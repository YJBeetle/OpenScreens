//! RFB PIXELFORMAT structure (RFC 6143 section 7.4).

use crate::Error;

pub const PIXEL_FORMAT_LEN: usize = 16;

/// Pixel layout of the framebuffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct PixelFormat {
    pub bits_per_pixel: u8,
    pub depth: u8,
    pub big_endian: bool,
    pub true_colour: bool,
    pub red_max: u16,
    pub green_max: u16,
    pub blue_max: u16,
    pub red_shift: u8,
    pub green_shift: u8,
    pub blue_shift: u8,
}

impl PixelFormat {
    /// 32 bpp little-endian BGRA: blue in the low byte, then green, red, alpha.
    /// This matches iOS and Android surface layouts.
    pub const fn bgra8888() -> Self {
        Self {
            bits_per_pixel: 32,
            depth: 24,
            big_endian: false,
            true_colour: true,
            red_max: 255,
            green_max: 255,
            blue_max: 255,
            red_shift: 16,
            green_shift: 8,
            blue_shift: 0,
        }
    }

    /// 32 bpp little-endian RGBA: red in the low byte, then green, blue, alpha.
    pub const fn rgba8888() -> Self {
        Self {
            bits_per_pixel: 32,
            depth: 24,
            big_endian: false,
            true_colour: true,
            red_max: 255,
            green_max: 255,
            blue_max: 255,
            red_shift: 0,
            green_shift: 8,
            blue_shift: 16,
        }
    }

    /// 16 bpp RGB565, the usual bandwidth-saving format.
    pub const fn rgb565() -> Self {
        Self {
            bits_per_pixel: 16,
            depth: 16,
            big_endian: false,
            true_colour: true,
            red_max: 31,
            green_max: 63,
            blue_max: 31,
            red_shift: 11,
            green_shift: 5,
            blue_shift: 0,
        }
    }

    pub fn parse(bytes: &[u8]) -> Result<Self, Error> {
        if bytes.len() < PIXEL_FORMAT_LEN {
            return Err(Error::UnexpectedEof);
        }
        let bits_per_pixel = bytes[0];
        let depth = bytes[1];
        if !matches!(bits_per_pixel, 8 | 16 | 32) || depth == 0 || depth > bits_per_pixel {
            return Err(Error::InvalidPixelFormat);
        }
        Ok(Self {
            bits_per_pixel,
            depth,
            big_endian: bytes[2] != 0,
            true_colour: bytes[3] != 0,
            red_max: u16::from_be_bytes([bytes[4], bytes[5]]),
            green_max: u16::from_be_bytes([bytes[6], bytes[7]]),
            blue_max: u16::from_be_bytes([bytes[8], bytes[9]]),
            red_shift: bytes[10],
            green_shift: bytes[11],
            blue_shift: bytes[12],
        })
    }

    pub fn encode(self) -> [u8; PIXEL_FORMAT_LEN] {
        let mut out = [0u8; PIXEL_FORMAT_LEN];
        out[0] = self.bits_per_pixel;
        out[1] = self.depth;
        out[2] = u8::from(self.big_endian);
        out[3] = u8::from(self.true_colour);
        out[4..6].copy_from_slice(&self.red_max.to_be_bytes());
        out[6..8].copy_from_slice(&self.green_max.to_be_bytes());
        out[8..10].copy_from_slice(&self.blue_max.to_be_bytes());
        out[10] = self.red_shift;
        out[11] = self.green_shift;
        out[12] = self.blue_shift;
        out
    }

    pub const fn bytes_per_pixel(self) -> usize {
        self.bits_per_pixel as usize / 8
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_presets() {
        for format in [
            PixelFormat::bgra8888(),
            PixelFormat::rgba8888(),
            PixelFormat::rgb565(),
        ] {
            assert_eq!(PixelFormat::parse(&format.encode()).unwrap(), format);
        }
    }

    #[test]
    fn encodes_bgra_layout() {
        assert_eq!(
            PixelFormat::bgra8888().encode(),
            [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        );
    }

    #[test]
    fn parses_server_default_layout() {
        let parsed =
            PixelFormat::parse(&[32, 24, 1, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]).unwrap();
        assert_eq!(
            parsed,
            PixelFormat {
                big_endian: true,
                ..PixelFormat::bgra8888()
            }
        );
        assert_eq!(parsed.bytes_per_pixel(), 4);
    }

    #[test]
    fn rejects_invalid_formats() {
        assert_eq!(
            PixelFormat::parse(&[24, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                .unwrap_err(),
            Error::InvalidPixelFormat
        );
        assert_eq!(
            PixelFormat::parse(&[32, 0, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                .unwrap_err(),
            Error::InvalidPixelFormat
        );
        assert_eq!(
            PixelFormat::parse(&[32, 33, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
                .unwrap_err(),
            Error::InvalidPixelFormat
        );
        assert_eq!(
            PixelFormat::parse(&[0; 8]).unwrap_err(),
            Error::UnexpectedEof
        );
    }
}
