import assert from "node:assert/strict";
import { execFile, spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { HistoryMessage } from "../src/generated/HistoryMessage.js";
import type { ImportProgress } from "../src/generated/ImportProgress.js";
import type { RuntimeEventKind } from "../src/generated/RuntimeEventKind.js";
import type { SavedMatch } from "../src/generated/SavedMatch.js";
import { HistoryStore } from "../src/history.js";
import { CHATGPT_CONVERSATIONS, chatGptExports, INSTRUCTION_MARKER, KAYAK, MALICIOUS_TOOL_TEXT, onePixelPng, PICNIC,
  sha256, writeExportFolder, writeExportZip } from "./fixtures/chatgpt-export.js";

type Run = { code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string };
type Owned = { child: ChildProcess; closed: Promise<Run> };

const CODEX_NOTE = "Codex note about deployment";
const EXPORT_ONE_ITEMS = 10;
// The picnic edit adds two prompts and replies and flips the old pair to alternate; the kayak
// regeneration adds one reply and flips the old one.
const EXPORT_TWO_ADDED_ITEMS = 4 + 2;
const NOTICE = "1 other version of this message is retained as evidence and not shown.";

function events(stdout: string): RuntimeEventKind[] {
  return stdout.split("\n").filter((line) => line.startsWith("{")).map((line) => JSON.parse(line) as RuntimeEventKind);
}
function progress(stdout: string): ImportProgress[] {
  return events(stdout).flatMap((event) => event.type === "import_progress" ? [event.progress] : []);
}
function errorCode(error: unknown): unknown {
  return error instanceof Error && "code" in error ? error.code : undefined;
}
async function groupAlive(pid: number): Promise<boolean> {
  try { process.kill(-pid, 0); return true; } catch (error) {
    if (errorCode(error) === "ESRCH") return false;
    if (errorCode(error) !== "EPERM") throw error;
    // Darwin's killpg returns EPERM once only zombies remain, so ask ps for live members.
    const { stdout } = await promisify(execFile)("/bin/ps", ["-ax", "-o", "pgid=,stat="]);
    return stdout.split("\n").some((line) => {
      const [group, state] = line.trim().split(/\s+/);
      return group === String(pid) && state !== undefined && !state.startsWith("Z");
    });
  }
}
async function until<T>(what: string, limit: number, probe: () => Promise<T | undefined>): Promise<T> {
  const deadline = Date.now() + limit;
  while (true) {
    const value = await probe();
    if (value !== undefined) return value;
    assert.ok(Date.now() < deadline, `Timed out waiting for ${what}`);
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
}

test("a ChatGPT export imports resumably and idempotently through an isolated coordinator", { timeout: 300_000 }, async (t) => {
  const embedding = { AGENT_LLAMA_SERVER: process.env.AGENT_LLAMA_SERVER, AGENT_EMBEDDING_MODEL: process.env.AGENT_EMBEDDING_MODEL };
  if (embedding.AGENT_LLAMA_SERVER === undefined || embedding.AGENT_EMBEDDING_MODEL === undefined) {
    t.skip("Import indexing needs the pinned embedding runtime; run this proof under `nix develop`");
    return;
  }
  const directory = await mkdtemp("/tmp/agent-chatgpt-e2e-");
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/beep-boop", import.meta.url));
  const runtime = fileURLToPath(new URL("../src/bridge.js", import.meta.url));
  const bin = join(directory, "bin"), state = join(directory, "state"), socket = join(state, "agent.sock");
  const assets = join(state, "history", "assets"), exports = join(directory, "exports");
  const globals = ["--state-dir", state, "--config", join(directory, "config.toml"), "--runtime", runtime,
    "--instructions", join(directory, "AGENTS.md")];
  const env = { PATH: bin, HOME: directory, XDG_CONFIG_HOME: join(directory, "config"), XDG_DATA_HOME: join(directory, "data"),
    TMPDIR: directory, AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC, ...embedding };
  const owned: Owned[] = [];

  function launch(args: string[]): Owned {
    const child = spawn(binary, [...globals, ...args], { cwd: directory, detached: true, stdio: ["ignore", "pipe", "pipe"], env });
    let stdout = "", stderr = "";
    child.stdout?.setEncoding("utf8").on("data", (value: string) => { stdout += value; });
    child.stderr?.setEncoding("utf8").on("data", (value: string) => { stderr += value; });
    const closed = new Promise<Run>((resolve, reject) => {
      child.once("close", (code, signal) => resolve({ code, signal, stdout, stderr })); child.once("error", reject);
    });
    void closed.catch(() => {});
    const run = { child, closed }; owned.push(run); return run;
  }
  async function cli(...args: string[]): Promise<Run> {
    const run = await launch(args).closed;
    assert.equal(run.code, 0, `beep-boop ${args.join(" ")} failed:\n${run.stderr}`);
    return run;
  }
  async function connectable(): Promise<boolean> {
    return new Promise((resolve) => {
      const channel = createConnection({ path: socket });
      channel.once("connect", () => { channel.destroy(); resolve(true); });
      channel.once("error", () => resolve(false));
    });
  }
  async function serve(): Promise<Owned> {
    const server = launch(["serve", "--local-only", "--no-sources"]);
    await until("the coordinator socket", 60_000, async () => {
      if (server.child.exitCode !== null || server.child.signalCode !== null) assert.fail(`The coordinator exited during startup:\n${(await server.closed).stderr}`);
      t.signal.throwIfAborted();
      return await connectable() ? true : undefined;
    });
    return server;
  }
  async function status(): Promise<ImportProgress | undefined> {
    return progress((await cli("--json", "import", "status")).stdout).find((row) => row.source === "chatgpt");
  }
  async function importExport(path: string): Promise<{ run: Run; final: ImportProgress }> {
    const run = await launch(["--json", "--no-tui", "import", "chatgpt", path]).closed;
    const final = progress(run.stdout).at(-1);
    assert.ok(final !== undefined, `import chatgpt ${path} reported no progress (exit ${run.code}):\n${run.stderr}`);
    assert.equal(final.source, "chatgpt");
    return { run, final };
  }
  async function read(conversationId: string): Promise<{ raw: string; messages: HistoryMessage[] }> {
    let cursor: string | null = null, raw = "";
    const messages: HistoryMessage[] = [];
    do {
      const run = await cli("--json", "history", "read", conversationId, ...(cursor === null ? [] : ["--cursor", cursor]));
      raw += run.stdout; cursor = null;
      for (const event of events(run.stdout)) if (event.type === "history") {
        messages.push(...event.messages);
        if (event.page_complete) cursor = event.next_cursor;
      }
    } while (cursor !== null);
    return { raw, messages };
  }
  async function search(query: string, ...mode: string[]): Promise<{ raw: string; matches: SavedMatch[] }> {
    const run = await cli("--json", "history", "search", query, ...mode);
    return { raw: run.stdout, matches: events(run.stdout).flatMap((event) => event.type === "saved_matches" ? event.matches : []) };
  }
  async function conversationOf(threadId: string, query: string): Promise<string> {
    const found = (await search(query, "--mode", "keyword")).matches.find((match) =>
      match.imported?.source === "chatgpt" && match.imported.thread.id === threadId);
    assert.ok(found, `Keyword search for "${query}" must find ChatGPT conversation ${threadId}`);
    return found.conversation_id;
  }
  function shown(messages: readonly HistoryMessage[]): [string, string][] {
    return messages.filter((message) => !message.continuation).map((message) => [message.role, message.text]);
  }

  try {
    await mkdir(bin, { mode: 0o700 }); await mkdir(state, { mode: 0o700 }); await mkdir(exports, { mode: 0o700 });
    await symlink(process.execPath, join(bin, "node"));
    await writeFile(join(directory, "config.toml"), "node_name = \"coordinator-chatgpt-import\"\njob_directories = []\n");
    await writeFile(join(directory, "AGENTS.md"), "Use only invented test data.\n");
    const blob = randomBytes(64 * 1024 * 1024), blobDigest = sha256(blob), pngDigest = sha256(onePixelPng());
    const { first, second } = chatGptExports(blob);
    const exportOne = join(exports, "export-1.zip"), exportTwo = join(exports, "export-2.zip"), extracted = join(exports, "export-1");
    await writeExportZip(exportOne, first); await writeExportZip(exportTwo, second); await writeExportFolder(extracted, first);

    const harness = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(state, "session.sqlite"))),
      { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
    let codexConversation: string;
    try {
      const seeded = await new HistoryStore(harness).import({ source: "codex", host_id: "11111111-1111-4111-8111-111111111111",
        thread: { id: CHATGPT_CONVERSATIONS.picnic, title: "Deployment notes", cwd: "/example/project", created_at: 1_767_000_000,
          updated_at: 1_767_000_100, version: "codex-v1", version_reliable: true, archived: false, forked_from_id: null, parent_thread_id: null },
        items: [{ id: "codex-item", turn_id: "codex-turn", kind: "userMessage", role: "user", text: CODEX_NOTE, version: "codex-item-v1",
          order: 0, timestamp_ms: 1_767_000_000_000, data: { type: "userMessage", content: [{ type: "text", text: CODEX_NOTE }] }, assets: [] }],
        next_cursor: null, gaps: [], complete: true });
      codexConversation = seeded.conversation.conversation_id;
    } finally { await harness.close(BACKGROUND_CONTEXT); }

    let server = await serve();
    const main = ROOT_CONVERSATION_ID.toString();
    const codexBaseline = (await read(codexConversation)).raw, mainBaseline = (await read(main)).raw;

    const interrupted = launch(["--json", "--no-tui", "import", "chatgpt", exportOne]);
    const stdout = interrupted.child.stdout;
    assert.ok(stdout);
    let committed: ImportProgress | undefined;
    for await (const line of createInterface({ input: stdout })) {
      if (!line.startsWith("{")) continue;
      const event = JSON.parse(line) as RuntimeEventKind;
      if (event.type === "import_progress" && event.progress.threads_imported >= 1) { committed = event.progress; break; }
    }
    if (committed === undefined) {
      const run = await interrupted.closed;
      assert.fail(`import chatgpt exited ${run.code} before committing a conversation:\n${run.stderr}`);
    }
    const pid = interrupted.child.pid;
    assert.ok(pid !== undefined);
    process.kill(-pid, "SIGSTOP");
    const stalled = await status();
    assert.ok(stalled, "import status reports the running ChatGPT import");
    assert.equal(stalled.phase, "importing", "The 64 MiB attachment keeps the walk inside the second conversation");
    assert.ok(stalled.threads_imported < 4, "The interruption lands before the walk finishes");

    process.kill(-pid, "SIGKILL");
    await interrupted.closed;
    const partial = await until("the ChatGPT import to end partial", 60_000, async () => {
      const row = await status();
      return row?.phase === "partial" ? row : undefined;
    });
    assert.equal(partial.gaps.filter((gap) => /disconnect/i.test(gap)).length, 1, partial.gaps.join("\n"));

    const coordinator = server.child.pid;
    assert.ok(coordinator !== undefined);
    process.kill(-coordinator, "SIGKILL");
    await server.closed;
    await until("the coordinator's runtime to exit", 30_000, async () => await groupAlive(coordinator) ? undefined : true);
    server = await serve();

    const resumed = await importExport(exportOne);
    assert.equal(resumed.run.code, 0, resumed.run.stderr);
    assert.equal(resumed.final.phase, "complete");
    assert.ok(resumed.final.threads_unchanged >= 1, "A conversation committed before the interruption is not reread");
    assert.equal(resumed.final.items_added, EXPORT_ONE_ITEMS - partial.items_added);

    const ids = {
      picnic: await conversationOf(CHATGPT_CONVERSATIONS.picnic, "picnic"),
      lighthouse: await conversationOf(CHATGPT_CONVERSATIONS.lighthouse, "lighthouse"),
      kayak: await conversationOf(CHATGPT_CONVERSATIONS.kayak, "kayak"),
      tent: await conversationOf(CHATGPT_CONVERSATIONS.tent, "tent"),
    };
    const afterFirst = { picnic: await read(ids.picnic), lighthouse: await read(ids.lighthouse), kayak: await read(ids.kayak), tent: await read(ids.tent) };
    assert.deepEqual(shown(afterFirst.picnic.messages), [["user", PICNIC.six], ["assistant", PICNIC.sixReply]]);
    const retained = await stat(join(assets, blobDigest));
    assert.equal(retained.mode & 0o777, 0o600);
    assert.equal(sha256(await readFile(join(assets, blobDigest))), blobDigest);

    assert.equal((await read(codexConversation)).raw, codexBaseline, "The colliding Codex conversation is untouched");
    const deployment = (await search("deployment")).matches.find((match) => match.conversation_id === codexConversation);
    assert.equal(deployment?.imported?.source, "codex");
    assert.notEqual(ids.picnic, codexConversation, "The same native ID from two sources is two conversations");

    const tool = afterFirst.tent.messages.filter((message) => message.text.includes(MALICIOUS_TOOL_TEXT));
    assert.deepEqual(tool.map((message) => message.role), ["tool"], "Tool output is inert evidence in its own row");
    const injected = [await search("previous instructions", "--mode", "keyword"), await search("previous instructions")];
    for (const result of injected) assert.ok(result.matches.every((match) => !match.excerpt.includes("Ignore previous instructions")));
    const instructions = await search(INSTRUCTION_MARKER, "--mode", "keyword");
    const written = [...Object.values(afterFirst).map((value) => value.raw), ...injected.map((value) => value.raw), instructions.raw];
    for (const name of await readdir(state, { recursive: true })) {
      const path = join(state, name);
      if (path.startsWith(assets) || !(await stat(path)).isFile()) continue;
      written.push((await readFile(path)).toString("latin1"));
    }
    assert.ok(written.every((value) => !value.includes(INSTRUCTION_MARKER)), "Instructions are never stored, rendered or indexed");
    assert.deepEqual(events((await cli("--json", "tasks", "list")).stdout), [{ type: "tasks", tasks: [] }]);
    assert.equal((await read(main)).raw, mainBaseline, "Importing adds no notice, input or answer to the main conversation");

    for (const source of [exportOne, extracted]) {
      const repeated = await importExport(source);
      assert.equal(repeated.run.code, 0, repeated.run.stderr);
      assert.equal(repeated.final.items_added, 0);
      assert.equal(repeated.final.threads_unchanged, 4);
      for (const [name, conversation] of Object.entries(ids)) {
        assert.equal((await read(conversation)).raw, afterFirst[name as keyof typeof ids].raw, `${name} is unchanged by a repeated import`);
      }
    }

    const later = await importExport(exportTwo);
    assert.equal(later.run.code, 0, later.run.stderr);
    assert.equal(later.final.threads_unchanged, 2);
    assert.equal(later.final.items_added, EXPORT_TWO_ADDED_ITEMS);
    const edited = await read(ids.picnic);
    assert.deepEqual(shown(edited.messages), [["notice", NOTICE], ["user", PICNIC.eight], ["assistant", PICNIC.eightReply]]);
    assert.deepEqual(shown((await read(ids.kayak)).messages), [["user", KAYAK.prompt], ["notice", NOTICE], ["assistant", KAYAK.regenerated]]);
    assert.deepEqual((await readdir(assets)).sort(), [blobDigest, pngDigest].sort(), "Retained attachments are stored once");

    const older = await importExport(exportOne);
    assert.equal(older.run.code, 0, older.run.stderr);
    assert.equal(older.final.items_added, 0);
    assert.deepEqual((await read(ids.picnic)).messages, edited.messages, "An older export never replaces the newer view");

    server.child.kill("SIGINT");
    const stopped = await server.closed;
    assert.equal(stopped.code, 0, stopped.stderr);
    assert.equal(await stat(socket).then(() => true, () => false), false, "Shutdown releases the coordinator socket");
  } finally {
    for (const { child, closed } of owned) {
      if (child.pid !== undefined && child.exitCode === null && child.signalCode === null) {
        try { process.kill(-child.pid, "SIGKILL"); } catch (error) {
          if (errorCode(error) !== "ESRCH" && errorCode(error) !== "EPERM") throw error;
        }
      }
      await closed.catch(() => {});
    }
    await rm(directory, { recursive: true, force: true });
  }
});
