import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { commands, startFaultProxy } from "./fixtures/failover-fault-proxy.js";
import { exists, HOLDERS, OWNER_FENCED_EXIT, sealedFor, until, World, type Host, type JoinedReceipt, type PromotedReceipt } from "./fixtures/failover-hosts.js";

const [OWNER, STANDBY] = HOLDERS;

test("a running owner whose Pi child is fenced releases after its cleanup and exits 75", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);
  const fenced = await world.runtimeWith(fileURLToPath(new URL("./fixtures/failover-fenced-bridge.js", import.meta.url)));
  const fence = (host: Host) => writeFile(join(host.home, "bridge-exit"), String(OWNER_FENCED_EXIT));

  await t.test("with the log sealed at its epoch it posts released, and the promotion completes", async (t) => {
    const proxy = await startFaultProxy(t, world.authorityUrl);
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER, proxy.url), standby = await world.host(coordinator, STANDBY);
    await owner.create();
    await owner.receipt("enroll");
    await standby.receipt<JoinedReceipt>("join", coordinator);
    const serving = owner.serve({ runtime: fenced });
    await until(() => exists(join(owner.state, "agent.sock")), "the owner serves");
    const state = await owner.authorityState();
    assert.ok(state.kind === "active" && state.epoch === 2, "the coordinator start claimed epoch 2");
    proxy.inject({ fault: { kind: "delay", ms: 1_000 }, match: commands("release") });

    const promotion = standby.start("promote", "--replace-epoch", "2", "--wait", "60");
    await until(() => sealedFor(owner, STANDBY), "the promotion seals the log");
    await fence(owner);
    await until(() => proxy.seen.some(commands("release")), "the fenced owner posts its release");
    assert.equal(await exists(join(owner.state, "agent.sock")), false, "the release is posted after the owner closed its socket");
    assert.equal(serving.child.exitCode, null, "and before the owner exits");

    const stopped = await serving.done;
    assert.equal(stopped.code, OWNER_FENCED_EXIT, stopped.stderr);
    assert.match(stopped.stderr, /Told the failover authority that this coordinator stopped its effects at epoch 2/);
    const completed = await promotion.done;
    assert.equal(completed.code, 0, completed.stderr);
    assert.deepEqual((JSON.parse(completed.stdout) as PromotedReceipt).evidence, { kind: "released" });
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: 3, holder: STANDBY, head: 0 });
  });

  await t.test("with a record that is not sealed it posts nothing", async (t) => {
    const proxy = await startFaultProxy(t, world.authorityUrl);
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER, proxy.url);
    await owner.create();
    await owner.receipt("enroll");
    const serving = owner.serve({ runtime: fenced });
    await until(() => exists(join(owner.state, "agent.sock")), "the owner serves");
    const record = await owner.record();
    await fence(owner);
    const stopped = await serving.done;
    assert.equal(stopped.code, OWNER_FENCED_EXIT, stopped.stderr);
    assert.doesNotMatch(stopped.stderr, /Told the failover authority/);
    assert.deepEqual(proxy.seen.filter(commands("release")), []);
    assert.deepEqual(await owner.record(), record);
  });
});
