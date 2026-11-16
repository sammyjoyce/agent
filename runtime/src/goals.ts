import { createHash } from "node:crypto";
import { Type } from "typebox";
import { copyJson } from "@earendil-works/chord";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineDocFamily, defineEntry, defineExtension, defineTool, GenerationTask, LiveDoc, ROOT_CONVERSATION_ID,
  type ConversationId, type Extension, type Harness, type TaskId as NativeTaskId, type Tx } from "@earendil-works/pi-durable";
import { EnvironmentError, type CoordinatorEnvironment } from "./environment.js";
import type { Goal } from "./generated/Goal.js";
import type { GoalCheck } from "./generated/GoalCheck.js";
import type { GoalCheckFailure } from "./generated/GoalCheckFailure.js";
import type { GoalCheckResult } from "./generated/GoalCheckResult.js";
import type { GoalPause } from "./generated/GoalPause.js";
import type { GoalStatus } from "./generated/GoalStatus.js";
import type { GoalTarget } from "./generated/GoalTarget.js";
import type { GoalVerification } from "./generated/GoalVerification.js";
import type { ObservedFile } from "./generated/ObservedFile.js";
import type { RuntimeCommand } from "./generated/RuntimeCommand.js";
import type { TaskInput } from "./generated/TaskInput.js";
import type { TaskRecord } from "./generated/TaskRecord.js";
import type { WorkerHost } from "./generated/WorkerHost.js";
import { output } from "./host-output.js";
import { validEvent } from "./protocol.js";
import { nativeConversationId, TaskError, type HostCall, type TaskStore } from "./tasks.js";
import { MAX_FILE_READ_BYTES, resolveHostPath, type Execution, type Executions } from "./tools.js";

/** Automatic continuations one activation may admit before the goal pauses itself. */
export const GOAL_CONTINUATION_BUDGET = 5;
const OBJECTIVE_LIMIT = 4000;
const TITLE_LIMIT = 80;

type GoalSlot = { goal: Goal | null };
const GoalDoc = defineDocFamily<GoalSlot, null>({ kind: "agent.goal", scope: "session", family: true, version: 1,
  initial: () => ({ goal: null }), checkpointWhen: () => true });
type MainPointer = { task_id: string | null; goal_id: string | null };
const MainGoal = defineDoc<MainPointer>({ kind: "agent.goal.main", scope: "session", version: 1,
  initial: () => ({ task_id: null, goal_id: null }), checkpointWhen: () => true });
type GoalControl = { action: "set" | "pause" | "resume"; objective: string | null };
/** The control one request ID was accepted for, kept for good so a replay at any later time changes nothing. */
type GoalRequest = GoalControl & { main: boolean; task_id: string; goal_id: string };
const GoalRequests = defineDocFamily<{ request: GoalRequest | null }, null>({ kind: "agent.goal.request", scope: "session", family: true,
  version: 1, initial: () => ({ request: null }), checkpointWhen: () => true });
/** Retained in the owning task's conversation for every check the runtime runs. */
export const GoalVerificationEntry = defineEntry<GoalVerification>("agent.goal_verification");

type GoalCommand = Extract<RuntimeCommand, { type: "goal" }>;
type Selected = { kind: "main" } | { kind: "task"; task: TaskRecord };
type Origin = { conversation_id: string; entry_id: string; tool_call_id: string };
/** Stops one exact native run of the goal's task. The bridge owns the worker's host-call cancellation. */
export type StopTurn = (taskId: string, run: NativeTaskId) => Promise<void>;

class Proof {
  readonly #brand = true;
  constructor(readonly goal_id: string, readonly activation: number, readonly check: GoalCheck, readonly observed: ObservedFile) {}
  /** Only this module constructs a Proof, so a copied object with the same fields is refused. */
  static minted(value: unknown): value is Proof { return typeof value === "object" && value !== null && #brand in value; }
}
export type GoalProof = Proof;
export type ResolutionAttempt = { origin?: Origin; proof?: GoalProof };
export type ResolutionVerdict = { type: "allowed"; evidence?: string } | { type: "rejected"; message: string };

/** TaskStore's view of goals. The two `In` methods run inside a TaskStore commit. */
export type GoalPolicy = {
  /** At an idle primary actor, the next goal input, counted in this commit, or none. Pauses the goal when its budget
   * is used or its latest generation was stopped. */
  continuationIn(tx: Tx, task: TaskRecord, conversationId: ConversationId): Promise<TaskInput | undefined>;
  /** Every transition of a task to resolved. A task with an unfinished goal resolves only with a proof for its current
   * activation. A refused attempt with an origin is recorded on the goal. */
  resolutionIn(tx: Tx, task: TaskRecord, attempt: ResolutionAttempt): Promise<ResolutionVerdict>;
  /** Whether `/goal pause` stopped this goal input, so its actor ends the turn without aborting the conversation. */
  stopped(taskId: string, inputId: string): Promise<boolean>;
};

export type GoalCheckReply = { passed: true; goal: "complete"; check: GoalCheck; observed: ObservedFile } |
  { passed: false; check: GoalCheck; failure: GoalCheckFailure; verification_entry_id: string; continuations_left: number };

const PREMATURE = "This task's goal is unfinished. It completes, and the task resolves, only when complete_goal verifies the outcome. This attempt is recorded on the goal.";
const UNFINISHED = "This conversation already has an unfinished goal. Show it with /goal.";
const NO_GOAL = "No goal is set for this conversation. Set one with /goal OBJECTIVE.";
const COMPLETE = "This goal is already complete. Set a new one with /goal OBJECTIVE.";
const AGENT = "An agent reports to its task. Set the goal from the task's conversation.";
const CHANGED = "The goal was paused or resumed during verification. Check it again in the current activation.";
const REUSED = "This goal request ID was already used for another control. Send the control again with a new request ID.";

export class GoalStore implements GoalPolicy {
  constructor(private readonly session: Harness, private readonly tasks: TaskStore, private readonly environment: CoordinatorEnvironment,
    private readonly stopTurn: StopTurn, private readonly budget = GOAL_CONTINUATION_BUDGET) {
    tasks.useGoals(this);
  }

  /** The whole `/goal` control. `call` reaches the requesting client, which dispatches the owning task's worker. */
  async handle(command: GoalCommand, call: HostCall): Promise<GoalStatus> {
    const selected = await this.select(command.target);
    const action = command.action;
    switch (action.type) {
      case "show": return this.status(selected);
      case "set": return this.set(selected, requestId(action.request_id), action.objective, call);
      case "pause": return this.pause(selected, requestId(action.request_id));
      case "resume": return this.resume(selected, requestId(action.request_id), call);
      default: { const unhandled: never = action; throw new TaskError(`Unknown goal control ${JSON.stringify(unhandled)}`); }
    }
  }

  private async select(target: GoalTarget): Promise<Selected> {
    switch (target.type) {
      case "main": return { kind: "main" };
      case "task":
        if (target.agent_id !== null) throw new TaskError(AGENT);
        return this.ordinary(await this.tasks.get(target.task_id));
      case "conversation": {
        if (target.conversation_id === ROOT_CONVERSATION_ID.toString()) return { kind: "main" };
        const owner = await this.tasks.findOwner(target.conversation_id);
        if (owner === undefined) throw new TaskError("This conversation has no task yet. Continue it with a message, then set its goal.");
        if (owner.agent !== undefined) throw new TaskError(AGENT);
        return this.ordinary(owner.task);
      }
      default: { const unhandled: never = target; throw new TaskError(`Unknown goal target ${JSON.stringify(unhandled)}`); }
    }
  }
  private ordinary(task: TaskRecord): Selected {
    if (this.tasks.isBackgroundTask(task)) throw new TaskError("A scheduled job's task follows its job file. Set the goal from the main conversation.");
    return { kind: "task", task };
  }

  private async goalIn(tx: Tx, selected: Selected): Promise<Goal | null> {
    if (selected.kind === "task") return (await tx.doc(GoalDoc, selected.task.id, null)).goal;
    const pointer = await tx.doc(MainGoal);
    if (pointer.task_id === null) return null;
    const goal = (await tx.doc(GoalDoc, pointer.task_id, null)).goal;
    return goal !== null && goal.id === pointer.goal_id ? goal : null;
  }
  /** The receipt of this request, created empty for the commit to fill. A commit that accepts nothing throws, so an
   * empty receipt is never kept. */
  private async receiptIn(tx: Tx, selected: Selected, request: string, control: GoalControl) {
    const receipt = await tx.doc(GoalRequests, request, null);
    return { receipt, replay: replayOf(receipt.request, selected, control) };
  }
  private async committedReplay(selected: Selected, request: string, control: GoalControl): Promise<GoalRequest | undefined> {
    return replayOf((await this.session.snapshot(GoalRequests, request, BACKGROUND_CONTEXT))?.request, selected, control);
  }

  /** The goal and its task come from one transaction, so a status never pairs a goal with another moment's task. */
  private async status(selected: Selected): Promise<GoalStatus> {
    const conversation_id = selected.kind === "main" ? ROOT_CONVERSATION_ID.toString() : selected.task.conversation_id;
    const view = await this.session.commit(async (tx) => {
      const goal = await this.goalIn(tx, selected);
      if (goal === null) return null;
      const task = await this.tasks.findIn(tx, goal.task_id);
      if (task === undefined) throw new TaskError("Unknown task");
      return copyJson({ goal, task });
    }, BACKGROUND_CONTEXT);
    const frame: unknown = { version: 1, id: 0, event: { type: "goal", status: { conversation_id, goal: view } } };
    if (!validEvent(frame) || frame.event.type !== "goal") throw new TaskError("The saved goal does not match the goal protocol");
    return frame.event.status;
  }

  private async set(selected: Selected, request: string, objective: string, call: HostCall): Promise<GoalStatus> {
    const text = objective.trim();
    if (text.length === 0 || text.length > OBJECTIVE_LIMIT) throw new TaskError(`A goal needs an objective of 1 to ${OBJECTIVE_LIMIT} characters`);
    const control: GoalControl = { action: "set", objective: text };
    const known = await this.committedReplay(selected, request, control);
    if (known !== undefined) return this.replayed(selected, known.goal_id, call);
    const host = selected.kind === "main" ? await this.defaultHost() : undefined;
    const model = host === undefined ? undefined : host.launch?.model ?? await this.environment.model(null);
    if (model !== undefined) await this.tasks.inference.preflight(model);
    const taskId = selected.kind === "task" ? selected.task.id : taskRequestId(request);
    type Admission = { type: "replayed"; goal_id: string } | { type: "set"; created: ConversationId | undefined };
    const admitted = await this.tasks.admitWith(taskId, async (tx): Promise<{ value: Admission; input?: TaskInput }> => {
      const { receipt, replay } = await this.receiptIn(tx, selected, request, control);
      if (replay !== undefined) return { value: { type: "replayed", goal_id: replay.goal_id } };
      let created: ConversationId | undefined;
      const current = await this.goalIn(tx, selected);
      if (current !== null && current.state.state !== "complete") throw new TaskError(UNFINISHED);
      if (selected.kind === "main") {
        if (model === undefined) throw new TaskError("The coordinator model is unavailable");
        if (await this.tasks.findIn(tx, taskId) !== undefined) throw new TaskError("This goal request ID already names a task");
        created = (await this.tasks.createIn(tx, { id: taskId, title: title(text), outcome: text, model })).native;
        Object.assign(await tx.doc(MainGoal), { task_id: taskId, goal_id: request });
      }
      const now = Date.now();
      const goal: Goal = { id: request, task_id: taskId, objective: text, state: { state: "active" }, last_rejection: null,
        activation: { number: 1, request_id: request, continuations: 0, budget: this.budget, check: null }, created_at: now, updated_at: now };
      (await tx.doc(GoalDoc, taskId, null)).goal = goal;
      receipt.request = { ...control, main: selected.kind === "main", task_id: taskId, goal_id: goal.id };
      return { value: { type: "set", created }, input: { id: inputId(goal, 0), content: objectiveText(goal), mode: "follow_up" } };
    });
    if (admitted.type === "replayed") return this.replayed(selected, admitted.goal_id, call);
    if (admitted.created !== undefined) this.tasks.rememberConversation(admitted.created);
    await this.ensureRunning(taskId, host, call);
    return this.status(selected);
  }

  /** A replay changes nothing. The goal it named still gets its worker while active, so a crash before dispatch converges. */
  private async replayed(selected: Selected, goalId: string, call: HostCall): Promise<GoalStatus> {
    const status = await this.status(selected);
    const goal = status.goal?.goal;
    if (goal === undefined || goal.id !== goalId || goal.state.state !== "active") return status;
    await this.ensureRunning(goal.task_id, undefined, call);
    return this.status(selected);
  }

  /** A replayed pause on the goal it paused repeats only the stop, so a crash between the commit and the stop converges. */
  private async pause(selected: Selected, request: string): Promise<GoalStatus> {
    const control: GoalControl = { action: "pause", objective: null };
    const paused = await this.session.commit(async (tx) => {
      const goal = await this.goalIn(tx, selected);
      const { receipt, replay } = await this.receiptIn(tx, selected, request, control);
      if (replay === undefined) {
        if (goal === null) throw new TaskError(NO_GOAL);
        if (goal.state.state === "complete") throw new TaskError(COMPLETE);
        if (goal.state.state === "active") pauseIn(goal, "requested");
        receipt.request = { ...control, main: selected.kind === "main", task_id: goal.task_id, goal_id: goal.id };
      }
      if (goal === null || goal.state.state !== "paused" || (replay !== undefined && replay.goal_id !== goal.id)) return undefined;
      // Pi's unplaced-abort receipt claims each request ID, so an actor that read the outbox earlier starts no turn.
      await this.tasks.withdrawIn(tx, goal.task_id, undefined, (input) => input.id.startsWith(inputPrefix(goal)));
      return { task_id: goal.task_id, latest: inputId(goal, goal.activation.continuations) };
    }, BACKGROUND_CONTEXT);
    if (paused !== undefined) await this.stopInput(paused.task_id, paused.latest);
    return this.status(selected);
  }

  private async stopInput(taskId: string, latest: string): Promise<void> {
    const conversation = await this.tasks.conversation((await this.tasks.get(taskId)).conversation_id);
    const native = await this.session.commit((tx) => tx.submissionByRequest(conversation.id, latest), BACKGROUND_CONTEXT);
    if (native === undefined || native.status === "done" || native.status === "unanswered") return;
    if (native.status === "queued" && await this.session.abortSubmission(native.id, BACKGROUND_CONTEXT, conversation.id) !== "already_placed") return;
    const run = (await this.session.snapshot(LiveDoc, conversation.id, BACKGROUND_CONTEXT))?.run;
    if (run !== undefined && run.inputs.includes(native.id)) await this.stopTurn(taskId, run.taskId);
  }

  private async resume(selected: Selected, request: string, call: HostCall): Promise<GoalStatus> {
    const control: GoalControl = { action: "resume", objective: null };
    const replayed = await this.committedReplay(selected, request, control);
    if (replayed !== undefined) return this.replayed(selected, replayed.goal_id, call);
    const known = (await this.status(selected)).goal?.goal;
    if (known === undefined) throw new TaskError(NO_GOAL);
    const replay = await this.tasks.admitWith(known.task_id, async (tx): Promise<{ value: string | undefined; input?: TaskInput }> => {
      const goal = await this.goalIn(tx, selected);
      const { receipt, replay } = await this.receiptIn(tx, selected, request, control);
      if (replay !== undefined) return { value: replay.goal_id };
      if (goal === null || goal.id !== known.id) throw new TaskError("The goal changed. Show it with /goal.");
      if (goal.state.state === "complete") throw new TaskError(COMPLETE);
      receipt.request = { ...control, main: selected.kind === "main", task_id: goal.task_id, goal_id: goal.id };
      if (goal.state.state === "active") return { value: undefined };
      goal.activation = { number: goal.activation.number + 1, request_id: request, continuations: 0, budget: this.budget, check: null };
      goal.state = { state: "active" }; goal.updated_at = Date.now();
      return { value: undefined, input: { id: inputId(goal, 0), content: resumeText(goal), mode: "follow_up" } };
    });
    if (replay !== undefined) return this.replayed(selected, replay, call);
    await this.ensureRunning(known.task_id, undefined, call);
    return this.status(selected);
  }

  private async ensureRunning(taskId: string, chosen: WorkerHost | undefined, call: HostCall): Promise<void> {
    try {
      const task = await this.tasks.get(taskId);
      const host = task.worker.state === "unassigned" ? chosen ?? await this.defaultHost() : await this.tasks.workerHost(taskId);
      await this.tasks.dispatch(taskId, host, call);
    } catch (error) {
      if (!(error instanceof TaskError || error instanceof EnvironmentError)) throw error;
      throw new TaskError(`The goal is saved, but its task could not start. ${error.message.replace(/\.$/, "")}. Run /goal resume to retry.`);
    }
  }
  private async defaultHost(): Promise<WorkerHost> {
    const host = await this.environment.defaultHost(await this.environment.hosts("/", null, []));
    if (host === null) throw new TaskError("The coordinator execution host is offline");
    return host;
  }

  async continuationIn(tx: Tx, task: TaskRecord, conversationId: ConversationId): Promise<TaskInput | undefined> {
    const goal = (await tx.doc(GoalDoc, task.id, null)).goal;
    if (goal === null || goal.state.state !== "active") return undefined;
    if (task.state.state === "waiting") return undefined;
    const latest = (await tx.scanTasks({ conversationId, kind: GenerationTask.definition.name, order: "descending" }, 1)).items[0];
    if (latest?.state.status === "terminal" && latest.state.outcome.status === "aborted") return pauseIn(goal, "interrupted");
    if (goal.activation.continuations >= goal.activation.budget) return pauseIn(goal, "budget_exhausted");
    goal.activation.continuations += 1; goal.updated_at = Date.now();
    return { id: inputId(goal, goal.activation.continuations), content: continuationText(goal, task), mode: "follow_up" };
  }

  async resolutionIn(tx: Tx, task: TaskRecord, attempt: ResolutionAttempt): Promise<ResolutionVerdict> {
    const goal = (await tx.doc(GoalDoc, task.id, null)).goal;
    const proof = attempt.proof;
    if (goal === null || goal.state.state === "complete") {
      return proof === undefined ? { type: "allowed" } : { type: "rejected", message: "This task has no unfinished goal" };
    }
    if (proof === undefined) {
      if (attempt.origin !== undefined) {
        const now = Date.now();
        goal.last_rejection = { type: "premature_resolution", ...attempt.origin, at: now }; goal.updated_at = now;
      }
      return { type: "rejected", message: PREMATURE };
    }
    if (!Proof.minted(proof)) return { type: "rejected", message: "A goal completes only through complete_goal" };
    if (attempt.origin === undefined) throw new TaskError("A goal verification needs its tool call provenance");
    if (goal.state.state !== "active" || proof.goal_id !== goal.id || proof.activation !== goal.activation.number) {
      return { type: "rejected", message: CHANGED };
    }
    if (goal.activation.check !== null && !sameCheck(goal.activation.check, proof.check)) {
      return { type: "rejected", message: `This activation verifies ${describe(goal.activation.check)}` };
    }
    const entry = await tx.appendEntry(GoalVerificationEntry, nativeConversationId(task.conversation_id), { data: {
      goal_id: goal.id, task_id: task.id, activation: goal.activation.number, check: proof.check,
      result: { type: "passed", observed: proof.observed }, origin_entry_id: attempt.origin.entry_id, tool_call_id: attempt.origin.tool_call_id } });
    const now = Date.now();
    goal.activation.check ??= proof.check;
    goal.state = { state: "complete", evidence: { entry_id: entry.id.toString(), activation: goal.activation.number, check: proof.check,
      observed: proof.observed, tool_call_id: attempt.origin.tool_call_id, verified_at: now } };
    goal.updated_at = now;
    return { type: "allowed", evidence: `Goal verified by the runtime. ${describe(proof.check)} (verification entry ${entry.id}, sha256 ${proof.observed.sha256})` };
  }

  async stopped(taskId: string, id: string): Promise<boolean> {
    const goal = (await this.session.snapshot(GoalDoc, taskId, BACKGROUND_CONTEXT))?.goal ?? null;
    if (goal === null || !id.startsWith(inputPrefix(goal))) return false;
    return goal.state.state === "paused" || fromEarlierActivation(goal, id);
  }

  async complete(origin: { conversation_id: string; call_id: string; native_task_id: NativeTaskId },
    request: { check: GoalCheck; summary: string }, execution: Execution): Promise<GoalCheckReply> {
    const owner = await this.tasks.owner(origin.conversation_id);
    if (owner.agent !== undefined) throw new TaskError("The task's parent worker completes its goal");
    const task = owner.task;
    const goal = (await this.session.snapshot(GoalDoc, task.id, BACKGROUND_CONTEXT))?.goal ?? null;
    if (goal === null || goal.state.state === "complete") throw new TaskError("This task has no unfinished goal");
    if (goal.state.state === "paused") throw new TaskError("The goal is paused. It continues after /goal resume.");
    if (!this.tasks.canResolve(task)) throw new TaskError("Wait for unfinished task agents before completing the goal");
    const check = pinnable(request.check, execution);
    if (goal.activation.check !== null && !sameCheck(goal.activation.check, check)) {
      throw new TaskError(`This activation already verifies ${describe(goal.activation.check)}. Complete that check.`);
    }
    const result = await runCheck(check, execution.call);
    switch (result.type) {
      case "failed": return this.recordFailure(task, goal, check, result.failure, origin);
      case "passed":
        await this.tasks.record(task.id, { summary: request.summary, state: { state: "resolved", evidence: "Goal check passed" } },
          { conversation_id: origin.conversation_id, call_id: origin.call_id, settled: false, native_task_id: origin.native_task_id },
          new Proof(goal.id, goal.activation.number, check, result.observed));
        return { passed: true, goal: "complete", check, observed: result.observed };
      default: { const unhandled: never = result; throw new TaskError(`Unknown check result ${JSON.stringify(unhandled)}`); }
    }
  }

  private async recordFailure(task: TaskRecord, checked: Goal, check: GoalCheck, failure: GoalCheckFailure,
    origin: { conversation_id: string; call_id: string }): Promise<GoalCheckReply> {
    const conversation = await this.tasks.conversation(task.conversation_id);
    const originEntry = await this.tasks.origin(conversation, origin.call_id);
    return this.session.commit(async (tx) => {
      const goal = (await tx.doc(GoalDoc, task.id, null)).goal;
      if (goal === null || goal.id !== checked.id || goal.state.state !== "active" || goal.activation.number !== checked.activation.number) {
        throw new TaskError(CHANGED);
      }
      if (goal.activation.check !== null && !sameCheck(goal.activation.check, check)) {
        throw new TaskError(`This activation already verifies ${describe(goal.activation.check)}. Complete that check.`);
      }
      const entry = await tx.appendEntry(GoalVerificationEntry, conversation.id, { data: {
        goal_id: goal.id, task_id: task.id, activation: goal.activation.number, check, result: { type: "failed", failure },
        origin_entry_id: originEntry.id.toString(), tool_call_id: origin.call_id } });
      const now = Date.now();
      goal.activation.check ??= check;
      goal.last_rejection = { type: "failed_check", entry_id: entry.id.toString(), activation: goal.activation.number, check, failure,
        tool_call_id: origin.call_id, at: now };
      goal.updated_at = now;
      return { passed: false, check, failure, verification_entry_id: entry.id.toString(),
        continuations_left: goal.activation.budget - goal.activation.continuations };
    }, BACKGROUND_CONTEXT);
  }
}

const goalCheck = Type.Union([Type.Object({ type: Type.Literal("file_contains"), path: Type.String({ minLength: 1 }),
  text: Type.String({ minLength: 1, maxLength: 4096 }) })]);

/** Worker-only. The model's one way to finish a goal. */
export function createGoalTools(goals: GoalStore, executions: Executions): Extension {
  return defineExtension({ name: "goal-tools", tools: [defineTool({ name: "complete_goal",
    description: "Finish this task's /goal. The runtime reads the file on this task's host itself. Only if it contains the exact text does the goal complete and the task resolve. The first check you run pins this activation, so choose the check that proves the objective. A failed check is recorded and the goal continues. record_task cannot resolve a task whose goal is unfinished.",
    parameters: Type.Object({ check: goalCheck, summary: Type.String({ minLength: 1, maxLength: 4000 }) }),
    async execute(args, api) {
      const conversation_id = api.conversationId.toString();
      const reply = await goals.complete({ conversation_id, call_id: api.callId, native_task_id: api.taskId }, args, executions.get(conversation_id));
      // A verified goal ends the turn. Pi honors this only when every call of the round asks for it.
      return reply.passed ? { ...output(reply), control: { terminate: true } } : output(reply);
    } })] });
}

function requestId(value: string): string {
  if (value.trim().length === 0) throw new TaskError("A goal control needs a request ID");
  return value;
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function taskRequestId(value: string): string {
  if (!UUID.test(value) || /^[0-]+$/.test(value)) throw new TaskError("A main goal request ID must be a non-nil UUID");
  return value;
}
/** A request ID names one control on one target. Its replay returns the receipt, and any other use is refused. */
function replayOf(saved: Readonly<GoalRequest> | null | undefined, selected: Selected, control: GoalControl): GoalRequest | undefined {
  if (saved === null || saved === undefined) return undefined;
  const sameTarget = selected.kind === "main" ? saved.main : !saved.main && saved.task_id === selected.task.id;
  if (saved.action !== control.action || saved.objective !== control.objective || !sameTarget) throw new TaskError(REUSED);
  return { action: saved.action, objective: saved.objective, main: saved.main, task_id: saved.task_id, goal_id: saved.goal_id };
}

function inputPrefix(goal: Goal): string { return `goal:${goal.id}:`; }
function activationPrefix(goal: Goal): string { return `${inputPrefix(goal)}${goal.activation.number}:`; }
function inputId(goal: Goal, sequence: number): string { return `${activationPrefix(goal)}${sequence}`; }
/** A resume can land before the actor sees its stopped input, so that input belongs to an earlier activation. */
function fromEarlierActivation(goal: Goal, id: string): boolean { return id.startsWith(inputPrefix(goal)) && !id.startsWith(activationPrefix(goal)); }
function pauseIn(goal: Goal, reason: GoalPause): undefined {
  goal.state = { state: "paused", reason }; goal.updated_at = Date.now(); return undefined;
}

function objectiveText(goal: Goal): string {
  return `Goal set with /goal: ${goal.objective}\n` +
    "Work in this task until the outcome is verified. When the artifact should be ready, call complete_goal with a check the runtime runs itself. The check names a file on this task's host and the exact text it must contain. " +
    `The first check pins this activation. A failed check is recorded and the goal continues automatically, up to ${goal.activation.budget} continuations. ` +
    "record_task cannot resolve this task while the goal is unfinished.";
}
function resumeText(goal: Goal): string {
  return [`Goal resumed (activation ${goal.activation.number}): ${goal.objective}`, rejectionLine(goal),
    "No check is pinned in this activation yet. Continue toward the outcome, then call complete_goal with a check the runtime runs itself."]
    .filter((line) => line.length > 0).join("\n");
}
function continuationText(goal: Goal, task: TaskRecord): string {
  const activation = goal.activation;
  const summary = task.summary.trim().slice(-1000);
  return [`Goal continuation ${activation.continuations} of ${activation.budget} (activation ${activation.number}): ${goal.objective}`,
    activation.check === null ? "No check is pinned yet." : `Pinned check: ${describe(activation.check)}.`, rejectionLine(goal),
    `Task state: ${task.state.state}.` + (summary.length === 0 ? "" : ` Latest summary: ${summary}`),
    "Continue toward the outcome, then call complete_goal."].filter((line) => line.length > 0).join("\n");
}
function rejectionLine(goal: Goal): string {
  const rejection = goal.last_rejection;
  if (rejection === null) return "";
  switch (rejection.type) {
    case "failed_check": return `Last rejection: ${describe(rejection.check)} failed in activation ${rejection.activation} (${failureText(rejection.failure)}).`;
    case "premature_resolution": return "Last rejection: record_task tried to resolve the task before complete_goal verified it.";
    default: { const unhandled: never = rejection; throw new TaskError(`Unknown goal rejection ${JSON.stringify(unhandled)}`); }
  }
}
function failureText(failure: GoalCheckFailure): string {
  switch (failure.type) {
    case "text_missing": return `text not found in ${failure.observed.bytes} bytes`;
    case "unreadable": return failure.message;
    default: { const unhandled: never = failure; throw new TaskError(`Unknown check failure ${JSON.stringify(unhandled)}`); }
  }
}
function title(objective: string): string {
  const line = objective.split("\n").find((part) => part.trim().length > 0)?.replace(/\s+/g, " ").trim() ?? objective.trim();
  return line.length <= TITLE_LIMIT ? line : line.slice(0, TITLE_LIMIT - 1).trimEnd() + "…";
}
function describe(check: GoalCheck): string { return `${check.path} contains ${JSON.stringify(check.text)}`; }
function sameCheck(left: GoalCheck, right: GoalCheck): boolean {
  return left.type === right.type && left.path === right.path && left.text === right.text;
}
function pinnable(check: GoalCheck, execution: Execution): GoalCheck {
  return { ...check, path: resolveHostPath(execution, check.path) };
}

async function runCheck(check: GoalCheck, call: HostCall): Promise<GoalCheckResult> {
  switch (check.type) {
    case "file_contains": {
      const result = await call({ type: "read_file", path: check.path, offset: 0, limit: MAX_FILE_READ_BYTES });
      if (result.type !== "file") {
        return { type: "failed", failure: { type: "unreadable", message: result.type === "failed" ? result.message : "The host returned no file text" } };
      }
      const observed: ObservedFile = { bytes: Buffer.byteLength(result.content), complete: !result.truncated,
        sha256: createHash("sha256").update(result.content).digest("hex") };
      return result.content.includes(check.text) ? { type: "passed", observed } : { type: "failed", failure: { type: "text_missing", observed } };
    }
    default: { const unhandled: never = check.type; throw new TaskError(`Unknown goal check ${JSON.stringify(unhandled)}`); }
  }
}
