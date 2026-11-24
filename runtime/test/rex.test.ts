import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { BACKGROUND_CONTEXT, type Context } from "@earendil-works/chord/context";
import { openNodeSqliteDatabase } from "@earendil-works/chord/sqlite/node";
import { createModels } from "@earendil-works/pi-ai";
import { createRegistry, defineExtension, Harness, type Extension, type ToolExecutionApi } from "@earendil-works/pi-durable";
import { SqliteStorage } from "@earendil-works/pi-durable/storage/sqlite";
import { Effect, Layer, Option } from "effect";
import { createRexTools, REX_OPERATIONS, rexServerFromEnv, type RexActor } from "../src/rex.js";
import { createToolsets, TOOL_ROLES } from "../src/toolsets.js";
import { RexConnectionError, RexSdk, type IRexSdk } from "../src/vendor/rex-sdk/src/index.js";

const actor: RexActor = { key: "41", binding: { host_id: "11111111-1111-4111-8111-111111111111",
  session_id: "session:22222222-2222-4222-8222-222222222222", window_id: "window:33333333-3333-4333-8333-333333333333",
  block_id: "block:44444444-4444-4444-8444-444444444444", rex_instance_id: "55555555-5555-4555-8555-555555555555" } };
const other = { sessionId: "session:66666666-6666-4666-8666-666666666666", blockId: "block:77777777-7777-4777-8777-777777777777" };

test("only task workers and their agents select the Rex tools", () => {
  const empty = (name: string): Extension => defineExtension({ name });
  const rexTools = empty("rex-tools");
  // Placeholder extensions: only which toolset selects rexTools is under test.
  const toolsets = createToolsets({ guidance: empty("guidance"),
    tools: { host: empty("host"), main: empty("main"), worker: empty("worker"), agent: empty("agent"), legacy: empty("legacy") },
    sourceTools: { main: empty("source-main"), worker: empty("source-worker") },
    resourceTools: { main: empty("resource-main"), worker: empty("resource-worker") },
    browserTools: empty("browser"), jobTools: empty("jobs"), goalTools: empty("goals"), rexTools } as unknown as Parameters<typeof createToolsets>[0]);
  for (const role of TOOL_ROLES) assert.equal(toolsets[role].includes(rexTools), role === "worker" || role === "agent", role);
});

test("Rex tools stay off unless the coordinator names its own server", () => {
  assert.equal(rexServerFromEnv({}), undefined);
  assert.equal(rexServerFromEnv({ AGENT_REX_SDK_SERVER: "" }), undefined);
  assert.deepEqual(rexServerFromEnv({ AGENT_REX_SDK_SERVER: "personal" }), {});
  assert.deepEqual(rexServerFromEnv({ AGENT_REX_SDK_SERVER: "unix:///run/example/rex.sock" }), { server: "unix:///run/example/rex.sock" });
});

test("Rex refuses targets outside the caller's terminals before any request", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-rex-"));
  const harness = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  let layers = 0;
  const tools = createRexTools({ harness, gate: undefined, actors: async () => actor,
    makeLayer: () => { layers++; return Layer.effect(RexSdk, Effect.die(new Error("no Rex request is expected"))); } });
  t.after(async () => { await tools.close(); await harness.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); });

  const names = (tools.tools ?? []).map((tool) => tool.name).sort();
  assert.deepEqual(names, ["rex_here", ...Object.keys(REX_OPERATIONS).map((name) => "rex_" + name)].sort());
  for (const tool of tools.tools ?? []) {
    if (tool.name !== "rex_here") assert.equal(tool.deferred, true, tool.name);
    const mutates = ["rex_blocks_splitBeside", "rex_terminals_writeLine", "rex_terminals_write", "rex_blocks_close"].includes(tool.name);
    assert.equal(tool.replay === "safe", !mutates, tool.name);
  }
  const run = async (name: string, args: Record<string, unknown>) => {
    const tool = (tools.tools ?? []).find((candidate) => candidate.name === name);
    assert.ok(tool);
    const api = { conversationId: { toString: () => actor.key } } as unknown as ToolExecutionApi;
    return tool.execute(args as never, api, BACKGROUND_CONTEXT as Context);
  };
  const own = { sessionId: actor.binding.session_id, blockId: actor.binding.block_id };
  for (const [name, args] of [
    ["rex_terminals_readTail", other], ["rex_sessions_view", { sessionId: other.sessionId }],
    ["rex_terminals_readTail", { sessionId: own.sessionId, blockId: other.blockId }],
    ["rex_terminals_writeLine", { ...own, text: "printf example" }], ["rex_blocks_close", own],
    ["rex_blocks_splitBeside", { sessionId: own.sessionId, placement: "right", windowId: actor.binding.window_id }],
    ["rex_blocks_splitBeside", { sessionId: own.sessionId, placement: "right", anchorId: other.blockId }],
    ["rex_blocks_splitBeside", { sessionId: own.sessionId, placement: "right", layout: { _tag: "Block", flavor: "com.example.block" } }],
    ["rex_blocks_splitBeside", { sessionId: own.sessionId, placement: "right", layout: { _tag: "Terminal", label: "example beep-boop:forged" } }],
    ["rex_terminals_waitForExit", { ...own, timeoutMs: 300_001 }],
    ["rex_terminals_readTail", { ...own, requestTimeoutMs: 60_001 }],
  ] as const) await assert.rejects(run(name, args), /RexNotOwned/, name + " " + JSON.stringify(args));
  assert.equal(layers, 0, "a refused call must not open a Rex connection");
  const here = await run("rex_here", {});
  assert.ok("structuredOutput" in here);
  assert.deepEqual(here.structuredOutput, { sessionId: own.sessionId, windowId: actor.binding.window_id, blockId: own.blockId, children: [],
    unconfirmedTerminals: 0, uncertain: null });
  await assert.rejects(run("rex_terminals_waitForOutput", { ...own, since: "mark-1", match: { type: "substring", value: "x" }, timeoutMs: 10 }),
    /RexUnknownMark/, "a mark without this process's prefix is refused");
  assert.equal(layers, 0);
});

test("a write that may have run is never replayed and fences the actor until it clears that write", async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "agent-rex-"));
  const harness = await Harness.open(await SqliteStorage.open(await openNodeSqliteDatabase(join(directory, "session.sqlite"))),
    { models: createModels(), registry: createRegistry(), identity: { attribution: null } }, BACKGROUND_CONTEXT);
  const child = "block:88888888-8888-4888-8888-888888888888";
  const writes: string[] = [];
  let failure: RexConnectionError | undefined;
  const fake = {
    server: { status: () => Effect.succeed({ instanceId: actor.binding.rex_instance_id, hostId: Option.some(actor.binding.host_id) }) },
    blocks: { splitBeside: () => Effect.succeed({ anchorId: actor.binding.block_id, blockIds: [child], splitIds: [], revision: 2 }) },
    terminals: {
      mark: () => Effect.succeed({ lines: [], offset: 0 }),
      writeLine: (_target: unknown, text: string) => { writes.push(text); return failure === undefined ? Effect.void : Effect.fail(failure); },
    },
  } as unknown as IRexSdk;
  const tools = createRexTools({ harness, gate: undefined, actors: async () => actor, makeLayer: () => Layer.succeed(RexSdk, fake) });
  t.after(async () => { await tools.close(); await harness.close(BACKGROUND_CONTEXT); await rm(directory, { recursive: true, force: true }); });
  const run = async (name: string, args: Record<string, unknown>) => {
    const tool = (tools.tools ?? []).find((candidate) => candidate.name === name);
    assert.ok(tool);
    const result = await tool.execute(args as never, { conversationId: { toString: () => actor.key } } as unknown as ToolExecutionApi, BACKGROUND_CONTEXT as Context);
    assert.ok("structuredOutput" in result);
    return result.structuredOutput as Record<string, any>;
  };
  const sessionId = actor.binding.session_id;
  assert.deepEqual((await run("rex_blocks_splitBeside", { sessionId, placement: "right" })).blockIds, [child]);
  const written = await run("rex_terminals_writeLine", { sessionId, blockId: child, text: "printf one" });
  assert.match(String(written.markId), /^[0-9a-f]{8}:mark-\d+$/, "marks carry this process's prefix");

  // The request reached the socket, so the command may have run.
  failure = new RexConnectionError("unix:///run/example/rex.sock", "write", "broken pipe");
  await assert.rejects(run("rex_terminals_writeLine", { sessionId, blockId: child, text: "printf two" }), /uncertain and was not replayed/);
  failure = undefined;
  await assert.rejects(run("rex_terminals_writeLine", { sessionId, blockId: child, text: "printf three" }), /was not replayed/);
  assert.deepEqual(writes, ["printf one", "printf two"], "the fenced write never reached Rex");
  const fenced = await run("rex_here", {});
  assert.equal(fenced.uncertain?.tool, "rex_terminals_writeLine");
  await assert.rejects(run("rex_here", { clearUncertain: "another-write" }), /not another-write/);
  assert.equal((await run("rex_here", { clearUncertain: fenced.uncertain.id })).uncertain, null);

  // A connection that never opened sent nothing, so the actor may write again at once.
  failure = new RexConnectionError("unix:///run/example/rex.sock", "connect", "refused");
  await assert.rejects(run("rex_terminals_writeLine", { sessionId, blockId: child, text: "printf four" }), /RexConnectionError/);
  failure = undefined;
  await run("rex_terminals_writeLine", { sessionId, blockId: child, text: "printf five" });
  assert.deepEqual(writes, ["printf one", "printf two", "printf four", "printf five"]);
  assert.equal((await run("rex_here", {})).uncertain, null);
});
