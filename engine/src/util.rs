use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn warn(line: impl std::fmt::Display) {
    let _ = writeln!(io::stderr(), "{line}");
}

pub fn say(line: impl std::fmt::Display) {
    let _ = writeln!(io::stdout(), "{line}");
}

pub fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let packed = (b0 << 16) | (b1 << 8) | b2;
        out.push(ALPHABET[(packed >> 18) as usize & 63] as char);
        out.push(ALPHABET[(packed >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            ALPHABET[(packed >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            ALPHABET[packed as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

pub fn base64_decode(input: &[u8]) -> Option<Vec<u8>> {
    let input = input
        .strip_suffix(b"==")
        .or_else(|| input.strip_suffix(b"="))
        .unwrap_or(input);
    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &byte in input {
        let value = ALPHABET.iter().position(|&c| c == byte)? as u32;
        acc = (acc << 6 | value) & 0xff_ffff;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    (bits < 6).then_some(out)
}

pub fn epoch_secs(time: SystemTime) -> u64 {
    time.duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or(0)
}

pub fn now_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_millis() as u64)
        .unwrap_or(0)
}

pub enum Perms {
    Private,
    Keep,
    Default,
}

pub enum Durability {
    None,
    File,
    FileAndDir,
}

pub struct WritePolicy {
    pub perms: Perms,
    pub durability: Durability,
    pub tmp_suffix: &'static str,
}

pub const PLAIN_WRITE: WritePolicy = WritePolicy {
    perms: Perms::Default,
    durability: Durability::None,
    tmp_suffix: ".tmp",
};

/// Appended rather than substituted: two files that differ only in their extension,
/// like a timer's two units, would otherwise share one temporary name.
pub fn tmp_path(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    path.with_file_name(name)
}

pub fn write_atomic(path: &Path, bytes: &[u8], policy: &WritePolicy) -> io::Result<()> {
    write_through(path, &tmp_path(path, policy.tmp_suffix), bytes, policy)
}

pub fn write_atomic_unique(path: &Path, bytes: &[u8], policy: &WritePolicy) -> io::Result<()> {
    let suffix = format!("{}.{}", policy.tmp_suffix, std::process::id());
    write_through(path, &tmp_path(path, &suffix), bytes, policy)
}

fn write_through(path: &Path, tmp: &Path, bytes: &[u8], policy: &WritePolicy) -> io::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    if let Perms::Private = policy.perms {
        options.mode(0o600);
    }
    let mut file = options.open(tmp)?;
    match policy.perms {
        Perms::Private => fs::set_permissions(tmp, fs::Permissions::from_mode(0o600))?,
        Perms::Keep => {
            if let Ok(meta) = fs::metadata(path) {
                fs::set_permissions(tmp, meta.permissions())?;
            }
        }
        Perms::Default => {}
    }
    file.write_all(bytes)?;
    if !matches!(policy.durability, Durability::None) {
        file.sync_all()?;
    }
    drop(file);
    fs::rename(tmp, path)?;
    if let (Durability::FileAndDir, Some(dir)) = (&policy.durability, path.parent()) {
        fs::File::open(dir)?.sync_all()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{base64_decode, base64_encode};

    #[test]
    fn base64_matches_rfc_4648_vectors() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn base64_decodes_with_or_without_padding() {
        assert_eq!(base64_decode(b"").unwrap(), b"");
        assert_eq!(base64_decode(b"Zg==").unwrap(), b"f");
        assert_eq!(base64_decode(b"Zm8").unwrap(), b"fo");
        assert_eq!(base64_decode(b"Zm9vYmFy").unwrap(), b"foobar");
        assert_eq!(base64_decode(b"Z"), None);
        assert_eq!(base64_decode(b"Zm9v\n"), None);
    }
}
