import { createHash } from "node:crypto";
import { cp, mkdir, readdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { HistoryStore } from "../../src/history.js";
import { Retrieval } from "../../src/retrieval.js";
import { TaskStore, type HostCall } from "../../src/tasks.js";
import type { EmbeddingSpace } from "../../src/generated/EmbeddingSpace.js";
import type { HistoryItem } from "../../src/generated/HistoryItem.js";

globalThis.fetch = async () => { throw new Error("Performance scenarios must not contact a provider"); };

// Snapshot subdirectories named in examples/cli_performance/coordinator.rs.
const SEARCH_INDEX = "search", CODEX_CORPUS = "codex";
const ROLLOUTS = 200, ITEMS_PER_ROLLOUT = 50;

const directory = process.argv[2];
if (directory === undefined) throw new Error("A synthetic state directory is required");
await mkdir(directory, { recursive: true, mode: 0o700 });
const open = async (path: string) => Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(path)),
  { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
const session = await open(join(directory, "session.sqlite"));
let ids: { chief: string; long_history: string };
try {
  const root = await session.root(BACKGROUND_CONTEXT);
  for (let index = 0; index < 40; index += 1) {
    await root.submit({ type: "write", entry: { kind: "agent.performance", data: { index }, model: [{
      role: "user", content: index === 39 ? "Stored chief conversation is ready." : `Synthetic chief conversation message ${index}.`, timestamp: index,
    }] } }, BACKGROUND_CONTEXT);
  }
  const histories = new HistoryStore(session);
  // Known-chat startup must stay independent of an unrelated retained corpus.
  for (let index = 0; index < 3_000; index += 1) {
    await histories.import({ host_id: "performance-fixture", thread: { id: `unrelated-${index}`, title: `Unrelated saved discussion ${index}`,
      cwd: directory, created_at: 1, updated_at: 2, version: "v1", version_reliable: true, archived: true,
      forked_from_id: null, parent_thread_id: null }, items: [], next_cursor: null, gaps: [], complete: true });
  }
  const items: HistoryItem[] = Array.from({ length: 5_000 }, (_, index) => {
    const text = index === 4_999 ? "Stored long conversation is ready."
      : `Synthetic retained conversation message ${index}. A previous task has context that remains readable after its terminal closes.`;
    return { id: `message-${index}`, turn_id: `turn-${Math.floor(index / 2)}`, kind: index % 2 === 0 ? "userMessage" : "agentMessage",
      role: index % 2 === 0 ? "user" : "assistant", text, version: "v1", order: index, timestamp_ms: index,
      data: { text, phase: "final_answer" }, assets: [] };
  });
  const saved = await histories.import({ host_id: "performance-fixture", thread: { id: "long-history", title: "Synthetic long conversation",
    cwd: directory, created_at: 1, updated_at: 2, version: "v1", version_reliable: true, archived: true,
    forked_from_id: null, parent_thread_id: null }, items, next_cursor: null, gaps: [], complete: true });
  ids = { chief: root.id.toString(), long_history: saved.conversation.conversation_id };
} finally { await session.close(BACKGROUND_CONTEXT); }

const dimensions = 8;
const space: EmbeddingSpace = { id: "performance-fixture-v1", model_revision: "deterministic", model_digest: "synthetic",
  dimensions, pooling: "last", normalization: "l2", instruction_version: 1 };
function vector(text: string): number[] {
  const digest = createHash("sha256").update(text).digest();
  const values = Array.from({ length: dimensions }, (_, index) => digest.readInt16LE(index * 2) / 32_768 + 0.001);
  const norm = Math.hypot(...values);
  return values.map((value) => value / norm);
}

/** Indexes a copy of the session so coordinators without search start from unchanged files. */
async function searchIndex(): Promise<{ conversations: number; chunks: number }> {
  const target = join(directory!, SEARCH_INDEX);
  await mkdir(target, { mode: 0o700 });
  const copies = (await readdir(directory!)).filter((name) => name.startsWith("session.sqlite"));
  for (const name of copies) await cp(join(directory!, name), join(target, name));
  const copy = await open(join(target, "session.sqlite"));
  try {
    const histories = new HistoryStore(copy), tasks = new TaskStore(copy);
    tasks.useHistory(histories);
    const retrieval = new Retrieval(copy, histories, tasks, join(target, "search.sqlite"));
    const call: HostCall = async (command) => {
      if (command.type !== "embed") throw new Error(`The performance seed cannot run ${command.type}`);
      return { type: "embeddings", batch: { space, vectors: command.texts.map(vector) } };
    };
    try { await retrieval.sync(call, true); } finally { await retrieval.close(); }
  } finally { await copy.close(BACKGROUND_CONTEXT); }
  for (const name of await readdir(target)) if (name.startsWith("session.sqlite")) await rm(join(target, name));
  const index = new DatabaseSync(join(target, "search.sqlite"));
  try {
    const count = (table: string) => Number(index.prepare(`SELECT COUNT(*) AS count FROM ${table}`).get()?.count);
    return { conversations: count("conversations"), chunks: count("chunks") };
  } finally { index.close(); }
}

/** Invented legacy rollouts that the real Codex app-server lists and reads. */
async function codexCorpus(): Promise<{ rollouts: number; items_per_rollout: number }> {
  const home = join(directory!, CODEX_CORPUS), folder = join(home, "sessions", "2026", "01", "02");
  await mkdir(folder, { recursive: true, mode: 0o700 });
  await writeFile(join(home, "config.toml"), "model_provider = \"openai\"\n");
  const line = (type: string, payload: object) => JSON.stringify({ timestamp: "2026-01-02T12:00:00Z", type, payload }) + "\n";
  for (let rollout = 0; rollout < ROLLOUTS; rollout += 1) {
    const id = `00000000-0000-4000-8000-${rollout.toString().padStart(12, "0")}`;
    const lines = [
      line("session_meta", { id, session_id: id, timestamp: "2026-01-02T12:00:00Z", cwd: "/", originator: "synthetic-benchmark",
        cli_version: "0.0.0", source: "cli", model_provider: "openai", history_mode: "legacy" }),
      line("event_msg", { type: "user_message", message: `Summarize invented ledger ${rollout}.`, images: [], local_images: [], text_elements: [] }),
      line("event_msg", { type: "task_started", turn_id: "turn-a", root_turn_id: "turn-a", started_at: 1767355200, model_context_window: null }),
      ...Array.from({ length: ITEMS_PER_ROLLOUT }, (_, item) => line("event_msg", { type: "item_completed", thread_id: id, turn_id: "turn-a",
        item: { type: "AgentMessage", id: `item-${rollout}-${item}`, phase: "final_answer",
          content: [{ type: "Text", text: `Invented ledger ${rollout} entry ${item} balances a synthetic account.` }] },
        completed_at_ms: 1767355200000 })),
    ];
    await writeFile(join(folder, `rollout-2026-01-02T12-00-00-${id}.jsonl`), lines.join(""));
  }
  return { rollouts: ROLLOUTS, items_per_rollout: ITEMS_PER_ROLLOUT };
}

// The search index needs sqlite-vec; the benchmark passes it only when a
// selected scenario searches.
const search_corpus = process.env.AGENT_SQLITE_VEC === undefined ? null : await searchIndex();
const import_corpus = await codexCorpus();
process.stdout.write(JSON.stringify({ ...ids, search_corpus, import_corpus }) + "\n");
