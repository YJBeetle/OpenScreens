//! Transports for the RFB protocol.

pub mod ssh;
pub mod tcp;

pub use ssh::{
    GeneratedSshKey, HostKeyPolicy, SshAuth, SshConfig, SshError, connect_ssh, fingerprint_sha256,
    generate_ssh_key, ssh_private_key_fingerprint, ssh_public_key_from_private,
};
pub use tcp::{BoxedTransport, Transport, connect_tcp};
