use super::os::{check, set_cloexec, set_nonblocking};
use super::wire::Size;
use std::collections::BTreeMap;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

#[cfg(any(target_os = "linux", test))]
fn process_membership(stat: &str) -> Option<(u32, libc::pid_t)> {
    let (_, fields) = stat.rsplit_once(") ")?;
    let mut fields = fields.split_whitespace();
    let parent = fields.nth(1)?.parse().ok()?;
    let group = fields.next()?.parse().ok()?;
    Some((parent, group))
}

fn process_line(cmdline: &[u8], executable: &str) -> Option<Vec<u8>> {
    let mut args = cmdline.split(|byte| *byte == 0);
    let command = std::str::from_utf8(args.next()?).ok()?;
    let argument = std::str::from_utf8(args.next().unwrap_or_default()).ok()?;
    if command.is_empty()
        || [command, executable, argument]
            .iter()
            .any(|field| field.chars().any(char::is_control))
    {
        return None;
    }
    let name = executable.rsplit('/').next()?;
    if matches!(
        name,
        "tmux" | ".tmux-wrapped" | "herdr" | ".herdr-wrapped" | "screen"
    ) {
        return None;
    }
    Some(format!("{command}\t{executable}\t{argument}\n").into_bytes())
}

#[cfg(any(target_os = "linux", test))]
fn foreground_processes(proc: &std::path::Path, group: libc::pid_t) -> Option<Vec<u8>> {
    let mut members = BTreeMap::new();
    for entry in std::fs::read_dir(proc).ok()? {
        let Ok(entry) = entry else {
            continue;
        };
        let name = entry.file_name();
        let Some(name) = name.to_str() else {
            continue;
        };
        let Ok(pid) = name.parse::<u32>() else {
            continue;
        };
        let path = entry.path();
        let Ok(stat) = std::fs::read_to_string(path.join("stat")) else {
            continue;
        };
        let Some((parent, process_group)) = process_membership(&stat) else {
            continue;
        };
        if process_group == group {
            members.insert(pid, parent);
        }
    }
    let pid = foreground_root(&members)?;
    let path = proc.join(pid.to_string());
    let cmdline = std::fs::read(path.join("cmdline")).ok()?;
    let executable = std::fs::read_link(path.join("exe")).ok()?;
    process_line(&cmdline, executable.to_str()?)
}

fn foreground_root(members: &BTreeMap<u32, u32>) -> Option<u32> {
    let mut roots = members
        .iter()
        .filter(|(_, parent)| !members.contains_key(parent));
    let (&pid, _) = roots.next()?;
    if roots.next().is_some() {
        return None;
    }
    Some(pid)
}

#[cfg(target_os = "macos")]
fn foreground_processes_darwin(group: libc::pid_t) -> Option<Vec<u8>> {
    let listing = Command::new("/bin/ps")
        .args(["-ww", "-axo", "pid=,ppid=,pgid=,comm="])
        .output()
        .ok()?;
    if !listing.status.success() {
        return None;
    }
    let listing = String::from_utf8(listing.stdout).ok()?;
    let (pid, executable) = darwin_foreground_root(&listing, group)?;
    let output = Command::new("/bin/ps")
        .args(["-ww", "-p", &pid.to_string(), "-o", "command="])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let command = String::from_utf8(output.stdout).ok()?;
    let argv: Vec<_> = command.split_whitespace().take(2).collect();
    let mut cmdline = argv.first()?.as_bytes().to_vec();
    cmdline.push(0);
    cmdline.extend_from_slice(argv.get(1).copied().unwrap_or_default().as_bytes());
    process_line(&cmdline, &executable)
}

#[cfg(any(target_os = "macos", test))]
fn darwin_foreground_root(listing: &str, group: libc::pid_t) -> Option<(u32, String)> {
    let mut members = BTreeMap::new();
    let mut commands = BTreeMap::new();
    for line in listing.lines() {
        let mut fields = line.split_whitespace();
        let (Some(pid), Some(parent), Some(process_group), Some(command)) =
            (fields.next(), fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        if process_group.parse::<libc::pid_t>().ok() == Some(group) {
            let pid = pid.parse::<u32>().ok()?;
            members.insert(pid, parent.parse::<u32>().ok()?);
            commands.insert(pid, command.to_string());
        }
    }
    let pid = foreground_root(&members)?;
    Some((pid, commands.remove(&pid)?))
}

pub struct Spawn {
    pub argv: Vec<String>,
    pub arg0: Option<String>,
    pub cwd: PathBuf,
    pub env: Vec<(String, String)>,
    pub size: Size,
}

pub struct Pty {
    master: File,
    child: Child,
}

fn winsize(size: Size) -> libc::winsize {
    libc::winsize {
        ws_row: size.rows.max(1),
        ws_col: size.cols.max(1),
        ws_xpixel: size.width_px,
        ws_ypixel: size.height_px,
    }
}

impl Pty {
    pub fn spawn(spec: &Spawn) -> io::Result<Self> {
        let Some(program) = spec.argv.first() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "nothing to run",
            ));
        };
        let mut master: RawFd = -1;
        let mut slave: RawFd = -1;
        let mut size = winsize(spec.size);
        check(unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &raw mut size,
            )
        })?;
        let master = unsafe { OwnedFd::from_raw_fd(master) };
        let slave = unsafe { OwnedFd::from_raw_fd(slave) };
        set_cloexec(master.as_raw_fd(), true)?;
        set_cloexec(slave.as_raw_fd(), true)?;

        let mut command = Command::new(program);
        command
            .args(&spec.argv[1..])
            .current_dir(&spec.cwd)
            .envs(spec.env.iter().map(|(key, value)| (key, value)))
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        if let Some(arg0) = &spec.arg0 {
            command.arg0(arg0);
        }
        unsafe {
            command.pre_exec(|| {
                check(libc::setsid())?;
                check(libc::ioctl(0, libc::TIOCSCTTY as _, 0))?;
                Ok(())
            });
        }
        let child = command.spawn()?;
        set_nonblocking(master.as_raw_fd())?;
        Ok(Self {
            master: File::from(master),
            child,
        })
    }

    pub fn fd(&self) -> RawFd {
        self.master.as_raw_fd()
    }

    pub fn pid(&self) -> u32 {
        self.child.id()
    }

    pub fn foreground_processes(&self) -> Vec<u8> {
        let Ok(group) = nix::unistd::tcgetpgrp(&self.master) else {
            return Vec::new();
        };
        if group.as_raw() <= 0 {
            return Vec::new();
        }
        #[cfg(target_os = "linux")]
        let processes = foreground_processes(std::path::Path::new("/proc"), group.as_raw());
        #[cfg(target_os = "macos")]
        let processes = foreground_processes_darwin(group.as_raw());
        #[cfg(not(any(target_os = "linux", target_os = "macos")))]
        let processes: Option<Vec<u8>> = None;
        if nix::unistd::tcgetpgrp(&self.master).ok() != Some(group) {
            return Vec::new();
        }
        processes.unwrap_or_default()
    }

    pub fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self.master.read(buf) {
            Err(err) if err.raw_os_error() == Some(libc::EIO) => Ok(0),
            other => other,
        }
    }

    pub fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.master.write(bytes)
    }

    pub fn resize(&self, size: Size) -> io::Result<()> {
        let size = winsize(size);
        check(unsafe { libc::ioctl(self.fd(), libc::TIOCSWINSZ as _, &size) }).map(drop)
    }

    pub fn try_wait(&mut self) -> io::Result<Option<i32>> {
        Ok(self.child.try_wait()?.map(|status| {
            status
                .code()
                .or_else(|| status.signal().map(|signal| -signal))
                .unwrap_or(-1)
        }))
    }

    pub fn hang_up(mut self, grace: Duration) -> i32 {
        let group = -(self.child.id() as libc::pid_t);
        unsafe { libc::kill(group, libc::SIGHUP) };
        drop(self.master);
        let deadline = Instant::now() + grace;
        loop {
            if let Ok(Some(status)) = self.child.try_wait() {
                return status
                    .code()
                    .or_else(|| status.signal().map(|s| -s))
                    .unwrap_or(-1);
            }
            if Instant::now() >= deadline {
                unsafe { libc::kill(group, libc::SIGKILL) };
                let _ = self.child.kill();
                return self
                    .child
                    .wait()
                    .map(|status| {
                        status
                            .code()
                            .or_else(|| status.signal().map(|s| -s))
                            .unwrap_or(-1)
                    })
                    .unwrap_or(-1);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_stat_uses_the_group_after_the_last_command_parenthesis() {
        assert_eq!(
            process_membership("23 (a ) strange name) S 10 23 23 4 23"),
            Some((10, 23))
        );
        assert_eq!(process_membership("23 (bad) S"), None);
    }

    #[test]
    fn darwin_ps_selects_one_foreground_root() {
        let listing = "\
 11758 377 11758 /usr/bin/login\n\
 11759 11758 11759 /bin/sh\n\
 11776 11759 11776 codex\n\
 11777 11776 11776 node\n";
        assert_eq!(
            darwin_foreground_root(listing, 11776),
            Some((11776, "codex".to_string()))
        );
        assert_eq!(
            darwin_foreground_root(listing, 11759),
            Some((11759, "/bin/sh".to_string()))
        );
        assert_eq!(darwin_foreground_root(listing, 99999), None);
        assert_eq!(
            darwin_foreground_root(&format!("{listing} 11778 11759 11776 claude\n"), 11776),
            None
        );
    }

    #[test]
    fn foreground_fields_reject_multiplexers_and_record_delimiters() {
        assert_eq!(
            process_line(b"codex\0--yolo\0", "/usr/bin/codex"),
            Some(b"codex\t/usr/bin/codex\t--yolo\n".to_vec())
        );
        assert_eq!(
            process_line(b"claude\0", "/usr/bin/claude"),
            Some(b"claude\t/usr/bin/claude\t\n".to_vec())
        );
        assert!(process_line(b"tmux\0", "/usr/bin/tmux").is_none());
        assert!(process_line(b"herdr\0", "/usr/bin/herdr").is_none());
        assert!(process_line(b"codex\0a\nb\0", "/usr/bin/codex").is_none());
        assert!(process_line(b"codex\0", "/usr/bin/co\tdex").is_none());
    }

    #[test]
    fn foreground_selection_keeps_helpers_but_rejects_independent_roots() {
        let root = std::env::temp_dir().join(format!("upgrade-foreground-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let add = |pid: u32, parent: u32, group: u32, name: &str| {
            let path = root.join(pid.to_string());
            std::fs::create_dir_all(&path).unwrap();
            std::fs::write(
                path.join("stat"),
                format!("{pid} ({name}) S {parent} {group} 1 4 {group}"),
            )
            .unwrap();
            std::fs::write(path.join("cmdline"), format!("{name}\0")).unwrap();
            std::os::unix::fs::symlink(format!("/usr/bin/{name}"), path.join("exe")).unwrap();
        };
        add(10, 1, 10, "codex");
        add(20, 1, 20, "claude");
        add(11, 10, 10, "node");
        add(12, 11, 10, "helper");
        add(13, 10, 10, "another-helper");
        add(21, 20, 20, "node");
        add(30, 1, 30, "tmux");
        add(31, 30, 30, "codex");
        assert_eq!(
            foreground_processes(&root, 10),
            Some(b"codex\t/usr/bin/codex\t\n".to_vec())
        );
        assert_eq!(
            foreground_processes(&root, 20),
            Some(b"claude\t/usr/bin/claude\t\n".to_vec())
        );
        assert!(foreground_processes(&root, 30).is_none());
        add(14, 1, 10, "cat");
        assert!(foreground_processes(&root, 10).is_none());
        assert!(foreground_processes(&root, 40).is_none());
        std::fs::remove_dir_all(root).unwrap();
    }

    fn spawn(argv: &[&str]) -> Pty {
        Pty::spawn(&Spawn {
            argv: argv.iter().map(|arg| arg.to_string()).collect(),
            arg0: None,
            cwd: std::env::temp_dir(),
            env: vec![("UPGRADE_TEST".into(), "here".into())],
            size: Size {
                cols: 33,
                rows: 11,
                width_px: 0,
                height_px: 0,
            },
        })
        .unwrap()
    }

    fn read_all(pty: &mut Pty) -> String {
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            match pty.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => out.extend_from_slice(&buf[..n]),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(err) => panic!("{err}"),
            }
        }
        String::from_utf8_lossy(&out).into_owned()
    }

    #[test]
    fn the_child_owns_a_terminal_of_the_size_asked() {
        let mut pty = spawn(&[
            "/bin/sh",
            "-c",
            "stty size; echo $UPGRADE_TEST; test -t 0 && echo tty",
        ]);
        let out = read_all(&mut pty);
        assert!(out.contains("11 33"), "{out:?}");
        assert!(out.contains("here"), "{out:?}");
        assert!(out.contains("tty"), "{out:?}");
    }

    #[test]
    fn the_status_is_the_code_or_minus_the_signal() {
        let mut pty = spawn(&["/bin/sh", "-c", "exit 3"]);
        read_all(&mut pty);
        let deadline = Instant::now() + Duration::from_secs(5);
        let status = loop {
            if let Some(status) = pty.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(status, 3);
        let pty = spawn(&["/bin/sh", "-c", "trap '' HUP; sleep 30"]);
        std::thread::sleep(Duration::from_millis(100));
        assert_eq!(pty.hang_up(Duration::from_millis(200)), -libc::SIGKILL);
    }
}
