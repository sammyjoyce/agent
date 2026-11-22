import assert from "node:assert/strict";
import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { chmod, mkdir, mkdtemp, open, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { createConnection } from "node:net";
import { delimiter, join } from "node:path";
import type { TestContext } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { validEvent } from "../../src/protocol.js";
import type { RuntimeCommand } from "../../src/generated/RuntimeCommand.js";
import type { RuntimeEventKind } from "../../src/generated/RuntimeEventKind.js";
import type { ModelQueue, ModelStep } from "./coordinator-runtime.js";

export type OwnedProcess = {
  child: ChildProcessWithoutNullStreams; exited: Promise<number | null>; output: () => string; errors: () => string;
};

export const effect = ["-e", "const value={host:process.env.AGENT_TEST_NODE_ID,cwd:process.cwd()};require('node:fs').appendFileSync(process.env.HOME+'/effects',JSON.stringify(value)+'\\n');process.stdout.write(JSON.stringify(value))"];
export const exec: ModelStep = { tool: "exec", args: { program: process.execPath, args: effect } };
export const delegate = (title: string, host?: string): ModelStep => ({ tool: "delegate_task", args: { title, outcome: title, input: title, new_task: true,
  new_task_reason: `${title} is a separate synthetic audit.`,
  ...(host === undefined ? {} : { host }) } });
export const held = (path: string): ModelStep => ({ tool: "exec", args: { program: process.execPath, timeout_seconds: 60, args: ["-e",
  'const fs=require("node:fs"),path=process.argv[1];fs.appendFileSync(path+".started",process.pid+" "+process.env.AGENT_TEST_NODE_ID+"\\n");' +
  'async function run(){while(!fs.existsSync(path+".release"))await new Promise(resolve=>setTimeout(resolve,20));' +
  'fs.appendFileSync(path+".finished","once\\n");process.stdout.write("Completed the held action.");}void run();', path] } });

export type WorldEnd = Pick<TestContext, "passed" | "diagnostic">;
/** Owns a world's lifetime: a test, or a long-lived fixture that runs the cleanup itself. */
export type WorldOwner = { after(cleanup: (end: WorldEnd) => Promise<void>): void };

/**
 * `prepare` runs after each home has its default files and before either
 * service starts. `runtime` is the script both services run as their Pi child.
 */
export async function coordinatorWorld(t: WorldOwner, prepare: (homes: readonly [string, string]) => Promise<void> = async () => {},
  runtime = fileURLToPath(new URL("./coordinator-runtime.js", import.meta.url))) {
  const directory = await realpath(await mkdtemp("/tmp/agent-e2e-"));
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../../target/debug/beep-boop", import.meta.url));
  const terminalFixture = fileURLToPath(new URL("../../../../target/debug/examples/terminal-fixture", import.meta.url));
  const coordinator = "11111111-1111-4111-8111-111111111111", laptop = "22222222-2222-4222-8222-222222222222";
  const bin = join(directory, "bin"), queue = join(directory, "responses.json"), feedbackGate = join(directory, "feedback-gate");
  const homes = [join(directory, "desktop"), join(directory, "laptop")] as const;
  const socket = join(homes[0], "state", "agent.sock");
  const children: OwnedProcess[] = [];
  t.after(async (context) => {
    try {
      if (!context.passed) await diagnose(context);
      for (const owned of children.slice().reverse()) if (owned.child.pid !== undefined && owned.child.exitCode === null && owned.child.signalCode === null) {
        try { process.kill(-owned.child.pid, "SIGTERM"); } catch { /* This owned group already exited. */ }
      }
      await Promise.race([Promise.allSettled(children.map((owned) => owned.exited)), new Promise((resolve) => setTimeout(resolve, 2000).unref())]);
      for (const owned of children) if (owned.child.pid !== undefined && owned.child.exitCode === null && owned.child.signalCode === null) {
        try { process.kill(-owned.child.pid, "SIGKILL"); } catch { /* This owned group already exited. */ }
      }
      try {
        for (const pid of await pidsMatching(directory)) {
          try { process.kill(pid, "SIGKILL"); } catch {}
        }
      } catch (error) { context.diagnostic("Could not sweep processes that left their owner's group: " + String(error)); }
      await Promise.allSettled(children.map((owned) => owned.exited));
    } finally { await rm(directory, { recursive: true, force: true }); }
  });
  async function diagnose(context: WorldEnd) {
    const durable = await Promise.all(homes.flatMap((home) => ["state/runtime.jsonl", "state/session.sqlite", "rex.json", "rex.json.calls"].map(async (name) => {
      try {
        const file = await open(join(home, name), "r");
        try {
          const metadata = await file.stat(), bytes = Buffer.alloc(4096);
          const read = name.endsWith(".sqlite") ? 0 : (await file.read(bytes, 0, bytes.length, Math.max(0, metadata.size - bytes.length))).bytesRead;
          return { host: homes.indexOf(home), name, bytes: metadata.size, tail: bytes.subarray(0, read).toString("utf8") };
        } finally { await file.close(); }
      } catch (failure) { return { host: homes.indexOf(home), name, error: String(failure) }; }
    })));
    context.diagnostic("Owned coordinator failure before cleanup: " + JSON.stringify({ durable, children: children.slice(-10).map((owned) => ({
      pid: owned.child.pid, executable: owned.child.spawnfile, arguments: owned.child.spawnargs.slice(1, 8),
      exitCode: owned.child.exitCode, signalCode: owned.child.signalCode, killed: owned.child.killed,
      stdout: owned.output().slice(-4096), stderr: owned.errors().slice(-4096),
    })) }));
  }
  const events = (text: string): RuntimeEventKind[] => text.slice(0, text.lastIndexOf("\n") + 1).split("\n").filter(Boolean).map((line) => {
    const event: unknown = JSON.parse(line), frame = { version: 1, id: 1, event };
    assert.ok(validEvent(frame), "The real CLI must return typed protocol events"); return frame.event;
  });
  function start(host: number, args: string[], input?: string, extra: NodeJS.ProcessEnv = {}, nativeArguments = false, terminal = false,
    clientBinary = binary): OwnedProcess {
    const home = homes[host]; assert.ok(home);
    const arguments_ = nativeArguments ? args : ["--state-dir", join(home, "state"), "--config", join(home, "agent.toml"),
      "--runtime", runtime, "--instructions", join(home, "AGENTS.md"), ...args];
    const command = terminal ? [clientBinary, ...arguments_]
      : ["--json", "--no-tui", ...arguments_];
    // A process given another HOME belongs to a host this fixture did not make, and runs there.
    const child = spawn(terminal ? terminalFixture : clientBinary, command, { cwd: extra.HOME ?? home, detached: true, stdio: ["pipe", "pipe", "pipe"], env: {
      PATH: bin + delimiter + process.env.PATH, HOME: home, XDG_CONFIG_HOME: join(home, ".config"), XDG_DATA_HOME: join(home, ".local"),
      TMPDIR: directory, TERM: "xterm-256color", AGENT_SQLITE_VEC: process.env.AGENT_SQLITE_VEC, OPENAI_API_KEY: "sk-synthetic-fixture",
      AGENT_TEST_NODE_ID: host === 0 ? coordinator : laptop, AGENT_TEST_REX_STATE: join(home, "rex.json"),
      AGENT_TEST_MODEL_QUEUE: queue, AGENT_TEST_COORDINATOR_SOCKET: socket, AGENT_TEST_FEEDBACK_GATE: feedbackGate, ...extra,
      ...(terminal ? { AGENT_TEST_TERMINAL_REPLY: "1" } : {}),
    } });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (text: string) => { stdout += text; });
    child.stderr.setEncoding("utf8").on("data", (text: string) => { stderr += text; });
    const exited = new Promise<number | null>((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
    const owned = { child, exited, output: () => stdout, errors: () => stderr }; children.push(owned);
    if (input !== undefined) {
      if (input.length === 0) child.stdin.end();
      else child.stdin.end(input);
    }
    return owned;
  }
  async function cli(host: number, args: string[], input = "", clientBinary = binary) {
    const process = start(host, args, input, {}, false, false, clientBinary); assert.equal(await process.exited, 0, process.errors()); return events(process.output());
  }
  async function exchange(command: RuntimeCommand, observe?: (event: RuntimeEventKind) => void, path = socket): Promise<RuntimeEventKind[]> {
    const channel = createConnection(path); let output = "", done = false, observed = 0;
    try {
      return await new Promise<RuntimeEventKind[]>((resolve, reject) => {
        channel.on("error", reject).on("data", (bytes: Buffer) => {
          try {
            output += bytes.toString("utf8"); const frames = events(output);
            for (const frame of frames.slice(observed)) observe?.(frame); observed = frames.length;
            if (frames.some((frame) => frame.type === "done")) { done = true; resolve(frames); }
          } catch (error) { reject(error); }
        }).on("end", () => { if (!done) reject(new Error("The coordinator closed a main view before Done")); });
        channel.write(JSON.stringify(command) + "\n");
      });
    } finally { channel.destroy(); }
  }
  async function until(check: () => Promise<boolean>, message = "", diagnostic: () => string = () => "", limit = 10_000): Promise<void> {
    const deadline = Date.now() + limit;
    while (!await check()) { assert.ok(Date.now() < deadline, message + "\n" + diagnostic() + "\n" + children.map((process) => process.errors()).join("\n") +
      children.slice(-3).map((process) => process.output().slice(-2400)).join("\n")); await new Promise((resolve) => setTimeout(resolve, 20)); }
  }
  async function online(ids: string[]): Promise<void> {
    await until(async () => {
      const state = (await cli(0, ["nodes"])).find((event) => event.type === "environment");
      return state?.type === "environment" && state.online_host_ids.slice().sort().join() === ids.slice().sort().join();
    });
  }
  async function tasks() {
    const event = (await cli(0, ["tasks", "list"])).find((event) => event.type === "tasks"); assert.ok(event?.type === "tasks"); return event.tasks;
  }
  async function script(key: string, steps: ModelStep[]): Promise<void> {
    const current: ModelQueue = JSON.parse(await readFile(queue, "utf8")); current[key] = steps; await writeFile(queue, JSON.stringify(current));
  }

  await mkdir(bin); await writeFile(queue, "{}");
  for (const method of ["rex", "ssh"]) {
    const path = join(bin, method); await writeFile(path, `#!${process.execPath}\nprocess.env.AGENT_TEST_NATIVE=${JSON.stringify(method)};await import(${JSON.stringify(new URL("./coordinator-native.js", import.meta.url).href)});\n`); await chmod(path, 0o700);
  }
  for (const [index, home] of homes.entries()) {
    await mkdir(join(home, "state"), { recursive: true, mode: 0o700 }); await chmod(join(home, "state"), 0o700);
    await writeFile(join(home, "AGENTS.md"), "Keep synthetic work on its requested host.\n");
    await writeFile(join(home, "agent.toml"), `node_name = "${index === 0 ? "desktop" : "laptop"}"\n` +
      (index === 0 ? "" : "coordinator = \"synthetic-coordinator\"\n"));
  }
  await prepare(homes);
  const server = start(0, ["serve", "--local-only", "--no-sources"]);
  await until(async () => { try { return (await stat(socket)).isSocket(); } catch { return false; } });
  const worker = start(1, ["maintain"]); await online([coordinator, laptop]);
  return { directory, binary, coordinator, laptop, homes, socket, queue, feedbackGate, server, worker,
    events, start, cli, exchange, until, online, tasks, script };
}

export async function pidsMatching(text: string): Promise<number[]> {
  // procps leaves piped width undefined; -w twice is unlimited on procps and macOS.
  const { stdout } = await promisify(execFile)(existsSync("/bin/ps") ? "/bin/ps" : "ps", ["-A", "-ww", "-o", "pid=,args="], { maxBuffer: 64 * 1024 * 1024 });
  return stdout.split("\n").flatMap((line) => {
    const match = /^\s*(\d+)\s(.*)$/.exec(line);
    return match !== null && match[2]!.includes(text) && Number(match[1]) !== process.pid ? [Number(match[1])] : [];
  });
}
