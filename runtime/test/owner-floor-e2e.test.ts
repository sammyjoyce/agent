import assert from "node:assert/strict";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { dirname, join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { coordinatorWorld, type OwnedProcess } from "./fixtures/coordinator-world.js";
import { answer, claimed, enableFailover, floorFile, holder } from "./fixtures/owner-floor.js";

const runtime = fileURLToPath(new URL("./fixtures/coordinator-runtime-local-pi.js", import.meta.url));
const exists = (path: string) => stat(path).then(() => true, () => false);
const lines = (path: string) => readFile(path, "utf8").then((text) => text.split("\n").filter(Boolean), () => []);

/** A coordinator from before owner floors: its ready frame names neither its identity nor an epoch. */
async function olderCoordinator(t: TestContext, path: string, target: string): Promise<void> {
  const server = createServer((client) => {
    const upstream = createConnection(target);
    let pending = "";
    client.pipe(upstream);
    upstream.setEncoding("utf8").on("data", (text: string) => {
      pending += text;
      const frames = pending.split("\n");
      pending = frames.pop() ?? "";
      for (const frame of frames) {
        const event = JSON.parse(frame) as Record<string, unknown>;
        if (event.type === "worker_ready") { delete event.coordinator_id; delete event.owner_epoch; }
        client.write(JSON.stringify(event) + "\n");
      }
    }).on("end", () => client.end());
    upstream.on("error", () => client.destroy());
    client.on("error", () => upstream.destroy()).on("close", () => upstream.destroy());
  });
  await new Promise<void>((resolve) => server.listen(path, resolve));
  t.after(() => new Promise<void>((resolve) => server.close(() => resolve())));
}

// The scripted helper grants the epochs, because this test needs a replaced owner that keeps serving beside its
// successor. An owner the real authority replaced ends itself at its next owner check.
test("a worker host serves no coordinator below the highest owner epoch it has served", { timeout: 120_000 }, async (t) => {
  const world = await coordinatorWorld(t, undefined, runtime);
  const { directory, coordinator: desktop, laptop, homes, socket, start, until, online, script, cli } = world;
  const id = await readFile(join(homes[0], "state", "coordinator-id"), "utf8");
  const floor = floorFile(homes[1], id), ledger = join(homes[1], "effects"), older = join(directory, "older.sock");
  const localConfig = await readFile(join(homes[0], "agent.toml"), "utf8");
  await olderCoordinator(t, older, socket);
  let server = world.server;

  const listening = (path: string) => until(async () => { try { return (await stat(path)).isSocket(); } catch { return false; } },
    "The coordinator must bind " + path);
  async function restart(): Promise<void> {
    server.child.kill("SIGINT"); await server.exited;
    server = start(0, ["serve", "--local-only", "--no-sources"]);
    await listening(socket);
  }
  async function stop(daemon: OwnedProcess): Promise<void> { daemon.child.kill("SIGINT"); await daemon.exited; }
  async function daemon(name: string, dial = socket): Promise<OwnedProcess> {
    const state = join(directory, name, "state");
    await mkdir(state, { recursive: true, mode: 0o700 });
    return start(1, ["--state-dir", state, "--config", join(homes[1], "agent.toml"), "--runtime", runtime,
      "--instructions", join(homes[1], "AGENTS.md"), "maintain"], undefined, { AGENT_TEST_COORDINATOR_SOCKET: dial }, true);
  }
  const refused = (daemon: OwnedProcess, notice: string) =>
    until(async () => daemon.errors().includes(notice), "The worker must refuse with: " + notice, () => daemon.errors().slice(-2000));
  async function effect(key: string): Promise<void> {
    await script(key, [{ tool: "exec", args: { host: laptop, program: process.execPath, args: ["-e",
      "const fs=require('node:fs');let floor=null;try{floor=fs.readFileSync(process.argv[1],'utf8')}catch{}" +
      "fs.appendFileSync(process.env.HOME+'/effects',JSON.stringify({host:process.env.AGENT_TEST_NODE_ID,floor})+'\\n')", floor] } },
    { text: `Finished ${key}.` }]);
    await cli(0, ["chat", key]);
  }

  const connected = (daemon: OwnedProcess) => until(async () => daemon.errors().includes("Worker connected as laptop."),
    "The worker must be served", () => daemon.errors().slice(-2000));
  await connected(world.worker);
  assert.equal(await exists(dirname(floor)), false, "A coordinator without failover offers no epoch and leaves no floor");
  await stop(world.worker);
  const unidentified = await daemon("older-first", older);
  await connected(unidentified);
  assert.equal(await exists(dirname(floor)), false, "A host without floors serves an older coordinator and writes none");
  await stop(unidentified);

  await enableFailover(homes[0], { holder });
  await answer(homes[0], { claim: claimed(5) });
  await restart();
  const worker = start(1, ["maintain"]);
  await online([desktop, laptop]);
  await until(async () => await readFile(floor, "utf8").catch(() => "") === "5\n", "Serving epoch 5 sets the floor");
  await effect("fixture-floor-first");
  assert.deepEqual((await lines(ledger)).map((line) => JSON.parse(line)), [{ host: laptop, floor: "5\n" }],
    "The effect must run once and find epoch 5 already on disk");

  const promoted = join(directory, "promoted", "state");
  await mkdir(promoted, { recursive: true, mode: 0o700 });
  await writeFile(join(promoted, "coordinator-id"), id);
  await answer(homes[0], { claim: claimed(6) });
  start(0, ["--state-dir", promoted, "--config", join(homes[0], "agent.toml"), "--runtime", runtime,
    "--instructions", join(homes[0], "AGENTS.md"), "serve", "--local-only", "--no-sources"], undefined, {}, true);
  await listening(join(promoted, "agent.sock"));
  await daemon("promoted-worker", join(promoted, "agent.sock"));
  await until(async () => await readFile(floor, "utf8").catch(() => "") === "6\n", "A second daemon serving epoch 6 raises the shared floor");
  const raised = await readFile(floor);
  assert.equal(worker.errors().includes("Refused"), false, worker.errors());

  const below = `Refused coordinator ${id} at owner epoch 5: this host has served it at epoch 6`;
  await effect("fixture-floor-stale");
  await refused(worker, below);
  const requests = await readFile(world.queue + ".requests", "utf8");
  assert.ok(requests.includes(below + ", so a newer owner replaced it; no command was started"),
    "The stale owner's host call must reach the worker and be refused before it starts a process");
  await until(async () => worker.errors().split(below).length > 2, "The worker must also refuse the stale owner at registration");

  await stop(worker);
  await refused(start(1, ["maintain"]), below);
  await refused(await daemon("fresh-state"), below);
  await refused(await daemon("older-floored", older),
    `Refused a coordinator that names no identity, as versions before owner floors do: this host has served coordinator ${id} at epoch 6`);

  await writeFile(join(homes[0], "agent.toml"), localConfig);
  await restart();
  await refused(await daemon("unfenced"), `Refused coordinator ${id} without an owner epoch: this host has served it at epoch 6`);

  assert.deepEqual(await readFile(floor), raised, "No refusal may change the floor file");
  assert.equal((await lines(ledger)).length, 1, "No effect may run for an owner below the floor");
});
