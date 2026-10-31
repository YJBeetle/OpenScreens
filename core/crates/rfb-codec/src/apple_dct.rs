//! Apple Adaptive DCT (encoding 1011 / 0x3F3) rectangle decoder.
//!
//! The wire format and decoder behaviour were reverse-engineered from
//! VNCKit's `VncCodecAppleAdaptiveDCT` (see
//! `var/research/screens-vnckit-deep.md`). A rectangle payload starts with a
//! big-endian `u32` message length followed by one of:
//!
//! * type 2: a 129-byte quantisation table update
//!   (`[2][64 B Y][64 B CbCr]`),
//! * type 0: a tile update with a command bitstream and a coefficient
//!   bitstream,
//! * type 1: a refinement update. This decoder does not implement type 1 and
//!   reports it as unsupported.
//!
//! Type 0 encodes 8x8 tiles as YCbCr 4:2:0 DCT coefficients. Quantisation
//! tables and the framebuffer live in [`AdaptiveDctDecoder`], which callers
//! should keep for the whole session. The convenience
//! [`decode_apple_dct`] / [`decode_apple_dct_message`] functions decode a
//! single message into a fresh full-frame BGRA8888 buffer.
//!
//! Output is always tightly packed BGRA8888 (the same layout as
//! [`crate::Framebuffer`]); `pixel_format` must be a 32 bpp true-colour
//! format because Apple forces that format before enabling this encoding.

use rfb_proto::pixel_format::PixelFormat;

use crate::{DecodeError, Rect};

const TILE: usize = 8;
const TILE_PIXELS: usize = TILE * TILE;
const TILE_BYTES: usize = TILE_PIXELS * 4;
const MAX_MESSAGE_LENGTH: usize = 100_000_000;
const MAX_CACHE_INDEX: u16 = 64_999;

/// Default luma quantisation table (`_vnc_adaptive_quality_default_quantisation_y`).
pub const DEFAULT_QUANT_Y: [u8; 64] = [
    0x10, 0x0b, 0x0b, 0x0e, 0x18, 0x16, 0x18, 0x21, 0x0b, 0x0c, 0x0b, 0x0b, 0x1a, 0x12, 0x13, 0x17,
    0x0d, 0x0d, 0x0e, 0x18, 0x14, 0x15, 0x16, 0x1c, 0x0d, 0x11, 0x0e, 0x15, 0x17, 0x19, 0x22, 0x22,
    0x11, 0x16, 0x12, 0x19, 0x1f, 0x20, 0x22, 0x2c, 0x18, 0x14, 0x11, 0x1b, 0x23, 0x28, 0x2c, 0x36,
    0x1e, 0x23, 0x1c, 0x1e, 0x22, 0x2c, 0x36, 0x40, 0x23, 0x1e, 0x21, 0x26, 0x2d, 0x37, 0x41, 0x4b,
];

/// Default chroma quantisation table (`_vnc_adaptive_quality_default_quantisation_cbcr`).
pub const DEFAULT_QUANT_CBCR: [u8; 64] = [
    0x13, 0x13, 0x18, 0x2f, 0x4c, 0x63, 0x63, 0x63, 0x13, 0x15, 0x1a, 0x42, 0x63, 0x63, 0x63, 0x63,
    0x18, 0x1a, 0x38, 0x63, 0x63, 0x63, 0x63, 0x63, 0x2f, 0x42, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
    0x4c, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
    0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63, 0x63,
];

/// Zigzag scan index to natural (row-major) index.
const ZIGZAG: [usize; 64] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
    13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59,
    52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

/// A decoded tile: Y, Cb and Cr planes in natural order.
type Planes = [i16; 3 * 64];

/// Persistent Adaptive DCT state: quantisation tables, tile predictor and
/// the BGRA framebuffer.
pub struct AdaptiveDctDecoder {
    width: u16,
    height: u16,
    pixel_format: PixelFormat,
    framebuffer: Vec<u8>,
    quant_y: [u16; 64],
    quant_cbcr: [u16; 64],
    cache_last_read: u16,
}

impl AdaptiveDctDecoder {
    pub fn new(width: u16, height: u16, pixel_format: PixelFormat) -> Self {
        let mut quant_y = [0u16; 64];
        let mut quant_cbcr = [0u16; 64];
        for (dst, src) in quant_y.iter_mut().zip(DEFAULT_QUANT_Y) {
            *dst = u16::from(src);
        }
        for (dst, src) in quant_cbcr.iter_mut().zip(DEFAULT_QUANT_CBCR) {
            *dst = u16::from(src);
        }
        Self {
            width,
            height,
            pixel_format,
            framebuffer: vec![0; usize::from(width) * usize::from(height) * 4],
            quant_y,
            quant_cbcr,
            cache_last_read: 0,
        }
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    /// Tightly packed BGRA8888 pixels.
    pub fn framebuffer(&self) -> &[u8] {
        &self.framebuffer
    }

    /// Decodes the payload of one rectangle, including its leading big-endian
    /// `u32` message length. Returns the number of bytes consumed.
    pub fn decode_rect(&mut self, data: &[u8], rect: Rect) -> Result<usize, DecodeError> {
        if data.len() < 4 {
            return Err(DecodeError::Incomplete);
        }
        let length = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
        if length > MAX_MESSAGE_LENGTH {
            return Err(DecodeError::InvalidData(
                "adaptive DCT message exceeds maximum size",
            ));
        }
        let consumed = 4usize
            .checked_add(length)
            .ok_or(DecodeError::InvalidData("adaptive DCT length overflow"))?;
        let message = data.get(4..consumed).ok_or(DecodeError::Incomplete)?;
        self.decode_message(message, rect)?;
        Ok(consumed)
    }

    /// Decodes one Adaptive DCT message (without the `u32` length prefix).
    pub fn decode_message(&mut self, message: &[u8], rect: Rect) -> Result<(), DecodeError> {
        self.check_format()?;
        let kind = *message
            .first()
            .ok_or(DecodeError::InvalidData("empty adaptive DCT message"))?;
        match kind {
            0 => {
                self.check_rect(rect)?;
                self.decode_type0(message, rect)
            }
            1 => Err(DecodeError::InvalidData(
                "adaptive DCT type 1 (refine) is not implemented",
            )),
            2 => self.decode_type2(message),
            _ => Err(DecodeError::InvalidData(
                "invalid adaptive DCT message type",
            )),
        }
    }

    fn check_format(&self) -> Result<(), DecodeError> {
        if !self.pixel_format.true_colour || self.pixel_format.bits_per_pixel != 32 {
            return Err(DecodeError::InvalidData(
                "adaptive DCT requires a 32 bpp true-colour pixel format",
            ));
        }
        Ok(())
    }

    fn check_rect(&self, rect: Rect) -> Result<(), DecodeError> {
        let x = u32::from(rect.x);
        let y = u32::from(rect.y);
        let width = u32::from(rect.width);
        let height = u32::from(rect.height);
        if width == 0 || height == 0 {
            return Err(DecodeError::InvalidData("empty adaptive DCT rectangle"));
        }
        if x + width > u32::from(self.width) || y + height > u32::from(self.height) {
            return Err(DecodeError::InvalidData(
                "adaptive DCT rectangle out of bounds",
            ));
        }
        Ok(())
    }

    fn decode_type2(&mut self, message: &[u8]) -> Result<(), DecodeError> {
        if message.len() != 129 {
            return Err(DecodeError::InvalidData(
                "adaptive DCT type 2 message must be 129 bytes",
            ));
        }
        for (dst, src) in self.quant_y.iter_mut().zip(&message[1..65]) {
            *dst = u16::from(*src);
        }
        for (dst, src) in self.quant_cbcr.iter_mut().zip(&message[65..129]) {
            *dst = u16::from(*src);
        }
        Ok(())
    }

    fn decode_type0(&mut self, message: &[u8], rect: Rect) -> Result<(), DecodeError> {
        if message.len() < 7 {
            return Err(DecodeError::InvalidData(
                "adaptive DCT type 0 message too short",
            ));
        }
        let threshold1 = message[1];
        let threshold2 = message[2];
        let data_offset = (usize::from(message[3]) << 16)
            | (usize::from(message[4]) << 8)
            | usize::from(message[5]);
        if data_offset <= 6 || data_offset > message.len() {
            return Err(DecodeError::InvalidData(
                "invalid adaptive DCT type 0 data offset",
            ));
        }

        let mut commands = BitReader::new(&message[6..data_offset]);
        // The command bitstream starts with one unused bit.
        commands.read(1)?;
        let mut coefficients = BitReader::new(&message[data_offset..]);

        let rect_tiles_x = u32::from(rect.width).div_ceil(8);
        let rect_tiles_y = u32::from(rect.height).div_ceil(8);
        let total = rect_tiles_x * rect_tiles_y;
        let fb_tiles_x = u32::from(self.width).div_ceil(8);
        let fb_tiles_y = u32::from(self.height).div_ceil(8);

        let mut prev: Planes = [0; 3 * 64];
        let mut last_single = [0xFFu8; 4];
        let mut last_a = [0u8; 4];
        let mut last_b = [0u8; 4];
        let mut tiles_done: u32 = 0;

        while tiles_done < total {
            let command = commands.read(3)? as u8;
            let count = read_num_boxes(&mut commands)?;
            // VNCKit clamps an over-long final run to the remaining tiles.
            let count = count.min((total - tiles_done) as usize);

            for _ in 0..count {
                let column = (tiles_done % rect_tiles_x) as usize;
                let row = (tiles_done / rect_tiles_x) as usize;
                let tile_x = u32::from(rect.x) / 8 + column as u32;
                let tile_y = u32::from(rect.y) / 8 + row as u32;
                if tile_x >= fb_tiles_x || tile_y >= fb_tiles_y {
                    return Err(DecodeError::InvalidData(
                        "adaptive DCT tile outside framebuffer",
                    ));
                }

                match command {
                    0 => {
                        let tile = [0xFFu8; TILE_BYTES];
                        self.blit_tile(rect, column, row, &tile);
                    }
                    1 => {
                        if tiles_done == 0 {
                            return Err(DecodeError::InvalidData(
                                "adaptive DCT repeat tile without a previous tile",
                            ));
                        }
                        let source = tiles_done - 1;
                        let source_column = (source % rect_tiles_x) as usize;
                        let source_row = (source / rect_tiles_x) as usize;
                        let mut tile = [0u8; TILE_BYTES];
                        self.read_tile(
                            usize::from(rect.x) / TILE + source_column,
                            usize::from(rect.y) / TILE + source_row,
                            &mut tile,
                        );
                        self.blit_tile(rect, column, row, &tile);
                    }
                    2 => {
                        let source_y = usize::from(rect.y) / TILE + row;
                        if source_y == 0 {
                            return Err(DecodeError::InvalidData(
                                "adaptive DCT copy tile above the framebuffer",
                            ));
                        }
                        let mut tile = [0u8; TILE_BYTES];
                        self.read_tile(
                            usize::from(rect.x) / TILE + column,
                            source_y - 1,
                            &mut tile,
                        );
                        self.blit_tile(rect, column, row, &tile);
                    }
                    3 => {
                        let tile = read_two_colour_tile(
                            &mut coefficients,
                            [0xFF, 0xFF, 0xFF, 0xFF],
                            [0, 0, 0, 0xFF],
                        )?;
                        self.blit_tile(rect, column, row, &tile);
                    }
                    4 => {
                        let subtype = coefficients.read(2)? as u8;
                        let tile = match subtype {
                            0 => {
                                last_single = read_ycc20_bgra(&mut coefficients)?;
                                solid_tile(last_single)
                            }
                            1 => solid_tile(last_single),
                            2 => {
                                last_a = read_ycc20_bgra(&mut coefficients)?;
                                last_b = read_ycc20_bgra(&mut coefficients)?;
                                read_two_colour_tile(&mut coefficients, last_a, last_b)?
                            }
                            3 => read_two_colour_tile(&mut coefficients, last_a, last_b)?,
                            _ => unreachable!(),
                        };
                        self.blit_tile(rect, column, row, &tile);
                    }
                    5 => {
                        let duplicate = coefficients.read(1)? == 1;
                        let planes = if duplicate {
                            prev
                        } else {
                            let planes = decode_new_coefficients(
                                &mut coefficients,
                                &prev,
                                threshold1,
                                threshold2,
                            )?;
                            prev = planes;
                            planes
                        };
                        let tile = self.idct_tile(&planes);
                        self.blit_tile(rect, column, row, &tile);
                    }
                    6 => {
                        let index = coefficients.read(16)? as u16;
                        self.copy_from_cache(index, rect, column, row)?;
                    }
                    7 => {
                        let index = next_cache_index(self.cache_last_read);
                        self.copy_from_cache(index, rect, column, row)?;
                    }
                    _ => unreachable!(),
                }
                tiles_done += 1;
            }
        }
        Ok(())
    }

    fn copy_from_cache(
        &mut self,
        _index: u16,
        _rect: Rect,
        _column: usize,
        _row: usize,
    ) -> Result<(), DecodeError> {
        // The coefficient cache is only filled by type 1 (refine) messages,
        // which this decoder does not implement.
        Err(DecodeError::InvalidData(
            "adaptive DCT tile cache reference requires type 1 support",
        ))
    }

    fn idct_tile(&self, planes: &Planes) -> [u8; TILE_BYTES] {
        let mut y = [0i16; 64];
        let mut cb = [0i16; 64];
        let mut cr = [0i16; 64];
        for i in 0..64 {
            y[i] = planes[i].wrapping_mul(self.quant_y[i] as i16);
            cb[i] = planes[64 + i].wrapping_mul(self.quant_cbcr[i] as i16);
            cr[i] = planes[128 + i].wrapping_mul(self.quant_cbcr[i] as i16);
        }
        let y = idct_block(&y);
        let cb = idct_block(&cb);
        let cr = idct_block(&cr);
        let mut tile = [0u8; TILE_BYTES];
        for row in 0..TILE {
            for column in 0..TILE {
                let i = row * TILE + column;
                let pixel = ycbcr_to_bgra(y[i], cb[i], cr[i]);
                tile[i * 4..i * 4 + 4].copy_from_slice(&pixel);
            }
        }
        tile
    }

    fn read_tile(&self, tile_x: usize, tile_y: usize, tile: &mut [u8; TILE_BYTES]) {
        let origin_x = tile_x * TILE;
        let origin_y = tile_y * TILE;
        let stride = usize::from(self.width) * 4;
        let fb_right = usize::from(self.width);
        let fb_bottom = usize::from(self.height);
        for y in 0..TILE {
            let source_y = origin_y + y;
            if source_y >= fb_bottom {
                continue;
            }
            for x in 0..TILE {
                let source_x = origin_x + x;
                if source_x >= fb_right {
                    continue;
                }
                let source = source_y * stride + source_x * 4;
                let target = (y * TILE + x) * 4;
                tile[target..target + 4].copy_from_slice(&self.framebuffer[source..source + 4]);
            }
        }
    }

    fn blit_tile(&mut self, rect: Rect, column: usize, row: usize, tile: &[u8; TILE_BYTES]) {
        let (origin_x, origin_y) = tile_origin(rect, column, row);
        let stride = usize::from(self.width) * 4;
        let rect_x = usize::from(rect.x);
        let rect_y = usize::from(rect.y);
        let rect_right = rect_x + usize::from(rect.width);
        let rect_bottom = rect_y + usize::from(rect.height);
        let fb_right = usize::from(self.width);
        let fb_bottom = usize::from(self.height);
        for y in 0..TILE {
            let target_y = origin_y + y;
            if target_y < rect_y || target_y >= rect_bottom || target_y >= fb_bottom {
                continue;
            }
            let start_x = origin_x.max(rect_x);
            let end_x = (origin_x + TILE).min(rect_right).min(fb_right);
            if start_x >= end_x {
                continue;
            }
            let source_start = (y * TILE + (start_x - origin_x)) * 4;
            let source_end = source_start + (end_x - start_x) * 4;
            let target_start = target_y * stride + start_x * 4;
            let target_end = target_start + (end_x - start_x) * 4;
            self.framebuffer[target_start..target_end]
                .copy_from_slice(&tile[source_start..source_end]);
        }
    }
}

/// Decodes a single length-prefixed Adaptive DCT message covering the whole
/// `width` x `height` framebuffer. `data` starts with the big-endian message
/// length, as it appears after the 12-byte rectangle header.
///
/// Quantisation tables start at the VNCKit defaults; use
/// [`AdaptiveDctDecoder`] when a session sends type 2 updates first.
pub fn decode_apple_dct(
    data: &[u8],
    width: u16,
    height: u16,
    pixel_format: &PixelFormat,
) -> Result<Vec<u8>, DecodeError> {
    let mut decoder = AdaptiveDctDecoder::new(width, height, *pixel_format);
    decoder.decode_rect(
        data,
        Rect {
            x: 0,
            y: 0,
            width,
            height,
        },
    )?;
    Ok(decoder.framebuffer().to_vec())
}

/// Decodes a single Adaptive DCT message without the `u32` length prefix,
/// covering the whole `width` x `height` framebuffer.
pub fn decode_apple_dct_message(
    message: &[u8],
    width: u16,
    height: u16,
    pixel_format: &PixelFormat,
) -> Result<Vec<u8>, DecodeError> {
    let mut decoder = AdaptiveDctDecoder::new(width, height, *pixel_format);
    decoder.decode_message(
        message,
        Rect {
            x: 0,
            y: 0,
            width,
            height,
        },
    )?;
    Ok(decoder.framebuffer().to_vec())
}

fn tile_origin(rect: Rect, column: usize, row: usize) -> (usize, usize) {
    (
        (usize::from(rect.x) / TILE + column) * TILE,
        (usize::from(rect.y) / TILE + row) * TILE,
    )
}

fn next_cache_index(last: u16) -> u16 {
    let next = last.wrapping_add(1);
    if next > MAX_CACHE_INDEX { 1 } else { next }
}

/// MSB-first bit reader matching VNCKit's `reader` structure.
struct BitReader<'a> {
    data: &'a [u8],
    position: usize,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, position: 0 }
    }

    fn read(&mut self, bits: u8) -> Result<u32, DecodeError> {
        debug_assert!(bits <= 32);
        let end = self
            .position
            .checked_add(usize::from(bits))
            .ok_or(DecodeError::InvalidData(
                "adaptive DCT bit position overflow",
            ))?;
        if end > self.data.len() * 8 {
            return Err(DecodeError::InvalidData("adaptive DCT bitstream exhausted"));
        }
        let mut value = 0u32;
        for _ in 0..bits {
            let byte = self.data[self.position >> 3];
            let bit = (byte >> (7 - (self.position & 7))) & 1;
            value = (value << 1) | u32::from(bit);
            self.position += 1;
        }
        Ok(value)
    }
}

/// Variable-length run length (`_decode_num_boxes_for_command`).
fn read_num_boxes(reader: &mut BitReader<'_>) -> Result<usize, DecodeError> {
    if reader.read(1)? == 0 {
        return Ok(1);
    }
    let value = reader.read(4)?;
    if value != 0xF {
        return Ok(value as usize + 2);
    }
    let a = reader.read(8)?;
    let mut count = 17 + (a & 0x7F) as usize;
    if a < 0x80 {
        return Ok(count);
    }
    let b = reader.read(8)?;
    count += ((b & 0x7F) as usize) << 7;
    if b < 0x80 {
        return Ok(count);
    }
    let c = reader.read(8)?;
    count += (c as usize) << 14;
    Ok(count)
}

/// Rice-coded DC difference (`_read_dc_rice`).
fn read_dc_rice(reader: &mut BitReader<'_>) -> Result<i32, DecodeError> {
    let mut quotient = 0u32;
    while reader.read(1)? == 1 {
        quotient += 1;
        if quotient >= 0x27 {
            return Err(DecodeError::InvalidData("adaptive DCT Rice quotient"));
        }
    }
    let magnitude = match quotient {
        0 => {
            if reader.read(1)? == 0 {
                return Ok(0);
            }
            1
        }
        1 => 2 | reader.read(1)?,
        2 => 4 | reader.read(2)?,
        _ => 8 * (quotient - 2) + reader.read(3)?,
    };
    let negative = reader.read(1)? == 1;
    Ok(if negative {
        -(magnitude as i32)
    } else {
        magnitude as i32
    })
}

/// Chroma DC predictor: VNCKit rounds the previous DC value down to an even
/// 16-bit value (in unsigned space) before subtracting twice the Rice delta.
fn chroma_dc(previous: i16, delta: i32) -> i16 {
    let previous = previous as u16;
    let even = previous.wrapping_add(previous >> 15) & !1;
    even.wrapping_sub((delta * 2) as u16) as i16
}

/// Decodes a new tile's coefficients (`_decode_new_idct_coefficients`).
fn decode_new_coefficients(
    reader: &mut BitReader<'_>,
    prev: &Planes,
    threshold1: u8,
    threshold2: u8,
) -> Result<Planes, DecodeError> {
    let mut planes: Planes = [0; 3 * 64];
    let copy_chroma = reader.read(1)? == 1;
    let maximum = if reader.read(1)? == 1 {
        threshold2
    } else {
        threshold1
    };

    if copy_chroma {
        planes[64] = prev[64];
        planes[128] = prev[128];
    } else {
        planes[64] = chroma_dc(prev[64], read_dc_rice(reader)?);
        planes[128] = chroma_dc(prev[128], read_dc_rice(reader)?);
    }
    planes[0] = prev[0].wrapping_sub(read_dc_rice(reader)? as i16);

    let mut k = 1usize;
    while k < 64 {
        let step = if maximum < 15 {
            if k < usize::from(maximum) { 8 } else { 16 }
        } else {
            if k < usize::from(maximum) { 2 } else { 8 }
        };
        let shift = match step {
            2 => 1,
            8 => 3,
            _ => 4,
        };
        if reader.read(1)? == 0 {
            k = decode_small_coefficient(reader, &mut planes, k, step)?;
        } else {
            let limit = if k <= 5 { 0x21 } else { 0x13 };
            let mut quotient = 0u32;
            while reader.read(1)? == 1 {
                quotient += 1;
                if quotient >= limit {
                    return Err(DecodeError::InvalidData(
                        "adaptive DCT coefficient prefix too long",
                    ));
                }
            }
            let magnitude = if k <= 5 {
                if quotient < 4 {
                    ((quotient << 2) | reader.read(2)?) + 2
                } else {
                    ((quotient << 3) | reader.read(3)?).wrapping_sub(14)
                }
            } else {
                match quotient {
                    0 => 2 | reader.read(1)?,
                    1 => 4 | reader.read(2)?,
                    _ => ((quotient << 3) | reader.read(3)?).wrapping_sub(8),
                }
            };
            let signed = if reader.read(1)? == 1 {
                -(magnitude as i32)
            } else {
                magnitude as i32
            };
            let byte = ((signed << shift) & 0xFF) as u8 as i8;
            planes[ZIGZAG[k]] = i16::from(byte);
            k += 1;
        }
    }
    Ok(planes)
}

/// The zero / end-of-block / run sub-code (`_decode_small_or_0_idct_coefficients`).
fn decode_small_coefficient(
    reader: &mut BitReader<'_>,
    planes: &mut Planes,
    k: usize,
    step: i16,
) -> Result<usize, DecodeError> {
    match reader.read(2)? {
        0 => Ok(k + 1),
        2 => {
            planes[ZIGZAG[k]] = step;
            Ok(k + 1)
        }
        3 => {
            planes[ZIGZAG[k]] = -step;
            Ok(k + 1)
        }
        _ => {
            if reader.read(1)? == 0 {
                return Ok(64);
            }
            let run = reader.read(2)? as usize;
            if run != 3 {
                return Ok(k + 3 + run);
            }
            let mut skip = 6usize;
            loop {
                let value = reader.read(3)? as usize;
                skip += value;
                if k + skip >= 64 {
                    return Err(DecodeError::InvalidData(
                        "adaptive DCT coefficient run past block end",
                    ));
                }
                if value != 7 {
                    break;
                }
            }
            Ok(k + skip)
        }
    }
}

fn solid_tile(color: [u8; 4]) -> [u8; TILE_BYTES] {
    let mut tile = [0u8; TILE_BYTES];
    for pixel in tile.as_chunks_mut::<4>().0 {
        *pixel = color;
    }
    tile
}

/// Reads a 20-bit YCC pixel (8 bit Y, 6 bit Cb, 6 bit Cr) as BGRA.
fn read_ycc20_bgra(reader: &mut BitReader<'_>) -> Result<[u8; 4], DecodeError> {
    let y = reader.read(8)? as u8;
    let cb = (reader.read(6)? as u8) << 2;
    let cr = (reader.read(6)? as u8) << 2;
    Ok(ycbcr_to_bgra(y, cb, cr))
}

/// Two-colour tile fill (`_fill_2_colour`).
///
/// The payload starts with an 8-bit row map. For each of the eight rows the
/// current top bit is inspected: 1 fills the whole row with `color_a` and
/// consumes nothing else, 0 reads an 8-bit row mask (MSB = leftmost pixel,
/// 1 = `color_a`) and chooses per pixel. The row map is shifted left by one
/// after every row, so one byte covers all eight rows. VNCKit does not treat
/// the byte as a single "fill whole tile" flag.
fn read_two_colour_tile(
    reader: &mut BitReader<'_>,
    color_a: [u8; 4],
    color_b: [u8; 4],
) -> Result<[u8; TILE_BYTES], DecodeError> {
    let mut row_map = reader.read(8)? as u8;
    let mut tile = [0u8; TILE_BYTES];
    for row in 0..TILE {
        if row_map & 0x80 != 0 {
            for column in 0..TILE {
                let offset = (row * TILE + column) * 4;
                tile[offset..offset + 4].copy_from_slice(&color_a);
            }
        } else {
            let bits = reader.read(8)?;
            for column in 0..TILE {
                let color = if bits & (0x80 >> column) != 0 {
                    color_a
                } else {
                    color_b
                };
                let offset = (row * TILE + column) * 4;
                tile[offset..offset + 4].copy_from_slice(&color);
            }
        }
        row_map <<= 1;
    }
    Ok(tile)
}

// --- IDCT and colour conversion (port of stb_image's integer path) ---

struct Idct1d {
    x0: i32,
    x1: i32,
    x2: i32,
    x3: i32,
    t0: i32,
    t1: i32,
    t2: i32,
    t3: i32,
}

fn idct_1d(s: [i32; 8]) -> Idct1d {
    let mut p2 = s[2];
    let mut p3 = s[6];
    let p1 = (p2 + p3) * 2217;
    let t2 = p1 + p3 * -7567;
    let t3 = p1 + p2 * 3135;
    p2 = s[0];
    p3 = s[4];
    let t0 = (p2 + p3) * 4096;
    let t1 = (p2 - p3) * 4096;
    let x0 = t0 + t3;
    let x3 = t0 - t3;
    let x1 = t1 + t2;
    let x2 = t1 - t2;

    let mut t0 = s[7];
    let mut t1 = s[5];
    let mut t2 = s[3];
    let mut t3 = s[1];
    let mut p3 = t0 + t2;
    let mut p4 = t1 + t3;
    let mut p1 = t0 + t3;
    let mut p2 = t1 + t2;
    let p5 = (p3 + p4) * 4816;
    t0 *= 1223;
    t1 *= 8410;
    t2 *= 12586;
    t3 *= 6149;
    p1 = p5 + p1 * -3685;
    p2 = p5 + p2 * -10497;
    p3 *= -8034;
    p4 *= -1597;
    Idct1d {
        x0,
        x1,
        x2,
        x3,
        t0: t0.wrapping_add(p1).wrapping_add(p3),
        t1: t1.wrapping_add(p2).wrapping_add(p4),
        t2: t2.wrapping_add(p2).wrapping_add(p3),
        t3: t3.wrapping_add(p1).wrapping_add(p4),
    }
}

fn clamp_u8(value: i32) -> u8 {
    value.clamp(0, 255) as u8
}

/// 8x8 inverse DCT on dequantised coefficients, in natural order.
fn idct_block(coefficients: &[i16; 64]) -> [u8; 64] {
    let mut intermediate = [0i32; 64];
    for column in 0..8 {
        let d = [
            i32::from(coefficients[column]),
            i32::from(coefficients[column + 8]),
            i32::from(coefficients[column + 16]),
            i32::from(coefficients[column + 24]),
            i32::from(coefficients[column + 32]),
            i32::from(coefficients[column + 40]),
            i32::from(coefficients[column + 48]),
            i32::from(coefficients[column + 56]),
        ];
        if d[1] == 0 && d[2] == 0 && d[3] == 0 && d[4] == 0 && d[5] == 0 && d[6] == 0 && d[7] == 0 {
            let dc = d[0].wrapping_mul(4);
            for row in 0..8 {
                intermediate[row * 8 + column] = dc;
            }
        } else {
            let r = idct_1d(d);
            let x0 = r.x0.wrapping_add(512);
            let x1 = r.x1.wrapping_add(512);
            let x2 = r.x2.wrapping_add(512);
            let x3 = r.x3.wrapping_add(512);
            intermediate[column] = (x0 + r.t3) >> 10;
            intermediate[56 + column] = (x0 - r.t3) >> 10;
            intermediate[8 + column] = (x1 + r.t2) >> 10;
            intermediate[48 + column] = (x1 - r.t2) >> 10;
            intermediate[16 + column] = (x2 + r.t1) >> 10;
            intermediate[40 + column] = (x2 - r.t1) >> 10;
            intermediate[24 + column] = (x3 + r.t0) >> 10;
            intermediate[32 + column] = (x3 - r.t0) >> 10;
        }
    }

    let mut output = [0u8; 64];
    for row in 0..8 {
        let v = [
            intermediate[row * 8],
            intermediate[row * 8 + 1],
            intermediate[row * 8 + 2],
            intermediate[row * 8 + 3],
            intermediate[row * 8 + 4],
            intermediate[row * 8 + 5],
            intermediate[row * 8 + 6],
            intermediate[row * 8 + 7],
        ];
        let r = idct_1d(v);
        let bias = 65_536 + (128 << 17);
        let x0 = r.x0.wrapping_add(bias);
        let x1 = r.x1.wrapping_add(bias);
        let x2 = r.x2.wrapping_add(bias);
        let x3 = r.x3.wrapping_add(bias);
        output[row * 8] = clamp_u8((x0 + r.t3) >> 17);
        output[row * 8 + 7] = clamp_u8((x0 - r.t3) >> 17);
        output[row * 8 + 1] = clamp_u8((x1 + r.t2) >> 17);
        output[row * 8 + 6] = clamp_u8((x1 - r.t2) >> 17);
        output[row * 8 + 2] = clamp_u8((x2 + r.t1) >> 17);
        output[row * 8 + 5] = clamp_u8((x2 - r.t1) >> 17);
        output[row * 8 + 3] = clamp_u8((x3 + r.t0) >> 17);
        output[row * 8 + 4] = clamp_u8((x3 - r.t0) >> 17);
    }
    output
}

const FLOAT2FIXED_1_402: i32 = 5743 << 8;
const FLOAT2FIXED_0_71414: i32 = 2925 << 8;
const FLOAT2FIXED_0_34414: i32 = 1410 << 8;
const FLOAT2FIXED_1_772: i32 = 7258 << 8;

/// stb_image's fixed-point YCbCr to BGRA conversion.
fn ycbcr_to_bgra(y: u8, cb: u8, cr: u8) -> [u8; 4] {
    let y_fixed = (i32::from(y) << 20) + (1 << 19);
    let cb = i32::from(cb) - 128;
    let cr = i32::from(cr) - 128;
    let r = (y_fixed + cr * FLOAT2FIXED_1_402) >> 20;
    let g =
        (y_fixed + cr * -FLOAT2FIXED_0_71414 + ((cb * -FLOAT2FIXED_0_34414) & !0xFFFFi32)) >> 20;
    let b = (y_fixed + cb * FLOAT2FIXED_1_772) >> 20;
    [clamp_u8(b), clamp_u8(g), clamp_u8(r), 255]
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Bits {
        bits: Vec<u8>,
    }

    impl Bits {
        fn new() -> Self {
            Self { bits: Vec::new() }
        }

        fn push(&mut self, value: u32, count: u8) {
            for shift in (0..count).rev() {
                self.bits.push(((value >> shift) & 1) as u8);
            }
        }

        fn push_bit(&mut self, value: bool) {
            self.bits.push(u8::from(value));
        }

        fn bytes(&self) -> Vec<u8> {
            let mut out = vec![0u8; self.bits.len().div_ceil(8)];
            for (index, bit) in self.bits.iter().enumerate() {
                if *bit != 0 {
                    out[index >> 3] |= 1 << (7 - (index & 7));
                }
            }
            out
        }
    }

    fn push_command(bits: &mut Bits, command: u8, count: usize) {
        bits.push(u32::from(command), 3);
        if count == 1 {
            bits.push_bit(false);
        } else if count <= 16 {
            bits.push_bit(true);
            bits.push((count - 2) as u32, 4);
        } else {
            assert!(count <= 144);
            bits.push_bit(true);
            bits.push(0xF, 4);
            bits.push((count - 17) as u32, 8);
        }
    }

    fn push_dc_rice(bits: &mut Bits, magnitude: u32) {
        if magnitude == 0 {
            bits.push(0, 2);
            return;
        }
        assert!(magnitude > 0);
        let quotient = match magnitude {
            1 => 0,
            2..=3 => 1,
            4..=7 => 2,
            _ => 3 + (magnitude - 8) / 8,
        };
        for _ in 0..quotient {
            bits.push_bit(true);
        }
        bits.push_bit(false);
        match quotient {
            0 => bits.push_bit(true),
            1 => bits.push(magnitude - 2, 1),
            2 => bits.push(magnitude - 4, 2),
            _ => bits.push((magnitude - 8) % 8, 3),
        }
        bits.push_bit(false); // positive
    }

    fn push_dc_tile(bits: &mut Bits, y_magnitude: u32) {
        bits.push_bit(false); // not a duplicate
        bits.push_bit(false); // decode chroma DC
        bits.push_bit(false); // use threshold1
        push_dc_rice(bits, 0); // Cb
        push_dc_rice(bits, 0); // Cr
        push_dc_rice(bits, y_magnitude);
        bits.push_bit(false); // small / zero sub-code
        bits.push(1, 2); // end of block
        bits.push_bit(false);
    }

    fn push_skip_bit(bits: &mut Bits) {
        bits.push_bit(false);
    }

    fn make_type0(commands: &Bits, coefficients: &Bits) -> Vec<u8> {
        let command_bytes = commands.bytes();
        let command_bytes = if command_bytes.is_empty() {
            vec![0]
        } else {
            command_bytes
        };
        let offset = 6 + command_bytes.len();
        let mut message = vec![
            0,
            0x0f,
            0x19,
            ((offset >> 16) & 0xFF) as u8,
            ((offset >> 8) & 0xFF) as u8,
            (offset & 0xFF) as u8,
        ];
        message.extend_from_slice(&command_bytes);
        message.extend_from_slice(&coefficients.bytes());
        message
    }

    fn framed(message: &[u8]) -> Vec<u8> {
        let mut data = (message.len() as u32).to_be_bytes().to_vec();
        data.extend_from_slice(message);
        data
    }

    fn rect(width: u16, height: u16) -> Rect {
        Rect {
            x: 0,
            y: 0,
            width,
            height,
        }
    }

    fn type2_message(y: u8, cbcr: u8) -> Vec<u8> {
        let mut message = vec![2u8];
        message.extend_from_slice(&[y; 64]);
        message.extend_from_slice(&[cbcr; 64]);
        message
    }

    fn decode_dc_tile(width: u16, height: u16, y_magnitude: u32) -> Vec<u8> {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 5, 1);
        let mut coefficients = Bits::new();
        push_dc_tile(&mut coefficients, y_magnitude);
        let message = make_type0(&commands, &coefficients);
        decode_apple_dct_message(&message, width, height, &PixelFormat::bgra8888()).unwrap()
    }

    #[test]
    fn bit_reader_reads_msb_first() {
        let mut reader = BitReader::new(&[0b1011_0010, 0b0100_0001]);
        assert_eq!(reader.read(4).unwrap(), 0b1011);
        assert_eq!(reader.read(8).unwrap(), 0b0010_0100);
        assert_eq!(reader.read(4).unwrap(), 0b0001);
        assert!(reader.read(1).is_err());
    }

    #[test]
    fn reads_all_run_length_forms() {
        let mut bits = Bits::new();
        bits.push_bit(false);
        bits.push_bit(true);
        bits.push(0, 4);
        bits.push_bit(true);
        bits.push(0xE, 4);
        bits.push_bit(true);
        bits.push(0xF, 4);
        bits.push(0x05, 8);
        bits.push_bit(true);
        bits.push(0xF, 4);
        bits.push(0xBA, 8);
        bits.push(0x01, 8);
        bits.push_bit(true);
        bits.push(0xF, 4);
        bits.push(0x81, 8);
        bits.push(0x81, 8);
        bits.push(0x02, 8);

        let bytes = bits.bytes();
        let mut reader = BitReader::new(&bytes);
        assert_eq!(read_num_boxes(&mut reader).unwrap(), 1);
        assert_eq!(read_num_boxes(&mut reader).unwrap(), 2);
        assert_eq!(read_num_boxes(&mut reader).unwrap(), 16);
        assert_eq!(read_num_boxes(&mut reader).unwrap(), 22);
        assert_eq!(read_num_boxes(&mut reader).unwrap(), 203);
        assert_eq!(
            read_num_boxes(&mut reader).unwrap(),
            17 + 1 + 128 + (2 << 14)
        );
    }

    #[test]
    fn default_quant_tables_match_vnc_kit() {
        assert_eq!(DEFAULT_QUANT_Y[0], 0x10);
        assert_eq!(DEFAULT_QUANT_Y[63], 0x4b);
        assert_eq!(DEFAULT_QUANT_CBCR[0], 0x13);
        assert_eq!(DEFAULT_QUANT_CBCR[63], 0x63);
        assert_eq!(DEFAULT_QUANT_Y.len(), 64);
        assert_eq!(DEFAULT_QUANT_CBCR.len(), 64);
    }

    #[test]
    fn idct_of_a_dc_only_block_is_flat() {
        let mut block = [0i16; 64];
        block[0] = 8;
        let output = idct_block(&block);
        let first = output[0];
        assert!(output.iter().all(|value| *value == first));
        assert!((128..=129).contains(&first));
    }

    #[test]
    fn decodes_a_dc_only_tile() {
        let pixels = decode_dc_tile(8, 8, 4);
        assert_eq!(pixels.len(), 8 * 8 * 4);
        for pixel in pixels.as_chunks::<4>().0 {
            assert_eq!(*pixel, [120, 120, 120, 255]);
        }
    }

    #[test]
    fn duplicate_command_copies_the_previous_tile() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 5, 2);
        let mut coefficients = Bits::new();
        push_dc_tile(&mut coefficients, 4);
        coefficients.push_bit(true); // duplicate the previous tile
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 16, 8, &PixelFormat::bgra8888()).unwrap();
        assert_eq!(pixels[..4], [120, 120, 120, 255]);
        assert_eq!(pixels[8 * 4..8 * 4 + 4], [120, 120, 120, 255]);
    }

    #[test]
    fn type2_updates_the_quantisation_tables() {
        let mut decoder = AdaptiveDctDecoder::new(8, 8, PixelFormat::bgra8888());
        decoder
            .decode_message(
                &type2_message(8, 8),
                Rect {
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0,
                },
            )
            .unwrap();
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 5, 1);
        let mut coefficients = Bits::new();
        push_dc_tile(&mut coefficients, 4);
        let message = make_type0(&commands, &coefficients);
        decoder.decode_message(&message, rect(8, 8)).unwrap();
        assert_eq!(&decoder.framebuffer()[..4], [124, 124, 124, 255]);
    }

    #[test]
    fn white_fill_command() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 0, 1);
        let message = make_type0(&commands, &Bits::new());
        let pixels = decode_apple_dct_message(&message, 8, 8, &PixelFormat::bgra8888()).unwrap();
        assert!(pixels.as_chunks::<4>().0.iter().all(|p| *p == [255; 4]));
    }

    #[test]
    fn solid_colour_fill_and_reuse() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 4, 2);
        let mut coefficients = Bits::new();
        coefficients.push(0, 2); // subtype 0, read one colour
        coefficients.push(128, 8); // Y
        coefficients.push(32, 6); // Cb
        coefficients.push(32, 6); // Cr
        coefficients.push(1, 2); // subtype 1, reuse the single colour
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 16, 8, &PixelFormat::bgra8888()).unwrap();
        for pixel in pixels.as_chunks::<4>().0 {
            assert_eq!(*pixel, [128, 128, 128, 255]);
        }
    }

    #[test]
    fn one_bit_mask_fill() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 3, 1);
        let mut coefficients = Bits::new();
        coefficients.push(0, 8); // not all colour A
        coefficients.push(0xFF, 8);
        for _ in 1..8 {
            coefficients.push(0, 8);
        }
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 8, 8, &PixelFormat::bgra8888()).unwrap();
        for column in 0..8 {
            assert_eq!(&pixels[column * 4..column * 4 + 4], [255, 255, 255, 255]);
        }
        for row in 1..8 {
            for column in 0..8 {
                let offset = (row * 8 + column) * 4;
                assert_eq!(&pixels[offset..offset + 4], [0, 0, 0, 255]);
            }
        }
    }

    #[test]
    fn two_colour_row_map_skips_masks_for_solid_rows() {
        // Command 3 uses colour A = white and colour B = black. The row map
        // 0x3F means rows 0 and 1 carry row masks, rows 2..7 are solid white;
        // only 16 mask bits follow the row map, not 64.
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 3, 1);
        let mut coefficients = Bits::new();
        coefficients.push(0x3F, 8);
        coefficients.push(0x00, 8); // row 0: all black
        coefficients.push(0x81, 8); // row 1: white at columns 0 and 7
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 8, 8, &PixelFormat::bgra8888()).unwrap();
        for column in 0..8 {
            assert_eq!(&pixels[column * 4..column * 4 + 4], [0, 0, 0, 255]);
        }
        for column in 0..8 {
            let offset = 8 * 4 + column * 4;
            let expected = if column == 0 || column == 7 {
                [255, 255, 255, 255]
            } else {
                [0, 0, 0, 255]
            };
            assert_eq!(&pixels[offset..offset + 4], expected);
        }
        for row in 2..8 {
            for column in 0..8 {
                let offset = (row * 8 + column) * 4;
                assert_eq!(&pixels[offset..offset + 4], [255, 255, 255, 255]);
            }
        }
    }

    #[test]
    fn two_colour_row_map_reads_masks_after_the_first_row() {
        // 0x80 fills only row 0 with colour A; rows 1..7 still read masks.
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 3, 1);
        let mut coefficients = Bits::new();
        coefficients.push(0x80, 8);
        for _ in 1..8 {
            coefficients.push(0x00, 8); // rows 1..7: all black
        }
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 8, 8, &PixelFormat::bgra8888()).unwrap();
        for column in 0..8 {
            assert_eq!(&pixels[column * 4..column * 4 + 4], [255, 255, 255, 255]);
        }
        for row in 1..8 {
            for column in 0..8 {
                let offset = (row * 8 + column) * 4;
                assert_eq!(&pixels[offset..offset + 4], [0, 0, 0, 255]);
            }
        }
    }

    #[test]
    fn two_colour_command_reads_the_row_map_after_the_colours() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 4, 1);
        let mut coefficients = Bits::new();
        coefficients.push(2, 2); // subtype 2: read colours A and B
        coefficients.push(128, 8); // A: Y
        coefficients.push(32, 6); // A: Cb
        coefficients.push(32, 6); // A: Cr
        coefficients.push(64, 8); // B: Y
        coefficients.push(32, 6); // B: Cb
        coefficients.push(32, 6); // B: Cr
        coefficients.push(0x3F, 8); // rows 0..1 masked, rows 2..7 solid A
        coefficients.push(0x00, 8); // row 0: B
        coefficients.push(0xFF, 8); // row 1: A
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 8, 8, &PixelFormat::bgra8888()).unwrap();
        for column in 0..8 {
            assert_eq!(&pixels[column * 4..column * 4 + 4], [64, 64, 64, 255]);
        }
        for row in 1..8 {
            for column in 0..8 {
                let offset = (row * 8 + column) * 4;
                assert_eq!(&pixels[offset..offset + 4], [128, 128, 128, 255]);
            }
        }
    }

    #[test]
    fn copies_the_previous_tile_in_raster_order() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 4, 1);
        push_command(&mut commands, 1, 1);
        let mut coefficients = Bits::new();
        coefficients.push(0, 2);
        coefficients.push(128, 8);
        coefficients.push(32, 6);
        coefficients.push(32, 6);
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 16, 8, &PixelFormat::bgra8888()).unwrap();
        for pixel in pixels.as_chunks::<4>().0 {
            assert_eq!(*pixel, [128, 128, 128, 255]);
        }
    }

    #[test]
    fn copies_the_tile_above() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 4, 1);
        push_command(&mut commands, 2, 1);
        let mut coefficients = Bits::new();
        coefficients.push(0, 2);
        coefficients.push(128, 8);
        coefficients.push(32, 6);
        coefficients.push(32, 6);
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 8, 16, &PixelFormat::bgra8888()).unwrap();
        for pixel in pixels.as_chunks::<4>().0 {
            assert_eq!(*pixel, [128, 128, 128, 255]);
        }
    }

    #[test]
    fn decodes_a_length_prefixed_rectangle() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 0, 1);
        let message = make_type0(&commands, &Bits::new());
        let data = framed(&message);
        let pixels = decode_apple_dct(&data, 8, 8, &PixelFormat::bgra8888()).unwrap();
        assert!(pixels.as_chunks::<4>().0.iter().all(|p| *p == [255; 4]));
    }

    #[test]
    fn reports_incomplete_and_unsupported_paths() {
        assert_eq!(
            decode_apple_dct(&[0, 0], 8, 8, &PixelFormat::bgra8888()).unwrap_err(),
            DecodeError::Incomplete
        );
        assert_eq!(
            decode_apple_dct_message(&[1, 0, 0, 0], 8, 8, &PixelFormat::bgra8888()).unwrap_err(),
            DecodeError::InvalidData("adaptive DCT type 1 (refine) is not implemented")
        );
        assert!(decode_apple_dct_message(&[], 8, 8, &PixelFormat::bgra8888()).is_err());
        assert!(decode_apple_dct_message(&[2; 128], 8, 8, &PixelFormat::bgra8888()).is_err());
        assert!(decode_apple_dct_message(&[9, 0, 0], 8, 8, &PixelFormat::bgra8888()).is_err());
    }

    #[test]
    fn rejects_non_32bpp_pixel_formats() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 0, 1);
        let message = make_type0(&commands, &Bits::new());
        assert!(decode_apple_dct_message(&message, 8, 8, &PixelFormat::rgb565()).is_err());
    }

    #[test]
    fn chroma_dc_rounds_previous_value_like_vnc_kit() {
        assert_eq!(chroma_dc(100, 0), 100);
        assert_eq!(chroma_dc(101, 0), 100);
        assert_eq!(chroma_dc(-100, 0), -100);
        assert_eq!(chroma_dc(-101, 0), -100);
        assert_eq!(chroma_dc(-3, 0), -2);
        assert_eq!(chroma_dc(0, 3), -6);
        assert_eq!(chroma_dc(i16::MIN, 0), i16::MIN);
    }

    #[test]
    fn new_tiles_predict_from_the_previous_tile() {
        let mut commands = Bits::new();
        push_skip_bit(&mut commands);
        push_command(&mut commands, 5, 2);
        let mut coefficients = Bits::new();
        push_dc_tile(&mut coefficients, 4);
        // Second tile sends a zero Y difference, so it must inherit Y = -4.
        coefficients.push_bit(false);
        coefficients.push_bit(false);
        coefficients.push_bit(false);
        push_dc_rice(&mut coefficients, 0);
        push_dc_rice(&mut coefficients, 0);
        push_dc_rice(&mut coefficients, 0);
        coefficients.push_bit(false);
        coefficients.push(1, 2);
        coefficients.push_bit(false);
        let message = make_type0(&commands, &coefficients);
        let pixels = decode_apple_dct_message(&message, 16, 8, &PixelFormat::bgra8888()).unwrap();
        assert_eq!(pixels[..4], [120, 120, 120, 255]);
        assert_eq!(pixels[8 * 4..8 * 4 + 4], [120, 120, 120, 255]);
    }

    #[test]
    #[ignore = "requires captured 1011 samples; set ADAPTIVE_DCT_SAMPLE_DIR"]
    fn decodes_captured_samples() {
        let directory =
            std::env::var("ADAPTIVE_DCT_SAMPLE_DIR").unwrap_or_else(|_| "/tmp/adaptive".into());
        let type2 = match std::fs::read(format!("{directory}/0_0_0x0.bin")) {
            Ok(data) => data,
            Err(_) => {
                eprintln!("sample not found in {directory}, skipping");
                return;
            }
        };
        let type0 = match std::fs::read(format!("{directory}/1_0_144x144.bin")) {
            Ok(data) => data,
            Err(_) => {
                eprintln!("type 0 sample not found in {directory}, skipping");
                return;
            }
        };
        assert_eq!(type2.len(), 129);
        assert_eq!(type0.len(), 841);

        let mut decoder = AdaptiveDctDecoder::new(144, 144, PixelFormat::bgra8888());
        decoder
            .decode_message(
                &type2,
                Rect {
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 0,
                },
            )
            .expect("type 2");
        decoder
            .decode_message(&type0, rect(144, 144))
            .expect("type 0");

        let pixels = decoder.framebuffer();
        assert_eq!(pixels.len(), 144 * 144 * 4);
        // The sample covers all 324 tiles (315 new coefficient tiles, 7
        // two-colour fills, 1 repeat and 1 copy); a wrong command or
        // coefficient layout fails before this point. The checksum matches
        // VNCKit's own decode of this sample byte for byte, so it also locks
        // the fill row-map semantics.
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        for byte in pixels {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x100_0000_01b3);
        }
        assert_eq!(hash, 0x366e_5ff4_4c07_f4f6);
        assert_eq!(&pixels[..4], &[95, 55, 83, 255]);
    }

    #[test]
    #[ignore = "requires the captured 4192x2624 stream sample; set ADAPTIVE_DCT_FAIL_SAMPLE"]
    fn decodes_captured_large_type0_sample() {
        let path = std::env::var("ADAPTIVE_DCT_FAIL_SAMPLE")
            .unwrap_or_else(|_| "/tmp/dct-fail.bin".into());
        let data = match std::fs::read(&path) {
            Ok(data) => data,
            Err(_) => {
                eprintln!("sample not found at {path}, skipping");
                return;
            }
        };
        // The rect is 4192x2624 at +6320+336; the minimal framebuffer is
        // 10512x2960. The message has 171,872 tiles and must consume the whole
        // length-prefixed payload.
        let mut decoder = AdaptiveDctDecoder::new(10_512, 2_960, PixelFormat::bgra8888());
        let consumed = decoder
            .decode_rect(
                &data,
                Rect {
                    x: 6320,
                    y: 336,
                    width: 4192,
                    height: 2624,
                },
            )
            .expect("large type 0 sample");
        assert_eq!(consumed, data.len());

        let stride = 10_512 * 4;
        let mut hash = 0xcbf2_9ce4_8422_2325u64;
        for row in 0..2624usize {
            let start = (336 + row) * stride + 6320 * 4;
            for byte in &decoder.framebuffer()[start..start + 4192 * 4] {
                hash ^= u64::from(*byte);
                hash = hash.wrapping_mul(0x100_0000_01b3);
            }
        }
        // Byte-exact match with VNCKit's decoder output for the same sample.
        assert_eq!(hash, 0x83ae_a03d_e560_9a22);
    }
}
