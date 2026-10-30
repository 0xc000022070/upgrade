#![deny(unsafe_code)]
#![deny(clippy::print_stdout, clippy::print_stderr)]

mod owner;
mod paths;
mod policy;
mod protocol;
mod services;
#[allow(unsafe_code)]
mod shell;
mod util;

use protocol::{EngineError, EngineResult, Request, Response};
use std::io::{Read, Write};
use std::path::PathBuf;

const MAX_REQUEST_BYTES: u64 = 1024 * 1024;

const USAGE: &str = "\
upgraded — the host side of a Upgrade plugin.

It is exec'd per call: it reads one JSON request on stdin, writes one JSON
response on stdout, and exits. The one thing that stays is a shell/1 server:
it listens on UDP for its own tab until the shell ends or is stopped.

    echo '{\"service\":\"lifecycle\",\"op\":\"probe\"}' | upgraded

  hook <agent>  report an agent's hook event (claude, codex, opencode); the
                agent runs this, not a person
  statusline [command]
                Claude Code's status line: keep its plan windows, then run
                the command, the status line the user had before, with
                sh -c; give it as one quoted argument
  --version   print the engine and protocol version as JSON
  --help      print this

Configuration is read from /etc/upgraded/config.json and the per-user file
beside it. Their denyCapabilities and denyExec lists are unioned, never replaced.
shellPorts {from, to} bounds the UDP ports shell/1 listens on; every file's
range is intersected, and the default is 60001-60999.
";

fn read_request() -> EngineResult<Request> {
    let mut raw = String::new();
    std::io::stdin()
        .lock()
        .take(MAX_REQUEST_BYTES)
        .read_to_string(&mut raw)
        .map_err(|err| EngineError::bad_request(format!("the request could not be read: {err}")))?;
    if raw.trim().is_empty() {
        return Err(EngineError::bad_request("no request was given on stdin"));
    }
    Ok(serde_json::from_str(&raw)?)
}

fn answer() -> EngineResult<serde_json::Value> {
    let request = read_request()?;
    let policy = policy::Policy::load()?;
    services::dispatch(&request, &policy)
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    match args.first().map(String::as_str) {
        Some("__supervise") => {
            let Some(dir) = args.get(1) else {
                util::warn("__supervise wants a job directory");
                std::process::exit(2);
            };
            std::process::exit(services::run::supervise(&PathBuf::from(dir)));
        }
        Some("__shell") => {
            let Some(dir) = args.get(1) else {
                util::warn("__shell wants a tab directory");
                std::process::exit(2);
            };
            std::process::exit(shell::serve(&PathBuf::from(dir)));
        }
        Some("__tick") => {
            let Some(scope) = args.get(1) else {
                util::warn("__tick wants a scope");
                std::process::exit(2);
            };
            std::process::exit(services::schedule::tick(scope));
        }
        Some("hook") => {
            let Some(agent) = args.get(1) else {
                util::warn("hook wants an agent kind");
                std::process::exit(0);
            };
            std::process::exit(services::agents::hook(agent));
        }
        Some("statusline") => {
            let command = args[1..].join(" ");
            let command = Some(command.as_str()).filter(|command| !command.trim().is_empty());
            std::process::exit(services::agents::statusline(command));
        }
        Some("--help" | "-h") => {
            let _ = std::io::stdout().write_all(USAGE.as_bytes());
            return;
        }
        Some("--version" | "-V") => {
            util::say(services::lifecycle::version());
            return;
        }
        Some(other) => {
            util::warn(format!(
                "upgraded: unknown argument {other}; the request goes on stdin"
            ));
            std::process::exit(2);
        }
        None => {}
    }

    let response = Response::from_result(answer());
    let mut stdout = std::io::stdout().lock();
    // The response carries the verdict. The exit status is about whether one was
    // produced at all, so a caller never has two answers that can disagree.
    match serde_json::to_writer(&mut stdout, &response).and_then(|()| {
        stdout.write_all(b"\n").map_err(serde_json::Error::io)?;
        stdout.flush().map_err(serde_json::Error::io)
    }) {
        Ok(()) => {}
        Err(err) => {
            util::warn(format!(
                "upgraded: the response could not be written: {err}"
            ));
            std::process::exit(2);
        }
    }
}
