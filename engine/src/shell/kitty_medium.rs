use super::kitty::MAX_KEYS;
use super::kitty_claims::{Claims, Object, Reply};
use super::IMAGE_BYTES;
use crate::util::{base64_decode, base64_encode};
use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::time::Instant;

const ESC: u8 = 0x1b;
const CAN: u8 = 0x18;
const SUB: u8 = 0x1a;
const CHUNK: usize = 4096;
const MAX_COMMAND: usize = 8192;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Medium {
    File,
    TemporaryFile,
    SharedMemory,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Span {
    pub offset: u64,
    pub size: Option<u64>,
    pub limit: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub reason: String,
    pub missing: bool,
}

impl From<String> for Refusal {
    fn from(reason: String) -> Self {
        Self {
            code: "EBADF",
            reason,
            missing: false,
        }
    }
}

impl From<&str> for Refusal {
    fn from(reason: &str) -> Self {
        reason.to_owned().into()
    }
}

pub trait Files {
    fn read(
        &mut self,
        medium: Medium,
        path: &Path,
        span: Span,
        reply: Reply,
    ) -> Result<Vec<u8>, Refusal>;

    fn placed(&mut self, at: usize);
}

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
enum State {
    #[default]
    Ground,
    Escape,
    Apc,
    Keys,
    Payload,
    End,
}

#[derive(Debug, Default)]
pub struct Media {
    state: State,
    held: Vec<u8>,
}

impl Media {
    pub fn feed(
        &mut self,
        bytes: &[u8],
        files: &mut impl Files,
        forward: &mut Vec<u8>,
        replies: &mut Vec<u8>,
    ) {
        let mut at = 0;
        while at < bytes.len() {
            at += match self.state {
                State::Ground => self.ground(&bytes[at..], forward),
                State::Escape => self.introducer(bytes[at], b'_', State::Apc, forward),
                State::Apc => self.introducer(bytes[at], b'G', State::Keys, forward),
                State::Keys => self.body(bytes[at], forward),
                State::Payload => self.payload(&bytes[at..], forward),
                State::End => self.end(bytes[at], files, forward, replies),
            };
        }
    }

    fn ground(&mut self, rest: &[u8], forward: &mut Vec<u8>) -> usize {
        let Some(n) = memchr::memchr(ESC, rest) else {
            forward.extend_from_slice(rest);
            return rest.len();
        };
        forward.extend_from_slice(&rest[..n]);
        self.held.push(ESC);
        self.state = State::Escape;
        n + 1
    }

    fn introducer(&mut self, byte: u8, expected: u8, next: State, forward: &mut Vec<u8>) -> usize {
        if byte != expected {
            self.release(forward);
            return 0;
        }
        self.held.push(byte);
        self.state = next;
        1
    }

    fn payload(&mut self, rest: &[u8], forward: &mut Vec<u8>) -> usize {
        let plain = memchr::memchr3(ESC, CAN, SUB, rest).unwrap_or(rest.len());
        if plain == 0 {
            return self.body(rest[0], forward);
        }
        let room = MAX_COMMAND.saturating_sub(self.held.len());
        if plain > room {
            self.held.extend_from_slice(&rest[..=room]);
            self.release(forward);
            return room + 1;
        }
        self.held.extend_from_slice(&rest[..plain]);
        plain
    }

    fn body(&mut self, byte: u8, forward: &mut Vec<u8>) -> usize {
        self.held.push(byte);
        match byte {
            ESC => self.state = State::End,
            CAN | SUB => self.release(forward),
            b';' if self.state == State::Keys => self.open_payload(forward),
            _ if self.held.len() > MAX_COMMAND => self.release(forward),
            _ => {}
        }
        1
    }

    fn open_payload(&mut self, forward: &mut Vec<u8>) {
        if command(&self.held[3..self.held.len() - 1]).is_some() {
            self.state = State::Payload;
        } else {
            self.release(forward);
        }
    }

    fn end(
        &mut self,
        byte: u8,
        files: &mut impl Files,
        forward: &mut Vec<u8>,
        replies: &mut Vec<u8>,
    ) -> usize {
        if byte != b'\\' {
            self.held.pop();
            self.release(forward);
            self.held.push(ESC);
            self.state = State::Escape;
            return 0;
        }
        self.held.push(byte);
        self.complete(files, forward, replies);
        1
    }

    pub fn finish(&mut self, forward: &mut Vec<u8>) {
        self.release(forward);
    }

    fn release(&mut self, forward: &mut Vec<u8>) {
        forward.append(&mut self.held);
        self.state = State::Ground;
    }

    fn complete(&mut self, files: &mut impl Files, forward: &mut Vec<u8>, replies: &mut Vec<u8>) {
        let body = &self.held[3..self.held.len() - 2];
        let (keys, payload) = match body.iter().position(|&b| b == b';') {
            Some(n) => (&body[..n], &body[n + 1..]),
            None => (body, &[][..]),
        };
        match command(keys) {
            Some(command) => {
                match command.read(payload, files) {
                    Ok(bytes) if command.fits => command.direct(&bytes, forward),
                    Ok(_) => command.refuse(&too_long(), replies),
                    Err(refusal) => command.refuse(&refusal, replies),
                }
                files.placed(forward.len());
            }
            None => forward.extend_from_slice(&self.held),
        }
        self.held.clear();
        self.state = State::Ground;
    }
}

struct Command<'a> {
    keys: Vec<(u8, &'a [u8])>,
    medium: Medium,
    direct_keys: Vec<u8>,
    fits: bool,
}

fn command(keys: &[u8]) -> Option<Command<'_>> {
    let keys = keys
        .split(|&b| b == b',')
        .map(|pair| match pair {
            [key, b'=', value @ ..] if !value.is_empty() => Some((*key, value)),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    let mut command = Command {
        direct_keys: Vec::new(),
        fits: false,
        medium: match value(&keys, b't')? {
            b"f" => Medium::File,
            b"t" => Medium::TemporaryFile,
            b"s" => Medium::SharedMemory,
            _ => return None,
        },
        keys,
    };
    for key in *b"iIpqmSOsvf" {
        command.number(key)?;
    }
    command.direct_keys = command.normal_keys();
    command.fits = command.direct_keys.len() + b",m=1".len() <= MAX_KEYS;
    (command.number(b'm')? == 0).then_some(command)
}

fn too_long() -> Refusal {
    Refusal {
        code: "EINVAL",
        reason: "the keys are too long".into(),
        missing: false,
    }
}

fn value<'a>(keys: &[(u8, &'a [u8])], key: u8) -> Option<&'a [u8]> {
    keys.iter().rev().find(|(k, _)| *k == key).map(|(_, v)| *v)
}

impl Command<'_> {
    fn number(&self, key: u8) -> Option<u64> {
        match value(&self.keys, key) {
            None => Some(0),
            Some(text) => std::str::from_utf8(text).ok()?.parse().ok(),
        }
    }

    fn read(&self, payload: &[u8], files: &mut impl Files) -> Result<Vec<u8>, Refusal> {
        let path = base64_decode(payload).ok_or("the path is not base64")?;
        let size = match self.number(b'S').unwrap_or(0) {
            0 => self.shared_memory_size(),
            size => Some(size),
        };
        let span = Span {
            offset: self.number(b'O').unwrap_or(0),
            size,
            limit: IMAGE_BYTES,
        };
        let reply = self.reply();
        let fits = |n: u64| u32::try_from(n).is_ok();
        let answered =
            self.fits && self.number(b'q') == Some(0) && fits(reply.id) && fits(reply.number);
        let reply = if answered { reply } else { Reply::default() };
        files.read(
            self.medium,
            Path::new(OsStr::from_bytes(&path)),
            span,
            reply,
        )
    }

    fn shared_memory_size(&self) -> Option<u64> {
        if self.medium != Medium::SharedMemory || value(&self.keys, b'o').is_some() {
            return None;
        }
        let depth = match self.number(b'f').unwrap_or(0) {
            0 | 32 => 4,
            24 => 3,
            _ => return None,
        };
        self.number(b's')?
            .checked_mul(self.number(b'v')?)?
            .checked_mul(depth)
            .filter(|&size| size > 0)
    }

    fn direct(&self, bytes: &[u8], out: &mut Vec<u8>) {
        let keys = &self.direct_keys;
        let encoded = base64_encode(bytes);
        let chunks: Vec<&[u8]> = encoded.as_bytes().chunks(CHUNK).collect();
        if chunks.len() <= 1 {
            write_command(out, keys, encoded.as_bytes());
            return;
        }
        let quiet = self.number(b'q').unwrap_or(0);
        let last = chunks.len() - 1;
        for (index, chunk) in chunks.into_iter().enumerate() {
            let mut control = if index == 0 {
                [&keys[..], b","].concat()
            } else {
                match quiet {
                    0 => Vec::new(),
                    q => format!("q={q},").into_bytes(),
                }
            };
            control.extend_from_slice(if index == last { b"m=0" } else { b"m=1" });
            write_command(out, &control, chunk);
        }
    }

    fn normal_keys(&self) -> Vec<u8> {
        let mut keys = Vec::new();
        for (at, (key, value)) in self.keys.iter().enumerate() {
            let later = self.keys[at + 1..].iter().any(|(k, _)| k == key);
            if later || matches!(key, b'S' | b'O' | b'm') {
                continue;
            }
            if !keys.is_empty() {
                keys.push(b',');
            }
            keys.extend_from_slice(&[*key, b'=']);
            let number = std::str::from_utf8(value)
                .ok()
                .and_then(|text| text.parse::<i128>().ok());
            match (key, number) {
                (b't', _) => keys.push(b'd'),
                (_, Some(number)) => keys.extend_from_slice(number.to_string().as_bytes()),
                (_, None) => keys.extend_from_slice(value),
            }
        }
        keys
    }

    fn reply(&self) -> Reply {
        Reply {
            id: self.number(b'i').unwrap_or(0),
            number: self.number(b'I').unwrap_or(0),
        }
    }

    fn refuse(&self, refusal: &Refusal, out: &mut Vec<u8>) {
        let quiet = self.number(b'q').unwrap_or(0);
        let Reply { id, number } = self.reply();
        let taken_elsewhere = refusal.missing && self.medium != Medium::File;
        if quiet >= 2 || (id == 0 && number == 0) || taken_elsewhere {
            return;
        }
        let mut keys = Vec::new();
        for (key, value) in [
            ("i", id),
            ("I", number),
            ("p", self.number(b'p').unwrap_or(0)),
        ] {
            if value != 0 {
                keys.push(format!("{key}={value}"));
            }
        }
        let message = format!(
            "{}: {}",
            refusal.code,
            refusal.reason.replace(ESC as char, "")
        );
        write_command(out, keys.join(",").as_bytes(), message.as_bytes());
    }
}

fn write_command(out: &mut Vec<u8>, keys: &[u8], payload: &[u8]) {
    out.extend_from_slice(b"\x1b_G");
    out.extend_from_slice(keys);
    out.push(b';');
    out.extend_from_slice(payload);
    out.extend_from_slice(b"\x1b\\");
}

pub struct HostFiles {
    temp_dirs: Vec<PathBuf>,
    pub claims: Claims,
}

impl Default for HostFiles {
    fn default() -> Self {
        let temp = std::env::temp_dir();
        let mut temp_dirs = vec![PathBuf::from("/tmp"), PathBuf::from("/dev/shm")];
        temp_dirs.extend(fs::canonicalize(&temp).ok());
        temp_dirs.push(temp);
        Self {
            temp_dirs,
            claims: Claims::default(),
        }
    }
}

impl Files for HostFiles {
    fn read(
        &mut self,
        medium: Medium,
        path: &Path,
        span: Span,
        reply: Reply,
    ) -> Result<Vec<u8>, Refusal> {
        let (bytes, left) = match medium {
            Medium::File => read_file(path, span, 0, |_| Ok(false)),
            Medium::TemporaryFile => read_file(path, span, 0, |real| self.temporary(real)),
            Medium::SharedMemory => read_shared_memory(path, span),
        }?;
        if let Some(object) = left {
            let reply = if bytes.is_ok() {
                reply
            } else {
                Reply::default()
            };
            self.claims.hold(reply, object, Instant::now());
        }
        bytes
    }

    fn placed(&mut self, at: usize) {
        self.claims.placed(at);
    }
}

impl HostFiles {
    fn temporary(&self, real: &Path) -> Result<bool, String> {
        if !self.temp_dirs.iter().any(|dir| real.starts_with(dir)) {
            return Err("temporary file not in a temporary directory".into());
        }
        let named = real
            .as_os_str()
            .as_bytes()
            .windows(b"tty-graphics-protocol".len())
            .any(|window| window == b"tty-graphics-protocol");
        if !named {
            return Err("temporary file not named tty-graphics-protocol".into());
        }
        Ok(true)
    }
}

#[cfg(target_os = "linux")]
fn read_shared_memory(name: &Path, span: Span) -> Result<Taken, Refusal> {
    let name = name.as_os_str().as_bytes();
    let valid = name.len() > 1
        && name.len() <= 255
        && name[0] == b'/'
        && name != b"/."
        && name != b"/.."
        && !name[1..].contains(&b'/');
    if !valid {
        return Err("not a shared memory name".into());
    }
    let path = Path::new("/dev/shm").join(OsStr::from_bytes(&name[1..]));
    read_file(&path, span, libc::O_NOFOLLOW, |_| Ok(true))
}

#[cfg(not(target_os = "linux"))]
fn read_shared_memory(_: &Path, _: Span) -> Result<Taken, Refusal> {
    Err("shared memory is not readable on this host".into())
}

type Taken = (Result<Vec<u8>, Refusal>, Option<Object>);

fn read_file(
    path: &Path,
    span: Span,
    flags: libc::c_int,
    consumed: impl FnOnce(&Path) -> Result<bool, String>,
) -> Result<Taken, Refusal> {
    // Non-blocking, so a fifo named here cannot stall the server in open(2).
    let mut file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY | flags)
        .open(path)
        .map_err(|err| Refusal {
            missing: err.kind() == io::ErrorKind::NotFound,
            ..Refusal::from(err.to_string())
        })?;
    let real = real_path(&file, path).map_err(|err| err.to_string())?;
    let real_text = real.as_os_str().as_bytes();
    let blocked = real_text.starts_with(b"/proc/")
        || real_text.starts_with(b"/sys/")
        || (real_text.starts_with(b"/dev/") && !real_text.starts_with(b"/dev/shm/"));
    if blocked {
        return Err("not a file images are read from".into());
    }
    if !consumed(&real)? {
        return Ok((read_span(&mut file, span), None));
    }
    let metadata = file.metadata().map_err(|err| err.to_string())?;
    Ok((
        read_span(&mut file, span),
        Some(Object::new(real, &metadata)),
    ))
}

#[cfg(target_os = "linux")]
fn real_path(file: &File, _: &Path) -> io::Result<PathBuf> {
    use std::os::fd::AsRawFd;
    fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
}

#[cfg(not(target_os = "linux"))]
fn real_path(_: &File, path: &Path) -> io::Result<PathBuf> {
    fs::canonicalize(path)
}

fn read_span(file: &mut File, span: Span) -> Result<Vec<u8>, Refusal> {
    let metadata = file.metadata().map_err(|err| err.to_string())?;
    if !metadata.is_file() {
        return Err("not a regular file".into());
    }
    let available = metadata
        .len()
        .checked_sub(span.offset)
        .ok_or("offset past the end of the file")?;
    let size = span.size.unwrap_or(available);
    if size > span.limit {
        return Err(Refusal {
            code: "EFBIG",
            reason: format!("larger than the {} bytes an image may be", span.limit),
            missing: false,
        });
    }
    if size > available {
        return Err("file shorter than the size asked for".into());
    }
    let mut bytes = vec![0; size as usize];
    file.seek(SeekFrom::Start(span.offset))
        .and_then(|_| file.read_exact(&mut bytes))
        .map_err(|err| err.to_string())?;
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::kitty::Transmissions;
    use crate::shell::testing;
    use crate::util::now_millis;
    use std::collections::HashMap;

    #[derive(Default)]
    struct FakeFiles {
        files: HashMap<PathBuf, Vec<u8>>,
        asked: Vec<(Medium, PathBuf, Span)>,
        claimed: Vec<Reply>,
        placed: Vec<usize>,
    }

    impl Files for FakeFiles {
        fn read(
            &mut self,
            medium: Medium,
            path: &Path,
            span: Span,
            reply: Reply,
        ) -> Result<Vec<u8>, Refusal> {
            self.asked.push((medium, path.to_owned(), span));
            self.claimed.push(reply);
            let bytes = self.files.get(path).ok_or(Refusal {
                missing: true,
                ..Refusal::from("No such file or directory")
            })?;
            let start = span.offset as usize;
            if span.size.is_some_and(|size| size > span.limit) {
                return Err(Refusal {
                    code: "EFBIG",
                    reason: "too large".into(),
                    missing: false,
                });
            }
            let end = span.size.map_or(bytes.len(), |size| start + size as usize);
            Ok(bytes[start..end].to_vec())
        }

        fn placed(&mut self, at: usize) {
            self.placed.push(at);
        }
    }

    fn fake(path: &str, bytes: &[u8]) -> FakeFiles {
        let mut files = FakeFiles::default();
        files.files.insert(PathBuf::from(path), bytes.to_vec());
        files
    }

    fn cmd(keys: &str, path: &str) -> Vec<u8> {
        format!("\x1b_G{keys};{}\x1b\\", base64_encode(path.as_bytes())).into_bytes()
    }

    fn run(files: &mut impl Files, pieces: &[&[u8]]) -> (Vec<u8>, Vec<u8>) {
        let mut media = Media::default();
        let (mut forward, mut replies) = (Vec::new(), Vec::new());
        for piece in pieces {
            media.feed(piece, files, &mut forward, &mut replies);
        }
        media.finish(&mut forward);
        (forward, replies)
    }

    fn text(bytes: &[u8]) -> String {
        String::from_utf8_lossy(bytes).into_owned()
    }

    #[test]
    fn a_file_is_sent_on_as_its_bytes() {
        let mut files = fake("/tmp/x.rgb", &[1, 2, 3]);
        let input = cmd("a=q,i=1,f=24,t=f,s=1,v=1,S=3", "/tmp/x.rgb");
        let (forward, replies) = run(&mut files, &[&input]);
        assert_eq!(text(&forward), "\x1b_Ga=q,i=1,f=24,t=d,s=1,v=1;AQID\x1b\\");
        assert!(replies.is_empty());
        assert_eq!(files.asked[0].0, Medium::File);
    }

    #[test]
    fn size_and_offset_reach_the_read() {
        let mut files = fake("/f", b"..abc..");
        let (forward, _) = run(&mut files, &[&cmd("a=T,t=f,O=2,S=3,i=4", "/f")]);
        assert_eq!(text(&forward), "\x1b_Ga=T,t=d,i=4;YWJj\x1b\\");
        let span = files.asked[0].2;
        assert_eq!((span.offset, span.size), (2, Some(3)));
    }

    #[test]
    fn shared_memory_without_a_size_reads_what_the_dimensions_say() {
        let mut files = fake("/name", &[7; 4096]);
        run(&mut files, &[&cmd("a=T,t=s,f=24,s=2,v=3", "/name")]);
        assert_eq!(files.asked[0].2.size, Some(18));
        assert_eq!(files.asked[0].0, Medium::SharedMemory);
        run(&mut files, &[&cmd("a=T,t=s,f=100", "/name")]);
        assert_eq!(files.asked[1].2.size, None);
    }

    #[test]
    fn a_large_file_is_chunked_with_q_carried() {
        let bytes = vec![9u8; CHUNK * 2];
        let mut files = fake("/big", &bytes);
        let (forward, _) = run(&mut files, &[&cmd("a=T,t=f,i=2,q=1", "/big")]);
        let out = text(&forward);
        let commands: Vec<&str> = out.split("\x1b\\").filter(|c| !c.is_empty()).collect();
        assert_eq!(commands.len(), 3);
        assert!(commands[0].starts_with("\x1b_Ga=T,t=d,i=2,q=1,m=1;"));
        assert!(commands[1].starts_with("\x1b_Gq=1,m=1;"));
        assert!(commands[2].starts_with("\x1b_Gq=1,m=0;"));
        assert!(commands
            .iter()
            .all(|c| c.split(';').nth(1).unwrap().len() <= CHUNK));
        let payload: String = commands
            .iter()
            .map(|c| c.split(';').nth(1).unwrap())
            .collect();
        assert_eq!(base64_decode(payload.as_bytes()).unwrap(), bytes);
        let framing = forward.len() - payload.len() - commands[0].find(';').unwrap();
        assert!(
            framing <= (commands.len() - 1) * 32,
            "mirror::transmission_bytes allows 32 a chunk"
        );
    }

    #[test]
    fn padded_keys_are_sent_on_plain_so_the_transmission_stays_seen() {
        let bytes = vec![9u8; CHUNK * 2];
        let mut files = fake("/big", &bytes);
        let padded = format!(
            "a=T,t=f,i=1,i=+2,s=0{},z=-03,q=000{}1",
            "0".repeat(300),
            "0".repeat(200)
        );
        let (forward, _) = run(&mut files, &[&cmd(&padded, "/big")]);
        let out = text(&forward);
        let commands: Vec<&str> = out.split("\x1b\\").filter(|c| !c.is_empty()).collect();
        assert!(commands[0].starts_with("\x1b_Ga=T,t=d,i=2,s=0,z=-3,q=1,m=1;"));
        assert!(commands[1].starts_with("\x1b_Gq=1,m=1;"));
        let mut seen = Transmissions::new(u64::MAX);
        for command in &commands[..commands.len() - 1] {
            seen.feed(command.as_bytes());
            seen.feed(b"\x1b\\");
            assert!(seen.open());
        }

        let long = format!("a=T,t=t,i=3,o={}", "z".repeat(MAX_KEYS));
        let (forward, replies) = run(&mut files, &[&cmd(&long, "/big")]);
        assert!(forward.is_empty(), "keys too long to track are not sent on");
        assert_eq!(
            text(&replies),
            "\x1b_Gi=3;EINVAL: the keys are too long\x1b\\"
        );
        assert_eq!(
            files.asked.len(),
            2,
            "the object is still read, so it is dropped"
        );
        assert_eq!(files.claimed[1], Reply::default());
    }

    #[test]
    fn a_missing_file_is_answered_and_goes_no_further() {
        let mut files = FakeFiles::default();
        let (forward, replies) = run(
            &mut files,
            &[b"a", &cmd("a=q,i=31,p=2,t=f,f=24,s=1,v=1", "/gone"), b"b"],
        );
        assert_eq!(text(&forward), "ab");
        assert_eq!(
            text(&replies),
            "\x1b_Gi=31,p=2;EBADF: No such file or directory\x1b\\"
        );
    }

    #[test]
    fn a_temporary_object_already_gone_was_answered_by_whoever_took_it() {
        let mut files = FakeFiles::default();
        for medium in ["t", "s"] {
            let keys = format!("a=T,i=8,t={medium},f=100");
            let (forward, replies) =
                run(&mut files, &[&cmd(&keys, "/tmp/tty-graphics-protocol-9")]);
            assert!(forward.is_empty());
            assert!(replies.is_empty(), "{medium}");
        }
    }

    #[test]
    fn a_file_past_the_cap_is_answered_efbig_and_goes_no_further() {
        let mut files = fake("/big", b"x");
        let keys = format!("a=T,i=6,t=f,S={}", IMAGE_BYTES + 1);
        let (forward, replies) = run(&mut files, &[&cmd(&keys, "/big")]);
        assert!(forward.is_empty());
        assert_eq!(text(&replies), "\x1b_Gi=6;EFBIG: too large\x1b\\");
        assert_eq!(files.asked[0].2.limit, IMAGE_BYTES);
    }

    #[test]
    fn quiet_is_honoured_as_kitty_says() {
        let mut files = FakeFiles::default();
        let (_, replies) = run(&mut files, &[&cmd("a=T,i=1,q=1,t=f", "/gone")]);
        assert!(!replies.is_empty(), "q=1 silences only success");
        let (_, replies) = run(&mut files, &[&cmd("a=T,i=1,q=2,t=f", "/gone")]);
        assert!(replies.is_empty(), "q=2 silences failure too");
        let (_, replies) = run(&mut files, &[&cmd("a=T,t=f", "/gone")]);
        assert!(replies.is_empty(), "no id, nobody to answer");
        let (_, replies) = run(&mut files, &[&cmd("a=T,I=5,t=f", "/gone")]);
        assert_eq!(
            text(&replies),
            "\x1b_GI=5;EBADF: No such file or directory\x1b\\"
        );
    }

    #[test]
    fn only_a_command_the_phone_answers_is_claimed_with_its_ids() {
        let mut files = fake("/f", b"png");
        for keys in ["i=5", "i=5,q=1", "i=4294967296", "I=4294967296"] {
            run(&mut files, &[&cmd(&format!("a=T,t=t,{keys}"), "/f")]);
        }
        let five = Reply { id: 5, number: 0 };
        assert_eq!(
            files.claimed,
            [five, Reply::default(), Reply::default(), Reply::default()]
        );
    }

    #[test]
    fn a_command_is_placed_where_its_own_bytes_end() {
        let mut files = fake("/f", b"png");
        let (forward, _) = run(
            &mut files,
            &[&[&cmd("a=T,t=f,i=5", "/f")[..], b"tail"].concat()],
        );
        assert_eq!(files.placed, [forward.len() - b"tail".len()]);
    }

    #[test]
    fn everything_else_passes_untouched() {
        let mut files = FakeFiles::default();
        let input: &[u8] = b"plain \x1b[1mbold\x1b[m \x1b_Ga=T,t=d,i=1;AAAA\x1b\\ \
            \x1b_Gm=1;AAAA\x1b\\ \x1b_Ga=T,t=f,m=1;L3g=\x1b\\ \x1b_Ga=d\x1b\\ \
            \x1b_title\x1b\\ \x1b_Gt=f,i=x;L3g=\x1b\\ \x1b_Gt=f;L3\x18g= \x1b\x1b_Gt \x1b";
        let (forward, replies) = run(&mut files, &[input]);
        assert_eq!(forward, input);
        assert!(replies.is_empty());
        assert!(files.asked.is_empty());
    }

    #[test]
    fn a_command_past_the_cap_passes_untouched() {
        let mut files = FakeFiles::default();
        let mut input = b"\x1b_Ga=T,t=f;".to_vec();
        input.extend(vec![b'A'; MAX_COMMAND * 2]);
        input.extend_from_slice(b"\x1b\\after");
        let (forward, replies) = run(&mut files, &[&input]);
        assert_eq!(forward, input);
        assert!(replies.is_empty());
        assert!(files.asked.is_empty());
        let bytes: Vec<&[u8]> = input.chunks(1).collect();
        assert_eq!(run(&mut files, &bytes), (forward, replies));

        let mut input = b"\x1b_Ga=T,t=f,x=".to_vec();
        input.resize(MAX_COMMAND, b'a');
        input.extend_from_slice(b";AAAA\x1b\\after");
        let (forward, replies) = run(&mut files, &[&input]);
        assert_eq!(
            forward, input,
            "keys filling the cap leave no room for a payload"
        );
        assert!(replies.is_empty());
        let bytes: Vec<&[u8]> = input.chunks(1).collect();
        assert_eq!(run(&mut files, &bytes), (forward, replies));
        assert!(files.asked.is_empty());
    }

    #[test]
    fn every_split_gives_what_the_whole_gives() {
        let mut stream = b"one\x1b[0m".to_vec();
        stream.extend(cmd("a=T,i=1,t=f,f=24,s=1,v=1", "/here"));
        stream.extend_from_slice(b"two\x1b_Ga=p,i=1\x1b\\");
        stream.extend(cmd("a=q,i=2,t=f", "/gone"));
        stream.extend_from_slice(b"\x1b\x1b_Gthree");
        let whole = run(&mut fake("/here", &[1, 2, 3]), &[&stream]);
        assert!(text(&whole.0).contains("t=d"), "{:?}", text(&whole.0));
        assert!(!whole.1.is_empty());
        for split in 0..=stream.len() {
            let (a, b) = stream.split_at(split);
            assert_eq!(
                run(&mut fake("/here", &[1, 2, 3]), &[a, b]),
                whole,
                "{split}"
            );
        }
        let bytes: Vec<&[u8]> = stream.chunks(1).collect();
        assert_eq!(run(&mut fake("/here", &[1, 2, 3]), &bytes), whole);
    }

    fn scratch(name: &str) -> PathBuf {
        testing::scratch("kitty-medium", name)
    }

    fn span(offset: u64, size: Option<u64>) -> Span {
        Span {
            offset,
            size,
            limit: IMAGE_BYTES,
        }
    }

    #[test]
    fn the_host_reads_a_span_of_a_regular_file() {
        let dir = scratch("span");
        let path = dir.join("image");
        fs::write(&path, b"0123456789").unwrap();
        let mut host = HostFiles::default();
        assert_eq!(
            host.read(Medium::File, &path, span(2, Some(3)), Reply::default())
                .unwrap(),
            b"234"
        );
        assert_eq!(
            host.read(Medium::File, &path, span(8, None), Reply::default())
                .unwrap(),
            b"89"
        );
        assert!(host
            .read(Medium::File, &path, span(8, Some(3)), Reply::default())
            .is_err());
        assert!(host
            .read(Medium::File, &path, span(11, None), Reply::default())
            .is_err());
        let limited = Span {
            limit: 4,
            ..span(0, None)
        };
        assert_eq!(
            host.read(Medium::File, &path, limited, Reply::default())
                .unwrap_err()
                .code,
            "EFBIG"
        );
        let asked = Span {
            limit: 4,
            ..span(0, Some(5))
        };
        assert_eq!(
            host.read(Medium::File, &path, asked, Reply::default())
                .unwrap_err()
                .code,
            "EFBIG"
        );
        assert_eq!(
            host.read(Medium::File, &path, span(8, Some(3)), Reply::default())
                .unwrap_err()
                .code,
            "EBADF"
        );
        assert!(host
            .read(Medium::File, &dir, span(0, None), Reply::default())
            .is_err());
        assert!(host
            .read(
                Medium::File,
                Path::new("/proc/self/status"),
                span(0, None),
                Reply::default()
            )
            .is_err());
        assert!(path.exists(), "a plain file is left alone");
        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_temporary_file_must_be_in_a_temporary_dir_and_named_so() {
        let temp = scratch("temp");
        let elsewhere = scratch("elsewhere");
        let mut host = HostFiles {
            temp_dirs: vec![fs::canonicalize(&temp).unwrap()],
            claims: Claims::default(),
        };
        let outside = elsewhere.join("tty-graphics-protocol-1");
        fs::write(&outside, b"x").unwrap();
        let refused = host.read(
            Medium::TemporaryFile,
            &outside,
            span(0, None),
            Reply::default(),
        );
        assert!(refused
            .unwrap_err()
            .reason
            .contains("not in a temporary directory"));
        assert!(outside.exists(), "a refused file is not deleted");

        let unnamed = temp.join("thumb.png");
        fs::write(&unnamed, b"x").unwrap();
        assert!(host
            .read(
                Medium::TemporaryFile,
                &unnamed,
                span(0, None),
                Reply::default()
            )
            .is_err());
        assert!(unnamed.exists());

        let named = temp.join("tty-graphics-protocol-2");
        fs::write(&named, b"pixels").unwrap();
        let reply = Reply { id: 7, number: 0 };
        let read = host.read(Medium::TemporaryFile, &named, span(0, None), reply);
        assert_eq!(read.unwrap(), b"pixels");
        assert!(named.exists(), "another terminal may still read it");
        let mut out = Vec::new();
        host.claims.answer(b"\x1b_Gi=7;OK\x1b\\", &mut out, Instant::now());
        assert_eq!(out, b"\x1b_Gi=7;OK\x1b\\");
        assert!(
            !named.exists(),
            "nobody else took it, so it goes with the answer"
        );

        let oversized = temp.join("tty-graphics-protocol-3");
        fs::write(&oversized, b"pixels").unwrap();
        let cramped = Span {
            offset: 0,
            size: None,
            limit: 2,
        };
        assert!(host
            .read(Medium::TemporaryFile, &oversized, cramped, reply)
            .is_err());
        assert!(
            oversized.exists(),
            "another terminal may still read it whole"
        );
        let mut out = Vec::new();
        host.claims.answer(b"\x1b_Gi=7;OK\x1b\\", &mut out, Instant::now());
        assert!(
            oversized.exists(),
            "no answer comes for a read that failed here"
        );
        host.claims.expire(host.claims.deadline().unwrap());
        assert!(!oversized.exists());
        fs::remove_dir_all(&temp).unwrap();
        fs::remove_dir_all(&elsewhere).unwrap();
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn shared_memory_is_read_and_unlinked_once_settled() {
        let name = format!(
            "upgrade-kitty-medium-{}-{}",
            std::process::id(),
            now_millis()
        );
        let path = Path::new("/dev/shm").join(&name);
        fs::write(&path, b"rgbrgb").unwrap();
        let mut host = HostFiles::default();
        let shm = PathBuf::from(format!("/{name}"));
        assert_eq!(
            host.read(
                Medium::SharedMemory,
                &shm,
                span(0, Some(3)),
                Reply::default()
            )
            .unwrap(),
            b"rgb"
        );
        drop(host.claims);
        assert!(!path.exists());

        let target = scratch("shm-target").join("thesis.tex");
        fs::write(&target, b"words").unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        let mut host = HostFiles::default();
        assert!(host
            .read(Medium::SharedMemory, &shm, span(0, None), Reply::default())
            .is_err());
        drop(host.claims);
        fs::remove_file(&path).unwrap();
        assert_eq!(
            fs::read(&target).unwrap(),
            b"words",
            "a link is not followed out of /dev/shm"
        );
        fs::remove_dir_all(target.parent().unwrap()).unwrap();

        let mut host = HostFiles::default();
        let climbing = Path::new("/../tmp/x");
        assert!(host
            .read(
                Medium::SharedMemory,
                climbing,
                span(0, None),
                Reply::default()
            )
            .is_err());
    }
}
