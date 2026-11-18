// Opt-in acceptance: an explicitly isolated Rex endpoint and compiled Executor
// bridge are required. No model providers or real task inputs are exercised.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxProvider } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { TaskStore } from "../src/tasks.js";
import { fixtureModel } from "./model.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { ConversationModels } from "../src/models.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";

test("real workspace dispatch persists sibling and child grouping across SQLite reopen", {
  skip: !process.env.AGENT_TEST_WORKSPACE_BRIDGE, timeout: 60_000,
}, async () => {
  const state = process.env.AGENT_TEST_WORKSPACE_STATE!;
  const bridge = spawn(process.env.AGENT_TEST_WORKSPACE_BRIDGE!, [], { stdio: ["pipe", "pipe", "inherit"] });
  const lines = createInterface({ input: bridge.stdout })[Symbol.asyncIterator]();
  const call = async (command: HostCommand): Promise<HostResult> => {
    bridge.stdin.write(JSON.stringify(command.type === "on_node" ? command.command : command) + "\n");
    const line = await lines.next(); assert.equal(line.done, false); return JSON.parse(line.value!);
  };
  const models = createModels();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }] }); models.setProvider(faux.provider);
  const open = async (filename = "acceptance.sqlite") => {
    const database = await openNodeSqliteDatabase(join(state, filename));
    const storage = await SqliteStorage.open(database);
    const session = await Harness.open(storage, { models, registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
    return { session, tasks: new TaskStore(session, new ConversationModels(models)) };
  };
  let app = await open();
  const host: WorkerHost = { name: "fixture", host_id: process.env.AGENT_TEST_WORKSPACE_HOST!,
    rex_server: null, coordinator: null, cwd: state, agent_program: process.env.AGENT_TEST_MARKER_PROGRAM! };
  try {
    const tasks = await Promise.all(["Alpha", "Beta", "Gamma"].map(title => app.tasks.create({ title, outcome: "Print marker" })));
    const results = await Promise.all(tasks.map(task => app.tasks.dispatch(task.id, host, call)));
    const bindings = results.map(task => { assert.ok(task.worker.state === "bound"); return task.worker.binding; });
    assert.equal(new Set(bindings.map(binding => binding.session_id)).size, 1);
    assert.equal(new Set(bindings.map(binding => binding.window_id)).size, 3);
    const child = await app.tasks.createAgent(tasks[0]!.id, { id: "review", title: "Review", outcome: "Print marker", input: "Invented fixture", inputId: "fixture" });
    const withChild = await app.tasks.dispatchAgent(tasks[0]!.id, child.id, call);
    assert.ok(withChild.agents[0]?.worker.state === "bound");
    assert.equal(withChild.agents[0].worker.binding.session_id, bindings[0]!.session_id);
    await app.session.close(BACKGROUND_CONTEXT); app = await open();
    const next = await app.tasks.create({ title: "Delta after restart", outcome: "Print marker" });
    const result = await app.tasks.dispatch(next.id, host, call);
    assert.ok(result.worker.state === "bound");
    assert.equal(result.worker.binding.session_id, bindings[0]!.session_id);
    const rex = (...args: string[]) => execFileSync("rex", ["-S", process.env.AGENT_TEST_REX_SERVER!, ...args], { encoding: "utf8" });
    const inventory = JSON.parse(rex("window", "ls", "-s", bindings[0]!.session_id, "--json"));
    assert.deepEqual(inventory.windows.map((window: { label: string }) => window.label).sort(),
      ["Alpha", "Beta", "Gamma", "Review", "Delta after restart"].sort());
    const all = [...bindings, withChild.agents[0].worker.binding, result.worker.binding];
    for (const binding of all) assert.match(rex("capture", "-b", binding.block_id, "--trim"), /workspace-marker/);
    console.log("REAL_WORKSPACE_OK ordinary=4 children=1 sessions=1 distinct_windows=5 sqlite_reopen=true");
    console.log(JSON.stringify({ bindings: [...bindings, withChild.agents[0].worker.binding, result.worker.binding] }));
    const other = await open("other-coordinator.sqlite");
    let unrelatedSession: string;
    try {
      const independent = await other.tasks.create({ title: "Other coordinator", outcome: "Isolate ownership" });
      const saved = await other.tasks.dispatch(independent.id, host, call);
      assert.ok(saved.worker.state === "bound");
      unrelatedSession = saved.worker.binding.session_id;
      assert.notEqual(unrelatedSession, bindings[0]!.session_id);
    } finally { await other.session.close(BACKGROUND_CONTEXT); }
    // Close only our own first pane; the durable workspace does not depend on it.
    rex("block", "close", bindings[0]!.block_id);
    const epsilon = await app.tasks.create({ title: "Epsilon", outcome: "Retain workspace" });
    const added = await app.tasks.dispatch(epsilon.id, host, call);
    assert.ok(added.worker.state === "bound");
    assert.equal(added.worker.binding.session_id, bindings[0]!.session_id);
    await app.tasks.enqueue(tasks[1]!.id, "Retained synthetic input", "after-close");
    rex("kill", bindings[0]!.session_id);
    const replacement = await app.tasks.dispatch(tasks[1]!.id, host, call);
    assert.ok(replacement.worker.state === "bound");
    const replacementId = replacement.worker.binding.session_id;
    assert.notEqual(replacementId, bindings[0]!.session_id);
    const siblingTasks = await Promise.all(["Zeta", "Eta"].map(title => app.tasks.create({ title, outcome: "Reuse replacement" })));
    const represented = await Promise.all([...siblingTasks.map(task => task.id), tasks[0]!.id, tasks[2]!.id].map(id => app.tasks.dispatch(id, host, call)));
    for (const task of represented) { assert.ok(task.worker.state === "bound"); assert.equal(task.worker.binding.session_id, replacementId); }
    const childAgain = await app.tasks.dispatchAgent(tasks[0]!.id, child.id, call);
    assert.ok(childAgain.agents[0]?.worker.state === "bound");
    assert.equal(childAgain.agents[0].worker.binding.session_id, replacementId);
    await assert.rejects(app.tasks.run({ type: "run_task", task_id: tasks[1]!.id,
      allocation_id: results[1]!.worker.state === "bound" ? results[1]!.worker.allocation_id : "",
      binding: bindings[1]!, model: fixtureModel, cwd: state, instructions: "" }, () => () => {}), /binding is not confirmed/);
    await app.session.close(BACKGROUND_CONTEXT); app = await open();
    assert.equal((await app.tasks.get(tasks[1]!.id)).pending[0]?.id, "after-close");
    for (const task of [...tasks, ...siblingTasks]) {
      const saved = await app.tasks.get(task.id); assert.ok(saved.worker.state === "bound");
      assert.equal(saved.worker.binding.session_id, replacementId);
    }
    assert.equal(JSON.parse(rex("window", "ls", "-s", replacementId, "--json")).windows.length, 6);
    rex("kill", replacementId);
    assert.ok(JSON.parse(rex("window", "ls", "-s", unrelatedSession, "--json")).windows.length === 1);
    rex("kill", unrelatedSession);
    console.log("REAL_COORDINATOR_ISOLATION_OK independent_database=independent_session other_session_survived_owned_session_close=true");
    let uncertain = await open("uncertain-coordinator.sqlite");
    let lostSession = "";
    try {
      const first = await uncertain.tasks.create({ title: "Lost receipt", outcome: "Fence an ambiguous real create" });
      await assert.rejects(uncertain.tasks.dispatch(first.id, host, async command => {
        const created = await call(command); assert.ok(created.type === "spawned");
        lostSession = created.binding.session_id;
        throw new Error("Synthetic lost application receipt after real creation");
      }));
      const saved = await uncertain.tasks.get(first.id); assert.ok(saved.worker.state === "uncertain");
      await uncertain.tasks.revokeAllocation(first.id, saved.worker.allocation_id);
      await uncertain.session.close(BACKGROUND_CONTEXT); uncertain = await open("uncertain-coordinator.sqlite");
      const next = await uncertain.tasks.create({ title: "No duplicate", outcome: "Retain durable claim" });
      let mutations = 0;
      await assert.rejects(uncertain.tasks.dispatch(next.id, host, async command => { mutations++; return call(command); }));
      assert.equal(mutations, 0);
      assert.equal(JSON.parse(rex("window", "ls", "-s", lostSession, "--json")).windows.length, 1);
      rex("kill", lostSession);
      console.log("REAL_UNCERTAINTY_OK real_create_lost_receipt=true task_revoked=true fresh_sqlite_reopen=true duplicate_rpc_count=0");
    } finally { await uncertain.session.close(BACKGROUND_CONTEXT); }
    let adopting = await open("adopting-coordinator.sqlite");
    try {
      const original = await adopting.tasks.create({ title: "Recover original receipt", outcome: "Prove original ownership", model: fixtureModel });
      let actual: WorkerRef | undefined;
      await assert.rejects(adopting.tasks.dispatch(original.id, host, async command => {
        const result = await call(command); assert.ok(result.type === "spawned"); actual = result.binding;
        throw new Error("Lose real creation receipt");
      }));
      const saved = await adopting.tasks.get(original.id); assert.ok(saved.worker.state === "uncertain"); assert.ok(actual);
      await adopting.session.close(BACKGROUND_CONTEXT); adopting = await open("adopting-coordinator.sqlite");
      await adopting.tasks.run({ type: "run_task", task_id: original.id, allocation_id: saved.worker.allocation_id,
        binding: actual, cwd: state, model: fixtureModel, instructions: "" }, () => () => {}, [], command => call(command));
      assert.equal((await adopting.tasks.get(original.id)).worker.state, "bound");
      await adopting.session.close(BACKGROUND_CONTEXT); adopting = await open("adopting-coordinator.sqlite");
      const sibling = await adopting.tasks.create({ title: "Adopted sibling", outcome: "Reuse repaired claim" });
      const resumed = await adopting.tasks.dispatch(sibling.id, host, call); assert.ok(resumed.worker.state === "bound");
      assert.equal(resumed.worker.binding.session_id, actual.session_id);
      assert.equal(JSON.parse(rex("window", "ls", "-s", actual.session_id, "--json")).windows.length, 2);
      assert.equal(faux.state.callCount, 0);
      rex("kill", actual.session_id);
      console.log("REAL_ADOPTION_OK lost_real_create_receipt=true original_presence_verified=true workspace_repaired_atomically=true sibling_same_session_after_fresh_reopen=true model_calls=0");
    } finally { await adopting.session.close(BACKGROUND_CONTEXT); }
    for (const completion of ["matching", "lost"] as const) {
      let inflight = await open("inflight-" + completion + ".sqlite");
      let release = () => {}; let pending: Promise<unknown> | undefined;
      try {
        const original = await inflight.tasks.create({ title: "Early native readiness", outcome: "Reconcile in-flight receipt", model: fixtureModel });
        let created = () => {}; const made = new Promise<void>(resolve => { created = resolve; });
        const gate = new Promise<void>(resolve => { release = resolve; });
        let actual: WorkerRef | undefined;
        pending = inflight.tasks.dispatch(original.id, host, async command => {
          const result = await call(command); assert.ok(result.type === "spawned");
          actual = result.binding; created(); await gate;
          if (completion === "lost") throw new Error("Lose real receipt after early native adoption");
          return result;
        });
        void pending.catch(() => {}); await made; assert.ok(actual);
        const allocating = await inflight.tasks.get(original.id); assert.ok(allocating.worker.state === "allocating");
        await inflight.tasks.run({ type: "run_task", task_id: original.id, allocation_id: allocating.worker.allocation_id,
          binding: actual, model: fixtureModel, instructions: "", cwd: state }, () => () => {}, [], command => call(command));
        const proven = await inflight.tasks.get(original.id); assert.ok(proven.worker.state === "bound");
        release(); await pending;
        assert.deepEqual((await inflight.tasks.get(original.id)).worker, proven.worker);
        await inflight.session.close(BACKGROUND_CONTEXT); inflight = await open("inflight-" + completion + ".sqlite");
        const sibling = await inflight.tasks.create({ title: "After early readiness", outcome: "Reuse original after completion" });
        const saved = await inflight.tasks.dispatch(sibling.id, host, call); assert.ok(saved.worker.state === "bound");
        assert.equal(saved.worker.binding.session_id, actual.session_id);
        assert.equal(JSON.parse(rex("window", "ls", "-s", actual.session_id, "--json")).windows.length, 2);
        assert.equal(faux.state.callCount, 0);
        rex("kill", actual.session_id);
        console.log("REAL_INFLIGHT_COMPLETION_OK completion=" + completion + " real_create_held=true native_proven_before_receipt=true dispatch_success=true same_original_bound=true fresh_reopen_sibling_same_session=true model_calls=0");
      } finally { release(); await pending?.catch(() => {}); await inflight.session.close(BACKGROUND_CONTEXT); }
    }
    if (process.env.AGENT_TEST_SECOND_REX_SERVER && process.env.AGENT_TEST_SECOND_REX_HOST) {
      const remoteBridge = spawn(process.env.AGENT_TEST_WORKSPACE_BRIDGE!, [], { stdio: ["pipe", "pipe", "inherit"],
        env: { ...process.env, AGENT_TEST_REX_SERVER: process.env.AGENT_TEST_SECOND_REX_SERVER } });
      const remoteLines = createInterface({ input: remoteBridge.stdout })[Symbol.asyncIterator]();
      const remoteCall = async (command: HostCommand): Promise<HostResult> => {
        remoteBridge.stdin.write(JSON.stringify(command) + "\n");
        const line = await remoteLines.next(); assert.equal(line.done, false); return JSON.parse(line.value!);
      };
      try {
        const remoteHost = { ...host, host_id: process.env.AGENT_TEST_SECOND_REX_HOST, name: "second-fixture" };
        const remoteTasks = await Promise.all(["Remote Alpha", "Remote Beta"].map(title => app.tasks.create({ title, outcome: "Isolate host" })));
        const remote = await Promise.all(remoteTasks.map(task => app.tasks.dispatch(task.id, remoteHost, remoteCall)));
        const remoteBindings = remote.map(task => { assert.ok(task.worker.state === "bound"); return task.worker.binding; });
        assert.equal(remoteBindings[0]!.session_id, remoteBindings[1]!.session_id);
        assert.notEqual(remoteBindings[0]!.session_id, bindings[0]!.session_id);
        assert.notEqual(remoteBindings[0]!.host_id, bindings[0]!.host_id);
        await app.session.close(BACKGROUND_CONTEXT); app = await open();
        const third = await app.tasks.create({ title: "Remote Gamma", outcome: "Reuse persisted host ownership" });
        const saved = await app.tasks.dispatch(third.id, remoteHost, remoteCall); assert.ok(saved.worker.state === "bound");
        assert.equal(saved.worker.binding.session_id, remoteBindings[0]!.session_id);
        execFileSync("rex", ["-S", process.env.AGENT_TEST_SECOND_REX_SERVER, "kill", saved.worker.binding.session_id]);
        console.log("REAL_HOST_ISOLATION_OK isolated_rex_host_identities=2 remote_siblings=3 remote_sessions=1 sqlite_reopen=true");
      } finally { remoteBridge.stdin.end(); }
    }
    if (process.env.AGENT_TEST_REX_STATE) {
      const restarting = await open("restart-coordinator.sqlite");
      try {
        const first = await restarting.tasks.create({ title: "Before Rex restart", outcome: "Verify restored identity" });
        const old = await restarting.tasks.dispatch(first.id, host, call); assert.ok(old.worker.state === "bound");
        rex("server", "stop");
        rex("server", "start", "--state-dir", process.env.AGENT_TEST_REX_STATE, "--config", "/dev/null", "--json");
        const next = await restarting.tasks.create({ title: "After Rex restart", outcome: "Verify exact restored ownership" });
        const resumed = await restarting.tasks.dispatch(next.id, host, call); assert.ok(resumed.worker.state === "bound");
        assert.equal(resumed.worker.binding.session_id, old.worker.binding.session_id);
        assert.notEqual(resumed.worker.binding.rex_instance_id, old.worker.binding.rex_instance_id);
        assert.equal(JSON.parse(rex("window", "ls", "-s", old.worker.binding.session_id, "--json")).windows.length, 2);
        rex("kill", old.worker.binding.session_id);
        console.log("REAL_REX_RESTART_OK instance_changed=true exact_owned_pane_host_verified=true same_session=true named_windows=2");
      } finally { await restarting.session.close(BACKGROUND_CONTEXT); }
    }
    console.log("REAL_RECOVERY_OK closed_anchor=reused shared_session_close=one_replacement old_generation=fenced conversations_children_pending=retained sqlite_reopen=true");
  } finally { await app.session.close(BACKGROUND_CONTEXT); bridge.stdin.end(); }
});
