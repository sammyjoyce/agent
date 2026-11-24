/**
 * Turns a documented Rex method into a typed, traced SDK operation.
 *
 * Each operation encodes its camelCase arguments with the generated codec (rejecting invalid
 * arguments before anything is sent), attaches to the named session when the method needs it,
 * sends the request, and decodes the result. Wire snake_case never leaves this module and the
 * generated codecs.
 *
 * @since 0.1.0
 */
import { Cause, Effect, Exit, Schema } from "effect";
import type { IRexAttachments } from "./rex-attachments.ts";
import type { IRexControl, RexRequestOptions } from "./rex-control.ts";
import { SessionId, type BlockId } from "./rex-domain.ts";
import { RexInvalidInput, RexInvalidResponse, type RexOperationError } from "./rex-errors.ts";
import {
  rexBlockMethods,
  rexWireMethods,
  type RexBlockMethod,
  type RexWireMethod,
} from "./generated/rex-wire-schemas.ts";

/**
 * Arguments of a server method, in the SDK's camelCase form.
 *
 * @category models
 * @since 0.1.0
 */
export type RexMethodInput<Method extends RexWireMethod> =
  (typeof rexWireMethods)[Method]["input"]["Type"];

/**
 * Result of a server method, decoded into the SDK's camelCase form.
 *
 * @category models
 * @since 0.1.0
 */
export type RexMethodResult<Method extends RexWireMethod> =
  (typeof rexWireMethods)[Method]["result"]["Type"];

/**
 * Arguments of a block method, in the SDK's camelCase form.
 *
 * @category models
 * @since 0.1.0
 */
export type RexBlockMethodArgs<Method extends RexBlockMethod> =
  (typeof rexBlockMethods)[Method]["args"]["Type"];

/**
 * Result of a block method, decoded into the SDK's camelCase form.
 *
 * @category models
 * @since 0.1.0
 */
export type RexBlockMethodResult<Method extends RexBlockMethod> =
  (typeof rexBlockMethods)[Method]["result"]["Type"];

/**
 * A typed operation for one server method.
 *
 * @category models
 * @since 0.1.0
 */
export type RexMethodOperation<Method extends RexWireMethod> = (
  input: RexMethodInput<Method>,
  options?: RexRequestOptions,
) => Effect.Effect<RexMethodResult<Method>, RexOperationError>;

/**
 * A typed operation for a server method that takes no arguments.
 *
 * @category models
 * @since 0.1.0
 */
export type RexNoInputOperation<Method extends RexWireMethod> = (
  options?: RexRequestOptions,
) => Effect.Effect<RexMethodResult<Method>, RexOperationError>;

/**
 * Names a block for a block method call.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexBlockTarget {
  /** The session that holds the block. */
  readonly sessionId: SessionId;
  /** The block to call the method on. */
  readonly blockId: BlockId;
}

/**
 * A typed operation for one block method; its own arguments go in `args`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexBlockMethodOperation<Method extends RexBlockMethod> = (
  target: RexBlockTarget,
  args: RexBlockMethodArgs<Method>,
  options?: RexRequestOptions,
) => Effect.Effect<RexBlockMethodResult<Method>, RexOperationError>;

/**
 * A typed operation for a block method that takes no arguments of its own.
 *
 * @category models
 * @since 0.1.0
 */
export type RexBlockNoArgsOperation<Method extends RexBlockMethod> = (
  target: RexBlockTarget,
  options?: RexRequestOptions,
) => Effect.Effect<RexBlockMethodResult<Method>, RexOperationError>;

/**
 * Methods that work on a connection that is not attached to the session they name.
 *
 * `session.attach` and `session.bootstrap` make the attachment themselves; `client.list` and
 * `client.perform` only filter or target by session.
 */
const methodsWithoutAttachment: ReadonlySet<string> = new Set([
  "session.attach",
  "session.attach_all",
  "session.bootstrap",
  "session.detach",
  "session.list",
  "session.create",
  "client.list",
  "client.perform",
]);

const decodeWireSessionId = Schema.decodeUnknownOption(Schema.Struct({ session_id: SessionId }));

/** Encodes a value with a codec, translating failure into `RexInvalidInput`. */
export function encodeRexInput<Type, Encoded>(
  operation: string,
  codec: Schema.Codec<Type, Encoded>,
  value: Type,
): Effect.Effect<Encoded, RexInvalidInput> {
  return Schema.encodeEffect(codec)(value).pipe(
    Effect.mapError((cause) => new RexInvalidInput(operation, cause)),
  );
}

/** Decodes a wire result with a codec, translating failure into `RexInvalidResponse`. */
export function decodeRexResult<Type, Encoded>(
  method: string,
  codec: Schema.Codec<Type, Encoded>,
  value: Schema.Json,
): Effect.Effect<Type, RexInvalidResponse> {
  return Schema.decodeUnknownEffect(codec)(value).pipe(
    Effect.mapError((cause) => new RexInvalidResponse(method, undefined, cause)),
  );
}

/**
 * Sends one already-encoded request, attaching to its session first when the method needs it.
 *
 * @category constructors
 * @since 0.1.0
 */
export function sendRexRequest(
  control: IRexControl,
  attachments: IRexAttachments,
  method: string,
  payload: Schema.Json | undefined,
  options?: RexRequestOptions,
) {
  return Effect.gen(function* () {
    if (!methodsWithoutAttachment.has(method)) {
      const target = decodeWireSessionId(payload);
      if (target._tag === "Some") yield* attachments.ensureAttached(target.value.session_id);
    }
    return yield* control.request(method, payload, options);
  });
}

/** Adds the SDK's outcome attribute to the current operation span. */
function annotateRexOutcome<A, E>(exit: Exit.Exit<A, E>) {
  return Effect.annotateCurrentSpan(
    "rex.outcome",
    Exit.isSuccess(exit)
      ? "success"
      : Cause.hasInterruptsOnly(exit.cause)
        ? "interrupted"
        : "failure",
  );
}

/**
 * Builds the typed operation for a server method.
 *
 * @category constructors
 * @since 0.1.0
 */
export function rexMethodOperation<Method extends RexWireMethod>(
  control: IRexControl,
  attachments: IRexAttachments,
  method: Method,
): RexMethodOperation<Method> {
  const codecs: {
    readonly input: Schema.Codec<RexMethodInput<Method>, Schema.Json>;
    readonly result: Schema.Codec<RexMethodResult<Method>, unknown>;
  } = rexWireMethods[method];
  return Effect.fn(`Rex.${method}`)(function* (
    input: RexMethodInput<Method>,
    options?: RexRequestOptions,
  ) {
    yield* Effect.annotateCurrentSpan("rex.method", method);
    const payload = yield* encodeRexInput(method, codecs.input, input);
    const response = yield* sendRexRequest(control, attachments, method, payload, options);
    return yield* decodeRexResult(method, codecs.result, response.payload);
  }, Effect.onExit(annotateRexOutcome));
}

/**
 * Builds the typed operation for a server method that takes no arguments.
 *
 * @category constructors
 * @since 0.1.0
 */
export function rexNoInputOperation<Method extends RexWireMethod>(
  control: IRexControl,
  attachments: IRexAttachments,
  method: Method & (RexMethodInput<Method> extends Record<string, never> ? Method : never),
): RexNoInputOperation<Method> {
  const operation = rexMethodOperation(control, attachments, method);
  const emptyInput: RexMethodInput<Method> = Object.freeze({});
  return (options) => operation(emptyInput, options);
}

/**
 * Builds the typed operation for a block method.
 *
 * @category constructors
 * @since 0.1.0
 */
export function rexBlockMethodOperation<Method extends RexBlockMethod>(
  control: IRexControl,
  attachments: IRexAttachments,
  method: Method,
): RexBlockMethodOperation<Method> {
  const codecs: {
    readonly args: Schema.Codec<RexBlockMethodArgs<Method>, Schema.Json>;
    readonly result: Schema.Codec<RexBlockMethodResult<Method>, unknown>;
  } = rexBlockMethods[method];
  return Effect.fn(`Rex.${method}`)(function* (
    target: RexBlockTarget,
    args: RexBlockMethodArgs<Method>,
    options?: RexRequestOptions,
  ) {
    yield* Effect.annotateCurrentSpan("rex.method", method);
    const encodedArgs = yield* encodeRexInput(method, codecs.args, args);
    const response = yield* sendRexRequest(
      control,
      attachments,
      method,
      { session_id: target.sessionId, block_id: target.blockId, args: encodedArgs },
      options,
    );
    return yield* decodeRexResult(method, codecs.result, response.payload);
  }, Effect.onExit(annotateRexOutcome));
}

/**
 * Builds the typed operation for a block method that takes no arguments of its own.
 *
 * @category constructors
 * @since 0.1.0
 */
export function rexBlockNoArgsOperation<Method extends RexBlockMethod>(
  control: IRexControl,
  attachments: IRexAttachments,
  method: Method & (RexBlockMethodArgs<Method> extends Record<string, never> ? Method : never),
): RexBlockNoArgsOperation<Method> {
  const operation = rexBlockMethodOperation(control, attachments, method);
  const emptyArgs: RexBlockMethodArgs<Method> = Object.freeze({});
  return (target, options) => operation(target, emptyArgs, options);
}

/** The error channel shared by typed operations. */
export type { RexOperationError };
