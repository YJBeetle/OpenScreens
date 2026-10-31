//! UniFFI surface for the OpenScreens core.
//!
//! Frontends see a session object, an event stream, input methods and a
//! copy-on-demand framebuffer region accessor.

use std::sync::Arc;

use rfb_codec::Rect as EngineRect;
use rfb_engine::apple_file_transfer as ft;
use rfb_engine::session::{
    Event as EngineEvent, Session, SessionConfig as EngineConfig, SshAuthSettings as EngineSshAuth,
    SshSettings as EngineSshSettings, WireGuardSettings as EngineWireGuardSettings,
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
    /// Full wg-quick text; when set the target is dialled through a userspace
    /// WireGuard tunnel (mutually exclusive with SSH).
    pub wireguard_config: Option<String>,
    pub wireguard_dns_fallback: bool,
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
            // Apple servers are detected during the handshake; non-Apple
            // servers keep the standard 3.8 flow.
            apple_session: true,
            adaptive_dct: true,
            wireguard: config
                .wireguard_config
                .filter(|text| !text.trim().is_empty())
                .map(|wg_quick| EngineWireGuardSettings {
                    wg_quick,
                    dns_fallback: config.wireguard_dns_fallback,
                    connect_timeout_secs: 30,
                }),
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

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DisplayScreen {
    pub id: u32,
    pub x: u16,
    pub y: u16,
    pub width: u16,
    pub height: u16,
    pub flags: u32,
}

/// One remote item offered by a drag-out (Apple message 0x20).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct RemoteFileInfo {
    /// Original `file://` URL from the remote pasteboard.
    pub url: String,
    /// Absolute POSIX path on the remote computer.
    pub path: String,
    /// Last path component, suitable as a local file name.
    pub name: String,
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
    DesktopLayout {
        width: u16,
        height: u16,
        screens: Vec<DisplayScreen>,
    },
    Clipboard {
        text: String,
    },
    /// The Apple server asked for the local clipboard (message 0x14 subtype 2).
    ClipboardRequest,
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
    UploadRequest {
        handle: u32,
        path: String,
    },
    /// Remote file URLs offered by an Apple drag-out sequence.
    DragOutInfo {
        handle: u32,
        files: Vec<RemoteFileInfo>,
    },
    FileTransfer {
        subtype: u16,
        handle: u32,
        payload: Vec<u8>,
    },
    DownloadProgress {
        handle: u32,
        name: Option<String>,
        bytes: u64,
        total: u64,
    },
    DownloadComplete {
        handle: u32,
        files: u32,
        directories: u32,
        bytes: u64,
        error: Option<String>,
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
            EngineEvent::DesktopLayout {
                width,
                height,
                screens,
            } => Self::DesktopLayout {
                width,
                height,
                screens: screens
                    .into_iter()
                    .map(|screen| DisplayScreen {
                        id: screen.id,
                        x: screen.x,
                        y: screen.y,
                        width: screen.width,
                        height: screen.height,
                        flags: screen.flags,
                    })
                    .collect(),
            },
            EngineEvent::Clipboard { text } => Self::Clipboard { text },
            EngineEvent::ClipboardRequest => Self::ClipboardRequest,
            EngineEvent::Bell => Self::Bell,
            EngineEvent::Cursor(shape) => Self::Cursor {
                hotspot_x: shape.hotspot_x,
                hotspot_y: shape.hotspot_y,
                width: shape.width,
                height: shape.height,
                pixels: shape.pixels,
            },
            EngineEvent::PointerPosition { x, y } => Self::PointerPosition { x, y },
            EngineEvent::UploadRequest { handle, path } => Self::UploadRequest { handle, path },
            EngineEvent::DragOutInfo { handle, files } => Self::DragOutInfo {
                handle,
                files: files
                    .into_iter()
                    .map(|file| RemoteFileInfo {
                        url: file.url,
                        path: file.path,
                        name: file.name,
                    })
                    .collect(),
            },
            EngineEvent::FileTransfer {
                subtype,
                handle,
                payload,
            } => Self::FileTransfer {
                subtype,
                handle,
                payload,
            },
            EngineEvent::DownloadProgress {
                handle,
                name,
                bytes,
                total,
            } => Self::DownloadProgress {
                handle,
                name,
                bytes,
                total,
            },
            EngineEvent::DownloadComplete {
                handle,
                files,
                directories,
                bytes,
                error,
            } => Self::DownloadComplete {
                handle,
                files,
                directories,
                bytes,
                error,
            },
            EngineEvent::Disconnected { reason } => Self::Disconnected { reason },
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum TransferEntryKind {
    File,
    Directory,
    Symlink,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct TransferEntry {
    pub kind: TransferEntryKind,
    pub name: String,
    pub data_size: u64,
    pub resource_size: u64,
    pub mode: u16,
    pub nesting: u16,
    pub created: u32,
    pub accessed: u32,
    pub changed: u32,
    pub modified: u32,
    pub finder_info: Vec<u8>,
    pub link_target: Option<String>,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum TransferProgress {
    Ratio { value: f64 },
    Name { name: String },
}

impl TransferEntry {
    fn to_engine(&self) -> Result<ft::Entry<'_>, SessionFailure> {
        if self.finder_info.len() != 32 {
            return Err(SessionFailure::Session {
                reason: "finder_info must be 32 bytes".to_string(),
            });
        }
        let mut finder_info = [0u8; 32];
        finder_info.copy_from_slice(&self.finder_info);
        Ok(ft::Entry {
            kind: match self.kind {
                TransferEntryKind::File => ft::EntryKind::File,
                TransferEntryKind::Directory => ft::EntryKind::Directory,
                TransferEntryKind::Symlink => ft::EntryKind::Symlink,
            },
            name: &self.name,
            data_size: self.data_size,
            resource_size: self.resource_size,
            mode: self.mode,
            nesting: self.nesting,
            created: self.created,
            accessed: self.accessed,
            changed: self.changed,
            modified: self.modified,
            finder_info,
            link_target: self.link_target.as_deref(),
        })
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

    pub fn next_transfer_handle(&self) -> u32 {
        self.session.next_transfer_handle()
    }

    /// Announces a drag-in with local file URLs and returns once the message is
    /// queued. The server replies with a `SessionEvent::UploadRequest`.
    pub async fn announce_upload(
        &self,
        handle: u32,
        file_urls: Vec<String>,
    ) -> Result<(), SessionFailure> {
        self.session
            .announce_upload(handle, &file_urls)
            .await
            .map_err(to_failure)
    }

    pub async fn upload_destination(
        &self,
        handle: u32,
        folder: String,
    ) -> Result<(), SessionFailure> {
        self.session
            .upload_destination(handle, &folder)
            .await
            .map_err(to_failure)
    }

    pub async fn upload_summary(
        &self,
        handle: u32,
        total_bytes: u64,
        files: u32,
        directories: u32,
    ) -> Result<(), SessionFailure> {
        self.session
            .upload_summary(handle, total_bytes, files, directories)
            .await
            .map_err(to_failure)
    }

    pub async fn upload_entry(
        &self,
        handle: u32,
        entry: TransferEntry,
    ) -> Result<(), SessionFailure> {
        let entry = entry.to_engine()?;
        self.session
            .upload_entry(handle, &entry)
            .await
            .map_err(to_failure)
    }

    pub async fn upload_data(&self, handle: u32, chunk: Vec<u8>) -> Result<(), SessionFailure> {
        self.session
            .upload_data(handle, &chunk)
            .await
            .map_err(to_failure)
    }

    pub async fn upload_complete(&self, handle: u32) -> Result<(), SessionFailure> {
        self.session
            .upload_complete(handle)
            .await
            .map_err(to_failure)
    }

    pub async fn cancel_transfer(&self, handle: u32) -> Result<(), SessionFailure> {
        self.session
            .cancel_transfer(handle)
            .await
            .map_err(to_failure)
    }

    /// Starts an Apple drag-out sequence (message 0x0E) and returns the handle
    /// used. The server answers with `SessionEvent.DragOutInfo`.
    pub async fn begin_drag_out(&self, handle: Option<u32>) -> Result<u32, SessionFailure> {
        self.session
            .begin_drag_out(handle)
            .await
            .map_err(to_failure)
    }

    pub async fn start_drag_out(&self, handle: u32) -> Result<(), SessionFailure> {
        self.session
            .start_drag_out(handle)
            .await
            .map_err(to_failure)
    }

    pub async fn request_download(&self, handle: u32, path: String) -> Result<(), SessionFailure> {
        self.session
            .request_download(handle, &path)
            .await
            .map_err(to_failure)
    }

    /// Requests `path` and materialises it below `root`; progress arrives as
    /// `SessionEvent.DownloadProgress` / `DownloadComplete`.
    pub async fn start_download(
        &self,
        handle: u32,
        path: String,
        root: String,
    ) -> Result<(), SessionFailure> {
        self.session
            .start_download(handle, &path, std::path::PathBuf::from(root))
            .await
            .map_err(to_failure)
    }

    pub async fn request_refresh(&self) -> Result<(), SessionFailure> {
        self.session.request_refresh().await.map_err(to_failure)
    }

    /// Selects an Apple display by id; `None` shows all displays.
    pub async fn select_display(&self, display_id: Option<u32>) -> Result<(), SessionFailure> {
        self.session
            .select_display(display_id)
            .await
            .map_err(to_failure)
    }

    /// Restricts incremental update requests to a region and refreshes it.
    /// A zero width or height restores full-screen updates.
    pub async fn set_viewport(
        &self,
        x: u16,
        y: u16,
        width: u16,
        height: u16,
    ) -> Result<(), SessionFailure> {
        let rect = (width > 0 && height > 0).then_some(EngineRect {
            x,
            y,
            width,
            height,
        });
        self.session.set_viewport(rect).await.map_err(to_failure)
    }

    /// Returns tightly packed BGRA8888 pixels for one framebuffer region.
    pub fn copy_region(&self, rect: Rect) -> Option<Vec<u8>> {
        self.session.copy_region(rect.into())
    }

    /// Returns a region sampled every `scale` pixels for a downscaled display.
    pub fn copy_region_scaled(&self, rect: Rect, scale: u16) -> Option<Vec<u8>> {
        self.session.copy_region_scaled(rect.into(), scale)
    }
}

#[uniffi::export]
pub fn parse_transfer_progress(payload: Vec<u8>) -> Option<TransferProgress> {
    match ft::parse_progress(&payload).ok()? {
        ft::Progress::Ratio(value) => Some(TransferProgress::Ratio { value }),
        ft::Progress::Name(name) => Some(TransferProgress::Name { name }),
    }
}

#[uniffi::export]
pub fn parse_transfer_ack(payload: Vec<u8>) -> Option<String> {
    ft::parse_ack(&payload).ok()
}

#[uniffi::export]
pub fn parse_pasteboard_file_urls(pasteboard: Vec<u8>) -> Vec<String> {
    ft::parse_pasteboard_file_urls(&pasteboard).unwrap_or_default()
}

#[uniffi::export]
pub fn transfer_timestamp_1904(unix_seconds: u64) -> u32 {
    ft::timestamp_1904(unix_seconds)
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
