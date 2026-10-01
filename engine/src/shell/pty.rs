use super::os::{check, set_cloexec, set_nonblocking};
use super::wire::Size;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

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

    fn spawn(argv: &[&str]) -> Pty {
        Pty::spawn(&Spawn {
            argv: argv.iter().map(|arg| arg.to_string()).collect(),
            arg0: None,
            cwd: std::env::temp_dir(),
            env: vec![("DAZZLE_TEST".into(), "here".into())],
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
            "stty size; echo $DAZZLE_TEST; test -t 0 && echo tty",
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
