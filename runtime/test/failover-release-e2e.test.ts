import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { pidsMatching } from "./fixtures/coordinator-world.js";
import type { PromotedReceipt } from "./fixtures/failover-hosts.js";
import { failoverWorld, type FailoverWorld } from "./fixtures/failover-world.js";

const exists = (path: string) => stat(path).then(() => true, () => false);

function groupAlive(group: number): boolean {
  try { process.kill(-group, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

const HELD_WRITE = "const fs=require('node:fs');const [started,latch]=process.argv.slice(1);fs.writeFileSync(started,String(process.pid));"
  + "(async()=>{while(!fs.existsSync(latch))await new Promise(r=>setTimeout(r,20));fs.writeFileSync(started+'.finished','written')})()";

/**
 * A local command whose output pipe stays open after its process group is killed, because a process it started left
 * the group and holds the pipe for `seconds`. The coordinator that cancels it waits for that output before its drain ends.
 */
const SLOW_DRAIN = "const fs=require('node:fs'),cp=require('node:child_process');const [started,seconds]=process.argv.slice(1);"
  + "const holder=cp.spawn(process.execPath,['-e','setTimeout(()=>{},'+seconds+'*1000)'],{detached:true,stdio:['ignore','inherit','inherit']});"
  + "fs.writeFileSync(started,String(holder.pid));setInterval(()=>{},1000)";

const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

/** A shell command that leaves one process behind in a process group of its own. That process keeps every file the command inherited. */
const LEFT_BEHIND = 'set -m; sleep 600 </dev/null >/dev/null 2>&1 & echo $! > "$1"';

/** A process group that this test started and whose leader has ended, as an id that another program's group took after the recorded process ended. */
async function leaderlessGroup(t: TestContext, directory: string): Promise<{ readonly group: number; readonly member: number }> {
  const started = join(directory, `leaderless-${randomUUID()}`);
  const leader = spawn(process.execPath, ["-e", "const child=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'});"
    + "require('node:fs').writeFileSync(process.argv[1],String(child.pid));child.unref()", started], { detached: true, stdio: "ignore" });
  assert.ok(leader.pid !== undefined);
  await once(leader, "exit");
  const member = Number(await readFile(started, "utf8"));
  t.after(() => { try { process.kill(member, "SIGKILL"); } catch { /* It already ended. */ } });
  return { group: leader.pid, member };
}

/** One local command on the owner's own machine that has started and makes its write only once the latch file exists. */
interface LocalEffect {
  readonly group: number;
  readonly latch: string;
  finished(): Promise<boolean>;
}

async function ownerWithLocalEffect(world: FailoverWorld, name: string): Promise<LocalEffect> {
  const { owner } = world, started = join(world.directory, `${name}.started`), latch = join(world.directory, `${name}.latch`);
  await world.enroll();
  await world.serve(owner);
  await world.join();
  const held: ModelStep = { tool: "exec", args: { host: owner.nodeId, program: process.execPath, timeout_seconds: 120, args: ["-e", HELD_WRITE, started, latch] } };
  await world.script(`fixture-${name}`, [held, { text: "The local command ended." }]);
  world.sending(owner, `fixture-${name}`);
  await world.until(() => exists(started), "The local command must start on the owner's machine");
  const group = Number(await readFile(started, "utf8"));
  // The command can write its file before the coordinator has recorded the group it leads.
  await world.until(async () => (await readFile(join(owner.state, "effects", String(group)), "utf8").catch(() => "")) !== "", "The coordinator must record the command's process group");
  return { group, latch, finished: () => exists(started + ".finished") };
}

/** Seals the log for the standby, which gets no stop evidence from the dead owner. Returns the sealed state. */
async function sealWithoutEvidence(world: FailoverWorld) {
  const waited = world.promoting({ replaceEpoch: 2, wait: 0 });
  assert.notEqual(await waited.exited, 0);
  assert.match(waited.errors(), /gave no stop evidence/);
  const state = (await world.record())?.state;
  assert.equal(state?.kind, "sealed");
  return state;
}

const recordReusedGroup = (state: string, group: number) => writeFile(join(state, "effects", String(group)), "1");

test("lock_held is posted only when no process of the old owner is alive on its host", { timeout: 240_000 }, async (t) => {
  await t.test("a local command that outlives its killed supervisor is stopped by release before lock_held is posted, and never makes its write", async (t) => {
    const world = await failoverWorld(t), effect = await ownerWithLocalEffect(world, "survivor");
    await world.crash(world.owner);
    assert.ok(groupAlive(effect.group), "the local command outlives its supervisor and its Pi child");
    await sealWithoutEvidence(world);

    assert.equal((await world.release()).evidence, "lock_held");
    assert.equal(groupAlive(effect.group), false, "release stopped the recorded process group before it posted");
    await writeFile(effect.latch, "");
    await delay(300);
    assert.equal(await effect.finished(), false, "the command never made its write");
    assert.deepEqual((await world.promote({ replaceEpoch: 2 })).evidence, { kind: "lock_held" });
  });

  await t.test("a release started while the old owner still drains a local command after its Pi child exited is refused by the writer lock", async (t) => {
    const world = await failoverWorld(t), { owner } = world, started = join(world.directory, "slow-drain.started");
    await world.enroll();
    const serving = await world.serve(owner);
    await world.join();
    await world.script("fixture-slow-drain", [{ tool: "exec", args: { host: owner.nodeId, program: process.execPath, timeout_seconds: 120, args: ["-e", SLOW_DRAIN, started, "8"] } },
      { text: "The local command ended." }]);
    world.sending(owner, "fixture-slow-drain");
    await world.until(() => exists(started), "The local command must start on the owner's machine");
    const holder = Number(await readFile(started, "utf8"));
    t.after(() => { try { process.kill(holder, "SIGKILL"); } catch { /* It already ended. */ } });
    const supervisor = serving.child.pid;
    const children = (await pidsMatching(owner.state)).filter((pid) => pid !== supervisor);
    assert.ok(children.length >= 1, "the coordinator has a Pi child");

    const promoting = world.promoting({ replaceEpoch: 2, wait: 60 });
    await world.until(async () => !children.some(alive), "The fenced Pi child must exit");
    assert.equal(serving.child.exitCode, null, "the supervisor is still draining the local command");
    const refused = world.launch(owner, ["failover", "release"], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), /Another agent process owns this state directory/);

    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.equal(await promoting.exited, 0, promoting.errors());
    assert.deepEqual((JSON.parse(promoting.output()) as { evidence: unknown }).evidence, { kind: "released" }, "the old owner posted its own evidence after its drain");
  });

  await t.test("a survivor that release may not stop: release names it and posts nothing, the restarted sealed holder exits 75 and posts nothing, and release succeeds after it ends", async (t) => {
    const world = await failoverWorld(t), { owner } = world, effect = await ownerWithLocalEffect(world, "unverified");
    await world.crash(owner);
    const state = await sealWithoutEvidence(world);
    await recordReusedGroup(owner.state, effect.group);

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

  await t.test("a record whose id now names another program's process group with no leader: release stops the old owner's command, never signals that group, and posts nothing while it lives", async (t) => {
    const world = await failoverWorld(t), { owner } = world, effect = await ownerWithLocalEffect(world, "stale-record");
    await world.crash(owner);
    const state = await sealWithoutEvidence(world);
    const unrelated = await leaderlessGroup(t, world.directory);
    assert.ok(groupAlive(unrelated.group) && !alive(unrelated.group), "the group is alive and its leader is gone");
    await recordReusedGroup(owner.state, unrelated.group);

    const refused = world.launch(owner, ["failover", "release"], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), new RegExp(`process group ${unrelated.group} is alive and was not signalled`));
    assert.match(refused.errors(), /--old-owner-stopped/);
    assert.ok(alive(unrelated.member), "release does not signal a group that no recorded process leads");
    assert.equal(groupAlive(effect.group), false, "release stopped the old owner's own command");
    assert.deepEqual((await world.record())?.state, state, "a refused release posts no evidence");

    process.kill(unrelated.member, "SIGKILL");
    await world.until(async () => !groupAlive(unrelated.group), "The other program's group must end");
    assert.equal((await world.release()).evidence, "lock_held");
  });

  await t.test("an old owner that takes ownership back stops the local command its killed coordinator left running before lock_held is posted, and is refused while a survivor it may not stop lives", async (t) => {
    const world = await failoverWorld(t), { owner } = world, effect = await ownerWithLocalEffect(world, "take-back");
    await world.crash(owner);
    const state = await sealWithoutEvidence(world);
    const takeBack = ["promote", "--replace-epoch", "2", "--wait", "0"];
    const record = join(owner.state, "effects", String(effect.group)), recorded = await readFile(record, "utf8");
    await recordReusedGroup(owner.state, effect.group);
    const refused = world.launch(owner, ["failover", ...takeBack], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), new RegExp(`process group ${effect.group}\\b`));
    assert.ok(groupAlive(effect.group), "the take-back does not signal a group whose leader is not the recorded process");
    assert.deepEqual((await world.record())?.state, { ...state, candidate: owner.holder }, "the refused take-back posted no evidence");

    await writeFile(record, recorded);
    const back = await world.receipt<PromotedReceipt>(owner, ...takeBack);
    assert.deepEqual([back.holder, back.evidence], [owner.holder, { kind: "lock_held" }]);
    assert.equal(groupAlive(effect.group), false, "the take-back stopped the recorded process group before it posted");
    await writeFile(effect.latch, "");
    await delay(300);
    assert.equal(await effect.finished(), false, "the command never made its write");
  });

  await t.test("a process that a finished local command left behind holds effects.lock: the fenced owner posts no released, release names the lock and posts nothing, and lock_held follows once the process ends", async (t) => {
    const world = await failoverWorld(t), { owner } = world, started = join(world.directory, "left-behind.started");
    await world.enroll();
    const serving = await world.serve(owner);
    await world.join();
    await world.script("fixture-left-behind", [{ tool: "exec", args: { host: owner.nodeId, program: "sh", timeout_seconds: 120, args: ["-c", LEFT_BEHIND, "sh", started] } },
      { text: "The local command ended." }]);
    await world.send(owner, "fixture-left-behind");
    const survivor = Number((await readFile(started, "utf8")).trim());
    t.after(() => { try { process.kill(survivor, "SIGKILL"); } catch { /* It already ended. */ } });
    assert.ok(alive(survivor), "the command ended and left a process behind");

    const state = await sealWithoutEvidence(world);
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.match(serving.errors(), /Did not tell the failover authority that this coordinator stopped/);
    assert.match(serving.errors(), /A process still holds .*effects\.lock/);
    assert.deepEqual((await world.record())?.state, state, "the fenced owner posted no evidence while a process it started is alive");

    const refused = world.launch(owner, ["failover", "release"], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), /A process still holds .*effects\.lock/);
    assert.match(refused.errors(), /lsof/);
    assert.ok(alive(survivor), "release does not signal a process that no record names");
    assert.deepEqual((await world.record())?.state, state, "a refused release posts no evidence");

    process.kill(survivor, "SIGKILL");
    await world.until(async () => !alive(survivor), "The process must end");
    assert.equal((await world.release()).evidence, "lock_held");
  });
});
