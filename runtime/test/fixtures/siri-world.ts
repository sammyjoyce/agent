import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer as createHttpServer } from "node:http";
import { createConnection, createServer, type AddressInfo, type Socket } from "node:net";
import { join } from "node:path";
import type { TestContext } from "node:test";
import { coordinatorWorld } from "./coordinator-world.js";

// A private coordinator for the iPhone app on a Simulator: the real service, Pi and bridge, with
// only the model provider and the execution hosts synthetic. The app reaches it over loopback TCP,
// relayed to the service's own socket. The Simulator's tests read and steer it over HTTP on
// loopback: GET /state, POST /hold-next-submit-reply, POST /stop.
// Usage: node siri-world.js <output directory>
const output = process.argv[2];
if (output === undefined) throw new Error("Usage: siri-world.js <output directory>");
await mkdir(output, { recursive: true });

const cleanups: ((context: unknown) => Promise<void> | void)[] = [];
const owner = { after: (cleanup: (context: unknown) => Promise<void> | void) => { cleanups.push(cleanup); } };
const world = await coordinatorWorld(owner as unknown as TestContext);
// Spare answers let a second generation run and be counted instead of failing the model call.
await world.script("Check the build", Array.from({ length: 3 }, () => ({ text: "The build is green." })));
await world.script("Rotate the Work logs", Array.from({ length: 3 }, () => ({ text: "The Work logs are rotated." })));

async function identify(): Promise<string> {
  const socket = createConnection(world.socket);
  try {
    return await new Promise<string>((resolve, reject) => {
      let text = "";
      socket.on("error", reject).on("data", (bytes: Buffer) => {
        text += bytes.toString("utf8");
        for (const line of text.split("\n").slice(0, -1)) {
          const event: unknown = JSON.parse(line);
          if (event !== null && typeof event === "object" && "coordinator_id" in event && typeof event.coordinator_id === "string") resolve(event.coordinator_id);
        }
      });
      socket.write(JSON.stringify({ type: "native", request: { type: "identify" } }) + "\n");
    });
  } finally { socket.destroy(); }
}
const coordinator = await identify();

type Submit = { input_id: string; text: string; origin: string | null; at: number; answered: boolean };
const submits: Submit[] = [];
let holdNextSubmitReply = false;
const relayed = new Set<Socket>();
const relay = createServer((phone) => {
  const service = createConnection(world.socket);
  relayed.add(phone);
  let pending = "", held: Submit | undefined;
  phone.on("data", (bytes: Buffer) => {
    pending += bytes.toString("utf8");
    const lines = pending.split("\n"); pending = lines.pop() ?? "";
    for (const line of lines) {
      const command: unknown = JSON.parse(line);
      if (command === null || typeof command !== "object" || !("request" in command)) continue;
      const request = command.request as { type?: string; input_id?: string; text?: string; origin?: string };
      if (request.type !== "submit" || request.input_id === undefined || request.text === undefined) continue;
      const submit = { input_id: request.input_id, text: request.text, origin: request.origin ?? null, at: Date.now(), answered: !holdNextSubmitReply };
      submits.push(submit);
      if (holdNextSubmitReply) { holdNextSubmitReply = false; held = submit; }
    }
    service.write(bytes);
  });
  service.on("data", (bytes: Buffer) => { if (held === undefined) phone.write(bytes); });
  const close = () => { relayed.delete(phone); phone.destroy(); service.destroy(); };
  phone.on("close", close).on("error", close);
  service.on("close", close).on("error", close);
});
await new Promise<void>((resolve) => relay.listen(0, "127.0.0.1", resolve));

async function generations(): Promise<Record<string, number>> {
  const text = await readFile(world.queue + ".requests", "utf8").catch(() => "");
  const counts: Record<string, number> = {};
  for (const line of text.split("\n").filter(Boolean)) {
    const { key } = JSON.parse(line) as { key: string };
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

let stop: () => void = () => {};
const stopped = new Promise<void>((resolve) => { stop = resolve; });
const control = createHttpServer((request, response) => {
  void (async () => {
    if (request.method === "GET" && request.url === "/state") {
      const state = { port: (relay.address() as AddressInfo).port, coordinator, submits, generations: await generations() };
      await writeFile(join(output, "state.json"), JSON.stringify(state, null, 2));
      response.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify(state));
    } else if (request.method === "POST" && request.url === "/hold-next-submit-reply") {
      holdNextSubmitReply = true; response.writeHead(204).end();
    } else if (request.method === "POST" && request.url === "/stop") {
      response.writeHead(204).end(); stop();
    } else response.writeHead(404).end();
  })().catch((error: unknown) => { response.writeHead(500).end(String(error)); });
});
await new Promise<void>((resolve) => control.listen(0, "127.0.0.1", resolve));
await writeFile(join(output, "world.json"), JSON.stringify({
  control: (control.address() as AddressInfo).port, relay: (relay.address() as AddressInfo).port, coordinator, directory: world.directory,
}));
process.once("SIGTERM", () => stop());
process.once("SIGINT", () => stop());
await stopped;
await writeFile(join(output, "final.json"), JSON.stringify({ submits, generations: await generations() }, null, 2));
control.close(); relay.close();
for (const socket of relayed) socket.destroy();
for (const cleanup of cleanups.reverse()) await cleanup({ passed: true, diagnostic: () => {} });
