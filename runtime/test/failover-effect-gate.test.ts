import assert from "node:assert/strict";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import type { HostResult } from "../src/generated/HostResult.js";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { apnsConfig, startApnsOrigin } from "./fixtures/apns-origin.js";
import { chat, connectHost, failoverCoordinator, startBridge } from "./fixtures/failover-bridge.js";
import { commands, type FaultRule } from "./fixtures/failover-fault-proxy.js";
import { enroll, OWNER, replaceOwner, STANDBY, stateDirectory } from "./fixtures/failover-state.js";
import { until } from "./fixtures/until.js";

const PATH = "gated-fixture-path";
const file: HostResult = { type: "file", content: "Invented file content", truncated: false };
type Seen = Parameters<NonNullable<FaultRule["match"]>>[0];

const appendLogsToolCall = (request: Seen) => commands("append")(request) && request.body.includes(PATH);

function confirmsAfterTheToolCall(): NonNullable<FaultRule["match"]> {
  let logged = false;
  return (request) => {
    if (commands("append")(request) && request.body.includes(PATH)) logged = true;
    return logged && commands("confirm")(request);
  };
}

/** A replicated owner whose model asks to read one file on its host. */
async function toolCall(t: TestContext) {
  const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t), { proxy } = coordinator;
  const epoch = await enroll(coordinator.owner);
  const proxyRequestsAtEachReadFile: number[] = [];
  const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch),
    queue: { "fixture-gated": [{ tool: "read_file", args: { path: PATH } }, { text: "Read the gated file." }] },
    host(command) {
      if (command.type !== "read_file") return undefined;
      proxyRequestsAtEachReadFile.push(proxy.seen.length);
      return file;
    } });
  await connectHost(bridge);
  const heldConfirm = () => proxy.seen.some((request, index) => commands("confirm")(request) && proxy.seen.slice(0, index).some(appendLogsToolCall));
  return { coordinator, proxy, epoch, bridge, proxyRequestsAtEachReadFile, heldConfirm, start: () => bridge.send(1, chat("fixture-gated", "gated-input")) };
}

const INSTALLATION = "44444444-4444-4444-8444-444444444444";

const appendSavesPushAttempt = (request: Seen) => commands("append")(request) && request.body.includes("attempting");

function confirmsAfterTheAttempt(): NonNullable<FaultRule["match"]> {
  let saved = false;
  return (request) => {
    if (appendSavesPushAttempt(request)) saved = true;
    return saved && commands("confirm")(request);
  };
}

/**
 * A replicated owner with one registered phone and a local APNs origin.
 */
async function push(t: TestContext) {
  const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t), { proxy } = coordinator;
  const epoch = await enroll(coordinator.owner);
  const origin = await startApnsOrigin(t);
  const proxyRequestsAtEachPush: number[] = [];
  origin.onPush = () => { proxyRequestsAtEachPush.push(proxy.seen.length); };
  const config = await apnsConfig(join(directory, "AuthKey.p8"));
  const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch),
    env: { AGENT_APNS_CONFIG: JSON.stringify(config), ...origin.environment },
    queue: { "fixture-push": [{ text: "A reply worth a push." }] } });
  bridge.send(1, { type: "notifications", request: { type: "register", installation_id: INSTALLATION, token: "01ab".repeat(24) } });
  await bridge.wait(1, (event) => event.type === "done");
  assert.deepEqual(bridge.of(1)[0], { type: "notifications", status: { configured: true, registered: true } }, bridge.errors());
  const heldConfirm = () => proxy.seen.some((request, index) => commands("confirm")(request) && proxy.seen.slice(0, index).some(appendSavesPushAttempt));
  return { coordinator, proxy, epoch, bridge, proxyRequestsAtEachPush, heldConfirm, start: () => bridge.send(2, chat("fixture-push", "push-input")) };
}

test("the effect gate of a replicated owner, against the Worker on local workerd", { timeout: 180_000 }, async (t) => {
  await t.test("a host call is emitted after a confirm that started after the tool call was requested", async (t) => {
    const { proxy, bridge, proxyRequestsAtEachReadFile, start } = await toolCall(t);
    start();
    await bridge.wait(1, (event) => event.type === "done");
    assert.ok(bridge.of(1).some((event) => event.type === "answer" && event.text === "Read the gated file."), bridge.errors());
    assert.equal(proxyRequestsAtEachReadFile.length, 1);
    const logged = proxy.seen.findIndex(appendLogsToolCall);
    assert.ok(logged >= 0, "the tool call is in the log");
    assert.ok(proxy.seen.slice(logged + 1, proxyRequestsAtEachReadFile[0]).some((request) => commands("confirm")(request) && request.forwarded),
      "the authority answered a confirm between the logged tool call and the host_call frame");
  });

  await t.test("with confirm unanswered the host call is never emitted, and it is emitted once the authority answers", async (t) => {
    const { proxy, bridge, proxyRequestsAtEachReadFile, heldConfirm, start } = await toolCall(t);
    proxy.inject({ fault: { kind: "blackhole" }, match: confirmsAfterTheToolCall() });
    start();
    await until(heldConfirm, "the owner asks to confirm before it emits the host call", 20_000);
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    assert.equal(proxyRequestsAtEachReadFile.length, 0, "no host_call frame while the confirm is unanswered");
    assert.equal(bridge.child.exitCode, null, "an unreachable authority fences nobody");
    proxy.heal();
    await bridge.wait(1, (event) => event.type === "done");
    assert.equal(proxyRequestsAtEachReadFile.length, 1);
    assert.ok(bridge.of(1).some((event) => event.type === "answer" && event.text === "Read the gated file."), bridge.errors());
  });

  await t.test("with confirm refused after a promotion and an activation, no host call is emitted and the bridge exits 75", async (t) => {
    const { coordinator, proxy, epoch, bridge, proxyRequestsAtEachReadFile, heldConfirm, start } = await toolCall(t);
    proxy.inject({ fault: { kind: "blackhole" }, match: confirmsAfterTheToolCall() });
    start();
    await until(heldConfirm, "the owner asks to confirm before it emits the host call", 20_000);
    await replaceOwner(coordinator.standby, STANDBY, epoch);
    proxy.heal();
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.equal(proxyRequestsAtEachReadFile.length, 0);
    assert.deepEqual(bridge.hostCalls("read_file"), []);
  });

  await t.test("a push waits for a confirm after its attempt is logged: with confirm unanswered nothing reaches APNs, and then one push does", async (t) => {
    const { proxy, bridge, proxyRequestsAtEachPush, heldConfirm, start } = await push(t);
    proxy.inject({ fault: { kind: "blackhole" }, match: confirmsAfterTheAttempt() });
    start();
    await until(heldConfirm, "the owner asks to confirm before it sends the push", 20_000);
    await new Promise((resolve) => setTimeout(resolve, 1_500));
    assert.deepEqual(proxyRequestsAtEachPush, [], "no request reaches APNs while the confirm is unanswered");
    assert.equal(bridge.child.exitCode, null);
    const healed = proxy.seen.length;
    proxy.heal();
    await until(() => proxyRequestsAtEachPush.length === 1, "the push reaches APNs once the authority answers", 20_000);
    assert.ok(proxy.seen.slice(healed, proxyRequestsAtEachPush[0]).some((request) => commands("confirm")(request) && request.forwarded),
      "the authority answered a confirm before the push left");
    await new Promise((resolve) => setTimeout(resolve, 500));
    assert.equal(proxyRequestsAtEachPush.length, 1);
  });

  await t.test("with confirm refused after a promotion and an activation, nothing reaches APNs and the bridge exits 75", async (t) => {
    const { coordinator, proxy, epoch, bridge, proxyRequestsAtEachPush, heldConfirm, start } = await push(t);
    proxy.inject({ fault: { kind: "blackhole" }, match: confirmsAfterTheAttempt() });
    start();
    await until(heldConfirm, "the owner asks to confirm before it sends the push", 20_000);
    await replaceOwner(coordinator.standby, STANDBY, epoch);
    proxy.heal();
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.deepEqual(proxyRequestsAtEachPush, []);
  });

  // This documents the design's residual. It does not close it: an approval
  // the authority gave before a promotion still releases its one effect after.
  await t.test("an approval held across a promotion releases its host call once, and the bridge exits 75 at its next exchange", async (t) => {
    const { coordinator, proxy, epoch, bridge, proxyRequestsAtEachReadFile, start } = await toolCall(t);
    let release = () => {};
    proxy.inject({ fault: { kind: "reply-late", release: new Promise<void>((resolve) => { release = resolve; }) }, match: confirmsAfterTheToolCall() });
    start();
    await until(() => proxy.seen.some((request, index) => commands("confirm")(request) && request.forwarded && proxy.seen.slice(0, index).some(appendLogsToolCall)),
      "the authority approves the confirm", 20_000);
    assert.equal(proxyRequestsAtEachReadFile.length, 0, "the approval is still on its way");
    await replaceOwner(coordinator.standby, STANDBY, epoch);
    release();
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.equal(proxyRequestsAtEachReadFile.length, 1, "the late approval releases the host call once");
    assert.equal(bridge.hostCalls("read_file").length, 1);
    assert.equal(bridge.of(1).some((event) => event.type === "answer"), false, "the fenced owner commits nothing after its host call");
  });
});
