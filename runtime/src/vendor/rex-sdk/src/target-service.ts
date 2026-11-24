/**
 * Looks up sessions, windows, blocks, and clients by ID, label, position, or short ID.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { RexConfigurationError } from "./rex-errors.ts";
import { rexMethodOperation, type RexMethodOperation } from "./rex-operation.ts";

/**
 * Target lookup and completion.
 *
 * @category services
 * @since 0.1.0
 */
export interface ITargetService {
  /** `target.resolve`: looks up each query; each result says whether it matched one thing, nothing, or several. */
  readonly resolve: RexMethodOperation<"target.resolve">;
  /** `target.complete`: lists labels, window positions, and short IDs that start with a prefix. */
  readonly complete: RexMethodOperation<"target.complete">;
}

/**
 * Yieldable target service.
 *
 * @category services
 * @since 0.1.0
 */
export class TargetService extends Context.Service<TargetService, ITargetService>()(
  "rex-sdk/TargetService",
) {}

/**
 * Constructs target operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeTargetService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  return TargetService.of({
    resolve: rexMethodOperation(control, attachments, "target.resolve"),
    complete: rexMethodOperation(control, attachments, "target.complete"),
  });
});

/**
 * Target operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const targetServiceLayerWithoutDependencies: Layer.Layer<
  TargetService,
  never,
  RexControl | RexAttachments
> = Layer.effect(TargetService, makeTargetService);

/**
 * Target operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const targetServiceLayer: Layer.Layer<TargetService, RexConfigurationError> =
  targetServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
