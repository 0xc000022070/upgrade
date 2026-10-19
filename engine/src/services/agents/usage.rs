use super::{cut, root, AgentKind};
use crate::owner;
use crate::paths;
use crate::protocol::{arg_bool, EngineError, EngineResult, ENGINE_VERSION};
use crate::util::{now_millis, write_atomic, write_atomic_unique, Durability, Perms, WritePolicy};
use nix::sys::signal::{killpg, SigSet, Signal};
use nix::unistd::Pid;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

const FRESH_MS: u64 = 60_000;
const DEADLINE: Duration = Duration::from_secs(10);
const ERROR_CHARS: usize = 160;
const ACCOUNT_ID: u64 = 2;
const LIMITS_ID: u64 = 3;
const LINE_BYTES: u64 = 1 << 20;
const STATUS_INPUT_BYTES: u64 = 1 << 20;
const STATUS_OUTPUT_BYTES: u64 = 1 << 20;
const STATUS_DEADLINE: Duration = Duration::from_secs(5);
const FIVE_HOURS_MIN: u64 = 300;
const SEVEN_DAYS_MIN: u64 = 10_080;
const HISTORY_MS: u64 = 9 * 24 * 3_600_000;
const HISTORY_SAMPLES: usize = 2_000;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Window {
    used_percent: f64,
    window_minutes: Option<u64>,
    resets_at: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Limit {
    id: String,
    name: Option<String>,
    reached: bool,
    windows: Vec<Window>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Credits {
    unlimited: bool,
    balance: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Account {
    agent: AgentKind,
    account: Option<String>,
    plan: Option<String>,
    captured: Option<u64>,
    limits: Vec<Limit>,
    credits: Option<Credits>,
    error: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    history: Vec<Sample>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Sample {
    at: u64,
    used: f64,
    resets: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
struct Captured {
    used_percentage: f64,
    resets_at: u64,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
struct Capture {
    captured: u64,
    five_hour: Option<Captured>,
    seven_day: Option<Captured>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Cache {
    checked: u64,
    accounts: Vec<Account>,
}

pub fn read(args: &Value, root: &Path) -> EngineResult<Value> {
    let fresh = arg_bool(args, "fresh", false)?;
    fs::create_dir_all(root)?;
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(root.join("usage.lock"))?;
    let entered = now_millis();
    let waited = Instant::now() + DEADLINE + Duration::from_secs(2);
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(fs::TryLockError::WouldBlock) if Instant::now() < waited => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Err(fs::TryLockError::WouldBlock) => {
                return match read_cache(root) {
                    Some(cache) => Ok(answer(cache.accounts, root)),
                    None => Err(EngineError::failed(
                        "another usage read held the cache too long",
                    )),
                };
            }
            Err(fs::TryLockError::Error(err)) => {
                return Err(EngineError::failed(format!(
                    "the usage cache could not be locked: {err}"
                )));
            }
        }
    }
    let cached = read_cache(root);
    if let Some(cache) = cached.as_ref().filter(|cache| {
        let now = now_millis();
        (cache.checked >= entered && cache.checked <= now) || (!fresh && is_fresh(cache, now))
    }) {
        return Ok(answer(cache.accounts.clone(), root));
    }
    let previous = cached.and_then(|cache| {
        cache
            .accounts
            .into_iter()
            .find(|account| account.agent == AgentKind::Codex)
    });
    let accounts: Vec<Account> = codex(previous.as_ref()).into_iter().collect();
    note_accounts(root, &accounts)?;
    let cache = Cache {
        checked: now_millis(),
        accounts,
    };
    write_atomic(
        &cache_path(root),
        &serde_json::to_vec(&cache).map_err(|err| EngineError::failed(err.to_string()))?,
        &WritePolicy {
            perms: Perms::Private,
            durability: Durability::None,
            tmp_suffix: ".tmp",
        },
    )?;
    Ok(answer(cache.accounts, root))
}

fn answer(mut accounts: Vec<Account>, root: &Path) -> Value {
    accounts.extend(claude(read_capture(root), &claude_sign_in(), now_millis()));
    for account in &mut accounts {
        account.history = read_history(root, account.agent);
    }
    json!({ "accounts": accounts })
}

fn note_accounts(root: &Path, accounts: &[Account]) -> EngineResult<()> {
    for account in accounts.iter().filter(|account| account.error.is_none()) {
        if let (Some(at), Some(window)) = (account.captured, weekly(&account.limits)) {
            note(root, account.agent, sample(at, window.used_percent, window.resets_at))?;
        }
    }
    Ok(())
}

fn weekly(limits: &[Limit]) -> Option<&Window> {
    limits.first()?.windows.iter().max_by_key(|window| window.window_minutes)
}

fn sample(at: u64, used: f64, resets: Option<u64>) -> Sample {
    Sample { at, used, resets }
}

fn history_path(root: &Path, agent: AgentKind) -> PathBuf {
    root.join(format!("{}-history.json", agent.name()))
}

fn read_history(root: &Path, agent: AgentKind) -> Vec<Sample> {
    fs::read(history_path(root, agent))
        .ok()
        .and_then(|raw| serde_json::from_slice(&raw).ok())
        .unwrap_or_default()
}

fn noted(mut history: Vec<Sample>, sample: Sample) -> Option<Vec<Sample>> {
    if history
        .last()
        .is_some_and(|last| last.at >= sample.at || (last.used == sample.used && last.resets == sample.resets))
    {
        return None;
    }
    let cutoff = sample.at.saturating_sub(HISTORY_MS);
    let old = history.iter().take_while(|kept| kept.at < cutoff).count();
    history.drain(..old.saturating_sub(1));
    history.push(sample);
    let over = history.len().saturating_sub(HISTORY_SAMPLES);
    history.drain(..over);
    Some(history)
}

fn note(root: &Path, agent: AgentKind, sample: Sample) -> EngineResult<()> {
    let Some(history) = noted(read_history(root, agent), sample) else {
        return Ok(());
    };
    write_atomic_unique(
        &history_path(root, agent),
        &serde_json::to_vec(&history).map_err(|err| EngineError::failed(err.to_string()))?,
        &WritePolicy {
            perms: Perms::Private,
            durability: Durability::None,
            tmp_suffix: ".tmp",
        },
    )?;
    Ok(())
}

fn cache_path(root: &Path) -> PathBuf {
    root.join("usage.json")
}

fn read_cache(root: &Path) -> Option<Cache> {
    serde_json::from_slice(&fs::read(cache_path(root)).ok()?).ok()
}

fn is_fresh(cache: &Cache, now: u64) -> bool {
    cache.checked <= now && now - cache.checked < FRESH_MS
}

fn capture_path(root: &Path) -> PathBuf {
    root.join("claude-usage.json")
}

fn read_capture(root: &Path) -> Option<Capture> {
    serde_json::from_slice(&fs::read(capture_path(root)).ok()?).ok()
}

fn captured(limits: &Value, key: &str) -> Option<Captured> {
    serde_json::from_value(limits.get(key)?.clone()).ok()
}

fn capture(input: &Value, now: u64) -> Option<Capture> {
    let limits = input.get("rate_limits").filter(|limits| limits.is_object())?;
    let capture = Capture {
        captured: now,
        five_hour: captured(limits, "five_hour"),
        seven_day: captured(limits, "seven_day"),
    };
    (capture.five_hour.is_some() || capture.seven_day.is_some()).then_some(capture)
}

fn newer(old: Option<Captured>, new: Option<Captured>) -> Option<Captured> {
    match (old, new) {
        (Some(old), Some(new)) => {
            let later = new.resets_at > old.resets_at
                || (new.resets_at == old.resets_at && new.used_percentage > old.used_percentage);
            Some(if later { new } else { old })
        }
        (old, new) => new.or(old),
    }
}

fn merged_capture(old: Option<Capture>, new: Capture) -> Option<Capture> {
    let Some(old) = old else {
        return Some(new);
    };
    let five_hour = newer(old.five_hour.clone(), new.five_hour);
    let seven_day = newer(old.seven_day.clone(), new.seven_day);
    (five_hour != old.five_hour || seven_day != old.seven_day).then_some(Capture {
        captured: new.captured,
        five_hour,
        seven_day,
    })
}

fn keep_capture(root: &Path, capture: Capture) -> EngineResult<()> {
    fs::create_dir_all(root)?;
    fs::set_permissions(root, fs::Permissions::from_mode(0o700))?;
    let lock = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(root.join("claude-usage.lock"))?;
    lock.lock()?;
    let Some(capture) = merged_capture(read_capture(root), capture) else {
        return Ok(());
    };
    write_atomic_unique(
        &capture_path(root),
        &serde_json::to_vec(&capture).map_err(|err| EngineError::failed(err.to_string()))?,
        &WritePolicy {
            perms: Perms::Private,
            durability: Durability::None,
            tmp_suffix: ".tmp",
        },
    )?;
    if let Some(week) = &capture.seven_day {
        note(
            root,
            AgentKind::Claude,
            sample(capture.captured, week.used_percentage, Some(week.resets_at)),
        )?;
    }
    Ok(())
}

fn claude_sign_in() -> Value {
    let path = match std::env::var_os("CLAUDE_CONFIG_DIR").filter(|dir| !dir.is_empty()) {
        Some(dir) => PathBuf::from(dir).join(".claude.json"),
        None => match paths::home() {
            Ok(home) => home.join(".claude.json"),
            Err(_) => return Value::Null,
        },
    };
    fs::read(path)
        .ok()
        .and_then(|raw| serde_json::from_slice::<SignIn>(&raw).ok())
        .map(|config| config.account)
        .unwrap_or_default()
}

#[derive(Deserialize)]
struct SignIn {
    #[serde(rename = "oauthAccount", default)]
    account: Value,
}

fn claude(capture: Option<Capture>, sign_in: &Value, now: u64) -> Option<Account> {
    let capture = capture?;
    let windows: Vec<Window> = [
        (FIVE_HOURS_MIN, capture.five_hour),
        (SEVEN_DAYS_MIN, capture.seven_day),
    ]
    .into_iter()
    .filter_map(|(minutes, window)| window.map(|window| (minutes, window)))
    .filter(|(_, window)| window.resets_at > now / 1000)
    .map(|(minutes, window)| Window {
        used_percent: window.used_percentage,
        window_minutes: Some(minutes),
        resets_at: Some(window.resets_at),
    })
    .collect();
    let limits = if windows.is_empty() {
        Vec::new()
    } else {
        vec![Limit {
            id: "claude".to_owned(),
            name: None,
            reached: windows.iter().any(|window| window.used_percent >= 100.0),
            windows,
        }]
    };
    Some(Account {
        agent: AgentKind::Claude,
        account: string(sign_in, "emailAddress"),
        plan: sign_in
            .get("organizationType")
            .and_then(Value::as_str)
            .and_then(|kind| kind.strip_prefix("claude_"))
            .filter(|plan| !plan.is_empty())
            .map(str::to_owned),
        captured: Some(capture.captured),
        limits,
        credits: None,
        error: None,
        history: Vec::new(),
    })
}

pub fn statusline(command: Option<&str>) -> i32 {
    let mut raw = Vec::new();
    let read = std::io::stdin()
        .lock()
        .take(STATUS_INPUT_BYTES + 1)
        .read_to_end(&mut raw);
    if read.is_err() || raw.len() as u64 > STATUS_INPUT_BYTES {
        return 0;
    }
    let Ok(state_root) = owner::account().and_then(|account| paths::state_root(&account)) else {
        return 0;
    };
    let root = root(&state_root);
    if let Some(capture) = serde_json::from_slice(&raw)
        .ok()
        .and_then(|input| capture(&input, now_millis()))
    {
        let _ = keep_capture(&root, capture);
    }
    if let Some(printed) = command.and_then(|command| chain(command, raw)) {
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(&printed).and_then(|()| stdout.flush());
    }
    0
}

fn chain(command: &str, input: Vec<u8>) -> Option<Vec<u8>> {
    let deadline = Instant::now() + STATUS_DEADLINE;
    let mut stopping = SigSet::empty();
    for signal in [Signal::SIGTERM, Signal::SIGINT, Signal::SIGHUP] {
        stopping.add(signal);
    }
    let _ = stopping.thread_block();
    let mut child = Command::new("/bin/sh")
        .arg("-c")
        .arg(command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .ok()?;
    let group = Pid::from_raw(child.id() as i32);
    // The child is reaped only under this lock, so a group still marked running has not had
    // its id handed to another.
    let running = Arc::new(Mutex::new(true));
    let watched = Arc::clone(&running);
    std::thread::spawn(move || {
        if stopping.wait().is_ok() {
            if *watched.lock().unwrap_or_else(PoisonError::into_inner) {
                let _ = killpg(group, Signal::SIGKILL);
            }
            std::process::exit(0);
        }
    });
    let mut stdin = child.stdin.take().expect("stdin is piped");
    std::thread::spawn(move || {
        let _ = stdin.write_all(&input);
    });
    let stdout = child.stdout.take().expect("stdout is piped");
    let (sender, output) = mpsc::channel();
    std::thread::spawn(move || {
        let mut printed = Vec::new();
        let _ = stdout.take(STATUS_OUTPUT_BYTES).read_to_end(&mut printed);
        let _ = sender.send(printed);
    });
    let printed = output
        .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        .ok();
    loop {
        let mut live = running.lock().unwrap_or_else(PoisonError::into_inner);
        match child.try_wait() {
            Ok(Some(_)) => {
                *live = false;
                break;
            }
            Ok(None) if printed.is_some() && Instant::now() < deadline => {
                drop(live);
                std::thread::sleep(Duration::from_millis(10));
            }
            _ => {
                let _ = killpg(group, Signal::SIGKILL);
                let _ = child.wait();
                *live = false;
                break;
            }
        }
    }
    printed
}

fn codex(previous: Option<&Account>) -> Option<Account> {
    let binary = find("codex", &search_dirs())?;
    match query(&binary) {
        Ok((account, limits)) => entry(&account, &limits, previous, now_millis()),
        Err(message) => previous.map(|_| failed(previous, &message)),
    }
}

fn search_dirs() -> Vec<PathBuf> {
    let mut dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).collect())
        .unwrap_or_default();
    let home = std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .or_else(owner::passwd_home);
    if let Some(home) = &home {
        dirs.push(home.join(".nix-profile/bin"));
    }
    if let Ok(user) = owner::account() {
        dirs.push(PathBuf::from(format!("/etc/profiles/per-user/{user}/bin")));
    }
    dirs.push(PathBuf::from("/run/current-system/sw/bin"));
    if let Some(home) = &home {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join(".npm-global/bin"));
    }
    dirs.push(PathBuf::from("/opt/homebrew/bin"));
    dirs.push(PathBuf::from("/usr/local/bin"));
    dirs
}

fn find(program: &str, dirs: &[PathBuf]) -> Option<PathBuf> {
    dirs.iter().map(|dir| dir.join(program)).find(|candidate| {
        fs::metadata(candidate)
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    })
}

fn child_path(binary: &Path) -> Option<std::ffi::OsString> {
    let dir = binary.parent()?.to_path_buf();
    let rest =
        std::env::var_os("PATH").map(|path| std::env::split_paths(&path).collect::<Vec<_>>());
    std::env::join_paths(std::iter::once(dir).chain(rest.into_iter().flatten())).ok()
}

fn requests() -> String {
    [
        json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": { "clientInfo": { "name": "striked", "version": ENGINE_VERSION } } }),
        json!({ "jsonrpc": "2.0", "method": "initialized" }),
        json!({ "jsonrpc": "2.0", "id": ACCOUNT_ID, "method": "account/read", "params": {} }),
        json!({ "jsonrpc": "2.0", "id": LIMITS_ID, "method": "account/rateLimits/read" }),
    ]
    .iter()
    .map(|request| format!("{request}\n"))
    .collect()
}

fn query(binary: &Path) -> Result<(Value, Value), String> {
    let mut command = Command::new(binary);
    command
        .arg("app-server")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0);
    if let Some(path) = child_path(binary) {
        command.env("PATH", path);
    }
    let mut child = command
        .spawn()
        .map_err(|err| format!("codex app-server could not start: {err}"))?;
    let stdout = child.stdout.take().expect("stdout is piped");
    let (sender, replies) = mpsc::channel();
    std::thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        while let Some(line) = bounded_line(&mut reader) {
            if let Ok(message) = serde_json::from_slice::<Value>(&line) {
                if sender.send(message).is_err() {
                    break;
                }
            }
        }
    });
    let mut stdin = child.stdin.take();
    let written = stdin.as_mut().map(|stdin| {
        stdin
            .write_all(requests().as_bytes())
            .and_then(|()| stdin.flush())
    });
    let answered = match written {
        Some(Err(err)) => Err(format!("codex app-server took no request: {err}")),
        _ => collect(&replies, Instant::now() + DEADLINE),
    };
    drop(stdin);
    let _ = killpg(Pid::from_raw(child.id() as i32), Signal::SIGKILL);
    let _ = child.wait();
    answered
}

fn bounded_line(reader: &mut impl BufRead) -> Option<Vec<u8>> {
    let mut skipping = false;
    loop {
        let mut line = Vec::new();
        let read = reader
            .by_ref()
            .take(LINE_BYTES)
            .read_until(b'\n', &mut line)
            .ok()?;
        if read == 0 {
            return None;
        }
        if !line.ends_with(b"\n") && read as u64 == LINE_BYTES {
            skipping = true;
        } else if skipping {
            skipping = false;
        } else {
            return Some(line);
        }
    }
}

fn collect(replies: &mpsc::Receiver<Value>, deadline: Instant) -> Result<(Value, Value), String> {
    let (mut account, mut limits) = (None, None);
    while account.is_none() || limits.is_none() {
        let left = deadline.saturating_duration_since(Instant::now());
        let message = match replies.recv_timeout(left) {
            Ok(message) => message,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                return Err("codex app-server did not answer in time".to_owned())
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return Err("codex app-server exited before it answered".to_owned())
            }
        };
        if message.get("method").is_some() {
            continue;
        }
        match message.get("id").and_then(Value::as_u64) {
            Some(ACCOUNT_ID) => account = Some(message),
            Some(LIMITS_ID) => limits = Some(message),
            _ => {}
        }
    }
    Ok((account.unwrap_or_default(), limits.unwrap_or_default()))
}

fn reply_error(reply: &Value) -> Option<String> {
    let error = reply.get("error")?;
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .unwrap_or("codex answered with an error");
    Some(message.to_owned())
}

fn failed(previous: Option<&Account>, message: &str) -> Account {
    let mut entry = previous.cloned().unwrap_or(Account {
        agent: AgentKind::Codex,
        account: None,
        plan: None,
        captured: None,
        limits: Vec::new(),
        credits: None,
        error: None,
        history: Vec::new(),
    });
    entry.error = Some(cut(message, ERROR_CHARS));
    entry
}

fn entry(account: &Value, limits: &Value, previous: Option<&Account>, now: u64) -> Option<Account> {
    if let Some(message) = reply_error(account) {
        return previous.map(|_| failed(previous, &message));
    }
    let signed_in = account
        .pointer("/result/account")
        .filter(|value| value.is_object())?;
    let email = string(signed_in, "email");
    let plan = string(signed_in, "planType");
    let Some(message) = reply_error(limits) else {
        let result = limits.get("result").unwrap_or(&Value::Null);
        let single = result.get("rateLimits").filter(|value| value.is_object());
        return Some(Account {
            agent: AgentKind::Codex,
            account: email,
            plan: plan.or_else(|| single.and_then(|single| string(single, "planType"))),
            captured: Some(now),
            limits: parse_limits(result),
            credits: single
                .and_then(|single| single.get("credits"))
                .or_else(|| result.pointer("/rateLimitsByLimitId/codex/credits"))
                .and_then(parse_credits),
            error: None,
            history: Vec::new(),
        });
    };
    let mut entry = failed(previous, &message);
    entry.account = email.or(entry.account);
    entry.plan = plan.or(entry.plan);
    Some(entry)
}

fn string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn parse_limits(result: &Value) -> Vec<Limit> {
    if let Some(by_id) = result.get("rateLimitsByLimitId").and_then(Value::as_object) {
        let mut limits: Vec<Limit> = by_id
            .iter()
            .filter(|(_, limit)| limit.is_object())
            .map(|(id, limit)| parse_limit(id, limit))
            .collect();
        limits.sort_by(|a, b| (a.id != "codex", &a.id).cmp(&(b.id != "codex", &b.id)));
        return limits;
    }
    result
        .get("rateLimits")
        .filter(|limit| limit.is_object())
        .map(|limit| {
            let id = limit
                .get("limitId")
                .and_then(Value::as_str)
                .unwrap_or("codex");
            vec![parse_limit(id, limit)]
        })
        .unwrap_or_default()
}

fn parse_limit(id: &str, limit: &Value) -> Limit {
    let reached = limit
        .get("rateLimitReachedType")
        .is_some_and(|value| !value.is_null())
        || limit.get("spendControlReached").and_then(Value::as_bool) == Some(true);
    Limit {
        id: id.to_owned(),
        name: string(limit, "limitName"),
        reached,
        windows: ["primary", "secondary"]
            .iter()
            .filter_map(|key| limit.get(*key))
            .filter_map(parse_window)
            .collect(),
    }
}

fn parse_window(window: &Value) -> Option<Window> {
    Some(Window {
        used_percent: window.get("usedPercent")?.as_f64()?,
        window_minutes: window.get("windowDurationMins").and_then(Value::as_u64),
        resets_at: window.get("resetsAt").and_then(Value::as_u64),
    })
}

fn parse_credits(credits: &Value) -> Option<Credits> {
    credits.as_object()?;
    Some(Credits {
        unlimited: credits
            .get("unlimited")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        balance: string(credits, "balance"),
    })
}

#[cfg(test)]
mod tests {
    use super::{
        bounded_line, capture, chain, claude, entry, is_fresh, merged_capture, noted, sample, Account, Cache,
        Capture, Captured, FRESH_MS, HISTORY_MS, LINE_BYTES,
    };
    use serde_json::{json, Value};

    fn signed_in() -> Value {
        json!({ "id": 2, "result": {
            "account": { "type": "chatgpt", "email": "fixture@localhost", "planType": "pro" },
            "requiresOpenaiAuth": true,
        } })
    }

    fn limit(id: &str, used: u64) -> Value {
        json!({
            "limitId": id, "limitName": null,
            "primary": { "usedPercent": used, "windowDurationMins": 300, "resetsAt": 1792386604u64 },
            "secondary": null,
            "credits": { "hasCredits": true, "unlimited": false, "balance": "1000" },
            "individualLimit": null, "spendControlReached": null, "planType": "pro",
            "rateLimitReachedType": null,
        })
    }

    fn read(account: &Value, limits: &Value, previous: Option<&Account>) -> Value {
        serde_json::to_value(entry(account, limits, previous, 7)).unwrap()
    }

    #[test]
    fn limits_by_id_put_codex_first() {
        let mut spark = limit("spark", 90);
        spark["limitName"] = json!("Spark");
        spark["rateLimitReachedType"] = json!("primary");
        let limits = json!({ "id": 3, "result": {
            "rateLimits": limit("codex", 12),
            "rateLimitsByLimitId": { "spark": spark, "codex": limit("codex", 12), "alpha": limit("alpha", 1) },
        } });

        let usage = read(&signed_in(), &limits, None);

        let ids: Vec<&str> = usage["limits"]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["codex", "alpha", "spark"]);
        assert_eq!(
            usage["limits"][2],
            json!({
                "id": "spark", "name": "Spark", "reached": true,
                "windows": [{ "used_percent": 90.0, "window_minutes": 300, "resets_at": 1792386604u64 }],
            })
        );
        assert_eq!(usage["account"], json!("fixture@localhost"));
        assert_eq!(usage["plan"], json!("pro"));
        assert_eq!(usage["captured"], json!(7));
        assert_eq!(
            usage["credits"],
            json!({ "unlimited": false, "balance": "1000" })
        );
        assert_eq!(usage["error"], Value::Null);
    }

    #[test]
    fn a_single_limit_keeps_both_windows() {
        let mut single = limit("codex", 12);
        single["secondary"] =
            json!({ "usedPercent": 34, "windowDurationMins": 10080, "resetsAt": null });
        single["spendControlReached"] = json!(true);
        let limits = json!({ "id": 3, "result": { "rateLimits": single } });

        let usage = read(&signed_in(), &limits, None);

        assert_eq!(
            usage["limits"],
            json!([{
                "id": "codex", "name": null, "reached": true,
                "windows": [
                    { "used_percent": 12.0, "window_minutes": 300, "resets_at": 1792386604u64 },
                    { "used_percent": 34.0, "window_minutes": 10080, "resets_at": null },
                ],
            }])
        );
    }

    #[test]
    fn a_signed_out_codex_is_no_account() {
        let account = json!({ "id": 2, "result": { "account": null, "requiresOpenaiAuth": true } });
        let limits = json!({ "id": 3, "result": { "rateLimits": limit("codex", 1) } });
        assert!(entry(&account, &limits, None, 7).is_none());
    }

    #[test]
    fn a_failed_read_keeps_the_last_good_one() {
        let good = json!({ "id": 3, "result": { "rateLimits": limit("codex", 12) } });
        let previous = entry(&signed_in(), &good, None, 7).unwrap();
        let long = format!("failed to fetch codex rate limits: {}", "x".repeat(400));
        let failure = json!({ "error": { "code": -32603, "message": long }, "id": 3 });

        let usage = entry(&signed_in(), &failure, Some(&previous), 99).unwrap();

        assert_eq!(usage.captured, Some(7));
        assert_eq!(usage.limits, previous.limits);
        assert_eq!(usage.credits, previous.credits);
        let error = usage.error.unwrap();
        assert!(error.starts_with("failed to fetch codex rate limits: x"));
        assert_eq!(error.chars().count(), 161);

        let first = entry(&signed_in(), &failure, None, 99).unwrap();
        assert_eq!((first.captured, first.limits.len()), (None, 0));
        assert_eq!(first.account.as_deref(), Some("fixture@localhost"));
    }

    #[test]
    fn a_failed_first_read_is_no_card() {
        let refused =
            json!({ "id": 2, "error": { "code": -32601, "message": "method not found" } });
        assert_eq!(read(&refused, &json!({}), None), Value::Null);
    }

    #[test]
    fn a_cache_is_served_for_a_minute() {
        let cache = Cache {
            checked: 1_000,
            accounts: Vec::new(),
        };
        assert!(is_fresh(&cache, 1_000 + FRESH_MS - 1));
        assert!(!is_fresh(&cache, 1_000 + FRESH_MS));
        assert!(
            !is_fresh(&cache, 0),
            "a cache from the future is a clock that moved"
        );
    }

    #[test]
    fn an_overlong_line_is_dropped_and_the_next_one_read() {
        let mut stream = vec![b'x'; LINE_BYTES as usize * 2 + 3];
        stream.extend_from_slice(b"\n{}\ntail");
        let mut reader = std::io::Cursor::new(stream);
        assert_eq!(bounded_line(&mut reader).as_deref(), Some(&b"{}\n"[..]));
        assert_eq!(bounded_line(&mut reader).as_deref(), Some(&b"tail"[..]));
        assert_eq!(bounded_line(&mut reader), None);
    }

    fn status_input(five_hour_resets: u64) -> Value {
        json!({
            "session_id": "s1",
            "rate_limits": {
                "five_hour": { "used_percentage": 100, "resets_at": five_hour_resets },
                "seven_day": { "used_percentage": 41.2, "resets_at": 1_900_000_000u64 },
                "spend_limit": { "used_percentage": 62.8, "resets_at": 1_900_000_000u64 },
            },
        })
    }

    #[test]
    fn a_status_line_without_rate_limits_captures_nothing() {
        assert!(capture(&json!({ "session_id": "s1" }), 7).is_none());
        assert!(capture(&json!({ "rate_limits": {} }), 7).is_none());
        let half = capture(&json!({ "rate_limits": { "seven_day": { "used_percentage": 3, "resets_at": 9 } } }), 7)
            .unwrap();
        assert_eq!((half.five_hour.is_none(), half.seven_day.is_some()), (true, true));
    }

    fn window(used_percentage: f64, resets_at: u64) -> Option<Captured> {
        Some(Captured { used_percentage, resets_at })
    }

    #[test]
    fn a_capture_keeps_the_newer_of_each_window() {
        let old = || Capture { captured: 1, five_hour: window(20.0, 100), seven_day: window(40.0, 900) };
        let older = Capture { captured: 2, five_hour: window(90.0, 50), seven_day: window(10.0, 900) };
        assert_eq!(merged_capture(Some(old()), older), None);
        let half = Capture { captured: 2, five_hour: None, seven_day: window(40.0, 900) };
        assert_eq!(merged_capture(Some(old()), half), None);

        let grown = Capture { captured: 3, five_hour: window(5.0, 400), seven_day: window(41.0, 900) };
        assert_eq!(
            merged_capture(Some(old()), grown),
            Some(Capture { captured: 3, five_hour: window(5.0, 400), seven_day: window(41.0, 900) })
        );
        let first = Capture { captured: 4, five_hour: None, seven_day: window(1.0, 2) };
        assert_eq!(merged_capture(None, first).map(|capture| capture.captured), Some(4));
    }

    #[test]
    fn a_capture_reads_back_as_the_claude_card() {
        let sign_in = json!({ "emailAddress": "fixture@localhost", "organizationType": "claude_max" });
        let card = claude(capture(&status_input(1_800_000_000), 7), &sign_in, 1_700_000_000_000).unwrap();
        assert_eq!(
            serde_json::to_value(card).unwrap(),
            json!({
                "agent": "claude", "account": "fixture@localhost", "plan": "max", "captured": 7,
                "limits": [{ "id": "claude", "name": null, "reached": true, "windows": [
                    { "used_percent": 100.0, "window_minutes": 300, "resets_at": 1_800_000_000u64 },
                    { "used_percent": 41.2, "window_minutes": 10080, "resets_at": 1_900_000_000u64 },
                ] }],
                "credits": null, "error": null,
            })
        );
    }

    #[test]
    fn a_window_whose_reset_has_passed_is_dropped() {
        let now = 1_850_000_000_000;
        let card = claude(capture(&status_input(1_800_000_000), 7), &Value::Null, now).unwrap();
        assert_eq!(card.limits.len(), 1);
        assert_eq!(card.limits[0].windows.len(), 1);
        assert_eq!(card.limits[0].windows[0].window_minutes, Some(10080));
        assert!(!card.limits[0].reached);
        assert_eq!((card.account, card.plan), (None, None));

        let gone = claude(capture(&status_input(1_800_000_000), 7), &Value::Null, 1_950_000_000_000).unwrap();
        assert!(gone.limits.is_empty());
        assert_eq!(gone.captured, Some(7));
        assert_eq!(gone.error, None);
    }

    #[test]
    fn history_notes_each_change_and_forgets_past_nine_days() {
        let day = HISTORY_MS / 9;
        let first = noted(Vec::new(), sample(day, 1.0, Some(5))).unwrap();
        assert_eq!(noted(first.clone(), sample(2 * day, 1.0, Some(5))), None);
        assert_eq!(noted(first.clone(), sample(day, 4.0, Some(5))), None, "a sample from the past");

        let mut history = first;
        for at in 2..=12 {
            history = noted(history, sample(at * day, at as f64, Some(5))).unwrap();
        }
        let kept: Vec<u64> = history.iter().map(|kept| kept.at / day).collect();
        assert_eq!(kept, [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], "the last one past the cutoff is the baseline");
    }

    #[test]
    fn no_capture_is_no_claude_card() {
        assert!(claude(None, &json!({ "emailAddress": "fixture@localhost" }), 7).is_none());
    }

    #[test]
    fn the_chained_status_line_gets_the_same_input_and_prints_through() {
        let printed = chain("tr a-z A-Z; printf ' done'", b"statusline".to_vec()).unwrap();
        assert_eq!(printed, b"STATUSLINE done");
        assert_eq!(chain("exit 3", Vec::new()).unwrap(), b"");
    }
}
