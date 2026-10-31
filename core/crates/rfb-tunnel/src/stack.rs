//! The single-task tunnel driver and the public [`Tunnel`] handle.
//!
//! One `tokio` task owns the `boringtun` tunnel, the in-memory device, the
//! smoltcp interface and every TCP socket. Nothing inside the driver awaits an
//! operation that also needs `iface.poll`, except sending UDP datagrams which
//! is serialised with the rest of the loop.

use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant as StdInstant};

use ipnet::IpNet;
use smoltcp::iface::{Config as IfaceConfig, Interface, SocketHandle, SocketSet};
use smoltcp::socket::dns as smoltcp_dns;
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::UdpSocket;
use tokio::sync::{Notify, mpsc, oneshot, watch};

use crate::config::{Endpoint, EndpointHost, MAX_MTU, MIN_MTU, WireGuardConfig};
use crate::device::QueueDevice;
use crate::dns as tunnel_dns;
use crate::dns::{PendingQuery, QueryProgress};
use crate::error::{ConfigError, TunnelError};
use crate::keys::PrivateKey;
use crate::noise::{Noise, Outcome};
use crate::stream::{ConnWake, StreamParts, TunnelStream};

/// TCP receive window per connection.
const TCP_RX_BUFFER: usize = 256 * 1024;
/// TCP send buffer per connection.
const TCP_TX_BUFFER: usize = 64 * 1024;
/// Chunks queued from the app to the driver per connection.
const APP_TO_DRIVER_CHUNKS: usize = 4;
/// Chunks queued from the driver to the app per connection.
const DRIVER_TO_APP_CHUNKS: usize = 4;
/// Largest block the driver copies out of a smoltcp socket per chunk.
const DRIVER_READ_CHUNK: usize = 16 * 1024;
/// Poll interval while idle.
const TICK: Duration = Duration::from_millis(100);
/// Extra time the driver waits before aborting a connection that never
/// reached `Established`; the caller's timeout fires first.
const CONNECT_GRACE: Duration = Duration::from_secs(5);
const MAX_DATAGRAM: usize = 65535;
const EPHEMERAL_PORTS: std::ops::RangeInclusive<u16> = 32768..=60999;

/// Runtime options that are not part of the WireGuard configuration.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TunnelOptions {
    /// Fall back to the system resolver when the tunnel DNS fails.
    ///
    /// Set this to `false` for strict no-leak setups; `resolve` then reports
    /// the tunnel DNS error instead.
    pub dns_fallback: bool,
    /// How long [`Tunnel::connect_tcp`] waits for the TCP handshake.
    pub connect_timeout: Duration,
}

impl Default for TunnelOptions {
    fn default() -> Self {
        Self {
            dns_fallback: true,
            connect_timeout: Duration::from_secs(30),
        }
    }
}

/// Coarse state of a tunnel, suitable for a status indicator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TunnelState {
    /// Waiting for the first WireGuard handshake.
    Connecting,
    /// At least one handshake completed.
    Up,
    /// The driver has stopped.
    Stopped,
}

/// A snapshot of tunnel health and counters.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunnelStatus {
    /// Coarse state.
    pub state: TunnelState,
    /// Outer endpoint, when one is configured.
    pub endpoint: Option<String>,
    /// Age of the most recent handshake.
    pub last_handshake: Option<Duration>,
    /// Inner bytes handed to `boringtun` for encryption.
    pub tx_bytes: u64,
    /// Inner bytes recovered from the peer.
    pub rx_bytes: u64,
    /// Open inner TCP connections.
    pub connections: usize,
    /// Most recent non-fatal driver error.
    pub last_error: Option<String>,
}

/// The outer datagram transport.
///
/// Production code uses [`Link::Udp`]; [`Link::memory`] exists for in-process
/// tests and for embedding the driver without a socket.
pub enum Link {
    /// A connected UDP socket to the peer endpoint.
    Udp(UdpSocket),
    /// A pair of in-memory channels carrying WireGuard datagrams.
    Memory {
        /// Datagrams arriving from the peer.
        rx: mpsc::Receiver<Vec<u8>>,
        /// Datagrams to deliver to the peer.
        tx: mpsc::Sender<Vec<u8>>,
    },
}

impl Link {
    /// Builds an in-memory link from a pair of channels.
    pub fn memory(rx: mpsc::Receiver<Vec<u8>>, tx: mpsc::Sender<Vec<u8>>) -> Self {
        Self::Memory { rx, tx }
    }

    async fn recv(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match self {
            Self::Udp(socket) => socket.recv(buffer).await,
            Self::Memory { rx, .. } => {
                let datagram = rx.recv().await.ok_or_else(|| {
                    io::Error::new(io::ErrorKind::BrokenPipe, "the memory link was closed")
                })?;
                if datagram.len() > buffer.len() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "datagram larger than the receive buffer",
                    ));
                }
                buffer[..datagram.len()].copy_from_slice(&datagram);
                Ok(datagram.len())
            }
        }
    }

    async fn send(&self, datagram: &[u8]) -> io::Result<()> {
        match self {
            Self::Udp(socket) => socket.send(datagram).await.map(|_| ()),
            Self::Memory { tx, .. } => tx.send(datagram.to_vec()).await.map_err(|_| {
                io::Error::new(io::ErrorKind::BrokenPipe, "the memory link was closed")
            }),
        }
    }
}

/// Per-connection state, also observed by [`TunnelStream`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum ConnState {
    /// SYN sent, waiting for the peer.
    Connecting,
    /// The TCP connection is established.
    Established,
    /// The connection closed normally.
    Closed,
    /// The connection failed; the string is user-facing and contains no secrets.
    Failed(String),
}

pub(crate) enum Command {
    Connect {
        ip: IpAddr,
        port: u16,
        reply: oneshot::Sender<Result<NewConnection, String>>,
    },
    Close {
        id: u32,
        ack: Option<oneshot::Sender<()>>,
    },
    Resolve {
        host: String,
        reply: oneshot::Sender<Result<Vec<IpAddr>, String>>,
    },
}

pub(crate) struct NewConnection {
    pub id: u32,
    pub parts: StreamParts,
}

pub(crate) struct TunnelHandle {
    pub(crate) commands: mpsc::UnboundedSender<Command>,
    pub(crate) notify: Arc<Notify>,
    pub(crate) status: watch::Receiver<TunnelStatus>,
    config: Arc<WireGuardConfig>,
    options: TunnelOptions,
    shutdown: Arc<AtomicBool>,
}

/// A running userspace WireGuard tunnel.
///
/// The driver task lives as long as this handle, any [`TunnelStream`], or any
/// in-flight command exists.
pub struct Tunnel {
    handle: Arc<TunnelHandle>,
}

impl Tunnel {
    /// Starts a tunnel over a UDP socket to the peer `Endpoint`.
    pub async fn start(
        config: WireGuardConfig,
        private_key: PrivateKey,
        options: TunnelOptions,
    ) -> Result<Arc<Self>, TunnelError> {
        validate(&config)?;
        let endpoint = config
            .peers
            .first()
            .and_then(|peer| peer.endpoint.clone())
            .ok_or_else(|| {
                TunnelError::Unsupported(
                    "a Peer Endpoint is required to open the outer UDP socket".to_string(),
                )
            })?;
        let socket = open_udp(&endpoint, config.interface.listen_port).await?;
        Self::start_with_link(config, private_key, options, Link::Udp(socket)).await
    }

    /// Starts a tunnel over a caller-supplied [`Link`].
    ///
    /// This is the seam used by the in-process tests: the server side is a
    /// second `boringtun` tunnel fed by the other end of the channel pair.
    pub async fn start_with_link(
        config: WireGuardConfig,
        private_key: PrivateKey,
        options: TunnelOptions,
        link: Link,
    ) -> Result<Arc<Self>, TunnelError> {
        validate(&config)?;

        let endpoint = config
            .peers
            .first()
            .and_then(|peer| peer.endpoint.as_ref())
            .map(ToString::to_string);
        let initial = TunnelStatus {
            state: TunnelState::Connecting,
            endpoint,
            last_handshake: None,
            tx_bytes: 0,
            rx_bytes: 0,
            connections: 0,
            last_error: None,
        };

        let (status_tx, status_rx) = watch::channel(initial);
        let (command_tx, command_rx) = mpsc::unbounded_channel();
        let notify = Arc::new(Notify::new());
        let shutdown = Arc::new(AtomicBool::new(false));
        let config = Arc::new(config);

        let driver = Driver::new(config.clone(), private_key, status_tx, options)?;
        let handle = Arc::new(TunnelHandle {
            commands: command_tx,
            notify: notify.clone(),
            status: status_rx,
            config,
            options,
            shutdown: shutdown.clone(),
        });

        tokio::spawn(run(driver, link, command_rx, notify, shutdown));

        Ok(Arc::new(Self { handle }))
    }

    /// Resolves `host`, then opens a TCP connection through the tunnel.
    ///
    /// The destination must be covered by a peer's `AllowedIPs`; otherwise the
    /// call fails with [`TunnelError::NoRoute`] instead of leaking the
    /// connection onto the host network.
    pub async fn connect_tcp(&self, host: &str, port: u16) -> Result<TunnelStream, TunnelError> {
        if port == 0 {
            return Err(TunnelError::Connect {
                host: host.to_string(),
                port,
                detail: "the port must not be zero".to_string(),
            });
        }

        let addresses = self.resolve(host).await?;
        let Some(ip) = addresses
            .into_iter()
            .find(|ip| ip.is_ipv4() && self.handle.config.peer_for(*ip).is_some())
        else {
            return Err(TunnelError::NoRoute {
                host: host.to_string(),
                port,
            });
        };

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
            Ok(Ok(())) => Ok(TunnelStream::new(self.handle.clone(), id, parts)),
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

    /// Resolves a host name, preferring the tunnel DNS when one is configured.
    ///
    /// IP literals are returned as-is. With [`TunnelOptions::dns_fallback`]
    /// enabled, a failed tunnel query falls back to the system resolver.
    pub async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, TunnelError> {
        let host = host.trim();
        if host.is_empty() {
            return Err(TunnelError::Resolve {
                host: host.to_string(),
                detail: "empty host name".to_string(),
            });
        }
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        if host.ends_with(".local") || self.handle.config.interface.dns.is_empty() {
            return tunnel_dns::system_lookup(host).await;
        }

        let (reply, reply_rx) = oneshot::channel();
        self.handle
            .commands
            .send(Command::Resolve {
                host: host.to_string(),
                reply,
            })
            .map_err(|_| TunnelError::Stopped)?;

        let outcome =
            tokio::time::timeout(tunnel_dns::QUERY_TIMEOUT + Duration::from_secs(1), reply_rx)
                .await;
        match outcome {
            Ok(Ok(Ok(addresses))) if !addresses.is_empty() => Ok(addresses),
            Ok(Ok(Err(message))) => self.resolve_fallback(host, message).await,
            Ok(Ok(Ok(_))) => {
                self.resolve_fallback(host, "DNS returned no addresses".to_string())
                    .await
            }
            Ok(Err(_)) => Err(TunnelError::Stopped),
            Err(_) => {
                self.resolve_fallback(host, "DNS lookup timed out".to_string())
                    .await
            }
        }
    }

    async fn resolve_fallback(
        &self,
        host: &str,
        detail: String,
    ) -> Result<Vec<IpAddr>, TunnelError> {
        if self.handle.options.dns_fallback {
            tunnel_dns::system_lookup(host).await
        } else {
            Err(TunnelError::Resolve {
                host: host.to_string(),
                detail,
            })
        }
    }

    /// Returns the latest status snapshot.
    pub fn status(&self) -> TunnelStatus {
        self.handle.status.borrow().clone()
    }

    /// Returns the configuration this tunnel was started with.
    pub fn config(&self) -> &WireGuardConfig {
        &self.handle.config
    }

    /// Stops the driver and fails every open connection.
    ///
    /// Existing [`TunnelStream`] values return an error on their next
    /// read/write; dropping the tunnel without calling this only stops the
    /// driver once the last stream is gone.
    pub fn stop(&self) {
        self.handle.shutdown.store(true, Ordering::SeqCst);
        self.handle.notify.notify_one();
    }
}

fn validate(config: &WireGuardConfig) -> Result<(), TunnelError> {
    if config.peers.is_empty() {
        return Err(ConfigError::MissingSection("Peer").into());
    }
    if config.peers.len() > 1 {
        return Err(TunnelError::Unsupported(
            "only one peer per tunnel is supported in this version".to_string(),
        ));
    }
    let peer = &config.peers[0];
    if peer.allowed_ips.is_empty() {
        return Err(ConfigError::MissingField("Peer.AllowedIPs").into());
    }
    if !config
        .interface
        .addresses
        .iter()
        .any(|net| net.addr().is_ipv4())
    {
        return Err(TunnelError::Unsupported(
            "an IPv4 Address is required; inner IPv6 is not supported yet".to_string(),
        ));
    }
    Ok(())
}

async fn open_udp(endpoint: &Endpoint, listen_port: u16) -> Result<UdpSocket, TunnelError> {
    let remotes: Vec<SocketAddr> = match &endpoint.host {
        EndpointHost::Ip(ip) => vec![SocketAddr::new(*ip, endpoint.port)],
        EndpointHost::Name(name) => tokio::net::lookup_host((name.as_str(), endpoint.port))
            .await
            .map_err(|error| TunnelError::Resolve {
                host: name.clone(),
                detail: error.to_string(),
            })?
            .collect(),
    };
    if remotes.is_empty() {
        return Err(TunnelError::Resolve {
            host: endpoint.to_string(),
            detail: "the resolver returned no addresses".to_string(),
        });
    }

    let mut last_error = None;
    for remote in remotes {
        match bind_udp(remote, listen_port) {
            Ok(socket) => return Ok(socket),
            Err(error) => last_error = Some(error),
        }
    }
    Err(TunnelError::Io(last_error.unwrap_or_else(|| {
        io::Error::new(io::ErrorKind::AddrNotAvailable, "no usable endpoint")
    })))
}

fn bind_udp(remote: SocketAddr, listen_port: u16) -> io::Result<UdpSocket> {
    let domain = if remote.is_ipv4() {
        Domain::IPV4
    } else {
        Domain::IPV6
    };
    let socket = Socket::new(domain, Type::DGRAM, Some(Protocol::UDP))?;
    // Mobile kernels clamp these; failure is not fatal.
    let _ = socket.set_recv_buffer_size(1 << 20);
    let _ = socket.set_send_buffer_size(1 << 20);
    socket.set_nonblocking(true)?;

    let bind_ip = if remote.is_ipv4() {
        IpAddr::V4(Ipv4Addr::UNSPECIFIED)
    } else {
        IpAddr::V6(Ipv6Addr::UNSPECIFIED)
    };
    socket.bind(&SocketAddr::new(bind_ip, listen_port).into())?;
    socket.connect(&remote.into())?;

    let std_socket: std::net::UdpSocket = socket.into();
    UdpSocket::from_std(std_socket)
}

enum Event {
    Command(Option<Command>),
    Datagram(io::Result<usize>),
    Tick,
    Wake,
}

struct PendingResolve {
    query: PendingQuery,
    reply: oneshot::Sender<Result<Vec<IpAddr>, String>>,
}

struct Connection {
    socket: SocketHandle,
    port: u16,
    to_driver: mpsc::Receiver<Vec<u8>>,
    from_driver: Option<mpsc::Sender<Vec<u8>>>,
    pending: Option<(Vec<u8>, usize)>,
    scratch: Vec<u8>,
    wake: Arc<ConnWake>,
    state: watch::Sender<ConnState>,
    state_value: ConnState,
    established: bool,
    close_requested: bool,
    close_ack: Option<oneshot::Sender<()>>,
    app_closed: bool,
    connect_started: StdInstant,
}

impl Connection {
    fn set_state(&mut self, state: ConnState) {
        if self.state_value != state {
            self.state_value = state.clone();
            let _ = self.state.send(state);
        }
    }
}

struct Driver {
    tunn: Noise,
    iface: Interface,
    sockets: SocketSet<'static>,
    device: QueueDevice,
    connections: HashMap<u32, Connection>,
    ports: HashSet<u16>,
    next_id: u32,
    next_port: u16,
    dns_socket: Option<SocketHandle>,
    pending_dns: Vec<PendingResolve>,
    status: watch::Sender<TunnelStatus>,
    status_value: TunnelStatus,
    endpoint: Option<String>,
    last_error: Option<String>,
    started: StdInstant,
    connect_timeout: Duration,
}

impl Driver {
    fn new(
        config: Arc<WireGuardConfig>,
        private_key: PrivateKey,
        status: watch::Sender<TunnelStatus>,
        options: TunnelOptions,
    ) -> Result<Self, TunnelError> {
        let peer = config
            .peers
            .first()
            .ok_or(ConfigError::MissingSection("Peer"))?;
        // Clamp again: struct-literals bypass the parser and smoltcp needs a
        // sane MTU.
        let mtu = config.interface.mtu.clamp(MIN_MTU, MAX_MTU);
        let mut device = QueueDevice::new(mtu);

        let mut iface_config = IfaceConfig::new(HardwareAddress::Ip);
        iface_config.random_seed = rand::random::<u64>();
        let mut iface = Interface::new(iface_config, &mut device, Instant::ZERO);
        let mut ipv4_addresses = 0usize;
        iface.update_ip_addrs(|addrs| {
            for net in &config.interface.addresses {
                if let IpNet::V4(net) = net {
                    let cidr = IpCidr::new(IpAddress::from(net.addr()), net.prefix_len());
                    if addrs.push(cidr).is_ok() {
                        ipv4_addresses += 1;
                    }
                }
            }
        });
        if ipv4_addresses == 0 {
            return Err(TunnelError::Unsupported(
                "no IPv4 Address fits on the inner interface".to_string(),
            ));
        }

        let mut sockets = SocketSet::new(Vec::new());
        let dns_socket =
            tunnel_dns::new_socket(&config.interface.dns).map(|socket| sockets.add(socket));

        let tunn = Noise::new(
            &private_key,
            peer.public_key,
            peer.preshared_key.as_ref(),
            peer.persistent_keepalive,
        );

        let status_value = status.borrow().clone();
        Ok(Self {
            tunn,
            iface,
            sockets,
            device,
            endpoint: config
                .peers
                .first()
                .and_then(|peer| peer.endpoint.as_ref())
                .map(ToString::to_string),
            connections: HashMap::new(),
            ports: HashSet::new(),
            next_id: 1,
            next_port: rand::random_range(EPHEMERAL_PORTS),
            dns_socket,
            pending_dns: Vec::new(),
            status,
            status_value,
            last_error: None,
            started: StdInstant::now(),
            connect_timeout: options.connect_timeout,
        })
    }

    fn now(&self) -> Instant {
        Instant::from_millis(self.started.elapsed().as_millis() as i64)
    }

    fn note(&mut self, error: String) {
        self.last_error = Some(error);
    }

    fn handle_command(&mut self, command: Command) {
        match command {
            Command::Connect { ip, port, reply } => {
                let result = self.open_connection(ip, port);
                let _ = reply.send(result);
            }
            Command::Close { id, ack } => {
                if let Some(connection) = self.connections.get_mut(&id) {
                    connection.close_requested = true;
                    connection.close_ack = ack;
                } else if let Some(ack) = ack {
                    let _ = ack.send(());
                }
            }
            Command::Resolve { host, reply } => match self.dns_socket {
                None => {
                    let _ = reply.send(Err("no tunnel DNS server is configured".to_string()));
                }
                Some(handle) => {
                    let now = StdInstant::now();
                    let socket = self.sockets.get_mut::<smoltcp_dns::Socket>(handle);
                    match tunnel_dns::start_query(socket, self.iface.context(), &host, now) {
                        Ok(query) => self.pending_dns.push(PendingResolve { query, reply }),
                        Err(message) => {
                            let _ = reply.send(Err(message));
                        }
                    }
                }
            },
        }
    }

    fn open_connection(&mut self, ip: IpAddr, port: u16) -> Result<NewConnection, String> {
        let IpAddr::V4(ip) = ip else {
            return Err("inner IPv6 is not supported yet".to_string());
        };
        let Some(local_port) = self.allocate_port() else {
            return Err("no free local TCP port".to_string());
        };

        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; TCP_RX_BUFFER]),
            tcp::SocketBuffer::new(vec![0u8; TCP_TX_BUFFER]),
        );
        socket.set_nagle_enabled(false);
        socket.set_keep_alive(Some(smoltcp::time::Duration::from_secs(60)));
        if let Err(error) = socket.connect(self.iface.context(), (ip, port), local_port) {
            return Err(format!("TCP connect failed: {error}"));
        }
        let socket_handle = self.sockets.add(socket);

        let (to_driver, to_driver_rx) = mpsc::channel(APP_TO_DRIVER_CHUNKS);
        let (from_driver, from_driver_rx) = mpsc::channel(DRIVER_TO_APP_CHUNKS);
        let (state, state_rx) = watch::channel(ConnState::Connecting);
        let wake = Arc::new(ConnWake::new());

        let id = self.next_id;
        self.next_id = self.next_id.wrapping_add(1).max(1);
        self.ports.insert(local_port);

        self.connections.insert(
            id,
            Connection {
                socket: socket_handle,
                port: local_port,
                to_driver: to_driver_rx,
                from_driver: Some(from_driver),
                pending: None,
                scratch: vec![0u8; DRIVER_READ_CHUNK],
                wake: wake.clone(),
                state,
                state_value: ConnState::Connecting,
                established: false,
                close_requested: false,
                close_ack: None,
                app_closed: false,
                connect_started: StdInstant::now(),
            },
        );

        Ok(NewConnection {
            id,
            parts: StreamParts {
                rx: from_driver_rx,
                tx: to_driver,
                state: state_rx,
                wake,
            },
        })
    }

    fn allocate_port(&mut self) -> Option<u16> {
        let count = usize::from(*EPHEMERAL_PORTS.end() - *EPHEMERAL_PORTS.start()) + 1;
        for _ in 0..count {
            let port = self.next_port;
            self.next_port = if port >= *EPHEMERAL_PORTS.end() {
                *EPHEMERAL_PORTS.start()
            } else {
                port + 1
            };
            if !self.ports.contains(&port) {
                return Some(port);
            }
        }
        None
    }

    fn feed(&mut self, datagram: &[u8], buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
        let mut input = Some(datagram);
        // `boringtun` asks the caller to repeat with an empty datagram until it
        // reports `Done`. The bound only guards against a malformed state.
        for _ in 0..256 {
            let repeat = input.is_none();
            let data = input.take().unwrap_or(&[]);
            match self.tunn.decapsulate(data, buffer) {
                Outcome::Done => {
                    if repeat {
                        return;
                    }
                }
                Outcome::Network(len) => out.push(buffer[..len].to_vec()),
                Outcome::TunnelV4(len) => self.device.push_rx(buffer[..len].to_vec()),
                // Inner IPv6 is not compiled into this smoltcp build.
                Outcome::TunnelV6 => {}
                Outcome::Error(error) => {
                    if report_noise_error(&error) {
                        self.note(format!("decapsulation failed: {error:?}"));
                    }
                    if repeat {
                        return;
                    }
                }
            }
        }
    }

    fn tick(&mut self, now: Instant, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        self.drain_timers(buffer, out);
        self.pump_to_app();
        self.pump_to_tcp();
        // A second poll lets data accepted from the app above go out in this
        // iteration instead of waiting for the next timer tick.
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        self.collect_egress(buffer, out);
        self.poll_dns();
        self.cleanup(now);
        self.refresh_status();
    }

    fn drain_timers(&mut self, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
        for _ in 0..16 {
            match self.tunn.update_timers(buffer) {
                Outcome::Network(len) => out.push(buffer[..len].to_vec()),
                Outcome::Done => return,
                Outcome::Error(error) => {
                    self.note(format!("handshake timers: {error:?}"));
                    return;
                }
                Outcome::TunnelV4(_) | Outcome::TunnelV6 => return,
            }
        }
    }

    fn collect_egress(&mut self, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
        while let Some(packet) = self.device.pop_tx() {
            match self.tunn.encapsulate(&packet, buffer) {
                Outcome::Network(len) => out.push(buffer[..len].to_vec()),
                Outcome::Done => {}
                Outcome::Error(error) => {
                    self.note(format!("encapsulation failed: {error:?}"));
                }
                Outcome::TunnelV4(_) | Outcome::TunnelV6 => {}
            }
        }
    }

    fn pump_to_app(&mut self) {
        let sockets = &mut self.sockets;
        for connection in self.connections.values_mut() {
            let socket = sockets.get_mut::<tcp::Socket>(connection.socket);

            if connection
                .from_driver
                .as_ref()
                .is_some_and(mpsc::Sender::is_closed)
            {
                socket.abort();
                connection.from_driver = None;
                continue;
            }

            loop {
                if !socket.can_recv() {
                    break;
                }
                let Some(sender) = connection.from_driver.as_ref() else {
                    break;
                };
                let Ok(permit) = sender.try_reserve() else {
                    break;
                };
                match socket.recv_slice(&mut connection.scratch) {
                    Ok(0) => break,
                    Ok(len) => permit.send(connection.scratch[..len].to_vec()),
                    Err(_) => break,
                }
            }
        }
    }

    fn pump_to_tcp(&mut self) {
        let sockets = &mut self.sockets;
        for connection in self.connections.values_mut() {
            let socket = sockets.get_mut::<tcp::Socket>(connection.socket);

            loop {
                if connection.pending.is_some() {
                    let mut finished = false;
                    if let Some((buffer, offset)) = connection.pending.as_mut() {
                        if !socket.may_send() {
                            break;
                        }
                        match socket.send_slice(&buffer[*offset..]) {
                            Ok(0) => break,
                            Ok(len) => {
                                *offset += len;
                                finished = *offset == buffer.len();
                            }
                            Err(_) => break,
                        }
                    }
                    if finished {
                        connection.pending = None;
                    }
                    connection.wake.wake();
                    if !finished {
                        continue;
                    }
                } else {
                    match connection.to_driver.try_recv() {
                        Ok(chunk) => {
                            connection.wake.wake();
                            if chunk.is_empty() {
                                continue;
                            }
                            connection.pending = Some((chunk, 0));
                        }
                        Err(mpsc::error::TryRecvError::Empty) => break,
                        Err(mpsc::error::TryRecvError::Disconnected) => {
                            connection.app_closed = true;
                            break;
                        }
                    }
                }
            }

            let flushed = connection.pending.is_none() && connection.to_driver.is_empty();
            if (connection.close_requested || connection.app_closed) && flushed {
                if socket.is_open() {
                    socket.close();
                }
                if let Some(ack) = connection.close_ack.take() {
                    let _ = ack.send(());
                }
            }
        }
    }

    fn poll_dns(&mut self) {
        if self.pending_dns.is_empty() {
            return;
        }
        let Some(handle) = self.dns_socket else {
            return;
        };
        let now = StdInstant::now();
        let mut finished = Vec::new();
        {
            let socket = self.sockets.get_mut::<smoltcp_dns::Socket>(handle);
            for (index, pending) in self.pending_dns.iter().enumerate() {
                match tunnel_dns::poll_query(socket, &pending.query, now) {
                    QueryProgress::Pending => {}
                    QueryProgress::Done(addresses) => finished.push((index, Ok(addresses))),
                    QueryProgress::Failed => finished.push((
                        index,
                        Err(format!(
                            "DNS lookup for {} failed or timed out",
                            pending.query.host
                        )),
                    )),
                }
            }
        }
        for (index, result) in finished.into_iter().rev() {
            let pending = self.pending_dns.remove(index);
            let _ = pending.reply.send(result);
        }
    }

    fn cleanup(&mut self, _now: Instant) {
        let connect_timeout = self.connect_timeout;
        let mut remove = Vec::new();

        for (id, connection) in self.connections.iter_mut() {
            let socket = self.sockets.get_mut::<tcp::Socket>(connection.socket);
            let state = socket.state();

            if !connection.established
                && matches!(
                    state,
                    tcp::State::Established
                        | tcp::State::CloseWait
                        | tcp::State::FinWait1
                        | tcp::State::FinWait2
                )
            {
                connection.established = true;
                connection.set_state(ConnState::Established);
            }

            if !connection.established && !connection.close_requested && !connection.app_closed {
                if state == tcp::State::Closed {
                    connection.set_state(ConnState::Failed(
                        "the peer refused the TCP connection".to_string(),
                    ));
                    connection.from_driver = None;
                    remove.push(*id);
                    continue;
                }
                if connection.connect_started.elapsed() > connect_timeout + CONNECT_GRACE {
                    socket.abort();
                    connection.set_state(ConnState::Failed(
                        "timed out connecting through the tunnel".to_string(),
                    ));
                    connection.from_driver = None;
                    remove.push(*id);
                    continue;
                }
            }

            if connection.established && !socket.may_recv() && !socket.can_recv() {
                // The remote half is closed and everything received has been
                // forwarded to the app.
                connection.from_driver = None;
            }

            if matches!(state, tcp::State::Closed | tcp::State::TimeWait) {
                if let Some(ack) = connection.close_ack.take() {
                    let _ = ack.send(());
                }
                connection.from_driver = None;
                if connection.established && !connection.close_requested && !connection.app_closed {
                    connection.set_state(ConnState::Failed(
                        "the peer reset the TCP connection".to_string(),
                    ));
                } else {
                    connection.set_state(ConnState::Closed);
                }
                remove.push(*id);
            }
        }

        for id in remove {
            if let Some(connection) = self.connections.remove(&id) {
                self.sockets.remove(connection.socket);
                self.ports.remove(&connection.port);
            }
        }
    }

    fn refresh_status(&mut self) {
        let stats = self.tunn.stats();
        let state = if stats.handshake_age.is_some() && !self.tunn.is_expired() {
            TunnelState::Up
        } else {
            TunnelState::Connecting
        };
        let status = TunnelStatus {
            state,
            endpoint: self.endpoint.clone(),
            last_handshake: stats.handshake_age,
            tx_bytes: stats.tx_bytes,
            rx_bytes: stats.rx_bytes,
            connections: self.connections.len(),
            last_error: self.last_error.clone(),
        };
        if status != self.status_value {
            self.status_value = status.clone();
            let _ = self.status.send(status);
        }
    }

    async fn send(&mut self, link: &mut Link, out: &mut Vec<Vec<u8>>) -> bool {
        let mut healthy = true;
        for datagram in out.drain(..) {
            if let Err(error) = link.send(&datagram).await {
                self.note(format!("send failed: {error}"));
                if error.kind() == io::ErrorKind::BrokenPipe {
                    healthy = false;
                }
            }
        }
        healthy
    }

    fn shutdown_all(&mut self) {
        for (_, mut connection) in self.connections.drain() {
            connection.set_state(ConnState::Failed("the tunnel was stopped".to_string()));
            if let Some(ack) = connection.close_ack.take() {
                let _ = ack.send(());
            }
            self.ports.remove(&connection.port);
            self.sockets.remove(connection.socket);
        }
        for pending in self.pending_dns.drain(..) {
            let _ = pending.reply.send(Err("tunnel stopped".to_string()));
        }
    }

    fn mark_stopped(&mut self) {
        let status = TunnelStatus {
            state: TunnelState::Stopped,
            connections: 0,
            ..self.status_value.clone()
        };
        if status != self.status_value {
            self.status_value = status.clone();
            let _ = self.status.send(status);
        }
    }
}

/// Replays, packets before the first session and stray counters are normal on
/// a lossy or reordered path and must not surface as tunnel errors.
fn report_noise_error(error: &boringtun::noise::errors::WireGuardError) -> bool {
    use boringtun::noise::errors::WireGuardError;

    !matches!(
        error,
        WireGuardError::DuplicateCounter
            | WireGuardError::InvalidCounter
            | WireGuardError::NoCurrentSession
    )
}

async fn run(
    mut driver: Driver,
    mut link: Link,
    mut commands: mpsc::UnboundedReceiver<Command>,
    notify: Arc<Notify>,
    shutdown: Arc<AtomicBool>,
) {
    let mut rx_buffer = vec![0u8; MAX_DATAGRAM];
    let mut tx_buffer = vec![0u8; MAX_DATAGRAM];
    let mut outbound: Vec<Vec<u8>> = Vec::new();
    let mut ticker = tokio::time::interval(TICK);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        if shutdown.load(Ordering::SeqCst) {
            break;
        }

        let event = tokio::select! {
            biased;
            command = commands.recv() => Event::Command(command),
            result = link.recv(&mut rx_buffer) => Event::Datagram(result),
            _ = ticker.tick() => Event::Tick,
            _ = notify.notified() => Event::Wake,
        };

        match event {
            Event::Command(Some(command)) => driver.handle_command(command),
            Event::Command(None) => break,
            Event::Datagram(Ok(len)) => {
                driver.feed(&rx_buffer[..len], &mut tx_buffer, &mut outbound)
            }
            Event::Datagram(Err(error)) => {
                driver.note(format!("receive failed: {error}"));
                if error.kind() == io::ErrorKind::BrokenPipe {
                    break;
                }
                // Avoid a busy loop on a persistent socket error, then keep
                // polling so timers and handshakes still make progress.
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            Event::Tick | Event::Wake => {}
        }

        let now = driver.now();
        driver.tick(now, &mut tx_buffer, &mut outbound);
        if !driver.send(&mut link, &mut outbound).await {
            break;
        }
    }

    driver.shutdown_all();
    driver.mark_stopped();
}
