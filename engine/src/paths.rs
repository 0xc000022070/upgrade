use crate::protocol::{EngineError, EngineResult};
use std::env;
use std::path::{Path, PathBuf};

pub fn platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else {
        "unknown"
    }
}

pub fn home() -> EngineResult<PathBuf> {
    if let Some(value) = env::var_os("HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(value));
    }
    crate::owner::passwd_home()
        .ok_or_else(|| EngineError::failed("this account has no home directory"))
}

fn non_empty_var(key: &str) -> Option<PathBuf> {
    env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// The directory the per-owner roots sit in. A timer the engine installs names this
/// rather than the root below it: the root is the base with the owner joined on, so a
/// unit that carried the root would have the owner joined on twice when it ran.
pub fn state_base() -> EngineResult<PathBuf> {
    if let Some(explicit) = non_empty_var("UPGRADED_STATE") {
        return Ok(explicit);
    }
    let base = if cfg!(target_os = "macos") {
        home()?.join("Library/Application Support")
    } else {
        non_empty_var("XDG_STATE_HOME").unwrap_or(home()?.join(".local/state"))
    };
    Ok(base.join("upgraded"))
}

/// Everything the engine writes lives under one directory, so `teardown` has a
/// single thing to remove and can say what it removed.
pub fn state_root(owner: &str) -> EngineResult<PathBuf> {
    Ok(state_base()?.join(owner))
}

/// Every one of these that exists is read and their deny lists are unioned, so a
/// file a user can write can only ever add to the ceiling the machine's owner set.
pub fn config_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(explicit) = non_empty_var("UPGRADED_CONFIG") {
        candidates.push(explicit);
    }
    if let Ok(home) = home() {
        if cfg!(target_os = "macos") {
            candidates.push(home.join("Library/Application Support/upgraded/config.json"));
        }
        let config_base = non_empty_var("XDG_CONFIG_HOME").unwrap_or(home.join(".config"));
        candidates.push(config_base.join("upgraded/config.json"));
    }
    candidates.push(PathBuf::from("/etc/upgraded/config.json"));
    candidates
}

pub fn expand(raw: &str) -> EngineResult<PathBuf> {
    if raw.is_empty() {
        return Err(EngineError::bad_request("path must not be empty"));
    }
    if raw == "~" {
        return home();
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return Ok(home()?.join(rest));
    }
    Ok(PathBuf::from(raw))
}

pub fn display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
