//! OpenVPN data-channel AEAD framing.
//!
//! Data packet layout:
//!
//! * V1: `[opcode/key_id 1][packet id 4][tag 16][ciphertext]`
//! * V2: `[opcode/key_id 1][peer id 3][packet id 4][tag 16][ciphertext]`
//!
//! The authentication tag precedes the ciphertext. OpenVPN reserves the tag
//! directly after the explicit IV and encrypts the payload behind it
//! (`openvpn_encrypt_aead`), so the same buffer position holds the tag on the
//! wire.
//!
//! The 12-byte AEAD nonce is the 4-byte packet id followed by the 8-byte
//! implicit IV from the key schedule. The additional data is the header plus
//! the packet id, exactly as OpenVPN's `openvpn_encrypt_aead` authenticates
//! the opcode and packet id.

use aes_gcm::aead::{AeadInPlace, KeyInit};
use aes_gcm::{Aes128Gcm, Aes256Gcm, AesGcm, Nonce};
use chacha20poly1305::ChaCha20Poly1305;

/// AES-192-GCM is not exported as a convenience alias by `aes-gcm`.
type Aes192Gcm = AesGcm<aes_gcm::aes::Aes192, aes_gcm::aead::consts::U12>;

use crate::cipher::Cipher;
use crate::error::TunnelError;
use crate::keys::DataKeys;

const TAG_LEN: usize = 16;
const V1_HEADER: usize = 1;
const V2_HEADER: usize = 4;
const OPCODE_DATA_V1: u8 = 6;
const OPCODE_DATA_V2: u8 = 9;

/// Sliding 64-packet replay window for short-form data packet ids.
#[derive(Debug, Clone)]
struct PacketIdWindow {
    highest: u32,
    bitmap: u64,
    seen: bool,
}

impl PacketIdWindow {
    fn new() -> Self {
        Self {
            highest: 0,
            bitmap: 0,
            seen: false,
        }
    }

    fn check_and_update(&mut self, id: u32) -> bool {
        if id == 0 {
            return false;
        }
        if !self.seen {
            self.seen = true;
            self.highest = id;
            self.bitmap = 1;
            return true;
        }
        if id > self.highest {
            let shift = id - self.highest;
            self.bitmap = if shift >= 64 {
                1
            } else {
                (self.bitmap << shift) | 1
            };
            self.highest = id;
            return true;
        }
        if self.highest.saturating_sub(id) >= 64 {
            return false;
        }
        let bit = 1u64 << (self.highest - id);
        if self.bitmap & bit != 0 {
            return false;
        }
        self.bitmap |= bit;
        true
    }
}

/// One direction of an established data channel.
pub(crate) struct DataChannel {
    cipher: Cipher,
    outgoing: crate::keys::DirectionalKey,
    incoming: crate::keys::DirectionalKey,
    tx_packet_id: u32,
    rx_packet_id: PacketIdWindow,
    peer_id: Option<u32>,
    key_id: u8,
}

impl DataChannel {
    /// Builds a channel with key id 0. `peer_id` enables P_DATA_V2.
    pub(crate) fn new(
        cipher: Cipher,
        keys: DataKeys,
        peer_id: Option<u32>,
    ) -> Result<Self, TunnelError> {
        if let Some(peer) = peer_id
            && peer > 0x00ff_ffff
        {
            return Err(TunnelError::Protocol(
                "peer id does not fit in 24 bits".to_string(),
            ));
        }
        if keys.outgoing.cipher_key.len() != cipher.key_len()
            || keys.incoming.cipher_key.len() != cipher.key_len()
        {
            return Err(TunnelError::Protocol(
                "data key length does not match the cipher".to_string(),
            ));
        }
        Ok(Self {
            cipher,
            outgoing: keys.outgoing,
            incoming: keys.incoming,
            tx_packet_id: 0,
            rx_packet_id: PacketIdWindow::new(),
            peer_id,
            key_id: 0,
        })
    }

    #[cfg(test)]
    pub(crate) fn uses_v2(&self) -> bool {
        self.peer_id.is_some()
    }

    fn header(&self) -> Vec<u8> {
        match self.peer_id {
            Some(peer) => {
                let mut header = Vec::with_capacity(V2_HEADER);
                header.push((OPCODE_DATA_V2 << 3) | self.key_id);
                let bytes = peer.to_be_bytes();
                header.extend_from_slice(&bytes[1..4]);
                header
            }
            None => vec![(OPCODE_DATA_V1 << 3) | self.key_id],
        }
    }

    /// Encrypts one inner IPv4 packet into a P_DATA packet.
    pub(crate) fn encrypt(&mut self, inner: &[u8]) -> Result<Vec<u8>, TunnelError> {
        if inner.is_empty() {
            return Err(TunnelError::Protocol(
                "refusing to encrypt an empty inner packet".to_string(),
            ));
        }
        let packet_id = self.tx_packet_id.checked_add(1).ok_or_else(|| {
            TunnelError::Protocol("data packet id exhausted; rekey is required".to_string())
        })?;
        self.tx_packet_id = packet_id;

        let header = self.header();
        let mut additional = Vec::with_capacity(header.len() + 4);
        additional.extend_from_slice(&header);
        additional.extend_from_slice(&packet_id.to_be_bytes());
        let nonce = nonce(packet_id, &self.outgoing.implicit_iv);

        let mut buffer = inner.to_vec();
        let tag = aead_encrypt(
            self.cipher,
            &self.outgoing.cipher_key,
            &nonce,
            &additional,
            &mut buffer,
        )?;
        let mut output = Vec::with_capacity(additional.len() + TAG_LEN + buffer.len());
        output.extend_from_slice(&additional);
        output.extend_from_slice(&tag);
        output.extend_from_slice(&buffer);
        Ok(output)
    }

    /// Decrypts one P_DATA packet into an inner IPv4 packet.
    pub(crate) fn decrypt(&mut self, packet: &[u8]) -> Result<Vec<u8>, TunnelError> {
        if packet.len() < V1_HEADER + 4 + TAG_LEN {
            return Err(TunnelError::Protocol(
                "data packet is too short".to_string(),
            ));
        }
        let opcode = packet[0] >> 3;
        let key_id = packet[0] & 0x07;
        if key_id != self.key_id {
            return Err(TunnelError::Protocol(
                "data packet uses an inactive key id".to_string(),
            ));
        }
        let (header_len, peer_id) = match opcode {
            OPCODE_DATA_V1 => (V1_HEADER, None),
            OPCODE_DATA_V2 => {
                if packet.len() < V2_HEADER {
                    return Err(TunnelError::Protocol(
                        "P_DATA_V2 packet is too short".to_string(),
                    ));
                }
                let peer = (u32::from(packet[1]) << 16)
                    | (u32::from(packet[2]) << 8)
                    | u32::from(packet[3]);
                (V2_HEADER, Some(peer))
            }
            other => {
                return Err(TunnelError::Protocol(format!(
                    "unexpected data opcode {other}"
                )));
            }
        };
        match (peer_id, self.peer_id) {
            (Some(received), Some(expected)) if received != expected => {
                return Err(TunnelError::Protocol(
                    "data packet peer id mismatch".to_string(),
                ));
            }
            (Some(_), None) => {
                return Err(TunnelError::Protocol(
                    "P_DATA_V2 packet without a negotiated peer id".to_string(),
                ));
            }
            _ => {}
        }

        if packet.len() < header_len + 4 + TAG_LEN {
            return Err(TunnelError::Protocol(
                "data packet is too short".to_string(),
            ));
        }
        let packet_id = u32::from_be_bytes(
            packet[header_len..header_len + 4]
                .try_into()
                .expect("fixed slice"),
        );
        let tag_start = header_len + 4;
        let tag_end = tag_start + TAG_LEN;
        let tag = &packet[tag_start..tag_end];
        let ciphertext = &packet[tag_end..];
        if ciphertext.is_empty() {
            return Err(TunnelError::Protocol(
                "data packet has no payload".to_string(),
            ));
        }
        let additional = &packet[..tag_start];
        let nonce = nonce(packet_id, &self.incoming.implicit_iv);
        let mut buffer = ciphertext.to_vec();
        aead_decrypt(
            self.cipher,
            &self.incoming.cipher_key,
            &nonce,
            additional,
            &mut buffer,
            tag,
        )?;

        if !self.rx_packet_id.check_and_update(packet_id) {
            return Err(TunnelError::Protocol(
                "data packet replay or stale packet id".to_string(),
            ));
        }
        Ok(buffer)
    }
}

fn nonce(packet_id: u32, implicit: &[u8; 8]) -> [u8; 12] {
    let mut nonce = [0u8; 12];
    nonce[..4].copy_from_slice(&packet_id.to_be_bytes());
    nonce[4..].copy_from_slice(implicit);
    nonce
}

fn aead_encrypt(
    cipher: Cipher,
    key: &[u8],
    nonce: &[u8; 12],
    additional: &[u8],
    buffer: &mut [u8],
) -> Result<Vec<u8>, TunnelError> {
    let nonce = Nonce::from_slice(nonce);
    let tag = match cipher {
        Cipher::Aes256Gcm => Aes256Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .encrypt_in_place_detached(nonce, additional, buffer)
            .map_err(|_| TunnelError::Protocol("AES-256-GCM encryption failed".to_string()))?,
        Cipher::Aes192Gcm => Aes192Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .encrypt_in_place_detached(nonce, additional, buffer)
            .map_err(|_| TunnelError::Protocol("AES-192-GCM encryption failed".to_string()))?,
        Cipher::Aes128Gcm => Aes128Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .encrypt_in_place_detached(nonce, additional, buffer)
            .map_err(|_| TunnelError::Protocol("AES-128-GCM encryption failed".to_string()))?,
        Cipher::ChaCha20Poly1305 => ChaCha20Poly1305::new_from_slice(key)
            .map_err(|_| key_error())?
            .encrypt_in_place_detached(nonce, additional, buffer)
            .map_err(|_| {
                TunnelError::Protocol("ChaCha20-Poly1305 encryption failed".to_string())
            })?,
    };
    Ok(tag.to_vec())
}

fn aead_decrypt(
    cipher: Cipher,
    key: &[u8],
    nonce: &[u8; 12],
    additional: &[u8],
    buffer: &mut [u8],
    tag: &[u8],
) -> Result<(), TunnelError> {
    let nonce = Nonce::from_slice(nonce);
    let tag = aes_gcm::Tag::from_slice(tag);
    let result = match cipher {
        Cipher::Aes256Gcm => Aes256Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .decrypt_in_place_detached(nonce, additional, buffer, tag),
        Cipher::Aes192Gcm => Aes192Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .decrypt_in_place_detached(nonce, additional, buffer, tag),
        Cipher::Aes128Gcm => Aes128Gcm::new_from_slice(key)
            .map_err(|_| key_error())?
            .decrypt_in_place_detached(nonce, additional, buffer, tag),
        Cipher::ChaCha20Poly1305 => ChaCha20Poly1305::new_from_slice(key)
            .map_err(|_| key_error())?
            .decrypt_in_place_detached(
                nonce,
                additional,
                buffer,
                chacha20poly1305::Tag::from_slice(&tag[..]),
            ),
    };
    result.map_err(|_| TunnelError::Protocol("data packet authentication failed".to_string()))
}

fn key_error() -> TunnelError {
    TunnelError::Protocol("invalid data-channel key length".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::keys::KeySource;

    fn channels(cipher: Cipher, peer_id: Option<u32>) -> (DataChannel, DataChannel) {
        let mut source = KeySource::generate();
        source.set_server_entropy([7; 32], [8; 32]);
        let client = source.data_keys(cipher, [1; 8], [2; 8], false);
        let server = source.data_keys(cipher, [1; 8], [2; 8], true);
        (
            DataChannel::new(cipher, client, peer_id).unwrap(),
            DataChannel::new(cipher, server, peer_id).unwrap(),
        )
    }

    #[test]
    fn all_supported_ciphers_round_trip_v1_and_v2() {
        for cipher in [
            Cipher::Aes256Gcm,
            Cipher::Aes192Gcm,
            Cipher::Aes128Gcm,
            Cipher::ChaCha20Poly1305,
        ] {
            for peer_id in [None, Some(0x000102)] {
                let (mut client, mut server) = channels(cipher, peer_id);
                let packet = b"inner IPv4 packet";
                let sealed = client.encrypt(packet).unwrap();
                assert_eq!(client.uses_v2(), peer_id.is_some());
                assert_eq!(server.decrypt(&sealed).unwrap(), packet);

                let reply = b"reply";
                let sealed = server.encrypt(reply).unwrap();
                assert_eq!(client.decrypt(&sealed).unwrap(), reply);
            }
        }
    }

    #[test]
    fn rejects_tampering_replay_and_wrong_keys() {
        let (mut client, mut server) = channels(Cipher::Aes256Gcm, Some(1));
        let sealed = client.encrypt(b"payload").unwrap();
        let mut tampered = sealed.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(server.decrypt(&tampered).is_err());
        assert_eq!(server.decrypt(&sealed).unwrap(), b"payload");
        assert!(server.decrypt(&sealed).is_err(), "replay must fail");

        let (mut other, _) = channels(Cipher::Aes256Gcm, Some(1));
        assert!(other.decrypt(&sealed).is_err());
    }

    #[test]
    fn rejects_wrong_peer_id_and_key_id() {
        let (mut client, mut server) = channels(Cipher::Aes256Gcm, Some(7));
        let sealed = client.encrypt(b"payload").unwrap();
        let mut wrong_peer = sealed.clone();
        wrong_peer[3] = wrong_peer[3].wrapping_add(1);
        assert!(server.decrypt(&wrong_peer).is_err());

        let mut wrong_key = sealed.clone();
        wrong_key[0] = (OPCODE_DATA_V2 << 3) | 1;
        assert!(server.decrypt(&wrong_key).is_err());
    }

    #[test]
    fn packet_id_window_handles_reordering() {
        let mut window = PacketIdWindow::new();
        assert!(window.check_and_update(1));
        assert!(window.check_and_update(3));
        assert!(window.check_and_update(2));
        assert!(!window.check_and_update(2));
        assert!(window.check_and_update(70));
        assert!(!window.check_and_update(1));
        assert!(!window.check_and_update(0));
    }

    #[test]
    fn rejects_empty_payload() {
        let (mut client, _) = channels(Cipher::Aes256Gcm, None);
        assert!(client.encrypt(b"").is_err());
    }

    #[test]
    fn aead_wire_layout_matches_openvpn_reference() {
        // A separately constructed OpenVPN packet pins the tag position and
        // the additional data: [opcode][packet id][tag][ciphertext].
        let mut source = KeySource::generate();
        source.set_server_entropy([7; 32], [8; 32]);
        let keys = source.data_keys(Cipher::Aes256Gcm, [1; 8], [2; 8], false);
        let key = keys.outgoing.cipher_key.clone();
        let implicit = keys.outgoing.implicit_iv;
        let mut client = DataChannel::new(Cipher::Aes256Gcm, keys, None).unwrap();

        let inner = b"an inner IPv4 packet";
        let sealed = client.encrypt(inner).unwrap();

        let mut header = vec![OPCODE_DATA_V1 << 3];
        header.extend_from_slice(&1u32.to_be_bytes());
        let mut manual = inner.to_vec();
        let tag = aes_gcm::Aes256Gcm::new_from_slice(&key)
            .unwrap()
            .encrypt_in_place_detached(
                aes_gcm::Nonce::from_slice(&nonce(1, &implicit)),
                &header,
                &mut manual,
            )
            .unwrap();

        assert_eq!(&sealed[..1], &header[..1]);
        assert_eq!(&sealed[1..5], &header[1..5]);
        assert_eq!(
            &sealed[5..21],
            tag.as_slice(),
            "the tag precedes the ciphertext"
        );
        assert_eq!(&sealed[21..], manual.as_slice());

        // The reference packet decrypts through the mirroring channel.
        let server_keys = source.data_keys(Cipher::Aes256Gcm, [1; 8], [2; 8], true);
        let mut server = DataChannel::new(Cipher::Aes256Gcm, server_keys, None).unwrap();
        assert_eq!(server.decrypt(&sealed).unwrap(), inner);
    }
}
