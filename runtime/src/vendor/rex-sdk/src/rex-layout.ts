/**
 * Typed layouts for the methods that create blocks in a window or floating layer.
 *
 * A layout is a tree: a block node starts one new block from a flavor, and a split node divides
 * its space between two nodes. `session.create`, `session.new_window`, `session.new_split`, and
 * `session.new_layer` take one. The server schema leaves layouts untyped, so this module owns
 * their shape and encodes terminal options with the generated `TerminalShellOptions` codec.
 *
 * @since 0.1.0
 */
import { Effect, Schema } from "effect";
import { TerminalShellOptions } from "./generated/rex-wire-schemas.ts";
import { RexInvalidInput } from "./rex-errors.ts";

/**
 * The flavor of a terminal running a shell or a command.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_TERMINAL_SHELL_FLAVOR = "com.superlogical.terminal.shell";

/**
 * Options for a terminal block, in the SDK's camelCase form.
 *
 * @category models
 * @since 0.1.0
 */
export type RexTerminalOptions = TerminalShellOptions;

/**
 * A layout node that starts a terminal block.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexTerminalLayoutNode {
  readonly _tag: "Terminal";
  /** The block's label, shown on its pane. */
  readonly label?: string | undefined;
  /** The terminal's program, directory, environment, and size. */
  readonly options?: RexTerminalOptions | undefined;
}

/**
 * A layout node that starts a block from any flavor, with options in the flavor's own form.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexBlockLayoutNode {
  readonly _tag: "Block";
  /** The flavor to start, such as `com.superlogical.terminal.shell`. */
  readonly flavor: string;
  /** The block's label, shown on its pane. */
  readonly label?: string | undefined;
  /** Options in the shape of the flavor's `options_schema`, with its own key names. */
  readonly options?: { readonly [key: string]: Schema.Json } | undefined;
}

/**
 * A layout node that divides its space between two nodes.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexSplitLayoutNode {
  readonly _tag: "Split";
  /** `horizontal` puts `before` on the left of `after`; `vertical` puts it on top. */
  readonly direction: "horizontal" | "vertical";
  /** The node on the left or top. */
  readonly before: RexLayoutNode;
  /** The node on the right or bottom. */
  readonly after: RexLayoutNode;
  /** The fraction of the space `before` gets, greater than 0 and less than 1; defaults to 0.5. */
  readonly ratio?: number | undefined;
}

/**
 * A layout tree of blocks and splits.
 *
 * @category models
 * @since 0.1.0
 */
export type RexLayoutNode = RexTerminalLayoutNode | RexBlockLayoutNode | RexSplitLayoutNode;

/**
 * Schema of a layout tree, for callers that receive layouts as data, such as tool arguments.
 * Ratios and terminal options are still checked when the layout is encoded.
 *
 * @category schemas
 * @since 0.1.0
 */
export const RexLayoutNode: Schema.Codec<RexLayoutNode> = Schema.Union([
  Schema.Struct({
    _tag: Schema.Literal("Terminal"),
    label: Schema.optionalKey(Schema.String),
    options: Schema.optionalKey(Schema.toType(TerminalShellOptions)),
  }),
  Schema.Struct({
    _tag: Schema.Literal("Block"),
    flavor: Schema.String,
    label: Schema.optionalKey(Schema.String),
    options: Schema.optionalKey(Schema.Record(Schema.String, Schema.Json)),
  }),
  Schema.Struct({
    _tag: Schema.Literal("Split"),
    direction: Schema.Literals(["horizontal", "vertical"]),
    before: Schema.suspend((): Schema.Codec<RexLayoutNode> => RexLayoutNode),
    after: Schema.suspend((): Schema.Codec<RexLayoutNode> => RexLayoutNode),
    ratio: Schema.optionalKey(Schema.Number),
  }),
]).annotate({ identifier: "RexLayoutNode" });

/**
 * Builders for layout trees.
 *
 * @category constructors
 * @since 0.1.0
 */
export const rexLayout = {
  /** A terminal running the user's shell, or `options.command` when set. */
  terminal: (
    options: RexTerminalOptions & { readonly label?: string | undefined } = {},
  ): RexTerminalLayoutNode => {
    const { label, ...terminalOptions } = options;
    return { _tag: "Terminal", label, options: terminalOptions };
  },
  /** A block of any flavor, with options in the flavor's own form. */
  block: (
    flavor: string,
    options: Omit<RexBlockLayoutNode, "_tag" | "flavor"> = {},
  ): RexBlockLayoutNode => ({ _tag: "Block", flavor, ...options }),
  /** `before` on the left of `after`. */
  horizontal: (
    before: RexLayoutNode,
    after: RexLayoutNode,
    ratio?: number,
  ): RexSplitLayoutNode => ({
    _tag: "Split",
    direction: "horizontal",
    before,
    after,
    ratio,
  }),
  /** `before` above `after`. */
  vertical: (before: RexLayoutNode, after: RexLayoutNode, ratio?: number): RexSplitLayoutNode => ({
    _tag: "Split",
    direction: "vertical",
    before,
    after,
    ratio,
  }),
};

const isValidRatio = (ratio: number) => Number.isFinite(ratio) && ratio > 0 && ratio < 1;

/**
 * Encodes a layout tree into its wire form, rejecting invalid ratios and terminal options.
 *
 * @category constructors
 * @since 0.1.0
 */
export function encodeRexLayout(
  operation: string,
  node: RexLayoutNode,
): Effect.Effect<{ readonly [key: string]: Schema.Json }, RexInvalidInput> {
  return Effect.gen(function* () {
    switch (node._tag) {
      case "Terminal": {
        const options =
          node.options === undefined
            ? undefined
            : yield* Schema.encodeEffect(TerminalShellOptions)(node.options).pipe(
                Effect.mapError((cause) => new RexInvalidInput(operation, cause)),
              );
        return {
          block: {
            flavor: REX_TERMINAL_SHELL_FLAVOR,
            ...(node.label === undefined ? {} : { label: node.label }),
            ...(options === undefined || Object.keys(options).length === 0 ? {} : { options }),
          },
        };
      }
      case "Block":
        return {
          block: {
            flavor: node.flavor,
            ...(node.label === undefined ? {} : { label: node.label }),
            ...(node.options === undefined ? {} : { options: node.options }),
          },
        };
      case "Split": {
        if (node.ratio !== undefined && !isValidRatio(node.ratio)) {
          return yield* new RexInvalidInput(
            operation,
            `layout ratio ${node.ratio} must be greater than 0 and less than 1`,
          );
        }
        const before = yield* encodeRexLayout(operation, node.before);
        const after = yield* encodeRexLayout(operation, node.after);
        return {
          split: {
            direction: node.direction,
            before,
            after,
            ...(node.ratio === undefined ? {} : { ratio: node.ratio }),
          },
        };
      }
    }
  });
}
