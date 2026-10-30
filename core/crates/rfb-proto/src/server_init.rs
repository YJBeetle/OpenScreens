//! RFB ServerInit message (RFC 6143 section 7.3.2).

use crate::Error;
use crate::pixel_format::{PIXEL_FORMAT_LEN, PixelFormat};

/// Framebuffer description sent by the server after authentication.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInit {
    pub width: u16,
    pub height: u16,
    pub pixel_format: PixelFormat,
    pub name: String,
}

pub const SERVER_INIT_HEADER_LEN: usize = 2 + 2 + PIXEL_FORMAT_LEN + 4;

/// Parses a ServerInit message. Returns the message and the number of bytes
/// consumed, so callers can keep the rest of their buffer.
pub fn parse_server_init(bytes: &[u8]) -> Result<(ServerInit, usize), Error> {
    if bytes.len() < SERVER_INIT_HEADER_LEN {
        return Err(Error::UnexpectedEof);
    }
    let width = u16::from_be_bytes([bytes[0], bytes[1]]);
    let height = u16::from_be_bytes([bytes[2], bytes[3]]);
    let pixel_format = PixelFormat::parse(&bytes[4..4 + PIXEL_FORMAT_LEN])?;
    let name_len = u32::from_be_bytes([bytes[20], bytes[21], bytes[22], bytes[23]]) as usize;
    let end = SERVER_INIT_HEADER_LEN
        .checked_add(name_len)
        .ok_or(Error::UnexpectedEof)?;
    if bytes.len() < end {
        return Err(Error::UnexpectedEof);
    }
    let name = String::from_utf8_lossy(&bytes[SERVER_INIT_HEADER_LEN..end]).into_owned();
    Ok((
        ServerInit {
            width,
            height,
            pixel_format,
            name,
        },
        end,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> Vec<u8> {
        let mut message = Vec::new();
        message.extend_from_slice(&1920u16.to_be_bytes());
        message.extend_from_slice(&1080u16.to_be_bytes());
        message.extend_from_slice(&PixelFormat::bgra8888().encode());
        message.extend_from_slice(&4u32.to_be_bytes());
        message.extend_from_slice(b"Mac\n");
        message
    }

    #[test]
    fn parses_server_init() {
        let bytes = sample();
        let (init, consumed) = parse_server_init(&bytes).unwrap();
        assert_eq!(init.width, 1920);
        assert_eq!(init.height, 1080);
        assert_eq!(init.pixel_format, PixelFormat::bgra8888());
        assert_eq!(init.name, "Mac\n");
        assert_eq!(consumed, bytes.len());
    }

    #[test]
    fn keeps_trailing_bytes() {
        let mut bytes = sample();
        bytes.extend_from_slice(&[3, 0]);
        let (_, consumed) = parse_server_init(&bytes).unwrap();
        assert_eq!(consumed, sample().len());
    }

    #[test]
    fn accepts_empty_name() {
        let mut bytes = sample();
        bytes.truncate(24);
        bytes[20..24].copy_from_slice(&0u32.to_be_bytes());
        let (init, consumed) = parse_server_init(&bytes).unwrap();
        assert_eq!(init.name, "");
        assert_eq!(consumed, 24);
    }

    #[test]
    fn rejects_truncated_messages() {
        let bytes = sample();
        assert_eq!(
            parse_server_init(&bytes[..10]).unwrap_err(),
            Error::UnexpectedEof
        );
        assert_eq!(
            parse_server_init(&bytes[..bytes.len() - 1]).unwrap_err(),
            Error::UnexpectedEof
        );
    }
}
