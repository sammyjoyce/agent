import AgentUI
import CarPlay
import UIKit

/// The car screen's scene, which the manifest names. Only iOS 26.4 and later have the voice-based
/// conversation category, so earlier systems never show Beep Boop in the car.
final class CarPlayScene: UIResponder, CPTemplateApplicationSceneDelegate {
  /// A `CarScreen`. A stored property cannot be limited to iOS 26.4.
  private var screen: AnyObject?

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didConnect interfaceController: CPInterfaceController
  ) {
    guard #available(iOS 26.4, *) else { return }
    let conversation = AppNotifications.current.flatMap {
      try? CarConversation(notifications: $0, engine: .parakeet, speaker: .onDevice)
    }
    screen = CarScreen(interface: interfaceController, conversation: conversation)
  }

  func templateApplicationScene(
    _ templateApplicationScene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    end()
    screen = nil
  }

  func sceneWillResignActive(_ scene: UIScene) { end() }

  private func end() {
    guard #available(iOS 26.4, *) else { return }
    (screen as? CarScreen)?.end()
  }
}
