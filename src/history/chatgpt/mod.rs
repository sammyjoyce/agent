//! A locally checked ChatGPT data export, served as inert history.

mod archive;
mod conversation;
#[cfg(test)]
mod fixture;
mod json;
mod package;

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

/// One step of the check, for people watching stderr.
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
