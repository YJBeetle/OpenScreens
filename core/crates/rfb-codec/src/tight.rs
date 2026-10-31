//! Tight encoding (encoding 7).
//!
//! The decoder keeps four persistent zlib streams across rectangles, as
//! required by the encoding. Compressed payloads carry no length prefix, so
//! the end of a payload is found by inflating exactly the number of bytes the
//! filter needs and then consuming the `Z_SYNC_FLUSH` marker that terminates
//! the compressed block. Bytes belonging to the next rectangle are never fed
//! to the zlib stream or counted as consumed.

use std::io::Cursor as IoCursor;

use flate2::{Decompress, FlushDecompress, Status};
use rfb_proto::pixel_format::PixelFormat;
use zune_jpeg::JpegDecoder;

use crate::pixel::{Cursor, color_to_bgra};
use crate::{DecodeError, Framebuffer, Rect};

/// End of the empty stored block written by `Z_SYNC_FLUSH`.
const FLUSH_MARKER: [u8; 4] = [0x00, 0x00, 0xff, 0xff];
/// At most this many bytes (end-of-block bits and stored-block header) can
/// precede the flush marker once the expected output has been produced.
const MARKER_PREFIX: usize = 3;
/// Bytes inspected when looking for the flush marker after the last output.
const TAIL_WINDOW: usize = MARKER_PREFIX + FLUSH_MARKER.len();
/// Upper bound for one zlib output slice. Larger outputs simply take more
/// calls.
const MAX_OUTPUT_CHUNK: usize = 64 * 1024;
/// Scratch space for draining the flush marker; no output may be produced.
const TAIL_OUTPUT: usize = 16;

const FILTER_COPY: u8 = 0;
const FILTER_PALETTE: u8 = 1;
const FILTER_GRADIENT: u8 = 2;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Filter {
    Copy,
    Palette,
}

/// Progress of the rectangle currently being decompressed.
struct Pending {
    rect: Rect,
    pixel_format: PixelFormat,
    stream: usize,
    filter: Filter,
    /// Offset of the next input byte to parse in the caller's buffer. All
    /// bytes before this offset have been consumed by the zlib stream or by
    /// the control-byte parser.
    offset: usize,
    /// Decompressed filter payload (TPIXELs, or palette + packed indices).
    output: Vec<u8>,
    /// The zlib stream signalled `Z_STREAM_END`, so no flush marker follows.
    ended: bool,
}

pub(crate) struct TightDecoder {
    streams: [Decompress; 4],
    pending: Option<Pending>,
    zlib_out: Vec<u8>,
    bgra: Vec<u8>,
}

impl TightDecoder {
    pub(crate) fn new() -> Self {
        Self {
            streams: [
                Decompress::new(true),
                Decompress::new(true),
                Decompress::new(true),
                Decompress::new(true),
            ],
            pending: None,
            zlib_out: vec![0; MAX_OUTPUT_CHUNK],
            bgra: Vec::new(),
        }
    }

    pub(crate) fn decode(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        data: &[u8],
        pixel_format: PixelFormat,
    ) -> Result<usize, DecodeError> {
        if let Some(pending) = &self.pending {
            if pending.rect != rect || pending.pixel_format != pixel_format {
                // The caller moved on to another rectangle; drop stale
                // progress. The zlib streams themselves stay persistent.
                self.pending = None;
            } else {
                return self.resume(framebuffer, data);
            }
        }
        self.begin(framebuffer, rect, data, pixel_format)
    }

    /// Parses the compression control byte, then either completes a
    /// self-contained subencoding or starts a Basic rect. The low nibble of
    /// the control byte resets the corresponding zlib streams; there is no
    /// separate reset prefix.
    fn begin(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        data: &[u8],
        pixel_format: PixelFormat,
    ) -> Result<usize, DecodeError> {
        let control = *data.first().ok_or(DecodeError::Incomplete)?;
        let resets = control & 0x0f;
        let mut position = 1usize;

        match control >> 4 {
            0x8 => {
                // Fill: one TPIXEL in the compressed rectangle's colour format.
                let size = tpixel_size(pixel_format);
                if size == 0 {
                    return Err(DecodeError::InvalidData("tight pixel size"));
                }
                let raw = data
                    .get(position..position + size)
                    .ok_or(DecodeError::Incomplete)?;
                let colour = read_tpixel(&mut Cursor::new(raw), pixel_format)?;
                self.apply_resets(resets);
                fill_bgra(framebuffer, rect, colour);
                Ok(position + size)
            }
            0x9 => {
                // JPEG: compact length followed by the JPEG byte stream.
                let (length, header) = read_compact(data.get(position..).unwrap_or(&[]))?;
                let start = position + header;
                let end = start
                    .checked_add(length)
                    .ok_or(DecodeError::InvalidData("tight JPEG length"))?;
                let jpeg = data.get(start..end).ok_or(DecodeError::Incomplete)?;
                self.apply_resets(resets);
                self.decode_jpeg(framebuffer, rect, jpeg)?;
                Ok(end)
            }
            0x0..=0x7 => {
                let stream = usize::from((control >> 4) & 0x03);
                let mut filter = Filter::Copy;
                if control & 0x40 != 0 {
                    let id = *data.get(position).ok_or(DecodeError::Incomplete)?;
                    position += 1;
                    filter = match id & 0x0f {
                        FILTER_COPY => Filter::Copy,
                        FILTER_PALETTE => Filter::Palette,
                        FILTER_GRADIENT => {
                            return Err(DecodeError::InvalidData("tight gradient filter"));
                        }
                        _ => return Err(DecodeError::InvalidData("tight filter")),
                    };
                }
                if tpixel_size(pixel_format) == 0 {
                    return Err(DecodeError::InvalidData("tight pixel size"));
                }
                self.apply_resets(resets);
                self.pending = Some(Pending {
                    rect,
                    pixel_format,
                    stream,
                    filter,
                    offset: position,
                    output: Vec::new(),
                    ended: false,
                });
                self.resume(framebuffer, data)
            }
            _ => Err(DecodeError::InvalidData("tight compression type")),
        }
    }

    fn resume(&mut self, framebuffer: &mut Framebuffer, data: &[u8]) -> Result<usize, DecodeError> {
        let mut pending = match self.pending.take() {
            Some(pending) => pending,
            None => return Err(DecodeError::Incomplete),
        };
        match self.drive(&mut pending, framebuffer, data) {
            Ok(()) => Ok(pending.offset),
            Err(DecodeError::Incomplete) => {
                self.pending = Some(pending);
                Err(DecodeError::Incomplete)
            }
            Err(error) => Err(error),
        }
    }

    fn drive(
        &mut self,
        pending: &mut Pending,
        framebuffer: &mut Framebuffer,
        data: &[u8],
    ) -> Result<(), DecodeError> {
        self.pump(pending, data)?;
        if !pending.ended {
            self.finish_stream(pending, data)?;
        }
        self.render(pending, framebuffer)
    }

    fn apply_resets(&mut self, resets: u8) {
        for (index, stream) in self.streams.iter_mut().enumerate() {
            if resets & (1 << index) != 0 {
                stream.reset(true);
            }
        }
    }

    /// Inflates until the filter has produced `target` bytes.
    ///
    /// Input is fed one byte at a time. The decompressor reads ahead (flate2's
    /// miniz backend may decode up to a 32 KiB dictionary beyond the requested
    /// output), so larger input slices could swallow the flush marker and even
    /// bytes of the next rectangle. One byte per call guarantees that the call
    /// which produces the final output byte consumes at most that byte itself;
    /// the flush marker is then located and drained explicitly.
    fn pump(&mut self, pending: &mut Pending, data: &[u8]) -> Result<(), DecodeError> {
        loop {
            let target = pending.target()?;
            if pending.output.len() == target {
                return Ok(());
            }
            if pending.offset >= data.len() {
                return Err(DecodeError::Incomplete);
            }
            let limit = (target - pending.output.len()).min(MAX_OUTPUT_CHUNK);

            let stream = &mut self.streams[pending.stream];
            let before_in = stream.total_in();
            let before_out = stream.total_out();
            let status = stream
                .decompress(
                    &data[pending.offset..pending.offset + 1],
                    &mut self.zlib_out[..limit],
                    FlushDecompress::None,
                )
                .map_err(|_| DecodeError::InvalidData("tight zlib error"))?;
            let consumed = usize::try_from(stream.total_in() - before_in)
                .map_err(|_| DecodeError::InvalidData("tight zlib progress"))?;
            let written = usize::try_from(stream.total_out() - before_out)
                .map_err(|_| DecodeError::InvalidData("tight zlib progress"))?;
            if consumed > 1 || written > limit {
                return Err(DecodeError::InvalidData("tight zlib progress"));
            }

            pending.offset += consumed;
            pending.output.extend_from_slice(&self.zlib_out[..written]);

            if matches!(status, Status::StreamEnd) {
                if pending.output.len() < pending.target()? {
                    return Err(DecodeError::InvalidData("tight zlib stream ended"));
                }
                pending.ended = true;
            }

            if consumed == 0 && written == 0 {
                return Err(DecodeError::InvalidData("tight zlib stalled"));
            }
        }
    }

    /// Consumes the flush marker that terminates a `Z_SYNC_FLUSH` block
    /// without touching the next rectangle's bytes.
    fn finish_stream(&mut self, pending: &mut Pending, data: &[u8]) -> Result<(), DecodeError> {
        let offset = pending.offset;
        let available = data
            .len()
            .checked_sub(offset)
            .ok_or(DecodeError::Incomplete)?;
        if available < FLUSH_MARKER.len() {
            return Err(DecodeError::Incomplete);
        }
        let last_start = MARKER_PREFIX.min(available - FLUSH_MARKER.len());
        let mut tail_len = None;
        for start in 0..=last_start {
            if data[offset + start..offset + start + FLUSH_MARKER.len()] == FLUSH_MARKER {
                tail_len = Some(start + FLUSH_MARKER.len());
                break;
            }
        }
        let tail_len = match tail_len {
            Some(length) => length,
            None if available < TAIL_WINDOW => return Err(DecodeError::Incomplete),
            None => return Err(DecodeError::InvalidData("tight zlib sync marker")),
        };

        let stream = &mut self.streams[pending.stream];
        let before_in = stream.total_in();
        let before_out = stream.total_out();
        stream
            .decompress(
                &data[offset..offset + tail_len],
                &mut self.zlib_out[..TAIL_OUTPUT],
                FlushDecompress::None,
            )
            .map_err(|_| DecodeError::InvalidData("tight zlib error"))?;
        let consumed = usize::try_from(stream.total_in() - before_in)
            .map_err(|_| DecodeError::InvalidData("tight zlib progress"))?;
        let written = usize::try_from(stream.total_out() - before_out)
            .map_err(|_| DecodeError::InvalidData("tight zlib progress"))?;
        if consumed != tail_len || written != 0 {
            return Err(DecodeError::InvalidData("tight zlib trailing data"));
        }
        pending.offset += tail_len;
        Ok(())
    }

    fn render(
        &mut self,
        pending: &Pending,
        framebuffer: &mut Framebuffer,
    ) -> Result<(), DecodeError> {
        let width = usize::from(pending.rect.width);
        let height = usize::from(pending.rect.height);
        let pixels = width * height;
        self.bgra.clear();
        self.bgra.resize(pixels * 4, 0);

        match pending.filter {
            Filter::Copy => {
                let mut cursor = Cursor::new(&pending.output);
                let mut offset = 0;
                for _ in 0..pixels {
                    let colour = read_tpixel(&mut cursor, pending.pixel_format)
                        .map_err(|_| DecodeError::InvalidData("tight payload truncated"))?;
                    self.bgra[offset..offset + 4].copy_from_slice(&colour);
                    offset += 4;
                }
            }
            Filter::Palette => {
                self.render_palette(pending, width, height)?;
            }
        }

        blit(framebuffer, pending.rect, &self.bgra);
        Ok(())
    }

    fn render_palette(
        &mut self,
        pending: &Pending,
        width: usize,
        height: usize,
    ) -> Result<(), DecodeError> {
        let output = &pending.output;
        let size = output.first().copied().unwrap_or(0);
        if size == 0 {
            return Err(DecodeError::InvalidData("tight palette size"));
        }
        let size = usize::from(size);
        let tpixel = tpixel_size(pending.pixel_format);
        let palette_end = 1 + size * tpixel;
        let mut cursor = Cursor::new(output.get(1..palette_end).unwrap_or(&[]));
        let mut palette = Vec::with_capacity(size);
        for _ in 0..size {
            palette.push(
                read_tpixel(&mut cursor, pending.pixel_format)
                    .map_err(|_| DecodeError::InvalidData("tight payload truncated"))?,
            );
        }

        let bits = bits_per_index(size);
        let row_bytes = (width * bits).div_ceil(8);
        let mask = if bits == 8 { 0xff } else { (1u8 << bits) - 1 };
        for row in 0..height {
            let start = palette_end + row * row_bytes;
            let packed = output
                .get(start..start + row_bytes)
                .ok_or(DecodeError::InvalidData("tight payload truncated"))?;
            for column in 0..width {
                let bit_index = column * bits;
                let byte = packed[bit_index / 8];
                let shift = 8 - bits - (bit_index % 8);
                let index = usize::from((byte >> shift) & mask);
                let colour = *palette
                    .get(index)
                    .ok_or(DecodeError::InvalidData("tight palette index"))?;
                let offset = (row * width + column) * 4;
                self.bgra[offset..offset + 4].copy_from_slice(&colour);
            }
        }
        Ok(())
    }

    fn decode_jpeg(
        &mut self,
        framebuffer: &mut Framebuffer,
        rect: Rect,
        jpeg: &[u8],
    ) -> Result<(), DecodeError> {
        let mut decoder = JpegDecoder::new(IoCursor::new(jpeg));
        let rgb = decoder
            .decode()
            .map_err(|_| DecodeError::InvalidData("tight JPEG decode"))?;
        let info = decoder
            .info()
            .ok_or(DecodeError::InvalidData("tight JPEG decode"))?;
        let width = usize::from(rect.width);
        let height = usize::from(rect.height);
        if usize::from(info.width) != width || usize::from(info.height) != height {
            return Err(DecodeError::InvalidData("tight JPEG dimensions"));
        }

        let pixels = width * height;
        self.bgra.clear();
        self.bgra.resize(pixels * 4, 0);
        match rgb.len() {
            length if length == pixels * 3 => {
                for (pixel, rgb) in self
                    .bgra
                    .as_chunks_mut::<4>()
                    .0
                    .iter_mut()
                    .zip(rgb.as_chunks::<3>().0.iter())
                {
                    pixel.copy_from_slice(&[rgb[2], rgb[1], rgb[0], 255]);
                }
            }
            length if length == pixels => {
                for (pixel, &luma) in self.bgra.as_chunks_mut::<4>().0.iter_mut().zip(rgb.iter()) {
                    pixel.copy_from_slice(&[luma, luma, luma, 255]);
                }
            }
            _ => return Err(DecodeError::InvalidData("tight JPEG pixel format")),
        }

        blit(framebuffer, rect, &self.bgra);
        Ok(())
    }
}

impl Pending {
    /// Number of decompressed bytes this filter still needs.
    fn target(&self) -> Result<usize, DecodeError> {
        let width = usize::from(self.rect.width);
        let height = usize::from(self.rect.height);
        let tpixel = tpixel_size(self.pixel_format);
        let pixels = width
            .checked_mul(height)
            .ok_or(DecodeError::InvalidData("tight rectangle too large"))?;
        match self.filter {
            Filter::Copy => pixels
                .checked_mul(tpixel)
                .ok_or(DecodeError::InvalidData("tight rectangle too large")),
            Filter::Palette => {
                let size = match self.output.first() {
                    Some(&size) if size != 0 => usize::from(size),
                    Some(_) => return Err(DecodeError::InvalidData("tight palette size")),
                    None => return Ok(1),
                };
                let bits = bits_per_index(size);
                let row_bytes = width
                    .checked_mul(bits)
                    .ok_or(DecodeError::InvalidData("tight rectangle too large"))?
                    .div_ceil(8);
                let indices = row_bytes
                    .checked_mul(height)
                    .ok_or(DecodeError::InvalidData("tight rectangle too large"))?;
                let palette = size
                    .checked_mul(tpixel)
                    .ok_or(DecodeError::InvalidData("tight rectangle too large"))?;
                1usize
                    .checked_add(palette)
                    .and_then(|value| value.checked_add(indices))
                    .ok_or(DecodeError::InvalidData("tight rectangle too large"))
            }
        }
    }
}

/// True when TPIXELs are three bytes in R, G, B order rather than a PIXEL in
/// the negotiated format.
fn is_rgb888(format: PixelFormat) -> bool {
    format.bits_per_pixel == 32
        && format.depth <= 24
        && format.true_colour
        && format.red_max == 255
        && format.green_max == 255
        && format.blue_max == 255
}

fn tpixel_size(format: PixelFormat) -> usize {
    if is_rgb888(format) {
        3
    } else {
        format.bytes_per_pixel()
    }
}

fn bits_per_index(size: usize) -> usize {
    match size {
        1..=2 => 1,
        3..=4 => 2,
        5..=16 => 4,
        _ => 8,
    }
}

fn read_tpixel(cursor: &mut Cursor<'_>, format: PixelFormat) -> Result<[u8; 4], DecodeError> {
    if is_rgb888(format) {
        let rgb = cursor.take(3)?;
        Ok([rgb[2], rgb[1], rgb[0], 255])
    } else {
        let value = cursor.pixel(format)?;
        color_to_bgra(value, format)
    }
}

fn read_compact(data: &[u8]) -> Result<(usize, usize), DecodeError> {
    let first = *data.first().ok_or(DecodeError::Incomplete)?;
    let mut length = usize::from(first & 0x7f);
    if first & 0x80 == 0 {
        return Ok((length, 1));
    }
    let second = *data.get(1).ok_or(DecodeError::Incomplete)?;
    length |= usize::from(second & 0x7f) << 7;
    if second & 0x80 == 0 {
        return Ok((length, 2));
    }
    let third = *data.get(2).ok_or(DecodeError::Incomplete)?;
    length |= usize::from(third) << 14;
    Ok((length, 3))
}

fn fill_bgra(framebuffer: &mut Framebuffer, rect: Rect, colour: [u8; 4]) {
    let stride = usize::from(framebuffer.width()) * 4;
    let row_bytes = usize::from(rect.width) * 4;
    let x = usize::from(rect.x);
    let y = usize::from(rect.y);
    for row in 0..usize::from(rect.height) {
        let start = (y + row) * stride + x * 4;
        for pixel in framebuffer.pixels_mut()[start..start + row_bytes]
            .as_chunks_mut::<4>()
            .0
        {
            pixel.copy_from_slice(&colour);
        }
    }
}

fn blit(framebuffer: &mut Framebuffer, rect: Rect, pixels: &[u8]) {
    let stride = usize::from(framebuffer.width()) * 4;
    let row_bytes = usize::from(rect.width) * 4;
    let x = usize::from(rect.x);
    let y = usize::from(rect.y);
    for row in 0..usize::from(rect.height) {
        let source = row * row_bytes;
        let destination = (y + row) * stride + x * 4;
        framebuffer.pixels_mut()[destination..destination + row_bytes]
            .copy_from_slice(&pixels[source..source + row_bytes]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_compact_lengths() {
        assert_eq!(read_compact(&[0x05]).unwrap(), (5, 1));
        assert_eq!(read_compact(&[0x80, 0x02]).unwrap(), (0x100, 2));
        assert_eq!(
            read_compact(&[0xff, 0x81, 0x03]).unwrap(),
            (0xff | 0x80 | (3 << 14), 3)
        );
        assert_eq!(read_compact(&[]).unwrap_err(), DecodeError::Incomplete);
        assert_eq!(read_compact(&[0x80]).unwrap_err(), DecodeError::Incomplete);
    }
}
