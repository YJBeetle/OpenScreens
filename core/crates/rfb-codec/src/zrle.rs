//! ZRLE decoding (RFC 6143 section 7.7.6).
//!
//! Input is the decompressed ZRLE payload for one rectangle. Pixels are
//! written into a tightly packed BGRA scratch buffer.

use rfb_proto::pixel_format::PixelFormat;

use crate::DecodeError;
use crate::pixel::{Cursor, fill_rect, store_pixel};

const TILE_SIZE: usize = 64;

const RAW: u8 = 0;
const SOLID: u8 = 1;
const PACKED_PALETTE: u8 = 2;
const PLAIN_RLE: u8 = 3;
const PALETTE_RLE: u8 = 4;

pub(crate) fn decode(
    data: &[u8],
    format: PixelFormat,
    width: usize,
    height: usize,
    scratch: &mut [u8],
) -> Result<(), DecodeError> {
    let stride = width * 4;
    let mut cursor = Cursor::new(data);
    let mut tile_y = 0;
    while tile_y < height {
        let tile_height = (height - tile_y).min(TILE_SIZE);
        let mut tile_x = 0;
        while tile_x < width {
            let tile_width = (width - tile_x).min(TILE_SIZE);
            let subencoding = cursor.u8()?;
            match subencoding {
                RAW => decode_raw_tile(
                    &mut cursor,
                    format,
                    scratch,
                    stride,
                    tile_x,
                    tile_y,
                    tile_width,
                    tile_height,
                )?,
                SOLID => {
                    let color = cursor.cpixel(format)?;
                    fill_rect(
                        scratch,
                        stride,
                        tile_x,
                        tile_y,
                        tile_width,
                        tile_height,
                        color,
                        format,
                    )?;
                }
                PACKED_PALETTE => decode_packed_palette(
                    &mut cursor,
                    format,
                    scratch,
                    stride,
                    tile_x,
                    tile_y,
                    tile_width,
                    tile_height,
                )?,
                PLAIN_RLE => decode_plain_rle(
                    &mut cursor,
                    format,
                    scratch,
                    stride,
                    tile_x,
                    tile_y,
                    tile_width,
                    tile_height,
                )?,
                PALETTE_RLE => decode_palette_rle(
                    &mut cursor,
                    format,
                    scratch,
                    stride,
                    tile_x,
                    tile_y,
                    tile_width,
                    tile_height,
                )?,
                _ => return Err(DecodeError::InvalidData("unknown ZRLE subencoding")),
            }
            tile_x += tile_width;
        }
        tile_y += tile_height;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn decode_raw_tile(
    cursor: &mut Cursor<'_>,
    format: PixelFormat,
    scratch: &mut [u8],
    stride: usize,
    tile_x: usize,
    tile_y: usize,
    width: usize,
    height: usize,
) -> Result<(), DecodeError> {
    for row in 0..height {
        for column in 0..width {
            let color = cursor.cpixel(format)?;
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
    Ok(())
}

fn read_palette(cursor: &mut Cursor<'_>, format: PixelFormat) -> Result<Vec<u32>, DecodeError> {
    let size = usize::from(cursor.u8()?);
    if size == 0 {
        return Err(DecodeError::InvalidData("empty ZRLE palette"));
    }
    let mut palette = Vec::with_capacity(size);
    for _ in 0..size {
        palette.push(cursor.cpixel(format)?);
    }
    Ok(palette)
}

#[allow(clippy::too_many_arguments)]
fn decode_packed_palette(
    cursor: &mut Cursor<'_>,
    format: PixelFormat,
    scratch: &mut [u8],
    stride: usize,
    tile_x: usize,
    tile_y: usize,
    width: usize,
    height: usize,
) -> Result<(), DecodeError> {
    let palette = read_palette(cursor, format)?;
    let bits = match palette.len() {
        1..=2 => 1,
        3..=4 => 2,
        5..=16 => 4,
        _ => 8,
    };
    let packed_row_bytes = (width * bits).div_ceil(8);
    let mask = if bits == 8 { 0xff } else { (1u8 << bits) - 1 };

    for row in 0..height {
        let packed = cursor.take(packed_row_bytes)?;
        for column in 0..width {
            let bit_index = column * bits;
            let byte = packed[bit_index / 8];
            let shift = 8 - bits - (bit_index % 8);
            let index = usize::from((byte >> shift) & mask);
            let color = *palette
                .get(index)
                .ok_or(DecodeError::InvalidData("ZRLE palette index"))?;
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
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn decode_plain_rle(
    cursor: &mut Cursor<'_>,
    format: PixelFormat,
    scratch: &mut [u8],
    stride: usize,
    tile_x: usize,
    tile_y: usize,
    width: usize,
    height: usize,
) -> Result<(), DecodeError> {
    let total = width * height;
    let mut written = 0;
    while written < total {
        let color = cursor.cpixel(format)?;
        let mut run = 1usize;
        loop {
            let byte = cursor.u8()?;
            run += usize::from(byte);
            if byte != 255 {
                break;
            }
        }
        if written + run > total {
            return Err(DecodeError::InvalidData("ZRLE run exceeds tile"));
        }
        write_run(
            scratch, stride, tile_x, tile_y, width, written, run, color, format,
        )?;
        written += run;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn decode_palette_rle(
    cursor: &mut Cursor<'_>,
    format: PixelFormat,
    scratch: &mut [u8],
    stride: usize,
    tile_x: usize,
    tile_y: usize,
    width: usize,
    height: usize,
) -> Result<(), DecodeError> {
    let palette = read_palette(cursor, format)?;
    let total = width * height;
    let mut written = 0;
    while written < total {
        let byte = cursor.u8()?;
        let index = usize::from(byte & 0x7f);
        let color = *palette
            .get(index)
            .ok_or(DecodeError::InvalidData("ZRLE palette index"))?;
        let run = if byte & 0x80 != 0 {
            let mut run = 1usize;
            loop {
                let length = cursor.u8()?;
                run += usize::from(length);
                if length != 255 {
                    break;
                }
            }
            run
        } else {
            1
        };
        if written + run > total {
            return Err(DecodeError::InvalidData("ZRLE run exceeds tile"));
        }
        write_run(
            scratch, stride, tile_x, tile_y, width, written, run, color, format,
        )?;
        written += run;
    }
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn write_run(
    scratch: &mut [u8],
    stride: usize,
    tile_x: usize,
    tile_y: usize,
    tile_width: usize,
    start: usize,
    run: usize,
    color: u32,
    format: PixelFormat,
) -> Result<(), DecodeError> {
    for offset in start..start + run {
        let x = offset % tile_width;
        let y = offset / tile_width;
        store_pixel(scratch, stride, tile_x + x, tile_y + y, color, format)?;
    }
    Ok(())
}
