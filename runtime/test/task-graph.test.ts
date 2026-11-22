import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineTask, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { DEFAULT_MODEL } from "../src/models.js";
import { validEvent } from "../src/protocol.js";
import { readTaskGraph, TASK_GRAPH_BYTE_LIMIT, TASK_GRAPH_NODE_LIMIT } from "../src/task-graph.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { TaskGraphActor } from "../src/generated/TaskGraphActor.js";
import type { TaskGraphNode } from "../src/generated/TaskGraphNode.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { binding, host, open, within } from "./delegation.js";
import type { ModelQueue } from "./fixtures/coordinator-runtime.js";

type HostCall = { id: number; call_id: string; command: HostCommand };
function unwrapOnNode(command: HostCommand): HostCommand { return command.type === "on_node" ? unwrapOnNode(command.command) : command; }

test("the task graph request joins live generations and tool calls with main, task and agent identity", { timeout: 30_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-task-graph-")); await chmod(directory, 0o700);
  const queue = join(directory, "responses.json");
  const hold = { tool: "exec", args: { program: "sleep", args: ["600"] } };
  await writeFile(queue, JSON.stringify({
    "fixture-graph-main": [
      { tool: "delegate_task", args: { input: "fixture-graph-delegate: inspect the board", title: "Board review", outcome: "Verify the board change" } },
      { text: "Delegated the board review." },
    ],
    "fixture-graph-delegate": [
      { tool: "spawn_agent", args: { title: "Review", outcome: "Review the bounded change", input: "fixture-graph-agent: review the change" } },
      hold,
    ],
    "fixture-graph-agent": [hold],
    "fixture-graph-second": [{ tool: "delegate_task", args: { input: "fixture-graph-other: audit the connector", title: "Connector audit",
      outcome: "Audit the connector", new_task: true, new_task_reason: "The connector audit is a separate outcome." } }],
  } satisfies ModelQueue));
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
  const closed = new Promise<void>((resolve) => child.once("close", () => resolve()));
  const lines = createInterface({ input: child.stdout }); const frames: RuntimeEvent[] = [];
  const listeners = new Set<() => void>(); let errors = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const reply = (call: HostCall, result: HostResult) => send(call.id, { type: "host_reply", call_id: call.call_id, result });
  lines.on("line", (line) => {
    const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame), "The bridge must emit typed protocol events: " + line); frames.push(frame);
    if (frame.event.type === "host_call") {
      const call = { id: frame.id, call_id: frame.event.call_id, command: unwrapOnNode(frame.event.command) };
      if (call.command.type === "reload_guidance") reply(call, { type: "shared_guidance", global: { text: "Brief fixture instructions.", sources: [] },
        workflow_policy: "", context_repositories: [], context_sources: [] });
      else if (call.command.type === "project_guidance") reply(call, { type: "project_guidance", snapshot: { text: "", sources: [] } });
      else if (call.command.type === "embed") reply(call, { type: "failed", message: "The fixture has no embedding host" });
      else if (call.command.type === "background") reply(call, { type: "failed", message: "The fixture schedules nothing" });
    }
    for (const notify of listeners) notify();
  });
  const wait = (describe: string, find: () => RuntimeEvent | undefined): Promise<RuntimeEvent> => new Promise((resolve, reject) => {
    function cleanup(): void { listeners.delete(check); t.signal.removeEventListener("abort", stopped); child.off("close", stopped); }
    function stopped(): void {
      cleanup(); reject(new Error("The bridge never reached: " + describe + "\n" + JSON.stringify(frames.slice(-12).map((frame) => ({ id: frame.id, event: frame.event }))) + errors));
    }
    function check(): void { const frame = find(); if (frame === undefined) return; cleanup(); resolve(frame); }
    listeners.add(check); t.signal.addEventListener("abort", stopped, { once: true }); child.once("close", stopped);
    if (t.signal.aborted || child.exitCode !== null || child.signalCode !== null) stopped(); else check();
  });
  const event = async (id: number, predicate: (event: RuntimeEventKind) => boolean): Promise<RuntimeEventKind> =>
    (await wait("request " + id, () => frames.find((frame) => frame.id === id && (predicate(frame.event) || frame.event.type === "failure")))).event;
  const hostCall = async <T extends HostCommand["type"]>(id: number, type: T, nth = 0): Promise<HostCall & { command: Extract<HostCommand, { type: T }> }> => {
    const frame = await wait(type + " in request " + id, () => frames.filter((frame) => frame.id === id &&
      (frame.event.type === "failure" || (frame.event.type === "host_call" && unwrapOnNode(frame.event.command).type === type)))[nth]);
    assert.ok(frame.event.type === "host_call", JSON.stringify(frame.event));
    const command = unwrapOnNode(frame.event.command); assert.ok(command.type === type);
    return { id, call_id: frame.event.call_id, command: command as Extract<HostCommand, { type: T }> };
  };
  const chat = (input: string, input_id: string): RuntimeCommand => ({ type: "chat", input, input_id, model: DEFAULT_MODEL, instructions: "Brief answers.",
    cwd: host.cwd, origin_host_id: null, hosts: [host] });
  const attach = (id: number, taskId: string, allocationId: string, worker: WorkerRef, agentId?: string) => send(id, { type: "run_task", task_id: taskId,
    ...(agentId === undefined ? {} : { agent_id: agentId }), allocation_id: allocationId, binding: worker, instructions: "", model: DEFAULT_MODEL,
    cwd: host.cwd, interactive: true });
  const serviceRequestId = 9;
  try {
    send(serviceRequestId, { type: "run_background", settings: { poll_interval_seconds: 3600, sources: false, jobs: null } });
    send(1, chat("fixture-graph-main: start the board review", "first-input"));
    const spawned = await hostCall(1, "spawn_workspace_worker"); reply(spawned, { type: "spawned", binding });
    assert.equal((await event(1, (event) => event.type === "done")).type, "done", errors);
    attach(2, spawned.command.task_id, spawned.command.allocation_id, binding);
    const subagent = await hostCall(serviceRequestId, "spawn_subagent");
    const agentBinding = { ...binding, block_id: "block:55555555-5555-4555-8555-555555555555" };
    reply(subagent, { type: "spawned", binding: agentBinding });
    attach(3, subagent.command.task_id, subagent.command.allocation_id, agentBinding, subagent.command.agent_id);
    await hostCall(serviceRequestId, "exec", 0); await hostCall(serviceRequestId, "exec", 1);
    send(4, chat("fixture-graph-second: start the connector audit", "second-input"));
    const inspected = await hostCall(4, "inspect_worker");
    reply(inspected, { type: "worker_presence", presence: { state: "present", running: true } });
    await hostCall(4, "spawn_workspace_worker");

    send(5, { type: "read_task_graph" });
    const response = await event(5, (event) => event.type === "task_graph");
    assert.ok(response.type === "task_graph", "The runtime must answer a task graph request: " + JSON.stringify(response));
    const { conversations, omitted } = response.graph;
    assert.equal(omitted, 0);
    const schedulerTimer = (node: TaskGraphNode) => node.kind.type === "other" && node.kind.name === "agent.background";
    const nodes = response.graph.nodes.filter((node) => !schedulerTimer(node));
    const work = (type: TaskGraphActor["type"]): TaskGraphNode[] => nodes.filter((node) =>
      conversations.find((conversation) => conversation.conversation_id === node.conversation_id)?.actor.type === type);
    const shape = (list: readonly TaskGraphNode[]) => list.map((node) => [node.kind, node.state.status,
      node.owner === null ? null : list.findIndex((owner) => owner.id === node.owner),
      node.state.status === "waiting" ? node.state.on.map((id) => list.findIndex((target) => target.id === id)) : null]);
    const running = (name: string) => [[{ type: "generation" }, "waiting", null, [1]], [{ type: "tool", name }, "running", 0, null]];
    const scripted = (name: string) => [...running("codemode"), [{ type: "tool", name }, "running", 1, null]];

    assert.deepEqual(shape(work("main")), running("delegate_task"));
    const delegate = conversations.find((conversation) => conversation.actor.type === "task"); assert.ok(delegate?.actor.type === "task");
    assert.deepEqual(delegate.actor, { type: "task", task_id: spawned.command.task_id, title: "Board review" });
    assert.deepEqual(shape(work("task")), scripted("exec"), "A worker's command runs nested in its code mode call");
    const agent = conversations.find((conversation) => conversation.actor.type === "agent"); assert.ok(agent?.actor.type === "agent");
    assert.deepEqual(agent.actor, { type: "agent", task_id: spawned.command.task_id, agent_id: subagent.command.agent_id, title: "Review",
      parent_conversation_id: delegate.conversation_id });
    assert.deepEqual(shape(work("agent")), scripted("exec"));
    assert.deepEqual(conversations.map((conversation) => conversation.actor.type).sort(), ["agent", "main", "task"],
      "A delegate with no live native work stays out of the graph");
    assert.equal(nodes.every((node) => !node.background && !node.abort_requested && node.blocked === null && node.conversations.length === 0), true);
    assert.equal((await event(5, (event) => event.type === "done")).type, "done");
  } finally { lines.close(); child.stdin.end(); child.kill("SIGKILL"); await closed; await rm(directory, { recursive: true, force: true }); }
});

test("the task graph shows sleeping, blocked and background work, keeps an idle task as its agent's parent, and bounds its count and bytes", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-task-graph-")); const app = await open(directory);
  const wake = Date.UTC(2100, 0, 1);
  const abort = async () => {};
  const timer = defineTask<null, { phase: "wait" }, null>({ name: "fixture.timer", version: 1, initial: () => ({ phase: "wait" }), abort, phases: {
    wait: async (task, runtime, context) => { await runtime.commit(() => ({ status: "sleeping", until: wake, checkpoint: task.state.checkpoint }), context); },
  } });
  const retired = defineTask<null, { phase: "run" }, null>({ name: "fixture.retired", version: 1, initial: () => ({ phase: "run" }), abort, phases: { run: async () => {} } });
  app.registry.install({ name: "fixture", tasks: [timer] });
  try {
    await app.session.root(BACKGROUND_CONTEXT);
    const task = await app.tasks.create({ title: "Idle parent", outcome: "Keep the review moving" });
    const agent = await app.tasks.createAgent(task.id, { id: "review", title: "Review", outcome: "Review the change", input: "Review the change", inputId: "review-input" });
    const agentConversation = await app.tasks.conversation(agent.conversation_id);
    const created = await app.session.commit(async (tx) => {
      const stray = await tx.createConversation({ ownership: { kind: "ownerless" } });
      return {
        stray: stray.id,
        timer: await tx.createTask(timer, null, { ownership: { kind: "conversation" }, conversationId: ROOT_CONVERSATION_ID, background: true }),
        agent: await tx.createTask(retired, null, { ownership: { kind: "conversation" }, conversationId: agentConversation.id }),
        parent: await tx.createTask(retired, null, { ownership: { kind: "conversation" }, conversationId: stray.id }),
      };
    }, BACKGROUND_CONTEXT);
    app.session.resume();
    const graph = await within((async () => {
      for (;;) {
        const graph = await readTaskGraph(app.tasks);
        if (graph.nodes.some((node) => node.id === created.timer && node.state.status === "sleeping")) return graph;
        await new Promise<void>((resolve) => setTimeout(resolve, 10));
      }
    })(), "The timer must reach its sleep");
    assert.ok(validEvent({ version: 1, id: 1, event: { type: "task_graph", graph } }), "The graph must satisfy the generated event schema");
    const blocked = { kind: { type: "other", name: "fixture.retired" }, owner: null, background: false, abort_requested: false,
      state: { status: "pending", phase: "run" }, blocked: "missing_task", conversations: [] };
    assert.deepEqual(graph, {
      nodes: [
        { id: created.timer, kind: { type: "other", name: "fixture.timer" }, conversation_id: ROOT_CONVERSATION_ID.toString(), owner: null,
          background: true, abort_requested: false, state: { status: "sleeping", phase: "wait", until: wake }, blocked: null, conversations: [] },
        { ...blocked, id: created.agent, conversation_id: agent.conversation_id },
        { ...blocked, id: created.parent, conversation_id: created.stray.toString() },
      ],
      conversations: [
        { conversation_id: ROOT_CONVERSATION_ID.toString(), actor: { type: "main" } },
        { conversation_id: task.conversation_id, actor: { type: "task", task_id: task.id, title: "Idle parent" } },
        { conversation_id: agent.conversation_id, actor: { type: "agent", task_id: task.id, agent_id: "review", title: "Review", parent_conversation_id: task.conversation_id } },
        { conversation_id: created.stray.toString(), actor: { type: "other" } },
      ],
      omitted: 0,
    });

    const taskConversation = await app.tasks.conversation(task.conversation_id);
    const nested = await app.session.commit(async (tx) => {
      for (let index = 0; index < TASK_GRAPH_NODE_LIMIT; index += 1) {
        await tx.createTask(retired, null, { ownership: { kind: "task", taskId: created.parent }, conversationId: created.stray });
      }
      return tx.createTask(retired, null, { ownership: { kind: "conversation" }, conversationId: taskConversation.id });
    }, BACKGROUND_CONTEXT);
    const bounded = await readTaskGraph(app.tasks);
    assert.equal(bounded.nodes.length, TASK_GRAPH_NODE_LIMIT); assert.equal(bounded.omitted, 4);
    assert.ok(bounded.nodes.some((node) => node.id === nested && node.conversation_id === task.conversation_id),
      "The bound must drop nested work before another conversation's newer work");
    assert.equal(bounded.nodes.filter((node) => node.owner === created.parent).length, TASK_GRAPH_NODE_LIMIT - 4);
    assert.ok(validEvent({ version: 1, id: 1, event: { type: "task_graph", graph: bounded } }));
    assert.ok(TASK_GRAPH_BYTE_LIMIT <= 4 * 1024 * 1024 / 2, "The byte limit must leave room inside the runtime's 4 MiB frame");
    const bytes = Buffer.byteLength(JSON.stringify(bounded));
    assert.ok(bytes < TASK_GRAPH_BYTE_LIMIT / 4, "A full snapshot of ordinary work must stay far below the byte limit, not " + bytes + " bytes");

    const verbose = await app.tasks.create({ title: "Long title ".repeat(TASK_GRAPH_BYTE_LIMIT / 10), outcome: "Carry an oversized label" });
    const verboseConversation = await app.tasks.conversation(verbose.conversation_id);
    await app.session.commit((tx) => tx.createTask(retired, null, { ownership: { kind: "conversation" }, conversationId: verboseConversation.id }), BACKGROUND_CONTEXT);
    await assert.rejects(readTaskGraph(app.tasks), /task graph is too large to send/,
      "An oversized snapshot must fail its own request, not overflow the runtime frame");
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

test("bridge rejects an oversized task-graph request without breaking subsequent commands", { timeout: 30_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-task-graph-bridge-"));
  const oversized = await open(directory);
  const abort = async () => {};
  const held = defineTask<null, { phase: "run" }, null>({ name: "fixture.held", version: 1, initial: () => ({ phase: "run" }), abort,
    phases: { run: async () => new Promise<never>(() => {}) } });
  oversized.registry.install({ name: "fixture", tasks: [held] });
  try {
    const verbose = await oversized.tasks.create({ title: "Oversized title ".repeat(TASK_GRAPH_BYTE_LIMIT / 14), outcome: "Overflow graph snapshot" });
    const conversation = await oversized.tasks.conversation(verbose.conversation_id);
    await oversized.session.commit((tx) => tx.createTask(held, null, { ownership: { kind: "conversation" }, conversationId: conversation.id }), BACKGROUND_CONTEXT);
  } finally { await oversized.session.close(BACKGROUND_CONTEXT); }

  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("../src/bridge.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "" } });
  const closed = new Promise<void>((resolve) => child.once("close", () => resolve()));
  const lines = createInterface({ input: child.stdout });
  const frames: RuntimeEvent[] = []; const listeners = new Set<() => void>(); let errors = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });
  lines.on("line", (line) => {
    const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame)); frames.push(frame);
    for (const notify of listeners) notify();
  });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const collect = (id: number): Promise<RuntimeEventKind[]> => new Promise((resolve, reject) => {
    function cleanup(): void { listeners.delete(check); t.signal.removeEventListener("abort", aborted); child.off("close", aborted); }
    function aborted(): void { cleanup(); reject(new Error("Bridge ended before request " + id + ": " + errors)); }
    function check(): void {
      const own = frames.filter((frame) => frame.id === id).map((frame) => frame.event);
      if (!own.some((event) => event.type === "done")) return;
      cleanup(); resolve(own);
    }
    listeners.add(check); t.signal.addEventListener("abort", aborted, { once: true }); child.once("close", aborted);
    if (t.signal.aborted || child.exitCode !== null || child.signalCode !== null) aborted(); else check();
  });
  try {
    send(1, { type: "read_task_graph" });
    const oversizedReply = await collect(1);
    assert.deepEqual(oversizedReply.map((event) => event.type), ["failure", "done"]);
    const failure = oversizedReply[0];
    assert.ok(failure?.type === "failure");
    assert.equal(failure.code, "invalid_request");
    assert.match(failure.message, /task graph is too large to send/u);

    send(2, { type: "list_tasks" });
    const followUp = await collect(2);
    assert.deepEqual(followUp.map((event) => event.type), ["tasks", "done"]);
  } finally { lines.close(); child.stdin.end(); child.kill("SIGKILL"); await closed; await rm(directory, { recursive: true, force: true }); }
});
