//! Content-free runtime receipts. The actor and service enqueue bounded records;
//! a separate writer owns private files and rotation.
use std::{
    cmp::Reverse,
    collections::BTreeSet,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, PoisonError, Weak},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{
    browser::BrowserResponse,
    protocol::{
        ErrorCode, GoalTarget, HostResult, InputMode, ModelActivity, RuntimeCommand,
        RuntimeEventKind,
    },
};

mod window;
#[cfg(test)]
pub(crate) use window::ClockMoves;
pub(crate) use window::{ReceiptWindow, read_window};

const MAX_BYTES: u64 = 1024 * 1024;
pub(crate) const RETENTION_CAP_BYTES: u64 = 128 * MAX_BYTES;
const CAPACITY: usize = 256;
pub(crate) const HEARTBEAT: Duration = Duration::from_secs(5 * 60);
const LOCK_WAIT: Duration = Duration::from_secs(10);
/// A sender stamps a receipt and then enqueues it without waiting, so two
/// senders can land a few milliseconds out of order, and a replacement writer
/// starts with receipts stamped while the retired one drained its queue. Both
/// are far below a minute. A timestamp that goes back by more is a moved clock.
pub(crate) const STAMP_REORDER_TOLERANCE: Duration = Duration::from_secs(60);
pub(crate) const UNWITNESSED_AFTER: Duration = Duration::from_secs(2 * HEARTBEAT.as_secs());

#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct Record {
    pub timestamp_ms: u64,
    pub request_id: u32,
    pub elapsed_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_id: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub dropped_before: u64,
    #[serde(flatten)]
    pub event: Event,
}

fn is_zero(value: &u64) -> bool {
    *value == 0
}
fn millis(duration: std::time::Duration) -> u64 {
    u64::try_from(duration.as_millis()).unwrap_or(u64::MAX)
}
pub(crate) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, millis)
}
pub(crate) fn is_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_-.:|".contains(&byte))
}
fn token(value: &str) -> Option<String> {
    is_token(value).then(|| value.to_owned())
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub(crate) enum Event {
    ServiceShutdown {
        signal: crate::runtime::ShutdownSignal,
    },
    PeerRejected {
        peer: std::net::SocketAddr,
        reason: String,
    },
    RequestReceived,
    CommandSent {
        command: String,
    },
    WriteBackpressure {
        command: Option<String>,
        written_bytes: usize,
        frame_bytes: usize,
    },
    InputReceived {
        input_id: Option<String>,
        mode: Option<InputMode>,
    },
    InputAccepted {
        input_id: Option<String>,
    },
    InputPlaced {
        input_id: Option<String>,
        entry_id: Option<String>,
    },
    InputRejected {
        input_id: Option<String>,
    },
    Ready,
    FirstActivity,
    ToolStarted {
        call_id: Option<String>,
    },
    ToolFinished {
        call_id: Option<String>,
    },
    Compaction {
        active: bool,
        failed: bool,
    },
    HostCall {
        call_id: Option<String>,
        command: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        embedding: Option<EmbeddingCall>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        browser: Option<BrowserCall>,
    },
    HostReply {
        call_id: Option<String>,
        command: Option<String>,
        duration_ms: u64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        embedding: Option<EmbeddingCall>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        browser: Option<BrowserReceipt>,
    },
    HostCancelRequested {
        call_id: Option<String>,
        duration_ms: Option<u64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        browser: Option<BrowserCall>,
    },
    InterruptReceived,
    ControlIgnored,
    Interrupted,
    Detached,
    Answer,
    Failure {
        code: ErrorCode,
    },
    Done,
    RuntimeStopped {
        code: ErrorCode,
    },
    Heartbeat,
    WriterStarted,
    WriterStopped,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub(crate) struct BrowserCall {
    pub(crate) owner_id: Option<String>,
    pub(crate) session_id: Uuid,
    pub(crate) operation_id: Option<String>,
    pub(crate) action: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) tab_id: Option<u32>,
}

#[derive(Debug, Serialize, Deserialize)]
pub(crate) struct BrowserReceipt {
    #[serde(flatten)]
    pub(crate) call: BrowserCall,
    pub(crate) outcome: BrowserOutcome,
    pub(crate) is_error: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) owned_count: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) cause: Option<BrowserCause>,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BrowserOutcome {
    Ready,
    Closed,
    Disconnected,
    Failed,
    Uncertain,
    HostFailed,
    UnexpectedReply,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum BrowserCause {
    Pairing,
    McpTransport,
    ExtensionAttach,
    EndpointDiscovery,
    BrowserAttach,
    ProfileContext,
    ConnectorIdentity,
    PageCreation,
    ConnectorCleanup,
    McpClosed,
    BrowserDisconnected,
    OwnedPageClosed,
    BrowserOperation,
}
impl BrowserCause {
    fn from_message(message: &str) -> Option<Self> {
        [
            ("Connection stage: pairing.", Self::Pairing),
            ("Connection stage: mcp_transport.", Self::McpTransport),
            ("Connection stage: extension_attach.", Self::ExtensionAttach),
            (
                "Connection stage: endpoint_discovery.",
                Self::EndpointDiscovery,
            ),
            ("Connection stage: browser_attach.", Self::BrowserAttach),
            ("Connection stage: profile_context.", Self::ProfileContext),
            (
                "Connection stage: connector_identity.",
                Self::ConnectorIdentity,
            ),
            ("Connection stage: page_creation.", Self::PageCreation),
            (
                "Connection stage: connector_cleanup.",
                Self::ConnectorCleanup,
            ),
            ("Control lost: mcp_closed.", Self::McpClosed),
            (
                "Control lost: browser_disconnected.",
                Self::BrowserDisconnected,
            ),
            ("Control lost: owned_page_closed.", Self::OwnedPageClosed),
            ("Failure stage: browser_operation.", Self::BrowserOperation),
        ]
        .into_iter()
        .find_map(|(marker, cause)| message.starts_with(marker).then_some(cause))
    }
}

// Decode only identity and action metadata. Serde skips script bodies, URLs,
// form values and every other payload field before a log record is created.
#[derive(Deserialize)]
struct BrowserFrame {
    event: BrowserEvent,
}
#[derive(Deserialize)]
struct BrowserEvent {
    command: BrowserCommand,
}
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum BrowserCommand {
    Browser {
        request: BrowserRequest,
    },
    OnNode {
        command: Box<BrowserCommand>,
    },
    #[serde(other)]
    Other,
}
#[derive(Deserialize)]
struct BrowserRequest {
    owner_id: String,
    session_id: Uuid,
    operation_id: String,
    action: BrowserAction,
}
#[derive(Deserialize)]
struct BrowserAction {
    #[serde(rename = "type")]
    kind: String,
    tab_id: Option<u32>,
}
impl BrowserCall {
    fn decode(bytes: &[u8]) -> Option<Self> {
        let mut command = serde_json::from_slice::<BrowserFrame>(bytes)
            .ok()?
            .event
            .command;
        loop {
            match command {
                BrowserCommand::Browser { request } => {
                    return Some(Self {
                        owner_id: token(&request.owner_id),
                        session_id: request.session_id,
                        operation_id: token(&request.operation_id),
                        action: token(&request.action.kind)?,
                        tab_id: request.action.tab_id,
                    });
                }
                BrowserCommand::OnNode { command: inner } => command = *inner,
                BrowserCommand::Other => return None,
            }
        }
    }

    fn reply(&self, result: &HostResult) -> BrowserReceipt {
        let cause = match result {
            HostResult::Browser {
                response:
                    BrowserResponse::Disconnected { message, .. }
                    | BrowserResponse::Failed { message, .. }
                    | BrowserResponse::Uncertain { message, .. },
            } => BrowserCause::from_message(message),
            _ => None,
        };
        let (outcome, is_error, owned_count) = match result {
            HostResult::Browser { response } => match response {
                BrowserResponse::UserTabs { .. } => (BrowserOutcome::Ready, false, None),
                BrowserResponse::Ready { is_error, tabs, .. } => {
                    (BrowserOutcome::Ready, *is_error, Some(tabs.len()))
                }
                BrowserResponse::Closed { tabs, .. } => {
                    (BrowserOutcome::Closed, !tabs.is_empty(), Some(tabs.len()))
                }
                BrowserResponse::Screenshot { tabs, .. } => {
                    (BrowserOutcome::Ready, false, Some(tabs.len()))
                }
                BrowserResponse::Disconnected { .. } => (BrowserOutcome::Disconnected, true, None),
                BrowserResponse::Failed { .. } => (BrowserOutcome::Failed, true, None),
                BrowserResponse::Uncertain { .. } => (BrowserOutcome::Uncertain, true, None),
            },
            HostResult::Failed { .. } => (BrowserOutcome::HostFailed, true, None),
            _ => (BrowserOutcome::UnexpectedReply, true, None),
        };
        BrowserReceipt {
            call: self.clone(),
            outcome,
            is_error,
            owned_count,
            cause,
        }
    }
}

#[derive(Clone)]
pub(crate) struct Trace {
    started: Option<Instant>,
    conversation_id: Option<String>,
    task_id: Option<String>,
    agent_id: Option<String>,
    active: bool,
}
impl Trace {
    pub fn new(command: &RuntimeCommand) -> Self {
        let mut trace = Self {
            started: Some(Instant::now()),
            conversation_id: None,
            task_id: None,
            agent_id: None,
            active: false,
        };
        match command {
            RuntimeCommand::RunTask {
                task_id, agent_id, ..
            }
            | RuntimeCommand::RevokeAllocation {
                task_id, agent_id, ..
            } => {
                trace.task_id = Some(task_id.to_string());
                trace.agent_id = agent_id.as_deref().and_then(token);
            }
            RuntimeCommand::ReadTask { task_id } => {
                trace.task_id = Some(task_id.to_string());
            }
            RuntimeCommand::Goal {
                target: GoalTarget::Task { task_id, agent_id },
                ..
            } => {
                trace.task_id = Some(task_id.to_string());
                trace.agent_id = agent_id.as_deref().and_then(token);
            }
            RuntimeCommand::Goal {
                target: GoalTarget::Conversation { conversation_id },
                ..
            } => {
                trace.conversation_id = token(conversation_id);
            }
            RuntimeCommand::ReadHistory {
                task_id, agent_id, ..
            }
            | RuntimeCommand::ConversationSettings {
                task_id, agent_id, ..
            } => {
                trace.task_id = task_id.as_ref().map(ToString::to_string);
                trace.agent_id = agent_id.as_deref().and_then(token);
            }
            RuntimeCommand::ReadConversation {
                conversation_id, ..
            }
            | RuntimeCommand::OpenConversation {
                conversation_id, ..
            }
            | RuntimeCommand::AttachConversation {
                conversation_id, ..
            }
            | RuntimeCommand::ConversationInput {
                conversation_id, ..
            }
            | RuntimeCommand::ConversationInterrupt {
                conversation_id, ..
            }
            | RuntimeCommand::ConversationUsage {
                conversation_id, ..
            } => {
                trace.conversation_id = token(conversation_id);
            }
            _ => {}
        }
        trace
    }
    pub fn unowned() -> Self {
        Self {
            started: None,
            conversation_id: None,
            task_id: None,
            agent_id: None,
            active: false,
        }
    }
    pub fn input(&self, command: &RuntimeCommand) -> Option<Event> {
        match command {
            RuntimeCommand::Chat { input_id, .. } => Some(Event::InputReceived {
                input_id: input_id.as_deref().and_then(token),
                mode: None,
            }),
            RuntimeCommand::SubmitInput { input_id, mode, .. }
            | RuntimeCommand::MainInput { input_id, mode, .. }
            | RuntimeCommand::ConversationInput { input_id, mode, .. } => {
                Some(Event::InputReceived {
                    input_id: token(input_id),
                    mode: Some(*mode),
                })
            }
            RuntimeCommand::WorkerInput { input_id, .. } => Some(Event::InputReceived {
                input_id: token(input_id),
                mode: None,
            }),
            RuntimeCommand::Interrupt
            | RuntimeCommand::MainInterrupt
            | RuntimeCommand::ConversationInterrupt { .. } => Some(Event::InterruptReceived),
            _ => None,
        }
    }
    pub fn observe(&mut self, event: &RuntimeEventKind) -> [Option<Event>; 2] {
        match event {
            RuntimeEventKind::MainReady {
                conversation_id, ..
            }
            | RuntimeEventKind::TaskReady {
                conversation_id, ..
            }
            | RuntimeEventKind::History {
                conversation_id, ..
            }
            | RuntimeEventKind::Answer {
                conversation_id, ..
            } => self.conversation_id = token(conversation_id),
            RuntimeEventKind::ConversationSettings { settings } => {
                self.conversation_id = token(&settings.conversation_id);
                self.task_id = settings.task_id.as_ref().map(ToString::to_string);
                self.agent_id = settings.agent_id.as_deref().and_then(token);
            }
            RuntimeEventKind::ConversationReady { conversation, .. } => {
                self.conversation_id = token(&conversation.conversation_id);
                self.task_id = conversation.task_id.as_ref().map(ToString::to_string);
                self.agent_id = conversation.agent_id.as_deref().and_then(token);
            }
            _ => {}
        }
        let first = if !self.active
            && matches!(
                event,
                RuntimeEventKind::Activity { .. } | RuntimeEventKind::Answer { .. }
            ) {
            self.active = true;
            Some(Event::FirstActivity)
        } else {
            None
        };
        let observed = match event {
            RuntimeEventKind::MainReady { .. }
            | RuntimeEventKind::TaskReady { .. }
            | RuntimeEventKind::ConversationReady { .. } => Some(Event::Ready),
            RuntimeEventKind::InputAccepted { input_id, .. } => Some(Event::InputAccepted {
                input_id: token(input_id),
            }),
            RuntimeEventKind::InputPlaced { input_id, entry_id } => Some(Event::InputPlaced {
                input_id: token(input_id),
                entry_id: token(entry_id),
            }),
            RuntimeEventKind::InputRejected { input_id, .. } => Some(Event::InputRejected {
                input_id: token(input_id),
            }),
            RuntimeEventKind::Activity {
                activity: ModelActivity::ToolStarted { call_id, .. },
            } => Some(Event::ToolStarted {
                call_id: token(call_id),
            }),
            RuntimeEventKind::Activity {
                activity: ModelActivity::ToolFinished { call_id, .. },
            } => Some(Event::ToolFinished {
                call_id: token(call_id),
            }),
            RuntimeEventKind::Activity {
                activity: ModelActivity::Compaction { active, failed },
            } => Some(Event::Compaction {
                active: *active,
                failed: *failed,
            }),
            RuntimeEventKind::Interrupted => Some(Event::Interrupted),
            RuntimeEventKind::Answer { .. } => Some(Event::Answer),
            RuntimeEventKind::Failure { code, .. } => Some(Event::Failure { code: code.clone() }),
            RuntimeEventKind::Done => Some(Event::Done),
            _ => None,
        };
        [first, observed]
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct EmbeddingCall {
    purpose: crate::embeddings::EmbeddingPurpose,
    texts: usize,
}
impl EmbeddingCall {
    fn from_command(command: &crate::protocol::HostCommand) -> Option<Self> {
        match command {
            crate::protocol::HostCommand::Embed { texts, purpose } => Some(Self {
                purpose: *purpose,
                texts: texts.len(),
            }),
            crate::protocol::HostCommand::OnNode { command, .. } => Self::from_command(command),
            _ => None,
        }
    }
}

pub(crate) struct HostTiming {
    pub started: Instant,
    pub command: Option<String>,
    browser: Option<BrowserCall>,
    embedding: Option<EmbeddingCall>,
}
impl HostTiming {
    pub fn new(bytes: &[u8], command: &crate::protocol::HostCommand) -> Self {
        Self {
            started: Instant::now(),
            command: host_kind(bytes),
            browser: BrowserCall::decode(bytes),
            embedding: EmbeddingCall::from_command(command),
        }
    }
    pub fn received(&self, call_id: &str) -> Event {
        Event::HostCall {
            call_id: token(call_id),
            command: self.command.clone(),
            embedding: self.embedding.clone(),
            browser: self.browser.clone(),
        }
    }
    pub fn reply(&self, call_id: &str, result: &HostResult) -> Event {
        Event::HostReply {
            call_id: token(call_id),
            command: self.command.clone(),
            duration_ms: millis(self.started.elapsed()),
            embedding: self.embedding.clone(),
            browser: self.browser.as_ref().map(|browser| browser.reply(result)),
        }
    }
    pub fn cancel(call_id: &str, timing: Option<&Self>) -> Event {
        Event::HostCancelRequested {
            call_id: token(call_id),
            duration_ms: timing.map(|timing| millis(timing.started.elapsed())),
            browser: timing.and_then(|timing| timing.browser.clone()),
        }
    }
}

// These narrow wire views skip all payload fields. Tags come from the existing
// protocol serializer/decoder; diagnostics has no duplicate command registry.
#[derive(Deserialize)]
struct Tag {
    #[serde(rename = "type")]
    kind: String,
    command: Option<Box<Tag>>,
}
impl Tag {
    fn leaf(self) -> Option<String> {
        match self.command {
            Some(child) if self.kind == "on_node" => child.leaf(),
            _ => token(&self.kind),
        }
    }
}
#[derive(Deserialize)]
struct CommandTag {
    command: Tag,
}
#[derive(Deserialize)]
struct HostTag {
    event: CommandTag,
}
pub(crate) fn command_kind(bytes: &[u8]) -> Option<String> {
    serde_json::from_slice::<CommandTag>(bytes)
        .ok()?
        .command
        .leaf()
}
fn host_kind(bytes: &[u8]) -> Option<String> {
    serde_json::from_slice::<HostTag>(bytes)
        .ok()?
        .event
        .command
        .leaf()
}

/// Receipts lost on a full channel, from the drop until a written receipt
/// reports them. A reader in this process counts both fields, so a loss is
/// never invisible while its report waits in the channel or in the writer.
#[derive(Default)]
struct DropLedger {
    /// Dropped, and not yet carried by any receipt.
    unreported: u64,
    /// Carried by a receipt that was sent and is not on disk yet.
    reported_unwritten: u64,
}
type SharedDrops = Arc<Mutex<DropLedger>>;

/// The ledgers of live writers in this process, by diagnostics directory. The
/// reader finds them here because the runtime that owns a writer and the
/// broker that owns a review are built apart, and a retiring writer and its
/// replacement can both be live for one directory.
static LIVE_DROP_LEDGERS: Mutex<Vec<(PathBuf, Weak<Mutex<DropLedger>>)>> = Mutex::new(Vec::new());

fn registry_key(directory: &Path) -> PathBuf {
    std::path::absolute(directory).unwrap_or_else(|_| directory.to_owned())
}

fn undelivered_drops(directory: &Path) -> u64 {
    let key = registry_key(directory);
    LIVE_DROP_LEDGERS
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .iter()
        .filter(|(live, _)| *live == key)
        .filter_map(|(_, ledger)| ledger.upgrade())
        .fold(0, |total, ledger| {
            let ledger = ledger.lock().unwrap_or_else(PoisonError::into_inner);
            total
                .saturating_add(ledger.unreported)
                .saturating_add(ledger.reported_unwritten)
        })
}

fn writer_receipt(event: Event, dropped_before: u64) -> Record {
    Record {
        timestamp_ms: now_ms(),
        request_id: 0,
        elapsed_ms: None,
        conversation_id: None,
        task_id: None,
        agent_id: None,
        dropped_before,
        event,
    }
}

/// What a record that finds the channel full means for the ledger.
#[derive(Clone, Copy)]
enum WhenFull {
    /// The record is a receipt, and losing it is a loss to report.
    CountAsLost,
    /// The record is a heartbeat, which witnesses time and reports nothing.
    Forget,
}

/// Sends without waiting. A record that gets through carries the count of the
/// receipts that did not, whichever sender dropped them.
fn deliver(
    sender: &mpsc::Sender<Record>,
    drops: &Mutex<DropLedger>,
    mut record: Record,
    when_full: WhenFull,
) {
    let mut ledger = drops.lock().unwrap_or_else(PoisonError::into_inner);
    record.dropped_before = ledger.unreported;
    match sender.try_send(record) {
        Ok(()) => {
            ledger.reported_unwritten = ledger.reported_unwritten.saturating_add(ledger.unreported);
            ledger.unreported = 0;
        }
        Err(mpsc::error::TrySendError::Full(_)) => {
            if let WhenFull::CountAsLost = when_full {
                ledger.unreported = ledger.unreported.saturating_add(1);
            }
        }
        Err(mpsc::error::TrySendError::Closed(_)) => {}
    }
}

/// Appends a record, and only then stops counting the drops it reports.
fn append_reported(
    writer: &mut Writer,
    drops: &Mutex<DropLedger>,
    record: &Record,
) -> io::Result<()> {
    writer.append(record)?;
    if record.dropped_before > 0 {
        let mut ledger = drops.lock().unwrap_or_else(PoisonError::into_inner);
        ledger.reported_unwritten = ledger
            .reported_unwritten
            .saturating_sub(record.dropped_before);
    }
    Ok(())
}

pub(crate) struct Diagnostics {
    sender: mpsc::Sender<Record>,
    drops: SharedDrops,
}

#[must_use]
pub(crate) struct WriterStart(std::sync::mpsc::Receiver<io::Result<()>>);
impl WriterStart {
    pub fn wait(self) -> io::Result<()> {
        self.0.recv().map_err(io::Error::other)?
    }
}

impl Diagnostics {
    pub fn fork(&self) -> Self {
        Self {
            sender: self.sender.clone(),
            drops: self.drops.clone(),
        }
    }
    pub fn start(state: &Path) -> (Self, WriterStart) {
        Self::start_with_heartbeat(state, HEARTBEAT)
    }
    fn open_channel(directory: &Path, capacity: usize) -> (Self, mpsc::Receiver<Record>) {
        let (sender, records) = mpsc::channel(capacity);
        let drops = SharedDrops::default();
        let mut live = LIVE_DROP_LEDGERS
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        live.retain(|(_, ledger)| ledger.strong_count() > 0);
        live.push((registry_key(directory), Arc::downgrade(&drops)));
        (Self { sender, drops }, records)
    }
    fn start_with_heartbeat(state: &Path, interval: Duration) -> (Self, WriterStart) {
        let directory = state.join("diagnostics");
        let (diagnostics, mut records) = Self::open_channel(&directory, CAPACITY);
        // A weak sender lets the writer end when its last real producer does.
        let witness = diagnostics.sender.downgrade();
        let drops = diagnostics.drops.clone();
        tokio::spawn(async move {
            let mut ticks =
                tokio::time::interval_at(tokio::time::Instant::now() + interval, interval);
            ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                ticks.tick().await;
                let Some(sender) = witness.upgrade() else {
                    return;
                };
                deliver(
                    &sender,
                    &drops,
                    writer_receipt(Event::Heartbeat, 0),
                    WhenFull::Forget,
                );
            }
        });
        let drops = diagnostics.drops.clone();
        let (started, start) = std::sync::mpsc::sync_channel(1);
        tokio::task::spawn_blocking(move || {
            let opened = Writer::open(directory, MAX_BYTES).and_then(|mut writer| {
                writer
                    .append(&writer_receipt(Event::WriterStarted, 0))
                    .map(|()| writer)
            });
            let mut writer = match opened {
                Ok(writer) => writer,
                Err(error) => {
                    let _ = started.send(Err(error));
                    return;
                }
            };
            let _ = started.send(Ok(()));
            let result = (|| -> io::Result<()> {
                while let Some(record) = records.blocking_recv() {
                    append_reported(&mut writer, &drops, &record)?;
                }
                // The last sender is gone, so nothing else can report these.
                let mut ledger = drops.lock().unwrap_or_else(PoisonError::into_inner);
                writer.append(&writer_receipt(Event::WriterStopped, ledger.unreported))?;
                ledger.unreported = 0;
                Ok(())
            })();
            if result.is_err() {
                eprintln!("Runtime diagnostics unavailable; chat continues.");
            }
        });
        (diagnostics, WriterStart(start))
    }
    pub fn record(&mut self, request_id: u32, trace: &Trace, event: Event) {
        let record = Record {
            timestamp_ms: now_ms(),
            request_id,
            elapsed_ms: trace.started.map(|started| millis(started.elapsed())),
            conversation_id: trace.conversation_id.clone(),
            task_id: trace.task_id.clone(),
            agent_id: trace.agent_id.clone(),
            dropped_before: 0,
            event,
        };
        deliver(&self.sender, &self.drops, record, WhenFull::CountAsLost);
    }
}

/// The total cap includes room for the watermark and its atomic replacement.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct RetentionPolicy {
    segment_bytes: u64,
    horizon_ms: u64,
    max_total_bytes: u64,
}
impl Default for RetentionPolicy {
    fn default() -> Self {
        Self {
            segment_bytes: MAX_BYTES,
            horizon_ms: 48 * 60 * 60 * 1000,
            max_total_bytes: RETENTION_CAP_BYTES,
        }
    }
}
const WATERMARK_BYTES: u64 = 4096;
impl RetentionPolicy {
    fn receipt_budget(self) -> io::Result<u64> {
        self.max_total_bytes
            .checked_sub(2 * WATERMARK_BYTES)
            .filter(|budget| {
                self.segment_bytes > 0 && *budget >= self.segment_bytes && self.horizon_ms > 0
            })
            .ok_or_else(|| io::Error::other("Diagnostics retention policy is too small"))
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct Timestamps {
    first: Option<u64>,
    last: Option<u64>,
    unknown: bool,
}
impl Timestamps {
    fn observe(&mut self, timestamp: u64) {
        self.first = Some(self.first.map_or(timestamp, |first| first.min(timestamp)));
        self.last = Some(self.last.map_or(timestamp, |last| last.max(timestamp)));
    }
    fn expired(self, cutoff: u64) -> bool {
        !self.unknown && self.last.is_none_or(|last| last < cutoff)
    }
}
struct Segment {
    index: u32,
    bytes: u64,
    timestamps: Timestamps,
}
impl Segment {
    fn path(directory: &Path, index: u32) -> PathBuf {
        directory.join(if index == 0 {
            "runtime.jsonl".into()
        } else {
            format!("runtime.jsonl.{index}")
        })
    }
    fn read(file: &File, index: u32) -> io::Result<Self> {
        #[derive(Deserialize)]
        struct Timestamp {
            timestamp_ms: u64,
        }
        let mut segment = Self {
            index,
            bytes: file.metadata()?.len(),
            timestamps: Timestamps::default(),
        };
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        while reader.read_until(b'\n', &mut line)? != 0 {
            match serde_json::from_slice::<Timestamp>(&line) {
                Ok(record) => segment.timestamps.observe(record.timestamp_ms),
                Err(_) => segment.timestamps.unknown = true,
            }
            line.clear();
        }
        Ok(segment)
    }
}

/// Bounds summarize capacity loss; they do not claim every timestamp between
/// them was lost. An interrupted prune can conservatively report possible loss.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub(crate) struct CapacityLoss {
    pub(crate) first_timestamp_ms: Option<u64>,
    pub(crate) last_timestamp_ms: Option<u64>,
    pub(crate) unknown_timestamps: bool,
    pub(crate) segments: u64,
    pub(crate) bytes: u64,
}
impl CapacityLoss {
    fn include(&mut self, segment: &Segment) {
        if let Some(first) = segment.timestamps.first {
            self.first_timestamp_ms =
                Some(self.first_timestamp_ms.map_or(first, |old| old.min(first)));
        }
        if let Some(last) = segment.timestamps.last {
            self.last_timestamp_ms = Some(self.last_timestamp_ms.map_or(last, |old| old.max(last)));
        }
        self.unknown_timestamps |= segment.timestamps.unknown;
        self.segments = self.segments.saturating_add(1);
        self.bytes = self.bytes.saturating_add(segment.bytes);
    }
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct RetentionWatermark {
    pub(crate) version: u32,
    pub(crate) policy: RetentionPolicy,
    pub(crate) prior_history_unknown: bool,
    pub(crate) expired_through_ms: Option<u64>,
    pub(crate) capacity_loss: Option<CapacityLoss>,
}

struct Writer {
    lock: File,
    directory: PathBuf,
    file: File,
    current: Segment,
    // Oldest first, including the legacy .2 / .1 ordering after an upgrade.
    archives: Vec<Segment>,
    policy: RetentionPolicy,
    watermark: RetentionWatermark,
}
impl Drop for Writer {
    fn drop(&mut self) {
        // Close alone waits for every inherited/duplicated descriptor. This
        // writer owns the lock, so end that ownership explicitly before drop.
        let _ = fs2::FileExt::unlock(&self.lock);
    }
}

impl Writer {
    fn open(directory: PathBuf, segment_bytes: u64) -> io::Result<Self> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, millis);
        Self::open_at(
            directory,
            RetentionPolicy {
                segment_bytes,
                ..RetentionPolicy::default()
            },
            now,
        )
    }
    fn open_at(directory: PathBuf, policy: RetentionPolicy, now: u64) -> io::Result<Self> {
        policy.receipt_budget()?;
        match fs::DirBuilder::new().mode(0o700).create(&directory) {
            Ok(()) => {}
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
        if !fs::symlink_metadata(&directory)?.is_dir() {
            return Err(io::Error::other("Diagnostics directory is unavailable"));
        }
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let path = directory.join("writer.lock");
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)?;
        lock.set_permissions(fs::Permissions::from_mode(0o600))?;
        let deadline = Instant::now() + LOCK_WAIT;
        while let Err(error) = fs2::FileExt::try_lock_exclusive(&lock) {
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
            if Instant::now() >= deadline {
                return Err(io::Error::other(format!(
                    "Another process has held {} for {} seconds",
                    path.display(),
                    LOCK_WAIT.as_secs()
                )));
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        let file = Self::file(&directory)?;
        let current = Segment::read(&file, 0)?;
        let mut archives = Vec::new();
        for entry in fs::read_dir(&directory)? {
            let entry = entry?;
            let name = entry.file_name();
            let Some(index) = name
                .to_str()
                .and_then(|name| name.strip_prefix("runtime.jsonl."))
                .and_then(|suffix| suffix.parse::<u32>().ok())
                .filter(|index| *index > 0)
            else {
                continue;
            };
            if name != format!("runtime.jsonl.{index}").as_str() {
                continue;
            }
            let archive = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(entry.path())?;
            if !archive.metadata()?.is_file() {
                return Err(io::Error::other(
                    "Diagnostics segment is not a regular file",
                ));
            }
            archive.set_permissions(fs::Permissions::from_mode(0o600))?;
            archives.push(Segment::read(&archive, index)?);
        }
        archives.sort_unstable_by_key(|segment| Reverse(segment.index));
        let mut watermark = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("retention.json"))
        {
            Ok(file) => {
                if !file.metadata()?.is_file() || file.metadata()?.len() > WATERMARK_BYTES {
                    return Err(io::Error::other(
                        "Diagnostics retention watermark is unavailable",
                    ));
                }
                file.set_permissions(fs::Permissions::from_mode(0o600))?;
                let mut watermark: RetentionWatermark = serde_json::from_reader(file)?;
                if watermark.version != 1 {
                    return Err(io::Error::other(
                        "Unsupported diagnostics retention watermark",
                    ));
                }
                watermark.policy = policy;
                watermark
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => RetentionWatermark {
                version: 1,
                policy,
                prior_history_unknown: current.bytes > 0
                    || archives.iter().any(|segment| segment.bytes > 0),
                expired_through_ms: None,
                capacity_loss: None,
            },
            Err(error) => return Err(error),
        };
        watermark.prior_history_unknown |=
            current.timestamps.unknown || archives.iter().any(|segment| segment.timestamps.unknown);
        let mut writer = Self {
            lock,
            directory,
            file,
            current,
            archives,
            policy,
            watermark,
        };
        if writer.current.bytes > 0
            && writer
                .current
                .timestamps
                .expired(now.saturating_sub(policy.horizon_ms))
        {
            writer.rotate()?;
        }
        writer.prune(now, 0, true)?;
        Ok(writer)
    }
    fn file(directory: &Path) -> io::Result<File> {
        let file = OpenOptions::new()
            .read(true)
            .append(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(directory.join("runtime.jsonl"))?;
        if !file.metadata()?.is_file() {
            return Err(io::Error::other(
                "Diagnostics segment is not a regular file",
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        Ok(file)
    }
    fn rotate(&mut self) -> io::Result<()> {
        for segment in &mut self.archives {
            let next = segment
                .index
                .checked_add(1)
                .ok_or_else(|| io::Error::other("Diagnostics segment index overflow"))?;
            fs::rename(
                Segment::path(&self.directory, segment.index),
                Segment::path(&self.directory, next),
            )?;
            segment.index = next;
        }
        fs::rename(
            Segment::path(&self.directory, 0),
            Segment::path(&self.directory, 1),
        )?;
        self.file = Self::file(&self.directory)?;
        self.archives.push(std::mem::replace(
            &mut self.current,
            Segment {
                index: 0,
                bytes: 0,
                timestamps: Timestamps::default(),
            },
        ));
        if let Some(previous) = self.archives.last_mut() {
            previous.index = 1;
        }
        Ok(())
    }
    fn save_watermark(&self, watermark: &RetentionWatermark) -> io::Result<()> {
        let path = self.directory.join("retention.json");
        match fs::symlink_metadata(&path) {
            Ok(metadata) if !metadata.is_file() => {
                return Err(io::Error::other(
                    "Diagnostics retention watermark is unavailable",
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
        let bytes = serde_json::to_vec(watermark)?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > WATERMARK_BYTES {
            return Err(io::Error::other(
                "Diagnostics retention watermark exceeds its bound",
            ));
        }
        let temporary = self.directory.join("retention.json.tmp");
        let mut file = OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&temporary)?;
        if !file.metadata()?.is_file() {
            return Err(io::Error::other(
                "Diagnostics retention replacement is unavailable",
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        fs::rename(temporary, path)?;
        // The rename itself must be durable before any receipt is unlinked.
        File::open(&self.directory)?.sync_all()
    }
    fn prune(&mut self, now: u64, incoming: u64, force_watermark: bool) -> io::Result<()> {
        let cutoff = now.saturating_sub(self.policy.horizon_ms);
        let mut bytes = self
            .archives
            .iter()
            .try_fold(self.current.bytes, |bytes, segment| {
                bytes
                    .checked_add(segment.bytes)
                    .ok_or_else(|| io::Error::other("Diagnostics byte count overflow"))
            })?;
        let mut remove = BTreeSet::new();
        let mut watermark = self.watermark.clone();
        for segment in &self.archives {
            if segment.timestamps.expired(cutoff) {
                remove.insert(segment.index);
                bytes -= segment.bytes;
                if let Some(last) = segment.timestamps.last {
                    watermark.expired_through_ms = Some(
                        watermark
                            .expired_through_ms
                            .map_or(last, |old| old.max(last)),
                    );
                }
            }
        }
        let budget = self.policy.receipt_budget()?.saturating_sub(incoming);
        for segment in &self.archives {
            if bytes <= budget {
                break;
            }
            if remove.insert(segment.index) {
                bytes -= segment.bytes;
                watermark
                    .capacity_loss
                    .get_or_insert_with(CapacityLoss::default)
                    .include(segment);
            }
        }
        if bytes > budget {
            return Err(io::Error::other(
                "Diagnostics current segment exceeds its retention budget",
            ));
        }
        if force_watermark || !remove.is_empty() {
            // Persist possible loss before unlinking. A crash can overstate a
            // gap, but cannot silently erase its only coverage receipt.
            self.save_watermark(&watermark)?;
            self.watermark = watermark;
            for index in &remove {
                fs::remove_file(Segment::path(&self.directory, *index))?;
            }
            self.archives
                .retain(|segment| !remove.contains(&segment.index));
        }
        Ok(())
    }
    fn append(&mut self, record: &Record) -> io::Result<()> {
        let mut bytes = serde_json::to_vec(record)?;
        bytes.push(b'\n');
        let length = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        if bytes.len() > 4096 || length > self.policy.segment_bytes {
            return Err(io::Error::other("Diagnostics record exceeds its bound"));
        }
        if self.current.bytes > 0
            && (self.current.bytes + length > self.policy.segment_bytes
                || self
                    .current
                    .timestamps
                    .expired(record.timestamp_ms.saturating_sub(self.policy.horizon_ms)))
        {
            self.rotate()?;
        }
        self.prune(record.timestamp_ms, length, false)?;
        self.file.write_all(&bytes)?;
        self.current.bytes += length;
        self.current.timestamps.observe(record.timestamp_ms);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use crate::protocol::{InputMode, MainInputContext, RuntimeCommand, RuntimeRequest};
    use crate::runtime::diagnostics::{
        Diagnostics, Event, Record, RetentionPolicy, RetentionWatermark, Trace, WATERMARK_BYTES,
        Writer, command_kind, read_window,
    };
    use std::{
        fs,
        os::unix::fs::{PermissionsExt, symlink},
    };
    use tokio::sync::mpsc;

    #[test]
    fn embedding_receipts_distinguish_indexing_from_queries_without_text() {
        use crate::embeddings::EmbeddingPurpose;
        use crate::protocol::{
            HostCommand, HostResult, PROTOCOL_VERSION, RuntimeEvent, RuntimeEventKind,
        };
        use crate::runtime::diagnostics::HostTiming;

        for purpose in [EmbeddingPurpose::Query, EmbeddingPurpose::Document] {
            let command = HostCommand::OnNode {
                host_id: "synthetic-worker".into(),
                command: Box::new(HostCommand::Embed {
                    texts: vec!["PRIVATE_EMBEDDING_TEXT_SENTINEL".into(); 2],
                    purpose,
                }),
            };
            let frame = RuntimeEvent {
                version: PROTOCOL_VERSION,
                id: 1,
                event: RuntimeEventKind::HostCall {
                    call_id: "embedding-call".into(),
                    command: Box::new(command.clone()),
                },
            };
            let timing = HostTiming::new(&serde_json::to_vec(&frame).unwrap(), &command);
            let events = [
                timing.received("embedding-call"),
                timing.reply(
                    "embedding-call",
                    &HostResult::Failed {
                        delivery: None,
                        message: "PRIVATE_EMBEDDING_ERROR_SENTINEL".into(),
                    },
                ),
            ];
            for event in events {
                let encoded = serde_json::to_string(&event).unwrap();
                assert!(!encoded.contains("PRIVATE_"));
                let embedding = match event {
                    Event::HostCall { embedding, .. } | Event::HostReply { embedding, .. } => {
                        embedding.unwrap()
                    }
                    _ => panic!("Expected an embedding lifecycle receipt"),
                };
                assert_eq!(embedding.texts, 2);
                assert_eq!(embedding.purpose, purpose);
            }
        }
    }

    fn record(sequence: u32) -> Record {
        Record {
            timestamp_ms: 1234,
            request_id: sequence,
            elapsed_ms: Some(12),
            conversation_id: Some("conversation-one".into()),
            task_id: None,
            agent_id: None,
            dropped_before: 0,
            event: Event::InputReceived {
                input_id: Some("opaque-input-id".into()),
                mode: Some(InputMode::Steer),
            },
        }
    }

    fn receipts(directory: &std::path::Path) -> Vec<Record> {
        let mut records = Vec::new();
        for entry in fs::read_dir(directory).unwrap() {
            let path = entry.unwrap().path();
            if !path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name == "runtime.jsonl" || name.starts_with("runtime.jsonl."))
            {
                continue;
            }
            for line in fs::read_to_string(path).unwrap().lines() {
                records.push(serde_json::from_str::<Record>(line).unwrap());
            }
        }
        records.sort_unstable_by_key(|record| record.request_id);
        records
    }

    fn watermark(directory: &std::path::Path) -> RetentionWatermark {
        serde_json::from_slice(&fs::read(directory.join("retention.json")).unwrap()).unwrap()
    }

    fn policy(receipt_budget: u64) -> RetentionPolicy {
        RetentionPolicy {
            segment_bytes: 600,
            max_total_bytes: 2 * WATERMARK_BYTES + receipt_budget,
            ..RetentionPolicy::default()
        }
    }

    #[test]
    fn in_horizon_receipts_survive_more_than_three_native_segments() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open(directory.clone(), 600).unwrap();
        for sequence in 0..50 {
            let mut receipt = record(sequence);
            receipt.timestamp_ms = 1_000_000 + u64::from(sequence);
            writer.append(&receipt).unwrap();
        }
        drop(writer);
        let retained = receipts(&directory);
        assert_eq!(
            retained
                .iter()
                .map(|record| record.request_id)
                .collect::<Vec<_>>(),
            (0..50).collect::<Vec<_>>(),
            "Size rotation must retain the full recent audit interval"
        );
    }

    #[test]
    fn expired_segments_leave_before_capacity_and_startup_reconciles_actual_files() {
        const HOUR: u64 = 60 * 60 * 1000;
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let now = 72 * HOUR;
        let old = now - 49 * HOUR;
        let mut writer = Writer::open_at(directory.clone(), policy(1800), old).unwrap();
        for sequence in 0..6 {
            let mut receipt = record(sequence);
            receipt.timestamp_ms = old + u64::from(sequence);
            writer.append(&receipt).unwrap();
        }
        let mut recent = record(6);
        recent.timestamp_ms = now;
        writer.append(&recent).unwrap();
        assert_eq!(
            receipts(&directory)
                .iter()
                .map(|record| record.request_id)
                .collect::<Vec<_>>(),
            [6]
        );
        let retained = watermark(&directory);
        assert_eq!(retained.expired_through_ms, Some(old + 5));
        assert!(
            retained.capacity_loss.is_none(),
            "Expiry must free space before evicting young receipts"
        );
        drop(writer);
        let writer = Writer::open_at(directory.clone(), policy(1800), now + 49 * HOUR).unwrap();
        assert!(
            receipts(&directory).is_empty(),
            "A quiet active segment must expire on reopening too"
        );
        assert_eq!(watermark(&directory).expired_through_ms, Some(now));
        drop(writer);
    }

    #[test]
    fn capacity_eviction_reports_its_interval_separately_from_channel_overflow() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let retention = policy(1800);
        let mut writer = Writer::open_at(directory.clone(), retention, 1_000_000).unwrap();
        for sequence in 0..50 {
            let mut receipt = record(sequence);
            receipt.timestamp_ms = 1_000_000 + u64::from(sequence);
            writer.append(&receipt).unwrap();
        }
        let records = receipts(&directory);
        assert!(records.len() < 50);
        assert_eq!(records.last().unwrap().request_id, 49);
        assert!(records.iter().all(|record| record.dropped_before == 0));
        let retained = watermark(&directory);
        let loss = retained.capacity_loss.as_ref().unwrap();
        assert_eq!(loss.first_timestamp_ms, Some(1_000_000));
        assert_eq!(loss.last_timestamp_ms, Some(records[0].timestamp_ms - 1));
        assert!(!loss.unknown_timestamps);
        assert!(loss.bytes > 0 && loss.segments > 0);
        assert!(retained.expired_through_ms.is_none());
        let total: u64 = fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().metadata().unwrap().len())
            .sum();
        assert!(total <= retention.max_total_bytes);
        drop(writer);
        let writer = Writer::open_at(directory.clone(), retention, 1_000_050).unwrap();
        assert_eq!(
            watermark(&directory),
            retained,
            "Reopening must preserve the historical capacity gap"
        );
        assert_eq!(receipts(&directory).len(), records.len());
        drop(writer);
    }

    #[test]
    fn legacy_rotations_reopen_without_discarding_receipts_and_remain_private() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        fs::create_dir(&directory).unwrap();
        for (name, sequence) in [
            ("runtime.jsonl.2", 0),
            ("runtime.jsonl.1", 1),
            ("runtime.jsonl", 2),
        ] {
            let mut bytes = serde_json::to_vec(&record(sequence)).unwrap();
            bytes.push(b'\n');
            fs::write(directory.join(name), bytes).unwrap();
        }
        let mut writer = Writer::open_at(directory.clone(), policy(12_000), 1234).unwrap();
        for sequence in 3..20 {
            writer.append(&record(sequence)).unwrap();
        }
        drop(writer);
        assert_eq!(
            receipts(&directory)
                .iter()
                .map(|record| record.request_id)
                .collect::<Vec<_>>(),
            (0..20).collect::<Vec<_>>()
        );
        assert!(
            watermark(&directory).prior_history_unknown,
            "Legacy retained files cannot establish coverage before their first receipt"
        );
        for entry in fs::read_dir(&directory).unwrap() {
            assert_eq!(
                entry.unwrap().metadata().unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        let writer = Writer::open_at(directory.clone(), policy(12_000), 1234).unwrap();
        assert_eq!(receipts(&directory).len(), 20);
        drop(writer);
    }

    #[test]
    fn clock_rollback_does_not_expire_fresh_or_future_dated_segments() {
        const HOUR: u64 = 60 * 60 * 1000;
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open_at(directory.clone(), policy(12_000), 72 * HOUR).unwrap();
        for sequence in 0..20 {
            let mut receipt = record(sequence);
            receipt.timestamp_ms =
                if sequence < 10 { 72 * HOUR } else { 12 * HOUR } + u64::from(sequence);
            writer.append(&receipt).unwrap();
        }
        drop(writer);
        let writer = Writer::open_at(directory.clone(), policy(12_000), 12 * HOUR + 20).unwrap();
        assert_eq!(receipts(&directory).len(), 20);
        let retained = watermark(&directory);
        assert!(retained.expired_through_ms.is_none() && retained.capacity_loss.is_none());
        drop(writer);
    }

    #[test]
    fn native_segments_and_retention_metadata_remain_private_and_bounded() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open(directory.clone(), 600).unwrap();
        for sequence in 0..50 {
            writer.append(&record(sequence)).unwrap();
        }
        drop(writer);
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        let paths = fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .collect::<Vec<_>>();
        assert!(paths.len() > 4);
        let mut retained = Vec::new();
        for path in paths {
            let metadata = fs::metadata(&path).unwrap();
            assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
            if path.file_name().is_some_and(|name| name == "writer.lock") {
                continue;
            }
            if path
                .file_name()
                .is_some_and(|name| name == "retention.json")
            {
                assert!(metadata.len() <= WATERMARK_BYTES);
                continue;
            }
            assert!(metadata.len() <= 600);
            for line in fs::read_to_string(path).unwrap().lines() {
                retained.push(serde_json::from_str::<Record>(line).unwrap().request_id);
            }
        }
        retained.sort_unstable();
        assert_eq!(retained.last(), Some(&49));
        assert_eq!(retained.len(), 50);
        assert!(retained.windows(2).all(|pair| pair[1] == pair[0] + 1));
    }

    #[test]
    fn diagnostics_refuses_symlinks_without_touching_the_target() {
        let state = tempfile::tempdir().unwrap();
        let target = state.path().join("private-target");
        fs::write(&target, "Preserve unrelated contents").unwrap();
        let directory = state.path().join("diagnostics");
        fs::create_dir(&directory).unwrap();
        symlink(&target, directory.join("runtime.jsonl")).unwrap();
        assert!(Writer::open(directory, 600).is_err());
        assert_eq!(
            fs::read_to_string(target).unwrap(),
            "Preserve unrelated contents"
        );
        let elsewhere = tempfile::tempdir().unwrap();
        let linked = state.path().join("linked");
        symlink(elsewhere.path(), &linked).unwrap();
        assert!(Writer::open(linked, 600).is_err());
        assert_eq!(fs::read_dir(elsewhere.path()).unwrap().count(), 0);
    }

    #[test]
    fn retention_watermark_and_atomic_replacement_refuse_symlink_targets() {
        let state = tempfile::tempdir().unwrap();
        let target = state.path().join("unrelated");
        fs::write(&target, "Preserve unrelated contents").unwrap();
        let directory = state.path().join("diagnostics");
        fs::create_dir(&directory).unwrap();
        symlink(&target, directory.join("retention.json")).unwrap();
        assert!(Writer::open_at(directory.clone(), policy(1800), 1234).is_err());
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "Preserve unrelated contents"
        );
        fs::remove_file(directory.join("retention.json")).unwrap();
        let mut writer = Writer::open_at(directory.clone(), policy(1800), 1234).unwrap();
        for sequence in 0..3 {
            writer.append(&record(sequence)).unwrap();
        }
        symlink(&target, directory.join("retention.json.tmp")).unwrap();
        let mut recent = record(3);
        recent.timestamp_ms += 49 * 60 * 60 * 1000;
        assert!(writer.append(&recent).is_err());
        assert_eq!(
            receipts(&directory).len(),
            3,
            "A failed coverage receipt must not delete the protected log segments"
        );
        assert_eq!(
            fs::read_to_string(&target).unwrap(),
            "Preserve unrelated contents"
        );
    }

    #[test]
    fn uncertain_timestamp_coverage_survives_expiry_and_is_reported_if_capacity_evicts_it() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        fs::create_dir(&directory).unwrap();
        let path = directory.join("runtime.jsonl.1");
        fs::write(&path, "fixture_private_truncated_record\n").unwrap();
        let mut writer =
            Writer::open_at(directory.clone(), policy(600), 72 * 60 * 60 * 1000).unwrap();
        assert!(
            path.exists(),
            "Unknown timestamps cannot establish that a segment expired"
        );
        assert!(watermark(&directory).prior_history_unknown);
        for sequence in 0..12 {
            let mut recent = record(sequence);
            recent.timestamp_ms = 72 * 60 * 60 * 1000 + u64::from(sequence);
            writer.append(&recent).unwrap();
        }
        let retained = watermark(&directory);
        assert!(retained.capacity_loss.unwrap().unknown_timestamps);
        assert!(
            !fs::read_to_string(directory.join("retention.json"))
                .unwrap()
                .contains("fixture_private_truncated_record")
        );
    }

    #[tokio::test]
    async fn a_full_nonblocking_channel_reports_its_dropped_count_after_recovery() {
        let (sender, mut records) = mpsc::channel(1);
        let mut log = Diagnostics {
            sender,
            drops: Default::default(),
        };
        let trace = Trace::new(&RuntimeCommand::Status);
        log.record(1, &trace, Event::RequestReceived);
        log.record(2, &trace, Event::RequestReceived);
        log.record(3, &trace, Event::RequestReceived);
        assert_eq!(records.recv().await.unwrap().dropped_before, 0);
        log.record(4, &trace, Event::Done);
        let recovered = records.recv().await.unwrap();
        assert_eq!(recovered.request_id, 4);
        assert_eq!(recovered.dropped_before, 2);
        log.record(5, &trace, Event::Done);
        assert_eq!(records.recv().await.unwrap().dropped_before, 0);
        drop(records);
        log.record(6, &trace, Event::Done);
    }

    #[test]
    fn writer_drop_releases_its_native_lock_even_if_a_descriptor_was_inherited() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let writer = Writer::open(directory.clone(), 600).unwrap();
        // dup and fork retain the same open-file description. A child between
        // fork and exec can outlive the writer's own final File handle.
        let inherited = writer.lock.try_clone().unwrap();
        drop(writer);
        let replacement = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.join("writer.lock"))
            .unwrap();
        assert!(
            fs2::FileExt::try_lock_exclusive(&replacement).is_ok(),
            "Writer ownership must end even while an inherited descriptor remains open"
        );
        drop(inherited);
    }

    #[test]
    fn retired_and_replacement_writers_serialize_native_rotation() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut retired = Writer::open(directory.clone(), 600).unwrap();
        let other = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.join("writer.lock"))
            .unwrap();
        assert_eq!(
            fs2::FileExt::try_lock_exclusive(&other).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        let (begun, started) = std::sync::mpsc::channel();
        let replacement_directory = directory.clone();
        let replacement = std::thread::spawn(move || {
            begun.send(()).unwrap();
            let mut writer = Writer::open(replacement_directory, 600).unwrap();
            for sequence in 50..100 {
                writer.append(&record(sequence)).unwrap();
            }
        });
        started.recv().unwrap();
        for sequence in 0..50 {
            retired.append(&record(sequence)).unwrap();
        }
        drop(retired);
        replacement.join().unwrap();
        fs2::FileExt::try_lock_exclusive(&other).unwrap();
        let retained = receipts(&directory)
            .iter()
            .map(|record| record.request_id)
            .collect::<Vec<_>>();
        assert_eq!(retained.last(), Some(&99));
        assert!(retained.windows(2).all(|pair| pair[1] == pair[0] + 1));
    }

    #[test]
    fn native_input_and_interrupt_diagnostics_retain_identity_mode_and_operation_only() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open(directory.clone(), 8192).unwrap();
        let (sender, mut received) = mpsc::channel(16);
        let mut diagnostics = Diagnostics {
            sender,
            drops: Default::default(),
        };
        let commands = [
            RuntimeCommand::MainInput {
                origin: None,
                attachments: None,
                input_id: "main-input".into(),
                input: "A private input body".into(),
                mode: InputMode::Steer,
                context: Some(MainInputContext {
                    instructions: "Private instructions".into(),
                    origin_host_id: Some("private-origin".into()),
                    cwd: "/private/workspace".into(),
                    hosts: Vec::new(),
                }),
            },
            RuntimeCommand::ConversationInput {
                origin: None,
                attachments: None,
                conversation_id: "saved-conversation".into(),
                input_id: "saved-input".into(),
                input: "Another private input body".into(),
                mode: InputMode::FollowUp,
                context: None,
            },
            RuntimeCommand::MainInterrupt,
            RuntimeCommand::ConversationInterrupt {
                conversation_id: "saved-conversation".into(),
            },
        ];
        for (index, command) in commands.into_iter().enumerate() {
            let id = u32::try_from(index + 1).unwrap();
            let trace = Trace::new(&command);
            diagnostics.record(
                id,
                &trace,
                trace
                    .input(&command)
                    .expect("Typed admission and stop commands need lifecycle receipts"),
            );
            let bytes = serde_json::to_vec(&RuntimeRequest {
                version: 1,
                id,
                command,
            })
            .unwrap();
            diagnostics.record(
                id,
                &trace,
                Event::CommandSent {
                    command: command_kind(&bytes).unwrap(),
                },
            );
        }
        while let Ok(record) = received.try_recv() {
            writer.append(&record).unwrap();
        }
        drop(writer);
        let records = fs::read_to_string(directory.join("runtime.jsonl"))
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str::<Record>(line).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(records.len(), 8);
        let expected = [
            (
                None,
                Event::InputReceived {
                    input_id: Some("main-input".into()),
                    mode: Some(InputMode::Steer),
                },
            ),
            (
                None,
                Event::CommandSent {
                    command: "main_input".into(),
                },
            ),
            (
                Some("saved-conversation"),
                Event::InputReceived {
                    input_id: Some("saved-input".into()),
                    mode: Some(InputMode::FollowUp),
                },
            ),
            (
                Some("saved-conversation"),
                Event::CommandSent {
                    command: "conversation_input".into(),
                },
            ),
            (None, Event::InterruptReceived),
            (
                None,
                Event::CommandSent {
                    command: "main_interrupt".into(),
                },
            ),
            (Some("saved-conversation"), Event::InterruptReceived),
            (
                Some("saved-conversation"),
                Event::CommandSent {
                    command: "conversation_interrupt".into(),
                },
            ),
        ];
        for (record, (conversation, event)) in records.iter().zip(expected) {
            let expected = Record {
                timestamp_ms: record.timestamp_ms,
                request_id: record.request_id,
                elapsed_ms: record.elapsed_ms,
                conversation_id: conversation.map(str::to_owned),
                task_id: None,
                agent_id: None,
                dropped_before: 0,
                event,
            };
            assert_eq!(
                serde_json::to_string(record).unwrap(),
                serde_json::to_string(&expected).unwrap()
            );
        }
    }

    fn at(timestamp_ms: u64, event: Event) -> Record {
        Record {
            timestamp_ms,
            event,
            ..record(0)
        }
    }

    #[tokio::test]
    async fn heartbeats_witness_an_idle_writer_without_keeping_it_alive() {
        let state = tempfile::tempdir().unwrap();
        let (diagnostics, _) =
            Diagnostics::start_with_heartbeat(state.path(), std::time::Duration::from_millis(20));
        let directory = state.path().join("diagnostics");
        let heartbeats = || {
            receipts(&directory)
                .iter()
                .filter(|record| matches!(record.event, Event::Heartbeat))
                .count()
        };
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while !directory.join("runtime.jsonl").exists() || heartbeats() < 2 {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("An idle writer must still record heartbeats");
        drop(diagnostics);
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(directory.join("writer.lock"))
            .unwrap();
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while fs2::FileExt::try_lock_exclusive(&lock).is_err() {
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("The heartbeat must not keep the writer alive after its last producer");
    }

    fn overflowed(
        state: &std::path::Path,
        heartbeat: std::time::Duration,
        records: u32,
    ) -> Diagnostics {
        let directory = state.join("diagnostics");
        fs::create_dir(&directory).unwrap();
        let lock = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(directory.join("writer.lock"))
            .unwrap();
        fs2::FileExt::lock_exclusive(&lock).unwrap();
        let (mut log, _) = Diagnostics::start_with_heartbeat(state, heartbeat);
        let trace = Trace::new(&RuntimeCommand::Status);
        for id in 1..=records {
            log.record(id, &trace, Event::RequestReceived);
        }
        fs2::FileExt::unlock(&lock).unwrap();
        log
    }

    async fn reported_drops(directory: &std::path::Path) -> u64 {
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
                let reported: u64 = receipts(directory)
                    .iter()
                    .map(|record| record.dropped_before)
                    .sum();
                if reported > 0 {
                    return reported;
                }
            }
        })
        .await
        .expect("Dropped receipts must be reported without another record() call")
    }

    #[tokio::test]
    async fn a_dropped_receipt_stays_visible_to_a_reader_until_its_report_is_on_disk() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open(directory.clone(), super::MAX_BYTES).unwrap();
        let (mut log, mut records) = Diagnostics::open_channel(&directory, 1);
        let trace = Trace::new(&RuntimeCommand::Status);
        let seen = || {
            let read = read_window(state.path(), (0, u64::MAX), 100, u64::MAX).unwrap();
            let written: u64 = read
                .records
                .iter()
                .map(|record| record.dropped_before)
                .sum();
            (read.undelivered_drops, written)
        };
        for id in 1..=3 {
            log.record(id, &trace, Event::RequestReceived);
        }
        assert_eq!(seen(), (2, 0), "Dropped and not yet carried by a receipt");
        super::append_reported(&mut writer, &log.drops, &records.recv().await.unwrap()).unwrap();
        log.record(4, &trace, Event::Done);
        assert_eq!(
            seen(),
            (2, 0),
            "Carried by a receipt that waits in the channel"
        );
        let report = records.recv().await.unwrap();
        assert_eq!(report.dropped_before, 2);
        assert_eq!(
            seen(),
            (2, 0),
            "Received by the writer and not yet appended"
        );
        super::append_reported(&mut writer, &log.drops, &report).unwrap();
        assert_eq!(seen(), (0, 2), "On disk, and no longer counted as pending");
    }

    #[tokio::test]
    async fn a_heartbeat_reports_receipts_that_a_silent_sender_dropped() {
        let state = tempfile::tempdir().unwrap();
        let log = overflowed(state.path(), std::time::Duration::from_millis(50), 300);
        let directory = state.path().join("diagnostics");
        let reported = reported_drops(&directory).await;
        let written = receipts(&directory)
            .iter()
            .filter(|record| matches!(record.event, Event::RequestReceived))
            .count() as u64;
        assert_eq!(
            reported + written,
            300,
            "Every receipt is written or counted"
        );
        assert_eq!(
            read_window(state.path(), (0, u64::MAX), 1_000, u64::MAX)
                .unwrap()
                .undelivered_drops,
            0,
            "A reported drop is no longer pending"
        );
        drop(log);
    }

    #[tokio::test]
    async fn a_reader_sees_drops_that_no_record_has_reported_yet_and_the_last_sender_leaves_them_on_disk()
     {
        let state = tempfile::tempdir().unwrap();
        let log = overflowed(state.path(), std::time::Duration::from_secs(3_600), 300);
        let directory = state.path().join("diagnostics");
        tokio::time::timeout(std::time::Duration::from_secs(10), async {
            while receipts(&directory).len() < 256 {
                tokio::time::sleep(std::time::Duration::from_millis(20)).await;
            }
        })
        .await
        .unwrap();
        assert_eq!(
            read_window(state.path(), (0, u64::MAX), 1_000, u64::MAX)
                .unwrap()
                .undelivered_drops,
            44
        );
        drop(log);
        assert_eq!(reported_drops(&directory).await, 44);
    }

    #[test]
    fn a_window_read_spans_segments_and_reports_loss_without_the_writer_lock() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        let mut writer = Writer::open_at(directory.clone(), policy(1_000_000), 10_000).unwrap();
        for timestamp in (1_000..=9_000).step_by(100) {
            writer.append(&at(timestamp, Event::Heartbeat)).unwrap();
        }
        assert!(writer.archives.len() > 3, "The fixture must span segments");
        let all = read_window(state.path(), (0, 20_000), 1_000, u64::MAX).unwrap();
        assert_eq!(all.records.len(), 81);
        assert_eq!(all.oldest_retained_ms, Some(1_000));
        assert_eq!(all.unplaced_lines, 0);
        assert!(!all.rotated_during_read);
        assert_eq!(all.truncated_at_ms, None);
        let facts = all.retention.unwrap();
        assert!(!facts.prior_history_unknown);
        assert_eq!(facts.expired_through_ms, None);
        assert_eq!(facts.capacity_loss, None);

        let middle = read_window(state.path(), (3_000, 5_000), 1_000, u64::MAX).unwrap();
        let timestamps: Vec<u64> = middle
            .records
            .iter()
            .map(|record| record.timestamp_ms)
            .collect();
        assert_eq!(timestamps, (3_000..5_000).step_by(100).collect::<Vec<_>>());
        assert_eq!(middle.oldest_retained_ms, Some(1_000));

        let cut = read_window(state.path(), (3_000, 5_000), 5, u64::MAX).unwrap();
        assert_eq!(cut.records.len(), 5);
        assert_eq!(cut.truncated_at_ms, Some(3_500));
    }

    #[test]
    fn a_bad_line_is_placed_before_the_window_only_while_receipt_timestamps_never_go_back() {
        let line = |timestamp| serde_json::to_string(&at(timestamp, Event::Heartbeat)).unwrap();
        let unplaced = |segments: &[(&str, String)]| {
            let state = tempfile::tempdir().unwrap();
            let directory = state.path().join("diagnostics");
            fs::create_dir(&directory).unwrap();
            for (name, content) in segments {
                fs::write(directory.join(name), content).unwrap();
            }
            read_window(state.path(), (500, 2_000), 100, u64::MAX)
                .unwrap()
                .unplaced_lines
        };
        let ordered = format!("{}\nbad\n{}\n{}\n", line(100), line(200), line(1_000));
        assert_eq!(unplaced(&[("runtime.jsonl", ordered)]), 0);

        let rolled_back = format!("{}\nbad\n{}\n{}\n", line(1_000), line(100), line(1_100));
        assert_eq!(
            unplaced(&[("runtime.jsonl", rolled_back)]),
            1,
            "A receipt whose clock went back proves nothing about the line before it"
        );
        let rolled_back_elsewhere = format!(
            "{}\n{}\n{}\nbad\n{}\n{}\n",
            line(400),
            line(100),
            line(150),
            line(200),
            line(1_000)
        );
        assert_eq!(
            unplaced(&[("runtime.jsonl", rolled_back_elsewhere)]),
            1,
            "Any timestamp that goes back in a segment removes the proof for that segment"
        );
        assert_eq!(
            unplaced(&[
                ("runtime.jsonl.1", format!("{}\nbad\n", line(100))),
                ("runtime.jsonl", format!("{}\n{}\n", line(200), line(1_000))),
            ]),
            0,
            "The next segment's older receipt places a segment's last line"
        );
        assert_eq!(
            unplaced(&[
                ("runtime.jsonl.1", format!("{}\nbad\n", line(300))),
                ("runtime.jsonl", format!("{}\n{}\n", line(200), line(1_000))),
            ]),
            1,
            "A timestamp that goes back across segments removes the proof too"
        );
        let unfinished = format!(
            "{}\n{}\n{{\"timestamp_ms\":1200,\"event\":",
            line(100),
            line(1_000)
        );
        assert_eq!(
            unplaced(&[("runtime.jsonl", unfinished)]),
            1,
            "An unfinished last line may be a receipt that a crashed writer lost"
        );
    }

    #[test]
    fn a_rollback_stays_with_a_segments_last_bad_line_until_a_later_segment_places_it() {
        let line = |timestamp| serde_json::to_string(&at(timestamp, Event::Heartbeat)).unwrap();
        let unplaced = |segments: &[(&str, String)]| {
            let state = tempfile::tempdir().unwrap();
            let directory = state.path().join("diagnostics");
            fs::create_dir(&directory).unwrap();
            for (name, content) in segments {
                fs::write(directory.join(name), content).unwrap();
            }
            read_window(state.path(), (500, 2_000), 100, u64::MAX)
                .unwrap()
                .unplaced_lines
        };
        assert_eq!(
            unplaced(&[
                (
                    "runtime.jsonl.1",
                    format!("{}\n{}\nbad\n", line(200), line(100))
                ),
                ("runtime.jsonl", format!("{}\n{}\n", line(150), line(1_000))),
            ]),
            1,
            "The clock went back in the segment that holds the bad line"
        );
        assert_eq!(
            unplaced(&[
                (
                    "runtime.jsonl.2",
                    format!("{}\n{}\nbad\n", line(200), line(100))
                ),
                ("runtime.jsonl.1", "also bad\n".to_owned()),
                ("runtime.jsonl", format!("{}\n{}\n", line(150), line(1_000))),
            ]),
            1,
            "Only the line from the segment whose clock went back loses its proof"
        );
        assert_eq!(
            unplaced(&[
                ("runtime.jsonl.1", format!("{}\nbad\n", line(100))),
                (
                    "runtime.jsonl",
                    format!("{}\n{}\n{}\n", line(150), line(120), line(1_000))
                ),
            ]),
            1,
            "The clock went back in the segment whose receipt would place the line"
        );
    }

    #[test]
    fn a_timestamp_that_goes_back_past_the_reorder_tolerance_around_the_window_is_a_clock_move() {
        const HOUR: u64 = 3_600_000;
        let line = |timestamp| serde_json::to_string(&at(timestamp, Event::Heartbeat)).unwrap();
        let now = super::now_ms();
        let window = (now - 2 * HOUR, now);
        let moves = |stamps: &[u64]| {
            let state = tempfile::tempdir().unwrap();
            let directory = state.path().join("diagnostics");
            fs::create_dir(&directory).unwrap();
            let log: String = stamps.iter().map(|stamp| line(*stamp) + "\n").collect();
            fs::write(directory.join("runtime.jsonl"), log).unwrap();
            read_window(state.path(), window, 100, u64::MAX)
                .unwrap()
                .clock_moves
        };
        assert_eq!(moves(&[now - HOUR, now - HOUR + 5, now - HOUR + 1]), None);
        assert_eq!(
            moves(&[now - HOUR, now - HOUR - 59_000, now - 1_000]),
            None,
            "Senders and a replacement writer reorder stamps by less than a minute"
        );
        assert_eq!(
            moves(&[now - 5 * HOUR, now - 6 * HOUR, now - HOUR]),
            None,
            "A move wholly before the window hides nothing in it"
        );
        let back = moves(&[now - HOUR, now - 4 * HOUR, now - 1_000]).unwrap();
        assert_eq!((back.times, back.largest_back_ms), (1, 3 * HOUR));
        assert_eq!(back.span_ms, (now - 4 * HOUR, now - HOUR));
        let ahead = moves(&[now - HOUR, now + 2 * HOUR, now - 1_000]).unwrap();
        assert_eq!(ahead.times, 1);
        assert_eq!(ahead.span_ms, (now - 1_000, now + 2 * HOUR));
        let trailing = moves(&[now - HOUR, now + 2 * HOUR]).unwrap();
        assert_eq!(
            trailing.times, 1,
            "A last receipt stamped ahead of the present"
        );
        let twice = moves(&[now - HOUR, now - 3 * HOUR, now - HOUR, now - 2 * HOUR - 1]).unwrap();
        assert_eq!((twice.times, twice.largest_back_ms), (2, 2 * HOUR));
    }

    #[test]
    fn a_window_read_counts_only_bad_lines_that_may_hide_a_receipt_in_the_window() {
        let state = tempfile::tempdir().unwrap();
        let directory = state.path().join("diagnostics");
        fs::create_dir(&directory).unwrap();
        let line = |timestamp| serde_json::to_string(&at(timestamp, Event::Heartbeat)).unwrap();
        fs::write(
            directory.join("runtime.jsonl.1"),
            format!(
                "{}\nnot a receipt, provably old\n{}\nmaybe in the window\n{}\n",
                line(100),
                line(200),
                line(1_000)
            ),
        )
        .unwrap();
        fs::write(
            directory.join("runtime.jsonl"),
            format!(
                "{}\n{{\"timestamp_ms\":1200,\"event\":\"from_a_newer_writer\"}}\n{}\n{{\"timestamp_ms\":",
                line(1_100),
                line(1_300)
            ),
        )
        .unwrap();
        let read = read_window(state.path(), (500, 2_000), 100, u64::MAX).unwrap();
        assert_eq!(read.records.len(), 3);
        assert_eq!(
            read.unplaced_lines, 3,
            "Only the bad line that ordered receipts place before the window is no gap"
        );
        assert!(
            read.retention.is_none(),
            "A missing watermark means loss is unknown"
        );

        fs::write(
            directory.join("retention.json"),
            serde_json::to_vec(&RetentionWatermark {
                version: 1,
                policy: RetentionPolicy::default(),
                prior_history_unknown: true,
                expired_through_ms: Some(90),
                capacity_loss: Some(super::CapacityLoss {
                    first_timestamp_ms: Some(10),
                    last_timestamp_ms: Some(20),
                    unknown_timestamps: false,
                    segments: 2,
                    bytes: 1_200,
                }),
            })
            .unwrap(),
        )
        .unwrap();
        let facts = read_window(state.path(), (500, 2_000), 100, u64::MAX)
            .unwrap()
            .retention
            .unwrap();
        assert!(facts.prior_history_unknown);
        assert_eq!(facts.expired_through_ms, Some(90));
        let loss = facts.capacity_loss.unwrap();
        assert_eq!(
            (
                loss.first_timestamp_ms,
                loss.last_timestamp_ms,
                loss.segments,
                loss.bytes
            ),
            (Some(10), Some(20), 2, 1_200)
        );
        let empty = tempfile::tempdir().unwrap();
        let none = read_window(empty.path(), (0, 10), 10, u64::MAX).unwrap();
        assert!(none.records.is_empty() && none.retention.is_none());
    }
}
