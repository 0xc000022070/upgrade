use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};

const BINARY: &str = env!("CARGO_BIN_EXE_dazzle-engine");
static COUNTER: AtomicU32 = AtomicU32::new(0);

struct Sandbox {
    root: PathBuf,
    only_stubs: bool,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        Self::build(name, false)
    }

    /// A PATH holding nothing but this sandbox's stubs. The machine running the suite
    /// may well have a real agent installed, and a test about a host that does not
    /// have one cannot be written against the machine that does.
    fn isolated(name: &str) -> Self {
        Self::build(name, true)
    }

    fn build(name: &str, only_stubs: bool) -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!(
            "dazzle-engine-test-{}-{name}-{unique}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("state")).unwrap();
        fs::create_dir_all(root.join("work")).unwrap();
        fs::create_dir_all(root.join("bin")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        Self { root, only_stubs }
    }

    fn state(&self) -> PathBuf {
        self.root.join("state")
    }

    /// The engine reads more than its state directory out of the account running it: a
    /// config file it unions into the ceiling, and the timers it installs. A suite run on
    /// a machine where the engine is actually installed would otherwise read that
    /// machine's ceiling into every test and take that account's live timers off it.
    fn home(&self) -> PathBuf {
        self.root.join("home")
    }

    fn unit_dir(&self) -> PathBuf {
        if cfg!(target_os = "macos") {
            self.home().join("Library/LaunchAgents")
        } else {
            self.home().join("config/systemd/user")
        }
    }

    fn work(&self) -> PathBuf {
        self.root.join("work")
    }

    /// Put ahead of the real PATH on every call, so a test can stand in for an agent
    /// the machine running the suite is not required to have installed.
    fn bin(&self) -> PathBuf {
        self.root.join("bin")
    }

    fn stub(&self, name: &str, body: &str) {
        let path = self.bin().join(name);
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, PermissionsExt::from_mode(0o755)).unwrap();
    }

    /// `setup` installs a real timer, which a sandbox has nowhere to put. The ops that
    /// come after it are gated on the flag rather than on the timer, so a test reaches
    /// them by setting the flag the way a completed setup would have.
    fn enable(&self, owner: &str, scope: &str) -> PathBuf {
        let root = self.state().join(owner).join("schedules").join(scope);
        fs::create_dir_all(&root).unwrap();
        fs::write(
            root.join("state.json"),
            json!({ "version": 1, "installed": true }).to_string(),
        )
        .unwrap();
        root
    }

    fn config(&self, body: &str) -> PathBuf {
        let path = self.root.join("config.json");
        fs::write(&path, body).unwrap();
        path
    }

    fn call(&self, request: Value) -> Value {
        self.call_with_config(request, None)
    }

    fn call_with_config(&self, request: Value, config: Option<&Path>) -> Value {
        let path = match std::env::var_os("PATH").filter(|_| !self.only_stubs) {
            Some(existing) => format!("{}:{}", self.bin().display(), existing.to_string_lossy()),
            None => self.bin().display().to_string(),
        };
        let mut command = self.command(&path);
        command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        match config {
            Some(path) => {
                command.env("DAZZLE_ENGINE_CONFIG", path);
            }
            None => {
                command.env_remove("DAZZLE_ENGINE_CONFIG");
            }
        }
        let mut child = command.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(request.to_string().as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "engine exited {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).expect("the engine answered with JSON")
    }

    fn command(&self, path: &str) -> Command {
        let mut command = Command::new(BINARY);
        command
            .env("DAZZLE_ENGINE_STATE", self.state())
            .env("HOME", self.home())
            .env("XDG_CONFIG_HOME", self.home().join("config"))
            .env("PATH", path);
        for key in [
            "CLAUDE_CONFIG_DIR",
            "CODEX_HOME",
            "HERDR_PANE_ID",
            "HERDR_SOCKET_PATH",
            "TMUX_PANE",
        ] {
            command.env_remove(key);
        }
        command
    }

    fn spawn_hook(&self, agent: &str, event: Value) -> std::process::Child {
        let mut command = self.command(&self.bin().display().to_string());
        command
            .args(["hook", agent])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = command.spawn().unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(event.to_string().as_bytes())
            .unwrap();
        child
    }

    fn hook(&self, agent: &str, event: Value) -> String {
        let output = self.spawn_hook(agent, event).wait_with_output().unwrap();
        assert!(output.status.success(), "the hook failed its agent");
        String::from_utf8(output.stdout).unwrap()
    }

    fn agents(&self, owner: &str, op: &str, args: Value) -> Value {
        self.call(json!({ "service": "agents/1", "op": op, "owner": owner, "args": args }))
    }

    fn owner(&self) -> String {
        self.call(json!({ "service": "lifecycle", "op": "probe" }))["result"]["owner"]
            .as_str()
            .unwrap()
            .to_owned()
    }

    fn wait_for_exit(&self, owner: &str, id: &str) -> Value {
        for _ in 0..200 {
            let answer = self.call(json!({
                "service": "run/1", "op": "status", "owner": owner, "args": { "id": id }
            }));
            let state = answer["result"]["state"].as_str().unwrap_or("");
            if state == "exited" || state == "lost" {
                return answer;
            }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        panic!("the job never reached a settled state");
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn assert_denied(answer: &Value) {
    assert_eq!(
        answer["ok"],
        json!(false),
        "expected a refusal, got {answer}"
    );
    assert_eq!(answer["error"]["kind"], json!("denied"), "got {answer}");
}

#[test]
fn probe_answers_without_an_owner_and_names_only_what_is_built() {
    let sandbox = Sandbox::new("probe");
    let answer = sandbox.call(json!({ "service": "lifecycle", "op": "probe" }));
    assert_eq!(answer["ok"], json!(true));

    let result = &answer["result"];
    assert_eq!(result["protocol"], json!(1));
    assert!(matches!(
        result["platform"].as_str(),
        Some("linux" | "darwin")
    ));
    assert!(!result["owner"].as_str().unwrap().is_empty());

    let names: Vec<&str> = result["services"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        vec!["lifecycle", "fs/1", "run/1", "schedule/1", "agents/1"]
    );
    for absent in ["git/1", "kv/1", "batch/1"] {
        assert!(!names.contains(&absent), "{absent} is named but not built");
    }
}

#[test]
fn a_call_made_for_another_owner_is_refused() {
    let sandbox = Sandbox::new("owner");
    let answer = sandbox.call(json!({
        "service": "fs/1", "op": "list", "owner": "somebody-else",
        "args": { "path": "/tmp" }
    }));
    assert_denied(&answer);

    let missing = sandbox.call(json!({
        "service": "fs/1", "op": "list", "args": { "path": "/tmp" }
    }));
    assert_eq!(missing["error"]["kind"], json!("bad_request"));
}

#[test]
fn fs_lists_reads_and_digests() {
    let sandbox = Sandbox::new("fs");
    let owner = sandbox.owner();
    fs::write(sandbox.work().join("hello.txt"), b"hello engine\n").unwrap();
    fs::create_dir(sandbox.work().join("nested")).unwrap();
    fs::write(sandbox.work().join("nested/deep.txt"), b"deep\n").unwrap();

    let listed = sandbox.call(json!({
        "service": "fs/1", "op": "list", "owner": owner,
        "args": { "path": sandbox.work().to_str().unwrap() }
    }));
    let entries = listed["result"]["entries"].as_array().unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0]["name"], json!("hello.txt"));
    assert_eq!(entries[0]["kind"], json!("file"));
    assert_eq!(entries[0]["size"], json!(13));
    assert_eq!(entries[1]["kind"], json!("dir"));

    let read = sandbox.call(json!({
        "service": "fs/1", "op": "read", "owner": owner,
        "args": { "path": sandbox.work().join("hello.txt").to_str().unwrap() }
    }));
    assert_eq!(read["result"]["encoding"], json!("utf8"));
    assert_eq!(read["result"]["content"], json!("hello engine\n"));
    assert_eq!(read["result"]["eof"], json!(true));

    // The digest of "hello engine\n", so a wrong answer is a wrong answer and not
    // merely a differently-shaped one.
    let digest = sandbox.call(json!({
        "service": "fs/1", "op": "digest", "owner": owner,
        "args": { "path": sandbox.work().join("hello.txt").to_str().unwrap() }
    }));
    assert_eq!(digest["result"]["size"], json!(13));
    assert_eq!(digest["result"]["digest"].as_str().unwrap().len(), 64);

    let scanned = sandbox.call(json!({
        "service": "fs/1", "op": "scan", "owner": owner,
        "args": { "root": sandbox.work().to_str().unwrap(), "suffix": ".txt" }
    }));
    assert_eq!(scanned["result"]["paths"].as_array().unwrap().len(), 2);
}

#[test]
fn fs_read_answers_a_binary_file_as_base64() {
    let sandbox = Sandbox::new("binary");
    let owner = sandbox.owner();
    let path = sandbox.work().join("blob.bin");
    fs::write(&path, [0xff_u8, 0xfe, 0x00, 0x01]).unwrap();

    let read = sandbox.call(json!({
        "service": "fs/1", "op": "read", "owner": owner,
        "args": { "path": path.to_str().unwrap() }
    }));
    assert_eq!(read["result"]["encoding"], json!("base64"));
    assert_eq!(read["result"]["content"], json!("//4AAQ=="));
}

#[test]
fn a_started_job_outlives_the_call_that_started_it() {
    let sandbox = Sandbox::new("run");
    let owner = sandbox.owner();

    let started = sandbox.call(json!({
        "service": "run/1", "op": "start", "owner": owner,
        "args": { "argv": ["sh", "-c", "echo one; echo two; echo three >&2; exit 7"] }
    }));
    let id = started["result"]["id"].as_str().unwrap().to_owned();

    let settled = sandbox.wait_for_exit(&owner, &id);
    assert_eq!(settled["result"]["state"], json!("exited"));
    assert_eq!(settled["result"]["code"], json!(7));
    assert_eq!(settled["result"]["cancelled"], json!(false));

    let out = sandbox.call(json!({
        "service": "run/1", "op": "output", "owner": owner,
        "args": { "id": id, "stream": "both" }
    }));
    assert_eq!(out["result"]["stdout"]["lines"], json!(["one", "two"]));
    assert_eq!(out["result"]["stderr"]["lines"], json!(["three"]));
}

#[test]
fn output_is_cut_on_the_machine_that_produced_it() {
    let sandbox = Sandbox::new("filter");
    let owner = sandbox.owner();
    let started = sandbox.call(json!({
        "service": "run/1", "op": "start", "owner": owner,
        "args": { "argv": ["sh", "-c", "for i in 1 2 3 4 5 6; do echo line $i; done; echo needle"] }
    }));
    let id = started["result"]["id"].as_str().unwrap().to_owned();
    sandbox.wait_for_exit(&owner, &id);

    let head = sandbox.call(json!({
        "service": "run/1", "op": "output", "owner": owner,
        "args": { "id": id, "head": 2 }
    }));
    assert_eq!(
        head["result"]["stdout"]["lines"],
        json!(["line 1", "line 2"])
    );
    assert_eq!(head["result"]["stdout"]["matched"], json!(7));
    assert_eq!(head["result"]["stdout"]["truncated"], json!(true));

    let tail = sandbox.call(json!({
        "service": "run/1", "op": "output", "owner": owner,
        "args": { "id": id, "tail": 1 }
    }));
    assert_eq!(tail["result"]["stdout"]["lines"], json!(["needle"]));

    let grepped = sandbox.call(json!({
        "service": "run/1", "op": "output", "owner": owner,
        "args": { "id": id, "grep": "needle" }
    }));
    assert_eq!(grepped["result"]["stdout"]["lines"], json!(["needle"]));
    assert_eq!(grepped["result"]["stdout"]["matched"], json!(1));
}

#[test]
fn cancel_stops_a_job_and_says_it_was_cancelled() {
    let sandbox = Sandbox::new("cancel");
    let owner = sandbox.owner();
    let started = sandbox.call(json!({
        "service": "run/1", "op": "start", "owner": owner,
        "args": { "argv": ["sh", "-c", "sleep 120"] }
    }));
    let id = started["result"]["id"].as_str().unwrap().to_owned();

    // The supervisor has to have recorded a pgid before cancelling can reach the tree.
    for _ in 0..100 {
        let status = sandbox.call(json!({
            "service": "run/1", "op": "status", "owner": owner, "args": { "id": id }
        }));
        if status["result"]["state"] == json!("running") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }

    let cancelled = sandbox.call(json!({
        "service": "run/1", "op": "cancel", "owner": owner, "args": { "id": id }
    }));
    assert_eq!(cancelled["ok"], json!(true));

    let settled = sandbox.wait_for_exit(&owner, &id);
    assert_eq!(settled["result"]["state"], json!("exited"));
    assert_eq!(settled["result"]["cancelled"], json!(true));
    assert_eq!(settled["result"]["signal"], json!(15));
}

#[test]
fn a_job_that_outstays_its_timeout_is_stopped() {
    let sandbox = Sandbox::new("timeout");
    let owner = sandbox.owner();
    let started = sandbox.call(json!({
        "service": "run/1", "op": "start", "owner": owner,
        "args": { "argv": ["sh", "-c", "sleep 120"], "timeout_ms": 300 }
    }));
    let id = started["result"]["id"].as_str().unwrap().to_owned();

    let settled = sandbox.wait_for_exit(&owner, &id);
    assert_eq!(settled["result"]["timed_out"], json!(true), "got {settled}");
    assert_eq!(
        settled["result"]["cancelled"],
        json!(false),
        "got {settled}"
    );
}

#[test]
fn the_hosts_deny_list_wins_over_the_call() {
    let sandbox = Sandbox::new("deny");
    let owner = sandbox.owner();
    let config = sandbox.config(r#"{"denyCapabilities":["fs/1.read"],"denyExec":["curl"]}"#);

    let denied_op = sandbox.call_with_config(
        json!({
            "service": "fs/1", "op": "read", "owner": owner,
            "args": { "path": "/etc/hostname" }
        }),
        Some(&config),
    );
    assert_denied(&denied_op);

    // The op beside it is untouched: the entry named one op, not the service.
    let allowed = sandbox.call_with_config(
        json!({
            "service": "fs/1", "op": "list", "owner": owner,
            "args": { "path": sandbox.work().to_str().unwrap() }
        }),
        Some(&config),
    );
    assert_eq!(allowed["ok"], json!(true));

    for program in ["curl", "/usr/bin/curl"] {
        let refused = sandbox.call_with_config(
            json!({
                "service": "run/1", "op": "start", "owner": owner,
                "args": { "argv": [program, "https://example.com"] }
            }),
            Some(&config),
        );
        assert_denied(&refused);
    }
}

#[test]
fn probe_names_the_ops_a_host_denies_one_at_a_time() {
    let sandbox = Sandbox::new("deny-op-probe");
    let config = sandbox.config(r#"{"denyCapabilities":["fs/1.read","fs/1.digest"]}"#);
    let probe = sandbox.call_with_config(
        json!({ "service": "lifecycle", "op": "probe" }),
        Some(&config),
    );
    let services = probe["result"]["services"].as_array().unwrap();
    let fs = services
        .iter()
        .find(|s| s["name"] == json!("fs/1"))
        .unwrap();

    // The service itself is not denied, so a caller reading only `denied` would
    // believe every op it lists can be called.
    assert_eq!(fs["denied"], json!(false));
    assert_eq!(fs["denied_ops"], json!(["read", "digest"]));

    let run = services
        .iter()
        .find(|s| s["name"] == json!("run/1"))
        .unwrap();
    assert_eq!(run["denied_ops"], json!([]));
}

#[test]
fn a_whole_service_can_be_denied_and_probe_says_so() {
    let sandbox = Sandbox::new("deny-service");
    let config = sandbox.config(r#"{"denyCapabilities":["run/1"]}"#);
    let probe = sandbox.call_with_config(
        json!({ "service": "lifecycle", "op": "probe" }),
        Some(&config),
    );
    let services = probe["result"]["services"].as_array().unwrap();
    let run = services
        .iter()
        .find(|s| s["name"] == json!("run/1"))
        .unwrap();
    assert_eq!(run["denied"], json!(true));

    let owner = probe["result"]["owner"].as_str().unwrap().to_owned();
    let refused = sandbox.call_with_config(
        json!({
            "service": "run/1", "op": "start", "owner": owner,
            "args": { "argv": ["true"] }
        }),
        Some(&config),
    );
    assert_denied(&refused);
}

#[test]
fn a_ceiling_that_cannot_be_parsed_refuses_rather_than_opens() {
    let sandbox = Sandbox::new("bad-config");
    let config = sandbox.config("{ this is not json");
    let answer = sandbox.call_with_config(
        json!({ "service": "lifecycle", "op": "version" }),
        Some(&config),
    );
    assert_eq!(answer["ok"], json!(false));
    assert_eq!(answer["error"]["kind"], json!("failed"));
}

#[test]
fn teardown_removes_what_the_engine_put_on_the_machine() {
    let sandbox = Sandbox::new("teardown");
    let owner = sandbox.owner();
    let started = sandbox.call(json!({
        "service": "run/1", "op": "start", "owner": owner,
        "args": { "argv": ["true"] }
    }));
    let id = started["result"]["id"].as_str().unwrap().to_owned();
    sandbox.wait_for_exit(&owner, &id);

    let state_root = sandbox.state().join(&owner);
    assert!(state_root.exists());

    let torn = sandbox.call(json!({
        "service": "lifecycle", "op": "teardown", "owner": owner
    }));
    assert_eq!(torn["ok"], json!(true));
    assert_eq!(torn["result"]["existed"], json!(true));
    assert_eq!(torn["result"]["jobs_removed"], json!(1));
    assert!(!state_root.exists());

    let again = sandbox.call(json!({
        "service": "lifecycle", "op": "teardown", "owner": owner
    }));
    assert_eq!(again["result"]["existed"], json!(false));
}

#[test]
fn teardown_takes_the_timer_off_the_manager_that_holds_it() {
    // The timer is the one thing the engine leaves outside its state directory, so it is
    // the one thing removing that directory cannot reach. Left behind it keeps firing
    // against a directory that is gone, and nothing on the machine still names it.
    let sandbox = Sandbox::new("teardown-timer");
    let owner = sandbox.owner();
    let log = sandbox.root.join("manager.log");
    for manager in ["systemctl", "launchctl"] {
        sandbox.stub(manager, &format!("echo \"$@\" >> {}", log.display()));
    }

    let units = sandbox.unit_dir();
    fs::create_dir_all(&units).unwrap();
    let planted: Vec<String> = if cfg!(target_os = "macos") {
        vec![format!("dazzle-schedule-{SCOPE}.plist")]
    } else {
        vec![
            format!("dazzle-schedule-{SCOPE}.timer"),
            format!("dazzle-schedule-{SCOPE}.service"),
        ]
    };
    // A file the engine did not write is not the engine's to remove, whoever else on
    // this account put it there.
    let theirs = units.join("borgbackup.timer");
    for name in &planted {
        fs::write(units.join(name), "planted").unwrap();
    }
    fs::write(&theirs, "theirs").unwrap();

    let torn = sandbox.call(json!({
        "service": "lifecycle", "op": "teardown", "owner": owner
    }));
    let removed = torn["result"]["timers_removed"].as_array().unwrap();
    for name in &planted {
        let label = name.strip_suffix(".plist").unwrap_or(name);
        assert!(
            removed.contains(&json!(label)),
            "teardown answered {removed:?} without {label}"
        );
        assert!(!units.join(name).exists());
    }
    assert!(theirs.exists());

    // The file is the smaller half: a manager that still holds the job keeps running it
    // whether or not the file that described it is there.
    let told = fs::read_to_string(&log).unwrap();
    if cfg!(target_os = "macos") {
        assert!(told.contains("bootout"), "launchctl was told {told:?}");
    } else {
        assert!(
            told.contains("disable --now"),
            "systemctl was told {told:?}"
        );
        // A unit that failed is held by name after its file is gone, and an account left
        // with dazzle entries under `--failed` has nothing on the machine to explain them.
        assert!(told.contains("reset-failed"), "systemctl was told {told:?}");
    }
}

#[test]
fn an_unbuilt_service_is_refused_by_name() {
    let sandbox = Sandbox::new("unbuilt");
    let owner = sandbox.owner();
    let answer = sandbox.call(json!({
        "service": "git/1", "op": "status", "owner": owner, "args": {}
    }));
    assert_eq!(answer["error"]["kind"], json!("unsupported"));
    assert!(answer["error"]["message"]
        .as_str()
        .unwrap()
        .contains("git/1"));
}

const SCOPE: &str = "aa11bb22cc33dd44ee55ff6600778899aabbccddeeff00112233445566778899";

fn schedule(sandbox: &Sandbox, owner: &str, op: &str, mut args: Value) -> Value {
    args["scope"] = json!(SCOPE);
    sandbox.call(json!({
        "service": "schedule/1", "op": op, "owner": owner, "args": args
    }))
}

fn a_job(sandbox: &Sandbox, revision: u64) -> Value {
    json!({
        "id": "nightly",
        "revision": revision,
        "title": "Nightly sweep",
        "directory": sandbox.work().display().to_string(),
        "agent": "claude",
        "model": "",
        "prompt": "sweep the repository",
        "repeat": "daily",
        "date": "",
        "time": "03:00",
        "timezone": "UTC",
        "timeout": 600,
    })
}

fn tick_queue(sandbox: &Sandbox) {
    assert!(Command::new(BINARY)
        .args(["__tick", SCOPE])
        .env("DAZZLE_ENGINE_STATE", sandbox.state())
        .env(
            "PATH",
            format!(
                "{}:{}",
                sandbox.bin().display(),
                std::env::var("PATH").unwrap_or_default()
            )
        )
        .status()
        .unwrap()
        .success());
}

#[test]
fn a_discovered_home_relative_workspace_is_resolved_on_the_host() {
    let sandbox = Sandbox::new("home-workspace");
    let owner = sandbox.owner();
    sandbox.enable(&owner, SCOPE);
    sandbox.stub("claude", "cat");
    fs::create_dir_all(sandbox.home().join("Projects/fixture")).unwrap();
    let mut job = a_job(&sandbox, 0);
    job["directory"] = json!("~/Projects/fixture");
    let saved = schedule(&sandbox, &owner, "save", json!({"schedule": job}));
    assert_eq!(saved["ok"], true, "{saved}");
    let got = schedule(&sandbox, &owner, "get", json!({"id": "nightly"}));
    assert_eq!(
        got["result"]["directory"],
        sandbox
            .home()
            .join("Projects/fixture")
            .display()
            .to_string()
    );
}

#[test]
fn immediate_tasks_queue_per_workspace_keep_their_prompt_and_can_be_canceled() {
    let sandbox = Sandbox::new("queue");
    let owner = sandbox.owner();
    sandbox.enable(&owner, SCOPE);
    sandbox.stub("claude", "while [ ! -f release ]; do sleep 0.05; done; cat");
    for id in ["first", "second", "third"] {
        let mut job = a_job(&sandbox, 0);
        job["id"] = json!(id);
        job["repeat"] = json!("now");
        job["prompt"] = json!(id);
        let saved = schedule(&sandbox, &owner, "save", json!({"schedule": job}));
        assert_eq!(saved["ok"], true, "{saved}");
    }
    let history = schedule(&sandbox, &owner, "history", json!({}));
    let items = history["result"]["items"].as_array().unwrap();
    let first = items.iter().find(|r| r["schedule"] == "first").unwrap();
    let second = items.iter().find(|r| r["schedule"] == "second").unwrap();
    let third = items.iter().find(|r| r["schedule"] == "third").unwrap();
    assert_eq!(first["status"], "running");
    assert_eq!(second["status"], "queued");
    assert_eq!(third["status"], "queued");
    let mut edited = a_job(&sandbox, 1);
    edited["id"] = json!("second");
    edited["repeat"] = json!("now");
    edited["prompt"] = json!("changed after enqueue");
    assert_eq!(
        schedule(&sandbox, &owner, "save", json!({"schedule": edited}))["ok"],
        true
    );
    assert_eq!(
        schedule(&sandbox, &owner, "cancel", json!({"id": third["id"]}))["ok"],
        true
    );
    assert_eq!(
        schedule(&sandbox, &owner, "cancel", json!({"id": first["id"]}))["ok"],
        true
    );
    fs::write(sandbox.work().join("release"), "").unwrap();
    let mut output = json!({});
    for _ in 0..100 {
        tick_queue(&sandbox);
        output = schedule(&sandbox, &owner, "output", json!({"id": second["id"]}));
        if output["result"]["status"] == "completed" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(output["result"]["status"], "completed", "{output}");
    assert_eq!(output["result"]["text"], "second");
    assert_eq!(
        schedule(&sandbox, &owner, "output", json!({"id": third["id"]}))["result"]["status"],
        "canceled"
    );
    tick_queue(&sandbox);
    assert_eq!(
        schedule(&sandbox, &owner, "history", json!({}))["result"]["items"]
            .as_array()
            .unwrap()
            .len(),
        3
    );
}

#[test]
fn output_exposes_agent_messages_and_warnings_without_hiding_diagnostics() {
    let sandbox = Sandbox::new("readable-output");
    let owner = sandbox.owner();
    sandbox.enable(&owner, SCOPE);
    sandbox.stub("codex", r#"printf '%s\n' '{"type":"item.completed","item":{"type":"error","message":"Tool unavailable"}}' '{"type":"item.completed","item":{"type":"agent_message","text":"Fixture ready"}}'"#);
    let mut job = a_job(&sandbox, 0);
    job["agent"] = json!("codex");
    job["repeat"] = json!("now");
    assert_eq!(
        schedule(&sandbox, &owner, "save", json!({"schedule": job}))["ok"],
        true
    );
    let history = schedule(&sandbox, &owner, "history", json!({}));
    let id = &history["result"]["items"][0]["id"];
    let mut output = json!({});
    for _ in 0..100 {
        output = schedule(&sandbox, &owner, "output", json!({"id": id}));
        if output["result"]["status"] == "completed" {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
    assert_eq!(output["result"]["summary"], "Fixture ready");
    assert_eq!(output["result"]["warnings"], json!(["Tool unavailable"]));
    assert!(output["result"]["text"]
        .as_str()
        .unwrap()
        .contains("item.completed"));
}

#[test]
fn a_host_is_asked_what_it_can_do_before_anything_is_scheduled_on_it() {
    let sandbox = Sandbox::isolated("schedule-inspect");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");

    let answer = schedule(&sandbox, &owner, "inspect", json!({}));
    let result = &answer["result"];
    assert_eq!(answer["ok"], json!(true));
    assert_eq!(result["installed"], json!(false));
    assert_eq!(result["timer_active"], json!(false));
    // The stub is on PATH, so the host reports it the way it would a real install.
    assert_eq!(result["agents"], json!(["claude"]));
    assert!(!result["timezone"].as_str().unwrap().is_empty());
}

#[test]
fn a_host_that_was_never_set_up_takes_no_schedules() {
    let sandbox = Sandbox::new("schedule-ungated");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");

    let answer = schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    assert_eq!(answer["error"]["kind"], json!("not_found"));
    assert!(answer["error"]["message"]
        .as_str()
        .unwrap()
        .contains("enable scheduling"));
}

#[test]
fn a_scope_is_a_plugin_namespace_and_nothing_that_could_climb_out_of_one() {
    let sandbox = Sandbox::new("schedule-scope");
    let owner = sandbox.owner();
    for bad in ["../escape", "", "AA11BB22", &"z".repeat(64)] {
        let answer = sandbox.call(json!({
            "service": "schedule/1", "op": "list", "owner": owner,
            "args": { "scope": bad }
        }));
        assert_eq!(
            answer["error"]["kind"],
            json!("bad_request"),
            "{bad} was accepted as a scope"
        );
    }
}

#[test]
fn a_saved_schedule_comes_back_with_the_next_time_it_is_due() {
    let sandbox = Sandbox::new("schedule-save");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);

    let saved = schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    assert_eq!(saved["result"]["revision"], json!(1));

    let listed = schedule(&sandbox, &owner, "list", json!({}));
    let items = listed["result"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["id"], json!("nightly"));
    assert_eq!(items[0]["enabled"], json!(true));
    assert!(items[0]["next_due"].as_i64().unwrap() > 0);
    assert!(items[0]["next_label"].as_str().unwrap().contains("T03:00"));
    // The listing is a summary; the prompt is only handed over when one is asked for.
    assert!(items[0].get("prompt").is_none());

    let got = schedule(&sandbox, &owner, "get", json!({ "id": "nightly" }));
    assert_eq!(got["result"]["prompt"], json!("sweep the repository"));
}

#[test]
fn a_save_against_a_revision_the_host_has_moved_past_is_refused() {
    let sandbox = Sandbox::new("schedule-revision");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);

    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    let stale = schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    assert_eq!(stale["error"]["kind"], json!("denied"));
    assert!(stale["error"]["message"]
        .as_str()
        .unwrap()
        .contains("refresh"));

    let fresh = schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 1) }),
    );
    assert_eq!(fresh["result"]["revision"], json!(2));
}

#[test]
fn a_schedule_naming_an_agent_the_machine_does_not_have_is_refused() {
    let sandbox = Sandbox::isolated("schedule-agent");
    let owner = sandbox.owner();
    sandbox.enable(&owner, SCOPE);

    let answer = schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    assert_eq!(answer["error"]["kind"], json!("not_found"));
    assert!(answer["error"]["message"]
        .as_str()
        .unwrap()
        .contains("claude"));
}

#[test]
fn a_run_asked_for_twice_under_one_slot_starts_one_agent() {
    let sandbox = Sandbox::new("schedule-run");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);
    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );

    let first = schedule(
        &sandbox,
        &owner,
        "run",
        json!({ "id": "nightly", "request_id": "req-1" }),
    );
    let run_id = first["result"]["id"].as_str().unwrap().to_owned();

    // The same request arriving again — a retry after a dropped tunnel — finds the
    // slot taken and returns the run that already exists.
    let again = schedule(
        &sandbox,
        &owner,
        "run",
        json!({ "id": "nightly", "request_id": "req-1" }),
    );
    assert_eq!(again["result"]["id"], json!(run_id));

    sandbox.wait_for_exit(&owner, &run_id);
    let history = schedule(&sandbox, &owner, "history", json!({}));
    let items = history["result"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 1, "one slot, one run");
    assert_eq!(items[0]["status"], json!("completed"));
    assert_eq!(items[0]["exit_code"], json!(0));

    // The stub echoes its stdin, which proves the prompt reached the agent that way
    // rather than through an argv the machine's process table would carry.
    let output = schedule(&sandbox, &owner, "output", json!({ "id": run_id }));
    assert_eq!(output["result"]["status"], json!("completed"));
    assert!(output["result"]["text"]
        .as_str()
        .unwrap()
        .contains("sweep the repository"));
}

#[test]
fn a_paused_scope_starts_nothing_until_it_is_resumed() {
    let sandbox = Sandbox::new("schedule-pause");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);
    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );

    assert_eq!(
        schedule(&sandbox, &owner, "pause_scope", json!({}))["result"]["paused"],
        json!(true)
    );
    let refused = schedule(
        &sandbox,
        &owner,
        "run",
        json!({ "id": "nightly", "request_id": "req-1" }),
    );
    assert_eq!(refused["error"]["kind"], json!("denied"));
    assert_eq!(
        schedule(&sandbox, &owner, "list", json!({}))["result"]["paused"],
        json!(true)
    );

    schedule(&sandbox, &owner, "resume_scope", json!({}));
    let allowed = schedule(
        &sandbox,
        &owner,
        "run",
        json!({ "id": "nightly", "request_id": "req-2" }),
    );
    assert_eq!(allowed["ok"], json!(true));
    sandbox.wait_for_exit(&owner, allowed["result"]["id"].as_str().unwrap());
}

#[test]
fn usage_counts_what_the_scope_is_holding() {
    let sandbox = Sandbox::new("schedule-usage");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);
    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );

    let usage = schedule(&sandbox, &owner, "usage", json!({}))["result"].clone();
    assert_eq!(usage["schema_version"], json!(2));
    assert_eq!(usage["schedules"], json!(1));
    assert_eq!(usage["runs"], json!(0));
    assert_eq!(usage["history_limit"], json!(1000));
    assert!(usage["bytes"].as_u64().unwrap() > 0);
}

#[test]
fn the_host_can_refuse_one_scheduler_op_while_carrying_the_rest() {
    let sandbox = Sandbox::new("schedule-deny");
    let owner = sandbox.owner();
    let config = sandbox.config(r#"{"denyCapabilities":["schedule/1.save"]}"#);

    let answer = sandbox.call_with_config(
        json!({
            "service": "schedule/1", "op": "save", "owner": owner,
            "args": { "scope": SCOPE, "schedule": {} }
        }),
        Some(&config),
    );
    assert_eq!(answer["error"]["kind"], json!("denied"));

    let probe = sandbox.call_with_config(
        json!({ "service": "lifecycle", "op": "probe" }),
        Some(&config),
    );
    let service = probe["result"]["services"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["name"] == json!("schedule/1"))
        .unwrap()
        .clone();
    assert_eq!(service["denied"], json!(false));
    assert_eq!(service["denied_ops"], json!(["save"]));
}

#[test]
fn a_save_answers_for_the_schedule_it_saved_and_leaves_a_pause_alone() {
    let sandbox = Sandbox::new("schedule-second");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    sandbox.enable(&owner, SCOPE);

    let mut second = a_job(&sandbox, 0);
    second["id"] = json!("weekly");
    second["time"] = json!("04:00");
    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );
    schedule(&sandbox, &owner, "save", json!({ "schedule": second }));

    schedule(&sandbox, &owner, "pause", json!({ "id": "nightly" }));
    let paused = schedule(&sandbox, &owner, "get", json!({ "id": "nightly" }));
    assert_eq!(paused["result"]["enabled"], json!(false));
    let revision = paused["result"]["revision"].as_u64().unwrap();

    // "nightly" is no longer the last schedule stored, so a save that answered with
    // whichever one happened to be last would name "weekly" here.
    let mut edited = a_job(&sandbox, revision);
    edited["title"] = json!("Renamed");
    let saved = schedule(&sandbox, &owner, "save", json!({ "schedule": edited }));
    assert_eq!(saved["result"]["id"], json!("nightly"));

    let after = schedule(&sandbox, &owner, "get", json!({ "id": "nightly" }));
    assert_eq!(after["result"]["title"], json!("Renamed"));
    assert_eq!(
        after["result"]["enabled"],
        json!(false),
        "editing a paused schedule must not resume it"
    );
}

/// A pid that is certainly nobody's: spawned, waited for, and never reused while the
/// test still holds the slot open through its own reaping.
fn a_dead_pid() -> i32 {
    let mut child = Command::new("sh").arg("-c").arg("exit 0").spawn().unwrap();
    let pid = child.id() as i32;
    child.wait().unwrap();
    pid
}

fn a_running_job(sandbox: &Sandbox, owner: &str, id: &str, pid: i32, supervisor: i32) {
    let dir = sandbox.state().join(owner).join("jobs").join(id);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("status.json"),
        json!({
            "state": "running", "pid": pid, "pgid": pid, "supervisor": supervisor,
            "started": 1, "cancelled": false, "timed_out": false
        })
        .to_string(),
    )
    .unwrap();
}

#[test]
fn a_reaped_child_is_not_a_lost_job_while_its_supervisor_is_still_there() {
    let sandbox = Sandbox::new("liveness");
    let owner = sandbox.owner();

    // The supervisor reaps its child before it writes the exit down. A reader that
    // lands in between sees the child gone, and the job is not lost for that: the one
    // process that can still answer for it is alive.
    a_running_job(
        &sandbox,
        &owner,
        "reaped",
        a_dead_pid(),
        std::process::id() as i32,
    );
    let answer = sandbox.call(json!({
        "service": "run/1", "op": "status", "owner": owner, "args": { "id": "reaped" }
    }));
    assert_eq!(answer["result"]["state"], json!("running"), "got {answer}");

    a_running_job(
        &sandbox,
        &owner,
        "orphan",
        std::process::id() as i32,
        a_dead_pid(),
    );
    let answer = sandbox.call(json!({
        "service": "run/1", "op": "status", "owner": owner, "args": { "id": "orphan" }
    }));
    assert_eq!(answer["result"]["state"], json!("lost"), "got {answer}");
}

fn a_starting_job(sandbox: &Sandbox, owner: &str, id: &str, created: u64) {
    let dir = sandbox.state().join(owner).join("jobs").join(id);
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("spec.json"),
        json!({ "argv": ["true"], "cwd": null, "env": [], "timeout_ms": null, "created": created })
            .to_string(),
    )
    .unwrap();
    fs::write(
        dir.join("status.json"),
        json!({ "state": "starting", "cancelled": false, "timed_out": false }).to_string(),
    )
    .unwrap();
}

#[test]
fn a_supervisor_that_never_wrote_a_pid_stops_being_called_alive() {
    let sandbox = Sandbox::new("startup-grace");
    let owner = sandbox.owner();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as u64;

    // Nothing to ask after in either case. What separates them is how long the record
    // has gone unanswered: one exec of the engine, or longer than any exec takes.
    a_starting_job(&sandbox, &owner, "fresh", now);
    let answer = sandbox.call(json!({
        "service": "run/1", "op": "status", "owner": owner, "args": { "id": "fresh" }
    }));
    assert_eq!(answer["result"]["state"], json!("starting"), "got {answer}");

    a_starting_job(&sandbox, &owner, "abandoned", now - 120_000);
    let answer = sandbox.call(json!({
        "service": "run/1", "op": "status", "owner": owner, "args": { "id": "abandoned" }
    }));
    assert_eq!(answer["result"]["state"], json!("lost"), "got {answer}");
}

#[test]
fn the_timer_ticks_against_the_same_state_the_service_wrote() {
    let sandbox = Sandbox::new("schedule-tick");
    let owner = sandbox.owner();
    sandbox.stub("claude", "cat");
    let root = sandbox.enable(&owner, SCOPE);
    schedule(
        &sandbox,
        &owner,
        "save",
        json!({ "schedule": a_job(&sandbox, 0) }),
    );

    // Due in the past, which no schedule ever is when it is saved: the next run is
    // computed forward from now, and a test cannot wait until 03:00 for one.
    let file = root.join("state.json");
    let mut state: Value = serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    state["schedules"][0]["next_due"] = json!(1);
    fs::write(&file, state.to_string()).unwrap();

    let ticked = Command::new(BINARY)
        .arg("__tick")
        .arg(SCOPE)
        .env("DAZZLE_ENGINE_STATE", sandbox.state())
        .env(
            "PATH",
            format!(
                "{}:{}",
                sandbox.bin().display(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .output()
        .unwrap();
    assert!(
        ticked.status.success(),
        "__tick exited {:?}: {}",
        ticked.status.code(),
        String::from_utf8_lossy(&ticked.stderr)
    );

    // The tick derives its own state root. One that derived a different root would
    // find no schedule due, exit cleanly, and leave this history empty.
    let history = schedule(&sandbox, &owner, "history", json!({}));
    let items = history["result"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 1, "got {history}");
    assert_eq!(items[0]["title"], json!("Nightly sweep"));
}

fn session_of<'a>(watch: &'a Value, key: &str) -> &'a Value {
    watch["result"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|session| session["key"] == json!(key))
        .unwrap_or_else(|| panic!("no session {key} in {watch}"))
}

#[test]
fn an_agent_hook_is_what_the_phone_watches() {
    let sandbox = Sandbox::new("agents-watch");
    let owner = sandbox.owner();
    let start = json!({ "hook_event_name": "SessionStart", "session_id": "s1", "cwd": "/w" });
    assert_eq!(sandbox.hook("claude", start), "");
    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "fix the build" }),
    );

    let watch = sandbox.agents(&owner, "watch", json!({}));
    let session = session_of(&watch, "claude:s1");
    assert_eq!(session["state"], json!("working"));
    assert_eq!(session["prompt"], json!("fix the build"));
    assert_eq!(session["cwd"], json!("/w"));

    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "Stop", "session_id": "s1", "last_assistant_message": "done, 3 tests fixed" }),
    );
    let watch = sandbox.agents(&owner, "watch", json!({}));
    let session = session_of(&watch, "claude:s1");
    assert_eq!(session["state"], json!("done"));
    assert_eq!(session["message"], json!("done, 3 tests fixed"));
}

#[test]
fn a_subagent_does_not_end_its_parent_turn() {
    let sandbox = Sandbox::new("agents-subagent");
    let owner = sandbox.owner();
    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "go" }),
    );
    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "Stop", "session_id": "s1", "agent_id": "a1" }),
    );
    let watch = sandbox.agents(&owner, "watch", json!({}));
    assert_eq!(session_of(&watch, "claude:s1")["state"], json!("working"));
}

#[test]
fn a_hook_given_garbage_leaves_its_agent_alone() {
    let sandbox = Sandbox::new("agents-garbage");
    let mut command = sandbox.command(&sandbox.bin().display().to_string());
    let mut child = command
        .args(["hook", "claude"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(b"not json").unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    assert!(output.stdout.is_empty());
}

fn pending_approval(sandbox: &Sandbox, owner: &str, key: &str) -> Value {
    for _ in 0..100 {
        let watch = sandbox.agents(owner, "watch", json!({}));
        let approval = watch["result"]["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|session| session["key"] == json!(key))
            .map(|session| session["approval"].clone())
            .unwrap_or(Value::Null);
        if !approval.is_null() {
            return approval;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    panic!("the approval never showed");
}

#[test]
fn an_approval_answered_on_the_phone_is_the_agent_decision() {
    let sandbox = Sandbox::new("agents-approve");
    let owner = sandbox.owner();
    let hook = sandbox.spawn_hook(
        "claude",
        json!({
            "hook_event_name": "PermissionRequest",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": { "command": "rm -rf build", "description": "clean" },
        }),
    );

    let approval = pending_approval(&sandbox, &owner, "claude:s1");
    assert_eq!(approval["tool"], json!("Bash"));
    assert_eq!(approval["summary"], json!("rm -rf build"));
    let watch = sandbox.agents(&owner, "watch", json!({}));
    assert_eq!(session_of(&watch, "claude:s1")["state"], json!("blocked"));

    let answer = sandbox.agents(
        &owner,
        "answer",
        json!({ "id": approval["id"], "decision": "deny" }),
    );
    assert_eq!(answer["ok"], json!(true), "{answer}");

    let output = hook.wait_with_output().unwrap();
    assert!(output.status.success());
    let decision: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        decision["hookSpecificOutput"]["hookEventName"],
        json!("PermissionRequest")
    );
    assert_eq!(
        decision["hookSpecificOutput"]["decision"]["behavior"],
        json!("deny")
    );

    let watch = sandbox.agents(&owner, "watch", json!({}));
    let session = session_of(&watch, "claude:s1");
    assert_eq!(session["state"], json!("working"));
    assert!(session["approval"].is_null());

    let again = sandbox.agents(
        &owner,
        "answer",
        json!({ "id": approval["id"], "decision": "allow" }),
    );
    assert_eq!(again["error"]["kind"], json!("not_found"));
}

#[test]
fn an_approval_taken_at_the_terminal_releases_the_hook_silently() {
    let sandbox = Sandbox::new("agents-terminal");
    let owner = sandbox.owner();
    let hook = sandbox.spawn_hook(
        "codex",
        json!({
            "hook_event_name": "PermissionRequest",
            "session_id": "s2",
            "turn_id": "t1",
            "tool_name": "shell",
            "tool_input": { "command": "cargo test" },
        }),
    );
    let approval = pending_approval(&sandbox, &owner, "codex:s2");

    sandbox.hook(
        "codex",
        json!({ "hook_event_name": "PostToolUse", "session_id": "s2" }),
    );
    let output = hook.wait_with_output().unwrap();
    assert!(output.status.success());
    assert!(output.stdout.is_empty(), "the hook answered for the terminal");

    let late = sandbox.agents(
        &owner,
        "answer",
        json!({ "id": approval["id"], "decision": "allow" }),
    );
    assert_eq!(late["error"]["kind"], json!("not_found"));
}

#[test]
fn watch_holds_until_something_changes() {
    let sandbox = Sandbox::new("agents-longpoll");
    let owner = sandbox.owner();
    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "SessionStart", "session_id": "s1" }),
    );
    let first = sandbox.agents(&owner, "watch", json!({}));
    let generation = first["result"]["generation"].clone();

    let started = std::time::Instant::now();
    let held = sandbox.agents(
        &owner,
        "watch",
        json!({ "generation": generation, "wait_ms": 400 }),
    );
    assert!(started.elapsed() >= std::time::Duration::from_millis(350));
    assert_eq!(held["result"]["generation"], generation);

    let stale = sandbox.agents(&owner, "watch", json!({ "generation": 0, "wait_ms": 5000 }));
    assert_eq!(stale["result"]["generation"], generation);
}

#[test]
fn a_transcript_reads_as_a_conversation() {
    let sandbox = Sandbox::new("agents-transcript");
    let owner = sandbox.owner();
    let path = sandbox.work().join("s1.jsonl");
    let lines = [
        json!({ "type": "user", "message": { "role": "user", "content": "run the tests" } }),
        json!({ "type": "assistant", "message": { "content": [
            { "type": "thinking", "thinking": "hm" },
            { "type": "text", "text": "Running them." },
            { "type": "tool_use", "id": "tu1", "name": "Bash", "input": { "command": "cargo test" } },
        ] } }),
        json!({ "type": "user", "isSidechain": true, "message": { "content": "a subagent's prompt" } }),
        json!({ "type": "user", "message": { "content": [
            { "type": "tool_result", "tool_use_id": "tu1", "content": "ok", "is_error": false },
        ] } }),
    ];
    let body: String = lines.iter().map(|line| format!("{line}\n")).collect();
    fs::write(&path, body).unwrap();
    sandbox.hook(
        "claude",
        json!({ "hook_event_name": "SessionStart", "session_id": "s1", "transcript_path": path }),
    );

    let answer = sandbox.agents(&owner, "transcript", json!({ "session": "claude:s1" }));
    let items = answer["result"]["items"].as_array().unwrap();
    let kinds: Vec<&str> = items.iter().map(|item| item["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, vec!["user", "assistant", "tool", "result"]);
    assert_eq!(items[2]["tool"], json!("Bash"));
    assert_eq!(items[2]["text"], json!("cargo test"));
    assert_eq!(items[3]["tool_id"], json!("tu1"));
    assert_eq!(answer["result"]["last"], json!(3));

    let appended = json!({ "type": "assistant", "message": { "content": [{ "type": "text", "text": "All green." }] } });
    let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
    writeln!(file, "{appended}").unwrap();
    let next = sandbox.agents(
        &owner,
        "transcript",
        json!({ "session": "claude:s1", "after": 3 }),
    );
    let items = next["result"]["items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    assert_eq!(items[0]["text"], json!("All green."));
}

#[test]
fn install_adds_the_hooks_beside_the_user_own_and_teardown_takes_only_them() {
    let sandbox = Sandbox::new("agents-install");
    let owner = sandbox.owner();
    let settings = sandbox.home().join(".claude/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    let mine = json!({ "hooks": [{ "type": "command", "command": "notify-send hi" }] });
    fs::write(
        &settings,
        json!({ "model": "opus", "hooks": { "Stop": [mine] } }).to_string(),
    )
    .unwrap();

    let before = sandbox.agents(&owner, "hooks", json!({}));
    let claude = &before["result"]["agents"][0];
    assert_eq!(claude["agent"], json!("claude"));
    assert_eq!(claude["installed"], json!(false));
    assert_eq!(claude["writable"], json!(true));

    let installed = sandbox.agents(&owner, "install", json!({ "agent": "claude" }));
    assert_eq!(installed["ok"], json!(true), "{installed}");
    let written: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(written["model"], json!("opus"));
    assert_eq!(written["hooks"]["Stop"].as_array().unwrap().len(), 2);
    assert_eq!(
        written["hooks"]["PermissionRequest"][0]["hooks"][0]["command"],
        json!("dazzle-engine hook claude")
    );

    sandbox.agents(&owner, "install", json!({ "agent": "claude" }));
    let twice: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(twice["hooks"]["Stop"].as_array().unwrap().len(), 2);

    let after = sandbox.agents(&owner, "hooks", json!({}));
    assert_eq!(after["result"]["agents"][0]["installed"], json!(true));

    let teardown = sandbox.call(json!({
        "service": "lifecycle", "op": "teardown", "owner": owner
    }));
    assert_eq!(teardown["result"]["hooks_removed"].as_array().unwrap().len(), 1);
    let left: Value = serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(left["hooks"], json!({ "Stop": [mine] }));
}

#[test]
fn a_config_a_declaration_owns_is_shown_rather_than_written() {
    let sandbox = Sandbox::new("agents-readonly");
    let owner = sandbox.owner();
    let store = sandbox.work().join("hooks.json");
    fs::write(&store, "{}").unwrap();
    fs::create_dir_all(sandbox.home().join(".codex")).unwrap();
    std::os::unix::fs::symlink(&store, sandbox.home().join(".codex/hooks.json")).unwrap();

    let hooks = sandbox.agents(&owner, "hooks", json!({}));
    let codex = &hooks["result"]["agents"][1];
    assert_eq!(codex["agent"], json!("codex"));
    assert_eq!(codex["writable"], json!(false));
    assert_eq!(
        codex["entries"]["hooks"]["PermissionRequest"][0]["hooks"][0]["command"],
        json!("dazzle-engine hook codex")
    );

    let refused = sandbox.agents(&owner, "install", json!({ "agent": "codex" }));
    assert_eq!(refused["error"]["kind"], json!("denied"));
    assert_eq!(fs::read_to_string(&store).unwrap(), "{}");
}
