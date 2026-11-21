import Foundation
import Testing

@testable import AgentCore

private let question = "Is the invented deploy done"
private let finished = "The invented deploy finished."

private func eventually(
  _ description: String, within limit: Duration = .seconds(15),
  _ predicate: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(try await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// A connected session on a fixture coordinator that takes carplay inputs unless `carplay` is
/// false.
private func withCarPeer(
  carplay: Bool = true,
  _ body: (CoordinatorSession, FixtureCoordinator, ProfileDirectory) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  await fixture.advertiseInputOrigins(true)
  await fixture.advertiseAcceptedInputOrigins(carplay ? ["siri", "carplay"] : ["siri"])
  let (listener, endpoint) = try await listen(fixture)
  defer { listener.cancel() }
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = CoordinatorSession(
    directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"), pin: fixture.id,
    stamps: StampSource(), transport: loopback(endpoint))
  let outcome: Result<Void, any Error>
  do {
    await session.connect()
    try await eventually("the session connected") { await session.connectionState == .connected }
    try await body(session, fixture, directory)
    outcome = .success(())
  } catch { outcome = .failure(error) }
  await session.disconnect()
  await fixture.stop()
  try outcome.get()
}

private func ask(_ session: CoordinatorSession, limits: VoiceTurnLimits = .car) throws -> (
  inputID: String, reply: Task<VoiceReply, any Error>
) {
  let inputID = UUID().uuidString
  let message = try SiriMessage(parsing: question)
  return (inputID, Task { try await session.converse(message, inputID: inputID, limits: limits) })
}

private func completion(_ inputID: String, answer entryID: String) -> NativeEvent {
  .accepted(.init(inputId: inputID, work: .completed(.init(answerEntryId: entryID))))
}

private func answer(_ entryID: String, _ text: String) -> NativeEvent {
  .answer(.init(entryId: entryID, text: text))
}

private func observes(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .observe = $0 { true } else { false } }.count
}

enum Arrival: CaseIterable, Sendable { case answerFirst, completionFirst }

@Test(.timeLimit(.minutes(1)), arguments: Arrival.allCases)
func theCarReadsOnlyTheAnswerItsInputsCompletionNames(_ arrival: Arrival) async throws {
  try await withCarPeer { session, fixture, _ in
    await fixture.placeEachSubmit()
    let (inputID, reply) = try ask(session)
    try await eventually("Work got the input") { await fixture.count() == 1 }
    try await fixture.emitOnObserver(answer("other-entry", "An invented reply to another input"))
    try await fixture.emitOnObserver(completion("other-input", answer: "other-entry"))
    let own = [completion(inputID, answer: "car-entry"), answer("car-entry", finished)]
    for event in arrival == .answerFirst ? Array(own.reversed()) : own {
      try await fixture.emitOnObserver(event)
    }
    #expect(try await reply.value == .answered(finished))
    #expect(await fixture.count() == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func aCompletionWhoseAnswerNeverArrivesReadsNoOtherAnswer() async throws {
  try await withCarPeer { session, fixture, _ in
    await fixture.placeEachSubmit()
    let limits = VoiceTurnLimits(
      delivery: .seconds(8), answer: .seconds(60), answerText: .milliseconds(300))
    let (inputID, reply) = try ask(session, limits: limits)
    try await eventually("Work got the input") { await fixture.count() == 1 }
    try await fixture.emitOnObserver(completion(inputID, answer: "car-entry"))
    try await fixture.emitOnObserver(answer("other-entry", "An invented reply to another input"))
    #expect(try await reply.value == .noReadableReply)
  }
}

@Test(.timeLimit(.minutes(1)))
func otherInputsAnswersDoNotPushOutTheAnswerThisInputsCompletionNames() async throws {
  try await withCarPeer { session, fixture, _ in
    await fixture.placeEachSubmit()
    let limits = VoiceTurnLimits(
      delivery: .seconds(8), answer: .seconds(60), answerText: .milliseconds(300))
    let (inputID, reply) = try ask(session, limits: limits)
    try await eventually("Work got the input") { await fixture.count() == 1 }
    try await fixture.emitOnObserver(answer("car-entry", finished))
    for index in 0..<63 {
      try await fixture.emitOnObserver(
        answer("other-\(index)", "An invented reply to another input."))
    }
    try await fixture.emitOnObserver(completion(inputID, answer: "car-entry"))
    #expect(try await reply.value == .answered(finished))
  }
}

@Test(
  .timeLimit(.minutes(1)),
  arguments: [InputWorkState.stopped, .blocked(.init(reason: .restartLimit))])
func workThatEndsWithoutAnAnswerIsStopped(_ work: InputWorkState) async throws {
  try await withCarPeer { session, fixture, _ in
    await fixture.placeEachSubmit()
    let (inputID, reply) = try ask(session)
    try await eventually("Work got the input") { await fixture.count() == 1 }
    try await fixture.emitOnObserver(.accepted(.init(inputId: inputID, work: work)))
    #expect(try await reply.value == .stopped)
  }
}

@Test(.timeLimit(.minutes(1)))
func aDeliveredInputWithNoCompletionInTimeIsStillWorking() async throws {
  try await withCarPeer { session, fixture, _ in
    await fixture.placeEachSubmit()
    let limits = VoiceTurnLimits(
      delivery: .seconds(8), answer: .milliseconds(500), answerText: .seconds(3))
    let (_, reply) = try ask(session, limits: limits)
    #expect(try await reply.value == .stillWorking)
    #expect(await fixture.count() == 1)
  }
}

@Test(.timeLimit(.minutes(1)))
func theOutboxHoldsTheCarCopyBeforeWorkHearsItAndNothingWritesItAgain() async throws {
  try await withCarPeer { session, fixture, directory in
    await fixture.holdNextSubmitReply()
    var heard = fixture.observedInputs.makeAsyncIterator()
    let limits = VoiceTurnLimits(
      delivery: .milliseconds(500), answer: .seconds(60), answerText: .seconds(3))
    let (inputID, reply) = try ask(session, limits: limits)
    let written = try #require(await heard.next())
    let saved = try #require(try queuedRequests(directory.outbox).first)
    #expect(saved == written)
    #expect(saved.origin == .carplay && saved.mode == .steer && saved.text == question)
    let again = try await session.converse(try SiriMessage(parsing: question), inputID: inputID)
    #expect(again == .notSent(.busy))
    #expect(try await reply.value == .unconfirmed)
    #expect(try queuedRequests(directory.outbox).map(\.inputId) == [inputID])
    await fixture.releaseSubmitReply()
    try await eventually("Work placed it") { try queuedRequests(directory.outbox).isEmpty }
    #expect(await fixture.count() == 1, "Nothing was written again")
  }
}

@Test(.timeLimit(.minutes(1)))
func aDroppedObserverEndsTheWaitAndTheInputIsNotWrittenAgain() async throws {
  try await withCarPeer { session, fixture, directory in
    await fixture.placeEachSubmit()
    let (_, reply) = try ask(session)
    try await eventually("Work placed it") {
      guard await fixture.count() == 1 else { return false }
      return try queuedRequests(directory.outbox).isEmpty
    }
    await fixture.dropObserver()
    #expect(try await reply.value == .lostConnection(delivered: true))
    try await eventually("the observer came back") { await observes(fixture) == 2 }
    #expect(await fixture.count() == 1, "Nothing was written again")
  }
}

@Test(.timeLimit(.minutes(1)))
func aCoordinatorThatDoesNotTakeCarplayGetsNothing() async throws {
  try await withCarPeer(carplay: false) { session, fixture, directory in
    let reply = try await session.converse(
      try SiriMessage(parsing: question), inputID: UUID().uuidString)
    #expect(reply == .notSent(.notAdvertised))
    #expect(!FileManager.default.fileExists(atPath: directory.outbox.path))
    #expect(await fixture.count() == 0)
  }
}

@Test(.timeLimit(.minutes(1)))
func aTurnCanceledBeforeTheSessionRunsItSavesAndSendsNothing() async throws {
  try await withCarPeer { session, fixture, directory in
    let message = try SiriMessage(parsing: question)
    let turn = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await session.converse(message, inputID: UUID().uuidString)
    }
    await #expect(throws: CancellationError.self) { try await turn.value }
    #expect(!FileManager.default.fileExists(atPath: directory.outbox.path))
    try await Task.sleep(for: .milliseconds(200))
    #expect(await fixture.count() == 0)
  }
}

@Test(.timeLimit(.minutes(1)))
func aRefusalAndAFailedWriteAreTheirOwnReplies() async throws {
  try await withCarPeer { session, fixture, _ in
    let message = try SiriMessage(parsing: question)
    await fixture.rejectSubmits()
    #expect(try await session.converse(message, inputID: UUID().uuidString) == .rejected)
    await fixture.rejectSubmits(false)
    await fixture.failSubmits("Invented: the execution host is offline")
    #expect(try await session.converse(message, inputID: UUID().uuidString) == .failed)
  }
}

@Test func theFoldDecidesByWhatItHeardAndWhen() {
  let start = ContinuousClock.now
  let limits = VoiceTurnLimits(delivery: .seconds(8), answer: .seconds(60), answerText: .seconds(3))
  func decide(_ words: [(InputWord, Duration)]) -> VoiceReply? {
    var fold = VoiceTurnFold(start: start, limits: limits)
    for (word, at) in words {
      if let reply = fold.hear(word, at: start + at) { return reply }
    }
    return nil
  }
  let completed = InputWord.completed(answerEntryID: "car-entry")
  #expect(decide([(.tick, .seconds(7))]) == nil)
  #expect(decide([(.tick, .seconds(8))]) == .unconfirmed)
  #expect(decide([(.unconfirmed, .seconds(1))]) == .unconfirmed)
  #expect(
    decide([(.delivered, .seconds(1)), (.unconfirmed, .seconds(1)), (.tick, .seconds(59))]) == nil)
  #expect(decide([(.delivered, .seconds(1)), (.tick, .seconds(60))]) == .stillWorking)
  #expect(decide([(completed, .seconds(59)), (.tick, .seconds(61))]) == nil)
  #expect(decide([(completed, .seconds(59)), (.tick, .seconds(62))]) == .noReadableReply)
  #expect(
    decide([(completed, .seconds(1)), (.answer(entryID: "car-entry", text: " \n"), .seconds(2))])
      == .noReadableReply)
  #expect(
    decide([(.answer(entryID: "car-entry", text: finished), .seconds(1)), (completed, .seconds(2))])
      == .answered(finished))
  #expect(decide([(.connectionLost, .seconds(1))]) == .lostConnection(delivered: false))
  #expect(
    decide([(.delivered, .seconds(1)), (.connectionLost, .seconds(2))])
      == .lostConnection(delivered: true))
  var fold = VoiceTurnFold(start: start, limits: limits)
  #expect(fold.cancelled == .unconfirmed)
  _ = fold.hear(.delivered, at: start)
  #expect(fold.cancelled == .stillWorking)
}

@Test func theFoldKeepsTheLatestAnswerOfEachOfTheLast64Entries() {
  let start = ContinuousClock.now
  let limits = VoiceTurnLimits(delivery: .seconds(8), answer: .seconds(60), answerText: .seconds(3))
  func reply(afterAnswersFrom others: Int) -> VoiceReply? {
    var fold = VoiceTurnFold(start: start, limits: limits)
    _ = fold.hear(.answer(entryID: "car-entry", text: "An invented first draft."), at: start)
    _ = fold.hear(.answer(entryID: "car-entry", text: finished), at: start)
    for index in 0..<others {
      for text in ["An invented reply to another input.", "The same reply again."] {
        _ = fold.hear(.answer(entryID: "other-\(index)", text: text), at: start)
      }
    }
    return fold.hear(.completed(answerEntryID: "car-entry"), at: start + .seconds(1))
  }
  #expect(reply(afterAnswersFrom: 63) == .answered(finished))
  #expect(reply(afterAnswersFrom: 64) == nil, "The oldest entry's answer was dropped")
}
