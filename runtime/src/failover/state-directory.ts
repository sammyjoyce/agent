import { createHash } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { FileRecord } from "../generated/FileRecord.js";
import type { UnfinishedDelivery } from "../generated/UnfinishedDelivery.js";
import type { UnfinishedToolCall } from "../generated/UnfinishedToolCall.js";
import type { AuthorityLink } from "./authority-link.js";
import { REPLICATED_FILE_ROOTS } from "../generated/replicated-file-roots.js";
import { readCheckpointManifest } from "./checkpoint-store.js";
import { replicatedFilePath } from "./standby.js";

/** Where a backup archive, and so a checkpoint, keeps the state directory's files. */
const ARCHIVE_DATA = "data/";
const LOG_PAGE_ENTRIES = 64;

export const sessionDatabasePath = (state: string) => join(state, "session.sqlite");

/**
 * How long a read waits for a lock. SQLite locks the file for an instant when
 * another process opens or closes it, and a read with no wait is then refused
 * as locked: `failover status` beside a running `failover follow`, or the reverse.
 */
const BUSY_TIMEOUT_MS = 5_000;

/** Opens a state directory's session database without the right to change it. */
function readOnly(state: string): DatabaseSync {
  const path = sessionDatabasePath(state);
  if (!existsSync(path)) throw new Error(`${state} has no session.sqlite, so it is not a coordinator's state directory`);
  return new DatabaseSync(path, { readOnly: true, timeout: BUSY_TIMEOUT_MS });
}

const hasTable = (database: DatabaseSync, name: string) =>
  database.prepare("SELECT 1 FROM sqlite_schema WHERE type = 'table' AND name = ?").get(name) !== undefined;

function position(database: DatabaseSync): number | undefined {
  if (!hasTable(database, "beep_boop_failover")) return undefined;
  const value = database.prepare("SELECT position FROM beep_boop_failover WHERE singleton = 1").get()?.position;
  return typeof value === "number" ? value : undefined;
}

/** The log position a state directory holds, or undefined when it has no session database or was never stamped. */
export function appliedPosition(state: string): number | undefined {
  if (!existsSync(sessionDatabasePath(state))) return undefined;
  const database = readOnly(state);
  try { return position(database); } finally { database.close(); }
}

async function hashFile(path: string): Promise<{ sha256: string; size: number }> {
  const hash = createHash("sha256");
  let size = 0;
  for await (const chunk of createReadStream(path) as AsyncIterable<Buffer>) { hash.update(chunk); size += chunk.byteLength; }
  return { sha256: hash.digest("hex"), size };
}

/**
 * Checks a state directory that must hold the whole log before it takes
 * ownership: the database's integrity, the coordinator id against the
 * checkpoint's, and the bytes of every replicated file that the checkpoint or
 * a later log entry names and no later entry removed. The latest record of a
 * path is the one that counts.
 */
export async function verifyStandby(link: AuthorityLink, state: string): Promise<{ applied: number; files: number }> {
  const record = await link.record();
  if (record === undefined) throw new Error("This coordinator is not enrolled with the authority");
  const { state: { head }, checkpoint } = record;
  const database = readOnly(state);
  let applied: number | undefined;
  try {
    applied = position(database);
    const integrity = database.prepare("PRAGMA integrity_check").all().map((row) => String(row.integrity_check));
    if (integrity.length !== 1 || integrity[0] !== "ok") throw new Error(`The session database of ${state} failed its integrity check: ${integrity.join("; ")}`);
  } finally { database.close(); }
  if (applied !== head) throw new Error(`${state} holds the log through position ${applied ?? "none"}, and the log head is ${head}`);

  const manifest = await readCheckpointManifest(link, checkpoint.manifest);
  const coordinatorId = await readFile(join(state, "coordinator-id"), "utf8");
  if (coordinatorId !== manifest.coordinator_id) throw new Error(`${state} belongs to coordinator ${coordinatorId}, and the checkpoint to coordinator ${manifest.coordinator_id}`);

  const expected = new Map<string, FileRecord>();
  for (const { path, sha256, size } of manifest.files) {
    const local = path.startsWith(ARCHIVE_DATA) ? path.slice(ARCHIVE_DATA.length) : undefined;
    if (local !== undefined && REPLICATED_FILE_ROOTS.some((root) => local.startsWith(`${root}/`))) expected.set(local, { path: local, sha256, size });
  }
  for (let after = checkpoint.through; after < head;) {
    const { entries } = await link.log(after, LOG_PAGE_ENTRIES);
    const last = entries.at(-1);
    if (last === undefined) throw new Error(`The log returned no entry after position ${after}, and its head is ${head}`);
    for (const entry of entries) {
      for (const file of entry.files) expected.set(file.path, file);
      for (const removed of entry.removed) {
        for (const path of expected.keys()) if (path === removed || path.startsWith(`${removed}/`)) expected.delete(path);
      }
    }
    after = last.at;
  }
  for (const file of expected.values()) {
    const found = await hashFile(replicatedFilePath(state, file)).catch((error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") throw new Error(`${file.path} is missing from ${state}, and the log names it`);
      throw error;
    });
    if (found.sha256 !== file.sha256 || found.size !== file.size) throw new Error(`${file.path} in ${state} does not match the record the log holds for it`);
  }
  return { applied, files: expected.size };
}

const object = (value: unknown): value is Record<string, unknown> => value !== null && typeof value === "object" && !Array.isArray(value);
const identifier = (value: unknown): string | undefined => typeof value === "string" || typeof value === "number" ? String(value) : undefined;
const parsed = (text: unknown): unknown => { try { return JSON.parse(String(text)); } catch { return undefined; } };

/**
 * A tool task Pi has not finished. Pi commits the intent of a call before it
 * runs the tool, as the checkpoint phase `execute`, so that phase without a
 * terminal status is a call that started and has no result. A task still in
 * the phase `call` ran nothing.
 */
function startedToolCall(database: DatabaseSync, text: unknown): UnfinishedToolCall | "not-started" | undefined {
  const task = parsed(text);
  if (!object(task) || !object(task.state) || !object(task.state.checkpoint) || !object(task.input)) return undefined;
  const { phase, replay } = task.state.checkpoint, { input } = task;
  if (phase === "call") return "not-started";
  const conversation_id = identifier(task.conversationId);
  if (phase !== "execute" || conversation_id === undefined) return undefined;
  const replay_safe = replay === "safe";
  if (input.kind === "nested") {
    if (!object(input.call) || typeof input.call.id !== "string" || typeof input.call.name !== "string") return undefined;
    return { conversation_id, tool: input.call.name, call_id: input.call.id, replay_safe };
  }
  const { callId: call_id } = input;
  if (typeof call_id !== "string" || typeof input.assistant !== "number") return undefined;
  const entry = parsed(database.prepare("SELECT record FROM entries WHERE id = ?").get(input.assistant)?.record);
  const messages: unknown[] = object(entry) && Array.isArray(entry.model) ? entry.model : [];
  for (const message of messages) {
    const blocks: unknown[] = object(message) && Array.isArray(message.content) ? message.content : [];
    for (const block of blocks) {
      if (object(block) && block.type === "toolCall" && block.id === call_id && typeof block.name === "string") return { conversation_id, tool: block.name, call_id, replay_safe };
    }
  }
  return undefined;
}

/** A phone notification claimed for sending, read from the newest stored revision of its delivery document. */
function attemptingDelivery(content: unknown, kind: unknown): UnfinishedDelivery | "settled" | undefined {
  const value = parsed(content);
  if (kind !== "base" || !object(value)) return undefined;
  const { delivery } = value;
  if (delivery === null) return "settled";
  if (!object(delivery) || typeof delivery.state !== "string") return undefined;
  if (delivery.state !== "attempting") return "settled";
  const { conversation_id, entry_id, installation_id, apns_id } = delivery;
  if (typeof conversation_id !== "string" || typeof entry_id !== "string" || typeof installation_id !== "string" || typeof apns_id !== "string") return undefined;
  return { conversation_id, entry_id, installation_id, apns_id };
}

/**
 * The effects the session database records as started and not finished: tool
 * calls past their intent and phone notifications in the state `attempting`.
 * It reads Pi Durable's tables directly and read-only, and never opens a
 * Harness, so it cannot recover or rerun anything. A row it cannot read is
 * named in `unreadable` and never dropped.
 */
export function unfinishedEffects(state: string): { tools: UnfinishedToolCall[]; deliveries: UnfinishedDelivery[]; unreadable: string[] } {
  const database = readOnly(state), tools: UnfinishedToolCall[] = [], deliveries: UnfinishedDelivery[] = [], unreadable: string[] = [];
  try {
    if (hasTable(database, "tasks") && hasTable(database, "entries")) {
      for (const row of database.prepare("SELECT id, record FROM tasks WHERE kind = ? AND status != 'terminal' ORDER BY id").all(JSON.stringify("pi.tool"))) {
        const call = startedToolCall(database, row.record);
        if (call === undefined) unreadable.push(`Tool task ${String(row.id)} is unfinished, and its stored record could not be read.`);
        else if (call !== "not-started") tools.push(call);
      }
    }
    if (hasTable(database, "documents") && hasTable(database, "document_revisions")) {
      const newest = database.prepare("SELECT kind, content FROM document_revisions WHERE document_id = ? ORDER BY seq DESC LIMIT 1");
      for (const row of database.prepare("SELECT id FROM documents WHERE kind = ? AND retired_at IS NULL ORDER BY id").all(JSON.stringify("agent.notification-delivery"))) {
        const id = Number(row.id), revision = newest.get(id);
        const delivery = revision === undefined ? "settled" : attemptingDelivery(revision.content, revision.kind);
        if (delivery === undefined) unreadable.push(`Notification delivery document ${id} could not be read.`);
        else if (delivery !== "settled") deliveries.push(delivery);
      }
    }
    return { tools, deliveries, unreadable };
  } finally { database.close(); }
}
