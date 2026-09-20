use crate::paths;
use crate::protocol::{EngineError, EngineResult};
use serde::Deserialize;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    #[serde(default, rename = "denyCapabilities")]
    deny_capabilities: Vec<String>,
    #[serde(default, rename = "denyExec")]
    deny_exec: Vec<String>,
}

#[derive(Debug, Default)]
pub struct Policy {
    deny_capabilities: BTreeSet<String>,
    deny_exec: BTreeSet<String>,
    sources: Vec<PathBuf>,
}

impl Policy {
    /// Every readable candidate contributes, and the lists are unioned rather than
    /// overridden: a file a user can write adds to the machine owner's ceiling and
    /// can never take anything off it.
    pub fn load() -> EngineResult<Self> {
        let mut policy = Self::default();
        for candidate in paths::config_candidates() {
            let raw = match std::fs::read_to_string(&candidate) {
                Ok(raw) => raw,
                Err(err) if err.kind() == std::io::ErrorKind::NotFound => continue,
                // A ceiling that cannot be read is not a ceiling of no denials.
                Err(err) => {
                    return Err(EngineError::failed(format!(
                        "{} could not be read: {err}",
                        paths::display(&candidate)
                    )))
                }
            };
            let parsed: ConfigFile = serde_json::from_str(&raw).map_err(|err| {
                EngineError::failed(format!(
                    "{} is not valid engine configuration: {err}",
                    paths::display(&candidate)
                ))
            })?;
            policy.deny_capabilities.extend(parsed.deny_capabilities);
            policy.deny_exec.extend(parsed.deny_exec);
            policy.sources.push(candidate);
        }
        Ok(policy)
    }

    pub fn denied_capabilities(&self) -> Vec<&str> {
        self.deny_capabilities.iter().map(String::as_str).collect()
    }

    pub fn denied_exec(&self) -> Vec<&str> {
        self.deny_exec.iter().map(String::as_str).collect()
    }

    pub fn sources(&self) -> Vec<String> {
        self.sources
            .iter()
            .map(|path| paths::display(path))
            .collect()
    }

    pub fn is_service_denied(&self, service: &str) -> bool {
        self.deny_capabilities.contains(service)
    }

    pub fn is_op_denied(&self, service: &str, op: &str) -> bool {
        self.deny_capabilities.contains(&format!("{service}.{op}"))
    }

    /// An entry names either a whole service (`git/1`) or one of its ops (`fs/1.read`).
    pub fn check_capability(&self, service: &str, op: &str) -> EngineResult<()> {
        if self.deny_capabilities.contains(service) {
            return Err(EngineError::denied(format!("this host denies {service}")));
        }
        let scoped = format!("{service}.{op}");
        if self.deny_capabilities.contains(&scoped) {
            return Err(EngineError::denied(format!("this host denies {scoped}")));
        }
        Ok(())
    }

    /// Matched on the basename as well as the path as written, so naming a program
    /// by an absolute path is not a way around an entry that named the program.
    pub fn check_exec(&self, program: &str) -> EngineResult<()> {
        if self.deny_exec.is_empty() {
            return Ok(());
        }
        let basename = Path::new(program)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| program.to_owned());
        if self.deny_exec.contains(program) || self.deny_exec.contains(&basename) {
            return Err(EngineError::denied(format!(
                "this host denies running {basename}"
            )));
        }
        Ok(())
    }
}
