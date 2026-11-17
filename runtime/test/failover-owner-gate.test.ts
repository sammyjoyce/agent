import assert from "node:assert/strict";
import { test } from "node:test";
import { AuthorityUnreachable } from "../src/failover/authority-link.js";
import { ConfirmGate } from "../src/failover/owner-gate.js";
import { OwnerFenced } from "../src/failover/replicated-storage.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import { MemoryAuthority } from "./fixtures/failover-memory-authority.js";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { claimStart, enroll, note, openOwner, OWNER, replaceOwner, STANDBY, stateDirectory } from "./fixtures/failover-state.js";
import { until } from "./fixtures/until.js";

function held() {
  let release = () => {};
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

async function gated() {
  const authority = new MemoryAuthority(), epoch = await enroll(authority), fences: OwnerFenced[] = [];
  const gate = new ConfirmGate({ link: authority, holder: OWNER, epoch, onFenced: (error) => fences.push(error) });
  return { authority, epoch, gate, fences };
}

const isConfirm = (command: AuthorityCommand) => command.op === "confirm";

test("the gate opens after one confirm that the authority answers as current owner", async () => {
  const { authority, gate, fences } = await gated();
  let confirms = 0;
  authority.beforeCommand = (command) => { if (isConfirm(command)) confirms += 1; };
  await gate.fresh();
  assert.equal(confirms, 1);
  await gate.fresh();
  assert.equal(confirms, 2, "an earlier answer never opens the gate for a later call");
  assert.deepEqual(fences, []);
});

test("callers that arrive while a confirm is in flight share the next confirm", async () => {
  const { authority, gate } = await gated();
  const first = held(), second = held(), opened: string[] = [];
  let confirms = 0;
  authority.beforeCommand = async (command) => {
    if (!isConfirm(command)) return;
    confirms += 1;
    await (confirms === 1 ? first.promise : second.promise);
  };
  const early = gate.fresh().then(() => opened.push("early"));
  await until(() => confirms === 1, "the first confirm starts");
  const late = [gate.fresh().then(() => opened.push("late")), gate.fresh().then(() => opened.push("late"))];
  first.release();
  await early;
  await until(() => confirms === 2, "the late callers get a confirm of their own");
  assert.deepEqual(opened, ["early"], "the confirm that was in flight when they asked opens nothing for them");
  second.release();
  await Promise.all(late);
  assert.deepEqual(opened, ["early", "late", "late"]);
  assert.equal(confirms, 2, "both late callers share one confirm");
});

test("the gate waits out an unreachable authority, and an abort ends one caller's wait", async () => {
  const { authority, gate, fences } = await gated();
  let reachable = false, refusedExchanges = 0;
  authority.beforeCommand = () => {
    if (reachable) return;
    refusedExchanges += 1;
    throw new AuthorityUnreachable("The authority is unreachable");
  };
  const stop = new AbortController();
  let patientOpened = false;
  const impatient = gate.fresh(stop.signal);
  const patient = gate.fresh().then(() => { patientOpened = true; });
  await until(() => refusedExchanges >= 3, "the gate keeps asking");
  stop.abort();
  await assert.rejects(impatient, (error) => !(error instanceof OwnerFenced));
  assert.equal(patientOpened, false);
  reachable = true;
  await patient;
  assert.deepEqual(fences, [], "an unreachable authority and an abort fence nobody");
});

test("a caller whose signal is already aborted sends no confirm", async () => {
  const { authority, gate } = await gated();
  let confirms = 0;
  authority.beforeCommand = (command) => { if (isConfirm(command)) confirms += 1; };
  await assert.rejects(gate.fresh(AbortSignal.abort()));
  assert.equal(confirms, 0);
});

test("once every caller of an unanswered confirm has left, the gate stops asking and serves the next caller", async () => {
  const { authority, gate } = await gated();
  let reachable = false, refusedExchanges = 0;
  authority.beforeCommand = () => {
    if (reachable) return;
    refusedExchanges += 1;
    throw new AuthorityUnreachable("The authority is unreachable");
  };
  const stop = new AbortController();
  const left = gate.fresh(stop.signal);
  await until(() => refusedExchanges >= 2, "the gate keeps asking");
  stop.abort();
  await assert.rejects(left);
  const asked = refusedExchanges;
  await new Promise((resolve) => setTimeout(resolve, 300));
  assert.ok(refusedExchanges <= asked + 1, "nobody waits, so nothing is asked");
  reachable = true;
  await gate.fresh();
});

test("a refusal rejects every waiter with OwnerFenced, reports the fence once, and closes the gate for good", async () => {
  const { authority, epoch, gate, fences } = await gated();
  const first = held();
  let confirms = 0;
  authority.beforeCommand = async (command) => {
    if (!isConfirm(command)) return;
    confirms += 1;
    if (confirms === 1) await first.promise;
  };
  const inFlight = gate.fresh();
  await until(() => confirms === 1, "the first confirm starts");
  const waiting = [gate.fresh(), gate.fresh()];
  await replaceOwner(authority, STANDBY, epoch);
  first.release();
  const fenced = (error: unknown) => error instanceof OwnerFenced && error.reason === "fenced";
  await assert.rejects(inFlight, fenced);
  for (const waiter of waiting) await assert.rejects(waiter, fenced);
  await assert.rejects(gate.fresh(), fenced);
  assert.equal(fences.length, 1);
  assert.equal(fences[0]?.state?.kind === "active" && fences[0].state.holder, STANDBY);
  assert.equal(confirms, 1, "a fenced gate asks nothing more");
});

test("a sealed log closes the gate", async () => {
  const { authority, epoch, gate, fences } = await gated();
  assert.equal((await authority.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null })).result, "accepted");
  await assert.rejects(gate.fresh(), (error) => error instanceof OwnerFenced && error.reason === "sealed");
  assert.equal(fences.length, 1);
});

test("the log writer reports a fence where it reads the refusal, though Pi keeps the rejected commit to itself", async (t) => {
  const authority = new MemoryAuthority(), epoch = await enroll(authority), directory = await stateDirectory(t), fences: OwnerFenced[] = [];
  const owner = await openOwner(directory, authority, { epoch, onFenced: (error) => fences.push(error) });
  t.after(() => owner.harness.close(BACKGROUND_CONTEXT).catch(() => {}));
  await owner.root.submit(note("first", "request-1"), BACKGROUND_CONTEXT);
  assert.equal(fences.length, 0);
  assert.equal((await authority.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null })).result, "accepted");
  await owner.root.submit(note("refused", "request-2"), BACKGROUND_CONTEXT).catch(() => {});
  assert.deepEqual(fences.map((error) => error.reason), ["sealed"]);
});

test("opening storage at an epoch the authority has moved past reports the fence", async (t) => {
  const authority = new MemoryAuthority(), epoch = await enroll(authority), directory = await stateDirectory(t), fences: OwnerFenced[] = [];
  assert.equal((await claimStart(authority, OWNER)).result, "accepted");
  await assert.rejects(openOwner(directory, authority, { epoch, onFenced: (error) => fences.push(error) }), OwnerFenced);
  assert.deepEqual(fences.map((error) => error.reason), ["fenced"]);
});
