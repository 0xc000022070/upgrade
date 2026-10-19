mod syntax;

use crate::paths;
use crate::policy::Policy;
use crate::protocol::{arg_str, arg_str_opt, arg_u64_opt, EngineError, EngineResult};
use serde_json::{json, Map, Value};
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

    fn get(&mut self, spec: &str) -> EngineResult<Side> {
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
        let (Some(size), Some(kind)) = (size, kind) else {
            return Ok(Side::Absent);
        };
        if !matches!(kind, "blob" | "tree" | "commit" | "tag") {
            return Ok(Side::Absent);
        }
        let mut body = (&mut self.stdout).take(size + 1);
        if kind != "blob" || size > MAX_SIDE_BYTES {
            io::copy(&mut body, &mut io::sink()).map_err(lost)?;
            return Ok(if kind == "blob" {
                Side::Large
            } else {
                Side::Absent
            });
        }
        let mut bytes = Vec::with_capacity(size as usize + 1);
        body.read_to_end(&mut bytes).map_err(lost)?;
        bytes.truncate(size as usize);
        Ok(Side::Bytes(bytes))
    }
}

impl Drop for Blobs {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn worktree_side(top: &Path, path: &str) -> EngineResult<Side> {
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
    if metadata.len() > MAX_SIDE_BYTES {
        return Ok(Side::Large);
    }
    Ok(Side::Bytes(fs::read(&target)?))
}

fn as_text(bytes: Vec<u8>) -> Option<String> {
    let sniffed = &bytes[..bytes.len().min(BINARY_SNIFF_BYTES)];
    if memchr::memchr(0, sniffed).is_some() {
        return None;
    }
    String::from_utf8(bytes).ok()
}

fn skipped(file: &FileRequest, reason: &str) -> Value {
    json!({
        "path": file.path,
        "origin": file.origin,
        "skipped": reason,
        "language": null,
    })
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
    let files = file_requests(args)?;
    let budget = arg_u64_opt(args, "max_bytes")?.unwrap_or(DEFAULT_DIFF_BUDGET);
    policy.check_exec("git")?;

    if !fs::metadata(&directory)?.is_dir() {
        return Err(EngineError::bad_request(format!(
            "{} is not a directory",
            paths::display(&directory)
        )));
    }
    let top = toplevel(&directory)?;
    let commit = commit
        .map(|commit| resolve_commit(&top, commit))
        .transpose()?;
    let mut blobs = Blobs::open(&top)?;
    answer(&mut blobs, &top, commit.as_deref(), &files, budget)
}

fn answer(
    blobs: &mut Blobs,
    top: &Path,
    commit: Option<&str>,
    files: &[FileRequest],
    budget: u64,
) -> EngineResult<Value> {
    let mut used = 0u64;
    let mut capped = false;
    let mut answered = Vec::with_capacity(files.len());
    for file in files {
        if capped {
            answered.push(skipped(file, "budget"));
            continue;
        }
        let (old, new) = match texts(blobs, top, commit, file)? {
            Ok(texts) => texts,
            Err(reason) => {
                answered.push(skipped(file, reason));
                continue;
            }
        };
        let size = old.as_ref().map_or(0, String::len) + new.as_ref().map_or(0, String::len);
        if used + size as u64 > budget {
            capped = true;
            answered.push(skipped(file, "budget"));
            continue;
        }
        used += size as u64;
        answered.push(described(file, old, new));
    }

    Ok(json!({ "files": answered, "capped": capped }))
}

type Texts = (Option<String>, Option<String>);

fn texts(
    blobs: &mut Blobs,
    top: &Path,
    commit: Option<&str>,
    file: &FileRequest,
) -> EngineResult<Result<Texts, &'static str>> {
    let old_path = file.origin.as_deref().unwrap_or(&file.path);
    let (old, new) = match commit {
        None => (
            blobs.get(&format!("HEAD:{old_path}"))?,
            worktree_side(top, &file.path)?,
        ),
        Some(sha) => (
            blobs.get(&format!("{sha}^1:{old_path}"))?,
            blobs.get(&format!("{sha}:{}", file.path))?,
        ),
    };
    if matches!(old, Side::Large) || matches!(new, Side::Large) {
        return Ok(Err("large"));
    }
    let decode = |side: Side| match side {
        Side::Bytes(bytes) => as_text(bytes).map(Some),
        _ => Some(None),
    };
    Ok(match (decode(old), decode(new)) {
        (Some(old), Some(new)) => Ok((old, new)),
        _ => Err("binary"),
    })
}

fn described(file: &FileRequest, old: Option<String>, new: Option<String>) -> Value {
    let analysis = syntax::grammar_for(&file.path).and_then(|grammar| {
        let analysis = syntax::analyze(
            &grammar,
            old.as_deref().unwrap_or(""),
            new.as_deref().unwrap_or(""),
        )?;
        Some((grammar.name, analysis))
    });
    let mut entry = Map::new();
    entry.insert("path".into(), json!(file.path));
    entry.insert("origin".into(), json!(file.origin));
    entry.insert("old".into(), json!(old));
    entry.insert("new".into(), json!(new));
    entry.insert("skipped".into(), Value::Null);
    match analysis {
        Some((language, analysis)) => {
            entry.insert("language".into(), json!(language));
            entry.insert("changed".into(), analysis.changed);
            entry.insert("scopes".into(), analysis.scopes);
        }
        None => {
            entry.insert("language".into(), Value::Null);
        }
    }
    Value::Object(entry)
}
