import { ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import type { ActiveWorkChild } from "./generated/ActiveWorkChild.js";
import type { ActiveWorkItem } from "./generated/ActiveWorkItem.js";
import type { ActiveWorkStatus } from "./generated/ActiveWorkStatus.js";
import type { TaskAgentRecord } from "./generated/TaskAgentRecord.js";
import type { TaskGraphActor } from "./generated/TaskGraphActor.js";
import type { TaskGraphBlocked } from "./generated/TaskGraphBlocked.js";
import type { TaskGraphNode } from "./generated/TaskGraphNode.js";
import type { TaskRecord } from "./generated/TaskRecord.js";
import type { TaskState } from "./generated/TaskState.js";
import type { WorkerState } from "./generated/WorkerState.js";
import { excerpt, firstMeaningfulLine } from "./message-presentation.js";
import { isJobTask } from "./tasks.js";

const DETAIL_SUMMARY_LIMIT = 120;
const TOOLS_PER_ITEM_LIMIT = 6;

function workerHostName(worker: WorkerState): string | undefined {
  switch (worker.state) {
    case "allocating":
    case "bound":
    case "resuming":
    case "resume_uncertain":
    case "uncertain":
      return worker.host.name;
    case "unassigned":
      return undefined;
    default: {
      const unsupported: never = worker;
      return unsupported;
    }
  }
}

function isRunningLiveNode(node: TaskGraphNode): boolean {
  return node.blocked === null && node.state.status !== "sleeping";
}

function blockedLabel(blocked: TaskGraphBlocked): string {
  switch (blocked) {
    case "missing_task": return "Worker update required";
    case "task_too_old": return "Task definition updated";
    case "migration_failed": return "Task state migration failed";
    case "restart_limit": return "Restart limit reached";
    default: { const unsupported: never = blocked; return String(unsupported); }
  }
}

function nodeWaitingDetail(nodes: readonly TaskGraphNode[]): string | undefined {
  const blocked = nodes.find((node) => node.blocked !== null)?.blocked;
  if (blocked !== null && blocked !== undefined) return blockedLabel(blocked);
  const sleeping = nodes.find((node) => node.state.status === "sleeping");
  if (sleeping?.state.status === "sleeping") {
    return `Waiting until ${new Date(sleeping.state.until).toISOString()}`;
  }
  return undefined;
}

function earliestStartedAt(nodes: readonly TaskGraphNode[]): number | undefined {
  let earliest: number | undefined;
  for (const node of nodes) {
    if (node.started_at === undefined) continue;
    if (earliest === undefined || node.started_at < earliest) earliest = node.started_at;
  }
  return earliest;
}

function formatConversationTools(nodes: readonly TaskGraphNode[]): string[] {
  const toolNodes = nodes.filter((node): node is TaskGraphNode & { kind: { type: "tool"; name: string } } =>
    node.kind.type === "tool" && node.kind.name !== null);
  const hasNonWrapperTool = toolNodes.some((node) => node.kind.name !== "codemode");
  const visible = hasNonWrapperTool ? toolNodes.filter((node) => node.kind.name !== "codemode") : toolNodes;
  const formatted: string[] = [];
  for (const node of visible) {
    const entry = node.argument_summary === undefined ? node.kind.name : `${node.kind.name}: ${node.argument_summary}`;
    if (!formatted.includes(entry)) formatted.push(entry);
    if (formatted.length >= TOOLS_PER_ITEM_LIMIT) break;
  }
  return formatted;
}

function waitDetail(
  taskSummary: string,
  waiting: Extract<TaskState, { state: "waiting" }>,
): string | undefined {
  const summary = firstMeaningfulLine(taskSummary, DETAIL_SUMMARY_LIMIT);
  if (waiting.target === "owner") return summary;
  const actor = waiting.actor.trim() || "external check";
  if (summary === undefined || summary.toLowerCase().includes(actor.toLowerCase())) {
    return excerpt(`Waiting on ${actor}`, DETAIL_SUMMARY_LIMIT);
  }
  return excerpt(`Waiting on ${actor} · ${summary}`, DETAIL_SUMMARY_LIMIT);
}

function conversationRow(
  id: string,
  conversationId: string,
  title: string,
  nodes: readonly TaskGraphNode[],
): ActiveWorkItem {
  const tools = formatConversationTools(nodes);
  const running = nodes.some(isRunningLiveNode);
  const detail = running ? tools[0] : nodeWaitingDetail(nodes);
  const startedAt = earliestStartedAt(nodes);
  return {
    id,
    conversation_id: conversationId,
    title,
    status: running ? "running" : "waiting_external",
    is_job: false,
    ...(detail === undefined ? {} : { detail }),
    ...(startedAt === undefined ? {} : { started_at: startedAt }),
    ...(tools.length === 0 ? {} : { tools }),
  };
}

function childRow(
  agent: TaskAgentRecord,
  agentNodes: readonly TaskGraphNode[],
  parentHasLiveNodes: boolean,
): ActiveWorkChild | undefined {
  const workerStarting = agent.worker.state === "allocating" || agent.worker.state === "resuming";
  const activeOpen = agent.state.state === "open" && (workerStarting || (parentHasLiveNodes && agent.pending.length > 0));
  if (agentNodes.length === 0 && !activeOpen) return undefined;
  const tools = formatConversationTools(agentNodes);
  const running = agentNodes.some(isRunningLiveNode) || workerStarting;
  const host = workerHostName(agent.worker);
  const detail = tools[0]
    ?? (workerStarting ? "Starting worker" : nodeWaitingDetail(agentNodes))
    ?? excerpt(agent.outcome, DETAIL_SUMMARY_LIMIT);
  return {
    agent_id: agent.id,
    conversation_id: agent.conversation_id,
    title: agent.title,
    status: running ? "running" : "waiting_external",
    ...(host === undefined ? {} : { host }),
    ...(detail === undefined ? {} : { detail }),
    tools,
  };
}

function taskRow(
  task: TaskRecord,
  nodesByConv: ReadonlyMap<string, readonly TaskGraphNode[]>,
  handledConversations: Set<string>,
): ActiveWorkItem | undefined {
  const taskNodes = nodesByConv.get(task.conversation_id) ?? [];
  handledConversations.add(task.conversation_id);

  const children: ActiveWorkChild[] = [];
  for (const agent of task.agents) {
    const agentNodes = nodesByConv.get(agent.conversation_id) ?? [];
    handledConversations.add(agent.conversation_id);
    const child = childRow(agent, agentNodes, taskNodes.length > 0);
    if (child !== undefined) children.push(child);
  }

  const parentStarting = task.worker.state === "allocating" || task.worker.state === "resuming";
  const waitingTask = task.state.state === "waiting";
  if (taskNodes.length === 0 && children.length === 0 && !waitingTask && !parentStarting) return undefined;

  const tools = formatConversationTools(taskNodes);
  const runningChild = children.find((child) => child.status === "running");
  const running = taskNodes.some(isRunningLiveNode) || runningChild !== undefined || parentStarting;

  let status: ActiveWorkStatus;
  let detail: string | undefined;
  if (running) {
    status = "running";
    detail = tools[0]
      ?? (runningChild !== undefined ? `${runningChild.title}${runningChild.detail === undefined ? "" : ` · ${runningChild.detail}`}` : undefined)
      ?? (parentStarting ? "Starting worker" : undefined);
  } else if (task.state.state === "waiting") {
    status = task.state.target === "owner" ? "waiting_owner" : "waiting_external";
    detail = waitDetail(task.summary, task.state);
  } else {
    status = "waiting_external";
    detail = taskNodes.length > 0 ? nodeWaitingDetail(taskNodes) : children[0]?.detail;
  }

  const childNodes = task.agents.flatMap((agent) => nodesByConv.get(agent.conversation_id) ?? []);
  const startedAt = earliestStartedAt([...taskNodes, ...childNodes]) ?? task.started_at ?? task.updated_at;
  const host = workerHostName(task.worker);
  const isJob = isJobTask(task) || task.scheduled_run !== undefined;
  return {
    id: `task:${task.id}`,
    task_id: task.id,
    conversation_id: task.conversation_id,
    title: task.title,
    status,
    is_job: isJob,
    ...(host === undefined ? {} : { host }),
    ...(detail === undefined ? {} : { detail }),
    ...(startedAt === undefined ? {} : { started_at: startedAt }),
    ...(tools.length === 0 ? {} : { tools }),
    ...(children.length === 0 ? {} : { children }),
  };
}

export function buildActiveWork(
  nodes: readonly TaskGraphNode[],
  records: readonly TaskRecord[],
  actors: ReadonlyMap<string, TaskGraphActor>,
): ActiveWorkItem[] {
  const visibleNodes = nodes.filter((node) => !node.background);
  const nodesByConv = new Map<string, TaskGraphNode[]>();
  for (const node of visibleNodes) {
    const existing = nodesByConv.get(node.conversation_id);
    if (existing === undefined) nodesByConv.set(node.conversation_id, [node]);
    else existing.push(node);
  }

  const items: ActiveWorkItem[] = [];
  const handledConversations = new Set<string>();
  const mainId = ROOT_CONVERSATION_ID.toString();
  const mainNodes = nodesByConv.get(mainId) ?? [];
  if (mainNodes.length > 0) {
    handledConversations.add(mainId);
    items.push(conversationRow("main", mainId, "Main", mainNodes));
  }

  for (const task of records) {
    const row = taskRow(task, nodesByConv, handledConversations);
    if (row !== undefined) items.push(row);
  }

  for (const [conversationId, convNodes] of nodesByConv) {
    if (handledConversations.has(conversationId)) continue;
    const actor = actors.get(conversationId);
    const title = actor?.type === "task" || actor?.type === "agent"
      ? actor.title
      : `Conversation ${conversationId}`;
    items.push(conversationRow(`conv:${conversationId}`, conversationId, title, convNodes));
  }

  const rank = (status: ActiveWorkStatus): number => status === "running" ? 0 : status === "waiting_owner" ? 1 : 2;
  items.sort((left, right) => {
    const byStatus = rank(left.status) - rank(right.status);
    if (byStatus !== 0) return byStatus;
    if (left.id === "main" && right.id !== "main") return -1;
    if (right.id === "main" && left.id !== "main") return 1;
    const byStart = (left.started_at ?? Number.MAX_SAFE_INTEGER) - (right.started_at ?? Number.MAX_SAFE_INTEGER);
    if (byStart !== 0) return byStart;
    return left.id.localeCompare(right.id);
  });
  return items;
}
