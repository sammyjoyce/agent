//! Opt-in Up bank transactions from the Up API. Read-only: GET requests only.
//!
//! The window of this source, which `Complete` refers to: every transaction
//! created since the source was turned on minus seven days, and the change
//! from held to settled, or the removal, of up to 512 held transactions.
//!
//! One scan is four steps. A `poll` call makes one request, or up to four lookups:
//!
//!   Ping      GET /util/ping                                          whose data the token reads
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
    http::{HttpApi, HttpFailure, Session, Target, UrlRule},
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
/// Lookups in one `poll` call. The runtime allows four calls a round.
const LOOKUPS_PER_POLL: usize = 4;
/// How far back a removed hold can pull the next window.
const MAX_REACH_BACK_SECONDS: u64 = 60 * 86_400;
const MAX_ID_BYTES: usize = 128;

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

    async fn poll_at(&self, saved: Option<&SourceCheckpoint>, now: u64) -> SourceBatch {
        feed::settle(LABEL, self.key(), self.step(saved, now).await)
    }

    /// One request, or up to `LOOKUPS_PER_POLL` lookups.
    async fn step(&self, saved: Option<&SourceCheckpoint>, now: u64) -> Result<SourceBatch, Stop> {
        let key = self.key();
        let scope = feed::scope(&[&self.api.fingerprint()]);
        let begin = |_: &Holds, since: u64| (since, UpScan::default());
        let mut checkpoint = match Checkpoint::load(saved, &key, &scope, now, begin)? {
            Turn::Rest(batch) => return Ok(batch),
            Turn::Scan(checkpoint) => checkpoint,
        };
        let session = self.api.open().await?;
        match checkpoint.scan.state.phase {
            Phase::Ping => {
                let ping: Ping = session.get(&Target::fixed("/util/ping")).await?.json()?;
                if ping.meta.id.is_empty() {
                    return Err(HttpFailure::Unreadable.into());
                }
                // Only this hash of the customer id is kept. A swapped token
                // would otherwise make every followed hold look removed.
                checkpoint.bind_owner(feed::scope(&[&self.account, &ping.meta.id]))?;
                checkpoint.scan.state.phase = Phase::Recent;
                checkpoint.advance(key, Vec::new(), Step::Next(None), now)
            }
            Phase::Recent => {
                let since = feed::utc(checkpoint.scan.since);
                let first = Target::fixed(TRANSACTIONS).query("filter[since]", &since);
                self.list_page(&session, checkpoint, first, key, now).await
            }
            // No lower bound here. If `filter[since]` compares `settledAt`,
            // this listing is the only place a new hold appears.
            Phase::Held => {
                let first = Target::fixed(TRANSACTIONS).query("filter[status]", "HELD");
                self.list_page(&session, checkpoint, first, key, now).await
            }
            Phase::Departed => {
                let mut events = Vec::new();
                for (id, hold) in take_departed(&mut checkpoint, LOOKUPS_PER_POLL) {
                    match look_up(&session, &id).await {
                        Ok(found) => events.push(resolve(&mut checkpoint, id, hold, found, &key)),
                        Err(failure) => return Err(Stop::after(events, failure)),
                    }
                }
                let step = if has_departed(&checkpoint) {
                    Step::Next(None)
                } else {
                    Step::Done {
                        floor: checkpoint.scan.state.reach_back,
                    }
                };
                checkpoint.advance(key, events, step, now)
            }
        }
    }

    async fn list_page(
        &self,
        session: &Session<'_>,
        mut checkpoint: Checkpoint,
        first: Target,
        key: SourceKey,
        now: u64,
    ) -> Result<SourceBatch, Stop> {
        let target = match &checkpoint.scan.cursor {
            Some(cursor) => saved_page(cursor)?,
            None => first.query("page[size]", feed::PAGE_SIZE),
        };
        let reply = session.get(&target).await?;
        if feed::cursor_refused(checkpoint.scan.cursor.is_some(), reply.status) {
            return checkpoint.advance(key, Vec::new(), Step::Restart, now);
        }
        let page: Page = reply.json()?;
        let listed = list(&mut checkpoint, &page.data, &key);
        if let Some(failure) = listed.failure {
            return Err(Stop::after(listed.events, failure));
        }
        match after_listing(&mut checkpoint, page.links.next.as_deref(), &self.api) {
            Ok(step) => checkpoint.advance(key, listed.events, step, now),
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
        Ok(self.poll_at(checkpoint, now_seconds()?).await)
    }
}

type Checkpoint = FeedCheckpoint<Holds, UpScan>;

/// Kept between scans: the transactions last seen as HELD, by transaction id.
type Holds = BTreeMap<String, Hold>;

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Hold {
    /// Unix seconds. Bounds how far a removal reaches back.
    created_at: u64,
    /// "Example Cafe: -12.50 AUD". A removed hold has no body to read, so its
    /// event text comes from here.
    summary: String,
    /// `started_at` of the scan whose Held listing last returned this id.
    /// A hold has departed when this is not the current scan's `started_at`.
    listed_in: u64,
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
    Ping,
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
/// from a proxy or a retired route, and proves nothing about a transaction.
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

impl ErrorBody {
    fn is_not_found(&self) -> bool {
        !self.errors.is_empty() && self.errors.iter().all(|error| error.status == "404")
    }
}

struct Transaction {
    id: String,
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

/// `None` without an id, a status or a creation time. A wrong shape in any
/// other field reads as absent. Category, tags and note are not read, because
/// the owner edits them and an edit is not an event.
fn parse(raw: &serde_json::Value) -> Option<Transaction> {
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
    let id = text("/id").filter(|id| {
        !id.is_empty() && id.len() <= MAX_ID_BYTES && !id.chars().any(char::is_control)
    })?;
    let status = match shown("/attributes/status", 40)?.as_str() {
        "HELD" => Status::Held,
        "SETTLED" => Status::Settled,
        other => Status::Other(other.to_owned()),
    };
    Some(Transaction {
        id: id.to_owned(),
        status,
        created_at: parse_timestamp_ms(text("/attributes/createdAt")?)? / 1000,
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
    let held_listing = checkpoint.scan.state.phase == Phase::Held;
    let started_at = checkpoint.scan.started_at;
    let mut events = Vec::new();
    let mut malformed = 0;
    let mut too_many_holds = false;
    for raw in items {
        let Some(transaction) = parse(raw) else {
            malformed += 1;
            continue;
        };
        if !checkpoint.covers(transaction.created_at) {
            continue;
        }
        events.push(describe(&transaction).into_event(key));
        if transaction.status != Status::Held {
            checkpoint.kept.remove(&transaction.id);
            continue;
        }
        let listed_before = checkpoint
            .kept
            .get(&transaction.id)
            .map(|hold| hold.listed_in);
        if listed_before.is_none() && checkpoint.kept.len() >= MAX_HOLDS {
            too_many_holds = true;
            continue;
        }
        let listed_in = if held_listing {
            started_at
        } else {
            listed_before.unwrap_or(0)
        };
        checkpoint.kept.insert(
            transaction.id.clone(),
            Hold {
                created_at: transaction.created_at,
                summary: summarize(&transaction),
                listed_in,
            },
        );
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
    let departed = has_departed(checkpoint);
    let state = &mut checkpoint.scan.state;
    Ok(match state.phase {
        Phase::Recent => {
            state.phase = Phase::Held;
            Step::Next(None)
        }
        _ if departed => {
            state.phase = Phase::Departed;
            Step::Next(None)
        }
        _ => Step::Done {
            floor: state.reach_back,
        },
    })
}

fn has_departed(checkpoint: &Checkpoint) -> bool {
    let started_at = checkpoint.scan.started_at;
    checkpoint
        .kept
        .values()
        .any(|hold| hold.listed_in != started_at)
}

/// Takes out up to `limit` holds that the Held listing of this scan did not
/// return, oldest first. `resolve` puts back the ones that are still held.
fn take_departed(checkpoint: &mut Checkpoint, limit: usize) -> Vec<(String, Hold)> {
    let started_at = checkpoint.scan.started_at;
    let mut departed: Vec<(u64, String)> = checkpoint
        .kept
        .iter()
        .filter(|(_, hold)| hold.listed_in != started_at)
        .map(|(id, hold)| (hold.created_at, id.clone()))
        .collect();
    departed.sort();
    departed
        .into_iter()
        .take(limit)
        .filter_map(|(_, id)| checkpoint.kept.remove_entry(&id))
        .collect()
}

/// The current state of one transaction. `None` when Up answers 404 with its
/// documented error body, which means that the transaction no longer exists.
async fn look_up(session: &Session<'_>, id: &str) -> Result<Option<Transaction>, FeedFailure> {
    let reply = session
        .get(&Target::fixed(TRANSACTIONS).segment(id))
        .await?;
    if reply.status == 404 {
        let documented = reply
            .body_as::<ErrorBody>()
            .is_some_and(|body| body.is_not_found());
        return if documented {
            Ok(None)
        } else {
            Err(HttpFailure::Status(404).into())
        };
    }
    let one: One = reply.json()?;
    match parse(&one.data) {
        Some(transaction) if transaction.id == id => Ok(Some(transaction)),
        _ => Err(FeedFailure::Malformed { count: 1 }),
    }
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
    id: String,
    hold: Hold,
    found: Option<Transaction>,
    key: &SourceKey,
) -> SourceEvent {
    let started_at = checkpoint.scan.started_at;
    match found {
        Some(transaction) => {
            // Still held: the listing changed while this scan read it.
            if transaction.status == Status::Held {
                checkpoint.kept.insert(
                    id,
                    Hold {
                        created_at: transaction.created_at,
                        summary: summarize(&transaction),
                        listed_in: started_at,
                    },
                );
            }
            describe(&transaction).into_event(key)
        }
        None => {
            let floor = hold
                .created_at
                .max(started_at.saturating_sub(MAX_REACH_BACK_SECONDS));
            let state = &mut checkpoint.scan.state;
            state.reach_back = Some(state.reach_back.map_or(floor, |earlier| earlier.min(floor)));
            describe_removed(id, &hold).into_event(key)
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
        id: transaction.id.clone(),
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
    feed::clip(&summary, 160)
}

/// The text does not say "refunded" or "settled", because Up does not say which happened.
fn describe_removed(id: String, hold: &Hold) -> FeedItem {
    FeedItem {
        id,
        title: format!("{} (hold removed)", hold.summary),
        text: "Status: hold removed\nUp no longer lists this held transaction. Up removes a hold when the merchant releases it, or when Up replaces it with a separate settled transaction.".into(),
        occurred_at: None,
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    };

    use serde_json::{Value, json};

    use super::*;
    use crate::{
        background::{self, BackgroundRequest, BackgroundResponse},
        protocol::{HostResult, SourceState},
        sources::{
            SourceConfig, SourceCoverage,
            http::testing::{
                Canned, FakeApi, Seen, credential_script, curl_shim, failing_credential_script,
                query_of, shim_runs,
            },
        },
    };

    const NOW: u64 = 1_795_000_000;
    const HOUR: u64 = 3_600;
    const DAY: u64 = 86_400;
    const SPACING: u64 = 300;
    const TOKEN: &str = "example-up-token";
    const FOREIGN: &str = "Up checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read.";
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

    /// The state of the invented Up account. A test edits it between polls.
    struct World {
        rows: Vec<Row>,
        customer: &'static str,
        since_compares_settled_at: bool,
        page_size: usize,
        /// Answers a request before the account does, for a failure the account cannot produce.
        script: Option<Script>,
    }

    impl World {
        fn settle(&mut self, id: &str, amount: &'static str, at: u64) {
            let row = self.rows.iter_mut().find(|row| row.id == id).unwrap();
            row.status = "SETTLED";
            row.settled = Some(at);
            row.amount = amount;
        }

        fn delete(&mut self, id: &str) {
            self.rows.retain(|row| row.id != id);
        }

        fn listing(&self, seen: &Seen) -> Canned {
            let since_text = seen.query("filter[since]");
            let since = since_text
                .as_deref()
                .map(|text| parse_timestamp_ms(text).unwrap() / 1000);
            let status = seen.query("filter[status]");
            let after: usize = seen
                .query("page[after]")
                .map_or(0, |offset| offset.parse().unwrap());
            let mut rows: Vec<&Row> = self
                .rows
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
    }

    impl Harness {
        async fn start(rows: Vec<Row>) -> Self {
            let world = Arc::new(Mutex::new(World {
                rows,
                customer: "example-customer-1",
                since_compares_settled_at: false,
                page_size: 100,
                script: None,
            }));
            let account = world.clone();
            let api = FakeApi::start(move |seen| {
                let world = account.lock().unwrap();
                if let Some(canned) = world.script.as_ref().and_then(|script| script(seen)) {
                    return canned;
                }
                if seen.bearer.as_deref() != Some(TOKEN) {
                    return up_error(401, "Not Authorized");
                }
                match seen.path() {
                    "/util/ping" => Canned::json(
                        200,
                        json!({ "meta": { "id": world.customer, "statusEmoji": "⚡️" } }),
                    ),
                    "/transactions" => world.listing(seen),
                    path => path
                        .strip_prefix("/transactions/")
                        .and_then(|id| world.rows.iter().find(|row| row.id == id))
                        .map_or_else(
                            || up_error(404, "Not Found"),
                            |row| Canned::json(200, json!({ "data": row.json() })),
                        ),
                }
            })
            .await;
            Self {
                api,
                world,
                dir: tempfile::tempdir().unwrap(),
            }
        }

        fn world(&self) -> std::sync::MutexGuard<'_, World> {
            self.world.lock().unwrap()
        }

        fn script(&self, script: impl Fn(&Seen) -> Option<Canned> + Send + 'static) {
            self.world().script = Some(Box::new(script));
        }

        /// A new adapter, as the coordinator builds one for every page.
        fn source(&self) -> UpSource {
            UpSource::new(
                "everyday".into(),
                Some(self.api.url.clone()),
                credential_script(self.dir.path(), TOKEN),
            )
            .unwrap()
        }

        async fn poll(&self, saved: Option<&SourceCheckpoint>, now: u64) -> SourceBatch {
            self.source().poll_at(saved, now).await
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
                let batch = source().poll_at(saved.as_ref(), now).await;
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

        let ping = up.poll(None, NOW).await;
        assert_eq!(ping.coverage, SourceCoverage::More);
        assert!(ping.events.is_empty());
        let recent = up.poll(ping.checkpoint.as_ref(), NOW).await;
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
                "/transactions?filter[status]=HELD&page[size]=100".to_owned(),
            ],
            "an idle scan is three requests"
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
            3,
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
        assert_eq!(requested.len(), 3, "a removed hold is not looked up again");
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
        let later = NOW + 2 * DAY + SPACING;
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
            .settle("example-transaction-2", "-30.00", NOW + DAY);
        let mark = up.targets().len();
        let (second, _) = up.scan(Some(&saved), NOW + DAY + SPACING).await;

        assert_eq!(titles(&second), ["Example Books: -30.00 AUD (settled)"]);
        assert_eq!(second[0].id, first[1].id);
        assert_ne!(second[0].version, first[1].version);
        assert_eq!(
            up.targets_since(mark).len(),
            3,
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
        assert_eq!(up.targets_since(mark).len(), 3, "nothing is looked up");
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

        let ping = up.poll(None, NOW).await;
        let first = up.poll(ping.checkpoint.as_ref(), NOW).await;
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
        for _ in 0..3 {
            let adapter = up.source();
            let batch = adapter.poll_at(saved.as_ref(), NOW).await;
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
        assert_eq!(requested[2].query("page[after]").as_deref(), Some("1"));
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
        let ping = up.poll(Some(&saved), later).await;
        let recent = up.poll(ping.checkpoint.as_ref(), later).await;
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
            let refused = source.poll_at(Some(&saved), NOW + SPACING).await;
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

        let ping = up.poll(None, NOW).await;
        for attempt in 0..2 {
            let stopped = up.poll(ping.checkpoint.as_ref(), NOW + attempt).await;
            assert_eq!(stopped.coverage, partial(TOO_MANY_HOLDS));
            assert!(stopped.checkpoint.is_none());
            assert_eq!(
                stopped.events.len(),
                MAX_HOLDS + 1,
                "every listed transaction is still delivered"
            );
        }

        up.world().delete("example-hold-000");
        let (_, saved) = up.scan(ping.checkpoint.as_ref(), NOW).await;
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
        up.world().script = None;
        let ping = up.poll(Some(&saved), later).await;

        up.script(|seen| (seen.path() == "/transactions").then(|| up_error(404, "Not Found")));
        let listing = up.poll(ping.checkpoint.as_ref(), later).await;
        assert_eq!(listing.coverage, not_found);
        assert!(listing.events.is_empty());
        up.world().script = None;
        let recent = up.poll(ping.checkpoint.as_ref(), later).await;
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

        let refused = source.poll_at(None, NOW).await;

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
    async fn a_timeout_reports_its_fixed_text() {
        let up = Harness::start(Vec::new()).await;
        up.script(|_| Some(Canned::hang()));

        let timed_out = up.source().with_max_time(1).poll_at(None, NOW).await;

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

        let unreachable = source.poll_at(None, NOW).await;

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
        let resting = no_credential.poll_at(Some(&saved), NOW + SPACING - 1).await;

        assert_eq!(resting.coverage, SourceCoverage::Complete);
        assert_eq!(resting.checkpoint.as_ref(), Some(&saved));
        assert!(resting.events.is_empty());
        assert!(
            up.targets_since(mark).is_empty(),
            "neither the credential command nor a request runs"
        );

        let (events, _) = up.scan(Some(&saved), NOW + SPACING).await;
        assert_eq!(titles(&events), ["Example Cafe: -12.50 AUD (settled)"]);
        assert_eq!(up.targets_since(mark).len(), 3);
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
        let ping = up.poll(None, NOW).await;
        let first = up.poll(ping.checkpoint.as_ref(), NOW).await;
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
        let ping = up.poll(None, NOW).await;
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
            let refused = up.poll(ping.checkpoint.as_ref(), NOW).await;
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
        let ping = up.poll(None, NOW).await;
        let good = settled("example-transaction-1", "Example Cafe", "-5.00", NOW - HOUR).json();
        let mut without_id = good.clone();
        without_id.as_object_mut().unwrap().remove("id");
        let mut without_time = good.clone();
        without_time["attributes"]["createdAt"] = json!("yesterday");
        let page = json!({ "data": [without_id, good, without_time], "links": { "prev": null, "next": null } });
        up.script(move |seen| {
            (seen.path() == "/transactions").then(|| Canned::json(200, page.clone()))
        });

        let stopped = up.poll(ping.checkpoint.as_ref(), NOW).await;

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
        let ping = up.poll(None, NOW).await;
        up.script(|seen| {
            (seen.path() == "/transactions")
                .then(|| Canned::json(200, json!({ "data": [], "links": {} })))
        });

        let unreadable = up.poll(ping.checkpoint.as_ref(), NOW).await;

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
        let refused = up.source().with_curl(refusing).poll_at(None, NOW).await;
        assert_eq!(
            refused.coverage,
            unavailable("Up API is unreachable; checkpoint retained."),
            "the shim does refuse an argument it is told to refuse"
        );
        assert!(up.dir.path().join("refused").exists());
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
                (SourceCoverage::More, 0),
                (SourceCoverage::More, 1),
                (
                    unavailable("Up API returned HTTP 503; checkpoint retained."),
                    0
                ),
            ],
            "the ping, the first page, and the failure that ends the round"
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
            requested[0].contains("page[after]=1&"),
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
