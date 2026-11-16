//! Reads the retained receipts of a time window. It never takes writer.lock,
//! so diagnostics never wait on a reader.
use std::{
    cmp::Reverse,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

use super::{Record, RetentionWatermark, Segment, WATERMARK_BYTES};

/// The segment the writer appends to. Its last line may be half written.
const LIVE_SEGMENT: u32 = 0;

#[derive(Debug)]
pub(crate) struct ReceiptWindow {
    pub records: Vec<Record>,
    /// None when retention.json is missing or unreadable, so loss is unknown.
    pub retention: Option<RetentionWatermark>,
    pub oldest_retained_ms: Option<u64>,
    /// Lines that are not receipts and that nothing places before the window.
    pub unplaced_lines: u32,
    pub truncated_at_ms: Option<u64>,
    pub rotated_during_read: bool,
}

/// Decides which lines that are not receipts may hide a receipt inside the
/// window. Segments are append ordered, so a bad line followed by a receipt
/// older than the window was written before the window too. That proof needs
/// honest timestamps. One that goes back, anywhere in a segment, shows that
/// the clock moved, so no receipt in that segment places a bad line.
#[derive(Default)]
struct Placement {
    /// Bad lines that no later receipt has placed yet.
    awaiting: u32,
    /// Bad lines that this segment's receipts placed before the window.
    placed_in_segment: u32,
    clock_went_back_in_segment: bool,
    previous_ms: Option<u64>,
    unplaced: u32,
}

impl Placement {
    fn bad_line(&mut self) {
        self.awaiting = self.awaiting.saturating_add(1);
    }
    fn receipt(&mut self, timestamp_ms: u64, window_start_ms: u64) {
        if self
            .previous_ms
            .is_some_and(|previous| timestamp_ms < previous)
        {
            self.clock_went_back_in_segment = true;
        }
        self.previous_ms = Some(timestamp_ms);
        if timestamp_ms < window_start_ms {
            self.placed_in_segment = self.placed_in_segment.saturating_add(self.awaiting);
        } else {
            self.unplaced = self.unplaced.saturating_add(self.awaiting);
        }
        self.awaiting = 0;
    }
    fn end_segment(&mut self) {
        if self.clock_went_back_in_segment {
            self.unplaced = self.unplaced.saturating_add(self.placed_in_segment);
        }
        self.placed_in_segment = 0;
        self.clock_went_back_in_segment = false;
    }
    /// Call after the last segment ended. A bad line with no receipt after it stays unplaced.
    fn unplaced(self) -> u32 {
        self.unplaced.saturating_add(self.awaiting)
    }
}

/// One pass over the segments, and what may have changed underneath it.
struct Pass {
    window: ReceiptWindow,
    segments_moved: bool,
    /// The live segment ended in a line with no newline that is not a receipt.
    /// The writer may be mid-append, or a crashed writer may have lost a receipt.
    unfinished_last_line: bool,
}

type SegmentIdentity = (u32, u64, u64);

fn segment_files(directory: &Path) -> io::Result<Vec<(u32, File)>> {
    let mut indexes = vec![LIVE_SEGMENT];
    for entry in fs::read_dir(directory)? {
        let name = entry?.file_name();
        if let Some(index) = name
            .to_str()
            .and_then(|name| name.strip_prefix("runtime.jsonl."))
            .and_then(|suffix| suffix.parse::<u32>().ok())
            .filter(|index| {
                *index != LIVE_SEGMENT && name == format!("runtime.jsonl.{index}").as_str()
            })
        {
            indexes.push(index);
        }
    }
    indexes.sort_unstable_by_key(|index| Reverse(*index));
    let mut files = Vec::new();
    for index in indexes {
        match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(Segment::path(directory, index))
        {
            Ok(file) if file.metadata()?.is_file() => files.push((index, file)),
            Ok(_) => {
                return Err(io::Error::other(
                    "Diagnostics segment is not a regular file",
                ));
            }
            // The writer renames and prunes without waiting for readers.
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }
    Ok(files)
}

fn identities(files: &[(u32, File)]) -> io::Result<Vec<SegmentIdentity>> {
    files
        .iter()
        .map(|(index, file)| {
            let metadata = file.metadata()?;
            Ok((*index, metadata.dev(), metadata.ino()))
        })
        .collect()
}

fn read_retention(directory: &Path) -> Option<RetentionWatermark> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(directory.join("retention.json"))
        .ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > WATERMARK_BYTES {
        return None;
    }
    let watermark: RetentionWatermark = serde_json::from_reader(file).ok()?;
    (watermark.version == 1).then_some(watermark)
}

fn read_once(
    directory: &Path,
    (start, end): (u64, u64),
    max_records: usize,
    max_bytes: u64,
) -> io::Result<Pass> {
    let retention = read_retention(directory);
    let files = match segment_files(directory) {
        Ok(files) => files,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    let before = identities(&files)?;
    let mut window = ReceiptWindow {
        records: Vec::new(),
        retention,
        oldest_retained_ms: None,
        unplaced_lines: 0,
        truncated_at_ms: None,
        rotated_during_read: false,
    };
    let mut placement = Placement::default();
    let mut unfinished_last_line = false;
    let mut bytes = 0_u64;
    for (index, file) in &files {
        let mut reader = BufReader::new(file);
        let mut line = Vec::new();
        while reader.read_until(b'\n', &mut line)? != 0 {
            bytes = bytes.saturating_add(u64::try_from(line.len()).unwrap_or(u64::MAX));
            match serde_json::from_slice::<Record>(&line) {
                Ok(record) => {
                    let timestamp = record.timestamp_ms;
                    window.oldest_retained_ms = Some(
                        window
                            .oldest_retained_ms
                            .map_or(timestamp, |oldest| oldest.min(timestamp)),
                    );
                    placement.receipt(timestamp, start);
                    if (start..end).contains(&timestamp) {
                        if window.records.len() < max_records && bytes <= max_bytes {
                            window.records.push(record);
                        } else {
                            window.truncated_at_ms = Some(
                                window
                                    .truncated_at_ms
                                    .map_or(timestamp, |cut| cut.min(timestamp)),
                            );
                        }
                    }
                }
                Err(_) => {
                    placement.bad_line();
                    unfinished_last_line |= *index == LIVE_SEGMENT && line.last() != Some(&b'\n');
                }
            }
            line.clear();
        }
        placement.end_segment();
    }
    window.unplaced_lines = placement.unplaced();
    let after = match segment_files(directory) {
        Ok(files) => identities(&files)?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(error),
    };
    Ok(Pass {
        window,
        segments_moved: before != after,
        unfinished_last_line,
    })
}

/// Reads retention.json, then every retained segment oldest first, keeping
/// receipts inside `window`. Reads once more when segments moved underneath it
/// or the writer may have been mid-append. An unfinished last line that is
/// still there on the second pass counts as a line nothing places.
pub(crate) fn read_window(
    state: &Path,
    window: (u64, u64),
    max_records: usize,
    max_bytes: u64,
) -> io::Result<ReceiptWindow> {
    let directory = state.join("diagnostics");
    let first = read_once(&directory, window, max_records, max_bytes)?;
    if !first.segments_moved && !first.unfinished_last_line {
        return Ok(first.window);
    }
    let mut second = read_once(&directory, window, max_records, max_bytes)?;
    second.window.rotated_during_read = second.segments_moved;
    Ok(second.window)
}
