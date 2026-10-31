//! Cursor pseudo-encoding (RFC 6143 section 7.7.3).

use rfb_proto::pixel_format::PixelFormat;

use crate::pixel::{Cursor, color_to_bgra};
use crate::{DecodeError, Rect};

/// A client-side cursor bitmap. `pixels` is tightly packed BGRA8888 with the
/// cursor mask folded into the alpha channel.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorShape {
    pub hotspot_x: u16,
    pub hotspot_y: u16,
    pub width: u16,
    pub height: u16,
    pub pixels: Vec<u8>,
}

impl CursorShape {
    pub fn is_empty(&self) -> bool {
        self.width == 0 || self.height == 0
    }
}

pub fn decode_cursor(
    rect: Rect,
    data: &[u8],
    format: PixelFormat,
) -> Result<(CursorShape, usize), DecodeError> {
    let width = usize::from(rect.width);
    let height = usize::from(rect.height);
    if width == 0 || height == 0 {
        return Ok((
            CursorShape {
                hotspot_x: rect.x,
                hotspot_y: rect.y,
                width: rect.width,
                height: rect.height,
                pixels: Vec::new(),
            },
            0,
        ));
    }

    let pixel_bytes = width
        .checked_mul(height)
        .and_then(|count| count.checked_mul(format.bytes_per_pixel()))
        .ok_or(DecodeError::InvalidData("cursor size overflow"))?;
    let mask_stride = width.div_ceil(8);
    let mask_bytes = mask_stride
        .checked_mul(height)
        .ok_or(DecodeError::InvalidData("cursor mask size overflow"))?;
    let consumed = pixel_bytes + mask_bytes;
    if data.len() < consumed {
        return Err(DecodeError::Incomplete);
    }

    let mut pixels = vec![0u8; width * height * 4];
    let mut reader = Cursor::new(&data[..pixel_bytes]);
    for row in 0..height {
        for column in 0..width {
            let color = reader.pixel(format)?;
            let mask = data[pixel_bytes + row * mask_stride + column / 8];
            if mask & (0x80 >> (column % 8)) != 0 {
                let offset = (row * width + column) * 4;
                pixels[offset..offset + 4].copy_from_slice(&color_to_bgra(color, format)?);
            }
        }
    }

    Ok((
        CursorShape {
            hotspot_x: rect.x,
            hotspot_y: rect.y,
            width: rect.width,
            height: rect.height,
            pixels,
        },
        consumed,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bgra_format() -> PixelFormat {
        PixelFormat::bgra8888()
    }

    fn rect(x: u16, y: u16, width: u16, height: u16) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    #[test]
    fn decodes_pixels_and_mask() {
        // 3x1 cursor: red, green, blue; mask shows the first and third pixels.
        let mut data = Vec::new();
        data.extend_from_slice(&[0, 0, 255, 255]); // BGRA red
        data.extend_from_slice(&[0, 255, 0, 255]); // BGRA green
        data.extend_from_slice(&[255, 0, 0, 255]); // BGRA blue
        data.push(0b1010_0000);

        let (shape, consumed) =
            decode_cursor(rect(1, 2, 3, 1), &data, bgra_format()).expect("cursor decodes");

        assert_eq!(consumed, data.len());
        assert_eq!((shape.hotspot_x, shape.hotspot_y), (1, 2));
        assert_eq!((shape.width, shape.height), (3, 1));
        assert_eq!(&shape.pixels[0..4], &[0, 0, 255, 255]);
        assert_eq!(&shape.pixels[4..8], &[0, 0, 0, 0]);
        assert_eq!(&shape.pixels[8..12], &[255, 0, 0, 255]);
    }

    #[test]
    fn respects_row_padding() {
        // Two rows of 9 pixels: each mask row is 2 bytes.
        let mut data = vec![255u8; 9 * 2 * 4];
        data[0..4].fill(255);
        let mask = [0x80, 0x00, 0x00, 0x80];
        data.extend_from_slice(&mask);

        let (shape, consumed) =
            decode_cursor(rect(0, 0, 9, 2), &data, bgra_format()).expect("cursor decodes");

        assert_eq!(consumed, data.len());
        assert_eq!(shape.pixels[3], 255);
        assert_eq!(shape.pixels[4 * 8 + 3], 0);
        assert_eq!(shape.pixels[9 * 4 + 3], 0);
        assert_eq!(shape.pixels[(9 + 8) * 4 + 3], 255);
    }

    #[test]
    fn requests_more_data_when_truncated() {
        let data = [0u8; 8];
        assert_eq!(
            decode_cursor(rect(0, 0, 3, 1), &data, bgra_format()),
            Err(DecodeError::Incomplete)
        );
    }

    #[test]
    fn accepts_empty_cursor() {
        let (shape, consumed) =
            decode_cursor(rect(0, 0, 0, 0), &[], bgra_format()).expect("empty cursor decodes");
        assert!(shape.is_empty());
        assert_eq!(consumed, 0);
    }
}
