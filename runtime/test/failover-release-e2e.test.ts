import assert from "node:assert/strict";
import { readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { failoverWorld, type FailoverWorld } from "./fixtures/failover-world.js";

const exists = (path: string) => stat(path).then(() => true, () => false);

function groupAlive(group: number): boolean {
  try { process.kill(-group, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

const HELD_WRITE = "const fs=require('node:fs');const [started,latch]=process.argv.slice(1);fs.writeFileSync(started,String(process.pid));"
  + "(async()=>{while(!fs.existsSync(latch))await new Promise(r=>setTimeout(r,20));fs.writeFileSync(started+'.finished','written')})()";

/** One local command on the owner's own machine that has started and makes its write only once the latch file exists. */
interface LocalEffect {
  /** The process group the command leads. */
  readonly group: number;
  readonly latch: string;
  /** Whether the command made its write. */
  finished(): Promise<boolean>;
}

/** An enrolled owner with a standby, whose main conversation is running a local command that waits on a latch. */
async function ownerWithLocalEffect(world: FailoverWorld, name: string): Promise<LocalEffect> {
  const { owner } = world, started = join(world.directory, `${name}.started`), latch = join(world.directory, `${name}.latch`);
  await world.enroll();
  await world.serve(owner);
  await world.join();
  const held: ModelStep = { tool: "exec", args: { host: owner.nodeId, program: process.execPath, timeout_seconds: 120, args: ["-e", HELD_WRITE, started, latch] } };
  await world.script(`fixture-${name}`, [held, { text: "The local command ended." }]);
  world.sending(owner, `fixture-${name}`);
  await world.until(() => exists(started), "The local command must start on the owner's machine");
  return { group: Number(await readFile(started, "utf8")), latch, finished: () => exists(started + ".finished") };
}

/** Seals the log for the standby, which gets no stop evidence from the dead owner. Returns the sealed state. */
async function sealed(world: FailoverWorld) {
  const waited = world.promoting({ replaceEpoch: 2, wait: 0 });
  assert.notEqual(await waited.exited, 0);
  assert.match(waited.errors(), /gave no stop evidence/);
  const state = (await world.record())?.state;
  assert.equal(state?.kind, "sealed");
  return state;
}

test("lock_held is posted only when no process of the old owner is alive on its host", { timeout: 240_000 }, async (t) => {
  await t.test("a local command that outlives its killed supervisor is stopped by release before lock_held is posted, and never makes its write", async (t) => {
    const world = await failoverWorld(t), effect = await ownerWithLocalEffect(world, "survivor");
    await world.crash(world.owner);
    assert.ok(groupAlive(effect.group), "the local command outlives its supervisor and its Pi child");
    await sealed(world);

    assert.equal((await world.release()).evidence, "lock_held");
    assert.equal(groupAlive(effect.group), false, "release stopped the recorded process group before it posted");
    await writeFile(effect.latch, "");
    await delay(300);
    assert.equal(await effect.finished(), false, "the command never made its write");
    assert.deepEqual((await world.promote({ replaceEpoch: 2 })).evidence, { kind: "lock_held" });
  });

  await t.test("a survivor that release may not stop: release names it and posts nothing, the restarted sealed holder exits 75 and posts nothing, and release succeeds after it ends", async (t) => {
    const world = await failoverWorld(t), { owner } = world, effect = await ownerWithLocalEffect(world, "unverified");
    await world.crash(owner);
    const state = await sealed(world);
    // The record no longer matches the process that leads the group, as after the group's id was reused.
    await writeFile(join(owner.state, "effects", String(effect.group)), "1");

    const refused = world.launch(owner, ["failover", "release"], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), new RegExp(`process group ${effect.group}\\b`));
    assert.match(refused.errors(), /effects\.lock/);
    assert.match(refused.errors(), /failover release/);
    assert.match(refused.errors(), /--old-owner-stopped/);
    assert.ok(groupAlive(effect.group), "release does not signal a group whose leader is not the recorded process");
    assert.deepEqual((await world.record())?.state, state, "a refused release posts no evidence");

    const restarted = world.starting(owner);
    assert.equal(await restarted.exited, OWNER_FENCED_EXIT, restarted.errors().slice(-2000));
    assert.match(restarted.errors(), new RegExp(`process group ${effect.group}\\b`));
    assert.deepEqual((await world.record())?.state, state, "the restarted sealed holder posts no evidence");

    await writeFile(effect.latch, "");
    await world.until(async () => !groupAlive(effect.group), "The local command must end by itself");
    assert.equal((await world.release()).evidence, "lock_held");
  });
});
