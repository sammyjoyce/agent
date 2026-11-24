/**
 * A terminal's output stream: opening it, resuming it, and separating program output from Rex's
 * own messages.
 *
 * Opening a stream asks the control connection for a ticket (`data.connect`) and opens a data
 * connection with `rex.data.terminal.v1`. If the connection drops, the stream resumes on a new
 * connection with a RESUME carrying the exact count of bytes received, so no output is lost or
 * repeated.
 *
 * Rex places messages in the stream as APC sequences, `ESC _ rex1;<nonce>;<json> ESC \`, where
 * the nonce is the WELCOME's channel nonce in decimal. A sequence with another nonce was printed
 * by a program, so it stays in the output unchanged. The parser keeps state across chunks,
 * because a sequence can be split between two messages.
 *
 * @since 0.1.0
 */
import { Effect, Exit, Option, Queue, Schema, Scope, Stream } from "effect";
import type { Socket } from "effect/socket";
import { DataConnectResult } from "./generated/rex-wire-schemas.ts";
import type { IRexAttachments } from "./rex-attachments.ts";
import type { IRexConfig } from "./rex-config.ts";
import type { IRexControl } from "./rex-control.ts";
import { encodeRexDataResume } from "./rex-data-codec.ts";
import {
  openRexDataConnection,
  REX_TERMINAL_DATA_SUBPROTOCOL,
  rexDataCloseFailure,
  rexDataHelloFromTicket,
} from "./rex-data-connection.ts";
import type { RexDataError, RexOperationError } from "./rex-errors.ts";
import { decodeRexResult, sendRexRequest, type RexBlockTarget } from "./rex-operation.ts";

/**
 * A message Rex placed in a terminal stream.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalStreamMessage =
  | {
      readonly type: "resize";
      readonly cols: number;
      readonly rows: number;
      /** A cell's width in pixels, or 0 when unknown. */
      readonly cellWidthPx: number;
      /** A cell's height in pixels, or 0 when unknown. */
      readonly cellHeightPx: number;
      /** The block's owner when the size was set. */
      readonly owner: Option.Option<string>;
    }
  | {
      readonly type: "theme";
      readonly foreground: Option.Option<string>;
      readonly background: Option.Option<string>;
      readonly cursor: Option.Option<string>;
      /** Changes to the 256-color palette, each as `index=RRGGBB`. */
      readonly palette: ReadonlyArray<string>;
      readonly scheme: Option.Option<string>;
    }
  | { readonly type: "child_exited"; readonly exitCode: number }
  | { readonly type: "unknown"; readonly messageType: string; readonly message: Schema.Json };

/**
 * One item of a terminal stream: program output bytes or a Rex message.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalStreamItem =
  | { readonly _tag: "Output"; readonly bytes: Uint8Array }
  | { readonly _tag: "Message"; readonly message: RexTerminalStreamMessage };

const ResizeMessage = Schema.Struct({
  type: Schema.Literal("resize"),
  cols: Schema.Int,
  rows: Schema.Int,
  cell_width_px: Schema.optionalKey(Schema.Int),
  cell_height_px: Schema.optionalKey(Schema.Int),
  owner: Schema.optionalKey(Schema.NullOr(Schema.String)),
});
const ThemeMessage = Schema.Struct({
  type: Schema.Literal("theme"),
  foreground: Schema.optionalKey(Schema.String),
  background: Schema.optionalKey(Schema.String),
  cursor: Schema.optionalKey(Schema.String),
  palette: Schema.optionalKey(Schema.NullOr(Schema.Array(Schema.String))),
  scheme: Schema.optionalKey(Schema.String),
});
const ChildExitedMessage = Schema.Struct({
  type: Schema.Literal("child_exited"),
  exit_code: Schema.Int,
});
const AnyMessage = Schema.Struct({ type: Schema.String });

const decodeMessageJson = Schema.decodeUnknownOption(Schema.fromJsonString(Schema.Json));
const decodeResize = Schema.decodeUnknownOption(ResizeMessage);
const decodeTheme = Schema.decodeUnknownOption(ThemeMessage);
const decodeChildExited = Schema.decodeUnknownOption(ChildExitedMessage);
const decodeAnyMessage = Schema.decodeUnknownOption(AnyMessage);
const decodeJson = Schema.decodeUnknownOption(Schema.Json);

function parseRexTerminalStreamMessage(json: string): Option.Option<RexTerminalStreamMessage> {
  const value = decodeMessageJson(json);
  if (Option.isNone(value)) return Option.none();
  const resize = decodeResize(value.value);
  if (Option.isSome(resize)) {
    return Option.some({
      type: "resize",
      cols: resize.value.cols,
      rows: resize.value.rows,
      cellWidthPx: resize.value.cell_width_px ?? 0,
      cellHeightPx: resize.value.cell_height_px ?? 0,
      owner: Option.fromNullishOr(resize.value.owner),
    });
  }
  const theme = decodeTheme(value.value);
  if (Option.isSome(theme)) {
    return Option.some({
      type: "theme",
      foreground: Option.fromUndefinedOr(theme.value.foreground),
      background: Option.fromUndefinedOr(theme.value.background),
      cursor: Option.fromUndefinedOr(theme.value.cursor),
      palette: theme.value.palette ?? [],
      scheme: Option.fromUndefinedOr(theme.value.scheme),
    });
  }
  const childExited = decodeChildExited(value.value);
  if (Option.isSome(childExited)) {
    return Option.some({ type: "child_exited", exitCode: childExited.value.exit_code });
  }
  const other = decodeAnyMessage(value.value);
  const message = decodeJson(value.value);
  if (Option.isSome(other) && Option.isSome(message)) {
    return Option.some({ type: "unknown", messageType: other.value.type, message: message.value });
  }
  return Option.none();
}

const ESC = 0x1b;
const APC_INTRODUCER = 0x5f; // "_"
const STRING_TERMINATOR = 0x5c; // "\"
const REX_PREFIX = new TextEncoder().encode("rex1;");
/** A partial sequence longer than this is treated as program output rather than held back. */
const MAX_PENDING_SEQUENCE = 1_048_576;

/**
 * Incremental parser for one terminal stream.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalStreamParser {
  /** Parses the next chunk, returning the items that are complete so far. */
  readonly push: (chunk: Uint8Array) => ReadonlyArray<RexTerminalStreamItem>;
  /** Returns bytes held back while waiting for the end of a possible Rex sequence. */
  readonly flush: () => ReadonlyArray<RexTerminalStreamItem>;
}

/**
 * Creates a parser for a stream whose WELCOME carried `nonce`.
 *
 * @category constructors
 * @since 0.1.0
 */
export function makeRexTerminalStreamParser(nonce: bigint): RexTerminalStreamParser {
  const nonceText = nonce.toString();
  const decoder = new TextDecoder();
  let pending: Uint8Array = new Uint8Array(0);

  const startsWithPrefix = (data: Uint8Array, at: number) => {
    for (let index = 0; index < REX_PREFIX.length; index += 1) {
      if (at + index >= data.length) return "incomplete";
      if (data[at + index] !== REX_PREFIX[index]) return "no";
    }
    return "yes";
  };

  const findTerminator = (data: Uint8Array, from: number) => {
    for (let index = from; index + 1 < data.length; index += 1) {
      if (data[index] === ESC && data[index + 1] === STRING_TERMINATOR) return index;
    }
    return -1;
  };

  const push = (chunk: Uint8Array): ReadonlyArray<RexTerminalStreamItem> => {
    const data = pending.length === 0 ? chunk : concatBytes(pending, chunk);
    pending = new Uint8Array(0);
    const items: Array<RexTerminalStreamItem> = [];
    let outputStart = 0;
    let index = 0;
    const emitOutput = (end: number) => {
      if (end > outputStart) items.push({ _tag: "Output", bytes: data.slice(outputStart, end) });
    };
    while (index < data.length) {
      const escape = data.indexOf(ESC, index);
      if (escape === -1) break;
      if (escape + 1 >= data.length) {
        emitOutput(escape);
        pending = data.slice(escape);
        return items;
      }
      if (data[escape + 1] !== APC_INTRODUCER) {
        index = escape + 1;
        continue;
      }
      const prefix = startsWithPrefix(data, escape + 2);
      if (prefix === "no") {
        index = escape + 1;
        continue;
      }
      const bodyStart = escape + 2 + REX_PREFIX.length;
      const terminator = prefix === "yes" ? findTerminator(data, bodyStart) : -1;
      if (terminator === -1) {
        if (data.length - escape > MAX_PENDING_SEQUENCE) {
          index = escape + 1;
          continue;
        }
        emitOutput(escape);
        pending = data.slice(escape);
        return items;
      }
      const body = decoder.decode(data.subarray(bodyStart, terminator));
      const separator = body.indexOf(";");
      const message =
        separator !== -1 && body.slice(0, separator) === nonceText
          ? parseRexTerminalStreamMessage(body.slice(separator + 1))
          : Option.none();
      if (Option.isSome(message)) {
        emitOutput(escape);
        items.push({ _tag: "Message", message: message.value });
        outputStart = terminator + 2;
      }
      index = terminator + 2;
    }
    emitOutput(data.length);
    return items;
  };

  const flush = (): ReadonlyArray<RexTerminalStreamItem> => {
    const rest = pending;
    pending = new Uint8Array(0);
    return rest.length === 0 ? [] : [{ _tag: "Output", bytes: rest }];
  };

  return { push, flush };
}

function concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const joined = new Uint8Array(first.length + second.length);
  joined.set(first, 0);
  joined.set(second, first.length);
  return joined;
}

/**
 * Options for a terminal output stream.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalStreamOptions {
  /** How many times to resume after the connection drops before failing; defaults to 3. */
  readonly maxResumes?: number | undefined;
}

/** A drop the terminal stream resumes after: a read failure, 1006, or a keepalive timeout. */
function isResumable(error: Socket.SocketError): boolean {
  const reason = error.reason;
  if (reason._tag === "SocketReadError") return true;
  if (reason._tag !== "SocketCloseError") return false;
  return (
    reason.code === 1006 || (reason.code === 1001 && reason.closeReason === "keepalive timeout")
  );
}

/**
 * Opens a terminal's output stream: its snapshot, everything its program writes, and Rex's
 * resize, theme, and exit messages.
 *
 * The stream ends when the server ends it normally, and fails with `RexBlockClosed` when the
 * block closes. Closing the stream's scope closes the data connection with status 1000, which
 * ends the stream on the server.
 *
 * @category constructors
 * @since 0.1.0
 */
export function openRexTerminalStream(
  config: IRexConfig,
  control: IRexControl,
  attachments: IRexAttachments,
  target: RexBlockTarget,
  options: RexTerminalStreamOptions = {},
): Stream.Stream<RexTerminalStreamItem, RexDataError | RexOperationError> {
  const maxResumes = options.maxResumes ?? 3;
  const connect = (handshake: Uint8Array, scope: Scope.Scope) =>
    openRexDataConnection(
      config,
      { subprotocol: REX_TERMINAL_DATA_SUBPROTOCOL, handshake, blockId: target.blockId },
      scope,
    );

  return Stream.callback<RexTerminalStreamItem, RexDataError | RexOperationError>((queue) =>
    Effect.gen(function* () {
      const response = yield* sendRexRequest(control, attachments, "data.connect", {
        session_id: target.sessionId,
        block_id: target.blockId,
        data_ref_id: "terminal",
        subprotocol: REX_TERMINAL_DATA_SUBPROTOCOL,
      });
      const ticket = yield* decodeRexResult("data.connect", DataConnectResult, response.payload);
      const hello = yield* rexDataHelloFromTicket("data.connect", ticket.ticket);

      let scope = yield* Scope.make();
      let connection = yield* connect(hello, scope);
      const parser = makeRexTerminalStreamParser(connection.nonce);
      let receivedBytes = 0n;
      let resumes = 0;
      let frames: ReadonlyArray<string | Uint8Array> = connection.leftover;

      yield* Effect.addFinalizer(() => Scope.close(scope, Exit.void));

      while (true) {
        for (const frame of frames) {
          if (typeof frame === "string") continue;
          receivedBytes += BigInt(frame.length);
          for (const item of parser.push(frame)) yield* Queue.offer(queue, item);
        }
        const next = yield* Effect.result(connection.reader.pull);
        if (next._tag === "Success") {
          frames = next.success;
          continue;
        }
        const error = next.failure;
        if (isResumable(error) && resumes < maxResumes) {
          resumes += 1;
          yield* Scope.close(scope, Exit.void);
          scope = yield* Scope.make();
          connection = yield* connect(
            encodeRexDataResume(connection.reconnectToken, receivedBytes),
            scope,
          );
          frames = connection.leftover;
          continue;
        }
        for (const item of parser.flush()) yield* Queue.offer(queue, item);
        const failure = rexDataCloseFailure(config, target.blockId, error);
        if (failure !== undefined) return yield* Effect.fail(failure);
        yield* Queue.end(queue);
        return;
      }
    }),
  );
}
