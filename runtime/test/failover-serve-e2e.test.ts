import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { appendFile, mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import type { AuthorityRecord } from "../src/generated/AuthorityRecord.js";
import type { FailoverSession } from "../src/generated/FailoverSession.js";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { coordinatorWorld, type OwnedProcess } from "./fixtures/coordinator-world.js";
import { failoverCoordinator } from "./fixtures/failover-bridge.js";
import { commands } from "./fixtures/failover-fault-proxy.js";
import { logBatches, loggedFiles, OWNER, retainedFiles, STANDBY, tables } from "./fixtures/failover-state.js";
import { floorFile } from "./fixtures/owner-floor.js";

const SERVE = ["serve", "--local-only", "--no-sources"];

/**
 * A runtime directory laid out as an installation's is: the Pi child's entry
 * with the built `failover` scripts and the database script beside it, where
 * Rust looks for them. The entry is the fixture that replaces only the model
 * provider.
 */
async function runtimeBesideBuiltScripts(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-runtime-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await symlink(fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), join(directory, "coordinator-runtime.js"));
  await symlink(fileURLToPath(new URL("../src/failover", import.meta.url)), join(directory, "failover"));
  await symlink(fileURLToPath(new URL("../src/backup-database.js", import.meta.url)), join(directory, "backup-database.js"));
  return join(directory, "coordinator-runtime.js");
}

const isSocket = (path: string) => stat(path).then((entry) => entry.isSocket(), () => false);

test("a coordinator enrolls, serves as the replicated owner, and hands over to a standby that joined, followed and promoted", { timeout: 120_000 }, async (t) => {
  const authority = await failoverCoordinator(t), runtime = await runtimeBesideBuiltScripts(t);
  const world = await coordinatorWorld(t, async (homes) => {
    await writeFile(join(homes[0], "state", "coordinator-id"), authority.id, { mode: 0o600 });
  }, runtime);
  const { homes, until } = world, state = join(homes[0], "state");
  const failover = async (holder: string) => {
    const session = JSON.parse(await authority.session(holder)) as FailoverSession;
    return `[failover]\nurl = "${session.url}"\nholder = "${holder}"\ntoken_file = "${session.token_file}"\n`;
  };
  /** Runs one `beep-boop failover` command to its end and returns its receipt. */
  async function receipt<T>(running: OwnedProcess): Promise<T> {
    assert.equal(await running.exited, 0, running.errors());
    return JSON.parse(running.output()) as T;
  }

  world.server.child.kill("SIGINT");
  assert.equal(await world.server.exited, 0, "the coordinator without failover made the state directory and stopped");
  await appendFile(join(homes[0], "agent.toml"), await failover(OWNER));
  const enrolled = await receipt<{ epoch: number; checkpoint: { through: number } }>(world.start(0, ["failover", "enroll"], ""));
  assert.deepEqual({ epoch: enrolled.epoch, through: enrolled.checkpoint.through }, { epoch: 1, through: 0 });

  const owner = world.start(0, SERVE);
  await until(() => isSocket(world.socket), "The replicated owner must bind its socket");
  const claimed = (await authority.reader.record())?.state;
  assert.deepEqual({ kind: claimed?.kind, epoch: claimed?.epoch, holder: claimed?.kind === "active" ? claimed.holder : undefined },
    { kind: "active", epoch: 2, holder: OWNER }, "serve claimed the epoch after the enrollment's before it bound its socket");
  assert.equal(authority.proxy.seen.filter(commands("claim")).length, 1, "the built helper sent one claim to the Worker");
  await until(async () => await readFile(floorFile(homes[1], authority.id), "utf8").catch(() => "") === "2\n", "A worker the owner links must be told epoch 2");

  await world.script("fixture-replicated-serve", [{ text: "The replicated coordinator answered." }]);
  const answered = await world.cli(0, ["chat", "fixture-replicated-serve"]);
  assert.ok(answered.some((event) => event.type === "answer" && event.text === "The replicated coordinator answered."), JSON.stringify(answered));
  const batches = await logBatches(authority.standby);
  assert.ok(batches.some((batch) => batch.some((write) => write.type === "submission")
    && batch.some((write) => write.type === "entry" && JSON.stringify(write.value).includes("fixture-replicated-serve"))), "one logged batch admits the input");
  assert.ok(batches.flat().some((write) => write.type === "entry" && JSON.stringify(write.value).includes("The replicated coordinator answered.")),
    "a logged batch holds the answer");

  const feedback = randomUUID(), captured = [`feedback/${feedback}.json`, "feedback/latest"];
  const accepted = await world.exchange({ type: "feedback", description: "Invented report about a garden", input_id: feedback, context: {
    origin_host_id: "33333333-3333-4333-8333-333333333333", cwd: homes[0], conversation_id: null, task_id: null, agent_id: null, model: DEFAULT_MODEL,
    binding: null, draft: "", queued_inputs: [], client_errors: [] } });
  assert.ok(accepted.some((event) => event.type === "input_accepted" && event.input_id === feedback), JSON.stringify(accepted));
  assert.deepEqual([...(await loggedFiles(authority.standby)).keys()].sort(), captured);

  const second = join(world.directory, "standby"), standbyState = join(second, "state");
  await mkdir(second, { mode: 0o700 });
  await writeFile(join(second, "AGENTS.md"), "Use only invented test data.\n");
  await writeFile(join(second, "agent.toml"), `node_name = "standby"\n${await failover(STANDBY)}`);
  const onStandby = (...command: string[]) => world.start(0, ["--state-dir", standbyState, "--config", join(second, "agent.toml"), "--runtime", runtime,
    "--instructions", join(second, "AGENTS.md"), ...command], "", { HOME: second, XDG_CONFIG_HOME: join(second, ".config"), XDG_DATA_HOME: join(second, ".local"),
    AGENT_TEST_REX_STATE: join(second, "rex.json") }, true);
  const held = async (directory: string) => ({ tables: tables(directory), files: await retainedFiles(directory) });

  assert.equal((await receipt<{ through: number }>(onStandby("failover", "join", authority.id))).through, 0);
  let compared = "";
  await until(async () => {
    const { applied } = await receipt<{ applied: number }>(onStandby("failover", "follow", "--once"));
    const mine = await held(state), theirs = await held(standbyState);
    compared = `at log position ${applied}, the owner holds ${JSON.stringify(mine)} and the standby holds ${JSON.stringify(theirs)}`;
    return isDeepStrictEqual(theirs, mine);
  }, "A standby that joined and follows must hold the owner's tables and retained files", () => compared);
  assert.deepEqual(Object.keys(await retainedFiles(standbyState)).sort(), captured);

  const sealed = Date.now(), promoting = onStandby("failover", "promote", "--replace-epoch", "2");
  const code = await Promise.race([owner.exited, new Promise<string>((resolve) => setTimeout(() => resolve("still running"), 15_000).unref())]);
  assert.equal(code, OWNER_FENCED_EXIT, owner.errors().slice(-2000));
  assert.ok(Date.now() - sealed < 12_000, `serve left ${Date.now() - sealed} ms after the promotion began`);
  assert.match(owner.errors(), /the failover authority fenced this coordinator's epoch/);
  assert.equal(await isSocket(world.socket), false, "the old owner removed its socket before it left");

  const promoted = await receipt<{ holder: string; epoch: number; sealed_head: number; evidence: unknown }>(promoting);
  assert.deepEqual({ holder: promoted.holder, epoch: promoted.epoch, evidence: promoted.evidence }, { holder: STANDBY, epoch: 3, evidence: { kind: "released" } },
    "the old owner's own release is the stop evidence, with no operator on its host");
  const status = await receipt<{ record: AuthorityRecord | null; applied: number | null }>(onStandby("failover", "status"));
  assert.deepEqual(status.record?.state, { kind: "active", epoch: 3, holder: STANDBY, head: promoted.sealed_head });
  assert.equal(status.applied, promoted.sealed_head);
  assert.deepEqual(await held(standbyState), await held(state), "the new owner holds what the old owner held when it stopped");

  const successor = onStandby(...SERVE), successorSocket = join(standbyState, "agent.sock");
  await until(() => isSocket(successorSocket), "The promoted standby must serve from its own directory", () => successor.errors().slice(-2000));
  const history = await world.exchange({ type: "read_history", task_id: null, agent_id: null, cursor: null }, undefined, successorSocket);
  const messages = history.flatMap((event) => event.type === "history" ? event.messages : []);
  assert.ok(messages.some((message) => message.role === "user" && message.text.includes("fixture-replicated-serve")), JSON.stringify(history));
  assert.ok(messages.some((message) => message.text === "The replicated coordinator answered."), JSON.stringify(history));

  const returned = world.start(0, SERVE);
  assert.equal(await returned.exited, OWNER_FENCED_EXIT, returned.errors());
  assert.match(returned.errors(), new RegExp(`holder ${STANDBY} owns it at epoch 4`));
  assert.equal(await isSocket(world.socket), false, "the replaced owner binds no socket");
});
