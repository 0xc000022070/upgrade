use super::control::Control;
use super::endpoint::Endpoint;
use super::input::Input;
use super::kitty_medium::{HostFiles, Media};
use super::link::{Header, Link};
use super::mirror::Mirror;
use super::os::{wait, Ready};
use super::pty::Pty;
use super::signals::{Signal, Signals};
use super::wire::{ClientPacket, KEY_LEN};
use std::collections::VecDeque;
use std::io;
use std::path::PathBuf;
use std::time::{Duration, Instant};

const PENDING_INPUT: usize = 256 * 1024;
const READ_BUDGET: usize = 1 << 20;

pub struct Timing {
    pub linger: Duration,
    pub first_contact: Duration,
    pub grace: Duration,
}

impl Default for Timing {
    fn default() -> Self {
        Self {
            linger: Duration::from_secs(600),
            first_contact: Duration::from_secs(60),
            grace: Duration::from_secs(2),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ending {
    Closed,
    Stopped,
    Exited,
    Abandoned,
}

pub struct Server {
    endpoint: Endpoint,
    link: Link,
    control: Control,
    input: Input,
    mirror: Mirror,
    media: Media,
    files: HostFiles,
    pty: Option<Pty>,
    pty_eof: bool,
    pending: VecDeque<u8>,
    key_file: PathBuf,
    timing: Timing,
    started: Instant,
    contacted: bool,
    ended_at: Option<Instant>,
    ending: Option<Ending>,
}

impl Server {
    pub fn new(
        endpoint: Endpoint,
        mirror: Mirror,
        pty: Pty,
        key_file: PathBuf,
        timing: Timing,
    ) -> Self {
        let now = Instant::now();
        Self {
            endpoint,
            link: Link::new(now),
            control: Control::default(),
            input: Input::default(),
            mirror,
            media: Media::default(),
            files: HostFiles::default(),
            pty: Some(pty),
            pty_eof: false,
            pending: VecDeque::new(),
            key_file,
            timing,
            started: now,
            contacted: false,
            ended_at: None,
            ending: None,
        }
    }

    pub fn run(mut self, mut signals: Signals) -> io::Result<Ending> {
        loop {
            let now = Instant::now();
            if let Some(ending) = self.ending.or_else(|| self.settled(now)) {
                if let Some(pty) = self.pty.take() {
                    pty.hang_up(self.timing.grace);
                }
                return Ok(ending);
            }
            let ready = self.wait(&signals, now)?;
            let now = Instant::now();
            if ready.can_read(signals.fd()) {
                self.signalled(signals.drain(), now);
            }
            if ready.can_read(self.endpoint.fd()) {
                while let Some(packet) = self.endpoint.receive()? {
                    self.receive(&packet, now);
                }
            }
            self.serve_pty(&ready);
            self.files.claims.expire(now);
            self.reap(now);
            self.transmit(now);
        }
    }

    fn wait(&self, signals: &Signals, now: Instant) -> io::Result<Ready> {
        let mut read = vec![signals.fd(), self.endpoint.fd()];
        let mut write = Vec::new();
        if let Some(pty) = &self.pty {
            if !self.pty_eof {
                read.push(pty.fd());
            }
            if !self.pending.is_empty() {
                write.push(pty.fd());
            }
        }
        let timeout = self
            .deadline(now)
            .map(|at| at.saturating_duration_since(now));
        wait(&read, &write, timeout)
    }

    fn signalled(&mut self, signals: Vec<Signal>, now: Instant) {
        for signal in signals {
            match signal {
                Signal::Stop => self.ending = Some(Ending::Stopped),
                Signal::Rekey => self.rekey(now),
                Signal::Child => {}
            }
        }
    }

    fn serve_pty(&mut self, ready: &Ready) {
        let Some(fd) = self.pty.as_ref().map(Pty::fd) else {
            return;
        };
        if ready.can_read(fd) {
            self.read_pty(READ_BUDGET);
        }
        if ready.can_write(fd) {
            self.write_pty();
        }
    }

    fn transmit(&mut self, now: Instant) {
        let _ = self.mirror.relieve(self.link.ack(), self.link.is_live(now));
        let header = Header {
            input_ack: self.input.ack(),
            size_gen: self.control.size_gen(),
        };
        for packet in self.link.transmit(now, self.mirror.stream(), header) {
            let _ = self.endpoint.send(&packet);
        }
    }

    fn settled(&self, now: Instant) -> Option<Ending> {
        if !self.contacted && now.duration_since(self.started) >= self.timing.first_contact {
            return Some(Ending::Abandoned);
        }
        let ended_at = self.ended_at?;
        if self.link.ack() >= self.mirror.stream().end() {
            Some(Ending::Exited)
        } else if now.duration_since(ended_at) >= self.timing.linger {
            Some(Ending::Abandoned)
        } else {
            None
        }
    }

    fn deadline(&self, now: Instant) -> Option<Instant> {
        [
            self.link.deadline(now, self.mirror.stream()),
            (!self.contacted).then(|| self.started + self.timing.first_contact),
            self.ended_at.map(|at| at + self.timing.linger),
            self.files.claims.deadline(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn receive(&mut self, packet: &ClientPacket, now: Instant) {
        self.contacted = true;
        self.link.heard(packet, now);
        let directives = self.control.apply(packet);
        if let Some(size) = directives.resize {
            let _ = self.mirror.resize(size);
            if let Some(pty) = &self.pty {
                let _ = pty.resize(size);
            }
        }
        if let Some((offset, bytes)) = &packet.input {
            if self.pending.len() < PENDING_INPUT {
                let fresh = self.input.accept(*offset, bytes);
                if self.pty.is_some() {
                    let mut answered = Vec::new();
                    self.files.claims.answer(fresh, &mut answered);
                    self.pending.extend(answered);
                }
            }
        }
        self.mirror.release(self.link.ack());
        let _ = if directives.keyframe {
            self.mirror.keyframe()
        } else {
            self.mirror.catch_up(self.link.ack())
        };
        if directives.close {
            self.ending = Some(Ending::Closed);
        }
    }

    fn read_pty(&mut self, budget: usize) {
        let Some(pty) = self.pty.as_mut() else {
            return;
        };
        let mut buf = vec![0u8; 64 * 1024];
        let mut taken = 0;
        let (mut forward, mut replies) = (Vec::new(), Vec::new());
        while taken < budget {
            match pty.read(&mut buf) {
                Ok(0) => {
                    self.pty_eof = true;
                    break;
                }
                Ok(n) => {
                    taken += n;
                    forward.clear();
                    self.media
                        .feed(&buf[..n], &mut self.files, &mut forward, &mut replies);
                    self.mirror.output(&forward);
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        self.pending.extend(replies);
    }

    fn write_pty(&mut self) {
        let Some(pty) = self.pty.as_mut() else {
            return;
        };
        while !self.pending.is_empty() {
            let (front, _) = self.pending.as_slices();
            match pty.write(front) {
                Ok(n) => {
                    self.pending.drain(..n);
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => {
                    self.pending.clear();
                    break;
                }
            }
        }
    }

    fn reap(&mut self, now: Instant) {
        let Some(status) = self
            .pty
            .as_mut()
            .and_then(|pty| pty.try_wait().ok().flatten())
        else {
            return;
        };
        self.read_pty(usize::MAX);
        let mut rest = Vec::new();
        self.media.finish(&mut rest);
        self.mirror.output(&rest);
        self.pty = None;
        self.pending.clear();
        self.mirror.exited(status);
        self.ended_at = Some(now);
    }

    fn rekey(&mut self, now: Instant) {
        let Ok(key) = std::fs::read(&self.key_file) else {
            return;
        };
        let _ = std::fs::remove_file(&self.key_file);
        let Ok(key) = <[u8; KEY_LEN]>::try_from(key.as_slice()) else {
            return;
        };
        self.endpoint.rekey(&key);
        self.link = Link::new(now);
        self.control = Control::default();
    }
}
