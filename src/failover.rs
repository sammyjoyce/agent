//! Wire types of the failover authority: one Cloudflare Durable Object per
//! coordinator that grants the owner epoch and holds the replication log.
//! The authority's rules are `decide` in `runtime/src/failover/authority-core.ts`.

use anyhow::{Result, ensure};
use serde::{Deserialize, Serialize};
use ts_rs::TS;
use uuid::Uuid;

/// JavaScript carries these counters as numbers, so they stay exact only below 2^53.
const MAX_EXACT: u64 = 9_007_199_254_740_991;

/// Granted only by the authority. Rises at every coordinator start and at every promotion.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct OwnerEpoch(#[ts(type = "number")] u64);

/// Position of an entry in the replication log. The first entry is at 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct LogPosition(#[ts(type = "number")] u64);

macro_rules! exact_counter {
    ($name:ident) => {
        impl $name {
            pub fn new(value: u64) -> Result<Self> {
                ensure!(
                    value <= MAX_EXACT,
                    concat!(stringify!($name), " is above 2^53 - 1")
                );
                Ok(Self(value))
            }

            pub fn get(self) -> u64 {
                self.0
            }
        }

        impl TryFrom<u64> for $name {
            type Error = anyhow::Error;

            fn try_from(value: u64) -> Result<Self> {
                Self::new(value)
            }
        }

        impl From<$name> for u64 {
            fn from(value: $name) -> u64 {
                value.0
            }
        }
    };
}

exact_counter!(OwnerEpoch);
exact_counter!(LogPosition);

/// One host's right to hold ownership.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(transparent)]
pub struct HolderId(Uuid);

impl HolderId {
    pub fn new(value: Uuid) -> Self {
        Self(value)
    }

    pub fn get(self) -> Uuid {
        self.0
    }
}

/// A lowercase hexadecimal SHA-256 digest.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(try_from = "String", into = "String")]
pub struct Sha256Hex(String);

impl Sha256Hex {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Sha256Hex {
    type Error = anyhow::Error;

    fn try_from(value: String) -> Result<Self> {
        ensure!(
            value.len() == 64
                && value
                    .bytes()
                    .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f')),
            "A SHA-256 digest is 64 lowercase hexadecimal characters"
        );
        Ok(Self(value))
    }
}

impl From<Sha256Hex> for String {
    fn from(value: Sha256Hex) -> String {
        value.0
    }
}

/// The retained file trees that replicate beside `session.sqlite`.
pub const REPLICATED_FILE_ROOTS: [&str; 3] = ["attachments", "history/assets", "feedback"];

/// A file path relative to the state directory, inside a replicated tree.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(try_from = "String", into = "String")]
pub struct StatePath(String);

impl StatePath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for StatePath {
    type Error = anyhow::Error;

    fn try_from(value: String) -> Result<Self> {
        let plain = value
            .split('/')
            .all(|segment| !matches!(segment, "" | "." | "..") && !segment.contains(['\\', '\0']));
        let replicated = REPLICATED_FILE_ROOTS.iter().any(|root| {
            value
                .strip_prefix(root)
                .is_some_and(|rest| rest.starts_with('/'))
        });
        ensure!(
            plain && replicated,
            "A replicated file path is relative and lies under attachments, history/assets or feedback"
        );
        Ok(Self(value))
    }
}

impl From<StatePath> for String {
    fn from(value: StatePath) -> String {
        value.0
    }
}

/// Why the old owner is taken to be stopped. No variant is built from a timeout.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum StopEvidence {
    /// The old owner saw the seal, cancelled and reaped its effects, closed its
    /// worker links, then said so.
    Released,
    /// `failover release` on the old host took `writer.lock`, so no supervisor
    /// or Pi child of the old owner survives.
    LockHeld,
    /// The old host cannot be reached. The operator's statement is stored verbatim.
    OperatorAttested { statement: String },
}

/// The stop evidence a sealed holder may post about itself.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum ReleaseEvidence {
    Released,
    LockHeld,
}

/// The one row the authority keeps about ownership.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthorityState {
    Active {
        epoch: OwnerEpoch,
        holder: HolderId,
        head: LogPosition,
    },
    /// The old owner is revoked. Nobody may append.
    Sealed {
        epoch: OwnerEpoch,
        holder: HolderId,
        candidate: HolderId,
        head: LogPosition,
    },
    /// The old owner is taken to be stopped. The candidate may activate once it
    /// has applied `head`.
    Vacant {
        epoch: OwnerEpoch,
        candidate: HolderId,
        evidence: StopEvidence,
        head: LogPosition,
    },
}

/// The versions that wrote a log entry, so a standby refuses a batch its own
/// Pi cannot replay.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct Versions {
    pub application: String,
    pub pi_durable: String,
    pub chord: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct FileRecord {
    pub path: StatePath,
    pub sha256: Sha256Hex,
    #[ts(type = "number")]
    pub size: u64,
}

/// Pi's `StorageWrite[]` for one commit, as JSON. A large batch is stored in
/// the blob store and named by its hash, because one authority row has a size limit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BatchBody {
    Inline {
        json: String,
    },
    Blob {
        sha256: Sha256Hex,
        #[ts(type = "number")]
        size: u64,
    },
}

/// One replication log entry: the files a commit needs, then the commit. A
/// file-only entry has neither `pi_seq` nor `batch`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct LogEntry {
    pub at: LogPosition,
    pub epoch: OwnerEpoch,
    /// SHA-256 over every other field, which tells a repeat from a conflict.
    pub digest: Sha256Hex,
    pub versions: Versions,
    /// The sequence Pi assigns this batch. A standby commits it only there.
    #[ts(type = "number | null")]
    pub pi_seq: Option<u64>,
    pub files: Vec<FileRecord>,
    pub batch: Option<BatchBody>,
}

/// A snapshot of the whole replicated state. The log holds only entries after `through`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CheckpointRecord {
    pub through: LogPosition,
    /// The backup manifest of the snapshot, stored in the blob store with every file it names.
    pub manifest: Sha256Hex,
}

/// A change to the authority. Each one is a single transaction in the object.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthorityCommand {
    /// Creates the record, active at epoch 1. A repeat by the same holder returns it.
    Enroll {
        holder: HolderId,
        checkpoint: CheckpointRecord,
    },
    /// A coordinator start by the current owner. Raises the epoch.
    Claim {
        holder: HolderId,
    },
    Append {
        holder: HolderId,
        entry: LogEntry,
    },
    /// Proves the caller is still the owner. Writes nothing.
    Confirm {
        holder: HolderId,
        epoch: OwnerEpoch,
    },
    /// Seals the log for `candidate`. With an attestation the old owner is also
    /// taken to be stopped.
    Promote {
        candidate: HolderId,
        expected_epoch: OwnerEpoch,
        attestation: Option<String>,
    },
    Release {
        holder: HolderId,
        epoch: OwnerEpoch,
        evidence: ReleaseEvidence,
    },
    Activate {
        candidate: HolderId,
        applied: LogPosition,
    },
    /// Moves the snapshot pointer and drops the log entries it covers.
    Checkpoint {
        holder: HolderId,
        epoch: OwnerEpoch,
        record: CheckpointRecord,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(rename_all = "snake_case")]
pub enum AuthorityRefusal {
    NotEnrolled,
    /// Another holder enrolled this coordinator.
    Enrolled,
    /// The log is sealed for a promotion.
    Sealed,
    /// The caller is not the current owner at the current epoch.
    Fenced,
    /// The entry is beyond the next log position.
    Gap,
    /// The log holds a different entry at that position.
    Conflict,
    /// The command names a blob the blob store does not hold: a file or the
    /// batch of an entry, or the manifest of a checkpoint.
    MissingBlob,
    /// The epoch the operator named is not the current one.
    EpochMoved,
    AlreadyOwner,
    /// The sealed holder releases. It does not attest about itself.
    SelfAttestation,
    NotSealed,
    NotSealedHolder,
    NotCandidate,
    NotCaughtUp,
    /// The checkpoint is behind the current one or beyond the head.
    CheckpointOutOfRange,
}

/// The authority's answer to a command. A refusal carries the record, so the
/// caller can name the current owner and epoch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum AuthorityReply {
    Accepted {
        state: AuthorityState,
    },
    Refused {
        reason: AuthorityRefusal,
        state: Option<AuthorityState>,
    },
}

/// What the authority holds for one enrolled coordinator, besides the log entries.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct AuthorityRecord {
    pub state: AuthorityState,
    pub checkpoint: CheckpointRecord,
}

/// Log entries after a position, in order, with the record they were read under.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct LogPage {
    pub record: AuthorityRecord,
    pub entries: Vec<LogEntry>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_paths_stay_inside_the_replicated_trees() {
        for accepted in [
            "attachments/a1/content",
            "history/assets/ab/cd.png",
            "feedback/latest",
        ] {
            assert!(
                StatePath::try_from(accepted.to_owned()).is_ok(),
                "{accepted}"
            );
        }
        for refused in [
            "/attachments/a",
            "attachments",
            "attachments/",
            "attachments/../auth.json",
            "attachments//a",
            "attachments/./a",
            "history/index.sqlite",
            "auth.json",
            "feedbacks/a",
            "attachments\\a",
        ] {
            assert!(
                StatePath::try_from(refused.to_owned()).is_err(),
                "{refused}"
            );
        }
    }

    #[test]
    fn counters_and_digests_parse_only_exact_values() {
        assert!(serde_json::from_str::<OwnerEpoch>("9007199254740991").is_ok());
        assert!(serde_json::from_str::<OwnerEpoch>("9007199254740992").is_err());
        assert!(serde_json::from_str::<LogPosition>("-1").is_err());
        assert!(serde_json::from_value::<Sha256Hex>("ab".repeat(32).into()).is_ok());
        assert!(serde_json::from_value::<Sha256Hex>("AB".repeat(32).into()).is_err());
        assert!(serde_json::from_value::<Sha256Hex>("ab".repeat(31).into()).is_err());
    }

    #[test]
    fn a_release_cannot_carry_an_attestation() {
        let command = serde_json::json!({
            "op": "release",
            "holder": Uuid::nil(),
            "epoch": 1,
            "evidence": { "kind": "operator_attested", "statement": "invented" },
        });
        assert!(serde_json::from_value::<AuthorityCommand>(command).is_err());
    }
}
