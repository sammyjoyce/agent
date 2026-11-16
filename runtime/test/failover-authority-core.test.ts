import assert from "node:assert/strict";
import test from "node:test";
import { decide } from "../src/failover/authority-core.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../src/generated/AuthorityRecord.js";
import type { AuthorityState } from "../src/generated/AuthorityState.js";
import type { LogEntry } from "../src/generated/LogEntry.js";

const tarantula = "11111111-1111-4111-8111-111111111111";
const orion = "22222222-2222-4222-8222-222222222222";
const spare = "33333333-3333-4333-8333-333333333333";
const holders = [tarantula, orion, spare];
const digests = ["a".repeat(64), "b".repeat(64)];
const manifest = "c".repeat(64);
const versions = { application: "0.1.0", pi_durable: "1.4.0", chord: "1.4.0" };

interface World {
  readonly record: AuthorityRecord | undefined;
  readonly log: Readonly<Record<number, string>>;
}

const entry = (epoch: number, at: number, digest: string): LogEntry =>
  ({ at, epoch, digest, versions, pi_seq: at, files: [], batch: { kind: "inline", json: "[]" } });

function step(world: World, command: AuthorityCommand) {
  const decision = decide(world.record, command, (at) => world.log[at]);
  let log = world.log;
  if (decision.write?.type === "append") log = { ...log, [decision.write.entry.at]: decision.write.entry.digest };
  if (decision.write?.type === "checkpoint") {
    const { through } = decision.write.record;
    log = Object.fromEntries(Object.entries(log).filter(([at]) => Number(at) > through));
  }
  return { world: { record: decision.record, log }, decision };
}

const key = (world: World) => JSON.stringify(world);

function commands(world: World, callers: readonly string[]): AuthorityCommand[] {
  const epoch = world.record?.state.epoch ?? 1, head = world.record?.state.head ?? 0;
  const through = world.record?.checkpoint.through ?? 0;
  const epochs = [epoch - 1, epoch, epoch + 1].filter((value) => value >= 0);
  const result: AuthorityCommand[] = [];
  for (const caller of callers) {
    result.push({ op: "enroll", holder: caller, checkpoint: { through: 0, manifest } }, { op: "claim", holder: caller });
    for (const value of epochs) {
      for (const at of [head - 1, head, head + 1, head + 2]) {
        if (at >= 1) for (const digest of digests) result.push({ op: "append", holder: caller, entry: entry(value, at, digest) });
      }
      result.push({ op: "confirm", holder: caller, epoch: value });
      for (const at of new Set([through - 1, through, head, head + 1])) {
        if (at >= 0) result.push({ op: "checkpoint", holder: caller, epoch: value, record: { through: at, manifest } });
      }
      for (const evidence of ["released", "lock_held"] as const) result.push({ op: "release", holder: caller, epoch: value, evidence });
      for (const attestation of [null, "the old host is powered off"]) result.push({ op: "promote", candidate: caller, expected_epoch: value, attestation });
    }
    for (const applied of [head - 1, head, head + 1]) if (applied >= 0) result.push({ op: "activate", candidate: caller, applied });
  }
  return result;
}

function reachable(start: World, callers: readonly string[], bound: { readonly epoch: number; readonly head: number }) {
  const seen = new Map([[key(start), start]]);
  const queue = [start];
  let accepted = 0, repeats = 0;
  for (let world = queue.shift(); world !== undefined; world = queue.shift()) {
    const before = world.record?.state;
    for (const command of commands(world, callers)) {
      const { world: next, decision } = step(world, command);
      if (decision.reply.result === "refused") {
        assert.equal(key(next), key(world), `a refused ${command.op} changed the authority`);
        assert.deepEqual(decision.reply.state, before ?? null, "a refusal names the current record");
        continue;
      }
      accepted += 1;
      const after = next.record?.state;
      assert.ok(after !== undefined, "an accepted command leaves a record");
      if (before === undefined) {
        assert.deepEqual([command.op, after.kind, after.epoch, after.head], ["enroll", "active", 1, 0]);
      } else {
        assert.ok(after.epoch === before.epoch || after.epoch === before.epoch + 1, "the epoch fell or skipped");
        assert.ok(after.head >= before.head, "the head fell");
        if (command.op === "append") {
          assert.ok(before.kind === "active" && before.holder === command.holder && before.epoch === command.entry.epoch,
            "an append or a repeat was accepted from a caller that is not the current owner");
          if (after.head === before.head) {
            repeats += 1;
            assert.equal(decision.write, undefined, "a repeat wrote to the log");
            assert.equal(world.log[command.entry.at], command.entry.digest, "a repeat was accepted for a different entry");
          } else {
            assert.equal(command.entry.at, before.head + 1, "an append skipped a position");
          }
        } else {
          assert.equal(after.head, before.head, `${command.op} moved the head`);
        }
        if (after.kind === "active" && before.kind === "active") assert.equal(after.holder, before.holder, "the owner changed without a seal");
        if (after.kind === "active" && before.kind !== "active") {
          assert.ok(before.kind === "vacant" && command.op === "activate", "ownership was granted without stop evidence");
          assert.deepEqual([after.epoch, after.holder, command.applied], [before.epoch + 1, before.candidate, before.head],
            "an activation kept the epoch, named another holder, or came before catch-up");
        }
        if (after.kind === "vacant" && before.kind !== "vacant") {
          const attested = command.op === "promote" && command.attestation !== null && (before.kind !== "sealed" || before.holder !== command.candidate);
          const released = command.op === "release" && before.kind === "sealed" && before.holder === command.holder;
          assert.ok(attested || released, "the old owner was taken to be stopped without evidence");
        }
      }
      if (command.op !== "claim" && command.op !== "append") {
        assert.equal(key(step(next, command).world), key(next), `a repeat of ${command.op} moved the authority again`);
      }
      if (after.epoch > bound.epoch || after.head > bound.head || seen.has(key(next))) continue;
      seen.set(key(next), next);
      queue.push(next);
    }
  }
  return { worlds: [...seen.values()], accepted, repeats };
}

test("the authority rules hold their invariants over every reachable state of three holders", () => {
  const { worlds, accepted, repeats } = reachable({ record: undefined, log: {} }, holders, { epoch: 5, head: 2 });
  assert.ok(worlds.length > 400 && accepted > 3000 && repeats > 0, `the search was too small: ${worlds.length} states, ${accepted} accepted, ${repeats} repeats`);
  for (const kind of ["active", "sealed", "vacant"]) assert.ok(worlds.some((world) => world.record?.state.kind === kind), `no ${kind} state was reached`);

  for (const world of worlds) {
    if (world.record === undefined) continue;
    const { epoch, head } = world.record.state;
    for (const survivor of holders) {
      const alone = reachable(world, [survivor], { epoch: epoch + 2, head }).worlds;
      assert.ok(alone.some((next) => next.record?.state.kind === "active" && next.record.state.holder === survivor),
        `${survivor} alone cannot become owner from ${key(world)}`);
    }
  }
});

type Outcome = "accepted" | Extract<ReturnType<typeof decide>["reply"], { result: "refused" }>["reason"];
const cells: Record<string, readonly [none: Outcome, active: readonly Outcome[], sealed: readonly Outcome[], vacant: readonly Outcome[]]> = {
  enroll: ["accepted", ["accepted", "enrolled", "enrolled"], ["enrolled", "enrolled", "enrolled"], ["enrolled", "enrolled", "enrolled"]],
  claim: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  append: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  confirm: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  checkpoint: ["not_enrolled", ["accepted", "fenced", "fenced"], ["sealed", "sealed", "sealed"], ["sealed", "sealed", "sealed"]],
  promote: ["not_enrolled", ["already_owner", "accepted", "accepted"], ["accepted", "accepted", "accepted"], ["accepted", "accepted", "accepted"]],
  "promote with an attestation": ["not_enrolled", ["already_owner", "accepted", "accepted"], ["self_attestation", "accepted", "accepted"], ["accepted", "accepted", "accepted"]],
  release: ["not_enrolled", ["not_sealed", "not_sealed", "not_sealed"], ["accepted", "not_sealed_holder", "not_sealed_holder"], ["not_sealed", "not_sealed", "not_sealed"]],
  activate: ["not_enrolled", ["accepted", "not_candidate", "not_candidate"], ["not_candidate", "not_candidate", "not_candidate"], ["not_candidate", "accepted", "not_candidate"]],
};

test("every state, operation and caller cell gives its documented answer", () => {
  const log = { 1: digests[0]!, 2: digests[1]! };
  const checkpoint = { through: 0, manifest };
  const states: AuthorityState[] = [
    { kind: "active", epoch: 3, holder: tarantula, head: 2 },
    { kind: "sealed", epoch: 3, holder: tarantula, candidate: orion, head: 2 },
    { kind: "vacant", epoch: 3, candidate: orion, evidence: { kind: "released" }, head: 2 },
  ];
  const command = (name: string, caller: string): AuthorityCommand => {
    switch (name) {
      case "enroll": return { op: "enroll", holder: caller, checkpoint };
      case "claim": return { op: "claim", holder: caller };
      case "append": return { op: "append", holder: caller, entry: entry(3, 3, digests[0]!) };
      case "confirm": return { op: "confirm", holder: caller, epoch: 3 };
      case "checkpoint": return { op: "checkpoint", holder: caller, epoch: 3, record: { through: 2, manifest } };
      case "promote": return { op: "promote", candidate: caller, expected_epoch: 3, attestation: null };
      case "promote with an attestation": return { op: "promote", candidate: caller, expected_epoch: 3, attestation: "the old host is powered off" };
      case "release": return { op: "release", holder: caller, epoch: 3, evidence: "lock_held" };
      case "activate": return { op: "activate", candidate: caller, applied: 2 };
      default: throw new Error(`no command for ${name}`);
    }
  };
  const outcome = (record: AuthorityRecord | undefined, name: string, caller: string): Outcome => {
    const { reply } = step({ record, log: record === undefined ? {} : log }, command(name, caller)).decision;
    return reply.result === "accepted" ? "accepted" : reply.reason;
  };
  const operations = new Set<string>(["enroll", "claim", "append", "confirm", "checkpoint", "promote", "release", "activate"] satisfies AuthorityCommand["op"][]);
  assert.deepEqual(new Set(Object.keys(cells).map((name) => name.split(" ")[0])), operations, "the table misses an operation");
  for (const [name, [none, ...enrolled]] of Object.entries(cells)) {
    assert.equal(outcome(undefined, name, tarantula), none, `${name} before enrollment`);
    states.forEach((state, index) => {
      assert.deepEqual(holders.map((caller) => outcome({ state, checkpoint }, name, caller)), enrolled[index],
        `${name} on ${state.kind} by the old owner, the candidate and a third holder`);
    });
  }
});

function run(start: World, script: readonly (readonly [AuthorityCommand, Outcome])[]) {
  let world = start;
  for (const [command, expected] of script) {
    const result = step(world, command);
    const { reply } = result.decision;
    assert.equal(reply.result === "accepted" ? "accepted" : reply.reason, expected, JSON.stringify(command));
    world = result.world;
  }
  return world;
}

const enrolled = () => run({ record: undefined, log: {} }, [[{ op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest } }, "accepted"]]);

test("a retried append is honored only for the current owner", () => {
  const first: AuthorityCommand = { op: "append", holder: tarantula, entry: entry(1, 1, digests[0]!) };
  const world = run(enrolled(), [
    [first, "accepted"],
    [first, "accepted"],
    [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[1]!) }, "conflict"],
    [{ op: "append", holder: tarantula, entry: entry(1, 3, digests[1]!) }, "gap"],
    [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "accepted"],
    [first, "sealed"],
    [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: "the old host is powered off" }, "accepted"],
    [{ op: "activate", candidate: orion, applied: 0 }, "not_caught_up"],
    [{ op: "activate", candidate: orion, applied: 1 }, "accepted"],
    [first, "fenced"],
    [{ op: "confirm", holder: tarantula, epoch: 1 }, "fenced"],
    [{ op: "claim", holder: tarantula }, "fenced"],
    [{ op: "append", holder: orion, entry: entry(1, 2, digests[1]!) }, "fenced"],
    [{ op: "append", holder: orion, entry: entry(2, 2, digests[1]!) }, "accepted"],
  ]);
  assert.deepEqual(world.record?.state, { kind: "active", epoch: 2, holder: orion, head: 2 });
  assert.deepEqual(world.log, { 1: digests[0], 2: digests[1] });
});

test("a promotion whose candidate is lost is completed by another standby or taken back by the old owner", () => {
  const sealed = run(enrolled(), [[{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "accepted"]]);
  const takenOver = run(sealed, [
    [{ op: "promote", candidate: spare, expected_epoch: 1, attestation: null }, "accepted"],
    [{ op: "activate", candidate: spare, applied: 0 }, "not_candidate"],
    [{ op: "release", holder: orion, epoch: 1, evidence: "released" }, "not_sealed_holder"],
    [{ op: "release", holder: tarantula, epoch: 1, evidence: "released" }, "accepted"],
    [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: "the old host is powered off" }, "accepted"],
    [{ op: "activate", candidate: spare, applied: 0 }, "not_candidate"],
    [{ op: "activate", candidate: orion, applied: 0 }, "accepted"],
    [{ op: "activate", candidate: orion, applied: 0 }, "accepted"],
  ]);
  assert.deepEqual(takenOver.record?.state, { kind: "active", epoch: 2, holder: orion, head: 0 });

  const takenBack = run(sealed, [
    [{ op: "promote", candidate: tarantula, expected_epoch: 1, attestation: "I am stopped" }, "self_attestation"],
    [{ op: "promote", candidate: tarantula, expected_epoch: 1, attestation: null }, "accepted"],
    [{ op: "release", holder: tarantula, epoch: 1, evidence: "released" }, "accepted"],
    [{ op: "activate", candidate: tarantula, applied: 0 }, "accepted"],
    [{ op: "promote", candidate: orion, expected_epoch: 1, attestation: null }, "epoch_moved"],
  ]);
  assert.deepEqual(takenBack.record?.state, { kind: "active", epoch: 2, holder: tarantula, head: 0 });
});

test("a checkpoint drops the entries it covers and never moves backward or past the head", () => {
  const world = run(enrolled(), [
    [{ op: "enroll", holder: orion, checkpoint: { through: 0, manifest } }, "enrolled"],
    [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[0]!) }, "accepted"],
    [{ op: "append", holder: tarantula, entry: entry(1, 2, digests[1]!) }, "accepted"],
    [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 3, manifest } }, "checkpoint_out_of_range"],
    [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 1, manifest } }, "accepted"],
    [{ op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 0, manifest } }, "checkpoint_out_of_range"],
    [{ op: "append", holder: tarantula, entry: entry(1, 1, digests[0]!) }, "conflict"],
    [{ op: "append", holder: tarantula, entry: entry(1, 2, digests[1]!) }, "accepted"],
  ]);
  assert.deepEqual(world.record, { state: { kind: "active", epoch: 1, holder: tarantula, head: 2 }, checkpoint: { through: 1, manifest } });
  assert.deepEqual(world.log, { 2: digests[1] });
  assert.equal(run({ record: undefined, log: {} }, [[{ op: "enroll", holder: tarantula, checkpoint: { through: 4, manifest } }, "checkpoint_out_of_range"]]).record, undefined);
});
