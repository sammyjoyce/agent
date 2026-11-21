import AgentCore
import AppIntents
import Foundation

public struct SendMessageIntent: AppIntent {
  public static let title: LocalizedStringResource = "Send Message"
  public static let description = IntentDescription(
    "Sends one line to a saved coordinator after you confirm it. It never runs commands.")
  public static let authenticationPolicy: IntentAuthenticationPolicy =
    .requiresLocalDeviceAuthentication
  public static let openAppWhenRun = false

  @Parameter(
    title: "Message",
    description: "The single-line message to send, without a leading slash command.",
    requestValueDialog: "What's the message?")
  public var message: String

  @Parameter(title: "Coordinator", description: "The saved coordinator to receive the message.")
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
  /// A throw from `confirm`, as when the person cancels, saves and sends nothing.
  /// `protectedDataAvailable` is read before anything else, and again when the outbox could not
  /// be read or saved, so a phone that locked meanwhile is named.
  @MainActor static func send(
    _ text: String, to coordinator: CoordinatorEntity, in coordinators: Coordinators,
    protectedDataAvailable: () -> Bool,
    confirm: (LocalizedStringResource) async throws -> Void
  ) async throws -> SiriSendOutcome {
    let message: SiriMessage
    do { message = try SiriMessage(parsing: text) } catch { return SiriSendOutcome(error) }
    let name = coordinator.name
    guard protectedDataAvailable() else { return SiriSendOutcome(.notSent(.locked), to: name) }
    var result: SiriSendResult
    do {
      guard let id = ProfileID(wire: coordinator.id) else { throw SiriNotSent.removed }
      let earlier = try await coordinators.siriEarlier(message, to: id)
      // A copy the coordinator accepted needs no confirmation and no connection.
      if case .accepted(let savedAt) = earlier {
        return SiriSendOutcome(.alreadyDelivered(savedAt), to: name)
      }
      if let dialog = confirmation(earlier, to: name, reading: message) {
        try await confirm(dialog)
      }
      result = try await coordinators.sendFromSiri(
        message, confirmed: earlier, newInputID: UUID().uuidString, to: id)
    } catch let reason as SiriNotSent { result = .notSent(reason) }
    if result == .notSent(.outboxUnreadable) || result == .notSent(.outboxNotSaved),
      !protectedDataAvailable()
    {
      result = .notSent(.locked)
    }
    return SiriSendOutcome(result, to: name)
  }

  /// What the person confirms before a send, or nil when the coordinator already accepted this
  /// copy. The coordinator's name comes first and the message last, after a fixed lead-in, so the
  /// message cannot change which coordinator the sentence names.
  static func confirmation(_ earlier: SiriEarlier, to name: String, reading message: SiriMessage)
    -> LocalizedStringResource?
  {
    let text = message.text
    switch earlier {
    case .none: return "Send to \(name)? The message reads: \(text)"
    case .waiting(_, let savedAt):
      return
        "An earlier copy of this message to \(name), saved at \(time(savedAt)), is not confirmed. Send that copy again? The message reads: \(text)"
    case .delivered(let sentAt):
      return
        "\(name) already has this message, sent at \(time(sentAt)). Send it again? The message reads: \(text)"
    case .accepted: return nil
    }
  }
}

private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

/// What Send Message says, and the code it returns.
public struct SiriSendOutcome: Sendable {
  /// The intent's value, such as `delivered` or `notSent.locked`.
  public let code: String
  public let dialog: LocalizedStringResource
}

extension SiriSendOutcome {
  /// No sentence for a send that saved nothing blames the coordinator, and each says so.
  init(_ result: SiriSendResult, to name: String) {
    let retries = "It stays on this iPhone, and asking again retries this copy."
    switch result {
    case .delivered: self.init(code: "delivered", dialog: "Sent to \(name).")
    case .alreadyDelivered(let at):
      self.init(
        code: "alreadyDelivered",
        dialog: "\(name) already has this message, from \(time(at)). Nothing new was sent.")
    case .saved:
      self.init(
        code: "saved",
        dialog:
          "Saved on this iPhone, but \(name) has not confirmed it. Ask again to retry this copy.")
    case .rejected:
      self.init(code: "refused", dialog: "\(name) did not accept the message. \(retries)")
    case .failed(let reason):
      let sentence = reason.hasSuffix(".") ? reason : reason + "."
      self.init(code: "refused", dialog: "\(name) reported a problem: \(sentence) \(retries)")
    case .notSent(let reason):
      self.init(code: "notSent.\(reason)", dialog: Self.notSent(reason, to: name))
    }
  }

  private static func notSent(_ reason: SiriNotSent, to name: String) -> LocalizedStringResource {
    switch reason {
    case .locked: "Unlock your iPhone to send messages to \(name). Nothing was sent."
    case .unanswered: "\(name) did not answer. Nothing was sent."
    case .outboxUnreadable:
      "The messages saved for \(name) on this iPhone could not be read. Nothing was sent."
    case .outboxNotSaved: "This iPhone could not save the message. Nothing was sent."
    case .notAdvertised:
      "\(name) needs an update before it takes messages from Siri. Nothing was sent."
    case .outboxFull:
      "Too many messages are waiting for \(name) on this iPhone. Open Beep Boop to resolve them. Nothing was sent."
    case .busy: "Beep Boop is busy with \(name). Try again in a moment. Nothing was sent."
    case .removed: "\(name) is no longer saved in Beep Boop. Nothing was sent."
    case .notPaired: "\(name) is not paired yet. Nothing was sent."
    case .copyGone: "The earlier copy is no longer on this iPhone. Nothing was sent."
    case .changed:
      "Another copy of this message reached \(name) while you were confirming. Nothing was sent."
    }
  }

  init(_ refusal: SiriMessage.Refusal) {
    let dialog: LocalizedStringResource =
      switch refusal {
      case .blank: "There is no message to send."
      case .tooLong:
        "Siri sends messages of at most 1,000 characters. Open Beep Boop to send a longer one."
      case .command: "Beep Boop does not run commands from Siri. Open Beep Boop to send it."
      case .hidden:
        "The message has characters that the confirmation cannot show. Open Beep Boop to send it."
      case .lineBreak: "Siri sends one line at a time. Open Beep Boop to send several lines."
      }
    self.init(code: "refusal.\(refusal)", dialog: dialog)
  }
}

extension SiriNotSent {
  init(_ error: LaneError) {
    switch error {
    case .gone: self = .removed
    case .notPaired: self = .notPaired
    case .outboxUnreadable: self = .outboxUnreadable
    case .unanswered, .interrupted: self = .unanswered
    }
  }
}

extension Coordinators {
  /// What coordinator `id`'s outbox holds of earlier Siri copies of `message`. It reads the
  /// outbox, and dials nothing. It throws `SiriNotSent`.
  func siriEarlier(_ message: SiriMessage, to id: ProfileID) async throws -> SiriEarlier {
    do {
      return try await chat.onLane(id) { try await $0.siriEarlier(message) }
    } catch let error as LaneError {
      throw SiriNotSent(error)
    }
  }

  /// Sends `message` to coordinator `id` over a lease, as the person confirmed it against
  /// `confirmed`. One limit covers the connection and the coordinator's answer. The session that
  /// connected answers, even if an address edit replaces it meanwhile, so what it saved is
  /// reported. It throws `SiriNotSent` when nothing was sent, and `CancellationError` for a task
  /// cancelled before the send.
  func sendFromSiri(
    _ message: SiriMessage, confirmed: SiriEarlier, newInputID: String, to id: ProfileID
  ) async throws -> SiriSendResult {
    let limit = ConnectionLease.connectionWait
    let deadline = ContinuousClock.now + limit
    do {
      return try await chat.withConnection(to: id, within: limit) { session in
        await session.sendFromSiri(
          message, confirmed: confirmed, newInputID: newInputID, until: deadline)
      }
    } catch let error as LaneError {
      throw SiriNotSent(error)
    }
  }
}
