//! An in-memory `smoltcp` device: this is the "virtual tun" of the tunnel.
//!
//! Received IP packets are pushed into `rx` by the driver and transmitted IP
//! packets are collected from `tx`. Nothing here touches an operating system
//! network interface.

use std::collections::VecDeque;

use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;

/// A packet queue that implements [`smoltcp::phy::Device`] with an IP medium.
pub struct QueueDevice {
    rx: VecDeque<Vec<u8>>,
    tx: VecDeque<Vec<u8>>,
    mtu: usize,
    max_burst: usize,
}

impl QueueDevice {
    /// Creates a device with the given inner MTU.
    pub fn new(mtu: u16) -> Self {
        Self {
            rx: VecDeque::new(),
            tx: VecDeque::new(),
            mtu: usize::from(mtu),
            max_burst: 64,
        }
    }

    /// Queues a received IP packet for the stack.
    pub fn push_rx(&mut self, packet: Vec<u8>) {
        self.rx.push_back(packet);
    }

    /// Takes the next IP packet produced by the stack.
    pub fn pop_tx(&mut self) -> Option<Vec<u8>> {
        self.tx.pop_front()
    }

    /// Number of received packets waiting for the stack.
    pub fn pending_rx(&self) -> usize {
        self.rx.len()
    }

    /// Number of transmitted packets waiting for the driver.
    pub fn pending_tx(&self) -> usize {
        self.tx.len()
    }

    /// Inner MTU in bytes.
    pub fn mtu(&self) -> usize {
        self.mtu
    }
}

/// A received packet moved out of the queue.
pub struct QueuedRxToken(Vec<u8>);

impl RxToken for QueuedRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

/// A transmit token that appends to the queue when consumed.
pub struct QueuedTxToken<'a>(&'a mut VecDeque<Vec<u8>>);

impl TxToken for QueuedTxToken<'_> {
    fn consume<R, F>(self, len: usize, f: F) -> R
    where
        F: FnOnce(&mut [u8]) -> R,
    {
        let mut buffer = vec![0u8; len];
        let result = f(&mut buffer);
        self.0.push_back(buffer);
        result
    }
}

impl Device for QueueDevice {
    type RxToken<'a> = QueuedRxToken;
    type TxToken<'a> = QueuedTxToken<'a>;

    fn receive(&mut self, _timestamp: Instant) -> Option<(Self::RxToken<'_>, Self::TxToken<'_>)> {
        let packet = self.rx.pop_front()?;
        Some((QueuedRxToken(packet), QueuedTxToken(&mut self.tx)))
    }

    fn transmit(&mut self, _timestamp: Instant) -> Option<Self::TxToken<'_>> {
        Some(QueuedTxToken(&mut self.tx))
    }

    fn capabilities(&self) -> DeviceCapabilities {
        let mut caps = DeviceCapabilities::default();
        caps.medium = Medium::Ip;
        caps.max_transmission_unit = self.mtu;
        caps.max_burst_size = Some(self.max_burst);
        caps
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use smoltcp::phy::Device;

    #[test]
    fn reports_ip_medium_and_mtu() {
        let device = QueueDevice::new(1280);
        let caps = device.capabilities();
        assert_eq!(caps.medium, Medium::Ip);
        assert_eq!(caps.max_transmission_unit, 1280);
        assert_eq!(caps.max_burst_size, Some(64));
        assert_eq!(caps.ip_mtu(), 1280);
    }

    #[test]
    fn queues_packets_in_both_directions() {
        let mut device = QueueDevice::new(1420);
        device.push_rx(vec![1, 2, 3]);
        assert_eq!(device.pending_rx(), 1);

        let (rx, _tx) = device.receive(Instant::ZERO).unwrap();
        assert_eq!(rx.consume(|packet| packet.to_vec()), vec![1, 2, 3]);
        assert_eq!(device.pending_rx(), 0);

        let tx = device.transmit(Instant::ZERO).unwrap();
        tx.consume(4, |buffer| buffer.copy_from_slice(b"pack"));
        assert_eq!(device.pending_tx(), 1);
        assert_eq!(device.pop_tx().unwrap(), b"pack");
        assert!(device.pop_tx().is_none());
    }
}
