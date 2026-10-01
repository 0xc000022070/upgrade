use std::fs::{self, Metadata};
use std::os::unix::fs::MetadataExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

const SETTLE: Duration = Duration::from_secs(5);
const FORGET: Duration = Duration::from_secs(60);
const GRACE: Duration = Duration::from_secs(1);
const PARTIAL: usize = 512;

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
            claim.id != 0 && self.number == 0 && self.id == claim.id
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
    placed: Option<usize>,
    sent: Option<u64>,
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
    cuts: Vec<Cut>,
    partial: Vec<u8>,
    partial_since: Option<Instant>,
}

struct Cut {
    reached: u64,
    to: u64,
    jumped: Option<Instant>,
}

impl Cut {
    fn holds(&self, claim: &Claim) -> bool {
        claim
            .sent
            .is_some_and(|at| self.reached < at && at <= self.to)
    }

    fn heard(&mut self, ack: u64, now: Option<Instant>) {
        if ack <= self.to {
            self.reached = self.reached.max(ack);
        } else if let Some(now) = now {
            self.jumped.get_or_insert(now);
        } else {
            self.jumped = None;
        }
    }
}

impl Claims {
    pub fn hold(&mut self, reply: Reply, object: Object, now: Instant) {
        self.open.push(Claim {
            reply,
            object,
            since: now,
            theirs: None,
            placed: None,
            sent: None,
        });
    }

    pub fn placed(&mut self, at: usize) {
        for claim in self.open.iter_mut().filter(|claim| claim.sent.is_none()) {
            claim.placed.get_or_insert(at);
        }
    }

    /// Stamps the claims of `len` forwarded bytes with where their own command ends in the
    /// stream, which holds those bytes up to `end`.
    pub fn sent(&mut self, end: Option<u64>, len: usize) {
        for claim in self.open.iter_mut().filter(|claim| claim.sent.is_none()) {
            let after = len - claim.placed.unwrap_or(len).min(len);
            claim.sent = Some(end.map_or(0, |end| end - after as u64));
            if end.is_none() {
                claim.reply = Reply::default();
            }
        }
    }

    pub fn cut(&mut self, (from, to): (u64, u64), ack: u64, now: Option<Instant>) {
        let mut cut = Cut {
            reached: from,
            to,
            jumped: None,
        };
        cut.heard(ack, now);
        if self.open.iter().any(|claim| cut.holds(claim)) {
            self.cuts.push(cut);
        }
    }

    pub fn acked(&mut self, ack: u64, now: Option<Instant>) {
        let open = &mut self.open;
        self.cuts.retain_mut(|cut| {
            cut.heard(ack, now);
            let settled = cut
                .jumped
                .zip(now)
                .is_some_and(|(jumped, now)| now >= jumped + GRACE);
            if settled {
                for claim in open.iter_mut().filter(|claim| cut.holds(claim)) {
                    claim.reply = Reply::default();
                }
            }
            !settled
        });
    }

    pub fn answer(&mut self, input: &[u8], out: &mut Vec<u8>, now: Instant) {
        let joined = [std::mem::take(&mut self.partial).as_slice(), input].concat();
        let mut rest = joined.as_slice();
        while let Some((start, end, reply)) =
            (!self.open.is_empty()).then(|| next_reply(rest)).flatten()
        {
            out.extend_from_slice(&rest[..start]);
            if !self.theirs(reply) {
                out.extend_from_slice(&rest[start..end]);
            }
            rest = &rest[end..];
        }
        let split =
            find(rest, b"\x1b_G").filter(|&at| !self.open.is_empty() && rest.len() - at <= PARTIAL);
        let (passed, held) = rest.split_at(split.unwrap_or(rest.len()));
        out.extend_from_slice(passed);
        self.partial = held.to_vec();
        self.partial_since = split.map(|at| match at {
            0 => self.partial_since.unwrap_or(now),
            _ => now,
        });
    }

    pub fn stalled(&mut self, now: Instant) -> Vec<u8> {
        match self.partial_since {
            Some(since) if now >= since + GRACE => {
                self.partial_since = None;
                std::mem::take(&mut self.partial)
            }
            _ => Vec::new(),
        }
    }

    pub fn expire(&mut self, now: Instant) {
        for claim in &mut self.open {
            if now >= claim.since + SETTLE {
                claim.settle();
            }
        }
        self.open.retain(|claim| now < claim.since + FORGET);
        let open = &self.open;
        self.cuts
            .retain(|cut| open.iter().any(|claim| cut.holds(claim)));
    }

    pub fn deadline(&self) -> Option<Instant> {
        self.open
            .iter()
            .map(Claim::deadline)
            .chain(self.partial_since.map(|since| since + GRACE))
            .min()
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
        claims.answer(input, &mut out, Instant::now());
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
    fn an_answer_to_another_command_is_not_taken_for_ours() {
        let dir = testing::scratch("kitty-claims", "another");
        let path = dir.join("tty-graphics-protocol-6");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        claims.hold(Reply::default(), object(&path), Instant::now());
        claims.hold(reply(5), object(&path), Instant::now());
        fs::remove_file(&path).unwrap();
        let input = b"\x1b_GI=8;ENOENT: image not found\x1b\\\x1b_Gi=5,I=7;OK\x1b\\";
        assert_eq!(answer(&mut claims, input), input);
        assert_eq!(claims.open.len(), 2);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_late_answer_goes_to_the_older_claim_with_its_id() {
        let dir = testing::scratch("kitty-claims", "late");
        let first = dir.join("tty-graphics-protocol-7");
        let second = dir.join("tty-graphics-protocol-8");
        fs::write(&first, b"png").unwrap();
        let mut claims = Claims::default();
        let start = Instant::now();
        claims.hold(reply(1), object(&first), start);
        claims.sent(Some(10), 0);
        fs::remove_file(&first).unwrap();
        claims.expire(start + SETTLE);
        fs::write(&second, b"png").unwrap();
        claims.hold(reply(1), object(&second), start + SETTLE);
        claims.sent(Some(20), 0);
        assert_eq!(answer(&mut claims, b"\x1b_Gi=1;ENOENT\x1b\\"), b"");
        assert!(second.exists());
        let ok = b"\x1b_Gi=1;OK\x1b\\";
        assert_eq!(answer(&mut claims, ok), ok);
        assert!(!second.exists());
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_command_cut_before_the_phone_got_it_is_owed_no_answer() {
        let dir = testing::scratch("kitty-claims", "cut");
        let paths: Vec<PathBuf> = (9..13)
            .map(|n| dir.join(format!("tty-graphics-protocol-{n}")))
            .collect();
        for path in &paths {
            fs::write(path, b"png").unwrap();
        }
        let mut claims = Claims::default();
        let start = Instant::now();
        let at = Some(start);
        claims.hold(reply(2), object(&paths[0]), start);
        claims.sent(Some(5), 0);
        claims.hold(reply(1), object(&paths[1]), start);
        claims.sent(Some(10), 0);
        claims.cut((0, 12), 0, at);
        claims.acked(6, at);
        claims.acked(13, at);
        claims.acked(13, Some(start + GRACE));
        claims.hold(reply(1), object(&paths[2]), start);
        claims.sent(None, 0);
        claims.hold(reply(1), object(&paths[3]), start);
        claims.sent(Some(30), 0);
        let ok = b"\x1b_Gi=2;OK\x1b\\\x1b_Gi=1;OK\x1b\\";
        assert_eq!(answer(&mut claims, ok), ok);
        assert!(!paths[0].exists(), "the phone got it before the cut");
        assert!(paths[1].exists() && paths[2].exists());
        assert!(!paths[3].exists());
        drop(claims);
        fs::remove_dir_all(&dir).unwrap();
    }

    fn owed(
        name: &str,
        sent: (u64, usize),
        placed: Option<usize>,
        acks: &[(u64, Option<u64>)],
        cut: ((u64, u64), u64),
    ) -> bool {
        let dir = testing::scratch("kitty-claims", name);
        let path = dir.join("tty-graphics-protocol-3");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        let start = Instant::now();
        let at = |ms: Option<u64>| ms.map(|ms| start + Duration::from_millis(ms));
        claims.hold(reply(3), object(&path), start);
        if let Some(placed) = placed {
            claims.placed(placed);
        }
        claims.sent(Some(sent.0), sent.1);
        claims.cut(cut.0, cut.1, Some(start));
        for &(ack, ms) in acks {
            claims.acked(ack, at(ms));
        }
        answer(&mut claims, b"\x1b_Gi=3;OK\x1b\\");
        let owed = !path.exists();
        drop(claims);
        fs::remove_dir_all(&dir).unwrap();
        owed
    }

    #[test]
    fn a_phone_that_acked_the_whole_cut_got_its_command() {
        let late = Some(GRACE.as_millis() as u64);
        assert!(owed(
            "whole",
            (12, 0),
            None,
            &[(12, Some(0)), (20, Some(0)), (20, late)],
            ((0, 12), 0)
        ));
    }

    #[test]
    fn an_answer_just_behind_the_jump_is_still_owed() {
        assert!(owed(
            "behind",
            (10, 0),
            None,
            &[(13, Some(0))],
            ((0, 12), 0)
        ));
    }

    #[test]
    fn a_cut_heard_after_the_jump_still_settles_on_time() {
        let late = Some(GRACE.as_millis() as u64);
        assert!(!owed(
            "heard-late",
            (10, 0),
            None,
            &[(13, late)],
            ((0, 12), 13)
        ));
    }

    #[test]
    fn a_backed_up_phone_starts_no_grace() {
        let late = Some(GRACE.as_millis() as u64);
        assert!(owed(
            "backed-up",
            (10, 0),
            None,
            &[(13, None), (13, late)],
            ((0, 12), 0)
        ));
    }

    #[test]
    fn backpressure_after_the_jump_restarts_the_grace() {
        let acks = [(13, Some(0)), (13, None), (13, Some(1500))];
        assert!(owed("backed-up-late", (10, 0), None, &acks, ((0, 12), 0)));
    }

    #[test]
    fn a_reply_split_across_packets_is_still_matched() {
        let dir = testing::scratch("kitty-claims", "split");
        let path = dir.join("tty-graphics-protocol-3");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        claims.hold(reply(3), object(&path), Instant::now());
        assert_eq!(answer(&mut claims, b"x\x1b_Gi=3;O"), b"x");
        assert_eq!(answer(&mut claims, b"K\x1b\\y"), b"\x1b_Gi=3;OK\x1b\\y");
        assert!(!path.exists());
        drop(claims);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_split_that_never_ends_reaches_the_shell() {
        let dir = testing::scratch("kitty-claims", "stalled");
        let path = dir.join("tty-graphics-protocol-3");
        fs::write(&path, b"png").unwrap();
        let mut claims = Claims::default();
        let start = Instant::now();
        claims.hold(reply(3), object(&path), start);
        let mut out = Vec::new();
        claims.answer(b"\x1b_Gi=3", &mut out, start);
        assert!(out.is_empty());
        assert!(claims.stalled(start).is_empty());
        assert_eq!(claims.deadline(), Some(start + GRACE));
        assert_eq!(claims.stalled(start + GRACE), b"\x1b_Gi=3");
        drop(claims);
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_claim_is_stamped_where_its_own_command_ends() {
        let late = Some(GRACE.as_millis() as u64);
        let acks = [(101, Some(0)), (101, late)];
        assert!(owed("placed", (100, 50), Some(10), &acks, ((0, 100), 70)));
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
    fn keystrokes_and_unnumbered_answers_pass_untouched() {
        let mut claims = Claims::default();
        assert_eq!(
            answer(&mut claims, b"\x1b_Gi=1;OK\x1b\\"),
            b"\x1b_Gi=1;OK\x1b\\"
        );
        let dir = testing::scratch("kitty-claims", "keys");
        let path = dir.join("tty-graphics-protocol-4");
        fs::write(&path, b"png").unwrap();
        claims.hold(reply(1), object(&path), Instant::now());
        for input in [&b"\x1b"[..], b"\x1b_G;OK\x1b\\"] {
            assert_eq!(answer(&mut claims, input), input);
        }
        assert!(path.exists());
        drop(claims);
        assert!(!path.exists(), "a server going away drops what it held");
        fs::remove_dir_all(&dir).unwrap();
    }
}
