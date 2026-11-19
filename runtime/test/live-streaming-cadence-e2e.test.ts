import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { performance } from "node:perf_hooks";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { DEFAULT_MODEL } from "../src/models.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { ModelQueue } from "./fixtures/coordinator-runtime.js";

const HOST = "11111111-1111-4111-8111-111111111111";
const CHUNKS = Array.from({ length: 40 }, (_, index) => `Invented sentence ${index} about the garden. `);
const CHUNK_INTERVAL_MS = 50;

test("a native main observer receives a streamed answer at Pi's partial interval", { timeout: 60_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-streaming-cadence-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify({ "stream-cadence": [{ stream: CHUNKS, interval_ms: CHUNK_INTERVAL_MS }] } satisfies ModelQueue));
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
  const closed = new Promise<number | null>((resolve) => child.once("close", resolve));
  const frames: RuntimeEvent[] = [], changes = new Set<() => void>(), deltas: { text: string; at: number }[] = [];
  let errors = "";
  child.stderr.setEncoding("utf8").on("data", (text: string) => { errors += text; });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const wait = (id: number, predicate: (event: RuntimeEventKind) => boolean): Promise<RuntimeEventKind> => new Promise((resolve) => {
    const check = () => { const frame = frames.find((frame) => frame.id === id && predicate(frame.event)); if (frame !== undefined) { changes.delete(check); resolve(frame.event); } };
    changes.add(check); check();
  });
  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame)); frames.push(frame);
      if (frame.id === 100 && frame.event.type === "text_delta") deltas.push({ text: frame.event.text, at: performance.now() });
      for (const check of changes) check();
      if (frame.event.type !== "host_call") continue;
      let command = frame.event.command; while (command.type === "on_node") command = command.command;
      const result: HostResult = command.type === "reload_guidance"
        ? { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] }
        : command.type === "project_guidance" ? { type: "project_guidance", snapshot: { text: "", sources: [] } }
        : { type: "failed", message: "Synthetic retrieval disabled" };
      send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result });
    }
  })(); void reader.catch(() => {});
  try {
    send(1, { type: "configure_coordinator", bootstrap: { node: { host_id: HOST, name: "fixture", home_directory: "/tmp", agent_program: "/fixture/agent",
      rex_server: null, coordinator: null, launch: { model: null, state_dir: null, runtime: null, config: null, instructions: null } },
      settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } });
    await wait(1, (event) => event.type === "done");
    send(20, { type: "set_connected_nodes", host_ids: [HOST] }); await wait(20, (event) => event.type === "done");
    send(100, { type: "observe_main", input_ids: [] }); await wait(100, (event) => event.type === "worker_idle");
    send(2, { type: "main_input", input_id: "22222222-2222-4222-8222-222222222222", input: "stream-cadence", mode: "steer" });
    await wait(2, (event) => event.type === "done");
    await wait(100, (event) => event.type === "answer");
    assert.equal(deltas.map((delta) => delta.text).join(""), CHUNKS.join(""), "The observer receives the whole answer once, in order");
    const gaps = deltas.slice(1).map((delta, index) => delta.at - (deltas[index]?.at ?? delta.at)).sort((a, b) => a - b);
    const median = gaps[Math.floor(gaps.length / 2)] ?? Infinity, longest = gaps.at(-1) ?? Infinity;
    t.diagnostic(`${deltas.length} text deltas over ${Math.round((deltas.at(-1)?.at ?? 0) - (deltas[0]?.at ?? 0))} ms, median gap ${Math.round(median)} ms, longest gap ${Math.round(longest)} ms`);
    // The model streams for two seconds. Pi commits a partial answer every
    // 100 ms and stores it within a second; the observer follows the former.
    assert.ok(deltas.length >= 8, `The answer arrives as it streams, not once per stored commit: ${deltas.length} deltas`);
    assert.ok(longest < 700, `No streamed partial waits for storage: the longest gap was ${Math.round(longest)} ms`);
  } finally {
    child.stdin.end(); child.kill(); await closed; await reader.catch(() => {});
    if (errors.length > 0) t.diagnostic(errors);
    await rm(directory, { recursive: true, force: true });
  }
});
