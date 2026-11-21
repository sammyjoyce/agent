import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { GenerationTask, LiveDoc, ROOT_CONVERSATION_ID, ToolTask, type JoinPolicy, type TaskGraphNode as NativeNode,
  type TaskGraphState as NativeState } from "@earendil-works/pi-durable";
import type { TaskGraphActor } from "./generated/TaskGraphActor.js";
import type { TaskGraphConversation } from "./generated/TaskGraphConversation.js";
import type { TaskGraphJoinPolicy } from "./generated/TaskGraphJoinPolicy.js";
import type { TaskGraphNode } from "./generated/TaskGraphNode.js";
import type { TaskGraphSnapshot } from "./generated/TaskGraphSnapshot.js";
import type { TaskGraphState } from "./generated/TaskGraphState.js";
import { TaskError, type TaskStore } from "./tasks.js";

export const TASK_GRAPH_NODE_LIMIT = 500;
export const TASK_GRAPH_BYTE_LIMIT = 1024 * 1024;

function joinPolicy(policy: JoinPolicy): TaskGraphJoinPolicy {
  switch (policy) {
    case "failFast": return "fail_fast";
    case "allSettled": return "all_settled";
    case "any": throw new Error("Unsupported Pi join policy: any");
    default: { const unsupported: never = policy; throw new Error("Unsupported Pi join policy: " + JSON.stringify(unsupported)); }
  }
}

function graphState(state: NativeState): TaskGraphState {
  switch (state.status) {
    case "pending": case "running": return { status: state.status, phase: state.phase };
    case "waiting": return { status: "waiting", phase: state.phase, on: [...state.on], policy: joinPolicy(state.policy) };
    case "sleeping": return state.until === undefined ? { status: "waiting", phase: state.phase, on: [], policy: "all_settled" } : { status: "sleeping", phase: state.phase, until: state.until };
    case "completing": return { status: "completing", outcome: state.outcome };
    default: { const unsupported: never = state; throw new Error("Unsupported Pi task state: " + JSON.stringify(unsupported)); }
  }
}

async function liveFrame(tasks: TaskStore): Promise<NativeNode[]> {
  const observed = await tasks.session.observeTaskGraph({ advance() {}, end() {} }, BACKGROUND_CONTEXT);
  try { return Object.values(observed.value.tasks); } finally { observed.detach(); }
}

function shallowestFirst(live: readonly NativeNode[], limit: number): NativeNode[] {
  const owners = new Map(live.map((node) => [node.id, node.owner]));
  const depth = (node: NativeNode): number => {
    let count = 0;
    for (let owner = node.owner; owner !== undefined; owner = owners.get(owner)) count += 1;
    return count;
  };
  return live.map((node) => ({ node, depth: depth(node) }))
    .sort((left, right) => left.depth - right.depth || left.node.id - right.node.id)
    .slice(0, limit).map(({ node }) => node);
}

async function currentToolNames(tasks: TaskStore, nodes: readonly NativeNode[]): Promise<Map<number, string>> {
  const names = new Map<number, string>();
  for (const conversationId of new Set(nodes.filter((node) => node.kind === ToolTask.definition.name).map((node) => node.conversationId))) {
    const state = await tasks.session.snapshot(LiveDoc, conversationId, BACKGROUND_CONTEXT);
    for (const slot of [...state?.tools ?? [], ...state?.nestedTools ?? []]) if (slot.taskId !== undefined) names.set(slot.taskId, slot.name);
  }
  return names;
}

async function currentActors(tasks: TaskStore, nodes: readonly NativeNode[]): Promise<Map<string, TaskGraphActor>> {
  const actors = new Map<string, TaskGraphActor>();
  for (const native of new Set(nodes.flatMap((node) => [node.conversationId, ...node.conversations]))) {
    const id = native.toString();
    if (native === ROOT_CONVERSATION_ID) { actors.set(id, { type: "main" }); continue; }
    const owner = await tasks.findOwner(id);
    if (owner === undefined) { actors.set(id, { type: "other" }); continue; }
    const { task, agent } = owner, parent: TaskGraphActor = { type: "task", task_id: task.id, title: task.title };
    if (agent === undefined) { actors.set(id, parent); continue; }
    actors.set(id, { type: "agent", task_id: task.id, agent_id: agent.id, title: agent.title, parent_conversation_id: task.conversation_id });
    actors.set(task.conversation_id, parent);
  }
  return actors;
}

export async function readTaskGraph(tasks: TaskStore): Promise<TaskGraphSnapshot> {
  const live = await liveFrame(tasks);
  const listed = shallowestFirst(live, TASK_GRAPH_NODE_LIMIT);
  const tools = await currentToolNames(tasks, listed), actors = await currentActors(tasks, listed);
  const snapshot: TaskGraphSnapshot = {
    nodes: listed.map((node): TaskGraphNode => ({
      id: node.id, conversation_id: node.conversationId.toString(), owner: node.owner ?? null,
      background: node.background, abort_requested: node.abortRequested, state: graphState(node.state), blocked: node.blocked ?? null,
      conversations: node.conversations.map((id) => id.toString()),
      kind: node.kind === GenerationTask.definition.name ? { type: "generation" }
        : node.kind === ToolTask.definition.name ? { type: "tool", name: tools.get(node.id) ?? null } : { type: "other", name: node.kind },
    })),
    conversations: [...actors].sort(([left], [right]) => Number(left) - Number(right))
      .map(([conversation_id, actor]): TaskGraphConversation => ({ conversation_id, actor })),
    omitted: live.length - listed.length,
  };
  if (Buffer.byteLength(JSON.stringify(snapshot)) > TASK_GRAPH_BYTE_LIMIT) {
    throw new TaskError("The task graph is too large to send; read one task with tasks read");
  }
  return snapshot;
}
