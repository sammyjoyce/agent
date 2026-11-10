import Foundation
import Testing

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
}
