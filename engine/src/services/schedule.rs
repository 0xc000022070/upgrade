use crate::paths;
use crate::protocol::{arg_str, arg_u64_opt, EngineError, EngineResult};
use crate::services::run;
use crate::util::now_millis;
use chrono::{LocalResult, NaiveDate, TimeZone, Utc};
use chrono_tz::Tz;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;

pub const SERVICE: &str = "schedule/1";
pub const OPS: &[&str] = &[
    "inspect",
    "setup",
    "list",
    "get",
    "save",
    "pause",
    "resume",
    "run",
    "history",
    "output",
    "usage",
    "pause_scope",
    "resume_scope",
];

const SCHEMA_VERSION: u32 = 1;
const MAX_OUTPUT: u64 = 64 * 1024;
const MAX_HISTORY: usize = 1000;
const MAX_SCHEDULES: usize = 200;
const PAGE: usize = 32;
/// A slot the tick reaches this long after it was due ran while nothing was watching.
/// It is recorded as missed rather than started late, because an agent run started an
/// hour after its time is not the run the user asked for.
const MISSED_AFTER: i64 = 300;
/// Two at once. An agent run is not cheap, and a machine that fell behind should not
/// answer by starting everything it owes at the same moment.
const MAX_ACTIVE: usize = 2;

fn now_secs() -> i64 {
    (now_millis() / 1000) as i64
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Job {
    id: String,
    revision: u64,
    title: String,
    directory: String,
    agent: String,
    model: String,
    prompt: String,
    repeat: String,
    date: String,
    time: String,
    timezone: String,
    timeout: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Entry {
    job: Job,
    enabled: bool,
    next_due: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct RunRecord {
    id: String,
    schedule: String,
    slot: String,
    title: String,
    started: i64,
    /// Set only for a run that never reached a job — a missed slot, or a launch that
    /// did not happen. Otherwise the supervised job is what says how the run ended,
    /// and asking it is what keeps the two from disagreeing.
    #[serde(default)]
    settled: Option<String>,
    #[serde(default)]
    job: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    error: String,
    #[serde(default)]
    installed: bool,
    #[serde(default)]
    schedules: Vec<Entry>,
    #[serde(default)]
    runs: Vec<RunRecord>,
}

fn scope_root(state_root: &Path, scope: &str) -> EngineResult<PathBuf> {
    // The scope names a directory, and it is the plugin's own namespace rather than
    // anything the machine chose, so it is checked before it is ever joined to a path.
    if scope.len() != 64
        || !scope
            .chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_uppercase())
    {
        return Err(EngineError::bad_request("scope is not a plugin namespace"));
    }
    Ok(state_root.join("schedules").join(scope))
}

fn identifier(value: &str) -> EngineResult<&str> {
    let ok = !value.is_empty()
        && value.len() <= 80
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
    if ok {
        Ok(value)
    } else {
        Err(EngineError::bad_request("invalid identifier"))
    }
}

fn no_symlink(path: &Path) -> EngineResult<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => Err(EngineError::denied(format!(
            "refusing a linked scheduler path: {}",
            paths::display(path)
        ))),
        _ => Ok(()),
    }
}

/// The state of one scope, held under an exclusive lock for as long as the call runs.
/// A tick, a save from the phone and a manual run can all arrive at once, and the lock
/// is what makes the read-modify-write between them a single step.
struct Store {
    root: PathBuf,
    state_root: PathBuf,
    lock: fs::File,
    state: State,
}

impl Store {
    fn open(state_root: &Path, scope: &str) -> EngineResult<Self> {
        let root = scope_root(state_root, scope)?;
        no_symlink(&root)?;
        fs::create_dir_all(&root)?;
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700))?;

        let lock = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(root.join("lock"))?;
        if unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) } == -1 {
            return Err(EngineError::failed(format!(
                "the scheduler state could not be locked: {}",
                std::io::Error::last_os_error()
            )));
        }

        let file = root.join("state.json");
        no_symlink(&file)?;
        let state = match fs::read_to_string(&file) {
            Ok(raw) => serde_json::from_str::<State>(&raw).map_err(|err| {
                EngineError::failed(format!("the scheduler state is unreadable: {err}"))
            })?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => State::default(),
            Err(err) => return Err(err.into()),
        };
        if state.version != 0 && state.version != SCHEMA_VERSION {
            return Err(EngineError::unsupported(
                "unsupported scheduler data version",
            ));
        }

        Ok(Self {
            root,
            state_root: state_root.to_path_buf(),
            lock,
            state,
        })
    }

    fn commit(&mut self) -> EngineResult<()> {
        self.state.version = SCHEMA_VERSION;
        let file = self.root.join("state.json");
        no_symlink(&file)?;
        let tmp = self.root.join("state.json.tmp");
        fs::write(
            &tmp,
            serde_json::to_vec(&self.state).map_err(|err| EngineError::failed(err.to_string()))?,
        )?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
        fs::rename(tmp, file)?;
        Ok(())
    }

    fn entry(&self, id: &str) -> EngineResult<&Entry> {
        self.state
            .schedules
            .iter()
            .find(|entry| entry.job.id == id)
            .ok_or_else(|| EngineError::not_found("schedule is unavailable"))
    }
}

impl Drop for Store {
    fn drop(&mut self) {
        unsafe { libc::flock(self.lock.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn parse_hhmm(value: &str) -> Option<(u32, u32)> {
    let (hour, minute) = value.split_once(':')?;
    if hour.len() != 2 || minute.len() != 2 {
        return None;
    }
    let hour: u32 = hour.parse().ok()?;
    let minute: u32 = minute.parse().ok()?;
    (hour < 24 && minute < 60).then_some((hour, minute))
}

/// The next moment strictly after `now` at which this schedule is due, or nothing if
/// it has none left.
///
/// A wall clock is not a line: the hour a schedule names can be skipped by a spring
/// forward and can happen twice in an autumn. A skipped day is passed over rather than
/// silently moved, and a doubled one fires on the first of the two.
fn next_due(job: &Job, now: i64) -> Option<i64> {
    let zone: Tz = job.timezone.parse().ok()?;
    let (hour, minute) = parse_hhmm(&job.time)?;
    let start = if job.repeat == "once" {
        NaiveDate::parse_from_str(&job.date, "%Y-%m-%d").ok()?
    } else {
        Utc.timestamp_opt(now, 0)
            .single()?
            .with_timezone(&zone)
            .date_naive()
    };
    let span = if job.repeat == "daily" { 370 } else { 1 };
    for offset in 0..span {
        let Some(day) = start.checked_add_signed(chrono::Duration::days(offset)) else {
            break;
        };
        let Some(local) = day.and_hms_opt(hour, minute, 0) else {
            continue;
        };
        let stamp = match zone.from_local_datetime(&local) {
            LocalResult::None => continue,
            LocalResult::Single(value) => value.timestamp(),
            LocalResult::Ambiguous(earlier, _) => earlier.timestamp(),
        };
        if stamp > now {
            return Some(stamp);
        }
    }
    None
}

fn label(stamp: i64, zone: &str) -> String {
    let Ok(zone) = zone.parse::<Tz>() else {
        return "Finished".into();
    };
    match Utc.timestamp_opt(stamp, 0).single() {
        Some(value) => value
            .with_timezone(&zone)
            .format("%Y-%m-%dT%H:%M%:z")
            .to_string(),
        None => "Finished".into(),
    }
}

fn utc_label(stamp: i64) -> String {
    match Utc.timestamp_opt(stamp, 0).single() {
        Some(value) => value.format("%Y-%m-%dT%H:%M:%S+00:00").to_string(),
        None => String::new(),
    }
}

fn text(value: &Value, key: &str, limit: usize) -> EngineResult<String> {
    let raw = value
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| EngineError::bad_request(format!("invalid {key}")))?;
    if raw.trim().is_empty() || raw.len() > limit || raw.contains('\0') {
        return Err(EngineError::bad_request(format!("invalid {key}")));
    }
    Ok(raw.to_owned())
}

fn integer(value: &Value, key: &str, min: u64, max: u64) -> EngineResult<u64> {
    let raw = value
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| EngineError::bad_request(format!("invalid {key}")))?;
    if raw < min || raw > max {
        return Err(EngineError::bad_request(format!("invalid {key}")));
    }
    Ok(raw)
}

const FIELDS: &[&str] = &[
    "id",
    "revision",
    "title",
    "directory",
    "agent",
    "model",
    "prompt",
    "repeat",
    "date",
    "time",
    "timezone",
    "timeout",
];

fn validate(value: &Value, now: i64) -> EngineResult<Job> {
    let Value::Object(map) = value else {
        return Err(EngineError::bad_request("invalid schedule"));
    };
    if let Some(unknown) = map.keys().find(|key| !FIELDS.contains(&key.as_str())) {
        return Err(EngineError::bad_request(format!(
            "unknown schedule field {unknown}"
        )));
    }

    let directory = text(value, "directory", 2048)?;
    if !Path::new(&directory).is_absolute() || !Path::new(&directory).is_dir() {
        return Err(EngineError::bad_request(
            "choose an existing absolute repository directory",
        ));
    }

    let agent = text(value, "agent", 200)?;
    if agent != "codex" && agent != "claude" {
        return Err(EngineError::bad_request("unsupported agent"));
    }

    let model = match value.get("model").and_then(Value::as_str) {
        None | Some("") => String::new(),
        Some(raw) => {
            let ok = raw.len() <= 100
                && raw
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '/' | '-'));
            if !ok {
                return Err(EngineError::bad_request("invalid model"));
            }
            raw.to_owned()
        }
    };

    let repeat = text(value, "repeat", 200)?;
    let time = text(value, "time", 200)?;
    if (repeat != "daily" && repeat != "once") || parse_hhmm(&time).is_none() {
        return Err(EngineError::bad_request("choose a daily or one-shot time"));
    }

    let timezone = text(value, "timezone", 100)?;
    if timezone.parse::<Tz>().is_err() {
        return Err(EngineError::bad_request("unknown IANA timezone"));
    }

    let date = match repeat.as_str() {
        "once" => {
            let raw = text(value, "date", 200)?;
            if NaiveDate::parse_from_str(&raw, "%Y-%m-%d").is_err() {
                return Err(EngineError::bad_request("invalid date"));
            }
            raw
        }
        _ => value
            .get("date")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned(),
    };

    let job = Job {
        id: identifier(
            value
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| EngineError::bad_request("invalid id"))?,
        )?
        .to_owned(),
        revision: integer(value, "revision", 0, 9_007_199_254_740_991)?,
        title: text(value, "title", 120)?,
        directory,
        agent,
        model,
        prompt: text(value, "prompt", 16000)?,
        repeat,
        date,
        time,
        timezone,
        timeout: integer(value, "timeout", 60, 14400)?,
    };

    if next_due(&job, now).is_none() {
        return Err(EngineError::bad_request(
            "scheduled time is past or does not exist in that timezone",
        ));
    }
    Ok(job)
}

fn which(program: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|dir| dir.join(program))
        .find(|candidate| {
            fs::metadata(candidate)
                .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
                .unwrap_or(false)
        })
}

fn captured(program: &str, args: &[&str]) -> Option<(bool, String)> {
    which(program)?;
    let output = Command::new(program).args(args).output().ok()?;
    Some((
        output.status.success(),
        String::from_utf8_lossy(&output.stdout).trim().to_owned(),
    ))
}

fn host_timezone() -> String {
    if cfg!(target_os = "macos") {
        // macOS keeps the choice as a link into the zoneinfo tree, and the zone is the
        // part of the target below it.
        if let Ok(target) = fs::read_link("/etc/localtime") {
            let target = paths::display(&target);
            if let Some((_, zone)) = target.split_once("zoneinfo/") {
                if !zone.is_empty() {
                    return zone.to_owned();
                }
            }
        }
        return "UTC".into();
    }
    match captured("timedatectl", &["show", "--property=Timezone", "--value"]) {
        Some((true, value)) if !value.is_empty() => value,
        _ => "UTC".into(),
    }
}

/// What this machine can actually do unattended, as opposed to what the engine carries.
///
/// A schedule is a promise to run while the phone is elsewhere, so a host that cannot
/// keep that promise says so here rather than accepting the schedule and missing it.
fn probe() -> Value {
    let agents: Vec<&str> = ["codex", "claude"]
        .into_iter()
        .filter(|agent| which(agent).is_some())
        .collect();

    let (supported, reason) = if cfg!(target_os = "macos") {
        let has_launchd = which("launchctl").is_some();
        (
            has_launchd,
            if has_launchd {
                ""
            } else {
                "launchctl is required for unattended runs"
            },
        )
    } else if cfg!(target_os = "linux") {
        let user_service = matches!(
            captured("systemctl", &["--user", "show-environment"]),
            Some((true, _))
        );
        // Without linger the user's systemd instance stops at logout, and a timer that
        // only runs while someone is logged in is not unattended.
        let linger = matches!(
            captured(
                "loginctl",
                &[
                    "show-user",
                    &unsafe { libc::getuid() }.to_string(),
                    "--property=Linger",
                    "--value",
                ],
            ),
            Some((true, ref value)) if value == "yes"
        );
        (
            user_service && linger,
            if user_service && linger {
                ""
            } else {
                "a systemd user service and login linger are required for unattended runs"
            },
        )
    } else {
        (
            false,
            "this platform has no unattended timer the engine can use",
        )
    };

    json!({
        "api_version": SCHEMA_VERSION,
        "platform": paths::platform(),
        "supported": supported,
        "reason": reason,
        "agents": agents,
        "timezone": host_timezone(),
    })
}

const TIMER_PREFIX: &str = "dazzle-schedule-";

fn timer_name(scope: &str) -> String {
    format!("{TIMER_PREFIX}{scope}")
}

fn unit_dir() -> EngineResult<PathBuf> {
    Ok(std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or(paths::home()?.join(".config"))
        .join("systemd/user"))
}

/// Takes every schedule timer this account has off the machine, whichever scope asked
/// for it, and answers with what it removed.
///
/// A timer is the one thing the engine leaves outside its state directory: it belongs
/// to a manager, not to a file tree. Removing the state without this leaves a loaded
/// job ticking once a minute against a directory that is no longer there, and nothing
/// left on the machine names it.
pub(crate) fn remove_timers() -> Vec<String> {
    if cfg!(target_os = "macos") {
        let Ok(dir) = paths::home().map(|home| home.join("Library/LaunchAgents")) else {
            return Vec::new();
        };
        return remove_launchd_timers(&dir);
    }
    let Ok(dir) = unit_dir() else {
        return Vec::new();
    };
    remove_systemd_timers(&dir)
}

fn mine(name: &str) -> bool {
    name.starts_with(TIMER_PREFIX)
}

/// The directory is a parameter rather than read here so that both of these are one call
/// away on either platform. `cfg!` picks a branch at compile time, so a suite run on one
/// platform cannot fail on the other's branch: it can only have no opinion about it.
pub(crate) fn remove_launchd_timers(dir: &Path) -> Vec<String> {
    let mut removed = Vec::new();
    let target = format!("gui/{}", unsafe { libc::getuid() });
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(label) = name.strip_suffix(".plist").filter(|label| mine(label)) else {
            continue;
        };
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("{target}/{label}")])
            .output();
        if fs::remove_file(entry.path()).is_ok() {
            removed.push(label.to_string());
        }
    }
    removed
}

pub(crate) fn remove_systemd_timers(dir: &Path) -> Vec<String> {
    let mut removed = Vec::new();
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !mine(&name) {
            continue;
        }
        if name.ends_with(".timer") {
            let _ = Command::new("systemctl")
                .args(["--user", "disable", "--now", &name])
                .output();
        }
        if fs::remove_file(entry.path()).is_ok() {
            removed.push(name);
        }
    }
    if !removed.is_empty() {
        let _ = Command::new("systemctl")
            .args(["--user", "daemon-reload"])
            .output();
        // A unit that failed is held by name in the manager long after its file is gone,
        // so without this the account is left with dazzle entries under `--failed` that
        // no file on the machine explains and nothing but this can clear.
        let _ = Command::new("systemctl")
            .arg("--user")
            .arg("reset-failed")
            .args(&removed)
            .output();
    }
    removed
}

fn timer_active(scope: &str) -> bool {
    let name = timer_name(scope);
    if cfg!(target_os = "macos") {
        matches!(captured("launchctl", &["list", &name]), Some((true, _)))
    } else {
        matches!(
            captured(
                "systemctl",
                &["--user", "is-active", &format!("{name}.timer")]
            ),
            Some((true, _))
        )
    }
}

fn write_private(path: &Path, body: &str) -> EngineResult<()> {
    no_symlink(path)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    // Appended rather than substituted: the timer's two units differ only in their
    // extension, and replacing it would give both the same temporary name.
    let tmp = path.with_file_name(format!(
        "{}.tmp",
        path.file_name().unwrap_or_default().to_string_lossy()
    ));
    fs::write(&tmp, body)?;
    fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    fs::rename(tmp, path)?;
    Ok(())
}

fn engine_path() -> EngineResult<String> {
    std::env::current_exe()
        .map(|path| paths::display(&path))
        .map_err(|err| EngineError::failed(format!("the engine cannot locate itself: {err}")))
}

/// The PATH the account had when it asked for the timer, to be pinned into the timer.
///
/// The manager that runs a tick starts from its own environment, not the caller's:
/// launchd hands a job /usr/bin:/bin:/usr/sbin:/sbin, and an agent installed into a
/// user profile is on neither that nor, on some machines, the systemd user manager's.
/// `inspect` answers on the caller's PATH, so without this the host reports an agent it
/// can find now and cannot exec later, and every unattended run fails on a missing
/// file while the same schedule run by hand succeeds.
fn install_path() -> Option<String> {
    std::env::var("PATH").ok().filter(|path| !path.is_empty())
}

fn xml_escape(raw: &str) -> String {
    raw.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// systemd reads the value of an Environment= assignment as a quoted word, so the two
/// characters that end or escape that word have to be spelled out.
fn unit_escape(raw: &str) -> String {
    raw.replace('\\', "\\\\").replace('"', "\\\"")
}

pub(crate) fn agent_plist(
    name: &str,
    engine: &str,
    scope: &str,
    state: &str,
    path: Option<&str>,
) -> String {
    let path_entry = path
        .map(|path| format!("<key>PATH</key><string>{}</string>", xml_escape(path)))
        .unwrap_or_default();
    let engine = xml_escape(engine);
    let state = xml_escape(state);
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{name}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{engine}</string>
    <string>__tick</string>
    <string>{scope}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>{path_entry}<key>DAZZLE_ENGINE_STATE</key><string>{state}</string></dict>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
"#
    )
}

// KillMode=process, because the whole point of a tick is what it leaves behind. A tick
// starts a supervisor and returns, and under the default systemd answers that return by
// killing everything left in the unit's cgroup: the supervisor dies before it can write
// down the pid of the agent it just started, and the run sits at `starting` with nobody
// able to say otherwise. setsid does not escape this; a cgroup is not a session.
pub(crate) fn dispatch_unit(engine: &str, scope: &str, state: &str, path: Option<&str>) -> String {
    let path_line = path
        .map(|path| format!("Environment=\"PATH={}\"\n", unit_escape(path)))
        .unwrap_or_default();
    format!(
        "[Unit]\nDescription=Dazzle agent schedule dispatch\n\
         [Service]\nType=oneshot\nKillMode=process\n\
         ExecStart=\"{}\" __tick \"{scope}\"\n\
         Environment=\"DAZZLE_ENGINE_STATE={}\"\n{path_line}\
         TimeoutStartSec=30\n",
        unit_escape(engine),
        unit_escape(state)
    )
}

/// Puts the per-minute timer on the machine. It runs the same binary the user already
/// declared, in the one mode that exists for it, and nothing else is left behind.
fn install_timer(scope: &str) -> EngineResult<()> {
    let engine = engine_path()?;
    let name = timer_name(scope);
    // The base and not the owner's root below it: the root is the base with the owner
    // joined on, so a unit carrying the root would join the owner on twice when it ran
    // and tick against a directory nothing writes to. Pinned into the unit rather than
    // left to the environment, because the manager that runs the timer is not the
    // shell that installed it and need not agree about where XDG_STATE_HOME points.
    let state = paths::display(&paths::state_base()?);

    if cfg!(target_os = "macos") {
        let plist = agent_plist(&name, &engine, scope, &state, install_path().as_deref());
        let path = paths::home()?.join(format!("Library/LaunchAgents/{name}.plist"));
        write_private(&path, &plist)?;
        let target = format!("gui/{}", unsafe { libc::getuid() });
        // bootout first, so a reinstall replaces the agent instead of failing on the
        // label already being loaded.
        let _ = Command::new("launchctl")
            .args(["bootout", &format!("{target}/{name}")])
            .output();
        let output = Command::new("launchctl")
            .args(["bootstrap", &target, &paths::display(&path)])
            .output()
            .map_err(|err| EngineError::failed(format!("launchctl did not run: {err}")))?;
        if !output.status.success() {
            return Err(EngineError::failed(format!(
                "the timer could not be loaded: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        return Ok(());
    }

    let service = dispatch_unit(&engine, scope, &state, install_path().as_deref());
    let timer = "[Unit]\nDescription=Dazzle agent schedules\n\
                 [Timer]\nOnCalendar=*-*-* *:*:00\nAccuracySec=1s\nPersistent=true\n\
                 [Install]\nWantedBy=timers.target\n";

    let base = unit_dir()?;
    write_private(&base.join(format!("{name}.service")), &service)?;
    write_private(&base.join(format!("{name}.timer")), timer)?;

    for args in [
        vec!["--user", "daemon-reload"],
        vec!["--user", "enable", "--now", &format!("{name}.timer")],
    ] {
        let output = Command::new("systemctl")
            .args(&args)
            .output()
            .map_err(|err| EngineError::failed(format!("systemctl did not run: {err}")))?;
        if !output.status.success() {
            return Err(EngineError::failed(format!(
                "the timer could not be enabled: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
    }
    Ok(())
}

struct Outcome {
    status: String,
    finished: Option<i64>,
    exit_code: Option<i32>,
}

/// A run's outcome is the supervised job's, read back rather than copied. Nothing
/// writes a run's ending down twice, so there is no pair of records that can disagree.
fn outcome(record: &RunRecord, state_root: &Path) -> Outcome {
    if let Some(status) = &record.settled {
        return Outcome {
            status: status.clone(),
            finished: Some(record.started),
            exit_code: None,
        };
    }
    let Some(job) = &record.job else {
        return Outcome {
            status: "failed".into(),
            finished: Some(record.started),
            exit_code: None,
        };
    };
    let Ok(dir) = run::job_dir(state_root, job) else {
        return Outcome {
            status: "interrupted".into(),
            finished: None,
            exit_code: None,
        };
    };
    let Ok(status) = run::read_status(&dir) else {
        return Outcome {
            status: "interrupted".into(),
            finished: None,
            exit_code: None,
        };
    };
    let status = run::liveness_checked(&dir, status);
    let finished = status.finished.map(|value| (value / 1000) as i64);
    let name = match status.state.as_str() {
        "starting" | "running" => "running",
        "lost" => "interrupted",
        "exited" if status.timed_out => "timeout",
        "exited" if status.cancelled => "canceled",
        "exited" if status.code == Some(0) => "completed",
        _ => "failed",
    };
    Outcome {
        status: name.into(),
        finished,
        exit_code: status.code,
    }
}

fn is_active(status: &str) -> bool {
    status == "queued" || status == "running"
}

fn summary(entry: &Entry, full: bool) -> Value {
    let mut value = if full {
        serde_json::to_value(&entry.job).unwrap_or_else(|_| json!({}))
    } else {
        json!({
            "id": entry.job.id,
            "title": entry.job.title,
            "agent": entry.job.agent,
            "repeat": entry.job.repeat,
            "time": entry.job.time,
            "timezone": entry.job.timezone,
        })
    };
    let map = value
        .as_object_mut()
        .expect("a job serialises to an object");
    map.insert("revision".into(), json!(entry.job.revision));
    map.insert("enabled".into(), json!(entry.enabled));
    map.insert("next_due".into(), json!(entry.next_due));
    map.insert(
        "next_label".into(),
        json!(match entry.next_due {
            Some(stamp) => label(stamp, &entry.job.timezone),
            None => "Finished".into(),
        }),
    );
    value
}

/// Takes a slot for a schedule, if the slot is free and the scope will allow it.
///
/// The slot is what makes a run happen once: a tick that fires twice for the same
/// minute, or a manual run retried after a dropped connection, finds the slot taken
/// and returns the run that already exists instead of starting a second agent.
fn claim(
    store: &mut Store,
    id: &str,
    slot: &str,
    now: i64,
    automatic: bool,
) -> EngineResult<(String, bool)> {
    let entry = store.entry(identifier(id)?)?.clone();
    if store.state.paused || (automatic && !entry.enabled) {
        return Err(EngineError::denied("host schedules are paused"));
    }
    if let Some(existing) = store
        .state
        .runs
        .iter()
        .find(|record| record.schedule == id && record.slot == slot)
    {
        return Ok((existing.id.clone(), false));
    }
    if store.state.runs.len() >= MAX_HISTORY {
        return Err(EngineError::denied(
            "run history quota reached; existing history is retained",
        ));
    }
    let active = store
        .state
        .runs
        .iter()
        .filter(|record| is_active(&outcome(record, &store.state_root).status))
        .count();
    if active >= MAX_ACTIVE {
        return Err(EngineError::denied("two runs are already active"));
    }

    let missed = automatic && entry.next_due.is_some_and(|due| now - due > MISSED_AFTER);
    let run_id = run::new_id();
    store.state.runs.push(RunRecord {
        id: run_id.clone(),
        schedule: id.to_owned(),
        slot: slot.to_owned(),
        title: entry.job.title.clone(),
        started: now,
        settled: missed.then(|| "missed".to_owned()),
        job: None,
    });

    if automatic {
        let following = next_due(&entry.job, now);
        if let Some(entry) = store
            .state
            .schedules
            .iter_mut()
            .find(|candidate| candidate.job.id == id)
        {
            entry.next_due = following;
            entry.enabled = following.is_some();
        }
    }
    Ok((run_id, !missed))
}

/// Hands a claimed run to the same supervisor every other job on this machine goes
/// through, so a scheduled run is watched, bounded and cancellable like any other.
fn dispatch_run(store: &mut Store, run_id: &str) -> EngineResult<()> {
    let record = store
        .state
        .runs
        .iter()
        .find(|record| record.id == run_id)
        .ok_or_else(|| EngineError::not_found("run is unavailable"))?
        .clone();
    let entry = store.entry(&record.schedule)?.clone();
    let job = &entry.job;

    let mut argv = if job.agent == "codex" {
        vec!["codex".into(), "exec".into(), "--json".into(), "-".into()]
    } else {
        vec![
            "claude".into(),
            "--print".into(),
            "--output-format".into(),
            "json".into(),
        ]
    };
    if !job.model.is_empty() {
        argv.push("--model".into());
        argv.push(job.model.clone());
    }

    let prompt = store.root.join(format!("{run_id}.prompt"));
    write_private(&prompt, &job.prompt)?;

    let spec = run::JobSpec {
        argv,
        cwd: Some(job.directory.clone()),
        env: Vec::new(),
        timeout_ms: Some(job.timeout * 1000),
        created: now_millis(),
        stdin_file: Some(paths::display(&prompt)),
    };

    let launched = run::launch(&store.state_root, run_id, &spec);
    if let Some(record) = store
        .state
        .runs
        .iter_mut()
        .find(|record| record.id == run_id)
    {
        match &launched {
            Ok(_) => record.job = Some(run_id.to_owned()),
            Err(_) => record.settled = Some("failed".into()),
        }
    }
    launched.map(|_| ())
}

pub fn dispatch(op: &str, args: &Value, state_root: &Path) -> EngineResult<Value> {
    let scope = arg_str(args, "scope")?;
    let now = now_secs();

    if op == "inspect" {
        // Checked even though inspect answers whether or not a scope has state, so a
        // caller never learns that a malformed scope is merely an empty one.
        scope_root(state_root, scope)?;
        let mut value = probe();
        let installed = Store::open(state_root, scope)
            .map(|store| store.state.installed)
            .unwrap_or(false);
        let map = value.as_object_mut().expect("probe answers an object");
        map.insert("installed".into(), json!(installed));
        map.insert(
            "timer_active".into(),
            json!(installed && timer_active(scope)),
        );
        return Ok(value);
    }

    let mut store = Store::open(state_root, scope)?;

    if op == "setup" {
        let capability = probe();
        if capability.get("supported") != Some(&Value::Bool(true)) {
            return Err(EngineError::unsupported(
                capability
                    .get("reason")
                    .and_then(Value::as_str)
                    .unwrap_or("this host cannot run schedules unattended")
                    .to_owned(),
            ));
        }
        install_timer(scope)?;
        store.state.installed = true;
        store.commit()?;
        let mut value = capability;
        let map = value.as_object_mut().expect("probe answers an object");
        map.insert("installed".into(), json!(true));
        map.insert("timer_active".into(), json!(true));
        return Ok(value);
    }

    if !store.state.installed {
        return Err(EngineError::not_found(
            "enable scheduling on this host first",
        ));
    }

    match op {
        "list" => {
            let offset = arg_u64_opt(args, "offset")?.unwrap_or(0) as usize;
            if offset > MAX_SCHEDULES {
                return Err(EngineError::bad_request("invalid page"));
            }
            let mut ordered: Vec<&Entry> = store.state.schedules.iter().collect();
            ordered.sort_by(|left, right| {
                (left.next_due.is_none(), left.next_due, &left.job.id).cmp(&(
                    right.next_due.is_none(),
                    right.next_due,
                    &right.job.id,
                ))
            });
            let page: Vec<Value> = ordered
                .iter()
                .skip(offset)
                .take(PAGE)
                .map(|entry| summary(entry, false))
                .collect();
            Ok(json!({
                "items": page,
                "offset": offset,
                "more": page.len() == PAGE,
                "paused": store.state.paused,
                "error": store.state.error,
            }))
        }
        "get" => Ok(summary(
            store.entry(identifier(arg_str(args, "id")?)?)?,
            true,
        )),
        "save" => {
            let job = validate(
                args.get("schedule")
                    .ok_or_else(|| EngineError::bad_request("schedule is required"))?,
                now,
            )?;
            if which(&job.agent).is_none() {
                return Err(EngineError::not_found(format!(
                    "agent executable is not installed: {}",
                    job.agent
                )));
            }
            let existing = store
                .state
                .schedules
                .iter()
                .position(|entry| entry.job.id == job.id);
            let current = existing.map_or(0, |index| store.state.schedules[index].job.revision);
            if current != job.revision {
                return Err(EngineError::denied(
                    "schedule changed; refresh before saving",
                ));
            }
            if existing.is_none() && store.state.schedules.len() >= MAX_SCHEDULES {
                return Err(EngineError::denied("schedule quota reached"));
            }

            let mut job = job;
            job.revision += 1;
            let revision = job.revision;
            let id = job.id.clone();
            let entry = Entry {
                next_due: next_due(&job, now),
                // Editing a schedule is not resuming it. One that was paused stays
                // paused through a save, and comes back only when it is asked to.
                enabled: existing.is_none_or(|index| store.state.schedules[index].enabled),
                job,
            };
            match existing {
                Some(index) => store.state.schedules[index] = entry,
                None => store.state.schedules.push(entry),
            }
            store.commit()?;
            Ok(json!({ "id": id, "revision": revision }))
        }
        "pause" | "resume" => {
            let id = identifier(arg_str(args, "id")?)?.to_owned();
            let entry = store.entry(&id)?.clone();
            let due = if op == "resume" {
                let due = next_due(&entry.job, now);
                if due.is_none() {
                    return Err(EngineError::bad_request(
                        "edit the expired schedule before resuming",
                    ));
                }
                due
            } else {
                entry.next_due
            };
            if let Some(entry) = store
                .state
                .schedules
                .iter_mut()
                .find(|candidate| candidate.job.id == id)
            {
                entry.enabled = op == "resume";
                entry.next_due = due;
                entry.job.revision += 1;
            }
            store.commit()?;
            Ok(json!({ "paused": op == "pause" }))
        }
        "pause_scope" | "resume_scope" => {
            store.state.paused = op == "pause_scope";
            store.commit()?;
            Ok(json!({ "paused": store.state.paused }))
        }
        "run" => {
            let id = arg_str(args, "id")?.to_owned();
            let slot = format!("manual:{}", identifier(arg_str(args, "request_id")?)?);
            let (run_id, fresh) = claim(&mut store, &id, &slot, now, false)?;
            if fresh {
                let launched = dispatch_run(&mut store, &run_id);
                store.commit()?;
                launched?;
            }
            Ok(json!({ "id": run_id }))
        }
        "history" => {
            let offset = arg_u64_opt(args, "offset")?.unwrap_or(0) as usize;
            if offset > MAX_HISTORY {
                return Err(EngineError::bad_request("invalid history page"));
            }
            let mut ordered: Vec<&RunRecord> = store.state.runs.iter().collect();
            ordered.sort_by_key(|record| std::cmp::Reverse(record.started));
            let page: Vec<Value> = ordered
                .iter()
                .skip(offset)
                .take(PAGE)
                .map(|record| {
                    let outcome = outcome(record, &store.state_root);
                    json!({
                        "id": record.id,
                        "title": record.title,
                        "status": outcome.status,
                        "started": record.started,
                        "started_label": utc_label(record.started),
                        "finished": outcome.finished,
                        "exit_code": outcome.exit_code,
                    })
                })
                .collect();
            Ok(json!({ "items": page, "offset": offset, "more": page.len() == PAGE }))
        }
        "output" => {
            let id = identifier(arg_str(args, "id")?)?;
            let record = store
                .state
                .runs
                .iter()
                .find(|record| record.id == id)
                .ok_or_else(|| EngineError::not_found("run is unavailable"))?;
            let outcome = outcome(record, &store.state_root);
            let (text, bytes) = match &record.job {
                None => (String::new(), 0),
                Some(job) => read_tail(&run::job_dir(&store.state_root, job)?)?,
            };
            Ok(json!({ "status": outcome.status, "text": text, "bytes": bytes }))
        }
        "usage" => {
            let bytes: u64 = fs::read_dir(&store.root)
                .map(|entries| {
                    entries
                        .flatten()
                        .filter_map(|entry| entry.metadata().ok())
                        .filter(|meta| meta.is_file())
                        .map(|meta| meta.len())
                        .sum()
                })
                .unwrap_or(0);
            Ok(json!({
                "schema_version": SCHEMA_VERSION,
                "schedules": store.state.schedules.len(),
                "runs": store.state.runs.len(),
                "bytes": bytes,
                "history_limit": MAX_HISTORY,
            }))
        }
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

/// The end of a run's output, both streams together. The agent's own diagnostics are
/// part of what the user came to read, and only the tail crosses the tunnel.
fn read_tail(dir: &Path) -> EngineResult<(String, u64)> {
    let mut collected = Vec::new();
    let mut total = 0u64;
    for name in ["stdout", "stderr"] {
        let path = dir.join(name);
        let Ok(mut file) = fs::File::open(&path) else {
            continue;
        };
        let size = file.metadata()?.len();
        total += size;
        if size > MAX_OUTPUT {
            file.seek(SeekFrom::Start(size - MAX_OUTPUT))?;
        }
        let mut buffer = Vec::new();
        file.take(MAX_OUTPUT).read_to_end(&mut buffer)?;
        collected.extend_from_slice(&buffer);
    }
    if collected.len() as u64 > MAX_OUTPUT {
        let cut = collected.len() - MAX_OUTPUT as usize;
        collected.drain(..cut);
    }
    Ok((String::from_utf8_lossy(&collected).into_owned(), total))
}

/// The timer's one job: settle what is owed and start what is due. It is the same
/// binary the phone talks to, in a mode that takes no request and answers nobody.
pub fn tick(scope: &str) -> i32 {
    let Ok(account) = crate::owner::account() else {
        return 1;
    };
    let Ok(state_root) = paths::state_root(&account) else {
        return 1;
    };
    let Ok(mut store) = Store::open(&state_root, scope) else {
        return 1;
    };
    if store.state.paused {
        return 0;
    }

    let now = now_secs();
    let due: Vec<(String, i64)> = store
        .state
        .schedules
        .iter()
        .filter(|entry| entry.enabled && entry.next_due.is_some_and(|stamp| stamp <= now))
        .map(|entry| (entry.job.id.clone(), entry.next_due.unwrap_or(now)))
        .take(PAGE)
        .collect();

    let mut error = String::new();
    for (id, stamp) in due {
        match claim(&mut store, &id, &stamp.to_string(), now, true) {
            Ok((run_id, true)) => {
                if let Err(failure) = dispatch_run(&mut store, &run_id) {
                    error = failure.message;
                }
            }
            Ok((_, false)) => {}
            Err(failure) => error = failure.message,
        }
    }
    store.state.error = error;
    if store.commit().is_err() {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::{
        agent_plist, dispatch_unit, next_due, parse_hhmm, remove_launchd_timers,
        remove_systemd_timers, Job,
    };

    fn job(repeat: &str, time: &str, zone: &str, date: &str) -> Job {
        Job {
            id: "one".into(),
            revision: 0,
            title: "One".into(),
            directory: "/tmp".into(),
            agent: "claude".into(),
            model: String::new(),
            prompt: "hello".into(),
            repeat: repeat.into(),
            date: date.into(),
            time: time.into(),
            timezone: zone.into(),
            timeout: 600,
        }
    }

    #[test]
    fn a_time_the_clock_skips_is_passed_over_rather_than_moved() {
        // 2026-03-08 02:30 does not exist in New York: the clock goes 01:59 to 03:00.
        let spec = job("daily", "02:30", "America/New_York", "");
        let before = 1_772_949_600; // 2026-03-08T01:00-05:00
        let due = next_due(&spec, before).expect("a daily schedule always has a next day");
        assert!(due > before + 86_000, "the skipped day is not fired early");

        let once = job("once", "02:30", "America/New_York", "2026-03-08");
        assert_eq!(next_due(&once, before), None);
    }

    #[test]
    fn an_hour_the_clock_repeats_fires_on_the_first_of_the_two() {
        // 2026-11-01 01:30 happens twice in New York, at -04:00 and again at -05:00.
        let spec = job("once", "01:30", "America/New_York", "2026-11-01");
        let due = next_due(&spec, 1_793_500_000).expect("the earlier of the two");
        assert_eq!(due, 1_793_511_000, "05:30Z is 01:30-04:00, not 01:30-05:00");
    }

    #[test]
    fn a_one_shot_in_the_past_has_no_next_time() {
        let spec = job("once", "09:00", "UTC", "2020-01-01");
        assert_eq!(next_due(&spec, 1_772_949_600), None);
    }

    #[test]
    fn a_daily_schedule_moves_to_tomorrow_once_today_is_gone() {
        let spec = job("daily", "09:00", "UTC", "");
        let morning = 1_772_960_400; // 2026-03-08T09:00Z
        assert_eq!(next_due(&spec, morning), Some(morning + 86_400));
        assert_eq!(next_due(&spec, morning - 60), Some(morning));
    }

    #[test]
    fn the_time_of_day_is_a_24_hour_clock() {
        assert_eq!(parse_hhmm("00:00"), Some((0, 0)));
        assert_eq!(parse_hhmm("23:59"), Some((23, 59)));
        assert_eq!(parse_hhmm("24:00"), None);
        assert_eq!(parse_hhmm("9:00"), None);
        assert_eq!(parse_hhmm("09:60"), None);
    }

    #[test]
    fn a_timer_carries_the_path_that_found_the_agent() {
        // launchd hands a job /usr/bin:/bin:/usr/sbin:/sbin, so an agent in a user
        // profile is exec'd by a schedule run by hand and not by the timer, and the
        // only trace is a missing file. Whatever PATH answered `inspect` is the one
        // the timer has to run with.
        let profile = "/etc/profiles/per-user/dev/bin:/usr/bin:/bin";
        let plist = agent_plist(
            "dazzle-schedule-aa",
            "/bin/engine",
            "aa",
            "/state",
            Some(profile),
        );
        assert!(plist.contains(&format!("<key>PATH</key><string>{profile}</string>")));
        let unit = dispatch_unit("/bin/engine", "aa", "/state", Some(profile));
        assert!(unit.contains(&format!("Environment=\"PATH={profile}\"\n")));

        // An account with no PATH at all leaves the key out rather than pinning an
        // empty one, which would be a narrower environment than inheriting.
        assert!(
            !agent_plist("dazzle-schedule-aa", "/bin/engine", "aa", "/state", None)
                .contains("PATH")
        );
        assert!(!dispatch_unit("/bin/engine", "aa", "/state", None).contains("PATH"));
    }

    #[test]
    fn a_path_is_spelled_for_the_file_it_lands_in() {
        let plist = agent_plist("n", "/bin/engine", "aa", "/s", Some("/a&b/bin:/c<d/bin"));
        assert!(plist.contains("<string>/a&amp;b/bin:/c&lt;d/bin</string>"));
        let unit = dispatch_unit("/bin/engine", "aa", "/s", Some("/a\"b/bin"));
        assert!(unit.contains("Environment=\"PATH=/a\\\"b/bin\"\n"));
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "dazzle-schedule-unit-{}-{name}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn plant(dir: &std::path::Path, names: &[&str]) {
        for name in names {
            std::fs::write(dir.join(name), "planted").unwrap();
        }
    }

    /// Both of these run on either platform. The manager each one calls is only present
    /// on its own, and a call that fails is already ignored: what is under test here is
    /// which files the walk claims, which is the half that can take somebody else's timer
    /// off the machine if it is wrong.
    #[test]
    fn a_launchd_walk_claims_this_engines_agents_and_leaves_the_rest() {
        let dir = scratch("launchd");
        plant(
            &dir,
            &[
                "dazzle-schedule-aa.plist",
                "dazzle-schedule-bb.plist",
                "com.apple.something.plist",
                "dazzle-schedule-cc.txt",
            ],
        );

        let mut removed = remove_launchd_timers(&dir);
        removed.sort();
        assert_eq!(removed, vec!["dazzle-schedule-aa", "dazzle-schedule-bb"]);
        assert!(!dir.join("dazzle-schedule-aa.plist").exists());
        assert!(dir.join("com.apple.something.plist").exists());
        // A label is what launchctl is addressed by, so a file that is not a plist is
        // not this walk's to take however it is named.
        assert!(dir.join("dazzle-schedule-cc.txt").exists());

        assert!(remove_launchd_timers(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_systemd_walk_claims_both_halves_of_a_timer_and_leaves_the_rest() {
        let dir = scratch("systemd");
        plant(
            &dir,
            &[
                "dazzle-schedule-aa.timer",
                "dazzle-schedule-aa.service",
                "borgbackup.timer",
            ],
        );

        let mut removed = remove_systemd_timers(&dir);
        removed.sort();
        assert_eq!(
            removed,
            vec!["dazzle-schedule-aa.service", "dazzle-schedule-aa.timer"]
        );
        assert!(dir.join("borgbackup.timer").exists());

        assert!(remove_systemd_timers(&dir).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_walk_over_a_directory_that_is_not_there_removes_nothing() {
        let absent = std::env::temp_dir().join("dazzle-schedule-unit-absent");
        let _ = std::fs::remove_dir_all(&absent);
        assert!(remove_launchd_timers(&absent).is_empty());
        assert!(remove_systemd_timers(&absent).is_empty());
    }
}
