//! UniFFI surface for the OpenScreens core.
//!
//! Frontends see a session object, an event stream, input methods and a
//! copy-on-demand framebuffer region accessor.

use std::sync::Arc;

use rfb_codec::Rect as EngineRect;
use rfb_engine::session::{
    Event as EngineEvent, Session, SessionConfig as EngineConfig, SshAuthSettings as EngineSshAuth,
    SshSettings as EngineSshSettings,
};

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, uniffi::Enum)]
pub enum SshAuthConfig {
    Password {
        password: String,
    },
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
    pub shared: bool,
    pub local_cursor: bool,
    pub quality: u8,
    pub frame_interval_ms: u16,
    pub ssh_host: Option<String>,
    pub ssh_port: Option<u16>,
    pub ssh_username: Option<String>,
    pub ssh_auth: Option<SshAuthConfig>,
    pub ssh_host_key_fingerprint: Option<String>,
}

impl From<SessionConfig> for EngineConfig {
    fn from(config: SessionConfig) -> Self {
        let ssh = match (config.ssh_username, config.ssh_auth) {
            (Some(username), Some(auth)) if !username.trim().is_empty() => {
                let auth = match auth {
                    SshAuthConfig::Password { password } => EngineSshAuth::Password(password),
                    SshAuthConfig::PrivateKey { pem, passphrase } => {
                        EngineSshAuth::PrivateKey { pem, passphrase }
                    }
                };
                Some(EngineSshSettings {
                    host: config
                        .ssh_host
                        .filter(|host| !host.trim().is_empty())
                        .unwrap_or_else(|| config.host.clone()),
                    port: config.ssh_port.unwrap_or(22),
                    username,
                    auth,
                    host_key_fingerprint: config.ssh_host_key_fingerprint,
                })
            }
            _ => None,
        };
        Self {
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            shared: config.shared,
            local_cursor: config.local_cursor,
            quality: config.quality,
            frame_interval_ms: config.frame_interval_ms,
            ssh,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Rect {
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
}

impl From<Rect> for EngineRect {
    fn from(rect: Rect) -> Self {
        Self {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }
    }
}

impl From<EngineRect> for Rect {
    fn from(rect: EngineRect) -> Self {
        Self {
            x: rect.x,
            y: rect.y,
            width: rect.width,
            height: rect.height,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SessionSize {
    pub width: u16,
    pub height: u16,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum SessionEvent {
    Connected {
        width: u16,
        height: u16,
        name: String,
    },
    Frame {
        sequence: u64,
        rects: Vec<Rect>,
    },
    Resized {
        width: u16,
        height: u16,
    },
    Clipboard {
        text: String,
    },
    Bell,
    Cursor {
        hotspot_x: u16,
        hotspot_y: u16,
        width: u16,
        height: u16,
        pixels: Vec<u8>,
    },
    PointerPosition {
        x: u16,
        y: u16,
    },
    Disconnected {
        reason: String,
    },
}

impl From<EngineEvent> for SessionEvent {
    fn from(event: EngineEvent) -> Self {
        match event {
            EngineEvent::Connected {
                width,
                height,
                name,
            } => Self::Connected {
                width,
                height,
                name,
            },
            EngineEvent::Frame { sequence, rects } => Self::Frame {
                sequence,
                rects: rects.into_iter().map(Rect::from).collect(),
            },
            EngineEvent::Resized { width, height } => Self::Resized { width, height },
            EngineEvent::Clipboard { text } => Self::Clipboard { text },
            EngineEvent::Bell => Self::Bell,
            EngineEvent::Cursor(shape) => Self::Cursor {
                hotspot_x: shape.hotspot_x,
                hotspot_y: shape.hotspot_y,
                width: shape.width,
                height: shape.height,
                pixels: shape.pixels,
            },
            EngineEvent::PointerPosition { x, y } => Self::PointerPosition { x, y },
            EngineEvent::Disconnected { reason } => Self::Disconnected { reason },
        }
    }
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SessionFailure {
    #[error("{reason}")]
    Session { reason: String },
}

#[derive(uniffi::Object)]
pub struct RemoteSession {
    session: Arc<Session>,
}

#[uniffi::export(async_runtime = "tokio")]
impl RemoteSession {
    #[uniffi::constructor]
    pub async fn connect(config: SessionConfig) -> Result<Arc<Self>, SessionFailure> {
        let session =
            Session::connect(config.into())
                .await
                .map_err(|error| SessionFailure::Session {
                    reason: error.to_string(),
                })?;
        Ok(Arc::new(Self {
            session: Arc::new(session),
        }))
    }

    pub fn server_name(&self) -> String {
        self.session.name().to_owned()
    }

    pub fn size(&self) -> Option<SessionSize> {
        self.session
            .size()
            .map(|(width, height)| SessionSize { width, height })
    }

    pub async fn next_event(&self) -> Option<SessionEvent> {
        self.session.next_event().await.map(SessionEvent::from)
    }

    pub async fn send_pointer(&self, mask: u8, x: u16, y: u16) -> Result<(), SessionFailure> {
        self.session
            .send_pointer(mask, x, y)
            .await
            .map_err(to_failure)
    }

    pub async fn send_key(&self, down: bool, keysym: u32) -> Result<(), SessionFailure> {
        self.session
            .send_key(down, keysym)
            .await
            .map_err(to_failure)
    }

    pub async fn send_clipboard(&self, text: String) -> Result<(), SessionFailure> {
        self.session.send_clipboard(&text).await.map_err(to_failure)
    }

    pub async fn request_refresh(&self) -> Result<(), SessionFailure> {
        self.session.request_refresh().await.map_err(to_failure)
    }

    /// Returns tightly packed BGRA8888 pixels for one framebuffer region.
    pub fn copy_region(&self, rect: Rect) -> Option<Vec<u8>> {
        self.session.copy_region(rect.into())
    }
}

fn to_failure(error: rfb_engine::session::SessionError) -> SessionFailure {
    SessionFailure::Session {
        reason: error.to_string(),
    }
}

fn to_ssh_failure(error: rfb_io::SshError) -> SessionFailure {
    SessionFailure::Session {
        reason: error.to_string(),
    }
}

/// A key pair generated by the core for the app's key manager.
#[derive(Debug, Clone, uniffi::Record)]
pub struct GeneratedSshKey {
    pub private_key_pem: String,
    pub public_key_openssh: String,
    pub fingerprint: String,
}

/// Returns the SHA-256 fingerprint of a private key in OpenSSH or PEM format.
#[uniffi::export]
pub fn ssh_key_fingerprint(
    pem: String,
    passphrase: Option<String>,
) -> Result<String, SessionFailure> {
    rfb_io::ssh_private_key_fingerprint(&pem, passphrase.as_deref()).map_err(to_ssh_failure)
}

/// Returns the OpenSSH public key derived from a private key.
#[uniffi::export]
pub fn ssh_public_key(pem: String, passphrase: Option<String>) -> Result<String, SessionFailure> {
    rfb_io::ssh_public_key_from_private(&pem, passphrase.as_deref()).map_err(to_ssh_failure)
}

/// Generates an Ed25519 key pair in OpenSSH format.
#[uniffi::export]
pub fn generate_ssh_key() -> Result<GeneratedSshKey, SessionFailure> {
    rfb_io::generate_ssh_key()
        .map(|generated| GeneratedSshKey {
            private_key_pem: generated.private_key_pem,
            public_key_openssh: generated.public_key_openssh,
            fingerprint: generated.fingerprint,
        })
        .map_err(to_ssh_failure)
}
