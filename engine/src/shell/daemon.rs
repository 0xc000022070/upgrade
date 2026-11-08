use super::launch::{inherited, say_ready, spawn_ready, write_private};
use super::os::random_bytes;
use super::registry::{self, Record};
use crate::policy::Policy;
use crate::protocol::{EngineError, EngineResult};
use crate::util::base64_encode;
use bytes::Bytes;
use quinn::crypto::rustls::QuicServerConfig;
use rustls::pki_types::{CertificateDer, PrivatePkcs8KeyDer};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::error::Error;
use std::ffi::OsStr;
use std::fs::{self, File};
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, UdpSocket};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::AsyncWriteExt;

pub const SERVICE: &str = "daemon/1";
pub const OPS: &[&str] = &["start", "stop"];

pub const ALPN: &[u8] = b"upgraded/1";
pub const SERVER_NAME: &str = "upgraded";
pub const TOKEN_LEN: usize = 32;
pub const RPC: u8 = b'R';
pub const ATTACH: u8 = b'S';
const REFUSED: u32 = 1;
const UNRUN: u32 = 2;
const DIR: &str = "daemon";
const INITIAL_MTU: u16 = 1232;
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const IDLE: Duration = Duration::from_secs(60);

type Fallible<T = ()> = Result<T, Box<dyn Error + Send + Sync>>;
type Channels = Arc<Mutex<HashMap<u8, Arc<tokio::net::UdpSocket>>>>;

pub fn dispatch(op: &str, state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    match op {
        "start" => start(state_root, policy),
        "stop" => Ok(json!({ "stopped": stop(state_root)? })),
        _ => Err(EngineError::unsupported(format!(
            "{SERVICE} has no op {op}"
        ))),
    }
}

pub fn stop(state_root: &Path) -> std::io::Result<bool> {
    registry::stop(&state_root.join(DIR))
}

fn start(state_root: &Path, policy: &Policy) -> EngineResult<Value> {
    let Some(ports) = policy.shell_ports() else {
        return Err(EngineError::denied(
            "this host's shellPorts leave no port to listen on",
        ));
    };
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(state_root)?;
    let _starting = registry::lock_at(&state_root.join("daemon.lock"))?;
    let dir = state_root.join(DIR);
    if let Some(record) = registry::live(&dir) {
        if let Ok(answer) = answer(&dir, &record, true) {
            return Ok(answer);
        }
        registry::stop(&dir)?;
    }

    registry::create_dir(&dir)?;
    let started = credentials(&dir).and_then(|()| spawn_ready(&dir, ports, "__daemon"));
    let answered = started.and_then(|_| {
        let record = registry::live(&dir)
            .ok_or_else(|| std::io::Error::other("the daemon left no record"))?;
        answer(&dir, &record, false)
    });
    answered.map_err(|err| {
        let _ = registry::stop(&dir);
        EngineError::failed(format!("the daemon did not start: {err}"))
    })
}

fn credentials(dir: &Path) -> std::io::Result<()> {
    let generated = rcgen::generate_simple_self_signed(vec![SERVER_NAME.to_owned()])
        .map_err(std::io::Error::other)?;
    write_private(&dir.join("cert.der"), generated.cert.der())?;
    write_private(&dir.join("key.der"), &generated.key_pair.serialize_der())?;
    write_private(&dir.join("token"), &random_bytes::<TOKEN_LEN>()?)
}

fn answer(dir: &Path, record: &Record, resumed: bool) -> std::io::Result<Value> {
    Ok(json!({
        "port": record.port,
        "cert": base64_encode(&fs::read(dir.join("cert.der"))?),
        "token": base64_encode(&fs::read(dir.join("token"))?),
        "pid": record.pid,
        "epoch": record.epoch(),
        "resumed": resumed,
    }))
}

pub fn serve(dir: &Path) -> i32 {
    let (mut ready, socket) = inherited();
    // Named once, at start: an engine upgraded in place leaves this process's own image
    // deleted, and the requests it runs belong to the binary now at that path.
    let prepared: Fallible<_> = std::env::current_exe()
        .map_err(Into::into)
        .and_then(|program| Ok((program, prepare(dir, socket)?)));
    let (program, (runtime, endpoint, token, held)) = match prepared {
        Ok(prepared) => prepared,
        Err(err) => {
            say_ready(&mut ready, Err(err.to_string()));
            return 1;
        }
    };
    say_ready(&mut ready, Ok(()));
    drop(ready);
    let state_root = dir.parent().map(Path::to_path_buf).unwrap_or_default();
    runtime.block_on(accept(
        endpoint,
        Arc::new(token),
        Arc::new(state_root),
        Arc::new(program),
    ));
    drop(held);
    0
}

type Prepared = (
    tokio::runtime::Runtime,
    quinn::Endpoint,
    [u8; TOKEN_LEN],
    File,
);

fn prepare(dir: &Path, socket: UdpSocket) -> Fallible<Prepared> {
    let Some(held) = registry::server_lock(dir)? else {
        return Err("another daemon holds this directory".into());
    };
    let cert = CertificateDer::from(fs::read(dir.join("cert.der"))?);
    let key = PrivatePkcs8KeyDer::from(fs::read(dir.join("key.der"))?);
    let token = <[u8; TOKEN_LEN]>::try_from(fs::read(dir.join("token"))?.as_slice())
        .map_err(|_| "the token file is not a token")?;

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut tls = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])?
        .with_no_client_auth()
        .with_single_cert(vec![cert], key.into())?;
    tls.alpn_protocols = vec![ALPN.to_vec()];
    let mut config = quinn::ServerConfig::with_crypto(Arc::new(QuicServerConfig::try_from(tls)?));
    config.transport_config(Arc::new(transport()));

    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    socket.set_nonblocking(true)?;
    let port = socket.local_addr()?.port();
    let endpoint = {
        let _entered = runtime.enter();
        quinn::Endpoint::new(
            quinn::EndpointConfig::default(),
            Some(config),
            socket,
            Arc::new(quinn::TokioRuntime),
        )?
    };
    registry::write_record(dir, &Record::new(port, std::process::id()))?;
    Ok((runtime, endpoint, token, held))
}

pub fn transport() -> quinn::TransportConfig {
    let mut transport = quinn::TransportConfig::default();
    transport.initial_mtu(INITIAL_MTU);
    transport.min_mtu(INITIAL_MTU);
    transport.max_idle_timeout(IDLE.try_into().ok());
    transport.congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
    let mut ack = quinn::AckFrequencyConfig::default();
    ack.max_ack_delay(Some(Duration::ZERO));
    transport.ack_frequency_config(Some(ack));
    transport
}

async fn accept(
    endpoint: quinn::Endpoint,
    token: Arc<[u8; TOKEN_LEN]>,
    state_root: Arc<PathBuf>,
    program: Arc<PathBuf>,
) {
    while let Some(incoming) = endpoint.accept().await {
        let (token, state_root, program) = (token.clone(), state_root.clone(), program.clone());
        tokio::spawn(async move {
            if let Ok(connection) = incoming.await {
                let _ = serve_connection(connection, &token, state_root, program).await;
            }
        });
    }
}

fn same(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn serve_connection(
    connection: quinn::Connection,
    token: &[u8; TOKEN_LEN],
    state_root: Arc<PathBuf>,
    program: Arc<PathBuf>,
) -> Fallible {
    let (mut send, mut recv) = connection.accept_bi().await?;
    let mut offered = [0u8; TOKEN_LEN];
    recv.read_exact(&mut offered).await?;
    if !same(&offered, token) {
        connection.close(REFUSED.into(), b"token");
        return Ok(());
    }
    send.write_all(&[1]).await?;
    send.finish()?;

    let channels: Channels = Arc::default();
    tokio::spawn(inbound(connection.clone(), channels.clone()));
    loop {
        let (send, recv) = connection.accept_bi().await?;
        let (connection, channels) = (connection.clone(), channels.clone());
        let (state_root, program) = (state_root.clone(), program.clone());
        tokio::spawn(async move {
            let _ = stream(connection, channels, &state_root, &program, send, recv).await;
        });
    }
}

async fn inbound(connection: quinn::Connection, channels: Channels) {
    while let Ok(datagram) = connection.read_datagram().await {
        let Some((channel, packet)) = datagram.split_first() else {
            continue;
        };
        let socket = channels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(channel)
            .cloned();
        if let Some(socket) = socket {
            let _ = socket.try_send(packet);
        }
    }
}

async fn stream(
    connection: quinn::Connection,
    channels: Channels,
    state_root: &Path,
    program: &Path,
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
) -> Fallible {
    let mut kind = [0u8; 1];
    recv.read_exact(&mut kind).await?;
    match kind[0] {
        RPC => match rpc(program, recv).await {
            Ok(answer) => {
                send.write_all(&answer).await?;
                Ok(send.finish()?)
            }
            Err(err) => {
                let _ = send.reset(UNRUN.into());
                Err(err)
            }
        },
        ATTACH => attach(connection, channels, state_root, send, recv).await,
        _ => {
            let _ = send.reset(REFUSED.into());
            Ok(())
        }
    }
}

async fn rpc(program: &Path, mut recv: quinn::RecvStream) -> Fallible<Vec<u8>> {
    let request = recv.read_to_end(MAX_REQUEST_BYTES).await?;
    let engine = engine(program, std::env::var_os("PATH").as_deref());
    let mut child = tokio::process::Command::new(engine)
        .current_dir("/")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(&request).await?;
    }
    Ok(child.wait_with_output().await?.stdout)
}

/// The engine an ssh exec of `upgraded` would run, so one installed at a new path answers
/// before this daemon restarts; this binary when PATH has none.
fn engine(program: &Path, path: Option<&OsStr>) -> PathBuf {
    let on_path = program.file_name().zip(path).and_then(|(name, path)| {
        std::env::split_paths(path)
            .map(|dir| dir.join(name))
            .find(|candidate| {
                fs::metadata(candidate)
                    .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            })
    });
    on_path.unwrap_or_else(|| program.to_path_buf())
}

async fn attach(
    connection: quinn::Connection,
    channels: Channels,
    state_root: &Path,
    mut send: quinn::SendStream,
    mut recv: quinn::RecvStream,
) -> Fallible {
    let mut len = [0u8; 1];
    recv.read_exact(&mut len).await?;
    let mut name = vec![0u8; usize::from(len[0])];
    recv.read_exact(&mut name).await?;
    let record = std::str::from_utf8(&name)
        .ok()
        .filter(|tab| super::valid_tab(tab))
        .and_then(|tab| registry::live(&registry::dir(state_root, tab)));
    let Some(record) = record else {
        send.write_all(&[0]).await?;
        send.finish()?;
        return Ok(());
    };
    let socket = Arc::new(loopback(record.port).await?);
    let channel = {
        let mut channels = channels
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let free = (0..=u8::MAX).find(|channel| !channels.contains_key(channel));
        if let Some(channel) = free {
            channels.insert(channel, socket.clone());
        }
        free
    };
    let Some(channel) = channel else {
        send.write_all(&[0]).await?;
        send.finish()?;
        return Ok(());
    };
    send.write_all(&[1, channel]).await?;

    let outbound = async {
        let mut buf = vec![0u8; 2048];
        buf[0] = channel;
        while let Ok(n) = socket.recv(&mut buf[1..]).await {
            let _ = connection.send_datagram(Bytes::copy_from_slice(&buf[..=n]));
        }
    };
    tokio::select! {
        () = outbound => {}
        _ = recv.read_to_end(0) => {}
    }
    channels
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .remove(&channel);
    let _ = send.finish();
    Ok(())
}

/// A tab server binds `::` and falls back to `0.0.0.0` only where IPv6 is missing,
/// so `::1` reaches it wherever IPv6 is up and 127.0.0.1 reaches it everywhere else.
async fn loopback(port: u16) -> std::io::Result<tokio::net::UdpSocket> {
    let v6 = SocketAddr::from((Ipv6Addr::LOCALHOST, port));
    if let Ok(socket) = tokio::net::UdpSocket::bind((Ipv6Addr::LOCALHOST, 0)).await {
        if socket.connect(v6).await.is_ok() {
            return Ok(socket);
        }
    }
    let socket = tokio::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await?;
    socket.connect((Ipv4Addr::LOCALHOST, port)).await?;
    Ok(socket)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell::testing;
    use crate::shell::wire::{MAX_PLAINTEXT, NONCE_LEN, TAG_LEN};
    use quinn::crypto::rustls::QuicClientConfig;

    struct Daemon {
        state: PathBuf,
        runtime: tokio::runtime::Runtime,
        port: u16,
        token: [u8; TOKEN_LEN],
        cert: Vec<u8>,
        _held: File,
    }

    fn daemon(name: &str, program: &str) -> Daemon {
        let state = testing::scratch("daemon", name);
        let dir = state.join(DIR);
        registry::create_dir(&dir).unwrap();
        credentials(&dir).unwrap();
        let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let (runtime, endpoint, token, held) = prepare(&dir, socket).unwrap();
        let port = registry::live(&dir).expect("a record").port;
        runtime.spawn(accept(
            endpoint,
            Arc::new(token),
            Arc::new(state.clone()),
            Arc::new(PathBuf::from(program)),
        ));
        let cert = fs::read(dir.join("cert.der")).unwrap();
        Daemon {
            state,
            runtime,
            port,
            token,
            cert,
            _held: held,
        }
    }

    async fn connect(daemon: &Daemon, token: &[u8; TOKEN_LEN]) -> Fallible<quinn::Connection> {
        let mut roots = rustls::RootCertStore::empty();
        roots.add(CertificateDer::from(daemon.cert.clone()))?;
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let mut tls = rustls::ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13])?
            .with_root_certificates(roots)
            .with_no_client_auth();
        tls.alpn_protocols = vec![ALPN.to_vec()];
        let mut config = quinn::ClientConfig::new(Arc::new(QuicClientConfig::try_from(tls)?));
        let mut transport = transport();
        transport.mtu_discovery_config(None);
        config.transport_config(Arc::new(transport));
        let mut endpoint = quinn::Endpoint::client((Ipv4Addr::LOCALHOST, 0).into())?;
        endpoint.set_default_client_config(config);
        let connection = endpoint
            .connect((Ipv4Addr::LOCALHOST, daemon.port).into(), SERVER_NAME)?
            .await?;
        let (mut send, mut recv) = connection.open_bi().await?;
        send.write_all(token).await?;
        send.finish()?;
        let mut ok = [0u8; 1];
        recv.read_exact(&mut ok).await?;
        Ok(connection)
    }

    #[test]
    fn a_request_runs_in_the_engine_on_path_before_this_binary() {
        let root = testing::scratch("daemon", "path");
        let (empty, installed) = (root.join("empty"), root.join("installed"));
        fs::create_dir_all(&empty).unwrap();
        fs::create_dir_all(&installed).unwrap();
        fs::write(installed.join("upgraded"), b"").unwrap();
        let own = Path::new("/old/bin/upgraded");
        let path = std::env::join_paths([&empty, &installed]).unwrap();
        assert_eq!(engine(own, Some(&path)), own);
        fs::set_permissions(
            installed.join("upgraded"),
            fs::Permissions::from_mode(0o755),
        )
        .unwrap();
        assert_eq!(engine(own, Some(&path)), installed.join("upgraded"));
        assert_eq!(engine(own, None), own);
    }

    #[test]
    fn a_wrong_token_is_turned_away() {
        let daemon = daemon("token", "/bin/sh");
        let mut wrong = daemon.token;
        wrong[0] ^= 1;
        assert!(daemon.runtime.block_on(connect(&daemon, &wrong)).is_err());
    }

    #[test]
    fn a_request_runs_in_the_program_and_its_output_comes_back() {
        let daemon = daemon("rpc", "/bin/sh");
        daemon.runtime.block_on(async {
            let connection = connect(&daemon, &daemon.token).await.unwrap();
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(&[RPC]).await.unwrap();
            send.write_all(b"echo answered").await.unwrap();
            send.finish().unwrap();
            let answer = recv.read_to_end(1024).await.unwrap();
            assert_eq!(answer, b"answered\n");
        });
    }

    #[test]
    fn a_tabs_packets_cross_to_its_server_and_back_whole() {
        let daemon = daemon("attach", "/bin/sh");
        registry::ensure_root(&daemon.state).unwrap();
        let tab = registry::dir(&daemon.state, "tab-1");
        registry::create_dir(&tab).unwrap();
        let _server_lock = registry::server_lock(&tab).unwrap().unwrap();
        let server = std::net::UdpSocket::bind((Ipv6Addr::UNSPECIFIED, 0))
            .or_else(|_| std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)))
            .unwrap();
        server
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        registry::write_record(&tab, &Record::new(server.local_addr().unwrap().port(), 1)).unwrap();

        daemon.runtime.block_on(async {
            let connection = connect(&daemon, &daemon.token).await.unwrap();
            let largest = NONCE_LEN + MAX_PLAINTEXT + TAG_LEN;
            assert!(connection.max_datagram_size().unwrap() > largest);

            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(&[ATTACH, 5]).await.unwrap();
            send.write_all(b"tab-1").await.unwrap();
            let mut reply = [0u8; 2];
            recv.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply[0], 1);
            let channel = reply[1];

            let mut packet = vec![channel];
            packet.extend(std::iter::repeat_n(7u8, largest));
            connection.send_datagram(Bytes::from(packet)).unwrap();
            let heard = tokio::task::spawn_blocking(move || {
                let mut buf = [0u8; 2048];
                let (n, from) = server.recv_from(&mut buf).unwrap();
                assert_eq!(&buf[..n], &vec![7u8; largest][..]);
                server.send_to(&vec![9u8; largest], from).unwrap();
            });
            heard.await.unwrap();
            let back = connection.read_datagram().await.unwrap();
            assert_eq!(back[0], channel);
            assert_eq!(&back[1..], &vec![9u8; largest][..]);
        });
    }

    #[test]
    fn a_request_that_cannot_run_is_reset_not_answered_empty() {
        let daemon = daemon("unrunnable", "/nonexistent/upgraded-nowhere");
        daemon.runtime.block_on(async {
            let connection = connect(&daemon, &daemon.token).await.unwrap();
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(&[RPC]).await.unwrap();
            send.finish().unwrap();
            assert!(recv.read_to_end(1024).await.is_err());
        });
    }

    #[test]
    fn a_tab_with_no_server_is_refused() {
        let daemon = daemon("missing", "/bin/sh");
        daemon.runtime.block_on(async {
            let connection = connect(&daemon, &daemon.token).await.unwrap();
            let (mut send, mut recv) = connection.open_bi().await.unwrap();
            send.write_all(&[ATTACH, 5]).await.unwrap();
            send.write_all(b"tab-9").await.unwrap();
            assert_eq!(recv.read_to_end(8).await.unwrap(), vec![0]);
        });
    }
}
