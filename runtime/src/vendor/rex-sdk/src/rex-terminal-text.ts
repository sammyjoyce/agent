/**
 * A terminal's text as lines with absolute positions, and marks that tell later text which of its
 * lines are new.
 *
 * Text comes from `com.superlogical.terminal.format` with `trim` and `unwrap`, so a line is one
 * line a program wrote, whatever the terminal's width. Each line knows its byte offset from the
 * start of the whole output (screen and scrollback). Output that only grows keeps those offsets,
 * which lets a mark find its place again exactly; when scrollback is trimmed or the screen is
 * cleared, the mark falls back to finding its anchor lines, and says so.
 *
 * Everything here is pure.
 *
 * @since 0.1.0
 */
/**
 * Part or all of a terminal's screen and scrollback, as lines.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalText {
  /** The lines, oldest first, with trailing spaces and trailing blank lines removed. */
  readonly lines: ReadonlyArray<string>;
  /**
   * Where each line starts, in UTF-8 bytes from the start of the whole output as `format`
   * returned it: the same units as `blob_read`'s `offset` and `total`. The bytes at
   * `lineOffsets[i]` begin with `lines[i]`; trailing spaces the line leaves out still count.
   */
  readonly lineOffsets: ReadonlyArray<number>;
  /** True when older lines exist that this text leaves out. */
  readonly truncated: boolean;
}

/**
 * Splits `content`, which starts `start` bytes into the whole output, into lines.
 *
 * `content` must start at a line start and on a character, so each offset is `start` plus the
 * UTF-8 length of the text before it.
 *
 * @category constructors
 * @since 0.1.0
 */
export function makeRexTerminalText(
  content: string,
  start = 0,
  truncated = false,
): RexTerminalText {
  const lines: string[] = [];
  const lineOffsets: number[] = [];
  let offset = start;
  // Offsets count the raw line, including the trailing spaces it leaves out, so they stay exact.
  for (const raw of content.split("\n")) {
    lines.push(raw.replace(/[ \t\r]+$/, ""));
    lineOffsets.push(offset);
    offset += Buffer.byteLength(raw) + 1;
  }
  while (lines.length > 0 && lines.at(-1) === "") {
    lines.pop();
    lineOffsets.pop();
  }
  return { lines, lineOffsets, truncated };
}

/** How many lines before the cursor line a mark keeps to recognize its place. */
const MARK_ANCHOR_LINES = 8;

/**
 * A place in a terminal's output: everything after the line the cursor was on is new.
 *
 * Make one before typing a command, then pass it to `waitForOutput` to match only the command's
 * output, not earlier output or the typed command line itself.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalMark {
  /** Where the cursor line started, in UTF-8 bytes from the start of the whole output. */
  readonly offset: number;
  /** Up to 8 lines just before the cursor line, to confirm the offset still points there. */
  readonly anchor: ReadonlyArray<string>;
  /** False when the text was empty, so there was no cursor line and every later line is new. */
  readonly hasCursorLine: boolean;
}

/**
 * Marks the end of `text`: its last non-blank line is taken as the cursor line, such as the
 * shell prompt a command is about to be typed on.
 *
 * @category constructors
 * @since 0.1.0
 */
export function markRexTerminalText(text: RexTerminalText): RexTerminalMark {
  const cursor = text.lines.length - 1;
  if (cursor < 0) return { offset: 0, anchor: [], hasCursorLine: false };
  return {
    offset: text.lineOffsets[cursor] ?? 0,
    anchor: text.lines.slice(Math.max(0, cursor - MARK_ANCHOR_LINES), cursor),
    hasCursorLine: true,
  };
}

/**
 * How {@link linesSinceRexMark} found the mark's place:
 *
 * - `offset`: at its exact byte offset, with its anchor lines unchanged. Exact.
 * - `anchor`: by finding its anchor lines, because the offsets moved (scrollback was trimmed or
 *   text above changed). Exact unless those lines appear again later.
 * - `unaligned`: not at all (the screen was cleared, or more output arrived than the text holds),
 *   so every line counts as new.
 *
 * @category models
 * @since 0.1.0
 */
export type RexMarkAlignment = "offset" | "anchor" | "unaligned";

/**
 * The lines of `text` written after `mark`, and how the mark's place was found.
 *
 * @category utils
 * @since 0.1.0
 */
export interface RexLinesSinceMark {
  readonly lines: ReadonlyArray<string>;
  readonly alignment: RexMarkAlignment;
}

/**
 * Whether the lines just before `cursor` are the mark's anchor. Anchor lines older than the text
 * can't be checked: `cutTop` accepts that when at least `minimum` lines were checked and matched.
 */
function anchorMatchesAt(
  text: RexTerminalText,
  cursor: number,
  anchor: ReadonlyArray<string>,
  cutTop: boolean,
  minimum: number,
): boolean {
  let checked = 0;
  for (let index = 0; index < anchor.length; index++) {
    const line = cursor - anchor.length + index;
    if (line < 0) {
      if (!cutTop) return false;
      continue;
    }
    if (text.lines[line] !== anchor[index]) return false;
    checked += 1;
  }
  return checked >= minimum;
}

/** Fewest anchor lines that must match when older ones were trimmed away. */
const MIN_ANCHOR_LINES = 3;

/**
 * The lines of `text` after the cursor line of `mark`.
 *
 * The cursor line itself is never new: after a mark is made, it is where a command is typed, so
 * its text is input, not output.
 *
 * @category utils
 * @since 0.1.0
 */
export function linesSinceRexMark(text: RexTerminalText, mark: RexTerminalMark): RexLinesSinceMark {
  if (!mark.hasCursorLine) return { lines: text.lines, alignment: "offset" };
  const exact = text.lineOffsets.indexOf(mark.offset);
  // At the exact offset, anchor lines are missing only because the text is a truncated window.
  if (exact >= 0 && anchorMatchesAt(text, exact, mark.anchor, text.truncated, 0)) {
    return { lines: text.lines.slice(exact + 1), alignment: "offset" };
  }
  // Elsewhere, older anchor lines may have been trimmed from the top; the newest occurrence wins.
  const minimum = Math.min(mark.anchor.length, MIN_ANCHOR_LINES);
  if (minimum > 0) {
    for (let cursor = text.lines.length - 1; cursor >= minimum; cursor--) {
      if (anchorMatchesAt(text, cursor, mark.anchor, true, minimum)) {
        return { lines: text.lines.slice(cursor + 1), alignment: "anchor" };
      }
    }
  }
  return { lines: text.lines, alignment: "unaligned" };
}
