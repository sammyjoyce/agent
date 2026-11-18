use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Output, Stdio},
    thread,
    time::{Duration, Instant},
};

use agent_cli::serialized_spawn::SerializedSpawn;
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
input.on("close", () => { if (!existsSync(join(root, "outlive"))) process.exit(0); });
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
const { appendFileSync, existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
appendFileSync(join(__dirname, "runs.ndjson"),
  JSON.stringify({ request: process.argv[2], session: process.env.AGENT_FAILOVER ?? null }) + "\n");
function finish() {
  if (existsSync(join(__dirname, "unanswered"))) return setTimeout(finish, 20);
  const answer = JSON.parse(readFileSync(join(__dirname, "answer.json"), "utf8"));
  process.stdout.write(answer.stdout);
  process.stderr.write(answer.stderr);
  process.exitCode = answer.status;
}
finish();
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
    /// Whether the command runs in the state directory's parent and names the directory as
    /// `DASHED_STATE`.
    dashed: bool,
}

/// A valid directory name that reads as an option where a program parses options.
const DASHED_STATE: &str = "--state";

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
            dashed: false,
            _root: root,
        }
    }

    /// Renames the state directory to `DASHED_STATE`. The command then runs in the parent directory and
    /// names the state directory by that relative path, as an operator does who names it relative to
    /// where the service runs.
    fn with_dashed_relative_state(mut self) -> Self {
        let dashed = self.state.with_file_name(DASHED_STATE);
        fs::rename(&self.state, &dashed).unwrap();
        self.state = dashed;
        self.dashed = true;
        self
    }

    /// Makes the session database, stamped at `position` as `failover enroll`
    /// and `failover join` stamp it, or with no stamp.
    fn session_database(&self, position: Option<u64>) {
        let stamp = position.map_or(String::new(), |position| {
            format!(
                "database.exec('CREATE TABLE beep_boop_failover (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), position INTEGER NOT NULL); INSERT INTO beep_boop_failover VALUES (1, {position})');"
            )
        });
        let script = format!(
            "const database = new (require('node:sqlite').DatabaseSync)(process.argv[1]); database.exec('CREATE TABLE entries (id INTEGER PRIMARY KEY)'); {stamp} database.close();"
        );
        let made = Command::new("node")
            .args(["--no-warnings", "-e", &script])
            .arg(self.state.join("session.sqlite"))
            .output_serialized()
            .unwrap();
        assert!(made.status.success(), "{}", stderr(&made));
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
        if self.dashed {
            command
                .arg(format!("--state-dir={DASHED_STATE}"))
                .current_dir(self.state.parent().unwrap());
        } else {
            command.arg("--state-dir").arg(&self.state);
        }
        command
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
        let supervisor = Supervisor(Some(command.spawn_serialized().unwrap()));
        until("the coordinator socket", || self.socket().exists());
        supervisor
    }

    fn run(&self) -> Output {
        Supervisor(Some(self.command().spawn_serialized().unwrap())).finish()
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

    /// Ends the supervisor as a host that loses power does, with no cleanup.
    fn kill(mut self) {
        let mut child = self.0.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
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
fn a_start_without_failover_refuses_a_directory_that_holds_a_log_position_before_sources_rex_pi_or_a_socket()
 {
    let world = World::new(Failover::Absent).with_coordinator_id();
    world.session_database(Some(4));
    let output = world.run();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(1), "{message}");
    assert!(
        message.contains("is a replicated state directory")
            && message.contains("through position 4")
            && message.contains("[failover] section"),
        "{message}"
    );
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);
    assert_eq!(world.rex_calls(), None);
    assert!(world.helper_runs().is_empty());
}

#[test]
fn a_start_without_failover_serves_a_directory_named_by_a_relative_path_that_begins_with_dashes() {
    let world = World::new(Failover::Absent).with_dashed_relative_state();
    world.session_database(None);
    let supervisor = world.serve();
    assert_eq!(world.bridge().unwrap(), json!({ "failover": null }));
    drop(supervisor);
}

#[test]
fn a_start_without_failover_refuses_a_replicated_directory_named_by_a_relative_path_that_begins_with_dashes()
 {
    let world = World::new(Failover::Absent)
        .with_dashed_relative_state()
        .with_coordinator_id();
    world.session_database(Some(4));
    let output = world.run();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(1), "{message}");
    assert!(
        message.contains("is a replicated state directory")
            && message.contains("through position 4"),
        "{message}"
    );
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);
}

#[test]
fn a_start_without_failover_serves_a_directory_whose_database_holds_no_log_position() {
    let world = World::new(Failover::Absent);
    world.session_database(None);
    let supervisor = world.serve();
    assert_eq!(world.bridge().unwrap(), json!({ "failover": null }));
    assert!(world.helper_runs().is_empty());
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
const { existsSync } = require("node:fs");
const vacant = (kind) => ({ kind: "vacant", epoch: 8, candidate: sealed.candidate, evidence: { kind }, head: 3 });
const landed = existsSync(join(__dirname, "release-landed"));
const report = request.op === "status"
  ? { result: "status", record: { state: sealed, checkpoint: { through: 0, manifest: "ab".repeat(32) } }, applied: null }
  : { result: "reply", reply: landed ? { result: "refused", reason: "not_sealed", state: vacant("lock_held") }
      : { result: "accepted", state: vacant(request.command.evidence) } };
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
fn a_release_that_the_authority_refuses_because_an_earlier_one_landed_is_reported_as_posted() {
    let restarted = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    fs::write(restarted.runtime.join("failover/release-landed"), "").unwrap();
    restarted.answer(sealed(HOLDER), "", 0);
    let output = restarted.run();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(
        message.contains("Told the failover authority"),
        "the restarted sealed holder: {message}"
    );
    assert!(!message.contains("Could not tell"), "{message}");

    let fenced = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    fs::write(fenced.runtime.join("failover/release-landed"), "").unwrap();
    fenced.answer(json!({ "result": "claimed", "epoch": 8, "head": 3 }), "", 0);
    let running = fenced.serve();
    fs::write(fenced.runtime.join("exit"), OWNER_FENCED.to_string()).unwrap();
    let output = running.finish();
    let message = stderr(&output);
    assert_eq!(output.status.code(), Some(OWNER_FENCED), "{message}");
    assert!(
        message.contains("Told the failover authority"),
        "the fenced owner: {message}"
    );
    assert!(!message.contains("Could not tell"), "{message}");
}

#[test]
fn a_claim_refused_because_the_epoch_moved_is_an_ordinary_failure_that_asks_for_another_start() {
    let world = World::new(Failover::Holder)
        .with_coordinator_id()
        .with_operator();
    world.answer(
        json!({
            "result": "refused",
            "reason": "epoch_moved",
            "state": { "kind": "active", "epoch": 9, "holder": HOLDER, "head": 3 },
        }),
        "",
        0,
    );
    let output = world.run();
    let message = stderr(&output);
    assert!(!output.status.success(), "{message}");
    assert_ne!(
        output.status.code(),
        Some(OWNER_FENCED),
        "a service manager must start it again: {message}"
    );
    assert!(message.contains("Start the coordinator again"), "{message}");
    assert!(world.operator_runs().is_empty());
    assert!(!world.socket().exists());
    assert_eq!(world.bridge(), None);
}

#[test]
fn a_claim_helper_that_outlives_its_killed_coordinator_keeps_the_next_start_out_until_it_ends() {
    let world = World::new(Failover::Holder).with_coordinator_id();
    world.answer(json!({ "result": "claimed", "epoch": 4, "head": 0 }), "", 0);
    let unanswered = world.runtime.join("failover/unanswered");
    fs::write(&unanswered, "").unwrap();
    let killed = Supervisor(Some(world.command().spawn_serialized().unwrap()));
    until("the first start's claim helper", || {
        world.helper_runs().len() == 1
    });
    killed.kill();

    let excluded = world.run();
    let message = stderr(&excluded);
    assert!(!excluded.status.success(), "{message}");
    assert!(
        message.contains("Another agent process owns"),
        "the helper of the killed start still holds the writer lock: {message}"
    );
    assert_eq!(
        world.helper_runs().len(),
        1,
        "the excluded start asked the authority for nothing"
    );

    fs::remove_file(&unanswered).unwrap();
    let lock = fs::File::open(world.state.join("writer.lock")).unwrap();
    until("the orphaned helper to end", || {
        fs2::FileExt::try_lock_exclusive(&lock).is_ok()
    });
    drop(lock);
    let next = world.serve();
    assert_eq!(world.helper_runs().len(), 2);
    drop(next);
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
    fs2::FileExt::try_lock_shared(&orphan).unwrap();
    let supervisor = world.serve_with(&[]);
    assert_eq!(world.bridge().unwrap(), json!({ "failover": null }));
    assert!(world.helper_runs().is_empty());
    drop(supervisor);
    drop(orphan);
}

#[test]
fn a_process_that_the_supervisor_started_without_an_effect_record_holds_the_effects_lock_until_it_ends()
 {
    let world = World::new(Failover::Absent);
    fs::write(world.runtime.join("outlive"), "").unwrap();
    let supervisor = world.serve();
    until("the Pi child", || world.bridge().is_some());
    supervisor.kill();
    let lock = fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(world.state.join("effects.lock"))
        .unwrap();
    let held = fs2::FileExt::try_lock_exclusive(&lock).is_err();
    fs::write(world.runtime.join("exit"), "0").unwrap();
    assert!(
        held,
        "A process that outlived the supervisor must hold the share it inherited"
    );
    until("the Pi child to end", || {
        fs2::FileExt::try_lock_exclusive(&lock).is_ok()
    });
}
