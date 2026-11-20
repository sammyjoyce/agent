import AgentCore
import Foundation

/// Ends a take without a touch. The speech engine has no silence detection, so the car decides
/// from the take's own words and loudness. A take with words ends once it has heard neither voice
/// nor new words for a while. Voice keeps it open while the next partial is still coming, since
/// partials trail speech, and new words keep a quiet speaker's take open.
struct Endpointer {
  struct Policy: Sendable, Equatable {
    var voiceLevel: Float = 0.45
    /// Quiet after the last voice and the last new words that ends a take with words.
    var trailingQuiet: Duration
    /// How long a take may hear no words before it ends as silence.
    var noWords: Duration
    /// The longest take, which then ends as if quiet.
    var longest: Duration

    static let message = Policy(
      trailingQuiet: .milliseconds(1400), noWords: .seconds(7), longest: .seconds(45))
    static let confirmation = Policy(
      trailingQuiet: .milliseconds(900), noWords: .seconds(5), longest: .seconds(6))
  }

  /// How far a partial can trail the voice it transcribes. Parakeet decodes chunks of 13 frames
  /// with 13 more to their right, so words show about two seconds after they are said.
  static let partialLag: Duration = .milliseconds(2100)

  enum Verdict: Equatable {
    /// The take is over and keeps the words it heard.
    case finish
    case silence
    case interrupted
  }

  private let policy: Policy
  private let start: ContinuousClock.Instant
  private var words = ""
  /// Stays true once any partial had words, even if a later one clears them, since the take's
  /// text comes from `finish`, not from the last partial.
  private var heardWords = false
  private var lastVoice: ContinuousClock.Instant?
  private var lastChange: ContinuousClock.Instant

  init(_ policy: Policy, startedAt start: ContinuousClock.Instant) {
    self.policy = policy
    self.start = start
    lastChange = start
  }

  mutating func hear(_ event: RecordingEvent, at now: ContinuousClock.Instant) -> Verdict? {
    switch event {
    case .level(let level): if level >= policy.voiceLevel { lastVoice = now }
    case .partial(let partial):
      if partial != words {
        words = partial
        lastChange = now
        if partial.contains(where: { $0.isLetter || $0.isNumber }) { heardWords = true }
      }
    case .interrupted: return .interrupted
    }
    return verdict(at: now)
  }

  /// A take never ends as silence while words for voice it heard before its no-words limit may
  /// still be coming, since `finish` decodes everything heard. Sound after the limit is too late,
  /// so steady noise cannot hold a take open.
  func verdict(at now: ContinuousClock.Instant) -> Verdict? {
    let voiceRecent =
      lastVoice.map { now < min($0, start + policy.noWords) + Self.partialLag } ?? false
    let wordsMayCome = heardWords || voiceRecent
    if now >= start + policy.longest { return wordsMayCome ? .finish : .silence }
    guard heardWords else {
      return now >= start + policy.noWords && !wordsMayCome ? .silence : nil
    }
    return now >= max(lastVoice ?? start, lastChange) + policy.trailingQuiet ? .finish : nil
  }
}

/// A whole short utterance the car takes as an answer or an instruction rather than a message.
/// Only an exact match counts once case, punctuation and surrounding space are dropped, so "yes,
/// but rename it" is never taken as yes.
enum VoicePhrase: Equatable {
  case yes, no, end, other

  static let yesPhrases: Set<String> = [
    "yes", "yeah", "yep", "yup", "sure", "send", "send it", "yes send it", "yeah send it",
    "okay send it", "yes please", "ok", "okay", "do it", "go ahead", "correct", "confirm",
  ]
  static let noPhrases: Set<String> = [
    "no", "nope", "don't", "do not", "don't send it", "do not send it", "no don't", "cancel",
    "wait", "change it",
  ]
  static let endPhrases: Set<String> = [
    "stop", "goodbye", "bye", "that's all", "that's it", "never mind", "nothing", "end",
  ]

  init(_ heard: String) {
    let kept = heard.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
      .unicodeScalars.filter { $0 == "'" || !CharacterSet.punctuationCharacters.contains($0) }
    let phrase = String(String.UnicodeScalarView(kept)).split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    self =
      if Self.yesPhrases.contains(phrase) {
        .yes
      } else if Self.noPhrases.contains(phrase) {
        .no
      } else if Self.endPhrases.contains(phrase) {
        .end
      } else {
        .other
      }
  }
}

enum SpokenReply {
  /// About forty seconds of speech.
  static let limit = 600
  static let rest = "The rest is in the chat."

  /// Prose, headings, quotes and list items as sentences. A code block or a table is named, not
  /// read. Links read as their text, and a bare web address in any case as "a link" that keeps
  /// the punctuation after it. A longer reply is cut at the last sentence end that fits, or else
  /// the last word, and closes with `rest`.
  static func speech(from markdown: String, limit: Int = limit) -> String {
    let sentences = RichText.parse(markdown).compactMap { block -> String? in
      switch block {
      case .prose(let text), .heading(let text, _), .quote(let text), .listItem(let text, _, _):
        return sentence(String(text.characters))
      case .code: return "There's a code block in the chat."
      case .table: return "There's a table in the chat."
      case .divider: return nil
      }
    }
    let speech = sentences.filter { !$0.isEmpty }.joined(separator: " ")
    guard speech.count > limit else { return speech }
    let room = speech.prefix(limit - rest.count - 1)
    let end = room.indices.last { index in
      ".!?".contains(room[index]) && room.index(after: index) < speech.endIndex
        && speech[room.index(after: index)] == " "
    }
    if let end { return String(speech[...end]) + " " + rest }
    let word = room.lastIndex(of: " ") ?? room.startIndex
    return String(room[..<word]) + "… " + rest
  }

  private static func sentence(_ text: String) -> String {
    let webAddress = /(?i)\b(?:https?:\/\/|www\.)\S+?(?=[.,;:!?'")\]]*(?:\s|$))/
    let words = text.replacing(webAddress, with: "a link")
      .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard let last = words.last, !".!?:;".contains(last) else { return words }
    return words + "."
  }
}

enum CarRefusal: Error, Equatable {
  /// Dictation on the iPhone holds the microphone.
  case microphoneBusy
  /// The car never offers the voice model's download.
  case noVoiceModel
  case voiceUnsupported
  /// Denied, or never asked. The car never shows the system prompt.
  case noMicrophone
  /// The lock, or what Send Message also refuses for.
  case notSent(SiriNotSent)

  /// The first reason in this order, or nil to go on. A stale model goes on, since its first take
  /// compiles it.
  static func preflight(
    protectedData: Bool, model: SpeechModel, microphone: MicrophonePermission
  ) -> CarRefusal? {
    guard protectedData else { return .notSent(.locked) }
    switch model {
    case .missing: return .noVoiceModel
    case .unsupported: return .voiceUnsupported
    case .stale, .ready: break
    }
    return microphone == .granted ? nil : .noMicrophone
  }
}

/// Every sentence the car speaks. None asks the driver to unlock, pick up, open or tap the
/// iPhone, to download anything or to allow anything.
enum CarSentence {
  static func opening(_ name: String) -> String { "Talking to \(name)." }
  static func readBack(_ message: SiriMessage, to name: String) -> String {
    "Send to \(name): \(message.text)?"
  }
  static let notSent = "Not sent."
  static let notSentGoAhead = "Not sent. Go ahead."

  static func refusal(_ refusal: CarRefusal, name: String) -> String {
    switch refusal {
    case .microphoneBusy: "The microphone is busy."
    case .noVoiceModel: "Voice input isn't set up in Beep Boop yet."
    case .voiceUnsupported: "Voice input doesn't work on this iPhone."
    case .noMicrophone: "Beep Boop isn't allowed to use the microphone."
    case .notSent(let reason): notSent(reason, name: name)
    }
  }

  static func refusal(_ refusal: SiriMessage.Refusal) -> String {
    switch refusal {
    case .blank: "I didn't catch that."
    case .tooLong: "That's too long for one message."
    case .command: "Beep Boop doesn't run commands from the car."
    case .hidden, .lineBreak: "I couldn't send that as one line."
    }
  }

  static func reply(_ reply: VoiceReply, from name: String) -> String {
    switch reply {
    case .answered(let text):
      let speech = SpokenReply.speech(from: text)
      return speech.isEmpty ? noReadableReply : speech
    case .noReadableReply: return noReadableReply
    case .stopped: return "\(name) stopped without an answer."
    case .stillWorking: return "\(name) is still working on it. The answer will be in the chat."
    case .unconfirmed: return "\(name) hasn't confirmed the message. Beep Boop kept a copy."
    case .rejected: return "\(name) didn't accept the message."
    case .failed: return "\(name) reported a problem."
    case .lostConnection(delivered: true):
      return "Lost the connection to \(name). It has your message."
    case .lostConnection(delivered: false):
      return
        "Lost the connection to \(name) before it confirmed the message. Beep Boop kept a copy."
    case .notSent(let reason): return notSent(reason, name: name) + " Nothing was sent."
    }
  }

  private static let noReadableReply = "There's no reply I can read here."

  private static func notSent(_ reason: SiriNotSent, name: String) -> String {
    switch reason {
    case .locked: "Beep Boop can't send messages while iPhone is locked."
    case .unanswered: "\(name) isn't answering."
    case .outboxUnreadable: "Beep Boop can't read the messages saved for \(name)."
    case .outboxNotSaved: "This iPhone couldn't save the message."
    case .notAdvertised: "\(name) needs an update before it can talk in the car."
    case .outboxFull: "Too many messages are waiting for \(name)."
    case .busy: "Beep Boop is busy with \(name)."
    case .removed: "\(name) is no longer saved in Beep Boop."
    case .notPaired: "\(name) isn't paired yet."
    case .copyGone: "The earlier copy is no longer on this iPhone."
    case .changed: "Another copy of this message reached \(name)."
    }
  }
}

extension VoiceReply {
  /// Whether the car listens for another message after saying this one's outcome. It goes on
  /// after an outcome for this message alone, and stops when the next one is unlikely to fare
  /// better.
  var continuesConversation: Bool {
    switch self {
    case .answered, .noReadableReply, .stopped, .rejected, .failed: true
    case .stillWorking, .unconfirmed, .lostConnection, .notSent: false
    }
  }
}
