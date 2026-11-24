/**
 * Rex lab: the packaged beep-boop and its runtime against a private, disposable Rex server.
 * A scripted model drives Codemode through a delegated task worker and one of its agents.
 * They discover the Rex tools, read a marker from the child terminal the worker opened, and
 * are refused every target they do not own. Nothing here reaches the user's own Rex server.
 *
 *   node dist/test/acceptance/rex-lab.js --beep-boop <store path> --rex <store path> --evidence <dir>
 */
import { randomBytes } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { execFileAsync, isRecord, now, PrivateCoordinator, SecretScanner, waitFor } from "./chrome-lab.js";

type Step = { code: string } | { tool: string; args: Record<string, unknown> } | { text: string };
type Phase = "main" | "work" | "agent";
type Seen = { phase: Phase; step: number; at: number; declared: string[]; rexNamespace: boolean; rexSection: number; outputs: string[] };
type Out = Record<string, any>;

const { values } = parseArgs({ options: { "beep-boop": { type: "string" }, rex: { type: "string" }, evidence: { type: "string" }, keep: { type: "boolean" } } });
function required(value: string | undefined, flag: string): string {
  if (value === undefined) throw new Error("Pass --beep-boop, --rex and --evidence; " + flag + " is missing");
  return value;
}
const beepBoop = required(values["beep-boop"], "--beep-boop"), rexPath = required(values.rex, "--rex"), evidence = required(values.evidence, "--evidence");
mkdirSync(evidence, { recursive: true });

const tag = "rexlab-" + randomBytes(4).toString("hex");
const nonce = randomBytes(6).toString("hex");
const MARKER = "REXLAB_MARKER_" + nonce;
const key = (phase: Phase) => tag + ":" + phase;
const seen: Seen[] = [];
const finals = new Map<Phase, string>();
const ids: { decoySession?: string; decoyBlock?: string; inSession?: string; workerBlock?: string } = {};
let markReady: () => void = () => {};
const ready = new Promise<void>((resolve) => { markReady = resolve; });

function text(content: unknown): string {
  if (typeof content === "string") return content;
  return Array.isArray(content) ? content.flatMap((part: unknown) => isRecord(part) && typeof part.text === "string" ? [part.text] : []).join("\n") : "";
}
const OUT = /rexlab-out:([A-Za-z0-9\-_.!~*'()%]+):end/;
function decoded(output: string): Out | undefined {
  const match = OUT.exec(output);
  return match?.[1] === undefined ? undefined : JSON.parse(decodeURIComponent(match[1])) as Out;
}
/** A Codemode script: optional deadline, the lab's values as a JSON prelude, then the body. */
function script(lines: string[], timeoutMs?: number): Step {
  const prelude = [
    ...(timeoutMs === undefined ? [] : ["// @options: " + JSON.stringify({ timeout_ms: timeoutMs })]),
    "const lab = " + JSON.stringify({ ...ids, marker: MARKER, markerCommand: "printf 'REXLAB_MARKER_%s\\n' " + nonce }) + ";",
    "const attempt = async (name, args) => { try { return { ok: true, value: await tools[name](args) }; }",
    "  catch (error) { return { ok: false, message: String(error && error.message ? error.message : error).slice(0, 600) }; } };",
  ];
  return { code: [...prelude, ...lines, "return 'rexlab-out:' + encodeURIComponent(JSON.stringify(out)) + ':end';"].join("\n") };
}

function childOf(outs: string[]): string {
  return String(outs.map(decoded).find((value) => typeof value?.child === "string")?.child ?? "");
}

const WORK_MAIN = [
  "const out = {};",
  "out.search = (await searchTools('rex terminal write wait output split close', { limit: 30 })).map((tool) => tool.name);",
  "const namespace = await describeNamespace('rex');",
  "out.namespace = { name: namespace.name, tools: namespace.tools };",
  "out.describe = String(await describeTool('rex_terminals_writeLine')).slice(0, 400);",
  "const here = await tools.rex_here({});",
  "out.here = here;",
  "const sessionId = here.sessionId;",
  "out.version = await tools.rex_server_version({});",
  "const view = await tools.rex_sessions_view({ sessionId });",
  "out.viewBlocks = view.windows.flatMap((window) => window.layers.flatMap((layer) => layer.blocks.map((block) => block.blockId)));",
  "out.ownTail = (await tools.rex_terminals_readTail({ sessionId, blockId: here.blockId, maxBytes: 4096 })).lines.length;",
  "const split = await tools.rex_blocks_splitBeside({ sessionId, placement: 'right', layout: { _tag: 'Terminal', label: 'rexlab-child' } });",
  "out.split = split;",
  "const child = split.blockIds[0];",
  "out.child = child;",
  "const written = await tools.rex_terminals_writeLine({ sessionId, blockId: child, text: lab.markerCommand });",
  "out.marker = await tools.rex_terminals_waitForOutput({ sessionId, blockId: child, since: written.markId, match: { type: 'substring', value: lab.marker }, timeoutMs: 30000 });",
  "out.childTail = (await tools.rex_terminals_readTail({ sessionId, blockId: child, maxBytes: 8192 })).lines.filter((line) => line.includes(lab.marker));",
  "const started = Date.now();",
  "const quietMark = (await tools.rex_terminals_mark({ sessionId, blockId: child })).markId;",
  "out.boundedWait = await tools.rex_terminals_waitForOutput({ sessionId, blockId: child, since: quietMark, match: { type: 'substring', value: 'REXLAB_NEVER_PRINTED' }, timeoutMs: 1500 });",
  "out.boundedWaitMs = Date.now() - started;",
  "out.refused = {",
  "  readDecoySession: await attempt('rex_terminals_readTail', { sessionId: lab.decoySession, blockId: lab.decoyBlock }),",
  "  viewDecoySession: await attempt('rex_sessions_view', { sessionId: lab.decoySession }),",
  "  writeDecoySession: await attempt('rex_terminals_writeLine', { sessionId: lab.decoySession, blockId: lab.decoyBlock, text: 'printf DECOY_TOUCHED' }),",
  "  readUnownedInSession: await attempt('rex_terminals_readTail', { sessionId, blockId: lab.inSession }),",
  "  writeUnownedInSession: await attempt('rex_terminals_writeLine', { sessionId, blockId: lab.inSession, text: 'printf INSESSION_TOUCHED' }),",
  "  closeUnownedInSession: await attempt('rex_blocks_close', { sessionId, blockId: lab.inSession }),",
  "  writeOwnTerminal: await attempt('rex_terminals_writeLine', { sessionId, blockId: here.blockId, text: 'printf OWN_TOUCHED' }),",
  "  closeOwnTerminal: await attempt('rex_blocks_close', { sessionId, blockId: here.blockId }),",
  "  splitByWindow: await attempt('rex_blocks_splitBeside', { sessionId, windowId: here.windowId, placement: 'below' }),",
  "  splitBesideUnowned: await attempt('rex_blocks_splitBeside', { sessionId, anchorId: lab.inSession, placement: 'below' }),",
  "  splitNonTerminal: await attempt('rex_blocks_splitBeside', { sessionId, placement: 'below', layout: { _tag: 'Block', flavor: 'com.superlogical.tunnel' } }),",
  "  overlongWait: await attempt('rex_terminals_waitForExit', { sessionId, blockId: child, timeoutMs: 900000 }),",
  "  serverStop: await attempt('rex_server_stop', {}),",
  "  sessionsCreate: await attempt('rex_sessions_create', { label: 'rexlab-forbidden' }),",
  "  callMethod: await attempt('rex_blocks_callMethod', { sessionId, blockId: child, method: 'com.superlogical.terminal.write' }),",
  "};",
  // Starting a terminal takes longer than 1 ms, so this split has no receipt although it may have happened.
  "out.uncertainWrite = await attempt('rex_blocks_splitBeside', { sessionId, anchorId: child, placement: 'below', requestTimeoutMs: 1 });",
  "out.fencedWrite = await attempt('rex_terminals_writeLine', { sessionId, blockId: child, text: 'printf REXLAB_FENCED' });",
  "out.hereUncertain = await tools.rex_here({});",
  "out.viewAfterUncertain = (await tools.rex_sessions_view({ sessionId })).windows.flatMap((window) => window.layers.flatMap((layer) => layer.blocks.map((block) => block.blockId)));",
  "out.wrongClear = await attempt('rex_here', { clearUncertain: 'not-the-uncertain-write' });",
  "out.cleared = await tools.rex_here({ clearUncertain: out.hereUncertain.uncertain.id });",
  "out.afterClear = await attempt('rex_terminals_writeLine', { sessionId, blockId: child, text: 'printf REXLAB_AFTER' });",
];

const SCRIPTS: Record<Phase, ((outs: string[]) => Promise<Step> | Step)[]> = {
  main: [
    () => ({ tool: "tool_search", args: { query: "rex terminal sessions blocks splitBeside", limit: 8 } }),
    () => ({ tool: "delegate_task", args: { title: "Rex lab " + tag, outcome: "Exercise Rex terminals through Codemode",
      input: key("work") + " Open a child terminal, print the lab marker in it and read it back.", host: "rexlab", new_task: true,
      new_task_reason: "Independent acceptance case" } }),
    () => ({ text: "Delegated the Rex lab." }),
  ],
  work: [
    async () => { await ready; return script(WORK_MAIN, 150_000); },
    // The script's own deadline cancels a long wait on the open child terminal.
    (outs) => script(["const here = await tools.rex_here({});",
      "await tools.rex_terminals_waitForOutput({ sessionId: here.sessionId, blockId: " + JSON.stringify(childOf(outs)) + ", match: { type: 'substring', value: 'REXLAB_NEVER_PRINTED' }, timeoutMs: 120000 });",
      "const out = { cancelled: false };"], 3000),
    () => script(["const here = await tools.rex_here({});",
      "const out = { here, tail: await attempt('rex_terminals_readTail', { sessionId: here.sessionId, blockId: here.blockId, maxBytes: 2048 }) };"]),
    () => ({ tool: "spawn_agent", args: { title: "Rex lab agent " + tag, outcome: "Show an agent reaches only its own Rex terminal",
      input: key("agent") + " Inspect your Rex terminal." } }),
    () => script(["let out = { agents: 'agent did not finish' };",
      "for (let i = 0; i < 4; i++) { const read = await tools.wait_agents({ timeout_seconds: 45 });",
      "  if (String(read).includes('\"state\":\"done\"')) { out = { agents: String(read).slice(0, 3000) }; break; } }"], 200_000),
    () => script(["const here = await tools.rex_here({});",
      "const out = { closed: [] };",
      "for (const blockId of here.children) out.closed.push(await attempt('rex_blocks_close', { sessionId: here.sessionId, blockId }));",
      "out.here = await tools.rex_here({});"]),
    () => ({ tool: "record_task", args: { summary: "Rex lab finished.", state: { state: "resolved", evidence: "The Rex lab scripts ran; the lab checks their results." } } }),
    () => ({ text: "Rex lab work finished." }),
  ],
  agent: [
    () => script(["const here = await tools.rex_here({});",
      "const out = { here,",
      "  readParentTerminal: await attempt('rex_terminals_readTail', { sessionId: here.sessionId, blockId: lab.workerBlock }),",
      "  writeParentTerminal: await attempt('rex_terminals_writeLine', { sessionId: here.sessionId, blockId: lab.workerBlock, text: 'printf PARENT_TOUCHED' }),",
      "  readDecoy: await attempt('rex_terminals_readTail', { sessionId: lab.decoySession, blockId: lab.decoyBlock }),",
      "  ownTail: await attempt('rex_terminals_readTail', { sessionId: here.sessionId, blockId: here.blockId, maxBytes: 2048 }) };"]),
    () => ({ tool: "report_result", args: { summary: "Rex lab agent inspected its terminal." } }),
    () => ({ text: "Rex lab agent finished." }),
  ],
};

function toolOutputs(input: unknown[], from: number): string[] {
  return input.slice(from).flatMap((item: unknown) => isRecord(item) && (item.type === "function_call_output" || item.type === "custom_tool_call_output")
    ? [typeof item.output === "string" ? item.output : text(item.output)] : []);
}

async function handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
  let raw = "";
  request.setEncoding("utf8");
  for await (const chunk of request) raw += String(chunk);
  const body: unknown = JSON.parse(raw);
  if (!isRecord(body) || !Array.isArray(body.input)) { response.writeHead(400).end(); return; }
  const input: unknown[] = body.input;
  let index = -1, phase: Phase | undefined;
  input.forEach((item, position) => {
    if (!isRecord(item) || item.role !== "user") return;
    const found = (["main", "work", "agent"] as const).find((candidate) => text(item.content).includes(key(candidate)));
    if (found !== undefined) { index = position; phase = found; }
  });
  const updates = input.flatMap((item) => isRecord(item) && item.type === "additional_tools" && Array.isArray(item.tools) ? item.tools : []);
  const declared = new Map([...(Array.isArray(body.tools) ? body.tools : []), ...updates].flatMap((tool: unknown) =>
    isRecord(tool) && typeof tool.name === "string" ? [[tool.name, String(tool.type)] as const] : []));
  const whole = JSON.stringify(body);
  const start = whole.indexOf("## rex\\n");
  const end = start < 0 ? -1 : [whole.indexOf("\\n\\n## ", start + 8), whole.indexOf("</codemode>", start)].filter((at) => at > 0).sort((a, b) => a - b)[0] ?? -1;
  const calls = phase === undefined ? 0 : input.slice(index).filter((item) => isRecord(item) && (item.type === "function_call" || item.type === "custom_tool_call")).length;
  const outs = phase === undefined ? [] : toolOutputs(input, index);
  if (phase !== undefined) seen.push({ phase, step: calls, at: Date.now(), declared: [...declared.keys()], rexNamespace: start >= 0,
    rexSection: start >= 0 && end > start ? end - start : 0, outputs: outs.map((output) => output.slice(0, 12_000)) });
  const builder = phase === undefined ? undefined : SCRIPTS[phase][calls];
  let step: Step = builder === undefined ? { text: "Rex lab step complete." } : await builder(outs);
  if ("tool" in step && !declared.has(step.tool) && !declared.has("codemode")) step = { text: "UNEXPECTED: " + step.tool + " is not offered." };
  if (phase !== undefined && "text" in step) finals.set(phase, step.text);
  response.writeHead(200, { "content-type": "text/event-stream" }).end(events(body, declared, step));
}

function events(body: Record<string, unknown>, declared: Map<string, string>, step: Step): string {
  const id = randomBytes(8).toString("hex");
  let item: Record<string, unknown> & { type: string };
  if ("text" in step) item = { id, type: "message", role: "assistant", status: "completed", content: [{ type: "output_text", text: step.text, annotations: [] }] };
  else if ("tool" in step && declared.has(step.tool)) item = { id, type: "function_call", call_id: id, name: step.tool, arguments: JSON.stringify(step.args), status: "completed" };
  else {
    const code = "code" in step ? step.code : "return await tools." + step.tool + "(" + JSON.stringify(step.args) + ");";
    item = declared.get("codemode") === "custom" ? { id, type: "custom_tool_call", call_id: id, name: "codemode", input: code, status: "completed" }
      : { id, type: "function_call", call_id: id, name: "codemode", arguments: JSON.stringify({ code }), status: "completed" };
  }
  const response = { id: randomBytes(8).toString("hex"), object: "response", created_at: Math.floor(Date.now() / 1000), model: String(body.model ?? "gpt-4.1") };
  const said = "text" in step ? step.text : "";
  const frames = [
    { type: "response.created", response: { ...response, status: "in_progress", output: [] } },
    { type: "response.output_item.added", output_index: 0, item: { ...item, status: "in_progress",
      ...(item.type === "message" ? { content: [] } : item.type === "custom_tool_call" ? { input: "" } : { arguments: "" }) } },
    ...(item.type === "message" ? [
      { type: "response.content_part.added", item_id: id, output_index: 0, content_index: 0, part: { type: "output_text", text: "", annotations: [] } },
      { type: "response.output_text.delta", item_id: id, output_index: 0, content_index: 0, delta: said },
      { type: "response.output_text.done", item_id: id, output_index: 0, content_index: 0, text: said },
    ] : item.type === "custom_tool_call" ? [
      { type: "response.custom_tool_call_input.delta", item_id: id, output_index: 0, delta: item.input },
      { type: "response.custom_tool_call_input.done", item_id: id, output_index: 0, input: item.input },
    ] : [
      { type: "response.function_call_arguments.delta", item_id: id, output_index: 0, delta: item.arguments },
      { type: "response.function_call_arguments.done", item_id: id, output_index: 0, arguments: item.arguments },
    ]),
    { type: "response.output_item.done", output_index: 0, item },
    { type: "response.completed", response: { ...response, status: "completed", output: [item], usage: { input_tokens: 1, output_tokens: 1,
      total_tokens: 2, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } },
  ];
  return frames.map((frame) => "data: " + JSON.stringify(frame) + "\n\n").join("");
}

const server = createServer((request, response) => { void handle(request, response).catch((error: unknown) => {
  console.error("model fixture failed", error); response.writeHead(500).end();
}); });
await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
if (address === null || typeof address === "string") throw new Error("The model fixture has no port");

const coordinator = PrivateCoordinator.create({ beepBoop, rex: rexPath, modelPort: address.port, nodeName: "rexlab", browserConfig: "",
  logFile: join(evidence, "coordinator.log"), scanner: new SecretScanner(), cliLog: join(evidence, "cli.jsonl") });
const socket = join(coordinator.dir, "rex.sock"), home = join(coordinator.dir, "home");
/** The Rex CLI against the lab's private server only. */
async function rex(args: string[]): Promise<string> {
  const { stdout } = await execFileAsync(join(rexPath, "bin", "rex"), ["-S", "unix://" + socket, "--autostart=false", ...args],
    { env: { PATH: "/usr/bin:/bin", HOME: home, XDG_RUNTIME_DIR: join(coordinator.dir, "tmp"), XDG_STATE_HOME: join(home, ".local", "state"),
      XDG_CONFIG_HOME: join(home, ".config") }, timeout: 30_000, maxBuffer: 16 * 1024 * 1024 });
  return stdout;
}
type Binding = { session_id: string; block_id: string; host_id: string; rex_instance_id?: string };
type TaskView = { title: string; state: { state: string }; worker: { state: string; binding?: Binding } };
async function labTask(): Promise<TaskView | undefined> {
  for (const line of (await coordinator.cli(["--json", "tasks", "list"], 60_000)).split("\n")) {
    let event: unknown;
    try { event = JSON.parse(line); } catch { continue; }
    if (isRecord(event) && event.type === "tasks" && Array.isArray(event.tasks)) return (event.tasks as TaskView[]).find((task) => task.title === "Rex lab " + tag);
  }
  return undefined;
}

const checks: { name: string; pass: boolean; observed: unknown }[] = [];
const check = (name: string, pass: boolean, observed: unknown) => { checks.push({ name, pass, observed }); };
const report: Record<string, unknown> = { tag, marker: MARKER, started_at: now() };
try {
  await coordinator.start();
  const decoy = JSON.parse(await rex(["new", "rexlab-decoy", "--json", "--", "sh", "-c", "printf 'DECOY_%s\\n' UNTOUCHED; exec sleep 3600"])) as
    { session_id: string; initial_windows: { block_ids: string[] }[] };
  ids.decoySession = decoy.session_id; ids.decoyBlock = required(decoy.initial_windows[0]?.block_ids[0], "the decoy block");
  await coordinator.chat(key("main") + " Delegate the Rex lab task.");
  const bound = await waitFor("the bound lab task", 90_000, async () => { const task = await labTask(); return task?.worker.state === "bound" ? task : undefined; }, 1000);
  const binding = bound.worker.binding!;
  ids.workerBlock = binding.block_id;
  const unowned = JSON.parse(await rex(["split", "-s", binding.session_id, "-b", binding.block_id, "--split", "below", "--focus=false", "--json", "--",
    "sh", "-c", "printf 'INSESSION_%s\\n' UNTOUCHED; exec sleep 3600"])) as { block_ids: string[] };
  ids.inSession = required(unowned.block_ids[0], "the unowned block");
  report.ids = { ...ids, worker_session: binding.session_id };
  markReady();
  await waitFor("the worker to finish", 300_000, () => finals.get("work"), 1000);
  await waitFor("the agent to finish", 60_000, () => finals.get("agent"), 1000);

  const work = seen.filter((entry) => entry.phase === "work");
  const at = (phase: Phase, step: number) => seen.find((entry) => entry.phase === phase && entry.step === step);
  const last = (entry: Seen | undefined) => entry?.outputs.map(decoded).filter((value) => value !== undefined).at(-1) ?? {};
  const main = last(at("work", 1)), afterCancel = last(at("work", 3)), closing = last(at("work", 6)), agent = last(at("agent", 1));
  const cancelIssued = at("work", 1), cancelEnded = at("work", 2);
  const cancel = { elapsed_ms: cancelIssued !== undefined && cancelEnded !== undefined ? cancelEnded.at - cancelIssued.at : null,
    output: cancelEnded?.outputs.at(-1)?.slice(0, 600) };
  Object.assign(report, { worker: main, after_cancel: afterCancel, closing, agent, cancel });

  const mainRequests = seen.filter((entry) => entry.phase === "main");
  check("main offers no Rex tools and no rex namespace", mainRequests.length > 0 && mainRequests.every((entry) =>
    !entry.declared.some((name) => name.startsWith("rex_")) && !entry.rexNamespace), mainRequests.map((entry) => entry.declared));
  const search = at("main", 1)?.outputs.at(-1) ?? "";
  check("main tool_search finds no Rex tool", search.length > 0 && !search.includes("rex_"), search.slice(0, 600));
  check("worker lists the rex namespace in Codemode, not as direct tools", work.length > 0 && work.every((entry) => entry.rexNamespace &&
    !entry.declared.some((name) => name.startsWith("rex_"))), work.map((entry) => ({ declared: entry.declared, section: entry.rexSection })));
  report.rex_section_chars = Math.max(0, ...work.map((entry) => entry.rexSection));
  const expected = ["rex_here", "rex_server_version", "rex_sessions_view", "rex_terminals_readTail", "rex_terminals_mark", "rex_terminals_waitForOutput",
    "rex_terminals_waitForQuiet", "rex_terminals_waitForExit", "rex_blocks_splitBeside", "rex_terminals_writeLine", "rex_terminals_write", "rex_blocks_close"].sort();
  check("describeNamespace('rex') lists exactly the allowlist", JSON.stringify([...(main.namespace?.tools ?? [])].sort()) === JSON.stringify(expected), main.namespace);
  check("searchTools finds Rex tools", Array.isArray(main.search) && main.search.includes("rex_terminals_writeLine"), main.search);
  check("rex_here is the task's bound terminal", main.here?.sessionId === binding.session_id && main.here?.blockId === binding.block_id, main.here);
  check("the marker was read from the child terminal", main.marker?.timedOut === false && String(main.marker?.match?.line ?? "").includes(MARKER)
    && Array.isArray(main.childTail) && main.childTail.length > 0, { marker: main.marker, tail: main.childTail });
  check("a short wait timed out within its bound", main.boundedWait?.timedOut === true && Number(main.boundedWaitMs) < 10_000,
    { wait: main.boundedWait, ms: main.boundedWaitMs });
  const refused = (main.refused ?? {}) as Record<string, { ok: boolean; message?: string }>;
  for (const [name, result] of Object.entries(refused)) check("refused: " + name, result.ok === false, result);
  check("all 15 refusal probes ran", Object.keys(refused).length === 15, Object.keys(refused));
  const owned = ["readDecoySession", "viewDecoySession", "writeDecoySession", "readUnownedInSession", "writeUnownedInSession", "closeUnownedInSession",
    "writeOwnTerminal", "closeOwnTerminal", "splitByWindow", "splitBesideUnowned", "splitNonTerminal", "overlongWait"];
  check("ownership refusals name RexNotOwned", owned.every((name) => String(refused[name]?.message ?? "").includes("RexNotOwned")),
    Object.fromEntries(owned.map((name) => [name, refused[name]?.message])));
  check("the split without a receipt was reported uncertain, not replayed, and fenced the next write", main.uncertainWrite?.ok === false
    && String(main.uncertainWrite?.message).includes("RexRequestTimeout") && String(main.uncertainWrite?.message).includes("uncertain")
    && main.fencedWrite?.ok === false && String(main.fencedWrite?.message).includes("was not replayed")
    && main.hereUncertain?.uncertain?.tool === "rex_blocks_splitBeside" && main.wrongClear?.ok === false && main.afterClear?.ok === true,
    { uncertain: main.uncertainWrite, fenced: main.fencedWrite, here: main.hereUncertain?.uncertain, wrongClear: main.wrongClear, afterClear: main.afterClear });
  const orphans = (main.viewAfterUncertain ?? []).filter((id: string) => ![binding.block_id, ids.inSession, main.child].includes(id));
  report.uncertain_split_orphans = orphans;
  check("the uncertain split was not recorded as owned before it was cleared", Array.isArray(main.hereUncertain?.children)
    && main.hereUncertain.children.length === 1 && orphans.every((id: string) => !main.hereUncertain.children.includes(id)),
    { children: main.hereUncertain?.children, orphans });
  const adopted = (main.cleared?.children ?? []).filter((id: string) => id !== main.child);
  check("clearing the uncertain split adopted exactly the terminal it opened, found by its label", orphans.length === 1
    && adopted.length === 1 && adopted[0] === orphans[0] && main.cleared?.unconfirmedTerminals === 0, { orphans, cleared: main.cleared });
  check("the cancelled script ended at its 3 s deadline, not the 120 s wait", cancel.elapsed_ms !== null && cancel.elapsed_ms >= 2_500
    && cancel.elapsed_ms < 20_000 && !String(cancel.output).includes("rexlab-out"), cancel);
  check("Rex tools still answer after the cancellation", afterCancel.tail?.ok === true, afterCancel.tail);
  check("the agent has its own terminal in the task session", typeof agent.here?.blockId === "string" && agent.here.blockId !== binding.block_id
    && agent.here.sessionId === binding.session_id, agent.here);
  for (const name of ["readParentTerminal", "writeParentTerminal", "readDecoy"]) {
    check("agent refused: " + name, agent[name]?.ok === false && String(agent[name]?.message).includes("RexNotOwned"), agent[name]);
  }
  check("the agent reads its own terminal", agent.ownTail?.ok === true, agent.ownTail);
  check("every child closed and left the actor's children", Array.isArray(closing.closed) && closing.closed.length === 2
    && closing.closed.every((result: { ok: boolean }) => result.ok) && Array.isArray(closing.here?.children) && closing.here.children.length === 0, closing);

  // Independent readback through the Rex CLI on the private server.
  const decoyScreen = await rex(["capture", "-s", ids.decoySession!, "-b", ids.decoyBlock!, "--trim"]);
  const unownedScreen = await rex(["capture", "-s", binding.session_id, "-b", ids.inSession!, "--trim"]);
  const viewText = await rex(["api", "call", "session.view", JSON.stringify({ session_id: binding.session_id })]);
  const status = JSON.parse(await rex(["api", "call", "server.status"])) as { instance_id: string; host_id: string };
  report.readback = { decoy: decoyScreen.slice(-300), unowned: unownedScreen.slice(-300), status: { instance_id: status.instance_id, host_id: status.host_id } };
  check("decoy session untouched", decoyScreen.includes("DECOY_UNTOUCHED") && !decoyScreen.includes("DECOY_TOUCHED") && !decoyScreen.includes("printf"), decoyScreen.slice(-300));
  check("unowned block in the task session untouched", unownedScreen.includes("INSESSION_UNTOUCHED") && !unownedScreen.includes("printf"), unownedScreen.slice(-300));
  check("unowned block in the task session still open", viewText.includes(ids.inSession!), ids.inSession);
  check("the closed children are gone from the session", typeof main.child === "string" && !viewText.includes(main.child)
    && orphans.every((id: string) => !viewText.includes(id)), { child: main.child, orphans });
  const childScreen = await rex(["capture", "-s", binding.session_id, "-b", binding.block_id, "--trim"]).catch((error: unknown) => String(error));
  check("the worker's own terminal received no lab writes", !childScreen.includes("OWN_TOUCHED") && !childScreen.includes("PARENT_TOUCHED"), childScreen.slice(-300));
  check("the task binding names this private Rex instance", binding.rex_instance_id === status.instance_id && binding.host_id === status.host_id,
    { binding, status: { instance_id: status.instance_id, host_id: status.host_id } });
  const resolved = await labTask();
  check("the task resolved", resolved?.state.state === "resolved", resolved?.state);
} catch (error) {
  check("lab ran to completion", false, error instanceof Error ? error.stack : String(error));
} finally {
  report.finished_at = now();
  report.checks = checks;
  report.requests = seen.map(({ outputs: _outputs, ...entry }) => entry);
  writeFileSync(join(evidence, "report.json"), JSON.stringify(report, null, 2));
  writeFileSync(join(evidence, "transcript.json"), JSON.stringify(seen, null, 2));
  await coordinator.stop();
  server.close();
  if (values.keep !== true) rmSync(coordinator.dir, { recursive: true, force: true });
}
const failed = checks.filter((entry) => !entry.pass);
for (const entry of checks) console.log((entry.pass ? "PASS " : "FAIL ") + entry.name);
console.log(JSON.stringify({ tag, checks: checks.length, failed: failed.length, evidence }));
process.exitCode = failed.length === 0 && checks.length > 0 ? 0 : 1;
