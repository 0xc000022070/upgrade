use super::os::{check, set_cloexec, set_nonblocking};
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::sync::atomic::{AtomicI32, Ordering};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Stop,
    Rekey,
    Child,
}

static WRITE_END: AtomicI32 = AtomicI32::new(-1);

extern "C" fn forward(signal: libc::c_int) {
    let byte = signal as u8;
    let fd = WRITE_END.load(Ordering::Relaxed);
    if fd >= 0 {
        let saved = unsafe { *errno() };
        unsafe { libc::write(fd, &byte as *const u8 as *const libc::c_void, 1) };
        unsafe { *errno() = saved };
    }
}

#[cfg(target_os = "linux")]
unsafe fn errno() -> *mut libc::c_int {
    libc::__errno_location()
}

#[cfg(target_os = "macos")]
unsafe fn errno() -> *mut libc::c_int {
    libc::__error()
}

pub struct Signals {
    read_end: File,
}

impl Signals {
    pub fn install() -> io::Result<Self> {
        let mut fds = [0 as RawFd; 2];
        check(unsafe { libc::pipe(fds.as_mut_ptr()) })?;
        for fd in fds {
            set_cloexec(fd, true)?;
            set_nonblocking(fd)?;
        }
        WRITE_END.store(fds[1], Ordering::Relaxed);
        for signal in [
            libc::SIGTERM,
            libc::SIGINT,
            libc::SIGHUP,
            libc::SIGUSR1,
            libc::SIGCHLD,
        ] {
            let mut action: libc::sigaction = unsafe { std::mem::zeroed() };
            action.sa_sigaction = forward as *const () as usize;
            action.sa_flags = libc::SA_RESTART;
            unsafe { libc::sigemptyset(&mut action.sa_mask) };
            check(unsafe { libc::sigaction(signal, &action, std::ptr::null_mut()) })?;
        }
        Ok(Self {
            read_end: unsafe { File::from_raw_fd(fds[0]) },
        })
    }

    pub fn fd(&self) -> RawFd {
        self.read_end.as_raw_fd()
    }

    pub fn drain(&mut self) -> Vec<Signal> {
        let mut buf = [0u8; 64];
        let mut out = Vec::new();
        while let Ok(n) = self.read_end.read(&mut buf) {
            if n == 0 {
                break;
            }
            out.extend(
                buf[..n]
                    .iter()
                    .filter_map(|&byte| match byte as libc::c_int {
                        libc::SIGTERM | libc::SIGINT | libc::SIGHUP => Some(Signal::Stop),
                        libc::SIGUSR1 => Some(Signal::Rekey),
                        libc::SIGCHLD => Some(Signal::Child),
                        _ => None,
                    }),
            );
        }
        out
    }
}
