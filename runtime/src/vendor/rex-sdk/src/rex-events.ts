/**
 * Decoded Rex events.
 *
 * The server sends server events directly, session events inside a `session_event` that names
 * the session, and block events inside a `block_event` inside a `session_event`. The SDK removes
 * both wrappers and tags each event by where it came from. Event types this SDK does not know
 * become `UnknownEvent` instead of failing, because newer servers add events.
 *
 * @since 0.1.0
 */
import { Cause, Effect, Option, Queue, Schema } from "effect";
import {
  RexServerEventFrame,
  RexTerminalEventFrame,
  rexServerEvents,
  rexSessionEvents,
  RexSessionEventFrame,
} from "./generated/rex-wire-schemas.ts";
import type { RexControlEvent } from "./rex-control.ts";
import { BlockId, SessionId } from "./rex-domain.ts";
import { RexEventsLost, RexInvalidResponse } from "./rex-errors.ts";

/**
 * The creator of terminal blocks.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_TERMINAL_CREATOR = "com.superlogical.terminal";

/**
 * An event about the server as a whole, such as `session_created`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexServerEvent = RexServerEventFrame & {
  readonly _tag: "ServerEvent";
  /** The event's place among the events on its connection. */
  readonly seq: number;
};

/**
 * An event about one session's windows, blocks, or clients, such as `block_closed`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexSessionEvent = RexSessionEventFrame & {
  readonly _tag: "SessionEvent";
  /** The event's place among the events on its connection. */
  readonly seq: number;
  /** The session the event happened in. */
  readonly sessionId: SessionId;
};

/**
 * An event a terminal block sent, such as `child_exited` or `pwd_changed`.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalEvent = RexTerminalEventFrame & {
  readonly _tag: "TerminalEvent";
  /** The event's place among the events on its connection. */
  readonly seq: number;
  /** The session the terminal belongs to. */
  readonly sessionId: SessionId;
  /** The terminal block that sent the event. */
  readonly blockId: BlockId;
};

/**
 * An event from a block made by a creator other than the terminal, with its fields undecoded.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexBlockEvent {
  readonly _tag: "BlockEvent";
  /** The event's place among the events on its connection. */
  readonly seq: number;
  /** The session the block belongs to. */
  readonly sessionId: SessionId;
  /** The block that sent the event. */
  readonly blockId: BlockId;
  /** The creator that made the block, when the server named it. */
  readonly creatorName: Option.Option<string>;
  /** The event's name, as its creator lists it. */
  readonly name: string;
  /** The event's fields, in the shape `block_creator.list` describes. */
  readonly payload: Schema.Json;
}

/**
 * An event whose type this SDK does not know, kept so callers can still see it.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexUnknownEvent {
  readonly _tag: "UnknownEvent";
  /** The event's place among the events on its connection. */
  readonly seq: number;
  /** The session it happened in, for an unknown session event. */
  readonly sessionId: Option.Option<SessionId>;
  /** The event's type. */
  readonly type: string;
  /** The event's fields. */
  readonly payload: Schema.Json;
}

/**
 * Any decoded event.
 *
 * @category models
 * @since 0.1.0
 */
export type RexEvent =
  | RexServerEvent
  | RexSessionEvent
  | RexTerminalEvent
  | RexBlockEvent
  | RexUnknownEvent;

const SessionEventEnvelope = Schema.Struct({
  session_id: SessionId,
  event: Schema.Struct({ type: Schema.String, payload: Schema.optionalKey(Schema.Json) }),
});

const BlockEventEnvelope = Schema.Struct({
  block_id: BlockId,
  creator_name: Schema.optionalKey(Schema.String),
  name: Schema.String,
  payload: Schema.optionalKey(Schema.Json),
});

const decodeSessionEventEnvelope = Schema.decodeUnknownEffect(SessionEventEnvelope);
const decodeBlockEventEnvelope = Schema.decodeUnknownEffect(BlockEventEnvelope);
const decodeServerEventFrame = Schema.decodeUnknownEffect(RexServerEventFrame);
const decodeSessionEventFrame = Schema.decodeUnknownEffect(RexSessionEventFrame);
const decodeTerminalEventFrame = Schema.decodeUnknownEffect(RexTerminalEventFrame);

const terminalEventNames: ReadonlySet<string> = new Set(
  RexTerminalEventFrame.members.map((member) => member.fields.name.literal),
);

/**
 * Decodes one control event frame.
 *
 * @returns The tagged event, or `RexInvalidResponse` when a known event has the wrong shape.
 * @category constructors
 * @since 0.1.0
 */
export function decodeRexEvent(
  frame: RexControlEvent,
): Effect.Effect<RexEvent, RexInvalidResponse> {
  return Effect.gen(function* () {
    const fail = (cause: unknown) =>
      new RexInvalidResponse(`${frame.type} event`, undefined, cause);
    if (frame.type !== "session_event") {
      if (!Object.hasOwn(rexServerEvents, frame.type)) {
        return {
          _tag: "UnknownEvent",
          seq: frame.seq,
          sessionId: Option.none(),
          type: frame.type,
          payload: frame.payload,
        } satisfies RexUnknownEvent;
      }
      const decoded = yield* decodeServerEventFrame({
        type: frame.type,
        payload: frame.payload ?? {},
      }).pipe(Effect.mapError(fail));
      return { ...decoded, _tag: "ServerEvent", seq: frame.seq } satisfies RexServerEvent;
    }

    const envelope = yield* decodeSessionEventEnvelope(frame.payload).pipe(Effect.mapError(fail));
    const sessionId = envelope.session_id;
    const inner = envelope.event;
    if (inner.type === "block_event") {
      const block = yield* decodeBlockEventEnvelope(inner.payload).pipe(Effect.mapError(fail));
      if (block.creator_name === REX_TERMINAL_CREATOR && terminalEventNames.has(block.name)) {
        const decoded = yield* decodeTerminalEventFrame({
          name: block.name,
          payload: block.payload ?? {},
        }).pipe(Effect.mapError(fail));
        return {
          ...decoded,
          _tag: "TerminalEvent",
          seq: frame.seq,
          sessionId,
          blockId: block.block_id,
        } satisfies RexTerminalEvent;
      }
      return {
        _tag: "BlockEvent",
        seq: frame.seq,
        sessionId,
        blockId: block.block_id,
        creatorName: Option.fromUndefinedOr(block.creator_name),
        name: block.name,
        payload: block.payload ?? null,
      } satisfies RexBlockEvent;
    }
    if (!Object.hasOwn(rexSessionEvents, inner.type)) {
      return {
        _tag: "UnknownEvent",
        seq: frame.seq,
        sessionId: Option.some(sessionId),
        type: inner.type,
        payload: inner.payload ?? null,
      } satisfies RexUnknownEvent;
    }
    const decoded = yield* decodeSessionEventFrame({
      type: inner.type,
      payload: inner.payload ?? {},
    }).pipe(Effect.mapError(fail));
    return {
      ...decoded,
      _tag: "SessionEvent",
      seq: frame.seq,
      sessionId,
    } satisfies RexSessionEvent;
  });
}

/**
 * The session an event belongs to, if any: the session it happened in, or for
 * `session_destroyed`, `client_script_events_dropped`, and a session's `event_dropped`, the
 * session it names. Attaching to that session delivers the event.
 *
 * @category accessors
 * @since 0.1.0
 */
export function rexEventSessionId(event: RexEvent): Option.Option<SessionId> {
  switch (event._tag) {
    case "SessionEvent":
    case "TerminalEvent":
    case "BlockEvent":
      return Option.some(event.sessionId);
    case "UnknownEvent":
      return event.sessionId;
    case "ServerEvent":
      switch (event.type) {
        case "session_destroyed":
        case "client_script_events_dropped":
          return Option.some(event.payload.sessionId);
        case "event_dropped":
          return event.payload.sessionId;
        default:
          return Option.none();
      }
  }
}

/**
 * Takes and decodes the next event from a control subscription.
 *
 * A subscription that ends, because its scope or connection closed, fails with `RexEventsLost`.
 *
 * @category constructors
 * @since 0.1.0
 */
export function takeRexEvent(
  subscription: Queue.Dequeue<RexControlEvent, RexEventsLost | Cause.Done>,
): Effect.Effect<RexEvent, RexEventsLost | RexInvalidResponse> {
  return Queue.take(subscription).pipe(
    Effect.catchIf(Cause.isDone, () => Effect.fail(new RexEventsLost("connection_ended"))),
    Effect.flatMap(decodeRexEvent),
  );
}
