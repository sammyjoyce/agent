use std::{
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::{JoinHandle, JoinSet},
    time::sleep_until,
};

use crate::{
    gate::{Hold, HoldKind},
    scenario::{Ending, Turn},
};

const MAX_REQUEST_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone)]
pub struct ToolFixture {
    pub node: PathBuf,
    pub pid_file: PathBuf,
    pub owner: u32,
}

impl ToolFixture {
    fn call(&self) -> Value {
        json!({ "program": self.node, "args": ["-e", TOOL_SCRIPT, self.pid_file, self.owner.to_string()] })
    }
}

#[derive(Clone, Debug)]
pub enum End {
    Completed { at: Instant, total_tokens: u64 },
    ClosedByClient { at: Instant },
    Unexpected { reason: String },
    Failed { error: String },
}

#[derive(Clone, Debug)]
pub struct Request {
    pub turn: Option<&'static Turn>,
    pub body_bytes: usize,
    pub received: Instant,
    pub first_chunk: Option<Instant>,
    pub holds: Vec<(Hold, Option<u64>)>,
    pub end: Option<End>,
}

type Log = Arc<Mutex<Vec<Request>>>;

pub struct Provider {
    log: Log,
    server: JoinHandle<()>,
}

impl Provider {
    pub fn start(listener: TcpListener, turns: &'static [Turn], tool: ToolFixture) -> Self {
        let log = Log::default();
        let shared = log.clone();
        let server = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            while let Ok((stream, _)) = listener.accept().await {
                let (log, tool) = (shared.clone(), tool.clone());
                connections.spawn(async move { serve(stream, turns, &tool, &log).await });
            }
        });
        Self { log, server }
    }

    pub fn requests(&self) -> Result<Vec<Request>> {
        Ok(locked(&self.log)?.clone())
    }

    pub fn close(self) -> Result<Vec<Request>> {
        self.server.abort();
        self.requests()
    }
}

impl Drop for Provider {
    fn drop(&mut self) {
        self.server.abort();
    }
}

fn locked(log: &Log) -> Result<MutexGuard<'_, Vec<Request>>> {
    log.lock()
        .map_err(|_| anyhow::anyhow!("The provider log is unavailable"))
}

async fn serve(mut stream: TcpStream, turns: &'static [Turn], tool: &ToolFixture, log: &Log) {
    let read = read_request(&mut stream).await;
    let request = Request {
        turn: None,
        body_bytes: read.as_ref().map_or(0, |(_, body)| body.len()),
        received: read.as_ref().map_or_else(|_| Instant::now(), |(at, _)| *at),
        first_chunk: None,
        holds: Vec::new(),
        end: None,
    };
    let Ok(index) = locked(log).map(|mut log| {
        log.push(request);
        log.len() - 1
    }) else {
        return;
    };
    let end = match read.and_then(|(_, body)| Ok((matched(&body, turns)?, body))) {
        Ok((turn, body)) => {
            update(log, index, |request| request.turn = Some(turn));
            respond(&mut stream, turn, &body, tool, log, index)
                .await
                .unwrap_or_else(|error| End::Failed {
                    error: format!("{error:#}"),
                })
        }
        Err(error) => {
            let _ = stream
                .write_all(
                    b"HTTP/1.1 400 Bad Request\r\nconnection: close\r\ncontent-length: 0\r\n\r\n",
                )
                .await;
            End::Unexpected {
                reason: format!("{error:#}"),
            }
        }
    };
    update(log, index, |request| request.end = Some(end));
}

fn update(log: &Log, index: usize, change: impl FnOnce(&mut Request)) {
    if let Ok(mut log) = locked(log)
        && let Some(request) = log.get_mut(index)
    {
        change(request);
    }
}

async fn read_request(stream: &mut TcpStream) -> Result<(Instant, Vec<u8>)> {
    let mut buffer = Vec::new();
    let mut chunk = [0; 16 * 1024];
    loop {
        let length = stream.read(&mut chunk).await?;
        ensure!(length != 0, "The client closed before a complete request");
        buffer.extend_from_slice(&chunk[..length]);
        ensure!(
            buffer.len() <= MAX_REQUEST_BYTES,
            "The request is too large"
        );
        let mut headers = [httparse::EMPTY_HEADER; 64];
        let mut head = httparse::Request::new(&mut headers);
        let httparse::Status::Complete(offset) = head.parse(&buffer)? else {
            continue;
        };
        ensure!(
            head.method == Some("POST") && head.path == Some("/v1/responses"),
            "Unexpected {:?} {:?}",
            head.method,
            head.path
        );
        let length = head
            .headers
            .iter()
            .find(|header| header.name.eq_ignore_ascii_case("content-length"))
            .context("The request has no content-length")?;
        let length: usize = std::str::from_utf8(length.value)?.trim().parse()?;
        if buffer.len() >= offset + length {
            ensure!(
                buffer.len() == offset + length,
                "The request has trailing bytes"
            );
            return Ok((Instant::now(), buffer.split_off(offset)));
        }
    }
}

fn matched(body: &[u8], turns: &'static [Turn]) -> Result<&'static Turn> {
    let body: Value = serde_json::from_slice(body)?;
    let user = body["input"]
        .as_array()
        .context("The request has no input")?
        .iter()
        .rev()
        .find(|item| item["role"] == "user")
        .context("The request has no user input")?;
    let text = match &user["content"] {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| part["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    };
    turns
        .iter()
        .find(|turn| text.contains(turn.prompt))
        .with_context(|| format!("No scripted turn matches {text:?}"))
}

fn frame(event: &Value) -> String {
    format!(
        "event: {}\ndata: {event}\n\n",
        event["type"].as_str().unwrap_or_default()
    )
}

fn tokens(bytes: usize) -> u64 {
    u64::try_from(bytes.div_ceil(4)).unwrap_or(u64::MAX)
}

async fn respond(
    stream: &mut TcpStream,
    turn: &'static Turn,
    body: &[u8],
    tool: &ToolFixture,
    log: &Log,
    index: usize,
) -> Result<End> {
    let received = locked(log)?
        .get(index)
        .map(|request| request.received)
        .context("The provider lost its request")?;
    let response = json!({ "id": format!("resp_{index}"), "object": "response", "created_at": 1, "model": "gpt-6.1-sol" });
    stream
        .write_all(
            b"HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\nconnection: close\r\n\r\n",
        )
        .await?;
    stream
        .write_all(
            frame(&json!({ "type": "response.created", "response": with(&response, json!({ "status": "in_progress", "output": [] })) }))
                .as_bytes(),
        )
        .await?;
    let first_chunk = Duration::from_millis(turn.first_chunk_ms);
    let released = hold(stream, Some(received + first_chunk)).await;
    record_hold(
        log,
        index,
        HoldKind::FirstChunk,
        received,
        released,
        Some(turn.first_chunk_ms),
    );
    if let Released::Closed(at) = released {
        return Ok(End::ClosedByClient { at });
    }
    let reasoning_id = format!("rs_{index}");
    stream
        .write_all(
            (frame(&json!({ "type": "response.output_item.added", "output_index": 0, "item": { "id": reasoning_id, "type": "reasoning", "summary": [] } }))
                + &frame(&json!({ "type": "response.reasoning_summary_text.delta", "item_id": reasoning_id, "output_index": 0, "summary_index": 0, "delta": turn.reasoning })))
                .as_bytes(),
        )
        .await?;
    let tail_from = Instant::now();
    update(log, index, |request| request.first_chunk = Some(tail_from));
    let tail = match turn.ending {
        Ending::Answer { tail_ms, .. } | Ending::Exec { tail_ms } => Some(tail_ms),
        Ending::Hang => None,
    };
    let released = hold(
        stream,
        tail.map(|tail| tail_from + Duration::from_millis(tail)),
    )
    .await;
    record_hold(log, index, HoldKind::Tail, tail_from, released, tail);
    if let Released::Closed(at) = released {
        return Ok(End::ClosedByClient { at });
    }
    let reasoning = json!({ "id": reasoning_id, "type": "reasoning", "summary": [{ "type": "summary_text", "text": turn.reasoning }] });
    let (item, added, reply_bytes) = match turn.ending {
        Ending::Answer { text, .. } => {
            let item = json!({ "id": format!("msg_{index}"), "type": "message", "role": "assistant", "status": "completed", "phase": "final_answer",
                "content": [{ "type": "output_text", "text": text, "annotations": [] }] });
            let added = with(&item, json!({ "status": "in_progress", "content": [] }));
            (item, added, text.len())
        }
        Ending::Exec { .. } => {
            let arguments = tool.call().to_string();
            let item = json!({ "id": format!("fc_{index}"), "type": "function_call", "call_id": format!("call_{index}"), "name": "exec",
                "arguments": arguments, "status": "completed" });
            let added = with(&item, json!({ "status": "in_progress", "arguments": "" }));
            (item, added, arguments.len())
        }
        Ending::Hang => bail!("A hanging turn cannot complete"),
    };
    let reasoning_tokens = tokens(turn.reasoning.len());
    let input_tokens = tokens(body.len());
    let output_tokens = reasoning_tokens + tokens(reply_bytes);
    let total_tokens = input_tokens + output_tokens;
    let usage = json!({ "input_tokens": input_tokens, "output_tokens": output_tokens, "total_tokens": total_tokens,
        "input_tokens_details": { "cached_tokens": 0 }, "output_tokens_details": { "reasoning_tokens": reasoning_tokens } });
    let frames = [
        json!({ "type": "response.output_item.done", "output_index": 0, "item": reasoning }),
        json!({ "type": "response.output_item.added", "output_index": 1, "item": added }),
        json!({ "type": "response.output_item.done", "output_index": 1, "item": item }),
        json!({ "type": "response.completed", "response": with(&response, json!({ "status": "completed", "output": [reasoning, item], "usage": usage })) }),
    ];
    stream
        .write_all(frames.iter().map(frame).collect::<String>().as_bytes())
        .await?;
    stream.shutdown().await?;
    Ok(End::Completed {
        at: Instant::now(),
        total_tokens,
    })
}

const TOOL_SCRIPT: &str = "const [pidFile, owner] = process.argv.slice(1); const owned = () => process.ppid === Number(owner); if (!owned()) process.exit(1); require('node:fs').writeFileSync(pidFile, String(process.pid)); setInterval(() => { if (!owned()) process.exit(1); }, 200);";

fn with(base: &Value, extra: Value) -> Value {
    let mut merged = base.clone();
    if let (Some(merged), Value::Object(extra)) = (merged.as_object_mut(), extra) {
        merged.extend(extra);
    }
    merged
}

#[derive(Clone, Copy)]
enum Released {
    Timer(Instant),
    Closed(Instant),
}

async fn hold(stream: &mut TcpStream, until: Option<Instant>) -> Released {
    let mut buffer = [0; 1024];
    let deadline = async {
        match until {
            Some(until) => sleep_until(until.into()).await,
            None => std::future::pending().await,
        }
    };
    tokio::pin!(deadline);
    loop {
        tokio::select! {
            () = &mut deadline => return Released::Timer(Instant::now()),
            read = stream.read(&mut buffer) => match read {
                Ok(0) | Err(_) => return Released::Closed(Instant::now()),
                Ok(_) => {}
            },
        }
    }
}

fn record_hold(
    log: &Log,
    index: usize,
    kind: HoldKind,
    from: Instant,
    released: Released,
    scripted_ms: Option<u64>,
) {
    let (Released::Timer(to) | Released::Closed(to)) = released;
    update(log, index, |request| {
        request.holds.push((Hold { kind, from, to }, scripted_ms))
    });
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{BufRead, BufReader, Write},
        os::unix::process::CommandExt,
        process::{Child, Command, Stdio},
        sync::mpsc::{self, Receiver},
        thread,
    };

    use super::*;
    use crate::coordinator::installed;

    const EXIT_DEADLINE: Duration = Duration::from_secs(10);

    const OWNER_STARTS_TOOL_AFTER_RELEASE: &str = r#"while IFS= read -r argument; do set -- "$@" "$argument"; done
(until [ -e "$0" ]; do sleep 0.01; done; exec "$@") &
echo $!
exec sleep 60 >/dev/null"#;

    struct Tool {
        owner: Child,
        pid: u32,
        release: PathBuf,
        pid_file: PathBuf,
        output_closed: Receiver<()>,
        _directory: tempfile::TempDir,
    }

    impl Tool {
        fn start() -> Self {
            let directory = tempfile::tempdir().unwrap();
            let release = directory.path().join("release");
            let pid_file = directory.path().join("tool.pid");
            let mut owner = Command::new("sh")
                .arg("-c")
                .arg(OWNER_STARTS_TOOL_AFTER_RELEASE)
                .arg(&release)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .process_group(0)
                .spawn()
                .unwrap();
            let call = ToolFixture {
                node: installed("node").unwrap(),
                pid_file: pid_file.clone(),
                owner: owner.id(),
            }
            .call();
            let mut arguments = owner.stdin.take().unwrap();
            for argument in
                std::iter::once(&call["program"]).chain(call["args"].as_array().unwrap())
            {
                let argument = argument.as_str().unwrap();
                assert!(!argument.contains('\n'), "{argument}");
                writeln!(arguments, "{argument}").unwrap();
            }
            drop(arguments);
            let mut output = BufReader::new(owner.stdout.take().unwrap());
            let mut pid = String::new();
            output.read_line(&mut pid).unwrap();
            let (closed, output_closed) = mpsc::channel();
            thread::spawn(move || {
                let _ = std::io::copy(&mut output, &mut std::io::sink());
                let _ = closed.send(());
            });
            Self {
                owner,
                pid: pid.trim().parse().unwrap(),
                release,
                pid_file,
                output_closed,
                _directory: directory,
            }
        }

        fn release(&self) {
            fs::write(&self.release, "").unwrap();
        }

        fn kill_owner(&self) {
            let owner = i32::try_from(self.owner.id()).unwrap();
            assert_eq!(unsafe { libc::kill(owner, libc::SIGKILL) }, 0);
            // WNOWAIT leaves the owner unreaped, which keeps its process group
            // ID reserved for the cleanup in drop.
            let mut information: libc::siginfo_t = unsafe { std::mem::zeroed() };
            let waited = unsafe {
                libc::waitid(
                    libc::P_PID,
                    self.owner.id(),
                    &mut information,
                    libc::WEXITED | libc::WNOWAIT,
                )
            };
            assert_eq!(waited, 0);
        }

        fn exits_within(&self, duration: Duration) -> bool {
            self.output_closed.recv_timeout(duration).is_ok()
        }
    }

    impl Drop for Tool {
        fn drop(&mut self) {
            if let Ok(group) = i32::try_from(self.owner.id()) {
                unsafe { libc::killpg(group, libc::SIGKILL) };
            }
            let _ = self.owner.wait();
        }
    }

    #[test]
    fn the_exec_tool_runs_while_its_owner_lives_and_exits_after_it_dies() {
        let tool = Tool::start();
        tool.release();
        let started = Instant::now();
        while fs::read_to_string(&tool.pid_file).ok() != Some(tool.pid.to_string()) {
            assert!(started.elapsed() < EXIT_DEADLINE, "the tool never started");
            thread::sleep(Duration::from_millis(10));
        }
        assert!(
            !tool.exits_within(Duration::from_millis(600)),
            "the tool exited while its owner lived"
        );
        tool.kill_owner();
        assert!(
            tool.exits_within(EXIT_DEADLINE),
            "the tool outlived its owner"
        );
    }

    #[test]
    fn the_exec_tool_exits_when_its_owner_died_before_it_started() {
        let tool = Tool::start();
        tool.kill_owner();
        tool.release();
        assert!(
            tool.exits_within(EXIT_DEADLINE),
            "the tool outlived an owner that died before it started"
        );
    }
}
