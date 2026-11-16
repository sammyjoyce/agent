import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";
import { once } from "node:events";
import { createServer as createHttpServer } from "node:http";
import { createServer, type Server, type Socket } from "node:net";
import test, { type TestContext } from "node:test";
import { AuthorityClient, AuthorityDenied, AuthorityProtocolError, AuthorityRejected } from "../src/failover/authority-client.js";
import { AuthorityUnreachable } from "../src/failover/authority-link.js";
import { commandHolder } from "../src/failover/authority-wire.js";
import type { AuthorityCommand } from "../src/generated/AuthorityCommand.js";
import type { AuthorityReply } from "../src/generated/AuthorityReply.js";
import type { LogEntry } from "../src/generated/LogEntry.js";
import { cellCheckpoint, cellCommand, cellLog, cells, cellStates, digests, entry, holders, manifest, manifestBytes, orion, scriptedSequences, tarantula,
  type Outcome, type Script } from "./fixtures/failover-authority-cells.js";
import { startAuthority } from "./fixtures/failover-workerd.js";

const coordinatorIds = Array.from({ length: 120 }, (_, index) => `00000000-0000-4000-8000-${index.toString(16).padStart(12, "0")}`);
const readOnlyCoordinator = coordinatorIds[0]!;
const sha256 = (bytes: Uint8Array) => createHash("sha256").update(bytes).digest("hex");
const outcome = (reply: AuthorityReply): Outcome => reply.result === "accepted" ? "accepted" : reply.reason;
const enroll: AuthorityCommand = { op: "enroll", holder: tarantula, checkpoint: { through: 0, manifest } };
const append = (at: number, change: Partial<LogEntry> = {}, epoch = 1): Extract<AuthorityCommand, { op: "append" }> =>
  ({ op: "append", holder: tarantula, entry: { ...entry(epoch, at, digests[0]), ...change } });
const status = (expected: number, type: typeof AuthorityRejected | typeof AuthorityDenied) => (error: unknown) =>
  error instanceof type && error.status === expected;

test("the authority Worker on local workerd", { timeout: 180_000 }, async (t) => {
  const authority = await startAuthority({ context: t, grants: [
    ...coordinatorIds.flatMap((coordinator) => holders.map((holder) => ({ coordinator, holder }))),
    { coordinator: readOnlyCoordinator, holder: null },
  ] });
  let used = 1;
  const token = (coordinator: string, holder: string | null) =>
    authority.credentials.find((credential) => credential.coordinator === coordinator && credential.holder === holder)!.token;
  const link = (coordinator: string, holder: string | null = tarantula) =>
    new AuthorityClient({ url: authority.url, coordinatorId: coordinator, token: token(coordinator, holder) });
  const bare = () => coordinatorIds[used++] ?? assert.fail("the test ran out of coordinator ids");
  const fresh = async () => {
    const coordinator = bare();
    await link(coordinator).putBlob(manifest, manifestBytes);
    return coordinator;
  };
  const play = async (coordinator: string, script: Script) => {
    for (const [command, expected] of script) {
      assert.equal(outcome(await link(coordinator, commandHolder(command)).command(command)), expected, JSON.stringify(command));
    }
  };
  const pages = async (coordinator: string, limit = 64) => {
    const result: LogEntry[][] = [];
    for (let after = 0; ;) {
      const { entries } = await link(coordinator).log(after, limit);
      if (entries.length === 0) return result;
      result.push(entries);
      after = entries[entries.length - 1]!.at;
    }
  };
  const logDigests = async (coordinator: string) =>
    Object.fromEntries((await pages(coordinator)).flat().map((logged) => [logged.at, logged.digest]));
  const head = async (coordinator: string) => (await link(coordinator).record())?.state.head;

  await t.test("every cell of the rules' table gives the same answer through HTTP", async () => {
    const active: Script = [
      [{ op: "enroll", holder: tarantula, checkpoint: cellCheckpoint }, "accepted"],
      [{ op: "claim", holder: tarantula }, "accepted"],
      [{ op: "claim", holder: tarantula }, "accepted"],
      [append(1, { digest: digests[0] }, 3), "accepted"],
      [append(2, { digest: digests[1] }, 3), "accepted"],
    ];
    const sealed: Script = [...active, [{ op: "promote", candidate: orion, expected_epoch: 3, attestation: null }, "accepted"]];
    const vacant: Script = [...sealed, [{ op: "release", holder: tarantula, epoch: 3, evidence: "released" }, "accepted"]];
    const setups = [active, sealed, vacant];
    const answer = async (setup: Script | undefined, name: string, caller: string) => {
      const coordinator = await fresh();
      if (setup !== undefined) {
        await play(coordinator, setup);
        assert.deepEqual(await link(coordinator).record(), { state: cellStates[setups.indexOf(setup)], checkpoint: cellCheckpoint });
        assert.deepEqual(await logDigests(coordinator), cellLog);
      }
      return outcome(await link(coordinator, caller).command(cellCommand(name, caller)));
    };
    // One operation at a time: wrangler dev's proxy drops connections when every cell's coordinator is set up at once.
    const observed: Record<string, unknown> = {};
    for (const name of Object.keys(cells)) {
      observed[name] = [
        await answer(undefined, name, tarantula),
        ...await Promise.all(setups.map((setup) => Promise.all(holders.map((caller) => answer(setup, name, caller))))),
      ];
    }
    assert.deepEqual(observed, cells);
  });

  await t.test("the rules' scripted sequences end in the same record and log", async () => {
    for (const [name, sequence] of Object.entries(scriptedSequences)) {
      const coordinator = await fresh();
      await play(coordinator, sequence.steps);
      assert.deepEqual(await link(coordinator).record(), sequence.record, name);
      if (sequence.record === undefined) await assert.rejects(link(coordinator).log(0, 64), status(404, AuthorityRejected), name);
      else assert.deepEqual(await logDigests(coordinator), sequence.log, name);
    }
  });

  await t.test("of appends for one position sent at the same time, one is accepted and the rest are conflicts", async () => {
    const coordinator = await fresh();
    const bytes = Buffer.from("invented bytes that make each append wait on the blob store");
    await link(coordinator).putBlob(sha256(bytes), bytes);
    await play(coordinator, [[enroll, "accepted"]]);
    const files = [{ path: "attachments/a1/content", sha256: sha256(bytes), size: bytes.length }];
    const winners: Record<number, string> = {};
    for (let at = 1; at <= 20; at += 1) {
      const contenders = Array.from({ length: 6 }, (_, index) => sha256(Buffer.from(`invented entry ${at}.${index}`)));
      const replies = await Promise.all(contenders.map((digest) => link(coordinator).command(append(at, { digest, files }))));
      assert.deepEqual(replies.map(outcome).sort(), ["accepted", ...Array<Outcome>(5).fill("conflict")], `position ${at}`);
      winners[at] = contenders[replies.findIndex((reply) => reply.result === "accepted")]!;
    }
    assert.equal(await head(coordinator), 20);
    assert.deepEqual(await logDigests(coordinator), winners);
  });

  await t.test("one hundred sequential appends leave the head at 100 with no gap", async () => {
    const coordinator = await fresh();
    await play(coordinator, [[enroll, "accepted"], ...Array.from({ length: 100 }, (_, index) => [append(index + 1), "accepted"] as const)]);
    assert.equal(await head(coordinator), 100);
    assert.deepEqual((await pages(coordinator)).flat().map((logged) => logged.at), Array.from({ length: 100 }, (_, index) => index + 1));
  });

  await t.test("a repeat of an append whose reply was lost is accepted and writes nothing", async () => {
    const coordinator = await fresh();
    await play(coordinator, [[enroll, "accepted"], [append(1), "accepted"]]);
    const before = await link(coordinator).log(0, 64);
    const repeat = await link(coordinator).command(append(1));
    assert.deepEqual(repeat, { result: "accepted", state: { kind: "active", epoch: 1, holder: tarantula, head: 1 } });
    assert.deepEqual(await link(coordinator).log(0, 64), before);
    assert.equal(outcome(await link(coordinator).command(append(1, { digest: digests[1] }))), "conflict");
  });

  await t.test("an append naming a missing blob is refused until the blob is stored", async () => {
    const coordinator = await fresh();
    const attachment = Buffer.from("invented attachment bytes");
    const batch = Buffer.from(JSON.stringify([{ invented: "batch" }]));
    const withFile = append(1, { files: [{ path: "attachments/a1/content", sha256: sha256(attachment), size: attachment.length }] });
    const withBatch = append(2, { batch: { pi_seq: 2, body: { kind: "blob", sha256: sha256(batch), size: batch.length } } });
    await play(coordinator, [[enroll, "accepted"], [withFile, "missing_blob"]]);
    assert.equal(await head(coordinator), 0);
    await link(coordinator).putBlob(sha256(attachment), attachment);
    await play(coordinator, [[withFile, "accepted"], [withBatch, "missing_blob"]]);
    assert.equal(await head(coordinator), 1);
    await link(coordinator).putBlob(sha256(batch), batch);
    await play(coordinator, [[withBatch, "accepted"]]);
    assert.equal(await head(coordinator), 2);
  });

  await t.test("an enrollment or a checkpoint naming a manifest the blob store lacks is refused until the manifest is stored", async () => {
    const coordinator = bare();
    await play(coordinator, [[enroll, "missing_blob"]]);
    assert.equal(await link(coordinator).record(), undefined);
    await link(coordinator).putBlob(manifest, manifestBytes);
    await play(coordinator, [[enroll, "accepted"], [append(1), "accepted"], [append(2), "accepted"]]);

    const later = Buffer.from("invented backup manifest through entry 2");
    const checkpoint: AuthorityCommand = { op: "checkpoint", holder: tarantula, epoch: 1, record: { through: 2, manifest: sha256(later) } };
    const before = await link(coordinator).log(0, 64);
    await play(coordinator, [[checkpoint, "missing_blob"]]);
    assert.deepEqual(await link(coordinator).log(0, 64), before, "the record, the head and the log entries are unchanged");
    await link(coordinator).putBlob(sha256(later), later);
    await play(coordinator, [[checkpoint, "accepted"]]);
    assert.deepEqual(await link(coordinator).log(0, 64), { record: { ...before.record, checkpoint: { through: 2, manifest: sha256(later) } }, entries: [] });
  });

  await t.test("a 12 MiB blob round-trips and bytes that do not match their hash are refused", async () => {
    const coordinator = await fresh();
    const large = randomBytes(12 * 1024 * 1024);
    await link(coordinator).putBlob(sha256(large), large);
    const back = await link(coordinator).getBlob(sha256(large));
    assert.equal(back.byteLength, large.length);
    assert.ok(Buffer.from(back).equals(large), "the blob came back with different bytes");

    const claimed = sha256(Buffer.from("invented original"));
    await assert.rejects(link(coordinator).putBlob(claimed, Buffer.from("invented substitute")), status(422, AuthorityRejected));
    await assert.rejects(link(coordinator).getBlob(claimed), status(404, AuthorityRejected));
    const probe = (sha: string) => fetch(`${authority.url}/v1/coordinators/${coordinator}/blobs/${sha}`,
      { method: "HEAD", headers: { authorization: `Bearer ${token(coordinator, tarantula)}` } });
    assert.equal((await probe(sha256(large))).status, 200);
    assert.equal((await probe(claimed)).status, 404);
  });

  await t.test("a command body over 1 MiB is refused and an inline batch of 256 KiB is accepted", async () => {
    const coordinator = await fresh();
    await play(coordinator, [[enroll, "accepted"]]);
    const oversized = append(1, { batch: { pi_seq: 1, body: { kind: "inline", json: "x".repeat(1024 * 1024) } } });
    await assert.rejects(link(coordinator).command(oversized), status(413, AuthorityRejected));
    assert.equal(await head(coordinator), 0);
    const largest = append(1, { batch: { pi_seq: 1, body: { kind: "inline", json: "x".repeat(256 * 1024) } } });
    await play(coordinator, [[largest, "accepted"]]);
    const [stored] = (await link(coordinator).log(0, 64)).entries;
    assert.deepEqual(stored, largest.entry);
  });

  await t.test("two coordinator ids are two objects with separate credentials and blobs", async () => {
    const first = await fresh(), second = await fresh();
    const bytes = Buffer.from("invented bytes of the first coordinator");
    await play(first, [[enroll, "accepted"], [append(1), "accepted"]]);
    await link(first).putBlob(sha256(bytes), bytes);
    assert.equal(await link(second).record(), undefined);
    await assert.rejects(link(second).getBlob(sha256(bytes)), status(404, AuthorityRejected));
    await play(second, [[{ op: "enroll", holder: orion, checkpoint: { through: 0, manifest } }, "accepted"]]);
    assert.deepEqual(await link(first).record(), { state: { kind: "active", epoch: 1, holder: tarantula, head: 1 }, checkpoint: { through: 0, manifest } });
    const borrowed = new AuthorityClient({ url: authority.url, coordinatorId: second, token: token(first, tarantula) });
    await assert.rejects(borrowed.record(), status(401, AuthorityDenied));
    await assert.rejects(borrowed.command({ op: "claim", holder: tarantula }), status(401, AuthorityDenied));
  });

  await t.test("credentials: tokens are checked, holders run only their own commands, and read-only reads only the record", async () => {
    const coordinator = readOnlyCoordinator;
    const anonymous = await fetch(`${authority.url}/v1/coordinators/${coordinator}/record`);
    assert.equal(anonymous.status, 401);
    assert.equal(typeof (await anonymous.json() as { error: unknown }).error, "string");
    const wrong = new AuthorityClient({ url: authority.url, coordinatorId: coordinator, token: "invented-wrong-token" });
    await assert.rejects(wrong.record(), status(401, AuthorityDenied));

    await link(coordinator).putBlob(manifest, manifestBytes);
    await play(coordinator, [[enroll, "accepted"]]);
    await assert.rejects(link(coordinator, tarantula).command({ op: "claim", holder: orion }), status(403, AuthorityDenied));
    await assert.rejects(link(coordinator, tarantula).command({ op: "activate", candidate: orion, applied: 0 }), status(403, AuthorityDenied));

    const reader = link(coordinator, null);
    assert.deepEqual(await reader.record(), await link(coordinator).record());
    await assert.rejects(reader.log(0, 64), status(403, AuthorityDenied));
    await assert.rejects(reader.command({ op: "confirm", holder: tarantula, epoch: 1 }), status(403, AuthorityDenied));
    await assert.rejects(reader.getBlob(digests[0]), status(403, AuthorityDenied));
    await assert.rejects(reader.putBlob(sha256(Buffer.from("x")), Buffer.from("x")), status(403, AuthorityDenied));
    assert.equal(outcome(await link(coordinator).command({ op: "confirm", holder: tarantula, epoch: 1 })), "accepted");
  });

  await t.test("following the log page by page returns every entry once, in order, in bounded pages", async () => {
    const coordinator = await fresh();
    await play(coordinator, [[enroll, "accepted"], ...Array.from({ length: 150 }, (_, index) => [append(index + 1), "accepted"] as const)]);
    const capped = await pages(coordinator, 1_000);
    assert.deepEqual(capped.map((page) => page.length), [64, 64, 22]);
    assert.deepEqual(capped.flat().map((logged) => logged.at), Array.from({ length: 150 }, (_, index) => index + 1));
    assert.deepEqual((await pages(coordinator, 7)).flat(), capped.flat());

    const heavy = await fresh();
    const large = (at: number) => append(at, { batch: { pi_seq: at, body: { kind: "inline", json: "y".repeat(900 * 1024) } } });
    await play(heavy, [[enroll, "accepted"], ...[1, 2, 3, 4, 5].map((at) => [large(at), "accepted"] as const)]);
    const sized = await pages(heavy);
    assert.ok(sized.length > 1, "five entries of 900 KiB came back in one page");
    for (const page of sized) assert.ok(JSON.stringify(page).length <= 4 * 1024 * 1024 + 64 * 1024, "a page holds more than about 4 MiB");
    assert.deepEqual(sized.flat().map((logged) => logged.at), [1, 2, 3, 4, 5]);
  });

  await t.test("malformed requests are refused with 400 and a sentence", async () => {
    const coordinator = await fresh();
    const authorization = { authorization: `Bearer ${token(coordinator, tarantula)}` };
    const refusal = async (path: string, init: RequestInit = {}) => {
      const response = await fetch(`${authority.url}${path}`, { ...init, headers: { ...authorization, ...init.headers } });
      assert.equal(response.status, 400, path);
      const { error } = await response.json() as { error: unknown };
      assert.equal(typeof error, "string", path);
      return String(error);
    };
    const base = `/v1/coordinators/${coordinator}`;
    await refusal("/v1/coordinators/not-a-uuid/record");
    await refusal("/v1/coordinators/AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE/record");
    await refusal(`${base}/blobs/not-a-digest`);
    await refusal(`${base}/log?after=-1&limit=5`);
    await refusal(`${base}/log?after=0`);
    await refusal(`${base}/log?after=0&limit=0`);
    await refusal(`${base}/log?after=0&limit=5&extra=1`);
    await refusal(`${base}/commands`, { method: "POST", body: "{ not json" });
    assert.match(await refusal(`${base}/commands`, { method: "POST", body: JSON.stringify({ op: "claim", holder: tarantula, extra: 1 }) }), /extra/);
  });

  await t.test("the record, the log and a blob survive a restart of workerd", async () => {
    const coordinator = await fresh();
    const bytes = Buffer.from("invented bytes that must outlive a restart");
    await link(coordinator).putBlob(sha256(bytes), bytes);
    await play(coordinator, [[enroll, "accepted"],
      [append(1, { files: [{ path: "feedback/latest", sha256: sha256(bytes), size: bytes.length }] }), "accepted"], [append(2), "accepted"]]);
    const record = await link(coordinator).record();
    const log = await link(coordinator).log(0, 64);
    await authority.restart();
    assert.deepEqual(await link(coordinator).record(), record);
    assert.deepEqual(await link(coordinator).log(0, 64), log);
    assert.ok(Buffer.from(await link(coordinator).getBlob(sha256(bytes))).equals(bytes));
    assert.equal(outcome(await link(coordinator).command(append(3))), "accepted");
  });
});

async function listening(server: Server | ReturnType<typeof createHttpServer>, t: TestContext): Promise<number> {
  const sockets = new Set<Socket>();
  server.on("connection", (socket: Socket) => sockets.add(socket));
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise((resolve) => {
    server.close(resolve);
    for (const socket of sockets) socket.destroy();
  }));
  const address = server.address();
  assert.ok(address !== null && typeof address !== "string");
  return address.port;
}

const clientAt = (port: number, timeoutMs?: number) => new AuthorityClient({
  url: `http://127.0.0.1:${port}`, coordinatorId: coordinatorIds[1]!, token: "invented-token", ...(timeoutMs === undefined ? {} : { timeoutMs }) });

test("the client reports a closed port as unreachable", async (t) => {
  const server = createServer();
  const port = await listening(server, t);
  await new Promise((resolve) => server.close(resolve));
  await assert.rejects(clientAt(port).record(), AuthorityUnreachable);
  await assert.rejects(clientAt(port).command(enroll), AuthorityUnreachable);
});

test("the client gives up on a port that accepts and never answers after its timeout", async (t) => {
  let connections = 0;
  const server = createServer(() => { connections += 1; });
  const port = await listening(server, t);
  const started = Date.now();
  await assert.rejects(clientAt(port, 300).command(enroll), AuthorityUnreachable);
  const waited = Date.now() - started;
  assert.ok(waited >= 290 && waited < 5_000, `the client waited ${waited} ms`);
  assert.ok(connections >= 1, "the client never connected");
});

test("the client reports a server error as unreachable and never retries", async (t) => {
  let requests = 0;
  const server = createHttpServer((_, response) => {
    requests += 1;
    response.writeHead(503, { "content-type": "application/json" }).end(JSON.stringify({ error: "The invented authority is overloaded." }));
  });
  const port = await listening(server, t);
  await assert.rejects(clientAt(port).command(enroll), (error: unknown) =>
    error instanceof AuthorityUnreachable && error.message.includes("The invented authority is overloaded."));
  assert.equal(requests, 1);
});

test("the client refuses a 2xx body that is not the answer it asked for, and does not repeat the request", async (t) => {
  let requests = 0;
  const server = createHttpServer((request, response) => {
    requests += 1;
    const body = request.url?.endsWith("/record") ? "<html>Invented captive portal</html>" : JSON.stringify({ result: "accepted" });
    response.writeHead(200, { "content-type": "application/json" }).end(body);
  });
  const port = await listening(server, t);
  await assert.rejects(clientAt(port).command(enroll), (error: unknown) => error instanceof AuthorityProtocolError && error.message.includes("state"));
  await assert.rejects(clientAt(port).record(), (error: unknown) => error instanceof AuthorityProtocolError && error.message.includes("not JSON"));
  assert.equal(requests, 2);
});
