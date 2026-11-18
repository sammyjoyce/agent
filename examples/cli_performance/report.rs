use std::{
    collections::BTreeMap,
    time::{Instant, UNIX_EPOCH},
};

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::{
    Seed,
    background::{Evidence, ImportPhase},
    coordinator::{Receipts, Tokens},
    gate::{
        self, ABSOLUTE_ALLOWANCE_MS, Comparison, Hold, HoldKind, Mark, Observation,
        RELATIVE_ALLOWANCE, Span, Version,
    },
    provider::{End, Request},
    resources::{PEAK_KIND, PeakKind, Process, Role},
    scenario::{Definition, Scenario},
    session::Outcome,
    terminal,
};

const USAGE_FORMULA: &str = "input_tokens = ceil(request body bytes / 4); reasoning_tokens = ceil(reasoning bytes / 4); output_tokens = reasoning_tokens + ceil(answer or exec arguments bytes / 4); cached 0; total = input + output";

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct SearchCorpus {
    conversations: u32,
    chunks: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct ImportCorpus {
    rollouts: u32,
    items_per_rollout: u32,
}

#[derive(Serialize)]
pub struct Sample {
    scenario: Scenario,
    version: Version,
    pair: u8,
    warmup: bool,
    spans: Vec<Span>,
    opened_epoch_ms: f64,
    opened_at_ms: f64,
    timeline: Vec<Moment>,
    background: BackgroundReport,
    requests: Vec<RequestReport>,
    processes: Vec<Process>,
    tokens: Option<Tokens>,
    receipts_missing: u64,
    received_bytes: usize,
}

#[derive(Serialize)]
struct Moment {
    at_ms: f64,
    #[serde(flatten)]
    event: Event,
}

#[derive(Serialize)]
#[serde(tag = "source", rename_all = "snake_case")]
enum Event {
    Mark {
        mark: Mark,
    },
    Provider {
        turn: Option<&'static str>,
        event: &'static str,
    },
    Receipt {
        event: String,
        input_id: Option<String>,
        command: Option<String>,
        resolution_ms: u8,
    },
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum BackgroundReport {
    None,
    Search { requests: Vec<SearchReport> },
    Import { progress: Vec<ProgressReport> },
}

#[derive(Serialize)]
struct SearchReport {
    sent_ms: f64,
    done_ms: f64,
    matches: usize,
    expected_found: bool,
    gaps: Vec<String>,
}

#[derive(Serialize)]
struct ProgressReport {
    at_ms: f64,
    phase: ImportPhase,
    items_added: u32,
    threads_imported: u32,
}

#[derive(Serialize)]
struct RequestReport {
    turn: Option<&'static str>,
    body_bytes: usize,
    holds: Vec<HoldReport>,
    end: EndReport,
}

#[derive(Serialize)]
struct HoldReport {
    kind: HoldKind,
    scripted_ms: Option<u64>,
    observed_ms: f64,
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
enum EndReport {
    Completed { total_tokens: u64 },
    ClosedByClient,
    Unexpected { reason: String },
    Failed { error: String },
    Open,
}

#[derive(Serialize)]
struct ScenarioHeader {
    scenario: Scenario,
    #[serde(flatten)]
    definition: &'static Definition,
}

#[derive(Serialize)]
struct ResourceMedian {
    scenario: Scenario,
    version: Version,
    role: Role,
    cpu_ms: f64,
    resident_bytes: f64,
    peak_bytes: f64,
}

#[derive(Serialize)]
struct TokenMedian {
    scenario: Scenario,
    version: Version,
    input: f64,
    output: f64,
    total: f64,
}

#[derive(Serialize)]
pub struct Report {
    schema: u8,
    metric: &'static str,
    terminal_rows: u16,
    terminal_columns: u16,
    long_history_messages: u32,
    unrelated_saved_conversations: u32,
    search_corpus: Option<SearchCorpus>,
    import_corpus: ImportCorpus,
    relative_allowance: f64,
    absolute_allowance_ms: f64,
    synthetic: bool,
    usage_formula: &'static str,
    peak_kind: PeakKind,
    scenarios: Vec<ScenarioHeader>,
    samples: Vec<Sample>,
    comparisons: Vec<Comparison>,
    resources: Vec<ResourceMedian>,
    tokens: Vec<TokenMedian>,
}

fn milliseconds(from: Instant, to: Instant) -> f64 {
    match to.checked_duration_since(from) {
        Some(after) => after.as_secs_f64() * 1000.0,
        None => -(from.duration_since(to).as_secs_f64() * 1000.0),
    }
}

impl Sample {
    pub fn new(
        (scenario, version, pair): (Scenario, Version, u8),
        outcome: Outcome,
        requests: &[Request],
        receipts: Receipts,
    ) -> Result<Self> {
        let holds = requests
            .iter()
            .flat_map(|request| request.holds.iter().map(|(hold, _)| *hold))
            .collect::<Vec<Hold>>();
        let spans = scenario
            .gates()
            .iter()
            .map(|definition| gate::span(definition, &outcome.marks, &holds))
            .collect::<Result<_>>()?;
        let at = |instant| milliseconds(outcome.origin, instant);
        let mut timeline = outcome
            .marks
            .iter()
            .map(|(mark, instant)| Moment {
                at_ms: at(instant),
                event: Event::Mark { mark },
            })
            .collect::<Vec<_>>();
        for request in requests {
            let turn = request.turn.map(|turn| turn.name);
            let ended = match request.end {
                Some(End::Completed { at, .. }) => Some(("completed", at)),
                Some(End::ClosedByClient { at }) => Some(("closed_by_client", at)),
                _ => None,
            };
            let events = [Some(("received", request.received))].into_iter().chain([
                request.first_chunk.map(|first| ("first_chunk", first)),
                ended,
            ]);
            for (event, instant) in events.flatten() {
                timeline.push(Moment {
                    at_ms: at(instant),
                    event: Event::Provider { turn, event },
                });
            }
        }
        let opened = outcome.opened;
        let opened_epoch_ms = opened.wall.duration_since(UNIX_EPOCH)?.as_secs_f64() * 1000.0;
        let opened_at_ms = at(opened.monotonic);
        for receipt in receipts.kept {
            timeline.push(Moment {
                at_ms: receipt.epoch_ms as f64 - opened_epoch_ms + opened_at_ms,
                event: Event::Receipt {
                    event: receipt.event,
                    input_id: receipt.input_id,
                    command: receipt.command,
                    resolution_ms: 1,
                },
            });
        }
        timeline.sort_by(|left, right| left.at_ms.total_cmp(&right.at_ms));
        let background = match outcome.background {
            Evidence::None => BackgroundReport::None,
            Evidence::Search(requests) => BackgroundReport::Search {
                requests: requests
                    .into_iter()
                    .map(|request| SearchReport {
                        sent_ms: at(request.sent),
                        done_ms: at(request.done),
                        matches: request.matches,
                        expected_found: request.expected_found,
                        gaps: request.gaps,
                    })
                    .collect(),
            },
            Evidence::Import(progress) => BackgroundReport::Import {
                progress: progress
                    .into_iter()
                    .map(|event| ProgressReport {
                        at_ms: at(event.at),
                        phase: event.phase,
                        items_added: event.items_added,
                        threads_imported: event.threads_imported,
                    })
                    .collect(),
            },
        };
        let requests = requests
            .iter()
            .map(|request| RequestReport {
                turn: request.turn.map(|turn| turn.name),
                body_bytes: request.body_bytes,
                holds: request
                    .holds
                    .iter()
                    .map(|(hold, scripted_ms)| HoldReport {
                        kind: hold.kind,
                        scripted_ms: *scripted_ms,
                        observed_ms: milliseconds(hold.from, hold.to),
                    })
                    .collect(),
                end: match &request.end {
                    Some(End::Completed { total_tokens, .. }) => EndReport::Completed {
                        total_tokens: *total_tokens,
                    },
                    Some(End::ClosedByClient { .. }) => EndReport::ClosedByClient,
                    Some(End::Unexpected { reason }) => EndReport::Unexpected {
                        reason: reason.clone(),
                    },
                    Some(End::Failed { error }) => EndReport::Failed {
                        error: error.clone(),
                    },
                    None => EndReport::Open,
                },
            })
            .collect();
        Ok(Self {
            scenario,
            version,
            pair,
            warmup: pair == 0,
            spans,
            opened_epoch_ms,
            opened_at_ms,
            timeline,
            background,
            requests,
            processes: outcome.processes,
            tokens: outcome.tokens,
            receipts_missing: receipts.missing,
            received_bytes: outcome.received_bytes,
        })
    }
}

fn median(mut values: Vec<f64>) -> f64 {
    values.sort_by(f64::total_cmp);
    values.get(values.len() / 2).copied().unwrap_or(f64::NAN)
}

fn medians(samples: &[Sample]) -> (Vec<ResourceMedian>, Vec<TokenMedian>) {
    let mut processes: BTreeMap<_, Vec<&Process>> = BTreeMap::new();
    let mut tokens: BTreeMap<_, Vec<Tokens>> = BTreeMap::new();
    for sample in samples.iter().filter(|sample| !sample.warmup) {
        for process in &sample.processes {
            processes
                .entry((sample.scenario, sample.version, process.role))
                .or_default()
                .push(process);
        }
        if let Some(used) = sample.tokens {
            tokens
                .entry((sample.scenario, sample.version))
                .or_default()
                .push(used);
        }
    }
    let resources = processes
        .into_iter()
        .map(|((scenario, version, role), processes)| {
            let of =
                |field: fn(&Process) -> f64| median(processes.iter().map(|p| field(p)).collect());
            ResourceMedian {
                scenario,
                version,
                role,
                cpu_ms: of(|process| process.cpu_ms),
                resident_bytes: of(|process| process.resident_bytes as f64),
                peak_bytes: of(|process| process.peak_bytes as f64),
            }
        })
        .collect();
    let tokens = tokens
        .into_iter()
        .map(|((scenario, version), used)| {
            let of =
                |field: fn(&Tokens) -> u64| median(used.iter().map(|t| field(t) as f64).collect());
            TokenMedian {
                scenario,
                version,
                input: of(|tokens| tokens.input),
                output: of(|tokens| tokens.output),
                total: of(|tokens| tokens.total),
            }
        })
        .collect();
    (resources, tokens)
}

pub fn print(report: &Report) {
    for comparison in &report.comparisons {
        println!(
            "{:?} {:?}: base {:.1} ms, candidate {:.1} ms, held {:.1}/{:.1} ms, paired budget {:.3} (limit 1.000), {}",
            comparison.scenario,
            comparison.gate,
            comparison.baseline_median_ms,
            comparison.candidate_median_ms,
            comparison.baseline_held_median_ms,
            comparison.candidate_held_median_ms,
            comparison.paired_budget_median,
            if comparison.passed {
                "pass"
            } else {
                "REGRESSION"
            }
        );
    }
    for resource in &report.resources {
        println!(
            "{:?} {:?} {:?}: cpu {:.1} ms, resident {:.1} MiB, {} {:.1} MiB",
            resource.scenario,
            resource.version,
            resource.role,
            resource.cpu_ms,
            resource.resident_bytes / 1_048_576.0,
            report.peak_kind.label(),
            resource.peak_bytes / 1_048_576.0
        );
    }
    for tokens in &report.tokens {
        println!(
            "{:?} {:?}: synthetic tokens {:.0} (input {:.0}, output {:.0})",
            tokens.scenario, tokens.version, tokens.total, tokens.input, tokens.output
        );
    }
}

impl Report {
    pub fn passed(&self) -> bool {
        self.comparisons.iter().all(|result| result.passed)
    }
}

pub fn build(scenarios: &[Scenario], samples: Vec<Sample>, seed: &Seed) -> Result<Report> {
    let observations = samples
        .iter()
        .flat_map(|sample| {
            sample.spans.iter().map(|span| Observation {
                scenario: sample.scenario,
                version: sample.version,
                pair: sample.pair,
                warmup: sample.warmup,
                span: *span,
            })
        })
        .collect::<Vec<_>>();
    let (resources, tokens) = medians(&samples);
    Ok(Report {
        schema: 3,
        metric: "application_delay_ms",
        terminal_rows: terminal::ROWS,
        terminal_columns: terminal::COLUMNS,
        long_history_messages: 5_000,
        unrelated_saved_conversations: 3_000,
        search_corpus: seed.search_corpus,
        import_corpus: seed.import_corpus,
        relative_allowance: RELATIVE_ALLOWANCE,
        absolute_allowance_ms: ABSOLUTE_ALLOWANCE_MS,
        synthetic: true,
        usage_formula: USAGE_FORMULA,
        peak_kind: PEAK_KIND,
        scenarios: scenarios
            .iter()
            .map(|scenario| ScenarioHeader {
                scenario: *scenario,
                definition: scenario.definition(),
            })
            .collect(),
        comparisons: gate::comparisons(scenarios, &observations)?,
        samples,
        resources,
        tokens,
    })
}
