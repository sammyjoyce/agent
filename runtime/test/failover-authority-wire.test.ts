import assert from "node:assert/strict";
import test from "node:test";
import { parseAuthorityCommand, parseAuthorityRecord, parseAuthorityReply, parseLogPage } from "../src/failover/authority-wire.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../src/generated/AuthorityRecord.js";
import type { AuthorityRefusal } from "../src/generated/AuthorityRefusal.js";
import type { AuthorityReply } from "../src/generated/AuthorityReply.js";
import type { AuthorityState } from "../src/generated/AuthorityState.js";
import type { LogPage } from "../src/generated/LogPage.js";
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

type Malformed = readonly (readonly [field: string, value: unknown])[];

function assertRefusedNamingField(parse: (value: unknown) => unknown, table: Malformed): void {
  for (const [field, value] of table) {
    assert.throws(() => parse(value), (error: unknown) => {
      assert.ok(error instanceof Error, `${JSON.stringify(value)} threw something other than an Error`);
      assert.ok(error.message.includes(field), `the message "${error.message}" does not name ${field}`);
      return true;
    }, `${field} in ${JSON.stringify(value)} was accepted`);
  }
}

const malformed: Malformed = [
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
  assertRefusedNamingField(parseAuthorityCommand, malformed);
});

const active: AuthorityState = { kind: "active", epoch: 3, holder: tarantula, head: 2 };
const sealed: AuthorityState = { kind: "sealed", epoch: 3, holder: tarantula, candidate: orion, head: 2 };
const vacant: AuthorityState = { kind: "vacant", epoch: 3, candidate: orion, evidence: { kind: "operator_attested", statement: "the old host is powered off" }, head: 2 };
const states: readonly AuthorityState[] = [active, sealed, vacant,
  { ...vacant, evidence: { kind: "released" } }, { ...vacant, evidence: { kind: "lock_held" } }];
const refusals = Object.keys({ not_enrolled: 0, enrolled: 0, sealed: 0, fenced: 0, gap: 0, conflict: 0, missing_blob: 0, epoch_moved: 0, already_owner: 0,
  self_attestation: 0, not_sealed: 0, not_sealed_holder: 0, not_candidate: 0, not_caught_up: 0, checkpoint_out_of_range: 0 } satisfies Record<AuthorityRefusal, 0>) as AuthorityRefusal[];
const record: AuthorityRecord = { state: active, checkpoint: { through: 1, manifest } };

const wellFormedReplies: readonly AuthorityReply[] = [
  ...states.map((state) => ({ result: "accepted", state }) as const),
  ...refusals.map((reason) => ({ result: "refused", reason, state: sealed }) as const),
  { result: "refused", reason: "not_enrolled", state: null },
];
const wellFormedRecords: readonly AuthorityRecord[] = states.map((state) => ({ state, checkpoint: { through: 1, manifest } }));
const wellFormedPages: readonly LogPage[] = [
  { record, entries: [] },
  { record, entries: wellFormed.flatMap((command) => command.op === "append" ? [command.entry] : []) },
];

test("every well-formed reply, record and log page is accepted unchanged", () => {
  const roundTrip = (value: unknown): unknown => JSON.parse(JSON.stringify(value));
  for (const reply of wellFormedReplies) assert.deepEqual(parseAuthorityReply(roundTrip(reply)), reply);
  for (const each of wellFormedRecords) assert.deepEqual(parseAuthorityRecord(roundTrip(each)), each);
  for (const page of wellFormedPages) assert.deepEqual(parseLogPage(roundTrip(page)), page);
  assert.equal(wellFormedPages[1]?.entries.length, 3, "the page holds the table's three appends");
});

const accepted = (state: unknown) => ({ result: "accepted", state });

const malformedReplies: Malformed = [
  ["reply", null],
  ["reply", "accepted"],
  ["reply", [accepted(active)]],
  ["result", { state: active }],
  ["result", { result: "maybe", state: active }],
  ["state", { result: "accepted" }],
  ["state", accepted(null)],
  ["extra", { ...accepted(active), extra: 1 }],
  ["state.kind", accepted({ ...active, kind: "paused" })],
  ["state.epoch", accepted({ ...active, epoch: -1 })],
  ["state.epoch", accepted({ ...active, epoch: "3" })],
  ["state.holder", accepted({ ...active, holder: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE" })],
  ["state.head", accepted(without(active, "head"))],
  ["state.candidate", accepted({ ...active, candidate: orion })],
  ["state.candidate", accepted(without(sealed, "candidate"))],
  ["state.evidence", accepted(without(vacant, "evidence"))],
  ["state.evidence.kind", accepted({ ...vacant, evidence: { kind: "timed_out" } })],
  ["state.evidence.statement", accepted({ ...vacant, evidence: { kind: "operator_attested" } })],
  ["state.evidence.statement", accepted({ ...vacant, evidence: { kind: "released", statement: "invented" } })],
  ["reason", { result: "refused", state: null }],
  ["reason", { result: "refused", reason: "busy", state: null }],
  ["state", { result: "refused", reason: "fenced" }],
  ["state.head", { result: "refused", reason: "fenced", state: { ...active, head: 2 ** 53 } }],
];

const malformedRecords: Malformed = [
  ["record", null],
  ["record", [record]],
  ["state", { checkpoint: record.checkpoint }],
  ["checkpoint", { state: active }],
  ["state.kind", { ...record, state: { ...active, kind: undefined } }],
  ["checkpoint.through", { ...record, checkpoint: { through: 1.5, manifest } }],
  ["checkpoint.manifest", { ...record, checkpoint: { through: 1, manifest: manifest.toUpperCase() } }],
  ["head", { ...record, head: 2 }],
];

const malformedPages: Malformed = [
  ["log page", null],
  ["log page", "[]"],
  ["record", { entries: [] }],
  ["entries", { record }],
  ["entries", { record, entries: {} }],
  ["record.state.holder", { record: { ...record, state: { ...active, holder: "tarantula" } }, entries: [] }],
  ["entries[0].digest", { record, entries: [{ ...entry(1, 1, digests[0]), digest: "a".repeat(63) }] }],
  ["entries[1].batch.pi_seq", { record, entries: [entry(1, 1, digests[0]), { ...entry(1, 2, digests[1]), batch: { body: { kind: "inline", json: "[]" } } }] }],
  ["entries[0].files[0].size", { record, entries: [{ ...entry(1, 1, digests[0]), files: [{ ...file, size: 2 ** 53 }] }] }],
  ["cursor", { record, entries: [], cursor: 3 }],
];

test("a malformed reply, record or log page is refused with a message that names the bad field", () => {
  assertRefusedNamingField(parseAuthorityReply, malformedReplies);
  assertRefusedNamingField(parseAuthorityRecord, malformedRecords);
  assertRefusedNamingField(parseLogPage, malformedPages);
});
