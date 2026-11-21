import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { getSupportedThinkingLevels, type Api, type AuthResult, type Model, type MutableModels, type ProviderStreams } from "@earendil-works/pi-ai";
import { builtinModels, getBuiltinProviders } from "@earendil-works/pi-ai/providers/all";
import { MODEL_THINKING_LEVELS } from "@earendil-works/pi-ai/providers/model-schema";
import { AgentDoc, LiveDoc, configure, defineDoc, ProviderDoc, type AgentChange, type Conversation, type Harness, type Registry, type Tx } from "@earendil-works/pi-durable";
import { AuthError, type ChatGptAuth } from "./auth.js";
import type { ModelProvider } from "./generated/ModelProvider.js";
import type { ModelSelection } from "./generated/ModelSelection.js";
import type { Reasoning } from "./generated/Reasoning.js";
import type { WorkerHost } from "./generated/WorkerHost.js";
import type { ConversationChange } from "./generated/ConversationChange.js";
import type { ModelOption } from "./generated/ModelOption.js";
import { withWebSearch } from "./web-search.js";
import { validProvider } from "./protocol.js";
import { createCompaction, guardCompactionRequests } from "./compaction.js";

const WIRE_PROVIDERS: readonly ModelProvider[] = getBuiltinProviders().filter((id) => validProvider(id));
export const DEFAULT_MODEL: ModelSelection = { provider: "openai", model_id: "gpt-6.1-sol", reasoning: "xhigh", fast: false };
export class ModelError extends Error {}
/** Allowlisted diagnostic categories, never raw provider bodies or credentials. */
export function subscriptionSharingLimit(error: string): boolean {
  return /\bsubscription_sharing_usage_limit_exceeded\b/u.test(error) ||
    /\bChatGPT user has reached (?:their |the )?Subscription Sharing usage limit\b/iu.test(error);
}

const PROVIDER_FAILURE_MESSAGES: Record<string, string> = {
  subscription_sharing_usage_limit_exceeded:
    "The upstream app subscription-sharing usage limit was reached. Saved history is retained; changing local credentials does not reset this limit.",
  authentication_error:
    "The model provider rejected authentication (401/authentication_error). Saved history and credentials are retained.",
  rate_limit_error:
    "The model provider rate limit was reached (429/rate_limit_error). Saved history is retained.",
  context_length_exceeded:
    "The model provider rejected the context size (context_length_exceeded). Saved history is retained; this does not imply stored history is corrupt.",
};

function retainedCompactionError(error: string): string | undefined {
  // Pi's blocking-compaction task adds these exact wrappers. Its Responses
  // serializer formats bare HTTP bodies as "OpenAI API error (status): body".
  // Read only an anchored transport status, never status-like digits in a body.
  const request = error.replace(/^Compaction failed: /u, "").replace(/^Summarization failed: /u, "");
  const match = /^(?:OpenAI API error \((\d{3})\):|(\d{3})(?=[:\s]|$))/u.exec(request);
  const status = match?.[1] ?? match?.[2];
  if (subscriptionSharingLimit(error)) return "subscription_sharing_usage_limit_exceeded";
  if (status === "401" || /\bauthentication_error\b|\binvalid x-api-key\b|\binvalid_api_key\b/u.test(error)) {
    return "authentication_error";
  }
  if (status === "429" || /\brate_limit_error\b|\brate_limit_exceeded\b/u.test(error)) {
    return "rate_limit_error";
  }
  if (/\bcontext_length_exceeded\b|\bprompt is too long\b|\bmaximum context length\b/u.test(error)) {
    return "context_length_exceeded";
  }
  return undefined;
}

export function providerFailureMessage(error: string): string | undefined {
  const category = retainedCompactionError(error);
  return category === undefined ? undefined : PROVIDER_FAILURE_MESSAGES[category];
}

const SHARING_LIMIT_MESSAGE = 'ChatGPT plan usage reached a limit for this app. In Settings → Usage → App limits (https://chatgpt.com/settings/usage), review the app limit and enable "Allow other apps to use credits after reaching your usage limit" to use available credits. Its conversation is retained.';

/** Classify known provider failures without exposing their raw responses. */
export async function modelFailureMessage(conversation: Conversation, fallback: string, harness?: Harness,
  settlement?: { readonly status: string; readonly detail?: unknown }): Promise<string> {
  // Pi records blocking-compaction failures on the settled input, without
  // appending an assistant error. This receipt, not a previous generation, owns
  // the diagnosis. Unknown or missing details must not borrow older errors.
  if (settlement !== undefined) {
    if (settlement.status === "done" || typeof settlement.detail !== "string") return fallback;
    const detail = settlement.detail;
    if (/^Compaction failed:/iu.test(detail)) return "Context compaction failed: " +
      (providerFailureMessage(detail) ?? "the provider request did not complete. Saved history is retained.");
    if (subscriptionSharingLimit(detail)) return SHARING_LIMIT_MESSAGE;
    const known = providerFailureMessage(detail);
    if (known !== undefined) return known;
    if (detail.includes("web_search")) return "The provider rejected hosted web search for this model or account. Its conversation is retained.";
    return fallback;
  }
  const compaction = harness === undefined ? undefined : (await harness.snapshot(LiveDoc, conversation.id, BACKGROUND_CONTEXT))?.compactionFailure;
  const compactionMessage = compaction === undefined ? fallback : "Context compaction failed: " +
    (providerFailureMessage(compaction.error) ?? "the provider request did not complete. Saved history is retained.");
  const page = await conversation.entries({ order: "descending" }, 5, undefined, BACKGROUND_CONTEXT);
  for (const entry of page.items) for (const message of entry.model ?? []) {
    if (message.role !== "assistant") continue;
    // Pi preserves this code in HTTP error bodies and failed response streams.
    // It can mean an app-specific limit, even when the account has credits.
    if (message.stopReason === "error" && message.provider === "openai" &&
        subscriptionSharingLimit(message.errorMessage ?? "")) {
      return SHARING_LIMIT_MESSAGE;
    }
    if (message.stopReason === "error" && message.errorMessage?.includes("web_search")) {
      return "The provider rejected hosted web search for this model or account. Its conversation is retained.";
    }
    if (message.stopReason === "error") {
      // A previous failed background compaction can outlive a later generation.
      // Prefer this generation's diagnosis; only consult that failure when the
      // generation itself says compaction prevented it from running.
      return providerFailureMessage(message.errorMessage ?? "") ??
        (/compaction/iu.test(message.errorMessage ?? "") ? compactionMessage : fallback);
    }
    if (compaction !== undefined && harness !== undefined && entry.byTaskId !== undefined) {
      const [generation, failed] = await Promise.all([
        harness.getTask(entry.byTaskId, BACKGROUND_CONTEXT), harness.getTask(compaction.taskId, BACKGROUND_CONTEXT),
      ]);
      if (generation?.endedAt !== undefined && failed?.endedAt !== undefined && generation.endedAt >= failed.endedAt) return fallback;
    }
    return compactionMessage;
  }
  return compactionMessage;
}
function object(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}
function provider(value: unknown): value is ModelProvider { return WIRE_PROVIDERS.some((id) => id === value); }
function reasoning(value: unknown): value is Reasoning { return MODEL_THINKING_LEVELS.some((level) => level === value); }
function supportsFast(model: Model<Api>): boolean { return model.provider === "openai" && model.api === "openai-responses"; }

/** Request the complete exposed explanation once, before every client receives Pi's output. */
function withDetailedReasoning(native: ProviderStreams["streamSimple"]): ProviderStreams["streamSimple"] {
  return (model, context, options) => native(model, context, { ...options,
    onPayload: async (payload, actual) => {
      const previous = await options?.onPayload?.(payload, actual);
      const selected = previous === undefined ? payload : previous;
      if (!object(selected) || !object(selected.reasoning) || typeof selected.reasoning.summary !== "string") return selected;
      return { ...selected, reasoning: { ...selected.reasoning, summary: "detailed" } };
    },
  });
}

/** Old worker launch records held an OpenAI model ID. Configuration itself is strict. */
export function savedModel(value: unknown): ModelSelection | null {
  if (value === undefined || value === null) return null;
  if (typeof value === "string" && value.trim().length > 0) return { ...DEFAULT_MODEL, model_id: value, reasoning: value === DEFAULT_MODEL.model_id ? DEFAULT_MODEL.reasoning : null };
  if (object(value) && provider(value.provider) && typeof value.model_id === "string" && value.model_id.trim().length > 0 &&
      (value.reasoning === null || reasoning(value.reasoning)) && typeof value.fast === "boolean") {
    return { provider: value.provider, model_id: value.model_id, reasoning: value.reasoning, fast: value.fast };
  }
  throw new ModelError("Saved model selection is invalid; its state was retained.");
}
export function savedHost(host: WorkerHost): WorkerHost {
  return host.launch === undefined || host.launch === null ? host : {
    ...host, launch: { ...host.launch, model: savedModel(host.launch.model) },
  };
}

const Policies = defineDoc<{ sessions: Record<string, ModelSelection> }>({
  kind: "agent.models", scope: "session", version: 1, initial: () => ({ sessions: {} }), checkpointWhen: () => true,
});

const WithheldHostedToolSessions = defineDoc<{ withheld: Record<string, true> }>({
  kind: "agent.hosted_tools", scope: "session", version: 1, initial: () => ({ withheld: {} }), checkpointWhen: () => true,
});

/** Pi owns model catalogs, auth and inference. This adapter owns saved application choices. */
export class ConversationModels {
  private readonly catalogRefreshes = new Map<ModelProvider, Promise<void>>();
  private bindSession: ((session: Harness) => void) | undefined;
  private readonly session = new Promise<Harness>((resolve) => { this.bindSession = resolve; });
  private readonly compactionFailures = new Map<string, string>();
  private readonly compaction = createCompaction(this.session, this.compactionFailures, retainedCompactionError);
  private compactionGuarded = false;
  constructor(readonly models: MutableModels = builtinModels(), auth?: ChatGptAuth, registry?: Registry) {
    for (const id of ["openai", "openai-codex"]) {
      const provider = models.getProvider(id);
      if (provider !== undefined) models.setProvider({ ...provider, streamSimple: withDetailedReasoning(withWebSearch(provider.streamSimple, (sessionId) => this.hostedToolsOffered(sessionId))) });
    }
    const openai = models.getProvider("openai");
    if (openai !== undefined) {
      const nativeKey = openai.auth.apiKey;
      models.setProvider({ ...openai,
        auth: auth === undefined ? openai.auth : { ...openai.auth, apiKey: {
          name: "ChatGPT plan or OpenAI API key",
          async resolve(args) {
            const state = await auth.status();
            // A stored plan credential owns this provider, including its failures.
            if (state.state === "signed_out") {
              const native = await nativeKey?.resolve(args);
              if (native !== undefined) return native;
            }
            const credential = await auth.credential();
            return { auth: { apiKey: credential.access }, source: "ChatGPT plan" };
          },
        } },
        streamSimple: (model, context, options) => openai.streamSimple(model, context, { ...options,
          onPayload: async (payload, actual) => {
            const previous = await options?.onPayload?.(payload, actual);
            const session = await this.session;
            const policy = options?.sessionId === undefined ? undefined
              : (await session.snapshot(Policies, BACKGROUND_CONTEXT))?.sessions[options.sessionId];
            if (policy?.fast !== true) return previous;
            // A settings change can commit after this generation chose its model.
            // Its next request owns the new policy; do not alter this older one.
            if (policy.provider !== actual.provider || policy.model_id !== actual.id) return previous;
            const selected = previous ?? payload;
            if (!object(selected)) throw new ModelError("The provider returned an invalid request payload.");
            return { ...selected, service_tier: "priority" };
          },
        }),
      });
    }
    if (registry !== undefined) this.register(registry);
  }
  register(registry: Registry): void {
    registry.install(this.compaction);
    if (!this.compactionGuarded) {
      this.compactionGuarded = true;
      guardCompactionRequests(this.models, this.compactionFailures);
    }
  }
  bind(session: Harness): void { this.bindSession?.(session); this.bindSession = undefined; }
  async withholdHostedTools(conversation: Conversation): Promise<void> {
    const session = await this.session;
    await session.commit(async (tx) => {
      const native = await tx.doc(ProviderDoc, conversation.id);
      (await tx.doc(WithheldHostedToolSessions)).withheld[native.sessionId] = true;
    }, BACKGROUND_CONTEXT);
  }
  private async hostedToolsOffered(sessionId: string | undefined): Promise<boolean> {
    // Pi sends the session of every conversation request. A request without one belongs to no conversation.
    if (sessionId === undefined) return true;
    const session = await this.session;
    return (await session.snapshot(WithheldHostedToolSessions, BACKGROUND_CONTEXT))?.withheld[sessionId] !== true;
  }
  validate(selection: ModelSelection): void {
    const model = this.models.getModel(selection.provider, selection.model_id);
    if (model === undefined) throw new ModelError(`Unknown model ${selection.provider}/${selection.model_id}.`);
    if (selection.reasoning !== null && !getSupportedThinkingLevels(model).includes(selection.reasoning)) {
      throw new ModelError(`Reasoning ${selection.reasoning} is unavailable for ${selection.provider}/${selection.model_id}.`);
    }
    if (selection.fast && !supportsFast(model)) {
      throw new ModelError(`Fast mode is unavailable for ${selection.provider}/${selection.model_id}.`);
    }
  }
  async preflight(selection: ModelSelection): Promise<void> {
    if (this.models.getModel(selection.provider, selection.model_id) === undefined &&
        this.models.getProvider(selection.provider)?.refreshModels !== undefined) {
      let refresh = this.catalogRefreshes.get(selection.provider);
      if (refresh === undefined) {
        refresh = (async () => {
          const refreshed = await this.models.refresh({ providers: [selection.provider], signal: AbortSignal.timeout(15_000) });
          if (refreshed.errors.has(selection.provider)) throw new ModelError(`Could not refresh the model catalog for ${selection.provider}.`);
        })().finally(() => { this.catalogRefreshes.delete(selection.provider); });
        this.catalogRefreshes.set(selection.provider, refresh);
      }
      await refresh;
    }
    this.validate(selection);
    let credential: AuthResult | undefined;
    try { credential = await this.models.getAuth(selection.provider); }
    catch (error) {
      // Models wraps provider-auth errors; preserve the application's safe,
      // actionable failure without exposing native token/transport diagnostics.
      if (error instanceof Error && error.cause instanceof AuthError) throw error.cause;
      throw new AuthError("refresh", `Could not resolve authentication for ${selection.provider}; saved credentials were retained.`);
    }
    if (credential === undefined) {
      throw new AuthError("needs_sign_in", `No authentication configured for ${selection.provider}. Configure its Pi authentication in the coordinator environment.`);
    }
  }
  async configure(conversation: Conversation, selection: ModelSelection, change: AgentChange): Promise<void> {
    this.validate(selection);
    const session = await this.session;
    await session.commit((tx) => this.configureIn(tx, conversation, selection, change), BACKGROUND_CONTEXT);
  }
  private async configureIn(tx: Tx, conversation: Conversation, selection: ModelSelection, change: AgentChange): Promise<void> {
    const native = await tx.doc(ProviderDoc, conversation.id);
    const policies = await tx.doc(Policies);
    policies.sessions[native.sessionId] = { ...selection };
    await configure(tx, conversation.id, { ...change, model: { provider: selection.provider, modelId: selection.model_id },
      thinkingLevel: selection.reasoning });
    // Keep explicit tool/extension selections while adding the internal policy.
    const agent = await tx.doc(AgentDoc, conversation.id), extensions = agent.extensions;
    if (Array.isArray(extensions)) {
      if (!extensions.includes(this.compaction.name)) extensions.push(this.compaction.name);
    } else agent.extensions = { ...extensions, add: [...new Set([...(extensions?.add ?? []), this.compaction.name])] };
  }
  private async currentIn(tx: Tx, conversation: Conversation, fallback: ModelSelection): Promise<ModelSelection> {
    const native = await tx.doc(AgentDoc, conversation.id);
    if (native.model === undefined) return { ...fallback };
    if (!provider(native.model.provider)) throw new ModelError("The saved provider is unavailable; its conversation was retained.");
    const connection = await tx.doc(ProviderDoc, conversation.id);
    const saved = (await tx.doc(Policies)).sessions[connection.sessionId];
    return { provider: native.model.provider, model_id: native.model.modelId, reasoning: native.thinkingLevel ?? null,
      fast: saved?.provider === native.model.provider && saved.model_id === native.model.modelId && saved.fast };
  }
  /** Startup context must not overwrite a setting changed while it was loading. */
  async configureCurrent(conversation: Conversation, fallback: ModelSelection, change: AgentChange): Promise<ModelSelection> {
    const session = await this.session;
    return session.commit(async (tx) => {
      const selected = await this.currentIn(tx, conversation, fallback); this.validate(selected);
      await this.configureIn(tx, conversation, selected, change); return selected;
    }, BACKGROUND_CONTEXT);
  }
  catalog(): ModelOption[] {
    return this.models.getModels().flatMap((model) => provider(model.provider) ? [{ provider: model.provider, model_id: model.id,
      name: model.name, reasoning: [...getSupportedThinkingLevels(model)], fast: supportsFast(model) }] : [])
      .sort((left, right) => left.provider.localeCompare(right.provider) || left.model_id.localeCompare(right.model_id));
  }
  private changed(current: ModelSelection, change: ConversationChange): ModelSelection {
    if (change.type === "set_selection") return { ...change.model };
    if (change.type === "set_fast") return { ...current, fast: change.mode === "toggle" ? !current.fast : change.mode === "on" };
    if (change.type === "set_reasoning") return { ...current, reasoning: change.reasoning };
    const provider = change.provider ?? current.provider;
    const model = this.models.getModel(provider, change.model_id);
    return { provider, model_id: change.model_id,
      reasoning: model !== undefined && current.reasoning !== null && getSupportedThinkingLevels(model).includes(current.reasoning) ? current.reasoning : null,
      fast: model !== undefined && supportsFast(model) && current.fast };
  }
  /** Native configuration and application actor metadata share the Pi commit. */
  async edit(conversation: Conversation, fallback: ModelSelection, change: ConversationChange | null,
    save?: (tx: Tx, selected: ModelSelection) => Promise<void>): Promise<ModelSelection> {
    const session = await this.session;
    const current = await this.legacy(conversation, fallback);
    if (change === null) return current;
    const resolved = change.type === "set_model" ? { ...change, provider: change.provider ?? current.provider } : change;
    if (resolved.type === "set_model" || resolved.type === "set_selection") await this.preflight(this.changed(current, resolved));
    return session.commit(async (tx) => {
      const current = await this.currentIn(tx, conversation, fallback);
      const selected = this.changed(current, resolved); this.validate(selected);
      await this.configureIn(tx, conversation, selected, {});
      await save?.(tx, selected); return selected;
    }, BACKGROUND_CONTEXT);
  }
  async legacy(conversation: Conversation, fallback: ModelSelection): Promise<ModelSelection> {
    const session = await this.session;
    return session.commit((tx) => this.currentIn(tx, conversation, fallback), BACKGROUND_CONTEXT);
  }
  /** Presentation must not create native provider or configuration documents. */
  async peek(conversation: Conversation, fallback: ModelSelection): Promise<ModelSelection> {
    const session = await this.session;
    const native = await session.snapshot(AgentDoc, conversation.id, BACKGROUND_CONTEXT);
    if (native?.model === undefined) return { ...fallback };
    if (!provider(native.model.provider)) throw new ModelError("The saved provider is unavailable; its conversation was retained.");
    const connection = await session.snapshot(ProviderDoc, conversation.id, BACKGROUND_CONTEXT);
    const policy = connection === undefined ? undefined
      : (await session.snapshot(Policies, BACKGROUND_CONTEXT))?.sessions[connection.sessionId];
    return { provider: native.model.provider, model_id: native.model.modelId, reasoning: native.thinkingLevel ?? null,
      fast: policy?.provider === native.model.provider && policy.model_id === native.model.modelId && policy.fast };
  }
}
