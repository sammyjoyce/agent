import { createHash } from "node:crypto";
import type { AuthorityCommand } from "../../src/generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../../src/generated/AuthorityRecord.js";
import type { AuthorityRefusal } from "../../src/generated/AuthorityRefusal.js";
import type { AuthorityState } from "../../src/generated/AuthorityState.js";
import type { LogEntry } from "../../src/generated/LogEntry.js";
import { logEntryDigest } from "../../src/failover/log-entry.js";

export const tarantula = "11111111-1111-4111-8111-111111111111";
export const orion = "22222222-2222-4222-8222-222222222222";
export const spare = "33333333-3333-4333-8333-333333333333";
export const holders = [tarantula, orion, spare] as const;
export const digests = ["a".repeat(64), "b".repeat(64)] as const;
/** An invented backup manifest. A test stores it as a blob before it enrolls or checkpoints through an authority with a blob store. */
export const manifestBytes = Buffer.from(JSON.stringify({ invented: "backup manifest", files: [] }));
export const manifest = createHash("sha256").update(manifestBytes).digest("hex");
export const versions = { application: "0.1.0", pi_durable: "1.4.0", chord: "1.4.0" };

/** An entry with the digest of its fields, which the Worker requires of every append. */
export const digested = (fields: Omit<LogEntry, "digest">): LogEntry => ({ ...fields, digest: logEntryDigest(fields) });

/** A log entry whose batch holds `content`, so two contents make two entries with two digests for one position. */
export const entry = (epoch: number, at: number, content: string): LogEntry =>
  digested({ at, epoch, versions, files: [], removed: [], batch: { pi_seq: at, body: { kind: "inline", json: JSON.stringify([content]) } } });

export type Outcome = "accepted" | AuthorityRefusal;

export const cellLog = { 1: entry(3, 1, digests[0]).digest, 2: entry(3, 2, digests[1]).digest } as const;
export const cellCheckpoint = { through: 0, manifest };
export const cellStates: readonly AuthorityState[] = [
  { kind: "active", epoch: 3, holder: tarantula, head: 2 },
  { kind: "sealed", epoch: 3, holder: tarantula, candidate: orion, head: 2 },
  { kind: "vacant", epoch: 3, candidate: orion, evidence: { kind: "released" }, head: 2 },
];

type ByCaller = readonly [owner: Outcome, candidate: Outcome, third: Outcome];

export const cells: Record<string, readonly [none: Outcome, active: ByCaller, sealed: ByCaller, vacant: ByCaller]> = {
  enroll: ["accepted", ["accepted", "enrolled", "enrolled"], ["enrolled", "enrolled", "enrolled"], ["enrolled", "enrolled", "enrolled"]],
  claim: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  "claim at an epoch that has moved": ["not_enrolled", ["epoch_moved", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  append: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  confirm: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  checkpoint: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  promote: ["not_enrolled", ["already_owner", "accepted", "accepted"], ["accepted", "accepted", "accepted"], ["accepted", "accepted", "accepted"]],
  "promote with an attestation": ["not_enrolled", ["already_owner", "accepted", "accepted"], ["self_attestation", "accepted", "accepted"], ["accepted", "accepted", "accepted"]],
  release: ["not_enrolled", ["not_sealed", "not_sealed", "not_sealed"], ["accepted", "not_sealed_holder", "not_sealed_holder"], ["not_sealed", "not_sealed", "not_sealed"]],
  activate: ["not_enrolled", ["accepted", "not_candidate", "not_candidate"], ["not_candidate", "not_candidate", "not_candidate"], ["not_candidate", "accepted", "not_candidate"]],
};

export function cellCommand(name: string, caller: string): AuthorityCommand {
  switch (name) {
    case "enroll": return { op: "enroll", holder: caller, checkpoint: cellCheckpoint };
    case "claim": return { op: "claim", holder: caller, expected_epoch: 3 };
    case "claim at an epoch that has moved": return { op: "claim", holder: caller, expected_epoch: 2 };
    case "append": return { op: "append", holder: caller, entry: entry(3, 3, digests[0]) };
    case "confirm": return { op: "confirm", holder: caller, epoch: 3 };
    case "checkpoint": return { op: "checkpoint", holder: caller, epoch: 3, record: { through: 2, manifest } };
    case "promote": return { op: "promote", candidate: caller, expected_epoch: 3, attestation: null };
    case "promote with an attestation": return { op: "promote", candidate: caller, expected_epoch: 3, attestation: "the old host is powered off" };
    case "release": return { op: "release", holder: caller, epoch: 3, evidence: "lock_held" };
    case "activate": return { op: "activate", candidate: caller, applied: 2 };
    default: throw new Error(`no command for ${name}`);
  }
}

export type Script = readonly (readonly [AuthorityCommand, Outcome])[];

export interface ScriptedSequence {
  readonly steps: Script;
  readonly record: AuthorityRecord | undefined;
  readonly log: Readonly<Record<number, string>>;
}

const enroll: Script = [[{ op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest } }, "accepted"]];
const first: AuthorityCommand = { op: "append", holder: tarantula, entry: entry(1, 1, digests[0]) };
const sealedForOrion: Script = [...enroll, [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "accepted"]];
const record = (state: AuthorityState, through = 0): AuthorityRecord => ({ state, checkpoint: { through, manifest } });

export const scriptedSequences: Record<string, ScriptedSequence> = {
  "a retried append is honored only for the current owner": {
    steps: [
      ...enroll,
      [first, "accepted"],
      [first, "accepted"],
      [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[1]) }, "conflict"],
      [{ op: "append", holder: tarantula, entry: entry(1, 3, digests[1]) }, "gap"],
      [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "accepted"],
      [first, "sealed"],
      [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: "the old host is powered off" }, "accepted"],
      [{ op: "activate", candidate: orion, applied: 0 }, "not_caught_up"],
      [{ op: "activate", candidate: orion, applied: 1 }, "accepted"],
      [first, "fenced"],
      [{ op: "confirm", holder: tarantula, epoch: 1 }, "fenced"],
      [{ op: "claim", holder: tarantula, expected_epoch: 2 }, "fenced"],
      [{ op: "append", holder: orion, entry: entry(1, 2, digests[1]) }, "fenced"],
      [{ op: "append", holder: orion, entry: entry(2, 2, digests[1]) }, "accepted"],
    ],
    record: record({ kind: "active", epoch: 2, holder: orion, head: 2 }),
    log: { 1: entry(1, 1, digests[0]).digest, 2: entry(2, 2, digests[1]).digest },
  },
  "a claim that arrives twice, or after a later claim, raises the epoch once and fences nobody": {
    steps: [
      ...enroll,
      [{ op: "claim", holder: tarantula, expected_epoch: 1 }, "accepted"],
      [{ op: "claim", holder: tarantula, expected_epoch: 1 }, "epoch_moved"],
      [{ op: "append", holder: tarantula, entry: entry(2, 1, digests[0]) }, "accepted"],
      [{ op: "claim", holder: tarantula, expected_epoch: 2 }, "accepted"],
      [{ op: "claim", holder: tarantula, expected_epoch: 1 }, "epoch_moved"],
      [{ op: "claim", holder: tarantula, expected_epoch: 2 }, "epoch_moved"],
      [{ op: "append", holder: tarantula, entry: entry(2, 2, digests[1]) }, "fenced"],
      [{ op: "append", holder: tarantula, entry: entry(3, 2, digests[1]) }, "accepted"],
    ],
    record: record({ kind: "active", epoch: 3, holder: tarantula, head: 2 }),
    log: { 1: entry(2, 1, digests[0]).digest, 2: entry(3, 2, digests[1]).digest },
  },
  "a promotion whose candidate is lost is completed by another standby": {
    steps: [
      ...sealedForOrion,
      [{ op: "promote", candidate: spare, expected_epoch: 1, attestation: null }, "accepted"],
      [{ op: "activate", candidate: spare, applied: 0 }, "not_candidate"],
      [{ op: "release", holder: orion, epoch: 1, evidence: "released" }, "not_sealed_holder"],
      [{ op: "release", holder: tarantula, epoch: 1, evidence: "released" }, "accepted"],
      [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: "the old host is powered off" }, "accepted"],
      [{ op: "activate", candidate: spare, applied: 0 }, "not_candidate"],
      [{ op: "activate", candidate: orion, applied: 0 }, "accepted"],
      [{ op: "activate", candidate: orion, applied: 0 }, "accepted"],
    ],
    record: record({ kind: "active", epoch: 2, holder: orion, head: 0 }),
    log: {},
  },
  "a promotion whose candidate is lost is taken back by the old owner": {
    steps: [
      ...sealedForOrion,
      [{ op: "promote", candidate: tarantula, expected_epoch: 1, attestation: "I am stopped" }, "self_attestation"],
      [{ op: "promote", candidate: tarantula, expected_epoch: 1, attestation: null }, "accepted"],
      [{ op: "release", holder: tarantula, epoch: 1, evidence: "released" }, "accepted"],
      [{ op: "activate", candidate: tarantula, applied: 0 }, "accepted"],
      [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "epoch_moved"],
    ],
    record: record({ kind: "active", epoch: 2, holder: tarantula, head: 0 }),
    log: {},
  },
  "a checkpoint drops the entries it covers and never moves backward or past the head": {
    steps: [
      ...enroll,
      [{ op: "enroll", holder: orion, checkpoint: { through: 0, manifest } }, "enrolled"],
      [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[0]) }, "accepted"],
      [{ op: "append", holder: tarantula, entry: entry(1, 2, digests[1]) }, "accepted"],
      [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 3, manifest } }, "checkpoint_out_of_range"],
      [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 1, manifest } }, "accepted"],
      [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 0, manifest } }, "checkpoint_out_of_range"],
      [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[0]) }, "conflict"],
      [{ op: "append", holder: tarantula, entry: entry(1, 2, digests[1]) }, "accepted"],
    ],
    record: record({ kind: "active", epoch: 1, holder: tarantula, head: 2 }, 1),
    log: { 2: entry(1, 2, digests[1]).digest },
  },
  "an enrollment must start from an empty checkpoint": {
    steps: [[{ op: "enroll", holder: tarantula, checkpoint: { through: 4, manifest } }, "checkpoint_out_of_range"]],
    record: undefined,
    log: {},
  },
};
