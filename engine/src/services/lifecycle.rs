use crate::paths;
use crate::policy::Policy;
use crate::protocol::{EngineError, EngineResult, ENGINE_VERSION, PROTOCOL_VERSION};
use crate::services::{
    agents as agents_service, run as run_service, schedule as schedule_service, Service, SERVICES,
};
use nix::sys::signal::{killpg, Signal};
use nix::unistd::Pid;
use serde_json::{json, Value};
use std::fs;
use std::path::Path;

pub const SERVICE: &str = "lifecycle";
pub const OPS: &[&str] = &["probe", "version", "teardown"];

pub fn dispatch(op: &str, state_root: &Path, owner: &str, policy: &Policy) -> EngineResult<Value> {
    match op {
        "probe" => Ok(probe(state_root, owner, policy)),
        "version" => Ok(version()),
        "teardown" => teardown(state_root),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

pub fn version() -> Value {
    json!({ "engine": ENGINE_VERSION, "protocol": PROTOCOL_VERSION })
}

/// Only what is built is answered here. A service this document names but this
/// binary does not carry is absent rather than listed, so a plugin asking for one is
/// told before the call instead of inside it.
///
/// `ops` is what the binary carries and `denied_ops` is what this host refuses of it.
/// A caller that reads only `ops` would believe a denied op is available, so a service
/// denied one op at a time says so here rather than at the call.
fn probe(state_root: &Path, owner: &str, policy: &Policy) -> Value {
    let services: Vec<Value> = SERVICES
        .iter()
        .map(|Service { name, ops, .. }| {
            let denied_ops: Vec<&&str> = ops
                .iter()
                .filter(|op| policy.is_op_denied(name, op))
                .collect();
            json!({
                "name": name,
                "ops": ops,
                "denied": policy.is_service_denied(name),
                "denied_ops": denied_ops,
            })
        })
        .collect();

    json!({
        "engine": ENGINE_VERSION,
        "protocol": PROTOCOL_VERSION,
        "platform": paths::platform(),
        "owner": owner,
        "state_root": paths::display(state_root),
        "services": services,
        "deny_capabilities": policy.denied_capabilities(),
        "deny_exec": policy.denied_exec(),
        "shell_ports": policy.shell_ports().map(|ports| json!({ "from": ports.start(), "to": ports.end() })),
        "config": policy.sources(),
    })
}

/// Takes the engine's state directory and its timers off the machine. It does not
/// remove the binary: the binary is the user's declaration and theirs to withdraw.
fn teardown(state_root: &Path) -> EngineResult<Value> {
    // Before the early return as much as after it: a machine can carry a timer whose
    // state directory is already gone, and that is exactly the state this has to be
    // able to clear rather than the one it refuses to look at.
    let timers_removed = schedule_service::remove_timers();
    let hooks_removed = agents_service::remove_hooks();
    let shells_stopped = crate::shell::stop_all(state_root);
    let daemon_stopped = crate::shell::daemon::stop(state_root).unwrap_or(false);

    let (existed, jobs_removed, jobs_signalled) = if state_root.exists() {
        let (removed, signalled) = signal_jobs(state_root);
        fs::remove_dir_all(state_root)?;
        (true, removed, signalled)
    } else {
        (false, 0, 0)
    };
    Ok(json!({
        "state_root": paths::display(state_root),
        "existed": existed,
        "jobs_removed": jobs_removed,
        "jobs_signalled": jobs_signalled,
        "timers_removed": timers_removed,
        "hooks_removed": hooks_removed,
        "shells_stopped": shells_stopped,
        "daemon_stopped": daemon_stopped,
    }))
}

/// A job still running would outlive the directory recording it, leaving a process
/// nothing on this machine could name again.
fn signal_jobs(state_root: &Path) -> (u64, u64) {
    let (mut removed, mut signalled) = (0u64, 0u64);
    let Ok(entries) = fs::read_dir(run_service::jobs_root(state_root)) else {
        return (removed, signalled);
    };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with('.') {
            continue;
        }
        removed += 1;
        let Ok(status) = run_service::read_status(&entry.path()) else {
            continue;
        };
        if let (true, Some(pgid)) = (status.state.is_live(), status.pgid) {
            let _ = killpg(Pid::from_raw(pgid), Signal::SIGTERM);
            signalled += 1;
        }
    }
    (removed, signalled)
}
