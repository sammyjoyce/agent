import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { protocolLines } from "../src/protocol.js";
import { pidsMatching } from "./fixtures/coordinator-world.js";
import { exists, HOLDERS, ownerActivity, replicatedPair, until, World, type EnrolledReceipt, type FollowedReceipt, type JoinedReceipt,
  type PromotedReceipt, type Running } from "./fixtures/failover-hosts.js";
import { tables } from "./fixtures/failover-state.js";

const STANDBY = HOLDERS[1];
const STATEMENT = "Invented: the owner host is powered off";
const socketOf = (state: string) => join(state, "agent.sock");

const accepts = (path: string) => new Promise<boolean>((resolve) => {
  const channel = createConnection(path);
  channel.once("connect", () => { channel.destroy(); resolve(true); }).once("error", () => resolve(false));
});

async function servesBeforeItEnds(running: Running, state: string): Promise<boolean> {
  let ended = false;
  void running.done.then(() => { ended = true; });
  let serving = false;
  await until(async () => ended || (serving = await accepts(socketOf(state))), "serve answers on its socket or ends", 30_000);
  return serving;
}

/** A coordinator that a client command starts outlives the command, in a session of its own. */
async function stopCoordinatorsOn(state: string): Promise<void> {
  const started = () => pidsMatching(`--state-dir ${state} `);
  for (const pid of await started()) try { process.kill(pid, "SIGINT"); } catch { /* It already ended. */ }
  await until(async () => (await started()).length === 0, "every coordinator on the state directory has ended", 30_000);
}

async function upload(state: string): Promise<string> {
  const channel = createConnection({ path: socketOf(state) }), bytes = Buffer.from("Invented upload sent to a replaced owner"), answers: string[] = [];
  try {
    channel.write(JSON.stringify({ type: "attachment", request: { type: "upload", id: randomUUID(), name: "invented.txt", media_type: "text/plain",
      size_bytes: bytes.length, offset: 0, data_base64: bytes.toString("base64"), complete: true } }) + "\n");
    for await (const line of protocolLines(channel)) {
      answers.push(line);
      if ((JSON.parse(line) as { type: string }).type === "done") break;
    }
  } finally { channel.destroy(); }
  return answers.join("\n");
}

const refusal = (position: number) =>
  new RegExp(`is a replicated state directory: it holds its coordinator's failover log through position ${position}\\..*\\[failover\\] section`, "s");

test("a replicated state directory opens only under a claim, whatever the config says", { timeout: 240_000 }, async (t) => {
  const world = await World.start(t);

  await t.test("a client command on a standby, with a config that has no [failover] section, starts no coordinator there", async () => {
    const { standby } = await replicatedPair(world);
    const { applied } = await standby.receipt<FollowedReceipt>("follow", "--once");
    const before = tables(standby.state);

    const status = await standby.clientWithoutFailover("status");
    const served = await accepts(socketOf(standby.state));
    await stopCoordinatorsOn(standby.state);

    assert.equal(served, false, `a coordinator served the standby's state directory, and status printed: ${status.stdout}`);
    assert.notEqual(status.code, 0, status.stdout);
    assert.match(status.stderr, /The local coordinator exited/);
    assert.match(await readFile(join(standby.state, "coordinator.log"), "utf8"), refusal(applied));
    assert.equal(await exists(socketOf(standby.state)), false, "a start that was refused leaves no socket");
    assert.deepEqual(tables(standby.state), before, "the standby's session database holds no commit that the log lacks");
    assert.equal((await standby.receipt<FollowedReceipt>("follow", "--once")).applied, applied, "the standby still follows the log");
  });

  await t.test("an owner that only enrolled and a standby that only joined hold the log through position 0 and serve nothing without a [failover] section", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, HOLDERS[0]), standby = await world.host(coordinator, STANDBY);
    await owner.create();
    await owner.receipt<EnrolledReceipt>("enroll");
    await standby.receipt<JoinedReceipt>("join", coordinator);
    for (const host of [owner, standby]) {
      const before = tables(host.state), started = host.serve({ failover: false });
      const served = await servesBeforeItEnds(started, host.state);
      if (served) started.child.kill("SIGINT");
      const ended = await started.done;
      assert.equal(served, false, `a coordinator served ${host.state} without a claim`);
      assert.notEqual(ended.code, 0, ended.stderr);
      assert.match(ended.stderr, refusal(0));
      assert.deepEqual(tables(host.state), before, "a start that was refused changes nothing in the session database");
    }
  });

  await t.test("after a start without a [failover] section on a standby, its promotion leaves a log that the old host applies as a standby", async () => {
    const { coordinator, owner, standby, epoch } = await replicatedPair(world);
    await standby.receipt<FollowedReceipt>("follow", "--once");
    const started = standby.serve({ failover: false });
    if (await servesBeforeItEnds(started, standby.state)) started.child.kill("SIGINT");
    await started.done;

    const promoted = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.equal(promoted.epoch, epoch + 1);
    await ownerActivity(standby, ["after promotion"]);
    await owner.receipt<JoinedReceipt>("join", coordinator, "--replace");
    const followed = await owner.failover("follow", "--once");
    assert.equal(followed.code, 0, `the old host, rebuilt as a standby, cannot apply the new owner's log: ${followed.stderr}`);
    assert.deepEqual(tables(owner.state), tables(standby.state), "the rebuilt standby holds the new owner's tables");
  });

  await t.test("a replaced owner restarted without its [failover] section serves nothing and acknowledges nothing", async () => {
    const { owner, standby, epoch } = await replicatedPair(world);
    const { applied } = await standby.receipt<FollowedReceipt>("follow", "--once");
    const promoted = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    const fenced = await owner.serve().done;
    assert.equal(fenced.code, OWNER_FENCED_EXIT, fenced.stderr);
    const before = tables(owner.state);

    const restarted = owner.serve({ failover: false });
    const served = await servesBeforeItEnds(restarted, owner.state);
    const answered = served ? await upload(owner.state) : "";
    if (served) restarted.child.kill("SIGINT");
    const ended = await restarted.done;

    assert.equal(answered.includes('"uploaded"'), false, `a replaced owner acknowledged an upload that the log and the new owner never hold: ${answered}`);
    assert.equal(served, false, "a replaced owner served its state directory");
    assert.ok(ended.code !== 0 && ended.code !== OWNER_FENCED_EXIT, `serve exited ${ended.code}: ${ended.stderr}`);
    assert.match(ended.stderr, refusal(applied));
    assert.equal(await exists(socketOf(owner.state)), false, "a start that was refused leaves no socket");
    assert.deepEqual(tables(owner.state), before, "a start that was refused changes nothing in the session database");
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: promoted.epoch, holder: STANDBY, head: promoted.sealed_head });
  });
});
