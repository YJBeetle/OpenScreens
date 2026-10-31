//! Receiving side of the Apple drag-out (download) file transfer.
//!
//! The caller demultiplexes `0x22` containers by handle and feeds
//! `(subtype, handle, payload)` tuples to [`DownloadTransfer`]. The state
//! machine materialises the remote tree below a local root:
//!
//! ```text
//! 0x64 summary -> 0x65 entry* -> (0x66 | 0x67)* per file -> 0x68 complete
//! ```
//!
//! Names are wire-encoded with `/` replaced by `:` (the HFS convention). This
//! module keeps `:` verbatim: it is a legal byte in POSIX file names, and
//! decoding it would turn a single name into extra path components. Every name
//! must be one normal path component, so a server cannot escape the root with
//! `..`, absolute paths or embedded separators.
//!
//! Limitations: only the main data fork is persisted (bytes beyond
//! `data_size`, i.e. the resource fork, are counted but dropped), symlinks are
//! skipped, and POSIX mode/timestamps/FinderInfo are not applied. The
//! destination root itself is trusted; pre-existing symlinks below it are
//! followed because `std` has no `openat`-style API.

use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

use flate2::read::ZlibDecoder;

use crate::apple_file_transfer::{
    EntryKind, FileTransferError, SUBTYPE_CANCEL, SUBTYPE_COMPLETE, SUBTYPE_COMPRESSED_DATA,
    SUBTYPE_DATA, SUBTYPE_ENTRY, SUBTYPE_SUMMARY, Summary, parse_entry, parse_summary,
};

/// Size of the `0x67` header before the zlib stream.
pub const COMPRESSED_HEADER_LEN: usize = 10;

/// Upper bound for one inflated `0x67` chunk. Servers send 64 KiB chunks; the
/// slack covers implementations that coalesce several chunks.
pub const MAX_DECOMPRESSED_CHUNK: u32 = 8 * 1024 * 1024;

/// Where the transfer is in its lifecycle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DownloadState {
    /// Waiting for the `0x64` summary.
    AwaitingSummary,
    /// Summary seen, entries and data are being received.
    Receiving,
    /// `0x68` was received and all files were closed.
    Completed,
    /// The server sent `0x05` (or the caller cancelled).
    Cancelled,
    /// A message was rejected; no further messages are processed.
    Failed,
}

/// Snapshot returned when the transfer completes.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct DownloadStats {
    /// Fully written files (main fork complete).
    pub files: u32,
    /// Directories actually created below the root.
    pub directories: u32,
    /// Symlink entries that were reported but not recreated.
    pub symlinks_skipped: u32,
    /// Main-fork bytes written (resource forks are not persisted).
    pub bytes_written: u64,
}

/// Progress callback payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DownloadProgress {
    /// Path relative to the transfer root, with `/` separators.
    pub name: String,
    /// Bytes written for the current file's main fork.
    pub file_bytes: u64,
    /// Bytes received for the whole transfer (including any resource fork).
    pub transfer_bytes: u64,
    /// `total data` from the `0x64` summary, or 0 when unknown.
    pub total_bytes: u64,
}

/// Result of one accepted container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DownloadEvent {
    Summary(Summary),
    EntryStarted {
        /// Path relative to the transfer root.
        path: PathBuf,
        kind: EntryKind,
        size: u64,
    },
    DataReceived {
        /// Path relative to the transfer root.
        path: PathBuf,
        /// Bytes carried by this message (after inflation for `0x67`).
        bytes: u64,
    },
    SymlinkSkipped {
        /// Path relative to the transfer root.
        path: PathBuf,
    },
    Completed(DownloadStats),
    Cancelled,
}

/// Errors raised by the download state machine.
#[derive(Debug)]
pub enum DownloadError {
    WrongHandle {
        expected: u32,
        received: u32,
    },
    MissingSummary,
    DuplicateSummary,
    UnexpectedSubtype(u16),
    NoCurrentFile,
    TruncatedPayload,
    BadDataLength,
    UnsafeName(String),
    BadNesting {
        nesting: u16,
        depth: usize,
    },
    Compression,
    DecompressedSizeMismatch {
        expected: u32,
        actual: usize,
    },
    DecompressedChunkTooLarge(u32),
    IncompleteFile {
        path: PathBuf,
        expected: u64,
        written: u64,
    },
    TransferFinished,
    TransferCancelled,
    TransferFailed,
    Codec(FileTransferError),
    Io(std::io::Error),
}

impl fmt::Display for DownloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::WrongHandle { expected, received } => write!(
                f,
                "container handle {received:#010x} does not match transfer handle {expected:#010x}"
            ),
            Self::MissingSummary => f.write_str("entry or data before summary"),
            Self::DuplicateSummary => f.write_str("duplicate summary"),
            Self::UnexpectedSubtype(subtype) => {
                write!(f, "unexpected download subtype {subtype:#06x}")
            }
            Self::NoCurrentFile => f.write_str("file data without an open file"),
            Self::TruncatedPayload => f.write_str("truncated file transfer payload"),
            Self::BadDataLength => f.write_str("invalid file transfer data length"),
            Self::UnsafeName(name) => write!(f, "unsafe entry name {name:?}"),
            Self::BadNesting { nesting, depth } => {
                write!(f, "entry nesting {nesting} exceeds directory depth {depth}")
            }
            Self::Compression => f.write_str("zlib decompression failed"),
            Self::DecompressedSizeMismatch { expected, actual } => write!(
                f,
                "decompressed chunk is {actual} bytes, expected {expected}"
            ),
            Self::DecompressedChunkTooLarge(size) => {
                write!(f, "decompressed chunk size {size} exceeds limit")
            }
            Self::IncompleteFile {
                path,
                expected,
                written,
            } => write!(
                f,
                "file {} is incomplete: {written} of {expected} bytes",
                path.display()
            ),
            Self::TransferFinished => f.write_str("transfer is already complete"),
            Self::TransferCancelled => f.write_str("transfer was cancelled"),
            Self::TransferFailed => f.write_str("transfer has failed"),
            Self::Codec(error) => write!(f, "malformed file transfer message: {error}"),
            Self::Io(error) => write!(f, "I/O error: {error}"),
        }
    }
}

impl std::error::Error for DownloadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Codec(error) => Some(error),
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<FileTransferError> for DownloadError {
    fn from(error: FileTransferError) -> Self {
        Self::Codec(error)
    }
}

impl From<std::io::Error> for DownloadError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

/// File currently receiving `0x66`/`0x67` data.
struct CurrentFile {
    path: PathBuf,
    file: File,
    /// Expected main-fork size from the `0x65` entry.
    expected: u64,
    /// Main-fork bytes written so far.
    written: u64,
}

type ProgressHandler = Box<dyn FnMut(&DownloadProgress) + Send>;

/// Download (drag-out) state machine for one `0x22` handle.
pub struct DownloadTransfer {
    root: PathBuf,
    handle: Option<u32>,
    state: DownloadState,
    summary: Option<Summary>,
    /// Directory names for the current nesting level.
    stack: Vec<String>,
    current: Option<CurrentFile>,
    stats: DownloadStats,
    bytes_received: u64,
    progress: Option<ProgressHandler>,
}

impl DownloadTransfer {
    /// Creates a transfer that writes below `root`. The directory is created
    /// lazily when the first entry (or completion) arrives.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            handle: None,
            state: DownloadState::AwaitingSummary,
            summary: None,
            stack: Vec::new(),
            current: None,
            stats: DownloadStats::default(),
            bytes_received: 0,
            progress: None,
        }
    }

    /// Convenience constructor with a progress callback.
    pub fn with_progress<F>(root: impl Into<PathBuf>, progress: F) -> Self
    where
        F: FnMut(&DownloadProgress) + Send + 'static,
    {
        let mut transfer = Self::new(root);
        transfer.set_progress(progress);
        transfer
    }

    /// Installs (or replaces) the progress callback.
    pub fn set_progress<F>(&mut self, progress: F)
    where
        F: FnMut(&DownloadProgress) + Send + 'static,
    {
        self.progress = Some(Box::new(progress));
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Handle bound by the first container, if any.
    pub fn handle(&self) -> Option<u32> {
        self.handle
    }

    pub fn state(&self) -> DownloadState {
        self.state
    }

    pub fn summary(&self) -> Option<Summary> {
        self.summary
    }

    pub fn stats(&self) -> DownloadStats {
        self.stats
    }

    pub fn bytes_received(&self) -> u64 {
        self.bytes_received
    }

    /// Feeds one `0x22` container payload.
    ///
    /// `handle` must match the handle of the first message. On error the
    /// transfer moves to [`DownloadState::Failed`] (unless it already
    /// completed or was cancelled) and the open file is closed.
    pub fn handle_message(
        &mut self,
        subtype: u16,
        handle: u32,
        payload: &[u8],
    ) -> Result<DownloadEvent, DownloadError> {
        let result = self.handle_message_inner(subtype, handle, payload);
        if result.is_err()
            && !matches!(
                self.state,
                DownloadState::Completed | DownloadState::Cancelled
            )
        {
            self.current = None;
            self.state = DownloadState::Failed;
        }
        result
    }

    fn handle_message_inner(
        &mut self,
        subtype: u16,
        handle: u32,
        payload: &[u8],
    ) -> Result<DownloadEvent, DownloadError> {
        match self.state {
            DownloadState::Completed => return Err(DownloadError::TransferFinished),
            DownloadState::Cancelled => return Err(DownloadError::TransferCancelled),
            DownloadState::Failed => return Err(DownloadError::TransferFailed),
            DownloadState::AwaitingSummary | DownloadState::Receiving => {}
        }
        match self.handle {
            None => self.handle = Some(handle),
            Some(expected) if expected == handle => {}
            Some(expected) => {
                return Err(DownloadError::WrongHandle {
                    expected,
                    received: handle,
                });
            }
        }
        match subtype {
            SUBTYPE_CANCEL => self.cancel_message(),
            SUBTYPE_SUMMARY => self.summary_message(payload),
            SUBTYPE_ENTRY => self.entry_message(payload),
            SUBTYPE_DATA => self.data_message(payload),
            SUBTYPE_COMPRESSED_DATA => self.compressed_message(payload),
            SUBTYPE_COMPLETE => self.complete_message(payload),
            other => Err(DownloadError::UnexpectedSubtype(other)),
        }
    }

    fn summary_message(&mut self, payload: &[u8]) -> Result<DownloadEvent, DownloadError> {
        if self.summary.is_some() {
            return Err(DownloadError::DuplicateSummary);
        }
        let summary = parse_summary(payload)?;
        self.summary = Some(summary);
        self.state = DownloadState::Receiving;
        Ok(DownloadEvent::Summary(summary))
    }

    fn entry_message(&mut self, payload: &[u8]) -> Result<DownloadEvent, DownloadError> {
        self.require_summary()?;
        let entry = parse_entry(payload)?;
        validate_name(&entry.name)?;
        let depth = entry.nesting as usize;
        if depth > self.stack.len() {
            return Err(DownloadError::BadNesting {
                nesting: entry.nesting,
                depth: self.stack.len(),
            });
        }
        self.finish_current()?;
        self.stack.truncate(depth);
        let relative = self.relative_path(&entry.name);
        match entry.kind {
            EntryKind::File => self.start_file(relative, entry.data_size),
            EntryKind::Directory => {
                self.create_directory(&relative)?;
                self.stack.push(entry.name);
                Ok(DownloadEvent::EntryStarted {
                    path: relative,
                    kind: EntryKind::Directory,
                    size: 0,
                })
            }
            EntryKind::Symlink => {
                self.stats.symlinks_skipped += 1;
                Ok(DownloadEvent::SymlinkSkipped { path: relative })
            }
        }
    }

    fn data_message(&mut self, payload: &[u8]) -> Result<DownloadEvent, DownloadError> {
        self.require_summary()?;
        if payload.len() < 4 {
            return Err(DownloadError::TruncatedPayload);
        }
        let length = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
        if length > payload.len() - 4 {
            return Err(DownloadError::BadDataLength);
        }
        self.write_data(&payload[4..4 + length])
    }

    fn compressed_message(&mut self, payload: &[u8]) -> Result<DownloadEvent, DownloadError> {
        self.require_summary()?;
        if payload.len() < COMPRESSED_HEADER_LEN {
            return Err(DownloadError::TruncatedPayload);
        }
        let expected = u32::from_be_bytes([payload[2], payload[3], payload[4], payload[5]]);
        let compressed_len =
            u32::from_be_bytes([payload[6], payload[7], payload[8], payload[9]]) as usize;
        let end = COMPRESSED_HEADER_LEN
            .checked_add(compressed_len)
            .ok_or(DownloadError::BadDataLength)?;
        if end > payload.len() {
            return Err(DownloadError::BadDataLength);
        }
        if expected > MAX_DECOMPRESSED_CHUNK {
            return Err(DownloadError::DecompressedChunkTooLarge(expected));
        }
        let mut inflated = Vec::with_capacity(expected as usize);
        ZlibDecoder::new(&payload[COMPRESSED_HEADER_LEN..end])
            .take(u64::from(expected) + 1)
            .read_to_end(&mut inflated)
            .map_err(|_| DownloadError::Compression)?;
        if inflated.len() != expected as usize {
            return Err(DownloadError::DecompressedSizeMismatch {
                expected,
                actual: inflated.len(),
            });
        }
        self.write_data(&inflated)
    }

    fn complete_message(&mut self, payload: &[u8]) -> Result<DownloadEvent, DownloadError> {
        self.require_summary()?;
        if !payload.is_empty() {
            return Err(DownloadError::BadDataLength);
        }
        self.finish_current()?;
        self.ensure_root()?;
        self.stack.clear();
        self.state = DownloadState::Completed;
        Ok(DownloadEvent::Completed(self.stats))
    }

    fn cancel_message(&mut self) -> Result<DownloadEvent, DownloadError> {
        self.current = None;
        self.stack.clear();
        self.state = DownloadState::Cancelled;
        Ok(DownloadEvent::Cancelled)
    }

    fn write_data(&mut self, data: &[u8]) -> Result<DownloadEvent, DownloadError> {
        let (path, written, to_write) = {
            let current = self.current.as_mut().ok_or(DownloadError::NoCurrentFile)?;
            let remaining = current.expected.saturating_sub(current.written);
            let to_write = remaining.min(data.len() as u64) as usize;
            if to_write > 0 {
                current.file.write_all(&data[..to_write])?;
                current.written += to_write as u64;
            }
            (current.path.clone(), current.written, to_write)
        };
        self.stats.bytes_written += to_write as u64;
        self.bytes_received += data.len() as u64;
        let progress = DownloadProgress {
            name: display_path(&path),
            file_bytes: written,
            transfer_bytes: self.bytes_received,
            total_bytes: self.total_bytes(),
        };
        self.emit_progress(progress);
        Ok(DownloadEvent::DataReceived {
            path,
            bytes: data.len() as u64,
        })
    }

    fn start_file(&mut self, path: PathBuf, size: u64) -> Result<DownloadEvent, DownloadError> {
        self.ensure_parent(&path)?;
        let file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .open(self.root.join(&path))?;
        self.current = Some(CurrentFile {
            path: path.clone(),
            file,
            expected: size,
            written: 0,
        });
        let progress = DownloadProgress {
            name: display_path(&path),
            file_bytes: 0,
            transfer_bytes: self.bytes_received,
            total_bytes: self.total_bytes(),
        };
        self.emit_progress(progress);
        Ok(DownloadEvent::EntryStarted {
            path,
            kind: EntryKind::File,
            size,
        })
    }

    fn finish_current(&mut self) -> Result<(), DownloadError> {
        let Some(CurrentFile {
            path,
            mut file,
            expected,
            written,
        }) = self.current.take()
        else {
            return Ok(());
        };
        file.flush()?;
        if written != expected {
            return Err(DownloadError::IncompleteFile {
                path,
                expected,
                written,
            });
        }
        self.stats.files += 1;
        Ok(())
    }

    fn create_directory(&mut self, path: &Path) -> Result<(), DownloadError> {
        self.ensure_root()?;
        let absolute = self.root.join(path);
        let existed = absolute.is_dir();
        fs::create_dir_all(&absolute)?;
        if !existed {
            self.stats.directories += 1;
        }
        Ok(())
    }

    fn ensure_root(&self) -> Result<(), DownloadError> {
        fs::create_dir_all(&self.root)?;
        Ok(())
    }

    fn ensure_parent(&self, path: &Path) -> Result<(), DownloadError> {
        self.ensure_root()?;
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            fs::create_dir_all(self.root.join(parent))?;
        }
        Ok(())
    }

    fn relative_path(&self, name: &str) -> PathBuf {
        let mut path = PathBuf::new();
        for part in &self.stack {
            path.push(part);
        }
        path.push(name);
        path
    }

    fn require_summary(&self) -> Result<(), DownloadError> {
        if self.summary.is_some() {
            Ok(())
        } else {
            Err(DownloadError::MissingSummary)
        }
    }

    fn total_bytes(&self) -> u64 {
        self.summary.map_or(0, |summary| summary.total_bytes)
    }

    fn emit_progress(&mut self, progress: DownloadProgress) {
        if let Some(handler) = self.progress.as_mut() {
            handler(&progress);
        }
    }
}

/// Rejects names that are not exactly one normal path component.
fn validate_name(name: &str) -> Result<(), DownloadError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.chars().any(char::is_control)
    {
        return Err(DownloadError::UnsafeName(name.to_string()));
    }
    let mut components = Path::new(name).components();
    match (components.next(), components.next()) {
        (Some(Component::Normal(component)), None) if component.to_str() == Some(name) => Ok(()),
        _ => Err(DownloadError::UnsafeName(name.to_string())),
    }
}

fn display_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::apple_file_transfer::{
        Container, Entry, SUBTYPE_COMPRESSED_DATA, SUBTYPE_DATA, SUBTYPE_ENTRY, SUBTYPE_SUMMARY,
        transfer_cancel, upload_complete, upload_data, upload_entry, upload_summary,
    };
    use flate2::Compression;
    use flate2::write::ZlibEncoder;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::{Arc, Mutex};

    const HANDLE: u32 = 7;

    static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

    struct TestDir(PathBuf);

    impl TestDir {
        fn new() -> Self {
            let unique = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let path = std::env::temp_dir().join(format!(
                "openscreens-download-{}-{unique}-{nanos}",
                std::process::id()
            ));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TestDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn mode_for(kind: EntryKind) -> u16 {
        match kind {
            EntryKind::File => 0o100_644,
            EntryKind::Directory => 0o040_755,
            EntryKind::Symlink => 0o120_777,
        }
    }

    fn entry_container(kind: EntryKind, name: &str, size: u64, nesting: u16) -> Container {
        let entry = Entry {
            kind,
            name,
            data_size: size,
            resource_size: 0,
            mode: mode_for(kind),
            nesting,
            created: 0,
            accessed: 0,
            changed: 0,
            modified: 0,
            finder_info: [0; 32],
            link_target: if kind == EntryKind::Symlink {
                Some("target")
            } else {
                None
            },
        };
        upload_entry(HANDLE, &entry).unwrap()
    }

    /// Encodes a `0x65` payload without the `/` -> `:` rewrite, so unsafe names
    /// reach the state machine byte-for-byte.
    fn raw_entry_container(kind: EntryKind, name: &str, size: u64, nesting: u16) -> Container {
        let mut payload = vec![0u8; 104];
        payload[0] = match kind {
            EntryKind::File => 1,
            EntryKind::Directory => 2,
            EntryKind::Symlink => 3,
        };
        payload[0x22..0x2a].copy_from_slice(&0u64.to_be_bytes());
        payload[0x2a..0x32].copy_from_slice(&size.to_be_bytes());
        let marker: u32 = if kind == EntryKind::File { 0 } else { 0x10 };
        payload[0x58..0x5c].copy_from_slice(&marker.to_be_bytes());
        payload[0x5c..0x5e].copy_from_slice(&nesting.to_be_bytes());
        payload[0x5e..0x60].copy_from_slice(&mode_for(kind).to_be_bytes());
        payload[0x64..0x66].copy_from_slice(&(name.len() as u16).to_be_bytes());
        payload[0x66..0x68].copy_from_slice(&0u16.to_be_bytes());
        payload.extend_from_slice(name.as_bytes());
        payload.push(0);
        Container {
            subtype: SUBTYPE_ENTRY,
            handle: HANDLE,
            payload,
        }
    }

    fn push(
        transfer: &mut DownloadTransfer,
        container: Container,
    ) -> Result<DownloadEvent, DownloadError> {
        transfer.handle_message(container.subtype, container.handle, &container.payload)
    }

    fn compressed_payload(data: &[u8], expected: u32) -> Vec<u8> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data).unwrap();
        let compressed = encoder.finish().unwrap();
        let mut payload = Vec::with_capacity(COMPRESSED_HEADER_LEN + compressed.len());
        payload.extend_from_slice(&[0, 0]);
        payload.extend_from_slice(&expected.to_be_bytes());
        payload.extend_from_slice(&(compressed.len() as u32).to_be_bytes());
        payload.extend_from_slice(&compressed);
        payload
    }

    #[test]
    fn downloads_two_files_and_a_subdirectory() {
        let dir = TestDir::new();
        let seen = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&seen);
        let mut transfer = DownloadTransfer::with_progress(dir.path(), move |progress| {
            sink.lock().unwrap().push(progress.clone());
        });

        let total = 5 + 7;
        let event = push(&mut transfer, upload_summary(HANDLE, total, 2, 1)).unwrap();
        assert_eq!(
            event,
            DownloadEvent::Summary(Summary {
                total_bytes: total,
                files: 2,
                directories: 1,
            })
        );
        assert_eq!(transfer.state(), DownloadState::Receiving);

        let event = push(
            &mut transfer,
            entry_container(EntryKind::Directory, "sub", 0, 0),
        )
        .unwrap();
        assert_eq!(
            event,
            DownloadEvent::EntryStarted {
                path: PathBuf::from("sub"),
                kind: EntryKind::Directory,
                size: 0,
            }
        );

        push(
            &mut transfer,
            entry_container(EntryKind::File, "b.txt", 7, 1),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"nested!").unwrap()).unwrap();

        push(
            &mut transfer,
            entry_container(EntryKind::File, "a.txt", 5, 0),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"hello").unwrap()).unwrap();

        let event = push(&mut transfer, upload_complete(HANDLE)).unwrap();
        assert_eq!(
            event,
            DownloadEvent::Completed(DownloadStats {
                files: 2,
                directories: 1,
                symlinks_skipped: 0,
                bytes_written: 12,
            })
        );
        assert_eq!(transfer.state(), DownloadState::Completed);
        assert_eq!(transfer.summary().unwrap().total_bytes, 12);

        assert_eq!(fs::read(dir.path().join("a.txt")).unwrap(), b"hello");
        assert_eq!(
            fs::read(dir.path().join("sub").join("b.txt")).unwrap(),
            b"nested!"
        );
        assert!(dir.path().join("sub").is_dir());

        let seen = seen.lock().unwrap();
        let names: Vec<&str> = seen.iter().map(|progress| progress.name.as_str()).collect();
        assert!(names.contains(&"a.txt"));
        assert!(names.contains(&"sub/b.txt"));
        let last = seen.last().unwrap();
        assert_eq!(last.transfer_bytes, 12);
        assert_eq!(last.total_bytes, 12);
        assert_eq!(last.file_bytes, 5);
    }

    #[test]
    fn inflates_zlib_chunks() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        let data = b"compress me ".repeat(400);
        let total = data.len() as u64;
        push(&mut transfer, upload_summary(HANDLE, total, 1, 0)).unwrap();
        push(
            &mut transfer,
            entry_container(EntryKind::File, "z.txt", total, 0),
        )
        .unwrap();

        let payload = compressed_payload(&data, total as u32);
        let event = transfer
            .handle_message(SUBTYPE_COMPRESSED_DATA, HANDLE, &payload)
            .unwrap();
        assert!(matches!(event, DownloadEvent::DataReceived { .. }));
        assert_eq!(fs::read(dir.path().join("z.txt")).unwrap(), data);

        push(&mut transfer, upload_complete(HANDLE)).unwrap();
        assert_eq!(transfer.state(), DownloadState::Completed);

        let mut bad = DownloadTransfer::new(dir.path().join("bad"));
        push(&mut bad, upload_summary(HANDLE, total, 1, 0)).unwrap();
        push(
            &mut bad,
            entry_container(EntryKind::File, "z.txt", total, 0),
        )
        .unwrap();
        let wrong_size = compressed_payload(&data, total as u32 + 1);
        assert!(matches!(
            bad.handle_message(SUBTYPE_COMPRESSED_DATA, HANDLE, &wrong_size),
            Err(DownloadError::DecompressedSizeMismatch { .. })
        ));
        assert_eq!(bad.state(), DownloadState::Failed);

        let mut short = DownloadTransfer::new(dir.path().join("short"));
        push(&mut short, upload_summary(HANDLE, total, 1, 0)).unwrap();
        push(
            &mut short,
            entry_container(EntryKind::File, "z.txt", total, 0),
        )
        .unwrap();
        let truncated = &compressed_payload(&data, total as u32)[..COMPRESSED_HEADER_LEN - 1];
        assert!(matches!(
            short.handle_message(SUBTYPE_COMPRESSED_DATA, HANDLE, truncated),
            Err(DownloadError::TruncatedPayload)
        ));
    }

    #[test]
    fn rejects_path_traversal_and_control_characters() {
        let dir = TestDir::new();
        let root_name = dir
            .path()
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        let escaped = format!("{root_name}-escape");
        let traversal = format!("../{escaped}");
        let names = [
            traversal.as_str(),
            "/etc/passwd",
            "a/b",
            "a\\b",
            "..",
            ".",
            "",
            "bad\0name",
            "bad\nname",
        ];

        for name in names {
            let mut transfer = DownloadTransfer::new(dir.path());
            push(&mut transfer, upload_summary(HANDLE, 0, 1, 0)).unwrap();
            let result = push(
                &mut transfer,
                raw_entry_container(EntryKind::File, name, 0, 0),
            );
            assert!(
                matches!(result, Err(DownloadError::UnsafeName(_))),
                "name {name:?} was accepted"
            );
            assert_eq!(transfer.state(), DownloadState::Failed);
        }

        assert!(!dir.path().parent().unwrap().join(escaped).exists());
    }

    #[test]
    fn colon_remains_one_file_name() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        push(&mut transfer, upload_summary(HANDLE, 1, 1, 0)).unwrap();
        push(
            &mut transfer,
            raw_entry_container(EntryKind::File, "a:b", 1, 0),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"x").unwrap()).unwrap();
        push(&mut transfer, upload_complete(HANDLE)).unwrap();

        assert_eq!(fs::read(dir.path().join("a:b")).unwrap(), b"x");
        assert!(!dir.path().join("a").exists());
    }

    #[test]
    fn symlinks_are_skipped() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        push(&mut transfer, upload_summary(HANDLE, 0, 0, 0)).unwrap();
        let event = push(
            &mut transfer,
            entry_container(EntryKind::Symlink, "link", 0, 0),
        )
        .unwrap();
        assert_eq!(
            event,
            DownloadEvent::SymlinkSkipped {
                path: PathBuf::from("link"),
            }
        );
        push(&mut transfer, upload_complete(HANDLE)).unwrap();

        assert_eq!(transfer.state(), DownloadState::Completed);
        assert_eq!(transfer.stats().symlinks_skipped, 1);
        assert!(!dir.path().join("link").exists());
    }

    #[test]
    fn completion_finishes_the_transfer() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        push(&mut transfer, upload_summary(HANDLE, 5, 1, 0)).unwrap();
        push(
            &mut transfer,
            entry_container(EntryKind::File, "done.txt", 5, 0),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"hello").unwrap()).unwrap();
        let event = push(&mut transfer, upload_complete(HANDLE)).unwrap();

        assert_eq!(
            event,
            DownloadEvent::Completed(DownloadStats {
                files: 1,
                directories: 0,
                symlinks_skipped: 0,
                bytes_written: 5,
            })
        );
        assert_eq!(transfer.state(), DownloadState::Completed);
        assert_eq!(transfer.stats().files, 1);

        let late = transfer.handle_message(SUBTYPE_DATA, HANDLE, &[0, 0, 0, 0]);
        assert!(matches!(late, Err(DownloadError::TransferFinished)));
        assert_eq!(transfer.state(), DownloadState::Completed);
    }

    #[test]
    fn completion_rejects_short_files() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        push(&mut transfer, upload_summary(HANDLE, 5, 1, 0)).unwrap();
        push(
            &mut transfer,
            entry_container(EntryKind::File, "short.txt", 5, 0),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"hi").unwrap()).unwrap();

        let result = push(&mut transfer, upload_complete(HANDLE));
        assert!(matches!(result, Err(DownloadError::IncompleteFile { .. })));
        assert_eq!(transfer.state(), DownloadState::Failed);
    }

    #[test]
    fn cancel_stops_the_transfer() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        push(&mut transfer, upload_summary(HANDLE, 10, 1, 0)).unwrap();
        push(
            &mut transfer,
            entry_container(EntryKind::File, "part.txt", 10, 0),
        )
        .unwrap();
        push(&mut transfer, upload_data(HANDLE, b"abc").unwrap()).unwrap();

        let event = push(&mut transfer, transfer_cancel(HANDLE)).unwrap();
        assert_eq!(event, DownloadEvent::Cancelled);
        assert_eq!(transfer.state(), DownloadState::Cancelled);
        assert_eq!(fs::read(dir.path().join("part.txt")).unwrap(), b"abc");

        let late = transfer.handle_message(SUBTYPE_DATA, HANDLE, &[0, 0, 0, 0]);
        assert!(matches!(late, Err(DownloadError::TransferCancelled)));
        assert_eq!(transfer.state(), DownloadState::Cancelled);
    }

    #[test]
    fn rejects_foreign_handles() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        let summary = upload_summary(HANDLE, 0, 0, 0);
        let event = transfer
            .handle_message(SUBTYPE_SUMMARY, HANDLE, &summary.payload)
            .unwrap();
        assert!(matches!(event, DownloadEvent::Summary(_)));

        let error = transfer
            .handle_message(SUBTYPE_SUMMARY, HANDLE + 1, &summary.payload)
            .unwrap_err();
        assert!(matches!(
            error,
            DownloadError::WrongHandle {
                expected: HANDLE,
                received: 8
            }
        ));
    }

    #[test]
    fn rejects_malformed_messages() {
        let dir = TestDir::new();
        let mut transfer = DownloadTransfer::new(dir.path());
        let result = transfer.handle_message(SUBTYPE_SUMMARY, HANDLE, &[]);
        assert!(matches!(
            result,
            Err(DownloadError::Codec(FileTransferError::Truncated))
        ));
        assert_eq!(transfer.state(), DownloadState::Failed);

        let mut truncated = DownloadTransfer::new(dir.path().join("truncated"));
        push(&mut truncated, upload_summary(HANDLE, 0, 0, 0)).unwrap();
        assert!(matches!(
            truncated.handle_message(SUBTYPE_DATA, HANDLE, &[0, 0, 0]),
            Err(DownloadError::TruncatedPayload)
        ));

        let mut empty = DownloadTransfer::new(dir.path().join("empty"));
        push(&mut empty, upload_summary(HANDLE, 0, 0, 0)).unwrap();
        let zero_length = [0, 0, 0, 0];
        assert!(matches!(
            empty.handle_message(SUBTYPE_DATA, HANDLE, &zero_length),
            Err(DownloadError::NoCurrentFile)
        ));
    }
}
