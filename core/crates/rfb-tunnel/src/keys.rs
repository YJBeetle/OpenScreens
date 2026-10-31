//! WireGuard keys: base64 conversion, generation and public key derivation.
//!
//! The X25519 types are re-exported by `boringtun`; this crate never depends on
//! `x25519-dalek` directly, so there is only one `StaticSecret` in the build.

use std::fmt;
use std::str::FromStr;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use boringtun::x25519::{PublicKey as DalekPublicKey, StaticSecret};
use rand::Rng;
use zeroize::Zeroizing;

use crate::error::KeyError;

/// Length of a WireGuard key in bytes.
pub const KEY_LEN: usize = 32;

/// Length of a base64 encoded WireGuard key, including padding.
pub const KEY_BASE64_LEN: usize = 44;

fn decode_key(encoded: &str) -> Result<Zeroizing<[u8; KEY_LEN]>, KeyError> {
    let encoded = encoded.trim();
    if encoded.len() != KEY_BASE64_LEN {
        return Err(KeyError::InvalidLength {
            actual: encoded.len(),
        });
    }
    let mut bytes = Zeroizing::new([0u8; KEY_LEN]);
    let decoded = STANDARD
        .decode_slice(encoded, &mut bytes[..])
        .map_err(|_| KeyError::InvalidBase64)?;
    if decoded != KEY_LEN {
        return Err(KeyError::InvalidLength { actual: decoded });
    }
    Ok(bytes)
}

/// A secret X25519 key.
///
/// The wrapped `StaticSecret` zeroizes its bytes on drop; the `Debug`
/// implementation never prints the key.
#[derive(Clone)]
pub struct PrivateKey(StaticSecret);

impl PrivateKey {
    /// Generates a random key from the operating system random source.
    pub fn generate() -> Self {
        let mut bytes = Zeroizing::new([0u8; KEY_LEN]);
        rand::rng().fill_bytes(&mut bytes[..]);
        Self(StaticSecret::from(*bytes))
    }

    /// Builds a key from raw bytes.
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(StaticSecret::from(bytes))
    }

    /// Parses a standard base64 (`wg genkey` style) key.
    pub fn from_base64(encoded: &str) -> Result<Self, KeyError> {
        Ok(Self::from_bytes(*decode_key(encoded)?))
    }

    /// Returns the raw key bytes.
    pub fn to_bytes(&self) -> [u8; KEY_LEN] {
        self.0.to_bytes()
    }

    /// Encodes the key as standard base64.
    pub fn encode_base64(&self) -> String {
        STANDARD.encode(self.0.to_bytes())
    }

    /// Derives the matching public key.
    pub fn public_key(&self) -> PublicKey {
        PublicKey(DalekPublicKey::from(&self.0).to_bytes())
    }

    pub(crate) fn as_static_secret(&self) -> &StaticSecret {
        &self.0
    }
}

impl fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PrivateKey(<redacted>)")
    }
}

/// A public X25519 key.
///
/// Public keys are not secret and are printed as base64.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct PublicKey([u8; KEY_LEN]);

impl PublicKey {
    /// Builds a public key from raw bytes.
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    /// Returns the raw key bytes.
    pub fn to_bytes(self) -> [u8; KEY_LEN] {
        self.0
    }

    /// Returns the raw key bytes by reference.
    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }

    /// Parses a standard base64 public key.
    pub fn from_base64(encoded: &str) -> Result<Self, KeyError> {
        Ok(Self(*decode_key(encoded)?))
    }

    /// Encodes the key as standard base64.
    pub fn encode_base64(self) -> String {
        STANDARD.encode(self.0)
    }

    pub(crate) fn to_dalek(self) -> DalekPublicKey {
        DalekPublicKey::from(self.0)
    }
}

impl fmt::Display for PublicKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.encode_base64())
    }
}

impl fmt::Debug for PublicKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PublicKey({})", self.encode_base64())
    }
}

impl FromStr for PublicKey {
    type Err = KeyError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::from_base64(s)
    }
}

/// An optional pre-shared key.
///
/// The bytes are zeroized on drop and the `Debug` implementation is redacted.
#[derive(Clone)]
pub struct PresharedKey(Zeroizing<[u8; KEY_LEN]>);

impl PresharedKey {
    /// Builds a pre-shared key from raw bytes.
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(Zeroizing::new(bytes))
    }

    /// Parses a standard base64 pre-shared key.
    pub fn from_base64(encoded: &str) -> Result<Self, KeyError> {
        Ok(Self(decode_key(encoded)?))
    }

    /// Returns the raw key bytes.
    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }

    /// Encodes the key as standard base64.
    pub fn encode_base64(&self) -> String {
        STANDARD.encode(&self.0[..])
    }

    pub(crate) fn to_array(&self) -> [u8; KEY_LEN] {
        *self.0
    }
}

impl fmt::Debug for PresharedKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("PresharedKey(<redacted>)")
    }
}

/// A matching private/public key pair.
#[derive(Clone)]
pub struct KeyPair {
    private: PrivateKey,
    public: PublicKey,
}

impl KeyPair {
    /// Generates a new random key pair.
    pub fn generate() -> Self {
        Self::from_private(PrivateKey::generate())
    }

    /// Derives the public half of an existing private key.
    pub fn from_private(private: PrivateKey) -> Self {
        let public = private.public_key();
        Self { private, public }
    }

    /// Returns the private key.
    pub fn private(&self) -> &PrivateKey {
        &self.private
    }

    /// Returns the public key.
    pub fn public(&self) -> &PublicKey {
        &self.public
    }

    /// Splits the pair into its halves.
    pub fn into_parts(self) -> (PrivateKey, PublicKey) {
        (self.private, self.public)
    }
}

impl fmt::Debug for KeyPair {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("KeyPair")
            .field("private", &"<redacted>")
            .field("public", &self.public.encode_base64())
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 7748 section 6.1 test vector, encoded the way `wg` does.
    const ALICE_PRIVATE: &str = "dwdtCnMYpX08FsFyUbJmRd9ML4frwJkqsXf7pR25LCo=";
    const ALICE_PUBLIC: &str = "hSDwCYkwp1R0i33ctD73Wg2/Og0mOBr066SpjqqbTmo=";

    #[test]
    fn derives_public_key_from_rfc7748_vector() {
        let private = PrivateKey::from_base64(ALICE_PRIVATE).unwrap();
        assert_eq!(private.public_key().encode_base64(), ALICE_PUBLIC);
    }

    #[test]
    fn base64_round_trip() {
        let private = PrivateKey::from_base64(ALICE_PRIVATE).unwrap();
        assert_eq!(private.encode_base64(), ALICE_PRIVATE);
        assert_eq!(private.to_bytes().len(), KEY_LEN);

        let public = PublicKey::from_base64(ALICE_PUBLIC).unwrap();
        assert_eq!(public.encode_base64(), ALICE_PUBLIC);
        assert_eq!(public.to_bytes().len(), KEY_LEN);
    }

    #[test]
    fn generated_pair_matches() {
        let pair = KeyPair::generate();
        assert_eq!(pair.private().public_key(), *pair.public());

        let encoded = pair.private().encode_base64();
        let reparsed = PrivateKey::from_base64(&encoded).unwrap();
        assert_eq!(reparsed.public_key(), *pair.public());
    }

    #[test]
    fn preshared_key_round_trip() {
        let bytes = [7u8; KEY_LEN];
        let psk = PresharedKey::from_bytes(bytes);
        let encoded = psk.encode_base64();
        assert_eq!(
            PresharedKey::from_base64(&encoded).unwrap().as_bytes(),
            &bytes
        );
    }

    #[test]
    fn rejects_bad_keys_without_echoing_them() {
        let error = PrivateKey::from_base64("too-short").unwrap_err();
        let message = error.to_string();
        assert!(!message.contains("too-short"));

        assert!(PublicKey::from_base64("!!!!").is_err());

        let wrong_length = STANDARD.encode([9u8; 31]);
        let error = PrivateKey::from_base64(&wrong_length).unwrap_err();
        assert!(matches!(error, KeyError::InvalidLength { .. }));
        assert!(!error.to_string().contains(&wrong_length));
    }

    #[test]
    fn debug_redacts_secrets() {
        let private = PrivateKey::from_base64(ALICE_PRIVATE).unwrap();
        let debug = format!("{private:?}");
        assert!(!debug.contains(ALICE_PRIVATE));
        assert!(debug.contains("redacted"));

        let psk = PresharedKey::from_bytes([1u8; KEY_LEN]);
        let debug = format!("{psk:?}");
        assert!(!debug.contains(&psk.encode_base64()));

        let pair = KeyPair::from_private(private);
        let debug = format!("{pair:?}");
        assert!(!debug.contains(ALICE_PRIVATE));
        assert!(debug.contains(ALICE_PUBLIC));
    }

    #[test]
    fn public_key_debug_is_readable() {
        let public = PublicKey::from_base64(ALICE_PUBLIC).unwrap();
        assert!(format!("{public:?}").contains(ALICE_PUBLIC));
        assert_eq!(public.to_string(), ALICE_PUBLIC);
    }
}
