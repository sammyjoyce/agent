//! Pure: one native ChatGPT conversation becomes a placed tree of inert history items.

use std::collections::BTreeSet;

use serde_json::Value;

use crate::{history::HistoryThread, protocol::HistoryRole};

const DEFAULT_TITLE: &str = "ChatGPT conversation";

/// "file_<hex>" or "file-<base62>": the export's name for an uploaded or generated file.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub(super) struct FileId(String);

impl FileId {
    /// Finds the id in a pointer (`sediment://file_…`, `file-service://file-…`), an
    /// attachment id, or a stored member name (`file_…-photo.dat`).
    pub fn find(text: &str) -> Option<Self> {
        let rest = text.rsplit("://").next().unwrap_or(text);
        ["file_", "file-"].into_iter().find_map(|prefix| {
            let tail = rest.strip_prefix(prefix)?;
            let run: String = tail
                .chars()
                .take_while(char::is_ascii_alphanumeric)
                .collect();
            (!run.is_empty()).then(|| Self(format!("{prefix}{run}")))
        })
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// What one native message becomes.
pub(super) enum Disposition {
    /// Never stored, rendered or indexed. Counted in the summary.
    Excluded,
    /// Structural or empty: no item, but the node keeps its place in the tree.
    Skipped,
    Emit {
        kind: String,
        role: HistoryRole,
    },
}

const INSTRUCTION_CONTENT: [&str; 4] = [
    "user_editable_context",
    "model_editable_context",
    "about_user_message",
    "about_model_message",
];

/// The classification table. Rows are checked in order; the first that matches decides.
///
/// | native message                                                     | becomes              |
/// |--------------------------------------------------------------------|----------------------|
/// | author `system` or `developer`                                     | Excluded             |
/// | custom-instruction content, or `metadata.is_user_system_message`   | Excluded             |
/// | `metadata.is_visually_hidden_from_conversation`                    | Excluded             |
/// | no text, code, asset pointer or attachment                         | Skipped              |
/// | author `user`                                                      | User                 |
/// | author `assistant` with a recipient other than `all`               | Tool                 |
/// | assistant `thoughts`, `reasoning_recap`, or a thinking preamble    | Thinking             |
/// | assistant on channel `commentary` / `final`                        | Commentary / Final   |
/// | any other assistant message                                        | Assistant            |
/// | any other author (`tool` and unknown roles)                        | Tool                 |
///
/// The kind is always `"{author role}:{content type}"`, with `text` as the default type.
pub(super) fn classify(message: &Value) -> Disposition {
    let author = message
        .pointer("/author/role")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let content_type = content_type(message);
    let flag = |name: &str| {
        message
            .pointer(&format!("/metadata/{name}"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
    };
    let instruction_part = message
        .pointer("/content/parts")
        .and_then(Value::as_array)
        .is_some_and(|parts| {
            parts.iter().any(|part| {
                part.get("content_type")
                    .and_then(Value::as_str)
                    .is_some_and(|kind| INSTRUCTION_CONTENT.contains(&kind))
            })
        });
    if matches!(author, "system" | "developer")
        || INSTRUCTION_CONTENT.contains(&content_type)
        || instruction_part
        || flag("is_user_system_message")
        || flag("is_visually_hidden_from_conversation")
    {
        return Disposition::Excluded;
    }
    if visible_text(message).trim().is_empty() && references(message, &[]).is_empty() {
        return Disposition::Skipped;
    }
    let recipient = message
        .get("recipient")
        .and_then(Value::as_str)
        .unwrap_or("all");
    let channel = message.get("channel").and_then(Value::as_str);
    let role = match author {
        "user" => HistoryRole::User,
        "assistant" if recipient != "all" => HistoryRole::Tool,
        "assistant"
            if matches!(content_type, "thoughts" | "reasoning_recap")
                || flag("is_thinking_preamble_message") =>
        {
            HistoryRole::Thinking
        }
        "assistant" if channel == Some("commentary") => HistoryRole::Commentary,
        "assistant" if channel == Some("final") => HistoryRole::Final,
        "assistant" => HistoryRole::Assistant,
        _ => HistoryRole::Tool,
    };
    Disposition::Emit {
        kind: format!("{author}:{content_type}"),
        role,
    }
}

fn content_type(message: &Value) -> &str {
    message
        .pointer("/content/content_type")
        .and_then(Value::as_str)
        .unwrap_or("text")
}

/// The text a person saw for this message, before excerpting.
pub(super) fn visible_text(message: &Value) -> String {
    if let Some(markdown) = message
        .pointer("/metadata/model_dil_v2/fallbackMarkdown")
        .and_then(Value::as_str)
    {
        return markdown.replace("<escape>", "").replace("</escape>", "");
    }
    let content = message.get("content").unwrap_or(&Value::Null);
    let mut pieces: Vec<&str> = Vec::new();
    if let Some(parts) = content.get("parts").and_then(Value::as_array) {
        for part in parts {
            match part {
                Value::String(text) => pieces.push(text),
                Value::Object(object) => {
                    if let Some(text) = object.get("text").and_then(Value::as_str) {
                        pieces.push(text);
                    }
                }
                _ => {}
            }
        }
    }
    if let Some(thoughts) = content.get("thoughts").and_then(Value::as_array) {
        for thought in thoughts {
            for field in ["summary", "content"] {
                if let Some(text) = thought.get(field).and_then(Value::as_str) {
                    pieces.push(text);
                }
            }
        }
    }
    for field in ["text", "content", "result"] {
        if let Some(text) = content.get(field).and_then(Value::as_str) {
            pieces.push(text);
        }
    }
    pieces
        .into_iter()
        .filter(|piece| !piece.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// A file one message points at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct FileRef {
    pub file: FileId,
    pub name: Option<String>,
    pub mime_type: Option<String>,
}

/// One live entry of the export's file library.
#[derive(Clone, Debug)]
pub(super) struct LibraryFile {
    pub file: FileId,
    pub name: Option<String>,
    pub mime_type: Option<String>,
    pub origination_message: Option<String>,
    pub created_at: Option<f64>,
    /// The entry as exported, kept as evidence on the item that shows it.
    pub raw: Value,
}

/// Every file a message references: attachment metadata, asset pointers (including voice
/// wrappers), code-interpreter chart images, and library entries that name this message as
/// their origin. One ref per file id, in that order.
pub(super) fn references(message: &Value, library: &[&LibraryFile]) -> Vec<FileRef> {
    let mut found: Vec<FileRef> = Vec::new();
    let mut add = |file: Option<FileId>, name: Option<&str>, mime_type: Option<&str>| {
        let Some(file) = file else { return };
        if let Some(existing) = found.iter_mut().find(|known| known.file == file) {
            existing.name = existing.name.take().or(name.map(str::to_owned));
            existing.mime_type = existing.mime_type.take().or(mime_type.map(str::to_owned));
            return;
        }
        found.push(FileRef {
            file,
            name: name.map(str::to_owned),
            mime_type: mime_type.map(str::to_owned),
        });
    };
    let text = |value: &Value, key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    if let Some(attachments) = message
        .pointer("/metadata/attachments")
        .and_then(Value::as_array)
    {
        for attachment in attachments {
            add(
                text(attachment, "id").as_deref().and_then(FileId::find),
                text(attachment, "name").as_deref(),
                text(attachment, "mime_type").as_deref(),
            );
        }
    }
    if let Some(parts) = message.pointer("/content/parts").and_then(Value::as_array) {
        let mut pointers = Vec::new();
        for part in parts {
            asset_pointers(part, 0, &mut pointers);
        }
        for pointer in pointers {
            add(FileId::find(&pointer), None, None);
        }
    }
    if let Some(messages) = message
        .pointer("/metadata/aggregate_result/messages")
        .and_then(Value::as_array)
    {
        for output in messages {
            add(
                text(output, "image_url").as_deref().and_then(FileId::find),
                None,
                None,
            );
        }
    }
    let node = message.get("id").and_then(Value::as_str);
    for entry in library {
        if node.is_some() && entry.origination_message.as_deref() == node {
            add(
                Some(entry.file.clone()),
                entry.name.as_deref(),
                entry.mime_type.as_deref(),
            );
        }
    }
    found
}

fn asset_pointers(value: &Value, depth: usize, found: &mut Vec<String>) {
    if depth > 4 {
        return;
    }
    if let Value::Object(object) = value {
        if let Some(pointer) = object.get("asset_pointer").and_then(Value::as_str) {
            found.push(pointer.to_owned());
        }
        for nested in object.values() {
            asset_pointers(nested, depth + 1, found);
        }
    }
}

/// What the package check counts for one conversation.
pub(super) struct Survey {
    pub excluded: u32,
    pub files: BTreeSet<FileId>,
}

pub(super) fn survey(raw: &Value) -> Survey {
    let mut survey = Survey {
        excluded: 0,
        files: BTreeSet::new(),
    };
    let Some(mapping) = raw.get("mapping").and_then(Value::as_object) else {
        return survey;
    };
    for node in mapping.values() {
        let Some(message) = node.get("message").filter(|message| message.is_object()) else {
            continue;
        };
        match classify(message) {
            Disposition::Excluded => survey.excluded += 1,
            Disposition::Skipped => {}
            Disposition::Emit { .. } => survey.files.extend(
                references(message, &[])
                    .into_iter()
                    .map(|reference| reference.file),
            ),
        }
    }
    survey
}

/// Seconds since the epoch from float seconds, integer milliseconds or an ISO string.
pub(super) fn seconds(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => {
            let value = number.as_f64()?;
            Some(if value > 1e12 { value / 1000.0 } else { value })
        }
        Value::String(text) => chrono::DateTime::parse_from_rfc3339(text)
            .ok()
            .map(|time| time.timestamp_millis() as f64 / 1000.0),
        _ => None,
    }
    .filter(|seconds| seconds.is_finite() && *seconds >= 0.0)
}

/// The thread List returns. `updated_at` falls back to the newest message, then creation.
/// `version` is filled by the package once the conversation's library entries are known.
pub(super) fn thread(id: &str, raw: &Value, version: String) -> HistoryThread {
    let created = raw.get("create_time").and_then(seconds);
    let newest_message = raw
        .get("mapping")
        .and_then(Value::as_object)
        .into_iter()
        .flat_map(|mapping| mapping.values())
        .filter_map(|node| node.pointer("/message/create_time").and_then(seconds))
        .fold(None, |newest: Option<f64>, time| {
            Some(newest.map_or(time, |newest| newest.max(time)))
        });
    let updated = raw
        .get("update_time")
        .and_then(seconds)
        .or(newest_message)
        .or(created);
    let title: String = raw
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .split_whitespace()
        .flat_map(|word| word.chars().chain(std::iter::once(' ')))
        .take(128)
        .collect();
    let title = match title.trim_end() {
        "" => DEFAULT_TITLE.to_owned(),
        title => title.to_owned(),
    };
    HistoryThread {
        id: id.to_owned(),
        title,
        cwd: String::new(),
        created_at: created.map_or(0, |time| time as i64),
        updated_at: updated.map_or(0, |time| time as i64),
        forked_from_id: None,
        parent_thread_id: None,
        version,
        version_reliable: true,
        archived: raw
            .get("is_archived")
            .and_then(Value::as_bool)
            .unwrap_or(false),
    }
}
