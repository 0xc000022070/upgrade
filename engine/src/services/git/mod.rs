mod declared;
mod grammar;
mod highlight;
mod syntax;

use crate::paths;
use crate::policy::Policy;
use crate::protocol::{arg_str, arg_str_opt, arg_u64_opt, EngineError, EngineResult};
use highlight::Highlighter;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};

pub const SERVICE: &str = "git/1";
pub const OPS: &[&str] = &["diff"];

const DEFAULT_DIFF_BUDGET: u64 = 1024 * 1024;
const MAX_SIDE_BYTES: u64 = 512 * 1024;
const MAX_IMAGE_BYTES: u64 = 2 * 1024 * 1024;
const BINARY_SNIFF_BYTES: usize = 8000;

pub fn dispatch(op: &str, args: &Value, policy: &Policy) -> EngineResult<Value> {
    match op {
        "diff" => diff(args, policy),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

struct FileRequest {
    path: String,
    origin: Option<String>,
}

fn checked_path(raw: &str, key: &str) -> EngineResult<String> {
    let inside = !raw.is_empty()
        && !raw.contains(['\n', '\0'])
        && Path::new(raw)
            .components()
            .all(|component| matches!(component, Component::Normal(_) | Component::CurDir));
    if !inside {
        return Err(EngineError::bad_request(format!(
            "{key} {raw:?} must be a path relative to the top of the repository"
        )));
    }
    Ok(raw.to_owned())
}

fn file_requests(args: &Value) -> EngineResult<Vec<FileRequest>> {
    let Some(items) = args.get("files").and_then(Value::as_array) else {
        return Err(EngineError::bad_request(
            "files is required and must be an array of {path, origin}",
        ));
    };
    items
        .iter()
        .map(|item| {
            Ok(FileRequest {
                path: checked_path(arg_str(item, "path")?, "path")?,
                origin: arg_str_opt(item, "origin")?
                    .map(|origin| checked_path(origin, "origin"))
                    .transpose()?,
            })
        })
        .collect()
}

fn checked_commit(raw: &str) -> EngineResult<&str> {
    if (4..=64).contains(&raw.len()) && raw.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        Ok(raw)
    } else {
        Err(EngineError::bad_request(format!(
            "commit {raw:?} must be a commit's hexadecimal name"
        )))
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Against {
    Head,
    Index,
    Staged,
}

fn checked_against(raw: Option<&str>) -> EngineResult<Against> {
    match raw {
        None | Some("head") => Ok(Against::Head),
        Some("index") => Ok(Against::Index),
        Some("staged") => Ok(Against::Staged),
        Some(other) => Err(EngineError::bad_request(format!(
            "against {other:?} must be one of head, index or staged"
        ))),
    }
}

fn git(directory: &Path) -> Command {
    let mut command = Command::new("git");
    command
        .arg("-C")
        .arg(directory)
        .env("GIT_OPTIONAL_LOCKS", "0")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .stdin(Stdio::null());
    command
}

fn spawn_failed(err: io::Error) -> EngineError {
    if err.kind() == io::ErrorKind::NotFound {
        EngineError::not_found("git is not on this host's PATH")
    } else {
        EngineError::failed(format!("git could not be started: {err}"))
    }
}

fn git_line(directory: &Path, args: &[&str]) -> EngineResult<Result<Vec<u8>, String>> {
    let output = git(directory).args(args).output().map_err(spawn_failed)?;
    if !output.status.success() {
        return Ok(Err(String::from_utf8_lossy(&output.stderr)
            .trim()
            .to_owned()));
    }
    let mut line = output.stdout;
    while line
        .last()
        .is_some_and(|byte| *byte == b'\n' || *byte == b'\r')
    {
        line.pop();
    }
    Ok(Ok(line))
}

fn toplevel(directory: &Path) -> EngineResult<PathBuf> {
    match git_line(directory, &["rev-parse", "--show-toplevel"])? {
        Ok(top) if !top.is_empty() => Ok(PathBuf::from(OsStr::from_bytes(&top))),
        Ok(_) => Err(EngineError::bad_request(format!(
            "{} is inside a bare repository, which has no working tree",
            paths::display(directory)
        ))),
        Err(reason) => Err(EngineError::not_found(format!(
            "{} is not inside a git checkout: {reason}",
            paths::display(directory)
        ))),
    }
}

fn resolve_commit(top: &Path, commit: &str) -> EngineResult<String> {
    let spec = format!("{commit}^{{commit}}");
    match git_line(top, &["rev-parse", "--verify", "--quiet", &spec])? {
        Ok(sha) => Ok(String::from_utf8_lossy(&sha).into_owned()),
        Err(_) => Err(EngineError::not_found(format!(
            "{} has no commit {commit}",
            paths::display(top)
        ))),
    }
}

enum Side {
    Absent,
    Large,
    Bytes(Vec<u8>),
}

struct Fetched {
    oid: Option<String>,
    side: Side,
}

impl Fetched {
    const ABSENT: Fetched = Fetched {
        oid: None,
        side: Side::Absent,
    };
}

struct Blobs {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

impl Blobs {
    fn open(top: &Path) -> EngineResult<Self> {
        let mut child = git(top)
            .args(["cat-file", "--batch"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(spawn_failed)?;
        let stdin = child.stdin.take().expect("stdin is piped");
        let stdout = BufReader::new(child.stdout.take().expect("stdout is piped"));
        Ok(Self {
            child,
            stdin,
            stdout,
        })
    }

    fn get(&mut self, spec: &str, limit: u64) -> EngineResult<Fetched> {
        let lost =
            |err: io::Error| EngineError::failed(format!("git cat-file stopped answering: {err}"));
        self.stdin
            .write_all(format!("{spec}\n").as_bytes())
            .map_err(lost)?;
        self.stdin.flush().map_err(lost)?;
        let mut header = String::new();
        if self.stdout.read_line(&mut header).map_err(lost)? == 0 {
            return Err(EngineError::failed("git cat-file stopped answering"));
        }
        // `<oid> <type> <size>` for an object, `<spec> missing` and the like for none;
        // the spec is echoed back, so only the shape of the line tells them apart.
        let mut fields = header.trim_end().rsplitn(3, ' ');
        let size = fields.next().and_then(|size| size.parse::<u64>().ok());
        let kind = fields.next();
        let (Some(size), Some(kind), Some(oid)) = (size, kind, fields.next()) else {
            return Ok(Fetched::ABSENT);
        };
        if !matches!(kind, "blob" | "tree" | "commit" | "tag") {
            return Ok(Fetched::ABSENT);
        }
        let mut body = (&mut self.stdout).take(size + 1);
        if kind != "blob" || size > limit {
            io::copy(&mut body, &mut io::sink()).map_err(lost)?;
            return Ok(if kind == "blob" {
                Fetched {
                    oid: Some(oid.to_owned()),
                    side: Side::Large,
                }
            } else {
                Fetched::ABSENT
            });
        }
        let mut bytes = Vec::with_capacity(size as usize + 1);
        body.read_to_end(&mut bytes).map_err(lost)?;
        bytes.truncate(size as usize);
        Ok(Fetched {
            oid: Some(oid.to_owned()),
            side: Side::Bytes(bytes),
        })
    }
}

impl Drop for Blobs {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn worktree_side(top: &Path, path: &str, limit: u64) -> EngineResult<Side> {
    let target = top.join(path);
    let metadata = match fs::symlink_metadata(&target) {
        Ok(metadata) => metadata,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(Side::Absent),
        Err(err) => return Err(err.into()),
    };
    if metadata.file_type().is_symlink() {
        return Ok(Side::Bytes(
            fs::read_link(&target)?.as_os_str().as_bytes().to_vec(),
        ));
    }
    if !metadata.is_file() {
        return Ok(Side::Absent);
    }
    if metadata.len() > limit {
        return Ok(Side::Large);
    }
    Ok(Side::Bytes(fs::read(&target)?))
}

type Oids = HashMap<String, String>;

/// A symlink's blob is its target, which hash-object cannot be pointed at, so each
/// one is hashed from stdin.
fn worktree_oids(top: &Path, paths: &[&str]) -> EngineResult<Oids> {
    let mut oids = Oids::new();
    let mut files = Vec::new();
    for path in paths {
        match fs::symlink_metadata(top.join(path)) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                let target = fs::read_link(top.join(path))?;
                if let Some(oid) = hash_stdin(top, target.as_os_str().as_bytes())? {
                    oids.insert((*path).to_owned(), oid);
                }
            }
            Ok(metadata) if metadata.is_file() => files.push(*path),
            _ => {}
        }
    }
    if files.is_empty() {
        return Ok(oids);
    }
    let mut listed = Vec::new();
    for path in &files {
        listed.extend_from_slice(stdin_path(path).as_bytes());
        listed.push(b'\n');
    }
    let answered = piped(top, &["hash-object", "--stdin-paths"], listed)?;
    for (path, oid) in files.iter().zip(answered.lines()) {
        oids.insert((*path).to_owned(), oid.to_owned());
    }
    Ok(oids)
}

fn hash_stdin(top: &Path, bytes: &[u8]) -> EngineResult<Option<String>> {
    let answered = piped(top, &["hash-object", "--stdin"], bytes.to_vec())?;
    Ok(answered.lines().next().map(str::to_owned))
}

/// hash-object unquotes a line that opens with a double quote, so such a path
/// goes in quoted.
fn stdin_path(path: &str) -> String {
    if !path.starts_with('"') {
        return path.to_owned();
    }
    let escaped = path.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn piped(top: &Path, args: &[&str], input: Vec<u8>) -> EngineResult<String> {
    let mut child = git(top)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(spawn_failed)?;
    let mut stdin = child.stdin.take().expect("stdin is piped");
    let writer = std::thread::spawn(move || stdin.write_all(&input));
    let output = child
        .wait_with_output()
        .map_err(|err| EngineError::failed(format!("git {} failed: {err}", args[0])))?;
    let _ = writer.join();
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn as_text(bytes: Vec<u8>) -> Option<String> {
    let sniffed = &bytes[..bytes.len().min(BINARY_SNIFF_BYTES)];
    if memchr::memchr(0, sniffed).is_some() {
        return None;
    }
    String::from_utf8(bytes).ok()
}

fn image_mime(path: &str) -> Option<&'static str> {
    let extension = Path::new(path).extension()?.to_str()?.to_ascii_lowercase();
    let mime = match extension.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        _ => return None,
    };
    Some(mime)
}

fn skipped(file: &FileRequest, reason: &str) -> Value {
    json!({
        "path": file.path,
        "origin": file.origin,
        "skipped": reason,
        "language": null,
    })
}

fn insert_oids(entry: &mut Value, old: &Fetched, new: &Fetched) {
    if let Value::Object(entry) = entry {
        entry.insert("old_oid".into(), json!(old.oid));
        entry.insert("new_oid".into(), json!(new.oid));
    }
}

fn diff(args: &Value, policy: &Policy) -> EngineResult<Value> {
    let directory = paths::expand(arg_str(args, "directory")?)?;
    if !directory.is_absolute() {
        return Err(EngineError::bad_request(
            "directory must be an absolute path",
        ));
    }
    let commit = arg_str_opt(args, "commit")?
        .map(checked_commit)
        .transpose()?;
    let against = checked_against(arg_str_opt(args, "against")?)?;
    let files = file_requests(args)?;
    let budget = arg_u64_opt(args, "max_bytes")?.unwrap_or(DEFAULT_DIFF_BUDGET);
    policy.check_exec("git")?;

    let top = checkout_top(&directory)?;
    let commit = commit
        .map(|commit| resolve_commit(&top, commit))
        .transpose()?;
    answer(Reader::open(top, commit, against, &files)?, &files, budget)
}

fn checkout_top(directory: &Path) -> EngineResult<PathBuf> {
    if !fs::metadata(directory)?.is_dir() {
        return Err(EngineError::bad_request(format!(
            "{} is not a directory",
            paths::display(directory)
        )));
    }
    toplevel(directory)
}

struct Reader {
    blobs: Blobs,
    oids: Oids,
    top: PathBuf,
    commit: Option<String>,
    against: Against,
}

impl Reader {
    fn open(
        top: PathBuf,
        commit: Option<String>,
        against: Against,
        files: &[FileRequest],
    ) -> EngineResult<Self> {
        let oids = match (&commit, against) {
            (None, Against::Head | Against::Index) => {
                let paths: Vec<&str> = files.iter().map(|file| file.path.as_str()).collect();
                worktree_oids(&top, &paths)?
            }
            _ => Oids::new(),
        };
        Ok(Self {
            blobs: Blobs::open(&top)?,
            oids,
            top,
            commit,
            against,
        })
    }

    fn sides(&mut self, file: &FileRequest, limit: u64) -> EngineResult<(Fetched, Fetched)> {
        let old_path = file.origin.as_deref().unwrap_or(&file.path);
        if let Some(sha) = &self.commit {
            let old = self.blobs.get(&format!("{sha}^1:{old_path}"), limit)?;
            let new = self.blobs.get(&format!("{sha}:{}", file.path), limit)?;
            return Ok((old, new));
        }
        let old = match self.against {
            Against::Index => self.blobs.get(&format!(":{old_path}"), limit)?,
            Against::Head | Against::Staged => {
                self.blobs.get(&format!("HEAD:{old_path}"), limit)?
            }
        };
        let new = match self.against {
            Against::Staged => self.blobs.get(&format!(":{}", file.path), limit)?,
            Against::Head | Against::Index => match worktree_side(&self.top, &file.path, limit)? {
                Side::Absent => Fetched::ABSENT,
                side => Fetched {
                    oid: self.oids.get(&file.path).cloned(),
                    side,
                },
            },
        };
        Ok((old, new))
    }
}

enum Content {
    Text(Option<String>, Option<String>),
    Image(Option<Vec<u8>>, Option<Vec<u8>>, &'static str),
}

impl Content {
    fn size(&self) -> u64 {
        let encoded =
            |bytes: &Option<Vec<u8>>| bytes.as_ref().map_or(0, |b| b.len().div_ceil(3) * 4);
        let size = match self {
            Content::Text(old, new) => {
                old.as_ref().map_or(0, String::len) + new.as_ref().map_or(0, String::len)
            }
            Content::Image(old, new, _) => encoded(old) + encoded(new),
        };
        size as u64
    }
}

fn content(old: Side, new: Side, mime: Option<&'static str>) -> Result<Content, &'static str> {
    if matches!(old, Side::Large) || matches!(new, Side::Large) {
        return Err("large");
    }
    let bytes = |side: Side| match side {
        Side::Bytes(bytes) => Some(bytes),
        _ => None,
    };
    if let Some(mime) = mime {
        return Ok(Content::Image(bytes(old), bytes(new), mime));
    }
    let decode = |side: Side| match bytes(side) {
        Some(bytes) => as_text(bytes).map(Some),
        None => Some(None),
    };
    match (decode(old), decode(new)) {
        (Some(old), Some(new)) => Ok(Content::Text(old, new)),
        _ => Err("binary"),
    }
}

fn answer(mut reader: Reader, files: &[FileRequest], budget: u64) -> EngineResult<Value> {
    let mut used = 0u64;
    let mut capped = false;
    let mut highlighters = Highlighters::new();
    let mut answered = Vec::with_capacity(files.len());
    for file in files {
        if capped {
            answered.push(skipped(file, "budget"));
            continue;
        }
        let mime = image_mime(&file.path);
        let limit = if mime.is_some() {
            MAX_IMAGE_BYTES
        } else {
            MAX_SIDE_BYTES
        };
        let (old, new) = reader.sides(file, limit)?;
        let oids = (
            Fetched {
                oid: old.oid,
                side: Side::Absent,
            },
            Fetched {
                oid: new.oid,
                side: Side::Absent,
            },
        );
        let mut entry = match content(old.side, new.side, mime) {
            Ok(found) if used + found.size() > budget => {
                capped = true;
                skipped(file, "budget")
            }
            Ok(found) => {
                used += found.size();
                described(file, found, &mut highlighters)
            }
            Err(reason) => skipped(file, reason),
        };
        insert_oids(&mut entry, &oids.0, &oids.1);
        answered.push(entry);
    }

    Ok(json!({ "files": answered, "capped": capped }))
}

type Highlighters = HashMap<&'static str, Highlighter>;

fn described(file: &FileRequest, content: Content, highlighters: &mut Highlighters) -> Value {
    let mut entry = Map::new();
    entry.insert("path".into(), json!(file.path));
    entry.insert("origin".into(), json!(file.origin));
    let (old, new) = match content {
        Content::Text(old, new) => (old, new),
        Content::Image(old, new, mime) => {
            entry.insert("old".into(), Value::Null);
            entry.insert("new".into(), Value::Null);
            entry.insert("skipped".into(), Value::Null);
            entry.insert("language".into(), Value::Null);
            let encoded =
                |bytes: Option<Vec<u8>>| bytes.map(|bytes| crate::util::base64_encode(&bytes));
            entry.insert(
                "image".into(),
                json!({ "old": encoded(old), "new": encoded(new), "mime": mime }),
            );
            return Value::Object(entry);
        }
    };
    let first_line = new
        .as_deref()
        .or(old.as_deref())
        .and_then(|text| text.lines().next());
    let analysis = grammar::grammar_for(&file.path, first_line).and_then(|grammar| {
        let highlighter = highlighters
            .entry(grammar.name)
            .or_insert_with(|| Highlighter::new(&grammar));
        let analysis = syntax::analyze(
            &grammar,
            highlighter,
            old.as_deref().unwrap_or(""),
            new.as_deref().unwrap_or(""),
        )?;
        Some((grammar.name, analysis))
    });
    entry.insert("old".into(), json!(old));
    entry.insert("new".into(), json!(new));
    entry.insert("skipped".into(), Value::Null);
    match analysis {
        Some((language, analysis)) => {
            entry.insert("language".into(), json!(language));
            entry.insert("changed".into(), analysis.changed);
            entry.insert("scopes".into(), analysis.scopes);
            entry.insert("highlight".into(), analysis.highlight);
        }
        None => {
            entry.insert("language".into(), Value::Null);
        }
    }
    Value::Object(entry)
}
