import { spawn, type ChildProcess } from "node:child_process";
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

function killGroup(child: ChildProcess, signal: NodeJS.Signals): void {
  if (child.pid === undefined) return;
  try { process.kill(-child.pid, signal); } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}

/**
 * Runs the real authority Worker under `wrangler dev --local` on a free
 * loopback port, with a temporary persistence directory and no Cloudflare
 * account: every `CLOUDFLARE_*` and `CF_*` variable is removed and HOME points
 * at the temporary directory, so wrangler can find no login. Each grant gets a
 * fresh random token. The test's `after` hook stops workerd even when the test fails.
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
  Object.assign(env, { WRANGLER_SEND_METRICS: "false", HOME: home, XDG_CONFIG_HOME: join(home, ".config") });

  let child: ChildProcess | undefined;
  const killOnExit = () => { if (child !== undefined) killGroup(child, "SIGKILL"); };
  process.once("exit", killOnExit);

  async function launch(): Promise<ChildProcess> {
    const started = spawn("wrangler", ["dev", "--local", "--config", join(directory, "wrangler.json"),
      "--ip", "127.0.0.1", "--port", String(port), "--inspector-port", String(await freePort()),
      "--persist-to", join(directory, "state"), "--show-interactive-dev-session=false", "--log-level", "warn",
      "--var", `AUTHORITY_CREDENTIALS:${secret}`], { cwd: directory, env, detached: true, stdio: ["ignore", "pipe", "pipe"] });
    child = started;
    let output = "";
    const collect = (chunk: Buffer) => { output = (output + chunk.toString("utf8")).slice(-20_000); };
    started.stdout?.on("data", collect);
    started.stderr?.on("data", collect);
    const failed = new Promise<Error>((resolve) => {
      started.once("error", (error: NodeJS.ErrnoException) => resolve(error.code === "ENOENT" ? new Error(MISSING_WRANGLER) : error));
      started.once("exit", (code, signal) => resolve(new Error(`wrangler dev exited (${code ?? signal}) before it answered:\n${output}`)));
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
      await halt(started);
      throw failure;
    }
    return started;
  }

  async function halt(running: ChildProcess): Promise<void> {
    if (running.exitCode === null && running.signalCode === null) {
      const exited = once(running, "exit");
      killGroup(running, "SIGTERM");
      const force = setTimeout(() => killGroup(running, "SIGKILL"), 5_000);
      await exited;
      clearTimeout(force);
    }
    killGroup(running, "SIGKILL");
  }

  let stopped = false;
  const authority: LocalAuthority = {
    url,
    credentials,
    async stop() {
      if (stopped) return;
      stopped = true;
      if (child !== undefined) await halt(child);
      process.removeListener("exit", killOnExit);
      await rm(directory, { recursive: true, force: true });
    },
    async restart() {
      if (child !== undefined) await halt(child);
      await launch();
    },
  };
  options.context.after(() => authority.stop());
  await launch();
  return authority;
}
