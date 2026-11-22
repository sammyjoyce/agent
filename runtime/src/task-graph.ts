import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { GenerationTask, LiveDoc, ROOT_CONVERSATION_ID, ToolTask, type JoinPolicy,
  type LiveState, type TaskGraphNode as NativeNode, type TaskGraphState as NativeState,
  type TaskInspection } from "@earendil-works/pi-durable";
import type { TaskGraphActor } from "./generated/TaskGraphActor.js";
import type { TaskGraphConversation } from "./generated/TaskGraphConversation.js";
import type { TaskGraphJoinPolicy } from "./generated/TaskGraphJoinPolicy.js";
import type { TaskGraphNode } from "./generated/TaskGraphNode.js";
import type { TaskGraphSnapshot } from "./generated/TaskGraphSnapshot.js";
import type { TaskGraphState } from "./generated/TaskGraphState.js";
import { buildActiveWork } from "./active-work.js";
import { firstMeaningfulLine, piToolPresentation, toolPresentationSummary } from "./message-presentation.js";
import { TaskError, type TaskStore } from "./tasks.js";
import { watchDerived } from "./watch-derived.js";

export const TASK_GRAPH_NODE_LIMIT = 500;
export const TASK_GRAPH_BYTE_LIMIT = 1024 * 1024;
const ARGUMENT_SUMMARY_LIMIT = 100;

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

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function summarizeArguments(toolName: string | undefined, args: Record<string, unknown> | undefined): string | undefined {
  if (args === undefined) return undefined;
  if (toolName !== undefined) {
    const summary = toolPresentationSummary(
      piToolPresentation({ name: toolName, arguments: args }, "coordinator"),
      ARGUMENT_SUMMARY_LIMIT,
    );
    if (summary !== undefined) return summary;
  }
  for (const key of ["command", "path", "file", "url", "query", "title", "task_id", "conversation_id", "input"]) {
    const candidate = args[key];
    if (typeof candidate === "string") {
      const text = firstMeaningfulLine(candidate, ARGUMENT_SUMMARY_LIMIT);
      if (text !== undefined) return text;
    }
  }
  if (typeof args.code === "string") {
    return firstMeaningfulLine(args.code, ARGUMENT_SUMMARY_LIMIT);
  }
  return undefined;
}

function checkpointArguments(inspection: TaskInspection | undefined): Record<string, unknown> | undefined {
  if (inspection === undefined) return undefined;
  const state: unknown = inspection.record.state;
  if (!isObjectRecord(state) || !isObjectRecord(state.checkpoint)) return undefined;
  return isObjectRecord(state.checkpoint.arguments) ? state.checkpoint.arguments : undefined;
}

async function readLiveDocs(tasks: TaskStore, nodes: readonly NativeNode[]): Promise<Map<string, Readonly<LiveState>>> {
  const docs = new Map<string, Readonly<LiveState>>();
  for (const conversationId of new Set(nodes.filter((node) => node.kind === ToolTask.definition.name).map((node) => node.conversationId))) {
    const state = await tasks.session.snapshot(LiveDoc, conversationId, BACKGROUND_CONTEXT);
    if (state !== undefined) docs.set(conversationId.toString(), state);
  }
  return docs;
}

function extractToolInfo(liveDocs: ReadonlyMap<string, Readonly<LiveState>>, inspections: ReadonlyMap<number, TaskInspection>,
  nodes: readonly NativeNode[]): { names: Map<number, string>; summaries: Map<number, string> } {
  const names = new Map<number, string>();
  const nestedArgs = new Map<number, Record<string, unknown>>();
  for (const state of liveDocs.values()) {
    for (const slot of state.tools ?? []) {
      if (slot.taskId !== undefined) names.set(Number(slot.taskId), slot.name);
    }
    for (const slot of state.nestedTools ?? []) {
      const taskId = Number(slot.taskId);
      names.set(taskId, slot.name);
      if (isObjectRecord(slot.arguments)) nestedArgs.set(taskId, slot.arguments);
    }
  }
  const summaries = new Map<number, string>();
  for (const node of nodes) {
    if (node.kind !== ToolTask.definition.name) continue;
    const name = names.get(node.id);
    const args = nestedArgs.get(node.id) ?? checkpointArguments(inspections.get(node.id));
    const summary = summarizeArguments(name, args);
    if (summary !== undefined) summaries.set(node.id, summary);
  }
  return { names, summaries };
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
  const [liveDocs, inspected, actors, records] = await Promise.all([
    readLiveDocs(tasks, listed),
    tasks.session.inspect(BACKGROUND_CONTEXT),
    currentActors(tasks, listed),
    tasks.list(),
  ]);
  const inspections = new Map(inspected.tasks.map((entry) => [Number(entry.record.id), entry]));
  const { names: tools, summaries } = extractToolInfo(liveDocs, inspections, listed);

  const nodes: TaskGraphNode[] = listed.map((node): TaskGraphNode => {
    const startedAt = inspections.get(node.id)?.record.startedAt;
    const argumentSummary = summaries.get(node.id);
    return {
      id: node.id, conversation_id: node.conversationId.toString(), owner: node.owner ?? null,
      background: node.background, abort_requested: node.abortRequested, state: graphState(node.state), blocked: node.blocked ?? null,
      conversations: node.conversations.map((id) => id.toString()),
      kind: node.kind === GenerationTask.definition.name ? { type: "generation" }
        : node.kind === ToolTask.definition.name ? { type: "tool", name: tools.get(node.id) ?? null } : { type: "other", name: node.kind },
      ...(startedAt === undefined ? {} : { started_at: startedAt }),
      ...(argumentSummary === undefined ? {} : { argument_summary: argumentSummary }),
    };
  });

  const snapshot: TaskGraphSnapshot = {
    nodes,
    conversations: [...actors].sort(([left], [right]) => Number(left) - Number(right))
      .map(([conversation_id, actor]): TaskGraphConversation => ({ conversation_id, actor })),
    omitted: live.length - listed.length,
    work: buildActiveWork(nodes, records, actors),
  };
  if (Buffer.byteLength(JSON.stringify(snapshot)) > TASK_GRAPH_BYTE_LIMIT) {
    throw new TaskError("The task graph is too large to send; read one task with tasks read");
  }
  return snapshot;
}

export async function watchTaskGraph(
  tasks: TaskStore,
  emit: (graph: TaskGraphSnapshot) => void,
  failed: (error: unknown) => void,
): Promise<() => Promise<void>> {
  return watchDerived({
    read: () => readTaskGraph(tasks),
    identity: (graph) => JSON.stringify(graph),
    subscribe: async (schedule) => {
      const graphObs = await tasks.session.observeTaskGraph({
        advance() { schedule(); },
        end() {},
      }, BACKGROUND_CONTEXT);
      const commits = tasks.session.observeCommits({
        advance(publication) {
          const relevant = publication.changes.some((change) => {
            if (change.type === "task") return true;
            if (change.type !== "document") return false;
            if (change.record.kind.startsWith("agent.task")) return true;
            if (change.record.kind === LiveDoc.definition.kind) {
              return change.kind !== "change" || change.ops.length === 0 || change.ops.some((op) => {
                const path = op[1];
                return Array.isArray(path) && (path[0] === "tools" || path[0] === "nestedTools" || path[0] === "run");
              });
            }
            return false;
          });
          if (relevant) schedule();
        },
        end() {},
      });
      return () => {
        commits.detach();
        graphObs.detach();
      };
    },
    emit,
    failed,
  });
}
