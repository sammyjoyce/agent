import AgentCore
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

struct OpenRequest: Equatable {
  let id = UUID()
  let notice: String?
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
    @ObservationIgnored private weak var fixtureTarget: AppNotifications?
    @ObservationIgnored private var pendingFixtureOrigin: AlertOrigin?

    func forwardFixtureOpens(to target: AppNotifications) {
      fixtureTarget = target
      if let origin = pendingFixtureOrigin {
        pendingFixtureOrigin = nil
        target.open(origin)
      }
    }
  #endif

  func open(_ origin: AlertOrigin) {
    #if DEBUG
      if let fixtureTarget {
        fixtureTarget.open(origin)
        return
      }
      pendingFixtureOrigin = origin
    #endif
    openRequest = OpenRequest(notice: coordinators.show(opening: origin))
  }

  func presents(_ origin: AlertOrigin?) -> Bool {
    #if DEBUG
      if let fixtureTarget { return fixtureTarget.presents(origin) }
    #endif
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
      sharedInbox: try? SharedDraftInbox.configured())
  }

  init(
    defaults: UserDefaults, applicationSupport: URL, caches: URL, transport: CoordinatorTransport,
    persistence: ComposerDraftStore? = nil, sharedInbox: SharedDraftInbox? = nil
  ) {
    let registration = NotificationRegistration(
      enabled: defaults.object(forKey: "notificationsEnabled") == nil
        || defaults.bool(forKey: "notificationsEnabled"),
      permission: {
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
      },
      register: {
        #if os(iOS)
          UIApplication.shared.registerForRemoteNotifications()
        #endif
      },
      save: { defaults.set($0, forKey: "notificationsEnabled") })
    self.registration = registration
    coordinators = Coordinators(
      registration: registration, defaults: defaults, applicationSupport: applicationSupport,
      caches: caches, transport: transport, persistence: persistence, sharedInbox: sharedInbox)
    super.init()
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
      Task { await registration.start() }
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
        completionHandler(self.presents(origin) ? [.banner, .sound] : [])
      }
    }

    public nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter,
      didReceive response: UNNotificationResponse,
      withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
      let origin = Self.origin(response.notification.request.content.userInfo)
      DispatchQueue.main.async {
        if let origin { self.open(origin) }
        completionHandler()
      }
    }
  }
#endif
