//! Real CLI feedback producer -> fake Rex CLI that owns the origin pane on one
//! server -> coordinator socket that consumes the feedback context.
#[path = "fixtures/fake_rex.rs"]
mod fake_rex;

use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Stdio, time::Duration};

use agent_cli::{
    feedback::{FeedbackContext, FeedbackReceipt},
    models::ModelSelection,
    protocol::{CoordinatorSettings, RuntimeCommand, RuntimeEventKind},
    runtime::FrameReader,
};
use tokio::{
    io::{AsyncWriteExt, BufReader},
    net::{
        UnixListener,
        unix::{OwnedReadHalf, OwnedWriteHalf},
    },
    process::Command,
    time::timeout,
};

const DECOY: &str = "unix:///run/user/1000/rex-decoy/server.sock";
const PRIVATE: &str = "unix:///run/user/1000/rex-agent/server.sock";
const TASK: &str = "77777777-7777-4777-8777-777777777777";
const DESCRIPTION: &str = "/feedback The invented composer is clipped.";
const ORIGIN_PANE: [&str; 3] = [
    fake_rex::ORIGIN_SESSION,
    fake_rex::ORIGIN_WINDOW,
    fake_rex::ORIGIN_BLOCK,
];

/// The coordinator rejects a terminal whose host differs from the origin host
/// as one on another machine.
fn assert_origin_pane(context: FeedbackContext, label: &str) {
    let binding = context
        .binding
        .expect("Feedback from inside Rex must name its terminal pane");
    assert_eq!(binding.host_id, context.origin_host_id, "{label}");
    assert_eq!(
        [binding.session_id, binding.window_id, binding.block_id],
        ORIGIN_PANE,
        "{label}"
    );
}

/// The terminal's environment names `DECOY` through `REX_SERVER`; only
/// `origin_server`, a Rex host of its own, holds the pane that `REX_SESSION`
/// and `REX_BLOCK` name.
fn cli(directory: &Path, rex_server: Option<&str>, origin_server: &str, args: &[&str]) -> Command {
    let bin = directory.join("bin");
    fs::create_dir(&bin).unwrap();
    std::os::unix::fs::symlink(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rex.sh"),
        bin.join("rex"),
    )
    .unwrap();
    let config = directory.join("config.toml");
    fs::write(&config, "").unwrap();
    let instructions = directory.join("AGENTS.md");
    fs::write(&instructions, "").unwrap();
    let path = std::env::join_paths(std::iter::once(bin.clone()).chain(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    )))
    .unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_beep-boop"));
    if let Some(server) = rex_server {
        command.args(["--rex-server", server]);
    }
    command
        .args(["--json", "--no-tui", "--state-dir"])
        .arg(directory)
        .arg("--config")
        .arg(config)
        .arg("--instructions")
        .arg(instructions)
        .args(args)
        .env("PATH", path)
        .env("AGENT_TEST_FAKE_REX", &bin)
        .env("AGENT_TEST_FAKE_REX_ORIGIN_SERVER", origin_server)
        .env("REX_SERVER", DECOY)
        .env("REX_SESSION", fake_rex::ORIGIN_SESSION)
        .env("REX_BLOCK", fake_rex::ORIGIN_BLOCK)
        .env_remove("REX_CLIENT")
        .current_dir(directory)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    command
}

fn coordinator(directory: &Path) -> UnixListener {
    fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    UnixListener::bind(directory.join("agent.sock")).unwrap()
}

type Frames = FrameReader<BufReader<OwnedReadHalf>>;

async fn accept(listener: &UnixListener) -> (RuntimeCommand, Frames, OwnedWriteHalf) {
    let (stream, _) = listener.accept().await.unwrap();
    let (reader, writer) = stream.into_split();
    let mut frames = FrameReader::new(BufReader::new(reader));
    let command = serde_json::from_slice(&frames.next_frame().await.unwrap().unwrap()).unwrap();
    (command, frames, writer)
}

async fn write_events(
    writer: &mut OwnedWriteHalf,
    events: impl IntoIterator<Item = RuntimeEventKind>,
) {
    let mut bytes = Vec::new();
    for event in events {
        serde_json::to_writer(&mut bytes, &event).unwrap();
        bytes.push(b'\n');
    }
    writer.write_all(&bytes).await.unwrap();
}

fn feedback_ready() -> RuntimeEventKind {
    RuntimeEventKind::FeedbackReady {
        receipt: FeedbackReceipt {
            id: "invented-feedback".into(),
            path: "/example/feedback/invented-feedback.json".into(),
            task_id: TASK.parse().unwrap(),
            agent_id: None,
        },
        input_id: None,
    }
}

#[tokio::test]
async fn terminal_feedback_reports_the_pane_from_the_rex_server_that_owns_the_terminal() {
    for rex_server in [None, Some(PRIVATE)] {
        let directory = tempfile::tempdir().unwrap();
        let listener = coordinator(directory.path());
        let consumer = tokio::spawn(async move {
            let (command, _frames, mut writer) = accept(&listener).await;
            let RuntimeCommand::Feedback { context, .. } = command else {
                panic!("Expected feedback, got {command:?}");
            };
            write_events(&mut writer, [feedback_ready(), RuntimeEventKind::Done]).await;
            context
        });
        let output = timeout(
            Duration::from_secs(30),
            cli(directory.path(), rex_server, DECOY, &["chat", DESCRIPTION]).output(),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(
            output.status.success(),
            "--rex-server {rex_server:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_origin_pane(
            consumer.await.unwrap(),
            &format!("--rex-server {rex_server:?}"),
        );
    }
}

#[tokio::test]
async fn worker_feedback_reports_its_pane_on_the_private_rex_server_that_started_it() {
    let directory = tempfile::tempdir().unwrap();
    let listener = coordinator(directory.path());
    let consumer = tokio::spawn(async move {
        loop {
            let (command, mut frames, mut writer) = accept(&listener).await;
            match command {
                RuntimeCommand::Environment { .. } => {
                    let settings = CoordinatorSettings {
                        model: ModelSelection::default(),
                        instructions: String::new(),
                        context_repositories: Vec::new(),
                        sources: Vec::new(),
                    };
                    let environment = RuntimeEventKind::Environment {
                        settings,
                        nodes: Vec::new(),
                        online_host_ids: Vec::new(),
                        unavailable_host_ids: None,
                    };
                    write_events(&mut writer, [environment, RuntimeEventKind::Done]).await;
                }
                RuntimeCommand::RunTask { .. } => {
                    let ready = RuntimeEventKind::TaskReady {
                        conversation_id: "invented-task-conversation".into(),
                        title: "Synthetic task".into(),
                    };
                    write_events(&mut writer, [ready]).await;
                    tokio::spawn(async move {
                        while let Ok(Some(frame)) = frames.next_frame().await {
                            let command: RuntimeCommand = serde_json::from_slice(&frame).unwrap();
                            if matches!(command, RuntimeCommand::DetachWorker) {
                                write_events(&mut writer, [RuntimeEventKind::Done]).await;
                                return;
                            }
                        }
                    });
                }
                RuntimeCommand::Feedback { context, .. } => {
                    write_events(&mut writer, [feedback_ready()]).await;
                    return context;
                }
                command => panic!("Unexpected worker command {command:?}"),
            }
        }
    });
    let mut worker = cli(
        directory.path(),
        Some(PRIVATE),
        PRIVATE,
        &["run-task", TASK, "--allocation-id", "allocation-root"],
    )
    .stdin(Stdio::piped())
    .spawn()
    .unwrap();
    let mut stdin = worker.stdin.take().unwrap();
    stdin
        .write_all(format!("{DESCRIPTION}\n").as_bytes())
        .await
        .unwrap();
    let context = match timeout(Duration::from_secs(30), consumer).await {
        Ok(context) => context.unwrap(),
        Err(_) => {
            worker.start_kill().unwrap();
            let output = worker.wait_with_output().await.unwrap();
            panic!(
                "The worker's feedback never reached the coordinator: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    };
    drop(stdin);
    let output = timeout(Duration::from_secs(30), worker.wait_with_output())
        .await
        .unwrap()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_origin_pane(context, "run-task --rex-server");
}
