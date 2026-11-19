import Foundation

/// How long a car turn waits, from just before its input is written.
public struct VoiceTurnLimits: Sendable, Equatable {
  /// For the coordinator's first word on the input.
  let delivery: Duration
  /// For the completion that names the input's answer entry.
  let answer: Duration
  /// For that entry's text once the completion named it.
  let answerText: Duration

  public static let car = VoiceTurnLimits(
    delivery: .seconds(8), answer: .seconds(60), answerText: .seconds(3))
}

/// What became of one car turn's input. Only `answered` carries text, and only the answer this
/// input's completion named.
public enum VoiceReply: Sendable, Equatable {
  case answered(String)
  /// The coordinator completed the input, and no readable text for its answer reached this phone.
  case noReadableReply
  /// Its work stopped, or is blocked, without an answer.
  case stopped
  /// Delivered, with no completion in time.
  case stillWorking
  /// Saved on this phone, with no word from the coordinator in time. It stays queued for Check.
  case unconfirmed
  case rejected
  /// The exchange that wrote the input reported a failure.
  case failed
  /// The connection ended while waiting. `delivered` says whether the coordinator had the input.
  case lostConnection(delivered: Bool)
  /// Nothing was saved.
  case notSent(SiriNotSent)
}

/// One thing a session learned about a car turn's input, in arrival order.
enum InputWord: Sendable, Equatable {
  /// Accepted or placed.
  case delivered
  case completed(answerEntryID: String)
  /// Its work stopped or is blocked.
  case stopped
  case rejected
  /// Only the exchange that wrote the input says this.
  case failed
  /// The exchange that wrote the input ended. Only that exchange says this.
  case unconfirmed
  /// A keyed answer to any input, since the completion that names its entry may come later.
  case answer(entryID: String, text: String)
  case connectionLost
  case tick

  /// What an acceptance's work says beyond delivery.
  init?(_ work: InputWorkState?) {
    switch work {
    case .completed(let completed)?: self = .completed(answerEntryID: completed.answerEntryId)
    case .stopped?, .blocked?: self = .stopped
    case .queued?, .running?, nil: return nil
    }
  }
}

/// The pure decision of a car turn's wait. A completion and its answer's text arrive in either
/// order, among other inputs' answers. Only the entry this input's completion names is read.
struct VoiceTurnFold {
  /// How many entries' answers a wait keeps until its completion names one. Other inputs' answers
  /// arrive meanwhile, and the oldest entry's goes once the wait holds this many.
  private static let answersKept = 64

  let start: ContinuousClock.Instant
  let limits: VoiceTurnLimits
  private(set) var delivered = false
  private var answerEntryID: String?
  private var completedAt: ContinuousClock.Instant?
  /// The latest answer of each entry heard, in the order those answers arrived.
  private var answers: [(entryID: String, text: String)] = []

  init(start: ContinuousClock.Instant, limits: VoiceTurnLimits) {
    self.start = start
    self.limits = limits
  }

  /// The turn's outcome once `word` decides it, or nil while it keeps waiting.
  mutating func hear(_ word: InputWord, at now: ContinuousClock.Instant) -> VoiceReply? {
    switch word {
    case .delivered: delivered = true
    case .completed(let entryID) where answerEntryID == nil:
      delivered = true
      answerEntryID = entryID
      completedAt = now
      if let answer = answers.last(where: { $0.entryID == entryID }) { return read(answer.text) }
    case .completed: break
    case .stopped: return .stopped
    case .rejected: return .rejected
    case .failed: return .failed
    case .unconfirmed: if !delivered { return .unconfirmed }
    case .answer(let entryID, let text):
      if entryID == answerEntryID { return read(text) }
      answers.removeAll { $0.entryID == entryID }
      answers.append((entryID, text))
      if answers.count > Self.answersKept { answers.removeFirst() }
    case .connectionLost: return .lostConnection(delivered: delivered)
    case .tick: break
    }
    if let completedAt {
      return now >= completedAt + limits.answerText ? .noReadableReply : nil
    }
    if !delivered { return now >= start + limits.delivery ? .unconfirmed : nil }
    return now >= start + limits.answer ? .stillWorking : nil
  }

  /// What a wait cancelled by its caller reports.
  var cancelled: VoiceReply { delivered ? .stillWorking : .unconfirmed }

  private func read(_ text: String) -> VoiceReply {
    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? .noReadableReply : .answered(text)
  }
}

/// A car turn's wait on its input. The session tells it words, which it folds with clock ticks.
final class VoiceTicket: Sendable {
  private let words: AsyncStream<InputWord>
  private let continuation: AsyncStream<InputWord>.Continuation

  init() { (words, continuation) = AsyncStream.makeStream() }

  func hear(_ word: InputWord) { continuation.yield(word) }

  func reply(limits: VoiceTurnLimits, from start: ContinuousClock.Instant) async -> VoiceReply {
    var fold = VoiceTurnFold(start: start, limits: limits)
    let ticks = Task { [continuation] in
      while (try? await Task.sleep(for: .milliseconds(50))) != nil { continuation.yield(.tick) }
    }
    defer { ticks.cancel() }
    for await word in words {
      if let reply = fold.hear(word, at: .now) { return reply }
    }
    return fold.cancelled
  }
}
