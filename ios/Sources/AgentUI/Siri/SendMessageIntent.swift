import AgentCore
import AppIntents
import Foundation

public struct SendMessageIntent: AppIntent {
  public static let title: LocalizedStringResource = "Send Message"
  public static let description = IntentDescription(
    "Sends one line to a saved coordinator after asking you to confirm it. It never runs commands.")
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
  public static let openAppWhenRun = false

  @Parameter(title: "Message", requestValueDialog: "What's the message?")
  public var message: String

  @Parameter(title: "Coordinator")
  public var coordinator: CoordinatorEntity

  @Dependency private var notifications: AppNotifications

  public init() {}

  @MainActor public func perform() async throws
    -> some IntentResult & ReturnsValue<String> & ProvidesDialog
  {
    let notifications = notifications
    let outcome = try await Self.send(
      message, to: coordinator, in: notifications.intentCoordinators,
      protectedDataAvailable: { notifications.protectedDataAvailable },
      confirm: { try await requestConfirmation(actionName: .send, dialog: IntentDialog($0)) })
    return .result(value: outcome.code, dialog: IntentDialog(outcome.dialog))
  }

  /// Sends `text` to `coordinator` in `coordinators` once `confirm` returns, and says how it went.
  @MainActor static func send(
    _ text: String, to coordinator: CoordinatorEntity, in coordinators: Coordinators,
    protectedDataAvailable: () -> Bool,
    confirm: (LocalizedStringResource) async throws -> Void
  ) async throws -> SiriSendOutcome {
    let message: SiriMessage
    do { message = try SiriMessage(parsing: text) } catch { return SiriSendOutcome(error) }
    let name = coordinator.name
    guard let id = ProfileID(wire: coordinator.id) else {
      return SiriSendOutcome(.notSent(.removed), to: name)
    }
    let earlier = SiriEarlier.none
    if let dialog = confirmation(earlier, to: name, reading: message) { try await confirm(dialog) }
    let result = try await coordinators.sendFromSiri(
      message, copy: .new(inputID: UUID().uuidString), earlier: earlier, to: id)
    return SiriSendOutcome(result, to: name)
  }

  /// What the person confirms before a send.
  static func confirmation(_ earlier: SiriEarlier, to name: String, reading message: SiriMessage)
    -> LocalizedStringResource?
  {
    "Send \"\(message.text)\" to \(name)?"
  }
}

/// What Send Message says, and the code it returns.
public struct SiriSendOutcome: Sendable {
  /// The intent's value, such as `delivered` or `notSent.locked`.
  public let code: String
  public let dialog: LocalizedStringResource
}

extension SiriSendOutcome {
  init(_ result: SiriSendResult, to name: String) {
    switch result {
    case .delivered: self.init(code: "delivered", dialog: "Sent to \(name).")
    case .alreadyDelivered: self.init(code: "alreadyDelivered", dialog: "Sent to \(name).")
    case .saved: self.init(code: "saved", dialog: "Saved. \(name) has not confirmed it yet.")
    case .rejected: self.init(code: "refused", dialog: "\(name) did not take the message.")
    case .failed(let reason):
      self.init(code: "refused", dialog: "\(name) did not take the message. \(reason)")
    case .notSent(let reason):
      self.init(code: "notSent.\(reason)", dialog: "\(name) did not take the message.")
    }
  }

  init(_ refusal: SiriMessage.Refusal) {
    switch refusal {
    case .blank: self.init(code: "refusal.blank", dialog: "There is no message to send.")
    case .tooLong: self.init(code: "refusal.tooLong", dialog: "Messages must be at most 64 KiB.")
    case .command, .hidden, .lineBreak:
      self.init(
        code: "refusal.\(refusal)",
        dialog: "Beep Boop does not run commands from Siri. Open Beep Boop to send it.")
    }
  }
}

extension Coordinators {
  /// Sends `message` to coordinator `id` over a lease.
  func sendFromSiri(
    _ message: SiriMessage, copy: SiriCopy, earlier: SiriEarlier, to id: ProfileID
  ) async throws -> SiriSendResult {
    let deadline = ContinuousClock.now + ConnectionLease.connectionWait
    do {
      return try await withConnection(to: id) {
        try await chat.session(on: id).sendFromSiri(
          message, copy: copy, earlier: earlier, until: deadline)
      }
    } catch let error as LaneError {
      switch error {
      case .gone: return .notSent(.removed)
      case .notPaired: return .notSent(.notPaired)
      case .outboxUnreadable: return .notSent(.outboxUnreadable)
      case .unanswered: return .notSent(.unanswered)
      case .interrupted: throw error
      }
    }
  }
}
