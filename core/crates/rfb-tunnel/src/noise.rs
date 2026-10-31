//! A thin wrapper around `boringtun`'s `Tunn`.
//!
//! It converts borrowed `TunnResult` values into lengths so the driver can copy
//! the bytes into its own device queues without holding a borrow of the
//! encryption buffer.

use std::time::Duration;

use boringtun::noise::errors::WireGuardError;
use boringtun::noise::{Tunn, TunnResult};

use crate::keys::{PresharedKey, PrivateKey, PublicKey};

/// The result of an encapsulation, decapsulation or timer step.
#[derive(Debug)]
pub(crate) enum Outcome {
    /// Nothing to do.
    Done,
    /// A WireGuard datagram of the given length is in the destination buffer.
    Network(usize),
    /// An inner IPv4 packet of the given length is in the destination buffer.
    TunnelV4(usize),
    /// An inner IPv6 packet is in the destination buffer.
    TunnelV6,
    /// `boringtun` rejected the operation.
    Error(WireGuardError),
}

/// Per-tunnel handshake and traffic counters.
#[derive(Debug, Clone, Copy, Default)]
pub(crate) struct NoiseStats {
    pub handshake_age: Option<Duration>,
    pub tx_bytes: u64,
    pub rx_bytes: u64,
}

pub(crate) struct Noise {
    tunn: Tunn,
}

impl Noise {
    pub fn new(
        private_key: &PrivateKey,
        peer_public: PublicKey,
        preshared_key: Option<&PresharedKey>,
        persistent_keepalive: Option<u16>,
    ) -> Self {
        let index = rand::random::<u32>();
        let tunn = Tunn::new(
            private_key.as_static_secret().clone(),
            peer_public.to_dalek(),
            preshared_key.map(PresharedKey::to_array),
            persistent_keepalive,
            index,
            None,
        );
        Self { tunn }
    }

    pub fn encapsulate(&mut self, packet: &[u8], dst: &mut [u8]) -> Outcome {
        convert(self.tunn.encapsulate(packet, dst))
    }

    pub fn decapsulate(&mut self, datagram: &[u8], dst: &mut [u8]) -> Outcome {
        convert(self.tunn.decapsulate(None, datagram, dst))
    }

    pub fn update_timers(&mut self, dst: &mut [u8]) -> Outcome {
        convert(self.tunn.update_timers(dst))
    }

    pub fn stats(&self) -> NoiseStats {
        let (handshake_age, tx_bytes, rx_bytes, _, _) = self.tunn.stats();
        NoiseStats {
            handshake_age,
            tx_bytes: tx_bytes as u64,
            rx_bytes: rx_bytes as u64,
        }
    }

    pub fn is_expired(&self) -> bool {
        self.tunn.is_expired()
    }
}

fn convert(result: TunnResult<'_>) -> Outcome {
    match result {
        TunnResult::Done => Outcome::Done,
        TunnResult::Err(error) => Outcome::Error(error),
        TunnResult::WriteToNetwork(packet) => Outcome::Network(packet.len()),
        TunnResult::WriteToTunnelV4(packet, _) => Outcome::TunnelV4(packet.len()),
        TunnResult::WriteToTunnelV6(_, _) => Outcome::TunnelV6,
    }
}
