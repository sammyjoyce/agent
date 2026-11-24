/**
 * Terminal activity: a cheap signal that a terminal's program wrote output or exited, shared by
 * every subscriber of a block.
 *
 * Rex allows one data connection per client and block (a second is refused with
 * `already_connected`), so activity opens one terminal stream per block, however many waits and
 * watches use it, and closes it when the last one ends. The stream starts with a snapshot of the
 * screen and then a `resize` message; activity skips the snapshot and reports `Ready` once it has
 * passed, so every `Output` after `Ready` is output written after the subscription started.
 * Output bytes are counted, never parsed.
 *
 * @since 0.1.0
 */
import {
  Deferred,
  Effect,
  Exit,
  Fiber,
  Option,
  PubSub,
  Queue,
  Scope,
  Semaphore,
  Stream,
} from "effect";
import type { RexDataError, RexOperationError } from "./rex-errors.ts";
import type { RexBlockTarget } from "./rex-operation.ts";
import type { RexTerminalStreamItem } from "./rex-terminal-stream.ts";

/**
 * One activity item.
 *
 * - `Ready`: first, once the subscription sees everything written from now on.
 * - `Output`: the program wrote `bytes` bytes.
 * - `Exited`: the program exited; no more output follows. A subscriber that joins after the exit
 *   gets it right after `Ready`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalActivity =
  | { readonly _tag: "Ready" }
  | { readonly _tag: "Output"; readonly bytes: number }
  | { readonly _tag: "Exited"; readonly exitCode: number };

/**
 * Failures of an activity stream: those of the terminal stream it reads.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalActivityError = RexDataError | RexOperationError;

type FeedItem =
  | { readonly _tag: "Output"; readonly bytes: number }
  | { readonly _tag: "Exited"; readonly exitCode: number }
  | { readonly _tag: "Failed"; readonly error: RexTerminalActivityError }
  | { readonly _tag: "Ended" };

/** One block's shared terminal stream. */
interface Feed {
  readonly pubsub: PubSub.PubSub<FeedItem>;
  readonly ready: Deferred.Deferred<void, RexTerminalActivityError>;
  exitCode: Option.Option<number>;
  subscribers: number;
  fiber: Fiber.Fiber<void> | undefined;
}

/**
 * Creates the activity source for one SDK instance. Feeds run in the calling scope, so they end
 * with the SDK.
 *
 * @category constructors
 * @since 0.1.0
 */
export function makeRexTerminalActivity(
  openStream: (
    target: RexBlockTarget,
  ) => Stream.Stream<RexTerminalStreamItem, RexTerminalActivityError>,
): Effect.Effect<
  (target: RexBlockTarget) => Stream.Stream<RexTerminalActivity, RexTerminalActivityError>,
  never,
  Scope.Scope
> {
  return Effect.gen(function* () {
    const scope = yield* Effect.scope;
    const lock = yield* Semaphore.make(1);
    const feeds = new Map<string, Feed>();
    const locked = <A, E, R>(effect: Effect.Effect<A, E, R>) =>
      Semaphore.withPermits(lock, 1)(effect);

    /** Publishes a feed's last item and forgets the feed, so a later subscriber starts anew. */
    const finish = (key: string, feed: Feed, item: FeedItem) =>
      locked(
        Effect.gen(function* () {
          if (feeds.get(key) === feed) feeds.delete(key);
          yield* PubSub.publish(feed.pubsub, item);
        }),
      );

    const runFeed = (key: string, target: RexBlockTarget, feed: Feed) =>
      Stream.runForEach(openStream(target), (item) =>
        Effect.gen(function* () {
          const ready = yield* Deferred.isDone(feed.ready);
          if (item._tag === "Output") {
            // Bytes before the first `resize` are the snapshot of what was already on screen.
            if (ready)
              yield* PubSub.publish(feed.pubsub, { _tag: "Output", bytes: item.bytes.length });
            return;
          }
          const message = item.message;
          if (message.type === "resize" && !ready) {
            yield* Deferred.succeed(feed.ready, undefined);
            return;
          }
          if (message.type === "child_exited") {
            yield* locked(
              Effect.gen(function* () {
                feed.exitCode = Option.some(message.exitCode);
                yield* PubSub.publish(feed.pubsub, { _tag: "Exited", exitCode: message.exitCode });
              }),
            );
            yield* Deferred.succeed(feed.ready, undefined);
          }
        }),
      ).pipe(
        Effect.exit,
        Effect.flatMap((exit) =>
          Exit.isSuccess(exit)
            ? Effect.andThen(
                Deferred.succeed(feed.ready, undefined),
                finish(key, feed, { _tag: "Ended" }),
              )
            : Effect.gen(function* () {
                const failure = Exit.findErrorOption(exit);
                if (Option.isNone(failure)) return; // interrupted: the last subscriber left
                yield* Deferred.fail(feed.ready, failure.value);
                yield* finish(key, feed, { _tag: "Failed", error: failure.value });
              }),
        ),
      );

    return (target: RexBlockTarget) =>
      Stream.callback<RexTerminalActivity, RexTerminalActivityError>((queue) =>
        Effect.gen(function* () {
          const key = `${target.sessionId}/${target.blockId}`;
          const { feed, subscription, exitedBefore } = yield* locked(
            Effect.gen(function* () {
              let feed = feeds.get(key);
              const isNew = feed === undefined;
              if (feed === undefined) {
                feed = {
                  pubsub: yield* PubSub.unbounded<FeedItem>(),
                  ready: yield* Deferred.make<void, RexTerminalActivityError>(),
                  exitCode: Option.none(),
                  subscribers: 0,
                  fiber: undefined,
                };
                feeds.set(key, feed);
              }
              feed.subscribers += 1;
              // Subscribe before the feed starts, so nothing it publishes is missed.
              const subscription = yield* PubSub.subscribe(feed.pubsub);
              if (isNew) feed.fiber = yield* Effect.forkIn(runFeed(key, target, feed), scope);
              return { feed, subscription, exitedBefore: feed.exitCode };
            }),
          );
          yield* Effect.addFinalizer(() =>
            locked(
              Effect.gen(function* () {
                feed.subscribers -= 1;
                if (feed.subscribers > 0 || feeds.get(key) !== feed) return;
                feeds.delete(key);
                if (feed.fiber !== undefined) yield* Fiber.interrupt(feed.fiber);
              }),
            ),
          );

          yield* Deferred.await(feed.ready);
          yield* Queue.offer(queue, { _tag: "Ready" });
          if (Option.isSome(exitedBefore)) {
            yield* Queue.offer(queue, { _tag: "Exited", exitCode: exitedBefore.value });
          }
          while (true) {
            const item = yield* PubSub.take(subscription);
            switch (item._tag) {
              case "Output":
              case "Exited":
                yield* Queue.offer(queue, item);
                break;
              case "Failed":
                return yield* Effect.fail(item.error);
              case "Ended":
                yield* Queue.end(queue);
                return;
            }
          }
        }),
      );
  });
}
