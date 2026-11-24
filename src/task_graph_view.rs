use crate::protocol::{
    TaskGraphActor, TaskGraphBlocked, TaskGraphConversation, TaskGraphJoinPolicy, TaskGraphKind,
    TaskGraphNode, TaskGraphOutcome, TaskGraphSnapshot, TaskGraphState,
};

pub(crate) fn label(text: &str) -> String {
    text.chars()
        .filter(|character| !crate::sidechats::is_unsafe_terminal_format(*character))
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect()
}

fn state(state: &TaskGraphState) -> String {
    match state {
        TaskGraphState::Pending { .. } => "pending".into(),
        TaskGraphState::Running { .. } => "running".into(),
        TaskGraphState::Waiting { on, policy, .. } => format!(
            "waiting on {} ({})",
            on.iter()
                .map(|id| format!("#{id}"))
                .collect::<Vec<_>>()
                .join(", "),
            match policy {
                TaskGraphJoinPolicy::AllSettled => "all settled",
                TaskGraphJoinPolicy::FailFast => "fail fast",
            }
        ),
        TaskGraphState::Sleeping { until, .. } => {
            match chrono::DateTime::from_timestamp_millis(*until as i64) {
                Some(wake) => format!("sleeping until {}", wake.format("%Y-%m-%d %H:%M:%S UTC")),
                None => "sleeping".into(),
            }
        }
        TaskGraphState::Completing { outcome } => format!(
            "completing ({})",
            match outcome {
                TaskGraphOutcome::Completed => "completed",
                TaskGraphOutcome::Failed => "failed",
                TaskGraphOutcome::Aborted => "aborted",
                TaskGraphOutcome::Orphaned => "orphaned",
                TaskGraphOutcome::Faulted => "faulted",
            }
        ),
    }
}

fn node_line(node: &TaskGraphNode) -> String {
    let kind = match &node.kind {
        TaskGraphKind::Generation => "generation".into(),
        TaskGraphKind::Tool { name: Some(name) } => format!("tool {}", label(name)),
        TaskGraphKind::Tool { name: None } => "tool".into(),
        TaskGraphKind::Other { name } => label(name),
    };
    let mut line = format!("#{} {kind}  {}", node.id, state(&node.state));
    if let Some(blocked) = node.blocked {
        line.push_str(match blocked {
            TaskGraphBlocked::MissingTask => " · blocked: no installed definition",
            TaskGraphBlocked::TaskTooOld => " · blocked: saved by an older version",
            TaskGraphBlocked::MigrationFailed => " · blocked: migration failed",
            TaskGraphBlocked::RestartLimit => " · blocked: restart limit reached",
        });
    }
    if node.abort_requested {
        line.push_str(" · abort requested");
    }
    if node.background {
        line.push_str(" · background");
    }
    if !node.conversations.is_empty() {
        line.push_str(&format!(
            " · owns conversation {}",
            node.conversations.join(", ")
        ));
    }
    line
}

fn owner_is_listed(graph: &TaskGraphSnapshot, node: &TaskGraphNode) -> bool {
    node.owner
        .is_some_and(|owner| graph.nodes.iter().any(|other| other.id == owner))
}

fn work(
    graph: &TaskGraphSnapshot,
    conversation_id: &str,
    owner: Option<u64>,
    indent: usize,
    lines: &mut Vec<String>,
) {
    for node in graph.nodes.iter().filter(|node| {
        node.conversation_id == conversation_id
            && match owner {
                Some(owner) => node.owner == Some(owner),
                None => !owner_is_listed(graph, node),
            }
    }) {
        lines.push(format!("{}{}", "  ".repeat(indent), node_line(node)));
        work(graph, conversation_id, Some(node.id), indent + 1, lines);
    }
}

fn actor(
    graph: &TaskGraphSnapshot,
    conversation: &TaskGraphConversation,
    indent: usize,
    lines: &mut Vec<String>,
) {
    let heading = if let Some(sidechat) = &conversation.sidechat {
        format!(
            "Sidechat {}  {}",
            label(&sidechat.slug),
            label(&sidechat.title)
        )
    } else {
        match &conversation.actor {
            TaskGraphActor::Main => "Main agent".into(),
            TaskGraphActor::Task { task_id, title } => format!("Task {task_id}  {}", label(title)),
            TaskGraphActor::Agent {
                agent_id, title, ..
            } => format!("Agent {}  {}", label(agent_id), label(title)),
            TaskGraphActor::Other => format!("Conversation {}", conversation.conversation_id),
        }
    };
    lines.push(format!("{}{heading}", "  ".repeat(indent)));
    work(
        graph,
        &conversation.conversation_id,
        None,
        indent + 1,
        lines,
    );
    for agent in graph.conversations.iter().filter(|other| {
        matches!(&other.actor, TaskGraphActor::Agent { parent_conversation_id, .. }
            if *parent_conversation_id == conversation.conversation_id)
    }) {
        actor(graph, agent, indent + 1, lines);
    }
}

fn prints_under_its_task(graph: &TaskGraphSnapshot, conversation: &TaskGraphConversation) -> bool {
    matches!(&conversation.actor, TaskGraphActor::Agent { parent_conversation_id, .. }
        if graph.conversations.iter().any(|other| other.conversation_id == *parent_conversation_id))
}

pub fn format(graph: &TaskGraphSnapshot) -> String {
    if graph.nodes.is_empty() && graph.omitted == 0 {
        return "No live work.".into();
    }
    let mut actors = Vec::new();
    for conversation in graph
        .conversations
        .iter()
        .filter(|conversation| !prints_under_its_task(graph, conversation))
    {
        let mut lines = Vec::new();
        actor(graph, conversation, 0, &mut lines);
        actors.push(lines.join("\n"));
    }
    if graph.omitted > 0 {
        actors.push(format!("{} more live tasks not shown.", graph.omitted));
    }
    actors.join("\n\n")
}

#[cfg(test)]
mod tests {
    use crate::protocol::{RuntimeEventKind, TaskGraphSnapshot};

    fn graph(json: &str) -> TaskGraphSnapshot {
        match serde_json::from_str(json).unwrap() {
            RuntimeEventKind::TaskGraph { graph } => graph,
            other => panic!("expected a task graph event, got {other:?}"),
        }
    }

    #[test]
    fn live_work_prints_under_its_owner_and_agents_print_under_their_task() {
        let graph = graph(
            r#"{"type":"task_graph","graph":{"omitted":0,"nodes":[
            {"id":7,"kind":{"type":"other","name":"agent.background"},"conversation_id":"1","owner":null,"background":true,"abort_requested":false,
             "state":{"status":"sleeping","phase":"tick","until":1794749100000.5},"blocked":null,"conversations":[]},
            {"id":41,"kind":{"type":"generation"},"conversation_id":"1","owner":null,"background":false,"abort_requested":false,
             "state":{"status":"waiting","phase":"tools","on":[42,43],"policy":"all_settled"},"blocked":null,"conversations":[]},
            {"id":44,"kind":{"type":"generation"},"conversation_id":"18","owner":null,"background":false,"abort_requested":false,
             "state":{"status":"waiting","phase":"tools","on":[46],"policy":"fail_fast"},"blocked":null,"conversations":[]},
            {"id":45,"kind":{"type":"generation"},"conversation_id":"19","owner":null,"background":false,"abort_requested":true,
             "state":{"status":"completing","outcome":"aborted"},"blocked":null,"conversations":[]},
            {"id":50,"kind":{"type":"other","name":"fixture.retired"},"conversation_id":"27","owner":null,"background":false,"abort_requested":false,
             "state":{"status":"pending","phase":"run"},"blocked":"missing_task","conversations":["31"]},
            {"id":42,"kind":{"type":"tool","name":"delegate_task"},"conversation_id":"1","owner":41,"background":false,"abort_requested":false,
             "state":{"status":"running","phase":"call"},"blocked":null,"conversations":[]},
            {"id":43,"kind":{"type":"tool","name":null},"conversation_id":"1","owner":41,"background":false,"abort_requested":false,
             "state":{"status":"pending","phase":"call"},"blocked":null,"conversations":[]},
            {"id":46,"kind":{"type":"tool","name":"exec"},"conversation_id":"18","owner":44,"background":false,"abort_requested":false,
             "state":{"status":"running","phase":"call"},"blocked":null,"conversations":[]},
            {"id":47,"kind":{"type":"tool","name":"read_file"},"conversation_id":"18","owner":46,"background":false,"abort_requested":false,
             "state":{"status":"running","phase":"call"},"blocked":null,"conversations":[]}
            ],"conversations":[
            {"conversation_id":"1","actor":{"type":"main"}},
            {"conversation_id":"18","actor":{"type":"task","task_id":"6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f","title":"Board\nreview"}},
            {"conversation_id":"19","actor":{"type":"agent","task_id":"6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f","agent_id":"review","title":"Review","parent_conversation_id":"18"}},
            {"conversation_id":"27","actor":{"type":"other"}}
            ]}}"#,
        );
        assert_eq!(
            super::format(&graph),
            "\
Main agent
  #7 agent.background  sleeping until 2026-11-15 13:25:00 UTC · background
  #41 generation  waiting on #42, #43 (all settled)
    #42 tool delegate_task  running
    #43 tool  pending

Task 6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f  Board review
  #44 generation  waiting on #46 (fail fast)
    #46 tool exec  running
      #47 tool read_file  running
  Agent review  Review
    #45 generation  completing (aborted) · abort requested

Conversation 27
  #50 fixture.retired  pending · blocked: no installed definition · owns conversation 31"
        );
    }

    #[test]
    fn an_idle_task_still_heads_its_working_agent_and_a_bounded_snapshot_says_what_it_left_out() {
        let graph = graph(
            r#"{"type":"task_graph","graph":{"omitted":12,"nodes":[
            {"id":9,"kind":{"type":"generation"},"conversation_id":"19","owner":8,"background":false,"abort_requested":false,
             "state":{"status":"sleeping","phase":"retry","until":9007199254740991},"blocked":"restart_limit","conversations":[]}
            ],"conversations":[
            {"conversation_id":"18","actor":{"type":"task","task_id":"6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f","title":"Board review"}},
            {"conversation_id":"19","actor":{"type":"agent","task_id":"6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f","agent_id":"review","title":"Review","parent_conversation_id":"18"}}
            ]}}"#,
        );
        assert_eq!(
            super::format(&graph),
            "\
Task 6f1d2c3e-8a4b-4c5d-9e6f-7a8b9c0d1e2f  Board review
  Agent review  Review
    #9 generation  sleeping · blocked: restart limit reached

12 more live tasks not shown."
        );
    }

    #[test]
    fn an_empty_graph_says_so_and_an_unknown_state_is_an_error() {
        let empty =
            graph(r#"{"type":"task_graph","graph":{"omitted":0,"nodes":[],"conversations":[]}}"#);
        assert_eq!(super::format(&empty), "No live work.");
        let unknown = r#"{"type":"task_graph","graph":{"omitted":0,"conversations":[],"nodes":[
            {"id":1,"kind":{"type":"generation"},"conversation_id":"1","owner":null,"background":false,"abort_requested":false,
             "state":{"status":"paused","phase":"request"},"blocked":null,"conversations":[]}]}}"#;
        assert!(serde_json::from_str::<RuntimeEventKind>(unknown).is_err());
    }

    #[test]
    fn sidechat_conversations_format_with_slug_and_title_and_keep_actor_wire_compatible() {
        let payload = r#"{"type":"task_graph","graph":{"omitted":0,"nodes":[
            {"id":4,"kind":{"type":"generation"},"conversation_id":"12","owner":null,"background":false,"abort_requested":false,
             "state":{"status":"running","phase":"stream"},"blocked":null,"conversations":[]}
            ],"conversations":[
            {"conversation_id":"12","actor":{"type":"other"},"sidechat":{"slug":"morning-brief","title":"Morning Brief"}}
            ]}}"#;
        let graph = graph(payload);
        assert_eq!(
            super::format(&graph),
            "Sidechat morning-brief  Morning Brief\n  #4 generation  running"
        );
        // Verify the actor stays `other` so older decoders without `sidechat` decode cleanly.
        assert!(matches!(
            graph.conversations[0].actor,
            crate::protocol::TaskGraphActor::Other
        ));
    }

    #[test]
    fn label_strips_bidi_and_invisible_format_chars_while_preserving_joined_emoji() {
        assert_eq!(
            super::label("Evil\u{202e}gnp.exe \u{200b}zero\nline"),
            "Evilgnp.exe zero line"
        );
        assert_eq!(
            super::label("Kitchen \u{1f9d1}\u{200d}\u{1f373}"),
            "Kitchen \u{1f9d1}\u{200d}\u{1f373}"
        );
    }
}
