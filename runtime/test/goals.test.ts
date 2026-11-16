import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type JsonObject, type Message } from "@earendil-works/pi-ai";
import { createRegistry, GenerationTask, Harness, ROOT_CONVERSATION_ID, type Conversation } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { CoordinatorEnvironment } from "../src/environment.js";
import type { Goal } from "../src/generated/Goal.js";
import type { GoalAction } from "../src/generated/GoalAction.js";
import type { GoalStatus } from "../src/generated/GoalStatus.js";
import type { GoalTarget } from "../src/generated/GoalTarget.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { createGoalTools, GoalStore, GoalVerificationEntry } from "../src/goals.js";
import { ConversationModels } from "../src/models.js";
import { SourceJournal } from "../src/sources.js";
import { TaskStore, type WorkerSession } from "../src/tasks.js";
import { createAppTools, Executions } from "../src/tools.js";
import { fixtureModel } from "./model.js";

type RunTask = Extract<RuntimeCommand, { type: "run_task" }>;
type Step = AssistantMessage;

const nodeId = "11111111-1111-4111-8111-111111111111";
const cwd = "/workspace/example";
const notes = `${cwd}/notes.md`;
const binding: WorkerRef = { host_id: nodeId, session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333", block_id: "block:44444444-4444-4444-8444-444444444444" };
const workerHost: WorkerHost = { host_id: nodeId, name: "fixture", rex_server: null, coordinator: null, cwd, agent_program: "/example/agent" };
const show: GoalAction = { type: "show" };
const MAIN: GoalTarget = { type: "main" };
const doneCheck = { type: "file_contains", path: "notes.md", text: "GOAL-DONE" } as const;

function sha256(text: string): string { return createHash("sha256").update(text).digest("hex"); }
function inTask(taskId: string): GoalTarget { return { type: "task", task_id: taskId, agent_id: null }; }
function goalOf(status: GoalStatus): Goal {
  if (status.goal === null) throw new Error("The fixture expected a goal");
  return status.goal.goal;
}
function call(name: string, args: JsonObject, id: string): Step {
  return fauxAssistantMessage(fauxToolCall(name, args, { id }), { stopReason: "toolUse" });
}
function said(message: Message): string {
  if (typeof message.content === "string") return message.content;
  return message.content.map((part) => part.type === "text" ? part.text : "").join("");
}
async function until(predicate: () => Promise<boolean>): Promise<void> {
  const deadline = Date.now() + 5_000;
  while (!await predicate()) {
    if (Date.now() > deadline) throw new Error("The fixture condition did not arrive");
    await new Promise<void>((resolve) => setTimeout(resolve, 5));
  }
}

class FixtureHost {
  readonly files = new Map<string, string>();
  readonly calls: HostCommand[] = [];
  private readonly gates = new Map<HostCommand["type"], { entered(): void; released: Promise<void> }>();
  hold(type: HostCommand["type"]): { entered: Promise<void>; release(): void } {
    let entered = () => {}, release = () => {};
    const started = new Promise<void>((resolve) => { entered = resolve; });
    const released = new Promise<void>((resolve) => { release = resolve; });
    this.gates.set(type, { entered, released });
    return { entered: started, release };
  }
  count(type: HostCommand["type"]): number { return this.calls.filter((command) => command.type === type).length; }
  readonly call = async (command: HostCommand): Promise<HostResult> => {
    if (command.type === "on_node") return this.call(command.command);
    this.calls.push(command);
    const gate = this.gates.get(command.type);
    if (gate !== undefined) { this.gates.delete(command.type); gate.entered(); await gate.released; }
    switch (command.type) {
      case "read_file": {
        const content = this.files.get(command.path);
        return content === undefined ? { type: "failed", message: "No such file" }
          : { type: "file", content: content.slice(command.offset, command.offset + command.limit), truncated: false };
      }
      case "write_file": this.files.set(command.path, command.content); return { type: "written" };
      case "exec": return { type: "process", exit_code: 0, stdout: "", stderr: "", truncated: false };
      case "spawn_worker": return { type: "spawned", binding };
      case "resume_worker": return { type: "written" };
      case "inspect_worker": return { type: "worker_presence", presence: { state: "present", running: false } };
      default: throw new Error(`The fixture host does not run ${command.type}`);
    }
  };
}

async function open(directory: string, host: FixtureHost, budget: number | undefined) {
  const database = await openNodeSqliteDatabase(join(directory, "session.sqlite"));
  await database.exec("PRAGMA synchronous = FULL");
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  const models = createModels(); models.setProvider(faux.provider);
  const registry = createRegistry();
  const session = await Harness.open(await SqliteStorage.open(database), { models, registry, identity: { attribution: null },
    settings: { retry: { enabled: false }, steeringMode: "all", followUpMode: "one-at-a-time" } }, BACKGROUND_CONTEXT);
  const tasks = new TaskStore(session, new ConversationModels(models));
  const environment = new CoordinatorEnvironment(session); tasks.useEnvironment(environment);
  await environment.configure({ node: { host_id: nodeId, name: "fixture", rex_server: null, coordinator: null, agent_program: "/example/agent",
    home_directory: cwd, launch: { state_dir: null, runtime: null, config: null, instructions: null, model: fixtureModel } },
  settings: { model: fixtureModel, instructions: "Fixture guidance", context_repositories: [], sources: [] } });
  environment.setConnected([nodeId]);
  const executions = new Executions();
  const sources = new SourceJournal(session, tasks);
  const tools = createAppTools(tasks, executions);
  const stops: string[] = [];
  const goals = new GoalStore(session, tasks, environment, async (taskId, run) => {
    stops.push(taskId); await session.abortTask(run, BACKGROUND_CONTEXT);
  }, budget);
  const goalTools = createGoalTools(goals, executions);
  for (const extension of [tools.host, tools.main, tools.worker, goalTools]) registry.install(extension);
  const prompts: string[] = [];
  const app = {
    session, tasks, sources, faux, goals, stops, prompts,
    script(steps: Step[]) {
      faux.setResponses(steps.map((step) => (context: { messages: Message[] }) => {
        const user = context.messages.findLast((message) => message.role === "user");
        prompts.push(user === undefined ? "" : said(user));
        return step;
      }));
    },
    goal(target: GoalTarget, action: GoalAction) { return goals.handle({ type: "goal", target, action }, host.call); },
    async task(title: string, sourced = false) {
      return tasks.create({ title, outcome: title, model: fixtureModel,
        ...(sourced ? { sources: [{ provider: "scheduled_jobs", account: "local", thread_id: "fixture-job" }] } : {}) });
    },
    async command(taskId: string, interactive = false): Promise<RunTask> {
      const task = await tasks.get(taskId);
      if (task.worker.state !== "bound") throw new Error("The fixture task has no bound worker");
      return { type: "run_task", task_id: taskId, allocation_id: task.worker.allocation_id, binding: task.worker.binding,
        instructions: "", model: fixtureModel, cwd, ...(interactive ? { interactive } : {}) };
    },
    run(command: RunTask, observer?: WorkerSession) {
      return tasks.run(command, (conversation, chosen) => executions.bind(conversation.id.toString(), {
        cwd: chosen.cwd, hosts: [chosen], default_host: chosen, role: "worker", call: host.call,
      }), [tools.host, tools.worker, goalTools], host.call, undefined, observer);
    },
    async conversation(taskId: string): Promise<Conversation> { return tasks.conversation((await tasks.get(taskId)).conversation_id); },
    async submission(taskId: string, requestId: string) {
      const conversation = await app.conversation(taskId);
      return session.commit((tx) => tx.submissionByRequest(conversation.id, requestId), BACKGROUND_CONTEXT);
    },
    async toolText(conversation: Conversation, callId: string): Promise<string> {
      const message = (await conversation.context(BACKGROUND_CONTEXT)).messages
        .find((candidate) => candidate.role === "toolResult" && candidate.toolCallId === callId);
      if (message === undefined) throw new Error(`No result for ${callId}`);
      return said(message);
    },
    async verifications(taskId: string) {
      const conversation = await app.conversation(taskId);
      return (await conversation.entries({ order: "ascending" }, 500, undefined, BACKGROUND_CONTEXT)).items
        .filter((entry) => GoalVerificationEntry.is(entry))
        .map((entry) => ({ id: entry.id.toString(), activation: entry.data.activation, result: entry.data.result.type }));
    },
    async resolvedOutcomes(taskId: string) {
      return (await sources.events({ provider: "task_outcomes", thread_id: taskId }))
        .filter((event) => event.outcome?.state.state === "resolved");
    },
    async abortMarked(conversation: Conversation): Promise<boolean> {
      return (await session.inspect(BACKGROUND_CONTEXT)).tasks.some((task) => task.record.conversationId === conversation.id &&
        task.record.kind === GenerationTask.definition.name && task.record.abortRequested);
    },
    async mainTurn(content: string, steps: Step[]) {
      const root = await session.root(BACKGROUND_CONTEXT);
      await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [tools.host, tools.main] }, BACKGROUND_CONTEXT);
      const unbind = executions.bind(root.id.toString(), { cwd, hosts: [workerHost], call: host.call });
      try {
        app.script(steps);
        const settled = await (await root.submit({ type: "input", content }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
        assert.equal(settled.status, "done");
        return root;
      } finally { unbind(); }
    },
  };
  return app;
}
type App = Awaited<ReturnType<typeof open>>;
type Fixture = { host: FixtureHost; app: App; reopen(): Promise<App> };

async function scenario(budget: number | undefined, body: (fixture: Fixture) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "agent-goal-"));
  const host = new FixtureHost();
  const fixture: Fixture = { host, app: await open(directory, host, budget), async reopen() {
    await fixture.app.session.close(BACKGROUND_CONTEXT);
    fixture.app = await open(directory, host, budget);
    return fixture.app;
  } };
  try { await body(fixture); } finally {
    await fixture.app.session.close(BACKGROUND_CONTEXT);
    await rm(directory, { recursive: true, force: true });
  }
}
function client() {
  const controller = new AbortController();
  const answers: string[] = [], rejected: string[] = [];
  let reachIdle = () => {};
  const idle = new Promise<void>((resolve) => { reachIdle = resolve; });
  const observer: WorkerSession = { signal: controller.signal, async ready() {}, idle: () => reachIdle(),
    answer: (_conversation, text) => { answers.push(text); }, rejected: (inputId) => { rejected.push(inputId); } };
  return { observer, answers, rejected, idle, stop: () => controller.abort() };
}

test("a premature resolution from the worker or from main is refused and recorded on the goal", async () => {
  await scenario(0, async ({ app }) => {
    const task = await app.task("Write the release notes");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-premature", objective: "Write the release notes into notes.md" });
    app.script([
      call("record_task", { summary: "Wrote the notes", state: { state: "resolved", evidence: "I wrote them" } }, "call-worker"),
      fauxAssistantMessage("The task stays open until the goal is verified."),
    ]);
    await app.run(await app.command(task.id));
    assert.match(await app.toolText(await app.conversation(task.id), "call-worker"), /goal is unfinished/);
    assert.equal((await app.tasks.get(task.id)).state.state, "open");
    let rejection = goalOf(await app.goal(inTask(task.id), show)).last_rejection;
    assert.ok(rejection?.type === "premature_resolution");
    assert.equal(rejection.conversation_id, task.conversation_id);
    assert.equal(rejection.tool_call_id, "call-worker");

    const root = await app.mainTurn("Resolve the release notes task.", [
      call("record_task", { task_id: task.id, summary: "Main checked it", state: { state: "resolved", evidence: "Looks done" } }, "call-main"),
      fauxAssistantMessage("The task stays open."),
    ]);
    assert.match(await app.toolText(root, "call-main"), /goal is unfinished/);
    rejection = goalOf(await app.goal(inTask(task.id), show)).last_rejection;
    assert.ok(rejection?.type === "premature_resolution");
    assert.equal(rejection.conversation_id, ROOT_CONVERSATION_ID.toString());
    assert.equal(rejection.tool_call_id, "call-main");
    assert.equal((await app.tasks.get(task.id)).state.state, "open");
    assert.deepEqual(await app.resolvedOutcomes(task.id), []);
  });
});

test("the generic task update cannot resolve a task whose goal is unfinished", async () => {
  await scenario(undefined, async ({ app }) => {
    const goalTask = await app.task("Goal task"), plain = await app.task("Plain task");
    await app.goal(inTask(goalTask.id), { type: "set", request_id: "set-update", objective: "Finish the goal task" });
    const resolve = (id: string) => app.session.commit((tx) => app.tasks.updateIn(tx, id, (task) => {
      task.state = { state: "resolved", evidence: "Checked by hand" };
    }), BACKGROUND_CONTEXT);
    await assert.rejects(resolve(goalTask.id), /goal is unfinished/);
    assert.equal((await app.tasks.get(goalTask.id)).state.state, "open");
    await resolve(plain.id);
    assert.equal((await app.tasks.get(plain.id)).state.state, "resolved");
  });
});

test("complete_goal records a failed check, refuses another check and completes the goal with its resolution", async () => {
  await scenario(undefined, async ({ app }) => {
    const task = await app.task("Finish the notes");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-check", objective: "Write GOAL-DONE into notes.md" });
    app.script([
      call("write_file", { path: "notes.md", content: "draft" }, "write-draft"),
      call("complete_goal", { check: doneCheck, summary: "Drafted the notes" }, "check-failed"),
      call("complete_goal", { check: { ...doneCheck, text: "anything" }, summary: "Try an easier check" }, "check-other"),
      call("write_file", { path: "notes.md", content: "GOAL-DONE\n" }, "write-done"),
      call("complete_goal", { check: doneCheck, summary: "Finished the notes" }, "check-passed"),
    ]);
    await app.run(await app.command(task.id));
    const conversation = await app.conversation(task.id);
    const failed: unknown = JSON.parse(await app.toolText(conversation, "check-failed"));
    assert.deepEqual(failed, { passed: false, check: { ...doneCheck, path: notes },
      failure: { type: "text_missing", observed: { bytes: 5, complete: true, sha256: sha256("draft") } },
      verification_entry_id: (await app.verifications(task.id))[0]?.id, continuations_left: 5 });
    assert.match(await app.toolText(conversation, "check-other"), /already verifies \/workspace\/example\/notes\.md contains "GOAL-DONE"/);
    const passed: unknown = JSON.parse(await app.toolText(conversation, "check-passed"));
    assert.deepEqual(passed, { passed: true, goal: "complete", check: { ...doneCheck, path: notes },
      observed: { bytes: 10, complete: true, sha256: sha256("GOAL-DONE\n") } });
    assert.equal(app.faux.state.callCount, 5, "A verified goal ends the turn without another model request");

    const entries = await app.verifications(task.id);
    assert.deepEqual(entries.map((entry) => [entry.activation, entry.result]), [[1, "failed"], [1, "passed"]]);
    const status = await app.goal(inTask(task.id), show);
    const goal = goalOf(status);
    assert.ok(goal.state.state === "complete");
    assert.equal(goal.state.evidence.entry_id, entries[1]?.id);
    assert.equal(goal.state.evidence.tool_call_id, "check-passed");
    assert.deepEqual(goal.state.evidence.check, { ...doneCheck, path: notes });
    const resolved = status.goal?.task.state;
    assert.ok(resolved?.state === "resolved");
    assert.match(resolved.evidence, new RegExp(`verification entry ${entries[1]?.id}`));
    assert.match(resolved.evidence, new RegExp(sha256("GOAL-DONE\n")));
    const recorded = (await app.resolvedOutcomes(task.id)).filter((event) => event.outcome?.tool_call_id !== null);
    assert.deepEqual(recorded.map((event) => event.outcome?.tool_call_id), ["check-passed"]);
  });
});

test("complete_goal refuses a task without a goal, a paused goal and unfinished agents", async () => {
  await scenario(0, async ({ app, host }) => {
    host.files.set(notes, "GOAL-DONE");
    const plain = await app.task("Plain task");
    await app.tasks.enqueue(plain.id, "Finish the plain task.");
    await app.tasks.dispatch(plain.id, workerHost, host.call);
    app.script([call("complete_goal", { check: doneCheck, summary: "Done" }, "no-goal"), fauxAssistantMessage("No goal here.")]);
    await app.run(await app.command(plain.id));
    assert.match(await app.toolText(await app.conversation(plain.id), "no-goal"), /no unfinished goal/);

    const paused = await app.task("Paused goal task");
    await app.goal(inTask(paused.id), { type: "set", request_id: "set-paused", objective: "Finish the paused task" });
    await app.goal(inTask(paused.id), { type: "pause", request_id: "pause-paused" });
    await app.tasks.enqueue(paused.id, "Try to finish now.");
    app.script([call("complete_goal", { check: doneCheck, summary: "Done" }, "paused-goal"), fauxAssistantMessage("The goal is paused.")]);
    await app.run(await app.command(paused.id));
    assert.match(await app.toolText(await app.conversation(paused.id), "paused-goal"), /goal is paused/);

    const parent = await app.task("Task with an agent");
    await app.goal(inTask(parent.id), { type: "set", request_id: "set-agent", objective: "Finish after the agent" });
    await app.tasks.createAgent(parent.id, { id: "agent-check", title: "Check the notes", outcome: "Report what the notes say",
      input: "Read the notes and report.", inputId: "agent-input" });
    app.script([call("complete_goal", { check: doneCheck, summary: "Done" }, "open-agent"), fauxAssistantMessage("Waiting for the agent.")]);
    await app.run(await app.command(parent.id));
    assert.match(await app.toolText(await app.conversation(parent.id), "open-agent"), /unfinished task agents/);

    for (const task of [plain, paused, parent]) {
      assert.deepEqual(await app.verifications(task.id), []);
      assert.notEqual((await app.tasks.get(task.id)).state.state, "resolved");
    }
    assert.equal(host.count("read_file"), 0, "A refused completion runs no check");
  });
});

test("a check that passes after a pause and resume does not complete the new activation", async () => {
  await scenario(0, async ({ app, host }) => {
    host.files.set(notes, "GOAL-DONE");
    const task = await app.task("Stale proof");
    const target = inTask(task.id);
    await app.goal(target, { type: "set", request_id: "set-stale", objective: "Write GOAL-DONE into notes.md" });
    app.script([call("complete_goal", { check: doneCheck, summary: "Done" }, "stale-check"), fauxAssistantMessage("Resumed the work.")]);
    const read = host.hold("read_file");
    const running = app.run(await app.command(task.id));
    await read.entered;
    await app.goal(target, { type: "pause", request_id: "pause-stale" });
    const resumed = goalOf(await app.goal(target, { type: "resume", request_id: "resume-stale" }));
    assert.equal(resumed.activation.number, 2);
    read.release();
    await running;
    assert.deepEqual(app.stops, [task.id]);
    assert.equal(host.count("read_file"), 1, "The check ran and passed after the activation changed");
    const goal = goalOf(await app.goal(target, show));
    assert.equal(goal.activation.number, 2);
    assert.equal(goal.activation.check, null);
    assert.notEqual(goal.state.state, "complete");
    assert.deepEqual(await app.verifications(task.id), []);
    assert.equal((await app.tasks.get(task.id)).state.state, "open");
    assert.match(app.prompts.at(-1) ?? "", /^Goal resumed \(activation 2\): /);
  });
});

test("main sets its goal in one new task, replays by request ID and keeps it across a restart", async () => {
  await scenario(undefined, async (fixture) => {
    let app = fixture.app;
    const { host } = fixture;
    await assert.rejects(app.goal(MAIN, { type: "set", request_id: "not-a-uuid", objective: "Ship it" }), /non-nil UUID/);
    await assert.rejects(app.goal(MAIN, { type: "set", request_id: "00000000-0000-0000-0000-000000000000", objective: "Ship it" }), /non-nil UUID/);
    assert.deepEqual(await app.tasks.list(), []);

    const request = randomUUID();
    const objective = "Write the fixture summary into notes.md";
    const status = await app.goal(MAIN, { type: "set", request_id: request, objective });
    assert.equal(status.conversation_id, ROOT_CONVERSATION_ID.toString());
    const goal = goalOf(status);
    assert.equal(goal.task_id, request);
    assert.deepEqual(goal.activation, { number: 1, request_id: request, continuations: 0, budget: 5, check: null });
    const task = await app.tasks.get(request);
    assert.equal(task.title, objective); assert.equal(task.outcome, objective);
    assert.deepEqual(task.pending.map((input) => input.id), [`goal:${request}:1:0`]);
    assert.match(task.pending[0]?.content ?? "", /^Goal set with \/goal: Write the fixture summary/);
    const spawned = host.calls.filter((command) => command.type === "spawn_worker");
    assert.equal(spawned.length, 1);
    assert.equal(spawned[0]?.type === "spawn_worker" ? spawned[0].host.host_id : undefined, nodeId);

    const replayed = await app.goal(MAIN, { type: "set", request_id: request, objective });
    assert.deepEqual(goalOf(replayed), goal);
    await assert.rejects(app.goal(MAIN, { type: "set", request_id: randomUUID(), objective: "Another goal" }), /already has an unfinished goal/);
    assert.deepEqual((await app.tasks.list()).map((saved) => saved.id), [request]);
    assert.equal((await app.tasks.get(request)).pending.length, 1);
    assert.equal(host.count("spawn_worker"), 1);

    app = await fixture.reopen();
    assert.deepEqual(goalOf(await app.goal(MAIN, show)), goal);
    assert.deepEqual(goalOf(await app.goal({ type: "conversation", conversation_id: ROOT_CONVERSATION_ID.toString() }, show)), goal);
    assert.deepEqual(goalOf(await app.goal({ type: "conversation", conversation_id: task.conversation_id }, show)), goal);
  });
});

test("a goal is refused for agents, job tasks and conversations without a task", async () => {
  await scenario(undefined, async ({ app }) => {
    const task = await app.task("Parent task");
    const agent = await app.tasks.createAgent(task.id, { id: "agent-goal", title: "Agent", outcome: "Report", input: "Report back.", inputId: "agent-goal-input" });
    const set: GoalAction = { type: "set", request_id: "refused-set", objective: "Do the work" };
    await assert.rejects(app.goal({ type: "task", task_id: task.id, agent_id: agent.id }, set), /An agent reports to its task/);
    await assert.rejects(app.goal({ type: "conversation", conversation_id: agent.conversation_id }, set), /An agent reports to its task/);
    const job = await app.task("Scheduled job task", true);
    await assert.rejects(app.goal(inTask(job.id), set), /scheduled job's task/);
    const taskless = await app.session.createConversation({ ownership: { kind: "ownerless" } }, BACKGROUND_CONTEXT);
    await assert.rejects(app.goal({ type: "conversation", conversation_id: taskless.id.toString() }, set), /no task yet/);
    assert.equal((await app.goal(inTask(task.id), show)).goal, null);
  });
});

test("main shows no goal once its task takes another goal", async () => {
  await scenario(undefined, async ({ app }) => {
    const request = randomUUID();
    await app.goal(MAIN, { type: "set", request_id: request, objective: "Write GOAL-DONE into notes.md" });
    app.script([
      call("write_file", { path: "notes.md", content: "GOAL-DONE\n" }, "write-main"),
      call("complete_goal", { check: doneCheck, summary: "Wrote the notes" }, "check-main"),
    ]);
    await app.run(await app.command(request));
    const completed = goalOf(await app.goal(MAIN, show));
    assert.equal(completed.id, request);
    assert.equal(completed.state.state, "complete");
    assert.equal((await app.tasks.get(request)).state.state, "resolved");

    const next = goalOf(await app.goal(inTask(request), { type: "set", request_id: "task-next", objective: "Review the notes" }));
    assert.equal(next.id, "task-next");
    assert.equal((await app.tasks.get(request)).state.state, "open");
    assert.deepEqual(await app.goal(MAIN, show), { conversation_id: ROOT_CONVERSATION_ID.toString(), goal: null });
    assert.equal(goalOf(await app.goal(inTask(request), show)).id, "task-next");
  });
});

test("pause withdraws only goal inputs, survives a restart and ignores replayed controls", async () => {
  await scenario(undefined, async (fixture) => {
    let app = fixture.app;
    const task = await app.task("Pause task");
    const target = inTask(task.id);
    await app.goal(target, { type: "set", request_id: "set-pause", objective: "Keep the notes current" });
    await app.tasks.enqueue(task.id, "Answer the unrelated question.", "u1");
    const paused = await app.goal(target, { type: "pause", request_id: "p0" });
    assert.deepEqual(goalOf(paused).state, { state: "paused", reason: "requested" });
    assert.deepEqual((await app.tasks.get(task.id)).pending.map((input) => input.id), ["u1"]);
    const receipt = await app.submission(task.id, "goal:set-pause:1:0");
    assert.ok(receipt?.status === "unanswered" && receipt.reason === "aborted");
    assert.deepEqual(goalOf(await app.goal(target, { type: "pause", request_id: "p0" })), goalOf(paused));

    app = await fixture.reopen();
    assert.deepEqual(goalOf(await app.goal(target, show)).state, { state: "paused", reason: "requested" });
    app.script([fauxAssistantMessage("Answered the unrelated question.")]);
    const result = await app.run(await app.command(task.id));
    assert.equal(result.text, "Answered the unrelated question.");
    assert.deepEqual(app.prompts, ["Answer the unrelated question."]);
    assert.equal(await app.submission(task.id, "goal:set-pause:1:1"), undefined);

    const r1 = goalOf(await app.goal(target, { type: "resume", request_id: "r1" }));
    assert.equal(r1.activation.number, 2);
    assert.deepEqual((await app.tasks.get(task.id)).pending.map((input) => input.id), ["goal:set-pause:2:0"]);
    await app.goal(target, { type: "pause", request_id: "p1" });
    const replayedResume = goalOf(await app.goal(target, { type: "resume", request_id: "r1" }));
    assert.deepEqual(replayedResume.state, { state: "paused", reason: "requested" }, "A replayed resume starts no new activation");
    assert.equal(replayedResume.activation.number, 2);
    assert.deepEqual((await app.tasks.get(task.id)).pending, []);

    const r2 = goalOf(await app.goal(target, { type: "resume", request_id: "r2" }));
    assert.equal(r2.activation.number, 3);
    const replayedPause = goalOf(await app.goal(target, { type: "pause", request_id: "p1" }));
    assert.deepEqual(replayedPause, r2, "A replayed pause leaves the resumed goal running");
    assert.deepEqual((await app.tasks.get(task.id)).pending.map((input) => input.id), ["goal:set-pause:3:0"]);
  });
});

async function pauseKeepsQueuedInput(interactive: boolean): Promise<void> {
  await scenario(undefined, async ({ app, host }) => {
    const task = await app.task("Busy goal task");
    const target = inTask(task.id);
    await app.goal(target, { type: "set", request_id: "set-busy", objective: "Build the fixture report" });
    app.script([call("exec", { program: "make", args: ["report"] }, "held-exec"), fauxAssistantMessage("Answered the unrelated follow-up.")]);
    const held = host.hold("exec");
    const watcher = interactive ? client() : undefined;
    const running = app.run(await app.command(task.id, interactive), watcher?.observer);
    await held.entered;
    await app.tasks.enqueue(task.id, "Answer the unrelated follow-up.", "u1", undefined, "follow_up");
    assert.equal((await app.submission(task.id, "u1"))?.status, "queued");
    assert.deepEqual(goalOf(await app.goal(target, { type: "pause", request_id: "pause-busy" })).state, { state: "paused", reason: "requested" });
    assert.deepEqual(app.stops, [task.id]);
    held.release();
    if (watcher !== undefined) { await watcher.idle; watcher.stop(); }
    const result = await running;

    assert.equal(result.text, "Answered the unrelated follow-up.");
    const goalInput = await app.submission(task.id, "goal:set-busy:1:0");
    assert.ok(goalInput?.status === "unanswered" && goalInput.reason === "aborted");
    assert.equal((await app.submission(task.id, "u1"))?.status, "done");
    assert.equal(app.prompts.length, 2);
    assert.match(app.prompts[0] ?? "", /^Goal set with \/goal: Build the fixture report/);
    assert.equal(app.prompts[1], "Answer the unrelated follow-up.");
    assert.equal(await app.submission(task.id, "goal:set-busy:1:1"), undefined);
    assert.deepEqual(goalOf(await app.goal(target, show)).state, { state: "paused", reason: "requested" });
    if (watcher !== undefined) {
      assert.deepEqual(watcher.rejected, []);
      assert.deepEqual(watcher.answers, ["Answered the unrelated follow-up."]);
    }
  });
}
test("pause stops only the goal's turn of a non-interactive actor and its queued input still runs", () => pauseKeepsQueuedInput(false));
test("pause stops only the goal's turn of an interactive worker and its queued input still runs", () => pauseKeepsQueuedInput(true));

test("continuations stop at the budget and exhaustion pauses the goal", async () => {
  await scenario(undefined, async ({ app }) => {
    const task = await app.task("Budget task");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-budget", objective: "Keep refining the notes" });
    app.script(Array.from({ length: 7 }, (_, index) => fauxAssistantMessage(`Progress ${index}.`)));
    await app.run(await app.command(task.id));
    assert.equal(app.faux.state.callCount, 6);
    assert.match(app.prompts[0] ?? "", /^Goal set with \/goal: Keep refining the notes/);
    for (let index = 1; index <= 5; index += 1) {
      assert.match(app.prompts[index] ?? "", new RegExp(`^Goal continuation ${index} of 5 \\(activation 1\\): Keep refining the notes`));
      assert.doesNotMatch(app.prompts[index] ?? "", /Goal set with \/goal:/);
    }
    const goal = goalOf(await app.goal(inTask(task.id), show));
    assert.deepEqual(goal.state, { state: "paused", reason: "budget_exhausted" });
    assert.equal(goal.activation.continuations, 5);
    for (let sequence = 0; sequence <= 5; sequence += 1) {
      assert.equal((await app.submission(task.id, `goal:set-budget:1:${sequence}`))?.status, "done");
    }
    assert.equal(await app.submission(task.id, "goal:set-budget:1:6"), undefined);
  });
});

test("a task waiting on another actor is not continued until new input reopens it", async () => {
  await scenario(1, async ({ app }) => {
    const task = await app.task("Waiting task");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-wait", objective: "Ship after CI passes" });
    app.script([
      call("record_task", { summary: "Waiting for CI", state: { state: "waiting", actor: "ci", next_check: null } }, "wait-ci"),
      fauxAssistantMessage("Waiting for CI."),
    ]);
    await app.run(await app.command(task.id));
    let goal = goalOf(await app.goal(inTask(task.id), show));
    assert.deepEqual(goal.state, { state: "active" });
    assert.equal(goal.activation.continuations, 0);
    assert.equal(app.faux.state.callCount, 2);

    await app.tasks.enqueue(task.id, "CI passed.", "ci-passed");
    app.script([fauxAssistantMessage("Checked the CI result."), fauxAssistantMessage("Still refining.")]);
    await app.run(await app.command(task.id));
    assert.equal(app.prompts.at(-2), "CI passed.");
    assert.match(app.prompts.at(-1) ?? "", /^Goal continuation 1 of 1 \(activation 1\): /);
    goal = goalOf(await app.goal(inTask(task.id), show));
    assert.deepEqual(goal.state, { state: "paused", reason: "budget_exhausted" });
  });
});

test("Esc in a goal turn pauses the goal as interrupted", async () => {
  await scenario(undefined, async ({ app, host }) => {
    const task = await app.task("Interrupted task");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-esc", objective: "Build the fixture report" });
    app.script([call("exec", { program: "make", args: ["report"] }, "esc-exec")]);
    const held = host.hold("exec");
    const watcher = client();
    const running = app.run(await app.command(task.id, true), watcher.observer);
    await held.entered;
    const conversation = await app.conversation(task.id);
    const aborting = conversation.abort(BACKGROUND_CONTEXT);
    await until(() => app.abortMarked(conversation));
    held.release();
    await aborting;
    await watcher.idle;
    watcher.stop();
    await running;
    assert.deepEqual(goalOf(await app.goal(inTask(task.id), show)).state, { state: "paused", reason: "interrupted" });
    assert.equal(app.faux.state.callCount, 1, "No continuation reaches the model after Esc");
    assert.deepEqual((await app.tasks.get(task.id)).pending, []);
  });
});

test("an interrupted goal turn pauses the goal after a restart", async () => {
  await scenario(undefined, async (fixture) => {
    let app = fixture.app;
    const task = await app.task("Interrupted before restart");
    await app.goal(inTask(task.id), { type: "set", request_id: "set-restart", objective: "Build the fixture report" });
    app.script([call("exec", { program: "make", args: ["report"] }, "restart-exec")]);
    const held = fixture.host.hold("exec");
    const running = app.run(await app.command(task.id));
    await held.entered;
    const conversation = await app.conversation(task.id);
    const aborting = conversation.abort(BACKGROUND_CONTEXT);
    await until(() => app.abortMarked(conversation));
    held.release();
    await aborting;
    await assert.rejects(running, /did not complete/);
    assert.deepEqual(goalOf(await app.goal(inTask(task.id), show)).state, { state: "active" });

    app = await fixture.reopen();
    app.script([fauxAssistantMessage("A continuation must not run.")]);
    await app.run(await app.command(task.id));
    assert.equal(app.faux.state.callCount, 0);
    assert.deepEqual(goalOf(await app.goal(inTask(task.id), show)).state, { state: "paused", reason: "interrupted" });
  });
});
