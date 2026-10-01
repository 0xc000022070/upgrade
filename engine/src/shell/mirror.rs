use super::stream::Stream;
use super::vt::{Options, Terminal, VtError};
use super::wire::{record, Size, RECORD_EXIT, RECORD_PTY, RECORD_SNAPSHOT};

const MIN_BACKLOG: u64 = 1 << 20;

pub struct Mirror {
    terminal: Terminal,
    stream: Stream,
    pending_images: bool,
    status: Option<i32>,
    keyframe_len: u64,
}

impl Mirror {
    pub fn new(size: Size, options: &Options) -> Result<Self, VtError> {
        Ok(Self {
            terminal: Terminal::new(size, options)?,
            stream: Stream::default(),
            pending_images: false,
            status: None,
            keyframe_len: 0,
        })
    }

    pub fn stream(&self) -> &Stream {
        &self.stream
    }

    pub fn output(&mut self, bytes: &[u8]) {
        if bytes.is_empty() {
            return;
        }
        self.terminal.write(bytes);
        self.stream.append(&record(RECORD_PTY, bytes));
        if self.pending_images && self.terminal.at_ground() {
            self.pending_images = false;
            self.append_images();
        }
    }

    pub fn exited(&mut self, status: i32) {
        self.status = Some(status);
        self.stream
            .append(&record(RECORD_EXIT, &status.to_be_bytes()));
    }

    pub fn resize(&mut self, size: Size) -> Result<(), VtError> {
        self.terminal.resize(size)
    }

    pub fn release(&mut self, ack: u64) {
        self.stream.release(ack);
    }

    pub fn keyframe(&mut self) -> Result<(), VtError> {
        let snapshot = match self.terminal.snapshot() {
            Ok(snapshot) => snapshot,
            Err(err) => {
                self.stream.go_stale();
                return Err(err);
            }
        };
        let keyframe = record(RECORD_SNAPSHOT, &snapshot);
        self.keyframe_len = keyframe.len() as u64;
        self.stream.append_keyframe(&keyframe);
        self.pending_images = !self.terminal.at_ground();
        if !self.pending_images {
            self.append_images();
        }
        if let Some(status) = self.status {
            self.stream
                .append(&record(RECORD_EXIT, &status.to_be_bytes()));
        }
        Ok(())
    }

    pub fn catch_up(&mut self, ack: u64) -> Result<(), VtError> {
        if ack <= self.stream.end() && !self.stream.serves(ack) {
            self.keyframe()?;
        }
        Ok(())
    }

    pub fn relieve(&mut self, ack: u64, live: bool) -> Result<(), VtError> {
        let limit = MIN_BACKLOG.max(2 * self.keyframe_len);
        if self.stream.is_stale() || self.stream.backlog(ack) <= limit {
            return Ok(());
        }
        if live {
            self.keyframe()
        } else {
            self.stream.go_stale();
            Ok(())
        }
    }

    fn append_images(&mut self) {
        let replay = self.terminal.image_replay();
        if !replay.is_empty() {
            self.stream.append(&record(RECORD_PTY, &replay));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::wire::RECORD_HEADER;

    const SIZE: Size = Size {
        cols: 20,
        rows: 5,
        width_px: 200,
        height_px: 100,
    };

    fn mirror() -> Mirror {
        Mirror::new(
            SIZE,
            &Options {
                scrollback_lines: 100,
                scrollback_bytes: 1 << 20,
                image_bytes: 1 << 20,
            },
        )
        .unwrap()
    }

    fn records(mirror: &Mirror) -> Vec<(u8, Vec<u8>)> {
        let stream = mirror.stream();
        let (bytes, _) = stream.read(stream.base(), usize::MAX).unwrap_or_default();
        let mut out = Vec::new();
        let mut rest = bytes.as_slice();
        while rest.len() >= RECORD_HEADER {
            let len = u32::from_be_bytes(rest[1..5].try_into().unwrap()) as usize;
            out.push((rest[0], rest[RECORD_HEADER..RECORD_HEADER + len].to_vec()));
            rest = &rest[RECORD_HEADER + len..];
        }
        out
    }

    fn kinds(mirror: &Mirror) -> Vec<u8> {
        records(mirror).into_iter().map(|(kind, _)| kind).collect()
    }

    const IMAGE: &[u8] = b"\x1b_Ga=T,f=32,s=1,v=1,i=4,q=2;/wAA/w==\x1b\\";

    #[test]
    fn output_is_kept_as_pty_records() {
        let mut mirror = mirror();
        mirror.output(b"hello");
        assert_eq!(records(&mirror), vec![(RECORD_PTY, b"hello".to_vec())]);
    }

    #[test]
    fn a_keyframe_carries_the_images_and_the_exit() {
        let mut mirror = mirror();
        mirror.output(IMAGE);
        mirror.exited(7);
        mirror.keyframe().unwrap();
        assert_eq!(
            kinds(&mirror),
            vec![RECORD_SNAPSHOT, RECORD_PTY, RECORD_EXIT]
        );
        let records = records(&mirror);
        assert!(records[1].1.starts_with(b"\x1b_Ga=t"));
        assert_eq!(records[2].1, 7i32.to_be_bytes());
    }

    #[test]
    fn images_wait_for_ground() {
        let mut mirror = mirror();
        mirror.output(IMAGE);
        mirror.output(b"\x1b]0;half a ti");
        mirror.keyframe().unwrap();
        assert_eq!(kinds(&mirror), vec![RECORD_SNAPSHOT]);
        mirror.output(b"tle\x07");
        assert_eq!(
            kinds(&mirror),
            vec![RECORD_SNAPSHOT, RECORD_PTY, RECORD_PTY]
        );
        assert!(records(&mirror)[2].1.starts_with(b"\x1b_Ga=t"));
    }

    #[test]
    fn a_phone_behind_the_log_gets_a_keyframe_and_one_ahead_does_not() {
        let mut mirror = mirror();
        mirror.output(b"abc");
        mirror.release(2);
        mirror.catch_up(1).unwrap();
        assert_eq!(kinds(&mirror)[0], RECORD_SNAPSHOT);
        let end = mirror.stream().end();
        mirror.catch_up(end + 10).unwrap();
        assert_eq!(mirror.stream().end(), end);
    }

    #[test]
    fn a_flood_is_cut_short_for_a_live_phone_and_dropped_for_an_absent_one() {
        let mut live = mirror();
        live.output(&vec![b'x'; 2 << 20]);
        live.relieve(0, true).unwrap();
        assert_eq!(kinds(&live), vec![RECORD_SNAPSHOT]);

        let mut absent = mirror();
        absent.output(&vec![b'x'; 2 << 20]);
        absent.relieve(0, false).unwrap();
        assert!(absent.stream().is_stale());
        absent.output(b"more");
        assert_eq!(absent.stream().backlog(0), 0);
        absent.catch_up(0).unwrap();
        assert_eq!(kinds(&absent), vec![RECORD_SNAPSHOT]);
    }
}
