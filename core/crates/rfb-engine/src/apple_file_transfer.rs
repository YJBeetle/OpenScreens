//! Apple drag-and-drop file transfer messages (RFB 3.889 vendor extension).
//!
//! Layouts are verified against a live Screens 5 session talking to a macOS
//! Screen Sharing server. The reverse-engineering notes live in
//! `var/research/file-transfer.md`.

use std::fmt;
use std::io::{Read, Write};

use flate2::Compression;
use flate2::read::DeflateDecoder;
use flate2::write::DeflateEncoder;

pub const MSG_DRAG_OUT_START: u8 = 0x0E;
pub const MSG_UPLOAD_REQUEST: u8 = 0x1E;
pub const MSG_DRAG_INFO: u8 = 0x20;
pub const MSG_FILE_TRANSFER: u8 = 0x22;

pub const SUBTYPE_DOWNLOAD_REQUEST: u16 = 0x0001;
pub const SUBTYPE_UPLOAD_DESTINATION: u16 = 0x0002;
pub const SUBTYPE_CANCEL: u16 = 0x0005;
pub const SUBTYPE_SUMMARY: u16 = 0x0064;
pub const SUBTYPE_ENTRY: u16 = 0x0065;
pub const SUBTYPE_DATA: u16 = 0x0066;
pub const SUBTYPE_COMPRESSED_DATA: u16 = 0x0067;
pub const SUBTYPE_COMPLETE: u16 = 0x0068;
pub const SUBTYPE_PROGRESS: u16 = 0x00C8;
pub const SUBTYPE_ACK: u16 = 0x012C;

pub const MAX_DATA_CHUNK: usize = 64 * 1024;
/// Seconds between the Unix and the 1904 (HFS) epochs.
pub const EPOCH_1904_OFFSET: u64 = 2_082_844_800;

const CONTAINER_HEADER: usize = 14;
const CONTAINER_VERSION: u16 = 0x0001;
const ENTRY_FIXED: usize = 104;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileTransferError {
    Truncated,
    BadType(u8),
    BadVersion(u16),
    BadLength,
    BadUtf8,
    Compression,
}

impl fmt::Display for FileTransferError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Truncated => write!(f, "truncated file transfer message"),
            Self::BadType(t) => write!(f, "unexpected message type {t:#04x}"),
            Self::BadVersion(v) => write!(f, "unexpected container version {v:#06x}"),
            Self::BadLength => write!(f, "invalid file transfer length"),
            Self::BadUtf8 => write!(f, "invalid UTF-8 in file transfer message"),
            Self::Compression => write!(f, "pasteboard compression error"),
        }
    }
}

impl std::error::Error for FileTransferError {}

/// A message 34 (`0x22`) container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Container {
    pub subtype: u16,
    pub handle: u32,
    pub payload: Vec<u8>,
}

impl Container {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(CONTAINER_HEADER + self.payload.len());
        out.push(MSG_FILE_TRANSFER);
        out.push(0);
        out.extend_from_slice(&(8u32 + self.payload.len() as u32).to_be_bytes());
        out.extend_from_slice(&CONTAINER_VERSION.to_be_bytes());
        out.extend_from_slice(&self.subtype.to_be_bytes());
        out.extend_from_slice(&self.handle.to_be_bytes());
        out.extend_from_slice(&self.payload);
        out
    }

    /// Consumes one container and returns it with the number of bytes used.
    pub fn parse(buf: &[u8]) -> Result<(Self, usize), FileTransferError> {
        if buf.len() < CONTAINER_HEADER {
            return Err(FileTransferError::Truncated);
        }
        if buf[0] != MSG_FILE_TRANSFER {
            return Err(FileTransferError::BadType(buf[0]));
        }
        let length = u32::from_be_bytes([buf[2], buf[3], buf[4], buf[5]]) as usize;
        let total = length.checked_add(6).ok_or(FileTransferError::BadLength)?;
        if total < CONTAINER_HEADER || total > buf.len() {
            return Err(FileTransferError::Truncated);
        }
        let version = u16::from_be_bytes([buf[6], buf[7]]);
        if version != CONTAINER_VERSION {
            return Err(FileTransferError::BadVersion(version));
        }
        let subtype = u16::from_be_bytes([buf[8], buf[9]]);
        let handle = u32::from_be_bytes([buf[10], buf[11], buf[12], buf[13]]);
        Ok((
            Self {
                subtype,
                handle,
                payload: buf[CONTAINER_HEADER..total].to_vec(),
            },
            total,
        ))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Summary {
    pub total_bytes: u64,
    pub files: u32,
    pub directories: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryKind {
    File,
    Directory,
    Symlink,
}

impl EntryKind {
    fn wire(self) -> u8 {
        match self {
            Self::File => 1,
            Self::Directory => 2,
            Self::Symlink => 3,
        }
    }

    fn from_wire(value: u8) -> Result<Self, FileTransferError> {
        match value {
            1 => Ok(Self::File),
            2 => Ok(Self::Directory),
            3 => Ok(Self::Symlink),
            other => Err(FileTransferError::BadType(other)),
        }
    }
}

/// An entry description to upload.
#[derive(Debug, Clone)]
pub struct Entry<'a> {
    pub kind: EntryKind,
    pub name: &'a str,
    pub data_size: u64,
    pub resource_size: u64,
    pub mode: u16,
    pub nesting: u16,
    /// 1904-epoch seconds; use [`timestamp_1904`] to convert.
    pub created: u32,
    pub accessed: u32,
    pub changed: u32,
    pub modified: u32,
    pub finder_info: [u8; 32],
    pub link_target: Option<&'a str>,
}

/// A decoded entry description (server to client during downloads).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EntryInfo {
    pub kind: EntryKind,
    pub name: String,
    pub data_size: u64,
    pub resource_size: u64,
    pub mode: u16,
    pub nesting: u16,
    pub created: u32,
    pub accessed: u32,
    pub changed: u32,
    pub modified: u32,
    pub finder_info: [u8; 32],
    pub link_target: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Progress {
    Ratio(f64),
    Name(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UploadRequest {
    pub handle: u32,
    pub path: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DragInfo {
    pub handle: u32,
    pub pasteboard: Vec<u8>,
}

pub fn timestamp_1904(unix_seconds: u64) -> u32 {
    u32::try_from(unix_seconds.saturating_add(EPOCH_1904_OFFSET)).unwrap_or(u32::MAX)
}

/// Destination folder announcement (`0x22/0x0002`).
pub fn upload_destination(handle: u32, folder: &str) -> Container {
    let mut payload = Vec::with_capacity(11 + folder.len());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(&(folder.len() as u32).to_be_bytes());
    payload.extend_from_slice(folder.as_bytes());
    payload.push(0);
    Container {
        subtype: SUBTYPE_UPLOAD_DESTINATION,
        handle,
        payload,
    }
}

/// Summary message (`0x22/0x0064`) for an upload of `files` top-level entries.
pub fn upload_summary(handle: u32, total_bytes: u64, files: u32, directories: u32) -> Container {
    let mut payload = Vec::with_capacity(52);
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&total_bytes.to_be_bytes());
    payload.extend_from_slice(&total_bytes.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&files.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&files.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&directories.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    Container {
        subtype: SUBTYPE_SUMMARY,
        handle,
        payload,
    }
}

/// Entry description (`0x22/0x0065`).
pub fn upload_entry(handle: u32, entry: &Entry<'_>) -> Result<Container, FileTransferError> {
    let name = entry.name.replace('/', ":");
    let link = entry
        .link_target
        .map(|target| target.replace('/', ":"))
        .unwrap_or_default();
    let name_bytes = name.as_bytes();
    let link_bytes = link.as_bytes();
    let name_len = u16::try_from(name_bytes.len()).map_err(|_| FileTransferError::BadLength)?;
    let link_len = u16::try_from(link_bytes.len().saturating_sub(1))
        .map_err(|_| FileTransferError::BadLength)?;

    let data_size = if entry.kind == EntryKind::Symlink {
        link_bytes.len() as u64
    } else {
        entry.data_size
    };

    let mut payload = Vec::with_capacity(ENTRY_FIXED + 1 + name_bytes.len() + link_bytes.len());
    payload.push(entry.kind.wire());
    payload.push(0);
    payload.extend_from_slice(&entry.finder_info);
    payload.extend_from_slice(&entry.resource_size.to_be_bytes());
    payload.extend_from_slice(&data_size.to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(&entry.created.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&entry.accessed.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&entry.changed.to_be_bytes());
    payload.extend_from_slice(&0u32.to_be_bytes());
    payload.extend_from_slice(&entry.modified.to_be_bytes());
    payload.extend_from_slice(&0u64.to_be_bytes());
    let marker: u32 = if entry.kind == EntryKind::File {
        0
    } else {
        0x10
    };
    payload.extend_from_slice(&marker.to_be_bytes());
    payload.extend_from_slice(&entry.nesting.to_be_bytes());
    payload.extend_from_slice(&entry.mode.to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(&name_len.to_be_bytes());
    payload.extend_from_slice(&link_len.to_be_bytes());
    payload.extend_from_slice(name_bytes);
    payload.push(0);
    if entry.kind == EntryKind::Symlink {
        payload.extend_from_slice(link_bytes);
    }
    Ok(Container {
        subtype: SUBTYPE_ENTRY,
        handle,
        payload,
    })
}

/// Raw data chunk (`0x22/0x0066`).
pub fn upload_data(handle: u32, chunk: &[u8]) -> Result<Container, FileTransferError> {
    if chunk.len() > MAX_DATA_CHUNK {
        return Err(FileTransferError::BadLength);
    }
    let mut payload = Vec::with_capacity(4 + chunk.len());
    payload.extend_from_slice(&(chunk.len() as u32).to_be_bytes());
    payload.extend_from_slice(chunk);
    Ok(Container {
        subtype: SUBTYPE_DATA,
        handle,
        payload,
    })
}

/// Completion (`0x22/0x0068`).
pub fn upload_complete(handle: u32) -> Container {
    Container {
        subtype: SUBTYPE_COMPLETE,
        handle,
        payload: Vec::new(),
    }
}

/// Cancel or abort (`0x22/0x0005`).
pub fn transfer_cancel(handle: u32) -> Container {
    Container {
        subtype: SUBTYPE_CANCEL,
        handle,
        payload: Vec::new(),
    }
}

/// Request a remote file (`0x22/0x0001`).
pub fn download_request(handle: u32, path: &str) -> Container {
    let mut payload = Vec::with_capacity(11 + path.len());
    payload.extend_from_slice(&1u32.to_be_bytes());
    payload.extend_from_slice(&0u16.to_be_bytes());
    payload.extend_from_slice(&(path.len() as u32).to_be_bytes());
    payload.extend_from_slice(path.as_bytes());
    payload.push(0);
    Container {
        subtype: SUBTYPE_DOWNLOAD_REQUEST,
        handle,
        payload,
    }
}

/// Start of a drag-out sequence (message 14), asking the server for the remote
/// pasteboard so the user can drag files from the remote desktop.
pub fn drag_out_start(handle: u32) -> Vec<u8> {
    let mut out = Vec::with_capacity(8);
    out.push(MSG_DRAG_OUT_START);
    out.extend_from_slice(&[0, 0, 0]);
    out.extend_from_slice(&handle.to_be_bytes());
    out
}

/// Drag-in announcement (message 32): compressed pasteboard with file URLs.
pub fn drag_in_message(handle: u32, file_urls: &[&str]) -> Vec<u8> {
    let pasteboard = pasteboard_file_urls(file_urls);
    let compressed = deflate(&pasteboard);
    let mut out = Vec::with_capacity(16 + 2 + compressed.len());
    out.push(MSG_DRAG_INFO);
    out.extend_from_slice(&[0, 0, 0]);
    out.extend_from_slice(&handle.to_be_bytes());
    out.extend_from_slice(&(pasteboard.len() as u32).to_be_bytes());
    out.extend_from_slice(&((2 + compressed.len()) as u32).to_be_bytes());
    out.extend_from_slice(&[0x78, 0xDA]);
    out.extend_from_slice(&compressed);
    out
}

/// Server upload request (message 30): destination folder chosen by the server.
pub fn parse_upload_request(buf: &[u8]) -> Result<(UploadRequest, usize), FileTransferError> {
    if buf.len() < 12 {
        return Err(FileTransferError::Truncated);
    }
    if buf[0] != MSG_UPLOAD_REQUEST {
        return Err(FileTransferError::BadType(buf[0]));
    }
    let handle = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let path_len = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]) as usize;
    let end = 12usize
        .checked_add(path_len)
        .ok_or(FileTransferError::BadLength)?;
    if buf.len() < end {
        return Err(FileTransferError::Truncated);
    }
    let path = std::str::from_utf8(&buf[12..end])
        .map_err(|_| FileTransferError::BadUtf8)?
        .to_string();
    Ok((UploadRequest { handle, path }, end))
}

/// Server drag info (message 32) with a compressed pasteboard payload.
pub fn parse_drag_info(buf: &[u8]) -> Result<(DragInfo, usize), FileTransferError> {
    if buf.len() < 16 {
        return Err(FileTransferError::Truncated);
    }
    if buf[0] != MSG_DRAG_INFO {
        return Err(FileTransferError::BadType(buf[0]));
    }
    let handle = u32::from_be_bytes([buf[4], buf[5], buf[6], buf[7]]);
    let raw_len = u32::from_be_bytes([buf[8], buf[9], buf[10], buf[11]]) as usize;
    let chunk_len = u32::from_be_bytes([buf[12], buf[13], buf[14], buf[15]]) as usize;
    let end = 16usize
        .checked_add(chunk_len)
        .ok_or(FileTransferError::BadLength)?;
    if buf.len() < end {
        return Err(FileTransferError::Truncated);
    }
    let pasteboard = inflate(&buf[16..end])?;
    if pasteboard.len() != raw_len {
        return Err(FileTransferError::BadLength);
    }
    Ok((DragInfo { handle, pasteboard }, end))
}

/// `0x22/0x00C8` payload: either a progress ratio or the final remote file name.
pub fn parse_progress(payload: &[u8]) -> Result<Progress, FileTransferError> {
    if payload.len() == 8 {
        let ratio = f64::from_bits(u64::from_be_bytes(payload.try_into().unwrap()));
        return Ok(Progress::Ratio(ratio));
    }
    if payload.len() >= 4 {
        let len = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
        if 4 + len <= payload.len() {
            let mut name = &payload[4..4 + len];
            if name.last() == Some(&0) {
                name = &name[..name.len() - 1];
            }
            let name = std::str::from_utf8(name)
                .map_err(|_| FileTransferError::BadUtf8)?
                .to_string();
            return Ok(Progress::Name(name));
        }
    }
    Err(FileTransferError::BadLength)
}

/// `0x22/0x012C` payload: u32 length + UTF-8 acknowledgement text.
pub fn parse_ack(payload: &[u8]) -> Result<String, FileTransferError> {
    if payload.len() < 4 {
        return Err(FileTransferError::Truncated);
    }
    let len = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if 4 + len > payload.len() {
        return Err(FileTransferError::Truncated);
    }
    let mut text = &payload[4..4 + len];
    if text.last() == Some(&0) {
        text = &text[..text.len() - 1];
    }
    Ok(std::str::from_utf8(text)
        .map_err(|_| FileTransferError::BadUtf8)?
        .to_string())
}

pub fn parse_summary(payload: &[u8]) -> Result<Summary, FileTransferError> {
    if payload.len() < 52 {
        return Err(FileTransferError::Truncated);
    }
    let total_bytes = u64::from_be_bytes(payload[8..16].try_into().unwrap());
    let files = u32::from_be_bytes(payload[28..32].try_into().unwrap());
    let directories = u32::from_be_bytes(payload[44..48].try_into().unwrap());
    Ok(Summary {
        total_bytes,
        files,
        directories,
    })
}

pub fn parse_entry(payload: &[u8]) -> Result<EntryInfo, FileTransferError> {
    if payload.len() < ENTRY_FIXED + 1 {
        return Err(FileTransferError::Truncated);
    }
    let kind = EntryKind::from_wire(payload[0])?;
    let mut finder_info = [0u8; 32];
    finder_info.copy_from_slice(&payload[2..34]);
    let resource_size = u64::from_be_bytes(payload[0x22..0x2a].try_into().unwrap());
    let data_size = u64::from_be_bytes(payload[0x2a..0x32].try_into().unwrap());
    let created = u32::from_be_bytes(payload[0x34..0x38].try_into().unwrap());
    let accessed = u32::from_be_bytes(payload[0x3c..0x40].try_into().unwrap());
    let changed = u32::from_be_bytes(payload[0x44..0x48].try_into().unwrap());
    let modified = u32::from_be_bytes(payload[0x4c..0x50].try_into().unwrap());
    let nesting = u16::from_be_bytes(payload[0x5c..0x5e].try_into().unwrap());
    let mode = u16::from_be_bytes(payload[0x5e..0x60].try_into().unwrap());
    let name_len = u16::from_be_bytes(payload[0x64..0x66].try_into().unwrap()) as usize;
    let link_len = u16::from_be_bytes(payload[0x66..0x68].try_into().unwrap()) as usize;
    let name_end = ENTRY_FIXED
        .checked_add(name_len)
        .ok_or(FileTransferError::BadLength)?;
    if payload.len() < name_end + 1 {
        return Err(FileTransferError::Truncated);
    }
    let name = std::str::from_utf8(&payload[ENTRY_FIXED..name_end])
        .map_err(|_| FileTransferError::BadUtf8)?
        .to_string();
    let link_target = if kind == EntryKind::Symlink && link_len > 0 {
        let link_start = name_end + 1;
        let link_end = link_start
            .checked_add(link_len + 1)
            .ok_or(FileTransferError::BadLength)?;
        if payload.len() < link_end {
            return Err(FileTransferError::Truncated);
        }
        Some(
            std::str::from_utf8(&payload[link_start..link_end])
                .map_err(|_| FileTransferError::BadUtf8)?
                .to_string(),
        )
    } else {
        None
    };
    Ok(EntryInfo {
        kind,
        name,
        data_size,
        resource_size,
        mode,
        nesting,
        created,
        accessed,
        changed,
        modified,
        finder_info,
        link_target,
    })
}

/// Serialized pasteboard archive used by message 32, one item per URL.
pub fn pasteboard_file_urls(file_urls: &[&str]) -> Vec<u8> {
    let mut out = Vec::new();
    for url in file_urls {
        out.extend_from_slice(&1u32.to_be_bytes());
        out.extend_from_slice(&0x0fu32.to_be_bytes());
        out.extend_from_slice(b"public.file-url");
        out.extend_from_slice(&0u32.to_be_bytes());
        out.extend_from_slice(&1u32.to_be_bytes());
        out.extend_from_slice(&0x10u32.to_be_bytes());
        out.extend_from_slice(b"com.apple.ostype");
        out.extend_from_slice(&4u32.to_be_bytes());
        out.extend_from_slice(b"furl");
        out.extend_from_slice(&(url.len() as u32).to_be_bytes());
        out.extend_from_slice(url.as_bytes());
    }
    out
}

pub fn parse_pasteboard_file_urls(blob: &[u8]) -> Result<Vec<String>, FileTransferError> {
    let mut out = Vec::new();
    let mut pos = 0usize;
    while pos < blob.len() {
        let count = take_u32(blob, &mut pos)?;
        for _ in 0..count {
            let type_len = take_u32(blob, &mut pos)? as usize;
            let type_name = take_bytes(blob, &mut pos, type_len)?;
            let type_name = trim_nul(type_name);
            let data_len = take_u32(blob, &mut pos)? as usize;
            take_bytes(blob, &mut pos, data_len)?;
            let flavors = take_u32(blob, &mut pos)?;
            for _ in 0..flavors {
                let name_len = take_u32(blob, &mut pos)? as usize;
                take_bytes(blob, &mut pos, name_len)?;
                let flavor_len = take_u32(blob, &mut pos)? as usize;
                take_bytes(blob, &mut pos, flavor_len)?;
            }
            if type_name == b"public.file-url" {
                let url_len = take_u32(blob, &mut pos)? as usize;
                let url = take_bytes(blob, &mut pos, url_len)?;
                out.push(
                    std::str::from_utf8(url)
                        .map_err(|_| FileTransferError::BadUtf8)?
                        .to_string(),
                );
            }
        }
    }
    Ok(out)
}

fn take_u32(buf: &[u8], pos: &mut usize) -> Result<u32, FileTransferError> {
    if *pos + 4 > buf.len() {
        return Err(FileTransferError::Truncated);
    }
    let value = u32::from_be_bytes(buf[*pos..*pos + 4].try_into().unwrap());
    *pos += 4;
    Ok(value)
}

fn take_bytes<'a>(
    buf: &'a [u8],
    pos: &mut usize,
    len: usize,
) -> Result<&'a [u8], FileTransferError> {
    let end = pos.checked_add(len).ok_or(FileTransferError::BadLength)?;
    if end > buf.len() {
        return Err(FileTransferError::Truncated);
    }
    let slice = &buf[*pos..end];
    *pos = end;
    Ok(slice)
}

fn trim_nul(bytes: &[u8]) -> &[u8] {
    match bytes.last() {
        Some(0) => &bytes[..bytes.len() - 1],
        _ => bytes,
    }
}

fn deflate(data: &[u8]) -> Vec<u8> {
    let mut encoder = DeflateEncoder::new(Vec::new(), Compression::new(3));
    let _ = encoder.write_all(data);
    encoder.finish().unwrap_or_default()
}

fn inflate(data: &[u8]) -> Result<Vec<u8>, FileTransferError> {
    let body = if data.len() >= 2 && data[0] == 0x78 {
        &data[2..]
    } else {
        data
    };
    let mut out = Vec::new();
    DeflateDecoder::new(body)
        .read_to_end(&mut out)
        .map_err(|_| FileTransferError::Compression)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file_entry(name: &str) -> Entry<'_> {
        Entry {
            kind: EntryKind::File,
            name,
            data_size: 1_408_301,
            resource_size: 0,
            mode: 0o100_644,
            nesting: 0,
            created: timestamp_1904(1_782_000_000),
            accessed: timestamp_1904(1_782_000_000) + 1,
            changed: timestamp_1904(1_782_000_000) + 2,
            modified: timestamp_1904(1_782_000_000) + 1,
            finder_info: [0; 32],
            link_target: None,
        }
    }

    #[test]
    fn destination_matches_capture() {
        let folder = "/Users/example/Desktops";
        assert_eq!(folder.len(), 23);
        let message = upload_destination(3, folder).encode();
        assert_eq!(message.len(), 48);
        assert_eq!(&message[0..2], &[MSG_FILE_TRANSFER, 0]);
        assert_eq!(u32::from_be_bytes(message[2..6].try_into().unwrap()), 42);
        assert_eq!(&message[6..8], &[0, 1]);
        assert_eq!(
            u16::from_be_bytes(message[8..10].try_into().unwrap()),
            SUBTYPE_UPLOAD_DESTINATION
        );
        assert_eq!(u32::from_be_bytes(message[10..14].try_into().unwrap()), 3);
        assert_eq!(&message[14..18], &[0, 0, 0, 0]);
        assert_eq!(&message[18..20], &[0, 0]);
        assert_eq!(u32::from_be_bytes(message[20..24].try_into().unwrap()), 23);
        assert_eq!(&message[24..47], folder.as_bytes());
        assert_eq!(message[47], 0);
    }

    #[test]
    fn summary_matches_capture() {
        let message = upload_summary(3, 1_408_301, 1, 0).encode();
        assert_eq!(message.len(), 66);
        assert_eq!(u32::from_be_bytes(message[2..6].try_into().unwrap()), 60);
        assert_eq!(
            u16::from_be_bytes(message[8..10].try_into().unwrap()),
            SUBTYPE_SUMMARY
        );
        let payload = &message[14..];
        assert_eq!(u32::from_be_bytes(payload[0..4].try_into().unwrap()), 0);
        assert_eq!(u32::from_be_bytes(payload[4..8].try_into().unwrap()), 0);
        assert_eq!(
            u64::from_be_bytes(payload[8..16].try_into().unwrap()),
            1_408_301
        );
        assert_eq!(
            u64::from_be_bytes(payload[16..24].try_into().unwrap()),
            1_408_301
        );
        assert_eq!(u32::from_be_bytes(payload[28..32].try_into().unwrap()), 1);
        assert_eq!(u32::from_be_bytes(payload[36..40].try_into().unwrap()), 1);
        assert_eq!(u32::from_be_bytes(payload[44..48].try_into().unwrap()), 0);
    }

    #[test]
    fn entry_layout_matches_capture() {
        let name = "example.zip";
        assert_eq!(name.len(), 11);
        let message = upload_entry(3, &file_entry(name)).unwrap().encode();
        assert_eq!(message.len(), 130);
        assert_eq!(u32::from_be_bytes(message[2..6].try_into().unwrap()), 124);
        assert_eq!(
            u16::from_be_bytes(message[8..10].try_into().unwrap()),
            SUBTYPE_ENTRY
        );
        let payload = &message[14..];
        assert_eq!(payload[0], 1);
        assert_eq!(
            u64::from_be_bytes(payload[0x22..0x2a].try_into().unwrap()),
            0
        );
        assert_eq!(
            u64::from_be_bytes(payload[0x2a..0x32].try_into().unwrap()),
            1_408_301
        );
        assert_eq!(&payload[0x58..0x5c], &[0, 0, 0, 0]);
        assert_eq!(
            u16::from_be_bytes(payload[0x5c..0x5e].try_into().unwrap()),
            0
        );
        assert_eq!(
            u16::from_be_bytes(payload[0x5e..0x60].try_into().unwrap()),
            0o100_644
        );
        assert_eq!(
            u16::from_be_bytes(payload[0x64..0x66].try_into().unwrap()),
            11
        );
        assert_eq!(
            u16::from_be_bytes(payload[0x66..0x68].try_into().unwrap()),
            0
        );
        assert_eq!(&payload[ENTRY_FIXED..ENTRY_FIXED + 11], name.as_bytes());
        assert_eq!(payload[ENTRY_FIXED + 11], 0);
        let parsed = parse_entry(payload).unwrap();
        assert_eq!(parsed.kind, EntryKind::File);
        assert_eq!(parsed.name, name);
        assert_eq!(parsed.data_size, 1_408_301);
        assert_eq!(parsed.mode, 0o100_644);
    }

    #[test]
    fn directory_and_symlink_layout() {
        let mut directory = file_entry("folder");
        directory.kind = EntryKind::Directory;
        let message = upload_entry(7, &directory).unwrap().encode();
        assert_eq!(message[14], 2);
        assert_eq!(&message[14 + 0x58..14 + 0x5c], &[0, 0, 0, 0x10]);

        let link = Entry {
            kind: EntryKind::Symlink,
            name: "link",
            data_size: 0,
            resource_size: 0,
            mode: 0o120_777,
            nesting: 0,
            created: 0,
            accessed: 0,
            changed: 0,
            modified: 0,
            finder_info: [0; 32],
            link_target: Some("x/y"),
        };
        let message = upload_entry(8, &link).unwrap().encode();
        assert_eq!(message[14], 3);
        assert_eq!(&message[14 + 0x58..14 + 0x5c], &[0, 0, 0, 0x10]);
        let payload = &message[14..];
        assert_eq!(
            u64::from_be_bytes(payload[0x2a..0x32].try_into().unwrap()),
            3
        );
        assert_eq!(
            u16::from_be_bytes(payload[0x66..0x68].try_into().unwrap()),
            2
        );
        let name_end = ENTRY_FIXED + 4;
        assert_eq!(payload[name_end], 0);
        assert_eq!(&payload[name_end + 1..name_end + 4], b"x:y");
        let parsed = parse_entry(payload).unwrap();
        assert_eq!(parsed.kind, EntryKind::Symlink);
        assert_eq!(parsed.link_target.as_deref(), Some("x:y"));
    }

    #[test]
    fn data_chunks_match_capture() {
        let full = upload_data(3, &vec![0x5a; MAX_DATA_CHUNK])
            .unwrap()
            .encode();
        assert_eq!(full.len(), 65_554);
        assert_eq!(u32::from_be_bytes(full[2..6].try_into().unwrap()), 65_548);
        assert_eq!(
            u16::from_be_bytes(full[8..10].try_into().unwrap()),
            SUBTYPE_DATA
        );
        assert_eq!(
            u32::from_be_bytes(full[14..18].try_into().unwrap()),
            MAX_DATA_CHUNK as u32
        );
        let tail = upload_data(3, &vec![0; 32_045]).unwrap().encode();
        assert_eq!(tail.len(), 32_063);
        assert!(upload_data(3, &vec![0; MAX_DATA_CHUNK + 1]).is_err());
    }

    #[test]
    fn completion_and_cancel_are_14_bytes() {
        let complete = upload_complete(3).encode();
        assert_eq!(complete.len(), 14);
        assert_eq!(u32::from_be_bytes(complete[2..6].try_into().unwrap()), 8);
        assert_eq!(
            u16::from_be_bytes(complete[8..10].try_into().unwrap()),
            SUBTYPE_COMPLETE
        );
        let cancel = transfer_cancel(9).encode();
        assert_eq!(cancel.len(), 14);
        assert_eq!(
            u16::from_be_bytes(cancel[8..10].try_into().unwrap()),
            SUBTYPE_CANCEL
        );
    }

    #[test]
    fn download_request_layout() {
        let path = "/Users/example/Desktop/file.txt";
        let message = download_request(4, path).encode();
        assert_eq!(message.len(), 25 + path.len());
        assert_eq!(
            u16::from_be_bytes(message[8..10].try_into().unwrap()),
            SUBTYPE_DOWNLOAD_REQUEST
        );
        assert_eq!(&message[14..18], &1u32.to_be_bytes());
        assert_eq!(&message[18..20], &[0, 0]);
        assert_eq!(
            u32::from_be_bytes(message[20..24].try_into().unwrap()) as usize,
            path.len()
        );
        assert_eq!(&message[24..24 + path.len()], path.as_bytes());
        assert_eq!(message[24 + path.len()], 0);
    }

    #[test]
    fn container_parse_rejects_bad_input() {
        let valid = upload_complete(1).encode();
        let (parsed, used) = Container::parse(&valid).unwrap();
        assert_eq!(used, 14);
        assert_eq!(parsed.handle, 1);
        assert_eq!(
            Container::parse(&valid[..13]),
            Err(FileTransferError::Truncated)
        );

        let mut bad_type = valid.clone();
        bad_type[0] = 0x21;
        assert_eq!(
            Container::parse(&bad_type),
            Err(FileTransferError::BadType(0x21))
        );

        let mut bad_version = valid.clone();
        bad_version[7] = 2;
        assert_eq!(
            Container::parse(&bad_version),
            Err(FileTransferError::BadVersion(0x0002))
        );
    }

    #[test]
    fn upload_request_parse_matches_capture() {
        let path = "/Users/example/Desktops";
        let mut message = vec![MSG_UPLOAD_REQUEST, 0, 0, 0];
        message.extend_from_slice(&0x1242_fe7eu32.to_be_bytes());
        message.extend_from_slice(&(path.len() as u32).to_be_bytes());
        message.extend_from_slice(path.as_bytes());
        assert_eq!(message.len(), 35);
        let (request, used) = parse_upload_request(&message).unwrap();
        assert_eq!(used, 35);
        assert_eq!(request.handle, 0x1242_fe7e);
        assert_eq!(request.path, path);
    }

    #[test]
    fn drag_in_roundtrip() {
        let urls = [
            "file:///Users/example/Desktop/a%20b.txt",
            "file:///Users/example/Desktop/c.txt",
        ];
        let message = drag_in_message(0x1242_fe7e, &urls);
        let (info, used) = parse_drag_info(&message).unwrap();
        assert_eq!(used, message.len());
        assert_eq!(info.handle, 0x1242_fe7e);
        assert_eq!(
            parse_pasteboard_file_urls(&info.pasteboard).unwrap(),
            urls.to_vec()
        );
    }

    #[test]
    fn pasteboard_template_is_63_bytes_plus_url() {
        let url = format!("file:///tmp/{}", "a".repeat(37));
        let blob = pasteboard_file_urls(&[&url]);
        assert_eq!(blob.len(), url.len() + 63);
        assert_eq!(blob.len(), 112);
        assert_eq!(
            parse_pasteboard_file_urls(&blob).unwrap(),
            vec![url.clone()]
        );
    }

    #[test]
    fn progress_and_ack_parse() {
        let mut payload = Vec::new();
        payload.extend_from_slice(&0.5f64.to_bits().to_be_bytes());
        assert_eq!(parse_progress(&payload).unwrap(), Progress::Ratio(0.5));

        let mut named = Vec::new();
        named.extend_from_slice(&11u32.to_be_bytes());
        named.extend_from_slice(b"example.zip\0");
        assert_eq!(
            parse_progress(&named).unwrap(),
            Progress::Name("example.zip".to_string())
        );

        let mut ack = Vec::new();
        ack.extend_from_slice(&4u32.to_be_bytes());
        ack.extend_from_slice(b"done");
        assert_eq!(parse_ack(&ack).unwrap(), "done");
        assert_eq!(parse_ack(&[0, 0]), Err(FileTransferError::Truncated));
    }

    #[test]
    fn drag_out_start_is_8_bytes() {
        let message = drag_out_start(0xdead_beef);
        assert_eq!(message, vec![0x0e, 0, 0, 0, 0xde, 0xad, 0xbe, 0xef]);
    }

    #[test]
    fn summary_parse_matches_encoder() {
        let payload = upload_summary(1, 42, 2, 1).payload;
        assert_eq!(
            parse_summary(&payload).unwrap(),
            Summary {
                total_bytes: 42,
                files: 2,
                directories: 1
            }
        );
    }
}
