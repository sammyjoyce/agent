import { appendFileSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { FailoverReport } from "../../../src/generated/FailoverReport.js";
import type { FailoverRequest } from "../../../src/generated/FailoverRequest.js";

/**
 * What the invented authority answers each request, reread on every run.
 * "fail" is an unreachable authority. This helper stands in for the built
 * `failover/helper.js` only where a test needs an answer the real authority
 * cannot be made to give at a chosen moment. Each test that uses it says which.
 */
export type FailoverAnswers = Partial<Record<FailoverRequest["op"], FailoverReport | "fail">>;

const home = process.env.HOME, session = process.env.AGENT_FAILOVER, argument = process.argv[2];
if (home === undefined || session === undefined || argument === undefined) throw new Error("The failover fixture needs HOME, AGENT_FAILOVER and a request");
const request = JSON.parse(argument) as FailoverRequest;
const answers = JSON.parse(readFileSync(join(home, "failover-answers.json"), "utf8")) as FailoverAnswers;
const answer = answers[request.op] ?? "fail";
appendFileSync(join(home, "failover-runs.ndjson"), JSON.stringify({ request, session: JSON.parse(session), answer }) + "\n");
if (answer === "fail") {
  process.stderr.write("The invented authority is unreachable.\n");
  process.exitCode = 1;
} else process.stdout.write(JSON.stringify(answer) + "\n");
