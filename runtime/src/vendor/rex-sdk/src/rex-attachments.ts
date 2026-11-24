/**
 * Keeps the control connection attached to the sessions the SDK uses.
 *
 * Rex answers most session-scoped methods with `conflict` until the connection attaches to the
 * session. The SDK attaches on first use, once per session per connection, so callers never
 * manage attachment to avoid that error. Attachments belong to the connection: a new
 * connection that does not resume the previous client starts with none.
 *
 * Attaching to all sessions (`session.attach_all`) is tracked separately, with the widest
 * `event_scope` requested so far, because it decides which events the connection receives.
 *
 * @since 0.1.0
 */
import { Context, Deferred, Effect, Exit, Layer } from "effect";
import { rexConfigLayer } from "./rex-config.ts";
import {
  RexControl,
  rexControlLayerWithoutDependencies,
  type RexControlConnectionInfo,
} from "./rex-control.ts";
import type { SessionId } from "./rex-domain.ts";
import type { RexConfigurationError, RexRequestError } from "./rex-errors.ts";

/**
 * Which events `session.attach_all` asks for: `session` leaves out block events and
 * client-wide events, `all` includes everything.
 *
 * @category models
 * @since 0.1.0
 */
export type RexEventScope = "session" | "all";

/**
 * Attachment management for the shared control connection.
 *
 * @category services
 * @since 0.1.0
 */
export interface IRexAttachments {
  /** Attaches to a session unless this connection already is; concurrent calls share one attach. */
  readonly ensureAttached: (sessionId: SessionId) => Effect.Effect<void, RexRequestError>;
  /** Calls `session.attach_all` unless this connection already has at least this event scope. */
  readonly ensureAttachedToAll: (scope: RexEventScope) => Effect.Effect<void, RexRequestError>;
  /** Records an attachment made by an explicit `session.attach` or `session.bootstrap` call. */
  readonly recordAttached: (
    connection: RexControlConnectionInfo,
    sessionIds: ReadonlyArray<SessionId>,
  ) => Effect.Effect<void>;
  /** Records an explicit `session.attach_all` or `session.bootstrap` call. */
  readonly recordAttachedToAll: (
    connection: RexControlConnectionInfo,
    scope: RexEventScope,
  ) => Effect.Effect<void>;
  /** Records an explicit `session.detach` call. */
  readonly recordDetached: (sessionId: SessionId) => Effect.Effect<void>;
}

/**
 * Yieldable attachment service.
 *
 * @category services
 * @since 0.1.0
 */
export class RexAttachments extends Context.Service<RexAttachments, IRexAttachments>()(
  "rex-sdk/RexAttachments",
) {}

const scopeRank: Readonly<Record<RexEventScope, number>> = { session: 1, all: 2 };

/**
 * Constructs attachment tracking over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeRexAttachments = Effect.gen(function* () {
  const control = yield* RexControl;
  let generation = 0;
  const attached = new Map<SessionId, Deferred.Deferred<void, RexRequestError>>();
  let attachedToAll: RexEventScope | undefined;

  /** Forgets attachments made on an earlier connection that this one did not resume. */
  const sync = (connection: RexControlConnectionInfo) => {
    if (connection.generation === generation) return;
    generation = connection.generation;
    if (!connection.resumed) {
      attached.clear();
      attachedToAll = undefined;
    }
  };

  const ensureAttached = Effect.fn("RexAttachments.ensureAttached")(function* (
    sessionId: SessionId,
  ) {
    const connection = yield* control.connection;
    sync(connection);
    const existing = attached.get(sessionId);
    if (existing !== undefined) return yield* Deferred.await(existing);
    const deferred = Deferred.makeUnsafe<void, RexRequestError>();
    attached.set(sessionId, deferred);
    const exit = yield* Effect.exit(
      Effect.asVoid(control.request("session.attach", { session_id: sessionId })),
    );
    if (Exit.isFailure(exit)) attached.delete(sessionId);
    yield* Deferred.done(deferred, exit);
    return yield* exit;
  });

  const ensureAttachedToAll = Effect.fn("RexAttachments.ensureAttachedToAll")(function* (
    scope: RexEventScope,
  ) {
    const connection = yield* control.connection;
    sync(connection);
    if (attachedToAll !== undefined && scopeRank[attachedToAll] >= scopeRank[scope]) return;
    yield* control.request("session.attach_all", { event_scope: scope });
    attachedToAll = scope;
  });

  return RexAttachments.of({
    ensureAttached,
    ensureAttachedToAll,
    recordAttached: (connection, sessionIds) =>
      Effect.sync(() => {
        sync(connection);
        for (const sessionId of sessionIds) {
          if (!attached.has(sessionId)) {
            const deferred = Deferred.makeUnsafe<void, RexRequestError>();
            Deferred.doneUnsafe(deferred, Effect.void);
            attached.set(sessionId, deferred);
          }
        }
      }),
    recordAttachedToAll: (connection, scope) =>
      Effect.sync(() => {
        sync(connection);
        if (attachedToAll === undefined || scopeRank[attachedToAll] < scopeRank[scope])
          attachedToAll = scope;
      }),
    recordDetached: (sessionId) => Effect.sync(() => void attached.delete(sessionId)),
  });
});

/**
 * Attachment tracking, leaving the control connection requirement visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexAttachmentsLayerWithoutDependencies: Layer.Layer<
  RexAttachments,
  never,
  RexControl
> = Layer.effect(RexAttachments, makeRexAttachments);

/**
 * Attachment tracking over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexAttachmentsLayer: Layer.Layer<RexAttachments, RexConfigurationError> =
  rexAttachmentsLayerWithoutDependencies.pipe(
    Layer.provide(rexControlLayerWithoutDependencies),
    Layer.provide(rexConfigLayer),
  );
