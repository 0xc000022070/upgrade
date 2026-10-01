use std::collections::VecDeque;

#[derive(Debug, Default)]
pub struct Stream {
    base: u64,
    bytes: VecDeque<u8>,
    keyframe: Option<u64>,
    stale: bool,
}

impl Stream {
    pub fn end(&self) -> u64 {
        self.base + self.bytes.len() as u64
    }

    pub fn base(&self) -> u64 {
        self.base
    }

    pub fn backlog(&self, from: u64) -> u64 {
        self.end().saturating_sub(from.max(self.base))
    }

    pub fn is_stale(&self) -> bool {
        self.stale
    }

    pub fn append(&mut self, bytes: &[u8]) {
        if !self.stale {
            self.bytes.extend(bytes);
        }
    }

    pub fn append_keyframe(&mut self, bytes: &[u8]) {
        self.base = self.end();
        self.bytes.clear();
        self.bytes.extend(bytes);
        self.keyframe = Some(self.base);
        self.stale = false;
    }

    pub fn go_stale(&mut self) {
        self.base = self.end();
        self.bytes.clear();
        self.keyframe = None;
        self.stale = true;
    }

    pub fn release(&mut self, ack: u64) {
        let ack = ack.min(self.end());
        if ack > self.base {
            self.bytes.drain(..(ack - self.base) as usize);
            self.base = ack;
        }
    }

    pub fn serves(&self, ack: u64) -> bool {
        if self.stale || ack > self.end() {
            return false;
        }
        ack >= self.base || self.keyframe == Some(self.base)
    }

    pub fn read(&self, offset: u64, max: usize) -> Option<(Vec<u8>, bool)> {
        if offset < self.base || offset >= self.end() {
            return None;
        }
        let start = (offset - self.base) as usize;
        let len = max.min(self.bytes.len() - start);
        let bytes = self.bytes.range(start..start + len).copied().collect();
        Some((bytes, self.keyframe == Some(offset)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_are_addressed_by_absolute_offset() {
        let mut stream = Stream::default();
        stream.append(b"hello");
        stream.release(2);
        assert_eq!(stream.base(), 2);
        assert_eq!(stream.read(2, 2), Some((b"ll".to_vec(), false)));
        assert_eq!(stream.read(1, 2), None);
        assert_eq!(stream.read(5, 2), None);
    }

    #[test]
    fn a_keyframe_drops_what_came_before_and_marks_its_start() {
        let mut stream = Stream::default();
        stream.append(b"old");
        stream.append_keyframe(b"KF");
        assert_eq!(stream.base(), 3);
        assert_eq!(stream.read(3, 10), Some((b"KF".to_vec(), true)));
        assert!(stream.serves(0), "a phone behind a keyframe jumps to it");
        stream.release(4);
        assert!(
            !stream.serves(0),
            "once trimmed past it, the keyframe is gone"
        );
        assert!(stream.serves(4));
    }

    #[test]
    fn a_stale_stream_keeps_nothing_and_serves_nobody() {
        let mut stream = Stream::default();
        stream.append(b"abc");
        stream.go_stale();
        stream.append(b"lost");
        assert_eq!(stream.end(), 3);
        assert!(!stream.serves(3));
        stream.append_keyframe(b"K");
        assert!(stream.serves(0));
        assert!(!stream.is_stale());
    }

    #[test]
    fn an_ack_from_the_future_is_not_served() {
        let mut stream = Stream::default();
        stream.append(b"ab");
        assert!(!stream.serves(9));
        stream.release(9);
        assert_eq!(stream.base(), 2);
    }

    #[test]
    fn backlog_counts_from_the_later_of_ack_and_base() {
        let mut stream = Stream::default();
        stream.append(&[0; 10]);
        assert_eq!(stream.backlog(4), 6);
        stream.release(8);
        assert_eq!(stream.backlog(4), 2);
    }
}
