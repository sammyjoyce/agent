import AgentUI
import Observation
import ScrawlKit
import SwiftUI

@main
struct AgentApp: App {
  @UIApplicationDelegateAdaptor(AppNotifications.self) private var notifications
  @State private var feedback = ScrawlFeedback()
  // App-level phase aggregates every scene, so a second iPad window cannot fight the first.
  @Environment(\.scenePhase) private var scenePhase
  var body: some Scene {
    WindowGroup {
      Group {
        #if DEBUG
          if let fixture = InteractionFixture.fromEnvironment(
            notifications: notifications, feedback: feedback)
          {
            fixture
          } else {
            chat
          }
        #else
          chat
        #endif
      }
      .scrawl(isEnabled: feedback.target != nil)
      // A disabled `.scrawl` ignores setup links, and pairing must work with no coordinator shown.
      .onOpenURL { _ = Scrawl.handleSetupURL($0) }
    }
    .onChange(of: scenePhase, initial: true) { _, phase in
      #if DEBUG
        if InteractionFixture.isRequested { return }
      #endif
      Task { await notifications.coordinators.setActive(phase == .active) }
    }
    .onChange(of: notifications.coordinators.savedNames, initial: true) {
      AgentShortcuts.updateAppShortcutParameters()
    }
  }

  private var chat: some View {
    MainChatView(notifications: notifications)
      .onAppear { notifications.coordinators.feedbackRecorder = feedback }
  }
}

/// Records feedback with ScrawlKit for the coordinator the feed shows, and names that coordinator
/// in each recording's timeline, so the watcher on the Mac sends the recording to it alone.
@MainActor @Observable
final class ScrawlFeedback: FeedbackRecorder {
  private(set) var target: FeedbackTarget?
  /// The typed description for the recording `start(description:)` asked for, until it begins.
  @ObservationIgnored private var pendingDescription: String?
  /// The latest recording that began, by its `recordedAt`, and the claim it took then.
  @ObservationIgnored private var recording: (recordedAt: String, claim: FeedbackRecording?)?

  init() {
    Scrawl.shared.timelineSupplement = { [weak self] timeline in
      await self?.supplement(timeline) ?? [:]
    }
    follow()
  }

  var isPaired: Bool { Scrawl.shared.isConfigured }

  func setTarget(_ target: FeedbackTarget?) { self.target = target }

  func start(description: String) -> FeedbackStart {
    let scrawl = Scrawl.shared
    guard scrawl.isConfigured else { return .unpaired }
    guard !scrawl.isRecording, !scrawl.isStarting else { return .busy }
    pendingDescription = description
    scrawl.start()
    guard scrawl.isStarting || scrawl.isRecording else {
      pendingDescription = nil
      return .busy
    }
    return .started
  }

  /// A recording that begins claims the target and the pending description of that moment. A start
  /// that ends without a recording drops its description.
  private func follow() {
    let scrawl = Scrawl.shared
    let state = withObservationTracking {
      (starting: scrawl.isStarting, recording: scrawl.isRecording)
    } onChange: { [weak self] in
      Task { @MainActor in self?.follow() }
    }
    if state.recording, let began = scrawl.startedAt?.ISO8601Format(),
      recording?.recordedAt != began
    {
      recording = (
        began, target.map { FeedbackRecording(target: $0, description: pendingDescription ?? "") }
      )
      pendingDescription = nil
    } else if !state.starting, !state.recording {
      pendingDescription = nil
    }
  }

  /// The recording's claim, while the feed still shows the coordinator it claimed.
  private func supplement(_ timeline: [String: Any]) async -> [String: Any] {
    guard let recording, recording.recordedAt == timeline["recordedAt"] as? String,
      let claim = recording.claim
    else { return [:] }
    self.recording = nil
    return await claim.timelineSupplement(current: target)
  }
}
