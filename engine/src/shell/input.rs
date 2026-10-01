#[derive(Debug, Default)]
pub struct Input {
    next: u64,
}

impl Input {
    pub fn ack(&self) -> u64 {
        self.next
    }

    pub fn accept<'a>(&mut self, offset: u64, bytes: &'a [u8]) -> &'a [u8] {
        let end = offset + bytes.len() as u64;
        if offset > self.next || end <= self.next {
            return &[];
        }
        let fresh = &bytes[(self.next - offset) as usize..];
        self.next = end;
        fresh
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_are_taken_once_and_in_order() {
        let mut input = Input::default();
        assert_eq!(input.accept(0, b"ab"), b"ab");
        assert_eq!(input.accept(0, b"abc"), b"c");
        assert_eq!(input.accept(1, b"b"), b"");
        assert_eq!(input.accept(5, b"x"), b"");
        assert_eq!(input.ack(), 3);
        assert_eq!(input.accept(3, b"de"), b"de");
        assert_eq!(input.ack(), 5);
    }
}
