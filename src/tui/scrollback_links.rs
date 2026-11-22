//! Inject OSC 8 hyperlinks around plain URLs when flushing completed scrollback.

use ratatui::{
    Terminal,
    backend::{Backend, ClearType as BackendClearType, CrosstermBackend, WindowSize},
    buffer::Cell,
    layout::{Position, Size},
};
use std::{collections::BTreeMap, io::Write};

pub(super) trait ScrollbackLinks {
    fn set_osc8(&mut self, _active: bool) {}
}

#[cfg(test)]
impl ScrollbackLinks for ratatui::backend::TestBackend {}

impl<W: Write> ScrollbackLinks for CrosstermBackend<W> {}

pub(super) struct ScrollbackBackend<W: Write> {
    inner: CrosstermBackend<W>,
    osc8_active: bool,
}

impl<W: Write> ScrollbackBackend<W> {
    pub(super) fn new(writer: W) -> Self {
        Self {
            inner: CrosstermBackend::new(writer),
            osc8_active: false,
        }
    }
}

impl<W: Write> ScrollbackLinks for ScrollbackBackend<W> {
    fn set_osc8(&mut self, active: bool) {
        self.osc8_active = active;
    }
}

pub(super) struct Osc8Guard<'a, B: Backend + ScrollbackLinks>(pub(super) &'a mut Terminal<B>);

impl<B: Backend + ScrollbackLinks> Drop for Osc8Guard<'_, B> {
    fn drop(&mut self) {
        self.0.backend_mut().set_osc8(false);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct UrlCellSpan {
    row_index: usize,
    start_cell: usize,
    end_cell: usize,
    url: String,
}

fn is_url_byte(ch: char) -> bool {
    ch.is_ascii_graphic()
        && !matches!(
            ch,
            '<' | '>' | '"' | '\'' | '`' | '{' | '}' | '|' | '^' | '\x7f'
        )
}

fn clean_osc8_url(raw: &str) -> Option<String> {
    let mut trimmed = raw;
    let mut open_parens = 0usize;
    let mut valid_len = 0usize;
    for (idx, ch) in trimmed.char_indices() {
        if ch.is_control() || !is_url_byte(ch) {
            break;
        }
        if ch == '(' {
            open_parens += 1;
        } else if ch == ')' {
            if open_parens == 0 {
                break;
            }
            open_parens -= 1;
        }
        valid_len = idx + ch.len_utf8();
    }
    trimmed = &trimmed[..valid_len];
    while let Some(last) = trimmed.chars().next_back() {
        if matches!(last, '.' | ',' | ';' | ':' | '!' | '?' | ']') {
            trimmed = &trimmed[..trimmed.len() - last.len_utf8()];
        } else {
            break;
        }
    }
    let after_scheme = trimmed
        .strip_prefix("https://")
        .or_else(|| trimmed.strip_prefix("http://"))?;
    if after_scheme.is_empty() || after_scheme.starts_with('/') {
        return None;
    }
    Some(trimmed.to_owned())
}

fn extract_osc8_spans_across_rows(rows: &[&[(u16, &Cell)]]) -> Vec<UrlCellSpan> {
    if rows.is_empty() {
        return Vec::new();
    }
    // Concatenate soft-wrapped full-width runs so wrapped URLs emit one URI.
    let max_width = rows.iter().map(|row| row.len()).max().unwrap_or(0);
    let mut result = Vec::new();
    let mut group_start = 0usize;
    while group_start < rows.len() {
        let mut group_end = group_start + 1;
        while group_end < rows.len() {
            let prev = rows[group_end - 1];
            let next = rows[group_end];
            let prev_at_edge = prev.len() == max_width
                && prev
                    .last()
                    .is_some_and(|(_, cell)| !cell.symbol().trim().is_empty());
            let next_contiguous =
                !next.is_empty() && next[0].0 == 0 && !next[0].1.symbol().trim().is_empty();
            if prev_at_edge && next_contiguous {
                group_end += 1;
            } else {
                break;
            }
        }
        let mut combined = String::new();
        let mut ranges: Vec<(usize, usize, usize, usize)> = Vec::new();
        for (row_offset, row) in rows[group_start..group_end].iter().enumerate() {
            let row_index = group_start + row_offset;
            for (cell_idx, (_, cell)) in row.iter().enumerate() {
                let start = combined.len();
                combined.push_str(cell.symbol());
                let end = combined.len();
                ranges.push((start, end, row_index, cell_idx));
            }
        }
        let mut cursor = 0usize;
        while cursor < combined.len() {
            let rest = &combined[cursor..];
            let rel_start = [rest.find("https://"), rest.find("http://")]
                .into_iter()
                .flatten()
                .min();
            let Some(offset) = rel_start else {
                break;
            };
            let byte_start = cursor + offset;
            let boundary_ok = byte_start == 0
                || combined[..byte_start]
                    .chars()
                    .next_back()
                    .is_some_and(|ch| {
                        ch.is_whitespace() || matches!(ch, '(' | '[' | '<' | '\'' | '"' | ',')
                    });
            if !boundary_ok {
                cursor = byte_start + 1;
                continue;
            }
            if let Some(url) = clean_osc8_url(&combined[byte_start..]) {
                let byte_end = byte_start + url.len();
                let mut per_row: BTreeMap<usize, (usize, usize)> = BTreeMap::new();
                for &(c_start, c_end, row_index, cell_idx) in &ranges {
                    if c_end > byte_start && c_start < byte_end {
                        per_row
                            .entry(row_index)
                            .and_modify(|entry| {
                                entry.0 = entry.0.min(cell_idx);
                                entry.1 = entry.1.max(cell_idx + 1);
                            })
                            .or_insert((cell_idx, cell_idx + 1));
                    }
                }
                for (row_index, (start_cell, end_cell)) in per_row {
                    result.push(UrlCellSpan {
                        row_index,
                        start_cell,
                        end_cell,
                        url: url.clone(),
                    });
                }
                cursor = byte_end;
            } else {
                cursor = byte_start + 1;
            }
        }
        group_start = group_end;
    }
    result
}

impl<W: Write> Backend for ScrollbackBackend<W> {
    type Error = std::io::Error;

    fn draw<'a, I>(&mut self, content: I) -> std::io::Result<()>
    where
        I: Iterator<Item = (u16, u16, &'a Cell)>,
    {
        if !self.osc8_active {
            return self.inner.draw(content);
        }
        type CellItem<'a> = (u16, u16, &'a Cell);
        let items: Vec<CellItem<'a>> = content.collect();
        if items.is_empty() {
            return Ok(());
        }
        let mut row_slices: Vec<(u16, &[CellItem<'a>])> = Vec::new();
        let mut start = 0usize;
        for idx in 1..=items.len() {
            let split = idx == items.len()
                || items[idx].1 != items[start].1
                || items[idx].0 != items[idx - 1].0 + 1;
            if split {
                row_slices.push((items[start].1, &items[start..idx]));
                start = idx;
            }
        }
        let simple_rows: Vec<Vec<(u16, &'a Cell)>> = row_slices
            .iter()
            .map(|(_, slice)| slice.iter().map(|&(x, _, cell)| (x, cell)).collect())
            .collect();
        let row_refs: Vec<&[(u16, &'a Cell)]> = simple_rows.iter().map(Vec::as_slice).collect();
        let spans = extract_osc8_spans_across_rows(&row_refs);
        if spans.is_empty() {
            return self.inner.draw(items.into_iter());
        }
        let mut by_row: Vec<Vec<&UrlCellSpan>> = vec![Vec::new(); row_slices.len()];
        for span in &spans {
            by_row[span.row_index].push(span);
        }
        for (row_idx, (y, row)) in row_slices.iter().enumerate() {
            let mut col_cursor = 0usize;
            for span in &by_row[row_idx] {
                if span.start_cell > col_cursor {
                    self.inner.draw(
                        row[col_cursor..span.start_cell]
                            .iter()
                            .map(|&(x, _, cell)| (x, *y, cell)),
                    )?;
                }
                write!(&mut self.inner, "\x1b]8;;{}\x1b\\", span.url)?;
                self.inner.draw(
                    row[span.start_cell..span.end_cell]
                        .iter()
                        .map(|&(x, _, cell)| (x, *y, cell)),
                )?;
                self.inner.write_all(b"\x1b]8;;\x1b\\")?;
                col_cursor = span.end_cell;
            }
            if col_cursor < row.len() {
                self.inner
                    .draw(row[col_cursor..].iter().map(|&(x, _, cell)| (x, *y, cell)))?;
            }
        }
        Ok(())
    }

    fn hide_cursor(&mut self) -> std::io::Result<()> {
        self.inner.hide_cursor()
    }

    fn show_cursor(&mut self) -> std::io::Result<()> {
        self.inner.show_cursor()
    }

    fn get_cursor_position(&mut self) -> std::io::Result<Position> {
        self.inner.get_cursor_position()
    }

    fn set_cursor_position<P: Into<Position>>(&mut self, position: P) -> std::io::Result<()> {
        self.inner.set_cursor_position(position)
    }

    fn clear(&mut self) -> std::io::Result<()> {
        self.inner.clear()
    }

    fn clear_region(&mut self, clear_type: BackendClearType) -> std::io::Result<()> {
        self.inner.clear_region(clear_type)
    }

    fn append_lines(&mut self, n: u16) -> std::io::Result<()> {
        self.inner.append_lines(n)
    }

    fn size(&self) -> std::io::Result<Size> {
        self.inner.size()
    }

    fn window_size(&mut self) -> std::io::Result<WindowSize> {
        self.inner.window_size()
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Backend::flush(&mut self.inner)
    }
}

#[cfg(test)]
mod tests {
    use super::{ScrollbackBackend, ScrollbackLinks};
    use ratatui::{backend::Backend, buffer::Buffer, layout::Rect, style::Style};
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Default)]
    struct SharedBuf(Arc<Mutex<Vec<u8>>>);

    impl std::io::Write for SharedBuf {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(buf);
            Ok(buf.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn osc_8_hyperlinks_wrap_urls_in_completed_scrollback_without_altering_layout() {
        let captured = SharedBuf::default();
        let mut backend = ScrollbackBackend::new(captured.clone());
        backend.set_osc8(true);
        let text = "Source (https://example.com/a_(b)) and https://example.org/docs.";
        let width = text.chars().count() as u16;
        let area = Rect::new(0, 0, width, 1);
        let mut buffer = Buffer::empty(area);
        buffer.set_string(0, 0, text, Style::default());
        backend
            .draw((0..width).map(|x| (x, 0, &buffer[(x, 0)])))
            .unwrap();
        let bytes = String::from_utf8(captured.0.lock().unwrap().clone()).unwrap();
        assert!(
            bytes.contains("\x1b]8;;https://example.com/a_(b)\x1b\\"),
            "{bytes:?}"
        );
        assert!(
            bytes.contains("\x1b]8;;https://example.org/docs\x1b\\"),
            "{bytes:?}"
        );
        assert_eq!(bytes.matches("\x1b]8;;\x1b\\").count(), 2, "{bytes:?}");

        // Non-scrollback draws emit zero OSC 8 hyperlinks.
        let plain_captured = SharedBuf::default();
        let mut plain_backend = ScrollbackBackend::new(plain_captured.clone());
        plain_backend
            .draw((0..width).map(|x| (x, 0, &buffer[(x, 0)])))
            .unwrap();
        let plain_bytes = String::from_utf8(plain_captured.0.lock().unwrap().clone()).unwrap();
        assert!(!plain_bytes.contains("\x1b]8;;"), "{plain_bytes:?}");

        let dev_captured = SharedBuf::default();
        let mut dev_backend = ScrollbackBackend::new(dev_captured.clone());
        dev_backend.set_osc8(true);
        let dev_text = "Dev: http://localhost:5173/app and http://127.0.0.1:8080/healthz";
        let dev_width = dev_text.chars().count() as u16;
        let mut dev_buf = Buffer::empty(Rect::new(0, 0, dev_width, 1));
        dev_buf.set_string(0, 0, dev_text, Style::default());
        dev_backend
            .draw((0..dev_width).map(|x| (x, 0, &dev_buf[(x, 0)])))
            .unwrap();
        let dev_bytes = String::from_utf8(dev_captured.0.lock().unwrap().clone()).unwrap();
        assert!(
            dev_bytes.contains("\x1b]8;;http://localhost:5173/app\x1b\\"),
            "{dev_bytes:?}"
        );
        assert!(
            dev_bytes.contains("\x1b]8;;http://127.0.0.1:8080/healthz\x1b\\"),
            "{dev_bytes:?}"
        );
    }
}
