import type { AuthorityReply } from "../generated/AuthorityReply.js";
import { untilReachable, type AuthorityLink } from "./authority-link.js";
import { OwnerFenced } from "./replicated-storage.js";

/** What an owner asks before it starts an effect outside its own state. */
export interface OwnerGate {
  /**
   * Resolves once the authority has answered, as to the current owner, an
   * exchange that started after this call. It waits while the authority is
   * unreachable. It rejects with `OwnerFenced` when the authority refuses this
   * owner, and with another error when `signal` aborts.
   */
  fresh(signal?: AbortSignal): Promise<void>;
}

export interface ConfirmGateOptions {
  readonly link: AuthorityLink;
  readonly holder: string;
  readonly epoch: number;
  /** Called once, where the refusal is read, before any waiter is rejected. */
  readonly onFenced: (error: OwnerFenced) => void;
}

interface Waiter {
  readonly resolve: () => void;
  readonly reject: (error: unknown) => void;
}

/**
 * A gate that sends one `confirm` per round. A round serves the callers that
 * asked before it started, so a caller never shares a `confirm` that was
 * already in flight when it asked.
 */
export class ConfirmGate implements OwnerGate {
  readonly #options: ConfirmGateOptions;
  #waiting = new Set<Waiter>();
  /** Ends the round in flight once none of its callers still waits. */
  #abandon: (() => void) | undefined;
  #running = false;
  #fenced: OwnerFenced | undefined;

  constructor(options: ConfirmGateOptions) { this.#options = options; }

  fresh(signal?: AbortSignal): Promise<void> {
    if (this.#fenced !== undefined) return Promise.reject(this.#fenced);
    if (signal?.aborted) return Promise.reject(stopped(signal));
    return new Promise<void>((resolve, reject) => {
      const aborted = () => {
        this.#waiting.delete(waiter);
        reject(stopped(signal));
        this.#abandon?.();
      };
      const settle = () => { this.#waiting.delete(waiter); signal?.removeEventListener("abort", aborted); };
      const waiter: Waiter = {
        resolve: () => { settle(); resolve(); },
        reject: (error) => { settle(); reject(error); },
      };
      this.#waiting.add(waiter);
      signal?.addEventListener("abort", aborted, { once: true });
      void this.#run();
    });
  }

  async #run(): Promise<void> {
    if (this.#running) return;
    this.#running = true;
    try {
      while (this.#waiting.size > 0) {
        const served = [...this.#waiting];
        const abandoned = new AbortController();
        this.#abandon = () => { if (served.every((waiter) => !this.#waiting.has(waiter))) abandoned.abort(); };
        let reply: AuthorityReply;
        try {
          reply = await this.#confirm(abandoned.signal);
        } catch (error) {
          for (const waiter of served) waiter.reject(error);
          continue;
        } finally {
          this.#abandon = undefined;
        }
        if (reply.result === "accepted") {
          for (const waiter of served) waiter.resolve();
        } else if (reply.reason === "sealed" || reply.reason === "fenced") {
          this.#fenced = new OwnerFenced(reply.reason, reply.state);
          this.#options.onFenced(this.#fenced);
          for (const waiter of [...this.#waiting]) waiter.reject(this.#fenced);
        } else {
          const refused = new Error(`The authority refused the owner check as ${reply.reason}`);
          for (const waiter of served) waiter.reject(refused);
        }
      }
    } finally {
      this.#running = false;
    }
  }

  /** `confirm` writes nothing, so repeating it after a lost exchange is safe. */
  #confirm(signal: AbortSignal): Promise<AuthorityReply> {
    const { link, holder, epoch } = this.#options;
    return untilReachable(() => link.command({ op: "confirm", holder, epoch }), signal);
  }
}

function stopped(signal: AbortSignal | undefined): Error {
  return new Error("Stopped waiting for the authority to confirm this owner", { cause: signal?.reason });
}
