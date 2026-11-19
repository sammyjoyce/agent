import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { DEFAULT_MODEL } from "../src/models.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";

const HOST = "11111111-1111-4111-8111-111111111111";
const CAR = "ca400000-0000-4000-8000-000000000001";

async function coordinator(t: TestContext, steps: Record<string, unknown[]>) {
  const directory = await mkdtemp(join(tmpdir(), "agent-carplay-turn-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify(steps));
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
  const closed = new Promise<number | null>((resolve) => child.once("close", resolve));
  const frames: RuntimeEvent[] = [], changes = new Set<() => void>();
  let errors = "";
  child.stderr.setEncoding("utf8").on("data", (text: string) => { errors += text; });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const events = (id: number) => frames.filter((frame) => frame.id === id).map((frame) => frame.event);
  const wait = (id: number, predicate: (event: RuntimeEventKind) => boolean): Promise<RuntimeEventKind> => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { changes.delete(check); reject(new Error(`Request ${id} stalled: ${errors}`)); }, 15_000);
    const check = () => { const event = events(id).find(predicate); if (event !== undefined) { clearTimeout(timer); changes.delete(check); resolve(event); } };
    changes.add(check); check();
  });
  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame)); frames.push(frame);
      for (const check of changes) check();
      if (frame.event.type !== "host_call") continue;
      let command = frame.event.command; while (command.type === "on_node") command = command.command;
      const result: HostResult = command.type === "reload_guidance" ? { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] }
        : command.type === "project_guidance" ? { type: "project_guidance", snapshot: { text: "", sources: [] } }
        : { type: "failed", message: "Synthetic retrieval disabled" };
      send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result });
    }
  })(); void reader.catch(() => {});
  t.after(async () => { child.kill(); await closed; await reader.catch(() => {}); await rm(directory, { recursive: true, force: true }); });
  const done = (id: number) => wait(id, (event) => event.type === "done");
  send(1, { type: "configure_coordinator", bootstrap: { node: { host_id: HOST, name: "fixture", home_directory: "/tmp", agent_program: "/fixture/agent", rex_server: null, coordinator: null,
    launch: { model: null, state_dir: null, runtime: null, config: null, instructions: null } }, settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } });
  await done(1);
  return { send, events, wait, done };
}

test("a CarPlay input's completion names an answer entry apart from the driver's, and observers get that answer", { timeout: 60_000 }, async (t) => {
  const peer = await coordinator(t, { "Is the invented deploy done": [{ text: "The invented deploy finished." }] });
  peer.send(2, { type: "set_connected_nodes", host_ids: [HOST] }); await peer.done(2);
  peer.send(100, { type: "observe_main", input_ids: [] });
  const ready = await peer.wait(100, (event) => event.type === "main_ready");
  assert.ok(ready.type === "main_ready" && ready.accepted_input_origins?.includes("carplay"), "The coordinator advertises the carplay origin");
  await peer.wait(100, (event) => event.type === "worker_idle");

  peer.send(3, { type: "main_input", origin: "carplay", input_id: CAR, input: "Is the invented deploy done", mode: "steer" }); await peer.done(3);
  const placed = peer.events(3).find((event) => event.type === "input_placed" && event.input_id === CAR);
  assert.ok(placed?.type === "input_placed");
  const accepted = await peer.wait(100, (event) => event.type === "input_accepted" && event.input_id === CAR && event.work?.type === "completed");
  const work = accepted.type === "input_accepted" ? accepted.work : undefined;
  assert.ok(work?.type === "completed");
  assert.notEqual(work.answer_entry_id, placed.entry_id, "The answer is its own entry, not the driver's message");
  const answer = await peer.wait(100, (event) => event.type === "answer" && event.entry_id === work.answer_entry_id);
  assert.ok(answer.type === "answer");
  assert.equal(answer.text, "The invented deploy finished.");
});
