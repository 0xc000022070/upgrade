use super::wire::{ClientPacket, ServerPacket, Session, KEY_LEN, TO_CLIENT};
use std::io;
use std::net::{SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};

const DATAGRAM: usize = 2048;

pub struct Endpoint {
    socket: UdpSocket,
    session: Session,
    sent: u64,
    highest: Option<u64>,
    peer: Option<SocketAddr>,
}

impl Endpoint {
    pub fn new(socket: UdpSocket, key: &[u8; KEY_LEN]) -> io::Result<Self> {
        socket.set_nonblocking(true)?;
        Ok(Self {
            socket,
            session: Session::new(key),
            sent: 0,
            highest: None,
            peer: None,
        })
    }

    pub fn fd(&self) -> RawFd {
        self.socket.as_raw_fd()
    }

    pub fn port(&self) -> io::Result<u16> {
        Ok(self.socket.local_addr()?.port())
    }

    pub fn rekey(&mut self, key: &[u8; KEY_LEN]) {
        self.session = Session::new(key);
        self.sent = 0;
        self.highest = None;
        self.peer = None;
    }

    pub fn receive(&mut self) -> io::Result<Option<ClientPacket>> {
        let mut buf = [0u8; DATAGRAM];
        loop {
            let (len, from) = match self.socket.recv_from(&mut buf) {
                Ok(received) => received,
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => return Ok(None),
                Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
                Err(err) if err.kind() == io::ErrorKind::ConnectionRefused => continue,
                Err(err) => return Err(err),
            };
            let Ok((nonce, plaintext)) = self.session.open(&buf[..len]) else {
                continue;
            };
            if nonce & TO_CLIENT != 0 || self.highest.is_some_and(|highest| nonce <= highest) {
                continue;
            }
            let Some(packet) = ClientPacket::decode(&plaintext) else {
                continue;
            };
            self.highest = Some(nonce);
            self.peer = Some(from);
            return Ok(Some(packet));
        }
    }

    pub fn send(&mut self, packet: &ServerPacket) -> io::Result<()> {
        let Some(peer) = self.peer else {
            return Ok(());
        };
        let datagram = self.session.seal(TO_CLIENT | self.sent, &packet.encode());
        self.sent += 1;
        self.socket.send_to(&datagram, peer).map(drop)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::testing::client_packet;
    use crate::shell::wire::NO_TIMESTAMP;

    fn pair(key: &[u8; KEY_LEN]) -> (Endpoint, UdpSocket) {
        let server = UdpSocket::bind("127.0.0.1:0").unwrap();
        let client = UdpSocket::bind("127.0.0.1:0").unwrap();
        client.connect(server.local_addr().unwrap()).unwrap();
        (Endpoint::new(server, key).unwrap(), client)
    }

    fn drain(endpoint: &mut Endpoint) -> Vec<u64> {
        std::thread::sleep(std::time::Duration::from_millis(20));
        std::iter::from_fn(|| endpoint.receive().unwrap())
            .map(|p| p.ack)
            .collect()
    }

    #[test]
    fn replays_forgeries_and_the_wrong_direction_are_dropped() {
        let key = [3; KEY_LEN];
        let (mut endpoint, client) = pair(&key);
        let session = Session::new(&key);
        let first = session.seal(5, &client_packet(1).encode());
        client.send(&first).unwrap();
        client.send(&first).unwrap();
        client
            .send(&session.seal(4, &client_packet(2).encode()))
            .unwrap();
        client
            .send(&session.seal(TO_CLIENT | 9, &client_packet(3).encode()))
            .unwrap();
        client
            .send(&Session::new(&[4; KEY_LEN]).seal(6, &client_packet(4).encode()))
            .unwrap();
        client
            .send(&session.seal(6, &client_packet(5).encode()))
            .unwrap();
        assert_eq!(drain(&mut endpoint), vec![1, 5]);
    }

    #[test]
    fn replies_go_to_the_last_address_heard_and_a_rekey_starts_over() {
        let key = [3; KEY_LEN];
        let (mut endpoint, client) = pair(&key);
        let session = Session::new(&key);
        client
            .send(&session.seal(0, &client_packet(0).encode()))
            .unwrap();
        drain(&mut endpoint);
        let reply = ServerPacket {
            jump: false,
            timestamp: 0,
            timestamp_reply: NO_TIMESTAMP,
            input_ack: 0,
            size_gen: 0,
            stream_end: 0,
            data: None,
        };
        endpoint.send(&reply).unwrap();
        let mut buf = [0u8; DATAGRAM];
        let len = client.recv(&mut buf).unwrap();
        assert_eq!(session.open(&buf[..len]).unwrap().0, TO_CLIENT);

        let fresh = [9; KEY_LEN];
        endpoint.rekey(&fresh);
        client
            .send(&session.seal(1, &client_packet(7).encode()))
            .unwrap();
        assert!(drain(&mut endpoint).is_empty());
        client
            .send(&Session::new(&fresh).seal(0, &client_packet(8).encode()))
            .unwrap();
        assert_eq!(drain(&mut endpoint), vec![8]);
    }
}
