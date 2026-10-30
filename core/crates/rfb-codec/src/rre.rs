//! RRE decoding (RFC 6143 section 7.7.3).

use rfb_proto::pixel_format::PixelFormat;

use crate::DecodeError;
use crate::pixel::{Cursor, fill_rect};

pub(crate) fn decode(
    data: &[u8],
    format: PixelFormat,
    width: usize,
    height: usize,
    scratch: &mut [u8],
) -> Result<usize, DecodeError> {
    let stride = width * 4;
    let mut cursor = Cursor::new(data);
    let count = cursor.u32_be()?;
    let background = cursor.pixel(format)?;
    fill_rect(scratch, stride, 0, 0, width, height, background, format)?;

    for _ in 0..count {
        let color = cursor.pixel(format)?;
        let x = usize::from(cursor.u16_be()?);
        let y = usize::from(cursor.u16_be()?);
        let sub_width = usize::from(cursor.u16_be()?);
        let sub_height = usize::from(cursor.u16_be()?);
        if x + sub_width > width || y + sub_height > height {
            return Err(DecodeError::InvalidData("RRE subrect out of bounds"));
        }
        fill_rect(scratch, stride, x, y, sub_width, sub_height, color, format)?;
    }

    Ok(cursor.position())
}
