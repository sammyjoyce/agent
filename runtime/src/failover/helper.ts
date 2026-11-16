import type { FailoverReport } from "../generated/FailoverReport.js";
import type { FailoverRequest } from "../generated/FailoverRequest.js";
import { tagged } from "./authority-wire.js";
import { helperSession, type HelperSession } from "./session.js";

/** Rust puts no limit on a claim, so the helper bounds its one request itself. */
const REQUEST_TIMEOUT_MS = 10_000;

const failoverRequest = tagged<FailoverRequest, "op">("op", { claim: {}, record: {} });

function parseRequest(argument: string | undefined): FailoverRequest {
  if (argument === undefined) throw new Error("The failover helper needs one request");
  let given: unknown;
  try { given = JSON.parse(argument); }
  catch { throw new Error("The failover helper's request is not JSON"); }
  return failoverRequest(given, "");
}

/** One exchange with the authority. An authority that refuses is a report. One that does not answer rejects. */
async function answer(session: HelperSession, request: FailoverRequest): Promise<FailoverReport> {
  switch (request.op) {
    case "claim": {
      if (session.holder === undefined) throw new Error("A claim needs a holder, and this host's failover session names none");
      const reply = await session.link.command({ op: "claim", holder: session.holder });
      return reply.result === "accepted" ? { result: "claimed", epoch: reply.state.epoch, head: reply.state.head }
        : { result: "refused", reason: reply.reason, state: reply.state };
    }
    case "record":
      return { result: "record", record: await session.link.record() ?? null };
    default:
      return request satisfies never;
  }
}

try {
  const request = parseRequest(process.argv[2]);
  const report = await answer(await helperSession(process.env.AGENT_FAILOVER, { timeoutMs: REQUEST_TIMEOUT_MS }), request);
  process.stdout.write(`${JSON.stringify(report)}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
