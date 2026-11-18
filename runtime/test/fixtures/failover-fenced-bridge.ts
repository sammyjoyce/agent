import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";

/**
 * Stands in for Pi under `serve`. It answers every command as done and writes
 * nothing. Once `$HOME/bridge-exit` exists it exits with the status that file
 * holds, as a bridge that finds its epoch fenced exits 75.
 */
const exit = join(process.env.HOME ?? "", "bridge-exit");
setInterval(() => { if (existsSync(exit)) process.exit(Number(readFileSync(exit, "utf8"))); }, 20);
const input = createInterface({ input: process.stdin });
input.on("close", () => process.exit(0));
input.on("line", (line) => {
  const { id, command } = JSON.parse(line) as { id: number; command: { type: string } };
  if (command.type === "run_background") return;
  process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "configured" } }) + "\n");
  process.stdout.write(JSON.stringify({ version: 1, id, event: { type: "done" } }) + "\n");
});
