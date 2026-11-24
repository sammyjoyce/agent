/**
 * Public entrypoint for the Effect-native Rex SDK.
 *
 * Re-exports the SDK aggregate, configuration, branded IDs, typed errors, layouts, events,
 * the control connection, every namespace service, and the generated wire models. Wire
 * snake_case representations stay inside the generated codecs.
 *
 * @since 0.1.0
 */
export * from "./rex-sdk.ts";
export * from "./rex-config.ts";
export * from "./rex-domain.ts";
export * from "./rex-errors.ts";
export * from "./rex-layout.ts";
export * from "./rex-events.ts";
export * from "./rex-terminal-stream.ts";
export * from "./rex-terminal-text.ts";
export * from "./rex-output-query.ts";
export * from "./rex-terminal-activity.ts";
export * from "./rex-terminal-watch.ts";
export {
  REX_BYTES_DATA_SUBPROTOCOL,
  REX_TERMINAL_DATA_SUBPROTOCOL,
} from "./rex-data-connection.ts";
export type { RexBytesStream, RexBytesStreamLimits } from "./rex-bytes-stream.ts";
export * from "./rex-file-transfer.ts";
export {
  RexControl,
  rexControlLayer,
  rexControlLayerWithoutDependencies,
  type IRexControl,
  type RexControlConnectError,
  type RexControlConnectionInfo,
  type RexControlEvent,
  type RexControlResponse,
  type RexRequestOptions,
} from "./rex-control.ts";
export {
  RexAttachments,
  rexAttachmentsLayer,
  rexAttachmentsLayerWithoutDependencies,
  type IRexAttachments,
  type RexEventScope,
} from "./rex-attachments.ts";
export { rexCoreLayer, rexCoreLayerWithoutDependencies } from "./rex-core.ts";
export type {
  RexBlockMethodArgs,
  RexBlockMethodOperation,
  RexBlockMethodResult,
  RexBlockNoArgsOperation,
  RexBlockTarget,
  RexMethodInput,
  RexMethodOperation,
  RexMethodResult,
  RexNoInputOperation,
} from "./rex-operation.ts";
export * from "./server-service.ts";
export * from "./session-service.ts";
export * from "./window-service.ts";
export * from "./block-service.ts";
export * from "./layer-service.ts";
export * from "./terminal-service.ts";
export * from "./tunnel-service.ts";
export * from "./client-service.ts";
export * from "./event-service.ts";
export * from "./target-service.ts";
export * from "./host-service.ts";
export * from "./creator-service.ts";
export * from "./generated/rex-wire-schemas.ts";
