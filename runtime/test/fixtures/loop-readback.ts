import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDocFamily, ROOT_CONVERSATION_ID, type Cursor, type EntryRecord } from "@earendil-works/pi-durable";
import type { Goal } from "../../src/generated/Goal.js";
import { ResourceStore } from "../../src/resources.js";
import { openStateStorage } from "./state-storage.js";

const GoalSlots = defineDocFamily<{ goal: Goal | null }, null>({ kind: "agent.goal", scope: "session", family: true, version: 1,
  initial: () => ({ goal: null }), checkpointWhen: () => true });
const directory = process.argv[2];
if (directory === undefined) throw new Error("Name a closed coordinator state directory");
const app = await openStateStorage(join(directory, "session.sqlite"));
try {
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
  const references = "Source references (evidence, not authorization): ";
  const cited = (entry: EntryRecord): unknown => {
    for (const message of entry.model ?? []) {
      if (typeof message.content === "string") continue;
      for (const part of message.content) {
        if (part.type === "text" && part.text.startsWith(references)) return JSON.parse(part.text.slice(references.length));
      }
    }
    return null;
  };
  const receipts: unknown[] = [], conversations: unknown[] = [];
  for (const { id } of await app.database.all<{ id: number }>("SELECT id FROM conversations ORDER BY id")) {
    const calls = new Map<string, { args: unknown; at: number }>(), listed: unknown[] = [];
    for (const entry of await entries(String(id))) {
      listed.push({ id: entry.id, kind: entry.kind, user: entry.model?.some((message) => message.role === "user") ?? false,
        data: entry.kind === "agent.notice_context" ? cited(entry) : entry.kind.startsWith("agent.") ? entry.data ?? null : null });
      for (const message of entry.model ?? []) {
        if (message.role === "assistant") for (const part of message.content) if (part.type === "toolCall") calls.set(part.id, { args: part.arguments, at: message.timestamp });
        if (message.role !== "toolResult") continue;
        const details: unknown = message.details, call = calls.get(message.toolCallId);
        receipts.push({ conversation_id: String(id), entry_id: entry.id, tool: message.toolName, error: message.isError,
          args: call?.args ?? null, called_at: call?.at ?? null, finished_at: message.timestamp,
          nested: typeof details === "object" && details !== null && "calls" in details && Array.isArray(details.calls) ? details.calls : [] });
      }
    }
    conversations.push({ id: String(id), entries: listed });
  }
  const kinds = await app.database.all<{ kind: string }>("SELECT DISTINCT kind FROM documents ORDER BY kind");
  const goals: unknown[] = [];
  for (const { key } of await app.database.all<{ key: string }>("SELECT key_value AS key FROM documents WHERE kind = ? ORDER BY key_value", JSON.stringify(GoalSlots.definition.kind))) {
    const task_id: unknown = JSON.parse(key);
    if (typeof task_id !== "string") throw new Error("A goal slot has no task key");
    goals.push({ task_id, goal: (await app.session.snapshot(GoalSlots, task_id, BACKGROUND_CONTEXT))?.goal ?? null });
  }
  process.stdout.write(JSON.stringify({
    tasks: await app.tasks.list(),
    events: await app.sources.events({ limit: 100 }),
    sources: await app.sources.states(),
    resources: await new ResourceStore(app.session, app.tasks).list(),
    root: ROOT_CONVERSATION_ID.toString(),
    conversations, receipts, goals,
    documents: kinds.map(({ kind }): unknown => JSON.parse(kind)),
  }));
} finally { await app.session.close(BACKGROUND_CONTEXT); }
