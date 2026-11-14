import AgentUI
import AppIntents

struct AgentAppIntentsPackage: AppIntentsPackage {
  static var includedPackages: [any AppIntentsPackage.Type] { [AgentUIIntentsPackage.self] }
}

/// The app's only shortcuts provider. It lives in the app target because a provider inside the
/// package ships no phrase.
struct AgentShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: OpenCoordinatorIntent(),
      phrases: ["Open \(\.$target) in \(.applicationName)"],
      shortTitle: "Open Coordinator",
      systemImageName: "bubble.left.and.bubble.right"
    )
  }
}
