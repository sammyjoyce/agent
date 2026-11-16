import { TaskError, type TaskStore } from "../../src/tasks.js";

export async function runAdmitted(tasks: TaskStore, id: string, agentId?: string, signal?: AbortSignal): Promise<void> {
  const ref = { task_id: id, ...(agentId === undefined ? {} : { agent_id: agentId }) };
  for (;;) {
    const start = await tasks.ensureActor(ref);
    switch (start.state) {
      case "started": case "running": {
        const stop = () => void tasks.stop(ref).catch(() => {});
        signal?.addEventListener("abort", stop, { once: true });
        if (signal?.aborted) stop();
        try { await start.exit; } finally { signal?.removeEventListener("abort", stop); }
        const task = await tasks.get(id);
        const pending = agentId === undefined ? task.pending : task.agents.find((agent) => agent.id === agentId)?.pending ?? [];
        if (pending.length === 0 || signal?.aborted) return;
        break;
      }
      case "idle": return;
      case "unplaced": case "host_offline": case "unavailable": throw new TaskError(start.reason);
      default: { const unknown: never = start; throw new TaskError(`Unknown actor start ${JSON.stringify(unknown)}`); }
    }
  }
}
