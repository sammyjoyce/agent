/**
 * Composes the complete Effect-native Rex SDK.
 *
 * `RexSdk` is a yieldable aggregate of the namespace services. Its production Layer shares one
 * configuration, one control connection, and one attachment tracker across every namespace;
 * direct service Layers keep their requirements visible for custom composition.
 *
 * @since 0.1.0
 */
import { Context, Effect, Layer } from "effect";
import {
  BlockService,
  blockServiceLayerWithoutDependencies,
  type IBlockService,
} from "./block-service.ts";
import {
  ClientService,
  clientServiceLayerWithoutDependencies,
  type IClientService,
} from "./client-service.ts";
import {
  CreatorService,
  creatorServiceLayerWithoutDependencies,
  type ICreatorService,
} from "./creator-service.ts";
import {
  EventService,
  eventServiceLayerWithoutDependencies,
  type IEventService,
} from "./event-service.ts";
import {
  HostService,
  hostServiceLayerWithoutDependencies,
  type IHostService,
} from "./host-service.ts";
import {
  LayerService,
  layerServiceLayerWithoutDependencies,
  type ILayerService,
} from "./layer-service.ts";
import { RexAttachments } from "./rex-attachments.ts";
import {
  RexConfig,
  rexConfigLayer,
  rexConfigLayerFromOptions,
  type IRexConfig,
  type RexConfigOptions,
} from "./rex-config.ts";
import { RexControl } from "./rex-control.ts";
import { rexCoreLayerWithoutDependencies } from "./rex-core.ts";
import { rexIds, type IRexIds } from "./rex-domain.ts";
import type { RexConfigurationError } from "./rex-errors.ts";
import {
  ServerService,
  serverServiceLayerWithoutDependencies,
  type IServerService,
} from "./server-service.ts";
import {
  SessionService,
  sessionServiceLayerWithoutDependencies,
  type ISessionService,
} from "./session-service.ts";
import {
  TargetService,
  targetServiceLayerWithoutDependencies,
  type ITargetService,
} from "./target-service.ts";
import {
  TerminalService,
  terminalServiceLayerWithoutDependencies,
  type ITerminalService,
} from "./terminal-service.ts";
import {
  TunnelService,
  tunnelServiceLayerWithoutDependencies,
  type ITunnelService,
} from "./tunnel-service.ts";
import {
  WindowService,
  windowServiceLayerWithoutDependencies,
  type IWindowService,
} from "./window-service.ts";

/**
 * The namespaces of the Rex SDK.
 *
 * Rex calls a tab a window and a pane a block.
 *
 * @category services
 * @since 0.1.0
 */
export interface IRexSdk {
  /** The configuration shared by the whole SDK. */
  readonly config: IRexConfig;
  /** Pure constructors for branded IDs. */
  readonly ids: IRexIds;
  /** Server identity, status, configuration, Tailscale, and macOS file access. */
  readonly server: IServerService;
  /** Sessions: create, destroy, attach, view, and watch. */
  readonly sessions: ISessionService;
  /** Windows, which are a session's tabs. */
  readonly windows: IWindowService;
  /** Blocks, which are a window's panes: split, move, focus, zoom, close, and input. */
  readonly blocks: IBlockService;
  /** Floating layers above a window's layout. */
  readonly layers: ILayerService;
  /** Terminal blocks: type, read, wait for exit, and stream output. */
  readonly terminals: ITerminalService;
  /** Tunnel blocks that forward TCP connections between the server's machine and their owner. */
  readonly tunnels: ITunnelService;
  /** Connected clients such as Rex.app, and requests between clients. */
  readonly clients: IClientService;
  /** Live events. */
  readonly events: IEventService;
  /** Lookup of sessions, windows, blocks, and clients by label, position, or short ID. */
  readonly targets: ITargetService;
  /** The server's host list. */
  readonly hosts: IHostService;
  /** The block creators the server offers. */
  readonly creators: ICreatorService;
}

/**
 * Yieldable Rex SDK aggregate.
 *
 * @category services
 * @since 0.1.0
 */
export class RexSdk extends Context.Service<RexSdk, IRexSdk>()("rex-sdk/RexSdk") {}

/**
 * Aggregates the namespace services without constructing or proxying them.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeRexSdk = Effect.gen(function* () {
  return RexSdk.of({
    config: yield* RexConfig,
    ids: rexIds,
    server: yield* ServerService,
    sessions: yield* SessionService,
    windows: yield* WindowService,
    blocks: yield* BlockService,
    layers: yield* LayerService,
    terminals: yield* TerminalService,
    tunnels: yield* TunnelService,
    clients: yield* ClientService,
    events: yield* EventService,
    targets: yield* TargetService,
    hosts: yield* HostService,
    creators: yield* CreatorService,
  });
});

/**
 * The SDK aggregate, leaving its namespace services as requirements.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexSdkLayerWithoutDependencies = Layer.effect(RexSdk, makeRexSdk);

/**
 * Every namespace service, leaving the shared infrastructure as requirements.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexNamespaceServicesLayerWithoutDependencies = Layer.mergeAll(
  serverServiceLayerWithoutDependencies,
  sessionServiceLayerWithoutDependencies,
  windowServiceLayerWithoutDependencies,
  blockServiceLayerWithoutDependencies,
  layerServiceLayerWithoutDependencies,
  terminalServiceLayerWithoutDependencies,
  tunnelServiceLayerWithoutDependencies,
  clientServiceLayerWithoutDependencies,
  eventServiceLayerWithoutDependencies,
  targetServiceLayerWithoutDependencies,
  hostServiceLayerWithoutDependencies,
  creatorServiceLayerWithoutDependencies,
);

function makeRexSdkLayer(
  configLayer: Layer.Layer<RexConfig, RexConfigurationError>,
): Layer.Layer<RexSdk | RexControl | RexAttachments | RexConfig, RexConfigurationError> {
  const shared = rexCoreLayerWithoutDependencies.pipe(Layer.provideMerge(configLayer));
  const namespaces = rexNamespaceServicesLayerWithoutDependencies.pipe(Layer.provideMerge(shared));
  return rexSdkLayerWithoutDependencies.pipe(Layer.provideMerge(namespaces));
}

/**
 * The SDK configured from the environment, sharing one control connection.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexSdkLayer = makeRexSdkLayer(rexConfigLayer);

/**
 * The SDK configured from explicit options, falling back to the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export function rexSdkLayerFromOptions(options: RexConfigOptions) {
  return makeRexSdkLayer(rexConfigLayerFromOptions(options));
}
