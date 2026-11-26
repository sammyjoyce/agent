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

  func file() async throws -> LocalAttachment {
    try await files.stage(
      data: Data("invented capture".utf8), name: "Feedback.png", mediaType: "image/png")
  }

  func erase() { try? FileManager.default.removeItem(at: root) }
}

private func profile(_ name: String, _ host: String) throws -> CoordinatorProfile {
  CoordinatorProfile(name: try TagName(name), address: try CoordinatorAddress(host: host))
}

extension DraftDisk {
  /// Writes a draft record as builds before the begin stamp saved it, with `addressing` as its
  /// addressing object.
  func saveRecord(_ text: String, addressing: [String: String]?) throws {
    var record: [String: Any] = [
      "revision": 1, "text": text, "mode": "steer", "attachments": [], "consumedTransfers": [],
    ]
    record["addressing"] = addressing
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: record).write(to: url)
  }
}

/// The required root fields of the draft decoder at 81ec9c2. Unknown keys are ignored.
private struct BaseDraftRecord: Decodable {
  let revision: UInt64
  let text: String
  let mode: InputMode
  let attachments: [AttachmentRef]
  let consumedTransfers: Set<UUID>
}

enum StoredWorkResponse: CaseIterable, Sendable {
  case active, pending, recovered
}

@MainActor @Test(arguments: StoredWorkResponse.allCases)
func workRecordsCannotBeOpenedByTheBaseDraftDecoder(_ position: StoredWorkResponse) async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let work = try profile("Work", "100.64.1.2")
  try disk.saveRecord("Invented ordinary draft", addressing: nil)
  let ordinaryBytes = try Data(contentsOf: disk.url)
  #expect(
    try JSONDecoder().decode(BaseDraftRecord.self, from: ordinaryBytes).text
      == "Invented ordinary draft")
  let store = ComposerDraftStore(url: disk.url)
  #expect(try await store.load(from: disk.files).draft.text == "Invented ordinary draft")
  let reference = WorkResponseReference(
    lane: work.id, coordinator: "Work", itemID: "task:orchard", conversationID: "orchard-thread",
    taskID: "orchard", agentID: nil, sidechatSlug: nil, isJob: false, title: "Orchard reply",
    detail: nil)
  let file = try await disk.file()
  let note = "Invented orchard reply"
  let metadata = RecoveredWorkResponse.Metadata(
    reference: reference, mode: .followUp, addressing: .init())
  var draft = ComposerDraft()
  switch position {
  case .active:
    draft = ComposerDraft(text: note, attachments: [file], workResponse: reference)
  case .pending:
    let identity = ComposerInputIdentity(composerID: UUID())
    draft.composerID = identity.composerID
    draft.submission = ComposerSubmission(
      identity: identity, outboxURLs: [disk.root.appending(path: "outbox.json")],
      text: note, attachments: [file], workResponse: metadata)
  case .recovered:
    draft.text = "Different invented draft"
    draft.recoveredWorkResponse = RecoveredWorkResponse(
      metadata: metadata, text: note, attachments: [file])
  }
  try #require(try await store.save(draft, revision: 2))
  let bytes = try Data(contentsOf: disk.url)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(BaseDraftRecord.self, from: bytes)
  }
  #expect(try Data(contentsOf: disk.url) == bytes)
  let reopened = try await disk.saved()
  if position == .recovered {
    #expect(reopened.recoveredWorkResponse == draft.recoveredWorkResponse)
    #expect(reopened.text == "Different invented draft")
  } else {
    #expect(
      reopened.workResponse == reference && reopened.text == note && reopened.attachments == [file])
  }
  let envelope = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
  let flat = try #require(envelope["draft"] as? [String: Any])
  try JSONSerialization.data(withJSONObject: flat).write(to: disk.url, options: .atomic)
  let migrated = await disk.launch([work])
  #expect(migrated.draftReady)
  #expect(migrated.workResponseTarget?.reference == reopened.workResponse)
  #expect(migrated.recoveredWorkResponse == reopened.recoveredWorkResponse)
  let migratedBytes = try Data(contentsOf: disk.url)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(BaseDraftRecord.self, from: migratedBytes)
  }
}

@MainActor @Test func anUnknownDraftVersionIsPreservedAndCannotSend() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  try disk.saveRecord("Invented ordinary draft", addressing: nil)
  let bytes = Data(#"{"version":99,"draft":{"revision":2,"text":"Invented later draft"}}"#.utf8)
  try bytes.write(to: disk.url, options: .atomic)
  let model = await disk.launch([])
  #expect(!model.draftReady && !model.canSend)
  #expect(model.draftError == "This app cannot open draft format 99. The draft was preserved.")
  #expect(await !model.saveDraft())
  #expect(try Data(contentsOf: disk.url) == bytes)
}

@Test func addressingRoundTripsThroughTheStore() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let work = ProfileID()
  let file = try await disk.file()
  let addressing = DraftAddressing(
    destination: .chip(work), restoredFrom: work,
    source: RestoredSource(
      lane: work, item: "example-item", kind: .held(queue: UUID()), text: "Invented",
      files: [file.id]))
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(text: "Invented", attachments: [file], addressing: addressing), revision: 1)
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
    ComposerDraft(
      text: restored, addressing: DraftAddressing(destination: .chip(work), source: source)),
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
  first.setChip(saved[1].id)
  #expect(await first.saveDraft())
  let next = await disk.launch(saved)
  #expect(next.draft == "Invented note")
  #expect(next.destination.chip == saved[1].id)
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
  first.setChip(gone.id)
  #expect(await first.saveDraft())
  let next = ChatModel(draftStore: disk.files, persistence: ComposerDraftStore(url: disk.url))
  try await withConnectedCoordinator(next) { _, _ in
    await next.restoreDraft()
    #expect(next.destination.chip == gone.id)
    #expect(next.recipientLine == "A coordinator was removed")
    #expect(!next.canSend)
  }
}

@MainActor @Test func aRecordSavedBeforeThisChangeLoadsWithTodaysMeaning() async throws {
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let (work, personal) = (saved[0].id, saved[1].id)
  let records: [(addressing: [String: String]?, destination: DraftDestination)] = [
    (nil, .open),
    (["restoredFrom": "\(work)"], .open),
    (["recipient": "\(personal)"], .chip(personal)),
  ]
  for record in records {
    let disk = DraftDisk()
    defer { disk.erase() }
    try disk.saveRecord("Invented note", addressing: record.addressing)
    let model = await disk.launch(saved)
    #expect(model.draftError == nil)
    #expect(model.draft == "Invented note")
    #expect(model.destination == record.destination, "\(record.addressing ?? [:])")
  }
}

@MainActor @Test func theDestinationRoundTripsAtomicallyWithTheText() async throws {
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let (work, personal) = (saved[0].id, saved[1].id)
  let destinations: [(shown: FeedScope, chip: ProfileID?, saved: DraftDestination)] = [
    (.all, nil, .open), (.one(work), nil, .begunIn(work)), (.one(work), personal, .chip(personal)),
  ]
  for destination in destinations {
    let disk = DraftDisk()
    defer { disk.erase() }
    let first = await disk.launch(saved)
    first.show(destination.shown)
    if let chip = destination.chip { first.setChip(chip) }
    first.draft = "Invented note"
    #expect(first.destination == destination.saved)
    #expect(await first.saveDraft())
    let next = await disk.launch(saved)
    #expect(next.draft == "Invented note" && next.destination == destination.saved)
    let data = try Data(contentsOf: disk.url)
    let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let keys = (record["addressing"] as? [String: Any]).map { Set($0.keys) } ?? []
    #expect(keys.intersection(["recipient", "begunIn"]).count <= 1, "\(keys)")
  }
}

@MainActor @Test func aRecordWithBothKeysLoadsAsTheChip() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  try disk.saveRecord(
    "Invented note", addressing: ["recipient": "\(saved[1].id)", "begunIn": "\(saved[0].id)"])
  let model = await disk.launch(saved)
  #expect(model.draft == "Invented note")
  #expect(model.destination == .chip(saved[1].id))
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSavedStampNamingNoSavedProfileBlocksInsteadOfBroadcasting() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let saved = try [profile("Work", "100.64.1.2"), profile("Personal", "100.64.1.3")]
  let gone = saved[1]
  let first = await disk.launch(saved)
  first.show(.one(gone.id))
  first.draft = "Invented note"
  #expect(first.destination == .begunIn(gone.id))
  #expect(await first.saveDraft())
  let next = ChatModel(draftStore: disk.files, persistence: ComposerDraftStore(url: disk.url))
  try await withConnectedCoordinator(next) { _, _ in
    await next.restoreDraft()
    #expect(next.destination == .begunIn(gone.id))
    #expect(next.recipientLine == "A coordinator was removed")
    #expect(!next.canSend)
  }
}

@MainActor @Test func anOldFormatDraftStillLoads() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let file = try await disk.file()
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(text: "/feedback Invented", attachments: [file]), revision: 1)
  let data = try Data(contentsOf: disk.url)
  let record = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(
    !record.keys.contains("addressing"),
    "An empty addressing writes no key, like a record from before addressing existed")
  let only = try profile("Work", "100.64.1.2")
  let model = await disk.launch([only])
  #expect(model.draftError == nil)
  #expect(model.draft == "/feedback Invented")
  #expect(model.attachments.map(\.id) == [file.id])
  #expect(try await disk.saved().addressing.isEmpty)
}

/// Earlier builds saved the automatic `/feedback` screenshot's ID and owner in the draft. Such a
/// draft still loads, its screenshot an ordinary file, and the next save drops both keys.
@MainActor @Test func aDraftSavedWithAFeedbackScreenshotStillLoads() async throws {
  let disk = DraftDisk()
  defer { disk.erase() }
  let work = try profile("Work", "100.64.1.2")
  let file = try await disk.file()
  try await ComposerDraftStore(url: disk.url).save(
    ComposerDraft(
      text: "/feedback Invented", attachments: [file],
      addressing: DraftAddressing(destination: .chip(work.id))), revision: 1)
  var record = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: disk.url)) as? [String: Any])
  record["feedbackScreenshotID"] = file.id
  var addressing = try #require(record["addressing"] as? [String: Any])
  addressing["screenshotOwner"] = work.id.description
  record["addressing"] = addressing
  try JSONSerialization.data(withJSONObject: record).write(to: disk.url)

  let model = await disk.launch([work])
  #expect(model.draftError == nil)
  #expect(model.draft == "/feedback Invented")
  #expect(model.attachments.map(\.id) == [file.id])
  #expect(model.destination == .chip(work.id))
  #expect(await model.saveDraft())
  let saved = try #require(String(data: try Data(contentsOf: disk.url), encoding: .utf8))
  #expect(!saved.contains("feedbackScreenshotID") && !saved.contains("screenshotOwner"))
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
    model.setChip(model.profiles[0].id)
    await model.send()
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Invented note"])
    #expect(model.destination.chip == nil)
  }
  let stopped = try #require(next.draft)
  #expect(stopped.text.isEmpty)
  #expect(stopped.addressing.isEmpty)
}
