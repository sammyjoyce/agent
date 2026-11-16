import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
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
import { openReplicatedStorage, type StagedFile } from "../../src/failover/replicated-storage.js";
import { ScopedDatabase } from "../../src/failover/scoped-database.js";
import { applyLog } from "../../src/failover/standby.js";
import type { AuthorityCommand } from "../../src/generated/AuthorityCommand.js";
import type { AuthorityState } from "../../src/generated/AuthorityState.js";
import type { LogEntry } from "../../src/generated/LogEntry.js";
import { fixtureModel } from "../model.js";
import { MemoryAuthority } from "./failover-memory-authority.js";
import { startAuthority, type LocalAuthority } from "./failover-workerd.js";

export const OWNER = "11111111-1111-4111-8111-111111111111";
export const STANDBY = "22222222-2222-4222-8222-222222222222";

/** An authority a test can stop between two steps of one exchange. */
export type TestAuthority = AuthorityLink & Pick<MemoryAuthority, "before" | "after">;

/**
 * The Worker over HTTP with the same two stops: before a command leaves, and
 * after the Worker applied it. Each command goes out under its own holder's
 * credential, as it does from that holder's host.
 */
class HookedLink implements TestAuthority {
  before: TestAuthority["before"] = () => {};
  after: TestAuthority["after"] = () => {};
  constructor(private readonly reader: AuthorityLink, private readonly as: (holder: string) => AuthorityLink) {}
  async command(command: AuthorityCommand) {
    await this.before(command);
    const reply = await this.as(commandHolder(command)).command(command);
    await this.after(command);
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

/** A coordinator nobody has enrolled, on one Worker under local workerd that the test file shares. */
async function workerAuthority(): Promise<TestAuthority> {
  worker ??= startAuthority({ context: { after: () => {} },
    grants: workerCoordinators.flatMap((coordinator) => [OWNER, STANDBY].map((holder) => ({ coordinator, holder }))) });
  const { url, credentials } = await worker;
  const coordinatorId = workerCoordinators[workerLinks++];
  if (coordinatorId === undefined) throw new Error("The test file ran out of Worker coordinators");
  const as = (holder: string) => {
    const credential = credentials.find((candidate) => candidate.coordinator === coordinatorId && candidate.holder === holder);
    if (credential === undefined) throw new Error(`The fixture holds no credential for holder ${holder}`);
    return new AuthorityClient({ url, coordinatorId, token: credential.token });
  };
  return new HookedLink(as(OWNER), as);
}

/** Every failover case runs once per entry: against the rules in process, and against the Worker that deploys them. */
export const authorities: Record<string, () => TestAuthority | Promise<TestAuthority>> = {
  "memory authority": () => new MemoryAuthority(),
  "Worker on local workerd": workerAuthority,
};

export async function stateDirectory(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

export const sessionPath = (directory: string) => join(directory, "session.sqlite");

/** Enrolls `holder` as the first owner and returns its epoch. */
export async function enroll(link: AuthorityLink, holder = OWNER): Promise<number> {
  return (await accepted(link, { op: "enroll", holder, checkpoint: { through: 0, manifest: "0".repeat(64) } })).epoch;
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
  const { provider, model_id: modelId } = fixtureModel;
  const faux = fauxProvider({ provider, models: [{ id: modelId }], tokensPerSecond: options.tokensPerSecond ?? 1_000_000 });
  models.setProvider(faux.provider);
  const harness = await Harness.open(storage, { models, registry: options.registry ?? createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const root = await harness.root(BACKGROUND_CONTEXT, { agent: { model: { provider, modelId } } });
  return { harness, root, faux };
}

/** The session database of a state directory, opened as the application opens it and then scoped. */
export async function openScoped(directory: string, observe: (database: SqliteDatabase) => SqliteDatabase = (database) => database): Promise<ScopedDatabase> {
  return ScopedDatabase.over(observe(await openConversationDatabase(sessionPath(directory))));
}

export interface OwnerOptions {
  readonly holder?: string;
  readonly epoch: number;
  readonly signal?: AbortSignal;
  readonly registry?: Registry;
  readonly tokensPerSecond?: number;
}

/** An owner's replicated storage with a real Harness over it. */
export async function openOwner(directory: string, link: AuthorityLink, options: OwnerOptions) {
  const database = await openScoped(directory);
  const { storage, log } = await openReplicatedStorage({ database, link, holder: options.holder ?? OWNER, epoch: options.epoch,
    stateDirectory: directory, ...(options.signal === undefined ? {} : { signal: options.signal }) });
  try { return { database, storage, log, ...await openPi(storage, options) }; }
  catch (error) { await storage.close(BACKGROUND_CONTEXT).catch(() => {}); throw error; }
}

/** A replicated file as its writer hands it to the log: bytes in the blob store and a temporary file beside its final path. */
export async function stage(directory: string, link: AuthorityLink, path: string, bytes: Uint8Array): Promise<StagedFile> {
  const sha256 = sha256Hex(bytes), staged = join(directory, dirname(path), `.${randomUUID()}.tmp`);
  await link.putBlob(sha256, bytes);
  await mkdir(dirname(staged), { recursive: true });
  await writeFile(staged, bytes);
  return { record: { path, sha256, size: bytes.byteLength }, staged };
}

/** A standby's follow of the log into its own state directory. Returns the position it reached. */
export async function follow(directory: string, link: AuthorityLink): Promise<number> {
  return applyLog({ database: await openScoped(directory), link, stateDirectory: directory });
}

/** The sealed holder takes ownership back, as `promote` on itself does. Returns the new epoch. */
export async function takeBack(link: AuthorityLink, holder: string, epoch: number): Promise<number> {
  await accepted(link, { op: "promote", candidate: holder, expected_epoch: epoch, attestation: null });
  const { head } = await accepted(link, { op: "release", holder, epoch, evidence: "released" });
  return (await accepted(link, { op: "activate", candidate: holder, applied: head })).epoch;
}

/** Another holder replaces the owner on an invented attestation. Returns the new epoch. */
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

const noteData = (entries: readonly { kind?: unknown; data?: unknown }[]) => entries.flatMap((entry) => entry.kind === "app.note" ? [String(entry.data)] : []);

export async function loggedNotes(link: AuthorityLink): Promise<string[]> {
  return noteData((await logBatches(link)).flat().flatMap((write) => write.type === "entry" ? [write.value] : []));
}

export function localNotes(directory: string): string[] {
  const database = new DatabaseSync(sessionPath(directory), { readOnly: true });
  try { return noteData(database.prepare("SELECT record FROM entries ORDER BY rowid").all().map((row) => JSON.parse(String(row.record)))); }
  finally { database.close(); }
}
