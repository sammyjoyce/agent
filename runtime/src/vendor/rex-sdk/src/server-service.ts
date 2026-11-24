/**
 * Server identity, status, configuration reloads, Tailscale, and macOS file access.
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
 * Server-wide operations.
 *
 * @category services
 * @since 0.1.0
 */
export interface IServerService {
  /** `server.status`: the server's identity, session count, configuration, and Tailscale status. */
  readonly status: RexNoInputOperation<"server.status">;
  /** `server.version`: the Rex version the server runs and how it was built. */
  readonly version: RexNoInputOperation<"server.version">;
  /** `server.whoami`: how the server identified this client, and the account it runs as. */
  readonly whoami: RexNoInputOperation<"server.whoami">;
  /** `server.config_reload`: reloads the configuration file and tells clients to refetch keymaps. */
  readonly reloadConfig: RexNoInputOperation<"server.config_reload">;
  /** `server.stop`: shuts the server down, ending every session; with `ifIdle`, only when unused. */
  readonly stop: RexMethodOperation<"server.stop">;
  /** `help.all`: every method the server provides, with JSON Schemas, as raw JSON. */
  readonly help: RexNoInputOperation<"help.all">;
  /** Built-in Tailscale, which lets devices on a tailnet reach the server. */
  readonly tailscale: {
    /** `server.tailscale.enable`: turns built-in Tailscale on. */
    readonly enable: RexMethodOperation<"server.tailscale.enable">;
    /** `server.tailscale.disable`: turns it off, keeping its sign-in. */
    readonly disable: RexNoInputOperation<"server.tailscale.disable">;
    /** `server.tailscale.login`: asks Tailscale for a sign-in link. */
    readonly login: RexNoInputOperation<"server.tailscale.login">;
    /** `server.tailscale.logout`: signs the server out and turns Tailscale off. */
    readonly logout: RexNoInputOperation<"server.tailscale.logout">;
    /** `server.tailscale.rename`: changes the device name without signing in again. */
    readonly rename: RexMethodOperation<"server.tailscale.rename">;
  };
  /** macOS privacy permissions of the server and the programs it runs. */
  readonly apple: {
    /** `server.apple.grant_file_access`: lets the server read files a Mac app was given. */
    readonly grantFileAccess: RexMethodOperation<"server.apple.grant_file_access">;
    /** `server.apple.privacy_status`: the macOS privacy permissions the server has. */
    readonly privacyStatus: RexNoInputOperation<"server.apple.privacy_status">;
  };
}

/**
 * Yieldable server service.
 *
 * @category services
 * @since 0.1.0
 */
export class ServerService extends Context.Service<ServerService, IServerService>()(
  "rex-sdk/ServerService",
) {}

/**
 * Constructs server operations over the shared control connection.
 *
 * @category constructors
 * @since 0.1.0
 */
export const makeServerService = Effect.gen(function* () {
  const control = yield* RexControl;
  const attachments = yield* RexAttachments;
  return ServerService.of({
    status: rexNoInputOperation(control, attachments, "server.status"),
    version: rexNoInputOperation(control, attachments, "server.version"),
    whoami: rexNoInputOperation(control, attachments, "server.whoami"),
    reloadConfig: rexNoInputOperation(control, attachments, "server.config_reload"),
    stop: rexMethodOperation(control, attachments, "server.stop"),
    help: rexNoInputOperation(control, attachments, "help.all"),
    tailscale: {
      enable: rexMethodOperation(control, attachments, "server.tailscale.enable"),
      disable: rexNoInputOperation(control, attachments, "server.tailscale.disable"),
      login: rexNoInputOperation(control, attachments, "server.tailscale.login"),
      logout: rexNoInputOperation(control, attachments, "server.tailscale.logout"),
      rename: rexMethodOperation(control, attachments, "server.tailscale.rename"),
    },
    apple: {
      grantFileAccess: rexMethodOperation(control, attachments, "server.apple.grant_file_access"),
      privacyStatus: rexNoInputOperation(control, attachments, "server.apple.privacy_status"),
    },
  });
});

/**
 * Server operations, leaving the control connection requirements visible.
 *
 * @category layers
 * @since 0.1.0
 */
export const serverServiceLayerWithoutDependencies: Layer.Layer<
  ServerService,
  never,
  RexControl | RexAttachments
> = Layer.effect(ServerService, makeServerService);

/**
 * Server operations over a control connection configured from the environment.
 *
 * @category layers
 * @since 0.1.0
 */
export const serverServiceLayer: Layer.Layer<ServerService, RexConfigurationError> =
  serverServiceLayerWithoutDependencies.pipe(Layer.provide(rexCoreLayer));
