import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { once } from "node:events";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

/** Who may use one credential: a holder, or `null` for a read-only credential. */
export interface AuthorityGrant {
  readonly coordinator: string;
  readonly holder: string | null;
}

export interface LocalCredential extends AuthorityGrant {
  readonly token: string;
}

export interface LocalAuthority {
  readonly url: string;
  readonly credentials: readonly LocalCredential[];
  /** Stops workerd and deletes its state. */
  stop(): Promise<void>;
  /** Stops workerd and starts it again on the same port and the same persisted state. */
  restart(): Promise<void>;
}

const runtimeRoot = fileURLToPath(new URL("../../../", import.meta.url));
const MISSING_WRANGLER = "wrangler is not on PATH. Run the failover tests inside the flake's ci shell: nix develop .#ci";
/**
 * Runs wrangler as the leader of its own process group, beside a watcher that
 * kills the group when this test process's end of stdin closes. A runner that
 * kills the test process with a signal then leaves no workerd behind.
 */
const GROUP_WITH_WATCHER = `command -v wrangler >/dev/null || exit 127
exec 3<&0
{ read -r _ <&3; kill -KILL -- -$$; } &
exec wrangler "$@" </dev/null 3<&-`;

async function freePort(): Promise<number> {
  const server = createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  server.close();
  await once(server, "close");
  if (address === null || typeof address === "string") throw new Error("A loopback listener reported no port");
  return address.port;
}

/**
 * Signals a process group and says whether any member was still there. macOS
 * answers EPERM while the only members left are exiting, so that counts as present.
 */
function signalGroup(group: number, signal: NodeJS.Signals | 0): boolean {
  try {
    process.kill(-group, signal);
    return true;
  } catch (error) {
    const { code } = error as NodeJS.ErrnoException;
    if (code === "ESRCH") return false;
    if (code === "EPERM") return true;
    throw error;
  }
}

/** Stops a process group and waits until no member is left, so the port and the persisted state are free. */
async function stopGroup(group: number): Promise<void> {
  signalGroup(group, "SIGTERM");
  const force = Date.now() + 5_000, deadline = force + 10_000;
  while (signalGroup(group, 0)) {
    if (Date.now() > deadline) throw new Error(`Process group ${group} of wrangler dev outlived SIGKILL`);
    if (Date.now() > force) signalGroup(group, "SIGKILL");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}

/**
 * Runs the real authority Worker under `wrangler dev --local` on a free
 * loopback port, with a temporary persistence directory and no Cloudflare
 * account: every `CLOUDFLARE_*` and `CF_*` variable is removed and HOME points
 * at the temporary directory, so wrangler can find no login. It also skips the
 * banner's npm update check and the download of request.cf data from
 * Cloudflare, so a run makes no network request at all. Each grant gets a
 * fresh random token. The test's `after` hook stops workerd even when the test
 * fails, and it never skips: without wrangler on PATH it throws.
 */
export async function startAuthority(options: {
  readonly context: { after(hook: () => Promise<void>): void };
  readonly grants: readonly AuthorityGrant[];
}): Promise<LocalAuthority> {
  const directory = await mkdtemp(join(tmpdir(), "beep-boop-authority-"));
  const home = join(directory, "home");
  await mkdir(home);
  const config = JSON.parse(await readFile(join(runtimeRoot, "failover/wrangler.jsonc"), "utf8")) as { main: string };
  await writeFile(join(directory, "wrangler.json"), JSON.stringify({ ...config, main: join(runtimeRoot, "failover", config.main) }));

  const credentials = options.grants.map((grant) => ({ ...grant, token: randomBytes(32).toString("hex") }));
  const secret = JSON.stringify(credentials.map(({ coordinator, holder, token }) =>
    ({ coordinator, holder, token_sha256: createHash("sha256").update(token).digest("hex") })));
  const port = await freePort();
  const url = `http://127.0.0.1:${port}`;
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith("CLOUDFLARE_") && !name.startsWith("CF_")));
  Object.assign(env, { HOME: home, XDG_CONFIG_HOME: join(home, ".config"), WRANGLER_SEND_METRICS: "false",
    WRANGLER_HIDE_BANNER: "true", CLOUDFLARE_CF_FETCH_ENABLED: "false" });

  let group: number | undefined;

  async function launch(): Promise<void> {
    const started = spawn("bash", ["-c", GROUP_WITH_WATCHER, "wrangler", "dev", "--local", "--config", join(directory, "wrangler.json"),
      "--ip", "127.0.0.1", "--port", String(port), "--inspector-port", String(await freePort()),
      "--persist-to", join(directory, "state"), "--show-interactive-dev-session=false", "--log-level", "warn",
      "--var", `AUTHORITY_CREDENTIALS:${secret}`], { cwd: directory, env, detached: true, stdio: ["pipe", "pipe", "pipe"] });
    group = started.pid;
    let output = "";
    const collect = (chunk: Buffer) => { output = (output + chunk.toString("utf8")).slice(-20_000); };
    started.stdout?.on("data", collect);
    started.stderr?.on("data", collect);
    const failed = new Promise<Error>((resolve) => {
      started.once("error", resolve);
      started.once("exit", (code, signal) =>
        resolve(new Error(code === 127 ? MISSING_WRANGLER : `wrangler dev exited (${code ?? signal}) before it answered:\n${output}`)));
    });
    const settled = new AbortController();
    const answered = (async (): Promise<Error | undefined> => {
      const deadline = Date.now() + 90_000;
      while (!settled.signal.aborted) {
        if (await fetch(url, { signal: AbortSignal.any([settled.signal, AbortSignal.timeout(1_000)]) }).then(() => true, () => false)) return undefined;
        if (Date.now() > deadline) return new Error(`wrangler dev did not answer on ${url} within 90 s:\n${output}`);
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      return undefined;
    })();
    const failure = await Promise.race([answered, failed]);
    settled.abort();
    if (failure !== undefined) {
      await halt();
      throw failure;
    }
  }

  async function halt(): Promise<void> {
    if (group !== undefined) await stopGroup(group);
  }

  let stopped = false;
  const authority: LocalAuthority = {
    url,
    credentials,
    async stop() {
      if (stopped) return;
      stopped = true;
      await halt();
      await rm(directory, { recursive: true, force: true });
    },
    async restart() {
      await halt();
      await launch();
    },
  };
  options.context.after(() => authority.stop());
  await launch();
  return authority;
}
