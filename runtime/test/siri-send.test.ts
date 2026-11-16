import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
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

// The iPhone's Siri send writes an unconfirmed copy again under its own input ID. These runs use
// the real coordinator runtime, with only the model provider and the execution host synthetic.
const HOST = "11111111-1111-4111-8111-111111111111";
const FIRST = "5a1e0000-0000-4000-8000-000000000001";
const RACED = "5a1e0000-0000-4000-8000-000000000002";
const OFFLINE = "5a1e0000-0000-4000-8000-000000000003";

async function coordinator(t: TestContext, steps: Record<string, unknown[]>) {
  const directory = await mkdtemp(join(tmpdir(), "agent-siri-send-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify(steps));
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
  const closed = new Promise<number | null>((resolve) => child.once("close", resolve));
  const frames: RuntimeEvent[] = [], changes = new Set<() => void>();
  let errors = "";
  const held: { request: number; call: string }[] = [];
  child.stderr.setEncoding("utf8").on("data", (text: string) => { errors += text; });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const events = (id: number) => frames.filter((frame) => frame.id === id).map((frame) => frame.event);
  const wait = (id: number, predicate: (event: RuntimeEventKind) => boolean): Promise<RuntimeEventKind> => new Promise((resolve, reject) => {
    const timer = setTimeout(() => { changes.delete(check); reject(new Error(`Request ${id} stalled: ${errors}`)); }, 5_000);
    const check = () => { const event = events(id).find(predicate); if (event !== undefined) { clearTimeout(timer); changes.delete(check); resolve(event); } };
    changes.add(check); check();
  });
  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line); assert.ok(validEvent(frame)); frames.push(frame);
      for (const check of changes) check();
      if (frame.event.type !== "host_call") continue;
      let command = frame.event.command; while (command.type === "on_node") command = command.command;
      if (command.type === "exec") { held.push({ request: frame.id, call: frame.event.call_id }); continue; }
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
  const generations = async () => (await readFile(queue + ".requests", "utf8").catch(() => "")).trim().split("\n").filter(Boolean).length;
  return { send, events, wait, done, held, generations };
}

test("a Siri input written again under its own ID after an unheard outcome runs the agent once", { timeout: 20_000 }, async (t) => {
  const peer = await coordinator(t, { "Run Nightly deps now": [{ text: "Nightly deps ran." }] });
  peer.send(2, { type: "set_connected_nodes", host_ids: [HOST] }); await peer.done(2);
  peer.send(100, { type: "observe_main", input_ids: [] });
  const ready = await peer.wait(100, (event) => event.type === "main_ready");
  assert.ok(ready.type === "main_ready" && ready.accepted_input_origins?.includes("siri"), "The coordinator advertises the siri origin");
  await peer.wait(100, (event) => event.type === "worker_idle");

  peer.send(3, { type: "main_input", origin: "siri", input_id: FIRST, input: "Run Nightly deps now", mode: "steer" }); await peer.done(3);
  assert.ok(peer.events(3).some((event) => event.type === "input_placed" && event.input_id === FIRST));
  assert.equal(await peer.generations(), 1);

  peer.send(4, { type: "main_input", origin: "siri", input_id: FIRST, input: "Run Nightly deps now", mode: "steer" }); await peer.done(4);
  assert.ok(peer.events(4).some((event) => (event.type === "input_accepted" || event.type === "input_placed") && event.input_id === FIRST),
    "The second write is answered about the first copy");
  assert.equal(peer.events(4).some((event) => event.type === "failure"), false);
  assert.equal(await peer.generations(), 1, "The second write of the same ID starts no second generation");
  assert.equal(peer.events(100).filter((event) => event.type === "input_placed" && event.input_id === FIRST).length, 1);
});

test("a Siri input written again while its first write still runs joins that run", { timeout: 20_000 }, async (t) => {
  const peer = await coordinator(t, { "Rotate the Work logs": [{ tool: "exec", args: { program: "held", args: [] } }, { text: "Rotated." }] });
  peer.send(2, { type: "set_connected_nodes", host_ids: [HOST] }); await peer.done(2);
  peer.send(100, { type: "observe_main", input_ids: [] }); await peer.wait(100, (event) => event.type === "worker_idle");

  peer.send(3, { type: "main_input", origin: "siri", input_id: RACED, input: "Rotate the Work logs", mode: "steer" });
  await peer.wait(3, (event) => event.type === "host_call"
    && (event.command.type === "exec" || event.command.type === "on_node" && event.command.command.type === "exec"));
  peer.send(4, { type: "main_input", origin: "siri", input_id: RACED, input: "Rotate the Work logs", mode: "steer" }); await peer.done(4);
  assert.equal(peer.events(4).some((event) => event.type === "failure"), false);
  const call = peer.held[0]; assert.ok(call);
  peer.send(call.request, { type: "host_reply", call_id: call.call, result: { type: "process", exit_code: 0, stdout: "rotated", stderr: "", truncated: false } });
  await peer.done(3);
  assert.equal(peer.held.length, 1, "The tool ran once");
  assert.equal(await peer.generations(), 2, "One run: the tool call and its answer");
});

test("a Siri input while the execution host is offline is refused at once, admitted nowhere, and goes once when written again", { timeout: 20_000 }, async (t) => {
  const peer = await coordinator(t, { "Check the build": [{ text: "The build is green." }] });
  const started = Date.now();
  peer.send(3, { type: "main_input", origin: "siri", input_id: OFFLINE, input: "Check the build", mode: "steer" }); await peer.done(3);
  const answer = peer.events(3).find((event) => event.type === "failure");
  assert.ok(answer?.type === "failure", JSON.stringify(peer.events(3)));
  assert.equal(answer.message, "The coordinator execution host is offline");
  assert.equal(peer.events(3).some((event) => event.type === "input_accepted" || event.type === "input_placed"), false);
  assert.ok(Date.now() - started < 2_000, "The refusal arrives at once, not after the phone's deadline");

  peer.send(4, { type: "observe_main", input_ids: [OFFLINE] }); await peer.wait(4, (event) => event.type === "worker_idle");
  assert.equal(peer.events(4).some((event) => "input_id" in event && event.input_id === OFFLINE), false, "Nothing was admitted");
  assert.equal(await peer.generations(), 0);
  peer.send(4, { type: "detach_main" }); await peer.done(4);

  peer.send(5, { type: "set_connected_nodes", host_ids: [HOST] }); await peer.done(5);
  peer.send(6, { type: "main_input", origin: "siri", input_id: OFFLINE, input: "Check the build", mode: "steer" }); await peer.done(6);
  assert.ok(peer.events(6).some((event) => event.type === "input_placed" && event.input_id === OFFLINE));
  assert.equal(await peer.generations(), 1);
});
