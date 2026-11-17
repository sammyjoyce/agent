import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openaiProvider } from "@earendil-works/pi-ai/providers/openai";
import { runScheduled, scheduledTaskId } from "../src/scheduled.js";
import { providerFailureMessage } from "../src/models.js";
import { exampleJob, pump } from "./fixtures/background-runtime.js";
import { openScheduled } from "./fixtures/scheduled-runtime.js";
import { fixtureModel } from "./model.js";

const generic = "Worker execution did not complete; inspect the retained task and its pending input";

for (const scenario of ["authentication", "rate", "authentication after older rate", "unknown provider", "arbitrary preparation error"] as const) {
  test("scheduled outcome persists safe " + scenario + " across a fresh process without replay", { timeout: 20_000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-scheduled-model-error-"));
    let requests = 0;
    const server = createServer(async (request, response) => {
      for await (const _chunk of request) { /* Consume the real serializer's request. */ }
      requests += 1;
      const status = scenario === "authentication after older rate" && requests === 1 ? 429
        : scenario.startsWith("authentication") ? 401 : scenario === "rate" ? 429 : 500;
      response.writeHead(status, { "content-type": "text/plain" });
      response.end("INVENTED_PRIVATE_PROVIDER_BODY with unrelated identifier 4010");
    });
    await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
    const address = server.address(); assert.ok(address && typeof address !== "string");
    const native = openaiProvider(), original = native.getModels()[0]; assert.ok(original);
    const app = await openScheduled(directory, "original", undefined, [{
      ...native,
      getModels: () => [{ ...original, id: "fixture", baseUrl: "http://127.0.0.1:" + address.port + "/v1" }],
      auth: { apiKey: { name: "Invented loopback fixture", resolve: async () => ({ auth: { apiKey: "invented-local-only" } }) } },
    }]);
    let closed = false;
    try {
      if (scenario === "arbitrary preparation error") app.tasks.useActorExecution({
        available: () => true, extensions: () => [], bind: () => () => {},
        call: async () => ({ type: "failed", message: "Unused fixture call" }),
        prepare: async () => { throw new Error("INVENTED_PRIVATE_PREPARATION_BODY"); },
      });
      const occurrence = { id: "invented-error-" + scenario, job: { ...exampleJob(), model: fixtureModel }, schedule_id: "daily", scheduled_at: Date.UTC(2027, 0, 2) };
      const id = scheduledTaskId(occurrence.id);
      if (scenario === "authentication after older rate") {
        await assert.rejects(runScheduled({ ...occurrence, id: "invented-older-rate-occurrence" }, new AbortController().signal, app, id));
        await pump(() => !app.tasks.isRunning(id));
      }
      await assert.rejects(runScheduled(occurrence, new AbortController().signal, app, id));
      await pump(() => !app.tasks.isRunning(id));
      await pump(async () => (await app.sources.events({ provider: "task_outcomes", thread_id: id, limit: 10 }))
        .some(event => event.outcome?.state.state === "failed"));
      const failed = (await app.sources.events({ provider: "task_outcomes", thread_id: id, limit: 10 }))
        .find(event => event.outcome?.state.state === "failed")?.outcome;
      assert.ok(failed && failed.state.state === "failed");
      const task = await app.tasks.get(id);
      const conversation = await app.tasks.conversation(task.conversation_id);
      const receipt = await app.session.commit(tx => tx.submissionByRequest(conversation.id, occurrence.id), BACKGROUND_CONTEXT);
      const expected = scenario.startsWith("authentication") ? providerFailureMessage("401 Invented")!
        : scenario === "rate" ? providerFailureMessage("429 Invented")!
          : scenario === "unknown provider" ? "The worker turn did not complete; its conversation is retained" : generic;
      const calls = requests;
      assert.equal(calls, scenario === "arbitrary preparation error" ? 0 : scenario === "authentication after older rate" ? 2 : 1);
      assert.equal(app.faux.state.callCount, 0, "The real provider replaces, rather than delegates to, the fixture faux provider");
      await app.close(); closed = true;
      const script = `import {openScheduled} from ${JSON.stringify(new URL("./fixtures/scheduled-runtime.js", import.meta.url).href)};
import {BACKGROUND_CONTEXT} from "@earendil-works/chord/context";
const app=await openScheduled(process.argv[1],"fresh-read");
try {
 const task=await app.tasks.get(process.argv[2]);
 const events=await app.sources.events({provider:"task_outcomes",thread_id:task.id,limit:10});
 const outcome=events.find(event=>event.outcome?.state.state==="failed")?.outcome;
 const conversation=await app.tasks.conversation(task.conversation_id);
 const receipt=await app.session.commit(tx=>tx.submissionByRequest(conversation.id,process.argv[3]),BACKGROUND_CONTEXT);
 console.log(JSON.stringify({outcome,modelCalls:app.faux.state.callCount,receipt:receipt===undefined?null:{id:receipt.id,status:receipt.status}}));
}finally{await app.close();}`;
      const fresh = spawnSync(process.execPath, ["--no-warnings", "--input-type=module", "-e", script, directory, id, occurrence.id], {
        cwd: new URL("..", import.meta.url), encoding: "utf8", timeout: 10_000,
        env: { PATH: process.env.PATH, HOME: directory },
      });
      assert.equal(fresh.status, 0, fresh.stderr);
      const restored = JSON.parse(fresh.stdout) as { outcome: typeof failed; modelCalls: number; receipt: { id: number; status: string } | null };
      assert.deepEqual(restored.outcome, failed);
      assert.equal(restored.modelCalls, 0, "Fresh-state inspection must not execute a model");
      assert.deepEqual(restored.receipt, receipt === undefined ? null : { id: receipt.id, status: receipt.status });
      assert.equal(requests, calls, "The fresh process must not replay scheduled input or inference");
      assert.equal(JSON.stringify(restored.outcome).includes("INVENTED_PRIVATE"), false);
      assert.equal(restored.outcome.state.state, "failed");
      if (restored.outcome.state.state !== "failed") throw new Error("No failed outcome");
      console.log(JSON.stringify({ scenario, freshPersistedReason: restored.outcome.state.reason, requests: calls, replayCalls: requests - calls }));
      assert.equal(restored.outcome.state.reason, expected);
    } finally {
      if (!closed) await app.close();
      server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve()));
      await rm(directory, { recursive: true, force: true });
    }
  });
}
