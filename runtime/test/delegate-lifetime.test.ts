import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import { attachMainAndSpawnedWorkers, binding, heldCall, host, open, scriptActors, within, type App } from "./delegation.js";
import { fixtureModel } from "./model.js";

const delegate = fauxAssistantMessage(fauxToolCall("delegate_task", { input: "Inspect the board repository", title: "Board review",
  outcome: "Verify the board change" }), { stopReason: "toolUse" });
const spawnAgent = fauxAssistantMessage(fauxToolCall("spawn_agent", { title: "Review", outcome: "Review the bounded change",
  input: "Review the bounded change" }), { stopReason: "toolUse" });

async function finished(app: App, answers: readonly string[]): Promise<TaskRecord> {
  await within((async () => {
    while (!answers.includes("Finished after the review.")) await new Promise<void>((resolve) => setTimeout(resolve, 10));
  })(), "The delegate must finish after its child agent reports");
  const task = (await app.tasks.list())[0]; assert.ok(task);
  return task;
}

test("delegate_task and spawn_agent return while the delegate and its child agent still work", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-delegate-return-")); const app = await open(directory);
  const controller = new AbortController(); let main: Awaited<ReturnType<typeof attachMainAndSpawnedWorkers>> | undefined;
  const delegateTurn = heldCall("Board inspected."), childTurn = heldCall("Review complete.");
  try {
    main = await attachMainAndSpawnedWorkers(app, controller.signal);
    scriptActors(app.faux, {
      "Start the board review": [delegate, fauxAssistantMessage("Delegated the board review.")],
      "Inspect the board repository": [spawnAgent, delegateTurn.step, fauxAssistantMessage("Finished after the review.")],
      "Review the bounded change": [childTurn.step],
    });
    const turn = await main.root.submit({ type: "input", content: "Start the board review" }, BACKGROUND_CONTEXT);
    await within(childTurn.started, "The child agent must start its assignment");
    await within(delegateTurn.started, "spawn_agent must return before its child agent goes idle");
    const settled = await within(turn.wait(BACKGROUND_CONTEXT), "delegate_task must return before its delegate goes idle");
    assert.equal(settled.status, "done");
    await within(main.root.waitForIdle(BACKGROUND_CONTEXT), "Main must be idle while its delegate still works");
    const working = (await app.tasks.list())[0]; assert.ok(working);
    assert.equal(app.tasks.isRunning(working.id), true);
    assert.equal(delegateTurn.aborted, false); assert.equal(childTurn.aborted, false);
    childTurn.release(); delegateTurn.release();
    const task = await finished(app, main.answers);
    assert.equal(task.agents[0]?.state.state, "done"); assert.equal(task.agents[0]?.summary, "Review complete.");
    assert.deepEqual(main.failures, []);
  } finally {
    childTurn.release(); delegateTurn.release(); controller.abort(); await main?.detach();
    await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true });
  }
});

test("interrupting main leaves its running delegate and that delegate's child agent working", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-delegate-interrupt-")); const app = await open(directory);
  const controller = new AbortController(); let main: Awaited<ReturnType<typeof attachMainAndSpawnedWorkers>> | undefined;
  const mainTurn = heldCall("Discarded main answer."), delegateTurn = heldCall("Board inspected."), childTurn = heldCall("Review complete.");
  try {
    main = await attachMainAndSpawnedWorkers(app, controller.signal);
    scriptActors(app.faux, {
      "Start the board review": [delegate, mainTurn.step],
      "Inspect the board repository": [spawnAgent, delegateTurn.step, fauxAssistantMessage("Finished after the review.")],
      "Review the bounded change": [childTurn.step],
    });
    const turn = await main.root.submit({ type: "input", content: "Start the board review" }, BACKGROUND_CONTEXT);
    await within(Promise.all([delegateTurn.started, childTurn.started]), "The delegate and its child agent must be working before the interrupt");
    await within(main.root.abort(BACKGROUND_CONTEXT), "The main interrupt must drain main's own work");
    assert.notEqual((await turn.wait(BACKGROUND_CONTEXT)).status, "done");
    assert.equal(delegateTurn.aborted, false, "Interrupting main must not abort its running delegate");
    assert.equal(childTurn.aborted, false, "Interrupting main must not abort a delegate's running child agent");
    const working = (await app.tasks.list())[0]; assert.ok(working);
    assert.equal(app.tasks.isRunning(working.id), true);
    childTurn.release(); delegateTurn.release();
    const task = await finished(app, main.answers);
    assert.equal(task.agents[0]?.state.state, "done"); assert.equal(task.agents[0]?.summary, "Review complete.");
    assert.deepEqual([...main.answers].sort(), ["Board inspected.", "Finished after the review.", "Review complete."]);
    assert.deepEqual(main.failures, []);
  } finally {
    mainTurn.release(); childTurn.release(); delegateTurn.release(); controller.abort(); await main?.detach();
    await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true });
  }
});

async function killedDuring(moment: "spawning" | "working", directory: string): Promise<Pick<TaskRecord, "conversation_id" | "worker"> & { task_id: string }> {
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/delegate-restart-child.js", import.meta.url)), directory, moment],
    { stdio: ["ignore", "pipe", "pipe"] });
  let errors = "";
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });
  const lines = createInterface({ input: child.stdout });
  try {
    const first = await within(Promise.race([lines[Symbol.asyncIterator]().next(),
      new Promise<never>((_resolve, reject) => child.once("close", () => reject(new Error("The coordinator fixture exited early: " + errors))))]),
    "The coordinator fixture must reach its kill point", 20_000);
    return JSON.parse(String(first.value));
  } finally {
    child.kill("SIGKILL");
    await new Promise<void>((resolve) => { if (child.exitCode !== null || child.signalCode !== null) resolve(); else child.once("close", () => resolve()); });
    lines.close();
  }
}
async function reopened(directory: string): Promise<App> {
  const app = await open(directory);
  scriptActors(app.faux, {
    "Start the board review": [fauxAssistantMessage("Delegated the board review.")],
    "Inspect the board repository": [fauxAssistantMessage("Recovered the delegated work.")],
  });
  return app;
}
async function delegatedInputs(app: App, task: TaskRecord): Promise<number> {
  const conversation = await app.tasks.conversation(task.conversation_id);
  const page = await conversation.entries({}, 100, undefined, BACKGROUND_CONTEXT);
  return page.items.filter((entry) => entry.model?.some((message) => message.role === "user")).length;
}

test("a delegate keeps its conversation, allocation and Rex binding when the coordinator is killed during its turn", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-delegate-restart-")); let app: App | undefined;
  try {
    const before = await killedDuring("working", directory);
    app = await reopened(directory);
    const task = await app.tasks.get(before.task_id);
    assert.equal(task.conversation_id, before.conversation_id); assert.deepEqual(task.worker, before.worker);
    assert.ok(task.worker.state === "bound");
    const recovered = await within(app.tasks.run({ type: "run_task", task_id: task.id, allocation_id: task.worker.allocation_id,
      binding: task.worker.binding, instructions: "", model: fixtureModel, cwd: host.cwd }, () => () => {}),
    "The reattached delegate must finish the turn it was running");
    assert.equal(recovered.text, "Recovered the delegated work."); assert.equal(recovered.conversation_id, before.conversation_id);
    assert.equal(await delegatedInputs(app, task), 1, "The restart must not admit the delegated input a second time");
    assert.deepEqual((await app.tasks.get(task.id)).worker, before.worker);
  } finally {
    if (app !== undefined) await app.session.close(BACKGROUND_CONTEXT);
    await rm(directory, { recursive: true, force: true });
  }
});

test("a delegate keeps its conversation, allocation and delegated input when the coordinator is killed during delegate_task", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-delegate-restart-")); let app: App | undefined;
  try {
    const before = await killedDuring("spawning", directory);
    assert.ok(before.worker.state === "allocating");
    app = await reopened(directory);
    const task = await app.tasks.get(before.task_id);
    assert.equal(task.conversation_id, before.conversation_id); assert.deepEqual(task.worker, before.worker);
    assert.deepEqual(task.pending.map((input) => input.content), ["Inspect the board repository"]);
    // A session-less workspace claim cannot be discarded through task revocation.
    // The exact original worker must positively prove its native presence.
    const recovered = await within(app.tasks.run({ type: "run_task", task_id: task.id, allocation_id: before.worker.allocation_id,
      binding, instructions: "", model: fixtureModel, cwd: host.cwd }, () => () => {}, [],
      async () => ({ type: "worker_presence", presence: { state: "present", running: true } })),
    "The delegate must run the input that delegate_task admitted before the kill");
    assert.equal(recovered.text, "Recovered the delegated work."); assert.equal(recovered.conversation_id, before.conversation_id);
    assert.equal(await delegatedInputs(app, task), 1);
  } finally {
    if (app !== undefined) await app.session.close(BACKGROUND_CONTEXT);
    await rm(directory, { recursive: true, force: true });
  }
});
