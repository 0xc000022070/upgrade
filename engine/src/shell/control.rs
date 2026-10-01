use super::wire::{ClientPacket, Size};

#[derive(Debug, Default)]
pub struct Control {
    size_gen: u32,
    keyframe: u32,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Directives {
    pub resize: Option<Size>,
    pub keyframe: bool,
    pub close: bool,
}

impl Control {
    pub fn size_gen(&self) -> u32 {
        self.size_gen
    }

    pub fn apply(&mut self, packet: &ClientPacket) -> Directives {
        let keyframe = packet.keyframe != 0 && packet.keyframe != self.keyframe;
        if keyframe {
            self.keyframe = packet.keyframe;
        }
        let usable = packet.size.cols > 0 && packet.size.rows > 0;
        let resize = (usable && (packet.size_gen > self.size_gen || keyframe)).then(|| {
            self.size_gen = packet.size_gen;
            packet.size
        });
        Directives {
            resize,
            keyframe,
            close: packet.close,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::wire::NO_TIMESTAMP;

    fn packet(keyframe: u32, size_gen: u32, cols: u16) -> ClientPacket {
        ClientPacket {
            close: false,
            timestamp: NO_TIMESTAMP,
            timestamp_reply: NO_TIMESTAMP,
            ack: 0,
            keyframe,
            size_gen,
            size: Size {
                cols,
                rows: 24,
                width_px: 0,
                height_px: 0,
            },
            input: None,
        }
    }

    #[test]
    fn a_late_size_never_wins_over_a_newer_one() {
        let mut control = Control::default();
        assert!(control.apply(&packet(0, 2, 100)).resize.is_some());
        assert_eq!(control.apply(&packet(0, 1, 80)).resize, None);
        assert_eq!(control.apply(&packet(0, 2, 100)).resize, None);
    }

    #[test]
    fn a_keyframe_id_is_served_once() {
        let mut control = Control::default();
        assert!(control.apply(&packet(7, 0, 0)).keyframe);
        assert!(!control.apply(&packet(7, 0, 0)).keyframe);
        assert!(control.apply(&packet(8, 0, 0)).keyframe);
    }

    #[test]
    fn a_phone_starting_over_resets_the_generation() {
        let mut control = Control::default();
        control.apply(&packet(1, 40, 100));
        let directives = control.apply(&packet(2, 1, 90));
        assert_eq!(directives.resize.map(|size| size.cols), Some(90));
        assert_eq!(control.size_gen(), 1);
    }

    #[test]
    fn a_zero_size_is_not_applied() {
        let mut control = Control::default();
        assert_eq!(control.apply(&packet(0, 1, 0)).resize, None);
    }
}
