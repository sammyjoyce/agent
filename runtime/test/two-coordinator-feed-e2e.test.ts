import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { createConnection, createServer, type Socket } from "node:net";
import { join } from "node:path";
import { StringDecoder } from "node:string_decoder";
import { test, type TestContext } from "node:test";
import { setTimeout as sleep } from "node:timers/promises";
import { fileURLToPath } from "node:url";
import type { NativeRequest } from "../src/generated/NativeRequest.js";
import { protocolLines } from "../src/protocol.js";

type Name = "work" | "personal";
type Lane = `${Name}-lane`;
type Coordinator = { name: Name; socket: string; id: string };
type Server = { child: ChildProcessWithoutNullStreams; closed: Promise<number | null> };
/** A client-to-coordinator frame as a lane's proxy forwarded it to `target`. */
type Sent = { lane: Lane; target: Name; connection: number; frame: string };
/** The ID a coordinator answered `identify` with on one proxied connection. */
type Answer = { lane: Lane; target: Name; connection: number; coordinator_id: string };
type ProxyLog = { sent: Sent[]; answers: Answer[] };
/**
 * Everything the phone under test is given. The Swift test receives these as
 * environment variables of the same names. To re-point the work lane, the phone
 * atomically writes `personal` or `work` to AGENT_E2E_REPOINT_REQUEST, then
 * waits until AGENT_E2E_REPOINT_ACK holds the same name, then removes the ack.
 */
type PhoneContract = {
  AGENT_E2E_WORK_SOCKET: string; AGENT_E2E_PERSONAL_SOCKET: string;
  AGENT_E2E_WORK_ID: string; AGENT_E2E_PERSONAL_ID: string;
  AGENT_E2E_LEGACY_INPUT: string; AGENT_E2E_LEGACY_TEXT: string;
  AGENT_E2E_TAGGED_TEXT: string; AGENT_E2E_BROADCAST_TEXT: string;
  AGENT_E2E_REPOINT_REQUEST: string; AGENT_E2E_REPOINT_ACK: string;
  AGENT_E2E_DIRECTORY: string;
};
type Phone = (contract: PhoneContract, signal: AbortSignal) => Promise<void>;
type Fault = "none" | "skipsIdentifyAfterRepoint" | "reusesBroadcastInput" | "sendsLegacyInput";

const SWIFT_TEST = "twoCoordinatorFeedRoutesOnlyToAddressedCoordinators";
const LEGACY_INPUT = "5b2e8c41-7d3a-4f6e-9a1b-3c4d5e6f7a8b", LEGACY_TEXT = "Invented note queued before the update.";
const TAGGED_TEXT = "Invented note for the work coordinator only.";
const BROADCAST_TEXT = "Invented note for both coordinators.";

function parse(line: string): unknown {
  try { return JSON.parse(line); } catch { return undefined; }
}
function nativeRequest(frame: string): NativeRequest | undefined {
  const command = parse(frame) as { type?: unknown; request?: NativeRequest } | null | undefined;
  return command?.type === "native" ? command.request : undefined;
}
function where(log: ProxyLog, sent: Sent): string {
  const answer = log.answers.find((value) => value.lane === sent.lane && value.connection === sent.connection);
  return `${sent.lane} connection ${sent.connection} to ${sent.target} (answered ${answer?.coordinator_id ?? "nothing"})`;
}
function submits(log: ProxyLog, text: string) {
  return log.sent.flatMap((sent) => {
    const request = nativeRequest(sent.frame);
    return request?.type === "submit" && request.text === text ? [{ sent, input: request.input_id }] : [];
  });
}

function assertTaggedSubmitReachesOnlyWork(log: ProxyLog, text: string): void {
  const sent = submits(log, text);
  assert.ok(sent.length > 0, `Invariant 1 broke: no submit carried the @Work text ${JSON.stringify(text)}`);
  const stray = sent.find((value) => value.sent.target !== "work");
  if (stray) assert.fail(`Invariant 1 broke: the @Work message reached ${stray.sent.target} as input ${stray.input} on ${where(log, stray.sent)}`);
}

function assertBroadcastReachesBothUnderDistinctInputs(log: ProxyLog, text: string): void {
  const sent = submits(log, text);
  const inputs = (name: Name) => [...new Set(sent.filter((value) => value.sent.target === name).map((value) => value.input))];
  const work = inputs("work"), personal = inputs("personal");
  assert.ok(work.length === 1 && personal.length === 1,
    `Invariant 2 broke: the untagged message must reach each coordinator under exactly one input ID, `
    + `but work saw ${JSON.stringify(work)} and personal saw ${JSON.stringify(personal)}`);
  assert.notEqual(work[0], personal[0], `Invariant 2 broke: work and personal both received the untagged message as input ${work[0]}`);
}

function assertRepointedWorkLaneCarriesOnlyIdentify(log: ProxyLog): void {
  const repointed = log.sent.filter((sent) => sent.lane === "work-lane" && sent.target === "personal");
  assert.ok(repointed.length > 0, "Invariant 3 broke: no work-lane connection reached personal, so the re-point was never exercised");
  const leaked = repointed.find((sent) => nativeRequest(sent.frame)?.type !== "identify");
  if (leaked) assert.fail(`Invariant 3 broke: re-pointed ${where(log, leaked)} carried ${leaked.frame}; only identify may reach the other coordinator`);
}

function assertNeverLeavesPhone(log: ProxyLog, held: string[]): void {
  const strings = (value: unknown): string[] => typeof value === "string" ? [value]
    : typeof value === "object" && value !== null ? Object.values(value).flatMap(strings) : [];
  for (const sent of log.sent) {
    // Decoded strings catch values an encoder escaped, such as Swift's `\/`.
    const found = held.find((value) => [sent.frame, ...strings(parse(sent.frame))].some((text) => text.includes(value)));
    if (found !== undefined) assert.fail(`Invariant 4 broke: legacy ${JSON.stringify(found)} left the phone on ${where(log, sent)}`);
  }
}

/** Each broken invariant's number and message. An empty object means all four hold. */
function violations(log: ProxyLog): Record<number, string> {
  const invariants = [
    () => assertTaggedSubmitReachesOnlyWork(log, TAGGED_TEXT),
    () => assertBroadcastReachesBothUnderDistinctInputs(log, BROADCAST_TEXT),
    () => assertRepointedWorkLaneCarriesOnlyIdentify(log),
    () => assertNeverLeavesPhone(log, [LEGACY_INPUT, LEGACY_TEXT]),
  ];
  const broken: Record<number, string> = {};
  invariants.forEach((check, index) => {
    try { check(); } catch (error) { broken[index + 1] = error instanceof Error ? error.message : String(error); }
  });
  return broken;
}

function summarize(log: ProxyLog): string[] {
  const connections = new Map<string, string[]>();
  for (const sent of log.sent) {
    const request = nativeRequest(sent.frame), connection = where(log, sent);
    const frame = request?.type === "submit" ? `submit ${request.input_id} ${JSON.stringify(request.text)}` : request?.type ?? sent.frame;
    connections.set(connection, [...connections.get(connection) ?? [], frame]);
  }
  return [...connections].map(([connection, frames]) => `${connection}: ${frames.join(", ")}`);
}

function eachLine(socket: Socket, read: (line: string) => void): void {
  const decoder = new StringDecoder("utf8");
  let pending = "";
  socket.on("data", (chunk: Buffer) => {
    pending += decoder.write(chunk);
    for (let end = pending.indexOf("\n"); end >= 0; end = pending.indexOf("\n")) {
      read(pending.slice(0, end));
      pending = pending.slice(end + 1);
    }
  });
  socket.once("close", () => {
    pending += decoder.end();
    if (pending.length > 0) read(pending);
  });
}

async function startProxy(lane: Lane, path: string, initial: Coordinator, log: ProxyLog) {
  let target = initial, accepted = 0;
  const open = new Set<Socket>();
  const server = createServer({ allowHalfOpen: true }, (client) => {
    const connection = ++accepted, to = target;
    const upstream = createConnection({ path: to.socket, allowHalfOpen: true });
    open.add(client);
    eachLine(client, (frame) => log.sent.push({ lane, target: to.name, connection, frame }));
    eachLine(upstream, (line) => {
      const event = parse(line) as { type?: unknown; coordinator_id?: unknown } | null | undefined;
      if (event?.type === "identity" && typeof event.coordinator_id === "string") {
        log.answers.push({ lane, target: to.name, connection, coordinator_id: event.coordinator_id });
      }
    });
    client.on("error", () => upstream.destroy()).on("close", () => { open.delete(client); upstream.destroy(); });
    upstream.on("error", () => client.destroy()).on("close", () => client.end());
    client.pipe(upstream);
    upstream.pipe(client);
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject).listen(path, resolve); });
  return {
    // A re-pointed name breaks the connections already open to the old coordinator.
    repoint(next: Coordinator) { target = next; for (const client of open) client.destroy(); },
    async close() {
      for (const client of open) client.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

const exists = (path: string) => stat(path).then(() => true, () => false);
async function writeAtomically(path: string, text: string): Promise<void> {
  await writeFile(`${path}.tmp`, text);
  await rename(`${path}.tmp`, path);
}

/** Runs one phone against both coordinators through fresh recording proxies, serving its re-point requests. */
async function throughProxies(coordinators: Record<Name, Coordinator>, directory: string, phone: Phone,
  signal: AbortSignal, log: ProxyLog): Promise<void> {
  await mkdir(join(directory, "phone"), { recursive: true, mode: 0o700 });
  const contract: PhoneContract = {
    AGENT_E2E_WORK_SOCKET: join(directory, "work-lane.sock"), AGENT_E2E_PERSONAL_SOCKET: join(directory, "personal-lane.sock"),
    AGENT_E2E_WORK_ID: coordinators.work.id, AGENT_E2E_PERSONAL_ID: coordinators.personal.id,
    AGENT_E2E_LEGACY_INPUT: LEGACY_INPUT, AGENT_E2E_LEGACY_TEXT: LEGACY_TEXT,
    AGENT_E2E_TAGGED_TEXT: TAGGED_TEXT, AGENT_E2E_BROADCAST_TEXT: BROADCAST_TEXT,
    AGENT_E2E_REPOINT_REQUEST: join(directory, "repoint-request"), AGENT_E2E_REPOINT_ACK: join(directory, "repoint-ack"),
    AGENT_E2E_DIRECTORY: join(directory, "phone"),
  };
  const work = await startProxy("work-lane", contract.AGENT_E2E_WORK_SOCKET, coordinators.work, log);
  const personal = await startProxy("personal-lane", contract.AGENT_E2E_PERSONAL_SOCKET, coordinators.personal, log);
  const stopPhone = new AbortController();
  let finished = false;
  const running = phone(contract, AbortSignal.any([signal, stopPhone.signal])).finally(() => { finished = true; });
  void running.catch(() => {});
  try {
    while (!finished) {
      signal.throwIfAborted();
      if (await exists(contract.AGENT_E2E_REPOINT_REQUEST)) {
        const name = (await readFile(contract.AGENT_E2E_REPOINT_REQUEST, "utf8")).trim();
        assert.ok(name === "work" || name === "personal", `A re-point request must name work or personal, not ${JSON.stringify(name)}`);
        await rm(contract.AGENT_E2E_REPOINT_REQUEST);
        work.repoint(coordinators[name]);
        await writeAtomically(contract.AGENT_E2E_REPOINT_ACK, name);
      }
      await sleep(10);
    }
    await running;
  } finally {
    stopPhone.abort();
    await running.catch(() => {});
    await work.close();
    await personal.close();
  }
}

/** A Node phone that dials like the designed app: `identify` first, and close unless the expected coordinator answers. */
function standInPhone(fault: Fault): Phone {
  return async (contract, signal) => {
    const lanes = {
      work: [contract.AGENT_E2E_WORK_SOCKET, contract.AGENT_E2E_WORK_ID],
      personal: [contract.AGENT_E2E_PERSONAL_SOCKET, contract.AGENT_E2E_PERSONAL_ID],
    } as const;
    const frame = (request: NativeRequest) => JSON.stringify({ type: "native", request }) + "\n";
    let skipsCheck = false;
    async function dial(lane: Name) {
      const [path, expected] = lanes[lane];
      const channel = createConnection({ path, signal });
      try {
        channel.write(frame({ type: "identify" }));
        const lines = protocolLines(channel);
        const answer = await lines.next();
        const identity = answer.done ? undefined : parse(answer.value) as { coordinator_id?: unknown } | null | undefined;
        if (skipsCheck || identity?.coordinator_id === expected) return { channel, lines };
      } catch (error) { channel.destroy(); throw error; }
      channel.destroy();
      return undefined;
    }
    async function send(lane: Name, request: NativeRequest): Promise<"sent" | "refused"> {
      const dialed = await dial(lane);
      if (!dialed) return "refused";
      try {
        dialed.channel.write(frame(request));
        for await (const line of dialed.lines) {
          const type = (parse(line) as { type?: unknown } | null | undefined)?.type;
          if (type === "done" || type === "idle") break;
        }
        return "sent";
      } finally { dialed.channel.destroy(); }
    }
    async function repoint(name: Name): Promise<void> {
      await writeAtomically(contract.AGENT_E2E_REPOINT_REQUEST, name);
      while (await readFile(contract.AGENT_E2E_REPOINT_ACK, "utf8").catch(() => "") !== name) {
        signal.throwIfAborted();
        await sleep(10);
      }
      await rm(contract.AGENT_E2E_REPOINT_ACK);
    }
    const submit = (input_id: string, text: string): NativeRequest => ({ type: "submit", input_id, text, mode: "steer" });
    const observe: NativeRequest = { type: "observe", input_ids: [] };

    assert.equal(await send("work", observe), "sent", "The work lane answers as Work");
    assert.equal(await send("personal", observe), "sent", "The personal lane answers as Personal");
    if (fault === "sendsLegacyInput") await send("work", submit(contract.AGENT_E2E_LEGACY_INPUT, contract.AGENT_E2E_LEGACY_TEXT));
    const tagged = submit(randomUUID(), contract.AGENT_E2E_TAGGED_TEXT);
    await send("work", tagged);
    const broadcast = randomUUID();
    await send("work", submit(broadcast, contract.AGENT_E2E_BROADCAST_TEXT));
    await send("personal", submit(fault === "reusesBroadcastInput" ? broadcast : randomUUID(), contract.AGENT_E2E_BROADCAST_TEXT));

    const watching = await dial("work");
    assert.ok(watching, "The work lane answers as Work before the re-point");
    watching.channel.write(frame(observe));
    void (async () => { for await (const _ of watching.lines); })().catch(() => {});
    const cut = once(watching.channel, "close", { signal: AbortSignal.timeout(10_000) }).then(() => true, () => false);
    await repoint("personal");
    assert.ok(await cut, "Re-pointing the work lane closes the connections it already had open");
    skipsCheck = fault === "skipsIdentifyAfterRepoint";
    const repointed = skipsCheck ? "sent" : "refused";
    assert.equal(await send("work", tagged), repointed, "Retrying the @Work input on the re-pointed lane");
    assert.equal(await send("work", submit(randomUUID(), "Invented note written after the re-point.")), repointed,
      "A new message on the re-pointed lane");
    await repoint("work");
    assert.equal(await send("work", observe), "sent", "A lane pointed back answers as Work again");
  };
}

async function swiftTest(args: string[], home: string, env: Record<string, string>, signal: AbortSignal): Promise<string> {
  const project = fileURLToPath(new URL("../../../ios", import.meta.url));
  // Its own build folder: `node --test` runs this file beside coordinator-observation-e2e,
  // and two SwiftPM builds in one folder fail on its locked build database.
  const scratch = fileURLToPath(new URL("../../../target/two-coordinator-feed-integration", import.meta.url));
  const child = spawn("/usr/bin/xcrun", ["--sdk", "macosx", "swift", "test", ...args,
    "--package-path", project, "--scratch-path", scratch], {
    detached: true, stdio: ["ignore", "pipe", "pipe"],
    env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", HOME: home, TMPDIR: home, ...env },
  });
  const closed = new Promise<number | null>((resolve, reject) => {
    child.once("close", resolve); child.once("error", reject);
  });
  void closed.catch(() => {});
  let output = "";
  child.stdout.setEncoding("utf8").on("data", (value: string) => { output += value; });
  child.stderr.setEncoding("utf8").on("data", (value: string) => { output += value; });
  const stop = () => {
    if (child.pid !== undefined && child.exitCode === null && child.signalCode === null) {
      try { process.kill(-child.pid, "SIGTERM"); } catch (error) {
        if (!(error instanceof Error && "code" in error && error.code === "ESRCH")) throw error;
      }
    }
  };
  signal.addEventListener("abort", stop, { once: true });
  try {
    assert.equal(await closed, 0, output);
    return output;
  } finally {
    signal.removeEventListener("abort", stop);
    stop();
    await closed.catch(() => {});
  }
}

test("two production coordinators behind recording proxies", { timeout: 300_000 }, async (t) => {
  const directory = await mkdtemp("/tmp/agent-two-coordinator-e2e-");
  const binary = process.env.AGENT_TEST_BINARY ?? fileURLToPath(new URL("../../../target/debug/beep-boop", import.meta.url));
  const runtime = fileURLToPath(new URL("../src/bridge.js", import.meta.url));
  const bin = join(directory, "bin");
  const children: Server[] = [];
  async function start(name: Name): Promise<Coordinator> {
    const home = join(directory, name), state = join(home, "state"), socket = join(state, "agent.sock");
    await mkdir(state, { recursive: true, mode: 0o700 });
    await writeFile(join(home, "config.toml"), `node_name = "coordinator-${name}"\njob_directories = []\n`);
    await writeFile(join(home, "AGENTS.md"), "Use only invented test data.\n");
    const child = spawn(binary, ["--state-dir", state, "--config", join(home, "config.toml"),
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
    children.push({ child, closed });
    while (!await stat(socket).then((value) => value.isSocket(), () => false)) {
      assert.equal(child.exitCode, null, stderr);
      t.signal.throwIfAborted();
      await sleep(10);
    }
    return { name, socket, id: await readFile(join(state, "coordinator-id"), "utf8") };
  }
  try {
    await mkdir(bin, { mode: 0o700 });
    await symlink(process.execPath, join(bin, "node"));
    const coordinators = { work: await start("work"), personal: await start("personal") };
    assert.notEqual(coordinators.work.id, coordinators.personal.id);
    t.diagnostic(`work answers ${coordinators.work.id}, personal answers ${coordinators.personal.id}`);
    const run = async (t: TestContext, label: string, phone: Phone) => {
      const log: ProxyLog = { sent: [], answers: [] };
      try {
        await throughProxies(coordinators, join(directory, label), phone, t.signal, log);
      } finally {
        // A phone that failed still shows what each coordinator received and which invariants broke.
        for (const line of [...summarize(log), ...Object.values(violations(log))]) t.diagnostic(line);
      }
      return log;
    };

    await t.test("a stand-in phone that identifies every socket keeps all four invariants", async (t) => {
      const log = await run(t, "honest", standInPhone("none"));
      assert.deepEqual(violations(log), {});
      const answered = (target: Name) => new Set(log.answers
        .filter((answer) => answer.lane === "work-lane" && answer.target === target).map((answer) => answer.coordinator_id));
      assert.deepEqual(answered("personal"), new Set([coordinators.personal.id]), "The re-pointed work lane reached Personal");
      assert.deepEqual(answered("work"), new Set([coordinators.work.id]), "The work lane reached Work before and after the re-point");
    });

    const controls: [Fault, Record<number, RegExp>][] = [
      ["skipsIdentifyAfterRepoint", {
        1: /^Invariant 1 broke: the @Work message reached personal as input \S+ on work-lane connection \d+ to personal/,
        3: /^Invariant 3 broke: re-pointed work-lane connection \d+ to personal \(answered [0-9a-f-]+\) carried .*"type":"submit"/,
      }],
      ["reusesBroadcastInput", { 2: /^Invariant 2 broke: work and personal both received the untagged message as input / }],
      ["sendsLegacyInput", { 4: /^Invariant 4 broke: legacy "5b2e8c41-7d3a-4f6e-9a1b-3c4d5e6f7a8b" left the phone on work-lane/ }],
    ];
    for (const [fault, expected] of controls) {
      await t.test(`negative control: a stand-in that ${fault} breaks invariant ${Object.keys(expected).join(" and ")}`, async (t) => {
        const broken = violations(await run(t, fault, standInPhone(fault)));
        assert.deepEqual(Object.keys(broken), Object.keys(expected));
        for (const [invariant, pattern] of Object.entries(expected)) assert.match(broken[Number(invariant)] ?? "", pattern);
      });
    }

    await t.test(`the iOS app keeps all four invariants (${SWIFT_TEST})`, async (t) => {
      if (process.platform !== "darwin") { t.skip("The iOS package builds only on macOS"); return; }
      const listed = await swiftTest(["list"], directory, {}, t.signal);
      if (!listed.includes(`${SWIFT_TEST}(`)) {
        t.skip(`ios has no ${SWIFT_TEST} test yet; the stand-in phones above prove this harness until it lands`);
        return;
      }
      const log = await run(t, "ios", (contract, signal) =>
        swiftTest(["--filter", SWIFT_TEST], directory, contract, signal).then(() => {}));
      assert.deepEqual(violations(log), {});
    });
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
