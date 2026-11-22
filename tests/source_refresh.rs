use std::{
    fs,
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{SystemTime, UNIX_EPOCH},
};

use agent_cli::{
    background::{self, BackgroundRequest, BackgroundResponse},
    protocol::{HostResult, RuntimeCommand, RuntimeEventKind, SourceState},
    runtime::{MAX_FRAME_BYTES, OwnerClaim, Runtime},
    sources::{Source, SourceConfig, SourceCoverage, slack::SlackSource},
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

/// An invented Up account on a loopback address. It has one held and two
/// settled transactions and lists them one per page, newest first.
struct FakeUp {
    url: String,
    requests: Arc<Mutex<Vec<String>>>,
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
                let (status, body) =
                    if request.contains(&format!("Authorization: Bearer {UP_TOKEN}\r\n")) {
                        up_answer(&target, &origin, &rows, fails.load(Ordering::Relaxed))
                    } else {
                        up_error(401)
                    };
                seen.lock().unwrap().push(target);
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
        self.requests.lock().unwrap().clone()
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

fn up_answer(target: &str, origin: &str, rows: &[Value], second_page_fails: bool) -> (u16, Value) {
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    match path {
        "/util/ping" => (
            200,
            json!({ "meta": { "id": "example-customer-1", "statusEmoji": "ok" } }),
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
    let mut cursor = None;
    let mut pages = Vec::new();
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
            return pages;
        }
    }
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
    let page = |coverage, sent_events, new_events, checkpoint_advanced| AdmittedPage {
        coverage,
        sent_events,
        new_events,
        checkpoint_advanced,
    };
    let failed = SourceCoverage::Unavailable {
        message: "Up API returned HTTP 503; checkpoint retained.".into(),
    };

    let runtime = start_runtime(&state);
    assert_eq!(
        refresh_into_journal(&runtime, &config).await,
        [
            page(SourceCoverage::More, 0, 0, true),
            page(SourceCoverage::More, 1, 1, true),
            page(failed.clone(), 0, 0, false),
        ],
        "the identity check, the first page, and the failure that ends the round"
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
            "/transactions?page[after]=1&page[size]=1",
            "/transactions?page[after]=2&page[size]=1",
            "/transactions?filter[status]=HELD&page[size]=100",
        ],
        "the scan resumes at the page the journal saved before the failure and the restart"
    );
    runtime.close().await.unwrap();
}
