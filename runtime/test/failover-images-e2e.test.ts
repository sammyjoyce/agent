import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import type { AttachmentRef } from "../src/generated/AttachmentRef.js";
import { ATTACHMENT_CHUNK_BYTES, MAX_ATTACHMENT_BYTES, MAX_ATTACHMENTS } from "../src/generated/attachment-limits.js";
import { admissions, answers, failoverWorld, type CoordinatorHost, type FailoverWorld } from "./fixtures/failover-world.js";
import { noisePng } from "./fixtures/png.js";

/** Uploads one file in the product's chunk size, as a client does, and returns its receipt. */
async function upload(world: FailoverWorld, host: CoordinatorHost, name: string, bytes: Buffer): Promise<AttachmentRef> {
  const id = randomUUID();
  for (let offset = 0; offset < bytes.length; offset += ATTACHMENT_CHUNK_BYTES) {
    const chunk = bytes.subarray(offset, offset + ATTACHMENT_CHUNK_BYTES), complete = offset + chunk.length === bytes.length;
    const events = await world.request(host, { type: "attachment", request: { type: "upload", id, name, media_type: "image/png", size_bytes: bytes.length, offset,
      data_base64: chunk.toString("base64"), complete } });
    const uploaded = events.flatMap((event) => event.type === "attachment" && event.response.type === "uploaded" ? [event.response] : [])[0];
    assert.ok(uploaded, JSON.stringify(events));
    if (complete) { assert.ok(uploaded.attachment, "the completed upload returns its receipt"); return uploaded.attachment; }
  }
  throw new Error("An empty file has no receipt");
}

const WORKER_REQUEST_BYTES = 100 * 1000 * 1000;

test("an input with eight large images is accepted once, its batch is in the blob store and the log row names it, and a standby replays it", { timeout: 180_000 }, async (t) => {
  const world = await failoverWorld(t), { owner, standby } = world;
  await world.enroll();
  await world.serve(owner);
  await world.join();
  const images: AttachmentRef[] = [];
  for (let seed = 1; seed <= MAX_ATTACHMENTS; seed += 1) images.push(await upload(world, owner, `invented-${seed}.png`, noisePng(seed, MAX_ATTACHMENT_BYTES)));
  await world.script("fixture-eight-images", [{ text: "Compared eight invented images." }]);
  const input = randomUUID();
  const events = await world.send(owner, "fixture-eight-images", { id: input, attachments: images });
  assert.equal(admissions(events, input), 1, JSON.stringify(events.filter((event) => event.type !== "message")));
  assert.deepEqual(answers(events), ["Compared eight invented images."]);

  const stored = (await world.logEntries()).flatMap(({ batch }) => batch?.body.kind === "blob" ? [batch.body] : []);
  assert.equal(stored.length, 1, "the log names one batch that the blob store holds");
  const [batch] = stored;
  assert.ok(batch);
  const bytes = Buffer.from(await world.authority.standby.getBlob(batch.sha256));
  assert.equal(bytes.length, batch.size);
  assert.ok(bytes.includes(input), "the stored batch is the one that admits the input");
  t.diagnostic(`eight images of ${MAX_ATTACHMENT_BYTES} bytes each make one Pi batch of ${batch.size} bytes`);
  assert.ok(batch.size < WORKER_REQUEST_BYTES, `a batch of ${batch.size} bytes does not fit one request to the Worker`);

  const again = await world.send(owner, "fixture-eight-images", { id: input, attachments: images });
  assert.equal(admissions(again, input), 0, "a repeat of the input is not accepted a second time");
  assert.equal(await world.logged(input), 1);
  assert.equal((await world.follow()).applied, (await world.record())?.state.head);
  assert.deepEqual(world.tables(standby), world.tables(owner));
  assert.equal(world.saved(standby, input), 1);
});
