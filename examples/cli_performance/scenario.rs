use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail, ensure};
use clap::ValueEnum;
use serde::Serialize;
use tokio::time::sleep;

use crate::{
    DEADLINE,
    background::{self, Background},
    coordinator::read_pid,
    gate::{Gate, GateDefinition, HoldDiscount, Mark, Marks},
    load::Load,
    provider::{End, Request},
    session::{self, Context, Outcome},
    terminal::{Keystroke, Sight, Terminal},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum Scenario {
    ChiefCold,
    Chief,
    LongHistory,
    ScrollHistory,
    Submit,
    SubmitDuringSearch,
    SubmitDuringImport,
    Steer,
    StopStream,
    StopTool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Lifetime {
    PerSample,
    SharedPerVersion,
}

#[derive(Debug, Serialize)]
pub struct Turn {
    pub name: &'static str,
    pub prompt: &'static str,
    pub reasoning: &'static str,
    pub first_chunk_ms: u64,
    pub ending: Ending,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Ending {
    Answer { tail_ms: u64, text: &'static str },
    Exec { tail_ms: u64 },
    Hang,
}

#[derive(Debug, Serialize)]
pub struct Definition {
    pub coordinator: Lifetime,
    pub background: Background,
    pub turns: &'static [Turn],
    pub gates: &'static [GateDefinition],
}

pub const CHIEF_SENTENCE: &str = "Stored chief conversation is ready.";
const LONG_SENTENCE: &str = "Stored long conversation is ready.";
const OLDEST_MESSAGE: &str = "Synthetic retained conversation message 0.";
const OLDER_PAGE_MESSAGE: &str = "Synthetic retained conversation message 3.";
const NEWER_PAGE_MESSAGE: &str = "Synthetic retained conversation message 12.";
pub const ENTER: &[u8] = b"\r";
const ESC: &[u8] = b"\x1b";
const CTRL_HOME: &[u8] = b"\x1b[1;5H";
const PAGE_DOWN: &[u8] = b"\x1b[6~";
const PAGE_UP: &[u8] = b"\x1b[5~";

struct ScrollKey {
    bytes: &'static [u8],
    shows: &'static str,
    pressed: Mark,
    visible: Mark,
}

const SCROLL_FROM_LIVE_BOTTOM_TO_OLDEST_THEN_BACK_ONE_PAGE: [ScrollKey; 3] = [
    ScrollKey {
        bytes: CTRL_HOME,
        shows: OLDEST_MESSAGE,
        pressed: Mark::CtrlHome,
        visible: Mark::OldestVisible,
    },
    ScrollKey {
        bytes: PAGE_DOWN,
        shows: NEWER_PAGE_MESSAGE,
        pressed: Mark::PageDown,
        visible: Mark::NewerPageVisible,
    },
    ScrollKey {
        bytes: PAGE_UP,
        shows: OLDER_PAGE_MESSAGE,
        pressed: Mark::PageUp,
        visible: Mark::OlderPageVisible,
    },
];

pub const PRIME_ANSWER: &str = "Priming finished without changes.";
const SUBMIT_ANSWER: &str = "Three synthetic invoices await review.";
const STEER_BASE_ANSWER: &str = "Checklist drafted with five steps.";
const STEER_ANSWER: &str = "Rollback plan added to the checklist.";

pub const PRIME: Turn = Turn {
    name: "prime",
    prompt: "Prime the synthetic benchmark session.",
    reasoning: "Reading the priming request",
    first_chunk_ms: 20,
    ending: Ending::Answer {
        tail_ms: 150,
        text: PRIME_ANSWER,
    },
};
const SUBMIT: Turn = Turn {
    name: "submit",
    prompt: "Summarize the synthetic invoice backlog.",
    reasoning: "Scanning invoice backlog notes",
    first_chunk_ms: 150,
    ending: Ending::Answer {
        tail_ms: 1_500,
        text: SUBMIT_ANSWER,
    },
};
const STEER_BASE: Turn = Turn {
    name: "steer_base",
    prompt: "Draft a synthetic release checklist.",
    reasoning: "Outlining checklist sections",
    first_chunk_ms: 150,
    ending: Ending::Answer {
        tail_ms: 2_500,
        text: STEER_BASE_ANSWER,
    },
};
const STEER: Turn = Turn {
    name: "steer",
    prompt: "Mention the synthetic rollback plan too.",
    reasoning: "Adding rollback guidance",
    first_chunk_ms: 150,
    ending: Ending::Answer {
        tail_ms: 100,
        text: STEER_ANSWER,
    },
};
const STOP_STREAM: Turn = Turn {
    name: "stop_stream",
    prompt: "Estimate the synthetic storage growth.",
    reasoning: "Projecting storage growth",
    first_chunk_ms: 150,
    ending: Ending::Hang,
};
const STOP_TOOL: Turn = Turn {
    name: "stop_tool",
    prompt: "Run the synthetic idle probe.",
    reasoning: "Starting the idle probe",
    first_chunk_ms: 150,
    ending: Ending::Exec { tail_ms: 300 },
};

const fn gate(gate: Gate, from: Mark, to: Mark, discount: HoldDiscount) -> GateDefinition {
    GateDefinition {
        gate,
        from,
        to,
        discount,
    }
}

static LAUNCH_GATES: [GateDefinition; 1] = [gate(
    Gate::ConversationVisible,
    Mark::Spawn,
    Mark::StoredTextVisible,
    HoldDiscount::None,
)];
static SUBMIT_GATES: [GateDefinition; 2] = [
    gate(
        Gate::Admission,
        Mark::Enter,
        Mark::Admitted,
        HoldDiscount::None,
    ),
    gate(
        Gate::FirstActivity,
        Mark::Enter,
        Mark::ActivityVisible,
        HoldDiscount::FirstChunkHolds,
    ),
];
static STOP_GATES: [GateDefinition; 1] = [gate(
    Gate::Stop,
    Mark::Esc,
    Mark::InterruptedVisible,
    HoldDiscount::None,
)];

static CHIEF_COLD_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::None,
    turns: &[],
    gates: &LAUNCH_GATES,
};
static RETAINED_DEFINITION: Definition = Definition {
    coordinator: Lifetime::SharedPerVersion,
    background: Background::None,
    turns: &[],
    gates: &LAUNCH_GATES,
};
static SCROLL_HISTORY_DEFINITION: Definition = Definition {
    coordinator: Lifetime::SharedPerVersion,
    background: Background::None,
    turns: &[],
    gates: &[
        gate(
            Gate::ScrollToOldest,
            Mark::CtrlHome,
            Mark::OldestVisible,
            HoldDiscount::None,
        ),
        gate(
            Gate::PageUp,
            Mark::PageUp,
            Mark::OlderPageVisible,
            HoldDiscount::None,
        ),
    ],
};
static SUBMIT_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::None,
    turns: &[PRIME, SUBMIT],
    gates: &SUBMIT_GATES,
};
static SUBMIT_DURING_SEARCH_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::Search,
    turns: &[PRIME, SUBMIT],
    gates: &SUBMIT_GATES,
};
static SUBMIT_DURING_IMPORT_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::Import,
    turns: &[PRIME, SUBMIT],
    gates: &SUBMIT_GATES,
};
static STEER_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::None,
    turns: &[PRIME, STEER_BASE, STEER],
    gates: &[
        gate(
            Gate::SteerAdmission,
            Mark::SteerEnter,
            Mark::SteerQueuedVisible,
            HoldDiscount::None,
        ),
        gate(
            Gate::SteerReply,
            Mark::SteerEnter,
            Mark::SteerReplyVisible,
            HoldDiscount::AllHoldsAfter(Mark::SteerQueuedVisible),
        ),
    ],
};
static STOP_STREAM_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::None,
    turns: &[PRIME, STOP_STREAM],
    gates: &STOP_GATES,
};
static STOP_TOOL_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    background: Background::None,
    turns: &[PRIME, STOP_TOOL],
    gates: &STOP_GATES,
};

impl Scenario {
    pub fn definition(self) -> &'static Definition {
        match self {
            Self::ChiefCold => &CHIEF_COLD_DEFINITION,
            Self::Chief | Self::LongHistory => &RETAINED_DEFINITION,
            Self::ScrollHistory => &SCROLL_HISTORY_DEFINITION,
            Self::Submit => &SUBMIT_DEFINITION,
            Self::SubmitDuringSearch => &SUBMIT_DURING_SEARCH_DEFINITION,
            Self::SubmitDuringImport => &SUBMIT_DURING_IMPORT_DEFINITION,
            Self::Steer => &STEER_DEFINITION,
            Self::StopStream => &STOP_STREAM_DEFINITION,
            Self::StopTool => &STOP_TOOL_DEFINITION,
        }
    }

    pub fn gates(self) -> &'static [GateDefinition] {
        self.definition().gates
    }
}

pub async fn drive(scenario: Scenario, context: &Context<'_>) -> Result<Outcome> {
    match scenario {
        Scenario::ChiefCold | Scenario::Chief => {
            session::launch(context, None, CHIEF_SENTENCE).await
        }
        Scenario::LongHistory => {
            let resume = format!("/resume {}", context.seed.long_history);
            session::launch(context, Some(resume), LONG_SENTENCE).await
        }
        Scenario::ScrollHistory => {
            let resume = format!("/resume {}", context.seed.long_history);
            session::browse(context, resume, LONG_SENTENCE, async |terminal, marks| {
                for key in SCROLL_FROM_LIVE_BOTTOM_TO_OLDEST_THEN_BACK_ONE_PAGE {
                    let Keystroke {
                        before_write,
                        sightings: mut seen,
                    } = terminal
                        .press(key.bytes, vec![Sight::Shows(key.shows)])
                        .await?;
                    marks.record(key.pressed, before_write)?;
                    marks.record(key.visible, seen.next().await?)?;
                }
                Ok(())
            })
            .await
        }
        Scenario::Submit | Scenario::SubmitDuringSearch | Scenario::SubmitDuringImport => {
            session::interactive(context, submit_then_stop_searches).await
        }
        Scenario::Steer => {
            session::interactive(context, async |terminal, marks, _| {
                terminal.compose(STEER_BASE.prompt).await?;
                let Keystroke {
                    before_write: enter,
                    sightings: mut seen,
                } = terminal
                    .press(ENTER, vec![Sight::Shows(STEER_BASE.reasoning)])
                    .await?;
                marks.record(Mark::Enter, enter)?;
                marks.record(Mark::BaseActivityVisible, seen.next().await?)?;
                terminal.compose(STEER.prompt).await?;
                let Keystroke {
                    before_write: enter,
                    sightings: mut seen,
                } = terminal
                    .press(
                        ENTER,
                        vec![
                            Sight::Shows("Steering messages, waiting"),
                            Sight::Shows(STEER.reasoning),
                            Sight::Settled(STEER_ANSWER),
                        ],
                    )
                    .await?;
                marks.record(Mark::SteerEnter, enter)?;
                marks.record(Mark::SteerQueuedVisible, seen.next().await?)?;
                marks.record(Mark::SteerActivityVisible, seen.next().await?)?;
                marks.record(Mark::SteerReplyVisible, seen.next().await?)
            })
            .await
        }
        Scenario::StopStream => {
            session::interactive(context, async |terminal, marks, _| {
                terminal.compose(STOP_STREAM.prompt).await?;
                let Keystroke {
                    before_write: enter,
                    sightings: mut seen,
                } = terminal
                    .press(ENTER, vec![Sight::Shows(STOP_STREAM.reasoning)])
                    .await?;
                marks.record(Mark::Enter, enter)?;
                marks.record(Mark::ActivityVisible, seen.next().await?)?;
                let Keystroke {
                    before_write: esc,
                    sightings: mut seen,
                } = terminal.press(ESC, vec![Sight::Stopped]).await?;
                marks.record(Mark::Esc, esc)?;
                marks.record(Mark::InterruptedVisible, seen.next().await?)
            })
            .await
        }
        Scenario::StopTool => {
            let pid_file = context.coordinator.tool_pid_file();
            session::interactive(context, async |terminal, marks, _| {
                terminal.compose(STOP_TOOL.prompt).await?;
                let Keystroke {
                    before_write: enter,
                    sightings: mut seen,
                } = terminal
                    .press(ENTER, vec![Sight::Shows(STOP_TOOL.reasoning)])
                    .await?;
                marks.record(Mark::Enter, enter)?;
                marks.record(Mark::ActivityVisible, seen.next().await?)?;
                let tool = tokio::time::timeout(DEADLINE, async {
                    loop {
                        if let Ok(pid) = read_pid(&pid_file)
                            && unsafe { libc::kill(pid, 0) } == 0
                        {
                            return pid;
                        }
                        sleep(Duration::from_millis(5)).await;
                    }
                })
                .await
                .context("The exec tool did not start")?;
                marks.record(Mark::ToolRunning, Instant::now())?;
                let Keystroke {
                    before_write: esc,
                    sightings: mut seen,
                } = terminal.press(ESC, vec![Sight::Stopped]).await?;
                marks.record(Mark::Esc, esc)?;
                marks.record(Mark::InterruptedVisible, seen.next().await?)?;
                ensure_reaped(tool)
            })
            .await
        }
    }
}

async fn submit_then_stop_searches(
    terminal: &Terminal,
    marks: &mut Marks,
    load: &mut Load,
) -> Result<()> {
    terminal.compose(SUBMIT.prompt).await?;
    let Keystroke {
        before_write: enter,
        sightings: mut seen,
    } = terminal
        .press(
            ENTER,
            vec![
                Sight::Admitted(SUBMIT.prompt),
                Sight::Shows(SUBMIT.reasoning),
                Sight::Settled(SUBMIT_ANSWER),
            ],
        )
        .await?;
    marks.record(Mark::Enter, enter)?;
    marks.record(Mark::Admitted, seen.next().await?)?;
    marks.record(Mark::ActivityVisible, seen.next().await?)?;
    load.stop_searches().await?;
    marks.record(Mark::ReplyVisible, seen.next().await?)
}

fn ensure_reaped(tool: i32) -> Result<()> {
    let alive = unsafe { libc::kill(tool, 0) };
    let error = std::io::Error::last_os_error();
    ensure!(
        alive != 0 && error.raw_os_error() == Some(libc::ESRCH),
        "Tool process {tool} was not reaped when Interrupted became visible ({error})"
    );
    Ok(())
}

pub fn verify(scenario: Scenario, outcome: &Outcome, requests: &[Request]) -> Result<()> {
    let definition = scenario.definition();
    background::verify_overlap(definition.background, &outcome.background, &outcome.marks)?;
    let turns = definition.turns;
    ensure!(
        requests.len() == turns.len(),
        "Expected {} provider requests, received {}",
        turns.len(),
        requests.len()
    );
    for (request, turn) in requests.iter().zip(turns) {
        ensure!(
            request.turn.is_some_and(|seen| seen.name == turn.name),
            "Expected the {} turn, received {:?}",
            turn.name,
            request.turn.map(|turn| turn.name)
        );
        match (&request.end, turn.ending) {
            (Some(End::ClosedByClient { .. }), Ending::Hang)
            | (Some(End::Completed { .. }), Ending::Answer { .. } | Ending::Exec { .. }) => {}
            (end, _) => bail!("The {} turn ended with {end:?}", turn.name),
        }
    }
    if let Ok(esc) = outcome.marks.get(Mark::Esc) {
        ensure!(
            requests.iter().all(|request| request.received < esc),
            "A provider request arrived after Esc"
        );
    }
    if scenario == Scenario::Steer {
        let named = |name: &str| {
            requests
                .iter()
                .find(|request| request.turn.is_some_and(|turn| turn.name == name))
                .with_context(|| format!("The {name} request is missing"))
        };
        let Some(End::Completed { at: base, .. }) = named(STEER_BASE.name)?.end else {
            bail!("The steering base response did not complete");
        };
        ensure!(
            named(STEER.name)?.received > base,
            "The steering request reached the provider before the base response completed"
        );
    }
    if let Some(tokens) = outcome.tokens {
        let completed: u64 = requests
            .iter()
            .filter_map(|request| match request.end {
                Some(End::Completed { at, total_tokens }) if at > outcome.opened.monotonic => {
                    Some(total_tokens)
                }
                _ => None,
            })
            .sum();
        ensure!(
            tokens.total == completed,
            "Pi recorded {} tokens; completed provider responses reported {completed}",
            tokens.total
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::time::SystemTime;

    use super::*;
    use crate::{
        background::Evidence,
        coordinator::Tokens,
        gate::{Hold, HoldKind, Marks, span},
        session::Anchor,
    };

    const FIRST_TURN_ARRIVES_MS: u64 = 10;
    const WINDOW_OPENS_MS: u64 = 100;
    const LATER_TURNS_ARRIVE_MS: u64 = 150;
    const ANSWER_TOKENS: u64 = 17;

    fn ms(milliseconds: u64) -> Duration {
        Duration::from_millis(milliseconds)
    }

    fn outcome(origin: Instant, marks: Marks, recorded_tokens: u64) -> Outcome {
        Outcome {
            origin,
            opened: Anchor {
                wall: SystemTime::now(),
                monotonic: origin + ms(WINDOW_OPENS_MS),
            },
            marks,
            processes: Vec::new(),
            tokens: Some(Tokens {
                total: recorded_tokens,
                ..Tokens::default()
            }),
            background: Evidence::None,
            screen: String::new(),
            received_bytes: 1,
        }
    }

    fn requests(scenario: Scenario, origin: Instant) -> Vec<Request> {
        scenario
            .definition()
            .turns
            .iter()
            .enumerate()
            .map(|(index, turn)| {
                let received = origin
                    + ms(if index == 0 {
                        FIRST_TURN_ARRIVES_MS
                    } else {
                        LATER_TURNS_ARRIVE_MS
                    });
                Request {
                    turn: Some(turn),
                    body_bytes: 1,
                    received,
                    first_chunk: None,
                    holds: Vec::new(),
                    end: Some(match turn.ending {
                        Ending::Hang => End::ClosedByClient {
                            at: received + ms(70),
                        },
                        Ending::Answer { .. } | Ending::Exec { .. } => End::Completed {
                            at: received + ms(5),
                            total_tokens: ANSWER_TOKENS,
                        },
                    }),
                }
            })
            .collect()
    }

    #[test]
    fn a_provider_request_after_esc_fails_verification() {
        let origin = Instant::now();
        let requests = requests(Scenario::StopStream, origin);
        let esc_at = |milliseconds| {
            let mut marks = Marks::default();
            marks.record(Mark::Esc, origin + ms(milliseconds)).unwrap();
            outcome(origin, marks, 0)
        };
        assert!(
            verify(
                Scenario::StopStream,
                &esc_at(LATER_TURNS_ARRIVE_MS + 10),
                &requests
            )
            .is_ok()
        );
        assert!(
            verify(
                Scenario::StopStream,
                &esc_at(LATER_TURNS_ARRIVE_MS - 10),
                &requests
            )
            .is_err()
        );
    }

    #[test]
    fn the_token_ledger_must_match_responses_completed_after_the_window_opens() {
        let origin = Instant::now();
        let requests = requests(Scenario::Submit, origin);
        let verified = |recorded| {
            verify(
                Scenario::Submit,
                &outcome(origin, Marks::default(), recorded),
                &requests,
            )
        };
        assert!(verified(ANSWER_TOKENS).is_ok());
        for recorded in [0, ANSWER_TOKENS - 1, ANSWER_TOKENS + 1, 2 * ANSWER_TOKENS] {
            assert!(verified(recorded).is_err(), "{recorded} tokens");
        }
    }

    #[test]
    fn production_gates_that_must_not_wait_on_the_model_subtract_no_hold() {
        let origin = Instant::now();
        let holds = [
            Hold {
                kind: HoldKind::FirstChunk,
                from: origin + ms(10),
                to: origin + ms(60),
            },
            Hold {
                kind: HoldKind::Tail,
                from: origin + ms(60),
                to: origin + ms(90),
            },
        ];
        let mut checked = Vec::new();
        for scenario in Scenario::value_variants() {
            for definition in scenario.gates() {
                match definition.gate {
                    Gate::ConversationVisible
                    | Gate::ScrollToOldest
                    | Gate::PageUp
                    | Gate::Admission
                    | Gate::SteerAdmission
                    | Gate::Stop => {}
                    Gate::FirstActivity | Gate::SteerReply => continue,
                }
                let mut marks = Marks::default();
                marks.record(definition.from, origin).unwrap();
                marks.record(definition.to, origin + ms(100)).unwrap();
                let measured = span(definition, &marks, &holds).unwrap();
                assert_eq!(
                    measured.application_ms, 100.0,
                    "{scenario:?} {:?}",
                    definition.gate
                );
                checked.push((*scenario, definition.gate));
            }
        }
        for required in [
            (Scenario::Submit, Gate::Admission),
            (Scenario::ScrollHistory, Gate::ScrollToOldest),
            (Scenario::ScrollHistory, Gate::PageUp),
            (Scenario::SubmitDuringSearch, Gate::Admission),
            (Scenario::SubmitDuringImport, Gate::Admission),
        ] {
            assert!(checked.contains(&required), "{required:?} was not checked");
        }
    }

    #[test]
    fn a_tool_still_alive_when_interrupted_is_visible_fails_the_sample() {
        let mut tool = std::process::Command::new("sleep")
            .arg("30")
            .spawn()
            .unwrap();
        let pid = i32::try_from(tool.id()).unwrap();
        assert!(ensure_reaped(pid).is_err());
        tool.kill().unwrap();
        tool.wait().unwrap();
        assert!(ensure_reaped(pid).is_ok());
    }

    #[test]
    fn every_scenario_has_unique_gates_prompts_and_unambiguous_text() {
        for scenario in Scenario::value_variants() {
            let definition = scenario.definition();
            let mut gates = definition
                .gates
                .iter()
                .map(|gate| gate.gate)
                .collect::<Vec<_>>();
            gates.sort();
            gates.dedup();
            assert_eq!(gates.len(), definition.gates.len(), "{scenario:?}");
            let mut prompts = definition
                .turns
                .iter()
                .map(|turn| turn.prompt)
                .collect::<Vec<_>>();
            prompts.sort();
            prompts.dedup();
            assert_eq!(prompts.len(), definition.turns.len(), "{scenario:?}");
        }
        let turns = [PRIME, SUBMIT, STEER_BASE, STEER, STOP_STREAM, STOP_TOOL];
        let mut texts = vec![
            CHIEF_SENTENCE,
            LONG_SENTENCE,
            OLDEST_MESSAGE,
            OLDER_PAGE_MESSAGE,
            NEWER_PAGE_MESSAGE,
            "Synthetic chief conversation message 38.",
            "Synthetic retained conversation message 4998.",
            "Unrelated saved discussion 2999",
            "Steering messages, waiting",
        ];
        for turn in &turns {
            texts.extend([turn.prompt, turn.reasoning]);
            if let Ending::Answer { text, .. } = turn.ending {
                texts.push(text);
            }
        }
        for (index, text) in texts.iter().enumerate() {
            assert!(text.len() < 60, "{text}");
            for (other, candidate) in texts.iter().enumerate() {
                assert!(
                    index == other || !candidate.contains(text),
                    "{text} is within {candidate}"
                );
            }
        }
    }
}
