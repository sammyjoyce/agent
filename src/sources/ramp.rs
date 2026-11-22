//! Opt-in Ramp expense/reimbursement/approval intake via a configured read-only CLI.

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
    provider: "ramp",
    label: "Ramp",
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
    kind: Option<String>,
    #[serde(default)]
    amount: Option<String>,
    #[serde(default)]
    currency: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    memo: Option<String>,
    #[serde(default)]
    version: Option<String>,
}

fn normalize_item(key: &SourceKey, raw: serde_json::Value) -> Result<SourceEvent> {
    let item: RawItem = serde_json::from_value(raw)?;
    ensure!(!item.id.trim().is_empty(), "Ramp item requires an id");
    ensure!(!item.title.trim().is_empty(), "Ramp item requires a title");
    let occurred_at = parse_timestamp_ms(&item.occurred_at);
    ensure!(
        occurred_at.is_some(),
        "Ramp item requires a valid occurred_at timestamp"
    );

    let kind = item.kind.filter(|v| !v.is_empty());
    let amount = item.amount.filter(|v| !v.is_empty());
    let currency = item.currency.filter(|v| !v.is_empty());
    let status = item.status.filter(|v| !v.is_empty());

    let formatted_amount = match (amount.as_deref(), currency.as_deref()) {
        (Some(amount), Some(currency)) => Some(format!("{amount} {currency}")),
        (Some(amount), None) => Some(amount.to_owned()),
        (None, _) => None,
    };

    let mut title = item.title.clone();
    if let Some(amount_text) = &formatted_amount {
        title.push_str(&format!(" ({amount_text})"));
    }
    if let Some(status_text) = &status {
        title.push_str(&format!(" — {status_text}"));
    }

    let mut lines = Vec::new();
    if let Some(kind_text) = &kind {
        lines.push(format!("Type: {kind_text}"));
    }
    lines.push(format!("Subject: {}", item.title));
    if let Some(amount_text) = &formatted_amount {
        lines.push(format!("Amount: {amount_text}"));
    }
    if let Some(status_text) = &status {
        lines.push(format!("Status: {status_text}"));
    }
    if let Some(memo) = item.memo.filter(|v| !v.is_empty()) {
        lines.push(format!("Memo: {memo}"));
    }

    let version = item.version.filter(|v| !v.is_empty()).unwrap_or_else(|| {
        stable_version_hash(&[
            &item.id,
            kind.as_deref().unwrap_or_default(),
            formatted_amount.as_deref().unwrap_or_default(),
            status.as_deref().unwrap_or_default(),
        ])
    });

    Ok(SourceEvent {
        id: item.id.clone(),
        version,
        legacy_version: None,
        source: SourceRef {
            provider: key.provider.clone(),
            account: key.account.clone(),
            thread_id: format!("ramp:{}", item.id),
        },
        title,
        text: lines.join("\n"),
        occurred_at,
    })
}

#[cfg(test)]
mod tests {
    use crate::sources::{Source, SourceCoverage, cli_feed::write_test_helper, ramp};

    #[tokio::test]
    async fn polls_ramp_activity_across_paginated_cursors_without_inventing_missing_amounts() {
        let dir = tempfile::tempdir().unwrap();
        let command = write_test_helper(
            dir.path(),
            "ramp-cli.sh",
            r#"#!/bin/sh
if echo "$*" | grep -q -- "--cursor page2"; then
  printf '%s\n' '{"status":"ok","items":[{"id":"tx-2","kind":"approval","title":"Example Transit","status":"pending_approval","occurred_at":"2026-11-22T04:10:00Z"}],"has_more":false}'
else
  printf '%s\n' '{"status":"ok","items":[{"id":"tx-1","kind":"transaction","title":"Cloud Hosting","amount":"42.00","currency":"USD","status":"cleared","occurred_at":"2026-11-22T04:00:00Z"}],"next_cursor":"page2","has_more":true}'
fi
"#,
        );

        let source = ramp::new(command, "corp-example".into()).unwrap();
        let first = source.poll(None).await.unwrap();
        assert_eq!(first.coverage, SourceCoverage::More);
        assert_eq!(first.events.len(), 1);
        assert!(first.events[0].title.contains("Cloud Hosting (42.00 USD)"));

        let second = source.poll(first.checkpoint.as_ref()).await.unwrap();
        assert_eq!(second.coverage, SourceCoverage::Complete);
        assert_eq!(second.events.len(), 1);
        assert_eq!(second.events[0].title, "Example Transit — pending_approval");
        assert!(!second.events[0].text.contains("0.00"));
        assert!(!second.events[0].text.contains("USD"));
    }
}
