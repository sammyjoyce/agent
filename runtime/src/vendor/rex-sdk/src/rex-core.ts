/**
 * The shared infrastructure every namespace service runs on: one control connection and its
 * attachment tracking.
 *
 * @since 0.1.0
 */
import { Layer } from "effect";
import { RexAttachments, rexAttachmentsLayerWithoutDependencies } from "./rex-attachments.ts";
import { RexConfig, rexConfigLayer } from "./rex-config.ts";
import { RexControl, rexControlLayerWithoutDependencies } from "./rex-control.ts";
import type { RexConfigurationError } from "./rex-errors.ts";

/**
 * The control connection and attachment tracking, leaving configuration visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexCoreLayerWithoutDependencies: Layer.Layer<
  RexControl | RexAttachments,
  never,
  RexConfig
> = rexAttachmentsLayerWithoutDependencies.pipe(
  Layer.provideMerge(rexControlLayerWithoutDependencies),
);

/**
 * The control connection and attachment tracking, configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexCoreLayer: Layer.Layer<RexControl | RexAttachments, RexConfigurationError> =
  rexCoreLayerWithoutDependencies.pipe(Layer.provide(rexConfigLayer));
