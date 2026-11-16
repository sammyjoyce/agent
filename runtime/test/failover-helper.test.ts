import assert from "node:assert/strict";
import { once } from "node:events";
import { createServer } from "node:net";
import { test } from "node:test";
import type { FailoverReport } from "../src/generated/FailoverReport.js";
import { failoverCoordinator, runHelper, runScript } from "./fixtures/failover-bridge.js";
import { enroll, OWNER, STANDBY } from "./fixtures/failover-state.js";

const CLAIM = JSON.stringify({ op: "claim" }), RECORD = JSON.stringify({ op: "record" });
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
    const run = await runHelper(await coordinator.session(OWNER), CLAIM);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "claimed", epoch: 2, head: 0 });
    assert.equal(run.stdout.trim().split("\n").length, 1, "the helper prints exactly one value");
    assert.deepEqual((await coordinator.reader.record())?.state, { kind: "active", epoch: 2, holder: OWNER, head: 0 });
  });

  await t.test("claim by a holder that is not the owner prints refused with the owner's state and exits 0", async (t) => {
    const coordinator = await failoverCoordinator(t);
    await enroll(coordinator.owner);
    const run = await runHelper(await coordinator.session(STANDBY), CLAIM);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "refused", reason: "fenced", state: { kind: "active", epoch: 1, holder: OWNER, head: 0 } });
    assert.equal((await coordinator.reader.record())?.state.epoch, 1, "a refused claim moves nothing");
  });

  await t.test("claim before enrollment prints refused with no state", async (t) => {
    const coordinator = await failoverCoordinator(t);
    const run = await runHelper(await coordinator.session(OWNER), CLAIM);
    assert.equal(run.code, 0, run.stderr);
    assert.deepEqual(report(run.stdout), { result: "refused", reason: "not_enrolled", state: null });
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
    const run = await runHelper(await coordinator.session(null), CLAIM);
    assert.notEqual(run.code, 0);
    assert.equal(run.stdout, "");
    assert.match(run.stderr, /holder/);
    assert.deepEqual(coordinator.proxy.seen, []);
  });

  await t.test("an authority that does not answer is a failure, never a refusal", async (t) => {
    const coordinator = await failoverCoordinator(t);
    for (const request of [CLAIM, RECORD]) {
      const run = await runHelper(await coordinator.session(OWNER, undefined, await closedPort()), request);
      assert.notEqual(run.code, 0);
      assert.equal(run.stdout, "", "a failed helper prints no report");
      assert.match(run.stderr, /authority did not answer/);
      assert.ok(run.elapsedMs < 10_000, `the helper ended after ${run.elapsedMs} ms`);
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
    const cases: [string | undefined, string, RegExp][] = [
      [undefined, CLAIM, /AGENT_FAILOVER/],
      ["not json", CLAIM, /AGENT_FAILOVER/],
      [JSON.stringify({ ...session, extra: true }), CLAIM, /AGENT_FAILOVER\.extra is not known/],
      [JSON.stringify({ ...session, epoch: 3 }), CLAIM, /AGENT_FAILOVER\.epoch is not known/],
      [JSON.stringify({ ...session, holder: "ABC" }), CLAIM, /AGENT_FAILOVER\.holder is not a lowercase UUID/],
      [JSON.stringify({ ...session, token_file: 7 }), CLAIM, /AGENT_FAILOVER\.token_file is not a string/],
      [JSON.stringify({ ...session, token_file: "/nonexistent/invented-token" }), CLAIM, /token file/],
      [JSON.stringify(session), JSON.stringify({ op: "promote" }), /op is not one of claim, record/],
      [JSON.stringify(session), JSON.stringify({ op: "claim", holder: OWNER }), /holder is not known/],
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
