import CryptoKit
import Foundation

/// Text a Siri send may carry. What the confirmation shows is what the agent reads.
public struct SiriMessage: Sendable, Equatable {
  public let text: String
  public static let maximumCharacters = 1000
  public enum Refusal: Error, Sendable, Equatable, CaseIterable {
    case blank, tooLong, command, hidden, lineBreak
  }

  /// Trims the ends, then refuses blank text, line breaks, scalars with no glyph of their own, a
  /// command, and text longer than Siri can show.
  public init(parsing raw: String) throws(Refusal) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let scalars = Array(text.unicodeScalars)
    guard !scalars.isEmpty else { throw .blank }
    guard !scalars.contains(where: Self.breaksLine) else { throw .lineBreak }
    guard scalars.indices.allSatisfy({ Self.shows(at: $0, in: scalars) }) else { throw .hidden }
    // Scalars, not characters, so a combining mark on the slash still makes a command, as the
    // coordinator reads it.
    guard scalars.first != "/", text != "?" else { throw .command }
    guard text.count <= Self.maximumCharacters else { throw .tooLong }
    self.text = text
  }

  private static func breaksLine(_ scalar: Unicode.Scalar) -> Bool {
    [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029].contains(scalar.value)
  }

  /// Whether the scalar at `index` shows as itself or as part of an emoji the person sees.
  private static func shows(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
    let scalar = scalars[index]
    guard hidesItself(scalar) else { return true }
    guard !(0xE0000...0xE007F).contains(scalar.value) else { return false }
    let isEmoji = { (offset: Int) in
      scalars.indices.contains(index + offset) && scalars[index + offset].properties.isEmoji
    }
    switch scalar.value {
    case 0xFE0E, 0xFE0F: return isEmoji(-1)
    case 0x200D:
      // A presentation selector often sits between an emoji and its joiner, as in the rainbow flag.
      let joinsEmoji = isEmoji(-1) || (index > 1 && scalars[index - 1] == "\u{FE0F}" && isEmoji(-2))
      return joinsEmoji && isEmoji(1)
    default: return false
    }
  }

  private static func hidesItself(_ scalar: Unicode.Scalar) -> Bool {
    let properties = scalar.properties
    switch properties.generalCategory {
    case .control, .format, .privateUse, .surrogate, .unassigned: return true
    default: return properties.isDefaultIgnorableCodePoint || properties.isBidiControl
    }
  }
}

/// What this phone holds of earlier Siri copies of one text to one coordinator.
public enum SiriEarlier: Sendable, Equatable {
  case none
  /// In the outbox, with no acceptance from the coordinator (staged, unconfirmed or refused).
  case waiting(inputID: String, savedAt: Date)
  /// In the outbox, accepted by the coordinator and not yet placed.
  case accepted(savedAt: Date)
  /// Placed within the last hour, from the outbox's Siri receipts.
  case delivered(sentAt: Date)

  /// The newest Siri copy of `message` in `pending`, else the newest of `receipts` from the hour
  /// before `now`.
  static func find(
    _ message: SiriMessage, pending: [OutboxItem], receipts: [SiriReceipt], now: Date
  ) -> SiriEarlier {
    if let item = pending.last(where: {
      $0.request.origin == .siri && $0.request.text == message.text
    }) {
      let savedAt = Date(timeIntervalSince1970: item.queuedAt)
      return item.accepted == true
        ? .accepted(savedAt: savedAt) : .waiting(inputID: item.request.inputId, savedAt: savedAt)
    }
    let digest = SiriReceipt.digest(message.text)
    let since = now.timeIntervalSince1970 - SiriReceipt.lifetime
    guard let receipt = receipts.last(where: { $0.digest == digest && $0.sentAt > since }) else {
      return .none
    }
    return .delivered(sentAt: Date(timeIntervalSince1970: receipt.sentAt))
  }
}

/// Why a Siri send saved nothing.
public enum SiriNotSent: Error, Sendable, Equatable, CaseIterable {
  case locked, unanswered, outboxUnreadable, outboxNotSaved, notAdvertised, outboxFull, busy
  case removed, notPaired, copyGone
  /// Another copy of the message reached the outbox or the coordinator after the confirmation
  /// was built.
  case changed
}

public enum SiriSendResult: Sendable, Equatable {
  /// The coordinator accepted or placed this input ID.
  case delivered
  /// Nothing was written, since the coordinator has this copy.
  case alreadyDelivered(Date)
  /// In the outbox, with no word from the coordinator by the deadline.
  case saved
  /// The coordinator rejected the input. Its reason is written for the composer, so it is dropped.
  case rejected
  /// The exchange that wrote the input failed, in the coordinator's words.
  case failed(String)
  /// This call saved nothing.
  case notSent(SiriNotSent)
}

/// A Siri input this phone saw placed. The outbox keeps it for an hour, so asking again names
/// the delivered copy before a second one goes. It holds a digest, never the text.
struct SiriReceipt: Codable, Equatable, Sendable {
  var digest: String
  var inputID: String
  var sentAt: TimeInterval

  static let lifetime: TimeInterval = 3600
  static let limit = 32

  init(text: String, inputID: String, sentAt: TimeInterval) {
    digest = Self.digest(text)
    self.inputID = inputID
    self.sentAt = sentAt
  }

  static func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  enum CodingKeys: String, CodingKey {
    case digest
    case inputID = "input_id"
    case sentAt = "sent_at"
  }
}

/// The first word on an input a Siri send waits for. Later words are dropped.
final class SiriAnswer: Sendable {
  let words: AsyncStream<SiriSendResult>
  private let continuation: AsyncStream<SiriSendResult>.Continuation
  init() { (words, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1)) }
  func settle(_ result: SiriSendResult) {
    continuation.yield(result)
    continuation.finish()
  }
  /// The first word, or `saved` once `deadline` passes or the waiting task is cancelled.
  func first(until deadline: ContinuousClock.Instant) async -> SiriSendResult {
    await withTaskGroup(of: SiriSendResult.self) { group in
      group.addTask { [words] in
        for await word in words { return word }
        return .saved
      }
      group.addTask {
        try? await Task.sleep(until: deadline, clock: .continuous)
        return .saved
      }
      defer { group.cancelAll() }
      return await group.next() ?? .saved
    }
  }
}
