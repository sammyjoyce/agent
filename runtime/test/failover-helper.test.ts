import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:net";
import { test } from "node:test";
import { logEntryDigest, versions } from "../src/failover/log-entry.js";
import { AUTHORITY_UNREACHABLE_EXIT } from "../src/generated/authority-unreachable-exit.js";
import type { FailoverReport } from "../src/generated/FailoverReport.js";
import { failoverCoordinator, runHelper, runScript, startScript } from "./fixtures/failover-bridge.js";
import { commands, latch } from "./fixtures/failover-fault-proxy.js";
import { claimStart, enroll, OWNER, STANDBY, stateDirectory, unstampedDirectory } from "./fixtures/failover-state.js";
import { until } from "./fixtures/until.js";

const RECORD = JSON.stringify({ op: "record" });
const claim = (state: string) => JSON.stringify({ op: "claim", state });
const report = (stdout: string): FailoverReport => JSON.parse(stdout) as FailoverReport;

async function closedPort(): Promise<string> {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  server.close();
  await once(server, "close");
  return `http://127.0.0.1:${address.port}`;
}

test("the failover helper against the Worker on local workerd", { timeout: 120_000 }, async (t) => {
  await t.test("claim by the owner raises the epoch and prints claimed", async (t) => {
    const coordinator = await failoverCoordinator(t);
    assert.equal(await enroll(coordinator.owner), 1);
    const run = await runHelper(await coordinator.session(OWNER), claim(await stateDirectory(t)));
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "claimed", epoch: 2, head: 0 });
    assert.equal(run.stdout.trim().split("\n").length, 1, "the helper prints exactly one value");
    assert.deepEqual((await coordinator.reader.record())?.state, { kind: "active", epoch: 2, holder: OWNER, head: 0 });
  });

  await t.test("each claim by the owner fences every epoch an earlier process of that owner held", async (t) => {
    const coordinator = await failoverCoordinator(t), state = await stateDirectory(t), session = await coordinator.session(OWNER);
    const earlier: number[] = [];
    let current = await enroll(coordinator.owner);
    for (let restart = 1; restart <= 3; restart += 1) {
      const run = await runHelper(session, claim(state));
      assert.equal(run.code, 0, run.stderr);
      const claimed = report(run.stdout);
      assert.ok(claimed.result === "claimed", run.stdout);
      earlier.push(current);
      for (const epoch of earlier) {
        const body = { at: 1, epoch, versions: await versions(), files: [], removed: [], batch: null };
        const append = await coordinator.owner.command({ op: "append", holder: OWNER, entry: { ...body, digest: logEntryDigest(body) } });
        assert.deepEqual([append.result, append.result === "refused" ? append.reason : null], ["refused", "fenced"], `after restart ${restart}, an append at epoch ${epoch} is refused`);
        const confirm = await coordinator.owner.command({ op: "confirm", holder: OWNER, epoch });
        assert.deepEqual([confirm.result, confirm.result === "refused" ? confirm.reason : null], ["refused", "fenced"], `after restart ${restart}, a confirm at epoch ${epoch} is refused`);
      }
      assert.equal(claimed.epoch, current + 1, "each claim grants the next epoch");
      assert.equal((await coordinator.owner.command({ op: "confirm", holder: OWNER, epoch: claimed.epoch })).result, "accepted", "the process that just claimed is the owner");
      current = claimed.epoch;
    }
    assert.deepEqual((await coordinator.reader.record())?.state, { kind: "active", epoch: 4, holder: OWNER, head: 0 }, "no refused append moved the head");
  });

  await t.test("a claim that reaches the authority after a later start claimed is refused, so the running owner keeps its epoch", async (t) => {
    const coordinator = await failoverCoordinator(t), state = await stateDirectory(t), session = await coordinator.session(OWNER), delayed = latch();
    assert.equal(await enroll(coordinator.owner), 1);
    const claims = () => coordinator.proxy.seen.filter(commands("claim"));
    coordinator.proxy.inject({ fault: { kind: "hold", release: delayed.released }, times: 1, match: commands("claim") });
    const gaveUp = startScript("helper", session, claim(state));
    await until(() => claims().length === 1, "The first start must send its claim");
    // The start that sent the claim is gone, as after a timeout and a restart by the service manager.
    gaveUp.child.kill("SIGKILL");
    await gaveUp.done;

    const restarted = await runHelper(session, claim(state));
    assert.deepEqual(report(restarted.stdout), { result: "claimed", epoch: 2, head: 0 }, restarted.stderr);
    delayed.release();
    await until(() => claims().every((request) => request.forwarded), "The delayed claim must reach the authority");
    assert.equal(claims().length, 2);
    assert.deepEqual((await coordinator.reader.record())?.state, { kind: "active", epoch: 2, holder: OWNER, head: 0 }, "the delayed claim raised no epoch");
    assert.equal((await coordinator.owner.command({ op: "confirm", holder: OWNER, epoch: 2 })).result, "accepted", "the running owner is not fenced by its own earlier claim");
  });

  await t.test("a claim that finds the epoch moved by another claim of its holder reads the epoch again and claims the next one", async (t) => {
    const coordinator = await failoverCoordinator(t), state = await stateDirectory(t), held = latch();
    assert.equal(await enroll(coordinator.owner), 1);
    coordinator.proxy.inject({ fault: { kind: "hold", release: held.released }, times: 1, match: commands("claim") });
    const starting = startScript("helper", await coordinator.session(OWNER), claim(state));
    await until(() => coordinator.proxy.seen.some(commands("claim")), "The start must send its claim");
    assert.equal((await claimStart(coordinator.owner, OWNER)).result, "accepted");
    held.release();
    const run = await starting.done;
    assert.deepEqual(report(run.stdout), { result: "claimed", epoch: 3, head: 0 }, run.stderr);
    assert.deepEqual(coordinator.proxy.seen.filter(commands("claim")).map((request) => (JSON.parse(request.body) as { expected_epoch: number }).expected_epoch), [1, 2]);
  });

  await t.test("claim by a holder that is not the owner prints refused with the owner's state and exits 0", async (t) => {
    const coordinator = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const run = await runHelper(await coordinator.session(STANDBY), claim(await stateDirectory(t)));
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "refused", reason: "fenced", state: { kind: "active", epoch: 1, holder: OWNER, head: 0 } });
    assert.equal((await coordinator.reader.record())?.state.epoch, 1, "a refused claim moves nothing");
  });

  await t.test("claim before enrollment prints refused with no state", async (t) => {
    const coordinator = await failoverCoordinator(t);
    const run = await runHelper(await coordinator.session(OWNER), claim(await stateDirectory(t)));
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "refused", reason: "not_enrolled", state: null });
  });

  await t.test("claim for a state directory that holds no log position prints unstamped and asks the authority nothing", async (t) => {
    const coordinator = await failoverCoordinator(t);
    assert.equal(await enroll(coordinator.owner), 1);
    const run = await runHelper(await coordinator.session(OWNER), claim(await unstampedDirectory(t)));
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "unstamped" });
    assert.deepEqual(coordinator.proxy.seen, []);
    assert.equal((await coordinator.reader.record())?.state.epoch, 1, "no epoch was claimed");
  });

  await t.test("record before enrollment prints a null record", async (t) => {
    const coordinator = await failoverCoordinator(t);
    const run = await runHelper(await coordinator.session(OWNER), RECORD);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "record", record: null });
  });

  await t.test("record for a session without a holder prints the owner record and writes nothing", async (t) => {
    const coordinator = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const before = await coordinator.reader.record();
    const run = await runHelper(await coordinator.session(null), RECORD);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "record", record: before });
    assert.deepEqual(await coordinator.reader.record(), before);
  });

  await t.test("claim for a session without a holder fails and sends nothing", async (t) => {
    const coordinator = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const run = await runHelper(await coordinator.session(null), claim(await stateDirectory(t)));
    assert.notEqual(run.code, 0);
    assert.equal(run.stdout, "");
    assert.match(run.stderr, /holder/);
    assert.deepEqual(coordinator.proxy.seen, []);
  });

  await t.test("an authority that does not answer is a failure with one exit status for both scripts, never a refusal", async (t) => {
    const coordinator = await failoverCoordinator(t);
    const requests: ["helper" | "operator", string][] = [["helper", claim(await stateDirectory(t))], ["helper", RECORD], ["operator", JSON.stringify({ op: "status", state: null })]];
    for (const [script, request] of requests) {
      const run = await runScript(script, await coordinator.session(OWNER, undefined, await closedPort()), request);
      assert.equal(run.code, AUTHORITY_UNREACHABLE_EXIT, `${script} ${request}: ${run.stderr}`);
      assert.equal(run.stdout, "", "a failed script prints no report");
      assert.match(run.stderr, /authority did not answer/);
      assert.ok(run.elapsedMs < 10_000, `the ${script} ended after ${run.elapsedMs} ms`);
    }
  });

  await t.test("a credential the authority does not know is a failure", async (t) => {
    const coordinator = await failoverCoordinator(t), other = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const session = JSON.stringify({ ...JSON.parse(await other.session(OWNER)), coordinator_id: coordinator.id });
    const run = await runHelper(session, RECORD);
    assert.notEqual(run.code, 0);
    assert.equal(run.stdout, "");
    assert.match(run.stderr, /bearer token is not a credential/);
  });

  await t.test("a session or a request that is not exactly what Rust writes fails before any exchange", async (t) => {
    const coordinator = await failoverCoordinator(t);
    const session = JSON.parse(await coordinator.session(OWNER)) as Record<string, unknown>;
    const state = await stateDirectory(t), stamped = claim(state);
    const cases: [string | undefined, string, RegExp][] = [
      [undefined, stamped, /AGENT_FAILOVER/],
      ["not json", stamped, /AGENT_FAILOVER/],
      [JSON.stringify({ ...session, extra: true }), stamped, /AGENT_FAILOVER\.extra is not known/],
      [JSON.stringify({ ...session, epoch: 3 }), stamped, /AGENT_FAILOVER\.epoch is not known/],
      [JSON.stringify({ ...session, holder: "ABC" }), stamped, /AGENT_FAILOVER\.holder is not a lowercase UUID/],
      [JSON.stringify({ ...session, token_file: 7 }), stamped, /AGENT_FAILOVER\.token_file is not a string/],
      [JSON.stringify({ ...session, token_file: "/nonexistent/invented-token" }), stamped, /token file/],
      [JSON.stringify(session), JSON.stringify({ op: "promote" }), /op is not one of claim, record/],
      [JSON.stringify(session), JSON.stringify({ op: "claim", state, holder: OWNER }), /holder is not known/],
      [JSON.stringify(session), JSON.stringify({ op: "claim" }), /state is missing/],
    ];
    for (const [given, request, expected] of cases) {
      const run = await runHelper(given, request);
      assert.notEqual(run.code, 0, `${given} ${request}`);
      assert.equal(run.stdout, "");
      assert.match(run.stderr, expected);
    }
    assert.deepEqual(coordinator.proxy.seen, []);
  });

  await t.test("the operator reads the session the helper reads, and refuses the same ones before any exchange", async (t) => {
    const coordinator = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const session = JSON.parse(await coordinator.session(OWNER)) as Record<string, unknown>;
    const status = JSON.stringify({ op: "status", state: null });
    const cases: [string | undefined, RegExp][] = [
      [undefined, /AGENT_FAILOVER is not set/],
      ["not json", /AGENT_FAILOVER is not JSON/],
      [JSON.stringify({ ...session, extra: true }), /AGENT_FAILOVER\.extra is not known/],
      [JSON.stringify({ ...session, epoch: 3 }), /AGENT_FAILOVER\.epoch is not known/],
      [JSON.stringify({ ...session, coordinator_id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA" }), /AGENT_FAILOVER\.coordinator_id is not a lowercase UUID/],
      [JSON.stringify({ ...session, token_file: "/nonexistent/invented-token" }), /token file/],
    ];
    for (const [given, expected] of cases) {
      const run = await runScript("operator", given, status);
      assert.equal(run.code, 1, `${given}: ${run.stderr}`);
      assert.equal(run.stdout, "");
      assert.match(run.stderr, expected);
    }
    assert.deepEqual(coordinator.proxy.seen, []);
    for (const holder of [OWNER, null]) {
      const run = await runScript("operator", await coordinator.session(holder), status);
      assert.equal(run.code, 0, run.stderr);
      assert.deepEqual(JSON.parse(run.stdout), { result: "status", record: await coordinator.reader.record(), applied: null });
    }
  });
});
