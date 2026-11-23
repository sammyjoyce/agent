import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, type Context as AiContext } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AttachmentStore } from "../src/attachments.js";
import { LocalFiles } from "../src/failover/retained-files.js";
import { HistoryStore } from "../src/history.js";
import { ConversationModels, DEFAULT_MODEL } from "../src/models.js";
import { history, transcript } from "../src/transcript.js";
import { openBridgeHarness } from "./bridge-harness.js";
import { host } from "./delegation.js";
import { fixtureModel } from "./model.js";

test("targeted reply informs model context while keeping HistoryMessage reply_to separate from user text", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-reply-reference-"));
  const seenPrompts: string[] = [];
  const models = createModels();
  const faux = fauxProvider({
    provider: "openai",
    api: "openai-responses",
    models: [{ id: "fixture", reasoning: true }],
    tokensPerSecond: 1_000_000,
  });
  faux.setResponses([
    (context: AiContext) => {
      const lastUser = [...context.messages].reverse().find((message) => message.role === "user");
      if (lastUser !== undefined) {
        seenPrompts.push(
          typeof lastUser.content === "string"
            ? lastUser.content
            : lastUser.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n"),
        );
      }
      return fauxAssistantMessage("Noted your reply target.");
    },
  ]);
  models.setProvider(faux.provider);

  const storage = await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite")));
  const registry = createRegistry();
  const inference = new ConversationModels(models, undefined, registry);
  const harness = await Harness.open(storage, { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  inference.bind(harness);
  try {
    const root = await harness.root(BACKGROUND_CONTEXT);
    await inference.configureCurrent(root, fixtureModel, {
      instructions: "Test main instructions",
      cwd: directory,
      extensions: [],
    });

    const attachments = new AttachmentStore(new LocalFiles(directory));
    const replyTo = { entry_id: "1", role: "final" as const, excerpt: "Alpha checklist item" };
    const prepared = await attachments.input({
      text: "Did we verify step two?",
      call: async () => ({ type: "failed", message: "unused" }),
      origin: "ios",
      replyTo,
    });
    const submission = await root.submit({ type: "input", ...prepared, whenBusy: "steer" }, BACKGROUND_CONTEXT);
    const settled = await submission.wait(BACKGROUND_CONTEXT);
    assert.equal(settled.type, "input");
    assert.equal(settled.status, "done");

    assert.equal(seenPrompts.length, 1);
    assert.match(seenPrompts[0]!, /Replying to assistant message 1: "Alpha checklist item"/);
    assert.match(seenPrompts[0]!, /Did we verify step two\?$/);

    const pages = await history(root, null, new HistoryStore(harness));
    const userRow = pages.flatMap((frame) => frame.messages).find((message) => message.role === "user");
    assert.ok(userRow);
    assert.equal(userRow.text, "Did we verify step two?");
    assert.deepEqual(userRow.reply_to, replyTo);

    const directEntry = (await root.entries({ order: "descending" }, 10, undefined, BACKGROUND_CONTEXT)).items
      .find((entry) => entry.kind === "agent.input");
    assert.ok(directEntry);
    const liveRows = transcript(directEntry);
    assert.equal(liveRows[0]?.text, "Did we verify step two?");
    assert.deepEqual(liveRows[0]?.reply_to, replyTo);
  } finally {
    await harness.close(BACKGROUND_CONTEXT);
    await rm(directory, { recursive: true, force: true });
  }
});

test("bridge handles main_input reply_to", { timeout: 25_000 }, async (t) => {
  const bridge = await openBridgeHarness(t, {
    "bridge-anchor-question": [{ text: "Main answer with anchor details." }],
    "bridge-reply-followup": [{ text: "Reply acknowledged." }],
  });
  try {
    bridge.send(10, {
      type: "chat",
      input: "bridge-anchor-question",
      input_id: "33333333-3333-4333-8333-333333333333",
      instructions: "",
      model: DEFAULT_MODEL,
      origin_host_id: bridge.node.host_id,
      cwd: host.cwd,
      hosts: [host],
    });
    const chatEvents = await bridge.collect(10);
    const mainAnswer = chatEvents.find((event) => event.type === "answer");
    assert.ok(mainAnswer?.type === "answer" && mainAnswer.entry_id !== undefined);

    bridge.send(15, {
      type: "main_input",
      input_id: "55555555-5555-4555-8555-555555555555",
      input: "bridge-reply-followup",
      mode: "steer",
      context: { cwd: host.cwd, origin_host_id: bridge.node.host_id, hosts: [host], instructions: "" },
      reply_to: { entry_id: mainAnswer.entry_id, role: "final", excerpt: "Main answer with anchor details." },
    });
    const replyEvents = await bridge.collect(15);
    assert.ok(replyEvents.some((event) => event.type === "input_accepted"));
    assert.ok(replyEvents.some((event) => event.type === "answer"));
  } finally {
    await bridge.close();
  }
});
