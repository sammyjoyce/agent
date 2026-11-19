import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineTask, LiveDoc, ROOT_CONVERSATION_ID, type Conversation, type EntryId, type EntryRecord, type Harness,
  type NextTaskState, type TaskId, type Tx } from "@earendil-works/pi-durable";

type HeldNoticeContext = { request_id: string; origin: EntryId; text: string[] };
type State = { active: TaskId<null> | null; held: HeldNoticeContext[] };
/** `placed` names the last context admitted, as Pi faults a phase that continues with an unchanged checkpoint. */
type Checkpoint = { phase: "place"; placed: string | null };

const HeldNoticeContexts = defineDoc<State>({ kind: "agent.notice_context.held", scope: "session", version: 1,
  initial: () => ({ active: null, held: [] }), checkpointWhen: () => true });

function settled(): NextTaskState<Checkpoint, null> { return { status: "terminal", outcome: { status: "completed", result: null } }; }

export function noticeContextModel(origin: EntryRecord | undefined, text: readonly string[]): NonNullable<EntryRecord["model"]> {
  return origin?.model?.flatMap((message) => message.role !== "assistant" ? []
    : [{ ...message, content: text.map((part) => ({ type: "text" as const, text: part })) }]) ?? [];
}

function admitIn(tx: Tx, root: Pick<Conversation, "submit">, requestId: string, model: NonNullable<EntryRecord["model"]>) {
  return root.submit(tx, { type: "write", requestId, entry: { kind: "agent.notice_context", model } });
}

export const NoticeContextPlacement = defineTask<null, Checkpoint, null>({
  name: "agent.notice_context.place", version: 1, initial: () => ({ phase: "place", placed: null }),
  phases: {
    place: async (task, runtime, context) => {
      const root = await runtime.conversation(ROOT_CONVERSATION_ID, context);
      if (root === undefined) throw new Error("The main conversation is unavailable");
      await runtime.commit(async (tx) => {
        const state = await tx.doc(HeldNoticeContexts), next = state.held[0];
        if (state.active !== runtime.taskId) return settled();
        if (next === undefined) { state.active = null; return settled(); }
        const run = (await tx.doc(LiveDoc, ROOT_CONVERSATION_ID)).run;
        if (run !== undefined) return { status: "waiting", checkpoint: task.state.checkpoint, on: [run.taskId], policy: "allSettled" };
        const model = noticeContextModel(await tx.entry(next.origin), next.text);
        if (model.length > 0) await admitIn(tx, root, next.request_id, model);
        state.held.shift();
        if (state.held.length > 0) return { status: "running", checkpoint: { phase: "place", placed: next.request_id } };
        state.active = null; return settled();
      }, context);
    },
  },
  abort: async (_task, runtime, context) => {
    await runtime.commit(async (tx) => {
      const state = await tx.doc(HeldNoticeContexts);
      if (state.active === runtime.taskId) state.active = null;
      return { status: "terminal", outcome: { status: "aborted" } };
    }, context);
  },
});

/**
 * Add a notice to main's model context. Pi places a busy conversation's queued
 * writes after a tool round, and a context that then ends in this assistant
 * message ends the run unanswered, so the notice waits until main has no run.
 */
export async function placeNoticeContext(session: Harness, root: Conversation, origin: EntryRecord, requestId: string, text: readonly string[]): Promise<void> {
  await session.commit(async (tx) => {
    if (await tx.submissionByRequest(root.id, requestId) !== undefined) return;
    const state = await tx.doc(HeldNoticeContexts);
    const active = state.active === null ? undefined : await tx.task(state.active);
    if (state.held.length === 0 && (await tx.doc(LiveDoc, root.id)).run === undefined) {
      await admitIn(tx, root, requestId, noticeContextModel(origin, text));
      return;
    }
    if (!state.held.some((held) => held.request_id === requestId)) state.held.push({ request_id: requestId, origin: origin.id, text: [...text] });
    if (active === undefined || active.state.status === "terminal") {
      state.active = await tx.createTask(NoticeContextPlacement, null, { ownership: { kind: "conversation" }, conversationId: ROOT_CONVERSATION_ID, background: true });
    }
  }, BACKGROUND_CONTEXT);
}
