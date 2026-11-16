import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const SOURCE = fileURLToPath(new URL("../../src/", import.meta.url));

/** Calls that create, change, rename or remove a file or a directory, each also as its `Sync` variant. */
const WRITE_CALLS = ["writeFile", "appendFile", "rename", "copyFile", "cp", "mkdir", "mkdtemp", "rm", "rmdir", "unlink", "createWriteStream",
  "truncate", "ftruncate", "symlink", "link", "chmod", "chown", "utimes", "write", "writev"];

/** Files that write on purpose without the log, and why. A file named here that writes nothing is a stale entry and fails. */
const LOCAL_ON_PURPOSE: Record<string, string> = {
  "auth.ts": "Credentials stay on the host that holds them and never replicate.",
  "search.ts": "The search index is a projection that each host rebuilds from the session.",
  "telemetry.ts": "Diagnostics belong to the host that recorded them.",
  "startup-diagnostics.ts": "Diagnostics belong to the host that recorded them.",
  "failover/retained-files.ts": "The one writer of retained files, local and replicated.",
  "failover/standby.ts": "The steps the retained-file writer and the log follower share: a synced temporary file, and its rename to the name a log entry gives it.",
};

/** Files allowed exactly these write calls and no other. */
const PINNED: Record<string, { readonly why: string; readonly calls: Readonly<Record<string, number>> }> = {
  "attachment-upload.ts": { why: "An upload before it completes, which no reader takes as real until RetainedFiles writes its complete metadata.",
    calls: { mkdir: 2, chmod: 1, writeFile: 2, open: 2, rename: 1, write: 1 } },
  "protocol.ts": { why: "StringDecoder.write decodes the input stream and writes no file.", calls: { write: 1 } },
  "failover/ownership.ts": { why: "writeSync puts the fenced owner's last line on stderr before the exit that follows it, and writes no file.", calls: { write: 1 } },
};

/** Receivers of a write-named method that write no file. */
const NOT_FILES: Record<string, string> = {
  "process.stdout": "Frames to the parent process.",
  "process.stderr": "Diagnostics to the parent process.",
  "this.files": "The RetainedFiles a store holds.",
};

interface WriteCall { readonly file: string; readonly line: number; readonly call: string }

/** Blanks comments, keeps string literals, and keeps line numbers. */
function withoutComments(source: string): string {
  return source.replace(/("(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`)|\/\*[\s\S]*?\*\/|\/\/[^\n]*/g,
    (match, literal: string | undefined) => literal ?? match.replace(/[^\n]/g, " "));
}

/** The text of a call's arguments, from just after its opening parenthesis to its closing one. */
function argumentsAt(source: string, open: number): string[] {
  const parts: string[] = [];
  let depth = 0, start = open;
  for (let index = open; index < source.length; index += 1) {
    const character = source[index];
    if (character === "(" || character === "[" || character === "{") depth += 1;
    else if (character === ")" || character === "]" || character === "}") {
      if (depth === 0) { parts.push(source.slice(start, index)); return parts.map((part) => part.trim()).filter((part) => part.length > 0); }
      depth -= 1;
    } else if (character === "," && depth === 0) { parts.push(source.slice(start, index)); start = index + 1; }
  }
  return parts;
}

/** Whether an `open` call's flags allow writing. A flag the scan cannot read counts as a write. */
function opensForWriting(flags: string | undefined): boolean {
  if (flags === undefined || flags.startsWith("{")) return false;
  const literal = /^["'`]([^"'`]*)["'`]$/.exec(flags);
  if (literal !== null) return /[wa+]/.test(literal[1] ?? "");
  if (/\bO_(WRONLY|RDWR|CREAT|APPEND|TRUNC)\b/.test(flags)) return true;
  return !/\bO_RDONLY\b/.test(flags);
}

function writeCalls(file: string, source: string): WriteCall[] {
  const code = withoutComments(source), calls: WriteCall[] = [];
  const lineOf = (index: number) => code.slice(0, index).split("\n").length;
  for (const match of code.matchAll(new RegExp(String.raw`\b(${WRITE_CALLS.join("|")})(?:Sync)?\s*\(`, "g"))) {
    const receiver = /([\w$.]+)\.$/.exec(code.slice(Math.max(0, match.index - 80), match.index))?.[1];
    if (receiver !== undefined && receiver in NOT_FILES) continue;
    calls.push({ file, line: lineOf(match.index), call: match[1] ?? "" });
  }
  for (const match of code.matchAll(/\bopen(?:Sync)?\s*\(/g)) {
    if (opensForWriting(argumentsAt(code, match.index + match[0].length)[1])) calls.push({ file, line: lineOf(match.index), call: "open" });
  }
  return calls.sort((a, b) => a.line - b.line);
}

async function sourceWrites(): Promise<WriteCall[]> {
  const files = (await readdir(SOURCE, { recursive: true, withFileTypes: true })).filter((entry) => entry.isFile() && entry.name.endsWith(".ts"));
  const calls = await Promise.all(files.map(async (entry) => {
    const path = join(entry.parentPath, entry.name);
    return writeCalls(relative(SOURCE, path), await readFile(path, "utf8"));
  }));
  return calls.flat();
}

function counted(calls: readonly WriteCall[]): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const { call } of calls) counts[call] = (counts[call] ?? 0) + 1;
  return counts;
}

test("the scan finds every kind of file write and no read", () => {
  const writes = [`await writeFile(path, "x");`, `writeFileSync(path, "x");`, `await appendFile(path, "x");`, `await rename(from, to);`, `renameSync(from, to);`,
    `await copyFile(from, to);`, `await mkdir(directory);`, `mkdirSync(directory);`, `await rm(path, { force: true });`, `await unlink(path);`,
    `createWriteStream(path);`, `await open(path, "w");`, `await open(path, "a", 0o600);`, `await open(path, "r+");`, `await open(path, "wx", 0o600);`,
    `openSync(path, constants.O_WRONLY | constants.O_CREAT);`, `await open(path, flags);`, `await handle.write(bytes, 0, 4, 0);`, `await handle.writeFile(bytes);`,
    `await fs.promises.writeFile(path, "x");`, `await handle.truncate(0);`, `await chmod(path, 0o600);`,
    `const glob = "src/**/*.ts"; await rename(from, to); const end = "*/";`, `const url = "https://example.invalid"; await rm(path);`];
  for (const write of writes) assert.equal(writeCalls("invented.ts", write).length, 1, write);
  const reads = [`await readFile(path);`, `await open(path, "r");`, `await open(path);`, `await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);`,
    `process.stdout.write(frame);`, `await this.files.write([file]);`, `Harness.open(storage, { models });`, `// await writeFile(path, "x");`,
    `/** Renames with rename(from, to). */`, `await rewrite(path);`, `const overwrite = (path) => path;`];
  for (const read of reads) assert.deepEqual(writeCalls("invented.ts", read), [], read);
});

test("only the retained-file writer and the stores that are local on purpose write files under runtime/src", async () => {
  const calls = await sourceWrites();
  const stray = calls.filter(({ file }) => !(file in LOCAL_ON_PURPOSE) && !(file in PINNED));
  assert.deepEqual(stray.map(({ file, line, call }) => `${file}:${line} ${call}`), [],
    "A file under attachments/, history/assets/ or feedback/ gets its final name only through RetainedFiles. Write through it, or name the file and why it is local.");
  for (const [file, { calls: allowed }] of Object.entries(PINNED)) {
    assert.deepEqual(counted(calls.filter((call) => call.file === file)), allowed, `${file} may make exactly these write calls`);
  }
  for (const file of Object.keys(LOCAL_ON_PURPOSE)) assert.ok(calls.some((call) => call.file === file), `${file} writes nothing, so its entry is stale`);
});
