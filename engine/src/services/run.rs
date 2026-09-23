use crate::paths;
use crate::policy::Policy;
use crate::protocol::{
    arg_bool, arg_str, arg_str_list, arg_str_opt, arg_u64_opt, EngineError, EngineResult,
};
use crate::util::now_millis;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub const SERVICE: &str = "run/1";
pub const OPS: &[&str] = &["start", "status", "output", "cancel"];

const DEFAULT_OUTPUT_LINES: u64 = 200;
const MAX_OUTPUT_BYTES: u64 = 1024 * 1024;
/// A tail of a log the engine never has to hold whole: only this much of the end
/// of the file is ever read into memory.
const MAX_SCAN_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug, Serialize, Deserialize)]
pub struct JobSpec {
    pub argv: Vec<String>,
    pub cwd: Option<String>,
    pub env: Vec<(String, String)>,
    pub timeout_ms: Option<u64>,
    pub created: u64,
    /// Read as the child's stdin. A schedule feeds its prompt this way rather than
    /// through argv, where the process table of the machine would carry it.
    #[serde(default)]
    pub stdin_file: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct JobStatus {
    pub state: String,
    pub pid: Option<i32>,
    pub pgid: Option<i32>,
    #[serde(default)]
    pub supervisor: Option<i32>,
    pub started: Option<u64>,
    pub finished: Option<u64>,
    pub code: Option<i32>,
    pub signal: Option<i32>,
    #[serde(default)]
    pub cancelled: bool,
    #[serde(default)]
    pub timed_out: bool,
    pub error: Option<String>,
}

pub fn jobs_root(state_root: &Path) -> PathBuf {
    state_root.join("jobs")
}

pub fn job_dir(state_root: &Path, id: &str) -> EngineResult<PathBuf> {
    // The id indexes a directory, so anything that could climb out of it is refused
    // before it is ever joined to a path.
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') {
        return Err(EngineError::bad_request("id is not a job identifier"));
    }
    Ok(jobs_root(state_root).join(id))
}

pub fn read_status(dir: &Path) -> EngineResult<JobStatus> {
    let raw = fs::read_to_string(dir.join("status.json"))
        .map_err(|_| EngineError::not_found("no such job"))?;
    serde_json::from_str(&raw).map_err(|err| EngineError::failed(err.to_string()))
}

pub fn write_status(dir: &Path, status: &JobStatus) -> EngineResult<()> {
    // Written beside the target and renamed, so a reader never sees half a status.
    let tmp = dir.join("status.json.tmp");
    fs::write(
        &tmp,
        serde_json::to_vec(status).map_err(|err| EngineError::failed(err.to_string()))?,
    )?;
    fs::rename(tmp, dir.join("status.json"))?;
    Ok(())
}

pub fn new_id() -> String {
    let mut bytes = [0u8; 8];
    if let Ok(mut source) = fs::File::open("/dev/urandom") {
        let _ = source.read_exact(&mut bytes);
    }
    let suffix: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{:x}-{}", now_millis(), suffix)
}

pub fn dispatch(op: &str, args: &Value, state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    match op {
        "start" => start(args, state_root, policy),
        "status" => status(args, state_root),
        "output" => output(args, state_root),
        "cancel" => cancel(args, state_root),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

fn env_pairs(args: &Value) -> EngineResult<Vec<(String, String)>> {
    let Some(value) = args.get("env") else {
        return Ok(Vec::new());
    };
    let Value::Object(map) = value else {
        if value.is_null() {
            return Ok(Vec::new());
        }
        return Err(EngineError::bad_request("env must be an object of strings"));
    };
    map.iter()
        .map(|(key, value)| {
            value
                .as_str()
                .map(|value| (key.clone(), value.to_owned()))
                .ok_or_else(|| EngineError::bad_request("env must be an object of strings"))
        })
        .collect()
}

fn start(args: &Value, state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    let argv = arg_str_list(args, "argv")?;
    let Some(program) = argv.first() else {
        return Err(EngineError::bad_request(
            "argv is required and must name a program",
        ));
    };
    policy.check_exec(program)?;

    let cwd = match arg_str_opt(args, "cwd")? {
        Some(raw) => Some(paths::display(&paths::expand(raw)?)),
        None => None,
    };
    let spec = JobSpec {
        argv,
        cwd,
        env: env_pairs(args)?,
        timeout_ms: arg_u64_opt(args, "timeout_ms")?,
        created: now_millis(),
        stdin_file: None,
    };

    let id = new_id();
    launch(state_root, &id, &spec)?;
    Ok(json!({ "id": id, "state": "starting" }))
}

/// Writes a job down and hands it to a detached copy of the engine.
///
/// The engine is not resident, so the thing that outlives this call is that copy in
/// its own session: it owns the child, waits for it, and records how it ended.
/// Without it nothing on this machine could report an exit code.
pub fn launch(state_root: &Path, id: &str, spec: &JobSpec) -> EngineResult<PathBuf> {
    let dir = job_dir(state_root, id)?;
    fs::create_dir_all(&dir)?;
    fs::write(
        dir.join("spec.json"),
        serde_json::to_vec(spec).map_err(|err| EngineError::failed(err.to_string()))?,
    )?;
    write_status(
        &dir,
        &JobStatus {
            state: "starting".into(),
            ..JobStatus::default()
        },
    )?;

    let executable = std::env::current_exe()
        .map_err(|err| EngineError::failed(format!("the engine cannot locate itself: {err}")))?;
    let mut supervisor = Command::new(executable);
    supervisor
        .arg("__supervise")
        .arg(&dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    unsafe {
        supervisor.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    supervisor
        .spawn()
        .map_err(|err| EngineError::failed(format!("the supervisor did not start: {err}")))?;
    Ok(dir)
}

/// How long a job may sit at `starting` before the supervisor that owes it a pid is
/// taken to be one that never ran. Generous against a loaded machine; an exec costs
/// milliseconds.
const STARTUP_GRACE: u64 = 30_000;

fn older_than(dir: &Path, age: u64) -> bool {
    let Ok(raw) = fs::read_to_string(dir.join("spec.json")) else {
        return false;
    };
    let Ok(spec) = serde_json::from_str::<JobSpec>(&raw) else {
        return false;
    };
    now_millis().saturating_sub(spec.created) > age
}

pub fn liveness_checked(dir: &Path, mut status: JobStatus) -> JobStatus {
    if status.state != "running" && status.state != "starting" {
        return status;
    }
    // The supervisor is what is asked about, never the child. The supervisor reaps the
    // child before it writes the exit down, so between those two the child's pid is
    // already gone while the only process that can answer for it is still there: asking
    // after the child would call a job that finished perfectly a job nobody is coming
    // back for. Older jobs recorded no supervisor and fall back to what they have.
    let Some(pid) = status.supervisor.or(status.pid) else {
        // A supervisor killed before its first write leaves a job with nothing to ask
        // after, and a record no question can settle would read as alive forever. The
        // moment the job was written down bounds it: recording itself costs the
        // supervisor one exec, so a job still `starting` this long after it was
        // created is one whose supervisor never arrived.
        if status.state == "starting" && older_than(dir, STARTUP_GRACE) {
            status.state = "lost".into();
            status.error = Some("the supervisor never started".into());
            let _ = write_status(dir, &status);
        }
        return status;
    };
    // kill(pid, 0) asks whether the process is still there without touching it. A job
    // that is gone with nothing recorded lost its supervisor, which is not the same
    // answer as an exit and is not reported as one.
    if unsafe { libc::kill(pid, 0) } == -1
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
    {
        status.state = "lost".into();
        status.error = Some("the supervisor stopped without recording an exit".into());
        let _ = write_status(dir, &status);
    }
    status
}

fn status_value(id: &str, status: &JobStatus) -> Value {
    json!({
        "id": id,
        "state": status.state,
        "pid": status.pid,
        "started": status.started,
        "finished": status.finished,
        "code": status.code,
        "signal": status.signal,
        "cancelled": status.cancelled,
        "timed_out": status.timed_out,
        "error": status.error,
    })
}

fn status(args: &Value, state_root: &Path) -> EngineResult<Value> {
    let id = arg_str(args, "id")?;
    let dir = job_dir(state_root, id)?;
    let status = liveness_checked(&dir, read_status(&dir)?);
    Ok(status_value(id, &status))
}

pub(crate) fn cancel(args: &Value, state_root: &Path) -> EngineResult<Value> {
    let id = arg_str(args, "id")?;
    let dir = job_dir(state_root, id)?;
    let status = read_status(&dir)?;
    if status.state == "exited" {
        return Ok(json!({ "id": id, "state": status.state, "cancelled": false }));
    }
    // The marker is written first: whichever of the two the supervisor notices, it
    // labels the job cancelled rather than reporting a bare signal.
    fs::write(dir.join("cancel"), b"")?;
    if let Some(pgid) = status.pgid {
        unsafe { libc::kill(-pgid, libc::SIGTERM) };
    }
    Ok(json!({ "id": id, "state": "cancelling", "cancelled": true }))
}

struct Filter {
    grep: Option<String>,
    ignore_case: bool,
    invert: bool,
    head: Option<usize>,
    tail: Option<usize>,
    limit: u64,
}

fn read_bounded(path: &Path, from_end: bool) -> EngineResult<(String, bool)> {
    let mut file = match fs::File::open(path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Ok((String::new(), false))
        }
        Err(err) => return Err(err.into()),
    };
    let size = file.metadata()?.len();
    let clipped = size > MAX_SCAN_BYTES;
    if clipped && from_end {
        file.seek(SeekFrom::Start(size - MAX_SCAN_BYTES))?;
    }
    let mut buffer = vec![0u8; size.min(MAX_SCAN_BYTES) as usize];
    let mut filled = 0usize;
    while filled < buffer.len() {
        match file.read(&mut buffer[filled..])? {
            0 => break,
            count => filled += count,
        }
    }
    buffer.truncate(filled);
    Ok((String::from_utf8_lossy(&buffer).into_owned(), clipped))
}

/// head, tail, grep and the byte limit are applied here, on the machine that produced
/// the output, so what crosses the tunnel is what was asked for and not a log the
/// phone receives in full to discard the bulk of.
fn filter_lines(text: &str, filter: &Filter) -> (Vec<String>, usize, bool) {
    let needle = filter.grep.as_ref().map(|value| {
        if filter.ignore_case {
            value.to_lowercase()
        } else {
            value.clone()
        }
    });

    let mut lines: Vec<String> = text
        .lines()
        .filter(|line| match &needle {
            None => true,
            Some(needle) => {
                let haystack = if filter.ignore_case {
                    line.to_lowercase()
                } else {
                    (*line).to_owned()
                };
                haystack.contains(needle.as_str()) != filter.invert
            }
        })
        .map(str::to_owned)
        .collect();

    let matched = lines.len();
    if let Some(head) = filter.head {
        lines.truncate(head);
    } else if let Some(tail) = filter.tail {
        if lines.len() > tail {
            lines.drain(..lines.len() - tail);
        }
    }

    let mut bytes = 0u64;
    let mut truncated = lines.len() < matched;
    let mut kept: Vec<String> = Vec::with_capacity(lines.len());
    for line in lines {
        bytes += line.len() as u64 + 1;
        if bytes > filter.limit {
            truncated = true;
            break;
        }
        kept.push(line);
    }
    (kept, matched, truncated)
}

fn output(args: &Value, state_root: &Path) -> EngineResult<Value> {
    let id = arg_str(args, "id")?;
    let dir = job_dir(state_root, id)?;
    let status = liveness_checked(&dir, read_status(&dir)?);

    let stream = arg_str_opt(args, "stream")?.unwrap_or("stdout");
    if !matches!(stream, "stdout" | "stderr" | "both") {
        return Err(EngineError::bad_request(
            "stream must be stdout, stderr or both",
        ));
    }

    let head = arg_u64_opt(args, "head")?.map(|value| value as usize);
    let tail = arg_u64_opt(args, "tail")?.map(|value| value as usize);
    if head.is_some() && tail.is_some() {
        return Err(EngineError::bad_request(
            "head and tail cannot both be given",
        ));
    }
    let tail = if head.is_none() && tail.is_none() {
        Some(DEFAULT_OUTPUT_LINES as usize)
    } else {
        tail
    };
    let filter = Filter {
        grep: arg_str_opt(args, "grep")?.map(str::to_owned),
        ignore_case: arg_bool(args, "ignore_case", false)?,
        invert: arg_bool(args, "invert", false)?,
        head,
        tail,
        limit: arg_u64_opt(args, "limit")?
            .unwrap_or(MAX_OUTPUT_BYTES)
            .min(MAX_OUTPUT_BYTES),
    };

    let mut result = Map::new();
    result.insert("id".into(), json!(id));
    result.insert("state".into(), json!(status.state));
    for name in ["stdout", "stderr"] {
        if stream != "both" && stream != name {
            continue;
        }
        let (text, clipped) = read_bounded(&dir.join(name), filter.head.is_none())?;
        let (lines, matched, truncated) = filter_lines(&text, &filter);
        result.insert(
            name.into(),
            json!({
                "lines": lines,
                "matched": matched,
                "truncated": truncated || clipped,
            }),
        );
    }
    Ok(Value::Object(result))
}

/// The detached half of `start`: it owns the child, enforces the timeout, and writes
/// the exit down where a later call can read it.
pub fn supervise(dir: &Path) -> i32 {
    let Ok(raw) = fs::read_to_string(dir.join("spec.json")) else {
        return 1;
    };
    let Ok(spec) = serde_json::from_str::<JobSpec>(&raw) else {
        return 1;
    };

    let failed = |message: String| {
        let _ = write_status(
            dir,
            &JobStatus {
                state: "exited".into(),
                finished: Some(now_millis()),
                code: Some(-1),
                error: Some(message),
                ..JobStatus::default()
            },
        );
        1
    };

    let (Ok(stdout), Ok(stderr)) = (
        fs::File::create(dir.join("stdout")),
        fs::File::create(dir.join("stderr")),
    ) else {
        return failed("the engine could not open the job's output files".into());
    };

    let stdin = match &spec.stdin_file {
        None => Stdio::null(),
        Some(path) => match fs::File::open(path) {
            Ok(file) => Stdio::from(file),
            Err(err) => return failed(format!("the job's stdin could not be opened: {err}")),
        },
    };

    let mut command = Command::new(&spec.argv[0]);
    command
        .args(&spec.argv[1..])
        .stdin(stdin)
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    if let Some(cwd) = &spec.cwd {
        command.current_dir(cwd);
    }
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    // Its own process group, so cancelling reaches what the child itself started and
    // not the supervisor sending the signal.
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => return failed(err.to_string()),
    };
    let pid = child.id() as i32;
    let started = now_millis();
    let _ = write_status(
        dir,
        &JobStatus {
            state: "running".into(),
            pid: Some(pid),
            pgid: Some(pid),
            supervisor: Some(std::process::id() as i32),
            started: Some(started),
            ..JobStatus::default()
        },
    );

    let cancel_marker = dir.join("cancel");
    let mut cancelled = false;
    let mut timed_out = false;
    let mut signalled_at: Option<u64> = None;

    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(err) => return failed(err.to_string()),
        }

        let now = now_millis();
        if !cancelled && cancel_marker.exists() {
            cancelled = true;
            unsafe { libc::kill(-pid, libc::SIGTERM) };
            signalled_at = Some(now);
        }
        if !timed_out {
            if let Some(timeout) = spec.timeout_ms {
                if now.saturating_sub(started) >= timeout {
                    timed_out = true;
                    unsafe { libc::kill(-pid, libc::SIGTERM) };
                    signalled_at = Some(now);
                }
            }
        }
        // A child that ignores SIGTERM still has to stop, or the supervisor would sit
        // on a job the user already cancelled.
        if let Some(at) = signalled_at {
            if now.saturating_sub(at) >= 5_000 {
                unsafe { libc::kill(-pid, libc::SIGKILL) };
                signalled_at = None;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    };

    // `cancel` signals the child itself, so a short-lived one can be gone before the
    // poll above ever sees the marker. The marker is what says a cancel was asked
    // for, and it is read once more here rather than only inside the loop.
    let cancelled = cancelled || cancel_marker.exists();

    let _ = write_status(
        dir,
        &JobStatus {
            state: "exited".into(),
            pid: Some(pid),
            pgid: Some(pid),
            supervisor: Some(std::process::id() as i32),
            started: Some(started),
            finished: Some(now_millis()),
            code: status.code(),
            signal: std::os::unix::process::ExitStatusExt::signal(&status),
            cancelled,
            timed_out,
            error: None,
        },
    );
    0
}

#[cfg(test)]
mod tests {
    use super::{filter_lines, Filter};

    fn filter() -> Filter {
        Filter {
            grep: None,
            ignore_case: false,
            invert: false,
            head: None,
            tail: None,
            limit: 1024,
        }
    }

    #[test]
    fn head_takes_from_the_front_and_tail_from_the_back() {
        let text = "one\ntwo\nthree\nfour\n";
        let mut spec = filter();
        spec.head = Some(2);
        assert_eq!(filter_lines(text, &spec).0, vec!["one", "two"]);

        let mut spec = filter();
        spec.tail = Some(2);
        assert_eq!(filter_lines(text, &spec).0, vec!["three", "four"]);
    }

    #[test]
    fn grep_filters_before_head_and_reports_what_matched() {
        let text = "alpha\nbeta\nALPHA\ngamma\n";
        let mut spec = filter();
        spec.grep = Some("alpha".into());
        let (lines, matched, _) = filter_lines(text, &spec);
        assert_eq!(lines, vec!["alpha"]);
        assert_eq!(matched, 1);

        let mut spec = filter();
        spec.grep = Some("alpha".into());
        spec.ignore_case = true;
        let (lines, matched, _) = filter_lines(text, &spec);
        assert_eq!(lines, vec!["alpha", "ALPHA"]);
        assert_eq!(matched, 2);

        let mut spec = filter();
        spec.grep = Some("alpha".into());
        spec.invert = true;
        assert_eq!(filter_lines(text, &spec).0, vec!["beta", "ALPHA", "gamma"]);
    }

    #[test]
    fn the_byte_limit_truncates_and_says_so() {
        let text = "aaaa\nbbbb\ncccc\n";
        let mut spec = filter();
        spec.limit = 10;
        let (lines, matched, truncated) = filter_lines(text, &spec);
        assert_eq!(lines, vec!["aaaa", "bbbb"]);
        assert_eq!(matched, 3);
        assert!(truncated);
    }
}
