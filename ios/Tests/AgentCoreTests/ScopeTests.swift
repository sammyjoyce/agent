import CoreGraphics
import Foundation
import ImageIO
import Network
import Testing
import UniformTypeIdentifiers

@testable import AgentCore
@testable import AgentUI

private func scopeRow(
  _ id: String, _ role: HistoryRole = .final, at seconds: TimeInterval, send: String? = nil,
  delivery: Delivery? = nil, input: String? = nil
) -> ChatRow {
  var row = ChatRow(id: id, role: role, text: id, delivery: delivery, inputID: input)
  row.receivedAt = Date(timeIntervalSince1970: seconds)
  row.sendID = send
  return row
}

private func mergeFixture(work: ProfileID, personal: ProfileID)
  -> [(id: ProfileID, snapshot: ChatSnapshot)]
{
  var fromWork = ChatSnapshot()
  fromWork.rows = [
    scopeRow("entry:w1:0", at: 1),
    scopeRow("input:wa", .user, at: 3, send: "A", input: "wa"),
    scopeRow("entry:w2:0", at: 4),
    scopeRow("input:wb", .user, at: 5, send: "B", input: "wb"),
    scopeRow("entry:w3:0", at: 7),
    scopeRow("entry:w3:1", at: 7),
    scopeRow("input:wd", .user, at: 9, send: "D", input: "wd"),
  ]
  fromWork.sends = [
    "A": .init(recipients: [work], progress: .placed),
    "B": .init(recipients: [work, personal], progress: .placed),
    "D": .init(recipients: [work, personal], progress: .placed),
  ]
  var fromPersonal = ChatSnapshot()
  fromPersonal.rows = [
    scopeRow("entry:p1:0", at: 2),
    scopeRow("input:pb", .user, at: 5.001, send: "B", delivery: .uncertain, input: "pb"),
    scopeRow("entry:p2:0", at: 7),
    scopeRow("input:pc", .user, at: 8, send: "C", input: "pc"),
  ]
  fromPersonal.sends = [
    "B": .init(recipients: [work, personal], progress: .pending(.uncertain)),
    "C": .init(recipients: [work, personal], progress: .placed),
    "D": .init(recipients: [work, personal], progress: .placed),
  ]
  return [(work, fromWork), (personal, fromPersonal)]
}

private func oldRefreshRows(_ lanes: [(id: ProfileID, snapshot: ChatSnapshot)]) -> [FeedRow] {
  let ordered = lanes.enumerated().flatMap { lane, source in
    source.snapshot.rows.enumerated().map { index, row in
      (stamp: row.receivedAt ?? .distantPast, lane: lane, index: index, id: source.id, row: row)
    }
  }.sorted { ($0.stamp, $0.lane, $0.index) < ($1.stamp, $1.lane, $1.index) }
  var shownIn: [String: ProfileID] = [:]
  var result: [FeedRow] = []
  for entry in ordered {
    let namespaced = FeedRow(
      id: "\(entry.id)/\(entry.row.id)", lane: entry.id, row: entry.row, receipts: [])
    guard entry.row.role == .user, let send = entry.row.sendID else {
      result.append(namespaced)
      continue
    }
    if let lane = shownIn[send] {
      if lane == entry.id { result.append(namespaced) }
      continue
    }
    shownIn[send] = entry.id
    let addressed = lanes.lazy.compactMap { $0.snapshot.sends[send] }.first
    let receipts: [Receipt] =
      addressed?.recipients.map { id in
        guard let lane = lanes.first(where: { $0.id == id }), let record = lane.snapshot.sends[send]
        else { return Receipt(lane: id, status: .unknown) }
        switch record.progress {
        case .placed: return Receipt(lane: id, status: .placed)
        case .withdrawn: return Receipt(lane: id, status: .notSent)
        case .held: return Receipt(lane: id, status: .pending(.saved, inputID: nil))
        case .pending(let delivery):
          let row = lane.snapshot.rows.first { $0.sendID == send && $0.delivery != nil }
          return Receipt(
            lane: id, status: .pending(delivery, inputID: row?.inputID), work: row?.work)
        }
      } ?? []
    result.append(FeedRow(id: "send:\(send)", lane: entry.id, row: entry.row, receipts: receipts))
  }
  return result
}

private func oldRefreshProjection(_ lanes: [(id: ProfileID, snapshot: ChatSnapshot)])
  -> FeedProjection
{
  let snapshots = lanes.map(\.snapshot)
  var usages: Set<String> = []
  return FeedProjection(
    rows: oldRefreshRows(lanes),
    connection: [ConnectionState.connected, .reconnecting, .connecting].first { state in
      snapshots.contains { $0.connection == state }
    } ?? .disconnected,
    model: snapshots.first?.model ?? "Unknown",
    busy: snapshots.contains(where: \.busy),
    commands: snapshots.flatMap(\.commands).filter { usages.insert($0.usage).inserted },
    canLoadEarlier: snapshots.contains { $0.olderCursor != nil },
    loadingHistory: snapshots.contains(where: \.loadingHistory),
    includesLatest: snapshots.allSatisfy(\.includesLatest))
}

private func temporaryRoot() throws -> URL {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  return root
}

@MainActor private func eventually(
  _ description: String, within limit: Duration = .seconds(15), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Saves Work and Personal for `chat`, each paired through a session that never dials and shown
/// connected, so the composer addresses both with no network.
@MainActor private func standIns(_ chat: ChatModel, in root: URL) throws -> (
  work: ProfileID, personal: ProfileID
) {
  let profiles = try [("Work", 4001), ("Personal", 4002)].map { name, port in
    CoordinatorProfile(
      name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.2", port: port))
  }
  chat.profiles = profiles
  for profile in profiles {
    let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
    chat.attach(
      Lane(
        id: profile.id,
        session: CoordinatorSession(
          directory: directory, address: profile.address, pin: CoordinatorID(UUID()),
          stamps: StampSource())))
    var connected = ChatSnapshot()
    connected.connection = .connected
    chat.apply(connected, lane: profile.id)
  }
  return (profiles[0].id, profiles[1].id)
}

/// A file whose bytes come through a named pipe, so a copy that opens it waits until the test
/// calls `finish()`.
@MainActor private final class PipedCopy {
  let url: URL
  private let bytes: Data
  private var writer: Int32 = -1

  /// Puts a pipe in place of the file at `url`, which gives its reader the file's bytes.
  convenience init(replacing url: URL) throws {
    let bytes = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try self.init(at: url, bytes: bytes)
  }

  init(at url: URL, bytes: Data) throws {
    self.url = url
    self.bytes = bytes
    guard mkfifo(url.path, 0o600) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Returns once a copy has opened the pipe. The copy then waits for `finish()`.
  func opened() async throws {
    let deadline = ContinuousClock.now + .seconds(15)
    while writer < 0 {
      writer = open(url.path, O_WRONLY | O_NONBLOCK)
      guard writer < 0 else { return }
      try #require(ContinuousClock.now < deadline, "Nothing opened \(url.lastPathComponent)")
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  /// Gives the copy the bytes and ends the file, so the copy completes.
  func finish() {
    _ = bytes.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
    release()
  }

  /// Ends a copy still waiting at the pipe, so a failed test leaves none stuck.
  func release() {
    if writer < 0 { writer = open(url.path, O_WRONLY | O_NONBLOCK) }
    if writer >= 0 { close(writer) }
    writer = -1
  }
}

/// A pasted or dropped PNG, as the system offers it.
private func imageProvider(in root: URL) throws -> NSItemProvider {
  let context = try #require(
    CGContext(
      data: nil, width: 12, height: 8, bitsPerComponent: 8, bytesPerRow: 48,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
  let data = NSMutableData()
  let image = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(image, try #require(context.makeImage()), nil)
  try #require(CGImageDestinationFinalize(image))
  let url = root.appending(path: "Pasted.png")
  try (data as Data).write(to: url)
  let provider = NSItemProvider()
  provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) {
    done in
    done(url, false, nil)
    return nil
  }
  return provider
}

@MainActor private final class TypingDuringAdmission {
  var edit: () -> Void = {}
}

@Suite struct ScopeTests {
  @Test func aSendToBothStaysInEachRecipientsScopeWithBothReceipts() throws {
    let work = ProfileID()
    let personal = ProfileID()
    var fromWork = ChatSnapshot()
    var fromPersonal = ChatSnapshot()
    let workCopy = scopeRow("input:w", .user, at: 1, send: "X", input: "w")
    let personalCopy = scopeRow("input:p", .user, at: 2, send: "X", input: "p")
    fromWork.rows = [workCopy]
    fromPersonal.rows = [personalCopy]
    let placed = SendStatus(recipients: [work, personal], progress: .placed)
    fromWork.sends = ["X": placed]
    fromPersonal.sends = ["X": placed]
    let lanes = [(work, fromWork), (personal, fromPersonal)]
    let receipts = [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .placed)]

    for (id, copy) in [(work, workCopy), (personal, personalCopy)] {
      let row = try #require(Feed.merge(lanes, showing: .one(id)).first)
      #expect(row == FeedRow(id: "send:X", lane: id, row: copy, receipts: receipts))
      #expect(Feed.merge(lanes, showing: .one(id)).count == 1)
    }
  }

  @MainActor @Test func aScopedMergeDropsOnlyTheOtherLanesRows() throws {
    let work = ProfileID()
    let personal = ProfileID()
    func tool(_ id: String, at seconds: TimeInterval) -> ChatRow {
      var row = ChatRow(
        id: id, entryID: id, role: .tool, text: "",
        tool: .init(callId: id, name: "exec", status: .finished))
      row.receivedAt = Date(timeIntervalSince1970: seconds)
      return row
    }
    var fromWork = ChatSnapshot()
    fromWork.rows = [tool("w1", at: 1), tool("w2", at: 3), scopeRow("w3", at: 5)]
    var fromPersonal = ChatSnapshot()
    fromPersonal.rows = [tool("p1", at: 2), tool("p2", at: 4), scopeRow("p3", at: 6)]
    let lanes = [(work, fromWork), (personal, fromPersonal)]
    let rows = Feed.merge(lanes, showing: .one(personal))
    #expect(rows.map(\.row.id) == ["p1", "p2", "p3"])
    #expect(rows.allSatisfy { $0.lane == personal })
    let items = TranscriptItem.grouped(rows.map(RowModel.init))
    #expect(items.map(\.lane) == [personal, personal])
    guard case .activity(let group) = try #require(items.first) else {
      Issue.record("Expected Personal's activity group")
      return
    }
    #expect(group.rows.map(\.row.id) == ["p1", "p2"])
    #expect(group.rows.allSatisfy { $0.lane == personal })
  }

  @Test func projectionAggregatesFollowTheScope() {
    let work = ProfileID()
    let personal = ProfileID()
    let workCommand = SlashCommand(description: "Work command", usage: "/work")
    let personalCommand = SlashCommand(description: "Personal command", usage: "/personal")
    var fromWork = ChatSnapshot()
    fromWork.connection = .disconnected
    fromWork.busy = true
    fromWork.model = "Work model"
    fromWork.commands = [workCommand]
    fromWork.olderCursor = "older"
    fromWork.loadingHistory = true
    fromWork.includesLatest = false
    var fromPersonal = ChatSnapshot()
    fromPersonal.connection = .connected
    fromPersonal.model = "Personal model"
    fromPersonal.commands = [personalCommand]
    let lanes = [(work, fromWork), (personal, fromPersonal)]
    let projection = Feed.project(lanes, scope: .one(personal))
    #expect(projection.connection == .connected)
    #expect(!projection.busy)
    #expect(projection.model == "Personal model")
    #expect(projection.commands == [personalCommand])
    #expect(!projection.canLoadEarlier)
    #expect(!projection.loadingHistory)
    #expect(projection.includesLatest)

    let workProjection = Feed.project(lanes, scope: .one(work))
    #expect(workProjection.connection == .disconnected)
    #expect(workProjection.busy)
    #expect(workProjection.model == "Work model")
    #expect(workProjection.commands == [workCommand])
    #expect(workProjection.canLoadEarlier)
    #expect(workProjection.loadingHistory)
    #expect(!workProjection.includesLatest)

    let absent = Feed.project(lanes, scope: .one(ProfileID()))
    #expect(absent.rows.isEmpty)
    #expect(absent.connection == .disconnected)
    #expect(absent.model == "Unknown")
    #expect(absent.includesLatest)
  }

  @Test func allProjectionMatchesTodaysRefresh() {
    let work = ProfileID()
    let personal = ProfileID()
    var lanes = mergeFixture(work: work, personal: personal)
    lanes[0].snapshot.connection = .reconnecting
    lanes[0].snapshot.model = "Work model"
    lanes[0].snapshot.busy = true
    lanes[0].snapshot.commands = [
      .init(description: "First", usage: "/shared"),
      .init(description: "Work", usage: "/work"),
    ]
    lanes[0].snapshot.olderCursor = "older"
    lanes[1].snapshot.connection = .connected
    lanes[1].snapshot.model = "Personal model"
    lanes[1].snapshot.commands = [
      .init(description: "Second", usage: "/shared"),
      .init(description: "Personal", usage: "/personal"),
    ]
    lanes[1].snapshot.loadingHistory = true
    lanes[1].snapshot.includesLatest = false

    let fixtureRows = Feed.project(lanes, scope: .all).rows
    #expect(
      fixtureRows.map(\.id) == [
        "\(work)/entry:w1:0", "\(personal)/entry:p1:0", "send:A", "\(work)/entry:w2:0",
        "send:B", "\(work)/entry:w3:0", "\(work)/entry:w3:1", "\(personal)/entry:p2:0",
        "send:C", "send:D",
      ])
    #expect(
      fixtureRows.first { $0.id == "send:B" }?.receipts == [
        Receipt(lane: work, status: .placed),
        Receipt(lane: personal, status: .pending(.uncertain, inputID: "pb")),
      ])

    let removed = ProfileID()
    var fromWork = ChatSnapshot()
    fromWork.rows = [
      scopeRow("input:old", .user, at: 1, send: "old", input: "old"),
      scopeRow("input:new", .user, at: 3, send: "new", input: "new"),
      scopeRow("input:gone", .user, at: 4, send: "gone", input: "gone"),
      scopeRow("input:back", .user, at: 5, send: "back", input: "back"),
    ]
    fromWork.sends = [
      "old": .init(recipients: [work, personal], progress: .placed),
      "new": .init(recipients: [work, personal], progress: .placed),
      "gone": .init(recipients: [work, removed], progress: .placed),
      "back": .init(recipients: [work, personal], progress: .placed),
    ]
    var fromPersonal = ChatSnapshot()
    fromPersonal.sends = ["back": .init(recipients: [work, personal], progress: .withdrawn)]
    let missingAndWithdrawn = [
      (id: work, snapshot: fromWork), (id: personal, snapshot: fromPersonal),
    ]
    var workCopy = scopeRow("input:w", .user, at: 1, send: "S", delivery: .saved, input: "w")
    workCopy.work = .running
    fromWork.rows = [workCopy]
    fromWork.sends = ["S": .init(recipients: [work, personal], progress: .pending(.saved))]
    var personalCopy = scopeRow("input:p", .user, at: 2, send: "S", delivery: .saved, input: "p")
    personalCopy.work = .blocked(.init(reason: .restartLimit))
    fromPersonal.rows = [personalCopy]
    fromPersonal.sends = ["S": .init(recipients: [work, personal], progress: .pending(.saved))]
    let workStates = [(id: work, snapshot: fromWork), (id: personal, snapshot: fromPersonal)]
    let fixtures = [
      [], [lanes[0]], [lanes[1]], lanes, lanes.reversed().map { $0 }, missingAndWithdrawn,
      workStates,
    ]
    for fixture in fixtures {
      #expect(Feed.project(fixture, scope: .all) == oldRefreshProjection(fixture))
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func allProjectionMatchesLiveFeedFixture() async throws {
    try await withTwoFixtures { coordinators, _, _, _ in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.draft = "An invented message to both"
      await chat.send()
      let deadline = ContinuousClock.now + .seconds(15)
      while ![work, personal].allSatisfy({ id in
        chat.snapshots[id]?.sends.values.contains { $0.progress == .placed } == true
      }) {
        try #require(ContinuousClock.now < deadline, "Both coordinators must place the message")
        try await Task.sleep(for: .milliseconds(5))
      }
      let states = try [work, personal].map { id in
        (id: id, snapshot: try #require(chat.snapshots[id]))
      }
      let expected = oldRefreshProjection(states)
      #expect(Feed.project(states, scope: .all) == expected)
      #expect(chat.rows.map(\.id) == expected.rows.map(\.id))
      #expect(chat.rows.map(\.row) == expected.rows.map(\.row))
      #expect(chat.rows.map(\.receipts) == expected.rows.map(\.receipts))
      #expect(chat.connection == expected.connection)
      #expect(chat.model == expected.model)
      #expect(chat.busy == expected.busy)
      #expect(chat.commands == expected.commands)
      #expect(chat.canLoadEarlier == expected.canLoadEarlier)
      #expect(chat.loadingHistory == expected.loadingHistory)
      #expect(chat.includesLatest == expected.includesLatest)
    }
  }

  @Test func scopeResolvesOnlyToSavedNonRemovedCoordinators() throws {
    let address = try CoordinatorAddress(host: "100.64.1.2")
    let work = CoordinatorProfile(name: try TagName("Work"), address: address)
    let personal = CoordinatorProfile(name: try TagName("Personal"), address: address)
    let profiles = [work, personal]
    #expect(FeedScope.resolve(.one(work.id), profiles: profiles, removed: [:]) == .one(work.id))
    #expect(FeedScope.resolve(.one(work.id), profiles: [work], removed: [:]) == .all)
    #expect(FeedScope.resolve(.one(ProfileID()), profiles: profiles, removed: [:]) == .all)
    #expect(
      FeedScope.resolve(.one(work.id), profiles: profiles, removed: [work.id: "Work"]) == .all)
    #expect(FeedScope.resolve(.all, profiles: profiles, removed: [:]) == .all)
    #expect(FeedScope(sending: [personal.id]) == .one(personal.id))
    #expect(FeedScope(sending: []) == .all)
    #expect(FeedScope(sending: [work.id, personal.id]) == .all)
    #expect(FeedScope.one(work.id).coordinator == work.id)
    #expect(FeedScope.all.coordinator == nil)
    #expect(FeedScope.all.shows(personal.id))
    #expect(!FeedScope.one(work.id).shows(personal.id))
  }

  @MainActor @Test func revisionTracksProjectedChanges() {
    let work = ProfileID()
    let personal = ProfileID()
    let model = ChatModel()
    model.attach(Lane(id: work, session: nil))
    model.attach(Lane(id: personal, session: nil))
    var fromWork = ChatSnapshot()
    fromWork.rows = [scopeRow("input:w", .user, at: 1, send: "X", input: "w")]
    fromWork.sends = ["X": .init(recipients: [work, personal], progress: .placed)]
    var fromPersonal = ChatSnapshot()
    fromPersonal.sends = ["X": .init(recipients: [work, personal], progress: .placed)]
    model.apply(fromWork, lane: work)
    model.apply(fromPersonal, lane: personal)
    let initial = model.revision
    model.apply(fromPersonal, lane: personal)
    #expect(model.revision == initial)

    fromPersonal.sends["X"] = .init(recipients: [work, personal], progress: .withdrawn)
    model.apply(fromPersonal, lane: personal)
    #expect(model.revision == initial + 1)
    #expect(model.rows.first?.receipts.last == Receipt(lane: personal, status: .notSent))
    let receiptRevision = model.revision
    fromPersonal.connection = .connected
    model.apply(fromPersonal, lane: personal)
    #expect(model.revision == receiptRevision + 1)
    #expect(model.connection == .connected)
  }

  /// A scope switch shows another feed with fresh rows and is remembered for the device. It never
  /// changes who the draft goes to. A draft to both reads where it would go until it is narrowed.
  @MainActor @Test func showingACoordinatorRebuildsTheFeedAndNeverReaddressesTheDraft() throws {
    let suite = "scope-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = ChatModel(scope: ScopePreference(defaults: defaults))
    let (work, personal) = try standIns(chat, in: root)
    var fromWork = ChatSnapshot()
    fromWork.connection = .connected
    fromWork.rows = [scopeRow("input:w", .user, at: 1, send: "X", input: "w")]
    fromWork.sends = ["X": .init(recipients: [work, personal], progress: .placed)]
    var fromPersonal = ChatSnapshot()
    fromPersonal.connection = .connected
    fromPersonal.rows = [
      scopeRow("input:p", .user, at: 2, send: "X", input: "p"), scopeRow("entry:p1:0", at: 3),
    ]
    fromPersonal.sends = fromWork.sends
    chat.apply(fromWork, lane: work)
    chat.apply(fromPersonal, lane: personal)
    let text = "Invented note for both"
    chat.draft = text
    let addressing = chat.draftAddressing
    let shown = chat.rows
    let revision = chat.revision
    #expect(
      shown.first?.row.inputID == "w" && chat.addressing == .to([work, personal], body: text))

    chat.show(.one(personal))
    #expect(chat.scope == .one(personal))
    #expect(chat.rows.map(\.lane) == [personal, personal])
    #expect(chat.rows.first?.row.inputID == "p", "The Send's row is Personal's copy")
    #expect(chat.rows.allSatisfy { row in !shown.contains { $0 === row } }, "No row is reused")
    #expect(chat.revision != revision)
    #expect(chat.draft == text && chat.draftAddressing == addressing)
    #expect(chat.addressing == .elsewhere([work, personal], narrows: true))
    #expect(chat.recipientLine == "This draft goes to Work and Personal" && !chat.canSend)
    #expect(defaults.string(forKey: ScopePreference.key) == personal.description)
    chat.setChip(personal)
    #expect(chat.addressing == .to([personal], body: text) && chat.recipientLine == "To Personal")

    chat.removeChip()
    chat.draft = ""
    chat.show(.one(work))
    chat.draft = "Invented note for Work"
    chat.show(.one(personal))
    chat.draft += ", typed on in Personal"
    #expect(chat.destination == .begunIn(work), "A switch never restamps a begun draft")
    #expect(chat.recipientLine == "This draft goes to Work")

    let next = ChatModel(scope: ScopePreference(defaults: defaults))
    next.profiles = chat.profiles
    #expect(next.scope == .one(personal), "The next launch shows Personal")
    for stale in ["Personal", ProfileID().description] {
      defaults.set(stale, forKey: ScopePreference.key)
      let launched = ChatModel(scope: ScopePreference(defaults: defaults))
      launched.profiles = chat.profiles
      #expect(launched.scope == .all, "\(stale) loads as All")
    }
  }

  /// In one coordinator's feed every way to start a draft begins it there. A share import and a
  /// Restore do not, and in All nothing does. Clearing the composer ends the stamp.
  @MainActor @Test func everyUserEntryPointStampsTheShownCoordinator() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = ChatModel(draftStore: AttachmentStore(directory: root.appending(path: "Drafts")))
    let (work, personal) = try standIns(chat, in: root)
    chat.show(.one(work))
    #expect(chat.recipientLine == "To Work", "An empty composer reads as begun in Work")
    let notes = root.appending(path: "Notes.txt")
    try Data("Invented notes".utf8).write(to: notes)
    let image = try imageProvider(in: root)
    let entries: [(name: String, begin: @MainActor () async -> Void)] = [
      ("typing", { chat.draft = "Rotate the staging deploy key" }),
      // As the Commands menu writes it.
      ("Commands", { chat.draft = "/status " }),
      ("attach(urls:)", { await chat.attach(urls: [notes])?.value }),
      ("attach(providers:)", { await chat.attach(providers: [image])?.value }),
      (
        "attach(data:)",
        {
          await chat.attach(
            data: Data("invented paste".utf8), name: "Paste.txt", mediaType: "text/plain")
        }
      ),
    ]
    for entry in entries {
      await entry.begin()
      #expect(chat.failure == nil, "\(entry.name)")
      #expect(chat.destination == .begunIn(work), "\(entry.name)")
      #expect(chat.recipientLine == "To Work", "\(entry.name)")
      chat.draft = ""
      for file in chat.attachments { await chat.removeAttachment(file) }
      #expect(chat.destination == .open, "Clearing the composer ends what \(entry.name) began")
    }

    chat.show(.all)
    chat.draft = "Invented note for everyone"
    #expect(chat.destination == .open, "All stamps nothing")
    chat.draft = ""

    chat.show(.one(work))
    let hold = try heldQueue(
      [NativeRequestSubmit(inputId: "held-1", mode: .steer, text: "Invented held note")], in: root)
    chat.holds.append(hold)
    let held = HeldMessage(
      queue: hold.queue.id, item: try #require(try await hold.store.items().first))
    await chat.restoreHeld(held, for: personal)
    #expect(chat.draft == "Invented held note")
    #expect(chat.destination == .chip(personal), "Restore addresses its coordinator, not the feed")

    let inbox = SharedDraftInbox(containerURL: root)
    let shared = ChatModel(
      draftStore: AttachmentStore(directory: root.appending(path: "Shared drafts")),
      persistence: ComposerDraftStore(url: root.appending(path: "draft.json")),
      sharedInbox: inbox)
    let lanes = try standIns(shared, in: root)
    shared.show(.one(lanes.work))
    try await inbox.enqueue(images: [], note: "https://example.com/article")
    await shared.restoreDraft()
    #expect(shared.draft == "https://example.com/article")
    #expect(shared.destination == .open, "A share import stamps nothing")
  }

  /// A file the user chose in Work's feed stays Work's when its copy lands after a switch to
  /// Personal. If the user typed in Personal meanwhile, the file joins that draft instead.
  @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func aFileChosenInWorkStaysWorksAfterASwitch(typedInPersonal: Bool) async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AttachmentStore(directory: root.appending(path: "Drafts"))
    let chat = ChatModel(draftStore: store)
    let (work, personal) = try standIns(chat, in: root)
    chat.show(.one(work))
    let chosen = root.appending(path: "Agenda.txt")
    try Data("Invented offsite agenda".utf8).write(to: chosen)
    // The store copies one file at a time, so the chosen file's copy waits behind one held at a
    // pipe. The chosen file cannot be the pipe, since only a regular file can be attached.
    let held = try PipedCopy(at: root.appending(path: "Earlier.txt"), bytes: Data("x".utf8))
    defer { held.release() }
    let reference = AttachmentRef(
      id: UUID().uuidString, mediaType: "text/plain", name: "Earlier.txt", sha256: "",
      sizeBytes: 1)
    let earlier = Task {
      try? await store.adopt(LocalAttachment(reference: reference, url: held.url))
    }
    try await held.opened()
    let attaching = chat.attach(urls: [chosen])
    chat.show(.one(personal))
    if typedInPersonal { chat.draft = "hi" }
    held.finish()
    _ = await earlier.value
    await attaching?.value
    #expect(chat.attachments.map(\.reference.name) == ["Agenda.txt"])
    if typedInPersonal {
      #expect(chat.destination == .begunIn(personal), "The file joins the draft typed meanwhile")
      #expect(chat.addressing == .to([personal], body: "hi"))
    } else {
      #expect(chat.destination == .begunIn(work), "The file keeps the feed it was chosen in")
      #expect(chat.addressing == .elsewhere([work], narrows: false))
      #expect(chat.recipientLine == "This draft goes to Work" && !chat.canSend)
    }
  }

  /// A file picked in Work's feed is Work's even when the feed shows Personal before its copy
  /// starts, as a switch made right after the pick can. Personal's feed refuses it, and only Work
  /// gets it.
  @MainActor @Test(.timeLimit(.minutes(1)), arguments: ["Choose files", "Paste"])
  func aFilePickedInWorkReachesOnlyWorkAfterAnImmediateSwitch(_ action: String) async throws {
    try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      let agenda = root.appending(path: "Agenda.txt")
      try Data("Invented offsite agenda".utf8).write(to: agenda)
      let image = try imageProvider(in: root)
      chat.show(.one(work))
      let picking =
        action == "Paste" ? chat.attach(providers: [image]) : chat.attach(urls: [agenda])
      chat.show(.one(personal))
      await picking?.value
      #expect(chat.attachments.count == 1)
      #expect(chat.destination == .begunIn(work), "The file keeps the feed it was picked in")
      #expect(chat.recipientLine == "This draft goes to Work" && !chat.canSend)
      await chat.send()
      chat.show(.one(work))
      await chat.send()
      try await eventually("Work got it") { await workFixture.count() == 1 }
      #expect(await personalFixture.count() == 0)
    }
  }

  /// Restore checks the composer before it copies Personal's files and fills it after. A draft
  /// begun in Work while the copy runs is not Personal's, so the Restore is refused and the draft
  /// stays Work's. Typed in All, the draft has no address of its own, so the restored message goes
  /// before it.
  @MainActor @Test(.timeLimit(.minutes(1)), arguments: ["Work", "All"])
  func aRestoreThatFinishesAfterADraftBeganElsewhereIsRefused(_ typedIn: String) async throws {
    try await withTwoFixtures { coordinators, _, personalFixture, root in
      await personalFixture.refuseUploads()
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      let personalDirectory = ProfileDirectory(personal, applicationSupport: root, caches: root)
      chat.setChip(personal)
      chat.draft = "Invented: the venue contract"
      await chat.attach(
        data: Data("invented contract".utf8), name: "Contract.txt", mediaType: "text/plain")
      await chat.send()
      try await eventually("rejected by Personal") {
        chat.snapshots[personal]?.rows.contains { $0.delivery == .rejected } == true
      }
      let original = try #require(try queuedRequests(personalDirectory.outbox).first)
      let file = try #require(original.attachments?.first)
      let held = try PipedCopy(
        replacing: personalDirectory.outboxAttachments.appending(path: file.id)
          .appending(path: file.name))
      defer { held.release() }
      let drafts = root.appending(path: "Agent/Drafts")
      let draftFiles = { (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? [] }
      let filesBefore = draftFiles()
      chat.show(.one(personal))
      let restoring = Task { await chat.restore(original.inputId) }
      try await held.opened()
      let typed = "Deploy at noon"
      chat.show(typedIn == "Work" ? .one(work) : .all)
      chat.draft = typed
      held.finish()
      await restoring.value
      if typedIn == "Work" {
        #expect(chat.draft == typed && chat.destination == .begunIn(work))
        #expect(chat.recipientLine == "To Work")
        #expect(chat.attachments.isEmpty && draftFiles() == filesBefore, "The copies are gone")
        #expect(chat.failure == "Send or clear the current draft before restoring another message.")
      } else {
        #expect(chat.draft == original.text + "\n\n" + typed)
        #expect(chat.destination == .chip(personal))
        #expect(chat.attachments.map(\.reference.name) == ["Contract.txt"])
      }
    }
  }

  /// Restore copies Work's files before it fills the composer. A draft tagged for Personal while
  /// the copy runs is not Work's, whether its tag is committed or the text after it is still being
  /// composed, and whether it was typed in Work's feed or in All. The Restore is refused, and the
  /// draft goes to Personal alone once it is sent.
  @MainActor @Test(.timeLimit(.minutes(1)), arguments: ["Work", "Work, composing", "All"])
  func aRestoreLeavesADraftTaggedForAnotherCoordinatorAlone(_ typedIn: String) async throws {
    try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
      await workFixture.refuseUploads()
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
      chat.setChip(work)
      chat.draft = "Invented: the Work offsite contract"
      await chat.attach(
        data: Data("invented contract".utf8), name: "Contract.txt", mediaType: "text/plain")
      await chat.send()
      try await eventually("rejected by Work") {
        chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
      }
      let original = try #require(try queuedRequests(workDirectory.outbox).first)
      let file = try #require(original.attachments?.first)
      let held = try PipedCopy(
        replacing: workDirectory.outboxAttachments.appending(path: file.id)
          .appending(path: file.name))
      defer { held.release() }
      let drafts = root.appending(path: "Agent/Drafts")
      let draftFiles = { (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? [] }
      let filesBefore = draftFiles()
      chat.show(typedIn == "All" ? .all : .one(work))
      let restoring = Task { await chat.restore(original.inputId) }
      try await held.opened()
      let typed = typedIn == "Work, composing" ? "@Personal the venue shortlist" : "@Personal"
      chat.edit(typed, committed: "@Personal")
      chat.promoteTypedTag()
      let destination = chat.destination
      held.finish()
      await restoring.value
      #expect(chat.draft == typed && chat.destination == destination)
      #expect(
        chat.recipientLine == (typedIn == "All" ? "To Personal" : "This draft goes to Personal"))
      #expect(chat.attachments.isEmpty && draftFiles() == filesBefore, "The copies are gone")
      #expect(chat.failure == "Send or clear the current draft before restoring another message.")
      let finished = "@Personal the venue shortlist"
      chat.edit(finished, committed: finished)
      chat.promoteTypedTag()
      chat.show(.one(personal))
      await chat.send()
      try await eventually("Personal got it") { await personalFixture.count() == 1 }
      #expect(await submitted(personalFixture) == ["the venue shortlist"])
      #expect(await workFixture.count() == 0)
    }
  }

  /// With one coordinator saved, a leading @ names no one, as on `main`. Text typed that way while
  /// Restore copies Work's files goes after the restored message, and Work gets both.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func withOneCoordinatorARestoreKeepsAnAtTypedMeanwhile() async throws {
    try await withTwoFixtures { coordinators, workFixture, _, root in
      await workFixture.refuseUploads()
      try await coordinators.add(
        name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      let work = try #require(coordinators.profiles.first?.id)
      let chat = coordinators.chat
      try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
      let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
      let text = "Invented: the Work offsite contract"
      chat.draft = text
      await chat.attach(
        data: Data("invented contract".utf8), name: "Contract.txt", mediaType: "text/plain")
      await chat.send()
      try await eventually("rejected by Work") {
        chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
      }
      let original = try #require(try queuedRequests(workDirectory.outbox).first)
      let file = try #require(original.attachments?.first)
      let held = try PipedCopy(
        replacing: workDirectory.outboxAttachments.appending(path: file.id)
          .appending(path: file.name))
      defer { held.release() }
      let restoring = Task { await chat.restore(original.inputId) }
      try await held.opened()
      let typed = "@here the venue shortlist"
      chat.edit(typed, committed: typed)
      chat.promoteTypedTag()
      held.finish()
      await restoring.value
      #expect(chat.draft == text + "\n\n" + typed)
      #expect(chat.attachments.map(\.reference.name) == ["Contract.txt"])
      await workFixture.acceptUploads()
      try await eventually("Send is enabled") { chat.canSend }
      await chat.send()
      try await eventually("Work got it") { await workFixture.count() == 1 }
      #expect(await submitted(workFixture) == [text + "\n\n" + typed])
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aBegunDraftHoldsRemoval() async throws {
    try await withTwoFixtures { coordinators, _, _, _ in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.show(.one(work))
      chat.draft = "Invented board minutes"
      #expect(chat.destination == .begunIn(work))
      do {
        try await coordinators.remove(coordinators.removal(work))
        Issue.record("Remove went ahead with a draft begun in Work")
      } catch {
        #expect(error.localizedDescription == "Send or clear the draft for Work first.")
      }
      #expect(coordinators.profiles.map(\.id) == [work, personal])
      chat.draft = ""
      try await coordinators.remove(coordinators.removal(work))
      #expect(coordinators.profiles.map(\.id) == [personal], "A cleared draft lets Remove go ahead")
      #expect(chat.scope == .all, "With Work removed the feed shows All")
    }
  }

  /// Removing Work while its feed is shown shows All at once, while Remove still waits on Work's
  /// alert withdrawal, and All is Personal's conversation alone once Work is gone.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func removingTheShownCoordinatorShowsAllAtOnce() async throws {
    let registration = NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    let gate = DialGate()
    try await withTwoFixtures(registration: registration, holdingWork: gate) {
      coordinators, workFixture, personalFixture, _ in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      try await eventually("Work's alert channel linked") { registration.status(work).configured }
      for (fixture, entry) in [(workFixture, "work-reply"), (personalFixture, "personal-reply")] {
        try await fixture.liveMessage(
          HistoryMessage(
            continuation: false, entryId: entry, finalChunk: true, role: .final, text: entry))
      }
      try await eventually("both replies") {
        chat.snapshots[work]?.rows.contains { $0.entryID == "work-reply" } == true
          && chat.snapshots[personal]?.rows.contains { $0.entryID == "personal-reply" } == true
      }
      chat.show(.one(work))
      #expect(chat.rows.map(\.row.text) == ["work-reply"])
      await gate.arm()
      let removal = Task { try await coordinators.remove(coordinators.removal(work)) }
      try await eventually("Remove waiting on Work's alert withdrawal") { await gate.waiting }
      #expect(chat.scope == .all)
      #expect(Set(chat.rows.map(\.row.text)) == ["work-reply", "personal-reply"])
      await gate.open()
      try await removal.value
      #expect(chat.rows.map(\.row.text) == ["personal-reply"])
    }
  }

  /// Old is saved but was never paired, as a profile the single-address build left. Removing it
  /// while its feed is shown shows All, which is Work's conversation, status and model, without
  /// waiting for Work's next event.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func removingTheShownUnpairedCoordinatorShowsTheOthers() async throws {
    let workFixture = FixtureCoordinator()
    await workFixture.replyToHistory(
      initial: NativeEventHistory(
        messages: (0..<3).map {
          HistoryMessage(
            continuation: false, entryId: "work-\($0)", finalChunk: true, role: .final,
            text: "Invented Work reply \($0)")
        }, nextCursor: nil, pageComplete: true), pages: [:])
    let (listener, endpoint) = try await listen(workFixture)
    defer { listener.cancel() }
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "scope-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    var work = CoordinatorProfile(
      name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4001))
    work.pin = workFixture.id
    let old = CoordinatorProfile(
      name: try TagName("Old"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4009))
    try writePrivately(
      JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [work, old])),
      to: root.appending(path: "Agent/profiles.json"))
    let coordinators = Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        guard address.port == 4001 else { throw ConnectionError.timedOut }
        return LineConnection(connection: NWConnection(to: endpoint, using: .tcp))
      })
    await coordinators.setActive(true)
    let chat = coordinators.chat
    try await eventually("Work's first page") {
      chat.snapshots[work.id]?.connection == .connected && chat.rows.count == 3
    }
    chat.show(.one(old.id))
    #expect(chat.rows.isEmpty)
    try await coordinators.remove(coordinators.removal(old.id))
    #expect(chat.scope == .all)
    #expect(chat.rows.map(\.lane) == [work.id, work.id, work.id])
    #expect(chat.connection == .connected && chat.model == "fixture/model")
    await coordinators.setActive(false)
    await workFixture.stop()
  }

  /// The chip's ⓧ does nothing while a Send is admitting, so the draft that went is the one the
  /// completion clears.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func theChipStaysWhileASendIsAdmitting() async throws {
    try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
      let (work, _) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.setChip(work)
      chat.draft = "Invented: the lease renewal"
      await chat.attach(
        data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
      let held = try PipedCopy(replacing: #require(chat.attachments.first).url)
      defer { held.release() }
      let sending = Task { await chat.send() }
      try await held.opened()
      #expect(chat.admitting)
      chat.removeChip()
      #expect(chat.destination == .chip(work), "The chip stays while the Send is admitting")
      held.finish()
      await sending.value
      #expect(chat.draft.isEmpty && chat.attachments.isEmpty && chat.destination == .open)
      try await eventually("Work got it") { await workFixture.count() == 1 }
      #expect(await personalFixture.count() == 0)
    }
  }

  /// A Send to both from All is admitting when the user shows Work, whose recipient line offers
  /// "Address to Work only". Narrowing then changes nothing, so the completion clears the sent
  /// draft, and a second tap once Work is connected again sends Work nothing.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func narrowingWhileASendIsAdmittingNeverSendsItTwice() async throws {
    try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      let text = "Invented: the offsite moves to Thursday"
      chat.draft = text
      await chat.attach(
        data: Data("invented agenda".utf8), name: "Agenda.txt", mediaType: "text/plain")
      let held = try PipedCopy(replacing: #require(chat.attachments.first).url)
      defer { held.release() }
      let sending = Task { await chat.send() }
      try await held.opened()
      chat.show(.one(work))
      #expect(chat.admitting)
      #expect(chat.addressing == .elsewhere([work, personal], narrows: true))
      chat.setChip(work)
      #expect(chat.destination == .open, "The draft keeps its address while the Send is admitting")
      // Work's copy holds the pipe open, so Personal's copy, which starts after it, gets its own.
      try FileManager.default.removeItem(at: held.url)
      try #require(mkfifo(held.url.path, 0o600) == 0)
      held.finish()
      // Personal's copy reads the file again.
      try await held.opened()
      held.finish()
      await sending.value
      #expect(chat.draft.isEmpty && chat.attachments.isEmpty && chat.destination == .open)
      try await eventually("each got it, and Work is connected again") {
        let (atWork, atPersonal) = (await submitted(workFixture), await submitted(personalFixture))
        return atWork == [text] && atPersonal == [text]
          && chat.snapshots[work]?.connection == .connected
      }
      await chat.send()
      try await Task.sleep(for: .seconds(1))
      #expect(await submitted(workFixture) == [text], "Work gets the message once")
    }
  }

  /// A Send from All that no outbox takes brings its text back as the draft it was. Showing Work
  /// meanwhile does not begin it there, so it is still for both and Work's feed only refuses it.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRefusedSendReturnsItsTextUnstampedAfterASwitch() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = ChatModel(admit: { _ in false })
    let (work, personal) = try standIns(chat, in: root)
    let text = "Invented note for both"
    chat.draft = text
    let sending = try #require(chat.startSend())
    chat.show(.one(work))
    await sending.value
    #expect(chat.draft == text && chat.destination == .open)
    #expect(chat.addressing == .elsewhere([work, personal], narrows: true))
  }

  /// Text typed and deleted while a Send is admitting leaves the composer empty, so the stamp of
  /// the draft that went ends with the Send and the next draft begins where it is typed.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aComposerEmptiedWhileASendIsAdmittingKeepsNoStamp() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let typing = TypingDuringAdmission()
    let chat = ChatModel(admit: { _ in
      typing.edit()
      return true
    })
    let (work, personal) = try standIns(chat, in: root)
    typing.edit = {
      chat.draft = "Invented second thought"
      chat.draft = ""
    }
    chat.show(.one(work))
    chat.draft = "Invented note for Work"
    #expect(chat.destination == .begunIn(work))
    await chat.send()
    #expect(chat.draft.isEmpty && chat.destination == .open)
    chat.show(.one(personal))
    chat.draft = "Invented note for Personal"
    #expect(chat.destination == .begunIn(personal))
  }
}
