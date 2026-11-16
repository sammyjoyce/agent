import assert from "node:assert/strict";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage } from "@earendil-works/pi-ai";
import { ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { AuthorityDenied } from "../src/failover/authority-client.js";
import { AuthorityUnreachable } from "../src/failover/authority-link.js";
import { INLINE_BATCH_LIMIT_BYTES, sha256Hex } from "../src/failover/log-entry.js";
import { OwnerFenced } from "../src/failover/replicated-storage.js";
import { UnloggedWrite } from "../src/failover/scoped-database.js";
import { authorities, enroll, follow, localNotes, logBatches, logEntries, loggedNotes, note, openOwner, OWNER, replaceOwner, STANDBY,
  stateDirectory, tables, takeBack } from "./fixtures/failover-state.js";
import { until } from "./fixtures/until.js";

const context = BACKGROUND_CONTEXT;

/** Deterministic invented bytes that do not compress, standing in for a prepared image. */
function inventedImage(seed: number, bytes: number): string {
  const data = Buffer.alloc(bytes);
  let state = seed;
  for (let index = 0; index < bytes; index += 1) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    data[index] = state >> 16;
  }
  return data.toString("base64");
}

for (const [name, connect] of Object.entries(authorities)) {
  test(`${name}: a commit refused by a sealed log is on neither disk nor log, and its resubmit is accepted once by the next owner`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const sealed = await openOwner(directory, link, { epoch });
    await sealed.root.submit(note("first", "request-1"), context);
    const promoted = await link.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null });
    assert.equal(promoted.result, "accepted");
    await assert.rejects(sealed.root.submit(note("refused", "request-2"), context),
      (error) => error instanceof OwnerFenced && error.reason === "sealed");
    await assert.rejects(sealed.root.submit(note("after", "request-3"), context), "the fenced owner accepts nothing more");
    await sealed.harness.close(context).catch(() => {});
    assert.deepEqual(localNotes(directory), ["first"]);
    assert.deepEqual(await loggedNotes(link), ["first"]);

    const next = await openOwner(directory, link, { epoch: await takeBack(link, OWNER, epoch) });
    t.after(() => next.harness.close(context));
    await next.root.submit(note("refused", "request-2"), context);
    await next.root.submit(note("refused", "request-2"), context);
    assert.deepEqual(localNotes(directory), ["first", "refused"]);
    assert.deepEqual(await loggedNotes(link), ["first", "refused"]);
  });

  test(`${name}: a crash after the append and before the local commit is repaired on reopen, before Pi opens`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const crash = new AbortController();
    const crashed = await openOwner(directory, link, { epoch, signal: crash.signal });
    await crashed.root.submit(note("first", "request-1"), context);
    link.after = (command) => {
      if (command.op !== "append") return;
      link.after = () => {};
      crash.abort();
      throw new AuthorityUnreachable("The process stopped before it read the reply");
    };
    await assert.rejects(crashed.root.submit(note("appended then crashed", "request-2"), context));
    await crashed.harness.close(context).catch(() => {});
    assert.deepEqual(localNotes(directory), ["first"], "the local commit never ran");
    assert.deepEqual(await loggedNotes(link), ["first", "appended then crashed"], "the log is one entry ahead");

    const reopened = await openOwner(directory, link, { epoch });
    t.after(() => reopened.harness.close(context));
    assert.deepEqual(localNotes(directory), ["first", "appended then crashed"]);
    const head = reopened.log.head;
    await reopened.root.submit(note("appended then crashed", "request-2"), context);
    assert.equal(reopened.log.head, head, "the resubmit is answered from the row the log already holds");
    assert.deepEqual(await loggedNotes(link), ["first", "appended then crashed"]);
  });

  test(`${name}: an append whose reply is lost is retried and accepted as a repeat`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    let appends = 0;
    link.after = (command) => {
      if (command.op !== "append") return;
      appends += 1;
      if (appends === 1) throw new AuthorityUnreachable("The reply was lost");
    };
    const before = owner.log.head;
    await owner.root.submit(note("sent twice", "request-1"), context);
    assert.equal(appends, 2);
    assert.equal(owner.log.head, before + 1, "one log entry");
    assert.deepEqual(await loggedNotes(link), ["sent twice"]);
    assert.deepEqual(localNotes(directory), ["sent twice"], "one local commit");
  });

  test(`${name}: an append whose reply is lost and whose retry meets a seal fences the owner with nothing committed locally`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context).catch(() => {}));
    await owner.root.submit(note("first", "request-1"), context);
    const before = tables(directory);
    link.after = async (command) => {
      if (command.op !== "append") return;
      link.after = () => {};
      await link.command({ op: "promote", candidate: STANDBY, expected_epoch: epoch, attestation: null });
      throw new AuthorityUnreachable("The reply was lost");
    };
    await assert.rejects(owner.root.submit(note("sealed away", "request-2"), context), OwnerFenced);
    assert.deepEqual(tables(directory), before);
    assert.deepEqual(await loggedNotes(link), ["first", "sealed away"], "the log holds the entry, so the next owner applies it");
  });

  test(`${name}: a replaced owner is fenced at its next commit and at its next start`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const stale = await openOwner(directory, link, { epoch });
    t.after(() => stale.harness.close(context).catch(() => {}));
    await stale.root.submit(note("first", "request-1"), context);
    const before = tables(directory);
    await replaceOwner(link, STANDBY, epoch);
    await assert.rejects(stale.root.submit(note("stale", "request-2"), context),
      (error) => error instanceof OwnerFenced && error.reason === "fenced" && error.state?.kind === "active" && error.state.holder === STANDBY);
    assert.deepEqual(tables(directory), before);
    assert.deepEqual(await loggedNotes(link), ["first"]);
    await stale.harness.close(context).catch(() => {});
    await assert.rejects(openOwner(directory, link, { epoch }), OwnerFenced);
  });

  test(`${name}: a commit waits out an unreachable authority while reads complete, then lands once`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    let refusedExchanges = 0, reachable = false;
    t.after(() => { reachable = true; return owner.harness.close(context); });
    await owner.root.submit(note("first", "request-1"), context);
    link.before = () => {
      if (reachable) return;
      refusedExchanges += 1;
      throw new AuthorityUnreachable("The authority is unreachable");
    };
    let settled = false;
    const waiting = owner.root.submit(note("waited", "request-2"), context).finally(() => { settled = true; });
    await until(() => refusedExchanges >= 3, "the commit keeps retrying");
    assert.equal((await owner.storage.conversation(ROOT_CONVERSATION_ID, context))?.id, ROOT_CONVERSATION_ID, "a read completes during the wait");
    assert.equal((await owner.storage.scanEntries({ conversationId: ROOT_CONVERSATION_ID }, 10, undefined, context)).items.length > 0, true);
    assert.equal(settled, false);
    assert.deepEqual(localNotes(directory), ["first"]);
    reachable = true;
    await waiting;
    assert.deepEqual(localNotes(directory), ["first", "waited"]);
    assert.deepEqual(await loggedNotes(link), ["first", "waited"]);
  });

  test(`${name}: an abort ends the wait for an unreachable authority with an error and no local commit`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const stop = new AbortController();
    const owner = await openOwner(directory, link, { epoch, signal: stop.signal });
    t.after(() => owner.harness.close(context).catch(() => {}));
    const before = tables(directory);
    let refusedExchanges = 0;
    link.before = () => { refusedExchanges += 1; throw new AuthorityUnreachable("The authority is unreachable"); };
    const waiting = owner.root.submit(note("never sent", "request-1"), context);
    await until(() => refusedExchanges >= 2, "the commit keeps retrying");
    stop.abort();
    await assert.rejects(waiting, /authority/);
    link.before = () => {};
    assert.deepEqual(tables(directory), before);
    assert.deepEqual(await loggedNotes(link), []);
  });

  test(`${name}: a rejection that is not a lost exchange ends the commit at once, with nothing on disk or in the log`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context).catch(() => {}));
    const before = tables(directory);
    let exchanges = 0;
    link.before = () => { exchanges += 1; throw new AuthorityDenied(403, "Invented: this credential was revoked"); };
    await assert.rejects(owner.root.submit(note("denied", "request-1"), context), AuthorityDenied);
    link.before = () => {};
    assert.equal(exchanges, 1, "a denied exchange is not repeated");
    assert.deepEqual(tables(directory), before);
    assert.deepEqual(await loggedNotes(link), []);
  });

  test(`${name}: a batch over 256 KiB goes to the blob store and the log entry names it by hash`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    await owner.root.submit(note("small", "request-1"), context);
    const large = "invented ".repeat(40_000);
    await owner.root.submit(note(large, "request-2"), context);
    const entries = await logEntries(link);
    assert.equal(entries.filter(({ batch }) => batch?.kind === "blob").length, 1);
    for (const { batch } of entries) {
      assert.ok(batch);
      if (batch.kind === "inline") { assert.ok(Buffer.byteLength(batch.json) <= INLINE_BATCH_LIMIT_BYTES); continue; }
      const bytes = await link.getBlob(batch.sha256);
      assert.ok(batch.size > INLINE_BATCH_LIMIT_BYTES);
      assert.equal(bytes.byteLength, batch.size);
      assert.equal(sha256Hex(bytes), batch.sha256);
    }
    assert.deepEqual(await loggedNotes(link), ["small", large]);
    assert.deepEqual(localNotes(directory), ["small", large]);
  });

  test(`${name}: an input with three large images is one 12 MB batch, accepted once, and a standby replays it`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    owner.faux.setResponses([fauxAssistantMessage("Invented reply about three images.")]);
    const content = [{ type: "text" as const, text: "Compare these three invented screenshots." },
      ...[1, 2, 3].map((seed) => ({ type: "image" as const, data: inventedImage(seed, 3_000_000), mimeType: "image/png" }))];
    const submission = await owner.root.submit({ type: "input", content, requestId: "request-images" }, context);
    assert.equal((await submission.wait(context)).status, "done");
    const head = owner.log.head;
    await owner.root.submit({ type: "input", content, requestId: "request-images" }, context);
    assert.equal(owner.log.head, head, "the repeated request commits nothing");
    await owner.harness.close(context);
    const blobs = (await logEntries(link)).flatMap(({ batch }) => batch?.kind === "blob" ? [batch] : []);
    assert.equal(blobs.filter(({ size }) => size > 12_000_000).length, 1, "the input is one batch of 12 MB in the blob store");
    assert.equal(await follow(standby, link), (await link.record())?.state.head);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: a batch Pi refuses never reaches the log`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context).catch(() => {}));
    await owner.root.submit(note("first", "request-1"), context);
    const reused = (await logBatches(link)).flat().find((write) => write.type === "entry");
    assert.ok(reused);
    const head = owner.log.head, before = tables(directory);
    await assert.rejects(owner.storage.commit([reused], context), /already belongs to entry/);
    assert.equal((await link.record())?.state.head, head);
    assert.equal(owner.log.head, head);
    assert.deepEqual(tables(directory), before);
  });

  test(`${name}: the owner's disk holds the batch as the log holds it, also when JSON changes a value`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    await owner.root.submit(note("first", "request-1"), context);
    const logged = (await logBatches(link)).flat().findLast((write) => write.type === "entry");
    assert.ok(logged);
    let serialized = 0;
    const unstable = { toJSON: () => `serialized ${serialized += 1} times` } as unknown as string;
    await owner.storage.commit([{ type: "entry", value: { ...logged.value, id: await owner.storage.mintId(), data: unstable } }], context);
    await owner.harness.close(context);
    await follow(standby, link);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: an empty batch takes a sequence as it does in plain storage, and a standby follows it`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t), standby = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    const head = owner.log.head;
    const first = await owner.storage.commit([], context);
    assert.equal(await owner.storage.commit([], context), first + 1);
    assert.equal(owner.log.head, head + 2);
    await owner.harness.close(context);
    assert.equal(await follow(standby, link), head + 2);
    assert.deepEqual(tables(standby), tables(directory));
  });

  test(`${name}: a write to the owner's database outside the barrier throws`, async (t) => {
    const link = await connect(), epoch = await enroll(link), directory = await stateDirectory(t);
    const owner = await openOwner(directory, link, { epoch });
    t.after(() => owner.harness.close(context));
    await owner.root.submit(note("first", "request-1"), context);
    const before = tables(directory), head = owner.log.head;
    await assert.rejects(owner.database.transaction((transaction) => transaction.run("DELETE FROM entries")), UnloggedWrite);
    await assert.rejects(owner.database.run("DELETE FROM entries"), UnloggedWrite);
    assert.deepEqual(tables(directory), before);
    await owner.root.submit(note("second", "request-2"), context);
    assert.equal(owner.log.head, head + 1, "the barrier still commits after a refused write");
    assert.deepEqual(localNotes(directory), ["first", "second"]);
  });
}
