import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private actor ComposerOwnershipGate {
  nonisolated let entered = AsyncStream<Bool>.makeStream()
  private var continuation: CheckedContinuation<Void, Never>?

  func wait(after admitted: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered.continuation.yield(admitted)
    }
    return admitted
  }
  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

/// The lane's latest snapshot in `model` once it satisfies `predicate`. The model is the one
/// reader of its session's updates.
@MainActor private func snapshot(
  of session: CoordinatorSession, in model: ChatModel, where predicate: (ChatSnapshot) -> Bool
) async throws -> ChatSnapshot {
  let deadline = ContinuousClock.now + .seconds(8)
  while true {
    if let snapshot = model.snapshots[session.profile], predicate(snapshot) { return snapshot }
    guard ContinuousClock.now < deadline else { throw ConnectionError.timedOut }
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Attaches `session` as `model`'s only coordinator and waits for it to connect.
@MainActor private func connect(_ model: ChatModel, to session: CoordinatorSession) async throws {
  model.attach(lane(session))
  await model.setActive(true)
  _ = try await snapshot(of: session, in: model) { $0.connection == .connected }
}

enum ComposerOwnershipStage: CaseIterable, Sendable {
  case admitted, accepted, placed, retired, liveRetry, relocated
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ComposerOwnershipStage.allCases, [false, true])
func admittedComposerOwnershipSurvivesFailedCheckpointAndColdRestore(
  stage: ComposerOwnershipStage, newTyping: Bool
) async throws {
  try await withCoordinator { session, fixture, outbox in
    if stage == .admitted || stage == .liveRetry || stage == .relocated {
      await fixture.loseInputAcknowledgements()
    }
    if stage == .retired { await fixture.refuseUploads() }
    let root = outbox.deletingLastPathComponent()
    let directory = root.appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: root.appending(path: "Drafts"))
    let gate = ComposerOwnershipGate()
    let model = await MainActor.run {
      ChatModel(
        draftStore: files, persistence: ComposerDraftStore(url: url),
        admit: { deliver in await gate.wait(after: await deliver()) })
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    let original = "Two different drafts can contain this exact same text."
    await MainActor.run { model.draft = original }
    await model.attach(
      data: Data("Original file".utf8), name: "Original.txt", mediaType: "text/plain")
    try #require(await model.saveDraft())
    let originalFile = try #require(await model.attachments.first)
    let sending = Task { await model.send() }
    for await admitted in gate.entered.stream {
      try #require(admitted)
      break
    }
    let input = try #require(queuedRequests(outbox).first)
    #expect(input.text == original)
    switch stage {
    case .admitted, .liveRetry, .relocated: break
    case .accepted:
      _ = try await snapshot(of: session, in: model) {
        $0.rows.contains { $0.inputID == input.inputId && $0.delivery == .saved }
      }
    case .placed:
      let deadline = ContinuousClock.now + .seconds(8)
      while await fixture.count() == 0 {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(5))
      }
      await session.connect()
      _ = try await snapshot(of: session, in: model) {
        $0.connection == .connected
          && $0.rows.contains { $0.entryID == "placed-\(input.inputId)" }
      }
      #expect(try queuedRequests(outbox).isEmpty)
    case .retired:
      _ = try await snapshot(of: session, in: model) {
        $0.rows.contains { $0.inputID == input.inputId && $0.delivery == .rejected }
      }
      let recoveredFiles = AttachmentStore(directory: root.appending(path: "RecoveredFiles"))
      let recovered = try #require(await session.restore(input.inputId, to: recoveredFiles))
      try await ComposerDraftStore(url: root.appending(path: "recovered.json")).save(
        ComposerDraft(
          text: recovered.text, mode: recovered.mode, attachments: recovered.attachments),
        revision: 1)
      #expect(await session.commitRestoration(recovered) == .committed)
      #expect(try queuedRequests(outbox).isEmpty)
    }
    let newText = newTyping ? original : ""
    if newTyping {
      await MainActor.run {
        model.draft = newText
        model.mode = .followUp
      }
      await model.attach(data: Data("New file".utf8), name: "New.txt", mediaType: "text/plain")
      try #require(await model.saveDraft())
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await gate.finish()
    await sending.value
    #expect(await model.draft == newText)
    #expect(await model.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    #expect(await model.draftError != nil)

    var coldRoot = root
    var coldDirectory = directory
    var coldFiles = files
    var originalFileURL = originalFile.url
    if stage == .relocated {
      await session.disconnect()
      coldRoot = root.deletingLastPathComponent().appending(path: UUID().uuidString)
      try FileManager.default.moveItem(at: root, to: coldRoot)
      coldDirectory = coldRoot.appending(path: "Composer")
      coldFiles = AttachmentStore(directory: coldRoot.appending(path: "Drafts"))
      originalFileURL = try #require(await coldFiles.existing(originalFile.reference)).url
    }
    defer {
      if stage == .relocated {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: coldDirectory.path)
        try? FileManager.default.removeItem(at: coldRoot)
      }
    }

    // A different endpoint must not hide the admission proof in the original
    // endpoint's outbox. Receipt retirement must not hide it either.
    let cold: ChatModel
    if stage == .liveRetry {
      cold = model
    } else {
      let elsewhere = coldRoot.appending(path: "OtherEndpoint")
      let other = CoordinatorSession(
        directory: ProfileDirectory(ProfileID(), applicationSupport: elsewhere, caches: elsewhere),
        address: try CoordinatorAddress(host: "100.64.1.3"), pin: CoordinatorID(UUID()),
        stamps: StampSource(),
        transport: CoordinatorTransport { _ in throw ConnectionError.closed })
      cold = await MainActor.run {
        let cold = ChatModel(
          draftStore: coldFiles,
          persistence: ComposerDraftStore(url: coldDirectory.appending(path: "draft.json")))
        cold.attach(lane(other))
        return cold
      }
      await cold.restoreDraft()
    }
    #expect(FileManager.default.fileExists(atPath: originalFileURL.path))
    #expect(await cold.draft == newText)
    #expect(await cold.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    if newTyping {
      #expect(await cold.mode == .followUp)
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New file".utf8))
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: coldDirectory.path)
    try #require(await cold.saveDraft())
    #expect(!FileManager.default.fileExists(atPath: originalFileURL.path))
    if newTyping {
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New file".utf8))
    }
  }
}

@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: [(false, false), (true, false), (false, true), (true, true)])
func failedInitialComposerOrOutboxPersistenceDoesNotClaimTheDraft(
  outboxFailure: Bool, control: Bool
) async throws {
  try await withCoordinator { session, fixture, outbox in
    let directory = outbox.deletingLastPathComponent().appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: directory.appending(path: "Files"))
    let model = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    let text = control ? "/status" : "Keep this unadmitted note."
    await MainActor.run { model.draft = text }
    if !control {
      await model.attach(data: Data("Keep file".utf8), name: "Keep.txt", mediaType: "text/plain")
    }
    try #require(await model.saveDraft())
    if outboxFailure {
      try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    } else {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await model.send()
    #expect(await model.draft == text)
    #expect(await fixture.count() == 0)
    if outboxFailure {
      try FileManager.default.removeItem(at: outbox)
      // Rejection restores the live draft in defer and schedules its autosave.
      // Finish that owner before simulating a cold process with another store.
      try #require(await model.saveDraft())
    }
    let cold = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await cold.restoreDraft()
    #expect(await cold.draft == text)
    #expect(await cold.attachments.map(\.reference.name) == (control ? [] : ["Keep.txt"]))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func acceptedSlashControlDoesNotReturnFromAFailedComposerCheckpoint(newTyping: Bool) async throws {
  try await withCoordinator { session, fixture, outbox in
    let directory = outbox.deletingLastPathComponent().appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: directory.appending(path: "Files"))
    let gate = ComposerOwnershipGate()
    let model = await MainActor.run {
      ChatModel(
        draftStore: files, persistence: ComposerDraftStore(url: url),
        admit: { deliver in await gate.wait(after: await deliver()) })
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    await MainActor.run { model.draft = "/status" }
    let sending = Task { await model.send() }
    for await admitted in gate.entered.stream {
      try #require(admitted)
      break
    }
    for await input in fixture.observedInputs {
      #expect(input.text == "/status")
      #expect(input.attachments == nil)
      break
    }
    let newText = newTyping ? "/status" : ""
    if newTyping {
      await MainActor.run { model.draft = newText }
      await model.attach(data: Data("New note".utf8), name: "New.txt", mediaType: "text/plain")
      try #require(await model.saveDraft())
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await gate.finish()
    await sending.value
    #expect(await model.draft == newText)
    #expect(await model.draftError != nil)
    let cold = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await cold.restoreDraft()
    #expect(await cold.draft == newText)
    #expect(await cold.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    if newTyping {
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New note".utf8))
    }
    if FileManager.default.fileExists(atPath: outbox.path) {
      #expect(try queuedRequests(outbox).isEmpty, "Controls must not enter the replayable queue")
    }
    await session.disconnect()
    _ = try await snapshot(of: session, in: model) { $0.connection == .disconnected }
    await session.connect()
    let reconnected = try await snapshot(of: session, in: model) { $0.connection == .connected }
    #expect(reconnected.rows.isEmpty)
    #expect(await fixture.count() == 1, "Reconnection must not submit the control again")
  }
}
