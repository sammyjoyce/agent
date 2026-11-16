import { createHash } from "node:crypto";
import type { ChatGptEnvelope } from "../../src/generated/ChatGptEnvelope.js";
import type { ChatGptMessage } from "../../src/generated/ChatGptMessage.js";
import type { HistoryBranch } from "../../src/generated/HistoryBranch.js";
import type { HistoryBranchState } from "../../src/generated/HistoryBranchState.js";
import type { HistoryImportBatch } from "../../src/generated/HistoryImportBatch.js";
import type { HistoryItem } from "../../src/generated/HistoryItem.js";
import type { HistoryRole } from "../../src/generated/HistoryRole.js";
import { CHATGPT_ORIGIN } from "../../src/importer.js";

export type ChatGptNode = { id: string; parent: string | null; turn: string; kind: string; role: HistoryRole; text: string;
  state?: HistoryBranchState; alternates?: number; message?: Partial<ChatGptMessage> };

const TEXT_EXCERPT = 16 * 1024;

export function sha256(value: string | Buffer): string { return createHash("sha256").update(value).digest("hex"); }

export function chatGptBatch(conversation: string, updated_at: number, nodes: readonly ChatGptNode[], title = "Picnic planning"): HistoryImportBatch {
  let follows: string | undefined;
  const items = nodes.map((node, order): HistoryItem => {
    const state = node.state ?? "current", [author = "", content_type = ""] = node.kind.split(":");
    const branch: HistoryBranch = { state, alternates: node.alternates ?? 0, ...(state === "current" && follows !== undefined ? { follows } : {}) };
    const data: ChatGptEnvelope = { conversation_id: conversation, node_id: node.id, parent_id: node.parent, text: node.text, attachments: [],
      message: { id: node.id, author: { role: author }, content_type, status: "finished_successfully", recipient: "all", ...node.message } };
    const version = sha256(JSON.stringify([node.kind, node.role, branch, data, node.turn]));
    if (state === "current") follows = version;
    return { id: node.id, turn_id: node.turn, kind: node.kind, role: node.role, text: node.text.slice(0, TEXT_EXCERPT), version, order, timestamp_ms: null, data, assets: [], branch };
  });
  return { source: "chatgpt", host_id: CHATGPT_ORIGIN, items, next_cursor: null, gaps: [], complete: true,
    thread: { id: conversation, title, cwd: "", created_at: 1, updated_at, version: sha256(JSON.stringify(items.map((item) => item.version))),
      version_reliable: true, archived: false, forked_from_id: null, parent_thread_id: null } };
}
