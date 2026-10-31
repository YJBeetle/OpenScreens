//! Userspace OpenVPN transport for the RFB client.
//!
//! This crate is a clean-room OpenVPN client for the profile described in
//! [`SUPPORTED_PROFILE`]. It uses `rustls` for the control-channel TLS
//! session, implements the OpenVPN reliable control channel and data-channel
//! AEAD framing, and routes inner IPv4 TCP through `smoltcp`. No operating
//! system VPN interface, VPN permission or system OpenVPN installation is
//! involved.
//!
//! ```no_run
//! # async fn run() -> Result<(), rfb_openvpn::TunnelError> {
//! use rfb_openvpn::{OvpnConfig, Tunnel, TunnelOptions};
//!
//! let profile = OvpnConfig::parse_file(std::path::Path::new("client.ovpn"))?;
//! let tunnel = Tunnel::connect(profile, TunnelOptions::default()).await?;
//! let mut stream = tunnel.connect_tcp("10.24.11.1", 5900).await?;
//! # let _ = &mut stream;
//! # Ok(())
//! # }
//! ```
//!
//! [`Tunnel::connect_tcp`] returns an [`OpenVpnStream`] that is a normal
//! `AsyncRead + AsyncWrite`, so it can be handed to the RFB or SSH engines
//! unchanged.

pub mod cipher;
pub mod config;
mod control;
mod data;
mod device;
pub mod error;
mod keys;
mod push;
mod stack;
mod static_key;
pub mod stream;
mod tls;
mod tunnel;

pub use cipher::{AuthDigest, Cipher};
pub use config::{
    LoadedMaterial, Material, OvpnConfig, Proto, Remote, RemoteCertTls, TlsWrapConfig, TlsWrapMode,
};
pub use error::{ConfigError, TunnelError};
pub use stream::OpenVpnStream;
pub use tunnel::{PushInfo, PushedRoute, Tunnel, TunnelOptions, TunnelState, TunnelStatus};

/// The exact client profile this version accepts.
pub const SUPPORTED_PROFILE: &str = "\
- .ovpn client profile with `client`, `dev tun`, one `remote host [port]`\n\
- transport `proto udp|udp4|tcp|tcp-client` (TCP gets the 2-byte length framing)\n\
- PKI authentication: `ca`, `cert`, `key` as paths or inline blocks, with\n\
  `remote-cert-tls server` (chain and server EKU are always verified; the\n\
  certificate host name is not checked, matching OpenVPN's default)\n\
- optional `tls-auth` (direction 0/1 or bidirectional) or `tls-crypt` v1\n\
- data ciphers AES-256-GCM, AES-192-GCM, AES-128-GCM, CHACHA20-POLY1305\n\
- Key method 2 and PUSH_REQUEST/PUSH_REPLY, IPv4 tun and TCP only\n\
\n\
Explicitly unsupported: username/password authentication, tls-crypt-v2,\n\
CBC/CFB/OFB ciphers, compression (comp-lzo/compress), tap, IPv6, proxies,\n\
fragment, route-nopull/pull-filter, PKCS#12 and configuration scripts.";
