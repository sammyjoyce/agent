/**
 * Floating layers: blocks placed above a window's tiled layout.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl, type RexRequestOptions } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { RexConfigurationError, RexOperationError } from "./rex-errors.ts";
import { encodeRexLayout, type RexLayoutNode } from "./rex-layout.ts";
import {
  rexMethodOperation,
  type RexMethodOperation,
  type RexMethodInput,
  type RexMethodResult,
} from "./rex-operation.ts";

/**
 * Floating layer operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface ILayerService {
  /** `session.close_layer`: closes a floating layer and every block in it. */
  readonly close: RexMethodOperation<"session.close_layer">;
  /** `session.raise_layer`: moves a floating layer to the front, or just above another. */
  readonly raise: RexMethodOperation<"session.raise_layer">;
  /** `session.lower_layer`: moves a floating layer to the back, or just below another. */
  readonly lower: RexMethodOperation<"session.lower_layer">;
  /** `session.resize_layer`: moves or resizes a floating layer; bounds are fractions of the window. */
  readonly resize: RexMethodOperation<"session.resize_layer">;
  /**
   * `session.set_layer_state`: minimizes a floating layer or returns it to normal; with `focus`,
   * also raises it and focuses its last focused block.
   */
  readonly setState: RexMethodOperation<"session.set_layer_state">;
  /** `session.new_layer`: creates blocks in a new floating layer at the front of a window. */
  readonly create: (
    input: Omit<RexMethodInput<"session.new_layer">, "layout"> & { readonly layout: RexLayoutNode },
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_layer">, RexOperationError>;
}

/**
 * Yieldable layer service.
 *
 * @category services
 * @since 0.1.0
 */
export class LayerService extends Context.Service<LayerService, ILayerService>()(
  "rex-sdk/LayerService",
) {}

/**
 * Constructs layer operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeLayerService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const newLayer = rexMethodOperation(control, attachments, "session.new_layer");
  return LayerService.of({
    create: Effect.fn("LayerService.create")(function* (input, options) {
      const layout = yield* encodeRexLayout("session.new_layer", input.layout);
      return yield* newLayer({ ...input, layout }, options);
    }),
    close: rexMethodOperation(control, attachments, "session.close_layer"),
    raise: rexMethodOperation(control, attachments, "session.raise_layer"),
    lower: rexMethodOperation(control, attachments, "session.lower_layer"),
    resize: rexMethodOperation(control, attachments, "session.resize_layer"),
    setState: rexMethodOperation(control, attachments, "session.set_layer_state"),
  });
});

/**
 * Layer operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const layerServiceLayerWithoutDependencies: Layer.Layer<
  LayerService,
  never,
  RexControl | RexAttachments
> = Layer.effect(LayerService, makeLayerService);

/**
 * Layer operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const layerServiceLayer: Layer.Layer<LayerService, RexConfigurationError> =
  layerServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
