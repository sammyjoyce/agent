import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { open, readFile, stat, writeFile, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { promisify } from "node:util";
import type { HistoryMessage } from "../src/generated/HistoryMessage.js";
import { sessions, type NativeSession } from "./fixtures/coordinator-native.js";
import { coordinatorWorld, delegate, effect, held, processes } from "./fixtures/coordinator-world.js";

type World = Awaited<ReturnType<typeof coordinatorWorld>>;

const heldReceipt = { type: "process", exit_code: 0, stdout: "Completed the held action.", stderr: "", truncated: false };

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }

async function laptopTask(world: World, dispatch: string, title: string) {
  await world.script(dispatch, [delegate(title, world.laptop), { text: `Delegated ${title}.` }]);
  await world.cli(0, ["chat", dispatch]);
  const task = (await world.tasks()).find((task) => task.title === title);
  assert.ok(task?.worker.state === "bound" && task.worker.binding.host_id === world.laptop, "The main agent must bind the worker task to the laptop");
  const binding = task.worker.binding;
  const launch = sessions(join(world.homes[1], "rex.json")).find((session) => session.block_id === binding.block_id);
  assert.ok(launch, "The laptop's Rex must record the worker's launch command");
  return { task, worker: task.worker, launch };
}

function runTask(world: World, launch: NativeSession, terminal: boolean) {
  return world.start(1, launch.command.slice(1), undefined, { REX_SESSION: launch.session_id, REX_BLOCK: launch.block_id }, true, terminal);
}

async function history(world: World, taskId: string): Promise<HistoryMessage[]> {
  const frames = await world.exchange({ type: "read_history", task_id: taskId, agent_id: null, cursor: null });
  return frames.flatMap((frame) => frame.type === "history" ? frame.messages : []);
}

/** The tool output the model received for the first call whose arguments contain `marker`. */
async function receipt(world: World, marker: string): Promise<string | undefined> {
  const log = await readFile(world.queue + ".requests", "utf8").catch(() => "");
  for (const line of log.split("\n").filter(Boolean)) {
    const request: unknown = JSON.parse(line);
    const input = object(request) && object(request.body) && Array.isArray(request.body.input) ? request.body.input : [];
    const calls = new Set(input.flatMap((item: unknown) => object(item) && typeof item.call_id === "string" &&
      ((item.type === "function_call" && typeof item.arguments === "string" && item.arguments.includes(marker)) ||
        (item.type === "custom_tool_call" && typeof item.input === "string" && item.input.includes(marker))) ? [item.call_id] : []));
    for (const item of input) {
      if (!object(item) || (item.type !== "function_call_output" && item.type !== "custom_tool_call_output") ||
        typeof item.call_id !== "string" || !calls.has(item.call_id)) continue;
      return typeof item.output === "string" ? item.output : JSON.stringify(item.output);
    }
  }
  return undefined;
}

async function delivered(world: World, marker: string, message: string): Promise<string> {
  let output: string | undefined;
  await world.until(async () => (output = await receipt(world, marker)) !== undefined, message);
  assert.ok(output !== undefined);
  return output;
}

/** Code mode wraps a host result as text after its status lines; the JSON value is the receipt. */
function hostResult(output: string): unknown {
  const start = output.indexOf("{");
  for (let end = output.lastIndexOf("}"); start >= 0 && end > start; end = output.lastIndexOf("}", end - 1)) {
    try { return JSON.parse(output.slice(start, end + 1)); } catch { /* Trailing prose can follow the JSON value. */ }
  }
  return undefined;
}

const lines = (path: string) => readFile(path, "utf8").then((text) => text.split("\n").filter(Boolean), () => []);
const starts = async (path: string) => (await lines(path + ".started")).map((line) => {
  const [pid, host] = line.split(" "); return { pid: Number(pid), host };
});
const exists = (path: string) => stat(path).then(() => true, () => false);

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

async function mkfifo(path: string): Promise<void> { await promisify(execFile)("mkfifo", [path]); }

/**
 * Opening the read end releases a writer blocked in open(2). Reads until the FIFO holds `length` bytes or the model
 * already has the write's receipt. The handle stays open, so `written` would also return a replayed write.
 */
async function drainWrite(t: TestContext, world: World, pipe: string, length: number) {
  const reader = await open(pipe, constants.O_RDONLY | constants.O_NONBLOCK);
  t.after(() => reader.close());
  let written = "";
  await world.until(async () => {
    written += await available(reader);
    return written.length >= length || await receipt(world, pipe) !== undefined;
  }, "The held write_file must reach its FIFO or report a receipt");
  const output = await delivered(world, pipe, "The model never received the write's receipt");
  return { receipt: output, written: async () => written += await available(reader) };
}

async function available(reader: FileHandle): Promise<string> {
  let text = "";
  for (;;) {
    try {
      const { bytesRead, buffer } = await reader.read(Buffer.alloc(4096), 0, 4096, null);
      if (bytesRead === 0) return text;
      text += buffer.subarray(0, bytesRead).toString("utf8");
    } catch (error) {
      if (error instanceof Error && "code" in error && error.code === "EAGAIN") return text;
      throw error;
    }
  }
}

test("closing the worker terminal mid-effect leaves the laptop daemon to finish the turn and its queued follow-up", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, cli, until, tasks, script } = world;
  const { task, worker, launch } = await laptopTask(world, "fixture-close-dispatch", "fixture-close-worker");
  const action = join(directory, "close-action"), pipe = join(directory, "close-pipe");
  const content = "Written once by the owning daemon.\n";
  const answer = "The closed terminal's turn finished.", followAnswer = "The queued follow-up ran without a terminal.";
  await mkfifo(pipe);
  await script("fixture-close-worker", [held(action), { tool: "write_file", args: { path: pipe, content } }, { text: answer }]);
  const terminal = runTask(world, launch, true);
  await until(async () => (await starts(action)).length === 1, "The worker's held exec did not start", () => terminal.output().slice(-2000));

  await script("fixture-close-followup", [{ text: followAnswer }]);
  await script("fixture-close-queue", [{ tool: "delegate_task", args: { task_id: task.id, input: "fixture-close-followup", mode: "follow_up" } },
    { text: "The follow-up is queued behind the held turn." }]);
  await cli(0, ["chat", "fixture-close-queue"]);

  terminal.child.kill("SIGKILL"); await terminal.exited;
  await until(async () => (await processes("run-task " + task.id)).length === 0, "Closing the PTY must hang up the worker's terminal client");

  await writeFile(action + ".release", "Finish after the terminal closed.");
  const execReceipt = await delivered(world, action, "The model never received the held exec's receipt");
  assert.deepEqual(hostResult(execReceipt), heldReceipt,
    "The actor must receive the held exec's real output after its terminal closed, not a disconnected or uncertain failure\n" + execReceipt);

  const write = await drainWrite(t, world, pipe, content.length);
  assert.deepEqual(hostResult(write.receipt), { type: "written" },
    "The write issued after the terminal closed must report its real receipt\n" + write.receipt);

  await until(async () => {
    const texts = (await history(world, task.id)).map((message) => message.text);
    return texts.includes(answer) && texts.includes(followAnswer);
  }, "The turn and its queued follow-up must both finish with no terminal attached");
  const saved = await history(world, task.id);
  assert.equal(saved.filter((message) => message.text === answer).length, 1, "The first turn's answer must be saved once");
  assert.equal(saved.filter((message) => message.text === followAnswer).length, 1, "The follow-up's answer must be saved once");
  assert.equal(await write.written(), content, "The model's content must reach the FIFO exactly once");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The held exec must start exactly once, on the laptop");
  assert.deepEqual(await lines(action + ".finished"), ["once"], "The held exec must finish exactly once");

  const after = (await tasks()).find((candidate) => candidate.id === task.id);
  assert.ok(after?.worker.state === "bound", "The task must keep its bound worker");
  assert.equal(after.conversation_id, task.conversation_id);
  assert.equal(after.worker.allocation_id, worker.allocation_id);
  assert.deepEqual(after.worker.binding, worker.binding);
});

test("killing the worker client mid-write keeps its actor running, and reopening the task attaches without a replay", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, homes, events, until, script } = world;
  const { task, launch } = await laptopTask(world, "fixture-kill-dispatch", "fixture-kill-worker");
  const pipe = join(directory, "kill-pipe"), action = join(directory, "kill-action"), rex = join(homes[1], "rex.json");
  const content = "Written once after the client was killed.\n";
  const answer = "The killed client's turn finished.", laterAnswer = "The reopened terminal continues the same conversation.";
  await mkfifo(pipe);
  await script("fixture-kill-worker", [{ tool: "write_file", args: { path: pipe, content } }, held(action), { text: answer }]);
  const client = runTask(world, launch, false);
  await until(async () => events(client.output()).some((event) => event.type === "activity" &&
    event.activity.type === "tool_started" && event.activity.name === "write_file"), "The worker did not start its FIFO write");
  const launches = sessions(rex), before = await history(world, task.id);

  client.child.kill("SIGKILL"); await client.exited;

  const write = await drainWrite(t, world, pipe, content.length);
  assert.deepEqual(hostResult(write.receipt), { type: "written" },
    "The write held when its client was killed must finish with its real receipt\n" + write.receipt);
  await until(async () => (await starts(action)).length > 0, "The held exec after the write did not start");

  const reopened = runTask(world, launch, false);
  await until(async () => events(reopened.output()).some((event) => event.type === "task_ready"), "The reopened terminal must reach task_ready");
  const ready = events(reopened.output()).find((event) => event.type === "task_ready");
  assert.ok(ready?.type === "task_ready"); assert.equal(ready.conversation_id, task.conversation_id, "Reopening must attach to the same conversation");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop],
    "Reopening must not start a second actor or replay the held exec, which runs once on the laptop");
  assert.deepEqual(sessions(rex), launches, "Reopening must not create a Rex session");

  await writeFile(action + ".release", "Finish while the reopened terminal observes.");
  await until(async () => events(reopened.output()).some((event) => event.type === "answer" && event.text === answer),
    "The reopened terminal must print the turn's final answer");
  assert.deepEqual(await lines(action + ".finished"), ["once"], "The held exec must finish exactly once");
  const execReceipt = await receipt(world, action); assert.ok(execReceipt !== undefined, "The model must receive the held exec's receipt");
  assert.deepEqual(hostResult(execReceipt), heldReceipt, "The actor must receive the held exec's real output\n" + execReceipt);

  await script("fixture-kill-later", [{ text: laterAnswer }]);
  reopened.child.stdin.write("fixture-kill-later\n");
  await until(async () => events(reopened.output()).some((event) => event.type === "answer" &&
    event.conversation_id === task.conversation_id && event.text === laterAnswer), "The reopened terminal's input must be answered in the same conversation");

  const after = await history(world, task.id);
  for (const input of ["fixture-kill-worker", "fixture-kill-later"]) {
    assert.equal(after.filter((message) => message.text === input).length, 1, `The input ${input} must appear exactly once in the task history`);
  }
  for (const entry of before) {
    assert.ok(after.some((message) => message.entry_id === entry.entry_id && message.role === entry.role),
      `The ${entry.role} entry ${entry.entry_id} saved before the kill must keep its id`);
  }
  assert.equal(await write.written(), content, "The model's content must reach the FIFO exactly once");
  reopened.child.stdin.end("/exit\n"); assert.equal(await reopened.exited, 0, reopened.errors());
});

test("an explicit Stop interrupts only its own actor's held effect, and the stopped actor still accepts input", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, events, until, script } = world;
  const first = await laptopTask(world, "fixture-stop-dispatch-a", "fixture-stop-held-a");
  const second = await laptopTask(world, "fixture-stop-dispatch-b", "fixture-stop-held-b");
  const stopped = join(directory, "stop-a"), running = join(directory, "stop-b");
  const runningAnswer = "The other actor finished its held exec.", resumedAnswer = "The stopped actor accepts new input.";
  await script("fixture-stop-held-a", [held(stopped), { text: "A stopped action must not finish." }]);
  await script("fixture-stop-held-b", [held(running), { text: runningAnswer }]);
  const stoppedTerminal = runTask(world, first.launch, true), runningClient = runTask(world, second.launch, false);
  await until(async () => (await starts(stopped)).length === 1 && (await starts(running)).length === 1, "Both held execs must start");
  const [stoppedStart] = await starts(stopped), [runningStart] = await starts(running);
  assert.ok(stoppedStart !== undefined && runningStart !== undefined);

  stoppedTerminal.child.stdin.write("\u001b");
  await until(async () => !alive(stoppedStart.pid), "Esc must stop the actor's held process", () => stoppedTerminal.output().slice(-2000));
  await writeFile(stopped + ".release", "A stopped action must remain stopped.");
  assert.equal(await exists(stopped + ".finished"), false, "A stopped effect must never finish");
  assert.ok(alive(runningStart.pid), "Stopping one actor must not touch another actor's held process");

  await writeFile(running + ".release", "Finish the other actor.");
  await until(async () => events(runningClient.output()).some((event) => event.type === "answer" && event.text === runningAnswer),
    "The other actor's turn must complete");
  assert.deepEqual(await lines(running + ".finished"), ["once"]);
  const runningReceipt = await receipt(world, running); assert.ok(runningReceipt !== undefined);
  assert.deepEqual(hostResult(runningReceipt), heldReceipt, "The other actor must receive its real receipt\n" + runningReceipt);

  await script("fixture-stop-resumed-a", [{ text: resumedAnswer }]);
  stoppedTerminal.child.stdin.write("fixture-stop-resumed-a\r");
  await until(async () => (await history(world, first.task.id)).some((message) => message.text === resumedAnswer),
    "The stopped actor must answer new input", () => stoppedTerminal.output().slice(-2000));
  runningClient.child.stdin.end("/exit\n"); assert.equal(await runningClient.exited, 0, runningClient.errors());
});

test("an offline owning host never runs the worker's command in its terminal or on the coordinator", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { coordinator, laptop, homes, events, start, until, online, script } = world;
  const { launch } = await laptopTask(world, "fixture-offline-dispatch", "fixture-offline-worker");
  await script("fixture-offline-worker", [{ text: "Ready for input." }]);
  const client = runTask(world, launch, false);
  await until(async () => events(client.output()).some((event) => event.type === "worker_idle"), "The worker terminal must become idle");

  world.worker.child.kill("SIGINT"); assert.equal(await world.worker.exited, 0, world.worker.errors()); await online([coordinator]);
  await script("fixture-offline-attempt", [{ tool: "exec", args: { program: process.execPath, args: [...effect, "offline-attempt"] } },
    { text: "The offline attempt was answered." }]);
  client.child.stdin.write("fixture-offline-attempt\n");
  await until(async () => events(client.output()).some((event) => event.type === "answer" && event.text === "The offline attempt was answered."),
    "The offline attempt must still be answered");
  for (const home of homes) {
    assert.deepEqual(await lines(join(home, "effects")), [], `No command may run in ${home} while its owning daemon is offline`);
  }
  const offline = await receipt(world, "offline-attempt"); assert.ok(offline !== undefined);
  const result = hostResult(offline);
  assert.ok(object(result) && (result.type === "not_started" || result.delivery === "not_started"),
    "The model must be told the command was not started\n" + offline);

  start(1, ["maintain"]); await online([coordinator, laptop]);
  await script("fixture-online-attempt", [{ tool: "exec", args: { program: process.execPath, args: [...effect, "online-attempt"] } },
    { text: "The online attempt was answered." }]);
  client.child.stdin.write("fixture-online-attempt\n");
  await until(async () => events(client.output()).some((event) => event.type === "answer" && event.text === "The online attempt was answered."),
    "The online attempt must be answered");
  assert.deepEqual((await lines(join(homes[1], "effects"))).map((line) => JSON.parse(line)), [{ host: laptop, cwd: homes[1] }],
    "The reconnected owning daemon must run the command once on the laptop");
  assert.deepEqual(await lines(join(homes[0], "effects")), [], "The coordinator must never run the worker's command");
  client.child.stdin.end("/exit\n"); assert.equal(await client.exited, 0, client.errors());
});
