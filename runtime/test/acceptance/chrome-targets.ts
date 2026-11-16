import { spawn, type ChildProcess } from "node:child_process";
import { closeSync, existsSync, mkdirSync, openSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { chromium } from "playwright-core";
import {
  CdpClient, execFileAsync, freePort, isRecord, LAB_TASK_TITLE_PREFIX, portAccepts, processAlive, replaceSavedLogin, waitFor, type PrivateCoordinator,
} from "./chrome-lab.js";

export type LegKind = "relaunch" | "kill_helper" | "kill_service" | "os_reboot";
export const LEG_KINDS: readonly LegKind[] = ["relaunch", "kill_helper", "kill_service", "os_reboot"];
export type TargetName = "guest" | "local";
export type BrowserMode = "extension" | "native_cdp";
export type ChromeFacts = { pid: number | null; data_root: string | null };
export type Change = "same" | "changed";
export type Expectation = { boot: Change; chrome: Change; service: Change };
export type FaultContext = { ownerId: string; coordinator: PrivateCoordinator; log: (line: string) => void };
export type QuitEvidence = { ordinary: boolean; proof: string; exit_type: string | null };
export type FaultEvidence = { detail: string; quit?: QuitEvidence };
export type Fault = {
  expect: Expectation;
  conversationSurvives: boolean;
  inject(context: FaultContext): Promise<FaultEvidence>;
  recover(context: FaultContext): Promise<void>;
};
export type PrepareReport = { target: TargetName; saved_logins_for_origin: number; token_written: boolean };

export interface Target {
  readonly name: TargetName;
  readonly mode: BrowserMode;
  readonly browserHost: string;
  readonly faults: Partial<Record<LegKind, Fault>>;
  prepare(password: string): Promise<PrepareReport>;
  browserConfig(): Promise<string>;
  connect(coordinator: PrivateCoordinator, log: (line: string) => void): Promise<void>;
  secrets(): Promise<string[]>;
  diagnostics(): Promise<string>;
  bootTime(): Promise<number>;
  chrome(): Promise<ChromeFacts>;
  servicePid(): Promise<number | null>;
  cdp(): Promise<CdpClient>;
  close(): Promise<void>;
}

const SAME: Change = "same", CHANGED: Change = "changed";
const AGENT_LABEL = "org.nixos.agent";
const GUEST_CHROME_ROOT = "/Users/admin/BeepBoopChrome";
const GUEST_CDP_PORT = 9333;
const GUEST_SOCKET = "/Users/admin/lab/coordinator.sock";
const GUEST_TOKEN = "~/lab/secrets/playwright-token";
const GUEST_REX = "/nix/var/nix/profiles/default/bin/rex --autostart=false";
const GUEST_HOST = "chrome-guest";
const LOCAL_HOST = "lab-coordinator";
const ACTOR = "BEEP_BOOP_ACTOR_CONVERSATION=";

function run(program: string, args: string[], input = "", timeoutMs = 60_000): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(program, args, { stdio: ["pipe", "pipe", "pipe"], timeout: timeoutMs });
    let stdout = "", stderr = "";
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => { stdout += chunk; });
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code, signal) => code === 0 ? resolve(stdout)
      : reject(new Error(`${args.at(-1)?.slice(0, 80) ?? program} exited ${code ?? signal}: ${stderr.trim().slice(0, 500)}`)));
    child.stdin.end(input);
  });
}

function dataRoot(args: string): string | null {
  return /--user-data-dir=(\S+)/.exec(args)?.[1] ?? null;
}

function helperOwners(listing: string): { pid: number; owner: string }[] {
  return listing.split("\n").flatMap((line) => {
    if (!line.includes("browser-host.js")) return [];
    const fields = line.trim().split(/\s+/);
    const owner = fields.find((field) => field.startsWith(ACTOR))?.slice(ACTOR.length);
    const pid = Number(fields[0]);
    return owner === undefined || !Number.isInteger(pid) ? [] : [{ pid, owner }];
  });
}

function terminateScript(pid: number): string {
  // An ordinary Quit of one exact application process, as the Dock or Cmd-Q would send.
  return `ObjC.import("AppKit"); const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(${pid}); app.isNil() ? "missing" : (app.terminate ? "terminated" : "refused")`;
}

class Tunnel {
  private child: ChildProcess | undefined;
  localCdpPort = 0;

  constructor(private readonly sshConfig: string, private readonly coordinatorSocket: string | null) {}

  alive(): boolean { return this.child !== undefined && this.child.exitCode === null && this.child.signalCode === null; }

  async up(guest: Guest): Promise<void> {
    if (this.alive()) return;
    if (this.coordinatorSocket !== null) await guest.sh(`rm -f ${GUEST_SOCKET}`);
    this.localCdpPort = await freePort();
    const forwards = ["-L", `${this.localCdpPort}:127.0.0.1:${GUEST_CDP_PORT}`, ...(this.coordinatorSocket === null ? []
      : ["-R", `${GUEST_SOCKET}:${this.coordinatorSocket}`, "-R", "18080:127.0.0.1:18080"])];
    const child = spawn("ssh", ["-F", this.sshConfig, "-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=5",
      "-o", "ServerAliveCountMax=3", ...forwards, "guest"], { stdio: "ignore" });
    this.child = child;
    await waitFor("the guest tunnel", 30_000, async () => {
      if (!this.alive()) throw new Error("ssh tunnel exited");
      if (!await portAccepts(this.localCdpPort)) return undefined;
      return this.coordinatorSocket === null || (await guest.sh(`test -S ${GUEST_SOCKET} && echo yes || true`)).trim() === "yes"
        ? true : undefined;
    }, 500);
  }

  down(): void { if (this.alive()) this.child?.kill("SIGTERM"); this.child = undefined; }
}

class Guest {
  constructor(readonly sshConfig: string) {}

  sh(script: string, input = "", timeoutMs = 60_000): Promise<string> {
    return run("ssh", ["-F", this.sshConfig, "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "guest", script], input, timeoutMs);
  }

  async bootTime(): Promise<number> {
    const sec = /sec = (\d+)/.exec(await this.sh("sysctl -n kern.boottime"))?.[1];
    if (sec === undefined) throw new Error("Guest boot time is unreadable");
    return Number(sec);
  }

  async chrome(): Promise<ChromeFacts> {
    const lines = (await this.sh(`for p in $(pgrep -x "Google Chrome"); do echo "$p $(ps -ww -o args= -p $p)"; done`)).split("\n").filter(Boolean);
    const parsed = lines.map((line) => ({ pid: Number(line.split(" ")[0]), data_root: dataRoot(line) }));
    return parsed.find((entry) => entry.data_root === GUEST_CHROME_ROOT) ?? parsed[0] ?? { pid: null, data_root: null };
  }

  async servicePid(): Promise<number | null> {
    const printed = await this.sh(`launchctl print gui/$(id -u)/${AGENT_LABEL}`).catch(() => "");
    const pid = /\n\tpid = (\d+)/.exec(printed)?.[1];
    return /\n\tstate = running/.test(printed) && pid !== undefined ? Number(pid) : null;
  }

  async exitType(): Promise<string | null> {
    const found = await this.sh(`grep -o '"exit_type":"[A-Za-z]*"' ${GUEST_CHROME_ROOT}/Default/Preferences || true`);
    return /"exit_type":"([A-Za-z]+)"/.exec(found)?.[1] ?? null;
  }

  async now(): Promise<string> { return (await this.sh(`date "+%Y-%m-%d %H:%M:%S"`)).trim(); }

  /** Chrome keeps exit_type Crashed after a clean Quit until someone answers its restore prompt, so AppKit's log decides. */
  async quitEvidence(pid: number, since: string): Promise<QuitEvidence> {
    const approved = Number((await this.sh(`sudo log show --style compact --start '${since}' --predicate 'processID == ${pid} AND eventMessage CONTAINS "App termination approved"' | grep -c 'App termination approved' || true`)).trim());
    const reports = Number((await this.sh(`find ~/Library/Logs/DiagnosticReports -name 'Google Chrome*' -newermt '${since}' 2>/dev/null | wc -l`)).trim());
    return { ordinary: approved > 0 && reports === 0, proof: `AppKit approved the Quit ${approved} times; ${reports} new Chrome crash reports`,
      exit_type: await this.exitType() };
  }

  async helperPid(owner: string): Promise<number | null> {
    // The helper environment carries the pairing token, so only pid and actor leave the guest.
    const listing = await this.sh(`ps -E -ww -axo pid=,command= | awk '/browser-host[.]js/ { for (i = 2; i <= NF; i++) if ($i ~ /^${ACTOR}/) print $1, "browser-host.js", $i }' || true`);
    return helperOwners(listing).find((entry) => entry.owner === owner)?.pid ?? null;
  }

  async processGone(pid: number, timeoutMs: number): Promise<void> {
    await waitFor(`guest pid ${pid} to exit`, timeoutMs, async () => (await this.sh(`ps -p ${pid} >/dev/null && echo alive || echo gone`)).trim() === "gone" ? true : undefined, 500);
  }

  async closeStaleTaskSessions(): Promise<string[]> {
    const listed: unknown = JSON.parse(await this.sh(`${GUEST_REX} ls --json`));
    const stale = isRecord(listed) && Array.isArray(listed.sessions) ? listed.sessions.flatMap((session: unknown) =>
      isRecord(session) && typeof session.session_id === "string" && /^session:[0-9a-f-]+$/.test(session.session_id) &&
        typeof session.label === "string" && session.label.startsWith(LAB_TASK_TITLE_PREFIX) ? [session.session_id] : []) : [];
    if (stale.length > 0) await this.sh(`${GUEST_REX} kill ${stale.join(" ")}`);
    return stale;
  }

  async cdpListening(): Promise<boolean> {
    return (await this.sh(`lsof -nP -iTCP:${GUEST_CDP_PORT} -sTCP:LISTEN >/dev/null && echo yes || echo no`)).trim() === "yes";
  }
}

class GuestTarget implements Target {
  readonly name = "guest" as const;
  readonly mode = "extension" as const;
  readonly browserHost = GUEST_HOST;
  readonly faults: Record<LegKind, Fault>;
  private readonly guest: Guest;
  private tunnel: Tunnel;

  constructor(lab: string) {
    this.guest = new Guest(join(lab, "ssh_config"));
    this.tunnel = new Tunnel(this.guest.sshConfig, null);
    let killedWorker = 0;
    const quitChrome = async (): Promise<FaultEvidence> => {
      const { pid, data_root } = await this.guest.chrome();
      if (pid === null || data_root !== GUEST_CHROME_ROOT) throw new Error("Chrome is not running on the lab data root");
      const since = await this.guest.now();
      const answer = (await this.guest.sh(`osascript -l JavaScript -e '${terminateScript(pid)}'`)).trim();
      await this.guest.processGone(pid, 60_000);
      return { detail: `Quit Chrome pid ${pid}: ${answer}`, quit: await this.guest.quitEvidence(pid, since) };
    };
    this.faults = {
      relaunch: { expect: { boot: SAME, chrome: CHANGED, service: SAME }, conversationSurvives: true, inject: quitChrome,
        recover: async (context) => {
          await this.guest.sh(`launchctl kickstart gui/$(id -u)/acceptance.chrome`);
          await this.ready(context.coordinator);
        } },
      kill_helper: { expect: { boot: SAME, chrome: SAME, service: SAME }, conversationSurvives: true,
        inject: async (context) => {
          const pid = await this.guest.helperPid(context.ownerId);
          if (pid === null) throw new Error(`No browser helper runs for conversation ${context.ownerId}`);
          await this.guest.sh(`kill -KILL ${pid}`);
          await this.guest.processGone(pid, 10_000);
          return { detail: `SIGKILL browser-host.js pid ${pid} of conversation ${context.ownerId}` };
        },
        recover: (context) => this.ready(context.coordinator) },
      kill_service: { expect: { boot: SAME, chrome: SAME, service: CHANGED }, conversationSurvives: true,
        inject: async () => {
          const pid = await this.guest.servicePid();
          if (pid === null) throw new Error("The guest worker is not running");
          await this.guest.sh(`kill -KILL ${pid}`);
          killedWorker = pid;
          return { detail: `SIGKILL worker pid ${pid}` };
        },
        recover: async (context) => {
          await waitFor("launchd to restart the guest worker", 120_000, async () => {
            const next = await this.guest.servicePid();
            return next !== null && next !== killedWorker ? next : undefined;
          }, 2000);
          await this.ready(context.coordinator);
        } },
      os_reboot: { expect: { boot: CHANGED, chrome: CHANGED, service: CHANGED }, conversationSurvives: true,
        inject: async () => {
          const before = await this.guest.bootTime();
          await this.guest.sh("sudo shutdown -r now", "", 15_000).catch(() => "");
          this.tunnel.down();
          await waitFor("the guest to boot again", 400_000, async () => {
            const after = await this.guest.bootTime();
            return after !== before ? after : undefined;
          }, 3000);
          return { detail: `sudo shutdown -r now; boot time ${before} changed` };
        },
        recover: (context) => this.ready(context.coordinator) },
    };
  }

  private async ready(coordinator: PrivateCoordinator): Promise<void> {
    await waitFor("guest ssh", 300_000, () => this.guest.bootTime(), 3000);
    await waitFor("an automatic console login", 180_000, async () => (await this.guest.sh("who | grep -c console || true")).trim() !== "0" ? true : undefined, 3000);
    await waitFor("the guest worker agent", 180_000, async () => await this.guest.servicePid() ?? undefined, 3000);
    await waitFor("Chrome on the lab data root with its observer port", 180_000, async () => {
      const facts = await this.guest.chrome();
      return facts.data_root === GUEST_CHROME_ROOT && await this.guest.cdpListening() ? true : undefined;
    }, 3000);
    await this.tunnel.up(this.guest);
    await waitFor(`${GUEST_HOST} online`, 240_000, async () => await coordinator.online(GUEST_HOST) ? true : undefined, 3000);
  }

  async prepare(password: string): Promise<PrepareReport> {
    const facts = await this.guest.chrome();
    if (facts.pid === null) {
      await this.guest.sh(`launchctl kickstart gui/$(id -u)/acceptance.chrome`);
      await waitFor("Chrome on the lab data root", 60_000, async () => (await this.guest.chrome()).data_root === GUEST_CHROME_ROOT ? true : undefined, 2000);
    } else if (facts.data_root !== GUEST_CHROME_ROOT) {
      throw new Error(`Guest Chrome pid ${facts.pid} runs on ${facts.data_root ?? "its default data root"}, not ${GUEST_CHROME_ROOT}. Quit it and run acceptance.chrome.`);
    }
    await waitFor("the guest Chrome observer port", 60_000, async () => await this.guest.cdpListening() ? true : undefined, 1000);
    await this.tunnel.up(this.guest);
    const cdp = await this.cdp();
    try {
      const token = await cdp.inPage("chrome-extension://mmlmfjhmonkocbjadbfplnigmagldckm/status.html",
        "document.readyState === 'complete' && localStorage.getItem('auth-token') !== null", (evaluate) => evaluate("localStorage.getItem('auth-token')"));
      if (typeof token !== "string" || !/^[A-Za-z0-9_-]{32,256}$/.test(token)) throw new Error("The Playwright extension has no pairing token");
      await this.guest.sh(`umask 077; mkdir -p ~/lab/secrets; cat > ${GUEST_TOKEN}.new && mv -f ${GUEST_TOKEN}.new ${GUEST_TOKEN}`, token);
      const saved = await replaceSavedLogin(cdp, password);
      return { target: this.name, saved_logins_for_origin: saved, token_written: true };
    } finally { cdp.close(); this.tunnel.down(); }
  }

  async browserConfig(): Promise<string> { return ""; }

  async connect(coordinator: PrivateCoordinator, log: (line: string) => void): Promise<void> {
    const stale = await this.guest.closeStaleTaskSessions();
    if (stale.length > 0) log(`closed ${stale.length} guest Rex sessions left by earlier runs: ${stale.join(", ")}`);
    this.tunnel = new Tunnel(this.guest.sshConfig, coordinator.socket);
    await this.ready(coordinator);
  }

  async secrets(): Promise<string[]> {
    const token = (await this.guest.sh(`cat ${GUEST_TOKEN}`)).trim();
    if (token.length === 0) throw new Error("The guest has no pairing token; run prepare first");
    return [token];
  }

  async diagnostics(): Promise<string> {
    return this.guest.sh(`echo "## launchctl"; for l in ${AGENT_LABEL} acceptance.rex acceptance.chrome; do launchctl print gui/$(id -u)/$l | grep -E "^.(state|pid|runs|last exit code) = " | sed "s/^/$l /"; done; echo "## agent.log"; tail -n 300 ~/lab/logs/agent.log`)
      .catch((error: unknown) => `guest diagnostics unavailable: ${String(error)}`);
  }

  bootTime(): Promise<number> { return this.guest.bootTime(); }
  chrome(): Promise<ChromeFacts> { return this.guest.chrome(); }
  servicePid(): Promise<number | null> { return this.guest.servicePid(); }
  cdp(): Promise<CdpClient> { return CdpClient.connect(this.tunnel.localCdpPort); }
  async close(): Promise<void> { this.tunnel.down(); }
}

class LocalTarget implements Target {
  readonly name = "local" as const;
  readonly mode = "native_cdp" as const;
  readonly browserHost = LOCAL_HOST;
  readonly faults: Partial<Record<LegKind, Fault>>;
  private browser: ChildProcess | undefined;
  private coordinator: PrivateCoordinator | undefined;
  private port = 0;

  constructor(private readonly lab: string, private readonly logFile: string) {
    const ready = async (coordinator: PrivateCoordinator) => {
      await waitFor(`${LOCAL_HOST} online`, 120_000, async () => await coordinator.online(LOCAL_HOST) ? true : undefined, 2000);
    };
    this.faults = {
      relaunch: { expect: { boot: SAME, chrome: CHANGED, service: SAME }, conversationSurvives: true,
        inject: async () => {
          const { pid, code, signal } = await this.quit();
          return { detail: `Quit Chrome for Testing pid ${pid}`, quit: { ordinary: code === 0 && signal === null,
            proof: `exit code ${code ?? "none"}, signal ${signal ?? "none"}`, exit_type: this.exitType() } };
        },
        recover: async (context) => { await this.launch(this.port); await ready(context.coordinator); } },
      kill_helper: { expect: { boot: SAME, chrome: SAME, service: SAME }, conversationSurvives: true,
        inject: async (context) => {
          const group = context.coordinator.pid();
          if (group === null) throw new Error("The lab coordinator is not running");
          const { stdout: members } = await execFileAsync("pgrep", ["-g", String(group)]);
          const { stdout } = await execFileAsync("ps", ["-E", "-ww", "-o", "pid=,command=", "-p", members.trim().split(/\s+/).join(",")],
            { maxBuffer: 64 * 1024 * 1024 });
          const pid = helperOwners(stdout).find((entry) => entry.owner === context.ownerId)?.pid;
          if (pid === undefined) throw new Error(`No browser helper runs for conversation ${context.ownerId}`);
          process.kill(pid, "SIGKILL");
          await waitFor(`helper pid ${pid} to exit`, 10_000, () => processAlive(pid) ? undefined : true, 250);
          return { detail: `SIGKILL browser-host.js pid ${pid} of conversation ${context.ownerId}` };
        },
        recover: (context) => ready(context.coordinator) },
      kill_service: { expect: { boot: SAME, chrome: SAME, service: CHANGED }, conversationSurvives: false,
        inject: async (context) => ({ detail: `SIGKILL lab coordinator process group ${await context.coordinator.kill()}` }),
        recover: async (context) => { await context.coordinator.start(); await ready(context.coordinator); } },
    };
  }

  private get root(): string { return join(this.lab, "local-chrome"); }

  private async launch(port: number): Promise<void> {
    const log = openSync(this.logFile, "a");
    try {
      this.browser = spawn(chromium.executablePath(), [`--user-data-dir=${this.root}`, `--remote-debugging-port=${port}`,
        "--use-mock-keychain", "--password-store=basic", "--no-first-run", "--no-default-browser-check", "about:blank"],
        { detached: true, stdio: ["ignore", log, log] });
      this.browser.unref();
    } finally { closeSync(log); }
    this.port = port;
    await waitFor("Chrome for Testing DevTools", 60_000, async () => {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`, { signal: AbortSignal.timeout(2000) });
      return response.ok ? true : undefined;
    }, 500);
  }

  private async quit(): Promise<{ pid: number; code: number | null; signal: NodeJS.Signals | null }> {
    const browser = this.browser, pid = browser?.pid;
    if (browser === undefined || pid === undefined || !processAlive(pid)) throw new Error("Chrome for Testing is not running");
    await execFileAsync("osascript", ["-l", "JavaScript", "-e", terminateScript(pid)]);
    await waitFor(`Chrome for Testing pid ${pid} to exit`, 60_000, () => browser.exitCode !== null || browser.signalCode !== null ? true : undefined, 250);
    return { pid, code: browser.exitCode, signal: browser.signalCode };
  }

  private exitType(): string | null {
    try {
      const preferences: unknown = JSON.parse(readFileSync(join(this.root, "Default", "Preferences"), "utf8"));
      return isRecord(preferences) && isRecord(preferences.profile) && typeof preferences.profile.exit_type === "string"
        ? preferences.profile.exit_type : null;
    } catch { return null; }
  }

  async prepare(password: string): Promise<PrepareReport> {
    rmSync(this.root, { recursive: true, force: true });
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    await this.launch(await freePort());
    try {
      const cdp = await this.cdp();
      try { return { target: this.name, saved_logins_for_origin: await replaceSavedLogin(cdp, password), token_written: false }; }
      finally { cdp.close(); }
    } finally { await this.quit(); }
  }

  async browserConfig(): Promise<string> {
    if (!existsSync(join(this.root, "Default"))) throw new Error(`${this.root} has no prepared profile; run prepare --target local first`);
    const port = await freePort();
    await this.launch(port);
    return `\n[browser]\ndebugging_port = ${port}\n`;
  }

  async connect(coordinator: PrivateCoordinator): Promise<void> { this.coordinator = coordinator; }
  async secrets(): Promise<string[]> { return []; }
  async diagnostics(): Promise<string> { return ""; }

  async bootTime(): Promise<number> {
    const { stdout } = await execFileAsync("sysctl", ["-n", "kern.boottime"]);
    return Number(/sec = (\d+)/.exec(stdout)?.[1]);
  }

  async chrome(): Promise<ChromeFacts> {
    const pid = this.browser?.pid;
    if (pid === undefined || !processAlive(pid)) return { pid: null, data_root: null };
    const { stdout } = await execFileAsync("ps", ["-ww", "-o", "args=", "-p", String(pid)]);
    return { pid, data_root: dataRoot(stdout) };
  }

  async servicePid(): Promise<number | null> { return this.coordinator?.pid() ?? null; }
  cdp(): Promise<CdpClient> { return CdpClient.connect(this.port); }
  async close(): Promise<void> { if (this.browser?.pid !== undefined && processAlive(this.browser.pid)) await this.quit().catch(() => {}); }
}

export function createTarget(name: TargetName, lab: string, logFile: string): Target {
  const targets: Record<TargetName, () => Target> = { guest: () => new GuestTarget(lab), local: () => new LocalTarget(lab, logFile) };
  return targets[name]();
}
