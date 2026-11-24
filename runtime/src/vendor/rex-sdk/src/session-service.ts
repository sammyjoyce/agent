/**
 * Sessions: listing, creating, destroying, attaching, labels, order, and live views.
 *
 * A session is a group of related work that keeps running whether or not anything shows it.
 * Explicit attach and detach calls are recorded so the SDK's automatic attachment stays
 * consistent with them.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer, Option, Queue, Stream } from "effect";
import type { SessionCreateInput, SessionViewResult } from "./generated/rex-wire-schemas.ts";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl, type RexRequestOptions } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { SessionId } from "./rex-domain.ts";
import type { RexConfigurationError, RexEventsLost, RexOperationError } from "./rex-errors.ts";
import { takeRexEvent } from "./rex-events.ts";
import { encodeRexLayout, type RexLayoutNode } from "./rex-layout.ts";
import {
  rexMethodOperation,
  rexNoInputOperation,
  type RexMethodInput,
  type RexMethodOperation,
  type RexMethodResult,
  type RexNoInputOperation,
} from "./rex-operation.ts";

/**
 * Arguments of `session.create`, with typed window layouts.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexSessionCreateInput extends Omit<SessionCreateInput, "initialWindows"> {
  /** Windows to create with the session, each with its blocks; the first becomes active. */
  readonly initialWindows?: ReadonlyArray<{
    /** The window's label. */
    readonly windowLabel?: string;
    /** The blocks to create in the window. */
    readonly layout?: RexLayoutNode;
  }>;
}

/**
 * Arguments of `session.bootstrap`, without `dataTickets`.
 *
 * Data tickets never reach callers; `terminals.stream` opens its own data connections.
 *
 * @category models
 * @since 0.1.0
 */
export type RexSessionBootstrapInput = Omit<RexMethodInput<"session.bootstrap">, "dataTickets">;

/**
 * Result of `session.bootstrap`, without `dataTickets`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexSessionBootstrapResult = Omit<RexMethodResult<"session.bootstrap">, "dataTickets">;

/**
 * Session operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface ISessionService {
  /** `session.list`: the sessions on the server, in order. */
  readonly list: RexNoInputOperation<"session.list">;
  /** `session.create`: creates a session, optionally with its first windows and blocks. */
  readonly create: (
    input?: RexSessionCreateInput,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.create">, RexOperationError>;
  /** `session.destroy`: destroys a session and closes every block in it. */
  readonly destroy: RexMethodOperation<"session.destroy">;
  /** `session.view`: the session's windows, layouts, and blocks in one snapshot. */
  readonly view: RexMethodOperation<"session.view">;
  /** `session.attach`: attaches this connection, receiving the session's events and its view. */
  readonly attach: RexMethodOperation<"session.attach">;
  /** `session.detach`: stops receiving the session's events; the session keeps running. */
  readonly detach: RexMethodOperation<"session.detach">;
  /** `session.attach_all`: receives events from the whole server, with `event_scope` `session` or `all`. */
  readonly attachAll: RexMethodOperation<"session.attach_all">;
  /**
   * `session.bootstrap`: attaches to all sessions and to chosen ones, and returns server status.
   *
   * Leaves out data tickets in both directions; stream a terminal with `terminals.stream`.
   */
  readonly bootstrap: (
    input: RexSessionBootstrapInput,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexSessionBootstrapResult, RexOperationError>;
  /** `session.set_label`: sets the session's label; an empty label restores the default. */
  readonly setLabel: RexMethodOperation<"session.set_label">;
  /** `session.move`: moves a session in the order `session.list` returns. */
  readonly move: RexMethodOperation<"session.move">;
  /** `session.list_blocks`: every block in the session, including detached blocks. */
  readonly listBlocks: RexMethodOperation<"session.list_blocks">;
  /** `session.list_clients`: the clients attached to the session. */
  readonly listClients: RexMethodOperation<"session.list_clients">;
  /** `session.help`: the methods this session accepts and its blocks provide, as raw JSON. */
  readonly help: RexMethodOperation<"session.help">;
  /**
   * The session's view now, then a new view after each change.
   *
   * Subscribes to events before reading the view, then reads it again only when a
   * `session_view_changed` event carries a revision newer than the view it holds, so it never
   * misses or repeats a change. An `event_dropped` for the session also reads it again, because
   * the dropped event may have been the change. Ends when the session is destroyed.
   */
  readonly watchView: (
    sessionId: SessionId,
  ) => Stream.Stream<SessionViewResult, RexOperationError | RexEventsLost>;
}

/**
 * Yieldable session service.
 *
 * @category services
 * @since 0.1.0
 */
export class SessionService extends Context.Service<SessionService, ISessionService>()(
  "rex-sdk/SessionService",
) {}

/**
 * Constructs session operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeSessionService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const createSession = rexMethodOperation(control, attachments, "session.create");
  const attachSession = rexMethodOperation(control, attachments, "session.attach");
  const detachSession = rexMethodOperation(control, attachments, "session.detach");
  const attachAllSessions = rexMethodOperation(control, attachments, "session.attach_all");
  const bootstrapSession = rexMethodOperation(control, attachments, "session.bootstrap");
  const view = rexMethodOperation(control, attachments, "session.view");

  const create = Effect.fn("SessionService.create")(function* (
    input: RexSessionCreateInput = {},
    options?: RexRequestOptions,
  ) {
    const initialWindows =
      input.initialWindows === undefined
        ? undefined
        : yield* Effect.forEach(input.initialWindows, (window) =>
            Effect.gen(function* () {
              const layout =
                window.layout === undefined
                  ? undefined
                  : yield* encodeRexLayout("session.create", window.layout);
              return {
                ...(window.windowLabel === undefined ? {} : { windowLabel: window.windowLabel }),
                ...(layout === undefined ? {} : { layout }),
              };
            }),
          );
    return yield* createSession(
      {
        ...(input.label === undefined ? {} : { label: input.label }),
        ...(initialWindows === undefined ? {} : { initialWindows }),
      },
      options,
    );
  });

  const watchView = (sessionId: SessionId) =>
    Stream.callback<SessionViewResult, RexOperationError | RexEventsLost>((queue) =>
      Effect.gen(function* () {
        const events = yield* control.subscribe;
        let current = yield* view({ sessionId });
        yield* Queue.offer(queue, current);
        const refresh = Effect.gen(function* () {
          const next = yield* view({ sessionId });
          if (next.revision > current.revision) {
            current = next;
            yield* Queue.offer(queue, current);
          }
        });
        while (true) {
          const event = yield* takeRexEvent(events);
          if (
            event._tag === "ServerEvent" &&
            event.type === "session_destroyed" &&
            event.payload.sessionId === sessionId
          ) {
            yield* Queue.end(queue);
            return;
          }
          if (
            event._tag === "SessionEvent" &&
            event.sessionId === sessionId &&
            event.type === "session_view_changed" &&
            event.payload.revision > current.revision
          ) {
            yield* refresh;
          }
          if (
            event._tag === "ServerEvent" &&
            event.type === "event_dropped" &&
            Option.contains(event.payload.sessionId, sessionId)
          ) {
            yield* refresh;
          }
        }
      }),
    );

  return SessionService.of({
    list: rexNoInputOperation(control, attachments, "session.list"),
    create,
    destroy: rexMethodOperation(control, attachments, "session.destroy"),
    view,
    attach: (input, options) =>
      Effect.gen(function* () {
        const result = yield* attachSession(input, options);
        yield* attachments.recordAttached(yield* control.connection, [input.sessionId]);
        return result;
      }),
    detach: (input, options) =>
      Effect.gen(function* () {
        const result = yield* detachSession(input, options);
        yield* attachments.recordDetached(input.sessionId);
        return result;
      }),
    attachAll: (input, options) =>
      Effect.gen(function* () {
        const result = yield* attachAllSessions(input, options);
        yield* attachments.recordAttachedToAll(
          yield* control.connection,
          input.eventScope === "all" ? "all" : "session",
        );
        return result;
      }),
    bootstrap: (input, options) =>
      Effect.gen(function* () {
        // Strip at runtime too, so a caller that widens the type still never handles tickets.
        const { dataTickets: _requested, ...request }: RexMethodInput<"session.bootstrap"> = input;
        const { dataTickets: _issued, ...result } = yield* bootstrapSession(request, options);
        const connection = yield* control.connection;
        yield* attachments.recordAttachedToAll(
          connection,
          input.eventScope === "all" ? "all" : "session",
        );
        const selected = Option.match(result.selectedSession, {
          onNone: () => [],
          onSome: (session) => [session.view.sessionId],
        });
        yield* attachments.recordAttached(connection, [
          ...selected,
          ...result.attachedSessions.map((session) => session.view.sessionId),
        ]);
        return result;
      }),
    setLabel: rexMethodOperation(control, attachments, "session.set_label"),
    move: rexMethodOperation(control, attachments, "session.move"),
    listBlocks: rexMethodOperation(control, attachments, "session.list_blocks"),
    listClients: rexMethodOperation(control, attachments, "session.list_clients"),
    help: rexMethodOperation(control, attachments, "session.help"),
    watchView,
  });
});

/**
 * Session operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const sessionServiceLayerWithoutDependencies: Layer.Layer<
  SessionService,
  never,
  RexControl | RexAttachments
> = Layer.effect(SessionService, makeSessionService);

/**
 * Session operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const sessionServiceLayer: Layer.Layer<SessionService, RexConfigurationError> =
  sessionServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
