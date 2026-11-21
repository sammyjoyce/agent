import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall, type TranscriptContext } from "@earendil-works/pi-ai";
import { AgentDoc, CompactionEntry, createRegistry, defineExtension, Harness, LiveDoc, UsageDoc } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { ConversationModels, modelFailureMessage } from "../src/models.js";
import { errorEvent, ModelTurnError } from "../src/protocol.js";
import { fixtureModel } from "./model.js";

const WINDOW = 8192;
type CompactionSettings = {
  readonly enabled: boolean;
  readonly keepRecentTokens: number;
  readonly reserveTokens?: number;
  readonly backgroundTokens?: number;
};
async function open(
  directory: string,
  window = WINDOW,
  retry = false,
  compaction: CompactionSettings = { enabled: false, keepRecentTokens: 0 },
) {
  const models = createModels(), registry = createRegistry();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture", contextWindow: window, maxTokens: 512 }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const inference = new ConversationModels(models, undefined, registry);
  const owned = defineExtension({ name: "owned_tools" }), excluded = defineExtension({ name: "excluded_tools" });
  registry.install(owned); registry.install(excluded);
  const session = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))), {
    models, registry, identity: { attribution: null }, settings: { compaction, retry: { enabled: retry } },
  }, BACKGROUND_CONTEXT);
  inference.bind(session);
  const root = await session.root(BACKGROUND_CONTEXT);
  await inference.configure(root, fixtureModel, { extensions: [owned] });
  return { session, root, inference, faux };
}
function text(context: TranscriptContext): string {
  return context.messages.map((message) => message.role === "system" || message.role === "user"
    ? typeof message.content === "string" ? message.content : message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n") : "").join("\n");
}
async function seed(app: Awaited<ReturnType<typeof open>>) {
  const body = "FIRST_MARKER " + "e\u0301🦊漢字 ".repeat(1800) + " LAST_MARKER";
  await app.root.submit({ type: "write", entry: { kind: "fixture.history", model: [
    { role: "user", content: body, timestamp: 1 },
    fauxAssistantMessage(fauxToolCall("completed_effect", { receipt: "EFFECT_ONCE", payload: "argument ".repeat(1200) }), { stopReason: "toolUse" }),
    { role: "toolResult", toolCallId: "old-effect", toolName: "completed_effect", content: [{ type: "text", text: "RESULT_MARKER " + "result ".repeat(1200) }], isError: false, timestamp: 2 },
  ] } }, BACKGROUND_CONTEXT);
  await app.root.submit({ type: "write", entry: { kind: "fixture.tail", model: [{ role: "user", content: "KEEP_THIS_TAIL", timestamp: 3 }] } }, BACKGROUND_CONTEXT);
  return body;
}

test("native compaction reduces oversized inputs, arguments and results without widening tools or changing originals", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-compaction-")), app = await open(directory);
  const requests: string[] = [];
  try {
    const body = await seed(app);
    const before = (await app.root.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items;
    const respond: Parameters<typeof app.faux.setResponses>[0][number] = (context, options) => {
      const source = text(context); requests.push(source);
      if (Buffer.byteLength(source) + (options?.maxTokens ?? 0) > WINDOW) return fauxAssistantMessage("", { stopReason: "error", errorMessage: "Your input exceeds the context window of this model." });
      assert.equal(context.messages.length, 2); assert.notEqual(options?.reasoning, "xhigh");
      assert.equal(options?.toolChoice, "none", "Checkpoint requests cannot select provider-hosted tools either");
      assert.ok(context.messages.every((message) => message.role !== "system" || message.toolsAdded === undefined));
      assert.equal(source.includes("�"), false);
      return fauxAssistantMessage("Preserve FIRST_MARKER LAST_MARKER EFFECT_ONCE RESULT_MARKER; completed effect stays complete.");
    };
    app.faux.setResponses(Array.from({ length: 80 }, () => respond));
    const compacted = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
    assert.equal(compacted.state.outcome.status, "completed"); assert.ok(requests.length > 2);
    const received = requests.join("\n");
    for (const marker of ["FIRST_MARKER", "LAST_MARKER", "EFFECT_ONCE", "RESULT_MARKER"]) assert.ok(received.includes(marker));
    assert.ok(body.length > WINDOW);
    const after = (await app.root.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items;
    assert.deepEqual(after.filter((entry) => !CompactionEntry.is(entry)), before);
    const summaries = after.filter(CompactionEntry.is); assert.equal(summaries.length, 1);
    assert.equal(summaries[0]?.head, before.at(-1)?.id);
    const agent = await app.session.snapshot(AgentDoc, app.root.id, BACKGROUND_CONTEXT);
    assert.deepEqual(agent?.extensions, ["owned_tools", "bounded_compaction"]);
    const ledger = await app.session.snapshot(UsageDoc, app.root.id, BACKGROUND_CONTEXT);
    assert.ok((ledger?.models["openai/fixture"]?.totalTokens ?? 0) > 0);
    app.faux.setResponses([fauxAssistantMessage("Continued with the retained checkpoint.")]);
    const continued = await app.root.submit({ type: "input", content: "Continue saved work." }, BACKGROUND_CONTEXT);
    assert.equal((await continued.wait(BACKGROUND_CONTEXT)).status, "done");
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

const failures: ("length" | "empty" | "tool")[] = ["length", "empty", "tool"];
for (const failure of failures) {
  test(`an incomplete ${failure} fragment cannot send the original oversized fallback or discard saved work`, { timeout: 15_000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-bounded-failure-")), app = await open(directory);
    const requests: string[] = [];
    try {
      await seed(app);
      const before = (await app.root.entries({}, 100, undefined, BACKGROUND_CONTEXT)).items;
      const respond: Parameters<typeof app.faux.setResponses>[0][number] = (context, options) => {
        const source = text(context); requests.push(source);
        assert.ok(Buffer.byteLength(source) + (options?.maxTokens ?? 0) < WINDOW, "No oversized fallback may reach the provider");
        if (requests.length === 1) return fauxAssistantMessage("Retained completed fragment EFFECT_ONCE.");
        return failure === "tool" ? fauxAssistantMessage(fauxToolCall("never_execute", {}), { stopReason: "toolUse" })
          : fauxAssistantMessage("", { stopReason: failure === "length" ? "length" : "stop" });
      };
      app.faux.setResponses(Array.from({ length: 80 }, () => respond));
      const failed = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
      assert.equal(failed.state.outcome.status, "failed"); assert.equal(requests.length, 2,
        JSON.stringify(requests.map((source) => ({ bytes: Buffer.byteLength(source), start: source.slice(0, 100) }))));
      assert.deepEqual((await app.root.entries({}, 100, undefined, BACKGROUND_CONTEXT)).items, before);
      const completed = requests[0], repeated: string[] = [];
      const finish: Parameters<typeof app.faux.setResponses>[0][number] = (context) => {
        repeated.push(text(context)); return fauxAssistantMessage("Merged retained checkpoint EFFECT_ONCE.");
      };
      app.faux.setResponses(Array.from({ length: 80 }, () => finish));
      const recovered = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
      assert.equal(recovered.state.outcome.status, "completed"); assert.ok(completed);
      assert.equal(repeated.includes(completed), false);
    } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
  });
}

test("an incomplete tool-result checkpoint cannot fall back to Pi's truncated transcript", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-tool-result-")), app = await open(directory, 16_384);
  let calls = 0;
  try {
    await app.root.submit({ type: "write", entry: { kind: "fixture.result", model: [
      fauxAssistantMessage(fauxToolCall("completed_effect", {}, { id: "original-effect" }), { stopReason: "toolUse" }),
      { role: "toolResult", toolName: "completed_effect", toolCallId: "original-effect",
      content: [{ type: "text", text: "result ".repeat(600) + " IMPORTANT_TAIL_EFFECT_RECEIPT" }], isError: false, timestamp: 1 }] } }, BACKGROUND_CONTEXT);
    await app.root.submit({ type: "write", entry: { kind: "fixture.tail", model: [{ role: "user", content: "Keep this tail.", timestamp: 2 }] } }, BACKGROUND_CONTEXT);
    const incomplete: Parameters<typeof app.faux.setResponses>[0][number] = (context) => {
      calls += 1; assert.ok(text(context).includes("IMPORTANT_TAIL_EFFECT_RECEIPT"));
      return fauxAssistantMessage("", { stopReason: "length" });
    };
    app.faux.setResponses([incomplete, incomplete]);
    const failed = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
    assert.equal(failed.state.outcome.status, "failed"); assert.equal(calls, 1);
    app.faux.setResponses([(context) => {
      assert.ok(text(context).includes("IMPORTANT_TAIL_EFFECT_RECEIPT")); return fauxAssistantMessage("Completed effect receipt IMPORTANT_TAIL_EFFECT_RECEIPT.");
    }]);
    const recovered = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
    assert.equal(recovered.state.outcome.status, "completed", JSON.stringify(recovered.state.outcome));
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

test("quoted truncation markers in a small user input remain ordinary checkpoint data", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-quoted-marker-")), app = await open(directory);
  try {
    await app.root.submit({ type: "write", entry: { kind: "fixture.quoted", model: [{ role: "user", timestamp: 1,
      content: "Explain this log format: [Tool result]: example [... 10 more characters truncated]" }] } }, BACKGROUND_CONTEXT);
    await app.root.submit({ type: "write", entry: { kind: "fixture.tail", model: [{ role: "user", content: "Keep the tail.", timestamp: 2 }] } }, BACKGROUND_CONTEXT);
    app.faux.setResponses([(context) => { assert.ok(text(context).includes("Explain this log format")); return fauxAssistantMessage("The user is asking about a quoted log marker."); }]);
    const result = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
    assert.equal(result.state.outcome.status, "completed"); assert.equal(app.faux.state.callCount, 1);
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

test("reopening interrupted native compaction reuses completed fragments and their usage", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-reopen-")); let app = await open(directory);
  let secondStarted = () => {}; const second = new Promise<void>((resolve) => { secondStarted = resolve; });
  let firstSource = "", calls = 0;
  try {
    await seed(app);
    const respond: Parameters<typeof app.faux.setResponses>[0][number] = async (context, options) => {
      calls += 1;
      if (calls === 1) { firstSource = text(context); return fauxAssistantMessage("Completed first fragment EFFECT_ONCE."); }
      secondStarted(); const signal = options?.signal; assert.ok(signal);
      await new Promise<void>((resolve) => { if (signal.aborted) resolve(); else signal.addEventListener("abort", () => resolve(), { once: true }); });
      return fauxAssistantMessage("", { stopReason: "aborted" });
    };
    app.faux.setResponses(Array.from({ length: 80 }, () => respond));
    const id = await app.root.compact(undefined, BACKGROUND_CONTEXT);
    await second; const before = await app.session.snapshot(UsageDoc, app.root.id, BACKGROUND_CONTEXT);
    assert.ok((before?.models["openai/fixture"]?.totalTokens ?? 0) > 0, JSON.stringify({ before, firstSourceBytes: Buffer.byteLength(firstSource), calls }));
    await app.session.close(BACKGROUND_CONTEXT); app = await open(directory);
    const sources: string[] = [];
    const finish: Parameters<typeof app.faux.setResponses>[0][number] = (context) => { sources.push(text(context)); return fauxAssistantMessage("Merged retained fragment EFFECT_ONCE."); };
    app.faux.setResponses(Array.from({ length: 80 }, () => finish));
    const result = await app.session.waitForTask(id, BACKGROUND_CONTEXT);
    assert.equal(result.state.outcome.status, "completed"); assert.ok(sources.length > 0);
    assert.equal(sources.includes(firstSource), false, "Committed first-fragment inference must not repeat");
    const after = await app.session.snapshot(UsageDoc, app.root.id, BACKGROUND_CONTEXT);
    assert.ok((after?.models["openai/fixture"]?.totalTokens ?? 0) > (before?.models["openai/fixture"]?.totalTokens ?? 0));
    assert.equal((await app.root.entries({}, 100, undefined, BACKGROUND_CONTEXT)).items.filter(CompactionEntry.is).length, 1);
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

const providerCompactionErrors = [
  {
    name: "401 authentication failure",
    errorMessage: "OpenAI API error (401): invalid_api_key INVENTED_PRIVATE_SECRET",
    retry: false,
    expectedDiagnosis: "Context compaction failed: The model provider rejected authentication (401/authentication_error). Saved history and credentials are retained.",
    expectedCode: "authentication_failed" as const,
  },
  {
    name: "429 rate limit with retries enabled",
    errorMessage: "OpenAI API error (429): rate_limit_exceeded INVENTED_PRIVATE_SECRET",
    retry: true,
    expectedDiagnosis: "Context compaction failed: The model provider rate limit was reached (429/rate_limit_error). Saved history is retained.",
    expectedCode: "provider_unavailable" as const,
  },
  {
    name: "subscription sharing usage limit",
    errorMessage: "OpenAI API error (429): subscription_sharing_usage_limit_exceeded INVENTED_PRIVATE_SECRET",
    retry: true,
    expectedDiagnosis: "Context compaction failed: The upstream app subscription-sharing usage limit was reached. Saved history is retained; changing local credentials does not reset this limit.",
    expectedCode: "provider_unavailable" as const,
  },
  {
    name: "unknown 500 server failure",
    errorMessage: "500 Internal Server Error INVENTED_PRIVATE_SECRET",
    retry: false,
    expectedDiagnosis: "Context compaction failed: the provider request did not complete. Saved history is retained.",
    expectedCode: "provider_unavailable" as const,
  },
];

for (const item of providerCompactionErrors) {
  test(`fragment provider error (${item.name}) preserves diagnosis without leaking secrets or re-sending fallback`, { timeout: 15_000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-bounded-provider-error-"));
    const app = await open(directory, WINDOW, item.retry);
    const requests: string[] = [];
    try {
      await seed(app);
      const before = (await app.root.entries({}, 100, undefined, BACKGROUND_CONTEXT)).items;
      const respond: Parameters<typeof app.faux.setResponses>[0][number] = (context, options) => {
        const source = text(context); requests.push(source);
        assert.ok(Buffer.byteLength(source) + (options?.maxTokens ?? 0) < WINDOW, "No oversized fallback may reach the provider");
        if (requests.length === 1) return fauxAssistantMessage("Retained completed fragment EFFECT_ONCE.");
        return fauxAssistantMessage("", { stopReason: "error", errorMessage: item.errorMessage });
      };
      app.faux.setResponses(Array.from({ length: 80 }, () => respond));
      const failed = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
      assert.equal(failed.state.outcome.status, "failed");
      assert.equal(requests.length, 2, "Fallback summary request must be guarded without extra provider calls");
      assert.deepEqual((await app.root.entries({}, 100, undefined, BACKGROUND_CONTEXT)).items, before);
      const liveFailure = (await app.session.snapshot(LiveDoc, app.root.id, BACKGROUND_CONTEXT))?.compactionFailure?.error;
      assert.ok(liveFailure);
      assert.equal(liveFailure.includes("INVENTED_PRIVATE_SECRET"), false);
      const diagnosis = await modelFailureMessage(app.root, "fallback", app.session);
      assert.equal(diagnosis, item.expectedDiagnosis);
      assert.equal(diagnosis.includes("INVENTED_PRIVATE_SECRET"), false);
      assert.deepEqual(errorEvent(new ModelTurnError(diagnosis)), { type: "failure", code: item.expectedCode, message: diagnosis });

      const completed = requests[0], repeated: string[] = [];
      const finish: Parameters<typeof app.faux.setResponses>[0][number] = (context) => {
        repeated.push(text(context)); return fauxAssistantMessage("Merged retained checkpoint EFFECT_ONCE.");
      };
      app.faux.setResponses(Array.from({ length: 80 }, () => finish));
      const recovered = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
      assert.equal(recovered.state.outcome.status, "completed");
      assert.ok(completed);
      assert.equal(repeated.includes(completed), false, "Committed first fragment must be reused after provider error");
    } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
  });
}

test("blocking overflow compaction error preserves provider diagnosis on input settlement without fallback", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-blocking-error-"));
  const app = await open(directory, WINDOW, true, { enabled: true, keepRecentTokens: 0, reserveTokens: 4096, backgroundTokens: 0 });
  const requests: string[] = [];
  try {
    await seed(app);
    const respond: Parameters<typeof app.faux.setResponses>[0][number] = (context, options) => {
      const source = text(context); requests.push(source);
      assert.ok(Buffer.byteLength(source) + (options?.maxTokens ?? 0) < WINDOW, "No oversized fallback may reach the provider");
      if (requests.length === 1) return fauxAssistantMessage("Retained completed fragment EFFECT_ONCE.");
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: "OpenAI API error (429): rate_limit_exceeded INVENTED_PRIVATE_SECRET" });
    };
    app.faux.setResponses(Array.from({ length: 80 }, () => respond));
    const input = await app.root.submit({ type: "input", content: "Continue saved work." }, BACKGROUND_CONTEXT);
    const settlement = await input.wait(BACKGROUND_CONTEXT);
    assert.equal(settlement.status, "unanswered");
    assert.equal(requests.length, 2);
    const diagnosis = await modelFailureMessage(app.root, "fallback", app.session, settlement);
    assert.equal(diagnosis, "Context compaction failed: The model provider rate limit was reached (429/rate_limit_error). Saved history is retained.");
    assert.equal(diagnosis.includes("INVENTED_PRIVATE_SECRET"), false);
    assert.deepEqual(errorEvent(new ModelTurnError(diagnosis)), { type: "failure", code: "provider_unavailable", message: diagnosis });

    const completed = requests[0], repeated: string[] = [];
    const finish: Parameters<typeof app.faux.setResponses>[0][number] = (context) => {
      repeated.push(text(context));
      return fauxAssistantMessage("Merged retained checkpoint and continued work.");
    };
    app.faux.setResponses(Array.from({ length: 80 }, () => finish));
    const retried = await app.root.submit({ type: "input", content: "Continue after transient error." }, BACKGROUND_CONTEXT);
    assert.equal((await retried.wait(BACKGROUND_CONTEXT)).status, "done");
    assert.ok(completed);
    assert.equal(repeated.includes(completed), false);
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

test("provider error on mid-sized fragment between bounded limit and context window suppresses non-oversized fallback", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-bounded-mid-error-"));
  const app = await open(directory, 16_384, false);
  const requests: string[] = [];
  try {
    const midBody = "MID_MARKER " + "alpha ".repeat(1800);
    await app.root.submit({ type: "write", entry: { kind: "fixture.mid", model: [{ role: "user", content: midBody, timestamp: 1 }] } }, BACKGROUND_CONTEXT);
    await app.root.submit({ type: "write", entry: { kind: "fixture.tail", model: [{ role: "user", content: "Keep this tail.", timestamp: 2 }] } }, BACKGROUND_CONTEXT);
    const respond: Parameters<typeof app.faux.setResponses>[0][number] = (context) => {
      requests.push(text(context));
      return fauxAssistantMessage("", { stopReason: "error", errorMessage: "OpenAI API error (401): invalid_api_key INVENTED_PRIVATE_SECRET" });
    };
    app.faux.setResponses([respond, respond]);
    const failed = await app.session.waitForTask(await app.root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT);
    assert.equal(failed.state.outcome.status, "failed");
    assert.equal(requests.length, 1, "Fallback summary must not be sent even when source fits model contextWindow");
    const diagnosis = await modelFailureMessage(app.root, "fallback", app.session);
    assert.equal(diagnosis, "Context compaction failed: The model provider rejected authentication (401/authentication_error). Saved history and credentials are retained.");
    assert.equal(diagnosis.includes("INVENTED_PRIVATE_SECRET"), false);
    assert.deepEqual(errorEvent(new ModelTurnError(diagnosis)), { type: "failure", code: "authentication_failed", message: diagnosis });
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});
