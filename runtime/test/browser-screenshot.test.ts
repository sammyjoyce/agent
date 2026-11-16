import assert from "node:assert/strict";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import { crc32, deflateSync } from "node:zlib";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels, fauxAssistantMessage, fauxProvider, fauxToolCall, type Message, type TranscriptContext } from "@earendil-works/pi-ai";
import { createRegistry, Harness } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { AttachmentStore } from "../src/attachments.js";
import { BrowserStore, createBrowserTools } from "../src/browser.js";
import { ATTACHMENT_CHUNK_BYTES } from "../src/generated/attachment-limits.js";
import type { AttachmentRef } from "../src/generated/AttachmentRef.js";
import type { BrowserRequest } from "../src/generated/BrowserRequest.js";
import type { BrowserResponse } from "../src/generated/BrowserResponse.js";
import type { HistoryMessage } from "../src/generated/HistoryMessage.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { RuntimeCommand } from "../src/generated/RuntimeCommand.js";
import type { RuntimeEvent } from "../src/generated/RuntimeEvent.js";
import { MAX_SCREENSHOT_BYTES } from "../src/generated/screenshot-limits.js";
import { DEFAULT_MODEL } from "../src/models.js";
import { protocolLines, validEvent } from "../src/protocol.js";
import { Executions } from "../src/tools.js";
import { history } from "../src/transcript.js";

const hostId = "11111111-1111-4111-8111-111111111111";
const host = { host_id: hostId, name: "fixture", rex_server: null, coordinator: null, cwd: "/example/project", agent_program: "/example/agent" };
const stripes: [number, number, number][] = [[0xd0, 0x30, 0x30], [0x30, 0xa0, 0x40], [0x30, 0x50, 0xd0]];

/** An invented page capture: one vertical stripe per color, stored without compression. */
function capturePng(width: number, height: number): Buffer {
  const row = Buffer.alloc(1 + width * 3);
  for (let x = 0; x < width; x++) row.set(stripes[Math.floor(x * stripes.length / width)] ?? [0, 0, 0], 1 + x * 3);
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
function sha256(bytes: Buffer): string { return createHash("sha256").update(bytes).digest("hex"); }
function size(png: Buffer): [number, number] { return [png.readUInt32BE(16), png.readUInt32BE(20)]; }

async function open(directory: string) {
  const database = await openNodeSqliteDatabase(join(directory, "session.sqlite"));
  await database.exec("PRAGMA synchronous = FULL");
  const models = createModels();
  const faux = fauxProvider({ provider: "openai", models: [{ id: "fixture", input: ["text", "image"] }], tokensPerSecond: 1_000_000 });
  models.setProvider(faux.provider);
  const registry = createRegistry();
  const session = await Harness.open(await SqliteStorage.open(database), { models, registry }, BACKGROUND_CONTEXT);
  const browsers = new BrowserStore(session), executions = new Executions(), attachments = new AttachmentStore(directory);
  const tools = createBrowserTools(browsers, executions, attachments); registry.install(tools);
  const root = await session.root(BACKGROUND_CONTEXT);
  await root.configure({ model: { provider: "openai", modelId: "fixture" }, extensions: [tools] }, BACKGROUND_CONTEXT);
  return { session, browsers, executions, attachments, root, faux };
}

/** A browser host whose open and release succeed and whose screenshot answer the case chooses. */
function browserHost(screenshot: (operation: BrowserRequest) => BrowserResponse | Promise<BrowserResponse>) {
  const effects: BrowserRequest[] = [];
  async function call(command: HostCommand): Promise<HostResult> {
    assert.ok(command.type === "browser" && command.host_id === hostId);
    const operation = command.request; effects.push(operation);
    const tabs = [{ id: 7, title: "Invented color blocks", url: "https://example.com/blocks" }];
    if (operation.action.type === "screenshot") return { type: "browser", response: await screenshot(operation) };
    if (operation.action.type === "release") return { type: "browser", response: { type: "closed", session_id: operation.session_id, tabs: [], output: "Released" } };
    return { type: "browser", response: { type: "ready", session_id: operation.session_id, tabs, output: "Invented page ready", is_error: false } };
  }
  return { effects, call };
}

function captured(operation: BrowserRequest, bytes: Buffer, digest = sha256(bytes), data = bytes.toString("base64")): BrowserResponse {
  return { type: "screenshot", session_id: operation.session_id, tabs: [{ id: 7, title: "Invented color blocks", url: "https://example.com/blocks" }],
    capture: { data_base64: data, sha256: digest } };
}

function screenshotResult(context: TranscriptContext): Extract<Message, { role: "toolResult" }> {
  const result = context.messages.findLast((message) => message.role === "toolResult");
  assert.ok(result?.role === "toolResult" && result.toolName === "browser_screenshot", "The next request follows the screenshot result");
  return result;
}

async function turn(app: Awaited<ReturnType<typeof open>>, observe: (result: Extract<Message, { role: "toolResult" }>) => void) {
  app.faux.setResponses([
    fauxAssistantMessage(fauxToolCall("browser_open", { url: "https://example.com/blocks" }), { stopReason: "toolUse" }),
    fauxAssistantMessage(fauxToolCall("browser_screenshot", { tab_id: 7 }), { stopReason: "toolUse" }),
    (context) => { observe(screenshotResult(context)); return fauxAssistantMessage("The invented page has three color blocks."); },
  ]);
  const settled = await (await app.root.submit({ type: "input", content: "Show me the invented page." }, BACKGROUND_CONTEXT)).wait(BACKGROUND_CONTEXT);
  assert.equal(settled.status, "done");
}

async function screenshotRows(app: Awaited<ReturnType<typeof open>>): Promise<HistoryMessage[]> {
  return (await history(app.root, null, app.session)).flatMap((frame) => frame.messages)
    .filter((message) => message.role === "tool" && message.tool?.name === "browser_screenshot");
}

async function download(attachments: AttachmentStore, id: string): Promise<Buffer> {
  const parts: Buffer[] = [];
  for (let offset: number | null = 0; offset !== null;) {
    const response = await attachments.request({ type: "download", id, offset, limit: ATTACHMENT_CHUNK_BYTES });
    assert.equal(response.type, "download"); if (response.type !== "download") break;
    parts.push(Buffer.from(response.data_base64, "base64")); offset = response.next_offset;
  }
  return Buffer.concat(parts);
}

async function stored(directory: string): Promise<string[]> {
  try { return await readdir(join(directory, "attachments")); }
  catch (error) { if (error instanceof Error && "code" in error && error.code === "ENOENT") return []; throw error; }
}

test("a screenshot reaches the next model request as an image and history as a retained attachment that survives reopen", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-browser-screenshot-"));
  let app = await open(directory);
  const png = capturePng(96, 48);
  const fixture = browserHost((operation) => captured(operation, png));
  let result: Extract<Message, { role: "toolResult" }> | undefined;
  try {
    const unbind = app.executions.bind(app.root.id.toString(), { cwd: host.cwd, hosts: [host], default_host: host, call: fixture.call });
    try { await turn(app, (seen) => { result = seen; }); } finally { unbind(); }
    assert.deepEqual(fixture.effects.map((operation) => operation.action), [
      { type: "open", url: "https://example.com/blocks" }, { type: "screenshot", tab_id: 7, full_page: false }, { type: "release" }]);
    assert.ok(result !== undefined && result.isError !== true, JSON.stringify(result?.content));
    const image = result.content.find((part) => part.type === "image");
    assert.ok(image?.type === "image" && image.mimeType === "image/png", "The model receives the capture as native image content");
    assert.deepEqual(size(Buffer.from(image.data, "base64")), [96, 48]);
    const text = result.content.flatMap((part) => part.type === "text" ? [part.text] : []).join("\n");
    assert.equal(text.includes(png.toString("base64").slice(0, 64)), false, "Image bytes never travel as model text");

    const rows = await screenshotRows(app);
    assert.equal(new Set(rows.map((message) => message.tool?.call_id)).size, 1, "History holds one screenshot call");
    const [row, ...others] = rows.filter((message) => message.tool?.status === "finished");
    assert.ok(row !== undefined && others.length === 0);
    assert.deepEqual(rows.filter((message) => message !== row).flatMap((message) => message.attachments ?? []), [],
      "Only the result row carries the attachment");
    const [attachment, ...extra] = row.attachments ?? [];
    assert.ok(attachment !== undefined && extra.length === 0, "The shared transcript lists the screenshot attachment");
    assert.equal(attachment.media_type, "image/png");
    assert.equal(attachment.size_bytes, png.length);
    assert.equal(attachment.sha256, sha256(png), "The retained digest is the capture's digest");
    assert.match(attachment.name, /\.png$/);
    assert.ok(text.includes(attachment.id), "The model can name the attachment for read_attachment and delegation");
    assert.ok((await download(app.attachments, attachment.id)).equals(png), "The retained bytes are the captured bytes");
    assert.equal(JSON.stringify(await app.browsers.binding(app.root.id.toString())).includes(png.toString("base64").slice(0, 64)), false,
      "The browser connection record keeps no image bytes");

    await app.session.close(BACKGROUND_CONTEXT); app = await open(directory);
    assert.deepEqual((await screenshotRows(app)).flatMap((message) => message.attachments ?? []), [attachment],
      "Reopened history keeps the same attachment");
    assert.ok((await download(app.attachments, attachment.id)).equals(png));
    await assert.rejects(app.attachments.request({ type: "discard", id: attachment.id }), /retained/,
      "History owns the screenshot, so staging expiry cannot remove it");
  } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
});

const png = capturePng(32, 16);
const refusals: { name: string; answer: (operation: BrowserRequest) => BrowserResponse | Promise<BrowserResponse>; connection: "released" | "uncertain" }[] = [
  { name: "bytes that are not a PNG", connection: "released",
    answer: (operation) => captured(operation, Buffer.from("Invented text, not an image")) },
  { name: "a digest that does not match the bytes", connection: "released",
    answer: (operation) => captured(operation, png, sha256(Buffer.from("Another capture"))) },
  { name: "base64 that does not decode exactly", connection: "released",
    answer: (operation) => captured(operation, png, sha256(png), png.toString("base64").slice(0, -4) + "%%%%") },
  { name: "a capture over the screenshot limit", connection: "released",
    answer: (operation) => { const large = Buffer.concat([png, Buffer.alloc(MAX_SCREENSHOT_BYTES + 1 - png.length)]); return captured(operation, large); } },
  { name: "a capture Chrome could not take", connection: "released",
    answer: (operation) => ({ type: "failed", session_id: operation.session_id, message: "Chrome could not capture the invented tab." }) },
  { name: "a capture interrupted before its reply", connection: "uncertain",
    answer: () => { throw new Error("The invented host connection dropped during capture"); } },
];
for (const refusal of refusals) {
  test(`a screenshot with ${refusal.name} reaches neither the model nor the attachment store`, async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-browser-screenshot-refused-"));
    const app = await open(directory);
    const fixture = browserHost(refusal.answer);
    let result: Extract<Message, { role: "toolResult" }> | undefined;
    try {
      const unbind = app.executions.bind(app.root.id.toString(), { cwd: host.cwd, hosts: [host], default_host: host, call: fixture.call });
      try { await turn(app, (seen) => { result = seen; }); } finally { unbind(); }
      assert.ok(result !== undefined);
      assert.ok(fixture.effects.some((operation) => operation.action.type === "screenshot"), "The capture request reached the host");
      assert.equal(result.isError, true);
      assert.equal(result.content.some((part) => part.type === "image"), false, "No unverified image reaches the model");
      assert.deepEqual((await screenshotRows(app)).flatMap((row) => row.attachments ?? []), [], "History lists no attachment");
      assert.deepEqual(await stored(directory), [], "The attachment store holds no bytes");
      assert.equal((await app.browsers.binding(app.root.id.toString()))?.state, refusal.connection,
        "A refused capture keeps the connection for normal cleanup; only a lost reply leaves it uncertain");
    } finally { await app.session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); }
  });
}

/** One run of the production bridge with a synthetic Responses provider and a synthetic browser host. */
class Bridge {
  readonly frames: RuntimeEvent[] = [];
  private readonly changes = new Set<() => void>();
  private readonly closed: Promise<number | null>;
  private readonly reader: Promise<void>;
  private errors = "";
  private readonly child: ChildProcessWithoutNullStreams;
  constructor(directory: string, queue: string, answer: (command: HostCommand) => HostResult) {
    const child = spawn(process.execPath, ["--no-warnings", fileURLToPath(new URL("./fixtures/coordinator-runtime.js", import.meta.url)), directory],
      { stdio: ["pipe", "pipe", "pipe"], env: { ...process.env, OPENAI_API_KEY: "sk-synthetic-fixture", AGENT_TEST_MODEL_QUEUE: queue } });
    this.child = child;
    this.closed = new Promise((resolve, reject) => { child.once("close", resolve); child.once("error", reject); });
    child.stderr.setEncoding("utf8").on("data", (value: string) => { this.errors += value; });
    this.reader = (async () => {
      for await (const line of protocolLines(child.stdout)) {
        const frame: unknown = JSON.parse(line);
        assert.ok(validEvent(frame), "Every bridge event passes the generated event contract");
        this.frames.push(frame); for (const changed of this.changes) changed();
        if (frame.event.type !== "host_call") continue;
        let command = frame.event.command; while (command.type === "on_node") command = command.command;
        this.send(frame.id, { type: "host_reply", call_id: frame.event.call_id, result: answer(command) });
      }
    })();
    void this.reader.catch(() => {});
  }
  send(id: number, command: RuntimeCommand): void { this.child.stdin.write(JSON.stringify({ version: 1, id, command }) + "\n"); }
  async exchange(id: number, command: RuntimeCommand): Promise<RuntimeEvent["event"][]> {
    this.send(id, command);
    await Promise.race([
      new Promise<void>((resolve) => {
        const check = () => { if (this.frames.some((frame) => frame.id === id && frame.event.type === "done")) { this.changes.delete(check); resolve(); } };
        this.changes.add(check); check();
      }),
      this.closed.then(() => { throw new Error("The bridge exited before its reply: " + this.errors); }),
    ]);
    const events = this.frames.filter((frame) => frame.id === id).map((frame) => frame.event);
    const failure = events.find((event) => event.type === "failure");
    assert.equal(failure, undefined, JSON.stringify(failure));
    return events;
  }
  async configure(id: number): Promise<void> {
    await this.exchange(id, { type: "configure_coordinator", bootstrap: { node: { host_id: hostId, name: "fixture", home_directory: "/example",
      agent_program: "/example/agent", rex_server: null, coordinator: null,
      launch: { model: null, state_dir: null, runtime: null, config: null, instructions: null } },
      settings: { model: DEFAULT_MODEL, instructions: "", context_repositories: [], sources: [] } } });
    await this.exchange(id + 1, { type: "set_connected_nodes", host_ids: [hostId] });
  }
  async screenshots(id: number): Promise<AttachmentRef[]> {
    const events = await this.exchange(id, { type: "read_history", task_id: null, agent_id: null, cursor: null });
    return events.flatMap((event) => event.type === "history" ? event.messages : [])
      .filter((message) => message.tool?.name === "browser_screenshot").flatMap((message) => message.attachments ?? []);
  }
  async download(id: number, attachment: string): Promise<Buffer> {
    const parts: Buffer[] = [];
    for (let offset: number | null = 0, request = id; offset !== null; request++) {
      const events = await this.exchange(request, { type: "attachment", request: { type: "download", id: attachment, offset, limit: ATTACHMENT_CHUNK_BYTES } });
      const reply = events.find((event) => event.type === "attachment");
      assert.ok(reply?.type === "attachment" && reply.response.type === "download");
      parts.push(Buffer.from(reply.response.data_base64, "base64")); offset = reply.response.next_offset;
    }
    return Buffer.concat(parts);
  }
  async stop(): Promise<void> {
    this.child.stdin.end(); assert.equal(await this.closed, 0, this.errors); await this.reader;
  }
  kill(): void { this.child.kill(); }
}

test("the production bridge sends a screenshot to the Responses provider as an image and keeps its attachment across a coordinator restart", { timeout: 20_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-browser-screenshot-bridge-")), queue = join(directory, "responses.json");
  await writeFile(queue, JSON.stringify({ "screenshot-wire": [
    { tool: "tool_search", args: { query: "browser open" } },
    { tool: "browser_open", args: { url: "https://example.com/blocks" } },
    { tool: "browser_screenshot", args: { tab_id: 7 } },
    { tool: "browser_release", args: {} },
    { text: "The invented page has three color blocks." },
  ] }));
  const capture = capturePng(120, 60);
  const answer = (command: HostCommand): HostResult => {
    if (command.type === "browser") {
      const operation = command.request;
      if (operation.action.type === "screenshot") return { type: "browser", response: captured(operation, capture) };
      if (operation.action.type === "release") return { type: "browser", response: { type: "closed", session_id: operation.session_id, tabs: [], output: "Released" } };
      return { type: "browser", response: { type: "ready", session_id: operation.session_id,
        tabs: [{ id: 7, title: "Invented color blocks", url: "https://example.com/blocks" }], output: "Invented page ready", is_error: false } };
    }
    if (command.type === "reload_guidance") return { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] };
    if (command.type === "project_guidance") return { type: "project_guidance", snapshot: { text: "", sources: [] } };
    return { type: "failed", message: "Synthetic retrieval disabled" };
  };
  let bridge = new Bridge(directory, queue, answer);
  try {
    await bridge.configure(1);
    await bridge.exchange(3, { type: "chat", input: "screenshot-wire", instructions: "", model: null, origin_host_id: hostId, cwd: host.cwd, hosts: [host] });
    const requests = (await readFile(queue + ".requests", "utf8")).trim().split("\n").map((line): unknown => JSON.parse(line));
    const images = requests.flatMap((request) => {
      if (typeof request !== "object" || request === null || !("body" in request)) return [];
      const body = request.body;
      if (typeof body !== "object" || body === null || !("input" in body) || !Array.isArray(body.input)) return [];
      return body.input.flatMap((item: unknown) => typeof item === "object" && item !== null && "type" in item && item.type === "function_call_output"
        && "output" in item && Array.isArray(item.output) ? item.output : [])
        .flatMap((part: unknown) => typeof part === "object" && part !== null && "type" in part && part.type === "input_image"
          && "image_url" in part && typeof part.image_url === "string" ? [part.image_url] : []);
    });
    const [first] = images;
    assert.ok(first !== undefined, "A later Responses request carries the screenshot as an input image");
    assert.match(first, /^data:image\/png;base64,/);
    assert.deepEqual(size(Buffer.from(first.slice("data:image/png;base64,".length), "base64")), [120, 60]);

    const [attachment, ...extra] = await bridge.screenshots(5);
    assert.ok(attachment !== undefined && extra.length === 0, "read_history lists the screenshot attachment on its tool row");
    assert.equal(attachment.sha256, sha256(capture));
    assert.ok((await bridge.download(6, attachment.id)).equals(capture));
    await bridge.stop();

    bridge = new Bridge(directory, queue, answer);
    await bridge.configure(1);
    assert.deepEqual(await bridge.screenshots(3), [attachment], "A restarted coordinator lists the same attachment");
    assert.ok((await bridge.download(4, attachment.id)).equals(capture), "A restarted coordinator serves the same bytes");
    await bridge.stop();
  } finally { bridge.kill(); await rm(directory, { recursive: true, force: true }); }
});
