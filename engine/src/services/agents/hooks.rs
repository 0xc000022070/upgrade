use crate::paths;
use crate::protocol::{EngineError, EngineResult};
use crate::util::{self, Durability, Perms, WritePolicy};
use nix::unistd::{access, AccessFlags};
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::fs;
use std::path::{Path, PathBuf};

use super::AgentKind;

const MARK: &str = "upgraded hook";
const PLUGIN_MARK: &str = "// upgraded agents plugin";
const STATUS_LINE: &str = "upgraded statusline";
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

fn config_path(agent: AgentKind) -> EngineResult<PathBuf> {
    let home = paths::home()?;
    Ok(match agent {
        AgentKind::Claude => env_dir("CLAUDE_CONFIG_DIR")
            .unwrap_or(home.join(".claude"))
            .join("settings.json"),
        AgentKind::Codex => env_dir("CODEX_HOME")
            .unwrap_or(home.join(".codex"))
            .join("hooks.json"),
        AgentKind::OpenCode => env_dir("XDG_CONFIG_HOME")
            .unwrap_or(home.join(".config"))
            .join("opencode/plugins/upgrade.js"),
    })
}

fn command(agent: AgentKind) -> String {
    format!("{MARK} {agent}")
}

fn events(agent: AgentKind) -> &'static [&'static str] {
    match agent {
        AgentKind::Claude => CLAUDE_EVENTS,
        AgentKind::Codex | AgentKind::OpenCode => CODEX_EVENTS,
    }
}

fn entries(agent: AgentKind) -> Value {
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

fn is_our_status_line(value: &Value) -> bool {
    value
        .get("command")
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|command| {
            command == STATUS_LINE || command.strip_prefix(STATUS_LINE).is_some_and(|rest| rest.starts_with(' '))
        })
}

fn shell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

fn shell_unquoted(word: &str) -> Option<String> {
    let mut rest = word.strip_prefix('\'')?;
    let mut text = String::new();
    loop {
        let close = rest.find('\'')?;
        text.push_str(&rest[..close]);
        rest = &rest[close + 1..];
        if rest.is_empty() {
            return Some(text);
        }
        rest = rest.strip_prefix("\\''")?;
        text.push('\'');
    }
}

fn user_command(status_line: &Value) -> Option<String> {
    let command = status_line.get("command")?.as_str()?.trim();
    let typed = status_line.get("type").and_then(Value::as_str).unwrap_or("command") == "command";
    (!command.is_empty() && typed && !is_our_status_line(status_line)).then(|| command.to_owned())
}

fn ours_over(current: Option<&Value>) -> Value {
    let current = current.filter(|value| value.is_object());
    if let Some(current) = current.filter(|value| is_our_status_line(value)) {
        return current.clone();
    }
    let mut ours = current.cloned().unwrap_or(json!({}));
    ours["type"] = json!("command");
    ours["command"] = json!(match current.and_then(user_command) {
        Some(command) => format!("{STATUS_LINE} {}", shell_quoted(&command)),
        None => STATUS_LINE.to_owned(),
    });
    ours
}

fn status_line_for(path: &Path) -> Value {
    let config = read_json(path).unwrap_or_default();
    ours_over(config.get("statusLine"))
}

fn with_status_line(mut config: Value) -> EngineResult<Value> {
    let Value::Object(settings) = &mut config else {
        return Err(EngineError::failed("the config is not a JSON object"));
    };
    let ours = ours_over(settings.get("statusLine"));
    settings.insert("statusLine".to_owned(), ours);
    Ok(config)
}

fn without_status_line(mut config: Value) -> Value {
    let Some(settings) = config.as_object_mut() else {
        return config;
    };
    let Some(command) = settings
        .get("statusLine")
        .filter(|value| is_our_status_line(value))
        .and_then(|value| value["command"].as_str())
        .map(|command| command.trim()[STATUS_LINE.len()..].trim_start().to_owned())
    else {
        return config;
    };
    if command.is_empty() {
        settings.retain(|key, _| key != "statusLine");
    } else if let Some(previous) = shell_unquoted(&command) {
        settings["statusLine"]["command"] = json!(previous);
    }
    config
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

fn is_ours(entry: &Value, agent: AgentKind) -> bool {
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

fn claim(agent: AgentKind, path: &Path) -> EngineResult<()> {
    let foreign = agent == AgentKind::OpenCode && path.exists() && !installed(agent, path);
    if foreign || !writable(path) {
        return Err(EngineError::denied(format!(
            "{} is not the engine's to write; add the entries to your own config",
            paths::display(path)
        )));
    }
    Ok(())
}

fn installed(agent: AgentKind, path: &Path) -> bool {
    if agent == AgentKind::OpenCode {
        return fs::read_to_string(path).is_ok_and(|raw| raw.starts_with(PLUGIN_MARK));
    }
    let Ok(config) = read_json(path) else {
        return false;
    };
    if agent == AgentKind::Claude && !config.get("statusLine").is_some_and(is_our_status_line) {
        return false;
    }
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

fn manual(agent: AgentKind, path: &Path) -> Value {
    match agent {
        AgentKind::OpenCode => json!(plugin()),
        AgentKind::Claude => {
            let mut entries = entries(agent);
            entries["statusLine"] = status_line_for(path);
            entries
        }
        AgentKind::Codex => entries(agent),
    }
}

pub fn describe() -> EngineResult<Value> {
    let agents: EngineResult<Vec<Value>> = AgentKind::ALL
        .into_iter()
        .map(|agent| {
            let path = config_path(agent)?;
            Ok(json!({
                "agent": agent,
                "config_path": paths::display(&path),
                "installed": installed(agent, &path),
                "writable": claim(agent, &path).is_ok(),
                "entries": manual(agent, &path),
            }))
        })
        .collect();
    Ok(json!({ "agents": agents? }))
}

fn write_atomic(path: &Path, contents: &str) -> EngineResult<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    util::write_atomic(
        path,
        contents.as_bytes(),
        &WritePolicy {
            perms: Perms::Keep,
            durability: Durability::None,
            tmp_suffix: ".upgrade.tmp",
        },
    )?;
    Ok(())
}

fn merged(agent: AgentKind, mut config: Value) -> EngineResult<Value> {
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

pub fn install(agent: AgentKind) -> EngineResult<Value> {
    let path = config_path(agent)?;
    claim(agent, &path)?;
    let contents = match agent {
        AgentKind::OpenCode => plugin(),
        AgentKind::Claude => {
            let raw = read_raw(&path)?;
            let config = with_status_line(merged(agent, parse(&raw, &path)?)?)?;
            render(&config, &raw)?
        }
        AgentKind::Codex => {
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
    for agent in AgentKind::ALL {
        let Ok(path) = config_path(agent) else {
            continue;
        };
        if !writable(&path) || !installed_any(agent, &path) {
            continue;
        }
        let done = if agent == AgentKind::OpenCode {
            fs::remove_file(&path).is_ok()
        } else {
            read_raw(&path).is_ok_and(|raw| {
                parse(&raw, &path)
                    .ok()
                    .and_then(|config| stripped(agent, config))
                    .map(|config| match agent {
                        AgentKind::Claude => without_status_line(config),
                        AgentKind::Codex | AgentKind::OpenCode => config,
                    })
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

fn installed_any(agent: AgentKind, path: &Path) -> bool {
    if agent == AgentKind::OpenCode {
        return installed(agent, path);
    }
    read_json(path).is_ok_and(|config| {
        let status_line = agent == AgentKind::Claude && config.get("statusLine").is_some_and(is_our_status_line);
        status_line
            || config
                .get("hooks")
                .and_then(Value::as_object)
                .is_some_and(|hooks| {
                    hooks.values().filter_map(Value::as_array).flatten().any(|entry| is_ours(entry, agent))
                })
    })
}

fn stripped(agent: AgentKind, mut config: Value) -> Option<Value> {
    let root = config.as_object_mut()?;
    let Some(hooks) = root.get_mut("hooks").and_then(Value::as_object_mut) else {
        return Some(config);
    };
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
    use super::{
        claim, merged, ours_over, parse, plugin, render, shell_quoted, shell_unquoted, stripped, with_status_line,
        without_status_line, AgentKind, PLUGIN_MARK,
    };
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

    fn round_trip(agent: AgentKind, original: &str) -> (String, String) {
        let path = Path::new("settings.json");
        let installed = render(&merged(agent, parse(original, path).unwrap()).unwrap(), original).unwrap();
        let removed = render(&stripped(agent, parse(&installed, path).unwrap()).unwrap(), &installed).unwrap();
        (installed, removed)
    }

    #[test]
    fn a_quoted_command_reads_back_as_itself_and_nothing_else_does() {
        for text in ["", "my-status", r#"printf '%s' "a b""#, "'", "''", r"a'\''b", r"\'"] {
            assert_eq!(shell_unquoted(&shell_quoted(text)).as_deref(), Some(text), "{text}");
        }
        for word in ["", "plain", "'open", "'a' 'b'", "'a'b", r"'a'\'", r#""a""#, r"'a'\'''x"] {
            assert_eq!(shell_unquoted(word), None, "{word}");
        }
    }

    #[test]
    fn the_status_line_rides_in_the_engine_and_comes_back_out() {
        let mine = json!({ "statusLine": { "type": "command", "command": "echo 'hi'", "padding": 2 }, "model": "opus" });
        let installed = with_status_line(mine.clone()).unwrap();
        assert_eq!(installed["statusLine"]["command"], json!(r"upgraded statusline 'echo '\''hi'\'''"));
        assert_eq!(with_status_line(installed.clone()).unwrap(), installed);
        assert_eq!(ours_over(installed.get("statusLine")), installed["statusLine"]);
        assert_eq!(without_status_line(installed), mine);

        let bare = with_status_line(json!({ "model": "opus" })).unwrap();
        assert_eq!(bare["statusLine"], json!({ "type": "command", "command": "upgraded statusline" }));
        assert_eq!(without_status_line(bare), json!({ "model": "opus" }));

        let theirs = json!({ "statusLine": { "type": "command", "command": "upgraded-statusline" } });
        assert_eq!(without_status_line(theirs.clone()), theirs);
    }

    #[test]
    fn install_and_teardown_keep_the_user_key_order_and_indent() {
        let original = "{\n    \"zeta\": 1,\n    \"alpha\": {\n        \"b\": 1,\n        \"a\": 2\n    }\n}\n";
        let (installed, removed) = round_trip(AgentKind::Claude, original);
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
        let (_, removed) = round_trip(AgentKind::Codex, original);
        assert_eq!(removed, original);
    }

    #[test]
    fn teardown_leaves_the_user_own_empty_lists_and_adds_no_hooks_object() {
        let config = json!({ "hooks": { "PreToolUse": [], "Stop": [{ "hooks": [{ "type": "command", "command": "mine" }] }] } });
        let back = stripped(AgentKind::Claude, merged(AgentKind::Claude, config.clone()).unwrap()).unwrap();
        assert_eq!(back, config);

        let bare = json!({ "model": "opus" });
        assert_eq!(stripped(AgentKind::Claude, merged(AgentKind::Claude, bare.clone()).unwrap()).unwrap(), bare);
    }

    #[test]
    fn an_opencode_plugin_the_engine_did_not_write_is_refused() {
        let dir = scratch("claim");
        let foreign = dir.join("foreign.js");
        std::fs::write(&foreign, "export const Mine = async () => ({});\n").unwrap();
        let refused = claim(AgentKind::OpenCode, &foreign).unwrap_err();
        assert_eq!(refused.kind, ErrorKind::Denied);

        let ours = dir.join("ours.js");
        std::fs::write(&ours, format!("{PLUGIN_MARK}\nold\n")).unwrap();
        assert!(claim(AgentKind::OpenCode, &ours).is_ok());
        assert!(claim(AgentKind::OpenCode, &dir.join("absent.js")).is_ok());
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
