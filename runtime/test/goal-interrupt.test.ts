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

const hostId = "11111111-1111-4111-8111-111111111111";
const binding: WorkerRef = { host_id: hostId, session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333", block_id: "block:44444444-4444-4444-8444-444444444444" };

test("Esc during a goal pause still withdraws the worker's other queued inputs", { timeout: 20_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-goal-interrupt-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify({ "Goal set with /goal: goal-esc-hold": [{ tool: "exec", args: { program: "held", args: [] } }],
    "goal-esc-unrelated": [{ text: "Must not run" }] }));
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
  let held: { request: number; call: string } | undefined;
  let errors = ""; child.stderr.setEncoding("utf8").on("data", (value: string) => { errors += value; });
  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame));
      frames.push({ id: frame.id, event: frame.event });
      for (const watcher of [...watchers]) watcher();
      if (frame.event.type !== "host_call") continue;
      let command = frame.event.command; while (command.type === "on_node") command = command.command;
      if (command.type === "exec") { held = { request: frame.id, call: frame.event.call_id }; for (const watcher of [...watchers]) watcher(); continue; }
      const result: HostResult = command.type === "spawn_worker" ? { type: "spawned", binding }
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
  try {
    send(1, { type: "configure_coordinator", bootstrap: { node: { host_id: hostId, name: "fixture", home_directory: "/tmp",
      agent_program: "/fixture/agent", coordinator: null, rex_server: null, launch: { model: null, state_dir: null, runtime: null, config: null, instructions: null } },
      settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } });
    await done(1);
    send(2, { type: "set_connected_nodes", host_ids: [hostId] }); await done(2);
    const goalId = randomUUID();
    send(3, { type: "goal", target: { type: "main" }, action: { type: "set", request_id: goalId, objective: "goal-esc-hold the fixture report" } });
    await done(3);
    const worker = status(3).goal?.task.worker;
    assert.ok(worker?.state === "bound", errors);
    send(4, { type: "run_task", task_id: goalId, allocation_id: worker.allocation_id, binding: worker.binding, instructions: "",
      model: DEFAULT_MODEL, cwd: "/tmp", interactive: true });
    await until(() => held !== undefined);
    const stopped = held; assert.ok(stopped);

    send(5, { type: "goal", target: { type: "main" }, action: { type: "pause", request_id: randomUUID() } });
    await done(5);
    assert.deepEqual(status(5).goal?.goal.state, { state: "paused", reason: "requested" });
    await until(() => frames.some((frame) => frame.event.type === "host_cancel" && frame.event.call_id === stopped.call));
    send(6, { type: "task_input", task_id: goalId, input_id: "unrelated-input", input: "goal-esc-unrelated", mode: "follow_up" });
    await done(6);
    assert.ok(frames.some((frame) => frame.id === 6 && frame.event.type === "input_accepted"));

    send(4, { type: "interrupt" });
    send(stopped.request, { type: "host_reply", call_id: stopped.call,
      result: { type: "process", exit_code: 143, stdout: "", stderr: "cancelled", truncated: false } });
    await until(() => frames.some((frame) => frame.id === 4 && frame.event.type === "worker_idle"));

    assert.equal(frames.some((frame) => frame.event.type === "answer" && frame.event.text === "Must not run"), false,
      "Esc must withdraw the input queued behind the paused goal turn");
    const requested = (await readFile(queue + ".requests", "utf8")).split("\n").filter((line) => line.length > 0)
      .map((line) => { const entry: unknown = JSON.parse(line); return typeof entry === "object" && entry !== null && "key" in entry ? entry.key : undefined; });
    assert.deepEqual(requested, ["Goal set with /goal: goal-esc-hold"]);
    send(4, { type: "detach_worker" }); await done(4);
    child.stdin.end(); assert.equal(await closed, 0, errors); await reader;
  } finally { child.kill(); await closed; await reader.catch(() => {}); await rm(directory, { recursive: true, force: true }); }
});
