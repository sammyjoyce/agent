import { generateKeyPairSync } from "node:crypto";
import { writeFile } from "node:fs/promises";
import { createServer, type ServerHttp2Session, type ServerHttp2Stream } from "node:http2";
import type { AddressInfo } from "node:net";
import type { TestContext } from "node:test";
import type { ApnsConfig } from "../../src/generated/ApnsConfig.js";

export interface Push { readonly path: string; readonly apnsId: string | undefined; readonly body: string }

/**
 * A local HTTP/2 origin that stands in for Apple. A coordinator started with
 * `environment` sends its pushes here. `received` lists each push when its
 * body has arrived. While `answering` is false the origin keeps the push and
 * sends no receipt, as a receipt lost on the way does.
 */
export async function startApnsOrigin(t: TestContext) {
  const server = createServer(), sessions = new Set<ServerHttp2Session>(), received: Push[] = [];
  const origin = { received, answering: true, onPush: (): void => {} };
  server.on("session", (session) => { sessions.add(session); session.on("error", () => {}); session.once("close", () => sessions.delete(session)); });
  server.on("stream", (stream: ServerHttp2Stream, headers) => {
    const chunks: Buffer[] = [];
    stream.on("error", () => {});
    stream.on("data", (chunk: Buffer) => chunks.push(chunk));
    stream.once("end", () => {
      const id = headers["apns-id"];
      received.push({ path: String(headers[":path"]), apnsId: typeof id === "string" ? id : undefined, body: Buffer.concat(chunks).toString("utf8") });
      origin.onPush();
      if (!origin.answering) return;
      stream.respond({ ":status": 200 });
      stream.end();
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  t.after(async () => {
    for (const session of sessions) session.destroy();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });
  return Object.assign(origin, { environment: { AGENT_TEST_APNS_ORIGIN: `http://127.0.0.1:${(server.address() as AddressInfo).port}` } });
}

export type ApnsOrigin = Awaited<ReturnType<typeof startApnsOrigin>>;

/** Writes an invented signing key at `keyFile` and returns the configuration that names it. */
export async function apnsConfig(keyFile: string): Promise<ApnsConfig> {
  await writeFile(keyFile, generateKeyPairSync("ec", { namedCurve: "prime256v1" }).privateKey.export({ format: "pem", type: "pkcs8" }), { mode: 0o600 });
  return { team_id: "TEAM000001", key_id: "KEY0000001", topic: "dev.example.Agent", key_file: keyFile, environment: "sandbox" };
}
