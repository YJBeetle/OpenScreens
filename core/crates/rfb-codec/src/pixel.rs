//! Wire pixel reading and conversion into BGRA8888.

use rfb_proto::pixel_format::PixelFormat;

use crate::DecodeError;

pub(crate) struct Cursor<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> Cursor<'a> {
    pub(crate) fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    pub(crate) fn position(&self) -> usize {
        self.position
    }

    pub(crate) fn u8(&mut self) -> Result<u8, DecodeError> {
        let byte = *self
            .data
            .get(self.position)
            .ok_or(DecodeError::Incomplete)?;
        self.position += 1;
        Ok(byte)
    }

    pub(crate) fn u16_be(&mut self) -> Result<u16, DecodeError> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    pub(crate) fn u32_be(&mut self) -> Result<u32, DecodeError> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    pub(crate) fn take(&mut self, length: usize) -> Result<&'a [u8], DecodeError> {
        let end = self
            .position
            .checked_add(length)
            .ok_or(DecodeError::InvalidData("length overflow"))?;
        let slice = self
            .data
            .get(self.position..end)
            .ok_or(DecodeError::Incomplete)?;
        self.position = end;
        Ok(slice)
    }

    pub(crate) fn pixel(&mut self, format: PixelFormat) -> Result<u32, DecodeError> {
        let bytes = self.take(format.bytes_per_pixel())?;
        decode_pixel_value(bytes, format)
    }

    /// ZRLE CPIXEL: a 32bpp format with depth <= 24 omits the most
    /// significant byte.
    pub(crate) fn cpixel(&mut self, format: PixelFormat) -> Result<u32, DecodeError> {
        if is_compact_pixel(format) {
            let bytes = self.take(3)?;
            Ok(if format.big_endian {
                (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2])
            } else {
                u32::from(bytes[0]) | (u32::from(bytes[1]) << 8) | (u32::from(bytes[2]) << 16)
            })
        } else {
            self.pixel(format)
        }
    }
}

pub(crate) fn is_compact_pixel(format: PixelFormat) -> bool {
    format.bits_per_pixel == 32 && format.depth <= 24
}

fn decode_pixel_value(bytes: &[u8], format: PixelFormat) -> Result<u32, DecodeError> {
    match (bytes.len(), format.big_endian) {
        (1, _) => Ok(u32::from(bytes[0])),
        (2, false) => Ok(u32::from(u16::from_le_bytes([bytes[0], bytes[1]]))),
        (2, true) => Ok(u32::from(u16::from_be_bytes([bytes[0], bytes[1]]))),
        (4, false) => Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])),
        (4, true) => Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]])),
        _ => Err(DecodeError::InvalidData("unsupported pixel size")),
    }
}

pub(crate) fn color_to_bgra(pixel: u32, format: PixelFormat) -> Result<[u8; 4], DecodeError> {
    if !format.true_colour {
        return Err(DecodeError::InvalidData("colour map unsupported"));
    }

    if format.bits_per_pixel == 32
        && format.red_max == 255
        && format.green_max == 255
        && format.blue_max == 255
        && format.red_shift == 16
        && format.green_shift == 8
        && format.blue_shift == 0
    {
        return Ok([pixel as u8, (pixel >> 8) as u8, (pixel >> 16) as u8, 255]);
    }

    Ok([
        scale_channel(pixel, format.blue_shift, format.blue_max),
        scale_channel(pixel, format.green_shift, format.green_max),
        scale_channel(pixel, format.red_shift, format.red_max),
        255,
    ])
}

fn scale_channel(pixel: u32, shift: u8, max: u16) -> u8 {
    if max == 0 {
        return 0;
    }
    let value = (pixel >> shift) & u32::from(max);
    ((value * 255 + u32::from(max) / 2) / u32::from(max)) as u8
}

pub(crate) fn store_pixel(
    dst: &mut [u8],
    stride: usize,
    x: usize,
    y: usize,
    color: u32,
    format: PixelFormat,
) -> Result<(), DecodeError> {
    let bgra = color_to_bgra(color, format)?;
    let offset = y
        .checked_mul(stride)
        .and_then(|value| value.checked_add(x * 4))
        .ok_or(DecodeError::InvalidData("pixel offset overflow"))?;
    let target = dst
        .get_mut(offset..offset + 4)
        .ok_or(DecodeError::InvalidData("pixel out of bounds"))?;
    target.copy_from_slice(&bgra);
    Ok(())
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn fill_rect(
    dst: &mut [u8],
    stride: usize,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    color: u32,
    format: PixelFormat,
) -> Result<(), DecodeError> {
    let bgra = color_to_bgra(color, format)?;
    for row in 0..height {
        let offset = (y + row)
            .checked_mul(stride)
            .and_then(|value| value.checked_add(x * 4))
            .ok_or(DecodeError::InvalidData("pixel offset overflow"))?;
        let line = dst
            .get_mut(offset..offset + width * 4)
            .ok_or(DecodeError::InvalidData("pixel out of bounds"))?;
        for pixel in line.chunks_exact_mut(4) {
            pixel.copy_from_slice(&bgra);
        }
    }
    Ok(())
}
