import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import type { Context, MutableModels } from "@earendil-works/pi-ai";
import { getCurrentSystemPrompt, getCurrentTools } from "@earendil-works/pi-ai/utils/transcript";
import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { createRegistry, defineExtension, Harness, wrapTool, type CompactionSettings, type Conversation, type Extension, type Registry } from "@earendil-works/pi-durable";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import { join } from "node:path";
import { BackgroundScheduler } from "../../src/background.js";
import { BrowserStore, createBrowserTools } from "../../src/browser.js";
import { CoordinatorEnvironment } from "../../src/environment.js";
import type { AgentNode } from "../../src/generated/AgentNode.js";
import type { HostCommand } from "../../src/generated/HostCommand.js";
import type { HostResult } from "../../src/generated/HostResult.js";
import type { ModelSelection } from "../../src/generated/ModelSelection.js";
import { createGuidance } from "../../src/guidance.js";
import { createInputOrigins } from "../../src/input_origin.js";
import { createMainResponsePolicy } from "../../src/main_response.js";
import { ConversationModels } from "../../src/models.js";
import { createResourceTools, ResourceStore } from "../../src/resources.js";
import { openJobActor, runScheduled } from "../../src/scheduled.js";
import { createSourceTools, SourceJournal } from "../../src/sources.js";
import { TaskStore } from "../../src/tasks.js";
import { createAppTools, createJobTools, Executions } from "../../src/tools.js";
import { createToolsets, withActorPolicies, type ToolRole, type Toolsets } from "../../src/toolsets.js";

export const TOOL_ROLES: readonly ToolRole[] = ["main", "triage", "worker", "agent"];

export type ToolSurface = {
  readonly deferred?: readonly string[];
  readonly codemode?: { readonly keepDirect: readonly string[] };
};
export type DiscoveryArm = Readonly<Partial<Record<ToolRole, ToolSurface>>>;

export const ROOT_FINAL_TOOLS: readonly string[] = ["finish_without_reply"];
export const IMAGE_RESULT_TOOLS: readonly string[] = ["read_attachment", "read_file"];
export const ALWAYS_DIRECT: readonly string[] = [...ROOT_FINAL_TOOLS, ...IMAGE_RESULT_TOOLS];
export const BROWSER_TOOLS: readonly string[] = ["browser_user_tabs", "browser_claim_tab", "browser_open", "browser_status",
  "browser_action", "browser_run_code", "browser_release"];

export const CONTEXT_TOOLS: readonly string[] = ["read_context", "search_context"];
const RARE_TOOLS: Record<ToolRole, readonly string[]> = {
  main: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "read_resources", "collect_worktrees", "revoke_allocation"],
  triage: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "revoke_allocation"],
  worker: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "allocate_worktree", "read_resources"],
  agent: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "allocate_worktree", "read_resources"],
};
const SOURCE_TOOLS: Record<ToolRole, readonly string[]> = {
  main: ["read_source_events", "notify_user", "notify", "link_source_events", "dismiss_source_events"],
  triage: [],
  worker: ["read_source_events", "notify_user"],
  agent: ["read_source_events", "notify_user"],
};

const LEAN_TOOLS: Record<ToolRole, readonly string[]> = {
  main: ["record_task"],
  triage: ["exec", "edit_file", "write_file", "read_job", "run_job"],
  worker: [],
  agent: [],
};

function recordingCodemode(role: ToolRole): ToolSurface {
  return { deferred: [...RARE_TOOLS[role], ...SOURCE_TOOLS[role]], codemode: { keepDirect: role === "agent" ? [] : ["record_task"] } };
}

function everyRole(surface: ToolSurface | ((role: ToolRole) => ToolSurface)): DiscoveryArm {
  return Object.fromEntries(TOOL_ROLES.map((role) => [role, typeof surface === "function" ? surface(role) : surface]));
}

export const DISCOVERY_ARMS = {
  direct: {},
  "search-browser": everyRole({ deferred: BROWSER_TOOLS }),
  "search-rare": everyRole((role) => ({ deferred: RARE_TOOLS[role] })),
  "search-sources": everyRole((role) => ({ deferred: [...RARE_TOOLS[role], ...SOURCE_TOOLS[role]] })),
  "search-lean": everyRole((role) => ({ deferred: [...RARE_TOOLS[role], ...SOURCE_TOOLS[role], ...LEAN_TOOLS[role]] })),
  codemode: everyRole({ codemode: { keepDirect: [] } }),
  "codemode-core": everyRole((role) => ({ deferred: [...RARE_TOOLS[role], ...SOURCE_TOOLS[role]], codemode: { keepDirect: [] } })),
  "codemode-recording": everyRole(recordingCodemode),
  split: { ...everyRole(recordingCodemode), main: { deferred: [...RARE_TOOLS.main, ...SOURCE_TOOLS.main] } },
} as const satisfies Record<string, DiscoveryArm>;
export type DiscoveryArmName = keyof typeof DISCOVERY_ARMS;

export function isDiscoveryArmName(value: string): value is DiscoveryArmName {
  return Object.hasOwn(DISCOVERY_ARMS, value);
}

export function createDiscoveryExtensions() {
  const sandbox = new CodemodeSandbox();
  return { toolSearch: createToolSearchExtension(), codemode: createCodemodeExtension({ sandbox, models: false }),
    close: () => sandbox.close() };
}
export type DiscoveryExtensions = ReturnType<typeof createDiscoveryExtensions>;

export function applyDiscoveryArm(toolsets: Toolsets, arm: DiscoveryArm, discovery: DiscoveryExtensions): { toolsets: Toolsets; installed: Extension[] } {
  const installed: Extension[] = [];
  const surfaces = Object.fromEntries(TOOL_ROLES.map((role) => {
    const surface = arm[role];
    const base = toolsets[role];
    if (surface === undefined) return [role, base];
    const tools = base.flatMap((extension) => extension.tools ?? []);
    const named = (name: string) => {
      const tool = tools.find((candidate) => candidate.name === name);
      if (tool === undefined) throw new Error(`${role} has no tool named ${name}`);
      return tool;
    };
    const deferred = (surface.deferred ?? []).map(named);
    const pinned = deferred.filter((tool) => ALWAYS_DIRECT.includes(tool.name));
    if (pinned.length > 0) throw new Error(`${pinned.map((tool) => tool.name).join(", ")} must stay directly offered`);
    const direct = surface.codemode === undefined ? undefined : new Set([...ALWAYS_DIRECT, ...surface.codemode.keepDirect]);
    const scripted = direct === undefined ? [] : tools.filter((tool) => !direct.has(tool.name) && (tool.callers ?? ["model", "tools"]).includes("model"));
    const wrapped = new Map([...deferred, ...scripted].map((tool) => [tool.name, tool]));
    const wrapper = defineExtension({ name: `tool-surface-${role}`, wraps: [...wrapped.values()].map((tool) => wrapTool(tool, (selected) => ({ ...selected,
      ...(deferred.includes(tool) ? { deferred: true as const } : {}), ...(scripted.includes(tool) ? { callers: ["tools"] as const } : {}) }))) });
    installed.push(wrapper);
    const searchable = deferred.some((tool) => direct === undefined || direct.has(tool.name));
    return [role, [...base, wrapper, ...(searchable ? [discovery.toolSearch] : []), ...(direct === undefined ? [] : [discovery.codemode])]];
  })) as Toolsets;
  return { toolsets: surfaces, installed };
}

export type DeclarationSize = { tools: string[]; perTool: Record<string, number>; section: number; characters: number; estimatedTokens: number };

export function declarationSize(context: Context): DeclarationSize {
  const tools = getCurrentTools(context.messages);
  const section = /<codemode>[\s\S]*?<\/codemode>/u.exec(getCurrentSystemPrompt(context.messages))?.[0].length ?? 0;
  const perTool = Object.fromEntries(tools.map((tool) => [tool.name, tool.name.length + tool.description.length + JSON.stringify(tool.parameters).length]));
  const characters = Object.values(perTool).reduce((sum, size) => sum + size, section);
  return { tools: tools.map((tool) => tool.name), perTool, section, characters, estimatedTokens: Math.ceil(characters / 4) };
}

export type DiscoveryHost = { node: AgentNode; call(command: HostCommand): Promise<HostResult> };

export async function openDiscoveryApp(directory: string, { models, model, arm, host, retry = false, compaction }: {
  models: MutableModels; model: ModelSelection; arm: DiscoveryArm; host: DiscoveryHost; retry?: boolean; compaction?: CompactionSettings;
}) {
  const registry: Registry = createRegistry();
  const session = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))), {
    models, registry, identity: { attribution: null },
    settings: { retry: { enabled: retry }, steeringMode: "all", followUpMode: "one-at-a-time", ...(compaction === undefined ? {} : { compaction }) },
  }, BACKGROUND_CONTEXT);
  const inference = new ConversationModels(models); inference.bind(session);
  const tasks = new TaskStore(session, inference), executions = new Executions();
  const environment = new CoordinatorEnvironment(session); environment.useLiveGuidance(); tasks.useEnvironment(environment);
  await environment.configure({ node: host.node, settings: { model, instructions: "", context_repositories: [], sources: [] } });
  environment.setConnected([host.node.host_id]);
  const worker = await environment.defaultHost(await environment.hosts(host.node.home_directory, null, []));
  if (worker === null) throw new Error("The invented host must be the default worker host");
  const sources = new SourceJournal(session, tasks, executions), resources = new ResourceStore(session, tasks); tasks.guardResources(resources);
  const tools = createAppTools(tasks, executions), sourceTools = createSourceTools(sources, executions);
  const bind = (conversation: Conversation, role?: "worker" | "triage") => executions.bind(conversation.id.toString(), {
    model, cwd: worker.cwd, hosts: [worker], default_host: worker, ...(role === undefined ? {} : { role }), call: host.call, notify: () => {},
  });
  const scheduler = new BackgroundScheduler(session, registry, tasks, {
    plan: async () => ({ due: null, next: Date.now() + 86_400_000 }),
    async refreshSources() {}, async triageSources() {}, async collectResources() {}, async indexHistory() {},
    jobActor: (job) => openJobActor(job, tasks), runJob: (occurrence, signal, id) => runScheduled(occurrence, signal, { session, tasks, sources }, id),
  });
  const jobTools = createJobTools(scheduler, executions);
  const production = withActorPolicies(createToolsets({ guidance: createGuidance(executions), tools, sourceTools,
    resourceTools: createResourceTools(resources, tasks, executions), browserTools: createBrowserTools(new BrowserStore(session), executions), jobTools,
  }), { responsePolicy: createMainResponsePolicy(session), inputOrigins: createInputOrigins(session) });
  const discovery = createDiscoveryExtensions();
  const { toolsets, installed } = applyDiscoveryArm(production, arm, discovery);
  for (const extension of new Set([...Object.values(production).flat(), discovery.toolSearch, discovery.codemode, ...installed, tools.legacy])) {
    registry.install(extension);
  }
  tasks.useBackgroundExecution({ available: () => true, extensions: (agentId) => agentId === undefined ? toolsets.worker : toolsets.agent,
    call: (command, _host, signal) => { signal.throwIfAborted(); return host.call(command); },
    bind: (conversation) => bind(conversation, "worker"),
  });
  async function close(): Promise<void> {
    const detached = tasks.detachBackground();
    await session.close(BACKGROUND_CONTEXT); await detached; await discovery.close();
  }
  return { session, registry, inference, tasks, environment, sources, resources, scheduler, executions, tools, toolsets, worker, bind, close };
}
export type DiscoveryApp = Awaited<ReturnType<typeof openDiscoveryApp>>;
