//! Userspace WireGuard for the RFB client.
//!
//! The tunnel exists entirely inside the process: `boringtun` implements the
//! WireGuard protocol, an in-memory [`device::QueueDevice`] stands in for a TUN
//! interface, and `smoltcp` provides TCP and DNS on top of it. The only
//! operating system resource is an ordinary UDP socket to the peer endpoint,
//! so no VPN permission, system profile or virtual interface is involved.
//!
//! ```no_run
//! # async fn run() -> Result<(), rfb_tunnel::TunnelError> {
//! use rfb_tunnel::{Tunnel, TunnelOptions, WireGuardConfig};
//!
//! let parsed = WireGuardConfig::parse(
//!     "[Interface]\nPrivateKey = <base64>\nAddress = 10.66.66.2/24\n\
//!      [Peer]\nPublicKey = <base64>\nAllowedIPs = 10.66.66.0/24\n",
//! )?;
//! let tunnel = Tunnel::start(parsed.config, parsed.private_key, TunnelOptions::default()).await?;
//! let mut stream = tunnel.connect_tcp("10.66.66.1", 5900).await?;
//! # let _ = &mut stream;
//! # Ok(())
//! # }
//! ```
//!
//! [`Tunnel::connect_tcp`] returns a [`TunnelStream`] that is a normal
//! `AsyncRead + AsyncWrite`, so it can be handed to the RFB or SSH engines
//! unchanged.

pub mod config;
pub mod device;
pub mod dns;
pub mod error;
pub mod keys;
mod noise;
pub mod stack;
pub mod stream;

pub use config::{
    Endpoint, EndpointHost, InterfaceConfig, MAX_MTU, MIN_MTU, ParsedConfig, PeerConfig,
    WireGuardConfig, default_mtu,
};
pub use device::QueueDevice;
pub use error::{ConfigError, KeyError, TunnelError};
pub use keys::{KeyPair, PresharedKey, PrivateKey, PublicKey};
pub use stack::{Link, Tunnel, TunnelOptions, TunnelState, TunnelStatus};
pub use stream::TunnelStream;
