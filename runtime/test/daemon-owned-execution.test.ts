import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { constants } from "node:fs";
import { open, readFile, stat, writeFile, type FileHandle } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { promisify } from "node:util";
import type { HistoryMessage } from "../src/generated/HistoryMessage.js";
import { sessions, type NativeSession } from "./fixtures/coordinator-native.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { coordinatorWorld, delegate, effect, held, pidsMatching } from "./fixtures/coordinator-world.js";

type World = Awaited<ReturnType<typeof coordinatorWorld>>;

const heldReceipt = { type: "process", exit_code: 0, stdout: "Completed the held action.", stderr: "", truncated: false };

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }

async function laptopTask(world: World, dispatch: string, title: string, steps: ModelStep[]) {
  await world.script(title, steps);
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

async function toolOutputFor(world: World, marker: string): Promise<string | undefined> {
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
  await world.until(async () => (output = await toolOutputFor(world, marker)) !== undefined, message);
  assert.ok(output !== undefined);
  return output;
}

/** Code mode wraps a host result as text between its status lines and any trailing prose. */
function hostResult(output: string): unknown {
  const start = output.indexOf("{");
  for (let end = output.lastIndexOf("}"); start >= 0 && end > start; end = output.lastIndexOf("}", end - 1)) {
    try { return JSON.parse(output.slice(start, end + 1)); } catch {}
  }
  return undefined;
}

const lines = (path: string) => readFile(path, "utf8").then((text) => text.split("\n").filter(Boolean), () => []);
const starts = async (path: string) => (await lines(path + ".started")).map((line) => {
  const [pid, host] = line.split(" "); return { pid: Number(pid), host };
});
const exists = (path: string) => stat(path).then(() => true, () => false);
const modelRequests = async (world: World, key: string) => (await lines(world.queue + ".requests")).filter((line) => {
  const request: unknown = JSON.parse(line); return object(request) && request.key === key;
}).length;
const attached = (world: World, client: ReturnType<World["start"]>) => world.until(async () =>
  world.events(client.output()).some((event) => event.type === "task_ready"), "The worker terminal must attach to its task", () => client.errors().slice(-2000));
const noTerminal = async (world: World, taskId: string, message: string) =>
  assert.deepEqual(await pidsMatching("run-task " + taskId), [], message);
async function mainCalls(world: World, key: string, step: ModelStep) {
  await world.script(key, [step, { text: `Finished ${key}.` }]);
  await world.cli(0, ["chat", key]);
}
const lingering = (path: string, output: string): ModelStep => ({ tool: "exec", args: { program: process.execPath, timeout_seconds: 60, args: ["-e",
  'const fs=require("node:fs"),path=process.argv[1];fs.appendFileSync(path+".started",process.pid+" "+process.env.AGENT_TEST_NODE_ID+"\\n");' +
  'fs.appendFileSync(path+".finished","once\\n");setTimeout(()=>process.stdout.write(process.argv[2]),500);', path, output] } });

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

async function mkfifo(path: string): Promise<void> { await promisify(execFile)("mkfifo", [path]); }

/**
 * Opening the read end releases a writer blocked in open(2).
 */
async function drainWrite(t: TestContext, world: World, pipe: string, length: number) {
  const reader = await open(pipe, constants.O_RDONLY | constants.O_NONBLOCK);
  t.after(() => reader.close());
  let written = "";
  await world.until(async () => {
    written += await available(reader);
    return written.length >= length || await toolOutputFor(world, pipe) !== undefined;
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
  const action = join(directory, "close-action"), pipe = join(directory, "close-pipe");
  const content = "Written once by the owning daemon.\n";
  const answer = "The closed terminal's turn finished.", followAnswer = "The queued follow-up ran without a terminal.";
  await mkfifo(pipe);
  const { task, worker, launch } = await laptopTask(world, "fixture-close-dispatch", "fixture-close-worker",
    [held(action), { tool: "write_file", args: { path: pipe, content } }, { text: answer }]);
  const terminal = runTask(world, launch, true);
  await until(async () => (await starts(action)).length === 1, "The worker's held exec did not start", () => terminal.output().slice(-2000));

  await script("fixture-close-followup", [{ text: followAnswer }]);
  await script("fixture-close-queue", [{ tool: "delegate_task", args: { task_id: task.id, input: "fixture-close-followup", mode: "follow_up" } },
    { text: "The follow-up is queued behind the held turn." }]);
  await cli(0, ["chat", "fixture-close-queue"]);

  terminal.child.kill("SIGKILL"); await terminal.exited;
  await until(async () => (await pidsMatching("run-task " + task.id)).length === 0, "Closing the PTY must hang up the worker's terminal client");

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
  const pipe = join(directory, "kill-pipe"), action = join(directory, "kill-action"), rex = join(homes[1], "rex.json");
  const content = "Written once after the client was killed.\n";
  const answer = "The killed client's turn finished.", laterAnswer = "The reopened terminal continues the same conversation.";
  await mkfifo(pipe);
  const { task, launch } = await laptopTask(world, "fixture-kill-dispatch", "fixture-kill-worker",
    [{ tool: "write_file", args: { path: pipe, content } }, held(action), { text: answer }]);
  const client = runTask(world, launch, false);
  // The FIFO has no reader yet, so the write cannot finish before the client is killed.
  await attached(world, client);
  await until(async () => await modelRequests(world, "fixture-kill-worker") === 1, "The model did not ask for the FIFO write");
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
  const execReceipt = await toolOutputFor(world, action); assert.ok(execReceipt !== undefined, "The model must receive the held exec's receipt");
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
  const stopped = join(directory, "stop-a"), running = join(directory, "stop-b");
  const runningAnswer = "The other actor finished its held exec.", resumedAnswer = "The stopped actor accepts new input.";
  const first = await laptopTask(world, "fixture-stop-dispatch-a", "fixture-stop-held-a", [held(stopped), { text: "A stopped action must not finish." }]);
  const second = await laptopTask(world, "fixture-stop-dispatch-b", "fixture-stop-held-b", [held(running), { text: runningAnswer }]);
  const stoppedTerminal = runTask(world, first.launch, true), runningClient = runTask(world, second.launch, false);
  await until(async () => (await starts(stopped)).length === 1 && (await starts(running)).length === 1, "Both held execs must start");
  const [stoppedStart] = await starts(stopped), [runningStart] = await starts(running);
  assert.ok(stoppedStart !== undefined && runningStart !== undefined);
  await until(async () => stoppedTerminal.output().includes("Working"), "The attached terminal must show the running turn", () => stoppedTerminal.output().slice(-2000));

  stoppedTerminal.child.stdin.write("\u001b");
  await until(async () => !alive(stoppedStart.pid), "Esc must stop the actor's held process", () => stoppedTerminal.output().slice(-2000));
  await writeFile(stopped + ".release", "A stopped action must remain stopped.");
  assert.equal(await exists(stopped + ".finished"), false, "A stopped effect must never finish");
  assert.ok(alive(runningStart.pid), "Stopping one actor must not touch another actor's held process");

  await writeFile(running + ".release", "Finish the other actor.");
  await until(async () => events(runningClient.output()).some((event) => event.type === "answer" && event.text === runningAnswer),
    "The other actor's turn must complete");
  assert.deepEqual(await lines(running + ".finished"), ["once"]);
  const runningReceipt = await toolOutputFor(world, running); assert.ok(runningReceipt !== undefined);
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
  const { launch } = await laptopTask(world, "fixture-offline-dispatch", "fixture-offline-worker", [{ text: "Ready for input." }]);
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
  const offline = await toolOutputFor(world, "offline-attempt"); assert.ok(offline !== undefined);
  assert.match(offline, /Tool call blocked: Workspace guidance is unavailable: [^\n]*no command was started/,
    "The model must be told the blocked command was not started\n" + offline);

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

test("a delegated task runs on its host with no pane attached", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, until } = world;
  const action = join(directory, "nopane-action"), answer = "The task finished with no pane.";
  const { task } = await laptopTask(world, "fixture-nopane-dispatch", "fixture-nopane-worker", [held(action), { text: answer }]);
  await until(async () => (await starts(action)).length === 1, "The delegated exec must start with no terminal attached");
  await writeFile(action + ".release", "Finish with no pane.");
  await until(async () => (await history(world, task.id)).some((message) => message.text === answer), "The turn must finish with no terminal attached");
  assert.equal((await history(world, task.id)).filter((message) => message.text === answer).length, 1, "The answer must be saved once");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The exec must start exactly once, on the laptop");
  assert.deepEqual(await lines(action + ".finished"), ["once"]);
  const execReceipt = await toolOutputFor(world, action); assert.ok(execReceipt !== undefined);
  assert.deepEqual(hostResult(execReceipt), heldReceipt, "The model must receive the exec's real output\n" + execReceipt);
  await noTerminal(world, task.id, "No terminal client may be needed to run delegated work");
});

test("input to an idle task whose terminal was killed runs on its host with no terminal", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { laptop, homes, events, until, script } = world;
  const followAnswer = "The follow-up ran after the terminal was killed.";
  const { task, launch } = await laptopTask(world, "fixture-idle-dispatch", "fixture-idle-worker", [{ text: "Ready for input." }]);
  const client = runTask(world, launch, false);
  await until(async () => events(client.output()).some((event) => event.type === "worker_idle"), "The worker terminal must become idle");
  client.child.kill("SIGKILL"); await client.exited;
  await until(async () => (await pidsMatching("run-task " + task.id)).length === 0, "The killed client must be gone");

  await script("fixture-idle-followup", [{ tool: "exec", args: { program: process.execPath, args: effect } }, { text: followAnswer }]);
  await mainCalls(world, "fixture-idle-send", { tool: "delegate_task", args: { task_id: task.id, input: "fixture-idle-followup" } });
  await until(async () => (await history(world, task.id)).some((message) => message.text === followAnswer),
    "The follow-up must be answered with no terminal attached");
  assert.equal((await history(world, task.id)).filter((message) => message.text === followAnswer).length, 1, "The follow-up must be answered once");
  assert.deepEqual((await lines(join(homes[1], "effects"))).map((line) => JSON.parse(line)), [{ host: laptop, cwd: homes[1] }],
    "The follow-up's command must run once on the laptop");
  assert.deepEqual(await lines(join(homes[0], "effects")), [], "The coordinator must never run the worker's command");
  assert.equal((await world.tasks()).find((candidate) => candidate.id === task.id)?.conversation_id, task.conversation_id);
  await noTerminal(world, task.id, "The follow-up must not need a terminal");
});

test("killing the client between an effect and its receipt still delivers the real output", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, events, until, script } = world;
  const action = join(directory, "gap-action"), output = "Completed after its client died.", answer = "The turn finished after its client died.";
  const { task, launch } = await laptopTask(world, "fixture-gap-dispatch", "fixture-gap-worker", [{ text: "Ready for input." }]);
  const client = runTask(world, launch, false);
  await until(async () => events(client.output()).some((event) => event.type === "worker_idle"), "The worker terminal must become idle");
  await script("fixture-gap-work", [lingering(action, output), { text: answer }]);
  client.child.stdin.write("fixture-gap-work\n");
  await until(async () => (await lines(action + ".finished")).length === 1, "The effect did not reach its finish line");
  client.child.kill("SIGKILL"); await client.exited;

  const execReceipt = await delivered(world, action, "The model never received the effect's receipt");
  assert.deepEqual(hostResult(execReceipt), { type: "process", exit_code: 0, stdout: output, stderr: "", truncated: false },
    "The model must receive the output of the effect that finished after its client died\n" + execReceipt);
  await until(async () => (await history(world, task.id)).some((message) => message.text === answer), "The turn must finish with no terminal attached");
  assert.equal((await history(world, task.id)).filter((message) => message.text === answer).length, 1, "The answer must be saved once");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The effect must start exactly once, on the laptop");
  assert.deepEqual(await lines(action + ".finished"), ["once"]);
});

test("two terminals on one task observe one actor", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, events, until } = world;
  const action = join(directory, "pair-action"), answer = "Both terminals saw this answer.";
  const { task, launch } = await laptopTask(world, "fixture-pair-dispatch", "fixture-pair-worker", [held(action), { text: answer }]);
  const first = runTask(world, launch, false), second = runTask(world, launch, false);
  await attached(world, first); await attached(world, second);
  await until(async () => (await starts(action)).length === 1, "The held exec did not start");
  await writeFile(action + ".release", "Finish while two terminals observe.");
  for (const client of [first, second]) {
    await until(async () => events(client.output()).some((event) => event.type === "answer" && event.text === answer),
      "Each attached terminal must print the final answer", () => client.errors().slice(-2000));
    assert.equal(events(client.output()).filter((event) => event.type === "answer" && event.text === answer).length, 1);
  }
  assert.equal(await modelRequests(world, "fixture-pair-worker"), 2, "One actor asks the model once per scripted step");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The exec must start exactly once, on the laptop");
  assert.deepEqual(await lines(action + ".finished"), ["once"]);
  assert.equal((await history(world, task.id)).filter((message) => message.text === answer).length, 1, "The answer must be saved once");
  for (const client of [first, second]) { client.child.stdin.end("/exit\n"); assert.equal(await client.exited, 0, client.errors()); }
});

test("a child agent's effect finishes on the laptop after its terminal is killed, and its result reaches the parent once", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, laptop, homes, until, script } = world;
  const action = join(directory, "child-action"), childAnswer = "The child finished its held exec.", parentAnswer = "The parent received the child's result.";
  await script("fixture-child-work", [held(action), { text: childAnswer }]);
  await script("Agent result (evidence", [{ text: parentAnswer }]);
  const { task } = await laptopTask(world, "fixture-family-dispatch", "fixture-family-worker", [
    { tool: "spawn_agent", args: { title: "Bounded review", outcome: "Run the held command", input: "fixture-child-work" } },
    { text: "The child is working." }]);
  await until(async () => (await starts(action)).length === 1, "The child's held exec did not start");
  const agent = async () => (await world.tasks()).find((candidate) => candidate.id === task.id)?.agents[0];
  await until(async () => (await agent())?.worker.state === "bound", "The child must get its own pane in the parent's session");
  const child = await agent(); assert.ok(child?.worker.state === "bound");
  const binding = child.worker.binding;
  const launch = sessions(join(homes[1], "rex.json")).find((session) => session.block_id === binding.block_id);
  assert.ok(launch, "The laptop's Rex must record the child's launch command");
  const terminal = runTask(world, launch, false);
  await attached(world, terminal);
  terminal.child.kill("SIGKILL"); await terminal.exited;

  await writeFile(action + ".release", "Finish after the child's terminal was killed.");
  await until(async () => (await history(world, task.id)).some((message) => message.text === parentAnswer),
    "The parent must answer the child's result with no terminal attached");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The child's exec must start exactly once, on the laptop");
  assert.deepEqual(await lines(action + ".finished"), ["once"]);
  const execReceipt = await toolOutputFor(world, action); assert.ok(execReceipt !== undefined);
  assert.deepEqual(hostResult(execReceipt), heldReceipt, "The child must receive its exec's real output\n" + execReceipt);
  assert.equal(await modelRequests(world, "Agent result (evidence"), 1, "The parent must be given the child's result once");
  assert.equal((await history(world, task.id)).filter((message) => message.text === parentAnswer).length, 1);
  const finished = (await world.tasks()).find((candidate) => candidate.id === task.id)?.agents[0];
  assert.equal(finished?.state.state, "done"); assert.equal(finished?.summary, childAnswer);
});

test("input for an offline host with no actor is kept, reported to its sender, and runs once when the host reconnects", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { coordinator, laptop, homes, start, until, online, script } = world;
  const followAnswer = "The kept input ran after the laptop reconnected.";
  const { task } = await laptopTask(world, "fixture-dark-dispatch", "fixture-dark-worker", [{ text: "Ready for input." }]);
  await until(async () => (await history(world, task.id)).some((message) => message.text === "Ready for input."), "The first turn must finish");

  world.worker.child.kill("SIGINT"); assert.equal(await world.worker.exited, 0, world.worker.errors()); await online([coordinator]);
  await script("fixture-dark-followup", [{ tool: "exec", args: { program: process.execPath, args: effect } }, { text: followAnswer }]);
  const sent = await world.exchange({ type: "task_input", task_id: task.id, input_id: "fixture-dark-input", input: "fixture-dark-followup", mode: "follow_up" });
  assert.ok(sent.some((event) => event.type === "input_accepted" && event.input_id === "fixture-dark-input"), "The input must be saved");
  assert.ok(sent.some((event) => event.type === "failure" && /is offline/.test(event.message)),
    "The sender must be told the owning host is offline\n" + JSON.stringify(sent));
  for (const home of homes) assert.deepEqual(await lines(join(home, "effects")), [], `No command may run in ${home} while the owning daemon is offline`);
  assert.equal(await modelRequests(world, "fixture-dark-followup"), 0, "The kept input must not start a turn while its host is offline");

  start(1, ["maintain"]); await online([coordinator, laptop]);
  await until(async () => (await history(world, task.id)).some((message) => message.text === followAnswer),
    "The kept input must run when its host reconnects, with no new input");
  assert.equal((await history(world, task.id)).filter((message) => message.text === followAnswer).length, 1, "The kept input must be answered once");
  assert.deepEqual((await lines(join(homes[1], "effects"))).map((line) => JSON.parse(line)), [{ host: laptop, cwd: homes[1] }],
    "The kept input's command must run once on the laptop");
  assert.deepEqual(await lines(join(homes[0], "effects")), [], "The coordinator must never run the worker's command");
  await noTerminal(world, task.id, "The kept input must not need a terminal");
});

test("a coordinator restart never reruns a held effect and still answers the queued follow-up", { timeout: 120_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, coordinator, laptop, socket, start, until, online, script } = world;
  const action = join(directory, "restart-action"), followAnswer = "The queued follow-up ran after the restart.";
  const { task } = await laptopTask(world, "fixture-restart-dispatch", "fixture-restart-worker",
    [held(action), { text: "The interrupted turn was reported." }]);
  await until(async () => (await starts(action)).length === 1, "The held exec did not start");
  await script("fixture-restart-followup", [{ text: followAnswer }]);
  await mainCalls(world, "fixture-restart-queue", { tool: "delegate_task", args: { task_id: task.id, input: "fixture-restart-followup", mode: "follow_up" } });

  world.server.child.kill("SIGINT"); await world.server.exited;
  start(0, ["serve", "--local-only", "--no-sources"]);
  await until(async () => { try { return (await stat(socket)).isSocket(); } catch { return false; } }, "The restarted coordinator must bind its socket");
  await online([coordinator, laptop]);

  await until(async () => (await history(world, task.id)).some((message) => message.text === followAnswer),
    "The queued follow-up must be answered after the restart with no terminal attached");
  assert.equal((await history(world, task.id)).filter((message) => message.text === followAnswer).length, 1, "The follow-up must be answered once");
  assert.deepEqual((await starts(action)).map((start) => start.host), [laptop], "The held exec must not start a second time");
  const interrupted = await toolOutputFor(world, action);
  assert.ok(interrupted === undefined || !interrupted.includes("Completed the held action."),
    "The model must not be given a success result for the effect the restart interrupted\n" + interrupted);
  assert.equal(await exists(action + ".finished"), false, "The interrupted effect must not finish");
  await noTerminal(world, task.id, "The queued follow-up must not need a terminal");
});

test("Esc from a reattached terminal stops its actor's held effect and no other actor's", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { directory, until } = world;
  const stopped = join(directory, "restop-a"), running = join(directory, "restop-b"), runningAnswer = "The other actor finished its held exec.";
  const first = await laptopTask(world, "fixture-restop-dispatch-a", "fixture-restop-held-a", [held(stopped), { text: "A stopped action must not finish." }]);
  const second = await laptopTask(world, "fixture-restop-dispatch-b", "fixture-restop-held-b", [held(running), { text: runningAnswer }]);
  const original = runTask(world, first.launch, false);
  await attached(world, original);
  await until(async () => (await starts(stopped)).length === 1 && (await starts(running)).length === 1, "Both held execs must start");
  const [stoppedStart] = await starts(stopped), [runningStart] = await starts(running);
  assert.ok(stoppedStart !== undefined && runningStart !== undefined);
  original.child.kill("SIGKILL"); await original.exited;
  await until(async () => (await pidsMatching("run-task " + first.task.id)).length === 0, "The killed client must be gone");
  assert.ok(alive(stoppedStart.pid), "Killing the terminal must not stop its actor's held process");

  const reattached = runTask(world, first.launch, true);
  await until(async () => reattached.output().includes("Working"), "The reattached terminal must show the running turn", () => reattached.output().slice(-2000));
  reattached.child.stdin.write("\u001b");
  await until(async () => !alive(stoppedStart.pid), "Esc from the reattached terminal must stop the actor's held process", () => reattached.output().slice(-2000));
  await writeFile(stopped + ".release", "A stopped action must remain stopped.");
  assert.equal(await exists(stopped + ".finished"), false, "A stopped effect must never finish");
  assert.ok(alive(runningStart.pid), "Stopping one actor must not touch another actor's held process");

  await writeFile(running + ".release", "Finish the other actor.");
  await until(async () => (await history(world, second.task.id)).some((message) => message.text === runningAnswer), "The other actor's turn must complete");
  assert.deepEqual(await lines(running + ".finished"), ["once"]);
  const runningReceipt = await toolOutputFor(world, running); assert.ok(runningReceipt !== undefined);
  assert.deepEqual(hostResult(runningReceipt), heldReceipt, "The other actor must receive its real receipt\n" + runningReceipt);
});
