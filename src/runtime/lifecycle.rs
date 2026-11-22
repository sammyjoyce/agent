//! Request ownership and connection controls, independent of wire transport.

use crate::protocol::{HostCommand, RuntimeCommand};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum View {
    Main,
    MainObserver,
    Conversation,
    TaskGraph,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestLifecycle {
    Once,
    Login,
    Chat,
    Worker { interactive: bool },
    ClientHistory,
    View(View),
    Background,
    Coordinator,
    Detached,
}

impl RequestLifecycle {
    pub fn for_command(command: &RuntimeCommand) -> Option<Self> {
        Some(match command {
            RuntimeCommand::Login => Self::Login,
            RuntimeCommand::Chat { .. } => Self::Chat,
            RuntimeCommand::RunTask { interactive, .. } => Self::Worker {
                interactive: *interactive == Some(true),
            },
            RuntimeCommand::AttachMain => Self::View(View::Main),
            RuntimeCommand::ObserveMain { .. } => Self::View(View::MainObserver),
            RuntimeCommand::AttachConversation { .. } => Self::View(View::Conversation),
            RuntimeCommand::WatchTaskGraph => Self::View(View::TaskGraph),
            RuntimeCommand::RunBackground { .. } => Self::Background,
            RuntimeCommand::ImportChatGpt { .. } => Self::ClientHistory,
            RuntimeCommand::ConfigureCoordinator { .. }
            | RuntimeCommand::RegisterNode { .. }
            | RuntimeCommand::SetConnectedNodes { .. } => Self::Coordinator,
            RuntimeCommand::OAuthCallback { .. }
            | RuntimeCommand::WorkerInput { .. }
            | RuntimeCommand::SubmitInput { .. }
            | RuntimeCommand::DetachWorker
            | RuntimeCommand::DetachMain
            | RuntimeCommand::DetachConversation
            | RuntimeCommand::DetachTaskGraph
            | RuntimeCommand::Interrupt
            | RuntimeCommand::HostReply { .. }
            | RuntimeCommand::Watch
            | RuntimeCommand::ConnectWorker { .. }
            | RuntimeCommand::Native { .. } => return None,
            RuntimeCommand::ConversationUsage { .. }
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
            | RuntimeCommand::Logout
            | RuntimeCommand::SearchTasks { .. }
            | RuntimeCommand::ListTasks
            | RuntimeCommand::ReadTaskGraph
            | RuntimeCommand::ListConversations { .. }
            | RuntimeCommand::ConversationInput { .. }
            | RuntimeCommand::ConversationInterrupt { .. }
            | RuntimeCommand::ListResources
            | RuntimeCommand::CollectResources { .. }
            | RuntimeCommand::ReadTask { .. }
            | RuntimeCommand::ReadHistory { .. }
            | RuntimeCommand::ReadToolDetails { .. }
            | RuntimeCommand::Feedback { .. }
            | RuntimeCommand::ReadFeedback { .. }
            | RuntimeCommand::ImportCodex { .. }
            | RuntimeCommand::ImportStatus
            | RuntimeCommand::RetryHistoryIndex
            | RuntimeCommand::TaskInput { .. }
            | RuntimeCommand::AnnotateTranscript { .. }
            | RuntimeCommand::Notifications { .. }
            | RuntimeCommand::SearchHistory { .. }
            | RuntimeCommand::ReadConversation { .. }
            | RuntimeCommand::OpenConversation { .. }
            | RuntimeCommand::RevokeAllocation { .. }
            | RuntimeCommand::TransferTask { .. }
            | RuntimeCommand::Goal { .. } => Self::Once,
        })
    }

    pub fn allows(self, command: &RuntimeCommand) -> bool {
        match command {
            RuntimeCommand::OAuthCallback { .. } => self == Self::Login,
            RuntimeCommand::Interrupt => matches!(
                self,
                Self::Chat | Self::Worker { .. } | Self::View(View::Main)
            ),
            RuntimeCommand::SubmitInput { .. } => self.accepts_input(),
            RuntimeCommand::WorkerInput { .. } | RuntimeCommand::DetachWorker => {
                self == Self::Worker { interactive: true }
            }
            _ => false,
        }
    }

    pub fn is_worker(self) -> bool {
        matches!(self, Self::Worker { .. })
    }

    pub fn accepts_input(self) -> bool {
        matches!(
            self,
            Self::Chat | Self::Worker { interactive: true } | Self::View(View::Main)
        )
    }

    pub fn input_ready(self, ready: bool) -> bool {
        self.accepts_input() && (self == Self::Chat || ready)
    }

    pub fn is_view(self) -> bool {
        matches!(self, Self::View(_))
    }

    pub fn is_service_owned(self) -> bool {
        matches!(self, Self::Background | Self::Coordinator)
    }

    pub fn owns_host_effects(self) -> bool {
        !self.is_worker()
    }

    pub fn serves_client_history(self, command: &HostCommand) -> bool {
        self == Self::ClientHistory && matches!(command, HostCommand::History { .. })
    }

    /// Release a connection's attachment once, without revoking admitted work.
    pub fn detach(&mut self) -> Option<RuntimeCommand> {
        std::mem::replace(self, Self::Detached).disconnect_command()
    }

    pub fn disconnect_command(self) -> Option<RuntimeCommand> {
        match self {
            Self::Worker { interactive: true } => Some(RuntimeCommand::DetachWorker),
            Self::View(View::Main | View::MainObserver) => Some(RuntimeCommand::DetachMain),
            Self::View(View::Conversation) => Some(RuntimeCommand::DetachConversation),
            Self::View(View::TaskGraph) => Some(RuntimeCommand::DetachTaskGraph),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::RequestLifecycle;
    use crate::{embeddings::EmbeddingPurpose, history::HistoryRequest, protocol::HostCommand};

    #[test]
    fn only_an_export_import_reads_history_from_its_client() {
        let history = HostCommand::History {
            request: HistoryRequest::List {
                archived: false,
                cursor: None,
            },
        };
        let exec = HostCommand::Exec {
            program: "true".into(),
            args: Vec::new(),
            cwd: "/".into(),
            timeout_seconds: 1,
            sender_conversation_id: None,
        };
        let others = [
            exec.clone(),
            HostCommand::ReadFile {
                path: "/invented".into(),
                offset: 0,
                limit: 1,
                image: None,
            },
            HostCommand::WriteFile {
                path: "/invented".into(),
                content: String::new(),
            },
            HostCommand::OnNode {
                host_id: "invented-host".into(),
                command: Box::new(history.clone()),
            },
            HostCommand::Embed {
                texts: vec!["Invented".into()],
                purpose: EmbeddingPurpose::Document,
            },
        ];
        let client = RequestLifecycle::ClientHistory;
        assert!(client.serves_client_history(&history) && client.owns_host_effects());
        for command in &others {
            assert!(!client.serves_client_history(command), "{command:?}");
        }
        for lifecycle in [
            RequestLifecycle::Once,
            RequestLifecycle::Worker { interactive: false },
            RequestLifecycle::Worker { interactive: true },
            RequestLifecycle::Background,
        ] {
            assert!(!lifecycle.serves_client_history(&history), "{lifecycle:?}");
        }
    }
}
