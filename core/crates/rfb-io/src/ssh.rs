//! SSH tunnelling for RFB connections.
//!
//! [`connect_ssh`] authenticates to a jump host and opens an RFC 4254
//! `direct-tcpip` channel to the RFB server. The returned stream is a plain
//! [`BoxedTransport`], so it can be handed to the RFB engine exactly like a
//! TCP connection.

use std::fmt;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::client;
use russh::keys::{PrivateKeyWithHashAlg, PublicKeyOrCertificate, load_secret_key};
use sha2::{Digest, Sha256};

use crate::tcp::BoxedTransport;

/// How to authenticate to the SSH jump host.
#[derive(Clone)]
pub enum SshAuth {
    /// Password authentication. The password is never included in errors or
    /// debug output.
    Password(String),
    /// Public-key authentication with an OpenSSH or PEM private key. The
    /// passphrase is optional and is never included in errors or debug output.
    PrivateKey {
        path: PathBuf,
        passphrase: Option<String>,
    },
}

impl fmt::Debug for SshAuth {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Password(_) => f.write_str("Password(<redacted>)"),
            Self::PrivateKey { path, passphrase } => f
                .debug_struct("PrivateKey")
                .field("path", path)
                .field("passphrase", &passphrase.as_ref().map(|_| "<redacted>"))
                .finish(),
        }
    }
}

/// How the SSH server's host key is validated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostKeyPolicy {
    /// Accept any host key. Intended for first-connect flows where the
    /// fingerprint is shown to the user and pinned afterwards.
    AcceptAny,
    /// Require the SHA-256 fingerprint of the server's public key blob to
    /// match the pinned value. Hex digits may be uppercase or lowercase and
    /// may be separated by colons; an optional `SHA256:` prefix is accepted.
    PinSha256(String),
}

/// Configuration for an SSH tunnel to an RFB server.
#[derive(Clone, Debug)]
pub struct SshConfig {
    /// SSH jump host.
    pub host: String,
    /// SSH port.
    pub port: u16,
    /// SSH username.
    pub username: String,
    /// Authentication method.
    pub auth: SshAuth,
    /// Host-key verification policy.
    pub host_key: HostKeyPolicy,
    /// VNC host as resolved from the SSH jump host.
    pub target_host: String,
    /// VNC port as resolved from the SSH jump host.
    pub target_port: u16,
}

/// Errors returned by [`connect_ssh`].
#[derive(Debug)]
pub enum SshError {
    /// Network I/O failed.
    Io(io::Error),
    /// The SSH transport, key exchange, or protocol failed.
    Ssh(russh::Error),
    /// The server rejected the configured credentials. Contains no secrets.
    Auth(String),
    /// The server's host key did not match the pinned SHA-256 fingerprint.
    HostKeyMismatch { expected: String, actual: String },
    /// The `direct-tcpip` channel could not be opened.
    Channel(String),
    /// The private key file could not be read or decrypted.
    KeyLoad(String),
}

impl fmt::Display for SshError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "SSH I/O error: {error}"),
            Self::Ssh(error) => write!(f, "SSH error: {error}"),
            Self::Auth(message) => write!(f, "SSH authentication failed: {message}"),
            Self::HostKeyMismatch { expected, actual } => write!(
                f,
                "SSH host key mismatch: expected SHA-256 {expected}, got {actual}"
            ),
            Self::Channel(message) => write!(f, "SSH channel error: {message}"),
            Self::KeyLoad(message) => write!(f, "SSH private key error: {message}"),
        }
    }
}

impl std::error::Error for SshError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Ssh(error) => Some(error),
            Self::Auth(_) | Self::HostKeyMismatch { .. } | Self::Channel(_) | Self::KeyLoad(_) => {
                None
            }
        }
    }
}

impl From<io::Error> for SshError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<russh::Error> for SshError {
    fn from(error: russh::Error) -> Self {
        match error {
            russh::Error::IO(error) => Self::Io(error),
            other => Self::Ssh(other),
        }
    }
}

/// Connects to a jump host and opens a `direct-tcpip` channel to the
/// configured VNC server.
///
/// The returned stream can be used for RFB immediately. Dropping it closes the
/// SSH channel and releases the underlying connection once no other channels
/// are open.
pub async fn connect_ssh(config: &SshConfig) -> Result<BoxedTransport, SshError> {
    let handler = ClientHandler {
        host_key: config.host_key.clone(),
    };
    let ssh_config = client::Config {
        nodelay: true,
        ..Default::default()
    };

    let mut handle = client::connect(
        Arc::new(ssh_config),
        (config.host.as_str(), config.port),
        handler,
    )
    .await?;

    match &config.auth {
        SshAuth::Password(password) => {
            let result = handle
                .authenticate_password(config.username.as_str(), password.as_str())
                .await?;
            if !result.success() {
                return Err(SshError::Auth(
                    "password authentication was rejected by the server".to_owned(),
                ));
            }
        }
        SshAuth::PrivateKey { path, passphrase } => {
            let key = load_private_key(path, passphrase.as_deref()).await?;
            let hash_alg = if key.algorithm().is_rsa() {
                handle.best_supported_rsa_hash().await?.flatten()
            } else {
                None
            };
            let key = PrivateKeyWithHashAlg::new(Arc::new(key), hash_alg);
            let result = handle
                .authenticate_publickey(config.username.as_str(), key)
                .await?;
            if !result.success() {
                return Err(SshError::Auth(
                    "public-key authentication was rejected by the server".to_owned(),
                ));
            }
        }
    }

    let channel = handle
        .channel_open_direct_tcpip(
            config.target_host.as_str(),
            u32::from(config.target_port),
            "127.0.0.1",
            0,
        )
        .await
        .map_err(|error| SshError::Channel(error.to_string()))?;

    Ok(Box::new(channel.into_stream()))
}

async fn load_private_key(
    path: &Path,
    passphrase: Option<&str>,
) -> Result<russh::keys::PrivateKey, SshError> {
    let path = path.to_path_buf();
    let passphrase = passphrase.map(str::to_owned);
    tokio::task::spawn_blocking(move || {
        load_secret_key(&path, passphrase.as_deref())
            .map_err(|error| SshError::KeyLoad(format!("{}: {error}", path.display())))
    })
    .await
    .map_err(|error| SshError::KeyLoad(format!("private key task failed: {error}")))?
}

struct ClientHandler {
    host_key: HostKeyPolicy,
}

impl client::Handler for ClientHandler {
    type Error = SshError;

    async fn check_server_key(
        &mut self,
        server_public_key: &PublicKeyOrCertificate,
    ) -> Result<bool, Self::Error> {
        let HostKeyPolicy::PinSha256(pinned) = &self.host_key else {
            return Ok(true);
        };

        let public_key = server_public_key.public_key();
        let blob = public_key
            .to_bytes()
            .map_err(|error| SshError::Ssh(russh::Error::from(error)))?;
        let actual = fingerprint_sha256(&blob);
        if fingerprints_match(pinned, &actual) {
            Ok(true)
        } else {
            Err(SshError::HostKeyMismatch {
                expected: pinned.clone(),
                actual,
            })
        }
    }
}

/// Formats the SHA-256 fingerprint of an SSH public key blob as lowercase,
/// colon-separated hex (`aa:bb:...`).
pub fn fingerprint_sha256(public_key_blob: &[u8]) -> String {
    const HEX: [u8; 16] = *b"0123456789abcdef";
    let digest = Sha256::digest(public_key_blob);
    let mut fingerprint = String::with_capacity(95);
    for (index, byte) in digest.iter().enumerate() {
        if index > 0 {
            fingerprint.push(':');
        }
        fingerprint.push(HEX[usize::from(byte >> 4)] as char);
        fingerprint.push(HEX[usize::from(byte & 0x0f)] as char);
    }
    fingerprint
}

fn fingerprints_match(pinned: &str, actual: &str) -> bool {
    matches!(
        (normalize_fingerprint(pinned), normalize_fingerprint(actual)),
        (Some(pinned), Some(actual)) if pinned == actual
    )
}

fn normalize_fingerprint(fingerprint: &str) -> Option<String> {
    let fingerprint = strip_sha256_prefix(fingerprint.trim());
    let mut normalized = String::with_capacity(64);
    for character in fingerprint.chars() {
        if character == ':' || character.is_ascii_whitespace() {
            continue;
        }
        if !character.is_ascii_hexdigit() {
            return None;
        }
        normalized.push(character.to_ascii_lowercase());
    }
    (normalized.len() == 64).then_some(normalized)
}

fn strip_sha256_prefix(fingerprint: &str) -> &str {
    match fingerprint.get(..7) {
        Some(prefix) if prefix.eq_ignore_ascii_case("sha256:") => {
            fingerprint.get(7..).unwrap_or_default()
        }
        _ => fingerprint,
    }
}

#[cfg(test)]
mod tests {
    use std::process;
    use std::time::Duration;

    use russh::keys::{Algorithm, PrivateKey, ssh_key::LineEnding};
    use russh::server::{Auth, ChannelOpenHandle, Msg, Server as _, Session, VerifiedPublicKey};
    use russh::{Channel, ChannelId, ChannelOpenFailure};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;

    const USER: &str = "openscreens";
    const PASSWORD: &str = "correct horse battery staple";
    const TARGET_HOST: &str = "vnc.internal";
    const TARGET_PORT: u16 = 5900;
    const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
    const IO_TIMEOUT: Duration = Duration::from_secs(5);

    #[test]
    fn sha256_fingerprint_is_formatted_as_colon_separated_hex() {
        // SHA-256 of the empty input.
        assert_eq!(
            fingerprint_sha256(b""),
            "e3:b0:c4:42:98:fc:1c:14:9a:fb:f4:c8:99:6f:b9:24:\
             27:ae:41:e4:64:9b:93:4c:a4:95:99:1b:78:52:b8:55"
        );
    }

    #[test]
    fn fingerprints_accept_colons_case_and_sha256_prefix() {
        let actual = fingerprint_sha256(b"host key blob");
        assert_eq!(actual.len(), 95);

        let plain = actual.replace(':', "");
        let upper = actual.to_uppercase();
        let upper_without_colons = plain.to_uppercase();
        let prefixed = format!("SHA256:{upper}");
        let padded = format!("  {}  ", actual.replace(':', " "));

        assert!(fingerprints_match(&plain, &actual));
        assert!(fingerprints_match(&upper, &actual));
        assert!(fingerprints_match(&upper_without_colons, &actual));
        assert!(fingerprints_match(&prefixed, &actual));
        assert!(fingerprints_match(&padded, &actual));
    }

    #[test]
    fn malformed_fingerprints_are_rejected() {
        let actual = fingerprint_sha256(b"host key blob");
        assert!(!fingerprints_match(&actual[..94], &actual));
        assert!(!fingerprints_match("not-hex", &actual));
        assert!(!fingerprints_match(&format!("{actual}00"), &actual));
        assert!(normalize_fingerprint(&format!("SZ{}", &actual[2..])).is_none());
    }

    #[test]
    fn debug_output_redacts_secrets() {
        let password = SshAuth::Password("hunter2".to_owned());
        assert!(!format!("{password:?}").contains("hunter2"));

        let private_key = SshAuth::PrivateKey {
            path: PathBuf::from("/tmp/id_ed25519"),
            passphrase: Some("open sesame".to_owned()),
        };
        let debug = format!("{private_key:?}");
        assert!(!debug.contains("open sesame"));
        assert!(debug.contains("redacted"));
    }

    #[tokio::test]
    async fn connects_with_password_and_echoes_through_direct_tcpip() {
        let (address, fingerprint) = start_server().await;
        let config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::Password(PASSWORD.to_owned()),
            // Exercise normalization: uppercase and no colons.
            host_key: HostKeyPolicy::PinSha256(fingerprint.replace(':', "").to_uppercase()),
            target_host: TARGET_HOST.to_owned(),
            target_port: TARGET_PORT,
        };

        let transport = timeout_connect(&config).await;
        // Mirror how the RFB engine consumes the stream.
        let (mut reader, mut writer) = tokio::io::split(transport);
        writer.write_all(b"ping").await.unwrap();
        let mut reply = [0_u8; 4];
        tokio::time::timeout(IO_TIMEOUT, reader.read_exact(&mut reply))
            .await
            .expect("reading the echo timed out")
            .unwrap();
        assert_eq!(&reply, b"ping");

        // First-connect flow: AcceptAny should also establish a tunnel.
        let mut first_connect = config.clone();
        first_connect.host_key = HostKeyPolicy::AcceptAny;
        drop(timeout_connect(&first_connect).await);
    }

    #[tokio::test]
    async fn reports_a_rejected_direct_tcpip_channel() {
        let (address, fingerprint) = start_server().await;
        let config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::Password(PASSWORD.to_owned()),
            host_key: HostKeyPolicy::PinSha256(fingerprint),
            target_host: "not-the-vnc-host".to_owned(),
            target_port: TARGET_PORT,
        };

        let error = match tokio::time::timeout(CONNECT_TIMEOUT, connect_ssh(&config)).await {
            Ok(Ok(_)) => panic!("channel open unexpectedly succeeded"),
            Ok(Err(error)) => error,
            Err(_) => panic!("connection timed out"),
        };
        assert!(matches!(error, SshError::Channel(_)), "{error}");
    }

    #[tokio::test]
    async fn rejects_wrong_password_without_leaking_it() {
        let (address, fingerprint) = start_server().await;
        let wrong_password = "definitely-not-the-password";
        let config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::Password(wrong_password.to_owned()),
            host_key: HostKeyPolicy::PinSha256(fingerprint),
            target_host: TARGET_HOST.to_owned(),
            target_port: TARGET_PORT,
        };

        let error = match tokio::time::timeout(CONNECT_TIMEOUT, connect_ssh(&config)).await {
            Ok(Ok(_)) => panic!("authentication unexpectedly succeeded"),
            Ok(Err(error)) => error,
            Err(_) => panic!("connection timed out"),
        };
        assert!(matches!(error, SshError::Auth(_)), "{error}");
        assert!(!error.to_string().contains(wrong_password));
        assert!(!format!("{error:?}").contains(wrong_password));
    }

    #[tokio::test]
    async fn rejects_a_mismatched_host_key() {
        let (address, _fingerprint) = start_server().await;
        let mut rng = russh::keys::key::safe_rng();
        let other_key = PrivateKey::random(&mut rng, Algorithm::Ed25519).unwrap();
        let other_fingerprint = fingerprint_sha256(&other_key.public_key().to_bytes().unwrap());
        let config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::Password(PASSWORD.to_owned()),
            host_key: HostKeyPolicy::PinSha256(other_fingerprint),
            target_host: TARGET_HOST.to_owned(),
            target_port: TARGET_PORT,
        };

        let error = match tokio::time::timeout(CONNECT_TIMEOUT, connect_ssh(&config)).await {
            Ok(Ok(_)) => panic!("host key verification unexpectedly succeeded"),
            Ok(Err(error)) => error,
            Err(_) => panic!("connection timed out"),
        };
        assert!(matches!(error, SshError::HostKeyMismatch { .. }), "{error}");
    }

    #[tokio::test]
    async fn connects_with_an_openssh_private_key() {
        let (address, fingerprint) = start_server().await;
        let mut rng = russh::keys::key::safe_rng();
        let key = PrivateKey::random(&mut rng, Algorithm::Ed25519).unwrap();
        let path = temp_key_path("plain");
        let pem = key.to_openssh(LineEnding::LF).unwrap();
        std::fs::write(&path, pem.as_bytes()).unwrap();

        let config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::PrivateKey {
                path: path.clone(),
                passphrase: None,
            },
            host_key: HostKeyPolicy::PinSha256(fingerprint),
            target_host: TARGET_HOST.to_owned(),
            target_port: TARGET_PORT,
        };

        let result = timeout_connect(&config).await;
        drop(result);
        let _ = std::fs::remove_file(path);
    }

    #[tokio::test]
    async fn connects_with_an_encrypted_private_key_and_reports_bad_passphrases() {
        let (address, fingerprint) = start_server().await;
        let mut rng = russh::keys::key::safe_rng();
        let key = PrivateKey::random(&mut rng, Algorithm::Ed25519).unwrap();
        let passphrase = "key passphrase";
        let encrypted = key.encrypt(&mut rng, passphrase).unwrap();
        let path = temp_key_path("encrypted");
        let pem = encrypted.to_openssh(LineEnding::LF).unwrap();
        std::fs::write(&path, pem.as_bytes()).unwrap();

        let mut config = SshConfig {
            host: "127.0.0.1".to_owned(),
            port: address.port(),
            username: USER.to_owned(),
            auth: SshAuth::PrivateKey {
                path: path.clone(),
                passphrase: Some(passphrase.to_owned()),
            },
            host_key: HostKeyPolicy::PinSha256(fingerprint),
            target_host: TARGET_HOST.to_owned(),
            target_port: TARGET_PORT,
        };

        let mut transport = timeout_connect(&config).await;
        transport.write_all(b"key").await.unwrap();
        let mut reply = [0_u8; 3];
        tokio::time::timeout(IO_TIMEOUT, transport.read_exact(&mut reply))
            .await
            .expect("reading the echo timed out")
            .unwrap();
        assert_eq!(&reply, b"key");
        drop(transport);

        config.auth = SshAuth::PrivateKey {
            path: path.clone(),
            passphrase: Some("wrong passphrase".to_owned()),
        };
        let error = match tokio::time::timeout(CONNECT_TIMEOUT, connect_ssh(&config)).await {
            Ok(Ok(_)) => panic!("authentication unexpectedly succeeded"),
            Ok(Err(error)) => error,
            Err(_) => panic!("connection timed out"),
        };
        assert!(matches!(error, SshError::KeyLoad(_)), "{error}");
        assert!(!format!("{error:?}").contains(passphrase));
        let _ = std::fs::remove_file(path);
    }

    fn temp_key_path(tag: &str) -> PathBuf {
        std::env::temp_dir().join(format!("rfb-io-ssh-{tag}-{}.key", process::id()))
    }

    async fn timeout_connect(config: &SshConfig) -> BoxedTransport {
        tokio::time::timeout(CONNECT_TIMEOUT, connect_ssh(config))
            .await
            .expect("connecting timed out")
            .expect("connecting failed")
    }

    async fn start_server() -> (std::net::SocketAddr, String) {
        let mut rng = russh::keys::key::safe_rng();
        let host_key = PrivateKey::random(&mut rng, Algorithm::Ed25519).unwrap();
        let fingerprint = fingerprint_sha256(&host_key.public_key().to_bytes().unwrap());

        let config = russh::server::Config {
            keys: vec![host_key],
            auth_rejection_time: Duration::ZERO,
            auth_rejection_time_initial: Some(Duration::ZERO),
            inactivity_timeout: None,
            ..Default::default()
        };

        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let mut server = EchoServer;
            let _ = server.run_on_socket(Arc::new(config), &listener).await;
        });
        (address, fingerprint)
    }

    #[derive(Clone)]
    struct EchoServer;

    impl russh::server::Server for EchoServer {
        type Handler = Self;

        fn new_client(&mut self, _peer_addr: Option<std::net::SocketAddr>) -> Self {
            Self
        }
    }

    impl russh::server::Handler for EchoServer {
        type Error = russh::Error;

        async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
            Ok(if user == USER && password == PASSWORD {
                Auth::Accept
            } else {
                Auth::reject()
            })
        }

        async fn auth_publickey(
            &mut self,
            _user: &str,
            _key: VerifiedPublicKey<'_>,
        ) -> Result<Auth, Self::Error> {
            Ok(Auth::Accept)
        }

        async fn channel_open_direct_tcpip(
            &mut self,
            _channel: Channel<Msg>,
            host_to_connect: &str,
            port_to_connect: u32,
            _originator_address: &str,
            _originator_port: u32,
            reply: ChannelOpenHandle,
            _session: &mut Session,
        ) -> Result<(), Self::Error> {
            if host_to_connect == TARGET_HOST && port_to_connect == u32::from(TARGET_PORT) {
                reply.accept().await;
            } else {
                reply.reject(ChannelOpenFailure::ConnectFailed).await;
            }
            Ok(())
        }

        async fn data(
            &mut self,
            channel: ChannelId,
            data: &[u8],
            session: &mut Session,
        ) -> Result<(), Self::Error> {
            session.data(channel, data.to_vec())?;
            Ok(())
        }
    }
}
