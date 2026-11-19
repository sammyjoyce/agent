import assert from "node:assert/strict";
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import http2 from "node:http2";
import { syncBuiltinESMExports } from "node:module";
import type { JsonObject } from "@earendil-works/pi-ai";
import type { FailoverSession } from "../../src/generated/FailoverSession.js";

/** A `text` step with `after` answers once the file `after` exists. */
export type ModelStep = { text: string; after?: string } | { tool: string; args: JsonObject; commentary?: string } |
  { code: string; commentary?: string } | { hold_and_write_pid: string } | { stream: string[]; interval_ms: number };
export type ModelQueue = Record<string, ModelStep[]>;
type ResponseItem = { id: string; type: "message"; role: "assistant"; status: "completed"; phase?: "commentary";
  content: [{ type: "output_text"; text: string; annotations: [] }] } |
  { id: string; type: "function_call"; call_id: string; name: string; arguments: string; status: "completed" } |
  { id: string; type: "custom_tool_call"; call_id: string; name: string; input: string; status: "completed" };
function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
function codemodeCall(id: string, code: string, codemode: unknown): ResponseItem {
  return codemode === "custom" ? { id, type: "custom_tool_call", call_id: id, name: "codemode", input: code, status: "completed" }
    : { id, type: "function_call", call_id: id, name: "codemode", arguments: JSON.stringify({ code }), status: "completed" };
}

// A replicated coordinator also reaches its authority, which a test runs on loopback.
const authority = process.env.AGENT_FAILOVER === undefined ? undefined : new URL((JSON.parse(process.env.AGENT_FAILOVER) as FailoverSession).url);
assert.ok(authority === undefined || authority.hostname === "127.0.0.1", "The fixture's authority must be on loopback");
const network = globalThis.fetch;

// A test with a local APNs origin redirects only Apple's address. Signing, the dispatcher and the HTTP/2 client run unchanged.
const apnsOrigin = process.env.AGENT_TEST_APNS_ORIGIN;
if (apnsOrigin !== undefined) {
  const connect = http2.connect;
  http2.connect = ((authority: string | URL, ...rest: unknown[]) => {
    assert.equal(String(authority), "https://api.sandbox.push.apple.com", "The fixture must never contact an external service");
    return (connect as (...args: unknown[]) => http2.ClientHttp2Session)(apnsOrigin, ...rest);
  }) as typeof http2.connect;
  syncBuiltinESMExports();
}

// Only the external provider is synthetic. Pi, application tools and the bridge
// are imported unchanged and consume actual Responses API event frames.
globalThis.fetch = async (input, options) => {
  const url = input instanceof Request ? input.url : input.toString();
  if (authority !== undefined && new URL(url).origin === authority.origin) return network(input, options);
  assert.equal(url, "https://api.openai.com/v1/responses", "The fixture must never contact an external service");
  assert.equal(typeof options?.body, "string");
  const body: unknown = JSON.parse(String(options?.body));
  assert.ok(object(body) && Array.isArray(body.input));
  const user: unknown = [...body.input].reverse().find((item: unknown) => object(item) && item.role === "user");
  assert.ok(object(user));
  const text = typeof user.content === "string" ? user.content : Array.isArray(user.content)
    ? user.content.flatMap((part: unknown) => object(part) && typeof part.text === "string" ? [part.text] : []).join("\n") : "";
  const path = process.env.AGENT_TEST_MODEL_QUEUE; assert.ok(path);
  const queue: unknown = JSON.parse(readFileSync(path, "utf8")); assert.ok(object(queue));
  const key = Object.keys(queue).find((key) => text.includes(key)); assert.ok(key, `Unexpected synthetic input: ${text}`);
  const steps = queue[key]; assert.ok(Array.isArray(steps) && steps.length > 0);
  const step: unknown = steps.shift(); assert.ok(object(step));
  writeFileSync(path, JSON.stringify(queue));
  appendFileSync(path + ".requests", JSON.stringify({ key, body }) + "\n");
  if (typeof step.hold_and_write_pid === "string") {
    writeFileSync(step.hold_and_write_pid, String(process.pid));
    const signal = options?.signal;
    return new Promise<Response>((_resolve, reject) => signal?.addEventListener("abort", () => reject(signal.reason), { once: true }));
  }
  if (typeof step.after === "string") {
    while (!existsSync(step.after)) {
      options?.signal?.throwIfAborted();
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
  const id = randomUUID();
  let item: ResponseItem;
  const updates = body.input.flatMap((item: unknown) => object(item) && item.type === "additional_tools" && Array.isArray(item.tools) ? item.tools : []);
  const declared = new Map([...(Array.isArray(body.tools) ? body.tools : []), ...updates].flatMap((tool: unknown) =>
    object(tool) && typeof tool.name === "string" ? [[tool.name, tool.type] as const] : []));
  const codemode = declared.get("codemode");
  const chunks = Array.isArray(step.stream) ? step.stream.map((chunk: unknown) => { assert.equal(typeof chunk, "string"); return String(chunk); }) : undefined;
  const answer = chunks?.join("") ?? step.text;
  if (typeof answer === "string") item = { id, type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: answer, annotations: [] }] };
  else if (typeof step.code === "string") {
    assert.ok(codemode !== undefined, "A scripted program needs the codemode tool");
    item = codemodeCall(id, step.code, codemode);
  } else {
    assert.ok(typeof step.tool === "string" && object(step.args));
    item = !declared.has(step.tool) && codemode !== undefined ? codemodeCall(id, `return await tools.${step.tool}(${JSON.stringify(step.args)});`, codemode)
      : { id, type: "function_call", call_id: id, name: step.tool, arguments: JSON.stringify(step.args), status: "completed" };
  }
  const items: ResponseItem[] = typeof step.commentary === "string" && item.type !== "message" ? [
    { id: randomUUID(), type: "message", role: "assistant", status: "completed", phase: "commentary", content: [{ type: "output_text", text: step.commentary, annotations: [] }] }, item,
  ] : [item];
  const response = { id: randomUUID(), object: "response", created_at: 1, model: "gpt-6.1-sol" };
  const events = [
    { type: "response.created", response: { ...response, status: "in_progress", output: [] } },
    ...items.flatMap((item, output_index) => [
      { type: "response.output_item.added", output_index, item: { ...item, status: "in_progress",
        ...(item.type === "message" ? { content: [] } : item.type === "custom_tool_call" ? { input: "" } : { arguments: "" }) } },
      ...(item.type === "message" ? [
        { type: "response.content_part.added", item_id: item.id, output_index, content_index: 0, part: { type: "output_text", text: "", annotations: [] } },
        ...(chunks ?? [item.content[0].text]).map((delta) => ({ type: "response.output_text.delta", item_id: item.id, output_index, content_index: 0, delta })),
        { type: "response.output_text.done", item_id: item.id, output_index, content_index: 0, text: item.content[0].text },
      ] : item.type === "custom_tool_call" ? [
        { type: "response.custom_tool_call_input.delta", item_id: item.id, output_index, delta: item.input },
        { type: "response.custom_tool_call_input.done", item_id: item.id, output_index, input: item.input },
      ] : [
        { type: "response.function_call_arguments.delta", item_id: item.id, output_index, delta: item.arguments },
        { type: "response.function_call_arguments.done", item_id: item.id, output_index, arguments: item.arguments },
      ]),
      { type: "response.output_item.done", output_index, item },
    ]),
    { type: "response.completed", response: { ...response, status: "completed", output: items, usage: {
      input_tokens: 1, output_tokens: 1, total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 },
    } } },
  ];
  const headers = { "content-type": "text/event-stream" };
  if (chunks === undefined) return new Response(events.map((event) => "data: " + JSON.stringify(event) + "\n\n").join(""), { headers });
  // A streamed step sends each text delta interval_ms after the one before, as a model streams its answer.
  const interval = Number(step.interval_ms), encoder = new TextEncoder();
  return new Response(new ReadableStream({ async start(controller) {
    for (const event of events) {
      if (event.type === "response.output_text.delta") await new Promise((resolve) => setTimeout(resolve, interval));
      controller.enqueue(encoder.encode("data: " + JSON.stringify(event) + "\n\n"));
    }
    controller.close();
  } }), { headers });
};
await import("../../src/bridge.js");
