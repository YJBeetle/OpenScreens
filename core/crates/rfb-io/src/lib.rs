//! Transports for the RFB protocol.

pub mod tcp;

pub use tcp::{BoxedTransport, Transport, connect_tcp};
