import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { openReplicatedStorage } from "../src/failover/replicated-storage.js";
import { appliedPosition, lastPiSequence } from "../src/failover/state-directory.js";
import type { LogEntry } from "../src/generated/LogEntry.js";
import { authorities, enroll, follow, logEntries, openPi, openScoped, OWNER, retainedFiles, stateDirectory, tables, type TestAuthority } from "./fixtures/failover-state.js";

const context = BACKGROUND_CONTEXT;
const fixture = new URL("../../test/fixtures/failover-log-1.4.0/", import.meta.url);
const fixtureJson = async (name: string): Promise<unknown> => JSON.parse(await readFile(new URL(name, fixture), "utf8"));

async function writtenBy140(link: TestAuthority): Promise<LogEntry[]> {
  const entries = (await readFile(new URL("log.jsonl", fixture), "utf8")).trim().split("\n").map((line) => JSON.parse(line) as LogEntry);
  for (const name of await readdir(new URL("blobs/", fixture))) await link.putBlob(name, await readFile(new URL(`blobs/${name}`, fixture)));
  for (const entry of entries) assert.equal((await link.command({ op: "append", holder: OWNER, entry })).result, "accepted");
  return entries;
}

for (const [name, connect] of Object.entries(authorities)) {
  test(`${name}: a log that Pi Durable 1.4.0 wrote replays on 1.5.2 to the tables its owner wrote, and an owner continues it`, async (t) => {
    const link = await connect(), epoch = await enroll(link);
    const written = await writtenBy140(link);
    assert.ok(written.every((entry) => entry.versions.pi_durable === "1.4.0" && entry.versions.chord === "1.4.0"));
    const ownerTables = await fixtureJson("owner-tables.json"), ownerFiles = await fixtureJson("owner-files.json");

    const upgraded = await stateDirectory(t);
    assert.equal(await follow(upgraded, link), written.length);
    assert.deepEqual(tables(upgraded), ownerTables, "a standby replays every 1.4.0 entry to the rows the 1.4.0 owner wrote");
    assert.deepEqual(await retainedFiles(upgraded), ownerFiles);

    const directory = await stateDirectory(t);
    const { storage, log } = await openReplicatedStorage({ database: await openScoped(directory), link, holder: OWNER, epoch, stateDirectory: directory, onFenced: () => {} });
    assert.equal(log.head, written.length, "the owner caught up with the 1.4.0 log before Pi opened");
    assert.deepEqual(tables(directory), ownerTables);
    const { harness, root, faux } = await openPi(storage);
    faux.setResponses(Array.from({ length: 3 }, () => fauxAssistantMessage("Invented: water the beds at dawn.")));
    const watering = await root.submit({ type: "input", content: "Water the garden.", requestId: "request-water" }, context);
    await watering.wait(context);
    await harness.close(context);

    const continued = (await logEntries(link)).slice(written.length);
    assert.ok(continued.length > 0 && continued.every((entry) => entry.versions.pi_durable === "1.5.2"), "the owner continued the log on Pi Durable 1.5.2");
    const head = (await link.record())?.state.head;
    assert.equal(await follow(upgraded, link), head);
    assert.deepEqual(tables(upgraded), tables(directory), "a standby that replayed the 1.4.0 entries follows the 1.5.2 ones");
    const joined = await stateDirectory(t);
    assert.equal(await follow(joined, link), head);
    assert.deepEqual(tables(joined), tables(directory), "a standby replays the whole mixed log");
    assert.equal(appliedPosition(joined), head);
    assert.equal(lastPiSequence(joined), (await logEntries(link)).findLast((entry) => entry.batch !== null)?.batch?.pi_seq,
      "promotion finds the Pi sequence of the last logged batch");
  });
}
