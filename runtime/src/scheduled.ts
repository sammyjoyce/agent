import { createHash } from "node:crypto";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AssistantEntry, ROOT_CONVERSATION_ID, type Conversation, type Harness, type SubmissionRecord } from "@earendil-works/pi-durable";
import type { ScheduledOccurrence } from "./generated/ScheduledOccurrence.js";
import type { ScheduledJob } from "./generated/ScheduledJob.js";
import type { SidechatStore } from "./sidechats.js";
import { SourceJournal } from "./sources.js";
import { nativeConversationId, publishConversationNotice, TaskError, TaskStore } from "./tasks.js";

/** A stable UUID keeps the ordinary task API authoritative across replay. */
export function scheduledTaskId(occurrence: string): string {
  const bytes = createHash("sha256").update(occurrence).digest();
  bytes[6] = (bytes[6]! & 0x0f) | 0x40; bytes[8] = (bytes[8]! & 0x3f) | 0x80;
  const hex = bytes.toString("hex", 0, 16);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function occurrencePrompt(occurrence: ScheduledOccurrence): string {
  const schedule = occurrence.job.schedules.find((schedule) => schedule.id === occurrence.schedule_id);
  if (schedule === undefined) throw new TaskError("The admitted job schedule is unavailable");
  return [occurrence.job.prompt,
    ...(schedule.prompt === null ? [] : [`This occurrence's focus${schedule.focus === null ? "" : ` (${schedule.focus})`}:\n${schedule.prompt}`]),
    `Scheduled occurrence: ${occurrence.id}. Continue related unfinished tasks and retain their decisions.`,
  ].join("\n\n");
}

/** Adopt only a job-owned chat; a mutable, nonunique title is not ownership. */
export async function openJobActor(job: ScheduledJob, tasks: TaskStore): Promise<string | undefined> {
  return (await tasks.list()).find((task) => task.sources.some((source) =>
    source.provider === "scheduled_jobs" && source.account === "local" && source.thread_id === job.id))?.id;
}

/** An evidence-only recheck, not another execution attempt. Keep it responsive
 * to a recovery turn rather than backing off business work for up to an hour. */
export class ScheduledReconciliationPending extends TaskError {}

async function requireReconciledTask(session: Harness, tasks: TaskStore, sources: SourceJournal, id: string, requestId: string): Promise<void> {
  const conversation = await tasks.conversation((await tasks.get(id)).conversation_id);
  // Exact successful recovery is occurrence-scoped. Unrelated later work in
  // this long-lived task must not keep the recovered occurrence open. Without
  // that proof, whole-task resolution still requires native/task quiescence.
  if (!await session.commit(async (tx) => await sources.reconcilesIn(tx, id, conversation.id, requestId) ||
      await tasks.canSettleScheduledIn(tx, id, conversation.id) && await tasks.canReleaseIn(tx, id), BACKGROUND_CONTEXT)) {
    throw new ScheduledReconciliationPending("The scheduled turn stopped without an answer; resolve its task or explicitly reconcile its exact input in a successful recovery turn before this occurrence can settle");
  }
}

async function deliverJobOutput(
  occurrence: ScheduledOccurrence,
  session: Harness,
  tasks: TaskStore,
  sidechats: SidechatStore | undefined,
  taskId: string,
  conversation: Conversation,
  submission: Extract<SubmissionRecord, { type: "input"; status: "done" }>,
): Promise<void> {
  const targetRef = occurrence.job.delivery_sidechat;
  if (targetRef === undefined) return;
  const answerEntry = await conversation.commit((tx) => tx.entry(AssistantEntry, submission.answer), BACKGROUND_CONTEXT);
  if (answerEntry === undefined) return;
  const answerText = answerEntry.model
    ?.flatMap((message) =>
      message.role !== "assistant"
        ? []
        : message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])),
    )
    .join("\n")
    .trim() ?? "";
  if (answerText.length === 0) return;

  const deliveryKey = "job-delivery:" + occurrence.id;
  const deliveryRequestId = "notice:" + answerEntry.id.toString() + ":" + deliveryKey;
  const alreadyDeliveredTo = async (targetConversationId: typeof ROOT_CONVERSATION_ID): Promise<boolean> =>
    (await session.commit(
      (tx) => tx.submissionByRequest(targetConversationId, deliveryRequestId),
      BACKGROUND_CONTEXT,
    )) !== undefined;

  // If an earlier attempt already fell back to Main for this exact occurrence
  // answer, never post a duplicate even if a side chat with that slug is
  // created later.
  if (await alreadyDeliveredTo(ROOT_CONVERSATION_ID)) return;

  const targetSidechat = await sidechats?.resolve(targetRef);
  if (targetSidechat !== undefined && sidechats !== undefined) {
    const targetConversationId = nativeConversationId(targetSidechat.conversation_id);
    if (await alreadyDeliveredTo(targetConversationId)) return;
    await sidechats.unarchiveIfNeeded(targetSidechat.conversation_id);
    const lineage = await tasks.noticeOrigin(conversation, answerEntry.id);
    await publishConversationNotice(session, targetConversationId, conversation, answerEntry, taskId, [], {
      key: deliveryKey,
      text: answerText,
      events: [],
      taskTitle: occurrence.job.title,
      ...(lineage === undefined ? {} : { origin: lineage }),
    });
    await sidechats.touchUpdatedAt(targetSidechat.conversation_id);
    return;
  }

  const warningText = `[Scheduled job "${occurrence.job.title}" could not find side chat "${targetRef}"; delivered here instead.]\n\n${answerText}`;
  const lineage = await tasks.noticeOrigin(conversation, answerEntry.id);
  await publishConversationNotice(session, ROOT_CONVERSATION_ID, conversation, answerEntry, taskId, [], {
    key: deliveryKey,
    text: warningText,
    events: [],
    taskTitle: occurrence.job.title,
    ...(lineage === undefined ? {} : { origin: lineage }),
  });
}

/** Run the existing task actor in the coordinator, then settle its exact Pi input. */
export async function runScheduled(occurrence: ScheduledOccurrence, signal: AbortSignal,
  services: { session: Harness; tasks: TaskStore; sources: SourceJournal; sidechats?: SidechatStore },
  id = scheduledTaskId(occurrence.id)): Promise<void> {
  const { session, tasks, sources, sidechats } = services;
  const resolvedTarget = occurrence.job.delivery_sidechat === undefined
    ? undefined
    : await sidechats?.resolve(occurrence.job.delivery_sidechat);
  const task = await tasks.create({
    id,
    title: occurrence.job.title,
    outcome: occurrence.job.prompt,
    model: occurrence.job.model,
    job_id: occurrence.job.id,
    ...(resolvedTarget === undefined ? {} : { delivery_conversation_id: resolvedTarget.conversation_id }),
  });
  if (task.delivery_conversation_id !== resolvedTarget?.conversation_id) {
    await tasks.setDeliveryConversation(task.id, resolvedTarget?.conversation_id);
  }
  const conversation = await tasks.conversation(task.conversation_id);
  let submission = await session.commit((tx) => tx.submissionByRequest(conversation.id, occurrence.id), BACKGROUND_CONTEXT);
  if (submission?.type === "input" && submission.status === "done") {
    await deliverJobOutput(occurrence, session, tasks, sidechats, id, conversation, submission);
    return;
  }
  if (submission?.status === "unanswered") { await requireReconciledTask(session, tasks, sources, id, occurrence.id); return; }
  if (submission === undefined && !task.pending.some((input) => input.id === occurrence.id)) {
    await tasks.enqueueScheduled(id, occurrencePrompt(occurrence), occurrence);
  }
  let failure: unknown, revision = 0, wake: (() => void) | undefined;
  const commits = session.observeCommits({ advance: () => { revision += 1; wake?.(); }, end() {} });
  const aborted = () => wake?.(); signal.addEventListener("abort", aborted);
  try {
    const previousOutcome = (await sources.events({ provider: "task_outcomes", thread_id: id, limit: 1 }))[0]?.key;
    const start = await tasks.ensureActor({ task_id: id });
    switch (start.state) {
      case "started": case "running":
        void start.exit.then(() => {}, (error: unknown) => { failure = error; }).finally(() => { revision += 1; wake?.(); });
        break;
      case "no_work": break;
      case "unplaced": case "host_offline": case "unavailable": throw new TaskError(start.reason);
      default: { const unknown: never = start; throw new TaskError(`Unknown actor start ${JSON.stringify(unknown)}`); }
    }
    for (;;) {
      if (signal.aborted) throw new TaskError("Scheduled work stopped with the coordinator; its admission is retained");
      const observed = revision;
      submission = await session.commit((tx) => tx.submissionByRequest(conversation.id, occurrence.id), BACKGROUND_CONTEXT);
      if (submission?.status === "unanswered") { await requireReconciledTask(session, tasks, sources, id, occurrence.id); return; }
      if (submission?.type === "input" && submission.status === "done") {
        await deliverJobOutput(occurrence, session, tasks, sidechats, id, conversation, submission);
        return;
      }
      if (failure !== undefined) throw failure;
      const latest = (await sources.events({ provider: "task_outcomes", thread_id: id, limit: 1 }))[0];
      if (latest?.key !== previousOutcome && latest?.outcome?.state.state === "failed") throw new TaskError(latest.outcome.state.reason);
      await new Promise<void>((resolve) => { wake = resolve; if (revision !== observed || signal.aborted) resolve(); });
      wake = undefined;
    }
  } finally { commits.detach(); signal.removeEventListener("abort", aborted); }
}
