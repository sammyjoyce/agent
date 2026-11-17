//! Wire types of the failover authority: one Cloudflare Durable Object per
//! coordinator that grants the owner epoch and holds the replication log.
//! The authority's rules are `decide` in `runtime/src/failover/authority-core.ts`.

use std::{
    fmt, fs,
    marker::PhantomData,
    net::{Ipv4Addr, Ipv6Addr},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    time::Duration,
};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use ts_rs::TS;
use uuid::Uuid;

use crate::{coordinator_id::CoordinatorId, runtime::WriterLock};

pub mod commands;

/// JavaScript carries these counters as numbers, so they stay exact only below 2^53.
const MAX_EXACT: u64 = 9_007_199_254_740_991;

/// The exit status of a coordinator the authority fenced, from the supervisor
/// and from its Pi child alike, so a service manager can leave it stopped.
pub const OWNER_FENCED_EXIT: u8 = 75;

/// The exit status of `failover/helper.js` and `failover/operator.js` when the
/// authority did not answer, so a caller can tell a request that is safe to
/// repeat from a failure.
pub const AUTHORITY_UNREACHABLE_EXIT: u8 = 69;

/// The largest part of a checkpoint file. One Worker request body holds at
/// most 100 MB and a Worker has 128 MB of memory.
pub const CHECKPOINT_PART_BYTES: u64 = 16 * 1024 * 1024;

/// The `format` of every checkpoint manifest this build writes and reads.
pub const CHECKPOINT_FORMAT: u32 = 1;

/// Granted only by the authority. Rises at every coordinator start and at every promotion.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct OwnerEpoch(#[ts(type = "number")] u64);

/// Position of an entry in the replication log. The first entry is at 1.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct LogPosition(#[ts(type = "number")] u64);

/// The sequence Pi assigns a commit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct PiSequence(#[ts(type = "number")] u64);

/// The size of a file or a blob, in bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize, TS)]
#[serde(try_from = "u64", into = "u64")]
pub struct ByteSize(#[ts(type = "number")] u64);

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
exact_counter!(PiSequence);
exact_counter!(ByteSize);

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
    /// The old owner saw the seal, cancelled and reaped its local effects,
    /// closed its worker links, then said so. It does not prove that an effect
    /// on a worker has ended.
    Released,
    /// A command on the old host took `writer.lock` and then `effects.lock`,
    /// so no supervisor, Pi child or local effect process of the old owner
    /// survives. It does not prove that an effect on a worker has ended.
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
    pub size: ByteSize,
}

/// Pi's `StorageWrite[]` for one commit, as JSON. A large batch is stored in
/// the blob store and named by its hash, because one authority row has a size limit.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum BatchBody {
    Inline { json: String },
    Blob { sha256: Sha256Hex, size: ByteSize },
}

/// Pi's `StorageWrite[]` for one commit, and the sequence Pi assigns it. A
/// standby commits it only there.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct LoggedBatch {
    pub pi_seq: PiSequence,
    pub body: BatchBody,
}

/// One replication log entry: the files a commit needs, then the commit. A
/// file-only entry has no batch.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct LogEntry {
    pub at: LogPosition,
    pub epoch: OwnerEpoch,
    /// SHA-256 over every other field, which tells a repeat from a conflict.
    pub digest: Sha256Hex,
    pub versions: Versions,
    pub files: Vec<FileRecord>,
    pub batch: Option<LoggedBatch>,
}

/// A snapshot of the whole replicated state. The log holds only entries after `through`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CheckpointRecord {
    pub through: LogPosition,
    /// The backup manifest of the snapshot, stored in the blob store with every file it names.
    pub manifest: Sha256Hex,
}

/// A file path inside a checkpoint archive, relative to the archive.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize, TS)]
#[serde(try_from = "String", into = "String")]
pub struct ArchivePath(String);

impl ArchivePath {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for ArchivePath {
    type Error = anyhow::Error;

    fn try_from(value: String) -> Result<Self> {
        ensure!(
            value.split('/').all(|segment| {
                !matches!(segment, "" | "." | "..") && !segment.contains(['\\', '\0'])
            }),
            "A checkpoint file path is relative and has no empty, `.` or `..` segment"
        );
        Ok(Self(value))
    }
}

impl From<ArchivePath> for String {
    fn from(value: ArchivePath) -> String {
        value.0
    }
}

/// One file of a checkpoint. Each part is a blob of at most
/// `CHECKPOINT_PART_BYTES`, and the parts in order are the file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CheckpointFile {
    pub path: ArchivePath,
    #[ts(type = "number")]
    pub size: u64,
    pub sha256: Sha256Hex,
    pub parts: Vec<Sha256Hex>,
}

/// The blob that `CheckpointRecord.manifest` names: a backup archive of the
/// state directory at log position `through`, its `manifest.json` included.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct CheckpointManifest {
    pub format: u32,
    pub through: LogPosition,
    pub coordinator_id: CoordinatorId,
    pub files: Vec<CheckpointFile>,
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

/// The authority's address: https, or http on a loopback address for tests and
/// local workerd. It carries no user name, password or escapes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(try_from = "String", into = "String")]
pub struct AuthorityUrl(String);

impl AuthorityUrl {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for AuthorityUrl {
    type Error = anyhow::Error;

    fn try_from(value: String) -> Result<Self> {
        ensure!(
            authority_url_allowed(&value),
            "The failover url must be https, or http on a loopback address, without a user name, password or escapes"
        );
        Ok(Self(value))
    }
}

impl From<AuthorityUrl> for String {
    fn from(value: AuthorityUrl) -> String {
        value.0
    }
}

fn authority_url_allowed(value: &str) -> bool {
    let (secure, rest) = match (
        value.strip_prefix("https://"),
        value.strip_prefix("http://"),
    ) {
        (Some(rest), _) => (true, rest),
        (None, Some(rest)) => (false, rest),
        (None, None) => return false,
    };
    if !value
        .bytes()
        .all(|byte| byte.is_ascii_graphic() && !matches!(byte, b'\\' | b'@' | b'%'))
    {
        return false;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let (host, port, loopback) = match authority.strip_prefix('[') {
        Some(bracketed) => {
            let Some((host, after)) = bracketed.split_once(']') else {
                return false;
            };
            let Ok(address) = host.parse::<Ipv6Addr>() else {
                return false;
            };
            let port = match after {
                "" => None,
                after => match after.strip_prefix(':') {
                    Some(port) => Some(port),
                    None => return false,
                },
            };
            (host, port, address.is_loopback())
        }
        None => {
            let (host, port) = match authority.split_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (authority, None),
            };
            let loopback = host.eq_ignore_ascii_case("localhost")
                || host.parse::<Ipv4Addr>().is_ok_and(|ip| ip.is_loopback());
            (host, port, loopback)
        }
    };
    let port_valid = port.is_none_or(|port| {
        !port.is_empty()
            && port.bytes().all(|byte| byte.is_ascii_digit())
            && port.parse::<u16>().is_ok_and(|port| port != 0)
    });
    !host.is_empty() && port_valid && (secure || loopback)
}

/// `[failover]` in the private config file. Managed settings cannot set it.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct FailoverConfig {
    pub url: AuthorityUrl,
    /// Absent on a host that only watches the owner record.
    pub holder: Option<HolderId>,
    /// The holder's credential for the authority.
    pub token_file: PathBuf,
    /// How often a worker daemon reads the owner record. 30 when absent.
    pub watch_interval_seconds: Option<u64>,
}

impl FailoverConfig {
    pub fn watch_interval(&self) -> Duration {
        Duration::from_secs(self.watch_interval_seconds.unwrap_or(30))
    }

    /// Checks `token_file` once `~/` is expanded: a private regular file outside the Nix store.
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.watch_interval_seconds
                .is_none_or(|seconds| (1..=3600).contains(&seconds)),
            "The failover watch_interval_seconds must be between 1 and 3600"
        );
        ensure!(
            self.token_file.is_absolute() && !self.token_file.starts_with("/nix/store"),
            "The failover token_file must be an absolute private file outside the Nix store"
        );
        let metadata = fs::metadata(&self.token_file).with_context(|| {
            format!(
                "Could not read the failover token_file {}",
                self.token_file.display()
            )
        })?;
        ensure!(
            metadata.is_file() && metadata.mode() & 0o077 == 0,
            "The failover token_file {} must be a regular file only its owner can read; run chmod 600 on it",
            self.token_file.display()
        );
        Ok(())
    }
}

/// What the Pi child and the failover helper need to reach the authority,
/// passed as private JSON in `AGENT_FAILOVER`. The helper's session has no
/// epoch. The child's carries the epoch its coordinator start was granted.
/// A worker that only watches the owner record has no holder.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct FailoverSession {
    pub url: AuthorityUrl,
    #[ts(type = "string")]
    pub token_file: PathBuf,
    pub coordinator_id: CoordinatorId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub holder: Option<HolderId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub epoch: Option<OwnerEpoch>,
}

/// One request to `failover/helper.js`. The helper reports facts and Rust decides.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum FailoverRequest {
    /// Raise the epoch for a coordinator start by the current owner, whose
    /// state directory `state` must already hold a log position.
    Claim {
        #[ts(type = "string")]
        state: PathBuf,
    },
    /// Read the owner record. Writes nothing.
    Record,
}

/// The helper's one line of output. An authority it could not reach is an
/// exit with `AUTHORITY_UNREACHABLE_EXIT`, never a refusal.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum FailoverReport {
    Claimed {
        epoch: OwnerEpoch,
        head: LogPosition,
    },
    Refused {
        reason: AuthorityRefusal,
        state: Option<AuthorityState>,
    },
    /// The state directory of a claim holds no log position, so the helper
    /// asked the authority nothing.
    Unstamped,
    /// The owner record, or null before enrollment.
    Record { record: Option<AuthorityRecord> },
}

/// One request to `failover/operator.js`, which does what a `beep-boop
/// failover` command needs from the authority and the blob store. The
/// operator reports facts and Rust decides.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum OperatorRequest {
    /// Read the owner record and, when `state` holds a session database, the
    /// log position it holds. Writes nothing.
    Status {
        #[ts(type = "string | null")]
        state: Option<PathBuf>,
    },
    /// Record that the state directory holds the log through `position`.
    Stamp {
        #[ts(type = "string")]
        state: PathBuf,
        position: LogPosition,
    },
    /// Store the backup archive at `archive` as a checkpoint at the position
    /// its database holds. `part_bytes` is for tests only.
    StoreCheckpoint {
        #[ts(type = "string")]
        archive: PathBuf,
        #[ts(type = "number | null")]
        part_bytes: Option<u64>,
    },
    /// Download the current checkpoint into the new directory `archive`.
    FetchCheckpoint {
        #[ts(type = "string")]
        archive: PathBuf,
    },
    /// Run one command and report the authority's reply.
    Authority { command: AuthorityCommand },
    /// Apply the log entries the state directory lacks, with their files.
    Follow {
        #[ts(type = "string")]
        state: PathBuf,
    },
    /// Check a state directory that must hold the whole log: the database's
    /// integrity, the coordinator id, and every replicated file's hash.
    Verify {
        #[ts(type = "string")]
        state: PathBuf,
    },
    /// List the effects the session database records as started and unfinished.
    Unfinished {
        #[ts(type = "string")]
        state: PathBuf,
    },
}

/// The operator's one line of output. An authority it could not reach is an
/// exit with `AUTHORITY_UNREACHABLE_EXIT`, never a report.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub enum OperatorReport {
    Status {
        /// Null before enrollment.
        record: Option<AuthorityRecord>,
        /// Null when the state directory holds no log position.
        applied: Option<LogPosition>,
    },
    Stamped,
    Stored {
        checkpoint: CheckpointRecord,
        #[ts(type = "number")]
        files: u64,
        #[ts(type = "number")]
        bytes: u64,
    },
    Fetched {
        checkpoint: CheckpointRecord,
        #[ts(type = "number")]
        files: u64,
        #[ts(type = "number")]
        bytes: u64,
    },
    Reply {
        reply: AuthorityReply,
    },
    Followed {
        from: LogPosition,
        applied: LogPosition,
    },
    Verified {
        applied: LogPosition,
        /// How many replicated files matched their records.
        #[ts(type = "number")]
        files: u64,
    },
    Unfinished {
        tools: Vec<UnfinishedToolCall>,
        deliveries: Vec<UnfinishedDelivery>,
        /// One sentence for each stored record the operator could not read.
        unreadable: Vec<String>,
    },
}

/// A tool call whose intent Pi committed and whose result it did not. A
/// restarted owner reruns it only when it is replay-safe, and otherwise
/// reports it to the model as interrupted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct UnfinishedToolCall {
    pub conversation_id: String,
    pub tool: String,
    pub call_id: String,
    pub replay_safe: bool,
}

/// A phone notification claimed for sending whose outcome was not stored. A
/// restarted owner marks it uncertain and does not send it again.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct UnfinishedDelivery {
    pub conversation_id: String,
    pub entry_id: String,
    pub installation_id: String,
    pub apns_id: String,
}

/// The authority did not answer the helper or the operator. The same request is safe to repeat.
#[derive(Debug)]
pub struct AuthorityUnreachable(String);

impl fmt::Display for AuthorityUnreachable {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for AuthorityUnreachable {}

/// A script under `failover/` beside the runtime script, run once per request
/// with the session in `AGENT_FAILOVER`. It prints one report.
pub struct FailoverScript<Request, Report> {
    path: PathBuf,
    name: &'static str,
    exchange: PhantomData<fn(&Request) -> Report>,
}

/// `failover/helper.js`, which a coordinator start and an owner watch use.
pub type FailoverHelper = FailoverScript<FailoverRequest, FailoverReport>;

/// `failover/operator.js`, which the `beep-boop failover` commands use.
pub type FailoverOperator = FailoverScript<OperatorRequest, OperatorReport>;

impl FailoverHelper {
    pub fn locate(script: &Path) -> Result<Self> {
        Self::beside(script, "helper.js", "failover helper")
    }
}

impl FailoverOperator {
    pub fn locate(script: &Path) -> Result<Self> {
        Self::beside(script, "operator.js", "failover operator")
    }
}

impl<Request: Serialize, Report: DeserializeOwned> FailoverScript<Request, Report> {
    fn beside(script: &Path, file: &str, name: &'static str) -> Result<Self> {
        let path = script.with_file_name("failover").join(file);
        ensure!(
            path.is_file(),
            "Pi runtime is not built; build the runtime first"
        );
        Ok(Self {
            path,
            name,
            exchange: PhantomData,
        })
    }

    pub fn run(&self, session: &FailoverSession, request: &Request) -> Result<Report> {
        self.finish(self.command(session, request)?)
    }

    /// Runs the script as a holder of `lock`, so the state directory stays
    /// locked while the script still writes to it, also when this process dies.
    pub(crate) fn run_holding(
        &self,
        lock: &WriterLock,
        session: &FailoverSession,
        request: &Request,
    ) -> Result<Report> {
        let mut command = self.command(session, request)?;
        lock.inherit(&mut command);
        self.finish(command)
    }

    /// Runs the script without blocking a runtime thread, and kills it after `limit`.
    pub async fn run_within(
        &self,
        session: &FailoverSession,
        request: &Request,
        limit: Duration,
    ) -> Result<Report> {
        let mut command = tokio::process::Command::from(self.command(session, request)?);
        command.kill_on_drop(true);
        let output = tokio::time::timeout(limit, command.output())
            .await
            .with_context(|| format!("The {} did not answer in time", self.name))?
            .with_context(|| format!("Could not start the {}", self.name))?;
        self.report(output)
    }

    fn finish(&self, mut command: Command) -> Result<Report> {
        let output = command
            .output()
            .with_context(|| format!("Could not start the {}", self.name))?;
        self.report(output)
    }

    fn command(&self, session: &FailoverSession, request: &Request) -> Result<Command> {
        let mut command = Command::new("node");
        command
            .arg("--no-warnings")
            .arg(&self.path)
            .arg(serde_json::to_string(request)?)
            .env("AGENT_FAILOVER", serde_json::to_string(session)?)
            .stdin(Stdio::null());
        Ok(command)
    }

    fn report(&self, output: Output) -> Result<Report> {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if output.status.code() == Some(i32::from(AUTHORITY_UNREACHABLE_EXIT)) {
            return Err(AuthorityUnreachable(stderr.trim().to_owned()).into());
        }
        ensure!(
            output.status.success(),
            "The {} failed ({}): {}",
            self.name,
            output.status,
            stderr.trim()
        );
        serde_json::from_slice(&output.stdout).with_context(|| {
            format!(
                "The {} returned an invalid report: {}",
                self.name,
                stderr.trim()
            )
        })
    }
}

impl fmt::Display for AuthorityState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Active { epoch, holder, .. } => write!(
                f,
                "holder {} owns it at epoch {}",
                holder.get(),
                epoch.get()
            ),
            Self::Sealed {
                epoch,
                holder,
                candidate,
                ..
            } => write!(
                f,
                "the log is sealed at epoch {} while holder {} replaces holder {}",
                epoch.get(),
                candidate.get(),
                holder.get()
            ),
            Self::Vacant {
                epoch, candidate, ..
            } => write!(
                f,
                "holder {} is taking ownership after epoch {}",
                candidate.get(),
                epoch.get()
            ),
        }
    }
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
    fn sizes_and_pi_sequences_parse_only_exact_values() {
        let file = |size: u64| {
            serde_json::from_value::<FileRecord>(serde_json::json!({
                "path": "feedback/latest",
                "sha256": "ab".repeat(32),
                "size": size,
            }))
        };
        let blob = |size: u64| {
            serde_json::from_value::<BatchBody>(serde_json::json!({
                "kind": "blob",
                "sha256": "ab".repeat(32),
                "size": size,
            }))
        };
        let batch = |pi_seq: u64| {
            serde_json::from_value::<LoggedBatch>(serde_json::json!({
                "pi_seq": pi_seq,
                "body": { "kind": "inline", "json": "[]" },
            }))
        };
        assert!(file(MAX_EXACT + 1).is_err());
        assert!(blob(MAX_EXACT + 1).is_err());
        assert!(batch(MAX_EXACT + 1).is_err());
        assert!(file(MAX_EXACT).is_ok());
        assert!(blob(MAX_EXACT).is_ok());
        assert!(batch(MAX_EXACT).is_ok());
    }

    #[test]
    fn a_log_entry_names_a_pi_sequence_only_with_its_batch() {
        let entry = |fields: serde_json::Value| {
            let mut entry = serde_json::json!({
                "at": 1,
                "epoch": 1,
                "digest": "ab".repeat(32),
                "versions": { "application": "0.1.0", "pi_durable": "1.4.0", "chord": "1.4.0" },
                "files": [],
            });
            if let (Some(entry), Some(fields)) = (entry.as_object_mut(), fields.as_object()) {
                entry.extend(fields.clone());
            }
            serde_json::from_value::<LogEntry>(entry)
        };
        let inline = serde_json::json!({ "kind": "inline", "json": "[]" });
        assert!(entry(serde_json::json!({ "pi_seq": 4, "batch": null })).is_err());
        assert!(entry(serde_json::json!({ "pi_seq": null, "batch": inline.clone() })).is_err());
        assert!(entry(serde_json::json!({ "batch": { "body": inline.clone() } })).is_err());
        assert!(entry(serde_json::json!({ "batch": { "pi_seq": 4, "body": inline } })).is_ok());
        assert!(entry(serde_json::json!({ "batch": null })).is_ok());
    }

    #[test]
    fn a_checkpoint_manifest_names_only_paths_inside_its_archive() {
        let manifest = |path: &str| {
            serde_json::json!({
                "format": CHECKPOINT_FORMAT,
                "through": 3,
                "coordinator_id": Uuid::nil(),
                "files": [{ "path": path, "size": 0, "sha256": "ab".repeat(32), "parts": [] }],
            })
        };
        for accepted in [
            "manifest.json",
            "data/session.sqlite",
            "data/history/assets/ab",
        ] {
            assert!(
                serde_json::from_value::<CheckpointManifest>(manifest(accepted)).is_ok(),
                "{accepted}"
            );
        }
        for refused in [
            "",
            "/etc/passwd",
            "data/../../auth.json",
            "data//a",
            "./a",
            "data\\a",
        ] {
            assert!(
                serde_json::from_value::<CheckpointManifest>(manifest(refused)).is_err(),
                "{refused}"
            );
        }
        let mut unknown = manifest("manifest.json");
        unknown["note"] = "invented".into();
        assert!(serde_json::from_value::<CheckpointManifest>(unknown).is_err());
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
