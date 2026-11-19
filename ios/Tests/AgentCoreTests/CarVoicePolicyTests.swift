import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

@Test func theEndpointerEndsATakeAfterQuietSilenceTheLongestTakeOrAnInterruption() {
  let start = ContinuousClock.now
  func verdict(_ events: [(at: Int, event: RecordingEvent?)]) -> Endpointer.Verdict? {
    var endpointer = Endpointer(.message, startedAt: start)
    for (at, event) in events {
      let now = start + .milliseconds(at)
      if let verdict = event.map({ endpointer.hear($0, at: now) }) ?? endpointer.verdict(at: now) {
        return verdict
      }
    }
    return nil
  }
  #expect(verdict([(6999, nil)]) == nil)
  #expect(verdict([(7000, nil)]) == .silence)
  #expect(verdict([(1000, .partial(" . ")), (7000, nil)]) == .silence)
  #expect(verdict([(1000, .partial("Water")), (2399, nil)]) == nil)
  #expect(verdict([(1000, .partial("Water")), (2400, nil)]) == .finish)
  #expect(verdict([(1000, .partial("Water")), (2000, .level(0.9)), (3399, nil)]) == nil)
  #expect(verdict([(1000, .partial("Water")), (2000, .level(0.9)), (3400, nil)]) == .finish)
  #expect(verdict([(1000, .partial("Water")), (2000, .level(0.2)), (2400, nil)]) == .finish)
  #expect(verdict([(1000, .partial("Water")), (2000, .partial("Water the")), (3399, nil)]) == nil)
  #expect(verdict([(1000, .partial("Water")), (2000, .partial("Water")), (2400, nil)]) == .finish)
  #expect(verdict([(1000, .partial("Water")), (44_500, .level(0.9)), (45_000, nil)]) == .finish)
  #expect(verdict([(1000, .level(0.9)), (45_000, nil)]) == .silence)
  #expect(verdict([(1000, .partial("Water")), (1100, .interrupted)]) == .interrupted)
}

@Test func wordsStayHeardWhenALaterPartialClearsThem() {
  let start = ContinuousClock.now
  var endpointer = Endpointer(.message, startedAt: start)
  #expect(endpointer.hear(.partial("Water"), at: start + .milliseconds(1000)) == nil)
  #expect(endpointer.hear(.partial(""), at: start + .milliseconds(2000)) == nil)
  #expect(endpointer.verdict(at: start + .milliseconds(3399)) == nil)
  #expect(endpointer.verdict(at: start + .milliseconds(3400)) == .finish)
}

@Test func onlyAWholeShortUtteranceIsAnAnswerOrAGoodbye() {
  let table: [(String, VoicePhrase)] = [
    ("Yes.", .yes), ("Yeah, send it!", .yes), ("OK", .yes), ("No.", .no),
    ("Don\u{2019}t send it.", .no), ("That's all.", .end), ("Goodbye", .end),
    ("Yes, but rename it", .other), ("Water the invented ferns", .other), ("", .other),
  ]
  for (heard, phrase) in table {
    #expect(VoicePhrase(heard) == phrase, "\(heard)")
  }
}

@Test func anAnswerIsReadAsSentencesWithCodeAndTablesNamedNotRead() {
  let answer = """
    # Deploy

    The invented deploy **finished**, see [the dashboard](https://example.com/deploys/42).

    - Three services restarted
    - One was skipped

    ```sh
    deploy --all
    ```

    | Service | State |
    | --- | --- |
    | api | ok |

    Logs are at https://example.com/logs/42 for now.
    """
  #expect(
    SpokenReply.speech(from: answer)
      == "Deploy. The invented deploy finished, see the dashboard. Three services restarted. One was skipped. There's a code block in the chat. There's a table in the chat. Logs are at a link for now."
  )
}

@Test func aBareWebAddressInAnyCaseReadsAsALinkAndKeepsItsSentenceEnd() {
  let table = [
    (
      "See HTTPS://example.com/invented-token for the invented report.",
      "See a link for the invented report."
    ),
    ("The invented log is at www.example.com/invented.", "The invented log is at a link."),
    (
      "The invented log is at https://example.com/invented. It has two lines.",
      "The invented log is at a link. It has two lines."
    ),
  ]
  for (answer, speech) in table {
    #expect(SpokenReply.speech(from: answer) == speech, "\(answer)")
  }
}

@Test func aLongAnswerStopsAtASentenceEndAndSaysTheRestIsInTheChat() {
  let sentence = "The invented report lists one more finding."
  #expect(SpokenReply.speech(from: sentence) == sentence)
  let report = SpokenReply.speech(
    from: Array(repeating: sentence, count: 30).joined(separator: " "))
  #expect(report.count <= SpokenReply.limit)
  #expect(report.hasSuffix("finding. The rest is in the chat."))
  let ramble = SpokenReply.speech(from: String(repeating: "and then ", count: 100))
  #expect(ramble.count <= SpokenReply.limit)
  #expect(ramble.hasPrefix("and then") && ramble.hasSuffix("\u{2026} The rest is in the chat."))
}

@Test func theCarRefusesInOrderBeforeTheMicrophoneOpensAndAStaleModelGoesOn() {
  let missing = SpeechModel.missing(download: 609_440_571)
  #expect(
    CarRefusal.preflight(protectedData: false, model: missing, microphone: .denied)
      == .notSent(.locked))
  #expect(
    CarRefusal.preflight(protectedData: true, model: missing, microphone: .denied) == .noVoiceModel)
  #expect(
    CarRefusal.preflight(protectedData: true, model: .unsupported, microphone: .denied)
      == .voiceUnsupported)
  #expect(
    CarRefusal.preflight(protectedData: true, model: .ready, microphone: .denied) == .noMicrophone)
  #expect(
    CarRefusal.preflight(protectedData: true, model: .ready, microphone: .undetermined)
      == .noMicrophone)
  #expect(CarRefusal.preflight(protectedData: true, model: .stale, microphone: .granted) == nil)
  #expect(CarRefusal.preflight(protectedData: true, model: .ready, microphone: .granted) == nil)
}

@Test func noSentenceAsksTheDriverToHandleTheIPhoneAndEveryUnsentReplySaysSo() throws {
  let readBack = CarSentence.readBack(try SiriMessage(parsing: "Invented"), to: "Work")
  let refusals: [CarRefusal] =
    [.microphoneBusy, .noVoiceModel, .voiceUnsupported, .noMicrophone]
    + SiriNotSent.allCases.map(CarRefusal.notSent)
  let replies: [VoiceReply] =
    [
      .answered("An invented answer."), .noReadableReply, .stopped, .stillWorking, .unconfirmed,
      .rejected, .failed, .lostConnection(delivered: true), .lostConnection(delivered: false),
    ] + SiriNotSent.allCases.map(VoiceReply.notSent)
  let sentences =
    refusals.map { CarSentence.refusal($0, name: "Work") }
    + replies.map { CarSentence.reply($0, from: "Work") }
    + SiriMessage.Refusal.allCases.map { CarSentence.refusal($0) }
    + [
      CarSentence.opening("Work"), CarSentence.notSent, CarSentence.notSentGoAhead, readBack,
    ]
  for sentence in sentences {
    for instruction in ["unlock", "pick up", "open", "tap", "download", "allow ", "settings"] {
      #expect(!sentence.localizedCaseInsensitiveContains(instruction), "\(sentence)")
    }
  }
  for reason in SiriNotSent.allCases {
    #expect(CarSentence.reply(.notSent(reason), from: "Work").hasSuffix(" Nothing was sent."))
  }
  #expect(
    CarSentence.reply(.answered(" "), from: "Work")
      == CarSentence.reply(.noReadableReply, from: "Work"))
}

@Test func theCarListensAgainOnlyAfterAnOutcomeForThatMessageAlone() {
  let goesOn: [VoiceReply] = [
    .answered("An invented answer."), .noReadableReply, .stopped, .rejected, .failed,
  ]
  let stops: [VoiceReply] =
    [
      .stillWorking, .unconfirmed, .lostConnection(delivered: true),
      .lostConnection(delivered: false),
    ]
    + SiriNotSent.allCases.map(VoiceReply.notSent)
  for reply in goesOn { #expect(reply.continuesConversation, "\(reply)") }
  for reply in stops { #expect(!reply.continuesConversation, "\(reply)") }
}
