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
