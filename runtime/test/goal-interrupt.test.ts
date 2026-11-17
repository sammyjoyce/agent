import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import type { GoalStatus } from "../src/generated/GoalStatus.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { until as poll } from "./fixtures/until.js";

const hostId = "11111111-1111-4111-8111-111111111111";
const binding: WorkerRef = { host_id: hostId, session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333", block_id: "block:44444444-4444-4444-8444-444444444444" };

async function goalRuntime(responses: Record<string, ModelStep[]>) {
  const directory = await mkdtemp(join(tmpdir(), "agent-goal-interrupt-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify(responses));
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
  const closed = new Promise<number | null>((resolve) => child.once("close", resolve));
  const frames: { id: number; event: RuntimeEventKind }[] = [];
  const watchers = new Set<() => void>();
  const send = (id: number, command: unknown) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const until = (predicate: () => boolean) => new Promise<void>((resolve) => {
    const check = () => { if (predicate()) { watchers.delete(check); resolve(); } };
    watchers.add(check); check();
  });
  const done = (id: number) => until(() => frames.some((frame) => frame.id === id && frame.event.type === "done"));
  const runtime: { held?: { request: number; call: string }; execs: { request: number; call: string }[]; errors: string } = { execs: [], errors: "" };
  child.stderr.setEncoding("utf8").on("data", (value: string) => { runtime.errors += value; });
  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame));
      frames.push({ id: frame.id, event: frame.event });
      for (const watcher of [...watchers]) watcher();
      if (frame.event.type !== "host_call") continue;
      let command = frame.event.command; while (command.type === "on_node") command = command.command;
      if (command.type === "exec") {
        const exec = { request: frame.id, call: frame.event.call_id };
        runtime.execs.push(exec); runtime.held ??= exec;
        for (const watcher of [...watchers]) watcher(); continue;
      }
      const result: HostResult = command.type === "spawn_workspace_worker" ? { type: "spawned", binding }
        : command.type === "inspect_worker" ? { type: "worker_presence", presence: { state: "present", running: true } }
        : command.type === "reload_guidance" ? { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "",
          context_repositories: [], context_sources: [] }
        : command.type === "project_guidance" ? { type: "project_guidance", snapshot: { text: "", sources: [] } }
        : { type: "failed", message: "Synthetic retrieval disabled" };
      send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result });
    }
  })(); void reader.catch(() => {});
  const status = (id: number): GoalStatus => {
    const event = frames.find((frame) => frame.id === id && frame.event.type === "goal")?.event;
    if (event?.type !== "goal") throw new Error(`Request ${id} returned no goal status`);
    return event.status;
  };
  const requested = async () => (await readFile(queue + ".requests", "utf8").catch(() => "")).split("\n").filter((line) => line.length > 0)
    .map((line) => { const entry: unknown = JSON.parse(line); return typeof entry === "object" && entry !== null && "key" in entry ? entry.key : undefined; });
  async function start(objective: string): Promise<string> {
    send(1, { type: "configure_coordinator", bootstrap: { node: { host_id: hostId, name: "fixture", home_directory: "/tmp",
      agent_program: "/fixture/agent", coordinator: null, rex_server: null, launch: { model: null, state_dir: null, runtime: null, config: null, instructions: null } },
      settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } });
    await done(1);
    send(2, { type: "set_connected_nodes", host_ids: [hostId] }); await done(2);
    send(9, { type: "run_background", settings: { poll_interval_seconds: 3600, sources: false, jobs: null } });
    const goalId = randomUUID();
    send(3, { type: "goal", target: { type: "main" }, action: { type: "set", request_id: goalId, objective } });
    await done(3);
    return goalId;
  }
  async function pause(id: number, call: string): Promise<void> {
    send(id, { type: "goal", target: { type: "main" }, action: { type: "pause", request_id: randomUUID() } });
    await done(id);
    assert.deepEqual(status(id).goal?.goal.state, { state: "paused", reason: "requested" });
    await until(() => frames.some((frame) => frame.event.type === "host_cancel" && frame.event.call_id === call));
  }
  async function close(): Promise<void> {
    child.kill(); await closed; await reader.catch(() => {}); await rm(directory, { recursive: true, force: true });
  }
  return Object.assign(runtime, { child, closed, frames, send, until, done, status, requested, start, pause, close });
}
const cancelled: HostResult = { type: "process", exit_code: 143, stdout: "", stderr: "cancelled", truncated: false };

test("Esc during a goal pause still withdraws the worker's other queued inputs", { timeout: 20_000 }, async () => {
  const runtime = await goalRuntime({ "Goal set with /goal: goal-esc-hold": [{ tool: "exec", args: { program: "held", args: [] } }],
    "goal-esc-unrelated": [{ text: "Must not run" }] });
  const { frames, send, until, done } = runtime;
  try {
    const goalId = await runtime.start("goal-esc-hold the fixture report");
    const worker = runtime.status(3).goal?.task.worker;
    assert.ok(worker?.state === "bound", runtime.errors);
    send(4, { type: "run_task", task_id: goalId, allocation_id: worker.allocation_id, binding: worker.binding, instructions: "",
      model: DEFAULT_MODEL, cwd: "/tmp", interactive: true });
    await until(() => runtime.held !== undefined);
    const stopped = runtime.held; assert.ok(stopped);

    await runtime.pause(5, stopped.call);
    send(6, { type: "task_input", task_id: goalId, input_id: "unrelated-input", input: "goal-esc-unrelated", mode: "follow_up" });
    await done(6);
    assert.ok(frames.some((frame) => frame.id === 6 && frame.event.type === "input_accepted"));

    send(4, { type: "interrupt" });
    send(stopped.request, { type: "host_reply", call_id: stopped.call, result: cancelled });
    await until(() => frames.some((frame) => frame.id === 4 && frame.event.type === "worker_idle"));

    assert.equal(frames.some((frame) => frame.event.type === "answer" && frame.event.text === "Must not run"), false,
      "Esc must withdraw the input queued behind the paused goal turn");
    assert.deepEqual(await runtime.requested(), ["Goal set with /goal: goal-esc-hold"]);
    send(4, { type: "detach_worker" }); await done(4);
    runtime.child.stdin.end(); assert.equal(await runtime.closed, 0, runtime.errors);
  } finally { await runtime.close(); }
});

test("pause cancels the host call of a goal turn no terminal observes and the task's other input still runs", { timeout: 20_000 }, async () => {
  const runtime = await goalRuntime({ "Goal set with /goal: goal-pause-daemon": [{ tool: "exec", args: { program: "held", args: [] } }],
    "goal-pause-unrelated": [{ tool: "exec", args: { program: "after", args: [] } }, { text: "Answered the unrelated input" }] });
  const { frames, send, until, done } = runtime;
  try {
    const goalId = await runtime.start("goal-pause-daemon the fixture report");
    await until(() => runtime.held !== undefined);
    const stopped = runtime.held; assert.ok(stopped);

    await runtime.pause(5, stopped.call);
    send(6, { type: "task_input", task_id: goalId, input_id: "unrelated-input", input: "goal-pause-unrelated", mode: "follow_up" });
    await done(6);
    send(stopped.request, { type: "host_reply", call_id: stopped.call, result: cancelled });
    await until(() => runtime.execs.length === 2);
    const after = runtime.execs[1]; assert.ok(after);
    send(after.request, { type: "host_reply", call_id: after.call, result: { type: "process", exit_code: 0, stdout: "done", stderr: "", truncated: false } });
    await poll(async () => (await runtime.requested()).length === 3, "The unrelated turn must answer after its host call");
    assert.deepEqual(await runtime.requested(), ["Goal set with /goal: goal-pause-daemon", "goal-pause-unrelated", "goal-pause-unrelated"]);
    assert.equal(frames.some((frame) => frame.event.type === "host_cancel" && frame.event.call_id === after.call), false,
      "Work after the paused run gets a fresh turn signal");
  } finally { await runtime.close(); }
});
