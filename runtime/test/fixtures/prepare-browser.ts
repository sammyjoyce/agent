import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { chromium } from "playwright-core";

// Test-only artifacts. Production connects to the user's installed Chrome.
const extensionId = "mmlmfjhmonkocbjadbfplnigmagldckm";
// Pin Google's versioned CRX blobs, not the mutable update-service redirect.
// 0.6.0 hands the client a claimed blank tab; 0.5.0 keeps its connect page.
const extensions = [{
  name: "extension", version: "0.6.0",
  sha256: "843be64a74cdc0ca24138499ab6ce9cd028877bcb5eaa57433c8036437cf5c6c",
  url: "https://clients2.googleusercontent.com/crx/blobs/ARGaeZIcbYXXT4GCQpkzTlBL28AbGnf6odSOLt7RcAuQ57kO1v_0IVmIOOw21X_4U8xRmAlTpGv1fWXJieimwqJJuLW0Cluj1Up3boEi7Z4_X6qKaMKZ4SC5MERQYHm-NysAxlKa5aeonBkRmDCxYCXVyewjlp7EMznb/MMLMFJHMONKOCBJADBFPLNIGMAGLDCKM_0_6_0_0.crx",
}, {
  name: "legacy-extension", version: "0.5.0",
  sha256: "598517ba87d9f2f3b3642483cb6662bc0ea061401c5d3c1eb188a19847c92b0b",
  url: "https://clients2.googleusercontent.com/crx/blobs/ARGaeZIuYdHUb_HJVBZB_VVCuw5XJe3t-P_bbw9xOfm56r7GXUTwBqW3L-1SyLzSPT3a9W8fA8LnC52tcUeEs44eyJjNb5Y7cRakmTUDlv3UpBJOgLmNUi7yS8ZZZI8rKwUAxlKa5bBvgcjPOP-3tsAFqSY-EMXyrRRX/MMLMFJHMONKOCBJADBFPLNIGMAGLDCKM_0_5_0_0.crx",
}] as const;

function object(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function extract(directory: string, pinned: typeof extensions[number]): Promise<string> {
  const extension = join(directory, pinned.name);
  const response = await fetch(pinned.url, { signal: AbortSignal.timeout(30_000) });
  if (!response.ok) throw new Error("Official extension download failed with HTTP " + response.status);
  const crx = Buffer.from(await response.arrayBuffer());
  if (createHash("sha256").update(crx).digest("hex") !== pinned.sha256) {
    throw new Error("Official extension checksum changed; review and update the pinned test fixture");
  }
  if (crx.length < 12 || crx.subarray(0, 4).toString("ascii") !== "Cr24" || crx.readUInt32LE(4) !== 3) {
    throw new Error("Expected a CRX3 extension archive");
  }
  const offset = 12 + crx.readUInt32LE(8);
  if (offset >= crx.length) throw new Error("Invalid CRX3 archive header");
  const archive = join(directory, pinned.name + ".zip");
  await writeFile(archive, crx.subarray(offset));
  await mkdir(extension);
  await promisify(execFile)("unzip", ["-q", archive, "-d", extension], { timeout: 15_000 });
  // Chrome rejects Store verification metadata in a normally loaded unpacked
  // fixture. All executable assets remain identical to the verified CRX.
  await rm(join(extension, "_metadata"), { recursive: true, force: true });
  await rm(archive);
  const manifest: unknown = JSON.parse(await readFile(join(extension, "manifest.json"), "utf8"));
  if (!object(manifest) || manifest.version !== pinned.version || typeof manifest.key !== "string") {
    throw new Error("Official extension manifest does not match the pinned version");
  }
  const actualId = [...createHash("sha256").update(Buffer.from(manifest.key, "base64")).digest("hex").slice(0, 32)]
    .map(digit => String.fromCharCode(97 + Number.parseInt(digit, 16))).join("");
  if (actualId !== extensionId) throw new Error("Official extension identity does not match");
  return extension;
}

async function main(): Promise<void> {
  const parent = process.argv[2];
  if (parent === undefined) throw new Error("Pass an ignored local directory or CI temporary directory for browser fixtures");
  const chrome = chromium.executablePath();
  if (!(await stat(chrome).catch(() => undefined))?.isFile()) {
    throw new Error("Install the pinned test browser first: node runtime/node_modules/playwright-core/cli.js install chromium");
  }
  await mkdir(resolve(parent), { recursive: true });
  const directory = await mkdtemp(join(resolve(parent), "agent-browser-"));
  try {
    const [current, legacy] = extensions;
    const environment = {
      AGENT_TEST_CHROME: chrome,
      AGENT_TEST_PLAYWRIGHT_EXTENSION_DIR: await extract(directory, current),
      AGENT_TEST_PLAYWRIGHT_LEGACY_EXTENSION_DIR: await extract(directory, legacy),
    };
    if (process.env.GITHUB_ENV !== undefined) {
      await appendFile(process.env.GITHUB_ENV, Object.entries(environment).map(([name, value]) => name + "=" + value + "\n").join(""));
    }
    process.stdout.write(JSON.stringify(environment) + "\n");
  } catch (error) {
    await rm(directory, { recursive: true, force: true });
    throw error;
  }
}

void main().catch(error => {
  process.stderr.write((error instanceof Error ? error.message : String(error)) + "\n");
  process.exitCode = 1;
});
