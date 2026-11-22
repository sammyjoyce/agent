import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer, type ServerResponse } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { statesExpiredCertificateCause } from "./fixtures/tool-discovery-oracle.js";

const LIVE_EVAL = fileURLToPath(new URL("./tool-discovery-eval.test.js", import.meta.url));

type Reply = { text: string } | { call: string; arguments: Record<string, unknown> } | { failure: string };

function stream(response: ServerResponse, reply: Reply, index: number): void {
  const id = `resp_example_${index}`, usage = { input_tokens: 120, output_tokens: 8, total_tokens: 128,
    input_tokens_details: { cached_tokens: 40 }, output_tokens_details: { reasoning_tokens: 2 } };
  const events: object[] = [{ type: "response.created", response: { id, object: "response", status: "in_progress", output: [] } }];
  if ("failure" in reply) {
    events.push({ type: "response.failed", response: { id, object: "response", status: "failed", output: [], error: { code: "server_error", message: reply.failure } } });
  } else {
    const item = "text" in reply
      ? { id: `msg_example_${index}`, type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: reply.text, annotations: [] }] }
      : { id: `fc_example_${index}`, type: "function_call", status: "completed", call_id: `call_example_${index}`, name: reply.call, arguments: JSON.stringify(reply.arguments) };
    events.push({ type: "response.output_item.added", output_index: 0, item: "text" in reply ? { ...item, status: "in_progress", content: [] } : { ...item, status: "in_progress", arguments: "" } });
    if ("text" in reply) events.push({ type: "response.output_text.delta", output_index: 0, item_id: item.id, content_index: 0, delta: reply.text });
    else events.push({ type: "response.function_call_arguments.delta", output_index: 0, item_id: item.id, delta: JSON.stringify(reply.arguments) });
    events.push({ type: "response.output_item.done", output_index: 0, item },
      { type: "response.completed", response: { id, object: "response", status: "completed", output: [item], usage } });
  }
  response.writeHead(200, { "content-type": "text/event-stream" });
  for (const event of events) response.write("data: " + JSON.stringify(event) + "\n\n");
  response.end();
}

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }

function declaredTools(body: unknown): string[] {
  const list = (value: unknown): unknown[] => Array.isArray(value) ? value : [];
  const updates = object(body) ? list(body.input).flatMap((item) => object(item) && item.type === "additional_tools" ? list(item.tools) : []) : [];
  return [...(object(body) ? list(body.tools) : []), ...updates].flatMap((tool) => object(tool) && typeof tool.name === "string" ? [tool.name] : []);
}

function inOrder(replies: readonly Reply[]): () => Reply | undefined {
  let next = 0;
  return () => replies[next++];
}

async function runLiveEval(reply: (tools: readonly string[]) => Reply | undefined, scenario = "direct-answer") {
  let served = 0;
  const server = createServer((request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk)).on("end", () => {
      const next = request.method === "POST" && request.url?.endsWith("/responses")
        ? reply(declaredTools(JSON.parse(Buffer.concat(chunks).toString("utf8")))) : undefined;
      if (next === undefined) { response.writeHead(404).end(); return; }
      stream(response, next, served++);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address(); assert.ok(address !== null && typeof address !== "string");
  const directory = await mkdtemp(join(tmpdir(), "agent-tool-discovery-report-")), out = join(directory, "units.jsonl");
  try {
    const env = { PATH: process.env.PATH ?? "", HOME: directory, AGENT_TOOL_DISCOVERY_EVAL: "1", OPENAI_API_KEY: "sk-example",
      OPENAI_BASE_URL: `http://127.0.0.1:${address.port}/v1`, AGENT_TOOL_DISCOVERY_SCENARIOS: scenario, AGENT_TOOL_DISCOVERY_TRIALS: "1",
      AGENT_TOOL_DISCOVERY_CONCURRENCY: "1", AGENT_TOOL_DISCOVERY_REASONING: "low", AGENT_TOOL_DISCOVERY_OUT: out };
    const { code, stdout } = await new Promise<{ code: number; stdout: string }>((resolve) => {
      execFile(process.execPath, ["--test", "--test-reporter=tap", LIVE_EVAL], { env, timeout: 60_000 }, (error, stdout) =>
        resolve({ code: error === null ? 0 : typeof error.code === "number" ? error.code : 1, stdout }));
    });
    const rows = (await readFile(out, "utf8")).trim().split("\n").map((line) => JSON.parse(line) as Record<string, unknown>);
    return { code, stdout, rows, served };
  } finally {
    server.closeAllConnections(); await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
}

test("a failed scenario fails the live eval and names the unit in its TAP output", { timeout: 90_000 }, async () => {
  const { code, stdout, rows } = await runLiveEval(inOrder([{ text: "I am not sure." }]));
  assert.equal(rows.length, 1); assert.equal(rows[0]?.success, false);
  assert.match(stdout, /^\s*not ok \d+ - direct t1 direct-answer$/mu, "The unit is reported as a failed test");
  assert.notEqual(code, 0, "The eval process exits with a failure");
});

test("the live eval reports a recovered retry and a tool error apart from failed units", { timeout: 90_000 }, async () => {
  const { code, stdout, rows, served } = await runLiveEval(inOrder([{ failure: "upstream request failed" },
    { call: "read_task", arguments: { task_id: "example-missing-task", include_history: false } }, { text: "210" }]));
  assert.equal(served, 3);
  assert.equal(rows.length, 1);
  assert.deepEqual({ success: rows[0]?.success, error: rows[0]?.error, requests: rows[0]?.requests, retries: rows[0]?.retries, tool_errors: rows[0]?.tool_errors },
    { success: true, error: null, requests: 3, retries: 1, tool_errors: 1 });
  assert.match(stdout, /^\s*ok \d+ - direct t1 direct-answer$/mu);
  assert.match(stdout, /errors 0; recovered retries 1; tool errors 1;/u);
  assert.equal(code, 0, stdout);
});

function runChildAgent(childSummary: string, parentEvidence: string) {
  const parent = inOrder([
    { call: "spawn_agent", arguments: { title: "Read incident 0412", outcome: "Report the root cause that docs/incident-0412.md states.",
      input: "Read docs/incident-0412.md and report the root cause it states on a line that begins \"Root cause:\"." } },
    { call: "wait_agents", arguments: { timeout_seconds: 60 } },
    { call: "record_task", arguments: { summary: "The agent reported the incident's root cause.", state: { state: "resolved", evidence: parentEvidence } } },
    { text: "Recorded the root cause." }]);
  const child = inOrder([{ call: "report_result", arguments: { summary: childSummary } }, { text: "Reported the root cause." }]);
  return runLiveEval((tools) => tools.includes("report_result") ? child() : parent() ?? { text: "The task is already resolved." }, "child-agent");
}

const SEEDED_CAUSE = "Root cause: an expired TLS certificate on the staging relay rejected every deploy upload.";
const DENIED_CAUSES = ["Root cause: There was no expired certificate; a full disk caused the deploy failure.", "Root cause: the certificate was not expired",
  "Root cause: it wasn't an expired certificate", "Root cause: we ruled out an expired certificate", "Root cause: not caused by an expired TLS certificate",
  "Root cause: a full disk, not an expired certificate.", "Root cause: unknown. An expired certificate was ruled out.",
  "Root cause (per the doc): an expired TLS certificate — but we disproved that."];
const RECORDED_CHILD_SUMMARIES = [
  "Read docs/incident-0412.md without modifying files. It states: Root cause: an expired TLS certificate on the staging relay rejected every deploy upload.",
  "Read docs/incident-0412.md without modifying files. Its stated root cause is: an expired TLS certificate on the staging relay rejected every deploy upload.",
  "Read docs/incident-0412.md without modifying files. Root cause: an expired TLS certificate on the staging relay rejected every deploy upload."];

test("the child-agent scenario fails when the child or parent denies or replaces the seeded root cause", { timeout: 180_000, concurrency: true }, async (t) => {
  const cases = [...DENIED_CAUSES.map((denial) => [denial, denial] as const),
    ["Root cause: an expired TLS certificate on the staging relay rejected the uploads.", "Root cause: we ruled out an expired certificate"] as const];
  await Promise.all(cases.map(([child, parent]) => t.test(`child "${child}", parent "${parent}"`, async () => {
    const { code, stdout, rows } = await runChildAgent(child, parent);
    assert.equal(rows.length, 1); assert.equal(rows[0]?.success, false, String(rows[0]?.detail));
    assert.deepEqual(JSON.parse(String(rows[0]?.detail)), { agents: [{ state: "done", summary: child }], state: "resolved", evidence: parent },
      "The child finished and the parent resolved, so the oracle rejected the answers");
    assert.match(stdout, /^\s*not ok \d+ - direct t1 child-agent$/mu);
    assert.notEqual(code, 0);
  })));
});

test("the child-agent scenario passes when both answers state the seeded root cause, and keeps both answers", { timeout: 180_000, concurrency: true }, async (t) => {
  const cases = [...["Root cause: an expired TLS certificate on the staging relay rejected the uploads", "Root cause: the relay's certificate had expired"]
    .map((answer) => [answer, answer] as const), ...RECORDED_CHILD_SUMMARIES.map((summary) => [summary, SEEDED_CAUSE] as const)];
  await Promise.all(cases.map(([child, parent]) => t.test(`child "${child}", parent "${parent}"`, async () => {
    const { code, stdout, rows } = await runChildAgent(child, parent);
    assert.equal(rows.length, 1); assert.equal(rows[0]?.success, true, String(rows[0]?.detail));
    assert.deepEqual(JSON.parse(String(rows[0]?.detail)), { agents: [{ state: "done", summary: child }], state: "resolved", evidence: parent });
    assert.equal(code, 0, stdout);
  })));
});

test("the child-agent oracle judges meaning, handles paraphrases, and rejects denials across clauses or later sentences", () => {
  for (const right of [SEEDED_CAUSE, ...RECORDED_CHILD_SUMMARIES,
    "The agent read the report.\n**Root cause:** The staging relay's TLS certificate had expired, so it rejected deploy uploads.",
    "- Root cause: the TLS certificate on the staging relay was expired",
    "Root cause: deploy uploads failed because the staging relay's SSL certificate had lapsed and was not renewed in time."]) {
    assert.equal(statesExpiredCertificateCause(right), true, right);
  }
  for (const wrong of [...DENIED_CAUSES, "An expired TLS certificate on the staging relay rejected every deploy upload.",
    "Root cause: a malformed environment variable. The certificate had expired earlier but was renewed.",
    "Root cause: an expired TLS certificate on the staging relay did not reject the uploads.",
    "Root cause: an expired TLS certificate on the staging relay.\nRoot cause: a full disk on the build host.",
    "Not the root cause: an expired TLS certificate on the staging relay.",
    "Root cause: an expired TLS certificate on the staging relay. Update: we ruled that out; the certificate was still valid.",
    "Root cause: an expired TLS certificate on the staging relay. Correction: the certificate was not expired; DNS failed.",
    "Root cause: DNS resolution failed instead of an expired TLS certificate.",
    "Root cause: we excluded an expired TLS certificate as the culprit and found a bad route.",
    "Root cause: discarded theory that an expired TLS certificate broke uploads; a full disk did."]) {
    assert.equal(statesExpiredCertificateCause(wrong), false, wrong);
  }
});
