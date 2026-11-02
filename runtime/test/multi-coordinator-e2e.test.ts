import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

type Server = { name: string; child: ChildProcessWithoutNullStreams; closed: Promise<number | null>; errors(): string };

const COORDINATOR_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

test("two production coordinators keep separate persisted coordinator IDs", { timeout: 120_000 }, async (t) => {
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

    let work = await start("work");
    const personal = await start("personal");
    const workId = await savedId("work"), personalId = await savedId("personal");
    assert.notEqual(workId, personalId, "Separate state directories are separate coordinators");

    await stop(work);
    work = await start("work");
    assert.equal(await savedId("work"), workId, "A restart keeps the coordinator's identity");
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
