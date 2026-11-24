//! A terminal view never claims the Rex worker's execution or effects.

use crate::{ClientContext, UiSession, ViewError, connection, exchange, write_command};
use agent_cli::{
    config::ClientConfig,
    protocol::{ErrorCode, RuntimeCommand, RuntimeEventKind, SavedConversation, SidechatSummary},
    rex::RexClient,
    runtime::{FrameReader, decode_coordinator_event},
    tui::{HistoryReplay, ObservationState, TuiInfo},
};
use anyhow::{Context, Result};
use std::{path::PathBuf, sync::Arc, time::Duration};
use tokio::{
    io::BufReader,
    sync::{mpsc, watch},
    task::JoinHandle,
};

struct Target {
    config: ClientConfig,
    coordinator: Option<String>,
    script: PathBuf,
    directory: PathBuf,
    rex: RexClient,
    terminal: RexClient,
    conversation_id: String,
}
impl Target {
    fn client(&self) -> ClientContext<'_> {
        ClientContext {
            config: &self.config,
            coordinator: self.coordinator.as_deref(),
            script: &self.script,
            directory: &self.directory,
            rex: &self.rex,
            terminal: &self.terminal,
        }
    }
}

pub(crate) struct View {
    pub(crate) token: uuid::Uuid,
    pub(crate) ready: tokio::sync::watch::Receiver<Observation>,
    target: Arc<Target>,
    input_ids: watch::Sender<Vec<String>>,
    pub(crate) retry: mpsc::Sender<AttachmentId>,
    task: JoinHandle<()>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct AttachmentId(uuid::Uuid);

#[derive(Clone, Copy)]
pub(crate) enum Observation {
    Connecting(AttachmentId),
    Connected(AttachmentId),
    Reconnecting(AttachmentId),
    Disconnected,
}
impl Observation {
    pub(crate) fn attachment(self) -> Option<AttachmentId> {
        match self {
            Self::Connecting(id) | Self::Connected(id) | Self::Reconnecting(id) => Some(id),
            Self::Disconnected => None,
        }
    }
    pub(crate) fn state(self) -> ObservationState {
        match self {
            Self::Connecting(_) => ObservationState::Connecting,
            Self::Connected(_) => ObservationState::Connected,
            Self::Reconnecting(_) => ObservationState::Reconnecting,
            Self::Disconnected => ObservationState::Disconnected,
        }
    }
}
impl Drop for View {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl View {
    pub(crate) fn reconcile(&self, ids: Vec<String>) {
        self.input_ids.send_replace(ids);
    }
    pub(crate) fn replay(&self, replay: HistoryReplay) -> crate::chat_history::Job {
        crate::chat_history::Job::start(
            self.target.client(),
            self.target.conversation_id.clone(),
            crate::chat_history::Start::Recent,
            replay,
        )
    }
    pub(crate) fn state(&self) -> ObservationState {
        observation(&self.ready)
    }
    pub(crate) async fn stop(mut self) {
        self.task.abort();
        let _ = (&mut self.task).await;
    }
}

pub(crate) fn observation(ready: &tokio::sync::watch::Receiver<Observation>) -> ObservationState {
    if ready.has_changed().is_err() {
        ObservationState::Disconnected
    } else {
        ready.borrow().state()
    }
}

pub(crate) async fn choices(
    client: ClientContext<'_>,
    query: String,
) -> Result<Vec<SavedConversation>> {
    let mut cursor = None;
    let mut items = Vec::new();
    // The picker is a bounded recent list. Exact/query lookups are filtered by
    // the native catalog before pagination, including original imported IDs.
    for _ in 0..10 {
        let page = exchange(
            client,
            RuntimeCommand::ListConversations {
                query: query.clone(),
                cursor,
                limit: 100,
            },
        )
        .await?
        .into_iter()
        .find_map(|event| match event {
            RuntimeEventKind::Conversations { items, next_cursor } => Some((items, next_cursor)),
            _ => None,
        })
        .context("The coordinator returned no saved conversations")?;
        let found = exact(&page.0, &query).is_some();
        items.extend(page.0);
        cursor = page.1;
        if found || cursor.is_none() {
            break;
        }
    }
    Ok(items)
}

pub(crate) fn exact<'a>(
    items: &'a [SavedConversation],
    query: &str,
) -> Option<&'a SavedConversation> {
    items
        .iter()
        .find(|item| item.conversation_id == query)
        .or_else(|| {
            items
                .iter()
                .find(|item| item.agent_id.as_deref() == Some(query))
        })
        .or_else(|| {
            items
                .iter()
                .find(|item| item.source_thread_id.as_deref() == Some(query))
        })
        .or_else(|| {
            items.iter().find(|item| {
                item.agent_id.is_none()
                    && item
                        .task_id
                        .as_ref()
                        .is_some_and(|id| id.to_string() == query)
            })
        })
}

async fn save_draft(ui: &mut UiSession) -> Result<()> {
    if let Some(current) = &ui.conversation_id {
        ui.drafts
            .insert(current.clone(), ui.handle.composer_draft().await?);
    }
    Ok(())
}

pub(crate) async fn resume(
    client: ClientContext<'_>,
    ui: &mut UiSession,
    query: String,
) -> Result<bool> {
    save_draft(ui).await?;
    let items = choices(client, query.clone()).await?;
    let selected = if !query.is_empty() {
        exact(&items, &query).map(|item| item.conversation_id.clone())
    } else {
        None
    };
    let selected = match selected {
        Some(id) => Some(id),
        None => ui.handle.choose_conversation(items.clone(), query).await?,
    };
    let Some(id) = selected else {
        return Ok(false);
    };
    let item = items
        .into_iter()
        .find(|item| item.conversation_id == id)
        .context("The selected conversation is unavailable")?;
    open(client, ui, item).await?;
    Ok(true)
}

pub(crate) fn sidechat_to_saved(summary: &SidechatSummary) -> SavedConversation {
    SavedConversation {
        conversation_id: summary.conversation_id.clone(),
        title: format!("{} ({})", summary.title, summary.slug),
        updated_at: Some(summary.updated_at),
        source_thread_id: None,
        task_id: None,
        agent_id: None,
        host: None,
    }
}

pub(crate) async fn list_sidechats(
    client: ClientContext<'_>,
    include_archived: bool,
) -> Result<Vec<SidechatSummary>> {
    exchange(client, RuntimeCommand::ListSidechats { include_archived })
        .await?
        .into_iter()
        .find_map(|event| match event {
            RuntimeEventKind::Sidechats { items } => Some(items),
            _ => None,
        })
        .context("The coordinator returned no side chat list")
}

pub(crate) async fn resolve_sidechat(
    client: ClientContext<'_>,
    slug_or_id: &str,
) -> Result<SidechatSummary> {
    let wanted = slug_or_id.trim();
    anyhow::ensure!(
        !wanted.is_empty(),
        "Choose a side chat slug or conversation ID"
    );
    let items = list_sidechats(client, true).await?;
    items
        .iter()
        .find(|item| item.conversation_id == wanted)
        .or_else(|| {
            items
                .iter()
                .find(|item| item.slug.eq_ignore_ascii_case(wanted))
        })
        .cloned()
        .with_context(|| format!("Unknown side chat: {wanted}"))
}

pub(crate) async fn open_sidechat(
    client: ClientContext<'_>,
    ui: &mut UiSession,
    target: Option<String>,
) -> Result<bool> {
    save_draft(ui).await?;
    let chosen = if let Some(target) = target {
        resolve_sidechat(client, &target).await?
    } else {
        let items = list_sidechats(client, false).await?;
        if items.is_empty() {
            ui.handle.notice(
                "No standing side chats yet. Create one with `beep-boop sidechats create`.".into(),
            )?;
            return Ok(false);
        }
        let choices: Vec<SavedConversation> = items.iter().map(sidechat_to_saved).collect();
        let Some(selected_id) = ui.handle.choose_sidechat(choices, String::new()).await? else {
            return Ok(false);
        };
        items
            .into_iter()
            .find(|item| item.conversation_id == selected_id)
            .context("The selected side chat is unavailable")?
    };
    open(client, ui, sidechat_to_saved(&chosen)).await?;
    Ok(true)
}

pub(crate) async fn open_main(client: ClientContext<'_>, ui: &mut UiSession) -> Result<()> {
    save_draft(ui).await?;
    open(
        client,
        ui,
        SavedConversation {
            conversation_id: "1".into(),
            title: "Main agent".into(),
            updated_at: None,
            source_thread_id: None,
            task_id: None,
            agent_id: None,
            host: None,
        },
    )
    .await
}

pub(crate) async fn open(
    client: ClientContext<'_>,
    ui: &mut UiSession,
    item: SavedConversation,
) -> Result<()> {
    if ui
        .selected
        .as_ref()
        .is_some_and(|current| current.conversation_id == item.conversation_id)
        && ui
            .view
            .as_ref()
            .is_some_and(|view| view.state() != ObservationState::Disconnected)
    {
        return Ok(());
    }
    let initial = ui.view.is_none() && ui.conversation_id.is_none() && ui.initial_replay.is_none();
    if let Some(current) = ui.conversation_id.clone() {
        ui.cancel_waiting(&current)?;
    }
    if let Some(view) = ui.view.take() {
        view.stop().await;
    }
    if let Some(history) = ui.history.take() {
        history.cancel().await;
    }
    // Cancel local reads/settings before their result can alter another view.
    ui.controls.abort_all();
    while ui.controls.join_next().await.is_some() {}
    let previous = ui.handle.info().await?;
    if !initial {
        ui.handle.reset_conversation(TuiInfo {
            title: item.title.clone(),
            model: None,
            ..previous
        })?;
    }
    ui.handle.observation(ObservationState::Connecting)?;
    ui.observer_ready = false;
    if let Some(draft) = ui
        .drafts
        .get(&item.conversation_id)
        .filter(|draft| !draft.is_empty())
    {
        ui.handle.set_composer(draft.clone())?;
    }
    let mut input_ids = Vec::new();
    for input in &ui.pending_admissions {
        if input.conversation_id == item.conversation_id && input.retained()? {
            input_ids.push(input.id.clone());
            ui.handle
                .pending_composer(input.id.clone(), &input.input()?, input.mode)?;
            if input.stage()? == crate::chat_admission::Stage::Accepted {
                ui.handle.event(RuntimeEventKind::InputAccepted {
                    input_id: input.id.clone(),
                    work: None,
                })?;
            } else if input.stage()? == crate::chat_admission::Stage::Uncertain {
                ui.handle.input_uncertain(input.id.clone())?;
            }
        }
    }
    let replay = ui.handle.begin_history_replay()?;
    let (ready, attached) = tokio::sync::oneshot::channel();
    let attachment = AttachmentId(uuid::Uuid::new_v4());
    let (connected, readiness) = tokio::sync::watch::channel(Observation::Connecting(attachment));
    ui.history = Some(crate::chat_history::Job::start(
        client,
        item.conversation_id.clone(),
        crate::chat_history::Start::AfterAttach(attached),
        replay,
    ));
    ui.conversation_id = Some(item.conversation_id.clone());
    ui.selected = Some(item.clone());
    let token = uuid::Uuid::new_v4();
    let sender = ui.view_sender.clone();
    let target = Arc::new(Target {
        config: client.config.clone(),
        coordinator: client.coordinator.map(str::to_owned),
        script: client.script.to_owned(),
        directory: client.directory.to_owned(),
        rex: client.rex.clone(),
        terminal: client.terminal.clone(),
        conversation_id: item.conversation_id.clone(),
    });
    let observer = target.clone();
    let (input_ids, pending_inputs) = watch::channel(input_ids);
    let (retry, mut retries) = mpsc::channel(1);
    let handle = ui.handle.clone();
    let task = tokio::spawn(async move {
        let mut ready = Some(ready);
        let mut delay = Duration::ZERO;
        let mut attachment = attachment;
        loop {
            while retries.try_recv().is_ok() {}
            let result: std::result::Result<(), ViewError> = async {
            let client = observer.client();
            let mut wire = connection(client, false)
                .await
                .map_err(ViewError::Coordinator)?;
            let input_ids = pending_inputs.borrow().clone();
            write_command(
                &mut *wire.writer,
                &RuntimeCommand::AttachConversation {
                    conversation_id: item.conversation_id.clone(),
                    input_ids,
                },
            )
            .await
            .map_err(ViewError::read)?;
            let mut reader = FrameReader::new(BufReader::new(wire.reader));
            loop {
                let frame = tokio::select! {
                    frame = reader.next_frame() => frame.map_err(ViewError::read)?,
                    Some(failed) = retries.recv() => {
                        // An old control socket can fail after a replacement
                        // observer starts. Only retire the attachment it used.
                        if failed == attachment {
                            return Err(ViewError::Coordinator(anyhow::anyhow!("The input connection needs to reattach")));
                        }
                        continue;
                    },
                };
                let Some(frame) = frame else { return Err(ViewError::Coordinator(anyhow::anyhow!("The conversation observation connection closed"))); };
                let event = decode_coordinator_event(&frame).map_err(ViewError::Internal)?;
                if matches!(event, RuntimeEventKind::HostCall { .. }) {
                    return Err(ViewError::Internal(anyhow::anyhow!(
                        "An observing terminal cannot own execution effects"
                    )));
                }
                if matches!(event, RuntimeEventKind::ConversationReady { .. }) {
                    if let Some(ready) = ready.take() { let _ = ready.send(()); }
                    delay = Duration::ZERO;
                    let _ = connected.send(Observation::Connected(attachment));
                    let _ = handle.observation(ObservationState::Connected);
                }
                if matches!(event, RuntimeEventKind::Done | RuntimeEventKind::Failure { code: ErrorCode::CoordinatorUnavailable | ErrorCode::Internal, .. }) {
                    return Err(ViewError::Coordinator(anyhow::anyhow!("The coordinator observation stopped")));
                }
                let failed = matches!(event, RuntimeEventKind::Failure { .. });
                if sender.send((token, event)).is_err() {
                    return Ok(());
                }
                if failed { return Ok(()); }
            }
        }
        .await;
            match result {
                Err(ViewError::Coordinator(_)) => {
                    attachment = AttachmentId(uuid::Uuid::new_v4());
                    let _ = connected.send(Observation::Reconnecting(attachment));
                    if handle.observation(ObservationState::Reconnecting).is_err() {
                        return;
                    }
                    tokio::time::sleep(delay).await;
                    delay = if delay.is_zero() {
                        Duration::from_secs(1)
                    } else {
                        (delay * 2).min(Duration::from_secs(8))
                    };
                }
                result => {
                    if let Err(error) = result {
                        let _ = sender.send((token, error.event(&item.conversation_id)));
                    }
                    break;
                }
            }
        }
        let _ = connected.send(Observation::Disconnected);
        let _ = handle.observation(ObservationState::Disconnected);
        let _ = sender.send((token, RuntimeEventKind::Done));
    });
    ui.view = Some(View {
        token,
        ready: readiness,
        target,
        input_ids,
        retry,
        task,
    });
    Ok(())
}

/// Control admission is streamed so a long-running turn never delays its receipt.
pub(crate) async fn control(
    client: ClientContext<'_>,
    command: RuntimeCommand,
    token: uuid::Uuid,
    sender: tokio::sync::mpsc::UnboundedSender<(uuid::Uuid, RuntimeEventKind)>,
    admission: &crate::chat_admission::Admission,
    ready: &tokio::sync::watch::Receiver<Observation>,
    attachment: AttachmentId,
) -> std::result::Result<(), ViewError> {
    let mut wire = connection(client, false)
        .await
        .map_err(ViewError::Coordinator)?;
    if !matches!(*ready.borrow(), Observation::Connected(current) if current == attachment) {
        return Err(ViewError::Coordinator(anyhow::anyhow!(
            "The conversation view is disconnected; this input remains unsent."
        )));
    }
    if !admission.sending().map_err(ViewError::Internal)? {
        return Ok(());
    }
    write_command(&mut *wire.writer, &command)
        .await
        .map_err(ViewError::read)?;
    let mut reader = FrameReader::new(BufReader::new(wire.reader));
    while let Some(frame) = reader.next_frame().await.map_err(ViewError::read)? {
        let event = decode_coordinator_event(&frame).map_err(ViewError::Internal)?;
        match event {
            RuntimeEventKind::Done => return Ok(()),
            RuntimeEventKind::HostCall { .. } => {
                return Err(ViewError::Internal(anyhow::anyhow!(
                    "The coordinator must own admitted execution effects"
                )));
            }
            RuntimeEventKind::InputAccepted { .. }
            | RuntimeEventKind::InputPlaced { .. }
            | RuntimeEventKind::InputRejected { .. }
            | RuntimeEventKind::Failure { .. } => {
                let _ = sender.send((token, event));
            }
            _ => {}
        }
    }
    Err(ViewError::Coordinator(anyhow::anyhow!(
        "Input connection ended; saved input may still be running"
    )))
}
