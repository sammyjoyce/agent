import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { after, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { AuthorityClient } from "../../src/failover/authority-client.js";
import type { FailoverSession } from "../../src/generated/FailoverSession.js";
import type { HostResult } from "../../src/generated/HostResult.js";
import type { RuntimeCommand } from "../../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../../src/generated/RuntimeEvent.js";
import type { RuntimeEventKind } from "../../src/generated/RuntimeEventKind.js";
import { DEFAULT_MODEL } from "../../src/models.js";
import { validEvent } from "../../src/protocol.js";
import type { ModelQueue } from "./coordinator-runtime.js";
import { startFaultProxy } from "./failover-fault-proxy.js";
import { OWNER, STANDBY } from "./failover-state.js";
import { startAuthority, type LocalAuthority } from "./failover-workerd.js";

const coordinators = Array.from({ length: 24 }, (_, index) => `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`);
let world: Promise<{ authority: LocalAuthority; tokens: string }> | undefined;
let used = 0;
// Registered while the test file loads, so workerd outlives the test that first asks for it.
after(async () => {
  const started = await world;
  if (started === undefined) return;
  await started.authority.stop();
  await rm(started.tokens, { recursive: true, force: true });
});

async function startWorld() {
  const authority = await startAuthority({ context: { after: () => {} },
    grants: coordinators.flatMap((coordinator) => [OWNER, STANDBY, null].map((holder) => ({ coordinator, holder }))) });
  const tokens = await mkdtemp(join(tmpdir(), "agent-failover-tokens-"));
  return { authority, tokens };
}

/**
 * A coordinator nobody has enrolled, on the one Worker under local workerd
 * that the test file shares, with its own fault proxy. `owner`, `standby` and
 * `reader` reach the Worker directly, as the test's own hands. A process under
 * test gets `session`, which reaches it through the proxy.
 */
export async function failoverCoordinator(t: TestContext) {
  const { authority, tokens } = await (world ??= startWorld());
  const id = coordinators[used++];
  if (id === undefined) throw new Error("The test file ran out of Worker coordinators");
  const proxy = await startFaultProxy(t, authority.url);
  const token = (holder: string | null) => {
    const credential = authority.credentials.find((candidate) => candidate.coordinator === id && candidate.holder === holder);
    if (credential === undefined) throw new Error(`The fixture holds no credential for holder ${holder}`);
    return credential.token;
  };
  const direct = (holder: string | null) => new AuthorityClient({ url: authority.url, coordinatorId: id, token: token(holder) });
  return {
    id, proxy, owner: direct(OWNER), standby: direct(STANDBY), reader: direct(null),
    /** The Worker's own address, for a second fault proxy. */
    url: authority.url,
    /** The `AGENT_FAILOVER` value of a process that speaks as `holder`, or with the read-only credential when it is null. */
    async session(holder: string | null, epoch?: number, url = proxy.url): Promise<string> {
      const token_file = join(tokens, `${id}-${holder ?? "reader"}`);
      await writeFile(token_file, `${token(holder)}\n`, { mode: 0o600 });
      const session: FailoverSession = { url, token_file, coordinator_id: id, ...(holder === null ? {} : { holder }), ...(epoch === undefined ? {} : { epoch }) };
      return JSON.stringify(session);
    },
  };
}

export type FailoverCoordinator = Awaited<ReturnType<typeof failoverCoordinator>>;

type HostCommand = Extract<RuntimeEventKind, { type: "host_call" }>["command"];

/** The operation a host call asks for, on whichever node it is routed to. */
function operation(command: HostCommand): HostCommand {
  while (command.type === "on_node") command = command.command;
  return command;
}

const guidance = (command: HostCommand): HostResult | undefined =>
  command.type === "reload_guidance" ? { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] }
    : command.type === "project_guidance" ? { type: "project_guidance", snapshot: { text: "", sources: [] } } : undefined;

export interface BridgeOptions {
  readonly directory: string;
  /** The `AGENT_FAILOVER` value. Absent for a coordinator without failover. */
  readonly session?: string;
  readonly queue?: ModelQueue;
  readonly env?: Record<string, string>;
  /** Answers a host call that is not a guidance read, given its operation. A call it leaves unanswered stays pending. */
  readonly host?: (operation: HostCommand) => HostResult | undefined;
}

/**
 * The real bridge as Rust starts it, with only the model provider replaced.
 * Frames go in on stdin and are collected from stdout in arrival order.
 */
export async function startBridge(t: TestContext, options: BridgeOptions) {
  const queue = join(options.directory, "responses.json");
  await chmod(options.directory, 0o700);
  await writeFile(queue, JSON.stringify(options.queue ?? {}));
  const { AGENT_FAILOVER: _inherited, ...inherited } = process.env;
  const child = spawn(process.execPath, ["--no-warnings",
    fileURLToPath(new URL("./coordinator-runtime.js", import.meta.url)), options.directory],
  { stdio: ["pipe", "pipe", "pipe"], env: { ...inherited, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue,
    ...(options.session === undefined ? {} : { AGENT_FAILOVER: options.session }), ...options.env } });
  const frames: RuntimeEvent[] = [], listeners = new Set<() => void>();
  let errors = "", ended = false;
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { errors += chunk; });
  child.stdin.on("error", () => {});
  const exit = new Promise<{ code: number | null; signal: NodeJS.Signals | null }>((resolve) =>
    child.once("close", (code, signal) => { ended = true; resolve({ code, signal }); for (const notify of listeners) notify(); }));
  const send = (id: number, command: RuntimeCommand) => { child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n"); };
  const lines = createInterface({ input: child.stdout });
  lines.on("line", (line) => {
    const frame: unknown = JSON.parse(line);
    assert.ok(validEvent(frame), `The bridge wrote an invalid frame: ${line}`);
    frames.push(frame);
    if (frame.event.type === "host_call") {
      const asked = operation(frame.event.command);
      const result = guidance(asked) ?? options.host?.(asked);
      if (result !== undefined) send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result });
    }
    for (const notify of listeners) notify();
  });
  t.after(async () => { lines.close(); child.kill("SIGKILL"); await exit; });
  const describe = () => `${JSON.stringify(frames.map((frame) => ({ id: frame.id, event: frame.event })))}\n${errors}`;
  return {
    child, frames, send,
    errors: () => errors,
    /** How the bridge ended. Rejects when it is still running after `timeoutMs`. */
    exited(timeoutMs = 15_000): Promise<{ code: number | null; signal: NodeJS.Signals | null }> {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`The bridge was still running after ${timeoutMs} ms: ${describe()}`)), timeoutMs);
        void exit.then((ended) => { clearTimeout(timer); resolve(ended); });
      });
    },
    /** The first frame of request `id` that matches. Rejects when the bridge exits or the wait runs out first. */
    wait(id: number, predicate: (event: RuntimeEventKind) => boolean, timeoutMs = 20_000): Promise<RuntimeEventKind> {
      return new Promise((resolve, reject) => {
        const finish = (settle: () => void) => { listeners.delete(check); clearTimeout(timer); settle(); };
        const check = () => {
          const frame = frames.find((candidate) => candidate.id === id && predicate(candidate.event));
          if (frame !== undefined) finish(() => resolve(frame.event));
          else if (ended) finish(() => reject(new Error(`The bridge exited before request ${id} got its frame: ${describe()}`)));
        };
        const timer = setTimeout(() => finish(() => reject(new Error(`Request ${id} did not get its frame in ${timeoutMs} ms: ${describe()}`))), timeoutMs);
        listeners.add(check);
        check();
      });
    },
    /** The host_call frames so far that ask for this operation. */
    hostCalls: (type: HostCommand["type"]) => frames.filter((frame) => frame.event.type === "host_call" && operation(frame.event.command).type === type),
    /** Every frame of request `id` so far. */
    of: (id: number) => frames.filter((frame) => frame.id === id).map((frame) => frame.event),
  };
}

export type Bridge = Awaited<ReturnType<typeof startBridge>>;

const node = { host_id: "33333333-3333-4333-8333-333333333333", name: "fixture", rex_server: null, home_directory: "/home/fixture",
  agent_program: "/example/agent", coordinator: null, launch: { state_dir: null, runtime: null, config: null, instructions: null, model: null } };

/** Gives the coordinator one connected execution host, as Rust does at start, so a tool can reach a host. */
export async function connectHost(bridge: Bridge): Promise<void> {
  const requests: RuntimeCommand[] = [
    { type: "configure_coordinator", bootstrap: { node, settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } },
    { type: "register_node", node }, { type: "set_connected_nodes", host_ids: [node.host_id] }];
  for (const [index, command] of requests.entries()) {
    bridge.send(900 + index, command);
    await bridge.wait(900 + index, (event) => event.type === "done");
  }
}

export const chat = (input: string, input_id: string): RuntimeCommand => ({ type: "chat", input, input_id, model: DEFAULT_MODEL,
  instructions: "Brief answers.", cwd: "/example/project", origin_host_id: null, hosts: [] });

/** Starts a one-shot failover script as Rust does. `done` resolves with what it printed. */
export function startScript(script: "helper" | "operator", session: string | undefined, request: string) {
  const { AGENT_FAILOVER: _inherited, ...inherited } = process.env;
  const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL(`../../src/failover/${script}.js`, import.meta.url)), request],
    { stdio: ["ignore", "pipe", "pipe"], env: { ...inherited, ...(session === undefined ? {} : { AGENT_FAILOVER: session }) } });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
  const started = Date.now();
  const done = new Promise<number | null>((resolve, reject) => { child.once("error", reject); child.once("close", resolve); })
    .then((code) => ({ code, stdout, stderr, elapsedMs: Date.now() - started }));
  return { child, done };
}

/** Runs a one-shot failover script as Rust does and returns what it printed. */
export const runScript = (script: "helper" | "operator", session: string | undefined, request: string) => startScript(script, session, request).done;

export const runHelper = (session: string | undefined, request: string) => runScript("helper", session, request);
