//! Program Status Protocol (`OSC 7501`) encoding and sanitization for Rex and compatible terminals.

use base64::{Engine as _, engine::general_purpose::STANDARD};

pub(super) const APP_ID: &str = "beep-boop";
const MAX_SEQUENCE_BYTES: usize = 4096;
const MAX_TITLE_DECODED_BYTES: usize = 192;
const MAX_MSG_DECODED_BYTES: usize = 2048;
const MAX_ID_BYTES: usize = 128;
const MAX_ID_SEGMENTS: usize = 8;
const MAX_SEGMENT_LEN: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum BlockedKind {
    Auth,
    Question,
}

impl BlockedKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Auth => "auth",
            Self::Question => "question",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum ProgramState {
    Idle,
    Working,
    Done,
    /// The kind says what the program waits for. The protocol has none for a
    /// plain acknowledgement, so that wait carries no kind.
    Blocked(Option<BlockedKind>),
    Error,
    Clear,
}

impl ProgramState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Working => "working",
            Self::Done => "done",
            Self::Blocked(_) => "blocked",
            Self::Error => "error",
            Self::Clear => "clear",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ProgramStatusReport {
    pub(super) id: Option<String>,
    pub(super) state: ProgramState,
    pub(super) progress: Option<u8>,
    pub(super) title: Option<String>,
    pub(super) msg: Option<String>,
}

impl ProgramStatusReport {
    pub(super) fn clear(id: Option<&str>) -> Self {
        let id = id.and_then(|value| {
            let segments: Vec<_> = value.split('/').collect();
            sanitize_record_id(&segments)
        });
        Self {
            id,
            state: ProgramState::Clear,
            progress: None,
            title: None,
            msg: None,
        }
    }

    pub(super) fn clear_all_sequence() -> &'static str {
        "\x1b]7501;state=clear\x1b\\"
    }

    pub(super) fn encode(&self) -> String {
        let mut fields = vec![format!("state={}", self.state.as_str())];
        if !matches!(self.state, ProgramState::Clear) {
            fields.push(format!("app={APP_ID}"));
        }
        if let Some(id) = self.id.as_deref().and_then(valid_record_id) {
            fields.push(format!("id={id}"));
        }
        if let ProgramState::Blocked(Some(kind)) = self.state {
            fields.push(format!("kind={}", kind.as_str()));
        }
        if matches!(self.state, ProgramState::Working | ProgramState::Blocked(_))
            && let Some(progress) = self.progress
        {
            fields.push(format!("progress={}", progress.min(100)));
        }
        let clean_title = self
            .title
            .as_deref()
            .map(|text| {
                truncate_utf8_bytes(&sanitize_single_line(text, 192), MAX_TITLE_DECODED_BYTES)
            })
            .filter(|text| !text.is_empty());
        if let Some(title) = clean_title {
            fields.push(format!("title={}", STANDARD.encode(title.as_bytes())));
        }
        let clean_msg = self
            .msg
            .as_deref()
            .map(|text| {
                truncate_utf8_bytes(&sanitize_single_line(text, 2048), MAX_MSG_DECODED_BYTES)
            })
            .filter(|text| !text.is_empty());

        let prefix = format!("\x1b]7501;{}", fields.join(":"));
        let suffix = "\x1b\\";
        if let Some(msg) = clean_msg {
            // Hard protocol cap is 4096 bytes for the whole OSC..ST sequence.
            let overhead = prefix.len() + ":msg=".len() + suffix.len();
            if overhead < MAX_SEQUENCE_BYTES {
                let max_encoded = MAX_SEQUENCE_BYTES - overhead;
                let max_decoded = (max_encoded / 4) * 3;
                let bounded = truncate_utf8_bytes(&msg, max_decoded);
                if !bounded.is_empty() {
                    return format!(
                        "{prefix}:msg={}{suffix}",
                        STANDARD.encode(bounded.as_bytes())
                    );
                }
            }
        }
        let sequence = format!("{prefix}{suffix}");
        debug_assert!(sequence.len() <= MAX_SEQUENCE_BYTES);
        sequence
    }
}

/// The root report of a program that cannot continue until the user acts,
/// with `msg` as the reason. For a program that waits outside the interface,
/// which reports nothing once it has stopped.
pub fn blocked_on_user_report(msg: &str) -> String {
    ProgramStatusReport {
        id: None,
        state: ProgramState::Blocked(None),
        progress: None,
        title: None,
        msg: Some(msg.to_owned()),
    }
    .encode()
}

/// Remove control characters, zero-width marks, and bidi overrides while collapsing whitespace
/// into a single line so both `OSC 0` titles and `OSC 7501` metadata stay terminal-safe.
pub(super) fn sanitize_single_line(text: &str, max_chars: usize) -> String {
    text.chars()
        .filter_map(|ch| {
            if matches!(ch, '\n' | '\r' | '\t') {
                Some(' ')
            } else if is_unsafe_control_or_bidi(ch) {
                None
            } else {
                Some(ch)
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(max_chars)
        .collect()
}

pub(super) fn sanitize_record_id(segments: &[&str]) -> Option<String> {
    if segments.is_empty() || segments.len() > MAX_ID_SEGMENTS {
        return None;
    }
    let mut cleaned = Vec::with_capacity(segments.len());
    for raw in segments {
        let mut segment = String::new();
        for ch in raw.chars() {
            if ch.is_ascii_alphanumeric() || matches!(ch, '_' | '.' | '+' | '-') {
                segment.push(ch);
            } else {
                segment.push('_');
            }
            if segment.len() >= MAX_SEGMENT_LEN {
                break;
            }
        }
        if segment.is_empty() {
            return None;
        }
        cleaned.push(segment);
    }
    let joined = cleaned.join("/");
    (joined.len() <= MAX_ID_BYTES).then_some(joined)
}

fn valid_record_id(id: &str) -> Option<&str> {
    if id.is_empty() || id.len() > MAX_ID_BYTES {
        return None;
    }
    let segments: Vec<_> = id.split('/').collect();
    if segments.len() > MAX_ID_SEGMENTS {
        return None;
    }
    segments
        .iter()
        .all(|segment| {
            !segment.is_empty()
                && segment.len() <= MAX_SEGMENT_LEN
                && segment.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'+' | b'-')
                })
        })
        .then_some(id)
}

fn is_unsafe_control_or_bidi(ch: char) -> bool {
    ch.is_control()
        || matches!(
            ch,
            '\u{061c}' | '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}'
        )
}

fn truncate_utf8_bytes(text: &str, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text.to_owned();
    }
    let mut end = 0;
    for (idx, ch) in text.char_indices() {
        let next = idx + ch.len_utf8();
        if next > max_bytes {
            break;
        }
        end = next;
    }
    text[..end].to_owned()
}

pub(super) struct Osc7501Command<'a>(pub(super) &'a str);

impl crossterm::Command for Osc7501Command<'_> {
    fn write_ansi(&self, f: &mut impl std::fmt::Write) -> std::fmt::Result {
        f.write_str(self.0)
    }

    #[cfg(windows)]
    fn execute_winapi(&self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode_pairs(sequence: &str) -> Vec<(&str, &str)> {
        let body = sequence
            .strip_prefix("\x1b]7501;")
            .and_then(|rest| rest.strip_suffix("\x1b\\"))
            .expect("valid OSC 7501 framing");
        body.split(':')
            .map(|pair| pair.split_once('=').expect("key=value"))
            .collect()
    }

    #[test]
    fn encodes_working_blocked_done_error_idle_and_clear_within_protocol_limits() {
        let working = ProgramStatusReport {
            id: None,
            state: ProgramState::Working,
            progress: Some(42),
            title: Some("Fix\x1b[31m title\u{202e}spoof".into()),
            msg: Some("Line 1\nLine\t2\u{200b}".into()),
        }
        .encode();
        assert!(working.len() <= MAX_SEQUENCE_BYTES);
        let pairs = decode_pairs(&working);
        assert_eq!(pairs[0], ("state", "working"));
        assert_eq!(pairs[1], ("app", "beep-boop"));
        assert_eq!(pairs[2], ("progress", "42"));
        let decoded_title = String::from_utf8(STANDARD.decode(pairs[3].1).unwrap()).unwrap();
        assert_eq!(decoded_title, "Fix[31m titlespoof");
        assert!(!decoded_title.chars().any(is_unsafe_control_or_bidi));
        let decoded_msg = String::from_utf8(STANDARD.decode(pairs[4].1).unwrap()).unwrap();
        assert_eq!(decoded_msg, "Line 1 Line 2");

        let blocked = ProgramStatusReport {
            id: sanitize_record_id(&["agent", "thread:1"]),
            state: ProgramState::Blocked(Some(BlockedKind::Auth)),
            progress: Some(120),
            title: Some("Child agent".into()),
            msg: Some("Sign in required".into()),
        }
        .encode();
        let blocked_pairs = decode_pairs(&blocked);
        assert!(blocked_pairs.contains(&("state", "blocked")));
        assert!(blocked_pairs.contains(&("id", "agent/thread_1")));
        assert!(blocked_pairs.contains(&("kind", "auth")));
        assert!(blocked_pairs.contains(&("progress", "100")));

        let oversized = ProgramStatusReport {
            id: sanitize_record_id(&["agent", "long"]),
            state: ProgramState::Error,
            progress: Some(50), // ignored on Error per spec
            title: Some("X".repeat(400)),
            msg: Some("🦀".repeat(2000)),
        }
        .encode();
        assert!(oversized.len() <= MAX_SEQUENCE_BYTES);
        let err_pairs = decode_pairs(&oversized);
        assert!(!err_pairs.iter().any(|(key, _)| *key == "progress"));
        let title_bytes = STANDARD
            .decode(err_pairs.iter().find(|p| p.0 == "title").unwrap().1)
            .unwrap();
        assert!(title_bytes.len() <= MAX_TITLE_DECODED_BYTES);
        assert!(err_pairs.iter().find(|p| p.0 == "msg").unwrap().1.len() <= 2732);

        assert_eq!(
            ProgramStatusReport::clear_all_sequence(),
            "\x1b]7501;state=clear\x1b\\"
        );
        assert_eq!(
            ProgramStatusReport::clear(Some("agent/child-1")).encode(),
            "\x1b]7501;state=clear:id=agent/child-1\x1b\\"
        );
    }
}
