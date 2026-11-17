import assert from "node:assert/strict";
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { AuthorityClient } from "../../src/failover/authority-client.js";
import type { AuthorityRecord } from "../../src/generated/AuthorityRecord.js";
import type { AuthorityState } from "../../src/generated/AuthorityState.js";
import type { CheckpointRecord } from "../../src/generated/CheckpointRecord.js";
import type { StopEvidence } from "../../src/generated/StopEvidence.js";
import type { UnfinishedDelivery } from "../../src/generated/UnfinishedDelivery.js";
import type { UnfinishedToolCall } from "../../src/generated/UnfinishedToolCall.js";
import { protocolLines } from "../../src/protocol.js";
import { claimStart, note, openOwner, stage } from "./failover-state.js";
import { startAuthority } from "./failover-workerd.js";

export const HOLDERS = ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"] as const;
const COORDINATORS = Array.from({ length: 24 }, (_, index) => `aaaaaaaa-aaaa-4aaa-8aaa-${index.toString(16).padStart(12, "0")}`);

export interface Run { readonly code: number | null; readonly stdout: string; readonly stderr: string }
export interface Running {
  readonly child: ChildProcess;
  readonly done: Promise<Run>;
  /** Fails with the command's output when it has ended, for a wait that needs it running. */
  assertRunning(): void;
}

export interface StatusReceipt { coordinator_id: string; record: AuthorityRecord | null; state_dir: string; applied: number | null }
export interface EnrolledReceipt { coordinator_id: string; holder: string; epoch: number; checkpoint: CheckpointRecord;
  uploaded: { files: number; bytes: number; not_included: string[] } | null }
export interface CheckpointedReceipt { coordinator_id: string; epoch: number; checkpoint: CheckpointRecord; head: number;
  uploaded: { files: number; bytes: number; not_included: string[] } }
export interface JoinedReceipt { coordinator_id: string; state_dir: string; through: number; files: number; bytes: number; replaced: string | null }
export interface FollowedReceipt { coordinator_id: string; from: number; applied: number }
export interface ReleasedReceipt { coordinator_id: string; epoch: number; evidence: string; candidate: string; posted: boolean }
export interface PromotedReceipt { coordinator_id: string; holder: string; epoch: number; sealed_head: number; evidence: StopEvidence | null;
  missing_credentials: string[]; unfinished_tools: UnfinishedToolCall[]; unfinished_deliveries: UnfinishedDelivery[]; unreadable: string[] }

export const exists = (path: string) => stat(path).then(() => true, () => false);
export const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

export async function fingerprint(root: string): Promise<Map<string, string>> {
  const files = new Map<string, string>();
  for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const path = join(entry.parentPath, entry.name);
    files.set(path.slice(root.length + 1), sha256(await readFile(path)));
  }
  return files;
}

export async function until(ready: () => boolean | Promise<boolean>, what: string, timeoutMs = 20_000): Promise<void> {
  for (const deadline = Date.now() + timeoutMs; !await ready();) {
    if (Date.now() > deadline) throw new Error(`Timed out waiting: ${what}`);
    await delay(25);
  }
}

/** One host of a replicated coordinator: its own state, home and private config, and its own holder credential. */
export class Host {
  readonly state: string;
  readonly link: AuthorityClient;
  private readonly configs: { plain: string; failover: string };

  constructor(private readonly world: World, readonly home: string, readonly coordinatorId: string, readonly holder: string, token: string, readonly url: string) {
    this.state = join(home, "state");
    this.configs = { plain: join(home, "plain.toml"), failover: join(home, "failover.toml") };
    this.link = new AuthorityClient({ url: world.authorityUrl, coordinatorId, token });
  }

  /** Makes the state directory with the production coordinator, as a host that ran before failover was configured. */
  async create(): Promise<void> {
    await mkdir(this.state, { mode: 0o700 });
    await writeFile(join(this.state, "coordinator-id"), this.coordinatorId, { mode: 0o600 });
    const server = this.serve({ failover: false });
    await until(async () => {
      assert.equal(server.child.exitCode, null, "The coordinator must stay up while its state directory is made");
      return await exists(join(this.state, "agent.sock")) && await this.answers();
    }, "the production coordinator answers on its socket");
    server.child.kill("SIGINT");
    const stopped = await server.done;
    assert.equal(stopped.code, 0, stopped.stderr);
  }

  private async answers(): Promise<boolean> {
    const channel = createConnection({ path: join(this.state, "agent.sock") });
    try {
      channel.write(JSON.stringify({ type: "job_status" }) + "\n");
      for await (const line of protocolLines(channel)) {
        if ((JSON.parse(line) as { type: string }).type === "done") return true;
      }
      return false;
    } catch { return false; } finally { channel.destroy(); }
  }

  private arguments(failover: boolean, runtime = this.world.runtime): string[] {
    return ["--state-dir", this.state, "--config", failover ? this.configs.failover : this.configs.plain, "--runtime", join(runtime, "bridge.js")];
  }

  /** Starts `serve`. `bridge` names a runtime directory whose `bridge.js` stands in for Pi. */
  serve(options: { failover?: boolean; runtime?: string } = {}): Running {
    return this.world.spawn([...this.arguments(options.failover ?? true, options.runtime), "--instructions", join(this.home, "AGENTS.md"),
      "serve", "--local-only", "--no-sources"], this.home);
  }

  start(...command: string[]): Running {
    return this.world.spawn([...this.arguments(true), "--json", "failover", ...command], this.home);
  }

  failover(...command: string[]): Promise<Run> { return this.start(...command).done; }

  /** Runs a command that must succeed without `--json` and returns what it prints for a person. */
  async plain(...command: string[]): Promise<string> {
    const run = await this.world.spawn([...this.arguments(true), "failover", ...command], this.home).done;
    assert.equal(run.code, 0, `failover ${command.join(" ")} failed: ${run.stderr}`);
    return run.stdout;
  }

  async receipt<T>(...command: string[]): Promise<T> {
    const run = await this.failover(...command);
    assert.equal(run.code, 0, `failover ${command.join(" ")} failed: ${run.stderr}`);
    return JSON.parse(run.stdout) as T;
  }

  async record(): Promise<AuthorityRecord | undefined> { return this.link.record(); }

  async authorityState(): Promise<AuthorityState> {
    const record = await this.record();
    assert.ok(record, "the coordinator is enrolled");
    return record.state;
  }
}

/** The real authority Worker on local workerd, the production binary, and hosts with temporary state, config and home directories. */
export class World {
  private coordinators = 0;
  private constructor(readonly directory: string, readonly authorityUrl: string, readonly binary: string, readonly runtime: string, private readonly bin: string,
    private readonly credentials: readonly { coordinator: string; holder: string | null; token: string }[], private readonly children: Set<ChildProcess>) {}

  static async start(t: TestContext): Promise<World> {
    const directory = await mkdtemp("/tmp/bb-failover-");
    const children = new Set<ChildProcess>();
    t.after(async () => {
      for (const child of children) if (child.pid !== undefined) try { process.kill(-child.pid, "SIGKILL"); } catch { /* It already ended. */ }
      await rm(directory, { recursive: true, force: true });
    });
    const authority = await startAuthority({ context: t, grants: COORDINATORS.flatMap((coordinator) => HOLDERS.map((holder) => ({ coordinator, holder }))) });
    const bin = join(directory, "bin"), runtime = join(directory, "runtime");
    await mkdir(bin, { mode: 0o700 });
    await symlink(process.execPath, join(bin, "node"));
    await linkRuntime(runtime, fileURLToPath(new URL("../../src/bridge.js", import.meta.url)));
    const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../../target/debug/beep-boop", import.meta.url));
    return new World(directory, authority.url, binary, runtime, bin, authority.credentials, children);
  }

  coordinator(): string {
    const id = COORDINATORS[this.coordinators++];
    if (id === undefined) throw new Error("The test file ran out of coordinators");
    return id;
  }

  /** A host of `coordinatorId` with its own holder. `url` routes its commands through a fault proxy. */
  async host(coordinatorId: string, holder: string, url = this.authorityUrl): Promise<Host> {
    const home = await mkdtemp(join(this.directory, "h"));
    const token = this.credentials.find((credential) => credential.coordinator === coordinatorId && credential.holder === holder)?.token;
    if (token === undefined) throw new Error(`The fixture holds no credential for holder ${holder}`);
    await writeFile(join(home, "failover-token"), token, { mode: 0o600 });
    await writeFile(join(home, "AGENTS.md"), "Use only invented test data.\n");
    const plain = 'node_name = "failover-e2e"\njob_directories = []\n';
    await writeFile(join(home, "plain.toml"), plain);
    await writeFile(join(home, "failover.toml"), `${plain}[failover]\nurl = "${url}"\nholder = "${holder}"\ntoken_file = "${join(home, "failover-token")}"\n`);
    return new Host(this, home, coordinatorId, holder, token, url);
  }

  /** A runtime directory whose `bridge.js` is `bridge`, beside the real operator and database scripts. */
  async runtimeWith(bridge: string): Promise<string> {
    const runtime = await mkdtemp(join(this.directory, "r"));
    await linkRuntime(runtime, bridge);
    return runtime;
  }

  spawn(args: string[], home: string): Running {
    const env = { PATH: this.bin, HOME: home, XDG_CONFIG_HOME: join(home, "config"), XDG_DATA_HOME: join(home, "data"), TMPDIR: this.directory,
      AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC };
    const child = spawn(this.binary, args, { cwd: home, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    this.children.add(child);
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (value: string) => { stdout += value; });
    child.stderr.setEncoding("utf8").on("data", (value: string) => { stderr += value; });
    let ended: Run | undefined;
    const done = new Promise<Run>((resolve, reject) => {
      child.once("error", reject);
      child.once("close", (code) => { this.children.delete(child); ended = { code, stdout, stderr }; resolve(ended); });
    });
    return { child, done, assertRunning: () => assert.equal(ended, undefined, `${args.join(" ")} ended: ${JSON.stringify(ended)}`) };
  }
}

async function linkRuntime(runtime: string, bridge: string): Promise<void> {
  const built = (path: string) => fileURLToPath(new URL(path, import.meta.url));
  await mkdir(join(runtime, "failover"), { recursive: true, mode: 0o700 });
  await symlink(bridge, join(runtime, "bridge.js"));
  await symlink(built("../../src/backup-database.js"), join(runtime, "backup-database.js"));
  await symlink(built("../../src/failover/operator.js"), join(runtime, "failover", "operator.js"));
  await symlink(built("../../src/failover/helper.js"), join(runtime, "failover", "helper.js"));
}

/** One run of an owner between two commands: it claims its start, does `work` and closes. Returns the epoch it ran at. */
export async function ownerRun(owner: Host, work: (opened: Awaited<ReturnType<typeof openOwner>>) => Promise<void>): Promise<number> {
  const claimed = await claimStart(owner.link, owner.holder);
  assert.ok(claimed.result === "accepted" && claimed.state.kind === "active", JSON.stringify(claimed));
  const { epoch } = claimed.state;
  const opened = await openOwner(owner.state, owner.link, { holder: owner.holder, epoch });
  try { await work(opened); } finally { await opened.harness.close(BACKGROUND_CONTEXT); }
  return epoch;
}

export function ownerActivity(owner: Host, notes: readonly string[], files: Readonly<Record<string, string>> = {}): Promise<number> {
  return ownerRun(owner, async (opened) => {
    for (const text of notes) await opened.root.submit(note(text, `request-${text}`), BACKGROUND_CONTEXT);
    for (const [path, text] of Object.entries(files)) await opened.log.appendFiles([await stage(owner.state, owner.link, path, Buffer.from(text))]);
  });
}

/** An enrolled owner that has logged notes and a file, and a standby that joined at the checkpoint and has not followed. */
export async function replicatedPair(world: World, urls: { owner?: string; standby?: string } = {}) {
  const coordinator = world.coordinator(), owner = await world.host(coordinator, HOLDERS[0], urls.owner), standby = await world.host(coordinator, HOLDERS[1], urls.standby);
  await owner.create();
  await owner.receipt<EnrolledReceipt>("enroll");
  await standby.receipt<JoinedReceipt>("join", coordinator);
  const epoch = await ownerActivity(owner, ["first", "second"], { "feedback/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.json": "Invented feedback bundle" });
  return { coordinator, owner, standby, epoch, head: (await owner.authorityState()).head };
}

/** Whether the log is sealed for `candidate`, which a promotion that waits for stop evidence has reached. */
export async function sealedFor(host: Host, candidate: string): Promise<boolean> {
  const state = await host.authorityState();
  return state.kind === "sealed" && state.candidate === candidate;
}

/** Whether any process of a group is left. macOS answers EPERM while the only members left are exiting. */
function groupAlive(group: number): boolean {
  try { process.kill(-group, 0); return true; } catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
}

/**
 * Kills a command and everything it started, as a crash of its host does. It
 * returns once the whole group is gone: the operator script a command started
 * holds the state directory's writer lock until it has died too.
 */
export async function crash(running: Running): Promise<void> {
  const group = running.child.pid;
  if (group !== undefined) try { process.kill(-group, "SIGKILL"); } catch { /* It already ended. */ }
  await running.done;
  if (group !== undefined) await until(() => !groupAlive(group), "every process the command started has ended");
}
