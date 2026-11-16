#![allow(dead_code)]

use std::{
    fs,
    os::unix::net::UnixStream,
    path::Path,
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};

// Package qualification can share a host with native compilers. Keep startup
// bounded without treating a brief scheduling delay as coordinator failure.
pub const COORDINATOR_READY_TIMEOUT: Duration = Duration::from_secs(60);

pub struct Coordinator<'a> {
    pub directory: &'a Path,
    pub config: &'a Path,
    pub state: &'a Path,
    pub bin: &'a Path,
    pub instructions: &'a Path,
    pub runtime: &'a Path,
}

impl Coordinator<'_> {
    pub fn command(&self, args: &[&str], json: bool) -> Command {
        // Qualify the packaged binary with the same real coordinator lifecycle tests.
        let binary = std::env::var_os("AGENT_CLI_PATH")
            .unwrap_or_else(|| env!("CARGO_BIN_EXE_beep-boop").into());
        let mut command = Command::new(binary);
        let mut paths = vec![self.bin.to_owned()];
        paths.extend(std::env::split_paths(&std::env::var_os("PATH").unwrap()));
        if json {
            command.arg("--json");
        }
        command
            .arg("--config")
            .arg(self.config)
            .arg("--state-dir")
            .arg(self.state)
            .arg("--runtime")
            .arg(self.runtime)
            .arg("--instructions")
            .arg(self.instructions)
            .args(args)
            .env("PATH", std::env::join_paths(paths).unwrap())
            .env(
                "AGENT_TEST_EXTERNAL_CALLS",
                self.directory.join("external-calls"),
            )
            .stdin(Stdio::null());
        command
    }

    pub fn start(&self, mut ready: impl FnMut() -> bool, ready_description: &str) -> Server {
        let stderr = self.directory.join("server.stderr");
        let child = self
            .command(&["serve", "--local-only", "--no-sources"], true)
            .stdout(Stdio::null())
            .stderr(fs::File::create(&stderr).unwrap())
            .spawn()
            .unwrap();
        let mut server = Server(Some(child));
        let deadline = Instant::now() + COORDINATOR_READY_TIMEOUT;
        // The pathname can appear before listen(2) accepts connections.
        while UnixStream::connect(self.state.join("agent.sock")).is_err() {
            assert!(
                server.0.as_mut().unwrap().try_wait().unwrap().is_none(),
                "Fixture coordinator exited before binding: {}",
                self.startup_diagnostics()
            );
            assert!(
                Instant::now() < deadline,
                "Fixture coordinator did not bind: {}",
                self.startup_diagnostics()
            );
            thread::sleep(Duration::from_millis(10));
        }
        while !ready() {
            assert!(
                Instant::now() < deadline,
                "{ready_description}: {}",
                self.startup_diagnostics()
            );
            thread::sleep(Duration::from_millis(10));
        }
        server
    }

    pub fn startup_diagnostics(&self) -> String {
        let stderr = fs::read_to_string(self.directory.join("server.stderr")).unwrap_or_default();
        let startup = fs::read_to_string(self.state.join("diagnostics/startup.jsonl"))
            .unwrap_or_else(|error| format!("Native startup diagnostics unavailable: {error}"));
        format!("{stderr}\nNative startup stages:\n{startup}")
    }
}

pub struct Server(Option<Child>);

impl Server {
    pub fn stop(&mut self) {
        if let Some(mut child) = self.0.take() {
            // Only the coordinator process started by this fixture is signalled.
            let pid = libc::pid_t::try_from(child.id()).unwrap();
            unsafe { libc::kill(pid, libc::SIGTERM) };
            let deadline = Instant::now() + Duration::from_secs(10);
            while child.try_wait().unwrap().is_none() {
                if Instant::now() >= deadline {
                    child.kill().unwrap();
                    child.wait().unwrap();
                    assert!(
                        thread::panicking(),
                        "Fixture coordinator did not stop gracefully"
                    );
                    return;
                }
                thread::sleep(Duration::from_millis(10));
            }
            assert!(
                child.wait().unwrap().success() || thread::panicking(),
                "Fixture coordinator shutdown failed"
            );
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.stop();
    }
}
