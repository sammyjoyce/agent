// Writes the log that failover-replay-1.4.0.test.ts replays: a replication log
// written by Beep Boop's runtime on Pi Durable 1.4.0 and Chord 1.4.0, the blobs
// it names, and the owner's tables and retained files after it closed.
//
// It runs against the runtime of a77ecf2, the last commit on Pi Durable 1.4.0:
//   git archive a77ecf2 runtime | tar -x -C <dir>
//   cd <dir>/runtime && npm ci --ignore-scripts && npm run build
//   cp <this file> dist/test/ && FIXTURE_OUT=<this directory> node --test dist/test/generate.mjs
import assert from "node:assert/strict";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";
import { createRegistry, defineDoc, defineDocFamily, defineExtension, defineTool, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { Type } from "typebox";
import { versions } from "../src/failover/log-entry.js";
import { MemoryAuthority } from "./fixtures/failover-memory-authority.js";
import { enroll, logEntries, note, openOwner, retainedFiles, stage, stateDirectory, tables } from "./fixtures/failover-state.js";

const context = BACKGROUND_CONTEXT;
const out = process.env.FIXTURE_OUT;
const Ledger = defineDoc({ kind: "fixture.ledger", scope: "conversation", history: "rewindable", fork: "asOf", version: 1,
  initial: () => ({ count: 0 }), checkpointWhen: () => false });
const Tally = defineDoc({ kind: "fixture.tally", scope: "session", version: 1, initial: () => ({ count: 0 }), checkpointWhen: () => false });
const Plots = defineDocFamily({ kind: "fixture.plot", scope: "session", family: true, version: 1, initial: (name) => ({ name, rows: 0 }), checkpointWhen: () => true });

function gardenRegistry(started) {
  const registry = createRegistry();
  registry.install(defineExtension({ name: "garden", tools: [
    defineTool({
      name: "note", description: "Write an invented note, one line at a time", parameters: Type.Object({ text: Type.String(), lines: Type.Number() }),
      async execute(args, api) {
        for (let line = 0; line < args.lines; line += 1) { api.output(`${args.text} line ${line}\n`); await new Promise((resolve) => setTimeout(resolve, 10)); }
        return {};
      },
    }),
    defineTool({
      name: "hold", description: "Wait until the coordinator stops", parameters: Type.Object({}),
      async execute(_args, _api, toolContext) {
        started();
        await new Promise((resolve) => toolContext.abortSignal?.addEventListener("abort", resolve, { once: true }));
        return {};
      },
    }),
  ] }));
  return registry;
}

test("write the log of a Pi Durable 1.4.0 owner", async (t) => {
  assert.ok(out, "FIXTURE_OUT names the fixture directory");
  assert.deepEqual(await versions(), { application: "0.1.0", pi_durable: "1.4.0", chord: "1.4.0" });
  const link = new MemoryAuthority(), epoch = await enroll(link), directory = await stateDirectory(t);
  let started = () => {};
  const holding = new Promise((resolve) => { started = resolve; });
  const owner = await openOwner(directory, link, { epoch, registry: gardenRegistry(() => started()), tokensPerSecond: 600 });

  owner.faux.setResponses([
    fauxAssistantMessage([fauxText("I will write that down first."), fauxToolCall("note", { text: "invented note", lines: 6 })], { stopReason: "toolUse" }),
    fauxAssistantMessage(Array.from({ length: 16 }, (_, index) => `Sentence ${index} of an invented answer about a garden plan.`).join(" ")),
  ]);
  const turn = await owner.root.submit({ type: "input", content: "Plan the garden.", requestId: "request-garden" }, context);
  assert.equal((await turn.wait(context)).status, "done");

  const early = await owner.harness.commit(async (tx) => {
    (await tx.doc(Ledger, ROOT_CONVERSATION_ID)).count = 1;
    return tx.appendEntry(ROOT_CONVERSATION_ID, { kind: "app.note", data: "the ledger says one" });
  }, context);
  await owner.harness.commit(async (tx) => { (await tx.doc(Ledger, ROOT_CONVERSATION_ID)).count = 2; }, context);
  const fork = await owner.harness.commit((tx) => tx.forkConversation(ROOT_CONVERSATION_ID, early.id, { ownership: { kind: "ownerless" } }), context);
  await owner.harness.commit((tx) => tx.retireDoc(Ledger, fork.id), context);
  await owner.harness.commit(async (tx) => { (await tx.doc(Tally)).count += 1; (await tx.doc(Plots, "north", "north")).rows = 3; }, context);
  await owner.harness.commit(async (tx) => { (await tx.doc(Tally)).count += 1; (await tx.doc(Plots, "south", "south")).rows = 1; }, context);
  await owner.harness.commit(async (tx) => { await tx.retireDoc(Tally); await tx.retireDoc(Plots, "north"); (await tx.doc(Plots, "south", "south")).rows = 2; }, context);

  await owner.log.appendFiles([await stage(directory, link, "feedback/invented-bundle.json", Buffer.from("{\"note\":\"invented feedback\"}"))]);
  owner.log.carry([await stage(directory, link, "attachments/invented-sketch.txt", Buffer.from("an invented sketch of the garden beds"))]);
  await owner.root.submit(note("the sketch is attached", "request-sketch"), context);
  await owner.log.removeFiles(["feedback/invented-bundle.json"]);

  owner.faux.setResponses([fauxAssistantMessage([fauxToolCall("hold", {})], { stopReason: "toolUse" })]);
  await owner.root.submit({ type: "input", content: "Hold the gate.", requestId: "request-hold" }, context);
  await holding;
  await owner.harness.close(context);

  const entries = await logEntries(link);
  const shas = new Set(entries.flatMap((entry) => [...entry.files.map((file) => file.sha256), ...entry.batch?.body.kind === "blob" ? [entry.batch.body.sha256] : []]));
  await rm(join(out, "blobs"), { recursive: true, force: true });
  await mkdir(join(out, "blobs"), { recursive: true });
  for (const sha256 of shas) await writeFile(join(out, "blobs", sha256), await link.getBlob(sha256));
  await writeFile(join(out, "log.jsonl"), entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
  await writeFile(join(out, "owner-tables.json"), JSON.stringify(tables(directory), null, 1) + "\n");
  await writeFile(join(out, "owner-files.json"), JSON.stringify(await retainedFiles(directory), null, 1) + "\n");
});
