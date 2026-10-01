use super::kitty::Transmissions;
use super::stream::Stream;
use super::vt::{Options, Terminal, VtError};
use super::wire::{record, Size, RECORD_EXIT, RECORD_HEADER, RECORD_PTY, RECORD_SNAPSHOT};

const MIN_BACKLOG: u64 = 1 << 20;

pub struct Mirror {
    terminal: Terminal,
    stream: Stream,
    transmissions: Transmissions,
    keyframe_due: bool,
    pending_images: bool,
    status: Option<i32>,
    keyframe_len: u64,
}

impl Mirror {
    pub fn new(size: Size, options: &Options) -> Result<Self, VtError> {
        Ok(Self {
            terminal: Terminal::new(size, options)?,
            stream: Stream::default(),
            transmissions: Transmissions::new(options.image_bytes / 3 * 4 + (1 << 16)),
            keyframe_due: false,
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
        self.transmissions.feed(bytes);
        if self.keyframe_due && !self.transmissions.open() {
            let _ = self.keyframe();
        }
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
        self.keyframe_due = self.transmissions.open();
        if self.keyframe_due {
            return Ok(());
        }
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
        let terminal = &self.terminal;
        self.transmissions.retain(|id| terminal.holds_image(id));
        let replay = record(RECORD_PTY, &terminal.image_replay(self.transmissions.ids()));
        if replay.len() > RECORD_HEADER {
            self.keyframe_len += replay.len() as u64;
            self.stream.append(&replay);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SIZE: Size = Size {
        cols: 20,
        rows: 5,
        width_px: 200,
        height_px: 100,
    };

    fn mirror() -> Mirror {
        mirror_holding(1 << 20)
    }

    fn mirror_holding(image_bytes: u64) -> Mirror {
        Mirror::new(
            SIZE,
            &Options {
                scrollback_lines: 100,
                scrollback_bytes: 1 << 20,
                image_bytes,
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

    fn large_image() -> Vec<Vec<u8>> {
        let mut seed = 1u32;
        let pixels: Vec<u8> = (0..480 * 600 * 4)
            .map(|_| {
                seed = seed.wrapping_mul(1_103_515_245).wrapping_add(12_345);
                (seed >> 16) as u8
            })
            .collect();
        let encoded = crate::util::base64_encode(&pixels);
        let chunks: Vec<&[u8]> = encoded.as_bytes().chunks(4096).collect();
        let last = chunks.len() - 1;
        let mut commands: Vec<Vec<u8>> = chunks
            .iter()
            .enumerate()
            .map(|(index, chunk)| {
                let more = u8::from(index != last);
                let keys = if index == 0 {
                    format!("a=t,f=32,s=480,v=600,i=9,q=2,m={more}")
                } else {
                    format!("m={more}")
                };
                [format!("\x1b_G{keys};").as_bytes(), chunk, b"\x1b\\"].concat()
            })
            .collect();
        commands.push(b"\x1b_Ga=p,i=9,c=4,r=2,C=1,q=2\x1b\\".to_vec());
        commands
    }

    #[test]
    fn a_keyframe_waits_for_the_last_chunk_and_then_carries_the_image() {
        let mut mirror = mirror_holding(16 << 20);
        let commands = large_image();
        let (head, tail) = commands.split_at(commands.len() / 2);
        for command in head {
            mirror.output(command);
        }
        mirror.keyframe().unwrap();
        assert!(!kinds(&mirror).contains(&RECORD_SNAPSHOT));
        for command in tail {
            mirror.output(command);
        }
        assert_eq!(
            kinds(&mirror),
            vec![RECORD_SNAPSHOT, RECORD_PTY, RECORD_PTY]
        );
        let records = records(&mirror);
        assert!(records[1].1.starts_with(b"\x1b_Ga=t"));
        assert_eq!(records[2].1, commands[commands.len() - 1]);
    }

    #[test]
    fn a_keyframe_carrying_a_large_image_is_not_cut_short_again() {
        let mut mirror = mirror_holding(16 << 20);
        for command in large_image() {
            mirror.output(&command);
        }
        mirror.relieve(0, true).unwrap();
        let base = mirror.stream().base();
        assert!(mirror.stream().backlog(0) > MIN_BACKLOG);
        mirror.relieve(0, true).unwrap();
        assert_eq!(mirror.stream().base(), base);
    }
}
