import { AsyncLocalStorage } from "node:async_hooks";
import type { SqliteDatabase, SqliteExecutor, SqliteValue } from "@earendil-works/chord/sqlite";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";

/** How one transaction may change the session database. A transaction with no mode can only read. */
type TransactionMode =
  /** Pi's schema work and the creation of the position table. */
  | { readonly kind: "open" }
  | { readonly kind: "dry-run" }
  | { readonly kind: "apply"; readonly at: number; readonly piSeq: number | null };

const REFUSE_WRITES = "PRAGMA query_only = ON";
const ALLOW_WRITES = "PRAGMA query_only = OFF";
const READ_POSITION = "SELECT position FROM beep_boop_failover WHERE singleton = 1";
const SQLITE_READONLY = 8;

/** A write reached the session database outside a dry run and outside the application of a log entry. */
export class UnloggedWrite extends Error {
  constructor(cause: unknown) {
    super("A write to the session database must be a dry run or the application of one log entry", { cause });
    this.name = "UnloggedWrite";
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
   * Opens Pi's storage over this database. A directory that opens in replicated
   * mode for the first time is taken to hold the checkpoint, at `through`.
   */
  async openStorage(through: number): Promise<SqliteStorage> {
    return this.#mode.run({ kind: "open" }, async () => {
      const storage = await SqliteStorage.open(this);
      await this.transaction(async (transaction) => {
        await transaction.exec("CREATE TABLE IF NOT EXISTS beep_boop_failover (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), position INTEGER NOT NULL)");
        await transaction.run("INSERT OR IGNORE INTO beep_boop_failover (singleton, position) VALUES (1, ?)", through);
      });
      return storage;
    });
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
   * Runs `commit` as the application of the log entry at `at`. Its transaction
   * commits only if this directory is at `at - 1` and, for a Pi batch, Pi
   * assigned it `piSeq`. The position moves to `at` in the same transaction.
   */
  apply<T>(at: number, piSeq: number | null, commit: () => Promise<T>): Promise<T> {
    return this.#mode.run({ kind: "apply", at, piSeq }, commit);
  }

  /** Applies a log entry that carries no Pi batch. */
  applyWithoutBatch(at: number): Promise<void> {
    return this.apply(at, null, () => this.transaction(async () => {}));
  }

  transaction<T>(callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
    const mode = this.#mode.getStore();
    // Chord runs operations in call order, so nothing runs between these three
    // and no other operation sees the connection with writes allowed.
    const allowed = this.#inner.exec(ALLOW_WRITES);
    const outcome = this.#inner.transaction((transaction) => runInMode(mode, transaction, callback));
    const refused = this.#inner.exec(REFUSE_WRITES);
    return Promise.all([allowed, outcome, refused]).then(([, value]) => value, (error: unknown) => {
      if (error instanceof DryRunValue) return error.value as T;
      if (mode !== undefined) throw error;
      return refuseUnlogged(error);
    });
  }

  exec(sql: string): Promise<void> { return this.#inner.exec(sql).catch(refuseUnlogged); }
  run(sql: string, ...params: SqliteValue[]): Promise<void> { return this.#inner.run(sql, ...params).catch(refuseUnlogged); }
  get<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T | undefined> { return this.#inner.get<T>(sql, ...params).catch(refuseUnlogged); }
  all<T extends object>(sql: string, ...params: SqliteValue[]): Promise<T[]> { return this.#inner.all<T>(sql, ...params).catch(refuseUnlogged); }
  close(): Promise<void> { return this.#inner.close(); }
}

async function runInMode<T>(mode: TransactionMode | undefined, transaction: SqliteExecutor, callback: (transaction: SqliteExecutor) => Promise<T>): Promise<T> {
  if (mode === undefined) {
    // Chord begins every transaction as a write, which SQLite refuses while
    // writes are refused. So the refusal starts here, inside the transaction.
    await transaction.exec(REFUSE_WRITES);
    return callback(transaction);
  }
  switch (mode.kind) {
    case "open": return callback(transaction);
    case "dry-run": throw new DryRunValue(await callback(transaction));
    case "apply": {
      const position = await readPosition(transaction);
      if (position !== mode.at - 1) throw new Error(`Log entry ${mode.at} does not apply to a directory at position ${position}`);
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
  const row = await executor.get<{ position: number }>(READ_POSITION);
  if (row === undefined) throw new Error("The session database has no replication position");
  return row.position;
}
