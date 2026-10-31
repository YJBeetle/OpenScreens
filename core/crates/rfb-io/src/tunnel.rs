//! Dial RFB targets through a userspace WireGuard tunnel.
//!
//! [`TunnelDialer`] wraps an [`rfb_tunnel::Tunnel`] and turns an inner
//! `host:port` into a [`BoxedTransport`], so the RFB engine consumes a tunnel
//! connection exactly like [`crate::connect_tcp`] or [`crate::connect_ssh`].
//! No operating-system VPN profile, permission or virtual interface is
//! involved: the tunnel is a `boringtun` session over an ordinary UDP socket.
//!
//! ```
//! # async fn run(config_text: &str) -> Result<(), rfb_tunnel::TunnelError> {
//! use rfb_tunnel::TunnelOptions;
//! use rfb_io::TunnelDialer;
//!
//! let dialer = TunnelDialer::start(config_text, TunnelOptions::default()).await?;
//! let stream = dialer.dial_tcp("10.66.66.1", 5900).await?;
//! # let _ = stream;
//! # Ok(())
//! # }
//! ```
//!
//! Only destinations covered by a peer's `AllowedIPs` are dialled. Anything
//! else fails with [`rfb_tunnel::TunnelError::NoRoute`] instead of silently
//! leaking onto the host network; callers that want wg-quick split-tunnel
//! behaviour should fall back to [`crate::connect_tcp`] themselves.

use std::fmt;
use std::net::IpAddr;
use std::sync::Arc;

use rfb_tunnel::{Tunnel, TunnelError, TunnelOptions, TunnelStatus, WireGuardConfig};

use crate::tcp::BoxedTransport;

/// A [`rfb_tunnel::Tunnel`] that produces [`BoxedTransport`] connections for
/// the RFB engine.
///
/// Cloning the dialer shares the same tunnel and its driver task.
#[derive(Clone)]
pub struct TunnelDialer {
    tunnel: Arc<Tunnel>,
}

impl fmt::Debug for TunnelDialer {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let status = self.tunnel.status();
        f.debug_struct("TunnelDialer")
            .field("endpoint", &status.endpoint)
            .field("state", &status.state)
            .finish()
    }
}

impl TunnelDialer {
    /// Parses a wg-quick style configuration and starts the tunnel.
    ///
    /// The configuration must contain exactly one `[Peer]` with an `Endpoint`,
    /// and an IPv4 `Address`, which are the limits of the current
    /// [`rfb_tunnel`] implementation.
    pub async fn start(config_text: &str, options: TunnelOptions) -> Result<Self, TunnelError> {
        let parsed = WireGuardConfig::parse(config_text)?;
        let tunnel = Tunnel::start(parsed.config, parsed.private_key, options).await?;
        Ok(Self { tunnel })
    }

    /// Wraps an already started tunnel.
    ///
    /// This shares one tunnel between several dialers (for example VNC and
    /// SSH) and lets embedders supply their own [`rfb_tunnel::Link`].
    pub fn from_tunnel(tunnel: Arc<Tunnel>) -> Self {
        Self { tunnel }
    }

    /// Returns the underlying tunnel handle, for status display or shutdown.
    pub fn tunnel(&self) -> &Arc<Tunnel> {
        &self.tunnel
    }

    /// Opens `host:port` through the tunnel and returns a transport.
    ///
    /// The host is resolved through the tunnel DNS when one is configured
    /// (falling back to the system resolver unless disabled in
    /// [`TunnelOptions`]); the destination must be inside a peer's
    /// `AllowedIPs`.
    pub async fn dial_tcp(&self, host: &str, port: u16) -> Result<BoxedTransport, TunnelError> {
        let stream = self.tunnel.connect_tcp(host, port).await?;
        Ok(Box::new(stream))
    }

    /// Resolves `host` the same way [`Self::dial_tcp`] does.
    pub async fn resolve(&self, host: &str) -> Result<Vec<IpAddr>, TunnelError> {
        self.tunnel.resolve(host).await
    }

    /// Returns the latest tunnel status snapshot.
    pub fn status(&self) -> TunnelStatus {
        self.tunnel.status()
    }

    /// Stops the tunnel and fails every open stream.
    pub fn stop(&self) {
        self.tunnel.stop();
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use boringtun::noise::{Tunn, TunnResult};
    use boringtun::x25519::{PublicKey as DalekPublicKey, StaticSecret};
    use rfb_tunnel::device::QueueDevice;
    use rfb_tunnel::{KeyPair, TunnelState};
    use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
    use smoltcp::socket::tcp;
    use smoltcp::time::Instant;
    use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UdpSocket;
    use tokio::time::timeout;

    use super::*;

    const CLIENT_ADDRESS: &str = "10.66.66.2";
    const SERVER_ADDRESS: &str = "10.66.66.1";
    const SERVER_PORT: u16 = 5900;
    const MTU: u16 = 1280;
    const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
    const IO_TIMEOUT: Duration = Duration::from_secs(10);

    /// A minimal WireGuard peer with a single listening TCP socket that
    /// echoes everything it receives.
    ///
    /// It uses real UDP on `127.0.0.1`, so the client side exercises the full
    /// production path (`Tunnel::start`, UDP socket, handshake, smoltcp TCP)
    /// without root, a TUN device, or an installed `wg`.
    struct EchoServer {
        tunn: Tunn,
        iface: Interface,
        sockets: SocketSet<'static>,
        device: QueueDevice,
        listener: SocketHandle,
        pending: Vec<u8>,
        pending_offset: usize,
        started: std::time::Instant,
    }

    impl EchoServer {
        fn new(private: StaticSecret, client_public: DalekPublicKey) -> Self {
            let mut device = QueueDevice::new(MTU);
            let mut config = Config::new(HardwareAddress::Ip);
            config.random_seed = 0x5eed_0bad_cafe_f00d;
            let mut iface = Interface::new(config, &mut device, Instant::ZERO);
            iface.update_ip_addrs(|addresses| {
                addresses
                    .push(IpCidr::new(IpAddress::v4(10, 66, 66, 1), 24))
                    .expect("one address fits");
            });

            let mut sockets = SocketSet::new(Vec::new());
            let mut socket = tcp::Socket::new(
                tcp::SocketBuffer::new(vec![0u8; 256 * 1024]),
                tcp::SocketBuffer::new(vec![0u8; 64 * 1024]),
            );
            socket
                .listen(SERVER_PORT)
                .expect("the echo server can listen");
            let listener = sockets.add(socket);

            Self {
                tunn: Tunn::new(private, client_public, None, None, 1, None),
                iface,
                sockets,
                device,
                listener,
                pending: Vec::new(),
                pending_offset: 0,
                started: std::time::Instant::now(),
            }
        }

        fn now(&self) -> Instant {
            Instant::from_millis(self.started.elapsed().as_millis() as i64)
        }

        fn feed(&mut self, datagram: &[u8], buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
            let mut input = Some(datagram);
            loop {
                let repeat = input.is_none();
                let data = input.take().unwrap_or(&[]);
                match self.tunn.decapsulate(None, data, buffer) {
                    TunnResult::Done => {
                        if repeat {
                            return;
                        }
                    }
                    TunnResult::Err(error) => {
                        eprintln!("test server decapsulate failed: {error:?}");
                        if repeat {
                            return;
                        }
                    }
                    TunnResult::WriteToNetwork(packet) => out.push(packet.to_vec()),
                    TunnResult::WriteToTunnelV4(packet, _) => self.device.push_rx(packet.to_vec()),
                    TunnResult::WriteToTunnelV6(packet, _) => self.device.push_rx(packet.to_vec()),
                }
            }
        }

        fn timers(&mut self, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
            for _ in 0..8 {
                match self.tunn.update_timers(buffer) {
                    TunnResult::WriteToNetwork(packet) => out.push(packet.to_vec()),
                    _ => return,
                }
            }
        }

        fn pump_echo(&mut self) {
            let socket = self.sockets.get_mut::<tcp::Socket>(self.listener);
            let mut chunk = [0u8; 8192];
            while socket.can_recv() {
                match socket.recv_slice(&mut chunk) {
                    Ok(0) => break,
                    Ok(len) => self.pending.extend_from_slice(&chunk[..len]),
                    Err(_) => break,
                }
            }
            while socket.may_send() && self.pending_offset < self.pending.len() {
                match socket.send_slice(&self.pending[self.pending_offset..]) {
                    Ok(0) => break,
                    Ok(len) => self.pending_offset += len,
                    Err(_) => break,
                }
            }
            if self.pending_offset == self.pending.len() {
                self.pending.clear();
                self.pending_offset = 0;
            }
            // Close once the client half-closed and everything was echoed.
            if socket.state() == tcp::State::CloseWait && self.pending.is_empty() {
                socket.close();
            }
        }

        fn egress(&mut self, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
            while let Some(packet) = self.device.pop_tx() {
                match self.tunn.encapsulate(&packet, buffer) {
                    TunnResult::WriteToNetwork(packet) => out.push(packet.to_vec()),
                    TunnResult::Done => {}
                    TunnResult::Err(error) => {
                        eprintln!("test server encapsulate failed: {error:?}");
                    }
                    TunnResult::WriteToTunnelV4(..) | TunnResult::WriteToTunnelV6(..) => {}
                }
            }
        }

        async fn run(mut self, socket: UdpSocket) {
            let mut rx = vec![0u8; 65535];
            let mut tx = vec![0u8; 65535];
            let mut out = Vec::new();
            let mut peer = None;
            let mut ticker = tokio::time::interval(Duration::from_millis(5));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

            loop {
                tokio::select! {
                    received = socket.recv_from(&mut rx) => match received {
                        Ok((len, from)) => {
                            peer = Some(from);
                            self.feed(&rx[..len], &mut tx, &mut out);
                        }
                        Err(_) => return,
                    },
                    _ = ticker.tick() => {}
                }

                self.timers(&mut tx, &mut out);
                let now = self.now();
                self.iface.poll(now, &mut self.device, &mut self.sockets);
                self.pump_echo();
                self.iface.poll(now, &mut self.device, &mut self.sockets);
                self.egress(&mut tx, &mut out);

                let Some(peer) = peer else {
                    out.clear();
                    continue;
                };
                for datagram in out.drain(..) {
                    if socket.send_to(&datagram, peer).await.is_err() {
                        return;
                    }
                }
            }
        }
    }

    fn client_config(server_public: rfb_tunnel::PublicKey, private: &str, port: u16) -> String {
        format!(
            "[Interface]\nPrivateKey = {private}\nAddress = {CLIENT_ADDRESS}/24\nMTU = {MTU}\n\
             DNS = {SERVER_ADDRESS}\n\n\
             [Peer]\nPublicKey = {}\nAllowedIPs = 10.66.66.0/24\n\
             Endpoint = 127.0.0.1:{port}\nPersistentKeepalive = 25\n",
            server_public.encode_base64()
        )
    }

    async fn start_fixture() -> (TunnelDialer, tokio::task::JoinHandle<()>) {
        let server_keys = KeyPair::generate();
        let client_keys = KeyPair::generate();

        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let endpoint = socket.local_addr().unwrap();
        let server = EchoServer::new(
            StaticSecret::from(server_keys.private().to_bytes()),
            DalekPublicKey::from(client_keys.public().to_bytes()),
        );
        let server = tokio::spawn(server.run(socket));

        let config = client_config(
            *server_keys.public(),
            &client_keys.private().encode_base64(),
            endpoint.port(),
        );
        let dialer = TunnelDialer::start(&config, TunnelOptions::default())
            .await
            .expect("the tunnel starts from a wg-quick configuration");
        (dialer, server)
    }

    #[test]
    fn tunnel_stream_is_a_transport() {
        use tokio::io::{AsyncRead, AsyncWrite};

        fn assert_transport<T: AsyncRead + AsyncWrite + Unpin + Send>() {}
        fn assert_dialer<T: Send + Sync + Clone>() {}

        assert_transport::<rfb_tunnel::TunnelStream>();
        assert_dialer::<TunnelDialer>();
    }

    #[tokio::test]
    async fn rejects_an_invalid_configuration() {
        let error = TunnelDialer::start(
            "[Interface]\nPrivateKey = not-a-key\n",
            TunnelOptions::default(),
        )
        .await
        .expect_err("an invalid key must be rejected");
        assert!(matches!(error, TunnelError::Config(_)), "{error}");
        assert!(!error.to_string().contains("not-a-key"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn dials_tcp_through_the_tunnel_and_echoes() {
        let (dialer, server) = start_fixture().await;

        // Destinations outside AllowedIPs must not leak onto the host network.
        let error = match dialer.dial_tcp("192.0.2.10", SERVER_PORT).await {
            Ok(_) => panic!("an address outside AllowedIPs must be refused"),
            Err(error) => error,
        };
        assert!(matches!(error, TunnelError::NoRoute { .. }), "{error}");

        let mut stream = timeout(
            CONNECT_TIMEOUT,
            dialer.dial_tcp(SERVER_ADDRESS, SERVER_PORT),
        )
        .await
        .expect("connecting must not time out")
        .expect("the tunnel peer accepts the connection");

        let payload: Vec<u8> = (0..128 * 1024).map(|index| (index % 251) as u8).collect();
        stream.write_all(&payload).await.unwrap();
        let mut echoed = vec![0u8; payload.len()];
        timeout(IO_TIMEOUT, stream.read_exact(&mut echoed))
            .await
            .expect("the payload must be echoed")
            .unwrap();
        assert_eq!(echoed, payload);

        let status = timeout(Duration::from_secs(5), async {
            loop {
                let status = dialer.status();
                if status.state == TunnelState::Up && status.connections == 1 {
                    return status;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("the tunnel reaches Up while a connection is open");
        assert!(status.last_handshake.is_some());
        assert!(status.tx_bytes > 0 && status.rx_bytes > 0);

        // A graceful shutdown flushes the queues, sends FIN, and the server
        // closes, so the reader observes EOF.
        stream.shutdown().await.unwrap();
        let mut trailing = [0u8; 8];
        let read = timeout(IO_TIMEOUT, stream.read(&mut trailing))
            .await
            .expect("EOF must arrive after shutdown")
            .unwrap();
        assert_eq!(read, 0);

        drop(stream);
        dialer.stop();
        server.abort();
    }
}
