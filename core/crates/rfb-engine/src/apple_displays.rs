//! Apple's display-list pseudo-encodings (RFB 3.889).
//!
//! The macOS Screen Sharing server does not describe multiple displays with
//! the standard ExtendedDesktopSize pseudo-encoding (`-308`). VNCKit 5.9
//! (Screens 5) does not even advertise `-308`; it advertises Apple's own
//! pseudo-encodings `1100..1105` and learns the display list from ordinary
//! FramebufferUpdate rectangles:
//!
//! | encoding | handler | contents |
//! |---|---|---|
//! | `0x44C` (1100) | cursor position | not a display list |
//! | `0x44D` (1101) | `_handleUpdateRect` | desktop info with 28-byte display records |
//! | `0x450` (1104) | `_handleUpdateRect` | Apple cursor bitmap |
//! | `0x451` (1105) | `_handleUpdateRect` | desktop info 2 with 56-byte display records |
//!
//! `-[VncClient effectiveCodecs]` removes `1100`, `1101`, `1104` and `1105`
//! unless the negotiated protocol is Apple 3.888/3.889 (`protocol` 3 or 4).
//! `+[VncClient supportedCodecs]` contains exactly those four plus Adaptive
//! DCT, Tight, ZRLE, Zlib, CopyRect, Raw, LastRect, Cursor and DesktopSize.
//! The client version message `0x21` is unrelated: its 16-byte capability mask
//! only lists server message ids (`0, 2, 3, 20, 30, 31, 32, 34`), so sending
//! `0x21` alone does not request a display list. The server sends `0x44D`
//! and/or `0x451` only after the client advertises them in SetEncodings.
//!
//! # `0x44D` payload
//!
//! Everything below follows the 12-byte RFB rectangle header. VNCKit reads
//! 10 bytes, then `count * 28` bytes (verified at `_handleUpdateRect`
//! `0x12134` and `_VncAppleDesktopInfoBigToHost` `0x1fe58`):
//!
//! ```text
//! [0..2]   u16 BE desktop width in pixels
//! [2..4]   u16 BE desktop height in pixels
//! [4..8]   u32 BE opaque; VNCKit swaps but does not use it
//! [8..10]  u16 BE display count
//! per display (28 bytes):
//!   [0..4]   u32 BE display id
//!   [4..6]   u16 BE pixel width
//!   [6..8]   u16 BE pixel height
//!   [8..12]  u32 BE flags
//!   [12..28] 16-byte server pixel format
//! ```
//!
//! The pixel format has the same field order as an RFB PIXEL_FORMAT:
//! `bpp, depth, big_endian, true_colour, red_max, green_max, blue_max,
//! red_shift, green_shift, blue_shift, padding[3]` (the two 16-bit maxima are
//! big-endian, the rest are bytes).
//!
//! # `0x451` payload
//!
//! VNCKit reads a two-byte length and then that many bytes
//! (`_handleUpdateRect` `0x125c4`/`0x12684`). The length must be
//! `20 + count * 56`; the count lives at offset 18 of the 20-byte header.
//! VNCKit rejects other sizes with "invalid VncAppleDesktopInfo2 size".
//!
//! ```text
//! [0..2]   u16 BE unknown
//! [2..4]   u16 BE desktop width in points
//! [4..6]   u16 BE desktop height in points
//! [6..8]   u16 BE framebuffer width in pixels
//! [8..10]  u16 BE framebuffer height in pixels
//! [10..14] u32 BE unknown
//! [14..18] u32 BE unknown
//! [18..20] u16 BE display count
//! per display (56 bytes):
//!   [0..8]    f64 BE pixels per point
//!   [8..16]   f64 BE viewer scale
//!   [16..20]  u32 BE display id
//!   [20..28]  four i16 BE: point top, left, bottom, right
//!   [28..36]  four i16 BE: pixel top, left, bottom, right
//!   [36..40]  u32 BE flags
//!   [40..56]  16-byte server pixel format
//! ```
//!
//! Both encodings are transported as pseudo-rectangles inside message 0, so
//! the caller must consume `count` rectangles from the update rather than
//! treating them as pixel data. These parsers take the bytes *after* the
//! 12-byte rectangle header.

use std::fmt;

/// Apple desktop info pseudo-encoding id.
pub const APPLE_DESKTOP_INFO_ENCODING: i32 = 0x44D;
/// Apple desktop info 2 pseudo-encoding id.
pub const APPLE_DESKTOP_INFO_2_ENCODING: i32 = 0x451;

/// Fixed part of an `0x44D` payload.
pub const APPLE_DESKTOP_INFO_HEADER_LEN: usize = 10;
/// Wire size of one `0x44D` display record.
pub const APPLE_DISPLAY_LEN: usize = 28;
/// Fixed part of an `0x451` payload (the 20 bytes after the length prefix).
pub const APPLE_DESKTOP_INFO_2_HEADER_LEN: usize = 20;
/// Wire size of one `0x451` display record.
pub const APPLE_DISPLAY_2_LEN: usize = 56;

/// Pixel format reported per display. Same layout as an RFB pixel format
/// without the trailing padding being exposed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ApplePixelFormat {
    pub bits_per_pixel: u8,
    pub depth: u8,
    pub big_endian: bool,
    pub true_colour: bool,
    pub red_max: u16,
    pub green_max: u16,
    pub blue_max: u16,
    pub red_shift: u8,
    pub green_shift: u8,
    pub blue_shift: u8,
}

/// One display from an Apple desktop info (`0x44D`) rectangle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleDisplay {
    pub id: u32,
    pub width: u16,
    pub height: u16,
    pub flags: u32,
    pub pixel_format: ApplePixelFormat,
}

/// Parsed `0x44D` payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppleDesktopInfo {
    /// Desktop width in pixels.
    pub width: u16,
    /// Desktop height in pixels.
    pub height: u16,
    /// Opaque header word at payload offset 4; VNCKit ignores it.
    pub flags: u32,
    pub displays: Vec<AppleDisplay>,
}

/// A rectangle in the `0x451` display record. `top`/`left` can be negative
/// for displays placed above or left of the primary display.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct AppleDisplayRect {
    pub top: i16,
    pub left: i16,
    pub bottom: i16,
    pub right: i16,
}

impl AppleDisplayRect {
    /// Pixel width, saturating at zero for malformed inverted rectangles.
    pub fn width(&self) -> u16 {
        u16::try_from(i32::from(self.right) - i32::from(self.left)).unwrap_or(0)
    }

    /// Pixel height, saturating at zero for malformed inverted rectangles.
    pub fn height(&self) -> u16 {
        u16::try_from(i32::from(self.bottom) - i32::from(self.top)).unwrap_or(0)
    }
}

/// One display from an Apple desktop info 2 (`0x451`) rectangle.
#[derive(Debug, Clone, PartialEq)]
pub struct AppleDisplay2 {
    pub id: u32,
    /// Backing scale of the display (1.0 for non-Retina, 2.0 for Retina).
    pub pixels_per_point: f64,
    /// Server-side viewer scale factor.
    pub viewer_scale: f64,
    /// Display frame in desktop points.
    pub point_rect: AppleDisplayRect,
    /// Display frame in framebuffer pixels.
    pub pixel_rect: AppleDisplayRect,
    pub flags: u32,
    pub pixel_format: ApplePixelFormat,
}

/// Parsed `0x451` payload.
#[derive(Debug, Clone, PartialEq)]
pub struct AppleDesktopInfo2 {
    /// Framebuffer width in pixels (header offset 6).
    pub width: u16,
    /// Framebuffer height in pixels (header offset 8).
    pub height: u16,
    pub displays: Vec<AppleDisplay2>,
}

/// Errors raised while parsing a display-info rectangle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AppleDisplayError {
    /// Fewer bytes were supplied than the structure requires.
    Truncated { needed: usize, available: usize },
    /// Bytes remain after the declared number of records.
    Trailing { expected: usize, available: usize },
    /// `0x451` length is not `20 + n * 56`.
    InvalidPayloadLength(usize),
    /// The `0x451` header count disagrees with the payload length.
    DisplayCountMismatch { declared: u16, actual: usize },
}

impl fmt::Display for AppleDisplayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated { needed, available } => {
                write!(
                    f,
                    "truncated display info: need {needed} bytes, got {available}"
                )
            }
            Self::Trailing {
                expected,
                available,
            } => write!(f, "display info has {available} bytes, expected {expected}"),
            Self::InvalidPayloadLength(length) => {
                write!(f, "invalid Apple desktop info 2 size {length}")
            }
            Self::DisplayCountMismatch { declared, actual } => write!(
                f,
                "Apple desktop info 2 declares {declared} displays, payload holds {actual}"
            ),
        }
    }
}

impl std::error::Error for AppleDisplayError {}

/// Parses the payload of a `0x44D` (Apple desktop info) rectangle, i.e. the
/// bytes following the 12-byte RFB rectangle header.
pub fn parse_apple_desktop_info(bytes: &[u8]) -> Result<AppleDesktopInfo, AppleDisplayError> {
    if bytes.len() < APPLE_DESKTOP_INFO_HEADER_LEN {
        return Err(AppleDisplayError::Truncated {
            needed: APPLE_DESKTOP_INFO_HEADER_LEN,
            available: bytes.len(),
        });
    }

    let width = read_u16(bytes, 0);
    let height = read_u16(bytes, 2);
    let flags = read_u32(bytes, 4);
    let count = usize::from(read_u16(bytes, 8));
    let expected = APPLE_DESKTOP_INFO_HEADER_LEN + count * APPLE_DISPLAY_LEN;

    if bytes.len() < expected {
        return Err(AppleDisplayError::Truncated {
            needed: expected,
            available: bytes.len(),
        });
    }
    if bytes.len() > expected {
        return Err(AppleDisplayError::Trailing {
            expected,
            available: bytes.len(),
        });
    }

    let displays = bytes[APPLE_DESKTOP_INFO_HEADER_LEN..]
        .as_chunks::<APPLE_DISPLAY_LEN>()
        .0
        .iter()
        .map(|record| parse_display(record))
        .collect();

    Ok(AppleDesktopInfo {
        width,
        height,
        flags,
        displays,
    })
}

/// Parses the payload of a `0x44D` rectangle and returns just the displays.
pub fn parse_apple_displays(bytes: &[u8]) -> Result<Vec<AppleDisplay>, AppleDisplayError> {
    Ok(parse_apple_desktop_info(bytes)?.displays)
}

/// Parses the payload of a `0x451` (Apple desktop info 2) rectangle, i.e. the
/// bytes following the 12-byte RFB rectangle header. The payload starts with
/// the two-byte big-endian length prefix.
pub fn parse_apple_desktop_info2(bytes: &[u8]) -> Result<AppleDesktopInfo2, AppleDisplayError> {
    if bytes.len() < 2 {
        return Err(AppleDisplayError::Truncated {
            needed: 2,
            available: bytes.len(),
        });
    }

    let declared = usize::from(read_u16(bytes, 0));
    let expected = 2 + declared;
    if bytes.len() < expected {
        return Err(AppleDisplayError::Truncated {
            needed: expected,
            available: bytes.len(),
        });
    }
    if bytes.len() > expected {
        return Err(AppleDisplayError::Trailing {
            expected,
            available: bytes.len(),
        });
    }

    let body = &bytes[2..];
    if body.len() < APPLE_DESKTOP_INFO_2_HEADER_LEN
        || !(body.len() - APPLE_DESKTOP_INFO_2_HEADER_LEN).is_multiple_of(APPLE_DISPLAY_2_LEN)
    {
        return Err(AppleDisplayError::InvalidPayloadLength(body.len()));
    }

    let count = usize::from(read_u16(body, 18));
    let actual = (body.len() - APPLE_DESKTOP_INFO_2_HEADER_LEN) / APPLE_DISPLAY_2_LEN;
    if count != actual {
        return Err(AppleDisplayError::DisplayCountMismatch {
            declared: u16::try_from(count).unwrap_or(u16::MAX),
            actual,
        });
    }

    let displays = body[APPLE_DESKTOP_INFO_2_HEADER_LEN..]
        .as_chunks::<APPLE_DISPLAY_2_LEN>()
        .0
        .iter()
        .map(|record| parse_display2(record))
        .collect();

    Ok(AppleDesktopInfo2 {
        width: read_u16(body, 6),
        height: read_u16(body, 8),
        displays,
    })
}

fn parse_display(record: &[u8]) -> AppleDisplay {
    AppleDisplay {
        id: read_u32(record, 0),
        width: read_u16(record, 4),
        height: read_u16(record, 6),
        flags: read_u32(record, 8),
        pixel_format: parse_pixel_format(&record[12..28]),
    }
}

fn parse_display2(record: &[u8]) -> AppleDisplay2 {
    AppleDisplay2 {
        pixels_per_point: f64::from_be_bytes(record[0..8].try_into().unwrap()),
        viewer_scale: f64::from_be_bytes(record[8..16].try_into().unwrap()),
        id: read_u32(record, 16),
        point_rect: AppleDisplayRect {
            top: read_i16(record, 20),
            left: read_i16(record, 22),
            bottom: read_i16(record, 24),
            right: read_i16(record, 26),
        },
        pixel_rect: AppleDisplayRect {
            top: read_i16(record, 28),
            left: read_i16(record, 30),
            bottom: read_i16(record, 32),
            right: read_i16(record, 34),
        },
        flags: read_u32(record, 36),
        pixel_format: parse_pixel_format(&record[40..56]),
    }
}

fn parse_pixel_format(bytes: &[u8]) -> ApplePixelFormat {
    ApplePixelFormat {
        bits_per_pixel: bytes[0],
        depth: bytes[1],
        big_endian: bytes[2] != 0,
        true_colour: bytes[3] != 0,
        red_max: read_u16(bytes, 4),
        green_max: read_u16(bytes, 6),
        blue_max: read_u16(bytes, 8),
        red_shift: bytes[10],
        green_shift: bytes[11],
        blue_shift: bytes[12],
    }
}

fn read_u16(bytes: &[u8], offset: usize) -> u16 {
    u16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_i16(bytes: &[u8], offset: usize) -> i16 {
    i16::from_be_bytes([bytes[offset], bytes[offset + 1]])
}

fn read_u32(bytes: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([
        bytes[offset],
        bytes[offset + 1],
        bytes[offset + 2],
        bytes[offset + 3],
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pixel_format() -> [u8; 16] {
        let mut format = [0u8; 16];
        format[0] = 32;
        format[1] = 24;
        format[3] = 1;
        format[4..6].copy_from_slice(&255u16.to_be_bytes());
        format[6..8].copy_from_slice(&255u16.to_be_bytes());
        format[8..10].copy_from_slice(&255u16.to_be_bytes());
        format[10] = 16;
        format[11] = 8;
        format
    }

    fn display(id: u32, width: u16, height: u16, flags: u32) -> Vec<u8> {
        let mut record = Vec::new();
        record.extend_from_slice(&id.to_be_bytes());
        record.extend_from_slice(&width.to_be_bytes());
        record.extend_from_slice(&height.to_be_bytes());
        record.extend_from_slice(&flags.to_be_bytes());
        record.extend_from_slice(&pixel_format());
        record
    }

    fn desktop_info(width: u16, height: u16, displays: &[Vec<u8>]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&width.to_be_bytes());
        payload.extend_from_slice(&height.to_be_bytes());
        payload.extend_from_slice(&0u32.to_be_bytes());
        payload.extend_from_slice(&(displays.len() as u16).to_be_bytes());
        for display in displays {
            payload.extend_from_slice(display);
        }
        payload
    }

    fn desktop_info2(width: u16, height: u16, displays: &[Vec<u8>]) -> Vec<u8> {
        let mut body = Vec::new();
        body.extend_from_slice(&0u16.to_be_bytes());
        body.extend_from_slice(&width.to_be_bytes());
        body.extend_from_slice(&height.to_be_bytes());
        body.extend_from_slice(&width.to_be_bytes());
        body.extend_from_slice(&height.to_be_bytes());
        body.extend_from_slice(&0u32.to_be_bytes());
        body.extend_from_slice(&0u32.to_be_bytes());
        body.extend_from_slice(&(displays.len() as u16).to_be_bytes());
        for display in displays {
            body.extend_from_slice(display);
        }

        let mut payload = Vec::new();
        payload.extend_from_slice(&(body.len() as u16).to_be_bytes());
        payload.extend_from_slice(&body);
        payload
    }

    fn display2(id: u32) -> Vec<u8> {
        let mut record = Vec::new();
        record.extend_from_slice(&2.0f64.to_be_bytes());
        record.extend_from_slice(&1.0f64.to_be_bytes());
        record.extend_from_slice(&id.to_be_bytes());
        for value in [0i16, 0, 1692, 3008] {
            record.extend_from_slice(&value.to_be_bytes());
        }
        for value in [0i16, 0, 1692, 3008] {
            record.extend_from_slice(&value.to_be_bytes());
        }
        record.extend_from_slice(&1u32.to_be_bytes());
        record.extend_from_slice(&pixel_format());
        record
    }

    #[test]
    fn parses_a_single_display() {
        let payload = desktop_info(3008, 1692, &[display(1, 3008, 1692, 1)]);
        let info = parse_apple_desktop_info(&payload).unwrap();

        assert_eq!(info.width, 3008);
        assert_eq!(info.height, 1692);
        assert_eq!(info.flags, 0);
        assert_eq!(info.displays.len(), 1);
        assert_eq!(
            info.displays[0],
            AppleDisplay {
                id: 1,
                width: 3008,
                height: 1692,
                flags: 1,
                pixel_format: ApplePixelFormat {
                    bits_per_pixel: 32,
                    depth: 24,
                    big_endian: false,
                    true_colour: true,
                    red_max: 255,
                    green_max: 255,
                    blue_max: 255,
                    red_shift: 16,
                    green_shift: 8,
                    blue_shift: 0,
                },
            }
        );
    }

    #[test]
    fn parses_multiple_displays_in_order() {
        let payload = desktop_info(
            6016,
            1692,
            &[display(1, 3008, 1692, 1), display(2, 1920, 1080, 0)],
        );
        let displays = parse_apple_displays(&payload).unwrap();

        assert_eq!(displays.len(), 2);
        assert_eq!((displays[0].id, displays[0].width), (1, 3008));
        assert_eq!((displays[1].id, displays[1].width), (2, 1920));
        assert_eq!(displays[1].height, 1080);
    }

    #[test]
    fn accepts_zero_displays() {
        let payload = desktop_info(0, 0, &[]);
        let info = parse_apple_desktop_info(&payload).unwrap();

        assert!(info.displays.is_empty());
    }

    #[test]
    fn rejects_truncated_header() {
        let payload = [0u8; APPLE_DESKTOP_INFO_HEADER_LEN - 1];
        assert_eq!(
            parse_apple_displays(&payload),
            Err(AppleDisplayError::Truncated {
                needed: APPLE_DESKTOP_INFO_HEADER_LEN,
                available: APPLE_DESKTOP_INFO_HEADER_LEN - 1,
            })
        );
    }

    #[test]
    fn rejects_truncated_display_record() {
        let mut payload = desktop_info(3008, 1692, &[display(1, 3008, 1692, 1)]);
        payload.pop();

        assert_eq!(
            parse_apple_displays(&payload),
            Err(AppleDisplayError::Truncated {
                needed: APPLE_DESKTOP_INFO_HEADER_LEN + APPLE_DISPLAY_LEN,
                available: APPLE_DESKTOP_INFO_HEADER_LEN + APPLE_DISPLAY_LEN - 1,
            })
        );
    }

    #[test]
    fn rejects_trailing_bytes() {
        let mut payload = desktop_info(3008, 1692, &[display(1, 3008, 1692, 1)]);
        payload.push(0);

        assert_eq!(
            parse_apple_displays(&payload),
            Err(AppleDisplayError::Trailing {
                expected: APPLE_DESKTOP_INFO_HEADER_LEN + APPLE_DISPLAY_LEN,
                available: APPLE_DESKTOP_INFO_HEADER_LEN + APPLE_DISPLAY_LEN + 1,
            })
        );
    }

    #[test]
    fn parses_desktop_info_2() {
        let payload = desktop_info2(3008, 1692, &[display2(1)]);
        let info = parse_apple_desktop_info2(&payload).unwrap();

        assert_eq!((info.width, info.height), (3008, 1692));
        assert_eq!(info.displays.len(), 1);
        let display = &info.displays[0];
        assert_eq!(display.id, 1);
        assert_eq!(display.pixels_per_point, 2.0);
        assert_eq!(display.viewer_scale, 1.0);
        assert_eq!(display.pixel_rect.width(), 3008);
        assert_eq!(display.pixel_rect.height(), 1692);
        assert_eq!(display.point_rect.width(), 3008);
        assert_eq!(display.flags, 1);
        assert_eq!(display.pixel_format.bits_per_pixel, 32);
    }

    #[test]
    fn parses_negative_display_origin() {
        let mut record = display2(2);
        record[20..22].copy_from_slice(&(-1080i16).to_be_bytes());
        record[22..24].copy_from_slice(&0i16.to_be_bytes());
        record[24..26].copy_from_slice(&0i16.to_be_bytes());
        record[26..28].copy_from_slice(&1920i16.to_be_bytes());
        record[28..30].copy_from_slice(&(-1080i16).to_be_bytes());
        record[30..32].copy_from_slice(&0i16.to_be_bytes());
        record[32..34].copy_from_slice(&0i16.to_be_bytes());
        record[34..36].copy_from_slice(&1920i16.to_be_bytes());

        let info = parse_apple_desktop_info2(&desktop_info2(3008, 1692, &[record])).unwrap();
        let display = &info.displays[0];

        assert_eq!(display.point_rect.top, -1080);
        assert_eq!(display.pixel_rect.top, -1080);
        assert_eq!(display.pixel_rect.width(), 1920);
        assert_eq!(display.pixel_rect.height(), 1080);
    }

    #[test]
    fn rejects_short_length_prefix() {
        assert_eq!(
            parse_apple_desktop_info2(&[0]),
            Err(AppleDisplayError::Truncated {
                needed: 2,
                available: 1,
            })
        );
    }

    #[test]
    fn rejects_truncated_desktop_info_2() {
        let mut payload = desktop_info2(3008, 1692, &[display2(1)]);
        payload.pop();

        assert_eq!(
            parse_apple_desktop_info2(&payload),
            Err(AppleDisplayError::Truncated {
                needed: 2 + APPLE_DESKTOP_INFO_2_HEADER_LEN + APPLE_DISPLAY_2_LEN,
                available: 2 + APPLE_DESKTOP_INFO_2_HEADER_LEN + APPLE_DISPLAY_2_LEN - 1,
            })
        );
    }

    #[test]
    fn rejects_misaligned_desktop_info_2() {
        let mut payload = desktop_info2(3008, 1692, &[display2(1)]);
        payload.push(0);
        let body_len = (payload.len() - 2) as u16;
        payload[0..2].copy_from_slice(&body_len.to_be_bytes());

        assert_eq!(
            parse_apple_desktop_info2(&payload),
            Err(AppleDisplayError::InvalidPayloadLength(
                APPLE_DESKTOP_INFO_2_HEADER_LEN + APPLE_DISPLAY_2_LEN + 1
            ))
        );
    }

    #[test]
    fn rejects_display_count_mismatch() {
        let mut payload = desktop_info2(3008, 1692, &[display2(1)]);
        // Header count field is at [2 + 18..2 + 20].
        payload[20..22].copy_from_slice(&2u16.to_be_bytes());

        assert_eq!(
            parse_apple_desktop_info2(&payload),
            Err(AppleDisplayError::DisplayCountMismatch {
                declared: 2,
                actual: 1,
            })
        );
    }
}
