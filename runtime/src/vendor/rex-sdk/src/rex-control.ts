/**
 * Owns the SDK's control connection to the Rex server.
 *
 * One WebSocket at `/api/control` (`rex.control.v1`) carries every request and every event. The
 * connection opens lazily on first use and is shared by the whole SDK graph. Requests are
 * correlated by `id` because the server may answer them in any order.
 *
 * When the connection ends, in-flight requests fail with `RexConnectionLost` (they may have run)
 * and event subscribers fail with `RexEventsLost`. Nothing is replayed. The next request dials
 * again, presenting the last reconnect token so the server can continue the same client.
 *
 * @since 0.1.0
 */
import { connect } from "node:net";
import {
  Cause,
  Context,
  Deferred,
  Duration,
  Effect,
  Exit,
  Layer,
  Option,
  Queue,
  Schema,
  Scope,
  Semaphore,
} from "effect";
import { Socket } from "effect/socket";
import { WebSocket } from "ws";
import { RexConfig, type IRexConfig, rexConfigLayer } from "./rex-config.ts";
import { ClientId } from "./rex-domain.ts";
import {
  RexConfigurationError,
  RexConnectionClosed,
  RexConnectionError,
  RexConnectionLost,
  RexEventsLost,
  RexHandshakeError,
  RexInvalidResponse,
  RexMessageTooLarge,
  RexRequestTimeout,
  RexUnsupportedApiRevision,
  rexServerFailure,
  type RexRequestError,
} from "./rex-errors.ts";

/**
 * Failure to open or keep the control connection.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexControlConnectError =
  | RexConnectionError
  | RexHandshakeError
  | RexUnsupportedApiRevision
  | RexConnectionClosed
  | RexInvalidResponse;

/**
 * What the server said about the current control connection in its welcome.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexControlConnectionInfo {
  /** Increases each time the SDK opens a new control connection. */
  readonly generation: number;
  /** The client this connection serves; stays the same when a reconnect resumes it. */
  readonly clientId: Option.Option<ClientId>;
  /** True when this connection continued the client of an earlier connection. */
  readonly resumed: boolean;
  /** The largest message, in bytes, that the server sends or accepts. */
  readonly maxMessageBytes: number;
  /** The API revision every message on this connection uses. */
  readonly apiRevision: number;
  /** Optional behaviors the server supports. */
  readonly features: ReadonlyArray<string>;
}

/**
 * A successful response: the result and the `seq` of the last event queued before it ran.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexControlResponse {
  /** Events with a `seq` at or below this are already reflected in `payload`. */
  readonly seq: number;
  /** The method's result, still in its wire form. */
  readonly payload: Schema.Json;
}

/**
 * One event frame from the control connection, still in its wire form.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexControlEvent {
  /** Which control connection delivered the event. */
  readonly generation: number;
  /** The event's place among the events on its connection, starting at 1 with no gaps. */
  readonly seq: number;
  /** The event's type, such as `session_event` or `session_created`. */
  readonly type: string;
  /** The event's fields. */
  readonly payload: Schema.Json;
}

/**
 * Per-request options.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexRequestOptions {
  /** How long to wait for this response; defaults to the configured request timeout. */
  readonly timeout?: Duration.Input | undefined;
}

/**
 * The control connection capability shared by every namespace service.
 *
 * @category services
 * @since 0.1.0
 */
export interface IRexControl {
  /** Sends one request and waits for its response, opening the connection if needed. */
  readonly request: (
    method: string,
    payload: Schema.Json | undefined,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexControlResponse, RexRequestError>;
  /** Opens the connection if needed and describes it. */
  readonly connection: Effect.Effect<RexControlConnectionInfo, RexControlConnectError>;
  /**
   * Receives every event frame from now until the Scope closes or the connection ends.
   *
   * Each subscriber has its own bounded buffer. A subscriber that falls behind fails with
   * `RexEventsLost` rather than missing events silently.
   */
  readonly subscribe: Effect.Effect<
    Queue.Dequeue<RexControlEvent, RexEventsLost | Cause.Done>,
    never,
    Scope.Scope
  >;
}

/**
 * Yieldable control connection service.
 *
 * @category services
 * @since 0.1.0
 */
export class RexControl extends Context.Service<RexControl, IRexControl>()("rex-sdk/RexControl") {}

const RexControlWelcomeMessage = Schema.Struct({
  type: Schema.Literal("welcome"),
  protocol: Schema.String,
  limits: Schema.Struct({ max_message_bytes: Schema.Int }),
  client: Schema.optionalKey(
    Schema.NullOr(
      Schema.Struct({
        id: Schema.String,
        reconnect_token: Schema.String,
        resumed: Schema.optionalKey(Schema.Boolean),
      }),
    ),
  ),
  features: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.String))),
  api_revision: Schema.optionalKey(Schema.Int),
});

const RexControlResponseMessage = Schema.Struct({
  type: Schema.Literal("response"),
  id: Schema.String,
  seq: Schema.Int,
  payload: Schema.optionalKey(Schema.Json),
  error: Schema.optionalKey(
    Schema.NullOr(
      Schema.Struct({ code: Schema.String, message: Schema.String, status: Schema.Int }),
    ),
  ),
});

const RexControlEventMessage = Schema.Struct({
  type: Schema.Literal("event"),
  seq: Schema.Int,
  payload: Schema.Struct({ type: Schema.String, payload: Schema.optionalKey(Schema.Json) }),
});

const RexControlMessage = Schema.Union([
  RexControlWelcomeMessage,
  RexControlResponseMessage,
  RexControlEventMessage,
  Schema.Struct({ type: Schema.String }),
]);

const decodeRexControlMessage = Schema.decodeUnknownEffect(
  Schema.fromJsonString(RexControlMessage),
);
const decodeClientId = Schema.decodeUnknownOption(ClientId);

const isWelcome = Schema.is(RexControlWelcomeMessage);
const isResponse = Schema.is(RexControlResponseMessage);
const isEvent = Schema.is(RexControlEventMessage);

/** Size of each event subscriber's buffer before it fails with `RexEventsLost`. */
const SUBSCRIBER_CAPACITY = 4096;

interface PendingRequest {
  readonly method: string;
  readonly deferred: Deferred.Deferred<RexControlResponse, RexRequestError>;
}

interface ControlConnection {
  readonly info: RexControlConnectionInfo;
  readonly writer: Socket.Writer;
  readonly pending: Map<string, PendingRequest>;
  readonly scope: Scope.Closeable;
  nextRequestId: number;
  lastEventSeq: number;
  alive: boolean;
}

/**
 * Creates a `ws` client for a path on the configured endpoint.
 *
 * Unix sockets are dialed with `createConnection` because `ws+unix:` URLs cannot carry paths
 * that contain spaces, such as macOS's `Application Support`.
 *
 * @category constructors
 * @since 0.1.0
 */
export function openRexWebSocket(
  config: IRexConfig,
  path: string,
  subprotocol: string,
  compress: boolean,
): WebSocket {
  const endpoint = config.endpoint;
  if (endpoint._tag === "Socket") {
    return new WebSocket(`ws://localhost${path}`, [subprotocol], {
      createConnection: () => connect({ path: endpoint.path }),
      perMessageDeflate: compress,
    });
  }
  return new WebSocket(`${endpoint.baseUrl}${path}`, [subprotocol], {
    perMessageDeflate: compress,
  });
}

function closeFailure(
  config: IRexConfig,
  error: Socket.SocketError,
): RexConnectionError | RexConnectionClosed | RexUnsupportedApiRevision {
  const reason = error.reason;
  switch (reason._tag) {
    case "SocketCloseError": {
      const closeReason = reason.closeReason ?? "";
      if (reason.code === 1008 && closeReason.startsWith("no common API revision")) {
        return new RexUnsupportedApiRevision({
          endpoint: config.endpointDisplay,
          requiredRevision: config.apiRevision,
          serverReason: closeReason,
        });
      }
      if (reason.code === 1006)
        return new RexConnectionError(config.endpointDisplay, "read", error);
      return new RexConnectionClosed(config.endpointDisplay, reason.code, closeReason);
    }
    case "SocketOpenError":
      return new RexConnectionError(config.endpointDisplay, "connect", error);
    case "SocketWriteError":
      return new RexConnectionError(config.endpointDisplay, "write", error);
    default:
      return new RexConnectionError(config.endpointDisplay, "read", error);
  }
}

/**
 * Constructs the control connection service for the current Layer scope.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeRexControl = Effect.gen(function* () {
  const config = yield* RexConfig;
  const layerScope = yield* Effect.scope;
  const dialLock = yield* Semaphore.make(1);
  const subscribers = new Set<Queue.Queue<RexControlEvent, RexEventsLost | Cause.Done>>();
  let current: ControlConnection | undefined;
  let generation = 0;
  let reconnectToken: string | undefined;

  const failSubscribers = (reason: RexEventsLost["reason"]) => {
    for (const subscriber of subscribers)
      Queue.failCauseUnsafe(subscriber, Cause.fail(new RexEventsLost(reason)));
    subscribers.clear();
  };

  const terminate = (connection: ControlConnection, cause: RexRequestError) =>
    Effect.gen(function* () {
      if (!connection.alive) return;
      connection.alive = false;
      for (const [requestId, pending] of connection.pending) {
        yield* Deferred.fail(
          pending.deferred,
          new RexConnectionLost(pending.method, requestId, cause),
        );
      }
      connection.pending.clear();
      failSubscribers("connection_ended");
      yield* Scope.close(connection.scope, Exit.void);
    });

  const dispatch = (connection: ControlConnection, text: string) =>
    Effect.gen(function* () {
      const message = yield* decodeRexControlMessage(text).pipe(
        Effect.mapError((cause) => new RexInvalidResponse("control message", undefined, cause)),
      );
      if (isResponse(message)) {
        const pending = connection.pending.get(message.id);
        if (pending === undefined) return;
        connection.pending.delete(message.id);
        if (message.error !== undefined && message.error !== null) {
          yield* Deferred.fail(
            pending.deferred,
            rexServerFailure({
              method: pending.method,
              requestId: message.id,
              code: message.error.code,
              status: message.error.status,
              serverMessage: message.error.message,
            }),
          );
          return;
        }
        yield* Deferred.succeed(pending.deferred, {
          seq: message.seq,
          payload: message.payload ?? null,
        });
        return;
      }
      if (isEvent(message)) {
        if (message.seq !== connection.lastEventSeq + 1) failSubscribers("sequence_gap");
        connection.lastEventSeq = message.seq;
        const event: RexControlEvent = {
          generation: connection.info.generation,
          seq: message.seq,
          type: message.payload.type,
          payload: message.payload.payload ?? null,
        };
        for (const subscriber of subscribers) {
          if (!Queue.offerUnsafe(subscriber, event)) {
            Queue.failCauseUnsafe(subscriber, Cause.fail(new RexEventsLost("subscriber_backlog")));
            subscribers.delete(subscriber);
          }
        }
      }
      // Unknown message types are skipped: newer servers add them.
    });

  const readLoop = (
    connection: ControlConnection,
    reader: Socket.Reader<string | Uint8Array>,
    leftover: ReadonlyArray<string | Uint8Array>,
  ) =>
    Effect.gen(function* () {
      let frames: ReadonlyArray<string | Uint8Array> = leftover;
      while (true) {
        for (const frame of frames) {
          if (typeof frame === "string") yield* dispatch(connection, frame);
        }
        frames = yield* reader.pull.pipe(Effect.mapError((error) => closeFailure(config, error)));
      }
    }).pipe(
      Effect.catch((error: RexRequestError) => terminate(connection, error)),
      Effect.onInterrupt(() =>
        terminate(
          connection,
          new RexConnectionError(config.endpointDisplay, "read", "connection closed"),
        ),
      ),
    );

  const dial = Effect.gen(function* () {
    const scope = yield* Scope.fork(layerScope, "sequential");
    const socket = yield* Socket.fromWebSocket(
      Effect.acquireRelease(
        Effect.sync(() => openRexWebSocket(config, "/api/control", "rex.control.v1", true)),
        (ws) => Effect.sync(() => ws.close(1000)),
      ),
      { openTimeout: config.connectTimeout },
    );
    const reader = yield* socket.reader.pipe(
      Scope.provide(scope),
      Effect.mapError((error) => closeFailure(config, error)),
    );
    const writer = yield* socket.writer.pipe(Scope.provide(scope));
    const hello = {
      type: "hello",
      api_revision: config.apiRevision,
      api_min_revision: config.apiRevision,
      client: {
        kind: config.client.kind,
        name: config.client.name,
        ...Option.match(config.client.version, {
          onNone: () => ({}),
          onSome: (version) => ({ version }),
        }),
        ...Option.match(config.client.label, {
          onNone: () => ({}),
          onSome: (label) => ({ label }),
        }),
      },
      ...(reconnectToken === undefined ? {} : { reconnect_token: reconnectToken }),
    };
    yield* writer
      .write(JSON.stringify(hello))
      .pipe(Effect.mapError((error) => closeFailure(config, error)));

    const [welcome, leftover] = yield* Effect.gen(function* () {
      while (true) {
        const frames = yield* reader.pull.pipe(
          Effect.mapError((error) => closeFailure(config, error)),
        );
        const index = frames.findIndex((frame) => typeof frame === "string");
        const first = frames[index];
        if (first === undefined || typeof first !== "string") continue;
        const message = yield* decodeRexControlMessage(first).pipe(
          Effect.mapError((cause) => new RexInvalidResponse("welcome", undefined, cause)),
        );
        if (!isWelcome(message)) {
          return yield* new RexHandshakeError(
            config.endpointDisplay,
            `the first message was ${message.type}, not welcome`,
          );
        }
        return [message, frames.slice(index + 1)] as const;
      }
    }).pipe(
      Effect.timeoutOrElse({
        duration: config.connectTimeout,
        orElse: () =>
          Effect.fail(new RexHandshakeError(config.endpointDisplay, "no welcome arrived in time")),
      }),
      Effect.onError(() => Scope.close(scope, Exit.void)),
    );

    if (welcome.protocol !== "rex.control.v1") {
      yield* Scope.close(scope, Exit.void);
      return yield* new RexHandshakeError(
        config.endpointDisplay,
        `the server speaks ${welcome.protocol}`,
      );
    }
    if ((welcome.api_revision ?? 0) !== config.apiRevision) {
      yield* Scope.close(scope, Exit.void);
      return yield* new RexUnsupportedApiRevision({
        endpoint: config.endpointDisplay,
        requiredRevision: config.apiRevision,
        serverRevision: welcome.api_revision ?? 0,
      });
    }

    generation += 1;
    reconnectToken = welcome.client?.reconnect_token;
    const connection: ControlConnection = {
      info: {
        generation,
        clientId:
          welcome.client === undefined || welcome.client === null
            ? Option.none()
            : decodeClientId(welcome.client.id),
        resumed: welcome.client?.resumed ?? false,
        maxMessageBytes: welcome.limits.max_message_bytes,
        apiRevision: welcome.api_revision ?? 0,
        features: welcome.features ?? [],
      },
      writer,
      pending: new Map(),
      scope,
      nextRequestId: 1,
      lastEventSeq: 0,
      alive: true,
    };
    yield* Effect.forkIn(readLoop(connection, reader, leftover), scope);
    return connection;
  }).pipe(
    Effect.withSpan("RexControl.connect", {
      attributes: { "rex.endpoint": config.endpointDisplay },
    }),
  );

  const ensureConnection = dialLock.withPermit(
    Effect.suspend(() =>
      current !== undefined && current.alive
        ? Effect.succeed(current)
        : dial.pipe(Effect.tap((connection) => Effect.sync(() => (current = connection)))),
    ),
  );

  const request = Effect.fn("RexControl.request")(function* (
    method: string,
    payload: Schema.Json | undefined,
    options?: RexRequestOptions,
  ) {
    yield* Effect.annotateCurrentSpan("rex.method", method);
    const connection = yield* ensureConnection;
    const requestId = String(connection.nextRequestId++);
    const text = JSON.stringify(
      payload === undefined
        ? { type: "request", id: requestId, method }
        : { type: "request", id: requestId, method, payload },
    );
    const bytes = Buffer.byteLength(text);
    if (bytes > connection.info.maxMessageBytes) {
      return yield* new RexMessageTooLarge(method, bytes, connection.info.maxMessageBytes);
    }
    const timeout = Option.getOrElse(
      Option.flatMap(Option.fromUndefinedOr(options?.timeout), Duration.fromInput),
      () => config.requestTimeout,
    );
    const deferred = Deferred.makeUnsafe<RexControlResponse, RexRequestError>();
    connection.pending.set(requestId, { method, deferred });
    if (!connection.alive) {
      connection.pending.delete(requestId);
      return yield* new RexConnectionLost(method, requestId, "connection closed");
    }
    yield* connection.writer.write(text).pipe(
      Effect.mapError((error) => closeFailure(config, error)),
      Effect.tapError(() => Effect.sync(() => connection.pending.delete(requestId))),
    );
    return yield* Deferred.await(deferred).pipe(
      Effect.timeoutOrElse({
        duration: timeout,
        orElse: () =>
          Effect.fail(new RexRequestTimeout(method, requestId, Duration.toMillis(timeout))),
      }),
      Effect.ensuring(Effect.sync(() => connection.pending.delete(requestId))),
    );
  });

  const subscribe = Effect.acquireRelease(
    Effect.gen(function* () {
      const queue = yield* Queue.bounded<RexControlEvent, RexEventsLost | Cause.Done>(
        SUBSCRIBER_CAPACITY,
      );
      subscribers.add(queue);
      return queue;
    }),
    (queue) =>
      Effect.gen(function* () {
        subscribers.delete(queue);
        yield* Queue.shutdown(queue);
      }),
  );

  yield* Effect.addFinalizer(() =>
    Effect.gen(function* () {
      if (current !== undefined) {
        yield* terminate(
          current,
          new RexConnectionError(config.endpointDisplay, "read", "the SDK was shut down"),
        );
      }
    }),
  );

  return RexControl.of({
    request: (method, payload, options) => request(method, payload, options),
    connection: ensureConnection.pipe(Effect.map((connection) => connection.info)),
    subscribe,
  });
});

/**
 * The control connection, leaving its configuration requirement visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexControlLayerWithoutDependencies: Layer.Layer<RexControl, never, RexConfig> =
  Layer.effect(RexControl, makeRexControl);

/**
 * The control connection with configuration from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexControlLayer: Layer.Layer<RexControl, RexConfigurationError> =
  rexControlLayerWithoutDependencies.pipe(Layer.provide(rexConfigLayer));
