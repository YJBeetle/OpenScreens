//! RFB client session: handshake, framebuffer updates, input and events.

use std::fmt;
use std::io;
use std::sync::{Arc, Mutex};

use bytes::{Buf, BytesMut};
use rfb_codec::{CursorShape, DecodeError, Decoder, Framebuffer, Rect};
use rfb_io::{HostKeyPolicy, SshAuth, SshConfig as IoSshConfig};
use rfb_proto::encoding::Encoding;
use rfb_proto::messages::{
    client_cut_text, framebuffer_update_request, key_event, pointer_event, set_encodings,
    set_pixel_format,
};
use rfb_proto::pixel_format::PixelFormat;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex as AsyncMutex;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::handshake::{self, ClientConfig, HandshakeError};

const EVENT_CHANNEL_CAPACITY: usize = 32;
const COMMAND_CHANNEL_CAPACITY: usize = 64;
const READ_CHUNK: usize = 64 * 1024;
const MAX_CUT_TEXT_LEN: usize = 16 * 1024 * 1024;

/// Encodings advertised to the server, most preferred first.
const BASE_ENCODINGS: [i32; 9] = [
    Encoding::Tight.to_id(),
    Encoding::Zrle.to_id(),
    Encoding::Hextile.to_id(),
    Encoding::CopyRect.to_id(),
    Encoding::Raw.to_id(),
    Encoding::Zlib.to_id(),
    Encoding::DesktopSize.to_id(),
    Encoding::LastRect.to_id(),
    // TightVNC JPEG quality level 9.
    -23,
];

fn encodings(local_cursor: bool) -> Vec<i32> {
    let mut ids = BASE_ENCODINGS.to_vec();
    if local_cursor {
        ids.push(Encoding::Cursor.to_id());
        ids.push(Encoding::PointerPos.to_id());
    }
    ids
}

#[derive(Debug, Clone)]
pub struct SessionConfig {
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub password: Option<String>,
    pub shared: bool,
    /// Advertise the Cursor pseudo-encoding and draw the pointer client-side.
    pub local_cursor: bool,
    pub ssh: Option<SshSettings>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SshSettings {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuthSettings,
    /// Optional SHA-256 host-key fingerprint; when empty the first key is
    /// accepted (TOFU pinning is surfaced by the frontend later).
    pub host_key_fingerprint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SshAuthSettings {
    Password(String),
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
}

impl SessionConfig {
    pub fn new(host: impl Into<String>, port: u16) -> Self {
        Self {
            host: host.into(),
            port,
            username: None,
            password: None,
            shared: true,
            local_cursor: false,
            ssh: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
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
    /// A client-side cursor bitmap (Cursor pseudo-encoding).
    Cursor(CursorShape),
    /// The server moved the pointer (PointerPos pseudo-encoding), in
    /// framebuffer pixels.
    PointerPosition {
        x: u16,
        y: u16,
    },
    Disconnected {
        reason: String,
    },
}

#[derive(Debug)]
pub enum SessionError {
    Io(io::Error),
    Handshake(HandshakeError),
    Decode(DecodeError),
    Protocol(&'static str),
    Ssh(rfb_io::SshError),
    Closed,
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Handshake(error) => write!(f, "handshake failed: {error}"),
            Self::Decode(error) => write!(f, "decode failed: {error:?}"),
            Self::Protocol(message) => write!(f, "protocol error: {message}"),
            Self::Ssh(error) => write!(f, "SSH tunnel failed: {error}"),
            Self::Closed => f.write_str("connection closed"),
        }
    }
}

impl std::error::Error for SessionError {}

impl From<io::Error> for SessionError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<HandshakeError> for SessionError {
    fn from(error: HandshakeError) -> Self {
        Self::Handshake(error)
    }
}

impl From<DecodeError> for SessionError {
    fn from(error: DecodeError) -> Self {
        Self::Decode(error)
    }
}

impl From<rfb_io::SshError> for SessionError {
    fn from(error: rfb_io::SshError) -> Self {
        Self::Ssh(error)
    }
}

/// A connected RFB session.
pub struct Session {
    commands: mpsc::Sender<Vec<u8>>,
    events: AsyncMutex<mpsc::Receiver<Event>>,
    framebuffer: Arc<Mutex<Framebuffer>>,
    input_key: Option<[u8; 16]>,
    name: String,
    reader: JoinHandle<()>,
    writer: JoinHandle<()>,
}

impl Session {
    pub async fn connect(config: SessionConfig) -> Result<Self, SessionError> {
        let stream: rfb_io::BoxedTransport = if let Some(ssh) = &config.ssh {
            let host_key = match ssh.host_key_fingerprint.as_deref() {
                Some(fingerprint) if !fingerprint.trim().is_empty() => {
                    HostKeyPolicy::PinSha256(fingerprint.trim().to_owned())
                }
                _ => HostKeyPolicy::AcceptAny,
            };
            let auth = match &ssh.auth {
                SshAuthSettings::Password(password) => SshAuth::Password(password.clone()),
                SshAuthSettings::PrivateKey { pem, passphrase } => SshAuth::PrivateKeyData {
                    pem: pem.clone(),
                    passphrase: passphrase.clone(),
                },
            };
            let ssh_config = IoSshConfig {
                host: ssh.host.clone(),
                port: ssh.port,
                username: ssh.username.clone(),
                auth,
                host_key,
                target_host: config.host.clone(),
                target_port: config.port,
            };
            rfb_io::connect_ssh(&ssh_config).await?
        } else {
            Box::new(rfb_io::connect_tcp(&config.host, config.port).await?)
        };
        Self::connect_stream(stream, config).await
    }

    pub async fn connect_stream<T>(
        mut stream: T,
        config: SessionConfig,
    ) -> Result<Self, SessionError>
    where
        T: AsyncRead + AsyncWrite + Send + Unpin + 'static,
    {
        let handshake = handshake::perform(
            &mut stream,
            &ClientConfig {
                username: config.username.clone(),
                password: config.password.clone(),
                shared: config.shared,
            },
        )
        .await?;
        let input_key = handshake.input_key;

        let width = handshake.server_init.width;
        let height = handshake.server_init.height;
        let name = handshake.server_init.name.clone();
        let framebuffer = Arc::new(Mutex::new(Framebuffer::new(width, height)));

        let (read_half, write_half) = tokio::io::split(stream);
        let (command_tx, command_rx) = mpsc::channel(COMMAND_CHANNEL_CAPACITY);
        let (event_tx, event_rx) = mpsc::channel(EVENT_CHANNEL_CAPACITY);

        let writer = tokio::spawn(writer_task(write_half, command_rx));

        let mut initial = Vec::new();
        initial.extend_from_slice(&set_pixel_format(&PixelFormat::bgra8888()));
        initial.extend_from_slice(&set_encodings(&encodings(config.local_cursor)));
        initial.extend_from_slice(&framebuffer_update_request(false, 0, 0, width, height));
        command_tx
            .send(initial)
            .await
            .map_err(|_| SessionError::Closed)?;

        let reader = tokio::spawn(reader_task(
            read_half,
            command_tx.clone(),
            framebuffer.clone(),
            event_tx.clone(),
            width,
            height,
            name.clone(),
        ));

        Ok(Self {
            commands: command_tx,
            events: AsyncMutex::new(event_rx),
            framebuffer,
            input_key,
            name,
            reader,
            writer,
        })
    }

    pub fn has_input_encryption(&self) -> bool {
        self.input_key.is_some()
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    pub fn size(&self) -> Option<(u16, u16)> {
        let framebuffer = self.framebuffer.lock().ok()?;
        Some((framebuffer.width(), framebuffer.height()))
    }

    /// Copies a framebuffer region out as tightly packed BGRA8888.
    pub fn copy_region(&self, rect: Rect) -> Option<Vec<u8>> {
        let framebuffer = self.framebuffer.lock().ok()?;
        copy_region_from(&framebuffer, rect)
    }

    pub async fn next_event(&self) -> Option<Event> {
        self.events.lock().await.recv().await
    }

    pub async fn send_pointer(&self, mask: u8, x: u16, y: u16) -> Result<(), SessionError> {
        self.send(pointer_event(mask, x, y).to_vec()).await
    }

    pub async fn send_key(&self, down: bool, keysym: u32) -> Result<(), SessionError> {
        self.send(key_event(down, keysym).to_vec()).await
    }

    pub async fn send_clipboard(&self, text: &str) -> Result<(), SessionError> {
        self.send(client_cut_text(text.as_bytes())).await
    }

    pub async fn request_refresh(&self) -> Result<(), SessionError> {
        let Some((width, height)) = self.size() else {
            return Err(SessionError::Closed);
        };
        self.send(framebuffer_update_request(false, 0, 0, width, height).to_vec())
            .await
    }

    async fn send(&self, bytes: Vec<u8>) -> Result<(), SessionError> {
        self.commands
            .send(bytes)
            .await
            .map_err(|_| SessionError::Closed)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.reader.abort();
        self.writer.abort();
    }
}

async fn writer_task<W>(mut write: W, mut commands: mpsc::Receiver<Vec<u8>>)
where
    W: AsyncWrite + Unpin,
{
    while let Some(bytes) = commands.recv().await {
        if write.write_all(&bytes).await.is_err() {
            break;
        }
    }
    let _ = write.shutdown().await;
}

struct ReaderState {
    buffer: BytesMut,
    decoder: Decoder,
    framebuffer: Arc<Mutex<Framebuffer>>,
    pixel_format: PixelFormat,
}

async fn reader_task<R>(
    mut read: R,
    commands: mpsc::Sender<Vec<u8>>,
    framebuffer: Arc<Mutex<Framebuffer>>,
    events: mpsc::Sender<Event>,
    width: u16,
    height: u16,
    name: String,
) where
    R: AsyncRead + Unpin,
{
    if events
        .send(Event::Connected {
            width,
            height,
            name,
        })
        .await
        .is_err()
    {
        return;
    }

    let mut state = ReaderState {
        buffer: BytesMut::with_capacity(READ_CHUNK),
        decoder: Decoder::new(),
        framebuffer,
        pixel_format: PixelFormat::bgra8888(),
    };
    let mut sequence = 0u64;

    loop {
        match read_message(&mut read, &mut state, &events, &mut sequence).await {
            Ok(needs_request) => {
                if needs_request {
                    let Some((width, height)) = state.size() else {
                        break;
                    };
                    let request = framebuffer_update_request(true, 0, 0, width, height);
                    if commands.send(request.to_vec()).await.is_err() {
                        break;
                    }
                }
            }
            Err(SessionError::Closed) => {
                let _ = events
                    .send(Event::Disconnected {
                        reason: "connection closed".to_owned(),
                    })
                    .await;
                return;
            }
            Err(error) => {
                let _ = events
                    .send(Event::Disconnected {
                        reason: error.to_string(),
                    })
                    .await;
                return;
            }
        }
    }
}

impl ReaderState {
    fn size(&self) -> Option<(u16, u16)> {
        let framebuffer = self.framebuffer.lock().ok()?;
        Some((framebuffer.width(), framebuffer.height()))
    }
}

async fn read_message<R>(
    read: &mut R,
    state: &mut ReaderState,
    events: &mpsc::Sender<Event>,
    sequence: &mut u64,
) -> Result<bool, SessionError>
where
    R: AsyncRead + Unpin,
{
    fill_buffer(read, &mut state.buffer, 1).await?;
    let message_type = state.buffer[0];
    state.buffer.advance(1);

    match message_type {
        0 => handle_framebuffer_update(read, state, events, sequence).await?,
        1 => skip_colour_map(read, state).await?,
        2 => {
            events
                .send(Event::Bell)
                .await
                .map_err(|_| SessionError::Closed)?;
        }
        3 => handle_server_cut_text(read, state, events).await?,
        _ => return Err(SessionError::Protocol("unknown server message")),
    }

    Ok(message_type == 0)
}

async fn handle_framebuffer_update<R>(
    read: &mut R,
    state: &mut ReaderState,
    events: &mpsc::Sender<Event>,
    sequence: &mut u64,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    fill_buffer(read, &mut state.buffer, 3).await?;
    let rect_count = u16::from_be_bytes([state.buffer[1], state.buffer[2]]);
    state.buffer.advance(3);

    let mut damaged = Vec::with_capacity(usize::from(rect_count));
    let mut resized = None;

    for _ in 0..rect_count {
        fill_buffer(read, &mut state.buffer, 12).await?;
        let x = u16::from_be_bytes([state.buffer[0], state.buffer[1]]);
        let y = u16::from_be_bytes([state.buffer[2], state.buffer[3]]);
        let width = u16::from_be_bytes([state.buffer[4], state.buffer[5]]);
        let height = u16::from_be_bytes([state.buffer[6], state.buffer[7]]);
        let encoding = i32::from_be_bytes([
            state.buffer[8],
            state.buffer[9],
            state.buffer[10],
            state.buffer[11],
        ]);
        state.buffer.advance(12);

        let encoding = Encoding::from_id(encoding);
        if encoding == Encoding::LastRect {
            break;
        }

        if encoding == Encoding::DesktopSize {
            {
                let mut framebuffer = state
                    .framebuffer
                    .lock()
                    .map_err(|_| SessionError::Protocol("framebuffer lock poisoned"))?;
                framebuffer.resize(width, height);
            }
            resized = Some((width, height));
            continue;
        }

        if encoding == Encoding::Cursor {
            let rect = Rect {
                x,
                y,
                width,
                height,
            };
            decode_cursor_shape(read, state, rect, events).await?;
            continue;
        }

        if encoding == Encoding::XCursor {
            skip_cursor(read, state, width, height, encoding).await?;
            continue;
        }

        if encoding == Encoding::PointerPos {
            fill_buffer(read, &mut state.buffer, 4).await?;
            let pointer_x = u16::from_be_bytes([state.buffer[0], state.buffer[1]]);
            let pointer_y = u16::from_be_bytes([state.buffer[2], state.buffer[3]]);
            state.buffer.advance(4);
            events
                .send(Event::PointerPosition {
                    x: pointer_x,
                    y: pointer_y,
                })
                .await
                .map_err(|_| SessionError::Closed)?;
            continue;
        }

        let rect = Rect {
            x,
            y,
            width,
            height,
        };
        decode_rect(read, state, rect, encoding).await?;
        damaged.push(rect);
    }

    if let Some((width, height)) = resized {
        events
            .send(Event::Resized { width, height })
            .await
            .map_err(|_| SessionError::Closed)?;
    }

    if !damaged.is_empty() {
        *sequence = sequence.wrapping_add(1);
        events
            .send(Event::Frame {
                sequence: *sequence,
                rects: damaged,
            })
            .await
            .map_err(|_| SessionError::Closed)?;
    }

    Ok(())
}

async fn decode_rect<R>(
    read: &mut R,
    state: &mut ReaderState,
    rect: Rect,
    encoding: Encoding,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    loop {
        let result = {
            let mut framebuffer = state
                .framebuffer
                .lock()
                .map_err(|_| SessionError::Protocol("framebuffer lock poisoned"))?;
            state.decoder.decode(
                &mut framebuffer,
                rect,
                encoding,
                &state.buffer,
                state.pixel_format,
            )
        };

        match result {
            Ok(consumed) => {
                state.buffer.advance(consumed);
                return Ok(());
            }
            Err(DecodeError::Incomplete) => read_more(read, &mut state.buffer).await?,
            Err(error) => return Err(SessionError::Decode(error)),
        }
    }
}

async fn decode_cursor_shape<R>(
    read: &mut R,
    state: &mut ReaderState,
    rect: Rect,
    events: &mpsc::Sender<Event>,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    loop {
        match rfb_codec::decode_cursor(rect, &state.buffer, state.pixel_format) {
            Ok((shape, consumed)) => {
                state.buffer.advance(consumed);
                events
                    .send(Event::Cursor(shape))
                    .await
                    .map_err(|_| SessionError::Closed)?;
                return Ok(());
            }
            Err(DecodeError::Incomplete) => read_more(read, &mut state.buffer).await?,
            Err(error) => return Err(SessionError::Decode(error)),
        }
    }
}

async fn skip_cursor<R>(
    read: &mut R,
    state: &mut ReaderState,
    width: u16,
    height: u16,
    encoding: Encoding,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    let pixels = usize::from(width) * usize::from(height);
    let total = if encoding == Encoding::XCursor {
        6 + width.div_ceil(8) as usize * usize::from(height)
    } else {
        pixels * 4 + width.div_ceil(8) as usize * usize::from(height)
    };
    skip_bytes(read, &mut state.buffer, total).await
}

async fn skip_colour_map<R>(read: &mut R, state: &mut ReaderState) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    fill_buffer(read, &mut state.buffer, 5).await?;
    let count = u16::from_be_bytes([state.buffer[3], state.buffer[4]]);
    state.buffer.advance(5);
    skip_bytes(read, &mut state.buffer, usize::from(count) * 6).await
}

async fn handle_server_cut_text<R>(
    read: &mut R,
    state: &mut ReaderState,
    events: &mpsc::Sender<Event>,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    fill_buffer(read, &mut state.buffer, 7).await?;
    let length = u32::from_be_bytes([
        state.buffer[3],
        state.buffer[4],
        state.buffer[5],
        state.buffer[6],
    ]) as usize;
    state.buffer.advance(7);
    if length > MAX_CUT_TEXT_LEN {
        return Err(SessionError::Protocol("cut text too long"));
    }
    fill_buffer(read, &mut state.buffer, length).await?;
    let text = String::from_utf8_lossy(&state.buffer[..length]).into_owned();
    state.buffer.advance(length);
    events
        .send(Event::Clipboard { text })
        .await
        .map_err(|_| SessionError::Closed)
}

async fn skip_bytes<R>(
    read: &mut R,
    buffer: &mut BytesMut,
    count: usize,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    fill_buffer(read, buffer, count).await?;
    buffer.advance(count);
    Ok(())
}

async fn fill_buffer<R>(
    read: &mut R,
    buffer: &mut BytesMut,
    needed: usize,
) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    while buffer.len() < needed {
        read_more(read, buffer).await?;
    }
    Ok(())
}

async fn read_more<R>(read: &mut R, buffer: &mut BytesMut) -> Result<(), SessionError>
where
    R: AsyncRead + Unpin,
{
    buffer.reserve(READ_CHUNK);
    let read_bytes = read.read_buf(buffer).await?;
    if read_bytes == 0 {
        return Err(SessionError::Closed);
    }
    Ok(())
}

fn copy_region_from(framebuffer: &Framebuffer, rect: Rect) -> Option<Vec<u8>> {
    let width = usize::from(framebuffer.width());
    let height = usize::from(framebuffer.height());
    let x = usize::from(rect.x);
    let y = usize::from(rect.y);
    let rect_width = usize::from(rect.width);
    let rect_height = usize::from(rect.height);
    if rect_width == 0 || rect_height == 0 || x + rect_width > width || y + rect_height > height {
        return None;
    }

    let stride = width * 4;
    let row_bytes = rect_width * 4;
    let mut out = Vec::with_capacity(row_bytes * rect_height);
    for row in 0..rect_height {
        let start = (y + row) * stride + x * 4;
        out.extend_from_slice(&framebuffer.pixels()[start..start + row_bytes]);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_region_validates_bounds() {
        let framebuffer = Framebuffer::new(10, 10);
        assert!(
            copy_region_from(
                &framebuffer,
                Rect {
                    x: 0,
                    y: 0,
                    width: 10,
                    height: 10
                }
            )
            .is_some()
        );
        assert!(
            copy_region_from(
                &framebuffer,
                Rect {
                    x: 5,
                    y: 5,
                    width: 6,
                    height: 1
                }
            )
            .is_none()
        );
        assert!(
            copy_region_from(
                &framebuffer,
                Rect {
                    x: 0,
                    y: 0,
                    width: 0,
                    height: 1
                }
            )
            .is_none()
        );
    }
}
