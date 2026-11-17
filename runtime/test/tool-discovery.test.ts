import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { awaitWithContext, BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall, type AssistantMessage, type Context, type FauxResponseFactory, type Message } from "@earendil-works/pi-ai";
import { getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import { defineExtension, defineTool, type CompactionSettings } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import type { AgentNode } from "../src/generated/AgentNode.js";
import { ATTACHMENT_CHUNK_BYTES } from "../src/generated/attachment-limits.js";
import type { BrowserResponse } from "../src/generated/BrowserResponse.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { TaskRecord } from "../src/generated/TaskRecord.js";
import { ALWAYS_DIRECT, applyToolSurfaces, BROWSER_TOOLS, createToolDiscovery, TOOL_ROLES, type ToolRole, type ToolSurface } from "../src/toolsets.js";
import { history, toolDetails, UserNoticeEntry } from "../src/transcript.js";
import { HistoryStore } from "../src/history.js";
import { declarationSize, DISCOVERY_ARMS, openDiscoveryApp, type DeclarationSize, type DiscoveryApp, type DiscoveryArm,
  type DiscoveryArmName } from "./fixtures/tool-discovery.js";
import { capturePng, pngSize } from "./fixtures/png.js";
import { fixtureModel } from "./model.js";
import { runAdmitted } from "./fixtures/run-admitted.js";

const node: AgentNode = { host_id: "11111111-1111-4111-8111-111111111111", name: "example", rex_server: null, agent_program: "/example/agent",
  home_directory: "/workspace/example", coordinator: null, launch: { state_dir: null, runtime: null, config: null, instructions: null, model: fixtureModel } };
type ToolArguments = Parameters<typeof fauxToolCall>[1];

async function lab(prefix: string, answer?: (command: HostCommand) => HostResult | undefined) {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  const models = createModels(), faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const commands: HostCommand[] = [];
  async function call(request: HostCommand): Promise<HostResult> {
    let command = request;
    while (command.type === "on_node") command = command.command;
    commands.push(command);
    const answered = answer?.(command);
    if (answered !== undefined) return answered;
    if (command.type === "reload_guidance") return { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] };
    if (command.type === "project_guidance") return { type: "project_guidance", snapshot: { text: "", sources: [] } };
    if (command.type === "exec") return { type: "process", exit_code: 0, stdout: "EXAMPLE_EXEC_OUTPUT", stderr: "", truncated: false };
    if (command.type === "edit_file") return { type: "written" };
    return { type: "failed", message: `The example host does not support ${command.type}` };
  }
  const open = (arm: DiscoveryArm, compaction?: CompactionSettings) =>
    openDiscoveryApp(directory, { models, model: fixtureModel, arm, host: { node, call }, ...(compaction === undefined ? {} : { compaction }) });
  return { faux, commands, open, remove: () => rm(directory, { recursive: true, force: true }) };
}

function offeredNames(input: Context): string[] { return getCurrentTools(input.messages).map((tool) => tool.name); }
function toolResult(input: Context, name: string) {
  const result = input.messages.findLast((message) => message.role === "toolResult" && message.toolName === name);
  assert.ok(result?.role === "toolResult", `Missing result from ${name}`);
  return { isError: result.isError, text: result.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n") };
}
function resultCount(messages: readonly Message[], name: string): number {
  return messages.filter((message) => message.role === "toolResult" && message.toolName === name).length;
}
function callsOf(input: Context, name: string) {
  return input.messages.flatMap((message) => message.role === "assistant" ? message.content.filter((part) => part.type === "toolCall" && part.name === name) : []);
}
function script(code: string): AssistantMessage { return fauxAssistantMessage(fauxToolCall("codemode", { code }), { stopReason: "toolUse" }); }
function scriptValue(text: string): unknown { return JSON.parse(text.slice(text.indexOf("Output:\n") + "Output:\n".length)); }
function callTool(input: Context, name: string, ...calls: ToolArguments[]): AssistantMessage {
  return offeredNames(input).includes(name) ? fauxAssistantMessage(calls.map((args) => fauxToolCall(name, args)), { stopReason: "toolUse" })
    : script(`return [${calls.map((args) => `await tools.${name}(${JSON.stringify(args)})`).join(", ")}];`);
}
const done: FauxResponseFactory = () => fauxAssistantMessage("Done.");

type RoleTurn = { responsesFromFirstRequest: [FauxResponseFactory, ...FauxResponseFactory[]]; run(): Promise<void> };
async function backgroundTask(app: DiscoveryApp) {
  return app.tasks.create({ title: "Example job", outcome: "Finish the example job", model: fixtureModel, job_id: "example-job" });
}
const startRole: Record<ToolRole, (app: DiscoveryApp, input: string) => Promise<RoleTurn>> = {
  async main(app, input) {
    return { responsesFromFirstRequest: [done], async run() {
      const root = await app.session.root(BACKGROUND_CONTEXT), release = app.bind(root);
      try {
        await app.inference.configure(root, fixtureModel, { extensions: app.toolsets.main });
        assert.equal((await (await root.submit({ type: "input", content: input }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
      } finally { release(); }
    } };
  },
  async triage(app, input) {
    await app.sources.admit({ source: { provider: "mail", account: "example" }, checkpoint: null, coverage: { status: "complete" },
      events: [{ id: "example-event", version: "one", source: { provider: "mail", account: "example", thread_id: "example-thread" }, title: "Example", text: input }] }, null);
    const event = (await app.sources.events({ pending: true }))[0]; assert.ok(event);
    return { responsesFromFirstRequest: [(request) => callTool(request, "dismiss_source_events", { keys: [event.key], reason: "The example needs no work." }), done],
      async run() {
        await app.sources.triage({ type: "triage_sources", instructions: "", model: fixtureModel, cwd: app.worker.cwd, hosts: [app.worker] },
          (conversation) => app.bind(conversation, "triage"), app.toolsets.triage);
        assert.equal(await app.sources.hasWork(), false);
      } };
  },
  async worker(app, input) {
    const task = await backgroundTask(app);
    return { responsesFromFirstRequest: [done], async run() { await app.tasks.enqueue(task.id, input); await runAdmitted(app.tasks, task.id); } };
  },
  async agent(app, input) {
    const task = await backgroundTask(app);
    return { responsesFromFirstRequest: [done], async run() {
      const agent = await app.tasks.createAgent(task.id, { id: "example-agent", title: "Example agent", outcome: "Finish the example check", input, inputId: "example-agent-input" });
      await runAdmitted(app.tasks, task.id, agent.id);
    } };
  },
};
function modelTools(app: DiscoveryApp, role: ToolRole): string[] {
  return [...new Set(app.toolsets[role].flatMap((extension) => extension.tools ?? [])
    .filter((tool) => tool.deferred !== true && (tool.callers ?? ["model"]).includes("model")).map((tool) => tool.name))];
}

function expectedSurface(arm: DiscoveryArmName, role: ToolRole, production: readonly string[]): string[] {
  const surface: ToolSurface | undefined = (DISCOVERY_ARMS[arm] as DiscoveryArm)[role];
  if (surface?.codemode !== undefined) {
    const direct = [...ALWAYS_DIRECT, ...surface.codemode.keepDirect];
    return [...production.filter((name) => direct.includes(name)), "codemode"];
  }
  const deferred = surface?.deferred ?? [];
  return [...production.filter((name) => !deferred.includes(name)), ...(deferred.length > 0 ? ["tool_search"] : [])];
}

test("each arm offers its role surfaces with the always-direct tools and reports their declaration size", async (t) => {
  const production = new Map<ToolRole, string[]>(), observed: { arm: DiscoveryArmName; role: ToolRole; size: DeclarationSize }[] = [];
  for (const arm of Object.keys(DISCOVERY_ARMS) as DiscoveryArmName[]) {
    const env = await lab("agent-tool-discovery-surface-"), app = await env.open(DISCOVERY_ARMS[arm]);
    try {
      for (const role of TOOL_ROLES) {
        if (arm === "direct") production.set(role, modelTools(app, role));
        const turn = await startRole[role](app, `Report the ${role} surface.`), [first, ...rest] = turn.responsesFromFirstRequest;
        let size: DeclarationSize | undefined;
        env.faux.setResponses([(input, ...request) => { size = declarationSize(input); return first(input, ...request); }, ...rest]);
        await turn.run();
        assert.ok(size !== undefined, `${arm} ${role} made no request`);
        t.diagnostic(`${arm} ${role}: ${size.tools.length} tools, ${size.characters} characters, ~${size.estimatedTokens} tokens`);
        observed.push({ arm, role, size });
      }
    } finally { await app.close(); await env.remove(); }
  }
  for (const { arm, role, size } of observed) {
    const offered = size.tools, surface = production.get(role); assert.ok(surface);
    assert.equal(new Set(offered).size, offered.length, `${arm} ${role} offers a tool twice`);
    assert.deepEqual([...offered].sort(), expectedSurface(arm, role, surface).sort(), `${arm} ${role} offered surface`);
    assert.ok(offered.includes("read_attachment") && offered.includes("read_file"), `${arm} ${role} offers attachments and files directly`);
    assert.ok(offered.includes("browser_screenshot"), `${arm} ${role} offers browser screenshots directly`);
    if (role === "main") assert.ok(offered.includes("finish_without_reply"), `${arm} main offers finish_without_reply`);
  }
  const sizeOf = (arm: DiscoveryArmName, role: ToolRole) => {
    const found = observed.find((entry) => entry.arm === arm && entry.role === role); assert.ok(found); return found.size;
  };
  for (const role of TOOL_ROLES) {
    const direct = sizeOf("direct", role), search = sizeOf("search-browser", role), scripted = sizeOf("codemode", role);
    const browser = BROWSER_TOOLS.reduce((sum, name) => sum + (direct.perTool[name] ?? 0), 0), toolSearch = search.perTool.tool_search ?? 0;
    assert.equal(direct.section + search.section, 0, `${role} declares no code mode section without code mode`);
    assert.equal(search.characters, direct.characters - browser + toolSearch, `${role} search-browser declares the browser tools' size less, plus tool_search`);
    assert.ok(scripted.section > 0, `${role} code mode declares its tool section`);
    for (const name of ALWAYS_DIRECT) assert.equal(scripted.perTool[name], direct.perTool[name], `${role} keeps the ${name} declaration unchanged`);
  }
});

test("an arm cannot defer finish_without_reply or read_file", async () => {
  const env = await lab("agent-tool-discovery-pinned-"), app = await env.open(DISCOVERY_ARMS.direct), discovery = createToolDiscovery();
  try {
    assert.throws(() => applyToolSurfaces(app.toolsets, { main: { deferred: ["finish_without_reply"] } }, discovery), /finish_without_reply must stay directly offered/);
    assert.throws(() => applyToolSurfaces(app.toolsets, { worker: { deferred: ["read_file"] } }, discovery), /read_file must stay directly offered/);
  } finally { await discovery.close(); await app.close(); await env.remove(); }
});

test("tool_search loads browser tools for the next request, and they stay offered after reopen and compaction", async () => {
  const env = await lab("agent-tool-discovery-search-"), arm = DISCOVERY_ARMS["search-browser"], compaction = { keepRecentTokens: 1 };
  let app = await env.open(arm, compaction);
  try {
    let before: string[] = [], loaded: string[] = [];
    env.faux.setResponses([
      (input) => { before = offeredNames(input); return fauxAssistantMessage(fauxToolCall("tool_search", { query: "browser open" }), { stopReason: "toolUse" }); },
      (input) => { loaded = offeredNames(input).filter((name) => !before.includes(name)); return fauxAssistantMessage("Loaded the browser tools."); },
    ]);
    await (await startRole.main(app, "Find a tool that opens a browser page.")).run();
    assert.equal(before.some((name) => BROWSER_TOOLS.includes(name)), false, "Browser tools wait for tool_search");
    assert.ok(loaded.includes("browser_open"), `tool_search loaded ${loaded.join(", ")}`);
    assert.deepEqual(loaded.filter((name) => !BROWSER_TOOLS.includes(name)), []);
    await app.close(); app = await env.open(arm, compaction);
    let reopened: string[] = [];
    env.faux.setResponses([(input) => { reopened = offeredNames(input); return fauxAssistantMessage("Still loaded."); }]);
    await (await startRole.main(app, "Continue after the restart.")).run();
    assert.deepEqual(loaded.filter((name) => !reopened.includes(name)), [], "Loaded tools stay offered after reopen");
    const root = await app.session.root(BACKGROUND_CONTEXT);
    env.faux.setResponses([() => fauxAssistantMessage("The user asked for browser tools and tool_search loaded them.")]);
    const { outcome } = (await app.session.waitForTask(await root.compact(undefined, BACKGROUND_CONTEXT), BACKGROUND_CONTEXT)).state;
    assert.ok(outcome.status === "completed" && (outcome.result.entryId ?? outcome.result.submissionId) !== undefined, "Compaction placed a summary");
    let compacted: string[] = [], searchResults = -1;
    env.faux.setResponses([(input) => {
      compacted = offeredNames(input); searchResults = resultCount(input.messages, "tool_search");
      return fauxAssistantMessage("Still loaded after compaction.");
    }]);
    await (await startRole.main(app, "Continue after compaction.")).run();
    assert.equal(searchResults, 0, "Compaction summarized the search");
    assert.deepEqual(loaded.filter((name) => !compacted.includes(name)), [], "Loaded tools stay offered after compaction");
  } finally { await app.close(); await env.remove(); }
});

const scriptGuards: { name: string; role: ToolRole; tool: string; args: (bystander: string) => ToolArguments; error: RegExp }[] = [
  { name: "a worker script cannot call the main-only delegate_task", role: "worker", tool: "delegate_task",
    args: (bystander) => ({ task_id: bystander, input: "Take over the bystander task." }), error: /tools\.delegate_task does not exist/ },
  { name: "a worker script cannot record another task", role: "worker", tool: "record_task",
    args: (bystander) => ({ task_id: bystander, summary: "Changed by another worker.", state: { state: "resolved", evidence: "Invented completion." } }),
    error: /A worker can update only its own task/ },
  { name: "a main script cannot finish without reply", role: "main", tool: "finish_without_reply", args: () => ({}),
    error: /Finish without reply must be the main owner's sole final tool/ },
  { name: "a worker script cannot take a screenshot whose image only a direct call delivers", role: "worker", tool: "browser_screenshot",
    args: () => ({ tab_id: 1 }), error: /tools\.browser_screenshot does not exist/ },
];
for (const guard of scriptGuards) {
  test(`code mode: ${guard.name}`, async () => {
    const env = await lab("agent-tool-discovery-guard-"), app = await env.open(DISCOVERY_ARMS.codemode);
    try {
      const bystander = await app.tasks.create({ title: "Bystander", outcome: "Stay untouched by other actors", model: fixtureModel });
      const turn = await startRole[guard.role](app, "Try the guarded call.");
      const saved = async () => (await app.tasks.list()).map(({ id, state, sources }) => ({ id, state, sources }))
        .sort((left, right) => left.id.localeCompare(right.id));
      const before = await saved();
      let result: ReturnType<typeof toolResult> | undefined;
      env.faux.setResponses([
        (input) => {
          assert.equal(offeredNames(input).includes(guard.tool), ALWAYS_DIRECT.includes(guard.tool));
          return script(`return await tools.${guard.tool}(${JSON.stringify(guard.args(bystander.id))});`);
        },
        (input) => { result = toolResult(input, "codemode"); return fauxAssistantMessage("The guarded call was refused."); },
      ]);
      await turn.run();
      assert.ok(result !== undefined, "The model saw the script result and the turn went on");
      assert.equal(result.isError, true); assert.match(result.text, guard.error);
      assert.deepEqual(await app.tasks.get(bystander.id), bystander);
      assert.deepEqual(await saved(), before, "No task was created or changed state");
    } finally { await app.close(); await env.remove(); }
  });
}

test("code mode: a worker opens a tab in a script, and its direct screenshot reaches the next request and history", async () => {
  const capture = capturePng(96, 48), digest = createHash("sha256").update(capture).digest("hex");
  const tabs = [{ id: 7, title: "Invented color blocks", url: "https://example.com/blocks" }];
  const browser = (command: HostCommand): HostResult | undefined => {
    if (command.type !== "browser") return undefined;
    const { action, session_id } = command.request;
    const response: BrowserResponse = action.type === "screenshot"
      ? { type: "screenshot", session_id, tabs, capture: { data_base64: capture.toString("base64"), sha256: digest } }
      : action.type === "release" ? { type: "closed", session_id, tabs: [], output: "Released" }
      : { type: "ready", session_id, tabs, output: "Invented page ready", is_error: false };
    return { type: "browser", response };
  };
  const env = await lab("agent-tool-discovery-screenshot-", browser), app = await env.open(DISCOVERY_ARMS.production);
  try {
    const turn = await startRole.worker(app, "Show me the invented page.");
    let opened: unknown, receipt = "", image: [number, number] | undefined;
    env.faux.setResponses([
      (input) => {
        const offered = offeredNames(input);
        assert.ok(offered.includes("codemode") && offered.includes("browser_screenshot") && !offered.includes("browser_open"), offered.join(", "));
        return script(`const found = (await searchTools("browser open")).map((tool) => tool.name);
const opened = JSON.parse(await tools.browser_open({ url: "https://example.com/blocks" }));
return { found, tabs: opened.response.tabs.map((tab) => tab.id) };`);
      },
      (input) => {
        const result = toolResult(input, "codemode"); assert.equal(result.isError, false, result.text);
        opened = scriptValue(result.text);
        return fauxAssistantMessage(fauxToolCall("browser_screenshot", { tab_id: 7 }), { stopReason: "toolUse" });
      },
      (input) => {
        const result = input.messages.findLast((message) => message.role === "toolResult");
        assert.ok(result?.role === "toolResult" && result.toolName === "browser_screenshot" && result.isError !== true, JSON.stringify(result));
        const part = result.content.find((item) => item.type === "image");
        assert.ok(part?.type === "image" && part.mimeType === "image/png", "The next request carries the screenshot as native image content");
        image = pngSize(Buffer.from(part.data, "base64"));
        receipt = result.content.flatMap((item) => item.type === "text" ? [item.text] : []).join("\n");
        return fauxAssistantMessage("The invented page has three color blocks.");
      },
    ]);
    await turn.run();
    assert.ok(typeof opened === "object" && opened !== null && "found" in opened && "tabs" in opened && Array.isArray(opened.found));
    assert.ok(opened.found.includes("browser_open"), `The script found the deferred browser tools: ${JSON.stringify(opened.found)}`);
    assert.deepEqual(opened.tabs, [7], "The script opened the owned tab");
    assert.deepEqual(image, [96, 48]);
    assert.equal(receipt.includes(capture.toString("base64").slice(0, 64)), false, "Image bytes never travel as model text");
    assert.deepEqual(env.commands.flatMap((command) => command.type === "browser" ? [command.request.action.type] : []), ["open", "screenshot", "release"]);

    const conversation = await app.tasks.conversation((await ownTask(app)).conversation_id);
    const rows = (await history(conversation, null, new HistoryStore(app.session))).flatMap((page) => page.messages)
      .filter((message) => message.tool?.name === "browser_screenshot");
    const [row, ...others] = rows.filter((message) => message.tool?.status === "finished");
    assert.ok(row !== undefined && others.length === 0, "History holds one finished screenshot row");
    assert.deepEqual(rows.filter((message) => message !== row).flatMap((message) => message.attachments ?? []), [], "Only the result row carries the attachment");
    const [attachment, ...extra] = row.attachments ?? [];
    assert.ok(attachment !== undefined && extra.length === 0, "The screenshot's result row lists its attachment");
    assert.equal(attachment.media_type, "image/png");
    assert.equal(attachment.size_bytes, capture.length);
    assert.equal(attachment.sha256, digest);
    assert.ok(receipt.includes(attachment.id), "The model can name the attachment for read_attachment and delegation");
    const download = await app.attachments.request({ type: "download", id: attachment.id, offset: 0, limit: ATTACHMENT_CHUNK_BYTES });
    assert.ok(download.type === "download" && download.next_offset === null);
    assert.ok(Buffer.from(download.data_base64, "base64").equals(capture), "The retained bytes are the captured bytes");
    await assert.rejects(app.attachments.request({ type: "discard", id: attachment.id }), /retained/, "History owns the screenshot");
  } finally { await app.close(); await env.remove(); }
});

type Publication = { conversation_id: string; entry_id: string | null; text: string; call_id?: string | null };
type CallerIdentity = { role: Exclude<ToolRole, "triage">; tool: string; texts: string[]; args(text: string): ToolArguments;
  published(app: DiscoveryApp): Promise<{ caller: string; publications: Publication[] }> };
async function ownTask(app: DiscoveryApp): Promise<TaskRecord> {
  const tasks = await app.tasks.list(), [task] = tasks;
  assert.ok(task !== undefined && tasks.length === 1, "The role turn owns the only task"); return task;
}
async function toolOutcomes(app: DiscoveryApp, task: TaskRecord): Promise<Publication[]> {
  return (await app.sources.events({ provider: "task_outcomes", thread_id: task.id })).flatMap(({ outcome }) =>
    outcome === undefined || outcome.tool_call_id === null ? []
      : [{ conversation_id: outcome.conversation_id, entry_id: outcome.entry_id, text: outcome.summary, call_id: outcome.tool_call_id }]);
}
async function mainNotices(app: DiscoveryApp): Promise<Publication[]> {
  const root = await app.session.root(BACKGROUND_CONTEXT);
  return (await root.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items.flatMap((entry) =>
    UserNoticeEntry.is(entry) && entry.data !== undefined
      ? [{ conversation_id: entry.data.source_conversation_id, entry_id: entry.data.source_entry_id, text: entry.data.text ?? "" }] : []);
}
async function issuingEntry(app: DiscoveryApp, conversationId: string, name: string): Promise<{ entry_id: string; call_ids: string[] }> {
  const conversation = await app.tasks.conversation(conversationId);
  const issued = (await conversation.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT)).items.flatMap((entry) => {
    const call_ids = (entry.model ?? []).flatMap((message) => message.role !== "assistant" ? []
      : message.content.flatMap((part) => part.type === "toolCall" && part.name === name ? [part.id] : []));
    return call_ids.length === 0 ? [] : [{ entry_id: entry.id.toString(), call_ids }];
  });
  const [only] = issued; assert.ok(only !== undefined && issued.length === 1, `One assistant entry in ${conversationId} issued ${name}`);
  return only;
}
const callerIdentities: CallerIdentity[] = [
  { role: "worker", tool: "record_task", texts: ["Recorded by the worker."],
    args: (summary) => ({ summary, state: { state: "resolved", evidence: "Invented completion." } }),
    async published(app) {
      const task = await ownTask(app); assert.equal(task.state.state, "resolved");
      return { caller: task.conversation_id, publications: await toolOutcomes(app, task) };
    } },
  { role: "agent", tool: "report_result", texts: ["The invented check passed."], args: (summary) => ({ summary }),
    async published(app) {
      const task = await ownTask(app), [agent] = task.agents ?? [];
      assert.ok(agent !== undefined); assert.deepEqual(agent.state, { state: "done" });
      return { caller: agent.conversation_id, publications: await toolOutcomes(app, task) };
    } },
  { role: "main", tool: "notify", texts: ["First invented outcome.", "Second invented outcome."], args: (text) => ({ keys: [], text }),
    async published(app) { return { caller: (await app.session.root(BACKGROUND_CONTEXT)).id.toString(), publications: await mainNotices(app) }; } },
  { role: "worker", tool: "notify_user", texts: ["First invented update.", "Second invented update."], args: (text) => ({ text }),
    async published(app) { return { caller: (await ownTask(app)).conversation_id, publications: await mainNotices(app) }; } },
];
for (const identity of callerIdentities) for (const arm of ["direct", "codemode"] as const) {
  test(`${arm}: the ${identity.role}'s ${identity.tool} belongs to the conversation and assistant entry that issued it`, async () => {
    const env = await lab("agent-tool-discovery-identity-"), app = await env.open(DISCOVERY_ARMS[arm]);
    try {
      const turn = await startRole[identity.role](app, `Use ${identity.tool}.`);
      let errors: string[] | undefined;
      env.faux.setResponses([
        (input) => {
          assert.equal(offeredNames(input).includes(identity.tool), arm === "direct");
          return callTool(input, identity.tool, ...identity.texts.map((text) => identity.args(text)));
        },
        (input) => {
          errors = input.messages.flatMap((message) => message.role === "toolResult" && message.isError
            ? [message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n")] : []);
          return fauxAssistantMessage("Done.");
        },
      ]);
      await turn.run();
      assert.deepEqual(errors, [], "The model saw every call succeed");
      const { caller, publications } = await identity.published(app);
      const issued = await issuingEntry(app, caller, arm === "direct" ? identity.tool : "codemode");
      assert.deepEqual(publications.map(({ text }) => text).sort(), [...identity.texts].sort(), "Each call published once");
      for (const { conversation_id, entry_id, call_id } of publications) {
        assert.equal(conversation_id, caller, "The publication belongs to the caller's conversation");
        assert.equal(entry_id, issued.entry_id, "The publication's origin is the assistant entry that issued the model-visible call");
        if (call_id !== undefined) assert.ok(issued.call_ids.some((id) => call_id === id || call_id?.startsWith(id + "/")),
          `${call_id} is the model-visible call or nested under it`);
      }
    } finally { await app.close(); await env.remove(); }
  });
}

test("a worker's code mode item in task history shows each command, edited path and the script's output", async () => {
  const env = await lab("agent-tool-discovery-history-"), app = await env.open(DISCOVERY_ARMS.codemode);
  try {
    const turn = await startRole.worker(app, "Raise the HTTP retries.");
    const code = `const found = JSON.parse(await tools.exec({ program: "grep", args: ["-n", "max_retries", "config/limits.toml"] })).stdout;
await tools.edit_file({ path: "config/limits.toml", old: "max_retries = 3", new: "max_retries = 5" });
return "Raised max_retries after grep printed " + found;`;
    env.faux.setResponses([(input) => { assert.equal(offeredNames(input).includes("edit_file"), false); return script(code); }, done]);
    await turn.run();
    const conversation = await app.tasks.conversation((await ownTask(app)).conversation_id);
    const items = (await history(conversation, null, new HistoryStore(app.session))).flatMap((page) => page.messages)
      .filter((message) => message.tool?.name === "codemode" && message.tool.status === "finished");
    assert.equal(items.length, 1, "One finished code mode item");
    const [item] = items; assert.ok(item?.tool !== undefined);
    assert.match(item.text, /grep -n max_retries config\/limits\.toml/u, "The item shows the command the script ran");
    assert.match(item.text, /edit_file config\/limits\.toml/u, "The item shows the path the script edited");
    assert.match(item.text, /Raised max_retries after grep printed EXAMPLE_EXEC_OUTPUT/u, "The item shows the script's output");
    const details = await toolDetails(conversation, item.entry_id, item.tool.call_id, new HistoryStore(app.session));
    assert.ok(details.type === "available" && details.input.type === "text");
    assert.ok(details.input.text.includes("tools.edit_file"), "Inspecting the item shows the script");
  } finally { await app.close(); await env.remove(); }
});

test("a main script gets the same task and job results the direct calls return", async () => {
  const env = await lab("agent-tool-discovery-results-"); let app = await env.open(DISCOVERY_ARMS.direct);
  try {
    const task = await app.tasks.create({ title: "Example review", outcome: "Keep the example evidence", model: fixtureModel });
    await (await app.tasks.conversation(task.conversation_id)).submit({ type: "write", entry: { kind: "fixture.evidence",
      model: [{ role: "user", content: "EXAMPLE_TASK_EVIDENCE", timestamp: Date.now() }] } }, BACKGROUND_CONTEXT);
    const read = { task_id: task.id, include_history: true };
    let direct: unknown;
    env.faux.setResponses([
      () => fauxAssistantMessage([fauxToolCall("read_task", read), fauxToolCall("list_jobs", {})], { stopReason: "toolUse" }),
      (input) => {
        const [task, jobs] = [toolResult(input, "read_task"), toolResult(input, "list_jobs")];
        assert.equal(task.isError || jobs.isError, false);
        direct = { task: JSON.parse(task.text), jobs: JSON.parse(jobs.text) };
        return fauxAssistantMessage("Read directly.");
      },
    ]);
    await (await startRole.main(app, "Read the example task and the jobs.")).run();
    assert.match(JSON.stringify(direct), /EXAMPLE_TASK_EVIDENCE/);
    await app.close(); app = await env.open(DISCOVERY_ARMS.codemode);
    let scripted: ReturnType<typeof toolResult> | undefined;
    env.faux.setResponses([
      (input) => {
        assert.equal(offeredNames(input).some((name) => name === "read_task" || name === "list_jobs"), false);
        return script(`return { task: JSON.parse(await tools.read_task(${JSON.stringify(read)})), jobs: JSON.parse(await tools.list_jobs({})) };`);
      },
      (input) => { scripted = toolResult(input, "codemode"); return fauxAssistantMessage("Read through a script."); },
    ]);
    await (await startRole.main(app, "Read the example task and the jobs again.")).run();
    assert.ok(scripted !== undefined); assert.equal(scripted.isError, false);
    assert.deepEqual(scriptValue(scripted.text), direct);
  } finally { await app.close(); await env.remove(); }
});

function replaceWithHangingTool(extension: string, name: string, replay: "safe" | undefined, entered: () => void) {
  return defineExtension({ name: extension, tools: [defineTool({ name, ...(replay === undefined ? {} : { replay }), description: "Use the selected task.",
    parameters: Type.Object({}), async execute(_args, _api, context) { entered(); return await awaitWithContext(new Promise<never>(() => {}), context); } })] });
}
async function until(condition: () => Promise<boolean>): Promise<void> {
  for (let attempt = 0; !(await condition()); attempt++) {
    assert.ok(attempt < 500, "The condition did not hold in time"); await delay(10);
  }
}

type InterruptedRound = { name: string; arm: DiscoveryArmName; hang: { tool: string; replay?: "safe" }; round(taskId: string): AssistantMessage;
  settled(messages: readonly Message[]): boolean; resumed(input: Context, observed: { commands: readonly HostCommand[]; created: TaskRecord; current: TaskRecord }): void };
const interruptedRounds: InterruptedRound[] = [
  { name: "a reopened code mode script replays its settled nested call and reruns its interrupted replay-safe one", arm: "codemode",
    hang: { tool: "read_task", replay: "safe" },
    round: (taskId) => script(`const ran = JSON.parse(await tools.exec({ program: "example", args: [] })).stdout;
return { ran, read: JSON.parse(await tools.read_task(${JSON.stringify({ task_id: taskId, include_history: false })})) };`),
    settled: () => true,
    resumed(input, { commands, created }) {
      assert.equal(commands.filter((command) => command.type === "exec").length, 1, "The settled nested exec ran once across the restart");
      assert.equal(callsOf(input, "codemode").length, 1);
      const result = toolResult(input, "codemode"); assert.equal(result.isError, false);
      const value = scriptValue(result.text);
      assert.ok(typeof value === "object" && value !== null && "ran" in value && "read" in value);
      assert.equal(value.ran, "EXAMPLE_EXEC_OUTPUT"); assert.match(JSON.stringify(value.read), new RegExp(created.id));
    } },
  { name: "a reopened code mode script does not rerun its interrupted unsafe nested call", arm: "codemode", hang: { tool: "record_task" },
    round: (taskId) => script(`return await tools.record_task(${JSON.stringify({ task_id: taskId, summary: "Recorded once.", state: { state: "open" } })});`),
    settled: () => true,
    resumed(input, { created, current }) {
      assert.equal(callsOf(input, "codemode").length, 1);
      const result = toolResult(input, "codemode"); assert.equal(result.isError, true);
      assert.match(result.text, /record_task was interrupted and may have partially run/);
      assert.deepEqual(current, created, "The interrupted record_task did not run again after reopen");
    } },
  { name: "a reopened round keeps its settled tool_search load and resumes the interrupted call", arm: "search-browser",
    hang: { tool: "read_task", replay: "safe" },
    round: (taskId) => fauxAssistantMessage([fauxToolCall("tool_search", { query: "browser open" }),
      fauxToolCall("read_task", { task_id: taskId, include_history: false })], { stopReason: "toolUse" }),
    settled: (messages) => resultCount(messages, "tool_search") === 1,
    resumed(input, { created }) {
      assert.ok(offeredNames(input).includes("browser_open"), "The settled load survives the restart");
      assert.equal(callsOf(input, "tool_search").length, 1); assert.equal(resultCount(input.messages, "tool_search"), 1);
      const search = toolResult(input, "tool_search"); assert.equal(search.isError, false); assert.match(search.text, /browser_open/);
      const read = toolResult(input, "read_task"); assert.equal(read.isError, false); assert.match(read.text, new RegExp(created.id));
    } },
];
for (const round of interruptedRounds) {
  test(round.name, { timeout: 10_000 }, async () => {
    const env = await lab("agent-tool-discovery-reopen-"); let app = await env.open(DISCOVERY_ARMS[round.arm]);
    let release = () => {};
    try {
      const created = await app.tasks.create({ title: "Example status", outcome: "Report the example status", model: fixtureModel });
      let entered = 0, resolveStarted = () => {};
      const started = new Promise<void>((resolve) => { resolveStarted = resolve; });
      app.registry.install(replaceWithHangingTool(app.tools.main.name, round.hang.tool, round.hang.replay, () => { entered++; resolveStarted(); }));
      let root = await app.session.root(BACKGROUND_CONTEXT); release = app.bind(root);
      await app.inference.configure(root, fixtureModel, { extensions: app.toolsets.main });
      let resumed: Context | undefined;
      env.faux.setResponses([round.round(created.id), (input) => { resumed = input; return fauxAssistantMessage("Resumed once."); }]);
      const submission = await root.submit({ type: "input", content: "Run the example round once." }, BACKGROUND_CONTEXT);
      await started; await until(async () => round.settled((await root.context(BACKGROUND_CONTEXT)).messages));
      assert.equal(env.faux.state.callCount, 1);
      release(); release = () => {}; await app.close(); app = await env.open(DISCOVERY_ARMS[round.arm]);
      root = await app.session.root(BACKGROUND_CONTEXT); release = app.bind(root);
      const reopened = await app.session.submission(submission.id, BACKGROUND_CONTEXT); assert.ok(reopened);
      assert.equal((await reopened.wait(BACKGROUND_CONTEXT)).status, "done");
      assert.equal(entered, 1);
      assert.equal(env.faux.state.callCount, 2, "Reopen asks the model only for the response after the saved round");
      assert.ok(resumed !== undefined);
      round.resumed(resumed, { commands: env.commands, created, current: await app.tasks.get(created.id) });
    } finally { release(); await app.close(); await env.remove(); }
  });
}
