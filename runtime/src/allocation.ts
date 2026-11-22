import { defineEntry } from "@earendil-works/pi-durable";
import type { AllocationDecision } from "./generated/AllocationDecision.js";
import type { AllocationResult } from "./generated/AllocationResult.js";
import type { HostResult } from "./generated/HostResult.js";
import type { ResourceRecord } from "./generated/ResourceRecord.js";

/** Private lifecycle evidence; no model projection and no second logging store. */
export const AllocationDecisionEntry = defineEntry<AllocationDecision>("agent.allocation");

export type RetainedResourceLineage = {
  id: string;
  host_id: string;
  repository: string;
  branch: string;
  path: string | null;
  state: ResourceRecord["state"]["state"];
};

export type TaskTransferData = {
  task_id: string;
  from_host_id: string | null;
  from_host_name: string;
  from_cwd: string;
  to_host_id: string | null;
  to_host_name: string;
  to_cwd: string;
  retained_resources: RetainedResourceLineage[];
};

export const TaskTransferEntry = defineEntry<TaskTransferData>("agent.task_transfer");

export function resourceLineage(resource: ResourceRecord): RetainedResourceLineage {
  return {
    id: resource.id,
    host_id: resource.host_id,
    repository: resource.repository,
    branch: resource.branch,
    path: "identity" in resource.state && resource.state.identity !== null ? resource.state.identity.top : null,
    state: resource.state.state,
  };
}

export function formatTaskTransferNotice(data: TaskTransferData): string {
  const resources = data.retained_resources.length === 0 ? ""
    : ` Retained resources on prior hosts (${data.retained_resources.length}): ${data.retained_resources.map((item) =>
      `${item.host_id}:${item.branch}@${item.path ?? item.repository} (${item.state})`).join(", ")}.`;
  return `Transferred task from offline host ${data.from_host_name} (${data.from_cwd}) to ${data.to_host_name} (${data.to_cwd}).${resources}`;
}

export function allocationResult(result: HostResult): AllocationResult {
  switch (result.type) {
    case "written": return { type: "written" };
    case "spawned": return { type: "spawned", binding: result.binding };
    case "worker_presence": return { type: "presence", presence: result.presence };
    case "creation_uncertain": return { type: "creation_uncertain", session_id: result.session_id };
    case "not_started": return { type: "not_started", message: result.message };
    case "failed": return { type: "failed", message: result.message };
    default: return { type: "failed", message: `Unexpected native allocation result: ${result.type}` };
  }
}
