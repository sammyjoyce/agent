//! A command that finds no local coordinator starts one and waits for it,
//! also when the real coordinator takes longer than the old five seconds.

use agent_cli::serialized_spawn::SerializedSpawn;
use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Stdio,
    thread,
    time::{Duration, Instant},
};

#[path = "fixtures/coordinator.rs"]
mod coordinator_fixture;
use coordinator_fixture::{COORDINATOR_READY_TIMEOUT, Coordinator};
#[path = "fixtures/executable.rs"]
mod executable_fixture;
use executable_fixture::write_executable;

/// The coordinator this test's command started in its own session. Only that
/// process is signalled.
struct Started(Option<libc::pid_t>);

impl Started {
    fn stop(&mut self, state: &Path) {
        let Some(pid) = self.0.take() else {
            return;
        };
        unsafe { libc::kill(pid, libc::SIGTERM) };
        let deadline = Instant::now() + Duration::from_secs(30);
        while state.join("agent.sock").exists() || unsafe { libc::kill(pid, 0) } == 0 {
            assert!(
                Instant::now() < deadline,
                "The started coordinator did not stop"
            );
            thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Started {
    fn drop(&mut self) {
        if let Some(pid) = self.0.take() {
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
}

#[test]
fn a_command_waits_for_a_local_coordinator_slower_than_five_seconds() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path();
    let (state, bin, codex) = (root.join("state"), root.join("bin"), root.join("codex"));
    for path in [&state, &bin, &codex] {
        fs::create_dir(path).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    let config = root.join("config.toml");
    fs::write(&config, "").unwrap();
    let instructions = codex.join("AGENTS.md");
    fs::write(&instructions, "Use only invented fixture data.\n").unwrap();
    for name in ["rex", "tailscale"] {
        write_executable(&bin.join(name), "#!/bin/sh\nexit 1\n");
    }
    let native = std::env::var_os("AGENT_RUNTIME_PATH")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new(env!("CARGO_MANIFEST_DIR")).join("runtime/dist/src/bridge.js"))
        .canonicalize()
        .unwrap();
    // The real runtime, held before it loads. The coordinator that runs it
    // is the process this command started; record it to stop it later.
    let runtime = root.join("slow-runtime.mjs");
    fs::write(
        &runtime,
        format!(
            "import {{writeFileSync}} from 'node:fs';\n\
             import {{join}} from 'node:path';\n\
             import {{setTimeout}} from 'node:timers/promises';\n\
             import {{pathToFileURL}} from 'node:url';\n\
             writeFileSync(join(process.argv[2], 'coordinator.pid'), String(process.ppid));\n\
             await setTimeout(8000);\n\
             await import(pathToFileURL({}).href);\n",
            serde_json::to_string(&native).unwrap()
        ),
    )
    .unwrap();
    let coordinator = Coordinator {
        directory: root,
        config: &config,
        state: &state,
        bin: &bin,
        instructions: &instructions,
        runtime: &runtime,
    };
    let started_at = Instant::now();
    let mut child = coordinator
        .command(&["status"], true)
        // The started coordinator reads the default instructions file.
        .env("CODEX_HOME", &codex)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn_serialized()
        .unwrap();
    let mut started = Started(None);
    let deadline = Instant::now() + COORDINATOR_READY_TIMEOUT;
    while child.try_wait().unwrap().is_none() {
        if started.0.is_none() {
            started.0 = fs::read_to_string(state.join("coordinator.pid"))
                .ok()
                .and_then(|pid| pid.trim().parse().ok());
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    let output = child.wait_with_output().unwrap();
    let waited = started_at.elapsed();
    if started.0.is_none() {
        started.0 = fs::read_to_string(state.join("coordinator.pid"))
            .ok()
            .and_then(|pid| pid.trim().parse().ok());
    }
    let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(
        output.status.success(),
        "status failed after {waited:?}: {stderr}\n{}",
        coordinator.startup_diagnostics()
    );
    assert!(waited > Duration::from_secs(8), "{waited:?}");
    assert!(stdout.contains("auth_status"), "{stdout}");
    println!("status answered after {waited:?}: {}", stdout.trim());
    assert!(started.0.is_some(), "The coordinator recorded no process");
    started.stop(&state);
}
