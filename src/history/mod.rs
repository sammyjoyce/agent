//! Inert, checkpointed history reads. Importing history never starts work.

pub mod chatgpt;
pub mod codex;

use anyhow::Result;
use async_trait::async_trait;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

use crate::protocol::HistoryRole;

/// The transport budget of one serialized history response, for every source.
pub(crate) const PAGE_BYTES: usize = 500 * 1024;

/// The longest UTF-8-safe prefix of `text` within `maximum` bytes.
pub(crate) fn excerpt(text: &str, maximum: usize) -> String {
    let end = text
        .char_indices()
        .map(|(index, _)| index)
        .take_while(|index| *index <= maximum)
        .last()
        .unwrap_or(0);
    if text.len() <= maximum {
        text.into()
    } else {
        text[..end].into()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HistoryRequest {
    List {
        archived: bool,
        cursor: Option<String>,
    },
    Read {
        thread_id: String,
        cursor: Option<String>,
    },
    Asset {
        thread_id: String,
        path: String,
        #[ts(type = "number")]
        offset: u64,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryThread {
    pub id: String,
    pub title: String,
    pub cwd: String,
    #[ts(type = "number")]
    pub created_at: i64,
    #[ts(type = "number")]
    pub updated_at: i64,
    pub forked_from_id: Option<String>,
    pub parent_thread_id: Option<String>,
    pub version: String,
    #[serde(default)]
    pub version_reliable: bool,
    pub archived: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum HistoryAssetKind {
    LocalMedia,
    InlineMedia,
    ColdEvidence,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryAssetRef {
    pub path: String,
    pub item_id: String,
    pub version: String,
    pub kind: HistoryAssetKind,
    pub media_type: String,
    pub sha256: Option<String>,
    #[ts(type = "number | null")]
    pub size: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryItem {
    pub id: String,
    pub turn_id: String,
    pub kind: String,
    pub role: HistoryRole,
    pub text: String,
    pub version: String,
    #[ts(type = "number")]
    pub order: u64,
    #[ts(type = "number | null")]
    pub timestamp_ms: Option<i64>,
    // Native evidence only. This field contributes no model messages.
    #[ts(type = "unknown")]
    pub data: serde_json::Value,
    pub assets: Vec<HistoryAssetRef>,
    /// Placement in a source's branch tree. Absent for sources without branches and for
    /// items saved before branches existed; readers treat absence as shown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub branch: Option<HistoryBranch>,
}

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryBranch {
    pub state: HistoryBranchState,
    /// Sibling subtrees the source kept but did not select at this point. Nonzero only on
    /// current items.
    pub alternates: u32,
    /// Version of the previous current item. A re-versioned current item therefore
    /// re-versions every later one, and they re-append in path order instead of
    /// aliasing to entries that sit before it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub follows: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum HistoryBranchState {
    /// On the path from the root to the leaf the source last displayed.
    Current,
    /// Reachable from a root, on a branch the source did not select.
    Alternate,
    /// Unreachable from every root, as in a parent cycle.
    Detached,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum HistoryGapCode {
    Missing,
    Unsupported,
    Oversized,
    Unavailable,
    Changed,
    Invalid,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryGap {
    pub code: HistoryGapCode,
    pub item_id: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HistoryResponse {
    List {
        threads: Vec<HistoryThread>,
        next_cursor: Option<String>,
    },
    Read {
        thread_id: String,
        version: String,
        items: Vec<HistoryItem>,
        next_cursor: Option<String>,
        /// Durable catch-up position, including EOF, separate from this walk's continuation.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        resume_cursor: Option<String>,
        gaps: Vec<HistoryGap>,
        complete: bool,
        // The native transcript reached EOF, independent of missing media.
        #[serde(default)]
        #[ts(optional = nullable)]
        source_exhausted: bool,
    },
    Asset {
        path: String,
        #[ts(type = "number")]
        offset: u64,
        data_base64: String,
        #[ts(type = "number | null")]
        next_offset: Option<u64>,
        #[ts(type = "number")]
        total_bytes: u64,
        sha256: String,
    },
}

#[async_trait]
pub trait HistorySource: Send + Sync {
    async fn request(&self, request: HistoryRequest) -> Result<HistoryResponse>;
}

#[cfg(test)]
mod tests {
    use super::{HistoryBranchState, HistoryItem};

    #[test]
    fn history_item_without_branch_still_decodes() {
        let saved = r#"{"id":"item","turn_id":"turn","kind":"userMessage","role":"user","text":"Hello","version":"v1","order":0,"timestamp_ms":null,"data":null,"assets":[]}"#;
        let item: HistoryItem = serde_json::from_str(saved).unwrap();
        assert!(item.branch.is_none());
        assert_eq!(serde_json::to_string(&item).unwrap(), saved);
        let placed: HistoryItem = serde_json::from_str(&saved.replace(
            r#""assets":[]"#,
            r#""assets":[],"branch":{"state":"alternate","alternates":0}"#,
        ))
        .unwrap();
        assert_eq!(
            placed.branch.map(|branch| (branch.state, branch.follows)),
            Some((HistoryBranchState::Alternate, None))
        );
    }
}
