//! `import chatgpt` checks an export on the client before anything reaches a coordinator.
use std::{
    io::{Cursor, Write},
    path::{Path, PathBuf},
    process::{Command, Output},
};

use agent_cli::history::chatgpt::ChatGptPackageSummary;
use serde_json::json;
use zip::{CompressionMethod, ZipWriter, write::SimpleFileOptions};

fn export(path: &Path, extra: Option<(&str, &[u8])>) -> PathBuf {
    let conversation = json!({
        "id": "00000000-0000-4000-8000-000000000001",
        "title": "Picnic",
        "create_time": 1_767_225_600.0,
        "update_time": 1_767_225_700.0,
        "current_node": "a1",
        "mapping": {
            "root": {"id": "root", "message": null, "parent": null},
            "u1": {"id": "u1", "parent": "root", "message": {"id": "u1", "author": {"role": "user"},
                "content": {"content_type": "text", "parts": ["Plan a picnic for six"]}}},
            "a1": {"id": "a1", "parent": "u1", "message": {"id": "a1", "author": {"role": "assistant"},
                "content": {"content_type": "text", "parts": ["Here is a plan for six."]}}},
        },
    });
    let mut writer = ZipWriter::new(Cursor::new(Vec::new()));
    let options = SimpleFileOptions::default().compression_method(CompressionMethod::Deflated);
    writer.start_file("conversations.json", options).unwrap();
    writer
        .write_all(&serde_json::to_vec(&[conversation]).unwrap())
        .unwrap();
    if let Some((name, bytes)) = extra {
        writer.start_file(name, options).unwrap();
        writer.write_all(bytes).unwrap();
    }
    std::fs::write(path, writer.finish().unwrap().into_inner()).unwrap();
    path.to_path_buf()
}

fn run(home: &Path, state: &Path, arguments: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_beep-boop"))
        .env_clear()
        .env("HOME", home)
        .env("PATH", "/usr/bin:/bin")
        .env("TMPDIR", home)
        .arg("--state-dir")
        .arg(state)
        .args(arguments)
        .output()
        .unwrap()
}

fn untouched(state: &Path) {
    assert!(!state.join("agent.sock").exists());
    assert!(!state.join("session.sqlite").exists());
}

#[test]
fn check_reports_and_never_contacts_a_coordinator() {
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("state");
    let path = export(&directory.path().join("export.zip"), None);
    let output = run(
        directory.path(),
        &state,
        &["import", "chatgpt", "--check", path.to_str().unwrap()],
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(output.status.success(), "{stderr}");
    assert!(
        stderr.contains("1 conversations (0 archived) in 1 shards"),
        "{stderr}"
    );
    assert!(output.stdout.is_empty());
    untouched(&state);
}

#[test]
fn check_json_prints_the_summary_on_stdout() {
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("state");
    let path = export(&directory.path().join("export.zip"), None);
    let output = run(
        directory.path(),
        &state,
        &[
            "--json",
            "import",
            "chatgpt",
            "--check",
            path.to_str().unwrap(),
        ],
    );
    assert!(output.status.success());
    let stdout = String::from_utf8(output.stdout).unwrap();
    assert_eq!(stdout.lines().count(), 1);
    let summary: ChatGptPackageSummary = serde_json::from_str(&stdout).unwrap();
    assert_eq!((summary.conversations, summary.shards), (1, 1));
    assert_eq!(summary.parts, ["export.zip"]);
    untouched(&state);
}

#[test]
fn invalid_export_exits_nonzero_before_admission() {
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("state");
    let path = export(
        &directory.path().join("export.zip"),
        Some(("../escape.json", b"Invented escape attempt")),
    );
    let output = run(
        directory.path(),
        &state,
        &["import", "chatgpt", path.to_str().unwrap()],
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert_eq!(output.status.code(), Some(1), "{stderr}");
    assert!(stderr.contains("path traversal"), "{stderr}");
    assert!(stderr.contains("Nothing was imported."), "{stderr}");
    assert!(!directory.path().join("escape.json").exists());
    untouched(&state);
}
