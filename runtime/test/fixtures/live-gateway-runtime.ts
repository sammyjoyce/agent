import assert from "node:assert/strict";
import { appendFileSync } from "node:fs";

const gateway = process.env.OPENAI_BASE_URL?.replace(/\/+$/, "");
assert.ok(gateway, "Set OPENAI_BASE_URL to an OpenAI-compatible gateway");
const upstream = globalThis.fetch;
globalThis.fetch = async (input, options) => {
  const url = input instanceof Request ? input.url : input.toString();
  assert.ok(url.startsWith("https://api.openai.com/v1/"), "The live fixture only forwards OpenAI API requests");
  const recorded = process.env.AGENT_TEST_REQUESTS;
  if (recorded !== undefined && typeof options?.body === "string") {
    appendFileSync(recorded, options.body.replace(/data:(image\/[a-z]+);base64,[A-Za-z0-9+/=]+/g,
      (_match, mime: string) => `data:${mime};base64,<elided>`) + "\n");
  }
  return upstream(gateway + url.slice("https://api.openai.com/v1".length), options);
};
await import("../../src/bridge.js");
