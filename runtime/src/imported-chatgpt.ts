import type { HistoryItem } from "./generated/HistoryItem.js";
import type { MediaOperation } from "./generated/MediaOperation.js";
import type { ToolStatus } from "./generated/ToolStatus.js";
import type { ImportedAdapter } from "./imported-history.js";
import { bounded, field, historyToolId, string, type MessageContent } from "./message-presentation.js";

const MESSAGE_CONTENT = new Set(["text", "multimodal_text", "thoughts", "reasoning_recap"]);
const MEDIA_KINDS: Readonly<Record<string, MediaOperation>> = { "tool:multimodal_text": "generate" };
const DETAIL_CHARACTERS = 32_768;

function author(item: HistoryItem): string { return item.kind.slice(0, item.kind.indexOf(":")); }
function contentType(item: HistoryItem): string { return item.kind.slice(item.kind.indexOf(":") + 1); }
function nativeMessage(data: unknown): unknown { return field(data, "message"); }
function status(data: unknown): ToolStatus {
  switch (string(field(nativeMessage(data), "status"))) {
    case "finished_successfully": return "finished";
    case "in_progress": return "running";
    default: return "unknown";
  }
}
function fullText(item: HistoryItem, data: unknown): string { return string(field(data, "text")) ?? item.text; }

function chatGptMessage(item: HistoryItem, data: unknown, entryId: string): MessageContent {
  const operation = MEDIA_KINDS[item.kind], text = fullText(item, data);
  if (item.role === "tool" && operation !== undefined) {
    return { role: "tool", text, presentation: { type: "media", operation, status: null, path: null } };
  }
  if (item.role === "tool") {
    const name = author(item) === "assistant" ? field(nativeMessage(data), "recipient") : field(field(nativeMessage(data), "author"), "name");
    return { role: "tool", text, tool: { call_id: historyToolId(entryId), name: string(name) ?? "ChatGPT tool", status: status(data) },
      presentation: { type: "tool", namespace: "chatgpt" } };
  }
  if (!MESSAGE_CONTENT.has(contentType(item))) return { role: item.role, text, presentation: { type: "unknown", kind: item.kind } };
  return { role: item.role, text };
}

export const chatGptAdapter: ImportedAdapter = {
  message: chatGptMessage,
  display: chatGptMessage,
  async toolDetail(item, data, next) {
    const own = fullText(item, data);
    if (author(item) !== "assistant") return { input: null, output: bounded(own, DETAIL_CHARACTERS), truncated: own.length > DETAIL_CHARACTERS };
    const following = await next();
    const answered = following !== undefined && author(following.item) === "tool" &&
      field(following.data, "parent_id") === field(data, "node_id");
    const output = answered ? fullText(following.item, following.data) : null;
    return { input: bounded(own, DETAIL_CHARACTERS), output: output === null ? null : bounded(output, DETAIL_CHARACTERS),
      truncated: output !== null && output.length > DETAIL_CHARACTERS };
  },
};
