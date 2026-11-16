//! Every scenario's definition and its driver. This is the one place a scenario
//! names its coordinator lifetime, provider turns, gates and steps.

use std::time::{Duration, Instant};

use anyhow::{Context as _, Result, bail, ensure};
use clap::ValueEnum;
use serde::Serialize;
use tokio::time::sleep;

use crate::{
    DEADLINE,
    coordinator::read_pid,
    gate::{Discount, Gate, GateDefinition, Mark},
    provider::{End, Request},
    session::{self, Context, Outcome},
    terminal::Sight,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum Scenario {
    ChiefCold,
    Chief,
    LongHistory,
    Submit,
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

/// What the provider sends after the tail hold.
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
    pub turns: &'static [Turn],
    pub gates: &'static [GateDefinition],
}

pub const CHIEF_SENTENCE: &str = "Stored chief conversation is ready.";
const LONG_SENTENCE: &str = "Stored long conversation is ready.";
pub const ENTER: &[u8] = b"\r";
const ESC: &[u8] = b"\x1b";

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

const fn gate(gate: Gate, from: Mark, to: Mark, discount: Discount) -> GateDefinition {
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
    Discount::None,
)];
static STOP_GATES: [GateDefinition; 1] = [gate(
    Gate::Stop,
    Mark::Esc,
    Mark::InterruptedVisible,
    Discount::None,
)];

static CHIEF_COLD_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    turns: &[],
    gates: &LAUNCH_GATES,
};
static RETAINED_DEFINITION: Definition = Definition {
    coordinator: Lifetime::SharedPerVersion,
    turns: &[],
    gates: &LAUNCH_GATES,
};
static SUBMIT_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    turns: &[PRIME, SUBMIT],
    gates: &[
        gate(Gate::Admission, Mark::Enter, Mark::Admitted, Discount::None),
        gate(
            Gate::FirstActivity,
            Mark::Enter,
            Mark::ActivityVisible,
            Discount::FirstChunkHolds,
        ),
    ],
};
static STEER_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    turns: &[PRIME, STEER_BASE, STEER],
    gates: &[
        gate(
            Gate::SteerAdmission,
            Mark::SteerEnter,
            Mark::SteerQueuedVisible,
            Discount::None,
        ),
        gate(
            Gate::SteerReply,
            Mark::SteerEnter,
            Mark::SteerReplyVisible,
            Discount::AllHoldsAfter(Mark::SteerQueuedVisible),
        ),
    ],
};
static STOP_STREAM_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    turns: &[PRIME, STOP_STREAM],
    gates: &STOP_GATES,
};
static STOP_TOOL_DEFINITION: Definition = Definition {
    coordinator: Lifetime::PerSample,
    turns: &[PRIME, STOP_TOOL],
    gates: &STOP_GATES,
};

impl Scenario {
    pub fn definition(self) -> &'static Definition {
        match self {
            Self::ChiefCold => &CHIEF_COLD_DEFINITION,
            Self::Chief | Self::LongHistory => &RETAINED_DEFINITION,
            Self::Submit => &SUBMIT_DEFINITION,
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
        Scenario::Submit => {
            session::interactive(context, async |terminal, marks| {
                terminal.compose(SUBMIT.prompt).await?;
                let (enter, mut seen) = terminal
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
                marks.record(Mark::ReplyVisible, seen.next().await?)
            })
            .await
        }
        Scenario::Steer => {
            session::interactive(context, async |terminal, marks| {
                terminal.compose(STEER_BASE.prompt).await?;
                let (enter, mut seen) = terminal
                    .press(ENTER, vec![Sight::Shows(STEER_BASE.reasoning)])
                    .await?;
                marks.record(Mark::Enter, enter)?;
                marks.record(Mark::BaseActivityVisible, seen.next().await?)?;
                terminal.compose(STEER.prompt).await?;
                let (enter, mut seen) = terminal
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
            session::interactive(context, async |terminal, marks| {
                terminal.compose(STOP_STREAM.prompt).await?;
                let (enter, mut seen) = terminal
                    .press(ENTER, vec![Sight::Shows(STOP_STREAM.reasoning)])
                    .await?;
                marks.record(Mark::Enter, enter)?;
                marks.record(Mark::ActivityVisible, seen.next().await?)?;
                let (esc, mut seen) = terminal.press(ESC, vec![Sight::Stopped]).await?;
                marks.record(Mark::Esc, esc)?;
                marks.record(Mark::InterruptedVisible, seen.next().await?)
            })
            .await
        }
        Scenario::StopTool => {
            let pid_file = context.coordinator.tool_pid_file();
            session::interactive(context, async |terminal, marks| {
                terminal.compose(STOP_TOOL.prompt).await?;
                let (enter, mut seen) = terminal
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
                let (esc, mut seen) = terminal.press(ESC, vec![Sight::Stopped]).await?;
                marks.record(Mark::Esc, esc)?;
                marks.record(Mark::InterruptedVisible, seen.next().await?)?;
                let alive = unsafe { libc::kill(tool, 0) };
                let error = std::io::Error::last_os_error();
                ensure!(
                    alive != 0 && error.raw_os_error() == Some(libc::ESRCH),
                    "Tool process {tool} was not reaped when Interrupted became visible ({error})"
                );
                Ok(())
            })
            .await
        }
    }
}

/// Correctness that fails the sample: the provider saw exactly the scripted
/// turns, stops stopped, steering waited for its boundary, and Pi's ledger
/// counted exactly the requests that completed inside the window.
pub fn verify(scenario: Scenario, outcome: &Outcome, requests: &[Request]) -> Result<()> {
    let turns = scenario.definition().turns;
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
                Some(End::Completed { at, total_tokens }) if at > outcome.opened.1 => {
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
    use super::*;

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
