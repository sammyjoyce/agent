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
pub use policy::{CheckSpec, DreamsCheckFile, DreamsPolicy, DreamsPolicyFile, ProtectedPaths};
pub use store::{DreamsStore, RunView};

use crate::{protocol::HostResult, runtime::diagnostics};

/// Reserved job id. Rust owns it; `make bindings` writes it to the runtime.
pub const DREAMS_JOB_ID: &str = "dreams";
pub const MAX_WINDOW_HOURS: u8 = 48;
pub const MAX_SUMMARIES: usize = 200;
/// Keeps one review request well inside the runtime frame limit.
pub const MAX_SUMMARY_BYTES: usize = 1024 * 1024;
pub const MAX_EDITS: usize = 4;
pub const MAX_EDIT_BYTES: usize = 64 * 1024;
/// Sealed proposal attempts per run. A constant, so no policy edit can raise it.
pub const MAX_ATTEMPTS: u8 = 3;
/// Upper bound on one Dreams host call; policy keeps total check time below it.
pub const HOST_TIMEOUT_MS: u64 = 21 * 60 * 1000;
pub const NOT_CONFIGURED: &str = "Dreams is not configured";

const MAX_EVIDENCE_CITATIONS: usize = 20;
const MAX_SHOWN_FILES: usize = 32;
/// Above the 128 MiB retention cap, so a healthy log is always read whole.
const MAX_RECEIPT_BYTES: u64 = 160 * 1024 * 1024;
const MAX_RECEIPTS: usize = 400_000;

// ---- Wire: TypeScript-exported, never reachable from the Swift roots ----

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

// ---- Domain: parsed at the broker boundary, trusted inside ----

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
    /// For a run named on the command line or found on disk.
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
    /// The short form `dreams list` shows.
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

/// Why one proposal attempt was not sealed, in words the model can act on.
type Rejection = String;

/// Coordinator-local executor. One per broker, built only when `[dreams]` is configured.
pub struct Dreams {
    state: PathBuf,
    store: DreamsStore,
    policy: DreamsPolicy,
}

impl Dreams {
    /// Refuses a state directory inside the policy repository, where a
    /// proposal could otherwise edit its own evidence.
    pub fn open(state: &Path, policy: DreamsPolicy) -> Result<Self> {
        let store = DreamsStore::open(state)?;
        ensure!(
            !state
                .canonicalize()
                .context("The state directory is unavailable")?
                .starts_with(policy.repository()),
            "Dreams repository must not contain the state directory"
        );
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

    /// The sealed review, or the reply that tells the model to make one.
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
            // Captured before the checks run, so a check that writes into its
            // directory cannot change what the model is shown.
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

    /// Current contents of the tracked editable files, so the model can return
    /// each changed file whole.
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
        let reason = match self
            .attempt(
                &view, attempt, &directory, edits, rationale, evidence, cancelled,
            )
            .await?
        {
            Ok(proposal) => {
                let outcome = self
                    .store
                    .seal_outcome(&run, &Outcome::Proposed(Box::new(proposal)))?;
                return Ok(Self::decided(&run, &outcome));
            }
            Err(reason) => reason,
        };
        store::write_json(
            &directory.join("verdict.json"),
            &serde_json::json!({ "accepted": false, "reason": reason }),
        )?;
        let rejected =
            format!("Dreams proposal attempt {attempt} of {MAX_ATTEMPTS} rejected: {reason}.");
        if attempt < MAX_ATTEMPTS {
            return Ok(Self::reply(
                &run,
                false,
                format!(
                    "{rejected} {} of {MAX_ATTEMPTS} attempts remain.",
                    MAX_ATTEMPTS - attempt
                ),
            ));
        }
        let outcome = self.store.seal_outcome(&run, &exhausted)?;
        let mut reply = Self::decided(&run, &outcome);
        reply.text = format!("{rejected}\n{}", reply.text);
        Ok(reply)
    }

    /// Validates one attempt against the policy and the sealed review.
    #[allow(clippy::too_many_arguments)]
    async fn attempt(
        &self,
        view: &RunView,
        _attempt: u8,
        _directory: &Path,
        edits: &[DreamsFileEdit],
        _rationale: &str,
        evidence: &[String],
        _cancelled: &watch::Receiver<bool>,
    ) -> Result<std::result::Result<Proposal, Rejection>> {
        if edits.is_empty() || edits.len() > MAX_EDITS {
            return Ok(Err(format!("a proposal changes 1 to {MAX_EDITS} files")));
        }
        let mut paths = Vec::new();
        for edit in edits {
            let path = match self.policy.editable(&edit.path) {
                Ok(path) => path,
                Err(reason) => return Ok(Err(reason)),
            };
            if edit.content.len() > MAX_EDIT_BYTES {
                return Ok(Err(format!(
                    "{} is larger than {MAX_EDIT_BYTES} bytes",
                    edit.path
                )));
            }
            if paths.contains(&path) {
                return Ok(Err(format!("{} is edited twice", edit.path)));
            }
            paths.push(path);
        }
        if evidence.is_empty() || evidence.len() > MAX_EVIDENCE_CITATIONS {
            return Ok(Err(format!(
                "a proposal cites 1 to {MAX_EVIDENCE_CITATIONS} evidence ids"
            )));
        }
        let reviewed = self.store.evidence(&view.id)?;
        if let Some(unknown) = evidence
            .iter()
            .find(|cited| !reviewed.iter().any(|item| item.id.as_str() == *cited))
        {
            let shown: String = unknown.chars().take(96).collect();
            return Ok(Err(format!("evidence id {shown:?} is not in this review")));
        }
        anyhow::bail!("Dreams cannot build candidates yet")
    }
}
