import { AUTHORITY_UNREACHABLE_EXIT } from "../generated/authority-unreachable-exit.js";
import type { FailoverReport } from "../generated/FailoverReport.js";
import type { FailoverRequest } from "../generated/FailoverRequest.js";
import { AuthorityUnreachable } from "./authority-link.js";
import { tagged, text } from "./authority-wire.js";
import { scriptSession, type ScriptSession } from "./session.js";
import { appliedPosition } from "./state-directory.js";

/** Rust puts no limit on a claim, so the helper bounds each request itself. */
const REQUEST_TIMEOUT_MS = 10_000;
/** How often a claim reads the epoch again after another claim of this holder moved it. */
const CLAIM_ATTEMPTS = 3;

const failoverRequest = tagged<FailoverRequest, "op">("op", { claim: { state: text }, record: {} });

function parseRequest(argument: string | undefined): FailoverRequest {
  if (argument === undefined) throw new Error("The failover helper needs one request");
  let given: unknown;
  try { given = JSON.parse(argument); }
  catch { throw new Error("The failover helper's request is not JSON"); }
  return failoverRequest(given, "");
}

/** An authority that refuses is a report. One that does not answer rejects with `AuthorityUnreachable`, and the helper never sends that request again. */
async function answer(session: ScriptSession, request: FailoverRequest): Promise<FailoverReport> {
  switch (request.op) {
    case "claim": {
      if (session.holder === undefined) throw new Error("A claim needs a holder, and this host's failover session names none");
      // A claim raises the epoch, and the Pi child refuses a directory with no position, so the check comes first.
      if (appliedPosition(request.state) === undefined) return { result: "unstamped" };
      // Each claim names the epoch it read, so one that arrives late, after a later start claimed, is refused and fences nobody.
      for (let attempt = 1; ; attempt += 1) {
        const record = await session.link.record();
        if (record === undefined) return { result: "refused", reason: "not_enrolled", state: null };
        const reply = await session.link.command({ op: "claim", holder: session.holder, expected_epoch: record.state.epoch });
        if (reply.result === "accepted") return { result: "claimed", epoch: reply.state.epoch, head: reply.state.head };
        if (reply.reason !== "epoch_moved" || attempt === CLAIM_ATTEMPTS) return { result: "refused", reason: reply.reason, state: reply.state };
      }
    }
    case "record":
      return { result: "record", record: await session.link.record() ?? null };
    default:
      return request satisfies never;
  }
}

try {
  const request = parseRequest(process.argv[2]);
  const report = await answer(await scriptSession(process.env.AGENT_FAILOVER, { timeoutMs: REQUEST_TIMEOUT_MS }), request);
  process.stdout.write(`${JSON.stringify(report)}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = error instanceof AuthorityUnreachable ? AUTHORITY_UNREACHABLE_EXIT : 1;
}
