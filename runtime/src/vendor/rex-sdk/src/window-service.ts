/**
 * Windows, which are the tabs of a session: creation, focus, order, labels, and closing.
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
 * Window operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IWindowService {
  /** `session.close_window`: closes a window, or the active one, and every block in it. */
  readonly close: RexMethodOperation<"session.close_window">;
  /** `session.focus_window`: makes a window active; focus returns to the block it last had focused. */
  readonly focus: RexMethodOperation<"session.focus_window">;
  /** `session.focus_next_window`: makes the next window active. */
  readonly focusNext: RexMethodOperation<"session.focus_next_window">;
  /** `session.focus_previous_window`: makes the previous window active. */
  readonly focusPrevious: RexMethodOperation<"session.focus_previous_window">;
  /** `session.move_window`: moves a window in the session's window order. */
  readonly move: RexMethodOperation<"session.move_window">;
  /** `session.set_window_label`: sets a window's label; an empty label restores the default. */
  readonly setLabel: RexMethodOperation<"session.set_window_label">;
  /** `session.new_window`: creates a window and its blocks; it becomes active unless `focus` is false. */
  readonly create: (
    input: Omit<RexMethodInput<"session.new_window">, "layout"> & {
      readonly layout?: RexLayoutNode;
    },
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_window">, RexOperationError>;
}

/**
 * Yieldable window service.
 *
 * @category services
 * @since 0.1.0
 */
export class WindowService extends Context.Service<WindowService, IWindowService>()(
  "rex-sdk/WindowService",
) {}

/**
 * Constructs window operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeWindowService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const newWindow = rexMethodOperation(control, attachments, "session.new_window");
  return WindowService.of({
    create: Effect.fn("WindowService.create")(function* (input, options) {
      const { layout, ...rest } = input;
      const encoded =
        layout === undefined ? undefined : yield* encodeRexLayout("session.new_window", layout);
      return yield* newWindow(
        { ...rest, ...(encoded === undefined ? {} : { layout: encoded }) },
        options,
      );
    }),
    close: rexMethodOperation(control, attachments, "session.close_window"),
    focus: rexMethodOperation(control, attachments, "session.focus_window"),
    focusNext: rexMethodOperation(control, attachments, "session.focus_next_window"),
    focusPrevious: rexMethodOperation(control, attachments, "session.focus_previous_window"),
    move: rexMethodOperation(control, attachments, "session.move_window"),
    setLabel: rexMethodOperation(control, attachments, "session.set_window_label"),
  });
});

/**
 * Window operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const windowServiceLayerWithoutDependencies: Layer.Layer<
  WindowService,
  never,
  RexControl | RexAttachments
> = Layer.effect(WindowService, makeWindowService);

/**
 * Window operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const windowServiceLayer: Layer.Layer<WindowService, RexConfigurationError> =
  windowServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
