use std::{
    collections::BTreeMap,
    fs,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    process::{Child, Command},
    time::{sleep, timeout},
};

use crate::{
    DEADLINE,
    provider::{Provider, Request, ToolFixture},
    scenario::Turn,
};

/// Answers the coordinator's local-node discovery and the CLI's per-input
/// identity check without starting Node inside a timed interval.
const REX: &str = r#"#!/bin/sh
for argument in "$@"; do
  case $argument in
    whoami) printf '{"host_id":"11111111-1111-4111-8111-111111111111","instance_id":"33333333-3333-4333-8333-333333333333","rex_version":"synthetic"}'; exit 0 ;;
    hosts) printf '{"hosts":[]}'; exit 0 ;;
  esac
done
exit 1
"#;

const RECEIPTS: &[&str] = &[
    "input_received",
    "input_placed",
    "input_accepted",
    "first_activity",
    "host_call",
    "host_cancel_requested",
    "interrupt_received",
    "interrupted",
];

pub fn isolated(command: &mut Command, directory: &Path) -> Result<()> {
    let bin = directory.join("bin");
    if !bin.exists() {
        fs::create_dir(&bin)?;
        let paths = std::env::var_os("PATH").context("PATH is required")?;
        let node = std::env::split_paths(&paths)
            .map(|path| path.join("node"))
            .find(|path| path.is_file())
            .context("Node is required")?;
        std::os::unix::fs::symlink(fs::canonicalize(node)?, bin.join("node"))?;
        fs::write(bin.join("rex"), REX)?;
        fs::set_permissions(bin.join("rex"), fs::Permissions::from_mode(0o700))?;
    }
    command
        .env_clear()
        .env("PATH", bin)
        .env("HOME", directory)
        .env("XDG_CONFIG_HOME", directory.join("config"))
        .env("XDG_DATA_HOME", directory.join("data"))
        .env("TERM", "xterm-256color")
        .env("LANG", "C.UTF-8")
        .current_dir(directory)
        .kill_on_drop(true);
    Ok(())
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tokens {
    pub input: u64,
    pub output: u64,
    pub cache_read: u64,
    pub cache_write: u64,
    pub reasoning: Option<u64>,
    pub total: u64,
}

impl Tokens {
    fn add(self, other: Self) -> Self {
        Self {
            input: self.input + other.input,
            output: self.output + other.output,
            cache_read: self.cache_read + other.cache_read,
            cache_write: self.cache_write + other.cache_write,
            reasoning: match (self.reasoning, other.reasoning) {
                (None, None) => None,
                (left, right) => Some(left.unwrap_or(0) + right.unwrap_or(0)),
            },
            total: self.total + other.total,
        }
    }

    pub fn since(self, before: Self) -> Result<Self> {
        let delta = |after: u64, before: u64| {
            after
                .checked_sub(before)
                .context("Pi's token ledger decreased")
        };
        Ok(Self {
            input: delta(self.input, before.input)?,
            output: delta(self.output, before.output)?,
            cache_read: delta(self.cache_read, before.cache_read)?,
            cache_write: delta(self.cache_write, before.cache_write)?,
            reasoning: match (self.reasoning, before.reasoning) {
                (Some(after), before) => Some(delta(after, before.unwrap_or(0))?),
                (None, None) => None,
                (None, Some(_)) => bail!("Pi's reasoning token ledger disappeared"),
            },
            total: delta(self.total, before.total)?,
        })
    }
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum LedgerEvent {
    ConversationUsage {
        usage: LedgerUsage,
    },
    Done,
    Failure {
        message: String,
    },
    #[serde(other)]
    Other,
}

#[derive(Deserialize)]
struct LedgerUsage {
    models: Vec<LedgerBucket>,
}

#[derive(Deserialize)]
struct LedgerBucket {
    tokens: Tokens,
}

#[derive(Clone, Debug, Serialize)]
pub struct Receipt {
    pub epoch_ms: u64,
    pub event: String,
    pub input_id: Option<String>,
    pub command: Option<String>,
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum ReceiptKey {
    EarliestPerInput { event: String, input_id: String },
    OnePerMillisecond { event: String, epoch_ms: u64 },
}

#[derive(Deserialize)]
struct ReceiptRecord {
    timestamp_ms: u64,
    event: String,
    input_id: Option<String>,
    command: Option<String>,
    #[serde(default)]
    dropped_before: u64,
}

#[derive(Debug, Default)]
pub struct Receipts {
    pub kept: Vec<Receipt>,
    pub missing: u64,
}

pub struct Closed {
    pub requests: Vec<Request>,
    pub receipts: Receipts,
}

pub struct Coordinator {
    child: Child,
    directory: tempfile::TempDir,
    provider: Provider,
}

impl Coordinator {
    pub async fn start(
        binary: &Path,
        shim: &Path,
        runtime: &Path,
        snapshot: &Path,
        turns: &'static [Turn],
    ) -> Result<Self> {
        let directory = tempfile::tempdir()?;
        let path = directory.path();
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
        for entry in fs::read_dir(snapshot)? {
            let entry = entry?;
            if entry.file_type()?.is_file() {
                fs::copy(entry.path(), path.join(entry.file_name()))?;
            }
        }
        fs::write(path.join("config.toml"), "")?;
        fs::write(path.join("AGENTS.md"), "")?;
        let mut command = Command::new(binary);
        command
            .arg("--state-dir")
            .arg(path)
            .arg("--config")
            .arg(path.join("config.toml"))
            .arg("--instructions")
            .arg(path.join("AGENTS.md"))
            .arg("--runtime")
            .arg(shim)
            .arg("serve")
            .arg("--local-only")
            .arg("--no-sources")
            .arg("--coordinator-only")
            .stdout(Stdio::null())
            .stderr(fs::File::create(path.join("coordinator.stderr"))?);
        isolated(&mut command, path)?;
        let provider = Provider::start(
            turns,
            ToolFixture {
                node: fs::canonicalize(path.join("bin/node"))?,
                pid_file: path.join("tool.pid"),
            },
        )
        .await?;
        command
            .env("AGENT_PERFORMANCE_RUNTIME", runtime)
            .env("AGENT_PERFORMANCE_PROVIDER", &provider.base_url)
            .env("AGENT_PERFORMANCE_RUNTIME_PID", path.join("runtime.pid"));
        let child = command.spawn()?;
        let mut coordinator = Self {
            child,
            directory,
            provider,
        };
        timeout(DEADLINE, async {
            loop {
                if agent_cli::service::connect(coordinator.directory())
                    .await
                    .is_ok()
                    && coordinator.directory().join("runtime.pid").exists()
                {
                    return Ok::<_, anyhow::Error>(());
                }
                if let Some(status) = coordinator.child.try_wait()? {
                    bail!(
                        "Synthetic coordinator exited before binding: {status}; {}",
                        coordinator.stderr()
                    );
                }
                sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .context("Synthetic coordinator did not bind")??;
        ensure!(
            !coordinator.stderr().contains("Local Rex is unavailable"),
            "The synthetic coordinator has no local node: {}",
            coordinator.stderr()
        );
        Ok(coordinator)
    }

    pub fn directory(&self) -> &Path {
        self.directory.path()
    }

    fn stderr(&self) -> String {
        fs::read_to_string(self.directory().join("coordinator.stderr")).unwrap_or_default()
    }

    pub fn pid(&self) -> Result<i32> {
        Ok(i32::try_from(
            self.child.id().context("The coordinator has exited")?,
        )?)
    }

    pub fn runtime_pid(&self) -> Result<i32> {
        read_pid(&self.directory().join("runtime.pid"))
    }

    pub fn tool_pid_file(&self) -> PathBuf {
        self.directory().join("tool.pid")
    }

    pub fn requests(&self) -> Result<Vec<Request>> {
        self.provider.requests()
    }

    pub async fn ledger(&self, conversation: &str) -> Result<Tokens> {
        let stream = agent_cli::service::connect(self.directory()).await?;
        let (reader, mut writer) = stream.into_split();
        let command =
            serde_json::json!({ "type": "conversation_usage", "conversation_id": conversation });
        writer.write_all(format!("{command}\n").as_bytes()).await?;
        let mut lines = BufReader::new(reader).lines();
        let mut tokens = None;
        timeout(DEADLINE, async {
            while let Some(line) = lines.next_line().await? {
                match serde_json::from_str(&line)? {
                    LedgerEvent::ConversationUsage { usage } => {
                        tokens = Some(
                            usage
                                .models
                                .into_iter()
                                .fold(Tokens::default(), |sum, bucket| sum.add(bucket.tokens)),
                        );
                    }
                    LedgerEvent::Done => return Ok(()),
                    LedgerEvent::Failure { message } => bail!("Usage request failed: {message}"),
                    LedgerEvent::Other => {}
                }
            }
            bail!("The coordinator closed the usage request")
        })
        .await
        .context("The usage request did not finish")??;
        tokens.context("The coordinator returned no usage")
    }

    pub async fn close(mut self) -> Result<Closed> {
        if let Some(pid) = self.child.id() {
            // Only this fixture-owned coordinator is signaled and reaped.
            ensure!(unsafe { libc::kill(i32::try_from(pid)?, libc::SIGTERM) } == 0);
        }
        let status = timeout(DEADLINE, self.child.wait())
            .await
            .context("Synthetic coordinator did not shut down")??;
        let Self {
            directory,
            provider,
            ..
        } = self;
        let requests = provider.close()?;
        let stderr = fs::read_to_string(directory.path().join("coordinator.stderr"))?;
        ensure!(status.success(), "Synthetic coordinator failed: {stderr}");
        Ok(Closed {
            requests,
            receipts: receipts(&directory.path().join("diagnostics"))?,
        })
    }
}

pub fn read_pid(path: &Path) -> Result<i32> {
    Ok(fs::read_to_string(path)
        .with_context(|| format!("Could not read {}", path.display()))?
        .trim()
        .parse()?)
}

fn receipts(directory: &Path) -> Result<Receipts> {
    let mut receipts = Receipts::default();
    let Ok(entries) = fs::read_dir(directory) else {
        return Ok(receipts);
    };
    let mut earliest: BTreeMap<ReceiptKey, Receipt> = BTreeMap::new();
    for entry in entries {
        let path = entry?.path();
        if !path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("runtime.jsonl"))
        {
            continue;
        }
        for line in fs::read_to_string(path)?.lines() {
            let Ok(record) = serde_json::from_str::<ReceiptRecord>(line) else {
                receipts.missing += 1;
                continue;
            };
            receipts.missing += record.dropped_before;
            if !RECEIPTS.contains(&record.event.as_str())
                || (record.event == "host_call" && record.command.as_deref() != Some("exec"))
            {
                continue;
            }
            let key = match &record.input_id {
                Some(input_id) => ReceiptKey::EarliestPerInput {
                    event: record.event.clone(),
                    input_id: input_id.clone(),
                },
                None => ReceiptKey::OnePerMillisecond {
                    event: record.event.clone(),
                    epoch_ms: record.timestamp_ms,
                },
            };
            let receipt = Receipt {
                epoch_ms: record.timestamp_ms,
                event: record.event,
                input_id: record.input_id,
                command: record.command,
            };
            earliest
                .entry(key)
                .and_modify(|kept| {
                    if receipt.epoch_ms < kept.epoch_ms {
                        *kept = receipt.clone();
                    }
                })
                .or_insert(receipt);
        }
    }
    receipts.kept = earliest.into_values().collect();
    receipts.kept.sort_by_key(|receipt| receipt.epoch_ms);
    Ok(receipts)
}
