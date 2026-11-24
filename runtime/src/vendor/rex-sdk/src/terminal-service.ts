/**
 * Terminal blocks: typing, reading the screen, process state, size, theme, output streams, and
 * file transfers with the terminal's machine.
 *
 * @since 0.1.0
 */
import { Context, Duration, Effect, Layer, Option, Stream } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexConfig, rexConfigLayer } from "./rex-config.ts";
import { RexControl, type RexRequestOptions } from "./rex-control.ts";
import { rexCoreLayerWithoutDependencies } from "./rex-core.ts";
import { openRexTerminalStream, type RexTerminalStreamOptions } from "./rex-terminal-stream.ts";
import {
  RexBlockClosed,
  RexInvalidResponse,
  RexRequestTimeout,
  type RexConfigurationError,
  type RexDataError,
  type RexEventsLost,
  type RexOperationError,
  type RexTerminalExited,
} from "./rex-errors.ts";
import { takeRexEvent } from "./rex-events.ts";
import type { RexOutputMatch, RexOutputPattern, RexOutputQuery } from "./rex-output-query.ts";
import {
  makeRexTerminalActivity,
  type RexTerminalActivity,
  type RexTerminalActivityError,
} from "./rex-terminal-activity.ts";
import {
  makeRexTerminalText,
  markRexTerminalText,
  type RexTerminalMark,
  type RexTerminalText,
} from "./rex-terminal-text.ts";
import {
  waitForRexOutput,
  waitForRexQuiet,
  watchRexTerminal,
  type RexTerminalFrame,
  type RexWaitForOutputOptions,
  type RexWaitForQuietOptions,
  type RexWatchOptions,
} from "./rex-terminal-watch.ts";
import { makeRexFileTransfer, type IRexFileTransfer } from "./rex-file-transfer.ts";
import type { RexTerminalStreamItem } from "./rex-terminal-stream.ts";
import {
  rexBlockMethodOperation,
  rexBlockNoArgsOperation,
  type RexBlockMethodOperation,
  type RexBlockNoArgsOperation,
  type RexBlockMethodArgs,
  type RexBlockTarget,
} from "./rex-operation.ts";

/**
 * How a terminal's program exited.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalExit {
  /** The program's exit code, or -1 if it has none, as when a signal ended it. */
  readonly exitCode: number;
  /** Why the program failed, such as `exit status 1`; none when it succeeded. */
  readonly error: Option.Option<string>;
}

/**
 * Options for {@link ITerminalService.waitForExit}.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexWaitForExitOptions {
  /** How long to wait before failing with `RexRequestTimeout`; waits forever when left out. */
  readonly timeout?: Duration.Input | undefined;
}

/**
 * Terminal block operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface ITerminalService extends IRexFileTransfer {
  /** `com.superlogical.terminal.write`: types text into the terminal as if the user typed it; returns once queued. */
  readonly write: RexBlockMethodOperation<"com.superlogical.terminal.write">;
  /** `com.superlogical.terminal.format`: the screen and scrollback as text, HTML, or escape sequences; may return only the first part. */
  readonly format: RexBlockMethodOperation<"com.superlogical.terminal.format">;
  /** `com.superlogical.terminal.blob_read`: reads part of a result too large for one reply, such as a long format result. */
  readonly blobRead: RexBlockMethodOperation<"com.superlogical.terminal.blob_read">;
  /** `com.superlogical.terminal.clear`: clears the screen and scrollback, keeping the current line. */
  readonly clear: RexBlockNoArgsOperation<"com.superlogical.terminal.clear">;
  /** `com.superlogical.terminal.reset`: resets the terminal to its starting state; the program keeps running. */
  readonly reset: RexBlockNoArgsOperation<"com.superlogical.terminal.reset">;
  /** `com.superlogical.terminal.resize`: requests a size in columns and rows; it applies when this client owns the block or nobody does. */
  readonly resize: RexBlockMethodOperation<"com.superlogical.terminal.resize">;
  /** `com.superlogical.terminal.size`: the terminal's size, its owner, and the size each client requested. */
  readonly size: RexBlockNoArgsOperation<"com.superlogical.terminal.size">;
  /** `com.superlogical.terminal.set_theme`: replaces the terminal's default colors. */
  readonly setTheme: RexBlockMethodOperation<"com.superlogical.terminal.set_theme">;
  /** `com.superlogical.terminal.title`: the terminal's title and the process that set it. */
  readonly title: RexBlockNoArgsOperation<"com.superlogical.terminal.title">;
  /** `com.superlogical.terminal.pwd`: the working directory a program in the terminal last reported. */
  readonly pwd: RexBlockNoArgsOperation<"com.superlogical.terminal.pwd">;
  /** `com.superlogical.terminal.process`: the processes running in the terminal and how its program exited. */
  readonly process: RexBlockNoArgsOperation<"com.superlogical.terminal.process">;
  /** `com.superlogical.terminal.modes`: the terminal modes programs can turn on, such as the alternate screen. */
  readonly modes: RexBlockNoArgsOperation<"com.superlogical.terminal.modes">;
  /** `com.superlogical.terminal.input_mode`: how the terminal handles typed input, such as whether it is echoed. */
  readonly inputMode: RexBlockNoArgsOperation<"com.superlogical.terminal.input_mode">;
  /** `com.superlogical.terminal.list_dir`: subdirectories, and optionally files, of a directory as the terminal resolves it. */
  readonly listDir: RexBlockMethodOperation<"com.superlogical.terminal.list_dir">;
  /** `com.superlogical.terminal.clipboard_read`: text a program in the terminal copied to the clipboard. */
  readonly clipboardRead: RexBlockMethodOperation<"com.superlogical.terminal.clipboard_read">;
  /** `com.superlogical.terminal.program_status`: statuses programs reported with OSC 7501, such as working or blocked. */
  readonly programStatus: RexBlockNoArgsOperation<"com.superlogical.terminal.program_status">;
  /**
   * `com.superlogical.terminal.ports`: the TCP ports programs in the terminal listen on, and the
   * processes that hold them. A truncated result names a blob to read the rest with `blobRead`.
   */
  readonly ports: RexBlockNoArgsOperation<"com.superlogical.terminal.ports">;
  /**
   * The whole screen and scrollback, reading every part of a long result with `blob_read`.
   *
   * `maxBytes` sets the size of each part (default 512 KiB), so results larger than one
   * message never fail with `too_large`.
   */
  readonly read: (
    target: RexBlockTarget,
    args?: RexBlockMethodArgs<"com.superlogical.terminal.format">,
    options?: RexRequestOptions,
  ) => Effect.Effect<string, RexOperationError>;
  /**
   * The end of the screen and scrollback as lines with their byte offsets: the whole lines in its
   * last `maxBytes` bytes (default 65536), read from one consistent snapshot. Cheaper than `read`
   * on long output whenever the tail fits in one `blob_read`.
   */
  readonly readTail: (
    target: RexBlockTarget,
    options?: { readonly maxBytes?: number | undefined },
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<RexTerminalText, RexOperationError>;
  /**
   * Marks the current end of the output. Make one before typing a command, then pass it as a
   * query's `since` to match only what the command printed.
   */
  readonly mark: (
    target: RexBlockTarget,
    requestOptions?: RexRequestOptions,
  ) => Effect.Effect<RexTerminalMark, RexOperationError>;
  /**
   * A signal of the program's output and exit: `Ready` once subscribed, then `Output` byte counts
   * and `Exited`. Shares one data connection per block with every other subscriber, so it can be
   * used by many waits at once, but not together with `stream` on the same block.
   */
  readonly activity: (
    target: RexBlockTarget,
  ) => Stream.Stream<RexTerminalActivity, RexTerminalActivityError>;
  /**
   * The terminal's text once at the start, again after each burst of output, and a last time
   * after the program exits. Reads nothing while the terminal is quiet.
   */
  readonly watch: (
    target: RexBlockTarget,
    options?: RexWatchOptions,
  ) => Stream.Stream<RexTerminalFrame, RexTerminalActivityError>;
  /**
   * Watches until a line matches the query, returning the bottom-most match. Output already on
   * screen counts; give the query a `since` mark to count only output written after it.
   *
   * Fails with `RexTerminalExited` when the program exits with no match, and with
   * `RexRequestTimeout` if `timeout` passes first.
   */
  readonly waitForOutput: (
    target: RexBlockTarget,
    query: RexOutputPattern | RexOutputQuery,
    options?: RexWaitForOutputOptions,
  ) => Effect.Effect<RexOutputMatch, RexTerminalActivityError | RexTerminalExited>;
  /**
   * Waits until the program has written nothing for `quietFor`, or has exited. Fails with
   * `RexRequestTimeout` if `timeout` passes first.
   */
  readonly waitForQuiet: (
    target: RexBlockTarget,
    options: RexWaitForQuietOptions,
  ) => Effect.Effect<void, RexTerminalActivityError>;
  /** Types a line of text and presses Return. */
  readonly writeLine: (
    target: RexBlockTarget,
    text: string,
    options?: RexRequestOptions,
  ) => Effect.Effect<void, RexOperationError>;
  /**
   * Waits for the terminal's program to exit; returns at once if it already has.
   *
   * After an `event_dropped` that may have been this block's exit or close, it reads the exit
   * again with `process` instead of waiting for an event that will never arrive.
   *
   * Fails with `RexBlockClosed` if the block closes without reporting an exit, and with
   * `RexRequestTimeout` if `timeout` passes first.
   */
  readonly waitForExit: (
    target: RexBlockTarget,
    options?: RexWaitForExitOptions,
  ) => Effect.Effect<RexTerminalExit, RexOperationError | RexEventsLost | RexBlockClosed>;
  /**
   * The terminal's output stream: a snapshot of the screen, then everything its program writes,
   * with Rex's resize, theme, and exit messages in place.
   *
   * Uses a data connection (`data.connect`, `/api/data`), resuming it when it drops.
   */
  readonly stream: (
    target: RexBlockTarget,
    options?: RexTerminalStreamOptions,
  ) => Stream.Stream<RexTerminalStreamItem, RexDataError | RexOperationError>;
}

/**
 * Yieldable terminal service.
 *
 * @category services
 * @since 0.1.0
 */
export class TerminalService extends Context.Service<TerminalService, ITerminalService>()(
  "rex-sdk/TerminalService",
) {}

/**
 * The last `tailBytes` bytes of the output as whole lines.
 *
 * `content` is a suffix of the output that ends at byte `end`, the end of the output. Lines are
 * placed by counting back from `end`, so `content` may start inside a character: Rex shows the
 * cut bytes as U+FFFD, which only changes the length of text before the first kept line. A line
 * that starts before the window is dropped; one that starts exactly at its first byte is kept.
 * See `docs/research/rex-blob-read.md`.
 */
function rexTerminalTail(content: string, end: number, tailBytes: number): RexTerminalText {
  const bytes = Buffer.from(content, "utf8");
  const cutoff = bytes.length - tailBytes;
  if (cutoff <= 0) return makeRexTerminalText(content, end - bytes.length, end > bytes.length);
  // A newline byte never occurs inside a UTF-8 character or a U+FFFD, so the first one at or
  // after the byte before the window ends a line that started before it.
  const newline = bytes.indexOf(0x0a, cutoff - 1);
  const kept = bytes.subarray(newline === -1 ? bytes.length : newline + 1);
  return makeRexTerminalText(kept.toString("utf8"), end - kept.length, true);
}

/** The most data one `blob_read` returns; Rex lowers larger `max_bytes` to this. */
const maxBlobReadBytes = 983_040;

/**
 * Constructs terminal operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeTerminalService = Effect.gen(function* () {
  const config = yield* RexConfig;
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const format = rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.format");
  const blobRead = rexBlockMethodOperation(
    control,
    attachments,
    "com.superlogical.terminal.blob_read",
  );
  const write = rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.write");
  const process = rexBlockNoArgsOperation(
    control,
    attachments,
    "com.superlogical.terminal.process",
  );

  const read = Effect.fn("TerminalService.read")(function* (
    target: RexBlockTarget,
    args: RexBlockMethodArgs<"com.superlogical.terminal.format"> = {},
    options?: RexRequestOptions,
  ) {
    const first = yield* format(target, { maxBytes: 524_288, ...args }, options);
    if (Option.isNone(first.id)) return first.content;
    const parts = [first.content];
    let offset = Buffer.byteLength(first.content);
    while (true) {
      const part = yield* blobRead(
        target,
        { id: first.id.value, offset, maxBytes: args.maxBytes ?? 524_288 },
        options,
      );
      parts.push(part.data);
      offset += Buffer.byteLength(part.data);
      if (part.eof) return parts.join("");
      if (part.data.length === 0) {
        return yield* new RexInvalidResponse(
          "com.superlogical.terminal.blob_read",
          undefined,
          "a part was empty before the end of the result",
        );
      }
    }
  });

  const waitForExit = Effect.fn("TerminalService.waitForExit")(function* (
    target: RexBlockTarget,
    options: RexWaitForExitOptions = {},
  ) {
    const wait = Effect.scoped(
      Effect.gen(function* () {
        const events = yield* control.subscribe;
        const state = yield* process(target);
        if (Option.isSome(state.lastExit)) return state.lastExit.value;
        // Rereads the exit after a dropped event that may have been child_exited or block_closed.
        const recheck = process(target).pipe(
          Effect.map((current) => current.lastExit),
          Effect.catchTags({
            RexNotFound: () => Effect.fail(new RexBlockClosed(target.blockId)),
            RexSessionNotFound: () => Effect.fail(new RexBlockClosed(target.blockId)),
          }),
        );
        while (true) {
          const event = yield* takeRexEvent(events);
          if (
            event._tag === "ServerEvent" &&
            event.type === "event_dropped" &&
            Option.contains(event.payload.sessionId, target.sessionId) &&
            (Option.contains(event.payload.blockId, target.blockId) ||
              event.payload.eventType === "block_closed")
          ) {
            const exit = yield* recheck;
            if (Option.isSome(exit)) return exit.value;
          }
          if (
            event._tag === "TerminalEvent" &&
            event.blockId === target.blockId &&
            event.name === "child_exited"
          ) {
            return { exitCode: event.payload.exitCode, error: event.payload.error };
          }
          if (
            event._tag === "SessionEvent" &&
            event.type === "block_closed" &&
            event.payload.blockId === target.blockId
          ) {
            return yield* new RexBlockClosed(target.blockId);
          }
        }
      }),
    );
    if (options.timeout === undefined) return yield* wait;
    const timeout = Duration.fromInputUnsafe(options.timeout);
    return yield* wait.pipe(
      Effect.timeoutOrElse({
        duration: timeout,
        orElse: () =>
          Effect.fail(
            new RexRequestTimeout("TerminalService.waitForExit", "", Duration.toMillis(timeout)),
          ),
      }),
    );
  });

  const readTail = Effect.fn("TerminalService.readTail")(function* (
    target: RexBlockTarget,
    options: { readonly maxBytes?: number | undefined } = {},
    requestOptions?: RexRequestOptions,
  ) {
    const tailBytes = options.maxBytes ?? 65_536;
    const args = { trim: true, unwrap: true } as const;
    const first = yield* format(
      target,
      { ...args, maxBytes: Math.min(tailBytes, 65_536) },
      requestOptions,
    );
    if (Option.isNone(first.id)) {
      return rexTerminalTail(first.content, Buffer.byteLength(first.content), tailBytes);
    }
    const id = first.id.value;
    const firstBytes = Buffer.byteLength(first.content);
    // Jump past the long middle when one read from the byte before the window could reach the
    // end. That read may start inside a character, so no offset is ever computed from it: it is
    // used only if it reaches the end, placed by counting back from `total`.
    if (Option.isSome(first.total)) {
      const total = first.total.value;
      const before = total - tailBytes - 1;
      if (before > firstBytes && tailBytes < maxBlobReadBytes) {
        const part = yield* blobRead(
          target,
          { id, offset: before, maxBytes: maxBlobReadBytes },
          requestOptions,
        );
        if (part.eof) return rexTerminalTail(part.data, total, tailBytes);
      }
    }
    // Read forward from the end of the first part: every read starts on a character, so adding
    // each part's length gives the next offset exactly.
    const parts = [first.content];
    let offset = firstBytes;
    while (true) {
      const part = yield* blobRead(target, { id, offset, maxBytes: 524_288 }, requestOptions);
      parts.push(part.data);
      offset += Buffer.byteLength(part.data);
      if (part.eof) return rexTerminalTail(parts.join(""), offset, tailBytes);
      if (part.data.length === 0) {
        return yield* new RexInvalidResponse(
          "com.superlogical.terminal.blob_read",
          undefined,
          "a part was empty before the end of the result",
        );
      }
    }
  });

  const activity = yield* makeRexTerminalActivity((target) =>
    openRexTerminalStream(config, control, attachments, target),
  );
  const watchDeps = {
    activity,
    readTail: (target: RexBlockTarget, options: { readonly maxBytes: number }) =>
      readTail(target, options),
    lastExit: (target: RexBlockTarget) =>
      process(target).pipe(
        Effect.map((state) => Option.map(state.lastExit, (exit) => exit.exitCode)),
      ),
  };

  return TerminalService.of({
    ...makeRexFileTransfer(config, control, attachments),
    read,
    readTail,
    mark: (target, requestOptions) =>
      Effect.map(readTail(target, {}, requestOptions), markRexTerminalText),
    activity,
    watch: (target, options) => watchRexTerminal(watchDeps, target, options),
    waitForOutput: (target, query, options) => waitForRexOutput(watchDeps, target, query, options),
    waitForQuiet: (target, options) => waitForRexQuiet(watchDeps, target, options),
    writeLine: (target, text, options) =>
      Effect.asVoid(write(target, { data: `${text}\r` }, options)),
    waitForExit,
    stream: (target, options) =>
      openRexTerminalStream(config, control, attachments, target, options),
    write: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.write"),
    format: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.format"),
    blobRead: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.blob_read"),
    clear: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.clear"),
    reset: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.reset"),
    resize: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.resize"),
    size: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.size"),
    setTheme: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.set_theme"),
    title: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.title"),
    pwd: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.pwd"),
    process: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.process"),
    modes: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.modes"),
    inputMode: rexBlockNoArgsOperation(
      control,
      attachments,
      "com.superlogical.terminal.input_mode",
    ),
    listDir: rexBlockMethodOperation(control, attachments, "com.superlogical.terminal.list_dir"),
    clipboardRead: rexBlockMethodOperation(
      control,
      attachments,
      "com.superlogical.terminal.clipboard_read",
    ),
    programStatus: rexBlockNoArgsOperation(
      control,
      attachments,
      "com.superlogical.terminal.program_status",
    ),
    ports: rexBlockNoArgsOperation(control, attachments, "com.superlogical.terminal.ports"),
  });
});

/**
 * Terminal operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const terminalServiceLayerWithoutDependencies: Layer.Layer<
  TerminalService,
  never,
  RexControl | RexAttachments | RexConfig
> = Layer.effect(TerminalService, makeTerminalService);

/**
 * Terminal operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const terminalServiceLayer: Layer.Layer<TerminalService, RexConfigurationError> =
  terminalServiceLayerWithoutDependencies.pipe(
    Layer.provide(rexCoreLayerWithoutDependencies),
    Layer.provide(rexConfigLayer),
  );
