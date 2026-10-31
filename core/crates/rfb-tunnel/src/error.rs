//! Errors for tunnel configuration, keys and runtime.
//!
//! Error messages never contain key material or raw configuration values.

use std::io;

use thiserror::Error;

/// A problem with a wg-quick style configuration.
#[derive(Debug, Error)]
pub enum ConfigError {
    /// The mandatory `[Interface]` section is absent.
    #[error("missing [{0}] section")]
    MissingSection(&'static str),
    /// A mandatory key inside a section is absent.
    #[error("{0} is required")]
    MissingField(&'static str),
    /// A section was declared more than once.
    #[error("duplicate [{0}] section")]
    DuplicateSection(&'static str),
    /// A value could not be parsed. The message names the field only, never its value.
    #[error("invalid value for {field}: {detail}")]
    InvalidValue {
        /// Field name, for example `MTU` or `Endpoint`.
        field: &'static str,
        /// Explanation that does not echo the rejected value.
        detail: String,
    },
    /// A key was not 32 bytes of standard base64.
    #[error("{0} is not a valid WireGuard key")]
    InvalidKey(&'static str),
    /// A line is not `key = value`.
    #[error("syntax error on line {0}")]
    Syntax(usize),
}

/// A malformed or missing key.
#[derive(Debug, Error)]
pub enum KeyError {
    /// The text was not 44 base64 characters (32 bytes plus padding).
    #[error("expected a 44 character base64 key, got a {actual} character string")]
    InvalidLength {
        /// Number of characters supplied.
        actual: usize,
    },
    /// The text was not standard base64.
    #[error("key is not valid base64")]
    InvalidBase64,
}

/// Runtime failures of a [`crate::Tunnel`].
#[derive(Debug, Error)]
pub enum TunnelError {
    /// Invalid configuration.
    #[error("invalid WireGuard configuration: {0}")]
    Config(#[from] ConfigError),
    /// Invalid key material.
    #[error("invalid key: {0}")]
    Key(#[from] KeyError),
    /// Socket or channel I/O failure.
    #[error("tunnel I/O failed: {0}")]
    Io(#[from] io::Error),
    /// The tunnel was stopped, or its driver task is gone.
    #[error("tunnel is stopped")]
    Stopped,
    /// No peer route covers the destination.
    #[error("no peer route for {host}:{port}")]
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
    /// The feature is recognised but not implemented in this version.
    #[error("unsupported: {0}")]
    Unsupported(String),
}
