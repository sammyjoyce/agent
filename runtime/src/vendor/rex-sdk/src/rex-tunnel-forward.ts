/**
 * Connects TCP sockets on this machine to tunnel byte streams.
 *
 * A tunnel carries one TCP connection per byte stream. This module owns the local side: listening
 * and connecting with `node:net`, and the bridge between a socket and a stream. The bridge keeps
 * TCP's semantics across the tunnel: a socket's FIN becomes the stream's half-close and the
 * stream's half-close becomes a FIN, and a failure on either side resets the other. Sockets are
 * read on demand and written with confirmation, so a slow side slows the other instead of
 * buffering without limit.
 *
 * @since 0.1.0
 */
import { createServer, connect, type Server, type Socket } from "node:net";
import { Effect, Option, Scope, Stream } from "effect";
import type { RexBytesStream } from "./rex-bytes-stream.ts";
import { RexForwardSocketError } from "./rex-errors.ts";

/** A local socket failed while a tunnel connection was being carried. */
class LocalSocketFailure {
  readonly _tag = "LocalSocketFailure";
  readonly cause: unknown;
  constructor(cause: unknown) {
    this.cause = cause;
  }
}

function ignoreError(): void {}

/** Formats a host and port the way people write them: `[::1]:80` for IPv6. */
export function formatHostPort(host: string, port: number): string {
  return host.includes(":") ? `[${host}]:${port}` : `${host}:${port}`;
}

/** Reads the next chunk a socket received, or none once the peer sent its FIN. */
function readSocketChunk(
  socket: Socket,
): Effect.Effect<Option.Option<Uint8Array>, LocalSocketFailure> {
  return Effect.callback((resume) => {
    const cleanup = () => {
      socket.off("readable", onReadable);
      socket.off("end", onEnd);
      socket.off("error", onError);
      socket.off("close", onClose);
    };
    const tryRead = (): boolean => {
      const chunk: Buffer | null = socket.read();
      if (chunk === null) return false;
      cleanup();
      resume(Effect.succeed(Option.some(new Uint8Array(chunk))));
      return true;
    };
    const onReadable = () => {
      tryRead();
    };
    const onEnd = () => {
      cleanup();
      resume(Effect.succeed(Option.none()));
    };
    const onError = (error: Error) => {
      cleanup();
      resume(Effect.fail(new LocalSocketFailure(error)));
    };
    const onClose = () => {
      cleanup();
      resume(Effect.fail(new LocalSocketFailure("the socket closed before its FIN")));
    };
    if (socket.readableEnded) return resume(Effect.succeed(Option.none()));
    if (tryRead()) return;
    socket.on("readable", onReadable);
    socket.once("end", onEnd);
    socket.once("error", onError);
    socket.once("close", onClose);
    return Effect.sync(cleanup);
  });
}

/** Writes to a socket and waits until the chunk is flushed to the system. */
function writeSocket(socket: Socket, chunk: Uint8Array): Effect.Effect<void, LocalSocketFailure> {
  return Effect.callback((resume) => {
    socket.write(chunk, (error) =>
      resume(
        error === undefined || error === null
          ? Effect.void
          : Effect.fail(new LocalSocketFailure(error)),
      ),
    );
  });
}

/**
 * Carries one TCP connection over one tunnel stream until both directions finish.
 *
 * On success both sides have sent their FIN and the socket closes on its own. On any failure the
 * socket is reset, and closing the stream's scope aborts the stream, which resets the far side.
 */
export function bridgeSocketToStream(socket: Socket, stream: RexBytesStream): Effect.Effect<void> {
  // Reads and writes report their own failures; this keeps a late error from crashing the process.
  socket.on("error", ignoreError);
  const toStream = Effect.gen(function* () {
    while (true) {
      const chunk = yield* readSocketChunk(socket);
      if (Option.isNone(chunk)) return yield* stream.end;
      yield* stream.write(chunk.value);
    }
  });
  const fromStream = stream.incoming.pipe(
    Stream.runForEach((chunk) => writeSocket(socket, chunk)),
    Effect.andThen(Effect.sync(() => socket.end())),
  );
  return Effect.all([toStream, fromStream], { concurrency: 2, discard: true }).pipe(
    Effect.andThen(stream.done),
    Effect.catchCause(() => Effect.sync(() => socket.resetAndDestroy())),
    Effect.onInterrupt(() => Effect.sync(() => socket.resetAndDestroy())),
  );
}

/**
 * Listens on this machine for the scope's lifetime, in half-open mode so a FIN from one side of a
 * tunnel connection doesn't end the other.
 *
 * @returns The server and the address it bound, with the port it picked when asked for port 0.
 */
export function listenLocal(
  host: string,
  port: number,
  onConnection: (socket: Socket) => void,
): Effect.Effect<
  { readonly server: Server; readonly address: string },
  RexForwardSocketError,
  Scope.Scope
> {
  const requested = formatHostPort(host, port);
  return Effect.acquireRelease(
    Effect.callback<{ readonly server: Server; readonly address: string }, RexForwardSocketError>(
      (resume) => {
        const server = createServer({ allowHalfOpen: true }, onConnection);
        server.once("error", (error) =>
          resume(Effect.fail(new RexForwardSocketError("listen", requested, error))),
        );
        server.listen(port, host, () => {
          const bound = server.address();
          const address =
            bound !== null && typeof bound === "object"
              ? formatHostPort(bound.address, bound.port)
              : requested;
          server.on("error", ignoreError);
          resume(Effect.succeed({ server, address }));
        });
      },
    ),
    ({ server }) =>
      Effect.sync(() => {
        server.close();
      }),
  );
}

/** Connects to a TCP address on this machine, in half-open mode. */
export function connectLocal(
  host: string,
  port: number,
): Effect.Effect<Socket, RexForwardSocketError> {
  const address = formatHostPort(host, port);
  return Effect.callback((resume) => {
    const socket = connect({ host, port, allowHalfOpen: true });
    const onError = (error: Error) =>
      resume(Effect.fail(new RexForwardSocketError("connect", address, error)));
    socket.once("error", onError);
    socket.once("connect", () => {
      socket.off("error", onError);
      resume(Effect.succeed(socket));
    });
    return Effect.sync(() => socket.destroy());
  });
}
