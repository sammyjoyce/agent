import Foundation
import Testing
import UniformTypeIdentifiers

@testable import AgentCore
@testable import AgentUI

/// Holds each Send where `ChatModel` hands it to the outboxes, until the test gives its outcome.
private actor HeldAdmission {
  nonisolated let entered: AsyncStream<Void>
  private let enteredContinuation: AsyncStream<Void>.Continuation
  private var continuation: CheckedContinuation<Bool, Never>?
  init() {
    (entered, enteredContinuation) = AsyncStream<Void>.makeStream()
  }
  func admit() async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      enteredContinuation.yield(())
    }
  }
  func finish(_ admitted: Bool) {
    continuation?.resume(returning: admitted)
    continuation = nil
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sendBlockerNamesWhySendIsDisabledAndTheMicWaitsForABusyDraft() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let held = HeldAdmission()
  let url = root.appending(path: "Composer/draft.json")
  let inbox = SharedDraftInbox(containerURL: root)
  let model = ChatModel(
    draftStore: AttachmentStore(directory: root.appending(path: "Drafts")),
    persistence: ComposerDraftStore(url: url), sharedInbox: inbox,
    admit: { _ in await held.admit() })
  #expect(model.sendBlocker == .draftNotRestored && !model.canSend && !model.dictationAllowed)
  await model.restoreDraft()
  try await withConnectedCoordinator(model) { _, _ in
    guard case .addressing(.empty) = model.sendBlocker else {
      Issue.record("An empty draft has no one to send to: \(String(describing: model.sendBlocker))")
      return
    }
    #expect(!model.canSend && model.dictationAllowed)
    model.draft = "Invented note"
    #expect(model.sendBlocker == nil && model.canSend)

    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all)
    { done in
      let progress = Progress(totalUnitCount: 1)
      progress.cancellationHandler = { done(nil, false, CancellationError()) }
      entered.continuation.yield(())
      return progress
    }
    let attaching = try #require(model.attach(providers: [provider]))
    for await _ in entered.stream { break }
    #expect(model.sendBlocker == .preparingAttachments && !model.canSend)
    #expect(model.dictationAllowed, "Words and files land independently")
    attaching.cancel()
    await attaching.value

    let sending = try #require(model.startSend())
    for await _ in held.entered { break }
    #expect(model.sendBlocker == .admitting && !model.canSend && !model.dictationAllowed)
    await held.finish(false)
    await sending.value
    #expect(model.draft == "Invented note" && model.sendBlocker == nil)

    #expect(await model.saveDraft())
    let composer = url.deletingLastPathComponent()
    let preserved = root.appending(path: "PreservedComposer")
    try FileManager.default.moveItem(at: composer, to: preserved)
    try Data("Not a directory".utf8).write(to: composer)
    try await inbox.enqueue(images: [], note: "Invented shared note")
    await model.receiveSharedDrafts()
    #expect(model.sendBlocker == .sharedImport && !model.canSend && !model.dictationAllowed)
    try FileManager.default.removeItem(at: composer)
    try FileManager.default.moveItem(at: preserved, to: composer)
    await model.receiveSharedDrafts()
    #expect(model.sendBlocker == nil && model.dictationAllowed)
  }
}

@MainActor @Test func theDraftMarkChangesWithTheDraftAndWithTheScopeShown() throws {
  let work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let personal = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
  let model = ChatModel()
  model.profiles = [work, personal]
  let mark = model.draftMark
  #expect(model.draftMark == mark, "Reading changes nothing")
  model.show(.one(work.id))
  #expect(model.draftMark != mark, "Another scope addresses the same draft elsewhere")
  let shown = model.draftMark
  model.draft = "Invented note"
  #expect(model.draftMark != shown)
}

@MainActor private func until(
  _ description: String, within limit: Duration = .seconds(10), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// A connected one-coordinator composer with dictation over a scripted engine. Taps stay taps
/// unless `holdDelay` is short.
@MainActor private func withDictation(
  _ script: ScriptedSpeech.Script = .init(), holdDelay: Duration = .seconds(30),
  admit: ChatModel.Admit? = nil,
  _ body: (Dictation, ScriptedSpeech, ChatModel, FixtureCoordinator, ProfileDirectory)
    async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = AttachmentStore(directory: root.appending(path: "Drafts"))
  let chat = admit.map { ChatModel(draftStore: store, admit: $0) } ?? ChatModel(draftStore: store)
  let speech = ScriptedSpeech(script)
  let dictation = Dictation(engine: speech.engine, holdDelay: holdDelay)
  dictation.setForeground(true)
  try await until("the model is read") { dictation.model != .checking }
  try await withConnectedCoordinator(chat) { fixture, directory in
    try await body(dictation, speech, chat, fixture, directory)
  }
}

private func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }

@MainActor private func tap(_ dictation: Dictation, _ target: DictationTarget) {
  dictation.mic(.down, in: target)
  dictation.mic(.up(onMic: true), in: target)
}

@MainActor private func listening(_ dictation: Dictation, _ gesture: Dictation.Gesture)
  async throws
{
  try await until("listening, \(gesture)") { dictation.take?.stage == .listening(gesture) }
}

@MainActor private func hold(_ dictation: Dictation, _ target: DictationTarget) async throws {
  dictation.mic(.down, in: target)
  try await listening(dictation, .holding)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aTappedTakeKeepsItsWordsInTheComposerAndSendsNothing() async throws {
  try await withDictation { dictation, speech, chat, fixture, directory in
    let target = DictationTarget(chat: chat)
    chat.draft = "Before"
    tap(dictation, target)
    try await listening(dictation, .toggled)
    tap(dictation, target)
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Before Invented dictated words")
    #expect(speech.recordings == 1 && dictation.notice == nil)
    #expect(!chat.admitting && (try? queuedRequests(directory.outbox)) == nil)
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldTakeReleasedOnTheMicSendsItsWordsExactlyOnce() async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, _, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("the submit") { await submitted(fixture) == ["Invented dictated words"] }
    #expect(chat.draft.isEmpty && dictation.take == nil && dictation.notice == nil)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await submitted(fixture) == ["Invented dictated words"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["slid off", "cancelled by the system"])
func aHeldTakeThatDoesNotEndOnTheMicKeepsItsWords(_ ending: String) async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, _, chat, fixture, directory in
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    dictation.mic(ending == "slid off" ? .up(onMic: false) : .cancelled, in: target)
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Invented dictated words")
    #expect((try? queuedRequests(directory.outbox)) == nil)
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func voiceOverActivationStartsAndStopsATakeLikeATap() async throws {
  try await withDictation { dictation, _, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    dictation.mic(.activated, in: target)
    try await listening(dictation, .toggled)
    dictation.mic(.activated, in: target)
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Invented dictated words")
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldTakeWhileFilesAreStillBeingAddedKeepsItsWordsAndSaysWhy() async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, _, chat, fixture, _ in
    let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let provider = NSItemProvider()
    provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all)
    { done in
      let progress = Progress(totalUnitCount: 1)
      progress.cancellationHandler = { done(nil, false, CancellationError()) }
      entered.continuation.yield(())
      return progress
    }
    let attaching = try #require(chat.attach(providers: [provider]))
    for await _ in entered.stream { break }
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Invented dictated words")
    #expect(dictation.notice == .notSent(.blocked(.preparingAttachments)))
    #expect(dictation.notice?.text(chat) == "Not sent. Files are still being added.")
    attaching.cancel()
    await attaching.value
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func wordsLandAfterAnotherEditButAHeldTakeThenDoesNotSend() async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, speech, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    speech.hold()
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("transcribing") { dictation.take?.stage == .transcribing(.send) }
    chat.draft = "Typed in another window"
    speech.release()
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Typed in another window Invented dictated words")
    #expect(dictation.notice == .notSent(.draftChanged))
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["while listening", "while transcribing"])
func leavingTheAppKeepsTheWordsAndNeverSends(_ moment: String) async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, speech, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    speech.hold()
    try await hold(dictation, target)
    if moment == "while transcribing" {
      dictation.mic(.up(onMic: true), in: target)
      try await until("transcribing") { dictation.take?.stage == .transcribing(.send) }
    }
    dictation.setForeground(false)
    #expect(dictation.take?.stage == .transcribing(.keep))
    speech.release()
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Invented dictated words" && dictation.notice == nil)
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anEmptyTranscriptNeverSendsTheDraftAlreadyThere() async throws {
  var script = ScriptedSpeech.Script()
  script.takes = ["  \n"]
  try await withDictation(script, holdDelay: .milliseconds(10)) {
    dictation, _, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    chat.draft = "An older invented draft"
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("the take ends") { dictation.take == nil }
    #expect(chat.draft == "An older invented draft" && dictation.notice == .nothingHeard)
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func theMicRefusesToOpenWhileASendIsAdmitting() async throws {
  let held = HeldAdmission()
  let admit: ChatModel.Admit = { _ in await held.admit() }
  try await withDictation(admit: admit) { dictation, speech, chat, _, _ in
    chat.draft = "Invented note"
    let sending = try #require(chat.startSend())
    for await _ in held.entered { break }
    tap(dictation, DictationTarget(chat: chat))
    #expect(dictation.take == nil && speech.recordings == 0)
    await held.finish(false)
    await sending.value
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aPressThatAsksForTheMicrophoneStartsNothing() async throws {
  var script = ScriptedSpeech.Script()
  script.microphone = .undetermined
  try await withDictation(script) { dictation, speech, chat, _, _ in
    let target = DictationTarget(chat: chat)
    tap(dictation, target)
    #expect(dictation.take == nil)
    try await until("the answer") { dictation.notice == .microphoneAllowed }
    #expect(speech.recordings == 0)
    tap(dictation, target)
    try await listening(dictation, .toggled)
    #expect(dictation.notice == nil)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aDeniedMicrophoneOffersSettingsAndStartsNothing() async throws {
  var script = ScriptedSpeech.Script()
  script.microphone = .denied
  try await withDictation(script) { dictation, speech, chat, _, _ in
    tap(dictation, DictationTarget(chat: chat))
    #expect(dictation.take == nil && speech.recordings == 0)
    #expect(dictation.notice == .microphoneDenied)
    #expect(dictation.notice?.text(chat) == "Dictation needs the microphone. Allow it in Settings.")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func theFirstTapOffersTheDownloadWhichCompilesAndNeverOpensTheMic() async throws {
  var script = ScriptedSpeech.Script()
  script.model = .missing
  script.microphone = .undetermined
  script.stepMilliseconds = 100
  try await withDictation(script, holdDelay: .milliseconds(10)) {
    dictation, speech, chat, _, _ in
    let target = DictationTarget(chat: chat)
    #expect(dictation.model == .missing(download: 614_082_275))
    dictation.mic(.down, in: target)
    try await Task.sleep(for: .milliseconds(50))
    #expect(dictation.take == nil && dictation.offering == nil, "Only a release offers it")
    dictation.mic(.up(onMic: true), in: target)
    try await until("the offer") { dictation.offering != nil }
    #expect(dictation.offering == Dictation.Offer(bytes: 614_082_275, cellular: false))
    #expect(dictation.offering?.question == "Download the voice model (\(size(614_082_275)))?")
    dictation.download()
    #expect(dictation.offering == nil && dictation.model == .downloading(0, of: 614_082_275))
    var seen: [Dictation.ModelPhase] = []
    try await until("ready") {
      if seen.last != dictation.model { seen.append(dictation.model) }
      return dictation.notice == .ready
    }
    #expect(seen.contains(.downloading(0.5, of: 614_082_275)))
    #expect(dictation.model == .ready && dictation.diskUsage == 614_082_275)
    #expect(speech.engine.permission() == .granted, "Asked while downloading")
    #expect(speech.installs == 1 && speech.recordings == 0 && dictation.take == nil)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aCancelledDownloadOffersItAgain() async throws {
  var script = ScriptedSpeech.Script()
  script.model = .missing
  script.stepMilliseconds = 500
  try await withDictation(script) { dictation, speech, chat, _, _ in
    tap(dictation, DictationTarget(chat: chat))
    try await until("the offer") { dictation.offering != nil }
    dictation.download()
    dictation.cancelDownload()
    try await until("missing again") { dictation.model == .missing(download: 614_082_275) }
    #expect(dictation.notice == nil && speech.recordings == 0)
    tap(dictation, DictationTarget(chat: chat))
    try await until("the offer again") { dictation.offering != nil }
    #expect(dictation.offering == Dictation.Offer(bytes: 614_082_275, cellular: false))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func onCellularTheOfferSaysSoAndNotNowDownloadsNothing() async throws {
  var script = ScriptedSpeech.Script()
  script.model = .missing
  script.cellular = true
  try await withDictation(script) { dictation, speech, chat, _, _ in
    tap(dictation, DictationTarget(chat: chat))
    try await until("the offer") { dictation.offering != nil }
    #expect(dictation.offering == Dictation.Offer(bytes: 614_082_275, cellular: true))
    #expect(
      dictation.offering?.question
        == "This iPhone is on cellular. Download the voice model (\(size(614_082_275)))?")
    dictation.offering = nil
    try await Task.sleep(for: .milliseconds(200))
    #expect(speech.installs == 0 && dictation.model == .missing(download: 614_082_275))
    #expect(dictation.offering == nil, "Not now stays declined until the next tap")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aModelAnUpdateLeftStaleCompilesInTheBackgroundOnForeground() async throws {
  var script = ScriptedSpeech.Script()
  script.model = .stale
  let speech = ScriptedSpeech(script)
  let dictation = Dictation(engine: speech.engine)
  dictation.setForeground(true)
  try await until("ready") { dictation.model == .ready }
  #expect(await speech.engine.model() == .ready, "The prewarm compiled it")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anInterruptedHeldTakeKeepsWhatWasHeard() async throws {
  try await withDictation(holdDelay: .milliseconds(10)) { dictation, speech, chat, fixture, _ in
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    speech.interrupt()
    try await until("the words land") { dictation.take == nil }
    dictation.mic(.up(onMic: true), in: target)
    #expect(chat.draft == "Invented dictated words" && dictation.notice == .interrupted)
    #expect(await submitted(fixture).isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func dictatedTagsArePromotedBeforeAHeldTakeSends() async throws {
  var script = ScriptedSpeech.Script()
  script.takes = ["@Work @Personal invented note"]
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    _ = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let dictation = Dictation(engine: ScriptedSpeech(script).engine, holdDelay: .milliseconds(10))
    dictation.setForeground(true)
    try await until("ready") { dictation.model == .ready }
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("Work's submit") { await submitted(workFixture).count == 1 }
    #expect(await submitted(workFixture) == ["@Personal invented note"])
    #expect(chat.destination.chip == nil && chat.draft.isEmpty)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await submitted(personalFixture).isEmpty, "The chip picked Work alone")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func showingAnotherScopeDuringAHeldTakeKeepsItsWords() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let speech = ScriptedSpeech()
    let dictation = Dictation(engine: speech.engine, holdDelay: .milliseconds(10))
    dictation.setForeground(true)
    try await until("ready") { dictation.model == .ready }
    let target = DictationTarget(chat: chat)
    speech.hold()
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("transcribing") { dictation.take?.stage == .transcribing(.send) }
    chat.show(.one(work))
    speech.release()
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "Invented dictated words" && dictation.notice == .notSent(.draftChanged))
    try await Task.sleep(for: .milliseconds(200))
    let toWork = await submitted(workFixture)
    let toPersonal = await submitted(personalFixture)
    #expect(toWork.isEmpty && toPersonal.isEmpty)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aDictatedTagNamingNoCoordinatorKeepsTheWordsAndSaysWhy() async throws {
  var script = ScriptedSpeech.Script()
  script.takes = ["@Nobody invented note"]
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    _ = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let dictation = Dictation(engine: ScriptedSpeech(script).engine, holdDelay: .milliseconds(10))
    dictation.setForeground(true)
    try await until("ready") { dictation.model == .ready }
    let target = DictationTarget(chat: chat)
    try await hold(dictation, target)
    dictation.mic(.up(onMic: true), in: target)
    try await until("the words land") { dictation.take == nil }
    #expect(chat.draft == "@Nobody invented note")
    guard case .notSent(.blocked(.addressing)) = dictation.notice else {
      Issue.record("Expected an addressing notice, got \(String(describing: dictation.notice))")
      return
    }
    #expect(dictation.notice?.text(chat) == "Not sent. \(chat.recipientLine).")
    let toWork = await submitted(workFixture)
    let toPersonal = await submitted(personalFixture)
    #expect(toWork.isEmpty && toPersonal.isEmpty)
  }
}

@Test func dictatedWordsGetASpaceOnlyWhereTheyWouldTouchAWord() {
  #expect(DictationText.fitted("Hello there.", between: nil, and: nil) == "Hello there.")
  #expect(DictationText.fitted("Hello", between: "d", and: "w") == " Hello ")
  #expect(DictationText.fitted("Hello", between: " ", and: "\n") == "Hello")
  #expect(DictationText.fitted(", and then", between: "d", and: nil) == ", and then")
  #expect(DictationText.fitted("hello", between: "(", and: ")") == "hello")
  #expect(DictationText.appended("Words.", to: "") == "Words.")
  #expect(DictationText.appended("Words.", to: "Draft") == "Draft Words.")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func completeFilesWithoutAReceiptCompileWithoutAskingToDownload() async throws {
  var script = ScriptedSpeech.Script()
  script.model = .missing
  script.download = 0
  try await withDictation(script) { dictation, speech, chat, _, _ in
    tap(dictation, DictationTarget(chat: chat))
    #expect(dictation.offering == nil)
    try await until("ready") { dictation.model == .ready }
    #expect(speech.installs == 1 && speech.recordings == 0)
  }
}
