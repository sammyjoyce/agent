import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { pidsMatching } from "./fixtures/coordinator-world.js";
import { commands, latch, type FaultRule } from "./fixtures/failover-fault-proxy.js";
import { STANDBY } from "./fixtures/failover-state.js";
import { admissions, answers, failoverWorld, REDIRECTED_WORKER_LIMIT, type CoordinatorHost, type FailoverWorld } from "./fixtures/failover-world.js";

const STATEMENT = "Invented: the old host stopped answering at 09:14";
type Match = NonNullable<FaultRule["match"]>;

const APPEND_MARK = "const fs=require('node:fs');fs.appendFileSync(process.env.HOME+'/effects',JSON.stringify({marker:process.argv[1]})+'\\n');";
/** A command on the worker that appends one ledger line that carries `marker`. */
const mark = (world: FailoverWorld, marker: string): ModelStep =>
  ({ tool: "exec", args: { host: world.worker.nodeId, program: process.execPath, args: ["-e", APPEND_MARK, marker] } });
/** The same command, which then stays running until the file `release` exists, so its receipt is still to come. */
const markAndHold = (world: FailoverWorld, marker: string, release: string): ModelStep => ({ tool: "exec", args: { host: world.worker.nodeId, program: process.execPath,
  timeout_seconds: 60, args: ["-e", APPEND_MARK + "(async()=>{while(!fs.existsSync(process.argv[2]))await new Promise(r=>setTimeout(r,20));process.stdout.write('released')})()", marker, release] } });

/** The confirms after the log holds the tool call whose arguments carry `marker`. The first of them approves its host call. */
function confirmsAfter(marker: string): Match {
  let logged = false;
  return (request) => {
    if (commands("append")(request) && request.body.includes(marker)) logged = true;
    return logged && commands("confirm")(request);
  };
}

const markers = async (world: FailoverWorld) => (await world.ledger()).map((line) => (line as { marker: string }).marker);
const historyText = (events: readonly RuntimeEventKind[]) => events.flatMap((event) => event.type === "history" ? event.messages.map((message) => message.text) : []).join("\n");
const history = async (world: FailoverWorld, host: CoordinatorHost) => historyText(await world.request(host, { type: "read_history", task_id: null, agent_id: null, cursor: null }));

/** An enrolled owner that serves at epoch 2 with the worker linked, and a standby that joined. */
async function linkedPair(world: FailoverWorld) {
  await world.enroll();
  const serving = await world.serve(world.owner);
  world.work();
  await world.online(world.owner, [world.worker.nodeId]);
  await world.join();
  return serving;
}

/** Starts the new owner and points the worker at it, as the operator does after a promotion. */
async function succeed(world: FailoverWorld): Promise<void> {
  await world.serve(world.standby);
  await world.direct(world.standby);
  await world.redirected(world.standby);
}

/**
 * A client that reconnects to the new owner resubmits the input it has no answer for. The main conversation needs
 * that client before it continues a turn, as it does after any restart.
 */
async function recovered(world: FailoverWorld, text: string, input: string, answer: string): Promise<void> {
  const { standby } = world;
  await world.until(async () => (await world.send(standby, text, { id: input })).some((event) => event.type === "input_accepted" && event.work?.type === "completed"),
    "The new owner must finish the turn it recovered");
  assert.ok((await history(world, standby)).includes(answer), "the new owner's history holds the turn's answer");
  assert.equal(await world.logged(input), 1, "the resubmitted input was admitted once, by the old owner");
}

function alive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

test("an owner the authority no longer answers, or has replaced, starts no effect", { timeout: 180_000 }, async (t) => {
  await t.test("an old owner partitioned from the authority, still linked to a worker, accepts no new input and sends no host call", async (t) => {
    const world = await failoverWorld(t), { owner, worker } = world;
    await linkedPair(world);
    await world.script("fixture-before-partition", [mark(world, "before-partition"), { text: "Ran before the partition." }]);
    assert.deepEqual(answers(await world.send(owner, "fixture-before-partition")), ["Ran before the partition."]);
    assert.deepEqual(await markers(world), ["before-partition"]);

    // The tool call is in the log when the partition begins, so only the gate stands between it and the worker.
    const partitioned = confirmsAfter("logged-then-partitioned");
    let cut = false;
    owner.proxy.inject({ fault: { kind: "blackhole" }, match: (request) => cut ||= partitioned(request) });
    await world.script("fixture-logged-call", [mark(world, "logged-then-partitioned"), { text: "Ran after the partition healed." }]);
    const logged = world.sending(owner, "fixture-logged-call");
    await world.until(async () => cut, "The owner must ask to confirm before it sends the host call");
    await world.script("fixture-new-input", [mark(world, "sent-while-partitioned"), { text: "Accepted after the partition healed." }]);
    const fresh = world.sending(owner, "fixture-new-input");
    const unanswered = () => owner.proxy.seen.filter((request) => !request.forwarded);
    await world.until(async () => unanswered().some((request) => commands("append")(request) && request.body.includes(fresh.id)), "The owner must offer the new input to the authority");
    await world.online(owner, [worker.nodeId]);
    assert.equal(admissions(fresh.events, fresh.id), 0, "no new input is accepted while the owner is partitioned");
    assert.equal(world.saved(owner, fresh.id), 0);
    assert.deepEqual(await markers(world), ["before-partition"], "the worker ran nothing for the partitioned owner");

    owner.proxy.heal();
    // The new input joins the turn the first one opened, so one client can see both answers.
    const answered = [...answers(await logged.done), ...answers(await fresh.done)];
    for (const answer of ["Ran after the partition healed.", "Accepted after the partition healed."]) assert.ok(answered.includes(answer), JSON.stringify(answered));
    assert.equal(admissions(fresh.events, fresh.id), 1, "the input is accepted once after the authority returned");
    assert.deepEqual((await markers(world)).sort(), ["before-partition", "logged-then-partitioned", "sent-while-partitioned"], "each command ran once after the authority returned");
  });

  await t.test("an old owner suspended across a promotion, then resumed, commits nothing, sends no host call and exits 75", async (t) => {
    const world = await failoverWorld(t), { owner } = world;
    const serving = await linkedPair(world);
    const approval = latch();
    owner.proxy.inject({ fault: { kind: "hold", release: approval.released }, match: confirmsAfter("asked-then-suspended") });
    await world.script("fixture-suspended", [mark(world, "asked-then-suspended"), { text: "A replaced owner must not answer." }]);
    const sent = world.sending(owner, "fixture-suspended");
    // Any confirm is unforwarded while it is on its way, so the wait names the one the proxy holds: the first after the tool call was logged.
    await world.until(async () => owner.proxy.seen.some((request) => commands("confirm")(request) && !request.forwarded && confirmedAfterMarker(owner, "asked-then-suspended", request)),
      "The owner must ask to confirm before it sends the host call");
    world.suspend(owner);
    const before = world.tables(owner);
    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.deepEqual({ holder: promoted.holder, epoch: promoted.epoch }, { holder: STANDBY, epoch: 3 });

    world.resume(owner);
    approval.release();
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.deepEqual(world.tables(owner), before, "the resumed owner committed nothing");
    assert.deepEqual(await markers(world), [], "the resumed owner sent no host call");
    assert.deepEqual(answers(sent.events), []);
  });

  await t.test("an old owner suspended after an approval and before its dispatch runs the command once, and the new owner reports it and does not repeat it", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world;
    const serving = await linkedPair(world);
    const approval = latch();
    owner.proxy.inject({ fault: { kind: "reply-late", release: approval.released }, times: 1, match: confirmsAfter("approved-then-suspended") });
    await world.script("fixture-approved", [mark(world, "approved-then-suspended"), { text: "The new owner finished the turn." }]);
    const sent = world.sending(owner, "fixture-approved");
    await world.until(async () => owner.proxy.seen.some((request) => commands("confirm")(request) && request.forwarded && confirmedAfterMarker(owner, "approved-then-suspended", request)),
      "The authority must approve the host call");
    world.suspend(owner);
    assert.deepEqual(await markers(world), [], "the approval is still on its way");
    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.deepEqual(promoted.unfinished_tools.map(({ replay_safe }) => replay_safe), [false], `the promotion reports the call the old epoch started: ${JSON.stringify(promoted)}`);

    // A command the resumed owner sends, such as a commit Pi deferred or its owner check, would fence it ahead of its dispatch.
    const afterResume = latch();
    owner.proxy.inject({ fault: { kind: "hold", release: afterResume.released }, match: commands() });
    approval.release();
    world.resume(owner);
    await world.until(async () => (await markers(world)).length === 1, "The approval the old owner held releases its one host call");
    afterResume.release();
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));

    await succeed(world);
    await recovered(world, "fixture-approved", sent.id, "The new owner finished the turn.");
    assert.deepEqual(await markers(world), ["approved-then-suspended"], "the new owner did not repeat the command");
    assert.match(await world.lastAsked("fixture-approved"), /Tool exec was interrupted/, "the new owner told the model the call was interrupted");
    assert.equal(await world.asked("fixture-approved"), 2, "the model was asked once by each owner");
  });

  await t.test("a paused old owner holding a worker link: the worker drops the link within its watch and serves the new owner", async (t) => {
    const world = await failoverWorld(t, { watchSeconds: 1 }), { owner, standby } = world;
    const serving = await linkedPair(world);
    await world.script("fixture-old-link", [mark(world, "old-owner"), { text: "The old owner ran its command." }]);
    assert.deepEqual(answers(await world.send(owner, "fixture-old-link")), ["The old owner ran its command."]);
    assert.equal(await world.floor(), 2);

    world.suspend(owner);
    await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    await world.serve(standby);
    await world.direct(standby);
    await world.until(async () => await world.floor() === 4, "The watching worker must raise its floor to the new owner's epoch");
    await world.redirected(standby);
    await world.script("fixture-new-link", [mark(world, "new-owner"), { text: "The new owner ran its command." }]);
    assert.deepEqual(answers(await world.send(standby, "fixture-new-link")), ["The new owner ran its command."]);
    assert.deepEqual(await markers(world), ["old-owner", "new-owner"]);

    world.resume(owner);
    assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
    assert.deepEqual(await markers(world), ["old-owner", "new-owner"], "the resumed owner ran nothing on the worker");
  });

  await t.test("an old owner that is dead: release refuses while a Pi child holds the lock, then succeeds", async (t) => {
    const world = await failoverWorld(t), { owner } = world;
    await world.enroll();
    const serving = await world.serve(owner);
    await world.join();
    const supervisor = serving.child.pid;
    assert.ok(supervisor !== undefined);
    const children = (await pidsMatching(owner.state)).filter((pid) => pid !== supervisor);
    assert.ok(children.length >= 1, "the coordinator has a Pi child");
    // A stopped child does not see its supervisor die, as a child that hangs does not.
    for (const pid of children) process.kill(pid, "SIGSTOP");
    process.kill(supervisor, "SIGKILL");
    await serving.exited;

    const waited = world.promoting({ replaceEpoch: 2, wait: 0 });
    assert.notEqual(await waited.exited, 0);
    assert.match(waited.errors(), /gave no stop evidence/);
    const sealed = (await world.record())?.state;
    assert.equal(sealed?.kind, "sealed");
    const refused = world.launch(owner, ["failover", "release"], "");
    assert.notEqual(await refused.exited, 0);
    assert.match(refused.errors(), /Another agent process owns this state directory/);
    assert.deepEqual((await world.record())?.state, sealed, "a refused release posts no evidence");

    for (const pid of children) process.kill(pid, "SIGKILL");
    await world.until(async () => !children.some(alive), "The Pi child must end");
    assert.equal((await world.release()).evidence, "lock_held");
    const promoted = await world.promote({ replaceEpoch: 2 });
    assert.deepEqual({ holder: promoted.holder, epoch: promoted.epoch, evidence: promoted.evidence }, { holder: STANDBY, epoch: 3, evidence: { kind: "lock_held" } });
  });

  await t.test("a lost worker receipt: the command ran once, and the new owner does not repeat it", async (t) => {
    const world = await failoverWorld(t), { owner, standby } = world, release = join(world.directory, "held-command.release");
    await linkedPair(world);
    await world.script("fixture-lost-receipt", [markAndHold(world, "receipt-lost", release), { text: "The new owner finished without the receipt." }]);
    const input = randomUUID();
    world.sending(owner, "fixture-lost-receipt", { id: input });
    await world.until(async () => (await markers(world)).length === 1, "The command must start on the worker");
    await world.crash(owner);

    const promoted = await world.promote({ replaceEpoch: 2, statement: STATEMENT });
    assert.deepEqual(promoted.unfinished_tools.map(({ replay_safe }) => replay_safe), [false], `the promotion reports the call that has no result: ${JSON.stringify(promoted)}`);
    await succeed(world);
    await recovered(world, "fixture-lost-receipt", input, "The new owner finished without the receipt.");
    await writeFile(release, "A command whose owner died must stay cancelled.");
    assert.deepEqual(await markers(world), ["receipt-lost"], "the command has one ledger line");
    assert.match(await world.lastAsked("fixture-lost-receipt"), /Tool exec was interrupted/, "the new owner told the model the call was interrupted");
    assert.equal(await world.asked("fixture-lost-receipt"), 2, "the model was asked once by each owner");
    assert.equal(world.saved(standby, input), 1);
  });
});

/** Whether `confirm` reached the proxy after the append that logged the tool call with `marker`. */
function confirmedAfterMarker(host: CoordinatorHost, marker: string, confirm: FailoverWorld["owner"]["proxy"]["seen"][number]): boolean {
  const { seen } = host.proxy;
  return seen.slice(0, seen.indexOf(confirm)).some((request) => commands("append")(request) && request.body.includes(marker));
}

test("a worker that dialed a paused old owner stops waiting for it and serves the new owner once its address moves", { timeout: 180_000 }, async (t) => {
  const world = await failoverWorld(t, { watchSeconds: 1 }), { owner, standby } = world;
  const serving = await linkedPair(world);
  world.suspend(owner);
  await world.promote({ replaceEpoch: 2, statement: STATEMENT });
  await world.serve(standby);
  await world.until(async () => world.worker.daemon?.errors().includes("The coordinator did not answer this worker's registration") === true,
    "The worker must stop waiting for the paused old owner", undefined, REDIRECTED_WORKER_LIMIT);
  await world.direct(standby);
  await world.redirected(standby);
  await world.script("fixture-after-wait", [mark(world, "new-owner"), { text: "The new owner ran its command." }]);
  assert.deepEqual(answers(await world.send(standby, "fixture-after-wait")), ["The new owner ran its command."]);

  world.resume(owner);
  assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
  assert.deepEqual(await markers(world), ["new-owner"], "the resumed owner ran nothing on the worker");
});
