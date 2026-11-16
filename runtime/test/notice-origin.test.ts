import assert from "node:assert/strict";
import { mkdtemp, rm, mkdir, symlink, writeFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { createConnection } from "node:net";
import { fileURLToPath } from "node:url";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxToolCall, type FauxResponseFactory } from "@earendil-works/pi-ai";
import { getCurrentSystemPrompt } from "@earendil-works/pi-ai/utils/transcript";
import { BackgroundScheduler } from "../src/background.js";
import { watchMainNotices } from "../src/main_observation.js";
import { runScheduled } from "../src/scheduled.js";
import { publishMainNotice } from "../src/tasks.js";
import { history, UserNoticeEntry } from "../src/transcript.js";
import { validEvent, protocolLines } from "../src/protocol.js";
import type { NativeEvent } from "../src/generated/NativeEvent.js";
import type { HistoryMessage } from "../src/generated/HistoryMessage.js";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import { fixtureModel } from "./model.js";
import { DAY, exampleJob, FakeClock } from "./fixtures/background-runtime.js";
import { openScheduled } from "./fixtures/scheduled-runtime.js";

function scheduler(app: Awaited<ReturnType<typeof openScheduled>>, completed: string[]) {
  return new BackgroundScheduler(app.session, app.registry, app.tasks, {
    async plan(_cadence, _after, now) { return { due: null, next: now + DAY }; },
    async refreshSources() {}, async triageSources() {}, async collectResources() {}, async indexHistory() {},
    async runJob(occurrence, signal, actor) {
      await runScheduled(occurrence, signal, app, actor); completed.push(occurrence.id);
    },
  });
}
async function eventually(condition: () => boolean | Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!await condition()) { assert.ok(Date.now() < deadline, "The admitted producer did not finish"); await new Promise((resolve) => setTimeout(resolve, 2)); }
}
function notice(text: string) { return fauxAssistantMessage(fauxToolCall("notify_user", { text }), { stopReason: "toolUse" }); }
function origin(row: HistoryMessage | undefined, job: { id: string; title: string }) {
  assert.ok(row); assert.deepEqual(row, { ...row, notice_origin: { job_id: job.id, title: job.title } });
}
async function continued(app: Awaited<ReturnType<typeof openScheduled>>, task: TaskRecord, id: string, text: string): Promise<void> {
  app.faux.setResponses([notice(text), fauxAssistantMessage("")]);
  await app.tasks.enqueue(task.id, "Continue this saved workflow.", id); await app.tasks.runBackground(task.id);
}

test("actual concurrent scheduler publications retain run titles live and after rename, deletion and reopen", { timeout: 20_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-notice-origins-")), clock = new FakeClock();
  let app = await openScheduled(directory, "original", clock), stop = () => {};
  try {
    const completed: string[] = [], background = scheduler(app, completed);
    const packages = { ...exampleJob(), id: "package-tracking", title: "Package tracking", prompt: "PACKAGE_JOB_FIXTURE" };
    const brief = { ...exampleJob(), id: "morning-brief", title: "Morning brief", prompt: "BRIEF_JOB_FIXTURE" };
    await background.syncJobs([packages, brief]);
    const live: HistoryMessage[] = [], root = await app.session.root(BACKGROUND_CONTEXT);
    stop = await watchMainNotices(app.session, root, (event) => {
      assert.ok(validEvent({ version: 1, id: 1, event })); if (event.type === "message") live.push(event.message);
    });
    let entered = 0, release = () => {}; const both = new Promise<void>((resolve) => { release = resolve; });
    const respond: FauxResponseFactory = async (context) => {
      if (context.messages.at(-1)?.role === "toolResult") return fauxAssistantMessage("");
      entered += 1; if (entered === 2) release(); await both;
      // Deliberately misleading body labels cannot choose the originating job.
      return notice(JSON.stringify(context.messages).includes("PACKAGE_JOB_FIXTURE") ? "Morning brief: the parcel needs a decision." : "Package tracking: a briefing decision is needed.");
    };
    app.faux.setResponses([respond, respond, respond, respond]);
    const [packageRun] = await Promise.all([
      background.runJob({ type: "run_job", job_id: packages.id, schedule_id: null, request_id: "packages" }),
      background.runJob({ type: "run_job", job_id: brief.id, schedule_id: null, request_id: "brief" }),
    ]);
    await eventually(() => completed.length === 2); assert.equal(entered, 2); assert.equal(live.length, 2);
    origin(live.find((row) => row.text.includes("parcel")), packages); origin(live.find((row) => row.text.includes("briefing")), brief);
    const renamed = { ...packages, title: "Renamed tracking", revision: "renamed" };
    await background.syncJobs([renamed, brief]);
    const task = await app.tasks.get(packageRun.task_id);
    await app.tasks.update(task.id, (saved) => { saved.title = "An unrelated mutable task title"; });
    await continued(app, task, "continue-before-next-run", "A continuation retains its admitted workflow origin.");
    origin(live.at(-1), packages);
    app.faux.setResponses([notice("The renamed job's new run."), fauxAssistantMessage("")]);
    await background.runJob({ type: "run_job", job_id: packages.id, schedule_id: null, request_id: "renamed" });
    await eventually(() => completed.length === 3); origin(live.at(-1), renamed);
    await background.syncJobs([brief]);
    await continued(app, task, "after-delete", "A saved continuation survives source deletion."); origin(live.at(-1), renamed);
    const count = live.length, calls = app.faux.state.callCount;
    await background.runJob({ type: "run_job", job_id: packages.id, schedule_id: null, request_id: "packages" });
    assert.equal(live.length, count); assert.equal(app.faux.state.callCount, calls, "Replay must not generate an extra publication");
    const durable = (await history(root, null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.deepEqual(durable, live, "Live and historical native rows carry the same captured snapshot");
    stop(); stop = () => {}; await app.session.close(BACKGROUND_CONTEXT);
    app = await openScheduled(directory, "original", clock); scheduler(app, []);
    const reopened = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.deepEqual(reopened, durable, "Historical rows must not look up renamed or deleted job/task titles");
    origin(reopened.find((row) => row.text.includes("parcel")), packages);
  } finally { stop(); await app.close(); await rm(directory, { recursive: true, force: true }); }
});

test("a scheduled child inherits its trusted lineage through deletion and its own continuation", { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-notice-child-")); let app = await openScheduled(directory, "original", new FakeClock()), release = () => {};
  try {
    const completed: string[] = [], background = scheduler(app, completed), job = { ...exampleJob(), title: "Package tracking" };
    await background.syncJobs([job]);
    let entered = () => {};
    const childStarted = new Promise<void>((resolve) => { entered = resolve; });
    const deleted = new Promise<void>((resolve) => { release = resolve; });
    const respond: FauxResponseFactory = async (input) => {
      const done = (name: string) => input.messages.some((message) => message.role === "toolResult" && message.toolName === name);
      if (getCurrentSystemPrompt(input.messages).includes("Task outcome: Check the admitted source.")) {
        if (done("report_result")) return fauxAssistantMessage("");
        if (done("notify_user")) return fauxAssistantMessage(fauxToolCall("report_result", { summary: "Checked the parcel with evidence." }), { stopReason: "toolUse" });
        entered(); await deleted; return notice("The child needs a concrete decision.");
      }
      return done("spawn_agent") ? fauxAssistantMessage("") : fauxAssistantMessage(fauxToolCall("spawn_agent", {
        title: "Unrelated child title", outcome: "Check the admitted source.", input: "Check the parcel.",
      }), { stopReason: "toolUse" });
    };
    app.faux.setResponses(Array.from({ length: 12 }, () => respond));
    const run = await background.runJob({ type: "run_job", job_id: job.id, schedule_id: null, request_id: "child-job" }); await eventually(() => completed.length === 1);
    await childStarted;
    const task = await app.tasks.get(run.task_id), child = task.agents[0]; assert.ok(child); assert.equal(child.worker.state, "unassigned");
    await background.syncJobs([]); await app.tasks.update(task.id, (saved) => { saved.title = "Wrong renamed parent title"; });
    release(); await eventually(() => !app.tasks.isRunning(task.id));
    const root = await app.session.root(BACKGROUND_CONTEXT), rows = (await history(root, null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.equal(rows.length, 1); origin(rows[0], job);
    await app.close(); app = await openScheduled(directory, "original", new FakeClock()); scheduler(app, []);
    const saved = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.deepEqual(saved, rows);
    app.faux.setResponses([notice("The same child has a second necessary decision."), fauxAssistantMessage(fauxToolCall("report_result", { summary: "Rechecked the same evidence." }), { stopReason: "toolUse" }), fauxAssistantMessage("")]);
    await app.tasks.continueAgent(task.id, child.id, "Recheck this same workflow.", "child-followup", app.call);
    await app.tasks.runBackground(task.id, undefined, child.id);
    const continuedRows = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.equal(continuedRows.length, 2); origin(continuedRows[1], job);
  } finally { release(); await app.close(); await rm(directory, { recursive: true, force: true }); }
});

test("main, generic and legacy notices never guess a job from titles, source links or body text", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-notice-generic-")), app = await openScheduled(directory);
  try {
    const task = await app.tasks.create({ title: "Morning brief", outcome: "An ordinary task", sources: [{ provider: "scheduled_jobs", account: "local", thread_id: "morning-brief" }] });
    const host = await app.environment.defaultHost(await app.environment.hosts("/workspace/example", null, [])); assert.ok(host);
    await app.tasks.enqueue(task.id, "Package tracking: a claimed job name is not transport metadata.", "generic"); await app.tasks.dispatch(task.id, host, app.call);
    app.faux.setResponses([notice("Morning brief: actionable generic work."), fauxAssistantMessage("")]); await app.tasks.runBackground(task.id);
    const root = await app.session.root(BACKGROUND_CONTEXT);
    await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [app.sourceTools.main] }, BACKGROUND_CONTEXT);
    const unbind = app.executions.bind(root.id.toString(), { cwd: host.cwd, hosts: [host], call: app.call });
    try { app.faux.setResponses([notice("Package tracking: a direct main-chat update."), fauxAssistantMessage("")]);
      await (await root.submit({ type: "input", content: "A direct request with no scheduled producer." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    } finally { unbind(); }
    await root.submit({ type: "write", entry: { kind: UserNoticeEntry.kind, data: { task_id: task.id, source_conversation_id: task.conversation_id, source_entry_id: "1", text: "Legacy generic notice" } } }, BACKGROUND_CONTEXT);
    for (const metadata of [{ job_id: "", title: "Package tracking" }, { job_id: "package-tracking", title: "  " }]) {
      await root.submit({ type: "write", entry: { kind: UserNoticeEntry.kind, data: { task_id: null, source_conversation_id: "legacy", source_entry_id: "1", text: "Unreliable legacy metadata", notice_origin: metadata } } }, BACKGROUND_CONTEXT);
    }
    const rows = (await history(root, null, app.session)).flatMap((event) => event.messages).filter((row) => row.role === "notice");
    assert.equal(rows.length, 5); for (const row of rows) assert.equal("notice_origin" in row, false);
    const legacy = rows.find(row => row.text === "Legacy generic notice");
    assert.equal(legacy?.notice_details?.task_title, undefined,
      "Legacy IDs must not borrow a task title from the current task store");
    assert.deepEqual(legacy?.notice_details, { task_id: task.id,
      source_conversation_id: task.conversation_id, source_entry_id: "1", sources: [] });
  } finally { await app.close(); await rm(directory, { recursive: true, force: true }); }
});

test("real publication snapshots distinct task and source evidence through live/history and fresh SQLite reopen", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-notice-details-"));
  let app = await openScheduled(directory), stop = () => {};
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT), live: HistoryMessage[] = [];
    stop = await watchMainNotices(app.session, root, (event) => {
      assert.ok(validEvent({ version: 1, id: 1, event }));
      if (event.type === "message") live.push(event.message);
    });
    for (const [provider, title] of [["mail", "Parcel decision"], ["calendar", "Meeting review"]] as const) {
      const task = await app.tasks.create({ title, outcome: "Inspect invented evidence." });
      const conversation = await app.tasks.conversation(task.conversation_id);
      const entry = await (await conversation.submit({ type: "write", entry: {
        kind: "fixture.assistant", model: [fauxAssistantMessage(fauxToolCall("notify", {}, { id: provider }), { stopReason: "toolUse" })]
      } }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
      assert.ok(entry.entry);
      const original = (await conversation.entries({ order: "descending" }, 1, undefined, BACKGROUND_CONTEXT)).items[0];
      assert.ok(original);
      const event = { id: provider + "-event", version: "v1", source: { provider, account: "invented-account", thread_id: provider + "-thread" },
        title: "Invented source title", text: "Never copy event body into provenance." };
      await app.sources.admit({ source: { provider, account: "invented-account" }, events: [event],
        checkpoint: { value: "one" }, coverage: { status: "complete" } }, null);
      const records = await app.sources.events({ provider, account: "invented-account" });
      assert.equal(records.length, 1);
      assert.equal(await app.sources.notify(conversation.id.toString(), provider, records.map(record => record.key),
        task.id, "Misleading body: Job Unknown."), "published");
      await app.tasks.update(task.id, saved => { saved.title = "Later unrelated title"; });
    }
    await eventually(() => live.length === 2);
    assert.deepEqual(live.map(row => row.notice_details?.task_title), ["Parcel decision", "Meeting review"]);
    assert.deepEqual(live.map(row => row.notice_details?.sources[0]?.provider), ["mail", "calendar"]);
    assert.ok(live.every(row => row.notice_origin === undefined && !JSON.stringify(row.notice_details).includes("Never copy")));
    const durable = (await history(root, null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(durable, live);
    stop(); stop = () => {}; await app.close(); app = await openScheduled(directory);
    const fresh = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(fresh, durable);
    console.log("Publication -> live -> persisted history -> fresh SQLite reopen: mail/Parcel decision, calendar/Meeting review; immutable and body-independent.");
  } finally { stop(); await app.close(); await rm(directory, { recursive: true, force: true }); }
});

test("source-only journal publications retain canonical provider/title evidence without a task live and after reopen", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-source-only-notice-"));
  let app = await openScheduled(directory), stop = () => {};
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT), live: HistoryMessage[] = [];
    stop = await watchMainNotices(app.session, root, event => {
      assert.ok(validEvent({ version: 1, id: 1, event }));
      if (event.type === "message") live.push(event.message);
    });
    for (const [provider, title] of [["google", "Parcel decision"], ["github", "Review requested"]] as const) {
      await (await root.submit({ type: "write", entry: {
        kind: "fixture.assistant",
        model: [fauxAssistantMessage(fauxToolCall("notify", {}, { id: provider }), { stopReason: "toolUse" })],
      } }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
      const source = { provider, account: "invented-account", thread_id: provider + "-thread",
        body: "Invented unknown field must not travel" };
      await app.sources.admit({ source, checkpoint: { value: "v1" }, coverage: { status: "complete" },
        events: [{ id: provider + "-event", version: "v1", source, title, text: "Not provenance: task Fake" }] }, null);
      const records = await app.sources.events({ provider, account: source.account });
      assert.equal(await app.sources.notify(root.id.toString(), provider, records.map(record => record.key),
        null, "Job Fake: body labels are not provenance."), "published");
      const record = records[0]; assert.ok(record);
      await app.sources.admit({ source, checkpoint: { value: "v2" }, coverage: { status: "complete" },
        events: [{ ...record.event, version: "v2", title: "Later unrelated title" }] }, { value: "v1" });
    }
    await eventually(() => live.length === 2);
    assert.deepEqual(live.map(row => row.notice_details?.sources.map(({ provider, title }) => ({ provider, title }))), [
      [{ provider: "google", title: "Parcel decision" }], [{ provider: "github", title: "Review requested" }],
    ]);
    for (const row of live) {
      assert.equal(row.notice_details?.task_id, undefined);
      assert.equal(row.notice_details?.task_title, undefined);
      assert.equal(row.notice_origin, undefined);
      assert.ok(row.notice_details?.source_entry_id);
      assert.equal(row.notice_details?.sources[0]?.event_version, "v1");
      assert.equal(JSON.stringify(row.notice_details).includes("body"), false);
      assert.equal(JSON.stringify(row.notice_details).includes("unknown field"), false);
    }
    const durable = (await history(root, null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(durable, live);
    stop(); stop = () => {}; await app.close();
    const native = await retainedNativeHistory(directory);
    assert.deepEqual(native.filter(row => row.role === "notice"), durable,
      "Built Rust coordinator native endpoint must preserve the actual producer's persisted metadata");
    app = await openScheduled(directory);
    const fresh = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(fresh, durable);
    console.log("Source-only task=null: google/Parcel decision and github/Review requested; canonical revision v2 does not alter publication v1; fresh SQLite read matches live.");
  } finally { stop(); await app.close(); await rm(directory, { recursive: true, force: true }); }
});



test("keyless notify_user task-only publication retains its title through the real native endpoint and fresh history", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-task-only-notice-"));
  let app = await openScheduled(directory), stop = () => {};
  try {
    const task = await app.tasks.create({ title: "Inspect parcel", outcome: "Check invented evidence" });
    const host = await app.environment.defaultHost(await app.environment.hosts("/workspace/example", null, [])); assert.ok(host);
    const root = await app.session.root(BACKGROUND_CONTEXT), live: HistoryMessage[] = [];
    stop = await watchMainNotices(app.session, root, event => {
      assert.ok(validEvent({ version: 1, id: 1, event }));
      if (event.type === "message") live.push(event.message);
    });
    await app.tasks.enqueue(task.id, "Check the authorized invented task.", "task-only");
    await app.tasks.dispatch(task.id, host, app.call);
    app.faux.setResponses([notice("Source Google: this body is not provenance."), fauxAssistantMessage("")]);
    const actor = await app.tasks.get(task.id);
    assert.ok(actor.worker.state === "bound");
    await app.tasks.run({ type: "run_task", task_id: task.id,
      allocation_id: actor.worker.allocation_id, binding: actor.worker.binding, instructions: "", model: fixtureModel, cwd: host.cwd },
      conversation => app.executions.bind(conversation.id.toString(), {
        cwd: host.cwd, hosts: [host], role: "worker", call: app.call,
      }), [app.sourceTools.worker]);
    await eventually(() => live.length === 1);
    const row = live[0]; assert.ok(row);
    assert.equal(row.notice_details?.task_id, task.id);
    assert.equal(row.notice_details?.task_title, "Inspect parcel");
    assert.deepEqual(row.notice_details?.sources, []);
    assert.equal(row.notice_origin, undefined);
    await app.tasks.update(task.id, saved => { saved.title = "Later unrelated task title"; });
    const durable = (await history(root, null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(durable, live);
    stop(); stop = () => {}; await app.close();
    const native = await retainedNativeHistory(directory);
    assert.deepEqual(native.filter(row => row.role === "notice"), durable);
    app = await openScheduled(directory);
    const fresh = (await history(await app.session.root(BACKGROUND_CONTEXT), null, app.session)).flatMap(event => event.messages).filter(row => row.role === "notice");
    assert.deepEqual(fresh, durable);
    console.log("Keyless real notify_user -> task-only Inspect parcel -> built Rust native history -> fresh SQLite history: exact immutable metadata, no sources or job.");
  } finally { stop(); await app.close(); await rm(directory, { recursive: true, force: true }); }
});


test("stored notice metadata is allowlisted and conflicting nested bindings fall back to recorded IDs", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-notice-allowlist-"));
  const app = await openScheduled(directory);
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    const snapshot = { source_conversation_id: "original-conversation", source_entry_id: "original-entry",
      task_id: "original-task", task_title: "Recorded title", unknown: "Invented unknown top level",
      sources: [{ provider: "google", account: "invented-account", thread_id: "invented-thread",
        title: "Recorded source", event_id: "invented-event", event_version: "v1", body: "Invented body must not travel" }] };
    for (const details of [snapshot, { ...snapshot, source_entry_id: "conflicting-entry" },
      { ...snapshot, task_id: "conflicting-task" }, { ...snapshot, source_conversation_id: "conflicting-conversation" }]) {
      await (await root.submit({ type: "write", entry: { kind: UserNoticeEntry.kind, data: {
        task_id: "original-task", source_conversation_id: "original-conversation", source_entry_id: "original-entry",
        text: "Invented notice", notice_details: details,
      } } }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    }
    await (await root.submit({ type: "write", entry: { kind: "fixture.original",
      model: [fauxAssistantMessage("Invented original")] } }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    const original = (await root.entries({ order: "descending" }, 1, undefined, BACKGROUND_CONTEXT)).items[0]; assert.ok(original);
    const source = { provider: "google", account: "invented-account", thread_id: "invented-thread",
      body: "Invented extra must not be persisted in notice metadata" };
    await publishMainNotice(app.session, root, original, null, [source], { key: "allowlist", text: "Publisher sentinel",
      events: [{ id: "event", version: "v1", source, title: "Invented source", text: "Invented body" }] });
    const stored = (await root.entries({ order: "descending" }, 20, undefined, BACKGROUND_CONTEXT)).items
      .find(entry => UserNoticeEntry.is(entry) && entry.data.text === "Publisher sentinel");
    assert.ok(stored);
    assert.equal(JSON.stringify(stored.data).includes("Invented extra"), false);
    const rows = (await history(root, null, app.session)).flatMap(event => event.messages)
      .filter(row => row.role === "notice" && row.text !== "Publisher sentinel");
    assert.equal(rows.length, 4);
    for (const row of rows) {
      assert.equal(JSON.stringify(row.notice_details).includes("body"), false);
      assert.equal(JSON.stringify(row.notice_details).includes("unknown"), false);
      assert.equal(row.notice_details?.source_conversation_id, "original-conversation");
      assert.equal(row.notice_details?.source_entry_id, "original-entry");
      assert.equal(row.notice_details?.task_id, "original-task");
      assert.ok(validEvent({ version: 1, id: 1, event: { type: "message", message: row } }));
    }
    assert.deepEqual(rows[0]?.notice_details?.sources, [{ provider: "google", account: "invented-account",
      thread_id: "invented-thread", title: "Recorded source", event_id: "invented-event", event_version: "v1" }]);
    for (const row of rows.slice(1)) {
      assert.deepEqual(row.notice_details?.sources, []);
      assert.equal(row.notice_details?.task_title, undefined);
    }
    await (await root.submit({ type: "write", entry: { kind: UserNoticeEntry.kind, data: {
      task_id: null, source_conversation_id: "original-conversation", source_entry_id: "original-entry",
      text: "No task exists", notice_details: { source_conversation_id: "original-conversation", source_entry_id: "original-entry",
        sources: snapshot.sources, task_title: "Unbound task title" },
    } } }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    const noTask = (await history(root, null, app.session)).flatMap(event => event.messages).find(row => row.text === "No task exists");
    assert.equal(noTask?.notice_details?.task_id, undefined);
    assert.equal(noTask?.notice_details?.task_title, undefined);
    console.log("Privacy projection: unknown top-level/body keys removed; conflicting entry/task/conversation bindings use recorded outer IDs only.");
  } finally { await app.close(); await rm(directory, { recursive: true, force: true }); }
});

/** The built Rust consumer and production bridge read actual publisher state.
 * Isolated HOME/PATH, no accounts, no auth, no model or worker admission. */
async function retainedNativeHistory(directory: string): Promise<HistoryMessage[]> {
  const bin = join(directory, "bin");
  await mkdir(bin); await symlink(process.execPath, join(bin, "node"));
  const config = join(directory, "config.toml"), instructions = join(directory, "AGENTS.md");
  await writeFile(config, 'node_name = "notice-fixture"\njob_directories = []\n');
  await writeFile(instructions, "Read invented retained evidence only.\n");
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/beep-boop", import.meta.url));
  const runtime = fileURLToPath(new URL("../src/bridge.js", import.meta.url));
  const child = spawn(binary, ["--state-dir", directory, "--config", config, "--runtime", runtime,
    "--instructions", instructions, "serve", "--local-only", "--no-sources"], {
    cwd: directory, stdio: ["ignore", "pipe", "pipe"],
    env: { PATH: bin, HOME: directory, TMPDIR: directory,
      XDG_CONFIG_HOME: join(directory, "config"), XDG_DATA_HOME: join(directory, "data"),
      AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC },
  });
  let errors = ""; child.stdout.resume();
  child.stderr.setEncoding("utf8").on("data", (part: string) => { errors += part; });
  const closed = new Promise<number | null>((resolve, reject) => {
    child.once("close", resolve); child.once("error", reject);
  });
  void closed.catch(() => {});
  const deadline = Date.now() + 15_000;
  try {
    for (;;) {
      assert.equal(child.exitCode, null, errors);
      assert.ok(Date.now() < deadline, "The isolated coordinator did not answer native history: " + errors);
      const channel = createConnection({ path: join(directory, "agent.sock") });
      channel.setTimeout(10_000, () => channel.destroy(new Error("Native history timed out")));
      try {
        channel.write(JSON.stringify({ type: "native", request: { type: "history", cursor: null } }) + "\n");
        const rows: HistoryMessage[] = [];
        for await (const line of protocolLines(channel)) {
          const event = JSON.parse(line) as NativeEvent;
          assert.notEqual(event.type, "error", JSON.stringify(event));
          if (event.type === "history") rows.push(...event.messages);
          if (event.type === "done") {
            console.log("Built Rust coordinator + production bridge native endpoint: retained producer metadata matched.");
            return rows;
          }
        }
        assert.fail("Native history closed without its done frame: " + errors);
      } catch (error) {
        if (!(error instanceof Error && "code" in error && ["ENOENT", "ECONNREFUSED"].includes(String(error.code)))) throw error;
        await new Promise(resolve => setTimeout(resolve, 10));
      } finally { channel.destroy(); }
    }
  } finally {
    child.kill("SIGINT");
    const code = await closed;
    assert.equal(code, 0, errors);
  }
}
