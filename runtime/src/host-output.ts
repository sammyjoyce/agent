import type { ToolExecutionResult } from "@earendil-works/pi-durable";
import type { HostResult } from "./generated/HostResult.js";

export function output(value: unknown, isError = false): ToolExecutionResult {
  return { output: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value) ?? "" }], isError };
}
export function hostOutput(result: HostResult) {
  return output(result, result.type === "failed" || result.type === "creation_uncertain" || result.type === "not_started" ||
    (result.type === "process" && result.exit_code !== 0));
}
