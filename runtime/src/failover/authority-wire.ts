import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { BatchBody } from "../generated/BatchBody.js";
import type { CheckpointRecord } from "../generated/CheckpointRecord.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { Versions } from "../generated/Versions.js";
import { REPLICATED_FILE_ROOTS } from "../generated/replicated-file-roots.js";

export const COMMAND_BODY_LIMIT_BYTES = 1024 * 1024;

type Field<T> = (value: unknown, path: string) => T;
type Fields<T> = { readonly [K in keyof T]-?: Field<T[K]> };
type Variants<U, Tag extends keyof U> = {
  readonly [V in U[Tag] & string]: Fields<Omit<Extract<U, Record<Tag, V>>, Tag>>;
};

const LOWERCASE_UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA256_HEX = /^[0-9a-f]{64}$/;

export const isLowercaseUuid = (value: string) => LOWERCASE_UUID.test(value);
export const isSha256Hex = (value: string) => SHA256_HEX.test(value);

function invalid(path: string, problem: string): never {
  throw new Error(`${path === "" ? "The command" : `The field ${path}`} ${problem}.`);
}

const join = (path: string, key: string) => path === "" ? key : `${path}.${key}`;

const counter: Field<number> = (value, path) =>
  typeof value === "number" && Number.isSafeInteger(value) && value >= 0 ? value : invalid(path, "is not a whole number from 0 to 2^53 - 1");

const text: Field<string> = (value, path) => typeof value === "string" ? value : invalid(path, "is not a string");

const textWhere = (check: (value: string) => boolean, problem: string): Field<string> => (value, path) => {
  const parsed = text(value, path);
  return check(parsed) ? parsed : invalid(path, problem);
};

const statement = textWhere((value) => /\S/.test(value), "is blank");
const uuid = textWhere(isLowercaseUuid, "is not a lowercase UUID");
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

const object = <T>(fields: Fields<T>): Field<T> => (value, path) => readFields(members(value, path), fields, path);

function tagged<U, Tag extends keyof U & string>(tag: Tag, variants: Variants<U, Tag>): Field<U> {
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

const logEntry = object<LogEntry>({
  at: counter,
  epoch: counter,
  digest: sha256,
  versions,
  pi_seq: nullable(counter),
  files: list(fileRecord),
  batch: nullable(batchBody),
});

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

/**
 * Parses a command from untrusted JSON, or throws an Error whose message names
 * the first bad field. It accepts what `src/failover.rs` accepts, narrowed in
 * three ways: every field the generated type names must be present, a UUID must
 * be in the lowercase hyphenated form Rust writes because the rules compare
 * holders as strings, and an attestation may not be blank.
 */
export function parseAuthorityCommand(value: unknown): AuthorityCommand {
  return authorityCommand(value, "");
}

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
