import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { cp, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, symlink, truncate, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { AttachmentStore } from "../src/attachments.js";
import { FeedbackStore } from "../src/feedback.js";
import { HistoryStore } from "../src/history.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import { runScheduled } from "../src/scheduled.js";
import type { AttachmentRef } from "../src/generated/AttachmentRef.js";
import type { HistoryItem } from "../src/generated/HistoryItem.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import { ATTACHMENT_CHUNK_BYTES } from "../src/generated/attachment-limits.js";
import { node, openScheduled, scheduledOccurrence } from "./fixtures/scheduled-runtime.js";

type Server = { child: ChildProcessWithoutNullStreams; closed: Promise<number | null>; errors(): string };
type Run = { code: number | null; stdout: string; stderr: string };
type Seeded = { taskId: string; agentId: string; scheduledTaskId: string; importedConversation: string; attachment: AttachmentRef;
  attachmentBytes: Buffer; feedbackId: string; fullOriginal: string; inputIds: string[] };

const STEER_ID = "a1111111-1111-4111-8111-111111111111";
const FOLLOW_UP_ID = "a2222222-2222-4222-8222-222222222222";
const AGENT_INPUT_ID = "a3333333-3333-4333-8333-333333333333";
const ATTACHMENT_ID = "a4444444-4444-4444-8444-444444444444";
const HELD_JOB = "invented-held-review";

function sha256(bytes: Buffer): string { return createHash("sha256").update(bytes).digest("hex"); }
async function exists(path: string): Promise<boolean> { return stat(path).then(() => true, () => false); }

async function fingerprint(root: string): Promise<Map<string, string>> {
  const files = new Map<string, string>();
  for (const entry of await readdir(root, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile()) continue;
    const path = join(entry.parentPath, entry.name);
    files.set(path.slice(root.length + 1), sha256(await readFile(path)));
  }
  return files;
}

async function seed(state: string): Promise<Seeded> {
  const app = await openScheduled(state);
  try {
    app.faux.setResponses([fauxAssistantMessage("The invented scheduled review is complete.")]);
    await runScheduled(scheduledOccurrence, new AbortController().signal, app);
    const scheduledTask = (await app.tasks.list())[0]; assert.ok(scheduledTask, "the scheduled occurrence owns a task");

    const attachments = new AttachmentStore(state); app.tasks.useAttachments(attachments);
    const attachmentBytes = Buffer.from("Invented ledger line one.\nInvented ledger line two.\n".repeat(4000));
    let attachment: AttachmentRef | null = null;
    for (let offset = 0; offset < attachmentBytes.length; offset += ATTACHMENT_CHUNK_BYTES) {
      const chunk = attachmentBytes.subarray(offset, offset + ATTACHMENT_CHUNK_BYTES), complete = offset + chunk.length === attachmentBytes.length;
      const uploaded = await attachments.request({ type: "upload", id: ATTACHMENT_ID, name: "invented-ledger.txt", media_type: "text/plain",
        size_bytes: attachmentBytes.length, offset, data_base64: chunk.toString("base64"), complete });
      assert.equal(uploaded.type, "uploaded"); if (uploaded.type === "uploaded") attachment = uploaded.attachment;
    }
    assert.ok(attachment !== null, "the completed upload returns its receipt");

    const task = await app.tasks.create({ title: "Invented backup fixture", outcome: "Keep every admitted input across restore" });
    await app.tasks.enqueue(task.id, "Steer toward the invented ledger.", STEER_ID, undefined, "steer");
    await app.tasks.enqueue(task.id, "Follow up with the attached ledger.", FOLLOW_UP_ID, undefined, "follow_up", [attachment]);
    const agent = await app.tasks.createAgent(task.id, { id: "invented-child", title: "Invented child", outcome: "Check the invented ledger",
      input: "Read the invented ledger and report totals.", inputId: AGENT_INPUT_ID });

    const assets = join(state, "history", "assets"); await mkdir(assets, { recursive: true, mode: 0o700 });
    const fullOriginal = "The retained detail is a zirconium connector. " + "Earlier invented context. ".repeat(100);
    const cold = Buffer.from(JSON.stringify({ type: "userMessage", content: [{ type: "text", text: fullOriginal }] }));
    const coldSha = sha256(cold); await writeFile(join(assets, coldSha), cold, { mode: 0o600 });
    const item: HistoryItem = { id: "invented-item", turn_id: "invented-turn", kind: "userMessage", role: "user", text: "Bounded excerpt only.",
      version: "v1", order: 0, timestamp_ms: 1, data: null,
      assets: [{ path: join(assets, coldSha), item_id: "invented-item", version: "v1", kind: "cold_evidence", media_type: "application/json",
        sha256: coldSha, size: cold.length }] };
    const imported = await new HistoryStore(app.session, assets).import({ host_id: node.host_id,
      thread: { id: "invented-thread", title: "Invented imported thread", cwd: "/workspace/example", created_at: 1, updated_at: 2,
        forked_from_id: null, parent_thread_id: null, version: "thread-v1", version_reliable: true, archived: false },
      items: [item], next_cursor: null, complete: true, gaps: [] });
    const large = randomBytes(16 * 1024 * 1024); await writeFile(join(assets, sha256(large)), large, { mode: 0o600 });

    const feedback = new FeedbackStore(state, app.tasks);
    const bundle = await feedback.capture("Invented feedback about the ledger task.", { attachments: [attachment], origin_host_id: node.host_id,
      cwd: "/workspace/example", conversation_id: null, task_id: task.id, agent_id: null, model: null, binding: null, draft: "",
      queued_inputs: [], client_errors: [] });
    await attachments.retain(bundle.context.attachments);

    return { taskId: task.id, agentId: agent.id, scheduledTaskId: scheduledTask.id, importedConversation: imported.conversation.conversation_id,
      attachment, attachmentBytes, feedbackId: bundle.id, fullOriginal, inputIds: [STEER_ID, FOLLOW_UP_ID, AGENT_INPUT_ID] };
  } finally { await app.close(); }
}

test("an offline backup restores into a new directory that the production coordinator reads identically", { timeout: 600_000 }, async (t) => {
  const directory = await mkdtemp("/tmp/agent-backup-e2e-");
  const original = join(directory, "original"), restored = join(directory, "restored"), moved = join(directory, "original-moved");
  const archive = join(directory, "archive"), bin = join(directory, "bin"), jobs = join(directory, "jobs");
  const plainConfig = join(directory, "plain.toml"), jobConfig = join(directory, "jobs.toml"), instructions = join(directory, "AGENTS.md");
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/beep-boop", import.meta.url));
  const runtime = fileURLToPath(new URL("../src/bridge.js", import.meta.url));
  const servers: Server[] = [];
  const env = { PATH: bin, HOME: directory, XDG_CONFIG_HOME: join(directory, "config"), XDG_DATA_HOME: join(directory, "data"),
    TMPDIR: directory, AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC };

  function cli(args: string[]): Promise<Run> {
    const child = spawn(binary, ["--runtime", runtime, ...args], { cwd: directory, env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (value: string) => { stdout += value; });
    child.stderr.setEncoding("utf8").on("data", (value: string) => { stderr += value; });
    return new Promise((resolve, reject) => { child.once("error", reject); child.once("close", (code) => resolve({ code, stdout, stderr })); });
  }
  function refused(run: Run, pattern: RegExp, label: string): void {
    assert.notEqual(run.code, 0, `${label} must be refused: ${run.stdout}`);
    assert.match(run.stderr, pattern, label);
  }
  async function start(state: string, config: string, script = runtime): Promise<Server> {
    const child = spawn(binary, ["--state-dir", state, "--config", config, "--runtime", script, "--instructions", instructions,
      "serve", "--local-only", "--no-sources"], { cwd: directory, detached: true, stdio: ["pipe", "pipe", "pipe"], env });
    let stderr = "";
    child.stderr.setEncoding("utf8").on("data", (value: string) => { stderr += value; });
    child.stdout.resume();
    const closed = new Promise<number | null>((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
    void closed.catch(() => {});
    const server = { child, closed, errors: () => stderr }; servers.push(server);
    return server;
  }
  async function ready(server: Server, state: string): Promise<void> {
    for (;;) {
      assert.equal(server.child.exitCode, null, server.errors());
      t.signal.throwIfAborted();
      try { await request(state, { type: "job_status" }); return; } catch (error) {
        if (!(error instanceof Error && "code" in error && (error.code === "ENOENT" || error.code === "ECONNREFUSED"))) throw error;
        await delay(20, undefined, { signal: t.signal });
      }
    }
  }
  async function stop(server: Server): Promise<void> {
    server.child.kill("SIGINT");
    assert.equal(await server.closed, 0, server.errors());
  }
  async function request(state: string, command: RuntimeCommand): Promise<RuntimeEventKind[]> {
    const channel = createConnection({ path: join(state, "agent.sock"), signal: t.signal });
    const events: RuntimeEventKind[] = [];
    try {
      channel.write(JSON.stringify(command) + "\n");
      for await (const line of protocolLines(channel)) {
        const frame = { version: 1, id: 1, event: JSON.parse(line) as unknown };
        assert.ok(validEvent(frame), "The production coordinator must emit its Rust-owned wire schema");
        if (frame.event.type === "failure") throw new Error(`${command.type} failed: ${frame.event.message}`);
        if (frame.event.type === "done") return events;
        events.push(frame.event);
      }
      throw new Error(`The coordinator closed before finishing ${command.type}`);
    } finally { channel.destroy(); }
  }
  async function download(state: string, id: string): Promise<Buffer> {
    const chunks: Buffer[] = []; let offset: number | null = 0;
    while (offset !== null) {
      const [event] = await request(state, { type: "attachment", request: { type: "download", id, offset, limit: ATTACHMENT_CHUNK_BYTES } });
      assert.ok(event?.type === "attachment" && event.response.type === "download", JSON.stringify(event));
      chunks.push(Buffer.from(event.response.data_base64, "base64")); offset = event.response.next_offset;
    }
    return Buffer.concat(chunks);
  }
  async function readBack(state: string, seeded: Seeded) {
    const tasks = [];
    for (const taskId of [seeded.taskId, seeded.scheduledTaskId]) {
      tasks.push(await request(state, { type: "read_task", task_id: taskId }));
      tasks.push(await request(state, { type: "read_history", task_id: taskId, agent_id: null, cursor: null }));
    }
    const agent = await request(state, { type: "read_history", task_id: seeded.taskId, agent_id: seeded.agentId, cursor: null });
    const imported = await request(state, { type: "read_conversation", conversation_id: seeded.importedConversation, cursor: null });
    const feedback = await request(state, { type: "read_feedback", id: seeded.feedbackId });
    const attachment = await download(state, seeded.attachment.id);
    return { tasks, agent, imported, feedback, attachment: sha256(attachment) };
  }

  try {
    await mkdir(original, { mode: 0o700 }); await mkdir(bin, { mode: 0o700 }); await mkdir(jobs, { mode: 0o700 });
    await symlink(process.execPath, join(bin, "node"));
    await writeFile(instructions, "Use only invented test data.\n");
    await writeFile(plainConfig, 'node_name = "backup-e2e"\njob_directories = []\n');
    await writeFile(jobConfig, `node_name = "backup-e2e"\njob_directories = [${JSON.stringify(jobs)}]\n`);
    await writeFile(join(jobs, `${HELD_JOB}.toml`), `id = "${HELD_JOB}"\nprompt = "Summarize the invented ledger."\nmodel = "fixture"\n` +
      'reasoning_effort = "medium"\ntimezone = "UTC"\n\n[[schedules]]\nid = "daily"\n' +
      'recurrence = "DTSTART:20990101T090000Z\\nRRULE:FREQ=DAILY;BYHOUR=9;BYMINUTE=0;BYSECOND=0"\n');

    const seeded = await seed(original);
    await writeFile(join(original, "auth.json"), JSON.stringify({ invented: { type: "api_key", key: "invented-not-a-credential" } }), { mode: 0o600 });
    await writeFile(join(original, "invented-unknown.txt"), "An unknown file is reported, never copied.\n", { mode: 0o600 });

    let server = await start(original, plainConfig); await ready(server, original);
    const baseline = await readBack(original, seeded);
    assert.equal(baseline.attachment, seeded.attachment.sha256);
    assert.equal(baseline.attachment, sha256(seeded.attachmentBytes));
    const importedText = baseline.imported.flatMap((event) => event.type === "history" ? event.messages.map((message) => message.text) : []).join("");
    assert.ok(importedText.includes("zirconium connector") && !importedText.includes("Bounded excerpt only."), "the original store renders its retained cold original");
    const coordinatorId = await readFile(join(original, "coordinator-id"), "utf8");

    refused(await cli(["--state-dir", original, "backup", "create", archive]), /Another agent process owns this state directory/, "backup of a live coordinator");
    assert.equal(await exists(archive), false, "a refused backup publishes nothing");
    await stop(server);

    const linger = join(directory, "linger.mjs");
    await writeFile(linger, `import { createInterface } from "node:readline";
      setInterval(() => {}, 1000);
      createInterface({ input: process.stdin }).on("line", (line) => {
        const { id, command } = JSON.parse(line);
        if (command.type === "run_background") return;
        process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "configured" } }) + "\\n");
        process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "done" } }) + "\\n");
      });\n`);
    const supervisor = await start(original, plainConfig, linger);
    while (!await exists(join(original, "agent.sock"))) { assert.equal(supervisor.child.exitCode, null, supervisor.errors()); await delay(10); }
    supervisor.child.kill("SIGKILL"); await supervisor.closed;
    const beforeRefusal = await fingerprint(original);
    refused(await cli(["--state-dir", original, "backup", "create", archive]), /Another agent process owns this state directory/, "backup while a Pi child survives");
    assert.equal(await exists(archive), false);
    assert.deepEqual(await fingerprint(original), beforeRefusal, "a refused backup leaves the original store byte-identical");
    process.kill(-supervisor.child.pid!, "SIGKILL");
    await rm(join(original, "agent.sock"), { force: true });

    const beforeBackup = await fingerprint(original);
    let created: Run | undefined;
    for (const deadline = Date.now() + 10_000; ;) {
      created = await cli(["--state-dir", original, "--json", "backup", "create", archive]);
      if (created.code === 0 || !/Another agent process owns/.test(created.stderr) || Date.now() > deadline) break;
      await delay(50);
    }
    assert.equal(created.code, 0, created.stderr);
    const receipt = JSON.parse(created.stdout) as { coordinator_id: string; archive: string; files: number; bytes: number; not_included: string[] };
    assert.equal(receipt.coordinator_id, coordinatorId);
    assert.ok(receipt.files >= 6 && receipt.bytes > 16 * 1024 * 1024, created.stdout);
    assert.deepEqual(receipt.not_included, ["invented-unknown.txt"], "every name the production coordinator wrote is classified; unknown state is reported, not copied");
    const afterBackup = await fingerprint(original);
    for (const [path, digest] of beforeBackup) assert.equal(afterBackup.get(path), digest, `a backup leaves ${path} byte-identical`);
    for (const [path, digest] of afterBackup) {
      if (!beforeBackup.has(path)) {
        assert.ok(path === "session.sqlite-shm" || (path === "session.sqlite-wal" && digest === sha256(Buffer.alloc(0))),
          `a backup adds only SQLite's read-only bookkeeping to the original store, not ${path}`);
      }
    }
    const manifest = JSON.parse(await readFile(join(archive, "manifest.json"), "utf8")) as { format: number; coordinator_id: string;
      database_integrity: string; sqlite_schema_version: number; files: { path: string; kind: string; size: number; sha256: string }[] };
    assert.equal(manifest.format, 1); assert.equal(manifest.coordinator_id, coordinatorId); assert.equal(manifest.database_integrity, "ok");
    assert.ok(manifest.sqlite_schema_version >= 1);
    assert.deepEqual([...new Set(manifest.files.map((file) => file.kind))].sort(),
      ["attachment", "coordinator_id", "database", "feedback", "history_asset"]);
    for (const path of manifest.files.map((file) => file.path)) {
      assert.doesNotMatch(path, /auth|search\.sqlite|diagnostics|writer\.lock|agent\.sock|invented-unknown|^\/|\.\./, path);
    }
    for (const file of manifest.files) {
      const bytes = await readFile(join(archive, "data", file.path));
      assert.equal(bytes.length, file.size, file.path); assert.equal(sha256(bytes), file.sha256, file.path);
    }
    refused(await cli(["--state-dir", original, "backup", "create", archive]), /already exists/, "backup over an existing archive");

    const killedArchive = join(directory, "killed");
    const killed = spawn(binary, ["--runtime", runtime, "--state-dir", original, "backup", "create", killedArchive],
      { cwd: directory, env, stdio: "ignore" });
    const killedClosed = new Promise<void>((resolve) => killed.once("close", () => resolve()));
    let interrupted = false;
    for (const deadline = Date.now() + 30_000; Date.now() < deadline && killed.exitCode === null;) {
      if ((await readdir(directory)).some((name) => name.startsWith(".killed.partial-"))) { interrupted = killed.kill("SIGKILL"); break; }
      await delay(1);
    }
    await killedClosed;
    assert.ok(interrupted, "the backup was killed while it was still writing its staging directory");
    if (await exists(killedArchive)) {
      const published = JSON.parse(await readFile(join(killedArchive, "manifest.json"), "utf8")) as typeof manifest;
      assert.deepEqual(published.files, manifest.files, "an archive at its final name is complete");
      for (const file of published.files) assert.equal(sha256(await readFile(join(killedArchive, "data", file.path))), file.sha256, file.path);
    } else {
      const leftovers = (await readdir(directory)).filter((name) => name.startsWith(".killed.partial-"));
      for (const leftover of leftovers) {
        const target = join(directory, `from-${leftover}`);
        const attempt = await cli(["backup", "restore", join(directory, leftover), target]);
        if (attempt.code === 0) assert.ok(await exists(join(target, "restore-hold.json")), "a verified leftover restores completely");
        else {
          refused(attempt, /not a complete backup|does not match|missing/i, "restore from an interrupted publication");
          assert.equal(await exists(target), false);
        }
      }
      const rerun = await cli(["--state-dir", original, "backup", "create", killedArchive]);
      assert.equal(rerun.code, 0, rerun.stderr);
    }

    const originalFiles = await fingerprint(original);
    await rename(original, moved);

    async function damaged(label: string, change: (copy: string) => Promise<void>, pattern: RegExp): Promise<void> {
      const copy = join(directory, `damaged-${label}`), target = join(directory, `target-${label}`);
      await cp(archive, copy, { recursive: true }); await change(copy);
      refused(await cli(["backup", "restore", copy, target]), pattern, `restore from a ${label} archive`);
      assert.equal(await exists(target), false, `${label}: a refused restore leaves no target`);
      assert.equal((await readdir(directory)).some((name) => name.startsWith(`.target-${label}.restore-`)), false, `${label}: no staging remains`);
    }
    const asset = manifest.files.find((file) => file.kind === "history_asset" && file.size < 1024 * 1024); assert.ok(asset);
    const content = manifest.files.find((file) => file.kind === "attachment" && file.path.endsWith("/content")); assert.ok(content);
    await damaged("missing-asset", (copy) => rm(join(copy, "data", asset.path)), /missing/i);
    await damaged("corrupt-content", async (copy) => {
      const path = join(copy, "data", content.path), bytes = await readFile(path); bytes[0] = bytes[0]! ^ 0xff; await writeFile(path, bytes);
    }, /does not match/);
    await damaged("corrupt-checksum", async (copy) => {
      const saved = JSON.parse(await readFile(join(copy, "manifest.json"), "utf8")) as typeof manifest;
      const record = saved.files.find((file) => file.path === content.path)!; record.sha256 = "0".repeat(64);
      await writeFile(join(copy, "manifest.json"), JSON.stringify(saved));
    }, /does not match/);
    await damaged("truncated-database", async (copy) => {
      const database = manifest.files.find((file) => file.kind === "database")!;
      await truncate(join(copy, "data", database.path), Math.floor(database.size / 2));
    }, /does not match/);
    await damaged("truncated-manifest", async (copy) => {
      const path = join(copy, "manifest.json"), text = await readFile(path, "utf8"); await writeFile(path, text.slice(0, text.length / 2));
    }, /not a complete backup/);
    await damaged("unpublished", (copy) => rm(join(copy, "manifest.json")), /not a complete backup/);
    await damaged("escaping-path", async (copy) => {
      const saved = JSON.parse(await readFile(join(copy, "manifest.json"), "utf8")) as typeof manifest;
      saved.files.find((file) => file.kind === "feedback")!.path = "../escaped.json";
      await writeFile(join(copy, "manifest.json"), JSON.stringify(saved));
    }, /path/i);
    assert.equal(await exists(join(directory, "escaped.json")), false);

    const occupied = join(directory, "occupied"); await mkdir(occupied, { mode: 0o700 });
    await writeFile(join(occupied, "keep.txt"), "Existing invented state.\n");
    refused(await cli(["backup", "restore", archive, occupied]), /not empty/, "restore into a nonempty directory");
    assert.deepEqual(await readdir(occupied), ["keep.txt"]);
    assert.equal(await readFile(join(occupied, "keep.txt"), "utf8"), "Existing invented state.\n");

    await mkdir(restored, { mode: 0o700 });
    const restore = await cli(["backup", "restore", archive, restored]);
    assert.equal(restore.code, 0, restore.stderr);
    assert.match(restore.stdout, new RegExp(coordinatorId)); assert.match(restore.stdout, /backup release/);
    assert.equal((await stat(restored)).mode & 0o777, 0o700);
    assert.equal(await readFile(join(restored, "coordinator-id"), "utf8"), coordinatorId, "restore keeps the coordinator identity");
    for (const absent of ["auth.json", "search.sqlite", "diagnostics", "invented-unknown.txt", "writer.lock", "agent.sock"]) {
      assert.equal(await exists(join(restored, absent)), false, `${absent} is not restored`);
    }
    assert.ok(await exists(join(restored, "restore-hold.json")), "a restored store starts held");
    assert.deepEqual(await fingerprint(moved), originalFiles, "restore never touches the old store");

    server = await start(restored, jobConfig); await ready(server, restored);
    const restoredRead = await readBack(restored, seeded);
    assert.deepEqual(restoredRead, baseline, "the restored store reads identical history, receipts, assets, attachments and feedback");
    await delay(2_000);
    const held = await request(restored, { type: "list_jobs" });
    assert.ok(held[0]?.type === "scheduled_jobs");
    assert.equal(held[0].jobs.some((status) => status.job.id === HELD_JOB), false, "a held store does not start background work");
    assert.match(server.errors(), /backup release/, "the held coordinator says how to release it");
    await stop(server);

    for (let attempt = 0; attempt < 2; attempt += 1) {
      const released = await cli(["--state-dir", restored, "backup", "release"]);
      assert.equal(released.code, 0, `release attempt ${attempt} is idempotent: ${released.stderr}`);
    }
    assert.equal(await exists(join(restored, "restore-hold.json")), false);

    server = await start(restored, jobConfig); await ready(server, restored);
    for (const deadline = Date.now() + 30_000; ;) {
      const [listed] = await request(restored, { type: "list_jobs" });
      if (listed?.type === "scheduled_jobs" && listed.jobs.some((status) => status.job.id === HELD_JOB)) break;
      assert.ok(Date.now() < deadline, "a released store starts its background owner");
      await delay(100);
    }
    assert.deepEqual(await readBack(restored, seeded), baseline, "release keeps the restored history");
    await stop(server);
  } finally {
    for (const server of servers) {
      if (server.child.pid !== undefined && server.child.exitCode === null && server.child.signalCode === null) {
        try { process.kill(-server.child.pid, "SIGTERM"); } catch (error) {
          if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error;
        }
      }
      await server.closed.catch(() => {});
    }
    await rm(directory, { recursive: true, force: true });
  }
});
