import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Cursor, EntryRecord } from "@earendil-works/pi-durable";
import { openStateStorage } from "./state-storage.js";

const directory = process.argv[2];
if (directory === undefined) throw new Error("Name a closed coordinator state directory");
const app = await openStateStorage(join(directory, "session.sqlite"));
try {
  const decided = (records: Awaited<ReturnType<typeof app.sources.events>>) => records.map((record) => ({
    key: record.key, id: record.event.id, version: record.event.version, thread_id: record.event.source.thread_id,
    decision: record.decision, outcome: record.outcome?.state ?? null, tool_call_id: record.outcome?.tool_call_id ?? null,
    task_id: record.outcome?.task_id ?? null, entry_id: record.outcome?.entry_id ?? null }));
  const entries = async (id: string) => {
    const conversation = await app.tasks.conversation(id);
    const found: EntryRecord[] = [];
    let cursor: Cursor | undefined;
    do {
      const page = await conversation.entries({}, 100, cursor, BACKGROUND_CONTEXT);
      found.push(...page.items);
      cursor = page.next;
    } while (cursor !== undefined);
    return found.sort((left, right) => left.id - right.id);
  };
  const tasks = await app.tasks.list();
  const inputs: { task_id: string; entry_id: number }[] = [];
  for (const task of tasks) for (const entry of await entries(task.conversation_id)) {
    if (entry.kind === "agent.input" || entry.model?.some((message) => message.role === "user")) inputs.push({ task_id: task.id, entry_id: entry.id });
  }
  const receipts: unknown[] = [], notices: unknown[] = [];
  const conversations = await app.database.all<{ id: number }>("SELECT DISTINCT conversation_id AS id FROM entries ORDER BY id");
  for (const { id } of conversations) {
    const calls = new Map<string, unknown>();
    for (const entry of await entries(String(id))) {
      if (entry.kind === "agent.user_notice") notices.push({ conversation_id: String(id), entry_id: entry.id, data: entry.data });
      for (const message of entry.model ?? []) {
        if (message.role === "assistant") for (const part of message.content) if (part.type === "toolCall") calls.set(part.id, part.arguments);
        if (message.role !== "toolResult") continue;
        const details: unknown = message.details;
        receipts.push({ conversation_id: String(id), entry_id: entry.id, tool: message.toolName, error: message.isError,
          args: calls.get(message.toolCallId) ?? null,
          nested: typeof details === "object" && details !== null && "calls" in details && Array.isArray(details.calls) ? details.calls : [] });
      }
    }
  }
  process.stdout.write(JSON.stringify({
    mail: decided(await app.sources.events({ provider: "google", limit: 100 })),
    outcomes: decided(await app.sources.events({ provider: "task_outcomes", limit: 100 })),
    sources: await app.sources.states(),
    tasks, inputs, receipts, notices,
  }));
} finally { await app.session.close(BACKGROUND_CONTEXT); }
