//! Client-side RFB handshake (RFC 6143 sections 7.1-7.3).

use std::fmt;
use std::io;

use rfb_proto::auth::vnc_auth_response;
use rfb_proto::security::{SecurityResult, SecurityType};
use rfb_proto::server_init::{SERVER_INIT_HEADER_LEN, ServerInit, parse_server_init};
use rfb_proto::version::{ProtocolVersion, VERSION_LEN};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

const MAX_NAME_LEN: usize = 1024 * 1024;
const MAX_REASON_LEN: usize = 64 * 1024;
const VNC_CHALLENGE_LEN: usize = 16;

/// Settings that affect the handshake.
#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub password: Option<String>,
    pub shared: bool,
}

impl Default for ClientConfig {
    fn default() -> Self {
        Self {
            password: None,
            shared: true,
        }
    }
}

/// Outcome of a successful handshake.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Handshake {
    pub version: ProtocolVersion,
    pub server_init: ServerInit,
}

#[derive(Debug)]
pub enum HandshakeError {
    Io(io::Error),
    Protocol(&'static str),
    ConnectionRefused(String),
    UnsupportedVersion(ProtocolVersion),
    UnsupportedSecurityType(SecurityType),
    MissingPassword,
    AuthenticationFailed(SecurityResult),
    ServerNameTooLong(usize),
}

impl fmt::Display for HandshakeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Protocol(message) => write!(f, "protocol error: {message}"),
            Self::ConnectionRefused(reason) => write!(f, "connection refused: {reason}"),
            Self::UnsupportedVersion(version) => write!(
                f,
                "unsupported RFB version {}.{}",
                version.major, version.minor
            ),
            Self::UnsupportedSecurityType(security) => {
                write!(f, "unsupported security type {security:?}")
            }
            Self::MissingPassword => {
                f.write_str("server requires VNC authentication but no password is configured")
            }
            Self::AuthenticationFailed(result) => write!(f, "authentication failed: {result:?}"),
            Self::ServerNameTooLong(length) => {
                write!(f, "server name length {length} exceeds limit")
            }
        }
    }
}

impl std::error::Error for HandshakeError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for HandshakeError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Performs the RFB handshake and returns the server's framebuffer description.
pub async fn perform<T>(stream: &mut T, config: &ClientConfig) -> Result<Handshake, HandshakeError>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    let server_version = read_version(stream).await?;
    if server_version.major != 3 || !server_version.is_at_least(ProtocolVersion::RFB_3_3) {
        return Err(HandshakeError::UnsupportedVersion(server_version));
    }

    // Apple advertises 3.889; the standard 3.8 flow remains valid until Apple
    // extensions are explicitly negotiated.
    let version = negotiate_version(server_version);
    stream.write_all(&version.encode()).await?;

    let security = if version == ProtocolVersion::RFB_3_3 {
        read_security_3_3(stream).await?
    } else {
        select_security(stream, config).await?
    };

    if security == SecurityType::VncAuthentication {
        let password = config
            .password
            .as_deref()
            .ok_or(HandshakeError::MissingPassword)?;
        let mut challenge = [0u8; VNC_CHALLENGE_LEN];
        stream.read_exact(&mut challenge).await?;
        stream
            .write_all(&vnc_auth_response(password.as_bytes(), &challenge))
            .await?;
    }

    // 3.8 always sends a SecurityResult; 3.7 and 3.3 only for authenticated
    // security types.
    if version.is_at_least(ProtocolVersion::RFB_3_8) || security != SecurityType::None {
        let result = SecurityResult::from_u32(read_u32(stream).await?);
        if result != SecurityResult::Ok {
            return Err(HandshakeError::AuthenticationFailed(result));
        }
    }

    stream.write_all(&[u8::from(config.shared)]).await?;
    let server_init = read_server_init(stream).await?;
    Ok(Handshake {
        version,
        server_init,
    })
}

fn negotiate_version(server: ProtocolVersion) -> ProtocolVersion {
    if server.is_at_least(ProtocolVersion::RFB_3_8) {
        ProtocolVersion::RFB_3_8
    } else if server.is_at_least(ProtocolVersion::RFB_3_7) {
        ProtocolVersion::RFB_3_7
    } else {
        ProtocolVersion::RFB_3_3
    }
}

async fn read_security_3_3<T>(stream: &mut T) -> Result<SecurityType, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    match read_u32(stream).await? {
        0 => Err(HandshakeError::ConnectionRefused(
            read_reason(stream).await?,
        )),
        1 => Ok(SecurityType::None),
        2 => Ok(SecurityType::VncAuthentication),
        other => {
            let byte = u8::try_from(other)
                .map_err(|_| HandshakeError::Protocol("invalid security type"))?;
            Err(HandshakeError::UnsupportedSecurityType(
                SecurityType::Other(byte),
            ))
        }
    }
}

async fn select_security<T>(
    stream: &mut T,
    config: &ClientConfig,
) -> Result<SecurityType, HandshakeError>
where
    T: AsyncRead + AsyncWrite + Unpin,
{
    let count = read_u8(stream).await?;
    if count == 0 {
        return Err(HandshakeError::ConnectionRefused(
            read_reason(stream).await?,
        ));
    }

    let mut types = vec![0u8; usize::from(count)];
    stream.read_exact(&mut types).await?;
    let offered: Vec<SecurityType> = types
        .iter()
        .map(|&value| SecurityType::from_u8(value))
        .collect();

    let selected =
        if config.password.is_some() && offered.contains(&SecurityType::VncAuthentication) {
            SecurityType::VncAuthentication
        } else if offered.contains(&SecurityType::None) {
            SecurityType::None
        } else if offered.contains(&SecurityType::VncAuthentication) {
            return Err(HandshakeError::MissingPassword);
        } else {
            return Err(HandshakeError::UnsupportedSecurityType(offered[0]));
        };

    stream.write_all(&[selected.to_u8()]).await?;
    Ok(selected)
}

async fn read_version<T>(stream: &mut T) -> Result<ProtocolVersion, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    let mut bytes = [0u8; VERSION_LEN];
    stream.read_exact(&mut bytes).await?;
    ProtocolVersion::parse(&bytes).map_err(|_| HandshakeError::Protocol("invalid protocol version"))
}

async fn read_server_init<T>(stream: &mut T) -> Result<ServerInit, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    let mut header = [0u8; SERVER_INIT_HEADER_LEN];
    stream.read_exact(&mut header).await?;
    let name_len = u32::from_be_bytes([header[20], header[21], header[22], header[23]]) as usize;
    if name_len > MAX_NAME_LEN {
        return Err(HandshakeError::ServerNameTooLong(name_len));
    }

    let mut message = Vec::with_capacity(SERVER_INIT_HEADER_LEN + name_len);
    message.extend_from_slice(&header);
    message.resize(SERVER_INIT_HEADER_LEN + name_len, 0);
    stream
        .read_exact(&mut message[SERVER_INIT_HEADER_LEN..])
        .await?;

    parse_server_init(&message)
        .map(|(init, _)| init)
        .map_err(|_| HandshakeError::Protocol("invalid ServerInit"))
}

async fn read_reason<T>(stream: &mut T) -> Result<String, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    let length = read_u32(stream).await? as usize;
    if length > MAX_REASON_LEN {
        return Err(HandshakeError::Protocol("refusal reason too long"));
    }
    let mut bytes = vec![0u8; length];
    stream.read_exact(&mut bytes).await?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

async fn read_u8<T>(stream: &mut T) -> Result<u8, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    let mut bytes = [0u8; 1];
    stream.read_exact(&mut bytes).await?;
    Ok(bytes[0])
}

async fn read_u32<T>(stream: &mut T) -> Result<u32, HandshakeError>
where
    T: AsyncRead + Unpin,
{
    let mut bytes = [0u8; 4];
    stream.read_exact(&mut bytes).await?;
    Ok(u32::from_be_bytes(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rfb_proto::pixel_format::PixelFormat;
    use tokio::io::{DuplexStream, duplex};

    fn server_init_message() -> Vec<u8> {
        let mut message = Vec::new();
        message.extend_from_slice(&1920u16.to_be_bytes());
        message.extend_from_slice(&1080u16.to_be_bytes());
        message.extend_from_slice(&PixelFormat::bgra8888().encode());
        message.extend_from_slice(&8u32.to_be_bytes());
        message.extend_from_slice(b"Test Mac");
        message
    }

    async fn read_u8_from(stream: &mut DuplexStream) -> u8 {
        let mut byte = [0u8; 1];
        stream.read_exact(&mut byte).await.unwrap();
        byte[0]
    }

    async fn read_version_from(stream: &mut DuplexStream) -> [u8; VERSION_LEN] {
        let mut version = [0u8; VERSION_LEN];
        stream.read_exact(&mut version).await.unwrap();
        version
    }

    #[tokio::test]
    async fn completes_38_none_handshake() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            assert_eq!(&read_version_from(&mut server).await, b"RFB 003.008\n");
            server.write_all(&[1, 1]).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&0u32.to_be_bytes()).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&server_init_message()).await.unwrap();
        });

        let handshake = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap();
        task.await.unwrap();
        assert_eq!(handshake.version, ProtocolVersion::RFB_3_8);
        assert_eq!(handshake.server_init.width, 1920);
        assert_eq!(handshake.server_init.height, 1080);
        assert_eq!(handshake.server_init.name, "Test Mac");
    }

    #[tokio::test]
    async fn performs_vnc_authentication() {
        let (mut client, mut server) = duplex(1024);
        let password = "hunter2";
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            read_version_from(&mut server).await;
            server.write_all(&[2, 1, 2]).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 2);
            let challenge = [0x42u8; 16];
            server.write_all(&challenge).await.unwrap();
            let mut response = [0u8; 16];
            server.read_exact(&mut response).await.unwrap();
            assert_eq!(response, vnc_auth_response(password.as_bytes(), &challenge));
            server.write_all(&0u32.to_be_bytes()).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&server_init_message()).await.unwrap();
        });

        let config = ClientConfig {
            password: Some(password.to_owned()),
            shared: true,
        };
        let handshake = perform(&mut client, &config).await.unwrap();
        task.await.unwrap();
        assert_eq!(handshake.server_init.name, "Test Mac");
    }

    #[tokio::test]
    async fn reports_authentication_failure() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            read_version_from(&mut server).await;
            server.write_all(&[1, 2]).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 2);
            server.write_all(&[0u8; 16]).await.unwrap();
            let mut response = [0u8; 16];
            server.read_exact(&mut response).await.unwrap();
            server.write_all(&1u32.to_be_bytes()).await.unwrap();
        });

        let config = ClientConfig {
            password: Some("wrong".to_owned()),
            shared: true,
        };
        let error = perform(&mut client, &config).await.unwrap_err();
        assert!(matches!(
            error,
            HandshakeError::AuthenticationFailed(SecurityResult::Failed)
        ));
        task.await.unwrap();
    }

    #[tokio::test]
    async fn completes_33_none_handshake_without_security_result() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.003\n").await.unwrap();
            assert_eq!(&read_version_from(&mut server).await, b"RFB 003.003\n");
            server.write_all(&1u32.to_be_bytes()).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&server_init_message()).await.unwrap();
        });

        let handshake = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap();
        task.await.unwrap();
        assert_eq!(handshake.version, ProtocolVersion::RFB_3_3);
    }

    #[tokio::test]
    async fn completes_37_none_handshake_without_security_result() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.007\n").await.unwrap();
            assert_eq!(&read_version_from(&mut server).await, b"RFB 003.007\n");
            server.write_all(&[1, 1]).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&server_init_message()).await.unwrap();
        });

        let handshake = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap();
        task.await.unwrap();
        assert_eq!(handshake.version, ProtocolVersion::RFB_3_7);
    }

    #[tokio::test]
    async fn negotiates_apple_version_down_to_38() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.889\n").await.unwrap();
            assert_eq!(&read_version_from(&mut server).await, b"RFB 003.008\n");
            server.write_all(&[1, 1]).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&0u32.to_be_bytes()).await.unwrap();
            assert_eq!(read_u8_from(&mut server).await, 1);
            server.write_all(&server_init_message()).await.unwrap();
        });

        let handshake = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap();
        task.await.unwrap();
        assert_eq!(handshake.version, ProtocolVersion::RFB_3_8);
    }

    #[tokio::test]
    async fn reports_refusal_reason() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            read_version_from(&mut server).await;
            server.write_all(&[0]).await.unwrap();
            server.write_all(&4u32.to_be_bytes()).await.unwrap();
            server.write_all(b"nope").await.unwrap();
        });

        let error = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            HandshakeError::ConnectionRefused(reason) if reason == "nope"
        ));
        task.await.unwrap();
    }

    #[tokio::test]
    async fn requires_password_when_only_vnc_auth_is_offered() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            read_version_from(&mut server).await;
            server.write_all(&[1, 2]).await.unwrap();
        });

        let error = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap_err();
        assert!(matches!(error, HandshakeError::MissingPassword));
        task.await.unwrap();
    }

    #[tokio::test]
    async fn reports_unsupported_security_type() {
        let (mut client, mut server) = duplex(1024);
        let task = tokio::spawn(async move {
            server.write_all(b"RFB 003.008\n").await.unwrap();
            read_version_from(&mut server).await;
            server.write_all(&[1, 16]).await.unwrap();
        });

        let error = perform(&mut client, &ClientConfig::default())
            .await
            .unwrap_err();
        assert!(matches!(
            error,
            HandshakeError::UnsupportedSecurityType(SecurityType::Tight)
        ));
        task.await.unwrap();
    }
}
