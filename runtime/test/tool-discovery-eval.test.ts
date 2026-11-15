import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFile, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { AssistantMessage, Message, MutableModels } from "@earendil-works/pi-ai";
import { builtinModels } from "@earendil-works/pi-ai/providers/all";
import { MODEL_THINKING_LEVELS } from "@earendil-works/pi-ai/providers/model-schema";
import type { AgentNode } from "../src/generated/AgentNode.js";
import type { BrowserAction } from "../src/generated/BrowserAction.js";
import type { BrowserResponse } from "../src/generated/BrowserResponse.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { ModelSelection } from "../src/generated/ModelSelection.js";
import type { ScheduledJob } from "../src/generated/ScheduledJob.js";
import type { SourceEvent } from "../src/generated/SourceEvent.js";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import { MAIN_RESPONSE_INSTRUCTIONS } from "../src/main_response.js";
import { DEFAULT_MODEL } from "../src/models.js";
import type { ToolRole } from "../src/toolsets.js";
import { declarationSize, DISCOVERY_ARMS, isDiscoveryArmName, openDiscoveryApp, type DiscoveryApp, type DiscoveryArmName } from "./fixtures/tool-discovery.js";
import { statesExpiredCertificateCause } from "./fixtures/tool-discovery-oracle.js";

type ProviderRequest = {
  context: string; tool_errors: number; stop: string; input: number; cache_read: number; cache_write: number; output: number; reasoning: number; total: number;
  cost_usd: number; duration_ms: number; declared_tokens: number; offered_tools: number; calls: string[];
};
type Verdict = { success: boolean; detail: string };
type World = { app: DiscoveryApp; host: EvalHost; workspace: string; model: ModelSelection; signal: AbortSignal };
type Scenario = { name: string; role: ToolRole; run(world: World): Promise<Verdict> };

type Provider = { apiKey: string; baseUrl: string | undefined };

function meteredModels({ apiKey, baseUrl }: Provider, requests: Promise<ProviderRequest>[]): MutableModels {
  const models = builtinModels(), openai = models.getProvider("openai");
  assert.ok(openai !== undefined, "The OpenAI provider is unavailable");
  models.setProvider({ ...openai,
    auth: { ...openai.auth, apiKey: { name: "Evaluation provider",
      resolve: async () => ({ auth: { apiKey, ...(baseUrl ? { baseUrl } : {}) }, source: "evaluation environment" }) } },
    streamSimple: (model, context, options) => {
      const declared = declarationSize(context), started = performance.now(), sent = JSON.stringify(context.messages, (key, value: unknown) => key === "timestamp" ? undefined : value);
      const round = context.messages.slice(context.messages.findLastIndex((message) => message.role === "assistant") + 1);
      const toolErrors = round.filter((message) => message.role === "toolResult" && message.isError).length;
      const stream = openai.streamSimple(model, context, options);
      requests.push(stream.result().then((message: AssistantMessage) => ({ context: sent, tool_errors: message.stopReason === "error" ? 0 : toolErrors, stop: message.stopReason,
        input: message.usage.input, cache_read: message.usage.cacheRead, cache_write: message.usage.cacheWrite,
        output: message.usage.output, reasoning: message.usage.reasoning ?? 0, total: message.usage.totalTokens,
        cost_usd: message.usage.cost.total, duration_ms: Math.round(performance.now() - started),
        declared_tokens: declared.estimatedTokens, offered_tools: declared.tools.length,
        calls: message.content.flatMap((part) => part.type === "toolCall" ? [part.name] : []) }),
      () => ({ context: sent, tool_errors: 0, stop: "error", input: 0, cache_read: 0, cache_write: 0, output: 0, reasoning: 0, total: 0, cost_usd: 0,
        duration_ms: Math.round(performance.now() - started), declared_tokens: declared.estimatedTokens, offered_tools: declared.tools.length, calls: [] })));
      return stream;
    } });
  return models;
}

const HOST_ID = "7a1c2e64-3b9d-4f0e-9d25-5c8e1f4a6b20";
const STATUS_URL = "https://status.pebble.example/";
const STATUS_PAGE = [`- heading "Pebble service status" [level=1] [ref=e1]`, `- text "Last updated 10:40 UTC" [ref=e2]`,
  `- table "Components" [ref=e3]:`, `  - row "API | Operational" [ref=e4]`, `  - row "Web dashboard | Operational" [ref=e5]`,
  `  - row "Sync workers | Degraded since 09:12 UTC: delayed project syncs" [ref=e6]`, `  - row "Billing | Operational" [ref=e7]`,
  `- link "Subscribe to updates" [ref=e8]`].join("\n");
const READ_ONLY_PROGRAMS = new Set(["ls", "cat", "head", "tail", "wc", "grep", "pwd"]);

class EvalHost {
  readonly commands: HostCommand["type"][] = [];
  private open = false;
  constructor(readonly workspace: string) {}
  get node(): AgentNode {
    return { host_id: HOST_ID, name: "eval-host", rex_server: null, agent_program: process.execPath, home_directory: this.workspace,
      coordinator: null, launch: { state_dir: null, runtime: null, config: null, instructions: null, model: null } };
  }
  private path(path: string): string {
    const target = resolve(this.workspace, path), within = relative(this.workspace, target);
    if (within.startsWith("..") || isAbsolute(within)) throw new Error("Only the project workspace is available in this evaluation");
    return target;
  }
  private browser(session_id: string, action: BrowserAction): BrowserResponse {
    const tab = { id: 1, url: STATUS_URL, title: "Pebble service status" };
    const ready = (output: string): BrowserResponse => ({ type: "ready", session_id, tabs: this.open ? [tab] : [], output, is_error: false });
    switch (action.type) {
      case "list_user_tabs": return { type: "user_tabs", session_id, tabs: [] };
      case "claim_user_tab": return { type: "failed", session_id, message: "That user tab is not open" };
      case "open": case "new_tab": case "navigate":
        if (!action.url.startsWith(STATUS_URL)) return { type: "ready", session_id, tabs: [], output: `${action.url} could not be reached`, is_error: true };
        this.open = true; return ready(STATUS_PAGE);
      case "snapshot": case "wait_for": case "click": case "fill": case "press_key": case "handle_dialog":
        return this.open ? ready(STATUS_PAGE) : { type: "ready", session_id, tabs: [], output: "No owned tab is open", is_error: true };
      case "run_code": return this.open ? ready(JSON.stringify(STATUS_PAGE.replaceAll(/ \[ref=e\d+\]/gu, ""))) : ready("No owned tab is open");
      case "status": return ready(this.open ? "Connected with one owned tab" : "Connected without owned tabs");
      case "close_tab": case "retain_tab": this.open = false; return ready("");
      case "release": this.open = false; return { type: "closed", session_id, tabs: [], output: "" };
      default: { const never: never = action; throw new Error(`Unknown browser action ${JSON.stringify(never)}`); }
    }
  }
  readonly call = async (command: HostCommand): Promise<HostResult> => {
    this.commands.push(command.type);
    try {
      switch (command.type) {
        case "on_node": return await this.call(command.command);
        case "reload_guidance": return { type: "shared_guidance", global: { text: "Prefer existing tasks over new ones. Verify file changes before recording them. " +
          "This machine is an isolated evaluation host: external services, accounts and messages are unavailable.", sources: [] },
          workflow_policy: "", context_repositories: [], context_sources: [] };
        case "project_guidance": return { type: "project_guidance", snapshot: { text: "", sources: [] } };
        case "read_file": {
          const bytes = await readFile(this.path(command.path));
          return { type: "file", content: bytes.subarray(command.offset, command.offset + command.limit).toString("utf8"),
            truncated: command.offset + command.limit < bytes.length };
        }
        case "write_file": {
          const target = this.path(command.path);
          await mkdir(dirname(target), { recursive: true }); await writeFile(target, command.content); return { type: "written" };
        }
        case "edit_file": {
          const target = this.path(command.path), text = await readFile(target, "utf8"), found = text.split(command.old).length - 1;
          if (found !== 1) return { type: "failed", message: `Expected exactly one occurrence, found ${found}` };
          await writeFile(target, text.replace(command.old, () => command.new)); return { type: "written" };
        }
        case "exec": {
          if (!READ_ONLY_PROGRAMS.has(command.program) || command.args.some((arg) => isAbsolute(arg) || arg.includes(".."))) {
            return { type: "failed", message: `Only read-only workspace programs (${[...READ_ONLY_PROGRAMS].join(", ")}) run in this evaluation` };
          }
          const result = await promisify(execFile)(command.program, command.args, { cwd: this.path(command.cwd), timeout: 10_000 })
            .then(({ stdout, stderr }) => ({ code: 0, stdout, stderr }), (error: { code?: unknown; stdout?: string; stderr?: string }) =>
              ({ code: typeof error.code === "number" ? error.code : 1, stdout: error.stdout ?? "", stderr: error.stderr ?? "" }));
          return { type: "process", exit_code: result.code, stdout: result.stdout, stderr: result.stderr, truncated: false };
        }
        case "browser": return { type: "browser", response: this.browser(command.request.session_id, command.request.action) };
        case "spawn_worker": return { type: "spawned", binding: { host_id: HOST_ID, session_id: `session:${randomUUID()}`,
          window_id: `window:${randomUUID()}`, block_id: `block:${randomUUID()}` } };
        default: return { type: "failed", message: `${command.type} is unavailable on this isolated evaluation host` };
      }
    } catch (error) {
      return { type: "failed", message: error instanceof Error ? error.message : "The evaluation host could not complete the operation" };
    }
  };
}

function text(message: Message | undefined): string {
  if (message?.role !== "assistant") return "";
  return message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
}

async function askMain({ app, workspace, model }: World, content: string): Promise<string> {
  const root = await app.session.root(BACKGROUND_CONTEXT), release = app.bind(root);
  try {
    await app.inference.configure(root, model, { instructions: await app.environment.instructions("") + "\n\n" + MAIN_RESPONSE_INSTRUCTIONS,
      cwd: workspace, extensions: app.toolsets.main });
    const outcome = await (await root.submit({ type: "input", content }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    assert.equal(outcome.status, "done", `The main turn ended as ${outcome.status}`);
    return text((await root.context(BACKGROUND_CONTEXT)).messages.findLast((message) => message.role === "assistant"));
  } finally { release(); }
}

async function runJobTask({ app, model, signal }: World, title: string, outcome: string, input: string): Promise<TaskRecord> {
  const task = await app.tasks.create({ title, outcome, model, sources: [{ provider: "scheduled_jobs", account: "local", thread_id: "eval-maintenance" }] });
  await app.tasks.enqueue(task.id, input);
  await app.tasks.runBackground(task.id, signal);
  for (let saved = await app.tasks.get(task.id); ; saved = await app.tasks.get(task.id)) {
    if (saved.agents.every((agent) => agent.state.state !== "open") || signal.aborted) return saved;
    await new Promise((settle) => setTimeout(settle, 500));
  }
}

async function seedInvoiceTask(app: DiscoveryApp, model: ModelSelection): Promise<TaskRecord> {
  const seeds: [string, string, string, TaskRecord["state"]][] = [
    ["Renew staging TLS certificates", "Replace the staging certificates before they expire.", "Requested new certificates from the internal CA.", { state: "open" }],
    ["Plan Q1 team offsite", "Book a venue and agenda for the March offsite.", "Two venues shortlisted; waiting for availability.", { state: "waiting", actor: "Venue coordinator", next_check: null }],
    ["Migrate build cache to the new bucket", "Move CI build caches to the new storage bucket.", "Caches moved and old bucket removed.", { state: "resolved", evidence: "CI runs read from the new bucket." }],
    ["Review Kestrel Design contractor agreement", "Check the renewal terms before signing.", "Sent redlines on clause 7.", { state: "waiting", actor: "Kestrel Design", next_check: null }],
    ["Reconcile October supplier invoices", "Match October invoices from Lumen Parts against purchase orders and clear the credit balance.",
      "Sent the corrected invoice batch on Tuesday. Waiting for Lumen Parts to issue credit note CN-4471 for the duplicated freight charge on INV-20931.",
      { state: "waiting", actor: "Lumen Parts accounts desk", next_check: null }],
  ];
  let invoice: TaskRecord | undefined;
  for (const [title, outcome, summary, state] of seeds) {
    const task = await app.tasks.create({ title, outcome, model, sources: [{ provider: "mail", account: "work", thread_id: title.toLowerCase().replaceAll(" ", "-") }] });
    invoice = await app.tasks.update(task.id, (saved) => { saved.summary = summary; saved.state = state; });
  }
  assert.ok(invoice !== undefined);
  return invoice;
}

function historyTurns(): Message[] {
  const topics = ["the offsite agenda", "catering for thirty people", "the shuttle from the station", "the workshop rooms", "the budget split",
    "dietary notes", "the evening event", "badge printing", "the speaker list", "travel reimbursements", "the backup venue", "the photo policy",
    "the accessibility checklist", "the welcome packs", "the room assignments", "the late checkout", "the team dinner", "the feedback survey",
    "the parking passes", "the quiet room", "the morning run", "the projector rental", "the printed schedules", "the thank-you notes"];
  const option = (topic: string, index: number) => `Option ${index} for ${topic} keeps the cost within the agreed envelope, needs one confirmation ` +
    `from the venue team by Thursday, and leaves room to adjust numbers after the final headcount. `;
  const messages: Message[] = [];
  for (const [index, topic] of topics.entries()) {
    const fact = index === 1 ? " We settled the venue deposit at Harbor Hall; its deposit reference is DEP-58213." : "";
    messages.push({ role: "user", timestamp: Date.now(), content: `Next, ${topic}. Summarize the options we have and what you would pick.${fact}` });
    messages.push({ role: "assistant", timestamp: Date.now(), api: "openai-responses", provider: "eval-history", model: "eval-history",
      stopReason: "stop", usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
      content: [{ type: "text", text: [1, 2, 3, 4, 5, 6].map((number) => option(topic, number)).join("") +
        `I would pick option 1 for ${topic}, confirm it this week, and keep option 2 as a fallback.${fact ? " Noted: deposit reference DEP-58213 at Harbor Hall." : ""}` }] });
  }
  return messages;
}

const scenarios: Scenario[] = [
  { name: "direct-answer", role: "main", async run(world) {
    const answer = await askMain(world, "How many minutes are in 3.5 hours? Reply with only the number.");
    return { success: /\b210\b/u.test(answer), detail: answer.slice(0, 200) };
  } },
  { name: "task-status", role: "main", async run(world) {
    await seedInvoiceTask(world.app, world.model);
    const answer = await askMain(world, "Where are we on the supplier invoice reconciliation? What exactly are we waiting for?");
    return { success: /CN-4471/u.test(answer), detail: answer.slice(0, 300) };
  } },
  { name: "delegation", role: "main", async run(world) {
    await writeFile(join(world.workspace, "CHANGELOG.md"), "# Pebble changelog\n\n## 2.4.0\n- Add `pebble sync --dry-run`.\n- Fix duplicate project names on import.\n\n## 2.3.1\n- Fix a crash when the config directory is missing.\n");
    const answer = await askMain(world, "Have a worker draft release notes for Pebble 2.4 from CHANGELOG.md in this project. Start it as a new task on the eval host; do not draft them yourself.");
    const task = (await world.app.tasks.list()).find((candidate) => /release notes/iu.test(candidate.title + " " + candidate.outcome));
    return { success: task !== undefined && world.host.commands.includes("spawn_worker"), detail: `task=${task?.title ?? "none"}; answer=${answer.slice(0, 160)}` };
  } },
  { name: "file-edit", role: "worker", async run(world) {
    const config = join(world.workspace, "config", "limits.toml");
    await mkdir(dirname(config), { recursive: true });
    await writeFile(config, "[http]\ntimeout_seconds = 30\nmax_retries = 3\n\n[queue]\nmax_retries = 8\nvisibility_seconds = 120\n");
    const task = await runJobTask(world, "Raise HTTP retries", "Raise the HTTP client's max_retries in config/limits.toml from 3 to 5 without changing any other setting, " +
      "then record this task as resolved with the change as evidence.", "Make this change now.");
    const saved = await readFile(config, "utf8");
    const edited = saved === "[http]\ntimeout_seconds = 30\nmax_retries = 5\n\n[queue]\nmax_retries = 8\nvisibility_seconds = 120\n";
    return { success: edited && task.state.state === "resolved", detail: `state=${task.state.state}; edited=${edited}` };
  } },
  { name: "child-agent", role: "agent", async run(world) {
    const report = join(world.workspace, "docs", "incident-0412.md");
    await mkdir(dirname(report), { recursive: true });
    await writeFile(report, "# Incident 0412: staging deploys failed\n\nImpact: staging deploys failed for 47 minutes.\n\n" +
      "Timeline: 09:02 first failure; 09:20 rollback attempted; 09:49 fixed.\n\nRoot cause: an expired TLS certificate on the staging relay rejected every deploy upload.\n\n" +
      "Follow-up: add certificate expiry alerts.\n");
    const task = await runJobTask(world, "Summarize incident 0412", "Spawn one agent to read docs/incident-0412.md and report the root cause it states. " +
      "Wait for the agent's result, then record this task as resolved with that root cause as evidence. Do not read the file yourself.", "Start now.");
    const agent = task.agents.find((candidate) => candidate.state.state === "done" && statesExpiredCertificateCause(candidate.summary));
    const evidence = task.state.state === "resolved" ? task.state.evidence : "";
    return { success: agent !== undefined && statesExpiredCertificateCause(evidence), detail: `agents=${task.agents.map((candidate) => candidate.state.state).join(",")}; state=${task.state.state}` };
  } },
  { name: "browser-read", role: "main", async run(world) {
    const answer = await askMain(world, `Open ${STATUS_URL} in the browser and tell me which component is degraded and since when.`);
    return { success: /sync workers/iu.test(answer) && /09:12/u.test(answer), detail: answer.slice(0, 200) };
  } },
  { name: "job-inspection", role: "main", async run(world) {
    const job = (id: string, title: string, prompt: string, recurrence: string): ScheduledJob => ({ id, title, prompt, model: world.model, cwd: world.workspace,
      timezone: "Etc/UTC", revision: "eval-v1", schedules: [{ id: "default", recurrence, focus: null, prompt: null }] });
    await world.app.scheduler.syncJobs([
      job("inbox-review", "Inbox review", "Review new mail, keep vendor pitches quiet and surface direct requests.", "DTSTART:20300101T090000Z\nRRULE:FREQ=DAILY"),
      job("invoice-sweep", "Invoice sweep", "Check the shared invoices folder for new Lumen Parts invoices, match each one to its purchase order, " +
        "and record mismatches on the invoice reconciliation task.", "DTSTART:20300107T080000Z\nRRULE:FREQ=WEEKLY;BYDAY=MO"),
    ]);
    const answer = await askMain(world, "What does the invoice sweep job check, and how often does it run?");
    return { success: /Lumen/u.test(answer) && /purchase order|\bPO\b/iu.test(answer) && /week|monday/iu.test(answer), detail: answer.slice(0, 300) };
  } },
  { name: "source-triage", role: "triage", async run(world) {
    const invoice = await seedInvoiceTask(world.app, world.model);
    const event = (id: string, title: string, body: string): SourceEvent => ({ id, version: "v1", source: { provider: "mail", account: "work", thread_id: id + "-thread" }, title, text: body });
    const credit = event("mail-301", "Credit note CN-4471 issued", "From: accounts@lumenparts.example\nTo: finance@pebble.example\n" +
      "Body: We have issued credit note CN-4471 for the duplicated freight charge on invoice INV-20931. The credit is applied to your next statement.");
    const newsletter = event("mail-302", "Pebble Weekly: five tips for faster builds", "From: newsletter@devtools.example\nTo: finance@pebble.example\n" +
      "Body: This week's tips on caching and parallel builds. You receive this because you subscribed to the newsletter.");
    await world.app.sources.admit({ source: { provider: "mail", account: "work" }, events: [credit, newsletter], checkpoint: { value: "eval-page" }, coverage: { status: "complete" } }, null);
    await world.app.sources.triage({ type: "triage_sources", instructions: "", model: world.model, cwd: world.workspace, hosts: [world.app.worker] },
      (conversation) => world.app.bind(conversation, "triage"), world.app.toolsets.triage, world.signal);
    const decisions = await world.app.sources.events({ provider: "mail", account: "work", limit: 10 });
    const decision = (id: string) => decisions.find((record) => record.event.id === id)?.decision;
    const linked = decision(credit.id), dismissed = decision(newsletter.id);
    return { success: linked?.type === "task" && linked.task_id === invoice.id && dismissed?.type === "dismissed",
      detail: JSON.stringify({ credit: linked ?? null, newsletter: dismissed ?? null }) };
  } },
  { name: "long-history", role: "main", async run(world) {
    const root = await world.app.session.root(BACKGROUND_CONTEXT);
    await root.submit({ type: "write", entry: { kind: "eval.history", model: historyTurns() } }, BACKGROUND_CONTEXT);
    const answer = await askMain(world, "Remind me: what was the venue deposit reference we settled on earlier?");
    return { success: /DEP-58213/u.test(answer), detail: answer.slice(0, 200) };
  } },
];

type UnitResult = {
  run_id: string; arm: DiscoveryArmName; trial: number; scenario: string; role: ToolRole; model: string; reasoning: string | null;
  success: boolean; detail: string; error: string | null; kept: string | null; requests: number; provider_errors: number; retries: number; tool_errors: number;
  input: number; cache_read: number; cache_write: number; output: number; reasoning_tokens: number; total_tokens: number; cost_usd: number;
  wall_ms: number; first_declared_tokens: number | null; first_offered_tools: number | null; tool_calls: string[];
};

async function runUnit(config: EvalConfig, arm: DiscoveryArmName, trial: number, scenario: Scenario): Promise<UnitResult> {
  const { runId, model, timeoutMs, keepFailures } = config;
  const directory = await mkdtemp(join(tmpdir(), "agent-tool-discovery-eval-")), workspace = join(directory, "workspace");
  await mkdir(workspace);
  const pending: Promise<ProviderRequest>[] = [], host = new EvalHost(workspace), controller = new AbortController();
  const started = performance.now();
  let verdict: Verdict = { success: false, detail: "" }, error: string | null = null;
  let app: DiscoveryApp | undefined;
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    app = await openDiscoveryApp(join(directory, "state"), { models: meteredModels(config.provider, pending), model, arm: DISCOVERY_ARMS[arm], host, retry: true });
    const world: World = { app, host, workspace, model, signal: controller.signal };
    const aborted = new Promise<never>((_, reject) => controller.signal.addEventListener("abort", () => reject(new Error(`Timed out after ${timeoutMs} ms`)), { once: true }));
    verdict = await Promise.race([scenario.run(world), aborted]);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  } finally { clearTimeout(timer); controller.abort(); }
  const wall = Math.round(performance.now() - started);
  await app?.close().catch((caught: unknown) => { error ??= `Close failed: ${caught instanceof Error ? caught.message : String(caught)}`; });
  const kept = keepFailures && !(error === null && verdict.success);
  if (!kept) await rm(directory, { recursive: true, force: true });
  const requests = await Promise.all(pending);
  const sum = (field: keyof Omit<ProviderRequest, "context" | "stop" | "calls">) => requests.reduce((total, request) => total + request[field], 0);
  const retries = requests.filter((request, index) => request.stop === "error" &&
    requests.slice(index + 1).some((later) => later.context === request.context)).length;
  return { run_id: runId, arm, trial, scenario: scenario.name, role: scenario.role, model: model.model_id, reasoning: model.reasoning,
    success: error === null && verdict.success, detail: verdict.detail || error || "", error, kept: kept ? directory : null, requests: requests.length,
    provider_errors: requests.filter((request) => request.stop === "error").length, retries, tool_errors: sum("tool_errors"),
    input: sum("input"), cache_read: sum("cache_read"), cache_write: sum("cache_write"), output: sum("output"), reasoning_tokens: sum("reasoning"),
    total_tokens: sum("total"), cost_usd: Number(sum("cost_usd").toFixed(6)), wall_ms: wall,
    first_declared_tokens: requests[0]?.declared_tokens ?? null, first_offered_tools: requests[0]?.offered_tools ?? null,
    tool_calls: requests.flatMap((request) => request.calls) };
}

function median(values: number[]): number {
  const sorted = [...values].sort((left, right) => left - right), middle = Math.floor(sorted.length / 2);
  return sorted.length === 0 ? 0 : sorted.length % 2 === 1 ? sorted[middle]! : (sorted[middle - 1]! + sorted[middle]!) / 2;
}

function readEvalConfig(env: NodeJS.ProcessEnv) {
  const list = (name: string, fallback: readonly string[]) =>
    env[name]?.split(",").map((value) => value.trim()).filter((value) => value !== "") ?? [...fallback];
  const count = (name: string, fallback: number) => {
    const value = Number(env[name] ?? fallback);
    assert.ok(Number.isSafeInteger(value) && value > 0, `${name} must be a positive integer`);
    return value;
  };
  const apiKey = env.OPENAI_API_KEY;
  assert.ok(apiKey, "Set OPENAI_API_KEY for the evaluation provider");
  const arms = list("AGENT_TOOL_DISCOVERY_ARMS", ["direct"]).map((arm) => {
    assert.ok(isDiscoveryArmName(arm), `Unknown arm ${arm}; choose from ${Object.keys(DISCOVERY_ARMS).join(", ")}`);
    return arm;
  });
  const names = list("AGENT_TOOL_DISCOVERY_SCENARIOS", scenarios.map((scenario) => scenario.name));
  const chosen = scenarios.filter((scenario) => names.includes(scenario.name));
  assert.equal(chosen.length, names.length, `Unknown scenario in ${names.join(", ")}`);
  const requested = env.AGENT_TOOL_DISCOVERY_REASONING;
  const reasoning = requested === undefined ? DEFAULT_MODEL.reasoning : MODEL_THINKING_LEVELS.find((level) => level === requested);
  assert.ok(reasoning !== undefined, `Unknown reasoning ${requested}`);
  const runId = new Date().toISOString().replaceAll(":", "-");
  return { runId, arms, scenarios: chosen, model: { ...DEFAULT_MODEL, reasoning } satisfies ModelSelection,
    trials: count("AGENT_TOOL_DISCOVERY_TRIALS", 3), concurrency: count("AGENT_TOOL_DISCOVERY_CONCURRENCY", 4),
    timeoutMs: count("AGENT_TOOL_DISCOVERY_TIMEOUT_SECONDS", 600) * 1000, keepFailures: env.AGENT_TOOL_DISCOVERY_KEEP_FAILURES === "1",
    out: env.AGENT_TOOL_DISCOVERY_OUT ?? join(tmpdir(), `agent-tool-discovery-${runId}.jsonl`),
    provider: { apiKey, baseUrl: env.OPENAI_BASE_URL } satisfies Provider };
}
type EvalConfig = ReturnType<typeof readEvalConfig>;

test("live tool discovery eval measures tokens, requests and success per arm", {
  skip: process.env.AGENT_TOOL_DISCOVERY_EVAL !== "1", timeout: 6 * 60 * 60_000,
}, async (t) => {
  const config = readEvalConfig(process.env), { arms, trials, model, out } = config, chosen = config.scenarios;
  const units = Array.from({ length: trials }, (_, index) => index + 1).flatMap((trial) =>
    (trial % 2 === 1 ? arms : [...arms].reverse()).flatMap((arm) => chosen.map((scenario) => ({ arm, trial, scenario }))));
  t.diagnostic(`run ${config.runId}: ${units.length} units (${arms.join(", ")} x ${chosen.length} scenarios x ${trials} trials) at ${model.model_id}/${model.reasoning}; writing ${out}`);
  const results: UnitResult[] = [];
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(config.concurrency, units.length) }, async () => {
    for (let index = next++; index < units.length; index = next++) {
      const unit = units[index]!;
      const result = await runUnit(config, unit.arm, unit.trial, unit.scenario);
      results.push(result); await appendFile(out, JSON.stringify(result) + "\n");
      t.diagnostic(`${result.arm} t${result.trial} ${result.scenario}: ${result.success ? "ok" : "FAIL"} requests=${result.requests} total=${result.total_tokens} ` +
        `cached=${result.cache_read} wall=${result.wall_ms}ms${result.error ? " error=" + result.error : ""}`);
    }
  }));
  for (const arm of arms) {
    const mine = results.filter((result) => result.arm === arm);
    const perTrial = Array.from({ length: trials }, (_, index) => mine.filter((result) => result.trial === index + 1));
    const suite = (field: "total_tokens" | "requests" | "cache_read" | "input" | "output" | "cost_usd" | "wall_ms") => perTrial.map((rows) => rows.reduce((sum, row) => sum + row[field], 0));
    t.diagnostic(`${arm}: success ${perTrial.map((rows) => rows.filter((row) => row.success).length).join("/")} of ${chosen.length}; ` +
      `median suite total ${median(suite("total_tokens"))} tokens (trials ${suite("total_tokens").join(", ")}); median requests ${median(suite("requests"))}; ` +
      `median cached share ${(median(suite("cache_read")) / Math.max(1, median(suite("total_tokens")))).toFixed(3)}; median cost $${median(suite("cost_usd")).toFixed(4)}; ` +
      `errors ${mine.filter((row) => row.error !== null || row.provider_errors > row.retries).length}; ` +
      `recovered retries ${mine.reduce((sum, row) => sum + row.retries, 0)}; tool errors ${mine.reduce((sum, row) => sum + row.tool_errors, 0)}; ` +
      `work ${mine.reduce((sum, row) => sum + row.requests, 0)} requests, ` +
      `${mine.reduce((sum, row) => sum + row.tool_calls.length, 0)} tool calls`);
    for (const scenario of chosen) {
      const rows = mine.filter((row) => row.scenario === scenario.name);
      t.diagnostic(`  ${scenario.name} (${scenario.role}): success ${rows.filter((row) => row.success).length}/${rows.length}; ` +
        `median total ${median(rows.map((row) => row.total_tokens))}; median requests ${median(rows.map((row) => row.requests))}; ` +
        `first request declares ${median(rows.flatMap((row) => row.first_declared_tokens ?? []))} est. tokens`);
    }
  }
  assert.equal(results.length, units.length, "Every unit must report");
  for (const unit of units) {
    const result = results.find((row) => row.arm === unit.arm && row.trial === unit.trial && row.scenario === unit.scenario.name);
    await t.test(`${unit.arm} t${unit.trial} ${unit.scenario.name}`, () => {
      assert.ok(result !== undefined && result.requests > 0, "The unit reached the provider");
      assert.ok(result.success, result.detail);
    });
  }
});
