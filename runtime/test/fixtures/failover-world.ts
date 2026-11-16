import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { appendFile, mkdir, mkdtemp, readFile, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import type { AttachmentRef } from "../../src/generated/AttachmentRef.js";
import type { AuthorityRecord } from "../../src/generated/AuthorityRecord.js";
import type { FailoverSession } from "../../src/generated/FailoverSession.js";
import type { RuntimeCommand } from "../../src/generated/RuntimeCommand.js";
import type { RuntimeEventKind } from "../../src/generated/RuntimeEventKind.js";
import { apnsConfig, startApnsOrigin, type ApnsOrigin, type Push } from "./apns-origin.js";
import { coordinatorWorld, type OwnedProcess } from "./coordinator-world.js";
import { failoverCoordinator } from "./failover-bridge.js";
import { startFaultProxy } from "./failover-fault-proxy.js";
import type { EnrolledReceipt, FollowedReceipt, JoinedReceipt, PromotedReceipt, ReleasedReceipt, StatusReceipt } from "./failover-hosts.js";
import { logBatches, logEntries, OWNER, STANDBY, tables } from "./failover-state.js";
import { floorFile } from "./owner-floor.js";

const SERVE = ["serve", "--local-only", "--no-sources"];
const STANDBY_NODE = "44444444-4444-4444-8444-444444444444";

/** One host that may own the coordinator: its own home, private config, holder credential, state directory and fault proxy. */
export interface CoordinatorHost {
  readonly name: "owner" | "standby";
  readonly holder: string;
  readonly home: string;
  readonly state: string;
  readonly socket: string;
  /** The execution host this coordinator's own machine registers as. */
  readonly nodeId: string;
  /** Every request this host's processes send to the authority passes through this proxy. */
  readonly proxy: Awaited<ReturnType<typeof startFaultProxy>>;
  readonly environment: NodeJS.ProcessEnv;
  /** The `serve` this host started last. */
  serving?: OwnedProcess;
}

export interface WorldOptions {
  /** Gives both coordinator hosts an `[apns]` section and sends their pushes to a local origin. */
  readonly apns?: boolean;
  /** Gives the worker host a read-only credential and makes it read the owner record this often. */
  readonly watchSeconds?: number;
  /** What the fixture source helper on the owner's host answers as that host's Codex history. */
  readonly history?: { readonly threads: readonly unknown[]; readonly turns: readonly unknown[] };
}

export interface PromoteOptions {
  readonly replaceEpoch: number;
  /** The operator's statement that the old owner is stopped. */
  readonly statement?: string;
  /** How many seconds the command waits for stop evidence. */
  readonly wait?: number;
}

/** One input a client sent: every event so far, and the end of the exchange. */
export interface Sent {
  readonly id: string;
  readonly events: RuntimeEventKind[];
  /** Resolves at `done`. Rejects when the coordinator closes the connection first. */
  readonly done: Promise<RuntimeEventKind[]>;
}

const isSocket = (path: string) => stat(path).then((entry) => entry.isSocket(), () => false);

function groupAlive(group: number): boolean {
  try { process.kill(-group, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

/**
 * A runtime directory laid out as an installation's is: the Pi child's entry
 * with the built `failover` scripts and the database script beside it, where
 * Rust looks for them. The entry is the fixture that replaces only the model
 * provider.
 */
async function runtimeBesideBuiltScripts(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-runtime-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await symlink(fileURLToPath(new URL("./coordinator-runtime.js", import.meta.url)), join(directory, "coordinator-runtime.js"));
  await symlink(fileURLToPath(new URL("../../src/failover", import.meta.url)), join(directory, "failover"));
  await symlink(fileURLToPath(new URL("../../src/backup-database.js", import.meta.url)), join(directory, "backup-database.js"));
  return join(directory, "coordinator-runtime.js");
}

/**
 * Two hosts that may own one coordinator, one worker host, and the real
 * authority Worker on the local workerd this test file shares. Every process
 * is the production binary. The Pi child is the production bridge with only
 * the model provider replaced. It returns with the owner's state directory
 * made by a coordinator without failover, nothing enrolled, and nothing running.
 */
export async function failoverWorld(t: TestContext, options: WorldOptions = {}) {
  const authority = await failoverCoordinator(t), runtime = await runtimeBesideBuiltScripts(t);
  const base = await coordinatorWorld(t, async (homes) => {
    await writeFile(join(homes[0], "state", "coordinator-id"), authority.id, { mode: 0o600 });
  }, runtime);
  const { directory, homes, until } = base;
  base.server.child.kill("SIGINT");
  assert.equal(await base.server.exited, 0, base.server.errors());
  // The first worker has run nothing, and a daemon takes three seconds to stop when asked.
  if (base.worker.child.pid !== undefined) process.kill(-base.worker.child.pid, "SIGKILL");
  await base.worker.exited;

  const apns: ApnsOrigin | undefined = options.apns ? await startApnsOrigin(t) : undefined;
  async function coordinatorHost(name: CoordinatorHost["name"], holder: string, home: string, nodeId: string, proxy: CoordinatorHost["proxy"],
    environment: NodeJS.ProcessEnv): Promise<CoordinatorHost> {
    const session = JSON.parse(await authority.session(holder, undefined, proxy.url)) as FailoverSession;
    let config = `[failover]\nurl = "${session.url}"\nholder = "${holder}"\ntoken_file = "${session.token_file}"\n`;
    if (apns !== undefined) {
      const { team_id, key_id, topic, key_file, environment: target } = await apnsConfig(join(home, "AuthKey.p8"));
      config += `[apns]\nteam_id = "${team_id}"\nkey_id = "${key_id}"\ntopic = "${topic}"\nkey_file = "${key_file}"\nenvironment = "${target}"\n`;
    }
    await appendFile(join(home, "agent.toml"), config);
    return { name, holder, home, state: join(home, "state"), socket: join(home, "state", "agent.sock"), nodeId, proxy, environment: { ...environment, ...apns?.environment } };
  }
  const second = join(directory, "standby");
  await mkdir(second, { mode: 0o700 });
  await writeFile(join(second, "AGENTS.md"), "Use only invented test data.\n");
  await writeFile(join(second, "agent.toml"), 'node_name = "standby"\n');
  // The source helper is the Rust tests' stand-in for `codex app-server`. It reads its answers from CODEX_HOME and lists each call there.
  const source = join(homes[0], "codex");
  if (options.history !== undefined) {
    await mkdir(source, { mode: 0o700 });
    await writeFile(join(source, "native.json"), JSON.stringify(options.history));
    await symlink(fileURLToPath(new URL("../../../../tests/fixtures/codex-native.cjs", import.meta.url)), join(directory, "bin", "codex"));
  }
  const owner = await coordinatorHost("owner", OWNER, homes[0], base.coordinator, authority.proxy, options.history === undefined ? {} : { CODEX_HOME: source });
  const standby = await coordinatorHost("standby", STANDBY, second, STANDBY_NODE, await startFaultProxy(t, authority.url), { HOME: second, XDG_CONFIG_HOME: join(second, ".config"),
    XDG_DATA_HOME: join(second, ".local"), AGENT_TEST_REX_STATE: join(second, "rex.json"), AGENT_TEST_NODE_ID: STANDBY_NODE });

  // The worker dials this path as its coordinator's address. It names the host the operator pointed the worker at.
  const address = join(directory, "coordinator-address");
  async function direct(host: CoordinatorHost): Promise<void> {
    await symlink(host.socket, address + ".next");
    await rename(address + ".next", address);
  }
  await direct(owner);
  if (options.watchSeconds !== undefined) {
    const session = JSON.parse(await authority.session(null, undefined, authority.url)) as FailoverSession;
    await appendFile(join(homes[1], "agent.toml"), `[failover]\nurl = "${session.url}"\ntoken_file = "${session.token_file}"\nwatch_interval_seconds = ${options.watchSeconds}\n`);
  }
  const worker: { readonly home: string; readonly nodeId: string; daemon?: OwnedProcess } = { home: homes[1], nodeId: base.laptop };

  const launch = (host: CoordinatorHost, command: string[], input?: string): OwnedProcess =>
    base.start(0, ["--state-dir", host.state, "--config", join(host.home, "agent.toml"), "--runtime", runtime, "--instructions", join(host.home, "AGENTS.md"), ...command],
      input, host.environment, true);
  async function receipt<T>(host: CoordinatorHost, ...command: string[]): Promise<T> {
    const running = launch(host, ["failover", ...command], "");
    assert.equal(await running.exited, 0, `failover ${command.join(" ")} on the ${host.name}: ${running.errors()}`);
    return JSON.parse(running.output()) as T;
  }
  const promotion = ({ replaceEpoch, statement, wait }: PromoteOptions) => ["promote", "--replace-epoch", String(replaceEpoch),
    ...(statement === undefined ? [] : ["--old-owner-stopped", statement]), ...(wait === undefined ? [] : ["--wait", String(wait)])];
  const signalGroup = (host: CoordinatorHost, signal: NodeJS.Signals) => {
    const pid = host.serving?.child.pid;
    assert.ok(pid !== undefined, `the ${host.name} has no coordinator to signal`);
    process.kill(-pid, signal);
    return pid;
  };

  function sending(host: CoordinatorHost, input: string, sent: { id?: string; attachments?: AttachmentRef[] } = {}): Sent {
    const id = sent.id ?? randomUUID(), events: RuntimeEventKind[] = [];
    const done = base.exchange({ type: "main_input", input_id: id, input, mode: "follow_up",
      context: { instructions: "Brief answers.", origin_host_id: null, cwd: host.home, hosts: [] },
      ...(sent.attachments === undefined ? {} : { attachments: sent.attachments }) }, (event) => { events.push(event); }, host.socket);
    done.catch(() => {});
    return { id, events, done };
  }

  return {
    id: authority.id, directory, owner, standby, worker, apns,
    /** The test's own hands on the authority, past every fault proxy. */
    authority: { owner: authority.owner, standby: authority.standby, reader: authority.reader },
    script: base.script, until, queue: base.queue,

    /** Starts a command of the binary on a coordinator host without waiting for it. */
    launch,
    /** Runs a `beep-boop failover` command that must succeed and returns its receipt. */
    receipt,
    enroll: () => receipt<EnrolledReceipt>(owner, "enroll"),
    join: () => receipt<JoinedReceipt>(standby, "join", authority.id),
    follow: () => receipt<FollowedReceipt>(standby, "follow", "--once"),
    /** Starts a promotion on the standby without waiting for it. */
    promoting: (promote: PromoteOptions) => launch(standby, ["failover", ...promotion(promote)], ""),
    promote: (promote: PromoteOptions) => receipt<PromotedReceipt>(standby, ...promotion(promote)),
    release: () => receipt<ReleasedReceipt>(owner, "release"),
    status: (host: CoordinatorHost) => receipt<StatusReceipt>(host, "status"),

    /** Starts `serve` on a host and returns once it has bound its socket. */
    async serve(host: CoordinatorHost): Promise<OwnedProcess> {
      const serving = launch(host, SERVE);
      host.serving = serving;
      await until(async () => {
        assert.equal(serving.child.exitCode, null, `serve on the ${host.name} exited ${serving.child.exitCode}: ${serving.errors()}`);
        return isSocket(host.socket);
      }, `The ${host.name} must bind its socket`, () => serving.errors().slice(-2000));
      return serving;
    },
    /** Starts `serve` on a host that is expected to be refused, and returns the process. */
    starting(host: CoordinatorHost): OwnedProcess { return host.serving = launch(host, SERVE); },
    /** Stops a coordinator as an operator does and returns its exit status. */
    async stop(host: CoordinatorHost): Promise<number | null> {
      signalGroup(host, "SIGINT");
      return host.serving!.exited;
    },
    /** Kills the supervisor, its Pi child and their helpers at once, as a host that loses power does. */
    async crash(host: CoordinatorHost): Promise<void> {
      const group = signalGroup(host, "SIGKILL");
      await host.serving!.exited;
      await until(async () => !groupAlive(group), `Every process of the ${host.name}'s coordinator must end`);
    },
    suspend: (host: CoordinatorHost) => { signalGroup(host, "SIGSTOP"); },
    resume: (host: CoordinatorHost) => { signalGroup(host, "SIGCONT"); },
    bound: (host: CoordinatorHost) => isSocket(host.socket),

    /** Starts the worker daemon, which dials whichever host `direct` named last. */
    work(): OwnedProcess { return worker.daemon = base.start(1, ["maintain"], undefined, { AGENT_TEST_COORDINATOR_SOCKET: address }); },
    /** Points the worker's coordinator address at a host, as an operator does after a promotion. */
    direct,
    /** Waits until a coordinator reports exactly these execution hosts online. */
    async online(host: CoordinatorHost, ids: readonly string[]): Promise<void> {
      await until(async () => {
        const nodes = launch(host, ["nodes"], "");
        if (await nodes.exited !== 0) return false;
        const state = base.events(nodes.output()).find((event) => event.type === "environment");
        return state?.type === "environment" && ids.every((id) => state.online_host_ids.includes(id));
      }, `The ${host.name} must see ${ids.join(" and ")} online`);
    },
    /** The highest owner epoch the worker host has served this coordinator at, or undefined before any. */
    async floor(): Promise<number | undefined> {
      const text = await readFile(floorFile(worker.home, authority.id), "utf8").catch(() => undefined);
      return text === undefined ? undefined : Number(text);
    },

    /** Sends one client input and returns without waiting for its end. */
    sending,
    /** Sends one client input and returns its events once the coordinator says `done`. */
    send: (host: CoordinatorHost, input: string, sent: { id?: string; attachments?: AttachmentRef[] } = {}) => sending(host, input, sent).done,
    /** One request of a client on a host's socket, to its `done`. */
    request: (host: CoordinatorHost, command: RuntimeCommand, observe?: (event: RuntimeEventKind) => void) => base.exchange(command, observe, host.socket),

    /** The lines the fixture `exec` appended on the worker host, one for each run. */
    async ledger(): Promise<unknown[]> {
      const text = await readFile(join(worker.home, "effects"), "utf8").catch(() => "");
      return text.split("\n").filter(Boolean).map((line) => JSON.parse(line) as unknown);
    },
    record: (): Promise<AuthorityRecord | undefined> => authority.reader.record(),
    logEntries: () => logEntries(authority.standby),
    /** How many submissions the log holds for the input with this id. Each one is an admission of it. */
    async logged(inputId: string): Promise<number> {
      const writes = (await logBatches(authority.standby)).flat();
      return new Set(writes.flatMap((write) => write.type === "submission" && write.value.requestId === inputId ? [write.value.id] : [])).size;
    },
    tables: (host: CoordinatorHost) => tables(host.state),
    /** How many submissions a host's session database holds for the input with this id. */
    saved: (host: CoordinatorHost, inputId: string) => (tables(host.state).submissions ?? []).filter((row) => row.includes(inputId)).length,
    pushes: (): readonly Push[] => apns?.received ?? [],
    /** The methods the fixture source helper was asked, in order. */
    async sourceCalls(): Promise<string[]> {
      const text = await readFile(join(source, "calls"), "utf8").catch(() => "");
      return text.split("\n").filter(Boolean).map((line) => (JSON.parse(line) as { method: string }).method);
    },
  };
}

export type FailoverWorld = Awaited<ReturnType<typeof failoverWorld>>;

/** The receipts that say an input was accepted. A later receipt with `work` reports its progress. */
export const admissions = (events: readonly RuntimeEventKind[], inputId: string) =>
  events.filter((event) => event.type === "input_accepted" && event.input_id === inputId && event.work === undefined).length;

export const answers = (events: readonly RuntimeEventKind[]) => events.flatMap((event) => event.type === "answer" ? [event.text] : []);
