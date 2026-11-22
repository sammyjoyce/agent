use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Stdio};

use agent_cli::{
    protocol::{ErrorCode, RuntimeCommand, RuntimeEventKind},
    serialized_spawn::{SerializedSpawn, SerializedTokioSpawn},
};
use tempfile::tempdir;
use tokio::{io::AsyncWriteExt, net::UnixListener};

const CLI: &str = env!("CARGO_BIN_EXE_beep-boop");

fn parse_single_failure(stdout: &[u8]) -> RuntimeEventKind {
    let text = std::str::from_utf8(stdout).expect("stdout must be UTF-8");
    let lines: Vec<_> = text
        .lines()
        .filter(|line| !line.trim().is_empty())
        .collect();
    assert_eq!(
        lines.len(),
        1,
        "expected one JSON event on stdout: {text:?}"
    );
    serde_json::from_str(lines[0]).expect("stdout line must parse as RuntimeEventKind")
}

fn write_test_config(directory: &Path) -> std::path::PathBuf {
    let config = directory.join("config.toml");
    fs::write(
        &config,
        "[model]\nprovider = \"openai\"\nmodel_id = \"gpt-5.4\"\n",
    )
    .unwrap();
    config
}

#[test]
fn json_clap_parse_errors_emit_invalid_request_json_and_keep_help_plain() {
    let failed = std::process::Command::new(CLI)
        .args(["--json", "tasks", "--nonexistent-flag"])
        .output_serialized()
        .unwrap();
    assert!(!failed.status.success());
    match parse_single_failure(&failed.stdout) {
        RuntimeEventKind::Failure { code, message } => {
            assert_eq!(code, ErrorCode::InvalidRequest);
            assert!(message.contains("--nonexistent-flag"), "{message}");
        }
        other => panic!("unexpected event: {other:?}"),
    }

    let help = std::process::Command::new(CLI)
        .args(["--json", "--help"])
        .output_serialized()
        .unwrap();
    assert!(help.status.success());
    assert!(String::from_utf8_lossy(&help.stdout).contains("Usage:"));
}

#[test]
fn json_local_command_failures_emit_structured_json_on_stdout() {
    let directory = tempdir().unwrap();
    let config = write_test_config(directory.path());
    let missing_archive = directory.path().join("missing-export.zip");
    let output = std::process::Command::new(CLI)
        .args(["--json", "--state-dir"])
        .arg(directory.path())
        .arg("--config")
        .arg(&config)
        .args(["import", "chatgpt"])
        .arg(&missing_archive)
        .output_serialized()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    match parse_single_failure(&output.stdout) {
        RuntimeEventKind::Failure { code, message } => {
            assert_eq!(code, ErrorCode::InvalidRequest);
            assert!(!message.is_empty());
        }
        other => panic!("unexpected event: {other:?}"),
    }
}

#[tokio::test]
async fn json_coordinator_and_runtime_failures_preserve_error_code_on_stdout() {
    let directory = tempdir().unwrap();
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let config = write_test_config(directory.path());
    let instructions = directory.path().join("AGENTS.md");
    fs::write(&instructions, "").unwrap();
    let listener = UnixListener::bind(directory.path().join("agent.sock")).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut reader = agent_cli::runtime::FrameReader::new(tokio::io::BufReader::new(reader));
        let frame = reader.next_frame().await.unwrap().unwrap();
        let command: RuntimeCommand = serde_json::from_slice(&frame).unwrap();
        assert!(matches!(command, RuntimeCommand::ReadTaskGraph));
        let failure = RuntimeEventKind::Failure {
            code: ErrorCode::StorageUnavailable,
            message: "Synthetic store offline".into(),
        };
        writer
            .write_all(&serde_json::to_vec(&failure).unwrap())
            .await
            .unwrap();
        writer.write_all(b"\n").await.unwrap();
    });

    let output = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        tokio::process::Command::new(CLI)
            .args(["--json", "--no-tui", "--state-dir"])
            .arg(directory.path())
            .arg("--config")
            .arg(&config)
            .arg("--instructions")
            .arg(&instructions)
            .args(["tasks", "graph"])
            .stdin(Stdio::null())
            .output_serialized(),
    )
    .await
    .expect("CLI timed out")
    .unwrap();
    let stdout_text = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr_text = String::from_utf8_lossy(&output.stderr).into_owned();
    tokio::time::timeout(std::time::Duration::from_secs(5), server)
        .await
        .unwrap_or_else(|_| panic!("mock server never received connection; stdout={stdout_text:?} stderr={stderr_text:?}"))
        .unwrap();

    assert_eq!(output.status.code(), Some(1));
    match parse_single_failure(&output.stdout) {
        RuntimeEventKind::Failure { code, message } => {
            assert_eq!(code, ErrorCode::StorageUnavailable);
            assert_eq!(message, "Synthetic store offline");
        }
        other => panic!("unexpected event: {other:?}"),
    }

    let missing_runtime = directory.path().join("missing-runtime.js");
    let dial_failed = tokio::process::Command::new(CLI)
        .args(["--json", "--no-tui", "--state-dir"])
        .arg(directory.path().join("other-state"))
        .arg("--config")
        .arg(&config)
        .arg("--instructions")
        .arg(&instructions)
        .arg("--runtime")
        .arg(&missing_runtime)
        .args(["tasks", "graph"])
        .stdin(Stdio::null())
        .output_serialized()
        .await
        .unwrap();
    assert_eq!(dial_failed.status.code(), Some(1));
    assert!(matches!(
        parse_single_failure(&dial_failed.stdout),
        RuntimeEventKind::Failure { .. }
    ));
}
