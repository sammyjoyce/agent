import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness, type Cursor } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { HistoryStore, ImportedItemEntry } from "../src/history.js";
import { SearchIndex } from "../src/search.js";

const fixture = (name: string) => fileURLToPath(new URL(`./fixtures/${name}`, import.meta.url));

function run(args: string[], env: Record<string, string> = {}): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { env: { PATH: process.env.PATH ?? "", ...env }, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", code => resolve({ code, stdout, stderr }));
  });
}

async function inTemporaryDirectory(use: (directory: string) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "performance-fixture-"));
  try { await use(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

async function treesWithCandidateShim(directory: string, bridge: string) {
  for (const side of ["baseline", "candidate"]) {
    const sentinel = join(directory, side, "node_modules", "side-sentinel");
    await mkdir(sentinel, { recursive: true });
    await mkdir(join(directory, side, "src"), { recursive: true });
    await writeFile(join(directory, side, "package.json"), JSON.stringify({ type: "module" }));
    await writeFile(join(sentinel, "package.json"), JSON.stringify({ type: "module", main: "index.js" }));
    await writeFile(join(sentinel, "index.js"), `export default ${JSON.stringify(side)};`);
    await writeFile(join(directory, side, "src", "bridge.js"), `import side from "side-sentinel";\n${bridge}`);
  }
  const shim = join(directory, "candidate", "test", "fixtures", "performance-runtime.js");
  await mkdir(dirname(shim), { recursive: true });
  await writeFile(shim, await readFile(fixture("performance-runtime.js")));
  return { shim, env: {
    AGENT_PERFORMANCE_RUNTIME: join(directory, "baseline", "src", "bridge.js"),
    AGENT_PERFORMANCE_PROVIDER: "http://127.0.0.1:1",
    AGENT_PERFORMANCE_RUNTIME_PID: join(directory, "runtime.pid"),
  } };
}

type Seeded = { chief: string; long_history: string; search_corpus: { conversations: number; chunks: number } | null;
  import_corpus: { rollouts: number; items_per_rollout: number } };

async function seed(directory: string, env: Record<string, string> = {}): Promise<Seeded> {
  const seeded = await run([fixture("performance.js"), directory], env);
  assert.equal(seeded.code, 0, seeded.stderr);
  return JSON.parse(seeded.stdout) as Seeded;
}

test("the performance seed stores the chief, 3,000 unrelated discussions and a 5,000-message conversation", () => inTemporaryDirectory(async directory => {
  const ids = await seed(directory);
  assert.equal(ids.search_corpus, null);
  const files = (await readdir(directory, { withFileTypes: true })).filter(entry => entry.isFile()).map(entry => entry.name);
  assert.deepEqual(files.filter(name => !name.startsWith("session.sqlite")), [], "Coordinators copy every top-level file");
  const storage = await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite")));
  const session = await Harness.open(storage, { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  try {
    const chief = await session.root(BACKGROUND_CONTEXT);
    assert.equal(chief.id.toString(), ids.chief);
    const messages = await chief.entries({ order: "ascending" }, 100, undefined, BACKGROUND_CONTEXT);
    assert.equal(messages.items.length, 40);
    assert.match(JSON.stringify(messages.items.at(-1)), /Stored chief conversation is ready/);
    const history = new HistoryStore(session);
    let retained = 0;
    for await (const _ of history.inventory()) retained += 1;
    assert.equal(retained, 3_002);
    const long = await history.conversation(ids.long_history);
    assert.ok(long);
    let imported = 0, last: unknown, cursor: Cursor | undefined;
    do {
      const page = await long.entries({ order: "ascending" }, 1_000, cursor, BACKGROUND_CONTEXT);
      const items = page.items.filter(ImportedItemEntry.is);
      imported += items.length;
      last = items.at(-1) ?? last;
      cursor = page.next;
    } while (cursor !== undefined);
    assert.equal(imported, 5_000);
    assert.match(JSON.stringify(last), /Stored long conversation is ready/);
  } finally { await session.close(BACKGROUND_CONTEXT); }
}));

test("the performance seed indexes a copy of the session so search finds the long conversation with nothing left to reindex", () => inTemporaryDirectory(async directory => {
  const extension = process.env.AGENT_SQLITE_VEC; assert.ok(extension);
  const ids = await seed(directory, { AGENT_SQLITE_VEC: extension });
  assert.deepEqual(await readdir(join(directory, "search")), ["search.sqlite"]);
  const storage = await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite")));
  const session = await Harness.open(storage, { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const index = new SearchIndex(join(directory, "search", "search.sqlite"), extension);
  try {
    let conversations = 0;
    for await (const { conversation_id, watermark } of new HistoryStore(session).inventory()) {
      conversations += 1;
      assert.deepEqual(index.checkpoint(conversation_id), { watermark, dirty: false }, conversation_id);
    }
    assert.equal(ids.search_corpus?.conversations, conversations);
    assert.ok((ids.search_corpus?.chunks ?? 0) >= 5_040);
    // The benchmark's query in examples/cli_performance/load.rs.
    const result = await index.search("previous task context remains readable", undefined, [], 8, "keyword");
    assert.equal(result.candidates[0]?.conversation_id, ids.long_history);
    assert.deepEqual(result.gaps, []);
  } finally { await index.close(); await session.close(BACKGROUND_CONTEXT); }
}));

test("the performance seed writes invented legacy Codex rollouts with unique thread and item ids", () => inTemporaryDirectory(async directory => {
  const { import_corpus: { rollouts: count, items_per_rollout: perRollout } } = await seed(directory);
  assert.ok(count > 0 && perRollout > 0);
  const home = join(directory, "codex"), folder = join(home, "sessions", "2026", "01", "02");
  assert.equal(await readFile(join(home, "config.toml"), "utf8"), "model_provider = \"openai\"\n");
  const rollouts = await readdir(folder), threads = new Set<string>(), items = new Set<string>();
  assert.equal(rollouts.length, count);
  for (const name of rollouts) {
    const records = (await readFile(join(folder, name), "utf8")).trimEnd().split("\n")
      .map(line => JSON.parse(line) as { type: string; payload: Record<string, unknown> });
    const [meta, ...events] = records;
    assert.equal(meta?.type, "session_meta");
    assert.equal(meta?.payload.history_mode, "legacy");
    const thread = String(meta?.payload.id);
    assert.ok(name.endsWith(`-${thread}.jsonl`), name);
    threads.add(thread);
    const completed = events.filter(event => event.payload.type === "item_completed");
    assert.equal(completed.length, perRollout);
    for (const event of completed) {
      assert.equal(event.payload.thread_id, thread);
      items.add(String((event.payload.item as { id: string }).id));
    }
  }
  assert.equal(threads.size, count);
  assert.equal(items.size, count * perRollout);
}));

test("the runtime shim starts the requested runtime with that runtime's own packages", () => inTemporaryDirectory(async directory => {
  const { shim, env } = await treesWithCandidateShim(directory, "console.log(JSON.stringify({ side, key: process.env.OPENAI_API_KEY }));");
  const started = await run([shim], env);
  assert.equal(started.code, 0, started.stderr);
  assert.deepEqual(JSON.parse(started.stdout), { side: "baseline", key: "sk-synthetic-performance" });
  assert.match(await readFile(env.AGENT_PERFORMANCE_RUNTIME_PID, "utf8"), /^\d+$/);
}));

test("the runtime shim sends Responses requests to the benchmark provider intact and refuses other URLs", () => inTemporaryDirectory(async directory => {
  let received: unknown;
  const server = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += String(chunk);
    received = { method: request.method, url: request.url, header: request.headers["x-example"], body };
    response.end("loopback accepted");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  try {
    const { shim, env } = await treesWithCandidateShim(directory, `const response = await fetch("https://api.openai.com/v1/responses", { method: "POST", headers: { "x-example": "invented" }, body: "synthetic" });
let refused = false;
try { await fetch("https://example.invalid/"); } catch { refused = true; }
console.log(JSON.stringify({ text: await response.text(), refused }));`);
    const started = await run([shim], { ...env, AGENT_PERFORMANCE_PROVIDER: `http://127.0.0.1:${(server.address() as AddressInfo).port}` });
    assert.equal(started.code, 0, started.stderr);
    assert.deepEqual(JSON.parse(started.stdout), { text: "loopback accepted", refused: true });
    assert.deepEqual(received, { method: "POST", url: "/v1/responses", header: "invented", body: "synthetic" });
  } finally { await new Promise(resolve => server.close(resolve)); }
}));

test("the slow runtime delays each copied stdout write by 500 ms and then starts its bridge", () => inTemporaryDirectory(async directory => {
  await mkdir(join(directory, "src"), { recursive: true });
  await mkdir(join(directory, "test", "fixtures"), { recursive: true });
  await writeFile(join(directory, "package.json"), JSON.stringify({ type: "module" }));
  await writeFile(join(directory, "src", "bridge.js"), "process.stdout.write(\"first\"); const bytes = Buffer.from(\"second\"); process.stdout.write(bytes); bytes.fill(120);");
  await writeFile(join(directory, "timers.js"), `import assert from "node:assert/strict";
let scheduled = 0;
globalThis.setTimeout = (callback, delay) => { assert.equal(delay, 500); scheduled += 1; queueMicrotask(callback); return {}; };
process.on("exit", () => assert.equal(scheduled, 2));`);
  const slow = join(directory, "test", "fixtures", "slow-runtime.js");
  await writeFile(slow, await readFile(fixture("slow-runtime.js")));
  const started = await run(["--import", join(directory, "timers.js"), slow]);
  assert.equal(started.code, 0, started.stderr);
  assert.equal(started.stdout, "firstsecond");
}));
