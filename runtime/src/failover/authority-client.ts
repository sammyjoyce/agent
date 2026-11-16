import { AuthorityUnreachable, type AuthorityLink } from "./authority-link.js";
import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { LogPage } from "../generated/LogPage.js";

/** The authority refused the credential: 401 for an unknown token, 403 for one that may not do this. */
export class AuthorityDenied extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

/** The authority refused the request itself, such as a malformed command, an oversized body, or a blob it does not hold (404). */
export class AuthorityRejected extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

export interface AuthorityClientOptions {
  readonly url: string;
  readonly coordinatorId: string;
  readonly token: string;
  /** Bounds each request, its body included. */
  readonly timeoutMs?: number;
}

/**
 * The authority Worker over HTTP. It never retries: only the caller knows
 * whether repeating a request is safe.
 */
export class AuthorityClient implements AuthorityLink {
  private readonly base: string;
  private readonly token: string;
  private readonly timeoutMs: number;

  constructor({ url, coordinatorId, token, timeoutMs = 30_000 }: AuthorityClientOptions) {
    this.base = `${url.replace(/\/+$/, "")}/v1/coordinators/${coordinatorId}`;
    this.token = token;
    this.timeoutMs = timeoutMs;
  }

  async command(command: AuthorityCommand): Promise<AuthorityReply> {
    return json(await this.exchange("POST", "commands", JSON.stringify(command)));
  }

  async record(): Promise<AuthorityRecord | undefined> {
    try {
      return json(await this.exchange("GET", "record"));
    } catch (error) {
      if (error instanceof AuthorityRejected && error.status === 404) return undefined;
      throw error;
    }
  }

  async log(after: number, limit: number): Promise<LogPage> {
    return json(await this.exchange("GET", `log?after=${after}&limit=${limit}`));
  }

  async putBlob(sha256: string, bytes: Uint8Array): Promise<void> {
    await this.exchange("PUT", `blobs/${sha256}`, bytes);
  }

  async getBlob(sha256: string): Promise<Uint8Array> {
    return this.exchange("GET", `blobs/${sha256}`);
  }

  private async exchange(method: string, path: string, body: string | Uint8Array | null = null): Promise<Uint8Array> {
    const request = `${method} ${path.split("?")[0]}`;
    let status: number, bytes: Uint8Array;
    try {
      const response = await fetch(`${this.base}/${path}`, {
        method, body, redirect: "error", signal: AbortSignal.timeout(this.timeoutMs),
        headers: { authorization: `Bearer ${this.token}` },
      });
      status = response.status;
      bytes = new Uint8Array(await response.arrayBuffer());
    } catch (error) {
      throw new AuthorityUnreachable(`The authority did not answer ${request}: ${error instanceof Error ? error.message : String(error)}.`, { cause: error });
    }
    if (status < 300) return bytes;
    const sentence = errorSentence(bytes) ?? `The authority answered ${request} with HTTP ${status}.`;
    if (status >= 500) throw new AuthorityUnreachable(sentence);
    if (status === 401 || status === 403) throw new AuthorityDenied(status, sentence);
    throw new AuthorityRejected(status, sentence);
  }
}

function json<T>(bytes: Uint8Array): T {
  try {
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  } catch (error) {
    throw new AuthorityUnreachable("The authority answered with a body that is not JSON, so something else answered at its address.", { cause: error });
  }
}

function errorSentence(bytes: Uint8Array): string | undefined {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    return typeof value === "object" && value !== null && "error" in value && typeof value.error === "string" ? value.error : undefined;
  } catch {
    return undefined;
  }
}
