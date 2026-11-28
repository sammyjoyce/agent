use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use agent_cli::{
    models::ModelSelection,
    protocol::{
        ConversationSettings, CoordinatorSettings, ErrorCode, HistoryMessage, HistoryRole,
        RuntimeCommand, RuntimeEventKind, SavedConversation,
    },
    runtime::FrameReader,
    serialized_spawn::SerializedTokioSpawn,
    tui::PROGRAM_RESUME_TOKEN_ENV,
};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use sha2::{Digest, Sha256};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt, BufReader},
    net::UnixListener,
    process::Command,
    time::timeout,
};

const TEST_TOKEN: &str = "test-osc7577-token-0123456789abcdef";

#[derive(Debug, PartialEq, Eq)]
enum DecodedOsc7577 {
    Resume {
        pid: u32,
        time: u64,
        argv: Vec<String>,
        cwd: Option<String>,
    },
    Clear {
        pid: u32,
        time: u64,
    },
}

fn decode_osc7577_reports(raw: &[u8], token: &str) -> Vec<DecodedOsc7577> {
    let text = String::from_utf8_lossy(raw);
    let mut reports = Vec::new();
    let mut rest = text.as_ref();
    while let Some(start) = rest.find("\x1b]7577;") {
        let after_prefix = &rest[start + "\x1b]7577;".len()..];
        let Some(end) = after_prefix.find("\x1b\\") else {
            break;
        };
        let payload = &after_prefix[..end];
        rest = &after_prefix[end + "\x1b\\".len()..];

        let (body, mac) = payload
            .rsplit_once(":mac=")
            .expect("OSC 7577 report must end with :mac=");
        assert_eq!(mac.len(), 64, "MAC must be 64 lowercase hex characters");
        let mut hasher = Sha256::new();
        hasher.update(format!("{body}:{token}").as_bytes());
        assert_eq!(
            hex::encode(hasher.finalize()),
            mac,
            "OSC 7577 SHA-256 MAC mismatch for body {body:?}"
        );

        let mut pid = None;
        let mut time = None;
        let mut argv = None;
        let mut cwd = None;
        let mut clear = false;
        for pair in body.split(':') {
            let (key, value) = pair.split_once('=').expect("key=value field");
            match key {
                "pid" => pid = Some(value.parse::<u32>().unwrap()),
                "time" => time = Some(value.parse::<u64>().unwrap()),
                "clear" => {
                    assert_eq!(value, "1");
                    clear = true;
                }
                "argv" => {
                    argv = Some(
                        value
                            .split(',')
                            .map(|item| String::from_utf8(STANDARD.decode(item).unwrap()).unwrap())
                            .collect::<Vec<_>>(),
                    );
                }
                "cwd" => {
                    cwd = Some(String::from_utf8(STANDARD.decode(value).unwrap()).unwrap());
                }
                other => panic!("Unexpected OSC 7577 field: {other}"),
            }
        }
        let pid = pid.expect("pid field");
        let time = time.expect("time field");
        if clear {
            reports.push(DecodedOsc7577::Clear { pid, time });
        } else {
            reports.push(DecodedOsc7577::Resume {
                pid,
                time,
                argv: argv.expect("argv field"),
                cwd,
            });
        }
    }
    reports
}

async fn write_events(
    writer: &mut tokio::net::unix::OwnedWriteHalf,
    events: impl IntoIterator<Item = RuntimeEventKind>,
) -> anyhow::Result<()> {
    for event in events {
        let mut frame = serde_json::to_vec(&event)?;
        frame.push(b'\n');
        writer.write_all(&frame).await?;
    }
    Ok(())
}

async fn read_until(
    output: &mut tokio::process::ChildStdout,
    bytes: &mut Vec<u8>,
    predicate: impl Fn(&[u8]) -> bool,
    description: &str,
) {
    let result = timeout(Duration::from_secs(10), async {
        let mut chunk = [0u8; 4096];
        while !predicate(bytes) {
            let count = output.read(&mut chunk).await.unwrap();
            assert!(
                count > 0,
                "Terminal output ended before {description}: {:?}",
                String::from_utf8_lossy(bytes)
            );
            bytes.extend_from_slice(&chunk[..count]);
        }
    })
    .await;
    assert!(
        result.is_ok(),
        "Timed out waiting for {description}; saw {:?}",
        String::from_utf8_lossy(bytes)
    );
}

fn binaries() -> (PathBuf, PathBuf) {
    let binary = std::env::var_os("AGENT_TEST_BINARY")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_BIN_EXE_beep-boop")));
    let fixture = Path::new(env!("CARGO_BIN_EXE_beep-boop"))
        .parent()
        .unwrap()
        .join("examples/terminal-fixture");
    (binary, fixture)
}

fn spawn_mock_coordinator(directory: &Path) -> tokio::task::JoinHandle<()> {
    let listener = UnixListener::bind(directory.join("agent.sock")).unwrap();
    tokio::spawn(async move {
        let mut connections = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                socket = listener.accept() => {
                    let (socket, _) = socket.unwrap();
                    connections.spawn(async move {
                        let (reader, mut writer) = socket.into_split();
                        let mut reader = FrameReader::new(BufReader::new(reader));
                        let Some(bytes) = reader.next_frame().await.unwrap() else { return; };
                        let command: RuntimeCommand = serde_json::from_slice(&bytes).unwrap();
                        let main_summary = SavedConversation {
                            conversation_id: "1".into(),
                            title: "Main agent".into(),
                            updated_at: None,
                            task_id: None,
                            agent_id: None,
                            host: None,
                            source_thread_id: None,
                        };
                        let conv42 = SavedConversation {
                            conversation_id: "42".into(),
                            title: "Remote Task 42".into(),
                            updated_at: None,
                            task_id: None,
                            agent_id: None,
                            host: Some("remote-mac".into()),
                            source_thread_id: None,
                        };
                        match command {
                            RuntimeCommand::ConversationSettings { conversation_id, .. } => {
                                let id = conversation_id.unwrap_or_else(|| "1".into());
                                if id != "1" && id != "42" {
                                    write_events(
                                        &mut writer,
                                        [RuntimeEventKind::Failure {
                                            code: ErrorCode::InvalidRequest,
                                            message: "Choose an existing saved conversation."
                                                .into(),
                                        }],
                                    )
                                    .await
                                    .unwrap();
                                } else {
                                    write_events(
                                        &mut writer,
                                        [
                                            RuntimeEventKind::ConversationSettings {
                                                settings: ConversationSettings {
                                                    conversation_id: id,
                                                    task_id: None,
                                                    agent_id: None,
                                                    model: ModelSelection::default(),
                                                    catalog: vec![],
                                                },
                                            },
                                            RuntimeEventKind::Done,
                                        ],
                                    )
                                    .await
                                    .unwrap();
                                }
                            }
                            RuntimeCommand::ListConversations { .. } => {
                                write_events(
                                    &mut writer,
                                    [
                                        RuntimeEventKind::Conversations {
                                            items: vec![main_summary, conv42],
                                            next_cursor: None,
                                        },
                                        RuntimeEventKind::Done,
                                    ],
                                )
                                .await
                                .unwrap();
                            }
                            RuntimeCommand::AttachConversation { conversation_id, .. } => {
                                let (conversation, remote_cwd) = if conversation_id == "42" {
                                    (conv42, "/remote/mac/does-not-exist".to_owned())
                                } else {
                                    (main_summary, "/coordinator/main".to_owned())
                                };
                                write_events(
                                    &mut writer,
                                    [RuntimeEventKind::ConversationReady {
                                        conversation,
                                        model: ModelSelection::default(),
                                        cwd: remote_cwd,
                                        working: false,
                                    }],
                                )
                                .await
                                .unwrap();
                                // Keep observation stream open until the client detaches.
                                let _ = reader.next_frame().await;
                            }
                            RuntimeCommand::ReadConversation { conversation_id, .. } => {
                                let marker = if conversation_id == "42" {
                                    "Conversation 42 transcript ready."
                                } else {
                                    "Main transcript ready."
                                };
                                write_events(
                                    &mut writer,
                                    [
                                        RuntimeEventKind::History {
                                            conversation_id,
                                            messages: vec![HistoryMessage {
                                                entry_id: "entry-1".into(),
                                                role: HistoryRole::Final,
                                                text: marker.into(),
                                                continuation: false,
                                                final_chunk: true,
                                                tool: None,
                                                presentation: None,
                                                notice_origin: None,
                                                notice_details: None,
                                                attachments: None,
                                                reply_to: None,
                                            }],
                                            next_cursor: None,
                                            page_complete: true,
                                        },
                                        RuntimeEventKind::Done,
                                    ],
                                )
                                .await
                                .unwrap();
                            }
                            RuntimeCommand::ConversationInput {
                                conversation_id,
                                input_id,
                                input,
                                ..
                            } => {
                                write_events(
                                    &mut writer,
                                    [
                                        RuntimeEventKind::InputAccepted {
                                            input_id: input_id.clone(),
                                            work: None,
                                        },
                                        RuntimeEventKind::InputPlaced {
                                            input_id,
                                            entry_id: "entry-2".into(),
                                        },
                                        RuntimeEventKind::Answer {
                                            conversation_id: conversation_id.clone(),
                                            text: format!("Reply[{conversation_id}]: {input}"),
                                            entry_id: Some("entry-3".into()),
                                        },
                                        RuntimeEventKind::Done,
                                    ],
                                )
                                .await
                                .unwrap();
                            }
                            RuntimeCommand::RunTask { .. } => {
                                write_events(
                                    &mut writer,
                                    [
                                        RuntimeEventKind::TaskReady {
                                            conversation_id: "99".into(),
                                            title: "Worker Task".into(),
                                        },
                                        RuntimeEventKind::History {
                                            conversation_id: "99".into(),
                                            messages: vec![HistoryMessage {
                                                entry_id: "worker-1".into(),
                                                role: HistoryRole::Final,
                                                text: "Worker pane ready.".into(),
                                                continuation: false,
                                                final_chunk: true,
                                                tool: None,
                                                presentation: None,
                                                notice_origin: None,
                                                notice_details: None,
                                                attachments: None,
                                                reply_to: None,
                                            }],
                                            next_cursor: None,
                                            page_complete: true,
                                        },
                                    ],
                                )
                                .await
                                .unwrap();
                                let _ = reader.next_frame().await;
                            }
                            RuntimeCommand::WatchTaskGraph => {
                                let _ = reader.next_frame().await;
                            }
                            RuntimeCommand::Environment { .. } => {
                                write_events(
                                    &mut writer,
                                    [
                                        RuntimeEventKind::Environment {
                                            settings: CoordinatorSettings {
                                                model: ModelSelection::default(),
                                                instructions: String::new(),
                                                context_repositories: vec![],
                                                sources: vec![],
                                            },
                                            nodes: vec![],
                                            online_host_ids: vec![],
                                            unavailable_host_ids: None,
                                        },
                                        RuntimeEventKind::Done,
                                    ],
                                )
                                .await
                                .unwrap();
                            }
                            _ => {
                                write_events(&mut writer, [RuntimeEventKind::Done]).await.unwrap();
                            }
                        }
                    });
                }
                done = connections.join_next(), if !connections.is_empty() => {
                    let _ = done;
                }
            }
        }
    })
}

#[tokio::test]
async fn chat_tui_reports_osc7577_updates_on_switch_keeps_local_cwd_and_clears_on_user_quit() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = directory.path().join("agent.toml");
    fs::write(&config, "").unwrap();
    let launch_dir = directory.path().join("launch-cwd");
    fs::create_dir(&launch_dir).unwrap();
    let pid_file = directory.path().join("child.pid");
    let server = spawn_mock_coordinator(directory.path());

    let (binary, fixture) = binaries();
    let state_arg = directory.path().to_str().unwrap().to_owned();
    let mut child = Command::new(fixture)
        .arg(binary)
        .arg("--state-dir")
        .arg(&state_arg)
        .arg("--config=../agent.toml")
        .arg("chat")
        .current_dir(&launch_dir)
        .env("TERM", "xterm-256color")
        .env("AGENT_TEST_TERMINAL_REPLY", "1")
        .env("AGENT_TEST_TERMINAL_PID", &pid_file)
        .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn_serialized()
        .unwrap();

    let mut input = child.stdin.take().unwrap();
    let mut output = child.stdout.take().unwrap();
    let mut bytes = Vec::new();

    read_until(
        &mut output,
        &mut bytes,
        |buf| !decode_osc7577_reports(buf, TEST_TOKEN).is_empty(),
        "initial Main OSC 7577 report",
    )
    .await;

    let child_pid: u32 = fs::read_to_string(&pid_file)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    let expected_cwd = std::path::absolute(&launch_dir)
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();

    // Switch to conversation 42 (whose coordinator cwd is a remote path).
    input.write_all(b"/resume 42\r").await.unwrap();
    read_until(
        &mut output,
        &mut bytes,
        |buf| decode_osc7577_reports(buf, TEST_TOKEN).len() >= 2,
        "conversation 42 OSC 7577 report",
    )
    .await;

    // Switch back to Main.
    input.write_all(b"/main\r").await.unwrap();
    read_until(
        &mut output,
        &mut bytes,
        |buf| decode_osc7577_reports(buf, TEST_TOKEN).len() >= 3,
        "returned Main OSC 7577 report",
    )
    .await;

    // Explicit user quit via Ctrl+C must clear OSC 7577.
    input.write_all(b"\x03").await.unwrap();
    let exited = timeout(Duration::from_secs(5), async {
        let (exited, drained) =
            tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes));
        drained.unwrap();
        exited.unwrap()
    })
    .await
    .unwrap();
    assert!(
        exited.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&exited.stderr)
    );

    let reports = decode_osc7577_reports(&bytes, TEST_TOKEN);
    assert_eq!(reports.len(), 4, "reports: {reports:?}");
    // Scope flags preserve exact launch order, `--flag=value` spelling, and raw relative paths.
    let main_argv = vec![
        "beep-boop".into(),
        "chat".into(),
        "--state-dir".into(),
        state_arg.clone(),
        "--config=../agent.toml".into(),
    ];
    let conv42_argv = vec![
        "beep-boop".into(),
        "chat".into(),
        "--conversation".into(),
        "42".into(),
        "--state-dir".into(),
        state_arg,
        "--config=../agent.toml".into(),
    ];
    assert!(matches!(
        &reports[0],
        DecodedOsc7577::Resume { pid, argv, cwd, .. }
            if *pid == child_pid && argv == &main_argv && cwd.as_deref() == Some(expected_cwd.as_str())
    ));
    assert!(
        matches!(
            &reports[1],
            DecodedOsc7577::Resume { pid, argv, cwd, .. }
                if *pid == child_pid && argv == &conv42_argv && cwd.as_deref() == Some(expected_cwd.as_str())
        ),
        "conversation 42 must preserve local launch cwd rather than remote cwd: {:?}",
        reports[1]
    );
    assert!(matches!(
        &reports[2],
        DecodedOsc7577::Resume { pid, argv, cwd, .. }
            if *pid == child_pid && argv == &main_argv && cwd.as_deref() == Some(expected_cwd.as_str())
    ));
    assert!(matches!(
        &reports[3],
        DecodedOsc7577::Clear { pid, .. } if *pid == child_pid
    ));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn chat_tui_direct_conversation_refreshes_on_sigcont_and_preserves_resume_on_signals() {
    for sig in [libc::SIGTERM, libc::SIGHUP] {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let config = directory.path().join("agent.toml");
        fs::write(&config, "").unwrap();
        let pid_file = directory.path().join("child.pid");
        let server = spawn_mock_coordinator(directory.path());

        let (binary, fixture) = binaries();
        let mut child = Command::new(fixture)
            .arg(binary)
            .arg("--state-dir")
            .arg(directory.path())
            .arg("--config")
            .arg(&config)
            .arg("chat")
            .arg("--conversation")
            .arg("42")
            .current_dir(directory.path())
            .env("TERM", "xterm-256color")
            .env("AGENT_TEST_TERMINAL_REPLY", "1")
            .env("AGENT_TEST_TERMINAL_PID", &pid_file)
            .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn_serialized()
            .unwrap();

        let _input = child.stdin.take().unwrap();
        let mut output = child.stdout.take().unwrap();
        let mut bytes = Vec::new();

        read_until(
            &mut output,
            &mut bytes,
            |buf| !decode_osc7577_reports(buf, TEST_TOKEN).is_empty(),
            "initial --conversation 42 OSC 7577 report",
        )
        .await;

        let child_pid: i32 = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        // SIGCONT refreshes the resume report with a fresh timestamp and MAC.
        assert_eq!(unsafe { libc::kill(child_pid, libc::SIGCONT) }, 0);
        read_until(
            &mut output,
            &mut bytes,
            |buf| decode_osc7577_reports(buf, TEST_TOKEN).len() >= 2,
            "refreshed OSC 7577 report after SIGCONT",
        )
        .await;

        // SIGTERM / SIGHUP must end cleanly WITHOUT sending clear=1.
        assert_eq!(unsafe { libc::kill(child_pid, sig) }, 0);
        let exited = timeout(Duration::from_secs(5), async {
            let (exited, drained) =
                tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes));
            drained.unwrap();
            exited.unwrap()
        })
        .await
        .expect("chat_tui must exit promptly on SIGTERM/SIGHUP");
        assert!(
            !exited.status.success(),
            "signal termination should not report clean user exit"
        );

        let reports = decode_osc7577_reports(&bytes, TEST_TOKEN);
        assert_eq!(
            reports.len(),
            2,
            "signal {sig} must preserve resume record without sending clear=1: {reports:?}"
        );
        assert!(
            !reports
                .iter()
                .any(|report| matches!(report, DecodedOsc7577::Clear { .. })),
            "signal {sig} emitted forbidden clear=1: {reports:?}"
        );
        match (&reports[0], &reports[1]) {
            (
                DecodedOsc7577::Resume {
                    pid: p1,
                    time: t1,
                    argv: a1,
                    ..
                },
                DecodedOsc7577::Resume {
                    pid: p2,
                    time: t2,
                    argv: a2,
                    ..
                },
            ) => {
                assert_eq!(*p1, child_pid as u32);
                assert_eq!(*p2, child_pid as u32);
                assert!(t2 >= t1);
                assert_eq!(a1, a2);
                assert!(a1.windows(2).any(|w| w == ["--conversation", "42"]));
            }
            other => panic!("Expected two Resume reports, got {other:?}"),
        }

        server.abort();
        let _ = server.await;
    }
}

#[tokio::test]
async fn chat_tui_omits_osc7577_without_token_and_never_repeats_transient_prompt_or_model() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = directory.path().join("agent.toml");
    fs::write(&config, "").unwrap();
    let server = spawn_mock_coordinator(directory.path());
    let (binary, fixture) = binaries();

    // 1. Without OSC7577_TOKEN or with empty OSC7577_TOKEN: zero OSC 7577 bytes emitted.
    for token in [None, Some("")] {
        let mut command = Command::new(&fixture);
        command
            .arg(&binary)
            .arg("--state-dir")
            .arg(directory.path())
            .arg("--config")
            .arg(&config)
            .arg("chat")
            .current_dir(directory.path())
            .env("TERM", "xterm-256color")
            .env("AGENT_TEST_TERMINAL_REPLY", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        match token {
            Some(value) => {
                command.env(PROGRAM_RESUME_TOKEN_ENV, value);
            }
            None => {
                command.env_remove(PROGRAM_RESUME_TOKEN_ENV);
            }
        }
        let mut child = command.spawn_serialized().unwrap();
        let mut input = child.stdin.take().unwrap();
        let mut output = child.stdout.take().unwrap();
        let mut bytes = Vec::new();
        read_until(
            &mut output,
            &mut bytes,
            |buf| String::from_utf8_lossy(buf).contains("Main transcript ready."),
            "main transcript without token",
        )
        .await;
        input.write_all(b"\x03").await.unwrap();
        let (exited, drained) =
            tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes));
        drained.unwrap();
        assert!(exited.unwrap().status.success());
        assert!(
            !String::from_utf8_lossy(&bytes).contains("\x1b]7577;"),
            "must never emit OSC 7577 when OSC7577_TOKEN is {token:?}"
        );
    }

    // 2. With OSC7577_TOKEN + initial prompt + --model: prompt and --model are NOT repeated,
    //    and explicit `/exit` clears OSC 7577.
    {
        let mut child = Command::new(&fixture)
            .arg(&binary)
            .arg("--state-dir")
            .arg(directory.path())
            .arg("--config")
            .arg(&config)
            .arg("chat")
            .arg("--provider")
            .arg("openai")
            .arg("--model")
            .arg("gpt-5.4")
            .arg("Do not repeat this prompt on restart")
            .current_dir(directory.path())
            .env("TERM", "xterm-256color")
            .env("AGENT_TEST_TERMINAL_REPLY", "1")
            .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn_serialized()
            .unwrap();
        let mut input = child.stdin.take().unwrap();
        let mut output = child.stdout.take().unwrap();
        let mut bytes = Vec::new();
        read_until(
            &mut output,
            &mut bytes,
            |buf| !decode_osc7577_reports(buf, TEST_TOKEN).is_empty(),
            "OSC 7577 report with initial prompt",
        )
        .await;
        input.write_all(b"/exit\r").await.unwrap();
        let (exited, drained) =
            tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes));
        drained.unwrap();
        assert!(exited.unwrap().status.success());
        let reports = decode_osc7577_reports(&bytes, TEST_TOKEN);
        assert_eq!(reports.len(), 2, "expected Resume then Clear: {reports:?}");
        let DecodedOsc7577::Resume { argv, .. } = &reports[0] else {
            panic!("expected Resume report first");
        };
        assert!(matches!(reports[1], DecodedOsc7577::Clear { .. }));
        assert!(!argv.iter().any(|arg| arg.contains("Do not repeat")));
        assert!(
            !argv
                .iter()
                .any(|arg| arg == "--provider" || arg == "--model")
        );
    }

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn cli_strips_osc7577_token_from_child_processes_and_run_task_never_reports_osc7577() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = directory.path().join("agent.toml");
    fs::write(&config, "").unwrap();
    let (binary, fixture) = binaries();

    // 1. Prove `beep-boop` strips OSC7577_TOKEN from its process environment before spawning children.
    let probe_out = directory.path().join("child-env.txt");
    let rex_fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rex.sh");
    let fake_bin = directory.path().join("bin");
    fs::create_dir(&fake_bin).unwrap();
    let fake_rex = fake_bin.join("rex");
    fs::write(
        &fake_rex,
        format!(
            "#!/bin/sh\nprintf 'token=<%s>' \"${{OSC7577_TOKEN:-}}\" > {}\nexec {} \"$@\"\n",
            probe_out.display(),
            rex_fixture.display(),
        ),
    )
    .unwrap();
    fs::set_permissions(&fake_rex, fs::Permissions::from_mode(0o755)).unwrap();
    let path_env = format!(
        "{}:{}",
        fake_bin.display(),
        std::env::var("PATH").unwrap_or_default()
    );

    // 2. Run `run-task` in a real PTY with OSC7577_TOKEN set:
    //    - fake `rex` (a child spawned by `beep-boop`) must NOT see OSC7577_TOKEN
    //    - `run-task` itself must NOT emit OSC 7577 (worker panes are coordinator-allocated).
    let server = spawn_mock_coordinator(directory.path());
    let mut child = Command::new(&fixture)
        .arg(&binary)
        .arg("--state-dir")
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .arg("run-task")
        .arg("55555555-5555-4555-8555-555555555555")
        .arg("--allocation-id")
        .arg("alloc-1")
        .current_dir(directory.path())
        .env("TERM", "xterm-256color")
        .env("PATH", &path_env)
        .env("AGENT_TEST_FAKE_REX", directory.path())
        .env("REX_BLOCK", "block:33333333-3333-4333-8333-333333333333")
        .env(
            "REX_SESSION",
            "session:11111111-1111-4111-8111-111111111111",
        )
        .env("AGENT_TEST_TERMINAL_REPLY", "1")
        .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn_serialized()
        .unwrap();

    let mut input = child.stdin.take().unwrap();
    let mut output = child.stdout.take().unwrap();
    let mut bytes = Vec::new();
    read_until(
        &mut output,
        &mut bytes,
        |buf| String::from_utf8_lossy(buf).contains("Worker pane ready."),
        "worker task pane ready",
    )
    .await;
    input.write_all(b"\x03").await.unwrap();
    let (exited, drained) = timeout(Duration::from_secs(5), async {
        tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes))
    })
    .await
    .unwrap();
    drained.unwrap();
    let _ = exited.unwrap();

    assert_eq!(
        fs::read_to_string(&probe_out).expect("fake rex child must have run"),
        "token=<>",
        "child process spawned by beep-boop must never inherit OSC7577_TOKEN"
    );
    assert!(
        !String::from_utf8_lossy(&bytes).contains("\x1b]7577;"),
        "run-task worker pane must never emit OSC 7577"
    );

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn chat_tui_handles_signals_and_sigcont_while_resume_picker_is_open() {
    for (startup_prompt, sig) in [(Some("/resume"), libc::SIGTERM), (None, libc::SIGHUP)] {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let config = directory.path().join("agent.toml");
        fs::write(&config, "").unwrap();
        let pid_file = directory.path().join("child.pid");
        let server = spawn_mock_coordinator(directory.path());

        let (binary, fixture) = binaries();
        let mut command = Command::new(fixture);
        command
            .arg(binary)
            .arg("--state-dir")
            .arg(directory.path())
            .arg("--config")
            .arg(&config)
            .arg("chat");
        if let Some(prompt) = startup_prompt {
            command.arg(prompt);
        }
        let mut child = command
            .current_dir(directory.path())
            .env("TERM", "xterm-256color")
            .env("AGENT_TEST_TERMINAL_REPLY", "1")
            .env("AGENT_TEST_TERMINAL_PID", &pid_file)
            .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn_serialized()
            .unwrap();

        let mut input = child.stdin.take().unwrap();
        let mut output = child.stdout.take().unwrap();
        let mut bytes = Vec::new();

        if startup_prompt.is_none() {
            read_until(
                &mut output,
                &mut bytes,
                |buf| !decode_osc7577_reports(buf, TEST_TOKEN).is_empty(),
                "initial OSC 7577 report before opening picker",
            )
            .await;
            input.write_all(b"/resume\r").await.unwrap();
        }
        read_until(
            &mut output,
            &mut bytes,
            |buf| String::from_utf8_lossy(buf).contains("Resume conversation"),
            "interactive /resume picker heading",
        )
        .await;

        let child_pid: i32 = fs::read_to_string(&pid_file)
            .unwrap()
            .trim()
            .parse()
            .unwrap();
        if startup_prompt.is_none() {
            let before_sigcont = decode_osc7577_reports(&bytes, TEST_TOKEN).len();
            assert_eq!(unsafe { libc::kill(child_pid, libc::SIGCONT) }, 0);
            read_until(
                &mut output,
                &mut bytes,
                |buf| decode_osc7577_reports(buf, TEST_TOKEN).len() > before_sigcont,
                "SIGCONT refresh while /resume picker is open",
            )
            .await;
        }

        assert_eq!(unsafe { libc::kill(child_pid, sig) }, 0);
        let exited = timeout(Duration::from_secs(5), async {
            let (exited, drained) =
                tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes));
            drained.unwrap();
            exited.unwrap()
        })
        .await
        .expect("chat_tui must exit promptly on SIGTERM/SIGHUP while /resume picker is open");
        assert!(!exited.status.success());

        let reports = decode_osc7577_reports(&bytes, TEST_TOKEN);
        if startup_prompt.is_none() {
            assert!(
                reports.len() >= 2,
                "expected initial + SIGCONT reports: {reports:?}"
            );
        }
        assert!(
            !reports
                .iter()
                .any(|report| matches!(report, DecodedOsc7577::Clear { .. })),
            "signal while picker open must preserve resume record: {reports:?}"
        );

        server.abort();
        let _ = server.await;
    }
}

#[tokio::test]
async fn chat_tui_conversation_main_id_canonicalizes_to_plain_chat_report() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = directory.path().join("agent.toml");
    fs::write(&config, "").unwrap();
    let server = spawn_mock_coordinator(directory.path());

    let (binary, fixture) = binaries();
    let mut child = Command::new(fixture)
        .arg(binary)
        .arg("--state-dir")
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .arg("chat")
        .arg("--conversation")
        .arg("1")
        .current_dir(directory.path())
        .env("TERM", "xterm-256color")
        .env("AGENT_TEST_TERMINAL_REPLY", "1")
        .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn_serialized()
        .unwrap();

    let mut input = child.stdin.take().unwrap();
    let mut output = child.stdout.take().unwrap();
    let mut bytes = Vec::new();
    read_until(
        &mut output,
        &mut bytes,
        |buf| !decode_osc7577_reports(buf, TEST_TOKEN).is_empty(),
        "canonical Main OSC 7577 report for --conversation 1",
    )
    .await;
    input.write_all(b"\x03").await.unwrap();
    let (exited, drained) = timeout(Duration::from_secs(5), async {
        tokio::join!(child.wait_with_output(), output.read_to_end(&mut bytes))
    })
    .await
    .unwrap();
    drained.unwrap();
    assert!(exited.unwrap().status.success());

    let reports = decode_osc7577_reports(&bytes, TEST_TOKEN);
    assert_eq!(reports.len(), 2, "expected Resume then Clear: {reports:?}");
    let DecodedOsc7577::Resume { argv, .. } = &reports[0] else {
        panic!("expected Resume report first");
    };
    assert_eq!(&argv[..2], &["beep-boop", "chat"]);
    assert!(
        !argv.iter().any(|arg| arg == "--conversation"),
        "main conversation ID 1 must canonicalize to plain `beep-boop chat`: {argv:?}"
    );
    assert!(matches!(reports[1], DecodedOsc7577::Clear { .. }));

    server.abort();
    let _ = server.await;
}

#[tokio::test]
async fn chat_non_tui_conversation_flag_supports_one_shot_plain_mode_and_rejects_unknown_id() {
    let directory = tempfile::tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = directory.path().join("agent.toml");
    fs::write(&config, "").unwrap();
    let server = spawn_mock_coordinator(directory.path());
    let (binary, _) = binaries();

    // 1. One-shot prompt against `--conversation 42` without TUI emits no OSC 7577.
    let one_shot = Command::new(&binary)
        .arg("--state-dir")
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .arg("chat")
        .arg("--conversation")
        .arg("42")
        .arg("Follow up one-shot")
        .current_dir(directory.path())
        .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output_serialized()
        .await
        .unwrap();
    let one_shot_stdout = String::from_utf8_lossy(&one_shot.stdout);
    assert!(
        one_shot.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&one_shot.stderr)
    );
    assert!(
        one_shot_stdout.contains("Reply[42]: Follow up one-shot"),
        "stdout: {one_shot_stdout}"
    );
    assert!(!one_shot_stdout.contains("\x1b]7577;"));

    // 2. Plain interactive mode (`--no-tui` on piped stdin) against `--conversation 42`.
    let mut plain = Command::new(&binary)
        .arg("--state-dir")
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .arg("--no-tui")
        .arg("chat")
        .arg("--conversation")
        .arg("42")
        .current_dir(directory.path())
        .env(PROGRAM_RESUME_TOKEN_ENV, TEST_TOKEN)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn_serialized()
        .unwrap();
    {
        let mut stdin = plain.stdin.take().unwrap();
        stdin.write_all(b"Follow up plain\n/exit\n").await.unwrap();
    }
    let plain_out = timeout(Duration::from_secs(10), plain.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    let plain_stdout = String::from_utf8_lossy(&plain_out.stdout);
    assert!(
        plain_out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&plain_out.stderr)
    );
    assert!(
        plain_stdout.contains("Conversation 42 transcript ready."),
        "stdout: {plain_stdout}"
    );
    assert!(
        plain_stdout.contains("Reply[42]: Follow up plain"),
        "stdout: {plain_stdout}"
    );
    assert!(!plain_stdout.contains("\x1b]7577;"));

    // 3. Unknown `--conversation 999` fails cleanly.
    let unknown = Command::new(&binary)
        .arg("--state-dir")
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .arg("chat")
        .arg("--conversation")
        .arg("999")
        .arg("Hello")
        .current_dir(directory.path())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output_serialized()
        .await
        .unwrap();
    assert!(!unknown.status.success());
    assert!(
        String::from_utf8_lossy(&unknown.stderr).contains("Choose an existing saved conversation."),
        "stderr: {}",
        String::from_utf8_lossy(&unknown.stderr)
    );

    server.abort();
    let _ = server.await;
}
