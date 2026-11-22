import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// A capture whose event stream the probe closes the way `Capture.halt(interrupted: false)` does:
/// the reporting stream ends, and no `.interrupted` event is delivered.
@MainActor private func phone(
  _ body: (Dictation, SpeechEngine, AsyncStream<RecordingEvent>.Continuation) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let model = ChatModel(
    draftStore: AttachmentStore(directory: root.appending(path: "Drafts")),
    persistence: ComposerDraftStore(url: root.appending(path: "Composer/draft.json")))
  await model.restoreDraft()
  let (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
  let engine = SpeechEngine(
    model: { .ready }, install: { _ in }, prewarm: {}, remove: {}, diskUsage: { 0 },
    onCellular: { false }, permission: { .granted }, requestPermission: { true },
    record: { Recording(events: events, finish: { "Invented words" }, cancel: {}) })
  let dictation = Dictation(engine: engine)
  try await withConnectedCoordinator(model) { _, _ in
    dictation.setForeground(true)
    let deadline = ContinuousClock.now + .seconds(10)
    while dictation.model != .ready || !model.dictationAllowed {
      try #require(ContinuousClock.now < deadline, "Dictation never became ready")
      try await Task.sleep(for: .milliseconds(5))
    }
    dictation.mic(.activated, in: DictationTarget(chat: model))
    while dictation.take == nil {
      try #require(ContinuousClock.now < deadline, "The phone take never opened")
      try await Task.sleep(for: .milliseconds(5))
    }
    try await body(dictation, engine, continuation)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anEndedPhoneCaptureThatWasNotInterruptedStillBlocksTheCar() async throws {
  try await phone { dictation, engine, continuation in
    continuation.yield(.level(0.9))
    let heard = ContinuousClock.now + .seconds(5)
    while dictation.level != 0.9 {
      try #require(ContinuousClock.now < heard, "The phone never read the capture")
      try await Task.sleep(for: .milliseconds(5))
    }
    continuation.finish()
    try await Task.sleep(for: .milliseconds(200))
    #expect(dictation.take != nil, "The dead take is still open")
    #expect(
      engine.microphone.take(.car) == false,
      "The car cannot take a microphone whose capture has already ended")
    #expect(CarSentence.refusal(.microphoneBusy, name: "Work") == "The microphone is busy.")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anInterruptedPhoneCaptureReleasesTheMicrophone() async throws {
  try await phone { dictation, engine, continuation in
    continuation.yield(.interrupted)
    let deadline = ContinuousClock.now + .seconds(5)
    while dictation.take != nil {
      try #require(ContinuousClock.now < deadline, "The interrupted take never ended")
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(engine.microphone.take(.car))
    engine.microphone.release(.car)
  }
}
