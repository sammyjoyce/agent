import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join, relative } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { StorageWrite } from "@earendil-works/pi-durable";
import type { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { BatchBody } from "../generated/BatchBody.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { Versions } from "../generated/Versions.js";
import type { AuthorityLink } from "./authority-link.js";
import { logEntryDigest, sha256Hex, versions } from "./log-entry.js";
import type { ScopedDatabase } from "./scoped-database.js";

const LOG_PAGE_ENTRIES = 32;

/** A directory that follows one coordinator's log. */
export interface LogFollower {
  readonly database: ScopedDatabase;
  readonly link: AuthorityLink;
  /** The state directory that holds the session database and the replicated file trees. */
  readonly stateDirectory: string;
  readonly signal?: AbortSignal;
}

/**
 * Brings a standby's directory up to the head of the log and returns the
 * position it reached. Takes ownership of `database` and closes it. It opens
 * Pi's storage and never a Harness, so it cannot schedule or emit.
 */
export async function applyLog(follower: LogFollower): Promise<number> {
  const { database, link } = follower;
  let storage: SqliteStorage;
  try {
    const record = await link.record();
    if (record === undefined) throw new Error("This coordinator is not enrolled with the authority");
    storage = await database.openStorage(record.checkpoint.through);
  } catch (error) {
    await database.close().catch(() => {});
    throw error;
  }
  try { return await followLog(follower, storage); }
  finally { await storage.close(BACKGROUND_CONTEXT); }
}

/**
 * Applies every log entry after the directory's position, in order, through
 * `storage`. The owner's catch-up on open and a standby's follow are this one
 * function, so both apply an entry the same way.
 */
export async function followLog(follower: LogFollower, storage: SqliteStorage): Promise<number> {
  const { database, link, signal } = follower;
  const installed = await versions();
  let position = await database.position();
  for (;;) {
    signal?.throwIfAborted();
    const { record: { state, checkpoint }, entries } = await link.log(position, LOG_PAGE_ENTRIES);
    if (position > state.head || position < checkpoint.through) {
      throw new Error(`This state directory does not belong to this log: it is at position ${position}, and the log runs from ${checkpoint.through} to ${state.head}`);
    }
    if (position === state.head) return position;
    if (entries.length === 0) throw new Error(`The log returned no entry after position ${position}, and its head is ${state.head}`);
    for (const entry of entries) {
      signal?.throwIfAborted();
      await applyEntry(follower, storage, installed, entry);
      position = entry.at;
    }
  }
}

async function applyEntry({ database, link, stateDirectory }: LogFollower, storage: SqliteStorage, installed: Versions, entry: LogEntry): Promise<void> {
  const { digest, ...body } = entry;
  if (body.versions.pi_durable !== installed.pi_durable || body.versions.chord !== installed.chord) {
    throw new Error(`Log entry ${entry.at} was written by Pi Durable ${body.versions.pi_durable} and Chord ${body.versions.chord}, and this host runs Pi Durable ${installed.pi_durable} and Chord ${installed.chord}`);
  }
  if (logEntryDigest(body) !== digest) throw new Error(`Log entry ${entry.at} does not match its digest`);
  for (const file of body.files) await materializeFile(link, stateDirectory, file);
  if (body.batch === null) {
    if (body.pi_seq !== null) throw new Error(`Log entry ${entry.at} names Pi sequence ${body.pi_seq} and carries no batch`);
    return database.applyWithoutBatch(entry.at);
  }
  if (body.pi_seq === null) throw new Error(`Log entry ${entry.at} carries a batch and names no Pi sequence`);
  const writes: unknown = JSON.parse(await batchJson(link, entry.at, body.batch));
  if (!Array.isArray(writes)) throw new Error(`The batch of log entry ${entry.at} is not a list of writes`);
  await database.apply(entry.at, body.pi_seq, () => storage.commit(writes as StorageWrite[], BACKGROUND_CONTEXT));
}

async function batchJson(link: AuthorityLink, at: number, batch: BatchBody): Promise<string> {
  switch (batch.kind) {
    case "inline": return batch.json;
    case "blob": {
      const bytes = await link.getBlob(batch.sha256);
      if (bytes.byteLength !== batch.size || sha256Hex(bytes) !== batch.sha256) throw new Error(`The blob that holds the batch of log entry ${at} does not match its record`);
      return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("utf8");
    }
    default: return batch satisfies never;
  }
}

/** The path of a replicated file under a state directory. Refuses a record whose path leaves it. */
export function replicatedFilePath(stateDirectory: string, file: FileRecord): string {
  const path = join(stateDirectory, file.path), inside = relative(stateDirectory, path);
  if (inside === "" || inside.startsWith("..") || isAbsolute(inside)) throw new Error(`The replicated file path ${file.path} leaves the state directory`);
  return path;
}

/** Gives a file its final name from the blob store, unless the directory already holds its bytes. */
async function materializeFile(link: AuthorityLink, stateDirectory: string, file: FileRecord): Promise<void> {
  const path = replicatedFilePath(stateDirectory, file);
  const present = await readFile(path).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined;
    throw error;
  });
  if (present !== undefined && matches(present, file)) return;
  const bytes = await link.getBlob(file.sha256);
  if (!matches(bytes, file)) throw new Error(`The blob for ${file.path} does not match its record`);
  await makeDirectory(dirname(path));
  const temporary = join(dirname(path), `.${randomUUID()}.tmp`);
  try {
    const handle = await open(temporary, "wx", 0o600);
    try { await handle.writeFile(bytes); await handle.sync(); } finally { await handle.close(); }
    await publishFile(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

/** Gives a synced file its final name, in a way that survives a crash. */
export async function publishFile(synced: string, path: string): Promise<void> {
  await makeDirectory(dirname(path));
  await rename(synced, path);
  await syncDirectory(dirname(path));
}

async function makeDirectory(directory: string): Promise<void> {
  const created = await mkdir(directory, { recursive: true, mode: 0o700 });
  if (created === undefined) return;
  for (let made = directory; ; made = dirname(made)) {
    await syncDirectory(dirname(made));
    if (relative(created, made) === "") return;
  }
}

async function syncDirectory(directory: string): Promise<void> {
  const handle = await open(directory, "r");
  try { await handle.sync(); } finally { await handle.close(); }
}

function matches(bytes: Uint8Array, file: FileRecord): boolean {
  return bytes.byteLength === file.size && sha256Hex(bytes) === file.sha256;
}
