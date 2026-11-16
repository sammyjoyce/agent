//! Dreams: nightly, proposal-only review of private operational evidence.
//! This library can review, propose and abstain. It cannot apply. Application
//! lives in the beep-boop binary (src/dreams_cli.rs), which no library code links.
mod evidence;
mod policy;
mod store;
pub mod workspace;

use std::{
    fmt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::watch;
use ts_rs::TS;

pub use evidence::{EvidenceItem, EvidenceKind, Finding};
pub use policy::{
    CheckSpec, DreamsCheckFile, DreamsPolicy, DreamsPolicyFile, EditablePath, ProtectedPaths,
};
pub use store::{DreamsStore, RunView};

use crate::{protocol::HostResult, runtime::diagnostics};

pub const DREAMS_JOB_ID: &str = "dreams";
pub const MAX_WINDOW_HOURS: u8 = 48;
pub const MAX_SUMMARIES: usize = 200;
pub const MAX_SUMMARY_BYTES: usize = 1024 * 1024;
pub const MAX_EDITS: usize = 4;
pub const MAX_EDIT_BYTES: usize = 64 * 1024;
pub const MAX_ATTEMPTS: u8 = 3;
pub const HOST_TIMEOUT_MS: u64 = 21 * 60 * 1000;
pub const NOT_CONFIGURED: &str = "Dreams is not configured";

const MAX_EVIDENCE_CITATIONS: usize = 20;
const MAX_SHOWN_FILES: usize = 32;
const MAX_RECEIPT_BYTES: u64 = 160 * 1024 * 1024;
const MAX_RECEIPTS: usize = 400_000;

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

/// Rendered by Rust so the model and `dreams show` read the same words.
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
    pub(crate) fn receipt(digest: &[u8]) -> Self {
        Self(format!("r:{}", hex::encode(&digest[..8.min(digest.len())])))
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
        match &self.cause {
            GapCause::RetentionUnknown => write!(
                formatter,
                "retention_unknown: retention metadata is missing or unreadable, so receipt loss is unknown"
            ),
            GapCause::HistoryUnknown => write!(
                formatter,
                "history_unknown: history before the oldest retained receipt is unknown{between}"
            ),
            GapCause::Expired => {
                write!(formatter, "expired: receipts were removed by age{between}")
            }
            GapCause::CapacityEvicted { segments, bytes } => write!(
                formatter,
                "capacity_evicted: {segments} segments ({bytes} bytes) were evicted for capacity{between}"
            ),
            GapCause::CapacityEvictedUnknownTime { segments, bytes } => write!(
                formatter,
                "capacity_evicted_unknown_time: {segments} segments ({bytes} bytes) with unknown timestamps were evicted for capacity"
            ),
            GapCause::ChannelOverflow { dropped } => write!(
                formatter,
                "channel_overflow: {dropped} receipts were dropped{between}"
            ),
            GapCause::Unparseable { lines } => {
                write!(formatter, "unparseable: {lines} lines are not receipts")
            }
            GapCause::ReadBudget => write!(
                formatter,
                "read_budget: the read budget stopped before the window end{between}"
            ),
            GapCause::ConcurrentRotation => write!(
                formatter,
                "concurrent_rotation: segments rotated during both read attempts"
            ),
            GapCause::Unwitnessed => write!(
                formatter,
                "unwitnessed: no receipt or heartbeat was written{between}"
            ),
            GapCause::SummariesOmitted { count } => write!(
                formatter,
                "summaries_omitted: {count} task summaries were left out"
            ),
            GapCause::SummariesTruncated { count } => write!(
                formatter,
                "summaries_truncated: {count} task summaries reached the retention limit and may be cut"
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
    pub policy_digest: String,
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
            Self::Abstained(Abstention::Chosen { reason, .. }) => format!(
                "abstained: {}",
                match reason {
                    DreamsAbstainReason::Quiet => "quiet",
                    DreamsAbstainReason::InsufficientCoverage => "insufficient_coverage",
                    DreamsAbstainReason::NoSupportedChange => "no_supported_change",
                }
            ),
            Self::Abstained(Abstention::AttemptsExhausted { .. }) => {
                "abstained: attempts_exhausted".into()
            }
        }
    }
    fn sealed_line(&self, run: &RunId) -> String {
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
    pub evidence: Vec<EvidenceId>,
    pub rationale: UntrustedText,
    pub before: Vec<CheckResult>,
    pub after: Vec<CheckResult>,
    pub policy_digest: String,
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

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| {
            u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX)
        })
}

struct Rejection {
    reason: String,
    output: Vec<String>,
}
impl Rejection {
    fn because(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            output: Vec::new(),
        }
    }
}

struct Draft<'a> {
    edits: &'a [DreamsFileEdit],
    rationale: &'a str,
    evidence: &'a [String],
}

pub struct Dreams {
    state: PathBuf,
    store: DreamsStore,
    policy: DreamsPolicy,
}

impl Dreams {
    /// Refuses a state directory inside the policy repository, where a
    /// proposal could otherwise edit its own evidence.
    pub fn open(state: &Path, policy: DreamsPolicy) -> Result<Self> {
        policy.refuse_state_inside(state)?;
        let store = DreamsStore::open(state)?;
        Ok(Self {
            state: state.to_owned(),
            store,
            policy,
        })
    }

    /// The only entry point. What the model can fix comes back as reply text;
    /// an infrastructure failure comes back as a failed host call.
    pub async fn execute(
        &self,
        request: DreamsRequest,
        cancelled: watch::Receiver<bool>,
    ) -> HostResult {
        let result = match request {
            DreamsRequest::Review {
                run,
                summaries,
                summaries_omitted,
                page,
            } => {
                self.review(&run, &summaries, summaries_omitted, page, &cancelled)
                    .await
            }
            DreamsRequest::Propose {
                run,
                edits,
                rationale,
                evidence,
            } => {
                self.propose(&run, &edits, &rationale, &evidence, &cancelled)
                    .await
            }
            DreamsRequest::Abstain { run, reason, note } => self.abstain(&run, reason, &note),
        };
        match result {
            Ok(reply) => HostResult::Dreams { reply },
            Err(error) => HostResult::Failed {
                delivery: None,
                message: format!("Dreams could not finish this request: {error:#}"),
            },
        }
    }

    fn reply(run: &RunId, decided: bool, text: String) -> DreamsReply {
        DreamsReply {
            run: run.to_string(),
            decided,
            text,
        }
    }

    fn decided(run: &RunId, outcome: &Outcome) -> DreamsReply {
        Self::reply(run, true, outcome.sealed_line(run))
    }

    fn reviewed(&self, run: &RunId) -> Result<std::result::Result<RunView, DreamsReply>> {
        Ok(self.store.read(run)?.ok_or_else(|| {
            Self::reply(
                run,
                false,
                "Call dreams_review before deciding: this run has no sealed review yet.".into(),
            )
        }))
    }

    async fn review(
        &self,
        request_id: &str,
        summaries: &[DreamsTaskSummary],
        omitted: u32,
        page: u32,
        cancelled: &watch::Receiver<bool>,
    ) -> Result<DreamsReply> {
        let run = RunId::from_request(request_id)?;
        let view = match self.store.read(&run)? {
            Some(view) => view,
            None => {
                self.seal_review(&run, request_id, summaries, omitted, cancelled)
                    .await?;
                self.store
                    .read(&run)?
                    .context("The sealed Dreams review is missing")?
            }
        };
        Ok(Self::reply(
            &run,
            view.outcome.is_some(),
            evidence::render_page(
                &view.review,
                &self.store.evidence(&run)?,
                &self.store.files(&run)?,
                page,
            ),
        ))
    }

    async fn seal_review(
        &self,
        run: &RunId,
        request_id: &str,
        summaries: &[DreamsTaskSummary],
        omitted: u32,
        cancelled: &watch::Receiver<bool>,
    ) -> Result<()> {
        let end_ms = now_ms();
        let span = u64::try_from(self.policy.window().as_millis()).unwrap_or(u64::MAX);
        let window = Interval::new(end_ms.saturating_sub(span), end_ms)
            .context("The Dreams window is empty")?;
        let state = self.state.clone();
        let receipts = tokio::task::spawn_blocking(move || {
            diagnostics::read_window(
                &state,
                (window.start_ms, window.end_ms),
                MAX_RECEIPTS,
                MAX_RECEIPT_BYTES,
            )
        })
        .await?
        .context("Could not read runtime receipts")?;
        let (snapshot, mut items) = evidence::summaries(summaries, omitted, end_ms);
        let (findings, receipt_items) = evidence::findings(&receipts.records);
        items.extend(receipt_items);
        let coverage = evidence::coverage(window, &receipts, snapshot);

        let staged = self.store.stage_review(run)?;
        let built = async {
            let base = workspace::resolve_base(self.policy.repository()).await?;
            let checkout = staged.join("base");
            workspace::checkout(self.policy.repository(), &base, &checkout).await?;
            store::write_json(
                &staged.join("files.json"),
                &self.editable_files(&checkout).await?,
            )?;
            let before = workspace::run_checks(&checkout, self.policy.checks(), cancelled).await?;
            let evidence_lines = items
                .iter()
                .map(serde_json::to_string)
                .collect::<Result<Vec<_>, _>>()?
                .join("\n");
            store::write_private(
                &staged.join("evidence.jsonl"),
                if evidence_lines.is_empty() {
                    String::new()
                } else {
                    evidence_lines + "\n"
                }
                .as_bytes(),
            )?;
            store::write_json(
                &staged.join("review.json"),
                &Review {
                    run: run.clone(),
                    request_id: request_id.to_owned(),
                    coverage,
                    repository: self.policy.repository().to_owned(),
                    base,
                    policy_digest: self.policy.digest().to_owned(),
                    before,
                    findings,
                },
            )?;
            self.store.seal_review(&staged, run)
        }
        .await;
        if built.is_err() {
            let _ = std::fs::remove_dir_all(&staged);
        }
        built.map(|_| ())
    }

    async fn editable_files(&self, checkout: &Path) -> Result<Vec<(String, String)>> {
        let mut files = Vec::new();
        for path in workspace::tracked_files(checkout).await? {
            if self.policy.editable(&path).is_err() {
                continue;
            }
            if files.len() == MAX_SHOWN_FILES {
                files.push((
                    "(more)".into(),
                    "[more editable files exist than one review shows]".into(),
                ));
                break;
            }
            let file = checkout.join(&path);
            let content = match std::fs::symlink_metadata(&file) {
                Ok(metadata) if !metadata.is_file() => "[not a regular file]".into(),
                Ok(metadata) if metadata.len() > MAX_EDIT_BYTES as u64 => {
                    format!("[larger than {MAX_EDIT_BYTES} bytes; not shown and not editable]")
                }
                Ok(_) => std::fs::read_to_string(&file)
                    .unwrap_or_else(|_| "[not UTF-8 text; not editable]".into()),
                Err(error) => return Err(error).context("Could not read an editable file"),
            };
            files.push((path, content));
        }
        Ok(files)
    }

    fn abstain(
        &self,
        request_id: &str,
        reason: DreamsAbstainReason,
        note: &str,
    ) -> Result<DreamsReply> {
        let run = RunId::from_request(request_id)?;
        let view = match self.reviewed(&run)? {
            Ok(view) => view,
            Err(reply) => return Ok(reply),
        };
        if let Some(outcome) = &view.outcome {
            return Ok(Self::decided(&run, outcome));
        }
        let gaps = view.review.coverage.gaps().count();
        if reason == DreamsAbstainReason::Quiet && gaps > 0 {
            return Ok(Self::reply(
                &run,
                false,
                format!(
                    "Dreams cannot record a quiet night: coverage is incomplete ({}). Choose insufficient_coverage or no_supported_change.",
                    count(gaps, "gap")
                ),
            ));
        }
        let outcome = self.store.seal_outcome(
            &run,
            &Outcome::Abstained(Abstention::Chosen {
                reason,
                note: UntrustedText::bounded(note, 2_000),
            }),
        )?;
        Ok(Self::decided(&run, &outcome))
    }

    async fn propose(
        &self,
        request_id: &str,
        edits: &[DreamsFileEdit],
        rationale: &str,
        evidence: &[String],
        cancelled: &watch::Receiver<bool>,
    ) -> Result<DreamsReply> {
        let run = RunId::from_request(request_id)?;
        let view = match self.reviewed(&run)? {
            Ok(view) => view,
            Err(reply) => return Ok(reply),
        };
        if let Some(outcome) = &view.outcome {
            return Ok(Self::decided(&run, outcome));
        }
        let exhausted = Outcome::Abstained(Abstention::AttemptsExhausted {
            attempts: MAX_ATTEMPTS,
        });
        let Some((attempt, directory)) = self.store.allocate_attempt(&run)? else {
            return Ok(Self::decided(
                &run,
                &self.store.seal_outcome(&run, &exhausted)?,
            ));
        };
        let draft = Draft {
            edits,
            rationale,
            evidence,
        };
        let rejection = match self
            .attempt(&view, attempt, &directory, &draft, cancelled)
            .await?
        {
            Ok(proposal) => {
                let outcome = self
                    .store
                    .seal_outcome(&run, &Outcome::Proposed(Box::new(proposal)))?;
                return Ok(Self::decided(&run, &outcome));
            }
            Err(rejection) => rejection,
        };
        store::write_json(
            &directory.join("verdict.json"),
            &serde_json::json!({ "accepted": false, "reason": rejection.reason }),
        )?;
        let mut lines = vec![format!(
            "Dreams proposal attempt {attempt} of {MAX_ATTEMPTS} rejected: {}. {} of {MAX_ATTEMPTS} attempts remain.",
            rejection.reason,
            MAX_ATTEMPTS - attempt
        )];
        lines.extend(rejection.output);
        if attempt < MAX_ATTEMPTS {
            return Ok(Self::reply(&run, false, lines.join("\n")));
        }
        let outcome = self.store.seal_outcome(&run, &exhausted)?;
        lines.push(outcome.sealed_line(&run));
        Ok(Self::reply(&run, true, lines.join("\n")))
    }

    async fn attempt(
        &self,
        view: &RunView,
        attempt: u8,
        directory: &Path,
        draft: &Draft<'_>,
        cancelled: &watch::Receiver<bool>,
    ) -> Result<std::result::Result<Proposal, Rejection>> {
        let review = &view.review;
        if review.policy_digest != self.policy.digest() {
            return Ok(Err(Rejection::because(
                "the Dreams policy changed after this review was sealed",
            )));
        }
        if draft.edits.is_empty() || draft.edits.len() > MAX_EDITS {
            return Ok(Err(Rejection::because(format!(
                "a proposal changes 1 to {MAX_EDITS} files"
            ))));
        }
        let mut edits: Vec<(EditablePath, &str)> = Vec::new();
        for edit in draft.edits {
            let path = match self.policy.editable(&edit.path) {
                Ok(path) => path,
                Err(reason) => return Ok(Err(Rejection::because(reason))),
            };
            if edit.content.len() > MAX_EDIT_BYTES {
                return Ok(Err(Rejection::because(format!(
                    "{path} is larger than {MAX_EDIT_BYTES} bytes"
                ))));
            }
            if edits.iter().any(|(edited, _)| edited == &path) {
                return Ok(Err(Rejection::because(format!("{path} is edited twice"))));
            }
            edits.push((path, &edit.content));
        }
        if draft.evidence.is_empty() || draft.evidence.len() > MAX_EVIDENCE_CITATIONS {
            return Ok(Err(Rejection::because(format!(
                "a proposal cites 1 to {MAX_EVIDENCE_CITATIONS} evidence ids"
            ))));
        }
        let reviewed = self.store.evidence(&view.id)?;
        let mut evidence = Vec::new();
        for cited in draft.evidence {
            match reviewed.iter().find(|item| item.id.as_str() == cited) {
                Some(item) => evidence.push(item.id.clone()),
                None => {
                    let shown: String = cited.chars().take(96).collect();
                    return Ok(Err(Rejection::because(format!(
                        "evidence id {shown:?} is not in this review"
                    ))));
                }
            }
        }

        let candidate = directory.join("candidate");
        let patch_path = directory.join("patch.diff");
        workspace::checkout(&review.repository, &review.base, &candidate).await?;
        let patch = match workspace::write_candidate(&candidate, &review.base, &edits, &patch_path)
            .await?
        {
            Ok(patch) => patch,
            Err(reason) => return Ok(Err(Rejection::because(reason))),
        };
        let after = workspace::run_checks(&candidate, self.policy.checks(), cancelled).await?;
        store::write_json(&directory.join("after.json"), &after)?;
        ensure!(
            ContentDigest::of(&std::fs::read(&patch_path)?) == patch.digest,
            "The Dreams patch changed while its checks ran"
        );
        if let Some(failed) = after.iter().find(|check| !check.passed()) {
            let mut output = Vec::new();
            evidence::check_lines(&mut output, "After", failed);
            return Ok(Err(Rejection {
                reason: format!("after check {} did not pass", failed.name),
                output,
            }));
        }
        store::write_json(
            &directory.join("verdict.json"),
            &serde_json::json!({ "accepted": true }),
        )?;
        Ok(Ok(Proposal {
            run: view.id.clone(),
            attempt,
            repository: review.repository.clone(),
            base: review.base.clone(),
            patch_sha256: patch.digest,
            files: patch.files,
            evidence,
            rationale: UntrustedText::bounded(draft.rationale, 4_000),
            before: review.before.clone(),
            after,
            policy_digest: review.policy_digest.clone(),
        }))
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
        path::{Path, PathBuf},
        process::Command,
    };

    use tokio::sync::watch;

    use crate::{
        dreams::{
            ContentDigest, Dreams, DreamsAbstainReason, DreamsCheckFile, DreamsFileEdit,
            DreamsPolicy, DreamsPolicyFile, DreamsReply, DreamsRequest, DreamsTaskSummary, Outcome,
            ProtectedPaths, RunId,
        },
        protocol::HostResult,
    };

    const BROKEN: &str = "Run `make test-all` before finishing.\n";
    const FIXED: &str = "Run `make test` before finishing.\n";
    const EVIDENCE: &str = "t:task-1@7";
    const CHECK: &str = "for target in $(grep -o 'make [a-z-]*' AGENTS.md | cut -d' ' -f2); do grep -q \"^$target:\" Makefile || { echo \"missing make target: $target\"; exit 1; }; done\n";

    fn git(repository: &Path, arguments: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(arguments)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    struct Night {
        root: tempfile::TempDir,
        repository: PathBuf,
        dreams: Dreams,
    }

    impl Night {
        fn new() -> Self {
            let root = tempfile::tempdir().unwrap();
            let base = root.path().canonicalize().unwrap();
            let (repository, state, outside) = (
                base.join("guidance"),
                base.join("state"),
                base.join("outside"),
            );
            for directory in [&repository, &state, &outside] {
                fs::create_dir(directory).unwrap();
            }
            fs::write(base.join("check.sh"), CHECK).unwrap();
            fs::write(repository.join("AGENTS.md"), BROKEN).unwrap();
            fs::write(repository.join("Makefile"), "test:\n\t@echo ok\n").unwrap();
            fs::create_dir(repository.join("playbooks")).unwrap();
            symlink("../Makefile", repository.join("playbooks/link.md")).unwrap();
            fs::write(repository.join("playbooks/tool.md"), "#!/bin/sh\n").unwrap();
            fs::set_permissions(
                repository.join("playbooks/tool.md"),
                fs::Permissions::from_mode(0o755),
            )
            .unwrap();
            symlink(&outside, repository.join("linked")).unwrap();
            git(&repository, &["init", "--quiet", "--initial-branch=main"]);
            git(&repository, &["config", "user.name", "Example"]);
            git(&repository, &["config", "user.email", "example@invalid"]);
            git(&repository, &["add", "."]);
            git(
                &repository,
                &["commit", "--quiet", "-m", "Add example guidance"],
            );
            let policy = DreamsPolicy::parse(
                &DreamsPolicyFile {
                    repository: repository.clone(),
                    editable: vec![
                        "AGENTS.md".into(),
                        "playbooks/*.md".into(),
                        "linked/*.md".into(),
                    ],
                    window_hours: Some(1),
                    checks: vec![DreamsCheckFile {
                        name: "commands-exist".into(),
                        argv: vec![
                            "/bin/sh".into(),
                            base.join("check.sh").to_string_lossy().into_owned(),
                        ],
                        timeout_seconds: 30,
                    }],
                },
                &ProtectedPaths {
                    config: None,
                    job_directories: &[],
                },
            )
            .unwrap();
            Self {
                dreams: Dreams::open(&state, policy).unwrap(),
                repository,
                root,
            }
        }

        async fn send(&self, request: DreamsRequest) -> DreamsReply {
            let (_owner, cancelled) = watch::channel(false);
            match self.dreams.execute(request, cancelled).await {
                HostResult::Dreams { reply } => reply,
                other => panic!("Dreams failed: {other:?}"),
            }
        }

        async fn review(&self, run: &str) -> DreamsReply {
            self.send(DreamsRequest::Review {
                run: run.into(),
                summaries: vec![DreamsTaskSummary {
                    task_id: "task-1".into(),
                    title: "Example build".into(),
                    summary: "make test-all failed: no such target.".into(),
                    updated_at: 7,
                }],
                summaries_omitted: 0,
                page: 1,
            })
            .await
        }

        async fn propose(
            &self,
            run: &str,
            path: &str,
            content: &str,
            evidence: &str,
        ) -> DreamsReply {
            self.send(DreamsRequest::Propose {
                run: run.into(),
                edits: vec![DreamsFileEdit {
                    path: path.into(),
                    content: content.into(),
                }],
                rationale: "The guidance names a missing target.".into(),
                evidence: vec![evidence.into()],
            })
            .await
        }

        fn target(&self) -> (String, String) {
            (
                git(&self.repository, &["rev-parse", "HEAD"]),
                git(&self.repository, &["status", "--porcelain"]),
            )
        }
    }

    #[tokio::test]
    async fn a_proposal_is_refused_for_each_way_it_could_exceed_its_policy_or_its_review() {
        let night = Night::new();
        let before = night.target();
        assert!(
            night
                .propose("unreviewed", "AGENTS.md", FIXED, EVIDENCE)
                .await
                .text
                .contains("Call dreams_review before deciding")
        );
        for (run, path, content, evidence, reason) in [
            (
                "symlink",
                "playbooks/link.md",
                "x",
                EVIDENCE,
                "is a symlink, a submodule or an executable",
            ),
            (
                "executable",
                "playbooks/tool.md",
                "x",
                EVIDENCE,
                "is a symlink, a submodule or an executable",
            ),
            (
                "escape",
                "linked/escape.md",
                "x",
                EVIDENCE,
                "has a parent that is not a directory",
            ),
            (
                "uneditable",
                "Makefile",
                "test-all:\n",
                EVIDENCE,
                "path Makefile is not editable",
            ),
            (
                "uncited",
                "AGENTS.md",
                FIXED,
                "t:task-2@7",
                "is not in this review",
            ),
            (
                "unchanged",
                "AGENTS.md",
                BROKEN,
                EVIDENCE,
                "change nothing at the base",
            ),
        ] {
            night.review(run).await;
            let reply = night.propose(run, path, content, evidence).await;
            assert!(
                !reply.decided && reply.text.contains("rejected") && reply.text.contains(reason),
                "{run}: {}",
                reply.text
            );
        }
        assert!(!night.root.path().join("outside/escape.md").exists());
        assert_eq!(night.target(), before);
    }

    #[tokio::test]
    async fn the_third_failed_attempt_seals_the_run_and_every_later_decision_returns_it() {
        let night = Night::new();
        night.review("night").await;
        let still_broken = "Run `make test-all` and then `make test`.\n";
        for attempt in 1..=2 {
            let reply = night
                .propose("night", "AGENTS.md", still_broken, EVIDENCE)
                .await;
            assert!(!reply.decided);
            assert!(
                reply.text.contains(&format!(
                    "attempt {attempt} of 3 rejected: after check commands-exist did not pass"
                )) && reply.text.contains("> missing make target: test-all"),
                "{}",
                reply.text
            );
        }
        let third = night
            .propose("night", "AGENTS.md", still_broken, EVIDENCE)
            .await;
        assert!(third.decided, "{}", third.text);
        assert!(third.text.contains("sealed: abstained: attempts_exhausted"));
        let late = night.propose("night", "AGENTS.md", FIXED, EVIDENCE).await;
        assert!(late.decided && late.text.contains("abstained: attempts_exhausted"));
        let abstained = night
            .send(DreamsRequest::Abstain {
                run: "night".into(),
                reason: DreamsAbstainReason::NoSupportedChange,
                note: String::new(),
            })
            .await;
        assert!(abstained.text.contains("abstained: attempts_exhausted"));
    }

    #[tokio::test]
    async fn a_passing_proposal_seals_a_git_derived_patch_and_leaves_the_target_alone() {
        let night = Night::new();
        let before = night.target();
        let first = night.review("night").await;
        assert!(
            first.text.contains(EVIDENCE)
                && first.text.contains("Before check commands-exist: exit 1")
        );
        let reply = night.propose("night", "AGENTS.md", FIXED, EVIDENCE).await;
        assert!(reply.decided, "{}", reply.text);
        let run = RunId::from_request("night").unwrap();
        let view = night.dreams.store.read(&run).unwrap().unwrap();
        let Some(Outcome::Proposed(proposal)) = view.outcome else {
            panic!("The run must hold a proposal");
        };
        let patch = fs::read(night.dreams.store.patch_path(&run, proposal.attempt)).unwrap();
        assert_eq!(proposal.patch_sha256, ContentDigest::of(&patch));
        let patch = String::from_utf8(patch).unwrap();
        assert!(patch.contains("-Run `make test-all`") && patch.contains("+Run `make test`"));
        assert!(patch.starts_with("diff --git a/AGENTS.md b/AGENTS.md\n"));
        assert_eq!(proposal.files, vec!["AGENTS.md"]);
        assert_eq!(proposal.base.as_str(), before.0.trim());
        assert!(!proposal.before[0].passed() && proposal.after[0].passed());
        assert_eq!(proposal.evidence[0].as_str(), EVIDENCE);
        assert_eq!(night.target(), before, "Only apply may touch the target");

        let sealed = fs::read(
            night
                .dreams
                .store
                .root()
                .join("runs")
                .join(run.as_str())
                .join("review/review.json"),
        )
        .unwrap();
        git(
            &night.repository,
            &["commit", "--quiet", "--allow-empty", "-m", "Move on"],
        );
        let again = night.review("night").await;
        assert!(again.decided);
        assert_eq!(
            again.text, first.text,
            "A later review of the same run rereads what was sealed"
        );
        assert_eq!(
            fs::read(
                night
                    .dreams
                    .store
                    .root()
                    .join("runs")
                    .join(run.as_str())
                    .join("review/review.json")
            )
            .unwrap(),
            sealed
        );
    }
}
