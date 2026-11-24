/**
 * Schema combinators for representations the Rex wire uses but Effect Schema does not name.
 *
 * Rex is written in Go, whose JSON encoder writes an empty slice as `null` and often leaves
 * empty slices out entirely. The SDK reads both as an empty array, so callers never branch on
 * a difference that carries no meaning.
 *
 * @since 0.1.0
 */
import { Effect, Schema, SchemaTransformation } from "effect";

/**
 * Decodes a wire array that may be `null` into an array, encoding an array unchanged.
 *
 * @category schemas
 * @since 0.1.0
 */
export function arrayFromNullOr<Item extends Schema.Top>(item: Item) {
  return Schema.NullOr(Schema.Array(item)).pipe(
    Schema.decodeTo(
      Schema.Array(Schema.toType(item)),
      SchemaTransformation.transform({
        decode: (value) => value ?? [],
        encode: (value) => value,
      }),
    ),
  );
}

/**
 * Decodes a wire array that may be missing or `null` into an array.
 *
 * @category schemas
 * @since 0.1.0
 */
export function optionalArrayFromNullOr<Item extends Schema.Top>(item: Item) {
  return arrayFromNullOr(item).pipe(Schema.withDecodingDefaultKey(Effect.succeed(null)));
}
