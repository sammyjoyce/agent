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
import { BACKGROUND_CONTEXT, withAbortSignal, type Context } from "@earendil-works/chord/context";
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
/** How long a call waits for an actor's terminal that is still opening, or its execution that is still recovering. */
const BINDING_WAIT_MS = 15_000;
const TERMINAL_FLAVOR = "com.superlogical.terminal.shell";
/** Every child's label ends with this and the id of the split that opened it; actors cannot choose such a label. */
const CHILD_LABEL = "beep-boop:";
/** Failures reported before any request was sent, or by a server that refused it. Others leave a write uncertain. */
const DEFINITE = new Set(["RexNotOwned", "RexInvalidInput", "SchemaError", "RexConfigurationError", "RexConnectionError", "RexHandshakeError",
  "RexUnsupportedApiRevision", "RexMessageTooLarge", "RexBadRequest", "RexNotFound", "RexSessionNotFound", "RexMethodNotFound", "RexConflict",
  "RexNotSupported", "RexRefused", "RexTooLarge", "RexRevisionTooLow", "RexInvalidPattern", "RexUnknownMark", "RexBlockClosed"]);

type Uncertain = { id: string; tool: string; block_id: string | null; at: number; terminals: number };
/** `pending`: cleared uncertain splits whose terminals were not found yet. They count against the limit until adopted. */
type Owned = { instance_id: string | null; children: string[]; pending: { id: string; terminals: number }[]; uncertain: Uncertain | null };
const RexOwned = defineDocFamily<Owned, null>({ kind: "agent.rex.owned", scope: "session", family: true, version: 1,
  initial: () => ({ instance_id: null, children: [], pending: [], uncertain: null }), checkpointWhen: () => true });

/** The actor's recorded terminal, confirmed by the Rex instance that started it. */
export type RexActor = { key: string; binding: WorkerRef & { rex_instance_id: string } };
export type RexActorResolver = (conversationId: string, context: Context) => Promise<RexActor>;

class RexNotOwned extends Error {
  readonly _tag = "RexNotOwned";
  constructor(message: string) { super(message); this.name = "RexNotOwned"; }
}
/** The server could not be confirmed after the call ran, so its effect is uncertain. */
class RexServerChanged extends Error {
  readonly _tag = "RexServerChanged";
  constructor(why: string) { super(`after the call, the Rex server was not confirmed as the one that started this actor's terminal (${why})`); this.name = "RexServerChanged"; }
}
function refusal(message: string): TaskError { return new TaskError("RexNotOwned: " + message); }
function tagOf(error: unknown): string {
  return typeof error === "object" && error !== null && "_tag" in error ? String(error._tag) : error instanceof Error ? error.name : String(error);
}

/** The server the SDK reaches: unset leaves Rex tools off, "personal" uses the SDK's own default selection. */
export function rexServerFromEnv(env: NodeJS.ProcessEnv = process.env): { server?: string } | undefined {
  const value = env.AGENT_REX_SDK_SERVER;
  if (value === undefined || value === "") return undefined;
  return value === "personal" ? {} : { server: value };
}

/** Task workers and their agents only, bound to a terminal whose Rex instance is recorded. */
export function taskRexActors(tasks: TaskStore, executions: Executions): RexActorResolver {
  return async (conversationId, context) => {
    const recovering = withAbortSignal(AbortSignal.timeout(BINDING_WAIT_MS), context);
    let execution: Awaited<ReturnType<Executions["ready"]>>;
    try { execution = await executions.ready(conversationId, recovering); } catch (error) {
      if (recovering.abortSignal?.aborted === true && context.abortSignal?.aborted !== true) throw refusal("this actor's execution is still recovering; retry shortly");
      throw error;
    }
    if (execution.role !== "worker") throw refusal("only task workers and their agents reach Rex");
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
      await delay(100, undefined, context.abortSignal === undefined ? undefined : { signal: context.abortSignal });
    }
  };
}

function terminalCount(layout: unknown, seen = 0): number {
  if (typeof layout !== "object" || layout === null) throw refusal("layout must be a Terminal or Split node");
  const node = layout as { _tag?: unknown; label?: unknown; before?: unknown; after?: unknown };
  let count: number;
  if (node._tag === "Terminal") {
    if (typeof node.label === "string" && node.label.includes(CHILD_LABEL)) throw refusal(`a child's label may not contain ${CHILD_LABEL}`);
    count = seen + 1;
  } else if (node._tag === "Split") count = terminalCount(node.after, terminalCount(node.before, seen));
  else throw refusal("layout may hold only Terminal and Split nodes");
  if (count > MAX_LAYOUT_TERMINALS) throw refusal(`a layout may open at most ${MAX_LAYOUT_TERMINALS} terminals`);
  return count;
}

/** Marks each terminal of a checked layout with the split that opens it, so an uncertain split's terminals can be found later. */
function labelled(layout: unknown, id: string): unknown {
  const node = layout as { _tag?: unknown; label?: unknown; before?: unknown; after?: unknown };
  if (node._tag === "Split") return { ...node, before: labelled(node.before, id), after: labelled(node.after, id) };
  return { ...node, label: (typeof node.label === "string" ? node.label.slice(0, 64) + " " : "") + CHILD_LABEL + id };
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
One write at a time. A write without a receipt (RexConnectionLost, RexRequestTimeout, interrupted) is not replayed, and further writes are refused until you inspect its effect and call rex_here({ clearUncertain: <its id> }). Terminals an uncertain split opened become your children once rex_here finds them by their label; until then they count against your ${MAX_REX_CHILDREN} children.
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
  const operation = (name: string): RexToolOperation => {
    const found = rexToolOperations.find((candidate) => candidate.name === name);
    if (found === undefined) throw new Error(`rex-sdk has no operation ${name}`);
    return found;
  };
  const viewOperation = operation("sessions_view");
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

  async function actor(conversationId: string, context: Context): Promise<RexActor & Omit<Owned, "instance_id">> {
    const resolved = await actors(conversationId, context);
    const saved = await harness.snapshot(RexOwned, resolved.key, BACKGROUND_CONTEXT);
    const current = saved?.instance_id === resolved.binding.rex_instance_id;
    return { ...resolved, children: current ? [...saved.children] : [], pending: current ? saved.pending.map((entry) => ({ ...entry })) : [],
      uncertain: current ? saved.uncertain : null };
  }
  /** The actor's record, reset when its terminal now belongs to another Rex instance. */
  async function owned(tx: Tx, caller: RexActor): Promise<Owned> {
    const doc = await tx.doc(RexOwned, caller.key, null);
    if (doc.instance_id !== caller.binding.rex_instance_id) {
      doc.instance_id = caller.binding.rex_instance_id; doc.children = []; doc.pending = []; doc.uncertain = null;
    }
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
  const unconfirmed = (record: Pick<Owned, "pending">) => record.pending.reduce((sum, entry) => sum + entry.terminals, 0);

  function authorize(access: Access, caller: RexActor, record: Pick<Owned, "children" | "pending">,
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
      if (children.length + unconfirmed(record) + terminalCount(params.layout ?? { _tag: "Terminal" }) > MAX_REX_CHILDREN) {
        throw refusal(`an actor may keep at most ${MAX_REX_CHILDREN} child terminals, counting ${unconfirmed(record)} an uncertain split may have opened; close some with rex_blocks_close`);
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
  const notOwned = () => new RexNotOwned("the Rex server the coordinator reaches did not start this actor's terminal");
  /** Runs an operation, then confirms the server again; failing that, the call's effect is uncertain. */
  const checked = (caller: RexActor, run: RexToolOperation, params: Record<string, unknown>) => Effect.gen(function* () {
    const value = yield* makeRexToolProgram(run, params, marksOf(caller.key));
    yield* verify(caller.binding, () => new RexServerChanged("another instance answered")).pipe(
      Effect.mapError((cause) => cause instanceof RexServerChanged ? cause : new RexServerChanged(tagOf(cause))));
    return value;
  });

  /** Adopts the terminals of cleared uncertain splits that the actor's session now shows with their label. */
  async function adopt(caller: RexActor, signal: AbortSignal | undefined): Promise<void> {
    const exit = await connection.run(Effect.andThen(verify(caller.binding, notOwned),
      checked(caller, viewOperation, { sessionId: caller.binding.session_id })), signal);
    if (Exit.isFailure(exit)) return;
    type Block = { blockId?: unknown; label?: unknown; flavor?: unknown; hostId?: unknown };
    const view = exit.value as { windows?: { layers?: { blocks?: Block[] }[] }[] } | null;
    const blocks = (view?.windows ?? []).flatMap((window) => (window.layers ?? []).flatMap((layer) => layer.blocks ?? []));
    await harness.commit(async (tx) => {
      const doc = await owned(tx, caller);
      for (const entry of doc.pending) {
        const found = blocks.filter((block): block is Block & { blockId: string } => typeof block.blockId === "string"
          && typeof block.label === "string" && block.label.endsWith(CHILD_LABEL + entry.id) && block.flavor === TERMINAL_FLAVOR
          && block.hostId === caller.binding.host_id && block.blockId !== caller.binding.block_id && !doc.children.includes(block.blockId))
          .slice(0, entry.terminals).map((block) => block.blockId);
        doc.children.push(...found);
        entry.terminals -= found.length;
      }
      doc.pending = doc.pending.filter((entry) => entry.terminals > 0);
    }, BACKGROUND_CONTEXT);
  }

  async function call(run: RexToolOperation, access: Access, args: Record<string, unknown>, conversationId: string,
    context: Context): Promise<ToolExecutionResult> {
    const signal = context.abortSignal;
    let caller = await actor(conversationId, context);
    if (access === "split" && caller.pending.length > 0) { await adopt(caller, signal); caller = await actor(conversationId, context); }
    let params = authorize(access, caller, caller, args);
    if (!MUTATES.includes(access)) {
      return output(toRexToolResult(await connection.run(Effect.andThen(verify(caller.binding, notOwned), checked(caller, run, params)), signal)));
    }
    const id = randomUUID();
    running.add(id);
    try {
      // The marker serializes this actor's writes, so the children checked here are current.
      params = await harness.commit(async (tx) => {
        const doc = await owned(tx, caller);
        const allowed = authorize(access, caller, doc, args);
        if (doc.uncertain !== null) {
          throw refusal(`${doc.uncertain.tool} (${doc.uncertain.id}) has no receipt or is still running and was not replayed. Inspect its effect with rex_sessions_view or rex_terminals_readTail, then call rex_here({ clearUncertain: "${doc.uncertain.id}" })`);
        }
        const terminals = access === "split" ? terminalCount(allowed.layout ?? { _tag: "Terminal" }) : 0;
        doc.uncertain = { id, tool: "rex_" + run.name, block_id: typeof allowed.blockId === "string" ? allowed.blockId : null, at: Date.now(), terminals };
        return access === "split" ? { ...allowed, layout: labelled(allowed.layout ?? { _tag: "Terminal" }, id) } : allowed;
      }, BACKGROUND_CONTEXT);
      // Nothing is sent until the owner and the server are confirmed, so failures up to here are definite.
      try {
        await gate?.fresh(AbortSignal.any([AbortSignal.timeout(MAX_REQUEST_MS), ...(signal === undefined ? [] : [signal])]));
        toRexToolResult(await connection.run(verify(caller.binding, notOwned), signal));
        signal?.throwIfAborted();
      } catch (error) { await settle(caller, id); throw error; }
      const exit = await connection.run(checked(caller, run, params), signal);
      if (Exit.isFailure(exit) && !definite(exit)) {
        let message: string;
        try { toRexToolResult(exit); message = "the call failed"; } catch (error) { message = error instanceof Error ? error.message : String(error); }
        throw new TaskError(`${message}. The outcome is uncertain and was not replayed; inspect it, then call rex_here({ clearUncertain: "${id}" }) before writing again.`);
      }
      const failure = Exit.isFailure(exit) ? tagOf(Option.getOrUndefined(Cause.findErrorOption(exit.cause))) : undefined;
      // A child the server no longer has stops counting against this actor.
      const gone = access === "close" && (failure === undefined || failure === "RexNotFound" || failure === "RexBlockClosed");
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
    const run = operation(name);
    return defineTool({
      name: "rex_" + name, description: (DESCRIPTIONS[name] ?? run.description) + SCOPE[access], deferred: true,
      ...(MUTATES.includes(access) ? {} : { replay: "safe" as const }),
      parameters: rexToolParametersJsonSchema({ fields: run.fields, input: run.input }),
      structuredOutputSchema: run.output === "void" ? { type: "null" } : rexToolOutputJsonSchema(run.output),
      execute: (args, api, context) => call(run, access, args as Record<string, unknown>, api.conversationId.toString(), context),
    });
  });
  const here = defineTool({
    name: "rex_here", replay: "safe",
    description: "Your Rex terminal (sessionId, windowId, blockId), the child terminals you opened, and a write without a receipt, if any. Once you have inspected that write's effect, pass its id as clearUncertain.",
    parameters: Type.Object({ clearUncertain: Type.Optional(Type.String({ minLength: 1 })) }),
    structuredOutputSchema: HereOutput,
    async execute(args, api, context) {
      const conversationId = api.conversationId.toString();
      let caller = await actor(conversationId, context);
      const clear = args.clearUncertain;
      if (clear !== undefined) {
        if (running.has(clear)) throw new TaskError(`Write ${clear} is still running; wait for its result`);
        if (caller.uncertain !== null && caller.uncertain.id !== clear) throw new TaskError(`The uncertain write is ${caller.uncertain.id}, not ${clear}`);
        await harness.commit(async (tx) => {
          const doc = await owned(tx, caller);
          if (doc.uncertain?.id !== clear) return;
          if (doc.uncertain.terminals > 0) doc.pending.push({ id: clear, terminals: doc.uncertain.terminals });
          doc.uncertain = null;
        }, BACKGROUND_CONTEXT);
        caller = await actor(conversationId, context);
      }
      if (caller.pending.length > 0) { await adopt(caller, context.abortSignal); caller = await actor(conversationId, context); }
      const uncertain = caller.uncertain === null ? null
        : { id: caller.uncertain.id, tool: caller.uncertain.tool, blockId: caller.uncertain.block_id, at: caller.uncertain.at };
      const value = { sessionId: caller.binding.session_id, windowId: caller.binding.window_id, blockId: caller.binding.block_id,
        children: caller.children, unconfirmedTerminals: unconfirmed(caller), uncertain };
      return { output: [{ type: "text", text: JSON.stringify(value) }], structuredOutput: value };
    },
  });
  return { ...defineExtension({ name: "rex-tools", namespace: REX_NAMESPACE, tools: [here, ...operations] }),
    close: async () => { marks.clear(); await connection.dispose(); } };
}
