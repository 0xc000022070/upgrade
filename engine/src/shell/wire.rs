use aes::Aes128;
use ocb3::aead::{Aead, KeyInit};
use ocb3::Ocb3;

pub const VERSION: u8 = 1;
pub const KEY_LEN: usize = 16;
pub const NONCE_LEN: usize = 8;
pub const TAG_LEN: usize = 16;
pub const MAX_PLAINTEXT: usize = 1200;
// Mosh sets bit 63 on server nonces, so a phone that speaks Mosh opens these unchanged.
pub const TO_CLIENT: u64 = 1 << 63;
pub const NO_TIMESTAMP: u16 = 0xffff;

pub const CLIENT_INPUT: u8 = 1 << 0;
pub const CLIENT_CLOSE: u8 = 1 << 1;
pub const SERVER_DATA: u8 = 1 << 0;
pub const SERVER_JUMP: u8 = 1 << 1;

pub const RECORD_PTY: u8 = 1;
pub const RECORD_SNAPSHOT: u8 = 2;
pub const RECORD_EXIT: u8 = 3;
pub const RECORD_FOREGROUND: u8 = 4;
pub const RECORD_HEADER: usize = 5;

#[cfg(test)]
pub const CLIENT_HEADER: usize = 1 + 1 + 2 + 2 + 8 + 4 + 4 + 2 * 4;
pub const SERVER_HEADER: usize = 1 + 1 + 2 + 2 + 8 + 4 + 8;
pub const SERVER_MAX_DATA: usize = MAX_PLAINTEXT - SERVER_HEADER - 8;

type Cipher = Ocb3<Aes128, ocb3::consts::U12, ocb3::consts::U16>;

pub struct Session {
    cipher: Cipher,
}

#[derive(Debug, PartialEq, Eq)]
pub enum OpenError {
    Short,
    Forged,
}

impl Session {
    pub fn new(key: &[u8; KEY_LEN]) -> Self {
        Self {
            cipher: Cipher::new(key.into()),
        }
    }

    pub fn seal(&self, nonce: u64, plaintext: &[u8]) -> Vec<u8> {
        let wire = nonce.to_be_bytes();
        let sealed = self
            .cipher
            .encrypt(&aead_nonce(&wire).into(), plaintext)
            .expect("OCB sealing has no failure mode for in-range lengths");
        let mut packet = Vec::with_capacity(NONCE_LEN + sealed.len());
        packet.extend_from_slice(&wire);
        packet.extend_from_slice(&sealed);
        packet
    }

    pub fn open(&self, packet: &[u8]) -> Result<(u64, Vec<u8>), OpenError> {
        if packet.len() < NONCE_LEN + TAG_LEN {
            return Err(OpenError::Short);
        }
        let wire: [u8; NONCE_LEN] = packet[..NONCE_LEN].try_into().unwrap();
        let plaintext = self
            .cipher
            .decrypt(&aead_nonce(&wire).into(), &packet[NONCE_LEN..])
            .map_err(|_| OpenError::Forged)?;
        Ok((u64::from_be_bytes(wire), plaintext))
    }
}

fn aead_nonce(wire: &[u8; NONCE_LEN]) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[4..].copy_from_slice(wire);
    nonce
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Size {
    pub cols: u16,
    pub rows: u16,
    pub width_px: u16,
    pub height_px: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientPacket {
    pub close: bool,
    pub timestamp: u16,
    pub timestamp_reply: u16,
    pub ack: u64,
    pub keyframe: u32,
    pub size_gen: u32,
    pub size: Size,
    pub input: Option<(u64, Vec<u8>)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerPacket {
    pub jump: bool,
    pub timestamp: u16,
    pub timestamp_reply: u16,
    pub input_ack: u64,
    pub size_gen: u32,
    pub stream_end: u64,
    pub data: Option<(u64, Vec<u8>)>,
}

struct Reader<'a> {
    bytes: &'a [u8],
}

impl<'a> Reader<'a> {
    fn take<const N: usize>(&mut self) -> Option<[u8; N]> {
        let (head, rest) = self.bytes.split_at_checked(N)?;
        self.bytes = rest;
        head.try_into().ok()
    }
    fn u8(&mut self) -> Option<u8> {
        self.take::<1>().map(|b| b[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take().map(u16::from_be_bytes)
    }
    fn u32(&mut self) -> Option<u32> {
        self.take().map(u32::from_be_bytes)
    }
    fn u64(&mut self) -> Option<u64> {
        self.take().map(u64::from_be_bytes)
    }
}

impl ClientPacket {
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let mut r = Reader { bytes };
        if r.u8()? != VERSION {
            return None;
        }
        let flags = r.u8()?;
        let mut packet = Self {
            close: flags & CLIENT_CLOSE != 0,
            timestamp: r.u16()?,
            timestamp_reply: r.u16()?,
            ack: r.u64()?,
            keyframe: r.u32()?,
            size_gen: r.u32()?,
            size: Size {
                cols: r.u16()?,
                rows: r.u16()?,
                width_px: r.u16()?,
                height_px: r.u16()?,
            },
            input: None,
        };
        if flags & CLIENT_INPUT != 0 {
            let offset = r.u64()?;
            packet.input = Some((offset, r.bytes.to_vec()));
        }
        Some(packet)
    }

    #[cfg(test)]
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(CLIENT_HEADER + 8);
        let flags = if self.input.is_some() {
            CLIENT_INPUT
        } else {
            0
        } | if self.close { CLIENT_CLOSE } else { 0 };
        out.extend_from_slice(&[VERSION, flags]);
        out.extend_from_slice(&self.timestamp.to_be_bytes());
        out.extend_from_slice(&self.timestamp_reply.to_be_bytes());
        out.extend_from_slice(&self.ack.to_be_bytes());
        out.extend_from_slice(&self.keyframe.to_be_bytes());
        out.extend_from_slice(&self.size_gen.to_be_bytes());
        for field in [
            self.size.cols,
            self.size.rows,
            self.size.width_px,
            self.size.height_px,
        ] {
            out.extend_from_slice(&field.to_be_bytes());
        }
        if let Some((offset, bytes)) = &self.input {
            out.extend_from_slice(&offset.to_be_bytes());
            out.extend_from_slice(bytes);
        }
        out
    }
}

impl ServerPacket {
    #[cfg(test)]
    pub fn decode(bytes: &[u8]) -> Option<Self> {
        let mut r = Reader { bytes };
        if r.u8()? != VERSION {
            return None;
        }
        let flags = r.u8()?;
        let mut packet = Self {
            jump: flags & SERVER_JUMP != 0,
            timestamp: r.u16()?,
            timestamp_reply: r.u16()?,
            input_ack: r.u64()?,
            size_gen: r.u32()?,
            stream_end: r.u64()?,
            data: None,
        };
        if flags & SERVER_DATA != 0 {
            let offset = r.u64()?;
            packet.data = Some((offset, r.bytes.to_vec()));
        }
        Some(packet)
    }

    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(MAX_PLAINTEXT);
        let flags = if self.data.is_some() { SERVER_DATA } else { 0 }
            | if self.jump { SERVER_JUMP } else { 0 };
        out.extend_from_slice(&[VERSION, flags]);
        out.extend_from_slice(&self.timestamp.to_be_bytes());
        out.extend_from_slice(&self.timestamp_reply.to_be_bytes());
        out.extend_from_slice(&self.input_ack.to_be_bytes());
        out.extend_from_slice(&self.size_gen.to_be_bytes());
        out.extend_from_slice(&self.stream_end.to_be_bytes());
        if let Some((offset, bytes)) = &self.data {
            out.extend_from_slice(&offset.to_be_bytes());
            out.extend_from_slice(bytes);
        }
        out
    }
}

pub fn record(kind: u8, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(RECORD_HEADER + body.len());
    out.push(kind);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(body);
    out
}

pub fn printable_key(key: &[u8; KEY_LEN]) -> String {
    crate::util::base64_encode(key)
        .trim_end_matches('=')
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_sealed_packet_opens_and_a_flipped_bit_does_not() {
        let session = Session::new(&[7; KEY_LEN]);
        let mut packet = session.seal(TO_CLIENT | 5, b"hello");
        assert_eq!(&packet[..8], &(TO_CLIENT | 5).to_be_bytes());
        assert_eq!(
            session.open(&packet),
            Ok((TO_CLIENT | 5, b"hello".to_vec()))
        );
        let last = packet.len() - 1;
        packet[last] ^= 1;
        assert_eq!(session.open(&packet), Err(OpenError::Forged));
    }

    #[test]
    fn the_cipher_is_rfc7253_ocb() {
        let key: [u8; 16] = std::array::from_fn(|i| i as u8);
        let cipher = Cipher::new(&key.into());
        let nonce = [
            0xbb, 0xaa, 0x99, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11, 0x00,
        ];
        let sealed = cipher.encrypt(&nonce.into(), &[][..]).unwrap();
        assert_eq!(
            sealed,
            [
                0x78, 0x54, 0x07, 0xbf, 0xff, 0xc8, 0xad, 0x9e, 0xdc, 0xc5, 0x52, 0x0a, 0xc9, 0x11,
                0x1e, 0xe6
            ]
        );
    }

    #[test]
    fn packets_round_trip() {
        let client = ClientPacket {
            close: false,
            timestamp: 1,
            timestamp_reply: NO_TIMESTAMP,
            ack: 9,
            keyframe: 2,
            size_gen: 3,
            size: Size {
                cols: 80,
                rows: 24,
                width_px: 800,
                height_px: 480,
            },
            input: Some((4, b"ls\r".to_vec())),
        };
        assert_eq!(ClientPacket::decode(&client.encode()), Some(client));
        let server = ServerPacket {
            jump: true,
            timestamp: 5,
            timestamp_reply: 6,
            input_ack: 7,
            size_gen: 3,
            stream_end: 100,
            data: Some((90, vec![1, 2, 3])),
        };
        assert_eq!(ServerPacket::decode(&server.encode()), Some(server));
    }

    #[test]
    fn a_key_prints_as_mosh_prints_one() {
        assert_eq!(printable_key(&[0; KEY_LEN]), "AAAAAAAAAAAAAAAAAAAAAA");
    }
}
