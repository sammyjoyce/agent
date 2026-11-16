//! A locally checked ChatGPT data export, served as inert history.

mod archive;
mod conversation;
#[cfg(test)]
mod fixture;
mod json;
mod package;

use std::{
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
    HistoryGap, HistoryGapCode, HistoryRequest, HistoryResponse, HistorySource, PAGE_BYTES,
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

/// The inert evidence stored as `HistoryItem.data` for one ChatGPT item. It is built from
/// the fields readers use, so nothing else in the export's message reaches storage.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptEnvelope {
    pub conversation_id: String,
    pub node_id: String,
    pub parent_id: Option<String>,
    /// The whole normalized message text, citations removed. `HistoryItem.text` is its excerpt.
    pub text: String,
    /// Null for a `library:file` item, which has no message.
    pub message: Option<ChatGptMessage>,
    /// The files the item references, up to its attachment limit. The checked digest is part of
    /// the evidence, so other bytes under the same file id are a new item version, never a
    /// refresh of the old one.
    pub attachments: Vec<ChatGptAttachment>,
}

/// The retained header of an export message. Each field is copied when the export has it as a
/// string.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptMessage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub id: Option<String>,
    pub author: ChatGptAuthor,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub recipient: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub channel: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub status: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub content_type: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptAuthor {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub role: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub name: Option<String>,
}

/// A file one ChatGPT item references.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ChatGptAttachment {
    pub file_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub mime_type: Option<String>,
    /// The SHA-256 of the checked bytes. Absent when the export does not hold the file.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub sha256: Option<String>,
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
    transfer: Option<(package::MemberId, archive::Region)>,
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
            let item = item.clone();
            let mut item_gaps: Vec<HistoryGap> = normalized
                .gaps
                .iter()
                .filter(|gap| gap.item_id.as_deref() == Some(item.id.as_str()))
                .cloned()
                .collect();
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
                let indexed = self
                    .package
                    .file(file)
                    .context("Attachment is not in this export")?;
                let digest = &indexed.digest;
                ensure!(
                    offset <= digest.size,
                    "History asset offset exceeds its size"
                );
                let region = self.transfer_region(state, indexed.member)?;
                ensure!(
                    region.len() == digest.size,
                    "Attachment changed after it was checked"
                );
                let length = (digest.size - offset).min(ASSET_CHUNK_BYTES as u64) as usize;
                let mut chunk = vec![0; length];
                region.read_exact_at(&mut chunk, offset)?;
                (chunk, digest.size, digest.sha256.clone())
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
    Files {
        count: u32,
        bytes: u64,
    },
}

impl std::fmt::Display for PackageProgress {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Part { name } => write!(formatter, "Checking {name}"),
            Self::Shard { name, index, count } => {
                write!(formatter, "Checking {name} ({index}/{count})")
            }
            Self::Files { count, bytes } => {
                write!(
                    formatter,
                    "Checking the bytes of {count} files ({bytes} bytes)"
                )
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
    use std::{collections::HashMap, path::Path};

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
                "b54f3a3b38e2dedfcb4de7e71773a36a40b160bc32547b3cd687c49efcacf35d",
                "4d51a21777f8a0cb006d2402f64359ca9820472e7cf1a8c3f01906b116537c3b",
                "cb963972bacf0447cdabc0dde65ffe3c900bc3478122ccb4b655517aca11933a",
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

    #[test]
    fn forged_attachment_size_refuses_the_export() {
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
        let error = refusal(&path);
        assert!(
            matches!(&error, PackageError::Corrupt { member, reason: Corruption::LongerThanDeclared }
                if member == "file_0c02-forged.dat"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn attachment_changed_after_the_check_is_served_with_its_checked_digest() {
        let directory = tempfile::tempdir().unwrap();
        let root = Export::new()
            .conversations(&[Conversation::new(1, "Notes")
                .node("u1", Some("root"), upload(&[("file_0c03", "notes.txt")]))
                .build()])
            .stored("file_0c03-notes.txt", b"First attachment")
            .folder(directory.path());
        let history = open(&root);
        std::fs::write(root.join("file_0c03-notes.txt"), b"Other attachment").unwrap();
        let checked = sha(b"First attachment");
        let page = read(&history, &fixture::id(1), None).await;
        assert_eq!(
            page.items[0].assets[0].sha256.as_deref(),
            Some(checked.as_str())
        );
        let (bytes, served, _) = fetch(&history, &fixture::id(1), "file_0c03").await.unwrap();
        assert_eq!(served, checked);
        assert_ne!(
            sha(&bytes),
            served,
            "the coordinator refuses bytes that miss the digest"
        );
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

    async fn thread_versions(history: &ChatGptHistory) -> HashMap<String, String> {
        let (threads, _) = list(history, false, None).await.unwrap();
        threads
            .into_iter()
            .map(|thread| (thread.id, thread.version))
            .collect()
    }

    async fn item_versions(history: &ChatGptHistory, thread: &str) -> HashMap<String, String> {
        read_all(history, thread)
            .await
            .0
            .into_iter()
            .map(|item| (item.id, item.version))
            .collect()
    }

    #[tokio::test]
    async fn same_size_attachment_with_other_bytes_changes_only_what_references_it() {
        let directory = tempfile::tempdir().unwrap();
        let export = |folder: &str, attachment: &[u8]| {
            let root = directory.path().join(folder);
            std::fs::create_dir(&root).unwrap();
            open(
                &Export::new()
                    .conversations(&[
                        Conversation::new(1, "Notes")
                            .say("u1", "root", "user", "Keep my notes")
                            .say("a1", "u1", "assistant", "Send them over")
                            .node("u2", Some("a1"), upload(&[("file_0h01", "notes.txt")]))
                            .build(),
                        picnic(2),
                    ])
                    .stored("file_0h01-notes.txt", attachment)
                    .folder(&root),
            )
        };
        let first = export("one", b"First attachment");
        let other = export("two", b"Other attachment");
        assert_ne!(first.summary().digest, other.summary().digest);
        let (threads, other_threads) =
            (thread_versions(&first).await, thread_versions(&other).await);
        let (notes, picnic) = (fixture::id(1), fixture::id(2));
        assert_ne!(threads[&notes], other_threads[&notes]);
        assert_eq!(threads[&picnic], other_threads[&picnic]);
        let items = item_versions(&first, &notes).await;
        let other_items = item_versions(&other, &notes).await;
        assert_ne!(items["u2"], other_items["u2"]);
        let upload = async |history| {
            let (items, _) = read_all(history, &notes).await;
            items.into_iter().find(|item| item.id == "u2").unwrap().data
        };
        assert_ne!(
            upload(&first).await,
            upload(&other).await,
            "the importer refreshes an item whose evidence is unchanged instead of keeping a new revision"
        );
        for unchanged in ["u1", "a1"] {
            assert_eq!(items[unchanged], other_items[unchanged], "{unchanged}");
        }
        assert_eq!(
            item_versions(&first, &picnic).await,
            item_versions(&other, &picnic).await
        );
    }

    struct Served {
        text: String,
        cold_evidence: usize,
    }

    /// Every list and read response an import requests, and the bytes of every asset its
    /// items reference.
    async fn serve_everything(history: &ChatGptHistory) -> Served {
        let mut served = Served {
            text: String::new(),
            cold_evidence: 0,
        };
        for archived in [false, true] {
            let (threads, _) = list(history, archived, None).await.unwrap();
            served.text += &serde_json::to_string(&threads).unwrap();
            for thread in threads {
                let mut cursor = None;
                loop {
                    let response = history
                        .request(HistoryRequest::Read {
                            thread_id: thread.id.clone(),
                            cursor,
                        })
                        .await
                        .unwrap();
                    served.text += &serde_json::to_string(&response).unwrap();
                    let HistoryResponse::Read {
                        items, next_cursor, ..
                    } = response
                    else {
                        panic!("expected a read");
                    };
                    for asset in items.iter().flat_map(|item| &item.assets) {
                        if matches!(asset.kind, HistoryAssetKind::ColdEvidence) {
                            served.cold_evidence += 1;
                        }
                        let (bytes, _, _) = fetch(history, &thread.id, &asset.path).await.unwrap();
                        served.text += &String::from_utf8_lossy(&bytes);
                    }
                    match next_cursor {
                        Some(next) => cursor = Some(next),
                        None => break,
                    }
                }
            }
        }
        served
    }

    fn assert_no_canary(served: &Served) {
        let leaked: Vec<String> = served
            .text
            .match_indices("PRIVATE_")
            .map(|(index, _)| served.text[index..].chars().take(32).collect())
            .collect();
        assert!(leaked.is_empty(), "{leaked:?}");
    }

    fn private_answer(node: &str, text: &str) -> Value {
        let mut hidden = fixture::text_message("assistant", "PRIVATE_HIDDEN_CANARY");
        hidden["metadata"] = json!({"is_visually_hidden_from_conversation": true});
        let mut answer = fixture::text_message("assistant", text);
        answer["id"] = json!(node);
        answer["metadata"] = json!({
            "aggregate_result": {"messages": [
                fixture::text_message("system", "PRIVATE_SYSTEM_CANARY"),
                hidden,
            ]},
            "citations": [{"metadata": {"user_context_message_data": "PRIVATE_CUSTOM_CANARY"}}],
            "user_context_message_data": "PRIVATE_DIRECT_CANARY",
        });
        answer
    }

    fn privacy_probe(answer: &str) -> Conversation {
        Conversation::new(1, "Invented audit")
            .say("u", "root", "user", "Public user text")
            .node("a", Some("u"), private_answer("a", answer))
    }

    #[tokio::test]
    async fn privacy_probe_serves_no_canary() {
        let directory = tempfile::tempdir().unwrap();
        let history = open(
            &Export::new()
                .conversations(&[privacy_probe("Public answer").build()])
                .zip(&directory.path().join("privacy.zip")),
        );
        let served = serve_everything(&history).await;
        assert!(served.text.contains("Public answer"));
        assert_no_canary(&served);
    }

    #[tokio::test]
    async fn alternate_probe_serves_no_canary() {
        let directory = tempfile::tempdir().unwrap();
        let mut alternate = fixture::text_message("assistant", "Alternate answer");
        alternate["metadata"] = json!({"aggregate_result": {"messages": [
            fixture::text_message("developer", "PRIVATE_ALTERNATE_CANARY"),
        ]}});
        let history = open(
            &Export::new()
                .conversations(&[privacy_probe("Public answer")
                    .node("alt", Some("u"), alternate)
                    .current("a")
                    .build()])
                .zip(&directory.path().join("alternate.zip")),
        );
        let served = serve_everything(&history).await;
        assert!(served.text.contains("Alternate answer"));
        assert_no_canary(&served);
    }

    #[tokio::test]
    async fn privacy_cold_probe_serves_no_canary() {
        let directory = tempfile::tempdir().unwrap();
        let answer = "Visible invented long answer. ".repeat(6000);
        let history = open(
            &Export::new()
                .conversations(&[privacy_probe(&answer).build()])
                .zip(&directory.path().join("privacy-cold.zip")),
        );
        let served = serve_everything(&history).await;
        assert_eq!(served.cold_evidence, 1);
        assert_no_canary(&served);
    }

    #[tokio::test]
    async fn hidden_library_probe_serves_no_canary() {
        let directory = tempfile::tempdir().unwrap();
        let mut hidden = fixture::text_message("system", "PRIVATE_EXCLUDED_CANARY");
        hidden["id"] = json!("hidden-message-id-not-mapping-key");
        hidden["metadata"] = json!({"attachments": [{"id": "file-SECRET", "name": "secret.txt"}]});
        let library = json!([{
            "origination_thread_id": fixture::id(1),
            "origination_message_id": "hidden-message-id-not-mapping-key",
            "file_id": "file-SECRET", "file_name": "secret.txt", "mime_type": "text/plain",
            "metadata": {"user_context_message_data": "PRIVATE_LIBRARY_CANARY"},
        }]);
        let history = open(
            &Export::new()
                .conversations(&[Conversation::new(1, "Invented audit")
                    .node("hidden", Some("root"), hidden)
                    .build()])
                .json("library_files.json", &library)
                .stored("file-SECRET-secret.txt", b"PRIVATE_ATTACHMENT_CANARY")
                .folder(directory.path()),
        );
        assert_eq!(history.summary().attachments, 0);
        let (items, _) = read_all(&history, &fixture::id(1)).await;
        let ids: Vec<&str> = items.iter().map(|item| item.id.as_str()).collect();
        assert!(ids.is_empty(), "{ids:?}");
        assert!(
            fetch(&history, &fixture::id(1), "file-SECRET")
                .await
                .is_err()
        );
        assert_no_canary(&serve_everything(&history).await);
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
        assert_eq!(envelope.text, canvas);
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
