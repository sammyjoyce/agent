import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join, relative } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { BatchBody } from "../generated/BatchBody.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { Versions } from "../generated/Versions.js";
import type { AuthorityLink } from "./authority-link.js";
import { commitLoggedBatch, logEntryDigest, parseBatch, sha256Hex, versions } from "./log-entry.js";
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
    if (await link.record() === undefined) throw new Error("This coordinator is not enrolled with the authority");
    storage = await database.openStorage();
  } catch (error) {
    await database.close().catch(() => {});
    throw error;
  }
  try { return await followLog(follower, storage); }
  finally { await storage.close(BACKGROUND_CONTEXT); }
}

/**
 * Applies every log entry after the directory's position, in order, through
 * `storage`.
 */
export async function followLog(follower: LogFollower, storage: SqliteStorage): Promise<number> {
  const { database, link, signal } = follower;
  const installed = await versions();
  let position = await database.position();
  for (;;) {
    signal?.throwIfAborted();
    const { record: { state, checkpoint }, entries } = await link.log(position, LOG_PAGE_ENTRIES);
    if (position < checkpoint.through) {
      throw new Error(`This state directory is at position ${position}, behind the checkpoint at ${checkpoint.through}, and the log no longer holds the entries between them. Rebuild it with \`beep-boop failover join --replace\``);
    }
    if (position > state.head) {
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
  const { digest, ...digested } = entry;
  const { at, versions: written, files, removed, batch } = entry;
  if (written.pi_durable !== installed.pi_durable || written.chord !== installed.chord) {
    throw new Error(`Log entry ${at} was written by Pi Durable ${written.pi_durable} and Chord ${written.chord}, and this host runs Pi Durable ${installed.pi_durable} and Chord ${installed.chord}`);
  }
  if (logEntryDigest(digested) !== digest) throw new Error(`Log entry ${at} does not match its digest`);
  const pending = await downloadFiles(link, stateDirectory, files);
  const publish = async () => {
    await publishFiles(pending);
    await removePaths(stateDirectory, removed);
  };
  try {
    if (batch === null) return await database.applyWithoutBatch(at, publish);
    const writes = parseBatch(await batchJson(link, at, batch.body), at);
    await database.apply(at, batch.pi_seq, { publish, commit: () => commitLoggedBatch(storage, writes, at, BACKGROUND_CONTEXT) });
  } catch (error) {
    await removeFiles(pending);
    throw error;
  }
}

async function batchJson(link: AuthorityLink, at: number, body: BatchBody): Promise<string> {
  switch (body.kind) {
    case "inline": return body.json;
    case "blob": {
      const bytes = await link.getBlob(body.sha256);
      if (bytes.byteLength !== body.size || sha256Hex(bytes) !== body.sha256) throw new Error(`The blob that holds the batch of log entry ${at} does not match its record`);
      return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.byteLength).toString("utf8");
    }
    default: return body satisfies never;
  }
}

/** The path of a replicated file under a state directory. Refuses a record whose path leaves it. */
export function replicatedFilePath(stateDirectory: string, file: Pick<FileRecord, "path">): string {
  const path = join(stateDirectory, file.path), inside = relative(stateDirectory, path);
  if (inside === "" || inside.startsWith("..") || isAbsolute(inside)) throw new Error(`The replicated file path ${file.path} leaves the state directory`);
  return path;
}

/** A synced file at a temporary name, waiting for its log entry's transaction to rename it to `path`. */
export interface PendingFile {
  readonly synced: string;
  readonly path: string;
}

/**
 * Downloads and verifies each file of an entry that the directory lacks, to a
 * temporary name beside its final path. A file already present with the
 * recorded bytes, such as one renamed before a crash, needs nothing.
 */
async function downloadFiles(link: AuthorityLink, stateDirectory: string, files: readonly FileRecord[]): Promise<PendingFile[]> {
  const pending: PendingFile[] = [];
  try {
    for (const file of files) {
      const path = replicatedFilePath(stateDirectory, file);
      const present = await readFile(path).catch((error: NodeJS.ErrnoException) => {
        if (error.code === "ENOENT") return undefined;
        throw error;
      });
      if (present !== undefined && matches(present, file)) continue;
      const bytes = await link.getBlob(file.sha256);
      if (!matches(bytes, file)) throw new Error(`The blob for ${file.path} does not match its record`);
      pending.push({ synced: await writeTemporary(dirname(path), bytes), path });
    }
    return pending;
  } catch (error) {
    await removeFiles(pending);
    throw error;
  }
}

async function removeFiles(files: readonly PendingFile[]): Promise<void> {
  await Promise.all(files.map(({ synced }) => rm(synced, { force: true })));
}

/** Gives each synced file its final name, in a way that survives a crash. */
export async function publishFiles(files: readonly PendingFile[]): Promise<void> {
  for (const { synced, path } of files) {
    await makeDirectory(dirname(path));
    await rename(synced, path);
    await syncDirectory(dirname(path));
  }
}

/**
 * Removes each path a log entry removed, a file or a whole tree, in a way that
 * survives a crash. A path that is already gone needs nothing, so a repeat
 * after a crash ends the same.
 */
export async function removePaths(stateDirectory: string, paths: readonly string[]): Promise<void> {
  for (const removed of paths) {
    const path = replicatedFilePath(stateDirectory, { path: removed });
    await rm(path, { recursive: true, force: true });
    await syncDirectory(dirname(path)).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "ENOENT") throw error;
    });
  }
}

/** A name no replicated file takes, so a file under it is one a crash left before its log entry named it. */
export function isTemporaryName(name: string): boolean {
  return name.startsWith(".") || name.endsWith(".tmp");
}

export function temporaryPath(directory: string): string {
  return join(directory, `.${randomUUID()}.tmp`);
}

export async function writeTemporary(directory: string, bytes: Uint8Array): Promise<string> {
  await makeDirectory(directory);
  const path = temporaryPath(directory);
  try {
    const handle = await open(path, "wx", 0o600);
    try { await handle.writeFile(bytes); await handle.sync(); } finally { await handle.close(); }
    return path;
  } catch (error) {
    await rm(path, { force: true });
    throw error;
  }
}

/** Creates a private directory and syncs each parent it had to create an entry in. */
export async function makeDirectory(directory: string): Promise<void> {
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
