import assert from "node:assert/strict";
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import type { JsonObject } from "@earendil-works/pi-ai";
import type { FailoverSession } from "../../src/generated/FailoverSession.js";

export type ModelStep = { text: string } | { tool: string; args: JsonObject; commentary?: string };
export type ModelQueue = Record<string, ModelStep[]>;
type ResponseItem = { id: string; type: "message"; role: "assistant"; status: "completed"; phase?: "commentary";
  content: [{ type: "output_text"; text: string; annotations: [] }] } |
  { id: string; type: "function_call"; call_id: string; name: string; arguments: string; status: "completed" } |
  { id: string; type: "custom_tool_call"; call_id: string; name: string; input: string; status: "completed" };
function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
function oneCallScript(id: string, tool: string, args: object, codemode: unknown): ResponseItem {
  const code = `return await tools.${tool}(${JSON.stringify(args)});`;
  return codemode === "custom" ? { id, type: "custom_tool_call", call_id: id, name: "codemode", input: code, status: "completed" }
    : { id, type: "function_call", call_id: id, name: "codemode", arguments: JSON.stringify({ code }), status: "completed" };
}

// A replicated coordinator also reaches its authority, which a test runs on loopback.
const authority = process.env.AGENT_FAILOVER === undefined ? undefined : new URL((JSON.parse(process.env.AGENT_FAILOVER) as FailoverSession).url);
assert.ok(authority === undefined || authority.hostname === "127.0.0.1", "The fixture's authority must be on loopback");
const network = globalThis.fetch;

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
  const id = randomUUID();
  let item: ResponseItem;
  if (typeof step.text === "string") item = { id, type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: step.text, annotations: [] }] };
  else {
    assert.ok(typeof step.tool === "string" && object(step.args));
    const updates = body.input.flatMap((item: unknown) => object(item) && item.type === "additional_tools" && Array.isArray(item.tools) ? item.tools : []);
    const declared = new Map([...(Array.isArray(body.tools) ? body.tools : []), ...updates].flatMap((tool: unknown) =>
      object(tool) && typeof tool.name === "string" ? [[tool.name, tool.type] as const] : []));
    const codemode = declared.get("codemode");
    item = !declared.has(step.tool) && codemode !== undefined ? oneCallScript(id, step.tool, step.args, codemode)
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
        { type: "response.output_text.delta", item_id: item.id, output_index, content_index: 0, delta: item.content[0].text },
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
  return new Response(events.map((event) => "data: " + JSON.stringify(event) + "\n\n").join(""), { headers: { "content-type": "text/event-stream" } });
};
await import("../../src/bridge.js");
