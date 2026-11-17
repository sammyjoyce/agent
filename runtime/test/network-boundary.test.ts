import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../../src/", import.meta.url));

/** The ways a module in the Pi child can open a connection by itself. */
const NETWORK_USES: readonly (readonly [string, RegExp])[] = [
  ...["http", "https", "http2", "net", "tls", "dgram"].map((module) => [`node:${module}`, new RegExp(`["'](?:node:)?${module}["']`)] as const),
  ["WebSocket", /\bWebSocket\b/],
  ["fetch(", /\bfetch\(/],
];

/**
 * Every network use the coordinator's Pi process has. Each one is either gated
 * on the owner gate or needs no gate, and `why` says which.
 */
const ALLOWED: readonly { file: string; use: string; why: string; only?: RegExp }[] = [
  { file: "notifications.ts", use: "node:http2", why: "The APNs client. Each send waits at the owner gate." },
  { file: "auth.ts", use: "node:http", why: "The loopback listener for the ChatGPT sign-in callback. It accepts and never dials." },
  { file: "auth.ts", use: "fetch(", why: "The OpenID exchange of a sign-in. It changes only this host's auth.json, which is not replicated." },
  { file: "failover/authority-client.ts", use: "fetch(", why: "The authority itself, which is what the owner gate asks." },
  { file: "protocol.ts", use: "node:net", why: "isIPv4 checks an address format and opens nothing.", only: /^import \{ isIPv4 \} from "node:net";$/ },
];

/** Files that do not run in the coordinator's Pi process, so they are not read. */
const OTHER_PROCESSES: Readonly<Record<string, string>> = {
  "browser-host.ts": "The browser helper, which Rust starts as its own process. Its work is to reach a browser.",
  "failover/authority-worker.ts": "The authority Worker, which runs on Cloudflare.",
};

test("no module of the Pi child opens a connection outside the listed, gated places", async () => {
  const files = (await readdir(source, { recursive: true, withFileTypes: true })).filter((entry) => entry.isFile())
    .map((entry) => relative(source, `${entry.parentPath}/${entry.name}`)).sort();
  for (const file of Object.keys(OTHER_PROCESSES)) assert.ok(files.includes(file), `${file} is listed as another process and does not exist`);
  const found: { file: string; line: number; use: string; text: string }[] = [];
  for (const file of files) {
    if (file in OTHER_PROCESSES) continue;
    for (const [index, text] of (await readFile(`${source}/${file}`, "utf8")).split("\n").entries()) {
      for (const [use, pattern] of NETWORK_USES) if (pattern.test(text)) found.push({ file, line: index + 1, use, text: text.trim() });
    }
  }
  const allowed = (use: (typeof found)[number]) =>
    ALLOWED.some((entry) => entry.file === use.file && entry.use === use.use && (entry.only?.test(use.text) ?? true));
  assert.deepEqual(found.filter((use) => !allowed(use)).map(({ file, line, use }) => `${file}:${line} uses ${use}`), [],
    "A network use outside the allowlist. Route the effect through HostRequests, or gate it on the owner gate and list it in ALLOWED with the reason.");
  assert.deepEqual(ALLOWED.filter((entry) => !found.some((use) => use.file === entry.file && use.use === entry.use)).map(({ file, use }) => `${file} no longer uses ${use}`), [],
    "An allowlist entry nothing uses. Remove it.");
});

test("a host_call frame is built in one place, where HostRequests emits it after the owner gate", async () => {
  const files = (await readdir(source, { recursive: true, withFileTypes: true })).filter((entry) => entry.isFile())
    .map((entry) => relative(source, `${entry.parentPath}/${entry.name}`)).filter((file) => !file.startsWith("generated/")).sort();
  const built: string[] = [];
  for (const file of files) {
    for (const text of (await readFile(`${source}/${file}`, "utf8")).split("\n")) if (/["']host_call["']/.test(text)) built.push(`${file}: ${text.trim()}`);
  }
  assert.deepEqual(built, ['bridge.ts: const hostRequests = new HostRequests((id, call_id, command) => emit(id, { type: "host_call", call_id, command }),'],
    "Every host call, the dreams call included, must go through HostRequests.call, which waits at the owner gate before this frame is written.");
});
