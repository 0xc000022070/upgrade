mod owner;
mod paths;
mod policy;
mod protocol;
mod services;
mod util;

use protocol::{EngineError, EngineResult, Request, Response};
use std::io::{Read, Write};
use std::path::PathBuf;

const MAX_REQUEST_BYTES: u64 = 1024 * 1024;

const USAGE: &str = "\
dazzle-engine — the host side of a Dazzle plugin.

It is exec'd per call: it reads one JSON request on stdin, writes one JSON
response on stdout, and exits. Nothing is resident and nothing listens.

    echo '{\"service\":\"lifecycle\",\"op\":\"probe\"}' | dazzle-engine

  hook <agent>  report an agent's hook event (claude, codex, opencode); the
                agent runs this, not a person
  --version   print the engine and protocol version as JSON
  --help      print this

Configuration is read from /etc/dazzle-engine/config.json and the per-user file
beside it. Their denyCapabilities and denyExec lists are unioned, never replaced.
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
                eprintln!("__supervise wants a job directory");
                std::process::exit(2);
            };
            std::process::exit(services::run::supervise(&PathBuf::from(dir)));
        }
        Some("__tick") => {
            let Some(scope) = args.get(1) else {
                eprintln!("__tick wants a scope");
                std::process::exit(2);
            };
            std::process::exit(services::schedule::tick(scope));
        }
        Some("hook") => {
            let Some(agent) = args.get(1) else {
                eprintln!("hook wants an agent kind");
                std::process::exit(0);
            };
            std::process::exit(services::agents::hook(agent));
        }
        Some("--help" | "-h") => {
            print!("{USAGE}");
            return;
        }
        Some("--version" | "-V") => {
            println!("{}", services::lifecycle::version());
            return;
        }
        Some(other) => {
            eprintln!("dazzle-engine: unknown argument {other}; the request goes on stdin");
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
            eprintln!("dazzle-engine: the response could not be written: {err}");
            std::process::exit(2);
        }
    }
}
