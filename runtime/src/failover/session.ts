import { readFile } from "node:fs/promises";
import type { FailoverSession } from "../generated/FailoverSession.js";
import { AuthorityClient } from "./authority-client.js";
import { counter, object, text, uuid, type Field } from "./authority-wire.js";

const VARIABLE = "AGENT_FAILOVER";

type Reach = Pick<FailoverSession, "url" | "token_file" | "coordinator_id">;
const reach = { url: text, token_file: text, coordinator_id: uuid };
const watcherSession = object<Reach>(reach);
const holderSession = object<Reach & { holder: string }>({ ...reach, holder: uuid });
const epochSession = object<Reach & { holder: string; epoch: number }>({ ...reach, holder: uuid, epoch: counter });

/** How the Pi child of a replicated coordinator reaches the authority, and the epoch its start was granted. */
export interface OwnerSession {
  readonly link: AuthorityClient;
  readonly holder: string;
  readonly epoch: number;
}

/** How a one-shot script, the helper or the operator, reaches the authority. A session without a holder can only read the record. */
export interface ScriptSession {
  readonly link: AuthorityClient;
  readonly coordinatorId: string;
  readonly holder: string | undefined;
}

export interface SessionOptions {
  readonly timeoutMs?: number;
  readonly signal?: AbortSignal;
}

/** Parses the Pi child's session, which must name a holder and an epoch. */
export async function ownerSession(value: string, options: SessionOptions = {}): Promise<OwnerSession> {
  const session = parse(value, epochSession);
  return { link: await client(session, options), holder: session.holder, epoch: session.epoch };
}

/** Parses a one-shot script's session, which never names an epoch and names a holder unless its host only watches the record. */
export async function scriptSession(value: string | undefined, options: SessionOptions = {}): Promise<ScriptSession> {
  if (value === undefined) throw new Error(`${VARIABLE} is not set`);
  const session = parse(value, (given, path): Reach & { holder?: string } =>
    typeof given === "object" && given !== null && "holder" in given ? holderSession(given, path) : watcherSession(given, path));
  return { link: await client(session, options), coordinatorId: session.coordinator_id, holder: session.holder };
}

function parse<T>(value: string, field: Field<T>): T {
  let given: unknown;
  try { given = JSON.parse(value); }
  catch { throw new Error(`${VARIABLE} is not JSON`); }
  return field(given, VARIABLE);
}

async function client({ url, token_file, coordinator_id }: Reach, options: SessionOptions): Promise<AuthorityClient> {
  let token: string;
  try { token = (await readFile(token_file, "utf8")).trim(); }
  catch (error) { throw new Error(`The failover token file ${token_file} could not be read`, { cause: error }); }
  if (token === "") throw new Error(`The failover token file ${token_file} is empty`);
  return new AuthorityClient({ url, coordinatorId: coordinator_id, token, ...options });
}
