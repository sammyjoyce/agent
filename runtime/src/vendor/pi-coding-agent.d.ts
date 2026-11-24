// The vendored Rex tool table imports these types from the Pi coding agent,
// which this runtime does not depend on. Only the fields it uses are declared.
declare module "@earendil-works/pi-coding-agent" {
  export interface ToolAnnotations {
    readonly title?: string;
    readonly readOnlyHint?: boolean;
    readonly destructiveHint?: boolean;
    readonly idempotentHint?: boolean;
    readonly openWorldHint?: boolean;
  }
  export interface AgentToolResult<TDetails> {
    content: { type: "text"; text: string }[];
    structuredContent?: unknown;
    details: TDetails;
  }
}
