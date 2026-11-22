use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use agent_cli::{
    background::{self, BackgroundRequest, BackgroundResponse},
    protocol::{HostResult, RuntimeCommand, RuntimeEventKind, SourceState},
    runtime::{MAX_FRAME_BYTES, OwnerClaim, Runtime},
    sources::{
        Source, SourceBatch, SourceCheckpoint, SourceConfig, SourceCoverage, SourceKey,
        slack::SlackSource,
    },
};
use serde::Serialize;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    task::JoinHandle,
    time::timeout,
};

#[path = "fixtures/hang_limit.rs"]
mod hang_limit;
use hang_limit::TEST_HANG_LIMIT;

#[derive(Serialize)]
struct SearchResponse {
    ok: bool,
    messages: SearchMessages,
}

#[derive(Serialize)]
struct SearchMessages {
    matches: Vec<SearchMessage>,
    paging: SearchPaging,
}

#[derive(Serialize)]
struct SearchMessage {
    ts: String,
    text: String,
    channel: SearchChannel,
}

#[derive(Serialize)]
struct SearchChannel {
    id: String,
    name: String,
}

#[derive(Serialize)]
struct SearchPaging {
    next_cursor: String,
}

fn response(page: usize, text_bytes: usize, next_cursor: &str) -> SearchResponse {
    SearchResponse {
        ok: true,
        messages: SearchMessages {
            matches: vec![SearchMessage {
                ts: format!("1700000000.{page:06}"),
                text: "x".repeat(text_bytes),
                channel: SearchChannel {
                    id: "CEXAMPLE".into(),
                    name: "example".into(),
                },
            }],
            paging: SearchPaging {
                next_cursor: next_cursor.into(),
            },
        },
    }
}

fn helper(directory: &Path, text_bytes: &[usize]) -> Vec<String> {
    for (page, length) in text_bytes.iter().enumerate() {
        let next = if page + 1 == text_bytes.len() {
            String::new()
        } else {
            format!("page-{}", page + 1)
        };
        fs::write(
            directory.join(format!("{page}.json")),
            serde_json::to_vec(&response(page, *length, &next)).unwrap(),
        )
        .unwrap();
    }
    let script = directory.join("source-read");
    fs::write(
        &script,
        r#"#!/bin/sh
for argument in "$@"; do
    case "$argument" in cursor=*) cursor="${argument#cursor=}" ;; esac
done
case "$cursor" in
    '*') page=0 ;;
    page-*) page="${cursor#page-}" ;;
    *) exit 1 ;;
esac
exec cat "$1/$page.json"
"#,
    )
    .unwrap();
    // Read the freshly written fixture as data instead of executing it. On Linux,
    // another test's concurrent spawn can briefly inherit its writable descriptor.
    vec![
        "sh".into(),
        script.to_str().unwrap().to_owned(),
        directory.to_str().unwrap().to_owned(),
    ]
}

#[tokio::test]
async fn real_source_pages_cross_the_transport_individually_and_retain_account_checkpoints() {
    let directory = tempfile::tempdir().unwrap();
    let command = helper(directory.path(), &[1_500_000; 3]);
    let accounts = ["workspace-one", "workspace-two"];
    let config: Vec<_> = accounts
        .iter()
        .map(|account| SourceConfig::Slack {
            enabled: true,
            command: command.clone(),
            account: (*account).into(),
        })
        .collect();
    let mut states: Vec<SourceState> = Vec::new();
    let mut cursor = None;
    let mut total_bytes = 0;
    let mut pages = 0;
    let mut seen = std::collections::BTreeSet::new();
    loop {
        let response = background::execute(BackgroundRequest::PollSources {
            sources: config.clone(),
            states: states.clone(),
            cursor,
        })
        .await
        .unwrap();
        let wire = serde_json::to_vec(&HostResult::Background { response }).unwrap();
        assert!(wire.len() <= MAX_FRAME_BYTES);
        total_bytes += wire.len();
        let HostResult::Background {
            response:
                BackgroundResponse::Sources {
                    reads,
                    cursor: next,
                    ..
                },
        } = serde_json::from_slice(&wire).unwrap()
        else {
            panic!("The source response did not survive the wire round trip");
        };
        assert_eq!(reads.len(), 1);
        let read = reads.into_iter().next().unwrap();
        assert_eq!(
            read.batch.source.account,
            accounts[if pages < 8 {
                pages / 4
            } else {
                (pages - 8) / 2
            }]
        );
        assert_eq!(read.batch.events.len(), 1);
        assert_eq!(read.batch.events[0].text.len(), 1_500_000);
        seen.insert((
            read.batch.source.account.clone(),
            read.batch.events[0].id.clone(),
        ));
        let previous = states
            .iter_mut()
            .find(|state| state.source == read.batch.source);
        assert_eq!(
            read.expected_checkpoint,
            previous.as_ref().and_then(|state| state.checkpoint.clone())
        );
        assert!(read.batch.checkpoint.is_some());
        let admitted = SourceState {
            last_completed_at: None,
            progress: read.batch.progress,
            source: read.batch.source,
            checkpoint: read.batch.checkpoint,
            coverage: read.batch.coverage,
            checked_at: 0,
        };
        match previous {
            Some(previous) => *previous = admitted,
            None => states.push(admitted),
        }
        pages += 1;
        cursor = next;
        if cursor.is_none()
            && states.len() == 2
            && states
                .iter()
                .all(|state| state.coverage == SourceCoverage::Complete)
        {
            break;
        }
        assert!(
            pages < 12,
            "The source cursor did not finish the account scan"
        );
    }
    assert_eq!(
        pages, 12,
        "Recent observations alternate with all three retained backfill pages, without starving the second account"
    );
    for account in accounts {
        for page in 0..3 {
            assert!(seen.contains(&(account.to_owned(), format!("CEXAMPLE:1700000000.{page:06}"))));
        }
    }
    assert!(total_bytes > MAX_FRAME_BYTES);
    assert_eq!(states.len(), 2);
    assert!(
        states
            .iter()
            .all(|state| state.coverage == SourceCoverage::Complete)
    );
}

#[tokio::test]
async fn normalization_that_exceeds_the_page_budget_preserves_the_supplied_checkpoint() {
    let directory = tempfile::tempdir().unwrap();
    let raw_overhead = serde_json::to_vec(&response(1, 0, "")).unwrap().len();
    let command = helper(
        directory.path(),
        &[32, MAX_FRAME_BYTES / 2 - raw_overhead - 1],
    );
    let account = "workspace-oversized".to_owned();
    let source = SlackSource::new(command.clone(), account.clone()).unwrap();
    let first = source.poll(None).await.unwrap();
    assert_eq!(first.coverage, SourceCoverage::More);
    let backfill = source.poll(first.checkpoint.as_ref()).await.unwrap();
    let recent = source.poll(backfill.checkpoint.as_ref()).await.unwrap();
    let checkpoint = recent.checkpoint.unwrap();
    let normalized = source.poll(Some(&checkpoint)).await.unwrap();
    assert!(matches!(
        normalized.coverage,
        SourceCoverage::Unavailable { .. }
    ));
    assert!(normalized.checkpoint.is_none());
    assert!(serde_json::to_vec(&normalized).unwrap().len() <= MAX_FRAME_BYTES / 2);
    let response = background::execute(BackgroundRequest::PollSources {
        sources: vec![SourceConfig::Slack {
            enabled: true,
            command,
            account,
        }],
        states: vec![SourceState {
            last_completed_at: None,
            progress: None,
            source: source.key(),
            checkpoint: Some(checkpoint.clone()),
            coverage: SourceCoverage::More,
            checked_at: 0,
        }],
        cursor: None,
    })
    .await
    .unwrap();
    let wire = serde_json::to_vec(&HostResult::Background { response }).unwrap();
    assert!(wire.len() <= MAX_FRAME_BYTES);
    let HostResult::Background {
        response: BackgroundResponse::Sources { reads, cursor, .. },
    } = serde_json::from_slice(&wire).unwrap()
    else {
        panic!("The source response did not survive the wire round trip");
    };
    assert!(cursor.is_none());
    assert_eq!(reads.len(), 1);
    let read = reads.into_iter().next().unwrap();
    assert_eq!(read.expected_checkpoint, Some(checkpoint));
    assert!(matches!(
        read.batch.coverage,
        SourceCoverage::Unavailable { .. }
    ));
    assert!(read.batch.events.is_empty());
    assert!(read.batch.checkpoint.is_none());
}

#[tokio::test]
async fn local_helper_can_run_while_its_script_is_open_for_writing() {
    let directory = tempfile::tempdir().unwrap();
    let command = helper(directory.path(), &[32]);
    // A concurrent fork can retain this descriptor after the fixture writer closes.
    let _writer = fs::OpenOptions::new()
        .write(true)
        .open(directory.path().join("source-read"))
        .unwrap();
    let source = SlackSource::new(command, "workspace-fixture".into()).unwrap();
    let batch = source.poll(None).await.unwrap();
    assert_eq!(batch.coverage, SourceCoverage::More);
    assert_eq!(batch.events.len(), 1);
    assert_eq!(batch.events[0].text.len(), 32);
}

const UP_TOKEN: &str = "example-up-token";
const SECOND_UP_TOKEN: &str = "example-second-up-token";
const UP_FOREIGN: &str = "Up checkpoint belongs to another account or configuration; change the account label to start a fresh seven-day read.";
const UP_CLOCK: &str = "Up checkpoint holds a time more than five minutes ahead of this computer's clock; check the clock. The source continues from this checkpoint when the clock is right. To start a fresh seven-day read instead, change the account label.";

/// An invented Up account on a loopback address. It has one held and two
/// settled transactions and lists them one per page, newest first. A second
/// customer, with a token of its own, has two settled transactions.
struct FakeUp {
    url: String,
    /// The target and the bearer token of each request.
    requests: Arc<Mutex<Vec<(String, String)>>>,
    second_page_fails: Arc<AtomicBool>,
    server: JoinHandle<()>,
}

impl Drop for FakeUp {
    fn drop(&mut self) {
        self.server.abort();
    }
}

impl FakeUp {
    async fn start() -> Self {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let rows = [
            up_transaction(
                "example-transaction-3",
                "HELD",
                "Example Hotel",
                now - 3_600,
            ),
            up_transaction(
                "example-transaction-2",
                "SETTLED",
                "Example Books",
                now - 7_200,
            ),
            up_transaction(
                "example-transaction-1",
                "SETTLED",
                "Example Cafe",
                now - 10_800,
            ),
        ];
        let second_rows = [
            up_transaction(
                "example-second-transaction-2",
                "SETTLED",
                "Example Pharmacy",
                now - 1_800,
            ),
            up_transaction(
                "example-second-transaction-1",
                "SETTLED",
                "Example Pharmacy",
                now - 5_400,
            ),
        ];
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let second_page_fails = Arc::new(AtomicBool::new(true));
        let (origin, seen, fails) = (url.clone(), requests.clone(), second_page_fails.clone());
        let server = tokio::spawn(async move {
            while let Ok((mut socket, _)) = listener.accept().await {
                let mut request = Vec::new();
                let mut chunk = [0_u8; 2048];
                while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                    match socket.read(&mut chunk).await {
                        Ok(count) if count > 0 => request.extend_from_slice(&chunk[..count]),
                        _ => break,
                    }
                }
                let request = String::from_utf8_lossy(&request).into_owned();
                let target = request.split(' ').nth(1).unwrap_or_default().to_owned();
                let bearer = request
                    .split("\r\n")
                    .find_map(|line| line.strip_prefix("Authorization: Bearer "))
                    .unwrap_or_default()
                    .to_owned();
                let fails = fails.load(Ordering::Relaxed);
                let (status, body) = match bearer.as_str() {
                    UP_TOKEN => up_answer(&target, &origin, "example-customer-1", &rows, fails),
                    SECOND_UP_TOKEN => {
                        up_answer(&target, &origin, "example-customer-2", &second_rows, fails)
                    }
                    _ => up_error(401),
                };
                seen.lock().unwrap().push((target, bearer));
                let body = body.to_string();
                let response = format!(
                    "HTTP/1.1 {status} Scripted\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = socket.write_all(response.as_bytes()).await;
            }
        });
        Self {
            url,
            requests,
            second_page_fails,
            server,
        }
    }

    fn requests(&self) -> Vec<String> {
        let requests = self.requests.lock().unwrap();
        requests.iter().map(|(target, _)| target.clone()).collect()
    }

    fn requests_with(&self, token: &str) -> Vec<String> {
        let requests = self.requests.lock().unwrap();
        requests
            .iter()
            .filter(|(_, bearer)| bearer == token)
            .map(|(target, _)| target.clone())
            .collect()
    }
}

fn up_transaction(id: &str, status: &str, description: &str, created: u64) -> Value {
    let time = |seconds: u64| {
        chrono::DateTime::from_timestamp(i64::try_from(seconds).unwrap(), 0)
            .unwrap()
            .to_rfc3339()
    };
    let amount = json!({ "currencyCode": "AUD", "value": "-20.00" });
    json!({
        "type": "transactions",
        "id": id,
        "attributes": {
            "status": status,
            "description": description,
            "message": null,
            "holdInfo": (status == "HELD").then(|| json!({ "amount": amount, "foreignAmount": null })),
            "amount": amount,
            "foreignAmount": null,
            "transactionType": "Purchase",
            "settledAt": (status == "SETTLED").then(|| time(created + 60)),
            "createdAt": time(created),
        },
        "relationships": { "transferAccount": { "data": null } }
    })
}

fn up_error(status: u16) -> (u16, Value) {
    (
        status,
        json!({ "errors": [{ "status": status.to_string(), "title": "Scripted failure", "detail": "example-private-detail" }] }),
    )
}

fn up_answer(
    target: &str,
    origin: &str,
    customer: &str,
    rows: &[Value],
    second_page_fails: bool,
) -> (u16, Value) {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    match path {
        "/util/ping" => (
            200,
            json!({ "meta": { "id": customer, "statusEmoji": "ok" } }),
        ),
        "/transactions" => {
            let held_only = query.contains("filter[status]=HELD");
            let after: usize = query
                .split('&')
                .find_map(|pair| pair.strip_prefix("page[after]="))
                .map_or(0, |offset| offset.parse().unwrap());
            if after == 1 && !held_only && second_page_fails {
                return up_error(503);
            }
            let listed: Vec<&Value> = rows
                .iter()
                .filter(|row| !held_only || row["attributes"]["status"] == "HELD")
                .collect();
            let next = (after + 1 < listed.len()).then(|| {
                let filter = if held_only {
                    "&filter[status]=HELD"
                } else {
                    ""
                };
                format!(
                    "{origin}/transactions?page[after]={}&page[size]=1{filter}",
                    after + 1
                )
            });
            let data: Vec<&Value> = listed.into_iter().skip(after).take(1).collect();
            (
                200,
                json!({ "data": data, "links": { "prev": null, "next": next } }),
            )
        }
        _ => up_error(404),
    }
}

fn start_runtime(state: &Path) -> Runtime {
    let bridge = std::env::var_os("AGENT_RUNTIME_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            Path::new(env!("CARGO_MANIFEST_DIR")).join("runtime/dist/src/bridge.js")
        });
    assert!(bridge.is_file(), "Build the runtime before this test");
    Runtime::start(&bridge, OwnerClaim::acquire(state, &bridge, None).unwrap()).unwrap()
}

async fn ask(runtime: &Runtime, command: RuntimeCommand) -> Vec<RuntimeEventKind> {
    let mut call = runtime.request(command).await.unwrap();
    let mut events = Vec::new();
    loop {
        let event = timeout(TEST_HANG_LIMIT, call.events.recv())
            .await
            .expect("The runtime request did not finish")
            .expect("The runtime request closed without its terminal event");
        match event {
            RuntimeEventKind::Done => return events,
            RuntimeEventKind::Failure { message, .. } => {
                panic!("The runtime request failed: {message}")
            }
            event => events.push(event),
        }
    }
}

async fn journal_states(runtime: &Runtime) -> Vec<SourceState> {
    ask(runtime, RuntimeCommand::SourceStates)
        .await
        .into_iter()
        .find_map(|event| match event {
            RuntimeEventKind::Sources { sources } => Some(sources),
            _ => None,
        })
        .expect("The journal did not report its states")
}

#[derive(Debug, PartialEq)]
struct AdmittedPage {
    coverage: SourceCoverage,
    sent_events: usize,
    new_events: u32,
    checkpoint_advanced: bool,
}

/// One refresh round against the journal of a running runtime. It makes the
/// calls of `refreshSources` in `runtime/src/bridge.ts` in the same order:
/// read the journal's states, poll one page, admit it, and repeat while the
/// poll returns a cursor.
async fn refresh_into_journal(runtime: &Runtime, config: &[SourceConfig]) -> Vec<AdmittedPage> {
    refresh_with_titles(runtime, config).await.0
}

/// `refresh_into_journal`, and the title of every event that the round sent to the journal.
async fn refresh_with_titles(
    runtime: &Runtime,
    config: &[SourceConfig],
) -> (Vec<AdmittedPage>, Vec<String>) {
    let mut cursor = None;
    let mut pages = Vec::new();
    let mut titles = Vec::new();
    loop {
        let response = background::execute(BackgroundRequest::PollSources {
            sources: config.to_vec(),
            states: journal_states(runtime).await,
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
            panic!("The source response did not survive the wire round trip");
        };
        for read in reads {
            let coverage = read.batch.coverage.clone();
            let sent_events = read.batch.events.len();
            titles.extend(read.batch.events.iter().map(|event| event.title.clone()));
            let (new_events, checkpoint_advanced) = ask(
                runtime,
                RuntimeCommand::IngestSource {
                    batch: read.batch,
                    expected_checkpoint: read.expected_checkpoint,
                },
            )
            .await
            .into_iter()
            .find_map(|event| match event {
                RuntimeEventKind::SourceAdmitted {
                    new_events,
                    checkpoint_advanced,
                    ..
                } => Some((new_events, checkpoint_advanced)),
                _ => None,
            })
            .expect("The journal did not report the admission");
            pages.push(AdmittedPage {
                coverage,
                sent_events,
                new_events,
                checkpoint_advanced,
            });
        }
        cursor = next;
        if cursor.is_none() {
            return (pages, titles);
        }
    }
}

/// A state directory, and an Up source whose credential command prints the
/// token that `use_token` wrote last.
struct UpSetup {
    directory: tempfile::TempDir,
    state: PathBuf,
    config: [SourceConfig; 1],
}

impl UpSetup {
    fn new(up: &FakeUp) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let state = directory.path().join("state");
        fs::create_dir(&state).unwrap();
        let credential = directory.path().join("credential");
        let setup = Self {
            config: [SourceConfig::Up {
                enabled: true,
                account: "everyday".into(),
                credential_command: vec!["sh".into(), credential.to_str().unwrap().to_owned()],
                url: Some(up.url.clone()),
            }],
            directory,
            state,
        };
        setup.use_token(UP_TOKEN);
        setup
    }

    fn use_token(&self, token: &str) {
        fs::write(
            self.directory.path().join("credential"),
            format!("printf '%s' '{token}'\n"),
        )
        .unwrap();
    }
}

fn page(
    coverage: SourceCoverage,
    sent_events: usize,
    new_events: u32,
    checkpoint_advanced: bool,
) -> AdmittedPage {
    AdmittedPage {
        coverage,
        sent_events,
        new_events,
        checkpoint_advanced,
    }
}

fn up_unavailable(message: &str) -> SourceCoverage {
    SourceCoverage::Unavailable {
        message: message.into(),
    }
}

async fn up_checkpoint(runtime: &Runtime) -> SourceCheckpoint {
    journal_states(runtime)
        .await
        .into_iter()
        .find(|state| state.source.provider == "up")
        .and_then(|state| state.checkpoint)
        .expect("The journal holds no Up checkpoint")
}

/// Every Unix time in a checkpoint is a number this large, and no count is.
const EARLIEST_TIME: u64 = 1_000_000_000;

fn latest_time(value: &Value) -> u64 {
    match value {
        Value::Number(number) => number
            .as_u64()
            .filter(|time| *time >= EARLIEST_TIME)
            .unwrap_or(0),
        Value::Array(items) => items.iter().map(latest_time).max().unwrap_or(0),
        Value::Object(fields) => fields.values().map(latest_time).max().unwrap_or(0),
        _ => 0,
    }
}

fn move_times(value: &mut Value, seconds: u64) {
    match value {
        Value::Number(number) => {
            if let Some(time) = number.as_u64().filter(|time| *time >= EARLIEST_TIME) {
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

/// Replaces the journal's Up checkpoint with the one a clock would have
/// written that ran ahead, so that its latest time is `ahead` seconds after now.
async fn save_as_written_by_a_clock_ahead(runtime: &Runtime, ahead: u64) -> SourceCheckpoint {
    let saved = up_checkpoint(runtime).await;
    let mut value: Value = serde_json::from_str(&saved.value).unwrap();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let shift = now + ahead - latest_time(&value);
    move_times(&mut value, shift);
    let moved = SourceCheckpoint {
        value: value.to_string(),
    };
    let advanced = ask(
        runtime,
        RuntimeCommand::IngestSource {
            batch: SourceBatch {
                source: SourceKey {
                    provider: "up".into(),
                    account: "everyday".into(),
                },
                events: Vec::new(),
                checkpoint: Some(moved.clone()),
                coverage: SourceCoverage::More,
                progress: None,
            },
            expected_checkpoint: Some(saved),
        },
    )
    .await
    .into_iter()
    .any(|event| {
        matches!(
            event,
            RuntimeEventKind::SourceAdmitted {
                checkpoint_advanced: true,
                ..
            }
        )
    });
    assert!(advanced, "The journal did not take the moved checkpoint");
    moved
}

#[tokio::test]
async fn a_token_for_another_up_customer_after_a_restart_reads_no_transaction_into_the_real_journal()
 {
    let up = FakeUp::start().await;
    let setup = UpSetup::new(&up);

    let runtime = start_runtime(&setup.state);
    let (first_round, first_titles) = refresh_with_titles(&runtime, &setup.config).await;
    assert_eq!(
        first_round.last().map(|page| &page.coverage),
        Some(&up_unavailable(
            "Up API returned HTTP 503; checkpoint retained."
        )),
        "the first customer's scan stops between two pages"
    );
    assert_eq!(first_titles, ["Example Hotel: -20.00 AUD (held)"]);
    let saved = up_checkpoint(&runtime).await;
    runtime.close().await.unwrap();

    setup.use_token(SECOND_UP_TOKEN);
    up.second_page_fails.store(false, Ordering::Relaxed);
    let runtime = start_runtime(&setup.state);
    let (pages, titles) = refresh_with_titles(&runtime, &setup.config).await;

    assert!(
        titles
            .iter()
            .all(|title| !title.contains("Example Pharmacy")),
        "a transaction of the second customer was sent to the journal: {titles:?}"
    );
    assert!(
        titles
            .iter()
            .all(|title| !title.ends_with("(hold removed)")),
        "a hold of the first customer was reported as removed: {titles:?}"
    );
    assert_eq!(pages, [page(up_unavailable(UP_FOREIGN), 0, 0, false)]);
    assert_eq!(
        up.requests_with(SECOND_UP_TOKEN),
        ["/util/ping"],
        "the second customer's token reads no transaction"
    );
    assert_eq!(
        up_checkpoint(&runtime).await,
        saved,
        "the first customer's checkpoint is kept"
    );
    runtime.close().await.unwrap();
}

#[tokio::test]
async fn an_up_checkpoint_with_a_time_in_the_future_stops_the_real_poll_path_and_is_never_complete()
{
    let up = FakeUp::start().await;
    up.second_page_fails.store(false, Ordering::Relaxed);
    let setup = UpSetup::new(&up);
    let runtime = start_runtime(&setup.state);
    let mut rounds = 0;
    while refresh_into_journal(&runtime, &setup.config)
        .await
        .last()
        .map(|page| &page.coverage)
        != Some(&SourceCoverage::Complete)
    {
        rounds += 1;
        assert!(rounds < 4, "The first scan did not complete");
    }

    let ahead = save_as_written_by_a_clock_ahead(&runtime, 30 * 86_400).await;
    let requests_before = up.requests().len();
    for _ in 0..2 {
        assert_eq!(
            refresh_into_journal(&runtime, &setup.config).await,
            [page(up_unavailable(UP_CLOCK), 0, 0, false)],
            "a window that starts in the future holds no current transaction"
        );
    }
    assert_eq!(up.requests().len(), requests_before, "no request is made");
    assert_eq!(up_checkpoint(&runtime).await, ahead);
    runtime.close().await.unwrap();
}

#[tokio::test]
async fn a_clock_behind_an_up_checkpoint_stops_the_real_poll_path_and_the_scan_resumes_at_its_saved_page_when_the_clock_is_right()
 {
    /// Seconds between the stop and the time the clock is right again.
    const WAIT: u64 = 12;
    let up = FakeUp::start().await;
    let setup = UpSetup::new(&up);
    let runtime = start_runtime(&setup.state);
    let first_round = refresh_into_journal(&runtime, &setup.config).await;
    assert_eq!(
        first_round.last().map(|page| &page.coverage),
        Some(&up_unavailable(
            "Up API returned HTTP 503; checkpoint retained."
        )),
        "the scan stops with its second page saved"
    );
    up.second_page_fails.store(false, Ordering::Relaxed);

    let ahead = save_as_written_by_a_clock_ahead(&runtime, 300 + WAIT).await;
    let requests_before = up.requests().len();
    assert_eq!(
        refresh_into_journal(&runtime, &setup.config).await,
        [page(up_unavailable(UP_CLOCK), 0, 0, false)]
    );
    assert_eq!(up.requests().len(), requests_before, "no request is made");
    assert_eq!(up_checkpoint(&runtime).await, ahead);

    tokio::time::sleep(Duration::from_secs(WAIT + 1)).await;
    let resumed = refresh_into_journal(&runtime, &setup.config).await;
    assert_eq!(resumed[0], page(SourceCoverage::More, 1, 1, true));
    assert_eq!(
        resumed.last().map(|page| &page.coverage),
        Some(&SourceCoverage::Complete)
    );
    let transactions: Vec<String> = up.requests()[requests_before..]
        .iter()
        .filter(|target| target.starts_with("/transactions"))
        .cloned()
        .collect();
    assert_eq!(
        transactions,
        [
            "/transactions?page[after]=1&page[size]=1",
            "/transactions?page[after]=2&page[size]=1",
            "/transactions?filter[status]=HELD&page[size]=100",
        ],
        "the scan continues at the page of the kept checkpoint"
    );
    runtime.close().await.unwrap();
}

/// Refresh rounds until a scan completes. A page that reports a failure ends the test.
async fn refresh_until_complete(runtime: &Runtime, config: &[SourceConfig]) -> Vec<AdmittedPage> {
    let mut pages = Vec::new();
    for _ in 0..4 {
        let round = refresh_into_journal(runtime, config).await;
        for page in &round {
            assert!(
                matches!(
                    page.coverage,
                    SourceCoverage::More | SourceCoverage::Complete
                ),
                "The source stopped: {:?}",
                page.coverage
            );
        }
        let complete = round.last().map(|page| &page.coverage) == Some(&SourceCoverage::Complete);
        pages.extend(round);
        if complete {
            return pages;
        }
    }
    panic!("The scan did not complete");
}

#[tokio::test]
async fn an_up_feed_whose_clock_ran_ahead_reads_again_through_the_real_poll_path_and_the_journal_admits_each_item_once()
 {
    let up = FakeUp::start().await;
    up.second_page_fails.store(false, Ordering::Relaxed);
    let setup = UpSetup::new(&up);
    let runtime = start_runtime(&setup.state);
    let first_scan = refresh_until_complete(&runtime, &setup.config).await;
    assert_eq!(
        first_scan.iter().map(|page| page.new_events).sum::<u32>(),
        3,
        "the journal holds the three transactions"
    );

    save_as_written_by_a_clock_ahead(&runtime, 30 * 86_400).await;
    let requests_before = up.requests().len();
    let rewound = refresh_until_complete(&runtime, &setup.config).await;
    let listings: Vec<String> = up.requests()[requests_before..]
        .iter()
        .filter(|target| target.starts_with("/transactions"))
        .cloned()
        .collect();
    assert!(
        listings[0].contains("filter[since]=") && !listings[0].contains("page[after]"),
        "the poll after the clock ran ahead reads from a first page: {listings:?}"
    );
    assert_eq!(
        rewound.iter().map(|page| page.sent_events).sum::<usize>(),
        4,
        "the three transactions are read again, and the held one is listed twice"
    );
    assert_eq!(
        rewound.iter().map(|page| page.new_events).sum::<u32>(),
        0,
        "the journal admits no transaction a second time"
    );

    let requests_after = up.requests().len();
    refresh_until_complete(&runtime, &setup.config).await;
    assert_eq!(
        up.requests().len(),
        requests_after,
        "the next round is inside the spacing, which counts from the current clock"
    );
    runtime.close().await.unwrap();
}

#[tokio::test]
async fn up_pages_enter_the_real_source_journal_once_and_a_failed_scan_resumes_at_its_saved_page() {
    let up = FakeUp::start().await;
    let directory = tempfile::tempdir().unwrap();
    let credential = directory.path().join("credential");
    fs::write(&credential, format!("printf '%s' '{UP_TOKEN}'\n")).unwrap();
    let state = directory.path().join("state");
    fs::create_dir(&state).unwrap();
    let config = [SourceConfig::Up {
        enabled: true,
        account: "everyday".into(),
        credential_command: vec!["sh".into(), credential.to_str().unwrap().to_owned()],
        url: Some(up.url.clone()),
    }];
    let failed = SourceCoverage::Unavailable {
        message: "Up API returned HTTP 503; checkpoint retained.".into(),
    };

    let runtime = start_runtime(&state);
    assert_eq!(
        refresh_into_journal(&runtime, &config).await,
        [
            page(SourceCoverage::More, 1, 1, true),
            page(failed.clone(), 0, 0, false),
        ],
        "the first page, and the failure that ends the round"
    );
    runtime.close().await.unwrap();

    let runtime = start_runtime(&state);
    let saved = journal_states(&runtime)
        .await
        .into_iter()
        .find(|state| state.source.provider == "up")
        .expect("The journal lost the source across a restart");
    assert_eq!(saved.source.account, "everyday");
    assert_eq!(saved.coverage, failed);
    up.second_page_fails.store(false, Ordering::Relaxed);
    let requests_before = up.requests().len();
    assert_eq!(
        refresh_into_journal(&runtime, &config).await,
        [
            page(SourceCoverage::More, 1, 1, true),
            page(SourceCoverage::More, 1, 1, true),
            page(SourceCoverage::Complete, 1, 0, true),
        ],
        "the held listing sends the first page's transaction again, and the journal admits it once"
    );
    assert_eq!(
        up.requests()[requests_before..],
        [
            "/util/ping",
            "/transactions?page[after]=1&page[size]=1",
            "/util/ping",
            "/transactions?page[after]=2&page[size]=1",
            "/util/ping",
            "/transactions?filter[status]=HELD&page[size]=100",
        ],
        "the scan resumes at the page the journal saved before the failure and the restart, and checks the customer before each page"
    );
    runtime.close().await.unwrap();
}
