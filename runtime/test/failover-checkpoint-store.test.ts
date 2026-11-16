import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { fetchCheckpoint, parseCheckpointManifest, readCheckpointManifest, storeCheckpoint } from "../src/failover/checkpoint-store.js";
import { sha256Hex } from "../src/failover/log-entry.js";
import { CHECKPOINT_PART_BYTES } from "../src/generated/failover-operator.js";
import { fingerprint } from "./fixtures/failover-hosts.js";
import { MemoryAuthority } from "./fixtures/failover-memory-authority.js";

const COORDINATOR = "11111111-1111-4111-8111-111111111111";
const HOLDER = "22222222-2222-4222-8222-222222222222";

async function directory(t: TestContext): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), "agent-checkpoint-"));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}

/** An archive with an empty file, a file smaller than a part, one that is exactly three parts and one that ends inside a part. */
async function archive(t: TestContext): Promise<string> {
  const root = join(await directory(t), "archive");
  await mkdir(join(root, "data", "history", "assets"), { recursive: true });
  await writeFile(join(root, "manifest.json"), "{\"invented\":true}");
  await writeFile(join(root, "data", "coordinator-id"), COORDINATOR);
  await writeFile(join(root, "data", "empty"), "");
  await writeFile(join(root, "data", "session.sqlite"), randomBytes(300));
  await writeFile(join(root, "data", "history", "assets", "ragged"), randomBytes(250));
  return root;
}

test("a checkpoint round trips through parts that each fit one request", async (t) => {
  const store = new MemoryAuthority(), source = await archive(t), target = join(await directory(t), "fetched");
  const stored = await storeCheckpoint(store, source, { through: 7, coordinator_id: COORDINATOR }, 100);
  assert.deepEqual({ files: stored.files, bytes: stored.bytes }, { files: 5, bytes: 17 + 36 + 0 + 300 + 250 });
  const manifest = await readCheckpointManifest(store, stored.manifest);
  assert.deepEqual({ format: manifest.format, through: manifest.through, coordinator_id: manifest.coordinator_id }, { format: 1, through: 7, coordinator_id: COORDINATOR });
  assert.deepEqual(Object.fromEntries(manifest.files.map((file) => [file.path, file.parts.length])),
    { "manifest.json": 1, "data/coordinator-id": 1, "data/empty": 0, "data/session.sqlite": 3, "data/history/assets/ragged": 3 });
  for (const sha256 of manifest.files.flatMap((file) => file.parts)) assert.ok((store.blobs.get(sha256)?.byteLength ?? 0) <= 100);

  assert.deepEqual(await fetchCheckpoint(store, manifest, target), { files: 5, bytes: stored.bytes });
  assert.deepEqual(await fingerprint(target), await fingerprint(source));
  assert.deepEqual(await storeCheckpoint(store, source, { through: 7, coordinator_id: COORDINATOR }, 100), stored, "storing the same archive again names the same manifest");
  await assert.rejects(storeCheckpoint(store, source, { through: 7, coordinator_id: COORDINATOR }, CHECKPOINT_PART_BYTES + 1), /A checkpoint part holds from 1 to/);
});

test("a part or a file that does not match its hash is refused, and the file never gets its name", async (t) => {
  const store = new MemoryAuthority(), source = await archive(t);
  const stored = await storeCheckpoint(store, source, { through: 0, coordinator_id: COORDINATOR }, 100);
  const manifest = await readCheckpointManifest(store, stored.manifest);
  const database = manifest.files.find((file) => file.path === "data/session.sqlite");
  assert.ok(database);
  const [first, second] = database.parts;
  assert.ok(first && second);

  const wrongPart = join(await directory(t), "fetched");
  store.blobs.set(second, randomBytes(100));
  await assert.rejects(fetchCheckpoint(store, manifest, wrongPart), new RegExp(`do not match part ${second} of data/session.sqlite`));
  assert.deepEqual((await readdir(join(wrongPart, "data"))).filter((name) => name === "session.sqlite"), [], "the refused file has no final name");

  const swapped = { ...manifest, files: manifest.files.map((file) => file === database ? { ...file, parts: [second, first, ...file.parts.slice(2)] } : file) };
  const good = new MemoryAuthority();
  await storeCheckpoint(good, source, { through: 0, coordinator_id: COORDINATOR }, 100);
  await assert.rejects(fetchCheckpoint(good, swapped, join(await directory(t), "fetched")), /parts of data\/session\.sqlite do not add up to the file/);

  const bytes = Buffer.from("not the manifest");
  good.blobs.set(stored.manifest, bytes);
  await assert.rejects(readCheckpointManifest(good, stored.manifest), /do not match checkpoint manifest/);
  assert.notEqual(sha256Hex(bytes), stored.manifest);
});

test("a checkpoint manifest is parsed strictly", () => {
  const file = { path: "data/session.sqlite", size: 3, sha256: "ab".repeat(32), parts: ["cd".repeat(32)] };
  const manifest = { format: 1, through: 0, coordinator_id: COORDINATOR, files: [file] };
  assert.deepEqual(parseCheckpointManifest(manifest), manifest);
  const refused: [string, unknown][] = [
    ["another format", { ...manifest, format: 2 }],
    ["an unknown field", { ...manifest, note: "invented" }],
    ["a missing position", { format: 1, coordinator_id: COORDINATOR, files: [] }],
    ["a path that leaves the archive", { ...manifest, files: [{ ...file, path: "data/../../auth.json" }] }],
    ["an absolute path", { ...manifest, files: [{ ...file, path: "/tmp/invented" }] }],
    ["a path named twice", { ...manifest, files: [file, file] }],
    ["a part that is no digest", { ...manifest, files: [{ ...file, parts: ["AB".repeat(32)] }] }],
    ["an unknown file field", { ...manifest, files: [{ ...file, mode: 0o600 }] }],
    ["a coordinator that is no UUID", { ...manifest, coordinator_id: "invented" }],
  ];
  for (const [label, value] of refused) assert.throws(() => parseCheckpointManifest(value), /The checkpoint manifest/, label);
});
