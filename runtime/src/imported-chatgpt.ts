import type { HistoryItem } from "./generated/HistoryItem.js";
import type { MediaOperation } from "./generated/MediaOperation.js";
import type { ToolStatus } from "./generated/ToolStatus.js";
import type { ImportedAdapter } from "./imported-history.js";
import { field, historyToolId, string, type MessageContent } from "./message-presentation.js";

/** Content the reader already turned into message text. Anything else keeps its text under an unknown presentation. */
const MESSAGE_CONTENT = new Set(["text", "multimodal_text", "thoughts", "reasoning_recap"]);
const MEDIA_KINDS: Readonly<Record<string, MediaOperation>> = { "tool:multimodal_text": "generate", "library:file": "attachment" };

/** `kind` is "<author role>:<content type>". */
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
/** Code and execution output keep their whole text in the envelope; `item.text` is a bounded excerpt. */
function fullText(item: HistoryItem, data: unknown): string {
  return string(field(field(nativeMessage(data), "content"), "text")) ?? item.text;
}

function chatGptMessage(item: HistoryItem, data: unknown, entryId: string): MessageContent {
  const operation = MEDIA_KINDS[item.kind];
  if (item.role === "tool" && operation !== undefined) {
    return { role: "tool", text: item.text, presentation: { type: "media", operation, status: null, path: null } };
  }
  if (item.role === "tool") {
    const name = author(item) === "assistant" ? field(nativeMessage(data), "recipient") : field(field(nativeMessage(data), "author"), "name");
    return { role: "tool", text: item.text, tool: { call_id: historyToolId(entryId), name: string(name) ?? "ChatGPT tool", status: status(data) },
      presentation: { type: "tool", namespace: "chatgpt" } };
  }
  if (!MESSAGE_CONTENT.has(contentType(item))) return { role: item.role, text: item.text, presentation: { type: "unknown", kind: item.kind } };
  return { role: item.role, text: item.text };
}

/** Reads only the reader's placement-free fields; the Rust reader owns the export's content shapes. */
export const chatGptAdapter: ImportedAdapter = {
  message: chatGptMessage,
  display: chatGptMessage,
  async toolDetail(item, data, next) {
    if (author(item) !== "assistant") return { input: null, output: fullText(item, data), truncated: false };
    const following = await next();
    const answered = following !== undefined && author(following.item) === "tool" &&
      field(following.data, "parent_id") === field(data, "node_id");
    return { input: fullText(item, data), output: answered ? fullText(following.item, following.data) : null, truncated: false };
  },
};
