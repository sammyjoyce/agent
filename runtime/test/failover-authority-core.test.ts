import assert from "node:assert/strict";
import test from "node:test";
import { decide } from "../src/failover/authority-core.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import type { AuthorityRecord } from "../src/generated/AuthorityRecord.js";
import { cellCheckpoint, cellCommand, cellLog, cells, cellStates, digests, entry, holders, manifest, scriptedSequences, tarantula, type Outcome, type Script } from "./fixtures/failover-authority-cells.js";

interface World {
  readonly record: AuthorityRecord | undefined;
  readonly log: Readonly<Record<number, string>>;
}

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
    result.push({ op: "enroll", holder: caller, checkpoint: { through: 0, manifest } });
    for (const value of epochs) {
      result.push({ op: "claim", holder: caller, expected_epoch: value });
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
      if (command.op !== "append") {
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

test("every state, operation and caller cell gives its documented answer", () => {
  const outcome = (record: AuthorityRecord | undefined, name: string, caller: string): Outcome => {
    const { reply } = step({ record, log: record === undefined ? {} : cellLog }, cellCommand(name, caller)).decision;
    return reply.result === "accepted" ? "accepted" : reply.reason;
  };
  const operations = new Set<string>(["enroll", "claim", "append", "confirm", "checkpoint", "promote", "release", "activate"] satisfies AuthorityCommand["op"][]);
  assert.deepEqual(new Set(Object.keys(cells).map((name) => name.split(" ")[0])), operations, "the table misses an operation");
  for (const [name, [none, ...enrolled]] of Object.entries(cells)) {
    assert.equal(outcome(undefined, name, tarantula), none, `${name} before enrollment`);
    cellStates.forEach((state, index) => {
      assert.deepEqual(holders.map((caller) => outcome({ state, checkpoint: cellCheckpoint }, name, caller)), enrolled[index],
        `${name} on ${state.kind} by the old owner, the candidate and a third holder`);
    });
  }
});

function run(start: World, script: Script) {
  let world = start;
  for (const [command, expected] of script) {
    const result = step(world, command);
    const { reply } = result.decision;
    assert.equal(reply.result === "accepted" ? "accepted" : reply.reason, expected, JSON.stringify(command));
    world = result.world;
  }
  return world;
}

for (const [name, sequence] of Object.entries(scriptedSequences)) {
  test(name, () => {
    const world = run({ record: undefined, log: {} }, sequence.steps);
    assert.deepEqual(world.record, sequence.record);
    assert.deepEqual(world.log, sequence.log);
  });
}
