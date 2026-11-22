//! Opt-in Home Assistant entity state-change intake via its REST `/api/states` endpoint.
//! Access tokens are retrieved on demand from the configured credential helper
//! and passed via curl stdin config (`-K -`) so secrets stay out of process args.

use std::collections::BTreeMap;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::{
    protocol::SourceRef,
    sources::{
        Source, SourceBatch, SourceCheckpoint, SourceCoverage, SourceEvent, SourceKey,
        parse_timestamp_ms, read_command, read_command_with_stdin,
    },
};

#[derive(Debug)]
pub struct HomeAssistantSource {
    account: String,
    base_url: String,
    credential_command: Vec<String>,
    entities: Vec<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
struct Checkpoint {
    account: String,
    #[serde(default)]
    states: BTreeMap<String, String>,
}

#[derive(Deserialize)]
struct HaState {
    entity_id: String,
    state: String,
    #[serde(default)]
    attributes: serde_json::Value,
    #[serde(default)]
    last_changed: Option<String>,
    #[serde(default)]
    last_updated: Option<String>,
}

impl HomeAssistantSource {
    pub fn new(
        account: String,
        url: String,
        credential_command: Vec<String>,
        entities: Vec<String>,
    ) -> Result<Self> {
        ensure!(
            !account.trim().is_empty() && !account.chars().any(char::is_control),
            "Home Assistant source needs an explicit account"
        );
        let trimmed_url = url.trim().trim_end_matches('/').to_owned();
        ensure!(
            (trimmed_url.starts_with("http://") || trimmed_url.starts_with("https://"))
                && !trimmed_url.chars().any(char::is_control)
                && !trimmed_url.chars().any(char::is_whitespace),
            "Home Assistant URL must be an http:// or https:// base URL"
        );
        ensure!(
            credential_command
                .first()
                .is_some_and(|program| !program.is_empty())
                && credential_command.iter().all(|part| !part.contains('\0')),
            "Home Assistant source needs a credential_command"
        );
        ensure!(
            !entities.is_empty()
                && entities
                    .iter()
                    .all(|pattern| !pattern.trim().is_empty()
                        && !pattern.chars().any(char::is_control)),
            "Home Assistant source requires a non-empty entities allowlist"
        );
        Ok(Self {
            account,
            base_url: trimmed_url,
            credential_command,
            entities,
        })
    }

    async fn read_token(&self) -> Result<String> {
        let output = read_command(&self.credential_command).await?;
        ensure!(
            output.exit_code == 0 && !output.truncated,
            "Home Assistant credential helper failed"
        );
        let token = output.stdout.trim().to_owned();
        ensure!(
            !token.is_empty()
                && !token.chars().any(char::is_control)
                && !token.contains('"')
                && !token.contains('\\'),
            "Home Assistant credential helper returned an unusable token"
        );
        Ok(token)
    }

    async fn get_json(&self, path: &str, token: &str) -> Result<(u16, String)> {
        let endpoint = format!("{}{}", self.base_url, path);
        let config_stdin = format!("header = \"Authorization: Bearer {token}\"\n");
        let argv = vec![
            "curl".into(),
            "-sS".into(),
            "-w".into(),
            "\n%{http_code}".into(),
            "--max-time".into(),
            "20".into(),
            "-K".into(),
            "-".into(),
            endpoint,
        ];
        let output = read_command_with_stdin(&argv, config_stdin.as_bytes()).await?;
        ensure!(
            output.exit_code == 0 && !output.truncated,
            "Home Assistant API request failed (exit {})",
            output.exit_code
        );
        let Some((body, code)) = output.stdout.rsplit_once('\n') else {
            bail!("Home Assistant HTTP response missing status code");
        };
        let status: u16 = code
            .trim()
            .parse()
            .context("Invalid HTTP status from Home Assistant")?;
        Ok((status, body.to_owned()))
    }

    fn matches_entity(&self, entity_id: &str) -> bool {
        self.entities.iter().any(|pattern| {
            if let Some(prefix) = pattern.strip_suffix('*') {
                entity_id.starts_with(prefix)
            } else {
                entity_id == pattern
            }
        })
    }

    fn diff_states(
        &self,
        states: Vec<HaState>,
        previous: &Checkpoint,
        initial: bool,
    ) -> (Vec<SourceEvent>, Checkpoint) {
        let mut next = Checkpoint {
            account: self.account.clone(),
            states: BTreeMap::new(),
        };
        let mut events = Vec::new();

        for item in states {
            if item.entity_id.is_empty() || !self.matches_entity(&item.entity_id) {
                continue;
            }
            let fingerprint = state_fingerprint(&item);
            let prior = previous.states.get(&item.entity_id);
            if prior.is_some_and(|prev| prev != &fingerprint) || (prior.is_none() && initial) {
                let friendly = item
                    .attributes
                    .get("friendly_name")
                    .and_then(|v| v.as_str())
                    .filter(|name| !name.is_empty())
                    .unwrap_or(&item.entity_id);
                let occurred_at = item
                    .last_changed
                    .as_deref()
                    .or(item.last_updated.as_deref())
                    .and_then(parse_timestamp_ms);
                let short_fp = fingerprint.get(..16).unwrap_or(&fingerprint);
                events.push(SourceEvent {
                    id: format!("state:{}:{short_fp}", item.entity_id),
                    version: fingerprint.clone(),
                    legacy_version: None,
                    source: SourceRef {
                        provider: "home_assistant".into(),
                        account: self.account.clone(),
                        thread_id: format!("entity:{}", item.entity_id),
                    },
                    title: format!("{friendly}: {}", item.state),
                    text: format!(
                        "Entity {} changed to '{}'{}.",
                        item.entity_id,
                        item.state,
                        prior
                            .map(|_| " (state transition)")
                            .unwrap_or(" (initial observation)")
                    ),
                    occurred_at,
                });
            }
            next.states.insert(item.entity_id, fingerprint);
        }

        (events, next)
    }
}

fn state_fingerprint(state: &HaState) -> String {
    let changed = state
        .last_changed
        .as_deref()
        .or(state.last_updated.as_deref())
        .unwrap_or_default();
    let mut hasher = Sha256::new();
    hasher.update(state.entity_id.as_bytes());
    hasher.update(b":");
    hasher.update(state.state.as_bytes());
    hasher.update(b":");
    hasher.update(changed.as_bytes());
    hex::encode(hasher.finalize())
}

#[async_trait::async_trait]
impl Source for HomeAssistantSource {
    fn key(&self) -> SourceKey {
        SourceKey {
            provider: "home_assistant".into(),
            account: self.account.clone(),
        }
    }

    async fn poll(&self, checkpoint: Option<&SourceCheckpoint>) -> Result<SourceBatch> {
        let key = self.key();
        let previous: Checkpoint = match checkpoint {
            Some(saved) => {
                serde_json::from_str(&saved.value).context("Invalid Home Assistant checkpoint")?
            }
            None => Checkpoint {
                account: self.account.clone(),
                ..Default::default()
            },
        };
        ensure!(
            previous.account == self.account,
            "Home Assistant checkpoint belongs to another account"
        );
        let token = match self.read_token().await {
            Ok(token) => token,
            Err(_) => {
                return Ok(SourceBatch::unavailable(
                    key,
                    "Home Assistant credentials are unavailable; check credential_command.",
                ));
            }
        };

        let (states_code, states_body) = match self.get_json("/api/states", &token).await {
            Ok(response) => response,
            Err(_) => {
                return Ok(SourceBatch::unavailable(
                    key,
                    "Home Assistant API is unreachable; checkpoint retained.",
                ));
            }
        };
        if !(200..300).contains(&states_code) {
            return Ok(SourceBatch::unavailable(
                key,
                format!("Home Assistant API returned HTTP {states_code}; checkpoint retained."),
            ));
        }
        let Ok(states) = serde_json::from_str::<Vec<HaState>>(&states_body) else {
            return Ok(SourceBatch::unavailable(
                key,
                "Home Assistant returned an invalid /api/states payload.",
            ));
        };

        let (events, next) = self.diff_states(states, &previous, checkpoint.is_none());
        let value = serde_json::to_string(&next)?;
        Ok(SourceBatch {
            source: key,
            events,
            checkpoint: Some(SourceCheckpoint { value }),
            coverage: SourceCoverage::Complete,
            progress: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    use super::*;
    use crate::sources::cli_feed::write_test_helper;

    #[test]
    fn rejects_empty_entities_allowlist() {
        let err = HomeAssistantSource::new(
            "home-example".into(),
            "http://127.0.0.1:8123".into(),
            vec!["true".into()],
            vec![],
        )
        .unwrap_err();
        assert!(err.to_string().contains("allowlist"));
    }

    #[tokio::test]
    async fn polls_state_changes_with_private_credential_command_and_fails_honestly_on_errors() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let step = Arc::new(AtomicUsize::new(0));
        let server_step = step.clone();
        let server = tokio::spawn(async move {
            loop {
                let Ok((mut socket, _)) = listener.accept().await else {
                    break;
                };
                let current_step = server_step.load(Ordering::Relaxed);
                tokio::spawn(async move {
                    let mut buf = [0_u8; 2048];
                    let n = socket.read(&mut buf).await.unwrap_or(0);
                    let request = String::from_utf8_lossy(&buf[..n]);
                    assert!(
                        request.contains("Authorization: Bearer ha-test-token-123"),
                        "Request must carry bearer token from credential helper: {request}"
                    );
                    let (status, body) = if request.starts_with("GET /api/states ") {
                        match current_step {
                            0 => (
                                "200 OK",
                                r#"[{"entity_id":"binary_sensor.leak","state":"off","attributes":{"friendly_name":"Kitchen Leak"},"last_changed":"2026-11-22T01:00:00Z"},{"entity_id":"sensor.ignored","state":"on"}]"#,
                            ),
                            1 => (
                                "200 OK",
                                r#"[{"entity_id":"binary_sensor.leak","state":"on","attributes":{"friendly_name":"Kitchen Leak"},"last_changed":"2026-11-22T02:00:00Z"}]"#,
                            ),
                            2 => ("500 Internal Server Error", "{}"),
                            _ => ("200 OK", "not-json"),
                        }
                    } else {
                        ("404 Not Found", "{}")
                    };
                    let response = format!(
                        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    );
                    let _ = socket.write_all(response.as_bytes()).await;
                });
            }
        });

        let dir = tempfile::tempdir().unwrap();
        let cred = write_test_helper(
            dir.path(),
            "cred.sh",
            "#!/bin/sh\nprintf '%s' 'ha-test-token-123'\n",
        );
        let source = HomeAssistantSource::new(
            "home-example".into(),
            format!("http://127.0.0.1:{port}"),
            cred,
            vec!["binary_sensor.leak".into()],
        )
        .unwrap();

        let first = source.poll(None).await.unwrap();
        assert_eq!(first.coverage, SourceCoverage::Complete);
        assert_eq!(first.events.len(), 1);
        assert_eq!(first.events[0].title, "Kitchen Leak: off");

        // No state change -> no duplicate events.
        let second = source.poll(first.checkpoint.as_ref()).await.unwrap();
        assert_eq!(second.coverage, SourceCoverage::Complete);
        assert!(second.events.is_empty());

        // State flips off -> on -> emits transition event.
        step.store(1, Ordering::Relaxed);
        let third = source.poll(second.checkpoint.as_ref()).await.unwrap();
        assert_eq!(third.coverage, SourceCoverage::Complete);
        assert_eq!(third.events.len(), 1);
        assert_eq!(third.events[0].title, "Kitchen Leak: on");

        // HTTP 500 -> Unavailable with checkpoint retained.
        step.store(2, Ordering::Relaxed);
        let http_err = source.poll(third.checkpoint.as_ref()).await.unwrap();
        assert!(matches!(
            http_err.coverage,
            SourceCoverage::Unavailable { .. }
        ));
        assert!(http_err.checkpoint.is_none());

        // Invalid JSON -> Unavailable with checkpoint retained.
        step.store(3, Ordering::Relaxed);
        let bad_json = source.poll(third.checkpoint.as_ref()).await.unwrap();
        assert!(matches!(
            bad_json.coverage,
            SourceCoverage::Unavailable { .. }
        ));
        assert!(bad_json.checkpoint.is_none());

        server.abort();
    }
}
