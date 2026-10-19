mod hooks;
mod transcript;
mod usage;

use crate::owner;
use crate::paths;
use crate::protocol::{arg_str, arg_u64_opt, EngineError, EngineResult};
use crate::util::{now_millis, write_atomic, Durability, Perms, WritePolicy, PLAIN_WRITE};
use nix::errno::Errno;
use nix::sys::signal::kill;
use nix::unistd::{getppid, Pid};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::Read;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;

pub use hooks::remove_all as remove_hooks;
pub use usage::statusline;

pub const SERVICE: &str = "agents/1";
pub const OPS: &[&str] = &["watch", "answer", "transcript", "hooks", "install", "usage"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentKind {
    Claude,
    Codex,
    OpenCode,
}

impl AgentKind {
    pub const ALL: [Self; 3] = [Self::Claude, Self::Codex, Self::OpenCode];

    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|kind| kind.name() == name)
    }

    pub fn parse(name: &str) -> EngineResult<Self> {
        Self::from_name(name)
            .ok_or_else(|| EngineError::bad_request(format!("no agent kind {name}")))
    }

    fn injected(self) -> &'static [&'static str] {
        match self {
            Self::Claude => CLAUDE_INJECTED,
            Self::Codex => CODEX_INJECTED,
            Self::OpenCode => &[],
        }
    }
}

impl std::fmt::Display for AgentKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.name())
    }
}

const SCHEMA_VERSION: u32 = 1;
const MAX_HOOK_INPUT: u64 = 64 * 1024 * 1024;
const APPROVAL_WAIT_MS: u64 = 60_000;
const MAX_WATCH_WAIT_MS: u64 = 30_000;
const SESSION_KEPT_MS: u64 = 24 * 60 * 60 * 1000;
const MAX_SESSIONS: usize = 64;
const SUMMARY_CHARS: usize = 256;
const LINE_CHARS: usize = 280;
const POLL: Duration = Duration::from_millis(150);

const CLAUDE_INJECTED: &[&str] = &[
    "<task-notification>",
    "<teammate-message",
    "Another Claude session sent a message:",
    "<local-command-stdout>",
    "<local-command-stderr>",
    "<local-command-caveat>",
    "<bash-stdout>",
    "<bash-stderr>",
    "<system-reminder>",
];

const CODEX_INJECTED: &[&str] = &[
    "# AGENTS.md instructions",
    "<environment_context>",
    "<permissions instructions>",
    "<user_instructions>",
    "<turn_aborted>",
];

fn tagged<'a>(text: &'a str, tag: &str) -> Option<&'a str> {
    let open = format!("<{tag}>");
    let start = text.find(&open)? + open.len();
    let end = start + text[start..].find(&format!("</{tag}>"))?;
    Some(text[start..end].trim())
}

fn typed(agent: AgentKind, text: &str) -> Option<String> {
    let trimmed = text.trim_start();
    if agent == AgentKind::Claude && trimmed.starts_with("<command-") {
        if let Some(name) = tagged(trimmed, "command-name") {
            let args = tagged(trimmed, "command-args").unwrap_or("");
            return Some(format!("{name} {args}").trim_end().to_owned());
        }
    }
    if agent == AgentKind::Claude && trimmed.starts_with("<bash-input>") {
        if let Some(command) = tagged(trimmed, "bash-input") {
            return Some(format!("! {command}"));
        }
    }
    let injected = trimmed.is_empty()
        || agent
            .injected()
            .iter()
            .any(|mark| trimmed.starts_with(mark));
    (!injected).then(|| text.to_owned())
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Approval {
    id: String,
    tool: String,
    summary: String,
    created: u64,
    expires: u64,
    pid: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Session {
    key: String,
    agent: AgentKind,
    session_id: String,
    state: String,
    started: u64,
    updated: u64,
    #[serde(default)]
    cwd: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    message: Option<String>,
    #[serde(default)]
    transcript: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    approval: Option<Approval>,
    #[serde(default)]
    question: Option<String>,
    #[serde(default)]
    herdr_pane: Option<String>,
    #[serde(default)]
    herdr_socket: Option<String>,
    #[serde(default)]
    tmux_pane: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    version: u32,
    generation: u64,
    sessions: Vec<Session>,
}

pub fn root(state_root: &Path) -> PathBuf {
    state_root.join("agents")
}

fn answers_dir(root: &Path) -> PathBuf {
    root.join("answers")
}

fn read_state(root: &Path) -> EngineResult<State> {
    match fs::read_to_string(root.join("state.json")) {
        Ok(raw) => {
            let state: State = serde_json::from_str(&raw)
                .map_err(|err| EngineError::failed(format!("the agent state is unreadable: {err}")))?;
            if state.version > SCHEMA_VERSION {
                return Err(EngineError::unsupported("unsupported agent data version"));
            }
            Ok(state)
        }
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(State::default()),
        Err(err) => Err(err.into()),
    }
}

struct Store {
    root: PathBuf,
    _lock: fs::File,
    state: State,
}

impl Store {
    fn open(root: &Path) -> EngineResult<Self> {
        fs::create_dir_all(root)?;
        fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join("lock"))?;
        if let Err(err) = lock.lock() {
            return Err(EngineError::failed(format!(
                "the agent state could not be locked: {err}"
            )));
        }
        let state = read_state(root)?;
        Ok(Self {
            root: root.to_path_buf(),
            _lock: lock,
            state,
        })
    }

    fn commit(&mut self) -> EngineResult<()> {
        let now = now_millis();
        self.state
            .sessions
            .retain(|session| now.saturating_sub(session.updated) < SESSION_KEPT_MS);
        self.state.sessions.sort_by_key(|session| std::cmp::Reverse(session.updated));
        self.state.sessions.truncate(MAX_SESSIONS);
        self.state.version = SCHEMA_VERSION;
        self.state.generation += 1;

        write_atomic(
            &self.root.join("state.json"),
            &serde_json::to_vec(&self.state).map_err(|err| EngineError::failed(err.to_string()))?,
            &WritePolicy {
                perms: Perms::Private,
                durability: Durability::File,
                tmp_suffix: ".tmp",
            },
        )?;
        Ok(())
    }

    fn session(&mut self, key: &str) -> Option<&mut Session> {
        self.state.sessions.iter_mut().find(|session| session.key == key)
    }
}

pub fn dispatch(op: &str, args: &Value, state_root: &Path) -> EngineResult<Value> {
    let root = root(state_root);
    match op {
        "watch" => watch(args, &root),
        "answer" => answer(args, &root),
        "transcript" => transcript::read(args, &read_state(&root)?.sessions_by_key()),
        "hooks" => hooks::describe(),
        "install" => hooks::install(AgentKind::parse(arg_str(args, "agent")?)?),
        "usage" => usage::read(args, &root),
        _ => Err(EngineError::unsupported(format!("{SERVICE} has no op {op}"))),
    }
}

impl State {
    fn sessions_by_key(&self) -> Vec<(String, AgentKind, Option<String>)> {
        self.sessions
            .iter()
            .map(|session| (session.key.clone(), session.agent, session.transcript.clone()))
            .collect()
    }
}

fn alive(pid: i32) -> bool {
    pid > 0
        && matches!(kill(Pid::from_raw(pid), None), Ok(()) | Err(Errno::EPERM))
}

fn view(session: &Session) -> Value {
    let approval = session
        .approval
        .as_ref()
        .filter(|approval| alive(approval.pid));
    json!({
        "key": session.key,
        "agent": session.agent,
        "session_id": session.session_id,
        "state": session.state,
        "started": session.started,
        "updated": session.updated,
        "cwd": session.cwd,
        "title": session.title,
        "prompt": session.prompt,
        "message": session.message,
        "model": session.model,
        "has_transcript": session.transcript.is_some(),
        "approval": approval.map(|approval| json!({
            "id": approval.id,
            "tool": approval.tool,
            "summary": approval.summary,
            "created": approval.created,
            "expires": approval.expires,
        })),
        "question": session.question.clone().or_else(|| {
            session
                .approval
                .as_ref()
                .filter(|approval| !alive(approval.pid))
                .map(|approval| approval.summary.clone())
        }),
        "herdr_pane": session.herdr_pane,
        "herdr_socket": session.herdr_socket,
        "tmux_pane": session.tmux_pane,
    })
}

fn snapshot(state: &State) -> Value {
    let now = now_millis();
    let sessions: Vec<Value> = state
        .sessions
        .iter()
        .filter(|session| now.saturating_sub(session.updated) < SESSION_KEPT_MS)
        .map(view)
        .collect();
    json!({ "generation": state.generation, "now": now, "sessions": sessions })
}

fn watch(args: &Value, root: &Path) -> EngineResult<Value> {
    let seen = arg_u64_opt(args, "generation")?;
    let wait = arg_u64_opt(args, "wait_ms")?.unwrap_or(0).min(MAX_WATCH_WAIT_MS);
    let deadline = now_millis() + wait;
    loop {
        let state = read_state(root)?;
        if seen != Some(state.generation) || now_millis() >= deadline {
            return Ok(snapshot(&state));
        }
        std::thread::sleep(POLL);
    }
}

fn answer(args: &Value, root: &Path) -> EngineResult<Value> {
    let id = arg_str(args, "id")?;
    let decision = arg_str(args, "decision")?;
    if decision != "allow" && decision != "deny" {
        return Err(EngineError::bad_request("decision must be allow or deny"));
    }
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(EngineError::bad_request("id is not an approval id"));
    }
    let store = Store::open(root)?;
    let now = now_millis();
    let waiting = store.state.sessions.iter().any(|session| {
        session
            .approval
            .as_ref()
            .is_some_and(|approval| approval.id == id && now < approval.expires && alive(approval.pid))
    });
    if !waiting {
        return Err(EngineError::not_found("the approval is no longer waiting"));
    }
    let dir = answers_dir(root);
    fs::create_dir_all(&dir)?;
    write_atomic(&dir.join(id), decision.as_bytes(), &PLAIN_WRITE)?;
    Ok(json!({ "id": id, "decision": decision }))
}

fn cut(text: &str, limit: usize) -> String {
    let trimmed = text.trim();
    match trimmed.char_indices().nth(limit) {
        Some((index, _)) => format!("{}…", &trimmed[..index]),
        None => trimmed.to_owned(),
    }
}

fn text(value: &Value, key: &str) -> Option<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_owned)
}

fn summarize(input: &Value) -> String {
    if let Some(question) = input.pointer("/questions/0").and_then(|first| text(first, "question")) {
        return cut(&question, SUMMARY_CHARS);
    }
    for key in ["command", "file_path", "path", "url", "pattern", "query", "description"] {
        if let Some(value) = text(input, key) {
            return cut(&value, SUMMARY_CHARS);
        }
    }
    match input {
        Value::Null => String::new(),
        Value::String(value) => cut(value, SUMMARY_CHARS),
        other => cut(&other.to_string(), SUMMARY_CHARS),
    }
}

fn env_text(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|value| !value.is_empty())
}

pub fn hook(agent: &str) -> i32 {
    if let Err(err) = run_hook(agent) {
        crate::util::warn(format!("strikedddd hook: {err}"));
    }
    0
}

fn new_session(key: &str, agent: AgentKind, session_id: &str, now: u64) -> Session {
    Session {
        key: key.to_owned(),
        agent,
        session_id: session_id.to_owned(),
        state: "idle".to_owned(),
        started: now,
        updated: now,
        cwd: None,
        title: None,
        prompt: None,
        message: None,
        transcript: None,
        model: None,
        approval: None,
        question: None,
        herdr_pane: None,
        herdr_socket: None,
        tmux_pane: None,
    }
}

fn note_context(session: &mut Session, input: &Value) {
    if let Some(cwd) = text(input, "cwd") {
        session.cwd = Some(cwd);
    }
    if let Some(path) = text(input, "transcript_path") {
        session.transcript = Some(path);
    }
    if let Some(model) = text(input, "model") {
        session.model = Some(model);
    }
    if let Some(title) = text(input, "session_title") {
        session.title = Some(cut(&title, LINE_CHARS));
    }
    session.herdr_pane = env_text("HERDR_PANE_ID").or(session.herdr_pane.take());
    session.herdr_socket = env_text("HERDR_SOCKET_PATH").or(session.herdr_socket.take());
    session.tmux_pane = env_text("TMUX_PANE").or(session.tmux_pane.take());
}

fn settle_state(session: &mut Session, state: &str) {
    session.state = state.to_owned();
    session.approval = None;
    session.question = None;
}

fn request_approval(session: &mut Session, input: &Value) -> Approval {
    let tool = text(input, "tool_name").unwrap_or_else(|| "tool".to_owned());
    let summary = summarize(input.get("tool_input").unwrap_or(&Value::Null));
    let created = now_millis();
    let pending = Approval {
        id: format!("{created}-{}", std::process::id()),
        tool,
        summary,
        created,
        expires: created + APPROVAL_WAIT_MS,
        pid: std::process::id() as i32,
    };
    session.state = "blocked".to_owned();
    session.question = None;
    session.approval = Some(pending.clone());
    pending
}

/// A question is answered by picking an option, which an allow or deny cannot carry, so it
/// opens no approval and the agent puts its own picker up at once.
fn asked(input: &Value) -> Option<String> {
    if text(input, "tool_name").as_deref() != Some("AskUserQuestion") {
        return None;
    }
    let questions = input.pointer("/tool_input/questions").and_then(Value::as_array)?;
    let first = questions.first()?;
    let question = text(first, "question")?;
    let head = match text(first, "header") {
        Some(header) => format!("{header} · {question}"),
        None => question,
    };
    let mut lines = vec![cut(&head, SUMMARY_CHARS)];
    let options = first.get("options").and_then(Value::as_array).into_iter().flatten();
    let labels = options.filter_map(|option| text(option, "label"));
    for (index, label) in labels.enumerate() {
        lines.push(format!("{}. {}", index + 1, cut(&label, LINE_CHARS / 4)));
    }
    if questions.len() > 1 {
        lines.push(format!("+{} more", questions.len() - 1));
    }
    Some(lines.join("\n"))
}

fn apply_event(session: &mut Session, event: &str, input: &Value) -> Option<Option<Approval>> {
    match event {
        "SessionStart" => settle_state(session, "idle"),
        "UserPromptSubmit" => {
            settle_state(session, "working");
            if let Some(prompt) = text(input, "prompt").and_then(|prompt| typed(session.agent, &prompt)) {
                session.prompt = Some(cut(&prompt, LINE_CHARS));
            }
        }
        "PreToolUse" | "PostToolUse" | "PostToolUseFailure" => settle_state(session, "working"),
        "PermissionRequest" => match asked(input) {
            Some(question) => {
                session.state = "blocked".to_owned();
                session.approval = None;
                session.question = Some(question);
            }
            None => return Some(Some(request_approval(session, input))),
        },
        "Notification" => {
            let kind = text(input, "notification_type").unwrap_or_default();
            if matches!(kind.as_str(), "elicitation_dialog" | "agent_needs_input") {
                session.state = "blocked".to_owned();
                let message = text(input, "message").map(|value| cut(&value, SUMMARY_CHARS));
                session.question = session.question.take().or(message);
            }
        }
        "Stop" | "StopFailure" => {
            settle_state(session, "done");
            if let Some(message) = text(input, "last_assistant_message") {
                session.message = Some(cut(&message, LINE_CHARS));
            }
        }
        "SessionEnd" => settle_state(session, "ended"),
        _ => return None,
    }
    Some(None)
}

fn print_decision(decision: &str) {
    let mut decided = json!({ "behavior": decision });
    if decision == "deny" {
        decided["message"] = json!("Denied from Striked");
    }
    let output = json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decided,
        }
    });
    crate::util::say(output);
}

fn read_hook_input() -> EngineResult<Value> {
    let mut stdin = std::io::stdin().lock();
    let mut raw = Vec::new();
    (&mut stdin).take(MAX_HOOK_INPUT).read_to_end(&mut raw)?;
    if std::io::copy(&mut stdin, &mut std::io::sink())? > 0 {
        return Err(EngineError::bad_request(format!(
            "the hook input is over {MAX_HOOK_INPUT} bytes"
        )));
    }
    Ok(serde_json::from_slice(&raw)?)
}

fn run_hook(agent: &str) -> EngineResult<()> {
    let agent = AgentKind::parse(agent)?;
    let input = read_hook_input()?;
    if input.get("agent_id").is_some_and(|value| !value.is_null()) {
        return Ok(());
    }
    let (Some(event), Some(session_id)) = (text(&input, "hook_event_name"), text(&input, "session_id")) else {
        return Ok(());
    };
    let root = root(&paths::state_root(&owner::account()?)?);
    let key = format!("{agent}:{session_id}");

    let mut store = Store::open(&root)?;
    let now = now_millis();
    if store.session(&key).is_none() {
        store.state.sessions.push(new_session(&key, agent, &session_id, now));
    }
    let session = store.session(&key).expect("the session was just inserted");
    session.updated = now;
    note_context(session, &input);
    let Some(approval) = apply_event(session, &event, &input) else {
        return Ok(());
    };
    store.commit()?;
    drop(store);

    if let Some(decision) = approval.and_then(|approval| await_answer(&root, &key, &approval)) {
        print_decision(decision);
    }
    Ok(())
}

fn read_answer(answer_file: &Path) -> Option<Option<&'static str>> {
    let raw = fs::read_to_string(answer_file).ok()?;
    Some(match raw.trim() {
        "allow" => Some("allow"),
        "deny" => Some("deny"),
        _ => None,
    })
}

fn holds(session: &Session, key: &str, approval: &Approval) -> bool {
    session.key == key && session.approval.as_ref().is_some_and(|pending| pending.id == approval.id)
}

fn still_pending(root: &Path, key: &str, approval: &Approval) -> bool {
    read_state(root)
        .ok()
        .is_some_and(|state| state.sessions.iter().any(|session| holds(session, key, approval)))
}

fn close_approval(root: &Path, key: &str, approval: &Approval) -> Option<&'static str> {
    let answer_file = answers_dir(root).join(&approval.id);
    let store = Store::open(root);
    let decision = read_answer(&answer_file).flatten();
    let _ = fs::remove_file(&answer_file);
    let mut store = store.ok()?;
    let session = store.session(key).filter(|session| holds(session, key, approval))?;
    session.approval = None;
    session.updated = now_millis();
    match decision {
        Some(_) => session.state = "working".to_owned(),
        None => session.question = Some(approval.summary.clone()),
    }
    let _ = store.commit();
    decision
}

/// Printing nothing when the wait ends unanswered is the agent's cue to put its
/// own prompt up in the terminal.
fn await_answer(root: &Path, key: &str, approval: &Approval) -> Option<&'static str> {
    let answer_file = answers_dir(root).join(&approval.id);
    let parent = getppid();
    while !answer_file.exists()
        && now_millis() < approval.expires
        && getppid() == parent
        && still_pending(root, key, approval)
    {
        std::thread::sleep(POLL);
    }
    close_approval(root, key, approval)
}

#[cfg(test)]
mod tests {
    use super::{
        answers_dir, apply_event, close_approval, cut, new_session, request_approval, summarize, typed,
        AgentKind, Store,
    };
    use crate::util::now_millis;
    use serde_json::json;

    #[test]
    fn an_answer_that_lands_as_the_wait_ends_is_taken_under_the_lock() {
        let root = std::env::temp_dir().join(format!("striked-agents-close-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let mut store = Store::open(&root).unwrap();
        let mut session = new_session("claude:s1", AgentKind::Claude, "s1", now_millis());
        let approval = request_approval(&mut session, &json!({ "tool_name": "Bash" }));
        store.state.sessions.push(session);
        store.commit().unwrap();
        drop(store);
        let answer_file = answers_dir(&root).join(&approval.id);
        std::fs::create_dir_all(answers_dir(&root)).unwrap();
        std::fs::write(&answer_file, "allow").unwrap();

        assert_eq!(close_approval(&root, "claude:s1", &approval), Some("allow"));

        assert!(!answer_file.exists(), "an orphan answer was left");
        let store = Store::open(&root).unwrap();
        assert_eq!(store.state.sessions[0].state, "working");
        drop(store);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn a_summary_is_the_argument_a_person_reads() {
        assert_eq!(summarize(&json!({ "command": "rm -rf build", "description": "x" })), "rm -rf build");
        assert_eq!(summarize(&json!({ "file_path": "/a/b.rs", "old_string": "x" })), "/a/b.rs");
        assert_eq!(summarize(&json!({ "questions": [{ "question": "Ship it?", "options": [] }] })), "Ship it?");
        assert_eq!(summarize(&json!({ "other": 1 })), "{\"other\":1}");
    }

    #[test]
    fn a_question_is_no_approval() {
        let mut session = new_session("claude:s1", AgentKind::Claude, "s1", now_millis());
        let input = json!({
            "tool_name": "AskUserQuestion",
            "tool_input": { "questions": [
                { "header": "Token proof", "question": "How should #2 close it?",
                  "options": [{ "label": "Runtime single-use" }, { "label": "Accept as-is" }] },
                { "question": "Second?", "options": [] },
            ] },
        });

        assert!(matches!(apply_event(&mut session, "PermissionRequest", &input), Some(None)));
        assert!(session.approval.is_none());
        assert_eq!(session.state, "blocked");
        assert_eq!(
            session.question.as_deref(),
            Some("Token proof · How should #2 close it?\n1. Runtime single-use\n2. Accept as-is\n+1 more"),
        );

        let notice = json!({ "notification_type": "agent_needs_input", "message": "Claude needs your input" });
        apply_event(&mut session, "Notification", &notice);
        assert!(session.question.as_deref().is_some_and(|line| line.starts_with("Token proof")));
    }

    #[test]
    fn a_cut_never_splits_a_character() {
        assert_eq!(cut("ñññ", 2), "ññ…");
        assert_eq!(cut("  ab  ", 5), "ab");
    }

    #[test]
    fn a_harness_turn_keeps_the_prompt_a_person_typed() {
        let mut session = new_session("claude:s1", AgentKind::Claude, "s1", now_millis());
        apply_event(&mut session, "UserPromptSubmit", &json!({ "prompt": "fix the tab strip" }));
        let notice = "<task-notification>\n<task-id>b1yu0brus</task-id>";
        apply_event(&mut session, "UserPromptSubmit", &json!({ "prompt": notice }));

        assert_eq!(session.prompt.as_deref(), Some("fix the tab strip"));
        assert_eq!(session.state, "working");
    }

    #[test]
    fn only_what_a_person_typed_is_their_turn() {
        assert_eq!(typed(AgentKind::Claude, "  <task-notification>x").as_deref(), None);
        let teammate = "Another Claude session sent a message:\n<teammate-message>";
        assert_eq!(typed(AgentKind::Claude, teammate).as_deref(), None);
        let command = "<command-message>commit</command-message>\n<command-name>/commit</command-name>\n\
            <command-args>only the engine</command-args>";
        assert_eq!(typed(AgentKind::Claude, command).as_deref(), Some("/commit only the engine"));
        assert_eq!(typed(AgentKind::Claude, "<command-name>/clear</command-name>").as_deref(), Some("/clear"));
        assert_eq!(typed(AgentKind::Claude, "<bash-input>ls</bash-input>").as_deref(), Some("! ls"));
        let lookalike = "<command-foo> why does this parse";
        assert_eq!(typed(AgentKind::Claude, lookalike).as_deref(), Some(lookalike));
        assert_eq!(typed(AgentKind::Codex, "<environment_context>").as_deref(), None);
        let typed_tag = "<system-reminder> is a tag";
        assert_eq!(typed(AgentKind::Codex, typed_tag).as_deref(), Some(typed_tag));
    }

    #[test]
    fn agent_kinds_keep_their_wire_names() {
        let names = ["claude", "codex", "opencode"];
        for (kind, name) in AgentKind::ALL.into_iter().zip(names) {
            assert_eq!(kind.name(), name);
            assert_eq!(serde_json::to_value(kind).unwrap(), json!(name));
            let parsed: AgentKind = serde_json::from_value(json!(name)).unwrap();
            assert_eq!(parsed, kind);
            assert_eq!(AgentKind::parse(name).unwrap(), kind);
        }
        let unknown = AgentKind::parse("gemini").unwrap_err();
        assert_eq!(unknown.message, "no agent kind gemini");
    }
}
