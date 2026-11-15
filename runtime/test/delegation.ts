import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, type FauxProviderHandle, type FauxResponseFactory, type FauxResponseStep } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { ConversationModels } from "../src/models.js";
import { TaskStore, type HostCall } from "../src/tasks.js";
import { createAppTools, Executions } from "../src/tools.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { fixtureModel } from "./model.js";

export const host: WorkerHost = { host_id: null, name: "fixture", rex_server: null, coordinator: null,
  cwd: "/workspace/example", agent_program: "/example/agent" };
export const binding: WorkerRef = {
  host_id: "11111111-1111-4111-8111-111111111111",
  session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333",
  block_id: "block:44444444-4444-4444-8444-444444444444",
};

export async function open(directory: string) {
  const database = await openNodeSqliteDatabase(join(directory, "session.sqlite"));
  await database.exec("PRAGMA synchronous = FULL");
  const storage = await SqliteStorage.open(database);
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  const models = createModels(); models.setProvider(faux.provider);
  const registry = createRegistry();
  const session = await Harness.open(storage, { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const tasks = new TaskStore(session, new ConversationModels(models));
  const executions = new Executions();
  const tools = createAppTools(tasks, executions);
  registry.install(tools.host); registry.install(tools.main); registry.install(tools.worker); registry.install(tools.agent); registry.install(tools.legacy);
  return { session, registry, tasks, executions, tools, faux };
}
export type App = Awaited<ReturnType<typeof open>>;

export function scriptActors(faux: FauxProviderHandle, stepsByInputMarker: Record<string, FauxResponseStep[]>): void {
  const route: FauxResponseFactory = (context, options, state, model) => {
    const first = context.messages.find((message) => message.role === "user");
    const input = first === undefined ? "" : typeof first.content === "string" ? first.content
      : first.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
    const marker = Object.keys(stepsByInputMarker).find((candidate) => input.includes(candidate));
    const step = marker === undefined ? undefined : stepsByInputMarker[marker]?.shift();
    if (step === undefined) throw new Error("No scripted model response for input: " + input.slice(0, 120));
    return typeof step === "function" ? step(context, options, state, model) : step;
  };
  faux.setResponses(Object.values(stepsByInputMarker).flat().map(() => route));
}

export function heldCall(answer: string) {
  let started = () => {}, release = () => {};
  const released = new Promise<void>((resolve) => { release = resolve; });
  const call = {
    started: new Promise<void>((resolve) => { started = resolve; }), aborted: false, release,
    step: (async (_context, options) => {
      const signal = options?.signal; assert.ok(signal);
      const stopped = new Promise<void>((resolve) => {
        const stop = () => { call.aborted = true; resolve(); };
        if (signal.aborted) stop(); else signal.addEventListener("abort", stop, { once: true });
      });
      started(); await Promise.race([released, stopped]);
      return fauxAssistantMessage(answer);
    }) satisfies FauxResponseFactory,
  };
  return call;
}

export async function within<T>(promise: Promise<T>, message: string, milliseconds = 5_000): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    return await Promise.race([promise, new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => reject(new assert.AssertionError({ message })), milliseconds);
    })]);
  } finally { clearTimeout(timer); }
}

export async function attachMainAndSpawnedWorkers(app: App, signal: AbortSignal) {
  const root = await app.session.root(BACKGROUND_CONTEXT);
  const answers: string[] = [], failures: unknown[] = [], runs: Promise<void>[] = [];
  const attach = (taskId: string, allocationId: string, worker: WorkerRef, agentId?: string) => {
    runs.push(app.tasks.run({ type: "run_task", task_id: taskId, ...(agentId === undefined ? {} : { agent_id: agentId }),
      allocation_id: allocationId, binding: worker, instructions: "", model: fixtureModel, cwd: host.cwd, interactive: true },
    (conversation) => app.executions.bind(conversation.id.toString(), { cwd: host.cwd, hosts: [host], call: effects }),
    [app.tools.host, agentId === undefined ? app.tools.worker : app.tools.agent], effects, undefined,
    { signal, async ready() {}, answer(_id, text) { answers.push(text); }, idle() {} }).then(() => {}, (error: unknown) => { failures.push(error); }));
  };
  const effects: HostCall = async (command) => {
    if (command.type === "spawn_worker") {
      attach(command.task_id, command.allocation_id, binding); return { type: "spawned", binding };
    }
    if (command.type === "spawn_subagent") {
      const worker = { ...binding, block_id: "block:" + randomUUID() };
      attach(command.task_id, command.allocation_id, worker, command.agent_id); return { type: "spawned", binding: worker };
    }
    throw new Error("Unexpected host effect: " + command.type);
  };
  const release = app.executions.bind(root.id.toString(), { model: fixtureModel, cwd: host.cwd, hosts: [host], call: effects });
  await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [app.tools.main] }, BACKGROUND_CONTEXT);
  return { root, answers, failures, async detach() { await Promise.all(runs); release(); } };
}
