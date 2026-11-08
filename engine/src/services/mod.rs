pub mod agents;
pub mod fs;
pub mod git;
pub mod lifecycle;
pub mod run;
pub mod schedule;

use crate::owner;
use crate::paths;
use crate::policy::Policy;
use crate::protocol::{EngineError, EngineResult, Request};
use serde_json::Value;
use std::path::Path;

type Handler = fn(&Request, &Path, &str, &Policy) -> EngineResult<Value>;

pub struct Service {
    pub name: &'static str,
    pub ops: &'static [&'static str],
    dispatch: Handler,
}

fn jobs_dir(state_root: &Path) -> EngineResult<()> {
    Ok(std::fs::create_dir_all(run::jobs_root(state_root))?)
}

/// Every service this binary carries, in the order `lifecycle probe` lists them.
pub const SERVICES: &[Service] = &[
    Service {
        name: lifecycle::SERVICE,
        ops: lifecycle::OPS,
        dispatch: |request, state_root, account, policy| {
            lifecycle::dispatch(&request.op, state_root, account, policy)
        },
    },
    Service {
        name: fs::SERVICE,
        ops: fs::OPS,
        dispatch: |request, _, _, _| fs::dispatch(&request.op, &request.args),
    },
    Service {
        name: run::SERVICE,
        ops: run::OPS,
        dispatch: |request, state_root, _, policy| {
            jobs_dir(state_root)?;
            run::dispatch(&request.op, &request.args, state_root, policy)
        },
    },
    Service {
        name: schedule::SERVICE,
        ops: schedule::OPS,
        dispatch: |request, state_root, _, _| {
            jobs_dir(state_root)?;
            schedule::dispatch(&request.op, &request.args, state_root)
        },
    },
    Service {
        name: agents::SERVICE,
        ops: agents::OPS,
        dispatch: |request, state_root, _, _| {
            agents::dispatch(&request.op, &request.args, state_root)
        },
    },
    Service {
        name: crate::shell::SERVICE,
        ops: crate::shell::OPS,
        dispatch: |request, state_root, _, policy| {
            crate::shell::dispatch(&request.op, &request.args, state_root, policy)
        },
    },
    Service {
        name: crate::shell::daemon::SERVICE,
        ops: crate::shell::daemon::OPS,
        dispatch: |request, state_root, _, policy| {
            crate::shell::daemon::dispatch(&request.op, state_root, policy)
        },
    },
    Service {
        name: git::SERVICE,
        ops: git::OPS,
        dispatch: |request, _, _, policy| git::dispatch(&request.op, &request.args, policy),
    },
];

/// probe and version answer before an owner is known: a phone has to be able to
/// ask a machine who it runs as before it can name that owner in a call.
fn caller(request: &Request) -> EngineResult<String> {
    if request.service == lifecycle::SERVICE && matches!(request.op.as_str(), "probe" | "version") {
        owner::account()
    } else {
        owner::verify(request.owner.as_deref())
    }
}

pub fn dispatch(request: &Request, policy: &Policy) -> EngineResult<Value> {
    let account = caller(request)?;

    policy.check_capability(&request.service, &request.op)?;
    let state_root = paths::state_root(&account)?;

    match SERVICES
        .iter()
        .find(|service| service.name == request.service)
    {
        Some(service) => (service.dispatch)(request, &state_root, &account, policy),
        None => Err(EngineError::unsupported(format!(
            "this engine carries no service {}; ask lifecycle probe for what it has",
            request.service
        ))),
    }
}
