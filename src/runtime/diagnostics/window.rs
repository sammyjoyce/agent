use std::{
    cmp::Reverse,
    fs::{self, File, OpenOptions},
    io::{self, BufRead, BufReader},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::Path,
};

use super::{
    Event, Record, RetentionWatermark, STAMP_REORDER_TOLERANCE, Segment, WATERMARK_BYTES, now_ms,
    undelivered_drops,
};

const LIVE_SEGMENT: u32 = 0;

#[derive(Debug)]
pub(crate) struct ReceiptWindow {
    pub records: Vec<Record>,
    pub retention: Option<RetentionWatermark>,
    pub oldest_retained_ms: Option<u64>,
    pub unplaced_lines: u32,
    pub truncated_at_ms: Option<u64>,
    pub rotated_during_read: bool,
    pub undelivered_drops: u64,
    /// Drops reported by receipts stamped at or after the window end. Those
    /// receipts are outside the window, but what they report as lost before
    /// them may lie inside it.
    pub drops_reported_after_window: u64,
    /// Set when receipt timestamps prove that the clock moved around the
    /// window. A receipt near such a move may be stamped outside the window
    /// although it was written inside it, so the window cannot be trusted whole.
    pub clock_moves: Option<ClockMoves>,
    /// For each writer start whose previous receipt is not a clean stop, the
    /// timestamps of that receipt and of the start. Anything the writer before
    /// had queued or counted as dropped was lost between them.
    pub unclean_restarts: Vec<(u64, u64)>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ClockMoves {
    pub times: u32,
    pub largest_back_ms: u64,
    /// The earliest and the latest timestamp on either side of a move.
    pub span_ms: (u64, u64),
}

/// Finds timestamps that go back by more than senders can reorder them.
struct ClockWatch {
    window: (u64, u64),
    previous_ms: Option<u64>,
    moves: Option<ClockMoves>,
}

impl ClockWatch {
    fn moved(&mut self, from_ms: u64, to_ms: u64) {
        let back_ms = from_ms.saturating_sub(to_ms);
        let moves = self.moves.get_or_insert(ClockMoves {
            times: 0,
            largest_back_ms: back_ms,
            span_ms: (to_ms, from_ms),
        });
        moves.times = moves.times.saturating_add(1);
        moves.largest_back_ms = moves.largest_back_ms.max(back_ms);
        moves.span_ms = (moves.span_ms.0.min(to_ms), moves.span_ms.1.max(from_ms));
    }
    fn receipt(&mut self, timestamp_ms: u64) {
        let tolerance = u64::try_from(STAMP_REORDER_TOLERANCE.as_millis()).unwrap_or(u64::MAX);
        let (start, end) = self.window;
        // A move that lies wholly before the window hides nothing in it: every
        // receipt stamped on the old clock is older than the window either way.
        if let Some(previous) = self.previous_ms
            && previous.saturating_sub(timestamp_ms) > tolerance
            && previous >= start
            && timestamp_ms < end
        {
            self.moved(previous, timestamp_ms);
        }
        self.previous_ms = Some(timestamp_ms);
    }
    /// The last receipt has no later one to go back to. A stamp ahead of the
    /// present clock shows the move just as well.
    fn finish(mut self) -> Option<ClockMoves> {
        let tolerance = u64::try_from(STAMP_REORDER_TOLERANCE.as_millis()).unwrap_or(u64::MAX);
        let now = now_ms();
        if let Some(last) = self.previous_ms
            && last.saturating_sub(now) > tolerance
        {
            self.moved(last, now);
        }
        self.moves
    }
}

/// Decides which lines that are not receipts may hide a receipt inside the
/// window. Segments are append ordered, so a later receipt that is older than
/// the window places a bad line before the window too. That proof needs honest
/// timestamps in the segment that holds the line and in the segment that holds
/// the receipt. A timestamp that goes back in either one removes it.
#[derive(Default)]
struct Placement {
    previous_ms: Option<u64>,
    segment: SegmentPlacement,
    /// Bad lines that ended an earlier segment whose clock never went back.
    /// The next receipt, in a later segment, decides them.
    carried: u32,
    unplaced: u32,
}

#[derive(Default)]
struct SegmentPlacement {
    clock_went_back: bool,
    /// Bad lines with no receipt after them yet.
    awaiting: u32,
    /// Bad lines that a receipt of this segment placed before the window. They
    /// stay placed only if this segment's clock never goes back.
    placed_before_window: u32,
}

impl Placement {
    fn bad_line(&mut self) {
        self.segment.awaiting = self.segment.awaiting.saturating_add(1);
    }
    fn receipt(&mut self, timestamp_ms: u64, window_start_ms: u64) {
        if self
            .previous_ms
            .is_some_and(|previous| timestamp_ms < previous)
        {
            self.segment.clock_went_back = true;
        }
        self.previous_ms = Some(timestamp_ms);
        let decided = self.segment.awaiting.saturating_add(self.carried);
        if timestamp_ms < window_start_ms {
            self.segment.placed_before_window =
                self.segment.placed_before_window.saturating_add(decided);
        } else {
            self.unplaced = self.unplaced.saturating_add(decided);
        }
        self.segment.awaiting = 0;
        self.carried = 0;
    }
    fn end_segment(&mut self) {
        let segment = std::mem::take(&mut self.segment);
        if segment.clock_went_back {
            self.unplaced = self
                .unplaced
                .saturating_add(segment.placed_before_window)
                .saturating_add(segment.awaiting);
        } else {
            self.carried = self.carried.saturating_add(segment.awaiting);
        }
    }
    /// Ends the last segment. A bad line with no receipt after it stays unplaced.
    fn finish(mut self) -> u32 {
        self.end_segment();
        self.unplaced.saturating_add(self.carried)
    }
}

struct Pass {
    window: ReceiptWindow,
    segments_moved: bool,
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
        undelivered_drops: 0,
        drops_reported_after_window: 0,
        clock_moves: None,
        unclean_restarts: Vec::new(),
    };
    let mut previous: Option<(u64, bool)> = None;
    let mut clock = ClockWatch {
        window: (start, end),
        previous_ms: None,
        moves: None,
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
                    clock.receipt(timestamp);
                    if let (Event::WriterStarted, Some((last, false))) = (&record.event, previous) {
                        window.unclean_restarts.push((last, timestamp));
                    }
                    previous = Some((timestamp, matches!(record.event, Event::WriterStopped)));
                    if timestamp >= end {
                        window.drops_reported_after_window = window
                            .drops_reported_after_window
                            .saturating_add(record.dropped_before);
                    }
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
    window.unplaced_lines = placement.finish();
    window.clock_moves = clock.finish();
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

pub(crate) fn read_window(
    state: &Path,
    window: (u64, u64),
    max_records: usize,
    max_bytes: u64,
) -> io::Result<ReceiptWindow> {
    let directory = state.join("diagnostics");
    // Read before the disk pass. A writer appends the receipt that reports a
    // drop before it stops counting that drop, so a count that is gone by now
    // is already on disk for the pass to read.
    let undelivered = undelivered_drops(&directory);
    let first = read_once(&directory, window, max_records, max_bytes)?;
    let mut read = if first.segments_moved || first.unfinished_last_line {
        let mut second = read_once(&directory, window, max_records, max_bytes)?;
        second.window.rotated_during_read = second.segments_moved;
        second.window
    } else {
        first.window
    };
    read.undelivered_drops = undelivered;
    Ok(read)
}
