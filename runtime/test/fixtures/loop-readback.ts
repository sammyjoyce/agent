import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Cursor } from "@earendil-works/pi-durable";
import { openStateStorage } from "./state-storage.js";

const directory = process.argv[2];
if (directory === undefined) throw new Error("Name a closed coordinator state directory");
const app = await openStateStorage(join(directory, "session.sqlite"));
try {
  const decided = (records: Awaited<ReturnType<typeof app.sources.events>>) => records.map((record) => ({
    key: record.key, id: record.event.id, version: record.event.version, thread_id: record.event.source.thread_id,
    decision: record.decision, outcome: record.outcome?.state ?? null, tool_call_id: record.outcome?.tool_call_id ?? null }));
  const tasks = await app.tasks.list();
  const inputs: { task_id: string; entry_id: string }[] = [];
  for (const task of tasks) {
    const conversation = await app.tasks.conversation(task.conversation_id);
    let cursor: Cursor | undefined;
    do {
      const page = await conversation.entries({}, 100, cursor, BACKGROUND_CONTEXT);
      for (const entry of page.items) if (entry.kind === "agent.input" || entry.model?.some((message) => message.role === "user")) {
        inputs.push({ task_id: task.id, entry_id: entry.id.toString() });
      }
      cursor = page.next;
    } while (cursor !== undefined);
  }
  process.stdout.write(JSON.stringify({
    mail: decided(await app.sources.events({ provider: "google", limit: 100 })),
    outcomes: decided(await app.sources.events({ provider: "task_outcomes", limit: 100 })),
    sources: await app.sources.states(),
    tasks, inputs,
  }));
} finally { await app.session.close(BACKGROUND_CONTEXT); }
