import Dispatch
import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private let deploy = "Is the invented deploy done"
private let finished = "The invented deploy finished."

@MainActor private func eventually(
  _ description: String, within limit: Duration = .seconds(15),
  _ predicate: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(try await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Keeps every sentence instead of saying it. A sentence that starts with `holding` lasts until
/// `holding` changes, and one that starts with `interrupting` is cut short.
@MainActor private final class SpokenLines {
  private(set) var lines: [String] = []
  var holding: String?
  var interrupting: String?

  struct Interrupted: Error {}

  var speaker: Speaker { Speaker { [self] in try await say($0) } }

  private func say(_ sentence: String) async throws {
    lines.append(sentence)
    if let interrupting, sentence.hasPrefix(interrupting) { throw Interrupted() }
    while let holding, sentence.hasPrefix(holding) { try await Task.sleep(for: .milliseconds(5)) }
  }
}

@MainActor private final class LockAfter {
  private var checks = 0
  private let limit: Int
  init(checks limit: Int) { self.limit = limit }
  func available() -> Bool {
    checks += 1
    return checks <= limit
  }
}

extension CarTimings {
  fileprivate static let quick = CarTimings(
    message: .init(trailingQuiet: .milliseconds(60), noWords: .seconds(2), longest: .seconds(5)),
    confirmation: .init(
      trailingQuiet: .milliseconds(60), noWords: .seconds(2), longest: .seconds(5)),
    turn: .car, tick: .milliseconds(10))

  /// A message take that only Done, Cancel or an interruption ends.
  fileprivate static var untilDone: CarTimings {
    var timings = quick
    timings.message = .init(
      trailingQuiet: .seconds(60), noWords: .seconds(60), longest: .seconds(60))
    return timings
  }
}

/// Each take hears words, and its final text is the next of `takes`.
private func takes(_ takes: [String]) -> ScriptedSpeech.Script {
  var script = ScriptedSpeech.Script()
  script.takes = takes
  script.partials = ["Invented words"]
  return script
}

@MainActor private struct CarRig {
  let car: CarConversation
  let work: CarCoordinator
  let speech: ScriptedSpeech
  let engine: SpeechEngine
  let spoken: SpokenLines
  let peer: FixtureCoordinator
  let coordinators: Coordinators

  func submitted() async -> [NativeRequestSubmit] {
    await peer.received().compactMap { if case .submit(let input) = $0 { input } else { nil } }
  }

  func ended(saying count: Int) async throws {
    try await eventually("\(count) sentences, then idle") {
      spoken.lines.count == count && car.phase == .idle
    }
  }
}

/// A conversation with Work, which takes carplay inputs unless `carplay` is false. The phone's
/// scene is inactive, as when only the car shows Beep Boop, so only the conversation connects Work.
@MainActor private func withCar(
  _ script: ScriptedSpeech.Script, carplay: Bool = true, timings: CarTimings = .quick,
  protectedDataAvailable: @escaping @MainActor () -> Bool = { true },
  decorateEngine: (SpeechEngine) -> SpeechEngine = { $0 },
  _ body: (CarRig) async throws -> Void
) async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    await workPeer.advertiseInputOrigins(true)
    await workPeer.advertiseAcceptedInputOrigins(carplay ? ["siri", "carplay"] : ["siri"])
    let (work, _) = try await addWorkAndPersonal(coordinators)
    await coordinators.setActive(false)
    let speech = ScriptedSpeech(script)
    let engine = decorateEngine(speech.engine)
    let spoken = SpokenLines()
    let car = CarConversation(
      coordinators: coordinators, engine: engine, speaker: spoken.speaker,
      protectedDataAvailable: protectedDataAvailable, timings: timings)
    let rig = CarRig(
      car: car, work: try #require(car.choices.first { $0.id == work }), speech: speech,
      engine: engine, spoken: spoken, peer: workPeer, coordinators: coordinators)
    let outcome: Result<Void, any Error>
    do {
      try await body(rig)
      outcome = .success(())
    } catch { outcome = .failure(error) }
    car.end()
    try await eventually("the conversation ended") { car.phase == .idle }
    try outcome.get()
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aTurnReadsBackSendsOnceAndSpeaksOnlyItsOwnAnswer() async throws {
  try await withCar(takes([deploy, "Yes.", ""])) { rig in
    await rig.peer.answerEachSubmit(finished)
    #expect(rig.car.choices.map(\.name) == ["Work", "Personal"])
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 3)
    #expect(rig.spoken.lines == ["Talking to Work.", "Send to Work: \(deploy)?", finished])
    let sent = await rig.submitted()
    #expect(sent.map(\.text) == [deploy])
    #expect(sent.first?.origin == .carplay && sent.first?.mode == .steer)
    #expect(rig.speech.recordings == 3, "It listened for another message")
    try await eventually("Work's lease ended") {
      rig.coordinators.chat.snapshots[rig.work.id]?.connection == .disconnected
    }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["Maybe later.", ""])
func noListensAgainAndAnythingButYesEndsWithNothingSent(_ answer: String) async throws {
  let ferns = "Water the invented ferns"
  try await withCar(takes([ferns, "No.", deploy, answer])) { rig in
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 5)
    #expect(
      rig.spoken.lines == [
        "Talking to Work.", "Send to Work: \(ferns)?", "Not sent. Go ahead.",
        "Send to Work: \(deploy)?", "Not sent.",
      ])
    #expect(await rig.submitted().isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["", "That's all."])
func silenceOrAGoodbyeEndsTheConversationWithoutAWord(_ heard: String) async throws {
  try await withCar(takes([heard])) { rig in
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 1)
    #expect(rig.spoken.lines == ["Talking to Work."])
    #expect(rig.speech.recordings == 1)
    #expect(await rig.submitted().isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aTakeWhosePartialClearsStillReadsBackTheWordsItHeard() async throws {
  var script = takes(["Water the invented ferns"])
  script.partials = ["Water", ""]
  var timings = CarTimings.quick
  timings.message = .init(
    trailingQuiet: .milliseconds(1400), noWords: .seconds(2), longest: .seconds(10))
  try await withCar(script, timings: timings) { rig in
    rig.spoken.holding = "Send to"
    rig.car.begin(with: rig.work)
    try await eventually("the take opened") { rig.speech.recordings == 1 }
    try await eventually("the take ended") {
      rig.spoken.lines.count == 2 || rig.car.phase == .idle
    }
    #expect(rig.spoken.lines == ["Talking to Work.", "Send to Work: Water the invented ferns?"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func doneEndsATakeAndSendConfirmsButAButtonForAnotherPhaseDoesNothing() async throws {
  try await withCar(takes([deploy]), timings: .untilDone) { rig in
    await rig.peer.answerEachSubmit(finished)
    rig.spoken.holding = "Send to"
    rig.car.begin(with: rig.work)
    try await eventually("the car listens") {
      rig.car.phase == .listening && rig.speech.recordings == 1
    }
    rig.car.perform(.send, in: .confirming)
    rig.car.perform(.done, in: .confirming)
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.car.phase == .listening)
    rig.car.perform(.done, in: .listening)
    try await eventually("the read-back") { rig.spoken.lines.last == "Send to Work: \(deploy)?" }
    rig.car.perform(.done, in: .listening)
    try await Task.sleep(for: .milliseconds(200))
    #expect(rig.car.phase == .confirming)
    #expect(await rig.submitted().isEmpty)
    rig.car.perform(.send, in: .confirming)
    try await eventually("the answer") { rig.spoken.lines.last == finished }
    #expect(await rig.submitted().map(\.text) == [deploy])
    try await eventually("the car listens again") {
      rig.car.phase == .listening && rig.speech.recordings == 2
    }
    rig.car.perform(.cancel, in: .speaking)
    try await rig.ended(saying: 3)
    #expect(rig.speech.recordings == 2, "Send skipped the confirmation take")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func cancelEndsATakeAtOnceWhileItsWordsAreStillComing() async throws {
  try await withCar(takes([deploy]), timings: .untilDone) { rig in
    rig.speech.hold()
    rig.car.begin(with: rig.work)
    try await eventually("the car listens") {
      rig.car.phase == .listening && rig.speech.recordings == 1
    }
    rig.car.perform(.done, in: .listening)
    try await eventually("the take waits for its words") { rig.speech.heldFinishes == 1 }
    rig.car.perform(.cancel, in: .listening)
    try await eventually("the conversation ended", within: .seconds(5)) {
      rig.car.phase == .idle
    }
    #expect(rig.speech.cancellations == 1, "The take's words were abandoned")
    try await eventually("Work's lease ended") {
      rig.coordinators.chat.snapshots[rig.work.id]?.connection == .disconnected
    }
    let phone = Dictation(engine: rig.engine)
    phone.setForeground(true)
    try await eventually("the phone's model is read") { phone.model == .ready }
    let target = DictationTarget(chat: rig.coordinators.chat)
    phone.mic(.activated, in: target)
    try await eventually("the phone listens") { rig.speech.recordings == 2 }
    rig.speech.release()
    phone.mic(.activated, in: target)
    try await eventually("the phone's words land") { phone.take == nil }
    #expect(rig.spoken.lines == ["Talking to Work."])
    #expect(await rig.submitted().isEmpty)
  }
}

enum CarStart: String, CaseIterable, Sendable {
  case locked, noVoiceModel, unsupported, denied, undetermined, notAdvertised, microphoneBusy
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: CarStart.allCases)
func eachRefusalIsSaidBeforeAnyTakeAndChangesNothing(_ start: CarStart) async throws {
  var script = takes([deploy, "Yes.", ""])
  switch start {
  case .noVoiceModel: script.model = .missing
  case .unsupported: script.model = .unsupported
  case .denied: script.microphone = .denied
  case .undetermined: script.microphone = .undetermined
  case .locked, .notAdvertised, .microphoneBusy: break
  }
  let said =
    switch start {
    case .locked: "Beep Boop can't send messages while iPhone is locked."
    case .noVoiceModel: "Voice input isn't set up in Beep Boop yet."
    case .unsupported: "Voice input doesn't work on this iPhone."
    case .denied, .undetermined: "Beep Boop isn't allowed to use the microphone."
    case .notAdvertised: "Work needs an update before it can talk in the car."
    case .microphoneBusy: "The microphone is busy."
    }
  let unlocked: @MainActor () -> Bool = { start != .locked }
  try await withCar(script, carplay: start != .notAdvertised, protectedDataAvailable: unlocked) {
    rig in
    let phone = Dictation(engine: rig.engine)
    let target = DictationTarget(chat: rig.coordinators.chat)
    if start == .microphoneBusy {
      phone.setForeground(true)
      try await eventually("the phone's model is read") { phone.model == .ready }
      phone.mic(.activated, in: target)
      try await eventually("the phone listens") { rig.speech.recordings == 1 }
    }
    let recordings = rig.speech.recordings
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 1)
    #expect(rig.spoken.lines == [said])
    #expect(rig.speech.recordings == recordings)
    #expect(rig.speech.installs == 0)
    #expect(rig.engine.permission() == script.microphone, "The car never asks for the microphone")
    #expect(await rig.submitted().isEmpty)
    if start == .microphoneBusy {
      phone.mic(.activated, in: target)
      try await eventually("the phone's words land") { phone.take == nil }
    }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func thePhoneCannotDictateWhileTheCarListensAndCanOnceItEnds() async throws {
  try await withCar(takes([deploy]), timings: .untilDone) { rig in
    let phone = Dictation(engine: rig.engine)
    phone.setForeground(true)
    try await eventually("the phone's model is read") { phone.model == .ready }
    let target = DictationTarget(chat: rig.coordinators.chat)
    rig.car.begin(with: rig.work)
    try await eventually("the car listens") {
      rig.car.phase == .listening && rig.speech.recordings == 1
    }
    phone.mic(.activated, in: target)
    #expect(phone.take == nil)
    #expect(phone.notice == .microphoneUnavailable)
    rig.car.end()
    try await rig.ended(saying: 1)
    phone.mic(.activated, in: target)
    try await eventually("the phone listens") { rig.speech.recordings == 2 }
    phone.mic(.activated, in: target)
    try await eventually("the phone's words land") { phone.take == nil }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPhoneThatLocksBeforeTheSendSaysNothingWasSent() async throws {
  let lock = LockAfter(checks: 3)
  try await withCar(takes([deploy, "Yes."]), protectedDataAvailable: lock.available) { rig in
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 3)
    #expect(
      rig.spoken.lines.last
        == "Beep Boop can't send messages while iPhone is locked. Nothing was sent.")
    #expect(await rig.submitted().isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aLostConnectionIsSaidOnceAndEndsTheConversation() async throws {
  try await withCar(takes([deploy, "Yes."])) { rig in
    await rig.peer.placeEachSubmit()
    rig.car.begin(with: rig.work)
    let outbox = try #require(rig.coordinators.chat.lanes.first { $0.id == rig.work.id }?.session)
      .outboxURL
    try await eventually("Work placed the message") {
      guard await rig.peer.count() == 1 else { return false }
      return try queuedItems(outbox).isEmpty
    }
    await rig.peer.dropObserver()
    try await rig.ended(saying: 3)
    #expect(rig.spoken.lines.last == "Lost the connection to Work. It has your message.")
    #expect(await rig.peer.count() == 1)
  }
}

enum Interruption: CaseIterable, Sendable { case whileSpeaking, whileListening }

@MainActor @Test(.timeLimit(.minutes(1)), arguments: Interruption.allCases)
func anAudioInterruptionEndsTheConversationWithoutAWord(_ interruption: Interruption)
  async throws
{
  try await withCar(takes([deploy, "Yes."]), timings: .untilDone) { rig in
    switch interruption {
    case .whileSpeaking:
      rig.spoken.interrupting = "Talking to"
      rig.car.begin(with: rig.work)
      try await rig.ended(saying: 1)
      #expect(rig.speech.recordings == 0)
    case .whileListening:
      rig.car.begin(with: rig.work)
      try await eventually("the car listens") {
        rig.car.phase == .listening && rig.speech.recordings == 1
      }
      rig.speech.interrupt()
      try await rig.ended(saying: 1)
    }
    #expect(await rig.submitted().isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func adversaryTheDriversReplyDoesNotAskThemToTouchThePhone() async throws {
  let instruction = "Pick up your iPhone and tap the invented Ferns button."
  try await withCar(takes([deploy, "Yes.", ""])) { rig in
    await rig.peer.answerEachSubmit(instruction)
    rig.car.begin(with: rig.work)
    try await rig.ended(saying: 3)
    let said = try #require(rig.spoken.lines.last)
    print("LAST_SPOKEN=\(said)")
    #expect(!said.contains("Pick up your iPhone"))
  }
}

private final class HeldSessionActor: Sendable {
  private let holding = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func occupy(_ session: isolated CoordinatorSession) {
    holding.signal()
    release.wait()
  }

  func isHolding() -> Bool { holding.wait(timeout: .now()) == .success }
  func open() { release.signal() }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func adversaryCancelBeforeTheSessionCanAdmitDoesNotSend() async throws {
  try await withCar(takes([deploy])) { rig in
    // The phone app being open holds Work's observer even if the car leaves.
    await rig.coordinators.setActive(true)
    await rig.peer.holdNextSubmitReply()
    rig.spoken.holding = "Send to"
    let run = rig.car.begin(with: rig.work)
    try await eventually("the car reads back") { rig.spoken.lines.count == 2 }
    let session = try #require(
      rig.coordinators.chat.lanes.first { $0.id == rig.work.id }?.session)
    let gate = HeldSessionActor()
    defer { gate.open() }
    let holding = Task.detached { await gate.occupy(session) }
    try await eventually("Work's actor is busy") { gate.isHolding() }

    rig.car.perform(.send, in: .confirming)
    try await eventually("the confirmed send is about to reach Work's actor") {
      rig.car.phase == .working
    }
    rig.car.perform(.cancel, in: .working)
    let outbox = session.outboxURL
    #expect(!FileManager.default.fileExists(atPath: outbox.path), "Cancel preceded admission")
    gate.open()
    await holding.value
    await run.value

    let saved =
      FileManager.default.fileExists(atPath: outbox.path) ? try queuedRequests(outbox) : []
    if !saved.isEmpty {
      try await eventually("the canceled send reaches the coordinator") {
        await rig.peer.count() == 1
      }
    }
    print("OUTBOX=\(saved.map(\.text)); SUBMITS=\(await rig.submitted().map(\.text))")
    #expect(saved.isEmpty)
    #expect(await rig.submitted().isEmpty)
    await rig.peer.releaseSubmitReply()
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func adversarySendButtonWorksWhileConfirmationTranscriptionFinishes() async throws {
  try await withCar(takes([deploy, "Perhaps.", ""])) { rig in
    await rig.peer.answerEachSubmit(finished)
    rig.spoken.holding = "Send to"
    rig.car.begin(with: rig.work)
    try await eventually("the read-back began") { rig.spoken.lines.count == 2 }
    rig.speech.hold()
    defer { rig.speech.release() }
    rig.spoken.holding = nil
    try await eventually("the confirmation take is finalizing") {
      rig.car.phase == .confirming && rig.speech.recordings == 2 && rig.speech.heldFinishes == 1
    }

    rig.car.perform(.send, in: .confirming)
    rig.speech.release()
    try await rig.ended(saying: 3)
    let sent = await rig.submitted().map(\.text)
    print("SENT_AFTER_SEND_PRESS=\(sent); LAST_SPOKEN=\(rig.spoken.lines.last ?? "")")
    #expect(sent == [deploy])
    #expect(rig.spoken.lines.last == finished)
  }
}

@MainActor private final class HeldConfirmationFinish {
  private var finishes = 0
  private var waiting: CheckedContinuation<Void, Never>?
  var isWaiting: Bool { waiting != nil }

  func wrap(_ engine: SpeechEngine) -> SpeechEngine {
    SpeechEngine(
      model: engine.model, install: engine.install, prewarm: engine.prewarm, remove: engine.remove,
      diskUsage: engine.diskUsage, onCellular: engine.onCellular, permission: engine.permission,
      requestPermission: engine.requestPermission,
      record: {
        let recording = try await engine.record()
        return Recording(
          events: recording.events, finish: { try await self.finish(recording) },
          cancel: recording.cancel)
      })
  }

  func release() {
    let continuation = waiting
    waiting = nil
    continuation?.resume()
  }

  private func finish(_ recording: Recording) async throws -> String {
    finishes += 1
    // Parakeet's real finish still has the microphone open for a short tail of audio.
    if finishes == 2 { await withCheckedContinuation { waiting = $0 } }
    return try await recording.finish()
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func adversaryInterruptionWhileFinalizingConfirmationDoesNotSend() async throws {
  let tail = HeldConfirmationFinish()
  try await withCar(takes([deploy, "Yes.", ""]), decorateEngine: tail.wrap) { rig in
    await rig.peer.answerEachSubmit(finished)
    let run = rig.car.begin(with: rig.work)
    defer { tail.release() }
    try await eventually("confirmation finish began while the mic is still open") { tail.isWaiting }
    #expect(rig.car.phase == .confirming)
    rig.speech.interrupt()
    let deadline = ContinuousClock.now + .milliseconds(300)
    while rig.car.phase == .confirming && ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    tail.release()
    await run.value

    let sent = await rig.submitted().map(\.text)
    print("SENT_AFTER_AUDIO_INTERRUPTION=\(sent); LAST_SPOKEN=\(rig.spoken.lines.last ?? "")")
    #expect(sent.isEmpty)
    #expect(rig.spoken.lines.count == 2)
  }
}
