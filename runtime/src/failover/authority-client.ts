import { AuthorityUnreachable, type AuthorityLink } from "./authority-link.js";
import { parseAuthorityRecord, parseAuthorityReply, parseLogPage } from "./authority-wire.js";
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

/**
 * The authority answered with a body that is not the answer the request
 * expects, so something else answered at its address or it runs another
 * version. Repeating the request does not help.
 */
export class AuthorityProtocolError extends Error {}

export interface AuthorityClientOptions {
  readonly url: string;
  readonly coordinatorId: string;
  readonly token: string;
  /** Bounds each request, its body included. */
  readonly timeoutMs?: number;
  /** An abort cuts every request in flight, which then rejects as `AuthorityUnreachable`. */
  readonly signal?: AbortSignal;
}

/**
 * The authority Worker over HTTP. It never retries: only the caller knows
 * whether repeating a request is safe.
 */
export class AuthorityClient implements AuthorityLink {
  private readonly base: string;
  private readonly token: string;
  private readonly timeoutMs: number;
  private readonly signal: AbortSignal | undefined;

  constructor({ url, coordinatorId, token, timeoutMs = 30_000, signal }: AuthorityClientOptions) {
    this.base = `${url.replace(/\/+$/, "")}/v1/coordinators/${coordinatorId}`;
    this.token = token;
    this.timeoutMs = timeoutMs;
    this.signal = signal;
  }

  command(command: AuthorityCommand): Promise<AuthorityReply> {
    return this.answer("POST", "commands", parseAuthorityReply, JSON.stringify(command));
  }

  async record(): Promise<AuthorityRecord | undefined> {
    try {
      return await this.answer("GET", "record", parseAuthorityRecord);
    } catch (error) {
      if (error instanceof AuthorityRejected && error.status === 404) return undefined;
      throw error;
    }
  }

  log(after: number, limit: number): Promise<LogPage> {
    return this.answer("GET", `log?after=${after}&limit=${limit}`, parseLogPage);
  }

  async putBlob(sha256: string, bytes: Uint8Array): Promise<void> {
    await this.exchange("PUT", `blobs/${sha256}`, bytes);
  }

  async getBlob(sha256: string): Promise<Uint8Array> {
    return this.exchange("GET", `blobs/${sha256}`);
  }

  private async answer<T>(method: string, path: string, parse: (value: unknown) => T, body: string | null = null): Promise<T> {
    const bytes = await this.exchange(method, path, body);
    let value: unknown;
    try {
      value = JSON.parse(new TextDecoder().decode(bytes));
    } catch (error) {
      throw new AuthorityProtocolError(`The authority answered ${requestName(method, path)} with a body that is not JSON, so something else answered at its address.`, { cause: error });
    }
    try {
      return parse(value);
    } catch (error) {
      throw new AuthorityProtocolError(`The authority answered ${requestName(method, path)} with a body this client does not understand. ${error instanceof Error ? error.message : String(error)}`, { cause: error });
    }
  }

  private async exchange(method: string, path: string, body: string | Uint8Array | null = null): Promise<Uint8Array> {
    const request = requestName(method, path);
    let status: number, bytes: Uint8Array;
    try {
      const response = await fetch(`${this.base}/${path}`, {
        method, body, redirect: "error",
        signal: this.signal === undefined ? AbortSignal.timeout(this.timeoutMs) : AbortSignal.any([this.signal, AbortSignal.timeout(this.timeoutMs)]),
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

const requestName = (method: string, path: string) => `${method} ${path.split("?")[0]}`;

function errorSentence(bytes: Uint8Array): string | undefined {
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    return typeof value === "object" && value !== null && "error" in value && typeof value.error === "string" ? value.error : undefined;
  } catch {
    return undefined;
  }
}
