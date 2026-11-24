import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { generateKeyPairSync } from "node:crypto";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type IncomingHttpHeaders, type ServerHttp2Session, type ServerHttp2Stream } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { AssistantEntry, createRegistry, Harness, ROOT_CONVERSATION_ID, type EntryRecord } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AttachmentStore } from "../src/attachments.js";
import { BackgroundScheduler } from "../src/background.js";
import { BrowserStore, createBrowserTools } from "../src/browser.js";
import { ConversationCatalog } from "../src/catalog.js";
import { CoordinatorEnvironment } from "../src/environment.js";
import { LocalFiles } from "../src/failover/retained-files.js";
import type { ApnsConfig } from "../src/generated/ApnsConfig.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { ScheduledOccurrence } from "../src/generated/ScheduledOccurrence.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";
import { createGoalTools, GoalStore } from "../src/goals.js";
import { createGuidance } from "../src/guidance.js";
import { HistoryStore } from "../src/history.js";
import { createInputOrigins } from "../src/input_origin.js";
import { createMainResponsePolicy } from "../src/main_response.js";
import { ConversationModels, DEFAULT_MODEL } from "../src/models.js";
import { notificationDeliveryKey, NotificationDeliveries, Notifications, NotificationState } from "../src/notifications.js";
import { placeNoticeContext } from "../src/notice_context.js";
import { readTaskGraph } from "../src/task-graph.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import { createResourceTools, ResourceStore } from "../src/resources.js";
import { Retrieval } from "../src/retrieval.js";
import { runScheduled } from "../src/scheduled.js";
import { conversationSettings } from "../src/settings.js";
import { createSidechatTools, SidechatStore } from "../src/sidechats.js";
import { createSourceTools, SourceJournal } from "../src/sources.js";
import { nativeConversationId, TaskStore } from "../src/tasks.js";
import { createAppTools, createJobTools, Executions } from "../src/tools.js";
import { applyToolSurfaces, createToolDiscovery, createToolsets, TOOL_SURFACES, withActorPolicies } from "../src/toolsets.js";
import { history, SidechatSeedEntry, UserNoticeEntry } from "../src/transcript.js";
import { fixtureModel } from "./model.js";
import { openScheduled, scheduledOccurrence } from "./fixtures/scheduled-runtime.js";

const host: WorkerHost = {
  host_id: "11111111-1111-4111-8111-111111111111",
  name: "fixture-host",
  rex_server: null,
  coordinator: null,
  cwd: "/workspace/example",
  agent_program: "/example/agent",
};

function embedVector(text: string): number[] {
  const lower = text.toLowerCase();
  const raw = [
    lower.includes("kyoto") || lower.includes("itinerary") ? 1 : 0.01,
    lower.includes("secretvault") || lower.includes("private") ? 1 : 0.01,
    lower.includes("invoice") || lower.includes("tax") ? 1 : 0.01,
    0.1,
  ];
  const norm = Math.hypot(...raw);
  return raw.map((value) => value / norm);
}

async function openHarness(directory: string) {
  const models = createModels();
  const registry = createRegistry();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const session = await Harness.open(
    await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models, registry, identity: { attribution: null }, settings: { retry: { enabled: false }, compaction: { enabled: false } } },
    BACKGROUND_CONTEXT,
  );
  const inference = new ConversationModels(models);
  const sidechats = new SidechatStore(session);
  const tasks = new TaskStore(session, inference);
  tasks.useSidechats(sidechats);
  const environment = new CoordinatorEnvironment(session);
  tasks.useEnvironment(environment);
  const histories = new HistoryStore(session);
  tasks.useHistory(histories);
  const catalog = new ConversationCatalog(session, histories, tasks, sidechats);
  const retrieval = new Retrieval(session, histories, tasks, join(directory, "search.sqlite"), sidechats);
  const executions = new Executions();
  const sources = new SourceJournal(session, tasks, executions);
  sources.useSidechats(sidechats);
  const resources = new ResourceStore(session, tasks);
  tasks.guardResources(resources);
  const tools = createAppTools(tasks, executions);
  const sidechatTools = createSidechatTools(sidechats, tasks, session, executions);
  const sourceTools = createSourceTools(sources, executions);
  const background = new BackgroundScheduler(session, registry, tasks, {
    async plan() { return { due: null, next: Date.now() + 86_400_000 }; },
    async refreshSources() {},
    async triageSources() {},
    async collectResources() {},
    async indexHistory() {},
    async runJob() {},
  });
  const discovery = createToolDiscovery();
  const goals = new GoalStore(session, tasks, environment);
  const { toolsets, installed } = applyToolSurfaces(
    withActorPolicies(
      createToolsets({
        guidance: createGuidance(executions),
        tools,
        sidechatTools,
        sourceTools,
        resourceTools: createResourceTools(resources, tasks, executions),
        browserTools: createBrowserTools(new BrowserStore(session), executions, new AttachmentStore(new LocalFiles(directory))),
        jobTools: createJobTools(background, executions),
        goalTools: createGoalTools(goals, executions),
      }),
      { responsePolicy: createMainResponsePolicy(session), inputOrigins: createInputOrigins(session) },
    ),
    TOOL_SURFACES,
    discovery,
  );
  for (const ext of new Set([...Object.values(toolsets).flat(), ...installed, tools.legacy])) registry.install(ext);
  const hostCall = async (command: HostCommand): Promise<HostResult> => {
    if (command.type === "embed") {
      return {
        type: "embeddings",
        batch: {
          space: {
            id: "fixture-embed",
            model_revision: "v1",
            model_digest: "fixture-digest",
            dimensions: 4,
            pooling: "mean",
            normalization: "l2",
            instruction_version: 1,
          },
          vectors: command.texts.map(embedVector),
        },
      };
    }
    if (command.type === "spawn_worker" || command.type === "spawn_workspace_worker") {
      return {
        type: "spawned",
        binding: {
          host_id: host.host_id ?? "11111111-1111-4111-8111-111111111111",
          session_id: "session:22222222-2222-4222-8222-222222222222",
          window_id: "window:33333333-3333-4333-8333-333333333333",
          block_id: "block:44444444-4444-4444-8444-444444444444",
        },
      };
    }
    if (command.type === "reload_guidance") {
      return { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] };
    }
    if (command.type === "project_guidance") {
      return { type: "project_guidance", snapshot: { text: "", sources: [] } };
    }
    throw new Error(`Unexpected host call: ${command.type}`);
  };
  return {
    session, inference, sidechats, tasks, environment, histories, catalog, retrieval, executions, sources, background, toolsets, faux, hostCall,
    async close() {
      catalog.close();
      await retrieval.close();
      await session.close(BACKGROUND_CONTEXT);
      await discovery.close();
    },
  };
}

test("standing side chats create fresh ownerless conversations, unique slugs, pin/archive/charter/isolation updates, and seed entries", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-store-"));
  const app = await openHarness(directory);
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    await app.session.commit(
      (tx) => tx.appendEntry(root.id, { kind: AssistantEntry.kind, model: [fauxAssistantMessage("Main-only message that must never appear in sidechat")] }),
      BACKGROUND_CONTEXT,
    );

    const first = await app.sidechats.create({
      title: "Travel & Flights",
      charter: "Track itineraries, hotels, and confirmations.",
      seed: { entry_id: "1", role: "final", excerpt: "Plan the autumn trip" },
      handoff: "Departing in October for Kyoto.",
    });
    assert.equal(first.slug, "travel-flights");
    assert.equal(first.pinned, false);
    assert.equal(first.isolated, false);
    assert.equal(first.notifications, "inherit");
    assert.equal(first.charter, "Track itineraries, hotels, and confirmations.");
    assert.equal(first.archived_at, undefined);
    assert.notEqual(first.conversation_id, ROOT_CONVERSATION_ID.toString());

    // Fresh conversation has only the seed entry, never Main's transcript (no Pi fork).
    const firstConv = await app.tasks.conversation(first.conversation_id);
    const firstEntries = (await firstConv.entries({ order: "ascending" }, 20, undefined, BACKGROUND_CONTEXT)).items;
    assert.equal(firstEntries.length, 1);
    assert.ok(SidechatSeedEntry.is(firstEntries[0]!));
    const rendered = await history(firstConv, null, app.histories);
    const noticeTexts = rendered.flatMap((frame) => frame.messages.map((m) => m.text)).join("\n");
    assert.match(noticeTexts, /Plan the autumn trip/);
    assert.match(noticeTexts, /Departing in October for Kyoto/);
    assert.doesNotMatch(noticeTexts, /Main-only message/);

    // Auto-suffixed unique slug when titles match; explicit duplicate slug rejects.
    const second = await app.sidechats.create({ title: "Travel & Flights" });
    assert.equal(second.slug, "travel-flights-2");
    await assert.rejects(app.sidechats.create({ title: "Duplicate", slug: "travel-flights" }), /already exists/);

    // Pinning orders pinned first; archiving hides from active list and unarchive restores.
    const pinned = await app.sidechats.update({ conversation_id: second.conversation_id, pinned: true, notifications: "on", isolated: true });
    assert.equal(pinned.pinned, true);
    assert.equal(pinned.notifications, "on");
    assert.equal(pinned.isolated, true);
    const active = await app.sidechats.list(false);
    assert.deepEqual(active.map((item) => item.conversation_id), [second.conversation_id, first.conversation_id]);

    const archived = await app.sidechats.update({ conversation_id: first.conversation_id, archived: true });
    assert.ok(typeof archived.archived_at === "number");
    assert.deepEqual((await app.sidechats.list(false)).map((item) => item.conversation_id), [second.conversation_id]);
    assert.equal((await app.sidechats.list(true)).length, 2);

    const restored = await app.sidechats.unarchiveIfNeeded(first.conversation_id);
    assert.equal(restored?.archived_at, undefined);
    assert.equal((await app.sidechats.list(false)).length, 2);

    // Charter clear vs mutual exclusion check.
    await assert.rejects(
      app.sidechats.update({ conversation_id: first.conversation_id, charter: "New", clear_charter: true }),
      /not both/,
    );
    const cleared = await app.sidechats.update({ conversation_id: first.conversation_id, clear_charter: true });
    assert.equal(cleared.charter, undefined);

    // Per-sidechat model settings work cleanly.
    const settings = await conversationSettings(
      app.tasks,
      app.environment,
      { type: "conversation_settings", task_id: null, agent_id: null, conversation_id: first.conversation_id, change: null, catalog: false },
      app.sidechats,
    );
    assert.equal(settings.conversation_id, first.conversation_id);
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("shared side chats are searchable from Main while isolated side chats are walled off and purged on toggle", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-retrieval-"));
  const app = await openHarness(directory);
  try {
    const shared = await app.sidechats.create({ title: "Kyoto Trip", charter: "Autumn itinerary" });
    const walled = await app.sidechats.create({ title: "Private Vault", isolated: true });

    await app.session.commit(async (tx) => {
      await tx.appendEntry(nativeConversationId(shared.conversation_id), {
        kind: AssistantEntry.kind,
        model: [fauxAssistantMessage("Kyoto ryokan reservation confirmed for October 14.")],
      });
      await tx.appendEntry(nativeConversationId(walled.conversation_id), {
        kind: AssistantEntry.kind,
        model: [fauxAssistantMessage("SecretVault passphrase notes stay isolated.")],
      });
    }, BACKGROUND_CONTEXT);

    await app.retrieval.sync(app.hostCall, true);
    const search = (query: string, refs: string[], limit: number, mode: "semantic" | "keyword" = "semantic") =>
      app.retrieval.search(query, refs, limit, app.hostCall, false, mode);

    const kyotoResults = await app.tasks.find("Kyoto ryokan", [], 8, search, "keyword");
    assert.ok(kyotoResults.matches.some((match) => match.conversation_id === shared.conversation_id && match.title === "Kyoto Trip"));

    const secretResults = await app.tasks.find("SecretVault", [], 8, search, "keyword");
    assert.equal(secretResults.matches.some((match) => match.conversation_id === walled.conversation_id), false);

    // Catalog includes shared sidechat (searchable by slug) and excludes isolated sidechat.
    const listed = await app.catalog.list("kyoto-trip", null, 20);
    assert.ok(listed.items.some((item) => item.conversation_id === shared.conversation_id));
    const listedAll = await app.catalog.list("", null, 20);
    assert.equal(listedAll.items.some((item) => item.conversation_id === walled.conversation_id), false);
    assert.equal((await app.catalog.get(walled.conversation_id))?.conversation_id, walled.conversation_id);

    // Toggling shared -> isolated immediately hides from find() AND purges index chunks after sync.
    await app.sidechats.update({ conversation_id: shared.conversation_id, isolated: true });
    const immediateAfterToggle = await app.tasks.find("Kyoto ryokan", [], 8, search, "keyword");
    assert.equal(immediateAfterToggle.matches.some((match) => match.conversation_id === shared.conversation_id), false);

    await app.retrieval.sync(app.hostCall, false);
    const rawSearchAfterPurge = await app.retrieval.search("Kyoto ryokan", [], 8, app.hostCall, false, "keyword");
    assert.equal(rawSearchAfterPurge.candidates.some((candidate) => candidate.conversation_id === shared.conversation_id), false);

    // Toggling back to shared re-indexes and makes it searchable again.
    await app.sidechats.update({ conversation_id: shared.conversation_id, isolated: false });
    await app.retrieval.sync(app.hostCall, false);
    const afterRestore = await app.tasks.find("Kyoto ryokan", [], 8, search, "keyword");
    assert.ok(afterRestore.matches.some((match) => match.conversation_id === shared.conversation_id));
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("agent sidechat tools create, update, auto-unarchive on post, and sidechat delegations route notices back to the side chat unless escalated", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-tools-"));
  const app = await openHarness(directory);
  let releaseRoot = () => {};
  let releaseSidechat = () => {};
  let releaseWorker = () => {};
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    releaseRoot = app.executions.bind(root.id.toString(), {
      model: fixtureModel,
      cwd: host.cwd,
      hosts: [host],
      default_host: host,
      call: app.hostCall,
      notify: () => {},
    });
    await app.inference.configure(root, fixtureModel, { extensions: app.toolsets.main });

    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("create_sidechat", { title: "Tax Filings", charter: "Keep receipts and tax deadlines here." }), { stopReason: "toolUse" }),
      fauxAssistantMessage(fauxToolCall("update_sidechat", { sidechat: "tax-filings", archived: true }), { stopReason: "toolUse" }),
      fauxAssistantMessage(fauxToolCall("post_to_sidechat", { sidechat: "tax-filings", text: "Filed Q3 receipt summary." }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Created and filed into Tax Filings."),
    ]);
    const mainTurn = await (await root.submit({ type: "input", content: "Create Tax Filings and post a note." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    assert.equal(mainTurn.status, "done");

    const tax = await app.sidechats.resolve("tax-filings");
    assert.ok(tax !== undefined);
    assert.equal(tax.archived_at, undefined, "post_to_sidechat must automatically unarchive an archived side chat");
    const taxConv = await app.tasks.conversation(tax.conversation_id);
    const taxEntries = (await taxConv.entries({ order: "ascending" }, 20, undefined, BACKGROUND_CONTEXT)).items;
    assert.ok(taxEntries.some((entry) => UserNoticeEntry.is(entry) && entry.data.text === "Filed Q3 receipt summary."));

    // Now delegate a task FROM the side chat and verify delivery_conversation_id + notice routing.
    releaseSidechat = app.executions.bind(tax.conversation_id, {
      model: fixtureModel,
      cwd: host.cwd,
      hosts: [host],
      default_host: host,
      role: "sidechat",
      call: app.hostCall,
      notify: () => {},
    });
    await app.inference.configure(taxConv, fixtureModel, { extensions: app.toolsets.sidechat });
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("delegate_task", {
          title: "Check Q3 receipts",
          outcome: "Verify receipts and report back",
          input: "Check all Q3 receipts.",
          new_task: true,
          new_task_reason: "Dedicated tax receipt verification",
        }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Delegated the receipt check."),
    ]);
    const scTurn = await (await taxConv.submit({ type: "input", content: "Delegate checking Q3 receipts." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    assert.equal(scTurn.status, "done");

    const delegated = (await app.tasks.list()).find((task) => task.title === "Check Q3 receipts");
    assert.ok(delegated !== undefined);
    assert.equal(delegated.delivery_conversation_id, tax.conversation_id);

    // Archive the side chat again to prove worker notify_user auto-unarchives it.
    await app.sidechats.update({ conversation_id: tax.conversation_id, archived: true });

    const workerConv = await app.tasks.conversation(delegated.conversation_id);
    releaseWorker = app.executions.bind(delegated.conversation_id, {
      model: fixtureModel,
      cwd: host.cwd,
      hosts: [host],
      default_host: host,
      role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(workerConv, fixtureModel, { extensions: app.toolsets.worker });
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", {
          code: `
            const routine = await tools.notify_user({ text: "Q3 receipt totals verified: 14 items." });
            const escalated = await tools.notify_user({ text: "Signature required before Friday.", escalate_to_main: true });
            return { routine, escalated };
          `,
        }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Notified both channels."),
    ]);
    const workerTurn = await (await workerConv.submit({ type: "input", content: "Send routine update and urgent escalation." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    assert.equal(workerTurn.status, "done");

    const refreshedTax = await app.sidechats.get(tax.conversation_id);
    assert.equal(refreshedTax?.archived_at, undefined, "worker notify_user to sidechat must auto-unarchive it");
    const taxNotices = (await taxConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.ok(taxNotices.includes("Q3 receipt totals verified: 14 items."));
    assert.equal(taxNotices.includes("Signature required before Friday."), false);

    const rootNotices = (await root.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.ok(rootNotices.includes("Signature required before Friday."));
    assert.equal(rootNotices.includes("Q3 receipt totals verified: 14 items."), false);
  } finally {
    releaseWorker();
    releaseSidechat();
    releaseRoot();
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("scheduled job delivery_sidechat lands in active sidechat, auto-unarchives archived sidechat, and falls back to Main if missing", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-scheduled-"));
  const app = await openScheduled(directory);
  try {
    const sidechats = new SidechatStore(app.session);
    app.tasks.useSidechats(sidechats);
    app.sources.useSidechats(sidechats);
    const brief = await sidechats.create({ title: "Morning Brief", slug: "morning-brief" });

    // 1. Active side chat delivery
    const activeOcc: ScheduledOccurrence = {
      ...scheduledOccurrence,
      id: "occ-active-1",
      job: { ...scheduledOccurrence.job, delivery_sidechat: "morning-brief" },
    };
    app.faux.setResponses([fauxAssistantMessage("Morning briefing #1: all systems green.")]);
    await runScheduled(activeOcc, new AbortController().signal, { ...app, sidechats });

    const briefConv = await app.tasks.conversation(brief.conversation_id);
    let briefNotices = (await briefConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.deepEqual(briefNotices, ["Morning briefing #1: all systems green."]);

    // 2. Archived side chat auto-unarchives on scheduled delivery
    await sidechats.update({ conversation_id: brief.conversation_id, archived: true });
    assert.ok((await sidechats.get(brief.conversation_id))?.archived_at !== undefined);
    const archivedOcc: ScheduledOccurrence = {
      ...scheduledOccurrence,
      id: "occ-archived-2",
      job: { ...scheduledOccurrence.job, delivery_sidechat: "morning-brief" },
    };
    app.faux.setResponses([fauxAssistantMessage("Morning briefing #2: unarchived delivery.")]);
    await runScheduled(archivedOcc, new AbortController().signal, { ...app, sidechats });
    assert.equal((await sidechats.get(brief.conversation_id))?.archived_at, undefined);
    briefNotices = (await briefConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.deepEqual(briefNotices, [
      "Morning briefing #1: all systems green.",
      "Morning briefing #2: unarchived delivery.",
    ]);

    // 3. Missing target side chat falls back to Main with warning
    const missingOcc: ScheduledOccurrence = {
      ...scheduledOccurrence,
      id: "occ-missing-3",
      job: { ...scheduledOccurrence.job, delivery_sidechat: "no-such-topic" },
    };
    app.faux.setResponses([fauxAssistantMessage("Fallback briefing body.")]);
    await runScheduled(missingOcc, new AbortController().signal, { ...app, sidechats });
    const root = await app.session.root(BACKGROUND_CONTEXT);
    const rootNotices = (await root.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text ?? "");
    assert.ok(rootNotices.some((text) => text.includes("no-such-topic") && text.includes("Fallback briefing body.")));
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("APNs notifications enforce all 6 combinations of Main (on/off) x Sidechat (inherit/on/off)", { timeout: 15_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-apns-"));
  await chmod(directory, 0o700);
  const keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const keyFile = join(directory, "AuthKey.p8");
  await writeFile(keyFile, keys.privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  const config: ApnsConfig = { team_id: "TEAM000001", key_id: "KEY0000001", topic: "dev.example.Agent", key_file: keyFile, environment: "sandbox" };
  const server = createServer();
  const sessions = new Set<ServerHttp2Session>();
  const requests: { path: string; title: string; body: string; conversation_id: string }[] = [];
  server.on("session", (s) => { sessions.add(s); s.on("error", () => {}); s.once("close", () => sessions.delete(s)); });
  server.on("stream", (stream: ServerHttp2Stream, headers: IncomingHttpHeaders) => {
    let raw = "";
    stream.on("error", () => {});
    stream.setEncoding("utf8").on("data", (chunk: string) => { raw += chunk; });
    stream.once("end", () => {
      const parsed = JSON.parse(raw) as { aps: { alert: { title: string; body: string } }; agent: { conversation_id: string } };
      requests.push({
        path: String(headers[":path"]),
        title: parsed.aps.alert.title,
        body: parsed.aps.alert.body,
        conversation_id: parsed.agent.conversation_id,
      });
      stream.respond({ ":status": 200 });
      stream.end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;

  const registry = createRegistry();
  const session = await Harness.open(
    await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models: createModels(), registry, identity: { attribution: null } },
    BACKGROUND_CONTEXT,
  );
  await session.root(BACKGROUND_CONTEXT);
  const sidechats = new SidechatStore(session);
  const notifications = new Notifications(session, registry, config, origin, undefined, sidechats);
  await notifications.start();
  session.resume();

  try {
    const devMainOn = "11111111-1111-4111-8111-111111111111";
    const devMainOff = "22222222-2222-4222-8222-222222222222";
    const tokOn = "aa11".repeat(24);
    const tokOff = "bb22".repeat(24);

    const statusOn = await notifications.request({ type: "register", installation_id: devMainOn, token: tokOn, main_enabled: true });
    assert.deepEqual(statusOn, { configured: true, registered: true, main_enabled: true });
    const statusOff = await notifications.request({ type: "register", installation_id: devMainOff, token: tokOff, main_enabled: false });
    assert.deepEqual(statusOff, { configured: true, registered: true, main_enabled: false });

    const scInherit = await sidechats.create({ title: "Inherit Topic", notifications: "inherit" });
    const scOn = await sidechats.create({ title: "Always On Topic", notifications: "on" });
    const scOff = await sidechats.create({ title: "Muted Topic", notifications: "off" });

    const append = (cid: typeof ROOT_CONVERSATION_ID, text: string): Promise<EntryRecord> =>
      session.commit((tx) => tx.appendEntry(cid, { kind: AssistantEntry.kind, model: [fauxAssistantMessage(text)] }), BACKGROUND_CONTEXT);

    const mainReply = await append(ROOT_CONVERSATION_ID, "Main alert body");
    const inheritReply = await append(nativeConversationId(scInherit.conversation_id), "Inherit alert body");
    const onReply = await append(nativeConversationId(scOn.conversation_id), "Always-on alert body");
    await append(nativeConversationId(scOff.conversation_id), "Muted body never pushed");

    // Wait for all 4 expected deliveries:
    // Main -> devMainOn; Inherit -> devMainOn; Always-On -> devMainOn + devMainOff; Off -> none.
    const waitDelivery = async (installation: string, entry: EntryRecord) => {
      const deadline = Date.now() + 8_000;
      while (Date.now() < deadline) {
        const saved = (await session.snapshot(NotificationDeliveries, notificationDeliveryKey(installation, entry.id.toString()), BACKGROUND_CONTEXT))?.delivery;
        if (saved?.state === "accepted") return;
        await new Promise((r) => setTimeout(r, 25));
      }
      throw new Error(`Timed out waiting for delivery ${installation}/${entry.id}`);
    };
    await waitDelivery(devMainOn, mainReply);
    await waitDelivery(devMainOn, inheritReply);
    await waitDelivery(devMainOn, onReply);
    await waitDelivery(devMainOff, onReply);
    // Give any unexpected delivery a brief window so we catch leaks cleanly.
    await new Promise((r) => setTimeout(r, 100));

    assert.equal(requests.length, 4);
    assert.ok(requests.some((r) => r.path === "/3/device/" + tokOn && r.title === "Beep Boop" && r.conversation_id === "1"));
    assert.ok(requests.some((r) => r.path === "/3/device/" + tokOn && r.title === "Beep Boop · Inherit Topic" && r.conversation_id === scInherit.conversation_id));
    assert.ok(requests.some((r) => r.path === "/3/device/" + tokOn && r.title === "Beep Boop · Always On Topic" && r.conversation_id === scOn.conversation_id));
    assert.ok(requests.some((r) => r.path === "/3/device/" + tokOff && r.title === "Beep Boop · Always On Topic" && r.conversation_id === scOn.conversation_id));
    assert.equal(requests.some((r) => r.body.includes("Muted")), false);
  } finally {
    notifications.close();
    await session.close(BACKGROUND_CONTEXT);
    for (const s of sessions) s.destroy();
    await new Promise<void>((resolve, reject) => server.close((err) => (err === undefined ? resolve() : reject(err))));
    await rm(directory, { recursive: true, force: true });
    void t;
  }
});

test("bridge streams ObserveSidechat, SidechatInput, updates, and advertises sidechats capability on MainReady", { timeout: 15_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-bridge-"));
  const queue = join(directory, "responses.json");
  await writeFile(
    queue,
    JSON.stringify({
      "hello-sidechat": [{ text: "Side chat reply streamed cleanly." }],
    }),
  );
  const child = spawn(
    process.execPath,
    ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
    { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } },
  );
  const closed = new Promise<number | null>((resolve) => child.once("close", resolve));
  const frames: RuntimeEvent[] = [];
  const waiters = new Set<() => void>();
  let errors = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });
  const send = (id: number, command: RuntimeCommand) => child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n");
  const waitFor = (id: number, predicate: (event: RuntimeEventKind) => boolean): Promise<RuntimeEventKind> =>
    new Promise((resolve, reject) => {
      function cleanup() { waiters.delete(check); t.signal.removeEventListener("abort", stopped); child.off("close", stopped); }
      function stopped() { cleanup(); reject(new Error(`Bridge closed before request ${id} matched: ${errors}`)); }
      function check() {
        const match = frames.find((frame) => frame.id === id && predicate(frame.event));
        if (match === undefined) return;
        cleanup();
        resolve(match.event);
      }
      waiters.add(check);
      t.signal.addEventListener("abort", stopped, { once: true });
      child.once("close", stopped);
      check();
    });

  const reader = (async () => {
    for await (const line of protocolLines(child.stdout)) {
      const frame: unknown = JSON.parse(line);
      assert.ok(validEvent(frame));
      frames.push(frame);
      for (const check of waiters) check();
      if (frame.event.type !== "host_call") continue;
      const result: HostResult = frame.event.command.type === "reload_guidance"
        ? { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] }
        : frame.event.command.type === "project_guidance"
          ? { type: "project_guidance", snapshot: { text: "", sources: [] } }
          : { type: "failed", message: "Synthetic host disabled" };
      send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result });
    }
  })();

  try {
    // Configure coordinator + online host so sidechat_input can run.
    send(1, {
      type: "configure_coordinator",
      bootstrap: {
        node: {
          host_id: "11111111-1111-4111-8111-111111111111",
          name: "fixture-host",
          rex_server: null,
          coordinator: null,
          home_directory: "/workspace/example",
          agent_program: "/example/agent",
          launch: { model: DEFAULT_MODEL, instructions: "", state_dir: directory, runtime: "", config: "" },
        },
        settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] },
      },
    });
    await waitFor(1, (e) => e.type === "done");
    send(2, { type: "set_connected_nodes", host_ids: ["11111111-1111-4111-8111-111111111111"] });
    await waitFor(2, (e) => e.type === "done");

    // Observe main -> check sidechats capability flag.
    send(3, { type: "observe_main", input_ids: [] });
    const mainReady = await waitFor(3, (e) => e.type === "main_ready");
    assert.equal(mainReady.type, "main_ready");
    assert.equal(mainReady.sidechats, true);
    send(3, { type: "detach_main" });
    await waitFor(3, (e) => e.type === "done");

    // Create a side chat.
    send(4, { type: "create_sidechat", title: "Home Renovation", charter: "Track quotes and contractor dates." });
    const createdEvent = await waitFor(4, (e) => e.type === "sidechat");
    assert.equal(createdEvent.type, "sidechat");
    const sidechat = createdEvent.sidechat;
    assert.equal(sidechat.slug, "home-renovation");
    await waitFor(4, (e) => e.type === "done");

    // Observe the side chat.
    send(5, { type: "observe_sidechat", conversation_id: sidechat.conversation_id, input_ids: [] });
    const readyEvent = await waitFor(5, (e) => e.type === "sidechat_ready");
    assert.equal(readyEvent.type, "sidechat_ready");
    assert.equal(readyEvent.sidechat.title, "Home Renovation");
    await waitFor(5, (e) => e.type === "worker_idle");

    // Send SidechatInput and verify streaming text_delta + answer arrive on the observer!
    send(6, {
      type: "sidechat_input",
      conversation_id: sidechat.conversation_id,
      input_id: "input-sidechat-1",
      input: "hello-sidechat",
      mode: "follow_up",
    });
    const observedAnswer = await waitFor(5, (e) => e.type === "answer");
    assert.equal(observedAnswer.type, "answer");
    assert.equal(observedAnswer.conversation_id, sidechat.conversation_id);
    assert.match(observedAnswer.text, /Side chat reply streamed cleanly/);
    const observerEvents = frames.filter((f) => f.id === 5).map((f) => f.event);
    assert.ok(observerEvents.some((e) => e.type === "text_delta"), "Sidechat observer must receive live text_delta streaming events");
    await waitFor(6, (e) => e.type === "done");

    send(5, { type: "detach_sidechat" });
    await waitFor(5, (e) => e.type === "done");

    // Early detach_sidechat sent immediately after observe_sidechat must terminate cleanly without hanging.
    send(7, { type: "observe_sidechat", conversation_id: sidechat.slug, input_ids: [] });
    send(7, { type: "detach_sidechat" });
    await waitFor(7, (e) => e.type === "done");

    // conversation_interrupt resolves side chat slugs cleanly.
    send(8, { type: "conversation_interrupt", conversation_id: sidechat.slug });
    await waitFor(8, (e) => e.type === "interrupted");
    await waitFor(8, (e) => e.type === "done");

    child.stdin.end();
    assert.equal(await closed, 0, errors);
  } finally {
    child.kill();
    await closed;
    await reader.catch(() => {});
    await rm(directory, { recursive: true, force: true });
  }
});

test("numeric slugs are rejected or auto-prefixed and post_to_sidechat validates task_id before unarchiving", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-validation-"));
  const app = await openHarness(directory);
  try {
    const auto = await app.sidechats.create({ title: "2026" });
    assert.equal(auto.slug, "topic-2026");

    await assert.rejects(() => app.sidechats.create({ title: "Digits", slug: "42" }), /purely numeric/i);

    const archived = await app.sidechats.create({ title: "Archived Note", slug: "archived-note" });
    await app.sidechats.update({ conversation_id: archived.conversation_id, archived: true });

    const sidechatTools = createSidechatTools(app.sidechats, app.tasks, app.session, app.executions);
    const root = await app.session.root(BACKGROUND_CONTEXT);
    const release = app.executions.bind(root.id.toString(), {
      model: DEFAULT_MODEL, cwd: "/", hosts: [host], default_host: host, origin_host_id: host.host_id,
      connectedHosts: async () => [host],
      search: async () => ({ candidates: [], gaps: [] }),
      call: async () => ({ type: "failed", message: "unused" }),
    });
    try {
      const postTool = sidechatTools.tools?.find((t) => t.name === "post_to_sidechat");
      assert.ok(postTool !== undefined);
      await assert.rejects(
        () => postTool.execute({ sidechat: archived.slug, text: "Update", task_id: "00000000-0000-4000-8000-000000000099" }, {
          conversationId: root.id,
          callId: "call-bad-task",
          commit: app.session.commit.bind(app.session),
        } as never, BACKGROUND_CONTEXT),
        /Unknown task/i,
      );
      const stillArchived = await app.sidechats.get(archived.conversation_id);
      assert.notEqual(stillArchived?.archived_at, undefined, "Failed post_to_sidechat must not unarchive target");
    } finally {
      release();
    }
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("isolated sidechat delegated tasks stay out of retrieval and catalog until shared, and sidechat notify_user/delegate_task rules hold", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-isolated-tasks-"));
  const app = await openHarness(directory);
  await app.sources.prepare();
  try {
    const isolated = await app.sidechats.create({ title: "Private Finance", slug: "private-finance", isolated: true });
    const delegated = await app.tasks.create({
      id: "11111111-1111-4111-8111-111111111199",
      title: "SecretVault Audit",
      outcome: "Check private invoice ledger",
      model: DEFAULT_MODEL,
      delivery_conversation_id: isolated.conversation_id,
    });
    const delegatedConv = await app.tasks.conversation(delegated.conversation_id);
    await delegatedConv.commit((tx) => tx.appendEntry(delegatedConv.id, {
      kind: AssistantEntry.kind,
      model: [fauxAssistantMessage("SecretVault private invoice details")],
    }), BACKGROUND_CONTEXT);

    await app.retrieval.sync(app.hostCall, true);
    const hiddenFind = await app.tasks.find("SecretVault", [], 8, (q, refs, lim, mode) => app.retrieval.search(q, refs, lim, app.hostCall, false, mode));
    assert.equal(hiddenFind.matches.some((m) => m.conversation_id === delegated.conversation_id), false);
    const hiddenCatalog = await app.catalog.list("", null, 50);
    assert.equal(hiddenCatalog.items.some((item) => item.conversation_id === delegated.conversation_id), false);

    // Un-isolating the side chat exposes its delegated task to search & catalog.
    await app.sidechats.update({ conversation_id: isolated.conversation_id, isolated: false });
    await app.retrieval.sync(app.hostCall, false);
    const visibleFind = await app.tasks.find("SecretVault", [], 8, (q, refs, lim, mode) => app.retrieval.search(q, refs, lim, app.hostCall, false, mode));
    assert.equal(visibleFind.matches.some((m) => m.conversation_id === delegated.conversation_id), true);
    const visibleCatalog = await app.catalog.list("", null, 50);
    assert.equal(visibleCatalog.items.some((item) => item.conversation_id === delegated.conversation_id), true);

    // Re-isolating removes the delegated task from search again.
    await app.sidechats.update({ conversation_id: isolated.conversation_id, isolated: true });
    await app.retrieval.sync(app.hostCall, false);
    const rehiddenFind = await app.tasks.find("SecretVault", [], 8, (q, refs, lim, mode) => app.retrieval.search(q, refs, lim, app.hostCall, false, mode));
    assert.equal(rehiddenFind.matches.some((m) => m.conversation_id === delegated.conversation_id), false);

    // delegate_task's find option excludes side chats so a side chat never blocks its own delegation.
    const shared = await app.sidechats.create({ title: "Kyoto Trip", slug: "kyoto-trip", isolated: false });
    const withSidechats = await app.tasks.find("kyoto trip", [], 8, undefined, "semantic", { includeSidechats: true });
    assert.equal(withSidechats.matches.some((m) => m.conversation_id === shared.conversation_id), true);
    const withoutSidechats = await app.tasks.find("kyoto trip", [], 8, undefined, "semantic", { includeSidechats: false });
    assert.equal(withoutSidechats.matches.some((m) => m.conversation_id === shared.conversation_id), false);

    // notify_user from a side chat rejects unless escalate_to_main: true.
    const sourceTools = createSourceTools(app.sources, app.executions);
    const scConv = await app.tasks.conversation(shared.conversation_id);
    const release = app.executions.bind(shared.conversation_id, {
      model: DEFAULT_MODEL, cwd: "/", hosts: [host], default_host: host, origin_host_id: host.host_id,
      role: "sidechat",
      connectedHosts: async () => [host],
      search: async () => ({ candidates: [], gaps: [] }),
      call: async () => ({ type: "failed", message: "unused" }),
    });
    try {
      const notifyUserTool = sourceTools.main.tools?.find((t) => t.name === "notify_user");
      assert.ok(notifyUserTool !== undefined);
      await assert.rejects(
        () => notifyUserTool.execute({ text: "Local status" }, { conversationId: scConv.id, callId: "call-local" } as never, BACKGROUND_CONTEXT),
        /escalate_to_main/i,
      );
      const originEntry = await scConv.commit((tx) => tx.appendEntry(scConv.id, {
        kind: AssistantEntry.kind,
        model: [fauxAssistantMessage([fauxToolCall("notify_user", { text: "Urgent", escalate_to_main: true }, { id: "call-escalate" })])],
      }), BACKGROUND_CONTEXT);
      assert.ok(originEntry !== undefined);
      const escalated = await notifyUserTool.execute(
        { text: "Urgent decision needed", escalate_to_main: true },
        { conversationId: scConv.id, callId: "call-escalate" } as never,
        BACKGROUND_CONTEXT,
      );
      assert.match(JSON.stringify(escalated), /main chat/i);
    } finally {
      release();
    }
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("notification sidechat cursors persist in Chord and unmuting Main preserves pending always-on sidechat alerts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-apns-regress-"));
  const { privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
  const keyFile = join(directory, "apns.p8");
  await writeFile(keyFile, privateKey.export({ type: "pkcs8", format: "pem" }));
  await chmod(keyFile, 0o600);
  const config: ApnsConfig = { key_file: keyFile, key_id: "ABCDE12345", team_id: "FGHIJ67890", topic: "dev.example.agent", environment: "sandbox" };

  const requests: { conversation_id: string; body: string }[] = [];
  const sessions = new Set<ServerHttp2Session>();
  const server = createServer();
  server.on("session", (s) => { sessions.add(s); s.once("close", () => sessions.delete(s)); });
  server.on("stream", (stream: ServerHttp2Stream, _headers: IncomingHttpHeaders) => {
    let raw = "";
    stream.setEncoding("utf8").on("data", (chunk: string) => { raw += chunk; });
    stream.once("end", () => {
      const parsed = JSON.parse(raw) as { aps: { alert: { body: string } }; agent: { conversation_id: string } };
      requests.push({ conversation_id: parsed.agent.conversation_id, body: parsed.aps.alert.body });
      stream.respond({ ":status": 200 });
      stream.end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address !== null && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;

  const registry = createRegistry();
  const session = await Harness.open(
    await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models: createModels(), registry, identity: { attribution: null } },
    BACKGROUND_CONTEXT,
  );
  await session.root(BACKGROUND_CONTEXT);
  const sidechats = new SidechatStore(session);
  const notifications = new Notifications(session, registry, config, origin, undefined, sidechats);
  await notifications.start();
  session.resume();
  try {
    const dev = "33333333-3333-4333-8333-333333333333";
    const tok = "cc33".repeat(24);
    await notifications.request({ type: "register", installation_id: dev, token: tok, main_enabled: false });
    const scOn = await sidechats.create({ title: "Alerts On", notifications: "on" });
    const append = (cid: typeof ROOT_CONVERSATION_ID, text: string): Promise<EntryRecord> =>
      session.commit((tx) => tx.appendEntry(cid, { kind: AssistantEntry.kind, model: [fauxAssistantMessage(text)] }), BACKGROUND_CONTEXT);

    const first = await append(nativeConversationId(scOn.conversation_id), "First always-on alert");
    const waitDelivery = async (entry: EntryRecord) => {
      const deadline = Date.now() + 8_000;
      while (Date.now() < deadline) {
        const saved = (await session.snapshot(NotificationDeliveries, notificationDeliveryKey(dev, entry.id.toString()), BACKGROUND_CONTEXT))?.delivery;
        if (saved?.state === "accepted") return;
        await new Promise((r) => setTimeout(r, 25));
      }
      throw new Error(`Timed out waiting for delivery ${entry.id}`);
    };
    await waitDelivery(first);

    // Side chat cursor must be durably persisted in NotificationState.cursors (not lost on a detached proxy).
    const state = await session.snapshot(NotificationState, BACKGROUND_CONTEXT);
    assert.equal(state?.cursors?.[scOn.conversation_id], first.id);

    // Re-registering with the same token and omitted main_enabled unmutes Main cleanly.
    const unmuted = await notifications.request({ type: "register", installation_id: dev, token: tok });
    assert.equal(unmuted.registered, true);
    assert.equal(unmuted.main_enabled, undefined);

    const mainAfterUnmute = await append(ROOT_CONVERSATION_ID, "Main reply after unmute");
    await waitDelivery(mainAfterUnmute);
    assert.ok(requests.some((r) => r.conversation_id === "1" && r.body.includes("Main reply after unmute")));
  } finally {
    notifications.close();
    await session.close(BACKGROUND_CONTEXT);
    for (const s of sessions) s.destroy();
    await new Promise<void>((resolve, reject) => server.close((err) => (err === undefined ? resolve() : reject(err))));
    await rm(directory, { recursive: true, force: true });
  }
});

test("BackgroundScheduler syncJobs replaces timer revision when only delivery_sidechat changes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-bg-rev-"));
  const app = await openHarness(directory);
  try {
    const baseJob = {
      id: "daily-brief",
      title: "Daily Brief",
      prompt: "Summarize updates.",
      model: DEFAULT_MODEL,
      timezone: "UTC",
      cwd: "/workspace/example",
      revision: "rev-1",
      delivery_sidechat: "morning-brief",
      schedules: [{ id: "am", recurrence: "daily at 08:00", focus: null, prompt: null }],
    };
    const liveTrigger = async () => {
      const inspected = await app.session.inspect(BACKGROUND_CONTEXT);
      return inspected.tasks.find((task) => {
        if (task.record.kind !== "agent.background" || task.record.abortRequested) return false;
        const input = task.record.input as { type?: string; key?: { type?: string; job_id?: string } } | null;
        return input?.type === "trigger" && input.key?.type === "job" && input.key.job_id === "daily-brief";
      });
    };
    const first = await app.background.syncJobs([baseJob]);
    assert.equal(first.added, 1);
    const firstTrigger = await liveTrigger();
    assert.ok(firstTrigger !== undefined);
    const firstInput = firstTrigger.record.input as { generation: number; job: { delivery_sidechat?: string } };
    assert.equal(firstInput.generation, 1);
    assert.equal(firstInput.job.delivery_sidechat, "morning-brief");

    const unchanged = await app.background.syncJobs([baseJob]);
    assert.equal(unchanged.unchanged, 1);
    assert.equal((await liveTrigger())?.record.id, firstTrigger.record.id);

    const changed = await app.background.syncJobs([{ ...baseJob, revision: "rev-2", delivery_sidechat: "evening-brief" }]);
    assert.equal(changed.updated, 1);
    const updatedTrigger = await liveTrigger();
    assert.ok(updatedTrigger !== undefined);
    assert.notEqual(updatedTrigger.record.id, firstTrigger.record.id, "Timer task must be replaced when delivery_sidechat changes");
    const updatedInput = updatedTrigger.record.input as { generation: number; job: { delivery_sidechat?: string } };
    assert.equal(updatedInput.generation, 2);
    assert.equal(updatedInput.job.delivery_sidechat, "evening-brief");
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("per-conversation NoticeContextPlacement does not mark idle Main as running in Active Work", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-notice-scope-"));
  const app = await openHarness(directory);
  try {
    await app.session.root(BACKGROUND_CONTEXT);
    const sc = await app.sidechats.create({ title: "Ops", slug: "ops" });
    const scConv = await app.tasks.conversation(sc.conversation_id);
    const origin = await scConv.commit((tx) => tx.appendEntry(scConv.id, {
      kind: AssistantEntry.kind,
      model: [fauxAssistantMessage("Notice origin")],
    }), BACKGROUND_CONTEXT);
    await placeNoticeContext(app.session, scConv, origin, "req-sidechat-1", ["Sidechat notice text"]);
    const graph = await readTaskGraph(app.tasks, app.sidechats);
    assert.equal(graph.work.some((item) => item.conversation_id === ROOT_CONVERSATION_ID.toString()), false);
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("SidechatStore rejects terminal escapes, bidi overrides, Kelvin-sign slugs, and malformed seed ids", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-validation-"));
  const app = await openHarness(directory);
  try {
    await assert.rejects(
      () => app.sidechats.create({ title: "Spoof\u202eTitle" }),
      /control or formatting/i,
    );
    await assert.rejects(
      () => app.sidechats.create({ title: "Zero\u200bWidth" }),
      /control or formatting/i,
    );
    await assert.rejects(
      () => app.sidechats.create({ title: "Safe", slug: "\u212aelvin" }),
      /lowercase ASCII/i,
    );
    await assert.rejects(
      () => app.sidechats.create({ title: "Safe", charter: "Bad\x1b[31mcharter" }),
      /control or directional/i,
    );
    await assert.rejects(
      () => app.sidechats.create({ title: "Safe", handoff: "Bad\x1b]0;spoof\x07" }),
      /control or directional/i,
    );
    await assert.rejects(
      () => app.sidechats.create({
        title: "Safe",
        seed: { entry_id: "bad id", role: "assistant", excerpt: "Valid" },
      }),
      /valid entry_id/i,
    );
    await assert.rejects(
      () => app.sidechats.create({
        title: "Safe",
        seed: { entry_id: "1".repeat(129), role: "assistant", excerpt: "Valid" },
      }),
      /valid entry_id/i,
    );
    const seeded = await app.sidechats.create({
      title: "Kitchen \u{1f9d1}\u{200d}\u{1f373}",
      seed: { entry_id: "42", role: "assistant", excerpt: "Call \u{202a}+1 555 0100\u{202c}\x1b[31m now" },
    });
    assert.equal(seeded.title, "Kitchen \u{1f9d1}\u{200d}\u{1f373}");
    assert.equal(seeded.seed?.excerpt, "Call +1 555 0100[31m now");
    const family = await app.sidechats.create({ title: "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} Family" });
    assert.equal(family.title, "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} Family");
    const runner = await app.sidechats.create({ title: "\u{1f3c3}\u{200d}\u{2640}\u{fe0f} Running" });
    assert.equal(runner.title, "\u{1f3c3}\u{200d}\u{2640}\u{fe0f} Running");
    const zwnj = await app.sidechats.create({ title: "می\u{200c}روم" });
    assert.equal(zwnj.title, "می\u{200c}روم");
    const rtlMark = await app.sidechats.create({ title: "פרויקט 2026\u{200f}" });
    assert.equal(rtlMark.title, "פרויקט 2026\u{200f}");
    const valid = await app.sidechats.create({
      title: "Multiline Safe",
      charter: "Line 1\n\tLine 2\u{2068}Name\u{2069}\x0cPage 2",
      handoff: "Notes:\n- item 1 \u{200e}next\u{2068}RTL\u{2069}",
    });
    assert.equal(valid.slug, "multiline-safe");
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("scheduled job calling notify_user still delivers its final answer and missing-target warning without replay duplicates", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-sched-notify-"));
  const app = await openScheduled(directory);
  try {
    const sidechats = new SidechatStore(app.session);
    app.tasks.useSidechats(sidechats);
    app.sources.useSidechats(sidechats);
    const brief = await sidechats.create({ title: "Morning Brief", slug: "morning-brief" });

    // 1. Job calls notify_user mid-turn and then returns its final briefing.
    const occWithNotify: ScheduledOccurrence = {
      ...scheduledOccurrence,
      id: "occ-notify-then-answer-1",
      job: { ...scheduledOccurrence.job, delivery_sidechat: "morning-brief" },
    };
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("notify_user", { text: "Heads up: gathering metrics." }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Final morning briefing body."),
    ]);
    await runScheduled(occWithNotify, new AbortController().signal, { ...app, sidechats });

    const briefConv = await app.tasks.conversation(brief.conversation_id);
    let briefNotices = (await briefConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.deepEqual(briefNotices, [
      "Heads up: gathering metrics.",
      "Final morning briefing body.",
    ]);

    // Replay after archiving the side chat must neither duplicate nor re-unarchive it.
    await sidechats.update({ conversation_id: brief.conversation_id, archived: true });
    await runScheduled(occWithNotify, new AbortController().signal, { ...app, sidechats });
    assert.ok((await sidechats.get(brief.conversation_id))?.archived_at !== undefined);
    briefNotices = (await briefConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text);
    assert.equal(briefNotices.length, 2);

    // 2. Missing target job calling notify_user mid-turn still delivers final answer + warning to Main.
    const occMissingWithNotify: ScheduledOccurrence = {
      ...scheduledOccurrence,
      id: "occ-missing-notify-2",
      job: { ...scheduledOccurrence.job, delivery_sidechat: "later-topic" },
    };
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("notify_user", { text: "Missing-target heads up." }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Missing-target final briefing."),
    ]);
    await runScheduled(occMissingWithNotify, new AbortController().signal, { ...app, sidechats });

    const root = await app.session.root(BACKGROUND_CONTEXT);
    const rootNotices = (await root.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text ?? "");
    assert.ok(rootNotices.includes("Missing-target heads up."));
    assert.ok(rootNotices.some((text) =>
      text.includes("later-topic") && text.includes("Missing-target final briefing.")));

    // 3. Replaying the fallback occurrence after creating a chat with that slug must not double-post.
    const later = await sidechats.create({ title: "Later Topic", slug: "later-topic" });
    await runScheduled(occMissingWithNotify, new AbortController().signal, { ...app, sidechats });
    const laterConv = await app.tasks.conversation(later.conversation_id);
    const laterNotices = (await laterConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry));
    assert.equal(laterNotices.length, 0);
  } finally {
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("blocking owner questions from a side chat's task pass up to Main regardless of escalate_to_main or call order", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-owner-wait-"));
  const app = await openHarness(directory);
  let releaseSidechat: (() => void) | undefined;
  let releaseWorkerA: (() => void) | undefined;
  let releaseWorkerB: (() => void) | undefined;
  let releaseWorkerC: (() => void) | undefined;
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    const tax = await app.sidechats.create({ title: "Tax Filings", slug: "tax-filings", notifications: "off" });
    const taxConv = await app.tasks.conversation(tax.conversation_id);
    releaseSidechat = app.executions.bind(tax.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "sidechat",
      call: app.hostCall,
    });

    const createSidechatTask = async (title: string) =>
      app.tasks.create({ title, outcome: title, delivery_conversation_id: tax.conversation_id });

    const rootNoticeTexts = async () =>
      (await root.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
        .filter((entry) => UserNoticeEntry.is(entry))
        .map((entry) => entry.data.text ?? "");

    // Ordering A: worker sends notify_user WITHOUT escalate_to_main, then records waiting on owner in next turn.
    const taskA = await createSidechatTask("Check receipts");
    const convA = await app.tasks.conversation(taskA.conversation_id);
    releaseWorkerA = app.executions.bind(taskA.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(convA, fixtureModel, { extensions: app.toolsets.worker });
    await app.sidechats.update({ conversation_id: tax.conversation_id, archived: true });
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "QUESTION: may I pay the 400 fee?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Asked in side chat."),
    ]);
    assert.equal((await (await convA.submit({ type: "input", content: "Check fee" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Blocked on owner approval of the 400 fee.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Waiting on owner."),
    ]);
    assert.equal((await (await convA.submit({ type: "input", content: "Record wait" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    let mainNotices = await rootNoticeTexts();
    assert.ok(mainNotices.some((text) =>
      text.includes("QUESTION: may I pay the 400 fee?") && text.includes("Blocked on owner approval of the 400 fee.")),
    `Expected blocking question and summary in Main, got: ${JSON.stringify(mainNotices)}`);

    // Ordering B: worker records waiting on owner FIRST, then calls notify_user WITHOUT escalate_to_main in one turn.
    // record_task posts immediately (never waits for turn end), and notify_user delivers to BOTH sidechat and Main
    // (skipping Main duplicate when the text matches the already-posted summary).
    const taskB = await createSidechatTask("Confirm filing date");
    const convB = await app.tasks.conversation(taskB.conversation_id);
    releaseWorkerB = app.executions.bind(taskB.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(convB, fixtureModel, { extensions: app.toolsets.worker });
    const mainCountBeforeB = (await rootNoticeTexts()).length;
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on filing date decision.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Should I file on Monday or Tuesday?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Escalated."),
    ]);
    assert.equal((await (await convB.submit({ type: "input", content: "Ask filing date" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    mainNotices = await rootNoticeTexts();
    const taskBMainNotices = mainNotices.slice(mainCountBeforeB);
    assert.deepEqual(taskBMainNotices, ["Waiting on filing date decision.", "Should I file on Monday or Tuesday?"]);
    const sideNotices = (await taxConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text ?? "");
    assert.ok(sideNotices.includes("Should I file on Monday or Tuesday?"));

    // Ordering B2: record_task FIRST with identical text to notify_user -> 1 Main notice, 1 sidechat notice.
    await app.tasks.enqueue(taskB.id, "Owner answered filing date", "req-b2-reopen");
    const mainCountBeforeB2 = mainNotices.length;
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Approve wire now?",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Approve wire now?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Done."),
    ]);
    assert.equal((await (await convB.submit({ type: "input", content: "Ask wire approval" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    mainNotices = await rootNoticeTexts();
    assert.deepEqual(mainNotices.slice(mainCountBeforeB2), ["Approve wire now?"]);
    const sideNoticesAfterB2 = (await taxConv.entries({ order: "ascending" }, 50, undefined, BACKGROUND_CONTEXT)).items
      .filter((entry) => UserNoticeEntry.is(entry))
      .map((entry) => entry.data.text ?? "");
    assert.ok(sideNoticesAfterB2.includes("Approve wire now?"));

    // Ordering C: worker already escalated via escalate_to_main before record_task in the same turn:
    // - when the escalated notice already contains the summary -> 1 notice (no duplicate);
    // - waiting on external target does NOT post to Main.
    const taskC = await createSidechatTask("Await bank transfer");
    const convC = await app.tasks.conversation(taskC.conversation_id);
    releaseWorkerC = app.executions.bind(taskC.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(convC, fixtureModel, { extensions: app.toolsets.worker });
    const mainCountBeforeC = mainNotices.length;
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Approve bank transfer?", escalate_to_main: true });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Approve bank transfer?",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Done."),
    ]);
    assert.equal((await (await convC.submit({ type: "input", content: "Request approval" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    mainNotices = await rootNoticeTexts();
    assert.deepEqual(mainNotices.slice(mainCountBeforeC), ["Approve bank transfer?"]);

    // External wait stays quiet in Main.
    const beforeExternal = mainNotices.length;
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on bank clearing.",
        state: { state: "waiting", actor: "bank", next_check: null, target: "external" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Waiting externally."),
    ]);
    assert.equal((await (await convC.submit({ type: "input", content: "Wait on bank" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    assert.equal((await rootNoticeTexts()).length, beforeExternal);
  } finally {
    releaseWorkerC?.();
    releaseWorkerB?.();
    releaseWorkerA?.();
    releaseSidechat?.();
    await app.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("later blocking questions after progress records, long turns, identical wording, alerts, or stop still reach Main", { timeout: 25_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-sidechats-owner-wait-later-"));
  const app = await openHarness(directory);
  let releaseWorker: (() => void) | undefined;
  let releaseAlertWorker: (() => void) | undefined;
  let releaseRepeatWorker: (() => void) | undefined;
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    const tax = await app.sidechats.create({ title: "Audit Prep", slug: "audit-prep", notifications: "off" });
    const taxConv = await app.tasks.conversation(tax.conversation_id);

    const rootNoticeTexts = async () =>
      (await root.entries({ order: "ascending" }, 500, undefined, BACKGROUND_CONTEXT)).items
        .filter((entry) => UserNoticeEntry.is(entry))
        .map((entry) => entry.data.text ?? "");

    const task = await app.tasks.create({
      title: "Multi-question audit",
      outcome: "Verify audit filings",
      delivery_conversation_id: tax.conversation_id,
    });
    const conv = await app.tasks.conversation(task.conversation_id);
    releaseWorker = app.executions.bind(task.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(conv, fixtureModel, { extensions: app.toolsets.worker });

    // 1. First blocking question reaches Main immediately, and re-recording inside the SAME wait episode
    // (without reopening, even reworded) does not add another Main notice.
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Q1: Approve initial scope?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on Q1 scope approval.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Still blocked on Q1 scope approval.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Asked Q1."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Start audit" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    let notices = await rootNoticeTexts();
    assert.equal(notices.length, 1);
    assert.ok(notices[0]!.includes("Q1: Approve initial scope?"));

    // 2. Same wait episode woken without leaving waiting(owner) does not spam Main.
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Reworded: still waiting on Q1.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Still waiting on Q1."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Status poke without answer" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    assert.equal((await rootNoticeTexts()).length, 1, "Re-recording within the same wait episode must not add another Main notice");

    // 3. S2 & P3: Owner answers (reopens task via enqueue), worker records progress (open), asks Q2, records wait -> Q2 reaches Main!
    await app.tasks.enqueue(task.id, "Owner approved Q1", "req-audit-q1");
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Scope approved; checking invoices.",
        state: { state: "open" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Q2: Reclassify invoice 88?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on invoice 88 decision.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Asked Q2."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Owner approved Q1, continue" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    notices = await rootNoticeTexts();
    assert.equal(notices.length, 2, `Expected Q2 in Main after progress record, got: ${JSON.stringify(notices)}`);
    assert.ok(notices[1]!.includes("Q2: Reclassify invoice 88?") && notices[1]!.includes("Waiting on invoice 88 decision."));

    // 4. S3 + B1: Owner answers, >100 unrelated sidechat entries occur, worker does 14 tool calls + notify_user + record_task -> Q3 reaches Main!
    await app.tasks.enqueue(task.id, "Owner approved Q2", "req-audit-q2");
    const fillerCalls = Array.from({ length: 14 }, (_, index) =>
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return ${index};` }),
        { stopReason: "toolUse" },
      ),
    );
    app.faux.setResponses([
      ...fillerCalls,
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Q3: Sign off Q3 ledger?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Asked Q3 in side chat."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Owner approved Q2, continue" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    // Flood >105 unrelated entries into the side chat between notify_user and record_task (B1).
    for (let i = 0; i < 105; i += 1) {
      await taxConv.commit((tx) => tx.appendEntry(taxConv.id, {
        kind: AssistantEntry.kind,
        model: [fauxAssistantMessage(`Side chat chatter ${i}`)],
      }), BACKGROUND_CONTEXT);
    }
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on Q3 ledger sign-off.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Recorded Q3 wait."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Record Q3 wait" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    notices = await rootNoticeTexts();
    assert.equal(notices.length, 3, `Expected Q3 in Main despite >100 sidechat entries, got: ${JSON.stringify(notices)}`);
    assert.ok(notices[2]!.includes("Q3: Sign off Q3 ledger?"));

    // 5. S4: Owner answers, long turn (14 tool calls) then record_task ALONE with Q4 in summary -> Q4 reaches Main!
    await app.tasks.enqueue(task.id, "Owner approved Q3", "req-audit-q3");
    app.faux.setResponses([
      ...fillerCalls,
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Q4: Should I submit amended schedule B?",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Asked Q4 via summary."),
    ]);
    assert.equal((await (await conv.submit({ type: "input", content: "Owner approved Q3, continue" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    notices = await rootNoticeTexts();
    assert.equal(notices.length, 4, `Expected Q4 summary in Main after long turn, got: ${JSON.stringify(notices)}`);
    assert.equal(notices[3], "Q4: Should I submit amended schedule B?");

    // 6. E1 & E3: New waits with the EXACT SAME question and summary after owner answers MUST reach Main every time!
    const repeatTask = await app.tasks.create({
      title: "Batch processor",
      outcome: "Process batches with owner go-ahead",
      delivery_conversation_id: tax.conversation_id,
    });
    const repeatConv = await app.tasks.conversation(repeatTask.conversation_id);
    releaseRepeatWorker = app.executions.bind(repeatTask.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(repeatConv, fixtureModel, { extensions: app.toolsets.worker });
    const countBeforeE1 = (await rootNoticeTexts()).length;
    for (let batch = 1; batch <= 3; batch += 1) {
      if (batch > 1) {
        await app.tasks.enqueue(repeatTask.id, `Yes, continue batch ${batch}`, `req-batch-${batch}`);
      }
      app.faux.setResponses([
        fauxAssistantMessage(
          fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "QUESTION-BATCH: continue with the next batch?" });` }),
          { stopReason: "toolUse" },
        ),
        fauxAssistantMessage(fauxToolCall("record_task", {
          summary: "Waiting for the owner's go-ahead.",
          state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
        }), { stopReason: "toolUse" }),
        fauxAssistantMessage(`Asked batch ${batch}.`),
      ]);
      assert.equal((await (await repeatConv.submit({ type: "input", content: `Run batch ${batch}` }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    }
    const e1Notices = (await rootNoticeTexts()).slice(countBeforeE1);
    assert.equal(e1Notices.length, 3, `Expected 3 notices for 3 distinct waits with identical text (E1), got: ${JSON.stringify(e1Notices)}`);

    // E3: 2 consecutive waits via record_task ALONE with identical summary after owner answers.
    const countBeforeE3 = (await rootNoticeTexts()).length;
    for (let step = 1; step <= 2; step += 1) {
      await app.tasks.enqueue(repeatTask.id, `Continue step ${step}`, `req-e3-${step}`);
      app.faux.setResponses([
        fauxAssistantMessage(fauxToolCall("record_task", {
          summary: "Confirm next batch step?",
          state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
        }), { stopReason: "toolUse" }),
        fauxAssistantMessage(`Recorded step ${step}.`),
      ]);
      assert.equal((await (await repeatConv.submit({ type: "input", content: `Step ${step}` }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    }
    const e3Notices = (await rootNoticeTexts()).slice(countBeforeE3);
    assert.deepEqual(e3Notices, ["Confirm next batch step?", "Confirm next batch step?"]);

    // 7. C5 & W2: Escalated alert followed by (a) unflagged blocking question + record_task (C5),
    // and (b) 6 tool calls + record_task with question ONLY in summary (W2) -> ALL reach Main!
    const alertTask = await app.tasks.create({
      title: "Alert then question",
      outcome: "Check deadline",
      delivery_conversation_id: tax.conversation_id,
    });
    const alertConv = await app.tasks.conversation(alertTask.conversation_id);
    releaseAlertWorker = app.executions.bind(alertTask.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: app.hostCall,
    });
    await app.inference.configure(alertConv, fixtureModel, { extensions: app.toolsets.worker });
    const countBeforeC5 = (await rootNoticeTexts()).length;
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "ALERT: deadline moved up", escalate_to_main: true });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Q5: Pay expedite fee?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on expedite fee decision.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Done."),
    ]);
    assert.equal((await (await alertConv.submit({ type: "input", content: "Check deadline" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    const c5Notices = (await rootNoticeTexts()).slice(countBeforeC5);
    assert.equal(c5Notices.length, 2, `Expected both alert and blocking question in Main, got: ${JSON.stringify(c5Notices)}`);
    assert.equal(c5Notices[0], "ALERT: deadline moved up");
    assert.ok(c5Notices[1]!.includes("Q5: Pay expedite fee?"));

    // W2: Escalated alert, 6 tool calls, then record_task ALONE with question in summary -> BOTH reach Main!
    await app.tasks.enqueue(alertTask.id, "Continue checking portal", "req-w2");
    const countBeforeW2 = (await rootNoticeTexts()).length;
    const sixTools = Array.from({ length: 6 }, (_, index) =>
      fauxAssistantMessage(fauxToolCall("codemode", { code: `return ${index};` }), { stopReason: "toolUse" }),
    );
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "ALERT W2: the portal is down.", escalate_to_main: true });` }),
        { stopReason: "toolUse" },
      ),
      ...sixTools,
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "QUESTION W2 in the summary: file by post instead?",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Done W2."),
    ]);
    assert.equal((await (await alertConv.submit({ type: "input", content: "Check portal" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    const w2Notices = (await rootNoticeTexts()).slice(countBeforeW2);
    assert.deepEqual(w2Notices, [
      "ALERT W2: the portal is down.",
      "QUESTION W2 in the summary: file by post instead?",
    ]);

    // 8. W1/W3: Two unflagged notify_user notices before record_task -> BOTH reach Main!
    await app.tasks.enqueue(alertTask.id, "Check multiple items", "req-w1");
    const countBeforeW1 = (await rootNoticeTexts()).length;
    app.faux.setResponses([
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Q-W1: Should we keep the old domain?" });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.notify_user({ text: "Meanwhile W1: preparing DNS records." });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "Waiting on domain decision.",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Done W1."),
    ]);
    assert.equal((await (await alertConv.submit({ type: "input", content: "Check domain" }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    const w1Notices = (await rootNoticeTexts()).slice(countBeforeW1);
    assert.equal(w1Notices.length, 1);
    assert.ok(w1Notices[0]!.includes("Q-W1: Should we keep the old domain?"));
    assert.ok(w1Notices[0]!.includes("Meanwhile W1: preparing DNS records."));
    assert.ok(w1Notices[0]!.includes("Waiting on domain decision."));

    // 9. Immediate delivery before turn ends & survival across Stop (abort) + restart!
    releaseAlertWorker();
    let releaseBlockedExec!: () => void;
    let signalEnteredExec!: () => void;
    const enteredExec = new Promise<void>((resolve) => { signalEnteredExec = resolve; });
    const holdExec = new Promise<void>((resolve) => { releaseBlockedExec = resolve; });
    releaseAlertWorker = app.executions.bind(alertTask.conversation_id, {
      cwd: host.cwd, hosts: [host], default_host: host, role: "worker",
      call: async (command) => {
        if (command.type === "exec") {
          signalEnteredExec();
          await holdExec;
          return { type: "process", exit_code: 0, stdout: "", stderr: "", truncated: false };
        }
        return app.hostCall(command);
      },
    });
    await app.tasks.enqueue(alertTask.id, "Next check", "req-stop");
    const countBeforeStop = (await rootNoticeTexts()).length;
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", {
        summary: "QUESTION-STOP: approve immediate courier?",
        state: { state: "waiting", actor: "owner", next_check: null, target: "owner" },
      }), { stopReason: "toolUse" }),
      fauxAssistantMessage(
        fauxToolCall("codemode", { code: `return await tools.exec({ program: "echo", args: ["hold"] });` }),
        { stopReason: "toolUse" },
      ),
      fauxAssistantMessage("Never reached due to abort."),
    ]);
    const pendingStopTurn = await alertConv.submit({ type: "input", content: "Check courier" }, BACKGROUND_CONTEXT);
    await enteredExec;
    // Before the turn finishes or aborts, Main MUST already hold the question!
    const midTurnNotices = (await rootNoticeTexts()).slice(countBeforeStop);
    assert.deepEqual(midTurnNotices, ["QUESTION-STOP: approve immediate courier?"]);
    const aborting = alertConv.abort(BACKGROUND_CONTEXT);
    releaseBlockedExec();
    await aborting;
    const settledStop = await pendingStopTurn.wait(BACKGROUND_CONTEXT);
    assert.equal(settledStop.status, "unanswered");
    assert.deepEqual((await rootNoticeTexts()).slice(countBeforeStop), ["QUESTION-STOP: approve immediate courier?"]);

    // Close and reopen the database (simulating restart after Stop) -> Main still holds the question!
    releaseRepeatWorker();
    releaseRepeatWorker = undefined;
    releaseAlertWorker();
    releaseAlertWorker = undefined;
    releaseWorker();
    releaseWorker = undefined;
    await app.close();
    const reopened = await openHarness(directory);
    try {
      const reopenedRoot = await reopened.session.root(BACKGROUND_CONTEXT);
      const reopenedNotices = (await reopenedRoot.entries({ order: "ascending" }, 500, undefined, BACKGROUND_CONTEXT)).items
        .filter((entry) => UserNoticeEntry.is(entry))
        .map((entry) => entry.data.text ?? "");
      assert.ok(reopenedNotices.includes("QUESTION-STOP: approve immediate courier?"));
      const reopenedTask = await reopened.tasks.get(alertTask.id);
      assert.equal(reopenedTask.state.state, "waiting");
    } finally {
      await reopened.close();
    }
    return;
  } finally {
    releaseRepeatWorker?.();
    releaseAlertWorker?.();
    releaseWorker?.();
    await app.close().catch(() => {});
    await rm(directory, { recursive: true, force: true });
  }
});
