import { CodemodeSandbox } from "@earendil-works/pi-codemode";
import { defineExtension, wrapTool, type Extension } from "@earendil-works/pi-durable";
import { createCodemodeExtension } from "@earendil-works/pi-durable/codemode";
import { createToolSearchExtension } from "@earendil-works/pi-durable/tool-search";
import type { createBrowserTools } from "./browser.js";
import type { createGuidance } from "./guidance.js";
import type { createResourceTools } from "./resources.js";
import type { createSourceTools } from "./sources.js";
import type { createAppTools, createJobTools } from "./tools.js";

export type ToolRole = "main" | "triage" | "worker" | "agent";
export type Toolsets = Record<ToolRole, readonly Extension[]>;
export const TOOL_ROLES: readonly ToolRole[] = ["main", "triage", "worker", "agent"];

/** Compose existing tools by actor ownership; execution guards remain on the tools. */
export function createToolsets({ guidance, tools, sourceTools, resourceTools, browserTools, jobTools }: {
  guidance: ReturnType<typeof createGuidance>;
  tools: ReturnType<typeof createAppTools>;
  sourceTools: ReturnType<typeof createSourceTools>;
  resourceTools: ReturnType<typeof createResourceTools>;
  browserTools: ReturnType<typeof createBrowserTools>;
  jobTools: ReturnType<typeof createJobTools>;
}): Toolsets {
  return {
    main: [guidance, tools.host, tools.main, sourceTools.main, resourceTools.main, browserTools, jobTools],
    triage: [guidance, tools.host, tools.main, sourceTools.main, browserTools, jobTools],
    worker: [guidance, tools.host, tools.worker, sourceTools.worker, resourceTools.worker, browserTools],
    agent: [guidance, tools.host, tools.agent, sourceTools.worker, resourceTools.worker, browserTools],
  };
}

export function withActorPolicies(toolsets: Toolsets, { responsePolicy, inputOrigins }: {
  responsePolicy: Extension; inputOrigins: Extension;
}): Toolsets {
  return { ...toolsets, main: [...toolsets.main, responsePolicy, inputOrigins],
    worker: [...toolsets.worker, inputOrigins], agent: [...toolsets.agent, inputOrigins] };
}

export type ToolSurface = {
  readonly deferred?: readonly string[];
  readonly codemode?: { readonly keepDirect: readonly string[] };
};
export type ToolSurfaces = Readonly<Partial<Record<ToolRole, ToolSurface>>>;

export const ROOT_FINAL_TOOLS: readonly string[] = ["finish_without_reply"];
export const IMAGE_RESULT_TOOLS: readonly string[] = ["read_attachment", "read_file", "browser_screenshot"];
export const ALWAYS_DIRECT: readonly string[] = [...ROOT_FINAL_TOOLS, ...IMAGE_RESULT_TOOLS];
export const BROWSER_TOOLS: readonly string[] = ["browser_user_tabs", "browser_claim_tab", "browser_open", "browser_status",
  "browser_action", "browser_run_code", "browser_release"];
export const CONTEXT_TOOLS: readonly string[] = ["read_context", "search_context"];

const CHILD_DEFERRED: readonly string[] = [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "allocate_worktree", "read_resources", "read_source_events", "notify_user"];
export const TOOL_SURFACES = {
  main: { deferred: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "read_resources", "collect_worktrees", "revoke_allocation",
    "read_source_events", "notify_user", "notify", "link_source_events", "dismiss_source_events"] },
  triage: { deferred: [...BROWSER_TOOLS, ...CONTEXT_TOOLS, "revoke_allocation"], codemode: { keepDirect: ["record_task"] } },
  worker: { deferred: CHILD_DEFERRED, codemode: { keepDirect: ["record_task"] } },
  agent: { deferred: CHILD_DEFERRED, codemode: { keepDirect: [] } },
} as const satisfies Record<ToolRole, ToolSurface>;

export function createToolDiscovery() {
  const sandbox = new CodemodeSandbox();
  return { toolSearch: createToolSearchExtension(), codemode: createCodemodeExtension({ sandbox, models: false }),
    close: () => sandbox.close() };
}
export type ToolDiscovery = ReturnType<typeof createToolDiscovery>;

export function applyToolSurfaces(toolsets: Toolsets, surfaces: ToolSurfaces, discovery: ToolDiscovery): { toolsets: Toolsets; installed: Extension[] } {
  const installed: Extension[] = [discovery.toolSearch, discovery.codemode];
  const offered = Object.fromEntries(TOOL_ROLES.map((role) => {
    const surface = surfaces[role];
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
    // Stored agent configuration names this extension, so the name must stay stable.
    const wrapper = defineExtension({ name: `tool-surface-${role}`, wraps: [...wrapped.values()].map((tool) => wrapTool(tool, (selected) => ({ ...selected,
      ...(deferred.includes(tool) ? { deferred: true as const } : {}), ...(scripted.includes(tool) ? { callers: ["tools"] as const } : {}) }))) });
    installed.push(wrapper);
    const searchable = deferred.some((tool) => direct === undefined || direct.has(tool.name));
    return [role, [...base, wrapper, ...(searchable ? [discovery.toolSearch] : []), ...(direct === undefined ? [] : [discovery.codemode])]];
  })) as Toolsets;
  return { toolsets: offered, installed };
}
