use std::{fmt, marker::PhantomData};

use serde::{
    Deserialize, Deserializer,
    de::{IgnoredAny, MapAccess, Visitor, value::MapAccessDeserializer},
};
use serde_json::Value;

use super::{
    ChatGptAuthor, ChatGptMessage, archive,
    conversation::{FileId, FileRef, Time, add},
};
use crate::protocol::HistoryRole;

const NAME_CHARACTERS: usize = 64;
const KIND_PART_CHARACTERS: usize = 64;
const INSTRUCTION_CONTENT: [&str; 4] = [
    "user_editable_context",
    "model_editable_context",
    "about_user_message",
    "about_model_message",
];

pub(super) struct Reading {
    pub message_or_node_id: String,
    pub created: Option<f64>,
    pub disposition: Disposition,
    pub left_out: Vec<LeftOut>,
}

pub(super) enum Disposition {
    Excluded,
    Unsupported,
    Kept(Box<Kept>),
}

pub(super) struct Kept {
    pub header: ChatGptMessage,
    pub role: HistoryRole,
    pub kind: String,
    contributions: Vec<Contribution>,
    attachments: Vec<FileRef>,
    outputs: Vec<AggregateOutput>,
    fallback: Option<String>,
}

struct Contribution {
    text: Option<String>,
    file: Option<FileId>,
}

enum AggregateOutput {
    Excluded {
        id: Option<String>,
    },
    Kept {
        id: Option<String>,
        file: Option<FileId>,
    },
}

#[derive(Clone, Copy)]
pub(super) enum Origin {
    Kept,
    Excluded,
}

pub(super) enum LeftOut {
    Message(String),
    Part(String),
    HiddenPart(String),
    Output(String),
    HiddenAttachment,
    UnreadableAttachment,
    UnreadableAttachments,
    UnreadableOutputs,
    UnreadableFallback,
    MessageShapedMetadata,
}

impl LeftOut {
    pub fn label(&self) -> String {
        match self {
            Self::Message(kind) => format!("message {kind}"),
            Self::Part(kind) => format!("part {kind}"),
            Self::HiddenPart(kind) => format!("part {kind} (hidden)"),
            Self::Output(kind) => format!("output {kind}"),
            Self::HiddenAttachment => "attachment (hidden)".into(),
            Self::UnreadableAttachment => "attachment (unreadable)".into(),
            Self::UnreadableAttachments => "attachments (unreadable)".into(),
            Self::UnreadableOutputs => "metadata aggregate_result (unreadable)".into(),
            Self::UnreadableFallback => "metadata model_dil_v2 (unreadable)".into(),
            Self::MessageShapedMetadata => "metadata (message-shaped)".into(),
        }
    }

    pub fn gap(&self, message: &str) -> String {
        let message = archive::shown(message);
        match self {
            Self::Message(kind) => {
                format!(
                    "Message {message} has content type {kind}, which this import does not read"
                )
            }
            Self::Part(kind) => format!(
                "A part of message {message} has type {kind}, which this import does not read"
            ),
            Self::HiddenPart(_) => {
                format!("A part of message {message} is marked hidden and was left out")
            }
            Self::Output(kind) => format!(
                "An output of message {message} has type {kind}, which this import does not read"
            ),
            Self::HiddenAttachment => {
                format!("An attachment of message {message} is marked hidden and was left out")
            }
            Self::UnreadableAttachment => {
                format!("An attachment of message {message} cannot be read and was left out")
            }
            Self::UnreadableAttachments => {
                format!("The attachments of message {message} cannot be read and were left out")
            }
            Self::UnreadableOutputs => {
                format!("The code outputs of message {message} cannot be read and were left out")
            }
            Self::UnreadableFallback => {
                format!("The fallback text of message {message} cannot be read and was left out")
            }
            Self::MessageShapedMetadata => format!(
                "The metadata of message {message} is shaped like a message and was not read"
            ),
        }
    }
}

impl Reading {
    pub fn kept(&self) -> Option<&Kept> {
        match &self.disposition {
            Disposition::Kept(kept) => Some(kept.as_ref()),
            Disposition::Excluded | Disposition::Unsupported => None,
        }
    }

    pub fn library_origins(&self) -> impl Iterator<Item = (&str, Origin)> {
        let (own, outputs) = match &self.disposition {
            Disposition::Excluded => (Some(Origin::Excluded), &[][..]),
            Disposition::Unsupported => (None, &[][..]),
            Disposition::Kept(kept) => (Some(Origin::Kept), kept.outputs.as_slice()),
        };
        own.map(|origin| (self.message_or_node_id.as_str(), origin))
            .into_iter()
            .chain(outputs.iter().filter_map(|output| match output {
                AggregateOutput::Excluded { id } => Some((id.as_deref()?, Origin::Excluded)),
                AggregateOutput::Kept { id, .. } => Some((id.as_deref()?, Origin::Kept)),
            }))
    }

    pub fn excluded(&self) -> u32 {
        match &self.disposition {
            Disposition::Excluded => 1,
            Disposition::Unsupported => 0,
            Disposition::Kept(kept) => kept
                .outputs
                .iter()
                .filter(|output| matches!(output, AggregateOutput::Excluded { .. }))
                .count() as u32,
        }
    }
}

impl Kept {
    pub fn text(&self) -> String {
        if let Some(markdown) = &self.fallback {
            return markdown.replace("<escape>", "").replace("</escape>", "");
        }
        self.contributions
            .iter()
            .filter_map(|contribution| contribution.text.as_deref())
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    pub fn files(&self) -> Vec<FileRef> {
        let bare = |file: &FileId| FileRef {
            file: file.clone(),
            name: None,
            mime_type: None,
        };
        let parts = self
            .contributions
            .iter()
            .filter_map(|contribution| contribution.file.as_ref().map(bare));
        let outputs = self.outputs.iter().filter_map(|output| match output {
            AggregateOutput::Kept {
                file: Some(file), ..
            } => Some(bare(file)),
            AggregateOutput::Kept { file: None, .. } | AggregateOutput::Excluded { .. } => None,
        });
        let mut found = Vec::new();
        for reference in parts.chain(self.attachments.iter().cloned()).chain(outputs) {
            add(&mut found, reference);
        }
        found
    }

    pub fn is_empty(&self) -> bool {
        self.text().trim().is_empty() && self.files().is_empty()
    }
}

pub(super) fn read(node: &str, message: &Value) -> Reading {
    let Ok(Record(head)) = Record::<Head>::deserialize(message) else {
        return Reading {
            message_or_node_id: node.to_owned(),
            created: None,
            disposition: Disposition::Unsupported,
            left_out: vec![LeftOut::Message(unreadable(None))],
        };
    };
    let Head {
        id,
        create_time,
        author,
        recipient,
        channel,
        status,
        content,
        metadata,
    } = head;
    let id = id.value();
    let mut reading = Reading {
        message_or_node_id: id.clone().unwrap_or_else(|| node.to_owned()),
        created: create_time.value().and_then(Time::seconds),
        disposition: Disposition::Unsupported,
        left_out: Vec::new(),
    };
    let (role, name) = match author {
        Field::Read(Record(author)) => (author.role, author.name.value()),
        Field::Absent => (Field::Absent, None),
        Field::Unreadable => (Field::Unreadable, None),
    };
    let content_type = content.then(|Record(content)| content.content_type);
    let flags = metadata.map(|Record(flags)| flags);
    if excludes(&role, &content_type, &flags) {
        reading.disposition = Disposition::Excluded;
        return reading;
    }
    let (role, content_type) = match (role, content_type) {
        (Field::Read(role), Field::Read(content_type)) => (role, content_type),
        (_, content_type) => {
            let known = content_type.value();
            reading
                .left_out
                .push(LeftOut::Message(unreadable(known.as_deref())));
            return reading;
        }
    };
    if unreadable_flags(&flags) {
        reading
            .left_out
            .push(LeftOut::Message(unreadable(Some(&content_type))));
        return reading;
    }
    let contributions = match supported_body(&content_type, message) {
        None => {
            reading
                .left_out
                .push(LeftOut::Message(named(&content_type)));
            return reading;
        }
        Some(Err(_)) => {
            reading
                .left_out
                .push(LeftOut::Message(unreadable(Some(&content_type))));
            return reading;
        }
        Some(Ok(Body::Texts(texts))) => texts
            .into_iter()
            .map(|text| Contribution {
                text: Some(text),
                file: None,
            })
            .collect(),
        Some(Ok(Body::Parts(parts))) => parts
            .into_iter()
            .filter_map(|part| {
                contribution(part)
                    .map_err(|left_out| reading.left_out.push(left_out))
                    .ok()
            })
            .collect(),
    };
    let extras = match flags {
        Field::Read(_) => MetadataExtras::read(message, &mut reading.left_out),
        Field::Absent | Field::Unreadable => MetadataExtras::default(),
    };
    let recipient = recipient.value();
    let channel = channel.value();
    let part = |text: &str| text.chars().take(KIND_PART_CHARACTERS).collect::<String>();
    reading.disposition = Disposition::Kept(Box::new(Kept {
        role: classify(
            &role,
            &content_type,
            recipient.as_deref(),
            channel.as_deref(),
            extras.preamble,
        ),
        kind: format!("{}:{}", part(&role), part(&content_type)),
        header: ChatGptMessage {
            id,
            author: ChatGptAuthor {
                role: Some(role),
                name,
            },
            recipient,
            channel,
            status: status.value(),
            content_type: Some(content_type),
        },
        contributions,
        attachments: extras.attachments,
        outputs: extras.outputs,
        fallback: extras.fallback,
    }));
    reading
}

fn classify(
    author: &str,
    content_type: &str,
    recipient: Option<&str>,
    channel: Option<&str>,
    preamble: bool,
) -> HistoryRole {
    match author {
        "user" => HistoryRole::User,
        "assistant" if recipient.unwrap_or("all") != "all" => HistoryRole::Tool,
        "assistant" if matches!(content_type, "thoughts" | "reasoning_recap") || preamble => {
            HistoryRole::Thinking
        }
        "assistant" if channel == Some("commentary") => HistoryRole::Commentary,
        "assistant" if channel == Some("final") => HistoryRole::Final,
        "assistant" => HistoryRole::Assistant,
        _ => HistoryRole::Tool,
    }
}

fn named(text: &str) -> String {
    archive::shown(text).chars().take(NAME_CHARACTERS).collect()
}

fn unreadable(content_type: Option<&str>) -> String {
    format!("{} (unreadable)", named(content_type.unwrap_or("(none)")))
}

fn excludes(
    role: &Field<String>,
    content_type: &Field<String>,
    flags: &Field<ExclusionFlags>,
) -> bool {
    matches!(role, Field::Read(role) if matches!(role.as_str(), "system" | "developer"))
        || matches!(content_type, Field::Read(kind) if INSTRUCTION_CONTENT.contains(&kind.as_str()))
        || matches!(flags, Field::Read(flags)
            if flags.flags().any(|flag| matches!(flag, Field::Read(true))))
}

fn unreadable_flags(flags: &Field<ExclusionFlags>) -> bool {
    match flags {
        Field::Read(flags) => flags.flags().any(Field::is_unreadable),
        Field::Absent => false,
        Field::Unreadable => true,
    }
}

#[derive(Deserialize)]
struct Head {
    id: Field<String>,
    create_time: Field<Time>,
    author: Field<Record<Author>>,
    recipient: Field<String>,
    channel: Field<String>,
    status: Field<String>,
    content: Field<Record<ContentType>>,
    metadata: Field<Record<ExclusionFlags>>,
}

#[derive(Deserialize)]
struct Author {
    role: Field<String>,
    name: Field<String>,
}

#[derive(Deserialize)]
struct ContentType {
    content_type: Field<String>,
}

#[derive(Deserialize)]
struct ExclusionFlags {
    is_user_system_message: Field<bool>,
    is_visually_hidden_from_conversation: Field<bool>,
}

impl ExclusionFlags {
    fn flags(&self) -> impl Iterator<Item = &Field<bool>> {
        [
            &self.is_user_system_message,
            &self.is_visually_hidden_from_conversation,
        ]
        .into_iter()
    }
}

enum Body {
    Parts(Vec<Part>),
    Texts(Vec<String>),
}

#[derive(Deserialize)]
struct ContentOf<C> {
    content: Record<C>,
}

#[derive(Deserialize)]
struct PartsContent {
    parts: Vec<Part>,
}

#[derive(Deserialize)]
struct TextContent {
    text: String,
}

#[derive(Deserialize)]
struct BrowsingContent {
    result: String,
}

#[derive(Deserialize)]
struct ThoughtsContent {
    thoughts: Vec<Record<Thought>>,
}

#[derive(Deserialize)]
struct Thought {
    summary: Option<String>,
    content: Option<String>,
}

#[derive(Deserialize)]
struct RecapContent {
    content: String,
}

fn supported_body(content_type: &str, message: &Value) -> Option<Result<Body, serde_json::Error>> {
    fn content<'a, C: Deserialize<'a>>(message: &'a Value) -> Result<C, serde_json::Error> {
        Record::<ContentOf<C>>::deserialize(message).map(|Record(of)| of.content.0)
    }
    Some(match content_type {
        "text" | "multimodal_text" => {
            content::<PartsContent>(message).map(|content| Body::Parts(content.parts))
        }
        "code" | "execution_output" | "tether_quote" | "system_error" => {
            content::<TextContent>(message).map(|content| Body::Texts(vec![content.text]))
        }
        "tether_browsing_display" => {
            content::<BrowsingContent>(message).map(|content| Body::Texts(vec![content.result]))
        }
        "thoughts" => content::<ThoughtsContent>(message).map(|content| {
            Body::Texts(
                content
                    .thoughts
                    .into_iter()
                    .flat_map(|Record(thought)| [thought.summary, thought.content])
                    .flatten()
                    .collect(),
            )
        }),
        "reasoning_recap" => {
            content::<RecapContent>(message).map(|content| Body::Texts(vec![content.content]))
        }
        _ => return None,
    })
}

/// One element of `content.parts`. Variants are tried in order, and the strict shapes come
/// before the catch-alls that only name what was left out.
#[derive(Deserialize)]
#[serde(untagged)]
enum Part {
    Text(String),
    Typed(Record<TextPart>),
    Spoken(Record<TranscriptionPart>),
    Asset(Record<AssetPart>),
    Named(Record<NamedPart>),
    Other(IgnoredAny),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TextPart {
    #[serde(rename = "content_type")]
    _content_type: TextTag,
    text: String,
    metadata: Field<Record<PartFlags>>,
}

#[derive(Deserialize)]
enum TextTag {
    #[serde(rename = "text")]
    Text,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct TranscriptionPart {
    #[serde(rename = "content_type")]
    _content_type: TranscriptionTag,
    text: String,
    metadata: Field<Record<PartFlags>>,
    #[serde(rename = "direction")]
    _direction: Option<IgnoredAny>,
    #[serde(rename = "decoding_id")]
    _decoding_id: Option<IgnoredAny>,
}

#[derive(Deserialize)]
enum TranscriptionTag {
    #[serde(rename = "audio_transcription")]
    Transcription,
}

#[derive(Deserialize)]
struct AssetPart {
    content_type: Option<AssetType>,
    asset_pointer: String,
    text: Field<String>,
    metadata: Field<Record<PartFlags>>,
}

#[derive(Deserialize)]
enum AssetType {
    #[serde(rename = "image_asset_pointer")]
    Image,
    #[serde(rename = "audio_asset_pointer")]
    Audio,
}

#[derive(Deserialize)]
struct NamedPart {
    content_type: Field<String>,
}

#[derive(Deserialize)]
struct PartFlags {
    is_visually_hidden_from_conversation: Field<bool>,
}

enum Visibility {
    Shown,
    Hidden,
    Unreadable,
}

fn visibility(metadata: &Field<Record<PartFlags>>) -> Visibility {
    match metadata {
        Field::Absent => Visibility::Shown,
        Field::Unreadable => Visibility::Unreadable,
        Field::Read(Record(flags)) => match flags.is_visually_hidden_from_conversation {
            Field::Read(true) => Visibility::Hidden,
            Field::Unreadable => Visibility::Unreadable,
            Field::Read(false) | Field::Absent => Visibility::Shown,
        },
    }
}

fn contribution(part: Part) -> Result<Contribution, LeftOut> {
    let (kind, metadata, text, pointer) = match part {
        Part::Text(text) => {
            return Ok(Contribution {
                text: Some(text),
                file: None,
            });
        }
        Part::Typed(Record(part)) => ("text", part.metadata, Field::Read(part.text), None),
        Part::Spoken(Record(part)) => (
            "audio_transcription",
            part.metadata,
            Field::Read(part.text),
            None,
        ),
        Part::Asset(Record(part)) => {
            let kind = match part.content_type {
                Some(AssetType::Image) => "image_asset_pointer",
                Some(AssetType::Audio) => "audio_asset_pointer",
                None => "(none)",
            };
            (kind, part.metadata, part.text, Some(part.asset_pointer))
        }
        Part::Named(Record(part)) => {
            let kind = part.content_type.value();
            return Err(LeftOut::Part(named(kind.as_deref().unwrap_or("(none)"))));
        }
        Part::Other(_) => return Err(LeftOut::Part("(none)".into())),
    };
    let unsupported = || LeftOut::Part(kind.to_owned());
    match visibility(&metadata) {
        Visibility::Shown => {}
        Visibility::Hidden => return Err(LeftOut::HiddenPart(kind.to_owned())),
        Visibility::Unreadable => return Err(unsupported()),
    }
    let text = match text {
        Field::Unreadable => return Err(unsupported()),
        text => text.value(),
    };
    let file = match pointer {
        Some(pointer) => Some(FileId::find(&pointer).ok_or_else(unsupported)?),
        None => None,
    };
    Ok(Contribution { text, file })
}

#[derive(Default)]
struct MetadataExtras {
    preamble: bool,
    attachments: Vec<FileRef>,
    outputs: Vec<AggregateOutput>,
    fallback: Option<String>,
}

#[derive(Deserialize)]
struct MetadataOf {
    metadata: Field<Record<Metadata>>,
}

#[derive(Deserialize)]
struct Metadata {
    is_thinking_preamble_message: Field<bool>,
    attachments: Field<Vec<Record<Attachment>>>,
    aggregate_result: Field<Record<Aggregate>>,
    model_dil_v2: Field<Record<Widget>>,
    author: Option<IgnoredAny>,
    content: Option<IgnoredAny>,
    metadata: Option<IgnoredAny>,
}

#[derive(Deserialize)]
struct Attachment {
    id: Field<String>,
    name: Field<String>,
    mime_type: Field<String>,
    metadata: Field<Record<PartFlags>>,
}

#[derive(Deserialize)]
struct Aggregate {
    messages: Field<Vec<Record<AggregateOutputEntry>>>,
}

#[derive(Deserialize)]
struct AggregateOutputEntry {
    id: Field<String>,
    author: Field<Record<OutputAuthor>>,
    content: Field<Record<ContentType>>,
    metadata: Field<Record<ExclusionFlags>>,
    message_type: Field<String>,
    image_url: Field<String>,
}

#[derive(Deserialize)]
struct OutputAuthor {
    role: Field<String>,
}

#[derive(Deserialize)]
struct Widget {
    #[serde(rename = "fallbackMarkdown")]
    fallback_markdown: Field<String>,
}

impl MetadataExtras {
    fn read(message: &Value, left_out: &mut Vec<LeftOut>) -> Self {
        let Ok(Record(MetadataOf {
            metadata: Field::Read(Record(metadata)),
        })) = Record::<MetadataOf>::deserialize(message)
        else {
            return Self::default();
        };
        if metadata.author.is_some() || metadata.content.is_some() || metadata.metadata.is_some() {
            left_out.push(LeftOut::MessageShapedMetadata);
            return Self::default();
        }
        let mut extras = Self {
            preamble: matches!(metadata.is_thinking_preamble_message, Field::Read(true)),
            ..Self::default()
        };
        match metadata.attachments {
            Field::Absent => {}
            Field::Unreadable => left_out.push(LeftOut::UnreadableAttachments),
            Field::Read(entries) => {
                for Record(entry) in entries {
                    match visibility(&entry.metadata) {
                        Visibility::Hidden => left_out.push(LeftOut::HiddenAttachment),
                        Visibility::Unreadable => left_out.push(LeftOut::UnreadableAttachment),
                        Visibility::Shown => {
                            match entry.id.value().as_deref().and_then(FileId::find) {
                                Some(file) => extras.attachments.push(FileRef {
                                    file,
                                    name: entry.name.value(),
                                    mime_type: entry.mime_type.value(),
                                }),
                                None => left_out.push(LeftOut::UnreadableAttachment),
                            }
                        }
                    }
                }
            }
        }
        match metadata
            .aggregate_result
            .then(|Record(aggregate)| aggregate.messages)
        {
            Field::Absent => {}
            Field::Unreadable => left_out.push(LeftOut::UnreadableOutputs),
            Field::Read(entries) => {
                for Record(entry) in entries {
                    match read_aggregate_output(entry) {
                        Ok(output) => extras.outputs.push(output),
                        Err(entry) => left_out.push(entry),
                    }
                }
            }
        }
        match metadata
            .model_dil_v2
            .then(|Record(widget)| widget.fallback_markdown)
        {
            Field::Absent => {}
            Field::Read(markdown) => extras.fallback = Some(markdown),
            Field::Unreadable => left_out.push(LeftOut::UnreadableFallback),
        }
        extras
    }
}

fn read_aggregate_output(entry: AggregateOutputEntry) -> Result<AggregateOutput, LeftOut> {
    let id = entry.id.value();
    let role = entry.author.then(|Record(author)| author.role);
    let content_type = entry.content.then(|Record(content)| content.content_type);
    let flags = entry.metadata.map(|Record(flags)| flags);
    if excludes(&role, &content_type, &flags) {
        return Ok(AggregateOutput::Excluded { id });
    }
    let kind = entry.message_type.value();
    let name = named(kind.as_deref().unwrap_or("(none)"));
    if role.is_unreadable() || content_type.is_unreadable() || unreadable_flags(&flags) {
        return Err(LeftOut::Output(format!("{name} (unreadable)")));
    }
    match kind.as_deref() {
        Some("image") => entry
            .image_url
            .value()
            .as_deref()
            .and_then(FileId::find)
            .map(|file| AggregateOutput::Kept {
                id,
                file: Some(file),
            })
            .ok_or(LeftOut::Output(name)),
        Some("stream") => Ok(AggregateOutput::Kept { id, file: None }),
        _ => Err(LeftOut::Output(name)),
    }
}

/// A JSON object read as `T`. Serde also reads a struct from an array, field by position, and
/// no export record is an array.
struct Record<T>(T);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Record<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Fields<T>(PhantomData<T>);

        impl<'de, T: Deserialize<'de>> Visitor<'de> for Fields<T> {
            type Value = T;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("an object")
            }

            fn visit_map<A: MapAccess<'de>>(self, map: A) -> Result<T, A::Error> {
                T::deserialize(MapAccessDeserializer::new(map))
            }
        }

        deserializer
            .deserialize_map(Fields(PhantomData))
            .map(Record)
    }
}

/// A field that is absent or null, holds a `T`, or holds something else. Serde reads a missing
/// key as none, so a struct of these never fails on a missing or mistyped field.
enum Field<T> {
    Absent,
    Read(T),
    Unreadable,
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Field<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Maybe<T> {
            Is(T),
            Not(IgnoredAny),
        }

        Ok(match Option::<Maybe<T>>::deserialize(deserializer)? {
            None => Self::Absent,
            Some(Maybe::Is(value)) => Self::Read(value),
            Some(Maybe::Not(_)) => Self::Unreadable,
        })
    }
}

impl<T> Field<T> {
    fn value(self) -> Option<T> {
        match self {
            Self::Read(value) => Some(value),
            Self::Absent | Self::Unreadable => None,
        }
    }

    fn is_unreadable(&self) -> bool {
        matches!(self, Self::Unreadable)
    }

    fn map<U>(self, read: impl FnOnce(T) -> U) -> Field<U> {
        self.then(|value| Field::Read(read(value)))
    }

    fn then<U>(self, read: impl FnOnce(T) -> Field<U>) -> Field<U> {
        match self {
            Self::Read(value) => read(value),
            Self::Absent => Field::Absent,
            Self::Unreadable => Field::Unreadable,
        }
    }
}
