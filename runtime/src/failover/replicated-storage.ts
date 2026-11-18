import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { Seq, Storage, StorageWrite } from "@earendil-works/pi-durable";
import type { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { AuthorityState } from "../generated/AuthorityState.js";
import type { BatchBody } from "../generated/BatchBody.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import { repeatUntilAnswered, type AuthorityLink } from "./authority-link.js";
import { INLINE_BATCH_LIMIT_BYTES, logEntryDigest, parseBatch, sha256Hex, versions } from "./log-entry.js";
import type { ScopedDatabase } from "./scoped-database.js";
import { followLog, publishFiles, removePaths, replicatedFilePath, type LogFollower } from "./standby.js";

/**
 * The authority no longer takes this holder for the owner. The process must
 * stop: nothing it commits or starts from here on is in the log.
 */
export class OwnerFenced extends Error {
  constructor(readonly reason: "sealed" | "fenced", readonly state: AuthorityState | null) {
    super(reason === "sealed" ? "The replication log is sealed for a promotion, so this coordinator is no longer the owner"
      : "Another owner or a later epoch holds this coordinator, so this one is fenced");
    this.name = "OwnerFenced";
  }
}

/**
 * A replicated file before it has its final name: a synced local file whose
 * bytes the blob store already holds under `record.sha256`.
 */
export interface StagedFile {
  readonly record: FileRecord;
  readonly staged: string;
}

/** The owner's side of the replication log. Its first failure is final, as a failed Pi Session is. */
export interface LogWriter {
  readonly holder: string;
  readonly epoch: number;
  /** The position of the last entry this owner appended and applied. */
  readonly head: number;
  /** Logs a file-only entry, then gives each file its final name. */
  appendFiles(files: readonly StagedFile[]): Promise<void>;
  /** Logs an entry that removes each path, a file or a whole tree, then removes it here. */
  removeFiles(paths: readonly string[]): Promise<void>;
  /** Holds files for the entry of the next Pi batch, which names them ahead of the batch that references them. */
  carry(files: readonly StagedFile[]): void;
}

export interface ReplicatedStorageOptions extends LogFollower {
  readonly holder: string;
  readonly epoch: number;
  /**
   * Called where a refusal is read from the authority's answer, before the
   * `OwnerFenced` is thrown. Pi turns a rejected commit into a failed Session
   * and keeps the process alive, so the throw alone can be swallowed.
   */
  readonly onFenced: (error: OwnerFenced) => void;
}

function fenced(options: Pick<ReplicatedStorageOptions, "onFenced">, reason: OwnerFenced["reason"], state: AuthorityState | null): OwnerFenced {
  const error = new OwnerFenced(reason, state);
  options.onFenced(error);
  return error;
}

/**
 * Opens the owner's storage. Every Pi commit is dry run locally, appended to
 * the log, and only then committed locally, so local disk never holds a commit
 * the log lacks. Entries the log holds and this directory lacks are applied
 * before this returns, which is before Pi opens. Takes ownership of
 * `database`. An abort of `signal` ends a wait for an unreachable authority.
 */
export async function openReplicatedStorage(options: ReplicatedStorageOptions): Promise<{ storage: Storage; log: LogWriter }> {
  const { database, link, holder, epoch } = options;
  let inner: SqliteStorage;
  try {
    const record = await link.record();
    if (record === undefined) throw new Error("This coordinator is not enrolled with the authority");
    const { state } = record;
    if (state.kind !== "active" || state.holder !== holder || state.epoch !== epoch) throw fenced(options, state.kind === "active" ? "fenced" : "sealed", state);
    inner = await database.openStorage();
  } catch (error) {
    await database.close().catch(() => {});
    throw error;
  }
  try {
    const log = new OwnerLog(options, inner, await followLog(options, inner));
    const storage = new Proxy(inner, {
      get(target, name) {
        if (name === "commit") return log.commit;
        const value: unknown = Reflect.get(target, name, target);
        return typeof value === "function" ? value.bind(target) : value;
      },
    });
    return { storage, log };
  } catch (error) {
    await inner.close(BACKGROUND_CONTEXT).catch(() => {});
    throw error;
  }
}

class OwnerLog implements LogWriter {
  readonly #options: ReplicatedStorageOptions;
  readonly #storage: SqliteStorage;
  #head: number;
  #carried: StagedFile[] = [];
  #serialUntilFirstFailure: Promise<unknown> = Promise.resolve();

  constructor(options: ReplicatedStorageOptions, storage: SqliteStorage, head: number) {
    this.#options = options; this.#storage = storage; this.#head = head;
  }

  get holder(): string { return this.#options.holder; }
  get epoch(): number { return this.#options.epoch; }
  get head(): number { return this.#head; }

  carry(files: readonly StagedFile[]): void { this.#carried.push(...files); }

  appendFiles(files: readonly StagedFile[]): Promise<void> {
    return this.#serialized(async () => {
      const at = await this.#append({ files, removed: [], batch: null });
      await this.#options.database.applyWithoutBatch(at, () => this.#publish(files));
      this.#head = at;
    });
  }

  removeFiles(paths: readonly string[]): Promise<void> {
    return this.#serialized(async () => {
      const at = await this.#append({ files: [], removed: paths, batch: null });
      await this.#options.database.applyWithoutBatch(at, () => removePaths(this.#options.stateDirectory, paths));
      this.#head = at;
    });
  }

  readonly commit = (writes: readonly StorageWrite[], context: Context): Promise<Seq> => this.#serialized(async () => {
    const { database } = this.#options;
    const json = JSON.stringify(writes);
    const logged = parseBatch(json, this.#head + 1);
    const piSeq = await database.dryRun(() => this.#storage.commit(logged, context));
    const files = this.#carried.splice(0);
    const at = await this.#append({ files, removed: [], batch: { piSeq, json } });
    const committed = await database.apply(at, piSeq, { publish: () => this.#publish(files), commit: () => this.#storage.commit(logged, context) });
    this.#head = at;
    return committed;
  });

  #serialized<T>(step: () => Promise<T>): Promise<T> {
    const result = this.#serialUntilFirstFailure.then(step);
    this.#serialUntilFirstFailure = result;
    return result;
  }

  async #append({ files, removed, batch }: { readonly files: readonly StagedFile[]; readonly removed: readonly string[];
    readonly batch: { readonly piSeq: number; readonly json: string } | null }): Promise<number> {
    const { link, holder, epoch, signal } = this.#options;
    const body = { at: this.#head + 1, epoch, versions: await versions(), files: files.map(({ record }) => record), removed: [...removed],
      batch: batch === null ? null : { pi_seq: batch.piSeq, body: await this.#batchBody(batch.json) } };
    const entry: LogEntry = { ...body, digest: logEntryDigest(body) };
    // The authority takes a repeated append from the current owner as the same
    // append, so a repeat after a lost exchange is safe.
    const reply = await repeatUntilAnswered(() => link.command({ op: "append", holder, entry }), signal);
    if (reply.result === "accepted") return entry.at;
    if (reply.reason === "sealed" || reply.reason === "fenced") throw fenced(this.#options, reply.reason, reply.state);
    throw new Error(`The authority refused log entry ${entry.at} as ${reply.reason}: this owner's head is ${this.#head}, and the authority's is ${reply.state?.head ?? "unknown"}`);
  }

  async #batchBody(json: string): Promise<BatchBody> {
    const bytes = Buffer.from(json, "utf8");
    if (bytes.byteLength <= INLINE_BATCH_LIMIT_BYTES) return { kind: "inline", json };
    const sha256 = sha256Hex(bytes);
    await repeatUntilAnswered(() => this.#options.link.putBlob(sha256, bytes), this.#options.signal);
    return { kind: "blob", sha256, size: bytes.byteLength };
  }

  #publish(files: readonly StagedFile[]): Promise<void> {
    return publishFiles(files.map(({ record, staged }) => ({ synced: staged, path: replicatedFilePath(this.#options.stateDirectory, record) })));
  }
}
