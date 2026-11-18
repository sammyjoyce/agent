use crate::embeddings::{EmbeddingBatch, EmbeddingPurpose};
use crate::feedback::{FeedbackBundle, FeedbackContext, FeedbackReceipt};
use crate::history::{HistoryGap, HistoryItem, HistoryRequest, HistoryResponse, HistoryThread};
use crate::instructions::{GuidanceSnapshot, GuidanceSource};
use crate::machines::MachineSnapshot;
use crate::models::{ModelProvider, ModelSelection, Reasoning};
use crate::resources::{CleanupPlan, ResourceRecord, ResourceReport, WorktreeAllocation};
use crate::sources::{
    SourceBatch, SourceCheckpoint, SourceConfig, SourceCoverage, SourceKey, SourceScanProgress,
};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;

/// Pi's own-conversation ledger. Imported transcripts and fork ancestors are not
/// billed again; reasoning and one-hour cache writes are subsets, not extra tokens.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct UsageTokens {
    #[ts(type = "number")]
    pub input: u64,
    #[ts(type = "number")]
    pub output: u64,
    #[ts(type = "number")]
    pub cache_read: u64,
    #[ts(type = "number")]
    pub cache_write: u64,
    #[ts(type = "number | null")]
    pub cache_write_1h: Option<u64>,
    #[ts(type = "number | null")]
    pub reasoning: Option<u64>,
    #[ts(type = "number")]
    pub total: u64,
}

/// Native SDK estimates are API-equivalent USD, never a provider invoice or
/// ChatGPT subscription spend. A zero/unknown native price is unavailable.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum UsageCost {
    ApiEstimate {
        input_usd: f64,
        output_usd: f64,
        cache_read_usd: f64,
        cache_write_usd: f64,
        total_usd: f64,
    },
    Unavailable,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct UsageBucket {
    /// Pi's provider/model key, or tool name for the tool ledger.
    pub name: String,
    pub tokens: UsageTokens,
    pub cost: UsageCost,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct RequestTiming {
    pub entry_id: String,
    pub provider: String,
    pub model: String,
    pub started_at_ms: f64,
    /// Native monotonic request duration; absent in legacy/deferred entries.
    pub duration_ms: Option<f64>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TelemetryStatus {
    pub available: bool,
    #[ts(type = "number")]
    pub dropped_spans: u64,
    #[ts(type = "number")]
    pub dropped_measurements: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ConversationUsage {
    pub conversation_id: String,
    /// False means Pi has no ledger for this conversation, not measured zero.
    pub recorded: bool,
    pub models: Vec<UsageBucket>,
    pub tools: Vec<UsageBucket>,
    /// Samples from the last 20 native entries, not a lifetime duration total.
    pub recent_requests: Vec<RequestTiming>,
    pub recent_entry_limit: u32,
    pub telemetry: TelemetryStatus,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ContextRepository {
    pub id: String,
    pub root: String,
    pub instructions: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct CoordinatorSettings {
    pub model: ModelSelection,
    pub instructions: String,
    pub context_repositories: Vec<ContextRepository>,
    pub sources: Vec<SourceConfig>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, Default)]
pub struct WorkerCapabilities {
    #[serde(default)]
    pub resume_agent: bool,
    #[serde(default)]
    pub browser: bool,
    #[serde(default)]
    pub browser_user_tabs: bool,
    #[serde(default)]
    pub browser_screenshots: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct AgentNode {
    pub host_id: String,
    pub name: String,
    pub rex_server: Option<String>,
    pub agent_program: String,
    pub home_directory: String,
    pub coordinator: Option<String>,
    pub launch: WorkerLaunch,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub capabilities: Option<WorkerCapabilities>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine: Option<MachineSnapshot>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct CoordinatorBootstrap {
    pub settings: CoordinatorSettings,
    pub node: Option<AgentNode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub background: Option<crate::background::BackgroundSettings>,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, JsonSchema, TS)]
pub struct TaskId(#[ts(type = "string")] Uuid);

impl Serialize for TaskId {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for TaskId {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Self::try_from(Uuid::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

impl TaskId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }
}

impl Default for TaskId {
    fn default() -> Self {
        Self::new()
    }
}

impl TryFrom<Uuid> for TaskId {
    type Error = &'static str;
    fn try_from(value: Uuid) -> Result<Self, Self::Error> {
        if value.is_nil() {
            Err("Task ID cannot be nil")
        } else {
            Ok(Self(value))
        }
    }
}

impl From<TaskId> for Uuid {
    fn from(value: TaskId) -> Self {
        value.0
    }
}

impl std::fmt::Display for TaskId {
    fn fmt(&self, output: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        self.0.fmt(output)
    }
}

impl std::str::FromStr for TaskId {
    type Err = anyhow::Error;
    fn from_str(value: &str) -> Result<Self, Self::Err> {
        Self::try_from(Uuid::parse_str(value)?).map_err(anyhow::Error::msg)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct AccountIdentity {
    pub issuer: String,
    pub subject: String,
    pub email: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum AuthStatus {
    SignedOut,
    Connected {
        account: AccountIdentity,
        #[ts(type = "number")]
        expires_at: u64,
    },
    NeedsSignIn {
        account: Option<AccountIdentity>,
    },
}

#[derive(
    Clone,
    Copy,
    Debug,
    Default,
    Deserialize,
    Serialize,
    JsonSchema,
    TS,
    clap::ValueEnum,
    PartialEq,
    Eq,
)]
#[serde(rename_all = "snake_case")]
pub enum FastMode {
    #[default]
    Toggle,
    On,
    Off,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ConversationChange {
    SetSelection {
        model: ModelSelection,
    },
    SetModel {
        provider: Option<ModelProvider>,
        model_id: String,
    },
    SetReasoning {
        reasoning: Option<Reasoning>,
    },
    SetFast {
        mode: FastMode,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ModelOption {
    pub provider: ModelProvider,
    pub model_id: String,
    pub name: String,
    pub reasoning: Vec<Reasoning>,
    pub fast: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ConversationSettings {
    pub conversation_id: String,
    pub task_id: Option<TaskId>,
    pub agent_id: Option<String>,
    pub model: ModelSelection,
    pub catalog: Vec<ModelOption>,
}

/// Saved conversation identity and metadata; listing never starts execution.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct SavedConversation {
    pub conversation_id: String,
    pub title: String,
    #[ts(type = "number | null")]
    pub updated_at: Option<i64>,
    pub task_id: Option<TaskId>,
    pub agent_id: Option<String>,
    pub host: Option<String>,
    pub source_thread_id: Option<String>,
}

/// Trusted direct-input transport metadata, never inferred from text or host.
/// Omission is unknown, including legacy clients and non-human work.
/// `siri` is Siri or a Shortcuts action relayed by the iPhone app. A client sends a value
/// only when the coordinator lists it in `AcceptedInputOrigins`.
#[derive(
    Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, JsonSchema, TS,
)]
#[serde(rename_all = "snake_case")]
pub enum InputOrigin {
    Cli,
    Ios,
    Siri,
}

/// The origins a coordinator accepts in a submit's `origin`. Decoding drops names this build
/// cannot decode instead of failing.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, JsonSchema, TS)]
#[serde(transparent)]
pub struct AcceptedInputOrigins(
    #[schemars(with = "Vec<String>")]
    #[ts(as = "Vec<String>")]
    std::collections::BTreeSet<InputOrigin>,
);

impl<'de> Deserialize<'de> for AcceptedInputOrigins {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        use serde::de::IntoDeserializer;
        let names = Vec::<String>::deserialize(deserializer)?;
        Ok(Self(
            names
                .iter()
                .filter_map(|name| {
                    let name: serde::de::value::StrDeserializer<'_, serde::de::value::Error> =
                        name.as_str().into_deserializer();
                    InputOrigin::deserialize(name).ok()
                })
                .collect(),
        ))
    }
}

impl AcceptedInputOrigins {
    const ORIGINS_BEFORE_THE_LIST: [InputOrigin; 2] = [InputOrigin::Cli, InputOrigin::Ios];

    pub(crate) fn from_main_ready(list: Option<&Self>, input_origins: Option<bool>) -> Self {
        match (list, input_origins) {
            (Some(list), _) => list.clone(),
            (None, Some(true)) => Self(Self::ORIGINS_BEFORE_THE_LIST.into()),
            (None, _) => Self::default(),
        }
    }
    pub(crate) fn contains(&self, origin: InputOrigin) -> bool {
        self.0.contains(&origin)
    }
    pub(crate) fn flag_for_phones_before_the_list(&self) -> Option<bool> {
        self.contains(InputOrigin::Ios).then_some(true)
    }
    pub(crate) fn non_empty(self) -> Option<Self> {
        (!self.0.is_empty()).then_some(self)
    }
}

/// The native conversation that supplied cross-task coordination context.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TaskMessageSender {
    Coordinator {
        conversation_id: String,
    },
    Task {
        task_id: TaskId,
        conversation_id: String,
        title: String,
    },
}

/// Used only when an idle chief starts a new turn; active work keeps its context.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct MainInputContext {
    pub instructions: String,
    pub origin_host_id: Option<String>,
    pub cwd: String,
    pub hosts: Vec<WorkerHost>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct RuntimeRequest {
    pub version: u32,
    pub id: u32,
    pub command: RuntimeCommand,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuntimeCommand {
    ConversationUsage {
        conversation_id: String,
    },
    Attachment {
        request: crate::attachments::AttachmentRequest,
    },
    RunBackground {
        settings: crate::background::BackgroundSettings,
    },
    SyncJobs {
        jobs: Vec<crate::jobs::ScheduledJob>,
    },
    JobStatus,
    ListJobs,
    ReadJob {
        job_id: crate::jobs::JobId,
    },
    RetryJob {
        job_id: crate::jobs::JobId,
    },
    RunJob {
        job_id: crate::jobs::JobId,
        schedule_id: Option<crate::jobs::ScheduleId>,
        request_id: String,
    },
    ConfigureCoordinator {
        bootstrap: CoordinatorBootstrap,
    },
    RegisterNode {
        node: AgentNode,
    },
    SetConnectedNodes {
        host_ids: Vec<String>,
    },
    Environment {
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        telemetry: bool,
    },
    ConnectWorker {
        node: AgentNode,
    },
    Watch,
    SourceStates,
    IngestSource {
        batch: SourceBatch,
        expected_checkpoint: Option<SourceCheckpoint>,
    },
    #[serde(rename = "oauth_callback")]
    OAuthCallback {
        target: String,
    },
    TriageSources {
        instructions: String,
        model: ModelSelection,
        cwd: String,
        hosts: Vec<WorkerHost>,
    },
    Login,
    Status,
    Usage {
        provider: crate::models::ModelProvider,
    },
    AttachMain,
    /// Long-lived, read-only observation of the existing root conversation.
    ObserveMain {
        input_ids: Vec<String>,
    },
    /// Owner-independent admission using Pi's durable request identity.
    MainInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<InputOrigin>,
        input_id: String,
        input: String,
        mode: InputMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        context: Option<MainInputContext>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    },
    MainInterrupt,
    MainFeedback {
        description: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_id: Option<String>,
    },
    /// Native clients share the authenticated local/tailnet transport.
    Native {
        request: crate::native::NativeRequest,
    },
    DetachMain,
    ConversationSettings {
        task_id: Option<TaskId>,
        agent_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_id: Option<String>,
        change: Option<ConversationChange>,
        #[serde(default)]
        catalog: bool,
    },
    /// `/goal` for one selected conversation: show, set, pause or resume its objective.
    Goal {
        target: GoalTarget,
        action: GoalAction,
    },
    Logout,
    Chat {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<InputOrigin>,
        input: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_id: Option<String>,
        instructions: String,
        model: Option<ModelSelection>,
        origin_host_id: Option<String>,
        cwd: String,
        hosts: Vec<WorkerHost>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    },
    SearchTasks {
        query: String,
    },
    ListTasks,
    /// One snapshot of the coordinator's live native work, joined with task and agent identity.
    ReadTaskGraph,
    ListConversations {
        query: String,
        cursor: Option<String>,
        limit: u32,
    },
    /// Observe a saved conversation without claiming its execution.
    AttachConversation {
        conversation_id: String,
        #[serde(default)]
        input_ids: Vec<String>,
    },
    DetachConversation,
    /// Admit input independently of any observing terminal's lifetime.
    ConversationInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<InputOrigin>,
        conversation_id: String,
        input_id: String,
        input: String,
        mode: InputMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        context: Option<MainInputContext>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    },
    ConversationInterrupt {
        conversation_id: String,
    },
    ListResources,
    CollectResources {
        host_id: String,
    },
    ReadTask {
        task_id: TaskId,
    },
    ReadHistory {
        task_id: Option<TaskId>,
        agent_id: Option<String>,
        cursor: Option<String>,
    },
    ReadToolDetails {
        entry_id: String,
        call_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        task_id: Option<TaskId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        agent_id: Option<String>,
    },
    Feedback {
        description: String,
        context: FeedbackContext,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_id: Option<String>,
    },
    ReadFeedback {
        id: Option<String>,
    },
    ImportCodex {
        hosts: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        embedding_host: Option<String>,
    },
    /// Import one checked ChatGPT export. The requesting client serves every history read
    /// for this request from the package it checked; the coordinator never sees a path.
    #[serde(rename = "import_chatgpt")]
    ImportChatGpt {
        package: crate::history::chatgpt::ChatGptPackageSummary,
    },
    ImportStatus,
    RetryHistoryIndex,
    TaskInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<InputOrigin>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        sender_conversation_id: Option<String>,
        task_id: TaskId,
        input_id: String,
        input: String,
        mode: InputMode,
    },
    AnnotateTranscript {
        conversation_id: String,
        entries: Vec<TranscriptAnnotation>,
    },
    Notifications {
        request: crate::notifications::NotificationRequest,
    },
    SearchHistory {
        query: String,
        limit: u32,
        #[serde(default)]
        mode: SearchMode,
    },
    ReadConversation {
        conversation_id: String,
        cursor: Option<String>,
    },
    OpenConversation {
        conversation_id: String,
        host: Option<String>,
    },
    RevokeAllocation {
        task_id: TaskId,
        allocation_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        agent_id: Option<String>,
    },
    RunTask {
        task_id: TaskId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        agent_id: Option<String>,
        allocation_id: String,
        binding: WorkerRef,
        instructions: String,
        model: ModelSelection,
        cwd: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        interactive: Option<bool>,
    },
    WorkerInput {
        input_id: String,
        input: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    },
    SubmitInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<InputOrigin>,
        input_id: String,
        input: String,
        mode: InputMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    },
    DetachWorker,
    Interrupt,
    HostReply {
        call_id: String,
        result: HostResult,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct WorkerHost {
    #[serde(default)]
    pub host_id: Option<String>,
    pub name: String,
    pub rex_server: Option<String>,
    pub coordinator: Option<String>,
    pub cwd: String,
    pub agent_program: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub launch: Option<WorkerLaunch>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct WorkerLaunch {
    pub state_dir: Option<String>,
    pub runtime: Option<String>,
    pub config: Option<String>,
    pub instructions: Option<String>,
    #[serde(default)]
    pub model: Option<ModelSelection>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct SourceRef {
    pub provider: String,
    pub account: String,
    pub thread_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DelegationCandidate {
    pub conversation_id: String,
    pub task_id: Option<TaskId>,
    pub score: f64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum DelegationSelection {
    Considered,
    Reuse {
        task_id: TaskId,
        conversation_id: String,
    },
    Adopt {
        task_id: TaskId,
        conversation_id: String,
    },
    Create {
        task_id: TaskId,
        conversation_id: String,
        reason: Option<String>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DelegationDecision {
    pub actor_conversation_id: String,
    pub tool_call_id: String,
    pub query: Option<String>,
    pub candidates: Vec<DelegationCandidate>,
    pub gaps: Vec<String>,
    pub selection: DelegationSelection,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub input_mode: Option<InputMode>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct WorkerRef {
    pub host_id: String,
    pub session_id: String,
    pub window_id: String,
    pub block_id: String,
    /// `whoami.instance_id` of the Rex server that started this pane's process.
    /// Rex restores a saved pane with a fresh shell under a new instance, so a
    /// process in the pane is the worker terminal only under this instance.
    /// Absent on a binding saved before this field, or made by an older host.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub rex_instance_id: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum WorkerState {
    Unassigned,
    Allocating {
        allocation_id: String,
        host: WorkerHost,
    },
    Bound {
        allocation_id: String,
        host: WorkerHost,
        binding: WorkerRef,
    },
    Resuming {
        allocation_id: String,
        host: WorkerHost,
        binding: WorkerRef,
    },
    ResumeUncertain {
        allocation_id: String,
        host: WorkerHost,
        binding: WorkerRef,
    },
    Uncertain {
        allocation_id: String,
        host: WorkerHost,
        session_id: Option<String>,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum AllocationOperation {
    Create,
    Resume,
    Reconcile,
    Revoke,
    Reopen,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AllocationResult {
    Pending,
    Written,
    Spawned { binding: WorkerRef },
    Presence { presence: WorkerPresence },
    CreationUncertain { session_id: Option<String> },
    NotStarted { message: String },
    Failed { message: String },
    Rejected,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct AllocationDecision {
    pub task_id: TaskId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub agent_id: Option<String>,
    pub operation: AllocationOperation,
    pub previous: WorkerState,
    pub current: WorkerState,
    pub result: AllocationResult,
    pub reason: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TaskState {
    Open,
    Waiting {
        actor: String,
        next_check: Option<String>,
    },
    Resolved {
        evidence: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskRecord {
    pub id: TaskId,
    pub conversation_id: String,
    pub title: String,
    pub outcome: String,
    pub summary: String,
    #[serde(default)]
    pub model: Option<ModelSelection>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub scheduled_run: Option<crate::background::JobRunReceipt>,
    pub state: TaskState,
    pub worker: WorkerState,
    pub sources: Vec<SourceRef>,
    pub pending: Vec<TaskInput>,
    pub agents: Vec<TaskAgentRecord>,
    #[ts(type = "number")]
    pub updated_at: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskAgentRecord {
    pub id: String,
    pub conversation_id: String,
    pub title: String,
    pub outcome: String,
    pub summary: String,
    #[serde(default)]
    pub model: Option<ModelSelection>,
    pub state: TaskAgentState,
    pub worker: WorkerState,
    pub pending: Vec<TaskInput>,
    #[ts(type = "number")]
    pub updated_at: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TaskAgentState {
    Open,
    Done,
    Failed { reason: String },
}

/// The coordinator's live Pi tasks at one moment, with the Beep Boop actor of each conversation.
///
/// Only live work appears. An idle delegate or agent has no node; `tasks list` and `tasks read`
/// answer what exists. Identity is read after the native frame, so a title can be newer than the
/// work beside it.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskGraphSnapshot {
    /// Live native tasks, an owner always before the tasks it owns.
    pub nodes: Vec<TaskGraphNode>,
    /// One row for each conversation a node runs in or owns, and for the task of each listed agent.
    pub conversations: Vec<TaskGraphConversation>,
    /// Live native tasks left out because the snapshot is bounded.
    pub omitted: u32,
}

/// One live Pi task. `id` and `owner` are Pi task IDs, never a Beep Boop `TaskId`.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskGraphNode {
    #[ts(type = "number")]
    pub id: u64,
    pub kind: TaskGraphKind,
    pub conversation_id: String,
    /// The Pi task that owns this one. None for a task its conversation owns.
    #[ts(type = "number | null")]
    pub owner: Option<u64>,
    /// Pi's lifecycle boundary: an abort of the owning conversation stops here.
    pub background: bool,
    pub abort_requested: bool,
    pub state: TaskGraphState,
    /// Why this coordinator cannot run the task, when it cannot.
    pub blocked: Option<TaskGraphBlocked>,
    /// Conversations this task owns in Pi. Delegate and agent conversations are not owned by a
    /// Pi task; their parent is `TaskGraphActor::Agent::parent_conversation_id`.
    pub conversations: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TaskGraphKind {
    /// One model turn of a conversation.
    Generation,
    /// A tool call. The name is absent once the call has settled.
    Tool { name: Option<String> },
    /// Any other Pi task kind, verbatim, such as `agent.background`.
    Other { name: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum TaskGraphState {
    Pending {
        phase: String,
    },
    Running {
        phase: String,
    },
    /// Parked until the tasks in `on` settle. A settled task has already left the graph.
    Waiting {
        phase: String,
        #[ts(type = "number[]")]
        on: Vec<u64>,
        policy: TaskGraphJoinPolicy,
    },
    /// Parked until the coordinator's clock reaches `until`, in epoch milliseconds.
    Sleeping {
        phase: String,
        until: f64,
    },
    /// The outcome is decided and held until the work this task owns has ended.
    Completing {
        outcome: TaskGraphOutcome,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum TaskGraphJoinPolicy {
    FailFast,
    AllSettled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum TaskGraphOutcome {
    Completed,
    Failed,
    Aborted,
    Orphaned,
    Faulted,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum TaskGraphBlocked {
    /// No installed definition has this task's kind.
    MissingTask,
    TaskTooOld,
    MigrationFailed,
    /// Parked after repeated restarts cut it off.
    RestartLimit,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskGraphConversation {
    pub conversation_id: String,
    pub actor: TaskGraphActor,
}

/// Who a conversation belongs to in Beep Boop.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TaskGraphActor {
    Main,
    Task {
        task_id: TaskId,
        title: String,
    },
    Agent {
        task_id: TaskId,
        agent_id: String,
        title: String,
        /// The conversation of the task this agent works for. Its row is always present.
        parent_conversation_id: String,
    },
    /// No task or agent owns it, as with source triage.
    Other,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskInput {
    /// Direct transport metadata retained in the durable task outbox.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub origin: Option<InputOrigin>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub sender: Option<TaskMessageSender>,
    pub id: String,
    pub content: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub mode: Option<InputMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub attachments: Option<Vec<crate::attachments::AttachmentRef>>,
    // The admitted file snapshot belongs to this turn, even in a reused chat.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub scheduled: Option<crate::background::ScheduledOccurrence>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskOutcome {
    pub task_id: TaskId,
    pub conversation_id: String,
    pub entry_id: Option<String>,
    pub tool_call_id: Option<String>,
    pub summary: String,
    pub sources: Vec<SourceRef>,
    pub state: TaskOutcomeState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub reconciliation: Option<TaskInputReconciliation>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskInputReceipt {
    pub request_id: String,
    pub submission_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TaskInputReconciliation {
    pub original: TaskInputReceipt,
    pub recovery_inputs: Vec<TaskInputReceipt>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum TaskOutcomeState {
    Progress,
    Waiting {
        actor: String,
        next_check: Option<String>,
    },
    Resolved {
        evidence: String,
    },
    Failed {
        reason: String,
    },
}

/// The conversation a `/goal` control addresses. The runtime resolves every form
/// to main or to exactly one existing task, and refuses an agent conversation.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalTarget {
    /// The root conversation.
    Main,
    Task {
        task_id: TaskId,
        agent_id: Option<String>,
    },
    Conversation {
        conversation_id: String,
    },
}

impl From<Option<(TaskId, Option<String>)>> for GoalTarget {
    fn from(target: Option<(TaskId, Option<String>)>) -> Self {
        match target {
            Some((task_id, agent_id)) => Self::Task { task_id, agent_id },
            None => Self::Main,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalAction {
    Show,
    /// `request_id` becomes the goal ID, and in main also the new task's ID, so a
    /// replayed set finds the goal it created instead of being refused.
    Set {
        request_id: String,
        objective: String,
    },
    /// A goal retains the request IDs it accepted, so a replayed pause or resume
    /// changes nothing even after later controls.
    Pause {
        request_id: String,
    },
    Resume {
        request_id: String,
    },
}

/// What `/goal` shows for the selected conversation.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct GoalStatus {
    /// Root for main, otherwise the task's conversation.
    pub conversation_id: String,
    pub goal: Option<Box<GoalView>>,
}

/// A goal with the task that executes it, read together so progress is current.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct GoalView {
    pub goal: Goal,
    pub task: TaskRecord,
}

/// One persistent objective, executed by exactly one existing task.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct Goal {
    pub id: String,
    pub task_id: TaskId,
    pub objective: String,
    pub activation: GoalActivation,
    pub state: GoalState,
    /// The latest attempt to finish the goal that the runtime refused.
    pub last_rejection: Option<GoalRejection>,
    #[ts(type = "number")]
    pub created_at: u64,
    #[ts(type = "number")]
    pub updated_at: u64,
}

/// A set or resume starts an activation. Its continuations, budget and pinned
/// check belong to it, and a verification counts only in the current one.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct GoalActivation {
    pub number: u32,
    pub request_id: String,
    pub continuations: u32,
    pub budget: u32,
    /// Pinned by the first verification in this activation.
    pub check: Option<GoalCheck>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum GoalState {
    Active,
    Paused {
        reason: GoalPause,
    },
    /// Written only in the commit that resolves the owning task after a passing
    /// runtime check of the current activation.
    Complete {
        evidence: GoalEvidence,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GoalPause {
    Requested,
    /// The activation used its continuation budget without a passing check.
    BudgetExhausted,
    /// The task's last turn was stopped.
    Interrupted,
}

/// A check the runtime runs itself against an artifact.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalCheck {
    /// `path` is absolute on the owning task's execution host once pinned.
    FileContains { path: String, text: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub struct ObservedFile {
    pub bytes: u32,
    /// False when the file was longer than the check's single read window.
    pub complete: bool,
    pub sha256: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct GoalEvidence {
    /// The retained `agent.goal_verification` entry in the task conversation.
    pub entry_id: String,
    pub activation: u32,
    pub check: GoalCheck,
    pub observed: ObservedFile,
    pub tool_call_id: String,
    #[ts(type = "number")]
    pub verified_at: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalCheckFailure {
    TextMissing { observed: ObservedFile },
    Unreadable { message: String },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalRejection {
    /// `complete_goal` ran its check and it failed. The entry is retained.
    FailedCheck {
        entry_id: String,
        activation: u32,
        check: GoalCheck,
        failure: GoalCheckFailure,
        tool_call_id: String,
        #[ts(type = "number")]
        at: u64,
    },
    /// Something tried to resolve the owning task without a passing check.
    PrematureResolution {
        conversation_id: String,
        entry_id: String,
        tool_call_id: String,
        #[ts(type = "number")]
        at: u64,
    },
}

/// Data of the retained Pi entry `agent.goal_verification`, appended to the
/// owning task's conversation for every check the runtime runs.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct GoalVerification {
    pub goal_id: String,
    pub task_id: TaskId,
    pub activation: u32,
    pub check: GoalCheck,
    pub result: GoalCheckResult,
    /// The assistant entry and tool call that asked for this check.
    pub origin_entry_id: String,
    pub tool_call_id: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum GoalCheckResult {
    Passed { observed: ObservedFile },
    Failed { failure: GoalCheckFailure },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct SourceState {
    pub source: SourceKey,
    pub checkpoint: Option<SourceCheckpoint>,
    pub coverage: SourceCoverage,
    #[ts(type = "number")]
    pub checked_at: u64,
    /// Last fully admitted scan, in Unix milliseconds. Older journals cannot
    /// infer this from a successful page read and leave it unknown.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional, type = "number")]
    pub last_completed_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub progress: Option<SourceScanProgress>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HostCommand {
    AttachmentWrite {
        attachment: crate::attachments::AttachmentRef,
        offset: u32,
        data_base64: String,
        complete: bool,
    },
    Browser {
        host_id: String,
        request: crate::browser::BrowserRequest,
    },
    Background {
        request: crate::background::BackgroundRequest,
    },
    /// Coordinator-local Dreams review. Its request type has no apply variant.
    Dreams {
        request: crate::dreams::DreamsRequest,
    },
    MachineSnapshot,
    ReadUsage {
        expected_email: String,
    },
    ReloadGuidance,
    ProjectGuidance {
        cwd: String,
    },
    History {
        request: HistoryRequest,
    },
    Embed {
        texts: Vec<String>,
        purpose: EmbeddingPurpose,
    },
    InspectWorker {
        binding: WorkerRef,
    },
    OnNode {
        host_id: String,
        command: Box<HostCommand>,
    },
    ReadContext {
        repository_id: String,
        path: String,
        offset: u32,
        limit: u32,
    },
    SearchContext {
        repository_id: String,
        path: Option<String>,
        query: String,
        limit: u32,
    },
    ResourceAllocate {
        request: WorktreeAllocation,
    },
    ResourceInspect {
        record: Box<ResourceRecord>,
    },
    ResourcePlanCleanup {
        record: Box<ResourceRecord>,
    },
    ResourceCollect {
        record: Box<ResourceRecord>,
        plan: CleanupPlan,
    },
    Exec {
        program: String,
        args: Vec<String>,
        cwd: String,
        timeout_seconds: u16,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        sender_conversation_id: Option<String>,
    },
    ReadFile {
        path: String,
        /// Text window in bytes. A host never applies it to an image.
        offset: u32,
        limit: u32,
        /// Older hosts skip this field and answer with text.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        image: Option<ImageRead>,
    },
    WriteFile {
        path: String,
        content: String,
    },
    EditFile {
        path: String,
        old: String,
        new: String,
    },
    SpawnWorker {
        host: WorkerHost,
        /// Where to open the root terminal if the node allows it. A node on a
        /// private Rex server checks its host and opens a new session instead.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        parent: Option<WorkerRef>,
        task_id: TaskId,
        allocation_id: String,
        title: String,
    },
    /// Distinct command so older hosts reject workspace routing before effects.
    SpawnWorkspaceWorker {
        host: WorkerHost,
        workspace: Option<WorkerRef>,
        task_id: TaskId,
        allocation_id: String,
        title: String,
    },
    SpawnSubagent {
        host: WorkerHost,
        parent: WorkerRef,
        task_id: TaskId,
        agent_id: String,
        allocation_id: String,
        title: String,
    },
    ResumeWorker {
        host: WorkerHost,
        binding: WorkerRef,
        task_id: TaskId,
        allocation_id: String,
    },
    ResumeAgentWorker {
        host: WorkerHost,
        binding: WorkerRef,
        task_id: TaskId,
        agent_id: String,
        allocation_id: String,
    },
}

/// The runtime keeps this much of the end of a task's or an agent's answer as
/// its summary, counted in UTF-16 code units.
pub const TASK_SUMMARY_MAX_UTF16_UNITS: usize = 4000;
pub const IMAGE_CHUNK_BYTES: u32 = 1024 * 1024;
pub const MAX_IMAGE_READ_BYTES: u32 = crate::attachments::MAX_ATTACHMENT_BYTES;

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ImageRead {
    /// The first image chunk when the header names a supported image, else the text window.
    Start,
    Next {
        at: u32,
        stamp: String,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub enum ImageMediaType {
    #[serde(rename = "image/png")]
    Png,
    #[serde(rename = "image/jpeg")]
    Jpeg,
    #[serde(rename = "image/gif")]
    Gif,
    #[serde(rename = "image/webp")]
    Webp,
    #[serde(rename = "image/bmp")]
    Bmp,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum HostResult {
    AttachmentWritten {
        next_offset: u32,
        path: Option<String>,
    },
    Browser {
        response: crate::browser::BrowserResponse,
    },
    Background {
        response: crate::background::BackgroundResponse,
    },
    Dreams {
        reply: crate::dreams::DreamsReply,
    },
    MachineSnapshot {
        snapshot: MachineSnapshot,
    },
    Usage {
        usage: crate::usage::UsageAvailability,
    },
    SharedGuidance {
        global: GuidanceSnapshot,
        workflow_policy: String,
        context_repositories: Vec<ContextRepository>,
        context_sources: Vec<GuidanceSource>,
    },
    ProjectGuidance {
        snapshot: GuidanceSnapshot,
    },
    History {
        response: HistoryResponse,
    },
    Embeddings {
        batch: EmbeddingBatch,
    },
    WorkerPresence {
        presence: WorkerPresence,
    },
    ContextMatches {
        matches: Vec<ContextMatch>,
        truncated: bool,
    },
    Resource {
        report: ResourceReport,
    },
    Process {
        exit_code: i32,
        stdout: String,
        stderr: String,
        truncated: bool,
    },
    File {
        content: String,
        truncated: bool,
    },
    /// Only ever a reply to a `ReadFile` that carries `image`.
    ImageChunk {
        media_type: ImageMediaType,
        size_bytes: u32,
        stamp: String,
        at: u32,
        data_base64: String,
    },
    Written,
    Spawned {
        binding: WorkerRef,
    },
    CreationUncertain {
        session_id: Option<String>,
    },
    /// Rex never received the create request, so retrying cannot duplicate a terminal.
    NotStarted {
        message: String,
    },
    Failed {
        message: String,
        /// Missing on older workers; absence makes no claim about execution.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        delivery: Option<HostDelivery>,
    },
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum HostDelivery {
    NotStarted,
    OutcomeUncertain,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ContextMatch {
    pub path: String,
    pub line: u32,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct RuntimeEvent {
    pub version: u32,
    pub id: u32,
    pub event: RuntimeEventKind,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum RuntimeEventKind {
    ConversationUsage {
        usage: ConversationUsage,
    },
    Attachment {
        response: crate::attachments::AttachmentResponse,
    },
    JobRun {
        run: crate::background::JobRunReceipt,
    },
    JobsSynced {
        report: crate::background::JobSyncReport,
    },
    JobStatus {
        status: crate::background::BackgroundStatus,
    },
    ScheduledJobs {
        jobs: Vec<crate::background::ScheduledJobStatus>,
    },
    ScheduledJob {
        job: crate::background::ScheduledJobStatus,
    },
    Usage {
        usage: crate::usage::UsageAvailability,
    },
    FeedbackReady {
        receipt: FeedbackReceipt,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_id: Option<String>,
    },
    Feedback {
        bundle: Box<FeedbackBundle>,
    },
    ImportProgress {
        progress: ImportProgress,
    },
    SavedMatches {
        matches: Vec<SavedMatch>,
        gaps: Vec<String>,
    },
    Conversations {
        items: Vec<SavedConversation>,
        next_cursor: Option<String>,
    },
    Configured,
    Notifications {
        status: crate::notifications::NotificationStatus,
    },
    TranscriptAnnotated {
        conversation_id: String,
        entries: Vec<TranscriptAnnotation>,
    },
    NodeRegistered {
        host_id: String,
    },
    WorkerReady {
        connection_id: String,
        /// Missing from coordinators older than owner floors.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[schemars(with = "Option<Uuid>")]
        #[ts(optional)]
        coordinator_id: Option<crate::coordinator_id::CoordinatorId>,
        /// The epoch the failover authority granted this coordinator start.
        /// Absent for a coordinator without a `[failover]` section.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[schemars(with = "Option<u64>")]
        #[ts(optional)]
        owner_epoch: Option<crate::failover::OwnerEpoch>,
    },
    Environment {
        settings: CoordinatorSettings,
        nodes: Vec<AgentNode>,
        online_host_ids: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        unavailable_host_ids: Option<Vec<String>>,
    },
    Resources {
        resources: Vec<ResourceRecord>,
    },
    Sources {
        sources: Vec<SourceState>,
    },
    SourceAdmitted {
        new_events: u32,
        checkpoint_advanced: bool,
        state: SourceState,
    },
    Notice {
        task_id: Option<TaskId>,
        text: String,
    },
    HostCall {
        call_id: String,
        command: Box<HostCommand>,
    },
    Tasks {
        tasks: Vec<TaskRecord>,
    },
    Task {
        task: Box<TaskRecord>,
        history: String,
    },
    TaskGraph {
        graph: TaskGraphSnapshot,
    },
    AuthorizationUrl {
        url: String,
    },
    AuthStatus {
        status: AuthStatus,
    },
    ConversationSettings {
        settings: ConversationSettings,
    },
    Goal {
        status: GoalStatus,
    },
    MainReady {
        /// Advertised by the runtime that persists and projects transport provenance.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_origins: Option<bool>,
        /// The origins this runtime validates, persists and names to the model.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        accepted_input_origins: Option<AcceptedInputOrigins>,
        /// Missing on legacy runtimes; native clients gate typed settings per connection.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_settings: Option<bool>,
        conversation_id: String,
        model: ModelSelection,
        cwd: String,
    },
    ConversationReady {
        conversation: SavedConversation,
        model: ModelSelection,
        cwd: String,
        working: bool,
    },
    ConversationState {
        working: bool,
    },
    Answer {
        conversation_id: String,
        text: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        entry_id: Option<String>,
    },
    History {
        conversation_id: String,
        messages: Vec<HistoryMessage>,
        next_cursor: Option<String>,
        // The final frame in this page, even when the worker stays open.
        #[serde(default)]
        page_complete: bool,
    },
    ToolDetails {
        details: crate::native::ToolDetails,
    },
    TaskReady {
        conversation_id: String,
        title: String,
    },
    WorkerIdle,
    InputRejected {
        input_id: String,
        message: String,
    },
    InputAccepted {
        input_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        work: Option<InputWorkState>,
    },
    /// The native submission has been placed into the conversation transcript.
    InputPlaced {
        input_id: String,
        entry_id: String,
    },
    TextDelta {
        text: String,
    },
    Activity {
        activity: ModelActivity,
    },
    Message {
        message: HistoryMessage,
    },
    Interrupted,
    HostCancel {
        call_id: String,
    },
    Failure {
        code: ErrorCode,
        message: String,
    },
    Done,
}

/// Immutable scheduled-run lineage copied onto the published notice.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub struct NoticeOrigin {
    pub job_id: crate::jobs::JobId,
    pub title: String,
}

/// Publication-time evidence, independent of scheduled-job lineage. Never inferred from text.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub struct NoticeDetails {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub task_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub task_title: Option<String>,
    pub source_conversation_id: String,
    pub source_entry_id: String,
    #[serde(default)]
    pub sources: Vec<NoticeSource>,
}
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub struct NoticeSource {
    pub provider: String,
    pub account: String,
    pub thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub event_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub event_version: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryMessage {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub notice_details: Option<Box<NoticeDetails>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub notice_origin: Option<NoticeOrigin>,
    pub entry_id: String,
    pub role: HistoryRole,
    pub text: String,
    pub continuation: bool,
    #[serde(default)]
    pub final_chunk: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub presentation: Option<Box<MessagePresentation>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub tool: Option<ToolHistory>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub attachments: Option<Vec<crate::attachments::AttachmentRef>>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
pub struct ToolHistory {
    pub call_id: String,
    pub name: String,
    pub status: ToolStatus,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ToolStatus {
    Running,
    Finished,
    Failed,
    Declined,
    Interrupted,
    Unknown,
}

/// Source-independent display semantics; native originals are retained separately.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessagePresentation {
    Command {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        command: Option<String>,
        exit_code: Option<i32>,
        #[ts(type = "number | null")]
        duration_ms: Option<u64>,
    },
    FileChanges {
        changes: Vec<FileChangePresentation>,
    },
    Tool {
        namespace: Option<String>,
    },
    AgentCoordination {
        action: Option<AgentAction>,
        sender_thread_id: Option<String>,
        receiver_thread_ids: Vec<String>,
        agents: Vec<AgentStatePresentation>,
    },
    AgentActivity {
        agent_path: String,
        agent_thread_id: String,
        state: Option<AgentActivityState>,
    },
    WebSearch {
        query: String,
        action: Option<WebSearchAction>,
    },
    Media {
        operation: MediaOperation,
        status: Option<String>,
        path: Option<String>,
    },
    Sleep {
        #[ts(type = "number | null")]
        duration_ms: Option<u64>,
    },
    Plan,
    Review {
        stage: ReviewStage,
    },
    HookPrompt,
    Compaction,
    Unknown {
        kind: String,
    },
    Unavailable {
        kind: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct FileChangePresentation {
    pub path: String,
    pub operation: Option<FileOperation>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum FileOperation {
    Add,
    Delete,
    Update,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum AgentAction {
    Spawn,
    SendInput,
    Resume,
    Wait,
    Close,
    SendMessage,
    Followup,
    Interrupt,
    List,
    Report,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum AgentActivityState {
    Started,
    Interacted,
    Interrupted,
    Completed,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum AgentState {
    Pending,
    Running,
    Interrupted,
    Completed,
    Failed,
    Shutdown,
    NotFound,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct AgentStatePresentation {
    pub thread_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub name: Option<String>,
    pub state: Option<AgentState>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum WebSearchAction {
    Search,
    OpenPage,
    FindInPage,
    Other,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum MediaOperation {
    View,
    Generate,
    Attachment,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum ReviewStage {
    Started,
    Finished,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum HistoryRole {
    User,
    /// Assistant text whose source did not identify a semantic phase.
    Assistant,
    Commentary,
    PartialAnswer,
    Final,
    Notice,
    Thinking,
    Tool,
}

#[derive(
    Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq, clap::ValueEnum,
)]
#[serde(rename_all = "snake_case")]
pub enum TranscriptClassification {
    Visible,
    InternalReceipt,
    MaintenanceControl,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct TranscriptAnnotation {
    pub entry_id: String,
    pub classification: TranscriptClassification,
}

#[derive(
    Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq, clap::ValueEnum,
)]
#[serde(rename_all = "snake_case")]
pub enum InputMode {
    Steer,
    #[value(name = "queue", aliases = ["follow_up", "follow-up"])]
    FollowUp,
}

/// Durable processing state, separate from acknowledgement of a saved input.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum InputWorkState {
    Queued,
    Running,
    Completed { answer_entry_id: String },
    Blocked { reason: InputBlockReason },
    Stopped,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum InputBlockReason {
    MissingTask,
    TaskTooOld,
    MigrationFailed,
    RestartLimit,
}

#[derive(
    Clone,
    Copy,
    Debug,
    Default,
    PartialEq,
    Eq,
    Deserialize,
    Serialize,
    JsonSchema,
    TS,
    clap::ValueEnum,
)]
#[serde(rename_all = "snake_case")]
pub enum SearchMode {
    #[default]
    Semantic,
    Keyword,
}

#[derive(
    Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Deserialize, Serialize, JsonSchema, TS,
)]
#[serde(rename_all = "snake_case")]
pub enum HistoryProvider {
    #[default]
    Codex,
    #[serde(rename = "chatgpt")]
    ChatGpt,
}

impl HistoryProvider {
    pub fn label(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::ChatGpt => "ChatGPT",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ImportedConversation {
    pub source: HistoryProvider,
    pub thread: HistoryThread,
    pub conversation_id: String,
    pub adopted_task_id: Option<TaskId>,
    pub complete: bool,
    pub gaps: Vec<HistoryGap>,
}

/// Coverage metadata for discovery and status reads, never an import record.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ImportedConversationSummary {
    pub source: HistoryProvider,
    pub thread: HistoryThread,
    pub conversation_id: String,
    pub adopted_task_id: Option<TaskId>,
    pub complete: bool,
    /// Bounded diagnostic examples. Full diagnostics remain in the import record.
    #[ts(type = "ReadonlyArray<import(\"./HistoryGap.js\").HistoryGap>")]
    pub gaps: Vec<HistoryGap>,
    /// Total retained diagnostics. Older producers omit this and send all gaps,
    /// so absence means the supplied array length is the full count.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub gap_count: Option<u32>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryImportBatch {
    /// Absent means Codex, for batches built before other sources existed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub source: Option<HistoryProvider>,
    pub host_id: String,
    pub thread: HistoryThread,
    pub items: Vec<HistoryItem>,
    pub next_cursor: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub resume_cursor: Option<String>,
    pub gaps: Vec<HistoryGap>,
    pub complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub source_exhausted: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[ts(optional)]
    pub retry_pages: Option<Vec<HistoryRetryPage>>,
}

/// An opaque native page locator and the unresolved asset items on that page.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryRetryPage {
    pub cursor: Option<String>,
    pub gaps: Vec<HistoryGap>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct HistoryImportReceipt {
    pub conversation: ImportedConversation,
    pub added_items: u32,
    pub existing_items: u32,
    pub entry_ids: Vec<String>,
    pub watermark: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum ImportPhase {
    Discovering,
    Importing,
    Indexing,
    Complete,
    Partial,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct ImportProgress {
    /// Older coordinators report only Codex progress and omit this field.
    #[serde(default)]
    pub source: HistoryProvider,
    pub phase: ImportPhase,
    pub host_id: Option<String>,
    pub threads_seen: u32,
    pub threads_imported: u32,
    pub threads_unchanged: u32,
    pub items_added: u32,
    pub items_unchanged: u32,
    pub assets_saved: u32,
    pub gap_count: u32,
    pub gaps: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct SavedMatch {
    pub conversation_id: String,
    pub title: String,
    pub excerpt: String,
    pub entry_ids: Vec<String>,
    pub score: f64,
    pub task_id: Option<TaskId>,
    pub imported: Option<ImportedConversationSummary>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum WorkerPresence {
    Pending,
    Present { running: bool },
    MissingSession,
    MissingTerminal,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ModelActivity {
    Thinking { text: String },
    ToolStarted { call_id: String, name: String },
    ToolFinished { call_id: String, name: String },
    Compaction { active: bool, failed: bool },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    InvalidRequest,
    AuthenticationRequired,
    AuthenticationFailed,
    ProviderUnavailable,
    CoordinatorUnavailable,
    StorageUnavailable,
    Internal,
}

#[cfg(test)]
mod tests {
    use crate::protocol::{
        HistoryMessage, HistoryProvider, HistoryRole, HostCommand, ImageRead, ImportedConversation,
        ImportedConversationSummary, RuntimeCommand, RuntimeEventKind, SearchMode, ToolHistory,
        ToolStatus,
    };

    #[test]
    fn import_chatgpt_command_round_trips_on_the_wire() {
        let wire = r#"{"type":"import_chatgpt","package":{"digest":"3f2a9c1b","parts":["export.zip"],"conversations":2,"archived":1,"shards":1,"attachments":3,"missing_attachments":1,"excluded_messages":4,"unsupported":[{"content":"message future_widget","count":2}],"dropped_library_files":1,"unreferenced_files":5,"notes":["1 broken characters are replaced with U+FFFD"],"problems":[]}}"#;
        let command: RuntimeCommand = serde_json::from_str(wire).unwrap();
        let RuntimeCommand::ImportChatGpt { package } = &command else {
            panic!("expected import_chatgpt, got {command:?}");
        };
        assert_eq!((package.conversations, package.missing_attachments), (2, 1));
        assert_eq!(
            (
                package.unsupported[0].count,
                package.dropped_library_files,
                package.unreferenced_files
            ),
            (2, 1, 5)
        );
        assert_eq!(serde_json::to_string(&command).unwrap(), wire);
    }

    #[test]
    fn history_provider_serializes_as_codex_and_chatgpt() {
        assert_eq!(
            serde_json::to_string(&[HistoryProvider::Codex, HistoryProvider::ChatGpt]).unwrap(),
            r#"["codex","chatgpt"]"#
        );
        let progress: crate::protocol::ImportProgress = serde_json::from_str(
            r#"{"phase":"complete","host_id":null,"threads_seen":0,"threads_imported":0,"threads_unchanged":0,"items_added":0,"items_unchanged":0,"assets_saved":0,"gap_count":0,"gaps":[]}"#,
        )
        .unwrap();
        assert_eq!(progress.source, HistoryProvider::Codex);
    }

    #[test]
    fn import_coverage_summary_preserves_legacy_fields_and_accepts_absent_counts() {
        let record = ImportedConversation {
            source: HistoryProvider::Codex,
            thread: crate::history::HistoryThread {
                id: "retained-thread".into(),
                title: "Retained discussion".into(),
                cwd: "/example".into(),
                created_at: 1,
                updated_at: 2,
                forked_from_id: None,
                parent_thread_id: None,
                version: "one".into(),
                version_reliable: true,
                archived: true,
            },
            conversation_id: "retained-conversation".into(),
            adopted_task_id: None,
            complete: false,
            gaps: vec![crate::history::HistoryGap {
                code: crate::history::HistoryGapCode::Missing,
                item_id: Some("retained-item".into()),
                message: "Original evidence is unavailable".into(),
            }],
        };
        let mut summary: ImportedConversationSummary =
            serde_json::from_slice(&serde_json::to_vec(&record).unwrap()).unwrap();
        assert_eq!(
            summary.gap_count, None,
            "Legacy producers sent every gap without a count"
        );
        assert_eq!(summary.gaps.len(), record.gaps.len());
        summary.gap_count = Some(2500);
        let legacy: ImportedConversation =
            serde_json::from_slice(&serde_json::to_vec(&summary).unwrap()).unwrap();
        assert_eq!(legacy.thread.id, record.thread.id);
        assert_eq!(legacy.conversation_id, record.conversation_id);
        assert!(!legacy.complete);
        assert_eq!(legacy.gaps[0].item_id, record.gaps[0].item_id);
    }

    #[test]
    fn import_embedding_host_is_optional_and_round_trips() {
        let old: RuntimeCommand =
            serde_json::from_str(r#"{"type":"import_codex","hosts":[]}"#).unwrap();
        assert!(matches!(
            old,
            RuntimeCommand::ImportCodex {
                embedding_host: None,
                ..
            }
        ));
        let command = RuntimeCommand::ImportCodex {
            hosts: vec!["archive".into()],
            embedding_host: Some("workstation".into()),
        };
        let decoded: RuntimeCommand =
            serde_json::from_slice(&serde_json::to_vec(&command).unwrap()).unwrap();
        assert!(
            matches!(decoded, RuntimeCommand::ImportCodex { hosts, embedding_host: Some(host) }
            if hosts == ["archive"] && host == "workstation")
        );
    }

    #[test]
    fn image_reads_stay_readable_by_hosts_and_coordinators_that_predate_them() {
        #[derive(serde::Deserialize, Debug, PartialEq)]
        #[serde(tag = "type", rename_all = "snake_case")]
        enum PreImageHostCommand {
            ReadFile {
                path: String,
                offset: u32,
                limit: u32,
            },
        }
        let read = |image| HostCommand::ReadFile {
            path: "/example/shot.png".into(),
            offset: 6,
            limit: 5,
            image,
        };
        for image in [
            ImageRead::Start,
            ImageRead::Next {
                at: 1_048_576,
                stamp: "fixture-stamp".into(),
            },
        ] {
            let frame = serde_json::to_vec(&read(Some(image))).unwrap();
            assert_eq!(
                serde_json::from_slice::<PreImageHostCommand>(&frame).unwrap(),
                PreImageHostCommand::ReadFile {
                    path: "/example/shot.png".into(),
                    offset: 6,
                    limit: 5,
                },
                "A host that predates image reads skips the field and reads text"
            );
        }
        assert_eq!(
            serde_json::to_value(read(None)).unwrap(),
            serde_json::json!({"type": "read_file", "path": "/example/shot.png", "offset": 6, "limit": 5}),
            "A text read is the frame it was before image reads"
        );
        let old: HostCommand = serde_json::from_str(
            r#"{"type":"read_file","path":"/example/notes.txt","offset":0,"limit":10}"#,
        )
        .unwrap();
        assert!(matches!(old, HostCommand::ReadFile { image: None, .. }));
    }

    #[test]
    fn history_page_completion_is_additive_for_older_wire_messages() {
        let old: RuntimeEventKind = serde_json::from_str(
            r#"{"type":"history","conversation_id":"saved","messages":[],"next_cursor":null}"#,
        )
        .unwrap();
        assert!(matches!(
            old,
            RuntimeEventKind::History {
                page_complete: false,
                ..
            }
        ));
        let complete = RuntimeEventKind::History {
            conversation_id: "saved".into(),
            messages: vec![],
            next_cursor: None,
            page_complete: true,
        };
        let round_trip: RuntimeEventKind =
            serde_json::from_slice(&serde_json::to_vec(&complete).unwrap()).unwrap();
        assert!(matches!(
            round_trip,
            RuntimeEventKind::History {
                page_complete: true,
                ..
            }
        ));
    }

    #[test]
    fn existing_environment_reads_do_not_request_machine_probes() {
        let command: RuntimeCommand = serde_json::from_str(r#"{"type":"environment"}"#).unwrap();
        assert!(matches!(
            command,
            RuntimeCommand::Environment { telemetry: false }
        ));
        assert_eq!(
            serde_json::to_string(&command).unwrap(),
            r#"{"type":"environment"}"#
        );
        let command: RuntimeCommand =
            serde_json::from_str(r#"{"type":"environment","telemetry":true}"#).unwrap();
        assert!(matches!(
            command,
            RuntimeCommand::Environment { telemetry: true }
        ));
    }

    #[test]
    fn old_history_without_tool_metadata_and_new_tool_identity_share_the_wire_contract() {
        let legacy: HistoryMessage = serde_json::from_str(
            r#"{"entry_id":"saved","role":"assistant","text":"Older response","continuation":false}"#,
        ).unwrap();
        assert!(matches!(legacy.role, HistoryRole::Assistant));
        assert!(legacy.tool.is_none());
        assert!(!legacy.final_chunk);
        let message = HistoryMessage {
            notice_details: None,
            notice_origin: None,
            presentation: None,
            attachments: None,
            entry_id: "result".into(),
            role: HistoryRole::Tool,
            text: "check failed".into(),
            continuation: false,
            final_chunk: true,
            tool: Some(ToolHistory {
                call_id: "native-call".into(),
                name: "check".into(),
                status: ToolStatus::Failed,
            }),
        };
        let decoded: HistoryMessage =
            serde_json::from_slice(&serde_json::to_vec(&message).unwrap()).unwrap();
        assert_eq!(decoded.tool, message.tool);
        assert!(matches!(decoded.role, HistoryRole::Tool));
        assert!(decoded.final_chunk);
        let legacy_answer: RuntimeEventKind = serde_json::from_str(
            r#"{"type":"answer","conversation_id":"main","text":"Older answer"}"#,
        )
        .unwrap();
        assert!(matches!(
            legacy_answer,
            RuntimeEventKind::Answer { entry_id: None, .. }
        ));
        let answer = RuntimeEventKind::Answer {
            conversation_id: "main".into(),
            text: "Stored answer".into(),
            entry_id: Some("native-entry".into()),
        };
        let decoded: RuntimeEventKind =
            serde_json::from_slice(&serde_json::to_vec(&answer).unwrap()).unwrap();
        assert!(
            matches!(decoded, RuntimeEventKind::Answer { entry_id: Some(entry_id), .. } if entry_id == "native-entry")
        );
    }

    #[test]
    fn history_search_mode_defaults_and_rejects_unknown_values() {
        let command: RuntimeCommand =
            serde_json::from_str(r#"{"type":"search_history","query":"saved context","limit":8}"#)
                .unwrap();
        assert!(matches!(
            command,
            RuntimeCommand::SearchHistory {
                mode: SearchMode::Semantic,
                ..
            }
        ));
        let command: RuntimeCommand = serde_json::from_str(
            r#"{"type":"search_history","query":"ERR_FIXTURE","limit":8,"mode":"keyword"}"#,
        )
        .unwrap();
        assert!(matches!(
            command,
            RuntimeCommand::SearchHistory {
                mode: SearchMode::Keyword,
                ..
            }
        ));
        assert!(
            serde_json::from_str::<RuntimeCommand>(
                r#"{"type":"search_history","query":"saved context","limit":8,"mode":"unknown"}"#,
            )
            .is_err()
        );
    }
}
