use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use base64::Engine as _;
use bytes::Bytes;
use serde_json::{json, Value};
use tokio::net::UdpSocket;
use tokio::runtime::Runtime;
use tokio::task::AbortHandle;

const ALPN: &[u8] = b"upgraded/1";
const SERVER_NAME: &str = "upgraded";
const ATTACH: u8 = b'S';
const RPC: u8 = b'R';
const UNRUN: u32 = 2;
const MAX_ANSWER: usize = 16 * 1024 * 1024;
const CONNECT: Duration = Duration::from_secs(3);
const MTU: u16 = 1232;
const IDLE: Duration = Duration::from_secs(60);

type Callback = extern "C" fn(*mut c_char);
type Fallible<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static LINKS: tokio::sync::Mutex<Option<HashMap<String, Arc<Link>>>> =
    tokio::sync::Mutex::const_new(None);
static TABS: Mutex<Option<HashMap<String, AbortHandle>>> = Mutex::new(None);

fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| Runtime::new().expect("tokio runtime"))
}

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

struct Link {
    pin: (Vec<u8>, Vec<u8>),
    _endpoint: quinn::Endpoint,
    connection: quinn::Connection,
    relays: Arc<Mutex<HashMap<u8, Arc<Relay>>>>,
}

struct Relay {
    socket: UdpSocket,
    peer: Mutex<Option<SocketAddr>>,
}

struct Release {
    relays: Arc<Mutex<HashMap<u8, Arc<Relay>>>>,
    channel: u8,
    relay: Arc<Relay>,
}

impl Drop for Release {
    fn drop(&mut self) {
        let mut relays = lock(&self.relays);
        if relays
            .get(&self.channel)
            .is_some_and(|held| Arc::ptr_eq(held, &self.relay))
        {
            relays.remove(&self.channel);
        }
    }
}

fn transport() -> quinn::TransportConfig {
    let mut transport = quinn::TransportConfig::default();
    transport.initial_mtu(MTU);
    transport.min_mtu(MTU);
    transport.max_idle_timeout(IDLE.try_into().ok());
    transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
    let mut ack = quinn::AckFrequencyConfig::default();
    ack.max_ack_delay(Some(Duration::ZERO));
    transport.ack_frequency_config(Some(ack));
    transport
}

async fn connect(host: &str, port: u16, cert: &[u8], token: &[u8]) -> Fallible<Link> {
    let address = tokio::net::lookup_host((host, port))
        .await?
        .next()
        .ok_or("the host has no address")?;
    let mut roots = rustls::RootCertStore::empty();
    roots.add(rustls::pki_types::CertificateDer::from(cert.to_vec()))?;
    let mut tls = rustls::ClientConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_protocol_versions(&[&rustls::version::TLS13])?
    .with_root_certificates(roots)
    .with_no_client_auth();
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut config = quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(tls)?,
    ));
    config.transport_config(Arc::new(transport()));
    let any: SocketAddr = if address.is_ipv6() {
        (Ipv6Addr::UNSPECIFIED, 0).into()
    } else {
        (Ipv4Addr::UNSPECIFIED, 0).into()
    };
    let endpoint = quinn::Endpoint::client(any)?;
    let connection = endpoint.connect_with(config, address, SERVER_NAME)?.await?;
    let (mut send, mut recv) = connection.open_bi().await?;
    send.write_all(token).await?;
    send.finish()?;
    let mut ok = [0u8; 1];
    recv.read_exact(&mut ok).await?;
    if ok != [1] {
        return Err("the daemon refused the token".into());
    }
    let relays = Arc::<Mutex<HashMap<u8, Arc<Relay>>>>::default();
    tokio::spawn(inbound(connection.clone(), relays.clone()));
    Ok(Link {
        pin: (cert.to_vec(), token.to_vec()),
        _endpoint: endpoint,
        connection,
        relays,
    })
}

async fn inbound(connection: quinn::Connection, relays: Arc<Mutex<HashMap<u8, Arc<Relay>>>>) {
    while let Ok(datagram) = connection.read_datagram().await {
        let Some((channel, packet)) = datagram.split_first() else {
            continue;
        };
        let Some(relay) = lock(&relays).get(channel).cloned() else {
            continue;
        };
        let peer = *lock(&relay.peer);
        if let Some(peer) = peer {
            let _ = relay.socket.send_to(packet, peer).await;
        }
    }
}

async fn link(host: &str, port: u16, cert: &[u8], token: &[u8]) -> Fallible<Arc<Link>> {
    let mut links = LINKS.lock().await;
    let links = links.get_or_insert_with(HashMap::new);
    let key = format!("{host}:{port}");
    if let Some(link) = links.get(&key) {
        if link.connection.close_reason().is_none() && link.pin == (cert.to_vec(), token.to_vec()) {
            return Ok(link.clone());
        }
    }
    let link = Arc::new(tokio::time::timeout(CONNECT, connect(host, port, cert, token)).await??);
    links.insert(key, link.clone());
    Ok(link)
}

struct Target {
    host: String,
    port: u16,
    cert: Vec<u8>,
    token: Vec<u8>,
}

type Attached = (u8, quinn::SendStream, quinn::RecvStream);

async fn open(link: &Link, tab: &str) -> Fallible<Option<Attached>> {
    let name = u8::try_from(tab.len())
        .ok()
        .filter(|len| *len > 0)
        .ok_or("the tab name does not fit")?;
    let (mut send, mut recv) = link.connection.open_bi().await?;
    let mut head = vec![ATTACH, name];
    head.extend_from_slice(tab.as_bytes());
    send.write_all(&head).await?;
    let mut answer = [0u8; 1];
    recv.read_exact(&mut answer).await?;
    if answer != [1] {
        return Ok(None);
    }
    recv.read_exact(&mut answer).await?;
    Ok(Some((answer[0], send, recv)))
}

async fn relink(target: &Target, tab: &str) -> Fallible<Option<(Arc<Link>, Attached)>> {
    let link = link(&target.host, target.port, &target.cert, &target.token).await?;
    Ok(open(&link, tab).await?.map(|attached| (link, attached)))
}

async fn attach(target: Target, link: Arc<Link>, tab: &str) -> Fallible<u16> {
    let attached = open(&link, tab)
        .await?
        .ok_or("the daemon has no server for this tab")?;
    let relay = Arc::new(Relay {
        socket: UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await?,
        peer: Mutex::new(None),
    });
    let port = relay.socket.local_addr()?.port();
    let task = tokio::spawn(forward(target, tab.to_owned(), relay, link, attached));
    if let Some(earlier) = lock(&TABS)
        .get_or_insert_with(HashMap::new)
        .insert(tab.to_owned(), task.abort_handle())
    {
        earlier.abort();
    }
    Ok(port)
}

/// Keeps the loopback port across links: a link that died, say idled out while the app was
/// away, is redialed on the next packet the tab sends and the tab attached again.
async fn forward(
    target: Target,
    tab: String,
    relay: Arc<Relay>,
    link: Arc<Link>,
    attached: Attached,
) {
    let mut buf = vec![0u8; 2048];
    let mut current = (link, attached);
    loop {
        let mut unsent = carry(&relay, current.0, current.1, &mut buf).await;
        current = loop {
            let n = match unsent.take() {
                Some(n) => n,
                None => match relay.socket.recv_from(&mut buf[1..]).await {
                    Ok((n, from)) => {
                        *lock(&relay.peer) = Some(from);
                        n
                    }
                    Err(_) => return,
                },
            };
            match relink(&target, &tab).await {
                Ok(Some((link, attached))) => {
                    buf[0] = attached.0;
                    let _ = link
                        .connection
                        .send_datagram(Bytes::copy_from_slice(&buf[..=n]));
                    break (link, attached);
                }
                Ok(None) => return,
                Err(_) => {}
            }
        };
    }
}

/// Answers the length of a packet the dead link refused, left in `buf`.
async fn carry(
    relay: &Arc<Relay>,
    link: Arc<Link>,
    attached: Attached,
    buf: &mut [u8],
) -> Option<usize> {
    let (channel, _send, mut recv) = attached;
    lock(&link.relays).insert(channel, relay.clone());
    let _release = Release {
        relays: link.relays.clone(),
        channel,
        relay: relay.clone(),
    };
    buf[0] = channel;
    let outbound = async {
        while let Ok((n, from)) = relay.socket.recv_from(&mut buf[1..]).await {
            *lock(&relay.peer) = Some(from);
            if link
                .connection
                .send_datagram(Bytes::copy_from_slice(&buf[..=n]))
                .is_err()
            {
                return Some(n);
            }
        }
        None
    };
    tokio::select! {
        unsent = outbound => unsent,
        _ = recv.read_to_end(0) => None,
    }
}

enum Failure {
    Unsent(String),
    Sent(String),
}

fn unsent(error: impl ToString) -> Failure {
    Failure::Unsent(error.to_string())
}

async fn call(link: &Link, body: &[u8]) -> Result<Vec<u8>, Failure> {
    let (mut send, mut recv) = link.connection.open_bi().await.map_err(unsent)?;
    send.write_all(&[RPC]).await.map_err(unsent)?;
    send.write_all(body).await.map_err(unsent)?;
    send.finish().map_err(unsent)?;
    recv.read_to_end(MAX_ANSWER)
        .await
        .map_err(|error| match error {
            quinn::ReadToEndError::Read(quinn::ReadError::Reset(code)) if code == UNRUN.into() => {
                unsent("the daemon could not run the request")
            }
            other => Failure::Sent(other.to_string()),
        })
}

enum Op {
    Attach,
    Call,
}

async fn run(op: Op, request: &str) -> Result<Value, Failure> {
    let request: Value = serde_json::from_str(request).map_err(unsent)?;
    let text = |field: &str| {
        request[field]
            .as_str()
            .ok_or_else(|| unsent(format!("{field} is missing")))
    };
    let decode = |field: &str| {
        base64::engine::general_purpose::STANDARD
            .decode(text(field)?)
            .map_err(unsent)
    };
    let port = request["port"]
        .as_u64()
        .and_then(|port| u16::try_from(port).ok())
        .ok_or_else(|| unsent("port is missing"))?;
    let target = Target {
        host: text("host")?.to_owned(),
        port,
        cert: decode("cert")?,
        token: decode("token")?,
    };
    let link = link(&target.host, port, &target.cert, &target.token)
        .await
        .map_err(unsent)?;
    match op {
        Op::Attach => match attach(target, link, text("tab")?).await {
            Ok(port) => Ok(json!(port)),
            Err(error) => Err(Failure::Sent(error.to_string())),
        },
        Op::Call => {
            let answer = call(&link, text("body")?.as_bytes()).await?;
            Ok(json!(String::from_utf8_lossy(&answer)))
        }
    }
}

/// Each call names its own callback: an isolate's listener is reachable only from the
/// callback it made, and the app calls from more than one isolate.
fn spawn(op: Op, id: i64, request: *const c_char, callback: Callback) {
    // SAFETY: the caller hands a NUL-terminated string that outlives this call.
    let request = unsafe { CStr::from_ptr(request) }
        .to_string_lossy()
        .into_owned();
    runtime().spawn(async move {
        let reply = match run(op, &request).await {
            Ok(value) => json!({"reply": id, "ok": value}),
            Err(Failure::Unsent(error)) => json!({"reply": id, "error": error, "sent": false}),
            Err(Failure::Sent(error)) => json!({"reply": id, "error": error, "sent": true}),
        };
        if let Ok(text) = CString::new(reply.to_string()) {
            callback(text.into_raw());
        }
    });
}

/// # Safety
/// `request` is a NUL-terminated JSON string that outlives the call.
#[no_mangle]
pub unsafe extern "C" fn upgrade_quic_attach(id: i64, request: *const c_char, callback: Callback) {
    spawn(Op::Attach, id, request, callback);
}

/// # Safety
/// `request` is a NUL-terminated JSON string that outlives the call.
#[no_mangle]
pub unsafe extern "C" fn upgrade_quic_call(id: i64, request: *const c_char, callback: Callback) {
    spawn(Op::Call, id, request, callback);
}

/// # Safety
/// `text` came from a callback and is freed once.
#[no_mangle]
pub unsafe extern "C" fn upgrade_quic_free(text: *mut c_char) {
    drop(CString::from_raw(text));
}

#[cfg(test)]
mod tests {
    use super::*;

    const TOKEN: [u8; 32] = [9; 32];

    fn target(port: u16, cert: &[u8]) -> Target {
        Target {
            host: "127.0.0.1".to_owned(),
            port,
            cert: cert.to_vec(),
            token: TOKEN.to_vec(),
        }
    }

    async fn echoed(client: &UdpSocket, relay: u16, packet: &[u8]) -> Vec<u8> {
        client
            .send_to(packet, (Ipv4Addr::LOCALHOST, relay))
            .await
            .unwrap();
        let mut buf = [0u8; 2048];
        let (n, from) = tokio::time::timeout(Duration::from_secs(5), client.recv_from(&mut buf))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(from.port(), relay);
        buf[..n].to_vec()
    }

    async fn daemon() -> (u16, Vec<u8>) {
        let key = rcgen::generate_simple_self_signed(vec![SERVER_NAME.to_owned()]).unwrap();
        let cert = key.cert.der().to_vec();
        let mut tls = rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::ring::default_provider(),
        ))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(
            vec![key.cert.der().clone()],
            rustls::pki_types::PrivatePkcs8KeyDer::from(key.key_pair.serialize_der()).into(),
        )
        .unwrap();
        tls.alpn_protocols = vec![ALPN.to_vec()];
        let mut config = quinn::ServerConfig::with_crypto(Arc::new(
            quinn::crypto::rustls::QuicServerConfig::try_from(tls).unwrap(),
        ));
        config.transport_config(Arc::new(transport()));
        let endpoint = quinn::Endpoint::server(config, (Ipv4Addr::LOCALHOST, 0).into()).unwrap();
        let port = endpoint.local_addr().unwrap().port();
        tokio::spawn(async move {
            while let Some(incoming) = endpoint.accept().await {
                let connection = incoming.await.unwrap();
                let (mut send, mut recv) = connection.accept_bi().await.unwrap();
                let mut token = [0u8; 32];
                recv.read_exact(&mut token).await.unwrap();
                if token != TOKEN {
                    connection.close(1u32.into(), b"token");
                    continue;
                }
                send.write_all(&[1]).await.unwrap();
                send.finish().unwrap();
                let echo = connection.clone();
                tokio::spawn(async move {
                    while let Ok(datagram) = echo.read_datagram().await {
                        let _ = echo.send_datagram(datagram);
                    }
                });
                while let Ok((send, recv)) = connection.accept_bi().await {
                    serve(send, recv).await;
                }
            }
        });
        (port, cert)
    }

    async fn serve(mut send: quinn::SendStream, mut recv: quinn::RecvStream) {
        let mut head = [0u8; 2];
        recv.read_exact(&mut head[..1]).await.unwrap();
        if head[0] == RPC {
            let body = recv.read_to_end(1024).await.unwrap();
            if body == b"unrunnable" {
                let _ = send.reset(UNRUN.into());
                return;
            }
            send.write_all(b"ran ").await.unwrap();
            send.write_all(&body).await.unwrap();
            send.finish().unwrap();
            return;
        }
        recv.read_exact(&mut head[1..]).await.unwrap();
        let mut tab = vec![0u8; usize::from(head[1])];
        recv.read_exact(&mut tab).await.unwrap();
        let reply: &[u8] = if tab == b"gone" { &[0] } else { &[1, 7] };
        send.write_all(reply).await.unwrap();
        tokio::spawn(async move {
            let _ = recv.read_to_end(0).await;
            drop(send);
        });
    }

    #[tokio::test]
    async fn a_full_packet_crosses_the_relay_and_comes_back_whole() {
        let (port, cert) = daemon().await;
        let link = link("127.0.0.1", port, &cert, &TOKEN).await.unwrap();
        let relay = attach(target(port, &cert), link, "tab-1").await.unwrap();
        let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let packet: Vec<u8> = (0..8 + 1160 + 16).map(|i| i as u8).collect();
        assert_eq!(echoed(&client, relay, &packet).await, packet);
    }

    #[tokio::test]
    async fn a_relay_outlives_its_link_and_attaches_again_on_the_next_packet() {
        let (port, cert) = daemon().await;
        let first = link("127.0.0.1", port, &cert, &TOKEN).await.unwrap();
        let relay = attach(target(port, &cert), first.clone(), "tab-2")
            .await
            .unwrap();
        let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        assert_eq!(echoed(&client, relay, b"before").await, b"before");
        first.connection.close(0u32.into(), b"idle");
        assert_eq!(echoed(&client, relay, b"after").await, b"after");
        let second = link("127.0.0.1", port, &cert, &TOKEN).await.unwrap();
        assert!(!Arc::ptr_eq(&first, &second));
    }

    #[tokio::test]
    async fn a_wrong_token_or_a_tab_without_a_server_is_an_error() {
        let (port, cert) = daemon().await;
        assert!(connect("127.0.0.1", port, &cert, &[0; 32]).await.is_err());
        let link = link("127.0.0.1", port, &cert, &TOKEN).await.unwrap();
        assert!(attach(target(port, &cert), link, "gone").await.is_err());
    }

    #[tokio::test]
    async fn a_call_is_answered_and_one_the_daemon_could_not_run_is_unsent() {
        let (port, cert) = daemon().await;
        let link = link("127.0.0.1", port, &cert, &TOKEN).await.unwrap();
        assert_eq!(call(&link, b"{}").await.ok(), Some(b"ran {}".to_vec()));
        assert!(matches!(
            call(&link, b"unrunnable").await,
            Err(Failure::Unsent(_))
        ));
        link.connection.close(0u32.into(), b"gone");
        assert!(matches!(call(&link, b"{}").await, Err(Failure::Unsent(_))));
    }
}
