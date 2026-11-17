import assert from "node:assert/strict";
import { join } from "node:path";
import { test } from "node:test";
import { commands, startFaultProxy, type FaultRule } from "./fixtures/failover-fault-proxy.js";
import { crash, exists, HOLDERS, replicatedPair, sealedFor, until, World, type PromotedReceipt, type ReleasedReceipt } from "./fixtures/failover-hosts.js";
import { tables } from "./fixtures/failover-state.js";

const [, STANDBY] = HOLDERS;
const held = (state: string) => exists(join(state, "restore-hold.json"));
const never = new Promise<void>(() => {});
const logRead: NonNullable<FaultRule["match"]> = ({ method, path }) => method === "GET" && path.includes("/log?");

/** Where a promotion is killed: the request the fault stops, and whether the old owner releases before the kill. */
const KILL_POINTS: readonly { after: string; stop: FaultRule; release: boolean }[] = [
  { after: "promote", stop: { fault: { kind: "reply-late", release: never }, match: commands("promote") }, release: false },
  { after: "the evidence", stop: { fault: { kind: "blackhole" }, match: logRead }, release: true },
  { after: "catch-up", stop: { fault: { kind: "blackhole" }, match: commands("activate") }, release: true },
  { after: "activate", stop: { fault: { kind: "reply-late", release: never }, match: commands("activate") }, release: true },
];

test("a release whose reply was lost posts nothing when it is run again, and reports the evidence the authority holds", { timeout: 60_000 }, async (t) => {
  const world = await World.start(t), proxy = await startFaultProxy(t, world.authorityUrl);
  const { owner, standby, epoch } = await replicatedPair(world, { owner: proxy.url });
  const releases = () => proxy.seen.filter(commands("release")).length;
  // Sealed by hand, so no promotion activates between the two releases.
  assert.equal((await standby.link.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null })).result, "accepted");

  proxy.inject({ fault: { kind: "drop-after-apply" }, times: 1, match: commands("release") });
  const lost = await owner.failover("release");
  assert.notEqual(lost.code, 0, "the release that got no reply fails");
  assert.equal(releases(), 1);

  const again = await owner.receipt<ReleasedReceipt>("release");
  assert.deepEqual(again, { coordinator_id: owner.coordinatorId, epoch, evidence: "lock_held", candidate: STANDBY, posted: false });
  assert.equal(releases(), 1, "the rerun sent no second release");
  assert.match(await owner.plain("release"), /already holds the old owner's stop evidence/);
  assert.deepEqual((await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch))).evidence, { kind: "lock_held" });
});

test("a promotion that stops partway ends in the same state when it is run again", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);

  for (const { after, stop, release } of KILL_POINTS) {
    await t.test(`a promotion killed after ${after} completes on a rerun`, async (t) => {
      const proxy = await startFaultProxy(t, world.authorityUrl);
      const { owner, standby, epoch, head } = await replicatedPair(world, { standby: proxy.url });
      proxy.inject(stop);
      const stopped = () => proxy.seen.some((request) => stop.match?.(request) === true);
      const promotion = standby.start("promote", "--replace-epoch", String(epoch));
      if (release) {
        await until(() => sealedFor(owner, STANDBY), "the promotion seals the log");
        await owner.receipt<ReleasedReceipt>("release");
      }
      await until(stopped, `the promotion reaches the request after ${after}`);
      await crash(promotion);
      proxy.heal();
      if (!release) await owner.receipt<ReleasedReceipt>("release");

      const promoted = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch));
      assert.equal(promoted.epoch, epoch + 1);
      assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: STANDBY, head });
      assert.deepEqual(tables(standby.state), tables(owner.state));
      assert.equal(await held(standby.state), false);
    });
  }
});
