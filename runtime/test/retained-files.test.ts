import assert from "node:assert/strict";
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { test } from "node:test";
import { cleanRetainedFiles, LocalFiles, StagingFile } from "../src/failover/retained-files.js";
import { filesUnder, unstampedDirectory } from "./fixtures/failover-state.js";

const BUNDLE = "11111111-1111-4111-8111-111111111111", ATTACHMENT = "33333333-3333-4333-8333-333333333333";

const temporary = (path: string) => path.split("/").some((name) => name.startsWith(".") || name.endsWith(".tmp"));

test("the local implementation names each file privately and leaves no temporary file, on success and on failure", async (t) => {
  const directory = await unstampedDirectory(t), files = new LocalFiles(directory);
  const bundle = Buffer.from(JSON.stringify({ invented: "feedback bundle" }));
  await files.write([{ path: `feedback/${BUNDLE}.json`, bytes: bundle }, { path: "feedback/latest", bytes: Buffer.from(BUNDLE) }]);
  assert.deepEqual(await filesUnder(directory), [`feedback/${BUNDLE}.json`, "feedback/latest"]);
  assert.deepEqual(await readFile(join(directory, `feedback/${BUNDLE}.json`)), bundle);
  assert.equal(await readFile(join(directory, "feedback/latest"), "utf8"), BUNDLE);
  assert.equal((await stat(join(directory, "feedback"))).mode & 0o777, 0o700);
  assert.equal((await stat(join(directory, "feedback/latest"))).mode & 0o777, 0o600);

  await mkdir(join(directory, "feedback/occupied/by-a-directory"), { recursive: true });
  await assert.rejects(files.write([{ path: "feedback/occupied", bytes: Buffer.from("cannot replace a directory") }]));
  await assert.rejects(files.write([{ path: "history/assets/missing", staged: join(directory, "history/assets/.never-staged.tmp") }]), { code: "ENOENT" });
  assert.deepEqual((await filesUnder(directory)).filter(temporary), [], "no temporary file is left behind");
  assert.deepEqual(await filesUnder(directory), [`feedback/${BUNDLE}.json`, "feedback/latest"]);
});

test("a staged file that already has its final path keeps it, and a staged file elsewhere takes it", async (t) => {
  const directory = await unstampedDirectory(t), files = new LocalFiles(directory);
  const content = join(directory, "attachments", ATTACHMENT, "content");
  await mkdir(join(directory, "attachments", ATTACHMENT), { recursive: true });
  await writeFile(content, "invented attachment content");
  await files.write([{ path: `attachments/${ATTACHMENT}/content`, staged: content },
    { path: `attachments/${ATTACHMENT}/metadata.json`, bytes: Buffer.from("{\"complete\":true}") }]);
  assert.equal(await readFile(content, "utf8"), "invented attachment content");

  const staging = await StagingFile.create(join(directory, "history/assets"));
  await staging.append(Buffer.from("invented "));
  await staging.append(Buffer.from("asset"));
  await staging.sync();
  await files.write([{ path: "history/assets/invented-digest", staged: staging.path }]);
  await staging.discard();
  const abandoned = await StagingFile.create(join(directory, "history/assets"));
  await abandoned.append(Buffer.from("never verified"));
  await abandoned.discard();
  assert.deepEqual(await filesUnder(directory), [`attachments/${ATTACHMENT}/content`, `attachments/${ATTACHMENT}/metadata.json`, "history/assets/invented-digest"]);
  assert.equal(await readFile(join(directory, "history/assets/invented-digest"), "utf8"), "invented asset");
});

test("a write refuses a path outside the three trees, or one with a temporary name, before it writes anything", async (t) => {
  const directory = await unstampedDirectory(t), files = new LocalFiles(directory);
  for (const path of ["auth.json", "session.sqlite", "diagnostics/startup.jsonl", "attachments", "feedback/", "/feedback/latest", "feedback//latest",
    "feedback/../auth.json", "./feedback/latest", "history/other", "historyX/assets/a", "attachmentsX/a", "feedback/a\\b",
    "feedback/.hidden", "feedback/latest.tmp", `attachments/.${ATTACHMENT}/content`]) {
    await assert.rejects(files.write([{ path: "feedback/latest", bytes: Buffer.from(BUNDLE) }, { path, bytes: Buffer.from("refused") }]),
      /retained file path/, path);
  }
  assert.deepEqual(await filesUnder(directory), []);
});

test("startup cleanup removes temporary files and unfinished uploads, and nothing a write could name", async (t) => {
  const directory = await unstampedDirectory(t), files = new LocalFiles(directory);
  const complete = "44444444-4444-4444-8444-444444444444", unfinished = "55555555-5555-4555-8555-555555555555", unnamed = "66666666-6666-4666-8666-666666666666";
  await files.write([{ path: `attachments/${complete}/content`, bytes: Buffer.from("kept") },
    { path: `attachments/${complete}/metadata.json`, bytes: Buffer.from(JSON.stringify({ complete: true, retained: false })) },
    { path: `feedback/${BUNDLE}.json`, bytes: Buffer.from("{}") }, { path: "feedback/latest", bytes: Buffer.from(BUNDLE) },
    { path: "history/assets/invented-digest", bytes: Buffer.from("kept asset") }]);
  const kept = await filesUnder(directory);
  const stray = { [`attachments/${unfinished}/content`]: "half", [`attachments/${unfinished}/metadata.json`]: JSON.stringify({ complete: false }),
    [`attachments/${unnamed}/content`]: "no metadata", [`attachments/${complete}/.metadata.json.tmp`]: "", [`attachments/${complete}/metadata.json.tmp`]: "",
    [`feedback/latest.${BUNDLE}.tmp`]: "", "feedback/.22222222-2222-4222-8222-222222222222.tmp": "", "history/assets/.77777777-7777-4777-8777-777777777777": "",
    "diagnostics/.outside.tmp": "outside the trees", "session.sqlite-journal.tmp": "outside the trees" };
  for (const [path, text] of Object.entries(stray)) {
    await mkdir(join(directory, path, ".."), { recursive: true });
    await writeFile(join(directory, path), text);
  }
  await cleanRetainedFiles(directory);
  assert.deepEqual(await filesUnder(directory), [...kept, "diagnostics/.outside.tmp", "session.sqlite-journal.tmp"].sort());
  await cleanRetainedFiles(directory);
  assert.deepEqual(await filesUnder(directory), [...kept, "diagnostics/.outside.tmp", "session.sqlite-journal.tmp"].sort(), "a second run changes nothing");
});
