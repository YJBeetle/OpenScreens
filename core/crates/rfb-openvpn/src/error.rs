//! Errors for OpenVPN configuration, protocol and runtime.
//!
//! Messages never contain key material or inline configuration values.

use std::io;

use thiserror::Error;

/// A problem with an `.ovpn` client profile.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// A line could not be understood.
    #[error("line {line}: {detail}")]
    Syntax {
        /// One-based line number.
        line: usize,
        /// Explanation that does not echo the line.
        detail: String,
    },
    /// A mandatory option or inline block is absent.
    #[error("{0} is required")]
    Missing(&'static str),
    /// A recognised option is outside the supported profile.
    #[error("unsupported: {0}")]
    Unsupported(String),
    /// A value could not be parsed.
    #[error("invalid {directive}: {detail}")]
    Invalid {
        /// Lower-case directive name.
        directive: &'static str,
        /// Explanation that does not echo the rejected value.
        detail: String,
    },
    /// Two options cannot be active at the same time.
    #[error("conflicting options: {0}")]
    Conflict(String),
    /// A referenced file could not be read.
    #[error("could not read {path}: {source}")]
    Io {
        /// Path as written in the profile.
        path: String,
        /// Underlying error.
        #[source]
        source: io::Error,
    },
}

/// A protocol or runtime failure.
#[derive(Debug, Error)]
pub enum TunnelError {
    /// Invalid configuration.
    #[error("invalid OpenVPN configuration: {0}")]
    Config(#[from] ConfigError),
    /// Outer socket or channel failure.
    #[error("OpenVPN I/O failed: {0}")]
    Io(#[from] io::Error),
    /// The tunnel was stopped, or its driver task is gone.
    #[error("tunnel is stopped")]
    Stopped,
    /// The control channel, TLS session or key exchange failed.
    #[error("OpenVPN handshake failed: {0}")]
    Handshake(String),
    /// A TLS record or certificate was rejected.
    #[error("OpenVPN TLS failed: {0}")]
    Tls(String),
    /// A peer packet was malformed or replayed.
    #[error("OpenVPN protocol error: {0}")]
    Protocol(String),
    /// The profile asks for a feature this crate does not implement.
    #[error("unsupported: {0}")]
    Unsupported(String),
    /// The destination is outside the routes pushed by the server.
    #[error("no pushed route for {host}:{port}")]
    NoRoute {
        /// Host name or address as requested.
        host: String,
        /// Destination port.
        port: u16,
    },
    /// A host name could not be resolved.
    #[error("could not resolve {host}: {detail}")]
    Resolve {
        /// Host name as requested.
        host: String,
        /// Underlying resolver message.
        detail: String,
    },
    /// The TCP connection could not be established.
    #[error("could not connect to {host}:{port}: {detail}")]
    Connect {
        /// Host name or address as requested.
        host: String,
        /// Destination port.
        port: u16,
        /// Reason reported by the driver.
        detail: String,
    },
    /// The TCP connection was not established within the timeout.
    #[error("timed out connecting to {host}:{port}")]
    ConnectTimeout {
        /// Host name or address as requested.
        host: String,
        /// Destination port.
        port: u16,
    },
}
