import assert from "node:assert/strict";
import { appendFile, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { ConversationModels } from "../src/models.js";
import { TaskStore } from "../src/tasks.js";
import { createAppTools, Executions } from "../src/tools.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { sessions } from "./fixtures/coordinator-native.js";
import { coordinatorWorld, delegate, type OwnedProcess } from "./fixtures/coordinator-world.js";
import { fixtureModel } from "./model.js";

type RunTask = Extract<RuntimeCommand, { type: "run_task" }>;
type App = Awaited<ReturnType<typeof open>>;
type World = Awaited<ReturnType<typeof coordinatorWorld>>;

const GRACE_MS = 600;
const host: WorkerHost = { host_id: null, name: "fixture", rex_server: null, coordinator: null,
  cwd: "/workspace/example", agent_program: "/example/agent" };
const binding: WorkerRef = {
  host_id: "11111111-1111-4111-8111-111111111111",
  session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333",
  block_id: "block:44444444-4444-4444-8444-444444444444",
};
const resolveTask = (summary: string) => fauxAssistantMessage(fauxToolCall("record_task",
  { summary, state: { state: "resolved", evidence: "The fixture audit passed." } }), { stopReason: "toolUse" });

async function open(directory: string) {
  const storage = await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite")));
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  const models = createModels(); models.setProvider(faux.provider);
  const registry = createRegistry();
  const session = await Harness.open(storage, { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const tasks = new TaskStore(session, new ConversationModels(models));
  tasks.useObserverReleaseAfter(GRACE_MS);
  const executions = new Executions();
  const tools = createAppTools(tasks, executions);
  registry.install(tools.host); registry.install(tools.main); registry.install(tools.worker); registry.install(tools.agent);
  return { session, tasks, executions, tools, faux };
}
async function withApp(body: (app: App) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "agent-observer-release-"));
  const app = await open(directory);
  try { await body(app); } finally {
    await app.tasks.detachActors(); await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true });
  }
}
async function boundTask(app: App, input: string): Promise<RunTask> {
  const task = await app.tasks.create({ title: "Release audit", outcome: "Finish the audit" });
  await app.tasks.enqueue(task.id, input);
  await app.tasks.dispatch(task.id, host, async () => ({ type: "spawned", binding }));
  const saved = await app.tasks.get(task.id); assert.ok(saved.worker.state === "bound");
  return { type: "run_task", task_id: task.id, allocation_id: saved.worker.allocation_id, binding, instructions: "", model: fixtureModel,
    cwd: host.cwd, interactive: true };
}
function attach(app: App, command: RunTask) {
  const idles: number[] = [];
  let seen = () => {};
  const run = app.tasks.run(command, (conversation) => app.executions.bind(conversation.id.toString(), {
    cwd: host.cwd, hosts: [host], call: async () => { throw new Error("No host effects expected"); },
  }), [app.tools.host, command.agent_id === undefined ? app.tools.worker : app.tools.agent], undefined, undefined, {
    signal: new AbortController().signal, async ready() {}, answer() {}, idle() { idles.push(Date.now()); seen(); },
  });
  return {
    ended: run.then(() => Date.now()),
    async idle(count: number): Promise<number> {
      while (idles.length < count) await new Promise<void>((resolve) => { seen = resolve; });
      return idles[count - 1]!;
    },
  };
}
const within = (ended: Promise<number>, ms: number) => Promise.race([ended, sleep(ms, undefined)]);

test("a terminal stays with unfinished work and is released once the grace after its task resolved has passed", { timeout: 20_000 }, async () => {
  await withApp(async (app) => {
    const command = await boundTask(app, "Start the audit");
    app.faux.setResponses([fauxAssistantMessage("The audit is still running."), resolveTask("Audit passed."), fauxAssistantMessage("Audit finished.")]);
    const terminal = attach(app, command);
    await terminal.idle(1);
    assert.equal((await app.tasks.get(command.task_id)).state.state, "open");
    assert.equal(await within(terminal.ended, GRACE_MS * 2), undefined, "A terminal on unfinished work is never released");
    await app.tasks.enqueue(command.task_id, "Finish the audit");
    const finished = await terminal.idle(2);
    assert.equal((await app.tasks.get(command.task_id)).state.state, "resolved");
    const ended = await within(terminal.ended, GRACE_MS * 10);
    assert.ok(ended !== undefined, "The terminal of a resolved task must be released");
    assert.ok(ended - finished >= GRACE_MS, `The terminal left ${ended - finished} ms after the task resolved, before its grace`);
  });
});

test("input before the deadline cancels every pending release, and the next finish starts a new grace", { timeout: 20_000 }, async () => {
  await withApp(async (app) => {
    const command = await boundTask(app, "Start the audit");
    app.faux.setResponses([resolveTask("First pass."), fauxAssistantMessage("First pass finished."),
      resolveTask("Second pass."), fauxAssistantMessage("Second pass finished.")]);
    const first = attach(app, command);
    await first.idle(1);
    const second = attach(app, command);
    await second.idle(1);
    await sleep(GRACE_MS / 4);
    await app.tasks.enqueue(command.task_id, "Check the audit once more");
    const finished = await first.idle(2);
    for (const terminal of [first, second]) {
      const ended = await within(terminal.ended, GRACE_MS * 10);
      assert.ok(ended !== undefined, "Each terminal must be released after the second finish");
      assert.ok(ended - finished >= GRACE_MS, `A terminal left ${ended - finished} ms after the second finish, at a cancelled deadline`);
    }
  });
});

test("a terminal that attaches to finished work gets the whole grace from when it attached", { timeout: 20_000 }, async () => {
  await withApp(async (app) => {
    const command = await boundTask(app, "Start the audit");
    app.faux.setResponses([resolveTask("Audit passed."), fauxAssistantMessage("Audit finished.")]);
    const first = attach(app, command);
    const finished = await first.idle(1);
    await sleep(GRACE_MS / 2);
    const attaching = Date.now();
    const late = attach(app, command);
    const firstEnded = await within(first.ended, GRACE_MS * 10), lateEnded = await within(late.ended, GRACE_MS * 10);
    assert.ok(firstEnded !== undefined && lateEnded !== undefined, "Both terminals must be released");
    assert.ok(firstEnded - finished >= GRACE_MS && firstEnded <= lateEnded, "The first terminal keeps its own deadline");
    assert.ok(lateEnded - attaching >= GRACE_MS, `The late terminal left ${lateEnded - attaching} ms after it attached`);
  });
});

test("a terminal attached to a finished agent is released once the grace has passed", { timeout: 20_000 }, async () => {
  await withApp(async (app) => {
    const task = await app.tasks.create({ title: "Parent", outcome: "Complete after review" });
    await app.tasks.dispatch(task.id, host, async () => ({ type: "spawned", binding }));
    const child = await app.tasks.createAgent(task.id, { id: "review", title: "Review", outcome: "Review the change",
      input: "Review the change", inputId: "review-input", model: fixtureModel });
    const childBinding = { ...binding, block_id: "block:55555555-5555-4555-8555-555555555555" };
    await app.tasks.dispatchAgent(task.id, child.id, async () => ({ type: "spawned", binding: childBinding }));
    const agent = (await app.tasks.get(task.id)).agents[0]; assert.ok(agent?.worker.state === "bound");
    app.faux.setResponses([fauxAssistantMessage(fauxToolCall("report_result", { summary: "Review passed" }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Review complete.")]);
    const terminal = attach(app, { type: "run_task", task_id: task.id, agent_id: child.id, allocation_id: agent.worker.allocation_id,
      binding: childBinding, instructions: "", model: fixtureModel, cwd: host.cwd, interactive: true });
    const finished = await terminal.idle(1);
    assert.equal((await app.tasks.get(task.id)).agents[0]?.state.state, "done");
    const ended = await within(terminal.ended, GRACE_MS * 10);
    assert.ok(ended !== undefined, "The terminal of a finished agent must be released");
    assert.ok(ended - finished >= GRACE_MS, `The terminal left ${ended - finished} ms after the agent finished, before its grace`);
  });
});

test("a report that finishes an idle agent releases its terminal once the grace has passed", { timeout: 20_000 }, async () => {
  await withApp(async (app) => {
    const task = await app.tasks.create({ title: "Parent", outcome: "Complete after review" });
    await app.tasks.dispatch(task.id, host, async () => ({ type: "spawned", binding }));
    const child = await app.tasks.createAgent(task.id, { id: "review", title: "Review", outcome: "Review the change",
      input: "Review the change", inputId: "review-input", model: fixtureModel });
    const childBinding = { ...binding, block_id: "block:55555555-5555-4555-8555-555555555555" };
    await app.tasks.dispatchAgent(task.id, child.id, async () => ({ type: "spawned", binding: childBinding }));
    await app.session.commit((tx) => app.tasks.withdrawIn(tx, task.id, child.id, () => true), BACKGROUND_CONTEXT);
    const agent = (await app.tasks.get(task.id)).agents[0]; assert.ok(agent?.worker.state === "bound");
    const terminal = attach(app, { type: "run_task", task_id: task.id, agent_id: child.id, allocation_id: agent.worker.allocation_id,
      binding: childBinding, instructions: "", model: fixtureModel, cwd: host.cwd, interactive: true });
    await terminal.idle(1);
    assert.equal(await within(terminal.ended, GRACE_MS * 2), undefined, "A terminal on an open agent is never released");
    const reported = Date.now();
    await app.tasks.reportAgent(task.id, child.id, "Review passed");
    const ended = await within(terminal.ended, GRACE_MS * 10);
    assert.ok(ended !== undefined, "The terminal of an agent that a report finished must be released");
    assert.ok(ended - reported >= GRACE_MS, `The terminal left ${ended - reported} ms after the report, before its grace`);
  });
});

const RELEASE_SECONDS = 2;
/** A real task terminal in a pseudo-terminal, attached to a task that resolves once `finish` runs. */
async function taskTerminal(t: TestContext, name: string) {
  const world = await coordinatorWorld(t, async ([desktop]) => {
    await appendFile(join(desktop, "agent.toml"), `observer_release_after_seconds = ${RELEASE_SECONDS}\n`);
  });
  const { directory, homes, script, cli, tasks, start, until } = world;
  const title = `${name} audit`, gate = join(directory, "release-gate"), main = `fixture-${name.toLowerCase().replaceAll(" ", "-")}-main`;
  await script(main, [delegate(title), { text: `Delegated the ${title}.` }]);
  await script(title, [{ tool: "record_task", args: { summary: "Audited.", state: { state: "resolved", evidence: "The synthetic audit passed." } } },
    { text: `${title} finished.`, after: gate }]);
  await cli(0, ["chat", `${main}: delegate the ${title}.`]);
  const task = (await tasks()).find((item) => item.title === title); assert.ok(task?.worker.state === "bound");
  const blockId = task.worker.binding.block_id;
  const launch = sessions(join(homes[0], "rex.json")).find((session) => session.block_id === blockId); assert.ok(launch);
  const recoveries = join(homes[0], "state", "recovery"), pidFile = join(directory, "terminal-pid");
  return {
    ...world, task, worker: task.worker, recoveries,
    attach: async (...flags: string[]) => {
      const terminal = start(0, [...flags, ...launch.command.slice(1)], undefined,
        { REX_SESSION: launch.session_id, REX_BLOCK: launch.block_id, AGENT_TEST_TERMINAL_PID: pidFile }, true, true);
      await until(async () => terminal.output().includes(title), "The task terminal must attach to its task");
      return terminal;
    },
    /** The run-task process inside the pseudo-terminal. `terminal.child` is the driver that owns the pseudo-terminal. */
    runTaskPid: async () => Number(await readFile(pidFile, "utf8")),
    finish: () => writeFile(gate, "Finish the audit."),
    saved: async () => Promise.all((await readdir(recoveries)).filter((name) => name.startsWith("tui-draft-")).map(async (name) =>
      ({ path: join(recoveries, name), recovery: JSON.parse(await readFile(join(recoveries, name), "utf8")) as unknown }))),
  };
}
/** The interface draws a typed line one cell at a time, so the text never appears whole in the output. */
async function type(terminal: OwnedProcess, text: string): Promise<void> {
  terminal.child.stdin.write(text);
  for (let drawn = -1; drawn !== terminal.output().length;) { drawn = terminal.output().length; await sleep(300); }
}
async function showMain(terminal: OwnedProcess, until: World["until"]): Promise<void> {
  terminal.child.stdin.write("/main\r");
  await until(async () => terminal.output().includes("Main agent"), "The terminal must show the main conversation");
}
const ASKS_FOR_ENTER = "Press Enter to close this terminal.";
/** A terminal that kept input stays open with the path on screen. It closes at Enter. */
async function heldWith(terminal: OwnedProcess, until: World["until"], path: string): Promise<void> {
  await until(async () => terminal.output().includes(ASKS_FOR_ENTER), "The terminal must ask before it closes", () => terminal.output().slice(-2000), 30_000);
  assert.ok(terminal.output().includes("Unsent input saved privately to " + path), terminal.output().slice(-2000));
  assert.equal(await Promise.race([terminal.exited, sleep(1_000, "open")]), "open", "The pane must stay open until Enter");
}
/** Ctrl+C in an idle interface quits it. A first press can instead clear what the interface was doing. */
async function quit(terminal: OwnedProcess): Promise<void> {
  for (let presses = 0; presses < 3; presses += 1) {
    terminal.child.stdin.write("\x03");
    const shown = terminal.output().length;
    if (await Promise.race([terminal.exited.then(() => true), sleep(2_000, false)]) || terminal.output().slice(shown).includes(ASKS_FOR_ENTER)) return;
  }
  assert.fail("Ctrl+C must quit the terminal: " + terminal.output().slice(-2000));
}

test("a released task terminal with nothing typed exits normally", { timeout: 60_000 }, async (t) => {
  const { task, attach, finish, saved, tasks } = await taskTerminal(t, "Plain release");
  const terminal = await attach();
  await finish();
  assert.equal(await terminal.exited, 0, terminal.errors());
  assert.deepEqual(await saved().catch(() => []), [], "A terminal with no unsent input saves nothing");
  assert.equal((await tasks()).find((item) => item.id === task.id)?.state.state, "resolved");
});

test("a draft typed in a task terminal's own view outlives the release and is still there", { timeout: 90_000 }, async (t) => {
  const { task, attach, finish, until, script, tasks, saved } = await taskTerminal(t, "Own draft");
  const draft = "fixture-own-draft: check the audit once more";
  await script("fixture-own-draft", [{ text: "Checked the own draft audit again." }]);
  const terminal = await attach();
  await type(terminal, draft);
  await finish();
  await until(async () => terminal.output().includes("Own draft audit finished."), "The task must finish");
  assert.equal((await tasks()).find((item) => item.id === task.id)?.state.state, "resolved");
  assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000, "running")]), "running",
    "A terminal that holds a draft for its own task must outlive the grace: " + terminal.errors());
  assert.deepEqual(await saved().catch(() => []), [], "The draft stays in the terminal, not in a recovery file");
  terminal.child.stdin.write("\r");
  await until(async () => terminal.output().includes("Checked the own draft audit again."), "The task must answer the draft once it is sent",
    () => terminal.output().slice(-2000), 30_000);
});

type TaskRecovery = { owner: unknown; draft: { text?: string }; queued_inputs: { input: unknown; mode: string }[] };
/**
 * An input that the terminal wrote to a request that its release ended. A stopped service holds the input in its socket,
 * so the coordinator releases the terminal before it reads the input. `then` runs while the service is stopped.
 */
async function caughtAtRelease(t: TestContext, name: string, then: (terminal: OwnedProcess) => Promise<void> = async () => {}) {
  const world = await taskTerminal(t, name);
  const { server, attach, finish, until, script } = world;
  const late = "fixture-late-input: check the audit once more";
  await script("fixture-late-input", [{ text: "Checked the late input audit again." }]);
  const terminal = await attach();
  await finish();
  await until(async () => terminal.output().includes(name + " audit finished."), "The task must finish");
  assert.ok(server.child.pid !== undefined);
  await sleep(RELEASE_SECONDS * 500);
  process.kill(server.child.pid, "SIGSTOP");
  try {
    terminal.child.stdin.write(late + "\r");
    await then(terminal);
    await sleep(RELEASE_SECONDS * 1_000);
  } finally { process.kill(server.child.pid, "SIGCONT"); }
  return { ...world, terminal, late, released: Date.now(),
    /** The task's recovery file holds the input alone, and the task never ran it. */
    async savedOnlyUnderItsTask(): Promise<string> {
      const [file, ...others] = await world.saved(); assert.ok(file !== undefined && others.length === 0);
      const recovery = file.recovery as TaskRecovery;
      assert.deepEqual(recovery.owner, { kind: "task", task_id: world.task.id, agent_id: null, allocation_id: world.worker.allocation_id });
      assert.deepEqual(recovery.queued_inputs.map(({ input, mode }) => ({ input, mode })), [{ input: { text: late }, mode: "steer" }]);
      assert.equal(recovery.draft.text ?? "", "", "A quit or an empty composer leaves no draft in the file");
      assert.ok(!(await world.cli(0, ["tasks", "read", world.task.id])).some((event) => event.type === "task" &&
        event.history.includes("Checked the late input audit again.")), "A saved input must not also reach the task");
      return file.path;
    } };
}

test("an input written to a request that its release ended keeps the terminal for one more grace, then is saved under its task and held on screen",
  { timeout: 90_000 }, async (t) => {
    const { terminal, released, until, savedOnlyUnderItsTask } = await caughtAtRelease(t, "Late input");
    await until(async () => terminal.output().includes(ASKS_FOR_ENTER), "The terminal must end at the next release and ask before it closes",
      () => terminal.output().slice(-2000), 30_000);
    assert.ok(Date.now() - released >= RELEASE_SECONDS * 1_000, "The release that caught the input must not end the terminal");
    await heldWith(terminal, until, await savedOnlyUnderItsTask());
    terminal.child.stdin.write("\r");
    assert.equal(await terminal.exited, 0, terminal.errors());
  });

for (const [held, name, then] of [
  ["a draft typed after it", "Late draft", (terminal: OwnedProcess) => type(terminal, "fixture-late-draft: and the summary")],
  ["another conversation in view", "Late view", async (terminal: OwnedProcess) => { terminal.child.stdin.write("/main\r"); }],
] as const) {
  test(`an input that a release caught does not end a terminal with ${held}, and a quit saves the input under its task and holds`,
    { timeout: 120_000 }, async (t) => {
      const { terminal, until, saved, savedOnlyUnderItsTask } = await caughtAtRelease(t, name, then);
      assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000 + 1_000, "running")]), "running",
        "A terminal in use must outlive three graces: " + terminal.errors());
      assert.deepEqual(await saved().catch(() => []), [], "Nothing is saved while the terminal stays");
      await quit(terminal);
      await heldWith(terminal, until, await savedOnlyUnderItsTask());
      terminal.child.stdin.write("\r");
      assert.equal(await terminal.exited, 0, terminal.errors());
    });
}

test("an input that the task places while the terminal shows another conversation does not end the terminal and is never saved as unsent",
  { timeout: 120_000 }, async (t) => {
    const { task, attach, finish, until, script, cli, saved } = await taskTerminal(t, "Placed elsewhere");
    const note = "fixture-steer-note: also check the summary", draft = "fixture-steer-main: is the audit done?";
    await script("fixture-steer-note", [{ tool: "record_task", args: { summary: "Checked the summary.",
      state: { state: "resolved", evidence: "The synthetic summary passed." } } }, { text: "The summary is checked." }]);
    await script("fixture-steer-main", [{ text: "The placed elsewhere audit is done." }]);
    const terminal = await attach();
    terminal.child.stdin.write(note + "\r");
    await sleep(500);
    await showMain(terminal, until);
    await type(terminal, draft);
    await finish();
    await until(async () => (await cli(0, ["tasks", "read", task.id])).some((event) => event.type === "task" &&
      event.history.includes("The summary is checked.") && event.task.state.state === "resolved"), "The task must answer the note and resolve");
    assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000 + 1_000, "running")]), "running",
      "A terminal that shows another conversation must outlive three graces: " + terminal.errors());
    terminal.child.stdin.write("\r");
    await until(async () => terminal.output().includes("The placed elsewhere audit is done."), "The main agent must answer the whole draft",
      () => terminal.output().slice(-2000), 30_000);
    await quit(terminal);
    assert.equal(await terminal.exited, 0, terminal.errors());
    assert.deepEqual(await saved().catch(() => []), [], "A placed input is not unsent, so no recovery file names it");
  });

test("a plain task terminal attaches again at every release, because it cannot see a line that is typed and not entered", { timeout: 120_000 }, async (t) => {
  const { task, attach, finish, until, script, cli } = await taskTerminal(t, "Plain terminal");
  const line = "fixture-plain-line: check the audit once more";
  await script("fixture-plain-line", [{ text: "Checked the plain terminal audit again." }]);
  const terminal = await attach("--no-tui");
  await finish();
  await until(async () => terminal.output().includes("Plain terminal audit finished."), "The task must finish");
  terminal.child.stdin.write(line);
  assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000 + 1_000, "running")]), "running",
    "A plain terminal must outlive three graces: " + terminal.errors());
  const shown = terminal.output();
  assert.equal(shown.split("Plain terminal audit finished.").length - 1, 1, "Attaching again must not print the history again: " + shown.slice(-2000));
  terminal.child.stdin.write("\r");
  await until(async () => (await cli(0, ["tasks", "read", task.id])).some((event) => event.type === "task" &&
    event.history.includes("Checked the plain terminal audit again.")), "The task must answer the whole line once it is entered");
  terminal.child.stdin.write("/exit\r");
  assert.equal(await terminal.exited, 0, terminal.errors());
});

test("a task terminal that loses its coordinator saves its own draft under its task and holds with the path", { timeout: 60_000 }, async (t) => {
  const { task, worker, server, attach, saved, until } = await taskTerminal(t, "Task draft");
  const draft = "An unsent note for later";
  const terminal = await attach();
  await type(terminal, draft);
  assert.ok(server.child.pid !== undefined); process.kill(-server.child.pid, "SIGKILL");
  await until(async () => terminal.output().includes(ASKS_FOR_ENTER), "The terminal must ask before it closes", () => terminal.output().slice(-2000), 30_000);
  const [file, ...others] = await saved(); assert.ok(file !== undefined && others.length === 0);
  await heldWith(terminal, until, file.path);
  assert.deepEqual(file.recovery, {
    owner: { kind: "task", task_id: task.id, agent_id: null, allocation_id: worker.allocation_id }, draft: { text: draft }, queued_inputs: [],
  });
  terminal.child.stdin.write("\r");
  assert.notEqual(await terminal.exited, 0, "A lost coordinator is a failure");
});

for (const signal of ["SIGTERM", "SIGHUP"] as const) {
  test(`${signal} to a task terminal that attached again after a release saves its draft under its task and ends it without a wait`, { timeout: 60_000 }, async (t) => {
    const { task, worker, attach, finish, until, saved, runTaskPid } = await taskTerminal(t, "Signalled draft");
    const draft = "An unsent note for later";
    const terminal = await attach();
    await type(terminal, draft);
    await finish();
    await until(async () => terminal.output().includes("Signalled draft audit finished."), "The task must finish");
    assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 1_500, "running")]), "running", "The draft keeps the terminal past its release");
    process.kill(await runTaskPid(), signal);
    assert.notEqual(await terminal.exited, 0, "A signal is not a normal end");
    const [file, ...others] = await saved(); assert.ok(file !== undefined && others.length === 0);
    assert.ok(terminal.output().includes("Unsent input saved privately to " + file.path), terminal.output().slice(-2000));
    assert.ok(!terminal.output().includes(ASKS_FOR_ENTER), "A signal asks the terminal to end, so it does not wait");
    assert.deepEqual(file.recovery, {
      owner: { kind: "task", task_id: task.id, agent_id: null, allocation_id: worker.allocation_id }, draft: { text: draft }, queued_inputs: [],
    });
  });
}

test("a task terminal whose pseudo-terminal is gone ends instead of waiting for its interface", { timeout: 60_000 }, async (t) => {
  const { attach, until, runTaskPid } = await taskTerminal(t, "Closed pane");
  const terminal = await attach();
  await type(terminal, "An unsent note for later");
  const pid = await runTaskPid();
  assert.ok(terminal.child.pid !== undefined); process.kill(terminal.child.pid, "SIGKILL");
  await until(async () => { try { process.kill(pid, 0); return false; } catch { return true; } },
    "run-task must not outlive a terminal that hung up", undefined, 10_000);
});

test("a task terminal that cannot save its unsent draft shows it and waits for Enter", { timeout: 60_000 }, async (t) => {
  const { recoveries, server, attach, until } = await taskTerminal(t, "Unsaved draft");
  const draft = "An unsent note to copy";
  await writeFile(recoveries, "");
  const terminal = await attach();
  await type(terminal, draft);
  assert.ok(server.child.pid !== undefined); process.kill(-server.child.pid, "SIGKILL");
  await until(async () => terminal.output().includes(ASKS_FOR_ENTER), "The terminal must ask before it closes",
    () => terminal.output().slice(-2000), 30_000);
  const shown = terminal.output().slice(terminal.output().lastIndexOf("Could not save your unsent input"));
  assert.ok(shown.includes(draft), shown);
  assert.equal(await Promise.race([terminal.exited, sleep(1_000, "open")]), "open", "The pane must stay open until Enter");
  terminal.child.stdin.write("\r");
  assert.notEqual(await terminal.exited, 0, "A lost coordinator is a failure");
});

test("a released task terminal that shows another conversation stays attached to its task", { timeout: 90_000 }, async (t) => {
  const { task, homes, attach, finish, until, cli, script, tasks } = await taskTerminal(t, "Switched view");
  const terminal = await attach();
  await showMain(terminal, until);
  await finish();
  await until(async () => (await tasks()).find((item) => item.id === task.id)?.state.state === "resolved", "The task must resolve");
  assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000, "running")]), "running",
    "A terminal in use for another conversation must outlive the grace: " + terminal.errors());
  const rexCalls = async () => (await readFile(join(homes[0], "rex.json.calls"), "utf8")).trim().split("\n").length;
  const before = await rexCalls();
  await script("fixture-switched-followup", [{ text: "Checked the switched view audit again." }]);
  await cli(0, ["tasks", "send", task.id, "fixture-switched-followup"]);
  await until(async () => (await cli(0, ["tasks", "read", task.id])).some((event) => event.type === "task" &&
    event.history.includes("Checked the switched view audit again.")), "The task must answer its new input");
  assert.equal(await rexCalls(), before, "The coordinator presents no pane for a task whose terminal is attached");
});

test("a task terminal that came back to its task from another conversation is released", { timeout: 90_000 }, async (t) => {
  const { task, attach, finish, until } = await taskTerminal(t, "Came back");
  const terminal = await attach();
  await showMain(terminal, until);
  const shown = terminal.output().length;
  terminal.child.stdin.write(`/resume ${task.id}\r`);
  await until(async () => terminal.output().slice(shown).includes("Came back audit"), "The terminal must show its task again");
  await finish();
  assert.equal(await terminal.exited, 0, terminal.errors());
});

test("a draft typed in another conversation outlives the release of its task terminal", { timeout: 90_000 }, async (t) => {
  const { task, attach, finish, until, script, tasks, saved } = await taskTerminal(t, "Kept draft");
  const draft = "fixture-kept-draft: is the audit done?";
  await script("fixture-kept-draft", [{ text: "The kept draft audit is done." }]);
  const terminal = await attach();
  await showMain(terminal, until);
  await type(terminal, draft);
  await finish();
  await until(async () => (await tasks()).find((item) => item.id === task.id)?.state.state === "resolved", "The task must resolve");
  assert.equal(await Promise.race([terminal.exited, sleep(RELEASE_SECONDS * 3_000, "running")]), "running",
    "A terminal that holds a draft for another conversation must outlive the grace: " + terminal.errors());
  assert.deepEqual(await saved().catch(() => []), [], "The draft stays in the terminal, not in a recovery file");
  terminal.child.stdin.write("\r");
  await until(async () => terminal.output().includes("The kept draft audit is done."), "The main agent must answer the draft once it is sent",
    () => terminal.output().slice(-2000), 30_000);
});

test("a task terminal that loses its coordinator saves another conversation's draft under that conversation, and SIGTERM ends its wait", { timeout: 60_000 }, async (t) => {
  const { server, attach, until, saved, runTaskPid } = await taskTerminal(t, "Lost coordinator");
  const draft = "A note for the main agent";
  const terminal = await attach();
  await showMain(terminal, until);
  await type(terminal, draft);
  assert.ok(server.child.pid !== undefined); process.kill(-server.child.pid, "SIGKILL");
  await until(async () => terminal.output().includes(ASKS_FOR_ENTER), "The terminal must ask before it closes", () => terminal.output().slice(-2000), 30_000);
  const files = await saved();
  assert.deepEqual(files.map((file) => file.recovery), [
    { owner: { kind: "conversation", conversation_id: "1" }, draft: { text: draft }, queued_inputs: [] },
  ]);
  await heldWith(terminal, until, files[0]!.path);
  process.kill(await runTaskPid(), "SIGTERM");
  assert.notEqual(await terminal.exited, 0, "SIGTERM must end a terminal that waits for Enter");
});
