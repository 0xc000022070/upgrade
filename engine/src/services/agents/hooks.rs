use crate::paths;
use crate::protocol::{EngineError, EngineResult};
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::KINDS;

const MARK: &str = "dazzle-engine hook";
const PLUGIN_MARK: &str = "// dazzle-engine agents plugin";
const EVENT_TIMEOUT_S: u64 = 10;
const APPROVAL_TIMEOUT_S: u64 = 90;

const CLAUDE_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "Notification",
    "Stop",
    "StopFailure",
    "SessionEnd",
];

const CODEX_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
];

fn env_dir(key: &str) -> Option<PathBuf> {
    std::env::var_os(key)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn config_path(agent: &str) -> EngineResult<PathBuf> {
    let home = paths::home()?;
    Ok(match agent {
        "claude" => env_dir("CLAUDE_CONFIG_DIR")
            .unwrap_or(home.join(".claude"))
            .join("settings.json"),
        "codex" => env_dir("CODEX_HOME")
            .unwrap_or(home.join(".codex"))
            .join("hooks.json"),
        "opencode" => env_dir("XDG_CONFIG_HOME")
            .unwrap_or(home.join(".config"))
            .join("opencode/plugins/dazzle.js"),
        other => return Err(EngineError::bad_request(format!("no agent kind {other}"))),
    })
}

fn command(agent: &str) -> String {
    format!("{MARK} {agent}")
}

fn events(agent: &str) -> &'static [&'static str] {
    match agent {
        "claude" => CLAUDE_EVENTS,
        _ => CODEX_EVENTS,
    }
}

fn entries(agent: &str) -> Value {
    let mut hooks = Map::new();
    for event in events(agent) {
        let timeout = if *event == "PermissionRequest" {
            APPROVAL_TIMEOUT_S
        } else {
            EVENT_TIMEOUT_S
        };
        hooks.insert(
            (*event).to_owned(),
            json!([{ "hooks": [{ "type": "command", "command": command(agent), "timeout": timeout }] }]),
        );
    }
    json!({ "hooks": hooks })
}

fn plugin() -> String {
    format!(
        r#"{PLUGIN_MARK}
const answerable = (event) => {{
  const p = event.properties ?? {{}};
  switch (event.type) {{
    case "session.created":
      return {{ hook_event_name: "SessionStart", session_id: p.info?.id, session_title: p.info?.title }};
    case "session.status":
      return p.status?.type === "busy" ? {{ hook_event_name: "UserPromptSubmit", session_id: p.sessionID }} : null;
    case "session.idle":
      return {{ hook_event_name: "Stop", session_id: p.sessionID }};
    case "session.deleted":
      return {{ hook_event_name: "SessionEnd", session_id: p.info?.id }};
    case "permission.replied":
      return {{ hook_event_name: "PostToolUse", session_id: p.sessionID }};
    case "permission.asked":
    case "permission.updated":
      return {{
        hook_event_name: "PermissionRequest",
        session_id: p.sessionID,
        tool_name: p.permission ?? p.type ?? "permission",
        tool_input: {{ command: [].concat(p.patterns ?? p.pattern ?? []).join(" ") || p.title, ...(p.metadata ?? {{}}) }},
      }};
    default:
      return null;
  }}
}};

export const DazzleAgents = async ({{ client, $, directory }}) => {{
  const report = async (input) => {{
    const out = await $`{MARK} opencode < ${{new Response(JSON.stringify({{ cwd: directory, ...input }}))}}`.quiet().nothrow();
    return out.text();
  }};
  const reply = async (event, behavior) => {{
    const p = event.properties;
    const id = p.id;
    const answer = behavior === "allow" ? "once" : "reject";
    if (client.permission?.reply) {{
      await client.permission.reply({{ requestID: id, reply: answer, directory }});
    }} else {{
      await client.postSessionIdPermissionsPermissionId({{ path: {{ id: p.sessionID, permissionID: id }}, body: {{ response: answer }} }});
    }}
  }};
  return {{
    event: async ({{ event }}) => {{
      const input = answerable(event);
      if (!input?.session_id) return;
      const pending = report(input).then(async (text) => {{
        if (input.hook_event_name !== "PermissionRequest" || !text.trim()) return;
        const behavior = JSON.parse(text).hookSpecificOutput?.decision?.behavior;
        if (behavior) await reply(event, behavior);
      }}).catch(() => {{}});
      if (input.hook_event_name !== "PermissionRequest") await pending;
    }},
  }};
}};
"#
    )
}

fn is_ours(entry: &Value, agent: &str) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks.iter().any(|hook| {
                hook.get("command")
                    .and_then(Value::as_str)
                    .is_some_and(|command| command.trim() == self::command(agent))
            })
        })
}

fn read_json(path: &Path) -> EngineResult<Value> {
    match fs::read_to_string(path) {
        Ok(raw) if raw.trim().is_empty() => Ok(json!({})),
        Ok(raw) => serde_json::from_str(&raw)
            .map_err(|err| EngineError::failed(format!("{} is not JSON: {err}", paths::display(path)))),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(err.into()),
    }
}

fn installed(agent: &str, path: &Path) -> bool {
    if agent == "opencode" {
        return fs::read_to_string(path).is_ok_and(|raw| raw.starts_with(PLUGIN_MARK));
    }
    let Ok(config) = read_json(path) else {
        return false;
    };
    events(agent).iter().all(|event| {
        config
            .pointer(&format!("/hooks/{event}"))
            .and_then(Value::as_array)
            .is_some_and(|list| list.iter().any(|entry| is_ours(entry, agent)))
    })
}

fn writable(path: &Path) -> bool {
    if fs::symlink_metadata(path).is_ok_and(|meta| meta.file_type().is_symlink()) {
        return false;
    }
    let target = if path.exists() {
        path.to_path_buf()
    } else {
        match path.ancestors().skip(1).find(|dir| dir.exists()) {
            Some(dir) => dir.to_path_buf(),
            None => return false,
        }
    };
    let Ok(c_path) = std::ffi::CString::new(target.as_os_str().as_encoded_bytes()) else {
        return false;
    };
    unsafe { libc::access(c_path.as_ptr(), libc::W_OK) == 0 }
}

fn manual(agent: &str) -> Value {
    match agent {
        "opencode" => json!(plugin()),
        _ => entries(agent),
    }
}

pub fn describe() -> EngineResult<Value> {
    let agents: EngineResult<Vec<Value>> = KINDS
        .iter()
        .map(|agent| {
            let path = config_path(agent)?;
            Ok(json!({
                "agent": agent,
                "config_path": paths::display(&path),
                "installed": installed(agent, &path),
                "writable": writable(&path),
                "entries": manual(agent),
            }))
        })
        .collect();
    Ok(json!({ "agents": agents? }))
}

fn write_atomic(path: &Path, contents: &str) -> EngineResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = path.with_extension("dazzle.tmp");
    fs::write(&tmp, contents)?;
    if let Ok(meta) = fs::metadata(path) {
        fs::set_permissions(&tmp, meta.permissions())?;
    }
    fs::rename(tmp, path)?;
    Ok(())
}

fn merged(agent: &str, mut config: Value) -> EngineResult<Value> {
    let Value::Object(root) = &mut config else {
        return Err(EngineError::failed("the config is not a JSON object"));
    };
    let hooks = root.entry("hooks").or_insert_with(|| json!({}));
    let Value::Object(hooks) = hooks else {
        return Err(EngineError::failed("the config's hooks is not an object"));
    };
    let ours = entries(agent);
    for event in events(agent) {
        let list = hooks.entry((*event).to_owned()).or_insert_with(|| json!([]));
        let Value::Array(list) = list else {
            return Err(EngineError::failed(format!("the config's {event} hooks are not a list")));
        };
        list.retain(|entry| !is_ours(entry, agent));
        list.push(ours["hooks"][*event][0].clone());
    }
    Ok(config)
}

pub fn install(agent: &str) -> EngineResult<Value> {
    if !KINDS.contains(&agent) {
        return Err(EngineError::bad_request(format!("no agent kind {agent}")));
    }
    let path = config_path(agent)?;
    if !writable(&path) {
        return Err(EngineError::denied(format!(
            "{} is not the engine's to write; add the entries to your own config",
            paths::display(&path)
        )));
    }
    let contents = match agent {
        "opencode" => plugin(),
        _ => {
            let config = merged(agent, read_json(&path)?)?;
            let mut raw = serde_json::to_string_pretty(&config)
                .map_err(|err| EngineError::failed(err.to_string()))?;
            raw.push('\n');
            raw
        }
    };
    write_atomic(&path, &contents)?;
    Ok(json!({
        "agent": agent,
        "config_path": paths::display(&path),
        "installed": true,
    }))
}

pub fn remove_all() -> Vec<String> {
    let mut removed = Vec::new();
    for agent in KINDS {
        let Ok(path) = config_path(agent) else {
            continue;
        };
        if !writable(&path) || !installed_any(agent, &path) {
            continue;
        }
        let done = if *agent == "opencode" {
            fs::remove_file(&path).is_ok()
        } else {
            read_json(&path).ok().and_then(|config| stripped(agent, config)).is_some_and(|config| {
                serde_json::to_string_pretty(&config)
                    .ok()
                    .is_some_and(|raw| write_atomic(&path, &(raw + "\n")).is_ok())
            })
        };
        if done {
            removed.push(paths::display(&path));
        }
    }
    removed
}

fn installed_any(agent: &str, path: &Path) -> bool {
    if agent == "opencode" {
        return installed(agent, path);
    }
    read_json(path).is_ok_and(|config| {
        config
            .get("hooks")
            .and_then(Value::as_object)
            .is_some_and(|hooks| {
                hooks.values().filter_map(Value::as_array).flatten().any(|entry| is_ours(entry, agent))
            })
    })
}

fn stripped(agent: &str, mut config: Value) -> Option<Value> {
    let hooks = config.get_mut("hooks")?.as_object_mut()?;
    for list in hooks.values_mut() {
        if let Value::Array(list) = list {
            list.retain(|entry| !is_ours(entry, agent));
        }
    }
    hooks.retain(|_, list| list.as_array().is_none_or(|list| !list.is_empty()));
    Some(config)
}
