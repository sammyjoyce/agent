import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { LogPage } from "../generated/LogPage.js";

/** One coordinator's authority and blob store, as a holder reaches them. */
export interface AuthorityLink {
  /** Runs one command. A refusal is a reply, and only a transport failure rejects. */
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
