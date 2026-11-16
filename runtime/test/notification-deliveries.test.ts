import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash, generateKeyPairSync } from "node:crypto";
import { chmod, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { createServer, type IncomingHttpHeaders, type ServerHttp2Session, type ServerHttp2Stream } from "node:http2";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall } from "@earendil-works/pi-ai";
import { createRegistry, Harness, ROOT_CONVERSATION_ID, type EntryRecord } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { ApnsConfig } from "../src/generated/ApnsConfig.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { WorkerRef } from "../src/generated/WorkerRef.js";
import { ConversationModels } from "../src/models.js";
import { notificationDeliveryKey, NotificationDeliveries, Notifications } from "../src/notifications.js";
import { SourceJournal, createSourceTools } from "../src/sources.js";
import { TaskStore } from "../src/tasks.js";
import { Executions } from "../src/tools.js";
import { isUserNotice } from "../src/transcript.js";
import { fixtureModel } from "./model.js";

const installation = "5e1f0a2b-3c4d-4e5f-8a6b-7c8d9e0f1a2b";
const token = "feedc0de".repeat(8);
const binding: WorkerRef = { host_id: "11111111-1111-4111-8111-111111111111",
  session_id: "session:22222222-2222-4222-8222-222222222222",
  window_id: "window:33333333-3333-4333-8333-333333333333",
  block_id: "block:44444444-4444-4444-8444-444444444444" };
const host = { host_id: null, name: "fixture", rex_server: null, coordinator: null,
  cwd: "/workspace/example", agent_program: "/example/agent" };
const script = fileURLToPath(new URL("../../scripts/notification-deliveries.mjs", import.meta.url));

type Line = Record<string, unknown>;
async function waitFor(signal: AbortSignal, condition: () => Promise<boolean>): Promise<void> {
  while (!(await condition())) await delay(5, undefined, { signal });
}
// A read-only SQLite reader may leave the empty WAL sidecars a live
// coordinator already keeps, so only the database file itself is compared.
async function fingerprint(directory: string) {
  const file = join(directory, "session.sqlite"), info = await stat(file);
  return { files: (await readdir(directory)).filter((name) => !/-(wal|shm)$/u.test(name)).sort(),
    sha256: createHash("sha256").update(await readFile(file)).digest("hex"), mtime: info.mtimeMs, size: info.size };
}
async function walBytes(directory: string): Promise<number> {
  return (await stat(join(directory, "session.sqlite-wal")).catch(() => ({ size: 0 }))).size;
}
async function readRecords(args: string[]): Promise<{ lines: Line[]; stdout: string; stderr: string }> {
  const child = spawn(process.execPath, ["--no-warnings", "--input-type=module", "-", ...args], { stdio: ["pipe", "pipe", "pipe"] });
  let stdout = "", stderr = "";
  child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
  child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
  const closed = new Promise<number | null>((resolve, reject) => { child.once("error", reject); child.once("close", resolve); });
  child.stdin.end(await readFile(script));
  assert.equal(await closed, 0, stderr);
  return { lines: stdout.trim().split("\n").map((line) => JSON.parse(line) as Line), stdout, stderr };
}

test("the delivery record reader reports each alert's durable APNs outcome read-only and never prints a token", { timeout: 20_000 }, async (t) => {
  const started = Date.now(), directory = await mkdtemp(join(tmpdir(), "agent-delivery-records-")); await chmod(directory, 0o700);
  const keys = generateKeyPairSync("ec", { namedCurve: "prime256v1" }), keyFile = join(directory, "AuthKey.p8");
  await writeFile(keyFile, keys.privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  const config: ApnsConfig = { team_id: "TEAM000001", key_id: "KEY0000001", topic: "dev.example.Agent", key_file: keyFile, environment: "sandbox" };
  const server = createServer(), connections = new Set<ServerHttp2Session>(), sent = new Map<string, string>();
  server.on("session", (connection) => { connections.add(connection); connection.on("error", () => {}); connection.once("close", () => connections.delete(connection)); });
  server.on("stream", (stream: ServerHttp2Stream, headers: IncomingHttpHeaders) => {
    let body = ""; stream.on("error", () => {});
    stream.setEncoding("utf8").on("data", (chunk: string) => { body += chunk; });
    stream.once("end", () => {
      const agent = (JSON.parse(body) as { agent: { entry_id: string } }).agent;
      sent.set(agent.entry_id, String(headers["apns-id"])); stream.respond({ ":status": 200 }); stream.end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address(); assert.ok(address !== null && typeof address === "object");

  const models = createModels(), faux = fauxProvider({ provider: "openai", models: [{ id: "fixture" }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const registry = createRegistry(), session = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const tasks = new TaskStore(session, new ConversationModels(models)), executions = new Executions();
  const tools = createSourceTools(new SourceJournal(session, tasks, executions), executions);
  registry.install(tools.main); registry.install(tools.worker);
  const notifications = new Notifications(session, registry, config, `http://127.0.0.1:${address.port}`);
  let release = () => {}, open = true;
  const held = new Promise<void>((resolve) => { release = resolve; });
  let execution: Promise<unknown> | undefined;
  const shutdown = async () => {
    if (!open) return; open = false; release(); await execution?.catch(() => {});
    notifications.close(); await session.close(BACKGROUND_CONTEXT);
  };
  t.after(async () => {
    await shutdown(); for (const connection of connections) connection.destroy();
    await new Promise<void>((resolve, reject) => server.close((error) => error === undefined ? resolve() : reject(error)));
    await rm(directory, { recursive: true, force: true });
  });
  assert.equal(await notifications.start(), true); session.resume();
  const root = await session.root(BACKGROUND_CONTEXT);
  await root.configure({ model: { provider: "openai", modelId: "fixture" } }, BACKGROUND_CONTEXT);
  const reply = async (text: string): Promise<EntryRecord> => {
    faux.setResponses([fauxAssistantMessage(text)]);
    assert.equal((await (await root.submit({ type: "input", content: "Report progress." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT)).status, "done");
    const entry = (await root.entries({ order: "descending" }, 1, undefined, BACKGROUND_CONTEXT)).items[0]; assert.ok(entry);
    return entry;
  };
  const accepted = (entry: EntryRecord) => waitFor(t.signal, async () =>
    (await session.snapshot(NotificationDeliveries, notificationDeliveryKey(installation, entry.id.toString()), BACKGROUND_CONTEXT))?.delivery?.state === "accepted");

  const unsent = await reply("Before any phone registered QUIET-BEFORE-REGISTER private detail.");
  await notifications.request({ type: "register", installation_id: installation, token });
  const main = await reply("The main reply is ready MAIN-REPLY-NEEDLE private detail.");
  await accepted(main);

  const job = await tasks.create({ title: "Continue the requested job", outcome: "Verify the result", model: fixtureModel });
  await tasks.enqueue(job.id, "Continue authorized work.");
  await tasks.dispatch(job.id, host, async () => ({ type: "spawned", binding }));
  const worker = await tasks.get(job.id); assert.ok(worker.worker.state === "bound");
  const run: Extract<RuntimeCommand, { type: "run_task" }> = { type: "run_task", task_id: job.id, allocation_id: worker.worker.allocation_id,
    binding, instructions: "", model: fixtureModel, cwd: host.cwd };
  let reached = () => {};
  const continuing = new Promise<void>((resolve) => { reached = resolve; });
  faux.setResponses([
    fauxAssistantMessage(fauxToolCall("notify_user", { text: "Halfway there MID-JOB-NOTICE-NEEDLE private detail." }, { id: "mid-job-update" }), { stopReason: "toolUse" }),
    async () => { reached(); await held; return fauxAssistantMessage("The job is now complete."); },
  ]);
  execution = tasks.run(run, (conversation) => executions.bind(conversation.id.toString(), {
    cwd: host.cwd, hosts: [host], role: "worker", call: async () => { throw new Error("No host effects are needed"); },
    notify: () => { throw new Error("Canonical publication must not invoke a direct callback"); },
  }), [tools.worker]);
  await Promise.race([continuing, execution.then(() => { throw new Error("The worker ended before publishing its notice"); })]);
  const notice = (await root.entries({ order: "descending" }, 20, undefined, BACKGROUND_CONTEXT)).items.find(isUserNotice); assert.ok(notice);
  await accepted(notice);
  assert.equal(tasks.isRunning(job.id), true, "The notice must be delivered while its job still runs");
  // Task end times and delivery queue times are wall-clock milliseconds; a
  // shared millisecond would leave their order unprovable.
  await delay(5);
  release(); await execution; execution = undefined;
  await shutdown();

  const before = await fingerprint(directory);
  const { lines, stdout, stderr } = await readRecords(["--database", join(directory, "session.sqlite"),
    "--text", "MAIN-REPLY-NEEDLE", "--text", "MID-JOB-NOTICE-NEEDLE", "--text", "QUIET-BEFORE-REGISTER", "--text", "NEVER-SENT-NEEDLE",
    "--tasks-since-entry", notice.id.toString()]);
  assert.deepEqual(await fingerprint(directory), before, "Reading delivery records must not change the database or leave files behind");
  assert.equal(await walBytes(directory), 0, "The reader must not write WAL frames");

  for (const output of [stdout, stderr]) {
    assert.equal(output.toLowerCase().includes(token), false, "A device token must never be printed");
    assert.equal(output.includes(installation), false, "Only an installation prefix may be printed");
    assert.equal(output.includes("private detail"), false, "Entry text is reported only as a needle match");
  }
  for (const [needle, entry, kind] of [["MAIN-REPLY-NEEDLE", main, "assistant"], ["MID-JOB-NOTICE-NEEDLE", notice, "notice"]] as const) {
    const line = lines.find((candidate) => candidate.record === "delivery" && candidate.needle === needle); assert.ok(line);
    const { entry_commit_seq, created_at, queued_at, ...rest } = line;
    assert.deepEqual(rest, { record: "delivery", needle, matched: true, entry_id: entry.id.toString(), conversation_id: ROOT_CONVERSATION_ID.toString(),
      entry_kind: kind, state: "accepted", status: 200, attempts: 1, apns_id: sent.get(entry.id.toString()), installation_id: installation.slice(0, 8) });
    assert.ok(typeof entry_commit_seq === "number" && typeof created_at === "number" && created_at >= entry_commit_seq,
      "A delivery document is created no earlier than the entry it announces");
    assert.ok(typeof queued_at === "number" && queued_at >= started && queued_at <= Date.now());
  }
  assert.ok(lines.some((line) => line.record === "entry" && line.needle === "QUIET-BEFORE-REGISTER" && line.entry_id === unsent.id.toString() && line.deliveries === 0));
  assert.ok(lines.some((line) => line.record === "missing" && line.needle === "NEVER-SENT-NEEDLE" && line.entry_id === null && line.deliveries === 0));
  assert.equal(lines.filter((line) => line.record === "delivery").length, 2);

  const since = lines.find((line) => line.record === "since_entry");
  assert.ok(since); assert.equal(since.entry_id, notice.id.toString()); assert.equal(since.job_id, job.id);
  assert.equal(since.source_conversation_id, worker.conversation_id);
  const continued = lines.filter((line) => line.record === "task" && line.evidence === "source_ran_after_entry");
  assert.ok(continued.some((line) => line.kind === "pi.generation" && line.status === "terminal" && line.outlived_delivery_queue === true &&
    typeof line.ended_at === "number" && typeof since.earliest_queued_at === "number" && line.ended_at > since.earliest_queued_at),
  "The worker's next turn shows the job still ran after the notice's delivery was queued");
  assert.ok(continued.every((line) => line.notice_source === true && line.conversation_id === worker.conversation_id));
});
