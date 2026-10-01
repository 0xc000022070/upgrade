use std::fs::{self, Metadata};
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

const SETTLE: Duration = Duration::from_secs(5);
const FORGET: Duration = Duration::from_secs(60);

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Reply {
    pub id: u64,
    pub number: u64,
}

impl Reply {
    fn expected(self) -> bool {
        self.id != 0 || self.number != 0
    }

    /// A command sent with only `I=` is answered with the id the terminal assigned as well.
    fn answers(self, claim: Reply) -> bool {
        if claim.number != 0 {
            self.number == claim.number
        } else {
            self.id == claim.id
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Object {
    path: PathBuf,
    dev: u64,
    ino: u64,
}

impl Object {
    pub fn new(path: PathBuf, metadata: &Metadata) -> Self {
        Self {
            path,
            dev: metadata.dev(),
            ino: metadata.ino(),
        }
    }

    fn taken(&self) -> bool {
        fs::symlink_metadata(&self.path).map_or(true, |found| {
            (found.dev(), found.ino()) != (self.dev, self.ino)
        })
    }
}

struct Claim {
    reply: Reply,
    object: Object,
    since: Instant,
    theirs: Option<bool>,
}

impl Claim {
    fn settle(&mut self) -> bool {
        let object = &self.object;
        *self.theirs.get_or_insert_with(|| {
            let taken = object.taken();
            if !taken {
                let _ = fs::remove_file(&object.path);
            }
            taken
        })
    }

    fn deadline(&self) -> Instant {
        self.since
            + if self.theirs.is_none() {
                SETTLE
            } else {
                FORGET
            }
    }
}

/// Under a multiplexer another terminal may read the same temporary file first, delete it and
/// answer, so the object stays until the phone's answer shows whether it is still ours to drop.
#[derive(Default)]
pub struct Claims {
    open: Vec<Claim>,
}

impl Claims {
    pub fn hold(&mut self, reply: Reply, object: Object, now: Instant) {
        self.open.push(Claim {
            reply,
            object,
            since: now,
            theirs: None,
        });
    }

    pub fn answer(&mut self, input: &[u8], out: &mut Vec<u8>) {
        let mut rest = input;
        while let Some((start, end, reply)) =
            (!self.open.is_empty()).then(|| next_reply(rest)).flatten()
        {
            out.extend_from_slice(&rest[..start]);
            if !self.theirs(reply) {
                out.extend_from_slice(&rest[start..end]);
            }
            rest = &rest[end..];
        }
        out.extend_from_slice(rest);
    }

    pub fn expire(&mut self, now: Instant) {
        for claim in &mut self.open {
            if now >= claim.since + SETTLE {
                claim.settle();
            }
        }
        self.open.retain(|claim| now < claim.since + FORGET);
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.open.iter().map(Claim::deadline).min()
    }

    fn theirs(&mut self, reply: Reply) -> bool {
        let found = reply
            .expected()
            .then(|| {
                self.open
                    .iter()
                    .position(|claim| reply.answers(claim.reply))
            })
            .flatten();
        found.is_some_and(|at| self.open.remove(at).settle())
    }
}

impl Drop for Claims {
    fn drop(&mut self) {
        for claim in &mut self.open {
            claim.settle();
        }
    }
}

fn next_reply(bytes: &[u8]) -> Option<(usize, usize, Reply)> {
    let start = find(bytes, b"\x1b_G")?;
    let end = start + find(&bytes[start..], b"\x1b\\")? + 2;
    let body = &bytes[start + 3..end - 2];
    let keys = body.split(|&b| b == b';').next().unwrap_or_default();
    let mut reply = Reply::default();
    for pair in keys.split(|&b| b == b',') {
        let number = || std::str::from_utf8(pair.get(2..)?).ok()?.parse().ok();
        match pair {
            [b'i', b'=', ..] => reply.id = number().unwrap_or(0),
            [b'I', b'=', ..] => reply.number = number().unwrap_or(0),
            _ => {}
        }
    }
    Some((start, end, reply))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::testing;

    fn object(path: &PathBuf) -> Object {
        Object::new(path.clone(), &fs::metadata(path).unwrap())
    }

    fn reply(id: u64) -> Reply {
        Reply { id, number: 0 }
    }

    fn answer(claims: &mut Claims, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        claims.answer(input, &mut out);
        out
    }

    #[test]
    fn an_object_nobody_else_took_is_dropped_and_the_answer_goes_through() {
        let dir = testing::scratch("kitty-claims", "ours");
        let path = dir.join("tty-graphics-protocol-1");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        claims.hold(reply(3), object(&path), Instant::now());
        let input = b"j\x1b_Gi=3;OK\x1b\\k";
        assert_eq!(answer(&mut claims, input), input);
        assert!(!path.exists());
        assert!(claims.deadline().is_none());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn an_object_another_terminal_took_silences_the_phone() {
        let dir = testing::scratch("kitty-claims", "theirs");
        let path = dir.join("tty-graphics-protocol-2");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        claims.hold(reply(4), object(&path), Instant::now());
        claims.hold(reply(4), object(&path), Instant::now());
        let another = dir.join("another");
        fs::write(&another, b"another").unwrap();
        fs::rename(&another, &path).unwrap();
        let input = b"\x1b_Gi=9;OK\x1b\\\x1b_Gi=4;OK\x1b\\x\x1b_Gi=4;OK\x1b\\";
        assert_eq!(answer(&mut claims, input), b"\x1b_Gi=9;OK\x1b\\x");
        assert!(path.exists(), "a newer file under the name is not ours");
        assert_eq!(
            answer(&mut claims, b"\x1b_Gi=4;OK\x1b\\"),
            b"\x1b_Gi=4;OK\x1b\\"
        );
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_numbered_command_is_answered_with_the_assigned_id_too() {
        let dir = testing::scratch("kitty-claims", "numbered");
        let path = dir.join("tty-graphics-protocol-5");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        claims.hold(Reply { id: 0, number: 8 }, object(&path), Instant::now());
        fs::remove_file(&path).unwrap();
        assert_eq!(
            answer(&mut claims, b"\x1b_Gi=3,I=9;OK\x1b\\\x1b_Gi=3,I=8;OK\x1b\\"),
            b"\x1b_Gi=3,I=9;OK\x1b\\"
        );
        assert!(claims.deadline().is_none());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_silent_phone_has_the_object_dropped_and_the_late_answer_judged() {
        let dir = testing::scratch("kitty-claims", "silent");
        let path = dir.join("tty-graphics-protocol-3");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        let start = Instant::now();
        claims.hold(reply(5), object(&path), start);
        assert_eq!(claims.deadline(), Some(start + SETTLE));
        claims.expire(start + SETTLE);
        assert!(!path.exists());
        assert_eq!(claims.deadline(), Some(start + FORGET));
        assert_eq!(
            answer(&mut claims, b"\x1b_Gi=5;OK\x1b\\"),
            b"\x1b_Gi=5;OK\x1b\\"
        );

        fs::write(&path, b"png").unwrap();
        claims.hold(reply(6), object(&path), start);
        claims.expire(start + FORGET);
        assert!(claims.deadline().is_none());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn keystrokes_and_split_answers_pass_untouched() {
        let mut claims = Claims::default();
        assert_eq!(
            answer(&mut claims, b"\x1b_Gi=1;OK\x1b\\"),
            b"\x1b_Gi=1;OK\x1b\\"
        );
        let dir = testing::scratch("kitty-claims", "keys");
        let path = dir.join("tty-graphics-protocol-4");
        fs::write(&path, b"png").unwrap();
        claims.hold(reply(1), object(&path), Instant::now());
        for input in [&b"\x1b"[..], b"\x1b_Gi=1;O", b"K\x1b\\", b"\x1b_G;OK\x1b\\"] {
            assert_eq!(answer(&mut claims, input), input);
        }
        assert!(path.exists());
        drop(claims);
        assert!(!path.exists(), "a server going away drops what it held");
        fs::remove_dir_all(&dir).unwrap();
    }
}
