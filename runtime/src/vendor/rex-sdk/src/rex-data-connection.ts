/**
 * Data connections: the WebSockets at `/api/data` that carry a block's terminal output or bytes.
 *
 * Every data connection starts the same way, whatever it carries: the control connection issues
 * a single-use ticket, the client opens `/api/data` with a subprotocol and sends a HELLO (or a
 * RESUME), and the server answers with a WELCOME or a REJECT. This module owns that handshake,
 * the conversion of tickets into HELLO bytes (so ticket strings never travel further), and the
 * meaning of a data connection's close codes. The terminal stream (`rex-terminal-stream.ts`) and
 * the byte stream (`rex-bytes-stream.ts`) build on it.
 *
 * @since 0.1.0
 */
import { Effect, Option, Scope } from "effect";
import { Socket } from "effect/socket";
import type { WebSocket } from "ws";
import type { IRexConfig } from "./rex-config.ts";
import { openRexWebSocket } from "./rex-control.ts";
import { decodeRexDataHandshakeReply, encodeRexDataHello } from "./rex-data-codec.ts";
import {
  RexBlockClosed,
  RexConnectionError,
  RexDataRejected,
  RexDataStreamFailed,
  RexInvalidResponse,
  type RexDataError,
} from "./rex-errors.ts";

/**
 * The subprotocol of a terminal's output stream.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_TERMINAL_DATA_SUBPROTOCOL = "rex.data.terminal.v1";

/**
 * The subprotocol of a byte stream: file downloads and uploads, and tunnel connections.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_BYTES_DATA_SUBPROTOCOL = "rex.data.bytes.v1";

/** A subprotocol the SDK speaks on a data connection. */
export type RexDataSubprotocol =
  | typeof REX_TERMINAL_DATA_SUBPROTOCOL
  | typeof REX_BYTES_DATA_SUBPROTOCOL;

/** An open data connection, after its WELCOME. */
export interface RexDataConnection {
  /** Frames after the WELCOME. */
  readonly reader: Socket.Reader<string | Uint8Array>;
  /** The WebSocket, for writes that wait until each message is handed to the socket. */
  readonly webSocket: WebSocket;
  /** Frames that arrived in the same batch as the WELCOME. */
  readonly leftover: ReadonlyArray<Uint8Array>;
  /** Presented in a RESUME to continue a terminal stream on a new connection. */
  readonly reconnectToken: Uint8Array;
  /** Marks Rex's own messages inside a terminal stream. */
  readonly nonce: bigint;
}

/** What {@link openRexDataConnection} needs to open one data connection. */
export interface RexDataConnectionOptions {
  readonly subprotocol: RexDataSubprotocol;
  /** The HELLO or RESUME to send first. */
  readonly handshake: Uint8Array;
  /** The block the connection reads from, for error messages. */
  readonly blockId: string;
}

/**
 * Turns a ticket from a control response into HELLO bytes. The ticket string goes no further.
 *
 * @param method - The method that issued the ticket, for the failure if it is malformed.
 */
export function rexDataHelloFromTicket(
  method: string,
  ticket: string,
): Effect.Effect<Uint8Array, RexInvalidResponse> {
  return Effect.fromOption(encodeRexDataHello(ticket)).pipe(
    Effect.mapError(
      () => new RexInvalidResponse(method, undefined, "the ticket is not 16 bytes of base64url"),
    ),
  );
}

/**
 * The failure a data connection's end means, or `undefined` for close 1000.
 *
 * 4000 means the block closed; another close code means the server stopped the stream; anything
 * else is a connection failure.
 */
export function rexDataCloseFailure(
  config: IRexConfig,
  blockId: string,
  error: Socket.SocketError,
): RexDataError | undefined {
  const reason = error.reason;
  if (reason._tag !== "SocketCloseError") {
    return new RexConnectionError(
      config.endpointDisplay,
      reason._tag === "SocketOpenError" ? "connect" : "read",
      error,
    );
  }
  if (reason.code === 1000) return undefined;
  if (reason.code === 4000) return new RexBlockClosed(blockId);
  return new RexDataStreamFailed(blockId, reason.code, reason.closeReason ?? "");
}

/**
 * Opens `/api/data`, sends the handshake, and waits for the WELCOME, all within `scope`.
 *
 * Closing `scope` closes the WebSocket with status 1000. Fails with `RexDataRejected` when the
 * server answers with a REJECT, and with `RexConnectionError` when no WELCOME arrives within the
 * configured connect timeout.
 */
export function openRexDataConnection(
  config: IRexConfig,
  options: RexDataConnectionOptions,
  scope: Scope.Scope,
): Effect.Effect<RexDataConnection, RexDataError> {
  return Effect.gen(function* () {
    let webSocket: WebSocket | undefined;
    const socket = yield* Socket.fromWebSocket(
      Effect.acquireRelease(
        Effect.sync(() => {
          webSocket = openRexWebSocket(config, "/api/data", options.subprotocol, false);
          return webSocket;
        }),
        (ws) => Effect.sync(() => ws.close(1000)),
      ),
      { openTimeout: config.connectTimeout },
    );
    const reader = yield* socket.reader.pipe(
      Scope.provide(scope),
      Effect.mapError((error) => new RexConnectionError(config.endpointDisplay, "connect", error)),
    );
    const writer = yield* socket.writer.pipe(Scope.provide(scope));
    yield* writer
      .write(options.handshake)
      .pipe(
        Effect.mapError((error) => new RexConnectionError(config.endpointDisplay, "write", error)),
      );
    if (webSocket === undefined) {
      return yield* new RexConnectionError(
        config.endpointDisplay,
        "connect",
        "the data connection opened without a WebSocket",
      );
    }
    while (true) {
      const frames = yield* reader.pull.pipe(
        Effect.mapError(
          (error): RexDataError =>
            rexDataCloseFailure(config, options.blockId, error) ??
            new RexDataStreamFailed(options.blockId, 1000, "the stream ended during the handshake"),
        ),
      );
      const [first, ...rest] = frames.filter(
        (frame): frame is Uint8Array => typeof frame !== "string",
      );
      if (first === undefined) continue;
      const reply = decodeRexDataHandshakeReply(first);
      if (Option.isNone(reply)) {
        return yield* new RexInvalidResponse(
          "data handshake",
          undefined,
          "not a WELCOME or REJECT",
        );
      }
      if (reply.value._tag === "Reject") return yield* new RexDataRejected(reply.value.reason);
      return {
        reader,
        webSocket,
        leftover: rest,
        reconnectToken: reply.value.reconnectToken,
        nonce: reply.value.nonce,
      } satisfies RexDataConnection;
    }
  }).pipe(
    Effect.timeoutOrElse({
      duration: config.connectTimeout,
      orElse: () =>
        Effect.fail(
          new RexConnectionError(config.endpointDisplay, "connect", "no WELCOME arrived in time"),
        ),
    }),
  );
}
