import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { isAbsolute, join } from "node:path";
import { openConversationDatabase } from "../conversation-database.js";
import type { FailoverSession } from "../generated/FailoverSession.js";
import { AUTHORITY_UNREACHABLE_EXIT } from "../generated/failover-operator.js";
import type { OperatorReport } from "../generated/OperatorReport.js";
import type { OperatorRequest } from "../generated/OperatorRequest.js";
import { AuthorityClient } from "./authority-client.js";
import { AuthorityUnreachable, type AuthorityLink } from "./authority-link.js";
import { isLowercaseUuid } from "./authority-wire.js";
import { fetchCheckpoint, readCheckpointManifest, storeCheckpoint } from "./checkpoint-store.js";
import { PositionMissing, ScopedDatabase } from "./scoped-database.js";
import { applyLog } from "./standby.js";
import { appliedPosition, sessionDatabasePath, unfinishedEffects, verifyStandby } from "./state-directory.js";

/** A part of 16 MiB on a slow uplink needs longer than the client's default. */
const REQUEST_TIMEOUT_MS = 120_000;

/**
 * Parses `AGENT_FAILOVER` strictly: the fields of `FailoverSession` and no other.
 * This belongs in `session.ts` once the bridge and the helper share one parser.
 */
export function parseOperatorSession(text: string | undefined): FailoverSession {
  if (text === undefined) throw new Error("The failover operator needs AGENT_FAILOVER");
  const value: unknown = JSON.parse(text);
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("AGENT_FAILOVER is not a failover session");
  const { url, token_file, coordinator_id, holder, epoch, ...unknown } = value as Record<string, unknown>;
  const extra = Object.keys(unknown);
  if (extra.length > 0) throw new Error(`AGENT_FAILOVER has the unknown field ${extra.join(", ")}`);
  if (typeof url !== "string" || !/^https?:\/\//.test(url)) throw new Error("AGENT_FAILOVER names no authority url");
  if (typeof token_file !== "string" || !isAbsolute(token_file)) throw new Error("AGENT_FAILOVER names no absolute token_file");
  if (typeof coordinator_id !== "string" || !isLowercaseUuid(coordinator_id)) throw new Error("AGENT_FAILOVER names no coordinator_id");
  if (holder !== undefined && (typeof holder !== "string" || !isLowercaseUuid(holder))) throw new Error("AGENT_FAILOVER names a holder that is not a lowercase UUID");
  if (epoch !== undefined && (typeof epoch !== "number" || !Number.isSafeInteger(epoch) || epoch < 0)) throw new Error("AGENT_FAILOVER names an epoch that is not a whole number");
  return { url, token_file, coordinator_id, ...(holder === undefined ? {} : { holder }), ...(epoch === undefined ? {} : { epoch }) };
}

async function scoped(state: string): Promise<ScopedDatabase> {
  const path = sessionDatabasePath(state);
  // Opening a missing database would create an empty one.
  if (!existsSync(path)) throw new Error(`${state} has no session.sqlite, so it is not a coordinator's state directory`);
  return ScopedDatabase.over(await openConversationDatabase(path));
}

async function enrolledRecord(link: AuthorityLink) {
  const record = await link.record();
  if (record === undefined) throw new Error("This coordinator is not enrolled with the authority. Run `beep-boop failover enroll` on its owner first");
  return record;
}

/** Does one request of a `beep-boop failover` command against the authority and one state directory. */
export async function answerOperatorRequest(request: OperatorRequest, session: FailoverSession, link: AuthorityLink): Promise<OperatorReport> {
  switch (request.op) {
    case "status":
      return { result: "status", record: await link.record() ?? null, applied: request.state === null ? null : appliedPosition(request.state) ?? null };
    case "stamp": {
      const database = await scoped(request.state);
      try { await database.stampPosition(request.position); } finally { await database.close(); }
      return { result: "stamped" };
    }
    case "store_checkpoint": {
      const data = join(request.archive, "data"), through = appliedPosition(data);
      if (through === undefined) throw new PositionMissing();
      const coordinatorId = await readFile(join(data, "coordinator-id"), "utf8");
      if (coordinatorId !== session.coordinator_id) throw new Error(`The archive holds coordinator ${coordinatorId}, and this session is for coordinator ${session.coordinator_id}`);
      const { manifest, files, bytes } = await storeCheckpoint(link, request.archive, { through, coordinator_id: session.coordinator_id }, request.part_bytes ?? undefined);
      return { result: "stored", checkpoint: { through, manifest }, files, bytes };
    }
    case "fetch_checkpoint": {
      const { checkpoint } = await enrolledRecord(link);
      const manifest = await readCheckpointManifest(link, checkpoint.manifest);
      if (manifest.coordinator_id !== session.coordinator_id || manifest.through !== checkpoint.through) {
        throw new Error(`The checkpoint manifest is for coordinator ${manifest.coordinator_id} at position ${manifest.through}, and the record names coordinator ${session.coordinator_id} at position ${checkpoint.through}`);
      }
      const { files, bytes } = await fetchCheckpoint(link, manifest, request.archive);
      const held = appliedPosition(join(request.archive, "data"));
      if (held !== checkpoint.through) throw new Error(`The checkpoint's database holds the log through position ${held ?? "none"}, and its manifest says ${checkpoint.through}`);
      return { result: "fetched", checkpoint, files, bytes };
    }
    case "authority":
      return { result: "reply", reply: await link.command(request.command) };
    case "follow": {
      const from = appliedPosition(request.state);
      if (from === undefined) throw new PositionMissing();
      return { result: "followed", from, applied: await applyLog({ database: await scoped(request.state), link, stateDirectory: request.state }) };
    }
    case "verify":
      return { result: "verified", ...await verifyStandby(link, request.state) };
    case "unfinished":
      return { result: "unfinished", ...unfinishedEffects(request.state) };
    default:
      return request satisfies never;
  }
}

async function main(): Promise<void> {
  const session = parseOperatorSession(process.env.AGENT_FAILOVER), argument = process.argv[2];
  if (argument === undefined) throw new Error("The failover operator needs one request");
  const token = (await readFile(session.token_file, "utf8")).trim();
  const link = new AuthorityClient({ url: session.url, coordinatorId: session.coordinator_id, token, timeoutMs: REQUEST_TIMEOUT_MS });
  // Rust builds the request from its own type, so it is trusted as that type.
  const report = await answerOperatorRequest(JSON.parse(argument) as OperatorRequest, session, link);
  process.stdout.write(JSON.stringify(report) + "\n");
}

if (import.meta.main) {
  void main().catch((error: unknown) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = error instanceof AuthorityUnreachable ? AUTHORITY_UNREACHABLE_EXIT : 1;
  });
}
