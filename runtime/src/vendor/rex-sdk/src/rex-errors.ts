/**
 * Typed failures exposed by Rex SDK operations.
 *
 * Local failures (configuration, input), connection failures, deadline failures, response and
 * event decoding failures, every error code the Rex server documents, and data-stream failures
 * each have their own tag, so callers recover with `Effect.catchTag` instead of parsing prose.
 *
 * @since 0.1.0
 */
import { Option, Schema } from "effect";

/**
 * Failure to resolve SDK configuration, such as an unusable `REX_SERVER` value.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexConfigurationError extends Schema.TaggedError<RexConfigurationError>()(
  "RexConfigurationError",
  {
    reason: Schema.String,
    message: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {
  /** Creates a configuration failure with the specific reason it could not be resolved. */
  constructor(reason: string, cause?: unknown) {
    super({
      reason,
      message: `Rex SDK configuration is invalid: ${reason}. Correct the SDK options or the REX_* environment and try again.`,
      cause,
    });
  }
}

/**
 * Caller input that does not satisfy the operation's argument schema; nothing was sent.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexInvalidInput extends Schema.TaggedError<RexInvalidInput>()("RexInvalidInput", {
  operation: Schema.String,
  message: Schema.String,
  cause: Schema.Defect(),
}) {
  /** Creates an input failure for a named operation; the request was not sent. */
  constructor(operation: string, cause: unknown) {
    super({
      operation,
      message: `Arguments for ${operation} are invalid, so nothing was sent to the Rex server. Correct the arguments and try again.`,
      cause,
    });
  }
}

/**
 * The control or data connection could not be opened, or failed while reading or writing.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexConnectionError extends Schema.TaggedError<RexConnectionError>()(
  "RexConnectionError",
  {
    endpoint: Schema.String,
    reason: Schema.Literals(["connect", "read", "write"]),
    message: Schema.String,
    cause: Schema.Defect(),
  },
) {
  /** Creates a classified connection failure for an endpoint. */
  constructor(endpoint: string, reason: RexConnectionError["reason"], cause: unknown) {
    super({
      endpoint,
      reason,
      message:
        reason === "connect"
          ? `Could not connect to the Rex server at ${endpoint}. Check that the server is running and that the endpoint is correct.`
          : `The connection to the Rex server at ${endpoint} failed while ${reason === "read" ? "reading" : "writing"}. Requests that were in flight may or may not have run; inspect the affected resources before retrying.`,
      cause,
    });
  }
}

/**
 * The server did not complete the control handshake: no welcome, or the wrong protocol.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexHandshakeError extends Schema.TaggedError<RexHandshakeError>()(
  "RexHandshakeError",
  {
    endpoint: Schema.String,
    reason: Schema.String,
    message: Schema.String,
  },
) {
  /** Creates a handshake failure with the specific reason the welcome was unusable. */
  constructor(endpoint: string, reason: string) {
    super({
      endpoint,
      reason,
      message: `The Rex server at ${endpoint} did not complete the control handshake: ${reason}. Check that the endpoint is a Rex server.`,
    });
  }
}

/**
 * The server does not speak the API revision this SDK was generated for.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexUnsupportedApiRevision extends Schema.TaggedError<RexUnsupportedApiRevision>()(
  "RexUnsupportedApiRevision",
  {
    endpoint: Schema.String,
    requiredRevision: Schema.Int,
    serverRevision: Schema.optional(Schema.Int),
    serverReason: Schema.optional(Schema.String),
    message: Schema.String,
  },
) {
  /** Creates a revision mismatch failure, keeping the server's explanation when it sent one. */
  constructor(options: {
    readonly endpoint: string;
    readonly requiredRevision: number;
    readonly serverRevision?: number | undefined;
    readonly serverReason?: string | undefined;
  }) {
    super({
      ...options,
      message: `The Rex server at ${options.endpoint} does not speak API revision ${options.requiredRevision}${options.serverReason === undefined ? "" : ` (${options.serverReason})`}. Install a Rex server and SDK release that share that revision.`,
    });
  }
}

/**
 * The server closed the control connection.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexConnectionClosed extends Schema.TaggedError<RexConnectionClosed>()(
  "RexConnectionClosed",
  {
    endpoint: Schema.String,
    code: Schema.Int,
    reason: Schema.String,
    message: Schema.String,
  },
) {
  /** Creates a close failure from the WebSocket close code and reason. */
  constructor(endpoint: string, code: number, reason: string) {
    super({
      endpoint,
      code,
      reason,
      message: `The Rex server at ${endpoint} closed the connection (code ${code}${reason.length === 0 ? "" : `, ${reason}`}). Requests that were in flight may or may not have run; inspect the affected resources before retrying.`,
    });
  }
}

/**
 * The connection ended before this request's response arrived; the request may have run.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexConnectionLost extends Schema.TaggedError<RexConnectionLost>()(
  "RexConnectionLost",
  {
    method: Schema.String,
    requestId: Schema.String,
    message: Schema.String,
    cause: Schema.Defect(),
  },
) {
  /** Creates an uncertain-outcome failure for one in-flight request. */
  constructor(method: string, requestId: string, cause: unknown) {
    super({
      method,
      requestId,
      message: `The connection to the Rex server ended before ${method} answered, so it may or may not have run. Inspect the affected resources before sending it again.`,
      cause,
    });
  }
}

/**
 * The SDK stopped waiting for a response; the server may still complete the request.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexRequestTimeout extends Schema.TaggedError<RexRequestTimeout>()(
  "RexRequestTimeout",
  {
    method: Schema.String,
    requestId: Schema.String,
    timeoutMillis: Schema.Number,
    message: Schema.String,
  },
) {
  /** Creates a local deadline failure for one request. */
  constructor(method: string, requestId: string, timeoutMillis: number) {
    super({
      method,
      requestId,
      timeoutMillis,
      message: `${method} did not answer within ${timeoutMillis} ms. The server may still complete it; inspect the affected resources before retrying with a longer deadline.`,
    });
  }
}

/**
 * A request is larger than the connection's message limit, so it was not sent.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexMessageTooLarge extends Schema.TaggedError<RexMessageTooLarge>()(
  "RexMessageTooLarge",
  {
    method: Schema.String,
    bytes: Schema.Int,
    limitBytes: Schema.Int,
    message: Schema.String,
  },
) {
  /** Creates a size failure for a request that was not sent. */
  constructor(method: string, bytes: number, limitBytes: number) {
    super({
      method,
      bytes,
      limitBytes,
      message: `${method} is ${bytes} bytes, more than the connection's limit of ${limitBytes} bytes, so it was not sent. Send less data in one call.`,
    });
  }
}

/**
 * A server message or result does not match the documented wire contract.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexInvalidResponse extends Schema.TaggedError<RexInvalidResponse>()(
  "RexInvalidResponse",
  {
    method: Schema.String,
    requestId: Schema.optional(Schema.String),
    message: Schema.String,
    cause: Schema.Defect(),
  },
) {
  /** Creates a contract failure for a result or message the SDK could not decode. */
  constructor(method: string, requestId: string | undefined, cause: unknown) {
    super({
      method,
      requestId,
      message: `The Rex server's answer to ${method} does not match the API revision this SDK was built for. The request may have run; inspect the affected resources, and check that the server and SDK versions match.`,
      cause,
    });
  }
}

/**
 * An event stream stopped because events were missed.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexEventsLost extends Schema.TaggedError<RexEventsLost>()("RexEventsLost", {
  reason: Schema.Literals(["subscriber_backlog", "connection_ended", "sequence_gap"]),
  message: Schema.String,
}) {
  /** Creates an events-lost failure with why events were missed. */
  constructor(reason: RexEventsLost["reason"]) {
    super({
      reason,
      message:
        reason === "subscriber_backlog"
          ? "An event subscriber fell too far behind, so its stream stopped instead of skipping events. Read the current state again and subscribe again."
          : reason === "connection_ended"
            ? "The connection to the Rex server ended, so events after that point were not received. Read the current state again and subscribe again."
            : "The Rex server's event sequence skipped a number, so an event was missed. Read the current state again and subscribe again.",
    });
  }
}

const serverErrorFields = {
  method: Schema.String,
  requestId: Schema.String,
  status: Schema.Int,
  serverMessage: Schema.String,
  message: Schema.String,
};

interface ServerErrorDetails {
  readonly method: string;
  readonly requestId: string;
  readonly status: number;
  readonly serverMessage: string;
}

function serverErrorMessage(details: ServerErrorDetails, guidance: string): string {
  return `${details.method} failed: ${details.serverMessage}. ${guidance}`;
}

/**
 * The server rejected the arguments (`bad_request`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexBadRequest extends Schema.TaggedError<RexBadRequest>()(
  "RexBadRequest",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(details, "Correct the arguments and try again."),
    });
  }
}

/**
 * Something the arguments name, such as a block, window, or layer, does not exist (`not_found`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexNotFound extends Schema.TaggedError<RexNotFound>()(
  "RexNotFound",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Look up current IDs, such as with session.view, and try again.",
      ),
    });
  }
}

/**
 * No session has the given ID; destroyed sessions are not remembered (`session_not_found`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexSessionNotFound extends Schema.TaggedError<RexSessionNotFound>()(
  "RexSessionNotFound",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(details, "List sessions to find a current session ID."),
    });
  }
}

/**
 * The server, or the named block, has no method by that name (`method_not_found`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexMethodNotFound extends Schema.TaggedError<RexMethodNotFound>()(
  "RexMethodNotFound",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "The server or block may be older than this SDK; check the server version and the block's methods.",
      ),
    });
  }
}

/**
 * The request cannot run in the current state, or a limit was reached (`conflict`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexConflict extends Schema.TaggedError<RexConflict>()(
  "RexConflict",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Read the current state; the request can succeed once it changes.",
      ),
    });
  }
}

/**
 * The named client cannot perform the action, or the server lacks the data (`not_supported`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexNotSupported extends Schema.TaggedError<RexNotSupported>()(
  "RexNotSupported",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Check the client's action list or the server's capabilities.",
      ),
    });
  }
}

/**
 * The named client chose not to perform the action (`refused`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexRefused extends Schema.TaggedError<RexRefused>()("RexRefused", serverErrorFields) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({ ...details, message: serverErrorMessage(details, "The server message says why.") });
  }
}

/**
 * The named client cannot take requests, such as when its connection dropped (`client_unavailable`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexClientUnavailable extends Schema.TaggedError<RexClientUnavailable>()(
  "RexClientUnavailable",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "List clients and try again once the client is connected.",
      ),
    });
  }
}

/**
 * The result or the change is larger than the server allows (`too_large`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexTooLarge extends Schema.TaggedError<RexTooLarge>()(
  "RexTooLarge",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Request less data at once, such as with max_bytes, or store less.",
      ),
    });
  }
}

/**
 * The method needs a newer API revision than the connection uses (`revision_too_low`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexRevisionTooLow extends Schema.TaggedError<RexRevisionTooLow>()(
  "RexRevisionTooLow",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({ ...details, message: serverErrorMessage(details, "Update the SDK.") });
  }
}

/**
 * The server stopped the request after its own time limit; some work may have happened (`timeout`).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexServerTimeout extends Schema.TaggedError<RexServerTimeout>()(
  "RexServerTimeout",
  serverErrorFields,
) {
  /** Creates the failure from a server error response. */
  constructor(details: ServerErrorDetails) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Some of its work may already have happened; inspect the affected resources before retrying.",
      ),
    });
  }
}

/**
 * The server failed for another reason (`internal`, or a code this SDK does not know).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexServerError extends Schema.TaggedError<RexServerError>()("RexServerError", {
  ...serverErrorFields,
  code: Schema.String,
}) {
  /** Creates the failure from a server error response, keeping the server's code. */
  constructor(details: ServerErrorDetails & { readonly code: string }) {
    super({
      ...details,
      message: serverErrorMessage(
        details,
        "Read the server message; if it doesn't point at the arguments, check the server's logs.",
      ),
    });
  }
}

/**
 * Any error the Rex server can answer a request with.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexServerFailure =
  | RexBadRequest
  | RexNotFound
  | RexSessionNotFound
  | RexMethodNotFound
  | RexConflict
  | RexNotSupported
  | RexRefused
  | RexClientUnavailable
  | RexTooLarge
  | RexRevisionTooLow
  | RexServerTimeout
  | RexServerError;

/**
 * Any failure of one request on an established or establishing control connection.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexRequestError =
  | RexServerFailure
  | RexConnectionError
  | RexHandshakeError
  | RexUnsupportedApiRevision
  | RexConnectionClosed
  | RexConnectionLost
  | RexRequestTimeout
  | RexMessageTooLarge
  | RexInvalidResponse;

/**
 * Any failure of a typed SDK operation, including rejected arguments.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexOperationError = RexRequestError | RexInvalidInput;

/**
 * Translates a server error body into its tagged failure; unknown codes keep their code.
 *
 * @category constructors
 * @since 0.1.0
 */
export function rexServerFailure(
  details: ServerErrorDetails & { readonly code: string },
): RexServerFailure {
  switch (details.code) {
    case "bad_request":
      return new RexBadRequest(details);
    case "not_found":
      return new RexNotFound(details);
    case "session_not_found":
      return new RexSessionNotFound(details);
    case "method_not_found":
      return new RexMethodNotFound(details);
    case "conflict":
      return new RexConflict(details);
    case "not_supported":
      return new RexNotSupported(details);
    case "refused":
      return new RexRefused(details);
    case "client_unavailable":
      return new RexClientUnavailable(details);
    case "too_large":
      return new RexTooLarge(details);
    case "revision_too_low":
      return new RexRevisionTooLow(details);
    case "timeout":
      return new RexServerTimeout(details);
    default:
      return new RexServerError(details);
  }
}

/**
 * The server refused a data connection handshake.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexDataRejected extends Schema.TaggedError<RexDataRejected>()("RexDataRejected", {
  reasonCode: Schema.Int,
  reason: Schema.Literals([
    "unknown_ticket",
    "already_connected",
    "stream_unavailable",
    "limit_reached",
    "malformed_handshake",
    "server_failed",
    "wrong_subprotocol",
    "unknown",
  ]),
  message: Schema.String,
}) {
  /** Creates the failure from a REJECT reason byte. */
  constructor(reasonCode: number) {
    const reason = dataRejectReasons[reasonCode] ?? "unknown";
    super({
      reasonCode,
      reason,
      message: `The Rex server refused the data connection (${reason}, 0x${reasonCode.toString(16).padStart(2, "0")}). Open the stream again with a new ticket.`,
    });
  }
}

const dataRejectReasons: Readonly<Record<number, RexDataRejected["reason"]>> = {
  1: "unknown_ticket",
  2: "already_connected",
  3: "stream_unavailable",
  4: "limit_reached",
  5: "malformed_handshake",
  6: "server_failed",
  7: "wrong_subprotocol",
};

/**
 * The block closed, ending its data stream (close code 4000).
 *
 * @category errors
 * @since 0.1.0
 */
export class RexBlockClosed extends Schema.TaggedError<RexBlockClosed>()("RexBlockClosed", {
  blockId: Schema.String,
  message: Schema.String,
}) {
  /** Creates the failure for a block whose stream ended because it closed. */
  constructor(blockId: string) {
    super({
      blockId,
      message: `Block ${blockId} closed, so its data stream ended. Do not reconnect to it.`,
    });
  }
}

/**
 * A terminal's program exited, or its output ended, before what a wait looked for appeared.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexTerminalExited extends Schema.TaggedError<RexTerminalExited>()(
  "RexTerminalExited",
  {
    blockId: Schema.String,
    exitCode: Schema.NullOr(Schema.Number),
    message: Schema.String,
  },
) {
  /** Creates the failure for a terminal whose program exited with `exitCode`, if known. */
  constructor(blockId: string, exitCode: Option.Option<number>) {
    super({
      blockId,
      exitCode: Option.getOrNull(exitCode),
      message: Option.isSome(exitCode)
        ? `The program in block ${blockId} exited with code ${exitCode.value} before the output appeared.`
        : `The output of block ${blockId} ended before the output appeared.`,
    });
  }
}

/**
 * A data stream ended for a reason other than the block closing.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexDataStreamFailed extends Schema.TaggedError<RexDataStreamFailed>()(
  "RexDataStreamFailed",
  {
    blockId: Schema.String,
    code: Schema.Int,
    reason: Schema.String,
    message: Schema.String,
  },
) {
  /** Creates the failure from the data connection's close code and reason. */
  constructor(blockId: string, code: number, reason: string) {
    super({
      blockId,
      code,
      reason,
      message: `The data stream of block ${blockId} ended (code ${code}${reason.length === 0 ? "" : `, ${reason}`}). Open a new stream to continue; a file transfer or tunnel connection on it did not finish.`,
    });
  }
}

/**
 * A data stream failure: refused, block closed, ended, or a connection failure.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexDataError =
  | RexDataRejected
  | RexBlockClosed
  | RexDataStreamFailed
  | RexConnectionError
  | RexInvalidResponse;

/**
 * A byte stream ended before it finished: a download without its end marker, or an upload
 * whose bytes did not match the size it declared.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexTransferIncomplete extends Schema.TaggedError<RexTransferIncomplete>()(
  "RexTransferIncomplete",
  {
    blockId: Schema.String,
    reason: Schema.String,
    message: Schema.String,
  },
) {
  /** Creates the failure with the specific reason the transfer is incomplete. */
  constructor(blockId: string, reason: string) {
    super({
      blockId,
      reason,
      message: `A file transfer with block ${blockId} did not finish: ${reason}. Discard any bytes it produced and start the transfer again.`,
    });
  }
}

/**
 * A byte stream received nothing for longer than its stall timeout, so the SDK stopped it.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexTransferStalled extends Schema.TaggedError<RexTransferStalled>()(
  "RexTransferStalled",
  {
    blockId: Schema.String,
    stallTimeoutMillis: Schema.Number,
    message: Schema.String,
  },
) {
  /** Creates the failure for a stream that went quiet for `stallTimeoutMillis`. */
  constructor(blockId: string, stallTimeoutMillis: number) {
    super({
      blockId,
      stallTimeoutMillis,
      message: `A file transfer with block ${blockId} received nothing for ${stallTimeoutMillis} ms, so it was stopped. Start it again, or raise stallTimeout for a slow link.`,
    });
  }
}

/**
 * A byte stream delivered more than its `maxBytes`, so the SDK stopped it.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexTransferTooLarge extends Schema.TaggedError<RexTransferTooLarge>()(
  "RexTransferTooLarge",
  {
    blockId: Schema.String,
    maxBytes: Schema.Number,
    message: Schema.String,
  },
) {
  /** Creates the failure for a stream that passed its byte limit. */
  constructor(blockId: string, maxBytes: number) {
    super({
      blockId,
      maxBytes,
      message: `A file transfer with block ${blockId} passed its limit of ${maxBytes} bytes, so it was stopped. The file may still be growing; raise maxBytes if you expect it to be larger.`,
    });
  }
}

/**
 * A byte stream failure: any data stream failure, or a transfer that was incomplete, stalled,
 * or too large.
 *
 * @category errors
 * @since 0.1.0
 */
export type RexBytesStreamError =
  | RexDataError
  | RexTransferIncomplete
  | RexTransferStalled
  | RexTransferTooLarge;

/**
 * A tunnel forward could not listen or connect on this machine.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexForwardSocketError extends Schema.TaggedError<RexForwardSocketError>()(
  "RexForwardSocketError",
  {
    operation: Schema.Literals(["listen", "connect"]),
    address: Schema.String,
    message: Schema.String,
    cause: Schema.Defect(),
  },
) {
  /** Creates the failure for a local listen or connect that failed. */
  constructor(operation: RexForwardSocketError["operation"], address: string, cause: unknown) {
    super({
      operation,
      address,
      message:
        operation === "listen"
          ? `Could not listen on ${address} on this machine. Choose another address or port, or free this one.`
          : `Could not connect to ${address} from this machine. Check that something is listening there.`,
      cause,
    });
  }
}
