use std::{
    fs,
    path::{Path, PathBuf},
};

use agent_cli::{
    config::ClientConfig,
    dreams::{
        Abstention, CheckResult, ContentDigest, DreamsPolicy, DreamsStore, EvidenceItem,
        MAX_ATTEMPTS, Outcome, Proposal, Review, RunId, RunView, count, format_utc, workspace::Git,
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
    /// Approve the exact review by its digest and apply its patch to the policy repository once.
    Apply {
        run: String,
        /// The review digest printed by `dreams show`.
        #[arg(long, value_name = "sha256:REVIEW_DIGEST")]
        approve: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum ProposalStatus {
    Pending {
        #[serde(skip)]
        half_applied: Vec<TouchedPath>,
    },
    Applied {
        commit: String,
    },
    Stale {
        head: String,
    },
    TargetDirty,
    PatchChanged {
        actual: ContentDigest,
    },
    PolicyChanged,
}

impl ProposalStatus {
    fn explain(&self) -> String {
        match self {
            Self::Pending { half_applied } if half_applied.is_empty() => {
                "pending (target HEAD is the base and the touched paths are clean)".into()
            }
            Self::Pending { .. } => {
                "pending (target HEAD is the base; an interrupted apply left proposed content that apply will finish)".into()
            }
            Self::Applied { commit } => format!("applied as commit {commit}"),
            Self::Stale { head } => format!("stale (target HEAD is {head})"),
            Self::TargetDirty => "target_dirty (local changes in touched paths)".into(),
            Self::PatchChanged { actual } => {
                format!("patch_changed (the patch file now hashes to {actual})")
            }
            Self::PolicyChanged => {
                "policy_changed (the private policy no longer matches this proposal)".into()
            }
        }
    }
}

#[derive(Clone, Debug)]
struct TouchedPath {
    path: String,
    base_blob: Option<String>,
    proposed_blob: String,
}

fn touched_paths(patch: &str) -> Result<Vec<TouchedPath>> {
    let mut touched = Vec::new();
    let mut current: Option<String> = None;
    for line in patch.lines() {
        if let Some(names) = line.strip_prefix("diff --git a/") {
            // `<path> b/<path>`: both halves are the same path, which may itself contain " b/".
            let path = names
                .len()
                .checked_sub(" b/".len())
                .and_then(|length| names.get(..length / 2))
                .filter(|path| names == format!("{path} b/{path}"))
                .context("The Dreams patch renames a file or has an unreadable header")?;
            current = Some(path.to_owned());
        } else if let Some(ids) = line.strip_prefix("index ")
            && let Some(path) = current.take()
        {
            let (base, proposed) = ids
                .split(' ')
                .next()
                .and_then(|ids| ids.split_once(".."))
                .context("The Dreams patch has an unreadable index header")?;
            ensure!(
                proposed.bytes().any(|byte| byte != b'0'),
                "The Dreams patch deletes a file"
            );
            touched.push(TouchedPath {
                path,
                base_blob: base
                    .bytes()
                    .any(|byte| byte != b'0')
                    .then(|| base.to_owned()),
                proposed_blob: proposed.to_owned(),
            });
        }
    }
    ensure!(!touched.is_empty(), "The Dreams patch changes no file");
    Ok(touched)
}

/// The patch file is read once. The digest check and Git both use those bytes,
/// so the file cannot change between the two.
fn read_patch(store: &DreamsStore, proposal: &Proposal) -> Result<Vec<u8>> {
    fs::read(store.patch_path(&proposal.run, proposal.attempt))
        .context("The Dreams patch file is missing")
}

async fn classify(
    policy: Option<&DreamsPolicy>,
    proposal: &Proposal,
    patch: &[u8],
) -> Result<ProposalStatus> {
    let actual = ContentDigest::of(patch);
    if actual != proposal.patch_sha256 {
        return Ok(ProposalStatus::PatchChanged { actual });
    }
    let admitted = policy.is_some_and(|policy| {
        policy.digest() == proposal.policy_digest
            && policy.repository() == proposal.repository
            && proposal
                .files
                .iter()
                .all(|path| policy.editable(path).is_ok())
    });
    if !admitted {
        return Ok(ProposalStatus::PolicyChanged);
    }
    let touched =
        touched_paths(std::str::from_utf8(patch).context("The Dreams patch is not text")?)?;
    ensure!(
        touched.iter().map(|file| &file.path).eq(&proposal.files),
        "The Dreams patch does not touch the files its record names"
    );

    let git = Git::reading(&proposal.repository);
    let base = proposal.base.as_str();
    let head = git.text(&["rev-parse", "--verify", "HEAD"]).await?;
    let head = head.trim();
    let range = format!("{base}..HEAD");
    let history = git
        .run(&[
            "log",
            "--format=%H%x09%(trailers:key=Dreams-Run,valueonly,separator=%x2C)%x09%(trailers:key=Dreams-Patch-Sha256,valueonly,separator=%x2C)",
            &range,
        ])
        .await?;
    if history.exit_code != 0 {
        return Ok(ProposalStatus::Stale { head: head.into() });
    }
    for line in history.stdout.lines() {
        let fields: Vec<&str> = line.split('\t').collect();
        if let [commit, run, patch] = fields.as_slice()
            && *run == proposal.run.as_str()
            && *patch == proposal.patch_sha256.hex()
        {
            return Ok(ProposalStatus::Applied {
                commit: (*commit).to_owned(),
            });
        }
    }
    if head != base {
        return Ok(ProposalStatus::Stale { head: head.into() });
    }

    let mut half_applied = Vec::new();
    for file in touched {
        let staged = git
            .text(&["ls-files", "-s", "-z", "--", &file.path])
            .await?;
        let staged = staged
            .split('\0')
            .next()
            .and_then(|entry| entry.split(' ').nth(1))
            .map(str::to_owned);
        let on_disk = match fs::symlink_metadata(proposal.repository.join(&file.path)) {
            Ok(metadata) if metadata.is_file() => Some(
                git.text(&["hash-object", "--", &file.path])
                    .await?
                    .trim()
                    .to_owned(),
            ),
            Ok(_) => return Ok(ProposalStatus::TargetDirty),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("Could not read a touched path"),
        };
        let proposed = Some(&file.proposed_blob);
        let is_base = |blob: &Option<String>| blob == &file.base_blob;
        let known = |blob: &Option<String>| is_base(blob) || blob.as_ref() == proposed;
        if !known(&staged) || !known(&on_disk) {
            return Ok(ProposalStatus::TargetDirty);
        }
        if !is_base(&staged) || !is_base(&on_disk) {
            half_applied.push(file);
        }
    }
    Ok(ProposalStatus::Pending { half_applied })
}

/// Characters that change how a terminal lays text out without showing as
/// text: bidirectional overrides and isolates, zero-width characters, line and
/// paragraph separators, and the tag block. A reviewer approves what they
/// read, so these must not make the display differ from the bytes.
fn is_format_control(character: char) -> bool {
    matches!(
        character,
        '\u{00ad}'
            | '\u{061c}'
            | '\u{180e}'
            | '\u{200b}'..='\u{200f}'
            | '\u{2028}'..='\u{202e}'
            | '\u{2060}'..='\u{206f}'
            | '\u{feff}'
            | '\u{fff9}'..='\u{fffb}'
            | '\u{e0000}'..='\u{e007f}'
    )
}

/// Shows control and format characters as escapes. Newlines and tabs stay.
fn escape_terminal_controls(text: &str) -> String {
    text.chars()
        .flat_map(|character| match character {
            '\n' | '\t' => vec![character],
            other if other.is_control() || is_format_control(other) => {
                other.escape_unicode().collect()
            }
            other => vec![other],
        })
        .collect()
}

fn quoted(text: &str) -> String {
    escape_terminal_controls(text)
        .lines()
        .map(|line| format!("  > {line}\n"))
        .collect()
}

fn check_line(label: &str, check: &CheckResult) -> String {
    let output: String = [&check.stdout, &check.stderr]
        .into_iter()
        .filter(|output| !output.trim().is_empty())
        .map(|output| quoted(output.trim_end()))
        .collect();
    format!(
        "{label:<11} {}  {}  {:.1}s\n{output}",
        check.name,
        check.verdict(),
        check.duration_ms as f64 / 1000.0
    )
}

#[derive(Serialize)]
struct RunReport<'a> {
    run: &'a RunId,
    review: &'a Review,
    evidence: &'a [EvidenceItem],
    outcome: Option<&'a Outcome>,
    review_sha256: Option<&'a ContentDigest>,
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

/// The status of a proposal with the patch bytes it was derived from.
async fn status_of(
    store: &DreamsStore,
    policy: Option<&DreamsPolicy>,
    view: &RunView,
) -> Result<Option<(ProposalStatus, Vec<u8>)>> {
    match &view.outcome {
        Some(Outcome::Proposed(proposal)) => {
            let patch = read_patch(store, proposal)?;
            Ok(Some((classify(policy, proposal, &patch).await?, patch)))
        }
        _ => Ok(None),
    }
}

fn coverage_word(review: &Review) -> &'static str {
    if review.coverage.complete() {
        "complete"
    } else {
        "incomplete"
    }
}

fn apply_command(view: &RunView) -> Option<String> {
    match (&view.outcome, &view.review_sha256) {
        (Some(Outcome::Proposed(_)), Some(digest)) => Some(format!(
            "beep-boop dreams apply {} --approve {digest}",
            view.id
        )),
        _ => None,
    }
}

fn render(report: &RunReport) -> String {
    let review = report.review;
    let coverage = &review.coverage;
    let hours = (coverage.window.end_ms - coverage.window.start_ms) / (60 * 60 * 1000);
    let mut text = format!(
        "Run         {} (request {})\nWindow      {} to {} ({hours}h)\nReceipts    {}, {}\n",
        report.run,
        escape_terminal_controls(&review.request_id),
        format_utc(coverage.window.start_ms),
        format_utc(coverage.window.end_ms),
        coverage_word(review),
        count(coverage.receipts.items as usize, "receipt"),
    );
    for gap in coverage.gaps() {
        text += &format!("  gap {gap}\n");
    }
    text += &format!(
        "Summaries   {} included (snapshot captured at {}; current retained text, not interval-complete history)\n",
        coverage.summaries.items,
        format_utc(coverage.summaries.captured_at_ms)
    );
    text += &format!(
        "Target      {} at base {} (policy {})\n",
        review.repository.display(),
        review.base,
        review
            .policy_digest
            .get(..12)
            .unwrap_or(&review.policy_digest)
    );
    for check in &review.before {
        text += &check_line("Before", check);
    }
    for finding in &review.findings {
        text += &format!(
            "Finding     {} x{} {}\n",
            finding.kind,
            finding.count,
            escape_terminal_controls(&finding.detail)
        );
    }
    match report.outcome {
        None => {
            text += &format!(
                "Outcome     undecided ({} of {MAX_ATTEMPTS} attempts used)\n",
                report.attempts_used
            );
        }
        Some(Outcome::Abstained(abstention)) => {
            text += &format!(
                "Outcome     {}\n",
                report.outcome.map(Outcome::label).unwrap_or_default()
            );
            if let Abstention::Chosen { note, .. } = abstention
                && !note.as_str().is_empty()
            {
                text += "Note (model-written, untrusted):\n";
                text += &quoted(note.as_str());
            }
        }
        Some(Outcome::Proposed(proposal)) => {
            text += &format!(
                "Outcome     proposed, attempt {} of {MAX_ATTEMPTS}\n",
                proposal.attempt
            );
            for check in &proposal.after {
                text += &check_line("After", check);
            }
            text += &format!(
                "Patch       {}  {}\n",
                proposal.patch_sha256,
                proposal.files.join(", ")
            );
            let evidence: Vec<&str> = proposal.evidence.iter().map(|id| id.as_str()).collect();
            text += &format!("Evidence    {}\n", evidence.join("  "));
            if let Some(status) = report.status {
                text += &format!("Status      {}\n", status.explain());
            }
            if let Some(digest) = report.review_sha256 {
                text += &format!("Review      {digest}\n");
            }
            text += "Rationale (model-written, untrusted):\n";
            text += &quoted(proposal.rationale.as_str());
            text += "--- patch ---\n";
            text += &escape_terminal_controls(report.patch.unwrap_or_default());
            text += "--- end of patch ---\n";
            if let Some(command) = &report.apply {
                text += &format!("Approve this exact review and apply it once:\n  {command}\n");
            }
        }
    }
    text
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

async fn fast_forward(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    proposal: &Proposal,
    patch: &[u8],
    half_applied: &[TouchedPath],
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
    let mut fields = changed.split('\0').filter(|field| !field.is_empty());
    let mut files = Vec::new();
    while let (Some(change), Some(path)) = (fields.next(), fields.next()) {
        let parts: Vec<&str> = change.split(' ').collect();
        ensure!(
            matches!(
                parts.as_slice(),
                [":100644" | ":000000", "100644", _, _, "M" | "A"]
            ) && policy.editable(path).is_ok(),
            "The approved patch changes more than the contents of editable files"
        );
        files.push(path);
    }
    ensure!(
        files.iter().eq(&proposal.files),
        "The approved patch does not change the files its record names"
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
    let commit = commit.trim();

    for file in half_applied {
        match &file.base_blob {
            Some(_) => {
                let source = format!("--source={base}");
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
    Ok(commit.to_owned())
}

fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

async fn apply(
    store: &DreamsStore,
    policy: Option<&DreamsPolicy>,
    run: &RunId,
    approval: &ContentDigest,
) -> Result<String> {
    let view = store
        .read(run)?
        .with_context(|| format!("Unknown Dreams run {run}"))?;
    ensure!(
        view.review_sha256.as_ref() == Some(approval),
        "Dreams approval does not match the review"
    );
    let Some(Outcome::Proposed(proposal)) = &view.outcome else {
        bail!("Dreams run did not propose a change");
    };
    let patch = read_patch(store, proposal)?;
    match classify(policy, proposal, &patch).await? {
        ProposalStatus::PatchChanged { .. } => bail!("Dreams patch changed since it was proposed"),
        ProposalStatus::PolicyChanged => bail!("Dreams policy changed since this proposal"),
        ProposalStatus::Stale { head } => bail!(
            "Dreams base is stale: target HEAD is {head}, proposal base is {}",
            proposal.base
        ),
        ProposalStatus::TargetDirty => bail!("Dreams target has local changes in touched paths"),
        ProposalStatus::Applied { commit } => Ok(format!(
            "Dreams run {run} is already applied as commit {}; nothing changed.",
            short(&commit)
        )),
        ProposalStatus::Pending { half_applied } => {
            let policy = policy.context("Dreams policy changed since this proposal")?;
            let commit = fast_forward(store, policy, proposal, &patch, &half_applied).await?;
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
                    let status = serde_json::to_value(&run.status)?;
                    println!(
                        "{:<17} {:<24} {:<11} {:<33} {}",
                        run.run,
                        format_utc(run.window_end_ms),
                        run.coverage,
                        run.outcome,
                        status["state"].as_str().unwrap_or("-")
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
                review_sha256: view.review_sha256.as_ref(),
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
                policy.as_ref(),
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
        ProposalStatus, RunReport, apply, apply_command, classify, escape_terminal_controls,
        read_patch, render, touched_paths,
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
        let approval = view.review_sha256.clone().unwrap();
        assert!(matches!(
            classify(Some(&policy), proposal, &read_patch(&store, proposal).unwrap()).await.unwrap(),
            ProposalStatus::Pending { half_applied } if half_applied.is_empty()
        ));

        fs::create_dir(repository.join("playbooks")).unwrap();
        fs::write(repository.join("playbooks/build.md"), playbook).unwrap();
        git(&repository, &["add", "playbooks/build.md"]);
        let status = classify(
            Some(&policy),
            proposal,
            &read_patch(&store, proposal).unwrap(),
        )
        .await
        .unwrap();
        assert!(
            matches!(&status, ProposalStatus::Pending { half_applied } if half_applied.len() == 1)
        );
        let evidence = store.evidence(&run).unwrap();
        let shown = render(&RunReport {
            run: &view.id,
            review: &view.review,
            evidence: &evidence,
            outcome: view.outcome.as_ref(),
            review_sha256: view.review_sha256.as_ref(),
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
            shown.contains("  > Add\\u{1b}[2K the missing playbook."),
            "{shown}"
        );

        let message = apply(&store, Some(&policy), &run, &approval).await.unwrap();
        assert!(message.starts_with("Applied Dreams run"), "{message}");
        assert_eq!(git(&repository, &["status", "--porcelain"]), "");
        assert_eq!(
            fs::read_to_string(repository.join("playbooks/build.md")).unwrap(),
            playbook
        );
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);
        let again = apply(&store, Some(&policy), &run, &approval).await.unwrap();
        assert!(again.contains("already applied"), "{again}");
        assert_eq!(git(&repository, &["rev-parse", "HEAD~1"]), head);

        assert!(
            matches!(
                classify(None, proposal, &read_patch(&store, proposal).unwrap())
                    .await
                    .unwrap(),
                ProposalStatus::PolicyChanged
            ),
            "Without the private policy, nothing is admitted"
        );
    }

    #[test]
    fn patch_headers_name_each_touched_path_with_both_blob_ids() {
        let (old, new) = ("1".repeat(40), "2".repeat(40));
        let patch = format!(
            "diff --git a/AGENTS.md b/AGENTS.md\nindex {old}..{new} 100644\n--- a/AGENTS.md\n+++ b/AGENTS.md\n@@ -1 +1 @@\n-index 0..0\n+diff --git a/x b/y\ndiff --git a/playbooks/new.md b/playbooks/new.md\nnew file mode 100644\nindex {}..{new}\n",
            "0".repeat(40)
        );
        let touched = touched_paths(&patch).unwrap();
        assert_eq!(touched.len(), 2);
        assert_eq!(touched[0].path, "AGENTS.md");
        assert_eq!(touched[0].base_blob.as_deref(), Some(old.as_str()));
        assert_eq!(touched[0].proposed_blob, new);
        assert_eq!(touched[1].path, "playbooks/new.md");
        assert_eq!(touched[1].base_blob, None);

        for refused in [
            String::new(),
            format!("diff --git a/a.md b/b.md\nindex {old}..{new} 100644\n"),
            format!(
                "diff --git a/a.md b/a.md\nindex {old}..{} 100644\n",
                "0".repeat(40)
            ),
        ] {
            assert!(touched_paths(&refused).is_err(), "{refused:?}");
        }
    }

    #[test]
    fn terminal_control_sequences_in_reviewed_text_are_shown_not_obeyed() {
        let shown = escape_terminal_controls("+safe\u{1b}[2K\r+hidden\n\tkept");
        assert!(!shown.contains('\u{1b}') && !shown.contains('\r'));
        assert!(shown.contains("\\u{1b}[2K\\u{d}+hidden\n\tkept"));
        assert_eq!(
            escape_terminal_controls("a\u{202e}b\u{200b}c\u{2066}d\u{feff}e\u{2029}f\u{e0041}g"),
            "a\\u{202e}b\\u{200b}c\\u{2066}d\\u{feff}e\\u{2029}f\\u{e0041}g"
        );
    }
}
