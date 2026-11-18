import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { test } from "node:test";
import type { AttachmentRef } from "../src/generated/AttachmentRef.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { effect } from "./fixtures/coordinator-world.js";
import { blobs, commands } from "./fixtures/failover-fault-proxy.js";
import { loggedFiles, retainedFiles } from "./fixtures/failover-state.js";
import { admissions, answers, failoverWorld, type CoordinatorHost, type FailoverWorld } from "./fixtures/failover-world.js";

const STATEMENT = "Invented: the old host lost power";
const INSTALLATION = "55555555-5555-4555-8555-555555555555";
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

const uploadOf = (id: string, bytes: Buffer): RuntimeCommand => ({ type: "attachment", request: { type: "upload", id, name: "evidence.txt", media_type: "text/plain",
  size_bytes: bytes.length, offset: 0, data_base64: bytes.toString("base64"), complete: true } });
const receipts = (events: readonly RuntimeEventKind[]): AttachmentRef[] =>
  events.flatMap((event) => event.type === "attachment" && event.response.type === "uploaded" && event.response.attachment !== null ? [event.response.attachment] : []);
const feedbackOf = (host: CoordinatorHost, id: string): RuntimeCommand => ({ type: "feedback", description: "Invented report about a garden", input_id: id, context: {
  origin_host_id: "33333333-3333-4333-8333-333333333333", cwd: host.home, conversation_id: null, task_id: null, agent_id: null, model: DEFAULT_MODEL,
  binding: null, draft: "", queued_inputs: [], client_errors: [] } });
const historyText = (events: readonly RuntimeEventKind[]) => events.flatMap((event) => event.type === "history" ? event.messages.map((message) => message.text) : []).join("\n");
const readHistory: RuntimeCommand = { type: "read_history", task_id: null, agent_id: null, cursor: null };

/** One request whose events are kept as they arrive, for a request that may never reach `done`. */
function requesting(world: FailoverWorld, host: CoordinatorHost, command: RuntimeCommand) {
  const events: RuntimeEventKind[] = [];
  const done = world.request(host, command, (event) => { events.push(event); });
  done.catch(() => {});
  return { events, done };
}

test("what a replicated owner acknowledges is in the log and the blob store first", { timeout: 180_000 }, async (t) => {
  await t.test("while the authority is unreachable no input is accepted and no effect starts, an attachment download and a history read complete, " +
    "and after it returns the input is accepted once with no duplicate entry", async (t) => {
    const world = await failoverWorld(t), { owner, worker } = world;
    await world.enroll();
    await world.serve(owner);
    world.work();
    await world.online(owner, [worker.nodeId]);
    await world.script("fixture-reachable", [{ text: "Answered while reachable." }]);
    assert.deepEqual(answers(await world.send(owner, "fixture-reachable")), ["Answered while reachable."]);
    const bytes = Buffer.from("Invented attachment bytes"), attachment = randomUUID();
    assert.equal(receipts(await world.request(owner, uploadOf(attachment, bytes))).length, 1);
    const download = async () => (await world.request(owner, { type: "attachment", request: { type: "download", id: attachment, offset: 0, limit: 1024 } }))[0];
    const downloaded = { type: "attachment", response: { type: "download", data_base64: bytes.toString("base64"), next_offset: null } };

    owner.proxy.inject({ fault: { kind: "blackhole" } });
    assert.ok(historyText(await world.request(owner, readHistory)).includes("Answered while reachable."), "a history read asked before any commit waits completes");
    assert.deepEqual(await download(), downloaded);

    await world.script("fixture-unreachable", [{ tool: "exec", args: { host: worker.nodeId, program: process.execPath, args: effect } }, { text: "Answered after the authority returned." }]);
    const waiting = world.sending(owner, "fixture-unreachable");
    await world.until(async () => owner.proxy.seen.some((request) => !request.forwarded && commands("append")(request) && request.body.includes(waiting.id)),
      "The owner must offer the input to the unreachable authority");
    // Pi Durable 1.4.0 answers a history read on the line its commits wait on, so this one is answered when the authority returns.
    const behind = requesting(world, owner, readHistory);
    assert.deepEqual(await download(), downloaded, "an attachment download completes while an input waits");
    assert.equal(admissions(waiting.events, waiting.id), 0, "no input is accepted while the authority is unreachable");
    assert.equal(world.saved(owner, waiting.id), 0);
    assert.deepEqual(await world.ledger(), [], "no effect starts while the authority is unreachable");
    t.diagnostic(`a history read asked behind the waiting input ${behind.events.some((event) => event.type === "history") ? "completed" : "did not complete"} while the authority was unreachable`);

    owner.proxy.heal();
    const events = await waiting.done;
    assert.equal(admissions(events, waiting.id), 1, JSON.stringify(events));
    assert.deepEqual(answers(events), ["Answered after the authority returned."]);
    assert.ok(historyText(await behind.done).includes("Answered while reachable."), "the history read asked behind the input completes once the authority returns");
    assert.equal(await world.logged(waiting.id), 1, "the log holds one entry for the input");
    assert.equal((await world.ledger()).length, 1, "the effect ran once");
  });

  await t.test("feedback written, a crash before its record is logged, a restart and a resubmit: no acknowledgement from a local-only bundle, and after the resubmit the bundle is on the standby", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world, feedback = randomUUID(), bundle = `feedback/${feedback}.json`;
    await world.enroll();
    await world.serve(owner);
    await world.join();
    const recorded = (request: { method: string; path: string; body: string }) => commands("append")(request) && request.body.includes(bundle);
    owner.proxy.inject({ fault: { kind: "blackhole" }, match: recorded });
    const first = requesting(world, owner, feedbackOf(owner, feedback));
    await world.until(async () => owner.proxy.seen.some(recorded), "The owner must offer the bundle's record to the authority");
    await world.crash(owner);
    owner.proxy.heal();
    assert.equal(first.events.some((event) => event.type === "input_accepted"), false, "the client heard no acknowledgement before the crash");
    assert.equal(bundle in await retainedFiles(owner.state), false, "no bundle has its final name without its record in the log");

    await world.serve(owner);
    const found = await world.request(owner, { type: "read_feedback", id: feedback });
    assert.equal(found.some((event) => event.type === "feedback"), false, `the restarted owner knows no such bundle: ${JSON.stringify(found)}`);
    const resubmitted = await world.request(owner, feedbackOf(owner, feedback));
    assert.ok(resubmitted.some((event) => event.type === "input_accepted" && event.input_id === feedback), JSON.stringify(resubmitted));
    assert.ok((await loggedFiles(world.authority.standby)).has(bundle), "the acknowledged bundle is in the log");
    await world.follow();
    const mine = await retainedFiles(owner.state);
    assert.ok(mine[bundle] !== undefined && (await retainedFiles(standby.state))[bundle] === mine[bundle], "the standby holds the bundle's bytes");
  });

  await t.test("an asset upload that is interrupted is not acknowledged without its bytes in the blob store", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world;
    await world.enroll();
    await world.serve(owner);
    await world.join();
    const bytes = Buffer.from("Invented attachment bytes that must reach the blob store"), attachment = randomUUID(), content = `attachments/${attachment}/content`;
    owner.proxy.inject({ fault: { kind: "unavailable" }, match: blobs });
    const upload = requesting(world, owner, uploadOf(attachment, bytes));
    await world.until(async () => owner.proxy.seen.filter((request) => blobs(request) && !request.forwarded).length >= 2, "The owner must try again to store the bytes");
    assert.deepEqual(receipts(upload.events), [], "no receipt while the blob store lacks the bytes");
    assert.equal((await loggedFiles(world.authority.standby)).has(content), false, "the log does not name the file");
    await assert.rejects(world.authority.standby.getBlob(sha256(bytes)), "the blob store lacks the bytes");

    owner.proxy.heal();
    const [receipt] = receipts(await upload.done);
    assert.equal(receipt?.sha256, sha256(bytes));
    assert.deepEqual(Buffer.from(await world.authority.standby.getBlob(sha256(bytes))), bytes, "the bytes are in the blob store when the receipt is sent");
    await world.follow();
    assert.equal((await retainedFiles(standby.state))[content], sha256(bytes));
  });

  await t.test("an APNs receipt lost at failover: one push at most, and the delivery is uncertain on the new owner", async (t) => {
    const world = await failoverWorld(t, { apns: true }), { owner, standby, apns } = world;
    assert.ok(apns);
    await world.enroll();
    await world.serve(owner);
    await world.join();
    await world.request(owner, { type: "notifications", request: { type: "register", installation_id: INSTALLATION, token: "01ab".repeat(24) } });
    apns.answering = false;
    await world.script("fixture-push", [{ text: "A reply worth a push." }]);
    assert.deepEqual(answers(await world.send(owner, "fixture-push")), ["A reply worth a push."]);
    await world.until(async () => world.pushes().length === 1, "The push must reach the origin");
    const [push] = world.pushes();
    assert.ok(push?.apnsId);
    await world.crash(owner);

    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.deepEqual(promoted.unfinished_deliveries.map((delivery) => delivery.apns_id), [push.apnsId], "the promotion reports the push that has no receipt");
    apns.answering = true;
    await world.serve(standby);
    const deliveries = () => Object.values(world.tables(standby)).flat().filter((row) => row.includes(push.apnsId!));
    await world.until(async () => {
      await world.request(standby, { type: "notifications", request: { type: "status", installation_id: INSTALLATION } });
      return deliveries().some((row) => row.includes("uncertain"));
    }, "The new owner must mark the delivery uncertain", () => JSON.stringify(deliveries()));
    await world.script("fixture-next-push", [{ text: "A second reply worth a push." }]);
    assert.deepEqual(answers(await world.send(standby, "fixture-next-push")), ["A second reply worth a push."]);
    await world.until(async () => world.pushes().length === 2, "The new owner must send the push for its own answer");
    assert.equal(world.pushes().filter((sent) => sent.body.includes("A reply worth a push.")).length, 1, "the first answer was pushed once");
    assert.equal(world.pushes().filter((sent) => sent.apnsId === push.apnsId).length, 1);
  });
});
