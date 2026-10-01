use super::wire::SERVER_MAX_DATA;

pub const MIN: u64 = 16 * 1024;
pub const INITIAL: u64 = 64 * 1024;
pub const MAX: u64 = 4 * 1024 * 1024;

#[derive(Debug)]
pub struct Window {
    size: u64,
    threshold: u64,
}

impl Default for Window {
    fn default() -> Self {
        Self {
            size: INITIAL,
            threshold: MAX,
        }
    }
}

impl Window {
    pub fn admits(&self, in_flight: u64) -> bool {
        in_flight < self.size
    }

    pub fn acknowledged(&mut self, bytes: u64) {
        let grown = if self.size < self.threshold {
            (self.size + bytes).min(self.threshold)
        } else {
            self.size + (SERVER_MAX_DATA as u64 * bytes / self.size).max(1)
        };
        self.size = grown.min(MAX);
    }

    pub fn timed_out(&mut self) {
        self.threshold = (self.size / 2).max(MIN);
        self.size = MIN;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_grows_fast_then_slow_and_collapses_on_loss() {
        let mut window = Window::default();
        window.acknowledged(INITIAL);
        assert_eq!(window.size, 2 * INITIAL);
        window.timed_out();
        assert_eq!(window.size, MIN);
        window.acknowledged(INITIAL);
        assert_eq!(window.size, INITIAL, "slow start up to the threshold");
        window.acknowledged(INITIAL);
        assert!(window.size < INITIAL + 2 * SERVER_MAX_DATA as u64);
    }

    #[test]
    fn it_never_passes_the_ceiling() {
        let mut window = Window::default();
        window.acknowledged(100 * MAX);
        assert_eq!(window.size, MAX);
    }
}
