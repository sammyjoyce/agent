//! Shared sliding-window CLI feed polling for opt-in read-only source CLIs.

use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::sources::{
    ReadOutput, Source, SourceBatch, SourceCheckpoint, SourceCoverage, SourceEvent, SourceKey,
    now_seconds, read_command,
};

const INITIAL_LOOKBACK_SECONDS: u64 = 7 * 86_400;
const OVERLAP_SECONDS: u64 = 120;

#[derive(Clone, Copy)]
pub(crate) struct CliFeedSpec {
    pub provider: &'static str,
    pub label: &'static str,
    pub normalize: fn(&SourceKey, serde_json::Value) -> Result<SourceEvent>,
}

/// Reusable `Source` adapter for read-only sliding-window CLI feeds.
pub struct CliFeedSource {
    spec: &'static CliFeedSpec,
    account: String,
    command: Vec<String>,
}

impl std::fmt::Debug for CliFeedSource {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("CliFeedSource")
            .field("provider", &self.spec.provider)
            .field("account", &self.account)
            .field("command", &self.command)
            .finish()
    }
}

impl CliFeedSource {
    pub(crate) fn new(
        spec: &'static CliFeedSpec,
        command: Vec<String>,
        account: String,
    ) -> Result<Self> {
        validate_cli_feed(&command, &account, spec.label)?;
        Ok(Self {
            spec,
            account,
            command,
        })
    }
}

#[async_trait::async_trait]
impl Source for CliFeedSource {
    fn key(&self) -> SourceKey {
        SourceKey {
            provider: self.spec.provider.into(),
            account: self.account.clone(),
        }
    }

    async fn poll(&self, checkpoint: Option<&SourceCheckpoint>) -> Result<SourceBatch> {
        poll_cli_feed(
            &self.command,
            &self.account,
            *self.spec,
            checkpoint,
            self.spec.normalize,
        )
        .await
    }
}

#[derive(Debug, Deserialize, Serialize)]
pub(crate) struct CliWindow {
    pub account: String,
    pub since: u64,
    pub until: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CliEnvelope {
    status: String,
    items: Vec<serde_json::Value>,
    #[serde(default)]
    next_cursor: Option<String>,
    #[serde(default)]
    has_more: bool,
}

pub(crate) fn validate_cli_feed(command: &[String], account: &str, label: &str) -> Result<()> {
    ensure!(
        command.first().is_some_and(|program| !program.is_empty())
            && command.iter().all(|part| !part.contains('\0')),
        "{label} source needs a configured read-only helper command"
    );
    ensure!(
        !account.trim().is_empty() && !account.chars().any(char::is_control),
        "{label} source needs an explicit account"
    );
    Ok(())
}

pub(crate) fn stable_version_hash(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.len().to_be_bytes());
        hasher.update(part.as_bytes());
    }
    hex::encode(hasher.finalize())
}

pub(crate) async fn poll_cli_feed<F>(
    command: &[String],
    account: &str,
    spec: CliFeedSpec,
    checkpoint: Option<&SourceCheckpoint>,
    mut normalize: F,
) -> Result<SourceBatch>
where
    F: FnMut(&SourceKey, serde_json::Value) -> Result<SourceEvent>,
{
    let key = SourceKey {
        provider: spec.provider.into(),
        account: account.to_owned(),
    };
    let window = next_window(account, spec.label, checkpoint, now_seconds()?)?;
    let mut argv = command.to_vec();
    argv.extend([
        "--json".into(),
        "--account".into(),
        account.to_owned(),
        "--since".into(),
        window.since.to_string(),
        "--until".into(),
        window.until.to_string(),
    ]);
    if let Some(cursor) = &window.cursor {
        argv.extend(["--cursor".into(), cursor.clone()]);
    }
    Ok(match read_command(&argv).await {
        Ok(output) => normalize_cli_output(key, spec, output, window, &mut normalize),
        Err(_) => SourceBatch::unavailable(
            key,
            format!(
                "{} helper could not run; check the configured command and credentials.",
                spec.label
            ),
        ),
    })
}

fn next_window(
    account: &str,
    label: &str,
    checkpoint: Option<&SourceCheckpoint>,
    now: u64,
) -> Result<CliWindow> {
    let mut window = match checkpoint {
        Some(checkpoint) => serde_json::from_str(&checkpoint.value)
            .with_context(|| format!("Invalid {label} checkpoint"))?,
        None => CliWindow {
            account: account.to_owned(),
            since: now.saturating_sub(INITIAL_LOOKBACK_SECONDS),
            until: 0,
            cursor: None,
        },
    };
    ensure!(
        window.account == account,
        "{label} checkpoint belongs to another account"
    );
    if window.until == 0 {
        window.until = now.max(window.since);
    }
    Ok(window)
}

fn normalize_cli_output<F>(
    key: SourceKey,
    spec: CliFeedSpec,
    output: ReadOutput,
    mut window: CliWindow,
    normalize: &mut F,
) -> SourceBatch
where
    F: FnMut(&SourceKey, serde_json::Value) -> Result<SourceEvent>,
{
    let unavailable = || {
        SourceBatch::unavailable(
            key.clone(),
            format!(
                "{} coverage is unavailable; checkpoint retained.",
                spec.label
            ),
        )
    };
    output.normalize(|output| {
        if output.truncated {
            return SourceBatch::unavailable(
                key.clone(),
                format!(
                    "{} output exceeded the bounded capture limit; narrow its window and retry.",
                    spec.label
                ),
            );
        }
        if output.exit_code != 0 {
            return unavailable();
        }
        let Ok(envelope) = serde_json::from_str::<CliEnvelope>(&output.stdout) else {
            return unavailable();
        };
        if envelope.status != "ok" {
            return unavailable();
        }
        let mut events = Vec::with_capacity(envelope.items.len());
        let mut rejected = 0usize;
        for item in envelope.items {
            match normalize(&key, item) {
                Ok(event) => events.push(event),
                Err(_) => rejected += 1,
            }
        }
        if rejected > 0 {
            return SourceBatch {
                source: key.clone(),
                events,
                checkpoint: None,
                coverage: SourceCoverage::Partial {
                    message: format!(
                        "{} rejected {rejected} malformed item(s); checkpoint retained.",
                        spec.label
                    ),
                },
                progress: None,
            };
        }
        let mut batch = SourceBatch {
            source: key.clone(),
            events,
            checkpoint: None,
            coverage: SourceCoverage::Partial {
                message: format!(
                    "{} coverage is incomplete; checkpoint retained.",
                    spec.label
                ),
            },
            progress: None,
        };
        if envelope.has_more {
            let Some(next) = envelope.next_cursor.filter(|value| !value.is_empty()) else {
                return batch;
            };
            window.cursor = Some(next);
            batch.coverage = SourceCoverage::More;
        } else {
            window.since = window.until.saturating_sub(OVERLAP_SECONDS);
            window.until = 0;
            window.cursor = None;
            batch.coverage = SourceCoverage::Complete;
        }
        if let Ok(value) = serde_json::to_string(&window) {
            batch.checkpoint = Some(SourceCheckpoint { value });
        }
        batch
    })
}

#[cfg(test)]
pub(crate) fn write_test_helper(dir: &std::path::Path, name: &str, body: &str) -> Vec<String> {
    let script = dir.join(name);
    std::fs::write(&script, body).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    vec![script.to_string_lossy().into_owned()]
}
