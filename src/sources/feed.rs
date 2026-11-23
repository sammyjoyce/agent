//! What a feed of dated items needs on top of `http.rs`.
//!
//! Three things live here, each with one owner:
//!   `FeedCheckpoint`: the window, its first seven days, paging, resume,
//!   restart, overlap, the daily reread, the spacing of scans and the rewind
//!   when the clock is behind the saved times.
//!   `FeedItem`: the only way to build an event. It derives the version from the text.
//!   `FeedFailure`: the only way to build a failure batch. It owns every fixed sentence.
//!
//! A source supplies the request for a page, the parse of an item, and its text.

use std::{
    sync::LazyLock,
    time::{Duration, Instant},
};

use anyhow::{Result, ensure};
use chrono::DateTime;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};

use crate::{
    protocol::SourceRef,
    sources::{
        SourceBatch, SourceCheckpoint, SourceCoverage, SourceEvent, SourceKey,
        http::{HttpFailure, REQUEST_SECONDS},
    },
};

/// The first poll reads this far back, as Messages does.
const FIRST_LOOKBACK_SECONDS: u64 = 7 * 86_400;
/// Each scan starts this long before the previous scan started. A repeated
/// item has an equal id and version, which the runtime ignores, so the overlap
/// is generous. It covers an item that the service lists late, and either
/// meaning of an inclusive or exclusive lower bound.
const OVERLAP_SECONDS: u64 = 86_400;
/// A finished scan is followed by this much rest, which bounds the requests of an idle feed.
const SCAN_SPACING_SECONDS: u64 = 300;
/// A saved time that is this far ahead of the clock was written under another
/// clock. A lower bound in the future would exclude current items, and a wait
/// for the clock to reach it would leave a gap as long as the wait. So the feed
/// starts again from the current clock and reads its reread window.
///
/// It is also how far the computer's clock may differ from the service's
/// clock. Each scan reads from `OVERLAP_SECONDS` before the scan before it
/// began, so a clock that is wrong by less opens no gap.
const CLOCK_TOLERANCE_SECONDS: u64 = 300;
/// One scan in this period reads the source's whole reread window again. It
/// finds an item that the service lists late with an old creation time.
const REREAD_EVERY_SECONDS: u64 = 86_400;
/// A scan that uses this many poll calls is treated as a paging loop.
const MAX_SCAN_PAGES: u32 = 200;
const MAX_CURSOR_BYTES: usize = 2048;
pub(crate) const PAGE_SIZE: &str = "100";

/// What the coordinator process remembers about its feeds between polls.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct ScanMemory {}

pub(crate) type Monotonic<'a> = &'a (dyn Fn() -> Duration + Sync);

pub(crate) fn process_clock() -> Duration {
    static STARTED: LazyLock<Instant> = LazyLock::new(Instant::now);
    STARTED.elapsed()
}

/// The time of one poll. The computer's clock is read once, when the poll
/// starts. Every later time of the poll is that reading plus what has passed
/// on the monotonic clock. So a clock that is set during a poll changes no
/// time that the poll compares or saves, and a slow credential command does
/// not look like a wrong clock.
pub(crate) struct PollClock<'a> {
    unix_time_at_start: Duration,
    monotonic_at_start: Duration,
    monotonic: Monotonic<'a>,
}

impl<'a> PollClock<'a> {
    pub(crate) fn start(unix_time: Duration, monotonic: Monotonic<'a>) -> Self {
        Self {
            unix_time_at_start: unix_time,
            monotonic_at_start: monotonic(),
            monotonic,
        }
    }

    fn now(&self) -> u64 {
        let passed = (self.monotonic)().saturating_sub(self.monotonic_at_start);
        self.unix_time_at_start.saturating_add(passed).as_secs()
    }
}

/// A poll clock that agreed with the service's clock. Only `check_clock`
/// makes one and `advance` needs one, so a poll under a clock that failed
/// the check saves nothing.
pub(crate) struct CheckedClock<'a>(&'a PollClock<'a>);

/// The state of one feed while a scan runs.
///
/// `P` is what the source keeps between scans. `S` is what it keeps during one
/// scan. `S` lives inside `Scan`, so it cannot outlive the scan. The source
/// must bound `P` and `S`, because both are saved with every page.
pub(crate) struct FeedCheckpoint<P, S> {
    account: String,
    scope: String,
    owner: Option<String>,
    origin: u64,
    reread_at: u64,
    pub(crate) scan: Scan<S>,
    pub(crate) kept: P,
}

/// The JSON in `SourceCheckpoint.value`.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Saved<P, S> {
    /// The config label. A checkpoint with another label is refused.
    account: String,
    /// What else the config says about the account, such as the base address.
    /// A checkpoint with another scope is refused.
    scope: String,
    /// What the service says about whose data the token reads, as a hash.
    owner: Option<String>,
    /// Unix seconds. Set on the first poll to now minus seven days. It moves
    /// only when the clock is behind the checkpoint, and then only earlier.
    /// The feed never asks for, and never delivers, an item created before it.
    origin: u64,
    /// Unix seconds when the last scan that read the whole reread window began.
    /// A checkpoint from before the daily reread has no such field and is
    /// refused, so its other fields are never read under new rules.
    reread_at: u64,
    window: Window<S>,
    kept: P,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Window<S> {
    /// Between scans. The next scan reads from `since` and does not start before `not_before`.
    Resting { since: u64, not_before: u64 },
    /// A scan in flight across polls.
    Scanning(Scan<S>),
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Scan<S> {
    /// Unix seconds when this scan began. The next lower bound derives from it,
    /// so a scan that takes an hour to finish still hands over without a gap.
    pub(crate) started_at: u64,
    /// The lower bound sent to the service for every page of this scan.
    pub(crate) since: u64,
    pages: u32,
    /// True after `Step::Restart`. A source restarts a scan once.
    restarted: bool,
    /// Where the next request continues. `None` asks for a first page.
    pub(crate) cursor: Option<Cursor>,
    pub(crate) state: S,
}

/// An opaque continuation from the service.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub(crate) struct Cursor(String);

impl Cursor {
    pub(crate) fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Cursor {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.is_empty() || value.len() > MAX_CURSOR_BYTES || value.chars().any(char::is_control)
        {
            return Err("unusable cursor");
        }
        Ok(Self(value))
    }
}

impl From<Cursor> for String {
    fn from(cursor: Cursor) -> Self {
        cursor.0
    }
}

/// What a poll call does after it loads the checkpoint.
pub(crate) enum Turn<P, S> {
    /// The last scan finished less than `SCAN_SPACING_SECONDS` ago. The source
    /// makes no request and returns this batch, which keeps the checkpoint.
    Rest(SourceBatch),
    Scan(FeedCheckpoint<P, S>),
}

/// How a successful poll call ends.
pub(crate) enum Step {
    /// Another request belongs to this scan. Coverage `More`.
    /// `Some(cursor)` continues a listing. `None` starts the source's next listing.
    Next(Option<Cursor>),
    /// The service refused a saved cursor. Start the same window again from its
    /// first page. Coverage `More`. Reading the pages again repeats equal events.
    Restart,
    /// The scan is complete. Coverage `Complete`. `floor` pulls the next window
    /// back to an item that can still change.
    Done { floor: Option<u64> },
}

/// A failure, with the events the poll call had already built.
pub(crate) struct Stop {
    failure: FeedFailure,
    events: Vec<SourceEvent>,
}

impl From<FeedFailure> for Stop {
    fn from(failure: FeedFailure) -> Self {
        Self::after(Vec::new(), failure)
    }
}

impl From<HttpFailure> for Stop {
    fn from(failure: HttpFailure) -> Self {
        Self::after(Vec::new(), failure)
    }
}

impl Stop {
    pub(crate) fn after(events: Vec<SourceEvent>, failure: impl Into<FeedFailure>) -> Self {
        Self {
            failure: failure.into(),
            events,
        }
    }
}

impl<P, S> FeedCheckpoint<P, S>
where
    P: Default + Serialize + DeserializeOwned,
    S: Default + Serialize + DeserializeOwned,
{
    /// Parses the saved checkpoint, or makes the first one, and enters a scan.
    ///
    /// When no scan is in flight, `begin` chooses the lower bound and the `S`
    /// of the new scan from `kept` and the default lower bound. Once a day the
    /// new scan reads the last `reread_seconds` again. The result is never
    /// before the first poll's seven days.
    ///
    /// A saved time more than `CLOCK_TOLERANCE_SECONDS` ahead of `now` drops
    /// the scan in flight and starts one that reads the last `reread_seconds`.
    pub(crate) fn load(
        saved: Option<&SourceCheckpoint>,
        key: &SourceKey,
        scope: &str,
        clock: &PollClock<'_>,
        reread_seconds: u64,
        begin: impl FnOnce(&P, u64) -> (u64, S),
    ) -> Result<Turn<P, S>, FeedFailure> {
        let now = clock.now();
        let Some(checkpoint) = saved else {
            let origin = now.saturating_sub(FIRST_LOOKBACK_SECONDS);
            let kept = P::default();
            let (since, state) = begin(&kept, origin);
            return Ok(Turn::Scan(Self {
                account: key.account.clone(),
                scope: scope.to_owned(),
                owner: None,
                origin,
                reread_at: now,
                scan: Scan::first_page(now, since.max(origin), 0, state),
                kept,
            }));
        };
        let saved: Saved<P, S> =
            serde_json::from_str(&checkpoint.value).map_err(|_| FeedFailure::ForeignCheckpoint)?;
        if saved.account != key.account || saved.scope != scope {
            return Err(FeedFailure::ForeignCheckpoint);
        }
        let latest = match &saved.window {
            Window::Resting { since, .. } => *since,
            Window::Scanning(scan) => scan.since.max(scan.started_at),
        }
        .max(saved.origin);
        let clock_is_behind = latest > now.saturating_add(CLOCK_TOLERANCE_SECONDS);
        let mut origin = saved.origin;
        let mut reread_at = saved.reread_at;
        let scan = match saved.window {
            // The saved times say nothing about what was read under this
            // clock, so the window comes from the clock alone. An origin
            // written by a clock that ran ahead would hide the seven days.
            _ if clock_is_behind => {
                origin = origin.min(now.saturating_sub(FIRST_LOOKBACK_SECONDS));
                reread_at = now;
                let (since, state) = begin(&saved.kept, now.saturating_sub(reread_seconds));
                Scan::first_page(now, since.max(origin), 0, state)
            }
            Window::Scanning(scan) if scan.pages >= MAX_SCAN_PAGES => {
                return Err(FeedFailure::Endless);
            }
            Window::Scanning(scan) => scan,
            // A stamp further ahead than the spacing was written by another clock.
            Window::Resting { not_before, .. }
                if now < not_before && not_before - now <= SCAN_SPACING_SECONDS =>
            {
                return Ok(Turn::Rest(SourceBatch {
                    source: key.clone(),
                    events: Vec::new(),
                    checkpoint: Some(checkpoint.clone()),
                    coverage: SourceCoverage::Complete,
                    progress: None,
                }));
            }
            Window::Resting { since, .. } => {
                let (mut since, state) = begin(&saved.kept, since);
                // A stamp in the future came from another clock, and is due as well.
                let reread_is_due =
                    now < reread_at || now >= reread_at.saturating_add(REREAD_EVERY_SECONDS);
                if reread_is_due {
                    reread_at = now;
                    since = since.min(now.saturating_sub(reread_seconds));
                }
                Scan::first_page(now, since.max(saved.origin), 0, state)
            }
        };
        Ok(Turn::Scan(Self {
            account: saved.account,
            scope: saved.scope,
            owner: saved.owner,
            origin,
            reread_at,
            scan,
            kept: saved.kept,
        }))
    }

    /// True when the feed delivers an item created at this time. One rule for
    /// every listing keeps the first seven days true whatever the service's
    /// own lower bound compares.
    pub(crate) fn covers(&self, created_at: u64) -> bool {
        created_at >= self.origin
    }

    /// Ties the checkpoint to the account that the service reports for the
    /// token. A later scan under the same label with another account is refused.
    pub(crate) fn bind_owner(&mut self, owner: String) -> Result<(), FeedFailure> {
        match &self.owner {
            Some(bound) if *bound != owner => Err(FeedFailure::ForeignCheckpoint),
            _ => {
                self.owner = Some(owner);
                Ok(())
            }
        }
    }

    /// Compares the computer's clock with `sent_at`, the time in the `Date`
    /// header of a reply from the service. After a failure the poll must make
    /// no further request.
    pub(crate) fn check_clock<'c>(
        &self,
        clock: &'c PollClock<'c>,
        sent_at: Option<u64>,
    ) -> Result<CheckedClock<'c>, FeedFailure> {
        let sent_at = sent_at.ok_or(FeedFailure::NoDate)?;
        if clock.now().abs_diff(sent_at) > CLOCK_TOLERANCE_SECONDS {
            return Err(FeedFailure::ClockDiffers);
        }
        Ok(CheckedClock(clock))
    }

    /// Ends a successful poll call. The only place a feed checkpoint is serialized.
    pub(crate) fn advance(
        self,
        key: SourceKey,
        events: Vec<SourceEvent>,
        step: Step,
        clock: &CheckedClock<'_>,
    ) -> Result<SourceBatch, Stop> {
        let now = clock.0.now();
        let Scan {
            started_at,
            since,
            pages,
            restarted,
            state,
            ..
        } = self.scan;
        let (window, coverage) = match step {
            Step::Next(cursor) => (
                Window::Scanning(Scan {
                    started_at,
                    since,
                    pages: pages + 1,
                    restarted,
                    cursor,
                    state,
                }),
                SourceCoverage::More,
            ),
            // The page count carries over, so a cursor that the service
            // refuses every time ends as `Endless` and not as a loop.
            Step::Restart => (
                Window::Scanning(Scan {
                    restarted: true,
                    ..Scan::first_page(now, since, pages + 1, S::default())
                }),
                SourceCoverage::More,
            ),
            Step::Done { floor } => (
                Window::Resting {
                    since: floor
                        .map_or(started_at, |floor| floor.min(started_at))
                        .saturating_sub(OVERLAP_SECONDS)
                        .max(self.origin),
                    not_before: now + SCAN_SPACING_SECONDS,
                },
                SourceCoverage::Complete,
            ),
        };
        let saved = Saved {
            account: self.account,
            scope: self.scope,
            owner: self.owner,
            origin: self.origin,
            reread_at: self.reread_at,
            window,
            kept: self.kept,
        };
        match serde_json::to_string(&saved) {
            Ok(value) => Ok(SourceBatch {
                source: key,
                events,
                checkpoint: Some(SourceCheckpoint { value }),
                coverage,
                progress: None,
            }),
            Err(_) => Err(Stop::after(events, FeedFailure::Unsaved)),
        }
    }
}

impl<S> Scan<S> {
    fn first_page(started_at: u64, since: u64, pages: u32, state: S) -> Self {
        Self {
            started_at,
            since,
            pages,
            restarted: false,
            cursor: None,
            state,
        }
    }

    /// True when this scan already started again after a refused cursor.
    pub(crate) fn restarted(&self) -> bool {
        self.restarted
    }
}

/// The last line of every feed's poll. A failure has no checkpoint, so the
/// next poll repeats the same request, and repeated events are equal.
pub(crate) fn settle(
    label: &'static str,
    key: SourceKey,
    step: Result<SourceBatch, Stop>,
) -> SourceBatch {
    let stop = match step {
        Ok(batch) => return batch,
        Err(stop) => stop,
    };
    let message = stop.failure.message(label);
    SourceBatch {
        source: key,
        coverage: if stop.events.is_empty() {
            SourceCoverage::Unavailable { message }
        } else {
            SourceCoverage::Partial { message }
        },
        events: stop.events,
        checkpoint: None,
        progress: None,
    }
}

/// True when a request that carried a saved cursor got 400, 404, 410 or 422.
/// No service here documents how long a cursor lives. A source answers with
/// `Step::Restart`. The same status on a first page is an ordinary failure.
pub(crate) fn cursor_refused(sent_cursor: bool, status: u16) -> bool {
    sent_cursor && matches!(status, 400 | 404 | 410 | 422)
}

/// One item, ready to become an event. It has no version field, so a source
/// cannot set one.
pub(crate) struct FeedItem {
    /// Stable for the life of the item at the service.
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) text: String,
    /// Unix milliseconds.
    pub(crate) occurred_at: Option<u64>,
}

impl FeedItem {
    /// The thread is the item id, so every version of an item is one thread.
    /// The version is a hash of the thread, the title and the text, which are
    /// the fields the runtime compares before it drops a page. So an id and a
    /// version cannot arrive twice with different text, and a change of status
    /// is a new version as long as the text names the status.
    pub(crate) fn into_event(self, key: &SourceKey) -> SourceEvent {
        SourceEvent {
            version: digest(&[&self.id, &self.title, &self.text]),
            legacy_version: None,
            source: SourceRef {
                provider: key.provider.clone(),
                account: key.account.clone(),
                thread_id: self.id.clone(),
            },
            id: self.id,
            title: self.title,
            text: self.text,
            occurred_at: self.occurred_at,
        }
    }
}

/// Each part carries its length, so two different lists cannot hash the same bytes.
fn digest(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update((part.len() as u64).to_be_bytes());
        hasher.update(part.as_bytes());
    }
    hex::encode(hasher.finalize())
}

/// Text from the service, made safe for a title or a line: control characters
/// removed, white space collapsed, cut to `max` characters.
pub(crate) fn clip(value: &str, max: usize) -> String {
    let printable: String = value
        .chars()
        .filter(|character| character.is_whitespace() || !character.is_control())
        .collect();
    let collapsed = printable.split_whitespace().collect::<Vec<_>>().join(" ");
    let cut: String = collapsed.chars().take(max).collect();
    cut.trim_end().to_owned()
}

/// "2026-11-15T00:00:00Z". It has no '+', which a service could read as a space.
pub(crate) fn utc(seconds: u64) -> String {
    i64::try_from(seconds)
        .ok()
        .and_then(|seconds| DateTime::from_timestamp(seconds, 0))
        .unwrap_or_default()
        .format("%Y-%m-%dT%H:%M:%SZ")
        .to_string()
}

pub(crate) fn validate_account(label: &'static str, account: &str) -> Result<()> {
    ensure!(
        !account.trim().is_empty() && !account.chars().any(char::is_control),
        "{label} source needs an explicit account"
    );
    Ok(())
}

/// A short stable hash of the parts. Sources build their checkpoint scope with it.
pub(crate) fn scope(parts: &[&str]) -> String {
    digest(parts)[..16].to_owned()
}

/// Every way a feed poll can fail. The message is built from the label, a
/// status number, a count and text written in this repository. No variant can
/// hold text from the service.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FeedFailure {
    Http(HttpFailure),
    /// The saved checkpoint does not parse, or has another account, scope or owner.
    ForeignCheckpoint,
    NoDate,
    ClockDiffers,
    /// A cursor or page link that is too long, malformed, or outside the API.
    BadCursor,
    /// The scan used `MAX_SCAN_PAGES` poll calls.
    Endless,
    /// Items without an id, a status or a creation time.
    Malformed {
        count: usize,
    },
    /// The next checkpoint could not be written as JSON.
    Unsaved,
    /// A sentence one source owns.
    Fixed(&'static str),
}

impl From<HttpFailure> for FeedFailure {
    fn from(failure: HttpFailure) -> Self {
        Self::Http(failure)
    }
}

impl FeedFailure {
    fn message(self, label: &'static str) -> String {
        match self {
            Self::Http(HttpFailure::Credential) => {
                format!("{label} credentials are unavailable; check credential_command.")
            }
            Self::Http(HttpFailure::NotRun) => {
                format!("{label} could not run curl; check that curl is on the service PATH.")
            }
            Self::Http(HttpFailure::TimedOut) => format!(
                "{label} API did not answer within {REQUEST_SECONDS} seconds; checkpoint retained."
            ),
            Self::Http(HttpFailure::Unreachable) => {
                format!("{label} API is unreachable; checkpoint retained.")
            }
            Self::Http(HttpFailure::Oversized) => {
                format!("{label} sent a response over the capture limit; checkpoint retained.")
            }
            Self::Http(HttpFailure::Status(401)) => format!(
                "{label} rejected the token; it may be expired, revoked or replaced. Checkpoint retained."
            ),
            Self::Http(HttpFailure::Status(403)) => format!(
                "{label} denied this token access; check what the token may read. Checkpoint retained."
            ),
            Self::Http(HttpFailure::Status(429)) => {
                format!("{label} rate limit reached; this poll stopped. Checkpoint retained.")
            }
            Self::Http(HttpFailure::Status(code)) => {
                format!("{label} API returned HTTP {code}; checkpoint retained.")
            }
            Self::Http(HttpFailure::Unreadable) => {
                format!("{label} sent a response this source cannot read; checkpoint retained.")
            }
            Self::ForeignCheckpoint => format!(
                "{label} checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read."
            ),
            Self::NoDate => {
                format!("{label}'s reply carried no usable Date header; checkpoint retained.")
            }
            Self::ClockDiffers => format!(
                "This computer's clock differs from {label}'s clock by more than five minutes; check the clock. Checkpoint retained."
            ),
            Self::BadCursor => {
                format!(
                    "{label} sent a page link this source will not follow; checkpoint retained."
                )
            }
            Self::Endless => format!(
                "{label} listing did not end within {MAX_SCAN_PAGES} pages; checkpoint retained."
            ),
            Self::Malformed { count } => {
                format!(
                    "{label} sent {count} item(s) this source cannot read; checkpoint retained."
                )
            }
            Self::Unsaved => {
                format!("{label} could not save its place in the listing; checkpoint retained.")
            }
            Self::Fixed(text) => text.to_owned(),
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    const NOW: u64 = 1_795_000_000;
    const DAY: u64 = 86_400;
    const REREAD: u64 = 14 * DAY;

    type Checkpoint = FeedCheckpoint<Vec<String>, Option<String>>;

    fn key() -> SourceKey {
        SourceKey {
            provider: "example".into(),
            account: "everyday".into(),
        }
    }

    fn scanning(saved: Option<&SourceCheckpoint>, now: u64) -> Checkpoint {
        scanning_with_reread(saved, now, REREAD)
    }

    fn poll_in_new_process_at(now: u64) -> PollClock<'static> {
        PollClock::start(Duration::from_secs(now), &|| Duration::ZERO)
    }

    fn scanning_with_reread(saved: Option<&SourceCheckpoint>, now: u64, reread: u64) -> Checkpoint {
        match Checkpoint::load(
            saved,
            &key(),
            "scope-a",
            &poll_in_new_process_at(now),
            reread,
            |_, since| (since, None),
        ) {
            Ok(Turn::Scan(checkpoint)) => checkpoint,
            Ok(Turn::Rest(_)) => panic!("the feed rests"),
            Err(failure) => panic!("{}", failure.message("Example")),
        }
    }

    fn refusal(saved: &SourceCheckpoint, key: &SourceKey, scope: &str) -> String {
        match Checkpoint::load(
            Some(saved),
            key,
            scope,
            &poll_in_new_process_at(NOW),
            REREAD,
            |_, since| (since, None),
        ) {
            Err(failure) => failure.message("Example"),
            Ok(_) => panic!("the checkpoint was accepted"),
        }
    }

    fn saved_after(checkpoint: Checkpoint, step: Step, now: u64) -> SourceBatch {
        let clock = poll_in_new_process_at(now);
        let checked = match checkpoint.check_clock(&clock, Some(now)) {
            Ok(checked) => checked,
            Err(failure) => panic!("{}", failure.message("Example")),
        };
        match checkpoint.advance(key(), Vec::new(), step, &checked) {
            Ok(batch) => batch,
            Err(stop) => panic!("{}", stop.failure.message("Example")),
        }
    }

    fn item(title: &str, text: &str) -> SourceEvent {
        FeedItem {
            id: "example-item-1".into(),
            title: title.into(),
            text: text.into(),
            occurred_at: Some(1),
        }
        .into_event(&key())
    }

    #[test]
    fn the_first_checkpoint_starts_seven_days_back() {
        let first = scanning(None, NOW);
        assert_eq!(first.scan.since, NOW - 7 * 86_400);
        assert_eq!(first.scan.started_at, NOW);
        assert!(first.scan.cursor.is_none());
        assert!(first.covers(NOW - 7 * 86_400));
        assert!(!first.covers(NOW - 7 * 86_400 - 1));
    }

    #[test]
    fn a_checkpoint_with_another_account_or_scope_is_refused_with_fixed_text() {
        let saved = saved_after(scanning(None, NOW), Step::Next(None), NOW)
            .checkpoint
            .unwrap();
        let foreign = "Example checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read.";
        let other_account = SourceKey {
            account: "savings".into(),
            ..key()
        };
        assert_eq!(refusal(&saved, &other_account, "scope-a"), foreign);
        assert_eq!(refusal(&saved, &key(), "scope-b"), foreign);
        scanning(Some(&saved), NOW);
    }

    #[test]
    fn an_unparseable_checkpoint_is_refused_with_fixed_text() {
        for value in ["", "{}", "{\"account\":\"everyday\",\"unknown\":1}"] {
            let saved = SourceCheckpoint {
                value: value.into(),
            };
            assert!(refusal(&saved, &key(), "scope-a").contains("belongs to another account"));
        }
    }

    #[test]
    fn an_owner_binds_once_and_another_owner_is_refused() {
        let mut first = scanning(None, NOW);
        first.bind_owner("owner-a".into()).unwrap();
        let saved = saved_after(first, Step::Next(None), NOW)
            .checkpoint
            .unwrap();

        let mut same = scanning(Some(&saved), NOW);
        assert_eq!(same.bind_owner("owner-a".into()), Ok(()));
        let mut other = scanning(Some(&saved), NOW);
        assert_eq!(
            other.bind_owner("owner-b".into()),
            Err(FeedFailure::ForeignCheckpoint)
        );
    }

    #[test]
    fn next_keeps_the_window_and_done_overlaps_the_scan_start() {
        let mut first = scanning(None, NOW);
        first.kept.push("kept between scans".into());
        first.scan.state = Some("kept during the scan".into());
        let cursor = Cursor::try_from("page-2".to_owned()).unwrap();
        let paged = saved_after(first, Step::Next(Some(cursor.clone())), NOW + 5);
        assert_eq!(paged.coverage, SourceCoverage::More);

        let resumed = scanning(paged.checkpoint.as_ref(), NOW + 60);
        assert_eq!(resumed.scan.cursor, Some(cursor));
        assert_eq!(resumed.scan.since, NOW - 7 * 86_400);
        assert_eq!(resumed.scan.started_at, NOW);
        assert_eq!(resumed.scan.state.as_deref(), Some("kept during the scan"));
        let done = saved_after(resumed, Step::Done { floor: None }, NOW + 60);
        assert_eq!(done.coverage, SourceCoverage::Complete);

        let next = scanning(done.checkpoint.as_ref(), NOW + 60 + SCAN_SPACING_SECONDS);
        assert_eq!(next.scan.since, NOW - OVERLAP_SECONDS);
        assert_eq!(next.scan.state, None, "scan state ends with its scan");
        assert_eq!(next.kept, ["kept between scans"]);
    }

    #[test]
    fn done_with_a_floor_pulls_the_next_window_back_but_never_before_origin() {
        let later = NOW + 30 * 86_400;
        let rested = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW);
        let pulled = saved_after(
            scanning(rested.checkpoint.as_ref(), later),
            Step::Done {
                floor: Some(later - 3 * 86_400),
            },
            later,
        );
        let next = scanning(pulled.checkpoint.as_ref(), later + SCAN_SPACING_SECONDS);
        assert_eq!(next.scan.since, later - 4 * 86_400);

        let before_origin = saved_after(
            next,
            Step::Done {
                floor: Some(NOW - 60 * 86_400),
            },
            later + SCAN_SPACING_SECONDS,
        );
        let clamped = scanning(
            before_origin.checkpoint.as_ref(),
            later + 2 * SCAN_SPACING_SECONDS,
        );
        assert_eq!(clamped.scan.since, NOW - 7 * 86_400);
    }

    #[test]
    fn a_poll_inside_the_spacing_rests_with_the_same_checkpoint() {
        let done = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW + 10);
        let saved = done.checkpoint.unwrap();
        let load = |now| {
            Checkpoint::load(
                Some(&saved),
                &key(),
                "scope-a",
                &poll_in_new_process_at(now),
                REREAD,
                |_, since| (since, None),
            )
        };

        match load(NOW + 10 + SCAN_SPACING_SECONDS - 1) {
            Ok(Turn::Rest(batch)) => {
                assert_eq!(batch.coverage, SourceCoverage::Complete);
                assert_eq!(batch.checkpoint, Some(saved.clone()));
                assert!(batch.events.is_empty());
            }
            _ => panic!("a poll inside the spacing must rest"),
        }
        assert!(matches!(
            load(NOW + 10 + SCAN_SPACING_SECONDS),
            Ok(Turn::Scan(_))
        ));
        assert!(
            matches!(load(NOW - 86_400), Ok(Turn::Scan(_))),
            "a clock that moved far back must not stop the feed"
        );
    }

    #[test]
    fn a_saved_time_more_than_five_minutes_ahead_of_the_clock_rewinds_the_feed_in_the_same_poll() {
        let paging = saved_after(scanning(None, NOW), Step::Next(None), NOW)
            .checkpoint
            .unwrap();
        assert_eq!(
            scanning(Some(&paging), NOW - 301).scan.started_at,
            NOW - 301,
            "the scan start is ahead, so a new scan starts"
        );
        assert_eq!(
            scanning(Some(&paging), NOW - 300).scan.started_at,
            NOW,
            "five minutes are tolerated, and the scan in flight continues"
        );

        let resting = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW)
            .checkpoint
            .unwrap();
        let since_at = |now: u64| scanning(Some(&resting), now).scan.since;
        let lower_bound = NOW - OVERLAP_SECONDS;
        assert_eq!(
            since_at(lower_bound - 301),
            lower_bound - 301 - 7 * DAY,
            "the lower bound is ahead, so the feed reads the seven days before the clock"
        );
        assert_eq!(
            since_at(lower_bound - 300),
            NOW - 7 * DAY,
            "five minutes are tolerated, and the origin stays"
        );
        assert_eq!(
            since_at(NOW - 8 * DAY),
            NOW - 15 * DAY,
            "the origin is ahead, and the feed reads and does not rest"
        );
        assert!(matches!(
            Checkpoint::load(
                Some(&resting),
                &key(),
                "scope-a",
                &poll_in_new_process_at(NOW + 1),
                REREAD,
                |_, since| { (since, None) }
            ),
            Ok(Turn::Rest(_))
        ));
    }

    #[test]
    fn one_scan_a_day_rereads_the_window_of_the_source_and_never_before_the_origin() {
        let since_at = |saved: &SourceBatch, now: u64, reread: u64| {
            scanning_with_reread(saved.checkpoint.as_ref(), now, reread)
                .scan
                .since
        };
        let done = |saved: &SourceBatch, now: u64, reread: u64| {
            let scan = scanning_with_reread(saved.checkpoint.as_ref(), now, reread);
            saved_after(scan, Step::Done { floor: None }, now)
        };
        let first = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW);
        let origin = NOW - 7 * DAY;

        assert_eq!(
            since_at(&first, NOW + DAY - 1, REREAD),
            NOW - OVERLAP_SECONDS,
            "the first scan read the whole window, so no reread is due for a day"
        );
        assert_eq!(since_at(&first, NOW + DAY, REREAD), origin);
        assert_eq!(since_at(&first, NOW + DAY, 3 * DAY), NOW - 2 * DAY);
        assert_eq!(
            since_at(&first, NOW + 40 * DAY, REREAD),
            NOW - OVERLAP_SECONDS,
            "a window that is already wider is kept"
        );

        let month = NOW + 30 * DAY;
        let reread = done(&first, month, REREAD);
        let narrow = done(&reread, month + 3_600, REREAD);
        assert_eq!(
            since_at(&narrow, month + DAY, REREAD),
            month + DAY - REREAD,
            "the day counts from the last reread, not from the last scan"
        );
        assert_eq!(since_at(&narrow, month + DAY, 90 * DAY), origin);

        let unfinished = scanning_with_reread(narrow.checkpoint.as_ref(), month + DAY, REREAD);
        let paged = saved_after(unfinished, Step::Next(None), month + DAY);
        let finished = done(&paged, month + DAY + 60, REREAD);
        assert_eq!(
            since_at(&finished, month + DAY + 600, REREAD),
            month + DAY - OVERLAP_SECONDS,
            "a reread that took several polls is not repeated"
        );
    }

    #[test]
    fn a_saved_time_ahead_of_the_clock_rewinds_to_the_reread_window_and_never_before_the_origin() {
        let first = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW);
        let origin = NOW - 7 * DAY;
        let ran_ahead = |real: u64, ahead: u64| {
            let scan = scanning(first.checkpoint.as_ref(), real + ahead);
            saved_after(scan, Step::Done { floor: None }, real + ahead)
        };

        let soon = NOW + 3_600;
        let rewound = scanning(ran_ahead(soon, 16 * DAY).checkpoint.as_ref(), soon + 600);
        assert_eq!(rewound.scan.started_at, soon + 600, "a new scan starts now");
        assert_eq!(
            rewound.scan.since, origin,
            "the reread window starts before the origin, so the origin is the lower bound"
        );

        let later = NOW + 40 * DAY;
        let saved = ran_ahead(later, 30 * DAY);
        let now = later + 600;
        assert_eq!(
            scanning(saved.checkpoint.as_ref(), now).scan.since,
            now - REREAD,
            "the lower bound is the reread window of the source"
        );
        assert_eq!(
            scanning_with_reread(saved.checkpoint.as_ref(), now, 90 * DAY)
                .scan
                .since,
            origin
        );
    }

    #[test]
    fn a_rewind_moves_the_origin_only_when_it_is_later_than_seven_days_before_the_clock() {
        let covered_from = |checkpoint: &Checkpoint| {
            let origin = checkpoint.scan.since;
            assert!(checkpoint.covers(origin) && !checkpoint.covers(origin - 1));
            origin
        };
        let done = |saved: Option<&SourceCheckpoint>, now: u64| {
            saved_after(scanning(saved, now), Step::Done { floor: None }, now)
        };

        let first_under_a_clock_ahead = done(None, NOW + 14 * DAY);
        let corrected = scanning(first_under_a_clock_ahead.checkpoint.as_ref(), NOW);
        assert_eq!(
            covered_from(&corrected),
            NOW - 7 * DAY,
            "an origin ahead of the clock becomes the clock's own first seven days"
        );

        let three_days_ahead = done(None, NOW + 3 * DAY);
        let corrected = scanning(three_days_ahead.checkpoint.as_ref(), NOW);
        assert_eq!(
            covered_from(&corrected),
            NOW - 7 * DAY,
            "an origin four days back was written by a clock that ran ahead"
        );

        let first = done(None, NOW);
        let ran_ahead = done(first.checkpoint.as_ref(), NOW + 16 * DAY);
        let corrected = scanning(ran_ahead.checkpoint.as_ref(), NOW + 3_600);
        assert_eq!(
            covered_from(&corrected),
            NOW - 7 * DAY,
            "an origin that is seven days or more before the clock stays"
        );
    }

    #[test]
    fn a_rewind_drops_the_scan_in_flight_and_keeps_what_the_source_keeps() {
        let mut first = scanning(None, NOW);
        first.kept.push("kept between scans".into());
        first.scan.state = Some("kept during the scan".into());
        let cursor = Cursor::try_from("page-2".to_owned()).unwrap();
        let paged = saved_after(first, Step::Next(Some(cursor)), NOW);

        let moved_back = NOW - 3_600;
        let rewound = scanning(paged.checkpoint.as_ref(), moved_back);
        assert_eq!(rewound.scan.started_at, moved_back);
        assert!(rewound.scan.cursor.is_none(), "the saved cursor is dropped");
        assert_eq!(rewound.scan.state, None, "scan state ends with its scan");
        assert_eq!(rewound.kept, ["kept between scans"]);
    }

    #[test]
    fn after_a_rewind_the_reread_and_the_spacing_count_from_the_current_clock() {
        let load = |saved: &SourceBatch, now: u64| {
            Checkpoint::load(
                saved.checkpoint.as_ref(),
                &key(),
                "scope-a",
                &poll_in_new_process_at(now),
                REREAD,
                |_, since| (since, None),
            )
        };
        let later = NOW + 40 * DAY;
        let first = saved_after(scanning(None, NOW), Step::Done { floor: None }, NOW);
        let ran_ahead = saved_after(
            scanning(first.checkpoint.as_ref(), later + 16 * DAY),
            Step::Done { floor: None },
            later + 16 * DAY,
        );

        let rewound = scanning(ran_ahead.checkpoint.as_ref(), later);
        let done = saved_after(rewound, Step::Done { floor: None }, later + 10);
        assert!(
            matches!(
                load(&done, later + 10 + SCAN_SPACING_SECONDS - 1),
                Ok(Turn::Rest(_))
            ),
            "the next scan waits for the spacing"
        );
        let since_at = |now: u64| scanning(done.checkpoint.as_ref(), now).scan.since;
        assert_eq!(
            since_at(later + 10 + SCAN_SPACING_SECONDS),
            later - OVERLAP_SECONDS
        );
        assert_eq!(
            since_at(later + DAY - 1),
            later - OVERLAP_SECONDS,
            "the rewind read the whole window, so no reread is due for a day"
        );
        assert_eq!(since_at(later + DAY), later + DAY - REREAD);
    }

    #[test]
    fn a_poll_keeps_one_reading_of_the_clock_and_adds_monotonic_time() {
        let monotonic = AtomicU64::new(1_000);
        let read = || Duration::from_secs(monotonic.load(Ordering::Relaxed));
        let clock = PollClock::start(Duration::from_secs(NOW), &read);
        let first = match Checkpoint::load(None, &key(), "scope-a", &clock, REREAD, |_, since| {
            (since, None)
        }) {
            Ok(Turn::Scan(checkpoint)) => checkpoint,
            _ => panic!("the first poll scans"),
        };
        assert_eq!(first.scan.started_at, NOW);

        monotonic.store(1_890, Ordering::Relaxed);
        let agrees = |sent_at| first.check_clock(&clock, sent_at).map(|_| ());
        assert_eq!(agrees(None), Err(FeedFailure::NoDate));
        assert_eq!(agrees(Some(NOW + 890 + 300)), Ok(()));
        assert_eq!(agrees(Some(NOW + 890 - 300)), Ok(()));
        assert_eq!(
            agrees(Some(NOW + 890 + 301)),
            Err(FeedFailure::ClockDiffers)
        );
        assert_eq!(
            agrees(Some(NOW + 890 - 301)),
            Err(FeedFailure::ClockDiffers)
        );
        assert_eq!(
            agrees(Some(NOW)),
            Err(FeedFailure::ClockDiffers),
            "890 seconds passed since the poll read the clock"
        );

        let checked = first.check_clock(&clock, Some(NOW + 890)).unwrap();
        monotonic.store(1_900, Ordering::Relaxed);
        let Ok(done) = first.advance(key(), Vec::new(), Step::Done { floor: None }, &checked)
        else {
            panic!("the checkpoint is saved");
        };
        let rests_at = |now| {
            matches!(
                Checkpoint::load(
                    done.checkpoint.as_ref(),
                    &key(),
                    "scope-a",
                    &poll_in_new_process_at(now),
                    REREAD,
                    |_, since| (since, None),
                ),
                Ok(Turn::Rest(_))
            )
        };
        assert!(
            rests_at(NOW + 900 + SCAN_SPACING_SECONDS - 1),
            "the spacing counts from the end of the poll, 900 monotonic seconds after its start"
        );
        assert!(!rests_at(NOW + 900 + SCAN_SPACING_SECONDS));
    }

    #[test]
    fn a_second_restart_is_visible_to_the_source() {
        let cursor = || Step::Next(Some(Cursor::try_from("page-2".to_owned()).unwrap()));
        let paged = saved_after(scanning(None, NOW), cursor(), NOW);
        let paging = scanning(paged.checkpoint.as_ref(), NOW);
        assert!(!paging.scan.restarted());
        let restarted = saved_after(paging, Step::Restart, NOW);
        let again = saved_after(scanning(restarted.checkpoint.as_ref(), NOW), cursor(), NOW);
        assert!(scanning(again.checkpoint.as_ref(), NOW).scan.restarted());

        let done = saved_after(
            scanning(again.checkpoint.as_ref(), NOW),
            Step::Done { floor: None },
            NOW,
        );
        let next = scanning(done.checkpoint.as_ref(), NOW + SCAN_SPACING_SECONDS);
        assert!(!next.scan.restarted(), "the next scan may restart once");
    }

    #[test]
    fn restart_keeps_the_window_and_resets_the_scan_state() {
        let mut first = scanning(None, NOW);
        first.scan.state = Some("second listing".into());
        let cursor = Cursor::try_from("page-2".to_owned()).unwrap();
        let paged = saved_after(first, Step::Next(Some(cursor)), NOW);
        let restarted = saved_after(
            scanning(paged.checkpoint.as_ref(), NOW + 60),
            Step::Restart,
            NOW + 60,
        );
        assert_eq!(restarted.coverage, SourceCoverage::More);

        let again = scanning(restarted.checkpoint.as_ref(), NOW + 120);
        assert_eq!(again.scan.since, NOW - 7 * 86_400);
        assert_eq!(again.scan.started_at, NOW + 60);
        assert!(again.scan.cursor.is_none());
        assert_eq!(again.scan.state, None);
    }

    #[test]
    fn a_scan_that_uses_every_page_is_endless() {
        let mut saved = None;
        for call in 0..MAX_SCAN_PAGES {
            let step = if call % 2 == 0 {
                Step::Next(Some(Cursor::try_from("page-2".to_owned()).unwrap()))
            } else {
                Step::Restart
            };
            saved = saved_after(scanning(saved.as_ref(), NOW), step, NOW).checkpoint;
        }
        assert_eq!(
            refusal(&saved.unwrap(), &key(), "scope-a"),
            "Example listing did not end within 200 pages; checkpoint retained."
        );
    }

    #[test]
    fn a_cursor_is_bounded_and_only_a_sent_cursor_can_be_refused() {
        assert!(Cursor::try_from(String::new()).is_err());
        assert!(Cursor::try_from("a\nb".to_owned()).is_err());
        assert!(Cursor::try_from("a".repeat(MAX_CURSOR_BYTES + 1)).is_err());
        assert!(Cursor::try_from("a".repeat(MAX_CURSOR_BYTES)).is_ok());
        for status in [400, 404, 410, 422] {
            assert!(cursor_refused(true, status));
            assert!(!cursor_refused(false, status));
        }
        assert!(!cursor_refused(true, 500));
        assert!(!cursor_refused(true, 401));
    }

    #[test]
    fn the_version_changes_when_title_or_text_changes_and_only_then() {
        let held = item("Example Cafe (held)", "Status: held");
        assert_eq!(held.source.thread_id, "example-item-1");
        assert_eq!(
            held.version,
            item("Example Cafe (held)", "Status: held").version
        );
        assert_ne!(
            held.version,
            item("Example Cafe (settled)", "Status: held").version
        );
        assert_ne!(
            held.version,
            item("Example Cafe (held)", "Status: settled").version
        );
        assert_ne!(
            item("ab", "c").version,
            item("a", "bc").version,
            "the fields are hashed with their lengths"
        );
        let later = FeedItem {
            id: "example-item-1".into(),
            title: "Example Cafe (held)".into(),
            text: "Status: held".into(),
            occurred_at: Some(2),
        }
        .into_event(&key());
        assert_eq!(held.version, later.version);
    }

    #[test]
    fn a_stop_with_events_is_partial_and_without_events_is_unavailable_and_neither_has_a_checkpoint()
     {
        let message = "Example API returned HTTP 500; checkpoint retained.";
        let empty = settle("Example", key(), Err(HttpFailure::Status(500).into()));
        assert_eq!(
            empty.coverage,
            SourceCoverage::Unavailable {
                message: message.into()
            }
        );
        assert!(empty.checkpoint.is_none());

        let partial = settle(
            "Example",
            key(),
            Err(Stop::after(
                vec![item("Example Cafe (held)", "Status: held")],
                HttpFailure::Status(500),
            )),
        );
        assert_eq!(
            partial.coverage,
            SourceCoverage::Partial {
                message: message.into()
            }
        );
        assert_eq!(partial.events.len(), 1);
        assert!(partial.checkpoint.is_none());
    }

    #[test]
    fn every_failure_message_is_fixed() {
        let cases = [
            (
                FeedFailure::Http(HttpFailure::Credential),
                "Example credentials are unavailable; check credential_command.",
            ),
            (
                FeedFailure::Http(HttpFailure::NotRun),
                "Example could not run curl; check that curl is on the service PATH.",
            ),
            (
                FeedFailure::Http(HttpFailure::TimedOut),
                "Example API did not answer within 20 seconds; checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Unreachable),
                "Example API is unreachable; checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Oversized),
                "Example sent a response over the capture limit; checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Status(401)),
                "Example rejected the token; it may be expired, revoked or replaced. Checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Status(403)),
                "Example denied this token access; check what the token may read. Checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Status(429)),
                "Example rate limit reached; this poll stopped. Checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Status(503)),
                "Example API returned HTTP 503; checkpoint retained.",
            ),
            (
                FeedFailure::Http(HttpFailure::Unreadable),
                "Example sent a response this source cannot read; checkpoint retained.",
            ),
            (
                FeedFailure::ForeignCheckpoint,
                "Example checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read.",
            ),
            (
                FeedFailure::NoDate,
                "Example's reply carried no usable Date header; checkpoint retained.",
            ),
            (
                FeedFailure::ClockDiffers,
                "This computer's clock differs from Example's clock by more than five minutes; check the clock. Checkpoint retained.",
            ),
            (
                FeedFailure::BadCursor,
                "Example sent a page link this source will not follow; checkpoint retained.",
            ),
            (
                FeedFailure::Endless,
                "Example listing did not end within 200 pages; checkpoint retained.",
            ),
            (
                FeedFailure::Malformed { count: 2 },
                "Example sent 2 item(s) this source cannot read; checkpoint retained.",
            ),
            (
                FeedFailure::Unsaved,
                "Example could not save its place in the listing; checkpoint retained.",
            ),
            (
                FeedFailure::Fixed("A sentence one source owns."),
                "A sentence one source owns.",
            ),
        ];
        for (failure, message) in cases {
            assert_eq!(failure.message("Example"), message);
        }
    }

    #[test]
    fn clip_removes_control_characters_and_bounds_length() {
        assert_eq!(
            clip("  Example\u{0}\u{1b}[31m Cafe\r\n\tSydney  ", 40),
            "Example[31m Cafe Sydney"
        );
        assert_eq!(clip("abcdef", 3), "abc");
        assert_eq!(clip("ab cdef", 3), "ab");
        assert_eq!(clip("\u{7}", 3), "");
    }

    #[test]
    fn utc_prints_seconds_without_an_offset_sign() {
        assert_eq!(utc(1_795_000_000), "2026-11-18T11:06:40Z");
        assert_eq!(utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc(u64::MAX), "1970-01-01T00:00:00Z");
    }

    #[test]
    fn an_account_label_must_be_visible_text() {
        assert!(validate_account("Example", "everyday").is_ok());
        for account in ["", "  ", "every\nday"] {
            assert_eq!(
                validate_account("Example", account)
                    .unwrap_err()
                    .to_string(),
                "Example source needs an explicit account"
            );
        }
    }
}
