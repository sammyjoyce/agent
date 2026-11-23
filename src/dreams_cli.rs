use std::path::Path;

use agent_cli::{
    config::ClientConfig,
    dreams::{
        Abstention, CheckPhase, ContentDigest, DreamsStore, EvidenceId, EvidenceItem, MAX_ATTEMPTS,
        Outcome, Review, RunId, RunView, SealedOutcome,
        apply::{POLICY_CHANGED, ProposalStatus, apply_proposal, short, status_of},
        check_lines, escape_controls, format_utc, quote, review_summary,
    },
};
use anyhow::{Context, Result};
use clap::Subcommand;
use serde::Serialize;

#[derive(Subcommand)]
pub enum DreamsAction {
    /// List Dreams runs, newest first, with coverage, outcome and current status.
    List,
    /// Show one run: window, coverage gaps, checks, evidence, patch and how to apply it.
    Show { run: String },
    /// Approve the exact sealed outcome by its digest and apply its patch to the policy repository once.
    Apply {
        run: String,
        /// The outcome digest printed by `dreams show`.
        #[arg(long, value_name = "sha256:OUTCOME_DIGEST")]
        approve: String,
    },
}

#[derive(Serialize)]
struct RunReport<'a> {
    run: &'a RunId,
    review: &'a Review,
    evidence: &'a [EvidenceItem],
    outcome: Option<&'a SealedOutcome>,
    outcome_sha256: Option<&'a ContentDigest>,
    status: Option<&'a ProposalStatus>,
    patch: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    patch_path: Option<&'a Path>,
    apply: Option<String>,
    attempts_used: u8,
}

#[derive(Serialize)]
struct RunSummary {
    run: RunId,
    window_end_ms: u64,
    coverage: &'static str,
    outcome: String,
    status: Option<ProposalStatus>,
}

fn coverage_word(review: &Review) -> &'static str {
    if review.coverage.complete() {
        "complete"
    } else {
        "incomplete"
    }
}

fn apply_command(view: &RunView) -> Option<String> {
    match (&view.outcome, &view.outcome_sha256) {
        (Some(Outcome::Proposed(_)), Some(digest)) => Some(format!(
            "beep-boop dreams apply {} --approve {digest}",
            view.id
        )),
        _ => None,
    }
}

const SHOWN_EVIDENCE_BYTES: usize = 4_000;
const SHOWN_EVIDENCE_TOTAL_BYTES: usize = 4 * SHOWN_EVIDENCE_BYTES;

fn cited_evidence(lines: &mut Vec<String>, cited: &[EvidenceId], reviewed: &[EvidenceItem]) {
    lines.push("Cited evidence (untrusted, quoted):".into());
    let mut budget = SHOWN_EVIDENCE_TOTAL_BYTES;
    for id in cited {
        lines.push(format!("evidence {}", escape_controls(id.as_str())));
        let Some(item) = reviewed.iter().find(|item| &item.id == id) else {
            lines.push("[not in the sealed review]".into());
            continue;
        };
        let shown = item
            .body
            .floor_char_boundary(SHOWN_EVIDENCE_BYTES.min(budget));
        budget -= shown;
        if shown > 0 {
            quote(lines, &item.body[..shown]);
        }
        if shown < item.body.len() {
            lines.push(format!(
                "[... {} more bytes; dreams show --json has the exact record]",
                item.body.len() - shown
            ));
        }
    }
}

fn render(report: &RunReport) -> String {
    let review = report.review;
    let mut lines = vec![format!(
        "Dreams run {} (request {})",
        report.run,
        escape_controls(&review.request_id)
    )];
    lines.extend(review_summary(review));
    lines.push(format!(
        "Repository: {} (policy {})",
        review.repository.display(),
        review.policy_digest.short()
    ));
    match report.outcome.map(|sealed| &sealed.outcome) {
        None => lines.push(format!(
            "Outcome: undecided ({} of {MAX_ATTEMPTS} attempts used)",
            report.attempts_used
        )),
        Some(outcome @ Outcome::Abstained(abstention)) => {
            lines.push(format!("Outcome: {}", outcome.label()));
            if let Abstention::Chosen { note, .. } = abstention
                && !note.as_str().is_empty()
            {
                lines.push("Note (model-written, untrusted):".into());
                quote(&mut lines, note.as_str());
            }
        }
        Some(Outcome::Proposed(proposal)) => {
            lines.push(format!(
                "Outcome: proposed, attempt {} of {MAX_ATTEMPTS}",
                proposal.attempt
            ));
            for check in &proposal.after {
                check_lines(&mut lines, CheckPhase::After, check);
            }
            lines.push(format!(
                "Patch: {}  {}",
                proposal.patch_sha256,
                proposal.files.join(", ")
            ));
            if let Some(path) = report.patch_path {
                lines.push(format!(
                    "Patch file: {}",
                    escape_controls(&path.display().to_string())
                ));
            }
            if let Some(status) = report.status {
                lines.push(format!("Status: {}", status.explain()));
            }
            if let Some(digest) = report.outcome_sha256 {
                lines.push(format!("Outcome sha256: {digest}"));
            }
            lines.push("Rationale (model-written, untrusted):".into());
            quote(&mut lines, proposal.rationale.as_str());
            cited_evidence(&mut lines, &proposal.evidence, report.evidence);
            lines.push("--- patch ---".into());
            lines.push(
                escape_controls(report.patch.unwrap_or_default())
                    .trim_end_matches('\n')
                    .to_owned(),
            );
            lines.push("--- end of patch ---".into());
            if let Some(command) = &report.apply {
                lines.push("Approve this exact outcome and apply it once:".into());
                lines.push(format!("  {command}"));
            }
        }
    }
    lines.join("\n") + "\n"
}

fn format_apply_message(outcome: &agent_cli::dreams::apply::ApplyOutcome) -> String {
    if outcome.already_applied {
        format!(
            "Dreams run {} is already applied as commit {}; nothing changed.",
            outcome.run,
            short(&outcome.commit)
        )
    } else {
        format!(
            "Applied Dreams run {} as commit {} to {}.",
            outcome.run,
            short(&outcome.commit),
            outcome.repository.display()
        )
    }
}

pub async fn run(
    state: &Path,
    config: &ClientConfig,
    json: bool,
    action: DreamsAction,
) -> Result<()> {
    let policy = config.dreams_policy()?;
    if let Some(policy) = &policy {
        policy.refuse_state_inside(state)?;
    }
    let store = DreamsStore::open(state)?;
    match action {
        DreamsAction::List => {
            let mut runs = Vec::new();
            for view in store.list()? {
                runs.push(RunSummary {
                    status: status_of(&store, policy.as_ref(), &view)
                        .await?
                        .map(|(status, _)| status),
                    window_end_ms: view.review.coverage.window.end_ms,
                    coverage: coverage_word(&view.review),
                    outcome: view
                        .outcome
                        .as_ref()
                        .map_or_else(|| "undecided".into(), Outcome::label),
                    run: view.id,
                });
            }
            if json {
                println!("{}", serde_json::to_string_pretty(&runs)?);
            } else {
                println!(
                    "{:<17} {:<24} {:<11} {:<33} STATUS",
                    "RUN", "WINDOW END", "COVERAGE", "OUTCOME"
                );
                for run in runs {
                    println!(
                        "{:<17} {:<24} {:<11} {:<33} {}",
                        run.run,
                        format_utc(run.window_end_ms),
                        run.coverage,
                        run.outcome,
                        run.status.as_ref().map_or("-", ProposalStatus::wire_name)
                    );
                }
            }
        }
        DreamsAction::Show { run } => {
            let run = RunId::parse(&run)?;
            let view = store
                .read(&run)?
                .with_context(|| format!("Unknown Dreams run {run}"))?;
            let (status, patch) = status_of(&store, policy.as_ref(), &view).await?.unzip();
            let patch = patch.map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
            let patch_path = match &view.outcome {
                Some(Outcome::Proposed(proposal)) => {
                    Some(store.patch_path(&view.id, proposal.attempt))
                }
                _ => None,
            };
            let sealed = view.outcome.clone().map(|outcome| SealedOutcome {
                review_sha256: view.review_sha256.clone(),
                outcome,
            });
            let report = RunReport {
                run: &view.id,
                review: &view.review,
                evidence: &view.evidence,
                outcome: sealed.as_ref(),
                outcome_sha256: view.outcome_sha256.as_ref(),
                status: status.as_ref(),
                patch: patch.as_deref(),
                patch_path: patch_path.as_deref(),
                apply: apply_command(&view),
                attempts_used: view.attempts_used,
            };
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", render(&report));
            }
        }
        DreamsAction::Apply { run, approve } => {
            let outcome = apply_proposal(
                &store,
                policy.as_ref().context(POLICY_CHANGED)?,
                &RunId::parse(&run)?,
                &ContentDigest::parse(&approve)?,
            )
            .await?;
            let message = format_apply_message(&outcome);
            if json {
                println!("{}", serde_json::json!({ "message": message }));
            } else {
                println!("{message}");
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use agent_cli::serialized_spawn::SerializedSpawn;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
        process::Command,
    };

    use agent_cli::{
        config::ClientConfig,
        dreams::{
            Dreams, DreamsCheckFile, DreamsFileEdit, DreamsPolicy, DreamsPolicyFile, DreamsRequest,
            DreamsStore, DreamsTaskSummary, ProtectedPaths, RunId, SealedOutcome,
            apply::{ProposalStatus, Reachability, apply_proposal, status_of},
        },
        protocol::HostResult,
    };
    use tokio::sync::watch;

    use crate::dreams_cli::{
        DreamsAction, RunReport, apply_command, format_apply_message, render, run,
    };

    fn git(repository: &Path, arguments: &[&str]) -> String {
        let output = Command::new("git")
            .arg("-C")
            .arg(repository)
            .args(arguments)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .output_serialized()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    const PLAYBOOK: &str = "# Build\n\nRun `make test`.\n";

    struct ProposedPlaybook {
        repository: PathBuf,
        state: PathBuf,
        policy_file: DreamsPolicyFile,
        policy: DreamsPolicy,
        head: String,
        run: RunId,
    }

    async fn proposed_playbook(base: &Path) -> ProposedPlaybook {
        let (repository, state) = (base.join("guidance"), base.join("state"));
        fs::create_dir(&repository).unwrap();
        fs::create_dir(&state).unwrap();
        fs::write(repository.join("AGENTS.md"), "Read the playbooks.\n").unwrap();
        git(&repository, &["init", "--quiet", "--initial-branch=main"]);
        git(&repository, &["config", "user.name", "Example"]);
        git(&repository, &["config", "user.email", "example@invalid"]);
        git(&repository, &["add", "."]);
        git(
            &repository,
            &["commit", "--quiet", "-m", "Add example guidance"],
        );
        let head = git(&repository, &["rev-parse", "HEAD"]);
        fs::write(base.join("check.sh"), "test -f playbooks/build.md\n").unwrap();
        let policy_file = DreamsPolicyFile {
            repository: repository.clone(),
            editable: vec!["playbooks/*.md".into()],
            window_hours: Some(1),
            checks: vec![DreamsCheckFile {
                name: "playbook-exists".into(),
                argv: vec![
                    "/bin/sh".into(),
                    base.join("check.sh").to_string_lossy().into_owned(),
                ],
                timeout_seconds: 30,
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
        let dreams = Dreams::open(&state, policy.clone()).unwrap();
        for request in [
            DreamsRequest::Review {
                run: "night".into(),
                summaries: vec![DreamsTaskSummary {
                    task_id: "task-1".into(),
                    title: "Example build".into(),
                    summary: "Nobody knew how to build.".into(),
                    updated_at: 7,
                }],
                summaries_omitted: 0,
                page: 1,
            },
            DreamsRequest::Propose {
                run: "night".into(),
                edits: vec![DreamsFileEdit {
                    path: "playbooks/build.md".into(),
                    content: PLAYBOOK.into(),
                }],
                rationale: "Add\u{1b}[2K the missing playbook.".into(),
                evidence: vec!["t:task-1@7".into()],
            },
        ] {
            let (_owner, cancelled) = watch::channel(false);
            assert!(matches!(
                dreams.execute(request, cancelled).await,
                HostResult::Dreams { .. }
            ));
        }
        ProposedPlaybook {
            repository,
            state,
            policy_file,
            policy,
            head,
            run: RunId::from_request("night").unwrap(),
        }
    }

    #[tokio::test]
    async fn a_proposed_new_file_applies_once_even_after_an_interrupted_apply_left_it_behind() {
        let root = tempfile::tempdir().unwrap();
        let ProposedPlaybook {
            repository,
            state,
            policy,
            head,
            ..
        } = proposed_playbook(&root.path().canonicalize().unwrap()).await;
        let playbook = PLAYBOOK;
        let store = DreamsStore::open(&state).unwrap();
        let run = RunId::from_request("night").unwrap();
        let view = store.read(&run).unwrap().unwrap();
        let Some(agent_cli::dreams::Outcome::Proposed(proposal)) = &view.outcome else {
            panic!("The run must hold a proposal");
        };
        let approval = view.outcome_sha256.clone().unwrap();
        assert!(matches!(
            status_of(&store, Some(&policy), &view).await.unwrap(),
            Some((ProposalStatus::Pending { interrupted: false }, _))
        ));

        fs::create_dir(repository.join("playbooks")).unwrap();
        fs::write(repository.join("playbooks/build.md"), playbook).unwrap();
        git(&repository, &["add", "playbooks/build.md"]);
        let (status, _) = status_of(&store, Some(&policy), &view)
            .await
            .unwrap()
            .unwrap();
        assert!(matches!(
            &status,
            ProposalStatus::Pending { interrupted: true }
        ));
        let sealed = view.outcome.clone().map(|outcome| SealedOutcome {
            review_sha256: view.review_sha256.clone(),
            outcome,
        });
        let patch_path = store.patch_path(&view.id, proposal.attempt);
        let shown = render(&RunReport {
            run: &view.id,
            review: &view.review,
            evidence: &view.evidence,
            outcome: sealed.as_ref(),
            outcome_sha256: view.outcome_sha256.as_ref(),
            status: Some(&status),
            patch: Some("+new\n"),
            patch_path: Some(&patch_path),
            apply: apply_command(&view),
            attempts_used: view.attempts_used,
        });
        assert!(
            shown.contains(&format!("Patch file: {}", patch_path.display())),
            "{shown}"
        );
        assert!(
            shown.contains("an interrupted apply left proposed content"),
            "{shown}"
        );
        assert!(shown.contains(&format!(
            "beep-boop dreams apply {run} --approve {approval}"
        )));
        assert!(
            shown.contains("\n> Add\\u{1b}[2K the missing playbook.\n"),
            "{shown}"
        );

        assert!(
            matches!(
                status_of(&store, None, &view).await.unwrap(),
                Some((ProposalStatus::PolicyChanged, _))
            ),
            "Without the private policy, nothing is admitted"
        );

        let message = format_apply_message(
            &apply_proposal(&store, &policy, &run, &approval)
                .await
                .unwrap(),
        );
        assert!(message.starts_with("Applied Dreams run"), "{message}");
        assert_eq!(git(&repository, &["status", "--porcelain"]), "");
        assert_eq!(
            fs::read_to_string(repository.join("playbooks/build.md")).unwrap(),
            playbook
        );
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);
        let again = format_apply_message(
            &apply_proposal(&store, &policy, &run, &approval)
                .await
                .unwrap(),
        );
        assert!(again.contains("already applied"), "{again}");
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);

        assert!(
            matches!(
                status_of(&store, None, &view).await.unwrap(),
                Some((
                    ProposalStatus::Applied {
                        reachable: Reachability::NotChecked,
                        ..
                    },
                    _
                ))
            ),
            "A recorded apply stays applied without the policy, and Git is not consulted"
        );
    }

    #[tokio::test]
    async fn apply_refuses_while_held_after_a_restore_and_applies_after_the_release() {
        let root = tempfile::tempdir().unwrap();
        let ProposedPlaybook {
            repository,
            state,
            policy_file,
            head,
            run: night,
            ..
        } = proposed_playbook(&root.path().canonicalize().unwrap()).await;
        let config = ClientConfig {
            dreams: Some(policy_file),
            ..ClientConfig::default()
        };
        let store = DreamsStore::open(&state).unwrap();
        let approval = store.read(&night).unwrap().unwrap().outcome_sha256.unwrap();
        let apply = || {
            run(
                &state,
                &config,
                false,
                DreamsAction::Apply {
                    run: night.to_string(),
                    approve: approval.to_string(),
                },
            )
        };
        fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(state.join("restore-hold.json"), "{}").unwrap();

        run(&state, &config, false, DreamsAction::List)
            .await
            .expect("A held state directory still lists its runs");
        let show = DreamsAction::Show {
            run: night.to_string(),
        };
        run(&state, &config, false, show)
            .await
            .expect("A held state directory still shows a run");
        let refused = apply()
            .await
            .expect_err("The command line must not apply while held after a restore");
        assert_eq!(
            refused.to_string(),
            "Dreams apply is held after a restore until `backup release`"
        );
        assert_eq!(git(&repository, &["rev-parse", "HEAD"]), head);
        assert_eq!(git(&repository, &["status", "--porcelain"]), "");
        assert!(!repository.join("playbooks").exists());
        assert!(store.applied(&night).unwrap().is_none());

        assert!(agent_cli::backup::release(&state).unwrap().was_held);
        apply().await.unwrap();
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);
        assert_eq!(git(&repository, &["status", "--porcelain"]), "");
        assert_eq!(
            fs::read_to_string(repository.join("playbooks/build.md")).unwrap(),
            PLAYBOOK
        );
    }

    #[test]
    fn every_status_label_is_the_name_its_json_uses() {
        let digest = agent_cli::dreams::ContentDigest::of(b"example");
        for status in [
            ProposalStatus::Pending { interrupted: false },
            ProposalStatus::Applied {
                commit: "a".repeat(40),
                reachable: Reachability::Reachable,
            },
            ProposalStatus::Stale {
                head: "b".repeat(40),
            },
            ProposalStatus::TargetDirty,
            ProposalStatus::TargetLocked {
                lock: "/example/guidance/.git/index.lock".into(),
            },
            ProposalStatus::PatchChanged { actual: digest },
            ProposalStatus::PolicyChanged,
        ] {
            assert_eq!(
                serde_json::to_value(&status).unwrap()["state"],
                status.wire_name()
            );
            assert!(status.explain().starts_with(status.wire_name()));
        }
    }
}
