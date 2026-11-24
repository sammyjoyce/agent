/**
 * Rex terminals for task workers and their agents, through the pinned rex-sdk in
 * src/vendor/rex-sdk. Only the upstream operations in REX_OPERATIONS are exposed.
 * Each call is checked against the calling actor's recorded Rex binding: it reads
 * its own terminal and the child terminals it opened, and writes only to those
 * children. The SDK's server must be the Rex instance that started the actor's
 * terminal, before and after the call. A write without a receipt is never replayed
 * and blocks the actor's further writes until it clears that exact write.
 */
import { randomUUID } from "node:crypto";
import { setTimeout as delay } from "node:timers/promises";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord/json";
import { defineDocFamily, defineExtension, defineTool, type Extension, type Harness, type ToolExecutionResult, type ToolNamespace,
  type ToolRegistration, type Tx } from "@earendil-works/pi-durable";
import { Cause, Effect, Exit, ManagedRuntime, Option, type Layer } from "effect";
import { Type } from "typebox";
import { RexSdk, rexSdkLayerFromOptions } from "./vendor/rex-sdk/src/index.js";
import { RexMarkStore } from "./vendor/rex-sdk/pi/rex-tool-marks.js";
import { rexToolOperations, type RexToolOperation } from "./vendor/rex-sdk/pi/rex-tool-operations.js";
import { makeRexToolProgram, toRexToolResult } from "./vendor/rex-sdk/pi/rex-tool-runtime.js";
import { rexToolOutputJsonSchema, rexToolParametersJsonSchema } from "./vendor/rex-sdk/pi/rex-tool-schemas.js";
import type { OwnerGate } from "./failover/owner-gate.js";
import type { WorkerRef } from "./generated/WorkerRef.js";
import { TaskError, type TaskStore } from "./tasks.js";
import type { Executions } from "./tools.js";

type Access = "server" | "session" | "read" | "split" | "write" | "close";
/** The upstream operations offered, by what they may touch. Everything else in rex-sdk stays out. */
export const REX_OPERATIONS: Readonly<Record<string, Access>> = {
  server_version: "server", sessions_view: "session",
  terminals_readTail: "read", terminals_mark: "read", terminals_waitForOutput: "read", terminals_waitForQuiet: "read", terminals_waitForExit: "read",
  blocks_splitBeside: "split", terminals_writeLine: "write", terminals_write: "write", blocks_close: "close",
};
const MUTATES: readonly Access[] = ["split", "write", "close"];
const SCOPE: Record<Access, string> = {
  server: "",
  session: " Only your own session.",
  read: " Only your own terminal or a child terminal you opened.",
  split: " Only beside your own terminal (the default anchor) or a child you opened; terminals only, no windowId.",
  write: " Only child terminals you opened with rex_blocks_splitBeside.",
  close: " Only child terminals you opened, by blockId.",
};
/** Upstream descriptions that point at its Pi extension's own discovery tool. */
const DESCRIPTIONS: Readonly<Record<string, string>> = {
  sessions_view: "One session's windows, layouts, and blocks with their IDs. Pass the sessionId from rex_here({}).",
};
export const MAX_REX_CHILDREN = 8;
const MAX_LAYOUT_TERMINALS = 4, MAX_WAIT_MS = 300_000, MAX_REQUEST_MS = 60_000, MAX_TAIL_BYTES = 262_144, MAX_MARK_OWNERS = 64;
/** How long a call waits for an actor's terminal that is still opening. */
const BINDING_WAIT_MS = 15_000;
/** Failures reported before any request was sent, or by a server that refused it. Others leave a write uncertain. */
const DEFINITE = new Set(["RexNotOwned", "RexInvalidInput", "SchemaError", "RexConfigurationError", "RexConnectionError", "RexHandshakeError",
  "RexUnsupportedApiRevision", "RexMessageTooLarge", "RexBadRequest", "RexNotFound", "RexSessionNotFound", "RexMethodNotFound", "RexConflict",
  "RexNotSupported", "RexRefused", "RexTooLarge", "RexRevisionTooLow", "RexInvalidPattern", "RexUnknownMark", "RexBlockClosed"]);

type Uncertain = { id: string; tool: string; block_id: string | null; at: number; terminals: number };
/** `unconfirmed`: terminals that uncertain splits may have opened. They are never adopted, but count against the limit. */
type Owned = { instance_id: string | null; children: string[]; unconfirmed: number; uncertain: Uncertain | null };
const RexOwned = defineDocFamily<Owned, null>({ kind: "agent.rex.owned", scope: "session", family: true, version: 1,
  initial: () => ({ instance_id: null, children: [], unconfirmed: 0, uncertain: null }), checkpointWhen: () => true });

/** The actor's recorded terminal, confirmed by the Rex instance that started it. */
export type RexActor = { key: string; binding: WorkerRef & { rex_instance_id: string } };
export type RexActorResolver = (conversationId: string, signal: AbortSignal | undefined) => Promise<RexActor>;

class RexNotOwned extends Error {
  readonly _tag = "RexNotOwned";
  constructor(message: string) { super(message); this.name = "RexNotOwned"; }
}
/** The SDK reached another Rex instance after the call started; its effect is uncertain. */
class RexServerChanged extends Error {
  readonly _tag = "RexServerChanged";
  constructor() { super("the Rex server changed during the call"); this.name = "RexServerChanged"; }
}
function refusal(message: string): TaskError { return new TaskError("RexNotOwned: " + message); }

/** The server the SDK reaches: unset leaves Rex tools off, "personal" uses the SDK's own default selection. */
export function rexServerFromEnv(env: NodeJS.ProcessEnv = process.env): { server?: string } | undefined {
  const value = env.AGENT_REX_SDK_SERVER;
  if (value === undefined || value === "") return undefined;
  return value === "personal" ? {} : { server: value };
}

/** Task workers and their agents only, bound to a terminal whose Rex instance is recorded. */
export function taskRexActors(tasks: TaskStore, executions: Executions): RexActorResolver {
  return async (conversationId, signal) => {
    if (executions.get(conversationId).role !== "worker") throw refusal("only task workers and their agents reach Rex");
    // An actor's first turn can start while its terminal is still opening.
    const deadline = Date.now() + BINDING_WAIT_MS;
    for (;;) {
      const { task, agent } = await tasks.owner(conversationId);
      if (tasks.isConfined(task) || tasks.isBackgroundTask(task)) throw refusal("scheduled and confined tasks have no Rex terminal");
      const worker = (agent ?? task).worker;
      if (worker.state === "bound") {
        const instance = worker.binding.rex_instance_id;
        if (instance === undefined) throw refusal("this actor's terminal predates Rex instance records");
        return { key: conversationId, binding: { ...worker.binding, rex_instance_id: instance } };
      }
      if ((worker.state !== "allocating" && worker.state !== "resuming") || Date.now() >= deadline) {
        throw refusal(`this actor's Rex terminal is not confirmed (${worker.state}); retry once it is open`);
      }
      await delay(100, undefined, signal === undefined ? undefined : { signal });
    }
  };
}

function terminalCount(layout: unknown, seen = 0): number {
  if (typeof layout !== "object" || layout === null) throw refusal("layout must be a Terminal or Split node");
  const node = layout as { _tag?: unknown; before?: unknown; after?: unknown };
  let count: number;
  if (node._tag === "Terminal") count = seen + 1;
  else if (node._tag === "Split") count = terminalCount(node.after, terminalCount(node.before, seen));
  else throw refusal("layout may hold only Terminal and Split nodes");
  if (count > MAX_LAYOUT_TERMINALS) throw refusal(`a layout may open at most ${MAX_LAYOUT_TERMINALS} terminals`);
  return count;
}

function bounded(params: Record<string, unknown>, key: string, max: number): void {
  const value = params[key];
  if (typeof value === "number" && value > max) throw refusal(`${key} must be at most ${max}`);
}

/** Whether a failed call certainly had no effect. A broken connection while reading or writing may have run it. */
function definite(exit: Exit.Exit<unknown, unknown>): boolean {
  if (Exit.isSuccess(exit)) return true;
  const error = Cause.findErrorOption(exit.cause);
  if (Option.isNone(error)) return false;
  const { _tag: tag, reason } = error.value as { _tag?: unknown; reason?: unknown };
  return typeof tag === "string" && DEFINITE.has(tag) && (tag !== "RexConnectionError" || reason === "connect");
}

const instructions = `Rex terminals of this task, through rex-sdk. Start with rex_here({}): your sessionId, your own terminal's blockId, and the child terminals you opened.
Read your own terminal or a child. Write only to children: open one with rex_blocks_splitBeside({ sessionId, placement: "right" }) (its blockIds), optionally with layout { _tag: "Terminal", options: { command, cwd } }.
Run: const { markId } = await tools.rex_terminals_writeLine({ sessionId, blockId, text }), then rex_terminals_waitForOutput({ sessionId, blockId, since: markId, match: { type: "regex", value }, timeoutMs }). Waits resolve to { timedOut: true } or { timedOut: false, match | quiet | exit }.
Deadlines: timeoutMs at most 300000; requestTimeoutMs bounds each request (default 10000, at most 60000).
Failures reject with the SDK error tag first; RexNotOwned means the target is outside this actor's terminals.
One write at a time. A write without a receipt (RexConnectionLost, RexRequestTimeout, interrupted) is not replayed, and further writes are refused until you inspect its effect and call rex_here({ clearUncertain: <its id> }). Terminals an uncertain split may have opened are never yours to write, but count against your ${MAX_REX_CHILDREN} children.
Close children you no longer need with rex_blocks_close({ sessionId, blockId }).`;
export const REX_NAMESPACE: ToolNamespace = { name: "rex", description: "Rex terminals of this task: read your terminal, open child terminals, run commands in them and wait for output.", instructions };

const HereOutput = Type.Object({
  sessionId: Type.String(), windowId: Type.String(), blockId: Type.String(), children: Type.Array(Type.String()), unconfirmedTerminals: Type.Number(),
  uncertain: Type.Union([Type.Object({ id: Type.String(), tool: Type.String(), blockId: Type.Union([Type.String(), Type.Null()]), at: Type.Number() }), Type.Null()]),
});

/** One SDK runtime, and so one control connection, opened on first use. */
class RexConnection {
  #runtime: ManagedRuntime.ManagedRuntime<RexSdk, unknown> | undefined;
  constructor(private readonly makeLayer: () => Layer.Layer<RexSdk, unknown>) {}
  run<A>(effect: Effect.Effect<A, unknown, RexSdk>, signal: AbortSignal | undefined): Promise<Exit.Exit<A, unknown>> {
    this.#runtime ??= ManagedRuntime.make(this.makeLayer());
    return this.#runtime.runPromiseExit(effect, signal === undefined ? undefined : { signal });
  }
  async dispose(): Promise<void> {
    const runtime = this.#runtime;
    this.#runtime = undefined;
    await runtime?.dispose();
  }
}

export type RexTools = Extension & { close(): Promise<void> };

export function createRexTools({ harness, actors, gate, server = {}, makeLayer }: {
  harness: Harness; actors: RexActorResolver; gate: OwnerGate | undefined; server?: { server?: string };
  makeLayer?: () => Layer.Layer<RexSdk, unknown>;
}): RexTools {
  const connection = new RexConnection(makeLayer ?? (() => rexSdkLayerFromOptions({ ...server, client: { kind: "agent", name: "beep-boop" } })));
  /** Marks stay with the actor that made them, for the newest actors only. Their IDs name this process, so none outlives it. */
  const marks = new Map<string, RexMarkStore>();
  const epoch = randomUUID().slice(0, 8);
  /** Writes of this process that have not finished; their markers cannot be cleared. */
  const running = new Set<string>();
  function marksOf(key: string): RexMarkStore {
    const store = marks.get(key) ?? new RexMarkStore();
    marks.delete(key); marks.set(key, store);
    for (const oldest of marks.keys()) { if (marks.size <= MAX_MARK_OWNERS) break; marks.delete(oldest); }
    return store;
  }

  async function actor(conversationId: string, signal: AbortSignal | undefined): Promise<RexActor & Omit<Owned, "instance_id">> {
    const resolved = await actors(conversationId, signal);
    const saved = await harness.snapshot(RexOwned, resolved.key, BACKGROUND_CONTEXT);
    const current = saved?.instance_id === resolved.binding.rex_instance_id;
    return { ...resolved, children: current ? [...saved.children] : [], unconfirmed: current ? saved.unconfirmed ?? 0 : 0,
      uncertain: current ? saved.uncertain : null };
  }
  /** The actor's record, reset when its terminal now belongs to another Rex instance. */
  async function owned(tx: Tx, caller: RexActor): Promise<Owned> {
    const doc = await tx.doc(RexOwned, caller.key, null);
    if (doc.instance_id !== caller.binding.rex_instance_id) {
      doc.instance_id = caller.binding.rex_instance_id; doc.children = []; doc.unconfirmed = 0; doc.uncertain = null;
    }
    doc.unconfirmed ??= 0;
    return doc;
  }
  /** Ends one write: only its own marker is removed. */
  async function settle(caller: RexActor, id: string, change: (doc: Owned) => void = () => {}): Promise<void> {
    await harness.commit(async (tx) => {
      const doc = await owned(tx, caller);
      if (doc.uncertain?.id === id) doc.uncertain = null;
      change(doc);
    }, BACKGROUND_CONTEXT);
  }

  function authorize(access: Access, caller: RexActor, record: { children: readonly string[]; unconfirmed: number },
    args: Record<string, unknown>): Record<string, unknown> {
    const params = { ...args };
    bounded(params, "requestTimeoutMs", MAX_REQUEST_MS); bounded(params, "timeoutMs", MAX_WAIT_MS); bounded(params, "maxBytes", MAX_TAIL_BYTES);
    if (typeof params.since === "string") {
      if (!params.since.startsWith(epoch + ":")) {
        throw new TaskError(`RexUnknownMark: mark ${params.since} is unknown or from an earlier coordinator run; make a new one with rex_terminals_mark or rex_terminals_writeLine`);
      }
      params.since = params.since.slice(epoch.length + 1);
    }
    if (access === "server") return params;
    const { session_id: session, block_id: own } = caller.binding;
    if (params.sessionId !== session) throw refusal(`sessionId must be this actor's session ${session}`);
    if (access === "session") return params;
    const { children } = record;
    if (access === "split") {
      if (params.windowId !== undefined) throw refusal("open children beside your own terminal or a child, not by windowId");
      const anchor = params.anchorId ?? own;
      if (anchor !== own && !children.includes(String(anchor))) throw refusal(`anchorId ${String(anchor)} is not your terminal or a child you opened`);
      if (children.length + record.unconfirmed + terminalCount(params.layout ?? { _tag: "Terminal" }) > MAX_REX_CHILDREN) {
        throw refusal(`an actor may keep at most ${MAX_REX_CHILDREN} child terminals, counting ${record.unconfirmed} an uncertain split may have opened; close some with rex_blocks_close`);
      }
      return { ...params, anchorId: anchor, focus: false };
    }
    if (access === "close" && params.windowId !== undefined) throw refusal("close a child by blockId");
    const block = String(params.blockId);
    if (!children.includes(block) && !(access === "read" && block === own)) {
      throw refusal(access === "read" ? `block ${block} is not your terminal or a child you opened` : `block ${block} is not a child terminal you opened`);
    }
    return params;
  }

  /** The SDK's server must be the Rex instance that started this actor's terminal. */
  const verify = (binding: RexActor["binding"], fail: () => Error) => Effect.gen(function* () {
    const status = yield* (yield* RexSdk).server.status();
    if (status.instanceId !== binding.rex_instance_id || Option.getOrUndefined(status.hostId) !== binding.host_id) return yield* Effect.fail(fail());
    return null;
  });

  async function call(operation: RexToolOperation, access: Access, args: Record<string, unknown>, conversationId: string,
    context: Context): Promise<ToolExecutionResult> {
    const signal = context.abortSignal;
    const caller = await actor(conversationId, signal);
    let params = authorize(access, caller, caller, args);
    const notOwned = () => new RexNotOwned("the Rex server the coordinator reaches did not start this actor's terminal");
    const program = Effect.gen(function* () {
      const value = yield* makeRexToolProgram(operation, params, marksOf(caller.key));
      // The call ran; whatever stops this check leaves its effect uncertain.
      yield* verify(caller.binding, () => new RexServerChanged()).pipe(Effect.mapError(() => new RexServerChanged()));
      return value;
    });
    if (!MUTATES.includes(access)) {
      return output(toRexToolResult(await connection.run(Effect.andThen(verify(caller.binding, notOwned), program), signal)));
    }
    // The marker serializes this actor's writes, so the children checked here are current.
    const id = randomUUID();
    params = await harness.commit(async (tx) => {
      const doc = await owned(tx, caller);
      const checked = authorize(access, caller, doc, args);
      if (doc.uncertain !== null) {
        throw refusal(`${doc.uncertain.tool} (${doc.uncertain.id}) has no receipt or is still running and was not replayed. Inspect its effect with rex_sessions_view or rex_terminals_readTail, then call rex_here({ clearUncertain: "${doc.uncertain.id}" })`);
      }
      doc.uncertain = { id, tool: "rex_" + operation.name, block_id: typeof checked.blockId === "string" ? checked.blockId : null, at: Date.now(),
        terminals: access === "split" ? terminalCount(checked.layout ?? { _tag: "Terminal" }) : 0 };
      return checked;
    }, BACKGROUND_CONTEXT);
    running.add(id);
    try {
      // Nothing is sent until the owner and the server are confirmed, so failures up to here are definite.
      try {
        await gate?.fresh(signal);
        toRexToolResult(await connection.run(verify(caller.binding, notOwned), signal));
        signal?.throwIfAborted();
      } catch (error) { await settle(caller, id); throw error; }
      const exit = await connection.run(program, signal);
      if (Exit.isFailure(exit) && !definite(exit)) {
        let message: string;
        try { toRexToolResult(exit); message = "the call failed"; } catch (error) { message = error instanceof Error ? error.message : String(error); }
        throw new TaskError(`${message}. The outcome is uncertain and was not replayed; inspect it, then call rex_here({ clearUncertain: "${id}" }) before writing again.`);
      }
      const tag = Exit.isFailure(exit) ? Option.getOrUndefined(Cause.findErrorOption(exit.cause)) as { _tag?: unknown } | undefined : undefined;
      // A child the server no longer has stops counting against this actor.
      const gone = access === "close" && (Exit.isSuccess(exit) || tag?._tag === "RexNotFound" || tag?._tag === "RexBlockClosed");
      const opened = Exit.isSuccess(exit) && access === "split" ? (exit.value as { blockIds?: unknown }).blockIds : undefined;
      await settle(caller, id, (doc) => {
        if (Array.isArray(opened)) doc.children.push(...opened.filter((block): block is string => typeof block === "string"));
        if (gone) doc.children = doc.children.filter((block) => block !== params.blockId);
      });
      return output(toRexToolResult(exit));
    } finally { running.delete(id); }
  }
  function output(result: ReturnType<typeof toRexToolResult>): ToolExecutionResult {
    let value = result.structuredContent as JsonValue;
    if (typeof value === "object" && value !== null && !Array.isArray(value) && typeof value.markId === "string") {
      value = { ...value, markId: epoch + ":" + value.markId };
    }
    return { output: [{ type: "text", text: JSON.stringify(value) }], structuredOutput: value };
  }

  const operations: ToolRegistration[] = Object.entries(REX_OPERATIONS).map(([name, access]) => {
    const operation = rexToolOperations.find((candidate) => candidate.name === name);
    if (operation === undefined) throw new Error(`rex-sdk has no operation ${name}`);
    return defineTool({
      name: "rex_" + name, description: (DESCRIPTIONS[name] ?? operation.description) + SCOPE[access], deferred: true,
      ...(MUTATES.includes(access) ? {} : { replay: "safe" as const }),
      parameters: rexToolParametersJsonSchema({ fields: operation.fields, input: operation.input }),
      structuredOutputSchema: operation.output === "void" ? { type: "null" } : rexToolOutputJsonSchema(operation.output),
      execute: (args, api, context) => call(operation, access, args as Record<string, unknown>, api.conversationId.toString(), context),
    });
  });
  const here = defineTool({
    name: "rex_here", replay: "safe",
    description: "Your Rex terminal (sessionId, windowId, blockId), the child terminals you opened, and a write without a receipt, if any. Once you have inspected that write's effect, pass its id as clearUncertain.",
    parameters: Type.Object({ clearUncertain: Type.Optional(Type.String({ minLength: 1 })) }),
    structuredOutputSchema: HereOutput,
    async execute(args, api, context) {
      let caller = await actor(api.conversationId.toString(), context.abortSignal);
      const clear = args.clearUncertain;
      if (clear !== undefined) {
        if (running.has(clear)) throw new TaskError(`Write ${clear} is still running; wait for its result`);
        if (caller.uncertain !== null && caller.uncertain.id !== clear) throw new TaskError(`The uncertain write is ${caller.uncertain.id}, not ${clear}`);
        await harness.commit(async (tx) => {
          const doc = await owned(tx, caller);
          if (doc.uncertain?.id !== clear) return;
          doc.unconfirmed += doc.uncertain.terminals;
          doc.uncertain = null;
        }, BACKGROUND_CONTEXT);
        caller = await actor(api.conversationId.toString(), context.abortSignal);
      }
      const uncertain = caller.uncertain === null ? null
        : { id: caller.uncertain.id, tool: caller.uncertain.tool, blockId: caller.uncertain.block_id, at: caller.uncertain.at };
      const value = { sessionId: caller.binding.session_id, windowId: caller.binding.window_id, blockId: caller.binding.block_id,
        children: caller.children, unconfirmedTerminals: caller.unconfirmed, uncertain };
      return { output: [{ type: "text", text: JSON.stringify(value) }], structuredOutput: value };
    },
  });
  return { ...defineExtension({ name: "rex-tools", namespace: REX_NAMESPACE, tools: [here, ...operations] }),
    close: async () => { marks.clear(); await connection.dispose(); } };
}
