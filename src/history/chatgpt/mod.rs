//! A locally checked ChatGPT data export, served as inert history.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

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
    #[ts(type = "unknown")]
    pub message: serde_json::Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    #[ts(optional, type = "unknown[]")]
    pub library_files: Vec<serde_json::Value>,
}
