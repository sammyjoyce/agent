import { readFile } from "node:fs/promises";
import { AuthorityClient } from "../../src/failover/authority-client.js";
import { parseOperatorSession } from "../../src/failover/operator.js";
import type { FailoverReport } from "../../src/generated/FailoverReport.js";
import type { FailoverRequest } from "../../src/generated/FailoverRequest.js";

/**
 * Stands in for the lane's `failover/helper.js` in tests that run `serve`
 * against the real Worker: it answers `claim` and `record` from the authority.
 */
async function answer(request: FailoverRequest): Promise<FailoverReport> {
  const session = parseOperatorSession(process.env.AGENT_FAILOVER);
  const link = new AuthorityClient({ url: session.url, coordinatorId: session.coordinator_id, token: (await readFile(session.token_file, "utf8")).trim() });
  switch (request.op) {
    case "claim": {
      if (session.holder === undefined) throw new Error("A claim needs a holder");
      const reply = await link.command({ op: "claim", holder: session.holder });
      if (reply.result === "refused") return { result: "refused", reason: reply.reason, state: reply.state };
      if (reply.state.kind !== "active") throw new Error("The authority accepted a claim and reported no owner");
      return { result: "claimed", epoch: reply.state.epoch, head: reply.state.head };
    }
    case "record":
      return { result: "record", record: await link.record() ?? null };
    default:
      return request satisfies never;
  }
}

process.stdout.write(JSON.stringify(await answer(JSON.parse(process.argv[2] ?? "null") as FailoverRequest)) + "\n");
