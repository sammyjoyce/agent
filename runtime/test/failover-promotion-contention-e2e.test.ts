import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { crash, exists, HOLDERS, replicatedPair, sealedFor, until, World, type Host, type JoinedReceipt, type PromotedReceipt, type ReleasedReceipt } from "./fixtures/failover-hosts.js";
import { tables } from "./fixtures/failover-state.js";

const [OWNER, STANDBY, THIRD] = HOLDERS;
const STATEMENT = "Invented: the old host is powered off";
const held = (state: string) => exists(join(state, "restore-hold.json"));

async function joinedStandby(world: World, coordinator: string, holder: string): Promise<Host> {
  const host = await world.host(coordinator, holder);
  await host.receipt<JoinedReceipt>("join", coordinator);
  return host;
}

test("a promotion that others contend for leaves one owner", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);

  await t.test("two standbys that promote at once leave one owner at one new epoch", async () => {
    const { coordinator, owner, standby, epoch, head } = await replicatedPair(world);
    const other = await joinedStandby(world, coordinator, THIRD);
    const promote = (host: Host) => host.failover("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    const runs = await Promise.all([promote(standby), promote(other)]);
    const state = await owner.authorityState();
    assert.ok(state.kind === "active" && state.epoch === epoch + 1 && state.head === head, JSON.stringify(state));
    const winner = [standby, other].find((host) => host.holder === state.holder), loser = [standby, other].find((host) => host.holder !== state.holder);
    assert.ok(winner && loser, `one of the two standbys owns the coordinator: ${state.holder}`);
    const won = runs.filter((run) => run.code === 0);
    assert.ok(won.length >= 1 && won.every((run) => (JSON.parse(run.stdout) as PromotedReceipt).holder === winner.holder),
      `no promotion reports an owner the authority does not hold: ${runs.map((run) => run.stderr).join(" | ")}`);
    assert.equal(await held(winner.state), false);
    assert.equal(await held(loser.state), true, "the loser stays a held standby");

    const rerun = await promote(loser);
    assert.notEqual(rerun.code, 0);
    assert.match(rerun.stderr, new RegExp(`holder ${winner.holder} owns it at epoch ${epoch + 1}`));
    assert.deepEqual(await owner.authorityState(), state, "the loser's rerun changes nothing");
  });

  await t.test("a second standby completes a promotion whose candidate was lost after the seal", async () => {
    const { coordinator, owner, standby, epoch, head } = await replicatedPair(world);
    const other = await joinedStandby(world, coordinator, THIRD);
    assert.notEqual((await standby.failover("promote", "--replace-epoch", String(epoch), "--wait", "0")).code, 0);
    const promotion = other.start("promote", "--replace-epoch", String(epoch));
    await until(() => sealedFor(owner, THIRD), "the second standby takes the stalled promotion over");
    await owner.receipt<ReleasedReceipt>("release");
    const completed = await promotion.done;
    assert.equal(completed.code, 0, completed.stderr);
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: THIRD, head });
    assert.deepEqual(tables(other.state), tables(owner.state));
  });

  await t.test("a second standby completes a promotion whose candidate was lost after the evidence", async () => {
    const { coordinator, owner, standby, epoch, head } = await replicatedPair(world);
    const other = await joinedStandby(world, coordinator, THIRD);
    assert.notEqual((await standby.failover("promote", "--replace-epoch", String(epoch), "--wait", "0")).code, 0);
    await owner.receipt<ReleasedReceipt>("release");
    const promoted = await other.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--wait", "0");
    assert.deepEqual(promoted.evidence, { kind: "lock_held" }, "the evidence the first candidate waited for still stands");
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: THIRD, head });
    assert.deepEqual(tables(other.state), tables(owner.state));
  });

  await t.test("the old owner takes ownership back from a candidate that was lost", async () => {
    const { owner, standby, epoch, head } = await replicatedPair(world);
    assert.notEqual((await standby.failover("promote", "--replace-epoch", String(epoch), "--wait", "0")).code, 0);
    const before = tables(owner.state);
    const back = await owner.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--wait", "0");
    assert.equal(back.holder, OWNER);
    assert.deepEqual(back.evidence, { kind: "lock_held" }, "the sealed holder's own writer lock is its stop evidence");
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: OWNER, head });
    assert.deepEqual(tables(owner.state), before);
    const late = await standby.failover("promote", "--replace-epoch", String(epoch));
    assert.notEqual(late.code, 0);
    assert.match(late.stderr, new RegExp(`holder ${OWNER} owns it at epoch ${epoch + 1}`));
  });

  await t.test("a promotion is refused while follow applies to the same directory, and then catches up", async () => {
    const { owner, standby, epoch, head } = await replicatedPair(world);
    const following = standby.start("follow", "--interval", "1");
    await until(() => { following.assertRunning(); return JSON.stringify(tables(standby.state)) === JSON.stringify(tables(owner.state)); },
      "follow holds the lock and has applied the log");
    const record = await owner.record();
    const refused = await standby.failover("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, /Another agent process owns this state directory/);
    assert.deepEqual(await owner.record(), record, "a promotion refused by the lock asks the authority for nothing");
    await crash(following);
    await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: STANDBY, head });
    assert.deepEqual(tables(standby.state), tables(owner.state));
  });
});
