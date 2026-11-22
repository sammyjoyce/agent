//! Opt-in MyChart notification intake via a configured read-only CLI.

use anyhow::{Result, ensure};
use serde::Deserialize;

use crate::{
    protocol::SourceRef,
    sources::{
        SourceEvent, SourceKey,
        cli_feed::{CliFeedSource, CliFeedSpec, stable_version_hash},
        parse_timestamp_ms,
    },
};

pub(crate) static SPEC: CliFeedSpec = CliFeedSpec {
    provider: "mychart",
    label: "MyChart",
    normalize: normalize_item,
};

pub fn new(command: Vec<String>, account: String) -> Result<CliFeedSource> {
    CliFeedSource::new(&SPEC, command, account)
}

#[derive(Deserialize)]
struct RawItem {
    id: String,
    title: String,
    occurred_at: String,
    #[serde(default)]
    thread_id: Option<String>,
    #[serde(default)]
    category: Option<String>,
    #[serde(default)]
    summary: Option<String>,
    #[serde(default)]
    body: Option<String>,
    #[serde(default)]
    sender: Option<String>,
    #[serde(default)]
    version: Option<String>,
}

fn normalize_item(key: &SourceKey, raw: serde_json::Value) -> Result<SourceEvent> {
    let item: RawItem = serde_json::from_value(raw)?;
    ensure!(!item.id.trim().is_empty(), "MyChart item requires an id");
    ensure!(
        !item.title.trim().is_empty(),
        "MyChart item requires a title"
    );
    let occurred_at = parse_timestamp_ms(&item.occurred_at);
    ensure!(
        occurred_at.is_some(),
        "MyChart item requires a valid occurred_at timestamp"
    );
    let thread_id = item
        .thread_id
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| item.id.clone());
    let body = item
        .body
        .or(item.summary)
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| item.title.clone());
    let mut lines = Vec::new();
    if let Some(category) = item.category.filter(|v| !v.is_empty()) {
        lines.push(format!("Category: {category}"));
    }
    if let Some(sender) = item.sender.filter(|v| !v.is_empty()) {
        lines.push(format!("From: {sender}"));
    }
    lines.push(body.clone());
    let version = item
        .version
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| stable_version_hash(&[&item.id, &item.title, &body]));
    Ok(SourceEvent {
        id: item.id,
        version,
        legacy_version: None,
        source: SourceRef {
            provider: key.provider.clone(),
            account: key.account.clone(),
            thread_id,
        },
        title: item.title,
        text: lines.join("\n"),
        occurred_at,
    })
}

#[cfg(test)]
mod tests {
    use crate::sources::{Source, SourceCoverage, cli_feed::write_test_helper, mychart};

    #[tokio::test]
    async fn polls_mychart_items_and_redacts_helper_failures() {
        let dir = tempfile::tempdir().unwrap();
        let command = write_test_helper(
            dir.path(),
            "mychart-cli.sh",
            r#"#!/bin/sh
if [ "$1" = "fail" ]; then
  printf '%s\n' '{"status":"error","failure":{"code":"authentication","phase":"authentication","message":"secret-patient-token"}}'
  exit 1
fi
if [ "$1" = "bad-item" ]; then
  printf '%s\n' '{"status":"ok","items":[{"id":"mc-101","title":"Lab panel available","occurred_at":"2026-11-22T03:00:00Z"},{"id":"","title":"Broken","occurred_at":"2026-11-22T03:01:00Z"}],"has_more":false}'
  exit 0
fi
printf '%s\n' '{"status":"ok","items":[{"id":"mc-101","thread_id":"thr-1","category":"test_result","title":"Lab panel available","sender":"Example Clinic","summary":"Comprehensive metabolic panel posted.","occurred_at":"2026-11-22T03:00:00Z"}],"has_more":false}'
"#,
        );

        let source = mychart::new(command.clone(), "clinic-example".into()).unwrap();
        let batch = source.poll(None).await.unwrap();
        assert_eq!(batch.coverage, SourceCoverage::Complete);
        assert!(batch.checkpoint.is_some());
        assert_eq!(batch.events.len(), 1);
        assert_eq!(batch.events[0].title, "Lab panel available");
        assert!(batch.events[0].text.contains("Example Clinic"));

        let mut bad_cmd = command.clone();
        bad_cmd.push("bad-item".into());
        let partial = mychart::new(bad_cmd, "clinic-example".into())
            .unwrap()
            .poll(None)
            .await
            .unwrap();
        assert!(matches!(partial.coverage, SourceCoverage::Partial { .. }));
        assert!(partial.checkpoint.is_none());
        assert_eq!(partial.events.len(), 1);

        let mut fail_cmd = command;
        fail_cmd.push("fail".into());
        let failed = mychart::new(fail_cmd, "clinic-example".into())
            .unwrap()
            .poll(None)
            .await
            .unwrap();
        let SourceCoverage::Unavailable { message } = failed.coverage else {
            panic!("Expected unavailable coverage on auth failure");
        };
        assert!(!message.contains("secret-patient-token"));
        assert!(failed.checkpoint.is_none());
    }
}
