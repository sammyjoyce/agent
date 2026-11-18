import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { readdir, readFile, rename } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { isDeepStrictEqual } from "node:util";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { effect } from "./fixtures/coordinator-world.js";
import { commands } from "./fixtures/failover-fault-proxy.js";
import { loggedFiles, OWNER, retainedFiles, STANDBY, tables } from "./fixtures/failover-state.js";
import { admissions, answers, failoverWorld } from "./fixtures/failover-world.js";

const INSTALLATION = "55555555-5555-4555-8555-555555555555";
/** The item keeps a 16 KiB excerpt of its text, so only a reader of the cold original finds this sentence. */
const BEYOND_THE_EXCERPT = "The cold original names a tungsten bracket.";
const ORIGINAL = "Earlier invented context. ".repeat(800) + BEYOND_THE_EXCERPT + " Later invented context.".repeat(8000);
/** One imported thread whose only message is larger than an item may be, so its original is kept as a cold asset. */
const history = {
  threads: [{ id: "thread-a", sessionId: "thread-a", name: "Invented imported thread", preview: "Saved request", cwd: "/", createdAt: 1, updatedAt: 2,
    forkedFromId: null, parentThreadId: null, historyMode: "legacy", turns: [] }],
  turns: [{ id: "turn-a", itemsView: "full", items: [{ id: "item-a", type: "userMessage", content: [{ type: "text", text: ORIGINAL }] }] }],
};
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const historyText = (events: readonly RuntimeEventKind[]) => events.flatMap((event) => event.type === "history" ? event.messages.map((message) => message.text) : []).join("\n");

test("a planned handover with inputs, a tool call on a worker, an attachment, feedback, a history import with a cold original and a notification " +
  "leaves every accepted input, the same bytes and the same coordinator id on the new owner", { timeout: 120_000 }, async (t) => {
  const world = await failoverWorld(t, { apns: true, history });
  const { owner, standby, worker, until } = world;

  const enrolled = await world.enroll();
  assert.deepEqual({ epoch: enrolled.epoch, through: enrolled.checkpoint.through }, { epoch: 1, through: 0 });
  const serving = await world.serve(owner);
  const claimed = (await world.record())?.state;
  assert.deepEqual({ kind: claimed?.kind, epoch: claimed?.epoch, holder: claimed?.kind === "active" ? claimed.holder : undefined },
    { kind: "active", epoch: 2, holder: OWNER }, "serve claimed the epoch after the enrollment's before it bound its socket");
  assert.equal(owner.proxy.seen.filter(commands("claim")).length, 1, "the built helper sent one claim to the Worker");
  world.work();
  await until(async () => await world.floor() === 2, "A worker the owner links must be told epoch 2");

  const registered = await world.request(owner, { type: "notifications", request: { type: "register", installation_id: INSTALLATION, token: "01ab".repeat(24) } });
  assert.deepEqual(registered[0], { type: "notifications", status: { configured: true, registered: true } });
  const bytes = Buffer.from("Invented attachment bytes for the handover"), attachment = randomUUID();
  const uploaded = await world.request(owner, { type: "attachment", request: { type: "upload", id: attachment, name: "evidence.txt", media_type: "text/plain",
    size_bytes: bytes.length, offset: 0, data_base64: bytes.toString("base64"), complete: true } });
  const receipt = uploaded.flatMap((event) => event.type === "attachment" && event.response.type === "uploaded" && event.response.attachment !== null ? [event.response.attachment] : [])[0];
  assert.ok(receipt, JSON.stringify(uploaded));

  const inputs = { plain: randomUUID(), tool: randomUUID() };
  await world.script("fixture-handover-plain", [{ text: "The replicated coordinator answered." }]);
  await world.script("fixture-handover-tool", [{ tool: "exec", args: { host: worker.nodeId, program: process.execPath, args: effect } }, { text: "The worker ran the command." }]);
  const plain = await world.send(owner, "fixture-handover-plain", { id: inputs.plain });
  assert.equal(admissions(plain, inputs.plain), 1);
  assert.deepEqual(answers(plain), ["The replicated coordinator answered."]);
  const tool = await world.send(owner, "fixture-handover-tool", { id: inputs.tool, attachments: [receipt] });
  assert.equal(admissions(tool, inputs.tool), 1);
  assert.deepEqual(answers(tool), ["The worker ran the command."]);
  assert.deepEqual(await world.ledger(), [{ host: worker.nodeId, cwd: worker.home }], "the tool call ran once, on the worker");
  for (const id of Object.values(inputs)) assert.equal(await world.logged(id), 1, "one logged batch admits each input");
  await until(async () => world.pushes().length === 2, "Each answer must reach the phone as one push");

  const feedback = randomUUID();
  const captured = await world.request(owner, { type: "feedback", description: "Invented report about a garden", input_id: feedback, context: {
    origin_host_id: "33333333-3333-4333-8333-333333333333", cwd: owner.home, conversation_id: null, task_id: null, agent_id: null, model: DEFAULT_MODEL,
    binding: null, draft: "", queued_inputs: [], client_errors: [] } });
  assert.ok(captured.some((event) => event.type === "input_accepted" && event.input_id === feedback), JSON.stringify(captured));

  const imported = await world.request(owner, { type: "import_codex", hosts: [owner.nodeId] });
  const progress = imported.flatMap((event) => event.type === "import_progress" ? [event.progress] : []).at(-1);
  assert.ok(progress !== undefined && progress.items_added === 1 && progress.assets_saved >= 1, JSON.stringify(imported));
  assert.ok((await world.sourceCalls()).includes("thread/read"), "the import read the thread from the source helper");
  const files = await loggedFiles(world.authority.standby), logged = [...files.keys()].sort();
  const cold = logged.filter((path) => path.startsWith("history/assets/"));
  assert.deepEqual(logged.filter((path) => !cold.includes(path)), [`attachments/${attachment}/content`, `attachments/${attachment}/metadata.json`, `feedback/${feedback}.json`, "feedback/latest"],
    "the log names the attachment and the feedback bundle");
  assert.equal(cold.length, 1, "the log names the cold original");
  assert.equal(cold[0], `history/assets/${files.get(cold[0]!)?.sha256}`, "the cold original is named by its hash");
  const conversations = await world.request(owner, { type: "list_conversations", query: "", cursor: null, limit: 50 });
  const thread = conversations.flatMap((event) => event.type === "conversations" ? event.items : []).find((item) => item.source_thread_id === "thread-a");
  assert.ok(thread, JSON.stringify(conversations));
  const read = async (host: typeof owner) => historyText(await world.request(host, { type: "read_conversation", conversation_id: thread.conversation_id, cursor: null }));
  const original = await read(owner);
  assert.ok(original.includes(BEYOND_THE_EXCERPT), "the owner renders the imported message from its cold original");

  const held = async (directory: string) => ({ tables: tables(directory), files: await retainedFiles(directory) });
  assert.equal((await world.join()).through, 0);
  let compared = "";
  await until(async () => {
    const { applied } = await world.follow();
    const mine = await held(owner.state), theirs = await held(standby.state);
    compared = `at log position ${applied}, the owner holds ${Object.keys(mine.files).length} files and the standby holds ${Object.keys(theirs.files).length}`;
    return isDeepStrictEqual(theirs, mine);
  }, "A standby that joined and follows must hold the owner's tables and retained files", () => compared);
  assert.deepEqual(Object.keys(await retainedFiles(standby.state)).sort(), logged);

  const sealed = Date.now(), promoting = world.promoting({ replaceEpoch: 2 });
  const code = await Promise.race([serving.exited, new Promise<string>((resolve) => setTimeout(() => resolve("still running"), 15_000).unref())]);
  assert.equal(code, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
  assert.ok(Date.now() - sealed < 12_000, `serve left ${Date.now() - sealed} ms after the promotion began`);
  assert.match(serving.errors(), /the failover authority fenced this coordinator's epoch/);
  assert.equal(await world.bound(owner), false, "the old owner removed its socket before it left");

  assert.equal(await promoting.exited, 0, promoting.errors());
  const promoted = JSON.parse(promoting.output()) as Awaited<ReturnType<typeof world.promote>>;
  assert.deepEqual({ holder: promoted.holder, epoch: promoted.epoch, evidence: promoted.evidence, missing: promoted.missing_credentials },
    { holder: STANDBY, epoch: 3, evidence: { kind: "released" }, missing: ["auth.json"] }, "the old owner's own release is the stop evidence, with no operator on its host");
  const status = await world.status(standby);
  assert.deepEqual(status.record?.state, { kind: "active", epoch: 3, holder: STANDBY, head: promoted.sealed_head });
  assert.equal(status.applied, promoted.sealed_head);
  assert.equal(status.coordinator_id, world.id);
  assert.equal(await readFile(join(standby.state, "coordinator-id"), "utf8"), await readFile(join(owner.state, "coordinator-id"), "utf8"), "the new owner is the same coordinator");
  assert.deepEqual(await held(standby.state), await held(owner.state), "the new owner holds what the old owner held when it stopped");

  const returned = world.starting(owner);
  assert.equal(await returned.exited, OWNER_FENCED_EXIT, returned.errors());
  assert.match(returned.errors(), new RegExp(`holder ${STANDBY} owns it at epoch 3`));
  assert.equal(await world.bound(owner), false, "the replaced owner binds no socket");

  await rename(owner.home, owner.home + "-moved");
  await world.serve(standby);
  const messages = historyText(await world.request(standby, { type: "read_history", task_id: null, agent_id: null, cursor: null }));
  for (const text of ["fixture-handover-plain", "The replicated coordinator answered.", "fixture-handover-tool", "The worker ran the command."]) {
    assert.ok(messages.includes(text), `the new owner's history holds "${text}": ${messages}`);
  }
  for (const id of Object.values(inputs)) {
    assert.equal(world.saved(standby, id), 1, "every accepted input id is on the new owner");
    const again = await world.send(standby, "a repeat of an input the old owner accepted", { id });
    assert.equal(admissions(again, id), 0, JSON.stringify(again));
    assert.ok(again.some((event) => event.type === "input_accepted" && event.input_id === id && event.work?.type === "completed"), JSON.stringify(again));
    assert.equal(await world.logged(id), 1, "a repeat on the new owner admits nothing");
  }
  const download = await world.request(standby, { type: "attachment", request: { type: "download", id: attachment, offset: 0, limit: 1024 } });
  const downloaded = download.flatMap((event) => event.type === "attachment" && event.response.type === "download" ? [Buffer.from(event.response.data_base64, "base64")] : [])[0];
  assert.ok(downloaded, JSON.stringify(download));
  assert.equal(sha256(downloaded), receipt.sha256, "the attachment's bytes on the new owner match the hash in the old owner's receipt");
  const bundle = await world.request(standby, { type: "read_feedback", id: feedback });
  assert.ok(bundle.some((event) => event.type === "feedback" && event.bundle.id === feedback && event.bundle.description === "Invented report about a garden"), JSON.stringify(bundle));
  assert.equal(await read(standby), original, "the new owner reads the cold original from its own directory, with the old owner's home moved away");
  assert.equal(world.pushes().length, 2, "the new owner sends no push the old owner already sent");
});

test("backup create knows every entry in a replicated owner's stopped state directory and in a standby's", { timeout: 120_000 }, async (t) => {
  const world = await failoverWorld(t), { owner, standby, worker, until } = world;
  await world.enroll();
  const serving = await world.serve(owner);
  world.work();
  await world.online(owner, [worker.nodeId]);
  const bytes = Buffer.from("Invented attachment bytes for the backup"), attachment = randomUUID();
  const uploaded = await world.request(owner, { type: "attachment", request: { type: "upload", id: attachment, name: "evidence.txt", media_type: "text/plain",
    size_bytes: bytes.length, offset: 0, data_base64: bytes.toString("base64"), complete: true } });
  const receipt = uploaded.flatMap((event) => event.type === "attachment" && event.response.type === "uploaded" && event.response.attachment !== null ? [event.response.attachment] : [])[0];
  assert.ok(receipt, JSON.stringify(uploaded));
  await world.script("fixture-backup", [{ tool: "exec", args: { program: process.execPath, args: effect } }, { text: "Ran before the backup." }]);
  assert.deepEqual(answers(await world.send(owner, "fixture-backup", { attachments: [receipt] })), ["Ran before the backup."]);
  await world.request(owner, { type: "feedback", description: "Invented report about a garden", input_id: randomUUID(), context: {
    origin_host_id: "33333333-3333-4333-8333-333333333333", cwd: owner.home, conversation_id: null, task_id: null, agent_id: null, model: DEFAULT_MODEL,
    binding: null, draft: "", queued_inputs: [], client_errors: [] } });
  await world.join();
  await until(async () => (await world.follow()).applied === (await world.record())?.state.head, "The standby must reach the owner's head");
  assert.equal(await world.stop(owner), 0, serving.errors().slice(-1500));

  for (const host of [owner, standby]) {
    const created = world.launch(host, ["backup", "create", join(world.directory, `backup-of-${host.name}`)], "");
    assert.equal(await created.exited, 0, created.errors());
    const { not_included: unknown } = JSON.parse(created.output()) as { not_included: string[] };
    assert.deepEqual(unknown, [], `backup create must know every entry in the ${host.name}'s state directory: ${(await readdir(host.state)).join(", ")}`);
  }
});
