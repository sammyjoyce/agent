import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { appendFile, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { isDeepStrictEqual } from "node:util";
import type { FailoverSession } from "../src/generated/FailoverSession.js";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { coordinatorWorld } from "./fixtures/coordinator-world.js";
import { failoverCoordinator } from "./fixtures/failover-bridge.js";
import { commands } from "./fixtures/failover-fault-proxy.js";
import { enroll, follow, logBatches, loggedFiles, OWNER, retainedFiles, STANDBY, stateDirectory, tables } from "./fixtures/failover-state.js";
import { floorFile } from "./fixtures/owner-floor.js";

/**
 * A runtime directory laid out as an installation's is: the Pi child's entry
 * with the built `failover/helper.js` beside it, where Rust looks for it. The
 * entry is the fixture that replaces only the model provider.
 */
async function runtimeBesideBuiltHelper(t: TestContext): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-failover-runtime-"));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await symlink(fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), join(directory, "coordinator-runtime.js"));
  await symlink(fileURLToPath(new URL("../src/failover", import.meta.url)), join(directory, "failover"));
  return join(directory, "coordinator-runtime.js");
}

test("serve with a [failover] section claims its epoch, logs an input and a feedback capture, matches a standby, and exits 75 when promoted away", { timeout: 120_000 }, async (t) => {
  const authority = await failoverCoordinator(t);
  assert.equal(await enroll(authority.owner), 1);
  const session = JSON.parse(await authority.session(OWNER)) as FailoverSession;
  const world = await coordinatorWorld(t, async (homes) => {
    await writeFile(join(homes[0], "state", "coordinator-id"), authority.id, { mode: 0o600 });
    await appendFile(join(homes[0], "agent.toml"), `[failover]\nurl = "${session.url}"\nholder = "${OWNER}"\ntoken_file = "${session.token_file}"\n`);
  }, await runtimeBesideBuiltHelper(t));
  const { homes, server, until } = world, state = join(homes[0], "state");

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

  const feedback = randomUUID();
  const captured = await world.exchange({ type: "feedback", description: "Invented report about a garden", input_id: feedback, context: {
    origin_host_id: "33333333-3333-4333-8333-333333333333", cwd: homes[0], conversation_id: null, task_id: null, agent_id: null, model: DEFAULT_MODEL,
    binding: null, draft: "", queued_inputs: [], client_errors: [] } });
  assert.ok(captured.some((event) => event.type === "input_accepted" && event.input_id === feedback), JSON.stringify(captured));
  assert.deepEqual([...(await loggedFiles(authority.standby)).keys()].sort(), [`feedback/${feedback}.json`, "feedback/latest"]);

  const standby = await stateDirectory(t);
  let compared = "";
  await until(async () => {
    const head = await follow(standby, authority.standby);
    try {
      const owner = { tables: tables(state), files: await retainedFiles(state) }, follower = { tables: tables(standby), files: await retainedFiles(standby) };
      compared = `at log position ${head}, the owner holds ${JSON.stringify(owner)} and the standby holds ${JSON.stringify(follower)}`;
      return isDeepStrictEqual(follower, owner);
    } catch (error) {
      if (error instanceof Error && /database is locked/.test(error.message)) return false;
      throw error;
    }
  }, "A standby that follows the log must hold the owner's tables and retained files", () => compared);
  assert.deepEqual(Object.keys(await retainedFiles(standby)).sort(), [`feedback/${feedback}.json`, "feedback/latest"]);

  const sealed = Date.now();
  assert.equal((await authority.standby.command({ op: "promote", candidate: STANDBY, expected_epoch: 2, attestation: null })).result, "accepted");
  const code = await Promise.race([server.exited, new Promise<string>((resolve) => setTimeout(() => resolve("still running"), 15_000).unref())]);
  assert.equal(code, OWNER_FENCED_EXIT, server.errors().slice(-2000));
  assert.ok(Date.now() - sealed < 12_000, `serve left ${Date.now() - sealed} ms after the seal`);
  assert.match(server.errors(), /the failover authority fenced this coordinator's epoch/);
});
