use crate::protocol::{EngineError, EngineResult};
use nix::unistd::{geteuid, User};
use std::path::PathBuf;

fn passwd_entry() -> Option<User> {
    User::from_uid(geteuid()).ok().flatten()
}

pub fn passwd_home() -> Option<PathBuf> {
    passwd_entry()
        .map(|entry| entry.dir)
        .filter(|dir| !dir.as_os_str().is_empty())
}

pub fn passwd_shell() -> Option<String> {
    passwd_entry()
        .and_then(|entry| entry.shell.into_os_string().into_string().ok())
        .filter(|value| !value.is_empty())
}

/// The account the engine is running as, taken from the password database rather
/// than the environment: `USER` is inherited and a caller could have set it.
pub fn account() -> EngineResult<String> {
    passwd_entry()
        .map(|entry| entry.name)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| EngineError::failed("this uid has no entry in the password database"))
}

/// A machine several people use is not a way into another account's files: a call
/// naming an owner the engine is not running as is refused rather than served.
pub fn verify(requested: Option<&str>) -> EngineResult<String> {
    let running_as = account()?;
    match requested {
        None => Err(EngineError::bad_request(
            "owner is required; ask lifecycle probe for the owner this engine runs as",
        )),
        Some(owner) if owner == running_as => Ok(running_as),
        Some(owner) => Err(EngineError::denied(format!(
            "this engine runs as {running_as} and the call was made for {owner}"
        ))),
    }
}
