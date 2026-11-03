import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, Harness, UserEntry } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { NativeRequest } from "../src/generated/NativeRequest.js";
import { protocolLines } from "../src/protocol.js";

type Server = { name: string; child: ChildProcessWithoutNullStreams; closed: Promise<number | null>; errors(): string };
type Frame = { type: string; coordinator_id?: string; input_id?: string };

const COORDINATOR_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test("two production coordinators keep separate persisted IDs and name them on identify", { timeout: 120_000 }, async (t) => {
  const directory = await mkdtemp("/tmp/agent-multi-coordinator-e2e-");
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/agent", import.meta.url));
  const runtime = fileURLToPath(new URL("../src/bridge.js", import.meta.url));
  const bin = join(directory, "bin");
  const state = (name: string) => join(directory, name, "state");
  const socket = (name: string) => join(state(name), "agent.sock");
  const idFile = (name: string) => join(state(name), "coordinator-id");
  const children: Server[] = [];
  try {
    await mkdir(bin, { mode: 0o700 });
    await symlink(process.execPath, join(bin, "node"));
    for (const name of ["work", "personal"]) {
      await mkdir(state(name), { recursive: true, mode: 0o700 });
      await writeFile(join(directory, name, "config.toml"), `node_name = "coordinator-${name}"\njob_directories = []\n`);
      await writeFile(join(directory, name, "AGENTS.md"), "Use only invented test data.\n");
    }

    // Seed a real interrupted admission through Pi's transaction API, as
    // coordinator-observation-e2e does, so `work` has saved receipts to report.
    const input = "2f6c1d7e-9a4b-4c3d-8e5f-0a1b2c3d4e5f";
    const database = await openNodeSqliteDatabase(join(state("work"), "session.sqlite"));
    const harness = await Harness.open(await SqliteStorage.open(database),
      { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
    try {
      const root = await harness.root(BACKGROUND_CONTEXT);
      await root.commit(async (tx) => {
        const saved = await tx.appendEntry(UserEntry, root.id,
          { model: [{ role: "user", content: "Invented note for the work coordinator.", timestamp: 1 }] });
        await tx.createSubmission({ type: "input", conversationId: root.id,
          requestId: input, status: "unanswered", entry: saved.id, reason: "aborted" });
      }, BACKGROUND_CONTEXT);
    } finally { await harness.close(BACKGROUND_CONTEXT); }

    function spawnCoordinator(name: string): Server {
      const home = join(directory, name);
      const child = spawn(binary, ["--state-dir", state(name), "--config", join(home, "config.toml"),
        "--runtime", runtime, "--instructions", join(home, "AGENTS.md"),
        "serve", "--local-only", "--no-sources"], {
        cwd: home, detached: true, stdio: ["pipe", "pipe", "pipe"],
        env: { PATH: bin, HOME: home, XDG_CONFIG_HOME: join(home, "config"),
          XDG_DATA_HOME: join(home, "data"), TMPDIR: home,
          AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC },
      });
      let stderr = "";
      child.stderr.setEncoding("utf8").on("data", (value: string) => { stderr += value; });
      child.stdout.resume();
      const closed = new Promise<number | null>((resolve, reject) => {
        child.once("close", resolve); child.once("error", reject);
      });
      void closed.catch(() => {});
      const server = { name, child, closed, errors: () => stderr };
      children.push(server);
      return server;
    }
    async function start(name: string): Promise<Server> {
      const server = spawnCoordinator(name);
      while (!await stat(socket(name)).then((value) => value.isSocket(), () => false)) {
        assert.equal(server.child.exitCode, null, server.errors());
        t.signal.throwIfAborted();
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      return server;
    }
    async function stop(server: Server): Promise<void> {
      server.child.kill("SIGINT");
      assert.equal(await server.closed, 0, server.errors());
      assert.equal(await stat(socket(server.name)).then(() => true, () => false), false,
        "Shutdown must release the real coordinator's socket");
    }
    async function savedId(name: string): Promise<string> {
      const id = await readFile(idFile(name), "utf8");
      assert.match(id, COORDINATOR_ID);
      assert.equal((await stat(idFile(name))).mode & 0o777, 0o600, "The coordinator ID is private to its owner");
      return id;
    }
    async function exchange(name: string, requests: NativeRequest[],
      { until = () => false, end = false }: { until?: (frame: Frame) => boolean; end?: boolean } = {}): Promise<Frame[]> {
      const channel = createConnection({ path: socket(name), signal: t.signal });
      const frames: Frame[] = [];
      try {
        for (const request of requests) channel.write(JSON.stringify({ type: "native", request }) + "\n");
        if (end) channel.end();
        for await (const line of protocolLines(channel)) {
          const frame = JSON.parse(line) as Frame;
          frames.push(frame);
          if (until(frame)) break;
        }
        return frames;
      } finally { channel.destroy(); }
    }
    const identify: NativeRequest = { type: "identify" };

    let work = await start("work");
    const personal = await start("personal");
    const workId = await savedId("work"), personalId = await savedId("personal");
    assert.notEqual(workId, personalId, "Separate state directories are separate coordinators");
    assert.deepEqual(await exchange("work", [identify], { end: true }), [{ type: "identity", coordinator_id: workId }],
      "Identify then EOF answers once and closes");
    assert.deepEqual(await exchange("personal", [identify], { end: true }),
      [{ type: "identity", coordinator_id: personalId }]);

    const observed = await exchange("work", [identify, { type: "observe", input_ids: [input] }],
      { until: (frame) => frame.type === "idle" });
    assert.deepEqual(observed.map((frame) => frame.type),
      ["identity", "commands", "ready", "accepted", "placed", "history", "idle"]);
    assert.equal(observed[0]?.coordinator_id, workId);
    assert.deepEqual(observed.filter((frame) => frame.input_id !== undefined).map((frame) => frame.input_id), [input, input]);
    assert.deepEqual((await exchange("personal", [identify, identify])).map((frame) => frame.type),
      ["identity", "failure", "done"], "Identify is valid only as the first request");

    await stop(work);
    work = await start("work");
    assert.equal(await savedId("work"), workId, "A restart keeps the coordinator's identity");
    assert.deepEqual(await exchange("work", [identify], { end: true }), [{ type: "identity", coordinator_id: workId }]);
    await stop(work);
    await stop(personal);

    const malformed = "not a coordinator ID";
    await writeFile(idFile("personal"), malformed);
    const refused = spawnCoordinator("personal");
    assert.notEqual(await refused.closed, 0, "A malformed coordinator ID must stop the coordinator");
    assert.match(refused.errors(), /is not a coordinator ID/);
    assert.equal(await readFile(idFile("personal"), "utf8"), malformed, "A malformed ID is never replaced");
  } finally {
    for (const server of children) {
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
