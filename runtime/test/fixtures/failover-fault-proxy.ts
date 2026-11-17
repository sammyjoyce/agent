import { createServer, request as forward, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { AddressInfo } from "node:net";
import type { TestContext } from "node:test";

export type Fault =
  | { readonly kind: "pass" }
  | { readonly kind: "delay"; readonly ms: number }
  | { readonly kind: "blackhole" }
  | { readonly kind: "drop-after-apply" }
  | { readonly kind: "reply-late"; readonly release: Promise<void> }
  | { readonly kind: "unavailable" };

export interface FaultRule {
  readonly fault: Fault;
  readonly match?: (request: { readonly method: string; readonly path: string; readonly body: string }) => boolean;
  times?: number;
}

export const commands = (op?: string): NonNullable<FaultRule["match"]> => ({ method, path, body }) =>
  method === "POST" && path.endsWith("/commands") && (op === undefined || body.includes(`"op":"${op}"`));
export const blobs: NonNullable<FaultRule["match"]> = ({ path }) => path.includes("/blobs/");

export async function startFaultProxy(t: TestContext, upstream: string) {
  const rules: FaultRule[] = [];
  const seen: { method: string; path: string; body: string; forwarded: boolean }[] = [];
  const held = new Set<ServerResponse>();
  const target = new URL(upstream);

  const send = (incoming: IncomingMessage, body: Buffer) => new Promise<{ status: number; headers: IncomingMessage["headers"]; body: Buffer }>((resolve, reject) => {
    const outgoing = forward({ host: target.hostname, port: target.port, path: incoming.url, method: incoming.method,
      headers: { ...incoming.headers, host: target.host } }, (reply) => {
      const chunks: Buffer[] = [];
      reply.on("data", (chunk: Buffer) => chunks.push(chunk));
      reply.on("end", () => resolve({ status: reply.statusCode ?? 502, headers: reply.headers, body: Buffer.concat(chunks) }));
      reply.on("error", reject);
    });
    outgoing.on("error", reject);
    outgoing.end(body);
  });

  const server: Server = createServer((incoming, response) => {
    const chunks: Buffer[] = [];
    incoming.on("data", (chunk: Buffer) => chunks.push(chunk));
    incoming.on("end", () => void handle(incoming, response, Buffer.concat(chunks)).catch(() => response.destroy()));
  });

  async function handle(incoming: IncomingMessage, response: ServerResponse, body: Buffer) {
    const request = { method: incoming.method ?? "GET", path: incoming.url ?? "/", body: body.length > 1_000_000 ? "" : body.toString("utf8") };
    const rule = rules.find((candidate) => (candidate.times ?? 1) > 0 && (candidate.match?.(request) ?? true));
    if (rule?.times !== undefined) rule.times -= 1;
    const fault = rule?.fault ?? { kind: "pass" };
    const record = { ...request, forwarded: false };
    seen.push(record);
    switch (fault.kind) {
      case "blackhole":
        held.add(response);
        return;
      case "unavailable":
        response.writeHead(503, { "content-type": "application/json" }).end('{"error":"The fault proxy refused this request"}');
        return;
      case "delay":
        await new Promise((resolve) => setTimeout(resolve, fault.ms));
        break;
      case "pass": case "drop-after-apply": case "reply-late":
        break;
      default:
        return fault satisfies never;
    }
    const reply = await send(incoming, body);
    record.forwarded = true;
    if (fault.kind === "drop-after-apply") { response.destroy(); return; }
    if (fault.kind === "reply-late") {
      held.add(response);
      await fault.release;
      held.delete(response);
    }
    response.writeHead(reply.status, reply.headers).end(reply.body);
  }

  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const stop = async () => {
    for (const response of held) response.destroy();
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  };
  t.after(stop);
  return {
    url: `http://127.0.0.1:${(server.address() as AddressInfo).port}`,
    seen,
    inject(rule: FaultRule) { rules.unshift(rule); return rule; },
    heal() { rules.length = 0; for (const response of held) response.destroy(); held.clear(); },
    stop,
  };
}
