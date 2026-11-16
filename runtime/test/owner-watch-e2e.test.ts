import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { FailoverReport } from "../src/generated/FailoverReport.js";
import { coordinatorWorld, held } from "./fixtures/coordinator-world.js";
import { answer, candidate, claimed, enableFailover, floorFile, helperRuns, holder, record } from "./fixtures/owner-floor.js";

const coordinatorId = "66666666-6666-4666-8666-666666666666";
const lines = (path: string) => readFile(path, "utf8").then((text) => text.split("\n").filter(Boolean), () => []);
const active = (epoch: number) => record({ kind: "active", epoch, holder, head: 0 });

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

test("a watching worker ends the link of an owner the authority replaced, and nothing else ends it", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t, async (homes) => {
    await writeFile(join(homes[0], "state", "coordinator-id"), coordinatorId);
    await enableFailover(homes[0], { holder });
    await answer(homes[0], { claim: claimed(5) });
    await enableFailover(homes[1], { watchSeconds: 1 });
    await answer(homes[1], { record: active(5) });
  });
  const { directory, coordinator: desktop, laptop, homes, start, until, online, script, cli } = world;
  const floor = floorFile(homes[1], coordinatorId), action = join(directory, "watched-action");
  const reads = async (answer: FailoverReport | "fail") =>
    (await helperRuns(homes[1])).filter((run) => JSON.stringify(run.answer) === JSON.stringify(answer)).length;
  async function unchanged(answer: FailoverReport | "fail", pid: number): Promise<void> {
    const before = await reads(answer);
    await until(async () => await reads(answer) >= before + 2, "The watch must read the record twice more");
    assert.equal(await readFile(floor, "utf8"), "5\n", `${JSON.stringify(answer)} must leave the floor at epoch 5`);
    assert.ok(alive(pid), `${JSON.stringify(answer)} must leave the held effect running`);
    const nodes = (await cli(0, ["nodes"])).find((event) => event.type === "environment");
    assert.ok(nodes?.type === "environment" && nodes.online_host_ids.includes(laptop), `${JSON.stringify(answer)} must keep the link`);
  }

  await until(async () => await readFile(floor, "utf8").catch(() => "") === "5\n", "Serving epoch 5 sets the floor");
  await until(async () => await reads(active(5)) >= 1, "The watch must read the owner record");
  const [first] = await helperRuns(homes[1]);
  assert.deepEqual(first?.request, { op: "record" });
  assert.deepEqual(first?.session, { url: "https://authority.example.invalid/coordinators/fixture",
    token_file: join(homes[1], "failover-token"), coordinator_id: coordinatorId }, "A watcher reads the linked coordinator's record without a holder");

  const step = held(action);
  assert.ok("tool" in step);
  await script("fixture-watch-held", [{ tool: "exec", args: { ...step.args, host: laptop } }, { text: "The held effect ended." }]);
  start(0, ["chat", "fixture-watch-held"], "");
  await until(async () => (await lines(action + ".started")).length === 1, "The held effect must start on the laptop");
  const [started] = await lines(action + ".started");
  const pid = Number(started?.split(" ")[0]);

  await unchanged(active(5), pid);
  await answer(homes[1], { record: "fail" });
  await unchanged("fail", pid);
  await answer(homes[1], { record: record({ kind: "sealed", epoch: 6, holder, candidate, head: 0 }) });
  await unchanged(record({ kind: "sealed", epoch: 6, holder, candidate, head: 0 }), pid);
  await answer(homes[1], { record: record({ kind: "vacant", epoch: 6, candidate, evidence: { kind: "released" }, head: 0 }) });
  await unchanged(record({ kind: "vacant", epoch: 6, candidate, evidence: { kind: "released" }, head: 0 }), pid);

  await answer(homes[1], { record: active(6) });
  await until(async () => !alive(pid), "A record naming epoch 6 must end the epoch 5 link and cancel its effect");
  assert.equal(await readFile(floor, "utf8"), "6\n");
  assert.equal(await reads(active(6)), 1, "The first read of the new owner's record must end the link");
  await until(async () => world.worker.errors().includes(`Refused coordinator ${coordinatorId} at owner epoch 5: this host has served it at epoch 6`),
    "The worker must then refuse the replaced owner at registration");
  await online([desktop]);
  await writeFile(action + ".release", "A cancelled effect must stay cancelled.");
  await script("fixture-watch-after", [{ tool: "exec", args: { host: laptop, program: process.execPath, args: ["-e",
    "require('node:fs').appendFileSync(process.env.HOME+'/effects','epoch 5\\n')"] } }, { text: "The replaced owner tried again." }]);
  await cli(0, ["chat", "fixture-watch-after"]);
  assert.deepEqual(await lines(join(homes[1], "effects")), [], "The replaced owner must run nothing on the laptop");
  assert.deepEqual(await lines(action + ".finished"), [], "The cancelled effect must never finish");
  assert.equal(await reads(active(6)), 1, "A refused link has no watch");
});
