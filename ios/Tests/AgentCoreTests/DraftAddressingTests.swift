import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// A draft's record and files under a fresh directory, as one launch after another finds them.
private struct DraftDisk {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  var files: AttachmentStore { AttachmentStore(directory: root.appending(path: "Drafts")) }
  var url: URL { root.appending(path: "Composer/draft.json") }

  /// A new launch's composer, with these coordinators saved, once it has restored the draft.
  @MainActor func launch(_ profiles: [CoordinatorProfile]) async -> ChatModel {
    let model = ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    model.profiles = profiles
    await model.restoreDraft()
    return model
  }

  /// What the next launch would read.
  func saved() async throws -> ComposerDraft {
    try await ComposerDraftStore(url: url).load(from: files).draft
  }

  func screenshot() async throws -> LocalAttachment {
    try await files.stage(
      data: Data("invented capture".utf8), name: "Feedback.png", mediaType: "image/png")
  }

  func erase() { try? FileManager.default.removeItem(at: root) }
}

private func profile(_ name: String, _ host: String) throws -> CoordinatorProfile {
  CoordinatorProfile(name: try TagName(name), address: try CoordinatorAddress(host: host))
}

@Test func addressingRoundTripsThroughTheStore() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let work = ProfileID()
  let shot = try await disk.screenshot()
  let addressing = DraftAddressing(
    recipient: work, restoredFrom: work, screenshotOwner: work,
    source: RestoredSource(
      lane: work, item: "example-item", kind: .held(queue: UUID()), text: "/feedback Invented",
      files: [shot.id]))
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(
      text: "/feedback Invented", attachments: [shot], feedbackScreenshotID: shot.id,
      addressing: addressing), revision: 1)
  #expect(try await disk.saved().addressing == addressing)
}

@Test func aRestoredTextIsSavedOnceAndStillMatchesItsUnchangedSend() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let work = ProfileID()
  let restored = "Invented restored note about the example report"
  let source = RestoredSource(
    lane: work, item: "example-item", kind: .live, text: restored, files: [])
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(text: restored, addressing: DraftAddressing(recipient: work, source: source)),
    revision: 1)
  let record = try #require(String(data: try Data(contentsOf: disk.url), encoding: .utf8))
  #expect(record.components(separatedBy: restored).count == 2, "The record holds the text once")
  let saved = try #require(try await disk.saved().addressing.source)
  #expect(saved.isCarried(by: "  \(restored)\n", files: [], to: [work]))
  #expect(!saved.isCarried(by: "\(restored), edited", files: [], to: [work]))
}

@MainActor @Test func aChipSurvivesRelaunch() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let first = await disk.launch(saved)
  first.draft = "Invented note"
  first.recipient = saved[1].id
  #expect(await first.saveDraft())
  let next = await disk.launch(saved)
  #expect(next.draft == "Invented note")
  #expect(next.recipient == saved[1].id)
  #expect(next.addresses(saved[1].id))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSavedAddresseeThatNoLongerExistsBlocksInsteadOfBroadcasting() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let gone = saved[1]
  let first = await disk.launch(saved)
  first.draft = "Invented note"
  first.recipient = gone.id
  #expect(await first.saveDraft())
  let next = ChatModel(draftStore: disk.files, persistence: ComposerDraftStore(url: disk.url))
  try await withConnectedCoordinator(next) { _, _ in
    await next.restoreDraft()
    #expect(next.recipient == gone.id)
    #expect(next.recipientLine == "A coordinator was removed")
    #expect(!next.canSend)
  }
}

@MainActor @Test func anOldFormatDraftStillLoads() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let shot = try await disk.screenshot()
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(text: "/feedback Invented", attachments: [shot], feedbackScreenshotID: shot.id),
    revision: 1)
  let data = try Data(contentsOf: disk.url)
  let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(
    !record.keys.contains("addressing"),
    "An empty addressing writes no key, like a record from before addressing existed")
  let only = try profile("Work", "100.64.1.2")
  let model = await disk.launch([only])
  #expect(model.draftError == nil)
  #expect(model.draft == "/feedback Invented")
  #expect(model.attachments.map(\.id) == [shot.id])
  #expect(try await disk.saved().addressing == DraftAddressing(screenshotOwner: only.id))
}

@MainActor @Test func theScreenshotOwnerSurvivesRelaunchWithTwoCoordinators() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let shot = try await disk.screenshot()
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(
      text: "/feedback Invented", attachments: [shot], feedbackScreenshotID: shot.id,
      addressing: DraftAddressing(screenshotOwner: saved[1].id)), revision: 1)
  let model = await disk.launch(saved)
  #expect(model.draftError == nil)
  #expect(try await disk.saved().addressing.screenshotOwner == saved[1].id)
}

@MainActor private final class NextLaunch {
  var draft: ComposerDraft?
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSendTheOutboxHoldsTakesItsChipWithItWhenTheAppStopsThere() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let next = NextLaunch()
  let model = ChatModel(
    draftStore: disk.files, persistence: ComposerDraftStore(url: disk.url),
    admit: { deliver in
      let held = await deliver()
      next.draft = try? await disk.saved()
      return held
    })
  await model.restoreDraft()
  try await withConnectedCoordinator(model) { _, directory in
    model.draft = "Invented note"
    model.recipient = model.profiles[0].id
    await model.send()
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Invented note"])
    #expect(model.recipient == nil)
  }
  let stopped = try #require(next.draft)
  #expect(stopped.text.isEmpty)
  #expect(stopped.addressing.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFeedbackScreenshotKeepsItsOwnerWhenTheAppStopsBeforeAnOutboxHoldsTheSend() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let next = NextLaunch()
  let model = ChatModel(
    draftStore: disk.files, persistence: ComposerDraftStore(url: disk.url),
    admit: { _ in
      next.draft = try? await disk.saved()
      return false
    })
  await model.restoreDraft()
  try await withConnectedCoordinator(model) { _, _ in
    model.draft = "/feedback Invented"
    await model.send(screenshot: { Data("invented capture".utf8) })
  }
  let stopped = try #require(next.draft)
  #expect(stopped.text == "/feedback Invented")
  #expect(stopped.feedbackScreenshotID != nil)
  #expect(stopped.addressing.screenshotOwner == model.profiles[0].id)
}
