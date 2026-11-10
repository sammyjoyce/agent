import AgentUI
import SwiftUI

@main
struct AgentApp: App {
  @UIApplicationDelegateAdaptor(AppNotifications.self) private var notifications
  // App-level phase aggregates every scene, so a second iPad window cannot fight the first.
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let fixture = InteractionFixture.fromEnvironment() {
          fixture
        } else {
          MainChatView(notifications: notifications)
        }
      #else
        MainChatView(notifications: notifications)
      #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      #if DEBUG
        if InteractionFixture.isRequested { return }
      #endif
      Task { await notifications.coordinators.setActive(phase == .active) }
    }
  }
}
