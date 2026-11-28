import assert from "node:assert/strict";
import { test, type TestContext } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteDatabase } from "@earendil-works/chord/sqlite";
import { defineDoc, type Seq, type Storage, type StorageWrite } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { openConversationDatabase } from "../src/conversation-database.js";
import { commitBatch, commitLoggedBatch, versions } from "../src/failover/log-entry.js";
import { PositionMissing, UnloggedWrite, type EntryApplication } from "../src/failover/scoped-database.js";
import { note, openPi, openScoped, sessionPath, stamp, stateDirectory, tables, unstampedDirectory } from "./fixtures/failover-state.js";

const Tally = defineDoc<{ count: number }>({ kind: "fixture.tally", scope: "session", version: 1, initial: () => ({ count: 0 }), checkpointWhen: () => false });

async function piBatches(t: TestContext): Promise<StorageWrite[][]> {
  const inner = await SqliteStorage.open(await openConversationDatabase(sessionPath(await stateDirectory(t))));
  const batches: StorageWrite[][] = [];
  const storage: Storage = new Proxy(inner, {
    get(target, name) {
      if (name === "commit") return (group: readonly (readonly StorageWrite[])[], receive: (index: number, seq: Seq) => void, context: typeof BACKGROUND_CONTEXT) => {
        batches.push(...group.map((writes) => [...writes]));
        return target.commit(group, receive, context);
      };
      const value: unknown = Reflect.get(target, name, target);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  const { harness, root } = await openPi(storage);
  await root.submit(note("first", "request-1"), BACKGROUND_CONTEXT);
  await harness.commit(async (tx) => { (await tx.doc(Tally)).count += 1; }, BACKGROUND_CONTEXT);
  await root.submit(note("second", "request-2"), BACKGROUND_CONTEXT);
  await harness.close(BACKGROUND_CONTEXT);
  return batches;
}

const withoutFiles = <T>(commit: () => Promise<T>): EntryApplication<T> => ({ publish: async () => {}, commit });

function counting(database: SqliteDatabase) {
  const counted = { transactions: 0, database: { exec: (sql) => database.exec(sql), run: (sql, ...params) => database.run(sql, ...params),
    runCounted: (sql, ...params) => database.runCounted(sql, ...params), get: (sql, ...params) => database.get(sql, ...params), all: (sql, ...params) => database.all(sql, ...params), close: () => database.close(),
    transaction: (callback) => { counted.transactions += 1; return database.transaction(callback); } } satisfies SqliteDatabase };
  return counted;
}

test("the dry-run contract was written for the installed Pi Durable and Chord", async () => {
  const installed = await versions();
  assert.equal(installed.pi_durable, "1.7.0", "Pi Durable changed: reread SqliteStorage.commit and rerun this file before trusting the barrier");
  assert.equal(installed.chord, "1.7.0", "Chord changed: reread its transaction contract before trusting the barrier");
  assert.equal(installed.application, "0.1.0");
});

test("a dry run returns the sequence the commit then assigns, changes no table, and each batch committed on its own is one transaction", async (t) => {
  const batches = await piBatches(t);
  assert.ok(batches.length >= 4, "the fixture produced Pi batches");
  const directory = await stateDirectory(t);
  let counted: ReturnType<typeof counting> | undefined;
  const database = await openScoped(directory, (raw) => (counted = counting(raw)).database);
  assert.ok(counted);
  const storage = await database.openStorage();
  t.after(() => storage.close(BACKGROUND_CONTEXT));
  for (const [index, batch] of batches.entries()) {
    const before = tables(directory);
    counted.transactions = 0;
    const predicted = await database.dryRun(() => commitBatch(storage, batch, BACKGROUND_CONTEXT));
    assert.equal(counted.transactions, 1, "the dry run of one batch is one transaction");
    assert.deepEqual(tables(directory), before, "a dry run leaves every table and durable_metadata unchanged");
    assert.ok(predicted.kind === "stored");
    counted.transactions = 0;
    assert.equal(await database.apply(index + 1, predicted.seq, withoutFiles(() => commitLoggedBatch(storage, batch, index + 1, BACKGROUND_CONTEXT))), predicted.seq);
    assert.equal(counted.transactions, 1, "one batch committed on its own is one transaction");
    assert.equal(await database.position(), index + 1);
  }
  assert.notDeepEqual(tables(directory).entries, []);
});

test("a batch Pi refuses is refused in the dry run and leaves the database unchanged", async (t) => {
  const batches = await piBatches(t), directory = await stateDirectory(t);
  const database = await openScoped(directory), storage = await database.openStorage();
  t.after(() => storage.close(BACKGROUND_CONTEXT));
  for (const [index, batch] of batches.entries()) await database.apply(index + 1, index + 1, withoutFiles(() => commitLoggedBatch(storage, batch, index + 1, BACKGROUND_CONTEXT)));
  const reused = batches.flat().find((write) => write.type === "entry");
  assert.ok(reused);
  const before = tables(directory);
  const refused = await database.dryRun(() => commitBatch(storage, [reused], BACKGROUND_CONTEXT));
  assert.ok(refused.kind === "refused" && refused.reason instanceof Error && /already belongs to entry/.test(refused.reason.message));
  assert.deepEqual(tables(directory), before);
});

test("an entry applies only at its own position and its own Pi sequence", async (t) => {
  const [first, second] = await piBatches(t), directory = await stateDirectory(t);
  assert.ok(first && second);
  const database = await openScoped(directory), storage = await database.openStorage();
  t.after(() => storage.close(BACKGROUND_CONTEXT));
  const empty = tables(directory);
  await assert.rejects(database.apply(2, 1, withoutFiles(() => commitLoggedBatch(storage, first, 1, BACKGROUND_CONTEXT))), /position 0/);
  await assert.rejects(database.apply(1, 2, withoutFiles(() => commitLoggedBatch(storage, first, 1, BACKGROUND_CONTEXT))), /Pi sequence 2/);
  assert.deepEqual(tables(directory), empty, "a refused entry rolls back whole");
  await database.apply(1, 1, withoutFiles(() => commitLoggedBatch(storage, first, 1, BACKGROUND_CONTEXT)));
  const applied = tables(directory);
  await assert.rejects(database.apply(1, 1, withoutFiles(() => commitLoggedBatch(storage, first, 1, BACKGROUND_CONTEXT))), /position 1/);
  assert.deepEqual(tables(directory), applied, "an entry does not apply twice");
  await database.apply(2, 2, withoutFiles(() => commitLoggedBatch(storage, second, 2, BACKGROUND_CONTEXT)));
  assert.equal(await database.position(), 2);
});

test("Pi reads a document inside a transaction, and a transaction outside the log can only read", async (t) => {
  const batches = await piBatches(t), directory = await stateDirectory(t);
  const database = await openScoped(directory), storage = await database.openStorage();
  t.after(() => storage.close(BACKGROUND_CONTEXT));
  for (const [index, batch] of batches.entries()) await database.apply(index + 1, index + 1, withoutFiles(() => commitLoggedBatch(storage, batch, index + 1, BACKGROUND_CONTEXT)));
  const created = batches.flat().find((write) => write.type === "document.create" && write.record.kind === "fixture.tally");
  assert.ok(created?.type === "document.create");
  assert.deepEqual((await storage.document(created.record.id, "current", BACKGROUND_CONTEXT))?.value, { count: 1 });
  const before = tables(directory);
  const change: StorageWrite[] = [{ type: "document.change", id: created.record.id, content: { version: 1, kind: "delta", ops: [["s", ["count"], 2]] } }];
  assert.deepEqual(await database.dryRun(() => commitBatch(storage, change, BACKGROUND_CONTEXT)), { kind: "stored", seq: batches.length + 1 }, "Pi accepts the batch");
  await assert.rejects(commitBatch(storage, change, BACKGROUND_CONTEXT), UnloggedWrite);
  await assert.rejects(database.transaction((transaction) => transaction.run("UPDATE durable_metadata SET next_seq = 99")), UnloggedWrite);
  await assert.rejects(database.run("UPDATE durable_metadata SET next_seq = 99"), UnloggedWrite);
  await assert.rejects(database.exec("DELETE FROM entries"), UnloggedWrite);
  await assert.rejects(database.get("UPDATE durable_metadata SET next_seq = 99 RETURNING next_seq"), UnloggedWrite);
  assert.deepEqual(tables(directory), before);
  assert.equal((await database.transaction((transaction) => transaction.get<{ next_seq: number }>("SELECT next_seq FROM durable_metadata")))?.next_seq, batches.length + 1);
});

test("a directory opens only after it was stamped, and a stamp never moves a position", async (t) => {
  const directory = await unstampedDirectory(t);
  await assert.rejects(async () => (await openScoped(directory)).openStorage(), (error) =>
    error instanceof PositionMissing && /beep-boop failover enroll/.test(error.message) && /beep-boop failover join/.test(error.message));
  assert.deepEqual(tables(directory), {}, "a refused open leaves the database without Pi's schema");
  await stamp(directory, 3);
  await stamp(directory, 3);
  await assert.rejects(stamp(directory, 4), /is at replication position 3, so it cannot be stamped at 4/);
  const database = await openScoped(directory), storage = await database.openStorage();
  t.after(() => storage.close(BACKGROUND_CONTEXT));
  assert.equal(await database.position(), 3);
});
