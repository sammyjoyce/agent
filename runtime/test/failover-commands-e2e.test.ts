import assert from "node:assert/strict";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import type { CheckpointManifest } from "../src/generated/CheckpointManifest.js";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { blobs, startFaultProxy } from "./fixtures/failover-fault-proxy.js";
import { crash, exists, fingerprint, HOLDERS, ownerActivity, until, World, type EnrolledReceipt, type FollowedReceipt,
  type JoinedReceipt, type StatusReceipt } from "./fixtures/failover-hosts.js";
import { logEntries, retainedFiles, tables } from "./fixtures/failover-state.js";

const [OWNER, STANDBY, THIRD] = HOLDERS;

test("the failover commands enroll an owner and keep a standby of it", { timeout: 120_000 }, async (t) => {
  const world = await World.start(t);

  await t.test("enroll makes the stopped coordinator the owner at epoch 1 with a checkpoint at 0", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER), other = await world.host(coordinator, STANDBY);
    await owner.create();
    const before = tables(owner.state);
    const enrolled = await owner.receipt<EnrolledReceipt>("enroll");
    assert.equal(enrolled.coordinator_id, coordinator);
    assert.equal(enrolled.epoch, 1);
    assert.equal(enrolled.checkpoint.through, 0);
    assert.ok(enrolled.uploaded !== null && enrolled.uploaded.files >= 3, JSON.stringify(enrolled));
    const record = await owner.record();
    assert.deepEqual(record, { state: { kind: "active", epoch: 1, holder: OWNER, head: 0 }, checkpoint: enrolled.checkpoint });
    const { beep_boop_failover: stamped, ...rest } = tables(owner.state);
    assert.deepEqual(stamped, [JSON.stringify({ singleton: 1, position: 0 })]);
    assert.deepEqual(rest, before, "enrollment changes nothing else in the session database");

    const again = await owner.receipt<EnrolledReceipt>("enroll");
    assert.equal(again.uploaded, null, "a second enrollment by the same holder uploads nothing");
    assert.deepEqual(await owner.record(), record);

    const status = await owner.receipt<StatusReceipt>("status");
    assert.deepEqual(status.record, record);
    assert.equal(status.applied, 0);

    await other.create();
    const refused = await other.failover("enroll");
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, new RegExp(`holder ${OWNER} owns it at epoch 1`));
    assert.deepEqual(await owner.record(), record);
    assert.equal(tables(other.state).beep_boop_failover, undefined, "a refused enrollment stamps nothing");
  });

  await t.test("enroll refuses a directory without a coordinator-id and one whose writer lock is held", async () => {
    const coordinator = world.coordinator(), unnamed = await world.host(coordinator, OWNER), running = await world.host(coordinator, STANDBY);
    await mkdir(unnamed.state, { mode: 0o700 });
    const noId = await unnamed.failover("enroll");
    assert.notEqual(noId.code, 0);
    assert.match(noId.stderr, /has no coordinator-id/);

    await running.create();
    const server = running.serve({ failover: false });
    await until(() => exists(join(running.state, "agent.sock")), "the coordinator is running");
    const held = await running.failover("enroll");
    assert.notEqual(held.code, 0);
    assert.match(held.stderr, /Another agent process owns this state directory/);
    server.child.kill("SIGINT");
    await server.done;
    assert.equal(await running.record(), undefined, "neither refusal enrolled the coordinator");
    assert.equal(tables(running.state).beep_boop_failover, undefined);
  });

  await t.test("join builds a held standby from the checkpoint, and follow brings it to the owner's head", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER), standby = await world.host(coordinator, STANDBY);
    await owner.create();
    await owner.receipt<EnrolledReceipt>("enroll");
    const atCheckpoint = tables(owner.state);

    const joined = await standby.receipt<JoinedReceipt>("join", coordinator);
    assert.equal(joined.through, 0);
    assert.equal(joined.replaced, null);
    assert.deepEqual(tables(standby.state), atCheckpoint, "the standby's tables equal the owner's at the checkpoint");
    assert.equal(await readFile(join(standby.state, "coordinator-id"), "utf8"), coordinator);
    assert.equal(await exists(join(standby.state, "restore-hold.json")), true, "a joined standby is held");

    const occupied = await fingerprint(standby.state);
    const refused = await standby.failover("join", coordinator);
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, /is not empty/);
    assert.deepEqual(await fingerprint(standby.state), occupied, "a refused join leaves the target as it was");

    await ownerActivity(owner, ["first", "second"], { "feedback/invented-bundle.json": "Invented feedback bundle", "attachments/invented/content": "Invented attachment" });
    const followed = await standby.receipt<FollowedReceipt>("follow", "--once");
    const head = (await owner.authorityState()).head;
    assert.ok(head >= 4, "the owner logged its notes and its files");
    assert.deepEqual(followed, { coordinator_id: coordinator, from: 0, applied: head });
    assert.deepEqual(tables(standby.state), tables(owner.state));
    assert.deepEqual(await retainedFiles(standby.state), await retainedFiles(owner.state));
    assert.equal(Object.keys(await retainedFiles(standby.state)).length, 2);

    const settled = tables(standby.state);
    assert.deepEqual(await standby.receipt<FollowedReceipt>("follow", "--once"), { coordinator_id: coordinator, from: head, applied: head });
    assert.deepEqual(tables(standby.state), settled, "a second follow applies nothing");

    const polling = standby.start("follow", "--interval", "1");
    await ownerActivity(owner, ["third"]);
    await until(() => { polling.assertRunning(); return JSON.stringify(tables(standby.state)) === JSON.stringify(tables(owner.state)); },
      "the polling follow applies what the owner logs next");
    const second = await standby.failover("follow", "--once");
    assert.notEqual(second.code, 0, "a second follow is refused while the first holds the lock");
    assert.match(second.stderr, /Another agent process owns this state directory/);
    await crash(polling);
  });

  await t.test("nothing that holds a secret leaves the host at enrollment", async (t) => {
    const coordinator = world.coordinator(), proxy = await startFaultProxy(t, world.authorityUrl), owner = await world.host(coordinator, OWNER, proxy.url);
    await owner.create();
    await writeFile(join(owner.state, "auth.json"), JSON.stringify({ invented: { type: "api_key", key: "SENTINEL-INVENTED-CREDENTIAL" } }), { mode: 0o600 });
    await mkdir(join(owner.state, "diagnostics"), { recursive: true });
    await writeFile(join(owner.state, "diagnostics", "invented.jsonl"), "SENTINEL-INVENTED-DIAGNOSTIC\n");
    const enrolled = await owner.receipt<EnrolledReceipt>("enroll");
    await ownerActivity(owner, ["after enrollment"]);

    const manifest = JSON.parse(Buffer.from(await owner.link.getBlob(enrolled.checkpoint.manifest)).toString("utf8")) as CheckpointManifest;
    assert.deepEqual(manifest.files.map((file) => file.path).filter((path) => /auth|diagnostics/.test(path)), []);
    const named = new Set([enrolled.checkpoint.manifest, ...manifest.files.flatMap((file) => file.parts)]);
    const stored = new Set(proxy.seen.filter((request) => request.method === "PUT").map((request) => request.path.split("/").at(-1)));
    assert.deepEqual([...stored].sort(), [...named].sort(), "enrollment stores the checkpoint's parts and its manifest, and no other blob");
    for (const blob of named) {
      const bytes = Buffer.from(await owner.link.getBlob(blob));
      assert.equal(bytes.includes("SENTINEL-INVENTED"), false, `blob ${blob} holds a secret`);
    }
    const entries = await logEntries(owner.link);
    assert.ok(entries.length > 0);
    assert.equal(JSON.stringify(entries).includes("SENTINEL-INVENTED"), false);
    assert.equal(JSON.stringify(proxy.seen.filter((request) => request.method === "POST")).includes("SENTINEL-INVENTED"), false);
  });

  await t.test("an authority that does not answer is a failure that names the request, never a refusal", async (t) => {
    const coordinator = world.coordinator(), proxy = await startFaultProxy(t, world.authorityUrl), owner = await world.host(coordinator, OWNER, proxy.url);
    await owner.create();
    proxy.inject({ fault: { kind: "unavailable" } });
    for (const command of [["status"], ["enroll"], ["release"], ["promote", "--replace-epoch", "1"]]) {
      const run = await owner.failover(...command), label = command.join(" ");
      assert.equal(run.code, 1, `${label}: ${run.stderr}`);
      assert.match(run.stderr, /The fault proxy refused this request/, label);
      assert.equal(run.stdout, "", `${label} prints no receipt`);
    }
    proxy.heal();
    assert.equal(await owner.record(), undefined, "nothing reached the authority");
    assert.equal(tables(owner.state).beep_boop_failover, undefined, "an enrollment that reached nobody stamps nothing");
  });

  await t.test("serve does not start as the replicated owner on a directory that was never stamped, and enroll says how to rebuild it", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER), unstamped = await world.host(coordinator, OWNER);
    await owner.create();
    await owner.receipt<EnrolledReceipt>("enroll");
    await unstamped.create();
    const before = tables(unstamped.state);
    const served = await unstamped.serve().done;
    assert.ok(served.code !== 0 && served.code !== OWNER_FENCED_EXIT, `serve exited ${served.code}: ${served.stderr}`);
    assert.equal(await exists(join(unstamped.state, "agent.sock")), false, "a start that was refused leaves no socket");
    assert.deepEqual(tables(unstamped.state), before, "a start that was refused changes nothing in the session database");
    const refused = await unstamped.failover("enroll");
    assert.notEqual(refused.code, 0);
    assert.match(refused.stderr, /already enrolled coordinator \S+ from another state directory: \S+ holds no log position\. Run `beep-boop failover join --replace`/);
    assert.equal((await unstamped.receipt<StatusReceipt>("status")).applied, null);
  });

  await t.test("status needs the coordinator named when the state directory names none", async () => {
    const coordinator = world.coordinator(), owner = await world.host(coordinator, OWNER), elsewhere = await world.host(coordinator, THIRD);
    await owner.create();
    const unnamed = await elsewhere.failover("status");
    assert.notEqual(unnamed.code, 0);
    assert.match(unnamed.stderr, /--coordinator-id/);
    assert.deepEqual(await elsewhere.receipt<StatusReceipt>("status", "--coordinator-id", coordinator),
      { coordinator_id: coordinator, record: null, state_dir: elsewhere.state, applied: null });
    assert.equal(await exists(elsewhere.state), false, "status creates no state directory");
    assert.deepEqual((await readdir(elsewhere.home)).filter((name) => name.startsWith(".")), []);
  });
});
