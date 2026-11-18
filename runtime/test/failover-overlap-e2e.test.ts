import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { commands, latch } from "./fixtures/failover-fault-proxy.js";
import { logBatches } from "./fixtures/failover-state.js";
import { failoverWorld, type FailoverWorld, type WorldOptions } from "./fixtures/failover-world.js";

const STATEMENT = "Invented: the old host stopped answering";
const JOB = "invented-ledger-review";
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

/** One tool call that the old owner runs to the point where only its result is still to be recorded, and that a new owner then recovers. */
interface Held {
  readonly tool: string;
  readonly world?: WorldOptions;
  /** The words the model searches for to load the tool, when the main conversation defers it. */
  readonly load?: string;
  /** What must exist before the model calls the tool. Returns the tool's arguments. */
  prepare(world: FailoverWorld): Promise<Record<string, string>>;
  /** How many times the tool's effect exists. It must not ask the old owner, whose reads wait behind its held commit. */
  effects(world: FailoverWorld, args: Record<string, string>): Promise<number>;
}

/**
 * Holds the first run open on the old owner after its effect and before its
 * result is recorded, promotes on a statement, lets the new owner recover the
 * turn, then releases the first run. Returns how the new owner treated the call.
 */
async function overlap(t: TestContext, { tool, world: options, load, prepare, effects }: Held) {
  const world = await failoverWorld(t, { watchSeconds: 1, ...options }), { owner, standby, worker } = world, key = `fixture-overlap-${tool}`;
  await world.enroll();
  const serving = await world.serve(owner);
  world.work();
  await world.online(owner, [worker.nodeId]);
  await world.join();
  const args = await prepare(world);
  const call: ModelStep = { tool, args };
  await world.script(key, [...(load === undefined ? [] : [{ tool: "tool_search", args: { query: load } }]), call, { text: "The new owner finished the turn." }]);

  const first = latch(), result = String.raw`\"toolName\":\"${tool}\"`;
  let open = false;
  owner.proxy.inject({ fault: { kind: "hold", release: first.released }, match: (request) => open ||= commands("append")(request) && request.body.includes(result) });
  const sent = world.sending(owner, key);
  await world.until(async () => open, `The old owner must reach the result of ${tool}`, () => serving.errors().slice(-1000));
  const before = await effects(world, args);

  await world.promote({ replaceEpoch: 2, statement: STATEMENT });
  await world.serve(standby);
  await world.direct(standby);
  await world.redirected(standby);
  await world.until(async () => (await world.send(standby, key, { id: sent.id })).some((event) => event.type === "input_accepted" && event.work?.type === "completed"),
    "The new owner must finish the turn it recovered");
  const told = await world.lastAsked(key);
  first.release();
  assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
  return { interrupted: told.includes(`Tool ${tool} was interrupted`), before, after: await effects(world, args) };
}

/** Tools whose effect is a Pi commit. The authority refuses that commit from a fenced owner, so they keep `replay: "safe"`. */
const rerun: readonly Held[] = [
  { tool: "notify_user", load: "notify user",
    prepare: async () => ({ text: "Invented notice: the ledger review found a zirconium connector." }),
    // A notice is a submission whose request id names the tool call that published it.
    effects: async (world) => new Set((await logBatches(world.authority.standby)).flat()
      .flatMap((write) => write.type === "submission" && write.value.requestId?.startsWith("notice:") ? [write.value.id] : [])).size },
  { tool: "run_job",
    world: { settings: async (home) => {
      const jobs = join(home, "jobs");
      await mkdir(jobs, { mode: 0o700 });
      await writeFile(join(jobs, `${JOB}.toml`), `id = "${JOB}"\nprompt = "fixture-invented-ledger-review"\nmodel = "fixture"\nreasoning_effort = "medium"\ntimezone = "UTC"\n\n` +
        '[[schedules]]\nid = "daily"\nrecurrence = "DTSTART:20990101T090000Z\\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0"\n');
      return `job_directories = [${JSON.stringify(jobs)}]\n`;
    } },
    async prepare(world) {
      await world.script("fixture-invented-ledger-review", [{ text: "The invented ledger review is complete." }, { text: "The invented ledger review is complete." }]);
      return { job_id: JOB };
    },
    // Each admitted run is an occurrence named after the request that asked for it.
    effects: async (world) => new Set(JSON.stringify(await logBatches(world.authority.standby)).match(/manual:[0-9a-f-]{36}/g)).size },
];

/** Tools whose effect is on a host, where no test holds a first run open while a second one starts. A new owner must not run them again. */
const interrupted: readonly Held[] = [
  { tool: "read_attachment",
    async prepare(world) {
      const bytes = Buffer.from("Invented attachment text that the tool reads back"), id = randomUUID();
      await world.request(world.owner, { type: "attachment", request: { type: "upload", id, name: "evidence.txt", media_type: "text/plain", size_bytes: bytes.length, offset: 0,
        data_base64: bytes.toString("base64"), complete: true } });
      return { id };
    },
    // The effect is one copy in a host's cache. The main conversation reads on its coordinator's own machine, so a second run would add a copy on the new owner's host.
    async effects(world) {
      const expected = sha256(Buffer.from("Invented attachment text that the tool reads back"));
      const copies = await Promise.all([world.owner.state, world.standby.state, join(world.worker.home, "state")].map(async (state) => {
        const cached = await readdir(join(state, "attachment-cache"), { recursive: true, withFileTypes: true }).catch(() => []);
        const hashes = await Promise.all(cached.filter((entry) => entry.isFile()).map(async (entry) => sha256(await readFile(join(entry.parentPath, entry.name)))));
        return hashes.filter((hash) => hash === expected).length;
      }));
      return copies.reduce((sum, count) => sum + count, 0);
    } },
  // With no owned worktree the collector asks no host, so the only thing to count is whether the call ran: its result names the inventory.
  { tool: "collect_worktrees", load: "collect worktrees", prepare: async () => ({}),
    effects: async (world) => (await logBatches(world.authority.standby)).flat()
      .filter((write) => write.type === "entry" && JSON.stringify(write.value).includes('"toolName":"collect_worktrees"') && !JSON.stringify(write.value).includes("was interrupted")).length },
];

test("a replay-safe tool that a new owner runs again while its first run is still open leaves one effect", { timeout: 180_000 }, async (t) => {
  for (const scenario of rerun) {
    await t.test(`${scenario.tool}, rerun while its first run is held open, leaves one effect`, async (t) => {
      const outcome = await overlap(t, scenario);
      assert.deepEqual(outcome, { interrupted: false, before: 1, after: 1 });
    });
  }
});

test("a host tool that the old owner left without a result is reported as interrupted by the new owner and is not run again", { timeout: 180_000 }, async (t) => {
  for (const scenario of interrupted) {
    await t.test(`${scenario.tool}, left without a result, is reported as interrupted and not run again`, async (t) => {
      const outcome = await overlap(t, scenario);
      assert.equal(outcome.interrupted, true, "the model is told that the call was interrupted");
      assert.equal(outcome.after, outcome.before, "the new owner made no effect of its own");
    });
  }
});
