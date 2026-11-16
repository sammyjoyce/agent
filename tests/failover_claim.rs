use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    thread,
    time::{Duration, Instant},
};

use serde_json::{Value, json};

const COORDINATOR: &str = "11111111-1111-4111-8111-111111111111";
const HOLDER: &str = "22222222-2222-4222-8222-222222222222";
const OTHER_HOLDER: &str = "33333333-3333-4333-8333-333333333333";
const AUTHORITY: &str = "https://authority.example.invalid/coordinators/fixture";
const OWNER_FENCED: i32 = 75;

const BRIDGE: &str = r#"
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
const root = dirname(process.argv[1]);
const record = join(root, "bridge.json");
writeFileSync(record + ".tmp", JSON.stringify({ failover: process.env.AGENT_FAILOVER ?? null }));
renameSync(record + ".tmp", record);
setInterval(() => {
  const exit = join(root, "exit");
  if (existsSync(exit)) process.exit(Number(readFileSync(exit, "utf8")));
}, 20);
const input = createInterface({ input: process.stdin });
input.on("close", () => process.exit(0));
input.on("line", line => {
  const { id, command } = JSON.parse(line);
  if (command.type === "run_background") return;
  process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "configured" } }) + "\n");
  process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "done" } }) + "\n");
});
"#;

/// Scripted, because these tests need what no authority can be made to give:
/// a chosen exit status, a garbled report, and a record of each run.
const HELPER: &str = r#"
const { appendFileSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
appendFileSync(join(__dirname, "runs.ndjson"),
  JSON.stringify({ request: process.argv[2], session: process.env.AGENT_FAILOVER ?? null }) + "\n");
const answer = JSON.parse(readFileSync(join(__dirname, "answer.json"), "utf8"));
process.stdout.write(answer.stdout);
process.stderr.write(answer.stderr);
process.exitCode = answer.status;
"#;

/// One coordinator host: private state, config and home directories, a fixture
/// runtime with a fake failover helper, and a fake Rex that records each call.
struct World {
    _root: tempfile::TempDir,
    state: PathBuf,
    runtime: PathBuf,
    config: PathBuf,
    home: PathBuf,
    rex: PathBuf,
}

enum Failover {
    Absent,
    Holder,
    Watcher,
}

impl World {
    fn new(failover: Failover) -> Self {
        let root = tempfile::tempdir().unwrap();
        let path = |name: &str| {
            let path = root.path().join(name);
            fs::create_dir_all(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            path
        };
        let (state, runtime, home, rex) =
            (path("state"), path("runtime"), path("home"), path("rex"));
        fs::create_dir(runtime.join("failover")).unwrap();
        fs::write(runtime.join("bridge.mjs"), BRIDGE).unwrap();
        fs::write(runtime.join("failover/helper.js"), HELPER).unwrap();
        std::os::unix::fs::symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/rex.sh"),
            rex.join("rex"),
        )
        .unwrap();
        let token = home.join("failover-token");
        fs::write(&token, "invented-holder-token").unwrap();
        fs::set_permissions(&token, fs::Permissions::from_mode(0o600)).unwrap();
        let holder = match failover {
            Failover::Absent => None,
            Failover::Holder => Some(format!("holder = '{HOLDER}'\n")),
            Failover::Watcher => Some(String::new()),
        };
        let mut config = "[[sources]]\nprovider = 'messages'\n".to_owned();
        if let Some(holder) = holder {
            config.push_str(&format!(
                "[failover]\nurl = '{AUTHORITY}'\n{holder}token_file = '~/failover-token'\n"
            ));
        }
        let config_path = root.path().join("config.toml");
        fs::write(&config_path, config).unwrap();
        Self {
            state,
            runtime,
            config: config_path,
            home,
            rex,
            _root: root,
        }
    }

    fn with_coordinator_id(self) -> Self {
        fs::write(self.state.join("coordinator-id"), COORDINATOR).unwrap();
        self
    }

    fn answer(&self, stdout: Value, stderr: &str, status: i32) {
        let stdout = match stdout {
            Value::String(text) => text,
            report => format!("{report}\n"),
        };
        fs::write(
            self.runtime.join("failover/answer.json"),
            json!({ "stdout": stdout, "stderr": stderr, "status": status }).to_string(),
        )
        .unwrap();
    }

    fn command(&self) -> Command {
        let path = std::env::join_paths(std::iter::once(self.rex.clone()).chain(
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default()),
        ))
        .unwrap();
        let mut command = Command::new(env!("CARGO_BIN_EXE_beep-boop"));
        command
            .arg("--state-dir")
            .arg(&self.state)
            .arg("--runtime")
            .arg(self.runtime.join("bridge.mjs"))
            .arg("--config")
            .arg(&self.config)
            .arg("--instructions")
            .arg(self.home.join("AGENTS.md"))
            .args(["serve", "--local-only"])
            .env("PATH", path)
            .env("HOME", &self.home)
            .env("REX_CONFIG", self.home.join("rex/init.lua"))
            .env("AGENT_TEST_FAKE_REX", &self.rex)
            .env("AGENT_TEST_FAKE_REX_FAIL_AT", "whoami")
            .env_remove("REX_SERVER")
            .env_remove("REX_SESSION")
            .env_remove("REX_BLOCK")
            .env_remove("AGENT_FAILOVER")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped());
        command
    }

    fn serve(&self) -> Supervisor {
        self.serve_with(&[])
    }

    fn serve_with(&self, environment: &[(&str, &str)]) -> Supervisor {
        let mut command = self.command();
        command.envs(environment.iter().copied());
        let supervisor = Supervisor(Some(command.spawn().unwrap()));
        until("the coordinator socket", || self.socket().exists());
        supervisor
    }

    fn run(&self) -> Output {
        Supervisor(Some(self.command().spawn().unwrap())).finish()
    }

    fn socket(&self) -> PathBuf {
        self.state.join("agent.sock")
    }

    fn helper_runs(&self) -> Vec<Value> {
        fs::read_to_string(self.runtime.join("failover/runs.ndjson"))
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    fn bridge(&self) -> Option<Value> {
        fs::read(self.runtime.join("bridge.json"))
            .ok()
            .map(|bytes| serde_json::from_slice(&bytes).unwrap())
    }

    fn rex_calls(&self) -> Option<String> {
        fs::read_to_string(self.rex.join("calls")).ok()
    }
}

struct Supervisor(Option<Child>);

impl Supervisor {
    fn finish(mut self) -> Output {
        let mut child = self.0.take().unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() > deadline {
                let _ = child.kill();
                let output = child.wait_with_output().unwrap();
                panic!(
                    "The coordinator did not exit: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            thread::sleep(Duration::from_millis(20));
        }
        child.wait_with_output().unwrap()
    }

    fn terminate(self) -> Output {
        let pid = self.0.as_ref().unwrap().id();
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
        self.finish()
    }
}

impl Drop for Supervisor {
    fn drop(&mut self) {
        if let Some(child) = self.0.take() {
            Supervisor(Some(child)).terminate();
        }
    }
}

fn until(what: &str, ready: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !ready() {
        assert!(Instant::now() < deadline, "Timed out waiting for {what}");
        thread::sleep(Duration::from_millis(20));
    }
}

fn stderr(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

fn session(text: &Value) -> Value {
    serde_json::from_str(text.as_str().expect("AGENT_FAILOVER is set")).unwrap()
}

#[test]
fn a_coordinator_without_failover_mints_its_id_and_never_passes_a_failover_session_to_pi() {
    let world = World::new(Failover::Absent);
    let inherited = json!({ "url": AUTHORITY, "holder": OTHER_HOLDER, "epoch": 9 }).to_string();
    let supervisor = world.serve_with(&[("AGENT_FAILOVER", &inherited)]);
    let minted = fs::read_to_string(world.state.join("coordinator-id")).unwrap();
    assert_eq!(uuid::Uuid::parse_str(&minted).unwrap().to_string(), minted);
    assert_eq!(world.bridge().unwrap(), json!({ "failover": null }));
    assert!(world.helper_runs().is_empty());
    until("Messages source setup", || {
        world
            .rex_calls()
            .is_some_and(|calls| calls.contains("config\u{1f}check"))
    });
    drop(supervisor);
}

#[test]
fn a_refused_claim_exits_75_before_sources_rex_pi_or_a_socket() {
    let world = World::new(Failover::Holder).with_coordinator_id();
    world.answer(
        json!({
            "result": "refused",
            "reason": "fenced",
            "state": { "kind": "active", "epoch": 7, "holder": OTHER_HOLDER, "head": 3 },
        }),
        "",
        0,
    );
    let output = world.run();
    assert_eq!(
        output.status.code(),
        Some(OWNER_FENCED),
        "{}",
        stderr(&output)
    );
    let message = stderr(&output);
    assert!(
        message.contains(OTHER_HOLDER) && message.contains("epoch 7"),
        "{message}"
    );
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);
    assert_eq!(world.rex_calls(), None);
    assert_eq!(
        fs::read_to_string(world.state.join("coordinator-id")).unwrap(),
        COORDINATOR
    );
    let runs = world.helper_runs();
    assert_eq!(runs.len(), 1);
    let request: Value = serde_json::from_str(runs[0]["request"].as_str().unwrap()).unwrap();
    assert_eq!(request, json!({ "op": "claim", "state": world.state }));
    let session = session(&runs[0]["session"]);
    assert_eq!(session["url"], AUTHORITY);
    assert_eq!(session["coordinator_id"], COORDINATOR);
    assert_eq!(session["holder"], HOLDER);
    assert!(session.get("epoch").is_none_or(Value::is_null), "{session}");
}

#[test]
fn a_state_directory_without_a_log_position_names_enroll_and_join_before_sources_rex_pi_or_a_socket()
 {
    let world = World::new(Failover::Holder).with_coordinator_id();
    world.answer(json!({ "result": "unstamped" }), "", 0);
    let output = world.run();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(1), "{message}");
    assert!(
        message.contains("holds no replication position")
            && message.contains("`beep-boop failover enroll`")
            && message.contains("`beep-boop failover join`"),
        "{message}"
    );
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);
    assert_eq!(world.rex_calls(), None);
    assert_eq!(world.helper_runs().len(), 1);
}

#[test]
fn a_failover_coordinator_without_an_id_names_enroll_and_join_and_mints_nothing() {
    let world = World::new(Failover::Holder);
    world.answer(json!({ "result": "claimed", "epoch": 2, "head": 0 }), "", 0);
    let output = world.run();
    let message = stderr(&output);
    assert!(!output.status.success());
    assert_ne!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(
        message.contains("beep-boop failover enroll")
            && message.contains("beep-boop failover join"),
        "{message}"
    );
    assert!(!world.state.join("coordinator-id").exists());
    assert!(world.helper_runs().is_empty());
    assert_eq!(world.bridge(), None);
}

#[test]
fn a_host_that_only_watches_the_owner_record_cannot_serve() {
    let world = World::new(Failover::Watcher).with_coordinator_id();
    world.answer(json!({ "result": "claimed", "epoch": 2, "head": 0 }), "", 0);
    let output = world.run();
    let message = stderr(&output);
    assert!(!output.status.success());
    assert_ne!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(message.contains("not a coordinator"), "{message}");
    assert!(world.helper_runs().is_empty());
    assert_eq!(world.bridge(), None);
}

#[test]
fn an_accepted_claim_gives_pi_the_session_at_the_granted_epoch() {
    let world = World::new(Failover::Holder).with_coordinator_id();
    world.answer(json!({ "result": "claimed", "epoch": 8, "head": 3 }), "", 0);
    let supervisor = world.serve();
    let bridge = world.bridge().unwrap();
    let session = session(&bridge["failover"]);
    assert_eq!(
        session,
        json!({
            "url": AUTHORITY,
            "token_file": world.home.join("failover-token"),
            "coordinator_id": COORDINATOR,
            "holder": HOLDER,
            "epoch": 8,
        })
    );
    assert_eq!(world.helper_runs().len(), 1);
    drop(supervisor);
}

#[test]
fn a_pi_child_that_exits_75_ends_the_supervisor_with_75_and_removes_its_socket() {
    for (child, supervisor) in [(OWNER_FENCED, OWNER_FENCED), (3, 1)] {
        let world = World::new(Failover::Absent);
        let running = world.serve();
        fs::write(world.runtime.join("exit"), child.to_string()).unwrap();
        let output = running.finish();
        assert_eq!(
            output.status.code(),
            Some(supervisor),
            "child {child}: {}",
            stderr(&output)
        );
        assert!(!world.socket().exists(), "child {child}");
    }
}

const OPERATOR: &str = r#"
const { appendFileSync } = require("node:fs");
const { join } = require("node:path");
appendFileSync(join(__dirname, "operator-runs.ndjson"), process.argv[2] + "\n");
const request = JSON.parse(process.argv[2]);
const sealed = { kind: "sealed", epoch: 8, holder: "22222222-2222-4222-8222-222222222222",
  candidate: "33333333-3333-4333-8333-333333333333", head: 3 };
const report = request.op === "status"
  ? { result: "status", record: { state: sealed, checkpoint: { through: 0, manifest: "ab".repeat(32) } }, applied: null }
  : { result: "reply", reply: { result: "accepted", state: { kind: "vacant", epoch: 8, candidate: sealed.candidate,
      evidence: { kind: request.command.evidence }, head: 3 } } };
process.stdout.write(JSON.stringify(report) + "\n");
"#;

impl World {
    fn with_operator(self) -> Self {
        fs::write(self.runtime.join("failover/operator.js"), OPERATOR).unwrap();
        self
    }

    fn operator_runs(&self) -> Vec<Value> {
        fs::read_to_string(self.runtime.join("failover/operator-runs.ndjson"))
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

fn sealed(holder: &str) -> Value {
    json!({
        "result": "refused",
        "reason": "sealed",
        "state": { "kind": "sealed", "epoch": 8, "holder": holder, "candidate": OTHER_HOLDER, "head": 3 },
    })
}

#[test]
fn a_start_refused_as_the_sealed_holder_posts_lock_held_and_exits_75_whether_or_not_the_post_lands()
{
    let world = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    world.answer(sealed(HOLDER), "", 0);
    let output = world.run();
    assert_eq!(
        output.status.code(),
        Some(OWNER_FENCED),
        "{}",
        stderr(&output)
    );
    assert_eq!(
        world.operator_runs(),
        [json!({
            "op": "authority",
            "command": { "op": "release", "holder": HOLDER, "epoch": 8, "evidence": "lock_held" },
        })]
    );
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);

    let unbuilt = World::new(Failover::Holder).with_coordinator_id();
    unbuilt.answer(sealed(HOLDER), "", 0);
    let output = unbuilt.run();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(
        message.contains("beep-boop failover release"),
        "a failed post names the command that posts the same evidence: {message}"
    );
}

#[test]
fn a_start_refused_while_another_holder_is_sealed_posts_nothing() {
    let world = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    world.answer(sealed(OTHER_HOLDER), "", 0);
    let output = world.run();
    assert_eq!(
        output.status.code(),
        Some(OWNER_FENCED),
        "{}",
        stderr(&output)
    );
    assert!(world.operator_runs().is_empty());
}

#[test]
fn a_fenced_pi_child_posts_released_only_under_a_replicated_claim_and_a_failed_post_still_exits_75()
{
    let posted = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    posted.answer(json!({ "result": "claimed", "epoch": 8, "head": 3 }), "", 0);
    let running = posted.serve();
    fs::write(posted.runtime.join("exit"), OWNER_FENCED.to_string()).unwrap();
    let output = running.finish();
    assert_eq!(
        output.status.code(),
        Some(OWNER_FENCED),
        "{}",
        stderr(&output)
    );
    assert_eq!(
        posted.operator_runs(),
        [
            json!({ "op": "status", "state": null }),
            json!({
                "op": "authority",
                "command": { "op": "release", "holder": HOLDER, "epoch": 8, "evidence": "released" },
            }),
        ]
    );
    assert!(!posted.socket().exists());

    let unbuilt = World::new(Failover::Holder).with_coordinator_id();
    unbuilt.answer(json!({ "result": "claimed", "epoch": 8, "head": 3 }), "", 0);
    let running = unbuilt.serve();
    fs::write(unbuilt.runtime.join("exit"), OWNER_FENCED.to_string()).unwrap();
    let output = running.finish();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(message.contains("beep-boop failover release"), "{message}");

    let another_epoch = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    another_epoch.answer(json!({ "result": "claimed", "epoch": 9, "head": 3 }), "", 0);
    let running = another_epoch.serve();
    fs::write(another_epoch.runtime.join("exit"), OWNER_FENCED.to_string()).unwrap();
    let output = running.finish();
    assert_eq!(
        output.status.code(),
        Some(OWNER_FENCED),
        "{}",
        stderr(&output)
    );
    assert_eq!(
        another_epoch.operator_runs(),
        [json!({ "op": "status", "state": null })],
        "a log sealed at another epoch is not this claim's to release"
    );
}

#[test]
fn an_unreachable_authority_is_an_ordinary_failure_with_the_helper_error() {
    for (stdout, stderr_text, status) in [
        (
            Value::String(String::new()),
            "invented authority unreachable",
            69,
        ),
        (Value::String(String::new()), "invented helper failure", 1),
        (
            Value::String("not a report\n".into()),
            "invented garbled answer",
            0,
        ),
    ] {
        let world = World::new(Failover::Holder).with_coordinator_id();
        world.answer(stdout, stderr_text, status);
        let output = world.run();
        let message = stderr(&output);
        assert!(!output.status.success(), "{message}");
        assert_ne!(output.status.code(), Some(OWNER_FENCED), "{message}");
        assert!(message.contains(stderr_text), "{message}");
        assert!(!world.socket().exists());
        assert_eq!(world.bridge(), None);
        assert_eq!(world.rex_calls(), None);
    }
}

#[test]
fn a_second_coordinator_on_the_same_state_is_refused_by_the_lock_before_the_helper_runs() {
    let world = World::new(Failover::Holder).with_coordinator_id();
    world.answer(json!({ "result": "claimed", "epoch": 4, "head": 0 }), "", 0);
    let first = world.serve();
    assert_eq!(world.helper_runs().len(), 1);
    let second = world.run();
    let message = stderr(&second);
    assert!(!second.status.success());
    assert_ne!(second.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(message.contains("Another agent process owns"), "{message}");
    assert_eq!(world.helper_runs().len(), 1);
    drop(first);
}

#[test]
fn a_coordinator_without_failover_starts_while_a_process_of_an_earlier_run_holds_the_effects_lock()
{
    let world = World::new(Failover::Absent);
    let orphan = fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(world.state.join("effects.lock"))
        .unwrap();
    // An effect process that outlived its coordinator holds a share, as this file does.
    fs2::FileExt::try_lock_shared(&orphan).unwrap();
    let supervisor = world.serve_with(&[]);
    assert_eq!(world.bridge().unwrap(), json!({ "failover": null }));
    assert!(world.helper_runs().is_empty());
    drop(supervisor);
    drop(orphan);
}
