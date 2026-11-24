/**
 * Blocks, the panes of a window: splitting, moving, focusing, zooming, labels, ownership, input, and closing.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl, type RexRequestOptions } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { RexConfigurationError, RexOperationError } from "./rex-errors.ts";
import type { AnchorId, SessionId, WindowId } from "./rex-domain.ts";
import { encodeRexLayout, rexLayout, type RexLayoutNode } from "./rex-layout.ts";
import {
  rexMethodOperation,
  type RexMethodOperation,
  type RexMethodInput,
  type RexMethodResult,
} from "./rex-operation.ts";

/**
 * Arguments of {@link IBlockService.splitBeside}.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexSplitBesideInput {
  /** The session to act on. */
  readonly sessionId: SessionId;
  /** The block or split to open beside; leave it out to use a window's focused block. */
  readonly anchorId?: AnchorId;
  /** The window whose focused block to open beside, when `anchorId` is left out. */
  readonly windowId?: WindowId;
  /** Where the new blocks go relative to the anchor. */
  readonly placement: "right" | "left" | "above" | "below";
  /** The fraction of the space the new blocks get, greater than 0 and less than 1. */
  readonly ratio?: number;
  /** The blocks to create; defaults to a terminal running the user's shell. */
  readonly layout?: RexLayoutNode;
  /** Whether to focus the first new block; defaults to false. */
  readonly focus?: boolean;
}

const splitPlacements = {
  right: { direction: "horizontal", side: "after" },
  left: { direction: "horizontal", side: "before" },
  below: { direction: "vertical", side: "after" },
  above: { direction: "vertical", side: "before" },
} as const;

/**
 * Block operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IBlockService {
  /** `session.new_block`: creates a detached block, to place later with move. */
  readonly create: RexMethodOperation<"session.new_block">;
  /** `session.move_block`: moves a block, or places a detached one, in a new split beside another block. */
  readonly move: RexMethodOperation<"session.move_block">;
  /** `session.swap_blocks`: swaps the places of two blocks. */
  readonly swap: RexMethodOperation<"session.swap_blocks">;
  /** `session.zoom_block`: zooms a block to fill its window, or undoes the zoom. */
  readonly zoom: RexMethodOperation<"session.zoom_block">;
  /** `session.detach_block`: takes a block out of its window without closing it. */
  readonly detach: RexMethodOperation<"session.detach_block">;
  /** `session.float_block`: moves a block out of its window's layout into a new floating layer. */
  readonly float: RexMethodOperation<"session.float_block">;
  /** `session.focus_block`: focuses a block and makes its window active. */
  readonly focus: RexMethodOperation<"session.focus_block">;
  /** `session.focus_direction`: moves focus to the nearest block in a direction. */
  readonly focusDirection: RexMethodOperation<"session.focus_direction">;
  /** `session.focus_next_pane`: moves focus to the next block in the active window. */
  readonly focusNext: RexMethodOperation<"session.focus_next_pane">;
  /** `session.focus_previous_pane`: moves focus to the previous block in the active window. */
  readonly focusPrevious: RexMethodOperation<"session.focus_previous_pane">;
  /** `session.resize_pane`: moves the border between two blocks to change their sizes. */
  readonly resize: RexMethodOperation<"session.resize_pane">;
  /** `session.set_block_label`: sets a block's label; an empty label restores the default. */
  readonly setLabel: RexMethodOperation<"session.set_block_label">;
  /** `session.own_block`: claims blocks for this client; an owner sets a terminal's size and colors. */
  readonly own: RexMethodOperation<"session.own_block">;
  /** `session.disown_block`: gives up this client's claim on blocks. */
  readonly disown: RexMethodOperation<"session.disown_block">;
  /** `session.describe_block`: a block's details and the methods, events, and actions it provides. */
  readonly describe: RexMethodOperation<"session.describe_block">;
  /** `block.close`: closes a block, or a window's focused block, ending its program. */
  readonly close: RexMethodOperation<"block.close">;
  /** `block.event`: sends an input event, such as a key press or a paste, to a block. */
  readonly sendEvent: RexMethodOperation<"block.event">;
  /** `block.method`: calls a method of any block by name and returns its raw result. */
  readonly callMethod: RexMethodOperation<"block.method">;
  /** `session.new_split`: creates blocks in a new split beside a block, a split, or a window's focused block. */
  readonly split: (
    input: Omit<RexMethodInput<"session.new_split">, "layout"> & { readonly layout: RexLayoutNode },
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_split">, RexOperationError>;
  /**
   * Opens new blocks on one side of a block or split, as `rex split --split=SIDE` does.
   *
   * `right` and `left` divide the space side by side; `below` and `above` divide it top and
   * bottom. `ratio` is the fraction the new blocks get. The layout defaults to a shell.
   */
  readonly splitBeside: (
    input: RexSplitBesideInput,
    options?: RexRequestOptions,
  ) => Effect.Effect<RexMethodResult<"session.new_split">, RexOperationError>;
}

/**
 * Yieldable block service.
 *
 * @category services
 * @since 0.1.0
 */
export class BlockService extends Context.Service<BlockService, IBlockService>()(
  "rex-sdk/BlockService",
) {}

/**
 * Constructs block operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeBlockService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  const newSplit = rexMethodOperation(control, attachments, "session.new_split");
  const split = Effect.fn("BlockService.split")(function* (
    input: Omit<RexMethodInput<"session.new_split">, "layout"> & { readonly layout: RexLayoutNode },
    options?: RexRequestOptions,
  ) {
    const layout = yield* encodeRexLayout("session.new_split", input.layout);
    return yield* newSplit({ ...input, layout }, options);
  });
  return BlockService.of({
    split,
    splitBeside: (input, options) => {
      const placement = splitPlacements[input.placement];
      const newShare = input.ratio;
      return split(
        {
          sessionId: input.sessionId,
          ...(input.anchorId === undefined ? {} : { anchorId: input.anchorId }),
          ...(input.windowId === undefined ? {} : { windowId: input.windowId }),
          direction: placement.direction,
          side: placement.side,
          layout: input.layout ?? rexLayout.terminal(),
          ...(newShare === undefined
            ? {}
            : { ratio: placement.side === "before" ? newShare : 1 - newShare }),
          ...(input.focus === undefined ? {} : { focus: input.focus }),
        },
        options,
      );
    },
    create: rexMethodOperation(control, attachments, "session.new_block"),
    move: rexMethodOperation(control, attachments, "session.move_block"),
    swap: rexMethodOperation(control, attachments, "session.swap_blocks"),
    zoom: rexMethodOperation(control, attachments, "session.zoom_block"),
    detach: rexMethodOperation(control, attachments, "session.detach_block"),
    float: rexMethodOperation(control, attachments, "session.float_block"),
    focus: rexMethodOperation(control, attachments, "session.focus_block"),
    focusDirection: rexMethodOperation(control, attachments, "session.focus_direction"),
    focusNext: rexMethodOperation(control, attachments, "session.focus_next_pane"),
    focusPrevious: rexMethodOperation(control, attachments, "session.focus_previous_pane"),
    resize: rexMethodOperation(control, attachments, "session.resize_pane"),
    setLabel: rexMethodOperation(control, attachments, "session.set_block_label"),
    own: rexMethodOperation(control, attachments, "session.own_block"),
    disown: rexMethodOperation(control, attachments, "session.disown_block"),
    describe: rexMethodOperation(control, attachments, "session.describe_block"),
    close: rexMethodOperation(control, attachments, "block.close"),
    sendEvent: rexMethodOperation(control, attachments, "block.event"),
    callMethod: rexMethodOperation(control, attachments, "block.method"),
  });
});

/**
 * Block operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const blockServiceLayerWithoutDependencies: Layer.Layer<
  BlockService,
  never,
  RexControl | RexAttachments
> = Layer.effect(BlockService, makeBlockService);

/**
 * Block operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const blockServiceLayer: Layer.Layer<BlockService, RexConfigurationError> =
  blockServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
