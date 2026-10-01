mod control;
mod endpoint;
mod input;
mod kitty;
mod kitty_medium;
mod launch;
mod link;
mod mirror;
mod os;
mod pty;
mod registry;
mod rtt;
mod server;
mod signals;
mod stream;
#[cfg(test)]
mod testing;
mod vt;
mod window;
pub mod wire;

use crate::owner;
use crate::paths;
use crate::policy::Policy;
use crate::protocol::{
    arg_bool, arg_str, arg_str_list, arg_str_opt, arg_u64_opt, EngineError, EngineResult,
};
use crate::services::run::env_pairs;
use launch::Spec;
use serde_json::{json, Value};
use std::ops::RangeInclusive;
use std::path::Path;

pub const SERVICE: &str = "shell/1";
pub const OPS: &[&str] = &["start", "stop", "list"];

pub use launch::serve;
pub use registry::stop_all;

const DEFAULT_TERM: &str = "xterm-256color";
const DEFAULT_SCROLLBACK: u64 = 10_000;
const MAX_SCROLLBACK: u64 = 1_000_000;
const SCROLLBACK_BYTES_PER_LINE: usize = 1024;
const IMAGE_BYTES: u64 = 64 << 20;
const MAX_CELLS: u64 = 1000;

pub fn dispatch(op: &str, args: &Value, state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    registry::ensure_root(state_root)?;
    match op {
        "start" => start(args, state_root, policy),
        "stop" => stop(args, state_root),
        "list" => Ok(list(state_root)),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

fn tab(args: &Value) -> EngineResult<&str> {
    let tab = arg_str(args, "tab")?;
    let valid = !tab.is_empty()
        && tab.len() <= 64
        && tab.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        && !tab.starts_with('-');
    if valid {
        Ok(tab)
    } else {
        Err(EngineError::bad_request(
            "tab must be 1-64 letters, digits and dashes, not leading with a dash",
        ))
    }
}

fn dimension(args: &Value, key: &str, fallback: u64, max: u64) -> EngineResult<u16> {
    let value = arg_u64_opt(args, key)?.unwrap_or(fallback);
    if value > max {
        return Err(EngineError::bad_request(format!(
            "{key} must be at most {max}"
        )));
    }
    Ok(value as u16)
}

fn ports(args: &Value, policy: &Policy) -> EngineResult<RangeInclusive<u16>> {
    let Some(allowed) = policy.shell_ports() else {
        return Err(EngineError::denied(
            "this host's shellPorts leave no port to listen on",
        ));
    };
    let Some(asked) = args.get("ports").filter(|value| !value.is_null()) else {
        return Ok(allowed);
    };
    let bound = |key: &str| {
        asked
            .get(key)
            .and_then(Value::as_u64)
            .filter(|port| (1..=u64::from(u16::MAX)).contains(port))
            .map(|port| port as u16)
            .ok_or_else(|| EngineError::bad_request(format!("ports.{key} must be a port number")))
    };
    let (from, to) = (
        bound("from")?.max(*allowed.start()),
        bound("to")?.min(*allowed.end()),
    );
    if from > to {
        return Err(EngineError::denied(format!(
            "no port asked for is one this host allows ({}-{})",
            allowed.start(),
            allowed.end()
        )));
    }
    Ok(from..=to)
}

fn login_shell() -> (Vec<String>, Option<String>) {
    let shell = owner::passwd_shell().unwrap_or_else(|| "/bin/sh".into());
    let name = Path::new(&shell)
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| shell.clone());
    (vec![shell], Some(format!("-{name}")))
}

fn spec(args: &Value, policy: &Policy) -> EngineResult<Spec> {
    let command = arg_str_list(args, "command")?;
    let (argv, arg0) = if command.is_empty() {
        login_shell()
    } else {
        (command, None)
    };
    policy.check_exec(&argv[0])?;

    let term = arg_str_opt(args, "term")?.unwrap_or(DEFAULT_TERM);
    if term.is_empty() || !term.chars().all(|c| c.is_ascii_graphic()) {
        return Err(EngineError::bad_request("term must be a terminal name"));
    }
    let mut env = vec![
        ("TERM".to_owned(), term.to_owned()),
        ("COLORTERM".to_owned(), "truecolor".to_owned()),
    ];
    env.extend(env_pairs(args)?);
    let scrollback = arg_u64_opt(args, "scrollback")?
        .unwrap_or(DEFAULT_SCROLLBACK)
        .min(MAX_SCROLLBACK) as usize;

    Ok(Spec {
        cols: dimension(args, "cols", 80, MAX_CELLS)?.max(1),
        rows: dimension(args, "rows", 24, MAX_CELLS)?.max(1),
        width_px: dimension(args, "width_px", 0, u64::from(u16::MAX))?,
        height_px: dimension(args, "height_px", 0, u64::from(u16::MAX))?,
        argv,
        arg0,
        cwd: paths::home()?,
        env,
        scrollback_lines: scrollback,
        scrollback_bytes: scrollback.max(1) * SCROLLBACK_BYTES_PER_LINE,
        image_bytes: IMAGE_BYTES,
    })
}

fn start(args: &Value, state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    let tab = tab(args)?;
    let resume = arg_bool(args, "resume", true)?;
    let spec = spec(args, policy)?;
    let ports = ports(args, policy)?;

    let _starting = registry::start_lock(state_root, tab)?;
    let dir = registry::dir(state_root, tab);
    if let Some(record) = registry::live(&dir) {
        if resume {
            if let Some(key) = launch::rekey(&dir, &record)? {
                return Ok(json!({
                    "port": record.port,
                    "key": wire::printable_key(&key),
                    "pid": record.pid,
                    "resumed": true,
                }));
            }
        }
        registry::stop(&dir)?;
    }

    registry::create_dir(&dir)?;
    match launch::launch(&dir, &spec, ports) {
        Ok(started) => Ok(json!({
            "port": started.port,
            "key": wire::printable_key(&started.key),
            "pid": started.pid,
            "resumed": false,
        })),
        Err(err) => {
            let _ = std::fs::remove_dir_all(&dir);
            Err(EngineError::failed(format!(
                "the shell server did not start: {err}"
            )))
        }
    }
}

fn stop(args: &Value, state_root: &Path) -> EngineResult<Value> {
    let tab = tab(args)?;
    let _starting = registry::start_lock(state_root, tab)?;
    let stopped = registry::stop(&registry::dir(state_root, tab))?;
    Ok(json!({ "stopped": stopped }))
}

fn list(state_root: &Path) -> Value {
    let shells: Vec<Value> = registry::list(state_root)
        .into_iter()
        .map(|(tab, record)| {
            json!({
                "tab": tab,
                "pid": record.pid,
                "port": record.port,
                "shell_pid": record.shell_pid,
                "started": record.started,
            })
        })
        .collect();
    json!({ "shells": shells })
}
