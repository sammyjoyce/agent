import AgentCore
import Foundation

/// The one coordinator the feed shows. A feedback recording goes to it alone.
public struct FeedbackTarget: Equatable, Sendable {
  public let profile: ProfileID
  public let coordinator: CoordinatorID
  public let address: CoordinatorAddress

  /// The coordinator `scope` names, or the only one saved. It is nil unless that coordinator is
  /// paired and not being removed, and owns every held message the feed shows. `owners` lists those
  /// messages' owners, with nil for a message no saved coordinator is proven to own.
  static func shown(
    scope: FeedScope, profiles: [CoordinatorProfile], removed: [ProfileID: String],
    owners: [ProfileID?]
  ) -> FeedbackTarget? {
    let id = scope.coordinator ?? (profiles.count == 1 ? profiles[0].id : nil)
    guard let profile = profiles.first(where: { $0.id == id }), removed[profile.id] == nil,
      let pin = profile.pin, owners.allSatisfy({ $0 == profile.id })
    else { return nil }
    return FeedbackTarget(profile: profile.id, coordinator: pin, address: profile.address)
  }
}

/// Records the screen for the coordinator the feed shows. The app implements it with ScrawlKit,
/// which sends the recording to Scrawl on the Mac.
@MainActor public protocol FeedbackRecorder: AnyObject {
  var isPaired: Bool { get }
  /// The coordinator a recording started now would go to, or nil while there is none.
  func setTarget(_ target: FeedbackTarget?)
  /// Starts a recording for the current target that carries `description`.
  func start(description: String) -> FeedbackStart
}

public enum FeedbackStart: Equatable, Sendable {
  case started, unpaired, busy
}

/// Why typed `/feedback` started no recording. The draft stays in the composer.
enum FeedbackRefusal: Equatable {
  case noCoordinator
  case addressedElsewhere(String)
  case files
  case unpaired
  case recording

  init?(_ start: FeedbackStart) {
    switch start {
    case .started: return nil
    case .unpaired: self = .unpaired
    case .busy: self = .recording
    }
  }

  var message: String {
    switch self {
    case .noCoordinator:
      "Feedback goes to the one coordinator on screen. Show a single paired coordinator's conversation, then try again."
    case .addressedElsewhere(let name):
      "Feedback goes only to \(name), the coordinator on screen. Address the draft to \(name) alone."
    case .files:
      "A recording can't carry attached files. Remove them, or send them as a message."
    case .unpaired:
      "Scrawl isn't paired with this phone. Pair it from Scrawl on your Mac, then try again."
    case .recording: "A recording is already running. Stop it, then try again."
    }
  }
}

/// The text after a leading `/feedback`, or nil when `text` is not that command.
func feedbackDescription(in text: String) -> String? {
  let command = text.drop(while: \.isWhitespace)
  guard command.prefix(while: { !$0.isWhitespace }) == "/feedback" else { return nil }
  return command.dropFirst("/feedback".count).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// A recording's claim on the coordinator the feed showed when it started, with the typed
/// `/feedback` description, or "" for a recording the gesture started.
public struct FeedbackRecording: Equatable, Sendable {
  public let target: FeedbackTarget
  public let description: String

  public init(target: FeedbackTarget, description: String) {
    self.target = target
    self.description = description
  }

  /// The `beepBoop` key of the recording's `timeline.json`, which the Mac reads to send it to its
  /// coordinator. It is empty once the feed shows anything but that coordinator, so the Mac refuses
  /// the recording instead of sending it to the wrong one.
  @MainActor public func timelineSupplement(current: FeedbackTarget?) async -> [String: Any] {
    guard current == target else { return [:] }
    let log = await ComposerDiagnostics.export()
    return [
      "beepBoop": [
        "version": 1,
        "coordinatorId": target.coordinator.wire,
        "host": target.address.host,
        "port": Int(target.address.port),
        "description": description,
        "composerLog": log.text,
      ] as [String: Any]
    ]
  }
}
