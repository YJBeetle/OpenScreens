//! In-memory smoltcp device: the virtual tun of the OpenVPN data plane.

use std::collections::VecDeque;

use smoltcp::phy::{Device, DeviceCapabilities, Medium, RxToken, TxToken};
use smoltcp::time::Instant;

/// A packet queue implementing [`smoltcp::phy::Device`] with an IP medium.
pub(crate) struct QueueDevice {
    rx: VecDeque<Vec<u8>>,
    tx: VecDeque<Vec<u8>>,
    mtu: usize,
    max_burst: usize,
}

impl QueueDevice {
    pub(crate) fn new(mtu: u16) -> Self {
        Self {
            rx: VecDeque::new(),
            tx: VecDeque::new(),
            mtu: usize::from(mtu),
            max_burst: 64,
        }
    }

    pub(crate) fn push_rx(&mut self, packet: Vec<u8>) {
        self.rx.push_back(packet);
    }

    pub(crate) fn pop_tx(&mut self) -> Option<Vec<u8>> {
        self.tx.pop_front()
    }

    #[cfg(test)]
    pub(crate) fn pending_rx(&self) -> usize {
        self.rx.len()
    }
}

pub(crate) struct QueuedRxToken(Vec<u8>);

impl RxToken for QueuedRxToken {
    fn consume<R, F>(self, f: F) -> R
    where
        F: FnOnce(&[u8]) -> R,
    {
        f(&self.0)
    }
}

pub(crate) struct QueuedTxToken<'a>(&'a mut VecDeque<Vec<u8>>);

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
    fn queues_packets_in_both_directions() {
        let mut device = QueueDevice::new(1400);
        assert_eq!(device.capabilities().medium, Medium::Ip);
        assert_eq!(device.capabilities().max_transmission_unit, 1400);

        device.push_rx(vec![1, 2, 3]);
        assert_eq!(device.pending_rx(), 1);
        let (rx, _tx) = device.receive(Instant::ZERO).unwrap();
        assert_eq!(rx.consume(|packet| packet.to_vec()), vec![1, 2, 3]);

        let tx = device.transmit(Instant::ZERO).unwrap();
        tx.consume(4, |buffer| buffer.copy_from_slice(b"pack"));
        assert_eq!(device.pop_tx().unwrap(), b"pack");
    }
}
