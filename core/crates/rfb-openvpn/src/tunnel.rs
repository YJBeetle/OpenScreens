//! OpenVPN session handshake, data-plane driver and the public [`Tunnel`].
//!
//! [`Tunnel::connect`] performs the whole OpenVPN session synchronously: the
//! hard-reset exchange, the control-channel TLS handshake (with `tls-auth` or
//! `tls-crypt`), key method 2, `PUSH_REQUEST`/`PUSH_REPLY` and data-channel key
//! installation. Only then does it spawn the driver task that owns the outer
//! socket, the smoltcp interface and every inner TCP connection.
//!
//! Everything stays in userspace: the outer transport is an ordinary TCP or
//! UDP socket and the "tun" is an in-memory packet queue, so no VPN
//! permission, system VPN profile or virtual network interface is involved.

use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant as StdInstant};

use tokio::io::{AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::{TcpStream, UdpSocket, lookup_host};
use tokio::sync::{Notify, mpsc, oneshot, watch};

use crate::cipher::Cipher;
use crate::config::{LoadedMaterial, OvpnConfig, Proto, Remote, TlsWrapMode};
use crate::control::{ControlChannel, ControlPacket, Opcode};
use crate::data::DataChannel;
use crate::error::TunnelError;
use crate::keys::{DataKeys, KeySource};
use crate::push::{PushReply, parse_push_reply};
use crate::stack::{NewConnection, Stack, StackConfig};
use crate::static_key::{ControlWrap, StaticKey};
use crate::stream::{ConnState, OpenVpnStream};
use crate::tls::{TlsSession, build_client_config};

/// How often the handshake loop polls control retransmissions and TLS state.
const CONTROL_POLL: Duration = Duration::from_millis(50);
/// How often the data-plane driver polls smoltcp timers.
const DRIVER_TICK: Duration = Duration::from_millis(50);
/// Initial retransmission timeout of the reliable control channel.
const RESET_TIMEOUT: Duration = Duration::from_millis(1000);
/// Re-send `PUSH_REQUEST` if no reply arrived within this interval.
const PUSH_RETRY: Duration = Duration::from_secs(2);
/// Largest outer packet accepted from the peer.
const MAX_PACKET: usize = 65535;
/// OpenVPN's keepalive marker (`ping_string` in `ping.c`).
const PING_STRING: [u8; 16] = [
    0x2a, 0x18, 0x7b, 0xf3, 0x64, 0x1e, 0xb4, 0xcb, 0x07, 0xed, 0x2d, 0x0a, 0x98, 0x1f, 0xc7, 0x48,
];

/// Runtime options that are not part of the profile.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TunnelOptions {
    /// How long [`Tunnel::connect_tcp`] waits for an inner TCP handshake.
    pub connect_timeout: Duration,
    /// Upper bound for the outer connect plus the OpenVPN/TLS handshake.
    pub handshake_timeout: Duration,
}

impl Default for TunnelOptions {
    fn default() -> Self {
        Self {
            connect_timeout: Duration::from_secs(30),
            handshake_timeout: Duration::from_secs(30),
        }
    }
}

/// Coarse state of a tunnel, suitable for a status indicator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelState {
    /// The driver is running and the session is established.
    Up,
    /// The driver has stopped.
    Stopped,
}

/// One IPv4 network pushed by the server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PushedRoute {
    /// Network address.
    pub network: Ipv4Addr,
    /// Prefix length.
    pub prefix: u8,
}

impl PushedRoute {
    /// Returns whether `ip` falls inside this network.
    pub fn contains(self, ip: Ipv4Addr) -> bool {
        let mask = prefix_mask(self.prefix);
        (u32::from(ip) & mask) == u32::from(self.network)
    }
}

fn prefix_mask(prefix: u8) -> u32 {
    if prefix == 0 {
        0
    } else {
        u32::MAX << (32 - u32::from(prefix.min(32)))
    }
}

/// The session parameters negotiated by `PUSH_REPLY`.
///
/// The addresses and routes are informational for the caller; the tunnel
/// enforces them internally before dialling an inner destination. No entry
/// contains key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushInfo {
    /// Inner tunnel address.
    pub local: Ipv4Addr,
    /// Inner netmask (topology dependent).
    pub netmask: Ipv4Addr,
    /// Prefix length derived from `netmask`.
    pub prefix: u8,
    /// Point-to-point peer, when the topology has one.
    pub peer: Option<Ipv4Addr>,
    /// Gateway used for pushed routes.
    pub gateway: Option<Ipv4Addr>,
    /// Pushed DNS servers.
    pub dns: Vec<Ipv4Addr>,
    /// Pushed routes.
    pub routes: Vec<PushedRoute>,
    /// Selected data-channel cipher.
    pub cipher: Cipher,
    /// `P_DATA_V2` peer id, when the server assigned one.
    pub peer_id: Option<u32>,
    /// Inner MTU.
    pub mtu: u16,
    /// Non-fatal findings from the push reply.
    pub warnings: Vec<String>,
}

impl PushInfo {
    /// Returns whether `ip` may be dialled through the tunnel.
    ///
    /// Any address outside the pushed routes, the tunnel subnet and the
    /// point-to-point peer is rejected by [`Tunnel::connect_tcp`] instead of
    /// leaking onto the host network.
    pub fn allows(&self, ip: Ipv4Addr) -> bool {
        if self.routes.iter().any(|route| route.contains(ip)) {
            return true;
        }
        if self.peer == Some(ip) {
            return true;
        }
        let mask = prefix_mask(self.prefix);
        (u32::from(ip) & mask) == (u32::from(self.local) & mask)
    }
}

impl PushInfo {
    fn from_reply(reply: &PushReply, cipher: Cipher) -> Self {
        Self {
            local: reply.ifconfig.local,
            netmask: reply.ifconfig.netmask,
            prefix: reply.ifconfig.prefix,
            peer: reply.ifconfig.peer,
            gateway: reply.gateway,
            dns: reply.dns.clone(),
            routes: reply
                .routes
                .iter()
                .map(|route| PushedRoute {
                    network: route.network,
                    prefix: route.prefix,
                })
                .collect(),
            cipher,
            peer_id: reply.peer_id,
            mtu: reply.mtu,
            warnings: reply.warnings.clone(),
        }
    }
}

/// A snapshot of tunnel health and counters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelStatus {
    /// Coarse state.
    pub state: TunnelState,
    /// Outer endpoint as written in the profile.
    pub endpoint: String,
    /// Inner address pushed by the server.
    pub local_address: Ipv4Addr,
    /// Data-channel cipher in use.
    pub cipher: Cipher,
    /// Negotiated control-channel TLS version.
    pub tls_version: Option<String>,
    /// Open inner TCP connections.
    pub connections: usize,
    /// Inner IPv4 packets encrypted and sent.
    pub tx_packets: u64,
    /// Inner IPv4 packets decrypted and received.
    pub rx_packets: u64,
    /// Most recent non-fatal driver error.
    pub last_error: Option<String>,
}

/// The outer transport of an OpenVPN session.
enum Outer {
    /// TCP with OpenVPN's two-byte big-endian length framing.
    Tcp {
        reader: BufReader<OwnedReadHalf>,
        writer: OwnedWriteHalf,
        pending: Vec<u8>,
        offset: usize,
    },
    /// One datagram per OpenVPN packet.
    Udp { socket: UdpSocket, buffer: Vec<u8> },
}

impl Outer {
    /// Receives one OpenVPN packet.
    ///
    /// Cancellation safe: partial TCP frames stay in `pending`, so the
    /// handshake and driver loops may time out this future at will.
    async fn recv(&mut self) -> io::Result<Option<Vec<u8>>> {
        match self {
            Self::Tcp {
                reader,
                pending,
                offset,
                ..
            } => loop {
                if let Some(frame) = take_tcp_frame(pending, offset)? {
                    return Ok(Some(frame));
                }
                let mut chunk = [0u8; 16 * 1024];
                let read = reader.read(&mut chunk).await?;
                if read == 0 {
                    return if pending.len() == *offset {
                        Ok(None)
                    } else {
                        Err(io::Error::new(
                            io::ErrorKind::UnexpectedEof,
                            "the OpenVPN TCP stream ended in the middle of a packet",
                        ))
                    };
                }
                pending.extend_from_slice(&chunk[..read]);
                if pending.len() > 4 * MAX_PACKET {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "the peer sent an oversized TCP backlog",
                    ));
                }
            },
            Self::Udp { socket, buffer } => {
                let read = socket.recv(buffer).await?;
                Ok(Some(buffer[..read].to_vec()))
            }
        }
    }

    /// Sends one OpenVPN packet.
    async fn send(&mut self, packet: &[u8]) -> io::Result<()> {
        match self {
            Self::Tcp { writer, .. } => {
                if packet.is_empty() || packet.len() > MAX_PACKET {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "packet does not fit in an OpenVPN TCP frame",
                    ));
                }
                let length = (packet.len() as u16).to_be_bytes();
                writer.write_all(&length).await?;
                writer.write_all(packet).await?;
                writer.flush().await
            }
            Self::Udp { socket, .. } => socket.send(packet).await.map(|_| ()),
        }
    }
}

/// Extracts one length-prefixed TCP frame from `buffer`.
fn take_tcp_frame(buffer: &mut Vec<u8>, offset: &mut usize) -> io::Result<Option<Vec<u8>>> {
    if buffer.len() - *offset < 2 {
        return Ok(None);
    }
    let length = usize::from(u16::from_be_bytes([buffer[*offset], buffer[*offset + 1]]));
    if length == 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "the peer sent an empty OpenVPN TCP frame",
        ));
    }
    if buffer.len() - *offset < 2 + length {
        return Ok(None);
    }
    let start = *offset + 2;
    let frame = buffer[start..start + length].to_vec();
    *offset = start + length;
    if *offset == buffer.len() {
        buffer.clear();
        *offset = 0;
    } else if *offset > 64 * 1024 {
        buffer.drain(..*offset);
        *offset = 0;
    }
    Ok(Some(frame))
}

/// Resolves the profile's remote to one IPv4 socket address.
async fn resolve_remote(remote: &Remote) -> Result<SocketAddr, TunnelError> {
    if let Ok(ip) = remote.host.parse::<Ipv4Addr>() {
        return Ok(SocketAddr::new(IpAddr::V4(ip), remote.port));
    }
    let addresses = lookup_host((remote.host.as_str(), remote.port))
        .await
        .map_err(|error| TunnelError::Resolve {
            host: remote.host.clone(),
            detail: error.to_string(),
        })?;
    for address in addresses {
        if address.is_ipv4() {
            return Ok(address);
        }
    }
    Err(TunnelError::Resolve {
        host: remote.host.clone(),
        detail: "the name has no IPv4 address".to_string(),
    })
}

/// Opens the outer TCP or UDP socket.
async fn open_outer(remote: &Remote) -> Result<Outer, TunnelError> {
    let address = resolve_remote(remote).await?;
    match remote.proto {
        Proto::Tcp => {
            let stream = TcpStream::connect(address).await?;
            stream.set_nodelay(true)?;
            let (read, write) = stream.into_split();
            Ok(Outer::Tcp {
                reader: BufReader::new(read),
                writer: write,
                pending: Vec::new(),
                offset: 0,
            })
        }
        Proto::Udp => {
            let socket =
                UdpSocket::bind(SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)).await?;
            socket.connect(address).await?;
            Ok(Outer::Udp {
                socket,
                buffer: vec![0u8; MAX_PACKET],
            })
        }
    }
}

/// Appends an OpenVPN length-prefixed string (the length includes the NUL).
fn write_string(buffer: &mut Vec<u8>, text: &str) -> Result<(), TunnelError> {
    let length = text.len() + 1;
    if length > usize::from(u16::MAX) {
        return Err(TunnelError::Handshake(
            "a key-method-2 string is too long".to_string(),
        ));
    }
    buffer.extend_from_slice(&(length as u16).to_be_bytes());
    buffer.extend_from_slice(text.as_bytes());
    buffer.push(0);
    Ok(())
}

/// Builds the client half of key method 2.
fn build_client_key_message(
    profile: &OvpnConfig,
    keys: &KeySource,
) -> Result<Vec<u8>, TunnelError> {
    let mut buffer = Vec::with_capacity(256);
    buffer.extend_from_slice(&[0u8; 4]);
    buffer.push(2);
    buffer.extend_from_slice(&keys.client_entropy());
    write_string(&mut buffer, &profile.options_string())?;
    write_string(&mut buffer, "")?;
    write_string(&mut buffer, "")?;
    write_string(&mut buffer, &profile.peer_info())?;
    Ok(buffer)
}

/// Reads one length-prefixed string, or `None` when it is still incomplete.
fn read_string(buffer: &[u8], offset: usize) -> Result<Option<(String, usize)>, TunnelError> {
    if buffer.len() < offset + 2 {
        return Ok(None);
    }
    let length = usize::from(u16::from_be_bytes([buffer[offset], buffer[offset + 1]]));
    if length == 0 {
        return Ok(Some((String::new(), offset + 2)));
    }
    if buffer.len() < offset + 2 + length {
        return Ok(None);
    }
    let bytes = &buffer[offset + 2..offset + 2 + length];
    let text = match bytes.last() {
        Some(0) => &bytes[..bytes.len() - 1],
        _ => {
            return Err(TunnelError::Handshake(
                "a key-method-2 string is missing its terminator".to_string(),
            ));
        }
    };
    Ok(Some((
        String::from_utf8_lossy(text).into_owned(),
        offset + 2 + length,
    )))
}

/// The server entropy carried by key method 2.
struct ServerKeyMaterial {
    random1: [u8; 32],
    random2: [u8; 32],
}

/// Parses the server half of key method 2, returning `None` while incomplete.
fn parse_server_key_message(
    buffer: &[u8],
) -> Result<Option<(ServerKeyMaterial, usize)>, TunnelError> {
    if buffer.len() < 4 + 1 + 64 {
        return Ok(None);
    }
    let method = buffer[4];
    if method & 0x0f != 2 {
        return Err(TunnelError::Handshake(format!(
            "the server used key method {}",
            method & 0x0f
        )));
    }
    let mut offset = 5;
    let mut random1 = [0u8; 32];
    random1.copy_from_slice(&buffer[offset..offset + 32]);
    offset += 32;
    let mut random2 = [0u8; 32];
    random2.copy_from_slice(&buffer[offset..offset + 32]);
    offset += 32;

    let Some((_options, next)) = read_string(buffer, offset)? else {
        return Ok(None);
    };
    let Some((_username, next)) = read_string(buffer, next)? else {
        return Ok(None);
    };
    let Some((_password, next)) = read_string(buffer, next)? else {
        return Ok(None);
    };
    let Some((_peer_info, end)) = read_string(buffer, next)? else {
        return Ok(None);
    };
    Ok(Some((ServerKeyMaterial { random1, random2 }, end)))
}

/// What a NUL-terminated control plaintext message means to the client.
enum ControlMessage {
    Push(String),
    Fatal(String),
    Ignore,
}

fn classify_message(message: &str) -> ControlMessage {
    if message.starts_with("PUSH_REPLY") {
        ControlMessage::Push(message.to_string())
    } else if message.starts_with("AUTH_FAILED")
        || message.starts_with("RESTART")
        || message == "HALT"
    {
        ControlMessage::Fatal(message.to_string())
    } else {
        ControlMessage::Ignore
    }
}

/// Everything the handshake produced and the driver needs.
struct Established {
    outer: Outer,
    control: ControlChannel,
    wrap: ControlWrap,
    tls: TlsSession,
    keys: DataKeys,
    cipher: Cipher,
    push: PushReply,
}

/// Performs the control-channel handshake up to and including `PUSH_REPLY`.
async fn handshake(
    mut outer: Outer,
    profile: &OvpnConfig,
    material: &LoadedMaterial,
) -> Result<Established, TunnelError> {
    let static_key = match (&profile.tls_wrap, &material.tls_wrap) {
        (Some(config), Some(loaded)) => {
            let directive = match config.mode {
                TlsWrapMode::Auth => "tls-auth",
                TlsWrapMode::Crypt => "tls-crypt",
            };
            Some(StaticKey::parse(&loaded.key_text, directive)?)
        }
        (None, None) => None,
        _ => {
            return Err(TunnelError::Handshake(
                "the profile's tls-auth/tls-crypt material was not loaded".to_string(),
            ));
        }
    };
    let mut wrap =
        ControlWrap::from_config(profile.tls_wrap.as_ref(), static_key.as_ref(), profile.auth)?;
    let tls_config = build_client_config(profile, material)?;
    let mut tls = TlsSession::new(tls_config, &profile.remote().host)?;
    let mut control = ControlChannel::new(RESET_TIMEOUT);
    control.queue_reset(Opcode::ResetClientV2, StdInstant::now());
    let mut keys = KeySource::generate();

    let mut plaintext: Vec<u8> = Vec::new();
    let mut tls_ready = false;
    let mut key_sent = false;
    let mut server_entropy: Option<ServerKeyMaterial> = None;
    let mut push_requested_at: Option<StdInstant> = None;
    let mut push: Option<PushReply> = None;

    loop {
        let now = StdInstant::now();

        if control.ready_for_tls() {
            let burst = tls.take_ciphertext()?;
            if !burst.is_empty() {
                control.queue_control(&burst, now);
            }
        }

        if tls_ready && !key_sent {
            let message = build_client_key_message(profile, &keys)?;
            tls.write_plaintext(&message)?;
            key_sent = true;
            continue;
        }

        if server_entropy.is_some() && push_requested_at.is_none() {
            tls.write_plaintext(b"PUSH_REQUEST\0")?;
            push_requested_at = Some(now);
            continue;
        }

        if let Some(interval) = push_requested_at
            && interval.elapsed() >= PUSH_RETRY
            && push.is_none()
        {
            tls.write_plaintext(b"PUSH_REQUEST\0")?;
            push_requested_at = Some(now);
        }

        if let Some(reply) = push.take() {
            let peer_session = control.peer_session_id().ok_or_else(|| {
                TunnelError::Handshake("the server session id is missing".to_string())
            })?;
            let cipher = reply.cipher.unwrap_or(profile.cipher);
            if !matches!(
                cipher,
                Cipher::Aes256Gcm
                    | Cipher::Aes192Gcm
                    | Cipher::Aes128Gcm
                    | Cipher::ChaCha20Poly1305
            ) {
                return Err(TunnelError::Unsupported(format!(
                    "the server selected unsupported cipher {}",
                    cipher.name()
                )));
            }
            let data_keys = keys.data_keys(cipher, control.our_session_id(), peer_session, false);
            return Ok(Established {
                outer,
                control,
                wrap,
                tls,
                keys: data_keys,
                cipher,
                push: reply,
            });
        }

        for packet in control.poll_outgoing(now, 16) {
            let encoded = packet.encode()?;
            let wrapped = wrap.wrap(&encoded)?;
            outer.send(&wrapped).await?;
        }

        match tokio::time::timeout(CONTROL_POLL, outer.recv()).await {
            Ok(Ok(Some(packet))) => {
                if packet.len() < 2 {
                    continue;
                }
                let opcode = packet[0] >> 3;
                if opcode == 6 || opcode == 9 {
                    // Data packets cannot be decrypted before the keys exist.
                    continue;
                }
                let unwrapped = wrap.unwrap(&packet).map_err(|error| {
                    TunnelError::Handshake(format!("control packet rejected: {error}"))
                })?;
                let parsed = ControlPacket::parse(&unwrapped)?;
                if parsed.opcode.is_data() {
                    continue;
                }
                for payload in control.on_packet(parsed)? {
                    tls.read_tls(&payload)?;
                }
                plaintext.extend(tls.take_plaintext()?);
                if plaintext.len() > 64 * 1024 {
                    return Err(TunnelError::Handshake(
                        "the server sent an oversized control message".to_string(),
                    ));
                }
                if !tls.is_handshaking() {
                    tls_ready = true;
                }

                if server_entropy.is_none()
                    && let Some((server, consumed)) = parse_server_key_message(&plaintext)?
                {
                    keys.set_server_entropy(server.random1, server.random2);
                    server_entropy = Some(server);
                    plaintext.drain(..consumed);
                }
                if server_entropy.is_some() {
                    while let Some(index) = plaintext.iter().position(|byte| *byte == 0) {
                        let message = String::from_utf8_lossy(&plaintext[..index]).into_owned();
                        plaintext.drain(..=index);
                        match classify_message(&message) {
                            ControlMessage::Push(text) => {
                                push = Some(parse_push_reply(&text)?);
                            }
                            ControlMessage::Fatal(text) => {
                                return Err(TunnelError::Handshake(text));
                            }
                            ControlMessage::Ignore => {}
                        }
                    }
                }
            }
            Ok(Ok(None)) => {
                return Err(TunnelError::Handshake(
                    "the server closed the outer connection during the handshake".to_string(),
                ));
            }
            Ok(Err(error)) => {
                return Err(TunnelError::Handshake(format!(
                    "outer socket error during the handshake: {error}"
                )));
            }
            Err(_) => {}
        }
    }
}

pub(crate) enum Command {
    Connect {
        ip: Ipv4Addr,
        port: u16,
        reply: oneshot::Sender<Result<NewConnection, String>>,
    },
    Close {
        id: u32,
        ack: Option<oneshot::Sender<()>>,
    },
}

pub(crate) struct TunnelHandle {
    pub(crate) commands: mpsc::UnboundedSender<Command>,
    pub(crate) notify: Arc<Notify>,
    pub(crate) status: watch::Receiver<TunnelStatus>,
    push: PushInfo,
    options: TunnelOptions,
    shutdown: Arc<AtomicBool>,
}

/// A running userspace OpenVPN session.
///
/// The session is fully established when this handle is returned. The driver
/// task lives as long as this handle, any [`OpenVpnStream`], or any in-flight
/// command exists.
pub struct Tunnel {
    handle: Arc<TunnelHandle>,
}

impl Tunnel {
    /// Connects and establishes the OpenVPN session described by `profile`.
    ///
    /// This performs the outer connect, the control-channel TLS handshake,
    /// key method 2 and `PUSH_REQUEST`/`PUSH_REPLY` before returning.
    pub async fn connect(
        profile: OvpnConfig,
        options: TunnelOptions,
    ) -> Result<Arc<Self>, TunnelError> {
        let material = profile.load_material()?;
        let remote = profile.remote().clone();
        let established = tokio::time::timeout(options.handshake_timeout, async {
            let outer = open_outer(&remote).await?;
            handshake(outer, &profile, &material).await
        })
        .await
        .map_err(|_| {
            TunnelError::Handshake(format!(
                "no established OpenVPN session after {:?}",
                options.handshake_timeout
            ))
        })??;

        let Established {
            outer,
            control,
            wrap,
            tls,
            keys,
            cipher,
            push,
        } = established;

        let data = DataChannel::new(cipher, keys, push.peer_id)?;
        let stack_config = StackConfig {
            local: push.ifconfig.local,
            prefix: push.ifconfig.prefix,
            gateway: push.stack_gateway(),
            mtu: push.mtu,
        };
        let shutdown = Arc::new(AtomicBool::new(false));
        let stack = Stack::new(stack_config, shutdown.clone()).map_err(TunnelError::Protocol)?;
        let push_info = PushInfo::from_reply(&push, cipher);
        let endpoint = remote.endpoint();
        let status_value = TunnelStatus {
            state: TunnelState::Up,
            endpoint: endpoint.clone(),
            local_address: push.ifconfig.local,
            cipher,
            tls_version: tls.protocol_version().map(str::to_string),
            connections: 0,
            tx_packets: 0,
            rx_packets: 0,
            last_error: None,
        };
        let (status_tx, status_rx) = watch::channel(status_value.clone());
        let (command_tx, command_rx) = mpsc::unbounded_channel();
        let notify = Arc::new(Notify::new());
        let handle = Arc::new(TunnelHandle {
            commands: command_tx,
            notify: notify.clone(),
            status: status_rx,
            push: push_info,
            options,
            shutdown: shutdown.clone(),
        });

        let driver = Driver {
            control,
            wrap,
            tls,
            data,
            stack,
            status: status_tx,
            status_value,
            started: StdInstant::now(),
            plaintext: Vec::new(),
            ping: push.ping,
            last_tx: StdInstant::now(),
            last_error: None,
        };
        tokio::spawn(run(driver, outer, command_rx, notify, shutdown));

        Ok(Arc::new(Self { handle }))
    }

    /// Resolves `host`, enforces the pushed routes, and opens an inner TCP
    /// connection through the tunnel.
    ///
    /// IP literals are used directly. Host names are resolved with the host
    /// resolver and every result is still checked against the pushed routes;
    /// this crate does not yet perform DNS inside the tunnel.
    pub async fn connect_tcp(&self, host: &str, port: u16) -> Result<OpenVpnStream, TunnelError> {
        if port == 0 {
            return Err(TunnelError::Connect {
                host: host.to_string(),
                port,
                detail: "the port must not be zero".to_string(),
            });
        }
        let ip = self.resolve_inner(host, port).await?;

        let (reply, reply_rx) = oneshot::channel();
        self.handle
            .commands
            .send(Command::Connect { ip, port, reply })
            .map_err(|_| TunnelError::Stopped)?;
        let connection = reply_rx
            .await
            .map_err(|_| TunnelError::Stopped)?
            .map_err(|detail| TunnelError::Connect {
                host: host.to_string(),
                port,
                detail,
            })?;

        let NewConnection { id, parts } = connection;
        let mut state = parts.state.clone();
        let wait = tokio::time::timeout(self.handle.options.connect_timeout, async {
            loop {
                match state.borrow().clone() {
                    ConnState::Established => return Ok(()),
                    ConnState::Failed(message) => {
                        return Err(TunnelError::Connect {
                            host: host.to_string(),
                            port,
                            detail: message,
                        });
                    }
                    ConnState::Closed => {
                        return Err(TunnelError::Connect {
                            host: host.to_string(),
                            port,
                            detail: "the connection was closed".to_string(),
                        });
                    }
                    ConnState::Connecting => {}
                }
                if state.changed().await.is_err() {
                    return Err(TunnelError::Stopped);
                }
            }
        })
        .await;

        match wait {
            Ok(Ok(())) => Ok(OpenVpnStream::new(self.handle.clone(), id, parts)),
            Ok(Err(error)) => {
                let _ = self.handle.commands.send(Command::Close { id, ack: None });
                Err(error)
            }
            Err(_) => {
                let _ = self.handle.commands.send(Command::Close { id, ack: None });
                Err(TunnelError::ConnectTimeout {
                    host: host.to_string(),
                    port,
                })
            }
        }
    }

    async fn resolve_inner(&self, host: &str, port: u16) -> Result<Ipv4Addr, TunnelError> {
        if let Ok(ip) = host.parse::<Ipv4Addr>() {
            if self.handle.push.allows(ip) {
                return Ok(ip);
            }
            return Err(TunnelError::NoRoute {
                host: host.to_string(),
                port,
            });
        }
        let addresses = lookup_host((host, 0))
            .await
            .map_err(|error| TunnelError::Resolve {
                host: host.to_string(),
                detail: error.to_string(),
            })?;
        for address in addresses {
            if let IpAddr::V4(ip) = address.ip()
                && self.handle.push.allows(ip)
            {
                return Ok(ip);
            }
        }
        Err(TunnelError::NoRoute {
            host: host.to_string(),
            port,
        })
    }

    /// Returns the `PUSH_REPLY` parameters, including the routes the tunnel
    /// enforces.
    pub fn push_info(&self) -> &PushInfo {
        &self.handle.push
    }

    /// Returns the latest status snapshot.
    pub fn status(&self) -> TunnelStatus {
        self.handle.status.borrow().clone()
    }

    /// Stops the driver and fails every open connection.
    pub fn stop(&self) {
        self.handle.shutdown.store(true, Ordering::SeqCst);
        self.handle.notify.notify_one();
    }
}

/// The data-plane driver: smoltcp plus the OpenVPN data channel.
struct Driver {
    control: ControlChannel,
    wrap: ControlWrap,
    tls: TlsSession,
    data: DataChannel,
    stack: Stack,
    status: watch::Sender<TunnelStatus>,
    status_value: TunnelStatus,
    started: StdInstant,
    plaintext: Vec<u8>,
    ping: Option<Duration>,
    last_tx: StdInstant,
    last_error: Option<String>,
}

impl Driver {
    fn now(&self) -> smoltcp::time::Instant {
        smoltcp::time::Instant::from_millis(self.started.elapsed().as_millis() as i64)
    }

    fn note(&mut self, message: String) {
        self.last_error = Some(message);
    }

    /// Handles one outer packet.
    fn on_outer(&mut self, packet: &[u8]) {
        if packet.len() < 2 {
            return;
        }
        let opcode = packet[0] >> 3;
        if opcode == 6 || opcode == 9 {
            match self.data.decrypt(packet) {
                Ok(inner) => {
                    self.status_value.rx_packets += 1;
                    if is_ipv4(&inner) {
                        self.stack.feed(inner);
                    }
                }
                Err(error) => self.note(format!("data packet rejected: {error}")),
            }
            return;
        }
        self.on_control(packet);
    }

    fn on_control(&mut self, packet: &[u8]) {
        let unwrapped = match self.wrap.unwrap(packet) {
            Ok(packet) => packet,
            Err(error) => {
                self.note(format!("control packet rejected: {error}"));
                return;
            }
        };
        let parsed = match ControlPacket::parse(&unwrapped) {
            Ok(packet) => packet,
            Err(error) => {
                self.note(format!("control packet rejected: {error}"));
                return;
            }
        };
        if parsed.opcode.is_data() {
            return;
        }
        let payloads = match self.control.on_packet(parsed) {
            Ok(payloads) => payloads,
            Err(error) => {
                self.note(format!("control channel error: {error}"));
                return;
            }
        };
        for payload in payloads {
            if let Err(error) = self.tls.read_tls(&payload) {
                self.note(format!("TLS record rejected: {error}"));
                return;
            }
        }
        match self.tls.take_plaintext() {
            Ok(data) if !data.is_empty() => {
                self.plaintext.extend(data);
                self.handle_control_plaintext();
            }
            Ok(_) => {}
            Err(error) => self.note(format!("TLS plaintext failed: {error}")),
        }
        if let Ok(burst) = self.tls.take_ciphertext()
            && !burst.is_empty()
        {
            self.control.queue_control(&burst, StdInstant::now());
        }
    }

    fn handle_control_plaintext(&mut self) {
        if self.plaintext.len() > 64 * 1024 {
            self.plaintext.clear();
            self.note("the server sent an oversized control message".to_string());
            return;
        }
        while let Some(index) = self.plaintext.iter().position(|byte| *byte == 0) {
            let message = String::from_utf8_lossy(&self.plaintext[..index]).into_owned();
            self.plaintext.drain(..=index);
            match classify_message(&message) {
                ControlMessage::Fatal(text) => {
                    self.note(text);
                    self.stack.fail_all("the server terminated the session");
                }
                ControlMessage::Push(text) => {
                    self.note(format!(
                        "ignored a post-handshake {} message",
                        first_word(&text)
                    ));
                }
                ControlMessage::Ignore => {}
            }
        }
    }

    /// Advances smoltcp and collects packets to put on the wire.
    fn tick(&mut self) -> Result<Vec<Vec<u8>>, TunnelError> {
        let now = self.now();
        self.stack.poll(now);

        let mut outgoing = Vec::new();
        let mut inner = Vec::new();
        self.stack.take_egress(&mut inner);
        for packet in inner {
            outgoing.push(self.data.encrypt(&packet)?);
            self.status_value.tx_packets += 1;
        }

        if let Some(interval) = self.ping
            && self.last_tx.elapsed() >= interval
        {
            outgoing.push(self.data.encrypt(&PING_STRING)?);
            self.last_tx = StdInstant::now();
        }

        for packet in self.control.poll_outgoing(StdInstant::now(), 16) {
            let encoded = packet.encode()?;
            outgoing.push(self.wrap.wrap(&encoded)?);
        }
        Ok(outgoing)
    }

    fn refresh_status(&mut self) {
        let status = TunnelStatus {
            state: TunnelState::Up,
            endpoint: self.status_value.endpoint.clone(),
            local_address: self.status_value.local_address,
            cipher: self.status_value.cipher,
            tls_version: self
                .tls
                .protocol_version()
                .map(str::to_string)
                .or_else(|| self.status_value.tls_version.clone()),
            connections: self.stack.connections(),
            tx_packets: self.status_value.tx_packets,
            rx_packets: self.status_value.rx_packets,
            last_error: self.last_error.clone(),
        };
        if status != self.status_value {
            self.status_value = status.clone();
            let _ = self.status.send(status);
        }
    }

    fn mark_stopped(&mut self) {
        self.stack.fail_all("the OpenVPN tunnel was stopped");
        let status = TunnelStatus {
            state: TunnelState::Stopped,
            connections: 0,
            ..self.status_value.clone()
        };
        let _ = self.status.send(status);
    }
}

fn is_ipv4(packet: &[u8]) -> bool {
    packet.len() >= 20 && packet[0] >> 4 == 4
}

fn first_word(text: &str) -> &str {
    text.split(|ch: char| ch == ',' || ch.is_whitespace())
        .next()
        .unwrap_or(text)
}

enum Event {
    Command(Option<Command>),
    Packet(io::Result<Option<Vec<u8>>>),
    Tick,
    Wake,
}

async fn run(
    mut driver: Driver,
    mut outer: Outer,
    mut commands: mpsc::UnboundedReceiver<Command>,
    notify: Arc<Notify>,
    shutdown: Arc<AtomicBool>,
) {
    let mut ticker = tokio::time::interval(DRIVER_TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }
        let event = tokio::select! {
            biased;
            command = commands.recv() => Event::Command(command),
            packet = outer.recv() => Event::Packet(packet),
            _ = ticker.tick() => Event::Tick,
            _ = notify.notified() => Event::Wake,
        };

        let mut fatal = false;
        match event {
            Event::Command(Some(Command::Connect { ip, port, reply })) => {
                let result = driver.stack.connect(ip, port);
                let _ = reply.send(result);
            }
            Event::Command(Some(Command::Close { id, ack })) => {
                driver.stack.close(id, ack);
            }
            Event::Command(None) => break,
            Event::Packet(Ok(Some(packet))) => driver.on_outer(&packet),
            Event::Packet(Ok(None)) => {
                driver.note("the server closed the outer connection".to_string());
                fatal = true;
            }
            Event::Packet(Err(error)) => {
                driver.note(format!("outer socket failed: {error}"));
                fatal = true;
            }
            Event::Tick | Event::Wake => {}
        }

        match driver.tick() {
            Ok(outgoing) => {
                for packet in outgoing {
                    if let Err(error) = outer.send(&packet).await {
                        driver.note(format!("could not send an outer packet: {error}"));
                        fatal = true;
                        break;
                    }
                }
            }
            Err(error) => {
                driver.note(error.to_string());
                fatal = true;
            }
        }
        driver.refresh_status();
        if fatal {
            break;
        }
    }

    driver.mark_stopped();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn profile() -> OvpnConfig {
        let fixture = |name: &str| {
            std::fs::read(format!("{}/tests/data/{name}", env!("CARGO_MANIFEST_DIR")))
                .expect("test fixture")
        };
        let ca = String::from_utf8(fixture("ca.crt")).unwrap();
        let cert = String::from_utf8(fixture("client.crt")).unwrap();
        let key = String::from_utf8(fixture("client.key")).unwrap();
        OvpnConfig::parse(&format!(
            "client\ndev tun\nproto tcp\nremote vpn.test 1194\n\
             <ca>\n{ca}</ca>\n<cert>\n{cert}</cert>\n<key>\n{key}</key>\n\
             remote-cert-tls server\n"
        ))
        .unwrap()
    }

    #[test]
    fn client_key_message_carries_the_profile_options() {
        let profile = profile();
        let keys = KeySource::generate();
        let message = build_client_key_message(&profile, &keys).unwrap();

        assert_eq!(&message[..4], &[0, 0, 0, 0]);
        assert_eq!(message[4], 2);
        assert_eq!(&message[5..5 + 112], keys.client_entropy().as_slice());

        let (options, offset) = read_string(&message, 5 + 112).unwrap().unwrap();
        assert!(options.contains("key-method 2"));
        assert!(options.contains("cipher AES-256-GCM"));
        let (username, offset) = read_string(&message, offset).unwrap().unwrap();
        assert!(username.is_empty());
        let (password, offset) = read_string(&message, offset).unwrap().unwrap();
        assert!(password.is_empty());
        let (peer_info, end) = read_string(&message, offset).unwrap().unwrap();
        assert!(peer_info.contains("IV_NCP=2"));
        assert_eq!(end, message.len());
    }

    #[test]
    fn server_key_message_parses_incrementally() {
        let mut key_message = vec![0u8; 4];
        key_message.push(2);
        key_message.extend_from_slice(&[0x11; 32]);
        key_message.extend_from_slice(&[0x22; 32]);
        write_string(&mut key_message, "V4,dev-type tun,key-method 2").unwrap();
        write_string(&mut key_message, "").unwrap();
        write_string(&mut key_message, "").unwrap();
        write_string(&mut key_message, "IV_VER=2.6.0\n").unwrap();

        for cut in 0..key_message.len() {
            assert!(
                parse_server_key_message(&key_message[..cut])
                    .unwrap()
                    .is_none(),
                "a prefix of {cut} bytes must be incomplete"
            );
        }

        let mut message = key_message.clone();
        message.extend_from_slice(b"PUSH_REPLY,ifconfig 10.8.0.2 255.255.255.0\0");
        let (server, consumed) = parse_server_key_message(&message).unwrap().unwrap();
        assert_eq!(server.random1, [0x11; 32]);
        assert_eq!(server.random2, [0x22; 32]);
        assert_eq!(consumed, key_message.len());
        assert!(message[consumed..].starts_with(b"PUSH_REPLY"));
    }

    #[test]
    fn rejects_an_unknown_key_method() {
        let mut message = vec![0u8; 4];
        message.push(1);
        message.extend_from_slice(&[0u8; 64]);
        let error = match parse_server_key_message(&message) {
            Err(error) => error,
            Ok(_) => panic!("key method 1 must be rejected"),
        };
        assert!(error.to_string().contains("key method 1"));
    }

    #[test]
    fn tcp_framing_handles_partial_and_coalesced_frames() {
        let mut buffer = vec![0u8, 3, b'a', b'b', b'c', 0u8, 2, b'd', b'e'];
        let mut offset = 0;
        assert_eq!(
            take_tcp_frame(&mut buffer, &mut offset).unwrap().unwrap(),
            b"abc"
        );
        assert_eq!(
            take_tcp_frame(&mut buffer, &mut offset).unwrap().unwrap(),
            b"de"
        );
        assert!(buffer.is_empty());
        assert_eq!(offset, 0);

        let mut partial = vec![0u8, 4, b'a'];
        let mut offset = 0;
        assert!(take_tcp_frame(&mut partial, &mut offset).unwrap().is_none());
        assert_eq!(offset, 0);

        let mut empty = vec![0u8, 0];
        let mut offset = 0;
        assert!(take_tcp_frame(&mut empty, &mut offset).is_err());
    }

    #[test]
    fn push_info_rejects_destinations_outside_the_session() {
        let info = PushInfo {
            local: Ipv4Addr::new(10, 8, 0, 2),
            netmask: Ipv4Addr::new(255, 255, 255, 0),
            prefix: 24,
            peer: Some(Ipv4Addr::new(10, 8, 0, 1)),
            gateway: Some(Ipv4Addr::new(10, 8, 0, 1)),
            dns: vec![Ipv4Addr::new(10, 8, 0, 1)],
            routes: vec![PushedRoute {
                network: Ipv4Addr::new(192, 168, 50, 0),
                prefix: 24,
            }],
            cipher: Cipher::Aes256Gcm,
            peer_id: None,
            mtu: 1500,
            warnings: Vec::new(),
        };
        assert!(info.allows(Ipv4Addr::new(10, 8, 0, 9)));
        assert!(info.allows(Ipv4Addr::new(192, 168, 50, 7)));
        assert!(!info.allows(Ipv4Addr::new(192, 168, 60, 1)));
        assert!(!info.allows(Ipv4Addr::new(8, 8, 8, 8)));
    }

    #[test]
    fn classifies_control_messages() {
        assert!(matches!(
            classify_message("PUSH_REPLY,ifconfig 10.8.0.2 10.8.0.1"),
            ControlMessage::Push(_)
        ));
        assert!(matches!(
            classify_message("AUTH_FAILED,certificate revoked"),
            ControlMessage::Fatal(_)
        ));
        assert!(matches!(
            classify_message("AUTH_PENDING,timeout 30"),
            ControlMessage::Ignore
        ));
    }
}
