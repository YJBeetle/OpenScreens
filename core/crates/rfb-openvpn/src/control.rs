//! OpenVPN control-channel packet codec and reliable delivery.
//!
//! Wire layout of an unwrapped control packet:
//!
//! `[opcode:5|key_id:3][session id 8][ack count 1][ack ids 4*n]`
//! `[remote session id 8, only when n > 0][packet id 4][payload...]`
//!
//! `P_ACK_V1` packets carry no packet id and no payload. Reset packets use
//! packet id 0. Control payloads form a reliable byte stream (TLS records are
//! split across packets arbitrarily); retransmission uses an exponential
//! backoff and at most six unacknowledged packets, matching OpenVPN's
//! `TLS_RELIABLE_N_SEND_BUFFERS`.

use std::collections::BTreeMap;
use std::fmt;
use std::time::{Duration, Instant};

use rand::Rng;

use crate::error::TunnelError;

/// Session id size.
pub const SESSION_ID_SIZE: usize = 8;
/// Largest number of acknowledgements accepted in one packet.
pub const MAX_ACKS: usize = 8;
/// Receive window, matching `TLS_RELIABLE_N_REC_BUFFERS`.
const RECEIVE_WINDOW: u32 = 12;
/// Send window, matching `TLS_RELIABLE_N_SEND_BUFFERS`.
const SEND_WINDOW: usize = 6;
/// Largest control payload carried by one packet.
pub(crate) const MAX_CONTROL_PAYLOAD: usize = 1024;
const ACK_OVERHEAD: usize = 1 + MAX_ACKS * 4 + SESSION_ID_SIZE;

/// Control/data opcodes on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Opcode {
    /// P_CONTROL_V1, TLS ciphertext or plaintext control payload.
    ControlV1,
    /// P_CONTROL_SOFT_RESET_V1 (renegotiation, not implemented).
    SoftResetV1,
    /// P_ACK_V1.
    AckV1,
    /// P_DATA_V1.
    DataV1,
    /// P_DATA_V2 (with a 24-bit peer id).
    DataV2,
    /// P_CONTROL_HARD_RESET_CLIENT_V2.
    ResetClientV2,
    /// P_CONTROL_HARD_RESET_SERVER_V2.
    ResetServerV2,
    /// P_CONTROL_HARD_RESET_CLIENT_V3 (tls-crypt-v2, rejected at runtime).
    ResetClientV3,
    /// P_CONTROL_WKC_V1 (tls-crypt-v2, rejected at runtime).
    ControlWkcV1,
}

impl Opcode {
    fn from_byte(byte: u8) -> Option<Self> {
        Some(match byte {
            3 => Self::SoftResetV1,
            4 => Self::ControlV1,
            5 => Self::AckV1,
            6 => Self::DataV1,
            8 => Self::ResetServerV2,
            9 => Self::DataV2,
            10 => Self::ResetClientV3,
            11 => Self::ControlWkcV1,
            7 => Self::ResetClientV2,
            _ => return None,
        })
    }

    fn value(self) -> u8 {
        match self {
            Self::SoftResetV1 => 3,
            Self::ControlV1 => 4,
            Self::AckV1 => 5,
            Self::DataV1 => 6,
            Self::ResetClientV2 => 7,
            Self::ResetServerV2 => 8,
            Self::DataV2 => 9,
            Self::ResetClientV3 => 10,
            Self::ControlWkcV1 => 11,
        }
    }

    pub(crate) fn is_reset(self) -> bool {
        matches!(self, Self::ResetClientV2 | Self::ResetServerV2)
    }

    pub(crate) fn is_data(self) -> bool {
        matches!(self, Self::DataV1 | Self::DataV2)
    }
}

/// A parsed control packet.
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct ControlPacket {
    pub(crate) opcode: Opcode,
    pub(crate) key_id: u8,
    pub(crate) session_id: [u8; SESSION_ID_SIZE],
    pub(crate) acks: Vec<u32>,
    pub(crate) remote_session_id: Option<[u8; SESSION_ID_SIZE]>,
    pub(crate) packet_id: Option<u32>,
    pub(crate) payload: Vec<u8>,
}

impl fmt::Debug for ControlPacket {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ControlPacket")
            .field("opcode", &self.opcode)
            .field("key_id", &self.key_id)
            .field("session_id", &self.session_id)
            .field("acks", &self.acks)
            .field("packet_id", &self.packet_id)
            .field("payload_len", &self.payload.len())
            .finish()
    }
}

impl ControlPacket {
    /// Parses an unwrapped control packet.
    pub(crate) fn parse(packet: &[u8]) -> Result<Self, TunnelError> {
        if packet.len() < 1 + SESSION_ID_SIZE + 1 {
            return Err(TunnelError::Protocol(
                "control packet is too short".to_string(),
            ));
        }
        let header = packet[0];
        let opcode = Opcode::from_byte(header >> 3).ok_or_else(|| {
            TunnelError::Protocol(format!("unknown control opcode {}", header >> 3))
        })?;
        if opcode.is_data() {
            return Err(TunnelError::Protocol(
                "data packet passed to the control parser".to_string(),
            ));
        }
        if opcode == Opcode::ResetClientV3 || opcode == Opcode::ControlWkcV1 {
            return Err(TunnelError::Unsupported(
                "tls-crypt-v2 control packets are not supported".to_string(),
            ));
        }
        if opcode == Opcode::SoftResetV1 {
            return Err(TunnelError::Unsupported(
                "control-channel renegotiation (soft reset) is not supported".to_string(),
            ));
        }
        let key_id = header & 0x07;
        let mut session_id = [0u8; SESSION_ID_SIZE];
        session_id.copy_from_slice(&packet[1..1 + SESSION_ID_SIZE]);
        let mut offset = 1 + SESSION_ID_SIZE;

        let ack_count = usize::from(packet[offset]);
        offset += 1;
        if ack_count > MAX_ACKS {
            return Err(TunnelError::Protocol(
                "control packet carries too many acknowledgements".to_string(),
            ));
        }
        let ack_bytes = ack_count
            .checked_mul(4)
            .ok_or_else(|| TunnelError::Protocol("ack count overflow".to_string()))?;
        if packet.len() < offset + ack_bytes {
            return Err(TunnelError::Protocol(
                "truncated acknowledgement list".to_string(),
            ));
        }
        let mut acks = Vec::with_capacity(ack_count);
        for index in 0..ack_count {
            let start = offset + index * 4;
            acks.push(u32::from_be_bytes(
                packet[start..start + 4].try_into().expect("fixed slice"),
            ));
        }
        offset += ack_bytes;

        let remote_session_id = if ack_count > 0 {
            if packet.len() < offset + SESSION_ID_SIZE {
                return Err(TunnelError::Protocol(
                    "truncated remote session id".to_string(),
                ));
            }
            let mut sid = [0u8; SESSION_ID_SIZE];
            sid.copy_from_slice(&packet[offset..offset + SESSION_ID_SIZE]);
            offset += SESSION_ID_SIZE;
            Some(sid)
        } else {
            None
        };

        let (packet_id, payload) = if opcode == Opcode::AckV1 {
            (None, Vec::new())
        } else {
            if packet.len() < offset + 4 {
                return Err(TunnelError::Protocol(
                    "truncated control packet id".to_string(),
                ));
            }
            let id =
                u32::from_be_bytes(packet[offset..offset + 4].try_into().expect("fixed slice"));
            offset += 4;
            (Some(id), packet[offset..].to_vec())
        };

        if opcode.is_reset() && packet_id != Some(0) {
            return Err(TunnelError::Protocol(
                "reset packet must use packet id 0".to_string(),
            ));
        }
        if opcode == Opcode::ControlV1 && packet_id.is_none() {
            return Err(TunnelError::Protocol(
                "control packet is missing its packet id".to_string(),
            ));
        }

        Ok(Self {
            opcode,
            key_id,
            session_id,
            acks,
            remote_session_id,
            packet_id,
            payload,
        })
    }

    /// Serialises the packet without `tls-auth`/`tls-crypt`.
    pub(crate) fn encode(&self) -> Result<Vec<u8>, TunnelError> {
        if self.acks.len() > MAX_ACKS {
            return Err(TunnelError::Protocol(
                "too many acknowledgements".to_string(),
            ));
        }
        let has_acks = !self.acks.is_empty();
        let remote = if has_acks {
            Some(self.remote_session_id.ok_or_else(|| {
                TunnelError::Protocol("acknowledgements need a remote session id".to_string())
            })?)
        } else {
            None
        };
        let mut output =
            Vec::with_capacity(1 + SESSION_ID_SIZE + ACK_OVERHEAD + 4 + self.payload.len());
        output.push((self.opcode.value() << 3) | (self.key_id & 0x07));
        output.extend_from_slice(&self.session_id);
        output.push(self.acks.len() as u8);
        for ack in &self.acks {
            output.extend_from_slice(&ack.to_be_bytes());
        }
        if let Some(remote) = remote {
            output.extend_from_slice(&remote);
        }
        if self.opcode != Opcode::AckV1 {
            let pid = self.packet_id.ok_or_else(|| {
                TunnelError::Protocol("control packet is missing its packet id".to_string())
            })?;
            output.extend_from_slice(&pid.to_be_bytes());
            output.extend_from_slice(&self.payload);
        }
        Ok(output)
    }

    /// The header byte used by data packets of the same key id.
    #[allow(dead_code)]
    pub(crate) fn key_id(&self) -> u8 {
        self.key_id
    }
}

/// A random OpenVPN session id.
pub(crate) fn random_session_id() -> [u8; SESSION_ID_SIZE] {
    let mut id = [0u8; SESSION_ID_SIZE];
    rand::rng().fill_bytes(&mut id);
    id
}

struct Sent {
    opcode: Opcode,
    payload: Vec<u8>,
    attempts: u32,
    next_try: Instant,
    timeout: Duration,
}

/// One peer's reliable control channel.
pub(crate) struct ControlChannel {
    our_sid: [u8; SESSION_ID_SIZE],
    peer_sid: Option<[u8; SESSION_ID_SIZE]>,
    next_send: u32,
    send: BTreeMap<u32, Sent>,
    pending_acks: Vec<u32>,
    recv_next: u32,
    recv: BTreeMap<u32, Vec<u8>>,
    reset_acked: bool,
    initial_timeout: Duration,
}

impl ControlChannel {
    /// Creates a channel with a fresh random session id. The reset packet is
    /// not queued automatically; call [`Self::queue_reset`].
    pub(crate) fn new(initial_timeout: Duration) -> Self {
        Self {
            our_sid: random_session_id(),
            peer_sid: None,
            next_send: 0,
            send: BTreeMap::new(),
            pending_acks: Vec::new(),
            recv_next: 0,
            recv: BTreeMap::new(),
            reset_acked: false,
            initial_timeout,
        }
    }

    pub(crate) fn our_session_id(&self) -> [u8; SESSION_ID_SIZE] {
        self.our_sid
    }

    pub(crate) fn peer_session_id(&self) -> Option<[u8; SESSION_ID_SIZE]> {
        self.peer_sid
    }

    /// Whether the peer's reset arrived and our reset was acknowledged.
    pub(crate) fn ready_for_tls(&self) -> bool {
        self.peer_sid.is_some() && self.reset_acked
    }

    /// Queues a hard-reset packet (packet id 0).
    pub(crate) fn queue_reset(&mut self, opcode: Opcode, now: Instant) {
        if self.next_send != 0 {
            return;
        }
        self.push(opcode, Vec::new(), now);
    }

    /// Queues control-channel bytes, splitting them into packets.
    pub(crate) fn queue_control(&mut self, payload: &[u8], now: Instant) -> Vec<u32> {
        let mut ids = Vec::new();
        if payload.is_empty() {
            return ids;
        }
        for chunk in payload.chunks(MAX_CONTROL_PAYLOAD) {
            ids.push(self.push(Opcode::ControlV1, chunk.to_vec(), now));
        }
        ids
    }

    fn push(&mut self, opcode: Opcode, payload: Vec<u8>, now: Instant) -> u32 {
        let id = self.next_send;
        self.next_send = self.next_send.wrapping_add(1);
        self.send.insert(
            id,
            Sent {
                opcode,
                payload,
                attempts: 0,
                next_try: now,
                timeout: self.initial_timeout,
            },
        );
        id
    }

    /// Returns packets that should go on the wire now. This includes due
    /// retransmissions, new packets within the six-packet window, and one
    /// dedicated acknowledgement packet when there are pending acks.
    pub(crate) fn poll_outgoing(&mut self, now: Instant, max: usize) -> Vec<ControlPacket> {
        let mut output = Vec::new();

        if !self.pending_acks.is_empty() {
            let acks = std::mem::take(&mut self.pending_acks);
            output.push(ControlPacket {
                opcode: Opcode::AckV1,
                key_id: 0,
                session_id: self.our_sid,
                acks,
                remote_session_id: self.peer_sid,
                packet_id: None,
                payload: Vec::new(),
            });
        }

        if max == 0 {
            return output;
        }

        let in_flight = self.send.values().filter(|sent| sent.attempts > 0).count();
        let mut budget = max;

        // Retransmissions first: the oldest due packet wins, like OpenVPN's
        // reliable_send().
        let mut due: Vec<u32> = self
            .send
            .iter()
            .filter(|(_, sent)| sent.attempts > 0 && sent.next_try <= now)
            .map(|(id, _)| *id)
            .collect();
        due.sort_unstable();

        for id in due {
            if budget == 0 {
                break;
            }
            self.build_outgoing(id, now, &mut output);
            budget -= 1;
        }

        // New packets only while the send window has room.
        if budget > 0 && in_flight < SEND_WINDOW {
            let unsent: Vec<u32> = self
                .send
                .iter()
                .filter(|(_, sent)| sent.attempts == 0)
                .map(|(id, _)| *id)
                .take(SEND_WINDOW.saturating_sub(in_flight))
                .collect();
            for id in unsent {
                if budget == 0 {
                    break;
                }
                self.build_outgoing(id, now, &mut output);
                budget -= 1;
            }
        }

        output
    }

    fn build_outgoing(&mut self, id: u32, now: Instant, output: &mut Vec<ControlPacket>) {
        let Some(sent) = self.send.get_mut(&id) else {
            return;
        };
        sent.attempts += 1;
        sent.next_try = now + sent.timeout;
        sent.timeout = (sent.timeout * 2).min(Duration::from_secs(8));
        let acks = if self.pending_acks.is_empty() {
            Vec::new()
        } else {
            std::mem::take(&mut self.pending_acks)
        };
        output.push(ControlPacket {
            opcode: sent.opcode,
            key_id: 0,
            session_id: self.our_sid,
            acks,
            remote_session_id: self.peer_sid,
            packet_id: Some(id),
            payload: sent.payload.clone(),
        });
    }

    /// Feeds one parsed control packet. Returns ordered control payload bytes
    /// that are ready for the TLS engine.
    pub(crate) fn on_packet(&mut self, packet: ControlPacket) -> Result<Vec<Vec<u8>>, TunnelError> {
        match self.peer_sid {
            None => {
                if packet.opcode != Opcode::ResetServerV2 {
                    return Err(TunnelError::Protocol(
                        "expected a server reset packet".to_string(),
                    ));
                }
                self.peer_sid = Some(packet.session_id);
            }
            Some(peer) => {
                if packet.session_id != peer {
                    return Err(TunnelError::Protocol(
                        "control packet session id changed".to_string(),
                    ));
                }
            }
        }

        if !packet.acks.is_empty() {
            if packet.remote_session_id != Some(self.our_sid) {
                return Err(TunnelError::Protocol(
                    "acknowledgement has the wrong remote session id".to_string(),
                ));
            }
            for ack in &packet.acks {
                self.send.remove(ack);
                if *ack == 0 {
                    self.reset_acked = true;
                }
            }
        }

        if packet.opcode == Opcode::AckV1 {
            return Ok(Vec::new());
        }

        let id = packet.packet_id.ok_or_else(|| {
            TunnelError::Protocol("control packet is missing its packet id".to_string())
        })?;

        if packet.opcode.is_reset() {
            // The server's reset is packet id 0 and may carry early
            // negotiation TLVs, which this profile does not use.
            self.note_ack(id);
            self.recv_next = self.recv_next.max(1);
            return Ok(Vec::new());
        }

        if id < self.recv_next {
            // Duplicate: acknowledge it again but do not deliver it twice.
            self.note_ack(id);
            return Ok(Vec::new());
        }
        if id >= self.recv_next.saturating_add(RECEIVE_WINDOW) {
            return Err(TunnelError::Protocol(
                "control packet is outside the receive window".to_string(),
            ));
        }

        self.note_ack(id);
        self.recv.entry(id).or_insert(packet.payload);

        let mut ready = Vec::new();
        while let Some(payload) = self.recv.remove(&self.recv_next) {
            ready.push(payload);
            self.recv_next = self.recv_next.saturating_add(1);
        }
        Ok(ready)
    }

    fn note_ack(&mut self, id: u32) {
        if !self.pending_acks.contains(&id) {
            if self.pending_acks.len() >= MAX_ACKS {
                self.pending_acks.remove(0);
            }
            self.pending_acks.push(id);
        }
    }
}

impl fmt::Debug for ControlChannel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ControlChannel")
            .field("peer_session", &self.peer_sid.is_some())
            .field("reset_acked", &self.reset_acked)
            .field("next_send", &self.next_send)
            .field("pending_acks", &self.pending_acks.len())
            .field("recv_next", &self.recv_next)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn packet(opcode: Opcode, sid: [u8; 8], pid: u32, payload: &[u8]) -> ControlPacket {
        ControlPacket {
            opcode,
            key_id: 0,
            session_id: sid,
            acks: Vec::new(),
            remote_session_id: None,
            packet_id: Some(pid),
            payload: payload.to_vec(),
        }
    }

    #[test]
    fn codec_round_trips_control_and_ack_packets() {
        let mut control = packet(Opcode::ControlV1, [1; 8], 7, b"hello");
        control.acks = vec![0, 4];
        control.remote_session_id = Some([2; 8]);
        let encoded = control.encode().unwrap();
        let decoded = ControlPacket::parse(&encoded).unwrap();
        assert_eq!(decoded, control);

        let ack = ControlPacket {
            opcode: Opcode::AckV1,
            key_id: 0,
            session_id: [1; 8],
            acks: vec![3],
            remote_session_id: Some([2; 8]),
            packet_id: None,
            payload: Vec::new(),
        };
        let encoded = ack.encode().unwrap();
        assert_eq!(ControlPacket::parse(&encoded).unwrap(), ack);

        let reset = packet(Opcode::ResetClientV2, [1; 8], 0, b"");
        assert_eq!(
            ControlPacket::parse(&reset.encode().unwrap()).unwrap(),
            reset
        );
    }

    #[test]
    fn codec_rejects_malformed_packets() {
        assert!(ControlPacket::parse(&[0x20]).is_err());
        let valid = packet(Opcode::ControlV1, [1; 8], 1, b"x").encode().unwrap();
        for cut in 1..valid.len() - 1 {
            assert!(
                ControlPacket::parse(&valid[..cut]).is_err(),
                "prefix {cut} must be rejected"
            );
        }
        let mut huge = valid.clone();
        huge[9] = 255;
        assert!(ControlPacket::parse(&huge).is_err());
    }

    #[test]
    fn reset_handshake_unblocks_tls() {
        let now = Instant::now();
        let mut client = ControlChannel::new(Duration::from_secs(1));
        client.queue_reset(Opcode::ResetClientV2, now);
        assert!(!client.ready_for_tls());

        let outgoing = client.poll_outgoing(now, 8);
        assert_eq!(outgoing.len(), 1);
        assert_eq!(outgoing[0].opcode, Opcode::ResetClientV2);
        assert_eq!(outgoing[0].packet_id, Some(0));

        let peer = random_session_id();
        let mut server_reset = packet(Opcode::ResetServerV2, peer, 0, b"");
        server_reset.acks = vec![0];
        server_reset.remote_session_id = Some(client.our_session_id());
        let ready = client.on_packet(server_reset).unwrap();
        assert!(ready.is_empty());
        assert!(client.ready_for_tls());
        assert_eq!(client.peer_session_id(), Some(peer));

        // The next outgoing packet acknowledges the server reset.
        let outgoing = client.poll_outgoing(now + Duration::from_secs(1), 8);
        assert_eq!(outgoing[0].opcode, Opcode::AckV1);
        assert_eq!(outgoing[0].acks, vec![0]);
    }

    #[test]
    fn delivers_payloads_in_order_and_acks_duplicates() {
        let now = Instant::now();
        let mut client = ControlChannel::new(Duration::from_secs(1));
        client.queue_reset(Opcode::ResetClientV2, now);
        let peer = [9; 8];
        let mut reset = packet(Opcode::ResetServerV2, peer, 0, b"");
        reset.acks = vec![0];
        reset.remote_session_id = Some(client.our_session_id());
        client.on_packet(reset).unwrap();
        let _ = client.poll_outgoing(now, 8);

        let ack_of_reset = ControlPacket {
            opcode: Opcode::AckV1,
            key_id: 0,
            session_id: peer,
            acks: vec![0],
            remote_session_id: Some(client.our_session_id()),
            packet_id: None,
            payload: Vec::new(),
        };
        // Not needed for delivery, but must be accepted.
        client.on_packet(ack_of_reset).unwrap();

        assert_eq!(
            client
                .on_packet(packet(Opcode::ControlV1, peer, 2, b"two"))
                .unwrap(),
            Vec::<Vec<u8>>::new()
        );
        assert_eq!(
            client
                .on_packet(packet(Opcode::ControlV1, peer, 1, b"one"))
                .unwrap(),
            vec![b"one".to_vec(), b"two".to_vec()]
        );

        // A duplicate is acknowledged but not delivered again.
        assert!(
            client
                .on_packet(packet(Opcode::ControlV1, peer, 1, b"one"))
                .unwrap()
                .is_empty()
        );
        let outgoing = client.poll_outgoing(now, 8);
        assert!(outgoing.iter().any(|p| p.acks.contains(&1)));
    }

    #[test]
    fn retransmits_with_backoff_and_stops_after_ack() {
        let now = Instant::now();
        let mut client = ControlChannel::new(Duration::from_secs(1));
        client.queue_reset(Opcode::ResetClientV2, now);
        let first = client.poll_outgoing(now, 8);
        assert_eq!(first.len(), 1);
        assert!(client.poll_outgoing(now, 8).is_empty(), "not due yet");
        assert_eq!(
            client.poll_outgoing(now + Duration::from_secs(1), 8).len(),
            1
        );

        let peer = [4; 8];
        let mut reset = packet(Opcode::ResetServerV2, peer, 0, b"");
        reset.acks = vec![0];
        reset.remote_session_id = Some(client.our_session_id());
        client.on_packet(reset).unwrap();
        assert!(
            client
                .poll_outgoing(now + Duration::from_secs(10), 8)
                .iter()
                .all(|packet| packet.packet_id != Some(0)),
            "the reset must not be retransmitted after its ack"
        );
    }

    #[test]
    fn rejects_packets_from_a_different_session() {
        let now = Instant::now();
        let mut client = ControlChannel::new(Duration::from_secs(1));
        client.queue_reset(Opcode::ResetClientV2, now);
        let mut reset = packet(Opcode::ResetServerV2, [1; 8], 0, b"");
        reset.acks = vec![0];
        reset.remote_session_id = Some(client.our_session_id());
        client.on_packet(reset).unwrap();

        let mut other = packet(Opcode::ControlV1, [2; 8], 1, b"x");
        other.acks = vec![];
        assert!(client.on_packet(other).is_err());
    }

    #[test]
    fn window_limits_in_flight_packets() {
        let now = Instant::now();
        let mut client = ControlChannel::new(Duration::from_secs(1));
        client.queue_reset(Opcode::ResetClientV2, now);
        let _ = client.poll_outgoing(now, 1);
        let peer = [5; 8];
        let mut reset = packet(Opcode::ResetServerV2, peer, 0, b"");
        reset.acks = vec![0];
        reset.remote_session_id = Some(client.our_session_id());
        client.on_packet(reset).unwrap();
        let _ = client.poll_outgoing(now, 1);

        client.queue_control(&vec![0u8; MAX_CONTROL_PAYLOAD * 10], now);
        let sent = client.poll_outgoing(now, 32);
        assert!(sent.len() <= SEND_WINDOW);
    }
}
