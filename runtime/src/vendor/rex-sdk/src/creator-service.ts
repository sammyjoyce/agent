/**
 * The block creators a server offers: their flavors, options, methods, and events.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { RexConfigurationError } from "./rex-errors.ts";
import { rexNoInputOperation, type RexNoInputOperation } from "./rex-operation.ts";

/**
 * Block creator discovery.
 *
 * @category services
 * @since 0.1.0
 */
export interface ICreatorService {
  /** `block_creator.list`: every creator the server can make blocks with, and their flavors. */
  readonly list: RexNoInputOperation<"block_creator.list">;
}

/**
 * Yieldable creator service.
 *
 * @category services
 * @since 0.1.0
 */
export class CreatorService extends Context.Service<CreatorService, ICreatorService>()(
  "rex-sdk/CreatorService",
) {}

/**
 * Constructs creator operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeCreatorService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  return CreatorService.of({
    list: rexNoInputOperation(control, attachments, "block_creator.list"),
  });
});

/**
 * Creator operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const creatorServiceLayerWithoutDependencies: Layer.Layer<
  CreatorService,
  never,
  RexControl | RexAttachments
> = Layer.effect(CreatorService, makeCreatorService);

/**
 * Creator operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const creatorServiceLayer: Layer.Layer<CreatorService, RexConfigurationError> =
  creatorServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
