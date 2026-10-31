//! Apple RFB 3.889 keyboard input and server pasteboard (message `0x1F`).
//!
//! # Keyboard events
//!
//! Layout verified by disassembling VNCKit 5.9 (Screens 5):
//! `-[VncClient sendAppleKeyEvent:keyCode:directionDown:timeDeltaUS:]` and its
//! block invoke (`0x15a24`). The method takes `(u16 keyEvent, u16 keyCode,
//! BOOL down, u32 timeDeltaUS)` (Objective-C type encoding
//! `B32@0:8S16S20B24I28`) and writes the following 16-byte header:
//!
//! ```text
//! [0]     0xFF
//! [1]     1 while the key is down, 0 on release
//! [2..4]  0
//! [4..6]  u16 BE "key event" (the Unicode character of the key, 0 if none)
//! [6..10] u32 BE microseconds since the previous input event
//! [10..13] 0
//! [13]    0x2F
//! [14..16] u16 BE macOS virtual key code
//! ```
//!
//! The call site in the Screens app passes `[NSEvent keyCode]` as the second
//! argument and a value derived from `NSEvent.characters` as the first, i.e.
//! the key code is a **macOS virtual key code** (`kVK_*`), not an X11 keysym.
//! The clear 2-byte prefix is `[0x10, direction ^ 1]` with direction 0 for
//! keys, so wire byte 1 is 1.
//!
//! Note that this differs from the previously assumed layout: the macOS key
//! code lives at `[14..16]`, while `[4..6]` carries the Unicode character.
//! Both fields are filled so the message matches VNCKit byte for byte.
//!
//! # Server pasteboard
//!
//! Message `0x1F` is a 16-byte header followed by a zlib stream:
//! `[0]=0x1F`, `[2]=preview`, `[8..12]=u32 BE decompressed size`,
//! `[12..16]=u32 BE compressed size` (verified in
//! `-[VncClient _handleApplePasteboard]` and `-[VncClient sendPasteboard:preview:]`).
//! The inflated archive (`_read_pb_message_data_from_tempfile`, `0x13684`) is:
//!
//! ```text
//! u32 BE item count
//! per item:
//!   u32 BE type length; type (UTF-8, may be NUL padded)
//!   u32 BE reserved (written as 0, ignored on read)
//!   u32 BE flavor count
//!   per flavor:
//!     u32 BE name length; name
//!     u32 BE value length; value
//!   u32 BE data length; data (raw bytes: text, URL, TIFF, RTFD, ...)
//! ```
//!
//! Text items indicate their encoding with a `public.utf8-plain-text` or
//! `public.utf16-plain-text` flavor; the actual bytes live in the data block.
//! URLs carry the UTF-8 URL string in the data block.

use std::fmt;
use std::io::{Read, Write};

use flate2::Compression;
use flate2::read::{DeflateDecoder, ZlibDecoder};
use flate2::write::ZlibEncoder;
use rfb_proto::apple_auth::{AES_KEY_LEN, encrypt_apple_input_message};

/// Server-to-client pasteboard message id.
pub const MSG_SERVER_PASTEBOARD: u8 = 0x1F;

/// Length of the pasteboard message header (including the message id).
pub const PASTEBOARD_HEADER_LEN: usize = 16;

/// Length of an encrypted Apple input message.
pub const APPLE_KEY_MESSAGE_LEN: usize = 18;

/// Constant found at byte 13 of every VNCKit keyboard header.
const KEY_HEADER_MARKER: u8 = 0x2F;

const KEY_HEADER_TAG: u8 = 0xFF;

const PASTEBOARD_TYPE_RESERVED: usize = 4;

/// The parts of a server pasteboard that a client can display synchronously.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ApplePasteboard {
    /// First text item found (`public.text` / `public.utf8-plain-text`).
    pub text: Option<String>,
    /// All `public.url` / `public.file-url` items in wire order.
    pub urls: Vec<String>,
    /// Every pasteboard type name in the archive, in wire order.
    pub types: Vec<String>,
}

/// Errors produced while decoding Apple input and pasteboard data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppleInputError {
    /// The input ends before a declared length is satisfied.
    Truncated,
    /// A length field is impossible (overflow, odd UTF-16 byte count, ...).
    BadLength,
    /// The zlib/deflate payload could not be inflated.
    Compression,
    /// A string field is not valid UTF-8/UTF-16.
    BadUtf8,
}

impl fmt::Display for AppleInputError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => f.write_str("truncated Apple input message"),
            Self::BadLength => f.write_str("invalid Apple input length"),
            Self::Compression => f.write_str("Apple pasteboard decompression failed"),
            Self::BadUtf8 => f.write_str("invalid text in Apple pasteboard"),
        }
    }
}

impl std::error::Error for AppleInputError {}

/// Builds the 16-byte plaintext header for an Apple keyboard event.
///
/// Returns `None` when the keysym has no macOS virtual-key-code equivalent.
/// See the module documentation for the verified field layout.
pub fn apple_key_header(keysym: u32, down: bool, delta_us: u32) -> Option<[u8; AES_KEY_LEN]> {
    let keycode = keysym_to_apple_keycode(keysym)?;
    let character = keysym_to_apple_character(keysym).unwrap_or(0);

    let mut header = [0u8; AES_KEY_LEN];
    header[0] = KEY_HEADER_TAG;
    header[1] = u8::from(down);
    header[4..6].copy_from_slice(&character.to_be_bytes());
    header[6..10].copy_from_slice(&delta_us.to_be_bytes());
    header[13] = KEY_HEADER_MARKER;
    header[14..16].copy_from_slice(&keycode.to_be_bytes());
    Some(header)
}

/// Builds the 18-byte encrypted keyboard message for an RFB 3.889 session.
///
/// `key` is the AES-128 session key from Apple DH authentication. Returns
/// `None` when [`keysym_to_apple_keycode`] does not know the keysym.
pub fn apple_key_message(
    key: &[u8; AES_KEY_LEN],
    keysym: u32,
    down: bool,
    delta_us: u32,
) -> Option<[u8; APPLE_KEY_MESSAGE_LEN]> {
    let header = apple_key_header(keysym, down, delta_us)?;
    Some(encrypt_apple_input_message(key, &header, 0))
}

/// Maps an X11 keysym to a macOS virtual key code (`kVK_*`).
///
/// The mapping is layout-independent (ANSI/US positions), which is what
/// `NSEvent.keyCode` reports for the key that was physically pressed.
/// Uppercase keysyms and shifted punctuation map to their base key.
/// Returns `None` for keysyms without a corresponding macOS key.
pub fn keysym_to_apple_keycode(keysym: u32) -> Option<u16> {
    let code = match keysym {
        // Letters (both cases map to the same physical key).
        0x61..=0x7a => LETTER_KEYS[(keysym - 0x61) as usize],
        0x41..=0x5a => LETTER_KEYS[(keysym - 0x41) as usize],
        // Digits.
        0x30..=0x39 => DIGIT_KEYS[(keysym - 0x30) as usize],
        // Punctuation and its shifted variants.
        0x20 => 49, // space
        0x21 => 18, // exclam -> 1
        0x22 => 39, // quotedbl -> '
        0x23 => 20, // numbersign -> 3
        0x24 => 21, // dollar -> 4
        0x25 => 23, // percent -> 5
        0x26 => 22, // ampersand -> 6
        0x27 => 39, // apostrophe
        0x28 => 25, // parenleft -> 9
        0x29 => 29, // parenright -> 0
        0x2a => 28, // asterisk -> 8
        0x2b => 24, // plus -> =
        0x2c => 43, // comma
        0x2d => 27, // minus
        0x2e => 47, // period
        0x2f => 44, // slash
        0x3a => 41, // colon -> ;
        0x3b => 41, // semicolon
        0x3c => 43, // less -> ,
        0x3d => 24, // equal
        0x3e => 47, // greater -> .
        0x3f => 44, // question -> /
        0x40 => 19, // at -> 2
        0x5b => 33, // bracketleft
        0x5c => 42, // backslash
        0x5d => 30, // bracketright
        0x5e => 22, // asciicircum -> 6
        0x5f => 27, // underscore -> -
        0x60 => 50, // grave
        0x7b => 33, // braceleft -> [
        0x7c => 42, // bar -> backslash
        0x7d => 30, // braceright -> ]
        0x7e => 50, // asciitilde -> `
        // Editing and navigation keys.
        0xff08 => 51,  // BackSpace -> kVK_Delete
        0xff09 => 48,  // Tab
        0xff0a => 36,  // Linefeed -> Return
        0xff0b => 71,  // Clear -> kVK_KeypadClear
        0xff0d => 36,  // Return
        0xff1b => 53,  // Escape
        0xff50 => 115, // Home
        0xff51 => 123, // Left
        0xff52 => 126, // Up
        0xff53 => 124, // Right
        0xff54 => 125, // Down
        0xff55 => 116, // Page_Up
        0xff56 => 121, // Page_Down
        0xff57 => 119, // End
        0xff58 => 115, // Begin -> Home
        0xff63 => 114, // Insert -> kVK_Help
        0xff6a => 114, // Help
        0xffff => 117, // Delete -> kVK_ForwardDelete
        // Modifiers.
        0xfe03 => 58, // ISO_Level3_Shift -> Option
        0xffe1 => 56, // Shift_L
        0xffe2 => 60, // Shift_R
        0xffe3 => 59, // Control_L
        0xffe4 => 62, // Control_R
        0xffe5 => 57, // Caps_Lock
        0xffe6 => 57, // Shift_Lock -> Caps Lock
        0xffe7 => 55, // Meta_L -> Command
        0xffe8 => 54, // Meta_R -> Right Command
        0xffe9 => 58, // Alt_L -> Option
        0xffea => 61, // Alt_R -> Right Option
        0xffeb => 55, // Super_L -> Command
        0xffec => 54, // Super_R -> Right Command
        // Function keys.
        0xffbe..=0xffc9 => FUNCTION_KEYS[(keysym - 0xffbe) as usize],
        // Keypad.
        0xff8d => 76, // KP_Enter
        0xffaa => 67, // KP_Multiply
        0xffab => 69, // KP_Add
        0xffac => 65, // KP_Separator -> KeypadDecimal
        0xffad => 78, // KP_Subtract
        0xffae => 65, // KP_Decimal
        0xffaf => 75, // KP_Divide
        0xffb0..=0xffb9 => KEYPAD_DIGITS[(keysym - 0xffb0) as usize],
        0xffbd => 81, // KP_Equal
        0xff7f => 71, // Num_Lock -> KeypadClear
        _ => return None,
    };
    Some(code)
}

/// The Unicode character VNCKit would put in the `key event` field.
///
/// Printable Latin-1 keysyms map to themselves. macOS reports function keys
/// in the `U+F700..U+F70F` range, which is reproduced here so a message is
/// byte-identical to VNCKit's. Modifier keys report `None` (the field is 0).
fn keysym_to_apple_character(keysym: u32) -> Option<u16> {
    let character = match keysym {
        0x20..=0x7e => keysym as u16,
        0xff08 => 0x7f,            // BackSpace -> DEL
        0xff09 => 0x09,            // Tab
        0xff0a => 0x0a,            // Linefeed
        0xff0d => 0x0d,            // Return
        0xff1b => 0x1b,            // Escape
        0xff50 | 0xff58 => 0xf729, // Home
        0xff51 => 0xf702,          // Left
        0xff52 => 0xf700,          // Up
        0xff53 => 0xf703,          // Right
        0xff54 => 0xf701,          // Down
        0xff55 => 0xf72c,          // Page_Up
        0xff56 => 0xf72d,          // Page_Down
        0xff57 => 0xf72b,          // End
        0xff63 => 0xf727,          // Insert
        0xffff => 0xf728,          // Forward Delete
        0xffbe..=0xffc9 => 0xf704 + (keysym - 0xffbe) as u16,
        0xff8d => 0x03, // KP_Enter
        0xffaa => 0x2a, // KP_Multiply
        0xffab => 0x2b, // KP_Add
        0xffac => 0x2c, // KP_Separator
        0xffad => 0x2d, // KP_Subtract
        0xffae => 0x2e, // KP_Decimal
        0xffaf => 0x2f, // KP_Divide
        0xffb0..=0xffb9 => 0x30 + (keysym - 0xffb0) as u16,
        0xffbd => 0x3d, // KP_Equal
        _ => return None,
    };
    Some(character)
}

/// Decodes a server pasteboard message or its compressed payload.
///
/// `message_or_payload` may be either the complete `0x1F` message (16-byte
/// header + zlib data, with the compressed length at `[12..16]`) or just the
/// compressed payload. Both zlib-wrapped and raw-deflate streams are accepted.
pub fn parse_server_pasteboard(
    message_or_payload: &[u8],
) -> Result<ApplePasteboard, AppleInputError> {
    let payload = if message_or_payload.first() == Some(&MSG_SERVER_PASTEBOARD)
        && message_or_payload.len() >= PASTEBOARD_HEADER_LEN
    {
        let length = u32::from_be_bytes([
            message_or_payload[12],
            message_or_payload[13],
            message_or_payload[14],
            message_or_payload[15],
        ]) as usize;
        let end = PASTEBOARD_HEADER_LEN
            .checked_add(length)
            .ok_or(AppleInputError::BadLength)?;
        if end > message_or_payload.len() {
            return Err(AppleInputError::Truncated);
        }
        &message_or_payload[PASTEBOARD_HEADER_LEN..end]
    } else {
        message_or_payload
    };

    let archive = inflate(payload)?;
    parse_archive(&archive)
}

/// Builds the pasteboard archive VNCKit sends for a plain-text pasteboard:
/// one `public.utf8-plain-text` item with that flavor and the same bytes as
/// its data block (`VncPasteboardData`).
pub fn client_pasteboard_archive(text: &str) -> Vec<u8> {
    let key = "public.utf8-plain-text";
    let mut archive = Vec::with_capacity(64 + text.len() * 2);
    push_u32(&mut archive, 1);
    push_string(&mut archive, key);
    push_u32(&mut archive, 0); // reserved, mirrors VNCKit's encoder
    push_u32(&mut archive, 1);
    push_string(&mut archive, key);
    push_string(&mut archive, text);
    push_u32(&mut archive, text.len() as u32);
    archive.extend_from_slice(text.as_bytes());
    archive
}

/// Builds a client-to-server pasteboard message (id `0x1F`).
///
/// Layout matches `-[VncClient sendPasteboard:preview:]`: a 16-byte header
/// (`[2]=preview`, `[8..12]=u32 BE uncompressed size`, `[12..16]=u32 BE
/// compressed size`) followed by a zlib stream. The server only advertises
/// support through feature bit 32 (`serverCanReceivePasteboard`).
pub fn client_pasteboard_message(text: &str) -> Vec<u8> {
    let archive = client_pasteboard_archive(text);
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    let _ = encoder.write_all(&archive);
    let compressed = encoder.finish().unwrap_or_default();

    let mut message = Vec::with_capacity(PASTEBOARD_HEADER_LEN + compressed.len());
    message.resize(PASTEBOARD_HEADER_LEN, 0);
    message[0] = MSG_SERVER_PASTEBOARD;
    message[2] = 0; // preview
    message[8..12].copy_from_slice(&(archive.len() as u32).to_be_bytes());
    message[12..16].copy_from_slice(&(compressed.len() as u32).to_be_bytes());
    message.extend_from_slice(&compressed);
    message
}

fn push_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn push_string(out: &mut Vec<u8>, value: &str) {
    push_u32(out, value.len() as u32);
    out.extend_from_slice(value.as_bytes());
}

fn inflate(payload: &[u8]) -> Result<Vec<u8>, AppleInputError> {
    let mut out = Vec::new();
    if ZlibDecoder::new(payload).read_to_end(&mut out).is_ok() && !out.is_empty() {
        return Ok(out);
    }
    out.clear();
    DeflateDecoder::new(payload)
        .read_to_end(&mut out)
        .map_err(|_| AppleInputError::Compression)?;
    if out.is_empty() {
        return Err(AppleInputError::Compression);
    }
    Ok(out)
}

/// Parses an already-decompressed pasteboard archive.
pub fn parse_pasteboard_archive(archive: &[u8]) -> Result<ApplePasteboard, AppleInputError> {
    parse_archive(archive)
}

/// Parses an already-decompressed archive that may contain several
/// concatenated item groups. VNCKit's drag-in template writes a fresh item
/// count for every URL, so a multi-file drag-in payload is several archives
/// back to back; drag-out payloads normally contain one group.
pub fn parse_pasteboard_archive_all(
    archive: &[u8],
) -> Result<ApplePasteboard, AppleInputError> {
    let mut cursor = Cursor::new(archive);
    let mut combined = ApplePasteboard::default();
    while cursor.pos < archive.len() {
        let start = cursor.pos;
        let pasteboard = parse_archive_group(&mut cursor)?;
        if cursor.pos == start {
            break;
        }
        if combined.text.is_none() {
            combined.text = pasteboard.text;
        }
        for url in pasteboard.urls {
            if !combined.urls.contains(&url) {
                combined.urls.push(url);
            }
        }
        combined.types.extend(pasteboard.types);
    }
    Ok(combined)
}

fn parse_archive(archive: &[u8]) -> Result<ApplePasteboard, AppleInputError> {
    let mut cursor = Cursor::new(archive);
    parse_archive_group(&mut cursor)
}

fn parse_archive_group(cursor: &mut Cursor<'_>) -> Result<ApplePasteboard, AppleInputError> {
    let item_count = cursor.take_u32()?;
    let mut pasteboard = ApplePasteboard::default();

    for _ in 0..item_count {
        let type_length = cursor.take_u32()? as usize;
        let type_name = cursor.take_str(type_length)?;
        // VNCKit writes four zero bytes between the type and the flavor count
        // and ignores them when reading.
        cursor.take(PASTEBOARD_TYPE_RESERVED)?;
        let flavor_count = cursor.take_u32()?;

        let mut utf16 = type_name == "public.utf16-plain-text";
        let mut flavor_text = None;
        for _ in 0..flavor_count {
            let name_length = cursor.take_u32()? as usize;
            let name = cursor.take_str(name_length)?;
            let value_length = cursor.take_u32()? as usize;
            let value = cursor.take_str(value_length)?;
            match name {
                "public.utf16-plain-text" => utf16 = true,
                "public.utf8-plain-text" => flavor_text = Some(value.to_string()),
                _ => {}
            }
        }

        let data_length = cursor.take_u32()? as usize;
        let data = cursor.take(data_length)?;
        pasteboard.types.push(type_name.to_string());

        if is_text_type(type_name) {
            if pasteboard.text.is_none() {
                let decoded = if utf16 {
                    decode_utf16(data)?
                } else {
                    decode_utf8(data)?
                };
                let candidate = if decoded.is_empty() {
                    flavor_text
                } else {
                    Some(decoded)
                };
                if let Some(text) = candidate.filter(|text| !text.is_empty()) {
                    pasteboard.text = Some(text);
                }
            }
        } else if is_url_type(type_name) {
            let url = decode_utf8(data)?;
            if !url.is_empty() && !pasteboard.urls.contains(&url) {
                pasteboard.urls.push(url);
            }
        }
    }

    Ok(pasteboard)
}

fn is_text_type(name: &str) -> bool {
    matches!(
        name,
        "public.text" | "public.utf8-plain-text" | "public.utf16-plain-text" | "NSStringPboardType"
    )
}

fn is_url_type(name: &str) -> bool {
    matches!(name, "public.url" | "public.file-url" | "NSURLPboardType")
}

fn decode_utf8(data: &[u8]) -> Result<String, AppleInputError> {
    let data = strip_trailing_nul(data);
    std::str::from_utf8(data)
        .map(str::to_string)
        .map_err(|_| AppleInputError::BadUtf8)
}

fn decode_utf16(data: &[u8]) -> Result<String, AppleInputError> {
    if !data.len().is_multiple_of(2) {
        return Err(AppleInputError::BadLength);
    }
    let (body, little_endian) = match data {
        [0xfe, 0xff, rest @ ..] => (rest, false),
        [0xff, 0xfe, rest @ ..] => (rest, true),
        _ => (data, false),
    };
    let units = body
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            if little_endian {
                u16::from_le_bytes([pair[0], pair[1]])
            } else {
                u16::from_be_bytes([pair[0], pair[1]])
            }
        })
        .collect::<Vec<_>>();
    let text = String::from_utf16(&units).map_err(|_| AppleInputError::BadUtf8)?;
    Ok(text.trim_end_matches('\0').to_string())
}

fn strip_trailing_nul(bytes: &[u8]) -> &[u8] {
    let mut end = bytes.len();
    while end > 0 && bytes[end - 1] == 0 {
        end -= 1;
    }
    &bytes[..end]
}

struct Cursor<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn take_u32(&mut self) -> Result<u32, AppleInputError> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], AppleInputError> {
        let end = self
            .pos
            .checked_add(length)
            .ok_or(AppleInputError::BadLength)?;
        if end > self.data.len() {
            return Err(AppleInputError::Truncated);
        }
        let slice = &self.data[self.pos..end];
        self.pos = end;
        Ok(slice)
    }

    fn take_str(&mut self, length: usize) -> Result<&'a str, AppleInputError> {
        let bytes = self.take(length)?;
        std::str::from_utf8(strip_trailing_nul(bytes)).map_err(|_| AppleInputError::BadUtf8)
    }
}

/// macOS virtual key codes for `a`..`z` (ANSI layout).
const LETTER_KEYS: [u16; 26] = [
    0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
];

/// macOS virtual key codes for `0`..`9`.
const DIGIT_KEYS: [u16; 10] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25];

/// macOS virtual key codes for `F1`..`F12`.
const FUNCTION_KEYS: [u16; 12] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111];

/// macOS virtual key codes for keypad `0`..`9`.
const KEYPAD_DIGITS: [u16; 10] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92];

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::Compression;
    use flate2::write::ZlibEncoder;
    use std::io::Write;

    const XK_RETURN: u32 = 0xff0d;
    const XK_BACK_SPACE: u32 = 0xff08;
    const XK_LEFT: u32 = 0xff51;
    const XK_UP: u32 = 0xff52;
    const XK_RIGHT: u32 = 0xff53;
    const XK_DOWN: u32 = 0xff54;

    #[test]
    fn maps_required_keysyms_to_macos_keycodes() {
        for (keysym, keycode) in [
            (b'a' as u32, 0x00),
            (b'A' as u32, 0x00),
            (b'z' as u32, 0x06),
            (b'0' as u32, 0x1d),
            (b'1' as u32, 0x12),
            (0x20, 0x31),
            (XK_RETURN, 0x24),
            (XK_BACK_SPACE, 0x33),
            (XK_LEFT, 0x7b),
            (XK_UP, 0x7e),
            (XK_RIGHT, 0x7c),
            (XK_DOWN, 0x7d),
            (0xffff, 0x75),
            (0xffe1, 0x38),
            (0xffe3, 0x3b),
            (0xffbe, 0x7a),
        ] {
            assert_eq!(
                keysym_to_apple_keycode(keysym),
                Some(keycode),
                "keysym {keysym:#x}"
            );
        }
        assert_eq!(keysym_to_apple_keycode(0x1008ff2a), None);
    }

    #[test]
    fn key_header_matches_vnckit_layout() {
        let header = apple_key_header(b'a' as u32, true, 42).unwrap();
        assert_eq!(header[0], 0xff);
        assert_eq!(header[1], 1);
        assert_eq!(&header[4..6], &[0x00, 0x61]);
        assert_eq!(&header[6..10], &42u32.to_be_bytes());
        assert_eq!(header[13], 0x2f);
        assert_eq!(&header[14..16], &[0x00, 0x00]);

        let return_header = apple_key_header(XK_RETURN, false, 0).unwrap();
        assert_eq!(&return_header[4..6], &[0x00, 0x0d]);
        assert_eq!(&return_header[14..16], &[0x00, 0x24]);

        let left = apple_key_header(XK_LEFT, true, 7).unwrap();
        assert_eq!(&left[4..6], &[0xf7, 0x02]);
        assert_eq!(&left[14..16], &[0x00, 0x7b]);
    }

    #[test]
    fn key_message_wraps_header_in_aes_frame() {
        let key = [0x5au8; AES_KEY_LEN];
        let message = apple_key_message(&key, b'z' as u32, true, 0x0a0b0c0d).unwrap();
        assert_eq!(message[0], 0x10);
        assert_eq!(message[1], 1);

        let header = apple_key_header(b'z' as u32, true, 0x0a0b0c0d).unwrap();
        let expected = encrypt_apple_input_message(&key, &header, 0);
        assert_eq!(message, expected);

        let release = apple_key_message(&key, XK_DOWN, false, 1).unwrap();
        assert_eq!(release[1], 1);
        let header = apple_key_header(XK_DOWN, false, 1).unwrap();
        assert_eq!(header[1], 0);
        assert_eq!(release, encrypt_apple_input_message(&key, &header, 0));

        assert!(apple_key_message(&key, 0x1008ff2a, true, 0).is_none());
    }

    fn push_u32(out: &mut Vec<u8>, value: u32) {
        out.extend_from_slice(&value.to_be_bytes());
    }

    fn push_str(out: &mut Vec<u8>, value: &str) {
        push_u32(out, value.len() as u32);
        out.extend_from_slice(value.as_bytes());
    }

    fn push_item(out: &mut Vec<u8>, kind: &str, flavors: &[(&str, &str)], data: &[u8]) {
        push_str(out, kind);
        push_u32(out, 0);
        push_u32(out, flavors.len() as u32);
        for (name, value) in flavors {
            push_str(out, name);
            push_str(out, value);
        }
        push_u32(out, data.len() as u32);
        out.extend_from_slice(data);
    }

    fn sample_archive() -> Vec<u8> {
        let mut archive = Vec::new();
        push_u32(&mut archive, 3);
        push_item(
            &mut archive,
            "public.text",
            &[("public.utf8-plain-text", "Hello")],
            "Hello, 世界".as_bytes(),
        );
        push_item(
            &mut archive,
            "public.url",
            &[],
            b"https://example.com/a?b=c",
        );
        push_item(
            &mut archive,
            "public.file-url",
            &[("com.apple.ostype", "furl")],
            b"file:///tmp/a%20b.txt",
        );
        archive
    }

    fn zlib(data: &[u8]) -> Vec<u8> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    fn message(archive: &[u8]) -> Vec<u8> {
        let compressed = zlib(archive);
        let mut message = vec![0u8; PASTEBOARD_HEADER_LEN];
        message[0] = MSG_SERVER_PASTEBOARD;
        message[2] = 1;
        message[8..12].copy_from_slice(&(archive.len() as u32).to_be_bytes());
        message[12..16].copy_from_slice(&(compressed.len() as u32).to_be_bytes());
        message.extend_from_slice(&compressed);
        message
    }

    #[test]
    fn parses_text_and_urls_from_message() {
        let archive = sample_archive();
        let full = message(&archive);
        let parsed = parse_server_pasteboard(&full).unwrap();
        assert_eq!(parsed.text.as_deref(), Some("Hello, 世界"));
        assert_eq!(
            parsed.urls,
            vec![
                "https://example.com/a?b=c".to_string(),
                "file:///tmp/a%20b.txt".to_string()
            ]
        );
        assert_eq!(
            parsed.types,
            vec!["public.text", "public.url", "public.file-url"]
        );

        // The payload without the 16-byte header must parse identically.
        let compressed = zlib(&archive);
        assert_eq!(parse_server_pasteboard(&compressed).unwrap(), parsed);
    }

    #[test]
    fn parses_utf16_text_and_raw_deflate() {
        let mut archive = Vec::new();
        push_u32(&mut archive, 1);
        let utf16: Vec<u8> = vec![0xfe, 0xff, 0x00, 0x48, 0x00, 0x69, 0x00, 0x00];
        push_item(
            &mut archive,
            "public.text",
            &[("public.utf16-plain-text", "")],
            &utf16,
        );

        let mut encoder = flate2::write::DeflateEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(&archive).unwrap();
        let raw = encoder.finish().unwrap();
        let parsed = parse_server_pasteboard(&raw).unwrap();
        assert_eq!(parsed.text.as_deref(), Some("Hi"));
        assert_eq!(parsed.types, vec!["public.text"]);
    }

    #[test]
    fn rejects_truncated_and_corrupt_pasteboard() {
        let archive = sample_archive();
        let full = message(&archive);

        let mut short = full.clone();
        short.truncate(PASTEBOARD_HEADER_LEN + 2);
        assert_eq!(
            parse_server_pasteboard(&short),
            Err(AppleInputError::Truncated)
        );

        assert_eq!(
            parse_server_pasteboard(b"not a zlib stream"),
            Err(AppleInputError::Compression)
        );

        let mut cut = archive.clone();
        cut.truncate(cut.len() - 2);
        assert_eq!(parse_archive(&cut), Err(AppleInputError::Truncated));
    }

    #[test]
    fn parses_archive_without_trailing_data() {
        let mut archive = Vec::new();
        push_u32(&mut archive, 1);
        push_str(&mut archive, "public.text");
        push_u32(&mut archive, 0);
        push_u32(&mut archive, 1);
        push_str(&mut archive, "public.utf8-plain-text");
        push_str(&mut archive, "fallback");
        push_u32(&mut archive, 0);

        let parsed = parse_server_pasteboard(&zlib(&archive)).unwrap();
        assert_eq!(parsed.text.as_deref(), Some("fallback"));
        assert!(parsed.urls.is_empty());
    }

    #[test]
    fn client_pasteboard_matches_vnckit_layout() {
        let text = "Hello, 世界";
        let archive = client_pasteboard_archive(text);
        let mut cursor = 0usize;
        assert_eq!(
            u32::from_be_bytes(archive[cursor..cursor + 4].try_into().unwrap()),
            1
        );
        cursor += 4;
        let key_len =
            u32::from_be_bytes(archive[cursor..cursor + 4].try_into().unwrap()) as usize;
        cursor += 4;
        assert_eq!(&archive[cursor..cursor + key_len], b"public.utf8-plain-text");
        cursor += key_len;
        assert_eq!(&archive[cursor..cursor + 4], &[0, 0, 0, 0]);
        cursor += 4;
        assert_eq!(
            u32::from_be_bytes(archive[cursor..cursor + 4].try_into().unwrap()),
            1
        );

        let message = client_pasteboard_message(text);
        assert_eq!(message.len(), 16 + u32::from_be_bytes(message[12..16].try_into().unwrap()) as usize);
        assert_eq!(message[0], MSG_SERVER_PASTEBOARD);
        assert_eq!(message[2], 0);
        assert_eq!(
            u32::from_be_bytes(message[8..12].try_into().unwrap()) as usize,
            archive.len()
        );
        let parsed = parse_server_pasteboard(&message).unwrap();
        assert_eq!(parsed.text.as_deref(), Some(text));
        assert_eq!(parsed.types, vec!["public.utf8-plain-text"]);
    }
}
