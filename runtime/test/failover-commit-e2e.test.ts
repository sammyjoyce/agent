import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { commands, latch, type FaultRule } from "./fixtures/failover-fault-proxy.js";
import { STANDBY } from "./fixtures/failover-state.js";
import { admissions, answers, failoverWorld, type FailoverWorld } from "./fixtures/failover-world.js";

const STATEMENT = "Invented: the old host is powered off";
type Match = NonNullable<FaultRule["match"]>;

/** The appends that carry the batch which admits this input. */
const admitting = (input: string): Match => (request) => commands("append")(request) && request.body.includes(input);

/** An enrolled owner that serves at epoch 2, and a standby that joined. */
async function servedPair(world: FailoverWorld) {
  await world.enroll();
  const serving = await world.serve(world.owner);
  await world.join();
  return serving;
}

test("each commit of a replicated owner is in the log before it is on disk", { timeout: 180_000 }, async (t) => {
  await t.test("a reply lost after the object applied an append, same owner: one entry, accepted once", async (t) => {
    const world = await failoverWorld(t), { owner } = world, input = randomUUID();
    await world.enroll();
    await world.serve(owner);
    await world.script("fixture-lost-reply", [{ text: "Answered after the lost reply." }]);
    owner.proxy.inject({ fault: { kind: "drop-after-apply" }, times: 1, match: admitting(input) });
    const events = await world.send(owner, "fixture-lost-reply", { id: input });
    assert.equal(admissions(events, input), 1, JSON.stringify(events));
    assert.deepEqual(answers(events), ["Answered after the lost reply."]);
    const offered = owner.proxy.seen.filter(admitting(input));
    assert.ok(offered.length >= 2 && offered[0]!.forwarded && offered[1]!.forwarded, "the owner repeated the append whose reply it never saw");
    assert.equal(offered[1]!.body, offered[0]!.body, "the repeat is the same entry at the same position");
    assert.equal(await world.logged(input), 1, "the log holds one entry for the input");
    assert.equal(world.saved(owner, input), 1);
  });

  await t.test("a crash between the append and the local commit, then a retry: accepted once, one log entry", async (t) => {
    const world = await failoverWorld(t), { owner } = world, input = randomUUID();
    await world.enroll();
    await world.serve(owner);
    await world.script("fixture-crash", [{ text: "Answered after the crash." }]);
    const lost = owner.proxy.inject({ fault: { kind: "drop-after-apply" }, times: 1, match: admitting(input) });
    owner.proxy.inject({ fault: { kind: "blackhole" }, match: () => lost.times === 0 });
    const first = world.sending(owner, "fixture-crash", { id: input });
    await world.until(async () => owner.proxy.seen.some((request) => request.forwarded && admitting(input)(request)), "The authority must apply the append");
    await world.crash(owner);
    owner.proxy.heal();
    assert.equal(admissions(first.events, input), 0, "the client heard no acceptance before the crash");
    assert.equal(world.saved(owner, input), 0, "the coordinator died before its local commit");
    assert.equal(await world.logged(input), 1);

    await world.serve(owner);
    const acknowledged = (events: Awaited<typeof first.done>) => events.flatMap((event) => event.type === "input_accepted" && event.input_id === input ? [event.work?.type] : []);
    const retry = await world.send(owner, "fixture-crash", { id: input });
    assert.ok(acknowledged(retry).length > 0, `the retry is acknowledged from the entry the restarted owner applied: ${JSON.stringify(retry)}`);
    await world.until(async () => acknowledged(await world.send(owner, "fixture-crash", { id: input })).includes("completed"), "The restarted owner must answer the input");
    assert.equal(await world.logged(input), 1, "the retries admit nothing new");
    assert.equal(world.saved(owner, input), 1);
    assert.equal(await world.asked("fixture-crash"), 1, "the model was asked once for the input");
  });

  await t.test("a refused batch is not on the old owner's disk, and its resubmit to the new owner is accepted once", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world, input = randomUUID();
    const serving = await servedPair(world);
    await world.script("fixture-refused", [{ text: "Answered by the new owner." }]);
    const held = latch();
    owner.proxy.inject({ fault: { kind: "hold", release: held.released }, match: admitting(input) });
    const refused = world.sending(owner, "fixture-refused", { id: input });
    await world.until(async () => owner.proxy.seen.some(admitting(input)), "The old owner must offer the batch to the authority");
    // The owner's periodic check would also find the fence. Holding it leaves the append as the exchange that is refused.
    owner.proxy.inject({ fault: { kind: "blackhole" }, match: commands("confirm") });
    const before = world.tables(owner);
    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.deepEqual({ holder: promoted.holder, epoch: promoted.epoch }, { holder: STANDBY, epoch: 3 });

    held.release();
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.equal(admissions(refused.events, input), 0, "the old owner accepted nothing");
    assert.deepEqual(world.tables(owner), before, "the refused batch is not on the old owner's disk");
    assert.equal(await world.logged(input), 0, "and not in the log");

    await world.serve(standby);
    const resubmitted = await world.send(standby, "fixture-refused", { id: input });
    assert.equal(admissions(resubmitted, input), 1, JSON.stringify(resubmitted));
    assert.deepEqual(answers(resubmitted), ["Answered by the new owner."]);
    assert.equal(admissions(await world.send(standby, "fixture-refused", { id: input }), input), 0, "a second resubmit is answered from the saved row");
    assert.equal(await world.logged(input), 1);
    assert.equal(world.saved(standby, input), 1);
  });

  await t.test("a reply lost, then a seal, then the old owner retries: refused, nothing committed locally, and the old owner exits 75", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world, input = randomUUID();
    const serving = await servedPair(world);
    await world.script("fixture-sealed-retry", [{ text: "Answered by the new owner." }]);
    const held = latch();
    owner.proxy.inject({ fault: { kind: "hold", release: held.released }, match: admitting(input) });
    owner.proxy.inject({ fault: { kind: "drop-after-apply" }, times: 1, match: admitting(input) });
    const sent = world.sending(owner, "fixture-sealed-retry", { id: input });
    await world.until(async () => {
      const offered = owner.proxy.seen.filter(admitting(input));
      return offered.length >= 2 && offered[0]!.forwarded;
    }, "The old owner must retry the append whose reply it never saw");
    owner.proxy.inject({ fault: { kind: "blackhole" }, match: commands("confirm") });
    const before = world.tables(owner);
    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.equal(promoted.holder, STANDBY);
    assert.deepEqual((await world.record())?.state, { kind: "active", epoch: 3, holder: STANDBY, head: promoted.sealed_head });

    held.release();
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.equal(admissions(sent.events, input), 0, "the old owner accepted nothing");
    assert.deepEqual(world.tables(owner), before, "the old owner committed nothing locally");
    assert.equal(world.saved(owner, input), 0);
    assert.equal(await world.logged(input), 1, "the entry the authority applied before the seal is in the log once");
    assert.equal(world.saved(standby, input), 1, "and the new owner holds it");
  });
});
