import { AsyncLocalStorage } from "node:async_hooks";
import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/chord/sqlite";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";

type TransactionMode =
  | { readonly kind: "read" }
  | { readonly kind: "schema" }
  | { readonly kind: "dry-run" }
  | { readonly kind: "apply"; readonly at: number; readonly piSeq: number | null; readonly publish: () => Promise<void> };

/** The two steps that apply one log entry: `publish` gives its files their final names, then `commit` writes its Pi batch. */
export interface EntryApplication<T> {
  readonly publish: () => Promise<void>;
  readonly commit: () => Promise<T>;
}

const REFUSE_WRITES = "PRAGMA query_only = ON";
const ALLOW_WRITES = "PRAGMA query_only = OFF";
const READ_POSITION = "SELECT position FROM beep_boop_failover WHERE singleton = 1";
const HAS_POSITION_TABLE = "SELECT 1 AS present FROM sqlite_schema WHERE type = 'table' AND name = 'beep_boop_failover'";
const SQLITE_READONLY = 8;

/** A write reached the session database outside a dry run and outside the application of a log entry. */
export class UnloggedWrite extends Error {
  constructor(cause: unknown) {
    super("A write to the session database must be a dry run or the application of one log entry", { cause });
    this.name = "UnloggedWrite";
  }
}

/** The state directory was never enrolled or joined, so nothing says which log entries it holds. */
export class PositionMissing extends Error {
  constructor() {
    super("This state directory holds no replication position. Run `beep-boop failover enroll` to enroll it as a replicated coordinator, or `beep-boop failover join` to make it a standby of an enrolled one");
    this.name = "PositionMissing";
  }
}

class DryRunValue {
  constructor(readonly value: unknown) {}
}

function refuseUnlogged(error: unknown): never {
  throw error instanceof Error && "errcode" in error && error.errcode === SQLITE_READONLY ? new UnloggedWrite(error) : error;
}

/**
 * The session database of a replicated coordinator. SQLite itself refuses
 * every write on this connection, and only a dry run or the application of one
 * named log entry lifts that, for one transaction. So no code path can leave a
 * row on local disk that the log lacks.
 */
export class ScopedDatabase implements SqliteDatabase {
  readonly #inner: SqliteDatabase;
  readonly #mode = new AsyncLocalStorage<TransactionMode>();

  private constructor(inner: SqliteDatabase) { this.#inner = inner; }

  /** Takes ownership of `database`, which no other code may keep using. */
  static async over(database: SqliteDatabase): Promise<ScopedDatabase> {
    try {
      await database.exec(REFUSE_WRITES);
      return new ScopedDatabase(database);
    } catch (error) {
      await database.close().catch(() => {});
      throw error;
    }
  }

  /**
   * Opens Pi's storage over this database. It refuses a directory that holds
   * no position, before Pi changes anything in it: nothing is taken to hold a
   * checkpoint that `stampPosition` did not say holds it.
   */
  async openStorage(): Promise<SqliteStorage> {
    await readPosition(this.#inner);
    return this.#mode.run({ kind: "schema" }, () => SqliteStorage.open(this));
  }

  /**
   * Records that this directory holds the log through `position`. Only
   * `failover enroll`, at 0, and `failover join`, at its checkpoint's
   * position, call it. A directory that already holds `position` is left as
   * it is, and one that holds another position is refused.
   */
  async stampPosition(position: number): Promise<void> {
    await this.#mode.run({ kind: "schema" }, () => this.transaction(async (transaction) => {
      await transaction.exec("CREATE TABLE IF NOT EXISTS beep_boop_failover (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), position INTEGER NOT NULL)");
      await transaction.run("INSERT OR IGNORE INTO beep_boop_failover (singleton, position) VALUES (1, ?)", position);
      const held = await readPosition(transaction);
      if (held !== position) throw new Error(`This state directory is at replication position ${held}, so it cannot be stamped at ${position}`);
    }));
  }

  /** The position of the last log entry applied to this directory. */
  async position(): Promise<number> {
    return readPosition(this.#inner);
  }

  /** Runs `commit`, rolls its transaction back, and returns what it returned. */
  dryRun<T>(commit: () => Promise<T>): Promise<T> {
    return this.#mode.run({ kind: "dry-run" }, commit);
  }

  /**
   * Applies the log entry at `at` in the one transaction that `commit` opens.
   * That transaction holds the session database's write lock, so appliers of
   * one directory take turns. It runs `publish` only once it finds this
   * directory at `at - 1`, then the writes of `commit`. It commits only if Pi
   * assigned the batch `piSeq`, and the position moves to `at` in it.
   */
  apply<T>(at: number, piSeq: number, { publish, commit }: EntryApplication<T>): Promise<T> {
    return this.#mode.run({ kind: "apply", at, piSeq, publish }, commit);
  }

  /** Applies a log entry that carries no Pi batch, as `apply` does. */
  applyWithoutBatch(at: number, publish: () => Promise<void>): Promise<void> {
    return this.#mode.run({ kind: "apply", at, piSeq: null, publish }, () => this.transaction(async () => {}));
  }

  transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
    const mode: TransactionMode = this.#mode.getStore() ?? { kind: "read" };
    // Chord runs operations in call order, so nothing runs between these three
    // and no other operation sees the connection with writes allowed.
    const allowed = this.#inner.exec(ALLOW_WRITES);
    const outcome = this.#inner.transaction((transaction) => runInMode(mode, transaction, callback));
    const refused = this.#inner.exec(REFUSE_WRITES);
    return Promise.all([allowed, outcome, refused]).then(([, value]) => value, (error: unknown) => {
      if (error instanceof DryRunValue) return error.value as T;
      if (mode.kind !== "read") throw error;
      return refuseUnlogged(error);
    });
  }

  exec(sql: string): Promise<void> { return this.#inner.exec(sql).catch(refuseUnlogged); }
  run(sql: string, ...params: SqliteValue[]): Promise<void> { return this.#inner.run(sql, ...params).catch(refuseUnlogged); }
  runCounted(sql: string, ...params: SqliteValue[]): Promise<number> { return this.#inner.runCounted(sql, ...params).catch(refuseUnlogged); }
  get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined> { return this.#inner.get<T>(sql, ...params).catch(refuseUnlogged); }
  all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]> { return this.#inner.all<T>(sql, ...params).catch(refuseUnlogged); }
  close(): Promise<void> { return this.#inner.close(); }
}

async function runInMode<T>(mode: TransactionMode, transaction: SqliteExecutor, callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
  switch (mode.kind) {
    case "read":
      // Chord begins every transaction as a write, which SQLite refuses while
      // writes are refused. So the refusal starts here, inside the transaction.
      await transaction.exec(REFUSE_WRITES);
      return callback(transaction);
    case "schema": return callback(transaction);
    case "dry-run": throw new DryRunValue(await callback(transaction));
    case "apply": {
      const position = await readPosition(transaction);
      if (position !== mode.at - 1) throw new Error(`Log entry ${mode.at} does not apply to a directory at position ${position}`);
      await mode.publish();
      const value = await callback(transaction);
      if (mode.piSeq !== null) {
        const metadata = await transaction.get<{ next_seq: number }>("SELECT next_seq FROM durable_metadata WHERE singleton = 1");
        if (metadata?.next_seq !== mode.piSeq + 1) {
          throw new Error(`Log entry ${mode.at} belongs at Pi sequence ${mode.piSeq}, and Pi assigned it ${(metadata?.next_seq ?? Number.NaN) - 1}`);
        }
      }
      await transaction.run("UPDATE beep_boop_failover SET position = ? WHERE singleton = 1", mode.at);
      return value;
    }
    default: return mode satisfies never;
  }
}

async function readPosition(executor: SqliteExecutor): Promise<number> {
  const row = await executor.get(HAS_POSITION_TABLE) === undefined ? undefined : await executor.get<{ position: number }>(READ_POSITION);
  if (row === undefined) throw new PositionMissing();
  return row.position;
}
