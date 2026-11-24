/**
 * The server's host list: the other Rex servers its clients connect to by label.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import { RexAttachments } from "./rex-attachments.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayer } from "./rex-core.ts";
import type { RexConfigurationError } from "./rex-errors.ts";
import {
  rexMethodOperation,
  rexNoInputOperation,
  type RexMethodOperation,
  type RexNoInputOperation,
} from "./rex-operation.ts";

/**
 * Host list operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IHostService {
  /** `hosts.list`: the server's hosts, with a hash that identifies the list. */
  readonly list: RexNoInputOperation<"hosts.list">;
  /** `hosts.put`: adds a host, or replaces the host with the same ID; repeating a request adds nothing. */
  readonly put: RexMethodOperation<"hosts.put">;
  /** `hosts.remove`: removes a host; removing one that isn't listed succeeds and changes nothing. */
  readonly remove: RexMethodOperation<"hosts.remove">;
}

/**
 * Yieldable host service.
 *
 * @category services
 * @since 0.1.0
 */
export class HostService extends Context.Service<HostService, IHostService>()(
  "rex-sdk/HostService",
) {}

/**
 * Constructs host operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeHostService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  return HostService.of({
    list: rexNoInputOperation(control, attachments, "hosts.list"),
    put: rexMethodOperation(control, attachments, "hosts.put"),
    remove: rexMethodOperation(control, attachments, "hosts.remove"),
  });
});

/**
 * Host operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const hostServiceLayerWithoutDependencies: Layer.Layer<
  HostService,
  never,
  RexControl | RexAttachments
> = Layer.effect(HostService, makeHostService);

/**
 * Host operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const hostServiceLayer: Layer.Layer<HostService, RexConfigurationError> =
  hostServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
