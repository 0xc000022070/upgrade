use super::rtt::{Clock, Rtt};
use super::stream::Stream;
use super::window::Window;
use super::wire::{ClientPacket, ServerPacket, NO_TIMESTAMP, SERVER_MAX_DATA};
use std::time::{Duration, Instant};

pub const HEARTBEAT: Duration = Duration::from_secs(3);
pub const SILENCE: Duration = Duration::from_secs(60);
pub const ACK_DELAY: Duration = Duration::from_millis(20);

#[derive(Debug, Clone, Copy)]
pub struct Header {
    pub input_ack: u64,
    pub size_gen: u32,
}

pub struct Link {
    clock: Clock,
    rtt: Rtt,
    window: Window,
    ack: u64,
    cursor: u64,
    last_send: Option<Instant>,
    last_heard: Option<Instant>,
    retransmit_at: Option<Instant>,
    owed_since: Option<Instant>,
}

impl Link {
    pub fn new(now: Instant) -> Self {
        Self {
            clock: Clock::new(now),
            rtt: Rtt::default(),
            window: Window::default(),
            ack: 0,
            cursor: 0,
            last_send: None,
            last_heard: None,
            retransmit_at: None,
            owed_since: None,
        }
    }

    pub fn ack(&self) -> u64 {
        self.ack
    }

    pub fn is_live(&self, now: Instant) -> bool {
        self.last_heard
            .is_some_and(|at| now.duration_since(at) < SILENCE)
    }

    pub fn heard(&mut self, packet: &ClientPacket, now: Instant) {
        self.rtt.observe(
            self.clock.stamp(now),
            packet.timestamp,
            packet.timestamp_reply,
            now,
        );
        self.last_heard = Some(now);
        if packet.ack > self.ack {
            self.window.acknowledged(packet.ack - self.ack);
            self.ack = packet.ack;
            self.cursor = self.cursor.max(self.ack);
            self.retransmit_at = (self.cursor > self.ack).then(|| now + self.rtt.rto());
        }
        if packet.input.is_some() || packet.timestamp != NO_TIMESTAMP {
            self.owed_since.get_or_insert(now);
        }
    }

    pub fn transmit(&mut self, now: Instant, stream: &Stream, header: Header) -> Vec<ServerPacket> {
        if !self.is_live(now) {
            return Vec::new();
        }
        let floor = self.ack.max(stream.base());
        if self.retransmit_at.is_some_and(|at| now >= at) && self.cursor > floor {
            self.cursor = floor;
            self.window.timed_out();
            self.retransmit_at = None;
        }
        self.cursor = self.cursor.max(stream.base());

        let mut packets = Vec::new();
        while self.cursor < stream.end() && self.window.admits(self.cursor - floor) {
            let Some((bytes, jump)) = stream.read(self.cursor, SERVER_MAX_DATA) else {
                break;
            };
            let offset = self.cursor;
            self.cursor += bytes.len() as u64;
            packets.push(self.packet(now, stream, header, jump, Some((offset, bytes))));
        }
        if !packets.is_empty() {
            self.retransmit_at.get_or_insert(now + self.rtt.rto());
        } else if self
            .owed_since
            .is_some_and(|at| now.duration_since(at) >= ACK_DELAY)
            || self
                .last_send
                .is_none_or(|at| now.duration_since(at) >= HEARTBEAT)
        {
            packets.push(self.packet(now, stream, header, false, None));
        }
        if !packets.is_empty() {
            self.last_send = Some(now);
            self.owed_since = None;
        }
        packets
    }

    fn packet(
        &mut self,
        now: Instant,
        stream: &Stream,
        header: Header,
        jump: bool,
        data: Option<(u64, Vec<u8>)>,
    ) -> ServerPacket {
        ServerPacket {
            jump,
            timestamp: self.clock.stamp(now),
            timestamp_reply: self.rtt.take_reply(now),
            input_ack: header.input_ack,
            size_gen: header.size_gen,
            stream_end: stream.end(),
            data,
        }
    }

    pub fn deadline(&self, now: Instant, stream: &Stream) -> Option<Instant> {
        if !self.is_live(now) {
            return None;
        }
        let floor = self.ack.max(stream.base());
        let cursor = self.cursor.max(stream.base());
        if cursor < stream.end() && self.window.admits(cursor - floor) {
            return Some(now);
        }
        [
            self.retransmit_at.filter(|_| self.cursor > floor),
            self.owed_since.map(|at| at + ACK_DELAY),
            self.last_send.map(|at| at + HEARTBEAT),
            self.last_heard.map(|at| at + SILENCE),
        ]
        .into_iter()
        .flatten()
        .min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::testing::client_packet;

    const HEADER: Header = Header {
        input_ack: 0,
        size_gen: 0,
    };

    fn offsets(packets: &[ServerPacket]) -> Vec<u64> {
        packets
            .iter()
            .filter_map(|p| p.data.as_ref().map(|d| d.0))
            .collect()
    }

    #[test]
    fn nothing_goes_to_a_phone_never_heard() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(b"hi");
        assert!(link.transmit(now, &stream, HEADER).is_empty());
        assert_eq!(link.deadline(now, &stream), None);
    }

    #[test]
    fn data_goes_out_once_then_again_after_the_timeout() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(&[1; SERVER_MAX_DATA + 10]);
        link.heard(&client_packet(0), now);
        assert_eq!(
            offsets(&link.transmit(now, &stream, HEADER)),
            vec![0, SERVER_MAX_DATA as u64]
        );
        assert!(link.transmit(now, &stream, HEADER).is_empty());
        let later = now + Duration::from_secs(2);
        link.heard(&client_packet(0), later);
        assert_eq!(
            offsets(&link.transmit(later, &stream, HEADER)),
            vec![0, SERVER_MAX_DATA as u64]
        );
    }

    #[test]
    fn an_ack_moves_the_window_and_stops_the_resend() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(b"abcdef");
        link.heard(&client_packet(0), now);
        link.transmit(now, &stream, HEADER);
        link.heard(&client_packet(6), now);
        stream.release(6);
        assert_eq!(link.deadline(now, &stream), Some(now + HEARTBEAT));
    }

    #[test]
    fn the_window_bounds_what_is_in_flight() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(&vec![0; 10 * 1024 * 1024]);
        link.heard(&client_packet(0), now);
        let sent: usize = link
            .transmit(now, &stream, HEADER)
            .iter()
            .map(|p| p.data.as_ref().unwrap().1.len())
            .sum();
        assert!(sent as u64 <= crate::shell::window::INITIAL + SERVER_MAX_DATA as u64);
        assert!(sent as u64 >= crate::shell::window::INITIAL);
    }

    #[test]
    fn a_keyframe_is_sent_as_a_jump_to_a_phone_behind_it() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(b"lost");
        stream.go_stale();
        stream.append_keyframe(b"KF");
        link.heard(&client_packet(0), now);
        let packets = link.transmit(now, &stream, HEADER);
        assert_eq!(packets.len(), 1);
        assert!(packets[0].jump);
        assert_eq!(packets[0].data, Some((4, b"KF".to_vec())));
    }

    #[test]
    fn input_is_acknowledged_after_the_delay_even_with_nothing_to_send() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let stream = Stream::default();
        link.heard(&client_packet(0), now);
        link.transmit(now, &stream, HEADER);
        let mut typed = client_packet(0);
        typed.input = Some((0, b"x".to_vec()));
        link.heard(&typed, now);
        assert_eq!(link.deadline(now, &stream), Some(now + ACK_DELAY));
        let header = Header {
            input_ack: 1,
            size_gen: 0,
        };
        let packets = link.transmit(now + ACK_DELAY, &stream, header);
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0].input_ack, 1);
    }

    #[test]
    fn a_silent_phone_is_left_alone() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        link.heard(&client_packet(0), now);
        stream.append(b"x");
        let asleep = now + SILENCE;
        assert!(link.transmit(asleep, &stream, HEADER).is_empty());
        assert_eq!(link.deadline(asleep, &stream), None);
    }

    #[test]
    fn the_first_packet_echoes_the_timestamp_and_the_rest_do_not() {
        let now = Instant::now();
        let mut link = Link::new(now);
        let mut stream = Stream::default();
        stream.append(&[0; 2 * SERVER_MAX_DATA]);
        let mut stamped = client_packet(0);
        stamped.timestamp = 1234;
        link.heard(&stamped, now);
        let packets = link.transmit(now, &stream, HEADER);
        assert_eq!(packets[0].timestamp_reply, 1234);
        assert_eq!(packets[1].timestamp_reply, NO_TIMESTAMP);
    }
}
