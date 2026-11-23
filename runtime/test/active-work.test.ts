import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer, type ServerHttp2Session, type ServerHttp2Stream } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { AssistantEntry, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { buildActiveWork } from "../src/active-work.js";
import type { ActiveWorkItem } from "../src/generated/ActiveWorkItem.js";
import type { TaskAgentRecord } from "../src/generated/TaskAgentRecord.js";
import type { TaskGraphActor } from "../src/generated/TaskGraphActor.js";
import type { TaskGraphNode } from "../src/generated/TaskGraphNode.js";
import type { TaskGraphSnapshot } from "../src/generated/TaskGraphSnapshot.js";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import { Notifications } from "../src/notifications.js";
import { readTaskGraph } from "../src/task-graph.js";
import { openBridgeHarness } from "./bridge-harness.js";
import { heldCall, host, open, type App } from "./delegation.js";
import { until } from "./fixtures/until.js";
import { fixtureModel } from "./model.js";

test("bridge observe_main with task_graph:true and watch_task_graph emit snapshots and detach cleanly", { timeout: 25_000 }, async (t) => {
  const bridge = await openBridgeHarness(t, {});
  try {
    bridge.send(3, { type: "observe_main", input_ids: [], task_graph: true });
    await bridge.waitFor("observe_main ready and task_graph", () =>
      bridge.frames.some((frame) => frame.id === 3 && frame.event.type === "main_ready")
      && bridge.frames.some((frame) => frame.id === 3 && frame.event.type === "task_graph"));
    bridge.send(3, { type: "detach_main" });
    const observeEvents = await bridge.collect(3);
    assert.ok(observeEvents.some((event) => event.type === "main_ready" && event.active_work === true));
    assert.ok(observeEvents.some((event) => event.type === "task_graph"));

    bridge.send(4, { type: "watch_task_graph" });
    await bridge.waitFor("watch_task_graph snapshot", () => bridge.frames.some((frame) => frame.id === 4 && frame.event.type === "task_graph"));
    bridge.send(4, { type: "detach_task_graph" });
    const watchEvents = await bridge.collect(4);
    assert.ok(watchEvents.some((event) => event.type === "task_graph"));
    assert.equal(watchEvents.at(-1)?.type, "done");
  } finally {
    await bridge.close();
  }
});

const MAIN = ROOT_CONVERSATION_ID.toString();
const actors = new Map<string, TaskGraphActor>([[MAIN, { type: "main" }]]);
const RETRY_AT = Date.UTC(2100, 0, 1);
const streaming: TaskGraphNode["state"] = { status: "running", phase: "request" };

function liveNode(id: number, conversationId: string, kind: TaskGraphNode["kind"], state: TaskGraphNode["state"],
  rest: Partial<TaskGraphNode> = {}): TaskGraphNode {
  return { id, conversation_id: conversationId, owner: null, background: false, abort_requested: false, state, blocked: null,
    conversations: [], kind, started_at: 1000 + id, ...rest };
}
const backgroundNode = (id: number, conversationId: string, name: string, state: TaskGraphNode["state"]) =>
  liveNode(id, conversationId, { type: "other", name }, state, { background: true });
const turnNode = (id: number, conversationId: string, state: TaskGraphNode["state"] = streaming) => liveNode(id, conversationId, { type: "generation" }, state);
const sleepingPushSender = backgroundNode(21, MAIN, "agent.notifications", { status: "sleeping", phase: "deliver", until: RETRY_AT });
const shown = (work: readonly ActiveWorkItem[]) => work.map((item) => [item.title, item.status, item.started_at]);

function taskRecord(id: string, conversationId: string, title: string, rest: Partial<TaskRecord> = {}): TaskRecord {
  return { id, conversation_id: conversationId, title, outcome: "Finish the invented work", summary: "", model: null, state: { state: "open" },
    worker: { state: "unassigned" }, sources: [], pending: [], agents: [], started_at: 900, updated_at: 900, ...rest };
}

const backgroundNodesOfMain: Array<[string, TaskGraphNode]> = [
  ["the push sender while it sends", backgroundNode(21, MAIN, "agent.notifications", { status: "running", phase: "deliver" })],
  ["the push sender asleep until its retry", sleepingPushSender],
  ["the placement of a held notice", backgroundNode(21, MAIN, "agent.notice_context.place", { status: "running", phase: "place" })],
  ["the scheduler", backgroundNode(21, MAIN, "agent.background", { status: "running", phase: "execute" })],
  ["a compaction that outlives its turn", backgroundNode(21, MAIN, "pi.compaction", { status: "running", phase: "summarize" })],
];
for (const [label, node] of backgroundNodesOfMain) {
  test(`${label} alone in the main conversation gives no active work row`, () => {
    assert.deepEqual(buildActiveWork([node], [], actors), []);
  });
}

const turnsOfMain: Array<[string, TaskGraphNode[], ActiveWorkItem["status"]]> = [
  ["streams", [turnNode(30, MAIN)], "running"],
  ["calls a tool", [turnNode(30, MAIN, { status: "waiting", phase: "tools", on: [31], policy: "all_settled" }),
    liveNode(31, MAIN, { type: "tool", name: "exec" }, { status: "running", phase: "run" }, { owner: 30 })], "running"],
  ["waits for a compaction it needs", [turnNode(30, MAIN, { status: "waiting", phase: "prepare", on: [31], policy: "all_settled" }),
    liveNode(31, MAIN, { type: "other", name: "pi.compaction" }, { status: "running", phase: "summarize" }, { owner: 30 })], "running"],
  ["sleeps until it retries the model", [turnNode(30, MAIN, { status: "sleeping", phase: "retry", until: RETRY_AT })], "waiting_external"],
];
for (const [label, turn, status] of turnsOfMain) {
  test(`a turn of the main chat that ${label} gives the Main row, timed from the turn and not from an older push sender`, () => {
    assert.deepEqual(shown(buildActiveWork([sleepingPushSender, ...turn], [], actors)), [["Main", status, 1030]]);
  });
}

test("a node of the main conversation that is not a background node gives the Main row, whatever its kind", () => {
  const manualCompaction = liveNode(30, MAIN, { type: "other", name: "pi.compaction" }, { status: "running", phase: "summarize" });
  assert.deepEqual(shown(buildActiveWork([sleepingPushSender, manualCompaction], [], actors)), [["Main", "running", 1030]]);
});

test("a background compaction in the conversation of a task that waits for the owner leaves the task waiting", () => {
  const task = taskRecord("task-fee", "40", "Fee approval",
    { summary: "Approve the invented fee?", state: { state: "waiting", actor: "Owner", next_check: null, target: "owner" } });
  const work = buildActiveWork([backgroundNode(41, "40", "pi.compaction", { status: "running", phase: "summarize" })], [task], actors);
  assert.deepEqual(shown(work), [["Fee approval", "waiting_owner", 900]]);
});

test("a job's turn beside an older background compaction and the scheduler gives one row, the job, timed from the turn", () => {
  const job = taskRecord("task-count", "50", "Nightly count", { sources: [{ provider: "scheduled_jobs", account: "local", thread_id: "nightly-count" }] });
  const work = buildActiveWork([
    backgroundNode(11, MAIN, "agent.background", { status: "running", phase: "execute" }),
    backgroundNode(51, "50", "pi.compaction", { status: "sleeping", phase: "retry", until: RETRY_AT }),
    turnNode(52, "50"),
  ], [job], actors);
  assert.deepEqual(work.map((item) => [item.title, item.status, item.is_job, item.started_at]), [["Nightly count", "running", true, 1052]]);
});

test("a background compaction alone gives no row for a child agent, its idle task or a conversation of no task", () => {
  const agent: TaskAgentRecord = { id: "review", conversation_id: "71", title: "Review", outcome: "Review the invented change", summary: "",
    model: null, state: { state: "open" }, worker: { state: "unassigned" }, pending: [], updated_at: 900 };
  const work = buildActiveWork([
    backgroundNode(72, "71", "pi.compaction", { status: "running", phase: "summarize" }),
    backgroundNode(81, "80", "pi.compaction", { status: "running", phase: "summarize" }),
  ], [taskRecord("task-board", "70", "Board review", { agents: [agent] })], actors);
  assert.deepEqual(work, []);
});

const pushSender = (graph: TaskGraphSnapshot, status: TaskGraphNode["state"]["status"]) => graph.nodes.find((node) =>
  node.kind.type === "other" && node.kind.name === "agent.notifications" && node.state.status === status);
const mainTurn = (graph: TaskGraphSnapshot) => graph.nodes.find((node) => node.kind.type === "generation" && node.conversation_id === MAIN);
async function graphWhen(app: App, reached: (graph: TaskGraphSnapshot) => boolean, message: string): Promise<TaskGraphSnapshot> {
  let graph = await readTaskGraph(app.tasks);
  await until(async () => reached(graph = await readTaskGraph(app.tasks)), message);
  return graph;
}

test("the push sender makes no active work row while it sends or sleeps, and the Main row lasts as long as the turn", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-active-work-push-")); await chmod(directory, 0o700);
  const key = join(directory, "AuthKey.p8");
  await writeFile(key, generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  const server = createServer(), sessions = new Set<ServerHttp2Session>(), pushes: ServerHttp2Stream[] = [];
  server.on("session", (session) => { sessions.add(session); session.on("error", () => {}); session.once("close", () => sessions.delete(session)); });
  server.on("stream", (stream: ServerHttp2Stream) => { stream.on("error", () => {}); stream.resume(); stream.once("end", () => pushes.push(stream)); });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address(); assert.ok(address !== null && typeof address === "object");
  const answer = (push: ServerHttp2Stream | undefined, status: number) => { assert.ok(push); push.respond({ ":status": status }); push.end(); };
  const app = await open(directory);
  const notifications = new Notifications(app.session, app.registry, { team_id: "TEAM000001", key_id: "KEY0000001", topic: "dev.example.Agent",
    key_file: key, environment: "sandbox" }, `http://127.0.0.1:${address.port}`);
  let releaseMain = () => {};
  try {
    const root = await app.session.root(BACKGROUND_CONTEXT);
    releaseMain = app.executions.bind(root.id.toString(), { model: fixtureModel, cwd: host.cwd, hosts: [], call: async () => ({ type: "written" }) });
    await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [app.tools.main] }, BACKGROUND_CONTEXT);
    assert.equal(await notifications.start(), true);
    await notifications.request({ type: "register", installation_id: "11111111-1111-4111-8111-111111111111", token: "01ab".repeat(24) });
    await app.session.commit((tx) => tx.appendEntry(ROOT_CONVERSATION_ID, { kind: AssistantEntry.kind, model: [fauxAssistantMessage("An invented reply")] }), BACKGROUND_CONTEXT);
    app.session.resume();

    const sending = await graphWhen(app, (graph) => pushes.length === 1 && pushSender(graph, "running") !== undefined, "The push sender must send the reply");
    assert.deepEqual(sending.work, [], "A push in flight is not work of the main chat");

    answer(pushes[0], 503);
    const asleep = await graphWhen(app, (graph) => pushSender(graph, "sleeping") !== undefined, "The push sender must sleep until its retry");
    assert.deepEqual(asleep.work, [], "A push that waits for its retry is not work of the main chat");

    const held = heldCall("An invented answer"); app.faux.setResponses([held.step]);
    const submission = await root.submit({ type: "input", content: "Count the invented stock." }, BACKGROUND_CONTEXT);
    await held.started;
    const during = await graphWhen(app, (graph) => mainTurn(graph)?.started_at !== undefined, "The turn of the main chat must be live");
    const sender = pushSender(during, "sleeping"), turn = mainTurn(during);
    assert.ok(sender?.started_at !== undefined && turn?.started_at !== undefined && sender.started_at < turn.started_at,
      "The sleeping push sender must be older than the turn");
    assert.deepEqual(shown(during.work), [["Main", "running", turn.started_at]]);

    held.release();
    assert.equal((await submission.wait(BACKGROUND_CONTEXT)).status, "done");
    const after = await graphWhen(app, (graph) => pushes.length === 2 && pushSender(graph, "running") !== undefined && mainTurn(graph) === undefined,
      "The answer of the turn must be pushed");
    assert.deepEqual(after.work, [], "The Main row must leave with the turn while the push of its answer is in flight");
    answer(pushes[1], 200);
  } finally {
    releaseMain(); notifications.close(); await app.session.close(BACKGROUND_CONTEXT);
    for (const session of sessions) session.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(directory, { recursive: true, force: true });
  }
});
