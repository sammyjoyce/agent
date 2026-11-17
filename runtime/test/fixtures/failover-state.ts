import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { after, type TestContext } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteDatabase } from "@earendil-works/chord/sqlite";
import { createModels, fauxProvider } from "@earendil-works/pi-ai";
import { createRegistry, Harness, type Registry, type Storage, type StorageWrite } from "@earendil-works/pi-durable";
import { openConversationDatabase } from "../../src/conversation-database.js";
import { AuthorityClient } from "../../src/failover/authority-client.js";
import type { AuthorityLink } from "../../src/failover/authority-link.js";
import { commandHolder } from "../../src/failover/authority-wire.js";
import { sha256Hex } from "../../src/failover/log-entry.js";
import { openReplicatedStorage, type OwnerFenced, type StagedFile } from "../../src/failover/replicated-storage.js";
import { ReplicatedFiles } from "../../src/failover/retained-files.js";
import { ScopedDatabase } from "../../src/failover/scoped-database.js";
import { applyLog } from "../../src/failover/standby.js";
import type { AuthorityCommand } from "../../src/generated/AuthorityCommand.js";
import type { AuthorityState } from "../../src/generated/AuthorityState.js";
import type { FileRecord } from "../../src/generated/FileRecord.js";
import type { LogEntry } from "../../src/generated/LogEntry.js";
import { REPLICATED_FILE_ROOTS } from "../../src/generated/replicated-file-roots.js";
import { fixtureModel } from "../model.js";
import { manifest, manifestBytes } from "./failover-authority-cells.js";
import { MemoryAuthority } from "./failover-memory-authority.js";
import { startAuthority, type LocalAuthority } from "./failover-workerd.js";

export const OWNER = "11111111-1111-4111-8111-111111111111";
export const STANDBY = "22222222-2222-4222-8222-222222222222";

export type TestAuthority = AuthorityLink & Pick<MemoryAuthority, "beforeCommand" | "afterApplied">;

class HookedLink implements TestAuthority {
  beforeCommand: TestAuthority["beforeCommand"] = () => {};
  afterApplied: TestAuthority["afterApplied"] = () => {};
  constructor(private readonly reader: AuthorityLink, private readonly clientForHolder: (holder: string) => AuthorityLink) {}
  async command(command: AuthorityCommand) {
    await this.beforeCommand(command);
    const reply = await this.clientForHolder(commandHolder(command)).command(command);
    await this.afterApplied(command);
    return reply;
  }
  record() { return this.reader.record(); }
  log(after: number, limit: number) { return this.reader.log(after, limit); }
  putBlob(sha256: string, bytes: Uint8Array) { return this.reader.putBlob(sha256, bytes); }
  getBlob(sha256: string) { return this.reader.getBlob(sha256); }
}

const workerCoordinators = Array.from({ length: 48 }, (_, index) => `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`);
let worker: Promise<LocalAuthority> | undefined;
let workerLinks = 0;
// Registered while the test file loads, so the Worker outlives the test that first asks for it.
after(async () => { await (await worker)?.stop(); });

async function freshWorkerCoordinator(): Promise<TestAuthority> {
  worker ??= startAuthority({ context: { after: () => {} },
    grants: workerCoordinators.flatMap((coordinator) => [OWNER, STANDBY].map((holder) => ({ coordinator, holder }))) });
  const { url, credentials } = await worker;
  const coordinatorId = workerCoordinators[workerLinks++];
  if (coordinatorId === undefined) throw new Error("The test file ran out of Worker coordinators");
  const clientForHolder = (holder: string) => {
    const credential = credentials.find((candidate) => candidate.coordinator === coordinatorId && candidate.holder === holder);
    if (credential === undefined) throw new Error(`The fixture holds no credential for holder ${holder}`);
    return new AuthorityClient({ url, coordinatorId, token: credential.token });
  };
  return new HookedLink(clientForHolder(OWNER), clientForHolder);
}

export const authorities: Record<string, () => TestAuthority | Promise<TestAuthority>> = {
  "memory authority": () => new MemoryAuthority(),
  "Worker on local workerd": freshWorkerCoordinator,
};

/** A new state directory that holds no replication position. */
export async function unstampedDirectory(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

/** Stamps a state directory at a log position, as `failover enroll` and `failover join` do. */
export async function stamp(directory: string, position = 0): Promise<void> {
  const database = await openScoped(directory);
  try { await database.stampPosition(position); } finally { await database.close(); }
}

/** A new state directory at position 0: the owner's after `failover enroll`, or a standby's after `failover join` of that checkpoint. */
export async function stateDirectory(t: TestContext): Promise<string> {
  const directory = await unstampedDirectory(t);
  await stamp(directory);
  return directory;
}

export const sessionPath = (directory: string) => join(directory, "session.sqlite");

export async function filesUnder(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { recursive: true, withFileTypes: true }).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return [];
    throw error;
  });
  return entries.filter((entry) => entry.isFile()).map((entry) => relative(directory, join(entry.parentPath, entry.name))).sort();
}

/** Every file under the replicated file trees, by path and SHA-256. */
export async function retainedFiles(directory: string): Promise<Record<string, string>> {
  const paths = (await filesUnder(directory)).filter((path) => REPLICATED_FILE_ROOTS.some((root) => path.startsWith(`${root}/`)));
  return Object.fromEntries(await Promise.all(paths.map(async (path) => [path, sha256Hex(await readFile(join(directory, path)))] as const)));
}

export async function enroll(link: AuthorityLink, holder = OWNER): Promise<number> {
  await link.putBlob(manifest, manifestBytes);
  return (await accepted(link, { op: "enroll", holder, checkpoint: { through: 0, manifest } })).epoch;
}

/** A read-only connection that waits for a lock, because a test reads a database that another process may be opening or closing. */
const reader = (directory: string) => new DatabaseSync(sessionPath(directory), { readOnly: true, timeout: 5_000 });

export function tables(directory: string): Record<string, string[]> {
  const database = reader(directory);
  try {
    const names = database.prepare("SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name").all();
    return Object.fromEntries(names.map(({ name }) =>
      [String(name), database.prepare(`SELECT * FROM "${String(name)}" ORDER BY rowid`).all().map((row) => JSON.stringify(row))]));
  } finally { database.close(); }
}

export async function openPi(storage: Storage, options: { registry?: Registry; tokensPerSecond?: number } = {}) {
  const models = createModels();
  const { provider, model_id: modelId } = fixtureModel;
  const faux = fauxProvider({ provider, models: [{ id: modelId }], tokensPerSecond: options.tokensPerSecond ?? 1_000_000 });
  models.setProvider(faux.provider);
  const harness = await Harness.open(storage, { models, registry: options.registry ?? createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider, modelId } } });
  return { harness, root, faux };
}

export async function openScoped(directory: string, observe: (database: SqliteDatabase) => SqliteDatabase = (database) => database): Promise<ScopedDatabase> {
  return ScopedDatabase.over(observe(await openConversationDatabase(sessionPath(directory))));
}

export interface OwnerOptions {
  readonly holder?: string;
  readonly epoch: number;
  readonly signal?: AbortSignal;
  readonly onFenced?: (error: OwnerFenced) => void;
  readonly registry?: Registry;
  readonly tokensPerSecond?: number;
  readonly observe?: (database: SqliteDatabase) => SqliteDatabase;
}

export async function openOwner(directory: string, link: AuthorityLink, options: OwnerOptions) {
  const database = await openScoped(directory, options.observe);
  const opened = { database, link, holder: options.holder ?? OWNER, epoch: options.epoch, stateDirectory: directory,
    onFenced: options.onFenced ?? (() => {}), ...(options.signal === undefined ? {} : { signal: options.signal }) };
  const { storage, log } = await openReplicatedStorage(opened);
  try { return { database, storage, log, files: new ReplicatedFiles(log, opened), ...await openPi(storage, options) }; }
  catch (error) { await storage.close(BACKGROUND_CONTEXT).catch(() => {}); throw error; }
}

export async function stage(directory: string, link: AuthorityLink, path: string, bytes: Uint8Array): Promise<StagedFile> {
  const sha256 = sha256Hex(bytes), staged = join(directory, dirname(path), `.${randomUUID()}.tmp`);
  await link.putBlob(sha256, bytes);
  await mkdir(dirname(staged), { recursive: true });
  await writeFile(staged, bytes);
  return { record: { path, sha256, size: bytes.byteLength }, staged };
}

export async function follow(directory: string, link: AuthorityLink): Promise<number> {
  return applyLog({ database: await openScoped(directory), link, stateDirectory: directory });
}

export async function takeBack(link: AuthorityLink, holder: string, epoch: number): Promise<number> {
  await accepted(link, { op: "promote", candidate: holder, expected_epoch: epoch, attestation: null });
  const { head } = await accepted(link, { op: "release", holder, epoch, evidence: "released" });
  return (await accepted(link, { op: "activate", candidate: holder, applied: head })).epoch;
}

export async function replaceOwner(link: AuthorityLink, candidate: string, epoch: number): Promise<number> {
  const { head } = await accepted(link, { op: "promote", candidate, expected_epoch: epoch, attestation: "Invented: the old host is powered off" });
  return (await accepted(link, { op: "activate", candidate, applied: head })).epoch;
}

async function accepted(link: AuthorityLink, command: AuthorityCommand): Promise<AuthorityState> {
  const reply = await link.command(command);
  if (reply.result !== "accepted") throw new Error(`The fixture's ${command.op} was refused: ${reply.reason}`);
  return reply.state;
}

export async function logEntries(link: AuthorityLink): Promise<LogEntry[]> {
  const entries: LogEntry[] = [];
  for (;;) {
    const page = await link.log(entries.at(-1)?.at ?? 0, 64);
    if (page.entries.length === 0) return entries;
    entries.push(...page.entries);
  }
}

/** The newest record of each path the log names. */
/** The files the log names and no later entry removed, by path. */
export async function loggedFiles(link: AuthorityLink): Promise<Map<string, FileRecord>> {
  const named = new Map<string, FileRecord>();
  for (const entry of await logEntries(link)) {
    for (const file of entry.files) named.set(file.path, file);
    for (const removed of entry.removed) for (const path of named.keys()) if (path === removed || path.startsWith(`${removed}/`)) named.delete(path);
  }
  return named;
}

export async function logBatches(link: AuthorityLink): Promise<StorageWrite[][]> {
  const batches: StorageWrite[][] = [];
  for (const { batch } of await logEntries(link)) {
    if (batch === null) continue;
    const { body } = batch;
    const json = body.kind === "inline" ? body.json : Buffer.from(await link.getBlob(body.sha256)).toString("utf8");
    batches.push(JSON.parse(json) as StorageWrite[]);
  }
  return batches;
}

export const note = (data: string, requestId: string) => ({ type: "write", entry: { kind: "app.note", data }, requestId }) as const;

const noteData = (entries: readonly { kind?: unknown; data?: unknown }[]) => entries.flatMap((entry) => entry.kind === "app.note" ? [String(entry.data)] : []);

export async function loggedNotes(link: AuthorityLink): Promise<string[]> {
  return noteData((await logBatches(link)).flat().flatMap((write) => write.type === "entry" ? [write.value] : []));
}

export function localNotes(directory: string): string[] {
  const database = reader(directory);
  try { return noteData(database.prepare("SELECT record FROM entries ORDER BY rowid").all().map((row) => JSON.parse(String(row.record)))); }
  finally { database.close(); }
}
