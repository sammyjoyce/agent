//! Native presentation boundary. Pi owns conversation state; Clap owns controls.
use crate::{
    chat_commands::ChatCommand,
    protocol::{
        GoalTarget, HistoryMessage, InputMode, ModelActivity, ReplyReference, RuntimeCommand,
        RuntimeEventKind, SavedConversation, SidechatNotificationPreference, SidechatSummary,
        SourceState,
    },
};
use anyhow::{Result, ensure};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeCommand {
    Native { request: NativeRequest },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum NativeRequest {
    Attachment {
        request: crate::attachments::AttachmentRequest,
    },
    Observe {
        input_ids: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        source_status: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        task_graph: Option<bool>,
    },
    TaskGraph,
    Submit {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<crate::protocol::InputOrigin>,
        input_id: String,
        text: String,
        mode: InputMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        reply_to: Option<crate::protocol::ReplyReference>,
    },
    History {
        cursor: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_id: Option<String>,
    },
    Jobs {
        job_id: Option<crate::jobs::JobId>,
    },
    RetryJob {
        job_id: crate::jobs::JobId,
    },
    Conversations {
        query: String,
        cursor: Option<String>,
    },
    /// Closing this observation detaches the view, not its executor.
    Inspect {
        conversation_id: String,
    },
    /// Main or sidechat local controls. Never submits a composer input.
    Settings {
        change: Option<crate::protocol::ConversationChange>,
        #[serde(default)]
        catalog: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_id: Option<String>,
    },
    ListSidechats {
        #[serde(default)]
        include_archived: bool,
    },
    CreateSidechat {
        title: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        slug: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        charter: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        isolated: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        notifications: Option<SidechatNotificationPreference>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        seed: Option<ReplyReference>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        handoff: Option<String>,
    },
    UpdateSidechat {
        conversation_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        title: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        slug: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        pinned: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        archived: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        charter: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        clear_charter: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        isolated: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        notifications: Option<SidechatNotificationPreference>,
    },
    ObserveSidechat {
        conversation_id: String,
        input_ids: Vec<String>,
    },
    SidechatInput {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        origin: Option<crate::protocol::InputOrigin>,
        conversation_id: String,
        input_id: String,
        text: String,
        mode: InputMode,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        attachments: Option<Vec<crate::attachments::AttachmentRef>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        reply_to: Option<ReplyReference>,
    },
    SidechatInterrupt {
        conversation_id: String,
    },
    ToolDetails {
        entry_id: String,
        call_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_id: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        task_id: Option<crate::protocol::TaskId>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        agent_id: Option<String>,
    },
    Interrupt,
    Notifications {
        request: crate::notifications::NotificationRequest,
    },
    /// Coordinator service-boundary Dreams review and explicit apply. Never forwarded to Pi.
    DreamsList,
    DreamsShow {
        run: String,
    },
    DreamsApply {
        run: String,
        approve: String,
    },
    /// Coordinator service-boundary running status and version comparison. Never forwarded to Pi.
    ServiceStatus,
    // Valid only as a connection's first frame; `service::handle` answers it
    // itself. Old coordinators close without a frame, which clients treat as
    // unidentified.
    Identify,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToolDetails {
    Available {
        call_id: String,
        name: String,
        status: crate::protocol::ToolStatus,
        input: ToolDetailContent,
        output: ToolDetailContent,
    },
    Unavailable {
        call_id: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ToolDetailContent {
    Text { text: String, truncated: bool },
    Unavailable { reason: ToolDetailUnavailable },
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum ToolDetailUnavailable {
    NotRecorded,
    Pending,
    LookupLimit,
    Unsupported,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct SlashCommand {
    pub usage: String,
    pub description: String,
}

/// Confirmed configured preference and catalog, not an in-flight request claim.
#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct NativeSettingsSnapshot {
    /// Catalog is populated only when requested. Empty fanout catalogs do not
    /// replace a client's separately fetched catalog.
    pub configured: crate::protocol::ConversationSettings,
    /// Unknown: the settings producer does not expose a generation's captured
    /// provider request. None must not be replaced with configured/default effort.
    pub effective: Option<crate::models::ModelSelection>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeJobStatus {
    List {
        jobs: Vec<crate::background::ScheduledJobStatus>,
    },
    Detail {
        job: Box<crate::background::ScheduledJobStatus>,
    },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize, JsonSchema, TS)]
#[serde(rename_all = "snake_case")]
pub enum DreamsProposalStatus {
    Pending,
    Applied,
    Stale,
    TargetDirty,
    TargetLocked,
    PatchChanged,
    PolicyChanged,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsRunSummary {
    pub run: String,
    #[ts(type = "number")]
    pub window_start_ms: u64,
    #[ts(type = "number")]
    pub window_end_ms: u64,
    pub coverage_complete: bool,
    pub outcome_label: String,
    pub proposal_status: Option<DreamsProposalStatus>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsCheckItem {
    pub name: String,
    pub phase: String,
    pub passed: bool,
    pub verdict: String,
    #[ts(type = "number")]
    pub duration_ms: u64,
    pub output: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsEvidenceCite {
    pub id: String,
    pub kind: String,
    pub title: Option<String>,
    pub body: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
pub struct DreamsRunDetail {
    pub run: String,
    #[ts(type = "number")]
    pub window_start_ms: u64,
    #[ts(type = "number")]
    pub window_end_ms: u64,
    pub coverage_complete: bool,
    pub gaps: Vec<String>,
    pub receipts_count: u32,
    pub summaries_count: u32,
    #[ts(type = "number")]
    pub summaries_captured_at_ms: u64,
    pub base_revision: String,
    pub outcome_label: String,
    pub outcome_sha256: Option<String>,
    pub proposal_status: Option<DreamsProposalStatus>,
    pub status_detail: Option<String>,
    pub rationale_or_note: Option<String>,
    pub files: Vec<String>,
    pub patch: Option<String>,
    pub patch_sha256: Option<String>,
    pub attempts_used: u8,
    pub can_apply: bool,
    pub checks: Vec<DreamsCheckItem>,
    pub cited_evidence: Vec<DreamsEvidenceCite>,
}

#[derive(Clone, Debug, Deserialize, Serialize, JsonSchema, TS)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum NativeEvent {
    FeedbackReady {
        input_id: String,
        receipt: crate::feedback::FeedbackReceipt,
    },
    Attachment {
        response: crate::attachments::AttachmentResponse,
    },
    Commands {
        commands: Vec<SlashCommand>,
    },
    Ready {
        /// Phones built before `accepted_input_origins` send `ios` only when this is true.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        input_origins: Option<bool>,
        /// The origins a submit may carry on this connection. Missing: use `input_origins`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[schemars(with = "Option<Vec<String>>")]
        #[ts(optional, as = "Option<Vec<String>>")]
        accepted_input_origins: Option<crate::protocol::AcceptedInputOrigins>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        conversation_settings: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        work_inspection: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        active_work: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        dreams: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        sidechats: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        sidechat: Option<Box<SidechatSummary>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        working: Option<bool>,
        conversation_id: String,
        model: String,
    },
    TaskGraph {
        graph: crate::protocol::TaskGraphSnapshot,
    },
    History {
        messages: Vec<HistoryMessage>,
        next_cursor: Option<String>,
        page_complete: bool,
    },
    Sources {
        sources: Vec<SourceState>,
    },
    Conversations {
        items: Vec<SavedConversation>,
        next_cursor: Option<String>,
    },
    Sidechat {
        sidechat: Box<SidechatSummary>,
    },
    Sidechats {
        items: Vec<SidechatSummary>,
    },
    Working {
        working: bool,
    },
    ToolDetails {
        details: ToolDetails,
    },
    Message {
        message: HistoryMessage,
    },
    Answer {
        entry_id: Option<String>,
        text: String,
    },
    TextDelta {
        text: String,
    },
    Activity {
        activity: ModelActivity,
    },
    Accepted {
        input_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        work: Option<crate::protocol::InputWorkState>,
    },
    Placed {
        input_id: String,
        entry_id: String,
    },
    Rejected {
        input_id: String,
        message: String,
    },
    Notice {
        text: String,
        /// Additive to the legacy notice shape, so older observers still decode it.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        settings: Option<NativeSettingsSnapshot>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        job_status: Option<NativeJobStatus>,
    },
    Failure {
        message: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        code: Option<crate::protocol::ErrorCode>,
    },
    Idle,
    Disconnect,
    Notifications {
        status: crate::notifications::NotificationStatus,
    },
    Done,
    DreamsList {
        runs: Vec<DreamsRunSummary>,
        pending_count: u32,
    },
    DreamsShow {
        report: Box<DreamsRunDetail>,
    },
    DreamsApplied {
        run: String,
        commit: String,
        already_applied: bool,
    },
    ServiceStatus {
        coordinator_id: String,
        pid: u32,
        version: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        #[ts(optional)]
        executable_path: Option<String>,
        state_dir: String,
    },
    // Older apps fail on unknown events, but they never send `Identify`.
    Identity {
        coordinator_id: String,
    },
}

/// Validated requests answered strictly at the coordinator service boundary, never forwarded to Pi.
#[derive(Clone, Debug)]
pub enum ServiceRequest {
    DreamsList,
    DreamsShow {
        run: crate::dreams::RunId,
    },
    DreamsApply {
        run: crate::dreams::RunId,
        approve: crate::dreams::ContentDigest,
    },
    ServiceStatus,
}

#[allow(clippy::large_enum_variant)]
pub enum Operation {
    Runtime(Box<RuntimeCommand>),
    Local(NativeEvent),
    Service(ServiceRequest),
}

pub fn commands() -> Vec<SlashCommand> {
    crate::chat_commands::command_help()
        .into_iter()
        .filter(|(usage, _)| {
            !matches!(
                usage.split_whitespace().next(),
                Some("/resume" | "/sidechat" | "/main")
            )
        })
        .map(|(usage, description)| SlashCommand { usage, description })
        .collect()
}

pub fn prepare(request: NativeRequest) -> Result<Operation> {
    let command = match request {
        NativeRequest::Attachment { request } => RuntimeCommand::Attachment { request },
        NativeRequest::Observe {
            input_ids,
            task_graph,
            ..
        } => {
            ensure!(input_ids.len() <= 32, "Too many pending inputs");
            for id in &input_ids {
                validate_id(id)?;
            }
            RuntimeCommand::ObserveMain {
                input_ids,
                task_graph,
            }
        }
        NativeRequest::TaskGraph => RuntimeCommand::ReadTaskGraph,
        NativeRequest::Settings {
            change,
            catalog,
            conversation_id,
        } => {
            if let Some(ref id) = conversation_id {
                validate_non_empty_id(id, "Choose a saved conversation")?;
            }
            RuntimeCommand::ConversationSettings {
                task_id: None,
                agent_id: None,
                conversation_id,
                change,
                catalog,
            }
        }
        NativeRequest::ListSidechats { include_archived } => {
            RuntimeCommand::ListSidechats { include_archived }
        }
        NativeRequest::CreateSidechat {
            title,
            slug,
            charter,
            isolated,
            notifications,
            seed,
            handoff,
        } => {
            crate::sidechats::validate_title(&title)?;
            if let Some(ref slug) = slug {
                crate::sidechats::validate_slug(slug)?;
            }
            if let Some(ref charter) = charter {
                crate::sidechats::validate_charter(charter)?;
            }
            if let Some(ref seed) = seed {
                crate::sidechats::validate_seed(seed)?;
            }
            if let Some(ref handoff) = handoff {
                crate::sidechats::validate_handoff(handoff)?;
            }
            RuntimeCommand::CreateSidechat {
                title,
                slug,
                charter,
                isolated,
                notifications,
                seed,
                handoff,
            }
        }
        NativeRequest::UpdateSidechat {
            conversation_id,
            title,
            slug,
            pinned,
            archived,
            charter,
            clear_charter,
            isolated,
            notifications,
        } => {
            validate_non_empty_id(&conversation_id, "Choose a side chat conversation")?;
            if let Some(ref title) = title {
                crate::sidechats::validate_title(title)?;
            }
            if let Some(ref slug) = slug {
                crate::sidechats::validate_slug(slug)?;
            }
            if let Some(ref charter) = charter {
                crate::sidechats::validate_charter(charter)?;
            }
            ensure!(
                !(charter.is_some() && clear_charter == Some(true)),
                "Choose either charter text or clear_charter, not both"
            );
            RuntimeCommand::UpdateSidechat {
                conversation_id,
                title,
                slug,
                pinned,
                archived,
                charter,
                clear_charter,
                isolated,
                notifications,
            }
        }
        NativeRequest::ObserveSidechat {
            conversation_id,
            input_ids,
        } => {
            validate_non_empty_id(&conversation_id, "Choose a side chat conversation")?;
            ensure!(input_ids.len() <= 32, "Too many pending inputs");
            for id in &input_ids {
                validate_id(id)?;
            }
            RuntimeCommand::ObserveSidechat {
                conversation_id,
                input_ids,
            }
        }
        NativeRequest::SidechatInput {
            origin,
            conversation_id,
            input_id,
            text,
            mode,
            attachments,
            reply_to,
        } => {
            validate_non_empty_id(&conversation_id, "Choose a side chat conversation")?;
            validate_user_input(&input_id, &text, attachments.as_deref(), reply_to.as_ref())?;
            RuntimeCommand::SidechatInput {
                origin,
                conversation_id,
                input_id,
                input: text,
                mode,
                context: None,
                attachments,
                reply_to,
            }
        }
        NativeRequest::SidechatInterrupt { conversation_id } => {
            validate_non_empty_id(&conversation_id, "Choose a side chat conversation")?;
            RuntimeCommand::ConversationInterrupt { conversation_id }
        }
        NativeRequest::History {
            cursor,
            conversation_id,
        } => match conversation_id {
            Some(conversation_id) => RuntimeCommand::ReadConversation {
                conversation_id,
                cursor,
            },
            None => RuntimeCommand::ReadHistory {
                task_id: None,
                agent_id: None,
                cursor,
            },
        },
        NativeRequest::Jobs { job_id } => match job_id {
            Some(job_id) => RuntimeCommand::ReadJob { job_id },
            None => RuntimeCommand::ListJobs,
        },
        NativeRequest::RetryJob { job_id } => RuntimeCommand::RetryJob { job_id },
        NativeRequest::Conversations { query, cursor } => {
            ensure!(query.len() <= 512, "Choose a bounded conversation search");
            RuntimeCommand::ListConversations {
                query,
                cursor,
                limit: 50,
            }
        }
        NativeRequest::Inspect { conversation_id } => {
            ensure!(
                !conversation_id.is_empty() && conversation_id.len() <= 128,
                "Choose a saved conversation"
            );
            RuntimeCommand::AttachConversation {
                conversation_id,
                input_ids: vec![],
            }
        }
        NativeRequest::ToolDetails {
            entry_id,
            call_id,
            conversation_id,
            task_id,
            agent_id,
        } => {
            let id = entry_id.parse::<u64>()?;
            ensure!(
                id > 0 && id <= 9_007_199_254_740_991 && id.to_string() == entry_id,
                "Invalid native entry ID"
            );
            ensure!(
                !call_id.is_empty() && call_id.len() <= 1024,
                "Invalid tool call ID"
            );
            if let Some(conversation_id) = conversation_id.as_deref() {
                validate_non_empty_id(conversation_id, "Choose a saved conversation")?;
            }
            RuntimeCommand::ReadToolDetails {
                entry_id,
                call_id,
                conversation_id,
                task_id,
                agent_id,
            }
        }
        NativeRequest::Interrupt => RuntimeCommand::MainInterrupt,
        NativeRequest::DreamsList => return Ok(Operation::Service(ServiceRequest::DreamsList)),
        NativeRequest::DreamsShow { run } => {
            let run = crate::dreams::RunId::parse(&run)?;
            return Ok(Operation::Service(ServiceRequest::DreamsShow { run }));
        }
        NativeRequest::DreamsApply { run, approve } => {
            let run = crate::dreams::RunId::parse(&run)?;
            let approve = crate::dreams::ContentDigest::parse(&approve)?;
            return Ok(Operation::Service(ServiceRequest::DreamsApply {
                run,
                approve,
            }));
        }
        NativeRequest::ServiceStatus => {
            return Ok(Operation::Service(ServiceRequest::ServiceStatus));
        }
        NativeRequest::Identify => {
            anyhow::bail!("Identify must be the first request on a connection")
        }
        NativeRequest::Notifications { request } => {
            request.validate()?;
            RuntimeCommand::Notifications { request }
        }
        NativeRequest::Submit {
            origin,
            input_id,
            text,
            mode,
            attachments,
            reply_to,
        } => {
            let request_id =
                validate_user_input(&input_id, &text, attachments.as_deref(), reply_to.as_ref())?;
            if let Some(control) = ChatCommand::parse(&text) {
                let control = match control {
                    Ok(control) => control,
                    Err(error) => {
                        return Ok(Operation::Local(NativeEvent::Rejected {
                            input_id,
                            message: error.to_string(),
                        }));
                    }
                };
                if reply_to.is_some() {
                    return Ok(Operation::Local(NativeEvent::Rejected {
                        input_id,
                        message: "Reply targets can only be attached to chat messages, not slash commands.".into(),
                    }));
                }
                if !matches!(&control, ChatCommand::Feedback { .. })
                    && attachments.as_ref().is_some_and(|items| !items.is_empty())
                {
                    return Ok(Operation::Local(NativeEvent::Rejected { input_id, message: "This command does not accept attachments; use /feedback or send a message.".into() }));
                }
                if let ChatCommand::RunJob(args) = &control {
                    return Ok(Operation::Runtime(Box::new(
                        args.request_with_id(format!("native-job:{input_id}")),
                    )));
                }
                let goal = control.goal(GoalTarget::Main, request_id).transpose()?;
                if let Some(command) = goal
                    .or_else(|| control.request())
                    .or_else(|| control.settings(None))
                {
                    return Ok(Operation::Runtime(Box::new(command)));
                }
                match control {
                    ChatCommand::Help => {
                        return Ok(Operation::Local(NativeEvent::Notice {
                            settings: None,
            job_status: None,
                            text: commands().into_iter().map(|command| format!("{}  {}", command.usage, command.description)).collect::<Vec<_>>().join("\n"),
                        }));
                    }
                    ChatCommand::Exit => return Ok(Operation::Local(NativeEvent::Disconnect)),
                    ChatCommand::History => RuntimeCommand::ReadHistory {
                        task_id: None,
                        agent_id: None,
                        cursor: None,
                    },
                    ChatCommand::Machines => RuntimeCommand::Environment { telemetry: true },
                    ChatCommand::Feedback { description } => RuntimeCommand::MainFeedback {
                        description: description.join(" "), input_id: attachments.as_ref().map(|_| input_id), attachments,
                    },
                    ChatCommand::Resume { .. } => return Ok(Operation::Local(NativeEvent::Rejected {
                        input_id, message: "This phone client stays on the main conversation. Saved conversation viewing with /resume is available in the TUI.".into(),
                    })),
                    ChatCommand::Sidechat { .. } | ChatCommand::Main => return Ok(Operation::Local(NativeEvent::Rejected {
                        input_id, message: "Use the Side chats button in the header to browse or switch standing side chats.".into(),
                    })),
                    ChatCommand::Status | ChatCommand::Model { .. } | ChatCommand::Fast { .. }
                    | ChatCommand::Reasoning { .. } | ChatCommand::Jobs { .. }
                    | ChatCommand::RunJob(_) | ChatCommand::Worktrees | ChatCommand::Goal { .. } => anyhow::bail!("The shared control handler did not accept this request"),
                }
            } else {
                RuntimeCommand::MainInput {
                    origin,
                    input_id,
                    input: text,
                    mode,
                    context: None,
                    attachments,
                    reply_to,
                }
            }
        }
    };
    Ok(Operation::Runtime(Box::new(command)))
}

fn validate_non_empty_id(value: &str, message: &str) -> Result<()> {
    ensure!(
        !value.trim().is_empty()
            && value.len() <= 128
            && !value
                .chars()
                .any(|character| character.is_whitespace() || character.is_control()),
        "{message}"
    );
    Ok(())
}

fn validate_reply_reference(reply_to: Option<&crate::protocol::ReplyReference>) -> Result<()> {
    if let Some(reference) = reply_to {
        validate_non_empty_id(&reference.entry_id, "Invalid reply target entry ID")?;
        ensure!(
            reference.excerpt.len() <= 4096,
            "Reply excerpt must be at most 4096 UTF-8 bytes"
        );
    }
    Ok(())
}

fn validate_user_input(
    input_id: &str,
    text: &str,
    attachments: Option<&[crate::attachments::AttachmentRef]>,
    reply_to: Option<&crate::protocol::ReplyReference>,
) -> Result<uuid::Uuid> {
    let request_id = validate_id(input_id)?;
    ensure!(
        (!text.trim().is_empty() || attachments.is_some_and(|items| !items.is_empty()))
            && text.len() <= 65_536,
        "Input must contain 1 to 65536 UTF-8 bytes"
    );
    ensure!(
        attachments.is_none_or(|items| items.len() <= crate::attachments::MAX_ATTACHMENTS),
        "Choose at most eight attachments"
    );
    validate_reply_reference(reply_to)?;
    Ok(request_id)
}

fn validate_id(id: &str) -> Result<uuid::Uuid> {
    match uuid::Uuid::parse_str(id) {
        Ok(id) if !id.is_nil() => Ok(id),
        _ => anyhow::bail!("Input ID must be a nonnil UUID"),
    }
}

fn model_label(model: &crate::models::ModelSelection) -> String {
    format!(
        "{}/{} · {}{}",
        model.provider.as_str(),
        model.model_id,
        model
            .reasoning
            .map_or("default", crate::models::Reasoning::as_str),
        if model.fast { " · fast" } else { "" }
    )
}

#[allow(clippy::too_many_arguments)]
fn project_ready(
    input_origins: Option<bool>,
    accepted_input_origins: Option<&crate::protocol::AcceptedInputOrigins>,
    conversation_settings: Option<bool>,
    work_inspection: Option<bool>,
    active_work: Option<bool>,
    sidechats: Option<bool>,
    sidechat: Option<Box<crate::protocol::SidechatSummary>>,
    working: Option<bool>,
    conversation_id: &str,
    model: &crate::models::ModelSelection,
) -> NativeEvent {
    let accepted = crate::protocol::AcceptedInputOrigins::from_main_ready(
        accepted_input_origins,
        input_origins,
    );
    NativeEvent::Ready {
        input_origins: accepted.flag_for_phones_before_the_list(),
        accepted_input_origins: accepted.non_empty(),
        conversation_settings,
        work_inspection,
        active_work,
        dreams: None,
        sidechats,
        sidechat,
        working,
        conversation_id: conversation_id.to_owned(),
        model: model_label(model),
    }
}

pub fn project(event: &RuntimeEventKind) -> Option<NativeEvent> {
    if let Some(text) = crate::job_view::event(event) {
        return Some(NativeEvent::Notice {
            text,
            settings: None,
            job_status: match event {
                RuntimeEventKind::ScheduledJobs { jobs } => {
                    Some(NativeJobStatus::List { jobs: jobs.clone() })
                }
                RuntimeEventKind::ScheduledJob { job } => Some(NativeJobStatus::Detail {
                    job: Box::new(job.clone()),
                }),
                _ => None,
            },
        });
    }
    Some(match event {
        RuntimeEventKind::Attachment { response } => NativeEvent::Attachment {
            response: response.clone(),
        },
        RuntimeEventKind::MainReady {
            input_origins,
            accepted_input_origins,
            conversation_settings,
            active_work,
            sidechats,
            conversation_id,
            model,
            ..
        } => project_ready(
            *input_origins,
            accepted_input_origins.as_ref(),
            *conversation_settings,
            Some(true),
            *active_work,
            *sidechats,
            None,
            None,
            conversation_id,
            model,
        ),
        RuntimeEventKind::SidechatReady {
            input_origins,
            accepted_input_origins,
            conversation_settings,
            conversation_id,
            sidechat,
            model,
            working,
            ..
        } => project_ready(
            *input_origins,
            accepted_input_origins.as_ref(),
            *conversation_settings,
            None,
            None,
            Some(true),
            Some(Box::new(sidechat.clone())),
            Some(*working),
            conversation_id,
            model,
        ),
        RuntimeEventKind::ConversationReady {
            conversation,
            model,
            working,
            ..
        } => NativeEvent::Ready {
            input_origins: None,
            accepted_input_origins: None,
            conversation_settings: None,
            work_inspection: None,
            active_work: None,
            dreams: None,
            sidechats: None,
            sidechat: None,
            working: Some(*working),
            conversation_id: conversation.conversation_id.clone(),
            model: model_label(model),
        },
        RuntimeEventKind::ConversationState { working } => {
            NativeEvent::Working { working: *working }
        }
        RuntimeEventKind::Conversations { items, next_cursor } => NativeEvent::Conversations {
            items: items.clone(),
            next_cursor: next_cursor.clone(),
        },
        RuntimeEventKind::Sidechat { sidechat } => NativeEvent::Sidechat {
            sidechat: Box::new(sidechat.clone()),
        },
        RuntimeEventKind::Sidechats { items } => NativeEvent::Sidechats {
            items: items.clone(),
        },
        RuntimeEventKind::History {
            messages,
            next_cursor,
            page_complete,
            ..
        } => NativeEvent::History {
            messages: messages.clone(),
            next_cursor: next_cursor.clone(),
            page_complete: *page_complete,
        },
        RuntimeEventKind::ToolDetails { details } => NativeEvent::ToolDetails {
            details: details.clone(),
        },
        RuntimeEventKind::Sources { sources } => NativeEvent::Sources {
            sources: sources.clone(),
        },
        RuntimeEventKind::Message { message } => NativeEvent::Message {
            message: message.clone(),
        },
        RuntimeEventKind::Notifications { status } => NativeEvent::Notifications {
            status: status.clone(),
        },
        RuntimeEventKind::Answer { entry_id, text, .. } => NativeEvent::Answer {
            entry_id: entry_id.clone(),
            text: text.clone(),
        },
        RuntimeEventKind::TextDelta { text } => NativeEvent::TextDelta { text: text.clone() },
        RuntimeEventKind::Activity { activity } => NativeEvent::Activity {
            activity: activity.clone(),
        },
        RuntimeEventKind::InputAccepted { input_id, work } => NativeEvent::Accepted {
            input_id: input_id.clone(),
            work: work.clone(),
        },
        RuntimeEventKind::InputPlaced { input_id, entry_id } => NativeEvent::Placed {
            input_id: input_id.clone(),
            entry_id: entry_id.clone(),
        },
        RuntimeEventKind::InputRejected { input_id, message } => NativeEvent::Rejected {
            input_id: input_id.clone(),
            message: message.clone(),
        },
        RuntimeEventKind::Failure { code, message } => NativeEvent::Failure {
            message: message.clone(),
            code: Some(code.clone()),
        },
        RuntimeEventKind::Notice { text, .. } => NativeEvent::Notice {
            settings: None,
            job_status: None,
            text: text.clone(),
        },
        RuntimeEventKind::Interrupted | RuntimeEventKind::WorkerIdle => NativeEvent::Idle,
        RuntimeEventKind::Done => NativeEvent::Done,
        RuntimeEventKind::ConversationSettings { settings } => NativeEvent::Notice {
            job_status: None,
            settings: Some(NativeSettingsSnapshot {
                configured: settings.clone(),
                effective: None,
            }),
            text: std::iter::once(model_label(&settings.model))
                .chain(settings.catalog.iter().map(|model| {
                    format!(
                        "{}/{} · {}",
                        model.provider.as_str(),
                        model.model_id,
                        model.name
                    )
                }))
                .collect::<Vec<_>>()
                .join("\n"),
        },
        RuntimeEventKind::Environment {
            nodes,
            online_host_ids,
            unavailable_host_ids,
            ..
        } => NativeEvent::Notice {
            settings: None,
            job_status: None,
            text: crate::machines::MachineInventory {
                nodes: nodes.clone(),
                online_host_ids: online_host_ids.clone(),
                unavailable_host_ids: unavailable_host_ids.clone().unwrap_or_default(),
            }
            .format(std::time::SystemTime::now()),
        },
        RuntimeEventKind::Resources { resources } => NativeEvent::Notice {
            settings: None,
            job_status: None,
            text: crate::resources::format_inventory(resources),
        },
        RuntimeEventKind::TaskGraph { graph } => NativeEvent::TaskGraph {
            graph: graph.clone(),
        },
        RuntimeEventKind::Goal { status } => NativeEvent::Notice {
            settings: None,
            job_status: None,
            text: crate::goal_view::format(status),
        },
        RuntimeEventKind::FeedbackReady {
            receipt,
            input_id: Some(input_id),
        } => NativeEvent::FeedbackReady {
            input_id: input_id.clone(),
            receipt: receipt.clone(),
        },
        RuntimeEventKind::FeedbackReady {
            receipt,
            input_id: None,
        } => NativeEvent::Notice {
            settings: None,
            job_status: None,
            text: format!("Feedback saved. Repair task: {}", receipt.task_id),
        },
        _ => return None,
    })
}

#[cfg(test)]
mod tests {
    use crate::{
        native::{NativeCommand, NativeEvent, NativeRequest, Operation, ServiceRequest, prepare},
        protocol::{InputMode, RuntimeCommand, RuntimeEventKind},
    };

    #[test]
    fn native_settings_prepare_main_only_explicit_defaults_and_truthful_ready_capabilities() {
        use crate::protocol::{ConversationChange, FastMode, RuntimeEventKind};
        for change in [
            ConversationChange::SetReasoning { reasoning: None },
            ConversationChange::SetFast { mode: FastMode::On },
            ConversationChange::SetFast {
                mode: FastMode::Off,
            },
        ] {
            let request = NativeRequest::Settings {
                change: Some(change.clone()),
                catalog: true,
                conversation_id: None,
            };
            let decoded = serde_json::from_slice(&serde_json::to_vec(&request).unwrap()).unwrap();
            let Operation::Runtime(command) = prepare(decoded).unwrap() else {
                panic!("Expected local settings")
            };
            let RuntimeCommand::ConversationSettings {
                task_id,
                agent_id,
                conversation_id,
                change: actual,
                catalog,
            } = *command
            else {
                panic!("Settings must not submit a chat input")
            };
            assert!(task_id.is_none() && agent_id.is_none() && conversation_id.is_none());
            assert!(catalog);
            match (change, actual) {
                (
                    ConversationChange::SetReasoning { reasoning: None },
                    Some(ConversationChange::SetReasoning { reasoning: None }),
                ) => {}
                (
                    ConversationChange::SetFast { mode: expected },
                    Some(ConversationChange::SetFast { mode: actual }),
                ) => assert_eq!(actual, expected),
                _ => panic!("An explicit preference changed in transport"),
            }
        }
        for advertised in [None, Some(false), Some(true)] {
            let event = RuntimeEventKind::MainReady {
                conversation_id: "1".into(),
                cwd: "/".into(),
                model: crate::models::ModelSelection::default(),
                input_origins: advertised,
                accepted_input_origins: None,
                conversation_settings: advertised,
                active_work: advertised,
                sidechats: advertised,
            };
            let Some(NativeEvent::Ready {
                input_origins,
                conversation_settings,
                active_work,
                sidechats,
                ..
            }) = crate::native::project(&event)
            else {
                panic!("Expected main ready")
            };
            assert_eq!(active_work, advertised);
            assert_eq!(sidechats, advertised);
            assert_eq!(input_origins, advertised.filter(|value| *value));
            assert_eq!(conversation_settings, advertised);
        }
        let legacy: RuntimeEventKind = serde_json::from_str(r#"{"type":"main_ready","conversation_id":"1","cwd":"/","model":{"provider":"openai","model_id":"fixture","reasoning":null,"fast":false}}"#).unwrap();
        assert!(matches!(
            crate::native::project(&legacy),
            Some(NativeEvent::Ready {
                input_origins: None,
                conversation_settings: None,
                ..
            })
        ));
    }

    #[test]
    fn ready_advertises_only_origins_both_the_runtime_and_this_binary_accept() {
        let model =
            r#""model":{"provider":"openai","model_id":"fixture","reasoning":null,"fast":false}"#;
        let rows = [
            (r#""#, r#""#),
            (
                r#""input_origins":true,"#,
                r#""input_origins":true,"accepted_input_origins":["cli","ios"],"#,
            ),
            (
                r#""input_origins":true,"accepted_input_origins":["cli","ios","siri"],"#,
                r#""input_origins":true,"accepted_input_origins":["cli","ios","siri"],"#,
            ),
            (
                r#""input_origins":true,"accepted_input_origins":["cli","ios","siri","carplay"],"#,
                r#""input_origins":true,"accepted_input_origins":["cli","ios","siri","carplay"],"#,
            ),
            (
                r#""input_origins":true,"accepted_input_origins":["watch","carplay","siri","cli","ios","siri"],"#,
                r#""input_origins":true,"accepted_input_origins":["cli","ios","siri","carplay"],"#,
            ),
            (
                r#""input_origins":true,"accepted_input_origins":["cli"],"#,
                r#""accepted_input_origins":["cli"],"#,
            ),
        ];
        for (runtime, phone) in rows {
            let event: RuntimeEventKind = serde_json::from_str(&format!(
                r#"{{"type":"main_ready",{runtime}"conversation_id":"1","cwd":"/",{model}}}"#
            ))
            .unwrap();
            let ready = serde_json::to_string(&crate::native::project(&event).unwrap()).unwrap();
            assert_eq!(
                ready,
                format!(
                    r#"{{"type":"ready",{phone}"work_inspection":true,"conversation_id":"1","model":"openai/fixture · default"}}"#
                ),
                "{runtime}"
            );
        }
    }

    #[test]
    fn native_submit_rejects_an_origin_this_coordinator_does_not_advertise() {
        let submit = |origin: &str| {
            serde_json::from_str::<NativeCommand>(&format!(
                r#"{{"type":"native","request":{{"type":"submit","input_id":"22222222-2222-4222-8222-222222222222","text":"x","mode":"steer","origin":"{origin}"}}}}"#
            ))
        };
        assert!(submit("siri").is_ok());
        assert!(submit("carplay").is_ok());
        assert!(submit("watch").is_err());
    }

    #[test]
    fn native_notice_origin_survives_live_and_historical_projection() {
        use crate::protocol::{HistoryMessage, HistoryRole, NoticeOrigin, RuntimeEventKind};
        let origin = NoticeOrigin {
            job_id: "package-tracking".to_string().try_into().unwrap(),
            title: "Package tracking".into(),
        };
        let details: crate::protocol::NoticeDetails = serde_json::from_str(r#"{"task_id":"invented-task","task_title":"Parcel decision","source_conversation_id":"2","source_entry_id":"9","sources":[{"provider":"mail","account":"invented-account","thread_id":"invented-thread","title":"Delivery","event_id":"event","event_version":"v1"}]}"#).unwrap();
        let row = HistoryMessage {
            notice_details: Some(Box::new(details.clone())),
            notice_origin: Some(origin.clone()),
            entry_id: "10".into(),
            role: HistoryRole::Notice,
            text: "A concrete decision is needed.".into(),
            continuation: false,
            final_chunk: true,
            presentation: None,
            tool: None,
            attachments: None,
            reply_to: None,
        };
        for event in [
            RuntimeEventKind::Message {
                message: row.clone(),
            },
            RuntimeEventKind::History {
                conversation_id: "1".into(),
                messages: vec![row],
                next_cursor: None,
                page_complete: true,
            },
        ] {
            let projected = crate::native::project(&event).unwrap();
            let wire = serde_json::to_vec(&projected).unwrap();
            let decoded: NativeEvent = serde_json::from_slice(&wire).unwrap();
            let actual = match decoded {
                NativeEvent::Message { message } => message,
                NativeEvent::History { mut messages, .. } => messages.remove(0),
                other => panic!("Unexpected native projection: {other:?}"),
            };
            assert_eq!(actual.notice_origin, Some(origin.clone()));
            assert_eq!(actual.notice_details, Some(Box::new(details.clone())));
            assert_eq!(actual.entry_id, "10");
            #[derive(serde::Deserialize)]
            struct LegacyRow {
                text: String,
            }
            let legacy: LegacyRow =
                serde_json::from_slice(&serde_json::to_vec(&actual).unwrap()).unwrap();
            assert_eq!(legacy.text, actual.text);
        }
        let legacy: HistoryMessage = serde_json::from_str(r#"{"entry_id":"1","role":"notice","text":"Legacy notice","continuation":false,"final_chunk":true}"#).unwrap();
        assert_eq!(legacy.notice_origin, None);
        assert_eq!(legacy.notice_details, None);
    }

    #[test]
    fn native_settings_keep_confirmed_values_and_capabilities_without_a_new_event_variant() {
        use crate::{
            models::{ModelProvider, ModelSelection, Reasoning},
            protocol::{ConversationSettings, ModelOption, RuntimeEventKind},
        };
        let settings = ConversationSettings {
            conversation_id: "1".into(),
            task_id: None,
            agent_id: None,
            model: ModelSelection::default(),
            catalog: vec![ModelOption {
                provider: ModelProvider::OpenAi,
                model_id: "gpt-6.1-sol".into(),
                name: "Native catalog entry".into(),
                reasoning: vec![Reasoning::Low, Reasoning::High, Reasoning::Xhigh],
                fast: true,
            }],
        };
        let event = crate::native::project(&RuntimeEventKind::ConversationSettings {
            settings: settings.clone(),
        })
        .unwrap();
        let NativeEvent::Notice {
            ref text,
            settings: Some(ref current),
            ..
        } = event
        else {
            panic!("Settings must retain the legacy notice shape")
        };
        assert!(text.starts_with("openai/gpt-6.1-sol · xhigh"));
        assert_eq!(current.configured.model, settings.model);
        assert_eq!(
            current.configured.catalog[0].reasoning,
            settings.catalog[0].reasoning
        );
        assert!(current.configured.catalog[0].fast);
        assert!(
            current.effective.is_none(),
            "Configured settings are not captured in-flight settings"
        );
        #[derive(serde::Deserialize)]
        struct LegacyNotice {
            text: String,
        }
        let old: LegacyNotice =
            serde_json::from_slice(&serde_json::to_vec(&event).unwrap()).unwrap();
        assert_eq!(old.text, *text);
        let old: NativeEvent =
            serde_json::from_str(r#"{"type":"notice","text":"Legacy notice"}"#).unwrap();
        assert!(matches!(
            old,
            NativeEvent::Notice {
                settings: None,
                job_status: None,
                ..
            }
        ));
        let old: NativeEvent = serde_json::from_str(
            r#"{"type":"ready","conversation_id":"1","model":"Legacy model"}"#,
        )
        .unwrap();
        assert!(matches!(
            old,
            NativeEvent::Ready {
                input_origins: None,
                ..
            }
        ));
    }

    #[test]
    fn source_coverage_projects_through_the_native_wire_without_becoming_a_notice() {
        use crate::{
            protocol::{RuntimeEventKind, SourceState},
            sources::{SourceCoverage, SourceKey},
        };
        let event = RuntimeEventKind::Sources {
            sources: vec![SourceState {
                source: SourceKey {
                    provider: "google".into(),
                    account: "mail-primary".into(),
                },
                checkpoint: None,
                coverage: SourceCoverage::Unavailable {
                    message: "Provider read failed".into(),
                },
                checked_at: 1,
                last_completed_at: None,
                progress: None,
            }],
        };
        let native =
            crate::native::project(&event).expect("Source coverage must reach native observers");
        let decoded: RuntimeEventKind =
            serde_json::from_slice(&serde_json::to_vec(&native).unwrap()).unwrap();
        let RuntimeEventKind::Sources { sources } = decoded else {
            panic!("Source status must remain typed")
        };
        assert_eq!(sources.len(), 1);
        assert!(matches!(
            sources[0].coverage,
            SourceCoverage::Unavailable { .. }
        ));
    }

    #[test]
    fn omitted_attachment_fields_preserve_old_wire_and_new_feedback_has_a_correlated_receipt() {
        let input_id = uuid::Uuid::new_v4().to_string();
        let legacy: NativeRequest = serde_json::from_str(&format!(r#"{{"type":"submit","input_id":"{input_id}","text":"/feedback report","mode":"steer"}}"#)).unwrap();
        assert!(
            !String::from_utf8(serde_json::to_vec(&legacy).unwrap())
                .unwrap()
                .contains("attachments")
        );
        let Operation::Runtime(command) = prepare(legacy).unwrap() else {
            panic!("Expected shared feedback")
        };
        assert!(matches!(
            *command,
            RuntimeCommand::MainFeedback {
                input_id: None,
                attachments: None,
                ..
            }
        ));
        let Operation::Runtime(command) = prepare(NativeRequest::Submit {
            origin: None,
            input_id: input_id.clone(),
            text: "/feedback report".into(),
            mode: InputMode::Steer,
            attachments: Some(vec![]),
            reply_to: None,
        })
        .unwrap() else {
            panic!("Expected shared feedback")
        };
        assert!(
            matches!(*command, RuntimeCommand::MainFeedback { input_id: Some(ref id), .. } if id == &input_id)
        );
        let receipt = crate::feedback::FeedbackReceipt {
            id: input_id.clone(),
            path: "/invented/private/feedback.json".into(),
            task_id: crate::protocol::TaskId::new(),
            agent_id: None,
        };
        assert!(matches!(
            crate::native::project(&crate::protocol::RuntimeEventKind::FeedbackReady {
                receipt: receipt.clone(),
                input_id: None
            }),
            Some(crate::native::NativeEvent::Notice { .. })
        ));
        assert!(
            matches!(crate::native::project(&crate::protocol::RuntimeEventKind::FeedbackReady { receipt, input_id: Some(input_id.clone()) }), Some(crate::native::NativeEvent::FeedbackReady { input_id: id, .. }) if id == input_id)
        );
    }

    #[test]
    fn file_only_input_reaches_main_but_control_commands_preserve_the_attachment_draft() {
        let attachment = crate::attachments::AttachmentRef {
            id: uuid::Uuid::new_v4().to_string(),
            name: "screenshot.png".into(),
            media_type: "image/png".into(),
            size_bytes: 0,
            sha256: "0".repeat(64),
        };
        let request = |text: &str| NativeRequest::Submit {
            origin: None,
            input_id: uuid::Uuid::new_v4().to_string(),
            text: text.into(),
            mode: InputMode::Steer,
            attachments: Some(vec![attachment.clone()]),
            reply_to: None,
        };
        assert!(
            matches!(prepare(request("")).unwrap(), Operation::Runtime(command) if matches!(*command, RuntimeCommand::MainInput { ref attachments, .. } if attachments.as_ref().unwrap() == std::slice::from_ref(&attachment)))
        );
        assert!(matches!(
            prepare(request("/help")).unwrap(),
            Operation::Local(crate::native::NativeEvent::Rejected { .. })
        ));
    }
    #[test]
    fn manual_job_controls_reuse_native_input_identity_across_retries() {
        let input_id = uuid::Uuid::new_v4().to_string();
        let request = || NativeRequest::Submit {
            origin: None,
            attachments: None,
            reply_to: None,
            input_id: input_id.clone(),
            text: "/run-job Daily_Review.v2 --schedule Morning.v1".into(),
            mode: InputMode::Steer,
        };
        let mut ids = Vec::new();
        for _ in 0..2 {
            let Operation::Runtime(command) = prepare(request()).unwrap() else {
                panic!("Manual control must reach the shared job controller");
            };
            let RuntimeCommand::RunJob {
                job_id,
                schedule_id: Some(schedule_id),
                request_id,
            } = *command
            else {
                panic!("Manual control must produce a typed job admission");
            };
            assert_eq!(job_id.as_str(), "Daily_Review.v2");
            assert_eq!(schedule_id.as_str(), "Morning.v1");
            ids.push(request_id);
        }
        assert_eq!(
            ids,
            [
                format!("native-job:{input_id}"),
                format!("native-job:{input_id}")
            ]
        );
    }

    #[test]
    fn native_job_inspection_is_a_read_only_control() {
        for (job_id, expected) in [
            (None, None),
            (Some("example-review"), Some("example-review")),
        ] {
            #[derive(serde::Serialize)]
            struct Request<'a> {
                r#type: &'static str,
                job_id: Option<&'a str>,
            }
            #[derive(serde::Serialize)]
            struct Envelope<'a> {
                r#type: &'static str,
                request: Request<'a>,
            }
            let wire = serde_json::to_vec(&Envelope {
                r#type: "native",
                request: Request {
                    r#type: "jobs",
                    job_id,
                },
            })
            .unwrap();
            let request = serde_json::from_slice::<crate::native::NativeCommand>(&wire);
            assert!(
                request.is_ok(),
                "Native clients need a read-only job inspection request"
            );
            let crate::native::NativeCommand::Native { request } = request.unwrap();
            let Operation::Runtime(command) = prepare(request).unwrap() else {
                panic!("Job inspection must use the existing runtime reader");
            };
            match (expected, *command) {
                (None, RuntimeCommand::ListJobs) => {}
                (Some(expected), RuntimeCommand::ReadJob { job_id }) => {
                    assert_eq!(job_id.as_str(), expected)
                }
                _ => panic!("Job inspection must not submit or run a job"),
            }
        }
    }

    #[test]
    fn native_job_notices_retain_typed_run_diagnostics_and_legacy_text() {
        use crate::{
            background::{JobExecution, JobExecutionState, ScheduledJobStatus},
            jobs::{JobSchedule, ScheduledJob, UtcMillis},
            protocol::RuntimeEventKind,
        };
        #[derive(serde::Deserialize)]
        struct NoticeContract {
            text: String,
            job_status: Option<JobContract>,
        }
        #[derive(serde::Deserialize)]
        #[serde(tag = "type", rename_all = "snake_case")]
        enum JobContract {
            List { jobs: Vec<ScheduledJobStatus> },
            Detail { job: Box<ScheduledJobStatus> },
        }
        let mut job = ScheduledJobStatus {
            job: ScheduledJob {
                id: "example-review".to_string().try_into().unwrap(),
                title: "Example review".into(),
                prompt: "Review existing evidence".into(),
                model: crate::models::ModelSelection::default(),
                timezone: "Etc/UTC".to_string().try_into().unwrap(),
                cwd: "/workspace/example".into(),
                delivery_sidechat: None,
                revision: "original".into(),
                schedules: vec![JobSchedule {
                    id: "daily".to_string().try_into().unwrap(),
                    recurrence: "DTSTART:20270101T090000Z\nRRULE:FREQ=DAILY"
                        .to_string()
                        .try_into()
                        .unwrap(),
                    focus: None,
                    prompt: None,
                }],
            },
            schedules: vec![],
            task_id: Some(crate::protocol::TaskId::new()),
            last_run: None,
        };
        let decode = |event| {
            let projected = crate::native::project(&event).unwrap();
            serde_json::from_slice::<NoticeContract>(&serde_json::to_vec(&projected).unwrap())
                .unwrap()
        };
        let listing = decode(RuntimeEventKind::ScheduledJobs {
            jobs: vec![job.clone()],
        });
        assert!(!listing.text.is_empty());
        let Some(JobContract::List { jobs }) = listing.job_status else {
            panic!("Job notices must retain typed diagnostics for native navigation");
        };
        assert_eq!(jobs.len(), 1);
        assert!(
            jobs[0].task_id.is_some(),
            "The owner must remain visible when legacy run timing is absent"
        );
        assert!(jobs[0].last_run.is_none(), "Old timing must remain unknown");
        job.last_run = Some(JobExecution {
            schedule_id: "daily".to_string().try_into().unwrap(),
            scheduled_at: UtcMillis::new(1).unwrap(),
            started_at: Some(UtcMillis::new(2).unwrap()),
            finished_at: None,
            revision: "captured".into(),
            state: JobExecutionState::Blocked {
                message: "Retained native task needs inspection".into(),
            },
            task_id: Some(crate::protocol::TaskId::new()),
            output: Some("Complete retained output\nwith another line".into()),
            output_truncated: false,
        });
        let detail = decode(RuntimeEventKind::ScheduledJob { job });
        assert!(
            detail
                .text
                .contains("Retained native task needs inspection")
        );
        let Some(JobContract::Detail { job }) = detail.job_status else {
            panic!("Job details must retain their typed execution");
        };
        let run = job.last_run.unwrap();
        assert!(
            matches!(run.state, JobExecutionState::Blocked { message } if message == "Retained native task needs inspection")
        );
        assert_eq!(
            run.output.as_deref(),
            Some("Complete retained output\nwith another line")
        );
        assert!(run.finished_at.is_none());
    }

    #[test]
    fn native_envelope_is_consumed_by_the_real_transport_and_bounds_are_enforced() {
        let id = uuid::Uuid::new_v4().to_string();
        let command = crate::native::NativeCommand::Native {
            request: NativeRequest::Observe {
                input_ids: vec![id.clone()],
                source_status: None,
                task_graph: None,
            },
        };
        let bytes = serde_json::to_vec(&command).unwrap();
        assert!(
            matches!(serde_json::from_slice::<RuntimeCommand>(&bytes).unwrap(),
            RuntimeCommand::Native { request: NativeRequest::Observe { input_ids, source_status: None, task_graph: None } } if input_ids == [id])
        );
        for input_id in [String::new(), uuid::Uuid::nil().to_string()] {
            assert!(
                prepare(NativeRequest::Submit {
                    origin: None,
                    attachments: None,
                    reply_to: None,
                    input_id,
                    text: "Hello".into(),
                    mode: InputMode::Steer
                })
                .is_err()
            );
        }
        assert!(
            prepare(NativeRequest::Observe {
                input_ids: (0..33).map(|_| uuid::Uuid::new_v4().to_string()).collect(),
                source_status: None,
                task_graph: None,
            })
            .is_err()
        );
        for text in [" ".to_owned(), "🦀".repeat(16385)] {
            assert!(
                prepare(NativeRequest::Submit {
                    origin: None,
                    attachments: None,
                    reply_to: None,
                    input_id: uuid::Uuid::new_v4().to_string(),
                    text,
                    mode: InputMode::Steer
                })
                .is_err()
            );
        }
    }

    #[test]
    fn tool_details_keep_the_durable_anchor_and_never_become_model_input() {
        let Operation::Runtime(command) = prepare(NativeRequest::ToolDetails {
            conversation_id: None,
            task_id: None,
            agent_id: None,
            entry_id: "42".into(),
            call_id: "provider-call".into(),
        })
        .unwrap() else {
            panic!("Expected a read-only runtime lookup");
        };
        assert!(
            matches!(*command, RuntimeCommand::ReadToolDetails { entry_id, call_id, conversation_id: None, task_id: None, agent_id: None }
            if entry_id == "42" && call_id == "provider-call")
        );
        for entry_id in ["", "0", "-1", "01", "1.0", "9007199254740992"] {
            assert!(
                prepare(NativeRequest::ToolDetails {
                    conversation_id: None,
                    task_id: None,
                    agent_id: None,
                    entry_id: entry_id.into(),
                    call_id: "provider-call".into(),
                })
                .is_err()
            );
        }
        for call_id in [String::new(), "🦀".repeat(257)] {
            assert!(
                prepare(NativeRequest::ToolDetails {
                    conversation_id: None,
                    task_id: None,
                    agent_id: None,
                    entry_id: "42".into(),
                    call_id,
                })
                .is_err()
            );
        }
        let projected = crate::native::project(&crate::protocol::RuntimeEventKind::ToolDetails {
            details: crate::native::ToolDetails::Unavailable {
                call_id: "provider-call".into(),
            },
        });
        assert!(
            matches!(projected, Some(crate::native::NativeEvent::ToolDetails {
            details: crate::native::ToolDetails::Unavailable { call_id }
        }) if call_id == "provider-call")
        );
    }

    #[test]
    fn native_catalog_does_not_advertise_task_or_saved_conversation_execution() {
        assert!(
            crate::native::commands()
                .iter()
                .all(|command| !command.usage.starts_with("/resume"))
        );
        assert!(matches!(
            prepare(NativeRequest::Submit {
                origin: None,
                attachments: None,
                reply_to: None,
                input_id: uuid::Uuid::new_v4().to_string(),
                text: "/resume saved-chat".into(),
                mode: InputMode::Steer
            })
            .unwrap(),
            Operation::Local(crate::native::NativeEvent::Rejected { .. })
        ));
    }

    #[test]
    fn worktree_control_uses_existing_inventory_without_model_input() {
        for mode in [InputMode::Steer, InputMode::FollowUp] {
            let operation = prepare(NativeRequest::Submit {
                origin: None,
                attachments: None,
                reply_to: None,
                input_id: uuid::Uuid::new_v4().to_string(),
                text: "/worktrees".into(),
                mode,
            })
            .unwrap();
            assert!(matches!(
                operation,
                Operation::Runtime(command) if matches!(*command, RuntimeCommand::ListResources)
            ));
        }
    }

    #[test]
    fn worktree_inventory_projects_to_existing_native_notice() {
        let task_id = crate::protocol::TaskId::new();
        let mut resource =
            crate::resources::ResourceRecord::allocating(crate::resources::WorktreeAllocation {
                host_id: "worker-a".into(),
                task_id: task_id.clone(),
                allocation_id: uuid::Uuid::new_v4(),
                repository: "/workspace/project".into(),
                branch: "task/review".into(),
            });
        resource.state = crate::resources::ResourceState::Held {
            identity: Some(crate::resources::NativeWorktreeIdentity {
                primary: "/workspace/project".into(),
                top: "/workspace/project-review".into(),
                common_dir: "/workspace/project/.git".into(),
                git_dir: "/workspace/project/.git/worktrees/review".into(),
                branch: "task/review".into(),
                head: "fixture-head".into(),
            }),
            reason: "Task is still open".into(),
        };
        let Some(crate::native::NativeEvent::Notice { text, .. }) =
            crate::native::project(&crate::protocol::RuntimeEventKind::Resources {
                resources: vec![resource],
            })
        else {
            panic!("Native clients must receive the existing inventory");
        };
        let task_label = task_id.to_string();
        for expected in [
            "/workspace/project-review",
            "task/review",
            "worker-a",
            "held",
            "Task is still open",
            task_label.as_str(),
        ] {
            assert!(text.contains(expected), "Missing {expected}: {text}");
        }
        assert!(matches!(
            crate::native::project(&crate::protocol::RuntimeEventKind::Resources {
                resources: vec![],
            }),
            Some(crate::native::NativeEvent::Notice { text, .. }) if text == "No Beep Boop-owned worktrees."
        ));
    }

    #[test]
    fn native_input_receipts_preserve_legacy_acknowledgements_and_typed_processing_state() {
        use crate::native::{NativeEvent, project};
        use crate::protocol::{InputBlockReason, InputWorkState, RuntimeEventKind};
        let legacy: RuntimeEventKind =
            serde_json::from_str(r#"{"type":"input_accepted","input_id":"saved"}"#).unwrap();
        assert!(matches!(
            project(&legacy),
            Some(NativeEvent::Accepted { work: None, .. })
        ));
        for work in [
            InputWorkState::Blocked {
                reason: InputBlockReason::RestartLimit,
            },
            InputWorkState::Completed {
                answer_entry_id: "answer".into(),
            },
        ] {
            let native = project(&RuntimeEventKind::InputAccepted {
                input_id: "saved".into(),
                work: Some(work.clone()),
            })
            .unwrap();
            let bytes = serde_json::to_vec(&native).unwrap();
            let decoded: NativeEvent = serde_json::from_slice(&bytes).unwrap();
            assert!(
                matches!(decoded, NativeEvent::Accepted { work: Some(saved), .. } if saved == work)
            );
        }
    }

    fn goal_submit(input_id: &str, text: &str) -> Operation {
        prepare(NativeRequest::Submit {
            origin: None,
            attachments: None,
            reply_to: None,
            input_id: input_id.into(),
            text: text.into(),
            mode: InputMode::FollowUp,
        })
        .unwrap()
    }

    #[test]
    fn native_goal_reuses_input_id_and_targets_main() {
        use crate::protocol::{GoalAction, GoalTarget};
        let input_id = "7a0c2b9e-1d1f-4c3a-9a51-0f6a3d1c2b02";
        let request_id = || input_id.to_owned();
        for (text, expected) in [
            ("/goal", GoalAction::Show),
            (
                "/goal pause",
                GoalAction::Pause {
                    request_id: request_id(),
                },
            ),
            (
                "/goal resume",
                GoalAction::Resume {
                    request_id: request_id(),
                },
            ),
            (
                "/goal ship it",
                GoalAction::Set {
                    request_id: request_id(),
                    objective: "ship it".into(),
                },
            ),
        ] {
            for attempt in 0..2 {
                let Operation::Runtime(command) = goal_submit(input_id, text) else {
                    panic!("{text} must reach the runtime as a control");
                };
                let RuntimeCommand::Goal { target, action } = *command else {
                    panic!("{text} must be a goal control, never model input");
                };
                assert_eq!(target, GoalTarget::Main, "{text} {attempt}");
                assert_eq!(action, expected, "{text} {attempt}");
            }
        }
        let replayed = |input_id: &str| match goal_submit(input_id, "/goal resume") {
            Operation::Runtime(command) => match *command {
                RuntimeCommand::Goal {
                    action: GoalAction::Resume { request_id },
                    ..
                } => request_id,
                other => panic!("Unexpected goal request: {other:?}"),
            },
            Operation::Local(event) => panic!("Unexpected local reply: {event:?}"),
            Operation::Service(service) => panic!("Unexpected service request: {service:?}"),
        };
        assert_eq!(
            replayed("7A0C2B9E-1D1F-4C3A-9A51-0F6A3D1C2B02"),
            input_id,
            "A phone's uppercase input ID names the same request on every replay"
        );
        assert!(
            crate::native::commands()
                .iter()
                .any(|command| command.usage == "/goal [OBJECTIVE | pause | resume]")
        );
    }

    #[test]
    fn native_goal_refuses_attachments() {
        let operation = prepare(NativeRequest::Submit {
            origin: None,
            attachments: Some(vec![crate::attachments::AttachmentRef {
                id: uuid::Uuid::new_v4().to_string(),
                name: "notes.png".into(),
                media_type: "image/png".into(),
                size_bytes: 0,
                sha256: "0".repeat(64),
            }]),
            input_id: uuid::Uuid::new_v4().to_string(),
            text: "/goal ship it".into(),
            mode: InputMode::FollowUp,
            reply_to: None,
        })
        .unwrap();
        assert!(matches!(
            operation,
            Operation::Local(NativeEvent::Rejected { .. })
        ));
    }

    #[test]
    fn native_goal_status_projects_to_notice() {
        let event: RuntimeEventKind = serde_json::from_value(serde_json::json!({
            "type": "goal",
            "status": { "conversation_id": "root", "goal": {
                "goal": { "id": "g1", "task_id": "5b2f7c1e-8d4a-4e6b-9c3f-1a2b3c4d5e6f",
                    "objective": "Write GOAL-DONE into the notes.",
                    "activation": { "number": 2, "request_id": "r2", "continuations": 0, "budget": 5, "check": null },
                    "state": { "state": "active" }, "last_rejection": null, "created_at": 0, "updated_at": 0 },
                "task": { "id": "5b2f7c1e-8d4a-4e6b-9c3f-1a2b3c4d5e6f", "conversation_id": "17",
                    "title": "Notes", "outcome": "Notes exist", "summary": "", "model": null,
                    "state": { "state": "open" }, "worker": { "state": "unassigned" },
                    "sources": [], "pending": [], "agents": [], "updated_at": 0 } } },
        }))
        .unwrap();
        let RuntimeEventKind::Goal { status } = &event else {
            panic!("The fixture must decode as a goal event");
        };
        let notice = crate::native::project(&event).unwrap();
        let wire: serde_json::Value = serde_json::to_value(&notice).unwrap();
        assert_eq!(wire["type"], "notice");
        let text = wire["text"].as_str().unwrap();
        assert_eq!(
            text,
            crate::goal_view::format(status),
            "The phone shows the TUI text"
        );
        assert!(
            text.contains("Goal: Write GOAL-DONE into the notes."),
            "{text}"
        );
        assert!(
            text.contains("State: active · activation 2 · continuations 0 of 5"),
            "{text}"
        );
        assert!(matches!(
            notice,
            NativeEvent::Notice {
                settings: None,
                job_status: None,
                ..
            }
        ));
    }

    #[test]
    fn native_controls_use_the_real_chat_parser_and_never_become_model_input() {
        for text in [
            "/help",
            "/status",
            "/machines",
            "/model",
            "/fast",
            "/reasoning",
            "/history",
            "/feedback fix this",
            "/exit",
            "/quit",
        ] {
            let operation = prepare(NativeRequest::Submit {
                origin: None,
                attachments: None,
                reply_to: None,
                input_id: uuid::Uuid::new_v4().to_string(),
                text: text.into(),
                mode: InputMode::Steer,
            })
            .unwrap();
            assert!(
                !matches!(
                    operation,
                    Operation::Runtime(command) if matches!(*command, RuntimeCommand::MainInput { .. })
                ),
                "{text}"
            );
        }
        assert!(
            prepare(NativeRequest::Submit {
                origin: None,
                attachments: None,
                reply_to: None,
                input_id: "invalid".into(),
                text: "Hi".into(),
                mode: InputMode::Steer
            })
            .is_err()
        );
    }

    #[test]
    fn dreams_and_service_status_prepare_as_service_boundary_operations() {
        let valid_run = "0123456789abcdef";
        let valid_digest = crate::dreams::ContentDigest::of(b"ok").as_str().to_owned();
        assert!(matches!(
            prepare(NativeRequest::DreamsList).unwrap(),
            Operation::Service(ServiceRequest::DreamsList)
        ));
        assert!(matches!(
            prepare(NativeRequest::DreamsShow {
                run: valid_run.into(),
            })
            .unwrap(),
            Operation::Service(ServiceRequest::DreamsShow { .. })
        ));
        assert!(matches!(
            prepare(NativeRequest::DreamsApply {
                run: valid_run.into(),
                approve: valid_digest,
            })
            .unwrap(),
            Operation::Service(ServiceRequest::DreamsApply { .. })
        ));
        assert!(matches!(
            prepare(NativeRequest::ServiceStatus).unwrap(),
            Operation::Service(ServiceRequest::ServiceStatus)
        ));
        assert!(
            prepare(NativeRequest::DreamsShow {
                run: "not-a-run-id".into(),
            })
            .is_err()
        );
        assert!(
            prepare(NativeRequest::DreamsApply {
                run: valid_run.into(),
                approve: "not-a-digest".into(),
            })
            .is_err()
        );
        let main_ready = RuntimeEventKind::MainReady {
            conversation_id: "1".into(),
            cwd: "/".into(),
            model: crate::models::ModelSelection::default(),
            input_origins: Some(true),
            accepted_input_origins: None,
            conversation_settings: Some(true),
            active_work: Some(true),
            sidechats: Some(true),
        };
        let Some(NativeEvent::Ready { dreams, .. }) = crate::native::project(&main_ready) else {
            panic!("Expected NativeEvent::Ready");
        };
        assert_eq!(
            dreams, None,
            "Pi MainReady never advertises Dreams directly"
        );
    }

    #[test]
    fn sidechat_requests_validate_and_project_typed_events() {
        let list = prepare(NativeRequest::ListSidechats {
            include_archived: true,
        })
        .unwrap();
        assert!(matches!(
            list,
            Operation::Runtime(cmd) if matches!(*cmd, RuntimeCommand::ListSidechats { include_archived: true })
        ));

        let created = prepare(NativeRequest::CreateSidechat {
            title: "Morning Brief".into(),
            slug: Some("morning-brief".into()),
            charter: Some("Daily briefings.".into()),
            isolated: Some(false),
            notifications: Some(crate::protocol::SidechatNotificationPreference::On),
            seed: None,
            handoff: Some("Start from today.".into()),
        })
        .unwrap();
        assert!(matches!(
            created,
            Operation::Runtime(cmd) if matches!(*cmd, RuntimeCommand::CreateSidechat { .. })
        ));

        // Reject invalid/numeric slugs, control chars in titles, and conflicting charter + clear_charter.
        assert!(
            prepare(NativeRequest::CreateSidechat {
                title: "Bad".into(),
                slug: Some("BAD SLUG!".into()),
                charter: None,
                isolated: None,
                notifications: None,
                seed: None,
                handoff: None,
            })
            .is_err()
        );
        assert!(
            prepare(NativeRequest::CreateSidechat {
                title: "Numeric slug".into(),
                slug: Some("42".into()),
                charter: None,
                isolated: None,
                notifications: None,
                seed: None,
                handoff: None,
            })
            .is_err()
        );
        assert!(
            prepare(NativeRequest::CreateSidechat {
                title: "Underscore slug".into(),
                slug: Some("Morning_Brief".into()),
                charter: None,
                isolated: None,
                notifications: None,
                seed: None,
                handoff: None,
            })
            .is_ok()
        );
        assert!(
            prepare(NativeRequest::CreateSidechat {
                title: "Bad\nTitle".into(),
                slug: None,
                charter: None,
                isolated: None,
                notifications: None,
                seed: None,
                handoff: None,
            })
            .is_err()
        );
        assert!(
            prepare(NativeRequest::UpdateSidechat {
                conversation_id: "7".into(),
                title: None,
                slug: None,
                pinned: None,
                archived: None,
                charter: Some("New charter".into()),
                clear_charter: Some(true),
                isolated: None,
                notifications: None,
            })
            .is_err()
        );

        let interrupt = prepare(NativeRequest::SidechatInterrupt {
            conversation_id: "7".into(),
        })
        .unwrap();
        assert!(matches!(
            interrupt,
            Operation::Runtime(cmd) if matches!(&*cmd, RuntimeCommand::ConversationInterrupt { conversation_id } if conversation_id == "7")
        ));

        let summary = crate::protocol::SidechatSummary {
            conversation_id: "7".into(),
            slug: "morning-brief".into(),
            title: "Morning Brief".into(),
            pinned: true,
            archived_at: None,
            charter: Some("Daily briefings.".into()),
            isolated: false,
            notifications: crate::protocol::SidechatNotificationPreference::On,
            seed: None,
            created_at: 100,
            updated_at: 200,
        };
        let ready = crate::native::project(&RuntimeEventKind::SidechatReady {
            input_origins: Some(true),
            accepted_input_origins: None,
            conversation_settings: Some(true),
            conversation_id: "7".into(),
            sidechat: summary.clone(),
            model: crate::models::ModelSelection {
                provider: crate::models::ModelProvider::OpenAi,
                model_id: "fixture".into(),
                reasoning: None,
                fast: false,
            },
            cwd: String::new(),
            working: true,
        });
        assert!(matches!(
            ready,
            Some(NativeEvent::Ready {
                sidechats: Some(true),
                sidechat: Some(projected),
                working: Some(true),
                conversation_id,
                ..
            }) if *projected == summary && conversation_id == "7"
        ));
    }
}

#[cfg(test)]
mod error_tests;
