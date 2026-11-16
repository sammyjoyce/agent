//! Dreams: nightly, proposal-only review of private operational evidence.
//! This library can review, propose and abstain. It cannot apply. Application
//! lives in the beep-boop binary (src/dreams_cli.rs), which no library code links.
mod evidence;
mod policy;
mod store;
mod types;
pub mod workspace;

use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use tokio::sync::watch;

pub use evidence::{
    EvidenceItem, EvidenceKind, Finding, check_lines, escape_controls, quote, review_summary,
};
pub use policy::{
    CheckSpec, DreamsCheckFile, DreamsPolicy, DreamsPolicyFile, EditablePath, ProtectedPaths,
};
use store::ReviewSeal;
pub use store::{AppliedRecord, DreamsStore, RunView};
pub use types::{
    Abstention, CheckResult, ContentDigest, Coverage, DreamsAbstainReason, DreamsFileEdit,
    DreamsReply, DreamsRequest, DreamsTaskSummary, EvidenceId, Gap, GapCause, Interval, Outcome,
    PolicyDigest, Proposal, ProposedFile, ReceiptCoverage, Review, Revision, RunId,
    SummarySnapshot, UntrustedText, count, format_utc,
};

use crate::{protocol::HostResult, runtime::diagnostics};

pub const DREAMS_JOB_ID: &str = "dreams";
pub const MAX_WINDOW_HOURS: u8 = 48;
pub const MAX_SUMMARIES: usize = 200;
pub const MAX_SUMMARY_BYTES: usize = crate::runtime::MAX_FRAME_BYTES / 4;
pub const MAX_EDITS: usize = 4;
pub const MAX_EDIT_BYTES: usize = 64 * 1024;
pub const MAX_PATH_BYTES: usize = 512;
pub const MAX_RATIONALE_CHARS: usize = 4_000;
pub const MAX_NOTE_CHARS: usize = 2_000;
pub const MAX_EVIDENCE_CITATIONS: usize = 20;
pub const MAX_EVIDENCE_ID_CHARS: usize = 96;
pub const MAX_REVIEW_PAGE: u32 = 10_000;
pub const MAX_ATTEMPTS: u8 = 3;
pub const HOST_TIMEOUT_MS: u64 = 21 * 60 * 1000;
pub const NOT_CONFIGURED: &str = "Dreams is not configured";

const MAX_SHOWN_FILES: usize = 32;
const MAX_RECEIPT_BYTES: u64 = diagnostics::RETENTION_CAP_BYTES + 32 * 1024 * 1024;
const MAX_RECEIPTS: usize = 400_000;

pub(crate) struct Rejection {
    reason: String,
    output: Vec<String>,
}
impl Rejection {
    pub(crate) fn because(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            output: Vec::new(),
        }
    }
}

pub(crate) enum AttemptError {
    Rejected(Rejection),
    Failed(anyhow::Error),
}
impl From<Rejection> for AttemptError {
    fn from(rejection: Rejection) -> Self {
        Self::Rejected(rejection)
    }
}
impl From<anyhow::Error> for AttemptError {
    fn from(error: anyhow::Error) -> Self {
        Self::Failed(error)
    }
}
impl From<std::io::Error> for AttemptError {
    fn from(error: std::io::Error) -> Self {
        Self::Failed(error.into())
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
        let end_ms = diagnostics::now_ms();
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
            let repository = self.policy.repository();
            let base = workspace::resolve_base(repository).await?;
            let reading = DreamsStore::files_clone(&staged);
            workspace::clone_detached(repository, &base, &reading).await?;
            let files = self.editable_files(&reading).await?;
            std::fs::remove_dir_all(&reading)?;
            let checking = DreamsStore::base_clone(&staged);
            workspace::clone_detached(repository, &base, &checking).await?;
            let before = workspace::run_checks(&checking, self.policy.checks(), cancelled).await?;
            DreamsStore::write_review(
                &staged,
                &Review {
                    run: run.clone(),
                    request_id: request_id.to_owned(),
                    coverage,
                    repository: repository.to_owned(),
                    base,
                    policy_digest: self.policy.digest().clone(),
                    before,
                    findings,
                },
                &items,
                &files,
            )?;
            self.store.seal_review(&staged, run)
        }
        .await;
        if built.is_err() {
            let _ = std::fs::remove_dir_all(&staged);
        }
        built.map(|_: ReviewSeal| ())
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
                Ok(_) => match std::fs::read_to_string(&file) {
                    Ok(content) => content,
                    Err(error) if error.kind() == std::io::ErrorKind::InvalidData => {
                        "[not UTF-8 text; not editable]".into()
                    }
                    Err(error) => return Err(error).context("Could not read an editable file"),
                },
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
                note: UntrustedText::bounded(note, MAX_NOTE_CHARS),
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
            .await
        {
            Ok(proposal) => {
                DreamsStore::write_verdict(&directory, None)?;
                let outcome = self
                    .store
                    .seal_outcome(&run, &Outcome::Proposed(Box::new(proposal)))?;
                return Ok(Self::decided(&run, &outcome));
            }
            Err(AttemptError::Failed(error)) => return Err(error),
            Err(AttemptError::Rejected(rejection)) => rejection,
        };
        DreamsStore::write_verdict(&directory, Some(&rejection.reason))?;
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
    ) -> Result<Proposal, AttemptError> {
        let reject = |reason: String| AttemptError::from(Rejection::because(reason));
        let review = &view.review;
        if &review.policy_digest != self.policy.digest() {
            return Err(reject(
                "the Dreams policy changed after this review was sealed".into(),
            ));
        }
        if draft.edits.is_empty() || draft.edits.len() > MAX_EDITS {
            return Err(reject(format!("a proposal changes 1 to {MAX_EDITS} files")));
        }
        let mut edits: Vec<(EditablePath, &str)> = Vec::new();
        for edit in draft.edits {
            let path = self.policy.editable(&edit.path).map_err(reject)?;
            if edit.content.len() > MAX_EDIT_BYTES {
                return Err(reject(format!(
                    "{path} is larger than {MAX_EDIT_BYTES} bytes"
                )));
            }
            if edits.iter().any(|(edited, _)| edited == &path) {
                return Err(reject(format!("{path} is edited twice")));
            }
            edits.push((path, &edit.content));
        }
        if draft.evidence.is_empty() || draft.evidence.len() > MAX_EVIDENCE_CITATIONS {
            return Err(reject(format!(
                "a proposal cites 1 to {MAX_EVIDENCE_CITATIONS} evidence ids"
            )));
        }
        let reviewed = self.store.evidence(&view.id)?;
        let mut evidence = Vec::new();
        for cited in draft.evidence {
            let Some(item) = reviewed.iter().find(|item| item.id.as_str() == cited) else {
                let shown: String = cited.chars().take(MAX_EVIDENCE_ID_CHARS).collect();
                return Err(reject(format!(
                    "evidence id {shown:?} is not in this review"
                )));
            };
            evidence.push(item.id.clone());
        }

        let candidate = DreamsStore::candidate_clone(directory);
        workspace::clone_detached(&review.repository, &review.base, &candidate).await?;
        let patch = workspace::write_candidate(&candidate, &review.base, &edits).await?;
        let after = workspace::run_checks(&candidate, self.policy.checks(), cancelled).await?;
        DreamsStore::write_after(directory, &after)?;
        DreamsStore::write_patch(directory, &patch.bytes)?;
        if let Some(failed) = after.iter().find(|check| !check.passed()) {
            let mut output = Vec::new();
            evidence::check_lines(&mut output, "After", failed);
            return Err(Rejection {
                reason: format!("after check {} did not pass", failed.name),
                output,
            }
            .into());
        }
        Ok(Proposal {
            run: view.id.clone(),
            attempt,
            repository: review.repository.clone(),
            base: review.base.clone(),
            patch_sha256: patch.digest,
            files: patch
                .changes
                .iter()
                .map(|change| change.path.clone())
                .collect(),
            changes: patch.changes,
            evidence,
            rationale: UntrustedText::bounded(draft.rationale, MAX_RATIONALE_CHARS),
            before: review.before.clone(),
            after,
            policy_digest: review.policy_digest.clone(),
        })
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
        runtime::diagnostics,
    };

    const BROKEN: &str = "Run `make test-all` before finishing.\n";
    const FIXED: &str = "Run `make test` before finishing.\n";
    const EVIDENCE: &str = "t:task-1@7";
    const CHECK: &str = "for target in $(grep -o 'make [a-z-]*' AGENTS.md | cut -d' ' -f2); do grep -q \"^$target:\" Makefile || { echo \"missing make target: $target\"; exit 1; }; done\n";

    const MINUTE: u64 = 60_000;

    fn heartbeat(timestamp_ms: u64) -> String {
        format!(
            "{{\"timestamp_ms\":{timestamp_ms},\"request_id\":0,\"elapsed_ms\":null,\"event\":\"heartbeat\"}}"
        )
    }

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

        fn seed_receipts(&self, tail: &str) {
            let directory = self.dreams.state.join("diagnostics");
            fs::create_dir(&directory).unwrap();
            let now = diagnostics::now_ms();
            let mut log: String = (now - 120 * MINUTE..=now - MINUTE / 2)
                .step_by(5 * MINUTE as usize)
                .map(|at| heartbeat(at) + "\n")
                .collect();
            log.push_str(tail);
            fs::write(directory.join("runtime.jsonl"), log).unwrap();
            fs::write(
                directory.join("retention.json"),
                r#"{"version":1,"policy":{"segment_bytes":1048576,"horizon_ms":172800000,"max_total_bytes":134217728},"prior_history_unknown":false,"expired_through_ms":null,"capacity_loss":null}"#,
            )
            .unwrap();
        }

        async fn abstain_as_quiet(&self, run: &str) -> DreamsReply {
            self.send(DreamsRequest::Abstain {
                run: run.into(),
                reason: DreamsAbstainReason::Quiet,
                note: "Nothing failed.".into(),
            })
            .await
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

        let sealed = view.review;
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
            night.dreams.store.read(&run).unwrap().unwrap().review,
            sealed
        );
    }

    #[tokio::test]
    async fn a_witnessed_night_is_complete_and_a_malformed_receipt_that_nothing_places_is_a_gap() {
        let quiet = Night::new();
        quiet.seed_receipts("");
        assert!(
            quiet
                .review("night")
                .await
                .text
                .contains("Coverage: complete")
        );
        assert!(quiet.abstain_as_quiet("night").await.decided);

        let now = diagnostics::now_ms();
        let malformed = format!(
            "{{\"timestamp_ms\":{},\"request_id\":7,\"event\":",
            now - MINUTE
        );
        for (name, tail) in [
            (
                "a receipt whose clock went back follows the malformed line",
                format!(
                    "{malformed}\n{}\n{}\n",
                    heartbeat(now - 26 * 60 * MINUTE),
                    heartbeat(now - MINUTE / 2)
                ),
            ),
            (
                "the malformed line is the unfinished last line",
                malformed.clone(),
            ),
        ] {
            let night = Night::new();
            night.seed_receipts(&tail);
            let page = night.review("night").await.text;
            assert!(page.contains("gap unparseable"), "{name}: {page}");
            let quiet = night.abstain_as_quiet("night").await;
            assert!(!quiet.decided, "{name}: {}", quiet.text);
        }
    }

    async fn overflow(night: &Night, sender: &mut diagnostics::Diagnostics, records: u32) -> usize {
        let directory = night.dreams.state.join("diagnostics");
        let lock = fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("writer.lock"))
            .unwrap();
        fs2::FileExt::lock_exclusive(&lock).unwrap();
        let trace = diagnostics::Trace::unowned();
        for id in 1..=records {
            sender.record(id, &trace, diagnostics::Event::RequestReceived);
        }
        fs2::FileExt::unlock(&lock).unwrap();
        let written = || {
            fs::read_to_string(directory.join("runtime.jsonl"))
                .unwrap()
                .lines()
                .filter(|line| line.contains("request_received"))
                .count()
        };
        let mut seen = 0;
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                if written() > 0 && written() == seen {
                    return;
                }
                seen = written();
            }
        })
        .await
        .expect("The writer drains its queue once the lock is free");
        seen
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn receipts_dropped_on_a_full_channel_are_a_gap_whoever_records_next_or_nobody_does() {
        for (name, dropping_fork, records_again) in [
            ("another fork records next", true, true),
            ("the sender that dropped never records again", false, false),
            ("a fork dropped and nothing records again", true, false),
        ] {
            let night = Night::new();
            night.seed_receipts("");
            let mut actor = diagnostics::Diagnostics::start(&night.dreams.state);
            let mut service = actor.fork();
            let sent = 400;
            let written = overflow(
                &night,
                if dropping_fork {
                    &mut service
                } else {
                    &mut actor
                },
                sent,
            )
            .await;
            assert!(written < sent as usize, "{name}: the channel must overflow");
            if records_again {
                actor.record(1, &diagnostics::Trace::unowned(), diagnostics::Event::Done);
                tokio::time::sleep(std::time::Duration::from_millis(300)).await;
            }
            let page = night.review("night").await.text;
            assert!(
                page.contains("gap channel_overflow"),
                "{name}: {} receipts were dropped, but the review lists no gap:\n{}",
                sent as usize - written,
                page.lines()
                    .filter(|line| line.starts_with("Coverage") || line.starts_with("gap "))
                    .collect::<Vec<_>>()
                    .join("\n")
            );
            let quiet = night.abstain_as_quiet("night").await;
            assert!(!quiet.decided, "{name}: {}", quiet.text);
            drop((actor, service));
        }
    }
}
