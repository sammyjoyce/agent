use crate::protocol::{ActiveWorkItem, ActiveWorkStatus, TaskGraphSnapshot};
use crossterm::event::{Event, KeyCode, KeyEvent, KeyModifiers};
use ratatui::{
    Frame,
    layout::{Constraint, Layout, Rect},
    style::{Color, Modifier, Style},
    text::{Line, Span},
    widgets::{Clear, Paragraph, Wrap},
};

#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub(super) struct WorkCounts {
    pub(super) running: usize,
    pub(super) waiting_owner: usize,
    pub(super) waiting_external: usize,
    pub(super) omitted: usize,
}

impl WorkCounts {
    pub(super) fn is_empty(self) -> bool {
        self.running == 0
            && self.waiting_owner == 0
            && self.waiting_external == 0
            && self.omitted == 0
    }
}

/// Whether the coordinator's stream of active work reaches this terminal.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum WorkStream {
    /// A stream is open, or the first one is being opened.
    #[default]
    Open,
    /// The stream ended and the terminal is opening it again.
    Lost,
    /// The coordinator closed the stream without an answer, as one that predates active work does.
    Unreported,
}

#[derive(Default)]
pub(super) struct WorkPanel {
    open: bool,
    scroll: usize,
    page_height: u16,
    snapshot: Option<TaskGraphSnapshot>,
    stream: WorkStream,
}

impl WorkPanel {
    pub(super) fn is_open(&self) -> bool {
        self.open
    }

    pub(super) fn open(&mut self) {
        self.open = true;
        self.scroll = 0;
    }

    pub(super) fn close(&mut self) {
        self.open = false;
    }

    pub(super) fn stream(&self) -> WorkStream {
        self.stream
    }

    pub(super) fn set_stream(&mut self, stream: WorkStream) {
        if stream != WorkStream::Open {
            self.snapshot = None;
        }
        self.stream = stream;
    }

    pub(super) fn set_graph(&mut self, graph: TaskGraphSnapshot) {
        self.snapshot = Some(graph);
        self.stream = WorkStream::Open;
    }

    pub(super) fn take_snapshot(&mut self) -> Option<TaskGraphSnapshot> {
        self.snapshot.take()
    }

    pub(super) fn counts(&self) -> WorkCounts {
        let Some(snapshot) = &self.snapshot else {
            return WorkCounts::default();
        };
        let mut counts = WorkCounts {
            running: 0,
            waiting_owner: 0,
            waiting_external: 0,
            omitted: usize::try_from(snapshot.omitted).unwrap_or(usize::MAX),
        };
        for item in &snapshot.work {
            match item.status {
                ActiveWorkStatus::Running => counts.running += 1,
                ActiveWorkStatus::WaitingOwner => counts.waiting_owner += 1,
                ActiveWorkStatus::WaitingExternal => counts.waiting_external += 1,
            }
        }
        counts
    }

    pub(super) fn footer_spans(&self) -> Vec<Span<'static>> {
        let dim = Style::default().add_modifier(Modifier::DIM);
        if self.stream == WorkStream::Lost {
            return vec![
                Span::styled(" · ", dim),
                Span::styled("active work unknown", dim),
                Span::styled(" (Ctrl+G)", dim),
            ];
        }
        let counts = self.counts();
        if counts.is_empty() {
            return Vec::new();
        }
        let mut spans = count_spans(counts, true);
        spans.push(Span::styled(" (Ctrl+G)", dim));
        spans
    }

    pub(super) fn input(&mut self, event: &Event) -> bool {
        let height = usize::from(self.page_height.max(1));
        match event {
            Event::Key(KeyEvent {
                code: KeyCode::Char('c'),
                modifiers,
                ..
            }) if modifiers.contains(KeyModifiers::CONTROL) => false,
            Event::Key(KeyEvent {
                code: KeyCode::Char('g'),
                modifiers,
                ..
            }) if modifiers.contains(KeyModifiers::CONTROL) => {
                self.close();
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Esc | KeyCode::Char('q'),
                ..
            }) => {
                self.close();
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Up | KeyCode::Char('k'),
                ..
            }) => {
                self.scroll = self.scroll.saturating_sub(1);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Down | KeyCode::Char('j'),
                ..
            }) => {
                self.scroll = self.scroll.saturating_add(1);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::PageUp,
                ..
            }) => {
                let step = height.saturating_sub(4).max(1);
                self.scroll = self.scroll.saturating_sub(step);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::PageDown,
                ..
            }) => {
                let step = height.saturating_sub(4).max(1);
                self.scroll = self.scroll.saturating_add(step);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Char('u'),
                modifiers,
                ..
            }) if modifiers.contains(KeyModifiers::CONTROL) => {
                let step = (height / 2).max(1);
                self.scroll = self.scroll.saturating_sub(step);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Char('d'),
                modifiers,
                ..
            }) if modifiers.contains(KeyModifiers::CONTROL) => {
                let step = (height / 2).max(1);
                self.scroll = self.scroll.saturating_add(step);
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::Home | KeyCode::Char('g'),
                ..
            }) => {
                self.scroll = 0;
                true
            }
            Event::Key(KeyEvent {
                code: KeyCode::End | KeyCode::Char('G'),
                ..
            }) => {
                self.scroll = usize::MAX;
                true
            }
            Event::Key(_) => true,
            _ => false,
        }
    }

    pub(super) fn draw(&mut self, frame: &mut Frame<'_>, area: Rect) {
        self.draw_at(frame, area, crate::runtime::diagnostics::now_ms());
    }

    pub(super) fn draw_at(&mut self, frame: &mut Frame<'_>, area: Rect, now_ms: u64) {
        frame.render_widget(Clear, area);
        let areas = Layout::vertical([
            Constraint::Length(1),
            Constraint::Min(1),
            Constraint::Length(1),
        ])
        .split(area);

        let dim = Style::default().add_modifier(Modifier::DIM);
        let bold = Style::default().add_modifier(Modifier::BOLD);
        let counts = self.counts();
        let mut header = vec![Span::styled("Active work", bold)];
        match self.stream {
            WorkStream::Lost => header.push(Span::styled(" · unknown", dim)),
            WorkStream::Unreported => header.push(Span::styled(" · not reported", dim)),
            WorkStream::Open if counts.is_empty() => header.push(Span::styled(" · idle", dim)),
            WorkStream::Open => header.extend(count_spans(counts, false)),
        }
        header.push(Span::styled(" · read-only", dim));
        frame.render_widget(Line::from(header), areas[0]);

        let paragraph = Paragraph::new(self.body_lines(now_ms)).wrap(Wrap { trim: false });
        let visual_rows = paragraph.line_count(areas[1].width.max(1));
        let view_height = usize::from(areas[1].height.max(1));
        self.page_height = areas[1].height;
        let max_scroll = visual_rows.saturating_sub(view_height);
        self.scroll = self.scroll.min(max_scroll);
        let scroll = u16::try_from(self.scroll).unwrap_or(u16::MAX);
        frame.render_widget(paragraph.scroll((scroll, 0)), areas[1]);

        frame.render_widget(
            Line::from(vec![
                Span::styled("↑↓ / j k", dim),
                Span::raw(" scroll · "),
                Span::styled("PgUp/PgDn", dim),
                Span::raw(" page · "),
                Span::styled("Esc / q / Ctrl+G", dim),
                Span::raw(" close"),
            ]),
            areas[2],
        );
    }

    fn body_lines(&self, now_ms: u64) -> Vec<Line<'static>> {
        let dim = Style::default().add_modifier(Modifier::DIM);
        let bold = Style::default().add_modifier(Modifier::BOLD);
        let Some(snapshot) = &self.snapshot else {
            return vec![Line::styled(
                match self.stream {
                    WorkStream::Open => "Waiting for coordinator task graph…",
                    WorkStream::Lost => {
                        "The coordinator's active work stream ended. This terminal is opening it again; the rows return by themselves."
                    }
                    WorkStream::Unreported => {
                        "This coordinator does not report active work. The rows appear after the coordinator is updated."
                    }
                },
                dim,
            )];
        };
        let work = &snapshot.work;
        if work.is_empty() && snapshot.omitted == 0 {
            return vec![Line::styled("No running or waiting work.", dim)];
        }

        let mut lines = Vec::new();
        let running: Vec<&ActiveWorkItem> = work
            .iter()
            .filter(|item| item.status == ActiveWorkStatus::Running)
            .collect();
        let waiting: Vec<&ActiveWorkItem> = work
            .iter()
            .filter(|item| {
                matches!(
                    item.status,
                    ActiveWorkStatus::WaitingOwner | ActiveWorkStatus::WaitingExternal
                )
            })
            .collect();

        if !running.is_empty() {
            lines.push(Line::styled("Running", bold));
            for item in running {
                render_work_item(item, now_ms, &mut lines);
            }
        }
        if !waiting.is_empty() {
            if !lines.is_empty() {
                lines.push(Line::raw(""));
            }
            lines.push(Line::styled("Waiting", bold));
            for item in waiting {
                render_work_item(item, now_ms, &mut lines);
            }
        }
        if snapshot.omitted > 0 {
            if !lines.is_empty() {
                lines.push(Line::raw(""));
            }
            lines.push(Line::styled(
                format!(
                    "+{} additional nested tasks omitted by snapshot bound (run `beep-boop tasks list` to inspect all)",
                    snapshot.omitted
                ),
                dim,
            ));
        }
        lines
    }
}

fn render_work_item(item: &ActiveWorkItem, now_ms: u64, lines: &mut Vec<Line<'static>>) {
    let dim = Style::default().add_modifier(Modifier::DIM);
    let bold = Style::default().add_modifier(Modifier::BOLD);
    let mut header = match item.status {
        ActiveWorkStatus::Running => vec![
            Span::styled("● ", Style::default().fg(Color::Green)),
            Span::styled(item.title.clone(), bold),
        ],
        ActiveWorkStatus::WaitingOwner => vec![
            Span::styled(
                "◆ ",
                Style::default()
                    .fg(Color::Yellow)
                    .add_modifier(Modifier::BOLD),
            ),
            Span::styled(item.title.clone(), bold),
            Span::styled(" · Needs you", Style::default().fg(Color::Yellow)),
        ],
        ActiveWorkStatus::WaitingExternal => vec![
            Span::styled("◇ ", dim),
            Span::styled(item.title.clone(), Style::default()),
            Span::styled(" · Waiting", dim),
        ],
    };
    if item.is_job {
        header.push(Span::styled(" [Job]", Style::default().fg(Color::Cyan)));
    }
    if let Some(host) = &item.host {
        header.push(Span::styled(format!(" @{host}"), dim));
    }
    if let Some(elapsed) = format_elapsed(item.started_at, now_ms) {
        header.push(Span::styled(format!(" · {elapsed}"), dim));
    }
    lines.push(Line::from(header));

    if let Some(detail) = &item.detail {
        let style = if item.status == ActiveWorkStatus::WaitingOwner {
            Style::default().fg(Color::Yellow)
        } else {
            dim
        };
        lines.push(Line::from(vec![
            Span::styled("  └ ", dim),
            Span::styled(detail.clone(), style),
        ]));
    }
    if let Some(tools) = &item.tools {
        for tool in tools {
            if item.detail.as_ref() == Some(tool) {
                continue;
            }
            lines.push(Line::styled(format!("  └ {tool}"), dim));
        }
    }
    if let Some(children) = &item.children {
        for child in children {
            let (bullet, bullet_style) = match child.status {
                ActiveWorkStatus::Running => ("  ◦ ", Style::default().fg(Color::Green)),
                ActiveWorkStatus::WaitingOwner => ("  ◆ ", Style::default().fg(Color::Yellow)),
                ActiveWorkStatus::WaitingExternal => ("  ◇ ", dim),
            };
            let mut row = vec![
                Span::styled(bullet, bullet_style),
                Span::raw(child.title.clone()),
            ];
            if let Some(host) = &child.host {
                row.push(Span::styled(format!(" @{host}"), dim));
            }
            if let Some(detail) = &child.detail {
                row.push(Span::styled(format!(" — {detail}"), dim));
            }
            lines.push(Line::from(row));
            for tool in &child.tools {
                if child.detail.as_ref() == Some(tool) {
                    continue;
                }
                lines.push(Line::styled(format!("    └ {tool}"), dim));
            }
        }
    }
}

fn count_spans(counts: WorkCounts, include_omitted: bool) -> Vec<Span<'static>> {
    let dim = Style::default().add_modifier(Modifier::DIM);
    let mut spans = Vec::new();
    let mut push = |text: String, style: Style| {
        spans.push(Span::styled(" · ", dim));
        spans.push(Span::styled(text, style));
    };
    if counts.running > 0 {
        push(
            format!("{} running", counts.running),
            Style::default().fg(Color::Green),
        );
    }
    if counts.waiting_owner > 0 {
        push(
            format!("{} needs you", counts.waiting_owner),
            Style::default()
                .fg(Color::Yellow)
                .add_modifier(Modifier::BOLD),
        );
    }
    if counts.waiting_external > 0 {
        push(format!("{} waiting", counts.waiting_external), dim);
    }
    if include_omitted && counts.omitted > 0 {
        push(format!("+{} omitted", counts.omitted), dim);
    }
    spans
}

fn format_elapsed(started_at_ms: Option<u64>, now_ms: u64) -> Option<String> {
    let started = started_at_ms?;
    let seconds = now_ms.saturating_sub(started) / 1000;
    Some(if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3_600 {
        format!("{}m", seconds / 60)
    } else if seconds < 86_400 {
        format!("{}h {}m", seconds / 3_600, (seconds % 3_600) / 60)
    } else {
        format!("{}d", seconds / 86_400)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{ActiveWorkChild, ActiveWorkItem, ActiveWorkStatus, TaskGraphSnapshot};
    use ratatui::{Terminal, backend::TestBackend};

    #[test]
    fn work_panel_groups_running_and_owner_waiting_and_computes_footer_counts() {
        let now_ms = 1_700_000_120_000;
        let mut panel = WorkPanel::default();
        assert!(panel.footer_spans().is_empty());

        panel.set_graph(TaskGraphSnapshot {
            nodes: vec![],
            conversations: vec![],
            omitted: 3,
            work: vec![
                ActiveWorkItem {
                    id: "task:run".into(),
                    task_id: Some("11111111-1111-4111-8111-111111111111".parse().unwrap()),
                    conversation_id: "10".into(),
                    title: "Fix protocol tests".into(),
                    status: ActiveWorkStatus::Running,
                    host: Some("workstation".into()),
                    is_job: false,
                    detail: Some("exec: cargo test".into()),
                    started_at: Some(now_ms - 90_000),
                    tools: Some(vec!["exec: cargo test".into()]),
                    children: Some(vec![ActiveWorkChild {
                        agent_id: "rev".into(),
                        conversation_id: "11".into(),
                        title: "Reviewer".into(),
                        status: ActiveWorkStatus::Running,
                        host: Some("laptop".into()),
                        detail: Some("read: src/protocol.rs".into()),
                        tools: vec!["read: src/protocol.rs".into()],
                    }]),
                },
                ActiveWorkItem {
                    id: "task:owner".into(),
                    task_id: Some("22222222-2222-4222-8222-222222222222".parse().unwrap()),
                    conversation_id: "12".into(),
                    title: "Deploy sign-off".into(),
                    status: ActiveWorkStatus::WaitingOwner,
                    host: None,
                    is_job: false,
                    detail: Some("Approve release v2".into()),
                    started_at: Some(now_ms - 15_000),
                    tools: None,
                    children: None,
                },
                ActiveWorkItem {
                    id: "task:ext".into(),
                    task_id: Some("33333333-3333-4333-8333-333333333333".parse().unwrap()),
                    conversation_id: "13".into(),
                    title: "Daily digest".into(),
                    status: ActiveWorkStatus::WaitingExternal,
                    host: None,
                    is_job: true,
                    detail: Some("Waiting on mail sync".into()),
                    started_at: Some(now_ms - 7_200_000),
                    tools: None,
                    children: None,
                },
            ],
        });

        let counts = panel.counts();
        assert_eq!(
            counts,
            WorkCounts {
                running: 1,
                waiting_owner: 1,
                waiting_external: 1,
                omitted: 3,
            }
        );
        let footer: String = panel
            .footer_spans()
            .into_iter()
            .map(|span| span.content.into_owned())
            .collect();
        assert!(footer.contains("1 running"), "{footer}");
        assert!(footer.contains("1 needs you"), "{footer}");
        assert!(footer.contains("1 waiting"), "{footer}");
        assert!(footer.contains("+3 omitted"), "{footer}");
        assert!(footer.contains("Ctrl+G"), "{footer}");

        panel.open();
        assert!(panel.is_open());
        let mut terminal = Terminal::new(TestBackend::new(80, 20)).unwrap();
        terminal
            .draw(|frame| panel.draw_at(frame, frame.area(), now_ms))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let mut rendered = String::new();
        for y in 0..20 {
            for x in 0..80 {
                rendered.push_str(buffer[(x, y)].symbol());
            }
            rendered.push('\n');
        }
        assert!(rendered.contains("Active work"), "{rendered}");
        assert!(rendered.contains("Running"), "{rendered}");
        assert!(rendered.contains("Fix protocol tests"), "{rendered}");
        assert!(rendered.contains("@workstation"), "{rendered}");
        assert!(rendered.contains("Reviewer @laptop"), "{rendered}");
        assert!(rendered.contains("Waiting"), "{rendered}");
        assert!(rendered.contains("Deploy sign-off"), "{rendered}");
        assert!(rendered.contains("Needs you"), "{rendered}");
        assert!(rendered.contains("[Job]"), "{rendered}");
        assert!(
            rendered.contains("+3 additional nested tasks omitted"),
            "{rendered}"
        );

        assert!(panel.input(&Event::Key(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE))));
        assert!(!panel.is_open());
    }

    fn one_running_task() -> TaskGraphSnapshot {
        TaskGraphSnapshot {
            nodes: vec![],
            conversations: vec![],
            omitted: 0,
            work: vec![ActiveWorkItem {
                id: "task:run".into(),
                task_id: Some("11111111-1111-4111-8111-111111111111".parse().unwrap()),
                conversation_id: "10".into(),
                title: "Fix protocol tests".into(),
                status: ActiveWorkStatus::Running,
                host: None,
                is_job: false,
                detail: None,
                started_at: None,
                tools: None,
                children: None,
            }],
        }
    }

    fn footer(panel: &WorkPanel) -> String {
        panel
            .footer_spans()
            .into_iter()
            .map(|span| span.content.into_owned())
            .collect()
    }

    fn drawn(panel: &mut WorkPanel) -> String {
        let mut terminal = Terminal::new(TestBackend::new(80, 8)).unwrap();
        terminal
            .draw(|frame| panel.draw_at(frame, frame.area(), 0))
            .unwrap();
        let buffer = terminal.backend().buffer();
        let mut rendered = String::new();
        for y in 0..8 {
            for x in 0..80 {
                rendered.push_str(buffer[(x, y)].symbol());
            }
            rendered.push('\n');
        }
        rendered
    }

    #[test]
    fn a_lost_stream_replaces_the_counts_with_a_notice_until_the_next_snapshot() {
        let mut panel = WorkPanel::default();
        panel.set_graph(one_running_task());
        assert_eq!(footer(&panel), " · 1 running (Ctrl+G)");

        panel.set_stream(WorkStream::Lost);

        assert_eq!(footer(&panel), " · active work unknown (Ctrl+G)");
        assert_eq!(panel.counts(), WorkCounts::default());
        let screen = drawn(&mut panel);
        assert!(screen.contains("Active work · unknown"), "{screen}");
        assert!(
            screen.contains("The coordinator's active work stream ended."),
            "{screen}"
        );
        assert!(!screen.contains("Fix protocol tests"), "{screen}");
        assert!(!screen.contains("idle"), "{screen}");

        panel.set_graph(one_running_task());

        assert_eq!(footer(&panel), " · 1 running (Ctrl+G)");
        assert!(drawn(&mut panel).contains("Fix protocol tests"));
    }

    #[test]
    fn a_coordinator_without_the_stream_is_named_in_the_panel_and_adds_nothing_to_the_footer() {
        let mut panel = WorkPanel::default();
        let waiting = drawn(&mut panel);
        assert!(
            waiting.contains("Waiting for coordinator task graph…"),
            "{waiting}"
        );

        panel.set_stream(WorkStream::Unreported);

        assert_eq!(footer(&panel), "");
        let screen = drawn(&mut panel);
        assert!(screen.contains("Active work · not reported"), "{screen}");
        assert!(
            screen.contains("This coordinator does not report active work."),
            "{screen}"
        );
        assert!(!screen.contains("Waiting for coordinator"), "{screen}");
    }
}
