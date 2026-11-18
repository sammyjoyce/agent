import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { test } from "node:test";
import { appliedPosition, unfinishedEffects } from "../src/failover/state-directory.js";
import { stamp, unstampedDirectory } from "./fixtures/failover-state.js";

const HOLD_EXCLUSIVE = `
const { DatabaseSync } = require("node:sqlite");
const database = new DatabaseSync(process.argv[1]);
database.exec("PRAGMA journal_mode = DELETE; BEGIN EXCLUSIVE");
process.stdout.write("locked\\n");
setTimeout(() => { database.exec("COMMIT"); database.close(); }, 400);
`;

test("a read of the position waits for another process that holds the database, as a follow pass does", async (t) => {
  const directory = await unstampedDirectory(t);
  assert.equal(appliedPosition(directory), undefined, "a directory without a session database holds no position");
  assert.throws(() => unfinishedEffects(directory), /has no session\.sqlite/);
  await stamp(directory, 4);
  assert.equal(appliedPosition(directory), 4);

  const holder = spawn(process.execPath, ["-e", HOLD_EXCLUSIVE, `${directory}/session.sqlite`], { stdio: ["ignore", "pipe", "inherit"] });
  await once(holder.stdout, "data");
  const started = Date.now();
  assert.equal(appliedPosition(directory), 4, "the read waits for the lock and is not refused as locked");
  assert.ok(Date.now() - started >= 200, "the read happened while the other process still held the database");
  await once(holder, "close");
});
