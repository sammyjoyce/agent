import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, mkdir, mkdtemp, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { delimiter, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { protocolLines, validEvent } from "../src/protocol.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import type { NativeRequest } from "../src/generated/NativeRequest.js";
import { sessions } from "./fixtures/coordinator-native.js";
import { pidsMatching } from "./fixtures/coordinator-world.js";
import type { ModelQueue, ModelStep } from "./fixtures/coordinator-runtime.js";

type GoalCheck = { type: "file_contains"; path: string; text: string };
type GoalView = {
  goal: {
    id: string; task_id: string; objective: string;
    activation: { number: number; continuations: number; budget: number; check: GoalCheck | null };
    state: { state: "active" } | { state: "paused"; reason: string } |
      { state: "complete"; evidence: { entry_id: string; activation: number; check: GoalCheck; observed: { bytes: number; sha256: string } } };
    last_rejection: { type: string; tool_call_id: string } | null;
  };
  task: TaskRecord;
};
type GoalStatus = { conversation_id: string; goal: GoalView | null };
type NativeFrame = { type: string; text?: string };

test("a /goal persists, pauses across a coordinator restart, resumes once and completes only on a verified file", { timeout: 120_000 }, async (t) => {
  const directory = await realpath(await mkdtemp("/tmp/agent-goal-e2e-"));
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/beep-boop", import.meta.url));
  const terminalFixture = fileURLToPath(new URL("../../../target/debug/examples/terminal-fixture", import.meta.url));
  const runtime = fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url));
  const coordinator = "11111111-1111-4111-8111-111111111111";
  const home = join(directory, "desktop"), bin = join(directory, "bin"), queue = join(directory, "responses.json");
  const state = join(home, "state"), socket = join(state, "agent.sock");
  const notes = join(directory, "goal-notes.md"), objective = `fixture-goal: write GOAL-DONE into ${notes}`;
  const children: { child: ChildProcessWithoutNullStreams; exited: Promise<number | null>; output: () => string; errors: () => string }[] = [];
  const events = (text: string): RuntimeEventKind[] => text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean).map((line) => {
    const event: unknown = JSON.parse(line), frame = { version: 1, id: 1, event };
    assert.ok(validEvent(frame), "The real CLI must return typed protocol events: " + line); return frame.event;
  });
  function start(args: string[], { terminal = false, plain = false, native = false, env = {} }:
    { terminal?: boolean; plain?: boolean; native?: boolean; env?: NodeJS.ProcessEnv } = {}) {
    const arguments_ = native ? args : ["--state-dir", state, "--config", join(home, "agent.toml"),
      "--runtime", runtime, "--instructions", join(home, "AGENTS.md"), ...args];
    const command = terminal ? [binary, ...arguments_] : plain ? ["--no-tui", ...arguments_] : ["--json", "--no-tui", ...arguments_];
    const child = spawn(terminal ? terminalFixture : binary, command, { cwd: home, detached: true, stdio: ["pipe", "pipe", "pipe"], env: {
      PATH: bin + delimiter + process.env.PATH, HOME: home, XDG_CONFIG_HOME: join(home, ".config"), XDG_DATA_HOME: join(home, ".local"),
      TMPDIR: directory, TERM: "xterm-256color", AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC, OPENAI_API_KEY: "sk-synthetic-fixture",
      AGENT_TEST_NODE_ID: coordinator, AGENT_TEST_REX_STATE: join(home, "rex.json"), AGENT_TEST_MODEL_QUEUE: queue,
      AGENT_TEST_COORDINATOR_SOCKET: socket, ...env, ...(terminal ? { AGENT_TEST_TERMINAL_REPLY: "1" } : {}),
    } });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (text: string) => { stdout += text; });
    child.stderr.setEncoding("utf8").on("data", (text: string) => { stderr += text; });
    const exited = new Promise<number | null>((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
    const owned = { child, exited, output: () => stdout, errors: () => stderr }; children.push(owned);
    return owned;
  }
  async function cli(args: string[]): Promise<RuntimeEventKind[]> {
    const process = start(args); process.child.stdin.end();
    assert.equal(await process.exited, 0, process.errors()); return events(process.output());
  }
  async function until(check: () => Promise<boolean>, message = ""): Promise<void> {
    const deadline = Date.now() + 15_000;
    while (!await check()) {
      assert.ok(Date.now() < deadline, message + "\n" + children.slice(-4).map((owned) => owned.errors().slice(-2400) + owned.output().slice(-2400)).join("\n"));
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  const exists = (path: string) => stat(path).then(() => true, () => false);
  // The TUI repaints only changed cells, so a skipped blank cell arrives as a cursor move.
  const screen = (output: string) => output.replace(/\x1b\[\d+;\d+H/g, " ").replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "").replace(/\s+/g, " ");
  async function serve() {
    const server = start(["serve", "--local-only", "--no-sources"]);
    await until(async () => new Promise<boolean>((resolve) => {
      const probe = createConnection(socket).once("connect", () => { probe.destroy(); resolve(true); }).once("error", () => resolve(false));
    }), "The coordinator did not accept connections");
    return server;
  }
  async function exchange(command: RuntimeCommand): Promise<RuntimeEventKind[]> {
    const channel = createConnection(socket); const frames: RuntimeEventKind[] = [];
    try {
      channel.write(JSON.stringify(command) + "\n");
      for await (const line of protocolLines(channel)) {
        const frame = { version: 1, id: 1, event: JSON.parse(line) as unknown };
        assert.ok(validEvent(frame)); frames.push(frame.event);
        if (frame.event.type === "done") break;
      }
      return frames;
    } finally { channel.destroy(); }
  }
  async function native(requests: NativeRequest[]): Promise<NativeFrame[]> {
    const channel = createConnection(socket); const frames: NativeFrame[] = [];
    try {
      for (const request of requests) channel.write(JSON.stringify({ type: "native", request }) + "\n");
      for await (const line of protocolLines(channel)) {
        const frame = JSON.parse(line) as NativeFrame; frames.push(frame);
        if (frame.type === "done") break;
      }
      return frames;
    } finally { channel.destroy(); }
  }
  function goalOf(frames: RuntimeEventKind[]): GoalStatus {
    const found = frames.find((event) => (event.type as string) === "goal") as unknown as { status: GoalStatus } | undefined;
    assert.ok(found, "/goal must answer with one typed goal event: " + JSON.stringify(frames)); return found.status;
  }
  const showGoal = async () => goalOf(await cli(["chat", "/goal"]));
  async function tasks(): Promise<TaskRecord[]> {
    const event = (await cli(["tasks", "list"])).find((event) => event.type === "tasks"); assert.ok(event?.type === "tasks"); return event.tasks;
  }
  async function script(key: string, steps: ModelStep[]): Promise<void> {
    const current: ModelQueue = JSON.parse(await readFile(queue, "utf8")); current[key] = steps; await writeFile(queue, JSON.stringify(current));
  }
  async function requests(): Promise<{ key: string }[]> {
    return (await readFile(queue + ".requests", "utf8")).trim().split("\n").map((line) => JSON.parse(line) as { key: string });
  }
  function worker(task: TaskRecord) {
    assert.ok(task.worker.state === "bound", "The task must own a confirmed Rex terminal");
    const binding = task.worker.binding;
    const launch = sessions(join(home, "rex.json")).find((window) => window.block_id === binding.block_id); assert.ok(launch);
    return start(launch.command.slice(1), { native: true, env: { REX_SESSION: launch.session_id, REX_BLOCK: launch.block_id } });
  }
  const held = (path: string): ModelStep => ({ tool: "exec", args: { program: process.execPath, args: ["-e",
    'const fs=require("node:fs"),path=process.argv[1];fs.writeFileSync(path+".started",String(process.pid));' +
    'async function run(){while(!fs.existsSync(path+".release"))await new Promise(resolve=>setTimeout(resolve,20));' +
    'fs.appendFileSync(path+".finished","once\\n");process.stdout.write("Completed the held action.");}void run();', path] } });
  const check: GoalCheck = { type: "file_contains", path: notes, text: "GOAL-DONE" };
  try {
    await mkdir(bin); await writeFile(queue, "{}"); await writeFile(queue + ".requests", "");
    for (const method of ["rex", "ssh"]) {
      const path = join(bin, method);
      await writeFile(path, `#!${process.execPath}\nprocess.env.AGENT_TEST_NATIVE=${JSON.stringify(method)};await import(${JSON.stringify(new URL("./fixtures/coordinator-native.js", import.meta.url).href)});\n`);
      await chmod(path, 0o700);
    }
    await mkdir(state, { recursive: true, mode: 0o700 }); await chmod(state, 0o700);
    await writeFile(join(home, "AGENTS.md"), "Keep synthetic work on its requested host.\n");
    await writeFile(join(home, "agent.toml"), 'node_name = "desktop"\n');
    let server = await serve();

    const other = join(directory, "unrelated");
    await script("fixture-unrelated-dispatch", [{ tool: "delegate_task", args: { title: "fixture-unrelated-work", outcome: "fixture-unrelated-work",
      input: "fixture-unrelated-work", new_task: true, new_task_reason: "The unrelated audit is separate synthetic work." } },
    { text: "Delegated the unrelated work." }]);
    await script("fixture-unrelated-work", [held(other),
      { tool: "record_task", args: { summary: "Unrelated work finished.", state: { state: "resolved", evidence: "The unrelated held action finished." } } },
      { text: "Unrelated work finished." }]);
    await cli(["chat", "fixture-unrelated-dispatch"]);
    const unrelated = (await tasks()).find((task) => task.title === "fixture-unrelated-work"); assert.ok(unrelated);
    let unrelatedWorker = worker(unrelated);
    await until(() => exists(other + ".started"), "The unrelated task must start its held host effect");

    const terminal = start([], { terminal: true });
    await until(async () => terminal.output().includes("Ask Beep Boop to do anything"), "The main TUI did not start");
    terminal.child.stdin.write(`/goal ${objective}\r`);
    await until(async () => screen(terminal.output()).includes("continuations 0 of 5"), "The TUI must show the new goal and its budget");
    terminal.child.stdin.write("/exit\r"); assert.equal(await terminal.exited, 0, terminal.errors());
    assert.equal((await requests()).filter((request) => request.key.startsWith("fixture-goal")).length, 0,
      "/goal is a control, so setting it never reaches the main model");

    const set = await showGoal(); assert.ok(set.goal);
    assert.equal(set.goal.goal.objective, objective); assert.equal(set.goal.goal.state.state, "active");
    assert.deepEqual(set.goal.goal.activation.number, 1);
    const goalTask = (await tasks()).find((task) => task.id === set.goal?.goal.task_id); assert.ok(goalTask);
    assert.notEqual(goalTask.id, unrelated.id); assert.equal(goalTask.worker.state, "bound");
    const nativeShow = await native([{ type: "identify" }, { type: "submit", input_id: "7a0c2b9e-1d1f-4c3a-9a51-0f6a3d1c2b01", text: "/goal", mode: "follow_up" }]);
    assert.ok(nativeShow.some((frame) => frame.type === "notice" && frame.text?.includes(`Goal: ${objective}`)),
      "The phone must see the same goal through the shared parser: " + JSON.stringify(nativeShow));

    const goalHold = join(directory, "goal-hold");
    await script("Goal set with /goal: fixture-goal", [
      { tool: "write_file", args: { path: notes, content: "draft\n" } },
      { tool: "complete_goal", args: { check, summary: "Checked the draft notes." } },
      { tool: "record_task", args: { summary: "Claiming the goal before it is verified.", state: { state: "resolved", evidence: "I wrote it." } } },
      { tool: "record_task", args: { summary: "Drafted the notes; GOAL-DONE is still missing.", state: { state: "open" } } },
      held(goalHold), { text: "The paused turn must never answer." }]);
    let goalWorker = worker(goalTask);
    await until(() => exists(goalHold + ".started"), "The goal task must run its first turn");
    const progress = await showGoal(); assert.ok(progress.goal);
    assert.equal(progress.goal.goal.state.state, "active");
    assert.equal(progress.goal.task.state.state, "open", "Neither the failed check nor the premature resolution may resolve the task");
    assert.equal(progress.goal.task.summary, "Drafted the notes; GOAL-DONE is still missing.");
    assert.deepEqual(progress.goal.goal.activation.check, check, "The first check pins this activation");
    assert.equal(progress.goal.goal.last_rejection?.type, "premature_resolution");
    const visible = start(["chat", "/goal"], { plain: true }); visible.child.stdin.end(); assert.equal(await visible.exited, 0, visible.errors());
    for (const line of [`Goal: ${objective}`, "State: active · activation 1 · continuations 0 of 5", "Summary: Drafted the notes; GOAL-DONE is still missing."]) {
      assert.ok(visible.output().includes(line), `Plain /goal must show "${line}":\n${visible.output()}`);
    }

    const paused = goalOf(await cli(["chat", "/goal pause"])); assert.ok(paused.goal);
    assert.deepEqual(paused.goal.goal.state, { state: "paused", reason: "requested" });
    await until(async () => events(goalWorker.output()).some((event) => event.type === "interrupted"), "Pause must stop the goal task's live turn");
    await writeFile(goalHold + ".release", "a paused goal's held action must stay stopped");
    await new Promise((resolve) => setTimeout(resolve, 300));
    assert.equal(await exists(goalHold + ".finished"), false, "Pause must cancel the goal turn's host effect");
    assert.equal(await exists(other + ".finished"), false, "Pause must not stop the unrelated task");
    await writeFile(other + ".release", "the unrelated task continues while the goal is paused");
    await until(async () => events(unrelatedWorker.output()).some((event) => event.type === "answer" && event.text === "Unrelated work finished."));
    assert.equal((await tasks()).find((task) => task.id === unrelated.id)?.state.state, "resolved");
    const afterOther = await showGoal(); assert.ok(afterOther.goal);
    assert.equal(afterOther.goal.goal.state.state, "paused", "Unrelated resolution must never complete or resume the goal");
    assert.equal(afterOther.goal.task.state.state, "open");
    assert.equal((await requests()).filter((request) => request.key.startsWith("Goal continuation")).length, 0,
      "A paused goal admits no continuation");

    for (const owned of [goalWorker, unrelatedWorker]) { owned.child.stdin.end("/exit\n"); assert.equal(await owned.exited, 0, owned.errors()); }
    server.child.kill("SIGINT"); assert.equal(await server.exited, 0, server.errors());
    server = await serve();
    const restarted = await showGoal(); assert.ok(restarted.goal);
    assert.deepEqual(restarted.goal.goal.state, { state: "paused", reason: "requested" }, "The pause must survive a coordinator restart");
    assert.equal(restarted.goal.goal.id, set.goal.goal.id); assert.equal(restarted.goal.task.id, goalTask.id);

    await script("Goal resumed (activation 2)", [{ tool: "write_file", args: { path: notes, content: "GOAL-DONE\n" } },
      { text: "Wrote the final notes." }]);
    await script("Goal continuation 1 of 5 (activation 2)", [{ tool: "complete_goal", args: { check, summary: "The notes contain GOAL-DONE." } },
      { text: "The goal is verified." }]);
    const resumeId = "7a0c2b9e-1d1f-4c3a-9a51-0f6a3d1c2b02";
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const resumed = await native([{ type: "identify" }, { type: "submit", input_id: resumeId, text: "/goal resume", mode: "follow_up" }]);
      const notice = resumed.find((frame) => frame.type === "notice")?.text ?? "";
      assert.match(notice, /State: active · activation 2 · continuations [01] of 5|Verified: activation 2 /,
        "A replayed native resume must return the same single activation, which its actor may already have verified: " + JSON.stringify(resumed));
    }
    const resumedTask = (await tasks()).find((task) => task.id === goalTask.id); assert.ok(resumedTask);
    assert.equal(resumedTask.conversation_id, goalTask.conversation_id, "Resume continues the same task conversation");
    goalWorker = worker(resumedTask);
    await until(async () => (await showGoal()).goal?.goal.state.state === "complete", "The verified goal must complete");

    const complete = await showGoal(); assert.ok(complete.goal && complete.goal.goal.state.state === "complete");
    const evidence = complete.goal.goal.state.evidence;
    assert.equal(evidence.activation, 2); assert.deepEqual(evidence.check, check);
    assert.equal(evidence.observed.sha256, createHash("sha256").update(await readFile(notes)).digest("hex"),
      "The evidence must describe the file the runtime read");
    assert.equal(complete.goal.task.id, goalTask.id); assert.equal(complete.goal.task.conversation_id, goalTask.conversation_id);
    assert.equal(complete.goal.task.state.state, "resolved");
    const history = (await exchange({ type: "read_history", task_id: goalTask.id, agent_id: null, cursor: null }))
      .flatMap((event) => event.type === "history" ? event.messages : []);
    assert.equal(history.filter((message) => message.role === "user" && message.text.startsWith("Goal resumed (activation 2)")).length, 1,
      "Two native resume submits must admit exactly one resume turn");
    assert.equal(history.filter((message) => message.role === "user" && message.text.startsWith("Goal continuation 2")).length, 0);
    const doneText = start(["chat", "/goal"], { plain: true }); doneText.child.stdin.end(); assert.equal(await doneText.exited, 0, doneText.errors());
    assert.ok(doneText.output().includes("State: complete"), doneText.output());

    goalWorker.child.stdin.end("/exit\n"); assert.equal(await goalWorker.exited, 0, goalWorker.errors());
    server.child.kill("SIGINT"); assert.equal(await server.exited, 0, server.errors());
    const database = await openNodeSqliteDatabase(join(state, "session.sqlite"));
    const harness = await Harness.open(await SqliteStorage.open(database), { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
    try {
      const conversation = await harness.conversation(Number(goalTask.conversation_id) as never, BACKGROUND_CONTEXT); assert.ok(conversation);
      const page = await conversation.entries({ order: "ascending" }, 1000, undefined, BACKGROUND_CONTEXT);
      const checks = page.items.filter((entry) => entry.kind === "agent.goal_verification")
        .map((entry) => ({ id: entry.id.toString(), data: entry.data as { activation: number; result: { type: string } } }));
      assert.deepEqual(checks.map((entry) => [entry.data.activation, entry.data.result.type]), [[1, "failed"], [2, "passed"]],
        "Every runtime check is retained in the task conversation");
      assert.equal(checks[1]?.id, evidence.entry_id, "The completed goal cites the retained passing entry");
    } finally { await harness.close(BACKGROUND_CONTEXT); }
  } catch (error) {
    t.diagnostic("Goal e2e failure: " + JSON.stringify(children.slice(-8).map((owned) => ({ arguments: owned.child.spawnargs.slice(1, 6),
      exitCode: owned.child.exitCode, stdout: owned.output().slice(-3000), stderr: owned.errors().slice(-3000) }))));
    throw error;
  } finally {
    for (const owned of children.slice().reverse()) if (owned.child.pid !== undefined && owned.child.exitCode === null && owned.child.signalCode === null) {
      try { process.kill(-owned.child.pid, "SIGTERM"); } catch {}
    }
    await Promise.race([Promise.allSettled(children.map((owned) => owned.exited)), new Promise((resolve) => setTimeout(resolve, 2000).unref())]);
    for (const owned of children) if (owned.child.pid !== undefined && owned.child.exitCode === null && owned.child.signalCode === null) {
      try { process.kill(-owned.child.pid, "SIGKILL"); } catch {}
    }
    await Promise.allSettled(children.map((owned) => owned.exited));
    // A held host action runs in its own process group, so the owner group kills above cannot reach it.
    for (const pid of await pidsMatching(directory).catch(() => [])) {
      try { process.kill(pid, "SIGKILL"); } catch {}
    }
    await rm(directory, { recursive: true, force: true });
  }
});
