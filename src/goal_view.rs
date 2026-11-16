use crate::{
    protocol::{
        GoalCheck, GoalCheckFailure, GoalPause, GoalRejection, GoalState, GoalStatus, ObservedFile,
        TaskState,
    },
    task_graph_view::label,
};

const SHA256_PREFIX: usize = 12;

pub fn format(status: &GoalStatus) -> String {
    let Some(view) = status.goal.as_deref() else {
        return "No goal for this conversation. Use /goal <objective> to set one.".into();
    };
    let (goal, task) = (&view.goal, &view.task);
    let activation = &goal.activation;
    let progress = format!(
        "activation {} · continuations {} of {}",
        activation.number, activation.continuations, activation.budget
    );
    let mut lines = vec![
        format!("Goal: {}", label(&goal.objective)),
        match &goal.state {
            GoalState::Active => format!("State: active · {progress}"),
            GoalState::Paused { reason } => {
                format!("State: paused ({}) · {progress}", pause(*reason))
            }
            GoalState::Complete { .. } => "State: complete".into(),
        },
        format!("Task: {} ({})", label(&task.title), task_state(&task.state)),
    ];
    if !task.summary.trim().is_empty() {
        lines.push(format!("Summary: {}", label(task.summary.trim())));
    }
    let pinned = match &goal.state {
        GoalState::Complete { evidence } => Some(&evidence.check),
        GoalState::Active | GoalState::Paused { .. } => activation.check.as_ref(),
    };
    if let Some(pinned) = pinned {
        lines.push(format!("Check: {}", check(pinned)));
    }
    if let GoalState::Complete { evidence } = &goal.state {
        let digest: String = evidence
            .observed
            .sha256
            .chars()
            .take(SHA256_PREFIX)
            .collect();
        lines.push(format!(
            "Verified: activation {} · entry {} · sha256 {} · {}",
            evidence.activation,
            label(&evidence.entry_id),
            label(&digest),
            bytes(&evidence.observed)
        ));
    }
    if let Some(rejection) = &goal.last_rejection {
        lines.push(format!("Last rejection: {}", rejection_text(rejection)));
    }
    if let GoalState::Paused { .. } = goal.state {
        lines.push("Continue with /goal resume.".into());
    }
    lines.join("\n")
}

fn pause(reason: GoalPause) -> &'static str {
    match reason {
        GoalPause::Requested => "requested",
        GoalPause::BudgetExhausted => "budget exhausted",
        GoalPause::Interrupted => "interrupted",
    }
}

fn task_state(state: &TaskState) -> String {
    match state {
        TaskState::Open => "open".into(),
        TaskState::Waiting {
            actor,
            next_check: None,
        } => format!("waiting on {}", label(actor)),
        TaskState::Waiting {
            actor,
            next_check: Some(next),
        } => format!("waiting on {}, next check {}", label(actor), label(next)),
        TaskState::Resolved { .. } => "resolved".into(),
    }
}

fn check(check: &GoalCheck) -> String {
    match check {
        GoalCheck::FileContains { path, text } => format!("{text:?} in {}", label(path)),
    }
}

fn bytes(file: &ObservedFile) -> String {
    let count = match file.bytes {
        1 => "1 byte".to_owned(),
        bytes => format!("{bytes} bytes"),
    };
    if file.complete {
        count
    } else {
        format!("first {count}")
    }
}

fn rejection_text(rejection: &GoalRejection) -> String {
    match rejection {
        GoalRejection::FailedCheck {
            entry_id,
            activation,
            failure,
            tool_call_id,
            ..
        } => format!(
            "check failed ({}) · activation {activation} · entry {} · call {}",
            match failure {
                GoalCheckFailure::TextMissing { observed } =>
                    format!("text not found in {}", bytes(observed)),
                GoalCheckFailure::Unreadable { .. } => "file unreadable".into(),
            },
            label(entry_id),
            label(tool_call_id)
        ),
        GoalRejection::PrematureResolution {
            conversation_id,
            entry_id,
            tool_call_id,
            ..
        } => format!(
            "resolution without a passing check · conversation {} · entry {} · call {}",
            label(conversation_id),
            label(entry_id),
            label(tool_call_id)
        ),
    }
}

#[cfg(test)]
mod tests {
    use crate::{goal_view::format, protocol::RuntimeEventKind};
    use serde_json::{Value, json};

    const TASK_ID: &str = "5b2f7c1e-8d4a-4e6b-9c3f-1a2b3c4d5e6f";
    const CHECK: &str = r#""GOAL-DONE" in /work/notes.md"#;

    fn check() -> Value {
        json!({ "type": "file_contains", "path": "/work/notes.md", "text": "GOAL-DONE" })
    }

    fn render(goal: Option<(Value, Value)>) -> String {
        let goal = goal.map(|(goal, task)| {
            let mut record = json!({
                "id": TASK_ID, "conversation_id": "17", "title": "Write the release notes",
                "outcome": "Release notes exist", "summary": "", "model": null,
                "state": { "state": "open" }, "worker": { "state": "unassigned" },
                "sources": [], "pending": [], "agents": [], "updated_at": 0,
            });
            for (key, value) in task.as_object().unwrap() {
                record[key] = value.clone();
            }
            let mut goal_record = json!({
                "id": "3d9e8f70-1111-4c2b-8a7d-6e5f4a3b2c1d", "task_id": TASK_ID,
                "objective": "Write the release notes with GOAL-DONE.",
                "activation": { "number": 1, "request_id": "3d9e8f70-1111-4c2b-8a7d-6e5f4a3b2c1d",
                    "continuations": 0, "budget": 5, "check": null },
                "state": { "state": "active" }, "last_rejection": null,
                "created_at": 0, "updated_at": 0,
            });
            for (key, value) in goal.as_object().unwrap() {
                goal_record[key] = value.clone();
            }
            json!({ "goal": goal_record, "task": record })
        });
        let event: RuntimeEventKind = serde_json::from_value(json!({
            "type": "goal", "status": { "conversation_id": "root", "goal": goal },
        }))
        .unwrap();
        let RuntimeEventKind::Goal { status } = event else {
            panic!("The fixture must decode as a goal event");
        };
        format(&status)
    }

    #[test]
    fn goal_view_lists_progress() {
        let text = render(Some((
            json!({
                "activation": { "number": 2, "request_id": "r2", "continuations": 3, "budget": 5, "check": check() },
                "last_rejection": { "type": "failed_check", "entry_id": "57", "activation": 2, "check": check(),
                    "failure": { "type": "text_missing", "observed": { "bytes": 6, "complete": true, "sha256": "ab" } },
                    "tool_call_id": "call-9", "at": 0 },
            }),
            json!({
                "summary": "Drafted the notes. Verifying.",
                "state": { "state": "waiting", "actor": "ci", "next_check": "after the build" },
            }),
        )));
        assert_eq!(
            text.lines().collect::<Vec<_>>(),
            [
                "Goal: Write the release notes with GOAL-DONE.",
                "State: active · activation 2 · continuations 3 of 5",
                "Task: Write the release notes (waiting on ci, next check after the build)",
                "Summary: Drafted the notes. Verifying.",
                &format!("Check: {CHECK}"),
                "Last rejection: check failed (text not found in 6 bytes) · activation 2 · entry 57 · call call-9",
            ]
        );
    }

    #[test]
    fn goal_view_hides_what_has_not_happened_yet() {
        assert_eq!(
            render(Some((json!({}), json!({ "summary": "  " })))),
            "Goal: Write the release notes with GOAL-DONE.\n\
             State: active · activation 1 · continuations 0 of 5\n\
             Task: Write the release notes (open)"
        );
    }

    #[test]
    fn goal_view_names_each_pause_reason() {
        for (reason, shown) in [
            ("requested", "requested"),
            ("budget_exhausted", "budget exhausted"),
            ("interrupted", "interrupted"),
        ] {
            let text = render(Some((
                json!({
                    "state": { "state": "paused", "reason": reason },
                    "activation": { "number": 1, "request_id": "r1", "continuations": 5, "budget": 5, "check": null },
                }),
                json!({}),
            )));
            assert!(
                text.contains(&format!(
                    "\nState: paused ({shown}) · activation 1 · continuations 5 of 5\n"
                )),
                "{text}"
            );
            assert!(text.ends_with("\nContinue with /goal resume."), "{text}");
        }
    }

    #[test]
    fn goal_view_shows_evidence_when_complete() {
        let sha256 = "3f2a9c01b4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f";
        let text = render(Some((
            json!({
                "activation": { "number": 2, "request_id": "r2", "continuations": 1, "budget": 5, "check": check() },
                "state": { "state": "complete", "evidence": { "entry_id": "58", "activation": 2, "check": check(),
                    "observed": { "bytes": 10, "complete": true, "sha256": sha256 },
                    "tool_call_id": "call-12", "verified_at": 0 } },
                "last_rejection": { "type": "premature_resolution", "conversation_id": "17", "entry_id": "41",
                    "tool_call_id": "call-4", "at": 0 },
            }),
            json!({ "summary": "The notes contain GOAL-DONE.", "state": { "state": "resolved", "evidence": "Verified." } }),
        )));
        assert_eq!(
            text.lines().collect::<Vec<_>>(),
            [
                "Goal: Write the release notes with GOAL-DONE.",
                "State: complete",
                "Task: Write the release notes (resolved)",
                "Summary: The notes contain GOAL-DONE.",
                &format!("Check: {CHECK}"),
                "Verified: activation 2 · entry 58 · sha256 3f2a9c01b4d5 · 10 bytes",
                "Last rejection: resolution without a passing check · conversation 17 · entry 41 · call call-4",
            ]
        );
    }

    #[test]
    fn goal_view_gives_short_reasons_for_failed_checks() {
        for (failure, reason) in [
            (
                json!({ "type": "text_missing", "observed": { "bytes": 262144, "complete": false, "sha256": "ab" } }),
                "text not found in first 262144 bytes",
            ),
            (
                json!({ "type": "unreadable", "message": "ENOENT /private/fixture/secret-path" }),
                "file unreadable",
            ),
        ] {
            let text = render(Some((
                json!({ "last_rejection": { "type": "failed_check", "entry_id": "60", "activation": 1,
                    "check": check(), "failure": failure, "tool_call_id": "call-1", "at": 0 } }),
                json!({}),
            )));
            assert!(
                text.ends_with(&format!(
                    "\nLast rejection: check failed ({reason}) · activation 1 · entry 60 · call call-1"
                )),
                "{text}"
            );
            assert!(!text.contains("secret-path"), "{text}");
        }
    }

    #[test]
    fn goal_view_without_goal_says_how_to_set_one() {
        assert_eq!(
            render(None),
            "No goal for this conversation. Use /goal <objective> to set one."
        );
    }

    #[test]
    fn goal_view_scrubs_control_characters() {
        let text = render(Some((
            json!({ "objective": "Ship\u{1b}[2J it" }),
            json!({ "title": "Ti\u{7}tle", "summary": "First line.\nSecond line." }),
        )));
        assert!(
            !text
                .chars()
                .any(|character| character.is_control() && character != '\n')
        );
        assert_eq!(
            text.lines().collect::<Vec<_>>(),
            [
                "Goal: Ship [2J it",
                "State: active · activation 1 · continuations 0 of 5",
                "Task: Ti tle (open)",
                "Summary: First line. Second line.",
            ]
        );
    }
}
