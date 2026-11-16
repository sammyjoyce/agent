import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";

const gateway = process.env.OPENAI_BASE_URL?.replace(/\/+$/, "");
assert.ok(gateway, "Set OPENAI_BASE_URL to an OpenAI-compatible gateway");
const upstream = globalThis.fetch;
let sequence = 0;
globalThis.fetch = async (input, options) => {
  const url = input instanceof Request ? input.url : input.toString();
  assert.ok(url.startsWith("https://api.openai.com/v1/"), "The live fixture only forwards OpenAI API requests");
  const request = sequence++;
  const recorded = process.env.AGENT_TEST_REQUESTS;
  if (recorded !== undefined && typeof options?.body === "string") {
    appendFileSync(recorded, options.body.replace(/data:(image\/[a-z]+);base64,[A-Za-z0-9+/=]+/g,
      (_match, mime: string) => `data:${mime};base64,<elided>`) + "\n");
  }
  const started = Date.now();
  const response = await upstream(gateway + url.slice("https://api.openai.com/v1".length), options);
  const responses = process.env.AGENT_TEST_RESPONSES;
  if (responses === undefined || response.body === null) return response;
  const [model, copy] = response.body.tee();
  void appendResponseWhenStreamEnds(copy, responses, { request, status: response.status, started });
  const headers = new Headers(response.headers);
  headers.delete("content-encoding"); headers.delete("content-length");
  return new Response(model, { status: response.status, statusText: response.statusText, headers });
};

function object(value: unknown): value is Record<string, unknown> { return value !== null && typeof value === "object" && !Array.isArray(value); }
async function appendResponseWhenStreamEnds(stream: ReadableStream<Uint8Array>, file: string, meta: { request: number; status: number; started: number }): Promise<void> {
  const decoder = new TextDecoder();
  let body = "", error: string | null = null;
  try { for await (const chunk of stream) body += decoder.decode(chunk, { stream: true }); }
  catch (failure) { error = failure instanceof Error ? failure.name : "stream failed"; }
  let final: Record<string, unknown> | undefined;
  for (const line of body.split("\n")) {
    if (!line.startsWith("data: ")) continue;
    try {
      const event: unknown = JSON.parse(line.slice("data: ".length));
      if (object(event) && object(event.response) &&
          ["response.completed", "response.incomplete", "response.failed"].includes(String(event.type))) final = event.response;
    } catch { continue; }
  }
  appendFileSync(file, JSON.stringify({ request: meta.request, status: meta.status, latency_ms: Date.now() - meta.started,
    state: final?.status ?? null, usage: final?.usage ?? null, output: final?.output ?? null, error }) + "\n");
}
await import("../../src/bridge.js");
