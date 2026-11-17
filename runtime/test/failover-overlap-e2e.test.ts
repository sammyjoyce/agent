import assert from "node:assert/strict";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { OWNER_FENCED_EXIT } from "../src/generated/owner-fenced-exit.js";
import { ATTACHMENT_CHUNK_BYTES } from "../src/generated/attachment-limits.js";
import type { ModelStep } from "./fixtures/coordinator-runtime.js";
import { delegate } from "./fixtures/coordinator-world.js";
import { commands, latch } from "./fixtures/failover-fault-proxy.js";
import { logBatches } from "./fixtures/failover-state.js";
import { failoverWorld, type FailoverWorld, type WorldOptions } from "./fixtures/failover-world.js";

const STATEMENT = "Invented: the old host stopped answering";
const JOB = "invented-ledger-review";
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");

/** One replay-safe tool, run to the point where only its result is still to be recorded, then run again by a new owner. */
interface Overlap {
  readonly tool: string;
  readonly world?: WorldOptions;
  /** The words the model searches for to load the tool, when the main conversation defers it. */
  readonly load?: string;
  /** What must exist before the model calls the tool. Returns the tool's arguments. */
  prepare(world: FailoverWorld): Promise<Record<string, string>>;
  /** Text that only the tool's result carries, which marks the append that records it. */
  readonly result: string;
  /** How many times the tool's effect exists. It must not ask the old owner, whose reads wait behind its held commit. */
  effects(world: FailoverWorld, args: Record<string, string>): Promise<number>;
}

/**
 * Holds the first run open on the old owner after its effect and before its
 * result is recorded, promotes on a statement, lets the new owner run the tool
 * again, then releases the first run. Returns how the new owner treated the call.
 */
async function overlap(t: TestContext, { tool, world: options, load, prepare, result, effects }: Overlap) {
  const world = await failoverWorld(t, { watchSeconds: 1, ...options }), { owner, standby, worker } = world, key = `fixture-overlap-${tool}`;
  await world.enroll();
  const serving = await world.serve(owner);
  world.work();
  await world.online(owner, [worker.nodeId]);
  await world.join();
  const args = await prepare(world);
  const call: ModelStep = { tool, args };
  await world.script(key, [...(load === undefined ? [] : [{ tool: "tool_search", args: { query: load } }]), call, { text: "The new owner finished the turn." }]);

  const first = latch();
  let open = false;
  owner.proxy.inject({ fault: { kind: "hold", release: first.released }, match: (request) => open ||= commands("append")(request) && request.body.includes(result) });
  const sent = world.sending(owner, key);
  await world.until(async () => open, `The old owner must reach the result of ${tool}`, () => serving.errors().slice(-1000));
  assert.equal(await effects(world, args), 1, "the first run made its effect once");

  await world.promote({ replaceEpoch: 2, statement: STATEMENT });
  await world.serve(standby);
  await world.direct(standby);
  await world.online(standby, [worker.nodeId]);
  await world.until(async () => (await world.send(standby, key, { id: sent.id })).some((event) => event.type === "input_accepted" && event.work?.type === "completed"),
    "The new owner must finish the turn it recovered");
  const told = await world.lastAsked(key);
  first.release();
  assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));
  return { world, args, interrupted: told.includes(`Tool ${tool} was interrupted`), effects: await effects(world, args) };
}

const cases: readonly Overlap[] = [
  { tool: "notify_user", load: "notify user", result: "Published to the main chat.",
    prepare: async () => ({ text: "Invented notice: the ledger review found a zirconium connector." }),
    // A notice is a submission whose request id names the tool call that published it.
    effects: async (world) => new Set((await logBatches(world.authority.standby)).flat()
      .flatMap((write) => write.type === "submission" && write.value.requestId?.startsWith("notice:") ? [write.value.id] : [])).size },
  // The receipt is JSON in the tool's text, so its quotes are escaped once more than those of the stored receipt.
  { tool: "run_job", result: String.raw`\\\"admitted_at`,
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
  { tool: "read_attachment", result: "Attached file",
    async prepare(world) {
      const bytes = Buffer.from("Invented attachment text that the tool reads back"), id = randomUUID();
      await world.request(world.owner, { type: "attachment", request: { type: "upload", id, name: "evidence.txt", media_type: "text/plain", size_bytes: bytes.length, offset: 0,
        data_base64: bytes.toString("base64"), complete: true } });
      return { id };
    },
    // The main conversation reads an attachment on its coordinator's own machine, so each owner materializes it on its own host.
    // The effect is one copy in a host's cache, and the count is that of the host that holds the most.
    async effects(world) {
      const expected = sha256(Buffer.from("Invented attachment text that the tool reads back"));
      const copies = await Promise.all([world.owner.state, world.standby.state, join(world.worker.home, "state")].map(async (state) => {
        const cached = await readdir(join(state, "attachment-cache"), { recursive: true, withFileTypes: true }).catch(() => []);
        const hashes = await Promise.all(cached.filter((entry) => entry.isFile()).map(async (entry) => sha256(await readFile(join(entry.parentPath, entry.name)))));
        return hashes.filter((hash) => hash === expected).length;
      }));
      return Math.max(...copies);
    } },
];

test("a replay-safe tool that a new owner runs again while its first run is still open leaves one effect", { timeout: 180_000 }, async (t) => {
  for (const scenario of cases) {
    await t.test(`${scenario.tool}, rerun while its first run is held open, leaves one effect`, async (t) => {
      const outcome = await overlap(t, scenario);
      t.diagnostic(`${scenario.tool}: the new owner ${outcome.interrupted ? "reported the call as interrupted" : "ran the call again"}, and its effect exists ${outcome.effects} time(s)`);
      assert.equal(outcome.interrupted, false, "a replay-safe call is run again, not reported as interrupted");
      assert.equal(outcome.effects, 1);
    });
  }
});

/** Every file under a host's attachment cache, by its path. */
async function cached(state: string): Promise<string[]> {
  const entries = await readdir(join(state, "attachment-cache"), { recursive: true, withFileTypes: true }).catch(() => []);
  return entries.filter((entry) => entry.isFile()).map((entry) => join(entry.parentPath, entry.name));
}

test("read_attachment, run again by a new owner on the same worker while the old owner is held in the middle of writing the file, leaves one complete file", { timeout: 120_000 }, async (t) => {
  const world = await failoverWorld(t, { watchSeconds: 1 }), { owner, standby, worker } = world, task = "fixture-overlap-worker-read", dispatch = "fixture-overlap-worker-dispatch";
  await world.enroll();
  const serving = await world.serve(owner);
  world.work();
  await world.online(owner, [worker.nodeId]);
  await world.join();
  const bytes = Buffer.alloc(5 * ATTACHMENT_CHUNK_BYTES, "Invented attachment bytes that fill five chunks. "), id = randomUUID();
  for (let offset = 0; offset < bytes.length; offset += ATTACHMENT_CHUNK_BYTES) {
    const chunk = bytes.subarray(offset, offset + ATTACHMENT_CHUNK_BYTES);
    await world.request(owner, { type: "attachment", request: { type: "upload", id, name: "evidence.bin", media_type: "application/octet-stream", size_bytes: bytes.length, offset,
      data_base64: chunk.toString("base64"), complete: offset + chunk.length === bytes.length } });
  }
  await world.script(task, [{ tool: "read_attachment", args: { id } }, { text: "The worker task read the attachment." }]);
  await world.script(dispatch, [delegate(task, worker.nodeId), { text: "Delegated the read." }]);

  // Each chunk waits for its own confirm. Two chunks reach the worker, and the third is held at the proxy.
  const first = latch();
  let logged = false, confirms = 0;
  owner.proxy.inject({ fault: { kind: "hold", release: first.released }, times: Number.MAX_SAFE_INTEGER, match: (request) => {
    if (commands("append")(request) && request.body.includes("tools.read_attachment(")) logged = true;
    return logged && commands("confirm")(request) && ++confirms > 2;
  } });
  world.sending(owner, dispatch);
  const workerState = join(worker.home, "state");
  const partial = async () => (await cached(workerState)).filter((path) => path.endsWith("content.part"));
  await world.until(async () => {
    const [part] = await partial();
    return part !== undefined && (await stat(part)).size === 2 * ATTACHMENT_CHUNK_BYTES;
  }, "The old owner must be held with two of five chunks on the worker", () => `${serving.errors().slice(-1000)} confirms=${confirms} logged=${logged}`);

  assert.deepEqual((await cached(workerState)).filter((path) => path.endsWith("file-evidence.bin")), [], "the old owner's run has not finished the file");

  await world.promote({ replaceEpoch: 2, statement: STATEMENT });
  await world.serve(standby);
  await world.direct(standby);
  await world.online(standby, [worker.nodeId]);
  await world.until(async () => (await cached(workerState)).some((path) => path.endsWith("file-evidence.bin")), "The new owner must run the read again on the same worker to its end");
  first.release();
  assert.equal(await serving.exited, OWNER_FENCED_EXIT, serving.errors().slice(-2000));

  const files = await cached(workerState);
  assert.deepEqual(await partial(), [], "no partial file is left on the worker");
  const complete = files.filter((path) => path.endsWith("file-evidence.bin"));
  assert.equal(complete.length, 1, `one complete file: ${JSON.stringify(files)}`);
  assert.equal(sha256(await readFile(complete[0]!)), sha256(bytes));
  assert.equal(await world.asked(task), 2, "the model was asked once by each owner for the task's turn");
});
