use crate::protocol::{EngineError, EngineResult};
use std::ffi::CStr;
use std::path::PathBuf;

/// `getpwuid` keeps its result in a static buffer and is not reentrant. The engine
/// answers one request on one thread and exits, so the borrow never outlives a call.
fn passwd_field<T>(read: impl FnOnce(&libc::passwd) -> T) -> Option<T> {
    unsafe {
        let entry = libc::getpwuid(libc::geteuid());
        if entry.is_null() {
            None
        } else {
            Some(read(&*entry))
        }
    }
}

fn c_str_to_string(raw: *const libc::c_char) -> Option<String> {
    if raw.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(raw) }
        .to_str()
        .ok()
        .map(str::to_owned)
}

pub fn passwd_home() -> Option<PathBuf> {
    passwd_field(|entry| c_str_to_string(entry.pw_dir))
        .flatten()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// The account the engine is running as, taken from the password database rather
/// than the environment: `USER` is inherited and a caller could have set it.
pub fn account() -> EngineResult<String> {
    passwd_field(|entry| c_str_to_string(entry.pw_name))
        .flatten()
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
