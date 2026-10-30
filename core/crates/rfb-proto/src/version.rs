//! RFB protocol version negotiation (RFC 6143 section 7.1.1).

use crate::Error;

/// Length of the version string, including the trailing newline.
pub const VERSION_LEN: usize = 12;

/// Protocol version advertised by an RFB peer.
///
/// Standard versions are 3.3, 3.7 and 3.8. Apple's desktop sharing
/// implementation advertises 3.889, which parses like any other version.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ProtocolVersion {
    pub major: u16,
    pub minor: u16,
}

impl ProtocolVersion {
    pub const RFB_3_3: Self = Self::new(3, 3);
    pub const RFB_3_7: Self = Self::new(3, 7);
    pub const RFB_3_8: Self = Self::new(3, 8);

    pub const fn new(major: u16, minor: u16) -> Self {
        Self { major, minor }
    }

    /// Parses a version string. Trailing bytes are ignored so callers can pass
    /// a larger buffered slice.
    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() < VERSION_LEN {
            return Err(Error::UnexpectedEof);
        }
        if &bytes[0..4] != b"RFB " || bytes[7] != b'.' || bytes[11] != b'\n' {
            return Err(Error::InvalidVersion);
        }
        Ok(Self {
            major: parse_digits(&bytes[4..7])?,
            minor: parse_digits(&bytes[8..11])?,
        })
    }

    pub fn encode(self) -> [u8; VERSION_LEN] {
        let mut out = *b"RFB 000.000\n";
        write_digits(&mut out[4..7], self.major);
        write_digits(&mut out[8..11], self.minor);
        out
    }

    pub const fn is_at_least(self, other: Self) -> bool {
        self.major > other.major || (self.major == other.major && self.minor >= other.minor)
    }
}

fn parse_digits(bytes: &[u8]) -> Result<u16, Error> {
    let mut value = 0u16;
    for &byte in bytes {
        if !byte.is_ascii_digit() {
            return Err(Error::InvalidVersion);
        }
        value = value * 10 + u16::from(byte - b'0');
    }
    Ok(value)
}

fn write_digits(dst: &mut [u8], value: u16) {
    let value = value % 1000;
    dst[0] = b'0' + (value / 100) as u8;
    dst[1] = b'0' + ((value / 10) % 10) as u8;
    dst[2] = b'0' + (value % 10) as u8;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_versions() {
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.003\n").unwrap(),
            ProtocolVersion::RFB_3_3
        );
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.007\n").unwrap(),
            ProtocolVersion::RFB_3_7
        );
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.008\n").unwrap(),
            ProtocolVersion::RFB_3_8
        );
    }

    #[test]
    fn parses_apple_version() {
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.889\n").unwrap(),
            ProtocolVersion::new(3, 889)
        );
    }

    #[test]
    fn ignores_trailing_bytes() {
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.008\n\x01\x02").unwrap(),
            ProtocolVersion::RFB_3_8
        );
    }

    #[test]
    fn rejects_malformed_versions() {
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.00").unwrap_err(),
            Error::UnexpectedEof
        );
        assert_eq!(
            ProtocolVersion::parse(b"FTP 003.008\n").unwrap_err(),
            Error::InvalidVersion
        );
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003x008\n").unwrap_err(),
            Error::InvalidVersion
        );
        assert_eq!(
            ProtocolVersion::parse(b"RFB 003.008!").unwrap_err(),
            Error::InvalidVersion
        );
    }

    #[test]
    fn encodes_versions() {
        assert_eq!(&ProtocolVersion::RFB_3_8.encode(), b"RFB 003.008\n");
        assert_eq!(&ProtocolVersion::new(3, 889).encode(), b"RFB 003.889\n");
    }

    #[test]
    fn compares_versions() {
        assert!(ProtocolVersion::RFB_3_8.is_at_least(ProtocolVersion::RFB_3_7));
        assert!(ProtocolVersion::RFB_3_8.is_at_least(ProtocolVersion::RFB_3_8));
        assert!(!ProtocolVersion::RFB_3_7.is_at_least(ProtocolVersion::RFB_3_8));
        assert!(ProtocolVersion::new(3, 889).is_at_least(ProtocolVersion::RFB_3_8));
    }
}
