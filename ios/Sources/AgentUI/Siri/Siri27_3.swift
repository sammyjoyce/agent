#if AGENT_IOS_27_3_SDK
  import AppIntents

  /// Siri may call Open Coordinator and Send Message as tools on iOS 27.3+.
  /// Open Job and Retry Interrupted Run stay non-tools: resolving `JobEntity` dials every paired
  /// coordinator over Tailscale, and Retry Interrupted Run mutates remote job state without an
  /// interactive confirmation dialog.
  @available(iOS 27.3, macOS 27.3, *)
  extension OpenCoordinatorIntent: ToolIntent {}

  @available(iOS 27.3, macOS 27.3, *)
  extension SendMessageIntent: ToolIntent {}

  /// Defense in depth alongside `.complete` file and Spotlight protection and each intent's own
  /// `authenticationPolicy` (Apple's iOS 27.3 release notes record known issue 190573761 where
  /// Siri AI may not proactively request unlock for entity policies). An entity's policy is the
  /// minimum policy for all of its properties, and every `@Property` on both entities is meant for
  /// Siri and Shortcuts (`IntentVisibility.default`), while private fields stay off the entities
  /// altogether.
  @available(iOS 27.3, macOS 27.3, *)
  extension CoordinatorEntity {
    public static let authenticationPolicy: IntentAuthenticationPolicy =
      .requiresLocalDeviceAuthentication
  }

  @available(iOS 27.3, macOS 27.3, *)
  extension JobEntity {
    public static let authenticationPolicy: IntentAuthenticationPolicy =
      .requiresLocalDeviceAuthentication
  }
#endif
