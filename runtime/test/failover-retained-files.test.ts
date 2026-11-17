import assert from "node:assert/strict";
import { cpSync, existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test, type TestContext } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteDatabase } from "@earendil-works/chord/sqlite";
import { createModels, fauxAssistantMessage } from "@earendil-works/pi-ai";
import { AttachmentStore } from "../src/attachments.js";
import { sha256Hex } from "../src/failover/log-entry.js";
import { AuthorityUnreachable } from "../src/failover/authority-link.js";
import { OwnerFenced } from "../src/failover/replicated-storage.js";
import { cleanRetainedFiles } from "../src/failover/retained-files.js";
import { FeedbackStore } from "../src/feedback.js";
import type { AgentNode } from "../src/generated/AgentNode.js";
import type { AttachmentRef } from "../src/generated/AttachmentRef.js";
import type { FeedbackContext } from "../src/generated/FeedbackContext.js";
import type { HistoryItem } from "../src/generated/HistoryItem.js";
import type { HistoryResponse } from "../src/generated/HistoryResponse.js";
import type { HistoryThread } from "../src/generated/HistoryThread.js";
import { HistoryStore } from "../src/history.js";
import { CodexImporter } from "../src/importer.js";
import { ConversationModels } from "../src/models.js";
import { TaskStore, type HostCall } from "../src/tasks.js";
import { authorities, enroll, filesUnder, follow, logEntries, loggedFiles, openOwner, replaceOwner, retainedFiles, STANDBY, stateDirectory, type TestAuthority } from "./fixtures/failover-state.js";
import { fixtureModel } from "./model.js";

const context = BACKGROUND_CONTEXT;
const FEEDBACK_ID = "77777777-7777-4777-8777-777777777777";
const ASSET = Buffer.from(JSON.stringify({ text: "Invented cold original of an imported garden transcript." }));

type Owner = Awaited<ReturnType<typeof openOwner>>;

function storesOf(owner: Owner) {
  const tasks = new TaskStore(owner.harness, new ConversationModels(createModels()));
  const assets = join(owner.files.stateDirectory, "history", "assets");
  return { attachments: new AttachmentStore(owner.files), feedback: new FeedbackStore(owner.files, tasks),
    importer: new CodexImporter(owner.harness, new HistoryStore(owner.harness, assets), owner.files) };
}

const feedbackContext = (): FeedbackContext => ({ origin_host_id: "11111111-1111-4111-8111-111111111111", cwd: "/invented/project", conversation_id: null,
  task_id: null, agent_id: null, model: fixtureModel, binding: null, draft: "Invented draft", queued_inputs: [], client_errors: [] });

const uploadChunk = (id: string, bytes: Buffer, complete: boolean) => ({ type: "upload", id, name: "garden.txt", media_type: "text/plain",
  size_bytes: bytes.length, offset: 0, data_base64: bytes.toString("base64"), complete }) as const;

async function upload(attachments: AttachmentStore, id: string, bytes: Buffer): Promise<AttachmentRef> {
  const response = await attachments.request(uploadChunk(id, bytes, true));
  assert.ok(response.type === "uploaded" && response.attachment !== null, "a complete upload returns its receipt");
  return response.attachment;
}

const historyHost: AgentNode = { host_id: "invented-worker", name: "invented-worker", rex_server: null, agent_program: "/invented/agent",
  home_directory: "/invented/home", coordinator: null, launch: { state_dir: null, runtime: null, config: null, instructions: null, model: null } };

/** A history host with one thread whose one item has a cold original. `advertised` is the digest the host claims for it. */
function nativeHistory(bytes: Buffer, advertised = sha256Hex(bytes)): HostCall {
  const thread: HistoryThread = { id: "invented-thread", title: "Garden", cwd: "/invented/project", created_at: 1, updated_at: 2, forked_from_id: null,
    parent_thread_id: null, version: "native-v1", version_reliable: true, archived: false };
  const item: HistoryItem = { id: "invented-item", turn_id: "turn-1", kind: "userMessage", role: "user", text: "Bounded excerpt", version: "item-v1", order: 0,
    timestamp_ms: 1, data: null, assets: [{ path: "/invented/native/evidence.json", item_id: "invented-item", version: "item-v1", kind: "cold_evidence",
      media_type: "application/json", sha256: advertised, size: bytes.length }] };
  return async (command) => {
    if (command.type !== "on_node" || command.command.type !== "history") throw new Error("The fixture host answers history reads only");
    const request = command.command.request;
    const response: HistoryResponse = request.type === "list" ? { type: "list", threads: request.archived ? [] : [thread], next_cursor: null }
      : request.type === "read" ? { type: "read", thread_id: thread.id, version: thread.version, items: [item], next_cursor: null, gaps: [], complete: true, source_exhausted: true }
      : { type: "asset", path: request.path, offset: request.offset, data_base64: bytes.toString("base64"), next_offset: null, total_bytes: bytes.length, sha256: advertised };
    return { type: "history", response };
  };
}

const importHistory = (importer: CodexImporter, call: HostCall) => importer.run([historyHost], [historyHost.host_id], [], call, () => {}, async () => {});

const temporaryName = (path: string) => path.split("/").some((name) => name.startsWith(".") || name.endsWith(".tmp"));

/** The files under the retained trees that a reader takes as real: no temporary name, and an attachment only once its metadata says it is complete. */
async function finalNamed(directory: string): Promise<string[]> {
  const named: string[] = [];
  for (const path of Object.keys(await retainedFiles(directory))) {
    if (temporaryName(path)) continue;
    const folder = /^attachments\/([^/]+)\//.exec(path)?.[1];
    if (folder !== undefined) {
      const metadata = await readFile(join(directory, "attachments", folder, "metadata.json"), "utf8").catch(() => "{}");
      if ((JSON.parse(metadata) as { complete?: unknown }).complete !== true) continue;
    }
    named.push(path);
  }
  return named;
}

/** No final-named file the log lacks, and every file the log names present with its logged bytes. */
async function assertMatchesLog(directory: string, link: TestAuthority, label: string): Promise<void> {
  const logged = await loggedFiles(link), present = await retainedFiles(directory);
  for (const path of await finalNamed(directory)) {
    assert.equal(present[path], logged.get(path)?.sha256, `${label}: ${path} has its final name with bytes the log does not hold`);
  }
  for (const [path, record] of logged) assert.equal(present[path], record.sha256, `${label}: the log names ${path} and the directory does not hold its bytes`);
}

/** Each step of a replicated write, and what has happened when a process stops there. */
const WRITE_STEPS = {
  synced: "a temporary file is synced and its upload has not started",
  uploaded: "the blob store holds the file and the log does not name it",
  sending: "the blob store holds every file and the entry has not reached the authority",
  appended: "the authority applied the entry and its reply was lost",
  renamed: "the file has its final name and the transaction that moves the applied position has not committed",
} as const;
type WriteStep = keyof typeof WRITE_STEPS;

/**
 * Stops an owner at one occurrence of one step, keeping a copy of its state
 * directory as the step left it. After the stop the link refuses the stopped
 * process, as it would refuse a dead one, until the test revives it.
 */
class Crash {
  readonly reached = new Map<WriteStep, number>();
  armed = false;
  stopped = false;
  #renaming: readonly string[] | undefined;

  constructor(readonly directory: string, readonly copy: string, readonly signal: AbortController, readonly target?: { step: WriteStep; occurrence: number }) {}

  instrument(link: TestAuthority): void {
    const putBlob = link.putBlob.bind(link);
    link.putBlob = async (sha256, bytes) => {
      this.refuseStopped();
      this.reach("synced");
      await putBlob(sha256, bytes);
      this.reach("uploaded");
    };
    link.beforeCommand = (command) => {
      this.refuseStopped();
      if (command.op === "append" && command.entry.files.length > 0) this.reach("sending");
    };
    link.afterApplied = (command) => {
      if (command.op !== "append" || command.entry.files.length === 0) return;
      this.#renaming = command.entry.files.map((file) => join(this.directory, file.path));
      this.reach("appended");
    };
  }

  /** Wraps the owner's raw database, so the end of the transaction that applies a file entry, after its renames and before its commit, is a step. */
  readonly observe = (database: SqliteDatabase): SqliteDatabase => ({
    exec: (sql) => database.exec(sql), run: (sql, ...params) => database.run(sql, ...params), get: (sql, ...params) => database.get(sql, ...params),
    all: (sql, ...params) => database.all(sql, ...params), close: () => database.close(),
    transaction: (callback) => database.transaction(async (transaction) => {
      const value = await callback(transaction);
      const renamed = this.#renaming;
      if (renamed !== undefined) {
        this.#renaming = undefined;
        assert.ok(renamed.every((path) => existsSync(path)), "the transaction after a file entry's append gives its files their final names");
        this.reach("renamed");
      }
      return value;
    }),
  });

  revive(link: TestAuthority): void {
    link.beforeCommand = () => {};
    link.afterApplied = () => {};
    this.stopped = false;
  }

  private refuseStopped(): void {
    if (this.stopped) throw new AuthorityUnreachable("The stopped process cannot reach the authority");
  }

  private reach(step: WriteStep): void {
    if (!this.armed) return;
    const occurrence = (this.reached.get(step) ?? 0) + 1;
    this.reached.set(step, occurrence);
    if (this.target?.step !== step || this.target.occurrence !== occurrence) return;
    cpSync(this.directory, this.copy, { recursive: true, filter: (source) => !source.endsWith("-shm") });
    this.stopped = true;
    this.signal.abort();
    throw new AuthorityUnreachable(`The process stopped once ${WRITE_STEPS[step]}`);
  }
}

/** One store write that a crash can interrupt. `arm` marks the start of the write under test. */
interface Scenario {
  readonly acknowledges: boolean;
  run(owner: Owner, arm: () => void): Promise<unknown>;
}

const SCENARIOS: Record<string, Scenario> = {
  "feedback capture": { acknowledges: true, async run(owner, arm) {
    const { feedback } = storesOf(owner);
    arm();
    return feedback.capture("Invented report about a garden", feedbackContext(), FEEDBACK_ID);
  } },
  "attachment upload": { acknowledges: true, async run(owner, arm) {
    const { attachments } = storesOf(owner), id = "88888888-8888-4888-8888-888888888888", bytes = Buffer.from("Invented attachment content");
    await attachments.request({ ...uploadChunk(id, bytes.subarray(0, 8), false), size_bytes: bytes.length });
    arm();
    return attachments.request({ ...uploadChunk(id, bytes.subarray(8), true), size_bytes: bytes.length, offset: 8 });
  } },
  "attachment retention": { acknowledges: true, async run(owner, arm) {
    const { attachments } = storesOf(owner), ref = await upload(attachments, "99999999-9999-4999-8999-999999999999", Buffer.from("Invented retained content"));
    arm();
    return attachments.retain([ref]);
  } },
  "history asset": { acknowledges: false, async run(owner, arm) {
    const { importer } = storesOf(owner);
    arm();
    return importHistory(importer, nativeHistory(ASSET));
  } },
};

async function crashableOwner(t: TestContext, connect: () => TestAuthority | Promise<TestAuthority>, target?: { step: WriteStep; occurrence: number }) {
  const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), copy = join(await stateDirectory(t), "state");
  const crash = new Crash(directory, copy, new AbortController(), target);
  crash.instrument(link);
  const owner = await openOwner(directory, link, { epoch, signal: crash.signal.signal, observe: crash.observe });
  return { link, epoch, directory, crash, owner };
}

/** Restarts from the directory as the crash left it: catch-up on open, then the startup cleanup. */
async function restart(link: TestAuthority, crash: Crash, stopped: Owner, epoch: number): Promise<Owner> {
  await stopped.harness.close(context).catch(() => {});
  crash.revive(link);
  const owner = await openOwner(crash.copy, link, { epoch });
  await cleanRetainedFiles(crash.copy);
  return owner;
}

for (const [name, connect] of Object.entries(authorities)) {
  test(`${name}: a crash at each step of each store's write leaves only files the log names, and a standby holds them all`, async (t) => {
    for (const [scenarioName, scenario] of Object.entries(SCENARIOS)) {
      const clean = await crashableOwner(t, connect);
      const acknowledged = await scenario.run(clean.owner, () => { clean.crash.armed = true; });
      await clean.owner.harness.close(context);
      for (const step of Object.keys(WRITE_STEPS)) assert.ok(clean.crash.reached.has(step as WriteStep), `${scenarioName} reaches the step where ${WRITE_STEPS[step as WriteStep]}`);
      if (scenarioName === "attachment upload") {
        const receipt = acknowledged as { attachment: AttachmentRef };
        assert.deepEqual(Buffer.from(await clean.link.getBlob(receipt.attachment.sha256)), Buffer.from("Invented attachment content"), "the blob store holds an acknowledged upload");
      }
      await assertMatchesLog(clean.directory, clean.link, `${scenarioName} without a crash`);
      console.log(`retained-file crash points: ${scenarioName}: ${[...clean.crash.reached].map(([step, count]) => `${step} ${count}`).join(", ")}`);

      for (const [step, occurrences] of clean.crash.reached) {
        for (let occurrence = 1; occurrence <= occurrences; occurrence += 1) {
          const label = `${scenarioName}, stopped at ${step} ${occurrence}`;
          const { link, epoch, crash, owner } = await crashableOwner(t, connect, { step, occurrence });
          const outcome = await scenario.run(owner, () => { crash.armed = true; }).then(() => "acknowledged", () => "refused");
          assert.ok(crash.stopped, `${label}: the process stopped`);
          if (scenario.acknowledges) assert.equal(outcome, "refused", `${label}: nothing is acknowledged`);
          const restarted = await restart(link, crash, owner, epoch);
          await assertMatchesLog(crash.copy, link, `${label}, after the catch-up`);
          await restarted.harness.close(context);
          assert.deepEqual(Object.keys(await retainedFiles(crash.copy)).sort(), [...(await loggedFiles(link)).keys()].sort(), `${label}: after the cleanup every retained file is one the log names`);
          const standby = await stateDirectory(t);
          await follow(standby, link);
          assert.deepEqual(await retainedFiles(standby), await retainedFiles(crash.copy), `${label}: the standby holds the owner's retained files`);
        }
      }
    }
  });

  test(`${name}: feedback that crashed before its record was logged is not found after a restart, and its resubmit reaches the standby`, async (t) => {
    const { link, epoch, crash, owner } = await crashableOwner(t, connect, { step: "uploaded", occurrence: 2 });
    crash.armed = true;
    await assert.rejects(storesOf(owner).feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID), /Stopped waiting for the authority/);
    const restarted = await restart(link, crash, owner, epoch);
    t.after(() => restarted.harness.close(context));
    const { feedback } = storesOf(restarted);
    await assert.rejects(feedback.read(FEEDBACK_ID), { code: "ENOENT" });
    const bundle = await feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID);
    assert.equal(bundle.id, FEEDBACK_ID);
    assert.deepEqual(await feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID), bundle, "a repeat is answered from the logged bundle");
    assert.deepEqual([...(await loggedFiles(link)).keys()].sort(), [`feedback/${FEEDBACK_ID}.json`, "feedback/latest"]);
    const standby = await stateDirectory(t);
    await follow(standby, link);
    for (const path of [`feedback/${FEEDBACK_ID}.json`, "feedback/latest"]) {
      assert.deepEqual(await readFile(join(standby, path)), await readFile(join(crash.copy, path)), `the standby holds ${path} with the owner's bytes`);
    }
  });

  test(`${name}: a complete upload that was never sent reaches a standby, and an unfinished one stays on the owner until the cleanup`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { attachments } = storesOf(owner);
    const complete = await upload(attachments, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", Buffer.from("Invented finished upload"));
    const unfinished = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
    await attachments.request({ ...uploadChunk(unfinished, Buffer.from("Invented"), false), size_bytes: 64 });
    await follow(standby, link);
    for (const file of ["content", "metadata.json"]) {
      const path = join("attachments", complete.id, file);
      assert.deepEqual(await readFile(join(standby, path)), await readFile(join(directory, path)), `the standby holds ${path}`);
    }
    assert.deepEqual(Object.keys(await retainedFiles(standby)).filter((path) => path.includes(unfinished)), [], "the unfinished upload is not on the standby");
    assert.equal(Object.keys(await retainedFiles(directory)).filter((path) => path.includes(unfinished)).length, 2, "the owner keeps it while it uploads");
    await cleanRetainedFiles(directory);
    assert.deepEqual(await retainedFiles(directory), await retainedFiles(standby), "the cleanup removes it from the owner");
  });

  test(`${name}: a discarded upload leaves the owner, the log's files and a standby that already held it`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { attachments } = storesOf(owner);
    const kept = await upload(attachments, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", Buffer.from("Invented kept upload"));
    const discarded = await upload(attachments, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", Buffer.from("Invented discarded upload"));
    await follow(standby, link);
    assert.equal(Object.keys(await retainedFiles(standby)).filter((path) => path.includes(discarded.id)).length, 2, "the standby holds the upload before the discard");
    assert.deepEqual(await attachments.request({ type: "discard", id: discarded.id }), { type: "discarded" });
    const remaining = [`attachments/${kept.id}/content`, `attachments/${kept.id}/metadata.json`];
    assert.deepEqual(Object.keys(await retainedFiles(directory)).sort(), remaining);
    assert.deepEqual([...(await loggedFiles(link)).keys()].sort(), remaining, "the log no longer names the discarded upload");
    await follow(standby, link);
    assert.deepEqual(await retainedFiles(standby), await retainedFiles(directory), "the standby holds what the owner holds");
    assert.equal(existsSync(join(standby, "attachments", discarded.id)), false, "the upload's directory is gone from the standby");
  });

  test(`${name}: a discard that stopped after the authority applied its entry is finished by the restart`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), stopped = new AbortController();
    const owner = await openOwner(directory, link, { epoch, signal: stopped.signal });
    const { attachments } = storesOf(owner);
    const ref = await upload(attachments, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", Buffer.from("Invented upload whose discard is cut off"));
    link.afterApplied = (command) => {
      if (command.op !== "append" || command.entry.removed.length === 0) return;
      stopped.abort();
      throw new AuthorityUnreachable("The process stopped once the authority applied the removal and its reply was lost");
    };
    await assert.rejects(attachments.request({ type: "discard", id: ref.id }), /Stopped waiting for the authority/);
    assert.equal(Object.keys(await retainedFiles(directory)).length, 2, "the stopped owner still holds the upload");
    await owner.harness.close(context).catch(() => {});
    link.afterApplied = () => {};
    const restarted = await openOwner(directory, link, { epoch });
    t.after(() => restarted.harness.close(context));
    assert.deepEqual(await retainedFiles(directory), {}, "the catch-up on open removes what the log removed");
    assert.deepEqual(await storesOf(restarted).attachments.request({ type: "discard", id: ref.id }), { type: "discarded" }, "a repeat of the discard finds nothing left to remove");
  });

  test(`${name}: admission that retains an attachment, and one that restores it, leave the same metadata on owner and standby`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { attachments } = storesOf(owner);
    const metadata = (id: string) => join("attachments", id, "metadata.json");
    const restored = await upload(attachments, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", Buffer.from("Invented restored content"));
    const uploaded = await readFile(join(directory, metadata(restored.id)));
    assert.equal(await attachments.admit([restored], () => undefined), undefined);
    assert.deepEqual(await readFile(join(directory, metadata(restored.id))), uploaded, "the restore puts back the metadata it replaced");
    const retained = await upload(attachments, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", Buffer.from("Invented retained content"));
    const pending = await attachments.admit([retained], () => owner.root.submit({ type: "write", requestId: "admission",
      entry: { kind: "fixture.admission", data: { attachment_id: retained.id } } }, context));
    await pending;
    assert.equal((JSON.parse(await readFile(join(directory, metadata(retained.id)), "utf8")) as { retained: boolean }).retained, true);
    await follow(standby, link);
    for (const id of [restored.id, retained.id]) {
      assert.deepEqual(await readFile(join(standby, metadata(id))), await readFile(join(directory, metadata(id))), `the standby holds the owner's ${metadata(id)}`);
    }
  });

  test(`${name}: an imported asset reaches a standby under its hash, and a transfer that fails verification logs nothing`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { importer } = storesOf(owner);
    const forged = Buffer.from("Invented bytes that do not match their advertised digest");
    assert.equal((await importHistory(importer, nativeHistory(forged, sha256Hex("Invented other bytes")))).phase, "partial");
    assert.deepEqual(await loggedFiles(link), new Map(), "a failed verification logs no file");
    assert.deepEqual(await filesUnder(join(directory, "history", "assets")), [], "and leaves no file");
    assert.equal((await importHistory(importer, nativeHistory(ASSET))).phase, "complete");
    await follow(standby, link);
    const path = join("history", "assets", sha256Hex(ASSET));
    assert.deepEqual(await readFile(join(standby, path)), ASSET);
    assert.deepEqual(await retainedFiles(standby), await retainedFiles(directory));
  });

  test(`${name}: while the authority is unreachable a write waits and lands once after it returns, and reads of existing files complete`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { attachments, feedback } = storesOf(owner);
    const existing = await upload(attachments, "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", Buffer.from("Invented existing upload"));
    const bundle = await feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID);
    const putBlob = link.putBlob.bind(link);
    const reachable = () => { link.putBlob = putBlob; link.beforeCommand = () => {}; };
    link.putBlob = async () => { throw new AuthorityUnreachable("The authority is unreachable"); };
    link.beforeCommand = () => { throw new AuthorityUnreachable("The authority is unreachable"); };
    let settled = false;
    const waiting = upload(attachments, "ffffffff-ffff-4fff-8fff-ffffffffffff", Buffer.from("Invented upload while unreachable")).finally(() => { settled = true; });
    try {
      const read = <T>(label: string, reading: Promise<T>) => Promise.race([reading,
        sleep(2_000).then(() => { throw new Error(`${label} waited behind the write for the unreachable authority`); })]);
      assert.deepEqual(await read("a download", attachments.request({ type: "download", id: existing.id, offset: 0, limit: 64 })),
        { type: "download", data_base64: Buffer.from("Invented existing upload").toString("base64"), next_offset: null });
      assert.deepEqual(await read("a feedback read", feedback.read(bundle.id)), bundle);
      assert.deepEqual(await read("a reference lookup", attachments.references([existing.id])), [existing]);
      await sleep(300);
      assert.equal(settled, false, "the write waits for the authority");
    } finally { reachable(); }
    const landed = await waiting;
    const entries = (await logEntries(link)).filter((entry) => entry.files.some((file) => file.path === `attachments/${landed.id}/content`));
    assert.equal(entries.length, 1, "the write lands once");
  });

  test(`${name}: a write from a fenced owner is refused and gives no file its final name`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context).catch(() => {}));
    const { attachments, feedback } = storesOf(owner);
    await replaceOwner(link, STANDBY, epoch);
    await assert.rejects(feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID), OwnerFenced);
    await assert.rejects(upload(attachments, "12121212-1212-4212-8212-121212121212", Buffer.from("Invented fenced upload")), OwnerFenced);
    assert.deepEqual(await finalNamed(directory), []);
    assert.deepEqual((await filesUnder(directory)).filter(temporaryName), [], "the refused writes leave no temporary file");
  });

  test(`${name}: no invented secret from auth.json or diagnostics reaches a log entry or a blob`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const markers = ["invented-auth-sentinel-5f1e", "invented-diagnostics-sentinel-c07a"];
    await writeFile(join(directory, "auth.json"), JSON.stringify({ openai: { type: "api_key", key: markers[0] } }));
    await mkdir(join(directory, "diagnostics"));
    await writeFile(join(directory, "diagnostics", "startup.jsonl"), `${JSON.stringify({ event: "invented", detail: markers[1] })}\n`);
    const uploaded: Uint8Array[] = [];
    const putBlob = link.putBlob.bind(link);
    link.putBlob = async (sha256, bytes) => { uploaded.push(Uint8Array.from(bytes)); await putBlob(sha256, bytes); };
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    const { attachments, feedback } = storesOf(owner);
    const ref = await upload(attachments, "13131313-1313-4313-8313-131313131313", Buffer.from("Invented attachment"));
    await (await attachments.admit([ref], () => owner.root.submit({ type: "write", requestId: "sentinel-admission",
      entry: { kind: "fixture.admission", data: { attachment_id: ref.id } } }, context)));
    owner.faux.setResponses([fauxAssistantMessage("Invented reply about the garden.")]);
    assert.equal((await (await owner.root.submit({ type: "input", content: "Invented question", requestId: "sentinel-turn" }, context)).wait(context)).status, "done");
    await feedback.capture("Invented report", feedbackContext(), FEEDBACK_ID);
    const entries = await logEntries(link);
    assert.ok(entries.some((entry) => entry.files.length > 0) && uploaded.length > 0, "the run logged files and uploaded blobs");
    for (const marker of markers) {
      assert.equal(JSON.stringify(entries).includes(marker), false, `${marker} is in no log entry`);
      assert.equal(uploaded.some((bytes) => Buffer.from(bytes).includes(marker)), false, `${marker} is in no blob`);
    }
  });
}
