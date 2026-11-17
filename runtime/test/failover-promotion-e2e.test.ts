import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { Type } from "typebox";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxToolCall } from "@earendil-works/pi-ai";
import { createRegistry, defineExtension, defineTool } from "@earendil-works/pi-durable";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { NotificationDeliveries } from "../src/notifications.js";
import { exists, HOLDERS, replicatedPair, until, World, type EnrolledReceipt, type Host, type PromotedReceipt, type ReleasedReceipt,
  type StatusReceipt } from "./fixtures/failover-hosts.js";
import { claimStart, commitOutsideTheLog, openOwner, tables } from "./fixtures/failover-state.js";
import { fixtureModel } from "./model.js";

const [OWNER, STANDBY] = HOLDERS;
const STATEMENT = "Invented: the old host lost power at 09:14, and \"nobody\" can reach it";
const FEEDBACK = "feedback/bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb.json";
const held = (state: string) => exists(join(state, "restore-hold.json"));

/** The owner claims a start, begins a tool call that never returns, and claims a phone notification it never finishes. */
async function unfinishedEffects(owner: Host): Promise<{ epoch: number; callId: string }> {
  const claimed = await claimStart(owner.link, owner.holder);
  assert.ok(claimed.result === "accepted" && claimed.state.kind === "active");
  let begin = () => {};
  const started = new Promise<void>((resolve) => { begin = resolve; }), registry = createRegistry();
  registry.install(defineExtension({ name: "garden", tools: [defineTool({ name: "hold", description: "Wait until the coordinator stops", parameters: Type.Object({}),
    async execute(_args, _api, toolContext) {
      begin();
      await new Promise((resolve) => toolContext.abortSignal?.addEventListener("abort", resolve, { once: true }));
      return {};
    } })] }));
  const opened = await openOwner(owner.state, owner.link, { holder: owner.holder, epoch: claimed.state.epoch, registry });
  // The production coordinator made this root conversation without a model, and a root that exists keeps its agent.
  await opened.root.configure({ model: { provider: fixtureModel.provider, modelId: fixtureModel.model_id } }, BACKGROUND_CONTEXT);
  const call = fauxToolCall("hold", {});
  opened.faux.setResponses([fauxAssistantMessage([call], { stopReason: "toolUse" })]);
  await opened.root.submit({ type: "input", content: "Hold the gate.", requestId: "request-hold" }, BACKGROUND_CONTEXT);
  await started;
  await opened.harness.commit(async (tx) => {
    (await tx.doc(NotificationDeliveries, "invented-delivery-key", null)).delivery = { installation_id: "invented-installation", generation: "invented-generation",
      conversation_id: "1", entry_id: "7", apns_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc", state: "attempting", status: null, attempts: 1, retry_at: null, expires_at: 4_102_444_800_000 };
  }, BACKGROUND_CONTEXT);
  await opened.harness.close(BACKGROUND_CONTEXT);
  return { epoch: claimed.state.epoch, callId: call.id };
}

test("promotion moves ownership to a standby only on stop evidence", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);
  const fenced = await world.runtimeWith(fileURLToPath(new URL("./fixtures/failover-fenced-bridge.js", import.meta.url)));

  await t.test("a stale --replace-epoch is refused and changes nothing", async () => {
    const { owner, standby, epoch } = await replicatedPair(world);
    const record = await owner.record(), before = tables(standby.state);
    const refused = await standby.failover("promote", "--replace-epoch", String(epoch - 1));
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, new RegExp(`holder ${OWNER} owns it at epoch ${epoch}`));
    assert.deepEqual(await owner.record(), record);
    assert.deepEqual(tables(standby.state), before);
    assert.equal(await held(standby.state), true);
  });

  await t.test("a wait that ends is no evidence, and the old host's release is", async () => {
    const { coordinator, owner, standby, epoch: before, head } = await replicatedPair(world);
    const alive = owner.serve({ runtime: fenced });
    await until(() => exists(join(owner.state, "agent.sock")), "the old owner serves, with a stand-in for Pi that never reads the seal");
    const epoch = before + 1;
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch, holder: OWNER, head }, "the old owner's start claimed the next epoch");
    const waited = await standby.failover("promote", "--replace-epoch", String(epoch), "--wait", "1");
    assert.notEqual(waited.code, 0);
    assert.match(waited.stderr, /gave no stop evidence within 1 seconds/);
    assert.match(waited.stderr, /beep-boop failover release/);
    assert.match(waited.stderr, /--old-owner-stopped/);
    const sealed = { kind: "sealed", epoch, holder: OWNER, candidate: STANDBY, head };
    assert.deepEqual(await owner.authorityState(), sealed, "the record stays sealed when the wait ends");
    assert.equal(await held(standby.state), true);

    const locked = await owner.failover("release");
    assert.notEqual(locked.code, 0);
    assert.match(locked.stderr, /Another agent process owns this state directory/);
    assert.deepEqual(await owner.authorityState(), sealed);
    alive.child.kill("SIGINT");
    await alive.done;

    assert.deepEqual(await owner.receipt<ReleasedReceipt>("release"), { coordinator_id: coordinator, epoch, evidence: "lock_held", candidate: STANDBY, posted: true });
    assert.deepEqual(await owner.authorityState(), { kind: "vacant", epoch, candidate: STANDBY, evidence: { kind: "lock_held" }, head });

    const promoted = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch));
    assert.deepEqual(promoted, { coordinator_id: coordinator, holder: STANDBY, epoch: epoch + 1, sealed_head: head, evidence: { kind: "lock_held" },
      missing_credentials: ["auth.json", "[apns]"], unfinished_tools: [], unfinished_deliveries: [], unreadable: [] });
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: STANDBY, head });
    assert.equal(await held(standby.state), false, "promotion removes the restore hold");
    assert.deepEqual(tables(standby.state), tables(owner.state));

    const claim = await claimStart(owner.link, OWNER);
    assert.equal(claim.result, "refused", "the old holder's claim is refused");
    const again = await owner.failover("release");
    assert.notEqual(again.code, 0);
    assert.match(again.stderr, new RegExp(`holder ${STANDBY} owns it at epoch ${epoch + 1}`));
    const returned = await owner.serve().done;
    assert.equal(returned.code, OWNER_FENCED_EXIT, returned.stderr);
    assert.match(returned.stderr, new RegExp(`holder ${STANDBY} owns it at epoch ${epoch + 1}`));
    assert.equal(await exists(join(owner.state, "agent.sock")), false, "the old host binds no socket");

    const rerun = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch));
    assert.equal(rerun.epoch, epoch + 1, "a rerun by the new owner changes nothing");
    assert.equal(rerun.evidence, null);
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: STANDBY, head });
  });

  await t.test("a statement promotes away from a host that does not answer, and the report names what the old epoch left unfinished", async () => {
    const { coordinator, owner, standby } = await replicatedPair(world);
    const { epoch, callId } = await unfinishedEffects(owner);
    const head = (await owner.authorityState()).head;
    await writeFile(join(standby.state, "auth.json"), JSON.stringify({ invented: { type: "api_key", key: "invented-not-a-credential" } }), { mode: 0o600 });

    const promoted = await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.deepEqual(promoted, { coordinator_id: coordinator, holder: STANDBY, epoch: epoch + 1, sealed_head: head,
      evidence: { kind: "operator_attested", statement: STATEMENT }, missing_credentials: ["[apns]"],
      unfinished_tools: [{ conversation_id: "1", tool: "hold", call_id: callId, replay_safe: false }],
      unfinished_deliveries: [{ conversation_id: "1", entry_id: "7", installation_id: "invented-installation", apns_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc" }],
      unreadable: [] });
    assert.deepEqual((await standby.receipt<StatusReceipt>("status")).record?.state, { kind: "active", epoch: epoch + 1, holder: STANDBY, head });
    assert.deepEqual(tables(standby.state), tables(owner.state));
  });

  await t.test("a standby whose replicated file is damaged is not activated", async () => {
    const { owner, standby, epoch, head } = await replicatedPair(world);
    await standby.receipt("follow", "--once");
    await writeFile(join(standby.state, FEEDBACK), "Invented damage");
    const refused = await standby.failover("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, new RegExp(`${FEEDBACK.replaceAll(".", "\\.")} in .* does not match the record the log holds for it`));
    assert.deepEqual(await owner.authorityState(),
      { kind: "vacant", epoch, candidate: STANDBY, evidence: { kind: "operator_attested", statement: STATEMENT }, head }, "nobody was activated");
    assert.equal(await held(standby.state), true);

    const back = await owner.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch));
    assert.equal(back.holder, OWNER, "the old owner can still take ownership back");
    assert.deepEqual(await owner.authorityState(), { kind: "active", epoch: epoch + 1, holder: OWNER, head });
  });

  await t.test("a standby whose session database holds a commit that the log lacks is not activated", async () => {
    const { owner, standby, epoch, head } = await replicatedPair(world);
    await standby.receipt("follow", "--once");
    await commitOutsideTheLog(standby.state, "never logged");
    const refused = await standby.failover("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.notEqual(refused.code, 0, "the promotion activated a standby that holds a commit the log lacks");
    assert.match(refused.stderr, /is at Pi sequence \d+, and the log is at Pi sequence \d+, which entry \d+ records/);
    assert.match(refused.stderr, /`beep-boop failover join --replace`/);
    assert.deepEqual(await owner.authorityState(),
      { kind: "vacant", epoch, candidate: STANDBY, evidence: { kind: "operator_attested", statement: STATEMENT }, head }, "nobody was activated");

    const back = await owner.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch));
    assert.equal(back.holder, OWNER, "the old owner can still take ownership back");
  });

  await t.test("a standby at a checkpoint that no batch follows is checked against the checkpoint's Pi sequence", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER), standby = await world.host(coordinator, STANDBY);
    await owner.create();
    const { epoch } = await owner.receipt<EnrolledReceipt>("enroll");
    await standby.receipt("join", coordinator);
    await commitOutsideTheLog(standby.state, "never logged");
    const refused = await standby.failover("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.notEqual(refused.code, 0, "the promotion activated a standby that holds a commit the log lacks");
    assert.match(refused.stderr, /is at Pi sequence \d+, and the log is at Pi sequence \d+, which its checkpoint records/);
    assert.deepEqual(await owner.authorityState(),
      { kind: "vacant", epoch, candidate: STANDBY, evidence: { kind: "operator_attested", statement: STATEMENT }, head: 0 }, "nobody was activated");
  });

  await t.test("the report a person reads carries the statement word for word and what to do next", async () => {
    const { coordinator, standby, epoch, head } = await replicatedPair(world);
    const report = await standby.plain("promote", "--replace-epoch", String(epoch), "--old-owner-stopped", STATEMENT);
    assert.ok(report.includes(`Holder ${STANDBY} owns coordinator ${coordinator} at epoch ${epoch + 1}. The sealed log head is ${head}.`), report);
    assert.ok(report.includes(`Stop evidence: the operator stated: ${STATEMENT}`), report);
    assert.ok(report.includes("This host lacks credentials that do not replicate: auth.json, [apns]."), report);
    assert.ok(report.includes("Start the coordinator with `beep-boop serve`."), report);
    const status = await standby.plain("status");
    assert.ok(status.includes(`Coordinator ${coordinator} is active at epoch ${epoch + 1}, owned by holder ${STANDBY}. The log head is ${head}`), status);
    assert.ok(status.includes(`holds the log through position ${head}.`), status);
  });

  await t.test("a sealed holder that restarts releases by itself and exits 75", async () => {
    const { owner, standby, epoch, head } = await replicatedPair(world);
    assert.notEqual((await standby.failover("promote", "--replace-epoch", String(epoch), "--wait", "0")).code, 0);
    const restarted = await owner.serve().done;
    assert.equal(restarted.code, OWNER_FENCED_EXIT, restarted.stderr);
    assert.match(restarted.stderr, /Told the failover authority that no process of this coordinator is alive/);
    assert.equal(await exists(join(owner.state, "agent.sock")), false);
    assert.deepEqual(await owner.authorityState(), { kind: "vacant", epoch, candidate: STANDBY, evidence: { kind: "lock_held" }, head });
    assert.equal((await standby.receipt<PromotedReceipt>("promote", "--replace-epoch", String(epoch))).epoch, epoch + 1);
  });
});
