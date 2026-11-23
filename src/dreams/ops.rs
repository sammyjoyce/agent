//! Coordinator service-boundary adapter for native Dreams review and apply.
//!
//! Delegates all proposal inspection, patch verification, commit building, and
//! fast-forward application to `crate::dreams::apply`. Never forwarded to Pi.

use std::path::Path;

use anyhow::{Context, Result};

use crate::{
    dreams::{
        Abstention, CheckPhase, CheckResult, ContentDigest, DreamsPolicy, DreamsStore, EvidenceId,
        EvidenceItem, EvidenceKind, Outcome, RunId,
        apply::{self, ApplyOutcome, DreamsRejected, ProposalStatus},
        check_lines, escape_controls,
    },
    native::{DreamsCheckItem, DreamsEvidenceCite, DreamsRunDetail, DreamsRunSummary},
};

fn format_check_item(phase: CheckPhase, check: &CheckResult) -> DreamsCheckItem {
    let mut lines = Vec::new();
    check_lines(&mut lines, phase, check);
    DreamsCheckItem {
        name: check.name.clone(),
        phase: match phase {
            CheckPhase::Before => "before".into(),
            CheckPhase::After => "after".into(),
        },
        passed: check.passed(),
        verdict: check.verdict(),
        duration_ms: check.duration_ms,
        output: lines.into_iter().skip(1).collect::<Vec<_>>().join("\n"),
    }
}

fn resolve_cited_evidence(
    cited: &[EvidenceId],
    evidence: &[EvidenceItem],
) -> Vec<DreamsEvidenceCite> {
    cited
        .iter()
        .filter_map(|id| evidence.iter().find(|item| &item.id == id))
        .map(|item| DreamsEvidenceCite {
            id: item.id.as_str().to_owned(),
            kind: match item.kind {
                EvidenceKind::Summary => "summary".into(),
                EvidenceKind::Receipt => "receipt".into(),
            },
            title: item.title.as_deref().map(escape_controls),
            body: escape_controls(&item.body),
        })
        .collect()
}

struct ShowOutcome {
    label: String,
    rationale_or_note: Option<String>,
    files: Vec<String>,
    patch: Option<String>,
    patch_sha256: Option<String>,
    cited_evidence: Vec<DreamsEvidenceCite>,
    after_checks: Vec<DreamsCheckItem>,
}

impl ShowOutcome {
    fn from_view(
        outcome: Option<&Outcome>,
        evidence: &[EvidenceItem],
        patch_text: Option<String>,
    ) -> Self {
        match outcome {
            Some(Outcome::Proposed(proposal)) => Self {
                label: "proposed".into(),
                rationale_or_note: Some(escape_controls(proposal.rationale.as_str())),
                files: proposal.files.clone(),
                patch: patch_text,
                patch_sha256: Some(proposal.patch_sha256.as_str().to_owned()),
                cited_evidence: resolve_cited_evidence(&proposal.evidence, evidence),
                after_checks: proposal
                    .after
                    .iter()
                    .map(|check| format_check_item(CheckPhase::After, check))
                    .collect(),
            },
            Some(outcome @ Outcome::Abstained(Abstention::Chosen { note, .. })) => Self {
                label: outcome.label(),
                rationale_or_note: Some(escape_controls(note.as_str())),
                files: Vec::new(),
                patch: None,
                patch_sha256: None,
                cited_evidence: Vec::new(),
                after_checks: Vec::new(),
            },
            Some(outcome @ Outcome::Abstained(Abstention::AttemptsExhausted { attempts })) => {
                Self {
                    label: outcome.label(),
                    rationale_or_note: Some(format!(
                        "Proposal attempts exhausted after {attempts} tries."
                    )),
                    files: Vec::new(),
                    patch: None,
                    patch_sha256: None,
                    cited_evidence: Vec::new(),
                    after_checks: Vec::new(),
                }
            }
            None => Self {
                label: "undecided".into(),
                rationale_or_note: None,
                files: Vec::new(),
                patch: None,
                patch_sha256: None,
                cited_evidence: Vec::new(),
                after_checks: Vec::new(),
            },
        }
    }
}

pub async fn native_list(
    state: &Path,
    policy: Option<&DreamsPolicy>,
) -> Result<(Vec<DreamsRunSummary>, u32)> {
    let store = DreamsStore::open(state)?;
    let views = store.list()?;
    let mut runs = Vec::with_capacity(views.len());
    let mut pending_count = 0u32;
    for view in views {
        let proposal_status = apply::status_of(&store, policy, &view)
            .await?
            .map(|(status, _)| status);
        if proposal_status
            .as_ref()
            .is_some_and(ProposalStatus::is_pending)
        {
            pending_count = pending_count.saturating_add(1);
        }
        let outcome_label = view
            .outcome
            .as_ref()
            .map_or_else(|| "undecided".into(), Outcome::label);
        runs.push(DreamsRunSummary {
            run: view.id.as_str().to_owned(),
            window_start_ms: view.review.coverage.window.start_ms,
            window_end_ms: view.review.coverage.window.end_ms,
            coverage_complete: view.review.coverage.complete(),
            outcome_label,
            proposal_status: proposal_status.as_ref().map(ProposalStatus::kind),
        });
    }
    Ok((runs, pending_count))
}

pub async fn native_show(
    state: &Path,
    policy: Option<&DreamsPolicy>,
    run: &RunId,
) -> Result<DreamsRunDetail> {
    let store = DreamsStore::open(state)?;
    let view = store
        .read(run)?
        .ok_or_else(|| anyhow::Error::new(DreamsRejected(format!("Unknown Dreams run {run}"))))?;
    let status_and_patch = apply::status_of(&store, policy, &view).await?;
    let patch_text = status_and_patch
        .as_ref()
        .map(|(_, bytes)| escape_controls(&String::from_utf8_lossy(bytes)));
    let status = status_and_patch.map(|(status, _)| status);

    let mut checks: Vec<_> = view
        .review
        .before
        .iter()
        .map(|check| format_check_item(CheckPhase::Before, check))
        .collect();
    let outcome = ShowOutcome::from_view(view.outcome.as_ref(), &view.evidence, patch_text);
    checks.extend(outcome.after_checks);

    let outcome_sha256 = view
        .outcome_sha256
        .as_ref()
        .map(|digest| digest.as_str().to_owned());
    let can_apply = policy.is_some()
        && outcome_sha256.is_some()
        && status.as_ref().is_some_and(ProposalStatus::is_pending);

    Ok(DreamsRunDetail {
        run: view.id.as_str().to_owned(),
        window_start_ms: view.review.coverage.window.start_ms,
        window_end_ms: view.review.coverage.window.end_ms,
        coverage_complete: view.review.coverage.complete(),
        gaps: view
            .review
            .coverage
            .gaps()
            .map(|gap| escape_controls(&gap.to_string()))
            .collect(),
        receipts_count: view.review.coverage.receipts.items,
        summaries_count: view.review.coverage.summaries.items,
        summaries_captured_at_ms: view.review.coverage.summaries.captured_at_ms,
        base_revision: view.review.base.as_str().to_owned(),
        outcome_label: outcome.label,
        outcome_sha256,
        proposal_status: status.as_ref().map(ProposalStatus::kind),
        status_detail: status.as_ref().map(ProposalStatus::detail),
        rationale_or_note: outcome.rationale_or_note,
        files: outcome.files,
        patch: outcome.patch,
        patch_sha256: outcome.patch_sha256,
        attempts_used: view.attempts_used,
        can_apply,
        checks,
        cited_evidence: outcome.cited_evidence,
    })
}

pub async fn native_apply(
    state: &Path,
    policy: &DreamsPolicy,
    run: &RunId,
    approve: &ContentDigest,
) -> Result<ApplyOutcome> {
    policy
        .refuse_state_inside(state)
        .context("Refusing to apply Dreams proposal with state inside policy repository")?;
    let store = DreamsStore::open(state)?;
    apply::apply_proposal(&store, policy, run, approve).await
}

#[cfg(test)]
pub(crate) mod test_support {
    use std::{fs, path::Path, process::Command};

    use crate::{
        dreams::{
            CheckResult, ContentDigest, Coverage, DreamsCheckFile, DreamsPolicy, DreamsPolicyFile,
            DreamsStore, EvidenceId, EvidenceItem, EvidenceKind, Interval, Outcome, Proposal,
            ProposedFile, ProtectedPaths, ReceiptCoverage, Review, Revision, RunId,
            SummarySnapshot, UntrustedText,
        },
        serialized_spawn::SerializedSpawn,
    };

    pub(crate) struct SampleProposal {
        pub(crate) policy: DreamsPolicy,
        pub(crate) run: RunId,
        pub(crate) patch_bytes: Vec<u8>,
    }

    pub(crate) fn git(repo: &Path, args: &[&str]) -> String {
        let output = Command::new("git")
            .args(args)
            .current_dir(repo)
            .output_serialized()
            .unwrap();
        assert!(
            output.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    pub(crate) fn write_sample_proposal(
        repo: &Path,
        state: &Path,
        run_name: &str,
        before_content: &str,
        after_content: &str,
    ) -> SampleProposal {
        fs::create_dir_all(repo).unwrap();
        fs::create_dir_all(state).unwrap();
        git(repo, &["init", "-q"]);
        git(repo, &["config", "user.name", "Test"]);
        git(repo, &["config", "user.email", "test@example.com"]);
        fs::write(repo.join("AGENTS.md"), before_content).unwrap();
        git(repo, &["add", "AGENTS.md"]);
        git(repo, &["commit", "-q", "-m", "init"]);
        let base = Revision::parse(git(repo, &["rev-parse", "HEAD"]).trim()).unwrap();

        let policy_file = DreamsPolicyFile {
            repository: repo.to_path_buf(),
            editable: vec!["AGENTS.md".into()],
            window_hours: Some(24),
            checks: vec![DreamsCheckFile {
                name: "ok".into(),
                argv: vec!["true".into()],
                timeout_seconds: 10,
            }],
        };
        let policy = DreamsPolicy::parse(
            &policy_file,
            &ProtectedPaths {
                config: None,
                job_directories: &[],
            },
        )
        .unwrap();

        let store = DreamsStore::open(state).unwrap();
        let run = RunId::from_request(run_name).unwrap();
        let staged = store.stage_review(&run).unwrap();
        let ev_id = EvidenceId::task("task-1", 1000);
        let review = Review {
            run: run.clone(),
            request_id: "req-1".into(),
            base: base.clone(),
            repository: policy.repository().to_path_buf(),
            policy_digest: policy.digest().clone(),
            coverage: Coverage {
                window: Interval {
                    start_ms: 1000,
                    end_ms: 2000,
                },
                receipts: ReceiptCoverage {
                    covered: vec![Interval {
                        start_ms: 1000,
                        end_ms: 2000,
                    }],
                    items: 2,
                    gaps: vec![],
                },
                summaries: SummarySnapshot {
                    items: 1,
                    gaps: vec![],
                    captured_at_ms: 2000,
                },
            },
            before: vec![CheckResult {
                name: "ok".into(),
                argv: vec!["true".into()],
                exit_code: Some(0),
                timed_out: false,
                duration_ms: 12,
                stdout: "before\x1b[31mok".into(),
                stderr: String::new(),
                truncated: false,
            }],
            findings: vec![],
        };
        let evidence = vec![EvidenceItem {
            id: ev_id.clone(),
            at_ms: 1000,
            kind: EvidenceKind::Summary,
            title: Some("Task\x1b[31m title".into()),
            body: "Updated rule\x1b[0m needed".into(),
        }];
        DreamsStore::write_review(&staged, &review, &evidence, &[]).unwrap();
        store.seal_review(&staged, &run).unwrap();

        fs::write(repo.join("AGENTS.md"), after_content).unwrap();
        let patch_bytes = git(repo, &["diff", "--binary", "AGENTS.md"]).into_bytes();
        let proposed_blob = git(repo, &["hash-object", "-w", "AGENTS.md"])
            .trim()
            .to_owned();
        let base_blob = git(repo, &["rev-parse", "HEAD:AGENTS.md"])
            .trim()
            .to_owned();
        git(repo, &["checkout", "--", "AGENTS.md"]);

        let attempt_dir = store.allocate_attempt(&run).unwrap().unwrap().1;
        DreamsStore::write_patch(&attempt_dir, &patch_bytes).unwrap();
        let view = store.read(&run).unwrap().unwrap();
        let outcome = Outcome::Proposed(Box::new(Proposal {
            run: run.clone(),
            attempt: 1,
            repository: policy.repository().to_path_buf(),
            base,
            patch_sha256: ContentDigest::of(&patch_bytes),
            files: vec!["AGENTS.md".into()],
            changes: vec![ProposedFile {
                path: "AGENTS.md".into(),
                change: crate::dreams::FileChange::Changed { base_blob },
                proposed_blob,
            }],
            evidence: vec![ev_id],
            rationale: UntrustedText::bounded("Replace\x1b[2J stale rule", 200),
            before: review.before.clone(),
            after: vec![CheckResult {
                name: "ok".into(),
                argv: vec!["true".into()],
                exit_code: Some(0),
                timed_out: false,
                duration_ms: 15,
                stdout: "after ok".into(),
                stderr: String::new(),
                truncated: false,
            }],
            policy_digest: policy.digest().clone(),
        }));
        store.seal_outcome(&view, &outcome).unwrap();

        SampleProposal {
            policy,
            run,
            patch_bytes,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use super::*;
    use crate::native::DreamsProposalStatus;

    #[tokio::test]
    async fn native_list_show_and_apply_use_fast_forward_trailers_and_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let repo = dir.path().join("repo");
        let state = dir.path().join("state");
        let sample = test_support::write_sample_proposal(
            &repo,
            &state,
            "run-1",
            "# Old rule\n",
            "# New rule\n",
        );

        // Simulate an interrupted prior apply where the proposed content was left on disk.
        fs::write(repo.join("AGENTS.md"), "# New rule\n").unwrap();

        let (listed, pending) = native_list(&state, Some(&sample.policy)).await.unwrap();
        assert_eq!(pending, 1);
        assert_eq!(listed.len(), 1);
        assert_eq!(
            listed[0].proposal_status,
            Some(DreamsProposalStatus::Pending)
        );

        let detail = native_show(&state, Some(&sample.policy), &sample.run)
            .await
            .unwrap();
        assert!(detail.can_apply);
        assert!(
            !detail
                .rationale_or_note
                .as_deref()
                .unwrap()
                .contains('\x1b')
        );
        assert!(!detail.cited_evidence[0].body.contains('\x1b'));
        assert_eq!(detail.checks.len(), 2);

        let wrong_digest = ContentDigest::of(b"wrong");
        let err = native_apply(&state, &sample.policy, &sample.run, &wrong_digest)
            .await
            .unwrap_err();
        assert!(err.is::<DreamsRejected>());

        let approval = ContentDigest::parse(detail.outcome_sha256.as_deref().unwrap()).unwrap();
        let applied = native_apply(&state, &sample.policy, &sample.run, &approval)
            .await
            .unwrap();
        assert!(!applied.already_applied);
        assert_eq!(
            fs::read_to_string(repo.join("AGENTS.md")).unwrap(),
            "# New rule\n"
        );
        assert_eq!(test_support::git(&repo, &["status", "--porcelain"]), "");
        let commit_msg = test_support::git(&repo, &["log", "-1", "--format=%B"]);
        assert!(
            commit_msg.contains(&format!("Dreams-Run: {}", sample.run)),
            "{commit_msg}"
        );
        assert!(
            commit_msg.contains(&format!(
                "Dreams-Patch-Sha256: {}",
                ContentDigest::of(&sample.patch_bytes).hex()
            )),
            "{commit_msg}"
        );

        let again = native_apply(&state, &sample.policy, &sample.run, &approval)
            .await
            .unwrap();
        assert!(again.already_applied);
        assert_eq!(again.commit, applied.commit);

        let detail_after = native_show(&state, Some(&sample.policy), &sample.run)
            .await
            .unwrap();
        assert!(!detail_after.can_apply);
        assert_eq!(
            detail_after.proposal_status,
            Some(DreamsProposalStatus::Applied)
        );
    }
}
