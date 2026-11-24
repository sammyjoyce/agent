/**
 * Schema-owned identifiers shared by every Rex namespace.
 *
 * Rex IDs never change and are never reused. Each kind carries a fixed prefix, such as
 * `session:` or `block:`, which the brands check so an ID of one kind cannot be passed where
 * another kind is expected.
 *
 * @since 0.1.0
 */
import { Schema } from "effect";

function prefixedRexIdString(prefix: string) {
  return Schema.String.check(
    Schema.isPattern(new RegExp(`^${prefix}:\\S+$`), {
      expected: `a Rex ${prefix} ID such as ${prefix}:<uuid>`,
    }),
  );
}

/**
 * ID of a Rex session, such as `session:01a1…`.
 *
 * @category schemas
 * @since 0.1.0
 */
export const SessionId = prefixedRexIdString("session").pipe(Schema.brand("SessionId"));

/**
 * ID of a Rex session, such as `session:01a1…`.
 *
 * @category models
 * @since 0.1.0
 */
export type SessionId = typeof SessionId.Type;

/**
 * ID of a Rex window, which is a tab within a session.
 *
 * @category schemas
 * @since 0.1.0
 */
export const WindowId = prefixedRexIdString("window").pipe(Schema.brand("WindowId"));

/**
 * ID of a Rex window, which is a tab within a session.
 *
 * @category models
 * @since 0.1.0
 */
export type WindowId = typeof WindowId.Type;

/**
 * ID of a Rex block, which is one application, usually a terminal, shown as a pane.
 *
 * @category schemas
 * @since 0.1.0
 */
export const BlockId = prefixedRexIdString("block").pipe(Schema.brand("BlockId"));

/**
 * ID of a Rex block, which is one application, usually a terminal, shown as a pane.
 *
 * @category models
 * @since 0.1.0
 */
export type BlockId = typeof BlockId.Type;

/**
 * ID of a split node in a window layout.
 *
 * @category schemas
 * @since 0.1.0
 */
export const SplitId = prefixedRexIdString("split").pipe(Schema.brand("SplitId"));

/**
 * ID of a split node in a window layout.
 *
 * @category models
 * @since 0.1.0
 */
export type SplitId = typeof SplitId.Type;

/**
 * ID of a window layer: the tiled layout or a floating layer above it.
 *
 * @category schemas
 * @since 0.1.0
 */
export const LayerId = prefixedRexIdString("layer").pipe(Schema.brand("LayerId"));

/**
 * ID of a window layer: the tiled layout or a floating layer above it.
 *
 * @category models
 * @since 0.1.0
 */
export type LayerId = typeof LayerId.Type;

/**
 * ID of a program connected to the Rex server, such as Rex.app or this SDK.
 *
 * @category schemas
 * @since 0.1.0
 */
export const ClientId = prefixedRexIdString("client").pipe(Schema.brand("ClientId"));

/**
 * ID of a program connected to the Rex server, such as Rex.app or this SDK.
 *
 * @category models
 * @since 0.1.0
 */
export type ClientId = typeof ClientId.Type;

/**
 * A block or split whose space a new split divides.
 *
 * @category schemas
 * @since 0.1.0
 */
export const AnchorId = Schema.Union([BlockId, SplitId]);

/**
 * A block or split whose space a new split divides.
 *
 * @category models
 * @since 0.1.0
 */
export type AnchorId = typeof AnchorId.Type;

/**
 * Pure constructors that check an ID's prefix and brand it.
 *
 * Use them for IDs that come from outside the SDK, such as `REX_SESSION` or a saved value.
 * IDs returned by SDK operations are already branded.
 *
 * @category models
 * @since 0.1.0
 */
export interface IRexIds {
  /** Brands a `session:` ID, throwing when the prefix is missing. */
  readonly session: (id: string) => SessionId;
  /** Brands a `window:` ID, throwing when the prefix is missing. */
  readonly window: (id: string) => WindowId;
  /** Brands a `block:` ID, throwing when the prefix is missing. */
  readonly block: (id: string) => BlockId;
  /** Brands a `split:` ID, throwing when the prefix is missing. */
  readonly split: (id: string) => SplitId;
  /** Brands a `layer:` ID, throwing when the prefix is missing. */
  readonly layer: (id: string) => LayerId;
  /** Brands a `client:` ID, throwing when the prefix is missing. */
  readonly client: (id: string) => ClientId;
}

/**
 * Pure ID constructors exposed as `RexSdk.ids`.
 *
 * @category constructors
 * @since 0.1.0
 */
export const rexIds: IRexIds = {
  session: (id) => SessionId.make(id),
  window: (id) => WindowId.make(id),
  block: (id) => BlockId.make(id),
  split: (id) => SplitId.make(id),
  layer: (id) => LayerId.make(id),
  client: (id) => ClientId.make(id),
};
