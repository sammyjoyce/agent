use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

use agent_cli::{
    config::ClientConfig,
    dreams::{
        Abstention, ContentDigest, DreamsPolicy, DreamsStore, EvidenceItem, MAX_ATTEMPTS, Outcome,
        Proposal, ProposedFile, Review, Revision, RunId, RunView, check_lines, escape_controls,
        format_utc, quote, review_summary,
        workspace::{Git, plain_changes},
    },
};
use anyhow::{Context, Result, bail, ensure};
use clap::Subcommand;
use serde::Serialize;
use uuid::Uuid;

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

#[derive(Debug, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum ProposalStatus {
    Pending {
        interrupted: bool,
    },
    Applied {
        commit: String,
        reachable: Option<bool>,
    },
    Stale {
        head: String,
    },
    TargetDirty,
    TargetLocked {
        lock: PathBuf,
    },
    PatchChanged {
        actual: ContentDigest,
    },
    PolicyChanged,
}

impl ProposalStatus {
    fn wire_name(&self) -> &'static str {
        match self {
            Self::Pending { .. } => "pending",
            Self::Applied { .. } => "applied",
            Self::Stale { .. } => "stale",
            Self::TargetDirty => "target_dirty",
            Self::TargetLocked { .. } => "target_locked",
            Self::PatchChanged { .. } => "patch_changed",
            Self::PolicyChanged => "policy_changed",
        }
    }

    fn explain(&self) -> String {
        match self {
            Self::Pending { interrupted: false } => {
                "pending (target HEAD is the base and the touched paths are clean)".into()
            }
            Self::Pending { interrupted: true } => {
                "pending (target HEAD is the base; an interrupted apply left proposed content that apply will finish)".into()
            }
            Self::Applied {
                commit,
                reachable: Some(true),
            } => format!("applied as commit {commit}"),
            Self::Applied {
                commit,
                reachable: Some(false),
            } => format!("applied as commit {commit}, which is no longer reachable from HEAD"),
            Self::Applied {
                commit,
                reachable: None,
            } => format!(
                "applied as commit {commit} (HEAD was not checked: the policy no longer names this repository)"
            ),
            Self::Stale { head } => format!("stale (target HEAD is {head})"),
            Self::TargetDirty => "target_dirty (local changes in touched paths)".into(),
            Self::TargetLocked { lock } => format!(
                "target_locked (a Git index lock is held at {}; another Git command is running, or one crashed)",
                lock.display()
            ),
            Self::PatchChanged { actual } => {
                format!("patch_changed (the patch file now hashes to {actual})")
            }
            Self::PolicyChanged => {
                "policy_changed (the private policy no longer matches this proposal)".into()
            }
        }
    }
}

enum Inspection {
    PatchChanged {
        actual: ContentDigest,
    },
    PolicyChanged,
    Applied {
        commit: String,
        reachable: Option<bool>,
        recorded: bool,
    },
    Stale {
        head: String,
    },
    TargetDirty,
    /// Git would refuse the fast-forward, but only after apply had written to the target.
    IndexLocked {
        lock: PathBuf,
    },
    Ready {
        half_applied: Vec<ProposedFile>,
    },
}

impl Inspection {
    fn status(&self) -> ProposalStatus {
        match self {
            Self::PatchChanged { actual } => ProposalStatus::PatchChanged {
                actual: actual.clone(),
            },
            Self::PolicyChanged => ProposalStatus::PolicyChanged,
            Self::Applied {
                commit, reachable, ..
            } => ProposalStatus::Applied {
                commit: commit.clone(),
                reachable: *reachable,
            },
            Self::Stale { head } => ProposalStatus::Stale { head: head.clone() },
            Self::TargetDirty => ProposalStatus::TargetDirty,
            Self::IndexLocked { lock } => ProposalStatus::TargetLocked { lock: lock.clone() },
            Self::Ready { half_applied } => ProposalStatus::Pending {
                interrupted: !half_applied.is_empty(),
            },
        }
    }
}

fn read_patch(store: &DreamsStore, proposal: &Proposal) -> Result<Vec<u8>> {
    fs::read(store.patch_path(&proposal.run, proposal.attempt))
        .context("The Dreams patch file is missing")
}

enum PathState {
    AtBase,
    HalfApplied,
    LocallyChanged,
}

async fn index_entries(git: &Git, path: &str) -> Result<Vec<(String, String, String, String)>> {
    let listed = git.text(&["ls-files", "-s", "-z", "--", path]).await?;
    let mut entries = Vec::new();
    for entry in listed.split('\0').filter(|entry| !entry.is_empty()) {
        let (fields, name) = entry
            .split_once('\t')
            .context("Git listed an unreadable index entry")?;
        let fields: Vec<&str> = fields.split(' ').collect();
        let [mode, blob, stage] = fields.as_slice() else {
            bail!("Git listed an unreadable index entry");
        };
        entries.push((
            (*mode).to_owned(),
            (*blob).to_owned(),
            (*stage).to_owned(),
            name.to_owned(),
        ));
    }
    Ok(entries)
}

async fn path_state(git: &Git, repository: &Path, file: &ProposedFile) -> Result<PathState> {
    const PLAIN_FILE: &str = "100644";
    let mut parent = PathBuf::new();
    let mut parts: Vec<&str> = file.path.split('/').collect();
    parts.pop();
    for part in parts {
        parent.push(part);
        match fs::symlink_metadata(repository.join(&parent)) {
            Ok(metadata) if metadata.is_dir() => {}
            Ok(_) => return Ok(PathState::LocallyChanged),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error).context("Could not read a touched path's parent"),
        }
        let name = parent.to_str().context("A touched path is not UTF-8")?;
        if index_entries(git, name)
            .await?
            .iter()
            .any(|(_, _, _, listed)| listed == name)
        {
            return Ok(PathState::LocallyChanged);
        }
    }

    let entries: Vec<_> = index_entries(git, &file.path)
        .await?
        .into_iter()
        .filter(|(_, _, _, listed)| listed == &file.path)
        .collect();
    let staged = match entries.as_slice() {
        [] => None,
        [(mode, blob, stage, _)] if mode == PLAIN_FILE && stage == "0" => Some(blob.clone()),
        _ => return Ok(PathState::LocallyChanged),
    };
    let on_disk = match fs::symlink_metadata(repository.join(&file.path)) {
        Ok(metadata) if metadata.is_file() => {
            // Read from the file, not asked of Git. With core.fileMode off Git
            // reports no mode change, and the fast-forward would then reset it.
            if metadata.permissions().mode() & 0o111 != 0 {
                return Ok(PathState::LocallyChanged);
            }
            Some(
                git.text(&["hash-object", "--", &file.path])
                    .await?
                    .trim()
                    .to_owned(),
            )
        }
        Ok(_) => return Ok(PathState::LocallyChanged),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(error).context("Could not read a touched path"),
    };
    let proposed = Some(&file.proposed_blob);
    let is_base = |blob: &Option<String>| blob == &file.base_blob;
    let known = |blob: &Option<String>| is_base(blob) || blob.as_ref() == proposed;
    Ok(if !known(&staged) || !known(&on_disk) {
        PathState::LocallyChanged
    } else if is_base(&staged) && is_base(&on_disk) {
        PathState::AtBase
    } else {
        PathState::HalfApplied
    })
}

async fn recorded_apply(
    store: &DreamsStore,
    policy: Option<&DreamsPolicy>,
    proposal: &Proposal,
) -> Result<Option<Inspection>> {
    let Some(record) = store.applied(&proposal.run)? else {
        return Ok(None);
    };
    let commit = record.commit.as_str();
    let reachable = if policy.is_some_and(|policy| policy.repository() == proposal.repository) {
        let contained = Git::reading(&proposal.repository)
            .run(&["merge-base", "--is-ancestor", commit, "HEAD"])
            .await?;
        Some(contained.exit_code == 0)
    } else {
        None
    };
    Ok(Some(Inspection::Applied {
        commit: commit.to_owned(),
        reachable,
        recorded: true,
    }))
}

async fn inspect(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    proposal: &Proposal,
    patch: &[u8],
) -> Result<Inspection> {
    if let Some(applied) = recorded_apply(store, Some(policy), proposal).await? {
        return Ok(applied);
    }
    let actual = ContentDigest::of(patch);
    if actual != proposal.patch_sha256 {
        return Ok(Inspection::PatchChanged { actual });
    }
    let admitted = policy.digest() == &proposal.policy_digest
        && policy.repository() == proposal.repository
        && proposal
            .files
            .iter()
            .all(|path| policy.editable(path).is_ok());
    if !admitted {
        return Ok(Inspection::PolicyChanged);
    }
    ensure!(
        proposal
            .changes
            .iter()
            .map(|change| &change.path)
            .eq(&proposal.files),
        "The Dreams record names files that its changes do not"
    );

    let git = Git::reading(&proposal.repository);
    let base = proposal.base.as_str();
    let head = git.text(&["rev-parse", "--verify", "HEAD"]).await?;
    let head = head.trim();
    let base_commit = format!("{base}^{{commit}}");
    if git.run(&["cat-file", "-e", &base_commit]).await?.exit_code != 0 {
        return Ok(Inspection::Stale { head: head.into() });
    }
    let range = format!("{base}..HEAD");
    let history = git
        .text(&[
            "log",
            "--format=%H%x09%(trailers:key=Dreams-Run,valueonly,separator=%x2C)%x09%(trailers:key=Dreams-Patch-Sha256,valueonly,separator=%x2C)",
            &range,
        ])
        .await?;
    for line in history.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if let [commit, run, patch] = fields.as_slice()
            && *run == proposal.run.as_str()
            && *patch == proposal.patch_sha256.hex()
        {
            return Ok(Inspection::Applied {
                commit: (*commit).to_owned(),
                reachable: Some(true),
                recorded: false,
            });
        }
    }
    if head != base {
        return Ok(Inspection::Stale { head: head.into() });
    }
    let lock = git.text(&["rev-parse", "--git-path", "index.lock"]).await?;
    let lock = proposal.repository.join(lock.trim_end_matches('\n'));
    if fs::symlink_metadata(&lock).is_ok() {
        return Ok(Inspection::IndexLocked { lock });
    }

    let mut half_applied = Vec::new();
    for file in &proposal.changes {
        match path_state(&git, &proposal.repository, file).await? {
            PathState::AtBase => {}
            PathState::HalfApplied => half_applied.push(file.clone()),
            PathState::LocallyChanged => return Ok(Inspection::TargetDirty),
        }
    }
    Ok(Inspection::Ready { half_applied })
}

#[derive(Serialize)]
struct RunReport<'a> {
    run: &'a RunId,
    review: &'a Review,
    evidence: &'a [EvidenceItem],
    outcome: Option<&'a Outcome>,
    outcome_sha256: Option<&'a ContentDigest>,
    status: Option<&'a ProposalStatus>,
    patch: Option<&'a str>,
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

async fn status_of(
    store: &DreamsStore,
    policy: Option<&DreamsPolicy>,
    view: &RunView,
) -> Result<Option<(ProposalStatus, Vec<u8>)>> {
    let Some(Outcome::Proposed(proposal)) = &view.outcome else {
        return Ok(None);
    };
    let patch = read_patch(store, proposal)?;
    let status = match policy {
        Some(policy) => inspect(store, policy, proposal, &patch).await?.status(),
        None => recorded_apply(store, None, proposal)
            .await?
            .map_or(ProposalStatus::PolicyChanged, |applied| applied.status()),
    };
    Ok(Some((status, patch)))
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
    match report.outcome {
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
                check_lines(&mut lines, "After", check);
            }
            lines.push(format!(
                "Patch: {}  {}",
                proposal.patch_sha256,
                proposal.files.join(", ")
            ));
            let evidence: Vec<&str> = proposal.evidence.iter().map(|id| id.as_str()).collect();
            lines.push(format!("Evidence: {}", evidence.join("  ")));
            if let Some(status) = report.status {
                lines.push(format!("Status: {}", status.explain()));
            }
            if let Some(digest) = report.outcome_sha256 {
                lines.push(format!("Outcome sha256: {digest}"));
            }
            lines.push("Rationale (model-written, untrusted):".into());
            quote(&mut lines, proposal.rationale.as_str());
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

struct ScratchIndex(PathBuf);
impl Drop for ScratchIndex {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
        let mut lock = self.0.clone().into_os_string();
        lock.push(".lock");
        let _ = fs::remove_file(lock);
    }
}

async fn build_commit(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    proposal: &Proposal,
    patch: &[u8],
) -> Result<String> {
    let base = proposal.base.as_str();
    let scratch = ScratchIndex(
        store
            .run_directory(&proposal.run)
            .join(format!(".apply-{}.index", Uuid::new_v4())),
    );
    let staging = Git::writing(&proposal.repository).with_variable(
        "GIT_INDEX_FILE",
        scratch.0.to_str().context("State path is not UTF-8")?,
    );
    staging.text(&["read-tree", base]).await?;
    let applied = staging
        .run_with_input(&["apply", "--cached", "--whitespace=nowarn"], patch)
        .await?;
    ensure!(
        applied.exit_code == 0,
        "The approved patch does not apply to its base: {}",
        applied.stderr.trim()
    );
    let tree = staging.text(&["write-tree"]).await?;
    let tree = tree.trim();

    let git = Git::writing(&proposal.repository);
    let changed = git
        .text(&[
            "diff-tree",
            "-r",
            "--raw",
            "-z",
            "--no-renames",
            "--no-abbrev",
            base,
            tree,
        ])
        .await?;
    let built = plain_changes(&changed)?;
    ensure!(
        built == proposal.changes,
        "The approved patch does not make the changes its record names"
    );
    ensure!(
        built
            .iter()
            .all(|change| policy.editable(&change.path).is_ok()),
        "The approved patch changes a file that is not editable"
    );

    let trailers = format!(
        "Dreams-Run: {}\nDreams-Base: {base}\nDreams-Patch-Sha256: {}",
        proposal.run,
        proposal.patch_sha256.hex()
    );
    let subject = format!("Apply Dreams proposal {}", proposal.run);
    let commit = git
        .text(&[
            "commit-tree",
            tree,
            "-p",
            base,
            "-m",
            &subject,
            "-m",
            &trailers,
        ])
        .await
        .context("Could not create the Dreams commit")?;
    Ok(commit.trim().to_owned())
}

async fn fast_forward(
    proposal: &Proposal,
    commit: &str,
    half_applied: &[ProposedFile],
) -> Result<()> {
    let git = Git::writing(&proposal.repository);
    for file in half_applied {
        match &file.base_blob {
            Some(_) => {
                let source = format!("--source={}", proposal.base);
                git.text(&[
                    "restore",
                    &source,
                    "--staged",
                    "--worktree",
                    "--",
                    &file.path,
                ])
                .await?;
            }
            None => {
                git.text(&[
                    "rm",
                    "--cached",
                    "--quiet",
                    "--ignore-unmatch",
                    "--",
                    &file.path,
                ])
                .await?;
                match fs::remove_file(proposal.repository.join(&file.path)) {
                    Ok(()) => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    Err(error) => return Err(error).context("Could not reset a touched path"),
                }
            }
        }
    }
    git.text(&["merge", "--ff-only", "--quiet", commit])
        .await
        .context("The target could not fast-forward to the Dreams commit")?;
    Ok(())
}

const POLICY_CHANGED: &str = "Dreams policy changed since this proposal";

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

async fn apply(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    run: &RunId,
    approval: &ContentDigest,
) -> Result<String> {
    let view = store
        .read(run)?
        .with_context(|| format!("Unknown Dreams run {run}"))?;
    ensure!(
        view.outcome_sha256.as_ref() == Some(approval),
        "Dreams approval does not match the review"
    );
    let Some(Outcome::Proposed(proposal)) = &view.outcome else {
        bail!("Dreams run did not propose a change");
    };
    let patch = read_patch(store, proposal)?;
    match inspect(store, policy, proposal, &patch).await? {
        Inspection::PatchChanged { .. } => bail!("Dreams patch changed since it was proposed"),
        Inspection::PolicyChanged => bail!("{POLICY_CHANGED}"),
        Inspection::Stale { head } => bail!(
            "Dreams base is stale: target HEAD is {head}, proposal base is {}",
            proposal.base
        ),
        Inspection::TargetDirty => bail!("Dreams target has local changes in touched paths"),
        Inspection::IndexLocked { lock } => bail!(
            "Dreams target has a held Git index lock: {}. Wait for the other Git command, or remove the lock if none is running",
            lock.display()
        ),
        Inspection::Applied {
            commit, recorded, ..
        } => {
            if !recorded {
                store.record_applied(run, &Revision::parse(&commit)?)?;
            }
            Ok(format!(
                "Dreams run {run} is already applied as commit {}; nothing changed.",
                short(&commit)
            ))
        }
        Inspection::Ready { half_applied } => {
            let commit = build_commit(store, policy, proposal, &patch).await?;
            fast_forward(proposal, &commit, &half_applied).await?;
            store.record_applied(run, &Revision::parse(&commit)?)?;
            Ok(format!(
                "Applied Dreams run {run} as commit {} to {}.",
                short(&commit),
                proposal.repository.display()
            ))
        }
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
            let evidence = store.evidence(&run)?;
            let report = RunReport {
                run: &view.id,
                review: &view.review,
                evidence: &evidence,
                outcome: view.outcome.as_ref(),
                outcome_sha256: view.outcome_sha256.as_ref(),
                status: status.as_ref(),
                patch: patch.as_deref(),
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
            let message = apply(
                &store,
                policy.as_ref().context(POLICY_CHANGED)?,
                &RunId::parse(&run)?,
                &ContentDigest::parse(&approve)?,
            )
            .await?;
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
    use std::{fs, path::Path, process::Command};

    use agent_cli::{
        dreams::{
            Dreams, DreamsCheckFile, DreamsFileEdit, DreamsPolicy, DreamsPolicyFile, DreamsRequest,
            DreamsStore, DreamsTaskSummary, ProtectedPaths, RunId,
        },
        protocol::HostResult,
    };
    use tokio::sync::watch;

    use crate::dreams_cli::{
        ProposalStatus, RunReport, apply, apply_command, inspect, read_patch, render, status_of,
    };

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

    #[tokio::test]
    async fn a_proposed_new_file_applies_once_even_after_an_interrupted_apply_left_it_behind() {
        let root = tempfile::tempdir().unwrap();
        let base = root.path().canonicalize().unwrap();
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
        let policy = DreamsPolicy::parse(
            &DreamsPolicyFile {
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
            },
            &ProtectedPaths {
                config: None,
                job_directories: &[],
            },
        )
        .unwrap();
        let dreams = Dreams::open(&state, policy.clone()).unwrap();
        let playbook = "# Build\n\nRun `make test`.\n";
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
                    content: playbook.into(),
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
        let store = DreamsStore::open(&state).unwrap();
        let run = RunId::from_request("night").unwrap();
        let view = store.read(&run).unwrap().unwrap();
        let Some(agent_cli::dreams::Outcome::Proposed(proposal)) = &view.outcome else {
            panic!("The run must hold a proposal");
        };
        let approval = view.outcome_sha256.clone().unwrap();
        let patch = read_patch(&store, proposal).unwrap();
        assert!(matches!(
            inspect(&store, &policy, proposal, &patch)
                .await
                .unwrap()
                .status(),
            ProposalStatus::Pending { interrupted: false }
        ));

        fs::create_dir(repository.join("playbooks")).unwrap();
        fs::write(repository.join("playbooks/build.md"), playbook).unwrap();
        git(&repository, &["add", "playbooks/build.md"]);
        let status = inspect(&store, &policy, proposal, &patch)
            .await
            .unwrap()
            .status();
        assert!(matches!(
            &status,
            ProposalStatus::Pending { interrupted: true }
        ));
        let evidence = store.evidence(&run).unwrap();
        let shown = render(&RunReport {
            run: &view.id,
            review: &view.review,
            evidence: &evidence,
            outcome: view.outcome.as_ref(),
            outcome_sha256: view.outcome_sha256.as_ref(),
            status: Some(&status),
            patch: Some("+new\n"),
            apply: apply_command(&view),
            attempts_used: view.attempts_used,
        });
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

        let message = apply(&store, &policy, &run, &approval).await.unwrap();
        assert!(message.starts_with("Applied Dreams run"), "{message}");
        assert_eq!(git(&repository, &["status", "--porcelain"]), "");
        assert_eq!(
            fs::read_to_string(repository.join("playbooks/build.md")).unwrap(),
            playbook
        );
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);
        let again = apply(&store, &policy, &run, &approval).await.unwrap();
        assert!(again.contains("already applied"), "{again}");
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);

        assert!(
            matches!(
                status_of(&store, None, &view).await.unwrap(),
                Some((
                    ProposalStatus::Applied {
                        reachable: None,
                        ..
                    },
                    _
                ))
            ),
            "A recorded apply stays applied without the policy, and Git is not consulted"
        );
    }

    #[test]
    fn every_status_label_is_the_name_its_json_uses() {
        let digest = agent_cli::dreams::ContentDigest::of(b"example");
        for status in [
            ProposalStatus::Pending { interrupted: false },
            ProposalStatus::Applied {
                commit: "a".repeat(40),
                reachable: Some(true),
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
