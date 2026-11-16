use std::time::Instant;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

use crate::gate::Marks;

/// What a scenario's coordinator runs beside the measured foreground work.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Background {
    None,
    Search,
    Import,
}

#[derive(Clone, Debug)]
pub struct SearchRequest {
    pub sent: Instant,
    pub done: Instant,
    pub matches: usize,
    pub expected_found: bool,
    pub gaps: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ImportPhase {
    Discovering,
    Importing,
    Indexing,
    Complete,
    Partial,
}

#[derive(Clone, Copy, Debug)]
pub struct ImportProgress {
    pub at: Instant,
    pub phase: ImportPhase,
    pub items_added: u32,
    pub threads_imported: u32,
}

#[derive(Clone, Debug)]
pub enum Evidence {
    None,
    Search(Vec<SearchRequest>),
    Import(Vec<ImportProgress>),
}

pub fn verify(background: Background, evidence: &Evidence, marks: &Marks) -> Result<()> {
    let _ = (background, evidence, marks);
    bail!("not implemented")
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;
    use crate::gate::Mark;

    const ENTER_MS: u64 = 1_000;
    const ACTIVITY_MS: u64 = 1_300;

    fn at(origin: Instant, milliseconds: u64) -> Instant {
        origin + Duration::from_millis(milliseconds)
    }

    fn marks(origin: Instant) -> Marks {
        let mut marks = Marks::default();
        marks.record(Mark::Enter, at(origin, ENTER_MS)).unwrap();
        marks
            .record(Mark::ActivityVisible, at(origin, ACTIVITY_MS))
            .unwrap();
        marks
    }

    fn searches(origin: Instant, intervals: &[(u64, u64)]) -> Evidence {
        Evidence::Search(
            intervals
                .iter()
                .map(|(sent, done)| SearchRequest {
                    sent: at(origin, *sent),
                    done: at(origin, *done),
                    matches: 3,
                    expected_found: true,
                    gaps: vec!["Synthetic coverage gap".into()],
                })
                .collect(),
        )
    }

    fn search_verdict(intervals: &[(u64, u64)]) -> Result<()> {
        let origin = Instant::now();
        verify(
            Background::Search,
            &searches(origin, intervals),
            &marks(origin),
        )
    }

    const WARM: (u64, u64) = (500, 560);

    #[test]
    fn overlapping_search_loops_that_cover_the_foreground_window_pass() {
        assert!(
            search_verdict(&[
                WARM,
                (900, 1_050),
                (960, 1_120),
                (1_050, 1_200),
                (1_120, 1_260),
                (1_200, 1_350),
            ])
            .is_ok()
        );
    }

    #[test]
    fn a_moment_with_no_outstanding_search_inside_the_window_fails() {
        assert!(search_verdict(&[WARM, (900, 1_100), (1_110, 1_350)]).is_err());
        assert!(search_verdict(&[WARM, (1_010, 1_350)]).is_err());
    }

    #[test]
    fn searches_that_end_before_activity_is_visible_fail() {
        assert!(search_verdict(&[WARM, (900, 1_150), (1_100, 1_290)]).is_err());
    }

    #[test]
    fn a_window_without_a_completed_search_before_enter_fails() {
        assert!(search_verdict(&[(900, 1_050), (960, 1_350)]).is_err());
        assert!(search_verdict(&[(500, 1_050), (960, 1_350)]).is_err());
    }

    #[test]
    fn a_search_that_misses_the_expected_conversation_fails() {
        let origin = Instant::now();
        let Evidence::Search(mut requests) =
            searches(origin, &[WARM, (900, 1_200), (1_100, 1_350)])
        else {
            unreachable!()
        };
        requests[2].expected_found = false;
        assert!(
            verify(
                Background::Search,
                &Evidence::Search(requests),
                &marks(origin)
            )
            .is_err()
        );
    }

    fn progress(origin: Instant, events: &[(u64, ImportPhase, u32)]) -> Evidence {
        Evidence::Import(
            events
                .iter()
                .map(|(milliseconds, phase, items_added)| ImportProgress {
                    at: at(origin, *milliseconds),
                    phase: *phase,
                    items_added: *items_added,
                    threads_imported: items_added / 10,
                })
                .collect(),
        )
    }

    fn import_verdict(events: &[(u64, ImportPhase, u32)]) -> Result<()> {
        let origin = Instant::now();
        verify(Background::Import, &progress(origin, events), &marks(origin))
    }

    use ImportPhase::{Complete, Discovering, Importing, Indexing, Partial};

    #[test]
    fn an_import_committing_before_enter_and_after_activity_passes() {
        assert!(
            import_verdict(&[
                (100, Discovering, 0),
                (200, Importing, 0),
                (600, Importing, 40),
                (1_100, Importing, 60),
                (1_900, Importing, 120),
                (9_000, Partial, 400),
            ])
            .is_ok()
        );
    }

    #[test]
    fn an_import_with_no_committed_items_before_enter_fails() {
        assert!(
            import_verdict(&[
                (100, Discovering, 0),
                (600, Importing, 0),
                (1_900, Importing, 120)
            ])
            .is_err()
        );
        assert!(import_verdict(&[(1_100, Importing, 60), (1_900, Importing, 120)]).is_err());
    }

    #[test]
    fn an_import_without_new_commits_after_activity_is_visible_fails() {
        assert!(import_verdict(&[(600, Importing, 40), (1_200, Importing, 120)]).is_err());
        assert!(import_verdict(&[(600, Importing, 40), (1_900, Importing, 40)]).is_err());
        assert!(
            import_verdict(&[
                (600, Importing, 40),
                (1_100, Importing, 90),
                (1_900, Importing, 90)
            ])
            .is_err()
        );
        assert!(
            import_verdict(&[
                (600, Importing, 40),
                (1_900, Indexing, 120),
                (2_000, Complete, 120)
            ])
            .is_err()
        );
    }

    #[test]
    fn evidence_must_come_from_the_scenarios_own_load() {
        let origin = Instant::now();
        let marks = marks(origin);
        assert!(verify(Background::None, &Evidence::None, &marks).is_ok());
        let search = searches(origin, &[WARM, (900, 1_350)]);
        assert!(verify(Background::Search, &search, &marks).is_ok());
        assert!(verify(Background::Import, &search, &marks).is_err());
        assert!(verify(Background::None, &search, &marks).is_err());
        assert!(verify(Background::Search, &Evidence::None, &marks).is_err());
        assert!(verify(Background::Import, &Evidence::None, &marks).is_err());
    }
}
