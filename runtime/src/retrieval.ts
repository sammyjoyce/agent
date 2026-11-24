import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { CommitObservation, Harness } from "@earendil-works/pi-durable";
import type { HostCall, TaskStore } from "./tasks.js";
import type { HistoryStore } from "./history.js";
import { SIDECHAT_RECORDS_KIND, type SidechatStore } from "./sidechats.js";
import { SearchIndex, type Embed, type SearchResult } from "./search.js";
import type { SearchMode } from "./generated/SearchMode.js";

/** Commit notifications enqueue work; indexing never reenters the Pi commit. */
export class Retrieval {
  private index: SearchIndex | undefined;
  private ready = false;
  private readonly dirty = new Map<string, string>();
  private readonly isolatedByConversation = new Map<string, boolean>();
  private readonly policyDirtySidechats = new Set<string>();
  private policyVersion = 0;
  private readonly commits: CommitObservation;
  private syncing = Promise.resolve();
  private pendingSyncs = 0;
  private closing: Promise<void> | undefined;
  constructor(session: Harness, private readonly histories: HistoryStore, private readonly tasks: TaskStore, private readonly path: string,
    private readonly sidechats?: SidechatStore) {
    this.commits = session.observeCommits({ advance: (publication) => {
      for (const change of publication.changes) {
        if (change.type === "entry") {
          this.dirty.set(change.value.conversationId.toString(), change.value.id.toString());
        } else if (change.type === "document" && change.kind === "change" &&
          change.record.kind === SIDECHAT_RECORDS_KIND && typeof change.record.key === "string") {
          const slot = change.value.value;
          const isolated = slot !== null && typeof slot === "object" && !Array.isArray(slot) && slot.isolated === true;
          const previous = this.isolatedByConversation.get(change.record.key);
          this.isolatedByConversation.set(change.record.key, isolated);
          if (previous === undefined || previous !== isolated) {
            this.policyVersion += 1;
            this.dirty.set(change.record.key, "policy:" + this.policyVersion.toString());
            this.policyDirtySidechats.add(change.record.key);
          }
        }
      }
    }, end() {} });
  }
  close(): Promise<void> {
    if (this.closing !== undefined) return this.closing;
    this.commits.detach(); this.dirty.clear();
    // Retire the workers before draining callbacks. Queued callbacks observe
    // closure before opening an index; active effects keep their real owner.
    const queued = this.syncing;
    return this.closing = (async () => { await this.index?.close(); await queued; })();
  }
  private assertOpen(): void {
    if (this.closing !== undefined) throw new Error("History retrieval is closed");
  }
  private open(): SearchIndex { this.assertOpen(); return this.index ??= new SearchIndex(this.path); }
  private embed(call: HostCall, signal?: AbortSignal): Embed {
    return async (texts, purpose) => {
      this.assertOpen(); signal?.throwIfAborted();
      const result = await call({ type: "embed", texts, purpose });
      this.assertOpen(); signal?.throwIfAborted();
      if (result.type === "failed") throw new Error(result.message);
      if (result.type !== "embeddings") throw new Error("Embedding host returned another response type");
      return result.batch;
    };
  }
  private queue(action: () => Promise<void>): Promise<void> {
    if (this.closing !== undefined) return Promise.reject(new Error("History retrieval is closed"));
    this.pendingSyncs += 1;
    const operation = this.syncing.then(() => { this.assertOpen(); return action(); })
      .finally(() => { this.pendingSyncs -= 1; });
    this.syncing = operation.catch(() => {}); return operation;
  }
  private async *scan<T>(items: AsyncIterable<T>, signal?: AbortSignal): AsyncGenerator<T> {
    this.assertOpen(); signal?.throwIfAborted();
    for await (const item of items) {
      this.assertOpen(); signal?.throwIfAborted(); yield item;
    }
  }
  private async watermarkFor(id: string, base: string): Promise<string> {
    const sidechat = await this.sidechats?.get(id);
    if (sidechat !== undefined) {
      this.isolatedByConversation.set(id, sidechat.isolated);
      return sidechat.isolated ? `${base}:isolated` : base;
    }
    const owner = await this.tasks.findOwner(id);
    if (owner !== undefined && await this.tasks.isIsolatedTask(owner.task)) {
      return `${base}:isolated`;
    }
    return base;
  }
  private async *inventory(signal?: AbortSignal): AsyncGenerator<{ conversation_id: string; watermark: string }> {
    for await (const item of this.scan(this.histories.inventory(), signal)) {
      yield { conversation_id: item.conversation_id, watermark: await this.watermarkFor(item.conversation_id, item.watermark) };
    }
  }
  private async changed(call: HostCall, signal?: AbortSignal): Promise<void> {
    if (this.policyDirtySidechats.size > 0) {
      const changedSidechats = new Set(this.policyDirtySidechats);
      this.policyDirtySidechats.clear();
      for (const task of await this.tasks.list()) {
        if (task.delivery_conversation_id === undefined || !changedSidechats.has(task.delivery_conversation_id)) continue;
        this.policyVersion += 1;
        const marker = "policy:" + this.policyVersion.toString();
        this.dirty.set(task.conversation_id, marker);
        for (const agent of task.agents) this.dirty.set(agent.conversation_id, marker);
      }
    }
    const index = this.open(), embed = this.embed(call, signal);
    for (const [id, queued] of [...this.dirty]) {
      this.assertOpen(); signal?.throwIfAborted();
      const checkpoint = index.checkpoint(id);
      if (checkpoint?.watermark === queued && !checkpoint.dirty) {
        if (this.dirty.get(id) === queued) this.dirty.delete(id);
        continue;
      }
      const conversation = await this.tasks.conversation(id);
      const tail = await conversation.entries({ order: "descending" }, 1, undefined, BACKGROUND_CONTEXT);
      const watermark = await this.watermarkFor(id, tail.items[0]?.id.toString() ?? "empty");
      await index.upsert(id, watermark, this.scan(this.tasks.records(id), signal), embed);
      if (this.dirty.get(id) === queued || this.dirty.get(id) === watermark) this.dirty.delete(id);
    }
  }
  /** Full catchup keeps the explicit import request's host-call ownership. */
  sync(call: HostCall, all = false, signal?: AbortSignal): Promise<void> {
    return this.queue(async () => {
      signal?.throwIfAborted();
      if (!this.ready || all) {
        await this.open().reconcile(this.inventory(signal),
          (id) => this.scan(this.tasks.records(id), signal), this.embed(call, signal));
        this.ready = true;
      }
      await this.changed(call, signal);
    });
  }
  /** Automatic context must not hold user admission behind corpus catchup. */
  async snapshot(query: string, sources: string[], limit: number): Promise<SearchResult> {
    const coverage = "Automatic context includes published keyword matches and current task metadata only. Use search_tasks for semantic lookup before starting separate work when this context is insufficient.";
    try {
      const result = await this.open().search(query, undefined, sources, limit, "keyword");
      return { candidates: result.candidates, gaps: [coverage, ...result.gaps] };
    } catch (error) {
      return { candidates: [], gaps: [coverage, error instanceof Error ? error.message : "History search is unavailable"] };
    }
  }
  async search(query: string, sources: string[], limit: number, call: HostCall, importing = false, mode: SearchMode = "semantic"): Promise<SearchResult> {
    const gaps: string[] = [];
    // The durable background lane owns indexing and its host effects. A lookup
    // must not inherit arbitrary document inference or a catch-up queue.
    if (importing) gaps.push("History import and indexing are in progress");
    else if (this.pendingSyncs > 0) gaps.push("History indexing is in progress; results use the published index");
    else if (this.dirty.size > 0) gaps.push("History changes await indexing; results use the published index");
    else if (!this.ready) gaps.push("History index freshness is unverified; results use the published index");
    try {
      const result = await this.open().search(query, this.embed(call), sources, limit, mode);
      return { candidates: result.candidates, gaps: [...gaps, ...result.gaps] };
    } catch (error) { return { candidates: [], gaps: [...gaps, error instanceof Error ? error.message : "History search is unavailable"] }; }
  }
}
