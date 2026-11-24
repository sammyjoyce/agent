/**
 * Watching a terminal's text change, and the waits built from it.
 *
 * `watch` reads the terminal once when it starts, so output already on screen is seen, and again
 * after each burst of output that activity reports. It subscribes to activity before its first
 * read, and reads again whenever more output arrives during a read, so every output byte is
 * covered by a read that started after the byte arrived. A quiet terminal costs no reads.
 *
 * @since 0.1.0
 */
import { Duration, Effect, Option, Queue, Scope, Stream } from "effect";
import { RexRequestTimeout, RexTerminalExited } from "./rex-errors.ts";
import type { RexBlockTarget } from "./rex-operation.ts";
import {
  findRexOutputMatch,
  type RexOutputMatch,
  type RexOutputPattern,
  type RexOutputQuery,
} from "./rex-output-query.ts";
import type { RexTerminalActivity } from "./rex-terminal-activity.ts";
import type { RexTerminalText } from "./rex-terminal-text.ts";

/**
 * A terminal's text at one moment.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalFrame {
  readonly text: RexTerminalText;
  /** The program's exit code once it exited; the last frame of a watch carries it. */
  readonly exit: Option.Option<number>;
}

/**
 * Options for `terminals.watch`.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexWatchOptions {
  /** How much of the end of the output each frame holds, in bytes; defaults to 65536. */
  readonly tailBytes?: number | undefined;
  /** How long to let a burst of output continue before reading; defaults to 100 milliseconds. */
  readonly settle?: Duration.Input | undefined;
}

/**
 * Options for `terminals.waitForOutput`.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexWaitForOutputOptions extends RexWatchOptions {
  /** How long to wait before failing with `RexRequestTimeout`; waits forever when left out. */
  readonly timeout?: Duration.Input | undefined;
}

/**
 * Options for `terminals.waitForQuiet`.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexWaitForQuietOptions {
  /** How long the program must write nothing. */
  readonly quietFor: Duration.Input;
  /** How long to wait before failing with `RexRequestTimeout`; waits forever when left out. */
  readonly timeout?: Duration.Input | undefined;
}

/** What `watch` and the waits need from the terminal service. */
export interface RexTerminalWatchDeps<E> {
  readonly activity: (target: RexBlockTarget) => Stream.Stream<RexTerminalActivity, E>;
  readonly readTail: (
    target: RexBlockTarget,
    options: { readonly maxBytes: number },
  ) => Effect.Effect<RexTerminalText, E>;
  /** The exit code of a program that exited before the watch started. */
  readonly lastExit: (target: RexBlockTarget) => Effect.Effect<Option.Option<number>, E>;
}

type ActivityItem<E> =
  | RexTerminalActivity
  | { readonly _tag: "End" }
  | { readonly _tag: "Fail"; readonly error: E };

/** Consumes an activity stream into a queue of items, in the current scope. */
function subscribeActivity<E>(
  activity: Stream.Stream<RexTerminalActivity, E>,
): Effect.Effect<Queue.Queue<ActivityItem<E>>, never, Scope.Scope> {
  return Effect.gen(function* () {
    const items = yield* Queue.unbounded<ActivityItem<E>>();
    yield* Effect.forkScoped(
      Stream.runForEach(activity, (item) => Queue.offer(items, item)).pipe(
        Effect.matchEffect({
          onSuccess: () => Queue.offer(items, { _tag: "End" }),
          onFailure: (error) => Queue.offer(items, { _tag: "Fail", error }),
        }),
      ),
    );
    return items;
  });
}

/** Takes items until `Ready`, failing or ending as the activity does. */
function awaitReady<E>(items: Queue.Queue<ActivityItem<E>>): Effect.Effect<boolean, E> {
  return Effect.gen(function* () {
    while (true) {
      const item = yield* Queue.take(items);
      if (item._tag === "Ready") return true;
      if (item._tag === "Fail") return yield* Effect.fail(item.error);
      if (item._tag === "End") return false;
    }
  });
}

/**
 * Streams the terminal's text: once at the start, then after each burst of output, and a last
 * time after the program exits. Ends after the frame that carries the exit.
 *
 * @category constructors
 * @since 0.1.0
 */
export function watchRexTerminal<E>(
  deps: RexTerminalWatchDeps<E>,
  target: RexBlockTarget,
  options: RexWatchOptions = {},
): Stream.Stream<RexTerminalFrame, E> {
  const maxBytes = options.tailBytes ?? 65_536;
  const settle = options.settle ?? Duration.millis(100);
  return Stream.callback<RexTerminalFrame, E>((queue) =>
    Effect.gen(function* () {
      const items = yield* subscribeActivity(deps.activity(target));
      const live = yield* awaitReady(items);
      let exit = yield* deps.lastExit(target);
      let ended = !live;
      while (true) {
        const text = yield* deps.readTail(target, { maxBytes });
        yield* Queue.offer(queue, { text, exit });
        if (Option.isSome(exit) || ended) {
          yield* Queue.end(queue);
          return;
        }
        // Wait for output, let the burst settle, then take everything that arrived, so the next
        // read starts after all of it.
        const pending = [yield* Queue.take(items)];
        yield* Effect.sleep(settle);
        pending.push(...(yield* Queue.clear(items)));
        for (const item of pending) {
          if (item._tag === "Fail") return yield* Effect.fail(item.error);
          if (item._tag === "End") ended = true;
          if (item._tag === "Exited") exit = Option.some(item.exitCode);
        }
      }
    }),
  );
}

function timeoutAs<A, E>(
  method: string,
  timeout: Duration.Input | undefined,
  effect: Effect.Effect<A, E>,
): Effect.Effect<A, E | RexRequestTimeout> {
  if (timeout === undefined) return effect;
  const duration = Duration.fromInputUnsafe(timeout);
  return effect.pipe(
    Effect.timeoutOrElse({
      duration,
      orElse: () => Effect.fail(new RexRequestTimeout(method, "", Duration.toMillis(duration))),
    }),
  );
}

/**
 * Watches until a frame matches `query`, returning the bottom-most match of the first frame that
 * has one. Fails with `RexTerminalExited` when the program exits, or its output ends, with no
 * match, and with `RexRequestTimeout` when `timeout` passes first.
 *
 * @category constructors
 * @since 0.1.0
 */
export function waitForRexOutput<E>(
  deps: RexTerminalWatchDeps<E>,
  target: RexBlockTarget,
  query: RexOutputPattern | RexOutputQuery,
  options: RexWaitForOutputOptions = {},
): Effect.Effect<RexOutputMatch, E | RexTerminalExited | RexRequestTimeout> {
  const search = Effect.gen(function* () {
    let lastExit = Option.none<number>();
    const found = yield* watchRexTerminal(deps, target, options).pipe(
      Stream.map((frame) => {
        lastExit = frame.exit;
        return findRexOutputMatch(frame.text, query);
      }),
      Stream.filter(Option.isSome),
      Stream.runHead,
    );
    if (Option.isSome(found)) return found.value.value;
    return yield* new RexTerminalExited(target.blockId, lastExit);
  });
  return timeoutAs("TerminalService.waitForOutput", options.timeout, search);
}

/**
 * Waits until the program has written nothing for `quietFor`, or has exited. Use it for programs
 * that print no line to wait for, such as a prompt or a full-screen program settling.
 *
 * @category constructors
 * @since 0.1.0
 */
export function waitForRexQuiet<E>(
  deps: RexTerminalWatchDeps<E>,
  target: RexBlockTarget,
  options: RexWaitForQuietOptions,
): Effect.Effect<void, E | RexRequestTimeout> {
  const quietFor = Duration.fromInputUnsafe(options.quietFor);
  const wait = Effect.scoped(
    Effect.gen(function* () {
      const items = yield* subscribeActivity(deps.activity(target));
      if (!(yield* awaitReady(items))) return;
      while (true) {
        const next = yield* Effect.timeoutOption(Queue.take(items), quietFor);
        if (Option.isNone(next)) return;
        const item = next.value;
        if (item._tag === "Fail") return yield* Effect.fail(item.error);
        if (item._tag === "Exited" || item._tag === "End") return;
      }
    }),
  );
  return timeoutAs("TerminalService.waitForQuiet", options.timeout, wait);
}
