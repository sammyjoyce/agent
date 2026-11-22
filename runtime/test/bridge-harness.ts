import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import type { TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { validEvent } from "../src/protocol.js";
import { binding } from "./delegation.js";
import type { ModelQueue } from "./fixtures/coordinator-runtime.js";

const FIXTURE_HOST_ID = "11111111-1111-4111-8111-111111111111";

export async function openBridgeHarness(t: TestContext, queue: ModelQueue) {
  const directory = await mkdtemp(join(tmpdir(), "agent-bridge-"));
  await chmod(directory, 0o700);
  const queuePath = join(directory, "responses.json");
  await writeFile(queuePath, JSON.stringify(queue));

  const child = spawn(
    process.execPath,
    ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queuePath } },
  );
  const closed = new Promise<void>((resolve) => child.once("close", () => resolve()));
  const lines = createInterface({ input: child.stdout });
  const frames: RuntimeEvent[] = [];
  const listeners = new Set<() => void>();
  let errors = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });

  const unwrap = (command: HostCommand): HostCommand => command.type === "on_node" ? unwrap(command.command) : command;
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const reply = (id: number, call_id: string, result: HostResult) => send(id, { type: "host_reply", call_id, result });

  lines.on("line", (line) => {
    const frame: unknown = JSON.parse(line);
    assert.ok(validEvent(frame), "Invalid bridge event: " + line);
    frames.push(frame);
    if (frame.event.type === "host_call") {
      const cmd = unwrap(frame.event.command);
      if (cmd.type === "reload_guidance") {
        reply(frame.id, frame.event.call_id, {
          type: "shared_guidance",
          global: { text: "Brief fixture instructions.", sources: [] },
          workflow_policy: "",
          context_repositories: [],
          context_sources: [],
        });
      } else if (cmd.type === "project_guidance") {
        reply(frame.id, frame.event.call_id, { type: "project_guidance", snapshot: { text: "", sources: [] } });
      } else if (cmd.type === "embed") {
        reply(frame.id, frame.event.call_id, { type: "failed", message: "No embeddings in fixture" });
      } else if (cmd.type === "spawn_workspace_worker") {
        reply(frame.id, frame.event.call_id, { type: "spawned", binding: { ...binding, host_id: FIXTURE_HOST_ID } });
      } else if (cmd.type === "resume_worker") {
        reply(frame.id, frame.event.call_id, { type: "spawned", binding: cmd.binding });
      } else if (cmd.type === "inspect_worker") {
        reply(frame.id, frame.event.call_id, { type: "worker_presence", presence: { state: "present", running: true } });
      }
    }
    for (const notify of listeners) notify();
  });

  const waitFor = (describe: string, predicate: () => boolean): Promise<void> => new Promise((resolve, reject) => {
    const timer = setInterval(check, 20);
    function cleanup(): void {
      clearInterval(timer);
      listeners.delete(check);
      t.signal.removeEventListener("abort", stopped);
      child.off("close", stopped);
    }
    function stopped(): void { cleanup(); reject(new Error(`Bridge never reached ${describe}: ${errors}`)); }
    function check(): void { if (!predicate()) return; cleanup(); resolve(); }
    listeners.add(check); t.signal.addEventListener("abort", stopped, { once: true }); child.once("close", stopped);
    if (t.signal.aborted || child.exitCode !== null || child.signalCode !== null) stopped(); else check();
  });

  const collect = async (id: number): Promise<RuntimeEventKind[]> => {
    await waitFor(`done for ${id}`, () => frames.some((frame) => frame.id === id && frame.event.type === "done"));
    return frames.filter((frame) => frame.id === id).map((frame) => frame.event);
  };

  const node = {
    host_id: FIXTURE_HOST_ID,
    name: "fixture",
    rex_server: null,
    coordinator: null,
    agent_program: "/example/agent",
    home_directory: directory,
    launch: { state_dir: null, runtime: null, config: null, instructions: null, model: DEFAULT_MODEL },
  };
  send(1, {
    type: "configure_coordinator",
    bootstrap: {
      node,
      settings: { model: DEFAULT_MODEL, instructions: "Brief answers.", context_repositories: [], sources: [] },
    },
  });
  await collect(1);
  send(2, { type: "set_connected_nodes", host_ids: [node.host_id] });
  await collect(2);

  return {
    directory,
    node,
    frames,
    send,
    waitFor,
    collect,
    async close() {
      lines.close();
      child.stdin.end();
      child.kill("SIGKILL");
      await closed;
      await rm(directory, { recursive: true, force: true });
    },
  };
}
