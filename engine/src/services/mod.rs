pub mod fs;
pub mod lifecycle;
pub mod run;
pub mod schedule;

use crate::owner;
use crate::paths;
use crate::policy::Policy;
use crate::protocol::{EngineError, EngineResult, Request};
use serde_json::Value;

pub fn dispatch(request: &Request, policy: &Policy) -> EngineResult<Value> {
    // probe and version answer before an owner is known: a phone has to be able to
    // ask a machine who it runs as before it can name that owner in a call.
    let anonymous =
        request.service == lifecycle::SERVICE && matches!(request.op.as_str(), "probe" | "version");
    let account = if anonymous {
        owner::account()?
    } else {
        owner::verify(request.owner.as_deref())?
    };

    policy.check_capability(&request.service, &request.op)?;
    let state_root = paths::state_root(&account)?;

    match request.service.as_str() {
        lifecycle::SERVICE => lifecycle::dispatch(&request.op, &state_root, &account, policy),
        fs::SERVICE => fs::dispatch(&request.op, &request.args),
        run::SERVICE => {
            std::fs::create_dir_all(run::jobs_root(&state_root))?;
            run::dispatch(&request.op, &request.args, &state_root, policy)
        }
        schedule::SERVICE => {
            std::fs::create_dir_all(run::jobs_root(&state_root))?;
            schedule::dispatch(&request.op, &request.args, &state_root)
        }
        other => Err(EngineError::unsupported(format!(
            "this engine carries no service {other}; ask lifecycle probe for what it has"
        ))),
    }
}
