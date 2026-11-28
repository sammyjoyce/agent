import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdir, readdir, readFile, rename } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteDatabase } from "@earendil-works/chord/sqlite";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createRegistry, defineDoc, defineExtension, defineTool, ROOT_CONVERSATION_ID, type StorageWrite } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { AuthorityLink } from "../src/failover/authority-link.js";
import { logEntryDigest, sha256Hex, versions } from "../src/failover/log-entry.js";
import { applyLog } from "../src/failover/standby.js";
import type { LogEntry } from "../src/generated/LogEntry.js";
import { HistoryStore, ImportedItemEntry } from "../src/history.js";
import type { HistoryImportBatch } from "../src/generated/HistoryImportBatch.js";
import { AuthorityUnreachable } from "../src/failover/authority-link.js";
import { authorities, enroll, follow, logBatches, logEntries, note, openOwner, openScoped, OWNER, replaceOwner, sessionPath, stage, stamp, STANDBY,
  stateDirectory, tables, unstampedDirectory } from "./fixtures/failover-state.js";

const context = BACKGROUND_CONTEXT;
const VARIANTS = ["conversation", "entry", "task", "submission", "document.create", "document.copy", "document.change", "document.retire"] as const;

const Ledger = defineDoc<{ count: number }>({ kind: "fixture.ledger", scope: "conversation", history: "rewindable", fork: "asOf", version: 1,
  initial: () => ({ count: 0 }), checkpointWhen: () => false });

function gardenRegistry(held: { started: () => void }) {
  const registry = createRegistry();
  registry.install(defineExtension({ name: "garden", tools: [
    defineTool({
      name: "note", description: "Write an invented note, one line at a time", parameters: Type.Object({ text: Type.String(), lines: Type.Number() }),
      async execute(args, api) {
        for (let line = 0; line < args.lines; line += 1) { api.output(`${args.text} line ${line}\n`); await new Promise((resolve) => setTimeout(resolve, 10)); }
        return {};
      },
    }),
    defineTool({
      name: "hold", description: "Wait until the coordinator stops", parameters: Type.Object({}),
      async execute(_args, _api, toolContext) {
        held.started();
        await new Promise((resolve) => toolContext.abortSignal?.addEventListener("abort", resolve, { once: true }));
        return {};
      },
    }),
  ] }));
  return registry;
}

function logThrough(link: AuthorityLink, head: number): AuthorityLink {
  return { command: (command) => link.command(command), putBlob: (sha256, bytes) => link.putBlob(sha256, bytes), getBlob: (sha256) => link.getBlob(sha256),
    async record() { const record = await link.record(); return record && { ...record, state: { ...record.state, head } }; },
    async log(after, limit) {
      const page = await link.log(after, limit);
      return { record: { ...page.record, state: { ...page.record.state, head } }, entries: page.entries.filter((entry) => entry.at <= head) };
    } };
}

async function position(directory: string): Promise<number> {
  const database = await openScoped(directory);
  try { return await database.position(); } finally { await database.close(); }
}

async function appendStamped(link: AuthorityLink, epoch: number, at: number, stamped: Partial<LogEntry["versions"]>): Promise<void> {
  const body = { at, epoch, versions: { ...await versions(), ...stamped }, files: [], removed: [], batch: null };
  assert.equal((await link.command({ op: "append", holder: OWNER, entry: { ...body, digest: logEntryDigest(body) } })).result, "accepted");
}

async function promotedHistory(t: TestContext, link: AuthorityLink) {
  const epoch = await enroll(link), root = await stateDirectory(t), standby = await stateDirectory(t);
  const directory = join(root, "owner");
  await mkdir(directory);
  await stamp(directory);
  const original = { text: "Invented accepted garden transcript, in full." };
  const bytes = Buffer.from(JSON.stringify(original)), path = `history/assets/${sha256Hex(bytes)}`;
  const owner = await openOwner(directory, link, { epoch });
  const { record } = await stage(directory, link, path, bytes).then(async (staged) => { await owner.log.appendFiles([staged]); return staged; });
  const batch: HistoryImportBatch = { host_id: "invented-worker",
    thread: { id: "invented-thread", title: "Garden", cwd: "/invented/workspace", created_at: 10, updated_at: 20, forked_from_id: null, parent_thread_id: null,
      version: "v1", version_reliable: true, archived: false },
    items: [{ id: "invented-item", turn_id: "turn-1", kind: "userMessage", role: "user", text: "Bounded excerpt", version: "item-v1", order: 1, timestamp_ms: 20, data: null,
      assets: [{ path: join(directory, path), item_id: "invented-item", version: "item-v1", kind: "cold_evidence", media_type: "application/json",
        sha256: record.sha256, size: record.size }] }],
    next_cursor: null, gaps: [], complete: true };
  const receipt = await new HistoryStore(owner.harness, join(directory, "history/assets")).import(batch);
  await owner.harness.close(context);

  assert.equal(await follow(standby, link), (await link.record())?.state.head);
  assert.deepEqual(tables(standby), tables(directory));
  await rename(directory, join(root, "unavailable-owner"));
  const promoted = await openOwner(standby, link, { holder: STANDBY, epoch: await replaceOwner(link, STANDBY, epoch) });
  t.after(() => promoted.harness.close(context));
  const histories = new HistoryStore(promoted.harness, join(standby, "history/assets"));
  const entry = (await Promise.all(receipt.entry_ids.map((id) => histories.entry(receipt.conversation.conversation_id, id)))).find(ImportedItemEntry.is);
  assert.ok(entry, "the standby holds the imported item");
  return { histories, entry, original, standby, root, path };
}

function resolvable() {
  let resolve = () => {};
  const promise = new Promise<void>((settle) => { resolve = settle; });
  return { promise, resolve };
}

for (const [name, connect] of Object.entries(authorities)) {
  test(`${name}: a streaming turn with a tool call replays to identical tables, and a second follow applies nothing`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch, registry: gardenRegistry({ started() {} }), tokensPerSecond: 600 });
    owner.faux.setResponses([
      fauxAssistantMessage([fauxText("I will write that down first."), fauxToolCall("note", { text: "invented note", lines: 12 })], { stopReason: "toolUse" }),
      fauxAssistantMessage(Array.from({ length: 40 }, (_, index) => `Sentence ${index} of an invented answer about a garden plan.`).join(" ")),
    ]);
    const before = owner.log.head;
    const submission = await owner.root.submit({ type: "input", content: "Plan the garden.", requestId: "request-garden" }, context);
    assert.equal((await submission.wait(context)).status, "done");
    const turnCommits = owner.log.head - before;
    await owner.harness.close(context);
    assert.ok(turnCommits > 10, "the streamed turn commits its deltas");

    const head = (await link.record())?.state.head;
    assert.equal(await follow(standby, link), head);
    assert.deepEqual(tables(standby), tables(directory));
    const applied = tables(standby);
    assert.equal(await follow(standby, link), head);
    assert.deepEqual(tables(standby), applied, "a second follow applies nothing");
  });

  test(`${name}: every kind of Pi write replays to identical tables, with the writes Pi makes at close`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const held = resolvable();
    const owner = await openOwner(directory, link, { epoch, registry: gardenRegistry({ started: held.resolve }) });
    const early = await owner.harness.commit(async (tx) => {
      (await tx.doc(Ledger, ROOT_CONVERSATION_ID)).count = 1;
      return tx.appendEntry(ROOT_CONVERSATION_ID, { kind: "app.note", data: "the ledger says one" });
    }, context);
    await owner.harness.commit(async (tx) => { (await tx.doc(Ledger, ROOT_CONVERSATION_ID)).count = 2; }, context);
    const fork = await owner.harness.commit((tx) => tx.forkConversation(ROOT_CONVERSATION_ID, early.id, { ownership: { kind: "ownerless" } }), context);
    assert.deepEqual(await owner.harness.snapshot(Ledger, fork.id, context), { count: 1 }, "the fork holds the ledger as it stood at the earlier entry");
    await owner.harness.commit((tx) => tx.retireDoc(Ledger, fork.id), context);

    owner.faux.setResponses([fauxAssistantMessage([fauxToolCall("hold", {})], { stopReason: "toolUse" })]);
    await owner.root.submit({ type: "input", content: "Hold the gate.", requestId: "request-hold" }, context);
    await held.promise;
    const beforeClose = owner.log.head;
    await owner.harness.close(context);
    const batches = await logBatches(link);
    const atClose = batches.slice(beforeClose).flat();
    assert.ok(atClose.some((write) => write.type === "task" && write.value.state.status === "pending"), "Pi wrote the stopped task back as pending while it closed");

    const logged = new Set(batches.flat().map((write) => write.type));
    assert.deepEqual(VARIANTS.filter((variant) => !logged.has(variant)), [], "the log holds every kind of Pi write");
    const copies = batches.flat().filter((write): write is Extract<StorageWrite, { type: "document.copy" }> => write.type === "document.copy");
    assert.ok(copies.some((copy) => copy.record.kind === "fixture.ledger" && typeof copy.source.at === "number"), "one copy reads its source at a historical point");

    assert.equal(await follow(standby, link), (await link.record())?.state.head);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: two appliers that read the same next entry apply it once, skip nothing, and leave the newer file`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch, registry: gardenRegistry({ started() {} }) });
    const older = Buffer.from("invented older feedback pointer"), newer = Buffer.from("invented newer feedback pointer");
    for (const bytes of [older, newer]) await owner.log.appendFiles([await stage(directory, link, "feedback/latest", bytes)]);
    owner.faux.setResponses([
      fauxAssistantMessage([fauxText("Noting it."), fauxToolCall("note", { text: "invented note", lines: 3 })], { stopReason: "toolUse" }),
      fauxAssistantMessage("The final invented answer."),
    ]);
    assert.equal((await (await owner.root.submit({ type: "input", content: "Plan the garden.", requestId: "request-garden" }, context)).wait(context)).status, "done");
    await owner.harness.close(context);

    const entries = await logEntries(link), batches = await logBatches(link);
    const upsertsOnly = (batch: StorageWrite[]) => batch.every((write) => write.type === "task" || write.type === "submission" || write.type === "document.change");
    const index = batches.findLastIndex((batch, at) => upsertsOnly(batch) && (batches[at + 1]?.some((write) => write.type === "entry") ?? false));
    const contestedBatch = entries.filter((entry) => entry.batch !== null)[index];
    assert.ok(contestedBatch, "the turn logged an entry of upserts followed by its final answer");
    const contestedFile = entries.find((entry) => entry.files.some((file) => file.sha256 === sha256Hex(older)));
    assert.ok(contestedFile, "the log holds the older feedback pointer");

    for (const contested of [contestedFile, contestedBatch]) {
      const standby = await stateDirectory(t);
      assert.equal(await follow(standby, logThrough(link, contested.at - 1)), contested.at - 1);
      const bothRead = resolvable(), firstDone = resolvable();
      let readers = 0;
      const page = link.log(contested.at - 1, 64);
      const sameRead = (release: Promise<void>): AuthorityLink => ({ ...logThrough(link, entries.length), log: async (after, limit) => {
        if (after !== contested.at - 1) return link.log(after, limit);
        readers += 1;
        if (readers === 2) bothRead.resolve();
        await release;
        return page;
      } });
      const first = applyLog({ database: await openScoped(standby), link: sameRead(bothRead.promise), stateDirectory: standby });
      const second = applyLog({ database: await openScoped(standby), link: sameRead(firstDone.promise), stateDirectory: standby });
      assert.equal(await first, entries.length);
      firstDone.resolve();
      await assert.rejects(second, new RegExp(`Log entry ${contested.at} does not apply to a directory at position ${entries.length}`));
      assert.deepEqual(await readFile(join(standby, "feedback/latest")), newer, `the applier refused at entry ${contested.at} left the newer file`);
      assert.deepEqual(await readdir(join(standby, "feedback")), ["latest"], "no temporary file is left");
      assert.deepEqual(tables(standby), tables(directory));
      assert.equal(await follow(standby, link), entries.length);
      assert.deepEqual(tables(standby), tables(directory));
    }
  });

  test(`${name}: a standby holds each logged file at its path, and a blob that does not match its record is refused`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const alone = Buffer.from("invented feedback bundle"), carried = Buffer.from("invented attachment content");
    const owner = await openOwner(directory, link, { epoch });
    await owner.log.appendFiles([await stage(directory, link, "feedback/bundle.json", alone)]);
    owner.log.carry([await stage(directory, link, "attachments/a1/content", carried)]);
    await owner.root.submit(note("references the attachment", "request-1"), context);
    await owner.harness.close(context);

    const entries = await logEntries(link);
    assert.deepEqual(entries.filter((entry) => entry.files.length > 0).map((entry) => [entry.files.map((file) => file.path), entry.batch === null]),
      [[["feedback/bundle.json"], true], [["attachments/a1/content"], false]], "one file-only entry, and one entry with a file ahead of its batch");
    assert.deepEqual(await readFile(join(directory, "feedback/bundle.json")), alone);
    assert.deepEqual(await readFile(join(directory, "attachments/a1/content")), carried);
    assert.deepEqual((await readdir(join(directory, "feedback"))), ["bundle.json"], "the staged file took its final name");

    const fileEntry = entries.find((entry) => entry.files.length > 0);
    assert.ok(fileEntry);
    const damaged: AuthorityLink = { ...logThrough(link, entries.length), getBlob: async (sha256) => sha256 === fileEntry.files[0]?.sha256 ? Buffer.from("other bytes") : link.getBlob(sha256) };
    await assert.rejects(applyLog({ database: await openScoped(standby), link: damaged, stateDirectory: standby }), /blob for feedback\/bundle\.json does not match its record/);
    assert.equal(await position(standby), fileEntry.at - 1, "the position did not move");
    await assert.rejects(readFile(join(standby, "feedback/bundle.json")), { code: "ENOENT" });

    assert.equal(await follow(standby, link), entries.length);
    assert.deepEqual(await readFile(join(standby, "feedback/bundle.json")), alone);
    assert.deepEqual(await readFile(join(standby, "attachments/a1/content")), carried);
    assert.deepEqual(await readdir(join(standby, "feedback")), ["bundle.json"]);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: a crash between a file's append and its rename is repaired on reopen`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const bytes = Buffer.from("invented feedback bundle");
    const crash = new AbortController();
    const crashed = await openOwner(directory, link, { epoch, signal: crash.signal });
    link.afterApplied = (command) => {
      if (command.op !== "append") return;
      link.afterApplied = () => {};
      crash.abort();
      throw new AuthorityUnreachable("The process stopped before it read the reply");
    };
    await assert.rejects(crashed.log.appendFiles([await stage(directory, link, "feedback/bundle.json", bytes)]));
    await crashed.harness.close(context).catch(() => {});
    await assert.rejects(readFile(join(directory, "feedback/bundle.json")), { code: "ENOENT" });
    assert.equal((await logEntries(link)).at(-1)?.files[0]?.path, "feedback/bundle.json", "the log names the file");

    const reopened = await openOwner(directory, link, { epoch });
    t.after(() => reopened.harness.close(context));
    assert.deepEqual(await readFile(join(directory, "feedback/bundle.json")), bytes);
    assert.equal(reopened.log.head, (await link.record())?.state.head);
  });

  test(`${name}: a standby that stops after an entry's rename and before its commit finds the file present on the next follow`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const bytes = Buffer.from("invented feedback bundle"), path = join(standby, "feedback/bundle.json");
    const owner = await openOwner(directory, link, { epoch });
    await owner.log.appendFiles([await stage(directory, link, "feedback/bundle.json", bytes)]);
    await owner.harness.close(context);

    let stopped = false;
    const stopsAfterRename = (database: SqliteDatabase): SqliteDatabase => ({ exec: (sql) => database.exec(sql), run: (sql, ...params) => database.run(sql, ...params),
      runCounted: (sql, ...params) => database.runCounted(sql, ...params), get: (sql, ...params) => database.get(sql, ...params), all: (sql, ...params) => database.all(sql, ...params), close: () => database.close(),
      transaction: (callback) => database.transaction(async (transaction) => {
        const value = await callback(transaction);
        if (!stopped && existsSync(path)) { stopped = true; throw new Error("Invented: the process stopped before the transaction committed"); }
        return value;
      }) });
    await assert.rejects(applyLog({ database: await openScoped(standby, stopsAfterRename), link, stateDirectory: standby }), /stopped before the transaction committed/);
    assert.deepEqual(await readFile(path), bytes, "the rename happened inside the transaction");
    const fileEntry = (await logEntries(link)).find((entry) => entry.files.length > 0);
    assert.ok(fileEntry);
    assert.equal(await position(standby), fileEntry.at - 1, "the position did not move");

    assert.equal(await follow(standby, link), (await link.record())?.state.head);
    assert.deepEqual(await readFile(path), bytes);
    assert.deepEqual(await readdir(join(standby, "feedback")), ["bundle.json"]);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: an entry written by a Pi Durable or Chord this host does not replay is refused and the position does not move`, async (t) => {
    for (const [stamped, expected] of [[{ pi_durable: "9.9.9" }, /Pi Durable 9\.9\.9 and Chord 1\.7\.0, and this host runs Pi Durable 1\.7\.0 and Chord 1\.7\.0/],
      [{ chord: "9.9.9" }, /Pi Durable 1\.7\.0 and Chord 9\.9\.9, and this host runs/],
      [{ pi_durable: "1.4.0" }, /Pi Durable 1\.4\.0 and Chord 1\.7\.0, and this host runs/],
      [{ pi_durable: "1.5.2" }, /Pi Durable 1\.5\.2 and Chord 1\.7\.0, and this host runs/],
      [{ pi_durable: "1.6.0" }, /Pi Durable 1\.6\.0 and Chord 1\.7\.0, and this host runs/]] as const) {
      const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
      const owner = await openOwner(directory, link, { epoch });
      await owner.root.submit(note("first", "request-1"), context);
      await owner.harness.close(context);
      const head = (await link.record())?.state.head ?? 0;
      await appendStamped(link, epoch, head + 1, stamped);
      await assert.rejects(follow(standby, link), expected);
      assert.equal(await position(standby), head);
      assert.deepEqual(tables(standby), tables(directory), "every entry before the refused one applied");
    }
  });

  test(`${name}: an entry that does not match its digest is refused`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    await owner.root.submit(note("first", "request-1"), context);
    await owner.harness.close(context);
    const altered: AuthorityLink = { ...logThrough(link, (await link.record())?.state.head ?? 0), async log(after, limit) {
      const page = await link.log(after, limit);
      return { ...page, entries: page.entries.map((entry) => entry.batch?.body.kind === "inline" ? { ...entry, batch: { ...entry.batch, body: { kind: "inline", json: entry.batch.body.json.replace("first", "other") } } } : entry) };
    } };
    const alteredAt = (await logEntries(link)).find((entry) => entry.batch?.body.kind === "inline" && entry.batch.body.json.includes("first"))?.at;
    assert.ok(alteredAt);
    await assert.rejects(applyLog({ database: await openScoped(standby), link: altered, stateDirectory: standby }), new RegExp(`Log entry ${alteredAt} does not match its digest`));
    assert.equal(await position(standby), alteredAt - 1);
  });

  test(`${name}: a directory ahead of the log, and one behind its checkpoint, refuse to open`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), behind = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    await owner.root.submit(note("first", "request-1"), context);
    await owner.harness.close(context);
    const early = await follow(behind, link);

    const other = await connect(), otherEpoch = await enroll(other);
    const before = tables(directory);
    const ahead = new RegExp(`does not belong to this log: it is at position ${early}, and the log runs from 0 to 0`);
    await assert.rejects(openOwner(directory, other, { epoch: otherEpoch }), ahead);
    await assert.rejects(follow(directory, other), ahead);
    assert.deepEqual(tables(directory), before);

    const again = await openOwner(directory, link, { epoch });
    await again.root.submit(note("second", "request-2"), context);
    await again.harness.close(context);
    const head = (await link.record())?.state.head ?? 0;
    const snapshot = Buffer.from("invented backup manifest at the head");
    const checkpoint = { op: "checkpoint" as const, holder: OWNER, epoch, record: { through: head, manifest: sha256Hex(snapshot) } };
    assert.deepEqual(await link.command(checkpoint), { result: "refused", reason: "missing_blob", state: (await link.record())?.state }, "a manifest the blob store lacks is refused");
    await link.putBlob(sha256Hex(snapshot), snapshot);
    assert.equal((await link.command(checkpoint)).result, "accepted");
    const stale = tables(behind);
    const behindCheckpoint = new RegExp(`is at position ${early}, behind the checkpoint at ${head}, and the log no longer holds the entries between them. Rebuild it with \`beep-boop failover join --replace\``);
    await assert.rejects(follow(behind, link), behindCheckpoint);
    await assert.rejects(openOwner(behind, link, { epoch }), behindCheckpoint);
    assert.deepEqual(tables(behind), stale);
  });

  test(`${name}: a standby nobody restored a checkpoint into is refused, and never reported at the head`, async (t) => {
    const link = await connect(), epoch = await enroll(link), owner = await stateDirectory(t), unrestored = await unstampedDirectory(t);
    const opened = await openOwner(owner, link, { epoch });
    for (let index = 1; index <= 3; index += 1) await opened.root.submit(note(`acknowledged ${index}`, `request-${index}`), context);
    await opened.harness.close(context);
    const head = (await link.record())?.state.head ?? 0;
    const manifest = Buffer.from("invented backup manifest of the owner at the head");
    await link.putBlob(sha256Hex(manifest), manifest);
    assert.equal((await link.command({ op: "checkpoint", holder: OWNER, epoch, record: { through: head, manifest: sha256Hex(manifest) } })).result, "accepted");

    await assert.rejects(applyLog({ database: await openScoped(unrestored), link, stateDirectory: unrestored }), /holds no replication position/,
      `an empty standby must not report position ${head}, the head whose acknowledged commits it lacks`);
    assert.deepEqual(tables(unrestored), {}, "a refused standby is left without Pi's schema");
  });

  test(`${name}: a promoted standby reads an imported cold original from its own directory`, async (t) => {
    const { histories, entry, original } = await promotedHistory(t, await connect());
    assert.deepEqual(await histories.original(entry), original);
    assert.equal(await histories.indexText(entry), original.text);
  });

  test(`${name}: a promoted standby hands clients an asset path under its own directory`, async (t) => {
    const { entry, standby, path } = await promotedHistory(t, await connect());
    assert.deepEqual(entry.data.item.assets.map((asset) => asset.path), [join(standby, path)]);
    assert.ok((await readFile(join(standby, path))).byteLength > 0, "the handed path names a file the standby holds");
  });
}
