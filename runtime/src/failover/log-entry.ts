import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { Context } from "@earendil-works/chord/context";
import type { Seq, Storage, StorageWrite } from "@earendil-works/pi-durable";
import type { LogEntry } from "../generated/LogEntry.js";
import type { Versions } from "../generated/Versions.js";
import { COMMAND_BODY_LIMIT_BYTES, logEntryCanonical } from "./authority-wire.js";

/**
 * A Pi batch whose JSON is longer than this goes to the blob store, and its
 * log entry names it by hash. An inline batch is a JSON string inside the
 * entry, where escaping can double it, and the entry must fit in one command
 * body.
 */
export const INLINE_BATCH_LIMIT_BYTES = COMMAND_BODY_LIMIT_BYTES / 4;

export function sha256Hex(bytes: Uint8Array | string): string {
  return createHash("sha256").update(bytes).digest("hex");
}

/** SHA-256 over every field of a log entry but its digest. */
export function logEntryDigest(entry: Omit<LogEntry, "digest">): string {
  return sha256Hex(logEntryCanonical(entry));
}

export function parseBatch(json: string, at: number): StorageWrite[] {
  const writes: unknown = JSON.parse(json);
  if (!Array.isArray(writes)) throw new Error(`The batch of log entry ${at} is not a list of writes`);
  return writes as StorageWrite[];
}

/** What Pi's storage did with one batch committed on its own: stored it at `seq`, or refused it by Pi's own checks. */
export type BatchOutcome = { readonly kind: "stored"; readonly seq: Seq } | { readonly kind: "refused"; readonly reason: unknown };

/**
 * Commits one batch through Pi's storage as a commit of its own, the way every
 * log entry is applied. A failure of the database rejects.
 */
export async function commitBatch(storage: Storage, writes: readonly StorageWrite[], context: Context): Promise<BatchOutcome> {
  let stored: Seq | undefined;
  const { refused } = await storage.commit([writes], (_index, seq) => { stored = seq; }, context);
  return stored === undefined ? { kind: "refused", reason: refused } : { kind: "stored", seq: stored };
}

/** Commits the batch of the log entry at `at`, which Pi must store. */
export async function commitLoggedBatch(storage: Storage, writes: readonly StorageWrite[], at: number, context: Context): Promise<Seq> {
  const outcome = await commitBatch(storage, writes, context);
  switch (outcome.kind) {
    case "stored": return outcome.seq;
    case "refused": throw new Error(`Pi Durable refused the batch of log entry ${at}`, { cause: outcome.reason });
    default: return outcome satisfies never;
  }
}

let installed: Promise<Versions> | undefined;

/** The application, Pi Durable and Chord versions this process runs, which stamp every log entry it writes. */
export function versions(): Promise<Versions> {
  installed ??= Promise.all([
    manifestVersion(new URL("../../../package.json", import.meta.url)),
    manifestVersion(new URL(import.meta.resolve("@earendil-works/pi-durable/package.json"))),
    manifestVersion(new URL(import.meta.resolve("@earendil-works/chord/package.json"))),
  ]).then(([application, pi_durable, chord]) => ({ application, pi_durable, chord }));
  return installed;
}

async function manifestVersion(manifest: URL): Promise<string> {
  const value: unknown = JSON.parse(await readFile(manifest, "utf8"));
  if (value === null || typeof value !== "object" || !("version" in value) || typeof value.version !== "string") {
    throw new Error(`The package manifest ${manifest.pathname} has no version`);
  }
  return value.version;
}
