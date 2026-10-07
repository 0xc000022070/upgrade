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
const AWAY: Duration = Duration::from_secs(30);
const FOREGROUND_IDLE: Duration = Duration::from_secs(2);
const FOREGROUND_ACTIVE: Duration = Duration::from_millis(250);

struct ForegroundSchedule {
    due: Instant,
    sampled: Option<Instant>,
}

impl ForegroundSchedule {
    fn new(now: Instant) -> Self {
        Self {
            due: now,
            sampled: None,
        }
    }

    fn activity(&mut self, now: Instant) {
        let next = self
            .sampled
            .map_or(now, |at| (at + FOREGROUND_ACTIVE).max(now));
        self.due = self.due.min(next);
    }

    fn sampled(&mut self, now: Instant) {
        self.sampled = Some(now);
        self.due = now + FOREGROUND_IDLE;
    }
}

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
    pty_buf: Box<[u8]>,
    forward: Vec<u8>,
    pending: VecDeque<u8>,
    key_file: PathBuf,
    timing: Timing,
    started: Instant,
    contacted: bool,
    rejoined: bool,
    ended_at: Option<Instant>,
    ending: Option<Ending>,
    foreground_schedule: ForegroundSchedule,
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
            pty_buf: vec![0; 64 * 1024].into_boxed_slice(),
            forward: Vec::new(),
            pending: VecDeque::new(),
            key_file,
            timing,
            started: now,
            contacted: false,
            rejoined: false,
            ended_at: None,
            ending: None,
            foreground_schedule: ForegroundSchedule::new(now),
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
            let stalled = self.files.claims.stalled(self.heard(now));
            self.pending.extend(stalled);
            self.reap(now);
            self.refresh_foreground_if_due(now);
            self.transmit(now);
            self.cut(now);
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
        let _ = self
            .mirror
            .relieve(self.link.ack(), self.link.is_recent(now));
        let header = Header {
            input_ack: self.input.ack(),
            size_gen: self.control.size_gen(),
        };
        for packet in self.link.transmit(now, self.mirror.stream(), header) {
            let _ = self.endpoint.send(&packet);
        }
    }

    fn heard(&self, now: Instant) -> Option<Instant> {
        (self.pending.len() < PENDING_INPUT).then_some(now)
    }

    fn cut(&mut self, now: Instant) {
        let (ack, heard) = (self.link.ack(), self.heard(now));
        for cut in self.mirror.take_cuts() {
            self.files.claims.cut(cut, ack, heard);
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
            (self.pty.is_some() && self.link.is_recent(now))
                .then_some(self.foreground_schedule.due),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    fn receive(&mut self, packet: &ClientPacket, now: Instant) {
        let first_contact = !self.contacted;
        self.contacted = true;
        let quiet = self.link.heard(packet, now);
        let directives = self.control.apply(packet);
        let rejoined = std::mem::take(&mut self.rejoined);
        self.replay_foreground_on_contact(now, first_contact, rejoined, quiet);
        if let Some(size) = directives.resize {
            let _ = self.mirror.resize(size);
            if let Some(pty) = &self.pty {
                let _ = pty.resize(size);
            }
        }
        let heard = self.heard(now);
        self.files.claims.acked(self.link.ack(), heard);
        if let Some((offset, bytes)) = &packet.input {
            if heard.is_some() {
                let fresh = self.input.accept(*offset, bytes);
                if self.pty.is_some() {
                    let mut answered = Vec::new();
                    self.files.claims.answer(fresh, &mut answered, now);
                    self.pending.extend(answered);
                }
            }
        }
        self.mirror.release(self.link.ack());
        let away = quiet.is_some_and(|quiet| quiet >= AWAY)
            && self.mirror.outweighs_keyframe(self.link.ack());
        // A phone that resized while away reflowed bytes the server had not, so what it
        // holds no longer matches what a replay continues.
        let _ = if directives.keyframe || away || (rejoined && directives.reshaped) {
            self.mirror.keyframe()
        } else {
            self.mirror.catch_up(self.link.ack())
        };
        self.cut(now);
        if directives.close {
            self.ending = Some(Ending::Closed);
        }
    }

    fn update_foreground(&mut self, now: Instant) {
        self.foreground_schedule.sampled(now);
        let processes = self
            .pty
            .as_ref()
            .map(Pty::foreground_processes)
            .unwrap_or_default();
        self.mirror.foreground(processes);
    }

    fn refresh_foreground_if_due(&mut self, now: Instant) {
        if now >= self.foreground_schedule.due && self.link.is_recent(now) {
            self.update_foreground(now);
        }
    }

    fn replay_foreground_on_contact(
        &mut self,
        now: Instant,
        first_contact: bool,
        rejoined: bool,
        quiet: Option<Duration>,
    ) {
        if first_contact || rejoined || quiet.is_some_and(|quiet| quiet >= AWAY) {
            self.update_foreground(now);
            self.mirror.replay_foreground();
        }
    }

    fn read_pty(&mut self, budget: usize) {
        let Some(pty) = self.pty.as_mut() else {
            return;
        };
        let mut taken = 0;
        let mut replies = Vec::new();
        while taken < budget {
            match pty.read(&mut self.pty_buf) {
                Ok(0) => {
                    self.pty_eof = true;
                    break;
                }
                Ok(n) => {
                    taken += n;
                    self.forward.clear();
                    self.media.feed(
                        &self.pty_buf[..n],
                        &mut self.files,
                        &mut self.forward,
                        &mut replies,
                    );
                    let sent = self.mirror.output(&self.forward);
                    self.files.claims.sent(sent, self.forward.len());
                }
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
        if self.forward.capacity() > self.pty_buf.len() * 2 {
            self.forward = Vec::new();
        }
        if taken > 0 {
            self.foreground_schedule.activity(Instant::now());
        }
        self.pending.extend(replies);
    }

    fn write_pty(&mut self) {
        let Some(pty) = self.pty.as_mut() else {
            return;
        };
        let before = self.pending.len();
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
        if self.pending.len() < before {
            self.foreground_schedule.activity(Instant::now());
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
        self.link.rekeyed(now);
        self.control.rekeyed();
        self.rejoined = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn idle_foreground_checks_wait_two_seconds_and_activity_brings_them_forward() {
        let now = Instant::now();
        let mut schedule = ForegroundSchedule::new(now);
        schedule.sampled(now);
        assert_eq!(schedule.due, now + Duration::from_secs(2));
        schedule.activity(now + Duration::from_millis(50));
        assert_eq!(schedule.due, now + Duration::from_millis(250));
        schedule.activity(now + Duration::from_millis(100));
        schedule.activity(now + Duration::from_millis(200));
        assert_eq!(schedule.due, now + Duration::from_millis(250));
        schedule.sampled(now + Duration::from_millis(250));
        schedule.activity(now + Duration::from_millis(260));
        assert_eq!(schedule.due, now + Duration::from_millis(500));
    }

    #[test]
    fn activity_after_a_quiet_period_is_checked_immediately() {
        let now = Instant::now();
        let mut schedule = ForegroundSchedule::new(now);
        schedule.sampled(now);
        schedule.activity(now + Duration::from_secs(1));
        assert_eq!(schedule.due, now + Duration::from_secs(1));
    }
}
