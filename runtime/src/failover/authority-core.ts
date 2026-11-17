import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityRefusal } from "../generated/AuthorityRefusal.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { AuthorityState } from "../generated/AuthorityState.js";
import type { CheckpointRecord } from "../generated/CheckpointRecord.js";
import type { LogEntry } from "../generated/LogEntry.js";

/** The digest of the log entry at a position, or undefined when the log holds none there. */
export type DigestAt = (at: number) => string | undefined;

export type AuthorityWrite =
  | { readonly type: "append"; readonly entry: LogEntry }
  /** Replaces the checkpoint and drops every log entry at or before `record.through`. */
  | { readonly type: "checkpoint"; readonly record: CheckpointRecord };

export interface AuthorityDecision {
  readonly record: AuthorityRecord | undefined;
  readonly reply: AuthorityReply;
  readonly write?: AuthorityWrite;
}

/**
 * The authority's rules. A pure function with no I/O and no clock, so the
 * object can run each command as one synchronous transaction: read the record,
 * decide, then store `record` and apply `write`.
 */
export function decide(record: AuthorityRecord | undefined, command: AuthorityCommand, digestAt: DigestAt): AuthorityDecision {
  const refuse = (reason: AuthorityRefusal): AuthorityDecision =>
    ({ record, reply: { result: "refused", reason, state: record?.state ?? null } });
  if (record === undefined) {
    if (command.op !== "enroll") return refuse("not_enrolled");
    if (command.checkpoint.through !== 0) return refuse("checkpoint_out_of_range");
    return accept({ state: { kind: "active", epoch: 1, holder: command.holder, head: 0 }, checkpoint: command.checkpoint });
  }
  const { state, checkpoint } = record;
  const move = (next: AuthorityState, write?: AuthorityWrite) => accept({ state: next, checkpoint }, write);
  const owns = (holder: string, epoch: number) => state.kind === "active" && state.holder === holder && state.epoch === epoch;
  const fenced = () => refuse(state.kind === "active" ? "fenced" : "sealed");
  switch (command.op) {
    case "enroll":
      return state.kind === "active" && state.holder === command.holder ? accept(record) : refuse("enrolled");
    case "claim":
      if (state.kind !== "active" || state.holder !== command.holder) return fenced();
      return command.expected_epoch === state.epoch ? move({ ...state, epoch: state.epoch + 1 }) : refuse("epoch_moved");
    case "append": {
      const { entry } = command;
      if (!owns(command.holder, entry.epoch)) return fenced();
      if (entry.at === state.head + 1) return move({ ...state, head: entry.at }, { type: "append", entry });
      if (entry.at > state.head) return refuse("gap");
      return digestAt(entry.at) === entry.digest ? accept(record) : refuse("conflict");
    }
    case "confirm":
      return owns(command.holder, command.epoch) ? accept(record) : fenced();
    case "checkpoint": {
      if (!owns(command.holder, command.epoch)) return fenced();
      const { through } = command.record;
      if (through < checkpoint.through || through > state.head) return refuse("checkpoint_out_of_range");
      return accept({ state, checkpoint: command.record }, { type: "checkpoint", record: command.record });
    }
    case "promote": {
      if (command.expected_epoch !== state.epoch) return refuse("epoch_moved");
      const { candidate } = command;
      const vacant = (statement: string) =>
        move({ kind: "vacant", epoch: state.epoch, candidate, evidence: { kind: "operator_attested", statement }, head: state.head });
      if (state.kind === "active") {
        if (state.holder === candidate) return refuse("already_owner");
        return command.attestation === null
          ? move({ kind: "sealed", epoch: state.epoch, holder: state.holder, candidate, head: state.head })
          : vacant(command.attestation);
      }
      if (state.kind === "sealed" && command.attestation !== null) {
        return state.holder === candidate ? refuse("self_attestation") : vacant(command.attestation);
      }
      return move({ ...state, candidate });
    }
    case "release":
      if (state.kind !== "sealed" || command.epoch !== state.epoch) return refuse("not_sealed");
      if (command.holder !== state.holder) return refuse("not_sealed_holder");
      return move({ kind: "vacant", epoch: state.epoch, candidate: state.candidate, evidence: { kind: command.evidence }, head: state.head });
    case "activate":
      if (state.kind === "active" && state.holder === command.candidate) return accept(record);
      if (state.kind !== "vacant" || state.candidate !== command.candidate) return refuse("not_candidate");
      if (command.applied !== state.head) return refuse("not_caught_up");
      return move({ kind: "active", epoch: state.epoch + 1, holder: command.candidate, head: state.head });
    default:
      return command satisfies never;
  }
}

function accept(record: AuthorityRecord, write?: AuthorityWrite): AuthorityDecision {
  const decision = { record, reply: { result: "accepted", state: record.state } } as const;
  return write === undefined ? decision : { ...decision, write };
}
