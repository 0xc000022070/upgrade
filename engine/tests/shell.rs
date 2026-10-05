use aes::Aes128;
use ocb3::aead::{Aead, KeyInit};
use ocb3::Ocb3;
use serde_json::{json, Value};
use std::fs;
use std::io::Write;
use std::net::UdpSocket;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};

const BINARY: &str = env!("CARGO_BIN_EXE_upgrade-engine");
static COUNTER: AtomicU32 = AtomicU32::new(0);

const TO_CLIENT: u64 = 1 << 63;
const RECORD_PTY: u8 = 1;
const RECORD_SNAPSHOT: u8 = 2;
const RECORD_EXIT: u8 = 3;
const PATIENCE: Duration = Duration::from_secs(10);

type Cipher = Ocb3<Aes128, ocb3::consts::U12, ocb3::consts::U16>;

struct Sandbox {
    root: PathBuf,
    owner: String,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let unique = COUNTER.fetch_add(1, Ordering::SeqCst);
        let root = std::env::temp_dir().join(format!(
            "upgrade-engine-shell-{}-{name}-{unique}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("state")).unwrap();
        fs::create_dir_all(root.join("home")).unwrap();
        let mut sandbox = Self {
            root,
            owner: String::new(),
        };
        sandbox.owner = sandbox.raw(json!({ "service": "lifecycle", "op": "probe" }))["result"]
            ["owner"]
            .as_str()
            .unwrap()
            .to_owned();
        sandbox
    }

    fn raw(&self, request: Value) -> Value {
        let mut child = Command::new(BINARY)
            .env("UPGRADE_ENGINE_STATE", self.root.join("state"))
            .env("HOME", self.root.join("home"))
            .env("XDG_CONFIG_HOME", self.root.join("home/config"))
            .env_remove("UPGRADE_ENGINE_CONFIG")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child
            .stdin
            .take()
            .unwrap()
            .write_all(request.to_string().as_bytes())
            .unwrap();
        let output = child.wait_with_output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn shell(&self, op: &str, args: Value) -> Value {
        let answer =
            self.raw(json!({ "service": "shell/1", "op": op, "owner": self.owner, "args": args }));
        assert_eq!(answer["ok"], json!(true), "{answer}");
        answer["result"].clone()
    }

    fn start(&self, tab: &str, extra: Value) -> Value {
        let mut args = json!({ "tab": tab, "cols": 80, "rows": 24, "command": ["/bin/sh"] });
        for (key, value) in extra.as_object().unwrap() {
            args[key] = value.clone();
        }
        self.shell("start", args)
    }

    fn tabs(&self) -> Vec<String> {
        self.shell("list", json!({}))["shells"]
            .as_array()
            .unwrap()
            .iter()
            .map(|shell| shell["tab"].as_str().unwrap().to_owned())
            .collect()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = self.raw(json!({ "service": "lifecycle", "op": "teardown", "owner": self.owner }));
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn base64_decode(text: &str) -> Vec<u8> {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    let (mut acc, mut bits) = (0u32, 0);
    for byte in text.bytes().filter(|&b| b != b'=') {
        acc = acc << 6 | ALPHABET.iter().position(|&c| c == byte).unwrap() as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    out
}

fn base64_encode(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let packed = chunk
            .iter()
            .enumerate()
            .fold(0u32, |acc, (i, &b)| acc | u32::from(b) << (16 - 8 * i));
        for i in 0..4 {
            out.push(if i <= chunk.len() {
                ALPHABET[(packed >> (18 - 6 * i)) as usize & 63] as char
            } else {
                '='
            });
        }
    }
    out
}

#[derive(Debug, PartialEq)]
enum Record {
    Pty(Vec<u8>),
    Snapshot(Vec<u8>),
    Exit(i32),
}

struct Client {
    socket: UdpSocket,
    cipher: Cipher,
    sent: u64,
    ack: u64,
    pending: Vec<u8>,
    records: Vec<Record>,
    jumped: bool,
    input: Vec<u8>,
    input_ack: u64,
    keyframe: u32,
    size_gen: u32,
    size: [u16; 4],
    close: bool,
}

impl Client {
    fn connect(started: &Value) -> Self {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket
            .connect(("127.0.0.1", started["port"].as_u64().unwrap() as u16))
            .unwrap();
        socket
            .set_read_timeout(Some(Duration::from_millis(20)))
            .unwrap();
        let mut client = Self {
            socket,
            cipher: Cipher::new(&[0; 16].into()),
            sent: 0,
            ack: 0,
            pending: Vec::new(),
            records: Vec::new(),
            jumped: false,
            input: Vec::new(),
            input_ack: 0,
            keyframe: 0,
            size_gen: 0,
            size: [80, 24, 0, 0],
            close: false,
        };
        client.rekey(started);
        client
    }

    fn rekey(&mut self, started: &Value) {
        let key: [u8; 16] = base64_decode(started["key"].as_str().unwrap())
            .try_into()
            .unwrap();
        self.cipher = Cipher::new(&key.into());
        self.sent = 0;
    }

    fn seal(&mut self, plaintext: &[u8]) -> Vec<u8> {
        let wire = self.sent.to_be_bytes();
        self.sent += 1;
        let mut nonce = [0u8; 12];
        nonce[4..].copy_from_slice(&wire);
        let mut packet = wire.to_vec();
        packet.extend(self.cipher.encrypt(&nonce.into(), plaintext).unwrap());
        packet
    }

    fn send(&mut self) {
        let unacked = &self.input[self.input_ack as usize..];
        let mut plaintext = vec![1, u8::from(!unacked.is_empty()) | u8::from(self.close) << 1];
        plaintext.extend(0u16.to_be_bytes());
        plaintext.extend(0xffffu16.to_be_bytes());
        plaintext.extend(self.ack.to_be_bytes());
        plaintext.extend(self.keyframe.to_be_bytes());
        plaintext.extend(self.size_gen.to_be_bytes());
        for field in self.size {
            plaintext.extend(field.to_be_bytes());
        }
        if !unacked.is_empty() {
            plaintext.extend(self.input_ack.to_be_bytes());
            plaintext.extend_from_slice(unacked);
        }
        let packet = self.seal(&plaintext);
        let _ = self.socket.send(&packet);
    }

    fn receive(&mut self) -> bool {
        let mut buf = [0u8; 2048];
        let mut heard = false;
        while let Ok(n) = self.socket.recv(&mut buf) {
            let packet = &buf[..n];
            let wire: [u8; 8] = packet[..8].try_into().unwrap();
            assert_ne!(
                u64::from_be_bytes(wire) & TO_CLIENT,
                0,
                "a server nonce has bit 63 set"
            );
            let mut nonce = [0u8; 12];
            nonce[4..].copy_from_slice(&wire);
            let Ok(plain) = self.cipher.decrypt(&nonce.into(), &packet[8..]) else {
                continue;
            };
            heard = true;
            self.take(&plain);
        }
        heard
    }

    fn take(&mut self, plain: &[u8]) {
        assert_eq!(plain[0], 1);
        let flags = plain[1];
        let input_ack = u64::from_be_bytes(plain[6..14].try_into().unwrap());
        self.input_ack = self.input_ack.max(input_ack);
        if flags & 1 == 0 {
            return;
        }
        let offset = u64::from_be_bytes(plain[26..34].try_into().unwrap());
        let data = &plain[34..];
        if flags & 2 != 0 && offset >= self.ack {
            self.pending.clear();
            self.ack = offset;
            self.jumped = true;
        }
        let end = offset + data.len() as u64;
        if offset <= self.ack && end > self.ack {
            self.pending
                .extend_from_slice(&data[(self.ack - offset) as usize..]);
            self.ack = end;
        }
        self.parse();
    }

    fn parse(&mut self) {
        while self.pending.len() >= 5 {
            let len = u32::from_be_bytes(self.pending[1..5].try_into().unwrap()) as usize;
            if self.pending.len() < 5 + len {
                return;
            }
            let body = self.pending[5..5 + len].to_vec();
            self.records.push(match self.pending[0] {
                RECORD_PTY => Record::Pty(body),
                RECORD_SNAPSHOT => Record::Snapshot(body),
                RECORD_EXIT => Record::Exit(i32::from_be_bytes(body[..4].try_into().unwrap())),
                kind => panic!("unknown record kind {kind}"),
            });
            self.pending.drain(..5 + len);
        }
    }

    fn type_in(&mut self, text: &str) {
        self.input.extend_from_slice(text.as_bytes());
    }

    fn output(&self) -> String {
        let mut out = Vec::new();
        for record in &self.records {
            if let Record::Pty(bytes) = record {
                out.extend_from_slice(bytes);
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    fn until(&mut self, what: &str, mut done: impl FnMut(&Self) -> bool) {
        let deadline = Instant::now() + PATIENCE;
        while !done(self) {
            assert!(
                Instant::now() < deadline,
                "never saw {what}; output so far: {:?}",
                self.output()
            );
            self.send();
            self.receive();
        }
    }
}

#[test]
fn a_started_shell_echoes_input_back_as_pty_records() {
    let sandbox = Sandbox::new("echo");
    let started = sandbox.start("echo", json!({}));
    assert_eq!(started["resumed"], json!(false));
    assert_eq!(started["key"].as_str().unwrap().len(), 22);

    let mut client = Client::connect(&started);
    client.type_in("echo hi-$((40+2))\n");
    client.until("the sum", |c| c.output().contains("hi-42"));
    assert_eq!(client.input_ack, client.input.len() as u64);
    assert_eq!(sandbox.tabs(), vec!["echo"]);
}

#[test]
fn a_keyframe_request_is_answered_with_a_snapshot_jump() {
    let sandbox = Sandbox::new("keyframe");
    let started = sandbox.start("snap", json!({}));
    let mut client = Client::connect(&started);
    client.type_in("echo marker-$((6*7))\n");
    client.until("the marker", |c| c.output().contains("marker-42"));

    client.records.clear();
    client.keyframe = 1;
    client.until("a snapshot", |c| {
        c.records.iter().any(|r| matches!(r, Record::Snapshot(_)))
    });
    assert!(client.jumped);
    let Some(Record::Snapshot(body)) = client.records.first() else {
        panic!("a keyframe begins with its snapshot: {:?}", client.records);
    };
    assert!(body.starts_with(b"GHOSTSNP"));
}

#[test]
fn a_resize_reaches_the_shell() {
    let sandbox = Sandbox::new("resize");
    let started = sandbox.start("size", json!({}));
    let mut client = Client::connect(&started);
    client.size = [132, 43, 0, 0];
    client.size_gen = 1;
    client.type_in("stty size\n");
    client.until("the new size", |c| c.output().contains("43 132"));
}

#[test]
fn the_shell_exit_is_the_last_record_and_the_server_goes_away() {
    let sandbox = Sandbox::new("exit");
    let started = sandbox.start("bye", json!({}));
    let mut client = Client::connect(&started);
    client.type_in("exit 7\n");
    client.until("the exit", |c| c.records.contains(&Record::Exit(7)));
    assert_eq!(client.records.last(), Some(&Record::Exit(7)));

    let deadline = Instant::now() + PATIENCE;
    while !sandbox.tabs().is_empty() {
        assert!(
            Instant::now() < deadline,
            "the server outlived an acked exit"
        );
        client.send();
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn close_ends_the_shell_from_the_phone() {
    let sandbox = Sandbox::new("close");
    let started = sandbox.start("close", json!({}));
    let mut client = Client::connect(&started);
    client.type_in(":\n");
    client.until("first contact", |c| c.input_ack == c.input.len() as u64);
    client.close = true;
    let deadline = Instant::now() + PATIENCE;
    while !sandbox.tabs().is_empty() {
        assert!(Instant::now() < deadline, "close did not end the server");
        client.send();
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn resuming_rekeys_the_running_session_and_keeps_its_shell() {
    let sandbox = Sandbox::new("resume");
    let first = sandbox.start("keep", json!({}));
    let mut client = Client::connect(&first);
    client.type_in("export KEPT=yes-$((1+1))\n");
    client.until("the export", |c| c.input_ack == c.input.len() as u64);

    let second = sandbox.start("keep", json!({}));
    assert_eq!(second["resumed"], json!(true));
    assert_eq!(second["port"], first["port"]);
    assert_eq!(second["pid"], first["pid"]);
    assert_ne!(second["key"], first["key"]);

    for _ in 0..10 {
        client.send();
        std::thread::sleep(Duration::from_millis(20));
        assert!(!client.receive(), "the old key still opens packets");
    }

    client.rekey(&second);
    client.keyframe = 1;
    client.type_in("echo kept-$KEPT\n");
    client.until("the variable set before the resume", |c| {
        c.output().contains("kept-yes-2")
    });
    assert!(client.jumped, "a rekeyed client starts from a keyframe");
}

#[test]
fn resume_false_replaces_the_running_session() {
    let sandbox = Sandbox::new("fresh");
    let first = sandbox.start("fresh", json!({}));
    let second = sandbox.start("fresh", json!({ "resume": false }));
    assert_eq!(second["resumed"], json!(false));
    assert_ne!(second["pid"], first["pid"]);
    assert_eq!(sandbox.tabs(), vec!["fresh"]);
}

#[test]
fn stop_ends_one_tab_and_list_forgets_it() {
    let sandbox = Sandbox::new("stop");
    sandbox.start("one", json!({}));
    sandbox.start("two", json!({}));
    assert_eq!(sandbox.tabs(), vec!["one", "two"]);
    assert_eq!(
        sandbox.shell("stop", json!({ "tab": "one" }))["stopped"],
        json!(true)
    );
    assert_eq!(sandbox.tabs(), vec!["two"]);
    assert_eq!(
        sandbox.shell("stop", json!({ "tab": "one" }))["stopped"],
        json!(false)
    );
}

#[test]
fn a_port_outside_the_hosts_range_is_refused() {
    let sandbox = Sandbox::new("ports");
    let answer = sandbox.raw(json!({
        "service": "shell/1", "op": "start", "owner": sandbox.owner,
        "args": { "tab": "p", "command": ["/bin/sh"], "ports": { "from": 2000, "to": 2010 } }
    }));
    assert_eq!(answer["error"]["kind"], json!("denied"), "{answer}");
}

#[test]
fn a_tab_that_could_climb_out_of_its_directory_is_refused() {
    let sandbox = Sandbox::new("tab");
    for tab in ["../x", "", "-a", "a/b"] {
        let answer = sandbox.raw(json!({
            "service": "shell/1", "op": "start", "owner": sandbox.owner,
            "args": { "tab": tab, "command": ["/bin/sh"] }
        }));
        assert_eq!(
            answer["error"]["kind"],
            json!("bad_request"),
            "{tab}: {answer}"
        );
    }
}

#[test]
fn teardown_stops_every_shell() {
    let sandbox = Sandbox::new("teardown");
    sandbox.start("a", json!({}));
    sandbox.start("b", json!({}));
    let answer =
        sandbox.raw(json!({ "service": "lifecycle", "op": "teardown", "owner": sandbox.owner }));
    assert_eq!(answer["result"]["shells_stopped"], json!(2), "{answer}");
    assert!(sandbox.tabs().is_empty());
}

#[test]
fn an_image_on_screen_is_redrawn_after_a_keyframe() {
    let sandbox = Sandbox::new("image");
    let started = sandbox.start("img", json!({}));
    let mut client = Client::connect(&started);
    client.type_in("printf '\\033_Ga=T,f=24,s=1,v=1,i=7;AAAA\\033\\\\'; echo drawn\n");
    client.until("the draw", |c| c.output().contains("drawn\r\n"));

    client.records.clear();
    client.keyframe = 1;
    client.until("the replay", |c| c.records.len() >= 2);
    assert!(
        matches!(client.records[0], Record::Snapshot(_)),
        "{:?}",
        client.records
    );
    let Record::Pty(replay) = &client.records[1] else {
        panic!("the images follow the snapshot: {:?}", client.records);
    };
    let replay = String::from_utf8_lossy(replay);
    assert!(replay.contains("\x1b_G"), "no kitty command in {replay:?}");
    assert!(replay.contains("i=7"), "the image keeps its id: {replay:?}");
}

#[test]
fn a_virtual_placement_is_redrawn_after_a_keyframe() {
    let sandbox = Sandbox::new("virtual");
    let started = sandbox.start("virt", json!({}));
    let mut client = Client::connect(&started);
    client.type_in("printf '\\033_Ga=T,f=24,s=1,v=1,i=9,U=1,c=1,r=1;AAAA\\033\\\\'; echo placed\n");
    client.until("the placement", |c| c.output().contains("placed\r\n"));

    client.records.clear();
    client.keyframe = 1;
    client.until("the replay", |c| c.records.len() >= 2);
    let Record::Pty(replay) = &client.records[1] else {
        panic!("the images follow the snapshot: {:?}", client.records);
    };
    let replay = String::from_utf8_lossy(replay);
    assert!(
        replay.contains("i=9") && replay.contains("U=1"),
        "{replay:?}"
    );
}

#[test]
fn a_file_transmission_reaches_the_phone_as_its_bytes() {
    let sandbox = Sandbox::new("medium");
    let file = sandbox.root.join("pixel.rgb");
    fs::write(&file, [1, 2, 3]).unwrap();
    let missing = sandbox.root.join("missing.rgb");
    let started = sandbox.start("medium", json!({}));
    let mut client = Client::connect(&started);
    client.type_in(&format!(
        "stty -icanon -echo min 0 time 20; \
         printf '\\033_Ga=q,i=30,t=f,f=24,s=1,v=1,S=3;{}\\033\\\\'; \
         printf '\\033_Ga=q,i=31,t=f,f=24,s=1,v=1;{}\\033\\\\'; \
         cat -v; stty sane; echo; echo medium-$((6*7))\n",
        base64_encode(file.to_str().unwrap().as_bytes()),
        base64_encode(missing.to_str().unwrap().as_bytes()),
    ));
    client.until("the answer read back", |c| c.output().contains("medium-42"));
    let output = client.output();
    assert!(
        output.contains("\x1b_Ga=q,i=30,t=d,f=24,s=1,v=1;AQID\x1b\\"),
        "{output:?}"
    );
    assert!(
        output.contains("^[_Gi=31;EBADF: No such file or directory"),
        "{output:?}"
    );
    assert!(!output.contains("\x1b_Ga=q,i=31"), "{output:?}");
}

#[test]
fn an_image_sent_by_file_is_redrawn_after_a_keyframe() {
    let sandbox = Sandbox::new("medium-replay");
    let file = sandbox.root.join("pixel.rgb");
    fs::write(&file, [10, 20, 30]).unwrap();
    let started = sandbox.start("img", json!({}));
    let mut client = Client::connect(&started);
    client.type_in(&format!(
        "printf '\\033_Ga=T,t=f,f=24,s=1,v=1,i=8,q=2;{}\\033\\\\'; echo drawn-$((1+1))\n",
        base64_encode(file.to_str().unwrap().as_bytes())
    ));
    client.until("the draw", |c| c.output().contains("drawn-2\r\n"));

    client.records.clear();
    client.keyframe = 1;
    client.until("the replay", |c| c.records.len() >= 2);
    let Record::Pty(replay) = &client.records[1] else {
        panic!("the images follow the snapshot: {:?}", client.records);
    };
    let replay = String::from_utf8_lossy(replay);
    let head = "\x1b_Ga=t,f=24,s=1,v=1,i=8,o=z,q=2,m=0;";
    let start = replay.find(head).expect(&replay) + head.len();
    let end = start + replay[start..].find("\x1b\\").unwrap();
    let pixels =
        miniz_oxide::inflate::decompress_to_vec_zlib(&base64_decode(&replay[start..end])).unwrap();
    assert_eq!(pixels, [10, 20, 30]);
}

fn shell_server(sandbox: &Sandbox) -> u32 {
    let root = sandbox.root.to_string_lossy().into_owned();
    fs::read_dir("/proc")
        .unwrap()
        .flatten()
        .filter_map(|entry| entry.file_name().to_str()?.parse().ok())
        .find(|pid: &u32| {
            fs::read(format!("/proc/{pid}/cmdline")).is_ok_and(|cmdline| {
                let cmdline = String::from_utf8_lossy(&cmdline);
                cmdline.contains("__shell") && cmdline.contains(&root)
            })
        })
        .expect("the shell server is running")
}

fn cpu_time(pid: u32) -> Duration {
    let schedstat = fs::read_to_string(format!("/proc/{pid}/schedstat")).unwrap();
    Duration::from_nanos(schedstat.split(' ').next().unwrap().parse().unwrap())
}

fn take_pty_bytes(client: &mut Client) -> (usize, bool) {
    let (bytes, _, exited) = take_records(client);
    (bytes, exited)
}

fn take_records(client: &mut Client) -> (usize, Vec<usize>, bool) {
    let mut bytes = 0;
    let mut snapshots = Vec::new();
    let mut exited = false;
    for record in client.records.drain(..) {
        match record {
            Record::Pty(body) => bytes += body.len(),
            Record::Snapshot(body) => {
                bytes += body.len();
                snapshots.push(body.len());
            }
            Record::Exit(_) => exited = true,
        }
    }
    (bytes, snapshots, exited)
}

fn drive(name: &str, script: &str) {
    let sandbox = Sandbox::new(name);
    let fixture = sandbox.root.join("fixture");
    let script = script.replace("$FIXTURE", fixture.to_str().unwrap());
    if script.contains(fixture.to_str().unwrap()) {
        fs::write(&fixture, tui_frames(1000)).unwrap();
    }
    let started = sandbox.start(
        name,
        json!({ "command": ["/bin/sh", "-c", format!("sleep 0.5; {script}")] }),
    );
    let mut client = Client::connect(&started);
    client
        .socket
        .set_read_timeout(Some(Duration::from_millis(1)))
        .unwrap();
    let server = shell_server(&sandbox);
    let cpu_before = cpu_time(server);
    let deadline = Instant::now() + Duration::from_secs(300);
    let produced = Command::new("/bin/sh")
        .args(["-c", &script])
        .output()
        .unwrap()
        .stdout
        .len();
    let mut first: Option<Instant> = None;
    let mut total = 0;
    let mut keyframes = Vec::new();
    loop {
        assert!(Instant::now() < deadline, "{name} never finished");
        client.send();
        client.receive();
        let (bytes, snapshots, exited) = take_records(&mut client);
        keyframes.extend(snapshots);
        if bytes > 0 && first.is_none() {
            first = Some(Instant::now());
        }
        total += bytes;
        if exited {
            break;
        }
    }
    let began = first.unwrap();
    let wall = began.elapsed();
    let cpu = cpu_time(server) - cpu_before;
    client.send();
    let mb = produced as f64 / 1e6;
    println!(
        "PERF {name:<10} {mb:>7.1} MB, {:>5.1} MB sent  wall {:>7.0} ms  {:>6.1} MB/s  server cpu {:>7.0} ms  {:>5.1} ms/MB  keyframes {} of {:.0} KB avg",
        total as f64 / 1e6,
        wall.as_secs_f64() * 1e3,
        mb / wall.as_secs_f64(),
        cpu.as_secs_f64() * 1e3,
        cpu.as_secs_f64() * 1e3 / mb,
        keyframes.len(),
        keyframes.iter().sum::<usize>() as f64 / keyframes.len().max(1) as f64 / 1e3,
    );
}

fn tui_frames(frames: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for frame in 0..frames {
        out.extend_from_slice(b"\x1b[H");
        for row in 0..24 {
            out.extend_from_slice(format!("\x1b[{};1H", row + 1).as_bytes());
            for col in 0..80 {
                let colour = (frame + row + col) % 256;
                let glyph = b'!' + ((frame * 7 + row * 3 + col) % 90) as u8;
                out.extend_from_slice(format!("\x1b[38;5;{colour}m").as_bytes());
                out.push(glyph);
            }
        }
    }
    out
}

#[test]
#[ignore = "a measurement, run with --ignored --nocapture"]
fn perf_lines() {
    drive("lines", "seq 1 3000000");
}

#[test]
#[ignore = "a measurement, run with --ignored --nocapture"]
fn perf_wrapped() {
    drive(
        "wrapped",
        "head -c 24000000 /dev/zero | tr '\\0' a | fold -w 200",
    );
}

#[test]
#[ignore = "a measurement, run with --ignored --nocapture"]
fn perf_tui() {
    drive("tui", "cat $FIXTURE");
}

#[test]
#[ignore = "a measurement, run with --ignored --nocapture"]
fn perf_keystroke_round_trip() {
    let sandbox = Sandbox::new("latency");
    let started = sandbox.start(
        "latency",
        json!({ "command": ["/bin/sh", "-c", "exec cat"] }),
    );
    let mut client = Client::connect(&started);
    client
        .socket
        .set_read_timeout(Some(Duration::from_millis(1)))
        .unwrap();
    client.until("first contact", |c| c.input_ack == c.input.len() as u64);
    let server = shell_server(&sandbox);
    let mut samples = Vec::new();
    let cpu_before = cpu_time(server);
    for _ in 0..300 {
        client.records.clear();
        client.type_in("x");
        let typed = Instant::now();
        client.send();
        loop {
            assert!(typed.elapsed() < PATIENCE, "the echo never came");
            client.receive();
            if take_pty_bytes(&mut client).0 > 0 {
                break;
            }
        }
        samples.push(typed.elapsed());
    }
    let cpu = cpu_time(server) - cpu_before;
    samples.sort();
    let at = |q: f64| samples[((samples.len() - 1) as f64 * q) as usize].as_secs_f64() * 1e6;
    println!(
        "PERF echo  p50 {:.0} us  p90 {:.0} us  p99 {:.0} us  server cpu {:.0} us/key",
        at(0.5),
        at(0.9),
        at(0.99),
        cpu.as_secs_f64() * 1e6 / samples.len() as f64,
    );

    let idle = cpu_time(server);
    let begin = Instant::now();
    while begin.elapsed() < Duration::from_secs(5) {
        client.send();
        std::thread::sleep(Duration::from_millis(100));
        client.receive();
    }
    println!(
        "PERF idle  server cpu {:.2} ms/s with a packet every 100 ms",
        (cpu_time(server) - idle).as_secs_f64() * 1e3 / begin.elapsed().as_secs_f64()
    );
}
