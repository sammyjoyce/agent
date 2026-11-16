import Foundation

/// Text a Siri send may carry. What the confirmation shows is what the agent reads.
public struct SiriMessage: Sendable, Equatable {
  public let text: String
  public static let maximumCharacters = 1000
  public enum Refusal: Error, Sendable, Equatable, CaseIterable {
    case blank, tooLong, command, hidden, lineBreak
  }

  public init(parsing raw: String) throws(Refusal) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw .blank }
    guard raw.utf8.count <= 65536 else { throw .tooLong }
    guard !trimmed.hasPrefix("/"), trimmed != "?" else { throw .command }
    text = raw
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
}

/// Which copy a confirmed send writes. `new` is minted before the confirmation.
public enum SiriCopy: Sendable, Equatable {
  case new(inputID: String)
  case earlier(inputID: String)
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
