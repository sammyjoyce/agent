import assert from "node:assert/strict";
import { createConnection } from "node:net";
import { readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { sessions } from "./fixtures/coordinator-native.js";
import { coordinatorWorld, delegate, effect } from "./fixtures/coordinator-world.js";

async function lines(path: string): Promise<string[]> {
  return readFile(path, "utf8").then((text) => text.split("\n").filter(Boolean), () => []);
}

test("a held store starts no task actor at restart, reconnect or chat delegation until backup release", { timeout: 120_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { cli, exchange, homes, online, script, start, until } = world;
  const effects = join(homes[1], "effects"), hold = join(homes[0], "state", "restore-hold.json");
  const socketReady = async () => { try { return (await stat(world.socket)).isSocket(); } catch { return false; } };
  const modelRequests = async (key: string) => (await lines(world.queue + ".requests")).filter((line) => (JSON.parse(line) as { key?: string }).key === key).length;

  await script("held-first-turn", [{ text: "Finished before the backup." }]);
  await script("held-dispatch", [delegate("held-first-turn", world.laptop), { text: "Delegated the first turn." }]);
  await cli(0, ["chat", "held-dispatch"]);
  const task = (await world.tasks()).find((saved) => saved.title === "held-first-turn");
  assert.ok(task?.worker.state === "bound" && task.worker.binding.host_id === world.laptop, "the main agent binds the task to the laptop");
  const binding = task.worker.binding, allocation = task.worker.allocation_id;
  assert.ok(sessions(join(homes[1], "rex.json")).some((session) => session.block_id === binding.block_id), "the laptop's Rex records the worker");
  await until(async () => (await world.tasks()).find((saved) => saved.id === task.id)?.pending.length === 0, "the first turn finishes");

  world.worker.child.kill("SIGINT"); await world.worker.exited; await online([world.coordinator]);
  await script("held-pending", [{ tool: "exec", args: { program: process.execPath, args: effect } }, { text: "Ran the saved input after release." },
    { tool: "exec", args: { program: process.execPath, args: effect } }, { text: "Ran the chat's input after release." }]);
  const admitted = await exchange({ type: "task_input", task_id: task.id, input_id: "held-saved-input", input: "held-pending", mode: "follow_up" });
  assert.ok(admitted.some((event) => event.type === "input_accepted"), "the coordinator admits input while the laptop is offline");
  world.server.child.kill("SIGINT"); await world.server.exited;

  await writeFile(hold, "{}");
  const heldServer = start(0, ["serve", "--local-only", "--no-sources"]);
  await until(socketReady, "the held coordinator binds its socket");
  const heldWorker = start(1, ["maintain"]); await online([world.coordinator, world.laptop]);
  await script("held-chat", [{ tool: "delegate_task", args: { task_id: task.id, input: "held-pending", mode: "follow_up" } }, { text: "Answered while held." }]);
  await cli(0, ["chat", "held-chat"]);
  await delay(1_000);
  assert.equal((await world.tasks()).find((saved) => saved.id === task.id)?.pending.length, 2, "a held store keeps both admitted inputs pending");
  assert.equal(await modelRequests("held-pending"), 0, "a held store starts no task turn after a restart, a reconnect or a chat delegation");
  assert.deepEqual(await lines(effects), [], "a held store sends no task effect to the laptop");
  const refusal = await new Promise<string>((resolve, reject) => {
    const socket = createConnection(world.socket); let text = "";
    socket.on("error", reject).on("data", (bytes: Buffer) => { text += bytes.toString("utf8"); }).on("end", () => resolve(text));
    socket.write(JSON.stringify({ type: "run_task", task_id: task.id, binding, allocation_id: allocation, cwd: homes[1], instructions: "",
      model: task.model, interactive: true }) + "\n");
  });
  assert.match(refusal, /held after a restore/, "a held store refuses the task's terminal");
  heldServer.child.kill("SIGINT"); assert.equal(await heldServer.exited, 0, heldServer.errors());
  heldWorker.child.kill("SIGINT"); await heldWorker.exited;

  const release = start(0, ["backup", "release"]);
  assert.equal(await release.exited, 0, release.errors());
  await assert.rejects(stat(hold), "backup release removes the hold");
  start(0, ["serve", "--local-only", "--no-sources"]);
  await until(socketReady, "the released coordinator binds its socket");
  start(1, ["maintain"]); await online([world.coordinator, world.laptop]);
  await until(async () => (await lines(effects)).length === 2, "a released store runs both admitted inputs on the laptop");
  await until(async () => (await world.tasks()).find((saved) => saved.id === task.id)?.pending.length === 0, "a released store drains the admitted inputs");
});
