//! Hextile decoding (RFC 6143 section 7.7.4).

use rfb_proto::pixel_format::PixelFormat;

use crate::DecodeError;
use crate::pixel::{Cursor, fill_rect, store_pixel};

const RAW: u8 = 1;
const BACKGROUND_SPECIFIED: u8 = 2;
const FOREGROUND_SPECIFIED: u8 = 4;
const ANY_SUBRECTS: u8 = 8;
const SUBRECTS_COLOURED: u8 = 16;

const TILE_SIZE: usize = 16;

pub(crate) fn decode(
    data: &[u8],
    format: PixelFormat,
    width: usize,
    height: usize,
    scratch: &mut [u8],
) -> Result<usize, DecodeError> {
    let stride = width * 4;
    let mut cursor = Cursor::new(data);
    let mut background = 0u32;
    let mut foreground = 0u32;

    let mut tile_y = 0;
    while tile_y < height {
        let tile_height = (height - tile_y).min(TILE_SIZE);
        let mut tile_x = 0;
        while tile_x < width {
            let tile_width = (width - tile_x).min(TILE_SIZE);
            let subencoding = cursor.u8()?;

            if subencoding & RAW != 0 {
                for row in 0..tile_height {
                    for column in 0..tile_width {
                        let color = cursor.pixel(format)?;
                        store_pixel(
                            scratch,
                            stride,
                            tile_x + column,
                            tile_y + row,
                            color,
                            format,
                        )?;
                    }
                }
                tile_x += tile_width;
                continue;
            }

            if subencoding & BACKGROUND_SPECIFIED != 0 {
                background = cursor.pixel(format)?;
            }
            fill_rect(
                scratch,
                stride,
                tile_x,
                tile_y,
                tile_width,
                tile_height,
                background,
                format,
            )?;

            if subencoding & FOREGROUND_SPECIFIED != 0 {
                foreground = cursor.pixel(format)?;
            }

            if subencoding & ANY_SUBRECTS != 0 {
                let count = cursor.u8()?;
                for _ in 0..count {
                    let color = if subencoding & SUBRECTS_COLOURED != 0 {
                        cursor.pixel(format)?
                    } else {
                        foreground
                    };
                    let position = cursor.u8()?;
                    let size = cursor.u8()?;
                    let x = usize::from(position >> 4);
                    let y = usize::from(position & 0x0f);
                    let sub_width = usize::from(size >> 4) + 1;
                    let sub_height = usize::from(size & 0x0f) + 1;
                    if x + sub_width > tile_width || y + sub_height > tile_height {
                        return Err(DecodeError::InvalidData("hextile subrect out of bounds"));
                    }
                    fill_rect(
                        scratch,
                        stride,
                        tile_x + x,
                        tile_y + y,
                        sub_width,
                        sub_height,
                        color,
                        format,
                    )?;
                }
            }

            tile_x += tile_width;
        }
        tile_y += tile_height;
    }

    Ok(cursor.position())
}
