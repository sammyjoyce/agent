import assert from "node:assert/strict";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { test } from "node:test";
import { beginUpload, writeChunk } from "../src/attachment-upload.js";
import type { CheckpointManifest } from "../src/generated/CheckpointManifest.js";
import { startFaultProxy } from "./fixtures/failover-fault-proxy.js";
import { exists, fingerprint, HOLDERS, ownerActivity, sha256, World, type CheckpointedReceipt, type EnrolledReceipt, type FollowedReceipt,
  type JoinedReceipt, type StatusReceipt } from "./fixtures/failover-hosts.js";
import { logEntries, retainedFiles, tables } from "./fixtures/failover-state.js";

const [OWNER, STANDBY, THIRD] = HOLDERS;
const FEEDBACK = "feedback/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.json";

const COMPLETE = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const UNFINISHED = ["eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "ffffffff-ffff-4fff-8fff-ffffffffffff"] as const;

const metadata = (id: string, content: Buffer, complete: boolean) => ({ attachment: { id, name: "invented.txt", media_type: "text/plain",
  size_bytes: content.length, sha256: sha256(content) }, retained: true, complete, created: 1 });

async function place(state: string, path: string, bytes: Buffer): Promise<void> {
  await mkdir(dirname(join(state, path)), { recursive: true, mode: 0o700 });
  await writeFile(join(state, path), bytes, { mode: 0o600 });
}

/** What a crash leaves under the retained trees: an upload that never completed, content without metadata, and temporary files. */
async function leaveDebris(state: string, upload: string): Promise<void> {
  const half = Buffer.from("Invented half of an upload"), folder = join(state, "attachments", upload);
  await beginUpload(folder, { ...metadata(upload, half, false), complete: false });
  assert.equal(await writeChunk(join(folder, "content"), 0, half), true);
  await place(state, `attachments/${upload}/.${upload}.tmp`, half);
  await place(state, `feedback/.${upload}.tmp`, half);
  await place(state, `history/assets/.${upload}.tmp`, half);
}

async function manifestOf(link: { getBlob(sha256: string): Promise<Uint8Array> }, sha256: string): Promise<CheckpointManifest> {
  return JSON.parse(Buffer.from(await link.getBlob(sha256)).toString("utf8")) as CheckpointManifest;
}

test("a checkpoint is stored in parts and replaces the log entries it covers", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);

  await t.test("a database larger than one part enrolls and joins, and a part with wrong bytes publishes nothing", async (t) => {
    const coordinator = world.coordinator(), proxy = await startFaultProxy(t, world.authorityUrl);
    const owner = await world.host(coordinator, OWNER), standby = await world.host(coordinator, STANDBY, proxy.url);
    await owner.create();
    const enrolled = await owner.receipt<EnrolledReceipt>("enroll", "--part-bytes", "8192");
    const manifest = await manifestOf(owner.link, enrolled.checkpoint.manifest);
    const database = manifest.files.find((file) => file.path === "data/session.sqlite");
    assert.ok(database !== undefined && database.parts.length >= 4, `the database spans several parts: ${database?.parts.length}`);
    assert.equal(database.parts.length, Math.ceil(database.size / 8192));
    assert.ok(manifest.files.some((file) => file.path === "manifest.json"), "the checkpoint carries the archive's own manifest");

    const damaged = database.parts[2];
    assert.ok(damaged);
    proxy.inject({ fault: { kind: "corrupt" }, match: ({ method, path }) => method === "GET" && path.endsWith(`/blobs/${damaged}`) });
    const refused = await standby.failover("join", coordinator);
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, new RegExp(`do not match part ${damaged} of data/session.sqlite`));
    assert.equal(await exists(standby.state), false, "a refused join publishes no state directory");
    assert.deepEqual((await readdir(standby.home)).filter((name) => name.includes("state")), [], "a refused join leaves no partial download");

    proxy.heal();
    await standby.receipt<JoinedReceipt>("join", coordinator);
    assert.deepEqual(tables(standby.state), tables(owner.state));
  });

  await t.test("a checkpoint drops the log it covers, a fresh standby joins from it, and one behind it must rejoin", async () => {
    const coordinator = world.coordinator();
    const owner = await world.host(coordinator, OWNER), behind = await world.host(coordinator, STANDBY), fresh = await world.host(coordinator, THIRD);
    await owner.create();
    await owner.receipt<EnrolledReceipt>("enroll");
    await behind.receipt<JoinedReceipt>("join", coordinator);
    const asset = Buffer.from("Invented cold original");
    const epoch = await ownerActivity(owner, ["first", "second"], { [FEEDBACK]: "Invented feedback bundle", [`history/assets/${sha256(asset)}`]: asset.toString() });
    const head = (await owner.authorityState()).head;
    assert.ok(head >= 3);

    const stored = await owner.receipt<CheckpointedReceipt>("checkpoint");
    assert.equal(stored.checkpoint.through, head);
    assert.equal(stored.epoch, epoch + 1, "a checkpoint claims the next epoch");
    assert.deepEqual(await owner.record(), { state: { kind: "active", epoch: epoch + 1, holder: OWNER, head }, checkpoint: stored.checkpoint });
    assert.deepEqual(await logEntries(owner.link), [], "the log holds no entry at or before the checkpoint");

    const joined = await fresh.receipt<JoinedReceipt>("join", coordinator);
    assert.equal(joined.through, head);
    assert.deepEqual(tables(fresh.state), tables(owner.state));
    assert.deepEqual(await retainedFiles(fresh.state), await retainedFiles(owner.state));
    assert.equal(Object.keys(await retainedFiles(fresh.state)).length, 2, "the checkpoint carries the replicated files");
    assert.equal((await fresh.receipt<StatusReceipt>("status")).applied, head);

    await ownerActivity(owner, ["third"], { "feedback/invented-unknown-name.json": "A name no backup carries" });
    const leftOut = await owner.failover("checkpoint");
    assert.notEqual(leftOut.code, 0);
    assert.match(leftOut.stderr, /would leave out feedback\/invented-unknown-name\.json/);
    assert.deepEqual((await owner.record())?.checkpoint, stored.checkpoint, "a refused checkpoint leaves the stored one in place");
    assert.equal((await fresh.receipt<FollowedReceipt>("follow", "--once")).from, head);
    assert.deepEqual(tables(fresh.state), tables(owner.state), "a standby that joined at the checkpoint follows the entries after it");

    const stale = tables(behind.state);
    const rejoin = await behind.failover("follow", "--once");
    assert.notEqual(rejoin.code, 0);
    assert.match(rejoin.stderr, /behind the checkpoint at \d+.*beep-boop failover join --replace/);
    assert.deepEqual(tables(behind.state), stale, "a refused follow applies nothing");

    const before = await fingerprint(behind.state);

    const replaced = await behind.receipt<JoinedReceipt>("join", coordinator, "--replace");
    assert.ok(replaced.replaced !== null && dirname(replaced.replaced) === behind.home && basename(replaced.replaced).startsWith("state.replaced-"), JSON.stringify(replaced));
    const kept = await fingerprint(replaced.replaced);
    assert.deepEqual(kept, before, "the replaced directory keeps its bytes under its new name");
    assert.equal(await readFile(join(behind.state, "coordinator-id"), "utf8"), coordinator);
    await behind.receipt<FollowedReceipt>("follow", "--once");
    assert.deepEqual(tables(behind.state), tables(owner.state));
  });

  await t.test("enroll and checkpoint leave out an unfinished upload, a temporary file and dreams/, and a standby holds exactly the files the checkpoint and the log name", async () => {
    const coordinator = world.coordinator();
    const owner = await world.host(coordinator, OWNER), early = await world.host(coordinator, STANDBY), late = await world.host(coordinator, THIRD);
    await owner.create();
    const attachment = Buffer.from("Invented complete attachment"), asset = Buffer.from("Invented cold original before enrollment");
    const kept = { [`attachments/${COMPLETE}/content`]: attachment,
      [`attachments/${COMPLETE}/metadata.json`]: Buffer.from(JSON.stringify(metadata(COMPLETE, attachment, true))),
      [`history/assets/${sha256(asset)}`]: asset, [FEEDBACK]: Buffer.from("Invented feedback bundle"), "feedback/latest": Buffer.from("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb") };
    for (const [path, bytes] of Object.entries(kept)) await place(owner.state, path, bytes);
    await leaveDebris(owner.state, UNFINISHED[0]);
    await place(owner.state, "dreams/invented-night.json", Buffer.from("Invented review of a quiet night"));
    const named = async (record: { manifest: string }) => (await manifestOf(owner.link, record.manifest)).files
      .map((file) => file.path).filter((path) => /^data\/(attachments|history|feedback)\//.test(path)).map((path) => path.slice("data/".length)).sort();
    const retained = async (state: string) => Object.keys(await retainedFiles(state)).sort();

    const enrolled = await owner.receipt<EnrolledReceipt>("enroll");
    assert.deepEqual(enrolled.uploaded?.not_included, ["dreams"], "the receipt names what the checkpoint does not carry");
    assert.deepEqual(await named(enrolled.checkpoint), Object.keys(kept).sort(), "the checkpoint names the complete files and no other");
    await early.receipt<JoinedReceipt>("join", coordinator);
    assert.deepEqual(await retained(early.state), Object.keys(kept).sort());
    assert.equal(await exists(join(early.state, "dreams")), false, "a standby gets no dreams/ directory");

    const logged = "feedback/cccccccc-cccc-4ccc-8ccc-cccccccccccc.json", after = [...Object.keys(kept), logged].sort();
    await ownerActivity(owner, ["first"], { [logged]: "Invented feedback bundle after enrollment" });
    await leaveDebris(owner.state, UNFINISHED[1]);
    await early.receipt<FollowedReceipt>("follow", "--once");
    assert.deepEqual(await retained(early.state), after, "a follower holds the checkpoint's files and the log's");

    const stored = await owner.receipt<CheckpointedReceipt>("checkpoint");
    assert.deepEqual(stored.uploaded.not_included, ["dreams"]);
    assert.deepEqual(await named(stored.checkpoint), after);
    await late.receipt<JoinedReceipt>("join", coordinator);
    assert.deepEqual(await retained(late.state), after);
    assert.deepEqual(await retainedFiles(late.state), await retainedFiles(early.state), "a standby that joined later holds the bytes one that followed holds");
    const owned = await retainedFiles(owner.state);
    for (const [path, digest] of Object.entries(await retainedFiles(late.state))) assert.equal(digest, owned[path], path);
    assert.deepEqual(tables(late.state), tables(owner.state));
  });
});
