use super::wire::{ClientPacket, Size, NO_TIMESTAMP};
use crate::util::now_millis;
use std::fs;
use std::path::PathBuf;

pub fn scratch(prefix: &str, name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "striked-{prefix}-{name}-{}-{}",
        std::process::id(),
        now_millis()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}

pub fn client_packet(ack: u64) -> ClientPacket {
    ClientPacket {
        close: false,
        timestamp: NO_TIMESTAMP,
        timestamp_reply: NO_TIMESTAMP,
        ack,
        keyframe: 0,
        size_gen: 0,
        size: Size::default(),
        input: None,
    }
}
