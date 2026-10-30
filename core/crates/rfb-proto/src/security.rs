//! RFB security types and results (RFC 6143 section 7.1.2).

use crate::Error;

/// Security types defined by RFC 6143 and common extensions.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SecurityType {
    None,
    VncAuthentication,
    Ra2,
    Ra2ne,
    Tight,
    Ultra,
    Tls,
    VeNCrypt,
    Other(u8),
}

impl SecurityType {
    pub const fn from_u8(value: u8) -> Self {
        match value {
            1 => Self::None,
            2 => Self::VncAuthentication,
            5 => Self::Ra2,
            6 => Self::Ra2ne,
            16 => Self::Tight,
            17 => Self::Ultra,
            18 => Self::Tls,
            19 => Self::VeNCrypt,
            other => Self::Other(other),
        }
    }

    pub const fn to_u8(self) -> u8 {
        match self {
            Self::None => 1,
            Self::VncAuthentication => 2,
            Self::Ra2 => 5,
            Self::Ra2ne => 6,
            Self::Tight => 16,
            Self::Ultra => 17,
            Self::Tls => 18,
            Self::VeNCrypt => 19,
            Self::Other(value) => value,
        }
    }
}

/// Server response to a security handshake.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SecurityResult {
    Ok,
    Failed,
    TooManyAttempts,
    Unknown(u32),
}

impl SecurityResult {
    pub const fn from_u32(value: u32) -> Self {
        match value {
            0 => Self::Ok,
            1 => Self::Failed,
            2 => Self::TooManyAttempts,
            other => Self::Unknown(other),
        }
    }
}

/// Either the security types a server offers or its refusal reason.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SecurityOffer {
    Types(Vec<SecurityType>),
    Failure { reason: String },
}

/// Parses the server's security types message (RFB 3.7+).
///
/// Returns the offer and the number of bytes consumed.
pub fn parse_security_offer(bytes: &[u8]) -> Result<(SecurityOffer, usize), Error> {
    let Some(&count) = bytes.first() else {
        return Err(Error::UnexpectedEof);
    };

    if count == 0 {
        let length_end = 5;
        if bytes.len() < length_end {
            return Err(Error::UnexpectedEof);
        }
        let length = u32::from_be_bytes([bytes[1], bytes[2], bytes[3], bytes[4]]) as usize;
        let end = length_end.checked_add(length).ok_or(Error::UnexpectedEof)?;
        if bytes.len() < end {
            return Err(Error::UnexpectedEof);
        }
        let reason = String::from_utf8_lossy(&bytes[length_end..end]).into_owned();
        return Ok((SecurityOffer::Failure { reason }, end));
    }

    let end = 1 + usize::from(count);
    if bytes.len() < end {
        return Err(Error::UnexpectedEof);
    }
    let types = bytes[1..end]
        .iter()
        .map(|&value| SecurityType::from_u8(value))
        .collect();
    Ok((SecurityOffer::Types(types), end))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_security_types() {
        for value in 0u8..=255 {
            assert_eq!(SecurityType::from_u8(value).to_u8(), value);
        }
        assert_eq!(SecurityType::from_u8(1), SecurityType::None);
        assert_eq!(SecurityType::from_u8(2), SecurityType::VncAuthentication);
        assert_eq!(SecurityType::from_u8(19), SecurityType::VeNCrypt);
    }

    #[test]
    fn parses_offers() {
        let (offer, consumed) = parse_security_offer(&[2, 2, 16]).unwrap();
        assert_eq!(
            offer,
            SecurityOffer::Types(vec![SecurityType::VncAuthentication, SecurityType::Tight])
        );
        assert_eq!(consumed, 3);

        let (offer, consumed) = parse_security_offer(&[1, 1, 0xaa]).unwrap();
        assert_eq!(offer, SecurityOffer::Types(vec![SecurityType::None]));
        assert_eq!(consumed, 2);
    }

    #[test]
    fn parses_refusal() {
        let (offer, consumed) =
            parse_security_offer(&[0, 0, 0, 0, 5, b'd', b'e', b'n', b'i', b'e']).unwrap();
        assert_eq!(
            offer,
            SecurityOffer::Failure {
                reason: "denie".to_owned()
            }
        );
        assert_eq!(consumed, 10);
    }

    #[test]
    fn rejects_truncated_offers() {
        assert_eq!(parse_security_offer(&[]).unwrap_err(), Error::UnexpectedEof);
        assert_eq!(
            parse_security_offer(&[2, 1]).unwrap_err(),
            Error::UnexpectedEof
        );
        assert_eq!(
            parse_security_offer(&[0, 0, 0, 0, 9, b'x']).unwrap_err(),
            Error::UnexpectedEof
        );
    }

    #[test]
    fn maps_security_results() {
        assert_eq!(SecurityResult::from_u32(0), SecurityResult::Ok);
        assert_eq!(SecurityResult::from_u32(1), SecurityResult::Failed);
        assert_eq!(SecurityResult::from_u32(2), SecurityResult::TooManyAttempts);
        assert_eq!(SecurityResult::from_u32(9), SecurityResult::Unknown(9));
    }
}
