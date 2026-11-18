import { setTimeout as sleep } from "node:timers/promises";
import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { LogPage } from "../generated/LogPage.js";

const FIRST_RETRY_MS = 50;
const RETRY_CAP_MS = 5_000;

/** The authority did not answer: a transport failure, a timeout or a server error. Only this rejection is safe to repeat. */
export class AuthorityUnreachable extends Error {}

/**
 * Repeats an exchange until the authority answers, waiting longer after each
 * try. Use it only for an exchange the authority takes twice as once. Any
 * rejection but `AuthorityUnreachable` is final. An abort of `signal` ends the
 * wait with an error.
 */
export async function repeatUntilAnswered<T>(exchange: () => Promise<T>, signal?: AbortSignal): Promise<T> {
  for (let wait = FIRST_RETRY_MS; ; wait = Math.min(wait * 2, RETRY_CAP_MS)) {
    try {
      return await exchange();
    } catch (error) {
      if (!(error instanceof AuthorityUnreachable)) throw error;
      if (signal?.aborted) throw new Error("Stopped waiting for the authority, which was unreachable", { cause: error });
    }
    await sleep(wait, undefined, signal === undefined ? {} : { signal }).catch((error: unknown) => {
      throw new Error("Stopped waiting for the authority, which was unreachable", { cause: error });
    });
  }
}

/** One coordinator's authority and blob store, as a holder reaches them. */
export interface AuthorityLink {
  /** Runs one command. A refusal is a reply. An authority that did not answer rejects with `AuthorityUnreachable`. */
  command(command: AuthorityCommand): Promise<AuthorityReply>;
  /** The record, or undefined before enrollment. */
  record(): Promise<AuthorityRecord | undefined>;
  /** Entries after `after` in order, at most `limit`. Rejects before enrollment. */
  log(after: number, limit: number): Promise<LogPage>;
  /** Stores bytes under their SHA-256. Storing the same bytes again succeeds. */
  putBlob(sha256: string, bytes: Uint8Array): Promise<void>;
  /** Rejects when the blob store holds no such blob. */
  getBlob(sha256: string): Promise<Uint8Array>;
}
