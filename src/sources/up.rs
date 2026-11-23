//! Opt-in Up bank transactions from the Up API. Read-only: GET requests only.
//!
//! The window of this source, which `Complete` refers to: every transaction
//! created since the source was turned on minus seven days, and the change
//! from held to settled, or the removal, of up to 512 held transactions.
//!
//! One scan is three steps. A `poll` call reads the token once, asks Up whose
//! data that token reads, and then makes one listing request or up to four
//! lookups with the same token:
//!
//!   Ping      GET /util/ping                                          before each step below
//!   Recent    GET /transactions?filter[since]=<since>&page[size]=100  new transactions
//!   Held      GET /transactions?filter[status]=HELD&page[size]=100    every current hold
//!   Departed  GET /transactions/{id}                                  each hold that left the Held listing
//!
//! Up has no modification time, and it does not say what `filter[since]`
//! compares. So this source never reads a change of status from the window and
//! never treats absence as proof. It relies on three documented facts: the
//! HELD filter lists current holds, a lookup of an id returns its current
//! state, and a lookup of a deleted id returns 404 with Up's error body.

use std::collections::BTreeMap;

use anyhow::Result;
use serde::{Deserialize, Serialize};

use crate::sources::{
    Source, SourceBatch, SourceCheckpoint, SourceEvent, SourceKey,
    feed::{self, Cursor, FeedCheckpoint, FeedFailure, FeedItem, Step, Stop, Turn},
    http::{HttpApi, HttpFailure, Reply, Session, Target, UrlRule},
    now_seconds, parse_timestamp_ms,
};

const LABEL: &str = "Up";
const PROVIDER: &str = "up";
const DEFAULT_URL: &str = "https://api.up.com.au/api/v1";
const TRANSACTIONS: &str = "/transactions";
/// The checkpoint follows at most this many holds. A scan that finds more
/// stops with `TOO_MANY_HOLDS` and drops none.
const MAX_HOLDS: usize = 512;
const TOO_MANY_HOLDS: &str =
    "Up lists more held transactions than the 512 this source follows; checkpoint retained.";
const REFUSED_AGAIN: &str =
    "Up refused a saved page link for the second time in one scan; checkpoint retained.";
/// Lookups in one `poll` call. The runtime allows four calls a round.
const LOOKUPS_PER_POLL: usize = 4;
/// How far back a removed hold can pull the next window.
const MAX_REACH_BACK_SECONDS: u64 = 60 * 86_400;
/// One scan a day reads this far back again. Up can record a settlement as a
/// new transaction with the creation time of the hold it replaces, after the
/// scan that followed the removal of the hold.
const REREAD_SECONDS: u64 = 14 * 86_400;
const MAX_ID_BYTES: usize = 128;
const MAX_SUMMARY_CHARS: usize = 160;

/// The time after the last response of a `poll` call.
type Clock<'a> = &'a (dyn Fn() -> u64 + Sync);

#[derive(Debug)]
pub struct UpSource {
    account: String,
    api: HttpApi,
}

impl UpSource {
    pub fn new(
        account: String,
        url: Option<String>,
        credential_command: Vec<String>,
    ) -> Result<Self> {
        feed::validate_account(LABEL, &account)?;
        let api = HttpApi::new(
            LABEL,
            url.as_deref().unwrap_or(DEFAULT_URL),
            credential_command,
            UrlRule::HttpsOrLoopback,
        )?;
        Ok(Self { account, api })
    }

    #[cfg(test)]
    async fn poll_at(
        &self,
        saved: Option<&SourceCheckpoint>,
        now: u64,
        monotonic: Clock<'_>,
        _scans: &feed::ScanMemory,
    ) -> SourceBatch {
        let began = monotonic();
        let after_response = || now + monotonic().saturating_sub(began);
        let step = self.step(saved, now, &after_response).await;
        feed::settle(LABEL, self.key(), step)
    }

    /// The identity check, and then one request or up to `LOOKUPS_PER_POLL` lookups.
    async fn step(
        &self,
        saved: Option<&SourceCheckpoint>,
        now: u64,
        clock: Clock<'_>,
    ) -> Result<SourceBatch, Stop> {
        let key = self.key();
        let scope = feed::scope(&[&self.api.fingerprint()]);
        let begin = |_: &Followed, since: u64| (since, UpScan::default());
        let loaded = Checkpoint::load(saved, &key, &scope, now, REREAD_SECONDS, begin)?;
        let mut checkpoint = match loaded {
            Turn::Rest(batch) => return Ok(batch),
            Turn::Scan(checkpoint) => checkpoint,
        };
        // The credential command runs for every `poll` call and can print the
        // token of another customer at any of them. So every call asks whose
        // token it holds before it reads a transaction with that token. Only
        // a hash of the customer id is kept.
        let session = self.api.open().await?;
        let ping: Ping = session.get(&Target::fixed("/util/ping")).await?.json()?;
        if ping.meta.id.is_empty() {
            return Err(HttpFailure::Unreadable.into());
        }
        checkpoint.bind_owner(feed::scope(&[&self.account, &ping.meta.id]))?;
        match checkpoint.scan.state.phase {
            Phase::Recent => {
                let since = feed::utc(checkpoint.scan.since);
                let first = Target::fixed(TRANSACTIONS).query("filter[since]", &since);
                self.list_page(&session, checkpoint, first, key, clock)
                    .await
            }
            // No lower bound here. If `filter[since]` compares `settledAt`,
            // this listing is the only place a new hold appears.
            Phase::Held => {
                let first = Target::fixed(TRANSACTIONS).query("filter[status]", "HELD");
                self.list_page(&session, checkpoint, first, key, clock)
                    .await
            }
            Phase::Departed => {
                let mut events = Vec::new();
                for (id, hold) in checkpoint.kept.unseen.take_oldest(LOOKUPS_PER_POLL) {
                    let found = match look_up(&session, &id).await {
                        Ok(found) => found,
                        Err(failure) => return Err(Stop::after(events, failure)),
                    };
                    let resolved = resolve(&mut checkpoint, id, hold, found, &key);
                    events.push(resolved.event);
                    if !resolved.within_cap {
                        return Err(Stop::after(events, FeedFailure::Fixed(TOO_MANY_HOLDS)));
                    }
                }
                let step = if checkpoint.kept.unseen.is_empty() {
                    finish(&mut checkpoint)
                } else {
                    Step::Next(None)
                };
                checkpoint.advance(key, events, step, clock())
            }
        }
    }

    async fn list_page(
        &self,
        session: &Session<'_>,
        mut checkpoint: Checkpoint,
        first: Target,
        key: SourceKey,
        clock: Clock<'_>,
    ) -> Result<SourceBatch, Stop> {
        let target = match &checkpoint.scan.cursor {
            Some(cursor) => saved_page(cursor)?,
            None => first.query("page[size]", feed::PAGE_SIZE),
        };
        let reply = session.get(&target).await?;
        // Only Up's own error body is a refusal. The same status with another
        // body proves nothing about the cursor, and is an ordinary failure.
        let refused = feed::cursor_refused(checkpoint.scan.cursor.is_some(), reply.status)
            && is_up_error(&reply);
        if refused {
            return if checkpoint.scan.restarted() {
                Err(FeedFailure::Fixed(REFUSED_AGAIN).into())
            } else {
                checkpoint.advance(key, Vec::new(), Step::Restart, clock())
            };
        }
        let page: Page = reply.json()?;
        let listed = list(&mut checkpoint, &page.data, &key);
        if let Some(failure) = listed.failure {
            return Err(Stop::after(listed.events, failure));
        }
        match after_listing(&mut checkpoint, page.links.next.as_deref(), &self.api) {
            Ok(step) => checkpoint.advance(key, listed.events, step, clock()),
            Err(failure) => Err(Stop::after(listed.events, failure)),
        }
    }

    #[cfg(test)]
    fn with_curl(mut self, program: String) -> Self {
        self.api = self.api.with_curl(program);
        self
    }

    #[cfg(test)]
    fn with_max_time(mut self, seconds: u32) -> Self {
        self.api = self.api.with_max_time(seconds);
        self
    }
}

#[async_trait::async_trait]
impl Source for UpSource {
    fn key(&self) -> SourceKey {
        SourceKey {
            provider: PROVIDER.into(),
            account: self.account.clone(),
        }
    }

    async fn poll(&self, checkpoint: Option<&SourceCheckpoint>) -> Result<SourceBatch> {
        let now = now_seconds()?;
        // The spacing of scans counts from the end of a scan, so the time is
        // read again after the last response.
        let after_response = || now_seconds().unwrap_or(now);
        let step = self.step(checkpoint, now, &after_response).await;
        Ok(feed::settle(LABEL, self.key(), step))
    }
}

type Checkpoint = FeedCheckpoint<Followed, UpScan>;

/// The transactions last seen as HELD.
///
/// The two sets are separate so that the cap counts what Up lists now. A hold
/// that left Up stays in `unseen` until its lookup, and takes no room from a
/// new hold. Both sets live outside the scan state, so a restarted scan
/// forgets neither.
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Followed {
    /// Followed since an earlier scan, and not returned yet by the scan in
    /// flight. Between scans, every followed hold is here.
    unseen: Holds,
    /// Returned as HELD by the scan in flight. Empty between scans.
    seen: Holds,
}

/// Holds by transaction id. Never more than `MAX_HOLDS`, with every summary
/// within its bound, also when it is read from a checkpoint.
#[derive(Default, Serialize, Deserialize)]
#[serde(try_from = "BTreeMap<TransactionId, Hold>")]
struct Holds(BTreeMap<TransactionId, Hold>);

impl TryFrom<BTreeMap<TransactionId, Hold>> for Holds {
    type Error = &'static str;

    fn try_from(holds: BTreeMap<TransactionId, Hold>) -> Result<Self, Self::Error> {
        let bounded = holds.len() <= MAX_HOLDS
            && holds.values().all(|hold| {
                hold.summary.chars().count() <= MAX_SUMMARY_CHARS
                    && !hold.summary.chars().any(char::is_control)
            });
        if bounded {
            Ok(Self(holds))
        } else {
            Err("holds outside their bounds")
        }
    }
}

impl Holds {
    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    fn remove(&mut self, id: &TransactionId) {
        self.0.remove(id);
    }

    /// Adds or replaces a hold. Returns false, and changes nothing, when the
    /// hold is new and the set is full.
    #[must_use]
    fn follow(&mut self, id: TransactionId, hold: Hold) -> bool {
        if self.0.len() >= MAX_HOLDS && !self.0.contains_key(&id) {
            return false;
        }
        self.0.insert(id, hold);
        true
    }

    /// Takes out up to `limit` holds, oldest first.
    fn take_oldest(&mut self, limit: usize) -> Vec<(TransactionId, Hold)> {
        let mut oldest: Vec<(u64, TransactionId)> = self
            .0
            .iter()
            .map(|(id, hold)| (hold.created_at, id.clone()))
            .collect();
        oldest.sort();
        oldest
            .into_iter()
            .take(limit)
            .filter_map(|(_, id)| self.0.remove_entry(&id))
            .collect()
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hold {
    /// Unix seconds. Bounds how far a removal reaches back.
    created_at: u64,
    /// "Example Cafe: -12.50 AUD". A removed hold has no body to read, so its
    /// event text comes from here.
    summary: String,
}

/// A transaction id: 1 to 128 ASCII letters, digits, hyphens and underscores.
/// Up documents UUIDs. An id is one segment of a request path and a key of the
/// checkpoint, so no other text is accepted from Up or from a checkpoint.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
struct TransactionId(String);

impl TransactionId {
    fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for TransactionId {
    type Error = &'static str;

    fn try_from(value: String) -> Result<Self, Self::Error> {
        let accepted = !value.is_empty()
            && value.len() <= MAX_ID_BYTES
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
        if accepted {
            Ok(Self(value))
        } else {
            Err("unusable transaction id")
        }
    }
}

impl From<TransactionId> for String {
    fn from(id: TransactionId) -> Self {
        id.0
    }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct UpScan {
    phase: Phase,
    /// The oldest creation time of a hold that this scan found removed.
    reach_back: Option<u64>,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    #[default]
    Recent,
    Held,
    Departed,
}

#[derive(Deserialize)]
struct Ping {
    meta: PingMeta,
}

#[derive(Deserialize)]
struct PingMeta {
    id: String,
}

/// `GET /transactions`. Items stay raw so one bad item does not hide its page.
#[derive(Deserialize)]
struct Page {
    data: Vec<serde_json::Value>,
    links: Links,
}

#[derive(Deserialize)]
struct Links {
    /// Present and `null` on the last page. A missing link is not an end.
    #[serde(deserialize_with = "Option::deserialize")]
    next: Option<String>,
}

/// `GET /transactions/{id}`.
#[derive(Deserialize)]
struct One {
    data: serde_json::Value,
}

/// Up's documented error body. Another body with the same status can come
/// from a proxy or a retired route, and proves nothing about a transaction or
/// a cursor. Up documents no text for a title or a detail, so only their type
/// is checked.
#[derive(Deserialize)]
struct ErrorBody {
    errors: Vec<ErrorObject>,
}

#[derive(Deserialize)]
struct ErrorObject {
    status: String,
    #[serde(rename = "title")]
    _title: String,
    #[serde(rename = "detail")]
    _detail: String,
}

/// True when the body is Up's error body and every entry names the status of the reply.
fn is_up_error(reply: &Reply) -> bool {
    let status = reply.status.to_string();
    reply.body_as::<ErrorBody>().is_some_and(|body| {
        !body.errors.is_empty() && body.errors.iter().all(|error| error.status == status)
    })
}

struct Transaction {
    id: TransactionId,
    status: Status,
    created_at: u64,
    settled_at: Option<u64>,
    description: String,
    amount: Option<Money>,
    foreign_amount: Option<Money>,
    /// `holdInfo.amount`, when the transaction is or was held.
    held_amount: Option<Money>,
    kind: Option<String>,
    message: Option<String>,
    between_own_accounts: bool,
}

/// Up documents HELD and SETTLED. Another value is shown as it is, and only
/// `Held` is followed as a hold.
#[derive(PartialEq, Eq)]
enum Status {
    Held,
    Settled,
    Other(String),
}

impl Status {
    fn label(&self) -> &str {
        match self {
            Self::Held => "held",
            Self::Settled => "settled",
            Self::Other(text) => text,
        }
    }
}

/// `value` and `currencyCode` as Up formats them, such as "-12.50" and "AUD".
#[derive(PartialEq, Eq)]
struct Money {
    value: String,
    currency: String,
}

impl std::fmt::Display for Money {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} {}", self.value, self.currency)
    }
}

/// Why an item is not a `Transaction`.
#[derive(Debug)]
enum Unread {
    /// No id, status or creation time. The other items of the page are delivered.
    Malformed,
    /// An id that is not a `TransactionId`. Nothing from its page is delivered.
    UnsafeId,
}

/// A wrong shape in a field other than the id, the status and the creation
/// time reads as absent. Category, tags and note are not read, because the
/// owner edits them and an edit is not an event.
fn parse(raw: &serde_json::Value) -> Result<Transaction, Unread> {
    let text = |pointer: &str| raw.pointer(pointer).and_then(serde_json::Value::as_str);
    let shown = |pointer: &str, max: usize| {
        text(pointer)
            .map(|value| feed::clip(value, max))
            .filter(|value| !value.is_empty())
    };
    let money = |pointer: &str| {
        Some(Money {
            value: shown(&format!("{pointer}/value"), 40)?,
            currency: shown(&format!("{pointer}/currencyCode"), 8)?,
        })
    };
    let id = TransactionId::try_from(text("/id").ok_or(Unread::Malformed)?.to_owned())
        .map_err(|_| Unread::UnsafeId)?;
    let status = match shown("/attributes/status", 40)
        .ok_or(Unread::Malformed)?
        .as_str()
    {
        "HELD" => Status::Held,
        "SETTLED" => Status::Settled,
        other => Status::Other(other.to_owned()),
    };
    let created_at = text("/attributes/createdAt")
        .and_then(parse_timestamp_ms)
        .ok_or(Unread::Malformed)?
        / 1000;
    Ok(Transaction {
        id,
        status,
        created_at,
        settled_at: text("/attributes/settledAt")
            .and_then(parse_timestamp_ms)
            .map(|milliseconds| milliseconds / 1000),
        description: shown("/attributes/description", 120).unwrap_or_else(|| "Transaction".into()),
        amount: money("/attributes/amount"),
        foreign_amount: money("/attributes/foreignAmount"),
        held_amount: money("/attributes/holdInfo/amount"),
        kind: shown("/attributes/transactionType", 60),
        message: shown("/attributes/message", 240),
        between_own_accounts: raw
            .pointer("/relationships/transferAccount/data")
            .is_some_and(|account| !account.is_null()),
    })
}

/// The saved continuation of a listing. A cursor that no longer names the
/// transactions listing is not sent.
fn saved_page(cursor: &Cursor) -> Result<Target, FeedFailure> {
    Target::try_from(cursor.as_str().to_owned())
        .ok()
        .filter(|target| target.path() == TRANSACTIONS)
        .ok_or(FeedFailure::BadCursor)
}

struct Listed {
    events: Vec<SourceEvent>,
    failure: Option<FeedFailure>,
}

/// Applies one page of either listing. Every item the feed covers becomes an
/// event, because the runtime ignores a repeat. A held item is followed, and
/// an item with another status is no longer followed.
fn list(checkpoint: &mut Checkpoint, items: &[serde_json::Value], key: &SourceKey) -> Listed {
    let mut transactions = Vec::new();
    let mut malformed = 0;
    for raw in items {
        match parse(raw) {
            Ok(transaction) => transactions.push(transaction),
            Err(Unread::Malformed) => malformed += 1,
            Err(Unread::UnsafeId) => {
                return Listed {
                    events: Vec::new(),
                    failure: Some(HttpFailure::Unreadable.into()),
                };
            }
        }
    }
    let mut events = Vec::new();
    let mut too_many_holds = false;
    for transaction in transactions {
        if !checkpoint.covers(transaction.created_at) {
            continue;
        }
        events.push(describe(&transaction).into_event(key));
        checkpoint.kept.unseen.remove(&transaction.id);
        if transaction.status != Status::Held {
            checkpoint.kept.seen.remove(&transaction.id);
            continue;
        }
        let hold = Hold {
            created_at: transaction.created_at,
            summary: summarize(&transaction),
        };
        if !checkpoint.kept.seen.follow(transaction.id, hold) {
            too_many_holds = true;
        }
    }
    let failure = if malformed > 0 {
        Some(FeedFailure::Malformed { count: malformed })
    } else if too_many_holds {
        Some(FeedFailure::Fixed(TOO_MANY_HOLDS))
    } else {
        None
    };
    Listed { events, failure }
}

/// What follows a clean page: its next page, the next listing, the lookups, or the end.
fn after_listing(
    checkpoint: &mut Checkpoint,
    next: Option<&str>,
    api: &HttpApi,
) -> Result<Step, FeedFailure> {
    if let Some(link) = next {
        // The token goes to this link, so it must be the listing on the configured address.
        let target = api
            .target_of(link)
            .filter(|target| target.path() == TRANSACTIONS)
            .ok_or(FeedFailure::BadCursor)?;
        let cursor =
            Cursor::try_from(target.as_str().to_owned()).map_err(|_| FeedFailure::BadCursor)?;
        return Ok(Step::Next(Some(cursor)));
    }
    let departed = !checkpoint.kept.unseen.is_empty();
    Ok(match checkpoint.scan.state.phase {
        Phase::Recent => {
            checkpoint.scan.state.phase = Phase::Held;
            Step::Next(None)
        }
        _ if departed => {
            checkpoint.scan.state.phase = Phase::Departed;
            Step::Next(None)
        }
        _ => finish(checkpoint),
    })
}

/// Ends the scan. Both listings are read and every hold that left them is
/// looked up, so the holds this scan saw are the followed holds.
fn finish(checkpoint: &mut Checkpoint) -> Step {
    checkpoint.kept.unseen = std::mem::take(&mut checkpoint.kept.seen);
    Step::Done {
        floor: checkpoint.scan.state.reach_back,
    }
}

/// The current state of one transaction. `None` when Up answers 404 with its
/// documented error body, which means that the transaction no longer exists.
async fn look_up(
    session: &Session<'_>,
    id: &TransactionId,
) -> Result<Option<Transaction>, FeedFailure> {
    let reply = session
        .get(&Target::fixed(TRANSACTIONS).segment(id.as_str()))
        .await?;
    if reply.status == 404 {
        return if is_up_error(&reply) {
            Ok(None)
        } else {
            Err(HttpFailure::Status(404).into())
        };
    }
    let one: One = reply.json()?;
    match parse(&one.data) {
        Ok(transaction) if transaction.id == *id => Ok(Some(transaction)),
        _ => Err(FeedFailure::Malformed { count: 1 }),
    }
}

struct Resolved {
    event: SourceEvent,
    /// False when the hold is still held and the scan already saw `MAX_HOLDS` others.
    within_cap: bool,
}

/// Settles one departed hold and returns its event.
///
/// Up says a settlement can arrive as a delete and a create, and does not say
/// what id or creation time the new transaction has. So after a removal the
/// next scan reads again from the removed hold's creation time, and a
/// replacement that carries the old time is inside the window.
///
/// The removal text comes from the saved `summary`, so a repeat of this call
/// for the same checkpoint builds an equal event.
fn resolve(
    checkpoint: &mut Checkpoint,
    id: TransactionId,
    hold: Hold,
    found: Option<Transaction>,
    key: &SourceKey,
) -> Resolved {
    match found {
        Some(transaction) => {
            let event = describe(&transaction).into_event(key);
            // Still held: the listing changed while this scan read it.
            let within_cap = transaction.status != Status::Held
                || checkpoint.kept.seen.follow(
                    id,
                    Hold {
                        created_at: transaction.created_at,
                        summary: summarize(&transaction),
                    },
                );
            Resolved { event, within_cap }
        }
        None => {
            let floor = hold.created_at.max(
                checkpoint
                    .scan
                    .started_at
                    .saturating_sub(MAX_REACH_BACK_SECONDS),
            );
            let state = &mut checkpoint.scan.state;
            state.reach_back = Some(state.reach_back.map_or(floor, |earlier| earlier.min(floor)));
            Resolved {
                event: describe_removed(id, &hold).into_event(key),
                within_cap: true,
            }
        }
    }
}

/// The status is in the title and in the text, so a change of status is a new
/// version. Times are printed from the parsed value, so a change in Up's
/// formatting is not.
fn describe(transaction: &Transaction) -> FeedItem {
    let status = transaction.status.label();
    let mut lines = vec![format!("Status: {status}")];
    if let Some(amount) = &transaction.amount {
        lines.push(format!("Amount: {amount}"));
    }
    if let Some(foreign) = &transaction.foreign_amount {
        lines.push(format!("Foreign amount: {foreign}"));
    }
    if let Some(held) = &transaction.held_amount
        && transaction.status != Status::Held
        && transaction.amount.as_ref() != Some(held)
    {
        lines.push(format!("Held at: {held}"));
    }
    if let Some(kind) = &transaction.kind {
        lines.push(format!("Type: {kind}"));
    }
    if let Some(message) = &transaction.message {
        lines.push(format!("Message: {message}"));
    }
    if transaction.between_own_accounts {
        lines.push("Between own accounts: yes".into());
    }
    lines.push(format!("Created: {}", feed::utc(transaction.created_at)));
    if let Some(settled_at) = transaction.settled_at {
        lines.push(format!("Settled: {}", feed::utc(settled_at)));
    }
    FeedItem {
        id: transaction.id.as_str().to_owned(),
        title: format!("{} ({status})", summarize(transaction)),
        text: lines.join("\n"),
        occurred_at: Some(transaction.created_at.saturating_mul(1000)),
    }
}

fn summarize(transaction: &Transaction) -> String {
    let summary = match &transaction.amount {
        Some(amount) => format!("{}: {amount}", transaction.description),
        None => transaction.description.clone(),
    };
    feed::clip(&summary, MAX_SUMMARY_CHARS)
}

/// The text does not say "refunded" or "settled", because Up does not say which happened.
fn describe_removed(id: TransactionId, hold: &Hold) -> FeedItem {
    FeedItem {
        id: id.into(),
        title: format!("{} (hold removed)", hold.summary),
        text: "Status: hold removed\nUp no longer lists this held transaction. Up removes a hold when the merchant releases it, or when Up replaces it with a separate settled transaction.".into(),
        occurred_at: None,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        collections::BTreeSet,
        sync::{
            Arc, Mutex,
            atomic::{AtomicBool, AtomicU64, Ordering},
        },
    };

    use serde_json::{Value, json};

    use super::*;
    use crate::{
        background::{self, BackgroundRequest, BackgroundResponse},
        protocol::{HostResult, SourceState},
        sources::{
            SourceConfig, SourceCoverage,
            feed::ScanMemory,
            http::testing::{
                Canned, FakeApi, Seen, credential_script, curl_shim, failing_credential_script,
                proxied_curl, query_of, shim_runs,
            },
        },
    };

    const NOW: u64 = 1_795_000_000;
    const HOUR: u64 = 3_600;
    const DAY: u64 = 86_400;
    const SPACING: u64 = 300;
    const TOKEN: &str = "example-up-token";
    const SECOND_TOKEN: &str = "example-second-up-token";
    const REFUSED_AGAIN: &str =
        "Up refused a saved page link for the second time in one scan; checkpoint retained.";
    const UNREADABLE: &str = "Up sent a response this source cannot read; checkpoint retained.";
    const FOREIGN: &str = "Up checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read.";
    const CLOCK_DIFFERS: &str = "This computer's clock differs from Up's clock by more than five minutes; check the clock. Checkpoint retained.";
    const NO_DATE: &str = "Up's reply carried no usable Date header; checkpoint retained.";
    const REMOVED_TEXT: &str = "Status: hold removed\nUp no longer lists this held transaction. Up removes a hold when the merchant releases it, or when Up replaces it with a separate settled transaction.";

    #[derive(Clone)]
    struct Row {
        id: String,
        status: &'static str,
        created: u64,
        settled: Option<u64>,
        description: &'static str,
        amount: &'static str,
        held_amount: Option<&'static str>,
    }

    fn held(id: &str, description: &'static str, amount: &'static str, created: u64) -> Row {
        Row {
            id: id.into(),
            status: "HELD",
            created,
            settled: None,
            description,
            amount,
            held_amount: Some(amount),
        }
    }

    fn settled(id: &str, description: &'static str, amount: &'static str, created: u64) -> Row {
        Row {
            id: id.into(),
            status: "SETTLED",
            created,
            settled: Some(created + 60),
            description,
            amount,
            held_amount: None,
        }
    }

    /// Up prints times with an Australian offset.
    fn offset_time(seconds: u64) -> String {
        chrono::DateTime::from_timestamp(i64::try_from(seconds).unwrap(), 0)
            .unwrap()
            .with_timezone(&chrono::FixedOffset::east_opt(10 * 3_600).unwrap())
            .to_rfc3339()
    }

    impl Row {
        fn json(&self) -> Value {
            let money = |value: &str| json!({ "currencyCode": "AUD", "value": value, "valueInBaseUnits": 0 });
            json!({
                "type": "transactions",
                "id": self.id,
                "attributes": {
                    "status": self.status,
                    "rawText": null,
                    "description": self.description,
                    "message": null,
                    "isCategorizable": true,
                    "holdInfo": self.held_amount.map(|value| json!({ "amount": money(value), "foreignAmount": null })),
                    "amount": money(self.amount),
                    "foreignAmount": null,
                    "transactionType": "Purchase",
                    "settledAt": self.settled.map(offset_time),
                    "createdAt": offset_time(self.created),
                },
                "relationships": {
                    "account": { "data": { "type": "accounts", "id": "example-account-1" } },
                    "transferAccount": { "data": null },
                    "category": { "data": { "type": "categories", "id": "example-category" } },
                    "tags": { "data": [] }
                }
            })
        }
    }

    type Script = Box<dyn Fn(&Seen) -> Option<Canned> + Send>;

    enum Dates {
        /// One header with the bank's time, as Up sends.
        Single,
        Missing,
        Duplicated,
        Text(&'static str),
    }

    fn http_date(seconds: u64) -> String {
        chrono::DateTime::from_timestamp(i64::try_from(seconds).unwrap(), 0)
            .unwrap()
            .format("%a, %d %b %Y %H:%M:%S GMT")
            .to_string()
    }

    /// The state of the invented Up account. A test edits it between polls.
    struct World {
        rows: Vec<Row>,
        customer: &'static str,
        /// The transactions of a second customer, whose token is `SECOND_TOKEN`.
        second_customer: Option<Vec<Row>>,
        /// What the credential command of the next adapter prints.
        credential: &'static str,
        since_compares_settled_at: bool,
        page_size: usize,
        /// Answers a request before the account does, for a failure the account cannot produce.
        script: Option<Script>,
        /// The wall clock and the monotonic clock of the computer when the
        /// poll in flight began. `None` for a poll on the real clocks.
        poll_began: Option<(u64, u64)>,
        /// The bank's clock when the poll in flight began. `None` when it
        /// agrees with the computer's wall clock.
        bank_time: Option<u64>,
        /// Seconds that pass before each identity check reaches the bank, as
        /// when the credential command is slow.
        credential_seconds: u64,
        dates: Dates,
    }

    impl World {
        fn answer(&self, seen: &Seen) -> Canned {
            if let Some(canned) = self.script.as_ref().and_then(|script| script(seen)) {
                return canned;
            }
            let (customer, rows) = match (seen.bearer.as_deref(), &self.second_customer) {
                (Some(TOKEN), _) => (self.customer, &self.rows),
                (Some(SECOND_TOKEN), Some(rows)) => ("example-customer-2", rows),
                _ => return up_error(401, "Not Authorized"),
            };
            match seen.path() {
                "/util/ping" => Canned::json(
                    200,
                    json!({ "meta": { "id": customer, "statusEmoji": "⚡️" } }),
                ),
                "/transactions" => self.listing(rows, seen),
                path => path
                    .strip_prefix("/transactions/")
                    .and_then(|id| rows.iter().find(|row| row.id == id))
                    .map_or_else(
                        || up_error(404, "Not Found"),
                        |row| Canned::json(200, json!({ "data": row.json() })),
                    ),
            }
        }

        /// The bank's clock runs with the monotonic clock of the computer.
        fn dated(&self, canned: Canned, monotonic: u64) -> Canned {
            let bank = match self.poll_began {
                Some((wall, began)) => self.bank_time.unwrap_or(wall) + (monotonic - began),
                None => now_seconds().unwrap(),
            };
            let date = http_date(bank);
            match self.dates {
                Dates::Single => canned.header("Date", &date),
                Dates::Missing => canned,
                Dates::Duplicated => canned.header("Date", &date).header("Date", &date),
                Dates::Text(text) => canned.header("Date", text),
            }
        }

        fn settle(&mut self, id: &str, amount: &'static str, at: u64) {
            let row = self.rows.iter_mut().find(|row| row.id == id).unwrap();
            row.status = "SETTLED";
            row.settled = Some(at);
            row.amount = amount;
        }

        fn delete(&mut self, id: &str) {
            self.rows.retain(|row| row.id != id);
        }

        fn listing(&self, rows: &[Row], seen: &Seen) -> Canned {
            let since_text = seen.query("filter[since]");
            let since = since_text
                .as_deref()
                .map(|text| parse_timestamp_ms(text).unwrap() / 1000);
            let status = seen.query("filter[status]");
            let after: usize = seen
                .query("page[after]")
                .map_or(0, |offset| offset.parse().unwrap());
            let mut rows: Vec<&Row> = rows
                .iter()
                .filter(|row| status.as_deref().is_none_or(|status| row.status == status))
                .filter(|row| {
                    since.is_none_or(|since| {
                        if self.since_compares_settled_at {
                            row.settled.is_some_and(|settled| settled >= since)
                        } else {
                            row.created >= since
                        }
                    })
                })
                .collect();
            rows.sort_by(|left, right| {
                right
                    .created
                    .cmp(&left.created)
                    .then(left.id.cmp(&right.id))
            });
            let data: Vec<Value> = rows
                .iter()
                .skip(after)
                .take(self.page_size)
                .map(|row| row.json())
                .collect();
            let next = (after + self.page_size < rows.len()).then(|| {
                let mut link = format!(
                    "http://{}/transactions?page[after]={}&page[size]={}",
                    seen.header("host").unwrap(),
                    after + self.page_size,
                    self.page_size
                );
                if let Some(text) = &since_text {
                    link += &format!("&filter[since]={}", text.replace(':', "%3A"));
                }
                if let Some(status) = &status {
                    link += &format!("&filter[status]={status}");
                }
                link
            });
            Canned::json(
                200,
                json!({ "data": data, "links": { "prev": null, "next": next } }),
            )
        }
    }

    fn up_error(status: u16, title: &str) -> Canned {
        Canned::json(
            status,
            json!({ "errors": [{ "status": status.to_string(), "title": title, "detail": "example-private-detail" }] }),
        )
    }

    struct Harness {
        api: FakeApi,
        world: Arc<Mutex<World>>,
        dir: tempfile::TempDir,
        /// The monotonic clock of the computer, in seconds. It moves only in `pass`.
        monotonic: Arc<AtomicU64>,
        /// What the coordinator process remembers. `restart` forgets it.
        process: Mutex<Arc<ScanMemory>>,
    }

    impl Harness {
        async fn start(rows: Vec<Row>) -> Self {
            let world = Arc::new(Mutex::new(World {
                rows,
                customer: "example-customer-1",
                second_customer: None,
                credential: TOKEN,
                since_compares_settled_at: false,
                page_size: 100,
                script: None,
                poll_began: None,
                bank_time: None,
                credential_seconds: 0,
                dates: Dates::Single,
            }));
            let monotonic = Arc::new(AtomicU64::new(0));
            let (account, clock) = (world.clone(), monotonic.clone());
            let api = FakeApi::start(move |seen| {
                let world = account.lock().unwrap();
                if seen.path() == "/util/ping" {
                    clock.fetch_add(world.credential_seconds, Ordering::Relaxed);
                }
                world.dated(world.answer(seen), clock.load(Ordering::Relaxed))
            })
            .await;
            Self {
                api,
                world,
                dir: tempfile::tempdir().unwrap(),
                monotonic,
                process: Mutex::default(),
            }
        }

        /// Time passes on the monotonic clock. The wall clock is the `now` of the next poll.
        fn pass(&self, seconds: u64) {
            self.monotonic.fetch_add(seconds, Ordering::Relaxed);
        }

        fn restart(&self) {
            *self.process.lock().unwrap() = Arc::default();
        }

        fn world(&self) -> std::sync::MutexGuard<'_, World> {
            self.world.lock().unwrap()
        }

        fn script(&self, script: impl Fn(&Seen) -> Option<Canned> + Send + 'static) {
            self.world().script = Some(Box::new(script));
        }

        /// A new adapter, as the coordinator builds one for every page.
        fn source(&self) -> UpSource {
            let token = self.world().credential;
            UpSource::new(
                "everyday".into(),
                Some(self.api.url.clone()),
                credential_script(self.dir.path(), token),
            )
            .unwrap()
        }

        /// Polls from `saved` until a poll asks for a transactions listing, and
        /// returns that poll's batch.
        async fn poll_to_listing(&self, saved: Option<&SourceCheckpoint>, now: u64) -> SourceBatch {
            let mut saved = saved.cloned();
            loop {
                let mark = self.targets().len();
                let batch = self.poll(saved.as_ref(), now).await;
                let listed = self
                    .targets_since(mark)
                    .iter()
                    .any(|target| target.starts_with("/transactions?"));
                if listed {
                    return batch;
                }
                assert_eq!(batch.coverage, SourceCoverage::More);
                saved = batch.checkpoint;
            }
        }

        /// Polls a scan from `saved` until its next poll looks up the holds that
        /// left the held listing. Returns the checkpoint for that poll.
        async fn poll_to_lookups(&self, saved: &SourceCheckpoint, now: u64) -> SourceCheckpoint {
            let mut saved = saved.clone();
            loop {
                let batch = self.poll(Some(&saved), now).await;
                assert_eq!(batch.coverage, SourceCoverage::More);
                saved = batch.checkpoint.unwrap();
                let held_listing = self
                    .targets()
                    .last()
                    .is_some_and(|target| target.contains("filter[status]=HELD"));
                if held_listing {
                    return saved;
                }
            }
        }

        /// The lower bound of the first recent listing requested since `mark`.
        fn since_requested_after(&self, mark: usize) -> String {
            let requested = self.targets_since(mark);
            let recent = requested
                .iter()
                .find(|target| target.contains("filter[since]"))
                .expect("no recent listing was requested");
            since_of(recent)
        }

        async fn poll(&self, saved: Option<&SourceCheckpoint>, now: u64) -> SourceBatch {
            self.poll_with(&self.source(), saved, now).await
        }

        async fn poll_with(
            &self,
            source: &UpSource,
            saved: Option<&SourceCheckpoint>,
            now: u64,
        ) -> SourceBatch {
            let monotonic = || self.monotonic.load(Ordering::Relaxed);
            self.world().poll_began = Some((now, monotonic()));
            let process = self.process.lock().unwrap().clone();
            source.poll_at(saved, now, &monotonic, &process).await
        }

        /// Polls until the scan completes. Returns its events and the last checkpoint.
        async fn scan(
            &self,
            saved: Option<&SourceCheckpoint>,
            now: u64,
        ) -> (Vec<SourceEvent>, SourceCheckpoint) {
            self.scan_with(&|| self.source(), saved, now).await
        }

        async fn scan_with(
            &self,
            source: &dyn Fn() -> UpSource,
            saved: Option<&SourceCheckpoint>,
            now: u64,
        ) -> (Vec<SourceEvent>, SourceCheckpoint) {
            let mut saved = saved.cloned();
            let mut events = Vec::new();
            for _ in 0..40 {
                let batch = self.poll_with(&source(), saved.as_ref(), now).await;
                events.extend(batch.events);
                match batch.coverage {
                    SourceCoverage::More => saved = batch.checkpoint,
                    SourceCoverage::Complete => return (events, batch.checkpoint.unwrap()),
                    failure => panic!("the scan stopped: {failure:?}"),
                }
            }
            panic!("the scan did not complete");
        }

        fn targets(&self) -> Vec<String> {
            self.api
                .seen()
                .into_iter()
                .map(|seen| seen.target)
                .collect()
        }

        /// The targets requested since `mark` requests had been made.
        fn targets_since(&self, mark: usize) -> Vec<String> {
            self.targets().split_off(mark)
        }
    }

    fn unavailable(message: &str) -> SourceCoverage {
        SourceCoverage::Unavailable {
            message: message.into(),
        }
    }

    fn partial(message: &str) -> SourceCoverage {
        SourceCoverage::Partial {
            message: message.into(),
        }
    }

    fn titles(events: &[SourceEvent]) -> Vec<&str> {
        events.iter().map(|event| event.title.as_str()).collect()
    }

    fn content(events: &[SourceEvent]) -> Vec<(&str, &str, &str, &str, &str)> {
        events
            .iter()
            .map(|event| {
                (
                    event.id.as_str(),
                    event.version.as_str(),
                    event.source.thread_id.as_str(),
                    event.title.as_str(),
                    event.text.as_str(),
                )
            })
            .collect()
    }

    fn since_of(target: &str) -> String {
        query_of(target, "filter[since]").unwrap()
    }

    #[tokio::test]
    async fn the_first_scan_pings_reads_seven_days_then_lists_holds_and_completes() {
        let up = Harness::start(vec![
            held(
                "example-transaction-2",
                "Example Books",
                "-30.00",
                NOW - HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-12.50",
                NOW - 2 * DAY,
            ),
            settled(
                "example-transaction-0",
                "Example Hardware",
                "-99.00",
                NOW - 8 * DAY,
            ),
        ])
        .await;

        let recent = up.poll(None, NOW).await;
        assert_eq!(recent.coverage, SourceCoverage::More);
        assert_eq!(
            titles(&recent.events),
            [
                "Example Books: -30.00 AUD (held)",
                "Example Cafe: -12.50 AUD (settled)"
            ]
        );
        let holds = up.poll(recent.checkpoint.as_ref(), NOW).await;
        assert_eq!(holds.coverage, SourceCoverage::Complete);
        assert_eq!(content(&holds.events), content(&recent.events[..1]));

        let cafe = &recent.events[1];
        assert_eq!(cafe.id, "example-transaction-1");
        assert_eq!(cafe.source.provider, "up");
        assert_eq!(cafe.source.account, "everyday");
        assert_eq!(cafe.source.thread_id, "example-transaction-1");
        assert_eq!(
            cafe.text,
            format!(
                "Status: settled\nAmount: -12.50 AUD\nType: Purchase\nCreated: {}\nSettled: {}",
                feed::utc(NOW - 2 * DAY),
                feed::utc(NOW - 2 * DAY + 60)
            )
        );
        assert_eq!(cafe.occurred_at, Some((NOW - 2 * DAY) * 1000));

        assert_eq!(
            up.targets(),
            [
                "/util/ping".to_owned(),
                format!(
                    "/transactions?filter[since]={}&page[size]=100",
                    feed::utc(NOW - 7 * DAY).replace(':', "%3A")
                ),
                "/util/ping".to_owned(),
                "/transactions?filter[status]=HELD&page[size]=100".to_owned(),
            ],
            "an idle scan is four requests: the identity check before each listing"
        );
        assert!(
            up.api
                .seen()
                .iter()
                .all(|seen| seen.bearer.as_deref() == Some(TOKEN))
        );
        let saved = holds.checkpoint.unwrap().value;
        for private in ["example-customer-1", TOKEN, "127.0.0.1"] {
            assert!(!saved.contains(private), "the checkpoint holds {private}");
        }
    }

    #[tokio::test]
    async fn a_transaction_held_and_then_settled_gets_a_new_version_of_the_same_id() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Cafe",
            "-12.50",
            NOW - 3 * DAY,
        )])
        .await;
        let (first, saved) = up.scan(None, NOW).await;
        let held = &first[0];
        assert_eq!(held.title, "Example Cafe: -12.50 AUD (held)");
        // The daily reread, before the settlement, so the scan below reads one day.
        let (_, saved) = up.scan(Some(&saved), NOW + 2 * DAY).await;

        up.world()
            .settle("example-transaction-1", "-13.10", NOW + 2 * DAY);
        let mark = up.targets().len();
        let later = NOW + 2 * DAY + SPACING;
        let (second, saved) = up.scan(Some(&saved), later).await;

        assert_eq!(
            up.targets_since(mark).last().map(String::as_str),
            Some("/transactions/example-transaction-1"),
            "the creation time left the window, so the hold is looked up"
        );
        assert_eq!(second.len(), 1);
        let settled = &second[0];
        assert_eq!(settled.id, held.id);
        assert_ne!(settled.version, held.version);
        assert_eq!(settled.title, "Example Cafe: -13.10 AUD (settled)");
        assert_eq!(
            settled.text,
            format!(
                "Status: settled\nAmount: -13.10 AUD\nHeld at: -12.50 AUD\nType: Purchase\nCreated: {}\nSettled: {}",
                feed::utc(NOW - 3 * DAY),
                feed::utc(NOW + 2 * DAY)
            )
        );

        let mark = up.targets().len();
        let (third, _) = up.scan(Some(&saved), later + SPACING).await;
        assert!(third.is_empty());
        assert_eq!(
            up.targets_since(mark).len(),
            4,
            "a settled transaction is no longer followed"
        );
    }

    #[tokio::test]
    async fn a_held_transaction_that_is_deleted_is_reported_once_as_hold_removed() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (first, saved) = up.scan(None, NOW).await;

        up.world().delete("example-transaction-1");
        let later = NOW + 2 * DAY + SPACING;
        let (second, saved) = up.scan(Some(&saved), later).await;

        assert_eq!(second.len(), 1);
        let removed = &second[0];
        assert_eq!(removed.id, first[0].id);
        assert_ne!(removed.version, first[0].version);
        assert_eq!(removed.title, "Example Hotel: -200.00 AUD (hold removed)");
        assert_eq!(removed.text, REMOVED_TEXT);
        assert_eq!(removed.occurred_at, None);

        let mark = up.targets().len();
        let (third, _) = up.scan(Some(&saved), later + SPACING).await;
        assert!(third.is_empty(), "the removal is reported once");
        let requested = up.targets_since(mark);
        assert_eq!(requested.len(), 4, "a removed hold is not looked up again");
        assert_eq!(
            since_of(&requested[1]),
            feed::utc(NOW - 4 * DAY),
            "the next scan reads again from a day before the removed hold was created"
        );
    }

    #[tokio::test]
    async fn a_settlement_that_arrives_as_a_delete_and_a_backdated_create_delivers_both() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;

        up.world().delete("example-transaction-1");
        up.world().rows.push(settled(
            "example-transaction-2",
            "Example Hotel",
            "-180.00",
            NOW - 3 * DAY,
        ));
        let later = NOW + SPACING;
        let (second, saved) = up.scan(Some(&saved), later).await;
        assert_eq!(
            titles(&second),
            ["Example Hotel: -200.00 AUD (hold removed)"]
        );

        let (third, _) = up.scan(Some(&saved), later + SPACING).await;
        assert_eq!(titles(&third), ["Example Hotel: -180.00 AUD (settled)"]);
        assert_eq!(third[0].id, "example-transaction-2");
    }

    #[tokio::test]
    async fn a_removed_hold_reaches_back_no_further_than_sixty_days() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;

        up.world().delete("example-transaction-1");
        let later = NOW + 100 * DAY;
        let (second, saved) = up.scan(Some(&saved), later).await;
        assert_eq!(
            titles(&second),
            ["Example Hotel: -200.00 AUD (hold removed)"]
        );

        let mark = up.targets().len();
        up.scan(Some(&saved), later + SPACING).await;
        assert_eq!(
            since_of(&up.targets_since(mark)[1]),
            feed::utc(later - 61 * DAY)
        );
    }

    #[tokio::test]
    async fn a_since_filter_that_compares_settled_at_still_delivers_holds_and_their_settlement() {
        let up = Harness::start(vec![
            held(
                "example-transaction-2",
                "Example Books",
                "-30.00",
                NOW - 2 * DAY,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-12.50",
                NOW - 3 * DAY,
            ),
        ])
        .await;
        up.world().since_compares_settled_at = true;

        let (first, saved) = up.scan(None, NOW).await;
        assert_eq!(
            titles(&first),
            [
                "Example Cafe: -12.50 AUD (settled)",
                "Example Books: -30.00 AUD (held)"
            ],
            "the hold has no settledAt, so only the HELD listing returns it"
        );

        up.world()
            .settle("example-transaction-2", "-30.00", NOW + HOUR);
        let mark = up.targets().len();
        let (second, _) = up.scan(Some(&saved), NOW + HOUR + SPACING).await;

        assert_eq!(titles(&second), ["Example Books: -30.00 AUD (settled)"]);
        assert_eq!(second[0].id, first[1].id);
        assert_ne!(second[0].version, first[1].version);
        assert_eq!(
            up.targets_since(mark).len(),
            4,
            "the window listed the settlement, so no lookup is needed"
        );
    }

    #[tokio::test]
    async fn a_transaction_created_before_the_first_seven_days_is_neither_emitted_nor_followed() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Deposit",
            "-500.00",
            NOW - 9 * DAY,
        )])
        .await;
        let (first, saved) = up.scan(None, NOW).await;
        assert!(first.is_empty());

        up.world().delete("example-transaction-1");
        let mark = up.targets().len();
        let (second, _) = up.scan(Some(&saved), NOW + SPACING).await;
        assert!(second.is_empty());
        assert_eq!(up.targets_since(mark).len(), 4, "nothing is looked up");
    }

    #[tokio::test]
    async fn three_pages_with_a_failure_on_the_second_resume_at_the_second_page() {
        let rows = (1..=5)
            .map(|number| {
                settled(
                    &format!("example-transaction-{number}"),
                    "Example Cafe",
                    "-5.00",
                    NOW - number * HOUR,
                )
            })
            .collect();
        let up = Harness::start(rows).await;
        up.world().page_size = 2;

        let first = up.poll(None, NOW).await;
        assert_eq!(first.coverage, SourceCoverage::More);
        assert_eq!(first.events.len(), 2);

        up.script(|seen| {
            (seen.query("page[after]").as_deref() == Some("2"))
                .then(|| up_error(500, "Server Error"))
        });
        for _ in 0..2 {
            let failed = up.poll(first.checkpoint.as_ref(), NOW + 60).await;
            assert_eq!(
                failed.coverage,
                unavailable("Up API returned HTTP 500; checkpoint retained.")
            );
            assert!(failed.checkpoint.is_none());
            assert!(failed.events.is_empty());
        }

        up.world().script = None;
        let second = up.poll(first.checkpoint.as_ref(), NOW + 120).await;
        assert_eq!(second.coverage, SourceCoverage::More);
        let (rest, _) = up.scan(second.checkpoint.as_ref(), NOW + 120).await;

        let mut delivered: Vec<&str> = first
            .events
            .iter()
            .chain(&second.events)
            .chain(&rest)
            .map(|event| event.id.as_str())
            .collect();
        delivered.sort();
        assert_eq!(
            delivered,
            [
                "example-transaction-1",
                "example-transaction-2",
                "example-transaction-3",
                "example-transaction-4",
                "example-transaction-5"
            ]
        );
        let pages: Vec<Option<String>> = up
            .api
            .seen()
            .iter()
            .filter(|seen| seen.query("filter[status]").is_none() && seen.path() == "/transactions")
            .map(|seen| seen.query("page[after]"))
            .collect();
        assert_eq!(
            pages,
            [
                None,
                Some("2".into()),
                Some("2".into()),
                Some("2".into()),
                Some("4".into())
            ],
            "the failed page is asked for again and the first page is not"
        );
    }

    #[tokio::test]
    async fn an_adapter_rebuilt_between_pages_continues_at_the_saved_page() {
        let up = Harness::start(vec![
            settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;

        let mut saved = None;
        let mut delivered = Vec::new();
        for _ in 0..2 {
            let adapter = up.source();
            let batch = up.poll_with(&adapter, saved.as_ref(), NOW).await;
            drop(adapter);
            assert_eq!(batch.coverage, SourceCoverage::More);
            delivered.extend(batch.events);
            saved = batch.checkpoint;
        }

        assert_eq!(
            titles(&delivered),
            [
                "Example Cafe: -5.00 AUD (settled)",
                "Example Books: -7.00 AUD (settled)"
            ]
        );
        let requested = up.api.seen();
        assert_eq!(requested[3].query("page[after]").as_deref(), Some("1"));
    }

    #[tokio::test]
    async fn the_same_poll_twice_gives_equal_ids_versions_and_text() {
        let up = Harness::start(vec![
            held(
                "example-transaction-3",
                "Example Hotel",
                "-200.00",
                NOW - 3 * DAY,
            ),
            held(
                "example-transaction-2",
                "Example Books",
                "-30.00",
                NOW - 2 * DAY,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-12.50",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        let (_, mut saved) = up.scan(None, NOW).await;
        up.world().delete("example-transaction-3");
        up.world()
            .settle("example-transaction-2", "-31.00", NOW + DAY);

        let later = NOW + 2 * DAY;
        let mut compared = 0;
        loop {
            let once = up.poll(Some(&saved), later).await;
            let again = up.poll(Some(&saved), later + 7).await;
            assert_eq!(content(&once.events), content(&again.events));
            assert_eq!(once.coverage, again.coverage);
            compared += once.events.len();
            saved = once.checkpoint.unwrap();
            if once.coverage == SourceCoverage::Complete {
                break;
            }
        }
        assert_eq!(
            compared, 3,
            "a listed transaction, a settlement by lookup and a removal"
        );
    }

    #[tokio::test]
    async fn a_failed_lookup_keeps_the_checkpoint_and_the_repeat_gives_equal_events() {
        let up = Harness::start(vec![
            held(
                "example-transaction-1",
                "Example Hotel",
                "-200.00",
                NOW - 3 * DAY,
            ),
            held(
                "example-transaction-2",
                "Example Motel",
                "-90.00",
                NOW - 2 * DAY,
            ),
        ])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().delete("example-transaction-1");
        up.world().delete("example-transaction-2");

        let later = NOW + 2 * DAY;
        let recent = up.poll(Some(&saved), later).await;
        let holds = up.poll(recent.checkpoint.as_ref(), later).await;
        assert_eq!(holds.coverage, SourceCoverage::More);

        up.script(|seen| {
            (seen.path() == "/transactions/example-transaction-2")
                .then(|| up_error(500, "Server Error"))
        });
        let failed = up.poll(holds.checkpoint.as_ref(), later).await;
        assert_eq!(
            failed.coverage,
            partial("Up API returned HTTP 500; checkpoint retained.")
        );
        assert!(failed.checkpoint.is_none());
        assert_eq!(
            titles(&failed.events),
            ["Example Hotel: -200.00 AUD (hold removed)"]
        );
        let repeated = up.poll(holds.checkpoint.as_ref(), later + 60).await;
        assert_eq!(content(&repeated.events), content(&failed.events));

        up.world().script = None;
        let resolved = up.poll(holds.checkpoint.as_ref(), later + 120).await;
        assert_eq!(resolved.coverage, SourceCoverage::Complete);
        assert_eq!(content(&resolved.events[..1]), content(&failed.events));
        assert_eq!(
            titles(&resolved.events[1..]),
            ["Example Motel: -90.00 AUD (hold removed)"]
        );
    }

    #[tokio::test]
    async fn a_different_customer_under_the_same_label_is_refused_before_any_transaction_is_read() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;

        up.world().customer = "example-customer-2";
        up.world().rows.clear();
        let mark = up.targets().len();
        for attempt in 1..=2 {
            let refused = up.poll(Some(&saved), NOW + attempt * SPACING).await;
            assert_eq!(refused.coverage, unavailable(FOREIGN));
            assert!(refused.checkpoint.is_none());
            assert!(refused.events.is_empty(), "no hold is reported as removed");
        }
        assert_eq!(up.targets_since(mark), ["/util/ping", "/util/ping"]);

        up.world().customer = "example-customer-1";
        let (events, _) = up.scan(Some(&saved), NOW + 3 * SPACING).await;
        assert_eq!(
            titles(&events),
            ["Example Hotel: -200.00 AUD (hold removed)"],
            "the first customer's checkpoint still follows its hold"
        );
    }

    #[tokio::test]
    async fn a_checkpoint_from_another_label_or_address_is_refused_before_any_request() {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;
        let elsewhere = Harness::start(Vec::new()).await;
        let mark = up.targets().len();

        let no_credential = failing_credential_script(up.dir.path());
        let other_label = UpSource::new(
            "savings".into(),
            Some(up.api.url.clone()),
            no_credential.clone(),
        )
        .unwrap();
        let other_address = UpSource::new(
            "everyday".into(),
            Some(elsewhere.api.url.clone()),
            no_credential,
        )
        .unwrap();
        for source in [other_label, other_address] {
            let refused = up.poll_with(&source, Some(&saved), NOW + SPACING).await;
            assert_eq!(
                refused.coverage,
                unavailable(FOREIGN),
                "the refusal comes before the credential command runs"
            );
        }
        assert!(up.targets_since(mark).is_empty());
        assert!(elsewhere.targets().is_empty());
    }

    #[tokio::test]
    async fn more_holds_than_the_cap_stop_the_scan_visibly_and_drop_none() {
        let rows: Vec<Row> = (0..=MAX_HOLDS as u64)
            .map(|number| {
                held(
                    &format!("example-hold-{number:03}"),
                    "Example Hotel",
                    "-1.00",
                    NOW - DAY - number,
                )
            })
            .collect();
        let oldest = rows.last().unwrap().id.clone();
        let up = Harness::start(rows).await;
        up.world().page_size = 600;

        for attempt in 0..2 {
            let stopped = up.poll(None, NOW + attempt).await;
            assert_eq!(stopped.coverage, partial(TOO_MANY_HOLDS));
            assert!(stopped.checkpoint.is_none());
            assert_eq!(
                stopped.events.len(),
                MAX_HOLDS + 1,
                "every listed transaction is still delivered"
            );
        }

        up.world().delete("example-hold-000");
        let (_, saved) = up.scan(None, NOW).await;
        up.world().delete(&oldest);
        let (events, _) = up.scan(Some(&saved), NOW + SPACING).await;
        let removed: Vec<&SourceEvent> = events
            .iter()
            .filter(|event| event.title.ends_with("(hold removed)"))
            .collect();
        assert_eq!(removed.len(), 1);
        assert_eq!(
            removed[0].id, oldest,
            "the oldest of 512 holds is still followed"
        );
    }

    #[tokio::test]
    async fn a_404_that_is_not_the_documented_one_is_a_failure_and_not_a_removal() {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().delete("example-transaction-1");
        let later = NOW + 2 * DAY;
        let not_found = unavailable("Up API returned HTTP 404; checkpoint retained.");

        up.script(|seen| (seen.path() == "/util/ping").then(|| up_error(404, "Not Found")));
        assert_eq!(up.poll(Some(&saved), later).await.coverage, not_found);
        up.script(|seen| (seen.path() == "/transactions").then(|| up_error(404, "Not Found")));
        let listing = up.poll(Some(&saved), later).await;
        assert_eq!(listing.coverage, not_found);
        assert!(listing.events.is_empty());
        up.world().script = None;
        let recent = up.poll(Some(&saved), later).await;
        let holds = up.poll(recent.checkpoint.as_ref(), later).await;
        assert_eq!(holds.coverage, SourceCoverage::More);

        let undocumented = [
            Canned::text(404, "<html>example proxy page</html>"),
            Canned::json(404, json!({})),
            Canned::json(404, json!({ "errors": [] })),
            Canned::json(404, json!({ "errors": [{ "status": "404" }] })),
            Canned::json(
                404,
                json!({ "errors": [{ "status": "500", "title": "Server Error", "detail": "example" }] }),
            ),
        ];
        for body in undocumented {
            let body = Mutex::new(Some(body));
            up.script(move |seen| {
                seen.path()
                    .starts_with("/transactions/")
                    .then(|| body.lock().unwrap().take().unwrap())
            });
            let lookup = up.poll(holds.checkpoint.as_ref(), later).await;
            assert_eq!(lookup.coverage, not_found);
            assert!(lookup.events.is_empty(), "no hold is reported as removed");
            assert!(lookup.checkpoint.is_none());
        }

        up.world().script = None;
        let documented = up.poll(holds.checkpoint.as_ref(), later).await;
        assert_eq!(documented.coverage, SourceCoverage::Complete);
        assert_eq!(
            titles(&documented.events),
            ["Example Hotel: -200.00 AUD (hold removed)"]
        );
    }

    #[tokio::test]
    async fn a_bad_token_reports_fixed_text_and_no_part_of_the_body() {
        let up = Harness::start(Vec::new()).await;
        let source = UpSource::new(
            "everyday".into(),
            Some(up.api.url.clone()),
            credential_script(up.dir.path(), "example-expired-token"),
        )
        .unwrap();

        let refused = up.poll_with(&source, None, NOW).await;

        assert_eq!(
            refused.coverage,
            unavailable(
                "Up rejected the token; it may be expired, revoked or replaced. Checkpoint retained."
            )
        );
        assert!(refused.checkpoint.is_none());
        let shown = format!("{refused:?}");
        assert!(!shown.contains("example-private-detail"));
        assert!(!shown.contains("example-expired-token"));
        assert_eq!(up.targets().len(), 1);
    }

    #[tokio::test]
    async fn rate_limiting_stops_the_poll_after_one_request() {
        let up = Harness::start(Vec::new()).await;
        up.script(|_| Some(up_error(429, "Too Many Requests")));

        let limited = up.poll(None, NOW).await;

        assert_eq!(
            limited.coverage,
            unavailable("Up rate limit reached; this poll stopped. Checkpoint retained.")
        );
        assert!(limited.checkpoint.is_none());
        assert_eq!(up.targets().len(), 1, "the poll does not retry");
    }

    #[tokio::test]
    async fn a_429_after_a_good_identity_check_ends_the_poll_after_two_requests_on_a_listing_and_up_to_five_on_lookups()
     {
        let limit = "Up rate limit reached; this poll stopped. Checkpoint retained.";
        let rows: Vec<Row> = (1..=4)
            .map(|number| {
                held(
                    &format!("example-hold-{number}"),
                    "Example Hotel",
                    "-1.00",
                    NOW - number * HOUR,
                )
            })
            .collect();
        let up = Harness::start(rows).await;
        let (_, saved) = up.scan(None, NOW).await;

        up.script(|seen| {
            (seen.path() == "/transactions").then(|| up_error(429, "Too Many Requests"))
        });
        for attempt in 0..2 {
            let mark = up.targets().len();
            let limited = up.poll(Some(&saved), NOW + SPACING + attempt).await;
            assert_eq!(limited.coverage, unavailable(limit));
            assert!(limited.checkpoint.is_none());
            let requested = up.targets_since(mark);
            assert_eq!(requested.len(), 2, "{requested:?}");
            assert_eq!(requested[0], "/util/ping");
        }

        up.world().script = None;
        up.world().rows.clear();
        let lookups = up.poll_to_lookups(&saved, NOW + SPACING).await;
        up.script(|seen| {
            (seen.path() == "/transactions/example-hold-1")
                .then(|| up_error(429, "Too Many Requests"))
        });
        for attempt in 0..2 {
            let mark = up.targets().len();
            let limited = up.poll(Some(&lookups), NOW + SPACING + attempt).await;
            assert_eq!(limited.coverage, partial(limit));
            assert!(limited.checkpoint.is_none());
            assert_eq!(
                up.targets_since(mark),
                [
                    "/util/ping",
                    "/transactions/example-hold-4",
                    "/transactions/example-hold-3",
                    "/transactions/example-hold-2",
                    "/transactions/example-hold-1",
                ],
                "the identity check, and the lookups up to the one that Up refuses"
            );
        }
    }

    #[tokio::test]
    async fn a_timeout_reports_its_fixed_text() {
        let up = Harness::start(Vec::new()).await;
        up.script(|_| Some(Canned::hang()));

        let timed_out = up.poll_with(&up.source().with_max_time(1), None, NOW).await;

        assert_eq!(
            timed_out.coverage,
            unavailable("Up API did not answer within 20 seconds; checkpoint retained.")
        );
        assert!(timed_out.checkpoint.is_none());
    }

    #[tokio::test]
    async fn a_body_that_is_not_json_reports_its_fixed_text() {
        let up = Harness::start(Vec::new()).await;
        up.script(|_| Some(Canned::text(200, "<html>example-private-body</html>")));

        let unreadable = up.poll(None, NOW).await;

        assert_eq!(
            unreadable.coverage,
            unavailable("Up sent a response this source cannot read; checkpoint retained.")
        );
        assert!(unreadable.checkpoint.is_none());
        assert!(!format!("{unreadable:?}").contains("example-private-body"));
    }

    #[tokio::test]
    async fn an_unreachable_server_reports_its_fixed_text() {
        let dir = tempfile::tempdir().unwrap();
        let source = UpSource::new(
            "everyday".into(),
            Some(FakeApi::dead_url()),
            credential_script(dir.path(), TOKEN),
        )
        .unwrap();

        let unreachable = source
            .poll_at(None, NOW, &|| 0, &ScanMemory::default())
            .await;

        assert_eq!(
            unreachable.coverage,
            unavailable("Up API is unreachable; checkpoint retained.")
        );
        assert!(unreachable.checkpoint.is_none());
    }

    #[tokio::test]
    async fn a_poll_inside_the_five_minute_spacing_makes_no_request() {
        let up = Harness::start(vec![settled(
            "example-transaction-1",
            "Example Cafe",
            "-12.50",
            NOW - HOUR,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        let mark = up.targets().len();

        let no_credential = UpSource::new(
            "everyday".into(),
            Some(up.api.url.clone()),
            failing_credential_script(up.dir.path()),
        )
        .unwrap();
        let resting = up
            .poll_with(&no_credential, Some(&saved), NOW + SPACING - 1)
            .await;

        assert_eq!(resting.coverage, SourceCoverage::Complete);
        assert_eq!(resting.checkpoint.as_ref(), Some(&saved));
        assert!(resting.events.is_empty());
        assert!(
            up.targets_since(mark).is_empty(),
            "neither the credential command nor a request runs"
        );

        let (events, _) = up.scan(Some(&saved), NOW + SPACING).await;
        assert_eq!(titles(&events), ["Example Cafe: -12.50 AUD (settled)"]);
        assert_eq!(up.targets_since(mark).len(), 4);
    }

    #[tokio::test]
    async fn a_refused_cursor_restarts_the_same_window() {
        let up = Harness::start(vec![
            settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let first = up.poll(None, NOW).await;
        assert_eq!(first.events.len(), 1);

        up.script(|seen| {
            seen.query("page[after]")
                .is_some()
                .then(|| up_error(410, "Gone"))
        });
        let restarted = up.poll(first.checkpoint.as_ref(), NOW + 60).await;
        assert_eq!(restarted.coverage, SourceCoverage::More);
        assert!(restarted.events.is_empty());

        up.world().script = None;
        let mark = up.targets().len();
        let (events, _) = up.scan(restarted.checkpoint.as_ref(), NOW + 60).await;

        assert_eq!(
            titles(&events),
            [
                "Example Cafe: -5.00 AUD (settled)",
                "Example Books: -7.00 AUD (settled)"
            ]
        );
        let requested = up.targets_since(mark);
        assert_eq!(requested[0], "/util/ping");
        assert_eq!(requested[1], up.targets()[1], "the same first page");
    }

    #[tokio::test]
    async fn a_page_link_to_another_host_or_path_is_not_followed() {
        let up = Harness::start(Vec::new()).await;
        let row = settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR);
        let own_address = up.api.url.clone();

        for link in [
            "https://other.example.test/transactions?page[after]=1".to_owned(),
            format!("{own_address}/accounts?page[after]=1"),
            format!("{own_address}/transactions/../accounts"),
            "/transactions?page[after]=1".to_owned(),
            String::new(),
        ] {
            let page = json!({ "data": [row.json()], "links": { "prev": null, "next": link } });
            up.script(move |seen| {
                (seen.path() == "/transactions").then(|| Canned::json(200, page.clone()))
            });
            let refused = up.poll(None, NOW).await;
            assert_eq!(
                refused.coverage,
                partial("Up sent a page link this source will not follow; checkpoint retained.")
            );
            assert!(refused.checkpoint.is_none());
            assert_eq!(refused.events.len(), 1);
        }
        assert!(
            up.targets().iter().all(|target| target == "/util/ping"
                || target.starts_with("/transactions?filter[since]="))
        );
    }

    #[tokio::test]
    async fn an_item_without_an_id_makes_the_page_partial_and_keeps_the_checkpoint() {
        let up = Harness::start(Vec::new()).await;
        let good = settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR).json();
        let mut without_id = good.clone();
        without_id.as_object_mut().unwrap().remove("id");
        let mut without_time = good.clone();
        without_time["attributes"]["createdAt"] = json!("yesterday");
        let page = json!({ "data": [without_id, good, without_time], "links": { "prev": null, "next": null } });
        up.script(move |seen| {
            (seen.path() == "/transactions").then(|| Canned::json(200, page.clone()))
        });

        let stopped = up.poll(None, NOW).await;

        assert_eq!(
            stopped.coverage,
            partial("Up sent 2 item(s) this source cannot read; checkpoint retained.")
        );
        assert!(stopped.checkpoint.is_none());
        assert_eq!(
            titles(&stopped.events),
            ["Example Cafe: -5.00 AUD (settled)"]
        );
    }

    #[tokio::test]
    async fn a_listing_without_a_next_link_field_is_not_read_as_its_last_page() {
        let up = Harness::start(Vec::new()).await;
        up.script(|seen| {
            (seen.path() == "/transactions")
                .then(|| Canned::json(200, json!({ "data": [], "links": {} })))
        });

        let unreadable = up.poll(None, NOW).await;

        assert_eq!(
            unreadable.coverage,
            unavailable("Up sent a response this source cannot read; checkpoint retained.")
        );
    }

    #[tokio::test]
    async fn curl_never_gets_the_token_the_address_an_id_or_a_cursor_as_an_argument() {
        let up = Harness::start(vec![
            held(
                "example-transaction-3",
                "Example Hotel",
                "-200.00",
                NOW - 3 * DAY,
            ),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-5.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let address = up.api.url.trim_start_matches("http://").to_owned();
        let shim = curl_shim(
            up.dir.path(),
            &[
                TOKEN,
                &address,
                "/util/ping",
                "/transactions",
                "example-transaction",
                "page[after]",
                "filter[",
            ],
        );
        let through_shim = || up.source().with_curl(shim.clone());

        let (first, saved) = up.scan_with(&through_shim, None, NOW).await;
        up.world().delete("example-transaction-3");
        let (second, _) = up
            .scan_with(&through_shim, Some(&saved), NOW + 2 * DAY)
            .await;

        assert_eq!(first.len(), 4);
        assert_eq!(
            titles(&second).last(),
            Some(&"Example Hotel: -200.00 AUD (hold removed)")
        );
        let requested = up.targets();
        assert!(
            requested
                .iter()
                .any(|target| target.contains("page[after]="))
        );
        assert!(requested.contains(&"/transactions/example-transaction-3".to_owned()));
        assert_eq!(
            shim_runs(up.dir.path()),
            requested.len(),
            "every request went through the shim"
        );
        assert!(!up.dir.path().join("refused").exists());

        let refusing = curl_shim(up.dir.path(), &["-K"]);
        let refused = up
            .poll_with(&up.source().with_curl(refusing), None, NOW)
            .await;
        assert_eq!(
            refused.coverage,
            unavailable("Up API is unreachable; checkpoint retained."),
            "the shim does refuse an argument it is told to refuse"
        );
        assert!(up.dir.path().join("refused").exists());
    }

    fn removals(events: &[SourceEvent]) -> Vec<&str> {
        let mut removed: Vec<&str> = events
            .iter()
            .filter(|event| event.title.ends_with("(hold removed)"))
            .map(|event| event.id.as_str())
            .collect();
        removed.sort_unstable();
        removed
    }

    fn empty_page() -> Canned {
        Canned::json(
            200,
            json!({ "data": [], "links": { "prev": null, "next": null } }),
        )
    }

    #[tokio::test]
    async fn a_token_for_another_customer_between_two_pages_of_one_scan_is_refused_before_any_transaction_request()
     {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().second_customer = Some(vec![settled(
            "example-second-transaction-1",
            "Example Pharmacy",
            "-9.00",
            NOW + DAY,
        )]);

        let later = NOW + 2 * DAY;
        let first = up.poll(Some(&saved), later).await;
        assert_eq!(first.coverage, SourceCoverage::More);
        up.world().credential = SECOND_TOKEN;
        let mut events = first.events;
        let mut saved = first.checkpoint;
        let mut last = first.coverage;
        for _ in 0..10 {
            let batch = up.poll(saved.as_ref(), later).await;
            events.extend(batch.events);
            last = batch.coverage;
            if last != SourceCoverage::More {
                break;
            }
            saved = batch.checkpoint;
        }

        assert!(
            events
                .iter()
                .all(|event| event.id != "example-second-transaction-1"),
            "a transaction of the second customer was delivered: {:?}",
            titles(&events)
        );
        assert!(
            removals(&events).is_empty(),
            "a hold of the first customer was reported as removed"
        );
        assert_eq!(last, unavailable(FOREIGN));
        let with_second_token: Vec<String> = up
            .api
            .seen()
            .into_iter()
            .filter(|seen| seen.bearer.as_deref() == Some(SECOND_TOKEN))
            .map(|seen| seen.target)
            .collect();
        assert_eq!(
            with_second_token,
            ["/util/ping"],
            "the second customer's token reads no transaction"
        );
    }

    #[tokio::test]
    async fn a_proxy_in_the_environment_of_curl_receives_no_up_request() {
        let proxy =
            FakeApi::start(|_| Canned::json(200, json!({ "meta": { "id": "example-proxy" } })))
                .await;
        let up = Harness::start(Vec::new()).await;
        let behind_proxy = proxied_curl(up.dir.path(), &proxy.url);

        let batch = up
            .poll_with(&up.source().with_curl(behind_proxy), None, NOW)
            .await;

        assert_eq!(
            proxy.connections(),
            0,
            "the proxy received the request and its bearer token"
        );
        assert_eq!(batch.coverage, SourceCoverage::More);
        assert!(!up.targets().is_empty());
    }

    #[tokio::test]
    async fn a_proxy_in_the_environment_of_curl_cannot_remove_a_hold_with_its_own_404() {
        let proxy = FakeApi::start(|_| {
            Canned::json(
                404,
                json!({ "errors": [{
                    "status": "404",
                    "title": "Proxy Route Missing",
                    "detail": "No upstream request was made."
                }] }),
            )
        })
        .await;
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.script(|seen| (seen.path() == "/transactions").then(empty_page));
        let later = NOW + 2 * DAY;
        let lookups = up.poll_to_lookups(&saved, later).await;

        let behind_proxy = proxied_curl(up.dir.path(), &proxy.url);
        let batch = up
            .poll_with(&up.source().with_curl(behind_proxy), Some(&lookups), later)
            .await;

        assert!(
            removals(&batch.events).is_empty(),
            "the proxy's 404 removed a hold that Up still lists"
        );
        assert_eq!(proxy.connections(), 0);
        assert_eq!(titles(&batch.events), ["Example Hotel: -200.00 AUD (held)"]);
        assert_eq!(batch.coverage, SourceCoverage::Complete);
    }

    #[tokio::test]
    async fn a_404_removes_a_hold_only_in_the_documented_envelope_whatever_its_title_and_detail_say()
     {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().delete("example-transaction-1");
        let later = NOW + 2 * DAY;
        let lookups = up.poll_to_lookups(&saved, later).await;
        let answer_lookups_with = |body: Value| {
            up.script(move |seen| {
                seen.path()
                    .starts_with("/transactions/")
                    .then(|| Canned::json(404, body.clone()))
            });
        };

        let entry = |status: Value, title: Value, detail: Value| json!({ "status": status, "title": title, "detail": detail });
        for other_form in [
            json!({ "errors": [entry(json!(404), json!("Not Found"), json!("example"))] }),
            json!({ "errors": [entry(json!("404"), json!(404), json!("example"))] }),
            json!({ "errors": [entry(json!("404"), json!("Not Found"), json!(null))] }),
            json!({ "errors": [
                entry(json!("404"), json!("Not Found"), json!("example")),
                entry(json!("500"), json!("Server Error"), json!("example")),
            ] }),
            json!([entry(json!("404"), json!("Not Found"), json!("example"))]),
        ] {
            answer_lookups_with(other_form);
            let failed = up.poll(Some(&lookups), later).await;
            assert_eq!(
                failed.coverage,
                unavailable("Up API returned HTTP 404; checkpoint retained.")
            );
            assert!(failed.events.is_empty(), "no hold is reported as removed");
            assert!(failed.checkpoint.is_none());
        }

        answer_lookups_with(json!({ "errors": [{
            "status": "404",
            "title": "Example Title",
            "detail": "An example detail that no document records.",
            "source": { "parameter": "id" }
        }] }));
        let removed = up.poll(Some(&lookups), later).await;
        assert_eq!(removed.coverage, SourceCoverage::Complete);
        assert_eq!(removals(&removed.events), ["example-transaction-1"]);
    }

    #[tokio::test]
    async fn a_404_on_a_saved_page_that_is_not_ups_error_body_fails_the_poll_and_does_not_restart_the_scan()
     {
        let up = Harness::start(vec![
            settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let first = up.poll_to_listing(None, NOW).await;
        assert_eq!(first.coverage, SourceCoverage::More);
        assert_eq!(first.events.len(), 1);

        for (answer, message) in [
            (
                Canned::text(404, "<html>example proxy page</html>"),
                "Up API returned HTTP 404; checkpoint retained.",
            ),
            (
                Canned::json(410, json!({})),
                "Up API returned HTTP 410; checkpoint retained.",
            ),
            (
                up_error(500, "Server Error"),
                "Up API returned HTTP 500; checkpoint retained.",
            ),
        ] {
            let answer = Mutex::new(Some(answer));
            up.script(move |seen| {
                seen.query("page[after]")
                    .and_then(|_| answer.lock().unwrap().take())
            });
            let failed = up.poll(first.checkpoint.as_ref(), NOW + 60).await;
            assert_eq!(failed.coverage, unavailable(message));
            assert!(failed.checkpoint.is_none());
            assert!(failed.events.is_empty());
        }

        up.world().script = None;
        let second = up.poll(first.checkpoint.as_ref(), NOW + 120).await;
        assert_eq!(
            titles(&second.events),
            ["Example Books: -7.00 AUD (settled)"]
        );
        assert!(
            up.targets().last().unwrap().contains("page[after]=1"),
            "the scan continues at the saved page"
        );
    }

    #[tokio::test]
    async fn a_second_refused_cursor_in_one_scan_fails_the_poll_with_fixed_text() {
        let up = Harness::start(vec![
            settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let first = up.poll_to_listing(None, NOW).await;

        up.script(|seen| {
            seen.query("page[after]")
                .is_some()
                .then(|| up_error(410, "Gone"))
        });
        let restarted = up.poll(first.checkpoint.as_ref(), NOW + 60).await;
        assert_eq!(restarted.coverage, SourceCoverage::More);
        assert!(restarted.events.is_empty());
        let again = up
            .poll_to_listing(restarted.checkpoint.as_ref(), NOW + 60)
            .await;
        assert_eq!(again.coverage, SourceCoverage::More);
        assert_eq!(titles(&again.events), ["Example Cafe: -5.00 AUD (settled)"]);

        for attempt in 0..2 {
            let refused = up
                .poll(again.checkpoint.as_ref(), NOW + 120 + attempt)
                .await;
            assert_eq!(refused.coverage, unavailable(REFUSED_AGAIN));
            assert!(refused.checkpoint.is_none());
            assert!(refused.events.is_empty());
        }

        up.world().script = None;
        let (rest, _) = up.scan(again.checkpoint.as_ref(), NOW + 180).await;
        assert_eq!(
            titles(&rest),
            ["Example Books: -7.00 AUD (settled)"],
            "the scan continues at the saved page when Up accepts the link again"
        );
    }

    #[tokio::test]
    async fn holds_that_left_do_not_count_against_the_cap() {
        let rows: Vec<Row> = (0..MAX_HOLDS as u64)
            .map(|number| {
                held(
                    &format!("example-hold-{number:03}"),
                    "Example Hotel",
                    "-1.00",
                    NOW - DAY - number,
                )
            })
            .collect();
        let up = Harness::start(rows).await;
        up.world().page_size = 600;
        let (_, saved) = up.scan(None, NOW).await;

        up.world().delete("example-hold-000");
        up.world().delete("example-hold-001");
        up.world()
            .rows
            .push(held("example-hold-new", "Example Motel", "-2.00", NOW));
        let later = NOW + SPACING;
        let mut saved = Some(saved);
        let mut events = Vec::new();
        for _ in 0..10 {
            let batch = up.poll(saved.as_ref(), later).await;
            events.extend(batch.events);
            match batch.coverage {
                SourceCoverage::More => saved = batch.checkpoint,
                SourceCoverage::Complete => {
                    saved = batch.checkpoint;
                    break;
                }
                stopped => panic!("511 live holds stopped the scan: {stopped:?}"),
            }
        }
        assert_eq!(
            removals(&events),
            ["example-hold-000", "example-hold-001"],
            "the two holds that left are looked up and reported"
        );

        up.world().delete("example-hold-new");
        let (events, _) = up.scan(saved.as_ref(), later + SPACING).await;
        assert_eq!(
            removals(&events),
            ["example-hold-new"],
            "the new hold was followed"
        );
    }

    #[tokio::test]
    async fn a_clock_that_moves_backward_restarts_the_scan_and_the_new_scan_continues_at_its_saved_page_when_the_clock_returns()
     {
        let up = Harness::start(vec![
            settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                NOW - 2 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let first = up.poll_to_listing(None, NOW).await;
        assert_eq!(first.coverage, SourceCoverage::More);

        let mut restarted = None;
        for moved_back in [30 * DAY, HOUR] {
            let mark = up.targets().len();
            let again = up.poll(first.checkpoint.as_ref(), NOW - moved_back).await;
            assert_eq!(again.coverage, SourceCoverage::More);
            assert_eq!(
                content(&again.events),
                content(&first.events),
                "the first page is read again"
            );
            let requested = up.targets_since(mark);
            assert_eq!(requested.len(), 2, "the poll reads Up: {requested:?}");
            assert!(!requested[1].contains("page[after]"));
            restarted = again.checkpoint;
        }

        let resumed = up.poll(restarted.as_ref(), NOW + 60).await;
        assert_eq!(resumed.coverage, SourceCoverage::More);
        assert_eq!(
            titles(&resumed.events),
            ["Example Books: -7.00 AUD (settled)"]
        );
        assert!(
            up.targets().last().unwrap().contains("page[after]=1"),
            "the scan that started under the clock that moved back continues at its saved page"
        );
    }

    fn versions(events: &[SourceEvent]) -> BTreeMap<&str, &str> {
        events
            .iter()
            .map(|event| (event.id.as_str(), event.version.as_str()))
            .collect()
    }

    #[tokio::test]
    async fn a_transaction_created_after_a_scan_under_a_clock_that_ran_ahead_is_delivered_by_the_next_poll()
     {
        for ahead in [16 * DAY, 30 * DAY] {
            let up = Harness::start(Vec::new()).await;
            let (_, saved) = up.scan(None, NOW).await;
            let (_, saved) = up.scan(Some(&saved), NOW + HOUR + ahead).await;

            let corrected = NOW + 2 * HOUR;
            up.world().rows.push(settled(
                "example-transaction-1",
                "Example Cafe",
                "-12.50",
                corrected + 60,
            ));
            let mark = up.targets().len();
            let next = up.poll(Some(&saved), corrected + 120).await;
            assert_eq!(
                next.coverage,
                SourceCoverage::More,
                "the poll after a clock that ran {} days ahead reads Up",
                ahead / DAY
            );
            assert_eq!(titles(&next.events), ["Example Cafe: -12.50 AUD (settled)"]);
            assert_eq!(
                up.since_requested_after(mark),
                feed::utc(NOW - 7 * DAY),
                "the poll reads its reread window again, from the origin at the earliest"
            );

            let (rest, saved) = up.scan(next.checkpoint.as_ref(), corrected + 120).await;
            assert!(rest.is_empty());
            let (repeat, _) = up.scan(Some(&saved), corrected + 120 + SPACING).await;
            assert_eq!(
                versions(&repeat),
                versions(&next.events),
                "the next scan reads the transaction again with an equal version"
            );
        }
    }

    #[tokio::test]
    async fn at_the_cap_a_hold_that_leaves_during_a_scan_keeps_its_place_until_a_new_label_reads_again()
     {
        let rows: Vec<Row> = (0..MAX_HOLDS as u64)
            .map(|number| {
                held(
                    &format!("example-hold-{number:03}"),
                    "Example Hotel",
                    "-1.00",
                    NOW - DAY - number,
                )
            })
            .collect();
        let up = Harness::start(rows).await;
        up.world().page_size = 600;
        let recent = up.poll(None, NOW).await;
        assert_eq!(recent.coverage, SourceCoverage::More);

        up.world().delete("example-hold-000");
        up.world().delete("example-hold-001");
        up.world()
            .rows
            .push(held("example-hold-new", "Example Motel", "-2.00", NOW));
        let stopped_with = |held_at_up: usize, batch: SourceBatch, requested: Vec<String>| {
            assert_eq!(
                batch.coverage,
                partial(TOO_MANY_HOLDS),
                "Up lists {held_at_up} held transactions"
            );
            assert!(batch.checkpoint.is_none());
            assert_eq!(batch.events.len(), held_at_up);
            assert!(titles(&batch.events).contains(&"Example Motel: -2.00 AUD (held)"));
            assert!(removals(&batch.events).is_empty());
            assert_eq!(
                requested,
                [
                    "/util/ping",
                    "/transactions?filter[status]=HELD&page[size]=100"
                ],
                "the poll reads the held list again, and no new transaction"
            );
        };
        let mark = up.targets().len();
        let stopped = up.poll(recent.checkpoint.as_ref(), NOW + 1).await;
        stopped_with(511, stopped, up.targets_since(mark));

        up.world().rows.truncate(449);
        up.world()
            .rows
            .push(held("example-hold-new", "Example Motel", "-2.00", NOW));
        let mark = up.targets().len();
        let stopped = up.poll(recent.checkpoint.as_ref(), NOW + 2).await;
        stopped_with(450, stopped, up.targets_since(mark));

        let new_label = || {
            UpSource::new(
                "everyday-2".into(),
                Some(up.api.url.clone()),
                credential_script(up.dir.path(), TOKEN),
            )
            .unwrap()
        };
        let mark = up.targets().len();
        let (events, _) = up.scan_with(&new_label, None, NOW + 3).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(NOW + 3 - 7 * DAY),
            "a new label starts a fresh seven-day read"
        );
        assert_eq!(versions(&events).len(), 450);
        assert!(
            removals(&events).is_empty(),
            "the holds that left under the old label are not reported under the new one"
        );

        up.world().settle("example-hold-new", "-2.00", NOW + 3);
        let (_, saved) = up.scan(recent.checkpoint.as_ref(), NOW + 4).await;
        let (events, _) = up.scan(Some(&saved), NOW + 4 + SPACING).await;
        assert_eq!(
            removals(&events).len(),
            MAX_HOLDS - 449,
            "under the old label the scan ends when Up lists no hold that it has not counted, and the next scan reports the holds that left"
        );
    }

    #[tokio::test]
    async fn the_daily_reread_finds_a_settlement_listed_thirteen_days_after_its_creation_time_and_misses_one_listed_later()
     {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;
        let reread = NOW + 30 * DAY;
        let (_, saved) = up.scan(Some(&saved), reread).await;

        let listed = reread + SPACING;
        up.world().rows.push(settled(
            "example-transaction-1",
            "Example Hotel",
            "-180.00",
            listed - 13 * DAY,
        ));
        let (same_scan, saved) = up.scan(Some(&saved), listed).await;
        assert!(same_scan.is_empty());

        let listed_later = reread + 6 * HOUR;
        up.world().rows.push(settled(
            "example-transaction-2",
            "Example Motel",
            "-90.00",
            listed_later - 13 * DAY - 18 * HOUR,
        ));
        let (same_scan, saved) = up.scan(Some(&saved), listed_later).await;
        assert!(same_scan.is_empty());

        let (next_reread, saved) = up.scan(Some(&saved), reread + DAY).await;
        assert_eq!(
            titles(&next_reread),
            ["Example Hotel: -180.00 AUD (settled)"],
            "the reread a day later reaches 14 days back, which is 13 days before the last reread"
        );
        let (reread_after, _) = up.scan(Some(&saved), reread + 2 * DAY).await;
        assert!(
            reread_after.is_empty(),
            "a settlement listed 13 days and 18 hours after its creation time is never read"
        );
    }

    #[tokio::test]
    async fn a_clock_that_ran_ahead_for_longer_than_the_reread_hides_new_transactions_and_one_from_before_the_reread_stays_missing()
     {
        const AHEAD: u64 = 30 * DAY;
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;
        let (_, mut saved) = up.scan(Some(&saved), NOW + DAY + AHEAD).await;

        for (id, description, created) in [
            ("example-transaction-1", "Example Cafe", NOW + 2 * DAY),
            ("example-transaction-2", "Example Books", NOW + 7 * DAY),
        ] {
            up.world()
                .rows
                .push(settled(id, description, "-5.00", created));
            let (hidden, next) = up.scan(Some(&saved), created + HOUR + AHEAD).await;
            assert!(
                hidden.is_empty(),
                "under the clock that runs ahead, the source asks from a time that has not come"
            );
            saved = next;
        }

        let corrected = NOW + 20 * DAY;
        let mark = up.targets().len();
        let (events, _) = up.scan(Some(&saved), corrected).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(corrected - 14 * DAY)
        );
        assert_eq!(
            titles(&events),
            ["Example Books: -5.00 AUD (settled)"],
            "the transaction from 18 days before the clock was corrected is missing"
        );
    }

    #[tokio::test]
    async fn a_first_scan_under_a_clock_that_ran_ahead_is_followed_by_the_last_seven_days_when_the_clock_is_corrected()
     {
        let up = Harness::start(vec![
            settled(
                "example-transaction-2",
                "Example Cafe",
                "-12.50",
                NOW - HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Books",
                "-7.00",
                NOW - 6 * DAY,
            ),
            settled(
                "example-transaction-0",
                "Example Hardware",
                "-99.00",
                NOW - 8 * DAY,
            ),
        ])
        .await;
        let (under_the_wrong_clock, saved) = up.scan(None, NOW + 14 * DAY).await;
        assert!(under_the_wrong_clock.is_empty());

        let mark = up.targets().len();
        let (events, _) = up.scan(Some(&saved), NOW).await;
        assert_eq!(
            titles(&events),
            [
                "Example Cafe: -12.50 AUD (settled)",
                "Example Books: -7.00 AUD (settled)"
            ]
        );
        assert_eq!(up.since_requested_after(mark), feed::utc(NOW - 7 * DAY));
    }

    #[tokio::test]
    async fn a_clock_that_moves_back_one_hour_between_two_scans_reads_each_item_again_with_an_equal_id_and_version()
     {
        let up = Harness::start(vec![
            held(
                "example-transaction-2",
                "Example Hotel",
                "-200.00",
                NOW - 2 * HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-5.00",
                NOW - 3 * HOUR,
            ),
        ])
        .await;
        let (first, saved) = up.scan(None, NOW).await;
        assert_eq!(versions(&first).len(), 2);

        let moved_back = NOW - HOUR;
        let (again, saved) = up.scan(Some(&saved), moved_back).await;
        assert_eq!(versions(&again), versions(&first));

        up.world().rows.push(settled(
            "example-transaction-3",
            "Example Books",
            "-7.00",
            moved_back + 60,
        ));
        let (next, _) = up.scan(Some(&saved), moved_back + SPACING).await;
        let mut expected = versions(&first);
        let books = next
            .iter()
            .find(|event| event.id == "example-transaction-3")
            .expect("the feed delivers a new transaction after the clock moved back");
        expected.insert(&books.id, &books.version);
        assert_eq!(versions(&next), expected);
    }

    #[tokio::test]
    async fn a_scan_in_flight_when_the_clock_moves_back_starts_again_and_its_saved_page_link_is_not_sent()
     {
        let up = Harness::start(vec![
            settled(
                "example-transaction-2",
                "Example Cafe",
                "-5.00",
                NOW - 2 * HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Books",
                "-7.00",
                NOW - 3 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let first = up.poll_to_listing(None, NOW).await;
        assert_eq!(first.coverage, SourceCoverage::More);
        let saved = first.checkpoint.as_ref().unwrap();
        assert!(
            saved.value.contains("page[after]=1"),
            "the scan in flight saved the link to its second page"
        );

        let mark = up.targets().len();
        let (events, _) = up.scan(Some(saved), NOW - HOUR).await;
        let listings: Vec<String> = up
            .targets_since(mark)
            .into_iter()
            .filter(|target| target.starts_with("/transactions?"))
            .collect();
        assert!(
            !listings[0].contains("page[after]"),
            "the first request after the clock moved back is a first page, and not the saved link: {listings:?}"
        );
        assert_eq!(
            titles(&events),
            [
                "Example Cafe: -5.00 AUD (settled)",
                "Example Books: -7.00 AUD (settled)"
            ]
        );
        assert_eq!(
            content(&events[..1]),
            content(&first.events),
            "the transaction that the dropped scan delivered is read again with an equal version"
        );
    }

    #[tokio::test]
    async fn followed_holds_survive_a_rewind_and_a_hold_that_left_is_reported_once() {
        let up = Harness::start(vec![
            held("example-hold-1", "Example Hotel", "-200.00", NOW - 2 * DAY),
            held("example-hold-2", "Example Motel", "-90.00", NOW - 3 * DAY),
        ])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        let (_, saved) = up.scan(Some(&saved), NOW + 16 * DAY).await;

        up.world().delete("example-hold-2");
        let corrected = NOW + HOUR;
        let (rewound, saved) = up.scan(Some(&saved), corrected).await;
        assert_eq!(removals(&rewound), ["example-hold-2"]);

        up.world().delete("example-hold-1");
        let (later, saved) = up.scan(Some(&saved), corrected + SPACING).await;
        assert_eq!(
            removals(&later),
            ["example-hold-1"],
            "the hold that stayed was still followed, and the first removal is not repeated"
        );
        let (last, _) = up.scan(Some(&saved), corrected + 2 * SPACING).await;
        assert!(removals(&last).is_empty());
    }

    #[tokio::test]
    async fn a_hold_that_the_dropped_scan_had_listed_is_still_followed_after_the_rewind() {
        let up = Harness::start(vec![
            held("example-hold-1", "Example Hotel", "-200.00", NOW - 2 * HOUR),
            held("example-hold-2", "Example Motel", "-90.00", NOW - 3 * HOUR),
        ])
        .await;
        up.world().page_size = 1;
        let (_, saved) = up.scan(None, NOW).await;
        let listed = up.poll_to_listing(Some(&saved), NOW + SPACING).await;
        assert_eq!(listed.coverage, SourceCoverage::More);
        assert_eq!(
            titles(&listed.events),
            ["Example Hotel: -200.00 AUD (held)"]
        );

        up.world().delete("example-hold-1");
        let moved_back = NOW - HOUR;
        let (rewound, saved) = up.scan(listed.checkpoint.as_ref(), moved_back).await;
        let (next, saved) = up.scan(Some(&saved), moved_back + SPACING).await;
        assert_eq!(
            removals(&[rewound, next].concat()),
            ["example-hold-1"],
            "the hold that the dropped scan had listed is looked up and reported once"
        );

        up.world().delete("example-hold-2");
        let (last, _) = up.scan(Some(&saved), moved_back + 2 * SPACING).await;
        assert_eq!(removals(&last), ["example-hold-2"]);
    }

    #[tokio::test]
    async fn the_five_minute_spacing_starts_when_the_last_response_of_the_scan_arrives() {
        let up = Harness::start(Vec::new()).await;
        up.script(|seen| {
            seen.query("filter[status]")
                .map(|_| empty_page().delayed(std::time::Duration::from_millis(2_500)))
        });
        let source = up.source();
        let mut saved = None;
        let last_poll_began = loop {
            let began = now_seconds().unwrap();
            let batch = source.poll(saved.as_ref()).await.unwrap();
            saved = batch.checkpoint;
            match batch.coverage {
                SourceCoverage::More => {}
                SourceCoverage::Complete => break began,
                stopped => panic!("the scan stopped: {stopped:?}"),
            }
        };
        let ended = now_seconds().unwrap();
        let mark = up.targets().len();

        let early = up.poll(saved.as_ref(), last_poll_began + SPACING + 1).await;
        assert_eq!(early.coverage, SourceCoverage::Complete);
        assert!(
            up.targets_since(mark).is_empty(),
            "a scan started less than five minutes after the last response, which took two seconds"
        );

        up.world().script = None;
        up.scan(saved.as_ref(), ended + SPACING).await;
        assert!(!up.targets_since(mark).is_empty());
    }

    #[tokio::test]
    async fn a_backdated_settlement_that_appears_after_the_reach_back_scan_is_found_by_the_daily_reread()
     {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - 3 * DAY,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().delete("example-transaction-1");
        let (removed, saved) = up.scan(Some(&saved), NOW + SPACING).await;
        assert_eq!(removals(&removed), ["example-transaction-1"]);
        let (reach_back, saved) = up.scan(Some(&saved), NOW + 2 * SPACING).await;
        assert!(reach_back.is_empty());

        up.world().rows.push(settled(
            "example-transaction-2",
            "Example Hotel",
            "-180.00",
            NOW - 3 * DAY,
        ));
        let (same_day, saved) = up.scan(Some(&saved), NOW + 3 * SPACING).await;
        assert!(
            same_day.is_empty(),
            "the one-day window does not reach the old creation time"
        );

        let mark = up.targets().len();
        let (next_day, _) = up.scan(Some(&saved), NOW + DAY).await;
        assert_eq!(titles(&next_day), ["Example Hotel: -180.00 AUD (settled)"]);
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(NOW - 7 * DAY),
            "the reread never starts before the first poll's seven days"
        );
    }

    #[tokio::test]
    async fn the_daily_reread_reads_fourteen_days_and_the_next_scan_of_that_day_reads_one() {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;
        let caught_up = NOW + 20 * DAY;
        let (_, saved) = up.scan(Some(&saved), caught_up).await;
        let (_, saved) = up.scan(Some(&saved), caught_up + SPACING).await;

        let mark = up.targets().len();
        let next_day = caught_up + DAY;
        let (_, saved) = up.scan(Some(&saved), next_day).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(next_day - 14 * DAY)
        );

        let mark = up.targets().len();
        up.scan(Some(&saved), next_day + SPACING).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(next_day - DAY),
            "one reread a day"
        );
    }

    #[tokio::test]
    async fn a_page_with_an_id_that_is_not_letters_digits_hyphens_and_underscores_is_unreadable_and_delivers_nothing()
     {
        let up = Harness::start(Vec::new()).await;
        let good = settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR).json();
        let page_with = |id: &str| {
            let other = held(id, "Example Hotel", "-200.00", NOW - 2 * HOUR).json();
            let page =
                json!({ "data": [good.clone(), other], "links": { "prev": null, "next": null } });
            up.script(move |seen| {
                (seen.path() == "/transactions").then(|| Canned::json(200, page.clone()))
            });
        };

        let too_long = "a".repeat(MAX_ID_BYTES + 1);
        for id in [
            "..", ".", "a/b", "a b", "a%2Fb", "a?b", "exämple", "", &too_long,
        ] {
            page_with(id);
            let unreadable = up.poll_to_listing(None, NOW).await;
            assert_eq!(unreadable.coverage, unavailable(UNREADABLE), "{id:?}");
            assert!(unreadable.events.is_empty(), "{id:?}");
            assert!(unreadable.checkpoint.is_none(), "{id:?}");
        }
        assert!(
            up.targets()
                .iter()
                .all(|target| !target.starts_with("/transactions/")),
            "no id reached a request path"
        );

        let longest = "a".repeat(MAX_ID_BYTES);
        for id in [
            "0f0e1d2c-3b4a-4958-8776-655443322110",
            "Example_1",
            &longest,
        ] {
            page_with(id);
            let read = up.poll_to_listing(None, NOW).await;
            assert_eq!(read.coverage, SourceCoverage::More, "{id:?}");
            assert_eq!(read.events.len(), 2, "{id:?}");
        }
    }

    /// The object in a checkpoint that holds the followed transactions, which
    /// is the one with the followed transaction `id` as a key.
    fn holds_of<'a>(checkpoint: &'a mut Value, id: &str) -> Option<&'a mut Value> {
        if checkpoint.get(id).is_some() {
            return Some(checkpoint);
        }
        checkpoint
            .as_object_mut()?
            .values_mut()
            .find_map(|field| holds_of(field, id))
    }

    #[tokio::test]
    async fn a_saved_checkpoint_with_more_holds_than_the_cap_or_a_field_outside_its_bound_is_refused_before_any_request()
     {
        let up = Harness::start(vec![held(
            "example-transaction-1",
            "Example Hotel",
            "-200.00",
            NOW - HOUR,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        let mut saved: Value = serde_json::from_str(&saved.value).unwrap();
        let followed =
            holds_of(&mut saved, "example-transaction-1").unwrap()["example-transaction-1"].clone();
        let with_holds = |ids: Vec<String>, hold: &Value| {
            let mut seeded = saved.clone();
            *holds_of(&mut seeded, "example-transaction-1").unwrap() =
                Value::Object(ids.into_iter().map(|id| (id, hold.clone())).collect());
            SourceCheckpoint {
                value: seeded.to_string(),
            }
        };
        let numbered = |count: usize| -> Vec<String> {
            (0..count)
                .map(|number| format!("example-hold-{number:04}"))
                .collect()
        };
        let mut long_summary = followed.clone();
        long_summary["summary"] = json!("a".repeat(161));
        let mut control_summary = followed.clone();
        control_summary["summary"] = json!("Example\nHotel");
        let mark = up.targets().len();

        let no_credential = UpSource::new(
            "everyday".into(),
            Some(up.api.url.clone()),
            failing_credential_script(up.dir.path()),
        )
        .unwrap();
        for (case, seeded) in [
            ("3,000 holds", with_holds(numbered(3_000), &followed)),
            ("513 holds", with_holds(numbered(MAX_HOLDS + 1), &followed)),
            ("a dot-segment id", with_holds(vec!["..".into()], &followed)),
            (
                "a long id",
                with_holds(vec!["a".repeat(MAX_ID_BYTES + 1)], &followed),
            ),
            ("a long summary", with_holds(numbered(1), &long_summary)),
            (
                "a control character in a summary",
                with_holds(numbered(1), &control_summary),
            ),
        ] {
            let refused = up
                .poll_with(&no_credential, Some(&seeded), NOW + SPACING)
                .await;
            assert_eq!(
                refused.coverage,
                unavailable(FOREIGN),
                "{case}: the refusal comes before the credential command runs"
            );
            assert!(refused.checkpoint.is_none());
        }
        assert!(up.targets_since(mark).is_empty());

        let at_the_cap = with_holds(numbered(MAX_HOLDS), &followed);
        let read = up.poll(Some(&at_the_cap), NOW + SPACING).await;
        assert_eq!(read.coverage, SourceCoverage::More, "512 holds are read");
    }

    #[tokio::test]
    async fn a_checkpoint_in_the_format_before_the_daily_reread_is_refused_and_not_misread() {
        let up = Harness::start(Vec::new()).await;
        let scope = feed::scope(&[&up.source().api.fingerprint()]);
        let owner = feed::scope(&["everyday", "example-customer-1"]);
        let head = format!(
            r#"{{"account":"everyday","scope":"{scope}","owner":"{owner}","origin":1794395200,"#
        );
        let old_format = [
            r#""window":{"scanning":{"started_at":1795000000,"since":1794395200,"pages":1,"cursor":null,"state":{"phase":"recent","reach_back":null}}},"kept":{}}"#,
            r#""window":{"scanning":{"started_at":1795000000,"since":1794395200,"pages":2,"cursor":"/transactions?page[after]=1&page[size]=1&filter[since]=2026-11-11T11%3A06%3A40Z","state":{"phase":"recent","reach_back":null}}},"kept":{}}"#,
            r#""window":{"resting":{"since":1794913600,"not_before":1795000300}},"kept":{"example-transaction-1":{"created_at":1794740800,"summary":"Example Hotel: -200.00 AUD","listed_in":1795000000}}}"#,
        ];
        let no_credential = UpSource::new(
            "everyday".into(),
            Some(up.api.url.clone()),
            failing_credential_script(up.dir.path()),
        )
        .unwrap();
        for rest in old_format {
            let saved = SourceCheckpoint {
                value: format!("{head}{rest}"),
            };
            let refused = up
                .poll_with(&no_credential, Some(&saved), NOW + SPACING)
                .await;
            assert_eq!(refused.coverage, unavailable(FOREIGN), "{rest}");
            assert!(refused.checkpoint.is_none());
        }
        assert!(up.targets().is_empty(), "no request is made");

        let same_state_in_the_current_format = SourceCheckpoint {
            value: format!(
                r#"{head}"reread_at":1795000000,"window":{{"resting":{{"since":1794913600,"not_before":1795000300}}}},"kept":{{"unseen":{{"example-transaction-1":{{"created_at":1794740800,"summary":"Example Hotel: -200.00 AUD"}}}},"seen":{{}}}}}}"#
            ),
        };
        let (events, _) = up
            .scan(Some(&same_state_in_the_current_format), NOW + SPACING)
            .await;
        assert_eq!(
            removals(&events),
            ["example-transaction-1"],
            "the refusal above comes from the format, and from nothing else in the checkpoint"
        );
    }

    #[test]
    fn an_address_with_a_quote_is_refused_with_a_message_that_names_the_cause() {
        let error = UpSource::new(
            "everyday".into(),
            Some("https://api.example.test/\"".into()),
            vec!["example-secrets".into()],
        )
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            "Up URL must not contain white space, a control character, a double quote or a backslash"
        );
    }

    /// A model of the runtime's source journal, with the two rules a poll
    /// depends on: a checkpoint moves only for `More` and `Complete`, and an
    /// event is new when its id and version are. `tests/source_refresh.rs`
    /// runs the same scan against the real journal.
    #[derive(Default)]
    struct JournalModel {
        states: Vec<SourceState>,
        admitted: BTreeMap<(String, String), (String, String)>,
    }

    impl JournalModel {
        fn admit(&mut self, batch: SourceBatch) -> usize {
            let mut new_events = 0;
            for event in &batch.events {
                let content = (event.title.clone(), event.text.clone());
                match self
                    .admitted
                    .insert((event.id.clone(), event.version.clone()), content.clone())
                {
                    None => new_events += 1,
                    Some(original) => assert_eq!(
                        original, content,
                        "the runtime drops a page that changes content under one version"
                    ),
                }
            }
            let advances = matches!(
                batch.coverage,
                SourceCoverage::More | SourceCoverage::Complete
            );
            let previous = self.states.pop().and_then(|state| state.checkpoint);
            self.states.push(SourceState {
                source: batch.source,
                checkpoint: if advances { batch.checkpoint } else { previous },
                coverage: batch.coverage,
                checked_at: 0,
                last_completed_at: None,
                progress: None,
            });
            new_events
        }
    }

    /// One refresh round: pages until the poll entry point returns no cursor.
    async fn refresh(
        config: &[SourceConfig],
        journal: &mut JournalModel,
    ) -> Vec<(SourceCoverage, usize)> {
        let mut cursor = None;
        let mut pages = Vec::new();
        loop {
            let response = background::execute(BackgroundRequest::PollSources {
                sources: config.to_vec(),
                states: journal.states.clone(),
                cursor,
            })
            .await
            .unwrap();
            let wire = serde_json::to_vec(&HostResult::Background { response }).unwrap();
            let HostResult::Background {
                response:
                    BackgroundResponse::Sources {
                        reads,
                        cursor: next,
                        ..
                    },
            } = serde_json::from_slice(&wire).unwrap()
            else {
                panic!("the source response did not survive the wire round trip");
            };
            for read in reads {
                assert_eq!(
                    read.expected_checkpoint,
                    journal
                        .states
                        .first()
                        .and_then(|state| state.checkpoint.clone())
                );
                let coverage = read.batch.coverage.clone();
                pages.push((coverage, journal.admit(read.batch)));
            }
            cursor = next;
            if cursor.is_none() {
                return pages;
            }
        }
    }

    #[tokio::test]
    async fn the_poll_entry_point_admits_a_page_once_and_resumes_at_the_saved_page_after_a_failure()
    {
        let now = now_seconds().unwrap();
        let up = Harness::start(vec![
            held(
                "example-transaction-3",
                "Example Hotel",
                "-200.00",
                now - HOUR,
            ),
            settled(
                "example-transaction-2",
                "Example Books",
                "-7.00",
                now - 2 * HOUR,
            ),
            settled(
                "example-transaction-1",
                "Example Cafe",
                "-5.00",
                now - 3 * HOUR,
            ),
        ])
        .await;
        up.world().page_size = 1;
        let config = [SourceConfig::Up {
            enabled: true,
            account: "everyday".into(),
            credential_command: credential_script(up.dir.path(), TOKEN),
            url: Some(up.api.url.clone()),
        }];
        let mut journal = JournalModel::default();

        let fail_once = AtomicBool::new(true);
        up.script(move |seen| {
            (seen.query("page[after]").as_deref() == Some("1")
                && fail_once.swap(false, Ordering::Relaxed))
            .then(|| up_error(503, "Service Unavailable"))
        });
        let first_round = refresh(&config, &mut journal).await;
        assert_eq!(
            first_round,
            [
                (SourceCoverage::More, 1),
                (
                    unavailable("Up API returned HTTP 503; checkpoint retained."),
                    0
                ),
            ],
            "the first page, and the failure that ends the round"
        );

        let mark = up.targets().len();
        let second_round = refresh(&config, &mut journal).await;
        assert_eq!(
            second_round,
            [
                (SourceCoverage::More, 1),
                (SourceCoverage::More, 1),
                (SourceCoverage::Complete, 0),
            ],
            "the HELD listing repeats the hold with its version, which is admitted once"
        );
        let requested = up.targets_since(mark);
        assert!(
            requested[1].contains("page[after]=1&"),
            "the scan resumes at the saved page: {requested:?}"
        );
        assert_eq!(journal.admitted.len(), 3);

        let mark = up.targets().len();
        assert_eq!(
            refresh(&config, &mut journal).await,
            [(SourceCoverage::Complete, 0)]
        );
        assert!(
            up.targets_since(mark).is_empty(),
            "the next round is inside the spacing"
        );
    }

    async fn assert_stopped(
        up: &Harness,
        saved: Option<&SourceCheckpoint>,
        now: u64,
        message: &str,
    ) {
        let mark = up.targets().len();
        let stopped = up.poll(saved, now).await;
        assert_eq!(stopped.coverage, unavailable(message));
        assert!(stopped.checkpoint.is_none(), "the poll saves nothing");
        assert!(stopped.events.is_empty(), "the poll delivers no event");
        assert_eq!(up.targets_since(mark), ["/util/ping"]);
    }

    /// The checkpoint with every Unix time `seconds` later, as a computer
    /// whose clock ran ahead would have written it.
    fn written_ahead(saved: &SourceCheckpoint, seconds: u64) -> SourceCheckpoint {
        fn move_times(value: &mut Value, seconds: u64) {
            match value {
                Value::Number(number) => {
                    if let Some(time) = number.as_u64().filter(|time| *time >= 1_000_000_000) {
                        *value = json!(time + seconds);
                    }
                }
                Value::Array(items) => items.iter_mut().for_each(|item| move_times(item, seconds)),
                Value::Object(fields) => fields
                    .values_mut()
                    .for_each(|field| move_times(field, seconds)),
                _ => {}
            }
        }
        let mut value: Value = serde_json::from_str(&saved.value).unwrap();
        move_times(&mut value, seconds);
        SourceCheckpoint {
            value: value.to_string(),
        }
    }

    #[tokio::test]
    async fn a_clock_that_steps_during_a_catch_up_scan_saves_nothing_and_every_transaction_arrives_once()
     {
        let up = Harness::start(vec![settled(
            "example-before",
            "Example Cafe",
            "-5.00",
            NOW - 200,
        )])
        .await;
        let (first, saved) = up.scan(None, NOW).await;

        let later = NOW + 20 * DAY;
        for number in 0..150 {
            up.world().rows.push(settled(
                &format!("example-outage-{number:03}"),
                "Example Books",
                "-7.00",
                NOW + DAY + number * (18 * DAY / 150),
            ));
        }
        up.world().bank_time = Some(later);
        assert_stopped(&up, Some(&saved), later + 70 * 60, CLOCK_DIFFERS).await;

        up.world().bank_time = Some(later + 10);
        let mark = up.targets().len();
        let page = up.poll_to_listing(Some(&saved), later + 10).await;
        assert_eq!(page.coverage, SourceCoverage::More);
        assert_eq!(page.events.len(), 100);
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(NOW - DAY),
            "the catch-up scan reads from one day before the last scan, 21 days back"
        );

        for wrong in [later + 20 - 600, later + 20 + HOUR] {
            up.world().bank_time = Some(later + 20);
            assert_stopped(&up, page.checkpoint.as_ref(), wrong, CLOCK_DIFFERS).await;
        }

        up.world().bank_time = Some(later + 30);
        let mark = up.targets().len();
        let (rest, _) = up.scan(page.checkpoint.as_ref(), later + 30).await;
        assert!(
            up.targets_since(mark)[1].contains("page[after]=100"),
            "the scan continues at its saved page with its saved lower bound"
        );
        let delivered = [first, page.events, rest].concat();
        let admitted: BTreeSet<(&str, &str)> = delivered
            .iter()
            .map(|event| (event.id.as_str(), event.version.as_str()))
            .collect();
        assert_eq!(versions(&delivered).len(), 151, "every transaction arrives");
        assert_eq!(admitted.len(), 151, "and each under one version");
    }

    #[tokio::test]
    async fn one_poll_under_a_clock_set_in_the_past_delivers_no_old_transaction_and_the_origin_stays()
     {
        let up = Harness::start(vec![
            settled("example-recent", "Example Cafe", "-5.00", NOW - HOUR),
            settled("example-old-9", "Example Books", "-7.00", NOW - 9 * DAY),
            settled("example-old-33", "Example Hotel", "-200.00", NOW - 33 * DAY),
            settled(
                "example-old-400",
                "Example Hardware",
                "-99.00",
                NOW - 400 * DAY,
            ),
        ])
        .await;
        let (first, saved) = up.scan(None, NOW).await;
        assert_eq!(titles(&first), ["Example Cafe: -5.00 AUD (settled)"]);

        let real = NOW + HOUR;
        up.world().bank_time = Some(real);
        for in_the_past in [real - 9 * DAY, real - 30 * DAY, 1_000] {
            assert_stopped(&up, Some(&saved), in_the_past, CLOCK_DIFFERS).await;
        }

        up.world().bank_time = None;
        let (corrected, saved) = up.scan(Some(&saved), real + 600).await;
        assert_eq!(titles(&corrected), ["Example Cafe: -5.00 AUD (settled)"]);
        let mark = up.targets().len();
        let (reread, _) = up.scan(Some(&saved), NOW + DAY + HOUR).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(NOW - 7 * DAY),
            "the daily reread still starts at the first poll's seven days"
        );
        assert_eq!(titles(&reread), ["Example Cafe: -5.00 AUD (settled)"]);
    }

    #[tokio::test]
    async fn a_clock_that_runs_ahead_for_sixteen_days_stops_the_source_and_every_transaction_arrives_after_the_correction()
     {
        const AHEAD: u64 = 16 * DAY;
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;

        for day in 1..=16 {
            let real = NOW + day * DAY;
            up.world().rows.push(settled(
                &format!("example-day-{day:02}"),
                "Example Cafe",
                "-5.00",
                real - HOUR,
            ));
            up.world().bank_time = Some(real);
            assert_stopped(&up, Some(&saved), real + AHEAD, CLOCK_DIFFERS).await;
        }

        let corrected = NOW + 17 * DAY;
        up.world().bank_time = Some(corrected);
        let mark = up.targets().len();
        let (events, _) = up.scan(Some(&saved), corrected).await;
        assert_eq!(
            up.since_requested_after(mark),
            feed::utc(NOW - DAY),
            "the scan reads from the bound that the last checked scan saved"
        );
        let delivered: Vec<&str> = events.iter().map(|event| event.id.as_str()).collect();
        let expected: Vec<String> = (1..=16)
            .rev()
            .map(|day| format!("example-day-{day:02}"))
            .collect();
        assert_eq!(delivered, expected);
    }

    #[tokio::test]
    async fn a_reply_without_exactly_one_readable_date_header_ends_the_poll_and_saves_nothing() {
        let up = Harness::start(vec![settled(
            "example-transaction-1",
            "Example Cafe",
            "-5.00",
            NOW - HOUR,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        for dates in [
            Dates::Missing,
            Dates::Duplicated,
            Dates::Text(""),
            Dates::Text("yesterday"),
            Dates::Text("2026-11-18T11:06:40Z"),
            Dates::Text("Wed, 18 Nov 2026 11:06:40"),
        ] {
            up.world().dates = dates;
            assert_stopped(&up, None, NOW, NO_DATE).await;
            assert_stopped(&up, Some(&saved), NOW + SPACING, NO_DATE).await;
        }

        up.world().dates = Dates::Text("Wed, 18 Nov 2026 11:06:40 GMT");
        let read = up.poll(None, NOW).await;
        assert_eq!(read.coverage, SourceCoverage::More);
    }

    #[tokio::test]
    async fn the_clock_may_differ_from_ups_clock_by_five_minutes_and_by_no_second_more() {
        let up = Harness::start(vec![settled(
            "example-transaction-1",
            "Example Cafe",
            "-5.00",
            NOW - HOUR,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;

        up.world().bank_time = Some(NOW);
        for tolerated in [NOW + 300, NOW - 300] {
            let read = up.poll(None, tolerated).await;
            assert_eq!(read.coverage, SourceCoverage::More);
            assert_eq!(titles(&read.events), ["Example Cafe: -5.00 AUD (settled)"]);
        }
        for wrong in [NOW + 301, NOW - 301] {
            up.world().bank_time = Some(NOW);
            assert_stopped(&up, None, wrong, CLOCK_DIFFERS).await;
            up.world().bank_time = Some(NOW + SPACING);
            assert_stopped(&up, Some(&saved), wrong + SPACING, CLOCK_DIFFERS).await;
        }
    }

    #[tokio::test]
    async fn the_clock_is_checked_on_a_reply_with_an_error_status() {
        let up = Harness::start(Vec::new()).await;
        up.script(|seen| (seen.path() == "/util/ping").then(|| up_error(401, "Not Authorized")));
        up.world().bank_time = Some(NOW);

        assert_stopped(
            &up,
            None,
            NOW + 300,
            "Up rejected the token; it may be expired, revoked or replaced. Checkpoint retained.",
        )
        .await;
        assert_stopped(&up, None, NOW + 301, CLOCK_DIFFERS).await;
        up.world().dates = Dates::Missing;
        assert_stopped(&up, None, NOW, NO_DATE).await;
    }

    #[tokio::test]
    async fn a_credential_command_that_takes_longer_than_five_minutes_is_not_a_clock_failure() {
        for seconds in [301, 890] {
            let up = Harness::start(vec![settled(
                "example-transaction-1",
                "Example Cafe",
                "-5.00",
                NOW - HOUR,
            )])
            .await;
            up.world().credential_seconds = seconds;
            let (events, saved) = up.scan(None, NOW).await;
            assert_eq!(titles(&events), ["Example Cafe: -5.00 AUD (settled)"]);

            up.world().credential_seconds = 0;
            let mark = up.targets().len();
            let resting = up.poll(Some(&saved), NOW + seconds + SPACING - 1).await;
            assert_eq!(resting.coverage, SourceCoverage::Complete);
            assert!(
                up.targets_since(mark).is_empty(),
                "the spacing counts from the last response, {seconds} seconds after its poll began"
            );
            up.scan(Some(&saved), NOW + seconds + SPACING).await;
            assert_eq!(up.targets_since(mark).len(), 4);
        }
    }

    #[tokio::test]
    async fn a_checkpoint_that_an_earlier_build_wrote_is_refused_and_a_new_label_starts_a_fresh_read()
     {
        let up = Harness::start(vec![settled(
            "example-transaction-1",
            "Example Cafe",
            "-5.00",
            NOW - HOUR,
        )])
        .await;
        let scope = feed::scope(&[&up.source().api.fingerprint()]);
        let owner = feed::scope(&["everyday", "example-customer-1"]);
        let head = format!(
            r#"{{"account":"everyday","scope":"{scope}","owner":"{owner}","origin":1794395200,"reread_at":1795000000,"#
        );
        let from_an_earlier_build = [
            r#""window":{"resting":{"since":1794913600,"not_before":1795000300}},"kept":{"unseen":{},"seen":{}}}"#,
            r#""window":{"scanning":{"started_at":1795000000,"since":1794395200,"pages":1,"restarted":false,"cursor":null,"state":{"phase":"held","reach_back":null}}},"kept":{"unseen":{},"seen":{}}}"#,
        ];
        let no_credential = UpSource::new(
            "everyday".into(),
            Some(up.api.url.clone()),
            failing_credential_script(up.dir.path()),
        )
        .unwrap();
        for rest in from_an_earlier_build {
            let saved = SourceCheckpoint {
                value: format!("{head}{rest}"),
            };
            for now in [NOW + SPACING, NOW + 20 * DAY] {
                let refused = up.poll_with(&no_credential, Some(&saved), now).await;
                assert_eq!(refused.coverage, unavailable(FOREIGN), "{rest}");
                assert!(refused.checkpoint.is_none());
            }
        }
        assert!(up.targets().is_empty(), "no request is made");

        let relabelled = UpSource::new(
            "everyday-2".into(),
            Some(up.api.url.clone()),
            credential_script(up.dir.path(), TOKEN),
        )
        .unwrap();
        let later = NOW + 20 * DAY;
        let fresh = up.poll_with(&relabelled, None, later).await;
        assert_eq!(fresh.coverage, SourceCoverage::More);
        assert_eq!(up.since_requested_after(0), feed::utc(later - 7 * DAY));
    }

    #[tokio::test]
    async fn a_saved_time_more_than_one_hour_ahead_of_ups_clock_is_refused_as_a_foreign_checkpoint()
    {
        let up = Harness::start(vec![settled(
            "example-transaction-1",
            "Example Cafe",
            "-5.00",
            NOW - HOUR,
        )])
        .await;
        let (_, saved) = up.scan(None, NOW).await;
        let latest_saved_time = NOW + SPACING;
        let poll_at = NOW + 2 * SPACING;
        let one_hour_ahead = poll_at + HOUR - latest_saved_time;

        for ahead in [one_hour_ahead + 1, 16 * DAY] {
            let copied = written_ahead(&saved, ahead);
            assert_stopped(&up, Some(&copied), poll_at, FOREIGN).await;
        }

        let within_the_hour = written_ahead(&saved, one_hour_ahead);
        let read = up.poll(Some(&within_the_hour), poll_at).await;
        assert_eq!(read.coverage, SourceCoverage::More);
        assert_eq!(titles(&read.events), ["Example Cafe: -5.00 AUD (settled)"]);
    }

    #[tokio::test]
    async fn a_poll_after_the_wall_clock_moved_back_one_hour_does_not_rest() {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;

        up.pass(60);
        up.world().bank_time = Some(NOW + 60);
        assert_stopped(&up, Some(&saved), NOW + 60 - HOUR, CLOCK_DIFFERS).await;
    }

    #[tokio::test]
    async fn under_a_wall_clock_that_stands_still_the_source_scans_again_after_300_seconds_of_monotonic_time()
     {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;
        up.world().rows.push(settled(
            "example-transaction-1",
            "Example Cafe",
            "-5.00",
            NOW + 100,
        ));

        up.pass(299);
        up.world().bank_time = Some(NOW + 299);
        let mark = up.targets().len();
        let resting = up.poll(Some(&saved), NOW).await;
        assert_eq!(resting.coverage, SourceCoverage::Complete);
        assert_eq!(resting.checkpoint.as_ref(), Some(&saved));
        assert!(up.targets_since(mark).is_empty());

        up.pass(1);
        up.world().bank_time = Some(NOW + 300);
        let scanning = up.poll(Some(&saved), NOW).await;
        assert_eq!(scanning.coverage, SourceCoverage::More);
        assert_eq!(
            titles(&scanning.events),
            ["Example Cafe: -5.00 AUD (settled)"],
            "the clocks differ by 300 seconds, so this poll still reads"
        );

        up.pass(1);
        up.world().bank_time = Some(NOW + 301);
        assert_stopped(&up, scanning.checkpoint.as_ref(), NOW, CLOCK_DIFFERS).await;
    }

    #[tokio::test]
    async fn after_a_restart_the_source_rests_for_at_most_300_seconds_of_monotonic_time() {
        let up = Harness::start(Vec::new()).await;
        let (_, saved) = up.scan(None, NOW).await;

        up.pass(200);
        up.restart();
        let stood_still = NOW + 200;
        for passed in [0, 299] {
            up.pass(passed);
            up.world().bank_time = Some(stood_still + passed);
            let mark = up.targets().len();
            let resting = up.poll(Some(&saved), stood_still).await;
            assert_eq!(resting.coverage, SourceCoverage::Complete);
            assert!(
                up.targets_since(mark).is_empty(),
                "{passed} seconds after the first poll of the new process"
            );
        }

        up.pass(1);
        up.world().bank_time = Some(stood_still + 300);
        let mark = up.targets().len();
        let scanning = up.poll(Some(&saved), stood_still).await;
        assert_eq!(scanning.coverage, SourceCoverage::More);
        assert_eq!(up.targets_since(mark).len(), 2);
    }

    fn parsed(row: &Row) -> Transaction {
        parse(&row.json()).unwrap()
    }

    #[test]
    fn held_and_settled_texts_are_exact() {
        let mut row = held("example-transaction-1", "Example Cafe", "-12.50", NOW);
        let item = describe(&parsed(&row));
        assert_eq!(item.id, "example-transaction-1");
        assert_eq!(item.title, "Example Cafe: -12.50 AUD (held)");
        assert_eq!(
            item.text,
            "Status: held\nAmount: -12.50 AUD\nType: Purchase\nCreated: 2026-11-18T11:06:40Z"
        );

        row.status = "SETTLED";
        row.amount = "-12.00";
        row.settled = Some(NOW + DAY);
        let mut raw = row.json();
        raw["attributes"]["foreignAmount"] =
            json!({ "currencyCode": "USD", "value": "-8.10", "valueInBaseUnits": -810 });
        raw["attributes"]["message"] = json!("Thanks\nfor lunch");
        raw["relationships"]["transferAccount"]["data"] =
            json!({ "type": "accounts", "id": "example-account-2" });
        let item = describe(&parse(&raw).unwrap());
        assert_eq!(item.title, "Example Cafe: -12.00 AUD (settled)");
        assert_eq!(
            item.text,
            "Status: settled\nAmount: -12.00 AUD\nForeign amount: -8.10 USD\nHeld at: -12.50 AUD\nType: Purchase\nMessage: Thanks for lunch\nBetween own accounts: yes\nCreated: 2026-11-18T11:06:40Z\nSettled: 2026-11-19T11:06:40Z"
        );

        raw["attributes"]["status"] = json!("REVERSED");
        raw["attributes"]["amount"] = json!(12);
        raw["attributes"]["description"] = json!(null);
        assert_eq!(
            describe(&parse(&raw).unwrap()).title,
            "Transaction (REVERSED)"
        );
    }

    #[test]
    fn a_status_change_changes_the_version_and_a_category_change_does_not() {
        let key = SourceKey {
            provider: PROVIDER.into(),
            account: "everyday".into(),
        };
        let mut row = held("example-transaction-1", "Example Cafe", "-12.50", NOW);
        let version = |raw: &Value| describe(&parse(raw).unwrap()).into_event(&key).version;
        let held_version = version(&row.json());

        let mut recategorized = row.json();
        recategorized["relationships"]["category"]["data"]["id"] = json!("example-other-category");
        recategorized["relationships"]["tags"]["data"] =
            json!([{ "type": "tags", "id": "example-tag" }]);
        recategorized["attributes"]["note"] = json!({ "text": "example note" });
        recategorized["attributes"]["createdAt"] = json!(feed::utc(NOW));
        assert_eq!(version(&recategorized), held_version);

        row.status = "SETTLED";
        row.settled = Some(NOW + 60);
        assert_ne!(version(&row.json()), held_version);
    }

    #[test]
    fn a_source_needs_a_label_an_encrypted_or_loopback_address_and_a_credential_command() {
        let command = || vec!["example-secrets".to_owned(), "read".to_owned()];
        let default_address = UpSource::new("everyday".into(), None, command()).unwrap();
        let shown = format!("{default_address:?}");
        assert!(shown.contains("everyday"));
        assert!(!shown.contains("example-secrets"));
        assert!(!shown.contains("api.up.com.au"));

        let refusal = |account: &str, url: &str, command: Vec<String>| {
            UpSource::new(account.into(), Some(url.into()), command)
                .unwrap_err()
                .to_string()
        };
        assert_eq!(
            refusal(" ", "https://api.example.test", command()),
            "Up source needs an explicit account"
        );
        assert_eq!(
            refusal("everyday", "http://api.example.test", command()),
            "Up URL must be https, or http on a loopback host"
        );
        assert_eq!(
            refusal("everyday", "https://api.example.test", Vec::new()),
            "Up source needs a credential_command"
        );
    }
}
