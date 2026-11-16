#![allow(dead_code)]

use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::{Command, Output, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use agent_cli::{
    background::{JobExecutionState, JobRunReceipt, ScheduledJobStatus},
    protocol::{RuntimeEventKind, TaskRecord},
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

#[path = "coordinator.rs"]
mod coordinator_fixture;
use coordinator_fixture::Coordinator;
pub use coordinator_fixture::Server;
#[path = "executable.rs"]
mod executable_fixture;
use executable_fixture::write_executable;

pub const JOB_TIMEOUT: Duration = Duration::from_secs(90);
pub const DREAMS_TOOLS: [&str; 3] = ["dreams_abstain", "dreams_propose", "dreams_review"];
pub const DREAMS_KEY: &str = "DREAMS_NIGHT";
pub const NOTES_KEY: &str = "NOTES_JOB";
pub const MINUTE: u64 = 60 * 1000;
pub const HOUR: u64 = 60 * MINUTE;

pub const BROKEN_AGENTS: &str = "# Example guidance\n\nRun `make test-all` before finishing.\n";
pub const FIXED_AGENTS: &str = "# Example guidance\n\nRun `make test` before finishing.\n";
pub const MAKEFILE: &str = "test:\n\t@echo ok\n";
pub const DEFECT_SUMMARY: &str = "AGENTS.md says to run `make test-all`, but the Makefile only defines `test`. The command failed: No rule to make target 'test-all'.";
pub const RECEIPT_INJECTION: &str = "EXAMPLE-RECEIPT-INJECTION";
pub const SUMMARY_INJECTION: &str = "EXAMPLE-SUMMARY-INJECTION";

pub fn now_ms() -> u64 {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_millis(),
    )
    .unwrap()
}

pub fn heartbeat(timestamp_ms: u64) -> String {
    json!({ "timestamp_ms": timestamp_ms, "request_id": 0, "elapsed_ms": null, "event": "heartbeat" })
        .to_string()
}

pub fn heartbeats(from: u64, to: u64) -> Vec<String> {
    (from..=to)
        .step_by(usize::try_from(5 * MINUTE).unwrap())
        .map(heartbeat)
        .collect()
}

pub fn retention(expired_through_ms: Option<u64>, capacity_loss: Option<Value>) -> Value {
    json!({
        "version": 1,
        "policy": { "segment_bytes": 1024 * 1024, "horizon_ms": 48 * HOUR, "max_total_bytes": 128 * 1024 * 1024 },
        "prior_history_unknown": false,
        "expired_through_ms": expired_through_ms,
        "capacity_loss": capacity_loss,
    })
}

pub fn tool(name: &str, args: Value) -> Value {
    json!({ "tool": name, "args": args })
}

pub fn text(text: &str) -> Value {
    json!({ "text": text })
}

pub fn sha256(bytes: &[u8]) -> String {
    format!("sha256:{}", hex::encode(Sha256::digest(bytes)))
}

pub fn git(repository: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repository)
        .args(args)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_SYSTEM", "/dev/null")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout).unwrap()
}

#[derive(Debug, PartialEq, Eq)]
pub struct Target {
    pub head: String,
    pub status: String,
    pub agents: Vec<u8>,
}

pub struct Fixture {
    pub directory: tempfile::TempDir,
    pub config: PathBuf,
    pub state: PathBuf,
    pub jobs: PathBuf,
    pub bin: PathBuf,
    pub instructions: PathBuf,
    pub runtime: PathBuf,
    pub queue: PathBuf,
    pub repository: PathBuf,
    pub check: PathBuf,
    pub marker: PathBuf,
}

impl Fixture {
    pub fn new() -> Self {
        let fixture = Self::without_policy();
        fixture.write_policy(
            &fixture.repository,
            &["/bin/sh", fixture.check.to_str().unwrap()],
        );
        fixture
    }

    pub fn without_policy() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let root = directory.path().canonicalize().unwrap();
        let config = root.join("config.toml");
        let state = root.join("state");
        let jobs = root.join("jobs");
        let bin = root.join("bin");
        let checks = root.join("checks");
        let repository = root.join("guidance");
        let instructions = root.join("AGENTS.md");
        for path in [&state, &jobs, &bin, &checks, &repository] {
            fs::create_dir(path).unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
        }
        fs::write(&instructions, "Use only invented fixture data.\n").unwrap();
        write_executable(
            &bin.join("rex"),
            "#!/bin/sh\nfor argument do\n  if [ \"$argument\" = whoami ]; then\n    printf '%s\\n' '{\"host_id\":\"44444444-4444-4444-8444-444444444444\",\"instance_id\":\"66666666-6666-4666-8666-666666666666\",\"rex_version\":\"fixture\"}'\n    exit 0\n  fi\ndone\nexit 1\n",
        );
        write_executable(&bin.join("tailscale"), "#!/bin/sh\nexit 1\n");
        write_executable(
            &bin.join("switchboard"),
            "#!/bin/sh\nprintf '%s\\n' unexpected >> \"$AGENT_TEST_EXTERNAL_CALLS\"\nexit 1\n",
        );
        let check = checks.join("commands-exist.sh");
        fs::copy(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("examples/dreams/commands-exist.sh"),
            &check,
        )
        .unwrap();

        fs::write(repository.join("AGENTS.md"), BROKEN_AGENTS).unwrap();
        fs::write(repository.join("Makefile"), MAKEFILE).unwrap();
        git(&repository, &["init", "--quiet", "--initial-branch=main"]);
        git(&repository, &["config", "user.name", "Example"]);
        git(&repository, &["config", "user.email", "example@invalid"]);
        git(&repository, &["add", "AGENTS.md", "Makefile"]);
        git(
            &repository,
            &["commit", "--quiet", "-m", "Add example guidance"],
        );

        let native = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("runtime/dist/test/fixtures/coordinator-runtime.js");
        assert!(native.is_file(), "Build the runtime before this test");
        let queue = root.join("queue.json");
        fs::write(&queue, "{}").unwrap();
        let runtime = root.join("runtime.mjs");
        fs::write(
            &runtime,
            format!(
                "process.env.OPENAI_API_KEY='sk-synthetic-fixture';\nprocess.env.AGENT_TEST_MODEL_QUEUE={};\nawait import({});\n",
                serde_json::to_string(&queue).unwrap(),
                serde_json::to_string(&native).unwrap()
            ),
        )
        .unwrap();

        let fixture = Self {
            marker: root.join("marker"),
            directory,
            config,
            state,
            jobs,
            bin,
            instructions,
            runtime,
            queue,
            repository,
            check,
        };
        fixture.write_config(None);
        fixture.write_job(
            "dreams",
            &format!(
                "{DREAMS_KEY} Call dreams_review and read every page. Propose one supported change or abstain with the honest reason."
            ),
        );
        fixture.write_job(
            "notes",
            &format!("{NOTES_KEY} Report what the last build did."),
        );
        fixture
    }

    pub fn write_config(&self, dreams: Option<Value>) {
        let mut config = json!({ "job_directories": [self.jobs], "poll_interval_seconds": 60 });
        if let Some(dreams) = dreams {
            config["dreams"] = dreams;
        }
        fs::write(&self.config, toml::to_string(&config).unwrap()).unwrap();
    }

    pub fn shadow_program(&self, name: &str, script: &str) {
        write_executable(&self.bin.join(name), script);
    }

    pub fn write_policy(&self, repository: &Path, argv: &[&str]) {
        self.write_config(Some(json!({
            "repository": repository,
            "editable": ["AGENTS.md", "playbooks/*.md"],
            "window_hours": 24,
            "checks": [{ "name": "commands-exist", "argv": argv, "timeout_seconds": 30 }],
        })));
    }

    pub fn write_job(&self, id: &str, prompt: &str) {
        fs::write(
            self.jobs.join(format!("{id}.toml")),
            format!(
                "id = \"{id}\"\nprompt = {prompt:?}\nmodel = \"gpt-6.1-sol\"\nreasoning_effort = \"medium\"\ntimezone = \"UTC\"\n\n[[schedules]]\nid = \"nightly\"\nrecurrence = \"DTSTART:20990101T033000Z\\nRRULE:FREQ=DAILY;BYHOUR=3;BYMINUTE=30;BYSECOND=0\"\n"
            ),
        )
        .unwrap();
    }

    pub fn use_live_runtime(&self, requests: &Path) {
        let live = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("runtime/dist/test/fixtures/live-gateway-runtime.js");
        assert!(live.is_file(), "Build the runtime before this test");
        fs::write(
            &self.runtime,
            format!(
                "process.env.AGENT_TEST_REQUESTS={};\nawait import({});\n",
                serde_json::to_string(requests).unwrap(),
                serde_json::to_string(&live).unwrap()
            ),
        )
        .unwrap();
    }

    /// Seeds the receipts of a coordinator that then stopped cleanly.
    pub fn seed_receipts(&self, lines: &[String], retention: &Value) {
        let diagnostics = self.state.join("diagnostics");
        fs::create_dir(&diagnostics).unwrap();
        fs::set_permissions(&diagnostics, fs::Permissions::from_mode(0o700)).unwrap();
        let stopped = json!({ "timestamp_ms": now_ms(), "request_id": 0, "elapsed_ms": null, "event": "writer_stopped" });
        fs::write(
            diagnostics.join("runtime.jsonl"),
            format!("{}\n{stopped}\n", lines.join("\n")),
        )
        .unwrap();
        fs::write(
            diagnostics.join("retention.json"),
            serde_json::to_vec(retention).unwrap(),
        )
        .unwrap();
    }

    pub fn seed_witnessed_night(&self) {
        let now = now_ms();
        self.seed_receipts(
            &heartbeats(now - 25 * HOUR, now - MINUTE / 2),
            &retention(None, None),
        );
    }

    pub fn script(&self, key: &str, steps: Vec<Value>) {
        let mut queue: BTreeMap<String, Value> =
            serde_json::from_slice(&fs::read(&self.queue).unwrap()).unwrap();
        queue.insert(key.into(), Value::Array(steps));
        fs::write(&self.queue, serde_json::to_vec(&queue).unwrap()).unwrap();
    }

    fn coordinator(&self) -> Coordinator<'_> {
        Coordinator {
            directory: self.directory.path(),
            config: &self.config,
            state: &self.state,
            bin: &self.bin,
            instructions: &self.instructions,
            runtime: &self.runtime,
        }
    }

    pub fn command(&self, args: &[&str], json: bool) -> Command {
        let mut command = self.coordinator().command(args, json);
        // The developer's Git identity and settings must not decide a test.
        command.env("HOME", self.directory.path());
        command
    }

    pub fn cli(&self, args: &[&str], json: bool) -> Output {
        let mut child = self
            .command(args, json)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        while child.try_wait().unwrap().is_none() {
            if Instant::now() >= deadline {
                child.kill().unwrap();
                let output = child.wait_with_output().unwrap();
                panic!(
                    "Fixture command {args:?} timed out: {}",
                    String::from_utf8_lossy(&output.stderr)
                );
            }
            thread::sleep(Duration::from_millis(10));
        }
        child.wait_with_output().unwrap()
    }

    pub fn ok(&self, args: &[&str], json: bool) -> String {
        let output = self.cli(args, json);
        assert!(
            output.status.success(),
            "Fixture command {args:?} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8(output.stdout).unwrap()
    }

    pub fn refused(&self, args: &[&str]) -> String {
        let output = self.cli(args, false);
        assert!(
            !output.status.success(),
            "Fixture command {args:?} must be refused, but printed: {}",
            String::from_utf8_lossy(&output.stdout)
        );
        String::from_utf8(output.stderr).unwrap()
    }

    pub fn events(&self, args: &[&str]) -> Vec<RuntimeEventKind> {
        self.ok(args, true)
            .lines()
            .filter(|line| !line.is_empty())
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }

    pub fn start(&self) -> Server {
        self.ok(&["jobs", "check"], false);
        self.coordinator().start(
            || self.cli(&["jobs", "sync"], true).status.success(),
            "Fixture coordinator did not accept its job catalog",
        )
    }

    pub fn job(&self, id: &str) -> ScheduledJobStatus {
        self.events(&["jobs", "get", id])
            .into_iter()
            .find_map(|event| match event {
                RuntimeEventKind::ScheduledJob { job } => Some(job),
                _ => None,
            })
            .expect("Get must return the applied job definition")
    }

    pub fn run_job(&self, id: &str) -> (JobRunReceipt, ScheduledJobStatus) {
        self.try_run_job(id, JOB_TIMEOUT)
            .unwrap_or_else(|failure| panic!("{failure}"))
    }

    pub fn try_run_job(
        &self,
        id: &str,
        limit: Duration,
    ) -> Result<(JobRunReceipt, ScheduledJobStatus), String> {
        let run = self
            .events(&["jobs", "run", id])
            .into_iter()
            .find_map(|event| match event {
                RuntimeEventKind::JobRun { run } => Some(run),
                _ => None,
            })
            .expect("Manual run must return its durable admission receipt");
        let deadline = Instant::now() + limit;
        loop {
            let job = self.job(id);
            match job.last_run.as_ref().map(|last| &last.state) {
                Some(JobExecutionState::Completed) => return Ok((run, job)),
                Some(JobExecutionState::Failed { message }) => {
                    return Err(format!("Job {id} failed: {message}"));
                }
                Some(JobExecutionState::Blocked { message }) => {
                    return Err(format!("Job {id} is blocked: {message}"));
                }
                _ => {}
            }
            if Instant::now() >= deadline {
                return Err(format!(
                    "Job {id} did not finish: {:?}\n{}",
                    job.last_run,
                    self.coordinator().startup_diagnostics()
                ));
            }
            thread::sleep(Duration::from_millis(50));
        }
    }

    pub fn task(&self, id: &str) -> TaskRecord {
        self.events(&["tasks", "list"])
            .into_iter()
            .find_map(|event| match event {
                RuntimeEventKind::Tasks { tasks } => Some(tasks),
                _ => None,
            })
            .expect("Tasks must return the ordinary task inventory")
            .into_iter()
            .find(|task| task.id.to_string() == id)
            .expect("The job's task is retained")
    }

    pub fn summarized(&self, summary: &str) -> TaskRecord {
        self.script(NOTES_KEY, vec![text(summary)]);
        let (run, _) = self.run_job("notes");
        let id = run.task_id.to_string();
        let deadline = Instant::now() + Duration::from_secs(20);
        let mut task = self.task(&id);
        loop {
            thread::sleep(Duration::from_millis(300));
            let again = self.task(&id);
            if again.updated_at == task.updated_at && again.summary.trim() == summary.trim() {
                return again;
            }
            assert!(Instant::now() < deadline, "The notes task did not settle");
            task = again;
        }
    }

    pub fn requests(&self, key: &str) -> Vec<Value> {
        let mut recorded = self.queue.clone().into_os_string();
        recorded.push(".requests");
        fs::read_to_string(recorded)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .filter(|request| request["key"] == key)
            .map(|request| request["body"].clone())
            .collect()
    }

    pub fn tool_outputs(&self, key: &str) -> Vec<(String, String)> {
        let requests = self.requests(key);
        let input = requests
            .last()
            .and_then(|body| body["input"].as_array())
            .expect("The model received at least one request");
        let names: BTreeMap<&str, &str> = input
            .iter()
            .filter(|item| item["type"] == "function_call")
            .map(|item| {
                (
                    item["call_id"].as_str().unwrap(),
                    item["name"].as_str().unwrap(),
                )
            })
            .collect();
        input
            .iter()
            .filter(|item| item["type"] == "function_call_output")
            .map(|item| {
                let output = match &item["output"] {
                    Value::String(text) => text.clone(),
                    Value::Array(parts) => parts
                        .iter()
                        .filter_map(|part| part["text"].as_str())
                        .collect::<Vec<_>>()
                        .join("\n"),
                    other => other.to_string(),
                };
                (names[item["call_id"].as_str().unwrap()].to_owned(), output)
            })
            .collect()
    }

    pub fn output_of(&self, key: &str, name: &str, index: usize) -> String {
        self.tool_outputs(key)
            .into_iter()
            .filter(|(tool, _)| tool == name)
            .nth(index)
            .unwrap_or_else(|| panic!("The model saw no output for {name} call {index}"))
            .1
    }

    pub fn target(&self) -> Target {
        Target {
            head: git(&self.repository, &["rev-parse", "HEAD"]),
            status: git(&self.repository, &["status", "--porcelain"]),
            agents: fs::read(self.repository.join("AGENTS.md")).unwrap(),
        }
    }

    pub fn dreams_json(&self, args: &[&str]) -> Value {
        let mut full = vec!["dreams"];
        full.extend(args);
        serde_json::from_str(&self.ok(&full, true)).unwrap()
    }

    pub fn latest_run(&self) -> Value {
        self.dreams_json(&["list"])
            .as_array()
            .and_then(|runs| runs.first().cloned())
            .expect("Dreams list shows the night's run")
    }

    pub fn check_passes_in_target(&self) -> bool {
        Command::new("/bin/sh")
            .arg(&self.check)
            .current_dir(&self.repository)
            .stdout(Stdio::null())
            .status()
            .unwrap()
            .success()
    }
}

pub fn offered_tools(body: &Value) -> BTreeSet<String> {
    let later = body["input"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "additional_tools")
        .flat_map(|item| item["tools"].as_array().cloned().unwrap_or_default());
    body["tools"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .chain(later)
        .map(|tool| {
            tool["name"]
                .as_str()
                .or_else(|| tool["type"].as_str())
                .map_or_else(|| tool.to_string(), str::to_owned)
        })
        .collect()
}

pub fn tree_snapshot(root: &Path) -> BTreeMap<PathBuf, (u32, Vec<u8>)> {
    let mut snapshot = BTreeMap::new();
    let mut pending = vec![root.to_owned()];
    while let Some(path) = pending.pop() {
        let metadata = fs::symlink_metadata(&path).unwrap();
        let bytes = if metadata.file_type().is_symlink() {
            fs::read_link(&path)
                .unwrap()
                .as_os_str()
                .as_encoded_bytes()
                .to_vec()
        } else if metadata.is_file() {
            fs::read(&path).unwrap()
        } else {
            Vec::new()
        };
        snapshot.insert(
            path.strip_prefix(root).unwrap().to_owned(),
            (metadata.permissions().mode(), bytes),
        );
        if metadata.is_dir() {
            pending.extend(
                fs::read_dir(&path)
                    .unwrap()
                    .map(|entry| entry.unwrap().path()),
            );
        }
    }
    snapshot
}
