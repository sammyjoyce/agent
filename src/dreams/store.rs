use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use uuid::Uuid;

use crate::dreams::{
    CheckResult, ContentDigest, EvidenceItem, MAX_ATTEMPTS, Outcome, Review, Revision, RunId,
    SealedOutcome,
};

const STALE_STAGING: Duration = Duration::from_secs(60 * 60);

pub(crate) const DREAMS_DIRECTORY: &str = "dreams";
const RUNS_DIRECTORY: &str = "runs";
const REVIEW_DIRECTORY: &str = "review";
const REVIEW_STAGING_PREFIX: &str = ".review-";
const REVIEW_FILE: &str = "review.json";
const EVIDENCE_FILE: &str = "evidence.jsonl";
const FILES_FILE: &str = "files.json";
const BASE_CLONE: &str = "base";
const CHECK_FREE_CLONE: &str = "files";
const ATTEMPTS_DIRECTORY: &str = "attempts";
const CANDIDATE_CLONE: &str = "candidate";
const PATCH_FILE: &str = "patch.diff";
const AFTER_FILE: &str = "after.json";
const VERDICT_FILE: &str = "verdict.json";
const OUTCOME_FILE: &str = "outcome.json";
const APPLIED_FILE: &str = "applied.json";
const APPLY_LOCK_FILE: &str = "apply.lock";

pub(crate) enum Verdict<'a> {
    Accepted,
    Rejected { reason: &'a str },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ReviewSeal {
    Sealed,
    AlreadySealed,
}

pub struct DreamsStore {
    root: PathBuf,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppliedRecord {
    pub commit: Revision,
}

pub struct RunView {
    pub id: RunId,
    pub review: Review,
    pub evidence: Vec<EvidenceItem>,
    pub review_sha256: ContentDigest,
    pub outcome: Option<Outcome>,
    pub outcome_sha256: Option<ContentDigest>,
    pub attempts_used: u8,
}

fn private_directory(path: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            if fs::symlink_metadata(path)?.is_dir() {
                Ok(())
            } else {
                Err(io::Error::other(format!(
                    "Dreams state {path:?} is not a directory"
                )))
            }
        }
        Err(error) => Err(error),
    }
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    Ok(write_private(path, &serde_json::to_vec_pretty(value)?)?)
}

fn review_digest(review: &[u8], evidence: &[u8]) -> Result<ContentDigest> {
    let mut sealed = u64::try_from(review.len())?.to_be_bytes().to_vec();
    sealed.extend(review);
    sealed.extend(evidence);
    Ok(ContentDigest::of(&sealed))
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Result<Option<T>> {
    match fs::read(path) {
        Ok(bytes) => {
            Ok(Some(serde_json::from_slice(&bytes).with_context(|| {
                format!("Dreams record {path:?} is unreadable")
            })?))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("Could not read Dreams record {path:?}")),
    }
}

impl DreamsStore {
    pub fn open(state: &Path) -> Result<Self> {
        let root = state.join(DREAMS_DIRECTORY);
        private_directory(&root)
            .and_then(|()| private_directory(&root.join(RUNS_DIRECTORY)))
            .context("Dreams state is unavailable")?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn run_directory(&self, run: &RunId) -> PathBuf {
        self.root.join(RUNS_DIRECTORY).join(run.as_str())
    }

    pub fn outcome_path(&self, run: &RunId) -> PathBuf {
        self.run_directory(run).join(OUTCOME_FILE)
    }

    pub fn attempt_directory(&self, run: &RunId, attempt: u8) -> PathBuf {
        self.run_directory(run)
            .join(ATTEMPTS_DIRECTORY)
            .join(attempt.to_string())
    }

    pub fn patch_path(&self, run: &RunId, attempt: u8) -> PathBuf {
        self.attempt_directory(run, attempt).join(PATCH_FILE)
    }

    pub(crate) fn review_directory(&self, run: &RunId) -> PathBuf {
        self.run_directory(run).join(REVIEW_DIRECTORY)
    }

    /// Runs with a sealed review, newest window first.
    pub fn list(&self) -> Result<Vec<RunView>> {
        let mut runs = Vec::new();
        for entry in fs::read_dir(self.root.join(RUNS_DIRECTORY))? {
            let name = entry?.file_name();
            if let Some(run) = name.to_str().and_then(|name| RunId::parse(name).ok())
                && let Some(view) = self
                    .read(&run)
                    .with_context(|| format!("Dreams run {run} is unreadable"))?
            {
                runs.push(view);
            }
        }
        runs.sort_by(|left, right| {
            right
                .review
                .coverage
                .window
                .end_ms
                .cmp(&left.review.coverage.window.end_ms)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(runs)
    }

    pub fn read(&self, run: &RunId) -> Result<Option<RunView>> {
        let directory = self.review_directory(run);
        let review = match fs::read(directory.join(REVIEW_FILE)) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error).context("Could not read the sealed Dreams review"),
        };
        let evidence =
            fs::read(directory.join(EVIDENCE_FILE)).context("Could not read Dreams evidence")?;
        let review_sha256 = review_digest(&review, &evidence)?;
        let sealed = match fs::read(self.outcome_path(run)) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("Could not read the Dreams outcome"),
        };
        let outcome = sealed
            .as_deref()
            .map(serde_json::from_slice::<SealedOutcome>)
            .transpose()
            .context("Dreams outcome is unreadable")?;
        if let Some(outcome) = &outcome {
            ensure!(
                review_sha256 == outcome.review_sha256,
                "Dreams review changed since it was sealed"
            );
        }
        let review: Review =
            serde_json::from_slice(&review).context("Dreams review is unreadable")?;
        ensure!(&review.run == run, "Dreams review belongs to another run");
        let evidence = std::str::from_utf8(&evidence)
            .context("Dreams evidence is unreadable")?
            .lines()
            .map(|line| serde_json::from_str(line).context("Dreams evidence is unreadable"))
            .collect::<Result<_>>()?;
        let attempts_used = match fs::read_dir(self.run_directory(run).join(ATTEMPTS_DIRECTORY)) {
            Ok(entries) => u8::try_from(entries.count()).unwrap_or(u8::MAX),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error).context("Could not read Dreams attempts"),
        };
        Ok(Some(RunView {
            id: run.clone(),
            review,
            evidence,
            review_sha256,
            outcome: outcome.map(|sealed| sealed.outcome),
            outcome_sha256: sealed.as_deref().map(ContentDigest::of),
            attempts_used,
        }))
    }

    pub(crate) fn files(&self, run: &RunId) -> Result<Vec<(String, String)>> {
        Ok(read_json(&self.review_directory(run).join(FILES_FILE))?.unwrap_or_default())
    }

    pub(crate) fn stage_review(&self, run: &RunId) -> Result<PathBuf> {
        let directory = self.run_directory(run);
        private_directory(&directory)?;
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let stale = entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .is_ok_and(|modified| {
                    SystemTime::now()
                        .duration_since(modified)
                        .is_ok_and(|age| age > STALE_STAGING)
                });
            if stale
                && entry
                    .file_name()
                    .to_string_lossy()
                    .starts_with(REVIEW_STAGING_PREFIX)
            {
                fs::remove_dir_all(entry.path())?;
            }
        }
        let staged = directory.join(format!("{REVIEW_STAGING_PREFIX}{}", Uuid::new_v4()));
        private_directory(&staged)?;
        Ok(staged)
    }

    pub(crate) fn base_clone(staged: &Path) -> PathBuf {
        staged.join(BASE_CLONE)
    }

    pub(crate) fn check_free_clone(staged: &Path) -> PathBuf {
        staged.join(CHECK_FREE_CLONE)
    }

    pub(crate) fn write_review(
        staged: &Path,
        review: &Review,
        evidence: &[EvidenceItem],
        files: &[(String, String)],
    ) -> Result<()> {
        let mut lines = String::new();
        for item in evidence {
            lines.push_str(&serde_json::to_string(item)?);
            lines.push('\n');
        }
        write_json(&staged.join(FILES_FILE), &files)?;
        write_private(&staged.join(EVIDENCE_FILE), lines.as_bytes())?;
        write_json(&staged.join(REVIEW_FILE), review)
    }

    pub(crate) fn seal_review(&self, staged: &Path, run: &RunId) -> Result<ReviewSeal> {
        let sealed = self.review_directory(run);
        // Renaming onto a directory that already holds a review fails, so the first seal wins.
        let seal = match fs::rename(staged, &sealed) {
            Ok(()) => ReviewSeal::Sealed,
            Err(_) if sealed.join(REVIEW_FILE).exists() => {
                fs::remove_dir_all(staged)?;
                ReviewSeal::AlreadySealed
            }
            Err(error) => return Err(error).context("Could not seal the Dreams review"),
        };
        File::open(self.run_directory(run))?.sync_all()?;
        Ok(seal)
    }

    pub(crate) fn candidate_clone(attempt: &Path) -> PathBuf {
        attempt.join(CANDIDATE_CLONE)
    }

    pub(crate) fn write_patch(attempt: &Path, patch: &[u8]) -> Result<()> {
        Ok(write_private(&attempt.join(PATCH_FILE), patch)?)
    }

    pub(crate) fn write_after(attempt: &Path, after: &[CheckResult]) -> Result<()> {
        write_json(&attempt.join(AFTER_FILE), &after)
    }

    pub(crate) fn write_verdict(attempt: &Path, verdict: Verdict<'_>) -> Result<()> {
        write_json(
            &attempt.join(VERDICT_FILE),
            &match verdict {
                Verdict::Rejected { reason } => {
                    serde_json::json!({ "accepted": false, "reason": reason })
                }
                Verdict::Accepted => serde_json::json!({ "accepted": true }),
            },
        )
    }

    pub(crate) fn allocate_attempt(&self, run: &RunId) -> Result<Option<(u8, PathBuf)>> {
        private_directory(&self.run_directory(run).join(ATTEMPTS_DIRECTORY))?;
        for attempt in 1..=MAX_ATTEMPTS {
            let directory = self.attempt_directory(run, attempt);
            match fs::DirBuilder::new().mode(0o700).create(&directory) {
                Ok(()) => return Ok(Some((attempt, directory))),
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(error) => return Err(error).context("Could not start a Dreams attempt"),
            }
        }
        Ok(None)
    }

    pub(crate) fn seal_outcome(&self, view: &RunView, outcome: &Outcome) -> Result<Outcome> {
        let sealed = SealedOutcome {
            review_sha256: view.review_sha256.clone(),
            outcome: outcome.clone(),
        };
        self.seal_once(&view.id, OUTCOME_FILE, &sealed)
            .map(|sealed| sealed.outcome)
            .context("Could not seal the Dreams outcome")
    }

    pub(crate) fn apply_lock_file(&self) -> Result<File> {
        OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.root.join(APPLY_LOCK_FILE))
            .context("Could not open the Dreams apply lock")
    }

    pub fn applied(&self, run: &RunId) -> Result<Option<AppliedRecord>> {
        read_json(&self.run_directory(run).join(APPLIED_FILE))
    }

    /// Records a finished apply. The first record stands, so a repeat returns it.
    pub fn record_applied(&self, run: &RunId, commit: &Revision) -> Result<AppliedRecord> {
        self.seal_once(
            run,
            APPLIED_FILE,
            &AppliedRecord {
                commit: commit.clone(),
            },
        )
        .context("Could not record the Dreams apply")
    }

    fn seal_once<T: Serialize + DeserializeOwned>(
        &self,
        run: &RunId,
        name: &str,
        value: &T,
    ) -> Result<T> {
        let directory = self.run_directory(run);
        let sealed = directory.join(name);
        let temporary = directory.join(format!(".{name}-{}", Uuid::new_v4()));
        write_json(&temporary, value)?;
        let linked = fs::hard_link(&temporary, &sealed);
        fs::remove_file(&temporary)?;
        match linked {
            Ok(()) => File::open(&directory)?.sync_all()?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error.into()),
        }
        read_json(&sealed)?.with_context(|| format!("The sealed Dreams record {name} is missing"))
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use crate::dreams::{
        Abstention, Coverage, DreamsAbstainReason, Interval, Outcome, PolicyDigest,
        ReceiptCoverage, Review, Revision, RunId, SummarySnapshot, UntrustedText,
        store::{DreamsStore, RUNS_DIRECTORY, ReviewSeal},
    };

    fn review(run: &RunId, end_ms: u64) -> Review {
        Review {
            run: run.clone(),
            request_id: "example-request".into(),
            coverage: Coverage {
                window: Interval {
                    start_ms: 0,
                    end_ms,
                },
                receipts: ReceiptCoverage {
                    covered: vec![],
                    gaps: vec![],
                    items: 0,
                },
                summaries: SummarySnapshot {
                    captured_at_ms: end_ms,
                    gaps: vec![],
                    items: 0,
                },
            },
            repository: "/example/guidance".into(),
            base: Revision::parse(&"a".repeat(40)).unwrap(),
            policy_digest: PolicyDigest::of(b"example"),
            before: vec![],
            findings: vec![],
        }
    }

    fn sealed(store: &DreamsStore, name: &str, end_ms: u64) -> RunId {
        let run = RunId::from_request(name).unwrap();
        let staged = store.stage_review(&run).unwrap();
        DreamsStore::write_review(&staged, &review(&run, end_ms), &[], &[]).unwrap();
        assert_eq!(
            store.seal_review(&staged, &run).unwrap(),
            ReviewSeal::Sealed
        );
        run
    }

    fn abstained(reason: DreamsAbstainReason) -> Outcome {
        Outcome::Abstained(Abstention::Chosen {
            reason,
            note: UntrustedText::bounded("Example note.", 100),
        })
    }

    #[test]
    fn the_first_review_and_the_first_outcome_of_a_run_are_the_only_ones() {
        let state = tempfile::tempdir().unwrap();
        let store = DreamsStore::open(state.path()).unwrap();
        let run = RunId::from_request("example-request").unwrap();
        assert!(store.read(&run).unwrap().is_none());

        let first = store.stage_review(&run).unwrap();
        let second = store.stage_review(&run).unwrap();
        DreamsStore::write_review(&first, &review(&run, 10), &[], &[]).unwrap();
        DreamsStore::write_review(&second, &review(&run, 99), &[], &[]).unwrap();
        assert_eq!(store.seal_review(&first, &run).unwrap(), ReviewSeal::Sealed);
        assert_eq!(
            store.seal_review(&second, &run).unwrap(),
            ReviewSeal::AlreadySealed
        );
        assert!(!second.exists(), "The losing staging directory is removed");
        let view = store.read(&run).unwrap().unwrap();
        assert_eq!(view.review.coverage.window.end_ms, 10);
        assert!(view.outcome.is_none() && view.outcome_sha256.is_none());

        let won = store
            .seal_outcome(&view, &abstained(DreamsAbstainReason::Quiet))
            .unwrap();
        let lost = store
            .seal_outcome(&view, &abstained(DreamsAbstainReason::NoSupportedChange))
            .unwrap();
        assert_eq!(won, abstained(DreamsAbstainReason::Quiet));
        assert_eq!(lost, won, "A later decision returns the sealed one");
        let view = store.read(&run).unwrap().unwrap();
        assert_eq!(view.outcome, Some(won));
        let bytes = fs::read(store.outcome_path(&run)).unwrap();
        assert_eq!(
            view.outcome_sha256,
            Some(crate::dreams::ContentDigest::of(&bytes))
        );
        let leftovers: Vec<_> = fs::read_dir(store.run_directory(&run))
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name.to_string_lossy().starts_with('.'))
            .collect();
        assert!(leftovers.is_empty(), "{leftovers:?}");
    }

    #[test]
    fn attempts_are_bounded_even_when_one_never_finished() {
        let state = tempfile::tempdir().unwrap();
        let store = DreamsStore::open(state.path()).unwrap();
        let run = sealed(&store, "example-request", 10);
        let numbers: Vec<Option<u8>> = (0..4)
            .map(|_| {
                store
                    .allocate_attempt(&run)
                    .unwrap()
                    .map(|(attempt, _)| attempt)
            })
            .collect();
        assert_eq!(numbers, vec![Some(1), Some(2), Some(3), None]);
        assert_eq!(store.read(&run).unwrap().unwrap().attempts_used, 3);
    }

    #[test]
    fn list_shows_sealed_runs_newest_first_and_ignores_unsealed_staging() {
        let state = tempfile::tempdir().unwrap();
        let store = DreamsStore::open(state.path()).unwrap();
        let older = sealed(&store, "older", 10);
        let newer = sealed(&store, "newer", 20);
        store
            .stage_review(&RunId::from_request("crashed").unwrap())
            .unwrap();
        fs::create_dir(store.root().join(RUNS_DIRECTORY).join("not-a-run")).unwrap();
        let listed: Vec<RunId> = store
            .list()
            .unwrap()
            .into_iter()
            .map(|view| view.id)
            .collect();
        assert_eq!(listed, vec![newer, older]);
    }
}
