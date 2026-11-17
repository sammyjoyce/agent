import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { BackgroundScheduler } from "../src/background.js";
import { runScheduled } from "../src/scheduled.js";
import type { ScheduledOccurrence } from "../src/generated/ScheduledOccurrence.js";
import { DAY, FakeClock, exampleJob, openBackground, planned, pump } from "./fixtures/background-runtime.js";
import { openScheduled } from "./fixtures/scheduled-runtime.js";
import { runAdmitted } from "./fixtures/run-admitted.js";

for (const state of ["open", "resolved"] as const) {
  test(`reconciled ${state} occurrence durably settles on the next evidence tick without replay`, { timeout: 20_000 }, async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-settlement-")), clock = new FakeClock();
    let app = await openScheduled(directory, "original", clock), occurrence: ScheduledOccurrence | undefined;
    const background = () => {
      const current = app;
      return new BackgroundScheduler(current.session, current.registry, current.tasks, {
        plan: async (cadence, after, now) => planned(cadence, after, now),
        refreshSources: async () => {}, triageSources: async () => {}, collectResources: async () => {}, indexHistory: async () => {},
        runJob: async (item, signal, actor) => { occurrence ??= item; await runScheduled(item, signal, current, actor); },
      });
    };
    let scheduler = background();
    try {
      app.faux.setResponses([() => { throw new Error("Invented original model failure"); }]);
      await scheduler.start({ poll_interval_seconds: 60, sources: false, jobs: [exampleJob()] });
      await pump(async () => (await scheduler.getJob("example-review")).schedules[0]?.next_at !== null);
      clock.advance(DAY);
      await pump(async () => (await scheduler.getJob("example-review")).last_run?.state.status === "retrying");
      assert.ok(occurrence); const originalOccurrence = occurrence;
      const task = (await app.tasks.list())[0]; assert.ok(task);
      const conversation = await app.tasks.conversation(task.conversation_id);
      const original = await app.session.commit(tx => tx.submissionByRequest(conversation.id, originalOccurrence.id), BACKGROUND_CONTEXT);
      assert.equal(original?.status, "unanswered");
      // Build up attempts. This is evidence checking only, never model replay.
      for (let attempt = 0; attempt < 7; attempt++) {
        const before = (await scheduler.getJob("example-review")).last_run;
        assert.equal(before?.state.status, "retrying");
        clock.advance(60_000);
        await pump(async () => {
          const run = (await scheduler.getJob("example-review")).last_run;
          return run?.state.status === "retrying" && run.state.at > clock.now();
        });
        assert.equal(app.faux.state.callCount, 1);
        assert.equal((await scheduler.getJob("example-review")).last_run?.finished_at, null);
      }
      app.faux.setResponses([
        fauxAssistantMessage(fauxToolCall("record_task", { summary: "Inspected the original failure without repeating work.",
          reconciles_input: originalOccurrence.id, state: state === "open" ? { state } : { state, evidence: "Inspected original result" } }), { stopReason: "toolUse" }),
        fauxAssistantMessage("Recovery verified; no replay needed."),
      ]);
      await app.tasks.enqueue(task.id, "Reconcile the original occurrence only.", "invented-recovery");
      await runAdmitted(app.tasks, task.id);
      assert.equal((await app.tasks.get(task.id)).state.state, state);
      const receipt = (await app.sources.events({ provider: "task_outcomes", thread_id: task.id, limit: 100 }))
        .find(event => event.outcome?.reconciliation)?.outcome?.reconciliation;
      assert.equal(receipt?.original.submission_id, original?.id.toString());
      assert.deepEqual(receipt?.recovery_inputs.map(input => input.request_id), ["invented-recovery"]);
      await app.close(); app = await openScheduled(directory, "restored", clock); scheduler = background();
      await scheduler.start({ poll_interval_seconds: 60, sources: false, jobs: [exampleJob()] });
      clock.advance(60_000);
      await pump(async () => (await scheduler.getJob("example-review")).last_run?.state.status === "completed");
      const settled = (await scheduler.getJob("example-review")).last_run;
      assert.ok(settled?.finished_at); assert.equal(settled.scheduled_at, originalOccurrence.scheduled_at);
      assert.equal(settled.task_id, task.id); assert.equal(app.faux.state.callCount, 0); assert.deepEqual(app.commands, []);
      const retainedConversation = await app.tasks.conversation(task.conversation_id);
      const retained = await app.session.commit(tx => tx.submissionByRequest(retainedConversation.id, originalOccurrence.id), BACKGROUND_CONTEXT);
      assert.equal(retained?.id, original?.id); assert.equal(retained?.status, "unanswered");
      await app.close(); app = await openScheduled(directory, "fresh-read", clock); scheduler = background();
      assert.deepEqual((await scheduler.getJob("example-review")).last_run, settled);
      console.log(`SETTLED ${state}: completed once; durable finished_at; original unanswered identity retained; reopened model calls=0 effects=0`);
    } finally { await app.close(); await rm(directory, { recursive: true, force: true }); }
  });
}

test("exact recovery settles while unrelated later native work stays active; unproven pending work cannot settle", { timeout: 20_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-settlement-active-"));
  const app = await openScheduled(directory);
  const occurrence: ScheduledOccurrence = { id: "invented-active-occurrence", job: exampleJob(), schedule_id: "daily", scheduled_at: Date.UTC(2027, 0, 2) };
  let release = () => {}, later: Promise<void> | undefined;
  try {
    app.faux.setResponses([() => { throw new Error("Invented interrupted generation"); }]);
    await assert.rejects(runScheduled(occurrence, new AbortController().signal, app), /scheduled turn/);
    const task = (await app.tasks.list())[0]; assert.ok(task);
    await app.tasks.enqueue(task.id, "Unanswered work is not proof of recovery.", "invented-pending");
    await assert.rejects(runScheduled(occurrence, new AbortController().signal, app, task.id), /scheduled turn/);
    assert.equal(app.faux.state.callCount, 1, "Pending input must not be executed by a settlement check");
    app.faux.setResponses([
      fauxAssistantMessage(fauxToolCall("record_task", { summary: "Verified exact original request.", state: { state: "open" }, reconciles_input: occurrence.id }), { stopReason: "toolUse" }),
      fauxAssistantMessage("Recovery complete; broader task remains open."),
    ]);
    await runAdmitted(app.tasks, task.id);
    let entered = () => {}; const active = new Promise<void>(resolve => { entered = resolve; });
    const gate = new Promise<void>(resolve => { release = resolve; });
    app.faux.setResponses([async () => { entered(); await gate; return fauxAssistantMessage("Independent later result."); }]);
    await app.tasks.enqueue(task.id, "A distinct later request.", "invented-later");
    later = runAdmitted(app.tasks, task.id); await active;
    const conversation = await app.tasks.conversation(task.conversation_id);
    assert.equal(await app.session.commit(tx => app.tasks.canSettleScheduledIn(tx, task.id, conversation.id), BACKGROUND_CONTEXT), false);
    const calls = app.faux.state.callCount;
    await runScheduled(occurrence, new AbortController().signal, app, task.id);
    assert.equal(app.tasks.isRunning(task.id), true);
    assert.equal((await app.tasks.get(task.id)).state.state, "open");
    assert.equal(app.faux.state.callCount, calls);
    assert.equal((await app.session.commit(tx => tx.submissionByRequest(conversation.id, "invented-later"), BACKGROUND_CONTEXT))?.status, "placed");
    console.log("EXACT SCOPE: original recovered; later input still placed and task open; no extra inference");
  } finally { release(); await later; await app.close(); await rm(directory, { recursive: true, force: true }); }
});

test("real execution failures retain exponential backoff and never become completed reconciliation", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-settlement-failure-")), clock = new FakeClock();
  let attempts = 0;
  const app = await openBackground(directory, clock, { runJob: async () => { attempts++; throw new Error("Invented worker unavailable"); } });
  try {
    await app.scheduler.start({ poll_interval_seconds: 60, sources: false, jobs: [exampleJob()] });
    await pump(async () => (await app.scheduler.getJob("example-review")).schedules[0]?.next_at !== null);
    clock.advance(DAY);
    for (const [index, delay] of [60_000, 120_000, 240_000].entries()) {
      await pump(async () => {
        const run = (await app.scheduler.getJob("example-review")).last_run;
        return attempts === index + 1 && run?.state.status === "retrying" && run.state.at > clock.now();
      });
      const run = (await app.scheduler.getJob("example-review")).last_run;
      assert.equal(run?.state.status, "retrying");
      if (run?.state.status === "retrying") {
        assert.equal(run.state.at, clock.now() + delay); assert.equal(run.state.message, "Invented worker unavailable");
      }
      assert.equal(run?.finished_at, null);
      if (index < 2) clock.advance(delay);
    }
    console.log("FAILURE CONTROL: actual worker failure stays retrying; delays=60,120,240 seconds; finished_at=null");
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});
