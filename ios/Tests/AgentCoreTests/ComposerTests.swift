import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// Holds a Send where `ChatModel` hands it to the outboxes, until the test gives its outcome.
private actor AdmissionGate {
  nonisolated let entered: AsyncStream<Void>
  private let enteredContinuation: AsyncStream<Void>.Continuation
  private var continuation: CheckedContinuation<Bool, Never>?
  init() {
    let pair = AsyncStream<Void>.makeStream()
    entered = pair.stream
    enteredContinuation = pair.continuation
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

/// A feed with one saved coordinator, connected to a loopback fixture, as the app builds it.
@MainActor private func withConnectedModel(
  _ body: (ChatModel, FixtureCoordinator, ProfileDirectory) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let profile = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
  let model = ChatModel(draftStore: AttachmentStore(directory: root.appending(path: "Drafts")))
  model.profiles = [profile]
  model.attach(
    Lane(
      id: profile.id,
      session: CoordinatorSession(
        directory: directory, address: profile.address, pin: fixture.id, stamps: StampSource(),
        transport: loopback(port))))
  await model.setActive(true)
  while model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
  do {
    try await body(model, fixture, directory)
  } catch {
    await model.detach(profile.id)
    await fixture.stop()
    throw error
  }
  await model.detach(profile.id)
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func buttonSubmissionSnapshotsAndClearsBeforeReturning() async throws {
  try await withCoordinator { session, fixture, outbox in
    await fixture.loseInputAcknowledgements()
    let model = await MainActor.run { ChatModel() }
    await model.attach(lane(session))
    await model.setActive(true)
    try await waitForComposerState { model.connection == .connected }
    let text = "Copy this note before clearing the visible editor."
    let started = await MainActor.run {
      model.draft = text
      let started = model.startSend()
      #expect(model.draft.isEmpty)
      #expect(model.admitting)
      model.draft = text
      return started
    }
    let sending = try #require(started)
    await sending.value
    #expect(await model.draft == text, "New identical typing belongs to the next message")
    #expect(try queuedRequests(outbox).map(\.text) == [text])
    await model.detach(session.profile)
  }
}

@MainActor
@Test(arguments: [
  ("", "/feedback "),
  ("Keep the note.\nSecond line.", "/feedback Keep the note.\nSecond line."),
  ("/help Keep the note.", "/feedback Keep the note."),
  ("/feedback Keep the note.", "/feedback Keep the note."),
  (" \n/help\tKeep the note.", "/feedback\tKeep the note."),
  ("/help", "/feedback "),
  ("/helpful is a path", "/feedback /helpful is a path"),
  ("/tmp/example.txt", "/feedback /tmp/example.txt"),
])
func commandInsertionPreservesTheDurableNoteAndReplacesOnlyKnownCommands(
  draft: String, expected: String
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = AttachmentStore(directory: root.appending(path: "Files"))
  let url = root.appending(path: "draft.json")
  let model = ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
  await model.restoreDraft()
  let feedback = SlashCommand(description: "Report a problem", usage: "/feedback <note>")
  model.commands = [feedback, .init(description: "Show commands", usage: "/help")]
  model.mode = .followUp
  await model.attach(data: Data("Kept attachment".utf8), name: "Note.txt", mediaType: "text/plain")
  let attachment = try #require(model.attachments.first)
  model.draft = draft
  model.insertCommand(feedback)
  #expect(model.draft == expected)
  let saved = await model.saveDraft()
  try #require(saved, "Draft save failed: \(model.draftError ?? "unknown error")")
  let restored = try await ComposerDraftStore(url: url).load(from: files)
  #expect(restored.draft.text == expected)
  #expect(restored.draft.mode == .followUp)
  #expect(restored.draft.attachments == [attachment])
}

@MainActor private func waitForComposerState(_ predicate: @MainActor () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(8)
  while !predicate() {
    guard ContinuousClock.now < deadline else { throw ConnectionError.timedOut }
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func failedDraftRestorationKeepsTheOriginalDurableOutbox() async throws {
  try await withCoordinator { session, fixture, outbox in
    let directory = outbox.deletingLastPathComponent()
    let files = AttachmentStore(directory: directory.appending(path: "Drafts"))
    let draftURL = directory.appending(path: "composer.json")
    let model = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: draftURL))
    }
    await model.restoreDraft()
    await fixture.refuseUploads()
    await model.attach(lane(session))
    await model.setActive(true)
    try await waitForComposerState { model.connection == .connected }
    let file = try await files.stage(
      data: Data("Keep the original file".utf8), name: "Note.txt", mediaType: "text/plain")
    #expect(await session.submit("Restore the original message", files: [file]))
    try await waitForComposerState { model.rows.last?.row.delivery == .rejected }
    let inputID = try #require(await MainActor.run { model.rows.last?.row.inputID })
    let original = try Data(contentsOf: outbox)

    // A real second owner makes the replacement save fail without a fake store.
    let otherOwner = ComposerDraftStore(url: draftURL)
    let adopted = try await otherOwner.load(from: files)
    try await otherOwner.save(
      ComposerDraft(text: "Another unsent note"), revision: adopted.revision + 1)
    await model.restore(inputID)
    #expect(try Data(contentsOf: outbox) == original)
    #expect(await model.draftError != nil)
    let reopened = try await ComposerDraftStore(url: draftURL).load(from: files)
    #expect(reopened.draft.text == "Another unsent note")
    await model.detach(session.profile)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sendClearsComposerBeforeAdmissionAndPreservesNewTyping() async throws {
  try await withConnectedModel { model, _, directory in
    model.draft = "Original draft"
    let sending = Task { await model.send() }
    while !model.admitting { await Task.yield() }
    #expect(model.draft.isEmpty, "Send must immediately clear the composer during admission")
    model.draft = "New typing while admission is pending"
    await model.send()
    await sending.value
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Original draft"])
    #expect(model.draft == "New typing while admission is pending")
    #expect(!model.admitting)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func durableAdmissionDoesNotEraseANewerDraftWithIdenticalText(afterClearing: Bool) async throws {
  try await withConnectedModel { model, _, directory in
    model.draft = "The same text in a different draft"
    let sending = Task { await model.send() }
    while !model.admitting { await Task.yield() }
    if afterClearing { model.draft = "" }
    model.draft = "The same text in a different draft"
    await model.send()
    await sending.value
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.count == 1)
    #expect(model.draft == "The same text in a different draft")
    #expect(!model.admitting)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func savedAdmissionStaysRetiredWhenTheConnectionOwnerStops(newerDraft: Bool) async throws {
  try await withCoordinator { session, _, outbox in
    let gate = AdmissionGate()
    let directory = outbox.deletingLastPathComponent()
    let draftURL = directory.appending(path: "composer.json")
    let files = AttachmentStore(directory: directory.appending(path: "Drafts"))
    let model = await MainActor.run {
      ChatModel(
        draftStore: files, persistence: ComposerDraftStore(url: draftURL),
        admit: { deliver in
          let saved = await deliver()
          #expect(saved)
          return await gate.admit()
        })
    }
    await model.restoreDraft()
    await model.attach(lane(session))
    await model.setActive(true)
    try await waitForComposerState { model.connection == .connected }
    await MainActor.run { model.draft = "The same text in a different draft" }
    #expect(await model.saveDraft())
    let sending = Task { await model.send() }
    for await _ in gate.entered { break }
    let saved = try queuedRequests(outbox)
    #expect(saved.count == 1)
    if newerDraft {
      await MainActor.run { model.draft = "The same text in a different draft" }
    }
    await model.detach(session.profile)
    await gate.finish(true)
    await sending.value
    let expected = newerDraft ? "The same text in a different draft" : ""
    #expect(await model.draft == expected)
    try #require(await model.saveDraft())
    let restored = try await ComposerDraftStore(url: draftURL).load(from: files)
    #expect(restored.draft.text == expected)
    #expect(await !model.admitting)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sendKeepsAnUnadmittedDraftAndClearsOnlyItsAdmittedOriginal() async throws {
  try await withConnectedModel { model, _, directory in
    let oversized = String(repeating: "x", count: 65537)
    model.draft = oversized
    await model.send()
    #expect(model.draft == oversized)
    #expect((try? queuedRequests(directory.outbox)) == nil, "Nothing was saved")
    model.draft = "Saved original"
    await model.send()
    #expect(model.draft.isEmpty)
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Saved original"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true], ["", "New typing"])
func sendingKeepsItsPersistedBackupUntilAdmissionFinishes(admitted: Bool, newText: String)
  async throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let files = AttachmentStore(directory: root.appending(path: "Files"))
  let url = root.appending(path: "draft.json")
  let gate = AdmissionGate()
  let model = ChatModel(
    draftStore: files, persistence: ComposerDraftStore(url: url),
    admit: { _ in await gate.admit() })
  await model.restoreDraft()
  try await withConnectedCoordinator(model) { _, _ in
    model.draft = "Original draft"
    #expect(await model.saveDraft())
    let sending = Task { await model.send() }
    for await _ in gate.entered { break }
    #expect(model.draft.isEmpty)
    if !newText.isEmpty {
      model.draft = newText
      #expect(await model.saveDraft())
    }
    let backup = "Original draft" + (newText.isEmpty ? "" : "\n\n" + newText)
    let saved = try await ComposerDraftStore(url: url).load(from: files)
    #expect(saved.draft.text == backup)
    await gate.finish(admitted)
    await sending.value
    #expect(model.draft == (admitted ? newText : backup))
    // Rejection schedules an autosave. Finish it before another owner reloads.
    #expect(await model.saveDraft())
    let restored = try await ComposerDraftStore(url: url).load(from: files)
    #expect(restored.draft.text == model.draft)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func rejectedAdmissionRestoresItsTextWithoutLosingNewTyping(stopping: Bool) async throws {
  try await withConnectedModel { model, _, directory in
    try await withReadOnlyProfile(directory) {
      model.draft = "Original draft"
      let sending = Task { await model.send() }
      while !model.admitting { await Task.yield() }
      model.draft = "New typing"
      if stopping { await model.detach(directory.profile) }
      await sending.value
      #expect(model.draft == "Original draft\n\nNew typing")
    }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func attachmentOnlyAdmissionPreservesFilesAndNewTyping(admitted: Bool) async throws {
  try await withConnectedModel { model, _, directory in
    await model.attach(data: Data([1]), name: "First.txt", mediaType: "text/plain")
    let sendWhileTypingAndAttaching = {
      let sending = Task { await model.send() }
      while !model.admitting { await Task.yield() }
      model.draft = "New typing"
      await model.attach(data: Data([2]), name: "Second.txt", mediaType: "text/plain")
      await sending.value
    }
    if admitted {
      await sendWhileTypingAndAttaching()
    } else {
      try await withReadOnlyProfile(directory) { await sendWhileTypingAndAttaching() }
    }
    #expect(
      model.attachments.map(\.reference.name)
        == (admitted ? ["Second.txt"] : ["First.txt", "Second.txt"]))
    #expect(model.draft == "New typing")
    #expect(try Data(contentsOf: #require(model.attachments.last).url) == Data([2]))
    if admitted {
      let queued = try queuedRequests(directory.outbox)
      #expect(queued.map(\.text) == [""])
      #expect(queued.first?.attachments?.map(\.name) == ["First.txt"])
    } else {
      #expect((try? queuedRequests(directory.outbox)) == nil, "Nothing was saved")
    }
  }
}

@MainActor private func connectModelThenRelease(_ session: CoordinatorSession) async throws {
  let model = ChatModel()
  model.attach(lane(session))
  await model.setActive(true)
  while model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
}

@Test(.timeLimit(.minutes(1)))
func detachAndModelDestructionBothCloseTheirSockets() async throws {
  try await withCoordinator { session, fixture, _ in
    let model = await MainActor.run { ChatModel() }
    let lane = lane(session)
    await model.attach(lane)
    await model.setActive(true)
    while await model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
    await model.detach(lane.id)
    for await _ in fixture.closedObservations { break }
    #expect(await model.connection == .disconnected)
    #expect(await session.submit("No orphaned observer") == false)
  }
  try await withCoordinator { session, fixture, _ in
    try await connectModelThenRelease(session)
    for await _ in fixture.closedObservations { break }
    #expect(await session.submit("Model was released") == false)
  }
}
