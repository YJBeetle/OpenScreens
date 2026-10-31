//! OpenVPN static keys, `tls-auth`/`tls-crypt` wrapping and replay windows.
//!
//! The wire layouts follow OpenVPN 2.6:
//!
//! * `tls-auth`: `[opcode+sid][HMAC-SHA1][8-byte replay id][ack...][pid][payload]`
//! * `tls-crypt`: `[opcode+sid][8-byte replay id][HMAC-SHA256 tag][AES-256-CTR ciphertext]`
//!
//! The replay id is `[u32 sequence][u32 timestamp]` in network order
//! (`packet_id_write(..., long_form=true, prepend=true)` writes the id in
//! front of the time). The tls-crypt tag's first 16 bytes are the AES-CTR IV,
//! exactly as OpenVPN derives it. For `tls-auth` OpenVPN hashes the replay id
//! followed by the whole control packet and writes the tag between the session
//! id and the replay id.

use aes::Aes256;
use aes::cipher::{KeyIvInit, StreamCipher};
use ctr::Ctr128BE;
use hmac::{Hmac, Mac};
use sha1::Sha1;
use sha2::{Sha256, Sha512};

use crate::cipher::AuthDigest;
use crate::config::{TlsWrapConfig, TlsWrapMode};
use crate::error::{ConfigError, TunnelError};

type HmacSha1 = Hmac<Sha1>;
type HmacSha256 = Hmac<Sha256>;
type HmacSha512 = Hmac<Sha512>;
type Aes256Ctr = Ctr128BE<Aes256>;

/// Session id size in bytes.
pub const SESSION_ID_SIZE: usize = 8;
/// Header (opcode/key id) plus session id.
const HEADER_SIZE: usize = 1 + SESSION_ID_SIZE;
const REPLAY_ID_SIZE: usize = 8;
#[cfg(test)]
const SHA1_SIZE: usize = 20;
const SHA256_SIZE: usize = 32;
const AES256_KEY_SIZE: usize = 32;

/// A 2048-bit OpenVPN static key (`tls-auth`/`tls-crypt` file).
#[derive(Clone)]
pub struct StaticKey {
    bytes: [u8; 256],
}

impl StaticKey {
    /// Parses the PEM-armoured or bare-hex static key text.
    pub fn parse(text: &str, directive: &'static str) -> Result<Self, ConfigError> {
        let mut hex = String::with_capacity(512);
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with("-----") {
                continue;
            }
            for ch in line.chars() {
                if ch.is_ascii_hexdigit() {
                    hex.push(ch);
                } else if !ch.is_whitespace() {
                    return Err(ConfigError::Invalid {
                        directive,
                        detail: "the static key contains a non-hex character".to_string(),
                    });
                }
            }
        }
        if hex.len() != 512 {
            return Err(ConfigError::Invalid {
                directive,
                detail: format!(
                    "expected a 2048-bit static key (512 hex digits), found {} digits",
                    hex.len()
                ),
            });
        }
        let mut bytes = [0u8; 256];
        for (index, slot) in bytes.iter_mut().enumerate() {
            let pair = &hex[index * 2..index * 2 + 2];
            *slot = u8::from_str_radix(pair, 16).map_err(|_| ConfigError::Invalid {
                directive,
                detail: "the static key is not valid hex".to_string(),
            })?;
        }
        Ok(Self { bytes })
    }

    fn key0(&self) -> &[u8] {
        &self.bytes[0..128]
    }

    fn key1(&self) -> &[u8] {
        &self.bytes[128..256]
    }

    /// Cipher material of one direction (`struct key.cipher`, 64 bytes).
    fn cipher(&self, index: usize) -> &[u8] {
        let key = if index == 0 { self.key0() } else { self.key1() };
        &key[0..64]
    }

    /// HMAC material of one direction (`struct key.hmac`, 64 bytes).
    fn hmac(&self, index: usize) -> &[u8] {
        let key = if index == 0 { self.key0() } else { self.key1() };
        &key[64..128]
    }
}

impl std::fmt::Debug for StaticKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("StaticKey(<redacted>)")
    }
}

/// Replay protection for long-form control-channel packet ids.
#[derive(Debug, Clone)]
pub(crate) struct ReplayWindow {
    last_time: u32,
    highest: u32,
    bitmap: u64,
}

impl ReplayWindow {
    pub(crate) fn new() -> Self {
        Self {
            last_time: 0,
            highest: 0,
            bitmap: 0,
        }
    }

    /// Checks and records `(time, sequence)`. Returns false for replays and
    /// timestamps older than the newest accepted one.
    pub(crate) fn check_and_update(&mut self, time: u32, sequence: u32) -> bool {
        if sequence == 0 {
            return false;
        }
        if time > self.last_time {
            self.last_time = time;
            self.highest = sequence;
            self.bitmap = 1;
            return true;
        }
        if time < self.last_time {
            return false;
        }
        if sequence > self.highest {
            let shift = sequence - self.highest;
            self.bitmap = if shift >= 64 {
                1
            } else {
                (self.bitmap << shift) | 1
            };
            self.highest = sequence;
            return true;
        }
        let lower = self.highest.saturating_sub(63);
        if sequence < lower {
            return false;
        }
        let bit = 1u64 << (self.highest - sequence);
        if self.bitmap & bit != 0 {
            return false;
        }
        self.bitmap |= bit;
        true
    }
}

/// Monotonic long-form replay id sender.
#[derive(Debug, Clone)]
pub(crate) struct ReplaySender {
    time: u32,
    sequence: u32,
}

impl ReplaySender {
    fn new() -> Self {
        Self::at(unix_time())
    }

    fn at(time: u32) -> Self {
        Self { time, sequence: 0 }
    }

    fn next(&mut self) -> [u8; REPLAY_ID_SIZE] {
        if self.sequence == u32::MAX {
            self.time = unix_time().max(self.time.saturating_add(1));
            self.sequence = 0;
        }
        self.sequence += 1;
        let mut output = [0u8; REPLAY_ID_SIZE];
        output[0..4].copy_from_slice(&self.sequence.to_be_bytes());
        output[4..8].copy_from_slice(&self.time.to_be_bytes());
        output
    }
}

fn unix_time() -> u32 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs() as u32)
        .unwrap_or(1)
}

/// The control-channel wrapping applied to every control packet.
pub(crate) enum ControlWrap {
    /// No `tls-auth`/`tls-crypt`.
    None,
    /// HMAC-SHA1/SHA256/SHA512 authentication only.
    Auth {
        digest: AuthDigest,
        out_key: Vec<u8>,
        in_key: Vec<u8>,
        tx: ReplaySender,
        rx: ReplayWindow,
    },
    /// HMAC-SHA256 + AES-256-CTR.
    Crypt {
        out_cipher: [u8; AES256_KEY_SIZE],
        out_hmac: [u8; SHA256_SIZE],
        in_cipher: [u8; AES256_KEY_SIZE],
        in_hmac: [u8; SHA256_SIZE],
        tx: ReplaySender,
        rx: ReplayWindow,
    },
}

impl std::fmt::Debug for ControlWrap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::None => f.write_str("ControlWrap::None"),
            Self::Auth { .. } => f.write_str("ControlWrap::Auth(<redacted>)"),
            Self::Crypt { .. } => f.write_str("ControlWrap::Crypt(<redacted>)"),
        }
    }
}

impl ControlWrap {
    /// Builds wrapping state from parsed config, static key text and the
    /// profile's `auth` digest (which selects the `tls-auth` HMAC).
    pub(crate) fn from_config(
        config: Option<&TlsWrapConfig>,
        key: Option<&StaticKey>,
        digest: AuthDigest,
    ) -> Result<Self, ConfigError> {
        let Some(config) = config else {
            return Ok(Self::None);
        };
        let key = key.ok_or(ConfigError::Missing("tls key"))?;
        match config.mode {
            TlsWrapMode::Auth => {
                let (out, input) = match config.direction {
                    Some(1) => (1, 0),
                    Some(0) => (0, 1),
                    None => (0, 0),
                    Some(other) => {
                        return Err(ConfigError::Invalid {
                            directive: "tls-auth",
                            detail: format!("key direction {other} is not 0 or 1"),
                        });
                    }
                };
                Ok(Self::Auth {
                    digest,
                    out_key: auth_key(key.hmac(out), digest),
                    in_key: auth_key(key.hmac(input), digest),
                    tx: ReplaySender::new(),
                    rx: ReplayWindow::new(),
                })
            }
            TlsWrapMode::Crypt => Ok(Self::Crypt {
                // OpenVPN's tls-crypt client always uses the inverse direction.
                out_cipher: cipher_key::<AES256_KEY_SIZE>(key.cipher(1)),
                out_hmac: hmac_key::<SHA256_SIZE>(key.hmac(1)),
                in_cipher: cipher_key::<AES256_KEY_SIZE>(key.cipher(0)),
                in_hmac: hmac_key::<SHA256_SIZE>(key.hmac(0)),
                tx: ReplaySender::new(),
                rx: ReplayWindow::new(),
            }),
        }
    }

    /// Wraps `packet` (`[opcode+sid][ack...][pid][payload]`).
    pub(crate) fn wrap(&mut self, packet: &[u8]) -> Result<Vec<u8>, TunnelError> {
        if packet.len() < HEADER_SIZE {
            return Err(TunnelError::Protocol(
                "control packet is shorter than its header".to_string(),
            ));
        }
        match self {
            Self::None => Ok(packet.to_vec()),
            Self::Auth {
                digest,
                out_key,
                tx,
                ..
            } => {
                let replay = tx.next();
                // OpenVPN prepends the replay id, prepends the HMAC over it
                // and the packet, then swaps [hmac, replay] behind the header.
                let tag = auth_hmac(*digest, out_key, &[&replay, packet])?;
                let mut output = Vec::with_capacity(packet.len() + REPLAY_ID_SIZE + tag.len());
                output.extend_from_slice(&packet[..HEADER_SIZE]);
                output.extend_from_slice(&tag);
                output.extend_from_slice(&replay);
                output.extend_from_slice(&packet[HEADER_SIZE..]);
                Ok(output)
            }
            Self::Crypt {
                out_cipher,
                out_hmac,
                tx,
                ..
            } => {
                let replay = tx.next();
                let mut mac = HmacSha256::new_from_slice(out_hmac)
                    .map_err(|_| TunnelError::Protocol("invalid tls-crypt key".to_string()))?;
                mac.update(&packet[..HEADER_SIZE]);
                mac.update(&replay);
                mac.update(&packet[HEADER_SIZE..]);
                let tag = mac.finalize().into_bytes();

                let mut cipher = Aes256Ctr::new_from_slices(out_cipher, &tag[..16])
                    .map_err(|_| TunnelError::Protocol("invalid tls-crypt key".to_string()))?;
                let mut ciphertext = packet[HEADER_SIZE..].to_vec();
                cipher.apply_keystream(&mut ciphertext);

                let mut output = Vec::with_capacity(
                    HEADER_SIZE + REPLAY_ID_SIZE + SHA256_SIZE + ciphertext.len(),
                );
                output.extend_from_slice(&packet[..HEADER_SIZE]);
                output.extend_from_slice(&replay);
                output.extend_from_slice(&tag);
                output.extend_from_slice(&ciphertext);
                Ok(output)
            }
        }
    }

    /// Verifies and unwraps an outer control packet.
    pub(crate) fn unwrap(&mut self, packet: &[u8]) -> Result<Vec<u8>, TunnelError> {
        match self {
            Self::None => {
                if packet.len() < HEADER_SIZE {
                    return Err(TunnelError::Protocol(
                        "control packet is shorter than its header".to_string(),
                    ));
                }
                Ok(packet.to_vec())
            }
            Self::Auth {
                digest, in_key, rx, ..
            } => {
                let tag_len = digest.output_len();
                let prefix = HEADER_SIZE + tag_len + REPLAY_ID_SIZE;
                if packet.len() < prefix {
                    return Err(TunnelError::Protocol(
                        "tls-auth packet is too short".to_string(),
                    ));
                }
                let tag = &packet[HEADER_SIZE..HEADER_SIZE + tag_len];
                let replay = &packet[HEADER_SIZE + tag_len..prefix];
                auth_hmac_verify(
                    *digest,
                    in_key,
                    &[replay, &packet[..HEADER_SIZE], &packet[prefix..]],
                    tag,
                )?;

                let (time, sequence) = replay_id(replay);
                if !rx.check_and_update(time, sequence) {
                    return Err(TunnelError::Protocol(
                        "tls-auth replay or stale packet".to_string(),
                    ));
                }

                let mut output = Vec::with_capacity(packet.len() - REPLAY_ID_SIZE - tag_len);
                output.extend_from_slice(&packet[..HEADER_SIZE]);
                output.extend_from_slice(&packet[prefix..]);
                Ok(output)
            }
            Self::Crypt {
                in_cipher,
                in_hmac,
                rx,
                ..
            } => {
                let prefix = HEADER_SIZE + REPLAY_ID_SIZE;
                let header_size = prefix + SHA256_SIZE;
                if packet.len() < header_size {
                    return Err(TunnelError::Protocol(
                        "tls-crypt packet is too short".to_string(),
                    ));
                }
                let replay = &packet[HEADER_SIZE..prefix];
                let tag = &packet[prefix..header_size];
                let ciphertext = &packet[header_size..];

                let mut cipher = Aes256Ctr::new_from_slices(in_cipher, &tag[..16])
                    .map_err(|_| TunnelError::Protocol("invalid tls-crypt key".to_string()))?;
                let mut plaintext = ciphertext.to_vec();
                cipher.apply_keystream(&mut plaintext);

                let mut mac = HmacSha256::new_from_slice(in_hmac)
                    .map_err(|_| TunnelError::Protocol("invalid tls-crypt key".to_string()))?;
                mac.update(&packet[..prefix]);
                mac.update(&plaintext);
                mac.verify_slice(tag)
                    .map_err(|_| TunnelError::Protocol("tls-crypt HMAC mismatch".to_string()))?;

                let (time, sequence) = replay_id(replay);
                if !rx.check_and_update(time, sequence) {
                    return Err(TunnelError::Protocol(
                        "tls-crypt replay or stale packet".to_string(),
                    ));
                }

                let mut output = Vec::with_capacity(HEADER_SIZE + plaintext.len());
                output.extend_from_slice(&packet[..HEADER_SIZE]);
                output.extend_from_slice(&plaintext);
                Ok(output)
            }
        }
    }
}

fn replay_id(bytes: &[u8]) -> (u32, u32) {
    let sequence = u32::from_be_bytes(bytes[0..4].try_into().unwrap_or([0; 4]));
    let time = u32::from_be_bytes(bytes[4..8].try_into().unwrap_or([0; 4]));
    (time, sequence)
}

/// `tls-auth` uses the first digest-sized bytes of the 64-byte HMAC half.
fn auth_key(source: &[u8], digest: AuthDigest) -> Vec<u8> {
    source[..digest.output_len()].to_vec()
}

fn auth_hmac(digest: AuthDigest, key: &[u8], parts: &[&[u8]]) -> Result<Vec<u8>, TunnelError> {
    let invalid = || TunnelError::Protocol("invalid tls-auth key".to_string());
    Ok(match digest {
        AuthDigest::Sha1 => {
            let mut mac = HmacSha1::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.finalize().into_bytes().to_vec()
        }
        AuthDigest::Sha256 => {
            let mut mac = HmacSha256::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.finalize().into_bytes().to_vec()
        }
        AuthDigest::Sha512 => {
            let mut mac = HmacSha512::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.finalize().into_bytes().to_vec()
        }
    })
}

fn auth_hmac_verify(
    digest: AuthDigest,
    key: &[u8],
    parts: &[&[u8]],
    tag: &[u8],
) -> Result<(), TunnelError> {
    let mismatch = || TunnelError::Protocol("tls-auth HMAC mismatch".to_string());
    let invalid = || TunnelError::Protocol("invalid tls-auth key".to_string());
    match digest {
        AuthDigest::Sha1 => {
            let mut mac = HmacSha1::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.verify_slice(tag).map_err(|_| mismatch())
        }
        AuthDigest::Sha256 => {
            let mut mac = HmacSha256::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.verify_slice(tag).map_err(|_| mismatch())
        }
        AuthDigest::Sha512 => {
            let mut mac = HmacSha512::new_from_slice(key).map_err(|_| invalid())?;
            for part in parts {
                mac.update(part);
            }
            mac.verify_slice(tag).map_err(|_| mismatch())
        }
    }
}

fn hmac_key<const N: usize>(source: &[u8]) -> [u8; N] {
    let mut output = [0u8; N];
    output.copy_from_slice(&source[..N]);
    output
}

fn cipher_key<const N: usize>(source: &[u8]) -> [u8; N] {
    let mut output = [0u8; N];
    output.copy_from_slice(&source[..N]);
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key_text(seed: u8) -> String {
        let mut text = String::new();
        for index in 0..16 {
            for column in 0..16 {
                let byte = seed.wrapping_add((index * 16 + column) as u8);
                text.push_str(&format!("{byte:02x}"));
            }
            text.push('\n');
        }
        text
    }

    fn wrap(mode: TlsWrapMode) -> ControlWrap {
        let key = StaticKey::parse(&key_text(7), "tls-crypt").unwrap();
        ControlWrap::from_config(
            Some(&TlsWrapConfig {
                mode,
                material: crate::config::Material::Inline(String::new()),
                direction: None,
            }),
            Some(&key),
            AuthDigest::Sha1,
        )
        .unwrap()
    }

    #[test]
    fn parses_a_static_key_and_rejects_bad_length() {
        let key = StaticKey::parse(&key_text(1), "tls-auth").unwrap();
        assert_eq!(format!("{key:?}"), "StaticKey(<redacted>)");
        assert!(StaticKey::parse("00".repeat(255).as_str(), "tls-auth").is_err());
        assert!(StaticKey::parse("zz", "tls-auth").is_err());
    }

    #[test]
    fn tls_auth_round_trips_and_rejects_tampering() {
        let mut sender = wrap(TlsWrapMode::Auth);
        let mut receiver = wrap(TlsWrapMode::Auth);
        // The same static key without explicit direction is bidirectional.
        let packet = b"\x20abcd1234\x00\x00\x00\x00\x01payload";
        let sealed = sender.wrap(packet).unwrap();
        assert!(sealed.len() > packet.len());
        let opened = receiver.unwrap(&sealed).unwrap();
        assert_eq!(opened, packet);

        let mut tampered = sealed.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 1;
        assert!(receiver.unwrap(&tampered).is_err());

        // Replay of the same packet is rejected.
        assert!(receiver.unwrap(&sealed).is_err());
    }

    #[test]
    fn tls_crypt_round_trips_and_uses_inverse_direction() {
        let key = StaticKey::parse(&key_text(7), "tls-crypt").unwrap();
        let mut sender = ControlWrap::Crypt {
            out_cipher: cipher_key(key.cipher(1)),
            out_hmac: hmac_key(key.hmac(1)),
            in_cipher: cipher_key(key.cipher(0)),
            in_hmac: hmac_key(key.hmac(0)),
            tx: ReplaySender::new(),
            rx: ReplayWindow::new(),
        };
        let mut receiver = ControlWrap::Crypt {
            out_cipher: cipher_key(key.cipher(0)),
            out_hmac: hmac_key(key.hmac(0)),
            in_cipher: cipher_key(key.cipher(1)),
            in_hmac: hmac_key(key.hmac(1)),
            tx: ReplaySender::new(),
            rx: ReplayWindow::new(),
        };
        let packet = b"\x20abcd1234\x00\x00\x00\x00\x01payload";
        let sealed = sender.wrap(packet).unwrap();
        assert_eq!(&sealed[..9], &packet[..9]);
        let opened = receiver.unwrap(&sealed).unwrap();
        assert_eq!(opened, packet);

        let mut bad = sealed.clone();
        bad[60] ^= 0x80;
        assert!(receiver.unwrap(&bad).is_err());
        assert!(receiver.unwrap(&sealed).is_err(), "replay must be rejected");
    }

    #[test]
    fn wrong_direction_key_fails() {
        let key = StaticKey::parse(&key_text(3), "tls-auth").unwrap();
        let mut client = ControlWrap::from_config(
            Some(&TlsWrapConfig {
                mode: TlsWrapMode::Auth,
                material: crate::config::Material::Inline(String::new()),
                direction: Some(1),
            }),
            Some(&key),
            AuthDigest::Sha1,
        )
        .unwrap();
        let mut server = ControlWrap::from_config(
            Some(&TlsWrapConfig {
                mode: TlsWrapMode::Auth,
                material: crate::config::Material::Inline(String::new()),
                direction: Some(1),
            }),
            Some(&key),
            AuthDigest::Sha1,
        )
        .unwrap();
        let packet = b"\x20abcd1234\x00\x00\x00\x00\x01payload";
        let sealed = client.wrap(packet).unwrap();
        // Both configured as clients: the HMAC key directions are mirrored,
        // so the receiver must reject the tag.
        assert!(server.unwrap(&sealed).is_err());
    }

    #[test]
    fn replay_window_accepts_reordering_and_rejects_replays() {
        let mut window = ReplayWindow::new();
        assert!(window.check_and_update(10, 1));
        assert!(window.check_and_update(10, 3));
        assert!(window.check_and_update(10, 2));
        assert!(!window.check_and_update(10, 2));
        assert!(!window.check_and_update(9, 4));
        assert!(window.check_and_update(11, 1));
        assert!(!window.check_and_update(11, 1));
    }

    #[test]
    fn tls_auth_matches_openvpn_wire_and_hmac_layout() {
        let key = StaticKey::parse(&key_text(7), "tls-auth").unwrap();
        let mut sender = ControlWrap::from_config(
            Some(&TlsWrapConfig {
                mode: TlsWrapMode::Auth,
                material: crate::config::Material::Inline(String::new()),
                direction: Some(0),
            }),
            Some(&key),
            AuthDigest::Sha1,
        )
        .unwrap();
        let mut receiver = ControlWrap::from_config(
            Some(&TlsWrapConfig {
                mode: TlsWrapMode::Auth,
                material: crate::config::Material::Inline(String::new()),
                direction: Some(1),
            }),
            Some(&key),
            AuthDigest::Sha1,
        )
        .unwrap();

        let header = [0x38u8, 1, 2, 3, 4, 5, 6, 7, 8];
        let mut packet = header.to_vec();
        packet.extend_from_slice(b"\x00\x00\x00\x00\x00rest-of-control-packet");
        let sealed = sender.wrap(&packet).unwrap();

        assert_eq!(&sealed[..9], &header, "opcode and session id stay in place");
        let hmac = &sealed[9..29];
        let replay = &sealed[29..37];
        assert_eq!(&sealed[37..], &packet[9..]);
        assert_eq!(u32::from_be_bytes(replay[..4].try_into().unwrap()), 1);
        assert!(
            u32::from_be_bytes(replay[4..].try_into().unwrap()) > 1_700_000_000,
            "the replay id is [sequence][timestamp]"
        );

        let mut expected = HmacSha1::new_from_slice(&key.hmac(0)[..SHA1_SIZE]).unwrap();
        expected.update(replay);
        expected.update(&header);
        expected.update(&packet[9..]);
        assert_eq!(hmac, expected.finalize().into_bytes().as_slice());

        assert_eq!(receiver.unwrap(&sealed).unwrap(), packet);
    }
}
