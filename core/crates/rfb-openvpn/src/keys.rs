//! OpenVPN key-method-2 entropy and data-channel key derivation.
//!
//! OpenVPN derives its data keys with the TLS 1.0 PRF (MD5 + SHA1), not with
//! the TLS exporter, unless both peers advertise `IV_PROTO_TLS_KEY_EXPORT`.
//! This client deliberately does not advertise the exporter, so the legacy
//! PRF path below is what a 2.4+ server will use.
//!
//! `master = PRF(pre_master, "OpenVPN master secret" || client.random1 ||
//! server.random1)` and `key2 = PRF(master, "OpenVPN key expansion" ||
//! client.random2 || server.random2 || client_sid || server_sid)`.

use std::fmt;

use hmac::{Hmac, Mac};
use md5::Md5;
use rand::Rng;
use sha1::Sha1;
use zeroize::Zeroize;

use crate::cipher::Cipher;

type HmacMd5 = Hmac<Md5>;
type HmacSha1 = Hmac<Sha1>;

/// TLS 1.0 PRF output used by OpenVPN's key expansion.
pub(crate) fn tls1_prf(secret: &[u8], seed: &[u8], output: &mut [u8]) {
    let half = secret.len().div_ceil(2);
    let s1 = &secret[..half];
    let s2 = &secret[secret.len() - half..];

    let mut md5 = vec![0u8; output.len()];
    p_hash_md5(s1, seed, &mut md5);
    let mut sha1 = vec![0u8; output.len()];
    p_hash_sha1(s2, seed, &mut sha1);

    for (index, byte) in output.iter_mut().enumerate() {
        *byte = md5[index] ^ sha1[index];
    }
    md5.zeroize();
    sha1.zeroize();
}

fn p_hash_md5(secret: &[u8], seed: &[u8], output: &mut [u8]) {
    let mut a = hmac_md5(secret, seed);
    let mut written = 0usize;
    while written < output.len() {
        let mut input = Vec::with_capacity(a.len() + seed.len());
        input.extend_from_slice(&a);
        input.extend_from_slice(seed);
        let block = hmac_md5(secret, &input);
        let take = block.len().min(output.len() - written);
        output[written..written + take].copy_from_slice(&block[..take]);
        written += take;
        a = hmac_md5(secret, &a);
        input.zeroize();
    }
    a.zeroize();
}

fn p_hash_sha1(secret: &[u8], seed: &[u8], output: &mut [u8]) {
    let mut a = hmac_sha1(secret, seed);
    let mut written = 0usize;
    while written < output.len() {
        let mut input = Vec::with_capacity(a.len() + seed.len());
        input.extend_from_slice(&a);
        input.extend_from_slice(seed);
        let block = hmac_sha1(secret, &input);
        let take = block.len().min(output.len() - written);
        output[written..written + take].copy_from_slice(&block[..take]);
        written += take;
        a = hmac_sha1(secret, &a);
        input.zeroize();
    }
    a.zeroize();
}

fn hmac_md5(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacMd5::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn hmac_sha1(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha1::new_from_slice(key).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

/// Client-side key-method-2 entropy.
#[derive(Clone)]
pub(crate) struct KeySource {
    pre_master: [u8; 48],
    client_random1: [u8; 32],
    client_random2: [u8; 32],
    server_random1: [u8; 32],
    server_random2: [u8; 32],
}

impl KeySource {
    /// Generates fresh client entropy. Server values are zero until
    /// [`Self::set_server_entropy`] is called.
    pub(crate) fn generate() -> Self {
        let mut source = Self {
            pre_master: [0u8; 48],
            client_random1: [0u8; 32],
            client_random2: [0u8; 32],
            server_random1: [0u8; 32],
            server_random2: [0u8; 32],
        };
        let mut rng = rand::rng();
        rng.fill_bytes(&mut source.pre_master);
        rng.fill_bytes(&mut source.client_random1);
        rng.fill_bytes(&mut source.client_random2);
        source
    }

    /// Client key-method-2 entropy as written to the TLS stream.
    pub(crate) fn client_entropy(&self) -> Vec<u8> {
        let mut output = Vec::with_capacity(48 + 32 + 32);
        output.extend_from_slice(&self.pre_master);
        output.extend_from_slice(&self.client_random1);
        output.extend_from_slice(&self.client_random2);
        output
    }

    /// Records the server's random1/random2 from its key-method message.
    pub(crate) fn set_server_entropy(&mut self, random1: [u8; 32], random2: [u8; 32]) {
        self.server_random1 = random1;
        self.server_random2 = random2;
    }

    pub(crate) fn has_server_entropy(&self) -> bool {
        self.server_random1 != [0u8; 32] || self.server_random2 != [0u8; 32]
    }

    fn master_secret(&self) -> [u8; 48] {
        let mut seed = Vec::with_capacity(21 + 32 + 32);
        seed.extend_from_slice(b"OpenVPN master secret");
        seed.extend_from_slice(&self.client_random1);
        seed.extend_from_slice(&self.server_random1);
        let mut master = [0u8; 48];
        tls1_prf(&self.pre_master, &seed, &mut master);
        seed.zeroize();
        master
    }

    /// The 256-byte `key2` output, for tests and for the data channel.
    pub(crate) fn key2(&self, client_sid: [u8; 8], server_sid: [u8; 8]) -> [u8; 256] {
        let master = self.master_secret();
        let mut seed = Vec::with_capacity(23 + 32 + 32 + 8 + 8);
        seed.extend_from_slice(b"OpenVPN key expansion");
        seed.extend_from_slice(&self.client_random2);
        seed.extend_from_slice(&self.server_random2);
        seed.extend_from_slice(&client_sid);
        seed.extend_from_slice(&server_sid);
        let mut key2 = [0u8; 256];
        tls1_prf(&master, &seed, &mut key2);
        seed.zeroize();
        master_zeroize(master);
        key2
    }

    /// Derives directional AEAD keys. `server_role` selects OpenVPN's inverse
    /// key direction; the client encrypts with key[0] and decrypts with key[1].
    pub(crate) fn data_keys(
        &self,
        cipher: Cipher,
        client_sid: [u8; 8],
        server_sid: [u8; 8],
        server_role: bool,
    ) -> DataKeys {
        let key2 = self.key2(client_sid, server_sid);
        let (outgoing, incoming) = if server_role { (1, 0) } else { (0, 1) };
        let outgoing = directional(&key2, outgoing, cipher.key_len());
        let incoming = directional(&key2, incoming, cipher.key_len());
        key2_zeroize(key2);
        DataKeys { outgoing, incoming }
    }
}

fn master_zeroize(mut master: [u8; 48]) {
    master.zeroize();
}

fn key2_zeroize(mut key2: [u8; 256]) {
    key2.zeroize();
}

fn directional(key2: &[u8; 256], index: usize, key_len: usize) -> DirectionalKey {
    let base = index * 128;
    let mut cipher_key = key2[base..base + key_len].to_vec();
    let mut implicit_iv = [0u8; 8];
    implicit_iv.copy_from_slice(&key2[base + 64..base + 72]);
    let output = DirectionalKey {
        cipher_key: std::mem::take(&mut cipher_key),
        implicit_iv,
    };
    cipher_key.zeroize();
    output
}

impl fmt::Debug for KeySource {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeySource")
            .field("pre_master", &"<redacted>")
            .field("server_entropy", &self.has_server_entropy())
            .finish()
    }
}

/// One direction of the data-channel key schedule.
#[derive(Clone)]
pub(crate) struct DirectionalKey {
    /// Cipher key, truncated to the selected cipher's key length.
    pub(crate) cipher_key: Vec<u8>,
    /// The 8-byte implicit IV taken from the HMAC-key half of `key2`.
    pub(crate) implicit_iv: [u8; 8],
}

impl fmt::Debug for DirectionalKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DirectionalKey")
            .field("cipher_key", &"<redacted>")
            .field("implicit_iv", &"<redacted>")
            .finish()
    }
}

/// Client and server directional keys.
#[derive(Debug, Clone)]
pub(crate) struct DataKeys {
    pub(crate) outgoing: DirectionalKey,
    pub(crate) incoming: DirectionalKey,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tls1_prf_matches_openvpn_self_test_vector() {
        // From OpenVPN's check_tls_prf_working().
        let mut output = [0u8; 8];
        tls1_prf(b"tls1-prf-test-secret", b"tls1-prf-test", &mut output);
        assert_eq!(output, [0x71, 0x44, 0xfe, 0x25, 0x40, 0x73, 0x75, 0x95]);
    }

    #[test]
    fn client_and_server_derive_mirrored_keys() {
        let mut client = KeySource::generate();
        let server_random1 = [0x11; 32];
        let server_random2 = [0x22; 32];
        client.set_server_entropy(server_random1, server_random2);

        let client_keys = client.data_keys(Cipher::Aes256Gcm, [0xaa; 8], [0xbb; 8], false);
        let server_keys = client.data_keys(Cipher::Aes256Gcm, [0xaa; 8], [0xbb; 8], true);
        assert_eq!(
            client_keys.outgoing.cipher_key,
            server_keys.incoming.cipher_key
        );
        assert_eq!(
            client_keys.incoming.cipher_key,
            server_keys.outgoing.cipher_key
        );
        assert_eq!(
            client_keys.outgoing.implicit_iv,
            server_keys.incoming.implicit_iv
        );
        assert_eq!(client_keys.outgoing.cipher_key.len(), 32);
    }

    #[test]
    fn different_session_ids_change_the_keys() {
        let mut source = KeySource::generate();
        source.set_server_entropy([1; 32], [2; 32]);
        let a = source.data_keys(Cipher::Aes256Gcm, [1; 8], [2; 8], false);
        let b = source.data_keys(Cipher::Aes256Gcm, [1; 8], [3; 8], false);
        assert_ne!(a.outgoing.cipher_key, b.outgoing.cipher_key);
    }

    #[test]
    fn debug_redacts_key_material() {
        let mut source = KeySource::generate();
        source.set_server_entropy([1; 32], [2; 32]);
        let debug = format!("{source:?}");
        assert!(debug.contains("redacted"));
        assert!(!debug.contains("pre_master\": ["));
    }
}
