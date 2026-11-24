/**
 * Resolves and provides immutable Rex SDK configuration.
 *
 * The server endpoint comes from explicit options, then `REX_SERVER`, then the platform's
 * default personal-server socket. Ambient `REX_SESSION`, `REX_BLOCK`, and `REX_CLIENT` are
 * exposed for callers to use explicitly; no operation falls back to them on its own.
 *
 * @since 0.1.0
 */
import { homedir, platform } from "node:os";
import { join } from "node:path";
import { Config, Context, Duration, Effect, Layer, Option, Schema } from "effect";
import { BlockId, SessionId } from "./rex-domain.ts";
import { RexConfigurationError } from "./rex-errors.ts";

/**
 * The Rex API revision this SDK was generated for and requires.
 *
 * @category constants
 * @since 0.1.0
 */
export const REX_API_REVISION = 18;

/**
 * Where the Rex server listens: a Unix socket (or Windows named pipe) path, or a URL.
 *
 * @category models
 * @since 0.1.0
 */
export type RexEndpoint =
  | { readonly _tag: "Socket"; readonly path: string }
  | { readonly _tag: "Url"; readonly baseUrl: string };

/**
 * How the SDK identifies itself in the control handshake, for showing to people.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexClientIdentity {
  /** What sort of program this is; Rex knows `app`, `cli`, `agent`, and `other`. */
  readonly kind: "app" | "cli" | "agent" | "other";
  /** The program's name, such as `my-tool`. */
  readonly name: string;
  /** The program's version, as it prints it. */
  readonly version: Option.Option<string>;
  /** A label people use to pick this client, such as `ci`. */
  readonly label: Option.Option<string>;
}

/**
 * Explicit SDK options; each one takes precedence over the environment.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexConfigOptions {
  /**
   * The server address: a socket path, a `unix://` URL, `host:port`, or an `http(s)://` or
   * `ws(s)://` URL. Host labels from `rex hosts` are not resolved; pass the address instead.
   */
  readonly server?: string | undefined;
  /** How the SDK identifies itself; defaults to `{ kind: "other", name: "rex-sdk" }`. */
  readonly client?:
    | {
        readonly kind?: RexClientIdentity["kind"] | undefined;
        readonly name: string;
        readonly version?: string | undefined;
        readonly label?: string | undefined;
      }
    | undefined;
  /** How long to wait for each response; defaults to 10 seconds, like the `rex` CLI. */
  readonly requestTimeout?: Duration.Input | undefined;
  /** How long to wait for the connection and its welcome; defaults to 5 seconds. */
  readonly connectTimeout?: Duration.Input | undefined;
}

/**
 * Immutable configuration shared by the whole SDK graph.
 *
 * @category services
 * @since 0.1.0
 */
export interface IRexConfig {
  /** Where the server listens. */
  readonly endpoint: RexEndpoint;
  /** A readable form of the endpoint for errors and spans. */
  readonly endpointDisplay: string;
  /** How the SDK identifies itself in the handshake. */
  readonly client: RexClientIdentity;
  /** The API revision the SDK requires. */
  readonly apiRevision: typeof REX_API_REVISION;
  /** How long to wait for each response. */
  readonly requestTimeout: Duration.Duration;
  /** How long to wait for the connection and its welcome. */
  readonly connectTimeout: Duration.Duration;
  /** IDs from the environment of the Rex terminal this process runs in, when it runs in one. */
  readonly ambient: {
    /** `REX_SESSION`: the session of the terminal this process runs in. */
    readonly sessionId: Option.Option<SessionId>;
    /** `REX_BLOCK`: the block of the terminal this process runs in. */
    readonly blockId: Option.Option<BlockId>;
    /** `REX_CLIENT`: the default client label or ID set for `rex -C`. */
    readonly client: Option.Option<string>;
  };
}

/**
 * Yieldable configuration service.
 *
 * @category services
 * @since 0.1.0
 */
export class RexConfig extends Context.Service<RexConfig, IRexConfig>()("rex-sdk/RexConfig") {}

/**
 * The environment inputs that endpoint resolution reads.
 *
 * @category models
 * @since 0.1.0
 */
export interface RexEndpointEnvironment {
  readonly platform: string;
  readonly homeDirectory: string;
  readonly xdgRuntimeDir: Option.Option<string>;
  readonly xdgStateHome: Option.Option<string>;
}

/**
 * The default socket of the current user's personal Rex server on a platform.
 *
 * macOS keeps it in Application Support. Linux uses `$XDG_RUNTIME_DIR/rex`; FreeBSD, and Linux
 * without a runtime directory, use `$XDG_STATE_HOME/rex/run` (`~/.local/state/rex/run`).
 *
 * @category constructors
 * @since 0.1.0
 */
export function defaultRexSocketPath(environment: RexEndpointEnvironment): string {
  if (environment.platform === "darwin") {
    return join(environment.homeDirectory, "Library/Application Support/rex/server.sock");
  }
  if (environment.platform === "linux" && Option.isSome(environment.xdgRuntimeDir)) {
    return join(environment.xdgRuntimeDir.value, "rex/server.sock");
  }
  const stateHome = Option.getOrElse(environment.xdgStateHome, () =>
    join(environment.homeDirectory, ".local/state"),
  );
  return join(stateHome, "rex/run/server.sock");
}

/**
 * Parses a server address the way `rex -S` accepts one.
 *
 * @returns The endpoint, or `RexConfigurationError` for a value that is not an address.
 * @category constructors
 * @since 0.1.0
 */
export function parseRexServerAddress(
  address: string,
): Effect.Effect<RexEndpoint, RexConfigurationError> {
  const trimmed = address.trim();
  if (trimmed.startsWith("unix://")) {
    return Effect.try({
      try: () => ({ _tag: "Socket", path: decodeURIComponent(new URL(trimmed).pathname) }) as const,
      catch: (cause) =>
        new RexConfigurationError(
          `the server address ${trimmed} is not a valid unix:// URL`,
          cause,
        ),
    });
  }
  if (trimmed.startsWith("/") || trimmed.startsWith("\\\\")) {
    return Effect.succeed({ _tag: "Socket", path: trimmed });
  }
  const url = /^(https?|wss?):\/\//.test(trimmed)
    ? trimmed
    : /^[^\s/:]+:\d+$/.test(trimmed) || /^\[[^\]]+\]:\d+$/.test(trimmed)
      ? `http://${trimmed}`
      : undefined;
  if (url === undefined) {
    return Effect.fail(
      new RexConfigurationError(
        `the server address ${JSON.stringify(trimmed)} is not a socket path or host:port address; the SDK does not resolve host labels`,
      ),
    );
  }
  return Effect.try({
    try: () => {
      const parsed = new URL(url);
      const protocol = parsed.protocol === "https:" || parsed.protocol === "wss:" ? "wss:" : "ws:";
      return { _tag: "Url", baseUrl: `${protocol}//${parsed.host}` } as const;
    },
    catch: (cause) =>
      new RexConfigurationError(`the server address ${trimmed} is not a valid URL`, cause),
  });
}

function displayRexEndpoint(endpoint: RexEndpoint): string {
  return endpoint._tag === "Socket" ? `unix://${endpoint.path}` : endpoint.baseUrl;
}

const RequestTimeout = Schema.Duration.check(
  Schema.makeFilter((value) =>
    Duration.isFinite(value) && Duration.isGreaterThan(value, Duration.zero)
      ? undefined
      : "must be a finite, positive duration",
  ),
);
const decodeRexTimeout = Schema.decodeEffect(RequestTimeout);

function parseRexTimeout(
  name: string,
  input: Duration.Input | undefined,
  fallback: Duration.Duration,
): Effect.Effect<Duration.Duration, RexConfigurationError> {
  if (input === undefined) return Effect.succeed(fallback);
  return Effect.gen(function* () {
    const duration = yield* Effect.fromOption(Duration.fromInput(input)).pipe(
      Effect.mapError(() => new RexConfigurationError(`${name} is not a duration`)),
    );
    return yield* decodeRexTimeout(duration).pipe(
      Effect.mapError(
        (cause) => new RexConfigurationError(`${name} must be finite and positive`, cause),
      ),
    );
  });
}

const optionalEnvironmentString = (name: string) => Config.option(Config.NonEmptyString(name));

const decodeOptionalSessionId = Schema.decodeEffect(Schema.Option(SessionId));
const decodeOptionalBlockId = Schema.decodeEffect(Schema.Option(BlockId));

/**
 * Resolves configuration from explicit options and the process environment.
 *
 * @returns The configuration, or `RexConfigurationError` when a value is unusable.
 * @category constructors
 * @since 0.1.0
 */
export function makeRexConfig(
  options: RexConfigOptions = {},
): Effect.Effect<IRexConfig, RexConfigurationError> {
  return Effect.gen(function* () {
    const environment = yield* Config.all({
      server: optionalEnvironmentString("REX_SERVER"),
      session: optionalEnvironmentString("REX_SESSION"),
      block: optionalEnvironmentString("REX_BLOCK"),
      client: optionalEnvironmentString("REX_CLIENT"),
      xdgRuntimeDir: optionalEnvironmentString("XDG_RUNTIME_DIR"),
      xdgStateHome: optionalEnvironmentString("XDG_STATE_HOME"),
    }).pipe(
      Effect.mapError(
        (cause) => new RexConfigurationError("the REX_* environment could not be read", cause),
      ),
    );

    const address = options.server ?? Option.getOrUndefined(environment.server);
    const endpoint =
      address === undefined
        ? ({
            _tag: "Socket",
            path: defaultRexSocketPath({
              platform: platform(),
              homeDirectory: homedir(),
              xdgRuntimeDir: environment.xdgRuntimeDir,
              xdgStateHome: environment.xdgStateHome,
            }),
          } as const)
        : yield* parseRexServerAddress(address);

    const requestTimeout = yield* parseRexTimeout(
      "requestTimeout",
      options.requestTimeout,
      Duration.seconds(10),
    );
    const connectTimeout = yield* parseRexTimeout(
      "connectTimeout",
      options.connectTimeout,
      Duration.seconds(5),
    );
    const sessionId = yield* decodeOptionalSessionId(environment.session).pipe(
      Effect.mapError(
        (cause) => new RexConfigurationError("REX_SESSION is not a session ID", cause),
      ),
    );
    const blockId = yield* decodeOptionalBlockId(environment.block).pipe(
      Effect.mapError((cause) => new RexConfigurationError("REX_BLOCK is not a block ID", cause)),
    );

    const client: RexClientIdentity = {
      kind: options.client?.kind ?? "other",
      name: options.client?.name ?? "rex-sdk",
      version: Option.fromUndefinedOr(options.client?.version),
      label: Option.fromUndefinedOr(options.client?.label),
    };

    return RexConfig.of({
      endpoint,
      endpointDisplay: displayRexEndpoint(endpoint),
      client,
      apiRevision: REX_API_REVISION,
      requestTimeout,
      connectTimeout,
      ambient: { sessionId, blockId, client: environment.client },
    });
  });
}

/**
 * Configuration from the environment and platform defaults.
 *
 * @category layers
 * @since 0.1.0
 */
export const rexConfigLayer: Layer.Layer<RexConfig, RexConfigurationError> = Layer.effect(
  RexConfig,
  makeRexConfig(),
);

/**
 * Configuration from explicit options, falling back to the environment for anything left out.
 *
 * @category layers
 * @since 0.1.0
 */
export function rexConfigLayerFromOptions(
  options: RexConfigOptions,
): Layer.Layer<RexConfig, RexConfigurationError> {
  return Layer.effect(RexConfig, makeRexConfig(options));
}
