import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import type { AuthorityLink } from "../src/failover/authority-link.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { chat, failoverCoordinator, startBridge } from "./fixtures/failover-bridge.js";
import { commands } from "./fixtures/failover-fault-proxy.js";
import { enroll, follow, logBatches, OWNER, STANDBY, stateDirectory, tables } from "./fixtures/failover-state.js";
import { until } from "./fixtures/until.js";

/** How many submissions the log holds for the input with this id. Each one is an admission of it. */
async function loggedInputs(link: AuthorityLink, inputId: string): Promise<number> {
  const writes = (await logBatches(link)).flat();
  return new Set(writes.flatMap((write) => write.type === "submission" && write.value.requestId === inputId ? [write.value.id] : [])).size;
}

/** The receipts that say the input was accepted. A later receipt with `work` reports its progress. */
const admissions = (events: readonly RuntimeEventKind[], inputId: string) =>
  events.filter((event) => event.type === "input_accepted" && event.input_id === inputId && event.work === undefined).length;

const localInputs = (directory: string, inputId: string) =>
  (tables(directory).submissions ?? []).filter((row) => row.includes(inputId)).length;

async function claim(link: AuthorityLink): Promise<number> {
  const reply = await link.command({ op: "claim", holder: OWNER });
  assert.equal(reply.result, "accepted");
  return reply.state!.epoch;
}

const seal = async (link: AuthorityLink, epoch: number) =>
  assert.equal((await link.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null })).result, "accepted");

test("the Pi bridge as a replicated owner, against the Worker on local workerd", { timeout: 180_000 }, async (t) => {
  await t.test("one turn is accepted, its batches are in the log, and a standby that follows the log has identical tables", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const epoch = await enroll(coordinator.owner);
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch),
      queue: { "fixture-replicated": [{ text: "The replicated owner answered." }] } });
    bridge.send(1, chat("fixture-replicated", "replicated-input"));
    await bridge.wait(1, (event) => event.type === "done");
    assert.equal(admissions(bridge.of(1), "replicated-input"), 1, bridge.errors());
    assert.ok(bridge.of(1).some((event) => event.type === "answer" && event.text === "The replicated owner answered."));
    bridge.child.stdin.end();
    assert.deepEqual(await bridge.exited(), { code: 0, signal: null }, "the owner check does not keep a closing bridge alive");
    assert.equal(await loggedInputs(coordinator.standby, "replicated-input"), 1);
    const head = (await coordinator.reader.record())?.state.head;
    assert.equal(await follow(standby, coordinator.standby), head);
    assert.deepEqual(tables(standby), tables(directory));
    assert.equal(localInputs(standby, "replicated-input"), 1);
  });

  await t.test("without a session the bridge asks the authority nothing and keeps no replication position", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t);
    const bridge = await startBridge(t, { directory, queue: { "fixture-local": [{ text: "The local owner answered." }] } });
    bridge.send(1, chat("fixture-local", "local-input"));
    await bridge.wait(1, (event) => event.type === "done");
    assert.ok(bridge.of(1).some((event) => event.type === "answer" && event.text === "The local owner answered."), bridge.errors());
    bridge.child.stdin.end();
    assert.deepEqual(await bridge.exited(), { code: 0, signal: null });
    assert.deepEqual(coordinator.proxy.seen, []);
    assert.equal("beep_boop_failover" in tables(directory), false);
    assert.equal(localInputs(directory, "local-input"), 1);
  });

  await t.test("a bridge started at an epoch the authority has moved past exits 75 before it accepts a frame", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t);
    const stale = await enroll(coordinator.owner);
    await claim(coordinator.owner);
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, stale) });
    bridge.send(1, { type: "status" });
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.deepEqual(bridge.frames, []);
    assert.match(bridge.errors(), /fenced/);
    assert.equal(coordinator.proxy.seen.some(commands()), false, "a fenced start sends no command");
  });

  await t.test("a bridge that cannot reach the authority at start does not start, and its exit is not the fenced one", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t);
    const epoch = await enroll(coordinator.owner);
    coordinator.proxy.inject({ fault: { kind: "unavailable" } });
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch) });
    bridge.send(1, { type: "status" });
    const ended = await bridge.exited();
    assert.ok(ended.code !== 0 && ended.code !== OWNER_FENCED_EXIT, `the bridge exited ${ended.code}`);
    assert.deepEqual(bridge.frames, []);
    assert.match(bridge.errors(), /fault proxy refused/);
  });

  await t.test("after a promotion seals the log, the next input is not accepted, nothing new is on disk, and the bridge exits 75", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t);
    const epoch = await enroll(coordinator.owner);
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch),
      queue: { "fixture-before-seal": [{ text: "Answered before the seal." }], "fixture-after-seal": [{ text: "Never answered." }] } });
    bridge.send(1, chat("fixture-before-seal", "before-seal"));
    await bridge.wait(1, (event) => event.type === "done");
    assert.ok(bridge.of(1).some((event) => event.type === "answer"), bridge.errors());
    await seal(coordinator.standby, epoch);
    const before = tables(directory), head = (await coordinator.reader.record())?.state.head;
    bridge.send(2, chat("fixture-after-seal", "after-seal"));
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.equal(bridge.frames.some((frame) => frame.event.type === "input_accepted" && frame.event.input_id === "after-seal"), false);
    assert.equal(bridge.of(2).some((event) => event.type === "host_call"), false);
    assert.deepEqual(tables(directory), before);
    assert.equal((await coordinator.reader.record())?.state.head, head);
    assert.match(bridge.errors(), /sealed/);
  });

  await t.test("an idle owner exits 75 within about one owner check of a seal", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t);
    const epoch = await enroll(coordinator.owner);
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, epoch) });
    bridge.send(1, { type: "status" });
    await bridge.wait(1, (event) => event.type === "done");
    await seal(coordinator.standby, epoch);
    const sealed = Date.now();
    assert.deepEqual(await bridge.exited(), { code: OWNER_FENCED_EXIT, signal: null }, bridge.errors());
    assert.ok(Date.now() - sealed < 12_000, `the idle owner left ${Date.now() - sealed} ms after the seal`);
    assert.ok(coordinator.proxy.seen.some(commands("confirm")), "the owner check is a confirm");
  });

  await t.test("an entry the authority applied before the bridge died is applied before Pi opens, and its input is accepted once", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t), { proxy } = coordinator;
    const queue = { "fixture-crash": [{ text: "Answered after the crash." }] };
    const first = await startBridge(t, { directory, session: await coordinator.session(OWNER, await enroll(coordinator.owner)), queue });
    const lost = proxy.inject({ fault: { kind: "drop-after-apply" }, times: 1, match: (request) => commands("append")(request) && request.body.includes("crash-input") });
    proxy.inject({ fault: { kind: "blackhole" }, match: () => lost.times === 0 });
    first.send(1, chat("fixture-crash", "crash-input"));
    await until(() => proxy.seen.some((request) => request.forwarded && request.body.includes("crash-input")), "the authority applies the append", 20_000);
    first.child.kill("SIGKILL");
    await first.exited();
    proxy.heal();
    assert.equal(first.frames.some((frame) => frame.event.type === "input_accepted"), false);
    assert.equal(localInputs(directory, "crash-input"), 0, "the bridge died before its local commit");
    assert.equal(await loggedInputs(coordinator.standby, "crash-input"), 1);

    const second = await startBridge(t, { directory, session: await coordinator.session(OWNER, await claim(coordinator.owner)), queue });
    await until(() => {
      // The new bridge recovers the killed one's write-ahead log under an exclusive lock.
      try { return localInputs(directory, "crash-input") === 1; }
      catch (error) { if (error instanceof Error && /database is locked/.test(error.message)) return false; throw error; }
    }, "the new bridge applies the entry before any frame asks it to open Pi", 20_000);
    second.send(1, chat("fixture-crash", "crash-input"));
    await second.wait(1, (event) => event.type === "done");
    assert.equal(admissions(second.of(1), "crash-input"), 1, second.errors());
    assert.ok(second.of(1).some((event) => event.type === "answer" && event.text === "Answered after the crash."));
    assert.equal(await loggedInputs(coordinator.standby, "crash-input"), 1);
    assert.equal(localInputs(directory, "crash-input"), 1);
  });

  await t.test("while the authority is unreachable no input is accepted and no host call starts, reads complete, and after it returns the input is accepted once", async (t) => {
    const coordinator = await failoverCoordinator(t), directory = await stateDirectory(t), { proxy } = coordinator;
    const bridge = await startBridge(t, { directory, session: await coordinator.session(OWNER, await enroll(coordinator.owner)),
      queue: { "fixture-reachable": [{ text: "Answered while reachable." }], "fixture-unreachable": [{ text: "Answered after the authority returned." }] } });
    bridge.send(1, chat("fixture-reachable", "reachable-input"));
    await bridge.wait(1, (event) => event.type === "done");
    const bytes = Buffer.from("Invented attachment bytes"), attachment = randomUUID();
    bridge.send(2, { type: "attachment", request: { type: "upload", id: attachment, name: "evidence.txt", media_type: "text/plain", size_bytes: bytes.length,
      offset: 0, data_base64: bytes.toString("base64"), complete: true } });
    await bridge.wait(2, (event) => event.type === "done");

    const history = (id: number) => bridge.send(id, { type: "read_history", task_id: null, agent_id: null, cursor: null });
    const download = (id: number) => bridge.send(id, { type: "attachment", request: { type: "download", id: attachment, offset: 0, limit: 1024 } });
    const answered = (id: number) => bridge.of(id).some((event) => event.type === "history" && event.messages.some((message) => message.text === "Answered while reachable."));
    const downloaded = { type: "attachment", response: { type: "download", data_base64: bytes.toString("base64"), next_offset: null } };

    proxy.inject({ fault: { kind: "blackhole" } });
    const frames = bridge.frames.length;
    history(3);
    await bridge.wait(3, (event) => event.type === "done");
    assert.ok(answered(3), JSON.stringify(bridge.of(3)));
    download(4);
    await bridge.wait(4, (event) => event.type === "done");
    assert.deepEqual(bridge.of(4)[0], downloaded);

    bridge.send(5, chat("fixture-unreachable", "unreachable-input"));
    await until(() => proxy.seen.some((request) => !request.forwarded && request.body.includes("unreachable-input")), "the bridge offers the input to the unreachable authority", 20_000);
    // Pi reads through the same serialized line as its commits, so a history
    // read asked behind a waiting commit is answered once that commit lands.
    history(6);
    download(7);
    await bridge.wait(7, (event) => event.type === "done");
    assert.deepEqual(bridge.of(7)[0], downloaded);
    await new Promise((resolve) => setTimeout(resolve, 1_000));
    const during = bridge.frames.slice(frames);
    assert.equal(during.some((frame) => frame.event.type === "input_accepted"), false, "no input is accepted while the authority is unreachable");
    assert.equal(during.some((frame) => frame.event.type === "host_call"), false, "no host call starts while the authority is unreachable");
    assert.equal(localInputs(directory, "unreachable-input"), 0);
    t.diagnostic(`a history read asked behind the waiting input ${bridge.of(6).some((event) => event.type === "done") ? "completed" : "did not complete"} while the authority was unreachable`);

    proxy.heal();
    await bridge.wait(5, (event) => event.type === "done");
    assert.equal(admissions(bridge.of(5), "unreachable-input"), 1, bridge.errors());
    assert.ok(bridge.of(5).some((event) => event.type === "answer" && event.text === "Answered after the authority returned."));
    await bridge.wait(6, (event) => event.type === "done");
    assert.ok(answered(6), JSON.stringify(bridge.of(6)));
    assert.equal(await loggedInputs(coordinator.standby, "unreachable-input"), 1);
  });
});
