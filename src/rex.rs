//! Typed Rex CLI boundary. No automatic mutation retries.
//! Native schemas are discovered per server with `rex api describe`.

pub mod actions;
pub mod install;
pub mod source;

use crate::serialized_spawn::SerializedTokioSpawn;
use std::fmt;
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Deserializer, Serialize};
use tokio::io::AsyncReadExt;
use tokio::process::Command;
use uuid::Uuid;

const CALL_TIMEOUT: Duration = Duration::from_secs(8);
const MAX_OUTPUT_BYTES: u64 = 1024 * 1024;
const MAX_ERROR_BYTES: u64 = 16 * 1024;

#[derive(Debug, PartialEq, Eq)]
pub enum RexError {
    InvalidInput,
    InvalidId,
    Unavailable,
    /// The selected server was not running, so the request never reached Rex.
    ServerDown {
        location: String,
    },
    ReadFailed,
    OutputTooLarge,
    InvalidResponse,
    BindingMismatch,
    SessionNotFound,
    CreationUncertain {
        session_id: Option<SessionId>,
    },
}
impl fmt::Display for RexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidInput => f.write_str("Invalid Rex worker request"),
            Self::InvalidId => f.write_str("Invalid Rex resource identifier"),
            Self::Unavailable => f.write_str("Rex CLI is unavailable"),
            Self::ServerDown { location } => write!(f, "No Rex server is running at {location}"),
            Self::ReadFailed => f.write_str("Rex read failed or timed out"),
            Self::OutputTooLarge => f.write_str("Rex response exceeds the supported size limit"),
            Self::InvalidResponse => f.write_str("Rex returned an unsupported response"),
            Self::BindingMismatch => f.write_str("Rex session does not match its recorded worker binding"),
            Self::SessionNotFound => f.write_str("The recorded Rex session no longer exists"),
            Self::CreationUncertain { .. } => f.write_str("Rex session creation is uncertain; reconcile the original allocation before retrying"),
        }
    }
}
impl std::error::Error for RexError {}

macro_rules! native_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Clone, Debug, PartialEq, Eq, Hash, Deserialize, Serialize)]
        #[serde(try_from = "String", into = "String")]
        pub struct $name(String);
        impl $name {
            pub fn parse(value: &str) -> Result<Self, RexError> {
                let uuid = value.strip_prefix($prefix).ok_or(RexError::InvalidId)?;
                let uuid = Uuid::parse_str(uuid).map_err(|_| RexError::InvalidId)?;
                if uuid.is_nil() {
                    return Err(RexError::InvalidId);
                }
                Ok(Self(format!("{}{}", $prefix, uuid)))
            }
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }
        impl TryFrom<String> for $name {
            type Error = RexError;
            fn try_from(value: String) -> Result<Self, Self::Error> {
                Self::parse(&value)
            }
        }
        impl From<$name> for String {
            fn from(value: $name) -> Self {
                value.0
            }
        }
        impl fmt::Display for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(&self.0)
            }
        }
    };
}
native_id!(SessionId, "session:");
native_id!(BlockId, "block:");
native_id!(WindowId, "window:");
native_id!(HostId, "");

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RexIdentity {
    pub host_id: HostId,
    pub instance_id: Uuid,
    pub rex_version: String,
    pub endpoint: Option<String>,
    pub tailscale: Option<RexTailnet>,
}

#[derive(Deserialize)]
struct PeerInventory {
    #[serde(default)]
    hosts: Vec<RexPeer>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RexPeer {
    pub host_id: Option<String>,
    pub label: String,
    pub endpoints: Option<Vec<String>>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RexTailnet {
    pub dns_name: Option<String>,
    pub https: Option<RexHttps>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RexHttps {
    pub state: String,
    pub url: Option<String>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionSummary {
    pub session_id: SessionId,
    pub label: String,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct WorkerBinding {
    pub session_id: SessionId,
    pub window_id: WindowId,
    pub block_id: BlockId,
    pub revision: u64,
}

pub enum WorkerResume {
    Running,
    Pending,
    Started(WorkerBinding),
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct SessionView {
    pub session_id: SessionId,
    pub revision: u64,
    pub label: Option<String>,
    #[serde(default, deserialize_with = "nullable_vec")]
    pub windows: Vec<WindowView>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct WindowView {
    pub window_id: Option<WindowId>,
    #[serde(deserialize_with = "nullable_vec")]
    pub layers: Vec<LayerView>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct LayerView {
    #[serde(deserialize_with = "nullable_vec")]
    pub blocks: Vec<BlockView>,
}
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct BlockView {
    pub block_id: Option<BlockId>,
    pub host_id: Option<HostId>,
    pub flavor: Option<String>,
    pub label: Option<String>,
}
/// The Rex pane this process runs in, as Rex names it to a pane's program.
/// Rex 0.1.0-snapshot.2629 sets `REX_BLOCK` but no `REX_SESSION` for a
/// direct-command pane.
#[derive(Debug, PartialEq, Eq)]
pub struct RexPane {
    block: BlockId,
    session: Option<SessionId>,
}

impl RexPane {
    pub fn from_env() -> Result<Option<Self>, RexError> {
        Self::parse(
            std::env::var("REX_BLOCK").ok().as_deref(),
            std::env::var("REX_SESSION").ok().as_deref(),
        )
    }

    fn parse(block: Option<&str>, session: Option<&str>) -> Result<Option<Self>, RexError> {
        let Some(block) = block else {
            return Ok(None);
        };
        Ok(Some(Self {
            block: BlockId::parse(block)?,
            session: session.map(SessionId::parse).transpose()?,
        }))
    }

    pub fn block(&self) -> &BlockId {
        &self.block
    }
}

impl SessionView {
    fn window_holding(&self, block: &BlockId) -> Option<&WindowId> {
        self.windows
            .iter()
            .find(|window| {
                window
                    .layers
                    .iter()
                    .flat_map(|layer| &layer.blocks)
                    .any(|candidate| candidate.block_id.as_ref() == Some(block))
            })
            .and_then(|window| window.window_id.as_ref())
    }

    pub fn verify_binding(&self, binding: &WorkerBinding, host: &HostId) -> Result<(), RexError> {
        if self.session_id != binding.session_id {
            return Err(RexError::BindingMismatch);
        }
        let matches = self
            .windows
            .iter()
            .filter(|window| window.window_id.as_ref() == Some(&binding.window_id))
            .flat_map(|window| &window.layers)
            .flat_map(|layer| &layer.blocks)
            .filter(|block| block.block_id.as_ref() == Some(&binding.block_id))
            .any(|block| {
                block.host_id.as_ref() == Some(host)
                    && block.flavor.as_deref() == Some("com.superlogical.terminal.shell")
            });
        if matches {
            Ok(())
        } else {
            Err(RexError::BindingMismatch)
        }
    }
}

#[derive(Clone, Debug)]
pub struct RexClient {
    route: RexRoute,
}

#[derive(Clone, Debug)]
enum RexRoute {
    /// The CLI's own selection: `REX_SERVER`, else the account's local server.
    Personal,
    /// `REX_SERVER` is removed because Rex falls back to the personal server
    /// when that variable names a dead socket.
    Private(LocalRexEndpoint),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum EndpointKind {
    Unix,
    Ssh,
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct LocalRexEndpoint {
    raw: String,
    kind: EndpointKind,
}

impl LocalRexEndpoint {
    fn parse(input: &str) -> anyhow::Result<Self> {
        if let Some(rest) = input.strip_prefix("unix://") {
            let path = Path::new(rest);
            anyhow::ensure!(
                path.is_absolute()
                    && path.file_name().is_some()
                    && !input.contains(['\0', '?', '#']),
                "--rex-server must be unix:// followed by an absolute socket path, not {input:?}"
            );
            return Ok(Self {
                raw: input.to_owned(),
                kind: EndpointKind::Unix,
            });
        }
        if let Some(rest) = input.strip_prefix("ssh://") {
            anyhow::ensure!(
                valid_ssh_authority(rest),
                "--rex-server ssh:// endpoint must be ssh://[user@]host[:port], not {input:?}"
            );
            return Ok(Self {
                raw: input.to_owned(),
                kind: EndpointKind::Ssh,
            });
        }
        anyhow::bail!(
            "--rex-server must be unix:///... or ssh://[user@]host[:port], not {input:?}"
        );
    }

    fn as_str(&self) -> &str {
        &self.raw
    }
}

fn valid_ssh_authority(authority: &str) -> bool {
    if authority.is_empty()
        || authority.len() > 320
        || authority
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace() || matches!(ch, '/' | '?' | '#' | '\\'))
    {
        return false;
    }
    let host_port = if let Some((user, rest)) = authority.split_once('@') {
        if user.is_empty()
            || user.len() > 64
            || user.starts_with('-')
            || !user
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-' | b'+'))
        {
            return false;
        }
        rest
    } else {
        authority
    };
    if host_port.is_empty() || host_port.contains('@') {
        return false;
    }
    let host = if let Some(bracketed) = host_port.strip_prefix('[') {
        let Some((ipv6, suffix)) = bracketed.split_once(']') else {
            return false;
        };
        if ipv6.is_empty()
            || !ipv6
                .bytes()
                .all(|b| b.is_ascii_hexdigit() || b == b':' || b == b'.')
        {
            return false;
        }
        if !suffix.is_empty() {
            let Some(port) = suffix.strip_prefix(':') else {
                return false;
            };
            if port.parse::<u16>().ok().filter(|p| *p > 0).is_none() {
                return false;
            }
        }
        return true;
    } else if let Some((host, port)) = host_port.rsplit_once(':') {
        if host.contains(':') || port.parse::<u16>().ok().filter(|p| *p > 0).is_none() {
            return false;
        }
        host
    } else {
        host_port
    };
    !host.is_empty()
        && !host.starts_with('-')
        && host
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplePrivacyPreflight {
    Granted,
    Missing {
        status: String,
        responsible_path: Option<String>,
    },
    NotApplicable,
    UnsupportedServer,
}

impl ApplePrivacyPreflight {
    pub fn warning_message(&self) -> Option<String> {
        let Self::Missing {
            status,
            responsible_path,
        } = self
        else {
            return None;
        };
        let target = responsible_path
            .as_deref()
            .filter(|path| !path.trim().is_empty())
            .unwrap_or("Rex");
        Some(format!(
            "Rex Full Disk Access is {status}. Grant Full Disk Access to {target} in macOS System Settings -> Privacy & Security -> Full Disk Access so Messages reads succeed."
        ))
    }
}

pub(crate) fn personal_messages() -> RexClient {
    RexClient {
        route: RexRoute::Personal,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum TerminalCapture {
    Html(String),
    Text(String),
}

impl RexClient {
    /// The live-session list is not an existence check. Inspect the recorded
    /// session directly, and accept absence only from its native 404 status.
    pub async fn worker_presence(
        &self,
        binding: &WorkerBinding,
        started_by: Option<Uuid>,
        host: &HostId,
    ) -> Result<crate::protocol::WorkerPresence, RexError> {
        use crate::protocol::WorkerPresence;
        let view = match self.inspect_session(&binding.session_id).await {
            Ok(view) => view,
            Err(RexError::SessionNotFound) => return Ok(WorkerPresence::MissingSession),
            Err(error) => return Err(error),
        };
        let found = view
            .windows
            .iter()
            .flat_map(|window| &window.layers)
            .flat_map(|layer| &layer.blocks)
            .any(|block| block.block_id.as_ref() == Some(&binding.block_id));
        if !found {
            return Ok(WorkerPresence::MissingTerminal);
        }
        view.verify_binding(binding, host)?;
        Ok(match self.pane_holds(binding, started_by).await? {
            PaneHolds::Worker => WorkerPresence::Present { running: true },
            PaneHolds::OtherProcess | PaneHolds::Exited => {
                WorkerPresence::Present { running: false }
            }
            PaneHolds::Pending => WorkerPresence::Pending,
        })
    }

    /// Rex restores a saved pane with a fresh shell under a new instance, so a
    /// process is the worker only while the instance that started it runs.
    /// That instance is read after the process, so a restart between the two
    /// reads cannot pass a restored shell off as the worker.
    async fn pane_holds(
        &self,
        binding: &WorkerBinding,
        started_by: Option<Uuid>,
    ) -> Result<PaneHolds, RexError> {
        let process: TerminalProcess =
            decode(&self.terminal_process(binding).await.map_err(read_failure)?)?;
        Ok(match (process.state(), started_by) {
            (TerminalState::Exited, _) => PaneHolds::Exited,
            (TerminalState::Pending, _) => PaneHolds::Pending,
            (TerminalState::Running, None) => PaneHolds::OtherProcess,
            (TerminalState::Running, Some(instance)) => {
                if self.whoami().await?.instance_id == instance {
                    PaneHolds::Worker
                } else {
                    PaneHolds::OtherProcess
                }
            }
        })
    }

    async fn terminal_process(&self, pane: &WorkerBinding) -> Result<Vec<u8>, CallFailure> {
        self.api(
            "com.superlogical.terminal.process",
            &ProcessRequest {
                session_id: pane.session_id.clone(),
                block_id: pane.block_id.clone(),
                args: Empty {},
            },
        )
        .await
    }

    async fn read_pane(&self, pane: &WorkerBinding) -> Result<PaneRead, RexError> {
        let process: TerminalProcess = match self.terminal_process(pane).await {
            Ok(output) => decode(&output)?,
            Err(failure) if failure.is_missing() => return Ok(PaneRead::Gone),
            Err(failure) => return Err(read_failure(failure)),
        };
        Ok(PaneRead::Holds {
            process: process.state(),
            instance: self.whoami().await?.instance_id,
        })
    }

    async fn listed_block(&self, pane: &WorkerBinding) -> Result<Option<ListedBlock>, RexError> {
        let request = SessionRequest {
            session_id: pane.session_id.clone(),
        };
        let listed: BlockList = match self.api("session.list_blocks", &request).await {
            Ok(output) => decode(&output)?,
            Err(failure) if failure.is_missing() => return Ok(None),
            Err(failure) => return Err(read_failure(failure)),
        };
        Ok(listed
            .blocks
            .into_iter()
            .find(|block| block.block_id.as_deref() == Some(pane.block_id.as_str())))
    }

    /// A create is confirmed when its pane verifies, and Rex is still the
    /// host and instance that `identity` read before the create. The worker
    /// reads its own Rex instance when it starts, and its claim must match
    /// the receipt. A restart around the create leaves the earlier read
    /// naming another instance.
    pub async fn confirm_creation(&self, binding: &WorkerBinding, identity: &RexIdentity) -> bool {
        self.verify_recorded_pane(binding, &identity.host_id)
            .await
            .is_ok()
            && self.whoami().await.is_ok_and(|after| {
                after.instance_id == identity.instance_id && after.host_id == identity.host_id
            })
    }

    /// A recorded pane verifies its session while Rex shows it in its window
    /// on this host. It also verifies once it has closed with its program,
    /// when Rex still has the session and no longer has the block. A block
    /// that Rex still has anywhere else proves nothing.
    pub async fn verify_recorded_pane(
        &self,
        binding: &WorkerBinding,
        host: &HostId,
    ) -> Result<(), RexError> {
        let view = self.inspect_session(&binding.session_id).await?;
        let Err(mismatch) = view.verify_binding(binding, host) else {
            return Ok(());
        };
        match self.listed_block(binding).await? {
            None => Ok(()),
            Some(_) => Err(mismatch),
        }
    }

    pub fn for_process(server: Option<&str>) -> anyhow::Result<Self> {
        let route = match server {
            None => RexRoute::Personal,
            Some(server) => RexRoute::Private(LocalRexEndpoint::parse(server)?),
        };
        Ok(Self { route })
    }

    /// The server the runtime's Rex SDK reaches: this process's own Rex, so
    /// SDK calls land where its local workers run. `personal` keeps the SDK's
    /// own selection, which follows `REX_SERVER` like the CLI; a private Unix
    /// server is its socket path. An SSH endpoint has no SDK transport, so the
    /// runtime gets no Rex tools.
    pub fn sdk_server(&self) -> Option<&str> {
        match &self.route {
            RexRoute::Personal => Some("personal"),
            // The SDK takes a bare absolute path verbatim, but parses a
            // unix:// URL: it decodes escapes, resolves `..` and trims. A path
            // it could read differently gets no SDK at all.
            RexRoute::Private(endpoint) if endpoint.kind == EndpointKind::Unix => {
                let path = endpoint.as_str().strip_prefix("unix://")?;
                // Rust's trim and JavaScript's differ on U+FEFF; keep to ASCII.
                let plain = path.is_ascii()
                    && path.trim() == path
                    && !path.contains('%')
                    && !path.chars().any(char::is_control)
                    // Path::components() hides `.`, so read the segments.
                    && path.strip_prefix('/').is_some_and(|rest| {
                        rest.split('/').all(|part| !matches!(part, "" | "." | ".."))
                    });
                plain.then_some(path)
            }
            RexRoute::Private(_) => None,
        }
    }

    pub fn is_private(&self) -> bool {
        matches!(self.route, RexRoute::Private(_))
    }

    pub fn ssh_endpoint(&self) -> Option<&str> {
        match &self.route {
            RexRoute::Private(endpoint) if endpoint.kind == EndpointKind::Ssh => {
                Some(endpoint.as_str())
            }
            _ => None,
        }
    }

    pub fn is_local_unix_socket(&self) -> bool {
        match &self.route {
            RexRoute::Personal => true,
            RexRoute::Private(endpoint) => endpoint.kind == EndpointKind::Unix,
        }
    }

    pub fn rex_server_args(&self) -> Vec<String> {
        match &self.route {
            RexRoute::Personal => Vec::new(),
            RexRoute::Private(endpoint) => {
                vec!["--rex-server".into(), endpoint.as_str().to_owned()]
            }
        }
    }

    /// `rex hosts` reads the account's home inventory and ignores `--server`,
    /// so a private server has none of its own.
    pub async fn peer_inventory(&self) -> Option<Vec<RexPeer>> {
        if self.is_private() {
            return None;
        }
        let args = ["--autostart=false".into(), "hosts".into(), "--json".into()];
        let request = crate::host::ProcessRequest::new(
            "rex",
            &args,
            Path::new("/"),
            Duration::from_secs(15),
            256 * 1024,
        )
        .ok()?;
        let crate::host::ProcessOutput {
            exit_code: 0,
            stdout,
            truncated: false,
            ..
        } = crate::host::run_process(request).await.ok()?
        else {
            return None;
        };
        serde_json::from_str::<PeerInventory>(&stdout)
            .ok()
            .map(|inventory| inventory.hosts)
    }

    pub async fn whoami(&self) -> Result<RexIdentity, RexError> {
        let output = self
            .run(vec!["whoami".to_owned(), "--json".to_owned()])
            .await
            .map_err(read_failure)?;
        decode(&output)
    }

    /// Preflight macOS Full Disk Access without triggering a TCC prompt.
    /// Queries only over a local Unix socket and skips non-macOS or older servers.
    pub async fn full_disk_access_preflight(&self) -> Result<ApplePrivacyPreflight, RexError> {
        #[derive(Deserialize)]
        struct ServerVersion {
            platform: Option<String>,
        }
        #[derive(Deserialize)]
        struct ApplePrivacyStatus {
            #[serde(default)]
            services: Vec<ApplePrivacyService>,
            responsible_path: Option<String>,
        }
        #[derive(Deserialize)]
        struct ApplePrivacyService {
            service: String,
            status: String,
        }

        if !self.is_local_unix_socket() {
            return Ok(ApplePrivacyPreflight::NotApplicable);
        }
        let version: ServerVersion = match self.api("server.version", &Empty {}).await {
            Ok(bytes) => decode(&bytes)?,
            Err(CallFailure::MethodNotFound | CallFailure::Forbidden) => {
                return Ok(ApplePrivacyPreflight::UnsupportedServer);
            }
            Err(error) => return Err(read_failure(error)),
        };
        if !version
            .platform
            .as_deref()
            .is_some_and(|platform| platform.starts_with("darwin"))
        {
            return Ok(ApplePrivacyPreflight::NotApplicable);
        }
        let privacy: ApplePrivacyStatus =
            match self.api("server.apple.privacy_status", &Empty {}).await {
                Ok(bytes) => decode(&bytes)?,
                Err(CallFailure::MethodNotFound | CallFailure::Forbidden) => {
                    return Ok(ApplePrivacyPreflight::UnsupportedServer);
                }
                Err(error) => return Err(read_failure(error)),
            };
        let Some(fda) = privacy
            .services
            .into_iter()
            .find(|service| service.service == "full_disk_access")
        else {
            return Ok(ApplePrivacyPreflight::NotApplicable);
        };
        if fda.status == "granted" {
            Ok(ApplePrivacyPreflight::Granted)
        } else {
            Ok(ApplePrivacyPreflight::Missing {
                status: fda.status,
                responsible_path: privacy.responsible_path,
            })
        }
    }

    async fn format_capture(
        &self,
        session: &SessionId,
        block: &BlockId,
        format: &str,
    ) -> Result<String, CallFailure> {
        #[derive(Serialize)]
        struct FormatRequest<'a> {
            session_id: &'a SessionId,
            block_id: &'a BlockId,
            args: FormatArgs<'a>,
        }
        #[derive(Serialize)]
        struct FormatArgs<'a> {
            format: &'a str,
            trim: bool,
            max_bytes: usize,
        }
        #[derive(Deserialize)]
        struct FormatReply {
            #[serde(default)]
            content: String,
            id: Option<u64>,
            eof: Option<bool>,
            total: Option<usize>,
        }
        #[derive(Serialize)]
        struct BlobRequest<'a> {
            session_id: &'a SessionId,
            block_id: &'a BlockId,
            args: BlobArgs,
        }
        #[derive(Serialize)]
        struct BlobArgs {
            id: u64,
            offset: usize,
            max_bytes: usize,
        }
        #[derive(Deserialize)]
        struct BlobReply {
            data: String,
            eof: bool,
        }

        const CHUNK_BYTES: usize = 256 * 1024;
        let max_total = usize::try_from(MAX_OUTPUT_BYTES).unwrap_or(usize::MAX);
        let reply: FormatReply = serde_json::from_slice(
            &self
                .api(
                    "com.superlogical.terminal.format",
                    &FormatRequest {
                        session_id: session,
                        block_id: block,
                        args: FormatArgs {
                            format,
                            trim: true,
                            max_bytes: CHUNK_BYTES,
                        },
                    },
                )
                .await?,
        )
        .map_err(|_| CallFailure::Failed)?;
        if reply.total.is_some_and(|total| total > max_total) {
            return Err(CallFailure::OutputTooLarge);
        }
        let mut out = reply.content;
        if out.len() > max_total {
            return Err(CallFailure::OutputTooLarge);
        }
        let mut done = reply.eof.unwrap_or(reply.id.is_none());
        if !done && let Some(id) = reply.id {
            while !done && out.len() < max_total {
                let remaining = max_total - out.len();
                let chunk: BlobReply = serde_json::from_slice(
                    &self
                        .api(
                            "com.superlogical.terminal.blob_read",
                            &BlobRequest {
                                session_id: session,
                                block_id: block,
                                args: BlobArgs {
                                    id,
                                    offset: out.len(),
                                    max_bytes: remaining.min(CHUNK_BYTES),
                                },
                            },
                        )
                        .await?,
                )
                .map_err(|_| CallFailure::Failed)?;
                if chunk.data.is_empty() {
                    break;
                }
                if chunk.data.len() > remaining {
                    return Err(CallFailure::OutputTooLarge);
                }
                out.push_str(&chunk.data);
                done = chunk.eof;
            }
            if !done {
                return Err(CallFailure::OutputTooLarge);
            }
        }
        if out.is_empty() {
            return Err(CallFailure::Failed);
        }
        Ok(out)
    }

    async fn cli_capture(
        &self,
        session: &SessionId,
        block: &BlockId,
        format: &str,
    ) -> Result<String, CallFailure> {
        let output = self
            .run(vec![
                "capture".to_owned(),
                "--session".to_owned(),
                session.to_string(),
                "--block".to_owned(),
                block.to_string(),
                "--format".to_owned(),
                format.to_owned(),
                "--trim".to_owned(),
            ])
            .await?;
        let text = String::from_utf8(output).map_err(|_| CallFailure::Failed)?;
        if text.is_empty() {
            return Err(CallFailure::Failed);
        }
        Ok(text)
    }

    async fn capture_terminal_via(
        &self,
        session: &SessionId,
        block: &BlockId,
        path: CapturePath,
    ) -> Result<TerminalCapture, CallFailure> {
        let capture = |format| async move {
            match path {
                CapturePath::Rpc => self.format_capture(session, block, format).await,
                CapturePath::Cli => self.cli_capture(session, block, format).await,
            }
        };
        match capture("html").await {
            Ok(html) => Ok(TerminalCapture::Html(html)),
            // Styling can exceed our byte bound while trimmed text still fits.
            Err(CallFailure::OutputTooLarge) => capture("text").await.map(TerminalCapture::Text),
            Err(error) => Err(error),
        }
    }

    /// Capture only the explicitly owned terminal, never the client's focused pane.
    pub async fn capture_terminal(
        &self,
        session: &SessionId,
        block: &BlockId,
    ) -> Result<TerminalCapture, RexError> {
        match self
            .capture_terminal_via(session, block, CapturePath::Rpc)
            .await
        {
            Err(CallFailure::MethodNotFound) => self
                .capture_terminal_via(session, block, CapturePath::Cli)
                .await
                .map_err(read_failure),
            other => other.map_err(read_failure),
        }
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionSummary>, RexError> {
        let output = self
            .api("session.list", &Empty {})
            .await
            .map_err(read_failure)?;
        let result: SessionList = decode(&output)?;
        Ok(result.sessions)
    }

    pub async fn create_worker_window(
        &self,
        session: &SessionId,
        title: &str,
        program: &str,
        args: &[String],
        cwd: &Path,
    ) -> Result<WorkerBinding, RexError> {
        let request = CreateRequest::worker(title, program, args, cwd)?;
        let [window] = request.initial_windows;
        let mut block = window.layout.block;
        block.label = title.to_owned();
        self.new_window(session, title, block).await
    }

    pub async fn promote_session(&self, session: &SessionId) -> Result<(), RexError> {
        let sessions = self.list_sessions().await?;
        if sessions
            .first()
            .is_some_and(|first| first.session_id == *session)
        {
            return Ok(());
        }
        let before = sessions
            .iter()
            .find(|other| other.session_id != *session)
            .map(|other| other.session_id.clone());
        self.api(
            "session.move",
            &MoveSession {
                session_id: session.clone(),
                before_session_id: before,
            },
        )
        .await
        .map_err(read_failure)?;
        Ok(())
    }

    /// The session and window that hold `pane`, or `None` when the pane is
    /// gone or its `REX_SESSION` does not hold it.
    pub async fn locate_pane(
        &self,
        pane: &RexPane,
    ) -> Result<Option<(SessionId, WindowId)>, RexError> {
        let session = match &pane.session {
            Some(session) => session.clone(),
            None => match self.block_session(&pane.block).await? {
                Some(session) => session,
                None => return Ok(None),
            },
        };
        let view = self.inspect_session(&session).await?;
        Ok(view
            .window_holding(&pane.block)
            .map(|window| (session, window.clone())))
    }

    /// Without a context, target.resolve searches every session for a full
    /// block ID.
    async fn block_session(&self, block: &BlockId) -> Result<Option<SessionId>, RexError> {
        let output = self
            .api(
                "target.resolve",
                &ResolveRequest {
                    kinds: ["block"],
                    queries: [block],
                },
            )
            .await
            .map_err(read_failure)?;
        let reply: ResolveReply = decode(&output)?;
        Ok(reply
            .results
            .into_iter()
            .filter(|result| result.status == "resolved")
            .filter_map(|result| result.target)
            .find(|target| target.block_id == *block)
            .map(|target| target.session_id))
    }

    pub async fn inspect_session(&self, session: &SessionId) -> Result<SessionView, RexError> {
        let output = self
            .api(
                "session.view",
                &SessionRequest {
                    session_id: session.clone(),
                },
            )
            .await
            .map_err(read_failure)?;
        let view: SessionView = decode(&output)?;
        if view.session_id != *session {
            return Err(RexError::BindingMismatch);
        }
        Ok(view)
    }

    /// Dedicated workspace ownership is durable in the coordinator, not inferred
    /// from this display label. Its first task gets a named window too.
    pub async fn create_workspace_session(
        &self,
        title: &str,
        program: &str,
        args: &[String],
        cwd: &Path,
    ) -> Result<WorkerBinding, RexError> {
        let mut request = CreateRequest::worker(title, program, args, cwd)?;
        request.label = "Beep Boop".to_owned();
        request.initial_windows[0].window_label = title.to_owned();
        request.initial_windows[0].layout.block.label = title.to_owned();
        let output = self
            .api("session.create", &request)
            .await
            .map_err(|error| creation_failure(error, None))?;
        decode_creation(&output)
    }

    /// One native create attempt. Lost or malformed receipts never authorize a retry.
    pub async fn create_session(
        &self,
        title: &str,
        program: &str,
        args: &[String],
        cwd: &Path,
    ) -> Result<WorkerBinding, RexError> {
        let request = CreateRequest::worker(title, program, args, cwd)?;
        let output = self
            .api("session.create", &request)
            .await
            .map_err(|error| creation_failure(error, None))?;
        decode_creation(&output)
    }

    /// Keep a live or starting worker. Replace an exited pane, or a pane whose
    /// process is not the worker, with a new window in the same session.
    pub async fn resume_worker(
        &self,
        binding: &WorkerBinding,
        started_by: Option<Uuid>,
        identity: &RexIdentity,
        program: &str,
        args: &[String],
        cwd: &Path,
    ) -> Result<WorkerResume, RexError> {
        for attempt in 0..20 {
            match self.pane_holds(binding, started_by).await? {
                PaneHolds::Exited | PaneHolds::OtherProcess => break,
                PaneHolds::Worker if attempt == 19 => return Ok(WorkerResume::Running),
                PaneHolds::Pending if attempt == 19 => return Ok(WorkerResume::Pending),
                PaneHolds::Worker | PaneHolds::Pending => {}
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let request = CreateRequest::worker("Chat", program, args, cwd)?;
        let [window] = request.initial_windows;
        let replacement = self
            .new_window(
                &binding.session_id,
                &window.window_label,
                window.layout.block,
            )
            .await?;
        // Once creation succeeded, every later failure must retain uncertainty
        // about this same session rather than authorize another allocation.
        if !self.confirm_creation(&replacement, identity).await {
            return Err(RexError::CreationUncertain {
                session_id: Some(binding.session_id.clone()),
            });
        }
        match self.close_superseded(binding, started_by).await {
            OldPane::Closed => {}
            OldPane::HandedOver => eprintln!(
                "Rex worker pane {} stays open for you; its replacement is running.",
                binding.block_id
            ),
            OldPane::MaybeDetached => eprintln!(
                "Rex worker pane {} may be detached from every window; its replacement is running.",
                binding.block_id
            ),
        }
        Ok(WorkerResume::Started(replacement))
    }

    /// Close the pane a replacement superseded if it holds the worker's own
    /// exit. The conversation lives in Pi, so closing loses nothing. Anything
    /// else in the pane stays where the user can see it.
    async fn close_superseded(&self, pane: &WorkerBinding, started_by: Option<Uuid>) -> OldPane {
        let mut step = GuardedClose::Read;
        loop {
            step = match self.guarded_close_step(pane, started_by, step).await {
                GuardedClose::Done(old) => return old,
                next => next,
            };
        }
    }

    async fn guarded_close_step(
        &self,
        pane: &WorkerBinding,
        started_by: Option<Uuid>,
        step: GuardedClose,
    ) -> GuardedClose {
        let block = BlockRequest {
            session_id: pane.session_id.clone(),
            block_id: pane.block_id.clone(),
        };
        match step {
            GuardedClose::Read => match self.read_pane(pane).await {
                Ok(read) => after_read(started_by, read),
                Err(_) => GuardedClose::Done(OldPane::HandedOver),
            },
            GuardedClose::Detach { recorded } => {
                match self.api("session.detach_block", &block).await {
                    Ok(_) => GuardedClose::RecheckWhileDetached { recorded },
                    Err(failure) if failure.is_missing() => GuardedClose::Done(OldPane::Closed),
                    Err(_) => GuardedClose::PutBack,
                }
            }
            GuardedClose::RecheckWhileDetached { recorded } => match self.read_pane(pane).await {
                Ok(read) => after_recheck(recorded, read),
                Err(_) => GuardedClose::PutBack,
            },
            GuardedClose::Close => match self.api("block.close", &block).await {
                Ok(_) => GuardedClose::Done(OldPane::Closed),
                Err(failure) if failure.is_missing() => GuardedClose::Done(OldPane::Closed),
                Err(_) => GuardedClose::PutBack,
            },
            GuardedClose::PutBack => {
                GuardedClose::Done(self.put_back(pane).await.unwrap_or(OldPane::MaybeDetached))
            }
            done @ GuardedClose::Done(_) => done,
        }
    }

    /// Bring a detached pane back into view in a window of its own. Rex
    /// places a detached block only beside a placed one, so a placeholder
    /// holds the new window open until the pane arrives. A failed move says
    /// nothing certain. Its 404 may name the pane or a placeholder that
    /// already closed itself, and any other error may hide a move that
    /// landed. So the listing decides, and a pane still detached gets one
    /// fresh placeholder.
    async fn put_back(&self, pane: &WorkerBinding) -> Result<OldPane, RexError> {
        let mut placeholders_left = 2;
        loop {
            let Some(old) = self.listed_block(pane).await? else {
                return Ok(OldPane::Closed);
            };
            if old.placement == Placement::Placed {
                return Ok(OldPane::HandedOver);
            }
            if placeholders_left == 0 {
                return Ok(OldPane::MaybeDetached);
            }
            placeholders_left -= 1;
            let placeholder = self
                .new_window(&pane.session_id, &old.label, WorkerBlock::placeholder()?)
                .await?;
            let moved = self
                .api(
                    "session.move_block",
                    &MoveBlock {
                        session_id: pane.session_id.clone(),
                        block_id: pane.block_id.clone(),
                        anchor_block_id: placeholder.block_id,
                    },
                )
                .await;
            if moved.is_ok() {
                return Ok(OldPane::HandedOver);
            }
        }
    }

    async fn new_window(
        &self,
        session: &SessionId,
        label: &str,
        block: WorkerBlock,
    ) -> Result<WorkerBinding, RexError> {
        let uncertain = || RexError::CreationUncertain {
            session_id: Some(session.clone()),
        };
        let receipt = self
            .api(
                "session.new_window",
                &NewWindowRequest {
                    session_id: session.clone(),
                    window_label: label.to_owned(),
                    layout: SingleBlock { block },
                    focus: false,
                },
            )
            .await
            .map_err(|error| creation_failure(error, Some(session.clone())))?;
        let window: CreatedWindow = serde_json::from_slice(&receipt).map_err(|_| uncertain())?;
        let [block] = window.block_ids.as_slice() else {
            return Err(uncertain());
        };
        Ok(WorkerBinding {
            session_id: session.clone(),
            window_id: window.window_id,
            block_id: block.clone(),
            revision: window.revision,
        })
    }

    async fn api<T: Serialize>(&self, method: &str, request: &T) -> Result<Vec<u8>, CallFailure> {
        let payload = serde_json::to_string(request).map_err(|_| CallFailure::InvalidInput)?;
        self.run(vec![
            "api".to_owned(),
            "call".to_owned(),
            method.to_owned(),
            payload,
        ])
        .await
    }

    fn command(&self, args: &[String]) -> Command {
        let mut command = Command::new("rex");
        command.args(["--autostart=false", "--timeout", "8s"]);
        if let RexRoute::Private(endpoint) = &self.route {
            command
                .arg("--server")
                .arg(endpoint.as_str())
                .env_remove("REX_SERVER");
        }
        command
            .args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .env_remove("REX_SESSION")
            .env_remove("REX_BLOCK")
            .env_remove("REX_CLIENT")
            .kill_on_drop(true);
        command
    }

    async fn run(&self, args: Vec<String>) -> Result<Vec<u8>, CallFailure> {
        let mut command = self.command(&args);
        let mut child = command
            .spawn_serialized()
            .map_err(|_| CallFailure::Unavailable)?;
        let result = tokio::time::timeout(CALL_TIMEOUT, async {
            let stdout = child.stdout.take().ok_or(CallFailure::Failed)?;
            let stderr = child.stderr.take().ok_or(CallFailure::Failed)?;
            let (bytes, error, status) = tokio::try_join!(
                bounded_output(stdout, MAX_OUTPUT_BYTES),
                bounded_output(stderr, MAX_ERROR_BYTES),
                child.wait(),
            )
            .map_err(|_| CallFailure::Failed)?;
            if bytes.len() as u64 > MAX_OUTPUT_BYTES {
                return Err(CallFailure::OutputTooLarge);
            }
            if error.len() as u64 > MAX_ERROR_BYTES {
                return Err(classify_common_error(&error).unwrap_or(CallFailure::Failed));
            }
            if !status.success() {
                if status.code() == Some(4)
                    && let Some(location) = std::str::from_utf8(&error)
                        .ok()
                        .and_then(server_down_location)
                {
                    return Err(CallFailure::ServerDown { location });
                }
                if std::str::from_utf8(&error)
                    .is_ok_and(|error| error.trim_end().ends_with("(status=413 code=too_large)"))
                {
                    return Err(CallFailure::OutputTooLarge);
                }
                if std::str::from_utf8(&error).is_ok_and(|error| {
                    error
                        .trim_end()
                        .ends_with("(status=404 code=session_not_found)")
                }) {
                    return Err(CallFailure::SessionNotFound);
                }
                return Err(classify_common_error(&error).unwrap_or(CallFailure::Failed));
            }
            Ok(bytes)
        })
        .await
        .map_err(|_| CallFailure::Failed)
        .and_then(std::convert::identity);
        // This only stops the owned CLI client, never a Rex server or remote worker.
        let _ = child.start_kill();
        if !matches!(
            tokio::time::timeout(Duration::from_secs(2), child.wait()).await,
            Ok(Ok(_))
        ) {
            return Err(CallFailure::Failed);
        }
        result
    }
}
/// Where Rex says it found no server. A local socket is named by path. An
/// address that cannot be reached is named as given, or as first probed when
/// it has no port, and an address from `REX_SERVER` carries that prefix.
fn server_down_location(error: &str) -> Option<String> {
    let line = error.lines().next()?.strip_prefix("Error: ")?;
    if let Some(socket) = line.strip_prefix("no Rex server is running at ") {
        let socket = socket
            .strip_suffix(", and autostart is disabled")
            .unwrap_or(socket);
        return Some(socket.to_owned());
    }
    let address = line
        .strip_prefix("REX_SERVER: ")
        .unwrap_or(line)
        .strip_prefix("connecting to Rex server")?;
    let address = address
        .strip_prefix(": probing ")
        .or_else(|| address.strip_prefix(' '))?;
    let (address, _) = address.split_once(": ")?;
    Some(address.to_owned())
}
async fn bounded_output(
    input: impl tokio::io::AsyncRead + Unpin,
    limit: u64,
) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    input.take(limit + 1).read_to_end(&mut bytes).await?;
    Ok(bytes)
}
#[derive(Clone, Copy)]
enum CapturePath {
    Rpc,
    Cli,
}
fn classify_common_error(error: &[u8]) -> Option<CallFailure> {
    let text = std::str::from_utf8(error).ok()?;
    let trimmed = text.trim_end();
    if trimmed.ends_with("(status=404 code=method_not_found)")
        || trimmed.ends_with("code=method_not_found)")
    {
        Some(CallFailure::MethodNotFound)
    } else if trimmed.ends_with("(status=404 code=not_found)") {
        Some(CallFailure::NotFound)
    } else if text.contains("(status=403 ") {
        Some(CallFailure::Forbidden)
    } else {
        None
    }
}
#[derive(Debug)]
enum CallFailure {
    Unavailable,
    InvalidInput,
    Failed,
    MethodNotFound,
    NotFound,
    Forbidden,
    OutputTooLarge,
    SessionNotFound,
    ServerDown { location: String },
}
impl CallFailure {
    fn is_missing(&self) -> bool {
        matches!(self, Self::NotFound | Self::SessionNotFound)
    }
}
fn read_failure(error: CallFailure) -> RexError {
    match error {
        CallFailure::Unavailable => RexError::Unavailable,
        CallFailure::ServerDown { location } => RexError::ServerDown { location },
        CallFailure::InvalidInput => RexError::InvalidInput,
        CallFailure::Failed
        | CallFailure::MethodNotFound
        | CallFailure::NotFound
        | CallFailure::Forbidden => RexError::ReadFailed,
        CallFailure::OutputTooLarge => RexError::OutputTooLarge,
        CallFailure::SessionNotFound => RexError::SessionNotFound,
    }
}
/// Only a call that never reached Rex proves that nothing was created.
fn creation_failure(error: CallFailure, session_id: Option<SessionId>) -> RexError {
    match error {
        CallFailure::Unavailable => RexError::Unavailable,
        CallFailure::ServerDown { location } => RexError::ServerDown { location },
        CallFailure::InvalidInput => RexError::InvalidInput,
        _ => RexError::CreationUncertain { session_id },
    }
}
fn decode<T: DeserializeOwned>(output: &[u8]) -> Result<T, RexError> {
    serde_json::from_slice(output).map_err(|_| RexError::InvalidResponse)
}
fn nullable_vec<'de, D, T>(deserializer: D) -> Result<Vec<T>, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de>,
{
    Ok(Option::<Vec<T>>::deserialize(deserializer)?.unwrap_or_default())
}
#[derive(Serialize)]
struct Empty {}
#[derive(Deserialize)]
struct SessionList {
    #[serde(deserialize_with = "nullable_vec")]
    sessions: Vec<SessionSummary>,
}
#[derive(Serialize)]
struct SessionRequest {
    session_id: SessionId,
}

#[derive(Serialize)]
struct ResolveRequest<'a> {
    kinds: [&'static str; 1],
    queries: [&'a BlockId; 1],
}
#[derive(Deserialize)]
struct ResolveReply {
    #[serde(default, deserialize_with = "nullable_vec")]
    results: Vec<Resolution>,
}
#[derive(Deserialize)]
struct Resolution {
    status: String,
    target: Option<ResolvedBlock>,
}
#[derive(Deserialize)]
struct ResolvedBlock {
    session_id: SessionId,
    block_id: BlockId,
}

#[derive(Serialize)]
struct ProcessRequest {
    session_id: SessionId,
    block_id: BlockId,
    args: Empty,
}
#[derive(Deserialize)]
struct TerminalProcess {
    child: Option<TerminalChild>,
    foreground: Option<TerminalChild>,
    last_exit: Option<TerminalExit>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TerminalState {
    Running,
    Exited,
    Pending,
}
enum PaneHolds {
    Worker,
    OtherProcess,
    Exited,
    Pending,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PaneRead {
    Gone,
    Holds {
        process: TerminalState,
        instance: Uuid,
    },
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OldPane {
    Closed,
    HandedOver,
    MaybeDetached,
}
/// Closing a superseded pane. It never closes a shell anyone could see. The
/// pane leaves every view before the read that decides its close, and a shell
/// that Rex restores there after a restart stays out of view too.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum GuardedClose {
    Read,
    Detach { recorded: Uuid },
    RecheckWhileDetached { recorded: Uuid },
    Close,
    PutBack,
    Done(OldPane),
}
/// The step after reading a pane still in view. Rex restores a pane with a
/// fresh shell under a new instance, and an exit there may be a shell the
/// user typed in and left. So only an exit under the instance that started
/// the worker is the worker's own.
fn after_read(started_by: Option<Uuid>, read: PaneRead) -> GuardedClose {
    match read {
        PaneRead::Gone => GuardedClose::Done(OldPane::Closed),
        PaneRead::Holds {
            process: TerminalState::Exited,
            instance,
        } if started_by == Some(instance) => GuardedClose::Detach { recorded: instance },
        PaneRead::Holds { .. } => GuardedClose::Done(OldPane::HandedOver),
    }
}
fn after_recheck(recorded: Uuid, read: PaneRead) -> GuardedClose {
    match read {
        PaneRead::Gone => GuardedClose::Done(OldPane::Closed),
        PaneRead::Holds {
            process: TerminalState::Exited,
            instance,
        } if instance == recorded => GuardedClose::Close,
        PaneRead::Holds { .. } => GuardedClose::PutBack,
    }
}
impl TerminalProcess {
    fn state(&self) -> TerminalState {
        if self.child.is_some() || self.foreground.is_some() {
            TerminalState::Running
        } else if self.last_exit.is_some() {
            TerminalState::Exited
        } else {
            // A direct terminal can be published before its process starts.
            // Missing process information alone never authorizes replacement.
            TerminalState::Pending
        }
    }
}
#[derive(Deserialize)]
struct TerminalExit {
    #[serde(rename = "exit_code")]
    _exit_code: i32,
}
#[derive(Deserialize)]
struct TerminalChild {
    #[serde(rename = "pid")]
    _pid: u32,
}
#[derive(Serialize)]
struct BlockRequest {
    session_id: SessionId,
    block_id: BlockId,
}
#[derive(Serialize)]
struct NewWindowRequest {
    session_id: SessionId,
    window_label: String,
    layout: SingleBlock,
    focus: bool,
}
#[derive(Serialize)]
struct MoveSession {
    session_id: SessionId,
    before_session_id: Option<SessionId>,
}
#[derive(Serialize)]
struct MoveBlock {
    session_id: SessionId,
    block_id: BlockId,
    anchor_block_id: BlockId,
}
#[derive(Deserialize)]
struct BlockList {
    #[serde(default, deserialize_with = "nullable_vec")]
    blocks: Vec<ListedBlock>,
}
#[derive(Deserialize)]
struct ListedBlock {
    block_id: Option<String>,
    label: String,
    placement: Placement,
}
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum Placement {
    Placed,
    /// Rex asks clients to read a placement they do not know as detached.
    #[serde(other)]
    Detached,
}

#[derive(Deserialize, Serialize)]
struct CreateRequest {
    label: String,
    initial_windows: [InitialWindow; 1],
}
impl CreateRequest {
    fn worker(title: &str, program: &str, args: &[String], cwd: &Path) -> Result<Self, RexError> {
        let cwd = cwd
            .to_str()
            .filter(|_| cwd.is_absolute())
            .ok_or(RexError::InvalidInput)?;
        if title.trim().is_empty()
            || title.chars().count() > 128
            || title.chars().any(char::is_control)
            || program.is_empty()
            || program.contains('\0')
            || cwd.contains('\0')
            || args.iter().any(|arg| arg.contains('\0'))
        {
            return Err(RexError::InvalidInput);
        }
        let command = std::iter::once(program.to_owned())
            .chain(args.iter().cloned())
            .collect();
        Ok(Self {
            label: title.to_owned(),
            initial_windows: [InitialWindow {
                window_label: "Chat".to_owned(),
                layout: SingleBlock {
                    block: WorkerBlock {
                        flavor: TerminalFlavor::Shell,
                        label: "Chat".to_owned(),
                        options: TerminalOptions {
                            shell: DirectShell::None,
                            login: None,
                            command,
                            cwd: cwd.to_owned(),
                            path_prepend: path_prepend()?,
                            exit: ExitPolicy::ON_ANY_EXIT,
                        },
                    },
                },
            }],
        })
    }
}
#[derive(Deserialize, Serialize)]
struct InitialWindow {
    window_label: String,
    layout: SingleBlock,
}
#[derive(Deserialize, Serialize)]
struct SingleBlock {
    block: WorkerBlock,
}
#[derive(Deserialize, Serialize)]
struct WorkerBlock {
    flavor: TerminalFlavor,
    label: String,
    options: TerminalOptions,
}
const PLACEHOLDER_LABEL: &str = "beep-boop:placeholder";
/// How long a placeholder lives. It closes itself, because a close sent after
/// a Rex restart would reach the shell Rex restored in its place, in view.
/// It must outlive the call that creates it and the move that follows.
const PLACEHOLDER_LIFETIME: Duration = Duration::from_secs(3 * CALL_TIMEOUT.as_secs());
impl WorkerBlock {
    fn placeholder() -> Result<Self, RexError> {
        Ok(Self {
            flavor: TerminalFlavor::Shell,
            label: PLACEHOLDER_LABEL.to_owned(),
            options: TerminalOptions {
                shell: DirectShell::None,
                // Rex starts a login program with a dash before argv[0], and a
                // multi-call coreutils then knows no program by that name.
                login: Some(false),
                command: vec![
                    "sleep".to_owned(),
                    PLACEHOLDER_LIFETIME.as_secs().to_string(),
                ],
                cwd: "/".to_owned(),
                path_prepend: path_prepend()?,
                exit: ExitPolicy::ON_ANY_EXIT,
            },
        })
    }
}
fn path_prepend() -> Result<Vec<String>, RexError> {
    let Some(path) = std::env::var_os("PATH") else {
        return Ok(Vec::new());
    };
    std::env::split_paths(&path)
        .map(|directory| {
            directory
                .into_os_string()
                .into_string()
                .map_err(|_| RexError::InvalidInput)
        })
        .collect()
}
#[derive(Deserialize, Serialize)]
enum TerminalFlavor {
    #[serde(rename = "com.superlogical.terminal.shell")]
    Shell,
}
#[derive(Deserialize, Serialize)]
enum DirectShell {
    #[serde(rename = "none")]
    None,
}
#[derive(Deserialize, Serialize)]
struct TerminalOptions {
    shell: DirectShell,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    login: Option<bool>,
    command: Vec<String>,
    cwd: String,
    path_prepend: Vec<String>,
    exit: ExitPolicy,
}
#[derive(Deserialize, Serialize)]
struct ExitPolicy {
    on_completion: bool,
    quick_exit_threshold_ms: u32,
}
impl ExitPolicy {
    /// Rex closes the pane when its program exits, so a pane lives as long
    /// as its program. Without a zero threshold Rex keeps a pane whose
    /// program exits quickly.
    const ON_ANY_EXIT: Self = Self {
        on_completion: true,
        quick_exit_threshold_ms: 0,
    };
}
#[derive(Deserialize)]
struct CreatedHeader {
    session_id: SessionId,
}
#[derive(Deserialize)]
struct CreatedSession {
    session_id: SessionId,
    initial_windows: Vec<CreatedWindow>,
}
#[derive(Deserialize)]
struct CreatedWindow {
    window_id: WindowId,
    block_ids: Vec<BlockId>,
    revision: u64,
}
fn decode_creation(output: &[u8]) -> Result<WorkerBinding, RexError> {
    let receipt: CreatedSession =
        serde_json::from_slice(output).map_err(|_| RexError::CreationUncertain {
            session_id: serde_json::from_slice::<CreatedHeader>(output)
                .ok()
                .map(|header| header.session_id),
        })?;
    let session_id = receipt.session_id;
    let [window] = receipt.initial_windows.as_slice() else {
        return Err(RexError::CreationUncertain {
            session_id: Some(session_id),
        });
    };
    let [block] = window.block_ids.as_slice() else {
        return Err(RexError::CreationUncertain {
            session_id: Some(session_id),
        });
    };
    Ok(WorkerBinding {
        session_id,
        window_id: window.window_id.clone(),
        block_id: block.clone(),
        revision: window.revision,
    })
}

#[cfg(test)]
#[allow(clippy::disallowed_methods)]
mod tests {
    use super::*;
    use crate::executable_fixture::write_executable;
    use crate::serialized_spawn::SerializedSpawn;
    const SESSION: &str = "session:11111111-1111-4111-8111-111111111111";
    const WINDOW: &str = "window:22222222-2222-4222-8222-222222222222";
    const BLOCK: &str = "block:33333333-3333-4333-8333-333333333333";
    const HOST: &str = "44444444-4444-4444-8444-444444444444";
    const INSTANCE: &str = "66666666-6666-4666-8666-666666666666";

    fn fixture_identity() -> RexIdentity {
        RexIdentity {
            host_id: HostId::parse(HOST).unwrap(),
            instance_id: Uuid::parse_str(INSTANCE).unwrap(),
            rex_version: "fixture".into(),
            endpoint: None,
            tailscale: None,
        }
    }

    #[test]
    fn rex_pane_needs_a_block_and_takes_a_session_when_rex_sets_one() {
        let block = BlockId::parse(BLOCK).unwrap();
        let session = SessionId::parse(SESSION).unwrap();
        assert_eq!(RexPane::parse(None, Some(SESSION)), Ok(None));
        assert_eq!(
            RexPane::parse(Some(BLOCK), None),
            Ok(Some(RexPane {
                block: block.clone(),
                session: None
            }))
        );
        assert_eq!(
            RexPane::parse(Some(BLOCK), Some(SESSION)),
            Ok(Some(RexPane {
                block,
                session: Some(session)
            }))
        );
        assert_eq!(
            RexPane::parse(Some(BLOCK), Some("unrelated-session")),
            Err(RexError::InvalidId)
        );
        assert_eq!(
            RexPane::parse(Some(SESSION), None),
            Err(RexError::InvalidId)
        );
    }

    #[tokio::test]
    async fn terminal_capture_targets_only_the_explicit_pane_and_keeps_rendered_evidence() {
        const CHILD: &str = "AGENT_TEST_REX_CAPTURE_CHILD";
        const TEST: &str = "rex::tests::terminal_capture_targets_only_the_explicit_pane_and_keeps_rendered_evidence";
        if std::env::var_os(CHILD).is_some() {
            let output = RexClient::for_process(None)
                .unwrap()
                .capture_terminal(
                    &SessionId::parse(SESSION).unwrap(),
                    &BlockId::parse(BLOCK).unwrap(),
                )
                .await
                .unwrap();
            assert_eq!(
                output,
                TerminalCapture::Html("<pre>Current task view 🦀</pre>\n".into())
            );
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("rex");
        write_executable(
            &program,
            r#"#!/bin/sh
set -eu
[ -z "${REX_SESSION-}" ] && [ -z "${REX_BLOCK-}" ] && [ -z "${REX_CLIENT-}" ]
for arg in "$@"; do
  if [ "$arg" = "com.superlogical.terminal.format" ]; then
    printf 'Error: stream response "control-1" failed: netapi: no handler for method "com.superlogical.terminal.format" (status=404 code=method_not_found)\n' >&2
    exit 3
  fi
done
printf '%s\n' "$@" > "$AGENT_TEST_REX_CAPTURE_ARGS"
printf '<pre>Current task view 🦀</pre>\n'
"#,
        );
        let arguments = directory.path().join("arguments");
        let path = std::env::join_paths(std::iter::once(directory.path().to_owned()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", TEST, "--nocapture"])
            .env(CHILD, "1")
            .env("AGENT_TEST_REX_CAPTURE_ARGS", &arguments)
            .env("PATH", path)
            .env("REX_SESSION", "unrelated-session")
            .env("REX_BLOCK", "unrelated-pane")
            .env("REX_CLIENT", "unrelated-client")
            .output_serialized()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let actual = std::fs::read_to_string(arguments).unwrap();
        assert_eq!(
            actual.lines().collect::<Vec<_>>(),
            [
                "--autostart=false",
                "--timeout",
                "8s",
                "capture",
                "--session",
                SESSION,
                "--block",
                BLOCK,
                "--format",
                "html",
                "--trim"
            ]
        );
    }

    #[tokio::test]
    async fn terminal_capture_uses_format_blob_read_and_degrades_large_html_to_bounded_text() {
        const CHILD: &str = "AGENT_TEST_REX_FORMAT_CAPTURE_CHILD";
        const MODE: &str = "AGENT_TEST_REX_FORMAT_MODE";
        const TEST: &str = "rex::tests::terminal_capture_uses_format_blob_read_and_degrades_large_html_to_bounded_text";
        if let Ok(mode) = std::env::var(MODE) {
            let _ = std::env::var_os(CHILD);
            let client = RexClient::for_process(None).unwrap();
            let output = client
                .capture_terminal(
                    &SessionId::parse(SESSION).unwrap(),
                    &BlockId::parse(BLOCK).unwrap(),
                )
                .await
                .unwrap();
            if mode == "chunked-html" {
                assert_eq!(
                    output,
                    TerminalCapture::Html("<pre>part-1 part-2</pre>".into())
                );
            } else {
                assert_eq!(output, TerminalCapture::Text("plain trimmed tail\n".into()));
            }
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("rex");
        write_executable(
            &program,
            r#"#!/bin/sh
set -eu
method=""
payload=""
prev=""
for arg do
  if [ -n "$method" ]; then payload=$arg; break; fi
  case "$prev:$arg" in
    call:*) method=$arg ;;
  esac
  prev=$arg
done
case "$method" in
  com.superlogical.terminal.format)
    case "$payload" in
      *'"trim":true'*) ;;
      *) exit 2 ;;
    esac
    if [ "$AGENT_TEST_REX_CASE_MODE" = "chunked-html" ]; then
      printf '{"content":"<pre>part-1 ","id":7,"eof":false,"total":20}\n'
    else
      case "$payload" in
        *'"format":"html"'*)
          printf 'Error: output exceeded limit (status=413 code=too_large)\n' >&2
          exit 3 ;;
        *'"format":"text"'*)
          printf '{"content":"plain trimmed tail\\n","eof":true}\n' ;;
      esac
    fi ;;
  com.superlogical.terminal.blob_read)
    case "$payload" in
      *'"id":7'*'"offset":12'*)
        printf '{"id":7,"data":"part-2</pre>","total":20,"eof":true}\n' ;;
      *) exit 2 ;;
    esac ;;
  *) exit 2 ;;
esac
"#,
        );
        let path = std::env::join_paths(std::iter::once(directory.path().to_owned()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        for mode in ["chunked-html", "html-too-large"] {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env(CHILD, "1")
                .env(MODE, mode)
                .env("AGENT_TEST_REX_CASE_MODE", mode)
                .env("PATH", &path)
                .output_serialized()
                .unwrap();
            assert!(
                output.status.success(),
                "{mode}: {}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    #[tokio::test]
    async fn full_disk_access_preflight_gates_platform_transport_and_legacy_servers() {
        const MODE: &str = "AGENT_TEST_REX_PRIVACY_MODE";
        const TEST: &str =
            "rex::tests::full_disk_access_preflight_gates_platform_transport_and_legacy_servers";
        if let Ok(mode) = std::env::var(MODE) {
            if mode == "ssh" {
                let ssh = RexClient::for_process(Some("ssh://worker.example.invalid")).unwrap();
                assert_eq!(
                    ssh.full_disk_access_preflight().await.unwrap(),
                    ApplePrivacyPreflight::NotApplicable
                );
                return;
            }
            let client = RexClient::for_process(None).unwrap();
            let result = client.full_disk_access_preflight().await.unwrap();
            match mode.as_str() {
                "linux" => assert_eq!(result, ApplePrivacyPreflight::NotApplicable),
                "legacy" => assert_eq!(result, ApplePrivacyPreflight::UnsupportedServer),
                "darwin-granted" => {
                    assert_eq!(result, ApplePrivacyPreflight::Granted);
                    assert_eq!(result.warning_message(), None);
                }
                "darwin-denied" => {
                    assert_eq!(
                        result,
                        ApplePrivacyPreflight::Missing {
                            status: "denied".into(),
                            responsible_path: Some(
                                "/Applications/Rex.app/Contents/MacOS/Rex".into()
                            ),
                        }
                    );
                    let msg = result.warning_message().unwrap();
                    assert!(msg.contains("denied"), "{msg}");
                    assert!(
                        msg.contains("/Applications/Rex.app/Contents/MacOS/Rex"),
                        "{msg}"
                    );
                }
                other => panic!("unexpected mode {other}"),
            }
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("rex");
        write_executable(
            &program,
            r#"#!/bin/sh
set -eu
method=""
prev=""
for arg do
  case "$prev:$arg" in
    call:*) method=$arg; break ;;
  esac
  prev=$arg
done
case "$AGENT_TEST_REX_PRIVACY_CASE:$method" in
  ssh:*) exit 2 ;;
  linux:server.version)
    printf '{"rex_version":"0.1.0","platform":"linux_amd64"}\n' ;;
  linux:server.apple.privacy_status)
    exit 2 ;;
  legacy:server.version)
    printf 'Error: stream response "control-1" failed: netapi: no handler for method "server.version" (status=404 code=method_not_found)\n' >&2
    exit 3 ;;
  darwin-granted:server.version|darwin-denied:server.version)
    printf '{"rex_version":"0.1.0","platform":"darwin_arm64"}\n' ;;
  darwin-granted:server.apple.privacy_status)
    printf '{"services":[{"service":"full_disk_access","status":"granted"}],"responsible_path":"/Applications/Rex.app"}\n' ;;
  darwin-denied:server.apple.privacy_status)
    printf '{"services":[{"service":"full_disk_access","status":"denied"}],"responsible_path":"/Applications/Rex.app/Contents/MacOS/Rex"}\n' ;;
  *) exit 2 ;;
esac
"#,
        );
        let path = std::env::join_paths(std::iter::once(directory.path().to_owned()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        for mode in ["ssh", "linux", "legacy", "darwin-granted", "darwin-denied"] {
            let output = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env(MODE, mode)
                .env("AGENT_TEST_REX_PRIVACY_CASE", mode)
                .env("PATH", &path)
                .output_serialized()
                .unwrap();
            assert!(
                output.status.success(),
                "{mode}: {}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    #[tokio::test]
    async fn only_a_server_that_is_not_running_proves_a_create_was_never_received() {
        const TEST: &str =
            "rex::tests::only_a_server_that_is_not_running_proves_a_create_was_never_received";
        const REMOTE: &str = "https://rex.example.invalid";
        let Some(case) = fake_rex::case() else {
            for (case, envs) in [
                (
                    "down-create",
                    &[("AGENT_TEST_FAKE_REX_DOWN_AT", "session.create")][..],
                ),
                (
                    "down-window",
                    &[("AGENT_TEST_FAKE_REX_DOWN_AT", "session.new_window")][..],
                ),
                (
                    "down-remote-create",
                    &[
                        ("AGENT_TEST_FAKE_REX_DOWN_AT", "session.create"),
                        ("REX_SERVER", REMOTE),
                    ][..],
                ),
                (
                    "lost-create",
                    &[("AGENT_TEST_FAKE_REX_FAIL_AT", "session.create")][..],
                ),
                (
                    "lost-window",
                    &[("AGENT_TEST_FAKE_REX_FAIL_AT", "session.new_window")][..],
                ),
            ] {
                fake_rex::run(TEST, case, envs);
            }
            return;
        };
        let client = RexClient::for_process(None).unwrap();
        let session = SessionId::parse(fake_rex::ORIGIN_SESSION).unwrap();
        let exited = WorkerBinding {
            session_id: session.clone(),
            window_id: WindowId::parse(fake_rex::ORIGIN_WINDOW).unwrap(),
            block_id: BlockId::parse(fake_rex::ORIGIN_BLOCK).unwrap(),
            revision: 1,
        };
        let cwd = Path::new("/tmp");
        let location = if case == "down-remote-create" {
            REMOTE
        } else {
            "/run/user/1000/rex/server.sock"
        };
        let expected = |down: bool, session_id: Option<SessionId>| {
            if down {
                RexError::ServerDown {
                    location: location.into(),
                }
            } else {
                RexError::CreationUncertain { session_id }
            }
        };
        let down = case.starts_with("down");
        if case.ends_with("create") {
            assert_eq!(
                client
                    .create_session("Task", "/example/agent", &[], cwd)
                    .await
                    .unwrap_err(),
                expected(down, None)
            );
            assert_eq!(fake_rex::methods(), ["session.create"]);
        } else {
            let resumed = client
                .resume_worker(
                    &exited,
                    None,
                    &fixture_identity(),
                    "/example/agent",
                    &[],
                    cwd,
                )
                .await;
            assert!(
                matches!(&resumed, Err(error) if *error == expected(down, Some(session.clone())))
            );
            assert_eq!(
                client
                    .create_worker_window(&session, "Review", "/example/agent", &[], cwd)
                    .await
                    .unwrap_err(),
                expected(down, Some(session.clone()))
            );
            assert_eq!(
                fake_rex::methods(),
                [
                    "com.superlogical.terminal.process",
                    "session.new_window",
                    "session.new_window"
                ]
            );
        }
    }

    #[test]
    fn reads_where_rex_found_no_server_from_each_unreachable_server_error() {
        let refused = "connecting to Rex server https://rex.example.invalid: connecting to API control: failed to WebSocket dial: failed to send handshake request: Get \"https://rex.example.invalid/api/control\": dial tcp 192.0.2.1:443: connect: connection refused\n";
        for (error, location) in [
            (
                "Error: no Rex server is running at /run/user/1000/rex/server.sock, and autostart is disabled\n".to_owned(),
                Some("/run/user/1000/rex/server.sock"),
            ),
            (
                "Error: no Rex server is running at /Users/example/Library/Application Support/rex/server.sock, and autostart is disabled\n".to_owned(),
                Some("/Users/example/Library/Application Support/rex/server.sock"),
            ),
            (format!("Error: {refused}"), Some("https://rex.example.invalid")),
            (
                format!("Error: REX_SERVER: {refused}"),
                Some("https://rex.example.invalid"),
            ),
            (
                "Error: connecting to Rex server: probing https://rex.example.invalid: connecting to API control: failed to WebSocket dial: failed to send handshake request: Get \"https://rex.example.invalid/api/control\": dial tcp: lookup rex.example.invalid: no such host\nprobing https://rex.example.invalid:7297: connecting to API control: failed to WebSocket dial: connection refused\n".to_owned(),
                Some("https://rex.example.invalid"),
            ),
            (
                "Error: REX_SERVER: connecting to Rex server: probing https://rex.example.invalid: connecting to API control: failed to WebSocket dial: connection refused\n".to_owned(),
                Some("https://rex.example.invalid"),
            ),
            (
                "Error: connecting to the server timed out after 8s; increase --timeout: context deadline exceeded\n".to_owned(),
                None,
            ),
            (
                "Error: stream response \"control-1\" failed: connection reset\n".to_owned(),
                None,
            ),
            (
                "Error: stream response \"control-1\" failed: session session:11111111-1111-4111-8111-111111111111 not found (status=404 code=session_not_found)\n".to_owned(),
                None,
            ),
        ] {
            assert_eq!(server_down_location(&error).as_deref(), location, "{error}");
        }
    }

    #[test]
    fn validates_native_id_kinds_and_rejects_nil_or_malformed_ids() {
        assert!(SessionId::parse(SESSION).is_ok());
        assert!(BlockId::parse(SESSION).is_err());
        assert!(SessionId::parse("session:not-an-id").is_err());
        assert!(HostId::parse("00000000-0000-0000-0000-000000000000").is_err());
        assert!(
            serde_json::from_str::<SessionId>(r#""block:33333333-3333-4333-8333-333333333333""#)
                .is_err()
        );
    }

    #[test]
    fn worker_request_roundtrip_preserves_literal_argv_and_one_direct_worker() {
        let args = vec![
            "a b".to_owned(),
            "$(not-a-shell)".to_owned(),
            "; literal".to_owned(),
        ];
        let request = CreateRequest::worker(
            "Synthetic task",
            "/tool/agent",
            &args,
            Path::new("/workspace/project"),
        )
        .unwrap();
        let bytes = serde_json::to_vec(&request).unwrap();
        let decoded: CreateRequest = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(decoded.initial_windows.len(), 1);
        let worker = &decoded.initial_windows[0].layout.block;
        assert_eq!(worker.label, "Chat");
        assert!(matches!(worker.options.shell, DirectShell::None));
        assert_eq!(
            worker.options.command,
            [vec!["/tool/agent".to_owned()], args].concat()
        );
        assert_eq!(worker.options.cwd, "/workspace/project");
        assert_eq!(
            worker.options.path_prepend,
            std::env::split_paths(&std::env::var_os("PATH").unwrap())
                .map(|path| path.into_os_string().into_string().unwrap())
                .collect::<Vec<_>>()
        );
        let options = &serde_json::to_value(&request).unwrap()["initial_windows"][0]["layout"]["block"]
            ["options"];
        assert_eq!(
            options["exit"],
            serde_json::json!({ "on_completion": true, "quick_exit_threshold_ms": 0 }),
            "Rex closes a worker's pane when its program exits, however quickly"
        );
        assert!(
            options.get("login").is_none(),
            "A worker keeps Rex's default argv"
        );
        assert!(CreateRequest::worker("Task", "tool", &[], Path::new("relative")).is_err());
    }

    #[test]
    fn only_the_workers_own_exit_closes_and_only_if_it_reads_the_same_out_of_view() {
        use GuardedClose::{Close, Detach, Done, PutBack};
        use OldPane::{Closed, HandedOver};
        use TerminalState::{Exited, Pending, Running};
        let started = Uuid::parse_str(INSTANCE).unwrap();
        let restarted = Uuid::from_u128(8);
        let holds = |process, instance| PaneRead::Holds { process, instance };
        for (reason, started_by, read, step) in [
            (
                "a pane Rex no longer has is closed",
                Some(started),
                PaneRead::Gone,
                Done(Closed),
            ),
            (
                "the worker's own exit leaves view first",
                Some(started),
                holds(Exited, started),
                Detach { recorded: started },
            ),
            (
                "an exit under a later instance may be a restored shell the user left",
                Some(started),
                holds(Exited, restarted),
                Done(HandedOver),
            ),
            (
                "an exit with no recorded instance may be one too",
                None,
                holds(Exited, started),
                Done(HandedOver),
            ),
            (
                "a running process stays",
                Some(started),
                holds(Running, started),
                Done(HandedOver),
            ),
            (
                "a starting process stays",
                Some(started),
                holds(Pending, started),
                Done(HandedOver),
            ),
        ] {
            assert_eq!(after_read(started_by, read), step, "In view, {reason}");
        }
        for (reason, read, step) in [
            (
                "a pane closed meanwhile is closed",
                PaneRead::Gone,
                Done(Closed),
            ),
            (
                "the same exit under the same instance closes",
                holds(Exited, started),
                Close,
            ),
            (
                "a restart restores a shell, which goes back",
                holds(Running, restarted),
                PutBack,
            ),
            (
                "an exit under a later instance goes back",
                holds(Exited, restarted),
                PutBack,
            ),
            (
                "a process that runs again goes back",
                holds(Running, started),
                PutBack,
            ),
        ] {
            assert_eq!(after_recheck(started, read), step, "Detached, {reason}");
        }
    }

    #[tokio::test]
    async fn a_put_back_refused_as_not_found_counts_as_closed_only_if_the_pane_is_gone() {
        const TEST: &str =
            "rex::tests::a_put_back_refused_as_not_found_counts_as_closed_only_if_the_pane_is_gone";
        let Some(case) = fake_rex::case() else {
            for missing in ["pane", "anchor"] {
                fake_rex::run(
                    TEST,
                    missing,
                    &[
                        ("AGENT_TEST_FAKE_REX_RESTART_AFTER", "session.detach_block"),
                        ("AGENT_TEST_FAKE_REX_MOVE_MISSING", missing),
                    ],
                );
            }
            return;
        };
        let old = close_superseded_origin().await;
        let methods = fake_rex::methods();
        assert!(
            methods.contains(&"session.move_block".to_owned()),
            "The restored shell was not put back: {methods:?}"
        );
        if case == "pane" {
            assert_eq!(old, OldPane::Closed, "Rex no longer has the pane");
        } else {
            assert_eq!(
                old,
                OldPane::MaybeDetached,
                "The placeholder was gone, so the pane stays detached"
            );
            assert_eq!(
                moves(&methods),
                2,
                "The put-back is tried once more and no further: {methods:?}"
            );
        }
        assert!(
            !methods.contains(&"block.close".to_owned()),
            "Nothing is closed: {methods:?}"
        );
    }

    async fn close_superseded_origin() -> OldPane {
        let pane = WorkerBinding {
            session_id: SessionId::parse(fake_rex::ORIGIN_SESSION).unwrap(),
            window_id: WindowId::parse(fake_rex::ORIGIN_WINDOW).unwrap(),
            block_id: BlockId::parse(fake_rex::ORIGIN_BLOCK).unwrap(),
            revision: 1,
        };
        RexClient::for_process(None)
            .unwrap()
            .close_superseded(&pane, Some(Uuid::parse_str(INSTANCE).unwrap()))
            .await
    }

    fn moves(methods: &[String]) -> usize {
        methods
            .iter()
            .filter(|method| *method == "session.move_block")
            .count()
    }

    #[tokio::test]
    async fn a_put_back_whose_placeholder_expired_goes_beside_a_fresh_one() {
        const TEST: &str =
            "rex::tests::a_put_back_whose_placeholder_expired_goes_beside_a_fresh_one";
        if fake_rex::case().is_none() {
            fake_rex::run(
                TEST,
                "anchor-once",
                &[
                    ("AGENT_TEST_FAKE_REX_RESTART_AFTER", "session.detach_block"),
                    ("AGENT_TEST_FAKE_REX_MOVE_MISSING", "anchor-once"),
                ],
            );
            return;
        }
        let old = close_superseded_origin().await;
        let methods = fake_rex::methods();
        assert_eq!(
            old,
            OldPane::HandedOver,
            "The second placeholder was still there: {methods:?}"
        );
        assert_eq!(
            methods
                .iter()
                .filter(|method| *method == "session.new_window")
                .count(),
            2,
            "Each move gets a placeholder of its own: {methods:?}"
        );
        assert_eq!(moves(&methods), 2, "{methods:?}");
        assert!(
            !methods.contains(&"block.close".to_owned()),
            "Nothing is closed: {methods:?}"
        );
    }

    #[tokio::test]
    async fn a_put_back_whose_move_failed_goes_beside_a_fresh_placeholder() {
        const TEST: &str =
            "rex::tests::a_put_back_whose_move_failed_goes_beside_a_fresh_placeholder";
        if fake_rex::case().is_none() {
            fake_rex::run(
                TEST,
                "move-fails-once",
                &[
                    ("AGENT_TEST_FAKE_REX_RESTART_AFTER", "session.detach_block"),
                    ("AGENT_TEST_FAKE_REX_FAIL_ONCE_AT", "session.move_block"),
                ],
            );
            return;
        }
        let old = close_superseded_origin().await;
        let methods = fake_rex::methods();
        assert_eq!(
            old,
            OldPane::HandedOver,
            "Rex still listed the pane as detached after the failed move: {methods:?}"
        );
        assert_eq!(
            methods
                .iter()
                .filter(|method| *method == "session.new_window")
                .count(),
            2,
            "Each move gets a placeholder of its own: {methods:?}"
        );
        assert_eq!(moves(&methods), 2, "{methods:?}");
        assert!(
            !methods.contains(&"block.close".to_owned()),
            "Nothing is closed: {methods:?}"
        );
    }

    #[test]
    fn creation_receipt_preserves_known_identity_when_result_is_uncertain() {
        let valid = format!(
            r#"{{"session_id":"{SESSION}","initial_windows":[{{"window_id":"{WINDOW}","block_ids":["{BLOCK}"],"revision":1}}]}}"#
        );
        let binding = decode_creation(valid.as_bytes()).unwrap();
        assert_eq!(binding.block_id.as_str(), BLOCK);
        let partial = format!(r#"{{"session_id":"{SESSION}","initial_windows":[]}}"#);
        assert_eq!(
            decode_creation(partial.as_bytes()).unwrap_err(),
            RexError::CreationUncertain {
                session_id: Some(SessionId::parse(SESSION).unwrap()),
            }
        );
        assert_eq!(
            decode_creation(b"not json").unwrap_err(),
            RexError::CreationUncertain { session_id: None }
        );
    }

    #[test]
    fn verifies_session_window_block_and_host_not_only_a_mutable_title() {
        let receipt = format!(
            r#"{{"session_id":"{SESSION}","initial_windows":[{{"window_id":"{WINDOW}","block_ids":["{BLOCK}"],"revision":1}}]}}"#
        );
        let binding = decode_creation(receipt.as_bytes()).unwrap();
        let view = format!(
            r#"{{"session_id":"{SESSION}","revision":2,"label":"Renamed","windows":[{{"window_id":"{WINDOW}","layers":[{{"blocks":[{{"block_id":"{BLOCK}","host_id":"{HOST}","flavor":"com.superlogical.terminal.shell","label":"Worker"}}]}}]}}]}}"#
        );
        let view: SessionView = decode(view.as_bytes()).unwrap();
        assert!(
            view.verify_binding(&binding, &HostId::parse(HOST).unwrap())
                .is_ok()
        );
        let other = HostId::parse("55555555-5555-4555-8555-555555555555").unwrap();
        assert_eq!(
            view.verify_binding(&binding, &other),
            Err(RexError::BindingMismatch)
        );
        assert!(
            decode::<SessionList>(br#"{"sessions":null}"#)
                .unwrap()
                .sessions
                .is_empty()
        );
        assert!(decode::<SessionList>(b"{}").is_err());
    }

    #[test]
    fn the_runtime_sdk_reaches_only_this_process_own_local_rex() {
        let sdk = |server: Option<&str>| {
            RexClient::for_process(server)
                .unwrap()
                .sdk_server()
                .map(str::to_owned)
        };
        assert_eq!(sdk(None).as_deref(), Some("personal"));
        assert_eq!(
            sdk(Some("unix:///run/example/rex.sock")).as_deref(),
            Some("/run/example/rex.sock")
        );
        for unclear in [
            "unix:///run/example/rex%2Fother.sock",
            "unix:///run/example/../rex.sock",
            "unix:///run/example/./rex.sock",
            "unix:///run/example/rex.sock ",
            "unix:///run/example/rex.sock\u{feff}",
            "unix:///run/example/re\tx.sock",
            "ssh://example.invalid",
        ] {
            let unclear = unclear.replace("\\t", "\t");
            assert_eq!(
                RexClient::for_process(Some(&unclear))
                    .map(|client| client.sdk_server().map(str::to_owned))
                    .unwrap_or(None),
                None,
                "{unclear:?}"
            );
        }
    }

    #[test]
    fn cli_argv_disables_autostart_and_scopes_server_without_shell_interpolation() {
        let client =
            RexClient::for_process(Some("unix:///run/user/1000/agent rex/$(x).sock")).unwrap();
        let command = client.command(&["whoami".to_owned(), "--json".to_owned()]);
        let args: Vec<_> = command
            .as_std()
            .get_args()
            .map(|arg| arg.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args,
            [
                "--autostart=false",
                "--timeout",
                "8s",
                "--server",
                "unix:///run/user/1000/agent rex/$(x).sock",
                "whoami",
                "--json"
            ]
        );
    }

    #[test]
    fn local_rex_endpoint_accepts_only_an_absolute_unix_socket() {
        for (input, accepted) in [
            ("unix:///run/user/1000/rex-agent/server.sock", true),
            ("unix:///tmp/a b/s.sock", true),
            ("unix://relative/server.sock", false),
            ("unix://", false),
            ("unix:///", false),
            ("/run/user/1000/rex-agent/server.sock", false),
            ("UNIX:///run/user/1000/rex-agent/server.sock", false),
            ("https://worker.example.invalid", false),
            ("studio", false),
            ("127.0.0.1:7777", false),
            ("unix:///run/user/1000/rex.sock?mode=0600", false),
            ("unix:///run/user/1000/rex.sock#pane", false),
            ("unix:///run/user/1000/rex\0.sock", false),
            ("", false),
        ] {
            assert_eq!(
                LocalRexEndpoint::parse(input).is_ok(),
                accepted,
                "{input:?}"
            );
            assert_eq!(
                RexClient::for_process(Some(input)).is_ok(),
                accepted,
                "{input:?}"
            );
        }
        assert!(!RexClient::for_process(None).unwrap().is_private());
    }

    #[test]
    fn ssh_rex_endpoints_are_validated_without_shell_interpolation() {
        for (input, accepted) in [
            ("ssh://worker.example.invalid", true),
            ("ssh://alice@worker.example.invalid", true),
            ("ssh://alice@worker.example.invalid:2222", true),
            ("ssh://[::1]:2222", true),
            ("ssh://", false),
            ("ssh://-oProxyCommand=bad", false),
            ("ssh://-alice@worker.example.invalid", false),
            ("ssh://alice@-worker.example.invalid", false),
            ("ssh://worker.example.invalid/path", false),
            ("ssh://worker.example.invalid?x=1", false),
            ("ssh://worker.example.invalid#frag", false),
            ("ssh://alice@bob@worker.example.invalid", false),
            ("ssh://worker.example.invalid:0", false),
            ("ssh://worker.example.invalid:notaport", false),
            ("ssh://worker example.invalid", false),
        ] {
            assert_eq!(
                LocalRexEndpoint::parse(input).is_ok(),
                accepted,
                "{input:?}"
            );
            let client = RexClient::for_process(Some(input));
            assert_eq!(client.is_ok(), accepted, "{input:?}");
            if accepted {
                let client = client.unwrap();
                assert_eq!(client.ssh_endpoint(), Some(input));
                assert!(!client.is_local_unix_socket());
            }
        }
    }

    #[tokio::test]
    async fn native_process_completion_evidence_prevents_duplicate_chat_windows() {
        const TEST: &str =
            "rex::tests::native_process_completion_evidence_prevents_duplicate_chat_windows";
        if let Ok(directory) = std::env::var("AGENT_TEST_REX_PROCESS_FIXTURE") {
            let client = RexClient::for_process(None).unwrap();
            let binding = WorkerBinding {
                session_id: SessionId::parse(SESSION).unwrap(),
                window_id: WindowId::parse(WINDOW).unwrap(),
                block_id: BlockId::parse(BLOCK).unwrap(),
                revision: 1,
            };
            let case = std::env::var("AGENT_TEST_REX_PROCESS_CASE").unwrap();
            let identity = fixture_identity();
            let started_by = Some(identity.instance_id);
            let presence = client
                .worker_presence(&binding, started_by, &identity.host_id)
                .await;
            if case == "unlisted-read-failure" {
                assert_eq!(presence.unwrap_err(), RexError::ReadFailed);
            } else if case == "unlisted-missing" {
                assert!(matches!(
                    presence.unwrap(),
                    crate::protocol::WorkerPresence::MissingSession
                ));
            } else if case == "invalid-exit" {
                assert_eq!(presence.unwrap_err(), RexError::InvalidResponse);
                assert!(matches!(
                    client
                        .resume_worker(
                            &binding,
                            started_by,
                            &identity,
                            "/example/agent",
                            &[],
                            Path::new("/tmp")
                        )
                        .await,
                    Err(RexError::InvalidResponse)
                ));
            } else {
                let presence = presence.unwrap();
                if case == "starting" {
                    assert!(
                        !matches!(
                            presence,
                            crate::protocol::WorkerPresence::Present { .. }
                                | crate::protocol::WorkerPresence::MissingSession
                                | crate::protocol::WorkerPresence::MissingTerminal
                        ),
                        "No process and no completion is pending, never proof that the worker exited"
                    );
                } else {
                    assert!(
                        matches!(presence, crate::protocol::WorkerPresence::Present { running } if running == !matches!(case.as_str(), "exited" | "unlisted-exited"))
                    );
                }
                let resumed = client
                    .resume_worker(
                        &binding,
                        started_by,
                        &identity,
                        "/example/agent",
                        &[],
                        Path::new("/tmp"),
                    )
                    .await
                    .unwrap();
                if matches!(case.as_str(), "exited" | "unlisted-exited") {
                    assert!(
                        matches!(resumed, WorkerResume::Started(ref next) if next.session_id == binding.session_id && next.block_id != binding.block_id)
                    );
                } else {
                    assert!(
                        !matches!(resumed, WorkerResume::Started(_)),
                        "An unconfirmed exit cannot create another Chat"
                    );
                }
            }
            let calls = std::fs::read_to_string(Path::new(&directory).join("calls")).unwrap();
            assert_eq!(
                calls
                    .lines()
                    .filter(|method| *method == "session.new_window")
                    .count(),
                usize::from(matches!(case.as_str(), "exited" | "unlisted-exited"))
            );
            assert_eq!(
                calls
                    .lines()
                    .filter(|method| *method == "block.close")
                    .count(),
                usize::from(matches!(case.as_str(), "exited" | "unlisted-exited"))
            );
            return;
        }
        let directory = tempfile::tempdir().unwrap();
        let program = directory.path().join("rex");
        // Keep each native RPC as a process, without booting a JS runtime for
        // every poll. The fixture only needs shell builtins and owned markers.
        let fixture = r#"#!/bin/sh
set -eu
root=${AGENT_TEST_REX_PROCESS_FIXTURE:?}
mode=${AGENT_TEST_REX_PROCESS_CASE:?}
previous=
method=
for argument do
  if [ "$previous" = call ]; then method=$argument; break; fi
  if [ "$argument" = whoami ]; then method=whoami; break; fi
  previous=$argument
done
printf '%s\n' "$method" >> "$root/calls"
trap 'code=$?; printf "%s status=%s pid=%s\n" "$method" "$code" "$$" >> "$root/results"' 0
fail() {
  printf '%s\n' "$1" >&2
  printf '%s\n' "$1" >> "$root/errors"
  exit "$2"
}
session=session:11111111-1111-4111-8111-111111111111
window=window:22222222-2222-4222-8222-222222222222
block=block:33333333-3333-4333-8333-333333333333
host=44444444-4444-4444-8444-444444444444
replacement=block:55555555-5555-4555-8555-555555555555
case "$method" in
  session.list)
    case "$mode" in
      unlisted-*) value='{"sessions":[]}' ;;
      *) value="{\"sessions\":[{\"session_id\":\"$session\",\"label\":\"Synthetic work\"}]}" ;;
    esac ;;
  session.view)
    case "$mode" in
      unlisted-missing) fail "Error: stream response \"control-1\" failed: session $session not found (status=404 code=session_not_found)" 3 ;;
      unlisted-read-failure) fail 'Error: session inspection denied (status=403 code=session_not_found)' 3 ;;
    esac
    blocks=
    for id in "$block" "$replacement"; do
      if [ "$id" = "$block" ] && [ -e "$root/closed" ]; then continue; fi
      if [ "$id" = "$replacement" ] && [ ! -e "$root/created" ]; then continue; fi
      item="{\"block_id\":\"$id\",\"host_id\":\"$host\",\"flavor\":\"com.superlogical.terminal.shell\"}"
      blocks="${blocks:+$blocks,}$item"
    done
    value="{\"session_id\":\"$session\",\"revision\":2,\"windows\":[{\"window_id\":\"$window\",\"layers\":[{\"blocks\":[$blocks]}]}]}" ;;
  com.superlogical.terminal.process)
    child=null
    foreground=null
    last_exit='{"exit_code":0}'
    live='{"pid":123,"user_id":501,"name":"agent"}'
    case "$mode" in child|unlisted-running) child=$live ;; esac
    if [ "$mode" = foreground ]; then foreground=$live; fi
    case "$mode" in
      invalid-exit) last_exit='{}' ;;
      starting|child) last_exit=null ;;
    esac
    value="{\"child\":$child,\"foreground\":$foreground,\"last_exit\":$last_exit}" ;;
  session.new_window)
    : > "$root/created"
    value="{\"window_id\":\"$window\",\"block_ids\":[\"$replacement\"],\"revision\":2}" ;;
  whoami)
    value="{\"host_id\":\"$host\",\"instance_id\":\"66666666-6666-4666-8666-666666666666\",\"rex_version\":\"fixture\"}" ;;
  session.detach_block) value='{"revision":3}' ;;
  block.close) : > "$root/closed"; value='{}' ;;
  *) fail "Unexpected native method $method" 1 ;;
esac
printf '%s\n' "$value"
"#;
        write_executable(&program, fixture);
        let paths = std::env::join_paths(
            std::iter::once(directory.path().to_path_buf())
                .chain(std::env::split_paths(&std::env::var_os("PATH").unwrap())),
        )
        .unwrap();
        for case in [
            "unlisted-running",
            "unlisted-exited",
            "unlisted-read-failure",
            "unlisted-missing",
            "starting",
            "foreground",
            "child",
            "exited",
            "invalid-exit",
        ] {
            for log in ["calls", "results", "errors"] {
                std::fs::write(directory.path().join(log), "").unwrap();
            }
            for marker in ["created", "closed"] {
                let _ = std::fs::remove_file(directory.path().join(marker));
            }
            let result = std::process::Command::new(std::env::current_exe().unwrap())
                .args(["--exact", TEST, "--nocapture"])
                .env("PATH", &paths)
                .env("AGENT_TEST_REX_PROCESS_FIXTURE", directory.path())
                .env("AGENT_TEST_REX_PROCESS_CASE", case)
                .output_serialized()
                .unwrap();
            assert!(
                result.status.success(),
                "Native fixture {case}:\n{}\n{}\nCalls:\n{}\nProcess results:\n{}\nDriver errors:\n{}",
                String::from_utf8_lossy(&result.stdout),
                String::from_utf8_lossy(&result.stderr),
                std::fs::read_to_string(directory.path().join("calls")).unwrap(),
                std::fs::read_to_string(directory.path().join("results")).unwrap(),
                std::fs::read_to_string(directory.path().join("errors")).unwrap(),
            );
        }
    }

    #[derive(Deserialize)]
    struct NativeWindows {
        windows: Vec<NamedWindow>,
    }
    #[derive(Deserialize)]
    struct NamedWindow {
        window_id: WindowId,
        label: String,
    }
    async fn assert_native_output(
        client: &RexClient,
        binding: &WorkerBinding,
        marker: &str,
    ) -> anyhow::Result<()> {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let output = client
                .run(vec![
                    "capture".to_owned(),
                    "-s".to_owned(),
                    binding.session_id.to_string(),
                    "-b".to_owned(),
                    binding.block_id.to_string(),
                    "--trim".to_owned(),
                    "--unwrap".to_owned(),
                ])
                .await
                .map_err(read_failure)?;
            if String::from_utf8(output)?.contains(marker) {
                return Ok(());
            }
            anyhow::ensure!(
                tokio::time::Instant::now() < deadline,
                "Native terminal did not show the marker"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn assert_closes_with_its_program(
        client: &RexClient,
        binding: &WorkerBinding,
        identity: &RexIdentity,
    ) -> anyhow::Result<()> {
        client
            .run(vec![
                "send-key".to_owned(),
                "-s".to_owned(),
                binding.session_id.to_string(),
                "-b".to_owned(),
                binding.block_id.to_string(),
                "enter".to_owned(),
            ])
            .await
            .map_err(read_failure)?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while client.listed_block(binding).await?.is_some() {
            anyhow::ensure!(
                tokio::time::Instant::now() < deadline,
                "Rex kept the pane after its program exited"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let presence = client
            .worker_presence(binding, Some(identity.instance_id), &identity.host_id)
            .await?;
        anyhow::ensure!(
            matches!(presence, crate::protocol::WorkerPresence::MissingTerminal),
            "A pane that closed with its program did not read as missing: {presence:?}"
        );
        Ok(())
    }

    fn private_test_server() -> anyhow::Result<(RexClient, String)> {
        let server = std::env::var("AGENT_TEST_REX_SERVER")
            .ok()
            .filter(|server| server.starts_with("unix://"))
            .ok_or_else(|| {
                anyhow::anyhow!(
                    "Set AGENT_TEST_REX_SERVER to a private unix:// Rex server; live tests never use the personal one"
                )
            })?;
        Ok((RexClient::for_process(Some(&server))?, server))
    }

    async fn pane_kept_after_exit(
        client: &RexClient,
        label: &str,
    ) -> anyhow::Result<WorkerBinding> {
        let title = format!("{label}-{}", Uuid::new_v4());
        let args = ["-c".to_owned(), "exit 3".to_owned()];
        let mut request = serde_json::to_value(CreateRequest::worker(
            &title,
            "/bin/sh",
            &args,
            Path::new("/tmp"),
        )?)?;
        request["initial_windows"][0]["layout"]["block"]["options"]["exit"] =
            serde_json::json!({ "on_completion": false });
        let binding = decode_creation(
            &client
                .api("session.create", &request)
                .await
                .map_err(read_failure)?,
        )?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !matches!(
            client.read_pane(&binding).await?,
            PaneRead::Holds {
                process: TerminalState::Exited,
                ..
            }
        ) {
            anyhow::ensure!(
                tokio::time::Instant::now() < deadline,
                "The legacy pane's program did not exit"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Ok(binding)
    }

    async fn restart_private_server(
        client: &RexClient,
        server: &str,
        state: &str,
    ) -> anyhow::Result<()> {
        use std::os::unix::process::CommandExt;
        let _ = client
            .run(vec!["server".to_owned(), "stop".to_owned()])
            .await;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while !matches!(client.whoami().await, Err(RexError::ServerDown { .. })) {
            anyhow::ensure!(
                tokio::time::Instant::now() < deadline,
                "The private Rex server did not stop"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        std::process::Command::new("rex")
            .args(["server", "run", "--listen", server, "--state-dir", state])
            .args(["--config", "/dev/null"])
            .env_remove("REX_SERVER")
            .env_remove("REX_SESSION")
            .env_remove("REX_BLOCK")
            .env_remove("REX_CLIENT")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn_serialized()?;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        while client.whoami().await.is_err() {
            anyhow::ensure!(
                tokio::time::Instant::now() < deadline,
                "The private Rex server did not start again"
            );
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        Ok(())
    }

    async fn close_test_session(client: &RexClient, session: &SessionId) -> anyhow::Result<()> {
        // One exact native kill, followed by independent state readback even if its reply was lost.
        let killed = client
            .run(vec!["kill".to_owned(), session.to_string()])
            .await;
        let absent = !client
            .list_sessions()
            .await?
            .iter()
            .any(|item| item.session_id == *session);
        anyhow::ensure!(absent, "The test-created Rex session remains after cleanup");
        if killed.is_err() {
            eprintln!(
                "Native kill reply was unavailable; independent listing verified test-session removal."
            );
        }
        Ok(())
    }

    #[tokio::test]
    #[ignore = "requires a private Rex server; creates and removes one synthetic session"]
    async fn live_native_rex_worker_contract() -> anyhow::Result<()> {
        let (client, _) = private_test_server()?;
        let identity = client.whoami().await?;
        let before = client.list_sessions().await?;
        let title = format!("agent-rex-contract-{}", Uuid::new_v4());
        let marker = "agent-rex-contract-marker";
        let args = vec![
            "-c".to_owned(),
            format!("printf '%s\\n' {marker}; read -r line"),
        ];
        let binding = match client
            .create_session(&title, "/bin/sh", &args, Path::new("/tmp"))
            .await
        {
            Ok(binding) => binding,
            Err(error) => {
                // Reconcile this unique test label without issuing a second create.
                let candidates: Vec<_> = client
                    .list_sessions()
                    .await?
                    .into_iter()
                    .filter(|item| {
                        item.label == title
                            && !before.iter().any(|old| old.session_id == item.session_id)
                    })
                    .collect();
                anyhow::ensure!(
                    candidates.len() <= 1,
                    "Could not identify the single test allocation for cleanup"
                );
                if let Some(created) = candidates.first() {
                    close_test_session(&client, &created.session_id).await?;
                }
                return Err(error.into());
            }
        };
        let result = tokio::time::timeout(Duration::from_secs(120), async {
            let view = client.inspect_session(&binding.session_id).await?;
            view.verify_binding(&binding, &identity.host_id)?;
            anyhow::ensure!(
                view.label.as_deref() == Some(&title),
                "Native task session label changed"
            );
            assert_native_output(&client, &binding, marker).await?;

            let review = client
                .create_worker_window(
                    &binding.session_id,
                    "Review",
                    "/bin/sh",
                    &args,
                    Path::new("/tmp"),
                )
                .await?;
            anyhow::ensure!(
                review.session_id == binding.session_id
                    && review.window_id != binding.window_id
                    && review.block_id != binding.block_id,
                "The task agent did not get a separate terminal in the same session"
            );
            let view = client.inspect_session(&binding.session_id).await?;
            view.verify_binding(&binding, &identity.host_id)?;
            view.verify_binding(&review, &identity.host_id)?;
            anyhow::ensure!(
                view.windows.len() == 2,
                "Expected one parent and one agent window"
            );
            let labels: NativeWindows = decode(
                &client
                    .run(vec![
                        "window".to_owned(),
                        "ls".to_owned(),
                        "-s".to_owned(),
                        binding.session_id.to_string(),
                        "--json".to_owned(),
                    ])
                    .await
                    .map_err(read_failure)?,
            )?;
            anyhow::ensure!(
                labels
                    .windows
                    .iter()
                    .any(|window| window.window_id == binding.window_id && window.label == "Chat")
                    && labels
                        .windows
                        .iter()
                        .any(|window| window.window_id == review.window_id
                            && window.label == "Review"),
                "Native window labels do not identify their work"
            );
            anyhow::ensure!(
                view.windows
                    .iter()
                    .flat_map(|window| &window.layers)
                    .flat_map(|layer| &layer.blocks)
                    .any(|block| block.block_id.as_ref() == Some(&review.block_id)
                        && block.label.as_deref() == Some("Review")),
                "Native agent terminal label is missing"
            );
            assert_native_output(&client, &review, marker).await?;
            assert_closes_with_its_program(&client, &review, &identity).await?;
            client
                .inspect_session(&binding.session_id)
                .await?
                .verify_binding(&binding, &identity.host_id)?;

            client
                .api(
                    "session.move",
                    &MoveSession {
                        session_id: binding.session_id.clone(),
                        before_session_id: None,
                    },
                )
                .await
                .map_err(read_failure)?;
            client.promote_session(&binding.session_id).await?;
            let sessions = client.list_sessions().await?;
            anyhow::ensure!(
                sessions
                    .first()
                    .is_some_and(|session| session.session_id == binding.session_id),
                "Promoted task is not first in the native sidebar"
            );
            anyhow::ensure!(
                sessions
                    .iter()
                    .filter(|session| session.label == title)
                    .count()
                    == 1,
                "Native task session was duplicated"
            );
            Ok::<_, anyhow::Error>(())
        })
        .await;
        let cleanup = close_test_session(&client, &binding.session_id).await;
        cleanup?;
        result
            .map_err(|_| anyhow::anyhow!("Native Rex contract exceeded its two-minute limit"))??;
        let closed = client
            .worker_presence(&binding, Some(identity.instance_id), &identity.host_id)
            .await?;
        anyhow::ensure!(
            matches!(closed, crate::protocol::WorkerPresence::MissingSession),
            "Rex's answer for a closed session did not read as missing: {closed:?}"
        );
        eprintln!(
            "Native Rex contract verified: two marker programs in two named windows of one session, a pane that closed with its program, sidebar promotion, independent cleanup readback, and a closed session read as missing."
        );
        Ok(())
    }

    #[tokio::test]
    #[ignore = "requires a private Rex server that it restarts; creates and removes two synthetic sessions"]
    async fn live_guarded_close_closes_a_legacy_exit_and_puts_back_a_restored_shell()
    -> anyhow::Result<()> {
        let (client, server) = private_test_server()?;
        let state = std::env::var("AGENT_TEST_REX_STATE_DIR").map_err(|_| {
            anyhow::anyhow!(
                "Set AGENT_TEST_REX_STATE_DIR to the private server's --state-dir. The test restarts that server and leaves it running, so start it with `rex server run --listen <AGENT_TEST_REX_SERVER> --state-dir <AGENT_TEST_REX_STATE_DIR> --config /dev/null`, with the same `rex` first on PATH"
            )
        })?;
        let identity = client.whoami().await?;
        let started_by = Some(identity.instance_id);
        let exited = pane_kept_after_exit(&client, "agent-rex-legacy-exit").await?;
        let restored = match pane_kept_after_exit(&client, "agent-rex-legacy-restore").await {
            Ok(restored) => restored,
            Err(error) => {
                close_test_session(&client, &exited.session_id).await?;
                return Err(error);
            }
        };
        let result = tokio::time::timeout(Duration::from_secs(120), async {
            let waits = ["-c".to_owned(), "read -r line".to_owned()];
            let WorkerResume::Started(replacement) = client
                .resume_worker(
                    &exited,
                    started_by,
                    &identity,
                    "/bin/sh",
                    &waits,
                    Path::new("/tmp"),
                )
                .await?
            else {
                anyhow::bail!("A legacy pane whose worker exited was not replaced");
            };
            anyhow::ensure!(
                client.listed_block(&exited).await?.is_none(),
                "The worker's own exit stayed after its replacement started"
            );
            anyhow::ensure!(
                client
                    .listed_block(&replacement)
                    .await?
                    .is_some_and(|block| block.placement == Placement::Placed),
                "The replacement pane is not in view"
            );

            let mut step = GuardedClose::Read;
            while !matches!(step, GuardedClose::RecheckWhileDetached { .. }) {
                step = client.guarded_close_step(&restored, started_by, step).await;
                anyhow::ensure!(
                    !matches!(step, GuardedClose::Done(_)),
                    "The guarded close ended before its recheck: {step:?}"
                );
            }
            restart_private_server(&client, &server, &state).await?;
            anyhow::ensure!(
                client.whoami().await?.instance_id != identity.instance_id,
                "Rex kept its instance across the restart"
            );
            while !matches!(step, GuardedClose::Done(_)) {
                step = client.guarded_close_step(&restored, started_by, step).await;
            }
            anyhow::ensure!(
                step == GuardedClose::Done(OldPane::HandedOver),
                "A shell Rex restored during the guarded close was not handed over: {step:?}"
            );
            let back = client
                .listed_block(&restored)
                .await?
                .ok_or_else(|| anyhow::anyhow!("The restored shell was closed"))?;
            anyhow::ensure!(
                back.placement == Placement::Placed,
                "The restored shell was left out of view"
            );
            anyhow::ensure!(
                matches!(
                    client.read_pane(&restored).await?,
                    PaneRead::Holds {
                        process: TerminalState::Running,
                        ..
                    }
                ),
                "The restored shell no longer runs"
            );
            let windows: NativeWindows = decode(
                &client
                    .run(vec![
                        "window".to_owned(),
                        "ls".to_owned(),
                        "-s".to_owned(),
                        restored.session_id.to_string(),
                        "--json".to_owned(),
                    ])
                    .await
                    .map_err(read_failure)?,
            )?;
            let labels: Vec<_> = windows
                .windows
                .iter()
                .map(|window| window.label.as_str())
                .collect();
            anyhow::ensure!(
                labels == [back.label.as_str()],
                "The restored shell is not back in a window named for it: {labels:?}"
            );
            let deadline =
                tokio::time::Instant::now() + PLACEHOLDER_LIFETIME + Duration::from_secs(5);
            loop {
                let listed: BlockList = decode(
                    &client
                        .api(
                            "session.list_blocks",
                            &SessionRequest {
                                session_id: restored.session_id.clone(),
                            },
                        )
                        .await
                        .map_err(read_failure)?,
                )?;
                if !listed
                    .blocks
                    .iter()
                    .any(|block| block.label == PLACEHOLDER_LABEL)
                {
                    break;
                }
                anyhow::ensure!(
                    tokio::time::Instant::now() < deadline,
                    "The placeholder did not close itself"
                );
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
            anyhow::ensure!(
                client
                    .listed_block(&restored)
                    .await?
                    .is_some_and(|block| block.placement == Placement::Placed),
                "The restored shell left view when the placeholder closed"
            );
            Ok::<_, anyhow::Error>(())
        })
        .await;
        let exited_cleanup = close_test_session(&client, &exited.session_id).await;
        let restored_cleanup = close_test_session(&client, &restored.session_id).await;
        exited_cleanup?;
        restored_cleanup?;
        result.map_err(|_| {
            anyhow::anyhow!("The guarded-close test exceeded its two-minute limit")
        })??;
        eprintln!(
            "Guarded close verified: a legacy pane's own exit closed after its replacement started, and a shell Rex restored between the detach and the recheck went back into view, still running, in a window named for it. Its placeholder then closed itself."
        );
        Ok(())
    }
}

#[cfg(test)]
#[path = "../tests/fixtures/fake_rex.rs"]
pub(crate) mod fake_rex;
