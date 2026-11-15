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

async function runLiveEval(replies: readonly Reply[]) {
  let served = 0;
  const server = createServer((request, response) => {
    request.resume();
    const reply = request.method === "POST" && request.url?.endsWith("/responses") ? replies[served] : undefined;
    if (reply === undefined) { response.writeHead(404).end(); return; }
    stream(response, reply, served++);
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address(); assert.ok(address !== null && typeof address !== "string");
  const directory = await mkdtemp(join(tmpdir(), "agent-tool-discovery-report-")), out = join(directory, "units.jsonl");
  try {
    const env = { PATH: process.env.PATH ?? "", HOME: directory, AGENT_TOOL_DISCOVERY_EVAL: "1", OPENAI_API_KEY: "sk-example",
      OPENAI_BASE_URL: `http://127.0.0.1:${address.port}/v1`, AGENT_TOOL_DISCOVERY_SCENARIOS: "direct-answer", AGENT_TOOL_DISCOVERY_TRIALS: "1",
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
  const { code, stdout, rows } = await runLiveEval([{ text: "I am not sure." }]);
  assert.equal(rows.length, 1); assert.equal(rows[0]?.success, false);
  assert.match(stdout, /^\s*not ok \d+ - direct t1 direct-answer$/mu, "The unit is reported as a failed test");
  assert.notEqual(code, 0, "The eval process exits with a failure");
});

test("the live eval reports a recovered retry and a tool error apart from failed units", { timeout: 90_000 }, async () => {
  const { code, stdout, rows, served } = await runLiveEval([{ failure: "upstream request failed" },
    { call: "read_task", arguments: { task_id: "example-missing-task", include_history: false } }, { text: "210" }]);
  assert.equal(served, 3);
  assert.equal(rows.length, 1);
  assert.deepEqual({ success: rows[0]?.success, error: rows[0]?.error, requests: rows[0]?.requests, retries: rows[0]?.retries, tool_errors: rows[0]?.tool_errors },
    { success: true, error: null, requests: 3, retries: 1, tool_errors: 1 });
  assert.match(stdout, /^\s*ok \d+ - direct t1 direct-answer$/mu);
  assert.match(stdout, /errors 0; recovered retries 1; tool errors 1;/u);
  assert.equal(code, 0, stdout);
});

test("the child-agent oracle accepts the seeded root cause and rejects a contradicting one", () => {
  for (const right of ["Root cause: an expired TLS certificate on the staging relay rejected every deploy upload.",
    "The staging relay's TLS certificate had expired, so it rejected deploy uploads."]) {
    assert.equal(statesExpiredCertificateCause(right), true, right);
  }
  for (const wrong of ["The certificate was not expired; a malformed environment variable caused the incident.",
    "The certificate was healthy. A malformed environment variable was the root cause.",
    "The certificate wasn't expired; the relay ran out of disk.", "A certificate was mentioned, but the cause is unknown."]) {
    assert.equal(statesExpiredCertificateCause(wrong), false, wrong);
  }
});
