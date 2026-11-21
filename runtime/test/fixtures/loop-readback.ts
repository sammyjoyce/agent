import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { defineDoc, defineDocFamily, ROOT_CONVERSATION_ID, type Cursor, type EntryRecord } from "@earendil-works/pi-durable";
import { CodemodeStoreDoc } from "@earendil-works/pi-durable/codemode";
import type { Goal } from "../../src/generated/Goal.js";
import { ResourceStore } from "../../src/resources.js";
import { openStateStorage } from "./state-storage.js";

const GoalSlots = defineDocFamily<{ goal: Goal | null }, null>({ kind: "agent.goal", scope: "session", family: true, version: 1,
  initial: () => ({ goal: null }), checkpointWhen: () => true });
const SourceControl = defineDoc<{ conversation_id: string | null }>({ kind: "agent.source.control", scope: "session", version: 1,
  initial: () => ({ conversation_id: null }), checkpointWhen: () => true });
const triagePrompt = "Continue this admitted source work; do not repeat completed actions.\n";
const isTriageInput = (entry: EntryRecord): boolean => entry.kind === "pi.user" && (entry.model ?? []).some((message) =>
  message.role === "user" && (typeof message.content === "string"
    ? message.content.startsWith(triagePrompt)
    : message.content.some((part) => part.type === "text" && part.text.startsWith(triagePrompt))));
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
  const latestTriage = (await app.session.snapshot(SourceControl, BACKGROUND_CONTEXT))?.conversation_id ?? null;
  const tool_results: unknown[] = [], conversations: unknown[] = [], codemode_stores: unknown[] = [];
  for (const { id } of await app.database.all<{ id: number }>("SELECT id FROM conversations ORDER BY id")) {
    const issued = new Map<string, number>(), listed: unknown[] = [], rawEntries = await entries(String(id));
    for (const entry of rawEntries) {
      listed.push({ id: entry.id, kind: entry.kind, assistant: entry.model?.some((message) => message.role === "assistant") ?? false, user: entry.model?.some((message) => message.role === "user") ?? false,
        data: entry.kind === "agent.notice_context" ? cited(entry) : entry.kind.startsWith("agent.") ? entry.data ?? null : null });
      for (const message of entry.model ?? []) {
        if (message.role === "assistant") for (const part of message.content) if (part.type === "toolCall") issued.set(part.id, entry.id);
        if (message.role !== "toolResult") continue;
        tool_results.push({ conversation_id: String(id), entry_id: entry.id, call_entry_id: issued.get(message.toolCallId) ?? null, tool: message.toolName,
          text: message.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n") });
      }
    }
    const userEntries = rawEntries.filter((entry) => entry.kind === "pi.user");
    const triage = id !== ROOT_CONVERSATION_ID && (await app.tasks.findOwner(String(id))) === undefined &&
      (String(id) === latestTriage || (userEntries.length > 0 && userEntries.every(isTriageInput)));
    conversations.push({ id: String(id), triage, entries: listed });
    const saved = await app.session.snapshot(CodemodeStoreDoc, (await app.tasks.conversation(String(id))).id, BACKGROUND_CONTEXT);
    if (saved !== undefined) codemode_stores.push({ conversation_id: String(id), values: saved.values });
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
    conversations, tool_results, codemode_stores, goals,
    documents: kinds.map(({ kind }): unknown => JSON.parse(kind)),
  }));
} finally { await app.session.close(BACKGROUND_CONTEXT); }
