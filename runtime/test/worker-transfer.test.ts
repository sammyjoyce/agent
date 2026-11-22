import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdir, mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, type Context } from "@earendil-works/pi-ai";
import { getSystemMessageText } from "@earendil-works/pi-ai/utils/text";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AllocationDecisionEntry, TaskTransferEntry } from "../src/allocation.js";
import { CoordinatorEnvironment } from "../src/environment.js";
import { HistoryStore } from "../src/history.js";
import { ConversationModels } from "../src/models.js";
import { createResourceTools, ResourceStore } from "../src/resources.js";
import { TaskStore } from "../src/tasks.js";
import { createAppTools, Executions } from "../src/tools.js";
import { history, transcript } from "../src/transcript.js";
import type { AgentNode } from "../src/generated/AgentNode.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { ResourceRecord } from "../src/generated/ResourceRecord.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import type { WorktreeAllocation } from "../src/generated/WorktreeAllocation.js";
import { coordinatorWorld, delegate, exec } from "./fixtures/coordinator-world.js";
import { fixtureModel } from "./model.js";

const hostA = "11111111-1111-4111-8111-111111111111";
const hostB = "22222222-2222-4222-8222-222222222222";

function node(host_id: string, name: string, home_directory: string): AgentNode {
  return {
    host_id,
    name,
    rex_server: null,
    coordinator: null,
    home_directory,
    agent_program: "/example/agent",
    machine: null,
    launch: { model: fixtureModel, state_dir: null, runtime: null, config: null, instructions: null },
  };
}

function bindingFor(host_id: string, suffix: string): WorkerRef {
  return {
    host_id,
    session_id: `session:${suffix}`,
    window_id: `window:${suffix}`,
    block_id: `block:${suffix}`,
  };
}

function readyResource(request: WorktreeAllocation): ResourceRecord {
  return {
    id: request.allocation_id,
    host_id: request.host_id,
    task_id: request.task_id,
    repository: request.repository,
    branch: request.branch,
    consumers: [],
    state: {
      state: "ready",
      identity: {
        primary: request.repository,
        top: `${request.repository}-${request.branch}`,
        common_dir: `${request.repository}/.git`,
        git_dir: `${request.repository}/.git/worktrees/${request.branch}`,
        branch: request.branch,
        head: "abc123",
      },
    },
  };
}

async function openHarness(directory: string) {
  const database = await openNodeSqliteDatabase(join(directory, "session.sqlite"));
  await database.exec("PRAGMA synchronous = FULL");
  const storage = await SqliteStorage.open(database);
  const models = createModels();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const registry = createRegistry();
  const session = await Harness.open(storage, {
    models,
    registry,
    identity: { attribution: null },
    settings: { retry: { enabled: false }, compaction: { enabled: false } },
  }, BACKGROUND_CONTEXT);
  const inference = new ConversationModels(models);
  const tasks = new TaskStore(session, inference);
  const resources = new ResourceStore(session, tasks);
  tasks.guardResources(resources);
  const environment = new CoordinatorEnvironment(session);
  tasks.useEnvironment(environment);
  const executions = new Executions();
  const appTools = createAppTools(tasks, executions);
  const resourceTools = createResourceTools(resources, tasks, executions);
  registry.install(appTools.host);
  registry.install(appTools.main);
  registry.install(appTools.worker);
  registry.install(appTools.agent);
  registry.install(resourceTools.main);
  registry.install(resourceTools.worker);
  return { session, tasks, resources, environment, executions, appTools, resourceTools, faux };
}

test("offline worker transfer preserves conversation, child agent and resource lineage across reopen and refuses unsafe transfers", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-transfer-"));
  let app = await openHarness(directory);
  const nodeA = node(hostA, "old-box", "/old/workspace");
  const nodeB = node(hostB, "new-box", "/new/workspace");
  try {
    await app.environment.configure({
      node: nodeA,
      settings: { model: fixtureModel, instructions: "", context_repositories: [], sources: [] },
    });
    await app.environment.register(nodeB);
    app.environment.setConnected([hostA, hostB]);

    const bindingA = bindingFor(hostA, "aaaa0000-0000-4000-8000-000000000001");
    const bindingChildA = { ...bindingA, block_id: "block:aaaa0000-0000-4000-8000-000000000002" };
    const bindingSiblingA = { ...bindingA, block_id: "block:aaaa0000-0000-4000-8000-000000000003" };
    const bindingB = bindingFor(hostB, "bbbb0000-0000-4000-8000-000000000001");
    const bindingChildB = { ...bindingB, block_id: "block:bbbb0000-0000-4000-8000-000000000002" };

    const callOn = async (command: HostCommand): Promise<HostResult> => {
      if (command.type === "on_node" && command.command.type === "inspect_worker") {
        return { type: "worker_presence", presence: { state: "present", running: true } };
      }
      if (command.type === "spawn_workspace_worker") {
        assert.ok(command.host.host_id);
        return { type: "spawned", binding: command.host.host_id === hostA ? bindingA : bindingB };
      }
      if (command.type === "spawn_subagent") {
        return { type: "spawned", binding: command.parent.host_id === hostA ? bindingChildA : bindingChildB };
      }
      if (command.type === "resource_allocate") {
        return { type: "resource", report: { type: "observed", record: readyResource(command.request) } };
      }
      if (command.type === "resource_inspect") {
        return { type: "resource", report: { type: "observed", record: command.record } };
      }
      if (command.type === "resource_plan_cleanup") {
        const identity = "identity" in command.record.state ? command.record.state.identity : null;
        assert.ok(identity);
        const plan = { id: randomUUID(), resource_id: command.record.id, identity, path: identity.top, fingerprint: "fp" };
        return {
          type: "resource",
          report: { type: "planned", record: { ...command.record, state: { state: "retiring", identity, plan_id: plan.id } }, plan },
        };
      }
      if (command.type === "resource_collect") {
        return {
          type: "resource",
          report: {
            type: "collected",
            record: { ...command.record, state: { state: "removed", identity: command.plan.identity } },
            receipt: {
              status: "removed",
              worktree_removed: true,
              branch_deleted: command.record.branch,
              primary_worktree: command.plan.identity.primary,
              retained_submodules: null,
              summary: "Removed",
            },
          },
        };
      }
      return { type: "written" };
    };

    const unassigned = await app.tasks.create({ title: "Unassigned", outcome: "Cannot transfer before binding" });
    await assert.rejects(app.tasks.transferTask(unassigned.id, "new-box", callOn), /not bound to an offline host/);

    const job = await app.tasks.create({ title: "Job", outcome: "Job stays on coordinator", job_id: "nightly" });
    await assert.rejects(app.tasks.transferTask(job.id, "new-box", callOn), /Scheduled job tasks/);

    const sibling = await app.tasks.create({ title: "Sibling on A", outcome: "Stay on host A" });
    await app.tasks.dispatch(sibling.id, { host_id: hostA, name: "old-box", rex_server: null, coordinator: null, cwd: "/old/workspace", agent_program: "/example/agent" }, callOn);

    const task = await app.tasks.create({ title: "Transferable task", outcome: "Finish migration work", model: fixtureModel });
    await app.tasks.dispatch(task.id, { host_id: hostA, name: "old-box", rex_server: null, coordinator: null, cwd: "/old/workspace", agent_program: "/example/agent" }, callOn);
    const boundA = await app.tasks.get(task.id);
    assert.ok(boundA.worker.state === "bound");

    app.faux.setResponses([fauxAssistantMessage("Initial turn finished on old-box.")]);
    await app.tasks.enqueue(task.id, "Start on old-box");
    const firstTurn = await app.tasks.run({
      type: "run_task",
      task_id: task.id,
      allocation_id: boundA.worker.allocation_id,
      binding: bindingA,
      instructions: "Task rules",
      model: fixtureModel,
      cwd: "/old/workspace",
      interactive: false,
    }, () => () => {}, []);
    assert.equal(firstTurn.text, "Initial turn finished on old-box.");

    const resourceA = await app.resources.allocate({
      host_id: hostA,
      task_id: task.id,
      allocation_id: randomUUID(),
      repository: "/old/repo",
      branch: "feat-transfer",
    }, callOn);
    assert.equal(resourceA.state.state, "ready");

    const child = await app.tasks.createAgent(task.id, {
      id: "review",
      title: "Review branch",
      outcome: "Verify diffs",
      input: "Inspect old-box changes first",
      inputId: "child-1",
      model: fixtureModel,
    });
    await app.tasks.dispatchAgent(task.id, child.id, callOn);

    // Online host cannot be transferred.
    await assert.rejects(app.tasks.transferTask(task.id, "new-box", callOn), /while it is online/);

    // Enqueue work for the task while host A goes offline.
    await app.tasks.enqueue(task.id, "Continue this work after transfer");
    app.environment.setConnected([hostB]);

    // Refuses offline, unknown, or self target hosts.
    await assert.rejects(app.tasks.transferTask(task.id, "old-box", callOn), /Choose a connected worker host/);
    await assert.rejects(app.tasks.transferTask(task.id, "missing", callOn), /Choose a connected worker host/);

    // Temporary spawn failure on target still cleanly detaches offline host A without losing history or resources.
    await assert.rejects(app.tasks.transferTask(task.id, "new-box", async () => ({
      type: "not_started",
      message: "Temporary dial timeout",
    }), "/srv/new-work"), /did not start/);
    const detached = await app.tasks.get(task.id);
    assert.equal(detached.worker.state, "unassigned");
    assert.equal(detached.agents[0]?.worker.state, "unassigned");

    // Re-bind to offline hostA? No, test standard bound -> offline -> transferred directly on a fresh bound task too,
    // and verify the already-transferred task finishes cleanly via dispatch on hostB.
    await app.tasks.dispatch(task.id, { host_id: hostB, name: "new-box", rex_server: null, coordinator: null, cwd: "/srv/new-work", agent_program: "/example/agent" }, callOn);

    app.environment.setConnected([hostA, hostB]);
    const direct = await app.tasks.create({ title: "Direct offline transfer", outcome: "Carry full lineage", model: fixtureModel });
    await app.tasks.dispatch(direct.id, { host_id: hostA, name: "old-box", rex_server: null, coordinator: null, cwd: "/old/workspace", agent_program: "/example/agent" }, callOn);
    const directBefore = await app.tasks.get(direct.id);
    assert.ok(directBefore.worker.state === "bound");
    const directResourceA = await app.resources.allocate({
      host_id: hostA,
      task_id: direct.id,
      allocation_id: randomUUID(),
      repository: "/old/direct-repo",
      branch: "feat-direct",
    }, callOn);
    const directChild = await app.tasks.createAgent(direct.id, {
      id: "audit",
      title: "Audit",
      outcome: "Complete audit on transferred host",
      input: "Check repo",
      inputId: "audit-1",
      model: fixtureModel,
    });
    await app.tasks.dispatchAgent(direct.id, directChild.id, callOn);
    await app.tasks.enqueue(direct.id, "Resume directly on new-box");
    app.environment.setConnected([hostB]);

    const transferred = await app.tasks.transferTask(direct.id, "new-box", callOn, "/srv/direct-new");
    assert.equal(transferred.id, direct.id);
    assert.equal(transferred.conversation_id, direct.conversation_id);
    assert.ok(transferred.worker.state === "bound");
    assert.equal(transferred.worker.binding.host_id, hostB);
    assert.equal(transferred.worker.host.cwd, "/srv/direct-new");
    assert.equal(transferred.pending[0]?.content, "Resume directly on new-box");
    const transferredChild = transferred.agents[0];
    assert.equal(transferredChild?.id, directChild.id);
    assert.equal(transferredChild?.conversation_id, directChild.conversation_id);
    assert.ok(transferredChild?.worker.state === "bound");
    assert.equal(transferredChild.worker.binding.host_id, hostB);
    assert.equal(transferredChild.worker.binding.session_id, bindingB.session_id);
    assert.equal(transferredChild.pending[0]?.content, "Check repo");

    // Sibling still on offline hostA stays untouched.
    const siblingAfter = await app.tasks.get(sibling.id);
    assert.ok(siblingAfter.worker.state === "bound" && siblingAfter.worker.binding.host_id === hostA);

    // Late claim from offline old-box using old allocation/binding is refused.
    await assert.rejects(app.tasks.run({
      type: "run_task",
      task_id: direct.id,
      allocation_id: directBefore.worker.allocation_id,
      binding: bindingA,
      instructions: "",
      model: fixtureModel,
      cwd: "/old/workspace",
      interactive: false,
    }, () => () => {}), /binding is not confirmed/);

    // Reopen SQLite and run on hostB, verifying conversation, transfer notice, model lineage instructions, child resumption, and resources.
    await app.session.close(BACKGROUND_CONTEXT);
    app = await openHarness(directory);
    await app.environment.configure({
      node: nodeA,
      settings: { model: fixtureModel, instructions: "", context_repositories: [], sources: [] },
    });
    await app.environment.register(nodeB);
    app.environment.setConnected([hostB]);

    const conversation = await app.tasks.conversation(direct.conversation_id);
    const entries = (await conversation.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items;
    const decisions = entries.filter(AllocationDecisionEntry.is);
    assert.ok(decisions.some((entry) => entry.data.operation === "transfer" && entry.data.previous.state === "bound" &&
      entry.data.previous.binding.host_id === hostA && entry.data.current.state === "unassigned"));
    const transferEntries = entries.filter(TaskTransferEntry.is);
    assert.equal(transferEntries.length, 1);
    const noticeRows = transcript(transferEntries[0]!);
    assert.equal(noticeRows[0]?.role, "notice");
    assert.match(noticeRows[0]?.text ?? "", /old-box.*new-box/);
    assert.match(noticeRows[0]?.text ?? "", /feat-direct/);

    const visibleHistory = (await history(conversation, null, new HistoryStore(app.session))).flatMap((frame) => frame.messages);
    assert.ok(visibleHistory.some((msg) => msg.role === "notice" && msg.text.includes("Transferred task from offline host old-box")));

    const reopenedChildConversation = await app.tasks.conversation(directChild.conversation_id);
    const childDecisions = (await reopenedChildConversation.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items
      .filter(AllocationDecisionEntry.is);
    assert.ok(childDecisions.some((entry) => entry.data.operation === "transfer" && entry.data.agent_id === directChild.id));

    let seenInstructions = "";
    let seenCwd = "";
    app.faux.setResponses([(context: Context) => {
      seenInstructions = context.messages
        .filter((message) => message.role === "system")
        .map((message) => getSystemMessageText(message))
        .join("\n");
      return fauxAssistantMessage("Continued safely on new-box.");
    }]);
    const resumedRun = await app.tasks.run({
      type: "run_task",
      task_id: direct.id,
      allocation_id: transferred.worker.allocation_id,
      binding: bindingB,
      instructions: "Run on new host.",
      model: fixtureModel,
      cwd: "/srv/direct-new",
      interactive: false,
    }, (conv, workerHost) => {
      seenCwd = workerHost.cwd;
      return app.executions.bind(conv.id.toString(), { cwd: workerHost.cwd, hosts: [workerHost], call: callOn });
    }, [app.appTools.worker, app.resourceTools.worker]);
    assert.equal(resumedRun.text, "Continued safely on new-box.");
    assert.equal(seenCwd, "/srv/direct-new");
    assert.match(seenInstructions, /Execution host transfer lineage:/);
    assert.match(seenInstructions, /old-box/);
    assert.match(seenInstructions, /feat-direct/);

    // Child agent resumes cleanly in new hostB session with exact conversation history preserved.
    const childAfter = await app.tasks.continueAgent(direct.id, directChild.id, "Finish on new-box", "audit-2", callOn);
    assert.ok(childAfter.agents[0]?.worker.state === "bound");
    assert.equal(childAfter.agents[0]?.worker.binding.host_id, hostB);
    assert.equal(childAfter.agents[0]?.worker.binding.session_id, bindingB.session_id);
    assert.equal(childAfter.agents[0]?.conversation_id, directChild.conversation_id);
    app.faux.setResponses([
      fauxAssistantMessage("Checked repo."),
      fauxAssistantMessage("Finished audit on new-box."),
    ]);
    await app.tasks.run({
      type: "run_task",
      task_id: direct.id,
      agent_id: directChild.id,
      allocation_id: childAfter.agents[0]!.worker.allocation_id,
      binding: bindingChildB,
      instructions: "Child rules",
      model: fixtureModel,
      cwd: "/srv/direct-new",
      interactive: false,
    }, (conv, workerHost) => app.executions.bind(conv.id.toString(), { cwd: workerHost.cwd, hosts: [workerHost], call: callOn }));
    await app.tasks.reportAgent(direct.id, directChild.id, "Audit completed on new-box");

    // Allocate a second worktree on new-box; both hostA and hostB resources preserve lineage under direct.id.
    const directResourceB = await app.resources.allocate({
      host_id: hostB,
      task_id: direct.id,
      allocation_id: randomUUID(),
      repository: "/srv/new-repo",
      branch: "feat-direct-b",
    }, callOn);
    assert.equal(directResourceB.host_id, hostB);
    const inventoryBeforeResolve = await app.resources.list();
    assert.equal(inventoryBeforeResolve.find((r) => r.id === directResourceA.id)?.host_id, hostA);
    assert.equal(inventoryBeforeResolve.find((r) => r.id === directResourceB.id)?.host_id, hostB);

    // Parent worker consumes the child agent's result on new-box before resolving.
    app.faux.setResponses([fauxAssistantMessage("Verified audit on new-box.")]);
    await app.tasks.run({
      type: "run_task",
      task_id: direct.id,
      allocation_id: transferred.worker.allocation_id,
      binding: bindingB,
      instructions: "Run on new host.",
      model: fixtureModel,
      cwd: "/srv/direct-new",
      interactive: false,
    }, (conv, workerHost) => app.executions.bind(conv.id.toString(), { cwd: workerHost.cwd, hosts: [workerHost], call: callOn }),
    [app.appTools.worker, app.resourceTools.worker]);

    // Resolve task -> hostB cleans up directResourceB while hostA retains directResourceA until hostA reconnects.
    await app.tasks.update(direct.id, (saved) => {
      saved.state = { state: "resolved", evidence: "Finished on new-box" };
    });
    await app.resources.collect(hostB, callOn);
    const afterHostBCollect = await app.resources.list();
    assert.equal(afterHostBCollect.find((r) => r.id === directResourceB.id)?.state.state, "removed");
    assert.equal(afterHostBCollect.find((r) => r.id === directResourceA.id)?.state.state, "ready");

    await app.resources.collect(hostA, callOn);
    const afterHostACollect = await app.resources.list();
    assert.equal(afterHostACollect.find((r) => r.id === directResourceA.id)?.state.state, "removed");
  } finally {
    await app.session.close(BACKGROUND_CONTEXT);
    await rm(directory, { recursive: true, force: true });
  }
});

test("CLI `tasks transfer` and main `transfer_task` tool move an offline worker task onto another online host and preserve conversation history", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { coordinator, laptop, homes, cli, online, script, tasks, until } = world;
  const targetDir = await realpath(homes[0]);
  const transferredCwd = join(targetDir, "transferred-cwd");
  await mkdir(transferredCwd, { recursive: true });

  await script("transfer-cli-work", [exec, { text: "Ran step one on laptop." }]);
  await script("dispatch-transfer-cli", [delegate("transfer-cli-work", laptop), { text: "Delegated to laptop." }]);
  await cli(0, ["chat", "dispatch-transfer-cli"]);

  const initialTask = (await tasks()).find((item) => item.title === "transfer-cli-work");
  assert.ok(initialTask?.worker.state === "bound" && initialTask.worker.binding.host_id === laptop);
  await until(async () => {
    const log = await readFile(join(homes[1], "effects"), "utf8").catch(() => "");
    return log.includes(laptop);
  }, "The task must run its first step on laptop");

  // Wait until initial task turn goes idle before stopping worker.
  await until(async () => {
    const read = (await cli(0, ["tasks", "read", initialTask.id])).find((e) => e.type === "task");
    return read?.type === "task" && read.history.includes("Ran step one on laptop.");
  }, "Initial task history must be committed");

  // Take laptop offline.
  world.worker.child.kill("SIGINT");
  assert.equal(await world.worker.exited, 0, world.worker.errors());
  await online([coordinator]);

  // Continuing on desktop via delegate_task without explicit transfer is refused.
  await script("refuse-silent-takeover", [{
    tool: "delegate_task",
    args: { task_id: initialTask.id, host: coordinator, input: "Must refuse implicit host change" },
  }, { text: "Handled refusal." }]);
  await cli(0, ["chat", "refuse-silent-takeover"]);
  const stillOnLaptop = (await tasks()).find((item) => item.id === initialTask.id);
  assert.ok(stillOnLaptop?.worker.state === "bound" && stillOnLaptop.worker.binding.host_id === laptop);

  // Explicit CLI transfer onto desktop with a target working directory.
  const transferEvents = await cli(0, ["tasks", "transfer", initialTask.id, "--host", "desktop", "--cwd", transferredCwd]);
  const transferEvent = transferEvents.find((event) => event.type === "task");
  assert.ok(transferEvent?.type === "task", "CLI transfer must emit the updated task receipt");
  assert.equal(transferEvent.task.id, initialTask.id);
  assert.equal(transferEvent.task.conversation_id, initialTask.conversation_id);
  assert.ok(transferEvent.task.worker.state === "bound");
  assert.equal(transferEvent.task.worker.binding.host_id, coordinator);
  assert.equal(transferEvent.task.worker.host.cwd, transferredCwd);
  assert.match(transferEvent.history, /Ran step one on laptop\./);
  assert.match(transferEvent.history, /Transferred task from offline host laptop/);

  // Continue the exact same task on desktop; verify effects run on desktop in transferredCwd.
  await script("continue-after-transfer", [exec, { text: "Ran step two on desktop." }]);
  await cli(0, ["tasks", "send", initialTask.id, "continue-after-transfer"]);
  await until(async () => {
    const log = await readFile(join(homes[0], "effects"), "utf8").catch(() => "");
    return log.includes(transferredCwd);
  }, "Continued work must run on desktop in the transferred working directory");
  const afterRead = (await cli(0, ["tasks", "read", initialTask.id])).find((e) => e.type === "task");
  assert.ok(afterRead?.type === "task");
  assert.match(afterRead.history, /Ran step one on laptop\./);
  assert.match(afterRead.history, /Transferred task from offline host laptop/);
  assert.match(afterRead.history, /Ran step two on desktop\./);
});

test("main agent discovers and runs transfer_task via tool_search to move an offline host task onto another online host", { timeout: 90_000 }, async (t) => {
  const world = await coordinatorWorld(t);
  const { coordinator, laptop, homes, cli, online, script, tasks, until } = world;
  const targetDir = await realpath(homes[0]);
  const transferCwd = join(targetDir, "tool-transferred-cwd");
  await mkdir(transferCwd, { recursive: true });

  await script("tool-transfer-task", [exec, { text: "Step one ran on laptop." }]);
  await script("dispatch-tool-transfer", [delegate("tool-transfer-task", laptop), { text: "Dispatched to laptop." }]);
  await cli(0, ["chat", "dispatch-tool-transfer"]);

  const initial = (await tasks()).find((item) => item.title === "tool-transfer-task");
  assert.ok(initial?.worker.state === "bound" && initial.worker.binding.host_id === laptop);
  await until(async () => {
    const read = (await cli(0, ["tasks", "read", initial.id])).find((e) => e.type === "task");
    return read?.type === "task" && read.history.includes("Step one ran on laptop.");
  }, "Initial task turn must complete on laptop");

  world.worker.child.kill("SIGINT");
  assert.equal(await world.worker.exited, 0, world.worker.errors());
  await online([coordinator]);

  await script("continue-after-tool-transfer", [exec, { text: "Continued via transfer_task tool." }]);
  await script("main-transfer-offline", [
    { tool: "tool_search", args: { query: "transfer_task" } },
    { tool: "transfer_task", args: { task_id: initial.id, host: "desktop", cwd: transferCwd } },
    { tool: "delegate_task", args: { task_id: initial.id, input: "continue-after-tool-transfer" } },
    { text: "Transferred and continued the task on desktop." },
  ]);
  await cli(0, ["chat", "main-transfer-offline"]);

  await until(async () => {
    const log = await readFile(join(homes[0], "effects"), "utf8").catch(() => "");
    return log.includes(transferCwd);
  }, "Queued task input must execute on desktop in the transferred working directory");
  const updated = (await tasks()).find((item) => item.id === initial.id);
  assert.ok(updated?.worker.state === "bound" && updated.worker.binding.host_id === coordinator);
  assert.equal(updated.conversation_id, initial.conversation_id);
  const read = (await cli(0, ["tasks", "read", initial.id])).find((e) => e.type === "task");
  assert.ok(read?.type === "task");
  assert.match(read.history, /Step one ran on laptop\./);
  assert.match(read.history, /Continued via transfer_task tool\./);
});
