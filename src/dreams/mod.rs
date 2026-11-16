//! Dreams: nightly, proposal-only review of private operational evidence.
//! This library can review, propose and abstain. It cannot apply. Application
//! lives in the beep-boop binary (src/dreams_cli.rs), which no library code links.
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

/// Reserved job id. Rust owns it; `make bindings` writes it to the runtime.
pub const DREAMS_JOB_ID: &str = "dreams";
pub const MAX_WINDOW_HOURS: u8 = 48;
pub const MAX_SUMMARIES: usize = 200;
/// Keeps one review request well inside the runtime frame limit.
pub const MAX_SUMMARY_BYTES: usize = 1024 * 1024;
/// Upper bound on one Dreams host call; policy keeps total check time below it.
pub const HOST_TIMEOUT_MS: u64 = 21 * 60 * 1000;
pub const NOT_CONFIGURED: &str = "Dreams is not configured";

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
