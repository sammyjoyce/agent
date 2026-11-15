import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { DEFAULT_MODEL } from "../src/models.js";
import { validEvent } from "../src/protocol.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { TaskGraphActor } from "../src/generated/TaskGraphActor.js";
import type { TaskGraphNode } from "../src/generated/TaskGraphNode.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { binding, host } from "./delegation.js";
import type { ModelQueue } from "./fixtures/coordinator-runtime.js";

type HostCall = { id: number; call_id: string; command: HostCommand };

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
      const call = { id: frame.id, call_id: frame.event.call_id, command: frame.event.command };
      if (call.command.type === "reload_guidance") reply(call, { type: "shared_guidance", global: { text: "Brief fixture instructions.", sources: [] },
        workflow_policy: "", context_repositories: [], context_sources: [] });
      else if (call.command.type === "project_guidance") reply(call, { type: "project_guidance", snapshot: { text: "", sources: [] } });
      else if (call.command.type === "embed") reply(call, { type: "failed", message: "The fixture has no embedding host" });
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
  const hostCall = async <T extends HostCommand["type"]>(id: number, type: T): Promise<HostCall & { command: Extract<HostCommand, { type: T }> }> => {
    const frame = await wait(type + " in request " + id, () => frames.find((frame) => frame.id === id &&
      (frame.event.type === "failure" || (frame.event.type === "host_call" && frame.event.command.type === type))));
    assert.ok(frame.event.type === "host_call", JSON.stringify(frame.event));
    const command = frame.event.command; assert.ok(command.type === type);
    return { id, call_id: frame.event.call_id, command: command as Extract<HostCommand, { type: T }> };
  };
  const chat = (input: string, input_id: string): RuntimeCommand => ({ type: "chat", input, input_id, model: DEFAULT_MODEL, instructions: "Brief answers.",
    cwd: host.cwd, origin_host_id: null, hosts: [host] });
  const attach = (id: number, taskId: string, allocationId: string, worker: WorkerRef, agentId?: string) => send(id, { type: "run_task", task_id: taskId,
    ...(agentId === undefined ? {} : { agent_id: agentId }), allocation_id: allocationId, binding: worker, instructions: "", model: DEFAULT_MODEL,
    cwd: host.cwd, interactive: true });
  try {
    send(1, chat("fixture-graph-main: start the board review", "first-input"));
    const spawned = await hostCall(1, "spawn_worker"); reply(spawned, { type: "spawned", binding });
    assert.equal((await event(1, (event) => event.type === "done")).type, "done", errors);
    attach(2, spawned.command.task_id, spawned.command.allocation_id, binding);
    const subagent = await hostCall(2, "spawn_subagent");
    const agentBinding = { ...binding, block_id: "block:55555555-5555-4555-8555-555555555555" };
    reply(subagent, { type: "spawned", binding: agentBinding });
    attach(3, subagent.command.task_id, subagent.command.allocation_id, agentBinding, subagent.command.agent_id);
    await hostCall(2, "exec"); await hostCall(3, "exec");
    send(4, chat("fixture-graph-second: start the connector audit", "second-input"));
    await hostCall(4, "spawn_worker");

    send(5, { type: "read_task_graph" });
    const response = await event(5, (event) => event.type === "task_graph");
    assert.ok(response.type === "task_graph", "The runtime must answer a task graph request: " + JSON.stringify(response));
    const { nodes, conversations, omitted } = response.graph;
    assert.equal(omitted, 0);
    const work = (type: TaskGraphActor["type"]): TaskGraphNode[] => nodes.filter((node) =>
      conversations.find((conversation) => conversation.conversation_id === node.conversation_id)?.actor.type === type);
    const shape = (list: readonly TaskGraphNode[]) => list.map((node) => [node.kind, node.tool, node.state.status,
      node.owner === null ? null : list.findIndex((owner) => owner.id === node.owner),
      node.state.status === "waiting" ? node.state.on.map((id) => list.findIndex((target) => target.id === id)) : null]);
    const running = (tool: string) => [["pi.generation", null, "waiting", null, [1]], ["pi.tool", tool, "running", 0, null]];

    assert.deepEqual(shape(work("main")), running("delegate_task"));
    const delegate = conversations.find((conversation) => conversation.actor.type === "task"); assert.ok(delegate?.actor.type === "task");
    assert.deepEqual(delegate.actor, { type: "task", task_id: spawned.command.task_id, title: "Board review" });
    assert.deepEqual(shape(work("task")), running("exec"));
    const agent = conversations.find((conversation) => conversation.actor.type === "agent"); assert.ok(agent?.actor.type === "agent");
    assert.deepEqual(agent.actor, { type: "agent", task_id: spawned.command.task_id, agent_id: subagent.command.agent_id, title: "Review",
      parent_conversation_id: delegate.conversation_id });
    assert.deepEqual(shape(work("agent")), running("exec"));
    assert.deepEqual(conversations.map((conversation) => conversation.actor.type).sort(), ["agent", "main", "task"],
      "A delegate with no live native work stays out of the graph");
    assert.equal(nodes.every((node) => !node.background && !node.abort_requested && node.blocked === null && node.conversations.length === 0), true);
    assert.equal((await event(5, (event) => event.type === "done")).type, "done");
  } finally { lines.close(); child.stdin.end(); child.kill("SIGKILL"); await closed; await rm(directory, { recursive: true, force: true }); }
});
