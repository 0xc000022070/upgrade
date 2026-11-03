use crate::paths;
use crate::protocol::{arg_str, arg_str_opt, arg_u64_opt, EngineError, EngineResult};
use crate::util::{base64_encode, epoch_secs};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

pub const SERVICE: &str = "fs/1";
pub const OPS: &[&str] = &["list", "read", "digest", "scan"];

/// A phone on a mobile radio pays for every byte twice, so a read that names no
/// limit still gets one rather than the whole file.
const DEFAULT_READ_LIMIT: u64 = 256 * 1024;
const MAX_READ_LIMIT: u64 = 4 * 1024 * 1024;
const DEFAULT_LIST_LIMIT: u64 = 1000;
const DEFAULT_SCAN_LIMIT: u64 = 1000;
const DEFAULT_SCAN_DEPTH: u64 = 16;

pub fn dispatch(op: &str, args: &Value) -> EngineResult<Value> {
    match op {
        "list" => list(args),
        "read" => read(args),
        "digest" => digest(args),
        "scan" => scan(args),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

fn kind_of(metadata: &fs::Metadata) -> &'static str {
    if metadata.is_dir() {
        "dir"
    } else if metadata.is_file() {
        "file"
    } else {
        "other"
    }
}

fn entry_value(name: String, path: &Path) -> Value {
    // symlink_metadata, so a link is reported as a link rather than as whatever it
    // points at, and a broken one still gets a row instead of failing the listing.
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            let target = fs::read_link(path).ok().map(|value| paths::display(&value));
            let resolved = fs::metadata(path).ok();
            json!({
                "name": name,
                "kind": "symlink",
                "target": target,
                "resolves_to": resolved.as_ref().map(kind_of),
                "size": resolved.as_ref().map(|value| value.len()).unwrap_or(0),
                "mtime": metadata.modified().map(epoch_secs).unwrap_or(0),
            })
        }
        Ok(metadata) => json!({
            "name": name,
            "kind": kind_of(&metadata),
            "size": metadata.len(),
            "mtime": metadata.modified().map(epoch_secs).unwrap_or(0),
        }),
        Err(err) => json!({ "name": name, "kind": "unreadable", "error": err.to_string() }),
    }
}

fn list(args: &Value) -> EngineResult<Value> {
    let target = paths::expand(arg_str(args, "path")?)?;
    let limit = arg_u64_opt(args, "limit")?.unwrap_or(DEFAULT_LIST_LIMIT) as usize;

    let metadata = fs::metadata(&target)?;
    if !metadata.is_dir() {
        return Err(EngineError::bad_request(format!(
            "{} is not a directory",
            paths::display(&target)
        )));
    }

    let mut names: Vec<String> = Vec::new();
    for entry in fs::read_dir(&target)? {
        names.push(entry?.file_name().to_string_lossy().into_owned());
    }
    names.sort();

    let total = names.len();
    let truncated = total > limit;
    names.truncate(limit);

    let entries: Vec<Value> = names
        .into_iter()
        .map(|name| {
            let path = target.join(&name);
            entry_value(name, &path)
        })
        .collect();

    Ok(json!({
        "path": paths::display(&target),
        "entries": entries,
        "total": total,
        "truncated": truncated,
    }))
}

fn read(args: &Value) -> EngineResult<Value> {
    let target = paths::expand(arg_str(args, "path")?)?;
    let offset = arg_u64_opt(args, "offset")?.unwrap_or(0);
    let limit = arg_u64_opt(args, "limit")?
        .unwrap_or(DEFAULT_READ_LIMIT)
        .min(MAX_READ_LIMIT);

    let metadata = fs::metadata(&target)?;
    if metadata.is_dir() {
        return Err(EngineError::bad_request(format!(
            "{} is a directory; use list",
            paths::display(&target)
        )));
    }

    let size = metadata.len();
    let mut file = fs::File::open(&target)?;
    if offset > 0 {
        file.seek(SeekFrom::Start(offset))?;
    }
    let mut buffer = vec![0u8; limit as usize];
    let mut filled = 0usize;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..])? {
            0 => break,
            count => filled += count,
        }
    }
    buffer.truncate(filled);

    // utf8 where it is utf8: a phone reading a source file should not have to decode
    // base64 to show it, and a binary is still answerable rather than an error.
    let (encoding, content) = match String::from_utf8(buffer) {
        Ok(text) => ("utf8", text),
        Err(err) => ("base64", base64_encode(err.as_bytes())),
    };

    Ok(json!({
        "path": paths::display(&target),
        "size": size,
        "offset": offset,
        "bytes": filled,
        "encoding": encoding,
        "content": content,
        "eof": offset.saturating_add(filled as u64) >= size,
    }))
}

fn digest(args: &Value) -> EngineResult<Value> {
    let target = paths::expand(arg_str(args, "path")?)?;
    let mut file = fs::File::open(&target)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 64 * 1024];
    let mut size = 0u64;
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        size += count as u64;
        hasher.update(&buffer[..count]);
    }
    Ok(json!({
        "path": paths::display(&target),
        "algorithm": "sha256",
        "digest": hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect::<String>(),
        "size": size,
    }))
}

fn scan(args: &Value) -> EngineResult<Value> {
    let root = paths::expand(arg_str(args, "root")?)?;
    let name = arg_str_opt(args, "name")?;
    let suffix = arg_str_opt(args, "suffix")?;
    let max_depth = arg_u64_opt(args, "max_depth")?.unwrap_or(DEFAULT_SCAN_DEPTH);
    let limit = arg_u64_opt(args, "limit")?.unwrap_or(DEFAULT_SCAN_LIMIT) as usize;

    let mut found: Vec<String> = Vec::new();
    let mut truncated = false;
    // Iterative, and symlinked directories are listed but never descended into, so a
    // link pointing back up its own tree cannot walk forever.
    let mut queue: Vec<(std::path::PathBuf, u64)> = vec![(root.clone(), 0)];
    while let Some((directory, depth)) = queue.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let file_name = entry.file_name().to_string_lossy().into_owned();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };

            let matches_name = name.is_none_or(|wanted| file_name == wanted);
            let matches_suffix = suffix.is_none_or(|wanted| file_name.ends_with(wanted));
            if matches_name && matches_suffix {
                if found.len() >= limit {
                    truncated = true;
                    break;
                }
                found.push(paths::display(&path));
            }

            if file_type.is_dir() && depth < max_depth {
                queue.push((path, depth + 1));
            }
        }
        if truncated {
            break;
        }
    }
    found.sort();

    Ok(json!({
        "root": paths::display(&root),
        "paths": found,
        "truncated": truncated,
    }))
}
