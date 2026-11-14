import AgentCore
import AppIntents

public struct OpenCoordinatorIntent: OpenIntent {
  public static let title: LocalizedStringResource = "Open Coordinator"
  public static let description = IntentDescription(
    "Shows a saved coordinator's feed in Beep Boop. The draft in the composer stays as it is.")

  @Parameter(title: "Coordinator", description: "The saved coordinator to show.")
  public var target: CoordinatorEntity

  @Dependency private var notifications: AppNotifications

  public init() {}

  /// For tests, which run outside the perform flow that resolves `@Dependency`.
  init(target: CoordinatorEntity, notifications: AppNotifications) {
    self.target = target
    self.notifications = notifications
  }

  /// Takes the route an alert tap takes, so both open a coordinator the same way.
  @MainActor public func perform() async throws -> some IntentResult {
    notifications.open(ProfileID(wire: target.id).map(AlertOrigin.named) ?? .malformed)
    return .result()
  }
}
