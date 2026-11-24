/**
 * Tunnel blocks: forward TCP connections between the server's machine and their owner.
 *
 * A dial tunnel connects to a fixed host and port for each stream its owner opens, like
 * `ssh -L`; a listen tunnel accepts connections on an address and has its owner carry each one
 * onward, like `ssh -R`. Tunnels start detached, as `session.new_block` makes them, and belong to
 * the calling client when it is attached to the session.
 *
 * Each TCP connection is one byte stream (`rex.data.bytes.v1`). Only the owner may open a
 * tunnel's streams, and a tunnel loses its owner when the owner's control connection ends, so
 * forwards stop then instead of resuming. `forwardLocal` and `forwardRemote` do the whole job;
 * `openStream` and `connections` are the parts they are built from.
 *
 * @since 0.1.0
 */
import { randomUUID } from "node:crypto";
import type { Socket } from "node:net";
import {
  Cause,
  Context,
  Deferred,
  Effect,
  FiberSet,
  Layer,
  Option,
  Queue,
  Schema,
  Scope,
  Stream,
} from "effect";
import { RexAttachments, type IRexAttachments } from "./rex-attachments.ts";
import { openRexBytesStream, type RexBytesStream } from "./rex-bytes-stream.ts";
import { RexConfig, rexConfigLayer, type IRexConfig } from "./rex-config.ts";
import {
  RexControl,
  type IRexControl,
  type RexControlEvent,
  type RexRequestOptions,
} from "./rex-control.ts";
import { rexCoreLayerWithoutDependencies } from "./rex-core.ts";
import { REX_BYTES_DATA_SUBPROTOCOL, rexDataHelloFromTicket } from "./rex-data-connection.ts";
import type { BlockId, SessionId } from "./rex-domain.ts";
import {
  RexBlockClosed,
  RexInvalidResponse,
  type RexConfigurationError,
  type RexDataError,
  type RexEventsLost,
  type RexForwardSocketError,
  type RexOperationError,
} from "./rex-errors.ts";
import { takeRexEvent, type RexEvent } from "./rex-events.ts";
import {
  encodeRexInput,
  rexBlockNoArgsOperation,
  rexMethodOperation,
  type RexBlockNoArgsOperation,
  type RexBlockTarget,
  type RexMethodResult,
} from "./rex-operation.ts";
import {
  bridgeSocketToStream,
  connectLocal,
  formatHostPort,
  listenLocal,
} from "./rex-tunnel-forward.ts";
import {
  TunnelConnectionRequestedEvent,
  TunnelDialOptions,
  TunnelListenOptions,
} from "./generated/rex-wire-schemas.ts";

/**
 * The flavor of a tunnel that connects to a fixed host and port, like `ssh -L`.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_TUNNEL_DIAL_FLAVOR = "com.superlogical.tunnel.dial";

/**
 * The flavor of a tunnel that listens on an address and hands each connection to its owner,
 * like `ssh -R`.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_TUNNEL_LISTEN_FLAVOR = "com.superlogical.tunnel.listen";

/**
 * Arguments of {@link ITunnelService.createDial}.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexCreateDialTunnelInput {
  /** The session to create the tunnel in. */
  readonly sessionId: SessionId;
  /** The tunnel block's label; defaults to the flavor's short name. */
  readonly label?: string;
  /** The host and port to connect to, and where the owner listens, for display. */
  readonly options: TunnelDialOptions;
}

/**
 * Arguments of {@link ITunnelService.createListen}.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexCreateListenTunnelInput {
  /** The session to create the tunnel in. */
  readonly sessionId: SessionId;
  /** The tunnel block's label; defaults to the flavor's short name. */
  readonly label?: string;
  /** The address and port to listen on, and where the owner connects, for display. */
  readonly options: TunnelListenOptions;
}

/**
 * A connection a listen tunnel accepted, waiting for this client to carry it.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTunnelConnection {
  /** The IP address and port the connection came from. */
  readonly peer: string;
  /**
   * Opens the connection's byte stream. Rex drops the connection if it isn't accepted within
   * 30 seconds. Closing the scope before the stream finishes resets the connection.
   */
  readonly accept: Effect.Effect<RexBytesStream, RexOperationError | RexDataError, Scope.Scope>;
}

/**
 * A TCP address; `host` defaults to `127.0.0.1` where it may be left out.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTcpAddress {
  readonly host?: string | undefined;
  /** 0 picks a free port where the SDK or Rex listens. */
  readonly port: number;
}

/**
 * Arguments of {@link ITunnelService.forwardLocal}, which works like `ssh -L`.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexForwardLocalInput {
  readonly sessionId: SessionId;
  /** Where the server's machine connects for each connection, such as a database's port. */
  readonly target: RexTcpAddress & { readonly host: string };
  /** Where this machine listens; defaults to a free port on 127.0.0.1. */
  readonly listen?: RexTcpAddress | undefined;
  /** The tunnel block's label. */
  readonly label?: string | undefined;
}

/**
 * Arguments of {@link ITunnelService.forwardRemote}, which works like `ssh -R`.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexForwardRemoteInput {
  readonly sessionId: SessionId;
  /** Where this machine connects for each connection, such as a development server. */
  readonly target: RexTcpAddress & { readonly host: string };
  /** Where the server's machine listens; defaults to a free port on 127.0.0.1. */
  readonly listen?: RexTcpAddress | undefined;
  /** The tunnel block's label. */
  readonly label?: string | undefined;
}

/**
 * A running forward. It stops when its scope closes, which also closes its tunnel block.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexForward {
  /** The tunnel block that carries the forward. */
  readonly blockId: BlockId;
  /**
   * Where to connect: an address on this machine for `forwardLocal`, and on the server's machine
   * for `forwardRemote`, with the port that was picked when port 0 was asked for.
   */
  readonly address: string;
  /**
   * Fails once the forward can no longer carry connections: with `RexBlockClosed` when its block
   * closes, and with `RexEventsLost` when the connection to the server ends. Never succeeds.
   */
  readonly stopped: Effect.Effect<never, RexBlockClosed | RexEventsLost | RexInvalidResponse>;
}

/**
 * Tunnel block operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface ITunnelService {
  /** `session.new_block` with the dial flavor: creates a detached tunnel to a fixed host and port. */
  readonly createDial: (
    input: RexCreateDialTunnelInput,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_block">, RexOperationError>;
  /** `session.new_block` with the listen flavor: creates a detached tunnel that accepts connections. */
  readonly createListen: (
    input: RexCreateListenTunnelInput,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_block">, RexOperationError>;
  /** `com.superlogical.tunnel.info`: what the tunnel forwards and how many connections it relays. */
  readonly info: RexBlockNoArgsOperation<"com.superlogical.tunnel.info">;
  /**
   * Opens one connection through a dial tunnel this client owns: the tunnel connects to its
   * target and carries the stream's bytes both ways.
   */
  readonly openStream: (
    target: RexBlockTarget,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexBytesStream, RexOperationError | RexDataError, Scope.Scope>;
  /** The connections a listen tunnel this client owns accepts, as they arrive. */
  readonly connections: (
    target: RexBlockTarget,
  ) => Stream.Stream<RexTunnelConnection, RexOperationError | RexEventsLost>;
  /**
   * Forwards a port on this machine to `target` on the server's machine, like `ssh -L`: creates
   * a dial tunnel, listens locally, and carries each connection through it. Closing the scope
   * stops listening and closes the tunnel.
   */
  readonly forwardLocal: (
    input: RexForwardLocalInput,
  ) => Effect.Effect<RexForward, RexOperationError | RexForwardSocketError, Scope.Scope>;
  /**
   * Forwards a port on the server's machine to `target` on this machine, like `ssh -R`: creates
   * a listen tunnel and connects each connection it accepts to `target`. Closing the scope closes
   * the tunnel.
   */
  readonly forwardRemote: (
    input: RexForwardRemoteInput,
  ) => Effect.Effect<RexForward, RexOperationError, Scope.Scope>;
}

/**
 * Yieldable tunnel service.
 *
 * @category services
 * @since 0.1.0
 */
export class TunnelService extends Context.Service<TunnelService, ITunnelService>()(
  "rex-sdk/TunnelService",
) {}

/** Where forwards listen when the caller doesn't say. */
const defaultForwardHost = "127.0.0.1";

const decodeConnectionRequested = Schema.decodeUnknownEffect(TunnelConnectionRequestedEvent);

/** The tunnel byte-stream operations, shared by the service and its forwards. */
function makeTunnelStreams(config: IRexConfig, control: IRexControl, attachments: IRexAttachments) {
  const dataConnect = rexMethodOperation(control, attachments, "data.connect");

  /** Opens the byte stream for one `conn:` reference of a tunnel. */
  const openRef = (target: RexBlockTarget, ref: string, options?: RexRequestOptions) =>
    Effect.gen(function* () {
      const ticket = yield* dataConnect(
        {
          sessionId: target.sessionId,
          blockId: target.blockId,
          dataRefId: ref,
          subprotocol: REX_BYTES_DATA_SUBPROTOCOL,
        },
        options,
      );
      const hello = yield* rexDataHelloFromTicket("data.connect", ticket.ticket);
      return yield* openRexBytesStream(config, hello, target.blockId);
    });

  const openStream: ITunnelService["openStream"] = (target, options) =>
    openRef(target, `conn:${randomUUID()}`, options).pipe(
      Effect.withSpan("TunnelService.openStream"),
    );

  /** The connection a `connection_requested` event offers this client, if it is one. */
  const connectionRequest = (
    event: RexEvent,
    target: RexBlockTarget,
    clientId: Option.Option<string>,
  ) =>
    Effect.gen(function* () {
      if (
        event._tag !== "BlockEvent" ||
        event.blockId !== target.blockId ||
        event.name !== "connection_requested"
      ) {
        return Option.none<RexTunnelConnection>();
      }
      const request = yield* decodeConnectionRequested(event.payload).pipe(
        Effect.mapError(
          (cause) => new RexInvalidResponse("connection_requested", undefined, cause),
        ),
      );
      // Every client in the session sees the event; only the owner it names may answer.
      if (!Option.contains(clientId, request.client)) return Option.none<RexTunnelConnection>();
      return Option.some<RexTunnelConnection>({
        peer: request.peer,
        accept: openRef(target, request.ref),
      });
    });

  const connections: ITunnelService["connections"] = (target) =>
    Stream.callback<RexTunnelConnection, RexOperationError | RexEventsLost>((queue) =>
      Effect.gen(function* () {
        const events = yield* control.subscribe;
        yield* attachments.ensureAttached(target.sessionId);
        const clientId = (yield* control.connection).clientId;
        while (true) {
          const event = yield* takeRexEvent(events);
          const connection = yield* connectionRequest(event, target, clientId);
          if (Option.isSome(connection)) yield* Queue.offer(queue, connection.value);
        }
      }),
    );

  return { openStream, connections, connectionRequest };
}

/**
 * Watches a forward's events in the background until its block closes, passing each event to
 * `onEvent` first, and returns the effect that fails when it stops.
 */
function watchForwardStopped(
  events: Queue.Dequeue<RexControlEvent, RexEventsLost | Cause.Done>,
  target: RexBlockTarget,
  onEvent: (event: RexEvent) => Effect.Effect<void, RexEventsLost | RexInvalidResponse>,
) {
  return Effect.gen(function* () {
    const stopped = yield* Deferred.make<
      never,
      RexBlockClosed | RexEventsLost | RexInvalidResponse
    >();
    const watch = Effect.gen(function* () {
      while (true) {
        const event = yield* takeRexEvent(events);
        yield* onEvent(event);
        const closed =
          (event._tag === "SessionEvent" &&
            event.type === "block_closed" &&
            event.payload.blockId === target.blockId) ||
          (event._tag === "ServerEvent" &&
            event.type === "session_destroyed" &&
            event.payload.sessionId === target.sessionId);
        if (closed) return yield* new RexBlockClosed(target.blockId);
      }
    });
    yield* Effect.forkScoped(watch.pipe(Effect.catch((error) => Deferred.fail(stopped, error))));
    return Deferred.await(stopped);
  });
}

/**
 * Constructs tunnel operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeTunnelService = Effect.gen(function* () {
  const config = yield* RexConfig;
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const newBlock = rexMethodOperation(control, attachments, "session.new_block");
  const closeBlock = rexMethodOperation(control, attachments, "block.close");
  const info = rexBlockNoArgsOperation(control, attachments, "com.superlogical.tunnel.info");
  const streams = makeTunnelStreams(config, control, attachments);

  const createDial: ITunnelService["createDial"] = Effect.fn("TunnelService.createDial")(
    function* (input, options) {
      const encoded = yield* encodeRexInput(
        "TunnelService.createDial",
        TunnelDialOptions,
        input.options,
      );
      return yield* newBlock(
        {
          sessionId: input.sessionId,
          flavor: REX_TUNNEL_DIAL_FLAVOR,
          options: encoded,
          ...(input.label === undefined ? {} : { label: input.label }),
        },
        options,
      );
    },
  );
  const createListen: ITunnelService["createListen"] = Effect.fn("TunnelService.createListen")(
    function* (input, options) {
      const encoded = yield* encodeRexInput(
        "TunnelService.createListen",
        TunnelListenOptions,
        input.options,
      );
      return yield* newBlock(
        {
          sessionId: input.sessionId,
          flavor: REX_TUNNEL_LISTEN_FLAVOR,
          options: encoded,
          ...(input.label === undefined ? {} : { label: input.label }),
        },
        options,
      );
    },
  );

  /** Creates a tunnel block for the scope's lifetime; closing the scope closes the block. */
  const scopedTunnel = (
    sessionId: SessionId,
    create: Effect.Effect<RexMethodResult<"session.new_block">, RexOperationError>,
  ) =>
    Effect.acquireRelease(create, (block) =>
      Effect.ignore(closeBlock({ sessionId, blockId: block.blockId })),
    );

  const forwardLocal: ITunnelService["forwardLocal"] = (input) =>
    Effect.gen(function* () {
      const events = yield* control.subscribe;
      const fibers = yield* FiberSet.make<void, never>();
      const run = yield* FiberSet.runtime(fibers)<never>();
      let target: RexBlockTarget | undefined;
      const listener = yield* listenLocal(
        input.listen?.host ?? defaultForwardHost,
        input.listen?.port ?? 0,
        (socket: Socket) => {
          if (target === undefined) return socket.resetAndDestroy();
          const through = target;
          run(
            Effect.scoped(
              streams
                .openStream(through)
                .pipe(Effect.flatMap((stream) => bridgeSocketToStream(socket, stream))),
            ).pipe(Effect.catchCause(() => Effect.sync(() => socket.resetAndDestroy()))),
          );
        },
      );
      const block = yield* scopedTunnel(
        input.sessionId,
        createDial({
          sessionId: input.sessionId,
          options: {
            host: input.target.host,
            port: input.target.port,
            clientAddress: listener.address,
          },
          ...(input.label === undefined ? {} : { label: input.label }),
        }),
      );
      target = { sessionId: input.sessionId, blockId: block.blockId };
      const stopped = yield* watchForwardStopped(events, target, () => Effect.void);
      return { blockId: block.blockId, address: listener.address, stopped } satisfies RexForward;
    }).pipe(Effect.withSpan("TunnelService.forwardLocal"));

  const forwardRemote: ITunnelService["forwardRemote"] = (input) =>
    Effect.gen(function* () {
      // Subscribe before the tunnel exists, so no connection request can arrive unseen.
      const events = yield* control.subscribe;
      const fibers = yield* FiberSet.make<void, never>();
      const block = yield* scopedTunnel(
        input.sessionId,
        createListen({
          sessionId: input.sessionId,
          options: {
            ...(input.listen?.host === undefined ? {} : { address: input.listen.host }),
            port: input.listen?.port ?? 0,
            clientTarget: formatHostPort(input.target.host, input.target.port),
          },
          ...(input.label === undefined ? {} : { label: input.label }),
        }),
      );
      const target = { sessionId: input.sessionId, blockId: block.blockId };
      const details = yield* info(target);
      const address = yield* Option.match(details.address, {
        onNone: () =>
          Effect.fail(
            new RexInvalidResponse(
              "com.superlogical.tunnel.info",
              undefined,
              "a listen tunnel reported no address",
            ),
          ),
        onSome: Effect.succeed,
      });
      const clientId = (yield* control.connection).clientId;
      const carry = (connection: RexTunnelConnection) =>
        FiberSet.run(
          fibers,
          Effect.scoped(
            Effect.gen(function* () {
              const stream = yield* connection.accept;
              const socket = yield* connectLocal(input.target.host, input.target.port);
              yield* bridgeSocketToStream(socket, stream);
            }),
          ).pipe(Effect.ignore),
        );
      const stopped = yield* watchForwardStopped(events, target, (event) =>
        Effect.gen(function* () {
          const connection = yield* streams.connectionRequest(event, target, clientId);
          if (Option.isSome(connection)) yield* carry(connection.value);
        }),
      );
      return { blockId: block.blockId, address, stopped } satisfies RexForward;
    }).pipe(Effect.withSpan("TunnelService.forwardRemote"));

  return TunnelService.of({
    createDial,
    createListen,
    info,
    openStream: streams.openStream,
    connections: streams.connections,
    forwardLocal,
    forwardRemote,
  });
});

/**
 * Tunnel operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const tunnelServiceLayerWithoutDependencies: Layer.Layer<
  TunnelService,
  never,
  RexControl | RexAttachments | RexConfig
> = Layer.effect(TunnelService, makeTunnelService);

/**
 * Tunnel operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const tunnelServiceLayer: Layer.Layer<TunnelService, RexConfigurationError> =
  tunnelServiceLayerWithoutDependencies.pipe(
    Layer.provide(rexCoreLayerWithoutDependencies),
    Layer.provide(rexConfigLayer),
  );
