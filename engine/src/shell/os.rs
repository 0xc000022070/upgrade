use std::fs::File;
use std::io::{self, Read};
use std::os::fd::RawFd;
use std::time::Duration;

pub fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result == -1 {
        Err(io::Error::last_os_error())
    } else {
        Ok(result)
    }
}

pub fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(bytes)
}

pub fn set_nonblocking(fd: RawFd) -> io::Result<()> {
    let flags = check(unsafe { libc::fcntl(fd, libc::F_GETFL) })?;
    check(unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) }).map(drop)
}

pub fn set_cloexec(fd: RawFd, on: bool) -> io::Result<()> {
    let flags = check(unsafe { libc::fcntl(fd, libc::F_GETFD) })?;
    let flags = if on {
        flags | libc::FD_CLOEXEC
    } else {
        flags & !libc::FD_CLOEXEC
    };
    check(unsafe { libc::fcntl(fd, libc::F_SETFD, flags) }).map(drop)
}

pub fn try_lock(file: &File) -> io::Result<bool> {
    use std::os::fd::AsRawFd;
    match check(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }) {
        Ok(_) => Ok(true),
        Err(err) if err.raw_os_error() == Some(libc::EWOULDBLOCK) => Ok(false),
        Err(err) => Err(err),
    }
}

pub fn lock(file: &File) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    loop {
        match check(unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) }) {
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            other => return other.map(drop),
        }
    }
}

#[derive(Debug, Default)]
pub struct Ready {
    pub readable: Vec<RawFd>,
    pub writable: Vec<RawFd>,
}

impl Ready {
    pub fn can_read(&self, fd: RawFd) -> bool {
        self.readable.contains(&fd)
    }

    pub fn can_write(&self, fd: RawFd) -> bool {
        self.writable.contains(&fd)
    }
}

pub fn wait(read: &[RawFd], write: &[RawFd], timeout: Option<Duration>) -> io::Result<Ready> {
    let mut read_set: libc::fd_set = unsafe { std::mem::zeroed() };
    let mut write_set: libc::fd_set = unsafe { std::mem::zeroed() };
    let mut highest = -1;
    for &fd in read.iter().chain(write) {
        if fd < 0 || fd as usize >= libc::FD_SETSIZE {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "descriptor out of select's range",
            ));
        }
        highest = highest.max(fd);
    }
    unsafe {
        libc::FD_ZERO(&mut read_set);
        libc::FD_ZERO(&mut write_set);
        read.iter().for_each(|&fd| libc::FD_SET(fd, &mut read_set));
        write
            .iter()
            .for_each(|&fd| libc::FD_SET(fd, &mut write_set));
    }
    let mut tv = timeout.map(|timeout| libc::timeval {
        tv_sec: timeout.as_secs() as libc::time_t,
        tv_usec: timeout.subsec_micros() as libc::suseconds_t,
    });
    let tv_ptr = tv
        .as_mut()
        .map_or(std::ptr::null_mut(), |tv| tv as *mut libc::timeval);
    let result = unsafe {
        libc::select(
            highest + 1,
            &mut read_set,
            &mut write_set,
            std::ptr::null_mut(),
            tv_ptr,
        )
    };
    if result == -1 {
        let err = io::Error::last_os_error();
        return if err.kind() == io::ErrorKind::Interrupted {
            Ok(Ready::default())
        } else {
            Err(err)
        };
    }
    Ok(Ready {
        readable: read
            .iter()
            .copied()
            .filter(|&fd| unsafe { libc::FD_ISSET(fd, &read_set) })
            .collect(),
        writable: write
            .iter()
            .copied()
            .filter(|&fd| unsafe { libc::FD_ISSET(fd, &write_set) })
            .collect(),
    })
}
