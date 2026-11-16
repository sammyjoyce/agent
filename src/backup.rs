use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::{CString, OsString},
    fmt,
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use ts_rs::TS;
use uuid::Uuid;

use crate::{
    attachments::AttachmentRef,
    coordinator_id::CoordinatorId,
    dreams::DREAMS_DIRECTORY,
    protocol::RuntimeCommand,
    runtime::{WriterLock, diagnostics::UNRECORDED_START_STAMP},
};

const MANIFEST: &str = "manifest.json";
const ARCHIVE_DATA: &str = "data";
const RESTORE_HOLD_FILE: &str = "restore-hold.json";
const FORMAT: u32 = 1;
const MAX_MANIFEST_BYTES: u64 = 64 * 1024 * 1024;

pub fn create(state: &Path, destination: &Path, runtime: &Path) -> Result<Created> {
    existing_private_directory(state)?;
    ensure!(
        absent(destination)?,
        "{} already exists",
        destination.display()
    );
    let (parent, name) = parent_and_name(destination)?;
    ensure!(
        !inside(&parent, state)?,
        "The backup destination must be outside the state directory"
    );
    let helper = DatabaseHelper::locate(runtime)?;
    let _lock = WriterLock::acquire(state)?;
    let coordinator_id = CoordinatorId::read(state)?.context(
        "The state directory has no coordinator-id; back up a store that a coordinator created",
    )?;
    let inventory = Inventory::scan(state)?;
    ensure!(
        inventory.files.contains_key(&StateFile::Database),
        "The state directory has no session.sqlite"
    );
    let staging = Staging::create(
        &parent,
        format!(".{name}.partial-{}", Uuid::new_v4()),
        directories(
            inventory
                .files
                .keys()
                .map(|file| Path::new(ARCHIVE_DATA).join(file.relative_path())),
        ),
    )?;
    let data = staging.root().join(ARCHIVE_DATA);
    let mut records = Vec::with_capacity(inventory.files.len());
    for (file, promise) in &inventory.files {
        if *file == StateFile::Database {
            continue;
        }
        let written = copy_hashed(
            &state.join(file.relative_path()),
            &data.join(file.relative_path()),
            *promise,
        )?;
        records.push(FileRecord::new(file.clone(), written));
    }
    let snapshot = data.join(StateFile::Database.relative_path());
    let database = helper
        .run(&DatabaseRequest::Snapshot {
            source: state.join(StateFile::Database.relative_path()),
            snapshot: snapshot.clone(),
        })?
        .verified(&snapshot)?;
    records.push(FileRecord::new(
        StateFile::Database,
        seal_database(&snapshot)?,
    ));
    let manifest = Manifest::new(coordinator_id, database, records)?;
    write_private(
        &staging.root().join(MANIFEST),
        &serde_json::to_vec_pretty(&manifest)?,
    )?;
    staging.publish(destination, Existing::Nothing)?;
    Ok(Created {
        coordinator_id,
        archive: std::path::absolute(destination)?,
        files: manifest.files.len(),
        bytes: manifest.bytes(),
        not_included: inventory.not_included,
    })
}

/// Rebuild a state directory at `target` from `archive`, held until `release`.
pub fn restore(archive: &Path, target: &Path, runtime: &Path) -> Result<Restored> {
    let existing = restore_target(target)?;
    let (parent, name) = parent_and_name(target)?;
    let manifest = Manifest::read(archive)?;
    ensure!(
        !inside(&parent, archive)?,
        "The restore target must be outside the backup"
    );
    let helper = DatabaseHelper::locate(runtime)?;
    let data = archive.join(ARCHIVE_DATA).canonicalize().with_context(|| {
        format!(
            "{} is not a complete backup: data is missing",
            archive.display()
        )
    })?;
    let staging = Staging::create(
        &parent,
        format!(".{name}.restore-{}", Uuid::new_v4()),
        directories(
            manifest
                .files
                .iter()
                .map(|record| record.path.relative_path()),
        ),
    )?;
    for record in &manifest.files {
        copy_hashed(
            &archived_file(&data, &record.path)?,
            &staging.root().join(record.path.relative_path()),
            Some(record.promise()),
        )?;
    }
    let database = staging.root().join(StateFile::Database.relative_path());
    let verified = helper
        .run(&DatabaseRequest::Inspect {
            database: database.clone(),
        })?
        .verified(&database)?;
    ensure!(
        verified.schema_version <= verified.supported_schema_version,
        "The backup's database schema {} is newer than this build supports ({}); restore it with a newer Beep Boop",
        verified.schema_version,
        verified.supported_schema_version
    );
    ensure!(
        verified.schema_version == manifest.sqlite_schema_version,
        "The database schema {} differs from the manifest's {}",
        verified.schema_version,
        manifest.sqlite_schema_version
    );
    let restored = CoordinatorId::read(staging.root())?
        .context("coordinator-id is missing from the backup")?;
    ensure!(
        restored == manifest.coordinator_id,
        "coordinator-id {restored} differs from the manifest's {}",
        manifest.coordinator_id
    );
    let target = std::path::absolute(target)?;
    write_private(
        &staging.root().join(RESTORE_HOLD_FILE),
        &serde_json::to_vec_pretty(&RestoreHold {
            coordinator_id: restored,
            archive: std::path::absolute(archive)?,
            archive_created_at_ms: manifest.created_at_ms,
            restored_at_ms: now_ms()?,
        })?,
    )?;
    staging.publish(&target, existing)?;
    Ok(Restored {
        coordinator_id: restored,
        hold: hold_notice(&target),
        state_dir: target,
        files: manifest.files.len(),
        bytes: manifest.bytes(),
    })
}

/// Let background work run again in a restored store. Releasing a store
/// without a hold succeeds.
pub fn release(state: &Path) -> Result<Released> {
    existing_private_directory(state)?;
    let _lock = WriterLock::acquire(state)?;
    let state_dir = std::path::absolute(state)?;
    match fs::remove_file(state.join(RESTORE_HOLD_FILE)) {
        Ok(()) => {
            sync_directory(state)?;
            Ok(Released {
                state_dir,
                was_held: true,
            })
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Released {
            state_dir,
            was_held: false,
        }),
        Err(error) => Err(error).context("Could not remove the restore hold"),
    }
}

/// Whether a restored store still waits for `backup release`. The writer lock
/// keeps `release` from changing the answer while the caller acts on it.
/// Anything at the name, or an unreadable name, is a hold.
pub fn restore_held(_owner: &WriterLock, state: &Path) -> bool {
    !matches!(
        fs::symlink_metadata(state.join(RESTORE_HOLD_FILE)),
        Err(error) if error.kind() == io::ErrorKind::NotFound
    )
}

pub fn hold_notice(state: &Path) -> String {
    format!(
        "Background work, task turns, automatic worktree collection and phone notifications are held after a restore until `beep-boop --state-dir {} backup release`.",
        state.display()
    )
}

/// The refusal a held store gives a request that waits for `backup release`.
pub fn held_after_restore(command: &RuntimeCommand) -> Option<&'static str> {
    match command {
        RuntimeCommand::RunTask { .. } => {
            Some("Task workers are held after a restore until `backup release`")
        }
        RuntimeCommand::CollectResources { .. } => {
            Some("Worktree collection is held after a restore until `backup release`")
        }
        RuntimeCommand::RunBackground { .. } => {
            Some("Background work is held after a restore until `backup release`")
        }
        RuntimeCommand::Login
        | RuntimeCommand::Chat { .. }
        | RuntimeCommand::AttachMain
        | RuntimeCommand::ObserveMain { .. }
        | RuntimeCommand::AttachConversation { .. }
        | RuntimeCommand::ConfigureCoordinator { .. }
        | RuntimeCommand::RegisterNode { .. }
        | RuntimeCommand::SetConnectedNodes { .. }
        | RuntimeCommand::OAuthCallback { .. }
        | RuntimeCommand::WorkerInput { .. }
        | RuntimeCommand::SubmitInput { .. }
        | RuntimeCommand::DetachWorker
        | RuntimeCommand::DetachMain
        | RuntimeCommand::DetachConversation
        | RuntimeCommand::Interrupt
        | RuntimeCommand::HostReply { .. }
        | RuntimeCommand::Watch
        | RuntimeCommand::ConnectWorker { .. }
        | RuntimeCommand::Native { .. }
        | RuntimeCommand::ConversationUsage { .. }
        | RuntimeCommand::Attachment { .. }
        | RuntimeCommand::SyncJobs { .. }
        | RuntimeCommand::JobStatus
        | RuntimeCommand::ListJobs
        | RuntimeCommand::ReadJob { .. }
        | RuntimeCommand::RetryJob { .. }
        | RuntimeCommand::RunJob { .. }
        | RuntimeCommand::Environment { .. }
        | RuntimeCommand::SourceStates
        | RuntimeCommand::IngestSource { .. }
        | RuntimeCommand::TriageSources { .. }
        | RuntimeCommand::Status
        | RuntimeCommand::Usage { .. }
        | RuntimeCommand::MainInput { .. }
        | RuntimeCommand::MainInterrupt
        | RuntimeCommand::MainFeedback { .. }
        | RuntimeCommand::ConversationSettings { .. }
        | RuntimeCommand::Goal { .. }
        | RuntimeCommand::Logout
        | RuntimeCommand::SearchTasks { .. }
        | RuntimeCommand::ListTasks
        | RuntimeCommand::ReadTaskGraph
        | RuntimeCommand::ListConversations { .. }
        | RuntimeCommand::ConversationInput { .. }
        | RuntimeCommand::ConversationInterrupt { .. }
        | RuntimeCommand::ListResources
        | RuntimeCommand::ReadTask { .. }
        | RuntimeCommand::ReadHistory { .. }
        | RuntimeCommand::ReadToolDetails { .. }
        | RuntimeCommand::Feedback { .. }
        | RuntimeCommand::ReadFeedback { .. }
        | RuntimeCommand::ImportCodex { .. }
        | RuntimeCommand::ImportChatGpt { .. }
        | RuntimeCommand::ImportStatus
        | RuntimeCommand::RetryHistoryIndex
        | RuntimeCommand::TaskInput { .. }
        | RuntimeCommand::AnnotateTranscript { .. }
        | RuntimeCommand::Notifications { .. }
        | RuntimeCommand::SearchHistory { .. }
        | RuntimeCommand::ReadConversation { .. }
        | RuntimeCommand::OpenConversation { .. }
        | RuntimeCommand::RevokeAllocation { .. } => None,
    }
}

#[derive(Debug, Serialize)]
pub struct Created {
    pub coordinator_id: CoordinatorId,
    pub archive: PathBuf,
    pub files: usize,
    pub bytes: u64,
    pub not_included: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Restored {
    pub coordinator_id: CoordinatorId,
    pub state_dir: PathBuf,
    pub files: usize,
    pub bytes: u64,
    pub hold: String,
}

#[derive(Debug, Serialize)]
pub struct Released {
    pub state_dir: PathBuf,
    pub was_held: bool,
}

impl fmt::Display for Created {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Backed up coordinator {} to {}: {} files, {} bytes.",
            self.coordinator_id,
            self.archive.display(),
            self.files,
            self.bytes
        )?;
        if !self.not_included.is_empty() {
            write!(f, " Not included: {}.", self.not_included.join(", "))?;
        }
        Ok(())
    }
}

impl fmt::Display for Restored {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "Restored coordinator {} into {} ({} files, {} bytes). {}",
            self.coordinator_id,
            self.state_dir.display(),
            self.files,
            self.bytes,
            self.hold
        )
    }
}

impl fmt::Display for Released {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.was_held {
            write!(
                f,
                "Released the restore hold in {}; the next coordinator start runs background work.",
                self.state_dir.display()
            )
        } else {
            write!(
                f,
                "{} has no restore hold; background work is not held.",
                self.state_dir.display()
            )
        }
    }
}

/// One request to `backup-database.js`. The helper reports facts and Rust
/// decides every refusal.
#[derive(Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum DatabaseRequest {
    /// Copy `source` with SQLite's backup API into the new self-contained
    /// file `snapshot`, then inspect the snapshot.
    Snapshot {
        #[ts(type = "string")]
        source: PathBuf,
        #[ts(type = "string")]
        snapshot: PathBuf,
    },
    Inspect {
        #[ts(type = "string")]
        database: PathBuf,
    },
}

#[derive(Debug, Serialize, Deserialize, TS)]
#[serde(deny_unknown_fields)]
pub struct DatabaseReport {
    /// Rows of `PRAGMA integrity_check`.
    pub integrity: Vec<String>,
    pub journal_mode: String,
    /// `durable_schema.version`, or null when the file is not a Pi Durable store.
    pub schema_version: Option<u32>,
    /// `CURRENT_SQLITE_SCHEMA_VERSION` of the installed Pi Durable.
    pub supported_schema_version: u32,
    pub pi_durable_version: String,
}

struct VerifiedDatabase {
    schema_version: u32,
    supported_schema_version: u32,
    pi_durable_version: String,
}

impl DatabaseReport {
    fn verified(self, file: &Path) -> Result<VerifiedDatabase> {
        ensure!(
            self.integrity == ["ok"],
            "Database integrity check failed for {}: {}",
            file.display(),
            self.integrity.join("; ")
        );
        ensure!(
            self.journal_mode == "delete",
            "{} is not a self-contained database (journal mode {})",
            file.display(),
            self.journal_mode
        );
        let schema_version = self
            .schema_version
            .with_context(|| format!("{} is not a Pi conversation database", file.display()))?;
        Ok(VerifiedDatabase {
            schema_version,
            supported_schema_version: self.supported_schema_version,
            pi_durable_version: self.pi_durable_version,
        })
    }
}

struct DatabaseHelper(PathBuf);

impl DatabaseHelper {
    fn locate(runtime: &Path) -> Result<Self> {
        let script = runtime.with_file_name("backup-database.js");
        ensure!(
            script.is_file(),
            "Pi runtime is not built; build the runtime first"
        );
        Ok(Self(script))
    }

    fn run(&self, request: &DatabaseRequest) -> Result<DatabaseReport> {
        let output = Command::new("node")
            .arg("--no-warnings")
            .arg(&self.0)
            .arg(serde_json::to_string(request)?)
            .stdin(Stdio::null())
            .output()
            .context("Could not start the SQLite backup helper")?;
        ensure!(
            output.status.success(),
            "SQLite could not read the database: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
        serde_json::from_slice(&output.stdout)
            .context("The SQLite backup helper returned an invalid report")
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
enum StateFile {
    Database,
    CoordinatorId,
    Attachment { id: UuidName, part: AttachmentPart },
    HistoryAsset(Sha256Digest),
    FeedbackBundle(UuidName),
    FeedbackLatest,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum AttachmentPart {
    Metadata,
    Content,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum FileKind {
    Database,
    CoordinatorId,
    Attachment,
    HistoryAsset,
    Feedback,
}

impl StateFile {
    fn parse(relative: &str) -> Option<Self> {
        let components: Vec<&str> = relative.split('/').collect();
        match components.as_slice() {
            ["session.sqlite"] => Some(Self::Database),
            ["coordinator-id"] => Some(Self::CoordinatorId),
            ["attachments", id, "metadata.json"] => {
                UuidName::attachment(id).map(|id| Self::Attachment {
                    id,
                    part: AttachmentPart::Metadata,
                })
            }
            ["attachments", id, "content"] => UuidName::attachment(id).map(|id| Self::Attachment {
                id,
                part: AttachmentPart::Content,
            }),
            ["history", "assets", digest] => Sha256Digest::parse(digest).map(Self::HistoryAsset),
            ["feedback", "latest"] => Some(Self::FeedbackLatest),
            ["feedback", name] => name
                .strip_suffix(".json")
                .and_then(UuidName::feedback)
                .map(Self::FeedbackBundle),
            _ => None,
        }
    }

    fn is_carried_directory(relative: &str) -> bool {
        let components: Vec<&str> = relative.split('/').collect();
        match components.as_slice() {
            ["attachments"] | ["history"] | ["history", "assets"] | ["feedback"] => true,
            ["attachments", id] => UuidName::attachment(id).is_some(),
            _ => false,
        }
    }

    fn relative_path(&self) -> PathBuf {
        PathBuf::from(self.to_string())
    }

    fn kind(&self) -> FileKind {
        match self {
            Self::Database => FileKind::Database,
            Self::CoordinatorId => FileKind::CoordinatorId,
            Self::Attachment { .. } => FileKind::Attachment,
            Self::HistoryAsset(_) => FileKind::HistoryAsset,
            Self::FeedbackBundle(_) | Self::FeedbackLatest => FileKind::Feedback,
        }
    }
}

impl fmt::Display for StateFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Database => f.write_str("session.sqlite"),
            Self::CoordinatorId => f.write_str("coordinator-id"),
            Self::Attachment {
                id,
                part: AttachmentPart::Metadata,
            } => write!(f, "attachments/{}/metadata.json", id.0),
            Self::Attachment {
                id,
                part: AttachmentPart::Content,
            } => write!(f, "attachments/{}/content", id.0),
            Self::HistoryAsset(digest) => write!(f, "history/assets/{digest}"),
            Self::FeedbackBundle(id) => write!(f, "feedback/{}.json", id.0),
            Self::FeedbackLatest => f.write_str("feedback/latest"),
        }
    }
}

impl TryFrom<String> for StateFile {
    type Error = String;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        Self::parse(&text).ok_or_else(|| format!("{text:?} is not an allowed backup path"))
    }
}

impl From<StateFile> for String {
    fn from(file: StateFile) -> Self {
        file.to_string()
    }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct UuidName(String);

impl UuidName {
    fn attachment(text: &str) -> Option<Self> {
        Self::feedback(text).filter(|name| name.0.bytes().any(|byte| !matches!(byte, b'0' | b'-')))
    }

    fn feedback(text: &str) -> Option<Self> {
        let hyphenated = text.len() == 36
            && text.bytes().enumerate().all(|(index, byte)| match index {
                8 | 13 | 18 | 23 => byte == b'-',
                _ => byte.is_ascii_hexdigit(),
            });
        hyphenated.then(|| Self(text.to_owned()))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
struct Sha256Digest([u8; 32]);

impl Sha256Digest {
    fn parse(text: &str) -> Option<Self> {
        if !text
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            return None;
        }
        let mut digest = [0; 32];
        hex::decode_to_slice(text, &mut digest).ok()?;
        Some(Self(digest))
    }
}

impl fmt::Display for Sha256Digest {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&hex::encode(self.0))
    }
}

impl TryFrom<String> for Sha256Digest {
    type Error = String;
    fn try_from(text: String) -> Result<Self, Self::Error> {
        Self::parse(&text).ok_or_else(|| format!("{text:?} is not a lowercase SHA-256"))
    }
}

impl From<Sha256Digest> for String {
    fn from(digest: Sha256Digest) -> Self {
        digest.to_string()
    }
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    format: u32,
    created_at_ms: u64,
    application_version: String,
    pi_durable_version: String,
    sqlite_schema_version: u32,
    coordinator_id: CoordinatorId,
    database_integrity: DatabaseIntegrity,
    files: Vec<FileRecord>,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum DatabaseIntegrity {
    Ok,
}

#[derive(Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct FileRecord {
    path: StateFile,
    kind: FileKind,
    size: u64,
    sha256: Sha256Digest,
}

#[derive(Deserialize)]
struct FormatProbe {
    format: u32,
}

impl Manifest {
    fn new(
        coordinator_id: CoordinatorId,
        database: VerifiedDatabase,
        mut files: Vec<FileRecord>,
    ) -> Result<Self> {
        files.sort_by(|left, right| left.path.cmp(&right.path));
        Ok(Self {
            format: FORMAT,
            created_at_ms: now_ms()?,
            application_version: env!("CARGO_PKG_VERSION").to_owned(),
            pi_durable_version: database.pi_durable_version,
            sqlite_schema_version: database.schema_version,
            coordinator_id,
            database_integrity: DatabaseIntegrity::Ok,
            files,
        })
    }

    fn read(archive: &Path) -> Result<Self> {
        let incomplete =
            |detail: &str| anyhow!("{} is not a complete backup: {detail}", archive.display());
        let path = archive.join(MANIFEST);
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Err(incomplete("manifest.json is missing"));
            }
            Err(error) => {
                return Err(error).with_context(|| format!("Could not open {}", path.display()));
            }
        };
        if !file.metadata()?.is_file() {
            return Err(incomplete("manifest.json is not a regular file"));
        }
        let mut bytes = Vec::new();
        file.take(MAX_MANIFEST_BYTES + 1)
            .read_to_end(&mut bytes)
            .with_context(|| format!("Could not read {}", path.display()))?;
        ensure!(
            bytes.len() as u64 <= MAX_MANIFEST_BYTES,
            "{} is too large to be a backup manifest",
            path.display()
        );
        let probe: FormatProbe =
            serde_json::from_slice(&bytes).map_err(|_| incomplete("manifest.json is malformed"))?;
        ensure!(
            probe.format == FORMAT,
            "{} uses backup format {}; this build reads format {FORMAT}",
            archive.display(),
            probe.format
        );
        let manifest: Self = serde_json::from_slice(&bytes)
            .map_err(|error| incomplete(&format!("manifest.json is malformed: {error}")))?;
        manifest.check(archive)?;
        Ok(manifest)
    }

    fn check(&self, archive: &Path) -> Result<()> {
        let mut paths = BTreeSet::new();
        for record in &self.files {
            ensure!(
                record.kind == record.path.kind(),
                "manifest path {} is not an allowed {:?} path",
                record.path,
                record.kind
            );
            ensure!(
                paths.insert(&record.path),
                "manifest path {} appears twice",
                record.path
            );
        }
        for required in [StateFile::Database, StateFile::CoordinatorId] {
            ensure!(
                paths.contains(&required),
                "{} is not a complete backup: the manifest has no {required}",
                archive.display()
            );
        }
        for path in &paths {
            if let StateFile::Attachment { id, .. } = path {
                for part in [AttachmentPart::Metadata, AttachmentPart::Content] {
                    let pair = StateFile::Attachment {
                        id: id.clone(),
                        part,
                    };
                    ensure!(
                        paths.contains(&pair),
                        "{} is not a complete backup: the manifest has {path} without {pair}",
                        archive.display()
                    );
                }
            }
        }
        Ok(())
    }

    fn bytes(&self) -> u64 {
        self.files.iter().map(|record| record.size).sum()
    }
}

impl FileRecord {
    fn new(path: StateFile, written: Written) -> Self {
        Self {
            kind: path.kind(),
            path,
            size: written.size,
            sha256: written.sha256,
        }
    }

    fn promise(&self) -> Promise {
        Promise {
            sha256: self.sha256,
            size: Some(self.size),
            by: PromisedBy::Manifest,
        }
    }
}

const STATE_ENTRIES: &[(EntryName, Disposition)] = &[
    (EntryName::Exact("session.sqlite"), Disposition::Carried),
    (EntryName::Exact("coordinator-id"), Disposition::Carried),
    (EntryName::Exact("attachments"), Disposition::Carried),
    (EntryName::Exact("history"), Disposition::Carried),
    (EntryName::Exact("feedback"), Disposition::Carried),
    (
        EntryName::Prefix("session.sqlite-"),
        Disposition::DatabaseLog,
    ),
    (EntryName::Exact("auth.json"), Disposition::Credential),
    (EntryName::Prefix(".auth-"), Disposition::Credential),
    (EntryName::Prefix("search.sqlite"), Disposition::Local),
    (EntryName::Exact("diagnostics"), Disposition::Local),
    (EntryName::Exact("coordinator.log"), Disposition::Local),
    (EntryName::Exact("agent.sock"), Disposition::Local),
    (EntryName::Exact("writer.lock"), Disposition::Local),
    (EntryName::Exact("embeddings"), Disposition::Local),
    (EntryName::Exact("attachment-cache"), Disposition::Local),
    (EntryName::Exact("feedback-outbox"), Disposition::Local),
    (EntryName::Exact("feedback-views"), Disposition::Local),
    (EntryName::Exact("recovery"), Disposition::Local),
    (EntryName::Exact("scrawl-feedback.json"), Disposition::Local),
    (EntryName::Exact("scrawl-feedback.lock"), Disposition::Local),
    (EntryName::Exact("coordinator-id.tmp"), Disposition::Local),
    (EntryName::Exact(RESTORE_HOLD_FILE), Disposition::Local),
    (EntryName::Exact(UNRECORDED_START_STAMP), Disposition::Local),
    (EntryName::Exact(DREAMS_DIRECTORY), Disposition::Local),
];

#[derive(Clone, Copy)]
enum EntryName {
    Exact(&'static str),
    Prefix(&'static str),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Disposition {
    Carried,
    DatabaseLog,
    Credential,
    Local,
}

fn disposition(name: &str) -> Option<Disposition> {
    STATE_ENTRIES
        .iter()
        .find(|(entry, _)| match entry {
            EntryName::Exact(exact) => name == *exact,
            EntryName::Prefix(prefix) => name.starts_with(prefix),
        })
        .map(|(_, disposition)| *disposition)
}

struct Inventory {
    files: BTreeMap<StateFile, Option<Promise>>,
    not_included: Vec<String>,
}

#[derive(Clone, Copy, Debug)]
struct Promise {
    sha256: Sha256Digest,
    size: Option<u64>,
    by: PromisedBy,
}

#[derive(Clone, Copy, Debug)]
enum PromisedBy {
    FileName,
    AttachmentMetadata,
    Manifest,
}

impl fmt::Display for PromisedBy {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::FileName => "its SHA-256 name",
            Self::AttachmentMetadata => "its attachment metadata",
            Self::Manifest => "the manifest",
        })
    }
}

#[derive(Deserialize)]
struct AttachmentMetadata {
    attachment: AttachmentRef,
    complete: bool,
}

impl Inventory {
    fn scan(state: &Path) -> Result<Self> {
        let mut inventory = Self {
            files: BTreeMap::new(),
            not_included: Vec::new(),
        };
        for name in sorted_names(state)? {
            match name.into_string() {
                Ok(name) => match disposition(&name) {
                    Some(Disposition::Carried) => inventory.walk(state, name)?,
                    Some(_) => {}
                    None => inventory.not_included.push(name),
                },
                Err(name) => inventory
                    .not_included
                    .push(name.to_string_lossy().into_owned()),
            }
        }
        inventory.admit_attachments(state)?;
        Ok(inventory)
    }

    fn walk(&mut self, state: &Path, relative: String) -> Result<()> {
        let path = state.join(&relative);
        let metadata = fs::symlink_metadata(&path)
            .with_context(|| format!("Could not inspect {}", path.display()))?;
        let file = StateFile::parse(&relative);
        let carried_directory = StateFile::is_carried_directory(&relative);
        if metadata.is_file() {
            match file {
                Some(file) => {
                    let promise = match &file {
                        StateFile::HistoryAsset(digest) => Some(Promise {
                            sha256: *digest,
                            size: None,
                            by: PromisedBy::FileName,
                        }),
                        _ => None,
                    };
                    self.files.insert(file, promise);
                }
                None if is_writer_temporary(&relative) => {}
                None => self.not_included.push(relative),
            }
        } else if metadata.is_dir() && carried_directory {
            for name in sorted_names(&path)? {
                match name.into_string() {
                    Ok(name) => self.walk(state, format!("{relative}/{name}"))?,
                    Err(name) => self
                        .not_included
                        .push(format!("{relative}/{}", name.to_string_lossy())),
                }
            }
        } else if file.is_some() || carried_directory {
            bail!("{} is not a regular file", path.display());
        } else {
            self.not_included.push(relative);
        }
        Ok(())
    }

    fn admit_attachments(&mut self, state: &Path) -> Result<()> {
        let ids: BTreeSet<UuidName> = self
            .files
            .keys()
            .filter_map(|file| match file {
                StateFile::Attachment { id, .. } => Some(id.clone()),
                _ => None,
            })
            .collect();
        for id in ids {
            let metadata = StateFile::Attachment {
                id: id.clone(),
                part: AttachmentPart::Metadata,
            };
            let content = StateFile::Attachment {
                id: id.clone(),
                part: AttachmentPart::Content,
            };
            if !self.files.contains_key(&metadata) {
                self.files.remove(&content);
                continue;
            }
            let path = state.join(metadata.relative_path());
            let invalid = || format!("{} is not valid attachment metadata", path.display());
            let saved: AttachmentMetadata =
                serde_json::from_slice(&fs::read(&path).with_context(invalid)?)
                    .with_context(invalid)?;
            ensure!(
                saved.attachment.id == id.0,
                "{} describes another attachment",
                path.display()
            );
            if !saved.complete {
                self.files.remove(&metadata);
                self.files.remove(&content);
                continue;
            }
            ensure!(
                self.files.contains_key(&content),
                "{} is missing",
                state.join(content.relative_path()).display()
            );
            let sha256 = Sha256Digest::parse(&saved.attachment.sha256).with_context(invalid)?;
            self.files.insert(
                content,
                Some(Promise {
                    sha256,
                    size: Some(u64::from(saved.attachment.size_bytes)),
                    by: PromisedBy::AttachmentMetadata,
                }),
            );
        }
        Ok(())
    }
}

fn sorted_names(directory: &Path) -> Result<Vec<OsString>> {
    let mut names = fs::read_dir(directory)
        .with_context(|| format!("Could not read {}", directory.display()))?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<io::Result<Vec<_>>>()
        .with_context(|| format!("Could not read {}", directory.display()))?;
    names.sort();
    Ok(names)
}

fn is_writer_temporary(relative: &str) -> bool {
    let name = relative.rsplit('/').next().unwrap_or(relative);
    name.starts_with('.') || name.ends_with(".tmp")
}

struct Written {
    size: u64,
    sha256: Sha256Digest,
}

fn copy_hashed(source: &Path, destination: &Path, promise: Option<Promise>) -> Result<Written> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(source)
        .with_context(|| format!("Could not open {}", source.display()))?;
    ensure!(
        file.metadata()?.is_file(),
        "{} is not a regular file",
        source.display()
    );
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(destination)
        .with_context(|| format!("Could not create {}", destination.display()))?;
    let limit = promise
        .and_then(|promise| promise.size)
        .map_or(u64::MAX, |size| size.saturating_add(1));
    let written = stream(file.take(limit), &mut output)
        .with_context(|| format!("Could not copy {}", source.display()))?;
    if let Some(promise) = promise {
        ensure!(
            written.sha256 == promise.sha256
                && promise.size.is_none_or(|size| size == written.size),
            "{} does not match {}",
            source.display(),
            promise.by
        );
    }
    output
        .sync_all()
        .with_context(|| format!("Could not sync {}", destination.display()))?;
    Ok(written)
}

fn stream(mut reader: impl Read, mut sink: impl Write) -> io::Result<Written> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 256 * 1024];
    let mut size = 0;
    loop {
        let count = match reader.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        hasher.update(&buffer[..count]);
        sink.write_all(&buffer[..count])?;
        size += count as u64;
    }
    Ok(Written {
        size,
        sha256: Sha256Digest(hasher.finalize().into()),
    })
}

fn seal_database(snapshot: &Path) -> Result<Written> {
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut sidecar = OsString::from(snapshot.as_os_str());
        sidecar.push(suffix);
        let sidecar = PathBuf::from(sidecar);
        ensure!(
            absent(&sidecar)?,
            "SQLite left {} beside the snapshot",
            sidecar.display()
        );
    }
    fs::set_permissions(snapshot, fs::Permissions::from_mode(0o600))?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(snapshot)
        .with_context(|| format!("Could not open {}", snapshot.display()))?;
    file.sync_all()
        .with_context(|| format!("Could not sync {}", snapshot.display()))?;
    Ok(stream(&file, io::sink())?)
}

fn archived_file(data: &Path, file: &StateFile) -> Result<PathBuf> {
    let path = data.join(file.relative_path());
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            bail!("{file} is missing from the backup")
        }
        Err(error) => {
            return Err(error).with_context(|| format!("Could not inspect {}", path.display()));
        }
    };
    ensure!(
        metadata.is_file(),
        "{} is not a regular file",
        path.display()
    );
    ensure!(
        path.canonicalize()?.starts_with(data),
        "{file} leaves the backup's data directory"
    );
    Ok(path)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Existing {
    Nothing,
    /// `rename(2)` replaces an empty directory atomically and refuses one that
    /// gained an entry.
    EmptyDirectory,
}

struct Staging {
    root: PathBuf,
    directories: BTreeSet<PathBuf>,
    published: bool,
}

impl Staging {
    fn create(parent: &Path, name: String, directories: BTreeSet<PathBuf>) -> Result<Self> {
        let root = parent.join(name);
        private_directory(&root)?;
        let staging = Self {
            root,
            directories,
            published: false,
        };
        for directory in &staging.directories {
            private_directory(&staging.root.join(directory))?;
        }
        Ok(staging)
    }

    fn root(&self) -> &Path {
        &self.root
    }

    fn publish(mut self, destination: &Path, existing: Existing) -> Result<()> {
        for directory in self.directories.iter().rev() {
            sync_directory(&self.root.join(directory))?;
        }
        sync_directory(&self.root)?;
        let renamed = match existing {
            Existing::Nothing => rename_noreplace(&self.root, destination),
            Existing::EmptyDirectory => fs::rename(&self.root, destination),
        };
        match renamed {
            Ok(()) => self.published = true,
            Err(error) if matches!(error.raw_os_error(), Some(libc::EEXIST | libc::ENOTEMPTY)) => {
                match existing {
                    Existing::Nothing => bail!("{} already exists", destination.display()),
                    Existing::EmptyDirectory => bail!(
                        "Restore target {} is not empty; choose a new or empty directory",
                        destination.display()
                    ),
                }
            }
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("Could not publish {}", destination.display()));
            }
        }
        let parent = self
            .root
            .parent()
            .context("A staging directory has no parent")?;
        sync_directory(parent)?;
        Ok(())
    }
}

impl Drop for Staging {
    fn drop(&mut self) {
        if !self.published {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
}

fn private_directory(path: &Path) -> Result<()> {
    DirBuilder::new()
        .mode(0o700)
        .create(path)
        .with_context(|| format!("Could not create {}", path.display()))
}

fn directories(files: impl Iterator<Item = PathBuf>) -> BTreeSet<PathBuf> {
    files
        .flat_map(|file| {
            file.ancestors()
                .skip(1)
                .filter(|ancestor| !ancestor.as_os_str().is_empty())
                .map(Path::to_path_buf)
                .collect::<Vec<_>>()
        })
        .collect()
}

fn rename_noreplace(from: &Path, to: &Path) -> io::Result<()> {
    let from = CString::new(from.as_os_str().as_bytes())?;
    let to = CString::new(to.as_os_str().as_bytes())?;
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), libc::RENAME_EXCL) };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn sync_directory(path: &Path) -> Result<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .with_context(|| format!("Could not sync {}", path.display()))
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .with_context(|| format!("Could not create {}", path.display()))?;
    file.write_all(bytes)?;
    file.sync_all()?;
    Ok(())
}

fn existing_private_directory(state: &Path) -> Result<()> {
    let metadata = match fs::metadata(state) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            bail!("The state directory {} does not exist", state.display())
        }
        Err(error) => {
            return Err(error).with_context(|| format!("Could not inspect {}", state.display()));
        }
    };
    ensure!(
        metadata.is_dir(),
        "The state directory {} is not a directory",
        state.display()
    );
    ensure!(
        metadata.permissions().mode() & 0o077 == 0,
        "The agent state directory must be private (mode 0700)"
    );
    Ok(())
}

fn absent(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(false),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(true),
        Err(error) => Err(error).with_context(|| format!("Could not inspect {}", path.display())),
    }
}

fn restore_target(target: &Path) -> Result<Existing> {
    let metadata = match fs::symlink_metadata(target) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Existing::Nothing),
        Err(error) => {
            return Err(error).with_context(|| format!("Could not inspect {}", target.display()));
        }
    };
    let empty = metadata.is_dir()
        && fs::read_dir(target)
            .with_context(|| format!("Could not read {}", target.display()))?
            .next()
            .is_none();
    ensure!(
        empty,
        "Restore target {} is not empty; choose a new or empty directory",
        target.display()
    );
    Ok(Existing::EmptyDirectory)
}

fn parent_and_name(path: &Path) -> Result<(PathBuf, String)> {
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .with_context(|| format!("{} needs a final name in UTF-8", path.display()))?;
    let parent = match path.parent() {
        Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
        _ => PathBuf::from("."),
    };
    ensure!(
        parent.is_dir(),
        "The parent directory {} does not exist",
        parent.display()
    );
    Ok((parent, name.to_owned()))
}

fn inside(path: &Path, directory: &Path) -> Result<bool> {
    let resolve = |path: &Path| {
        path.canonicalize()
            .with_context(|| format!("Could not resolve {}", path.display()))
    };
    Ok(resolve(path)?.starts_with(resolve(directory)?))
}

fn now_ms() -> Result<u64> {
    Ok(u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("The system clock is before 1970")?
            .as_millis(),
    )?)
}

#[derive(Serialize)]
struct RestoreHold {
    coordinator_id: CoordinatorId,
    archive: PathBuf,
    archive_created_at_ms: u64,
    restored_at_ms: u64,
}

#[cfg(test)]
mod tests {
    use super::*;

    const ID: &str = "0f5a3c2e-7b1d-4e8f-9a6b-1c2d3e4f5a6b";

    fn every_variant() -> Vec<StateFile> {
        let id = UuidName::attachment(ID).unwrap();
        vec![
            StateFile::Database,
            StateFile::CoordinatorId,
            StateFile::Attachment {
                id: id.clone(),
                part: AttachmentPart::Metadata,
            },
            StateFile::Attachment {
                id,
                part: AttachmentPart::Content,
            },
            StateFile::HistoryAsset(Sha256Digest([0xab; 32])),
            StateFile::FeedbackBundle(UuidName::feedback(&ID.to_uppercase()).unwrap()),
            StateFile::FeedbackLatest,
        ]
    }

    fn sample_manifest() -> Manifest {
        Manifest {
            format: FORMAT,
            created_at_ms: 1,
            application_version: "0.1.0".into(),
            pi_durable_version: "1.4.0".into(),
            sqlite_schema_version: 2,
            coordinator_id: ID.parse().unwrap(),
            database_integrity: DatabaseIntegrity::Ok,
            files: every_variant()
                .into_iter()
                .map(|path| FileRecord {
                    kind: path.kind(),
                    path,
                    size: 3,
                    sha256: Sha256Digest([1; 32]),
                })
                .collect(),
        }
    }

    fn read_manifest(text: &[u8]) -> Result<Manifest> {
        let archive = tempfile::tempdir().unwrap();
        fs::write(archive.path().join(MANIFEST), text).unwrap();
        Manifest::read(archive.path())
    }

    #[test]
    fn state_file_paths_round_trip_and_nothing_else_parses() {
        for file in every_variant() {
            assert_eq!(StateFile::parse(&file.to_string()), Some(file.clone()));
        }
        let uppercase_asset = format!("history/assets/{}", "AB".repeat(32));
        for rejected in [
            "../escaped.json",
            "/session.sqlite",
            "./session.sqlite",
            "session.sqlite/",
            "feedback/../coordinator-id",
            &uppercase_asset,
            "history/assets/abc",
            "attachments/00000000-0000-0000-0000-000000000000/content",
            "attachments/not-a-uuid/content",
            "feedback/latest/",
            "feedback/latest.json",
            "auth.json",
            "",
            "data/session.sqlite",
        ] {
            assert_eq!(StateFile::parse(rejected), None, "{rejected:?}");
        }
    }

    #[test]
    fn every_carried_path_starts_at_a_carried_top_level_name() {
        for file in every_variant() {
            let path = file.to_string();
            let components: Vec<&str> = path.split('/').collect();
            assert_eq!(
                disposition(components[0]),
                Some(Disposition::Carried),
                "{path}"
            );
            for depth in 1..components.len() {
                assert!(
                    StateFile::is_carried_directory(&components[..depth].join("/")),
                    "{path}"
                );
            }
        }
    }

    #[test]
    fn manifest_round_trips() {
        let manifest = sample_manifest();
        assert_eq!(
            read_manifest(&serde_json::to_vec(&manifest).unwrap()).unwrap(),
            manifest
        );
    }

    #[test]
    fn manifest_parse_is_strict() {
        let valid = serde_json::to_value(sample_manifest()).unwrap();
        let refused = |expected: &str, change: &dyn Fn(&mut serde_json::Value)| {
            let mut manifest = valid.clone();
            change(&mut manifest);
            let error = format!(
                "{:#}",
                read_manifest(&serde_json::to_vec(&manifest).unwrap()).unwrap_err()
            );
            assert!(error.contains(expected), "expected {expected:?}: {error}");
        };
        let files = |manifest: &mut serde_json::Value| -> Vec<serde_json::Value> {
            manifest["files"].as_array().unwrap().clone()
        };
        refused("unknown field `extra`", &|manifest| {
            manifest["extra"] = true.into();
        });
        refused("unknown field `note`", &|manifest| {
            manifest["files"][0]["note"] = true.into();
        });
        refused("is not an allowed Feedback path", &|manifest| {
            manifest["files"][0]["kind"] = "feedback".into();
        });
        refused(
            "\"../escaped.json\" is not an allowed backup path",
            &|manifest| {
                manifest["files"][0]["path"] = "../escaped.json".into();
            },
        );
        refused("appears twice", &|manifest| {
            let mut records = files(manifest);
            records.push(records[1].clone());
            manifest["files"] = records.into();
        });
        refused(
            "not a complete backup: the manifest has no session.sqlite",
            &|manifest| {
                let mut records = files(manifest);
                records.retain(|record| record["kind"] != "database");
                manifest["files"] = records.into();
            },
        );
        refused("without attachments/", &|manifest| {
            let mut records = files(manifest);
            records.retain(|record| !record["path"].as_str().unwrap().ends_with("/content"));
            manifest["files"] = records.into();
        });
        refused("is not a lowercase SHA-256", &|manifest| {
            manifest["files"][0]["sha256"] = "AB".repeat(32).into();
        });
        refused("unknown variant `damaged`", &|manifest| {
            manifest["database_integrity"] = "damaged".into();
        });
        refused(
            "uses backup format 2; this build reads format 1",
            &|manifest| {
                manifest["format"] = 2.into();
                manifest["files"] = "a later layout".into();
            },
        );

        let text = serde_json::to_vec(&valid).unwrap();
        let truncated = format!("{:#}", read_manifest(&text[..text.len() / 2]).unwrap_err());
        assert!(
            truncated.contains("is not a complete backup: manifest.json is malformed"),
            "{truncated}"
        );
        let unpublished = format!(
            "{:#}",
            Manifest::read(tempfile::tempdir().unwrap().path()).unwrap_err()
        );
        assert!(
            unpublished.contains("is not a complete backup: manifest.json is missing"),
            "{unpublished}"
        );
    }

    #[test]
    fn staging_is_removed_unless_published() {
        let parent = tempfile::tempdir().unwrap();
        let layout = || directories([PathBuf::from("data/history/assets/file")].into_iter());

        let staging =
            Staging::create(parent.path(), ".archive.partial-a".into(), layout()).unwrap();
        let abandoned = staging.root().to_path_buf();
        assert!(abandoned.join("data/history/assets").is_dir());
        assert_eq!(
            fs::metadata(&abandoned).unwrap().permissions().mode() & 0o777,
            0o700
        );
        drop(staging);
        assert!(!abandoned.exists());

        let archive = parent.path().join("archive");
        let staging =
            Staging::create(parent.path(), ".archive.partial-b".into(), layout()).unwrap();
        fs::write(staging.root().join("data/history/assets/file"), "kept").unwrap();
        staging.publish(&archive, Existing::Nothing).unwrap();
        assert_eq!(
            fs::read_to_string(archive.join("data/history/assets/file")).unwrap(),
            "kept"
        );
        assert_eq!(fs::read_dir(parent.path()).unwrap().count(), 1);
    }

    #[test]
    fn rename_noreplace_refuses_an_existing_destination_and_leaves_both() {
        let parent = tempfile::tempdir().unwrap();
        let staged = parent.path().join("staged");
        let existing = parent.path().join("existing");
        fs::create_dir(&staged).unwrap();
        fs::write(staged.join("manifest.json"), "staged").unwrap();
        fs::create_dir(&existing).unwrap();

        let error = rename_noreplace(&staged, &existing).unwrap_err();
        assert_eq!(error.raw_os_error(), Some(libc::EEXIST));
        assert_eq!(
            fs::read_to_string(staged.join("manifest.json")).unwrap(),
            "staged"
        );
        assert_eq!(fs::read_dir(&existing).unwrap().count(), 0);

        let fresh = parent.path().join("fresh");
        rename_noreplace(&staged, &fresh).unwrap();
        assert_eq!(
            fs::read_to_string(fresh.join("manifest.json")).unwrap(),
            "staged"
        );
    }

    #[test]
    fn publish_over_an_empty_directory_replaces_it_and_refuses_a_nonempty_one() {
        let parent = tempfile::tempdir().unwrap();
        let empty = parent.path().join("empty");
        fs::create_dir(&empty).unwrap();
        let staging =
            Staging::create(parent.path(), ".empty.restore-a".into(), BTreeSet::new()).unwrap();
        fs::write(staging.root().join("coordinator-id"), ID).unwrap();
        staging.publish(&empty, Existing::EmptyDirectory).unwrap();
        assert_eq!(
            fs::read_to_string(empty.join("coordinator-id")).unwrap(),
            ID
        );
        assert_eq!(
            fs::metadata(&empty).unwrap().permissions().mode() & 0o777,
            0o700
        );

        let occupied = parent.path().join("occupied");
        fs::create_dir(&occupied).unwrap();
        fs::write(occupied.join("keep.txt"), "existing").unwrap();
        let staging =
            Staging::create(parent.path(), ".occupied.restore-b".into(), BTreeSet::new()).unwrap();
        let abandoned = staging.root().to_path_buf();
        fs::write(abandoned.join("coordinator-id"), ID).unwrap();
        let error = staging
            .publish(&occupied, Existing::EmptyDirectory)
            .unwrap_err();
        assert!(error.to_string().contains("is not empty"), "{error:#}");
        assert_eq!(
            fs::read_to_string(occupied.join("keep.txt")).unwrap(),
            "existing"
        );
        assert_eq!(fs::read_dir(&occupied).unwrap().count(), 1);
        assert!(!abandoned.exists());
    }

    fn stopped_store() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let state = root.path().join("state");
        DirBuilder::new().mode(0o700).create(&state).unwrap();
        fs::write(state.join("session.sqlite"), "invented database").unwrap();
        fs::write(state.join("coordinator-id"), ID).unwrap();
        fs::write(state.join("writer.lock"), "").unwrap();
        let runtime = root.path().join("runtime");
        fs::create_dir(&runtime).unwrap();
        fs::write(runtime.join("backup-database.js"), "process.exit(9);\n").unwrap();
        (root, state, runtime.join("bridge.js"))
    }

    fn tree(root: &Path) -> BTreeMap<PathBuf, Vec<u8>> {
        let mut files = BTreeMap::new();
        for name in sorted_names(root).unwrap() {
            let path = root.join(name);
            if path.is_dir() {
                files.extend(tree(&path));
            } else {
                files.insert(path.clone(), fs::read(&path).unwrap());
            }
        }
        files
    }

    #[test]
    fn create_refuses_a_file_that_breaks_its_promise_and_leaves_everything_as_it_was() {
        fn refused(expected: &str, damage: impl Fn(&Path) -> PathBuf) {
            let (root, state, runtime) = stopped_store();
            let damaged = damage(&state);
            let before = tree(root.path());
            let archive = root.path().join("archive");
            let error = format!("{:#}", create(&state, &archive, &runtime).unwrap_err());
            assert!(error.contains(expected), "{error}");
            assert!(error.contains(&damaged.display().to_string()), "{error}");
            assert_eq!(tree(root.path()), before, "{expected}: nothing was written");
        }
        let promised = b"promised invented bytes";
        let promised_sha256 = hex::encode(Sha256::digest(promised));
        refused("does not match its SHA-256 name", |state| {
            let assets = state.join("history/assets");
            fs::create_dir_all(&assets).unwrap();
            let asset = assets.join(&promised_sha256);
            fs::write(&asset, "different invented bytes").unwrap();
            asset
        });
        refused("does not match its attachment metadata", |state| {
            let folder = state.join("attachments").join(ID);
            fs::create_dir_all(&folder).unwrap();
            let metadata = serde_json::json!({
                "attachment": {"id": ID, "name": "ledger.txt", "media_type": "text/plain",
                    "size_bytes": promised.len(), "sha256": promised_sha256},
                "retained": true, "complete": true, "created": 1,
            });
            fs::write(folder.join("metadata.json"), metadata.to_string()).unwrap();
            fs::write(folder.join("content"), "tampered invented bytes").unwrap();
            folder.join("content")
        });
    }

    #[test]
    fn incomplete_uploads_and_content_without_metadata_stay_behind() {
        let (_root, state, _) = stopped_store();
        let pending = state.join("attachments").join(ID);
        fs::create_dir_all(&pending).unwrap();
        let metadata = serde_json::json!({
            "attachment": {"id": ID, "name": "draft.txt", "media_type": "text/plain",
                "size_bytes": 7, "sha256": "ab".repeat(32)},
            "retained": true, "complete": false, "created": 1,
        });
        fs::write(pending.join("metadata.json"), metadata.to_string()).unwrap();
        fs::write(pending.join("content"), "partial").unwrap();
        let orphan = state
            .join("attachments")
            .join("1f5a3c2e-7b1d-4e8f-9a6b-1c2d3e4f5a6b");
        fs::create_dir_all(&orphan).unwrap();
        fs::write(orphan.join("content"), "orphaned").unwrap();

        let inventory = Inventory::scan(&state).unwrap();
        assert_eq!(
            inventory.files.keys().cloned().collect::<Vec<_>>(),
            vec![StateFile::Database, StateFile::CoordinatorId]
        );
        assert!(
            inventory.not_included.is_empty(),
            "{:?}",
            inventory.not_included
        );
    }

    #[test]
    fn an_unclean_stop_leaves_coordinator_state_that_is_neither_carried_nor_unknown() {
        let (_root, state, _) = stopped_store();
        fs::write(state.join("unrecorded-start"), "1700000000000").unwrap();
        fs::create_dir_all(state.join("dreams/runs/invented-run")).unwrap();
        fs::write(state.join("dreams/runs/invented-run/run.json"), "{}").unwrap();

        let inventory = Inventory::scan(&state).unwrap();
        assert_eq!(
            inventory.files.keys().cloned().collect::<Vec<_>>(),
            vec![StateFile::Database, StateFile::CoordinatorId]
        );
        assert!(
            inventory.not_included.is_empty(),
            "{:?}",
            inventory.not_included
        );
    }

    #[test]
    fn create_refuses_a_symlinked_carried_file() {
        let (root, state, runtime) = stopped_store();
        fs::create_dir_all(state.join("history/assets")).unwrap();
        let outside = root.path().join("outside");
        fs::write(&outside, "invented").unwrap();
        std::os::unix::fs::symlink(&outside, state.join("history/assets").join("a".repeat(64)))
            .unwrap();
        let error = format!(
            "{:#}",
            create(&state, &root.path().join("archive"), &runtime).unwrap_err()
        );
        assert!(error.contains("is not a regular file"), "{error}");
        assert!(!root.path().join("archive").exists());
    }

    #[test]
    fn create_never_creates_the_state_directory() {
        let (root, _, runtime) = stopped_store();
        let missing = root.path().join("missing");
        let error = create(&missing, &root.path().join("archive"), &runtime).unwrap_err();
        assert!(error.to_string().contains("does not exist"), "{error:#}");
        assert!(!missing.exists());
        assert!(!root.path().join("archive").exists());
    }
}
