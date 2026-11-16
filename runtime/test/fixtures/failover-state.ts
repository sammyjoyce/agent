import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import type { TestContext } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteDatabase } from "@earendil-works/chord/sqlite";
import { createModels, fauxProvider } from "@earendil-works/pi-ai";
import { createRegistry, Harness, type Registry, type Storage, type StorageWrite } from "@earendil-works/pi-durable";
import { openConversationDatabase } from "../../src/conversation-database.js";
import type { AuthorityLink } from "../../src/failover/authority-link.js";
import { ScopedDatabase } from "../../src/failover/scoped-database.js";
import type { LogEntry } from "../../src/generated/LogEntry.js";
import { MemoryAuthority } from "./failover-memory-authority.js";

export const OWNER = "11111111-1111-4111-8111-111111111111";
export const STANDBY = "22222222-2222-4222-8222-222222222222";

/** An authority a test can stop between two steps of one exchange. */
export type TestAuthority = AuthorityLink & Pick<MemoryAuthority, "before" | "after">;

/**
 * Every failover case runs once per entry. Add the Worker on local workerd
 * here to run the same cases against the deployed rules.
 */
export const authorities: Record<string, () => TestAuthority | Promise<TestAuthority>> = {
  "memory authority": () => new MemoryAuthority(),
};

export async function stateDirectory(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

export const sessionPath = (directory: string) => join(directory, "session.sqlite");

/** Enrolls `holder` as the first owner and returns its epoch. */
export async function enroll(link: AuthorityLink, holder = OWNER): Promise<number> {
  const reply = await link.command({ op: "enroll", holder, checkpoint: { through: 0, manifest: "0".repeat(64) } });
  if (reply.result !== "accepted") throw new Error(`The fixture could not enroll: ${reply.reason}`);
  return reply.state.epoch;
}

/** Every table's rows in rowid order, read through a separate connection. */
export function tables(directory: string): Record<string, string[]> {
  const database = new DatabaseSync(sessionPath(directory), { readOnly: true });
  try {
    const names = database.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
    return Object.fromEntries(names.map(({ name }) =>
      [String(name), database.prepare(`SELECT * FROM "${String(name)}" ORDER BY rowid`).all().map((row) => JSON.stringify(row))]));
  } finally { database.close(); }
}

export async function openPi(storage: Storage, options: { registry?: Registry; tokensPerSecond?: number } = {}) {
  const models = createModels();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: options.tokensPerSecond ?? 1_000_000 });
  models.setProvider(faux.provider);
  const harness = await Harness.open(storage, { models, registry: options.registry ?? createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider: "openai", modelId: "fixture" } } });
  return { harness, root, faux };
}

/** The session database of a state directory, opened as the application opens it and then scoped. */
export async function openScoped(directory: string, observe: (database: SqliteDatabase) => SqliteDatabase = (database) => database): Promise<ScopedDatabase> {
  return ScopedDatabase.over(observe(await openConversationDatabase(sessionPath(directory))));
}

export async function logEntries(link: AuthorityLink): Promise<LogEntry[]> {
  const entries: LogEntry[] = [];
  for (;;) {
    const page = await link.log(entries.at(-1)?.at ?? 0, 64);
    if (page.entries.length === 0) return entries;
    entries.push(...page.entries);
  }
}

/** The Pi batch each log entry carries, read back from the log and the blob store. */
export async function logBatches(link: AuthorityLink): Promise<StorageWrite[][]> {
  const batches: StorageWrite[][] = [];
  for (const { batch } of await logEntries(link)) {
    if (batch === null) continue;
    const json = batch.kind === "inline" ? batch.json : Buffer.from(await link.getBlob(batch.sha256)).toString("utf8");
    batches.push(JSON.parse(json) as StorageWrite[]);
  }
  return batches;
}

export const note = (data: string, requestId: string) => ({ type: "write", entry: { kind: "app.note", data }, requestId }) as const;

function noteData(writes: readonly StorageWrite[]): string[] {
  return writes.flatMap((write) => write.type === "entry" && write.value.kind === "app.note" ? [String(write.value.data)] : []);
}

export async function loggedNotes(link: AuthorityLink): Promise<string[]> {
  return noteData((await logBatches(link)).flat());
}

export function localNotes(directory: string): string[] {
  const database = new DatabaseSync(sessionPath(directory), { readOnly: true });
  try {
    return noteData(database.prepare("SELECT record FROM entries ORDER BY rowid").all()
      .map((row) => ({ type: "entry", value: JSON.parse(String(row.record)) }) as StorageWrite));
  } finally { database.close(); }
}
