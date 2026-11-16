//! A locally checked ChatGPT data export, served as inert history.

mod archive;
mod conversation;
#[cfg(test)]
mod fixture;
mod json;
mod package;

use std::{
    collections::HashMap,
    io::Read,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use async_trait::async_trait;
use base64::{Engine, engine::general_purpose::STANDARD};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ts_rs::TS;

use crate::history::{
    HistoryAssetKind, HistoryGap, HistoryGapCode, HistoryItem, HistoryRequest, HistoryResponse,
    HistorySource, PAGE_BYTES,
};

const ASSET_CHUNK_BYTES: usize = 320 * 1024;

/// What the client checked, sent to the coordinator as the import's identity. Bounded and
/// path-free: part names are file names only.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptPackageSummary {
    /// Equal for a ZIP and its extracted folder. The coordinator's single-flight key.
    pub digest: String,
    pub parts: Vec<String>,
    pub conversations: u32,
    pub archived: u32,
    pub shards: u32,
    pub attachments: u32,
    pub missing_attachments: u32,
    /// System, developer and custom-instruction messages left out on purpose.
    pub excluded_messages: u32,
    /// Repairs and skips that lose no conversation data. Printed, never gaps.
    pub notes: Vec<String>,
    /// Export data that will not be imported. Each becomes an import gap.
    pub problems: Vec<String>,
}

/// The inert evidence stored as `HistoryItem.data` for one ChatGPT message node.
/// Instruction-bearing metadata is removed before it is built.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptEnvelope {
    pub conversation_id: String,
    pub node_id: String,
    pub parent_id: Option<String>,
    /// The whole normalized message text, citations removed. `HistoryItem.text` is its excerpt.
    pub text: String,
    #[ts(type = "unknown")]
    pub message: serde_json::Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[ts(optional, type = "unknown[]")]
    pub library_files: Vec<serde_json::Value>,
}

/// One checked, immutable export served as history. Cheap to clone.
#[derive(Clone)]
pub struct ChatGptHistory {
    package: Arc<package::Package>,
    state: Arc<Mutex<ReadState>>,
}

#[derive(Default)]
struct ReadState {
    current: Option<(String, Arc<conversation::Normalized>)>,
    digests: HashMap<package::MemberId, Result<MemberDigest, String>>,
    transfer: Option<(package::MemberId, archive::Region)>,
}

#[derive(Clone)]
struct MemberDigest {
    sha256: String,
    size: u64,
    sniffed: Option<&'static str>,
}

#[derive(Serialize, Deserialize)]
struct InventoryCursor {
    package: String,
    archived: bool,
    offset: usize,
}

#[derive(Serialize, Deserialize)]
struct ReadCursor {
    thread: String,
    version: String,
    order: u64,
    #[serde(default)]
    incomplete: bool,
}

const LIST_PAGE: usize = 100;
const PAGE_SLACK: usize = 16 * 1024;

impl ChatGptHistory {
    /// Opens and checks the whole package before anything is written anywhere. Blocking.
    pub fn open(
        paths: &[PathBuf],
        progress: &mut dyn FnMut(PackageProgress),
    ) -> Result<Self, PackageError> {
        Self::open_with(paths, archive::Limits::default(), progress)
    }

    fn open_with(
        paths: &[PathBuf],
        limits: archive::Limits,
        progress: &mut dyn FnMut(PackageProgress),
    ) -> Result<Self, PackageError> {
        Ok(Self {
            package: Arc::new(package::Package::open(paths, limits, progress)?),
            state: Arc::default(),
        })
    }

    pub fn summary(&self) -> &ChatGptPackageSummary {
        &self.package.summary
    }

    fn serve(&self, request: HistoryRequest) -> Result<HistoryResponse> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| anyhow!("ChatGPT history reader failed earlier"))?;
        let response = match request {
            HistoryRequest::List { archived, cursor } => self.list(archived, cursor.as_deref())?,
            HistoryRequest::Read { thread_id, cursor } => {
                self.read(&mut state, &thread_id, cursor.as_deref())?
            }
            HistoryRequest::Asset {
                thread_id,
                path,
                offset,
            } => self.asset(&mut state, &thread_id, &path, offset)?,
        };
        ensure!(
            serde_json::to_vec(&response)?.len() <= PAGE_BYTES,
            "History response exceeded its transport budget"
        );
        Ok(response)
    }

    fn list(&self, archived: bool, cursor: Option<&str>) -> Result<HistoryResponse> {
        let package = &self.summary().digest[..16];
        let offset = match cursor {
            None => 0,
            Some(cursor) => {
                let cursor: InventoryCursor =
                    serde_json::from_str(cursor).context("Invalid ChatGPT inventory cursor")?;
                ensure!(
                    cursor.package == package && cursor.archived == archived,
                    "ChatGPT inventory cursor belongs to another export or collection"
                );
                cursor.offset
            }
        };
        let mut threads = self
            .package
            .conversations()
            .iter()
            .filter(|entry| entry.thread.archived == archived)
            .skip(offset)
            .map(|entry| entry.thread.clone());
        let page: Vec<_> = threads.by_ref().take(LIST_PAGE).collect();
        let next_cursor = threads
            .next()
            .map(|_| {
                serde_json::to_string(&InventoryCursor {
                    package: package.to_owned(),
                    archived,
                    offset: offset + page.len(),
                })
            })
            .transpose()?;
        Ok(HistoryResponse::List {
            threads: page,
            next_cursor,
        })
    }

    fn read(
        &self,
        state: &mut ReadState,
        thread_id: &str,
        cursor: Option<&str>,
    ) -> Result<HistoryResponse> {
        let entry = self
            .package
            .conversation(thread_id)
            .context("ChatGPT conversation is not in this export")?;
        let version = entry.thread.version.clone();
        let position = match cursor {
            None => ReadCursor {
                thread: thread_id.to_owned(),
                version: version.clone(),
                order: 0,
                incomplete: false,
            },
            Some(cursor) => {
                let cursor: ReadCursor =
                    serde_json::from_str(cursor).context("Invalid ChatGPT history cursor")?;
                ensure!(
                    cursor.thread == thread_id,
                    "ChatGPT history cursor belongs to another conversation"
                );
                cursor
            }
        };
        if position.version != version {
            return Ok(changed(
                thread_id,
                version,
                "This conversation changed since its last read; reread it from the start",
            ));
        }
        let Some(normalized) = self.normalized(state, thread_id) else {
            return Ok(changed(
                thread_id,
                version,
                "The export changed after it was checked; check it again and rerun the import",
            ));
        };
        let start = usize::try_from(position.order)?;
        let mut items = Vec::new();
        let mut gaps: Vec<HistoryGap> = if start == 0 {
            normalized
                .gaps
                .iter()
                .filter(|gap| gap.item_id.is_none())
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        let mut bytes = PAGE_SLACK + serde_json::to_vec(&gaps)?.len();
        for item in normalized.items.iter().skip(start) {
            let mut item = item.clone();
            let mut item_gaps: Vec<HistoryGap> = normalized
                .gaps
                .iter()
                .filter(|gap| gap.item_id.as_deref() == Some(item.id.as_str()))
                .cloned()
                .collect();
            self.fill_digests(state, &mut item, &mut item_gaps);
            let length = serde_json::to_vec(&item)?.len() + serde_json::to_vec(&item_gaps)?.len();
            if bytes + length > PAGE_BYTES && !items.is_empty() {
                break;
            }
            bytes += length;
            items.push(item);
            gaps.append(&mut item_gaps);
        }
        let next = start + items.len();
        let incomplete = position.incomplete || !gaps.is_empty();
        let exhausted = next >= normalized.items.len();
        let next_cursor = (!exhausted)
            .then(|| {
                serde_json::to_string(&ReadCursor {
                    thread: thread_id.to_owned(),
                    version: version.clone(),
                    order: next as u64,
                    incomplete,
                })
            })
            .transpose()?;
        Ok(HistoryResponse::Read {
            thread_id: thread_id.to_owned(),
            version,
            items,
            next_cursor,
            resume_cursor: None,
            complete: exhausted && !incomplete,
            gaps,
            source_exhausted: exhausted,
        })
    }

    fn normalized(
        &self,
        state: &mut ReadState,
        thread_id: &str,
    ) -> Option<Arc<conversation::Normalized>> {
        if let Some((current, normalized)) = &state.current
            && current == thread_id
        {
            return Some(normalized.clone());
        }
        let entry = self.package.conversation(thread_id)?;
        let raw = self.package.read_conversation(entry).ok()?;
        let normalized = Arc::new(conversation::normalize(
            thread_id,
            &raw,
            self.package.library(thread_id),
            self.package.as_ref(),
        ));
        state.current = Some((thread_id.to_owned(), normalized.clone()));
        Some(normalized)
    }

    fn fill_digests(
        &self,
        state: &mut ReadState,
        item: &mut HistoryItem,
        gaps: &mut Vec<HistoryGap>,
    ) {
        let mut kept = Vec::new();
        for mut asset in std::mem::take(&mut item.assets) {
            if !matches!(asset.kind, HistoryAssetKind::LocalMedia) {
                kept.push(asset);
                continue;
            }
            match self.digest(state, &asset.path) {
                Ok(digest) => {
                    if asset.media_type == conversation::UNKNOWN_MEDIA
                        && let Some(sniffed) = digest.sniffed
                    {
                        asset.media_type = sniffed.to_owned();
                    }
                    asset.sha256 = Some(digest.sha256);
                    asset.size = Some(digest.size);
                    kept.push(asset);
                }
                Err(reason) => gaps.push(HistoryGap {
                    code: HistoryGapCode::Changed,
                    item_id: Some(item.id.clone()),
                    message: format!("Attachment {} {reason}; it was not imported", asset.path),
                }),
            }
        }
        item.assets = kept;
    }

    fn digest(&self, state: &mut ReadState, file: &str) -> Result<MemberDigest, String> {
        let (member, _) = conversation::FileId::find(file)
            .and_then(|file| self.package.file(&file))
            .ok_or_else(|| "is not in this export".to_owned())?;
        if let Some(known) = state.digests.get(&member) {
            return known.clone();
        }
        let computed = self.compute_digest(member);
        state.digests.insert(member, computed.clone());
        computed
    }

    fn compute_digest(&self, member: package::MemberId) -> Result<MemberDigest, String> {
        let describe = |error: std::io::Error| match archive::corruption(&error) {
            Some(reason) => reason.describe().to_owned(),
            None => format!("could not be read ({error})"),
        };
        let mut reader = self.package.member(member).open().map_err(describe)?;
        let mut hash = Sha256::new();
        let mut head = Vec::new();
        let mut buffer = vec![0; 64 * 1024];
        let mut size = 0u64;
        loop {
            let count = reader.read(&mut buffer).map_err(describe)?;
            if count == 0 {
                break;
            }
            if head.len() < 16 {
                head.extend_from_slice(&buffer[..count.min(16 - head.len())]);
            }
            hash.update(&buffer[..count]);
            size += count as u64;
        }
        Ok(MemberDigest {
            sha256: hex::encode(hash.finalize()),
            size,
            sniffed: sniff(&head),
        })
    }

    fn asset(
        &self,
        state: &mut ReadState,
        thread_id: &str,
        path: &str,
        offset: u64,
    ) -> Result<HistoryResponse> {
        ensure!(
            self.package.conversation(thread_id).is_some(),
            "ChatGPT conversation is not in this export"
        );
        let Some(normalized) = self.normalized(state, thread_id) else {
            bail!("The export changed after it was checked");
        };
        let (bytes, total, sha256) = match normalized.assets.get(path) {
            Some(conversation::AssetSource::Evidence(evidence)) => {
                let start = usize::try_from(offset)?.min(evidence.len());
                let end = (start + ASSET_CHUNK_BYTES).min(evidence.len());
                (
                    evidence[start..end].to_vec(),
                    evidence.len() as u64,
                    hex::encode(Sha256::digest(evidence.as_slice())),
                )
            }
            Some(conversation::AssetSource::File(file)) => {
                let digest = self
                    .digest(state, file.as_str())
                    .map_err(|reason| anyhow!("Attachment {path} {reason}"))?;
                ensure!(
                    offset <= digest.size,
                    "History asset offset exceeds its size"
                );
                let (member, _) = self
                    .package
                    .file(file)
                    .context("Attachment is not in this export")?;
                let region = self.transfer_region(state, member)?;
                ensure!(
                    region.len() == digest.size,
                    "Attachment changed after it was checked"
                );
                let length = (digest.size - offset).min(ASSET_CHUNK_BYTES as u64) as usize;
                let mut chunk = vec![0; length];
                region.read_exact_at(&mut chunk, offset)?;
                (chunk, digest.size, digest.sha256)
            }
            None => bail!("Asset is not referenced by this ChatGPT conversation"),
        };
        let next = offset + bytes.len() as u64;
        Ok(HistoryResponse::Asset {
            path: path.to_owned(),
            offset,
            data_base64: STANDARD.encode(bytes),
            next_offset: (next < total).then_some(next),
            total_bytes: total,
            sha256,
        })
    }

    fn transfer_region(
        &self,
        state: &mut ReadState,
        member: package::MemberId,
    ) -> Result<archive::Region> {
        if let Some(region) = self.package.member(member).region()? {
            return Ok(region);
        }
        if let Some((current, region)) = &state.transfer
            && *current == member
        {
            return Ok(region.clone());
        }
        state.transfer = None;
        let source = self.package.member(member);
        let mut spool = archive::Spool::create(source.size)?;
        std::io::copy(&mut source.open()?, &mut spool)?;
        let region = spool.into_region();
        state.transfer = Some((member, region.clone()));
        Ok(region)
    }
}

fn changed(thread_id: &str, version: String, message: &str) -> HistoryResponse {
    HistoryResponse::Read {
        thread_id: thread_id.to_owned(),
        version,
        items: Vec::new(),
        next_cursor: None,
        resume_cursor: None,
        gaps: vec![HistoryGap {
            code: HistoryGapCode::Changed,
            item_id: None,
            message: message.to_owned(),
        }],
        complete: false,
        source_exhausted: false,
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

#[async_trait]
impl HistorySource for ChatGptHistory {
    /// Err only for protocol misuse: an unknown thread, a foreign cursor or an unreferenced
    /// asset. Faults in the export's data come back as gaps.
    async fn request(&self, request: HistoryRequest) -> Result<HistoryResponse> {
        let this = self.clone();
        tokio::task::spawn_blocking(move || this.serve(request)).await?
    }
}

pub enum PackageProgress {
    Part {
        name: String,
    },
    Shard {
        name: String,
        index: u32,
        count: u32,
    },
    Attachments {
        referenced: u32,
    },
}

impl std::fmt::Display for PackageProgress {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Part { name } => write!(formatter, "Checking {name}"),
            Self::Shard { name, index, count } => {
                write!(formatter, "Checking {name} ({index}/{count})")
            }
            Self::Attachments { referenced } => {
                write!(formatter, "Checking {referenced} referenced attachments")
            }
        }
    }
}

/// Why an export was refused before anything was imported. Callers match variants.
#[derive(Debug)]
pub enum PackageError {
    Unreadable {
        path: String,
        reason: String,
    },
    Unsafe {
        member: String,
        reason: UnsafeReason,
    },
    Bounds {
        what: &'static str,
        limit: u64,
        found: u64,
    },
    Incomplete {
        reason: Incompleteness,
    },
    Corrupt {
        member: String,
        reason: Corruption,
    },
    Empty,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum UnsafeReason {
    Traversal,
    Absolute,
    Symlink,
    SpecialFile,
    DuplicateName,
    Encrypted,
    UnsupportedCompression,
    NameNotUtf8,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Incompleteness {
    MissingShard { name: String },
    UnlistedShard { name: String },
    ShardCountMismatch { declared: u32, found: u32 },
    MissingPart { number: u32 },
    ConflictingManifests,
    AmbiguousConversations,
    InventorySizeMismatch { path: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Corruption {
    LongerThanDeclared,
    ShorterThanDeclared,
    CrcMismatch,
    NotJson,
}

impl Corruption {
    fn describe(self) -> &'static str {
        match self {
            Self::LongerThanDeclared => "holds more bytes than its archive declares",
            Self::ShorterThanDeclared => "holds fewer bytes than its archive declares",
            Self::CrcMismatch => "fails its checksum",
            Self::NotJson => "is not valid JSON",
        }
    }
}

impl std::fmt::Display for PackageError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unreadable { path, reason } => {
                write!(
                    formatter,
                    "ChatGPT export {path} could not be read: {reason}."
                )
            }
            Self::Unsafe { member, reason } => {
                let reason = match reason {
                    UnsafeReason::Traversal => "escapes the package (path traversal)",
                    UnsafeReason::Absolute => "is an absolute path",
                    UnsafeReason::Symlink => "is a symbolic link",
                    UnsafeReason::SpecialFile => "is not a regular file",
                    UnsafeReason::DuplicateName => "holds the same member name more than once",
                    UnsafeReason::Encrypted => "is encrypted",
                    UnsafeReason::UnsupportedCompression => {
                        "uses an unsupported compression method"
                    }
                    UnsafeReason::NameNotUtf8 => "has a name that is not UTF-8",
                };
                write!(formatter, "ChatGPT export is unsafe: {member} {reason}.")
            }
            Self::Bounds { what, limit, found } => write!(
                formatter,
                "ChatGPT export exceeds its {what} limit ({found} against a limit of {limit})."
            ),
            Self::Incomplete { reason } => {
                formatter.write_str("ChatGPT export is incomplete: ")?;
                match reason {
                    Incompleteness::MissingShard { name } => {
                        write!(formatter, "{name} is missing")?
                    }
                    Incompleteness::UnlistedShard { name } => {
                        write!(formatter, "{name} is not listed in its export manifest")?
                    }
                    Incompleteness::ShardCountMismatch { declared, found } => write!(
                        formatter,
                        "its export manifest declares {declared} conversation files but lists {found}"
                    )?,
                    Incompleteness::MissingPart { number } => {
                        write!(formatter, "part {number:04} of the download is missing")?
                    }
                    Incompleteness::ConflictingManifests => {
                        formatter.write_str("its parts carry different export manifests")?
                    }
                    Incompleteness::AmbiguousConversations => formatter.write_str(
                        "it holds both conversations.json and numbered conversation files",
                    )?,
                    Incompleteness::InventorySizeMismatch { path } => write!(
                        formatter,
                        "{path} does not have the size its export manifest lists"
                    )?,
                }
                formatter.write_str(".")
            }
            Self::Corrupt { member, reason } => write!(
                formatter,
                "ChatGPT export is damaged: {member} {}.",
                reason.describe()
            ),
            Self::Empty => formatter.write_str("ChatGPT export holds no conversations."),
        }?;
        formatter.write_str(" Nothing was imported.")
    }
}

impl std::error::Error for PackageError {}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use base64::{Engine, engine::general_purpose::STANDARD};
    use serde_json::{Value, json};
    use sha2::{Digest, Sha256};

    use super::*;
    use crate::history::{
        HistoryAssetKind, HistoryBranchState, HistoryGap, HistoryGapCode, HistoryItem,
        HistoryThread, PAGE_BYTES,
    };
    use fixture::{Conversation, Export, Forge};

    fn open(path: &Path) -> ChatGptHistory {
        ChatGptHistory::open(&[path.to_path_buf()], &mut |_| {}).unwrap()
    }

    async fn list(
        history: &ChatGptHistory,
        archived: bool,
        cursor: Option<String>,
    ) -> Result<(Vec<HistoryThread>, Option<String>)> {
        match history
            .request(HistoryRequest::List { archived, cursor })
            .await?
        {
            HistoryResponse::List {
                threads,
                next_cursor,
            } => Ok((threads, next_cursor)),
            other => panic!("expected a list, got {other:?}"),
        }
    }

    struct Page {
        version: String,
        items: Vec<HistoryItem>,
        gaps: Vec<HistoryGap>,
        next_cursor: Option<String>,
        complete: bool,
        exhausted: bool,
        bytes: usize,
    }

    async fn read(history: &ChatGptHistory, thread: &str, cursor: Option<String>) -> Page {
        let response = history
            .request(HistoryRequest::Read {
                thread_id: thread.into(),
                cursor,
            })
            .await
            .unwrap();
        let bytes = serde_json::to_vec(&response).unwrap().len();
        match response {
            HistoryResponse::Read {
                version,
                items,
                gaps,
                next_cursor,
                complete,
                source_exhausted,
                ..
            } => Page {
                version,
                items,
                gaps,
                next_cursor,
                complete,
                exhausted: source_exhausted,
                bytes,
            },
            other => panic!("expected a read, got {other:?}"),
        }
    }

    async fn read_all(
        history: &ChatGptHistory,
        thread: &str,
    ) -> (Vec<HistoryItem>, Vec<HistoryGap>) {
        let (mut items, mut gaps, mut cursor) = (Vec::new(), Vec::new(), None);
        loop {
            let mut page = read(history, thread, cursor).await;
            items.append(&mut page.items);
            gaps.append(&mut page.gaps);
            match page.next_cursor {
                Some(next) => cursor = Some(next),
                None => return (items, gaps),
            }
        }
    }

    async fn fetch(
        history: &ChatGptHistory,
        thread: &str,
        path: &str,
    ) -> Result<(Vec<u8>, String, usize)> {
        let (mut bytes, mut digest, mut chunks, mut offset) = (Vec::new(), None, 0, 0);
        loop {
            let HistoryResponse::Asset {
                offset: served,
                data_base64,
                next_offset,
                total_bytes,
                sha256,
                ..
            } = history
                .request(HistoryRequest::Asset {
                    thread_id: thread.into(),
                    path: path.into(),
                    offset,
                })
                .await?
            else {
                panic!("expected an asset chunk");
            };
            assert_eq!(served, offset);
            let chunk = STANDARD.decode(data_base64).unwrap();
            assert!(chunk.len() <= ASSET_CHUNK_BYTES);
            assert_eq!(*digest.get_or_insert(sha256.clone()), sha256);
            bytes.extend_from_slice(&chunk);
            chunks += 1;
            assert!(total_bytes as usize >= bytes.len());
            match next_offset {
                Some(next) => offset = next,
                None => {
                    assert_eq!(bytes.len() as u64, total_bytes);
                    return Ok((bytes, sha256, chunks));
                }
            }
        }
    }

    fn sha(bytes: &[u8]) -> String {
        hex::encode(Sha256::digest(bytes))
    }

    fn picnic(number: u8) -> Value {
        Conversation::new(number, &format!("Picnic {number}"))
            .say("u1", "root", "user", "Plan a picnic for six")
            .say("a1", "u1", "assistant", "Here is a plan for six.")
            .build()
    }

    fn upload(parts: &[(&str, &str)]) -> Value {
        let attachments: Vec<Value> = parts
            .iter()
            .map(|(file, name)| json!({"id": file, "name": name}))
            .collect();
        json!({"author": {"role": "user"},
            "content": {"content_type": "text", "parts": ["Files attached"]},
            "metadata": {"attachments": attachments}})
    }

    #[tokio::test]
    async fn versions_change_only_when_their_format_constants_do() {
        let directory = tempfile::tempdir().unwrap();
        let history = open(
            &Export::new()
                .conversations(&[picnic(1)])
                .zip(&directory.path().join("export.zip")),
        );
        let (threads, _) = list(&history, false, None).await.unwrap();
        let page = read(&history, &fixture::id(1), None).await;
        assert_eq!(
            [
                history.summary().digest.as_str(),
                threads[0].version.as_str(),
                page.items[1].version.as_str(),
            ],
            [
                "4533b7025b4c69176cbfba5d73f1d68474b851200ee969a1b67298ab433d6c93",
                "23a8986dea5960b5b49b9dc1d80b6315a4eb534a96b455fd9abca191f2c66926",
                "6b273e3331333be4d762a3bc73367b4f6b077ddefc2c49bacd8c40ad04b29b78",
            ],
            "A pinned version changed. If the change is meant, bump PACKAGE_FORMAT, THREAD_FORMAT or ITEM_FORMAT and update these values."
        );
    }

    #[tokio::test]
    async fn edited_branch_reads_back_with_the_selected_prompt_shown() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .conversations(&[Conversation::new(1, "Picnic")
                .say("six", "root", "user", "Plan a picnic for six")
                .say("six-reply", "six", "assistant", "Here is a plan for six…")
                .say("eight", "root", "user", "Plan a picnic for eight")
                .say(
                    "eight-reply",
                    "eight",
                    "assistant",
                    "Here is a plan for eight…",
                )
                .build()])
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let (threads, _) = list(&history, false, None).await.unwrap();
        let page = read(&history, &threads[0].id, None).await;
        let shown: Vec<&str> = page
            .items
            .iter()
            .filter(|item| {
                item.branch
                    .as_ref()
                    .is_some_and(|branch| branch.state == HistoryBranchState::Current)
            })
            .map(|item| item.text.as_str())
            .collect();
        assert_eq!(
            shown,
            ["Plan a picnic for eight", "Here is a plan for eight…"]
        );
        assert_eq!(page.items.len(), 4);
        assert!(page.complete && page.exhausted);
        assert_eq!(page.version, threads[0].version);
    }

    #[tokio::test]
    async fn list_is_newest_first_and_paged_with_a_package_bound_cursor() {
        let directory = tempfile::tempdir().unwrap();
        let conversations: Vec<Value> = (0..250u32)
            .map(|index| {
                Conversation::new((index % 200) as u8, &format!("Conversation {index}"))
                    .set("id", json!(format!("00000000-0000-4000-8000-{index:012}")))
                    .set(
                        "update_time",
                        json!(1_767_225_600.0 + f64::from(index) * 60.0),
                    )
                    .say("u1", "root", "user", "Hello")
                    .build()
            })
            .collect();
        let history = open(
            &Export::new()
                .conversations(&conversations)
                .zip(&directory.path().join("export.zip")),
        );
        let mut sizes = Vec::new();
        let mut updated = Vec::new();
        let mut cursor = None;
        loop {
            let (threads, next) = list(&history, false, cursor).await.unwrap();
            sizes.push(threads.len());
            updated.extend(threads.iter().map(|thread| thread.updated_at));
            match next {
                Some(next) => cursor = Some(next),
                None => break,
            }
        }
        assert_eq!(sizes, [100, 100, 50]);
        assert!(updated.windows(2).all(|pair| pair[0] >= pair[1]));
        let (_, first_cursor) = list(&history, false, None).await.unwrap();
        let other = open(
            &Export::new()
                .conversations(&[picnic(1)])
                .zip(&directory.path().join("other.zip")),
        );
        assert!(list(&other, false, first_cursor.clone()).await.is_err());
        assert!(list(&history, true, first_cursor).await.is_err());
    }

    #[tokio::test]
    async fn read_pages_stay_under_the_page_budget() {
        let directory = tempfile::tempdir().unwrap();
        let mut conversation = Conversation::new(1, "Long");
        let mut parent = "root".to_owned();
        for index in 0..40 {
            let node = format!("n{index:02}");
            let role = if index % 2 == 0 { "user" } else { "assistant" };
            conversation = conversation.say(
                &node,
                &parent,
                role,
                &format!("{index} ").repeat(100 * 1024 / 3),
            );
            parent = node;
        }
        let history = open(
            &Export::new()
                .conversations(&[conversation.build()])
                .zip(&directory.path().join("export.zip")),
        );
        let mut orders = Vec::new();
        let mut cursor = None;
        let mut pages = 0;
        loop {
            let page = read(&history, &fixture::id(1), cursor).await;
            pages += 1;
            assert!(page.bytes <= PAGE_BYTES, "{}", page.bytes);
            orders.extend(page.items.iter().map(|item| item.order));
            assert_eq!(page.exhausted, page.next_cursor.is_none());
            match page.next_cursor {
                Some(next) => cursor = Some(next),
                None => {
                    assert!(page.complete);
                    break;
                }
            }
        }
        assert!(pages > 1);
        assert_eq!(orders, (0..40).collect::<Vec<u64>>());
    }

    #[tokio::test]
    async fn read_cursor_from_another_version_answers_changed() {
        let directory = tempfile::tempdir().unwrap();
        let mut conversation = Conversation::new(1, "Long");
        let mut parent = "root".to_owned();
        for index in 0..40 {
            let node = format!("n{index:02}");
            conversation = conversation.say(&node, &parent, "user", &"words ".repeat(20 * 1024));
            parent = node;
        }
        let history = open(
            &Export::new()
                .conversations(&[conversation.build()])
                .zip(&directory.path().join("export.zip")),
        );
        let first = read(&history, &fixture::id(1), None).await;
        let mut stale: Value = serde_json::from_str(first.next_cursor.as_deref().unwrap()).unwrap();
        stale["version"] = json!("0".repeat(64));
        let page = read(&history, &fixture::id(1), Some(stale.to_string())).await;
        assert!(page.items.is_empty());
        assert_eq!(page.gaps.len(), 1);
        assert!(matches!(page.gaps[0].code, HistoryGapCode::Changed));
        assert_eq!(page.gaps[0].item_id, None);
        assert!(page.next_cursor.is_none() && !page.exhausted && !page.complete);
    }

    #[tokio::test]
    async fn bytes_changed_after_check_answer_changed() {
        let directory = tempfile::tempdir().unwrap();
        let root = Export::new()
            .conversations(&[picnic(1)])
            .folder(directory.path());
        let history = open(&root);
        std::fs::write(
            root.join("conversations.json"),
            serde_json::to_vec(&[Conversation::new(1, "Rewritten")
                .say("u1", "root", "user", "Different words")
                .build()])
            .unwrap(),
        )
        .unwrap();
        let page = read(&history, &fixture::id(1), None).await;
        assert!(page.items.is_empty());
        assert!(matches!(page.gaps[0].code, HistoryGapCode::Changed));
        assert!(!page.complete);
    }

    #[tokio::test]
    async fn page_assets_carry_digests_and_sizes() {
        let directory = tempfile::tempdir().unwrap();
        let wav = fixture::wav();
        let conversation = Conversation::new(1, "Files")
            .node(
                "u1",
                Some("root"),
                upload(&[
                    ("file_0b01", "photo"),
                    ("file_0b02", "plan"),
                    ("file_0b03", "silence"),
                ]),
            )
            .build();
        let path = Export::new()
            .conversations(&[conversation])
            .stored("file_0b01-photo.dat", fixture::PNG)
            .deflated("file_0b02-plan.dat", fixture::PDF)
            .stored("file_0b03-silence.dat", &wav)
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let page = read(&history, &fixture::id(1), None).await;
        let assets: Vec<(&str, &str, Option<&str>, Option<u64>)> = page.items[0]
            .assets
            .iter()
            .map(|asset| {
                (
                    asset.path.as_str(),
                    asset.media_type.as_str(),
                    asset.sha256.as_deref(),
                    asset.size,
                )
            })
            .collect();
        let (png, pdf, wav_digest) = (sha(fixture::PNG), sha(fixture::PDF), sha(&wav));
        assert_eq!(
            assets,
            [
                (
                    "file_0b01",
                    "image/png",
                    Some(png.as_str()),
                    Some(fixture::PNG.len() as u64)
                ),
                (
                    "file_0b02",
                    "application/pdf",
                    Some(pdf.as_str()),
                    Some(fixture::PDF.len() as u64)
                ),
                (
                    "file_0b03",
                    "audio/wav",
                    Some(wav_digest.as_str()),
                    Some(wav.len() as u64)
                ),
            ]
        );
        assert!(page.complete);
        let (bytes, digest, _) = fetch(&history, &fixture::id(1), "file_0b02").await.unwrap();
        assert_eq!((bytes.as_slice(), digest), (fixture::PDF, pdf));
    }

    #[tokio::test]
    async fn forged_attachment_size_is_a_changed_gap_not_an_error() {
        let directory = tempfile::tempdir().unwrap();
        let conversation = Conversation::new(1, "Forged")
            .node("u1", Some("root"), upload(&[("file_0c01", "honest")]))
            .node("u2", Some("u1"), upload(&[("file_0c02", "forged")]))
            .build();
        let forged = vec![9; 4096];
        let path = Forge::new(
            &Export::new()
                .conversations(&[conversation])
                .stored("file_0c01-honest.dat", fixture::PNG)
                .deflated("file_0c02-forged.dat", &forged),
        )
        .size("file_0c02-forged.dat", 100)
        .write(&directory.path().join("export.zip"));
        let history = open(&path);
        let page = read(&history, &fixture::id(1), None).await;
        let honest = page.items.iter().find(|item| item.id == "u1").unwrap();
        let forged = page.items.iter().find(|item| item.id == "u2").unwrap();
        assert_eq!(honest.assets.len(), 1);
        assert!(forged.assets.is_empty());
        assert_eq!(forged.text, "Files attached");
        assert_eq!(page.gaps.len(), 1);
        assert!(matches!(page.gaps[0].code, HistoryGapCode::Changed));
        assert_eq!(page.gaps[0].item_id.as_deref(), Some("u2"));
        assert!(!page.complete);
    }

    fn refusal(path: &Path) -> PackageError {
        match ChatGptHistory::open(&[path.to_path_buf()], &mut |_| {}) {
            Ok(_) => panic!("the damaged export was admitted"),
            Err(error) => error,
        }
    }

    fn damaged(directory: &Path, flipped: &str) -> PathBuf {
        let attachment = b"Invented attachment bytes";
        Forge::new(
            &Export::new()
                .conversations(&[Conversation::new(1, "Notes")
                    .node("u1", Some("root"), upload(&[("file_0g01", "notes.txt")]))
                    .build()])
                .stored("file_0g01-notes.txt", attachment)
                .stored("file_0g02-spare.txt", attachment)
                .stored("chat.html", attachment),
        )
        .flip(flipped, 3)
        .write(&directory.join("export.zip"))
    }

    #[test]
    fn a_referenced_attachment_that_fails_its_checksum_refuses_the_export() {
        let directory = tempfile::tempdir().unwrap();
        let error = refusal(&damaged(directory.path(), "file_0g01-notes.txt"));
        assert!(
            matches!(&error, PackageError::Corrupt { member, reason: Corruption::CrcMismatch }
                if member == "file_0g01-notes.txt"),
            "{error}"
        );
    }

    #[test]
    fn an_unreferenced_member_that_fails_its_checksum_refuses_the_export() {
        for flipped in ["file_0g02-spare.txt", "chat.html"] {
            let directory = tempfile::tempdir().unwrap();
            let error = refusal(&damaged(directory.path(), flipped));
            assert!(
                matches!(&error, PackageError::Corrupt { member, reason: Corruption::CrcMismatch }
                    if member == flipped),
                "{flipped}: {error}"
            );
        }
    }

    #[tokio::test]
    async fn asset_chunks_cover_the_file_and_repeat_the_whole_file_digest() {
        let directory = tempfile::tempdir().unwrap();
        let blob: Vec<u8> = (0..1024 * 1024u32)
            .map(|index| (index * 7 % 251) as u8)
            .collect();
        let path = Export::new()
            .conversations(&[Conversation::new(1, "Blob")
                .node("u1", Some("root"), upload(&[("file_0d01", "blob.bin")]))
                .build()])
            .deflated("file_0d01-blob.dat", &blob)
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let (bytes, digest, chunks) = fetch(&history, &fixture::id(1), "file_0d01").await.unwrap();
        assert_eq!(bytes, blob);
        assert_eq!(digest, sha(&blob));
        assert_eq!(chunks, blob.len().div_ceil(ASSET_CHUNK_BYTES));
    }

    #[tokio::test]
    async fn asset_requests_are_authorized_by_thread_reference() {
        let directory = tempfile::tempdir().unwrap();
        let path = Export::new()
            .conversations(&[
                picnic(1),
                Conversation::new(2, "Photo")
                    .node("u1", Some("root"), upload(&[("file_0e01", "photo.png")]))
                    .build(),
            ])
            .stored("file_0e01-photo.dat", fixture::PNG)
            .stored("user.json", b"{\"name\": \"Invented Person\"}")
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        assert!(fetch(&history, &fixture::id(2), "file_0e01").await.is_ok());
        assert!(fetch(&history, &fixture::id(1), "file_0e01").await.is_err());
        assert!(fetch(&history, &fixture::id(1), "user.json").await.is_err());
        assert!(
            fetch(
                &history,
                "00000000-0000-4000-8000-0000000000ff",
                "file_0e01"
            )
            .await
            .is_err()
        );
    }

    #[tokio::test]
    async fn cold_evidence_asset_serves_the_envelope_bytes() {
        let directory = tempfile::tempdir().unwrap();
        let canvas = "Canvas text. ".repeat(200 * 1024 / 13);
        let path = Export::new()
            .conversations(&[Conversation::new(1, "Canvas")
                .say("a1", "root", "assistant", &canvas)
                .build()])
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let page = read(&history, &fixture::id(1), None).await;
        let reference = &page.items[0].assets[0];
        assert!(matches!(reference.kind, HistoryAssetKind::ColdEvidence));
        let (bytes, digest, _) = fetch(&history, &fixture::id(1), &reference.path)
            .await
            .unwrap();
        assert_eq!(Some(digest.as_str()), reference.sha256.as_deref());
        let envelope: ChatGptEnvelope = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(envelope.message["content"]["parts"][0], canvas);
    }

    fn spools() -> Vec<std::ffi::OsString> {
        std::fs::read_dir(std::env::temp_dir())
            .unwrap()
            .filter_map(|entry| entry.ok().map(|entry| entry.file_name()))
            .filter(|name| name.to_string_lossy().starts_with(".beep-boop-chatgpt-"))
            .collect()
    }

    #[tokio::test]
    async fn deflated_asset_spool_is_unlinked() {
        let directory = tempfile::tempdir().unwrap();
        let blob: Vec<u8> = (0..900 * 1024u32)
            .map(|index| (index % 253) as u8)
            .collect();
        let path = Export::new()
            .conversations(&[Conversation::new(1, "Blob")
                .node("u1", Some("root"), upload(&[("file_0f01", "blob.bin")]))
                .build()])
            .deflated("file_0f01-blob.dat", &blob)
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let HistoryResponse::Asset { next_offset, .. } = history
            .request(HistoryRequest::Asset {
                thread_id: fixture::id(1),
                path: "file_0f01".into(),
                offset: 0,
            })
            .await
            .unwrap()
        else {
            panic!("expected an asset chunk");
        };
        assert!(next_offset.is_some(), "the transfer is still in progress");
        assert!(spools().is_empty());
        drop(history);
        assert!(spools().is_empty());
    }

    #[tokio::test]
    async fn bare_json_reads_text_with_a_missing_attachment_gap() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("conversations.json");
        let conversation = Conversation::new(1, "Photo")
            .node("u1", Some("root"), upload(&[("file_00ab12", "beach.png")]))
            .build();
        std::fs::write(&path, serde_json::to_vec(&[conversation]).unwrap()).unwrap();
        let history = open(&path);
        let page = read(&history, &fixture::id(1), None).await;
        assert_eq!(page.items[0].text, "Files attached");
        assert!(matches!(page.gaps[0].code, HistoryGapCode::Missing));
        assert!(page.gaps[0].message.contains("file_00ab12"));
        assert!(page.exhausted && !page.complete);
    }

    #[tokio::test]
    async fn zip_and_folder_items_match_and_nested_and_sibling_assets_are_served() {
        let directory = tempfile::tempdir().unwrap();
        let photo = || {
            Conversation::new(1, "Photo")
                .node("u1", Some("root"), upload(&[("file_1a01", "beach.png")]))
                .build()
        };
        let export = Export::new()
            .conversations(&[photo()])
            .stored("file_1a01-beach.dat", fixture::PNG);
        let zipped = open(&export.zip(&directory.path().join("export.zip")));
        let folder = directory.path().join("folder");
        std::fs::create_dir(&folder).unwrap();
        let extracted = open(&export.folder(&folder));
        let versions = |items: &[HistoryItem]| {
            items
                .iter()
                .map(|item| item.version.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(
            versions(&read_all(&zipped, &fixture::id(1)).await.0),
            versions(&read_all(&extracted, &fixture::id(1)).await.0)
        );
        let portal = Export::new()
            .stored(
                "Conversations__x.zip",
                &Export::new().conversations(&[photo()]).zip_bytes(),
            )
            .deflated(
                "Files__x.zip",
                &Export::new()
                    .stored("file_1a01-beach.dat", fixture::PNG)
                    .zip_bytes(),
            )
            .zip(&directory.path().join("portal.zip"));
        let parts = directory.path().join("parts");
        std::fs::create_dir(&parts).unwrap();
        let first = Export::new()
            .conversations(&[photo()])
            .zip(&parts.join("export-part-0001.zip"));
        Export::new()
            .stored("file_1a01-beach.dat", fixture::PNG)
            .zip(&parts.join("export-part-0002.zip"));
        for history in [open(&portal), open(&first)] {
            let (items, gaps) = read_all(&history, &fixture::id(1)).await;
            assert!(gaps.is_empty());
            assert_eq!(
                items[0].assets[0].sha256.as_deref(),
                Some(sha(fixture::PNG).as_str())
            );
            let (bytes, _, _) = fetch(&history, &fixture::id(1), "file_1a01").await.unwrap();
            assert_eq!(bytes, fixture::PNG);
        }
    }

    #[tokio::test]
    async fn a_thousand_attachments_on_one_message_read_in_bounded_pages() {
        let directory = tempfile::tempdir().unwrap();
        let node = "n".repeat(256);
        let files: Vec<String> = (0..1000).map(|index| format!("file_{index:04x}")).collect();
        let references: Vec<(&str, &str)> =
            files.iter().map(|file| (file.as_str(), "photo")).collect();
        let export = files.iter().fold(
            Export::new().conversations(&[Conversation::new(1, "Album")
                .node(&node, Some("root"), upload(&references))
                .build()]),
            |export, file| export.stored(&format!("{file}-photo.dat"), fixture::PNG),
        );
        let history = open(&export.zip(&directory.path().join("export.zip")));
        let (items, gaps) = read_all(&history, &fixture::id(1)).await;
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].assets.len(), 64);
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].item_id.as_deref(), Some(node.as_str()));
        assert!(gaps[0].message.contains("936"), "{}", gaps[0].message);
    }

    #[tokio::test]
    async fn over_long_conversation_and_node_ids_are_problems_not_stranded_pages() {
        let directory = tempfile::tempdir().unwrap();
        let long = "9".repeat(600 * 1024);
        let long_conversation = Conversation::new(2, "Long id")
            .set("id", json!(long))
            .set("conversation_id", json!(long))
            .say("u1", "root", "user", "Hello")
            .build();
        let long_node = Conversation::new(3, "Long node")
            .say(&long, "root", "user", "Hello")
            .build();
        let history = open(
            &Export::new()
                .conversations(&[picnic(1), long_conversation, long_node])
                .zip(&directory.path().join("export.zip")),
        );
        let (threads, _) = list(&history, false, None).await.unwrap();
        let listed: Vec<&str> = threads.iter().map(|thread| thread.id.as_str()).collect();
        assert_eq!(listed, [fixture::id(1)]);
        assert_eq!(history.summary().problems.len(), 2);
        assert!(
            history
                .summary()
                .problems
                .iter()
                .all(|problem| problem.len() < 1024 && problem.contains("256 bytes")),
            "{:?}",
            history.summary().problems
        );
    }

    #[tokio::test]
    async fn oversized_export_strings_stay_inside_one_page() {
        let directory = tempfile::tempdir().unwrap();
        let huge = |letter: &str| letter.repeat(600 * 1024);
        let attachment = |attachment: Value| {
            json!({"author": {"role": "user"},
                "content": {"content_type": "text", "parts": ["Files attached"]},
                "metadata": {"attachments": [attachment]}})
        };
        let conversation = Conversation::new(1, "Hostile")
            .node(
                "kind",
                Some("root"),
                json!({"author": {"role": huge("r")},
                    "content": {"content_type": huge("c"), "text": "Widget"}}),
            )
            .node(
                "id",
                Some("kind"),
                attachment(json!({"id": format!("file_{}", huge("a"))})),
            )
            .node(
                "name",
                Some("id"),
                attachment(json!({"id": "file_0b01", "name": huge("x")})),
            )
            .node(
                "mime",
                Some("name"),
                attachment(json!({"id": "file_0b02", "mime_type": huge("m")})),
            )
            .build();
        let history = open(
            &Export::new()
                .conversations(&[conversation])
                .stored("file_0b02-photo.dat", fixture::PNG)
                .zip(&directory.path().join("export.zip")),
        );
        let (items, gaps) = read_all(&history, &fixture::id(1)).await;
        let ids: Vec<&str> = items.iter().map(|item| item.id.as_str()).collect();
        assert_eq!(ids, ["kind", "id", "name", "mime"]);
        assert_eq!(items[3].assets[0].media_type, "image/png");
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].item_id.as_deref(), Some("name"));
    }

    #[tokio::test]
    async fn many_parent_cycles_report_one_thread_gap() {
        let directory = tempfile::tempdir().unwrap();
        let conversation = (0..500).fold(
            Conversation::new(1, "Cycles").say("u1", "root", "user", "Hello"),
            |conversation, index| {
                let (left, right) = (format!("a{index:03}"), format!("b{index:03}"));
                conversation.say(&left, &right, "user", "Loop").say(
                    &right,
                    &left,
                    "assistant",
                    "Loop",
                )
            },
        );
        let history = open(
            &Export::new()
                .conversations(&[conversation.current("u1").build()])
                .zip(&directory.path().join("export.zip")),
        );
        let (items, gaps) = read_all(&history, &fixture::id(1)).await;
        assert_eq!(items.len(), 1001);
        assert_eq!(gaps.len(), 1);
        assert_eq!(gaps[0].item_id, None);
        assert!(matches!(gaps[0].code, HistoryGapCode::Invalid));
    }

    #[tokio::test]
    async fn an_uploaded_zip_is_served_as_an_opaque_attachment() {
        let directory = tempfile::tempdir().unwrap();
        let report = Export::new().conversations(&[picnic(9)]).zip_bytes();
        let path = Export::new()
            .conversations(&[Conversation::new(1, "Report")
                .node(
                    "u1",
                    Some("root"),
                    upload(&[("file-Report1", "report.zip")]),
                )
                .build()])
            .deflated("file-Report1-report.zip", &report)
            .zip(&directory.path().join("export.zip"));
        let history = open(&path);
        let (threads, _) = list(&history, false, None).await.unwrap();
        assert_eq!(threads.len(), 1);
        let page = read(&history, &fixture::id(1), None).await;
        assert_eq!(page.items[0].assets[0].media_type, "application/zip");
        let (bytes, _, _) = fetch(&history, &fixture::id(1), "file-Report1")
            .await
            .unwrap();
        assert_eq!(bytes, report);
    }
}
