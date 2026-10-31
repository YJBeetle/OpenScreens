//! Data-channel cipher and digest identifiers.

/// An AEAD cipher implemented by the data channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cipher {
    /// AES-256-GCM (the OpenVPN 2.6 default).
    Aes256Gcm,
    /// AES-192-GCM.
    Aes192Gcm,
    /// AES-128-GCM.
    Aes128Gcm,
    /// ChaCha20-Poly1305.
    ChaCha20Poly1305,
}

impl Cipher {
    /// Parses an OpenVPN cipher name. CBC/CFB/OFB names are recognised so the
    /// parser can report them as unsupported explicitly.
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_uppercase().as_str() {
            "AES-256-GCM" => Some(Self::Aes256Gcm),
            "AES-192-GCM" => Some(Self::Aes192Gcm),
            "AES-128-GCM" => Some(Self::Aes128Gcm),
            "CHACHA20-POLY1305" => Some(Self::ChaCha20Poly1305),
            _ => None,
        }
    }

    /// Returns whether a name is a known non-AEAD OpenVPN cipher.
    pub fn is_legacy(name: &str) -> bool {
        matches!(
            name.trim().to_ascii_uppercase().as_str(),
            "AES-256-CBC"
                | "AES-192-CBC"
                | "AES-128-CBC"
                | "BF-CBC"
                | "DES-EDE3-CBC"
                | "AES-256-CFB"
                | "AES-256-OFB"
        )
    }

    /// OpenVPN's canonical spelling.
    pub fn name(self) -> &'static str {
        match self {
            Self::Aes256Gcm => "AES-256-GCM",
            Self::Aes192Gcm => "AES-192-GCM",
            Self::Aes128Gcm => "AES-128-GCM",
            Self::ChaCha20Poly1305 => "CHACHA20-POLY1305",
        }
    }

    /// Key length in bytes.
    pub fn key_len(self) -> usize {
        match self {
            Self::Aes256Gcm | Self::ChaCha20Poly1305 => 32,
            Self::Aes192Gcm => 24,
            Self::Aes128Gcm => 16,
        }
    }

    /// Key size in bits, as announced in the OCC options string.
    pub fn key_bits(self) -> usize {
        self.key_len() * 8
    }
}

/// The `auth` digest. It is only used by CBC data channels; AEAD profiles
/// still carry the value for interoperability with the server's options.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AuthDigest {
    /// HMAC-SHA1 (OpenVPN's historical default).
    #[default]
    Sha1,
    /// HMAC-SHA-256.
    Sha256,
    /// HMAC-SHA-512.
    Sha512,
}

impl AuthDigest {
    /// Parses an OpenVPN digest name.
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_uppercase().replace('_', "-").as_str() {
            "SHA1" | "SHA-1" => Some(Self::Sha1),
            "SHA256" | "SHA-256" => Some(Self::Sha256),
            "SHA512" | "SHA-512" => Some(Self::Sha512),
            _ => None,
        }
    }

    /// OpenVPN's canonical spelling.
    pub fn name(self) -> &'static str {
        match self {
            Self::Sha1 => "SHA1",
            Self::Sha256 => "SHA256",
            Self::Sha512 => "SHA512",
        }
    }

    /// HMAC output length in bytes.
    pub fn output_len(self) -> usize {
        match self {
            Self::Sha1 => 20,
            Self::Sha256 => 32,
            Self::Sha512 => 64,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_supported_ciphers_case_insensitively() {
        assert_eq!(Cipher::parse("aes-256-gcm"), Some(Cipher::Aes256Gcm));
        assert_eq!(
            Cipher::parse("ChaCha20-Poly1305"),
            Some(Cipher::ChaCha20Poly1305)
        );
        assert_eq!(Cipher::parse("AES-192-GCM"), Some(Cipher::Aes192Gcm));
        assert_eq!(Cipher::parse("AES-128-GCM"), Some(Cipher::Aes128Gcm));
        assert_eq!(Cipher::parse("none"), None);
        assert!(Cipher::is_legacy("AES-256-CBC"));
        assert!(!Cipher::is_legacy("AES-256-GCM"));
    }

    #[test]
    fn parses_digests() {
        assert_eq!(AuthDigest::parse("SHA1"), Some(AuthDigest::Sha1));
        assert_eq!(AuthDigest::parse("sha256"), Some(AuthDigest::Sha256));
        assert_eq!(AuthDigest::parse("SHA-512"), Some(AuthDigest::Sha512));
        assert_eq!(AuthDigest::parse("MD5"), None);
        assert_eq!(AuthDigest::Sha1.output_len(), 20);
        assert_eq!(AuthDigest::Sha256.output_len(), 32);
        assert_eq!(AuthDigest::Sha512.output_len(), 64);
    }
}
