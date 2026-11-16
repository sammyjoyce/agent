import { setTimeout as sleep } from "node:timers/promises";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import type { Seq, Storage, StorageWrite } from "@earendil-works/pi-durable";
import type { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { AuthorityState } from "../generated/AuthorityState.js";
import type { BatchBody } from "../generated/BatchBody.js";
import type { FileRecord } from "../generated/FileRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";
import type { AuthorityLink } from "./authority-link.js";
import { INLINE_BATCH_LIMIT_BYTES, logEntryDigest, sha256Hex, versions } from "./log-entry.js";
import type { ScopedDatabase } from "./scoped-database.js";
import { followLog, publishFile, replicatedFilePath, type LogFollower } from "./standby.js";

const FIRST_RETRY_MS = 50;
const RETRY_CAP_MS = 5_000;

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
  /** Holds files for the entry of the next Pi batch, which names them ahead of the batch that references them. */
  carry(files: readonly StagedFile[]): void;
}

export interface ReplicatedStorageOptions extends LogFollower {
  readonly holder: string;
  readonly epoch: number;
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
    if (state.kind !== "active" || state.holder !== holder || state.epoch !== epoch) throw new OwnerFenced(state.kind === "active" ? "fenced" : "sealed", state);
    inner = await database.openStorage(record.checkpoint.through);
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
  /** Rejected by the first failure, so nothing is appended once the head and the local position may differ. */
  #line: Promise<unknown> = Promise.resolve();

  constructor(options: ReplicatedStorageOptions, storage: SqliteStorage, head: number) {
    this.#options = options; this.#storage = storage; this.#head = head;
  }

  get holder(): string { return this.#options.holder; }
  get epoch(): number { return this.#options.epoch; }
  get head(): number { return this.#head; }

  carry(files: readonly StagedFile[]): void { this.#carried.push(...files); }

  appendFiles(files: readonly StagedFile[]): Promise<void> {
    return this.#serialized(async () => {
      const at = await this.#append(null, files, null);
      await this.#publish(files);
      await this.#options.database.applyWithoutBatch(at);
      this.#head = at;
    });
  }

  readonly commit = (writes: readonly StorageWrite[], context: Context): Promise<Seq> => this.#serialized(async () => {
    const { database } = this.#options;
    const piSeq = await database.dryRun(() => this.#storage.commit(writes, context));
    const files = this.#carried.splice(0);
    const json = JSON.stringify(writes);
    const at = await this.#append(piSeq, files, json);
    await this.#publish(files);
    // A standby commits the logged JSON, so the owner commits it too. Then a
    // value that JSON changes cannot differ between the two disks.
    const logged = JSON.parse(json) as StorageWrite[];
    const committed = await database.apply(at, piSeq, () => this.#storage.commit(logged, context));
    this.#head = at;
    return committed;
  });

  #serialized<T>(step: () => Promise<T>): Promise<T> {
    const result = this.#line.then(step);
    this.#line = result;
    return result;
  }

  async #append(piSeq: number | null, files: readonly StagedFile[], json: string | null): Promise<number> {
    const { link, holder, epoch } = this.#options;
    const body = { at: this.#head + 1, epoch, versions: await versions(), pi_seq: piSeq, files: files.map(({ record }) => record),
      batch: json === null ? null : await this.#batch(json) };
    const entry: LogEntry = { ...body, digest: logEntryDigest(body) };
    const reply = await this.#untilReachable(() => link.command({ op: "append", holder, entry }));
    if (reply.result === "accepted") return entry.at;
    if (reply.reason === "sealed" || reply.reason === "fenced") throw new OwnerFenced(reply.reason, reply.state);
    throw new Error(`The authority refused log entry ${entry.at} as ${reply.reason}: this owner's head is ${this.#head}, and the authority's is ${reply.state?.head ?? "unknown"}`);
  }

  async #batch(json: string): Promise<BatchBody> {
    const bytes = Buffer.from(json, "utf8");
    if (bytes.byteLength <= INLINE_BATCH_LIMIT_BYTES) return { kind: "inline", json };
    const sha256 = sha256Hex(bytes);
    await this.#untilReachable(() => this.#options.link.putBlob(sha256, bytes));
    return { kind: "blob", sha256, size: bytes.byteLength };
  }

  /** The files have their final names only now that the log names them, and before the position says the entry is applied. */
  async #publish(files: readonly StagedFile[]): Promise<void> {
    for (const { record, staged } of files) await publishFile(staged, replicatedFilePath(this.#options.stateDirectory, record));
  }

  /**
   * Repeats an exchange until the authority answers. Only a transport failure
   * rejects an exchange, and the authority takes a repeated append from the
   * current owner as the same append, so a repeat is safe.
   */
  async #untilReachable<T>(exchange: () => Promise<T>): Promise<T> {
    const { signal } = this.#options;
    for (let wait = FIRST_RETRY_MS; ; wait = Math.min(wait * 2, RETRY_CAP_MS)) {
      try {
        return await exchange();
      } catch (error) {
        if (signal?.aborted) throw new Error("Stopped waiting for the authority, which was unreachable", { cause: error });
      }
      await sleep(wait, undefined, signal === undefined ? {} : { signal }).catch((error: unknown) => {
        throw new Error("Stopped waiting for the authority, which was unreachable", { cause: error });
      });
    }
  }
}
