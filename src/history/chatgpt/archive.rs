use std::{
    fs::{File, OpenOptions},
    io::{self, Read, Seek, SeekFrom, Write},
    os::unix::fs::{FileExt, OpenOptionsExt},
    path::{Path, PathBuf},
    sync::Arc,
};

use sha2::{Digest, Sha256};

use super::{Corruption, Incompleteness, PackageError, UnsafeReason};

#[derive(Clone, Copy, Debug)]
pub(super) struct Limits {
    pub parts: usize,
    pub members_per_archive: usize,
    pub member_bytes: u64,
    pub package_bytes: u64,
    pub ratio: u64,
    pub conversation_bytes: usize,
    pub spool_bytes: u64,
    pub name_bytes: usize,
    pub name_depth: usize,
}

const RATIO_FLOOR: u64 = 1024 * 1024;

pub(super) struct Admission {
    pub limits: Limits,
    parts: usize,
    declared: u64,
}

impl Admission {
    pub fn new(limits: Limits) -> Self {
        Self {
            limits,
            parts: 0,
            declared: 0,
        }
    }

    pub fn part(&mut self) -> Result<(), PackageError> {
        self.parts += 1;
        within("parts", self.limits.parts as u64, self.parts as u64)
    }

    pub fn member(&mut self, size: u64) -> Result<(), PackageError> {
        within("member size", self.limits.member_bytes, size)?;
        self.declared = self.declared.saturating_add(size);
        within("package size", self.limits.package_bytes, self.declared)
    }
}

fn within(what: &'static str, limit: u64, found: u64) -> Result<(), PackageError> {
    if found > limit {
        return Err(PackageError::Bounds { what, limit, found });
    }
    Ok(())
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            parts: 64,
            members_per_archive: 250_000,
            member_bytes: 4 << 30,
            package_bytes: 128 << 30,
            ratio: 1_000,
            conversation_bytes: 256 << 20,
            spool_bytes: 32 << 30,
            name_bytes: 1_024,
            name_depth: 32,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(super) struct MemberPath(String);

impl MemberPath {
    pub fn parse(raw: &[u8], limits: &Limits) -> Result<Self, PackageError> {
        let refuse = |reason| PackageError::Unsafe {
            member: shown(&String::from_utf8_lossy(raw)),
            reason,
        };
        if raw.len() > limits.name_bytes {
            return Err(PackageError::Bounds {
                what: "member name",
                limit: limits.name_bytes as u64,
                found: raw.len() as u64,
            });
        }
        let text = std::str::from_utf8(raw).map_err(|_| refuse(UnsafeReason::NameNotUtf8))?;
        let drive = raw.len() >= 2 && raw[0].is_ascii_alphabetic() && raw[1] == b':';
        if text.starts_with('/') || text.starts_with('\\') || drive {
            return Err(refuse(UnsafeReason::Absolute));
        }
        if text.contains('\\') || text.contains('\0') {
            return Err(refuse(UnsafeReason::Traversal));
        }
        let components: Vec<&str> = text
            .split('/')
            .filter(|component| !component.is_empty() && *component != ".")
            .collect();
        if components.is_empty() || components.contains(&"..") {
            return Err(refuse(UnsafeReason::Traversal));
        }
        if components.len() > limits.name_depth {
            return Err(PackageError::Bounds {
                what: "member name depth",
                limit: limits.name_depth as u64,
                found: components.len() as u64,
            });
        }
        Ok(Self(components.join("/")))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn file_name(&self) -> &str {
        self.0.rsplit('/').next().unwrap_or(&self.0)
    }

    pub fn is_root(&self) -> bool {
        !self.0.contains('/')
    }
}

pub(super) fn shown(text: &str) -> String {
    text.chars()
        .map(|character| {
            if character.is_control() {
                '\u{FFFD}'
            } else {
                character
            }
        })
        .take(200)
        .collect()
}

#[derive(Clone)]
pub(super) struct Region {
    file: Arc<File>,
    start: u64,
    len: u64,
}

impl Region {
    pub fn whole(file: File) -> io::Result<Self> {
        let len = file.metadata()?.len();
        Ok(Self {
            file: Arc::new(file),
            start: 0,
            len,
        })
    }

    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn slice(&self, offset: u64, len: u64) -> io::Result<Self> {
        let end = offset.checked_add(len).ok_or_else(out_of_bounds)?;
        if end > self.len {
            return Err(out_of_bounds());
        }
        Ok(Self {
            file: self.file.clone(),
            start: self.start + offset,
            len,
        })
    }

    pub fn reader(&self) -> RegionReader {
        RegionReader {
            region: self.clone(),
            position: 0,
        }
    }

    pub fn read_exact_at(&self, buffer: &mut [u8], offset: u64) -> io::Result<()> {
        let end = offset
            .checked_add(buffer.len() as u64)
            .ok_or_else(out_of_bounds)?;
        if end > self.len {
            return Err(out_of_bounds());
        }
        self.file.read_exact_at(buffer, self.start + offset)
    }
}

fn out_of_bounds() -> io::Error {
    io::Error::new(
        io::ErrorKind::UnexpectedEof,
        "Read past the end of an export member",
    )
}

pub(super) struct RegionReader {
    region: Region,
    position: u64,
}

impl Read for RegionReader {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let remaining = self.region.len.saturating_sub(self.position);
        let wanted = (buffer.len() as u64).min(remaining) as usize;
        if wanted == 0 {
            return Ok(0);
        }
        let count = self
            .region
            .file
            .read_at(&mut buffer[..wanted], self.region.start + self.position)?;
        self.position += count as u64;
        Ok(count)
    }
}

impl Seek for RegionReader {
    fn seek(&mut self, position: SeekFrom) -> io::Result<u64> {
        let target = match position {
            SeekFrom::Start(offset) => Some(offset),
            SeekFrom::End(offset) => self.region.len.checked_add_signed(offset),
            SeekFrom::Current(offset) => self.position.checked_add_signed(offset),
        };
        self.position = target.ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Invalid export member seek")
        })?;
        Ok(self.position)
    }
}

pub(super) struct Spool {
    file: File,
    len: u64,
    limit: u64,
}

impl Spool {
    pub fn create(limit: u64) -> io::Result<Self> {
        let path =
            std::env::temp_dir().join(format!(".beep-boop-chatgpt-{}", uuid::Uuid::new_v4()));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        std::fs::remove_file(&path)?;
        Ok(Self {
            file,
            len: 0,
            limit,
        })
    }

    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn into_region(self) -> Region {
        Region {
            file: Arc::new(self.file),
            start: 0,
            len: self.len,
        }
    }
}

impl Write for Spool {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let end = self.len.saturating_add(buffer.len() as u64);
        if end > self.limit {
            return Err(io::Error::other(SpoolFull { limit: self.limit }));
        }
        self.file.write_all_at(buffer, self.len)?;
        self.len = end;
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[derive(Debug)]
pub(super) struct SpoolFull {
    pub limit: u64,
}

impl std::fmt::Display for SpoolFull {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "the private spool is limited to {} bytes",
            self.limit
        )
    }
}

impl std::error::Error for SpoolFull {}

pub(super) struct Tee<'a, R> {
    pub inner: R,
    pub spool: &'a mut Spool,
}

impl<R: Read> Read for Tee<'_, R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        let count = self.inner.read(buffer)?;
        self.spool.write_all(&buffer[..count])?;
        Ok(count)
    }
}

#[derive(Debug)]
pub(super) struct CorruptRead(pub Corruption);

impl std::fmt::Display for CorruptRead {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.0.describe())
    }
}

impl std::error::Error for CorruptRead {}

pub(super) fn corruption(error: &io::Error) -> Option<Corruption> {
    error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<CorruptRead>())
        .map(|corrupt| corrupt.0)
}

fn corrupt(reason: Corruption) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, CorruptRead(reason))
}

pub(super) struct Exact<R> {
    inner: R,
    declared: u64,
    read: u64,
    crc: Option<(crc32fast::Hasher, u32)>,
}

impl<R: Read> Exact<R> {
    pub fn new(inner: R, declared: u64, crc: Option<u32>) -> Self {
        Self {
            inner,
            declared,
            read: 0,
            crc: crc.map(|expected| (crc32fast::Hasher::new(), expected)),
        }
    }

    fn finish(&mut self) -> io::Result<usize> {
        let mut probe = [0; 1];
        loop {
            match self.inner.read(&mut probe) {
                Ok(0) => break,
                Ok(_) => return Err(corrupt(Corruption::LongerThanDeclared)),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
                Err(error) => return Err(error),
            }
        }
        if let Some((hasher, expected)) = &self.crc
            && hasher.clone().finalize() != *expected
        {
            return Err(corrupt(Corruption::CrcMismatch));
        }
        Ok(0)
    }
}

impl<R: Read> Read for Exact<R> {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        if buffer.is_empty() {
            return Ok(0);
        }
        let remaining = self.declared - self.read;
        if remaining == 0 {
            return self.finish();
        }
        let wanted = (buffer.len() as u64).min(remaining) as usize;
        let count = match self.inner.read(&mut buffer[..wanted]) {
            Ok(0) => return Err(corrupt(Corruption::ShorterThanDeclared)),
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                return Err(corrupt(Corruption::ShorterThanDeclared));
            }
            Err(error) => return Err(error),
        };
        self.read += count as u64;
        if let Some((hasher, _)) = &mut self.crc {
            hasher.update(&buffer[..count]);
        }
        Ok(count)
    }
}

const SNIFF_BYTES: usize = 16;

pub(super) struct MemberDigest {
    pub sha256: String,
    pub size: u64,
    pub sniffed: Option<&'static str>,
}

#[derive(Default)]
pub(super) struct Hashing {
    sha256: Sha256,
    head: Vec<u8>,
}

impl Write for Hashing {
    fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
        let wanted = SNIFF_BYTES
            .saturating_sub(self.head.len())
            .min(buffer.len());
        self.head.extend_from_slice(&buffer[..wanted]);
        self.sha256.update(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

impl Hashing {
    pub fn finish(self, size: u64) -> MemberDigest {
        MemberDigest {
            sha256: hex::encode(self.sha256.finalize()),
            size,
            sniffed: sniff(&self.head),
        }
    }
}

fn sniff(head: &[u8]) -> Option<&'static str> {
    let riff = |kind: &[u8]| head.starts_with(b"RIFF") && head.get(8..12) == Some(kind);
    Some(match head {
        _ if head.starts_with(b"\x89PNG") => "image/png",
        _ if head.starts_with(&[0xFF, 0xD8, 0xFF]) => "image/jpeg",
        _ if head.starts_with(b"GIF8") => "image/gif",
        _ if riff(b"WEBP") => "image/webp",
        _ if riff(b"WAVE") => "audio/wav",
        _ if head.starts_with(b"%PDF-") => "application/pdf",
        _ if head.starts_with(b"ID3") || head.starts_with(&[0xFF, 0xFB]) => "audio/mpeg",
        _ if head.get(4..8) == Some(b"ftyp") => "video/mp4",
        _ if head.starts_with(b"OggS") => "audio/ogg",
        _ if head.starts_with(&[0x1A, 0x45, 0xDF, 0xA3]) => "video/webm",
        _ if head.starts_with(b"PK\x03\x04") => "application/zip",
        _ => return None,
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Method {
    Stored,
    Deflated,
}

pub(super) struct ZipMember {
    pub path: MemberPath,
    pub size: u64,
    pub compressed: u64,
    pub data_start: u64,
    pub method: Method,
    pub crc32: u32,
}

impl ZipMember {
    pub fn open(&self, archive: &Region) -> io::Result<Box<dyn Read + Send>> {
        let raw = archive.slice(self.data_start, self.compressed)?.reader();
        Ok(match self.method {
            Method::Stored => Box::new(Exact::new(raw, self.size, Some(self.crc32))),
            Method::Deflated => Box::new(Exact::new(
                flate2::read::DeflateDecoder::new(raw),
                self.size,
                Some(self.crc32),
            )),
        })
    }
}

const FILE_TYPE: u32 = 0o170_000;
const SYMLINK: u32 = 0o120_000;
const DIRECTORY: u32 = 0o040_000;
const REGULAR: u32 = 0o100_000;

pub(super) fn zip_members(
    name: &str,
    archive: &Region,
    admission: &mut Admission,
) -> Result<Vec<ZipMember>, PackageError> {
    let limits = admission.limits;
    let unreadable = |error: &dyn std::fmt::Display| PackageError::Unreadable {
        path: name.to_owned(),
        reason: error.to_string(),
    };
    let mut zip = zip::ZipArchive::new(archive.reader()).map_err(|error| unreadable(&error))?;
    if zip.len() > limits.members_per_archive {
        return Err(PackageError::Bounds {
            what: "members",
            limit: limits.members_per_archive as u64,
            found: zip.len() as u64,
        });
    }
    if zip.has_duplicate_names() {
        return Err(PackageError::Unsafe {
            member: shown(name),
            reason: UnsafeReason::DuplicateName,
        });
    }
    let mut members = Vec::new();
    for index in 0..zip.len() {
        let entry = zip
            .by_index_raw(index)
            .map_err(|error| unreadable(&error))?;
        let raw_name = entry.name_raw().to_vec();
        let mode = entry.unix_mode().map(|mode| mode & FILE_TYPE);
        if entry.is_dir() || mode == Some(DIRECTORY) {
            continue;
        }
        let path = MemberPath::parse(&raw_name, &limits)?;
        let refuse = |reason| PackageError::Unsafe {
            member: shown(path.as_str()),
            reason,
        };
        match mode {
            Some(SYMLINK) => return Err(refuse(UnsafeReason::Symlink)),
            Some(REGULAR) | Some(0) | None => {}
            Some(_) => return Err(refuse(UnsafeReason::SpecialFile)),
        }
        if entry.encrypted() {
            return Err(refuse(UnsafeReason::Encrypted));
        }
        let method = match entry.compression() {
            zip::CompressionMethod::Stored => Method::Stored,
            zip::CompressionMethod::Deflated => Method::Deflated,
            _ => return Err(refuse(UnsafeReason::UnsupportedCompression)),
        };
        let size = entry.size();
        let compressed = entry.compressed_size();
        admission.member(size)?;
        if size > RATIO_FLOOR && size / compressed.max(1) > limits.ratio {
            return Err(PackageError::Bounds {
                what: "compression ratio",
                limit: limits.ratio,
                found: size / compressed.max(1),
            });
        }
        let data_start = entry
            .data_start()
            .ok_or_else(|| unreadable(&"a member has no data offset"))?;
        members.push(ZipMember {
            path,
            size,
            compressed,
            data_start,
            method,
            crc32: entry.crc32(),
        });
    }
    Ok(members)
}

pub(super) struct FolderMember {
    pub path: MemberPath,
    pub size: u64,
    pub file: PathBuf,
}

pub(super) fn walk_folder(
    root: &Path,
    admission: &mut Admission,
) -> Result<Vec<FolderMember>, PackageError> {
    let limits = admission.limits;
    let unreadable = |path: &Path, error: io::Error| PackageError::Unreadable {
        path: shown(&path.to_string_lossy()),
        reason: error.to_string(),
    };
    let mut members = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let entries =
            std::fs::read_dir(&directory).map_err(|error| unreadable(&directory, error))?;
        for entry in entries {
            let entry = entry.map_err(|error| unreadable(&directory, error))?;
            let path = entry.path();
            let relative = path.strip_prefix(root).unwrap_or(&path);
            let name = relative
                .to_str()
                .ok_or_else(|| PackageError::Unsafe {
                    member: shown(&relative.to_string_lossy()),
                    reason: UnsafeReason::NameNotUtf8,
                })?
                .to_owned();
            let metadata =
                std::fs::symlink_metadata(&path).map_err(|error| unreadable(&path, error))?;
            let kind = metadata.file_type();
            let refuse = |reason| PackageError::Unsafe {
                member: shown(&name),
                reason,
            };
            if kind.is_symlink() {
                return Err(refuse(UnsafeReason::Symlink));
            }
            if kind.is_dir() {
                MemberPath::parse(name.as_bytes(), &limits)?;
                pending.push(path);
                continue;
            }
            if !kind.is_file() {
                return Err(refuse(UnsafeReason::SpecialFile));
            }
            let member = MemberPath::parse(name.as_bytes(), &limits)?;
            admission.member(metadata.len())?;
            members.push(FolderMember {
                path: member,
                size: metadata.len(),
                file: path,
            });
            if members.len() > limits.members_per_archive {
                return Err(PackageError::Bounds {
                    what: "members",
                    limit: limits.members_per_archive as u64,
                    found: members.len() as u64,
                });
            }
        }
    }
    Ok(members)
}

/// Opens a file that must still be the regular file the walk saw. `O_NOFOLLOW` refuses a
/// swapped-in link and `O_NONBLOCK` keeps a swapped-in FIFO from hanging the open.
pub(super) fn open_regular(path: &Path) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "An export file is no longer a regular file",
        ));
    }
    Ok(file)
}

/// Given `…-part-0001.zip`, every `…-part-NNNN.zip` beside it with the same stem, in order.
/// A gap in the numbering refuses the package. A missing final part cannot be detected; its
/// attachments surface later as `missing` gaps.
pub(super) fn sibling_parts(path: &Path) -> Result<Vec<PathBuf>, PackageError> {
    let Some((stem, _)) = path
        .file_name()
        .and_then(|name| name.to_str())
        .and_then(part_number)
    else {
        return Ok(vec![path.to_path_buf()]);
    };
    let directory = path.parent().unwrap_or(Path::new("."));
    let unreadable = |error: io::Error| PackageError::Unreadable {
        path: shown(&directory.to_string_lossy()),
        reason: error.to_string(),
    };
    let mut parts = Vec::new();
    for entry in std::fs::read_dir(directory).map_err(unreadable)? {
        let entry = entry.map_err(unreadable)?;
        let name = entry.file_name();
        if let Some((sibling, number)) = name.to_str().and_then(part_number)
            && sibling == stem
        {
            parts.push((number, entry.path()));
        }
    }
    parts.sort();
    for (expected, (number, _)) in (1..).zip(&parts) {
        if *number != expected {
            return Err(PackageError::Incomplete {
                reason: Incompleteness::MissingPart { number: expected },
            });
        }
    }
    Ok(parts.into_iter().map(|(_, path)| path).collect())
}

fn part_number(name: &str) -> Option<(&str, u32)> {
    let base = name
        .strip_suffix(".zip")
        .or_else(|| name.strip_suffix(".ZIP"))?;
    let (stem, number) = base.rsplit_once("-part-")?;
    if number.len() != 4 || !number.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    Some((stem, number.parse().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn member_names_are_normalized_or_refused() {
        let limits = Limits::default();
        let parse = |raw: &str| MemberPath::parse(raw.as_bytes(), &limits);
        assert_eq!(parse("a/./b//c.dat").unwrap().as_str(), "a/b/c.dat");
        for (raw, expected) in [
            ("../escape.json", UnsafeReason::Traversal),
            ("a/../../b.dat", UnsafeReason::Traversal),
            ("a\\..\\b", UnsafeReason::Traversal),
            ("/abs.dat", UnsafeReason::Absolute),
            ("C:\\x.dat", UnsafeReason::Absolute),
        ] {
            assert!(
                matches!(parse(raw), Err(PackageError::Unsafe { reason, .. }) if reason == expected),
                "{raw}"
            );
        }
        assert!(matches!(
            MemberPath::parse(b"bad\xff.dat", &limits),
            Err(PackageError::Unsafe {
                reason: UnsafeReason::NameNotUtf8,
                ..
            })
        ));
    }

    #[test]
    fn exact_reads_fail_on_forged_sizes_and_checksums() {
        let read = |bytes: &[u8], declared, crc| {
            let mut output = Vec::new();
            Exact::new(bytes, declared, crc)
                .read_to_end(&mut output)
                .map(|_| output)
                .map_err(|error| corruption(&error))
        };
        let checksum = crc32fast::hash(b"abc");
        assert_eq!(read(b"abc", 3, Some(checksum)).unwrap(), b"abc");
        assert_eq!(
            read(b"abc", 2, None),
            Err(Some(Corruption::LongerThanDeclared))
        );
        assert_eq!(
            read(b"abc", 4, None),
            Err(Some(Corruption::ShorterThanDeclared))
        );
        assert_eq!(
            read(b"abd", 3, Some(checksum)),
            Err(Some(Corruption::CrcMismatch))
        );
    }
}
