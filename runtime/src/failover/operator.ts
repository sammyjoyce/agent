import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { openConversationDatabase } from "../conversation-database.js";
import { AUTHORITY_UNREACHABLE_EXIT } from "../generated/failover-operator.js";
import type { OperatorReport } from "../generated/OperatorReport.js";
import type { OperatorRequest } from "../generated/OperatorRequest.js";
import { AuthorityUnreachable, type AuthorityLink } from "./authority-link.js";
import { fetchCheckpoint, readCheckpointManifest, storeCheckpoint } from "./checkpoint-store.js";
import { PositionMissing, ScopedDatabase } from "./scoped-database.js";
import { scriptSession, type ScriptSession } from "./session.js";
import { applyLog } from "./standby.js";
import { appliedPosition, sessionDatabasePath, unfinishedEffects, verifyStandby } from "./state-directory.js";

/** A part of 16 MiB on a slow uplink needs longer than the client's default. */
const REQUEST_TIMEOUT_MS = 120_000;

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
async function answer({ link, coordinatorId }: ScriptSession, request: OperatorRequest): Promise<OperatorReport> {
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
      const archived = await readFile(join(data, "coordinator-id"), "utf8");
      if (archived !== coordinatorId) throw new Error(`The archive holds coordinator ${archived}, and this session is for coordinator ${coordinatorId}`);
      const { manifest, files, bytes } = await storeCheckpoint(link, request.archive, { through, coordinator_id: coordinatorId }, request.part_bytes ?? undefined);
      return { result: "stored", checkpoint: { through, manifest }, files, bytes };
    }
    case "fetch_checkpoint": {
      const { checkpoint } = await enrolledRecord(link);
      const manifest = await readCheckpointManifest(link, checkpoint.manifest);
      if (manifest.coordinator_id !== coordinatorId || manifest.through !== checkpoint.through) {
        throw new Error(`The checkpoint manifest is for coordinator ${manifest.coordinator_id} at position ${manifest.through}, and the record names coordinator ${coordinatorId} at position ${checkpoint.through}`);
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

try {
  const argument = process.argv[2];
  if (argument === undefined) throw new Error("The failover operator needs one request");
  const session = await scriptSession(process.env.AGENT_FAILOVER, { timeoutMs: REQUEST_TIMEOUT_MS });
  // Rust builds the request from its own type, so it is trusted as that type.
  const report = await answer(session, JSON.parse(argument) as OperatorRequest);
  process.stdout.write(`${JSON.stringify(report)}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = error instanceof AuthorityUnreachable ? AUTHORITY_UNREACHABLE_EXIT : 1;
}
