import assert from "node:assert/strict";
import test from "node:test";
import { parseAuthorityCommand } from "../src/failover/authority-wire.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import { digests, entry, manifest, orion, tarantula } from "./fixtures/failover-authority-cells.js";

const file = { path: "attachments/a1/content", sha256: digests[1], size: 12 };
const wellFormed: readonly AuthorityCommand[] = [
  { op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest } },
  { op: "claim", holder: tarantula },
  { op: "append", holder: tarantula, entry: entry(1, 1, digests[0]) },
  { op: "append", holder: tarantula, entry: { ...entry(1, 2, digests[0]), batch: null, files: [file, { ...file, path: "history/assets/ab/cd.png" }, { ...file, path: "feedback/latest" }] } },
  { op: "append", holder: tarantula, entry: { ...entry(1, 3, digests[0]), files: [file], batch: { pi_seq: 9_007_199_254_740_991, body: { kind: "blob", sha256: digests[1], size: 9_007_199_254_740_991 } } } },
  { op: "confirm", holder: tarantula, epoch: 9_007_199_254_740_991 },
  { op: "promote", candidate: orion, expected_epoch: 1, attestation: null },
  { op: "promote", candidate: orion, expected_epoch: 1, attestation: "the old host is powered off" },
  { op: "release", holder: tarantula, epoch: 1, evidence: "released" },
  { op: "release", holder: tarantula, epoch: 1, evidence: "lock_held" },
  { op: "activate", candidate: orion, applied: 0 },
  { op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 2, manifest } },
];

test("every well-formed command is accepted unchanged", () => {
  const operations = new Set(wellFormed.map((command) => command.op));
  assert.equal(operations.size, 8, "the table misses an operation");
  for (const command of wellFormed) {
    assert.deepEqual(parseAuthorityCommand(JSON.parse(JSON.stringify(command))), command);
  }
});

const claim = { op: "claim", holder: tarantula };
const append = { op: "append", holder: tarantula, entry: entry(1, 1, digests[0]) };
const withEntry = (change: Record<string, unknown>) => ({ ...append, entry: { ...append.entry, ...change } });
const withFile = (change: Record<string, unknown>) => withEntry({ files: [{ ...file, ...change }] });
const withBatch = (change: Record<string, unknown>) => withEntry({ batch: { ...append.entry.batch, ...change } });
const promote = { op: "promote", candidate: orion, expected_epoch: 1, attestation: null };
const without = <T extends object>(value: T, field: keyof T) => Object.fromEntries(Object.entries(value).filter(([key]) => key !== field));

const malformed: readonly (readonly [field: string, value: unknown])[] = [
  ["command", null],
  ["command", [claim]],
  ["command", "claim"],
  ["op", { holder: tarantula }],
  ["op", { ...claim, op: "seize" }],
  ["op", { ...claim, op: 1 }],
  ["extra", { ...claim, extra: 1 }],
  ["__proto__", JSON.parse(`{"op":"claim","holder":"${tarantula}","__proto__":{}}`)],
  ["holder", { op: "claim" }],
  ["holder", { op: "claim", holder: "tarantula" }],
  ["holder", { op: "claim", holder: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE" }],
  ["holder", { op: "claim", holder: `{${tarantula}}` }],
  ["candidate", { op: "activate", candidate: 7, applied: 0 }],
  ["applied", { op: "activate", candidate: orion, applied: null }],
  ["epoch", { op: "confirm", holder: tarantula, epoch: -1 }],
  ["epoch", { op: "confirm", holder: tarantula, epoch: 9_007_199_254_740_992 }],
  ["epoch", { op: "confirm", holder: tarantula, epoch: 1.5 }],
  ["epoch", { op: "confirm", holder: tarantula, epoch: "1" }],
  ["expected_epoch", without(promote, "expected_epoch")],
  ["attestation", without(promote, "attestation")],
  ["attestation", { ...promote, attestation: "" }],
  ["attestation", { ...promote, attestation: " \n\t" }],
  ["attestation", { ...promote, attestation: 1 }],
  ["evidence", { op: "release", holder: tarantula, epoch: 1, evidence: "operator_attested" }],
  ["evidence", { op: "release", holder: tarantula, epoch: 1, evidence: { kind: "released" } }],
  ["checkpoint", { op: "enroll", holder: tarantula }],
  ["checkpoint.manifest", { op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest: manifest.toUpperCase() } }],
  ["checkpoint.size", { op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest, size: 1 } }],
  ["record.through", { op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 2 ** 53, manifest } }],
  ["entry", { op: "append", holder: tarantula, entry: [] }],
  ["entry.at", { ...append, entry: without(append.entry, "at") }],
  ["entry.head", withEntry({ head: 1 })],
  ["entry.digest", withEntry({ digest: "a".repeat(63) })],
  ["entry.digest", withEntry({ digest: "g".repeat(64) })],
  ["entry.versions.chord", withEntry({ versions: { application: "0.1.0", pi_durable: "1.4.0", chord: 1 } })],
  ["entry.versions.pi", withEntry({ versions: { application: "0.1.0", pi_durable: "1.4.0", chord: "1.4.0", pi: "1" } })],
  ["entry.files", withEntry({ files: {} })],
  ["entry.files[0]", withEntry({ files: ["attachments/a"] })],
  ...["/attachments/a", "attachments", "attachments/", "attachments/../auth.json", "attachments//a", "attachments/./a",
    "history/index.sqlite", "auth.json", "feedbacks/a", "attachments\\a", "attachments/a\0", "history/assets"]
    .map((path) => ["entry.files[0].path", withFile({ path })] as const),
  ["entry.files[0].sha256", withFile({ sha256: digests[1].toUpperCase() })],
  ["entry.files[0].size", withFile({ size: 2 ** 53 })],
  ["entry.files[0].mode", withFile({ mode: 0o600 })],
  ["entry.batch", { ...append, entry: without(append.entry, "batch") }],
  ["entry.pi_seq", withEntry({ pi_seq: 4, batch: null })],
  ["entry.batch.pi_seq", withEntry({ batch: { body: { kind: "inline", json: "[]" } } })],
  ["entry.batch.pi_seq", withBatch({ pi_seq: -1 })],
  ["entry.batch.body", withBatch({ body: null })],
  ["entry.batch.kind", withEntry({ batch: { kind: "inline", json: "[]" } })],
  ["entry.batch.body.kind", withBatch({ body: { kind: "zip", json: "[]" } })],
  ["entry.batch.body.json", withBatch({ body: { kind: "inline" } })],
  ["entry.batch.body.json", withBatch({ body: { kind: "inline", json: [] } })],
  ["entry.batch.body.sha256", withBatch({ body: { kind: "blob", sha256: "x", size: 1 } })],
  ["entry.batch.body.json", withBatch({ body: { kind: "blob", sha256: digests[0], size: 1, json: "[]" } })],
];

test("a malformed command is refused with a message that names the bad field", () => {
  for (const [field, value] of malformed) {
    assert.throws(() => parseAuthorityCommand(value), (error: unknown) => {
      assert.ok(error instanceof Error, `${JSON.stringify(value)} threw something other than an Error`);
      assert.ok(error.message.includes(field), `the message "${error.message}" does not name ${field}`);
      return true;
    }, `${field} in ${JSON.stringify(value)} was accepted`);
  }
});
