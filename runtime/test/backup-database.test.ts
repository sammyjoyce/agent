import assert from "node:assert/strict";
import { copyFile, mkdtemp, readdir, rm } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { test } from "node:test";
import { CURRENT_SQLITE_SCHEMA_VERSION } from "@earendil-works/pi-durable/storage/sqlite";
import { answerDatabaseRequest } from "../src/backup-database.js";

async function scratch(t: { after(callback: () => Promise<void>): void }): Promise<string> {
  const directory = await mkdtemp("/tmp/agent-backup-database-");
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test("a snapshot of a killed writer's store carries its uncheckpointed WAL frames as one self-contained file", async (t) => {
  const directory = await scratch(t);
  const live = join(directory, "live.sqlite"), killed = join(directory, "killed.sqlite"), snapshot = join(directory, "snapshot.sqlite");
  const writer = new DatabaseSync(live);
  try {
    writer.exec("PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0");
    writer.exec("CREATE TABLE durable_schema (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), version INTEGER NOT NULL) STRICT");
    writer.exec(`INSERT INTO durable_schema (singleton, version) VALUES (1, ${CURRENT_SQLITE_SCHEMA_VERSION})`);
    writer.exec("CREATE TABLE invented_ledger (line TEXT NOT NULL)");
    writer.prepare("INSERT INTO invented_ledger (line) VALUES (?)").run("committed only in the WAL");
    await copyFile(live, killed); await copyFile(`${live}-wal`, `${killed}-wal`);
  } finally { writer.close(); }

  const report = await answerDatabaseRequest({ type: "snapshot", source: killed, snapshot });
  assert.deepEqual(report.integrity, ["ok"]);
  assert.equal(report.journal_mode, "delete");
  assert.equal(report.schema_version, CURRENT_SQLITE_SCHEMA_VERSION);
  assert.equal(report.supported_schema_version, CURRENT_SQLITE_SCHEMA_VERSION);
  assert.match(report.pi_durable_version, /^\d+\.\d+\.\d+/);
  assert.deepEqual((await readdir(directory)).filter((name) => name.startsWith("snapshot.sqlite")), ["snapshot.sqlite"], "the snapshot has no sidecars");

  const restored = new DatabaseSync(snapshot, { readOnly: true });
  try { assert.deepEqual(restored.prepare("SELECT line FROM invented_ledger").all().map((row) => row.line), ["committed only in the WAL"]); }
  finally { restored.close(); }
  assert.deepEqual(await answerDatabaseRequest({ type: "inspect", database: snapshot }), report);
});

test("inspect reports a SQLite file that is not a Pi Durable store", async (t) => {
  const directory = await scratch(t);
  const path = join(directory, "plain.sqlite");
  const plain = new DatabaseSync(path);
  try { plain.exec("CREATE TABLE invented_notes (body TEXT)"); } finally { plain.close(); }
  const report = await answerDatabaseRequest({ type: "inspect", database: path });
  assert.equal(report.schema_version, null);
  assert.deepEqual(report.integrity, ["ok"]);
});
