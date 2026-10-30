//! Sans-I/O primitives for the RFB (VNC) protocol.
//!
//! This crate contains no networking or rendering code. It parses and encodes
//! wire messages so that transports and frontends stay thin.

pub mod encoding;
pub mod messages;
pub mod pixel_format;
pub mod security;
pub mod server_init;
pub mod version;

use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    UnexpectedEof,
    InvalidVersion,
    InvalidPixelFormat,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::UnexpectedEof => "unexpected end of input",
            Self::InvalidVersion => "invalid RFB protocol version",
            Self::InvalidPixelFormat => "invalid RFB pixel format",
        };
        f.write_str(message)
    }
}

impl std::error::Error for Error {}
