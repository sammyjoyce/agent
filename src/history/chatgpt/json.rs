//! Pure JSON helpers: a streaming splitter for conversation shards, string repair and the
//! canonical form every version hashes.

use std::{
    borrow::Cow,
    io::{self, BufRead, BufReader, Read},
};

use serde_json::Value;

/// One top-level element of a conversation shard.
pub(super) enum Element<'a> {
    Value {
        offset: u64,
        bytes: &'a [u8],
    },
    /// Larger than the element bound; skipped without buffering.
    Oversized {
        offset: u64,
        len: u64,
    },
}

#[derive(Debug)]
pub(super) enum SplitError {
    NotJson,
    Read(io::Error),
}

impl From<io::Error> for SplitError {
    fn from(error: io::Error) -> Self {
        Self::Read(error)
    }
}

/// Calls `element` with each top-level conversation's raw bytes and its offset in the stream.
/// Accepts a JSON array, an object whose first key is `conversations` holding an array, or
/// one bare conversation object. Tracks only strings, escapes and depth, buffers at most one
/// element, and reads the stream to its end so a size or checksum fault always surfaces.
pub(super) fn split_conversations<E>(
    stream: &mut dyn Read,
    maximum_element: usize,
    element: &mut dyn FnMut(Element<'_>) -> Result<(), E>,
) -> Result<(), Split<E>> {
    let mut scanner = Scanner {
        input: BufReader::with_capacity(64 * 1024, stream),
        offset: 0,
    };
    scanner.skip_bom()?;
    match scanner.next_significant()? {
        Some(b'[') => scanner.array(maximum_element, element)?,
        Some(b'{') => {
            let start = scanner.offset - 1;
            let mut bytes = vec![b'{'];
            let mut lexer = Lexer {
                depth: 1,
                string: false,
                escaped: false,
            };
            let key = scanner.first_key(&mut lexer, &mut bytes)?;
            if key.as_deref() == Some("conversations") {
                if scanner.next_significant()? != Some(b':')
                    || scanner.next_significant()? != Some(b'[')
                {
                    return Err(Split::Shape(SplitError::NotJson));
                }
                scanner.array(maximum_element, element)?;
                scanner.finish(&mut lexer, &mut Vec::new(), 0)?;
            } else {
                let oversized = scanner.finish(&mut lexer, &mut bytes, maximum_element)?;
                let reported = if oversized {
                    element(Element::Oversized {
                        offset: start,
                        len: scanner.offset - start,
                    })
                } else {
                    element(Element::Value {
                        offset: start,
                        bytes: &bytes,
                    })
                };
                reported.map_err(Split::Element)?;
            }
        }
        _ => return Err(Split::Shape(SplitError::NotJson)),
    }
    if scanner.next_significant()?.is_some() {
        return Err(Split::Shape(SplitError::NotJson));
    }
    Ok(())
}

pub(super) enum Split<E> {
    Shape(SplitError),
    Element(E),
}

impl<E> From<SplitError> for Split<E> {
    fn from(error: SplitError) -> Self {
        Self::Shape(error)
    }
}

impl<E> From<io::Error> for Split<E> {
    fn from(error: io::Error) -> Self {
        Self::Shape(SplitError::Read(error))
    }
}

/// String, escape and bracket state of the bytes seen so far.
struct Lexer {
    depth: usize,
    string: bool,
    escaped: bool,
}

impl Lexer {
    fn step(&mut self, byte: u8) -> Result<(), SplitError> {
        if self.string {
            if self.escaped {
                self.escaped = false;
            } else if byte == b'\\' {
                self.escaped = true;
            } else if byte == b'"' {
                self.string = false;
            }
            return Ok(());
        }
        match byte {
            b'"' => self.string = true,
            b'{' | b'[' => self.depth += 1,
            b'}' | b']' => self.depth = self.depth.checked_sub(1).ok_or(SplitError::NotJson)?,
            _ => {}
        }
        Ok(())
    }

    fn closed(&self) -> bool {
        self.depth == 0 && !self.string
    }
}

/// Buffers an element until it passes `maximum`, then drops it and only keeps scanning.
fn keep(bytes: &mut Vec<u8>, byte: u8, maximum: usize, oversized: &mut bool) {
    if *oversized {
        return;
    }
    if bytes.len() >= maximum {
        *oversized = true;
        *bytes = Vec::new();
    } else {
        bytes.push(byte);
    }
}

struct Scanner<R> {
    input: BufReader<R>,
    offset: u64,
}

impl<R: Read> Scanner<R> {
    fn byte(&mut self) -> Result<Option<u8>, SplitError> {
        let buffer = self.input.fill_buf()?;
        let Some(&byte) = buffer.first() else {
            return Ok(None);
        };
        self.input.consume(1);
        self.offset += 1;
        Ok(Some(byte))
    }

    fn required(&mut self) -> Result<u8, SplitError> {
        self.byte()?.ok_or(SplitError::NotJson)
    }

    fn skip_bom(&mut self) -> Result<(), SplitError> {
        if self.input.fill_buf()?.starts_with(&[0xEF, 0xBB, 0xBF]) {
            self.input.consume(3);
            self.offset += 3;
        }
        Ok(())
    }

    fn next_significant(&mut self) -> Result<Option<u8>, SplitError> {
        while let Some(byte) = self.byte()? {
            if !byte.is_ascii_whitespace() {
                return Ok(Some(byte));
            }
        }
        Ok(None)
    }

    fn array<E>(
        &mut self,
        maximum: usize,
        element: &mut dyn FnMut(Element<'_>) -> Result<(), E>,
    ) -> Result<(), Split<E>> {
        let mut first = true;
        loop {
            let byte = self.next_significant()?.ok_or(SplitError::NotJson)?;
            if first && byte == b']' {
                return Ok(());
            }
            first = false;
            let start = self.offset - 1;
            let mut bytes = vec![byte];
            let mut oversized = false;
            let mut lexer = Lexer {
                depth: 0,
                string: false,
                escaped: false,
            };
            lexer.step(byte)?;
            let terminator = loop {
                let byte = self.required()?;
                if lexer.closed() && (byte == b',' || byte == b']') {
                    break byte;
                }
                lexer.step(byte)?;
                keep(&mut bytes, byte, maximum, &mut oversized);
            };
            let reported = if oversized {
                element(Element::Oversized {
                    offset: start,
                    len: self.offset - 1 - start,
                })
            } else {
                while bytes.last().is_some_and(u8::is_ascii_whitespace) {
                    bytes.pop();
                }
                element(Element::Value {
                    offset: start,
                    bytes: &bytes,
                })
            };
            reported.map_err(Split::Element)?;
            if terminator == b']' {
                return Ok(());
            }
        }
    }

    /// Reads the whitespace and first key of an object whose `{` was consumed, copying them.
    fn first_key(
        &mut self,
        lexer: &mut Lexer,
        bytes: &mut Vec<u8>,
    ) -> Result<Option<String>, SplitError> {
        let mut byte = self.required()?;
        while byte.is_ascii_whitespace() {
            bytes.push(byte);
            byte = self.required()?;
        }
        bytes.push(byte);
        lexer.step(byte)?;
        if byte != b'"' {
            return Ok(None);
        }
        let mut key = Vec::new();
        while lexer.string {
            let byte = self.required()?;
            bytes.push(byte);
            lexer.step(byte)?;
            if lexer.string && key.len() <= 64 {
                key.push(byte);
            }
        }
        Ok(String::from_utf8(key).ok())
    }

    /// Consumes bytes until the object `lexer` is inside closes. True when `bytes` passed
    /// `maximum` and was dropped.
    fn finish(
        &mut self,
        lexer: &mut Lexer,
        bytes: &mut Vec<u8>,
        maximum: usize,
    ) -> Result<bool, SplitError> {
        let mut oversized = bytes.len() > maximum;
        while lexer.depth > 0 {
            let byte = self.required()?;
            lexer.step(byte)?;
            keep(bytes, byte, maximum, &mut oversized);
        }
        Ok(oversized)
    }
}

/// Replaces invalid UTF-8 and unpaired UTF-16 surrogate escapes with U+FFFD, counting each.
/// Borrowed when nothing needed repair.
pub(super) fn repair(bytes: &[u8]) -> (Cow<'_, [u8]>, u32) {
    let mut repairs = 0;
    let text: Cow<'_, [u8]> = if std::str::from_utf8(bytes).is_ok() {
        Cow::Borrowed(bytes)
    } else {
        let mut owned = Vec::with_capacity(bytes.len());
        for chunk in bytes.utf8_chunks() {
            owned.extend_from_slice(chunk.valid().as_bytes());
            if !chunk.invalid().is_empty() {
                owned.extend_from_slice("\u{FFFD}".as_bytes());
                repairs += 1;
            }
        }
        Cow::Owned(owned)
    };
    if !text
        .windows(3)
        .any(|window| window[0] == b'\\' && window[1] == b'u' && matches!(window[2], b'd' | b'D'))
    {
        return (text, repairs);
    }
    let mut output = Vec::with_capacity(text.len());
    let mut index = 0;
    let mut string = false;
    while index < text.len() {
        let byte = text[index];
        if !string {
            string = byte == b'"';
            output.push(byte);
            index += 1;
            continue;
        }
        match byte {
            b'"' => {
                string = false;
                output.push(byte);
                index += 1;
            }
            b'\\' if text.get(index + 1) == Some(&b'u') => {
                let unit = escape_unit(&text[index..]);
                match unit {
                    Some(0xD800..=0xDBFF) => {
                        let low = text.get(index + 6..).and_then(escape_unit);
                        if matches!(low, Some(0xDC00..=0xDFFF)) {
                            output.extend_from_slice(&text[index..index + 12]);
                            index += 12;
                        } else {
                            output.extend_from_slice(b"\\uFFFD");
                            repairs += 1;
                            index += 6;
                        }
                    }
                    Some(0xDC00..=0xDFFF) => {
                        output.extend_from_slice(b"\\uFFFD");
                        repairs += 1;
                        index += 6;
                    }
                    _ => {
                        output.extend_from_slice(&text[index..(index + 6).min(text.len())]);
                        index += 6;
                    }
                }
            }
            b'\\' => {
                output.extend_from_slice(&text[index..(index + 2).min(text.len())]);
                index += 2;
            }
            _ => {
                output.push(byte);
                index += 1;
            }
        }
    }
    (Cow::Owned(output), repairs)
}

fn escape_unit(bytes: &[u8]) -> Option<u16> {
    if bytes.len() < 6 || bytes[0] != b'\\' || bytes[1] != b'u' {
        return None;
    }
    let digits = std::str::from_utf8(&bytes[2..6]).ok()?;
    u16::from_str_radix(digits, 16).ok()
}

/// JSON with object keys sorted at every depth, so equal content hashes equally whatever
/// key order the export used.
pub(super) fn canonical(value: &Value) -> Vec<u8> {
    let mut output = Vec::new();
    write_canonical(value, &mut output);
    output
}

fn write_canonical(value: &Value, output: &mut Vec<u8>) {
    match value {
        Value::Object(map) => {
            let mut entries: Vec<_> = map.iter().collect();
            entries.sort_by(|left, right| left.0.cmp(right.0));
            output.push(b'{');
            for (index, (key, value)) in entries.into_iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                output.extend_from_slice(&serde_json::to_vec(key).unwrap_or_default());
                output.push(b':');
                write_canonical(value, output);
            }
            output.push(b'}');
        }
        Value::Array(values) => {
            output.push(b'[');
            for (index, value) in values.iter().enumerate() {
                if index > 0 {
                    output.push(b',');
                }
                write_canonical(value, output);
            }
            output.push(b']');
        }
        scalar => output.extend_from_slice(&serde_json::to_vec(scalar).unwrap_or_default()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn split(input: &str, maximum: usize) -> Result<Vec<String>, ()> {
        let mut found = Vec::new();
        let result = split_conversations::<()>(&mut input.as_bytes(), maximum, &mut |element| {
            found.push(match element {
                Element::Value { offset, bytes } => {
                    format!("{offset}:{}", String::from_utf8_lossy(bytes))
                }
                Element::Oversized { offset, len } => format!("{offset}:oversized {len}"),
            });
            Ok(())
        });
        result.map(|()| found).map_err(|_| ())
    }

    #[test]
    fn arrays_wrappers_and_bare_objects_split_into_elements() {
        assert_eq!(
            split(r#" [{"a":"x,]"}, 42 ,{}] "#, 100).unwrap(),
            [r#"2:{"a":"x,]"}"#, "15:42", "19:{}"]
        );
        assert_eq!(
            split(r#"{"conversations": [{"id":"1"}], "other": [1]}"#, 100).unwrap(),
            [r#"19:{"id":"1"}"#]
        );
        assert_eq!(split(r#"{"id":"1"}"#, 100).unwrap(), [r#"0:{"id":"1"}"#]);
        assert_eq!(split("[]", 100).unwrap(), Vec::<String>::new());
        assert_eq!(
            split(r#"[{"long":"abcdefghij"},{"b":1}]"#, 8).unwrap(),
            ["1:oversized 21", r#"23:{"b":1}"#]
        );
        assert!(split(r#"[{"a":1}"#, 100).is_err());
        assert!(split(r#"[1] 2"#, 100).is_err());
        assert!(split("nonsense", 100).is_err());
    }

    #[test]
    fn repair_replaces_lone_surrogates_and_keeps_pairs() {
        let (text, count) = repair(br#"{"a":"\ud83d\ude00 \ud83d x \udc00 \\ud800"}"#);
        assert_eq!(count, 2);
        let value: Value = serde_json::from_slice(&text).unwrap();
        assert_eq!(value["a"], "\u{1F600} \u{FFFD} x \u{FFFD} \\ud800");
        let (text, count) = repair(b"{\"a\":\"\xff\"}");
        assert_eq!(count, 1);
        assert!(matches!(text, Cow::Owned(_)));
        assert!(matches!(repair(br#"{"a":"plain"}"#), (Cow::Borrowed(_), 0)));
    }

    #[test]
    fn canonical_sorts_keys_at_every_depth() {
        let left: Value =
            serde_json::from_str(r#"{"b":{"y":1,"x":[{"d":2,"c":3}]},"a":"\u00e9"}"#).unwrap();
        let right: Value =
            serde_json::from_str(r#"{"a":"é","b":{"x":[{"c":3,"d":2}],"y":1}}"#).unwrap();
        assert_eq!(canonical(&left), canonical(&right));
        assert_eq!(
            String::from_utf8(canonical(&left)).unwrap(),
            r#"{"a":"é","b":{"x":[{"c":3,"d":2}],"y":1}}"#
        );
    }
}
