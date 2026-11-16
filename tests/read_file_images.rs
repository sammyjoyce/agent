#[path = "fixtures/executable.rs"]
mod executable_fixture;
#[path = "fixtures/fake_rex.rs"]
mod fake_rex;

use std::{
    fs,
    hash::{BuildHasher, Hasher, RandomState},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::Duration,
};

use agent_cli::{
    background::{self, BackgroundSettings},
    broker::Broker,
    jobs::{JobSchedule, ScheduledJob},
    models::{ModelProvider, ModelSelection},
    protocol::{
        AgentNode, CoordinatorBootstrap, CoordinatorSettings, HostCommand, HostResult, ImageRead,
        InputMode, RuntimeCommand, RuntimeEventKind, TaskId, WorkerLaunch,
    },
    rex::RexClient,
    runtime::{FrameReader, OwnerClaim, Runtime, RuntimeCall},
};
use base64::Engine;
use serde_json::{Value, json};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{
        UnixListener,
        unix::{OwnedReadHalf, OwnedWriteHalf},
    },
    process::Command,
    time::{sleep, timeout},
};

const HOST_ID: &str = "11111111-1111-4111-8111-111111111111";
const OMITTED: &str = "(tool image omitted: model does not support images)";

fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xffff_ffff_u32;
    for byte in bytes {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 == 1 {
                (crc >> 1) ^ 0xedb8_8320
            } else {
                crc >> 1
            };
        }
    }
    !crc
}

fn stored_png(width: u32, height: u32, pixel: impl Fn(u32, u32) -> [u8; 3]) -> Vec<u8> {
    let mut raw = Vec::new();
    for y in 0..height {
        raw.push(0);
        for x in 0..width {
            raw.extend(pixel(x, y));
        }
    }
    let mut zlib = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65_535).collect();
    for (index, block) in blocks.iter().enumerate() {
        let length = u16::try_from(block.len()).unwrap();
        zlib.push(u8::from(index + 1 == blocks.len()));
        zlib.extend(length.to_le_bytes());
        zlib.extend((!length).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    let (mut a, mut b) = (1_u32, 0_u32);
    for byte in &raw {
        a = (a + u32::from(*byte)) % 65_521;
        b = (b + a) % 65_521;
    }
    zlib.extend(((b << 16) | a).to_be_bytes());
    let mut header = width.to_be_bytes().to_vec();
    header.extend(height.to_be_bytes());
    header.extend([8, 2, 0, 0, 0]);
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    for (kind, data) in [(&b"IHDR"[..], header), (b"IDAT", zlib), (b"IEND", vec![])] {
        let mut chunk = kind.to_vec();
        chunk.extend(&data);
        bytes.extend(u32::try_from(data.len()).unwrap().to_be_bytes());
        bytes.extend(&chunk);
        bytes.extend(crc32(&chunk).to_be_bytes());
    }
    bytes
}

fn digit(value: usize, background: [u8; 3]) -> Vec<u8> {
    const SEGMENTS: [&str; 10] = [
        "abcdef", "bc", "abdeg", "abcdg", "bcfg", "acdfg", "acdefg", "abc", "abcdefg", "abcdfg",
    ];
    let lit = SEGMENTS[value];
    stored_png(240, 240, |x, y| {
        let segment = |name: char, left: u32, top: u32, right: u32, bottom: u32| {
            lit.contains(name) && (left..right).contains(&x) && (top..bottom).contains(&y)
        };
        let on = segment('a', 70, 30, 170, 46)
            || segment('b', 154, 30, 170, 120)
            || segment('c', 154, 120, 170, 210)
            || segment('d', 70, 194, 170, 210)
            || segment('e', 70, 120, 86, 210)
            || segment('f', 70, 30, 86, 120)
            || segment('g', 70, 112, 170, 128);
        if on { [255, 255, 255] } else { background }
    })
}

fn job(id: &str, prompt: &str, directory: &Path, model: ModelSelection) -> ScheduledJob {
    ScheduledJob {
        id: id.to_owned().try_into().unwrap(),
        title: format!("Images {id}"),
        prompt: prompt.into(),
        model,
        timezone: "Etc/UTC".to_owned().try_into().unwrap(),
        cwd: directory.to_string_lossy().into_owned(),
        revision: "fixture".into(),
        schedules: vec![JobSchedule {
            id: "daily".to_owned().try_into().unwrap(),
            recurrence: "DTSTART:20990101T090000Z\nRRULE:FREQ=DAILY"
                .to_owned()
                .try_into()
                .unwrap(),
            focus: None,
            prompt: None,
        }],
    }
}

async fn collect(mut call: RuntimeCall) -> Vec<RuntimeEventKind> {
    let mut events = Vec::new();
    loop {
        let event = timeout(Duration::from_secs(8), call.events.recv())
            .await
            .expect("The runtime request did not finish")
            .expect("The runtime request closed without its terminal event");
        if let RuntimeEventKind::Failure { message, .. } = &event {
            panic!("Runtime request failed: {message}");
        }
        if matches!(event, RuntimeEventKind::Done) {
            return events;
        }
        events.push(event);
    }
}

struct Coordinator {
    runtime: Arc<Runtime>,
    background: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl Coordinator {
    #[allow(clippy::disallowed_methods)]
    async fn open(files: &Path, fixture: &str, environment: &str, jobs: &[ScheduledJob]) -> Self {
        let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("runtime/dist/test/fixtures")
            .join(fixture);
        assert!(fixture.is_file(), "Build the runtime before this test");
        let script = files.join("runtime.mjs");
        fs::write(
            &script,
            format!(
                "{environment}await import({});\n",
                serde_json::to_string(&fixture).unwrap()
            ),
        )
        .unwrap();
        let instructions = files.join("AGENTS.md");
        fs::write(&instructions, "Use only invented fixture data.\n").unwrap();
        let bootstrap = CoordinatorBootstrap {
            node: Some(AgentNode {
                host_id: HOST_ID.into(),
                name: "fixture".into(),
                home_directory: files.to_string_lossy().into_owned(),
                agent_program: "/fixture/agent".into(),
                rex_server: None,
                coordinator: None,
                capabilities: None,
                machine: None,
                launch: WorkerLaunch {
                    instructions: Some(instructions.to_string_lossy().into_owned()),
                    state_dir: None,
                    runtime: None,
                    config: None,
                    model: None,
                },
            }),
            settings: CoordinatorSettings {
                model: ModelSelection::default(),
                instructions: String::new(),
                context_repositories: vec![],
                sources: vec![],
            },
            background: None,
        };
        let runtime = Arc::new(
            Runtime::start(&script, OwnerClaim::acquire(files, &script, None).unwrap()).unwrap(),
        );
        for command in [
            RuntimeCommand::ConfigureCoordinator {
                bootstrap: bootstrap.clone(),
            },
            RuntimeCommand::SetConnectedNodes {
                host_ids: vec![HOST_ID.into()],
            },
        ] {
            collect(runtime.request(command).await.unwrap()).await;
        }
        let broker = Arc::new(
            Broker::new(
                Some(&bootstrap),
                files,
                RexClient::for_process(None).unwrap(),
            )
            .unwrap(),
        );
        let (running, jobs) = (runtime.clone(), jobs.to_vec());
        let count = jobs.len();
        let background = tokio::spawn(async move {
            background::run(
                running,
                broker,
                BackgroundSettings {
                    poll_interval_seconds: 60,
                    sources: false,
                    jobs: Some(jobs),
                },
            )
            .await
        });
        timeout(Duration::from_secs(8), async {
            loop {
                let events =
                    collect(runtime.request(RuntimeCommand::ListJobs).await.unwrap()).await;
                if events.iter().any(|event| {
                    matches!(event, RuntimeEventKind::ScheduledJobs { jobs } if jobs.len() == count)
                }) {
                    break;
                }
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        Self {
            runtime,
            background,
        }
    }

    async fn run(&self, name: &str) -> TaskId {
        collect(
            self.runtime
                .request(RuntimeCommand::RunJob {
                    job_id: name.to_owned().try_into().unwrap(),
                    schedule_id: None,
                    request_id: format!("manual-{name}"),
                })
                .await
                .unwrap(),
        )
        .await
        .into_iter()
        .find_map(|event| match event {
            RuntimeEventKind::JobRun { run } => Some(run.task_id),
            _ => None,
        })
        .unwrap()
    }

    async fn finished(
        &self,
        id: &TaskId,
        limit: Duration,
        done: impl Fn(&str) -> bool,
    ) -> (String, String) {
        timeout(limit, async {
            loop {
                let task = collect(
                    self.runtime
                        .request(RuntimeCommand::ReadTask {
                            task_id: id.clone(),
                        })
                        .await
                        .unwrap(),
                )
                .await
                .into_iter()
                .find_map(|event| match event {
                    RuntimeEventKind::Task { task, .. } => Some(*task),
                    _ => None,
                })
                .unwrap();
                if done(&task.summary) {
                    return (task.conversation_id, task.summary);
                }
                sleep(Duration::from_millis(20)).await;
            }
        })
        .await
        .expect("The task did not finish")
    }

    async fn close(self) {
        self.background.abort();
        let _ = self.background.await;
        timeout(Duration::from_secs(8), async {
            while Arc::strong_count(&self.runtime) > 1 {
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .expect("The stopped background owner must release its runtime");
        Arc::try_unwrap(self.runtime)
            .ok()
            .unwrap()
            .close()
            .await
            .unwrap();
    }
}

fn outputs(requests: &Path, key: &str) -> Vec<(String, Value)> {
    let requests = fs::read_to_string(requests).unwrap();
    let body = requests
        .lines()
        .rev()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .find(|request| request["key"] == key)
        .unwrap_or_else(|| panic!("No model request recorded for {key}"))["body"]
        .clone();
    let items = body["input"].as_array().unwrap();
    let name = |call_id: &Value| {
        let call = items
            .iter()
            .find(|item| item["type"] == "function_call" && item["call_id"] == *call_id)
            .unwrap();
        assert_eq!(call["name"], "read_file");
        let arguments: Value = serde_json::from_str(call["arguments"].as_str().unwrap()).unwrap();
        Path::new(arguments["path"].as_str().unwrap())
            .file_name()
            .unwrap()
            .to_string_lossy()
            .into_owned()
    };
    items
        .iter()
        .filter(|item| item["type"] == "function_call_output")
        .map(|item| (name(&item["call_id"]), item["output"].clone()))
        .collect()
}

fn output<'a>(outputs: &'a [(String, Value)], name: &str) -> &'a Value {
    &outputs
        .iter()
        .find(|(file, _)| file == name)
        .unwrap_or_else(|| panic!("No read_file output for {name}"))
        .1
}

fn text(output: &Value) -> String {
    match output {
        Value::String(text) => text.clone(),
        Value::Array(parts) => parts
            .iter()
            .filter_map(|part| part["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        other => panic!("Unexpected tool output {other}"),
    }
}

fn image(output: &Value) -> (u32, u32) {
    let images: Vec<&str> = output
        .as_array()
        .map(|parts| {
            parts
                .iter()
                .filter(|part| part["type"] == "input_image")
                .filter_map(|part| part["image_url"].as_str())
                .collect()
        })
        .unwrap_or_default();
    assert_eq!(images.len(), 1, "Expected one native image in {output}");
    let data = images[0]
        .strip_prefix("data:image/png;base64,")
        .expect("A solid PNG stays a PNG");
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data)
        .unwrap();
    assert!(bytes.starts_with(b"\x89PNG\r\n\x1a\n"));
    (
        u32::from_be_bytes(bytes[16..20].try_into().unwrap()),
        u32::from_be_bytes(bytes[20..24].try_into().unwrap()),
    )
}

fn refused_without_image(output: &Value) {
    let text = text(output);
    assert!(
        !output
            .as_array()
            .is_some_and(|parts| parts.iter().any(|part| part["type"] == "input_image")),
        "A refused image must not reach the model: {output}"
    );
    assert!(
        !text.contains('\u{fffd}'),
        "Image bytes must never reach the model as lossy text: {text}"
    );
    assert!(text.contains("image"), "The refusal must say why: {text}");
}

#[tokio::test]
async fn read_file_sends_host_images_natively_and_keeps_text_reads() {
    let directory = tempfile::tempdir().unwrap();
    let files = directory.path();
    fs::write(
        files.join("digit.txt"),
        stored_png(4, 4, |_, _| [200, 30, 30]),
    )
    .unwrap();
    fs::write(
        files.join("wide.png"),
        stored_png(2400, 8, |_, _| [20, 90, 200]),
    )
    .unwrap();
    let screenshot = stored_png(1700, 1700, |_, _| [240, 240, 236]);
    assert!(
        (8 * 1024 * 1024..12 * 1024 * 1024).contains(&screenshot.len()),
        "A screenshot-sized file spans several 1 MiB chunks"
    );
    fs::write(files.join("screenshot.png"), screenshot).unwrap();
    fs::write(files.join("notes.txt"), "alpha beta gamma\n").unwrap();
    let mut broken = b"\x89PNG\r\n\x1a\n".to_vec();
    broken.extend(b"\0\0\0\rIHDR not really an image");
    fs::write(files.join("broken.png"), broken).unwrap();
    fs::write(files.join("huge.png"), b"\x89PNG\r\n\x1a\n").unwrap();
    fs::OpenOptions::new()
        .write(true)
        .open(files.join("huge.png"))
        .unwrap()
        .set_len(16 * 1024 * 1024 + 1)
        .unwrap();
    let read = |name: &str| json!({ "tool": "read_file", "args": { "path": files.join(name) } });
    let queue = files.join("queue.json");
    fs::write(
        &queue,
        serde_json::to_vec(&json!({
            "JOB_VISION": [
                read("digit.txt"),
                { "tool": "read_file", "args": { "path": files.join("notes.txt"), "offset": 6, "limit": 5 } },
                read("wide.png"),
                read("broken.png"),
                read("huge.png"),
                read("screenshot.png"),
                { "text": "Vision job done." },
            ],
            "JOB_BLIND": [read("digit.txt"), { "text": "Blind job done." }],
            "VISION_AGAIN": [{ "text": "Vision continued after reopening." }],
        }))
        .unwrap(),
    )
    .unwrap();
    let requests = files.join("queue.json.requests");
    let environment = format!(
        "process.env.OPENAI_API_KEY='sk-synthetic-fixture';\nprocess.env.AGENT_TEST_MODEL_QUEUE={};\n",
        serde_json::to_string(&queue).unwrap()
    );
    let text_only = ModelSelection {
        provider: ModelProvider::OpenAi,
        model_id: "o3-mini".into(),
        reasoning: None,
        fast: false,
    };
    let jobs = [
        job("vision", "JOB_VISION", files, ModelSelection::default()),
        job("blind", "JOB_BLIND", files, text_only),
    ];
    let limit = Duration::from_secs(20);
    let coordinator = Coordinator::open(files, "coordinator-runtime.js", &environment, &jobs).await;
    let vision_task = coordinator.run("vision").await;
    let blind_task = coordinator.run("blind").await;
    let (vision, _) = coordinator
        .finished(&vision_task, limit, |summary| summary == "Vision job done.")
        .await;
    coordinator
        .finished(&blind_task, limit, |summary| summary == "Blind job done.")
        .await;

    let seen = outputs(&requests, "JOB_VISION");
    assert_eq!(
        image(output(&seen, "digit.txt")),
        (4, 4),
        "A PNG named .txt is detected by its header"
    );
    assert_eq!(
        output(&seen, "notes.txt"),
        &json!(r#"{"type":"file","content":"beta ","truncated":true}"#),
        "Text reads keep their byte offset, limit and result"
    );
    let (width, height) = image(output(&seen, "wide.png"));
    assert!(
        width <= 2000 && height <= 2000,
        "Images fit the model's limits"
    );
    assert!(
        text(output(&seen, "wide.png")).contains("2400x8"),
        "The model learns the original size to map coordinates"
    );
    assert_eq!(
        image(output(&seen, "screenshot.png")),
        (1700, 1700),
        "An image larger than one frame arrives whole"
    );
    refused_without_image(output(&seen, "broken.png"));
    refused_without_image(output(&seen, "huge.png"));

    let blind = text(output(&outputs(&requests, "JOB_BLIND"), "digit.txt"));
    assert!(
        blind.contains(OMITTED),
        "A text-only model gets Pi's placeholder: {blind}"
    );
    assert!(
        blind.contains("current model does not support images"),
        "A text-only model is told why it cannot see the image: {blind}"
    );
    coordinator.close().await;

    let coordinator = Coordinator::open(files, "coordinator-runtime.js", &environment, &jobs).await;
    collect(
        coordinator
            .runtime
            .request(RuntimeCommand::ConversationInput {
                origin: None,
                conversation_id: vision,
                input_id: "vision-again".into(),
                input: "VISION_AGAIN".into(),
                mode: InputMode::FollowUp,
                context: None,
                attachments: None,
            })
            .await
            .unwrap(),
    )
    .await;
    coordinator
        .finished(&vision_task, limit, |summary| {
            summary == "Vision continued after reopening."
        })
        .await;
    assert_eq!(
        image(output(&outputs(&requests, "VISION_AGAIN"), "digit.txt")),
        (4, 4),
        "The saved tool image survives reopening the conversation store"
    );
    coordinator.close().await;
}

struct Attached {
    frames: FrameReader<BufReader<OwnedReadHalf>>,
    writer: OwnedWriteHalf,
    calls: usize,
}

impl Attached {
    async fn send(&mut self, events: impl IntoIterator<Item = RuntimeEventKind>) {
        let mut bytes = Vec::new();
        for event in events {
            serde_json::to_writer(&mut bytes, &event).unwrap();
            bytes.push(b'\n');
        }
        self.writer.write_all(&bytes).await.unwrap();
    }

    async fn next(&mut self) -> RuntimeCommand {
        let frame = timeout(Duration::from_secs(10), self.frames.next_frame())
            .await
            .expect("The registered worker went quiet")
            .unwrap()
            .expect("The registered worker closed its connection");
        serde_json::from_slice(&frame).unwrap()
    }

    async fn call(&mut self, command: HostCommand) -> HostResult {
        self.calls += 1;
        let call_id = format!("fixture-call-{}", self.calls);
        self.send([RuntimeEventKind::HostCall {
            call_id: call_id.clone(),
            command: Box::new(command),
        }])
        .await;
        loop {
            if let RuntimeCommand::HostReply {
                call_id: replied,
                result,
            } = self.next().await
                && replied == call_id
            {
                return result;
            }
        }
    }
}

#[tokio::test]
async fn a_registered_worker_serves_image_reads_from_its_own_host() {
    const SERVER: &str = "unix:///run/user/1000/rex-agent/server.sock";
    let directory = tempfile::tempdir().unwrap();
    let files = directory.path().to_owned();
    fs::set_permissions(&files, fs::Permissions::from_mode(0o700)).unwrap();
    let image = stored_png(1200, 1200, |x, y| {
        [
            u8::try_from(x % 256).unwrap(),
            u8::try_from(y % 256).unwrap(),
            90,
        ]
    });
    fs::write(files.join("shot.dat"), &image).unwrap();
    fs::write(files.join("notes.txt"), "alpha beta gamma\n").unwrap();
    let listener = UnixListener::bind(files.join("agent.sock")).unwrap();
    let (reads, served_reads) = tokio::sync::oneshot::channel();
    let served = files.clone();
    let read = move |name: &str, offset, limit, image| HostCommand::ReadFile {
        path: served.join(name).to_string_lossy().into_owned(),
        offset,
        limit,
        image: Some(image),
    };
    let coordinator = tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let (reader, writer) = stream.into_split();
            let mut attached = Attached {
                frames: FrameReader::new(BufReader::new(reader)),
                writer,
                calls: 0,
            };
            match attached.next().await {
                RuntimeCommand::Environment { .. } => {
                    let environment = RuntimeEventKind::Environment {
                        settings: CoordinatorSettings {
                            model: ModelSelection::default(),
                            instructions: String::new(),
                            context_repositories: Vec::new(),
                            sources: Vec::new(),
                        },
                        nodes: Vec::new(),
                        online_host_ids: Vec::new(),
                        unavailable_host_ids: None,
                    };
                    attached.send([environment, RuntimeEventKind::Done]).await;
                }
                RuntimeCommand::ConnectWorker { .. } => {
                    attached
                        .send([RuntimeEventKind::WorkerReady {
                            connection_id: "invented-connection".into(),
                        }])
                        .await;
                    let mut received = Vec::new();
                    let mut next = ImageRead::Start;
                    loop {
                        let result = attached.call(read("shot.dat", 0, 64_000, next)).await;
                        let HostResult::ImageChunk {
                            size_bytes,
                            stamp,
                            at,
                            data_base64,
                            ..
                        } = result
                        else {
                            panic!("Expected an image chunk, got {result:?}");
                        };
                        assert_eq!(usize::try_from(at).unwrap(), received.len());
                        received.extend(
                            base64::engine::general_purpose::STANDARD
                                .decode(data_base64)
                                .unwrap(),
                        );
                        if received.len() == usize::try_from(size_bytes).unwrap() {
                            break;
                        }
                        next = ImageRead::Next {
                            at: u32::try_from(received.len()).unwrap(),
                            stamp,
                        };
                    }
                    let chunks = attached.calls;
                    let text = attached
                        .call(read("notes.txt", 6, 5, ImageRead::Start))
                        .await;
                    reads.send((received, chunks, text)).unwrap();
                    return;
                }
                command => panic!("Unexpected worker command {command:?}"),
            }
        }
    });
    let bin = files.join("bin");
    fs::create_dir(&bin).unwrap();
    std::os::unix::fs::symlink(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rex.sh"),
        bin.join("rex"),
    )
    .unwrap();
    let relay = bin.join("relay.cjs");
    fs::write(
        &relay,
        "const socket=require('node:net').connect(process.env.AGENT_TEST_COORDINATOR_SOCKET);\n\
         process.stdin.pipe(socket);socket.pipe(process.stdout);socket.on('close',()=>process.exit(0));\n",
    )
    .unwrap();
    executable_fixture::write_executable(
        &bin.join("ssh"),
        "#!/bin/sh\nexec node \"$AGENT_TEST_SSH_RELAY\"\n",
    );
    fs::write(
        files.join("config.toml"),
        "coordinator = \"synthetic-coordinator\"\n",
    )
    .unwrap();
    fs::write(files.join("AGENTS.md"), "").unwrap();
    let path = std::env::join_paths(std::iter::once(bin.clone()).chain(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    )))
    .unwrap();
    let mut worker = Command::new(env!("CARGO_BIN_EXE_beep-boop"))
        .args(["--rex-server", SERVER, "--json", "--no-tui", "--state-dir"])
        .arg(&files)
        .arg("--config")
        .arg(files.join("config.toml"))
        .arg("--instructions")
        .arg(files.join("AGENTS.md"))
        .arg("maintain")
        .env("PATH", path)
        .env("AGENT_TEST_FAKE_REX", &bin)
        .env("AGENT_TEST_FAKE_REX_ORIGIN_SERVER", SERVER)
        .env("AGENT_TEST_COORDINATOR_SOCKET", files.join("agent.sock"))
        .env("AGENT_TEST_SSH_RELAY", &relay)
        .env("REX_SERVER", SERVER)
        .env_remove("REX_CLIENT")
        .current_dir(&files)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let served = timeout(Duration::from_secs(30), served_reads).await;
    worker.start_kill().unwrap();
    let output = worker.wait_with_output().await.unwrap();
    let Ok(Ok((received, chunks, text))) = served else {
        panic!(
            "The registered worker never served the reads: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    coordinator.await.unwrap();
    assert!(received == image, "The image arrives byte for byte");
    assert_eq!(chunks, image.len().div_ceil(1024 * 1024));
    assert_eq!(
        serde_json::to_value(text).unwrap(),
        json!({"type": "file", "content": "beta ", "truncated": true}),
        "A text read on the same worker keeps its byte window"
    );
}

#[tokio::test]
#[ignore = "live model through OPENAI_BASE_URL; AGENT_IMAGE_READ_PROOF names a directory that keeps the evidence"]
async fn live_model_reads_a_host_image_through_read_file() {
    assert!(
        std::env::var_os("OPENAI_API_KEY").is_some()
            && std::env::var_os("OPENAI_BASE_URL").is_some(),
        "Set OPENAI_API_KEY and OPENAI_BASE_URL"
    );
    let directory = tempfile::tempdir().unwrap();
    let files = directory.path();
    let seed = usize::try_from(RandomState::new().build_hasher().finish() % 30).unwrap();
    let colors = [
        ("red", [210, 40, 40]),
        ("green", [30, 150, 60]),
        ("blue", [40, 80, 220]),
    ];
    let (value, (color, rgb)) = (seed % 10, colors[seed / 10 % colors.len()]);
    let sample = files.join("sample.dat");
    fs::write(&sample, digit(value, rgb)).unwrap();
    let proof = std::env::var_os("AGENT_IMAGE_READ_PROOF").map(PathBuf::from);
    let requests = proof.as_ref().map_or_else(
        || files.join("requests.jsonl"),
        |proof| proof.join("requests.jsonl"),
    );
    let environment = format!(
        "process.env.AGENT_TEST_REQUESTS={};\n",
        serde_json::to_string(&requests).unwrap()
    );
    let prompt = format!(
        "Call read_file on {} exactly once and use no other tool to inspect it. Then reply with one line naming the digit shown and the background color.",
        sample.display()
    );
    let jobs = [job("live", &prompt, files, ModelSelection::default())];
    let coordinator =
        Coordinator::open(files, "live-gateway-runtime.js", &environment, &jobs).await;
    let task = coordinator.run("live").await;
    let (_, answer) = coordinator
        .finished(&task, Duration::from_secs(300), |summary| {
            !summary.is_empty() && !summary.starts_with("Call read_file")
        })
        .await;
    coordinator.close().await;
    if let Some(proof) = &proof {
        fs::write(
            proof.join("answer.txt"),
            format!("expected digit {value} on {color}\nanswer: {answer}\n"),
        )
        .unwrap();
    }
    let last = fs::read_to_string(&requests)
        .unwrap()
        .lines()
        .last()
        .map(|line| serde_json::from_str::<Value>(line).unwrap())
        .unwrap();
    let items = last["input"].as_array().unwrap();
    let calls: Vec<&Value> = items
        .iter()
        .filter(|item| item["type"] == "function_call")
        .collect();
    assert!(
        calls.iter().all(|call| call["name"] != "exec"),
        "The model must see the image, not decode the file with a program"
    );
    let read = calls
        .iter()
        .find(|call| call["name"] == "read_file")
        .expect("The model must call read_file");
    let seen = items
        .iter()
        .find(|item| item["type"] == "function_call_output" && item["call_id"] == read["call_id"])
        .unwrap();
    assert!(
        seen["output"]
            .as_array()
            .is_some_and(|parts| parts.iter().any(|part| part["type"] == "input_image")),
        "read_file must reach the live model as a native image: {}",
        seen["output"]
    );
    let answer = answer.to_lowercase();
    assert!(
        answer.contains(&value.to_string()) && answer.contains(color),
        "Expected digit {value} on {color}, the model answered {answer:?}"
    );
}
