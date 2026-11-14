import AgentUI
import SwiftUI

@main
struct AgentApp: App {
  @UIApplicationDelegateAdaptor(AppNotifications.self) private var notifications
  /// One per process, like the coordinators, so every window shares one microphone and one model.
  @State private var dictation = Dictation(engine: .parakeet)
  // App-level phase aggregates every scene, so a second iPad window cannot fight the first.
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if let fixture = InteractionFixture.fromEnvironment(notifications: notifications) {
          fixture
        } else {
          MainChatView(notifications: notifications, dictation: dictation)
        }
      #else
        MainChatView(notifications: notifications, dictation: dictation)
      #endif
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      #if DEBUG
        if InteractionFixture.isRequested { return }
      #endif
      dictation.setForeground(phase != .background)
      Task { await notifications.coordinators.setActive(phase == .active) }
    }
  }
}
