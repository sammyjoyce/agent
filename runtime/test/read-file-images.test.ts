import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { crc32, deflateSync } from "node:zlib";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall, type Message, type TranscriptContext } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import { IMAGE_CHUNK_BYTES, MAX_IMAGE_READ_BYTES } from "../src/generated/image-read-limits.js";
import { readImageFile, type ReadFileCommand } from "../src/images.js";
import { ConversationModels } from "../src/models.js";
import { TaskStore } from "../src/tasks.js";
import { createAppTools, Executions } from "../src/tools.js";

/** An RGB PNG of one color whose pixels are stored, not compressed, so its size follows its area. */
function png(width: number, height: number): Buffer {
  const row = Buffer.concat([Buffer.of(0), Buffer.alloc(width * 3, 0x5a)]);
  const chunk = (kind: string, data: Buffer) => {
    const body = Buffer.concat([Buffer.from(kind, "ascii"), data]);
    const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4); header.set([8, 2, 0, 0, 0], 8);
  return Buffer.concat([Buffer.from("\x89PNG\r\n\x1a\n", "latin1"), chunk("IHDR", header),
    chunk("IDAT", deflateSync(Buffer.concat(Array.from({ length: height }, () => row)), { level: 0 })), chunk("IEND", Buffer.alloc(0))]);
}

function host(files: Record<string, Buffer>, rewritten: ReadonlySet<string>) {
  const calls: HostCommand[] = [];
  async function call(command: HostCommand): Promise<HostResult> {
    calls.push(command);
    assert.ok(command.type === "read_file" && command.image !== undefined);
    const bytes = files[command.path]; assert.ok(bytes !== undefined);
    const at = command.image.type === "next" ? command.image.at : 0;
    const stamp = rewritten.has(command.path) && at > 0 ? "version-2" : "version-1";
    return { type: "image_chunk", media_type: "image/png", size_bytes: bytes.length, stamp, at,
      data_base64: bytes.subarray(at, at + IMAGE_CHUNK_BYTES).toString("base64") };
  }
  return { calls, call };
}

function toolResult(context: TranscriptContext): Extract<Message, { role: "toolResult" }> {
  const result = context.messages.at(-1);
  assert.ok(result?.role === "toolResult");
  return result;
}

test("read_file prepares a host image within the model's limits and refuses one that changes mid-transfer", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-read-file-images-"));
  const registry = createRegistry(), models = createModels(), executions = new Executions();
  const faux = fauxProvider({ provider: "openai", tokensPerSecond: 1_000_000,
    models: [{ id: "narrow", input: ["text", "image"], inputLimits: { images: { resize: { maxWidth: 800 } } } }] });
  models.setProvider(faux.provider);
  const session = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  registry.install(createAppTools(new TaskStore(session, new ConversationModels(models)), executions).host);
  const root = await session.root(BACKGROUND_CONTEXT, { agent: { model: { provider: "openai", modelId: "narrow" }, instructions: "Use invented fixtures." } });
  const wide = png(1200, 400), fixture = host({ "/fixture/wide.png": wide, "/fixture/changing.png": wide }, new Set(["/fixture/changing.png"]));
  const release = executions.bind(root.id.toString(), { cwd: "/fixture", hosts: [], call: fixture.call });
  const seen: Extract<Message, { role: "toolResult" }>[] = [];
  const read = (path: string) => fauxAssistantMessage(fauxToolCall("read_file", { path }), { stopReason: "toolUse" });
  try {
    assert.ok(wide.length > IMAGE_CHUNK_BYTES, "The fixture spans two chunks");
    faux.setResponses([
      read("wide.png"),
      (context) => { seen.push(toolResult(context)); return read("changing.png"); },
      (context) => { seen.push(toolResult(context)); return fauxAssistantMessage("Both reads finished."); },
    ]);
    const settled = await (await root.submit({ type: "input", content: "Read both images." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
    assert.equal(settled.status, "done");

    const [prepared, changed] = seen;
    assert.ok(prepared !== undefined && changed !== undefined);
    const image = prepared.content.find((part) => part.type === "image");
    assert.ok(image?.type === "image" && image.mimeType === "image/png", JSON.stringify(prepared.content));
    const decoded = Buffer.from(image.data, "base64");
    assert.equal(decoded.readUInt32BE(16), 800, "Photon fits the model's maximum width");
    assert.equal(decoded.readUInt32BE(20), 267);
    const text = prepared.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
    assert.match(text, /Resized from 1200x400 to 800x267\. Multiply coordinates by 1\.50/);
    assert.notEqual(prepared.isError, true);

    assert.equal(changed.isError, true);
    assert.ok(!changed.content.some((part) => part.type === "image"), "A changed file never reaches the model");
    assert.match(changed.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n"), /changing\.png changed while it was read/);

    assert.deepEqual(fixture.calls.map((command) => command.type === "read_file" ? [command.path, command.image] : []), [
      ["/fixture/wide.png", { type: "start" }],
      ["/fixture/wide.png", { type: "next", at: IMAGE_CHUNK_BYTES, stamp: "version-1" }],
      ["/fixture/changing.png", { type: "start" }],
      ["/fixture/changing.png", { type: "next", at: IMAGE_CHUNK_BYTES, stamp: "version-1" }],
    ]);
  } finally {
    release(); await session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true });
  }
});

test("an image transfer ends without an image on any reply that does not continue the same file version", async () => {
  const command: ReadFileCommand = { type: "read_file", path: "/fixture/shot.png", offset: 0, limit: 64_000, image: { type: "start" } };
  const size = IMAGE_CHUNK_BYTES + 4;
  type ImageChunk = Extract<HostResult, { type: "image_chunk" }>;
  const chunk = (at: number, length: number, change: Partial<ImageChunk> = {}): ImageChunk => ({
    type: "image_chunk", media_type: "image/png", size_bytes: size, stamp: "version-1", at, data_base64: Buffer.alloc(length).toString("base64"), ...change });
  const first = chunk(0, IMAGE_CHUNK_BYTES);
  const input = { vision: true, limits: { maxWidth: 2000, maxHeight: 2000, maxBytes: 4_718_592 } };
  const cases: [string, ImageChunk, HostResult | undefined][] = [
    ["a first chunk past 0", chunk(4, IMAGE_CHUNK_BYTES), undefined],
    ["an empty image", chunk(0, 0, { size_bytes: 0 }), undefined],
    ["an image over the cap", chunk(0, IMAGE_CHUNK_BYTES, { size_bytes: MAX_IMAGE_READ_BYTES + 1 }), undefined],
    ["a short first chunk", chunk(0, IMAGE_CHUNK_BYTES - 1), undefined],
    ["a short last chunk", first, chunk(IMAGE_CHUNK_BYTES, 3)],
    ["a long last chunk", first, chunk(IMAGE_CHUNK_BYTES, 5)],
    ["a chunk at the wrong offset", first, chunk(IMAGE_CHUNK_BYTES - 4, 4)],
    ["another media type", first, chunk(IMAGE_CHUNK_BYTES, 4, { media_type: "image/jpeg" })],
    ["another size", first, chunk(IMAGE_CHUNK_BYTES, 4, { size_bytes: size + 1 })],
    ["a text reply from a downgraded host", first, { type: "file", content: "", truncated: false }],
  ];
  for (const [name, start, next] of cases) {
    const calls: HostCommand[] = [];
    const result = await readImageFile(async (command) => { calls.push(command); assert.ok(next !== undefined, `${name} makes no further host call`); return next; },
      command, start, input);
    assert.deepEqual(result, { output: [], isError: true, diagnostics: [{ severity: "error", code: "unsupported_image",
      message: "/fixture/shot.png changed while it was read; read it again." }] }, name);
    assert.equal(calls.length, next === undefined ? 0 : 1, name);
  }
  const failed: HostResult = { type: "failed", message: "The file changed while it was read; read it again" };
  assert.deepEqual(await readImageFile(async () => failed, command, first, input),
    { output: [{ type: "text", text: JSON.stringify(failed) }], isError: true }, "A host failure reads as any failed host result");
});
