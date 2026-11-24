import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineTask, LiveDoc, ROOT_CONVERSATION_ID, type Conversation, type ConversationId,
  type EntryId, type EntryRecord, type Harness, type NextTaskState, type TaskId, type Tx } from "@earendil-works/pi-durable";

type HeldNoticeContext = { request_id: string; origin: EntryId; text: string[] };
type State = { active: TaskId<null> | null; held: HeldNoticeContext[] };
/** `placed` names the last context admitted, as Pi faults a phase that continues with an unchanged checkpoint. */
type Checkpoint = { phase: "place"; placed: string | null };

// Keep Main's held notice queue at `scope: "session"` under the original document
// kind so notices held before upgrading to side chats still drain on restart.
const MainHeldNoticeContexts = defineDoc<State>({ kind: "agent.notice_context.held", scope: "session", version: 1,
  initial: () => ({ active: null, held: [] }), checkpointWhen: () => true });
const SidechatHeldNoticeContexts = defineDoc<State>({ kind: "agent.sidechat.notice_context.held", scope: "conversation", history: "latest", fork: "initial", version: 1,
  initial: () => ({ active: null, held: [] }), checkpointWhen: () => true });

function heldState(tx: Tx, conversationId: ConversationId) {
  return conversationId === ROOT_CONVERSATION_ID
    ? tx.doc(MainHeldNoticeContexts)
    : tx.doc(SidechatHeldNoticeContexts, conversationId);
}

function settled(): NextTaskState<Checkpoint, null> { return { status: "terminal", outcome: { status: "completed", result: null } }; }

export function noticeContextModel(origin: EntryRecord | undefined, text: readonly string[]): NonNullable<EntryRecord["model"]> {
  return origin?.model?.flatMap((message) => message.role !== "assistant" ? []
    : [{ ...message, content: text.map((part) => ({ type: "text" as const, text: part })) }]) ?? [];
}

function admitIn(tx: Tx, target: Pick<Conversation, "submit">, requestId: string, model: NonNullable<EntryRecord["model"]>) {
  return target.submit(tx, { type: "write", requestId, entry: { kind: "agent.notice_context", model } });
}

export const NoticeContextPlacement = defineTask<null, Checkpoint, null>({
  name: "agent.notice_context.place", version: 1, initial: () => ({ phase: "place", placed: null }),
  phases: {
    place: async (task, runtime, context) => {
      const targetId = runtime.conversationId;
      const target = await runtime.conversation(targetId, context);
      if (target === undefined) throw new Error("The target conversation is unavailable");
      await runtime.commit(async (tx) => {
        const state = await heldState(tx, targetId);
        if (state.active !== runtime.taskId) return settled();
        const next = state.held[0];
        if (next === undefined) { state.active = null; return settled(); }
        const run = (await tx.doc(LiveDoc, targetId)).run;
        if (run !== undefined) return { status: "waiting", checkpoint: task.state.checkpoint, on: [run.taskId], policy: "allSettled" };
        const model = noticeContextModel(await tx.entry(next.origin), next.text);
        if (model.length > 0) await admitIn(tx, target, next.request_id, model);
        state.held.shift();
        if (state.held.length > 0) return { status: "running", checkpoint: { phase: "place", placed: next.request_id } };
        state.active = null; return settled();
      }, context);
    },
  },
  abort: async (_task, runtime, context) => {
    await runtime.commit(async (tx) => {
      const state = await heldState(tx, runtime.conversationId);
      if (state.active === runtime.taskId) state.active = null;
      return { status: "terminal", outcome: { status: "aborted" } };
    }, context);
  },
});

/**
 * Add a notice to a target conversation's model context. Pi places a busy
 * conversation's queued writes after a tool round, and a context that then
 * ends in this assistant message ends the run unanswered, so the notice waits
 * until that conversation has no run.
 */
export async function placeNoticeContext(session: Harness, target: Conversation, origin: EntryRecord, requestId: string, text: readonly string[]): Promise<void> {
  await session.commit(async (tx) => {
    if (await tx.submissionByRequest(target.id, requestId) !== undefined) return;
    const state = await heldState(tx, target.id);
    const active = state.active === null ? undefined : await tx.task(state.active);
    if (state.held.length === 0 && (await tx.doc(LiveDoc, target.id)).run === undefined) {
      await admitIn(tx, target, requestId, noticeContextModel(origin, text));
      return;
    }
    if (!state.held.some((held) => held.request_id === requestId)) {
      state.held.push({ request_id: requestId, origin: origin.id, text: [...text] });
    }
    if (active === undefined || active.state.status === "terminal") {
      state.active = await tx.createTask(NoticeContextPlacement, null, { ownership: { kind: "conversation" }, conversationId: target.id, background: true });
    }
  }, BACKGROUND_CONTEXT);
}
