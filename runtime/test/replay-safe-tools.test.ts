import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const source = fileURLToPath(new URL("../../src/", import.meta.url));

const READS_OWN_STORE = "Reads the coordinator's own store and asks no host.";
const COMMITS = "Its only effect is a Pi commit, which the authority refuses from a fenced owner.";
const READS_A_HOST = "Asks a host to read or compute, and changes nothing there.";

/**
 * Every tool a recovering owner runs again when its call has no result. After
 * a promotion on a wrong statement the old owner can still be inside the first
 * run, so each entry says why a second run beside it duplicates nothing.
 */
const SAFE_UNDER_OVERLAP: Readonly<Record<string, string>> = {
  read_resources: READS_OWN_STORE,
  read_source_events: READS_OWN_STORE,
  list_jobs: READS_OWN_STORE,
  list_sidechats: READS_OWN_STORE,
  read_job: READS_OWN_STORE,
  read_task: READS_OWN_STORE,
  read_agents: READS_OWN_STORE,
  wait_agents: READS_OWN_STORE,
  finish_without_reply: COMMITS,
  notify_user: `${COMMITS} failover-overlap-e2e holds its first run open.`,
  run_job: `${COMMITS} failover-overlap-e2e holds its first run open.`,
  browser_user_tabs: "Commits its pending operation before it asks the host, and a call that finds a pending operation is refused before it asks.",
  browser_status: READS_A_HOST,
  read_file: READS_A_HOST,
  search_tasks: READS_A_HOST,
  read_context: `${READS_A_HOST} Only the coordinator's own host answers it.`,
  search_context: `${READS_A_HOST} Only the coordinator's own host answers it.`,
};

test("every tool declared replay-safe is listed with the reason a second run beside the first duplicates nothing", async () => {
  const files = (await readdir(source, { recursive: true, withFileTypes: true })).filter((entry) => entry.isFile() && entry.name.endsWith(".ts"));
  const declared: string[] = [];
  for (const entry of files) {
    const text = await readFile(`${entry.parentPath}/${entry.name}`, "utf8");
    const tools = [...text.matchAll(/defineTool\(\{\s*name: "([a-z_]+)"/g)];
    for (const flag of text.matchAll(/replay: "safe"/g)) {
      const tool = tools.findLast((match) => match.index < flag.index);
      assert.ok(tool?.[1] !== undefined, `${entry.name} declares replay: "safe" outside a defineTool call that names its tool first`);
      declared.push(tool[1]);
    }
  }
  assert.deepEqual(declared.sort(), Object.keys(SAFE_UNDER_OVERLAP).sort(),
    "A promoted owner runs a replay-safe tool again while a wrongly attested old owner can still be inside its first run. " +
    "A tool that changes something on a host keeps the flag only with a test in failover-overlap-e2e that holds its first run open on a shared worker. " +
    "Otherwise leave the flag off, so the new owner reports the call as interrupted.");
});
