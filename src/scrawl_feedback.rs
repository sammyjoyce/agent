//! Forwards each finished Scrawl capture on this Mac to a coordinator as the
//! `/feedback` submit the phone sends, so it starts the same repair.
use std::{
    borrow::Borrow,
    collections::{BTreeMap, HashMap},
    fmt,
    fs::{self, File, OpenOptions},
    io::{ErrorKind, Write},
    net::{IpAddr, Ipv4Addr, SocketAddr},
    num::NonZeroU16,
    os::unix::fs::OpenOptionsExt,
    path::{Component, Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context, Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncRead, AsyncWrite, BufReader},
    process::Child,
    time::timeout,
};

use crate::{
    attachments::{
        ATTACHMENT_STAGING_MILLIS, AttachmentRef, AttachmentRequest, MAX_ATTACHMENT_BYTES,
        MAX_ATTACHMENTS, WireEnvelope, exchange_chunk, upload_bytes, upload_file,
    },
    coordinator_id::CoordinatorId,
    native::{NativeEvent, NativeRequest},
    protocol::{InputMode, RuntimeCommand},
    runtime::{FrameReader, Wire},
    service::write_frame,
    tailnet::{Daemon, PeerPolicy},
};

pub const POLL_INTERVAL: Duration = Duration::from_secs(2);
/// Scrawl writes `summary.md` last, without a rename, so it must stop changing.
const SETTLE_PERIOD: Duration = Duration::from_secs(2);
const DESCRIPTION_BYTES: usize = 4096;
const COMPOSER_LOG_BYTES: usize = 262_144;
const LEDGER_FILE: &str = "scrawl-feedback.json";
const LOCK_FILE: &str = "scrawl-feedback.lock";
const IDENTITY_TIMEOUT: Duration = Duration::from_secs(10);
const ACKNOWLEDGEMENT_TIMEOUT: Duration = Duration::from_secs(120);
const FIRST_RETRY: Duration = Duration::from_secs(5);
const LAST_RETRY: Duration = Duration::from_secs(300);

/// Scrawl's built-in captures folder. Scrawl's capture side runs only on macOS.
pub fn default_captures_dir() -> Option<PathBuf> {
    cfg!(target_os = "macos")
        .then(dirs::home_dir)
        .flatten()
        .map(|home| home.join("Library/Application Support/scrawl/captures"))
}

/// A bundle folder's name, such as `scrawl-20261114-0001.scrawl`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct BundleId(String);

impl BundleId {
    fn from_folder(name: &std::ffi::OsStr) -> Option<Self> {
        let name = name.to_str()?;
        (name.ends_with(".scrawl") && !name.starts_with('.')).then(|| Self(name.to_owned()))
    }
}

impl Borrow<str> for BundleId {
    fn borrow(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for BundleId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

/// A coordinator address as the phone holds it: a tailnet IPv4 address or a
/// full MagicDNS name, and a nonzero port.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "AddressFields", into = "AddressFields")]
pub struct PhoneAddress {
    host: TailnetHost,
    port: NonZeroU16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TailnetHost {
    Address(Ipv4Addr),
    MagicDns(String),
}

#[derive(Serialize, Deserialize)]
struct AddressFields {
    host: String,
    port: u16,
}

impl PhoneAddress {
    /// Mirrors `CoordinatorAddress.init` in the iOS app.
    pub fn new(host: &str, port: u16) -> Result<Self> {
        let port = NonZeroU16::new(port).context("A coordinator port is 1 to 65535")?;
        let host = host.to_ascii_lowercase();
        let host = host.strip_suffix('.').unwrap_or(&host);
        let host = match host.parse::<Ipv4Addr>() {
            Ok(address) => TailnetHost::Address(crate::tailnet::tailnet_v4(address.into())?),
            Err(_) => {
                ensure!(
                    is_magic_dns(host),
                    "A coordinator host is a Tailscale IPv4 address or a full .ts.net name"
                );
                TailnetHost::MagicDns(host.to_owned())
            }
        };
        Ok(Self { host, port })
    }

    async fn resolve(&self) -> Result<SocketAddr> {
        let address = match &self.host {
            TailnetHost::Address(address) => *address,
            TailnetHost::MagicDns(name) => {
                let answers: Vec<Ipv4Addr> = tokio::net::lookup_host((name.as_str(), 0))
                    .await
                    .with_context(|| format!("Could not resolve {name}"))?
                    .filter_map(|answer| match answer.ip() {
                        IpAddr::V4(address) => Some(address),
                        IpAddr::V6(_) => None,
                    })
                    .collect();
                ensure!(!answers.is_empty(), "{name} has no IPv4 address");
                for answer in &answers {
                    crate::tailnet::tailnet_v4((*answer).into())
                        .with_context(|| format!("{name} resolves outside the tailnet"))?;
                }
                answers[0]
            }
        };
        Ok(SocketAddr::from((address, self.port.get())))
    }
}

fn is_magic_dns(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    host.ends_with(".ts.net")
        && labels.len() >= 4
        && host.len() <= 253
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
}

impl TryFrom<AddressFields> for PhoneAddress {
    type Error = anyhow::Error;

    fn try_from(fields: AddressFields) -> Result<Self> {
        Self::new(&fields.host, fields.port)
    }
}

impl From<PhoneAddress> for AddressFields {
    fn from(address: PhoneAddress) -> Self {
        Self {
            host: match address.host {
                TailnetHost::Address(address) => address.to_string(),
                TailnetHost::MagicDns(name) => name,
            },
            port: address.port.get(),
        }
    }
}

impl fmt::Display for PhoneAddress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.host {
            TailnetHost::Address(address) => write!(f, "{address}:{}", self.port),
            TailnetHost::MagicDns(name) => write!(f, "{name}:{}", self.port),
        }
    }
}

/// Where a capture's feedback goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "route", rename_all = "snake_case")]
pub enum Destination {
    /// The coordinator this Mac's configuration selects.
    Configured,
    /// The coordinator the phone showed, reached only after it names itself.
    Pinned {
        coordinator_id: CoordinatorId,
        address: PhoneAddress,
    },
}

struct ScrawlCapture {
    id: BundleId,
    origin: CaptureOrigin,
    contents: CaptureContents,
}

enum CaptureOrigin {
    Phone {
        coordinator_id: CoordinatorId,
        address: PhoneAddress,
        description: String,
        composer_log: Option<String>,
    },
    PhoneWithoutTarget {
        reason: String,
    },
    Mac,
}

struct CaptureContents {
    narration: String,
    note: Option<String>,
    summary: BundleFile,
    contact_sheet: Option<BundleFile>,
    manifest: BundleFile,
    keyframes: Vec<BundleFile>,
    recording: Option<BundleFile>,
}

struct BundleFile {
    path: PathBuf,
    size: u64,
}

impl BundleFile {
    fn regular(path: PathBuf) -> Option<Self> {
        let metadata = fs::symlink_metadata(&path).ok()?;
        metadata.is_file().then_some(Self {
            path,
            size: metadata.len(),
        })
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Manifest {
    transcript: ManifestTranscript,
    #[serde(default)]
    note: Option<String>,
    #[serde(default)]
    keyframes: Vec<ManifestKeyframe>,
    contact_sheet: BundlePath,
    #[serde(default)]
    video: Option<BundlePath>,
    #[serde(default)]
    source: Option<String>,
}

#[derive(Deserialize)]
struct ManifestTranscript {
    #[serde(default)]
    text: String,
}

#[derive(Deserialize)]
struct ManifestKeyframe {
    index: usize,
    file: BundlePath,
}

#[derive(Deserialize)]
#[serde(try_from = "String")]
struct BundlePath(PathBuf);

impl TryFrom<String> for BundlePath {
    type Error = String;

    fn try_from(value: String) -> Result<Self, String> {
        let path = PathBuf::from(&value);
        let inside = path.components().next().is_some()
            && path
                .components()
                .all(|component| matches!(component, Component::Normal(_)));
        inside
            .then_some(Self(path))
            .ok_or_else(|| format!("{value:?} is not a path inside the bundle"))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BeepBoopTarget {
    coordinator_id: String,
    host: String,
    port: u16,
    description: String,
    #[serde(default)]
    composer_log: Option<String>,
}

enum Reading {
    Incomplete,
    Invalid(String),
    Ready(Box<ScrawlCapture>),
}

fn read_capture(captures: &Path, id: &BundleId, now: SystemTime) -> Reading {
    let directory = captures.join(&id.0);
    let Some(summary) = BundleFile::regular(directory.join("summary.md")) else {
        return Reading::Incomplete;
    };
    let settled = fs::symlink_metadata(&summary.path)
        .and_then(|metadata| metadata.modified())
        .is_ok_and(|modified| {
            now.duration_since(modified)
                .is_ok_and(|age| age >= SETTLE_PERIOD)
        });
    if !settled || directory.join(".transcript-pending").exists() {
        return Reading::Incomplete;
    }
    let Some(manifest_file) = BundleFile::regular(directory.join("scrawl.json")) else {
        return Reading::Invalid("The bundle has a summary but no scrawl.json".into());
    };
    let manifest: Manifest = match fs::read(&manifest_file.path)
        .map_err(anyhow::Error::from)
        .and_then(|bytes| Ok(serde_json::from_slice(&bytes)?))
    {
        Ok(manifest) => manifest,
        Err(error) => return Reading::Invalid(format!("scrawl.json is unreadable: {error}")),
    };
    let origin = capture_origin(&directory, manifest.source.is_some());
    let mut keyframes = manifest.keyframes;
    keyframes.sort_by_key(|keyframe| keyframe.index);
    let file = |relative: &BundlePath| BundleFile::regular(directory.join(&relative.0));
    Reading::Ready(Box::new(ScrawlCapture {
        id: id.clone(),
        origin,
        contents: CaptureContents {
            narration: manifest.transcript.text,
            note: manifest.note,
            summary,
            contact_sheet: file(&manifest.contact_sheet),
            keyframes: keyframes
                .iter()
                .filter_map(|keyframe| file(&keyframe.file))
                .collect(),
            recording: manifest.video.as_ref().and_then(file),
            manifest: manifest_file,
        },
    }))
}

fn capture_origin(directory: &Path, phone_source: bool) -> CaptureOrigin {
    let refuse = |reason: String| CaptureOrigin::PhoneWithoutTarget { reason };
    match fs::read(directory.join("timeline.json")) {
        Ok(bytes) => phone_target(&bytes).unwrap_or_else(refuse),
        Err(error) if error.kind() == ErrorKind::NotFound && !phone_source => CaptureOrigin::Mac,
        Err(error) if error.kind() == ErrorKind::NotFound => {
            refuse("The phone recording names no Beep Boop coordinator".into())
        }
        Err(error) => refuse(format!("timeline.json is unreadable: {error}")),
    }
}

fn phone_target(timeline: &[u8]) -> Result<CaptureOrigin, String> {
    let timeline: serde_json::Value = serde_json::from_slice(timeline)
        .map_err(|error| format!("timeline.json is not JSON: {error}"))?;
    let target = timeline
        .get("beepBoop")
        .ok_or("The phone recording names no Beep Boop coordinator")?;
    match target.get("version") {
        Some(version) if *version == serde_json::json!(1) => {}
        Some(version) => return Err(format!("Unsupported beepBoop version {version}")),
        None => return Err("beepBoop has no version".into()),
    }
    let target = BeepBoopTarget::deserialize(target)
        .map_err(|error| format!("Invalid beepBoop target: {error}"))?;
    let coordinator_id = target
        .coordinator_id
        .parse()
        .map_err(|error| format!("Invalid beepBoop coordinatorId: {error}"))?;
    let address = PhoneAddress::new(&target.host, target.port)
        .map_err(|error| format!("Invalid beepBoop address: {error}"))?;
    if target
        .composer_log
        .as_ref()
        .is_some_and(|log| log.len() > COMPOSER_LOG_BYTES)
    {
        return Err(format!(
            "beepBoop composerLog exceeds {COMPOSER_LOG_BYTES} bytes"
        ));
    }
    Ok(CaptureOrigin::Phone {
        coordinator_id,
        address,
        description: target.description,
        composer_log: target.composer_log,
    })
}

struct Plan {
    destination: Destination,
    description: String,
    attachments: Vec<Attachment>,
}

struct Attachment {
    name: String,
    size: u64,
    content: AttachmentContent,
}

enum AttachmentContent {
    File(PathBuf),
    Text(String),
}

impl Attachment {
    fn file(file: &BundleFile) -> Self {
        Self {
            name: file
                .path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
            size: file.size,
            content: AttachmentContent::File(file.path.clone()),
        }
    }
}

impl ScrawlCapture {
    fn plan(&self) -> Result<Plan, String> {
        let (destination, typed, composer_log) = match &self.origin {
            CaptureOrigin::Phone {
                coordinator_id,
                address,
                description,
                composer_log,
            } => (
                Destination::Pinned {
                    coordinator_id: *coordinator_id,
                    address: address.clone(),
                },
                description.as_str(),
                composer_log.as_deref(),
            ),
            CaptureOrigin::PhoneWithoutTarget { reason } => return Err(reason.clone()),
            CaptureOrigin::Mac => (
                Destination::Configured,
                self.contents.note.as_deref().unwrap_or_default(),
                None,
            ),
        };
        Ok(Plan {
            destination,
            description: description(typed, &self.contents.narration, &self.id),
            attachments: self.contents.attachments(composer_log),
        })
    }
}

impl CaptureContents {
    fn attachments(&self, composer_log: Option<&str>) -> Vec<Attachment> {
        let composer_log = composer_log
            .filter(|log| !log.is_empty())
            .map(|log| Attachment {
                name: "Composer.log".into(),
                size: log.len() as u64,
                content: AttachmentContent::Text(log.to_owned()),
            });
        [
            Some(Attachment::file(&self.summary)),
            self.contact_sheet.as_ref().map(Attachment::file),
            Some(Attachment::file(&self.manifest)),
            composer_log,
        ]
        .into_iter()
        .flatten()
        .chain(self.keyframes.iter().map(Attachment::file))
        .chain(self.recording.iter().map(Attachment::file))
        .filter(|attachment| attachment.size <= u64::from(MAX_ATTACHMENT_BYTES))
        .take(MAX_ATTACHMENTS)
        .collect()
    }
}

fn description(typed: &str, narration: &str, bundle: &BundleId) -> String {
    let mut words: Vec<&str> = typed.split_whitespace().collect();
    let mut narration = narration.split_whitespace().peekable();
    if narration.peek().is_some() {
        words.push("Narration:");
        words.extend(narration);
    }
    let fallback = format!("Scrawl capture {bundle}");
    if words.is_empty() {
        words.extend(fallback.split_whitespace());
    }
    let mut text = words.join(" ");
    if text.len() > DESCRIPTION_BYTES {
        let mut end = DESCRIPTION_BYTES;
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(text[..end].trim_end().len());
    }
    text
}

/// One bundle's routing decision, as `scrawl-feedback --dry-run` prints it.
#[derive(Serialize)]
pub struct Preview {
    bundle: BundleId,
    #[serde(flatten)]
    decision: PreviewDecision,
}

#[derive(Serialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
enum PreviewDecision {
    Backlog,
    Submitted {
        input_id: uuid::Uuid,
        destination: Destination,
        submitted_at_ms: u64,
    },
    Acknowledged,
    Incomplete,
    Refused {
        reason: String,
    },
    Deliver {
        destination: Destination,
        description: String,
        attachments: Vec<String>,
    },
}

impl From<BundleState> for PreviewDecision {
    fn from(state: BundleState) -> Self {
        match state {
            BundleState::Backlog => Self::Backlog,
            BundleState::Submitted {
                input_id,
                destination,
                submitted_at_ms,
                ..
            } => Self::Submitted {
                input_id,
                destination,
                submitted_at_ms,
            },
            BundleState::Acknowledged => Self::Acknowledged,
            BundleState::Refused { reason } => Self::Refused { reason },
        }
    }
}

/// Reports what a watcher on `state` does with each bundle: its ledger state,
/// or the decision for a bundle the ledger does not hold yet. It reads the
/// ledger without the lock and makes no write or network call.
pub fn preview(captures: &Path, state: &Path) -> Result<Vec<Preview>> {
    let present = list_bundles(captures)?;
    let Some(ledger) = read_ledger(&state.join(LEDGER_FILE))? else {
        return Ok(present
            .into_iter()
            .map(|bundle| Preview {
                bundle,
                decision: PreviewDecision::Backlog,
            })
            .collect());
    };
    let now = SystemTime::now();
    let unrecorded: Vec<BundleId> = present
        .into_iter()
        .filter(|bundle| !ledger.contains_key(bundle))
        .collect();
    let mut previews: Vec<Preview> = ledger
        .into_iter()
        .map(|(bundle, state)| Preview {
            bundle,
            decision: state.into(),
        })
        .chain(unrecorded.into_iter().map(|bundle| {
            let decision = match read_capture(captures, &bundle, now) {
                Reading::Incomplete => PreviewDecision::Incomplete,
                Reading::Invalid(reason) => PreviewDecision::Refused { reason },
                Reading::Ready(capture) => match capture.plan() {
                    Err(reason) => PreviewDecision::Refused { reason },
                    Ok(plan) => PreviewDecision::Deliver {
                        destination: plan.destination,
                        description: plan.description,
                        attachments: plan
                            .attachments
                            .into_iter()
                            .map(|attachment| attachment.name)
                            .collect(),
                    },
                },
            };
            Preview { bundle, decision }
        }))
        .collect();
    previews.sort_by(|left, right| left.bundle.cmp(&right.bundle));
    Ok(previews)
}

fn list_bundles(captures: &Path) -> Result<Vec<BundleId>> {
    let entries = match fs::read_dir(captures) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| format!("Could not read {}", captures.display()));
        }
    };
    let mut bundles = Vec::new();
    for entry in entries {
        let entry = entry?;
        if entry.file_type()?.is_dir()
            && let Some(bundle) = BundleId::from_folder(&entry.file_name())
        {
            bundles.push(bundle);
        }
    }
    bundles.sort();
    Ok(bundles)
}

/// A bundle's place in the ledger. A bundle with no entry is new.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum BundleState {
    /// Present before the watcher first ran; never sent.
    Backlog,
    /// Persisted before the command's first write, so a resend is identical.
    Submitted {
        input_id: uuid::Uuid,
        destination: Destination,
        command: Box<RuntimeCommand>,
        /// Wall-clock Unix milliseconds, taken before the first upload.
        submitted_at_ms: u64,
    },
    Acknowledged,
    Refused {
        reason: String,
    },
}

struct Ledger {
    path: PathBuf,
    bundles: BTreeMap<BundleId, BundleState>,
}

impl Ledger {
    fn open(state: &Path, captures: &Path) -> Result<Self> {
        let path = state.join(LEDGER_FILE);
        if let Some(bundles) = read_ledger(&path)? {
            return Ok(Self { path, bundles });
        }
        let ledger = Self {
            bundles: list_bundles(captures)?
                .into_iter()
                .map(|bundle| (bundle, BundleState::Backlog))
                .collect(),
            path,
        };
        ledger.save()?;
        Ok(ledger)
    }

    fn record(&mut self, bundle: &BundleId, state: BundleState) -> Result<()> {
        let previous = self.bundles.insert(bundle.clone(), state);
        let saved = self.save();
        if saved.is_err() {
            match previous {
                Some(previous) => self.bundles.insert(bundle.clone(), previous),
                None => self.bundles.remove(bundle),
            };
        }
        saved
    }

    fn save(&self) -> Result<()> {
        let directory = self.path.parent().context("The ledger has no directory")?;
        let temporary = self.path.with_extension("json.tmp");
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)
            .with_context(|| format!("Could not write {}", temporary.display()))?;
        file.write_all(&serde_json::to_vec_pretty(&self.bundles)?)?;
        file.sync_all()?;
        fs::rename(&temporary, &self.path)
            .with_context(|| format!("Could not replace {}", self.path.display()))?;
        File::open(directory)?.sync_all()?;
        Ok(())
    }
}

fn read_ledger(path: &Path) -> Result<Option<BTreeMap<BundleId, BundleState>>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes).map(Some).with_context(|| {
            format!(
                "{} is not a Scrawl feedback ledger; removing it marks every capture already present as sent",
                path.display()
            )
        }),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("Could not read {}", path.display())),
    }
}

/// Opens coordinator connections for the watcher.
#[async_trait::async_trait]
pub trait Dialer: Send + Sync {
    async fn dial(&self, destination: &Destination) -> Result<Wire>;
}

/// Reaches a phone's pinned coordinator over the native tailnet with this
/// Mac's peer policy.
pub async fn dial_pinned(
    address: &PhoneAddress,
    policy: &PeerPolicy,
    daemon: &Daemon,
) -> Result<Wire> {
    Ok(Wire::tcp(
        crate::tailnet::connect(address.resolve().await?, policy, daemon).await?,
    ))
}

enum Failure {
    Refused(String),
    Transient(anyhow::Error),
}

impl From<anyhow::Error> for Failure {
    fn from(error: anyhow::Error) -> Self {
        Self::Transient(error)
    }
}

struct Session {
    reader: FrameReader<BufReader<Box<dyn AsyncRead + Unpin + Send>>>,
    writer: Box<dyn AsyncWrite + Unpin + Send>,
    _relay: Option<Child>,
}

impl Session {
    async fn open(dialer: &dyn Dialer, destination: &Destination) -> Result<Self, Failure> {
        let wire = dialer.dial(destination).await?;
        let mut session = Self {
            reader: FrameReader::new(BufReader::new(wire.reader)),
            writer: wire.writer,
            _relay: wire.child,
        };
        if let Destination::Pinned {
            coordinator_id,
            address,
        } = destination
        {
            session.identify(*coordinator_id, address).await?;
        }
        Ok(session)
    }

    async fn identify(
        &mut self,
        expected: CoordinatorId,
        address: &PhoneAddress,
    ) -> Result<(), Failure> {
        write_frame(
            &mut *self.writer,
            &RuntimeCommand::Native {
                request: NativeRequest::Identify,
            },
        )
        .await?;
        let frame = timeout(IDENTITY_TIMEOUT, self.reader.next_frame())
            .await
            .map_err(|_| anyhow!("{address} did not name itself in time"))??
            .with_context(|| format!("{address} closed before naming itself"))?;
        let Ok(NativeEvent::Identity { coordinator_id }) = serde_json::from_slice(&frame) else {
            return Err(anyhow!("{address} answered identify with another event").into());
        };
        match coordinator_id.parse::<CoordinatorId>() {
            Ok(actual) if actual == expected => Ok(()),
            _ => Err(Failure::Refused(format!(
                "{address} is coordinator {coordinator_id}, not {expected}, which the phone showed"
            ))),
        }
    }

    async fn upload(&mut self, attachments: &[Attachment]) -> Result<Vec<AttachmentRef>> {
        let session = tokio::sync::Mutex::new(&mut *self);
        let transfer = |request: AttachmentRequest| {
            let session = &session;
            async move {
                let mut session = session.lock().await;
                let Session { reader, writer, .. } = &mut **session;
                exchange_chunk(reader, &mut **writer, request, WireEnvelope::Native).await
            }
        };
        let mut uploaded = Vec::with_capacity(attachments.len());
        for attachment in attachments {
            uploaded.push(match &attachment.content {
                AttachmentContent::File(path) => upload_file(path, transfer).await,
                AttachmentContent::Text(text) => {
                    upload_bytes(attachment.name.clone(), text.as_bytes(), transfer).await
                }
            }?);
        }
        Ok(uploaded)
    }

    async fn submit(
        &mut self,
        command: &RuntimeCommand,
        input_id: uuid::Uuid,
    ) -> Result<(), Failure> {
        write_frame(&mut *self.writer, command).await?;
        let expected = input_id.to_string();
        timeout(ACKNOWLEDGEMENT_TIMEOUT, async {
            loop {
                let frame = self
                    .reader
                    .next_frame()
                    .await?
                    .context("The coordinator disconnected before confirming the feedback")?;
                match serde_json::from_slice(&frame) {
                    Ok(NativeEvent::FeedbackReady { input_id, .. }) if input_id == expected => {
                        return Ok(());
                    }
                    Ok(NativeEvent::Rejected { input_id, message }) if input_id == expected => {
                        return Err(Failure::Refused(message));
                    }
                    Ok(NativeEvent::Failure { message, .. }) => {
                        return Err(anyhow!(
                            "The coordinator did not take the feedback: {message}"
                        )
                        .into());
                    }
                    Ok(NativeEvent::Done) => {
                        return Err(anyhow!(
                            "The coordinator finished without confirming the feedback"
                        )
                        .into());
                    }
                    _ => {}
                }
            }
        })
        .await
        .context("The coordinator did not confirm the feedback in time")?
    }
}

struct Retry {
    at: Instant,
    delay: Duration,
}

/// Owns the ledger in one state directory and moves each bundle through it.
pub struct Watcher {
    captures: PathBuf,
    ledger: Ledger,
    retries: HashMap<BundleId, Retry>,
    lock: File,
}

impl Drop for Watcher {
    fn drop(&mut self) {
        // A child forked before exec holds a copy of this descriptor, and the
        // lock outlives a close until that copy closes too.
        let _ = fs2::FileExt::unlock(&self.lock);
    }
}

impl Watcher {
    /// The first open records every bundle already present as `Backlog`.
    pub fn open(captures: &Path, state: &Path) -> Result<Self> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(state.join(LOCK_FILE))
            .context("Could not open the Scrawl feedback lock")?;
        fs2::FileExt::try_lock_exclusive(&lock)
            .context("Another Scrawl feedback watcher uses this state directory")?;
        Ok(Self {
            captures: captures.to_owned(),
            ledger: Ledger::open(state, captures)?,
            retries: HashMap::new(),
            lock,
        })
    }

    pub fn state(&self, bundle: &str) -> Option<&BundleState> {
        self.ledger.bundles.get(bundle)
    }

    /// One pass: resend unconfirmed requests that are due, then take in new
    /// finished bundles. Returns what happened, for the service log.
    pub async fn poll(&mut self, dialer: &dyn Dialer) -> Vec<String> {
        let mut notices = Vec::new();
        let unconfirmed: Vec<_> = self
            .ledger
            .bundles
            .iter()
            .filter_map(|(bundle, state)| match state {
                BundleState::Submitted {
                    input_id,
                    destination,
                    command,
                    submitted_at_ms,
                } if self.due(bundle) => Some((
                    bundle.clone(),
                    *input_id,
                    destination.clone(),
                    command.clone(),
                    *submitted_at_ms,
                )),
                _ => None,
            })
            .collect();
        for (bundle, input_id, destination, command, submitted_at_ms) in unconfirmed {
            let outcome = match async {
                Session::open(dialer, &destination)
                    .await?
                    .submit(&command, input_id)
                    .await
            }
            .await
            {
                Err(Failure::Transient(_))
                    if now_unix_millis().saturating_sub(submitted_at_ms)
                        >= ATTACHMENT_STAGING_MILLIS =>
                {
                    Err(Failure::Refused(format!(
                        "The coordinator did not confirm within {} hours, and the uploaded files expired",
                        ATTACHMENT_STAGING_MILLIS / 3_600_000
                    )))
                }
                outcome => outcome,
            };
            self.settle(&bundle, outcome, &mut notices);
        }
        let bundles = match list_bundles(&self.captures) {
            Ok(bundles) => bundles,
            Err(error) => {
                notices.push(format!("Scrawl captures are unavailable: {error:#}"));
                return notices;
            }
        };
        let now = SystemTime::now();
        for bundle in bundles {
            if self.ledger.bundles.contains_key(&bundle) || !self.due(&bundle) {
                continue;
            }
            let outcome = match read_capture(&self.captures, &bundle, now) {
                Reading::Incomplete => continue,
                Reading::Invalid(reason) => Err(Failure::Refused(reason)),
                Reading::Ready(capture) => match capture.plan() {
                    Err(reason) => Err(Failure::Refused(reason)),
                    Ok(plan) => self.deliver(&bundle, plan, dialer).await,
                },
            };
            self.settle(&bundle, outcome, &mut notices);
        }
        notices
    }

    async fn deliver(
        &mut self,
        bundle: &BundleId,
        plan: Plan,
        dialer: &dyn Dialer,
    ) -> Result<(), Failure> {
        let submitted_at_ms = now_unix_millis();
        let mut session = Session::open(dialer, &plan.destination).await?;
        let attachments = session.upload(&plan.attachments).await?;
        let input_id = uuid::Uuid::new_v4();
        let command = RuntimeCommand::Native {
            request: NativeRequest::Submit {
                origin: None,
                input_id: input_id.to_string(),
                // clap would take a description's leading `--` as its own separator.
                text: format!("/feedback -- {}", plan.description),
                mode: InputMode::Steer,
                attachments: Some(attachments),
            },
        };
        self.ledger.record(
            bundle,
            BundleState::Submitted {
                input_id,
                destination: plan.destination,
                command: Box::new(command.clone()),
                submitted_at_ms,
            },
        )?;
        session.submit(&command, input_id).await
    }

    fn settle(
        &mut self,
        bundle: &BundleId,
        outcome: Result<(), Failure>,
        notices: &mut Vec<String>,
    ) {
        let state = match outcome {
            Ok(()) => {
                notices.push(format!(
                    "Scrawl capture {bundle} reached its coordinator as feedback."
                ));
                BundleState::Acknowledged
            }
            Err(Failure::Refused(reason)) => {
                notices.push(format!(
                    "Scrawl capture {bundle} will not be sent: {reason}"
                ));
                BundleState::Refused { reason }
            }
            Err(Failure::Transient(error)) => {
                let delay = self.retry_later(bundle);
                notices.push(format!(
                    "Scrawl capture {bundle} is waiting for its coordinator; retrying in {}s: {error:#}",
                    delay.as_secs()
                ));
                return;
            }
        };
        self.retries.remove(bundle);
        if let Err(error) = self.ledger.record(bundle, state) {
            self.retry_later(bundle);
            notices.push(format!(
                "Could not record Scrawl capture {bundle}: {error:#}"
            ));
        }
    }

    fn due(&self, bundle: &BundleId) -> bool {
        self.retries
            .get(bundle)
            .is_none_or(|retry| Instant::now() >= retry.at)
    }

    fn retry_later(&mut self, bundle: &BundleId) -> Duration {
        let delay = self
            .retries
            .get(bundle)
            .map_or(FIRST_RETRY, |retry| (retry.delay * 2).min(LAST_RETRY));
        self.retries.insert(
            bundle.clone(),
            Retry {
                at: Instant::now() + delay,
                delay,
            },
        );
        delay
    }
}

fn now_unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_millis() as u64)
}

/// Polls forever. A failed pass is logged and the next one runs on schedule.
pub async fn watch(mut watcher: Watcher, dialer: &dyn Dialer, notice: impl Fn(String)) {
    loop {
        for line in watcher.poll(dialer).await {
            notice(line);
        }
        tokio::time::sleep(POLL_INTERVAL).await;
    }
}

#[cfg(test)]
pub(crate) mod test_bundles {
    use std::{
        fs,
        path::{Path, PathBuf},
        time::{Duration, SystemTime},
    };

    use serde_json::{Value, json};

    pub(crate) const PINNED_HOST: &str = "coordinator.example-tailnet.ts.net";

    pub(crate) fn manifest(narration: &str, keyframes: usize, source: Option<&str>) -> Value {
        let frames: Vec<Value> = (1..=keyframes)
            .rev()
            .map(|index| {
                json!({"index": index, "t": index * 1000, "reason": "mark",
                    "file": format!("frames/frame-{index:02}.png"), "event": ""})
            })
            .collect();
        let mut manifest = json!({
            "version": 1, "id": "invented", "createdAtMs": 1, "durationMs": 9000,
            "transcript": {"source": "test", "text": narration, "segments": []},
            "keyframes": frames, "contactSheet": "contact-sheet.png", "video": "recording.mp4",
        });
        if let Some(source) = source {
            manifest["source"] = source.into();
        }
        manifest
    }

    pub(crate) fn phone_timeline(coordinator_id: &str, description: &str) -> Value {
        json!({"app": "Beep Boop", "touches": [], "beepBoop": {
            "version": 1, "coordinatorId": coordinator_id, "host": PINNED_HOST, "port": 43187,
            "description": description, "composerLog": "composer opened\ncomposer sent\n",
        }})
    }

    pub(crate) fn write(
        captures: &Path,
        name: &str,
        manifest: &Value,
        timeline: Option<&Value>,
    ) -> PathBuf {
        let directory = captures.join(name);
        fs::create_dir_all(directory.join("frames")).unwrap();
        fs::write(directory.join("recording.mp4"), b"invented movie").unwrap();
        if let Some(timeline) = timeline {
            fs::write(directory.join("timeline.json"), timeline.to_string()).unwrap();
        }
        fs::write(
            directory.join("contact-sheet.png"),
            b"\x89PNG\r\n\x1a\nsheet",
        )
        .unwrap();
        for keyframe in manifest["keyframes"].as_array().unwrap() {
            let file = keyframe["file"].as_str().unwrap();
            fs::write(directory.join(file), b"\x89PNG\r\n\x1a\nframe").unwrap();
        }
        fs::write(directory.join("scrawl.json"), manifest.to_string()).unwrap();
        fs::write(directory.join("summary.md"), "# Invented capture\n").unwrap();
        settle(&directory);
        directory
    }

    pub(crate) fn settle(directory: &Path) {
        fs::File::options()
            .write(true)
            .open(directory.join("summary.md"))
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(60))
            .unwrap();
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use anyhow::{Result, bail};
    use serde_json::{Value, json};

    use super::{
        BundleState, Destination, Dialer, MAX_ATTACHMENT_BYTES, Watcher, preview,
        test_bundles::{PINNED_HOST, manifest, phone_timeline, settle, write},
    };
    use crate::runtime::Wire;

    const COORDINATOR: &str = "6F9619FF-8B86-D011-B42D-00C04FC964FF";

    struct Unreachable(AtomicUsize);

    #[async_trait::async_trait]
    impl Dialer for Unreachable {
        async fn dial(&self, _: &Destination) -> Result<Wire> {
            self.0.fetch_add(1, Ordering::SeqCst);
            bail!("{PINNED_HOST} is unreachable")
        }
    }

    fn decisions(captures: &std::path::Path) -> Value {
        let state = tempfile::tempdir().unwrap();
        drop(Watcher::open(tempfile::tempdir().unwrap().path(), state.path()).unwrap());
        previews(captures, state.path())
    }

    fn previews(captures: &std::path::Path, state: &std::path::Path) -> Value {
        preview(captures, state)
            .unwrap()
            .into_iter()
            .map(|preview| {
                let preview = serde_json::to_value(preview).unwrap();
                (preview["bundle"].as_str().unwrap().to_owned(), preview)
            })
            .collect::<serde_json::Map<_, _>>()
            .into()
    }

    #[test]
    fn bundles_route_by_the_contract_table() {
        let captures = tempfile::tempdir().unwrap();
        let captures = captures.path();
        let phone = manifest("I tap send", 1, Some("iphone"));
        write(
            captures,
            "a-pinned.scrawl",
            &phone,
            Some(&phone_timeline(COORDINATOR, "")),
        );
        write(
            captures,
            "b-other-app.scrawl",
            &phone,
            Some(&json!({"app": "Other"})),
        );
        write(captures, "c-mirrored.scrawl", &phone, None);
        let mut version_two = phone_timeline(COORDINATOR, "");
        version_two["beepBoop"]["version"] = 2.into();
        write(captures, "d-version-two.scrawl", &phone, Some(&version_two));
        let mut lan_host = phone_timeline(COORDINATOR, "");
        lan_host["beepBoop"]["host"] = "192.168.1.10".into();
        write(captures, "e-lan-host.scrawl", &phone, Some(&lan_host));
        write(
            captures,
            "f-mac.scrawl",
            &manifest("Look here", 1, None),
            None,
        );

        let decisions = decisions(captures);
        assert_eq!(
            decisions["a-pinned.scrawl"]["destination"],
            json!({"route": "pinned", "coordinator_id": COORDINATOR.to_lowercase(),
                "address": {"host": PINNED_HOST, "port": 43187}})
        );
        for refused in ["b-other-app", "c-mirrored", "d-version-two", "e-lan-host"] {
            let decision = &decisions[format!("{refused}.scrawl")];
            assert_eq!(decision["decision"], "refused", "{refused}: {decision}");
        }
        assert!(
            decisions["d-version-two.scrawl"]["reason"]
                .as_str()
                .unwrap()
                .contains("version 2")
        );
        assert_eq!(
            decisions["f-mac.scrawl"]["destination"],
            json!({"route": "configured"})
        );
    }

    #[test]
    fn attachments_keep_priority_order_and_the_transfer_caps() {
        let captures = tempfile::tempdir().unwrap();
        let captures = captures.path();
        write(
            captures,
            "phone.scrawl",
            &manifest("", 6, Some("iphone")),
            Some(&phone_timeline(COORDINATOR, "")),
        );
        let mac = write(captures, "mac.scrawl", &manifest("", 2, None), None);
        fs::File::options()
            .write(true)
            .open(mac.join("frames/frame-01.png"))
            .unwrap()
            .set_len(u64::from(MAX_ATTACHMENT_BYTES) + 1)
            .unwrap();

        let decisions = decisions(captures);
        assert_eq!(
            decisions["phone.scrawl"]["attachments"],
            json!([
                "summary.md",
                "contact-sheet.png",
                "scrawl.json",
                "Composer.log",
                "frame-01.png",
                "frame-02.png",
                "frame-03.png",
                "frame-04.png"
            ])
        );
        assert_eq!(
            decisions["mac.scrawl"]["attachments"],
            json!([
                "summary.md",
                "contact-sheet.png",
                "scrawl.json",
                "frame-02.png",
                "recording.mp4"
            ])
        );
    }

    #[test]
    fn description_puts_typed_text_before_narration_within_4096_bytes() {
        let captures = tempfile::tempdir().unwrap();
        let captures = captures.path();
        let narrated = manifest(
            "  The button stays grey\nwhen I tap it.  ",
            0,
            Some("iphone"),
        );
        write(
            captures,
            "typed.scrawl",
            &narrated,
            Some(&phone_timeline(COORDINATOR, "Send stays grey after paste")),
        );
        let long = "€".repeat(2000);
        write(
            captures,
            "long.scrawl",
            &narrated,
            Some(&phone_timeline(COORDINATOR, &long)),
        );
        write(captures, "silent.scrawl", &manifest("", 0, None), None);

        let decisions = decisions(captures);
        assert_eq!(
            decisions["typed.scrawl"]["description"],
            "Send stays grey after paste Narration: The button stays grey when I tap it."
        );
        let bounded = decisions["long.scrawl"]["description"].as_str().unwrap();
        assert_eq!(bounded.len(), 4095);
        assert!(long.starts_with(bounded));
        assert_eq!(
            decisions["silent.scrawl"]["description"],
            "Scrawl capture silent.scrawl"
        );
    }

    #[tokio::test]
    async fn first_start_backlogs_existing_captures_and_takes_only_new_ones() {
        let captures = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        write(captures.path(), "old.scrawl", &manifest("", 1, None), None);
        let dialer = Unreachable(AtomicUsize::new(0));

        let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
        watcher.poll(&dialer).await;
        assert_eq!(dialer.0.load(Ordering::SeqCst), 0);
        assert!(matches!(
            watcher.state("old.scrawl"),
            Some(BundleState::Backlog)
        ));

        write(captures.path(), "new.scrawl", &manifest("", 1, None), None);
        watcher.poll(&dialer).await;
        assert_eq!(dialer.0.load(Ordering::SeqCst), 1);
        drop(watcher);

        let mut restarted = Watcher::open(captures.path(), state.path()).unwrap();
        assert!(matches!(
            restarted.state("old.scrawl"),
            Some(BundleState::Backlog)
        ));
        restarted.poll(&dialer).await;
        assert_eq!(
            dialer.0.load(Ordering::SeqCst),
            2,
            "Only the new capture is attempted again after a restart"
        );
    }

    #[tokio::test]
    async fn a_failed_attempt_waits_instead_of_spinning() {
        let captures = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let dialer = Unreachable(AtomicUsize::new(0));
        let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
        write(captures.path(), "new.scrawl", &manifest("", 1, None), None);
        for _ in 0..3 {
            watcher.poll(&dialer).await;
        }
        assert_eq!(dialer.0.load(Ordering::SeqCst), 1);
        assert!(watcher.state("new.scrawl").is_none());
    }

    #[tokio::test]
    async fn unfinished_bundles_wait_for_summary_and_transcript() {
        let captures = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let dialer = Unreachable(AtomicUsize::new(0));
        let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
        let bundle = write(captures.path(), "new.scrawl", &manifest("", 1, None), None);
        fs::write(bundle.join("summary.md"), "# Still writing\n").unwrap();
        watcher.poll(&dialer).await;
        settle(&bundle);
        fs::write(bundle.join(".transcript-pending"), "").unwrap();
        watcher.poll(&dialer).await;
        assert_eq!(dialer.0.load(Ordering::SeqCst), 0);
        fs::remove_file(bundle.join(".transcript-pending")).unwrap();
        watcher.poll(&dialer).await;
        assert_eq!(dialer.0.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn dry_run_reports_the_ledger_and_writes_nothing() {
        let captures = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let unstarted = state.path().join("unstarted");
        write(captures.path(), "old.scrawl", &manifest("", 1, None), None);
        let unfinished = write(
            captures.path(),
            "unfinished.scrawl",
            &manifest("", 1, None),
            None,
        );
        fs::remove_file(unfinished.join("summary.md")).unwrap();

        let first_start = previews(captures.path(), &unstarted);
        assert_eq!(first_start["old.scrawl"]["decision"], "backlog");
        assert_eq!(first_start["unfinished.scrawl"]["decision"], "backlog");
        assert!(!unstarted.exists(), "A dry run creates no state directory");

        let mut watcher = Watcher::open(captures.path(), state.path()).unwrap();
        write(
            captures.path(),
            "no-target.scrawl",
            &manifest("", 1, Some("iphone")),
            Some(&json!({"app": "Other"})),
        );
        watcher.poll(&Unreachable(AtomicUsize::new(0))).await;
        write(captures.path(), "new.scrawl", &manifest("", 1, None), None);
        let ledger = fs::read(state.path().join("scrawl-feedback.json")).unwrap();

        let running = previews(captures.path(), state.path());
        assert_eq!(running["old.scrawl"]["decision"], "backlog");
        assert_eq!(running["unfinished.scrawl"]["decision"], "backlog");
        assert_eq!(running["no-target.scrawl"]["decision"], "refused");
        assert_eq!(
            running["no-target.scrawl"]["reason"],
            "The phone recording names no Beep Boop coordinator"
        );
        assert_eq!(running["new.scrawl"]["decision"], "deliver");
        assert_eq!(
            fs::read(state.path().join("scrawl-feedback.json")).unwrap(),
            ledger,
            "A dry run leaves the ledger unchanged"
        );
        drop(watcher);
    }

    #[test]
    fn one_watcher_owns_a_state_directory() {
        let captures = tempfile::tempdir().unwrap();
        let state = tempfile::tempdir().unwrap();
        let first = Watcher::open(captures.path(), state.path()).unwrap();
        assert!(Watcher::open(captures.path(), state.path()).is_err());
        let inherited = first.lock.try_clone().unwrap();
        drop(first);
        assert!(
            Watcher::open(captures.path(), state.path()).is_ok(),
            "A descriptor a forked child still holds does not keep the lock"
        );
        drop(inherited);
    }
}
