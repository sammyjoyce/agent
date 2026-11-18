import { appendFile, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { AuthorityState } from "../../src/generated/AuthorityState.js";
import type { FailoverReport } from "../../src/generated/FailoverReport.js";
import type { FailoverAnswers } from "./failover/helper.js";

export const holder = "22222222-2222-4222-8222-222222222222";
export const candidate = "55555555-5555-4555-8555-555555555555";

/** Where `dirs::data_local_dir()` keeps floors under the HOME and XDG_DATA_HOME that `coordinatorWorld` sets. */
export function floorFile(home: string, coordinator: string): string {
  const data = process.platform === "darwin" ? join(home, "Library", "Application Support") : join(home, ".local");
  return join(data, "beep-boop-owner-floors", coordinator);
}

export async function answer(home: string, answers: FailoverAnswers): Promise<void> {
  const path = join(home, "failover-answers.json");
  await writeFile(path + ".tmp", JSON.stringify(answers));
  await rename(path + ".tmp", path);
}

/** A coordinator host names its holder. A worker host without one only watches the owner record. */
export async function enableFailover(home: string, options: { holder?: string; watchSeconds?: number }): Promise<void> {
  await writeFile(join(home, "failover-token"), "invented-failover-token", { mode: 0o600 });
  await appendFile(join(home, "agent.toml"), "[failover]\nurl = \"https://authority.example.invalid/coordinators/fixture\"\n" +
    "token_file = \"~/failover-token\"\n" + (options.holder === undefined ? "" : `holder = "${options.holder}"\n`) +
    (options.watchSeconds === undefined ? "" : `watch_interval_seconds = ${options.watchSeconds}\n`));
}

export type HelperRun = { request: { op: string }; session: Record<string, unknown>; answer: FailoverReport | "fail" };

export async function helperRuns(home: string): Promise<HelperRun[]> {
  const text = await readFile(join(home, "failover-runs.ndjson"), "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).map((line) => JSON.parse(line) as HelperRun);
}

export const claimed = (epoch: number): FailoverReport => ({ result: "claimed", epoch, head: 0 });

export const record = (state: AuthorityState): FailoverReport =>
  ({ result: "record", record: { state, checkpoint: { through: 0, manifest: "ab".repeat(32) } } });
