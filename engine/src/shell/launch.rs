use super::endpoint::Endpoint;
use super::mirror::Mirror;
use super::os::{check, random_bytes, set_cloexec, wait};
use super::pty::{Pty, Spawn};
use super::registry::{self, Record};
use super::server::{Server, Timing};
use super::signals::Signals;
use super::vt::Options;
use super::wire::{Size, KEY_LEN};
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::UdpSocket;
use std::ops::RangeInclusive;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const SOCKET_FD: RawFd = 3;
const READY_FD: RawFd = 4;
const READY_WAIT: Duration = Duration::from_secs(10);
const REKEY_WAIT: Duration = Duration::from_secs(3);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Spec {
    pub cols: u16,
    pub rows: u16,
    pub width_px: u16,
    pub height_px: u16,
    pub argv: Vec<String>,
    pub arg0: Option<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub scrollback_lines: usize,
    pub scrollback_bytes: usize,
    pub image_bytes: u64,
}

impl Spec {
    fn size(&self) -> Size {
        Size {
            cols: self.cols,
            rows: self.rows,
            width_px: self.width_px,
            height_px: self.height_px,
        }
    }
}

pub struct Started {
    pub port: u16,
    pub key: [u8; KEY_LEN],
    pub pid: i32,
}

#[derive(Serialize, Deserialize)]
struct Readiness {
    ok: bool,
    #[serde(default)]
    error: Option<String>,
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)
}

fn bind(ports: RangeInclusive<u16>) -> io::Result<UdpSocket> {
    let (from, to) = (*ports.start(), *ports.end());
    let span = u32::from(to - from) + 1;
    let offset = u32::from_be_bytes(random_bytes()?) % span;
    let mut v4_only = false;
    for step in 0..span {
        let port = from + ((offset + step) % span) as u16;
        if !v4_only {
            match UdpSocket::bind(("::", port)) {
                Ok(socket) => return Ok(socket),
                Err(err) if err.kind() == io::ErrorKind::AddrInUse => continue,
                Err(_) => v4_only = true,
            }
        }
        match UdpSocket::bind(("0.0.0.0", port)) {
            Ok(socket) => return Ok(socket),
            Err(err) if err.kind() == io::ErrorKind::AddrInUse => continue,
            Err(err) => return Err(err),
        }
    }
    Err(io::Error::new(
        io::ErrorKind::AddrInUse,
        format!("every UDP port in {from}-{to} is taken"),
    ))
}

fn lift(fd: RawFd) -> io::Result<OwnedFd> {
    let lifted = check(unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 10) })?;
    Ok(unsafe { OwnedFd::from_raw_fd(lifted) })
}

fn pipe() -> io::Result<(File, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    check(unsafe { libc::pipe(fds.as_mut_ptr()) })?;
    for fd in fds {
        set_cloexec(fd, true)?;
    }
    Ok(unsafe { (File::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) })
}

pub fn launch(dir: &Path, spec: &Spec, ports: RangeInclusive<u16>) -> io::Result<Started> {
    fs::write(dir.join("spec.json"), serde_json::to_vec(spec)?)?;
    let key: [u8; KEY_LEN] = random_bytes()?;
    write_private(&dir.join("key"), &key)?;
    let socket = bind(ports)?;
    let port = socket.local_addr()?.port();
    let (mut ready_read, ready_write) = pipe()?;
    let socket_fd = lift(socket.as_raw_fd())?;
    let ready_fd = lift(ready_write.as_raw_fd())?;
    drop(ready_write);
    drop(socket);

    let child = spawn_server(dir, socket_fd.as_raw_fd(), ready_fd.as_raw_fd())?;
    drop(socket_fd);
    drop(ready_fd);

    match read_readiness(&mut ready_read) {
        Ok(Readiness { ok: true, .. }) => Ok(Started {
            port,
            key,
            pid: child.id() as i32,
        }),
        Ok(Readiness { error, .. }) => Err(io::Error::other(
            error.unwrap_or_else(|| "the server did not start".into()),
        )),
        Err(err) => {
            unsafe { libc::kill(child.id() as libc::pid_t, libc::SIGKILL) };
            Err(err)
        }
    }
}

fn spawn_server(dir: &Path, raw_socket: RawFd, raw_ready: RawFd) -> io::Result<Child> {
    let executable = std::env::current_exe()?;
    let log = OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(dir.join("log"))?;
    let mut command = Command::new(executable);
    command
        .arg("__shell")
        .arg(dir)
        .current_dir("/")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(log));
    unsafe {
        command.pre_exec(move || {
            check(libc::setsid())?;
            check(libc::dup2(raw_socket, SOCKET_FD))?;
            check(libc::dup2(raw_ready, READY_FD))?;
            Ok(())
        });
    }
    command.spawn()
}

fn read_readiness(pipe: &mut File) -> io::Result<Readiness> {
    let deadline = Instant::now() + READY_WAIT;
    let mut raw = Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "the server did not say it was ready",
            ));
        }
        if !wait(&[pipe.as_raw_fd()], &[], Some(deadline - now))?.can_read(pipe.as_raw_fd()) {
            continue;
        }
        match pipe.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => raw.extend_from_slice(&buf[..n]),
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            Err(err) => return Err(err),
        }
    }
    serde_json::from_slice(&raw)
        .map_err(|_| io::Error::other("the server ended before it was ready"))
}

pub fn rekey(dir: &Path, record: &Record) -> io::Result<Option<[u8; KEY_LEN]>> {
    let key: [u8; KEY_LEN] = random_bytes()?;
    let path = dir.join("key");
    let tmp = dir.join("key.tmp");
    write_private(&tmp, &key)?;
    fs::rename(&tmp, &path)?;
    unsafe { libc::kill(record.pid, libc::SIGUSR1) };
    let deadline = Instant::now() + REKEY_WAIT;
    while path.exists() {
        if Instant::now() >= deadline || !registry::is_live(dir) {
            let _ = fs::remove_file(&path);
            return Ok(None);
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(registry::is_live(dir).then_some(key))
}

pub fn serve(dir: &Path) -> i32 {
    let _ = set_cloexec(SOCKET_FD, true);
    let _ = set_cloexec(READY_FD, true);
    let mut ready = unsafe { File::from_raw_fd(READY_FD) };
    let socket = unsafe { UdpSocket::from_raw_fd(SOCKET_FD) };
    let (server, signals, held) = match prepare(dir, socket) {
        Ok(prepared) => prepared,
        Err(err) => {
            let answer = Readiness {
                ok: false,
                error: Some(err.to_string()),
            };
            let _ = ready.write_all(&serde_json::to_vec(&answer).unwrap_or_default());
            return 1;
        }
    };
    let _ = ready.write_all(
        &serde_json::to_vec(&Readiness {
            ok: true,
            error: None,
        })
        .unwrap_or_default(),
    );
    drop(ready);
    let ending = server.run(signals);
    eprintln!("shell server ended: {ending:?}");
    let _ = fs::remove_dir_all(dir);
    drop(held);
    0
}

fn prepare(dir: &Path, socket: UdpSocket) -> io::Result<(Server, Signals, File)> {
    let Some(held) = registry::server_lock(dir)? else {
        return Err(io::Error::other("another server holds this tab"));
    };
    let spec: Spec = serde_json::from_slice(&fs::read(dir.join("spec.json"))?)?;
    let key_path = dir.join("key");
    let key = fs::read(&key_path)?;
    fs::remove_file(&key_path)?;
    let key = <[u8; KEY_LEN]>::try_from(key.as_slice())
        .map_err(|_| io::Error::other("the key file is not a key"))?;

    let signals = Signals::install()?;
    let options = Options {
        scrollback_lines: spec.scrollback_lines,
        scrollback_bytes: spec.scrollback_bytes,
        image_bytes: spec.image_bytes,
    };
    let mirror =
        Mirror::new(spec.size(), &options).map_err(|err| io::Error::other(err.to_string()))?;
    let pty = Pty::spawn(&Spawn {
        argv: spec.argv.clone(),
        arg0: spec.arg0.clone(),
        cwd: spec.cwd.clone(),
        env: spec.env.clone(),
        size: spec.size(),
    })?;
    let endpoint = Endpoint::new(socket, &key)?;
    registry::write_record(dir, &Record::new(endpoint.port()?, pty.pid()))?;
    Ok((
        Server::new(endpoint, mirror, pty, key_path, Timing::default()),
        signals,
        held,
    ))
}
