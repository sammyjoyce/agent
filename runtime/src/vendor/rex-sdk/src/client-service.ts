/**
 * Connected clients such as Rex.app: listing, labels, keymaps, scripts, actions, and requests between clients.
 *
 * @since 0.1.0
 */
import { Cause, Context, Effect, Layer, Schema } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type {
  RexClientCallRequestedEvent,
  RexClientPerformRequestedEvent,
} from "./generated/rex-wire-schemas.ts";
import type { RexConfigurationError, RexEventsLost, RexOperationError } from "./rex-errors.ts";
import { takeRexEvent } from "./rex-events.ts";
import { rexMethodOperation, type RexMethodOperation } from "./rex-operation.ts";

/**
 * A handler's answer that it did not perform a requested action or call.
 *
 * The code goes back to the requester, so use a documented one such as `refused`,
 * `not_found`, or `internal`.
 *
 * @category errors
 * @since 0.1.0
 */
export class RexClientRequestFailure extends Schema.TaggedError<RexClientRequestFailure>()(
  "RexClientRequestFailure",
  { code: Schema.String, message: Schema.String },
) {}

/**
 * Handles one `client_perform_requested` event: perform the action and return its result.
 *
 * @category models
 * @since 0.1.0
 */
export type RexPerformRequestHandler = (
  request: RexClientPerformRequestedEvent,
) => Effect.Effect<Schema.Json, RexClientRequestFailure>;

/**
 * Handles one `client_call_requested` event: make the call and return its result.
 *
 * @category models
 * @since 0.1.0
 */
export type RexCallRequestHandler = (
  request: RexClientCallRequestedEvent,
) => Effect.Effect<Schema.Json, RexClientRequestFailure>;

/**
 * Client operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IClientService {
  /** `client.list`: the clients connected to the server, in the order they connected. */
  readonly list: RexMethodOperation<"client.list">;
  /** `client.inspect`: one client's details, including the actions it offers. */
  readonly inspect: RexMethodOperation<"client.inspect">;
  /** `client.set_label`: sets or removes this client's label. */
  readonly setLabel: RexMethodOperation<"client.set_label">;
  /** `client.set_script`: loads Lua scripts for this client, replacing any loaded before. */
  readonly setScript: RexMethodOperation<"client.set_script">;
  /** `client.keymap`: what each key does for this client. */
  readonly keymap: RexMethodOperation<"client.keymap">;
  /** `client.action`: performs a configuration-file or block action as this client. */
  readonly action: RexMethodOperation<"client.action">;
  /** `client.key`: sends a key to a block, giving Lua key bindings the first chance at it. */
  readonly key: RexMethodOperation<"client.key">;
  /** `client.perform`: asks another client, such as Rex.app, to perform one of its actions and waits for its answer. */
  readonly perform: RexMethodOperation<"client.perform">;
  /** `client.reply`: answers a client_call_requested or client_perform_requested event. */
  readonly reply: RexMethodOperation<"client.reply">;
  /**
   * Answers every `client_perform_requested` event sent to this client until interrupted.
   *
   * Each request runs on its own fiber and is always answered with `client.reply`: the
   * handler's result, its `RexClientRequestFailure`, or `internal` if it fails otherwise.
   */
  readonly servePerformRequests: (
    handler: RexPerformRequestHandler,
  ) => Effect.Effect<never, RexOperationError | RexEventsLost>;
  /**
   * Answers every `client_call_requested` event sent to this client until interrupted, the
   * way {@link IClientService.servePerformRequests} answers perform requests.
   */
  readonly serveCallRequests: (
    handler: RexCallRequestHandler,
  ) => Effect.Effect<never, RexOperationError | RexEventsLost>;
}

/**
 * Yieldable client service.
 *
 * @category services
 * @since 0.1.0
 */
export class ClientService extends Context.Service<ClientService, IClientService>()(
  "rex-sdk/ClientService",
) {}

/**
 * Constructs client operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeClientService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const reply = rexMethodOperation(control, attachments, "client.reply");

  const answer = (callId: string, outcome: Effect.Effect<Schema.Json, RexClientRequestFailure>) =>
    outcome.pipe(
      Effect.matchCauseEffect({
        onSuccess: (result) => reply({ callId, result }),
        onFailure: (cause) => {
          const failure = Cause.findErrorOption(cause);
          return reply({
            callId,
            error:
              failure._tag === "Some"
                ? { code: failure.value.code, message: failure.value.message }
                : { code: "internal", message: "The handler failed without an answer." },
          });
        },
      }),
      Effect.ignore,
    );

  const serve = <Request>(
    name: string,
    select: (event: Effect.Success<ReturnType<typeof takeRexEvent>>) => Request | undefined,
    callIdOf: (request: Request) => string,
    handle: (request: Request) => Effect.Effect<Schema.Json, RexClientRequestFailure>,
  ) =>
    Effect.scoped(
      Effect.gen(function* () {
        const events = yield* control.subscribe;
        yield* control.connection;
        while (true) {
          const event = yield* takeRexEvent(events);
          const request = select(event);
          if (request !== undefined) {
            yield* Effect.forkScoped(
              answer(
                callIdOf(request),
                Effect.suspend(() => handle(request)),
              ),
            );
          }
        }
      }),
    ).pipe(Effect.withSpan(name));

  return ClientService.of({
    servePerformRequests: (handler) =>
      serve(
        "ClientService.servePerformRequests",
        (event) =>
          event._tag === "ServerEvent" && event.type === "client_perform_requested"
            ? event.payload
            : undefined,
        (request) => request.callId,
        handler,
      ),
    serveCallRequests: (handler) =>
      serve(
        "ClientService.serveCallRequests",
        (event) =>
          event._tag === "ServerEvent" && event.type === "client_call_requested"
            ? event.payload
            : undefined,
        (request) => request.callId,
        handler,
      ),
    list: rexMethodOperation(control, attachments, "client.list"),
    inspect: rexMethodOperation(control, attachments, "client.inspect"),
    setLabel: rexMethodOperation(control, attachments, "client.set_label"),
    setScript: rexMethodOperation(control, attachments, "client.set_script"),
    keymap: rexMethodOperation(control, attachments, "client.keymap"),
    action: rexMethodOperation(control, attachments, "client.action"),
    key: rexMethodOperation(control, attachments, "client.key"),
    perform: rexMethodOperation(control, attachments, "client.perform"),
    reply: rexMethodOperation(control, attachments, "client.reply"),
  });
});

/**
 * Client operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const clientServiceLayerWithoutDependencies: Layer.Layer<
  ClientService,
  never,
  RexControl | RexAttachments
> = Layer.effect(ClientService, makeClientService);

/**
 * Client operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const clientServiceLayer: Layer.Layer<ClientService, RexConfigurationError> =
  clientServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
