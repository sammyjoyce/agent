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
import { CoordinatorEnvironment } from "../src/environment.js";
import type { HostCommand } from "../src/generated/HostCommand.js";
import type { HostResult } from "../src/generated/HostResult.js";
import type { ModelSelection } from "../src/generated/ModelSelection.js";
import type { WorkerHost } from "../src/generated/WorkerHost.js";
import { IMAGE_CHUNK_BYTES, MAX_IMAGE_READ_BYTES } from "../src/generated/image-read-limits.js";
import { createGuidance } from "../src/guidance.js";
import { readImageFile, type ReadFileCommand } from "../src/images.js";
import { ConversationModels } from "../src/models.js";
import { createSourceTools, SourceJournal } from "../src/sources.js";
import { TaskStore } from "../src/tasks.js";
import { createAppTools, Executions, HostRequests } from "../src/tools.js";
import { runAdmitted } from "./fixtures/run-admitted.js";

function storedPng(width: number, height: number): Buffer {
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
  const wide = storedPng(1200, 400), fixture = host({ "/fixture/wide.png": wide, "/fixture/changing.png": wide }, new Set(["/fixture/changing.png"]));
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

test("triage and child agents read chunked images from a second machine through on_node", { timeout: 30_000 }, async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-read-file-remote-"));
  const registry = createRegistry(), models = createModels(), executions = new Executions();
  const modelRef = { provider: "openai", modelId: "narrow" } as const;
  const faux = fauxProvider({ provider: "openai", tokensPerSecond: 1_000_000,
    models: [{ id: "narrow", input: ["text", "image"], inputLimits: { images: { resize: { maxWidth: 800 } } } }] });
  models.setProvider(faux.provider);
  const session = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models, registry, identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const inference = new ConversationModels(models);
  const environment = new CoordinatorEnvironment(session);
  const tasks = new TaskStore(session, inference);
  const sources = new SourceJournal(session, tasks, executions);
  await sources.prepare();
  const tools = createAppTools(tasks, executions), sourceTools = createSourceTools(sources, executions), guidance = createGuidance(executions);
  registry.install(guidance); registry.install(tools.host); registry.install(tools.main); registry.install(tools.agent);
  registry.install(sourceTools.main);

  const modelSelection: ModelSelection = { provider: "openai", model_id: "narrow", reasoning: null, fast: false };
  const launch = { state_dir: null, runtime: null, config: null, instructions: null, model: null };
  const remoteHost: WorkerHost = { name: "second-host", host_id: "22222222-2222-4222-8222-222222222222",
    rex_server: null, coordinator: null, cwd: "/remote/work", agent_program: "/bin/agent" };
  await environment.configure({
    node: { host_id: "11111111-1111-4111-8111-111111111111", name: "local-host", rex_server: null, coordinator: null,
      home_directory: "/local", agent_program: "/bin/agent", launch },
    settings: { model: modelSelection, instructions: "Use invented remote fixtures.", context_repositories: [], sources: [] },
  });
  await environment.register({ host_id: remoteHost.host_id!, name: remoteHost.name, rex_server: null, coordinator: null,
    home_directory: "/remote", agent_program: "/bin/agent", launch });
  environment.setConnected([remoteHost.host_id!]);

  const wide = storedPng(1200, 400);
  assert.ok(wide.length > IMAGE_CHUNK_BYTES, "Fixture spans multiple chunks");
  const fixture = host({ "/remote/work/triage-shot.png": wide, "/remote/work/child-shot.png": wide }, new Set());
  const forwarded: Array<{ role: string; command: HostCommand }> = [];
  const routedCall = (role: string) => async (command: HostCommand): Promise<HostResult> => {
    forwarded.push({ role, command });
    if (command.type === "reload_guidance") {
      return { type: "shared_guidance", global: { text: "", sources: [] }, workflow_policy: "", context_repositories: [], context_sources: [] };
    }
    if (command.type === "project_guidance") return { type: "project_guidance", snapshot: { text: "", sources: [] } };
    if (command.type === "spawn_worker" || command.type === "spawn_workspace_worker") {
      return {
        type: "spawned",
        binding: {
          host_id: remoteHost.host_id!,
          session_id: "session:33333333-3333-4333-8333-333333333333",
          window_id: "window:44444444-4444-4444-8444-444444444444",
          block_id: "block:55555555-5555-4555-8555-555555555555",
        },
      };
    }
    if (command.type === "on_node") {
      assert.equal(command.host_id, remoteHost.host_id);
      if (command.command.type === "inspect_worker") {
        return { type: "worker_presence", presence: { state: "present", running: true } };
      }
      return fixture.call(command.command);
    }
    return fixture.call(command);
  };

  try {
    await sources.admit({
      source: { provider: "mail", account: "example" },
      checkpoint: null,
      coverage: { status: "complete" },
      events: [{ id: "evt-1", version: "v1", source: { provider: "mail", account: "example", thread_id: "thr-1" }, title: "Inspect", text: "Check shot" }],
    }, null);
    const pendingEvent = (await sources.events({ pending: true }))[0];
    assert.ok(pendingEvent !== undefined);

    const triageSeen: Extract<Message, { role: "toolResult" }>[] = [];
    faux.setResponses([
      fauxAssistantMessage(fauxToolCall("read_file", { path: "triage-shot.png" }), { stopReason: "toolUse" }),
      (context) => {
        triageSeen.push(toolResult(context));
        return fauxAssistantMessage(fauxToolCall("dismiss_source_events", { keys: [pendingEvent.key], reason: "Reviewed remote image." }), { stopReason: "toolUse" });
      },
      fauxAssistantMessage("Triage finished."),
    ]);
    await sources.triage(
      { type: "triage_sources", instructions: "Review.", model: modelSelection, cwd: remoteHost.cwd, hosts: [remoteHost] },
      (conversation, model) => executions.bind(conversation.id.toString(), {
        model, cwd: remoteHost.cwd, hosts: [remoteHost], default_host: remoteHost,
        connectedHosts: async () => [remoteHost], role: "triage",
        call: (operation) => routedCall("triage")(environment.route(operation, remoteHost)),
      }),
      [guidance, tools.host, tools.main, sourceTools.main],
    );
    assert.equal(triageSeen.length, 1);
    const triageImage = triageSeen[0]!.content.find((part) => part.type === "image");
    assert.ok(triageImage?.type === "image" && triageImage.mimeType === "image/png");
    assert.equal(Buffer.from(triageImage.data, "base64").readUInt32BE(16), 800);

    tasks.useActorExecution({
      available: () => true,
      extensions: (agentId) => agentId === undefined ? [guidance, tools.host, tools.agent] : [guidance, tools.host, tools.agent],
      call: (operation, node) => routedCall("actor")(environment.route(operation, node)),
      prepare: async () => {},
      bind: (conversation, node, model) => executions.bind(conversation.id.toString(), {
        model, cwd: node.cwd, hosts: [node], default_host: node, origin_host_id: node.host_id,
        connectedHosts: async () => [node], role: "worker",
        call: (operation) => routedCall("child-agent")(environment.route(operation, node)),
      }),
    });
    const task = await tasks.create({ title: "Remote inspection", outcome: "Read remote child image", model: modelSelection });
    await tasks.dispatch(task.id, remoteHost, routedCall("dispatch"));
    const child = await tasks.createAgent(task.id, { id: "remote-child", title: "Child reader", outcome: "Read child-shot.png", input: "Read child-shot.png", inputId: "child-in-1" });
    const childSeen: Extract<Message, { role: "toolResult" }>[] = [];
    faux.setResponses([
      fauxAssistantMessage(fauxToolCall("read_file", { path: "child-shot.png" }), { stopReason: "toolUse" }),
      (context) => {
        childSeen.push(toolResult(context));
        return fauxAssistantMessage(fauxToolCall("report_result", { summary: "Inspected remote image." }), { stopReason: "toolUse" });
      },
      fauxAssistantMessage("Child finished."),
    ]);
    await runAdmitted(tasks, task.id, child.id);
    assert.equal(childSeen.length, 1);
    const childImage = childSeen[0]!.content.find((part) => part.type === "image");
    assert.ok(childImage?.type === "image" && childImage.mimeType === "image/png");
    assert.equal(Buffer.from(childImage.data, "base64").readUInt32BE(16), 800);

    const onNodeReads = forwarded
      .filter((entry): entry is { role: string; command: Extract<HostCommand, { type: "on_node" }> } =>
        entry.command.type === "on_node" && entry.command.command.type === "read_file")
      .map((entry) => {
        const read = entry.command.command as ReadFileCommand;
        return [entry.role, entry.command.host_id, read.path, read.image];
      });
    assert.deepEqual(onNodeReads, [
      ["triage", remoteHost.host_id, "/remote/work/triage-shot.png", { type: "start" }],
      ["triage", remoteHost.host_id, "/remote/work/triage-shot.png", { type: "next", at: IMAGE_CHUNK_BYTES, stamp: "version-1" }],
      ["child-agent", remoteHost.host_id, "/remote/work/child-shot.png", { type: "start" }],
      ["child-agent", remoteHost.host_id, "/remote/work/child-shot.png", { type: "next", at: IMAGE_CHUNK_BYTES, stamp: "version-1" }],
    ]);
  } finally {
    await session.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true });
  }
});

test("cancelling a slow chunked image transfer aborts without hanging or breaking later reads", { timeout: 10_000 }, async () => {
  const png = storedPng(1200, 400);
  assert.ok(png.length > IMAGE_CHUNK_BYTES, "Fixture spans two chunks");
  const backing = host({ "/fixture/slow.png": png }, new Set());
  const emitted: Array<{ request: number; call: string; command: HostCommand }> = [];
  const cancelled: Array<{ request: number; call: string }> = [];
  let stallNext = true;

  const hostRequests = new HostRequests(
    (request, call, command) => {
      emitted.push({ request, call, command });
      if (command.type === "on_node" && command.command.type === "read_file" &&
          command.command.image?.type === "next" && stallNext) {
        return; // Simulate a slow second chunk stuck on the remote host.
      }
      void backing.call(command.type === "on_node" ? command.command : command).then((reply) => hostRequests.reply(request, call, reply));
    },
    (request, call) => cancelled.push({ request, call }),
  );

  const command: ReadFileCommand = { type: "read_file", path: "/fixture/slow.png", offset: 0, limit: 64_000, image: { type: "start" } };
  const route = (op: HostCommand): HostCommand => ({ type: "on_node", host_id: "22222222-2222-4222-8222-222222222222", command: op });
  const input = { vision: true, limits: { maxWidth: 800, maxHeight: 800, maxBytes: 4_000_000 } };

  const startedAt = Date.now();
  const first = await hostRequests.call(1, route(command));
  assert.equal(first.type, "image_chunk");
  const readPromise = readImageFile((next) => hostRequests.call(1, route(next)), command, first, input);
  await new Promise<void>((resolve) => setTimeout(resolve, 15));
  assert.equal(emitted.length, 2, "Second chunk is in flight before cancellation");

  hostRequests.cancelRequest(1);
  await assert.rejects(readPromise, /File read was interrupted/);
  assert.ok(Date.now() - startedAt < 2_000, "Cancelling a slow read releases immediately instead of waiting for host timeout");
  assert.deepEqual(cancelled, [{ request: 1, call: emitted[1]!.call }]);

  const controller = new AbortController();
  const second = await hostRequests.call(2, route(command), controller.signal);
  assert.equal(second.type, "image_chunk");
  const abortedRead = readImageFile((next) => hostRequests.call(2, route(next), controller.signal), command, second, input);
  await new Promise<void>((resolve) => setTimeout(resolve, 15));
  controller.abort();
  await assert.rejects(abortedRead, /File read was interrupted/);
  assert.equal(cancelled.length, 2);

  hostRequests.resumeRequest(1);
  stallNext = false;
  const recoveredFirst = await hostRequests.call(1, route(command));
  assert.equal(recoveredFirst.type, "image_chunk");
  const recovered = await readImageFile((next) => hostRequests.call(1, route(next)), command, recoveredFirst, input);
  assert.equal(recovered.isError, undefined);
  const image = recovered.output?.find((part) => part.type === "image");
  assert.ok(image?.type === "image" && image.mimeType === "image/png");
});
