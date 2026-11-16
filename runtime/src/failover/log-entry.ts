import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import type { StorageWrite } from "@earendil-works/pi-durable";
import type { BatchBody } from "../generated/BatchBody.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { Versions } from "../generated/Versions.js";
import { COMMAND_BODY_LIMIT_BYTES } from "./authority-wire.js";

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

/** SHA-256 over every field of a log entry but its digest, in a fixed key order. */
export function logEntryDigest(entry: Omit<LogEntry, "digest">): string {
  const { application, pi_durable, chord } = entry.versions;
  return sha256Hex(JSON.stringify({
    at: entry.at, epoch: entry.epoch, versions: { application, pi_durable, chord }, pi_seq: entry.pi_seq,
    files: entry.files.map(({ path, sha256, size }) => ({ path, sha256, size })),
    batch: entry.batch === null ? null : canonicalBatch(entry.batch),
  }));
}

export function parseBatch(json: string, at: number): StorageWrite[] {
  const writes: unknown = JSON.parse(json);
  if (!Array.isArray(writes)) throw new Error(`The batch of log entry ${at} is not a list of writes`);
  return writes as StorageWrite[];
}

function canonicalBatch(batch: BatchBody): BatchBody {
  switch (batch.kind) {
    case "inline": return { kind: batch.kind, json: batch.json };
    case "blob": return { kind: batch.kind, sha256: batch.sha256, size: batch.size };
    default: return batch satisfies never;
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
