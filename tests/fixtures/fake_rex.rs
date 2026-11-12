//! PATH is process-wide, so each scenario re-executes the test binary with
//! the fixture first on PATH.
#![allow(dead_code)]

use std::path::Path;

pub const HOST: &str = "44444444-4444-4444-8444-444444444444";
pub const ORIGIN_SESSION: &str = "session:11111111-1111-4111-8111-111111111111";
pub const ORIGIN_WINDOW: &str = "window:22222222-2222-4222-8222-222222222222";
pub const ORIGIN_BLOCK: &str = "block:33333333-3333-4333-8333-333333333333";
pub const CREATED_SESSION: &str = "session:aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
/// The missing socket from the live dead-socket probe, so the fixture's
/// stderr matches what Rex printed byte for byte.
pub const DEAD_ENDPOINT: &str = "unix:///run/user/1000/rex-probe-dead/missing.sock";
const CASE: &str = "AGENT_TEST_FAKE_REX_CASE";

pub fn case() -> Option<String> {
    std::env::var(CASE).ok()
}

pub fn run(test: &str, case: &str, envs: &[(&str, &str)]) {
    let directory = tempfile::tempdir().unwrap();
    std::os::unix::fs::symlink(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rex.sh"),
        directory.path().join("rex"),
    )
    .unwrap();
    let path = std::env::join_paths(std::iter::once(directory.path().to_owned()).chain(
        std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
    ))
    .unwrap();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", test, "--nocapture"])
        .env(CASE, case)
        .env("AGENT_TEST_FAKE_REX", directory.path())
        .env("PATH", path)
        .envs(envs.iter().copied())
        .output()
        .unwrap();
    assert!(
        output.status.success()
            && String::from_utf8_lossy(&output.stdout).contains("test result: ok. 1 passed"),
        "Fake Rex case {case}:\n{}\n{}\nCalls:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
        std::fs::read_to_string(directory.path().join("calls")).unwrap_or_default(),
    );
}

pub struct Call {
    pub rex_server: Option<String>,
    pub args: Vec<String>,
}
impl Call {
    pub fn method(&self) -> &str {
        let position = self
            .args
            .iter()
            .position(|arg| arg == "call")
            .map(|call| call + 1)
            .or_else(|| {
                self.args
                    .iter()
                    .position(|arg| arg == "whoami" || arg == "hosts")
            });
        position.map_or("", |position| &self.args[position])
    }
    pub fn server(&self) -> Option<&str> {
        let flag = self.args.iter().position(|arg| arg == "--server")?;
        self.args.get(flag + 1).map(String::as_str)
    }
    pub fn payload(&self) -> serde_json::Value {
        let call = self.args.iter().position(|arg| arg == "call").unwrap();
        serde_json::from_str(&self.args[call + 2]).unwrap()
    }
}

pub fn calls() -> Vec<Call> {
    let root = std::env::var_os("AGENT_TEST_FAKE_REX").unwrap();
    std::fs::read_to_string(Path::new(&root).join("calls"))
        .unwrap_or_default()
        .lines()
        .map(|line| {
            let (server, args) = line.split_once('\t').unwrap();
            Call {
                rex_server: (server != "<unset>").then(|| server.to_owned()),
                args: args.split_terminator('\u{1f}').map(str::to_owned).collect(),
            }
        })
        .collect()
}

pub fn methods() -> Vec<String> {
    calls()
        .iter()
        .map(|call| call.method().to_owned())
        .collect()
}
