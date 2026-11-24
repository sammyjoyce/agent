/**
 * Byte streams (`rex.data.bytes.v1`): the data connections that carry file downloads, uploads,
 * and tunnel connections.
 *
 * Rex does not document this subprotocol; `docs/research/rex-data-bytes-v1.md` records what was
 * observed. Each binary message carries raw bytes. An empty message is a half-close: the side
 * that sends it sends nothing more. The stream succeeds only when the server closes with status
 * 1000 after at least one side has half-closed; any other close, or a connection that ends
 * without one, is a failure, whatever bytes arrived. Byte streams cannot be resumed.
 *
 * Closing the stream's scope before it finishes aborts it with status 4001, which cancels a
 * download or upload and resets a tunnel's TCP connection.
 *
 * @since 0.1.0
 */
import { Cause, Deferred, Duration, Effect, Option, Queue, Scope, Stream } from "effect";
import type { IRexConfig } from "./rex-config.ts";
import {
  openRexDataConnection,
  REX_BYTES_DATA_SUBPROTOCOL,
  rexDataCloseFailure,
} from "./rex-data-connection.ts";
import {
  RexConnectionError,
  RexInvalidResponse,
  RexTransferIncomplete,
  RexTransferStalled,
  RexTransferTooLarge,
  type RexBytesStreamError,
  type RexDataError,
} from "./rex-errors.ts";

/** Largest message the SDK sends; Rex itself sends at most 32 KiB. */
const maxMessageBytes = 64 * 1024;

/** How many received messages wait for the reader before the socket is paused. */
const incomingBufferMessages = 16;

/** The close status that aborts a byte stream: a cancel, or a TCP reset on a tunnel. */
const abortCloseCode = 4001;

/**
 * Limits on what a byte stream receives.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexBytesStreamLimits {
  /** Stop with `RexTransferTooLarge` once more than this many bytes arrive. */
  readonly maxBytes?: number | undefined;
  /**
   * Stop with `RexTransferStalled` when nothing arrives for this long before the other side
   * finishes sending. Rex never pings a data connection, so a stalled transfer otherwise waits
   * forever.
   */
  readonly stallTimeout?: Duration.Input | undefined;
  /**
   * Stop with `RexTransferStalled` when the server has not closed the stream this long after the
   * other side half-closed. Set it for a stream that ends with the other side's half-close, such
   * as a download; leave it out for one that stays open, such as a tunnel's idle TCP connection
   * after a half-close.
   */
  readonly closeTimeout?: Duration.Input | undefined;
}

/**
 * An open byte stream in both directions.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexBytesStream {
  /** The other side's bytes. Ends when the other side half-closes; read it once. */
  readonly incoming: Stream.Stream<Uint8Array, RexBytesStreamError>;
  /**
   * Sends bytes, returning once they are handed to the connection, so a fast writer waits for a
   * slow link. An empty chunk sends nothing.
   */
  readonly write: (chunk: Uint8Array) => Effect.Effect<void, RexBytesStreamError>;
  /** Half-closes: tells the other side this side sends nothing more. */
  readonly end: Effect.Effect<void, RexBytesStreamError>;
  /** Succeeds when the stream finished: the server closed it with 1000 after a half-close. */
  readonly done: Effect.Effect<void, RexBytesStreamError>;
}

/**
 * Opens a byte stream with a HELLO built from a ticket, within the current scope.
 *
 * @param blockId - The block the stream belongs to, for error messages.
 *
 * @category constructors
 * @since 0.1.0
 */
export function openRexBytesStream(
  config: IRexConfig,
  hello: Uint8Array,
  blockId: string,
  limits: RexBytesStreamLimits = {},
): Effect.Effect<RexBytesStream, RexDataError, Scope.Scope> {
  return Effect.gen(function* () {
    const scope = yield* Effect.scope;
    const connection = yield* openRexDataConnection(
      config,
      { subprotocol: REX_BYTES_DATA_SUBPROTOCOL, handshake: hello, blockId },
      scope,
    );
    const webSocket = connection.webSocket;
    const incoming = yield* Queue.bounded<Uint8Array, RexBytesStreamError | Cause.Done>(
      incomingBufferMessages,
    );
    const finished = yield* Deferred.make<void, RexBytesStreamError>();
    const toMillis = (timeout: Duration.Input | undefined) =>
      Option.map(Option.fromUndefinedOr(timeout), (input) =>
        Duration.toMillis(Duration.fromInputUnsafe(input)),
      );
    const stallMillis = toMillis(limits.stallTimeout);
    const closeMillis = toMillis(limits.closeTimeout);
    let remoteEnded = false;
    let localEnded = false;
    let settled = false;
    let receivedBytes = 0;

    const succeed = Effect.gen(function* () {
      settled = true;
      yield* Queue.end(incoming);
      yield* Deferred.succeed(finished, undefined);
    });
    /** Ends the stream with a failure; a failure found here, not by the server, aborts it. */
    const fail = (error: RexBytesStreamError, abort: boolean) =>
      Effect.gen(function* () {
        settled = true;
        if (abort) webSocket.close(abortCloseCode, "aborted");
        yield* Queue.fail(incoming, error);
        yield* Deferred.fail(finished, error);
      });
    const violation = (reason: string) =>
      fail(new RexInvalidResponse(REX_BYTES_DATA_SUBPROTOCOL, undefined, reason), true);

    /** Applies the protocol to received frames; returns false once the stream has ended. */
    const receive = (frames: ReadonlyArray<string | Uint8Array>) =>
      Effect.gen(function* () {
        for (const frame of frames) {
          if (typeof frame === "string") {
            yield* violation("the server sent a text message");
            return false;
          }
          if (remoteEnded) {
            yield* violation("the server sent a message after its half-close");
            return false;
          }
          if (frame.length === 0) {
            remoteEnded = true;
            yield* Queue.end(incoming);
            continue;
          }
          receivedBytes += frame.length;
          if (limits.maxBytes !== undefined && receivedBytes > limits.maxBytes) {
            yield* fail(new RexTransferTooLarge(blockId, limits.maxBytes), true);
            return false;
          }
          yield* Queue.offer(incoming, frame);
        }
        return true;
      });

    const pull = Effect.result(connection.reader.pull);
    const pump = Effect.gen(function* () {
      if (!(yield* receive(connection.leftover))) return;
      while (true) {
        // Before the server's half-close, the stall timer bounds each message; after it, the close
        // timer bounds the wait for the server to close the stream.
        const deadline = remoteEnded ? closeMillis : stallMillis;
        const next = Option.isSome(deadline)
          ? yield* pull.pipe(Effect.timeoutOption(deadline.value))
          : Option.some(yield* pull);
        if (Option.isNone(next)) {
          return yield* fail(
            new RexTransferStalled(blockId, deadline.pipe(Option.getOrElse(() => 0))),
            true,
          );
        }
        const result = next.value;
        if (result._tag === "Success") {
          if (!(yield* receive(result.success))) return;
          continue;
        }
        const failure = rexDataCloseFailure(config, blockId, result.failure);
        if (failure !== undefined) return yield* fail(failure, false);
        if (!remoteEnded && !localEnded) {
          return yield* fail(
            new RexTransferIncomplete(blockId, "the stream closed before either side finished"),
            false,
          );
        }
        return yield* succeed;
      }
    });
    yield* Effect.forkIn(pump, scope);
    yield* Scope.addFinalizer(
      scope,
      Effect.sync(() => {
        if (!settled) webSocket.close(abortCloseCode, "cancelled");
      }),
    );

    /** Sends one message once the socket has taken it; reports the stream's own end if it ended. */
    const send = (message: Uint8Array): Effect.Effect<void, RexBytesStreamError> =>
      Effect.callback<void, RexConnectionError>((resume) => {
        if (webSocket.readyState !== webSocket.OPEN) {
          resume(
            Effect.fail(
              new RexConnectionError(config.endpointDisplay, "write", "the stream is closed"),
            ),
          );
          return;
        }
        webSocket.send(message, { binary: true }, (error) =>
          resume(
            error === undefined || error === null
              ? Effect.void
              : Effect.fail(new RexConnectionError(config.endpointDisplay, "write", error)),
          ),
        );
      }).pipe(
        Effect.catchTag("RexConnectionError", (writeError) =>
          Deferred.await(finished).pipe(
            Effect.flatMap(() => Effect.fail(writeError)),
            Effect.timeoutOrElse({ duration: "1 second", orElse: () => Effect.fail(writeError) }),
          ),
        ),
      );

    return {
      incoming: Stream.fromQueue(incoming),
      write: (chunk) =>
        Effect.gen(function* () {
          if (localEnded) return yield* Effect.die(new Error("write after end on a byte stream"));
          for (let offset = 0; offset < chunk.length; offset += maxMessageBytes) {
            yield* send(chunk.subarray(offset, offset + maxMessageBytes));
          }
        }),
      end: Effect.suspend(() => {
        if (localEnded) return Effect.void;
        localEnded = true;
        return send(new Uint8Array(0));
      }),
      done: Deferred.await(finished),
    } satisfies RexBytesStream;
  });
}
