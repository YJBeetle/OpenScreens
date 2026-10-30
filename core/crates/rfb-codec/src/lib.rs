//! Rectangle decoders for RFB encodings.
//!
//! Decoding is sans-I/O: callers pass the bytes of one rectangle and receive
//! the number of bytes consumed. `DecodeError::Incomplete` means more bytes
//! are needed; the framebuffer is left untouched in that case.

mod compression;
mod hextile;
mod pixel;
mod rre;
mod zrle;

use rfb_proto::encoding::Encoding;
use rfb_proto::pixel_format::PixelFormat;

use crate::compression::Inflater;
use crate::pixel::{Cursor, store_pixel};

/// A tightly packed BGRA8888 framebuffer.
pub struct Framebuffer {
    width: u16,
    height: u16,
    pixels: Vec<u8>,
}

impl Framebuffer {
    pub fn new(width: u16, height: u16) -> Self {
        Self {
            width,
            height,
            pixels: vec![0; pixel_count(width, height)],
        }
    }

    pub fn resize(&mut self, width: u16, height: u16) {
        if self.width == width && self.height == height {
            return;
        }
        self.width = width;
        self.height = height;
        self.pixels = vec![0; pixel_count(width, height)];
    }

    pub fn width(&self) -> u16 {
        self.width
    }

    pub fn height(&self) -> u16 {
        self.height
    }

    pub fn pixels(&self) -> &[u8] {
        &self.pixels
    }

    pub fn pixels_mut(&mut self) -> &mut [u8] {
        &mut self.pixels
    }

    fn contains(&self, rect: Rect) -> bool {
        let x = usize::from(rect.x);
        let y = usize::from(rect.y);
        let width = usize::from(rect.width);
        let height = usize::from(rect.height);
        width > 0
            && height > 0
            && x + width <= usize::from(self.width)
            && y + height <= usize::from(self.height)
    }
}

fn pixel_count(width: u16, height: u16) -> usize {
    usize::from(width) * usize::from(height) * 4
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeError {
    Incomplete,
    InvalidData(&'static str),
    UnsupportedEncoding(i32),
}

pub struct Decoder {
    scratch: Vec<u8>,
    inflated: Vec<u8>,
    zrle: Inflater,
    zlib: Inflater,
}

impl Decoder {
    pub fn new() -> Self {
        Self {
            scratch: Vec::new(),
            inflated: Vec::new(),
            zrle: Inflater::new(),
            zlib: Inflater::new(),
        }
    }

    /// Decodes one rectangle. Returns the number of bytes consumed from
    /// `data`. When `Incomplete` is returned the framebuffer is unchanged.
    pub fn decode(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        encoding: Encoding,
        data: &[u8],
        pixel_format: PixelFormat,
    ) -> Result<usize, DecodeError> {
        if !framebuffer.contains(rect) {
            return Err(DecodeError::InvalidData("rectangle out of bounds"));
        }

        match encoding {
            Encoding::Raw => decode_raw(framebuffer, rect, data, pixel_format),
            Encoding::CopyRect => self.decode_copy_rect(framebuffer, rect, data),
            Encoding::Rre => {
                let width = usize::from(rect.width);
                let height = usize::from(rect.height);
                self.prepare_scratch(width, height);
                let consumed = rre::decode(data, pixel_format, width, height, &mut self.scratch)?;
                self.blit(framebuffer, rect);
                Ok(consumed)
            }
            Encoding::Hextile => {
                let width = usize::from(rect.width);
                let height = usize::from(rect.height);
                self.prepare_scratch(width, height);
                let consumed =
                    hextile::decode(data, pixel_format, width, height, &mut self.scratch)?;
                self.blit(framebuffer, rect);
                Ok(consumed)
            }
            Encoding::Zrle => self.decode_zrle(framebuffer, rect, data, pixel_format),
            Encoding::Zlib => self.decode_zlib(framebuffer, rect, data, pixel_format),
            other => Err(DecodeError::UnsupportedEncoding(other.to_id())),
        }
    }

    fn prepare_scratch(&mut self, width: usize, height: usize) {
        self.scratch.resize(width * height * 4, 0);
    }

    fn blit(&self, framebuffer: &mut Framebuffer, rect: Rect) {
        let stride = usize::from(framebuffer.width()) * 4;
        let row_bytes = usize::from(rect.width) * 4;
        let x = usize::from(rect.x);
        let y = usize::from(rect.y);
        for row in 0..usize::from(rect.height) {
            let source = row * row_bytes;
            let destination = (y + row) * stride + x * 4;
            framebuffer.pixels_mut()[destination..destination + row_bytes]
                .copy_from_slice(&self.scratch[source..source + row_bytes]);
        }
    }

    fn decode_copy_rect(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        data: &[u8],
    ) -> Result<usize, DecodeError> {
        if data.len() < 4 {
            return Err(DecodeError::Incomplete);
        }
        let source_x = usize::from(u16::from_be_bytes([data[0], data[1]]));
        let source_y = usize::from(u16::from_be_bytes([data[2], data[3]]));
        let width = usize::from(rect.width);
        let height = usize::from(rect.height);
        let stride = usize::from(framebuffer.width()) * 4;

        if source_x + width > usize::from(framebuffer.width())
            || source_y + height > usize::from(framebuffer.height())
        {
            return Err(DecodeError::InvalidData("CopyRect source out of bounds"));
        }

        self.prepare_scratch(width, height);
        let row_bytes = width * 4;
        for row in 0..height {
            let source = (source_y + row) * stride + source_x * 4;
            let destination = row * row_bytes;
            self.scratch[destination..destination + row_bytes]
                .copy_from_slice(&framebuffer.pixels()[source..source + row_bytes]);
        }
        self.blit(framebuffer, rect);
        Ok(4)
    }

    fn decode_zrle(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        data: &[u8],
        pixel_format: PixelFormat,
    ) -> Result<usize, DecodeError> {
        let (payload, consumed) = split_payload(data)?;
        self.zrle.inflate(payload, &mut self.inflated)?;

        let width = usize::from(rect.width);
        let height = usize::from(rect.height);
        self.prepare_scratch(width, height);
        zrle::decode(
            &self.inflated,
            pixel_format,
            width,
            height,
            &mut self.scratch,
        )?;
        self.blit(framebuffer, rect);
        Ok(consumed)
    }

    fn decode_zlib(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        data: &[u8],
        pixel_format: PixelFormat,
    ) -> Result<usize, DecodeError> {
        let (payload, consumed) = split_payload(data)?;
        self.zlib.inflate(payload, &mut self.inflated)?;

        let width = usize::from(rect.width);
        let height = usize::from(rect.height);
        let expected = width * height * pixel_format.bytes_per_pixel();
        if self.inflated.len() != expected {
            return Err(DecodeError::InvalidData("zlib payload size mismatch"));
        }

        self.prepare_scratch(width, height);
        let stride = width * 4;
        let mut cursor = Cursor::new(&self.inflated);
        for row in 0..height {
            for column in 0..width {
                let color = cursor.pixel(pixel_format)?;
                store_pixel(&mut self.scratch, stride, column, row, color, pixel_format)?;
            }
        }
        self.blit(framebuffer, rect);
        Ok(consumed)
    }
}

impl Default for Decoder {
    fn default() -> Self {
        Self::new()
    }
}

fn split_payload(data: &[u8]) -> Result<(&[u8], usize), DecodeError> {
    if data.len() < 4 {
        return Err(DecodeError::Incomplete);
    }
    let length = u32::from_be_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let consumed = 4usize
        .checked_add(length)
        .ok_or(DecodeError::InvalidData("payload length overflow"))?;
    if data.len() < consumed {
        return Err(DecodeError::Incomplete);
    }
    Ok((&data[4..consumed], consumed))
}

fn decode_raw(
    framebuffer: &mut Framebuffer,
    rect: Rect,
    data: &[u8],
    pixel_format: PixelFormat,
) -> Result<usize, DecodeError> {
    let width = usize::from(rect.width);
    let height = usize::from(rect.height);
    let needed = width * height * pixel_format.bytes_per_pixel();
    if data.len() < needed {
        return Err(DecodeError::Incomplete);
    }

    let stride = usize::from(framebuffer.width()) * 4;
    let x = usize::from(rect.x);
    let y = usize::from(rect.y);
    let mut cursor = Cursor::new(&data[..needed]);
    let pixels = framebuffer.pixels_mut();
    for row in 0..height {
        for column in 0..width {
            let color = cursor.pixel(pixel_format)?;
            store_pixel(pixels, stride, x + column, y + row, color, pixel_format)?;
        }
    }
    Ok(needed)
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use flate2::Compression;
    use flate2::write::ZlibEncoder;

    use super::*;

    fn rect(x: u16, y: u16, width: u16, height: u16) -> Rect {
        Rect {
            x,
            y,
            width,
            height,
        }
    }

    fn compress_chunks(chunks: &[&[u8]]) -> Vec<Vec<u8>> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        chunks
            .iter()
            .map(|chunk| {
                let start = encoder.get_ref().len();
                encoder.write_all(chunk).unwrap();
                encoder.flush().unwrap();
                encoder.get_ref()[start..].to_vec()
            })
            .collect()
    }

    fn framed(compressed: &[u8]) -> Vec<u8> {
        let mut message = Vec::new();
        message.extend_from_slice(&(compressed.len() as u32).to_be_bytes());
        message.extend_from_slice(compressed);
        message
    }

    fn red() -> [u8; 4] {
        [0, 0, 255, 255]
    }

    fn green() -> [u8; 4] {
        [0, 255, 0, 255]
    }

    fn blue() -> [u8; 4] {
        [255, 0, 0, 255]
    }

    fn white() -> [u8; 4] {
        [255, 255, 255, 255]
    }

    #[test]
    fn decodes_raw() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut data = Vec::new();
        for pixel in [red(), green(), blue(), white()] {
            data.extend_from_slice(&pixel);
        }
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Raw,
                &data,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, 16);
        assert_eq!(framebuffer.pixels(), data);
    }

    #[test]
    fn raw_is_incomplete_without_mutation() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let data = [0u8; 15];
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Raw,
                &data,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::Incomplete);
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn copy_rect_handles_overlap() {
        let mut framebuffer = Framebuffer::new(4, 1);
        let mut decoder = Decoder::new();
        let mut initial = Vec::new();
        for pixel in [
            [1, 0, 0, 255],
            [2, 0, 0, 255],
            [3, 0, 0, 255],
            [4, 0, 0, 255],
        ] {
            initial.extend_from_slice(&pixel);
        }
        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 4, 1),
                Encoding::Raw,
                &initial,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 3, 1),
                Encoding::CopyRect,
                &[0, 1, 0, 0],
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, 4);
        assert_eq!(
            framebuffer.pixels(),
            &[2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255, 4, 0, 0, 255]
        );
    }

    #[test]
    fn decodes_rre() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut data = Vec::new();
        data.extend_from_slice(&1u32.to_be_bytes());
        data.extend_from_slice(&[0, 0, 0, 255]);
        data.extend_from_slice(&white());
        data.extend_from_slice(&0u16.to_be_bytes());
        data.extend_from_slice(&0u16.to_be_bytes());
        data.extend_from_slice(&2u16.to_be_bytes());
        data.extend_from_slice(&2u16.to_be_bytes());
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Rre,
                &data,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, data.len());
        assert!(framebuffer.pixels().chunks_exact(4).all(|p| p == white()));
    }

    #[test]
    fn decodes_hextile_subrects() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut data = vec![2 | 4 | 8];
        data.extend_from_slice(&[0, 0, 0, 255]);
        data.extend_from_slice(&red());
        data.push(1);
        data.push(0x00);
        data.push(0x11);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Hextile,
                &data,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, data.len());
        assert!(framebuffer.pixels().chunks_exact(4).all(|p| p == red()));
    }

    #[test]
    fn decodes_hextile_raw_tile() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut data = vec![1];
        for pixel in [red(), green(), blue(), white()] {
            data.extend_from_slice(&pixel);
        }
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Hextile,
                &data,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, data.len());
        assert_eq!(framebuffer.pixels(), &data[1..]);
    }

    fn zrle_payload_solid(color: [u8; 4]) -> Vec<u8> {
        vec![1, color[0], color[1], color[2]]
    }

    #[test]
    fn decodes_zrle_solid() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let payload = zrle_payload_solid(red());
        let compressed = compress_chunks(&[&payload]);
        let message = framed(&compressed[0]);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &message,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, message.len());
        assert!(framebuffer.pixels().chunks_exact(4).all(|p| p == red()));
    }

    #[test]
    fn zrle_stream_persists_across_rectangles() {
        let mut framebuffer = Framebuffer::new(4, 2);
        let mut decoder = Decoder::new();
        let first = zrle_payload_solid(red());
        let second = zrle_payload_solid(green());
        let compressed = compress_chunks(&[&first, &second]);

        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &framed(&compressed[0]),
                PixelFormat::bgra8888(),
            )
            .unwrap();
        decoder
            .decode(
                &mut framebuffer,
                rect(2, 0, 2, 2),
                Encoding::Zrle,
                &framed(&compressed[1]),
                PixelFormat::bgra8888(),
            )
            .unwrap();

        for row in 0..2 {
            for column in 0..2 {
                let offset = (row * 4 + column) * 4;
                assert_eq!(&framebuffer.pixels()[offset..offset + 4], red());
                let offset = (row * 4 + column + 2) * 4;
                assert_eq!(&framebuffer.pixels()[offset..offset + 4], green());
            }
        }
    }

    #[test]
    fn decodes_zrle_plain_rle() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let payload = vec![3, 0, 0, 255, 3];
        let compressed = compress_chunks(&[&payload]);
        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &framed(&compressed[0]),
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert!(framebuffer.pixels().chunks_exact(4).all(|p| p == red()));
    }

    #[test]
    fn decodes_zrle_packed_palette() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut payload = vec![2, 2];
        payload.extend_from_slice(&[0, 0, 0]);
        payload.extend_from_slice(&[255, 255, 255]);
        payload.extend_from_slice(&[0x40, 0x40]);
        let compressed = compress_chunks(&[&payload]);
        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &framed(&compressed[0]),
                PixelFormat::bgra8888(),
            )
            .unwrap();

        let pixels = framebuffer.pixels();
        assert_eq!(&pixels[0..4], &[0, 0, 0, 255]);
        assert_eq!(&pixels[4..8], white());
        assert_eq!(&pixels[8..12], &[0, 0, 0, 255]);
        assert_eq!(&pixels[12..16], white());
    }

    #[test]
    fn decodes_zrle_palette_rle() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut payload = vec![4, 2];
        payload.extend_from_slice(&[0, 0, 0]);
        payload.extend_from_slice(&[255, 255, 255]);
        payload.extend_from_slice(&[0x80, 3]);
        let compressed = compress_chunks(&[&payload]);
        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &framed(&compressed[0]),
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert!(
            framebuffer
                .pixels()
                .chunks_exact(4)
                .all(|p| p == [0, 0, 0, 255])
        );
    }

    #[test]
    fn zrle_is_incomplete_without_mutation() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let payload = zrle_payload_solid(red());
        let compressed = compress_chunks(&[&payload]);
        let mut message = framed(&compressed[0]);
        message.pop();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zrle,
                &message,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::Incomplete);
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn decodes_zlib_encoding() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut payload = Vec::new();
        for pixel in [red(), green(), blue(), white()] {
            payload.extend_from_slice(&pixel);
        }
        let compressed = compress_chunks(&[&payload]);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Zlib,
                &framed(&compressed[0]),
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, framed(&compressed[0]).len());
        assert_eq!(framebuffer.pixels(), payload);
    }

    #[test]
    fn rejects_out_of_bounds_rectangles() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(1, 1, 2, 2),
                Encoding::Raw,
                &[0u8; 16],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("rectangle out of bounds"));
    }

    #[test]
    fn rejects_unsupported_encodings() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &[],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::UnsupportedEncoding(7));
    }
}
