//! RFB ServerInit message (RFC 6143 section 7.3.2).

use crate::Error;
use crate::pixel_format::{PIXEL_FORMAT_LEN, PixelFormat};

/// Apple-specific fields carried inside the ServerInit name for RFB 3.889.
///
/// The macOS server prepends a 22-byte extension to the screen name when the
/// name length is greater than 21: five zero bytes, a flags byte, and two
/// big-endian feature bitmaps. Everything after the extension is the actual
/// screen name (VNCKit reads it with `subdataWithRange:22..nameLength`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AppleServerFeatures {
    pub flags: u8,
    /// First feature bitmap (`appleServerFeatureBits`).
    pub feature_bits: u64,
    /// Second feature bitmap (`appleServerFeatureBitsExt`).
    pub feature_bits_ext: u64,
}

impl AppleServerFeatures {
    /// Bit 32: the server accepts client pasteboard messages (message `0x1F`).
    pub const SERVER_CAN_RECEIVE_PASTEBOARD: u64 = 1 << 32;

    pub fn server_can_receive_pasteboard(&self) -> bool {
        self.feature_bits & Self::SERVER_CAN_RECEIVE_PASTEBOARD != 0
    }

    /// Bit 41: the clipboard integration ("automatic pasteboard") feature.
    pub fn has_clipboard_integration(&self) -> bool {
        self.feature_bits & (1 << 41) != 0
    }
}

/// Framebuffer description sent by the server after authentication.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ServerInit {
    pub width: u16,
    pub height: u16,
    pub pixel_format: PixelFormat,
    pub name: String,
    /// Apple extension parsed from the name (RFB 3.889 only).
    pub apple_features: Option<AppleServerFeatures>,
}

pub const SERVER_INIT_HEADER_LEN: usize = 2 + 2 + PIXEL_FORMAT_LEN + 4;

/// Parses a ServerInit message. Returns the message and the number of bytes
/// consumed, so callers can keep the rest of their buffer.
pub fn parse_server_init(bytes: &[u8]) -> Result<(ServerInit, usize), Error> {
    parse_server_init_ext(bytes, false)
}

/// Parses a ServerInit message, optionally decoding Apple's 22-byte name
/// extension (RFB 3.889). See [`AppleServerFeatures`].
pub fn parse_server_init_ext(bytes: &[u8], apple: bool) -> Result<(ServerInit, usize), Error> {
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
    let raw_name = &bytes[SERVER_INIT_HEADER_LEN..end];
    let (name_bytes, apple_features) = if apple && name_len > 21 && raw_name.len() >= 22 {
        // The extension is only recognised when its five reserved bytes are
        // zero, mirroring VNCKit's check. Anything else is a plain long name.
        if raw_name[..5].iter().all(|byte| *byte == 0) {
            let features = AppleServerFeatures {
                flags: raw_name[5],
                feature_bits: u64::from_be_bytes(raw_name[6..14].try_into().unwrap()),
                feature_bits_ext: u64::from_be_bytes(raw_name[14..22].try_into().unwrap()),
            };
            (&raw_name[22..], Some(features))
        } else {
            (raw_name, None)
        }
    } else {
        (raw_name, None)
    };
    let name = String::from_utf8_lossy(name_bytes).into_owned();
    Ok((
        ServerInit {
            width,
            height,
            pixel_format,
            name,
            apple_features,
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
        assert_eq!(init.apple_features, None);
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
    fn parses_apple_extension_inside_a_long_name() {
        let mut extension = vec![0u8; 22];
        extension[5] = 0x04;
        let bits = AppleServerFeatures::SERVER_CAN_RECEIVE_PASTEBOARD | (1 << 41);
        extension[6..14].copy_from_slice(&bits.to_be_bytes());
        extension[14..22].copy_from_slice(&7u64.to_be_bytes());

        let mut bytes = Vec::new();
        bytes.extend_from_slice(&1920u16.to_be_bytes());
        bytes.extend_from_slice(&1080u16.to_be_bytes());
        bytes.extend_from_slice(&PixelFormat::bgra8888().encode());
        let name_len = extension.len() + "Studio".len();
        bytes.extend_from_slice(&(name_len as u32).to_be_bytes());
        bytes.extend_from_slice(&extension);
        bytes.extend_from_slice(b"Studio");
        let (init, consumed) = parse_server_init_ext(&bytes, true).unwrap();
        assert_eq!(consumed, bytes.len());
        assert_eq!(init.name, "Studio");
        let features = init.apple_features.unwrap();
        assert_eq!(features.flags, 0x04);
        assert!(features.server_can_receive_pasteboard());
        assert!(features.has_clipboard_integration());
        assert_eq!(features.feature_bits_ext, 7);

        // Without Apple negotiation the same bytes stay a plain name.
        let (plain, _) = parse_server_init(&bytes).unwrap();
        assert!(plain.apple_features.is_none());
        assert_ne!(plain.name, "Studio");
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
