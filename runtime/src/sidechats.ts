import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { Type } from "typebox";
import {
  defineExtension,
  defineTool,
  ROOT_CONVERSATION_ID,
  type ConversationId,
  type Extension,
  type Harness,
  type Tx,
} from "@earendil-works/pi-durable";
import type { ReplyReference } from "./generated/ReplyReference.js";
import type { SavedConversation } from "./generated/SavedConversation.js";
import type { SidechatNotificationPreference } from "./generated/SidechatNotificationPreference.js";
import type { SidechatSummary } from "./generated/SidechatSummary.js";
import {
  SIDECHAT_CHARTER_MAX_BYTES,
  SIDECHAT_HANDOFF_MAX_BYTES,
  SIDECHAT_SEED_EXCERPT_MAX_BYTES,
  SIDECHAT_SLUG_MAX_BYTES,
  SIDECHAT_TITLE_MAX_BYTES,
} from "./generated/sidechat-limits.js";
import { PartitionedRecords } from "./partitioned-records.js";
import { nativeConversationId, publishConversationNotice, TaskError, type TaskStore } from "./tasks.js";
import { SidechatSeedEntry } from "./transcript.js";
import type { Executions } from "./tools.js";
import { output } from "./host-output.js";

export {
  SIDECHAT_CHARTER_MAX_BYTES,
  SIDECHAT_HANDOFF_MAX_BYTES,
  SIDECHAT_SEED_EXCERPT_MAX_BYTES,
  SIDECHAT_SLUG_MAX_BYTES,
  SIDECHAT_TITLE_MAX_BYTES,
};
const SLUG_PATTERN = /^[a-z0-9][a-z0-9_-]*$/;
const PURELY_NUMERIC = /^[0-9]+$/;
// Allow U+200C (ZWNJ), U+200D (ZWJ), and ordinary direction marks (U+200E, U+200F, U+061C)
// for joined emoji and natural multilingual titles; block controls, spoofing bidi overrides/isolates, and invisible separators.
const UNSAFE_TITLE_CHARS = /[\p{Cc}\u200B\u2028-\u202E\u2060-\u206F\uFEFF]/u;
// Reject C0/C1 controls other than ordinary whitespace (\t, \n, \r, \f) and bidi overrides/embeddings.
const UNSAFE_MULTILINE_CHARS = /[\u0000-\u0008\u000B\u000E-\u001F\u007F-\u009F\u202A-\u202E]/u;
const UNSAFE_MULTILINE_CHARS_GLOBAL = /[\u0000-\u0008\u000B\u000E-\u001F\u007F-\u009F\u202A-\u202E]/gu;
const WHITESPACE_OR_CONTROL = /[\s\p{Cc}]/u;

function asciiLowercase(value: string): string {
  return value.replace(/[A-Z]/g, (ch) => ch.toLowerCase());
}

export type CreateSidechatInput = {
  title: string;
  slug?: string;
  charter?: string;
  isolated?: boolean;
  notifications?: SidechatNotificationPreference;
  seed?: ReplyReference;
  handoff?: string;
};

export type UpdateSidechatInput = {
  conversation_id: string;
  title?: string;
  slug?: string;
  pinned?: boolean;
  archived?: boolean;
  charter?: string;
  clear_charter?: boolean;
  isolated?: boolean;
  notifications?: SidechatNotificationPreference;
};

function validateTitle(raw: string): string {
  const title = raw.trim();
  if (title.length === 0) throw new TaskError("Side chat title cannot be empty.");
  if (UNSAFE_TITLE_CHARS.test(title)) {
    throw new TaskError("Side chat title cannot contain control or formatting characters.");
  }
  if (Buffer.byteLength(title) > SIDECHAT_TITLE_MAX_BYTES) {
    throw new TaskError(`Side chat title must be at most ${SIDECHAT_TITLE_MAX_BYTES} UTF-8 bytes.`);
  }
  return title;
}

function validateSlug(raw: string): string {
  const slug = asciiLowercase(raw.trim());
  if (slug.length === 0) throw new TaskError("Side chat slug cannot be empty.");
  if (Buffer.byteLength(slug) > SIDECHAT_SLUG_MAX_BYTES || !SLUG_PATTERN.test(slug)) {
    throw new TaskError("Side chat slug must be lowercase ASCII letters, digits, hyphens or underscores (at most 64 bytes).");
  }
  if (PURELY_NUMERIC.test(slug)) {
    throw new TaskError("Side chat slug cannot be purely numeric.");
  }
  return slug;
}

function validateCharter(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined;
  const trimmed = raw.trim();
  if (UNSAFE_MULTILINE_CHARS.test(trimmed)) {
    throw new TaskError("Side chat charter cannot contain control or directional override characters.");
  }
  if (Buffer.byteLength(trimmed) > SIDECHAT_CHARTER_MAX_BYTES) {
    throw new TaskError(`Side chat charter must be at most ${SIDECHAT_CHARTER_MAX_BYTES} UTF-8 bytes.`);
  }
  return trimmed.length === 0 ? undefined : trimmed;
}

function validateHandoff(raw: string | undefined): string | undefined {
  if (raw === undefined) return undefined;
  const trimmed = raw.trim();
  if (UNSAFE_MULTILINE_CHARS.test(trimmed)) {
    throw new TaskError("Side chat handoff cannot contain control or directional override characters.");
  }
  if (Buffer.byteLength(trimmed) > SIDECHAT_HANDOFF_MAX_BYTES) {
    throw new TaskError(`Side chat handoff must be at most ${SIDECHAT_HANDOFF_MAX_BYTES} UTF-8 bytes.`);
  }
  return trimmed.length === 0 ? undefined : trimmed;
}

function validateSeed(seed: ReplyReference | undefined): ReplyReference | undefined {
  if (seed === undefined) return undefined;
  const entryId = seed.entry_id.trim();
  if (entryId.length === 0 || Buffer.byteLength(entryId) > 128 || WHITESPACE_OR_CONTROL.test(entryId)) {
    throw new TaskError("Seed message reference needs a valid entry_id.");
  }
  // Seed excerpts come from existing chat messages that clients cannot edit in-place;
  // sanitize unsafe control and directional override characters rather than rejecting.
  const excerpt = seed.excerpt.replace(UNSAFE_MULTILINE_CHARS_GLOBAL, "").trim();
  if (Buffer.byteLength(excerpt) > SIDECHAT_SEED_EXCERPT_MAX_BYTES) {
    throw new TaskError(`Seed message excerpt must be at most ${SIDECHAT_SEED_EXCERPT_MAX_BYTES} UTF-8 bytes.`);
  }
  return { entry_id: entryId, role: seed.role, excerpt };
}

export function slugifyTitle(title: string): string {
  const normalized = title
    .normalize("NFKC")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  const rawBase = normalized.length === 0 ? "topic" : normalized.slice(0, 56).replace(/-+$/g, "");
  const base = rawBase.length === 0 ? "topic" : rawBase;
  return PURELY_NUMERIC.test(base) ? `topic-${base}`.slice(0, 56) : base;
}

function cloneSummary(value: SidechatSummary): SidechatSummary {
  return {
    conversation_id: value.conversation_id,
    slug: value.slug,
    title: value.title,
    pinned: value.pinned,
    ...(value.archived_at === undefined ? {} : { archived_at: value.archived_at }),
    ...(value.charter === undefined ? {} : { charter: value.charter }),
    isolated: value.isolated,
    notifications: value.notifications,
    ...(value.seed === undefined ? {} : { seed: { ...value.seed } }),
    created_at: value.created_at,
    updated_at: value.updated_at,
  };
}

function sortSidechats(items: SidechatSummary[]): SidechatSummary[] {
  return items.sort(
    (left, right) =>
      Number(right.pinned) - Number(left.pinned) ||
      right.updated_at - left.updated_at ||
      right.conversation_id.localeCompare(left.conversation_id),
  );
}

const sidechatRecords = new PartitionedRecords<SidechatSummary>("agent.sidechat");
export const SIDECHAT_RECORDS_KIND = sidechatRecords.records.definition.kind;

/** Durable standing topic side chats stored alongside Pi's native conversations. */
export class SidechatStore {
  private readonly records = sidechatRecords;
  constructor(private readonly session: Harness) {}

  private async allocateSlugIn(tx: Tx, requested: string | undefined, title: string, excludeId?: string): Promise<string> {
    const taken = new Set<string>();
    for await (const existing of this.records.valuesIn(tx)) {
      if (existing.conversation_id !== excludeId) taken.add(existing.slug.toLowerCase());
    }
    if (requested !== undefined) {
      const slug = validateSlug(requested);
      if (taken.has(slug)) throw new TaskError(`A side chat with slug "${slug}" already exists.`);
      return slug;
    }
    const base = slugifyTitle(title);
    if (!taken.has(base)) return base;
    for (let suffix = 2; suffix < 10_000; suffix += 1) {
      const tag = `-${suffix}`;
      const candidate = `${base.slice(0, SIDECHAT_SLUG_MAX_BYTES - tag.length)}${tag}`;
      if (!taken.has(candidate)) return candidate;
    }
    throw new TaskError("Could not allocate a unique side chat slug.");
  }

  async getIn(tx: Tx, conversationId: string): Promise<SidechatSummary | undefined> {
    const record = await this.records.valueIn(tx, conversationId);
    return record === undefined ? undefined : cloneSummary(record);
  }

  async listIn(tx: Tx, includeArchived = true): Promise<SidechatSummary[]> {
    const items: SidechatSummary[] = [];
    for await (const record of this.records.valuesIn(tx)) {
      if (includeArchived || record.archived_at === undefined) items.push(cloneSummary(record));
    }
    return sortSidechats(items);
  }

  async get(conversationId: string): Promise<SidechatSummary | undefined> {
    const record = await this.records.get(this.session, conversationId);
    return record === undefined ? undefined : cloneSummary(record);
  }

  async resolve(slugOrConversationId: string): Promise<SidechatSummary | undefined> {
    const target = slugOrConversationId.trim();
    if (target.length === 0) return undefined;
    const direct = await this.get(target);
    if (direct !== undefined) return direct;
    const wanted = target.toLowerCase();
    for await (const record of this.records.values(this.session)) {
      if (record.slug.toLowerCase() === wanted) return cloneSummary(record);
    }
    return undefined;
  }

  async require(slugOrConversationId: string): Promise<SidechatSummary> {
    const found = await this.resolve(slugOrConversationId);
    if (found === undefined) throw new TaskError("Unknown side chat.");
    return found;
  }

  async list(includeArchived = false): Promise<SidechatSummary[]> {
    const items: SidechatSummary[] = [];
    for await (const record of this.records.values(this.session)) {
      if (includeArchived || record.archived_at === undefined) items.push(cloneSummary(record));
    }
    return sortSidechats(items);
  }

  async create(input: CreateSidechatInput): Promise<SidechatSummary> {
    const title = validateTitle(input.title);
    const charter = validateCharter(input.charter);
    const handoff = validateHandoff(input.handoff);
    const seed = validateSeed(input.seed);
    const notifications: SidechatNotificationPreference = input.notifications ?? "inherit";
    const isolated = input.isolated === true;

    const createdId = await this.session.commit(async (tx) => {
      const slug = await this.allocateSlugIn(tx, input.slug, title);
      // Standing side chats are always fresh ownerless conversations, never Pi forks.
      const conversation = await tx.createConversation({ ownership: { kind: "ownerless" } });
      const now = Date.now();
      const summary: SidechatSummary = {
        conversation_id: conversation.id.toString(),
        slug,
        title,
        pinned: false,
        isolated,
        notifications,
        created_at: now,
        updated_at: now,
        ...(charter === undefined ? {} : { charter }),
        ...(seed === undefined ? {} : { seed }),
      };
      await this.records.insertIn(tx, summary.conversation_id, summary);
      const seedParts: string[] = [];
      if (seed !== undefined) {
        const quoted = seed.excerpt.length > 0 ? `\n> ${seed.excerpt.replaceAll("\n", "\n> ")}` : "";
        seedParts.push(`Started from ${seed.role} message (${seed.entry_id}):${quoted}`);
      }
      if (handoff !== undefined) seedParts.push(handoff);
      if (seedParts.length > 0) {
        const seedText = seedParts.join("\n\n");
        await tx.appendEntry(conversation.id, {
          kind: SidechatSeedEntry.kind,
          data: { text: seedText, ...(seed === undefined ? {} : { seed }) },
          model: [{ role: "user", content: [{ type: "text", text: `[Side chat context]\n${seedText}` }], timestamp: now }],
        });
      }
      return summary.conversation_id;
    }, BACKGROUND_CONTEXT);

    const saved = await this.get(createdId);
    if (saved === undefined) throw new TaskError("Created side chat could not be read.");
    return saved;
  }

  async update(input: UpdateSidechatInput): Promise<SidechatSummary> {
    if (input.charter !== undefined && input.clear_charter === true) {
      throw new TaskError("Choose either charter text or clear_charter, not both.");
    }
    const target = await this.require(input.conversation_id);
    const nextTitle = input.title === undefined ? undefined : validateTitle(input.title);
    const nextCharter = input.charter === undefined ? undefined : validateCharter(input.charter);

    await this.session.commit(async (tx) => {
      const record = await this.records.valueIn(tx, target.conversation_id);
      if (record === undefined) throw new TaskError("Unknown side chat.");
      if (nextTitle !== undefined) record.title = nextTitle;
      if (input.slug !== undefined) {
        record.slug = await this.allocateSlugIn(tx, input.slug, record.title, target.conversation_id);
      }
      if (input.pinned !== undefined) record.pinned = input.pinned;
      if (input.archived !== undefined) {
        if (input.archived) record.archived_at ??= Date.now();
        else delete record.archived_at;
      }
      if (input.clear_charter === true) {
        delete record.charter;
      } else if (input.charter !== undefined) {
        if (nextCharter === undefined) delete record.charter;
        else record.charter = nextCharter;
      }
      if (input.isolated !== undefined) record.isolated = input.isolated;
      if (input.notifications !== undefined) record.notifications = input.notifications;
      record.updated_at = Date.now();
    }, BACKGROUND_CONTEXT);

    const updated = await this.get(target.conversation_id);
    if (updated === undefined) throw new TaskError("Updated side chat could not be read.");
    return updated;
  }

  async unarchiveIfNeeded(conversationId: string): Promise<SidechatSummary | undefined> {
    const existing = await this.get(conversationId);
    if (existing === undefined) return undefined;
    if (existing.archived_at === undefined) return existing;
    await this.session.commit(async (tx) => {
      const record = await this.records.valueIn(tx, conversationId);
      if (record === undefined) return;
      if (record.archived_at !== undefined) {
        delete record.archived_at;
        record.updated_at = Date.now();
      }
    }, BACKGROUND_CONTEXT);
    return this.get(conversationId);
  }

  async touchUpdatedAt(conversationId: string): Promise<void> {
    await this.session.commit(async (tx) => {
      const record = await this.records.valueIn(tx, conversationId);
      if (record === undefined) return;
      record.updated_at = Date.now();
    }, BACKGROUND_CONTEXT);
  }

  savedConversation(summary: SidechatSummary): SavedConversation {
    return {
      conversation_id: summary.conversation_id,
      title: summary.title,
      updated_at: summary.updated_at,
      source_thread_id: null,
      task_id: null,
      agent_id: null,
      host: null,
    };
  }
}

export function sidechatInstructions(summary: SidechatSummary): string {
  const lines = [
    `Standing topic side chat: "${summary.title}" (slug: ${summary.slug}, conversation_id: ${summary.conversation_id}).`,
    summary.isolated
      ? "Isolation: this side chat is walled off from cross-chat retrieval. Keep topic notes here; Main and other chats will not find them via search."
      : "Shared memory: facts and work recorded here are searchable from Main and other chats without mixing transcripts.",
    "Keep topic updates, follow-ups, and delegated task notices in this side chat. Escalate to the Main chat (notify_user with escalate_to_main: true) only when the owner needs to make a decision, take action, or see an urgent alert.",
  ];
  if (summary.charter !== undefined && summary.charter.trim().length > 0) {
    lines.push(`Topic charter:\n${summary.charter.trim()}`);
  }
  return lines.join("\n\n");
}

const notificationPrefs = { inherit: "inherit", on: "on", off: "off" } satisfies Record<
  SidechatNotificationPreference,
  SidechatNotificationPreference
>;

export function createSidechatTools(
  sidechats: SidechatStore,
  tasks: TaskStore,
  harness: Harness,
  executions: Executions,
): Extension {
  function requireCoordinator(id: string): void {
    if (!executions.isCoordinator(id)) {
      throw new TaskError("Side chat management belongs to the coordinator.");
    }
  }

  return defineExtension({
    name: "sidechat-tools",
    tools: [
      defineTool({
        name: "list_sidechats",
        replay: "safe",
        description: "List standing topic side chats (pinned first, then recently updated), including slug, title, charter, isolation, and notification settings.",
        parameters: Type.Object({
          include_archived: Type.Optional(Type.Boolean()),
        }),
        async execute(args, api) {
          requireCoordinator(api.conversationId.toString());
          return output(await sidechats.list(args.include_archived === true));
        },
      }),
      defineTool({
        name: "create_sidechat",
        description: "Create a standing topic side chat with its own fresh conversation (never forked from Main) and optional charter, isolation, notification override, and handoff summary.",
        parameters: Type.Object({
          title: Type.String({ minLength: 1, maxLength: SIDECHAT_TITLE_MAX_BYTES }),
          slug: Type.Optional(Type.String({ minLength: 1, maxLength: SIDECHAT_SLUG_MAX_BYTES })),
          charter: Type.Optional(Type.String({ maxLength: SIDECHAT_CHARTER_MAX_BYTES })),
          isolated: Type.Optional(Type.Boolean()),
          notifications: Type.Optional(Type.Enum(notificationPrefs)),
          handoff: Type.Optional(Type.String({ maxLength: SIDECHAT_HANDOFF_MAX_BYTES })),
        }),
        async execute(args, api) {
          requireCoordinator(api.conversationId.toString());
          const created = await sidechats.create({
            title: args.title,
            ...(args.slug === undefined ? {} : { slug: args.slug }),
            ...(args.charter === undefined ? {} : { charter: args.charter }),
            ...(args.isolated === undefined ? {} : { isolated: args.isolated }),
            ...(args.notifications === undefined ? {} : { notifications: args.notifications }),
            ...(args.handoff === undefined ? {} : { handoff: args.handoff }),
          });
          return output(created);
        },
      }),
      defineTool({
        name: "update_sidechat",
        description: "Update a standing side chat's title, slug, pin state, archive state, topic charter, retrieval isolation, or push notification preference.",
        parameters: Type.Object({
          sidechat: Type.String({ minLength: 1, description: "Side chat slug or conversation_id." }),
          title: Type.Optional(Type.String({ minLength: 1, maxLength: SIDECHAT_TITLE_MAX_BYTES })),
          slug: Type.Optional(Type.String({ minLength: 1, maxLength: SIDECHAT_SLUG_MAX_BYTES })),
          pinned: Type.Optional(Type.Boolean()),
          archived: Type.Optional(Type.Boolean()),
          charter: Type.Optional(Type.String({ maxLength: SIDECHAT_CHARTER_MAX_BYTES })),
          clear_charter: Type.Optional(Type.Boolean()),
          isolated: Type.Optional(Type.Boolean()),
          notifications: Type.Optional(Type.Enum(notificationPrefs)),
        }),
        async execute(args, api) {
          requireCoordinator(api.conversationId.toString());
          const updated = await sidechats.update({
            conversation_id: args.sidechat,
            ...(args.title === undefined ? {} : { title: args.title }),
            ...(args.slug === undefined ? {} : { slug: args.slug }),
            ...(args.pinned === undefined ? {} : { pinned: args.pinned }),
            ...(args.archived === undefined ? {} : { archived: args.archived }),
            ...(args.charter === undefined ? {} : { charter: args.charter }),
            ...(args.clear_charter === undefined ? {} : { clear_charter: args.clear_charter }),
            ...(args.isolated === undefined ? {} : { isolated: args.isolated }),
            ...(args.notifications === undefined ? {} : { notifications: args.notifications }),
          });
          return output(updated);
        },
      }),
      defineTool({
        name: "post_to_sidechat",
        description: "Post a durable update or filed note into a standing side chat by slug or conversation_id. Automatically unarchives the side chat if archived.",
        parameters: Type.Object({
          sidechat: Type.String({ minLength: 1, description: "Target side chat slug or conversation_id." }),
          text: Type.String({ minLength: 1, maxLength: 16_000 }),
          task_id: Type.Optional(Type.String({ minLength: 1 })),
        }),
        async execute(args, api) {
          const sourceId = api.conversationId.toString();
          requireCoordinator(sourceId);
          const text = args.text.trim();
          if (text.length === 0) throw new TaskError("A side chat post needs non-empty text.");
          const target = await sidechats.require(args.sidechat);
          if (target.conversation_id === sourceId) {
            throw new TaskError("You are already in this side chat; reply directly instead.");
          }
          const task = args.task_id === undefined ? undefined : await tasks.get(args.task_id);
          await sidechats.unarchiveIfNeeded(target.conversation_id);
          const sourceConversation = await tasks.conversation(sourceId);
          const origin = await tasks.origin(sourceConversation, api.callId);
          const lineage = await tasks.noticeOrigin(sourceConversation, origin.id);
          const targetNativeId: ConversationId = target.conversation_id === ROOT_CONVERSATION_ID.toString()
            ? ROOT_CONVERSATION_ID
            : nativeConversationId(target.conversation_id);
          const publication = await publishConversationNotice(
            harness,
            targetNativeId,
            sourceConversation,
            origin,
            task?.id ?? null,
            [],
            {
              key: api.callId,
              text,
              events: [],
              ...(task === undefined ? {} : { taskTitle: task.title }),
              ...(lineage === undefined ? {} : { origin: lineage }),
            },
          );
          await sidechats.touchUpdatedAt(target.conversation_id);
          const latest = (await sidechats.get(target.conversation_id)) ?? target;
          return output({ sidechat: latest, publication });
        },
      }),
    ],
  });
}
