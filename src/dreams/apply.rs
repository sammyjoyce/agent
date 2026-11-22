//! Shared Dreams proposal inspection and operator-approved application engine.
//!
//! Used by both the CLI (`beep-boop dreams ...`) and the coordinator service
//! boundary (`src/service.rs`). Never exposed to the Pi model runtime.

use std::{
    fmt, fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use uuid::Uuid;

use crate::dreams::{
    ContentDigest, DreamsPolicy, DreamsStore, FileChange, Outcome, Proposal, ProposedFile,
    Revision, RunId, RunView,
    workspace::{Git, plain_changes},
};

pub const POLICY_CHANGED: &str = "Dreams policy changed since this proposal";

/// Caller- or state-level refusal (maps to `ErrorCode::InvalidRequest` on the wire).
#[derive(Debug)]
pub struct DreamsRejected(pub String);

impl fmt::Display for DreamsRejected {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for DreamsRejected {}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ProposalStatus {
    Pending {
        interrupted: bool,
    },
    Applied {
        commit: String,
        reachable: Reachability,
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
    pub fn kind(&self) -> crate::native::DreamsProposalStatus {
        use crate::native::DreamsProposalStatus as Kind;
        match self {
            Self::Pending { .. } => Kind::Pending,
            Self::Applied { .. } => Kind::Applied,
            Self::Stale { .. } => Kind::Stale,
            Self::TargetDirty => Kind::TargetDirty,
            Self::TargetLocked { .. } => Kind::TargetLocked,
            Self::PatchChanged { .. } => Kind::PatchChanged,
            Self::PolicyChanged => Kind::PolicyChanged,
        }
    }

    pub fn wire_name(&self) -> &'static str {
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

    pub fn is_pending(&self) -> bool {
        matches!(self, Self::Pending { .. })
    }

    pub fn explain(&self) -> String {
        match self {
            Self::Pending { interrupted: false } => {
                "pending (target HEAD is the base and the touched paths are clean)".into()
            }
            Self::Pending { interrupted: true } => {
                "pending (target HEAD is the base; an interrupted apply left proposed content that apply will finish)".into()
            }
            Self::Applied {
                commit,
                reachable: Reachability::Reachable,
            } => format!("applied as commit {commit}"),
            Self::Applied {
                commit,
                reachable: Reachability::Unreachable,
            } => format!("applied as commit {commit}, which is no longer reachable from HEAD"),
            Self::Applied {
                commit,
                reachable: Reachability::NotChecked,
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

    pub fn detail(&self) -> String {
        match self {
            Self::Pending { interrupted: true } => {
                "Previous apply was interrupted before commit; applying will cleanly finish it."
                    .into()
            }
            Self::Pending { interrupted: false } => "Ready for confirmation and apply.".into(),
            Self::Applied {
                commit,
                reachable: Reachability::Reachable,
            } => format!("Applied as commit {}.", short(commit)),
            Self::Applied {
                commit,
                reachable: Reachability::Unreachable,
            } => format!(
                "Applied as commit {} (not an ancestor of current HEAD).",
                short(commit)
            ),
            Self::Applied {
                commit,
                reachable: Reachability::NotChecked,
            } => format!(
                "Applied as commit {} (HEAD not checked because policy no longer names this repository).",
                short(commit)
            ),
            Self::Stale { head } => {
                format!("Repository moved past proposal base (HEAD is {}).", short(head))
            }
            Self::PatchChanged { actual } => {
                format!("Saved patch digest differs from proposal ({actual}).")
            }
            Self::PolicyChanged => {
                "Coordinator Dreams policy is unavailable or changed since this run was sealed."
                    .into()
            }
            Self::TargetDirty => {
                "Target repository has local modifications, mode changes, or symlinks in touched paths."
                    .into()
            }
            Self::TargetLocked { lock } => {
                format!("Target repository index is locked ({}).", lock.display())
            }
        }
    }
}

/// Whether HEAD still contains an applied commit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Reachability {
    Reachable,
    Unreachable,
    /// The policy no longer names the repository, and Git runs only in the policy's.
    NotChecked,
}

impl Serialize for Reachability {
    /// `true`, `false`, or `null` when HEAD was not checked.
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self {
            Self::Reachable => serializer.serialize_bool(true),
            Self::Unreachable => serializer.serialize_bool(false),
            Self::NotChecked => serializer.serialize_none(),
        }
    }
}

/// What shows that a run was applied.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ApplyEvidence {
    /// The record that apply writes after its fast-forward.
    Recorded,
    /// Only the commit trailer in `base..HEAD`, which is what a crash between
    /// the fast-forward and the record leaves.
    TrailerOnly,
}

/// Patch bytes whose digest is the one the sealed proposal names. Only
/// `read_patch` makes one, so apply can give Git nothing else.
struct VerifiedPatch(Vec<u8>);

enum PatchFile {
    Verified(VerifiedPatch),
    Changed {
        actual: ContentDigest,
        bytes: Vec<u8>,
    },
}

impl PatchFile {
    fn bytes(&self) -> &[u8] {
        match self {
            Self::Verified(VerifiedPatch(bytes)) | Self::Changed { bytes, .. } => bytes,
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
        reachable: Reachability,
        evidence: ApplyEvidence,
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
        patch: VerifiedPatch,
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
            Self::Ready { half_applied, .. } => ProposalStatus::Pending {
                interrupted: !half_applied.is_empty(),
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApplyOutcome {
    pub run: String,
    pub commit: String,
    pub repository: PathBuf,
    pub already_applied: bool,
}

pub fn short(commit: &str) -> &str {
    commit.get(..12).unwrap_or(commit)
}

fn read_patch(store: &DreamsStore, proposal: &Proposal) -> Result<PatchFile> {
    let bytes = fs::read(store.patch_path(&proposal.run, proposal.attempt))
        .context("The Dreams patch file is missing")?;
    let actual = ContentDigest::of(&bytes);
    Ok(if actual == proposal.patch_sha256 {
        PatchFile::Verified(VerifiedPatch(bytes))
    } else {
        PatchFile::Changed { actual, bytes }
    })
}

enum PathState {
    AtBase,
    HalfApplied,
    LocallyChanged,
}

/// One line of `git ls-files -s`.
struct IndexEntry {
    mode: String,
    blob: String,
    stage: String,
    path: String,
}

async fn index_entries(git: &Git, path: &str) -> Result<Vec<IndexEntry>> {
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
        entries.push(IndexEntry {
            mode: (*mode).to_owned(),
            blob: (*blob).to_owned(),
            stage: (*stage).to_owned(),
            path: name.to_owned(),
        });
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
            .any(|entry| entry.path == name)
        {
            return Ok(PathState::LocallyChanged);
        }
    }

    let entries: Vec<_> = index_entries(git, &file.path)
        .await?
        .into_iter()
        .filter(|entry| entry.path == file.path)
        .collect();
    let staged = match entries.as_slice() {
        [] => None,
        [entry] if entry.mode == PLAIN_FILE && entry.stage == "0" => Some(entry.blob.clone()),
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
    let is_base = |blob: &Option<String>| blob.as_deref() == file.base_blob();
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
        if contained.exit_code == 0 {
            Reachability::Reachable
        } else {
            Reachability::Unreachable
        }
    } else {
        Reachability::NotChecked
    };
    Ok(Some(Inspection::Applied {
        commit: commit.to_owned(),
        reachable,
        evidence: ApplyEvidence::Recorded,
    }))
}

async fn inspect(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    proposal: &Proposal,
    patch: PatchFile,
) -> Result<Inspection> {
    if let Some(applied) = recorded_apply(store, Some(policy), proposal).await? {
        return Ok(applied);
    }
    let patch = match patch {
        PatchFile::Verified(patch) => patch,
        PatchFile::Changed { actual, .. } => return Ok(Inspection::PatchChanged { actual }),
    };
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
                reachable: Reachability::Reachable,
                evidence: ApplyEvidence::TrailerOnly,
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
    Ok(Inspection::Ready {
        patch,
        half_applied,
    })
}

pub async fn status_of(
    store: &DreamsStore,
    policy: Option<&DreamsPolicy>,
    view: &RunView,
) -> Result<Option<(ProposalStatus, Vec<u8>)>> {
    let Some(Outcome::Proposed(proposal)) = &view.outcome else {
        return Ok(None);
    };
    let patch = read_patch(store, proposal)?;
    let shown = patch.bytes().to_vec();
    let status = match policy {
        Some(policy) => inspect(store, policy, proposal, patch).await?.status(),
        None => recorded_apply(store, None, proposal)
            .await?
            .map_or(ProposalStatus::PolicyChanged, |applied| applied.status()),
    };
    Ok(Some((status, shown)))
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
    patch: &VerifiedPatch,
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
        .run_with_input(&["apply", "--cached", "--whitespace=nowarn"], &patch.0)
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

/// Returns each path that an interrupted apply left at its proposed content
/// to the base, so the fast-forward finds a clean target.
async fn restore_half_applied(proposal: &Proposal, half_applied: &[ProposedFile]) -> Result<()> {
    let git = Git::writing(&proposal.repository);
    for file in half_applied {
        match &file.change {
            FileChange::Changed { .. } => {
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
            FileChange::Added => {
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
    Ok(())
}

async fn fast_forward(proposal: &Proposal, commit: &str) -> Result<()> {
    Git::writing(&proposal.repository)
        .text(&["merge", "--ff-only", "--quiet", commit])
        .await
        .context("The target could not fast-forward to the Dreams commit")?;
    Ok(())
}

pub async fn apply_proposal(
    store: &DreamsStore,
    policy: &DreamsPolicy,
    run: &RunId,
    approval: &ContentDigest,
) -> Result<ApplyOutcome> {
    let view = store
        .read(run)?
        .ok_or_else(|| anyhow::Error::new(DreamsRejected(format!("Unknown Dreams run {run}"))))?;
    if view.outcome_sha256.as_ref() != Some(approval) {
        return Err(anyhow::Error::new(DreamsRejected(
            "Dreams approval does not match the review".into(),
        )));
    }
    let Some(Outcome::Proposed(proposal)) = &view.outcome else {
        return Err(anyhow::Error::new(DreamsRejected(
            "Dreams run did not propose a change".into(),
        )));
    };
    match inspect(store, policy, proposal, read_patch(store, proposal)?).await? {
        Inspection::PatchChanged { .. } => Err(anyhow::Error::new(DreamsRejected(
            "Dreams patch changed since it was proposed".into(),
        ))),
        Inspection::PolicyChanged => Err(anyhow::Error::new(DreamsRejected(POLICY_CHANGED.into()))),
        Inspection::Stale { head } => Err(anyhow::Error::new(DreamsRejected(format!(
            "Dreams base is stale: target HEAD is {head}, proposal base is {}",
            proposal.base
        )))),
        Inspection::TargetDirty => Err(anyhow::Error::new(DreamsRejected(
            "Dreams target has local changes in touched paths".into(),
        ))),
        Inspection::IndexLocked { lock } => Err(anyhow::Error::new(DreamsRejected(format!(
            "Dreams target has a held Git index lock: {}. Wait for the other Git command, or remove the lock if none is running",
            lock.display()
        )))),
        Inspection::Applied {
            commit, evidence, ..
        } => {
            if evidence == ApplyEvidence::TrailerOnly {
                store.record_applied(run, &Revision::parse(&commit)?)?;
            }
            Ok(ApplyOutcome {
                run: run.as_str().to_owned(),
                commit,
                repository: proposal.repository.clone(),
                already_applied: true,
            })
        }
        Inspection::Ready {
            patch,
            half_applied,
        } => {
            let commit = build_commit(store, policy, proposal, &patch).await?;
            restore_half_applied(proposal, &half_applied).await?;
            fast_forward(proposal, &commit).await?;
            store.record_applied(run, &Revision::parse(&commit)?)?;
            Ok(ApplyOutcome {
                run: run.as_str().to_owned(),
                commit,
                repository: proposal.repository.clone(),
                already_applied: false,
            })
        }
    }
}
