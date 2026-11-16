use std::{
    collections::{BTreeMap, btree_map::Entry},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;

use crate::scenario::Scenario;

pub const RELATIVE_ALLOWANCE: f64 = 0.25;
pub const ABSOLUTE_ALLOWANCE_MS: f64 = 20.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mark {
    Spawn,
    StoredTextVisible,
    Enter,
    Admitted,
    ActivityVisible,
    ReplyVisible,
    BaseActivityVisible,
    SteerEnter,
    SteerQueuedVisible,
    SteerActivityVisible,
    SteerReplyVisible,
    ToolRunning,
    Esc,
    InterruptedVisible,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Gate {
    ConversationVisible,
    Admission,
    FirstActivity,
    SteerAdmission,
    SteerReply,
    Stop,
}

/// Which provider holds a gate may subtract from its wall-clock span.
#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Discount {
    None,
    FirstChunkHolds,
    AllHoldsAfter(Mark),
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct GateDefinition {
    pub gate: Gate,
    pub from: Mark,
    pub to: Mark,
    pub discount: Discount,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum HoldKind {
    FirstChunk,
    Tail,
}

#[derive(Clone, Copy, Debug)]
pub struct Hold {
    pub kind: HoldKind,
    pub from: Instant,
    pub to: Instant,
}

#[derive(Debug, Default)]
pub struct Marks(BTreeMap<Mark, Instant>);

impl Marks {
    pub fn record(&mut self, mark: Mark, at: Instant) -> Result<()> {
        match self.0.entry(mark) {
            Entry::Occupied(_) => bail!("{mark:?} was recorded twice"),
            Entry::Vacant(entry) => {
                entry.insert(at);
                Ok(())
            }
        }
    }

    pub fn get(&self, mark: Mark) -> Result<Instant> {
        self.0
            .get(&mark)
            .copied()
            .with_context(|| format!("{mark:?} was never recorded"))
    }

    pub fn iter(&self) -> impl Iterator<Item = (Mark, Instant)> + '_ {
        self.0.iter().map(|(mark, at)| (*mark, *at))
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
pub struct Span {
    pub gate: Gate,
    pub total_ms: f64,
    pub provider_held_ms: f64,
    pub application_ms: f64,
}

pub fn span(definition: &GateDefinition, marks: &Marks, holds: &[Hold]) -> Result<Span> {
    let from = marks.get(definition.from)?;
    let to = marks.get(definition.to)?;
    let total = to.checked_duration_since(from).with_context(|| {
        format!(
            "{:?} ends at {:?} before it starts at {:?}",
            definition.gate, definition.to, definition.from
        )
    })?;
    for hold in holds {
        ensure!(
            hold.from <= hold.to,
            "A provider hold ends before it starts"
        );
    }
    let (start, eligible): (Instant, fn(&Hold) -> bool) = match definition.discount {
        Discount::None => (to, |_| false),
        Discount::FirstChunkHolds => (from, |hold| hold.kind == HoldKind::FirstChunk),
        Discount::AllHoldsAfter(mark) => (from.max(marks.get(mark)?), |_| true),
    };
    let mut clipped = holds
        .iter()
        .filter(|hold| eligible(hold))
        .map(|hold| (hold.from.max(start), hold.to.min(to)))
        .filter(|(from, to)| from < to)
        .collect::<Vec<_>>();
    clipped.sort();
    let mut held = Duration::ZERO;
    let mut covered = start;
    for (from, to) in clipped {
        let from = from.max(covered);
        if from < to {
            held += to - from;
            covered = to;
        }
    }
    let application = total.checked_sub(held).with_context(|| {
        format!(
            "{:?} has more provider-held time than wall time",
            definition.gate
        )
    })?;
    Ok(Span {
        gate: definition.gate,
        total_ms: milliseconds(total),
        provider_held_ms: milliseconds(held),
        application_ms: milliseconds(application),
    })
}

fn milliseconds(duration: Duration) -> f64 {
    duration.as_secs_f64() * 1000.0
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Version {
    Baseline,
    Candidate,
}

#[derive(Clone, Copy, Debug)]
pub struct Observation {
    pub scenario: Scenario,
    pub version: Version,
    pub pair: u8,
    pub warmup: bool,
    pub span: Span,
}

#[derive(Debug, Serialize)]
pub struct Comparison {
    pub scenario: Scenario,
    pub gate: Gate,
    pub baseline_median_ms: f64,
    pub candidate_median_ms: f64,
    pub baseline_held_median_ms: f64,
    pub candidate_held_median_ms: f64,
    pub paired_budget_median: f64,
    pub passed: bool,
}

pub fn comparisons(
    scenarios: &[Scenario],
    observations: &[Observation],
) -> Result<Vec<Comparison>> {
    scenarios
        .iter()
        .flat_map(|scenario| {
            scenario
                .gates()
                .iter()
                .map(|definition| compare(*scenario, definition.gate, observations))
        })
        .collect()
}

fn compare(scenario: Scenario, gate: Gate, observations: &[Observation]) -> Result<Comparison> {
    let mut pairs: BTreeMap<u8, (Option<Span>, Option<Span>)> = BTreeMap::new();
    for observation in observations.iter().filter(|observation| {
        observation.scenario == scenario && observation.span.gate == gate && !observation.warmup
    }) {
        let measured = observation.span.application_ms;
        ensure!(
            measured.is_finite() && measured >= 0.0,
            "{scenario:?} {gate:?} pair {} has an invalid measurement",
            observation.pair
        );
        let pair = pairs.entry(observation.pair).or_default();
        let slot = match observation.version {
            Version::Baseline => &mut pair.0,
            Version::Candidate => &mut pair.1,
        };
        ensure!(
            slot.is_none(),
            "{scenario:?} {gate:?} pair {} repeats {:?}",
            observation.pair,
            observation.version
        );
        *slot = Some(observation.span);
    }
    let mut baseline = Vec::new();
    let mut candidate = Vec::new();
    let mut baseline_held = Vec::new();
    let mut candidate_held = Vec::new();
    let mut fractions = Vec::new();
    for (pair, (before, after)) in pairs {
        let before = before.with_context(|| {
            format!("{scenario:?} {gate:?} pair {pair} is missing its baseline")
        })?;
        let after = after.with_context(|| {
            format!("{scenario:?} {gate:?} pair {pair} is missing its candidate")
        })?;
        let allowed = (before.application_ms * (1.0 + RELATIVE_ALLOWANCE))
            .max(before.application_ms + ABSOLUTE_ALLOWANCE_MS);
        ensure!(
            allowed.is_finite(),
            "{scenario:?} {gate:?} pair {pair} has an invalid budget"
        );
        baseline.push(before.application_ms);
        candidate.push(after.application_ms);
        baseline_held.push(before.provider_held_ms);
        candidate_held.push(after.provider_held_ms);
        fractions.push(after.application_ms / allowed);
    }
    let median = |mut values: Vec<f64>| -> Result<f64> {
        ensure!(
            values.len() >= 3,
            "{scenario:?} {gate:?} requires at least three measurement pairs"
        );
        values.sort_by(f64::total_cmp);
        values
            .get(values.len() / 2)
            .copied()
            .context("Measurement median is unavailable")
    };
    // Alternating measurements must stay paired: separate medians can
    // turn uneven runner stalls into a regression in a faster candidate.
    let paired_budget_median = median(fractions)?;
    Ok(Comparison {
        scenario,
        gate,
        baseline_median_ms: median(baseline)?,
        candidate_median_ms: median(candidate)?,
        baseline_held_median_ms: median(baseline_held)?,
        candidate_held_median_ms: median(candidate_held)?,
        paired_budget_median,
        passed: paired_budget_median <= 1.0,
    })
}

#[cfg(test)]
mod tests {
    use clap::ValueEnum;

    use super::*;

    fn at(origin: Instant, milliseconds: u64) -> Instant {
        origin + Duration::from_millis(milliseconds)
    }

    fn marks(origin: Instant, entries: &[(Mark, u64)]) -> Marks {
        let mut marks = Marks::default();
        for (mark, milliseconds) in entries {
            marks.record(*mark, at(origin, *milliseconds)).unwrap();
        }
        marks
    }

    fn hold(origin: Instant, kind: HoldKind, from: u64, to: u64) -> Hold {
        Hold {
            kind,
            from: at(origin, from),
            to: at(origin, to),
        }
    }

    const FIRST_ACTIVITY: GateDefinition = GateDefinition {
        gate: Gate::FirstActivity,
        from: Mark::Enter,
        to: Mark::ActivityVisible,
        discount: Discount::FirstChunkHolds,
    };
    const STEER_REPLY: GateDefinition = GateDefinition {
        gate: Gate::SteerReply,
        from: Mark::SteerEnter,
        to: Mark::SteerReplyVisible,
        discount: Discount::AllHoldsAfter(Mark::SteerQueuedVisible),
    };
    const ADMISSION: GateDefinition = GateDefinition {
        gate: Gate::Admission,
        from: Mark::Enter,
        to: Mark::Admitted,
        discount: Discount::None,
    };

    fn first_activity(first_chunk: (u64, u64), tail: (u64, u64), visible: u64) -> Span {
        let origin = Instant::now();
        span(
            &FIRST_ACTIVITY,
            &marks(
                origin,
                &[(Mark::Enter, 0), (Mark::ActivityVisible, visible)],
            ),
            &[
                hold(origin, HoldKind::FirstChunk, first_chunk.0, first_chunk.1),
                hold(origin, HoldKind::Tail, tail.0, tail.1),
            ],
        )
        .unwrap()
    }

    #[test]
    fn first_activity_discounts_only_the_first_chunk_hold_while_the_tail_overlaps() {
        let measured = first_activity((5, 155), (155, 1_655), 290);
        assert_eq!(measured.total_ms, 290.0);
        assert_eq!(measured.provider_held_ms, 150.0);
        assert_eq!(measured.application_ms, 140.0);
    }

    #[test]
    fn a_longer_first_chunk_hold_leaves_first_activity_application_delay_unchanged() {
        let short = first_activity((5, 155), (155, 1_655), 290);
        let long = first_activity((5, 455), (455, 1_955), 590);
        assert_eq!(long.total_ms, short.total_ms + 300.0);
        assert_eq!(long.application_ms, short.application_ms);
    }

    #[test]
    fn a_longer_tail_leaves_first_activity_unchanged() {
        let short = first_activity((5, 155), (155, 1_655), 290);
        let long = first_activity((5, 155), (155, 3_655), 290);
        assert_eq!(long.total_ms, short.total_ms);
        assert_eq!(long.provider_held_ms, short.provider_held_ms);
        assert_eq!(long.application_ms, short.application_ms);
    }

    #[test]
    fn steer_reply_discounts_every_hold_only_after_the_steer_is_queued() {
        let origin = Instant::now();
        let measured = span(
            &STEER_REPLY,
            &marks(
                origin,
                &[
                    (Mark::SteerEnter, 1_000),
                    (Mark::SteerQueuedVisible, 1_100),
                    (Mark::SteerReplyVisible, 3_200),
                ],
            ),
            &[
                hold(origin, HoldKind::FirstChunk, 50, 200),
                hold(origin, HoldKind::Tail, 200, 2_700),
                hold(origin, HoldKind::FirstChunk, 2_750, 2_900),
                hold(origin, HoldKind::Tail, 2_850, 3_000),
            ],
        )
        .unwrap();
        assert_eq!(measured.total_ms, 2_200.0);
        assert_eq!(measured.provider_held_ms, 1_600.0 + 250.0);
        assert_eq!(measured.application_ms, 350.0);
    }

    #[test]
    fn an_undiscounted_gate_ignores_concurrent_holds() {
        let origin = Instant::now();
        let measured = span(
            &ADMISSION,
            &marks(origin, &[(Mark::Enter, 0), (Mark::Admitted, 60)]),
            &[
                hold(origin, HoldKind::FirstChunk, 10, 160),
                hold(origin, HoldKind::Tail, 160, 900),
            ],
        )
        .unwrap();
        assert_eq!(measured.total_ms, 60.0);
        assert_eq!(measured.provider_held_ms, 0.0);
        assert_eq!(measured.application_ms, 60.0);
    }

    #[test]
    fn spans_reject_missing_reversed_and_inverted_inputs() {
        let origin = Instant::now();
        let complete = marks(origin, &[(Mark::Enter, 100), (Mark::Admitted, 160)]);
        assert!(span(&ADMISSION, &marks(origin, &[(Mark::Enter, 0)]), &[]).is_err());
        assert!(
            span(
                &ADMISSION,
                &marks(origin, &[(Mark::Enter, 100), (Mark::Admitted, 60)]),
                &[]
            )
            .is_err()
        );
        assert!(
            span(
                &STEER_REPLY,
                &marks(
                    origin,
                    &[(Mark::SteerEnter, 0), (Mark::SteerReplyVisible, 500)]
                ),
                &[]
            )
            .is_err(),
            "the discount's mark is required"
        );
        assert!(
            span(
                &FIRST_ACTIVITY,
                &marks(origin, &[(Mark::Enter, 0), (Mark::ActivityVisible, 500)]),
                &[hold(origin, HoldKind::FirstChunk, 300, 200)]
            )
            .is_err(),
            "a hold that ends before it starts is invalid"
        );
        assert!(span(&ADMISSION, &complete, &[]).is_ok());
    }

    #[test]
    fn a_mark_is_recorded_once() {
        let origin = Instant::now();
        let mut marks = Marks::default();
        marks.record(Mark::Enter, origin).unwrap();
        assert!(marks.record(Mark::Enter, at(origin, 1)).is_err());
        assert_eq!(marks.get(Mark::Enter).unwrap(), origin);
        assert!(marks.get(Mark::Esc).is_err());
    }

    /// A realistic timeline for any gate. The candidate's closing mark arrives
    /// `delay` later while every provider hold stays identical.
    fn timeline(definition: &GateDefinition, delay: u64) -> Span {
        let origin = Instant::now();
        let mut entries = vec![(definition.from, 1_000), (definition.to, 1_600 + delay)];
        if let Discount::AllHoldsAfter(mark) = definition.discount
            && mark != definition.from
            && mark != definition.to
        {
            entries.push((mark, 1_050));
        }
        span(
            definition,
            &marks(origin, &entries),
            &[
                hold(origin, HoldKind::FirstChunk, 1_010, 1_160),
                hold(origin, HoldKind::Tail, 1_160, 1_500),
            ],
        )
        .unwrap()
    }

    #[test]
    fn two_hundred_milliseconds_of_application_delay_fails_every_discount_kind() {
        for definition in [ADMISSION, FIRST_ACTIVITY, STEER_REPLY] {
            let before = timeline(&definition, 0);
            let after = timeline(&definition, 200);
            assert_eq!(after.provider_held_ms, before.provider_held_ms);
            assert_eq!(after.application_ms, before.application_ms + 200.0);
            assert!(
                after.application_ms
                    > (before.application_ms * 1.25).max(before.application_ms + 20.0),
                "{:?}",
                definition.gate
            );
        }
    }

    #[test]
    fn two_hundred_milliseconds_of_application_delay_fails_every_defined_gate() {
        let observations = Scenario::value_variants()
            .iter()
            .flat_map(|scenario| {
                scenario.gates().iter().flat_map(move |definition| {
                    (1..=3).flat_map(move |pair| {
                        [(Version::Baseline, 0), (Version::Candidate, 200)].map(
                            |(version, delay)| Observation {
                                scenario: *scenario,
                                version,
                                pair,
                                warmup: false,
                                span: timeline(definition, delay),
                            },
                        )
                    })
                })
            })
            .collect::<Vec<_>>();
        let results = comparisons(Scenario::value_variants(), &observations).unwrap();
        assert_eq!(
            results.len(),
            Scenario::value_variants()
                .iter()
                .map(|scenario| scenario.gates().len())
                .sum::<usize>()
        );
        for result in results {
            assert!(!result.passed, "{:?} {:?}", result.scenario, result.gate);
        }
    }

    fn observation(
        scenario: Scenario,
        gate: Gate,
        version: Version,
        pair: u8,
        ms: f64,
    ) -> Observation {
        Observation {
            scenario,
            version,
            pair,
            warmup: pair == 0,
            span: Span {
                gate,
                total_ms: ms,
                provider_held_ms: 0.0,
                application_ms: ms,
            },
        }
    }

    fn paired(baseline: &[f64], candidate: &[f64]) -> Vec<Observation> {
        assert_eq!(baseline.len(), candidate.len());
        Scenario::value_variants()
            .iter()
            .flat_map(|scenario| {
                scenario.gates().iter().flat_map(move |definition| {
                    baseline.iter().zip(candidate).enumerate().flat_map(
                        move |(index, (before, after))| {
                            let pair = u8::try_from(index + 1).unwrap();
                            [(Version::Baseline, *before), (Version::Candidate, *after)].map(
                                |(version, ms)| {
                                    observation(*scenario, definition.gate, version, pair, ms)
                                },
                            )
                        },
                    )
                })
            })
            .collect()
    }

    #[test]
    fn paired_gate_excludes_warmups_and_rejects_a_material_regression() {
        let mut observations = paired(&[100.0; 3], &[140.0; 3]);
        for scenario in Scenario::value_variants() {
            for definition in scenario.gates() {
                for version in [Version::Baseline, Version::Candidate] {
                    observations.push(observation(*scenario, definition.gate, version, 0, 5_000.0));
                }
            }
        }
        for result in comparisons(Scenario::value_variants(), &observations).unwrap() {
            assert_eq!(result.baseline_median_ms, 100.0);
            assert_eq!(result.candidate_median_ms, 140.0);
            assert_eq!(result.paired_budget_median, 140.0 / 125.0);
            assert!(!result.passed);
        }
    }

    #[test]
    fn paired_gate_preserves_faster_pairs_despite_uneven_runner_stalls() {
        let baseline = [
            439.37029, 1310.91328, 366.57530, 904.75781, 298.85085, 302.64821, 929.83019,
        ];
        let candidate = [
            284.22749, 1163.28675, 266.54889, 300.55142, 610.78433, 758.52455, 703.86416,
        ];
        assert_eq!(
            baseline
                .iter()
                .zip(candidate)
                .filter(|(before, after)| after < *before)
                .count(),
            5
        );
        for result in
            comparisons(Scenario::value_variants(), &paired(&baseline, &candidate)).unwrap()
        {
            assert!(
                result.candidate_median_ms
                    > (result.baseline_median_ms * 1.25).max(result.baseline_median_ms + 20.0)
            );
            assert!(
                result.passed,
                "{:?} {:?} has five faster measurement pairs",
                result.scenario, result.gate
            );
        }
    }

    #[test]
    fn paired_gate_preserves_relative_and_absolute_budget_boundaries() {
        for (baseline, candidate, passed) in [
            (100.0, 125.0, true),
            (100.0, 125.1, false),
            (10.0, 30.0, true),
            (10.0, 30.1, false),
            (0.0, 20.0, true),
            (0.0, 20.1, false),
        ] {
            for result in comparisons(
                Scenario::value_variants(),
                &paired(&[baseline; 3], &[candidate; 3]),
            )
            .unwrap()
            {
                assert_eq!(result.passed, passed);
            }
        }
    }

    #[test]
    fn paired_gate_reports_median_provider_held_time_per_version() {
        let mut observations = paired(&[100.0; 3], &[100.0; 3]);
        for observation in &mut observations {
            observation.span.provider_held_ms = match observation.version {
                Version::Baseline => 150.0,
                Version::Candidate => 160.0,
            };
        }
        for result in comparisons(Scenario::value_variants(), &observations).unwrap() {
            assert_eq!(result.baseline_held_median_ms, 150.0);
            assert_eq!(result.candidate_held_median_ms, 160.0);
            assert!(result.passed);
        }
    }

    #[test]
    fn paired_gate_rejects_incomplete_duplicate_and_invalid_measurements() {
        let all = Scenario::value_variants();
        let valid = || paired(&[100.0; 3], &[100.0; 3]);
        assert!(comparisons(all, &valid()).is_ok());
        for version in [Version::Baseline, Version::Candidate] {
            let mut incomplete = valid();
            incomplete.retain(|observation| {
                !(observation.scenario == Scenario::Chief
                    && observation.pair == 2
                    && observation.version == version)
            });
            assert!(comparisons(all, &incomplete).is_err());
        }
        let mut duplicate = valid();
        duplicate.push(observation(
            Scenario::Chief,
            Gate::ConversationVisible,
            Version::Baseline,
            1,
            100.0,
        ));
        assert!(comparisons(all, &duplicate).is_err());
        for milliseconds in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1.0] {
            let mut invalid = valid();
            invalid[0].span.application_ms = milliseconds;
            assert!(comparisons(all, &invalid).is_err());
        }
        let mut missing_gate = valid();
        missing_gate.retain(|observation| observation.scenario != Scenario::LongHistory);
        assert!(comparisons(all, &missing_gate).is_err());
        assert!(comparisons(&[Scenario::Chief], &missing_gate).is_ok());
        assert!(comparisons(all, &paired(&[100.0; 2], &[100.0; 2])).is_err());
        assert!(comparisons(all, &paired(&[f64::MAX; 3], &[f64::MAX; 3])).is_err());
        assert!(comparisons(all, &[]).is_err());
    }
}
