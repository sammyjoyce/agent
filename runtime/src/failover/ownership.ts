import { writeSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Storage } from "@earendil-works/pi-durable";
import { openConversationDatabase } from "../conversation-database.js";
import { OWNER_FENCED_EXIT } from "../generated/owner-fenced-exit.js";
import type { AuthorityLink } from "./authority-link.js";
import { ConfirmGate, type OwnerGate } from "./owner-gate.js";
import { openReplicatedStorage, OwnerFenced, type LogWriter } from "./replicated-storage.js";
import { cleanRetainedFiles } from "./retained-files.js";
import { ScopedDatabase } from "./scoped-database.js";
import { ownerSession } from "./session.js";

const OWNER_CHECK_INTERVAL_MS = 5_000;

/** What makes this process the one owner of its coordinator. */
export type Ownership =
  /** No failover: the writer lock that Rust holds alone decides. */
  | { readonly kind: "local" }
  /** The authority granted `epoch` to `holder` for this start, and every commit and effect is checked against it. */
  | {
    readonly kind: "replicated";
    readonly link: AuthorityLink;
    readonly holder: string;
    readonly epoch: number;
    /** Pi's storage, caught up with the log. The Harness that opens over it closes it. */
    readonly storage: Storage;
    readonly log: LogWriter;
    readonly gate: OwnerGate;
  };

export type ReplicatedOwnership = Extract<Ownership, { kind: "replicated" }>;

export interface ReplicatedOwnershipOptions {
  /** The value of `AGENT_FAILOVER`. */
  readonly session: string;
  readonly stateDirectory: string;
  /** Called where the authority's refusal is read. In the Pi child this is `exitFenced`. */
  readonly onFenced: (error: OwnerFenced) => void;
  /** An abort cuts every request to the authority and ends every wait for it, so a closing process can exit. */
  readonly signal: AbortSignal;
}

/**
 * Opens the owner's side of a replicated coordinator: the session database
 * and the retained files caught up with the log, the leftovers of a crash
 * removed, and a check with the authority every 5 s. Without that check an
 * idle owner would never learn that a promotion sealed the log.
 */
export async function openReplicatedOwnership({ session, stateDirectory, onFenced, signal }: ReplicatedOwnershipOptions): Promise<ReplicatedOwnership> {
  const { link, holder, epoch } = await ownerSession(session, { signal });
  const database = await ScopedDatabase.over(await openConversationDatabase(join(stateDirectory, "session.sqlite")));
  const { storage, log } = await openReplicatedStorage({ database, link, holder, epoch, stateDirectory, onFenced, signal });
  // The catch-up has named every file the log names, so what is left under a
  // temporary name or in an unfinished upload is what a crash left behind.
  try { await cleanRetainedFiles(stateDirectory); }
  catch (error) { await storage.close(BACKGROUND_CONTEXT).catch(() => {}); throw error; }
  const gate = new ConfirmGate({ link, holder, epoch, onFenced });
  void watchOwner(gate, signal);
  return { kind: "replicated", link, holder, epoch, storage, log, gate };
}

/** An unreachable authority changes nothing: the gate waits it out, and the next check follows its answer. */
async function watchOwner(gate: OwnerGate, signal: AbortSignal): Promise<void> {
  for (;;) {
    try {
      await sleep(OWNER_CHECK_INTERVAL_MS, undefined, { signal, ref: false });
      await gate.fresh(signal);
    } catch (error) {
      if (signal.aborted || error instanceof OwnerFenced) return;
    }
  }
}

/** The gate an effect outside this process's state waits at, or undefined when the writer lock alone decides ownership. */
export function effectGate(ownership: Ownership): OwnerGate | undefined {
  switch (ownership.kind) {
    case "local": return undefined;
    case "replicated": return ownership.gate;
    default: return ownership satisfies never;
  }
}

/**
 * Ends the Pi child as a fenced owner. It runs where the refusal is read and
 * ends the process in the same turn, so nothing is committed, and no frame is
 * written, after the authority's answer.
 */
export function exitFenced(error: OwnerFenced): never {
  try { writeSync(process.stderr.fd, `${error.message}. The Pi runtime exits with status ${OWNER_FENCED_EXIT}.\n`); }
  catch { /* A closed stderr must not delay the exit. */ }
  process.exit(OWNER_FENCED_EXIT);
}
