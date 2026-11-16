import AgentCore
import AppIntents
import Foundation
import Observation
import UserNotifications

#if os(iOS)
  import UIKit
#endif

enum AlertOrigin: Equatable {
  case unnamed
  case named(ProfileID)
  case malformed
}

enum OpenDestination: Hashable {
  case feed(notice: String?)
  case job(ScopedEntityID)
}

struct OpenRequest: Equatable {
  let id = UUID()
  let destination: OpenDestination
}

public enum MainVisibility: Equatable {
  case hidden
  case visible(atLatest: Bool)
}

/// The app delegate owns OS registration; the coordinator owns delivery. As the
/// process-scoped object, it also owns the saved coordinators.
@MainActor @Observable
public final class AppNotifications: NSObject {
  public let registration: NotificationRegistration
  public let coordinators: Coordinators
  public var mainVisible: MainVisibility = .hidden
  private(set) var openRequest: OpenRequest?
  #if DEBUG
    /// What a Debug launch asked for.
    public enum InteractionLaunch {
      case plain
      /// The launch's one interaction fixture, which acts in place of the app delegate.
      case fixture(AppNotifications)
      case unavailable(reason: String)
    }

    /// Set once by the app before any scene and before the app delegate finishes launching. The
    /// app delegate exists earlier, so until then `receiver()` throws.
    public static var interactionLaunch: InteractionLaunch?

    struct InteractionFixtureUnavailable: Error, CustomLocalizedStringResourceConvertible {
      let reason: String
      var localizedStringResource: LocalizedStringResource { "\(reason)" }
    }
  #endif

  /// The object that alert taps and intents act on, which is the interaction fixture's when the
  /// launch has one. It throws when the launch lacks the fixture it asked for, or has not set one
  /// yet, rather than reach the app's own saved coordinators.
  func receiver() throws -> AppNotifications {
    #if DEBUG
      switch Self.interactionLaunch {
      case .plain: return self
      case .fixture(let fixture): return fixture
      case .unavailable(let reason): throw InteractionFixtureUnavailable(reason: reason)
      case nil:
        throw InteractionFixtureUnavailable(
          reason: "This launch has not yet chosen whether it uses the interaction fixture.")
      }
    #else
      return self
    #endif
  }

  public var intentCoordinators: Coordinators {
    get throws { try receiver().coordinators }
  }

  /// False while the phone is locked and files it protects cannot be read or written.
  var protectedDataAvailable: Bool {
    #if os(iOS)
      UIApplication.shared.isProtectedDataAvailable
    #else
      true
    #endif
  }

  func open(_ origin: AlertOrigin) {
    openRequest = OpenRequest(destination: .feed(notice: coordinators.show(opening: origin)))
  }

  func open(_ job: JobEntity) {
    openRequest = OpenRequest(destination: .job(job.id))
  }

  func presents(_ origin: AlertOrigin?) -> Bool {
    guard registration.enabled else { return false }
    guard case .visible(let atLatest) = mainVisible else { return true }
    let chat = coordinators.chat
    guard chat.multiple else { return false }
    guard atLatest, let origin, let routed = coordinators.route(origin) else { return true }
    return !chat.scope.shows(routed)
  }

  public override convenience init() { self.init(defaults: .standard) }

  public convenience init(defaults: UserDefaults) {
    self.init(
      defaults: defaults, applicationSupport: .applicationSupportDirectory,
      caches: .cachesDirectory, transport: .tailnet,
      persistence: ComposerDraftStore(
        url: URL.applicationSupportDirectory.appending(path: "Agent/Composer/draft.json")),
      sharedInbox: try? SharedDraftInbox.configured(), spotlight: Self.appSpotlight)
    AppDependencyManager.shared.add(dependency: self)
  }

  /// The app's own index on a phone. A Mac test host has none, so no test writes the Mac's own
  /// Spotlight.
  private static var appSpotlight: (any SpotlightStore)? {
    #if os(iOS)
      CoreSpotlightStore()
    #else
      nil
    #endif
  }

  init(
    defaults: UserDefaults, applicationSupport: URL, caches: URL, transport: CoordinatorTransport,
    persistence: ComposerDraftStore? = nil, sharedInbox: SharedDraftInbox? = nil,
    spotlight: (any SpotlightStore)? = nil,
    permission: @escaping @MainActor () async throws -> Bool = AppNotifications.alertPermission
  ) {
    let registration = NotificationRegistration(
      enabled: defaults.object(forKey: "notificationsEnabled") == nil
        || defaults.bool(forKey: "notificationsEnabled"),
      permission: permission,
      register: {
        #if os(iOS)
          UIApplication.shared.registerForRemoteNotifications()
        #endif
      },
      save: { defaults.set($0, forKey: "notificationsEnabled") })
    self.registration = registration
    coordinators = Coordinators(
      registration: registration, defaults: defaults, applicationSupport: applicationSupport,
      caches: caches, transport: transport, persistence: persistence, sharedInbox: sharedInbox,
      spotlight: spotlight)
    super.init()
  }

  /// Apple's alert permission.
  static func alertPermission() async throws -> Bool {
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    switch settings.authorizationStatus {
    case .notDetermined:
      return try await center.requestAuthorization(options: [.alert, .sound])
    case .authorized, .provisional: return true
    #if os(iOS)
      case .ephemeral: return true
    #endif
    case .denied: return false
    @unknown default: return false
    }
  }

  /// Asks for alerts at launch, only when this object acts for the launch. Under an interaction
  /// fixture it stays idle like the coordinators, since a launch that the system starts has no
  /// `-notificationsEnabled NO`, and the fixture asks for itself.
  func startRegistration() async {
    #if DEBUG
      guard (try? receiver()) === self else { return }
    #endif
    await registration.start()
  }

  nonisolated static func origin(_ userInfo: [AnyHashable: Any]) -> AlertOrigin? {
    guard var agent = userInfo["agent"] as? [String: Any] else { return nil }
    let key = agent.removeValue(forKey: "installation_id")
    guard JSONSerialization.isValidJSONObject(agent),
      let data = try? JSONSerialization.data(withJSONObject: agent),
      (try? JSONDecoder().decode(NotificationTarget.self, from: data)) != nil
    else { return nil }
    switch key {
    case .none, .some(is NSNull): return .unnamed
    case .some(let wire as String):
      return ProfileID(wire: wire).map(AlertOrigin.named) ?? .malformed
    case .some: return .malformed
    }
  }
}

#if os(iOS)
  extension AppNotifications: UIApplicationDelegate {
    public func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
      UNUserNotificationCenter.current().delegate = self
      Task { await startRegistration() }
      return true
    }

    public func application(
      _ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data
    ) {
      let value = token.map { String(format: "%02x", $0) }.joined()
      Task { await registration.received(token: value) }
    }

    public func application(
      _ application: UIApplication,
      didFailToRegisterForRemoteNotificationsWithError error: any Error
    ) {
      registration.failed()
    }
  }

  extension AppNotifications: UNUserNotificationCenterDelegate {
    public nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      willPresent notification: UNNotification,
      withCompletionHandler completionHandler:
        @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
      let origin = Self.origin(notification.request.content.userInfo)
      DispatchQueue.main.async {
        let presents = (try? self.receiver())?.presents(origin) ?? false
        completionHandler(presents ? [.banner, .sound] : [])
      }
    }

    public nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
      let origin = Self.origin(response.notification.request.content.userInfo)
      DispatchQueue.main.async {
        if let origin { try? self.receiver().open(origin) }
        completionHandler()
      }
    }
  }
#endif
