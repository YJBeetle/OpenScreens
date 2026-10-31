//! Rectangle decoders for RFB encodings.
//!
//! Decoding is sans-I/O: callers pass the bytes of one rectangle and receive
//! the number of bytes consumed. `DecodeError::Incomplete` means more bytes
//! are needed; the framebuffer is left untouched in that case.

pub mod apple_dct;
mod compression;
mod cursor;
mod hextile;
mod pixel;
mod rre;
mod tight;
mod zrle;

use rfb_proto::encoding::Encoding;
use rfb_proto::pixel_format::PixelFormat;

use crate::compression::Inflater;
use crate::pixel::{Cursor, store_pixel};
use crate::tight::TightDecoder;

pub use crate::cursor::{CursorShape, decode_cursor};

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
    tight: TightDecoder,
}

impl Decoder {
    pub fn new() -> Self {
        Self {
            scratch: Vec::new(),
            inflated: Vec::new(),
            zrle: Inflater::new(),
            zlib: Inflater::new(),
            tight: TightDecoder::new(),
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
            Encoding::Tight => self.tight.decode(framebuffer, rect, data, pixel_format),
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
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == white())
        );
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
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == red())
        );
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
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == red())
        );
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
        let payload = vec![128, 0, 0, 255, 3];
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
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == red())
        );
    }

    #[test]
    fn decodes_zrle_packed_palette() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut payload = vec![2];
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
        let mut payload = vec![130];
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
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == [0, 0, 0, 255])
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
                Encoding::Other(1234),
                &[],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::UnsupportedEncoding(1234));
    }

    struct TightEncoder {
        encoder: ZlibEncoder<Vec<u8>>,
    }

    impl TightEncoder {
        fn new() -> Self {
            Self {
                encoder: ZlibEncoder::new(Vec::new(), Compression::default()),
            }
        }

        /// Compresses one rectangle worth of filter data with Z_SYNC_FLUSH.
        fn chunk(&mut self, payload: &[u8]) -> Vec<u8> {
            let start = self.encoder.get_ref().len();
            self.encoder.write_all(payload).unwrap();
            self.encoder.flush().unwrap();
            self.encoder.get_ref()[start..].to_vec()
        }
    }

    /// One rectangle with no stream resets and a Basic compression control.
    fn tight_wire(stream: u8, filter: Option<u8>, compressed: &[u8]) -> Vec<u8> {
        let mut control = stream << 4;
        if filter.is_some() {
            control |= 0x40;
        }
        let mut wire = vec![control];
        if let Some(filter) = filter {
            wire.push(filter);
        }
        wire.extend_from_slice(compressed);
        wire
    }

    fn rgb(colour: [u8; 4]) -> [u8; 3] {
        [colour[2], colour[1], colour[0]]
    }

    fn bgras(colours: &[[u8; 4]]) -> Vec<u8> {
        colours
            .iter()
            .flat_map(|colour| colour.iter().copied())
            .collect()
    }

    const TINY_JPEG: &[u8] = include_bytes!("testdata/tiny.jpg");

    fn tight_jpeg_wire() -> Vec<u8> {
        let length = TINY_JPEG.len();
        let mut wire = vec![0x90];
        wire.push((length & 0x7f) as u8 | 0x80);
        wire.push(((length >> 7) & 0x7f) as u8);
        wire.extend_from_slice(TINY_JPEG);
        wire
    }

    #[test]
    fn tight_decodes_copy_with_rgb_tpixels() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let colours = [red(), green(), blue(), white()];
        let mut payload = Vec::new();
        for colour in colours {
            payload.extend_from_slice(&rgb(colour));
        }
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, None, &compressed);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert_eq!(framebuffer.pixels(), bgras(&colours));
    }

    #[test]
    fn tight_copy_uses_negotiated_pixel_format() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let mut payload = Vec::new();
        for pixel in [0xf800u16, 0x07e0, 0x001f, 0xffff] {
            payload.extend_from_slice(&pixel.to_le_bytes());
        }
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(0), &compressed);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::rgb565(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert_eq!(
            framebuffer.pixels(),
            bgras(&[red(), green(), blue(), white()])
        );
    }

    #[test]
    fn tight_stream_persists_and_stops_at_rect_boundary() {
        let mut framebuffer = Framebuffer::new(4, 2);
        let mut decoder = Decoder::new();
        let mut encoder = TightEncoder::new();
        let first = encoder.chunk(
            &[red(), green(), blue(), white()]
                .iter()
                .flat_map(|colour| rgb(*colour))
                .collect::<Vec<_>>(),
        );
        let second = encoder.chunk(
            &[blue(), white(), red(), green()]
                .iter()
                .flat_map(|colour| rgb(*colour))
                .collect::<Vec<_>>(),
        );
        let first_wire = tight_wire(0, None, &first);
        let second_wire = tight_wire(0, None, &second);
        let mut message = first_wire.clone();
        message.extend_from_slice(&second_wire);

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &message,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, first_wire.len());

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(2, 0, 2, 2),
                Encoding::Tight,
                &message[consumed..],
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, second_wire.len());

        let expected = [
            red(),
            green(),
            blue(),
            white(),
            blue(),
            white(),
            red(),
            green(),
        ];
        let mut rows = Vec::new();
        rows.extend_from_slice(&bgras(&expected[..2]));
        rows.extend_from_slice(&bgras(&expected[4..6]));
        rows.extend_from_slice(&bgras(&expected[2..4]));
        rows.extend_from_slice(&bgras(&expected[6..8]));
        assert_eq!(framebuffer.pixels(), rows);
    }

    #[test]
    fn tight_reset_starts_a_fresh_zlib_stream() {
        let mut framebuffer = Framebuffer::new(4, 2);
        let mut decoder = Decoder::new();
        let first = TightEncoder::new().chunk(
            &[red(), green(), blue(), white()]
                .iter()
                .flat_map(|c| rgb(*c))
                .collect::<Vec<_>>(),
        );
        let second = TightEncoder::new().chunk(
            &[green(), blue(), white(), red()]
                .iter()
                .flat_map(|c| rgb(*c))
                .collect::<Vec<_>>(),
        );

        let mut first_wire = vec![0x00];
        first_wire.extend_from_slice(&first);
        let mut second_wire = vec![0x01];
        second_wire.extend_from_slice(&second);

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &first_wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, first_wire.len());
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(2, 0, 2, 2),
                Encoding::Tight,
                &second_wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, second_wire.len());

        assert_eq!(&framebuffer.pixels()[0..8], &bgras(&[red(), green()]));
        assert_eq!(&framebuffer.pixels()[8..16], &bgras(&[green(), blue()]));
        assert_eq!(&framebuffer.pixels()[16..24], &bgras(&[blue(), white()]));
        assert_eq!(&framebuffer.pixels()[24..32], &bgras(&[white(), red()]));
    }

    #[test]
    fn tight_reset_bits_live_in_the_control_low_nibble() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let wire = [0x81, 0, 0, 0];
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|pixel| *pixel == [0, 0, 0, 255])
        );
    }

    #[test]
    fn tight_fill_uses_tpixel() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let wire = [0x80, 50, 100, 200];
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|pixel| *pixel == [200, 100, 50, 255])
        );
    }

    #[test]
    fn tight_fill_uses_negotiated_pixel_format() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let wire = [0x80, 0x00, 0xf8];
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::rgb565(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert!(
            framebuffer
                .pixels()
                .as_chunks::<4>()
                .0
                .iter()
                .all(|p| *p == red())
        );
    }

    #[test]
    fn tight_fill_is_incomplete_without_mutation() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &[0x80, 50, 100],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::Incomplete);
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn tight_decodes_one_bit_palette() {
        let mut framebuffer = Framebuffer::new(4, 2);
        let mut decoder = Decoder::new();
        let mut payload = vec![2];
        payload.extend_from_slice(&rgb(white()));
        payload.extend_from_slice(&rgb(red()));
        payload.extend_from_slice(&[0b0101_0000, 0b1010_0000]);
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(1), &compressed);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 4, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert_eq!(
            framebuffer.pixels(),
            bgras(&[
                white(),
                red(),
                white(),
                red(),
                red(),
                white(),
                red(),
                white()
            ])
        );
    }

    #[test]
    fn tight_palette_pads_each_row() {
        let mut framebuffer = Framebuffer::new(3, 1);
        let mut decoder = Decoder::new();
        let mut payload = vec![3];
        payload.extend_from_slice(&rgb(red()));
        payload.extend_from_slice(&rgb(green()));
        payload.extend_from_slice(&rgb(blue()));
        payload.push(0b00_01_10_00);
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(1), &compressed);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 3, 1),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        assert_eq!(framebuffer.pixels(), bgras(&[red(), green(), blue()]));
    }

    #[test]
    fn tight_decodes_eight_bit_palette() {
        let mut framebuffer = Framebuffer::new(4, 1);
        let mut decoder = Decoder::new();
        let size = 130usize;
        let mut payload = vec![size as u8];
        for index in 0..size {
            payload.extend_from_slice(&[(index * 3) as u8, (index * 5) as u8, (index * 7) as u8]);
        }
        let indices = [0u8, 129, 64, 3];
        payload.extend_from_slice(&indices);
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(1), &compressed);
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 4, 1),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
        let expected: Vec<[u8; 4]> = indices
            .iter()
            .map(|&index| {
                let index = usize::from(index);
                [(index * 7) as u8, (index * 5) as u8, (index * 3) as u8, 255]
            })
            .collect();
        assert_eq!(framebuffer.pixels(), bgras(&expected));
    }

    #[test]
    fn tight_rejects_zero_palette_size() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let compressed = TightEncoder::new().chunk(&[0]);
        let wire = tight_wire(0, Some(1), &compressed);
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("tight palette size"));
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn tight_rejects_palette_index_out_of_range() {
        let mut framebuffer = Framebuffer::new(1, 1);
        let mut decoder = Decoder::new();
        let mut payload = vec![3];
        payload.extend_from_slice(&rgb(red()));
        payload.extend_from_slice(&rgb(green()));
        payload.extend_from_slice(&rgb(blue()));
        payload.push(0b11_000000);
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(1), &compressed);
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 1, 1),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("tight palette index"));
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn tight_rejects_gradient_filter() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &[0x40, 0x02],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("tight gradient filter"));
    }

    #[test]
    fn tight_rejects_unknown_compression_type() {
        let mut framebuffer = Framebuffer::new(2, 2);
        let mut decoder = Decoder::new();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &[0xa0],
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("tight compression type"));
    }

    #[test]
    fn tight_decodes_jpeg() {
        let mut framebuffer = Framebuffer::new(8, 8);
        let mut decoder = Decoder::new();
        let wire = tight_jpeg_wire();
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 8, 8),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());

        let mut source = zune_jpeg::JpegDecoder::new(std::io::Cursor::new(TINY_JPEG));
        let rgb = source.decode().unwrap();
        let mut expected = Vec::new();
        for pixel in rgb.as_chunks::<3>().0.iter() {
            expected.extend_from_slice(&[pixel[2], pixel[1], pixel[0], 255]);
        }
        assert_eq!(expected.len(), 8 * 8 * 4);
        assert_eq!(framebuffer.pixels(), expected);
    }

    #[test]
    fn tight_jpeg_rejects_dimension_mismatch() {
        let mut framebuffer = Framebuffer::new(4, 4);
        let mut decoder = Decoder::new();
        let wire = tight_jpeg_wire();
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 4, 4),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::InvalidData("tight JPEG dimensions"));
        assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
    }

    #[test]
    fn tight_jpeg_is_incomplete_without_mutation() {
        let mut framebuffer = Framebuffer::new(8, 8);
        let mut decoder = Decoder::new();
        let wire = tight_jpeg_wire();
        for prefix in [1, 2, 3, wire.len() - 1] {
            let mut framebuffer = Framebuffer::new(8, 8);
            let mut decoder = Decoder::new();
            let error = decoder
                .decode(
                    &mut framebuffer,
                    rect(0, 0, 8, 8),
                    Encoding::Tight,
                    &wire[..prefix],
                    PixelFormat::bgra8888(),
                )
                .unwrap_err();
            assert_eq!(error, DecodeError::Incomplete, "prefix {prefix}");
            assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
        }
        // Retrying with the complete message succeeds.
        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 8, 8),
                Encoding::Tight,
                &wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, wire.len());
    }

    #[test]
    fn tight_incomplete_at_every_prefix() {
        let colours = [red(), green(), blue(), white()];
        let mut payload = Vec::new();
        for colour in colours {
            payload.extend_from_slice(&rgb(colour));
        }
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, None, &compressed);

        let mut decoder = Decoder::new();
        let mut framebuffer = Framebuffer::new(2, 2);
        for prefix in 0..=wire.len() {
            let result = decoder.decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &wire[..prefix],
                PixelFormat::bgra8888(),
            );
            if prefix < wire.len() {
                assert_eq!(result, Err(DecodeError::Incomplete), "prefix {prefix}");
                assert!(
                    framebuffer.pixels().iter().all(|&byte| byte == 0),
                    "prefix {prefix}"
                );
            } else {
                assert_eq!(result, Ok(wire.len()));
            }
        }
        assert_eq!(framebuffer.pixels(), bgras(&colours));
    }

    #[test]
    fn tight_incomplete_prefixes_retry_from_scratch() {
        let colours = [red(), green(), blue(), white()];
        let mut payload = Vec::new();
        for colour in colours {
            payload.extend_from_slice(&rgb(colour));
        }
        let compressed = TightEncoder::new().chunk(&payload);
        let wire = tight_wire(0, Some(0), &compressed);

        let mut prefixes = vec![0, 1, 2, 3, 4, wire.len() / 2, wire.len() - 1];
        prefixes.sort_unstable();
        prefixes.dedup();
        for prefix in prefixes {
            let mut framebuffer = Framebuffer::new(2, 2);
            let mut decoder = Decoder::new();
            let error = decoder
                .decode(
                    &mut framebuffer,
                    rect(0, 0, 2, 2),
                    Encoding::Tight,
                    &wire[..prefix],
                    PixelFormat::bgra8888(),
                )
                .unwrap_err();
            assert_eq!(error, DecodeError::Incomplete, "prefix {prefix}");
            assert!(framebuffer.pixels().iter().all(|&byte| byte == 0));
            let consumed = decoder
                .decode(
                    &mut framebuffer,
                    rect(0, 0, 2, 2),
                    Encoding::Tight,
                    &wire,
                    PixelFormat::bgra8888(),
                )
                .unwrap();
            assert_eq!(consumed, wire.len(), "prefix {prefix}");
            assert_eq!(framebuffer.pixels(), bgras(&colours), "prefix {prefix}");
        }
    }

    #[test]
    fn tight_persistent_stream_resumes_after_incomplete() {
        let mut framebuffer = Framebuffer::new(4, 2);
        let mut decoder = Decoder::new();
        let mut encoder = TightEncoder::new();
        let first = encoder.chunk(
            &[red(), green(), blue(), white()]
                .iter()
                .flat_map(|c| rgb(*c))
                .collect::<Vec<_>>(),
        );
        let second = encoder.chunk(
            &[green(), red(), white(), blue()]
                .iter()
                .flat_map(|c| rgb(*c))
                .collect::<Vec<_>>(),
        );
        let first_wire = tight_wire(0, None, &first);
        let second_wire = tight_wire(0, None, &second);

        decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, 2, 2),
                Encoding::Tight,
                &first_wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();

        let truncated = &second_wire[..second_wire.len() - 1];
        let error = decoder
            .decode(
                &mut framebuffer,
                rect(2, 0, 2, 2),
                Encoding::Tight,
                truncated,
                PixelFormat::bgra8888(),
            )
            .unwrap_err();
        assert_eq!(error, DecodeError::Incomplete);

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(2, 0, 2, 2),
                Encoding::Tight,
                &second_wire,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, second_wire.len());

        assert_eq!(&framebuffer.pixels()[0..8], &bgras(&[red(), green()]));
        assert_eq!(&framebuffer.pixels()[8..16], &bgras(&[green(), red()]));
        assert_eq!(&framebuffer.pixels()[16..24], &bgras(&[blue(), white()]));
        assert_eq!(&framebuffer.pixels()[24..32], &bgras(&[white(), blue()]));
    }

    fn patterned_payload(width: u16, height: u16, seed: u8) -> (Vec<u8>, Vec<[u8; 4]>) {
        let mut payload = Vec::new();
        let mut colours = Vec::new();
        for y in 0..height {
            for x in 0..width {
                let x = x as u32;
                let y = y as u32;
                let r = ((x * 7 + y * 13 + u32::from(seed)) & 0xff) as u8;
                let g = (((x * 3) ^ (y * 5)) & 0xff) as u8;
                let b = ((x * y + u32::from(seed) * 11) & 0xff) as u8;
                payload.extend_from_slice(&[r, g, b]);
                colours.push([b, g, r, 255]);
            }
        }
        (payload, colours)
    }

    #[test]
    fn tight_dense_and_large_rects_consume_exactly() {
        for (width, height) in [(1u16, 1u16), (3, 3), (48, 48)] {
            let mut framebuffer = Framebuffer::new(width * 2, height);
            let mut decoder = Decoder::new();
            let (first_payload, first_colours) = patterned_payload(width, height, 0);
            let (second_payload, second_colours) = patterned_payload(width, height, 61);
            let mut encoder = TightEncoder::new();
            let first = encoder.chunk(&first_payload);
            let second = encoder.chunk(&second_payload);
            let first_wire = tight_wire(0, None, &first);
            let second_wire = tight_wire(0, None, &second);
            let mut message = first_wire.clone();
            message.extend_from_slice(&second_wire);

            let consumed = decoder
                .decode(
                    &mut framebuffer,
                    rect(0, 0, width, height),
                    Encoding::Tight,
                    &message,
                    PixelFormat::bgra8888(),
                )
                .unwrap();
            assert_eq!(consumed, first_wire.len());
            let row_bytes = usize::from(width) * 4;
            let frame_stride = row_bytes * 2;
            let first_pixels = bgras(&first_colours);
            let second_pixels = bgras(&second_colours);
            for row in 0..usize::from(height) {
                let start = row * frame_stride;
                let expected = row * row_bytes;
                assert_eq!(
                    &framebuffer.pixels()[start..start + row_bytes],
                    &first_pixels[expected..expected + row_bytes]
                );
            }

            let consumed = decoder
                .decode(
                    &mut framebuffer,
                    rect(width, 0, width, height),
                    Encoding::Tight,
                    &message[consumed..],
                    PixelFormat::bgra8888(),
                )
                .unwrap();
            assert_eq!(consumed, second_wire.len());

            for row in 0..usize::from(height) {
                let start = row * frame_stride;
                let expected = row * row_bytes;
                assert_eq!(
                    &framebuffer.pixels()[start..start + row_bytes],
                    &first_pixels[expected..expected + row_bytes]
                );
                assert_eq!(
                    &framebuffer.pixels()[start + row_bytes..start + row_bytes * 2],
                    &second_pixels[expected..expected + row_bytes]
                );
            }
        }
    }

    #[test]
    fn tight_highly_compressible_rects_consume_exactly() {
        let width = 256u16;
        let height = 32u16;
        let mut framebuffer = Framebuffer::new(width, height * 2);
        let mut decoder = Decoder::new();
        let mut payload = Vec::new();
        for _ in 0..usize::from(width) * usize::from(height) {
            payload.extend_from_slice(&rgb(blue()));
        }
        let mut encoder = TightEncoder::new();
        let first = encoder.chunk(&payload);
        let second = encoder.chunk(
            &[rgb(blue()), rgb(red())]
                .repeat(usize::from(width) * usize::from(height) / 2)
                .into_iter()
                .flatten()
                .collect::<Vec<_>>(),
        );
        let first_wire = tight_wire(0, None, &first);
        let second_wire = tight_wire(0, None, &second);
        let mut message = first_wire.clone();
        message.extend_from_slice(&second_wire);

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, 0, width, height),
                Encoding::Tight,
                &message,
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, first_wire.len());
        for row in 0..usize::from(height) {
            let start = row * usize::from(width) * 4;
            let end = start + usize::from(width) * 4;
            assert!(
                framebuffer.pixels()[start..end]
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .all(|pixel| *pixel == blue())
            );
        }

        let consumed = decoder
            .decode(
                &mut framebuffer,
                rect(0, height, width, height),
                Encoding::Tight,
                &message[consumed..],
                PixelFormat::bgra8888(),
            )
            .unwrap();
        assert_eq!(consumed, second_wire.len());
        for row in 0..usize::from(height) {
            let start = (usize::from(height) + row) * usize::from(width) * 4;
            for column in 0..usize::from(width) {
                let pixel = &framebuffer.pixels()[start + column * 4..start + column * 4 + 4];
                let expected = if column % 2 == 0 { blue() } else { red() };
                assert_eq!(pixel, expected);
            }
        }
    }
}
