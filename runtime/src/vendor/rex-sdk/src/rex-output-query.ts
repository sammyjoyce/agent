/**
 * Queries over a terminal's text: which lines to look at, and what to look for in each.
 *
 * Everything here is pure, so the same query works on any {@link RexTerminalText}, from a single
 * read or from each frame of `terminals.watch`.
 *
 * @since 0.1.0
 */
import { Option } from "effect";
import {
  linesSinceRexMark,
  type RexMarkAlignment,
  type RexTerminalMark,
  type RexTerminalText,
} from "./rex-terminal-text.ts";

/**
 * What to look for in each line: a substring, or a regular expression tested against one line at
 * a time, so `^` and `$` anchor to the line. Global and sticky flags are ignored.
 *
 * @category models
 * @since 0.1.0
 */
export type RexOutputPattern = string | RegExp;

/**
 * A pattern and the lines to search for it.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexOutputQuery {
  readonly pattern: RexOutputPattern;
  /** Search only lines written after this mark, such as the output of a command typed after it. */
  readonly since?: RexTerminalMark | undefined;
  /** Search only the last `lines` of the lines left. */
  readonly lines?: number | undefined;
}

/**
 * The line a query found.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexOutputMatch {
  /** The whole line that matched. */
  readonly line: string;
  /** The text the pattern matched within the line. */
  readonly text: string;
  /** The regular expression's capture groups, in order; empty for a substring. */
  readonly groups: ReadonlyArray<string | undefined>;
  /** How the query's `since` mark was found; none when the query had no mark. */
  readonly alignment: Option.Option<RexMarkAlignment>;
}

/**
 * Accepts a bare pattern wherever a query is expected.
 *
 * @category constructors
 * @since 0.1.0
 */
export function toRexOutputQuery(query: RexOutputPattern | RexOutputQuery): RexOutputQuery {
  return typeof query === "string" || query instanceof RegExp ? { pattern: query } : query;
}

/**
 * The lines a query searches, oldest first, and how its mark was found.
 *
 * @category utils
 * @since 0.1.0
 */
export function rexOutputQueryLines(
  text: RexTerminalText,
  query: RexOutputQuery,
): { readonly lines: ReadonlyArray<string>; readonly alignment: Option.Option<RexMarkAlignment> } {
  const since = query.since === undefined ? undefined : linesSinceRexMark(text, query.since);
  const lines = since?.lines ?? text.lines;
  return {
    lines: query.lines === undefined ? lines : lines.slice(Math.max(0, lines.length - query.lines)),
    alignment: Option.fromUndefinedOr(since?.alignment),
  };
}

/**
 * The bottom-most line of `text` that `query` matches.
 *
 * @category utils
 * @since 0.1.0
 */
export function findRexOutputMatch(
  text: RexTerminalText,
  query: RexOutputPattern | RexOutputQuery,
): Option.Option<RexOutputMatch> {
  const { pattern, ...rest } = toRexOutputQuery(query);
  const { lines, alignment } = rexOutputQueryLines(text, { pattern, ...rest });
  // A global or sticky regex keeps `lastIndex` between calls; a copy without those flags does not.
  const regex =
    typeof pattern === "string"
      ? undefined
      : new RegExp(pattern.source, pattern.flags.replace(/[gy]/g, ""));
  for (let index = lines.length - 1; index >= 0; index--) {
    const line = lines[index] ?? "";
    if (regex === undefined) {
      if (typeof pattern === "string" && line.includes(pattern)) {
        return Option.some({ line, text: pattern, groups: [], alignment });
      }
      continue;
    }
    const found = regex.exec(line);
    if (found !== null) {
      return Option.some({ line, text: found[0], groups: found.slice(1), alignment });
    }
  }
  return Option.none();
}
