import { createHash } from "node:crypto";
import { decide } from "../../src/failover/authority-core.js";
import type { AuthorityLink } from "../../src/failover/authority-link.js";
import type { AuthorityCommand } from "../../src/generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../../src/generated/AuthorityRecord.js";
import type { LogEntry } from "../../src/generated/LogEntry.js";

/**
 * The authority's real rules over in-process storage, for tests that need to
 * stop between two steps. It has no row limit and no transport, so the Worker
 * tests on local workerd stay the proof of the deployed object.
 */
export class MemoryAuthority implements AuthorityLink {
  current: AuthorityRecord | undefined;
  readonly entries = new Map<number, LogEntry>();
  readonly blobs = new Map<string, Uint8Array>();
  /** Runs before each command reaches the rules. Throw to fail the exchange. */
  before: (command: AuthorityCommand) => void | Promise<void> = () => {};
  /** Runs after a command was applied and before its reply returns. Throw to lose the reply. */
  after: (command: AuthorityCommand) => void | Promise<void> = () => {};

  async command(command: AuthorityCommand) {
    await this.before(command);
    if (command.op === "append") {
      const { batch, files } = command.entry;
      const named = [...files.map((file) => file.sha256), ...(batch?.kind === "blob" ? [batch.sha256] : [])];
      if (named.some((sha256) => !this.blobs.has(sha256))) return { result: "refused", reason: "missing_blob", state: this.current?.state ?? null } as const;
    }
    const decision = decide(this.current, structuredClone(command), (at) => this.entries.get(at)?.digest);
    this.current = decision.record;
    if (decision.write?.type === "append") this.entries.set(decision.write.entry.at, decision.write.entry);
    if (decision.write?.type === "checkpoint") {
      for (const at of this.entries.keys()) if (at <= decision.write.record.through) this.entries.delete(at);
    }
    await this.after(command);
    return structuredClone(decision.reply);
  }

  async record() { return structuredClone(this.current); }

  async log(after: number, limit: number) {
    if (this.current === undefined) throw new Error("This coordinator is not enrolled");
    const entries = [...this.entries.values()].filter((entry) => entry.at > after).sort((a, b) => a.at - b.at).slice(0, limit);
    return structuredClone({ record: this.current, entries });
  }

  async putBlob(sha256: string, bytes: Uint8Array) {
    if (createHash("sha256").update(bytes).digest("hex") !== sha256) throw new Error("The blob does not match its SHA-256");
    this.blobs.set(sha256, Uint8Array.from(bytes));
  }

  async getBlob(sha256: string) {
    const bytes = this.blobs.get(sha256);
    if (bytes === undefined) throw new Error(`The blob store holds no blob ${sha256}`);
    return Uint8Array.from(bytes);
  }
}
