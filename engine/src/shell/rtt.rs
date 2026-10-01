use super::wire::NO_TIMESTAMP;
use std::time::{Duration, Instant};

pub const MIN_RTO: Duration = Duration::from_millis(50);
pub const MAX_RTO: Duration = Duration::from_millis(1000);
const MAX_SAMPLE: u16 = 5000;

pub struct Clock {
    origin: Instant,
}

impl Clock {
    pub fn new(origin: Instant) -> Self {
        Self { origin }
    }

    pub fn stamp(&self, now: Instant) -> u16 {
        let stamp = (now.duration_since(self.origin).as_millis() & 0xffff) as u16;
        if stamp == NO_TIMESTAMP {
            0
        } else {
            stamp
        }
    }
}

#[derive(Debug, Default)]
pub struct Rtt {
    smoothed: Option<f64>,
    variance: f64,
    heard: Option<(u16, Instant)>,
}

impl Rtt {
    pub fn observe(&mut self, now_stamp: u16, timestamp: u16, reply: u16, now: Instant) {
        if timestamp != NO_TIMESTAMP {
            self.heard = Some((timestamp, now));
        }
        if reply == NO_TIMESTAMP {
            return;
        }
        let sample = now_stamp.wrapping_sub(reply);
        if sample > MAX_SAMPLE {
            return;
        }
        let sample = f64::from(sample);
        match self.smoothed {
            None => {
                self.smoothed = Some(sample);
                self.variance = sample / 2.0;
            }
            Some(srtt) => {
                self.variance = 0.75 * self.variance + 0.25 * (srtt - sample).abs();
                self.smoothed = Some(0.875 * srtt + 0.125 * sample);
            }
        }
    }

    pub fn take_reply(&mut self, now: Instant) -> u16 {
        match self.heard.take() {
            None => NO_TIMESTAMP,
            Some((stamp, at)) => {
                let held = now.duration_since(at).as_millis().min(u128::from(u16::MAX)) as u16;
                let reply = stamp.wrapping_add(held);
                if reply == NO_TIMESTAMP {
                    reply.wrapping_add(1)
                } else {
                    reply
                }
            }
        }
    }

    #[cfg(test)]
    pub fn owes_reply(&self) -> bool {
        self.heard.is_some()
    }

    pub fn rto(&self) -> Duration {
        let Some(srtt) = self.smoothed else {
            return MAX_RTO;
        };
        let rto = Duration::from_secs_f64((srtt + 4.0 * self.variance).max(0.0) / 1000.0);
        rto.clamp(MIN_RTO, MAX_RTO)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_sample_sets_the_estimate() {
        let now = Instant::now();
        let mut rtt = Rtt::default();
        assert_eq!(rtt.rto(), MAX_RTO);
        rtt.observe(1100, NO_TIMESTAMP, 1000, now);
        assert_eq!(rtt.rto(), Duration::from_millis(300));
    }

    #[test]
    fn the_rto_is_clamped() {
        let now = Instant::now();
        let mut rtt = Rtt::default();
        for _ in 0..50 {
            rtt.observe(1001, NO_TIMESTAMP, 1000, now);
        }
        assert_eq!(rtt.rto(), MIN_RTO);
    }

    #[test]
    fn a_stale_echo_is_ignored() {
        let now = Instant::now();
        let mut rtt = Rtt::default();
        rtt.observe(60000, NO_TIMESTAMP, 1000, now);
        assert_eq!(rtt.rto(), MAX_RTO);
    }

    #[test]
    fn the_echo_carries_the_hold_and_is_owed_once() {
        let now = Instant::now();
        let mut rtt = Rtt::default();
        rtt.observe(0, 500, NO_TIMESTAMP, now);
        assert!(rtt.owes_reply());
        assert_eq!(rtt.take_reply(now + Duration::from_millis(20)), 520);
        assert_eq!(rtt.take_reply(now), NO_TIMESTAMP);
    }

    #[test]
    fn a_stamp_never_reads_as_none() {
        let origin = Instant::now();
        let clock = Clock::new(origin);
        assert_eq!(clock.stamp(origin + Duration::from_millis(0xffff)), 0);
    }
}
