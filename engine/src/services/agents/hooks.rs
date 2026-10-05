use crate::paths;
use crate::protocol::{EngineError, EngineResult};
use nix::unistd::{access, AccessFlags};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::KINDS;

const MARK: &str = "upgraded hook";
const PLUGIN_MARK: &str = "// upgraded agents plugin";
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
            .join("opencode/plugins/upgrade.js"),
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

export const UpgradeAgents = async ({{ client, $, directory }}) => {{
  let queue = Promise.resolve();
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
      const reported = queue.then(() => report(input));
      if (input.hook_event_name !== "PermissionRequest") queue = reported.catch(() => "");
      const pending = reported.then(async (text) => {{
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

fn read_raw(path: &Path) -> EngineResult<String> {
    match fs::read_to_string(path) {
        Ok(raw) => Ok(raw),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(err) => Err(err.into()),
    }
}

fn parse(raw: &str, path: &Path) -> EngineResult<Value> {
    if raw.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(raw)
        .map_err(|err| EngineError::failed(format!("{} is not JSON: {err}", paths::display(path))))
}

fn read_json(path: &Path) -> EngineResult<Value> {
    parse(&read_raw(path)?, path)
}

fn indent(raw: &str) -> &str {
    raw.lines()
        .skip(1)
        .map(|line| &line[..line.len() - line.trim_start_matches([' ', '\t']).len()])
        .find(|indent| !indent.is_empty())
        .unwrap_or("  ")
}

fn render(config: &Value, original: &str) -> EngineResult<String> {
    let mut out = Vec::new();
    let formatter = serde_json::ser::PrettyFormatter::with_indent(indent(original).as_bytes());
    config
        .serialize(&mut serde_json::Serializer::with_formatter(&mut out, formatter))
        .map_err(|err| EngineError::failed(err.to_string()))?;
    let mut raw = String::from_utf8_lossy(&out).into_owned();
    if original.is_empty() || original.ends_with('\n') {
        raw.push('\n');
    }
    Ok(raw)
}

fn claim(agent: &str, path: &Path) -> EngineResult<()> {
    let foreign = agent == "opencode" && path.exists() && !installed(agent, path);
    if foreign || !writable(path) {
        return Err(EngineError::denied(format!(
            "{} is not the engine's to write; add the entries to your own config",
            paths::display(path)
        )));
    }
    Ok(())
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
    access(&target, AccessFlags::W_OK).is_ok()
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
                "writable": claim(agent, &path).is_ok(),
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
    let tmp = path.with_extension("upgrade.tmp");
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
    claim(agent, &path)?;
    let contents = match agent {
        "opencode" => plugin(),
        _ => {
            let raw = read_raw(&path)?;
            render(&merged(agent, parse(&raw, &path)?)?, &raw)?
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
            read_raw(&path).is_ok_and(|raw| {
                parse(&raw, &path)
                    .ok()
                    .and_then(|config| stripped(agent, config))
                    .and_then(|config| render(&config, &raw).ok())
                    .is_some_and(|contents| write_atomic(&path, &contents).is_ok())
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
    let root = config.as_object_mut()?;
    let hooks = root.get_mut("hooks")?.as_object_mut()?;
    let before = hooks.len();
    hooks.retain(|_, list| match list {
        Value::Array(list) if list.iter().any(|entry| is_ours(entry, agent)) => {
            list.retain(|entry| !is_ours(entry, agent));
            !list.is_empty()
        }
        _ => true,
    });
    if hooks.is_empty() && before > 0 {
        root.retain(|key, _| key != "hooks");
    }
    Some(config)
}

#[cfg(test)]
mod tests {
    use super::{claim, merged, parse, plugin, render, stripped, PLUGIN_MARK};
    use crate::protocol::ErrorKind;
    use serde_json::{json, Value};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("upgrade-hooks-unit-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn round_trip(agent: &str, original: &str) -> (String, String) {
        let path = Path::new("settings.json");
        let installed = render(&merged(agent, parse(original, path).unwrap()).unwrap(), original).unwrap();
        let removed = render(&stripped(agent, parse(&installed, path).unwrap()).unwrap(), &installed).unwrap();
        (installed, removed)
    }

    #[test]
    fn install_and_teardown_keep_the_user_key_order_and_indent() {
        let original = "{\n    \"zeta\": 1,\n    \"alpha\": {\n        \"b\": 1,\n        \"a\": 2\n    }\n}\n";
        let (installed, removed) = round_trip("claude", original);
        let keys: Vec<String> = serde_json::from_str::<serde_json::Map<String, Value>>(&installed)
            .unwrap()
            .keys()
            .cloned()
            .collect();
        assert_eq!(keys, vec!["zeta", "alpha", "hooks"]);
        assert!(installed.starts_with("{\n    \"zeta\": 1,\n    \"alpha\": {\n        \"b\": 1,"), "{installed}");
        assert_eq!(removed, original);
    }

    #[test]
    fn a_file_without_a_trailing_newline_keeps_none() {
        let original = "{\n  \"model\": \"opus\"\n}";
        let (_, removed) = round_trip("codex", original);
        assert_eq!(removed, original);
    }

    #[test]
    fn teardown_leaves_the_user_own_empty_lists_and_adds_no_hooks_object() {
        let config = json!({ "hooks": { "PreToolUse": [], "Stop": [{ "hooks": [{ "type": "command", "command": "mine" }] }] } });
        let back = stripped("claude", merged("claude", config.clone()).unwrap()).unwrap();
        assert_eq!(back, config);

        let bare = json!({ "model": "opus" });
        assert_eq!(stripped("claude", merged("claude", bare.clone()).unwrap()).unwrap(), bare);
    }

    #[test]
    fn an_opencode_plugin_the_engine_did_not_write_is_refused() {
        let dir = scratch("claim");
        let foreign = dir.join("foreign.js");
        std::fs::write(&foreign, "export const Mine = async () => ({});\n").unwrap();
        let refused = claim("opencode", &foreign).unwrap_err();
        assert_eq!(refused.kind, ErrorKind::Denied);

        let ours = dir.join("ours.js");
        std::fs::write(&ours, format!("{PLUGIN_MARK}\nold\n")).unwrap();
        assert!(claim("opencode", &ours).is_ok());
        assert!(claim("opencode", &dir.join("absent.js")).is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    const HARNESS: &str = r#"
const { UpgradeAgents } = await import(process.argv[2]);
const log = [];
const $ = (_strings, body) => ({ quiet: () => ({ nothrow: async () => {
  const name = JSON.parse(await body.text()).hook_event_name;
  log.push(`start ${name}`);
  await new Promise((done) => setTimeout(done, name === "UserPromptSubmit" ? 80 : 0));
  log.push(`end ${name}`);
  return { text: () => "" };
} }) });
const hooks = await UpgradeAgents({ client: {}, $, directory: "/w" });
hooks.event({ event: { type: "session.status", properties: { sessionID: "s", status: { type: "busy" } } } });
hooks.event({ event: { type: "permission.asked", properties: { id: "p1", sessionID: "s", permission: "bash", patterns: ["ls"] } } });
await new Promise((done) => setTimeout(done, 300));
console.log(JSON.stringify(log));
"#;

    /// Skipped where no node is on PATH, as in the nix build sandbox.
    #[test]
    fn the_opencode_plugin_reports_events_in_the_order_they_came() {
        let dir = scratch("plugin-order");
        std::fs::write(dir.join("upgrade.mjs"), plugin()).unwrap();
        std::fs::write(dir.join("harness.mjs"), HARNESS).unwrap();
        let Ok(output) = Command::new("node").arg(dir.join("harness.mjs")).arg(dir.join("upgrade.mjs")).output() else {
            return;
        };
        let _ = std::fs::remove_dir_all(&dir);
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        let log: Vec<String> = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(
            log,
            vec!["start UserPromptSubmit", "end UserPromptSubmit", "start PermissionRequest", "end PermissionRequest"]
        );
    }
}
