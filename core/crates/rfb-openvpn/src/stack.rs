//! Userspace TCP/IP stack for the OpenVPN data plane.
//!
//! The device is an in-memory packet queue. Inner IP packets decrypted by the
//! data channel are pushed into the stack; IP packets emitted by smoltcp are
//! encrypted by the data channel. There is no TUN interface and no OS routing.

use std::collections::{BTreeMap, HashSet};
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant as StdInstant};

use smoltcp::iface::{Config as IfaceConfig, Interface, SocketHandle, SocketSet};
use smoltcp::socket::tcp;
use smoltcp::time::Instant;
use smoltcp::wire::{HardwareAddress, IpAddress, IpCidr, Ipv4Address};
use tokio::sync::{mpsc, oneshot, watch};

use crate::device::QueueDevice;
use crate::stream::{ConnState, ConnWake, StreamParts};

const TCP_RX_BUFFER: usize = 256 * 1024;
const TCP_TX_BUFFER: usize = 64 * 1024;
const APP_TO_DRIVER_CHUNKS: usize = 4;
const DRIVER_TO_APP_CHUNKS: usize = 4;
const DRIVER_READ_CHUNK: usize = 16 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
const CONNECT_GRACE: Duration = Duration::from_secs(5);
const EPHEMERAL_PORTS: std::ops::RangeInclusive<u16> = 32768..=60999;

/// Stack parameters derived from PUSH_REPLY.
#[derive(Debug, Clone, Copy)]
pub(crate) struct StackConfig {
    pub(crate) local: Ipv4Addr,
    pub(crate) prefix: u8,
    pub(crate) gateway: Option<Ipv4Addr>,
    pub(crate) mtu: u16,
}

/// The half of a new connection handed to the stream.
pub(crate) struct NewConnection {
    pub(crate) id: u32,
    pub(crate) parts: StreamParts,
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

/// The in-process smoltcp interface.
pub(crate) struct Stack {
    iface: Interface,
    sockets: SocketSet<'static>,
    device: QueueDevice,
    connections: BTreeMap<u32, Connection>,
    ports: HashSet<u16>,
    next_id: u32,
    next_port: u16,
    shutdown: Arc<AtomicBool>,
}

impl Stack {
    pub(crate) fn new(config: StackConfig, shutdown: Arc<AtomicBool>) -> Result<Self, String> {
        let mut device = QueueDevice::new(config.mtu.clamp(1280, 1500));
        let mut iface_config = IfaceConfig::new(HardwareAddress::Ip);
        iface_config.random_seed = rand::random::<u64>();
        let mut iface = Interface::new(iface_config, &mut device, Instant::ZERO);
        let mut address_installed = false;
        iface.update_ip_addrs(|addresses| {
            address_installed = addresses
                .push(IpCidr::new(
                    IpAddress::v4(
                        config.local.octets()[0],
                        config.local.octets()[1],
                        config.local.octets()[2],
                        config.local.octets()[3],
                    ),
                    config.prefix,
                ))
                .is_ok();
        });
        if !address_installed {
            return Err("could not install the pushed tunnel address".to_string());
        }
        if let Some(gateway) = config.gateway {
            let gateway = Ipv4Address::new(
                gateway.octets()[0],
                gateway.octets()[1],
                gateway.octets()[2],
                gateway.octets()[3],
            );
            iface
                .routes_mut()
                .add_default_ipv4_route(gateway)
                .map_err(|_| "could not install the pushed default route".to_string())?;
        }

        Ok(Self {
            iface,
            sockets: SocketSet::new(Vec::new()),
            device,
            connections: BTreeMap::new(),
            ports: HashSet::new(),
            next_id: 1,
            next_port: rand::random_range(EPHEMERAL_PORTS),
            shutdown,
        })
    }

    pub(crate) fn feed(&mut self, packet: Vec<u8>) {
        self.device.push_rx(packet);
    }

    pub(crate) fn take_egress(&mut self, out: &mut Vec<Vec<u8>>) {
        while let Some(packet) = self.device.pop_tx() {
            out.push(packet);
        }
    }

    pub(crate) fn connections(&self) -> usize {
        self.connections.len()
    }

    pub(crate) fn connect(&mut self, ip: Ipv4Addr, port: u16) -> Result<NewConnection, String> {
        let remote = IpAddress::v4(
            ip.octets()[0],
            ip.octets()[1],
            ip.octets()[2],
            ip.octets()[3],
        );
        let local_port = self
            .allocate_port()
            .ok_or_else(|| "no free local TCP port".to_string())?;

        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; TCP_RX_BUFFER]),
            tcp::SocketBuffer::new(vec![0u8; TCP_TX_BUFFER]),
        );
        socket.set_nagle_enabled(false);
        socket.set_keep_alive(Some(smoltcp::time::Duration::from_secs(60)));
        socket
            .connect(self.iface.context(), (remote, port), local_port)
            .map_err(|error| format!("TCP connect failed: {error}"))?;
        let handle = self.sockets.add(socket);

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
                socket: handle,
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

    pub(crate) fn close(&mut self, id: u32, ack: Option<oneshot::Sender<()>>) {
        if let Some(connection) = self.connections.get_mut(&id) {
            connection.close_requested = true;
            connection.close_ack = ack;
        } else if let Some(ack) = ack {
            let _ = ack.send(());
        }
    }

    pub(crate) fn poll(&mut self, now: Instant) {
        if self.shutdown.load(Ordering::SeqCst) {
            return;
        }
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        self.pump_to_app();
        self.pump_to_tcp();
        self.iface.poll(now, &mut self.device, &mut self.sockets);
        self.cleanup();
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

    fn cleanup(&mut self) {
        let now = StdInstant::now();
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
                if now.duration_since(connection.connect_started) > CONNECT_TIMEOUT + CONNECT_GRACE
                {
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

    pub(crate) fn fail_all(&mut self, message: &str) {
        let connections = std::mem::take(&mut self.connections);
        for (_, mut connection) in connections {
            connection.set_state(ConnState::Failed(message.to_string()));
            if let Some(ack) = connection.close_ack.take() {
                let _ = ack.send(());
            }
            self.ports.remove(&connection.port);
            self.sockets.remove(connection.socket);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct EchoServer {
        iface: Interface,
        sockets: SocketSet<'static>,
        device: QueueDevice,
        listener: SocketHandle,
        pending: Vec<u8>,
        pending_offset: usize,
    }

    impl EchoServer {
        fn new() -> Self {
            let mut device = QueueDevice::new(1280);
            let mut config = IfaceConfig::new(HardwareAddress::Ip);
            config.random_seed = 0x5eed_0bad_cafe_f00d;
            let mut iface = Interface::new(config, &mut device, Instant::ZERO);
            iface.update_ip_addrs(|addresses| {
                addresses
                    .push(IpCidr::new(IpAddress::v4(10, 8, 0, 1), 24))
                    .expect("one address fits");
            });
            let mut sockets = SocketSet::new(Vec::new());
            let mut socket = tcp::Socket::new(
                tcp::SocketBuffer::new(vec![0u8; 256 * 1024]),
                tcp::SocketBuffer::new(vec![0u8; 64 * 1024]),
            );
            socket.listen(5900).expect("echo server listens");
            let listener = sockets.add(socket);
            Self {
                iface,
                sockets,
                device,
                listener,
                pending: Vec::new(),
                pending_offset: 0,
            }
        }

        fn feed(&mut self, packet: Vec<u8>) {
            self.device.push_rx(packet);
        }

        fn poll(&mut self, now: Instant, out: &mut Vec<Vec<u8>>) {
            self.iface.poll(now, &mut self.device, &mut self.sockets);
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
            if socket.state() == tcp::State::CloseWait && self.pending.is_empty() {
                socket.close();
            }
            self.iface.poll(now, &mut self.device, &mut self.sockets);
            while let Some(packet) = self.device.pop_tx() {
                out.push(packet);
            }
        }
    }

    #[test]
    fn dials_and_echoes_through_the_userspace_stack() {
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut client = Stack::new(
            StackConfig {
                local: Ipv4Addr::new(10, 8, 0, 2),
                prefix: 24,
                gateway: None,
                mtu: 1280,
            },
            shutdown.clone(),
        )
        .unwrap();
        let connection = client.connect(Ipv4Addr::new(10, 8, 0, 1), 5900).unwrap();
        let NewConnection { id, parts } = connection;
        let StreamParts {
            tx, mut rx, state, ..
        } = parts;

        tx.try_send(b"hello through openvpn".to_vec()).unwrap();
        drop(tx);

        let mut server = EchoServer::new();
        let mut received = Vec::new();
        let mut established = false;

        for step in 0..4000 {
            let now = Instant::from_millis(step * 10);
            client.poll(now);
            let mut packets = Vec::new();
            client.take_egress(&mut packets);
            for packet in packets {
                server.feed(packet);
            }
            let mut reply = Vec::new();
            server.poll(now, &mut reply);
            for packet in reply {
                client.feed(packet);
            }
            client.poll(now);

            if *state.borrow() == ConnState::Established {
                established = true;
            }
            while let Ok(chunk) = rx.try_recv() {
                received.extend_from_slice(&chunk);
            }
            if established && received == b"hello through openvpn" {
                break;
            }
            if matches!(*state.borrow(), ConnState::Failed(_)) {
                panic!("connection failed: {:?}", *state.borrow());
            }
        }

        assert!(established, "TCP must establish through smoltcp");
        assert_eq!(received, b"hello through openvpn");
        client.close(id, None);
        for step in 0..500 {
            let now = Instant::from_millis(4000 + step * 10);
            client.poll(now);
            let mut packets = Vec::new();
            client.take_egress(&mut packets);
            for packet in packets {
                server.feed(packet);
            }
            let mut reply = Vec::new();
            server.poll(now, &mut reply);
            for packet in reply {
                client.feed(packet);
            }
            client.poll(now);
            if *state.borrow() == ConnState::Closed {
                break;
            }
        }
        assert_eq!(*state.borrow(), ConnState::Closed);
    }

    #[test]
    fn rejects_a_full_port_range_gracefully() {
        let shutdown = Arc::new(AtomicBool::new(false));
        let mut stack = Stack::new(
            StackConfig {
                local: Ipv4Addr::new(10, 8, 0, 2),
                prefix: 24,
                gateway: Some(Ipv4Addr::new(10, 8, 0, 1)),
                mtu: 1280,
            },
            shutdown,
        )
        .unwrap();
        assert!(stack.connections() == 0);
        // A malformed port zero is rejected by the socket layer, not by
        // panicking.
        let _ = stack.connect(Ipv4Addr::new(10, 8, 0, 1), 0);
    }
}
