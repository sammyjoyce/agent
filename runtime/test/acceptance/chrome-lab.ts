import { execFile, spawn, type ChildProcess } from "node:child_process";
import { randomUUID } from "node:crypto";
import { appendFileSync, closeSync, existsSync, mkdirSync, mkdtempSync, openSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { createServer as createNetServer, connect } from "node:net";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { promisify } from "node:util";
import type { BrowserResponse } from "../../src/generated/BrowserResponse.js";
import type { BrowserTab } from "../../src/generated/BrowserTab.js";

export const SITE_PORT = 18080;
export const SITE_ORIGIN = `http://127.0.0.1:${SITE_PORT}`;
export const SITE_USERNAME = "ada@example.test";
export const EXTENSION_CONNECT_URL = "chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/connect.html";
/** The product's words for a tab that may outlive its lost connection. */
export const CLEANUP_UNVERIFIED = "cleanup was not verified";
const CASE_ID = /^[a-z0-9-]{1,80}$/;

export const execFileAsync = promisify(execFile);

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function now(): string { return new Date().toISOString(); }

export async function waitFor<T>(label: string, timeoutMs: number, probe: () => Promise<T | undefined> | T | undefined,
  intervalMs = 1000): Promise<T> {
  const deadline = Date.now() + timeoutMs;
  let last: unknown;
  for (;;) {
    try {
      const value = await probe();
      if (value !== undefined) return value;
    } catch (error) { last = error; }
    if (Date.now() >= deadline) {
      throw new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s waiting for ${label}` + (last instanceof Error ? ` (${last.message})` : ""));
    }
    await delay(intervalMs);
  }
}

export async function freePort(): Promise<number> {
  const server = createNetServer();
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
  const address = server.address();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  if (address === null || typeof address === "string") throw new Error("No free loopback port");
  return address.port;
}

export function portAccepts(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ host: "127.0.0.1", port });
    socket.once("connect", () => { socket.destroy(); resolve(true); });
    socket.once("error", () => resolve(false));
  });
}

export function socketAccepts(path: string): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = connect({ path });
    socket.once("connect", () => { socket.destroy(); resolve(true); });
    socket.once("error", () => resolve(false));
  });
}

export function processAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch { return false; }
}

export class SecretScanner {
  private readonly needles = new Set<string>();

  add(secret: string): void {
    if (secret.length < 8) throw new Error("A scanned secret is too short to search for reliably");
    for (const variant of [secret, JSON.stringify(secret).slice(1, -1), encodeURIComponent(secret)]) this.needles.add(variant);
  }

  exposed(text: string): boolean {
    for (const needle of this.needles) if (text.includes(needle)) return true;
    return false;
  }

  redact(text: string): string {
    let out = text;
    for (const needle of this.needles) out = out.split(needle).join("[secret]");
    return out;
  }
}

export type CdpTarget = { targetId: string; type: string; url: string; title: string };

export class CdpClient {
  private nextId = 0;
  private readonly pending = new Map<number, { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void }>();

  private constructor(private readonly socket: WebSocket) {
    socket.addEventListener("message", (event) => {
      const message: unknown = JSON.parse(String(event.data));
      if (!isRecord(message) || typeof message.id !== "number") return;
      const waiter = this.pending.get(message.id);
      if (waiter === undefined) return;
      this.pending.delete(message.id);
      if (isRecord(message.error)) waiter.reject(new Error(`CDP error ${String(message.error.message)}`));
      else waiter.resolve(isRecord(message.result) ? message.result : {});
    });
    socket.addEventListener("close", () => {
      for (const waiter of this.pending.values()) waiter.reject(new Error("CDP connection closed"));
      this.pending.clear();
    });
  }

  static async connect(port: number): Promise<CdpClient> {
    const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(5000) });
    const version: unknown = await response.json();
    if (!isRecord(version) || typeof version.webSocketDebuggerUrl !== "string") throw new Error("Chrome did not report a DevTools endpoint");
    // The guest's endpoint names its own port; the observer reaches it through a forward.
    const socket = new WebSocket(`ws://127.0.0.1:${port}${new URL(version.webSocketDebuggerUrl).pathname}`);
    await new Promise<void>((resolve, reject) => {
      socket.addEventListener("open", () => resolve(), { once: true });
      socket.addEventListener("error", () => reject(new Error("CDP connection failed")), { once: true });
    });
    return new CdpClient(socket);
  }

  send(method: string, params: Record<string, unknown> = {}, sessionId?: string): Promise<Record<string, unknown>> {
    const id = ++this.nextId;
    const reply = new Promise<Record<string, unknown>>((resolve, reject) => { this.pending.set(id, { resolve, reject }); });
    this.socket.send(JSON.stringify({ id, method, params, ...(sessionId === undefined ? {} : { sessionId }) }));
    return Promise.race([reply, delay(20_000).then(() => { throw new Error(`CDP ${method} timed out`); })]);
  }

  async targets(): Promise<CdpTarget[]> {
    const result = await this.send("Target.getTargets");
    const infos = Array.isArray(result.targetInfos) ? result.targetInfos : [];
    return infos.flatMap((info: unknown) => isRecord(info) && typeof info.targetId === "string" && typeof info.type === "string"
      && typeof info.url === "string" ? [{ targetId: info.targetId, type: info.type, url: info.url, title: String(info.title ?? "") }] : []);
  }

  async inPage<T>(url: string, ready: string, use: (evaluate: (expression: string) => Promise<unknown>) => Promise<T>): Promise<T> {
    const created = await this.send("Target.createTarget", { url, background: true });
    const targetId = String(created.targetId);
    try {
      const attached = await this.send("Target.attachToTarget", { targetId, flatten: true });
      const sessionId = String(attached.sessionId);
      const evaluate = async (expression: string): Promise<unknown> => {
        const result = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, sessionId);
        if (result.exceptionDetails !== undefined) throw new Error("Page evaluation failed");
        return isRecord(result.result) ? result.result.value : undefined;
      };
      await waitFor(`${url} to load`, 20_000, async () => await evaluate(ready) === true ? true : undefined, 250);
      return await use(evaluate);
    } finally {
      await this.send("Target.closeTarget", { targetId }).catch(() => {});
    }
  }

  async closeTarget(targetId: string): Promise<void> { await this.send("Target.closeTarget", { targetId }); }

  close(): void { this.socket.close(); }
}

const PASSWORD_PAGE = "chrome://password-manager/passwords";
const PASSWORDS_READY = "document.readyState === 'complete' && typeof chrome === 'object' && typeof chrome.passwordsPrivate === 'object'";
const OURS = `(entry) => (entry.affiliatedDomains || []).some((domain) => domain.signonRealm === ${JSON.stringify(`${SITE_ORIGIN}/`)})`;
// The page's list arrives asynchronously after load and after each change.
// Background tabs throttle timers to about once a second, so loops are bounded by time.
const COUNT_OURS = `(async () => {
  let count = 0;
  for (const deadline = Date.now() + 6000; Date.now() < deadline;) {
    count = (await chrome.passwordsPrivate.getSavedPasswordList()).filter(${OURS}).length;
    if (count > 0) return count;
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  return count;
})()`;

export async function savedLoginsForOrigin(cdp: CdpClient): Promise<number> {
  return cdp.inPage(PASSWORD_PAGE, PASSWORDS_READY, async (evaluate) => {
    const count = await evaluate(COUNT_OURS);
    if (typeof count !== "number") throw new Error("Chrome did not list saved logins");
    return count;
  });
}

export async function replaceSavedLogin(cdp: CdpClient, password: string): Promise<number> {
  return cdp.inPage(PASSWORD_PAGE, PASSWORDS_READY, async (evaluate) => {
    const existing = await evaluate(COUNT_OURS);
    if (typeof existing !== "number") throw new Error("Chrome did not list saved logins");
    const removed = await evaluate(`(async () => {
      const api = chrome.passwordsPrivate, ours = ${OURS};
      for (const entry of (await api.getSavedPasswordList()).filter(ours)) await api.removeCredential(entry.id, entry.storedIn);
      for (const deadline = Date.now() + 6000; Date.now() < deadline;) {
        if ((await api.getSavedPasswordList()).filter(ours).length === 0) return true;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      return false;
    })()`);
    if (removed !== true) throw new Error("Older saved logins for the invented origin could not be removed");
    try {
      await evaluate(`chrome.passwordsPrivate.addPassword(${JSON.stringify({ url: `${SITE_ORIGIN}/login`, username: SITE_USERNAME,
        password, note: "", useAccountStore: false })}).then(() => true)`);
    } catch { throw new Error("Chrome did not save the invented login"); }
    const count = await evaluate(COUNT_OURS);
    if (typeof count !== "number") throw new Error("Chrome did not list saved logins");
    return count;
  });
}

export type SiteOutcome = "page" | "signed_in" | "sign_in_rejected" | "submitted" | "not_found";
export type SiteRequest = { seq: number; at: string; leg: string; method: string; path: string; case_id: string | null;
  outcome: SiteOutcome; password_matched: boolean | null };

function page(title: string, body: string): string {
  // The data: icon keeps Chrome from sending favicon requests attributed to a case.
  return `<!doctype html><html><head><meta charset="utf-8"><link rel="icon" href="data:,"><title>${title}</title></head><body>${body}</body></html>`;
}

export class InventedSite {
  readonly requests: SiteRequest[] = [];
  leg = "";
  private readonly holding = new Set<string>();
  private held: (() => void)[] = [];
  private server: Server | undefined;

  constructor(private readonly password: string, private readonly logFile: string) {}

  async start(): Promise<void> {
    const server = createServer((request, response) => { void this.handle(request, response); });
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(SITE_PORT, "127.0.0.1", resolve); });
    this.server = server;
  }

  async stop(): Promise<void> {
    this.release();
    const server = this.server;
    if (server === undefined) return;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  hold(caseId: string): void { this.holding.add(caseId); }

  release(): void {
    this.holding.clear();
    const held = this.held;
    this.held = [];
    for (const answer of held) answer();
  }

  get seq(): number { return this.requests.length; }

  count(caseId: string, outcome: SiteOutcome): number {
    return this.requests.filter((entry) => entry.case_id === caseId && entry.outcome === outcome).length;
  }

  signedInWithSavedPassword(caseId: string): boolean {
    return this.requests.some((entry) => entry.case_id === caseId && entry.outcome === "signed_in" && entry.password_matched === true);
  }

  after(caseId: string, seq: number): SiteRequest[] {
    return this.requests.filter((entry) => entry.case_id === caseId && entry.seq > seq);
  }

  private record(request: IncomingMessage, caseId: string | null, outcome: SiteOutcome, passwordMatched: boolean | null): void {
    const entry: SiteRequest = { seq: this.requests.length + 1, at: now(), leg: this.leg, method: request.method ?? "",
      path: new URL(request.url ?? "/", SITE_ORIGIN).pathname, case_id: caseId, outcome, password_matched: passwordMatched };
    this.requests.push(entry);
    appendFileSync(this.logFile, JSON.stringify(entry) + "\n");
  }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", SITE_ORIGIN);
    const raw = url.searchParams.get("case");
    const caseId = raw !== null && CASE_ID.test(raw) ? raw : null;
    const answer = (status: number, html: string) => {
      if (response.writableEnded || response.destroyed) return;
      response.writeHead(status, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" }).end(html);
    };
    const query = caseId === null ? "" : `?case=${caseId}`;
    if (request.method === "GET" && url.pathname === "/login") {
      this.record(request, caseId, "page", null);
      answer(200, page("Invented login", `<h1>Invented sign-in</h1><form method="post" action="/session${query}">
        <label>Email <input name="username" autocomplete="username"></label>
        <label>Password <input type="password" name="password" autocomplete="current-password"></label>
        <button type="submit">Sign in</button></form>`));
      return;
    }
    if (request.method === "POST" && (url.pathname === "/session" || url.pathname === "/submit")) {
      const form = new URLSearchParams(await readBody(request));
      if (url.pathname === "/session") {
        const matched = form.get("password") === this.password;
        const signedIn = matched && form.get("username") === SITE_USERNAME;
        this.record(request, caseId, signedIn ? "signed_in" : "sign_in_rejected", matched);
        answer(signedIn ? 200 : 403, signedIn
          ? page("Signed in", `<h1>Signed in as ${SITE_USERNAME}</h1><form method="post" action="/submit${query}">
            <label>Note <textarea name="note"></textarea></label><button type="submit">Submit</button></form>`)
          : page("Sign-in rejected", "<h1>Sign-in rejected</h1>"));
        return;
      }
      this.record(request, caseId, "submitted", null);
      const saved = () => answer(200, page("Saved", "<h1>Saved</h1>"));
      if (caseId !== null && this.holding.has(caseId)) this.held.push(saved); else saved();
      return;
    }
    this.record(request, caseId, "not_found", null);
    answer(404, page("Not found", "<h1>Not found</h1>"));
  }
}

async function readBody(request: IncomingMessage): Promise<string> {
  let body = "";
  request.setEncoding("utf8");
  for await (const chunk of request) {
    body += String(chunk);
    if (body.length > 16_384) throw new Error("Invented form body is too large");
  }
  return body;
}

export type Phase = "delegate" | "start" | "reconcile";
export type CaseRole = "interrupted" | "fresh";
export type LabCase = { id: string; role: CaseRole; host: string };
export type ToolOutcomeType = BrowserResponse["type"] | "rejected" | "unparsed" | "absent";
export type Observed = { type: ToolOutcomeType; state: string | null; pending_operation: string | null; owner_id: string | null;
  tabs: BrowserTab[]; message: string; output: string | null };
export type CaseView = {
  open: Observed | null; run_code: Observed | null; release: Observed | null;
  old_handle: Observed | null; status: Observed | null; reconcile_release: Observed | null;
  finals: Partial<Record<Phase, string>>;
};
export type Unexpected = { at: string; leg: string; case_id: string | null; phase: Phase | null; reason: string };

type Step = { text: string } | { tool: string; args: Record<string, unknown> };
type Call = { callId: string; tool: string; output: Observed | null };
type Segment = { caseId: string; phase: Phase; calls: Call[] };
type History = { current: Segment; segments: Segment[] };
type StepBuilder = (history: History) => Step;

class UnexpectedRequest extends Error {}

const LABKEY = /^labkey:([a-z0-9-]+):(delegate|start|reconcile)\b/;
const RESULT = /labresult:([A-Za-z0-9\-_.!~*'()%]+):end/;
const SEARCH: Step = { tool: "tool_search", args: { query: "browser open run code action status release", limit: 8 } };

export function labKey(caseId: string, phase: Phase): string { return `labkey:${caseId}:${phase}`; }

export const LAB_TASK_TITLE_PREFIX = "Chrome case ";
export function labTaskTitle(caseId: string): string { return `${LAB_TASK_TITLE_PREFIX}${caseId}`; }

function signInAndSubmit(caseId: string): string {
  return `async (page) => {
  const autofilled = await page.waitForFunction(() => document.querySelector('input[type="password"]')?.matches(':autofill') === true,
    undefined, { timeout: 20000 }).then(() => true, () => false);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('heading', { name: /Signed in/ }).waitFor({ timeout: 20000 });
  await page.locator('textarea[name="note"]').fill('Invented note for ${caseId}');
  await page.getByRole('button', { name: 'Submit' }).click();
  await page.getByRole('heading', { name: 'Saved' }).waitFor({ timeout: 120000 });
  return { autofilled, saved: true };
}`;
}

function segment(history: History, caseId: string, phase: Phase): Segment {
  const found = history.segments.find((entry) => entry.caseId === caseId && entry.phase === phase);
  if (found === undefined) throw new UnexpectedRequest(`no ${phase} history for ${caseId}`);
  return found;
}

function result(of: Segment, tool: string): Observed {
  const call = of.calls.find((entry) => entry.tool === tool);
  if (call?.output == null) throw new UnexpectedRequest(`${tool} has no output in ${of.phase}`);
  return call.output;
}

function openedTab(of: Segment): number {
  const opened = result(of, "browser_open");
  const tab = opened.tabs[0];
  if (opened.type !== "ready" || opened.tabs.length !== 1 || tab === undefined) {
    throw new UnexpectedRequest(`browser_open returned ${opened.type} with ${opened.tabs.length} tabs`);
  }
  return tab.id;
}

const SCRIPTS: { readonly [P in Phase]: (labCase: LabCase) => readonly StepBuilder[] } = {
  delegate: (labCase) => [
    () => ({ tool: "delegate_task", args: { title: labTaskTitle(labCase.id), outcome: "Sign in to the invented site and submit one invented note",
      input: `${labKey(labCase.id, "start")} Sign in to the invented site with the saved login and submit one invented note.`,
      host: labCase.host, new_task: true, new_task_reason: "Independent acceptance case" } }),
    () => ({ text: `Delegated ${labCase.id}.` }),
  ],
  start: (labCase) => [
    () => SEARCH,
    () => ({ tool: "browser_open", args: { url: `${SITE_ORIGIN}/login?case=${labCase.id}`, host: labCase.host } }),
    ({ current }) => ({ tool: "browser_run_code", args: { tab_id: openedTab(current), code: signInAndSubmit(labCase.id) } }),
    ...(labCase.role === "fresh" ? [() => ({ tool: "browser_release", args: {} })] : []),
    ({ current }) => ({ text: `Case ${labCase.id} start finished. ${current.calls.map((call) => `${call.tool}: ${call.output?.type ?? "absent"}`).join("; ")}.` }),
  ],
  reconcile: (labCase) => [
    () => SEARCH,
    (history) => ({ tool: "browser_action", args: { action: { type: "snapshot", tab_id: openedTab(segment(history, labCase.id, "start")) } } }),
    () => ({ tool: "browser_status", args: {} }),
    () => ({ tool: "browser_release", args: {} }),
    ({ current }) => ({ text: `Case ${labCase.id} reconciled. ${current.calls.map((call) => `${call.tool}: ${call.output?.type ?? "absent"}`).join("; ")}.` }),
  ],
};

function contentText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.flatMap((part: unknown) => isRecord(part) && typeof part.text === "string" ? [part.text] : []).join("\n");
}

function binding(text: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(text);
    return isRecord(value) && typeof value.owner_id === "string" ? value : undefined;
  } catch { return undefined; }
}

function tabs(value: unknown): BrowserTab[] {
  return Array.isArray(value) ? value.flatMap((tab: unknown) => isRecord(tab) && typeof tab.id === "number"
    ? [{ id: tab.id, url: String(tab.url ?? ""), title: String(tab.title ?? "") }] : []) : [];
}

export function observe(outputText: string): Observed {
  const wrapped = RESULT.exec(outputText);
  let rejected = false, text = outputText;
  if (wrapped?.[1] !== undefined) {
    const inner: unknown = JSON.parse(decodeURIComponent(wrapped[1]));
    if (isRecord(inner)) { rejected = inner.rejected === true; text = String(inner.text ?? ""); }
  }
  const saved = binding(text);
  const response = isRecord(saved?.response) ? saved.response : undefined;
  if (saved === undefined || response === undefined) {
    return { type: rejected ? "rejected" : "unparsed", state: null, pending_operation: null, owner_id: null, tabs: [],
      message: text.slice(0, 2000), output: null };
  }
  return { type: String(response.type) as BrowserResponse["type"], state: String(saved.state), owner_id: String(saved.owner_id),
    pending_operation: typeof saved.pending_operation === "string" ? saved.pending_operation : null, tabs: tabs(response.tabs),
    message: typeof response.message === "string" ? response.message : "",
    output: typeof response.output === "string" ? response.output.slice(0, 8000) : null };
}

function toolOf(item: Record<string, unknown>): string {
  if (item.name !== "codemode") return String(item.name);
  const code = typeof item.input === "string" ? item.input : (() => {
    try { const args: unknown = JSON.parse(String(item.arguments)); return isRecord(args) ? String(args.code) : ""; } catch { return ""; }
  })();
  if (code.includes("await searchTools(")) return "tool_search";
  return /tools\.([a-z_]+)\(/.exec(code)?.[1] ?? "codemode";
}

function parseHistory(input: unknown[]): History {
  const segments: Segment[] = [];
  const calls = new Map<string, Call>();
  for (const item of input) {
    if (!isRecord(item)) continue;
    if (item.role === "user") {
      const keys = LABKEY.exec(contentText(item.content).trimStart());
      if (keys?.[1] !== undefined && keys[2] !== undefined) segments.push({ caseId: keys[1], phase: keys[2] as Phase, calls: [] });
      continue;
    }
    if ((item.type === "function_call" || item.type === "custom_tool_call") && typeof item.call_id === "string") {
      const call: Call = { callId: item.call_id, tool: toolOf(item), output: null };
      calls.set(call.callId, call);
      segments.at(-1)?.calls.push(call);
      continue;
    }
    if ((item.type === "function_call_output" || item.type === "custom_tool_call_output") && typeof item.call_id === "string") {
      const call = calls.get(item.call_id);
      if (call !== undefined) call.output = observe(contentText(item.output));
    }
  }
  const current = segments.at(-1);
  if (current === undefined) throw new UnexpectedRequest("no lab key in any user message");
  return { current, segments };
}

function emptyView(): CaseView {
  return { open: null, run_code: null, release: null, old_handle: null, status: null, reconcile_release: null, finals: {} };
}

function outputOf(of: Segment | undefined, tool: string): Observed | null {
  return of?.calls.find((call) => call.tool === tool)?.output ?? null;
}

export class ScriptedModel {
  readonly cases = new Map<string, LabCase>();
  readonly views = new Map<string, CaseView>();
  readonly unexpected: Unexpected[] = [];
  readonly exposures: { at: string; leg: string }[] = [];
  leg = "";
  private server: Server | undefined;
  port = 0;

  constructor(private readonly scanner: SecretScanner, private readonly logFile: string) {}

  async start(): Promise<void> {
    const server = createServer((request, response) => { void this.handle(request, response); });
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); });
    const address = server.address();
    if (address === null || typeof address === "string") throw new Error("Scripted model has no port");
    this.port = address.port;
    this.server = server;
  }

  async stop(): Promise<void> {
    const server = this.server;
    if (server === undefined) return;
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }

  add(labCase: LabCase): void { this.cases.set(labCase.id, labCase); this.views.set(labCase.id, emptyView()); }

  view(caseId: string): CaseView { return this.views.get(caseId) ?? emptyView(); }

  private async handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    let raw = "";
    request.setEncoding("utf8");
    for await (const chunk of request) raw += String(chunk);
    if (this.scanner.exposed(raw)) this.exposures.push({ at: now(), leg: this.leg });
    let body: unknown;
    try { body = JSON.parse(raw); } catch { body = undefined; }
    if (request.method !== "POST" || !(request.url ?? "").startsWith("/v1/responses") || !isRecord(body) || !Array.isArray(body.input)) {
      this.unexpected.push({ at: now(), leg: this.leg, case_id: null, phase: null, reason: `malformed request ${request.method} ${request.url}` });
      response.writeHead(400).end("unexpected request");
      return;
    }
    let step: Step, caseId: string | null = null, phase: Phase | null = null, index = -1, previous: Call | undefined, lastUser: string | undefined;
    try {
      const history = parseHistory(body.input);
      previous = history.current.calls.at(-1);
      ({ caseId, phase } = history.current);
      const labCase = this.cases.get(caseId);
      if (labCase === undefined) throw new UnexpectedRequest(`unknown case ${caseId}`);
      this.remember(labCase.id, history);
      const script = SCRIPTS[phase](labCase);
      index = history.current.calls.length;
      const expected = script.slice(0, index).map((builder) => builder(history));
      history.current.calls.forEach((call, position) => {
        const planned = expected[position];
        if (planned === undefined || !("tool" in planned) || planned.tool !== call.tool) {
          throw new UnexpectedRequest(`call ${position} was ${call.tool}, not the scripted step`);
        }
      });
      const builder = script[index];
      if (builder === undefined) throw new UnexpectedRequest(`script for ${phase} has no step ${index}`);
      step = builder(history);
      if ("text" in step) this.view(labCase.id).finals[phase] = step.text;
    } catch (error) {
      if (!(error instanceof UnexpectedRequest)) throw error;
      this.unexpected.push({ at: now(), leg: this.leg, case_id: caseId, phase, reason: error.message });
      const users = body.input.filter((item: unknown) => isRecord(item) && item.role === "user");
      lastUser = contentText(isRecord(users.at(-1)) ? users.at(-1).content : "").slice(0, 400);
      step = { text: `UNEXPECTED: ${error.message}. This acceptance case stops here.` };
    }
    appendFileSync(this.logFile, this.scanner.redact(JSON.stringify({ at: now(), leg: this.leg, case_id: caseId, phase, step: index,
      previous: previous === undefined ? undefined : { tool: previous.tool, type: previous.output?.type ?? "absent",
        message: previous.output?.message.slice(0, 300) }, emitted: "tool" in step ? step.tool : "text", text: "text" in step ? step.text : undefined,
      last_user: lastUser })) + "\n");
    response.writeHead(200, { "content-type": "text/event-stream" }).end(events(body, step));
  }

  private remember(caseId: string, history: History): void {
    const mine = (phase: Phase) => history.segments.filter((entry) => entry.caseId === caseId && entry.phase === phase).at(-1);
    const view = this.view(caseId), start = mine("start"), reconcile = mine("reconcile");
    view.open = outputOf(start, "browser_open") ?? view.open;
    view.run_code = outputOf(start, "browser_run_code") ?? view.run_code;
    view.release = outputOf(start, "browser_release") ?? view.release;
    view.old_handle = outputOf(reconcile, "browser_action") ?? view.old_handle;
    view.status = outputOf(reconcile, "browser_status") ?? view.status;
    view.reconcile_release = outputOf(reconcile, "browser_release") ?? view.reconcile_release;
    this.views.set(caseId, view);
  }
}

type ResponseItem = { id: string; type: "message"; role: "assistant"; status: "completed"; content: [{ type: "output_text"; text: string; annotations: [] }] }
  | { id: string; type: "function_call"; call_id: string; name: string; arguments: string; status: "completed" }
  | { id: string; type: "custom_tool_call"; call_id: string; name: string; input: string; status: "completed" };

function codemodeScript(tool: string, args: Record<string, unknown>): string {
  // Code mode discovers deferred tools with its searchTools global rather than a tool_search tool.
  const call = tool === "tool_search" ? `searchTools(${JSON.stringify(args.query)}, { limit: ${Number(args.limit)} })`
    : `tools.${tool}(${JSON.stringify(args)})`;
  return `let text = "", rejected = false;
try { const value = await ${call}; text = typeof value === "string" ? value : JSON.stringify(value); }
catch (error) { rejected = true; text = String(error && error.message ? error.message : error); }
return "labresult:" + encodeURIComponent(JSON.stringify({ rejected, text: String(text).slice(0, 12000) })) + ":end";`;
}

function responseItem(body: Record<string, unknown>, step: Step): ResponseItem {
  const id = randomUUID();
  if ("text" in step) return { id, type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: step.text, annotations: [] }] };
  const updates = Array.isArray(body.input) ? body.input.flatMap((item: unknown) => isRecord(item) && item.type === "additional_tools"
    && Array.isArray(item.tools) ? item.tools : []) : [];
  const declared = new Map([...(Array.isArray(body.tools) ? body.tools : []), ...updates].flatMap((tool: unknown) =>
    isRecord(tool) && typeof tool.name === "string" ? [[tool.name, tool.type] as const] : []));
  if (declared.has(step.tool)) return { id, type: "function_call", call_id: id, name: step.tool, arguments: JSON.stringify(step.args), status: "completed" };
  const codemode = declared.get("codemode");
  if (codemode === undefined) {
    return { id, type: "message", role: "assistant", status: "completed",
      content: [{ type: "output_text", text: `UNEXPECTED: ${step.tool} is not offered.`, annotations: [] }] };
  }
  const code = codemodeScript(step.tool, step.args);
  return codemode === "custom" ? { id, type: "custom_tool_call", call_id: id, name: "codemode", input: code, status: "completed" }
    : { id, type: "function_call", call_id: id, name: "codemode", arguments: JSON.stringify({ code }), status: "completed" };
}

function events(body: Record<string, unknown>, step: Step): string {
  const item = responseItem(body, step);
  const response = { id: randomUUID(), object: "response", created_at: Math.floor(Date.now() / 1000), model: String(body.model ?? "gpt-4.1") };
  const frames = [
    { type: "response.created", response: { ...response, status: "in_progress", output: [] } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, status: "in_progress",
      ...(item.type === "message" ? { content: [] } : item.type === "custom_tool_call" ? { input: "" } : { arguments: "" }) } },
    ...(item.type === "message" ? [
      { type: "response.content_part.added", item_id: item.id, output_index: 0, content_index: 0, part: { type: "output_text", text: "", annotations: [] } },
      { type: "response.output_text.delta", item_id: item.id, output_index: 0, content_index: 0, delta: item.content[0].text },
      { type: "response.output_text.done", item_id: item.id, output_index: 0, content_index: 0, text: item.content[0].text },
    ] : item.type === "custom_tool_call" ? [
      { type: "response.custom_tool_call_input.delta", item_id: item.id, output_index: 0, delta: item.input },
      { type: "response.custom_tool_call_input.done", item_id: item.id, output_index: 0, input: item.input },
    ] : [
      { type: "response.function_call_arguments.delta", item_id: item.id, output_index: 0, delta: item.arguments },
      { type: "response.function_call_arguments.done", item_id: item.id, output_index: 0, arguments: item.arguments },
    ]),
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: { ...response, status: "completed", output: [item], usage: { input_tokens: 1, output_tokens: 1,
      total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } },
  ];
  return frames.map((frame) => "data: " + JSON.stringify(frame) + "\n\n").join("");
}

export type TaskEntry = { id: string; conversation_id: string; title: string };
export type SendOutcome =
  | { type: "dispatched"; input_id: string }
  | { type: "accepted_dispatch_failed"; input_id: string; error: string };
export type CoordinatorOptions = { beepBoop: string; rex: string; modelPort: number; nodeName: string; browserConfig: string;
  logFile: string; scanner: SecretScanner; cliLog: string };

export class PrivateCoordinator {
  private serve: ChildProcess | undefined;
  private rexServer: ChildProcess | undefined;

  private constructor(readonly dir: string, private readonly options: CoordinatorOptions) {}

  static create(options: CoordinatorOptions): PrivateCoordinator {
    // Short paths keep the Unix sockets under the platform limit.
    const dir = mkdtempSync("/tmp/chrome-lifecycle-");
    for (const sub of ["home", "state", "rex-state", "bin", "tmp"]) mkdirSync(join(dir, sub), { recursive: true, mode: 0o700 });
    symlinkSync(join(options.rex, "bin", "rex"), join(dir, "bin", "rex"));
    writeFileSync(join(dir, "AGENTS.md"), "Use only invented test data.\n");
    writeFileSync(join(dir, "config.toml"), `node_name = "${options.nodeName}"
context_repositories = []
job_directories = []
sources = []

[model]
provider = "azure"
model_id = "gpt-4.1"
fast = false
${options.browserConfig}`);
    return new PrivateCoordinator(dir, options);
  }

  get socket(): string { return join(this.dir, "state", "agent.sock"); }
  private get rexSocket(): string { return join(this.dir, "rex.sock"); }

  private env(): NodeJS.ProcessEnv {
    const home = join(this.dir, "home");
    return { PATH: `${join(this.dir, "bin")}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: home, TMPDIR: join(this.dir, "tmp") + "/",
      XDG_CONFIG_HOME: join(home, ".config"), XDG_DATA_HOME: join(home, ".local", "share"), XDG_STATE_HOME: join(home, ".local", "state"),
      XDG_CACHE_HOME: join(home, ".cache"), LANG: "en_US.UTF-8", AZURE_OPENAI_API_KEY: "invented-acceptance-key",
      AZURE_OPENAI_BASE_URL: `http://127.0.0.1:${this.options.modelPort}/v1` };
  }

  private launch(program: string, args: string[]): ChildProcess {
    const log = openSync(this.options.logFile, "a");
    try {
      const child = spawn(program, args, { cwd: join(this.dir, "home"), env: this.env(), detached: true, stdio: ["ignore", log, log] });
      child.unref();
      return child;
    } finally { closeSync(log); }
  }

  private get globalArgs(): string[] {
    return ["--state-dir", join(this.dir, "state"), "--config", join(this.dir, "config.toml"), "--rex-server", `unix://${this.rexSocket}`];
  }

  get logFile(): string { return this.options.logFile; }

  async start(): Promise<void> {
    if (this.rexServer === undefined) {
      this.rexServer = this.launch(join(this.options.rex, "bin", "rex"),
        ["server", "run", "--listen", `unix://${this.rexSocket}`, "--state-dir", join(this.dir, "rex-state"), "--restore=false"]);
      await waitFor("the private Rex socket", 30_000, () => existsSync(this.rexSocket) ? true : undefined, 250);
    }
    const serve = this.launch(join(this.options.beepBoop, "bin", "beep-boop"),
      [...this.globalArgs, "--instructions", join(this.dir, "AGENTS.md"), "serve", "--local-only", "--no-sources"]);
    this.serve = serve;
    await waitFor("the lab coordinator socket", 60_000, async () => {
      if (serve.exitCode !== null || serve.signalCode !== null) throw new Error(`the lab coordinator exited ${serve.exitCode ?? serve.signalCode}; see ${this.options.logFile}`);
      return await socketAccepts(this.socket) ? true : undefined;
    }, 200);
    await waitFor(`${this.options.nodeName} online`, 90_000, async () => await this.online(this.options.nodeName) ? true : undefined, 1000);
  }

  pid(): number | null {
    const pid = this.serve?.pid;
    return pid !== undefined && this.serve?.exitCode === null && this.serve.signalCode === null ? pid : null;
  }

  async kill(): Promise<number> {
    const serve = this.serve, pid = serve?.pid;
    if (serve === undefined || pid === undefined) throw new Error("The lab coordinator is not running");
    const exited = new Promise<void>((resolve) => { if (serve.exitCode !== null || serve.signalCode !== null) resolve(); else serve.once("exit", () => resolve()); });
    process.kill(-pid, "SIGKILL");
    await exited;
    return pid;
  }

  private async invoke(args: string[], timeoutMs: number): Promise<{ stdout: string; failed: string | null }> {
    const program = join(this.options.beepBoop, "bin", "beep-boop");
    try {
      const { stdout } = await execFileAsync(program, [...this.globalArgs, ...args], { cwd: join(this.dir, "home"), env: this.env(),
        timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 });
      appendFileSync(this.options.cliLog, this.options.scanner.redact(JSON.stringify({ at: now(), args, stdout: stdout.slice(0, 20_000) })) + "\n");
      return { stdout, failed: null };
    } catch (error) {
      const stdout = isRecord(error) ? String(error.stdout ?? "") : "";
      const stderr = isRecord(error) ? String(error.stderr ?? "").trim() : String(error);
      appendFileSync(this.options.cliLog, this.options.scanner.redact(JSON.stringify({ at: now(), args, stdout: stdout.slice(0, 20_000),
        failed: stderr.slice(0, 4000) })) + "\n");
      return { stdout, failed: this.options.scanner.redact(stderr.slice(0, 4000)) };
    }
  }

  async cli(args: string[], timeoutMs: number): Promise<string> {
    const { stdout, failed } = await this.invoke(args, timeoutMs);
    if (failed !== null) throw new Error(`beep-boop ${args.slice(0, 2).join(" ")} failed: ${failed} ${this.options.scanner.redact(stdout.trim().slice(0, 2000))}`);
    return stdout;
  }

  chat(text: string): Promise<string> { return this.cli(["--json", "--no-tui", "chat", text], 240_000); }

  async send(taskId: string, text: string): Promise<SendOutcome> {
    const { stdout, failed } = await this.invoke(["--json", "--no-tui", "tasks", "send", taskId, text], 120_000);
    let inputId: string | null = null;
    for (const line of stdout.split("\n")) {
      let event: unknown;
      try { event = JSON.parse(line); } catch { continue; }
      if (isRecord(event) && event.type === "input_accepted" && typeof event.input_id === "string") inputId = event.input_id;
    }
    if (inputId === null) throw new Error(`tasks send ${taskId} did not accept the input: ${failed ?? "no input_accepted event"}`);
    return failed === null ? { type: "dispatched", input_id: inputId } : { type: "accepted_dispatch_failed", input_id: inputId, error: failed };
  }

  async tasks(): Promise<TaskEntry[]> {
    const lines = (await this.cli(["--json", "tasks", "list"], 60_000)).split("\n");
    for (const line of lines) {
      let event: unknown;
      try { event = JSON.parse(line); } catch { continue; }
      if (isRecord(event) && event.type === "tasks" && Array.isArray(event.tasks)) {
        return event.tasks.flatMap((task: unknown) => isRecord(task) && typeof task.id === "string"
          ? [{ id: task.id, conversation_id: String(task.conversation_id), title: String(task.title) }] : []);
      }
    }
    throw new Error("tasks list returned no task event");
  }

  async online(name: string): Promise<boolean> {
    const listed = await this.cli(["nodes"], 30_000).catch(() => "");
    return listed.split("\n").some((line) => new RegExp(`\\s${name}\\s+online\\s*$`).test(line));
  }

  async stop(): Promise<void> {
    const rex = join(this.options.rex, "bin", "rex");
    if (this.pid() !== null) await this.kill().catch(() => {});
    await execFileAsync(rex, ["-S", `unix://${this.rexSocket}`, "server", "stop"], { env: this.env(), timeout: 30_000 }).catch(() => {});
    const rexPid = this.rexServer?.pid;
    if (rexPid !== undefined && processAlive(rexPid)) { try { process.kill(-rexPid, "SIGTERM"); } catch { /* already gone */ } }
  }
}
