//! Client-to-server RFB messages (RFC 6143 section 7.5).

use crate::pixel_format::{PIXEL_FORMAT_LEN, PixelFormat};

pub const SET_PIXEL_FORMAT: u8 = 0;
pub const SET_ENCODINGS: u8 = 2;
pub const FRAMEBUFFER_UPDATE_REQUEST: u8 = 3;
pub const KEY_EVENT: u8 = 4;
pub const POINTER_EVENT: u8 = 5;
pub const CLIENT_CUT_TEXT: u8 = 6;

pub const SET_PIXEL_FORMAT_LEN: usize = 4 + PIXEL_FORMAT_LEN;
pub const FRAMEBUFFER_UPDATE_REQUEST_LEN: usize = 10;
pub const KEY_EVENT_LEN: usize = 8;
pub const POINTER_EVENT_LEN: usize = 6;

pub fn set_pixel_format(format: &PixelFormat) -> [u8; SET_PIXEL_FORMAT_LEN] {
    let mut out = [0u8; SET_PIXEL_FORMAT_LEN];
    out[0] = SET_PIXEL_FORMAT;
    out[4..].copy_from_slice(&format.encode());
    out
}

pub fn set_encodings(encodings: &[i32]) -> Vec<u8> {
    let count = u16::try_from(encodings.len()).expect("encoding list exceeds u16::MAX entries");
    let mut out = Vec::with_capacity(4 + encodings.len() * 4);
    out.push(SET_ENCODINGS);
    out.push(0);
    out.extend_from_slice(&count.to_be_bytes());
    for encoding in encodings {
        out.extend_from_slice(&encoding.to_be_bytes());
    }
    out
}

pub fn framebuffer_update_request(
    incremental: bool,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
) -> [u8; FRAMEBUFFER_UPDATE_REQUEST_LEN] {
    let mut out = [0u8; FRAMEBUFFER_UPDATE_REQUEST_LEN];
    out[0] = FRAMEBUFFER_UPDATE_REQUEST;
    out[1] = u8::from(incremental);
    out[2..4].copy_from_slice(&x.to_be_bytes());
    out[4..6].copy_from_slice(&y.to_be_bytes());
    out[6..8].copy_from_slice(&width.to_be_bytes());
    out[8..10].copy_from_slice(&height.to_be_bytes());
    out
}

pub fn key_event(down: bool, key: u32) -> [u8; KEY_EVENT_LEN] {
    let mut out = [0u8; KEY_EVENT_LEN];
    out[0] = KEY_EVENT;
    out[1] = u8::from(down);
    out[4..].copy_from_slice(&key.to_be_bytes());
    out
}

pub fn pointer_event(button_mask: u8, x: u16, y: u16) -> [u8; POINTER_EVENT_LEN] {
    let mut out = [0u8; POINTER_EVENT_LEN];
    out[0] = POINTER_EVENT;
    out[1] = button_mask;
    out[2..4].copy_from_slice(&x.to_be_bytes());
    out[4..6].copy_from_slice(&y.to_be_bytes());
    out
}

pub fn client_cut_text(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(8 + text.len());
    out.push(CLIENT_CUT_TEXT);
    out.extend_from_slice(&[0, 0, 0]);
    out.extend_from_slice(&(text.len() as u32).to_be_bytes());
    out.extend_from_slice(text);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_set_pixel_format() {
        let message = set_pixel_format(&PixelFormat::bgra8888());
        assert_eq!(message.len(), 20);
        assert_eq!(&message[0..4], &[0, 0, 0, 0]);
        assert_eq!(&message[4..], &PixelFormat::bgra8888().encode());
    }

    #[test]
    fn encodes_set_encodings() {
        let message = set_encodings(&[0, 16, -239]);
        assert_eq!(
            message,
            vec![2, 0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 16, 0xff, 0xff, 0xff, 0x11]
        );
    }

    #[test]
    fn encodes_framebuffer_update_request() {
        assert_eq!(
            framebuffer_update_request(true, 10, 20, 640, 480),
            [3, 1, 0, 10, 0, 20, 2, 128, 1, 224]
        );
        assert_eq!(
            framebuffer_update_request(false, 0, 0, 65535, 65535),
            [3, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff]
        );
    }

    #[test]
    fn encodes_key_event() {
        assert_eq!(key_event(true, 0xff0d), [4, 1, 0, 0, 0, 0, 0xff, 0x0d]);
        assert_eq!(key_event(false, 0x61), [4, 0, 0, 0, 0, 0, 0, 0x61]);
    }

    #[test]
    fn encodes_pointer_event() {
        assert_eq!(pointer_event(0x01, 1024, 768), [5, 1, 4, 0, 3, 0]);
    }

    #[test]
    fn encodes_client_cut_text() {
        assert_eq!(
            client_cut_text(b"hi"),
            vec![6, 0, 0, 0, 0, 0, 0, 2, b'h', b'i']
        );
        assert_eq!(client_cut_text(b""), vec![6, 0, 0, 0, 0, 0, 0, 0]);
    }
}
