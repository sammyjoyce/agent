import { decide, type AuthorityWrite } from "./authority-core.js";
import { commandHolder, isLowercaseUuid, isSha256Hex, parseAuthorityCommand, parseAuthorityCredentials, type AuthorityCredential } from "./authority-wire.js";
import type { AuthorityCommand } from "../generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../generated/AuthorityRecord.js";
import type { AuthorityReply } from "../generated/AuthorityReply.js";
import type { LogEntry } from "../generated/LogEntry.js";

type SqlValue = string | number | null;
interface SqlCursor extends Iterable<Record<string, SqlValue>> {
  toArray(): Record<string, SqlValue>[];
}
/** The parts of a SQLite Durable Object's state the authority uses. */
interface DurableObjectState {
  readonly storage: {
    readonly sql: { exec(query: string, ...bindings: SqlValue[]): SqlCursor };
    transactionSync<T>(closure: () => T): T;
  };
}
interface DurableObjectId {
  toString(): string;
}
interface DurableObjectNamespace {
  idFromName(name: string): DurableObjectId;
  get(id: DurableObjectId): { fetch(request: Request): Promise<Response> };
}
interface R2Object {
  readonly size: number;
}
interface R2Bucket {
  head(key: string): Promise<R2Object | null>;
  get(key: string): Promise<(R2Object & { readonly body: ReadableStream }) | null>;
  put(key: string, value: ArrayBuffer, options: { readonly sha256: string }): Promise<R2Object | null>;
}

export interface AuthorityEnv {
  readonly AUTHORITY: DurableObjectNamespace;
  readonly BLOBS: R2Bucket;
  /** A JSON array that `parseAuthorityCredentials` accepts. */
  readonly AUTHORITY_CREDENTIALS: string;
}

const COMMAND_BODY_LIMIT = 1024 * 1024;
const PAGE_ENTRIES = 64;
const PAGE_ENTRY_JSON = 4 * 1024 * 1024;

type Endpoint =
  | { readonly name: "command" | "record" }
  | { readonly name: "log"; readonly after: number; readonly limit: number }
  | { readonly name: "put_blob" | "get_blob" | "head_blob"; readonly sha256: string };

/** What the Worker asks its coordinator's object, after it has authorized the request. */
type ObjectRequest =
  | { readonly type: "command"; readonly coordinator: string; readonly command: AuthorityCommand }
  | { readonly type: "record" }
  | { readonly type: "log"; readonly after: number; readonly limit: number };

class Refusal extends Error {
  constructor(readonly status: number, message: string) { super(message); }
}

const failure = (status: number, sentence: string) => Response.json({ error: sentence }, { status });
const jsonResponse = (json: string) => new Response(json, { headers: { "content-type": "application/json" } });
const notEnrolled = () => failure(404, "This coordinator is not enrolled.");

function parseEndpoint(request: Request): { readonly coordinator: string; readonly endpoint: Endpoint } {
  const url = new URL(request.url);
  const match = /^\/v1\/coordinators\/([^/]+)\/(commands|record|log|blobs\/([^/]*))$/.exec(url.pathname);
  const coordinator = match?.[1], resource = match?.[2], sha256 = match?.[3];
  if (coordinator === undefined || resource === undefined) throw new Refusal(400, "The path is not one the authority serves.");
  if (!isLowercaseUuid(coordinator)) throw new Refusal(400, "The coordinator id in the path is not a lowercase UUID.");
  if (sha256 !== undefined && !isSha256Hex(sha256)) throw new Refusal(400, "The blob name in the path is not 64 lowercase hexadecimal characters.");
  if (resource !== "log" && url.search !== "") throw new Refusal(400, "This path takes no query.");
  const endpoint = route(request.method, resource, sha256, url.searchParams);
  if (endpoint === undefined) throw new Refusal(405, `The authority does not answer ${request.method} on this path.`);
  return { coordinator, endpoint };
}

function route(method: string, resource: string, sha256: string | undefined, query: URLSearchParams): Endpoint | undefined {
  if (sha256 !== undefined) {
    switch (method) {
      case "PUT": return { name: "put_blob", sha256 };
      case "GET": return { name: "get_blob", sha256 };
      case "HEAD": return { name: "head_blob", sha256 };
      default: return undefined;
    }
  }
  switch (`${method} ${resource}`) {
    case "POST commands": return { name: "command" };
    case "GET record": return { name: "record" };
    case "GET log": return { name: "log", ...logQuery(query) };
    default: return undefined;
  }
}

function logQuery(query: URLSearchParams): { after: number; limit: number } {
  for (const name of query.keys()) {
    if (name !== "after" && name !== "limit") throw new Refusal(400, `The log takes no query parameter ${name}.`);
  }
  const whole = (name: string, least: number) => {
    const values = query.getAll(name);
    const value = values.length === 1 && /^\d{1,16}$/.test(values[0] ?? "") ? Number(values[0]) : Number.NaN;
    if (!Number.isSafeInteger(value) || value < least) throw new Refusal(400, `The log needs one whole number of at least ${least} as ${name}.`);
    return value;
  };
  return { after: whole("after", 0), limit: whole("limit", 1) };
}

async function sha256Hex(bytes: ArrayBuffer | Uint8Array<ArrayBuffer>): Promise<string> {
  return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function sameDigest(left: string, right: string): boolean {
  let difference = left.length ^ right.length;
  for (let index = 0; index < Math.min(left.length, right.length); index += 1) difference |= left.charCodeAt(index) ^ right.charCodeAt(index);
  return difference === 0;
}

async function authenticate(request: Request, env: AuthorityEnv, coordinator: string): Promise<AuthorityCredential> {
  const token = /^Bearer (\S+)$/.exec(request.headers.get("authorization") ?? "")?.[1];
  if (token === undefined) throw new Refusal(401, "The request carries no bearer token.");
  const digest = await sha256Hex(new TextEncoder().encode(token));
  let found: AuthorityCredential | undefined;
  for (const credential of parseAuthorityCredentials(JSON.parse(env.AUTHORITY_CREDENTIALS))) {
    if (sameDigest(credential.token_sha256, digest) && credential.coordinator === coordinator) found = credential;
  }
  if (found === undefined) throw new Refusal(401, "The bearer token is not a credential for this coordinator.");
  return found;
}

async function readCommand(request: Request): Promise<AuthorityCommand> {
  const tooLarge = new Refusal(413, `A command body may hold at most ${COMMAND_BODY_LIMIT} bytes. Store a large batch as a blob.`);
  if (Number(request.headers.get("content-length") ?? 0) > COMMAND_BODY_LIMIT) throw tooLarge;
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > COMMAND_BODY_LIMIT) throw tooLarge;
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    throw new Refusal(400, "The command body is not UTF-8 JSON.");
  }
  try {
    return parseAuthorityCommand(value);
  } catch (error) {
    throw new Refusal(400, error instanceof Error ? error.message : String(error));
  }
}

function ask(env: AuthorityEnv, coordinator: string, message: ObjectRequest): Promise<Response> {
  const authority = env.AUTHORITY.get(env.AUTHORITY.idFromName(coordinator));
  return authority.fetch(new Request("https://authority.internal/", { method: "POST", body: JSON.stringify(message) }));
}

async function serve(request: Request, env: AuthorityEnv): Promise<Response> {
  const { coordinator, endpoint } = parseEndpoint(request);
  const credential = await authenticate(request, env, coordinator);
  if (credential.holder === null && endpoint.name !== "record") throw new Refusal(403, "A read-only credential may only read the record.");
  switch (endpoint.name) {
    case "record":
      return ask(env, coordinator, { type: "record" });
    case "log":
      return ask(env, coordinator, { type: "log", after: endpoint.after, limit: endpoint.limit });
    case "command": {
      const command = await readCommand(request);
      if (commandHolder(command) !== credential.holder) throw new Refusal(403, "A credential may only run commands for its own holder.");
      return ask(env, coordinator, { type: "command", coordinator, command });
    }
    case "put_blob": {
      const bytes = await request.arrayBuffer();
      if (await sha256Hex(bytes) !== endpoint.sha256) throw new Refusal(422, "The bytes do not match the SHA-256 in the path.");
      await env.BLOBS.put(`${coordinator}/${endpoint.sha256}`, bytes, { sha256: endpoint.sha256 });
      return new Response(null, { status: 204 });
    }
    case "get_blob": {
      const blob = await env.BLOBS.get(`${coordinator}/${endpoint.sha256}`);
      if (blob === null) throw new Refusal(404, "The blob store holds no such blob for this coordinator.");
      return new Response(blob.body, { headers: { "content-type": "application/octet-stream" } });
    }
    case "head_blob":
      return new Response(null, { status: await env.BLOBS.head(`${coordinator}/${endpoint.sha256}`) === null ? 404 : 200 });
    default:
      return endpoint satisfies never;
  }
}

/**
 * The authority Worker. It authenticates and authorizes each request, parses
 * commands strictly, serves blobs from R2, and hands everything else to the
 * coordinator's Durable Object.
 */
export default {
  async fetch(request: Request, env: AuthorityEnv): Promise<Response> {
    try {
      return await serve(request, env);
    } catch (error) {
      if (error instanceof Refusal) return failure(error.status, error.message);
      console.error(error);
      return failure(500, "The authority failed to handle the request.");
    }
  },
};

/**
 * One coordinator's authority: the record and the replication log in the
 * object's SQLite database. Each command runs `decide` inside one synchronous
 * transaction, so the compare-and-swap it describes is atomic.
 */
export class CoordinatorAuthority {
  private readonly storage: DurableObjectState["storage"];
  private readonly blobs: R2Bucket;

  constructor(ctx: DurableObjectState, env: AuthorityEnv) {
    this.storage = ctx.storage;
    this.blobs = env.BLOBS;
    this.rows("CREATE TABLE IF NOT EXISTS record (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), json TEXT NOT NULL)");
    this.rows("CREATE TABLE IF NOT EXISTS log (at INTEGER PRIMARY KEY, digest TEXT NOT NULL, entry TEXT NOT NULL)");
  }

  async fetch(request: Request): Promise<Response> {
    const message = await request.json() as ObjectRequest;
    switch (message.type) {
      case "command":
        return Response.json(await this.command(message.coordinator, message.command));
      case "record": {
        const record = this.recordJson();
        return record === undefined ? notEnrolled() : jsonResponse(record);
      }
      case "log":
        return this.log(message.after, message.limit);
      default:
        return message satisfies never;
    }
  }

  private rows(query: string, ...bindings: SqlValue[]): SqlCursor {
    return this.storage.sql.exec(query, ...bindings);
  }

  private recordJson(): string | undefined {
    const [row] = this.rows("SELECT json FROM record WHERE singleton = 1").toArray();
    return typeof row?.json === "string" ? row.json : undefined;
  }

  /**
   * Blobs are checked before the transaction because they are never deleted:
   * a blob found here is still there when the entry commits.
   */
  private async command(coordinator: string, command: AuthorityCommand): Promise<AuthorityReply> {
    if (command.op === "append" && await this.namesMissingBlob(coordinator, command.entry)) {
      const record = this.recordJson();
      return { result: "refused", reason: "missing_blob", state: record === undefined ? null : (JSON.parse(record) as AuthorityRecord).state };
    }
    return this.storage.transactionSync(() => {
      const stored = this.recordJson();
      const decision = decide(stored === undefined ? undefined : JSON.parse(stored) as AuthorityRecord, command, (at) => {
        const [row] = this.rows("SELECT digest FROM log WHERE at = ?", at).toArray();
        return typeof row?.digest === "string" ? row.digest : undefined;
      });
      const next = decision.record === undefined ? undefined : JSON.stringify(decision.record);
      if (next !== undefined && next !== stored) {
        this.rows("INSERT INTO record (singleton, json) VALUES (1, ?) ON CONFLICT (singleton) DO UPDATE SET json = excluded.json", next).toArray();
      }
      if (decision.write !== undefined) this.apply(decision.write);
      return decision.reply;
    });
  }

  private async namesMissingBlob(coordinator: string, entry: LogEntry): Promise<boolean> {
    const named = new Set([...entry.files.map((file) => file.sha256), ...(entry.batch?.kind === "blob" ? [entry.batch.sha256] : [])]);
    const found = await Promise.all([...named].map((sha256) => this.blobs.head(`${coordinator}/${sha256}`)));
    return found.includes(null);
  }

  private apply(write: AuthorityWrite): void {
    switch (write.type) {
      case "append":
        this.rows("INSERT INTO log (at, digest, entry) VALUES (?, ?, ?)", write.entry.at, write.entry.digest, JSON.stringify(write.entry)).toArray();
        return;
      case "checkpoint":
        this.rows("DELETE FROM log WHERE at <= ?", write.record.through).toArray();
        return;
      default:
        return write satisfies never;
    }
  }

  private log(after: number, limit: number): Response {
    const record = this.recordJson();
    if (record === undefined) return notEnrolled();
    const entries: string[] = [];
    let size = 0;
    const rows = this.rows("SELECT entry, length(CAST(entry AS BLOB)) AS bytes FROM log WHERE at > ? ORDER BY at LIMIT ?", after, Math.min(limit, PAGE_ENTRIES));
    for (const row of rows) {
      size += Number(row.bytes);
      if (entries.length > 0 && size > PAGE_ENTRY_JSON) break;
      entries.push(String(row.entry));
    }
    return jsonResponse(`{"record":${record},"entries":[${entries.join(",")}]}`);
  }
}
