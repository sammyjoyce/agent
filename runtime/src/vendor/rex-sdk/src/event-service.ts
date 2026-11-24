/**
 * Live Rex events as a `Stream`, and waiting for one event.
 *
 * Streams subscribe before they attach, so no event between attaching and reading is missed.
 * Every stream shares one control connection, whose attachments are the union of what all its
 * streams asked for, so each stream keeps only the events its own options select.
 * Each stream has its own bounded buffer; one that falls behind fails with `RexEventsLost`
 * instead of skipping events. A stream also fails with `RexEventsLost` when the connection ends,
 * because events sent while it was gone are lost. Read the state again and subscribe again.
 *
 * @since 0.1.0
 */
import { Context, Duration, Effect, Layer, Option, Queue, Stream } from "effect";
import { RexAttachments, type RexEventScope } from "./rex-attachments.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { SessionId } from "./rex-domain.ts";
import {
  RexRequestTimeout,
  type RexConfigurationError,
  type RexEventsLost,
  type RexOperationError,
} from "./rex-errors.ts";
import { rexEventSessionId, takeRexEvent, type RexEvent } from "./rex-events.ts";

/**
 * Which events a stream receives.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexEventStreamOptions {
  /**
   * Sessions to attach to; the stream receives every event from them, including block events
   * such as a terminal's `child_exited`.
   */
  readonly sessionIds?: ReadonlyArray<SessionId> | undefined;
  /**
   * Server-wide events through `session.attach_all`: `session` for session lifecycle and every
   * session's structural events, `all` to add block events and client events. Defaults to
   * `all` when `sessionIds` is left out, and to none otherwise.
   */
  readonly server?: RexEventScope | "none" | undefined;
}

/** Server events a connection receives with `event_scope: "session"` or with no attachment. */
const sessionScopeServerEvents: ReadonlySet<string> = new Set([
  "session_created",
  "session_destroyed",
  "session_moved",
  "tailscale_status_changed",
  "event_dropped",
  "keymap_changed",
  "hosts_changed",
  "client_call_requested",
  "client_perform_requested",
  "client_prompt_requested",
  "client_prompt_ended",
]);

/**
 * Whether a stream with these options should receive an event, mirroring what the server would
 * send a connection attached only as the options ask.
 *
 * Every event of a listed session is selected, including block events and its
 * `session_destroyed`. `server: "session"` adds the session lifecycle and account-wide server
 * events and every session's events except block events; `server: "all"` adds everything.
 *
 * @category predicates
 * @since 0.1.0
 */
export function rexEventStreamSelects(
  options: RexEventStreamOptions,
): (event: RexEvent) => boolean {
  const sessionIds: ReadonlySet<SessionId> = new Set(options.sessionIds ?? []);
  const server = options.server ?? (options.sessionIds === undefined ? "all" : "none");
  return (event) => {
    const sessionId = rexEventSessionId(event);
    if (Option.isSome(sessionId) && sessionIds.has(sessionId.value)) return true;
    if (server === "all") return true;
    if (server === "none") return false;
    switch (event._tag) {
      case "SessionEvent":
        return true;
      case "TerminalEvent":
      case "BlockEvent":
        return false;
      case "UnknownEvent":
        return Option.isSome(event.sessionId);
      case "ServerEvent":
        return sessionScopeServerEvents.has(event.type);
    }
  };
}

/**
 * Event operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IEventService {
  /** Every event the options select, and no other event on the shared connection, from now until the stream is interrupted or fails. */
  readonly stream: (
    options?: RexEventStreamOptions,
  ) => Stream.Stream<RexEvent, RexOperationError | RexEventsLost>;
  /**
   * The first event that `predicate` accepts. Fails with `RexRequestTimeout` if `timeout`
   * passes first.
   */
  readonly waitFor: <Event extends RexEvent>(
    predicate: (event: RexEvent) => event is Event,
    options?: RexEventStreamOptions & { readonly timeout?: Duration.Input | undefined },
  ) => Effect.Effect<Event, RexOperationError | RexEventsLost>;
}

/**
 * Yieldable event service.
 *
 * @category services
 * @since 0.1.0
 */
export class EventService extends Context.Service<EventService, IEventService>()(
  "rex-sdk/EventService",
) {}

/**
 * Constructs event operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeEventService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;

  /** Subscribes, then attaches as the options ask, so nothing in between is missed. */
  const subscribeWith = (options: RexEventStreamOptions) =>
    Effect.gen(function* () {
      const subscription = yield* control.subscribe;
      const server = options.server ?? (options.sessionIds === undefined ? "all" : "none");
      if (server !== "none") yield* attachments.ensureAttachedToAll(server);
      for (const sessionId of options.sessionIds ?? [])
        yield* attachments.ensureAttached(sessionId);
      return subscription;
    });

  const stream = (options: RexEventStreamOptions = {}) =>
    Stream.callback<RexEvent, RexOperationError | RexEventsLost>((queue) =>
      Effect.gen(function* () {
        const selects = rexEventStreamSelects(options);
        const subscription = yield* subscribeWith(options);
        while (true) {
          const event = yield* takeRexEvent(subscription);
          if (selects(event)) yield* Queue.offer(queue, event);
        }
      }),
    );

  const waitFor = <Event extends RexEvent>(
    predicate: (event: RexEvent) => event is Event,
    options: RexEventStreamOptions & { readonly timeout?: Duration.Input | undefined } = {},
  ): Effect.Effect<Event, RexOperationError | RexEventsLost> => {
    const wait = Effect.scoped(
      Effect.gen(function* () {
        const selects = rexEventStreamSelects(options);
        const subscription = yield* subscribeWith(options);
        while (true) {
          const event = yield* takeRexEvent(subscription);
          if (selects(event) && predicate(event)) return event;
        }
      }),
    );
    if (options.timeout === undefined) return wait;
    const timeout = Duration.fromInputUnsafe(options.timeout);
    return wait.pipe(
      Effect.timeoutOrElse({
        duration: timeout,
        orElse: () =>
          Effect.fail(
            new RexRequestTimeout("EventService.waitFor", "", Duration.toMillis(timeout)),
          ),
      }),
    );
  };

  return EventService.of({ stream, waitFor });
});

/**
 * Event operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const eventServiceLayerWithoutDependencies: Layer.Layer<
  EventService,
  never,
  RexControl | RexAttachments
> = Layer.effect(EventService, makeEventService);

/**
 * Event operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const eventServiceLayer: Layer.Layer<EventService, RexConfigurationError> =
  eventServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
