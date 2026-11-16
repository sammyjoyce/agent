//! The private run directory. Each record is written once: a review by an
//! atomic directory rename, an attempt by an exclusive create, an outcome by a
//! hard link. A rerun finds what was sealed and never rewrites it.
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, ensure};
use serde::{Serialize, de::DeserializeOwned};
use uuid::Uuid;

use crate::dreams::{ContentDigest, EvidenceItem, MAX_ATTEMPTS, Outcome, Review, RunId};

const STALE_STAGING: Duration = Duration::from_secs(60 * 60);

pub struct DreamsStore {
    root: PathBuf,
}

/// Everything sealed for one run.
pub struct RunView {
    pub id: RunId,
    pub review: Review,
    pub outcome: Option<Outcome>,
    /// sha256 of the exact outcome bytes: what a reviewer approves.
    pub review_sha256: Option<ContentDigest>,
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

pub(crate) fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

pub(crate) fn write_json(path: &Path, value: &impl Serialize) -> Result<()> {
    Ok(write_private(path, &serde_json::to_vec_pretty(value)?)?)
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
        let root = state.join("dreams");
        private_directory(&root)
            .and_then(|()| private_directory(&root.join("runs")))
            .context("Dreams state is unavailable")?;
        Ok(Self { root })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn run_directory(&self, run: &RunId) -> PathBuf {
        self.root.join("runs").join(run.as_str())
    }

    pub fn outcome_path(&self, run: &RunId) -> PathBuf {
        self.run_directory(run).join("outcome.json")
    }

    pub fn attempt_directory(&self, run: &RunId, attempt: u8) -> PathBuf {
        self.run_directory(run)
            .join("attempts")
            .join(attempt.to_string())
    }

    pub fn patch_path(&self, run: &RunId, attempt: u8) -> PathBuf {
        self.attempt_directory(run, attempt).join("patch.diff")
    }

    pub(crate) fn review_directory(&self, run: &RunId) -> PathBuf {
        self.run_directory(run).join("review")
    }

    /// Runs with a sealed review, newest window first.
    pub fn list(&self) -> Result<Vec<RunView>> {
        let mut runs = Vec::new();
        for entry in fs::read_dir(self.root.join("runs"))? {
            let name = entry?.file_name();
            if let Some(run) = name.to_str().and_then(|name| RunId::parse(name).ok())
                && let Some(view) = self.read(&run)?
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
        let Some(review) = read_json::<Review>(&self.review_directory(run).join("review.json"))?
        else {
            return Ok(None);
        };
        ensure!(&review.run == run, "Dreams review belongs to another run");
        let sealed = match fs::read(self.outcome_path(run)) {
            Ok(bytes) => Some(bytes),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error).context("Could not read the Dreams outcome"),
        };
        let outcome = sealed
            .as_deref()
            .map(serde_json::from_slice::<Outcome>)
            .transpose()
            .context("Dreams outcome is unreadable")?;
        let attempts_used = match fs::read_dir(self.run_directory(run).join("attempts")) {
            Ok(entries) => u8::try_from(entries.count()).unwrap_or(u8::MAX),
            Err(error) if error.kind() == io::ErrorKind::NotFound => 0,
            Err(error) => return Err(error).context("Could not read Dreams attempts"),
        };
        Ok(Some(RunView {
            id: run.clone(),
            review,
            outcome,
            review_sha256: sealed.as_deref().map(ContentDigest::of),
            attempts_used,
        }))
    }

    pub fn evidence(&self, run: &RunId) -> Result<Vec<EvidenceItem>> {
        let path = self.review_directory(run).join("evidence.jsonl");
        fs::read_to_string(&path)
            .with_context(|| format!("Could not read Dreams evidence {path:?}"))?
            .lines()
            .map(|line| serde_json::from_str(line).context("Dreams evidence is unreadable"))
            .collect()
    }

    pub(crate) fn files(&self, run: &RunId) -> Result<Vec<(String, String)>> {
        Ok(read_json(&self.review_directory(run).join("files.json"))?.unwrap_or_default())
    }

    /// A private directory to build a review in. Staging left by a crashed
    /// review of this run is removed once it is an hour old.
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
            if stale && entry.file_name().to_string_lossy().starts_with(".review-") {
                fs::remove_dir_all(entry.path())?;
            }
        }
        let staged = directory.join(format!(".review-{}", Uuid::new_v4()));
        private_directory(&staged)?;
        Ok(staged)
    }

    /// Returns false when another review of this run was sealed first; the
    /// staged copy is discarded and the sealed one stands.
    pub(crate) fn seal_review(&self, staged: &Path, run: &RunId) -> Result<bool> {
        let sealed = self.review_directory(run);
        // Renaming onto a directory that already holds a review fails, so the first seal wins.
        let won = match fs::rename(staged, &sealed) {
            Ok(()) => true,
            Err(_) if sealed.join("review.json").exists() => {
                fs::remove_dir_all(staged)?;
                false
            }
            Err(error) => return Err(error).context("Could not seal the Dreams review"),
        };
        File::open(self.run_directory(run))?.sync_all()?;
        Ok(won)
    }

    /// The first free attempt number, or None when every attempt is used. A
    /// crashed attempt keeps its number, so the bound holds across restarts.
    pub(crate) fn allocate_attempt(&self, run: &RunId) -> Result<Option<(u8, PathBuf)>> {
        private_directory(&self.run_directory(run).join("attempts"))?;
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

    /// Seals the run's single outcome and returns whichever outcome is sealed:
    /// this one, or the one that was linked first.
    pub(crate) fn seal_outcome(&self, run: &RunId, outcome: &Outcome) -> Result<Outcome> {
        let directory = self.run_directory(run);
        let temporary = directory.join(format!(".outcome-{}", Uuid::new_v4()));
        write_json(&temporary, outcome)?;
        let linked = fs::hard_link(&temporary, self.outcome_path(run));
        fs::remove_file(&temporary)?;
        match linked {
            Ok(()) => File::open(&directory)?.sync_all()?,
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error).context("Could not seal the Dreams outcome"),
        }
        read_json(&self.outcome_path(run))?.context("The sealed Dreams outcome is missing")
    }
}

#[cfg(test)]
mod tests {
    use std::fs;

    use crate::dreams::{
        Abstention, Coverage, DreamsAbstainReason, Interval, Outcome, ReceiptCoverage, Review,
        Revision, RunId, SummarySnapshot, UntrustedText,
        store::{DreamsStore, write_json},
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
            policy_digest: "example".into(),
            before: vec![],
            findings: vec![],
        }
    }

    fn sealed(store: &DreamsStore, name: &str, end_ms: u64) -> RunId {
        let run = RunId::from_request(name).unwrap();
        let staged = store.stage_review(&run).unwrap();
        write_json(&staged.join("review.json"), &review(&run, end_ms)).unwrap();
        fs::write(staged.join("evidence.jsonl"), "").unwrap();
        assert!(store.seal_review(&staged, &run).unwrap());
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
        write_json(&first.join("review.json"), &review(&run, 10)).unwrap();
        write_json(&second.join("review.json"), &review(&run, 99)).unwrap();
        assert!(store.seal_review(&first, &run).unwrap());
        assert!(!store.seal_review(&second, &run).unwrap());
        assert!(!second.exists(), "The losing staging directory is removed");
        let view = store.read(&run).unwrap().unwrap();
        assert_eq!(view.review.coverage.window.end_ms, 10);
        assert!(view.outcome.is_none() && view.review_sha256.is_none());

        let won = store
            .seal_outcome(&run, &abstained(DreamsAbstainReason::Quiet))
            .unwrap();
        let lost = store
            .seal_outcome(&run, &abstained(DreamsAbstainReason::NoSupportedChange))
            .unwrap();
        assert_eq!(won, abstained(DreamsAbstainReason::Quiet));
        assert_eq!(lost, won, "A later decision returns the sealed one");
        let view = store.read(&run).unwrap().unwrap();
        assert_eq!(view.outcome, Some(won));
        let bytes = fs::read(store.outcome_path(&run)).unwrap();
        assert_eq!(
            view.review_sha256,
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
        fs::create_dir(store.root().join("runs/not-a-run")).unwrap();
        let listed: Vec<RunId> = store
            .list()
            .unwrap()
            .into_iter()
            .map(|view| view.id)
            .collect();
        assert_eq!(listed, vec![newer, older]);
    }
}
