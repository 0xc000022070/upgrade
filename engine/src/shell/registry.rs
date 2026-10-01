use super::os::{lock, try_lock};
use crate::util::now_millis;
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const STOP_WAIT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Record {
    pub pid: i32,
    pub port: u16,
    pub shell_pid: u32,
    pub started: u64,
}

impl Record {
    pub fn new(port: u16, shell_pid: u32) -> Self {
        Self {
            pid: std::process::id() as i32,
            port,
            shell_pid,
            started: now_millis(),
        }
    }
}

pub fn root(state_root: &Path) -> PathBuf {
    state_root.join("shell")
}

pub fn dir(state_root: &Path, tab: &str) -> PathBuf {
    root(state_root).join(tab)
}

pub fn ensure_root(state_root: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root(state_root))
}

fn open_private(path: &Path) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)
}

pub fn start_lock(state_root: &Path, tab: &str) -> io::Result<File> {
    let file = open_private(&root(state_root).join(format!("{tab}.lock")))?;
    lock(&file)?;
    Ok(file)
}

pub fn server_lock(dir: &Path) -> io::Result<Option<File>> {
    let file = open_private(&dir.join("lock"))?;
    Ok(try_lock(&file)?.then_some(file))
}

pub fn write_record(dir: &Path, record: &Record) -> io::Result<()> {
    let tmp = dir.join("server.json.tmp");
    fs::write(&tmp, serde_json::to_vec(record)?)?;
    fs::rename(tmp, dir.join("server.json"))
}

pub fn is_live(dir: &Path) -> bool {
    let Ok(file) = OpenOptions::new().read(true).open(dir.join("lock")) else {
        return false;
    };
    matches!(try_lock(&file), Ok(false))
}

pub fn live(dir: &Path) -> Option<Record> {
    if !is_live(dir) {
        return None;
    }
    let raw = fs::read(dir.join("server.json")).ok()?;
    serde_json::from_slice(&raw).ok()
}

pub fn create_dir(dir: &Path) -> io::Result<()> {
    if dir.exists() {
        fs::remove_dir_all(dir)?;
    }
    fs::DirBuilder::new().mode(0o700).create(dir)
}

pub fn stop(dir: &Path) -> io::Result<bool> {
    let Ok(file) = OpenOptions::new().read(true).open(dir.join("lock")) else {
        return Ok(false);
    };
    if try_lock(&file)? {
        drop(file);
        remove(dir)?;
        return Ok(false);
    }
    let record = live(dir);
    if let Some(record) = &record {
        unsafe { libc::kill(record.pid, libc::SIGTERM) };
    }
    let deadline = Instant::now() + STOP_WAIT;
    while !try_lock(&file)? {
        if Instant::now() >= deadline {
            if let Some(record) = &record {
                unsafe {
                    libc::kill(record.pid, libc::SIGKILL);
                    libc::kill(-(record.shell_pid as libc::pid_t), libc::SIGKILL);
                }
            }
            lock(&file)?;
            break;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    remove(dir)?;
    Ok(true)
}

fn remove(dir: &Path) -> io::Result<()> {
    match fs::remove_dir_all(dir) {
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

fn tabs(state_root: &Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(root(state_root)) else {
        return Vec::new();
    };
    let mut tabs: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    tabs.sort();
    tabs
}

pub fn list(state_root: &Path) -> Vec<(String, Record)> {
    let mut out = Vec::new();
    for tab in tabs(state_root) {
        let dir = dir(state_root, &tab);
        if let Some(record) = live(&dir) {
            out.push((tab, record));
            continue;
        }
        let Ok(guard) = open_private(&root(state_root).join(format!("{tab}.lock"))) else {
            continue;
        };
        if matches!(try_lock(&guard), Ok(true)) && !is_live(&dir) {
            let _ = remove(&dir);
        }
    }
    out
}

pub fn stop_all(state_root: &Path) -> u64 {
    tabs(state_root)
        .into_iter()
        .filter(|tab| stop(&dir(state_root, tab)).unwrap_or(false))
        .count() as u64
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::testing;

    fn scratch(name: &str) -> PathBuf {
        testing::scratch("shell-registry", name)
    }

    fn eventually(mut done: impl FnMut() -> bool) -> bool {
        let deadline = Instant::now() + Duration::from_secs(2);
        while !done() {
            if Instant::now() >= deadline {
                return false;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        true
    }

    #[test]
    fn a_held_lock_is_a_live_server_and_a_released_one_is_swept() {
        let state = scratch("sweep");
        ensure_root(&state).unwrap();
        let dir = dir(&state, "tab-1");
        create_dir(&dir).unwrap();
        let held = server_lock(&dir).unwrap().expect("a fresh lock is free");
        write_record(&dir, &Record::new(60001, 1)).unwrap();
        assert!(server_lock(&dir).unwrap().is_none());
        assert_eq!(list(&state).len(), 1);
        drop(held);
        assert!(eventually(|| list(&state).is_empty() && !dir.exists()));
    }

    #[test]
    fn a_tab_being_started_is_not_swept() {
        let state = scratch("starting");
        ensure_root(&state).unwrap();
        let dir = dir(&state, "tab-2");
        create_dir(&dir).unwrap();
        let starting = start_lock(&state, "tab-2").unwrap();
        assert!(list(&state).is_empty());
        assert!(dir.exists());
        drop(starting);
        assert!(eventually(|| {
            list(&state);
            !dir.exists()
        }));
    }

    #[test]
    fn stopping_a_tab_with_no_server_says_so() {
        let state = scratch("stop");
        ensure_root(&state).unwrap();
        assert!(!stop(&dir(&state, "none")).unwrap());
    }
}
