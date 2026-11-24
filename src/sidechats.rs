//! Canonical limits and validation for standing-topic side chats.
//!
//! Rust owns these bounds and exports `runtime/src/generated/sidechat-limits.ts`
//! via `make bindings` so the native boundary and TypeScript runtime agree.

use anyhow::{Result, ensure};

use crate::protocol::ReplyReference;

pub const SIDECHAT_TITLE_MAX_BYTES: usize = 160;
pub const SIDECHAT_SLUG_MAX_BYTES: usize = 64;
pub const SIDECHAT_CHARTER_MAX_BYTES: usize = 4_000;
pub const SIDECHAT_HANDOFF_MAX_BYTES: usize = 16_384;
pub const SIDECHAT_SEED_EXCERPT_MAX_BYTES: usize = 4_000;

/// Unicode bidi overrides/isolates and invisible format characters that can spoof terminal
/// or single-line UI display. Leaves U+200C (ZWNJ), U+200D (ZWJ), and ordinary direction
/// marks (U+200E, U+200F, U+061C) allowed for joined emoji and natural multilingual text.
pub fn is_unsafe_terminal_format(ch: char) -> bool {
    matches!(
        ch,
        '\u{200b}' | '\u{2028}'..='\u{202e}' | '\u{2060}'..='\u{206f}' | '\u{feff}'
    )
}

/// Control or bidirectional override characters disallowed in multiline side chat text
/// (charters and handoffs). Allows ordinary whitespace (`\n`, `\r`, `\t`, `\x0c`),
/// direction marks (`U+200E`, `U+200F`, `U+061C`), and direction isolates (`U+2066..=U+2069`).
pub fn is_unsafe_multiline_char(ch: char) -> bool {
    (ch.is_control() && !matches!(ch, '\n' | '\r' | '\t' | '\x0c'))
        || matches!(ch, '\u{202a}'..='\u{202e}')
}

/// Strips unsafe control and directional override characters from multiline text while
/// preserving ordinary newlines and tabs.
pub fn sanitize_multiline_text(text: &str) -> String {
    text.chars()
        .filter(|ch| !is_unsafe_multiline_char(*ch))
        .collect()
}

/// Strips terminal control and directional/invisible format characters for single-line output.
pub fn sanitize_terminal_text(text: &str) -> String {
    text.chars()
        .filter(|ch| !ch.is_control() && !is_unsafe_terminal_format(*ch))
        .collect()
}

pub fn validate_title(raw: &str) -> Result<()> {
    let trimmed = raw.trim();
    ensure!(!trimmed.is_empty(), "Side chat title cannot be empty");
    ensure!(
        !trimmed
            .chars()
            .any(|ch| ch.is_control() || is_unsafe_terminal_format(ch)),
        "Side chat title cannot contain control or formatting characters"
    );
    ensure!(
        trimmed.len() <= SIDECHAT_TITLE_MAX_BYTES,
        "Side chat title must be at most {SIDECHAT_TITLE_MAX_BYTES} UTF-8 bytes"
    );
    Ok(())
}

pub fn validate_slug(raw: &str) -> Result<()> {
    let slug = raw.trim().to_ascii_lowercase();
    ensure!(!slug.is_empty(), "Side chat slug cannot be empty");
    ensure!(
        slug.len() <= SIDECHAT_SLUG_MAX_BYTES
            && slug
                .as_bytes()
                .first()
                .is_some_and(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
            && slug.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
            }),
        "Side chat slug must be 1 to {SIDECHAT_SLUG_MAX_BYTES} lowercase ASCII letters, digits, hyphens, or underscores starting with a letter or digit"
    );
    ensure!(
        !slug.bytes().all(|byte| byte.is_ascii_digit()),
        "Side chat slug cannot be purely numeric"
    );
    Ok(())
}

pub fn validate_charter(raw: &str) -> Result<()> {
    let trimmed = raw.trim();
    ensure!(
        !trimmed.chars().any(is_unsafe_multiline_char),
        "Side chat charter cannot contain control or directional override characters"
    );
    ensure!(
        trimmed.len() <= SIDECHAT_CHARTER_MAX_BYTES,
        "Side chat charter must be at most {SIDECHAT_CHARTER_MAX_BYTES} UTF-8 bytes"
    );
    Ok(())
}

pub fn validate_handoff(raw: &str) -> Result<()> {
    let trimmed = raw.trim();
    ensure!(
        !trimmed.chars().any(is_unsafe_multiline_char),
        "Side chat handoff cannot contain control or directional override characters"
    );
    ensure!(
        trimmed.len() <= SIDECHAT_HANDOFF_MAX_BYTES,
        "Side chat handoff must be at most {SIDECHAT_HANDOFF_MAX_BYTES} UTF-8 bytes"
    );
    Ok(())
}

pub fn validate_seed(seed: &ReplyReference) -> Result<()> {
    let entry_id = seed.entry_id.trim();
    ensure!(
        !entry_id.is_empty()
            && entry_id.len() <= 128
            && !entry_id
                .chars()
                .any(|character| character.is_whitespace() || character.is_control()),
        "Invalid seed message entry ID"
    );
    // Seed excerpts are quoted verbatim from existing chat messages that the user cannot
    // edit in the create sheet; the runtime strips unsafe control/bidi characters rather
    // than rejecting the quote.
    let sanitized = sanitize_multiline_text(&seed.excerpt);
    let excerpt = sanitized.trim();
    ensure!(
        excerpt.len() <= SIDECHAT_SEED_EXCERPT_MAX_BYTES,
        "Seed message excerpt must be at most {SIDECHAT_SEED_EXCERPT_MAX_BYTES} UTF-8 bytes"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::HistoryRole;

    #[test]
    fn title_validation_matches_runtime_rules() {
        assert!(validate_title("Morning Brief").is_ok());
        assert!(validate_title("Kitchen \u{1f9d1}\u{200d}\u{1f373}").is_ok());
        assert!(validate_title("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} Family").is_ok());
        assert!(validate_title("\u{1f3c3}\u{200d}\u{2640}\u{fe0f} Running").is_ok());
        assert!(validate_title("می\u{200c}روم").is_ok());
        assert!(validate_title("פרויקט 2026\u{200f}").is_ok());
        assert!(validate_title(&"a".repeat(SIDECHAT_TITLE_MAX_BYTES)).is_ok());
        assert!(validate_title(&"a".repeat(SIDECHAT_TITLE_MAX_BYTES + 1)).is_err());
        assert!(validate_title("   ").is_err());
        assert!(validate_title("Bad\nTitle").is_err());
        assert!(validate_title("Bad\x1b[31mTitle").is_err());
        assert!(validate_title("Spoof\u{202e}Title").is_err());
        assert!(validate_title("Zero\u{200b}Width").is_err());
        assert!(validate_title("Line\u{2028}Sep").is_err());
        assert!(validate_title("Isolate\u{2066}Title").is_err());
    }

    #[test]
    fn slug_validation_accepts_underscores_and_rejects_purely_numeric_slugs() {
        assert!(validate_slug("morning_brief-2").is_ok());
        assert!(validate_slug("  Morning_Brief  ").is_ok());
        assert!(validate_slug("12345").is_err());
        assert!(validate_slug("-bad").is_err());
        assert!(validate_slug("_bad").is_err());
        assert!(validate_slug("bad slug!").is_err());
        assert!(validate_slug("\u{212a}elvin").is_err());
    }

    #[test]
    fn charter_handoff_and_seed_trim_before_checking_bounds_and_reject_escape_controls() {
        assert!(validate_charter("Line 1\n\tLine 2").is_ok());
        assert!(validate_charter("Wrapped \u{2068}Name\u{2069}\u{200f}\x0cPage 2").is_ok());
        assert!(
            validate_charter(&format!("  {}  ", "x".repeat(SIDECHAT_CHARTER_MAX_BYTES))).is_ok()
        );
        assert!(validate_charter(&"x".repeat(SIDECHAT_CHARTER_MAX_BYTES + 1)).is_err());
        assert!(validate_charter("Bad\x1b[31mcharter").is_err());
        assert!(validate_charter("Bad\u{202e}charter").is_err());
        assert!(validate_handoff("Notes:\n- item 1\n\t- detail").is_ok());
        assert!(validate_handoff("Notes \u{2068}RTL\u{2069} \u{200e}next\x0cpage").is_ok());
        assert!(
            validate_handoff(&format!("  {}  ", "x".repeat(SIDECHAT_HANDOFF_MAX_BYTES))).is_ok()
        );
        assert!(validate_handoff(&"x".repeat(SIDECHAT_HANDOFF_MAX_BYTES + 1)).is_err());
        assert!(validate_handoff("Bad\x1b]0;title\x07").is_err());
        assert!(validate_handoff("Bad\u{202e}handoff").is_err());
        assert!(
            validate_seed(&ReplyReference {
                entry_id: "42".into(),
                role: HistoryRole::Assistant,
                excerpt: format!("  {}  ", "e".repeat(SIDECHAT_SEED_EXCERPT_MAX_BYTES)),
            })
            .is_ok()
        );
        assert!(
            validate_seed(&ReplyReference {
                entry_id: "42".into(),
                role: HistoryRole::Assistant,
                excerpt: "e".repeat(SIDECHAT_SEED_EXCERPT_MAX_BYTES + 1),
            })
            .is_err()
        );
        assert!(
            validate_seed(&ReplyReference {
                entry_id: "42".into(),
                role: HistoryRole::Assistant,
                excerpt: "Quoted \u{202a}+1 555 0100\u{202c} \x1b[31mred".into(),
            })
            .is_ok()
        );
        assert_eq!(
            sanitize_terminal_text("Demo\u{202e}\x1b[31m Car\u{200b}"),
            "Demo[31m Car"
        );
    }
}
