import { randomBytes } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { parseArgs } from "node:util";
import {
  CLEANUP_UNVERIFIED, EXTENSION_CONNECT_URL, InventedSite, PrivateCoordinator, ScriptedModel, SecretScanner, SITE_ORIGIN, labKey, labTaskTitle, now, savedLoginsForOrigin, waitFor,
  type CaseView, type LabCase, type Observed, type SendOutcome, type ToolOutcomeType,
} from "./chrome-lab.js";
import {
  createTarget, LEG_KINDS, type BrowserMode, type ChromeFacts, type Fault, type LegKind, type QuitEvidence, type Target, type TargetName,
} from "./chrome-targets.js";

const USAGE = `Usage:
  chrome-lifecycle prepare --target guest|local [--lab DIR]
  chrome-lifecycle run --target guest|local --legs relaunch,kill_helper,kill_service[,os_reboot] --evidence DIR [--lab DIR]

Environment: BEEP_BOOP and REX name the packaged store paths under test (run only).
CHROME_GUEST_LAB sets the default lab directory [~/.chrome-guest-lab].`;

type OwnedTabState = "closed" | "present_reported_uncertain" | "present_unreported";

export type LegRecord = {
  leg: LegKind;
  target: TargetName;
  browser_mode: BrowserMode;
  started_at: string;
  finished_at: string;
  boot: { before: number; after: number };
  chrome: { before: ChromeFacts; after: ChromeFacts; quit?: QuitEvidence };
  service: { before_pid: number | null; after_pid: number | null };
  autofill: { saved_logins_for_origin: number; autofilled_before_click: boolean };
  interrupted: {
    case_id: string; task_id: string; submissions_seen_before_fault: number; run_code_result_type: ToolOutcomeType;
    old_handle_result: ToolOutcomeType; status_result: ToolOutcomeType; release_result: ToolOutcomeType; replayed: boolean;
  };
  fresh: {
    case_id: string; task_id: string; signed_in_with_saved_password: boolean; submissions: number;
    release_result: ToolOutcomeType; tabs_left: number;
  };
  approvals_pending: number | "n/a";
  owned_tabs_after: { case_id: string; url: string; state: OwnedTabState }[];
  secret_exposed: boolean;
  passed: boolean;
  failures: string[];
};

type Lab = {
  target: Target; coordinator: PrivateCoordinator; site: InventedSite; model: ScriptedModel; scanner: SecretScanner;
  evidence: string; tag: string; log: (line: string) => void;
};

function passwordFile(lab: string, target: TargetName): string { return join(lab, "secrets", `site-password-${target}`); }

function typeOf(observed: Observed | null): ToolOutcomeType { return observed?.type ?? "absent"; }

function scriptResult(observed: Observed | null): Record<string, unknown> {
  try {
    const output: unknown = JSON.parse(observed?.output ?? "null");
    const value = typeof output === "object" && output !== null && "result" in output ? output.result : undefined;
    return typeof value === "object" && value !== null ? { ...value } : {};
  } catch { return {}; }
}

function message(error: unknown): string { return error instanceof Error ? error.message : String(error); }

async function prepare(targetName: TargetName, lab: string): Promise<void> {
  const target = createTarget(targetName, lab, join(lab, `${targetName}-prepare.log`));
  const password = `Invented-${randomBytes(18).toString("base64url")}`;
  try {
    const report = await target.prepare(password);
    if (report.saved_logins_for_origin !== 1) throw new Error(`Chrome kept ${report.saved_logins_for_origin} saved logins for ${SITE_ORIGIN}`);
    mkdirSync(join(lab, "secrets"), { recursive: true, mode: 0o700 });
    const file = passwordFile(lab, targetName);
    writeFileSync(`${file}.new`, password, { mode: 0o600 });
    renameSync(`${file}.new`, file);
    console.log(JSON.stringify({ ...report, password_file: file }));
  } finally { await target.close(); }
}

async function delegate(lab: Lab, labCase: LabCase): Promise<string> {
  lab.model.add(labCase);
  await lab.coordinator.chat(`${labKey(labCase.id, "delegate")} Delegate one invented acceptance case.`);
  return waitFor(`the task for ${labCase.id}`, 60_000, async () =>
    (await lab.coordinator.tasks()).find((task) => task.title === labTaskTitle(labCase.id))?.id, 2000);
}

function failFast(lab: Lab, caseId: string): void {
  const stop = lab.model.unexpected.find((entry) => entry.case_id === caseId);
  if (stop !== undefined) throw new Error(`scripted model stopped ${caseId}: ${stop.reason}`);
}

async function final(lab: Lab, labCase: LabCase, phase: keyof CaseView["finals"], timeoutMs: number): Promise<string> {
  return waitFor(`${labCase.id} ${phase} to finish`, timeoutMs, () => {
    failFast(lab, labCase.id);
    return lab.model.view(labCase.id).finals[phase];
  }, 1000);
}

async function runLeg(lab: Lab, kind: LegKind, fault: Fault): Promise<LegRecord> {
  const { target, coordinator, site, model, log } = lab;
  const slug = kind.replaceAll("_", "-");
  const a: LabCase = { id: `${lab.tag}-${slug}-a`, role: "interrupted", host: target.browserHost };
  const b: LabCase = { id: `${lab.tag}-${slug}-b`, role: "fresh", host: target.browserHost };
  model.leg = kind; site.leg = kind;
  const unexpectedBefore = model.unexpected.length, exposuresBefore = model.exposures.length;
  const failures: string[] = [];
  const started_at = now();
  let taskA = "", taskB = "", submissionsBeforeFault = 0, faultSeq = Number.MAX_SAFE_INTEGER;
  let quit: QuitEvidence | undefined;
  let reconcileSend: SendOutcome | null = null;

  log(`${kind}: before facts`);
  const before = { boot: await target.bootTime(), chrome: await target.chrome(), service: await target.servicePid() };
  let savedLogins = -1;
  try {
    const cdp = await target.cdp();
    try { savedLogins = await savedLoginsForOrigin(cdp); } finally { cdp.close(); }
  } catch (error) { failures.push(`saved logins unreadable: ${message(error)}`); }

  try {
    site.hold(a.id);
    log(`${kind}: delegating interrupted case ${a.id}`);
    taskA = await delegate(lab, a);
    await waitFor(`${a.id}'s submission`, 240_000, () => { failFast(lab, a.id); return site.count(a.id, "submitted") > 0 ? true : undefined; }, 250);
    submissionsBeforeFault = site.count(a.id, "submitted");
    faultSeq = site.seq;
    const ownerId = model.view(a.id).open?.owner_id;
    if (ownerId == null) throw new Error(`${a.id} has no browser owner in its browser_open output`);
    const context = { ownerId, coordinator, log };
    log(`${kind}: injecting fault`);
    const evidence = await fault.inject(context);
    if (evidence.quit !== undefined) quit = evidence.quit;
    log(`${kind}: ${evidence.detail}; releasing held responses`);
    site.release();
    await fault.recover(context);
    log(`${kind}: recovered`);
    if (fault.conversationSurvives) {
      await final(lab, a, "start", 240_000).catch((error: unknown) => { failures.push(`interrupted call never returned: ${message(error)}`); });
    }
    log(`${kind}: reconciling ${a.id}`);
    reconcileSend = await coordinator.send(taskA, `${labKey(a.id, "reconcile")} Reconcile the interrupted browser work before anything else.`);
    if (reconcileSend.type === "accepted_dispatch_failed") log(`${kind}: tasks send accepted input ${reconcileSend.input_id} but dispatch failed: ${reconcileSend.error}`);
    await final(lab, a, "reconcile", 480_000).catch((error: unknown) => { log(`${kind}: ${message(error)}; continuing with the fresh case`); });
    log(`${kind}: delegating fresh case ${b.id}`);
    taskB = await delegate(lab, b);
    await final(lab, b, "start", 360_000);
  } catch (error) {
    failures.push(`leg stopped: ${message(error)}`);
  } finally { site.release(); }

  log(`${kind}: observing`);
  const after = {
    boot: await target.bootTime().catch(() => 0), chrome: await target.chrome().catch((): ChromeFacts => ({ pid: null, data_root: null })),
    service: await target.servicePid().catch(() => null),
  };
  const viewA = model.view(a.id), viewB = model.view(b.id);
  let pages: { url: string; targetId: string }[] = [], connectors = 0;
  try {
    const cdp = await target.cdp();
    try {
      const listed = await cdp.targets();
      pages = listed.filter((entry) => entry.type === "page" && entry.url.startsWith(SITE_ORIGIN));
      connectors = listed.filter((entry) => entry.url.startsWith(EXTENSION_CONNECT_URL)).length;
      for (const page of pages) await cdp.closeTarget(page.targetId).catch(() => {});
    } finally { cdp.close(); }
  } catch (error) { failures.push(`tabs unobservable: ${message(error)}`); }
  const tabsOf = (caseId: string) => pages.filter((page) => new URL(page.url).searchParams.get("case") === caseId);
  const ownedTabs = (labCase: LabCase, replies: (Observed | null)[]) => {
    const present = tabsOf(labCase.id);
    const reported = replies.some((reply) => reply !== null && reply.type !== "closed" &&
      `${reply.message} ${reply.output ?? ""}`.includes(CLEANUP_UNVERIFIED));
    const state: OwnedTabState = reported ? "present_reported_uncertain" : "present_unreported";
    const opened = model.view(labCase.id).open?.tabs[0]?.url ?? `${SITE_ORIGIN}/login?case=${labCase.id}`;
    return present.length === 0 ? [{ case_id: labCase.id, url: opened, state: "closed" as const }]
      : present.map((page) => ({ case_id: labCase.id, url: page.url, state }));
  };
  const lateA = site.after(a.id, faultSeq);
  const freshScript = scriptResult(viewB.run_code);
  const exposed = model.exposures.length > exposuresBefore;

  const record: LegRecord = {
    leg: kind, target: target.name, browser_mode: target.mode, started_at, finished_at: now(),
    boot: { before: before.boot, after: after.boot },
    chrome: { before: before.chrome, after: after.chrome, ...(quit === undefined ? {} : { quit }) },
    service: { before_pid: before.service, after_pid: after.service },
    autofill: { saved_logins_for_origin: savedLogins, autofilled_before_click: freshScript.autofilled === true },
    interrupted: {
      case_id: a.id, task_id: taskA, submissions_seen_before_fault: submissionsBeforeFault, run_code_result_type: typeOf(viewA.run_code),
      old_handle_result: typeOf(viewA.old_handle), status_result: typeOf(viewA.status), release_result: typeOf(viewA.reconcile_release),
      replayed: site.count(a.id, "submitted") > 1 || site.count(a.id, "signed_in") > 1,
    },
    fresh: {
      case_id: b.id, task_id: taskB, signed_in_with_saved_password: site.signedInWithSavedPassword(b.id),
      submissions: site.count(b.id, "submitted"), release_result: typeOf(viewB.release), tabs_left: tabsOf(b.id).length,
    },
    approvals_pending: target.mode === "extension" ? connectors : "n/a",
    owned_tabs_after: [...ownedTabs(a, [viewA.status, viewA.reconcile_release]), ...ownedTabs(b, [viewB.release])],
    secret_exposed: exposed,
    passed: false,
    failures,
  };

  const changed = { boot: before.boot !== after.boot, chrome: before.chrome.pid !== after.chrome.pid, service: before.service !== after.service };
  const checks: [boolean, string][] = [
    [savedLogins === 1, `expected one saved login for ${SITE_ORIGIN}, saw ${savedLogins}`],
    [before.chrome.data_root === after.chrome.data_root && after.chrome.pid !== null, `Chrome after the leg is ${after.chrome.pid ?? "not running"} on ${after.chrome.data_root ?? "the default data root"}`],
    ...(["boot", "chrome", "service"] as const).map((key): [boolean, string] =>
      [changed[key] === (fault.expect[key] === "changed"), `${key} was expected to ${fault.expect[key] === "changed" ? "change" : "stay the same"}`]),
    [kind !== "relaunch" || quit?.ordinary === true, `relaunch did not end Chrome with an ordinary Quit: ${quit?.proof ?? "no quit evidence"}`],
    [site.signedInWithSavedPassword(a.id), `${a.id} did not sign in with the saved password`],
    [submissionsBeforeFault === 1, `${a.id} had ${submissionsBeforeFault} submissions when the fault was injected`],
    [record.interrupted.run_code_result_type !== "ready", `${a.id}'s interrupted run_code reported success`],
    [record.interrupted.old_handle_result !== "ready" && record.interrupted.old_handle_result !== "absent", `${a.id}'s old tab handle returned ${record.interrupted.old_handle_result}`],
    [record.interrupted.status_result !== "absent", `${a.id}'s browser_status was never answered`],
    [record.interrupted.release_result !== "absent", `${a.id}'s browser_release was never answered`],
    [viewA.finals.reconcile !== undefined, `${a.id}'s reconcile turn never finished${reconcileSend?.type === "accepted_dispatch_failed"
      ? ` after tasks send accepted input ${reconcileSend.input_id} and reported: ${reconcileSend.error}` : ""}`],
    [lateA.length === 0, `${a.id} sent ${lateA.length} site requests after the fault: ${lateA.map((entry) => `${entry.method} ${entry.path}`).join(", ")}`],
    [!record.interrupted.replayed, `${a.id}'s effect was replayed`],
    [record.fresh.signed_in_with_saved_password, `${b.id} did not sign in with the saved password`],
    [record.autofill.autofilled_before_click, `${b.id}'s password field was not autofilled before the click`],
    [record.fresh.submissions === 1, `${b.id} submitted ${record.fresh.submissions} times`],
    [record.fresh.release_result === "closed" && (viewB.release?.tabs.length ?? 1) === 0, `${b.id}'s release returned ${record.fresh.release_result}`],
    [record.fresh.tabs_left === 0, `${b.id} left ${record.fresh.tabs_left} tabs open`],
    [record.owned_tabs_after.every((tab) => tab.case_id !== b.id || tab.state === "closed"), `${b.id} has an owned tab after release`],
    [record.owned_tabs_after.every((tab) => tab.state !== "present_unreported"),
      `a tab is still open but its conversation was never told that "${CLEANUP_UNVERIFIED}"`],
    [record.approvals_pending === "n/a" || record.approvals_pending === 0, `${String(record.approvals_pending)} extension approval tabs are open`],
    [!exposed, "a model request contained the invented password or the pairing token"],
    ...model.unexpected.slice(unexpectedBefore).map((entry): [boolean, string] => [false, `unexpected model request (${entry.case_id ?? "no case"} ${entry.phase ?? ""}): ${entry.reason}`]),
  ];
  failures.push(...checks.filter(([ok]) => !ok).map(([, text]) => text));
  record.passed = failures.length === 0;
  appendFileSync(join(lab.evidence, "cases.jsonl"), lab.scanner.redact(JSON.stringify({ leg: kind, cases: { [a.id]: viewA, [b.id]: viewB },
    reconcile_send: reconcileSend, late_requests: lateA })) + "\n");
  return record;
}

function summary(records: LegRecord[], targetName: TargetName): string {
  const rows = records.map((record) => `| ${record.leg} | ${record.passed ? "pass" : "FAIL"} | ${record.boot.before === record.boot.after ? "same" : "changed"} | `
    + `${record.chrome.before.pid ?? "-"} → ${record.chrome.after.pid ?? "-"} | ${record.service.before_pid ?? "-"} → ${record.service.after_pid ?? "-"} | `
    + `${record.interrupted.run_code_result_type} / ${record.interrupted.old_handle_result} / ${record.interrupted.status_result} / ${record.interrupted.release_result} | `
    + `${record.interrupted.replayed ? "yes" : "no"} | ${record.fresh.submissions} / ${record.fresh.release_result} / ${record.fresh.tabs_left} | `
    + `${record.owned_tabs_after.map((tab) => tab.state).join(", ")} | ${record.failures.join("; ").replaceAll("|", "\\|") || "none"} |`);
  return [`# Chrome lifecycle acceptance: ${targetName}`, "",
    "| Leg | Verdict | Boot | Chrome pid | Service pid | A: run_code / old handle / status / release | A replayed | B: submissions / release / tabs left | Owned tabs | Failures |",
    "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |", ...rows, ""].join("\n");
}

async function run(targetName: TargetName, legs: LegKind[], evidence: string, labDir: string): Promise<boolean> {
  const beepBoop = process.env.BEEP_BOOP, rex = process.env.REX;
  if (beepBoop === undefined || rex === undefined) throw new Error("Set BEEP_BOOP and REX to the packaged store paths under test");
  const file = passwordFile(labDir, targetName);
  if (!existsSync(file)) throw new Error(`No invented password at ${file}; run prepare --target ${targetName} first`);
  mkdirSync(evidence, { recursive: true });
  const driverLog = join(evidence, "driver.log");
  const log = (line: string) => { const entry = `${now()} ${line}`; console.error(entry); appendFileSync(driverLog, entry + "\n"); };
  const target = createTarget(targetName, labDir, join(evidence, "chrome.log"));
  const missing = legs.filter((leg) => target.faults[leg] === undefined);
  if (missing.length > 0) throw new Error(`${targetName} has no ${missing.join(", ")} leg`);
  const password = readFileSync(file, "utf8");
  const scanner = new SecretScanner();
  scanner.add(password);
  for (const secret of await target.secrets()) scanner.add(secret);
  if (!scanner.exposed(`form=${encodeURIComponent(password)}`)) throw new Error("The secret scanner does not detect the invented password");
  const site = new InventedSite(password, join(evidence, "site.jsonl"));
  const model = new ScriptedModel(scanner, join(evidence, "model.jsonl"));
  await site.start();
  await model.start();
  let coordinator: PrivateCoordinator | undefined;
  const records: LegRecord[] = [];
  try {
    const browserConfig = await target.browserConfig();
    coordinator = PrivateCoordinator.create({ beepBoop, rex, modelPort: model.port, nodeName: "lab-coordinator", browserConfig,
      logFile: join(evidence, "coordinator.log"), scanner, cliLog: join(evidence, "cli.jsonl") });
    log(`lab coordinator in ${coordinator.dir}`);
    await coordinator.start();
    await target.connect(coordinator, log);
    const lab: Lab = { target, coordinator, site, model, scanner, evidence, tag: randomBytes(3).toString("hex"), log };
    for (const leg of legs) {
      const fault = target.faults[leg];
      if (fault === undefined) continue;
      const record = await runLeg(lab, leg, fault);
      records.push(record);
      appendFileSync(join(evidence, "ledger.jsonl"), JSON.stringify(record) + "\n");
      log(`${leg}: ${record.passed ? "PASS" : `FAIL ${record.failures.join("; ")}`}`);
    }
  } finally {
    writeFileSync(join(evidence, "summary.md"), summary(records, targetName));
    writeFileSync(join(evidence, "host-diagnostics.txt"), scanner.redact(await target.diagnostics()));
    await target.close();
    await coordinator?.stop();
    await site.stop();
    await model.stop();
    const coordinatorLog = join(evidence, "coordinator.log");
    if (existsSync(coordinatorLog)) {
      const text = readFileSync(coordinatorLog, "utf8");
      if (scanner.exposed(text)) { writeFileSync(coordinatorLog, scanner.redact(text)); log("coordinator.log contained a secret; redacted in place"); }
    }
  }
  return records.length === legs.length && records.every((record) => record.passed);
}

async function main(): Promise<number> {
  const { positionals, values } = parseArgs({ allowPositionals: true, options: {
    target: { type: "string" }, legs: { type: "string" }, evidence: { type: "string" }, lab: { type: "string" }, help: { type: "boolean" },
  } });
  const command = positionals[0];
  if (values.help === true || command === undefined) { console.log(USAGE); return command === undefined && values.help !== true ? 2 : 0; }
  const targetName = values.target;
  if (targetName !== "guest" && targetName !== "local") { console.error(USAGE); return 2; }
  const labDir = resolve(values.lab ?? process.env.CHROME_GUEST_LAB ?? join(homedir(), ".chrome-guest-lab"));
  if (command === "prepare") { await prepare(targetName, labDir); return 0; }
  if (command !== "run" || values.evidence === undefined || values.legs === undefined) { console.error(USAGE); return 2; }
  const legs = values.legs.split(",").map((leg) => leg.trim());
  const unknown = legs.filter((leg) => !LEG_KINDS.includes(leg as LegKind));
  if (unknown.length > 0) { console.error(`Unknown legs: ${unknown.join(", ")}\n${USAGE}`); return 2; }
  return await run(targetName, legs as LegKind[], resolve(values.evidence), labDir) ? 0 : 1;
}

main().then((code) => { process.exitCode = code; }, (error: unknown) => { console.error(message(error)); process.exitCode = 1; });
