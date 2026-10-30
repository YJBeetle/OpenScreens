//! UniFFI surface for the OpenScreens core.
//!
//! Frontends see a session object, an event stream, input methods and a
//! copy-on-demand framebuffer region accessor.

use std::sync::Arc;

use rfb_codec::Rect as EngineRect;
use rfb_engine::session::{Event as EngineEvent, Session, SessionConfig as EngineConfig};

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, uniffi::Record)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
    pub shared: bool,
}

impl From<SessionConfig> for EngineConfig {
    fn from(config: SessionConfig) -> Self {
        Self {
            host: config.host,
            port: config.port,
            username: config.username,
            password: config.password,
            shared: config.shared,
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
