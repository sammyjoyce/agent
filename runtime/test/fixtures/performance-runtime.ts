// Imports only Node built-ins, so each benchmarked version loads only its own
// runtime's packages.
import { writeFile } from "node:fs/promises";

const runtime = process.env.AGENT_PERFORMANCE_RUNTIME;
const provider = process.env.AGENT_PERFORMANCE_PROVIDER;
const pidFile = process.env.AGENT_PERFORMANCE_RUNTIME_PID;
if (runtime === undefined || provider === undefined || pidFile === undefined) {
  throw new Error("The runtime, the benchmark provider and the runtime PID file are required");
}
process.env.OPENAI_API_KEY = "sk-synthetic-performance";
await writeFile(pidFile, String(process.pid));
const providerFetch = globalThis.fetch;
globalThis.fetch = async (input, init) => {
  const url = input instanceof Request ? input.url : input.toString();
  if (url !== "https://api.openai.com/v1/responses") throw new Error(`Performance scenarios must not contact ${url}`);
  const target = `${provider}/v1/responses`;
  return providerFetch(input instanceof Request ? new Request(target, input) : target, init);
};
// Runtime.start gives this process the same state argument as bridge.js.
await import(runtime);
