//! Apple Screen Sharing Diffie-Hellman authentication (RFB security types 30
//! and 32).
//!
//! Both security types use the same exchange:
//!
//! 1. The client selects type 30 or 32 and the server replies with
//!    `u16` BE generator, `u16` BE key length `L`, `L` modulus bytes `P`
//!    and `L` server public-key bytes.
//! 2. The client derives a DH key pair from `(g, P, L)` and derives the
//!    AES-128 key from the shared secret.
//! 3. The client sends the 128-byte encrypted credential block immediately
//!    followed by its `L`-byte public key.
//! 4. The server answers with a `u32` BE `SecurityResult`. Only on success
//!    (0) does the usual `ClientInit`/`ServerInit` exchange follow.
//!
//! Security type 18 is not handled here: TLS must be established first and
//! the security-type list re-read before type 30 or 32 can be selected.
//!
//! The credential block is exactly 128 bytes: the username as UTF-8,
//! NUL-padded to 64 bytes, followed by the password as UTF-8, NUL-padded to
//! 64 bytes. The block is encrypted with AES-128-ECB using
//! `MD5(shared_secret)`, where the shared secret is encoded as exactly `L`
//! big-endian bytes with leading zero padding. That same MD5 digest is the
//! session key for later encrypted client-to-server input events.
//!
//! This module is sans-I/O: it produces the bytes to write and leaves all
//! socket handling and `SecurityResult` parsing to the handshake engine.

use std::fmt;

use aes::Aes128;
use aes::cipher::{Block, BlockEncrypt, KeyInit};
use md5::{Digest, Md5};
use num_bigint::BigUint;
use num_traits::Zero;

/// Length of the encrypted credential block in bytes.
pub const CREDENTIAL_BLOCK_LEN: usize = 128;

/// Length of each credential field in bytes (including its NUL terminator).
pub const CREDENTIAL_FIELD_LEN: usize = 64;

/// Maximum UTF-8 byte length of a username or password (leaves room for NUL).
pub const MAX_CREDENTIAL_LEN: usize = CREDENTIAL_FIELD_LEN - 1;

/// AES-128 key length used for credentials and input events.
pub const AES_KEY_LEN: usize = 16;

/// Smallest accepted DH modulus size in bytes (512 bits).
pub const MIN_MODULUS_LEN: usize = 64;

/// Largest accepted DH modulus size in bytes (4096 bits).
pub const MAX_MODULUS_LEN: usize = 512;

/// The client's response to an Apple DH authentication request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleAuthReply {
    /// 128-byte AES-128-ECB ciphertext of the padded credential block.
    pub credentials_ciphertext: Vec<u8>,
    /// Client DH public key as `L` big-endian bytes, zero-padded on the left.
    pub client_public_key: Vec<u8>,
    /// `MD5(shared_secret)`, retained for encrypted input events.
    pub aes_key: [u8; AES_KEY_LEN],
}

/// Errors produced while building an Apple DH authentication reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppleAuthError {
    /// The modulus length is outside [`MIN_MODULUS_LEN`]..=[`MAX_MODULUS_LEN`].
    InvalidModulusLength(usize),
    /// The modulus is below 3 or even.
    InvalidModulus,
    /// The generator is outside `[2, P)`.
    InvalidGenerator,
    /// The server public key does not have the same length as the modulus.
    InvalidServerKeyLength { expected: usize, actual: usize },
    /// The server public key is outside `(1, P-1)` or yields a zero secret.
    InvalidServerKey,
    /// The username exceeds [`MAX_CREDENTIAL_LEN`] UTF-8 bytes.
    UsernameTooLong(usize),
    /// The password exceeds [`MAX_CREDENTIAL_LEN`] UTF-8 bytes.
    PasswordTooLong(usize),
    /// Entropy generation or DH arithmetic failed.
    CryptoFailure,
}

impl fmt::Display for AppleAuthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidModulusLength(length) => {
                write!(f, "invalid DH modulus length {length} bytes")
            }
            Self::InvalidModulus => f.write_str("DH modulus must be odd and greater than 2"),
            Self::InvalidGenerator => f.write_str("DH generator is outside the range [2, P)"),
            Self::InvalidServerKeyLength { expected, actual } => write!(
                f,
                "server DH public key is {actual} bytes, expected {expected}"
            ),
            Self::InvalidServerKey => {
                f.write_str("server DH public key is outside the range (1, P-1)")
            }
            Self::UsernameTooLong(length) => {
                write!(f, "username is {length} bytes, maximum is 63")
            }
            Self::PasswordTooLong(length) => {
                write!(f, "password is {length} bytes, maximum is 63")
            }
            Self::CryptoFailure => f.write_str("cryptographic operation failed"),
        }
    }
}

impl std::error::Error for AppleAuthError {}

/// Builds the client reply for security type 30 or 32.
///
/// `generator` and `modulus` come from the server's `u16` BE generator and
/// `L`-byte modulus; `server_public_key` is the following `L`-byte key. The
/// returned reply must be written as `credentials_ciphertext` (128 bytes)
/// followed by `client_public_key` (`L` bytes), before reading the server's
/// `u32` BE `SecurityResult`.
///
/// A fresh DH private exponent is drawn from the operating system. Use
/// [`encrypt_apple_input_event`] with [`AppleAuthReply::aes_key`] for later
/// encrypted input events.
pub fn apple_dh_reply(
    generator: u16,
    modulus: &[u8],
    server_public_key: &[u8],
    username: &str,
    password: &str,
) -> Result<AppleAuthReply, AppleAuthError> {
    let params = validate(generator, modulus, server_public_key)?;
    let exponent = random_exponent(&params)?;
    build_reply(&params, username, password, &exponent)
}

/// Variant of [`apple_dh_reply`] with a caller-supplied private exponent.
///
/// Only used by tests to make the exchange reproducible; the public entry
/// point always draws its exponent from the operating system.
#[cfg(test)]
fn apple_dh_reply_with_exponent(
    generator: u16,
    modulus: &[u8],
    server_public_key: &[u8],
    username: &str,
    password: &str,
    exponent: &BigUint,
) -> Result<AppleAuthReply, AppleAuthError> {
    let params = validate(generator, modulus, server_public_key)?;
    build_reply(&params, username, password, exponent)
}

/// Encrypts a 16-byte input-event header with the retained session key.
///
/// Wraps a 16-byte event header into the 18-byte Apple input message used
/// inside RFB 3.889 sessions: `[0x10, direction ^ 1, AES-128-ECB(header)]`.
pub fn encrypt_apple_input_message(
    key: &[u8; AES_KEY_LEN],
    header: &[u8; AES_KEY_LEN],
    direction: u8,
) -> [u8; 18] {
    let ciphertext = encrypt_apple_input_event(key, header);
    let mut message = [0u8; 18];
    message[0] = 0x10;
    message[1] = direction ^ 1;
    message[2..].copy_from_slice(&ciphertext);
    message
}

/// Builds the encrypted mouse message. Layout verified by disassembling
/// `-[VncClient sendAppleMouseEvent:y:buttons:timeDeltaUS:]`:
/// `[0..6)=0, u32 BE time delta at 6, 0xFF at 10, buttons at 11,
/// u16 BE x at 12, u16 BE y at 14`.
pub fn encrypt_apple_pointer_event(
    key: &[u8; AES_KEY_LEN],
    x: u16,
    y: u16,
    buttons: u8,
    time_delta_us: u32,
) -> [u8; 18] {
    let mut header = [0u8; AES_KEY_LEN];
    header[6..10].copy_from_slice(&time_delta_us.to_be_bytes());
    header[10] = 0xFF;
    header[11] = buttons;
    header[12..14].copy_from_slice(&x.to_be_bytes());
    header[14..16].copy_from_slice(&y.to_be_bytes());
    encrypt_apple_input_message(key, &header, 1)
}

/// Builds the encrypted key message; see `-[VncClient sendAppleKeyEvent:...]`.
/// `keycode` is the macOS virtual keycode carried in the header.
pub fn encrypt_apple_key_event(
    key: &[u8; AES_KEY_LEN],
    keycode: u16,
    down: bool,
    time_delta_us: u32,
) -> [u8; 18] {
    let mut header = [0u8; AES_KEY_LEN];
    header[0] = 0xFF;
    header[1] = u8::from(down);
    header[4..6].copy_from_slice(&keycode.to_be_bytes());
    header[6..10].copy_from_slice(&time_delta_us.to_be_bytes());
    header[13] = 0x2F;
    encrypt_apple_input_message(key, &header, 0)
}

/// The protocol requires AES-128-ECB over each 16-byte block; the header is
/// a single block, so no padding is involved.
pub fn encrypt_apple_input_event(key: &[u8; AES_KEY_LEN], header: &[u8; AES_KEY_LEN]) -> [u8; 16] {
    let cipher = aes128(key);
    let mut block = Block::<Aes128>::clone_from_slice(header);
    cipher.encrypt_block(&mut block);
    let mut output = [0u8; AES_KEY_LEN];
    output.copy_from_slice(&block);
    output
}

struct DhParameters {
    modulus: BigUint,
    generator: BigUint,
    server_public: BigUint,
    width: usize,
}

fn validate(
    generator: u16,
    modulus: &[u8],
    server_public_key: &[u8],
) -> Result<DhParameters, AppleAuthError> {
    let width = modulus.len();
    if !(MIN_MODULUS_LEN..=MAX_MODULUS_LEN).contains(&width) {
        return Err(AppleAuthError::InvalidModulusLength(width));
    }
    if server_public_key.len() != width {
        return Err(AppleAuthError::InvalidServerKeyLength {
            expected: width,
            actual: server_public_key.len(),
        });
    }

    let modulus_value = BigUint::from_bytes_be(modulus);
    if modulus_value < BigUint::from(3u8) || !modulus_value.bit(0) {
        return Err(AppleAuthError::InvalidModulus);
    }

    let generator_value = BigUint::from(generator);
    if generator_value < BigUint::from(2u8) || generator_value >= modulus_value {
        return Err(AppleAuthError::InvalidGenerator);
    }

    let server_public = BigUint::from_bytes_be(server_public_key);
    let p_minus_one = &modulus_value - BigUint::from(1u8);
    if server_public <= BigUint::from(1u8) || server_public >= p_minus_one {
        return Err(AppleAuthError::InvalidServerKey);
    }

    Ok(DhParameters {
        modulus: modulus_value,
        generator: generator_value,
        server_public,
        width,
    })
}

fn random_exponent(params: &DhParameters) -> Result<BigUint, AppleAuthError> {
    let mut bytes = vec![0u8; params.width];
    getrandom::fill(&mut bytes).map_err(|_| AppleAuthError::CryptoFailure)?;

    // Map uniformly-ish into [2, P-2]; P is far larger than the tiny modulo
    // bias introduced by this reduction.
    let range = &params.modulus - BigUint::from(3u8);
    if range.is_zero() {
        return Err(AppleAuthError::InvalidModulus);
    }
    Ok(BigUint::from_bytes_be(&bytes) % range + BigUint::from(2u8))
}

fn build_reply(
    params: &DhParameters,
    username: &str,
    password: &str,
    exponent: &BigUint,
) -> Result<AppleAuthReply, AppleAuthError> {
    let mut block = credential_block(username, password)?;

    let shared = params.server_public.modpow(exponent, &params.modulus);
    if shared.is_zero() {
        return Err(AppleAuthError::InvalidServerKey);
    }
    let shared_bytes =
        encode_fixed_width(&shared, params.width).ok_or(AppleAuthError::CryptoFailure)?;
    let aes_key = md5_key(&shared_bytes);
    encrypt_credential_block(&aes_key, &mut block);

    let client_public = params.generator.modpow(exponent, &params.modulus);
    if client_public.bits() <= 1 {
        return Err(AppleAuthError::InvalidModulus);
    }
    let client_public_key =
        encode_fixed_width(&client_public, params.width).ok_or(AppleAuthError::CryptoFailure)?;

    Ok(AppleAuthReply {
        credentials_ciphertext: block.to_vec(),
        client_public_key,
        aes_key,
    })
}

fn credential_block(
    username: &str,
    password: &str,
) -> Result<[u8; CREDENTIAL_BLOCK_LEN], AppleAuthError> {
    let username = username.as_bytes();
    let password = password.as_bytes();
    if username.len() > MAX_CREDENTIAL_LEN {
        return Err(AppleAuthError::UsernameTooLong(username.len()));
    }
    if password.len() > MAX_CREDENTIAL_LEN {
        return Err(AppleAuthError::PasswordTooLong(password.len()));
    }

    // The remaining bytes stay zero; servers ignore their previous contents.
    let mut block = [0u8; CREDENTIAL_BLOCK_LEN];
    block[..username.len()].copy_from_slice(username);
    block[CREDENTIAL_FIELD_LEN..CREDENTIAL_FIELD_LEN + password.len()].copy_from_slice(password);
    Ok(block)
}

fn md5_key(shared_secret: &[u8]) -> [u8; AES_KEY_LEN] {
    let digest = Md5::digest(shared_secret);
    let mut key = [0u8; AES_KEY_LEN];
    key.copy_from_slice(&digest);
    key
}

/// Encodes `value` as exactly `width` big-endian bytes, left-padded with
/// zeros. Returns `None` if the value does not fit (not attacker reachable:
/// every encoded value is smaller than the `width`-byte modulus).
fn encode_fixed_width(value: &BigUint, width: usize) -> Option<Vec<u8>> {
    let bytes = value.to_bytes_be();
    if bytes.len() > width {
        return None;
    }
    let mut output = vec![0u8; width];
    output[width - bytes.len()..].copy_from_slice(&bytes);
    Some(output)
}

fn aes128(key: &[u8; AES_KEY_LEN]) -> Aes128 {
    Aes128::new_from_slice(key).expect("AES-128 keys are always 16 bytes")
}

fn encrypt_credential_block(key: &[u8; AES_KEY_LEN], block: &mut [u8; CREDENTIAL_BLOCK_LEN]) {
    let cipher = aes128(key);
    for chunk in block.as_chunks_mut::<AES_KEY_LEN>().0 {
        let mut cipher_block = Block::<Aes128>::clone_from_slice(chunk);
        cipher.encrypt_block(&mut cipher_block);
        chunk.copy_from_slice(&cipher_block);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::BlockDecrypt;

    /// RFC 2409 Appendix E, 1024-bit MODP group (group 2).
    const GROUP2_HEX: &str = concat!(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD1",
        "29024E088A67CC74020BBEA63B139B22514A08798E3404DD",
        "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245",
        "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED",
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381",
        "FFFFFFFFFFFFFFFF",
    );

    const TEST_SERVER_PRIVATE: u8 = 5;

    fn hex(value: &str) -> Vec<u8> {
        let bytes = value.as_bytes();
        assert_eq!(bytes.len() & 1, 0, "hex string must have even length");
        bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| {
                let text = std::str::from_utf8(pair).expect("ASCII hex");
                u8::from_str_radix(text, 16).expect("valid hex")
            })
            .collect()
    }

    fn group2_modulus() -> Vec<u8> {
        let modulus = hex(GROUP2_HEX);
        assert_eq!(modulus.len(), 128);
        modulus
    }

    /// Type 30 parameters with a known server key pair and generator 2.
    fn group2_params() -> (u16, Vec<u8>, Vec<u8>) {
        let modulus = group2_modulus();
        let p = BigUint::from_bytes_be(&modulus);
        let server_public = BigUint::from(2u8).modpow(&BigUint::from(TEST_SERVER_PRIVATE), &p);
        let server_public_key = encode_fixed_width(&server_public, modulus.len()).unwrap();
        (2, modulus, server_public_key)
    }

    fn decrypt_ecb(key: &[u8; AES_KEY_LEN], ciphertext: &[u8]) -> Vec<u8> {
        let cipher = aes128(key);
        let mut plaintext = ciphertext.to_vec();
        for chunk in plaintext.as_chunks_mut::<AES_KEY_LEN>().0 {
            let mut block = Block::<Aes128>::clone_from_slice(chunk);
            cipher.decrypt_block(&mut block);
            chunk.copy_from_slice(&block);
        }
        plaintext
    }

    fn assert_padded(plaintext: &[u8], username: &[u8], password: &[u8]) {
        assert_eq!(plaintext.len(), CREDENTIAL_BLOCK_LEN);
        assert_eq!(&plaintext[..username.len()], username);
        assert!(
            plaintext[username.len()..CREDENTIAL_FIELD_LEN]
                .iter()
                .all(|&byte| byte == 0)
        );
        let password_start = CREDENTIAL_FIELD_LEN;
        assert_eq!(
            &plaintext[password_start..password_start + password.len()],
            password
        );
        assert!(
            plaintext[password_start + password.len()..]
                .iter()
                .all(|&byte| byte == 0)
        );
    }

    #[test]
    fn encodes_fixed_width_big_endian() {
        let width = 128;
        assert_eq!(
            encode_fixed_width(&BigUint::from(0u8), width).unwrap(),
            vec![0u8; width]
        );

        let one = encode_fixed_width(&BigUint::from(1u8), width).unwrap();
        assert!(one[..width - 1].iter().all(|&byte| byte == 0));
        assert_eq!(one[width - 1], 1);

        let value = encode_fixed_width(&BigUint::from(0x0102u16), width).unwrap();
        assert_eq!(&value[width - 2..], &[1, 2]);

        assert_eq!(encode_fixed_width(&BigUint::from(0x010000u32), 2), None);
    }

    #[test]
    fn reply_layout_and_credentials_round_trip() {
        let (generator, modulus, server_public_key) = group2_params();
        let p = BigUint::from_bytes_be(&modulus);
        let exponent = BigUint::from(11u8);
        let reply = apple_dh_reply_with_exponent(
            generator,
            &modulus,
            &server_public_key,
            "alice",
            "s3cret",
            &exponent,
        )
        .unwrap();

        assert_eq!(reply.credentials_ciphertext.len(), CREDENTIAL_BLOCK_LEN);
        assert_eq!(reply.client_public_key.len(), modulus.len());

        let client_public = BigUint::from_bytes_be(&reply.client_public_key);
        let p_minus_one = &p - BigUint::from(1u8);
        assert!(client_public > BigUint::from(1u8));
        assert!(client_public < p_minus_one);

        let shared = client_public.modpow(&BigUint::from(TEST_SERVER_PRIVATE), &p);
        let shared_bytes = encode_fixed_width(&shared, modulus.len()).unwrap();
        let key = md5_key(&shared_bytes);
        assert_eq!(reply.aes_key, key);

        let plaintext = decrypt_ecb(&key, &reply.credentials_ciphertext);
        assert_padded(&plaintext, b"alice", b"s3cret");
    }

    #[test]
    fn zero_pads_shared_secret_and_client_public_key() {
        let modulus = group2_modulus();
        let width = modulus.len();
        let two = BigUint::from(2u8);
        let server_public_key = encode_fixed_width(&two, width).unwrap();

        // Exponent 1 makes both the client public key and the shared secret
        // equal to g = 2, so both must be left-padded to the full width.
        let reply = apple_dh_reply_with_exponent(
            2,
            &modulus,
            &server_public_key,
            "u",
            "p",
            &BigUint::from(1u8),
        )
        .unwrap();

        let mut expected_public = vec![0u8; width];
        expected_public[width - 1] = 2;
        assert_eq!(reply.client_public_key, expected_public);

        let mut expected_secret = vec![0u8; width];
        expected_secret[width - 1] = 2;
        let key = md5_key(&expected_secret);
        assert_eq!(reply.aes_key, key);

        let plaintext = decrypt_ecb(&key, &reply.credentials_ciphertext);
        assert_padded(&plaintext, b"u", b"p");
    }

    #[test]
    fn enforces_credential_length_limits() {
        let (generator, modulus, server_public_key) = group2_params();
        let exponent = BigUint::from(3u8);
        let username = "a".repeat(MAX_CREDENTIAL_LEN);
        let password = "b".repeat(MAX_CREDENTIAL_LEN);
        assert!(
            apple_dh_reply_with_exponent(
                generator,
                &modulus,
                &server_public_key,
                &username,
                &password,
                &exponent,
            )
            .is_ok()
        );

        let too_long = "c".repeat(MAX_CREDENTIAL_LEN + 1);
        assert_eq!(
            apple_dh_reply_with_exponent(
                generator,
                &modulus,
                &server_public_key,
                &too_long,
                "pw",
                &exponent,
            )
            .unwrap_err(),
            AppleAuthError::UsernameTooLong(64)
        );
        assert_eq!(
            apple_dh_reply_with_exponent(
                generator,
                &modulus,
                &server_public_key,
                "user",
                &too_long,
                &exponent,
            )
            .unwrap_err(),
            AppleAuthError::PasswordTooLong(64)
        );

        // Limits are UTF-8 bytes, not characters: 32 * 2 bytes = 64.
        let accented = "é".repeat(32);
        assert_eq!(accented.len(), 64);
        assert_eq!(
            apple_dh_reply_with_exponent(
                generator,
                &modulus,
                &server_public_key,
                &accented,
                "pw",
                &exponent,
            )
            .unwrap_err(),
            AppleAuthError::UsernameTooLong(64)
        );
        assert!(
            apple_dh_reply_with_exponent(
                generator,
                &modulus,
                &server_public_key,
                &"é".repeat(31),
                "pw",
                &exponent,
            )
            .is_ok()
        );
    }

    #[test]
    fn rejects_invalid_server_public_keys() {
        let modulus = group2_modulus();
        let width = modulus.len();
        let p = BigUint::from_bytes_be(&modulus);
        let exponent = BigUint::from(7u8);

        let zero = vec![0u8; width];
        let one = encode_fixed_width(&BigUint::from(1u8), width).unwrap();
        let p_minus_one = encode_fixed_width(&(&p - BigUint::from(1u8)), width).unwrap();
        let modulus_value = encode_fixed_width(&p, width).unwrap();
        let all_ones = vec![0xffu8; width];

        for key in [&zero, &one, &p_minus_one, &modulus_value, &all_ones] {
            assert_eq!(
                apple_dh_reply_with_exponent(2, &modulus, key.as_slice(), "user", "pw", &exponent,)
                    .unwrap_err(),
                AppleAuthError::InvalidServerKey
            );
        }

        assert_eq!(
            apple_dh_reply_with_exponent(2, &modulus, &zero[..width - 1], "user", "pw", &exponent)
                .unwrap_err(),
            AppleAuthError::InvalidServerKeyLength {
                expected: width,
                actual: width - 1,
            }
        );
    }

    #[test]
    fn rejects_invalid_groups() {
        let modulus = group2_modulus();
        let width = modulus.len();
        let key = encode_fixed_width(&BigUint::from(2u8), width).unwrap();
        let exponent = BigUint::from(3u8);

        assert_eq!(
            apple_dh_reply_with_exponent(
                2,
                &modulus[..MIN_MODULUS_LEN - 1],
                &key[..MIN_MODULUS_LEN - 1],
                "user",
                "pw",
                &exponent,
            )
            .unwrap_err(),
            AppleAuthError::InvalidModulusLength(MIN_MODULUS_LEN - 1)
        );

        let oversized = vec![0xffu8; MAX_MODULUS_LEN + 1];
        assert_eq!(
            apple_dh_reply_with_exponent(2, &oversized, &oversized, "user", "pw", &exponent)
                .unwrap_err(),
            AppleAuthError::InvalidModulusLength(MAX_MODULUS_LEN + 1)
        );

        let mut even = modulus.clone();
        *even.last_mut().unwrap() &= 0xfe;
        assert_eq!(
            apple_dh_reply_with_exponent(2, &even, &key, "user", "pw", &exponent).unwrap_err(),
            AppleAuthError::InvalidModulus
        );

        let zero_modulus = vec![0u8; width];
        assert_eq!(
            apple_dh_reply_with_exponent(2, &zero_modulus, &key, "user", "pw", &exponent)
                .unwrap_err(),
            AppleAuthError::InvalidModulus
        );

        for generator in [0, 1] {
            assert_eq!(
                apple_dh_reply_with_exponent(generator, &modulus, &key, "user", "pw", &exponent)
                    .unwrap_err(),
                AppleAuthError::InvalidGenerator
            );
        }

        // A full-width buffer may still encode a tiny modulus; the key range
        // check must reject it without panicking on the small reduction range.
        let mut tiny = vec![0u8; MIN_MODULUS_LEN];
        tiny[MIN_MODULUS_LEN - 1] = 3;
        let tiny_key = encode_fixed_width(&BigUint::from(2u8), MIN_MODULUS_LEN).unwrap();
        assert_eq!(
            apple_dh_reply_with_exponent(2, &tiny, &tiny_key, "user", "pw", &exponent).unwrap_err(),
            AppleAuthError::InvalidServerKey
        );
    }

    #[test]
    fn encrypts_input_event_with_nist_aes128_ecb_vector() {
        // NIST SP 800-38A, F.1.1, first block.
        let key: [u8; AES_KEY_LEN] = hex("2b7e151628aed2a6abf7158809cf4f3c").try_into().unwrap();
        let plaintext: [u8; AES_KEY_LEN] =
            hex("6bc1bee22e409f96e93d7e117393172a").try_into().unwrap();
        let expected: [u8; AES_KEY_LEN] =
            hex("3ad77bb40d7a3660a89ecaf32466ef97").try_into().unwrap();
        assert_eq!(encrypt_apple_input_event(&key, &plaintext), expected);
    }

    #[test]
    fn pointer_message_layout() {
        use aes::cipher::BlockDecrypt;
        let key = [0x11u8; AES_KEY_LEN];
        let message = encrypt_apple_pointer_event(&key, 0x1234, 0x5678, 0x05, 0x0a0b0c0d);
        assert_eq!(message[0], 0x10);
        assert_eq!(message[1], 0);

        let cipher = Aes128::new_from_slice(&key).unwrap();
        let mut block = Block::<Aes128>::clone_from_slice(&message[2..]);
        cipher.decrypt_block(&mut block);
        let header: [u8; 16] = block.into();
        assert_eq!(&header[6..10], &0x0a0b0c0du32.to_be_bytes());
        assert_eq!(header[10], 0xff);
        assert_eq!(header[11], 0x05);
        assert_eq!(&header[12..14], &0x1234u16.to_be_bytes());
        assert_eq!(&header[14..16], &0x5678u16.to_be_bytes());
    }

    #[test]
    fn key_message_layout() {
        use aes::cipher::BlockDecrypt;
        let key = [0x22u8; AES_KEY_LEN];
        let message = encrypt_apple_key_event(&key, 0x000d, true, 42);
        assert_eq!(message[0], 0x10);
        assert_eq!(message[1], 1);

        let cipher = Aes128::new_from_slice(&key).unwrap();
        let mut block = Block::<Aes128>::clone_from_slice(&message[2..]);
        cipher.decrypt_block(&mut block);
        let header: [u8; 16] = block.into();
        assert_eq!(header[0], 0xff);
        assert_eq!(header[1], 1);
        assert_eq!(&header[4..6], &0x000du16.to_be_bytes());
        assert_eq!(&header[6..10], &42u32.to_be_bytes());
        assert_eq!(header[13], 0x2f);
    }

    #[test]
    fn public_entry_point_returns_usable_reply() {
        let (generator, modulus, server_public_key) = group2_params();
        let reply =
            apple_dh_reply(generator, &modulus, &server_public_key, "alice", "hunter2").unwrap();

        assert_eq!(reply.credentials_ciphertext.len(), CREDENTIAL_BLOCK_LEN);
        assert_eq!(reply.client_public_key.len(), modulus.len());

        let p = BigUint::from_bytes_be(&modulus);
        let client_public = BigUint::from_bytes_be(&reply.client_public_key);
        assert!(client_public > BigUint::from(1u8));
        assert!(client_public < &p - BigUint::from(1u8));

        let shared = client_public.modpow(&BigUint::from(TEST_SERVER_PRIVATE), &p);
        let key = md5_key(&encode_fixed_width(&shared, modulus.len()).unwrap());
        assert_eq!(reply.aes_key, key);

        let plaintext = decrypt_ecb(&key, &reply.credentials_ciphertext);
        assert_padded(&plaintext, b"alice", b"hunter2");
    }
}
