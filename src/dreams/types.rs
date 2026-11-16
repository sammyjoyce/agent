use std::{fmt, path::PathBuf};

use anyhow::{Result, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ts_rs::TS;

use super::evidence::Finding;

/// Everything a Dreams actor can ask the coordinator to do.
/// Invariant: no variant applies, executes a caller-chosen command, names a
/// target, or carries policy. Adding one is a security change, not a feature.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum DreamsRequest {
    /// Seal (or reread) this run's window, coverage, base, before checks and evidence.
    /// `summaries` is used only by the first, sealing call of a run.
    Review {
        run: String,
        summaries: Vec<DreamsTaskSummary>,
        summaries_omitted: u32,
        page: u32,
    },
    /// One proposal attempt. Edits are full file contents; the patch is derived by git.
    Propose {
        run: String,
        edits: Vec<DreamsFileEdit>,
        rationale: String,
        evidence: Vec<String>,
    },
    /// Seal an explicit abstention.
    Abstain {
        run: String,
        reason: DreamsAbstainReason,
        note: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsTaskSummary {
    pub task_id: String,
    pub title: String,
    pub summary: String,
    #[ts(type = "number")]
    pub updated_at: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsFileEdit {
    pub path: String,
    pub content: String,
}

/// Model-selectable reasons. Exhausted attempts are absent: only the executor seals them.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DreamsAbstainReason {
    Quiet,
    InsufficientCoverage,
    NoSupportedChange,
}

impl DreamsAbstainReason {
    pub const ALL: [Self; 3] = [
        Self::Quiet,
        Self::InsufficientCoverage,
        Self::NoSupportedChange,
    ];

    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Quiet => "quiet",
            Self::InsufficientCoverage => "insufficient_coverage",
            Self::NoSupportedChange => "no_supported_change",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsReply {
    pub run: String,
    pub decided: bool,
    pub text: String,
}

fn is_lower_hex(text: &str, lengths: &[usize]) -> bool {
    lengths.contains(&text.len())
        && text
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// 16 lowercase hex. Derived from the native request id; never a path from input.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct RunId(String);
impl RunId {
    pub fn from_request(request_id: &str) -> Result<Self> {
        ensure!(
            !request_id.is_empty() && request_id.len() <= 256,
            "A Dreams run needs a request id of 1 to 256 bytes"
        );
        let digest = Sha256::new()
            .chain_update(b"dreams-run\0")
            .chain_update(request_id.as_bytes())
            .finalize();
        Ok(Self(hex::encode(&digest[..8])))
    }
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(
            is_lower_hex(text, &[16]),
            "A Dreams run id is 16 lowercase hex characters"
        );
        Ok(Self(text.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for RunId {
    type Error = anyhow::Error;
    fn try_from(text: String) -> Result<Self> {
        Self::parse(&text)
    }
}
impl From<RunId> for String {
    fn from(run: RunId) -> Self {
        run.0
    }
}
impl fmt::Display for RunId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// `r:<16 hex>` for a receipt (a hash of its canonical bytes) or
/// `t:<task id>@<updated_at>` for one version of a task summary.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct EvidenceId(String);
impl EvidenceId {
    pub(crate) fn receipt(canonical: &[u8]) -> Self {
        Self(format!(
            "r:{}",
            hex::encode(&Sha256::digest(canonical)[..8])
        ))
    }
    pub(crate) fn task(task_id: &str, updated_at: u64) -> Self {
        Self(format!("t:{task_id}@{updated_at}"))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl fmt::Display for EvidenceId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Half-open `[start_ms, end_ms)`, milliseconds since the epoch.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Interval {
    pub start_ms: u64,
    pub end_ms: u64,
}
impl Interval {
    pub(crate) fn new(start_ms: u64, end_ms: u64) -> Option<Self> {
        (start_ms < end_ms).then_some(Self { start_ms, end_ms })
    }
    pub(crate) fn intersect(self, other: Self) -> Option<Self> {
        Self::new(
            self.start_ms.max(other.start_ms),
            self.end_ms.min(other.end_ms),
        )
    }
}

/// What a run actually saw. Completeness is derived from the gaps and never
/// stored, so a quiet night and a blind night cannot be confused in the record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Coverage {
    pub window: Interval,
    pub receipts: ReceiptCoverage,
    pub summaries: SummarySnapshot,
}
impl Coverage {
    pub fn gaps(&self) -> impl Iterator<Item = &Gap> {
        self.receipts.gaps.iter().chain(&self.summaries.gaps)
    }
    pub fn complete(&self) -> bool {
        self.gaps().next().is_none()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReceiptCoverage {
    /// The window minus every gap whose interval is known.
    pub covered: Vec<Interval>,
    pub gaps: Vec<Gap>,
    pub items: u32,
}

/// Task summaries are the text retained when the review was sealed. They are
/// not a history of the window, and the record says so.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SummarySnapshot {
    pub captured_at_ms: u64,
    pub gaps: Vec<Gap>,
    pub items: u32,
}

/// `interval` is None when the loss is real but its time is unknown.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Gap {
    pub interval: Option<Interval>,
    #[serde(flatten)]
    pub cause: GapCause,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "cause", rename_all = "snake_case")]
pub enum GapCause {
    /// retention.json is missing or unreadable, so nothing about loss is known.
    RetentionUnknown,
    /// History before the oldest retained receipt is unknown and the window starts before it.
    HistoryUnknown,
    /// Age expiry removed whole segments inside the window.
    Expired,
    /// Capacity eviction removed segments overlapping the window.
    CapacityEvicted { segments: u64, bytes: u64 },
    /// Capacity eviction removed segments with unknown timestamps.
    CapacityEvictedUnknownTime { segments: u64, bytes: u64 },
    /// The nonblocking channel dropped receipts between two retained ones.
    ChannelOverflow { dropped: u64 },
    /// Lines that did not parse as receipts. Their bytes never reach the model.
    Unparseable { lines: u32 },
    /// The read budget stopped before the window end.
    ReadBudget,
    /// Segments rotated during both read attempts.
    ConcurrentRotation,
    /// No receipt, not even a heartbeat, for longer than two heartbeat intervals.
    Unwitnessed,
    /// Summaries the runtime or the executor left out.
    SummariesOmitted { count: u32 },
    /// Summaries at the retention limit, which may have lost their beginning.
    SummariesTruncated { count: u32 },
}

impl GapCause {
    pub fn wire_name(&self) -> &'static str {
        match self {
            Self::RetentionUnknown => "retention_unknown",
            Self::HistoryUnknown => "history_unknown",
            Self::Expired => "expired",
            Self::CapacityEvicted { .. } => "capacity_evicted",
            Self::CapacityEvictedUnknownTime { .. } => "capacity_evicted_unknown_time",
            Self::ChannelOverflow { .. } => "channel_overflow",
            Self::Unparseable { .. } => "unparseable",
            Self::ReadBudget => "read_budget",
            Self::ConcurrentRotation => "concurrent_rotation",
            Self::Unwitnessed => "unwitnessed",
            Self::SummariesOmitted { .. } => "summaries_omitted",
            Self::SummariesTruncated { .. } => "summaries_truncated",
        }
    }
}

impl fmt::Display for Gap {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let between = match self.interval {
            Some(interval) => format!(
                " between {} and {}",
                format_utc(interval.start_ms),
                format_utc(interval.end_ms)
            ),
            None => String::new(),
        };
        write!(formatter, "{}: ", self.cause.wire_name())?;
        match &self.cause {
            GapCause::RetentionUnknown => write!(
                formatter,
                "retention metadata is missing or unreadable, so receipt loss is unknown"
            ),
            GapCause::HistoryUnknown => write!(
                formatter,
                "history before the oldest retained receipt is unknown{between}"
            ),
            GapCause::Expired => write!(formatter, "receipts were removed by age{between}"),
            GapCause::CapacityEvicted { segments, bytes } => write!(
                formatter,
                "{segments} segments ({bytes} bytes) were evicted for capacity{between}"
            ),
            GapCause::CapacityEvictedUnknownTime { segments, bytes } => write!(
                formatter,
                "{segments} segments ({bytes} bytes) with unknown timestamps were evicted for capacity"
            ),
            GapCause::ChannelOverflow { dropped } => {
                write!(formatter, "{dropped} receipts were dropped{between}")
            }
            GapCause::Unparseable { lines } => write!(formatter, "{lines} lines are not receipts"),
            GapCause::ReadBudget => write!(
                formatter,
                "the read budget stopped before the window end{between}"
            ),
            GapCause::ConcurrentRotation => {
                write!(formatter, "segments rotated during both read attempts")
            }
            GapCause::Unwitnessed => {
                write!(formatter, "no receipt or heartbeat was written{between}")
            }
            GapCause::SummariesOmitted { count } => {
                write!(formatter, "{count} task summaries were left out")
            }
            GapCause::SummariesTruncated { count } => write!(
                formatter,
                "{count} task summaries reached the retention limit and may be cut"
            ),
        }
    }
}

/// Full commit id of the target.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Revision(String);
impl Revision {
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(
            is_lower_hex(text, &[40, 64]),
            "A Dreams base is a full commit id"
        );
        Ok(Self(text.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}
impl TryFrom<String> for Revision {
    type Error = anyhow::Error;
    fn try_from(text: String) -> Result<Self> {
        Self::parse(&text)
    }
}
impl From<Revision> for String {
    fn from(revision: Revision) -> Self {
        revision.0
    }
}
impl fmt::Display for Revision {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// sha256 of exact bytes, written `sha256:<64 hex>`. A patch and a sealed
/// outcome are each identified this way.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct ContentDigest(String);
impl ContentDigest {
    pub fn of(bytes: &[u8]) -> Self {
        Self(format!("sha256:{}", hex::encode(Sha256::digest(bytes))))
    }
    pub fn parse(text: &str) -> Result<Self> {
        ensure!(
            text.strip_prefix("sha256:")
                .is_some_and(|digest| is_lower_hex(digest, &[64])),
            "A Dreams digest is sha256: followed by 64 lowercase hex characters"
        );
        Ok(Self(text.to_owned()))
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn hex(&self) -> &str {
        &self.0["sha256:".len()..]
    }
}
impl TryFrom<String> for ContentDigest {
    type Error = anyhow::Error;
    fn try_from(text: String) -> Result<Self> {
        Self::parse(&text)
    }
}
impl From<ContentDigest> for String {
    fn from(digest: ContentDigest) -> Self {
        digest.0
    }
}
impl fmt::Display for ContentDigest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Identifies the policy a review and a proposal were made under: the
/// repository, the editable globs, the window and the checks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct PolicyDigest(String);
impl PolicyDigest {
    pub(crate) fn of(policy: &[u8]) -> Self {
        Self(hex::encode(Sha256::digest(policy)))
    }
    pub fn short(&self) -> &str {
        self.0.get(..12).unwrap_or(&self.0)
    }
}
impl fmt::Display for PolicyDigest {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

/// Model-authored text. Bounded when stored and always shown as quoted data.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct UntrustedText(String);
impl UntrustedText {
    pub fn bounded(text: &str, characters: usize) -> Self {
        Self(text.chars().take(characters).collect())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CheckResult {
    pub name: String,
    pub argv: Vec<String>,
    /// None when the check timed out or could not start.
    pub exit_code: Option<i32>,
    pub timed_out: bool,
    pub duration_ms: u64,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
}
impl CheckResult {
    pub fn passed(&self) -> bool {
        self.exit_code == Some(0) && !self.timed_out
    }
    pub fn verdict(&self) -> String {
        match self.exit_code {
            Some(code) => format!("exit {code}"),
            None if self.timed_out => "timed out".into(),
            None => "did not start".into(),
        }
    }
}

/// Sealed once per run. Window, base and evidence never change after this exists.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Review {
    pub run: RunId,
    pub request_id: String,
    pub coverage: Coverage,
    pub repository: PathBuf,
    pub base: Revision,
    pub policy_digest: PolicyDigest,
    pub before: Vec<CheckResult>,
    pub findings: Vec<Finding>,
}

/// The single decision of a run. One file, one variant.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum Outcome {
    Proposed(Box<Proposal>),
    Abstained(Abstention),
}
impl Outcome {
    pub fn label(&self) -> String {
        match self {
            Self::Proposed(_) => "proposed".into(),
            Self::Abstained(Abstention::Chosen { reason, .. }) => {
                format!("abstained: {}", reason.wire_name())
            }
            Self::Abstained(Abstention::AttemptsExhausted { .. }) => {
                "abstained: attempts_exhausted".into()
            }
        }
    }
    pub(crate) fn sealed_line(&self, run: &RunId) -> String {
        let detail = match self {
            Self::Proposed(proposal) => format!(
                "proposed {} ({}, {})",
                proposal.patch_sha256,
                count(proposal.files.len(), "file"),
                proposal.files.join(", ")
            ),
            Self::Abstained(_) => self.label(),
        };
        format!("Dreams run {run} sealed: {detail}.\nReview with: beep-boop dreams show {run}")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Abstention {
    /// `Quiet` is accepted only when the review's coverage is complete.
    Chosen {
        reason: DreamsAbstainReason,
        note: UntrustedText,
    },
    AttemptsExhausted {
        attempts: u8,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProposedFile {
    pub path: String,
    pub base_blob: Option<String>,
    pub proposed_blob: String,
}

/// A sealed proposal. Every after check passed, the evidence is contained in
/// the review, and the files were editable under the review's policy.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proposal {
    pub run: RunId,
    pub attempt: u8,
    pub repository: PathBuf,
    pub base: Revision,
    pub patch_sha256: ContentDigest,
    pub files: Vec<String>,
    pub changes: Vec<ProposedFile>,
    pub evidence: Vec<EvidenceId>,
    pub rationale: UntrustedText,
    pub before: Vec<CheckResult>,
    pub after: Vec<CheckResult>,
    pub policy_digest: PolicyDigest,
}

pub fn format_utc(timestamp_ms: u64) -> String {
    i64::try_from(timestamp_ms)
        .ok()
        .and_then(chrono::DateTime::<chrono::Utc>::from_timestamp_millis)
        .map_or_else(
            || format!("{timestamp_ms} ms"),
            |time| time.format("%Y-%m-%d %H:%M:%S UTC").to_string(),
        )
}

pub fn count(number: usize, noun: &str) -> String {
    format!("{number} {noun}{}", if number == 1 { "" } else { "s" })
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use crate::dreams::{DreamsAbstainReason, GapCause};

    #[test]
    fn every_label_is_the_name_the_wire_uses() {
        for cause in [
            GapCause::RetentionUnknown,
            GapCause::HistoryUnknown,
            GapCause::Expired,
            GapCause::CapacityEvicted {
                segments: 1,
                bytes: 1,
            },
            GapCause::CapacityEvictedUnknownTime {
                segments: 1,
                bytes: 1,
            },
            GapCause::ChannelOverflow { dropped: 1 },
            GapCause::Unparseable { lines: 1 },
            GapCause::ReadBudget,
            GapCause::ConcurrentRotation,
            GapCause::Unwitnessed,
            GapCause::SummariesOmitted { count: 1 },
            GapCause::SummariesTruncated { count: 1 },
        ] {
            assert_eq!(
                serde_json::to_value(&cause).unwrap()["cause"],
                cause.wire_name()
            );
        }
        for reason in DreamsAbstainReason::ALL {
            assert_eq!(json!(reason), reason.wire_name());
        }
    }
}
