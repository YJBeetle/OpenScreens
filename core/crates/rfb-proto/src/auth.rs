//! VNC Authentication (RFC 6143 section 7.2.2).
//!
//! The server sends a 16-byte challenge; the client encrypts it with DES
//! using the password as the key, with every key byte bit-reversed.

use des::Des;
use des::cipher::{Block, BlockEncrypt, KeyInit};

pub const VNC_CHALLENGE_LEN: usize = 16;

/// Converts a VNC password into the DES key used on the wire.
pub fn vnc_des_key(password: &[u8]) -> [u8; 8] {
    let mut key = [0u8; 8];
    let take = password.len().min(key.len());
    key[..take].copy_from_slice(&password[..take]);
    for byte in &mut key {
        *byte = byte.reverse_bits();
    }
    key
}

/// Encrypts a VNC authentication challenge with the given password.
pub fn vnc_auth_response(
    password: &[u8],
    challenge: &[u8; VNC_CHALLENGE_LEN],
) -> [u8; VNC_CHALLENGE_LEN] {
    let cipher = Des::new_from_slice(&vnc_des_key(password)).expect("DES key is always 8 bytes");
    let mut response = [0u8; VNC_CHALLENGE_LEN];
    for (chunk, out) in challenge
        .as_chunks::<8>()
        .0
        .iter()
        .zip(response.as_chunks_mut::<8>().0)
    {
        let mut block = Block::<Des>::clone_from_slice(chunk);
        cipher.encrypt_block(&mut block);
        out.copy_from_slice(&block);
    }
    response
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reverses_key_bits() {
        assert_eq!(vnc_des_key(b"p")[0], 0x0e);
        assert_eq!(vnc_des_key(b"as")[..2], [0x86, 0xce]);
    }

    #[test]
    fn pads_and_truncates_password() {
        assert_eq!(vnc_des_key(b""), [0; 8]);
        assert_eq!(
            vnc_des_key(b"123456789"),
            [0x8c, 0x4c, 0xcc, 0x2c, 0xac, 0x6c, 0xec, 0x1c]
        );
    }

    #[test]
    fn matches_des_test_vector() {
        // Standard DES vector: key 133457799BBCDFF1, plaintext 0123456789ABCDEF.
        // The password whose bits reverse to that key is C8 2C EA 9E D9 3D FB 8F.
        let password = [0xc8, 0x2c, 0xea, 0x9e, 0xd9, 0x3d, 0xfb, 0x8f];
        let challenge = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]
            .into_iter()
            .cycle()
            .take(16)
            .collect::<Vec<_>>()
            .try_into()
            .unwrap();
        let expected = [
            0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a, 0xb4, 0x05, 0x85, 0xe8, 0x13, 0x54, 0x0f, 0x0a,
            0xb4, 0x05,
        ];
        assert_eq!(vnc_auth_response(&password, &challenge), expected);
    }
}
