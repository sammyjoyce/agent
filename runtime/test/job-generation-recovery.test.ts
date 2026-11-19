import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { JsonValue } from "@earendil-works/chord/json";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { createRegistry, defineDoc, GenerationTask, Harness, LiveDoc, UserEntry, type Conversation,
  type GenerationCheckpoint } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { commitWrites } from "@earendil-works/pi-durable/testing";
import { BackgroundScheduler } from "../src/background.js";
import type { ScheduledJob } from "../src/generated/ScheduledJob.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { runScheduled, scheduledTaskId } from "../src/scheduled.js";
import { SourceJournal } from "../src/sources.js";
import { TaskStore } from "../src/tasks.js";
import { Executions } from "../src/tools.js";
import { pump } from "./fixtures/background-runtime.js";

const LegacyState = defineDoc<{ lanes: { id: string; last_run?: JsonValue }[] }>({
  kind: "agent.background", scope: "session", version: 1, initial: () => ({ lanes: [] }), checkpointWhen: () => true,
});
const job: ScheduledJob = { id: "generation-review", title: "Retained review", prompt: "Read existing evidence.",
  model: DEFAULT_MODEL, timezone: "Etc/UTC", revision: "original", cwd: "/",
  schedules: [{ id: "daily", recurrence: "DTSTART:20270101T090000Z\nRRULE:FREQ=DAILY", focus: null, prompt: null }] };

async function open(directory: string) {
  const storage = await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite")));
  const registry = createRegistry();
  const session = await Harness.open(storage, { models: builtinModels(), registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const tasks = new TaskStore(session), sources = new SourceJournal(session, tasks, new Executions());
  const scheduler = new BackgroundScheduler(session, registry, tasks, {
    // Calendar calculation is outside this regression. Pi owns the model run,
    // its restart limit and the durable input the production job consumer settles.
    plan: async (_cadence, _after, now) => ({ due: null, next: now + 3_600_000 }),
    refreshSources: async () => {}, triageSources: async () => {}, collectResources: async () => {}, indexHistory: async () => {},
    runJob: (occurrence, signal, actorId) => runScheduled(occurrence, signal, { session, tasks, sources }, actorId),
  });
  return { session, storage, tasks, scheduler };
}

test("job inspection leaves an actor without a current native run untouched", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-job-no-generation-")), app = await open(directory);
  try {
    await app.scheduler.syncJobs([job]);
    const receipt = await app.scheduler.runJob({ type: "run_job", job_id: job.id, schedule_id: null, request_id: "not-admitted" });
    // Without an execution service the job's admitted input waits for its actor.
    await pump(async () => /execution is unavailable/.test((await app.scheduler.getJob(job.id)).schedules[0]?.error ?? ""));
    const actor = await app.tasks.get(receipt.task_id), conversation = await app.tasks.conversation(actor.conversation_id);
    const before = await app.session.snapshot(LiveDoc, conversation.id, BACKGROUND_CONTEXT);
    assert.equal(before?.run, undefined);
    await app.scheduler.getJob(job.id);
    assert.deepEqual(await app.session.snapshot(LiveDoc, conversation.id, BACKGROUND_CONTEXT), before);
    assert.deepEqual(await app.tasks.get(receipt.task_id), actor);
    await assert.rejects(app.scheduler.retryJob(job.id), /parked/);
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

for (const legacy of [false, true]) test(`a job run Pi ends at its restart limit waits for reconciliation${legacy ? " in a lane without timing" : ""}, untouched by inspection and retry`, { timeout: 15_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-job-generation-"));
  let app = await open(directory);
  const otherJob = { ...job, id: "unrelated-review" }, until = Date.now() + 3_600_000;
  const checkpoint = { phase: "retry", attempt: 1, until } satisfies GenerationCheckpoint;
  try {
    await app.scheduler.syncJobs([job, otherJob]);
    const actor = await app.tasks.create({ id: scheduledTaskId("job:" + job.id), title: job.title, outcome: job.prompt,
      model: job.model, job_id: job.id });
    const otherActor = await app.tasks.create({ id: scheduledTaskId("job:" + otherJob.id), title: otherJob.title, outcome: otherJob.prompt,
      model: otherJob.model, job_id: otherJob.id });
    const conversation = await app.tasks.conversation(actor.conversation_id), other = await app.tasks.conversation(otherActor.conversation_id);
    const placed = (target: Conversation, requestId: string) => target.commit(async tx => {
      const entry = await tx.appendEntry(UserEntry, target.id, { model: [{ role: "user", content: "Retained job request", timestamp: 1 }] });
      const input = await tx.createSubmission({ type: "input", conversationId: target.id, requestId, status: "placed", entry: entry.id });
      const generation = await tx.createTask(GenerationTask, {}, { ownership: { kind: "conversation" } });
      const live = await tx.doc(LiveDoc, target.id); live.run = { taskId: generation, inputs: [input.id], turns: 0 }; live.generation = { attempt: 1 };
      return generation;
    }, BACKGROUND_CONTEXT);
    const generation = await placed(conversation, "manual:retained"), otherGeneration = await placed(other, "manual:other");
    // Persist genuine native crash records while the Harness is paused: this
    // job's run was cut off at Pi's restart limit, the other's sleeps until its retry.
    for (const id of [generation, otherGeneration]) {
      const record = await app.session.getTask(id, BACKGROUND_CONTEXT); assert.ok(record);
      await commitWrites(app.storage, [{ type: "task", value: id === generation
        ? { ...record, restarts: 5, state: { status: "pending", checkpoint } }
        : { ...record, state: { status: "sleeping", until, checkpoint } } }], BACKGROUND_CONTEXT);
    }
    await app.session.close(BACKGROUND_CONTEXT); app = await open(directory);
    app.session.resume();
    await app.session.waitForTask(generation, BACKGROUND_CONTEXT);
    const ended = await app.session.getTask(generation, BACKGROUND_CONTEXT);
    assert.ok(ended?.state.status === "terminal" && ended.state.outcome.status === "failed");
    assert.deepEqual(ended.state.outcome.error.detail, { reason: "restart_limit" });
    const input = await app.session.commit(tx => tx.submissionByRequest(conversation.id, "manual:retained"), BACKGROUND_CONTEXT);
    assert.ok(input?.status === "unanswered"); assert.equal(input.reason, "restart_limit");
    const receipt = await app.scheduler.runJob({ type: "run_job", job_id: job.id, schedule_id: null, request_id: "retained" });
    const queued = await app.scheduler.runJob({ type: "run_job", job_id: job.id, schedule_id: null, request_id: "queued" });
    assert.equal(receipt.task_id, actor.id); assert.equal(queued.task_id, actor.id);
    await pump(async () => /stopped without an answer/.test((await app.scheduler.getJob(job.id)).schedules[0]?.error ?? ""));
    if (legacy) await app.session.commit(async tx => {
      const lane = (await tx.doc(LegacyState)).lanes.find(item => item.id === JSON.stringify(["job", job.id]));
      assert.ok(lane); delete lane.last_run;
    }, BACKGROUND_CONTEXT);
    const native = async () => ({
      tasks: await Promise.all([generation, otherGeneration].map(id => app.session.getTask(id, BACKGROUND_CONTEXT))),
      inputs: await app.session.commit(async tx => [await tx.submissionByRequest(conversation.id, "manual:retained"),
        await tx.submissionByRequest(other.id, "manual:other")], BACKGROUND_CONTEXT),
      live: await Promise.all([conversation, other].map(item => app.session.snapshot(LiveDoc, item.id, BACKGROUND_CONTEXT))),
    });
    const before = await native(), statusBefore = await app.scheduler.status();
    const inspected = await app.scheduler.getJob(job.id);
    assert.match(inspected.schedules[0]?.error ?? "", /reconcile its exact input/);
    if (legacy) assert.equal(inspected.last_run, undefined, "Legacy timing must remain unknown");
    else assert.equal(inspected.last_run?.task_id, actor.id);
    await assert.rejects(app.scheduler.retryJob(otherJob.id), /no parked interrupted run or timer/);
    await assert.rejects(app.scheduler.retryJob(job.id), /no parked interrupted run or timer/,
      "Pi settled the run's input; its occurrence reconciles in a recovery turn instead of another model attempt");
    assert.deepEqual(await native(), before, "Inspection and refused retries must not change native work");
    assert.equal(before.tasks[1]?.state.status, "sleeping", "The other job's run keeps its retry deadline");
    assert.equal((await app.scheduler.status()).pending, statusBefore.pending, "Queued occurrences must stay in their original lanes");
    assert.deepEqual(await app.scheduler.runJob({ type: "run_job", job_id: job.id, schedule_id: null, request_id: "queued" }), queued);
    assert.equal((await app.tasks.list()).length, 2);
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});
