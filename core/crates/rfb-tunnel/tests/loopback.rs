//! In-process end-to-end test: a real `boringtun` peer on the server side and
//! the full client driver on the other, connected by in-memory datagram
//! channels instead of UDP.
//!
//! The server side is deliberately a separate, minimal implementation: two
//! `boringtun::noise::Tunn` instances acting as WireGuard peers is exactly what
//! would happen over the network, without requiring root, a TUN device or a
//! real `wg` installation.

use std::time::Duration;

use boringtun::noise::{Tunn, TunnResult};
use boringtun::x25519::{PublicKey as DalekPublicKey, StaticSecret};
use rfb_tunnel::device::QueueDevice;
use rfb_tunnel::{
    InterfaceConfig, KeyPair, Link, PeerConfig, Tunnel, TunnelError, TunnelOptions, TunnelState,
    WireGuardConfig,
};
use smoltcp::iface::{Config, Interface, SocketHandle, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::mpsc;
use tokio::time::timeout;

const SERVER_TUNNEL_IP: &str = "10.66.66.1";
const SERVER_TCP_PORT: u16 = 5900;
const MTU: u16 = 1280;

/// A tiny WireGuard server: one tunnel, one listening TCP socket, optional
/// echo. It is close to the prototype in the design notes but driven by tokio
/// channels.
struct EchoServer {
    tunnel: Tunn,
    iface: Interface,
    sockets: SocketSet<'static>,
    device: QueueDevice,
    listener: SocketHandle,
    echo: bool,
    pending: Vec<u8>,
    pending_offset: usize,
    started: std::time::Instant,
}

impl EchoServer {
    fn new(private: StaticSecret, client_public: DalekPublicKey, echo: bool) -> Self {
        let mut device = QueueDevice::new(MTU);
        let mut config = Config::new(HardwareAddress::Ip);
        config.random_seed = 0x5eed_1234_abcd_ef01;
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
            .listen(SERVER_TCP_PORT)
            .expect("the echo server can listen");
        let listener = sockets.add(socket);

        Self {
            tunnel: Tunn::new(private, client_public, None, None, 1, None),
            iface,
            sockets,
            device,
            listener,
            echo,
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
            match self.tunnel.decapsulate(None, data, buffer) {
                TunnResult::Done => {
                    if repeat {
                        return;
                    }
                }
                TunnResult::Err(error) => {
                    eprintln!("server decapsulate failed: {error:?}");
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
            match self.tunnel.update_timers(buffer) {
                TunnResult::WriteToNetwork(packet) => out.push(packet.to_vec()),
                _ => return,
            }
        }
    }

    fn pump_echo(&mut self) {
        if !self.echo {
            return;
        }
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
        // The listener must survive until a connection exists; only a peer
        // FIN (`CloseWait`) with everything echoed closes this side.
        if socket.state() == tcp::State::CloseWait && self.pending.is_empty() {
            socket.close();
        }
    }

    fn egress(&mut self, buffer: &mut [u8], out: &mut Vec<Vec<u8>>) {
        while let Some(packet) = self.device.pop_tx() {
            match self.tunnel.encapsulate(&packet, buffer) {
                TunnResult::WriteToNetwork(packet) => out.push(packet.to_vec()),
                TunnResult::Done => {}
                TunnResult::Err(error) => eprintln!("server encapsulate failed: {error:?}"),
                TunnResult::WriteToTunnelV4(..) | TunnResult::WriteToTunnelV6(..) => {}
            }
        }
    }

    fn finished(&mut self) -> bool {
        let socket = self.sockets.get_mut::<tcp::Socket>(self.listener);
        matches!(socket.state(), tcp::State::Closed | tcp::State::TimeWait)
            && self.pending.is_empty()
    }

    async fn run(
        mut self,
        mut rx: mpsc::Receiver<Vec<u8>>,
        tx: mpsc::Sender<Vec<u8>>,
        stop_after_close: bool,
    ) {
        let mut buffer = vec![0u8; 65535];
        let mut out = Vec::new();

        loop {
            match timeout(Duration::from_millis(10), rx.recv()).await {
                Ok(Some(datagram)) => self.feed(&datagram, &mut buffer, &mut out),
                Ok(None) => return,
                Err(_) => {}
            }

            let now = self.now();
            self.timers(&mut buffer, &mut out);
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            self.pump_echo();
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            self.egress(&mut buffer, &mut out);

            for datagram in out.drain(..) {
                if tx.send(datagram).await.is_err() {
                    return;
                }
            }

            if stop_after_close && self.finished() {
                return;
            }
        }
    }
}

fn client_config(server_public: rfb_tunnel::PublicKey, mtu: u16) -> WireGuardConfig {
    WireGuardConfig {
        interface: InterfaceConfig {
            addresses: vec!["10.66.66.2/24".parse().unwrap()],
            dns: Vec::new(),
            mtu,
            listen_port: 0,
        },
        peers: vec![PeerConfig {
            public_key: server_public,
            preshared_key: None,
            endpoint: None,
            allowed_ips: vec!["10.66.66.0/24".parse().unwrap()],
            persistent_keepalive: Some(25),
        }],
        warnings: Vec::new(),
    }
}

struct Fixture {
    tunnel: std::sync::Arc<Tunnel>,
    server: tokio::task::JoinHandle<()>,
}

#[test]
fn tunnel_stream_is_a_transport() {
    fn assert_transport<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send>() {}
    fn assert_send_sync<T: Send + Sync>() {}

    assert_transport::<rfb_tunnel::TunnelStream>();
    assert_send_sync::<Tunnel>();
    assert_send_sync::<std::sync::Arc<Tunnel>>();
}

async fn start_fixture(echo: bool, mtu: u16) -> Fixture {
    let server_keys = KeyPair::generate();
    let client_keys = KeyPair::generate();

    let (client_out, server_in) = mpsc::channel(4096);
    let (server_out, client_in) = mpsc::channel(4096);

    let server = EchoServer::new(
        StaticSecret::from(server_keys.private().to_bytes()),
        DalekPublicKey::from(client_keys.public().to_bytes()),
        echo,
    );
    let server = tokio::spawn(server.run(server_in, server_out, echo));

    let config = client_config(*server_keys.public(), mtu);
    let tunnel = Tunnel::start_with_link(
        config,
        client_keys.private().clone(),
        TunnelOptions::default(),
        Link::memory(client_in, client_out),
    )
    .await
    .expect("the client tunnel starts");

    Fixture { tunnel, server }
}

#[tokio::test]
async fn start_rejects_multiple_peers_and_a_missing_endpoint() {
    let server = KeyPair::generate();
    let client = KeyPair::generate();

    let mut multi = client_config(*server.public(), MTU);
    multi.peers.push(PeerConfig {
        public_key: *server.public(),
        preshared_key: None,
        endpoint: None,
        allowed_ips: vec!["192.168.0.0/16".parse().unwrap()],
        persistent_keepalive: None,
    });
    let (tx, rx) = mpsc::channel(1);
    let result = Tunnel::start_with_link(
        multi,
        client.private().clone(),
        TunnelOptions::default(),
        Link::memory(rx, tx),
    )
    .await;
    assert!(
        matches!(result, Err(TunnelError::Unsupported(_))),
        "multiple peers must be rejected explicitly"
    );

    let no_endpoint = client_config(*server.public(), MTU);
    let result = Tunnel::start(
        no_endpoint,
        client.private().clone(),
        TunnelOptions::default(),
    )
    .await;
    assert!(
        matches!(result, Err(TunnelError::Unsupported(_))),
        "a UDP tunnel needs a peer endpoint"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn connection_errors_reach_the_caller() {
    let fixture = start_fixture(true, MTU).await;
    // Nothing listens on 5901 in the echo server; smoltcp answers with RST.
    let result = timeout(
        Duration::from_secs(10),
        fixture.tunnel.connect_tcp(SERVER_TUNNEL_IP, 5901),
    )
    .await
    .expect("a refused connection must not hang until the timeout")
    .expect_err("the connection must be refused");
    assert!(
        matches!(result, TunnelError::Connect { .. }),
        "unexpected error: {result:?}"
    );

    drop(fixture.tunnel);
    fixture.server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stop_marks_the_tunnel_stopped() {
    let fixture = start_fixture(false, MTU).await;
    fixture.tunnel.stop();

    let stopped = timeout(Duration::from_secs(5), async {
        loop {
            if fixture.tunnel.status().state == TunnelState::Stopped {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await;
    assert!(stopped.is_ok(), "the driver should stop promptly");

    fixture.server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stream_keeps_the_driver_alive() {
    let fixture = start_fixture(true, MTU).await;
    let mut stream = timeout(
        Duration::from_secs(20),
        fixture
            .tunnel
            .connect_tcp(SERVER_TUNNEL_IP, SERVER_TCP_PORT),
    )
    .await
    .expect("connect must not time out")
    .expect("the server accepts the connection");

    // Dropping the only tunnel handle must not kill the driver while a stream
    // is still open.
    drop(fixture.tunnel);

    stream.write_all(b"still here").await.unwrap();
    let mut echoed = vec![0u8; b"still here".len()];
    timeout(Duration::from_secs(10), stream.read_exact(&mut echoed))
        .await
        .expect("the stream must keep working")
        .unwrap();
    assert_eq!(&echoed, b"still here");

    stream.shutdown().await.unwrap();
    fixture.server.abort();
}

async fn wait_for_status(
    tunnel: &Tunnel,
    ready: impl Fn(&rfb_tunnel::TunnelStatus) -> bool,
) -> rfb_tunnel::TunnelStatus {
    timeout(Duration::from_secs(5), async {
        loop {
            let status = tunnel.status();
            if ready(&status) {
                return status;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the tunnel status never reached the expected value")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tcp_echo_through_tunnel() {
    let fixture = start_fixture(true, MTU).await;
    let tunnel = &fixture.tunnel;

    assert_eq!(
        tunnel.resolve(SERVER_TUNNEL_IP).await.unwrap(),
        vec!["10.66.66.1".parse::<std::net::IpAddr>().unwrap()]
    );

    let no_route = tunnel.connect_tcp("192.0.2.10", SERVER_TCP_PORT).await;
    assert!(
        matches!(no_route, Err(TunnelError::NoRoute { .. })),
        "addresses outside AllowedIPs must not be dialled: {no_route:?}"
    );

    let mut stream = timeout(
        Duration::from_secs(20),
        tunnel.connect_tcp(SERVER_TUNNEL_IP, SERVER_TCP_PORT),
    )
    .await
    .expect("connect must not time out")
    .expect("the echo server accepts the connection");

    let status = wait_for_status(tunnel, |status| {
        status.state == TunnelState::Up && status.connections == 1
    })
    .await;
    assert!(status.last_handshake.is_some());

    let greeting = b"hello over wireguard";
    stream.write_all(greeting).await.unwrap();
    let mut echoed = vec![0u8; greeting.len()];
    timeout(Duration::from_secs(10), stream.read_exact(&mut echoed))
        .await
        .expect("the greeting must be echoed")
        .unwrap();
    assert_eq!(&echoed, greeting);

    // One `write` call only accepts a chunk; a larger buffer is a short write.
    let payload: Vec<u8> = (0..512 * 1024).map(|index| (index % 251) as u8).collect();
    let written = stream.write(&payload).await.unwrap();
    assert!(
        written < payload.len(),
        "poll_write should return a short write for {}-byte buffers, wrote {written}",
        payload.len()
    );
    stream.write_all(&payload[written..]).await.unwrap();

    let mut received = vec![0u8; payload.len()];
    timeout(Duration::from_secs(30), stream.read_exact(&mut received))
        .await
        .expect("the payload must be echoed")
        .unwrap();
    assert_eq!(received, payload);

    let status = wait_for_status(tunnel, |status| status.tx_bytes > 0 && status.rx_bytes > 0).await;
    assert!(
        status.tx_bytes > 0 && status.rx_bytes > 0,
        "traffic counters should advance"
    );

    // Graceful close: the driver drains queued bytes, sends FIN, then the
    // reader observes EOF once the server closes its side.
    stream.shutdown().await.unwrap();
    let mut trailing = [0u8; 16];
    let read = timeout(Duration::from_secs(10), stream.read(&mut trailing))
        .await
        .expect("EOF must arrive after shutdown")
        .unwrap();
    assert_eq!(read, 0, "expected EOF after a clean shutdown");

    drop(stream);
    drop(fixture.tunnel);
    timeout(Duration::from_secs(10), fixture.server)
        .await
        .expect("the echo server should stop after the connection closes")
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn tcp_echo_with_default_mtu_1420() {
    let fixture = start_fixture(true, 1420).await;
    let mut stream = timeout(
        Duration::from_secs(20),
        fixture
            .tunnel
            .connect_tcp(SERVER_TUNNEL_IP, SERVER_TCP_PORT),
    )
    .await
    .expect("connect must not time out")
    .expect("the echo server accepts the connection");

    let payload: Vec<u8> = (0..128 * 1024).map(|index| (index % 97) as u8).collect();
    stream.write_all(&payload).await.unwrap();
    let mut received = vec![0u8; payload.len()];
    timeout(Duration::from_secs(30), stream.read_exact(&mut received))
        .await
        .expect("the payload must be echoed")
        .unwrap();
    assert_eq!(received, payload);

    drop(stream);
    drop(fixture.tunnel);
    fixture.server.abort();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn writes_block_when_the_peer_stops_reading() {
    // The server still acknowledges TCP segments and fills its receive window,
    // but never reads from the socket. Once all buffers are full the client
    // write path must apply backpressure instead of buffering without bound.
    let fixture = start_fixture(false, MTU).await;
    let mut stream = timeout(
        Duration::from_secs(20),
        fixture
            .tunnel
            .connect_tcp(SERVER_TUNNEL_IP, SERVER_TCP_PORT),
    )
    .await
    .expect("connect must not time out")
    .expect("the server accepts the connection");

    let payload = vec![0xABu8; 8 * 1024 * 1024];
    let result = timeout(Duration::from_secs(5), stream.write_all(&payload)).await;
    assert!(
        result.is_err(),
        "write_all must stall once the bounded queues and the TCP window are full"
    );

    drop(stream);
    drop(fixture.tunnel);
    fixture.server.abort();
}
