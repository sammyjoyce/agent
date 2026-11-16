import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityRefusal } from "../generated/AuthorityRefusal.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { AuthorityState } from "../generated/AuthorityState.js";
import type { BatchBody } from "../generated/BatchBody.js";
import type { CheckpointRecord } from "../generated/CheckpointRecord.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { LoggedBatch } from "../generated/LoggedBatch.js";
import type { LogPage } from "../generated/LogPage.js";
import type { StopEvidence } from "../generated/StopEvidence.js";
import type { Versions } from "../generated/Versions.js";
import { REPLICATED_FILE_ROOTS } from "../generated/replicated-file-roots.js";

export const COMMAND_BODY_LIMIT_BYTES = 1024 * 1024;

/** Parses one value of untrusted JSON, or throws an Error that names `path`. */
export type Field<T> = (value: unknown, path: string) => T;
type Fields<T> = { readonly [K in keyof T]-?: Field<T[K]> };
type Variants<U, Tag extends keyof U> = {
  readonly [V in U[Tag] & string]: Fields<Omit<Extract<U, Record<Tag, V>>, Tag>>;
};

const LOWERCASE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;

export const isLowercaseUuid = (value: string) => LOWERCASE_UUID.test(value);
export const isSha256Hex = (value: string) => SHA256_HEX.test(value);

function invalid(path: string, problem: string): never {
  throw new Error(`The field ${path} ${problem}.`);
}

const join = (path: string, key: string) => path === "" ? key : `${path}.${key}`;

export const counter: Field<number> = (value, path) =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : invalid(path, "is not a whole number from 0 to 2^53 - 1");

export const text: Field<string> = (value, path) => typeof value === "string" ? value : invalid(path, "is not a string");

const textWhere = (check: (value: string) => boolean, problem: string): Field<string> => (value, path) => {
  const parsed = text(value, path);
  return check(parsed) ? parsed : invalid(path, problem);
};

const statement = textWhere((value) => /\S/.test(value), "is blank");
export const uuid = textWhere(isLowercaseUuid, "is not a lowercase UUID");
const sha256 = textWhere(isSha256Hex, "is not 64 lowercase hexadecimal characters");
const statePath = textWhere((value) =>
  value.split("/").every((segment) => segment !== "" && segment !== "." && segment !== ".." && !/[\\\0]/.test(segment))
    && REPLICATED_FILE_ROOTS.some((root) => value.startsWith(`${root}/`)),
  "is not a relative path under attachments, history/assets or feedback");

const nullable = <T>(field: Field<T>): Field<T | null> => (value, path) => value === null ? null : field(value, path);

const list = <T>(field: Field<T>): Field<T[]> => (value, path) =>
  Array.isArray(value) ? value.map((item: unknown, index) => field(item, `${path}[${index}]`)) : invalid(path, "is not a list");

const oneOf = <const T extends string>(...choices: readonly T[]): Field<T> => (value, path) =>
  choices.find((choice) => choice === value) ?? invalid(path, `is not one of ${choices.join(", ")}`);

function members(value: unknown, path: string): Map<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return invalid(path, "is not an object");
  return new Map<string, unknown>(Object.entries(value));
}

function readFields<T>(given: ReadonlyMap<string, unknown>, fields: Fields<T>, path: string): T {
  for (const key of given.keys()) if (!Object.hasOwn(fields, key)) invalid(join(path, key), "is not known");
  const parsed = Object.entries<Field<unknown>>(fields).map(([key, field]) =>
    given.has(key) ? [key, field(given.get(key), join(path, key))] : invalid(join(path, key), "is missing"));
  return Object.fromEntries(parsed) as T;
}

/** An object with exactly these fields: a missing field and an unknown field both throw. */
export const object = <T>(fields: Fields<T>): Field<T> => (value, path) => readFields(members(value, path), fields, path);

export function tagged<U, Tag extends keyof U & string>(tag: Tag, variants: Variants<U, Tag>): Field<U> {
  return (value, path) => {
    const given = members(value, path);
    const name = given.get(tag);
    if (!given.has(tag)) invalid(join(path, tag), "is missing");
    if (typeof name !== "string" || !Object.hasOwn(variants, name)) invalid(join(path, tag), `is not one of ${Object.keys(variants).join(", ")}`);
    const rest = new Map([...given].filter(([key]) => key !== tag));
    return { [tag]: name, ...readFields(rest, variants[name as keyof typeof variants], path) } as U;
  };
}

const checkpointRecord = object<CheckpointRecord>({ through: counter, manifest: sha256 });

const versions = object<Versions>({ application: text, pi_durable: text, chord: text });

const fileRecord = object<FileRecord>({ path: statePath, sha256, size: counter });

const batchBody = tagged<BatchBody, "kind">("kind", {
  inline: { json: text },
  blob: { sha256, size: counter },
});

const loggedBatch = object<LoggedBatch>({ pi_seq: counter, body: batchBody });

const logEntry = object<LogEntry>({
  at: counter,
  epoch: counter,
  digest: sha256,
  versions,
  files: list(fileRecord),
  batch: nullable(loggedBatch),
});

const stopEvidence = tagged<StopEvidence, "kind">("kind", {
  released: {},
  lock_held: {},
  operator_attested: { statement: text },
});

const authorityState = tagged<AuthorityState, "kind">("kind", {
  active: { epoch: counter, holder: uuid, head: counter },
  sealed: { epoch: counter, holder: uuid, candidate: uuid, head: counter },
  vacant: { epoch: counter, candidate: uuid, evidence: stopEvidence, head: counter },
});

const refusals = { not_enrolled: null, enrolled: null, sealed: null, fenced: null, gap: null, conflict: null, missing_blob: null, epoch_moved: null,
  already_owner: null, self_attestation: null, not_sealed: null, not_sealed_holder: null, not_candidate: null, not_caught_up: null,
  checkpoint_out_of_range: null } satisfies Record<AuthorityRefusal, null>;

const authorityReply = tagged<AuthorityReply, "result">("result", {
  accepted: { state: authorityState },
  refused: { reason: oneOf(...Object.keys(refusals) as AuthorityRefusal[]), state: nullable(authorityState) },
});

const authorityRecord = object<AuthorityRecord>({ state: authorityState, checkpoint: checkpointRecord });

const logPage = object<LogPage>({ record: authorityRecord, entries: list(logEntry) });

const authorityCommand = tagged<AuthorityCommand, "op">("op", {
  enroll: { holder: uuid, checkpoint: checkpointRecord },
  claim: { holder: uuid },
  append: { holder: uuid, entry: logEntry },
  confirm: { holder: uuid, epoch: counter },
  promote: { candidate: uuid, expected_epoch: counter, attestation: nullable(statement) },
  release: { holder: uuid, epoch: counter, evidence: oneOf("released", "lock_held") },
  activate: { candidate: uuid, applied: counter },
  checkpoint: { holder: uuid, epoch: counter, record: checkpointRecord },
});

/** One entry of the Worker's `AUTHORITY_CREDENTIALS` secret. A credential without a holder may only read the record. */
export interface AuthorityCredential {
  readonly coordinator: string;
  readonly holder: string | null;
  readonly token_sha256: string;
}

const authorityCredentials = list(object<AuthorityCredential>({ coordinator: uuid, holder: nullable(uuid), token_sha256: sha256 }));

export function parseAuthorityCredentials(value: unknown): AuthorityCredential[] {
  return authorityCredentials(value, "AUTHORITY_CREDENTIALS");
}

/** Parses one whole JSON object, which a refusal's message calls `subject`. */
const whole = <T>(subject: string, field: Field<T>) => (value: unknown): T => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`The ${subject} is not an object.`);
  return field(value, "");
};

/**
 * Parses a command from untrusted JSON, or throws an Error whose message names
 * the first bad field. It accepts what `src/failover.rs` accepts, narrowed in
 * three ways: every field the generated type names must be present, a UUID must
 * be in the lowercase hyphenated form Rust writes because the rules compare
 * holders as strings, and an attestation may not be blank.
 */
export const parseAuthorityCommand = whole("command", authorityCommand);

/**
 * Parse the Worker's answers as `parseAuthorityCommand` parses a command,
 * narrowed in its first two ways.
 */
export const parseAuthorityReply = whole("reply", authorityReply);
export const parseAuthorityRecord = whole("record", authorityRecord);
export const parseLogPage = whole("log page", logPage);

/** The holder a command speaks for, which its credential must name. */
export function commandHolder(command: AuthorityCommand): string {
  switch (command.op) {
    case "enroll": case "claim": case "append": case "confirm": case "release": case "checkpoint":
      return command.holder;
    case "promote": case "activate":
      return command.candidate;
    default:
      return command satisfies never;
  }
}

/** The blobs a command names, which the blob store must hold before the authority decides the command. */
export function commandBlobs(command: AuthorityCommand): string[] {
  switch (command.op) {
    case "enroll":
      return [command.checkpoint.manifest];
    case "checkpoint":
      return [command.record.manifest];
    case "append": {
      const { files, batch } = command.entry;
      return [...files.map((file) => file.sha256), ...(batch?.body.kind === "blob" ? [batch.body.sha256] : [])];
    }
    case "claim": case "confirm": case "promote": case "release": case "activate":
      return [];
    default:
      return command satisfies never;
  }
}
