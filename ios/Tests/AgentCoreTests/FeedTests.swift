import CryptoKit
import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

@Test func addressingNamesTheRecipientsOrWhySendIsBlocked() {
  let work = ProfileID()
  let work1 = ProfileID()
  let personal = ProfileID()
  func saved(_ id: ProfileID, _ name: String, paired: Bool = true, connected: Bool = true)
    -> Addressing.Coordinator
  {
    .init(id: id, name: name, paired: paired, connected: connected)
  }
  let three = [saved(work, "Work"), saved(work1, "Work-1"), saved(personal, "Personal")]
  let pair = [saved(work, "Work"), saved(personal, "Personal")]
  let all = [work, work1, personal]
  let cases:
    [(
      draft: String, files: Bool, chip: ProfileID?, saved: [Addressing.Coordinator],
      expected: Addressing
    )] = [
      ("Ship it", false, nil, three, .to(all, body: "Ship it")),
      ("@Work ship it", false, nil, three, .to([work], body: "ship it")),
      ("@work ship it", false, nil, three, .to([work], body: "ship it")),
      ("@Work-1 ship it", false, nil, three, .to([work1], body: "ship it")),
      ("@Work @Work ship it", false, nil, three, .to([work], body: "ship it")),
      ("@Personal @Work ship it", false, nil, three, .to([work, personal], body: "ship it")),
      ("@Wrok ship it", false, nil, three, .blocked("No coordinator named Wrok")),
      ("@per", false, nil, three, .blocked("Choose a coordinator")),
      ("@Per ", false, nil, three, .blocked("No coordinator named Per")),
      ("@Xyz", false, nil, three, .blocked("No coordinator named Xyz")),
      ("@Work, ship it", false, nil, three, .blocked("No coordinator named Work,")),
      ("@ ship it", false, nil, three, .blocked("Choose a coordinator")),
      ("", false, nil, three, .empty(all)),
      (" \n", false, nil, three, .empty(all)),
      ("", true, nil, three, .to(all, body: "")),
      ("@Work", true, nil, three, .to([work], body: "")),
      ("@Work", false, nil, three, .empty([work])),
      (
        "@Personal check the invented report", false, work, pair,
        .to([work], body: "@Personal check the invented report")
      ),
      ("@Wrok", false, work, pair, .to([work], body: "@Wrok")),
      (
        "@WORK hi", false, nil, [saved(work, "Work"), saved(work1, "work")],
        .blocked("More than one coordinator is named WORK")
      ),
      (
        "@Personal hi", false, nil,
        [saved(work, "Work"), saved(personal, "Personal", paired: false)],
        .blocked("Personal is not paired yet")
      ),
      (
        "hi", false, personal, [saved(work, "Work"), saved(personal, "Personal", paired: false)],
        .blocked("Personal is not paired yet")
      ),
      (
        "hi", false, nil, [saved(work, "Work"), saved(personal, "Personal", paired: false)],
        .to([work], body: "hi")
      ),
      (
        "hi", false, nil,
        [saved(work, "Work", paired: false), saved(personal, "Personal", paired: false)],
        .blocked("No coordinator is paired yet")
      ),
      (
        "hi", false, nil, [saved(work, "Work"), saved(personal, "Personal", connected: false)],
        .blocked("Personal is not connected")
      ),
      (
        "@Work hi", false, nil,
        [saved(work, "Work"), saved(personal, "Personal", connected: false)],
        .to([work], body: "hi")
      ),
      (
        "hi", false, nil,
        [saved(work, "Work", connected: false), saved(personal, "Personal", connected: false)],
        .blocked("Work and Personal are not connected")
      ),
      ("@Wrok hi", false, nil, [saved(work, "Work")], .to([work], body: "@Wrok hi")),
      ("@Work hi", false, work, [saved(work, "Work")], .to([work], body: "@Work hi")),
      (
        "@Work hi", false, personal, [saved(work, "Work")],
        .blocked("Choose who receives this message")
      ),
      ("hi", false, nil, [], .blocked("No coordinator is paired yet")),
    ]
  for item in cases {
    #expect(
      Addressing.parse(
        item.draft, hasAttachments: item.files,
        destination: item.chip.map(DraftDestination.chip) ?? .open, among: item.saved)
        == item.expected, "\(item.draft.debugDescription) with \(item.saved.map(\.name))")
  }
  // Personal was removed. A coordinator added again under its name is a new one.
  let readded = ProfileID()
  let removedCases:
    [(draft: String, chip: ProfileID?, saved: [Addressing.Coordinator], expected: Addressing)] = [
      ("hi", personal, [saved(work, "Work")], .blocked("Personal was removed")),
      (
        "hi", personal, [saved(work, "Work"), saved(work1, "Work-1")],
        .blocked("Personal was removed")
      ),
      ("@Personal hi", nil, [saved(work, "Work")], .blocked("No coordinator named Personal")),
      (
        "@Work @personal hi", nil, [saved(work, "Work"), saved(work1, "Work-1")],
        .blocked("No coordinator named personal")
      ),
      ("@Job hi", nil, [saved(work, "Work")], .blocked("No coordinator named Job")),
      ("@Work hi", nil, [saved(work, "Work")], .to([work], body: "hi")),
      ("hi", nil, [saved(work, "Work")], .to([work], body: "hi")),
      ("@Personal hi", work, [saved(work, "Work")], .to([work], body: "@Personal hi")),
      ("hi @Personal", nil, [saved(work, "Work")], .to([work], body: "hi @Personal")),
      (
        "@Personal hi", nil, [saved(work, "Work"), saved(readded, "Personal")],
        .to([readded], body: "hi")
      ),
    ]
  for item in removedCases {
    #expect(
      Addressing.parse(
        item.draft, hasAttachments: false,
        destination: item.chip.map(DraftDestination.chip) ?? .open, among: item.saved,
        removed: [personal: "Personal"]) == item.expected,
      "\(item.draft.debugDescription) with \(item.saved.map(\.name))")
  }
}

/// A draft begun in one coordinator's conversation goes there unless its chip or tags say
/// otherwise, and is read over every saved coordinator whatever the feed shows.
@Test func theBeginStampIsReadAfterTheChipAndTagsAndBeforeEveryPairedCoordinator() {
  let work = ProfileID()
  let personal = ProfileID()
  let home = ProfileID()
  func saved(_ id: ProfileID, _ name: String, paired: Bool = true, connected: Bool = true)
    -> Addressing.Coordinator
  {
    .init(id: id, name: name, paired: paired, connected: connected)
  }
  let pair = [saved(work, "Work"), saved(personal, "Personal")]
  let left = [saved(personal, "Personal")]
  let cases:
    [(
      draft: String, destination: DraftDestination, literal: Bool,
      saved: [Addressing.Coordinator], removed: [ProfileID: String], expected: Addressing
    )] = [
      ("@Personal hi", .chip(work), false, pair, [:], .to([work], body: "@Personal hi")),
      ("@Personal hi", .begunIn(work), false, pair, [:], .to([personal], body: "hi")),
      ("@Wrok hi", .begunIn(work), false, pair, [:], .blocked("No coordinator named Wrok")),
      ("hi", .begunIn(work), false, pair, [:], .to([work], body: "hi")),
      ("", .begunIn(personal), false, pair, [:], .empty([personal])),
      ("hi", .open, false, pair, [:], .to([work, personal], body: "hi")),
      ("@Personal hi", .open, true, pair, [:], .to([work, personal], body: "@Personal hi")),
      ("hi", .begunIn(work), false, left, [work: "Work"], .blocked("Work was removed")),
      ("@Personal hi", .begunIn(work), false, left, [work: "Work"], .to([personal], body: "hi")),
      ("hi", .begunIn(home), false, pair, [:], .blocked("Choose who receives this message")),
      (
        "hi", .begunIn(work), false,
        [saved(work, "Work", paired: false), saved(personal, "Personal")],
        [:], .blocked("Work is not paired yet")
      ),
      (
        "hi", .begunIn(work), false,
        [saved(work, "Work", connected: false), saved(personal, "Personal")], [:],
        .blocked("Work is not connected")
      ),
      (
        "@Personal hi", .begunIn(work), false, [saved(work, "Work")], [:],
        .to([work], body: "@Personal hi")
      ),
    ]
  for item in cases {
    #expect(
      Addressing.parse(
        item.draft, hasAttachments: false, destination: item.destination, literal: item.literal,
        among: item.saved, removed: item.removed) == item.expected,
      "\(item.draft.debugDescription) \(item.destination) with \(item.saved.map(\.name))")
  }
}

/// The scope shown can only refuse a draft. It passes the draft as parsed or names where it
/// would go, and never changes who gets it.
@Test func aScopeOnlyVetoesAndNeverChangesTheRecipients() throws {
  let work = ProfileID()
  let personal = ProfileID()
  let home = ProfileID()
  let recipients = [[], [work], [personal], [work, personal], [personal, work], [work, home]]
  let values =
    recipients.flatMap { ids -> [Addressing] in
      [.to(ids, body: "hi"), .empty(ids), .elsewhere(ids, narrows: false)]
    } + [.blocked("Work was removed")]
  for value in values {
    for scope in [FeedScope.all, .one(work), .one(personal), .one(home)] {
      for unbound in [false, true] {
        let gated = value.gated(by: scope, unbound: unbound)
        let label = "\(value) in \(scope), unbound \(unbound)"
        switch (value, gated) {
        case (.to(let ids, _), .elsewhere(let named, let narrows)),
          (.empty(let ids), .elsewhere(let named, let narrows)):
          let shown = try #require(scope.coordinator, "\(label): All refused a draft")
          #expect(ids != [shown] && named == ids, "\(label)")
          #expect(narrows == (unbound && ids.contains(shown)), "\(label)")
        case (.to(let ids, _), .to), (.empty(let ids), .empty):
          #expect(gated == value, "\(label)")
          #expect(scope.coordinator.map { ids == [$0] } ?? true, "\(label) passed")
        default:
          #expect(gated == value, "\(label) became \(gated)")
        }
      }
    }
  }
}

private func row(
  _ id: String, _ role: HistoryRole = .final, at seconds: TimeInterval, send: String? = nil,
  delivery: Delivery? = nil, input: String? = nil
) -> ChatRow {
  var row = ChatRow(id: id, role: role, text: id, delivery: delivery, inputID: input)
  row.receivedAt = Date(timeIntervalSince1970: seconds)
  row.sendID = send
  return row
}

@Test func theFeedOrdersByReceiveTimeAndFoldsEachSendWithEveryRecipientsStatus() {
  let work = ProfileID()
  let personal = ProfileID()
  var fromWork = ChatSnapshot()
  fromWork.rows = [
    row("entry:w1:0", at: 1),
    row("input:wa", .user, at: 3, send: "A", input: "wa"),
    row("entry:w2:0", at: 4),
    row("input:wb", .user, at: 5, send: "B", input: "wb"),
    row("entry:w3:0", at: 7),
    row("entry:w3:1", at: 7),
    row("input:wd", .user, at: 9, send: "D", input: "wd"),
  ]
  fromWork.sends = [
    "A": .init(recipients: [work], progress: .placed),
    "B": .init(recipients: [work, personal], progress: .placed),
    "D": .init(recipients: [work, personal], progress: .placed),
  ]
  var fromPersonal = ChatSnapshot()
  fromPersonal.rows = [
    row("entry:p1:0", at: 2),
    row("input:pb", .user, at: 5.001, send: "B", delivery: .uncertain, input: "pb"),
    row("entry:p2:0", at: 7),
    row("input:pc", .user, at: 8, send: "C", input: "pc"),
  ]
  // D's row left Personal's window. Its record still reports it.
  fromPersonal.sends = [
    "B": .init(recipients: [work, personal], progress: .pending(.uncertain)),
    "C": .init(recipients: [work, personal], progress: .placed),
    "D": .init(recipients: [work, personal], progress: .placed),
  ]
  let feed = Feed.merge([(work, fromWork), (personal, fromPersonal)])
  #expect(
    feed.map(\.id) == [
      "\(work)/entry:w1:0", "\(personal)/entry:p1:0", "send:A", "\(work)/entry:w2:0", "send:B",
      "\(work)/entry:w3:0", "\(work)/entry:w3:1", "\(personal)/entry:p2:0", "send:C", "send:D",
    ])
  let receipts = Dictionary(uniqueKeysWithValues: feed.map { ($0.id, $0.receipts) })
  #expect(receipts["send:A"] == [Receipt(lane: work, status: .placed)])
  #expect(
    receipts["send:B"] == [
      Receipt(lane: work, status: .placed),
      Receipt(lane: personal, status: .pending(.uncertain, inputID: "pb")),
    ])
  #expect(
    receipts["send:C"] == [
      Receipt(lane: work, status: .unknown), Receipt(lane: personal, status: .placed),
    ])
  #expect(
    receipts["send:D"] == [
      Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .placed),
    ])
  #expect(feed.first { $0.id == "send:B" }?.lane == work, "A Send shows at its first row")
  #expect(feed.first { $0.id == "send:C" }?.lane == personal)
  #expect(
    feed.filter { $0.lane == personal }.map(\.row.id) == ["entry:p1:0", "entry:p2:0", "input:pc"])
}

/// A recipient with no record of a Send is unknown however old or new the Send is, and so is a
/// recipient no longer saved. Only a record that its item was withdrawn reads as not sent.
@Test func aRecipientReadsNotSentOnlyFromARecordThatItsItemWasWithdrawn() {
  let work = ProfileID()
  let personal = ProfileID()
  let removed = ProfileID()
  var fromWork = ChatSnapshot()
  fromWork.rows = [
    row("input:old", .user, at: 1, send: "old", input: "old"),
    row("input:new", .user, at: 3, send: "new", input: "new"),
    row("input:gone", .user, at: 4, send: "gone", input: "gone"),
    row("input:back", .user, at: 5, send: "back", input: "back"),
  ]
  fromWork.sends = [
    "old": .init(recipients: [work, personal], progress: .placed),
    "new": .init(recipients: [work, personal], progress: .placed),
    "gone": .init(recipients: [work, removed], progress: .placed),
    "back": .init(recipients: [work, personal], progress: .placed),
  ]
  var fromPersonal = ChatSnapshot()
  fromPersonal.sends = ["back": .init(recipients: [work, personal], progress: .withdrawn)]
  let feed = Feed.merge([(work, fromWork), (personal, fromPersonal)])
  let receipts = Dictionary(uniqueKeysWithValues: feed.map { ($0.id, $0.receipts) })
  let placed = Receipt(lane: work, status: .placed)
  #expect(receipts["send:old"] == [placed, Receipt(lane: personal, status: .unknown)])
  #expect(receipts["send:new"] == [placed, Receipt(lane: personal, status: .unknown)])
  #expect(receipts["send:gone"] == [placed, Receipt(lane: removed, status: .unknown)])
  #expect(receipts["send:back"] == [placed, Receipt(lane: personal, status: .notSent)])
  let names = ["Work", "Personal"]
  #expect(Receipt.summary([placed, placed], names: names) == "To Work and Personal")
  for status in [Receipt.Status.unknown, .notSent, .pending(.uncertain, inputID: "p")] {
    #expect(
      Receipt.summary([placed, Receipt(lane: personal, status: status)], names: names) == nil)
  }
  #expect(Receipt(lane: personal, status: .notSent).line("Personal") == "Not sent to Personal")
  #expect(Receipt(lane: personal, status: .unknown).line("Personal") == "Personal · Status unknown")
  #expect(placed.line("Work") == "Work · Delivered")
}

/// Each recipient's line carries the processing state its own coordinator reported for its copy.
@Test func eachRecipientsReceiptShowsTheWorkItsCoordinatorReported() {
  let work = ProfileID()
  let personal = ProfileID()
  var fromWork = ChatSnapshot()
  var workCopy = row("input:w", .user, at: 1, send: "S", delivery: .saved, input: "w")
  workCopy.work = .running
  fromWork.rows = [workCopy]
  fromWork.sends = ["S": .init(recipients: [work, personal], progress: .pending(.saved))]
  var fromPersonal = ChatSnapshot()
  var personalCopy = row("input:p", .user, at: 2, send: "S", delivery: .saved, input: "p")
  personalCopy.work = .blocked(.init(reason: .restartLimit))
  fromPersonal.rows = [personalCopy]
  fromPersonal.sends = ["S": .init(recipients: [work, personal], progress: .pending(.saved))]
  let feed = Feed.merge([(work, fromWork), (personal, fromPersonal)])
  #expect(feed.map(\.id) == ["send:S"])
  #expect(
    feed.first?.receipts == [
      Receipt(lane: work, status: .pending(.saved, inputID: "w"), work: .running),
      Receipt(
        lane: personal, status: .pending(.saved, inputID: "p"),
        work: .blocked(.init(reason: .restartLimit))),
    ])
}

/// Two coordinators can watch the same account. Each one's checks and warning stay its own, in
/// lane order, and one recovering clears only its own warning.
@MainActor @Test func eachCoordinatorsSourceChecksStayItsOwn() {
  let (work, workRoot) = temporaryProfile()
  let (personal, personalRoot) = temporaryProfile()
  defer { for root in [workRoot, personalRoot] { try? FileManager.default.removeItem(at: root) } }
  let model = ChatModel()
  for directory in [work, personal] {
    model.attach(Lane(id: directory.profile, session: nil))
  }
  let mail = SourceKey(account: "mail-primary", provider: "google")
  func checks(_ coverage: SourceCoverage, _ warning: String?) -> ChatSnapshot {
    var snapshot = ChatSnapshot()
    snapshot.sources = [.init(checkedAt: 1, checkpoint: nil, coverage: coverage, source: mail)]
    snapshot.sourceWarning = warning
    return snapshot
  }
  let failing = checks(
    .unavailable(.init(message: "Provider read failed")),
    "Source checks incomplete: Gmail unavailable")
  model.apply(failing, lane: personal.profile)
  model.apply(checks(.complete, nil), lane: work.profile)
  #expect(model.sourceReports.map(\.id) == [work.profile, personal.profile])
  #expect(
    model.sourceReports.map(\.warning) == [nil, "Source checks incomplete: Gmail unavailable"])
  #expect(model.sourceReports.map(\.states) == [checks(.complete, nil).sources, failing.sources])
  model.apply(checks(.complete, nil), lane: personal.profile)
  #expect(model.sourceReports.map(\.warning) == [nil, nil])
}

@MainActor @Test func activityGroupsNeverSpanTwoCoordinatorsAndEachRunIsNamed() {
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
  fromWork.rows = [tool("tool:w1", at: 1), tool("tool:w2", at: 2), row("entry:w3:0", at: 5)]
  var fromPersonal = ChatSnapshot()
  fromPersonal.rows = [
    tool("tool:p1", at: 3), row("entry:p2:0", at: 4), row("input:p", .user, at: 6),
    row("entry:p3:0", at: 7),
  ]
  let items = TranscriptItem.grouped(
    Feed.merge([(work, fromWork), (personal, fromPersonal)]).map(RowModel.init))
  #expect(items.map(\.lane) == [work, personal, personal, work, personal, personal])
  guard case .activity(let first) = items[0], case .activity(let second) = items[1] else {
    Issue.record("Expected one activity group per coordinator")
    return
  }
  #expect(first.rows.map(\.row.id) == ["tool:w1", "tool:w2"])
  #expect(second.rows.map(\.row.id) == ["tool:p1"])
  #expect(
    TranscriptItem.runStarts(items)
      == [items[0].id, items[1].id, items[3].id, items[5].id],
    "Each coordinator is named where its run starts, and again after your message")
}

/// Holds the next dial to Work's port once armed, as a slow tailnet would.
actor DialGate {
  private var armed = false
  private(set) var waiting = false
  private var release: CheckedContinuation<Void, Never>?
  func arm() { armed = true }
  func pass() async {
    guard armed else { return }
    armed = false
    waiting = true
    await withCheckedContinuation { release = $0 }
  }
  func open() {
    armed = false
    release?.resume()
    release = nil
  }
}

/// Where Work's addresses lead. A test can point them at Personal, as a moved name would, swap
/// Work's and Personal's, as when the two coordinators trade ports, or leave Personal's address
/// answering nothing.
actor WorkRoute {
  private(set) var answersAsPersonal = false
  private(set) var swapped = false
  private(set) var personalsAddressDown = false
  func point(atPersonal value: Bool) { answersAsPersonal = value }
  func swap() { swapped = true }
  func takePersonalsAddressDown(_ value: Bool) { personalsAddressDown = value }
}

/// Two loopback coordinators, Personal at port 4002 of an invented address and Work at any
/// other address, and a fresh `Coordinators` with nothing saved, as the app builds it.
@MainActor func withTwoFixtures(
  registration: NotificationRegistration? = nil, holdingWork gate: DialGate? = nil,
  route: WorkRoute? = nil,
  _ body: (Coordinators, FixtureCoordinator, FixtureCoordinator, URL) async throws -> Void
) async throws {
  let first = FixtureCoordinator()
  let second = FixtureCoordinator()
  let (firstListener, firstPort) = try await listen(first)
  defer { firstListener.cancel() }
  let (secondListener, secondPort) = try await listen(second)
  defer { secondListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "feed-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: registration, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      if address.port == 4001 { await gate?.pass() }
      if address.port == 4002, await route?.personalsAddressDown == true {
        throw ConnectionError.timedOut
      }
      let repointed = await route?.answersAsPersonal == true
      let swapped = await route?.swapped == true
      let personal = (address.port == 4002) != swapped || repointed
      return LineConnection(
        connection: NWConnection(to: personal ? secondPort : firstPort, using: .tcp))
    })
  await coordinators.setActive(true)
  do {
    try await body(coordinators, first, second, root)
  } catch {
    await gate?.open()
    await coordinators.setActive(false)
    await first.stop()
    await second.stop()
    throw error
  }
  await gate?.open()
  await coordinators.setActive(false)
  await first.stop()
  await second.stop()
}

/// How long a wait across a lane's reconnect may take. A session whose dial fails backs off up to
/// 32 s before it dials again.
private let reconnecting = Duration.seconds(45)

@MainActor private func eventually(
  _ description: String, within limit: Duration = .seconds(15), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor func addWorkAndPersonal(_ coordinators: Coordinators) async throws -> (
  work: ProfileID, personal: ProfileID
) {
  try await coordinators.add(
    name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
  try await coordinators.add(
    name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  let chat = coordinators.chat
  try await eventually("both connected") {
    chat.snapshots.values.filter { $0.connection == .connected }.count == 2
  }
  return (coordinators.profiles[0].id, coordinators.profiles[1].id)
}

private func submits(_ fixture: FixtureCoordinator) async -> [NativeRequestSubmit] {
  await fixture.received().compactMap { if case .submit(let input) = $0 { input } else { nil } }
}

private func observes(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .observe = $0 { true } else { false } }.count
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSecondCoordinatorIsAddedOnceUnderItsOwnName() async throws {
  try await withTwoFixtures { coordinators, first, _, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    #expect(coordinators.chat.lanes.map(\.id) == [work, personal])
    #expect(coordinators.chat.multiple)
    await #expect(throws: ProfileError.duplicateName("Work")) {
      try await coordinators.add(
        name: TagName("work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    }
    await #expect(throws: ProfileError.duplicateCoordinator(savedAs: "Work")) {
      try await coordinators.add(
        name: TagName("Again"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    }
    #expect(coordinators.profiles.map(\.id) == [work, personal])
    #expect(await first.received().filter { $0 == .identify }.count >= 2, "Add probes first")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anUntaggedSendReachesBothCoordinatorsAndATaggedOneOnlyItsOwn() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let broadcast = "Flying to Lisbon, offline until 6"
    chat.draft = broadcast
    #expect(chat.recipientLine == "To Work and Personal")
    await chat.send()
    try await eventually("one submit at each coordinator") {
      (await workFixture.count(), await personalFixture.count()) == (1, 1)
    }
    let toWork = await submits(workFixture)
    let toPersonal = await submits(personalFixture)
    #expect(toWork.map(\.text) == [broadcast] && toPersonal.map(\.text) == [broadcast])
    #expect(toWork.first?.inputId != toPersonal.first?.inputId, "Each has its own input ID")
    try await eventually("one folded row") {
      chat.rows.filter { $0.row.role == .user }.count == 1
        && chat.rows.first { $0.row.role == .user }?.receipts.count == 2
    }
    let folded = try #require(chat.rows.first { $0.row.role == .user })
    #expect(folded.id.hasPrefix("send:"))
    #expect(folded.receipts.map(\.lane) == [work, personal])
    // The fixture closes each submit's socket after `accepted`, so both lanes reconnect after a
    // backoff, and only that observe reports `placed`.
    try await eventually("both placed it and reconnected") {
      chat.rows.first { $0.row.role == .user }?.receipts
        == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .placed)]
        && chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }

    chat.draft = "@Work "
    chat.promoteTypedTag()
    #expect(chat.destination.chip == work && chat.draft.isEmpty, "A typed tag becomes the chip")
    chat.draft = "@Personal rotate the staging deploy key"
    chat.promoteTypedTag()
    #expect(chat.recipientLine == "To Work", "Text after the chip is never routed")
    await chat.send()
    #expect(chat.destination.chip == nil && chat.draft.isEmpty)
    try await eventually("Work's second submit") { await workFixture.count() == 2 }
    #expect(
      await submits(workFixture).map(\.text) == [
        broadcast, "@Personal rotate the staging deploy key",
      ])
    let personalOutbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    let queuedForPersonal = (try? queuedRequests(personalOutbox)) ?? []
    #expect(!queuedForPersonal.contains { $0.text.contains("rotate") }, "Never staged for Personal")
    #expect(await submits(personalFixture).map(\.text) == [broadcast])
  }
}

/// A Send to both keeps the composer's receipt in the first recipient's outbox alone, under that
/// copy's input ID. The other copy has its own ID and no receipt.
@MainActor @Test(.timeLimit(.minutes(1)))
func aSendToBothKeepsItsComposerReceiptWithTheFirstRecipientAlone() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    await workFixture.holdPlacements()
    await personalFixture.holdPlacements()
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.draft = "Invented: the venue moved to Friday"
    await chat.send()
    #expect(chat.draft.isEmpty)
    struct WithReceipts: Decodable {
      let pending: [OutboxItem]
      let composerInputs: [String: String]
    }
    func outbox(_ id: ProfileID) throws -> Data {
      try Data(contentsOf: ProfileDirectory(id, applicationSupport: root, caches: root).outbox)
    }
    let atWork = try JSONDecoder().decode(WithReceipts.self, from: outbox(work))
    #expect(atWork.pending.count == 1)
    #expect(Array(atWork.composerInputs.values) == atWork.pending.map(\.request.inputId))
    let atPersonal = try JSONDecoder().decode([OutboxItem].self, from: outbox(personal))
    #expect(atPersonal.count == 1, "No receipt, so Personal's outbox stays a bare array")
    #expect(atPersonal.first?.request.inputId != atWork.pending.first?.request.inputId)
    #expect(atPersonal.first?.sendID == atWork.pending.first?.sendID)
  }
}

/// With one coordinator saved and none removed, a typed `@Work ` is text, as on `main`. With one
/// left after a removal, the composer names recipients, as with two. Typing `@W` offers Work, and
/// `@Work ` becomes the chip, so the draft shows what Send delivers.
@MainActor @Test(.timeLimit(.minutes(1)))
func aTypedTagAfterARemovalBecomesTheChip() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, _ in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    chat.draft = "@W"
    #expect(chat.pickerMatches.isEmpty, "With one coordinator saved nothing is offered")
    chat.draft = "@Work "
    chat.promoteTypedTag()
    #expect(chat.destination.chip == nil && chat.draft == "@Work ", "The tag stays text")
    chat.draft = ""
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await coordinators.remove(
      coordinators.removal(try #require(coordinators.profiles.last?.id)))
    chat.draft = "@W"
    print("IF6-T4 picker for @W: \(chat.pickerMatches.map(\.name.description))")
    #expect(chat.pickerMatches.map(\.id) == [work], "Typing @W offers Work")
    chat.draft = "@Work "
    chat.promoteTypedTag()
    print(
      "IF6-T4 after @Work: recipient=\(chat.destination.chip.map(chat.name) ?? "none") draft=\(chat.draft.debugDescription) line=\(chat.recipientLine)"
    )
    #expect(chat.destination.chip == work, "The typed tag did not become the chip")
    #expect(chat.draft.isEmpty)
    #expect(chat.shownChip == work && chat.recipientLine == "To Work")
    chat.draft = "Invented: the venue is booked"
    await chat.send()
    try await eventually("Work got it") { await workFixture.count() == 1 }
    #expect(await submits(workFixture).map(\.text) == ["Invented: the venue is booked"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aFeedbackToBothStaysOneBubbleWithEachRecipientsStatusOnceSettled() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.draft = "/feedback The invented text is clipped"
    await chat.send()
    try await eventually("both settled") {
      (await workFixture.count(), await personalFixture.count()) == (1, 1)
        && chat.snapshots.values.allSatisfy {
          $0.sends.count == 1 && $0.sends.values.allSatisfy { $0.progress == .placed }
        }
    }
    let users = chat.rows.filter { $0.row.role == .user }
    #expect(users.count == 1)
    #expect(
      users.first?.receipts
        == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .placed)])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aRefusedStageLeavesNothingQueuedAnywhereAndKeepsTheDraft() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let workOutbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    try await withReadOnlyProfile(
      ProfileDirectory(personal, applicationSupport: root, caches: root)
    ) {
      chat.draft = "Both or neither"
      await chat.send()
    }
    #expect(chat.draft == "Both or neither")
    #expect(chat.error == "Nothing was sent. Personal did not take the message.")
    #expect(try queuedRequests(workOutbox).isEmpty, "Work's staged item was withdrawn")
    #expect((await workFixture.count(), await personalFixture.count()) == (0, 0))
    try await eventually("Personal's own reason") { chat.snapshots[personal]?.error != nil }
    #expect(!chat.rows.contains { $0.row.role == .user })
    await chat.send()
    try await eventually("the kept draft sent to both") {
      (await workFixture.count(), await personalFixture.count()) == (1, 1)
    }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func restoreAddressesTheSourceCoordinatorAndKeepsItsTextLiteral() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    await personalFixture.refuseUploads()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    chat.setChip(personal)
    chat.draft = "@Work check the invented report"
    await chat.attach(data: Data("bytes".utf8), name: "Notes.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected by Personal") {
      chat.snapshots[personal]?.rows.contains { $0.delivery == .rejected } == true
    }
    let original = try #require(try queuedRequests(outbox).first)
    #expect(
      chat.rows.first { $0.row.role == .user }?.receipts
        == [Receipt(lane: personal, status: .pending(.rejected, inputID: original.inputId))])
    await chat.restore(original.inputId)
    #expect(chat.destination.chip == personal)
    #expect(chat.draft == "@Work check the invented report")
    #expect(chat.recipientLine == "To Personal")
    #expect(try queuedRequests(outbox) == [original], "Restore copies")
    await chat.send()
    let after = try queuedRequests(outbox)
    #expect(after.count == 1 && after.first?.inputId != original.inputId)
    #expect(after.first?.text == "@Work check the invented report")
    #expect(await workFixture.count() == 0)
    #expect(await workFixture.received().allSatisfy { !"\($0)".contains("invented report") })
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removeRefusesWhileTheDraftIsAddressedToOrRestoredFromThatCoordinator() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let workOutbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    chat.setChip(work)
    chat.draft = "Invented Q3 numbers for the Work board"
    await chat.attach(data: Data("bytes".utf8), name: "Payroll.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let original = try #require(try queuedRequests(workOutbox).first)
    await chat.restore(original.inputId)
    #expect(chat.recipientLine == "To Work")
    for chip in [work, nil] {
      if let chip { chat.setChip(chip) } else { chat.removeChip() }
      do {
        try await coordinators.remove(coordinators.removal(work))
        Issue.record("Remove went ahead with a draft from Work, chip \(String(describing: chip))")
      } catch {
        #expect(error.localizedDescription == "Send or clear the draft for Work first.")
      }
      #expect(coordinators.profiles.map(\.id) == [work, personal])
    }
    chat.draft = ""
    for file in chat.attachments { await chat.removeAttachment(file) }
    try await coordinators.remove(coordinators.removal(work))
    #expect(coordinators.profiles.map(\.id) == [personal], "A cleared draft lets Remove go ahead")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aScreenshotKeptFromOneCoordinatorIsRefusedOnceASecondIsSaved() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let chat = coordinators.chat
    let work = try #require(coordinators.profiles.first?.id)
    try await eventually("Work connected") { chat.connection == .connected }
    var captures = 0
    try await withReadOnlyProfile(ProfileDirectory(work, applicationSupport: root, caches: root)) {
      chat.draft = "/feedback The text is clipped"
      await chat.send(screenshot: {
        captures += 1
        return Data([1, 2, 3])
      })
    }
    #expect(
      captures == 1
        && chat.attachments.map(\.reference.name) == ["Feedback.png", "Composer.log"])
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await chat.send(screenshot: {
      captures += 1
      return Data([4, 5, 6])
    })
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true)
    #expect(captures == 1)
    #expect((await workFixture.count(), await personalFixture.count()) == (0, 0))
    for file in chat.attachments { await chat.removeAttachment(file) }
    await chat.send(screenshot: {
      captures += 1
      return Data([7, 8, 9])
    })
    #expect(captures == 1, "No automatic screenshot with two coordinators")
    try await eventually("feedback without a screenshot at both") {
      (await workFixture.count(), await personalFixture.count()) == (1, 1)
    }
    #expect(await submits(personalFixture).first?.attachments?.isEmpty == true)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anAutomaticScreenshotNeverGoesToACoordinatorItWasNotCapturedWith() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let chat = coordinators.chat
    let work = try #require(coordinators.profiles.first?.id)
    try await eventually("Work connected") { chat.connection == .connected }
    try await withReadOnlyProfile(ProfileDirectory(work, applicationSupport: root, caches: root)) {
      chat.draft = "/feedback The invented Work reply is clipped"
      await chat.send(screenshot: { Data("Invented Work feed".utf8) })
    }
    let screenshot = try #require(chat.attachments.first)
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await coordinators.remove(coordinators.removal(work))
    try await eventually("Personal connected") { chat.connection == .connected }
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true)
    await chat.removeAttachment(screenshot)
    await chat.send()
    try await eventually("Personal's feedback") { await personalFixture.count() > 0 }
    // The composer's own log holds no message text and shows no feed, so it stays with the draft.
    #expect(
      await submits(personalFixture).map { ($0.attachments ?? []).map(\.name) }
        == [["Composer.log"]])
    #expect(await personalFixture.uploaded(screenshot.id) == nil)
    #expect(await workFixture.count() == 0)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func toolDetailsGoToTheRowsOwnCoordinatorWhenCallIDsCollide() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let details = ToolDetails.unavailable(.init(callId: "shared"))
    for fixture in [workFixture, personalFixture] {
      await fixture.replyToToolLookups(with: [.toolDetails(.init(details: details)), .done])
    }
    let row = ChatRow(
      id: "tool:shared", entryID: "7", role: .tool, text: "",
      tool: .init(callId: "shared", name: "exec", status: .finished))
    #expect(try await coordinators.chat.toolDetails(for: row, lane: personal) == details)
    #expect(await personalFixture.toolLookups() == [.init(callId: "shared", entryId: "7")])
    #expect(await workFixture.toolLookups().isEmpty)
  }
}

/// Remove withdraws Work's alerts over the network before it deletes anything. Meanwhile a
/// second window, or this one after Done, restores, chooses or tags Work. None of that may
/// become a draft that reaches Personal once Work is gone.
@MainActor @Test(.timeLimit(.minutes(1)))
func nothingRestoredChosenOrTaggedDuringRemoveReachesTheOtherCoordinator() async throws {
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {}, save: { _ in })
  let gate = DialGate()
  try await withTwoFixtures(registration: registration, holdingWork: gate) {
    coordinators, workFixture, personalFixture, root in
    await workFixture.refuseUploads()
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    try await eventually("Work's alert channel linked") { registration.status(work).configured }
    let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
    chat.setChip(work)
    chat.draft = "Invented Q3 payroll numbers for the Work board"
    await chat.attach(
      data: Data("invented payroll".utf8), name: "Payroll.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(workDirectory.outbox).first)
    let hold = try heldQueue(
      [NativeRequestSubmit(inputId: "held-1", mode: .steer, text: "Invented Work-only held text")],
      in: root)
    chat.holds.append(hold)
    let held = HeldMessage(
      queue: hold.queue.id, item: try #require(try await hold.store.items().first))

    await gate.arm()
    let removal = Task { try await coordinators.remove(coordinators.removal(work)) }
    try await eventually("Remove waiting on Work's alert withdrawal") { await gate.waiting }
    chat.draft = "@Wo"
    #expect(chat.pickerMatches.isEmpty, "Work is not offered while it is removed")
    chat.choose(work)
    #expect(chat.destination.chip == nil)
    chat.draft = "@Work see the invented payroll"
    chat.promoteTypedTag()
    #expect(!chat.canSend && chat.recipientLine == "Work was removed")
    chat.removeChip()
    chat.draft = ""
    await chat.restoreHeld(held, for: work)
    await chat.restore(queued.inputId)
    #expect(chat.draft.isEmpty && chat.attachments.isEmpty, "Restore refuses while Work is removed")
    await gate.open()
    try await removal.value
    #expect(coordinators.profiles.map(\.id) == [personal])
    await chat.send()
    try await Task.sleep(for: .seconds(1))
    let atPersonal = await submits(personalFixture)
    #expect(atPersonal.isEmpty, "Personal received \(atPersonal.map(\.text))")
  }
}

/// A restore that passed its checks before Remove started fills the composer after Work is
/// marked. Clearing the chip later must not make Work's message sendable to Personal.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageRestoredFromARemovedCoordinatorStaysBlockedUnderAnyAddress() async throws {
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {}, save: { _ in })
  let gate = DialGate()
  try await withTwoFixtures(registration: registration, holdingWork: gate) {
    coordinators, workFixture, personalFixture, root in
    await workFixture.refuseUploads()
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    try await eventually("Work's alert channel linked") { registration.status(work).configured }
    chat.setChip(work)
    chat.draft = "Invented Q3 payroll numbers for the Work board"
    await chat.attach(
      data: Data("invented payroll".utf8), name: "Payroll.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let workOutbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let queued = try #require(try queuedRequests(workOutbox).first)
    await gate.arm()
    // Both start on the main actor in this order, so the restore resumes after Remove's mark.
    let restoring = Task { @MainActor in await chat.restore(queued.inputId) }
    let removal = Task { @MainActor in try await coordinators.remove(coordinators.removal(work)) }
    await restoring.value
    #expect(chat.draft == queued.text && chat.destination.chip == work)
    try await eventually("Remove waiting on Work's alert withdrawal") { await gate.waiting }
    await gate.open()
    try await removal.value
    #expect(coordinators.profiles.map(\.id) == [personal])
    for chip in [work, nil] {
      if let chip { chat.setChip(chip) } else { chat.removeChip() }
      #expect(chat.addressing == .blocked("Work was removed"))
      await chat.send()
    }
    try await Task.sleep(for: .milliseconds(500))
    let atPersonal = await submits(personalFixture)
    #expect(atPersonal.isEmpty, "Personal received \(atPersonal.map(\.text))")
  }
}

/// A typed `@Work` that has not become the chip addresses Work too. Remove refuses it. Once Work
/// is gone, no tag or chip naming Work sends, even with one coordinator left.
@MainActor @Test(.timeLimit(.minutes(1)))
func removeRefusesATypedTagAndNothingNamingARemovedCoordinatorSends() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.draft = "@Work"
    chat.promoteTypedTag()
    await chat.attach(
      data: Data("invented board minutes".utf8), name: "Board-minutes.txt",
      mediaType: "text/plain")
    #expect(chat.destination.chip == nil && chat.recipientLine == "To Work")
    do {
      try await coordinators.remove(coordinators.removal(work))
      Issue.record("Remove went ahead with a draft tagged @Work")
    } catch {
      #expect(error.localizedDescription == "Send or clear the draft for Work first.")
    }
    #expect(coordinators.profiles.map(\.id) == [work, personal])
    chat.draft = ""
    for file in chat.attachments { await chat.removeAttachment(file) }
    try await coordinators.remove(coordinators.removal(work))
    #expect(coordinators.profiles.map(\.id) == [personal])
    let drafts: [(chip: ProfileID?, text: String, blocked: String)] = [
      (nil, "@Work see the invented board minutes", "No coordinator named Work"),
      (work, "Invented board minutes", "Work was removed"),
    ]
    for draft in drafts {
      if let chip = draft.chip { chat.setChip(chip) } else { chat.removeChip() }
      chat.draft = draft.text
      #expect(chat.addressing == .blocked(draft.blocked), "\(draft.text)")
      await chat.send()
      #expect(chat.draft == draft.text, "Send keeps a draft for a removed coordinator")
    }
    try await Task.sleep(for: .milliseconds(500))
    let atPersonal = await submits(personalFixture)
    #expect(atPersonal.isEmpty, "Personal received \(atPersonal.map(\.text))")
  }
}

/// Deleting `/feedback` from the text does not make its automatic screenshot a chosen file. A
/// restore still knows which coordinator's feed it shows.
@MainActor @Test(.timeLimit(.minutes(1)))
func anEditedFeedbackKeepsItsScreenshotWithItsCoordinatorThroughRestore() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let chat = coordinators.chat
    let work = try #require(coordinators.profiles.first?.id)
    try await eventually("Work connected") { chat.connection == .connected }
    let directory = ProfileDirectory(work, applicationSupport: root, caches: root)
    try await withReadOnlyProfile(directory) {
      chat.draft = "/feedback The invented Work feed is clipped"
      await chat.send(screenshot: { Data("Invented private Work screenshot bytes".utf8) })
    }
    #expect(chat.attachments.map(\.reference.name) == ["Feedback.png", "Composer.log"])
    await workFixture.refuseUploads()
    chat.draft = "The invented Work feed is clipped"
    await chat.send()
    try await eventually("the edited message rejected at Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(directory.outbox).first)
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await chat.restore(queued.inputId)
    let restored = try #require(chat.attachments.first)
    chat.removeChip()
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await personalFixture.uploaded(restored.id) == nil)
    #expect(await submits(personalFixture).isEmpty)
  }
}

/// Each coordinator caps its own send records. After 2000 later Sends to Personal alone,
/// Personal's record of an old message to both is gone while Work's stays. Load earlier brings
/// the message back, and nothing may say Personal did not get it.
@Test(.timeLimit(.minutes(1)))
func aRecipientWhoseRecordWasCappedIsNeverShownAsNotSent() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let (workDirectory, workRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: workRoot) }
  let (personalDirectory, personalRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: personalRoot) }
  let work = workDirectory.profile
  let personal = personalDirectory.profile
  let both = [work, personal]
  var workLedger = Ledger()
  workLedger.sends["send-old"] = .init(inputID: "w-old-input", entryID: "w-old", recipients: both)
  workLedger.entries["w-today"] = .init(receivedAt: 5000)
  try writePrivately(JSONEncoder().encode(workLedger), to: workDirectory.ledger)
  var personalLedger = Ledger()
  personalLedger.sends["send-old"] = .init(
    inputID: "p-old-input", entryID: "p-old", recipients: both)
  for index in 0..<2000 {
    personalLedger.entries["p-\(index)"] = .init(
      receivedAt: 200 + Double(index), sendID: "send-p\(index)")
    personalLedger.sends["send-p\(index)"] = .init(
      inputID: "p-input-\(index)", entryID: "p-\(index)", recipients: [personal])
  }
  try writePrivately(JSONEncoder().encode(personalLedger), to: personalDirectory.ledger)
  func reply(_ entry: String, role: HistoryRole = .final, _ text: String) -> HistoryMessage {
    HistoryMessage(continuation: false, entryId: entry, finalChunk: true, role: role, text: text)
  }
  func page(_ messages: [HistoryMessage], next: String?) -> NativeEventHistory {
    .init(messages: messages, nextCursor: next, pageComplete: true)
  }
  await workFixture.replyToHistory(
    initial: page([reply("w-today", "A Work reply")], next: "older"),
    pages: ["older": page([reply("w-old", role: .user, "Flying to Lisbon")], next: nil)])
  await personalFixture.replyToHistory(
    initial: page([reply("p-1999", role: .user, "Tagged 1999")], next: "older"),
    pages: ["older": page([reply("p-old", role: .user, "Flying to Lisbon")], next: nil)])
  func until(
    _ session: CoordinatorSession, _ predicate: @Sendable (ChatSnapshot) -> Bool
  ) async throws -> ChatSnapshot {
    for await snapshot in session.updates where predicate(snapshot) { return snapshot }
    throw ConnectionError.closed
  }
  let stamps = StampSource()
  let workSession = CoordinatorSession(
    directory: workDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: workFixture.id, stamps: stamps, transport: loopback(workPort))
  let personalSession = CoordinatorSession(
    directory: personalDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: personalFixture.id, stamps: stamps, transport: loopback(personalPort))
  await workSession.connect()
  await personalSession.connect()
  _ = try await until(workSession) { $0.connection == .connected }
  _ = try await until(personalSession) { $0.connection == .connected }
  #expect(await personalSession.submit("One more for Personal"))
  _ = try await until(personalSession) { snapshot in
    snapshot.connection == .connected
      && snapshot.sends.values.filter { $0.recipients == [personal] && $0.progress == .placed }
        .count >= 2000
      && snapshot.sends.values.allSatisfy { $0.progress == .placed }
  }
  let saved = try JSONDecoder().decode(
    Ledger.self, from: Data(contentsOf: personalDirectory.ledger))
  #expect(saved.sends["send-old"] == nil, "Personal's cap dropped its record of the old message")
  await workSession.loadEarlier()
  await personalSession.loadEarlier()
  let workSnapshot = try await until(workSession) { $0.rows.contains { $0.entryID == "w-old" } }
  let personalSnapshot = try await until(personalSession) {
    $0.rows.contains { $0.entryID == "p-old" }
  }
  let old = Feed.merge([(work, workSnapshot), (personal, personalSnapshot)]).filter {
    $0.row.text == "Flying to Lisbon"
  }
  // Personal's copy lost its send ID with the record, so the two copies cannot fold.
  #expect(
    old.first { $0.id == "send:send-old" }?.receipts
      == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .unknown)],
    "Personal placed it, so its status is unknown, never not sent")
  #expect(old.allSatisfy { $0.id == "send:send-old" || $0.receipts.isEmpty })
  await workSession.disconnect()
  await personalSession.disconnect()
  await workFixture.stop()
  await personalFixture.stop()
}

/// Removing and adding Personal again gives it a new identity. An earlier message to both must
/// still read as sent to both, never as a tagged `@Work` Send.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageToBothKeepsItsRecipientsAfterOneIsRemovedAndAddedAgain() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    @MainActor func bothConnected() async throws {
      try await eventually("both connected") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    }
    let broadcast = "Flying to Lisbon, offline until 6"
    chat.draft = broadcast
    await chat.send()
    try await eventually("the broadcast placed at both") {
      chat.rows.first { $0.row.text == broadcast }?.receipts
        == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .placed)]
    }
    try await bothConnected()
    let tagged = "Invented note for Work only"
    chat.setChip(work)
    chat.draft = tagged
    await chat.send()
    try await eventually("the tagged Send placed") {
      chat.rows.first { $0.row.text == tagged }?.receipts == [Receipt(lane: work, status: .placed)]
    }
    try await bothConnected()
    try await coordinators.remove(coordinators.removal(personal))
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await bothConnected()
    let broadcastRow = try #require(chat.rows.first { $0.row.text == broadcast })
    let taggedRow = try #require(chat.rows.first { $0.row.text == tagged })
    #expect(
      broadcastRow.receipts
        == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .unknown)],
      "Everyone it was sent to, the removed Personal included")
    #expect(broadcastRow.receipts != taggedRow.receipts)
    #expect(taggedRow.receipts == [Receipt(lane: work, status: .placed)])
  }
}

// MARK: - Profile mutations run one at a time, and Remove commits before it withdraws

/// An address edit swaps Work's session, and Remove starts while the edit retires the old session
/// or connects the new one. Remove waits for the edit, so Work keeps no lane, no row and no
/// directory. Tests run in parallel on the main actor, so an iteration can miss that window and
/// then removes Work after the edit.
@MainActor @Test(.timeLimit(.minutes(2)))
func anEditAndARemoveOfOneCoordinatorRunOneAfterTheOther() async throws {
  var overlapped = 0
  for _ in 0..<20 {
    try await withTwoFixtures { coordinators, workFixture, _, root in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      await workFixture.replyToHistory(
        initial: .init(
          messages: [
            .init(
              continuation: false, entryId: "work-entry", finalChunk: true, role: .final,
              text: "Invented private Work-only reply")
          ], pageComplete: true), pages: [:])
      var editFinished = false
      let editing = Task { @MainActor in
        defer { editFinished = true }
        try await coordinators.update(
          work, name: TagName("Office"), address: CoordinatorAddress(host: "100.64.1.3", port: 4001)
        )
      }
      let original = chat.lanes.first { $0.id == work }?.session
      while !editFinished, chat.snapshots[work]?.connection == .connected,
        chat.lanes.first(where: { $0.id == work })?.session === original
      { await Task.yield() }
      if !editFinished { overlapped += 1 }
      try await coordinators.remove(coordinators.removal(work))
      try await editing.value
      try await Task.sleep(for: .milliseconds(150))
      let directory = ProfileDirectory(work, applicationSupport: root, caches: root)
      #expect(coordinators.profiles.map(\.id) == [personal])
      #expect(chat.lanes.map(\.id) == [personal], "A removed coordinator has no lane")
      #expect(!chat.rows.contains { $0.lane == work }, "No row of the removed coordinator shows")
      #expect(!FileManager.default.fileExists(atPath: directory.ledger.path))
      #expect(!FileManager.default.fileExists(atPath: directory.root.path))
    }
  }
  #expect(overlapped > 0, "Remove started while the edit swapped Work's session")
}

/// The same edit and Remove, then `/feedback` with Personal alone saved. The automatic
/// screenshot shows the feed at Send, so that feed must hold nothing of Work.
@MainActor @Test(.timeLimit(.minutes(1)))
func aFeedbackScreenshotAfterAnEditAndRemoveShowsOnlyTheCoordinatorLeft() async throws {
  let gate = DialGate()
  try await withTwoFixtures(holdingWork: gate) { coordinators, workFixture, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let workOnly = "Invented private Work-only board minutes"
    await workFixture.replyToHistory(
      initial: .init(
        messages: [
          .init(
            continuation: false, entryId: "private-work", finalChunk: true, role: .final,
            text: workOnly)
        ], pageComplete: true), pages: [:])
    await gate.arm()
    let editing = Task { @MainActor in
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.3", port: 4001))
    }
    try await eventually("the edit proving Work's new address") { await gate.waiting }
    // Profile changes run one at a time, so Remove waits its turn while the edit is held there.
    var removeCalled = false
    let removing = Task { @MainActor in
      removeCalled = true
      try await coordinators.remove(coordinators.removal(work))
    }
    try await eventually("Remove called during the edit") { removeCalled }
    await gate.open()
    try await editing.value
    try await removing.value
    try await Task.sleep(for: .milliseconds(500))
    #expect(coordinators.profiles.map(\.id) == [personal])
    var shown: [String]?
    chat.draft = "/feedback The visible reply is clipped"
    // Stands in for the window capture: the bytes are the feed's rows at Send.
    await chat.send(screenshot: {
      shown = chat.rows.map(\.row.text)
      return Data((shown ?? []).joined(separator: "\n").utf8)
    })
    try await eventually("Personal's feedback") { await personalFixture.count() == 1 }
    let request = try #require(await submits(personalFixture).first)
    let screenshot = try #require(request.attachments?.first)
    let uploaded = try #require(await personalFixture.uploaded(screenshot.id))
    #expect(shown?.contains(workOnly) == false, "The screenshot showed Work's removed conversation")
    #expect(
      !String(decoding: uploaded, as: UTF8.self).contains(workOnly),
      "Personal received Work's removed conversation")
    #expect(await workFixture.count() == 0)
  }
}

/// A draft tagged `@Work` keeps that word when Work is renamed Job. Removing Job goes ahead, and
/// with Personal alone left the tag still names no saved coordinator, so Send stays blocked.
@MainActor @Test(.timeLimit(.minutes(1)))
func aTagForARenamedCoordinatorStaysBlockedOnceItIsRemoved() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.draft = "@Work"
    chat.promoteTypedTag()
    await chat.attach(
      data: Data("invented board minutes".utf8), name: "Board-minutes.txt",
      mediaType: "text/plain")
    #expect(chat.destination.chip == nil && chat.recipientLine == "To Work")
    try await coordinators.update(
      work, name: TagName("Job"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    #expect(chat.addressing == .blocked("No coordinator named Work"))
    try await coordinators.remove(coordinators.removal(work))
    #expect(coordinators.profiles.map(\.id) == [personal])
    #expect(chat.addressing == .blocked("No coordinator named Work"))
    #expect(!chat.canSend)
    await chat.send()
    try await Task.sleep(for: .seconds(1))
    let atPersonal = await submits(personalFixture)
    #expect(atPersonal.isEmpty, "Personal received \(atPersonal.map(\.text))")
    #expect(await personalFixture.uploadCount() == 0, "Personal received Work's file")
    #expect(await workFixture.count() == 0)
  }
}

/// Remove withdraws nothing until `profiles.json` is saved without the coordinator. When that
/// save fails, the coordinator stays as it was, its alerts included.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRemoveThatCannotSaveLeavesTheCoordinatorAndItsAlertsAsTheyWere() async throws {
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.start()
  await registration.received(token: String(repeating: "ab", count: 32))
  try await withTwoFixtures(registration: registration) { coordinators, workFixture, _, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    try await eventually("both enrolled") {
      registration.status(work).registered && registration.status(personal).registered
    }
    let agent = root.appending(path: "Agent")
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
    var refusal: String?
    do { try await coordinators.remove(coordinators.removal(work)) } catch {
      refusal = error.localizedDescription
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
    #expect(refusal != nil, "The failed save is reported")
    #expect(coordinators.profiles.map(\.id) == [work, personal])
    #expect(chat.lanes.map(\.id) == [work, personal])
    #expect(chat.addressing == .empty([work, personal]), "Work is addressable again")
    #expect(chat.snapshots[work]?.connection == .connected)
    #expect(registration.status(work) == .init(configured: true, registered: true))
    let withdrawal = NotificationRequest.unregister(.init(installationId: "\(work)"))
    #expect(!(await workFixture.notificationControls()).contains(withdrawal), "Nothing withdrawn")
    let status = NotificationRequest.status(.init(installationId: "\(work)"))
    await chat.reconnect(work)
    try await eventually("Work's alerts linked again after the reconnect") {
      await workFixture.notificationControls().filter { $0 == status }.count == 2
        && registration.status(work).configured
    }
    await registration.setEnabled(false)
    await registration.setEnabled(true)
    await registration.received(token: String(repeating: "cd", count: 32))
    try await eventually("Work enrolled again") { registration.status(work).registered }
    #expect(registration.status(work).error == nil, "\(registration.status(work).error ?? "")")
  }
}

/// The installation IDs of the alert withdrawals `profiles.json` keeps.
private func savedWithdrawals(_ root: URL) throws -> [String] {
  let saved = try JSONSerialization.jsonObject(
    with: Data(contentsOf: root.appending(path: "Agent/profiles.json")))
  let withdrawals = (saved as? [String: Any])?["withdrawals"] as? [[String: Any]] ?? []
  return withdrawals.compactMap { $0["installation"] as? String }
}

/// The coordinator loses Remove's withdrawal before applying it. Remove still completes, and
/// `profiles.json` keeps the withdrawal until an activation sends it again and it is confirmed.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWithdrawalItsCoordinatorNeverConfirmedIsSentAgainOnTheNextActivation() async throws {
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.start()
  await registration.received(token: String(repeating: "ab", count: 32))
  try await withTwoFixtures(registration: registration) { coordinators, workFixture, _, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    try await eventually("Work enrolled") { registration.status(work).registered }
    await workFixture.dropNextNotificationRemoval()
    try await coordinators.remove(coordinators.removal(work))
    #expect(coordinators.profiles.map(\.id) == [personal])
    let directory = ProfileDirectory(work, applicationSupport: root, caches: root)
    #expect(!FileManager.default.fileExists(atPath: directory.root.path))
    let withdrawal = NotificationRequest.unregister(.init(installationId: "\(work)"))
    #expect(await workFixture.notificationControls().filter { $0 == withdrawal }.count == 1)
    #expect(await workFixture.holdsRegistration(), "The lost withdrawal was never applied")
    #expect(try savedWithdrawals(root) == ["\(work)"], "profiles.json keeps it unconfirmed")
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("the withdrawal confirmed") {
      (try? savedWithdrawals(root))?.isEmpty == true
    }
    #expect(await workFixture.notificationControls().filter { $0 == withdrawal }.count == 2)
    #expect(!(await workFixture.holdsRegistration()), "Work no longer holds this device")
  }
}

/// A pending withdrawal whose address now answers as another coordinator, while no saved address
/// answers as its own, is dropped. No address this phone knows reaches the coordinator that holds
/// the registration, as after a reinstall, and the coordinator that answers never sees the removed
/// installation ID.
@MainActor @Test(.timeLimit(.minutes(1)))
func aPendingWithdrawalIsDroppedOnceItsAddressAnswersAsAnotherCoordinator() async throws {
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.start()
  await registration.received(token: String(repeating: "ab", count: 32))
  let route = WorkRoute()
  try await withTwoFixtures(registration: registration, route: route) {
    coordinators, workFixture, personalFixture, root in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    try await eventually("Work enrolled") { registration.status(work).registered }
    await workFixture.dropNextNotificationRemoval()
    try await coordinators.remove(coordinators.removal(work))
    #expect(try savedWithdrawals(root) == ["\(work)"])
    await coordinators.setActive(false)
    await route.point(atPersonal: true)
    let before = await personalFixture.received().count
    await coordinators.setActive(true)
    try await eventually("the withdrawal dropped") {
      (try? savedWithdrawals(root))?.isEmpty == true
    }
    let seen = await personalFixture.received().dropFirst(before)
    #expect(!seen.contains { "\($0)".contains("\(work)") }, "Personal saw Work's installation ID")
  }
}

/// Work enrolled this device for alerts, then Work and Personal trade ports, and the user removes
/// Work anyway while its line names Personal. Personal answers at Work's saved address and never
/// held Work's registration, so its answer confirms nothing. While Personal's saved address answers
/// nothing, Work's coordinator may be there, so the withdrawal is kept. Once it answers, as Work's
/// coordinator, the withdrawal reaches it there over a socket that proves Work's pin. Personal
/// never sees Work's installation ID.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWithdrawalReachesItsCoordinatorAtTheSavedAddressItNowAnswersAt() async throws {
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.start()
  await registration.received(token: String(repeating: "ab", count: 32))
  let route = WorkRoute()
  try await withTwoFixtures(registration: registration, route: route) {
    coordinators, workFixture, personalFixture, root in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    try await eventually("Work enrolled") { registration.status(work).registered }
    await route.swap()
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work's line names who answers") {
      coordinators.chat.laneError(work)?.hasPrefix("This address now answers as") == true
    }
    let before = await personalFixture.received().count
    try await coordinators.remove(coordinators.removal(work))
    await route.takePersonalsAddressDown(true)
    await coordinators.setActive(false)
    // Lets a dial Work's retired lane had started land first.
    try await Task.sleep(for: .milliseconds(200))
    let identifies = await personalFixture.received().filter { $0 == .identify }.count
    await coordinators.setActive(true)
    try await eventually("the withdrawal tried at Work's saved address") {
      await personalFixture.received().filter { $0 == .identify }.count > identifies
    }
    try await Task.sleep(for: .milliseconds(300))
    let keptWhileDown = try savedWithdrawals(root)
    await route.takePersonalsAddressDown(false)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("the saved withdrawal settled") {
      (try? savedWithdrawals(root))?.isEmpty == true
    }
    let withdrawal = NotificationRequest.unregister(.init(installationId: "\(work)"))
    let atWork = await workFixture.notificationControls().filter { $0 == withdrawal }.count
    let held = await workFixture.holds("\(work)")
    let seen = await personalFixture.received().dropFirst(before)
    let leaked = seen.contains { "\($0)".contains("\(work)") }
    print(
      "IF13-X1[withdrawal after the swap] kept while Personal's address was down=\(keptWhileDown == ["\(work)"]) withdrawals Work's coordinator got=\(atWork) Work's coordinator still holds this device=\(held) Personal saw Work's installation=\(leaked)"
    )
    #expect(keptWhileDown == ["\(work)"], "Dropped while Work's coordinator might be unreachable")
    #expect(!held, "A removed coordinator keeps alerting this device")
    #expect(!leaked, "Personal saw Work's installation ID")
  }
}

/// Nothing can attach a lane for a coordinator once Remove has marked it.
@MainActor @Test func aRemovedCoordinatorsLaneIsNeverAttachedAgain() {
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let chat = ChatModel()
  chat.removed[directory.profile] = "Work"
  chat.attach(Lane(id: directory.profile, session: nil))
  #expect(chat.lanes.isEmpty)
}

/// The app becomes active while Remove of Personal runs, as when it returns to the foreground
/// during a confirmed Remove. Both start on the main actor in this order. Nothing may dial
/// Personal again or write into its deleted directory after Remove returns.
@MainActor @Test(.timeLimit(.minutes(1)))
func anActivationDuringRemoveNeverReconnectsTheRemovedCoordinator() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let directory = ProfileDirectory(personal, applicationSupport: root, caches: root)
    await personalFixture.replyToHistory(
      initial: .init(
        messages: [
          HistoryMessage(
            continuation: false, entryId: "p-reply", finalChunk: true, role: .final,
            text: "An invented Personal reply")
        ], nextCursor: nil, pageComplete: true), pages: [:])
    let activating = Task { @MainActor in await coordinators.setActive(true) }
    let removing = Task { @MainActor in
      try await coordinators.remove(coordinators.removal(personal))
    }
    await activating.value
    try await removing.value
    let observesAtRemove = await observes(personalFixture)
    #expect(coordinators.profiles.map(\.name.description) == ["Work"])
    #expect(!FileManager.default.fileExists(atPath: directory.ledger.path))
    try await Task.sleep(for: .seconds(2))
    #expect(
      await observes(personalFixture) == observesAtRemove,
      "Nothing dials the removed coordinator again")
    #expect(
      !FileManager.default.fileExists(atPath: directory.ledger.path),
      "Nothing writes into the removed coordinator's directory")
  }
}

/// The same activation, with a message to Personal waiting for Personal's lane to reconnect.
/// Remove's confirmation says it deletes that message, so it must never leave the phone.
@MainActor @Test(.timeLimit(.minutes(1)))
func anActivationDuringRemoveNeverSendsTheMessageRemoveDeletes() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let session = try #require(coordinators.chat.lanes.first { $0.id == personal }?.session)
    let text = "Invented: renew the passport before March"
    let staged = try #require(
      await session.stage(text, sendID: UUID().uuidString, recipients: [personal]))
    await session.disconnect()
    #expect(await session.start(staged) == .started)
    #expect(
      coordinators.removal(personal).message
        == "This deletes 1 queued message on this phone.")
    let activating = Task { @MainActor in await coordinators.setActive(true) }
    let removing = Task { @MainActor in
      try await coordinators.remove(coordinators.removal(personal))
    }
    await activating.value
    try await removing.value
    try await Task.sleep(for: .seconds(2))
    #expect(await submits(personalFixture).isEmpty, "Remove deleted this message")
    #expect(await submits(workFixture).isEmpty)
  }
}

// MARK: - A recipient reads not sent only from a positive record, and unknown without one

/// The app dies between Work's stage and Personal's stage of one message to both, so only Work's
/// outbox holds it. After the relaunch and Check, this phone holds no record at Personal, so the
/// bubble says "Personal · Status unknown", never "To Work and Personal". This supersedes
/// DESIGN-REVIEW A3's "Not sent to Personal": a missing record cannot tell this kill from a
/// record that was capped or could not be read.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageToBothStagedOnlyAtWorkBeforeAKillReadsUnknownAtPersonal() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "kill-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        LineConnection(
          connection: NWConnection(to: address.port == 4002 ? personalPort : workPort, using: .tcp))
      })
  }
  let before = launch()
  await before.setActive(true)
  let (work, personal) = try await addWorkAndPersonal(before)
  let text = "Invented: dinner moved to 8, tell the sitter"
  // Send's first stage, as `ChatModel.send` makes it, and then the process stops.
  let session = try #require(before.chat.lanes.first { $0.id == work }?.session)
  let staged = try #require(
    await session.stage(text, sendID: UUID().uuidString, recipients: [work, personal]))
  await before.setActive(false)

  let after = launch()
  await after.setActive(true)
  let chat = after.chat
  try await eventually("both connected after the relaunch") {
    chat.snapshots.values.filter { $0.connection == .connected }.count == 2
  }
  try await eventually("the message's bubble") { chat.rows.contains { $0.row.text == text } }
  await chat.retry(staged.inputID)
  try await eventually("Work placed it") {
    chat.rows.first { $0.row.text == text }?.receipts.first?.status == .placed
  }
  let bubble = try #require(chat.rows.first { $0.row.text == text })
  #expect(
    bubble.receipts
      == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .unknown)])
  #expect(Receipt.summary(bubble.receipts, names: ["Work", "Personal"]) == nil)
  #expect(
    bubble.receipts.map { $0.line($0.lane == work ? "Work" : "Personal") } == [
      "Work · Delivered", "Personal · Status unknown",
    ])
  #expect(await submits(personalFixture).isEmpty)
  #expect(await submits(workFixture).map(\.text) == [text])
  await after.setActive(false)
  await workFixture.stop()
  await personalFixture.stop()
}

/// Personal places its copy of a message to both while Work's copy still waits in Work's outbox.
/// Then Personal's `Ledger.json` becomes unreadable, so its record of the message is gone. The
/// phone cannot know Personal never got it, at the next launch or at the one after Personal's
/// session has written the ledger again, so the bubble must never read "Not sent to Personal".
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageToBothReadsUnknownAtACoordinatorWhoseLedgerCouldNotBeRead() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "unreadable-ledger-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        LineConnection(
          connection: NWConnection(to: address.port == 4002 ? personalPort : workPort, using: .tcp))
      })
  }
  let before = launch()
  await before.setActive(true)
  let (work, personal) = try await addWorkAndPersonal(before)
  let text = "Invented: the plumber comes Thursday at 9"
  let send = UUID().uuidString
  let workSession = try #require(before.chat.lanes.first { $0.id == work }?.session)
  let personalSession = try #require(before.chat.lanes.first { $0.id == personal }?.session)
  _ = try #require(await workSession.stage(text, sendID: send, recipients: [work, personal]))
  let atPersonal = try #require(
    await personalSession.stage(text, sendID: send, recipients: [work, personal]))
  await personalSession.start(atPersonal)
  try await eventually("Personal placed it") {
    before.chat.rows.first { $0.id == "send:\(send)" }?.receipts.last?.status == .placed
  }
  await before.setActive(false)
  #expect(await submits(personalFixture).map(\.text) == [text])
  await personalFixture.replyToHistory(
    initial: .init(
      messages: [
        HistoryMessage(
          continuation: false, entryId: "placed-\(atPersonal.inputID)", finalChunk: true,
          role: .user, text: text)
      ], nextCursor: nil, pageComplete: true),
    pages: [:])
  let ledger = ProfileDirectory(personal, applicationSupport: root, caches: root).ledger
  try Data("not a ledger".utf8).write(to: ledger)

  for relaunch in ["with the unreadable ledger", "after Personal saved its ledger again"] {
    let after = launch()
    await after.setActive(true)
    let chat = after.chat
    try await eventually("both connected \(relaunch)") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    try await eventually("Personal's history loaded \(relaunch)") {
      chat.snapshots[personal]?.rows.contains { $0.text == text } == true
    }
    let bubble = try #require(chat.rows.first { $0.id == "send:\(send)" })
    #expect(bubble.receipts.map(\.lane) == [work, personal])
    #expect(bubble.receipts.last?.status == .unknown, "Personal \(relaunch)")
    #expect(
      bubble.receipts.last.map { $0.line("Personal") } == "Personal · Status unknown",
      "Personal \(relaunch)")
    await after.setActive(false)
    #expect(
      (try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: ledger))) != nil,
      "Personal's session wrote its ledger again \(relaunch)")
  }
  #expect(await submits(personalFixture).map(\.text) == [text], "Nothing was sent again")
  await workFixture.stop()
  await personalFixture.stop()
}

/// Work is busy and Personal quiet. A message to both, staged at Work first, is still in Personal's
/// latest page. One more Work send makes Work's cap drop its record of it, the newest record the
/// cap dropped. Work placed it, so the bubble must not say "Not sent to Work".
@Test(.timeLimit(.minutes(1)))
func aFirstRecipientsCappedRecordReadsUnknownWhileTheMessageIsInTheLatestPage() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let (workDirectory, workRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: workRoot) }
  let (personalDirectory, personalRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: personalRoot) }
  let work = workDirectory.profile
  let personal = personalDirectory.profile
  let both = [work, personal]
  let workQueued: TimeInterval = 1_700_000_100.000
  let personalQueued: TimeInterval = 1_700_000_100.001
  var workLedger = Ledger()
  workLedger.sends["send-b"] = .init(
    inputID: "w-b-input", entryID: "w-b", recipients: both, queuedAt: workQueued)
  workLedger.entries["w-b"] = .init(receivedAt: workQueued, sendID: "send-b")
  for index in 0..<1999 {
    let stamp = 1_700_000_200 + Double(index)
    workLedger.entries["w-\(index)"] = .init(receivedAt: stamp, sendID: "send-w\(index)")
    workLedger.sends["send-w\(index)"] = .init(
      inputID: "w-input-\(index)", entryID: "w-\(index)", recipients: [work], queuedAt: stamp)
  }
  try writePrivately(JSONEncoder().encode(workLedger), to: workDirectory.ledger)
  var personalLedger = Ledger()
  personalLedger.sends["send-b"] = .init(
    inputID: "p-b-input", entryID: "p-b", recipients: both, queuedAt: personalQueued)
  personalLedger.entries["p-b"] = .init(receivedAt: personalQueued, sendID: "send-b")
  try writePrivately(JSONEncoder().encode(personalLedger), to: personalDirectory.ledger)
  func reply(_ entry: String, role: HistoryRole = .final, _ text: String) -> HistoryMessage {
    HistoryMessage(continuation: false, entryId: entry, finalChunk: true, role: role, text: text)
  }
  let text = "Invented: flying to Lisbon, offline until 6"
  await workFixture.replyToHistory(
    initial: .init(
      messages: [reply("w-today", "An invented Work reply")], nextCursor: nil,
      pageComplete: true), pages: [:])
  await personalFixture.replyToHistory(
    initial: .init(
      messages: [reply("p-b", role: .user, text)], nextCursor: nil, pageComplete: true),
    pages: [:])
  func until(
    _ session: CoordinatorSession, _ predicate: @Sendable (ChatSnapshot) -> Bool
  ) async throws -> ChatSnapshot {
    for await snapshot in session.updates where predicate(snapshot) { return snapshot }
    throw ConnectionError.closed
  }
  let stamps = StampSource()
  let workSession = CoordinatorSession(
    directory: workDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: workFixture.id, stamps: stamps, transport: loopback(workPort))
  let personalSession = CoordinatorSession(
    directory: personalDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: personalFixture.id, stamps: stamps, transport: loopback(personalPort))
  await workSession.connect()
  await personalSession.connect()
  _ = try await until(workSession) { $0.connection == .connected }
  let personalSnapshot = try await until(personalSession) {
    $0.connection == .connected && $0.rows.contains { $0.text == text }
  }
  #expect(await workSession.submit("Invented: one more for Work"))
  let workSnapshot = try await until(workSession) { snapshot in
    snapshot.connection == .connected && snapshot.sends["send-b"] == nil
      && snapshot.sends.values.allSatisfy { $0.progress == .placed }
  }
  let saved = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: workDirectory.ledger))
  #expect(saved.sends["send-b"] == nil, "Work's cap dropped its record of the message")
  let bubble = try #require(
    Feed.merge([(work, workSnapshot), (personal, personalSnapshot)]).first {
      $0.row.text == text
    })
  let names = [work: "Work", personal: "Personal"]
  let lines =
    Receipt.summary(bubble.receipts, names: bubble.receipts.map { names[$0.lane]! })
    .map { [$0] } ?? bubble.receipts.map { $0.line(names[$0.lane]!) }
  #expect(
    bubble.receipts
      == [Receipt(lane: work, status: .unknown), Receipt(lane: personal, status: .placed)],
    "Work's cap dropped its record, so the phone cannot say Work never got it")
  #expect(!lines.contains("Not sent to Work"))
  await workSession.disconnect()
  await personalSession.disconnect()
  await workFixture.stop()
  await personalFixture.stop()
}

/// The same cap at the first-staged recipient, with both copies of the old message loaded from an
/// earlier page. Work placed it and its cap dropped the record, so Work reads unknown.
@Test(.timeLimit(.minutes(1)))
func aFirstRecipientsCappedRecordReadsUnknownOnceItsMessageIsLoadedEarlier() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let (workDirectory, workRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: workRoot) }
  let (personalDirectory, personalRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: personalRoot) }
  let work = workDirectory.profile
  let personal = personalDirectory.profile
  let both = [work, personal]
  var workLedger = Ledger()
  workLedger.sends["send-old"] = .init(
    inputID: "w-old-input", entryID: "w-old", recipients: both, queuedAt: 100)
  workLedger.entries["w-today"] = .init(receivedAt: 5000)
  for index in 0..<1999 {
    workLedger.sends["send-w\(index)"] = .init(
      inputID: "w-input-\(index)", entryID: "w-e\(index)", recipients: [work],
      queuedAt: 200 + Double(index))
  }
  try writePrivately(JSONEncoder().encode(workLedger), to: workDirectory.ledger)
  var personalLedger = Ledger()
  personalLedger.sends["send-old"] = .init(
    inputID: "p-old-input", entryID: "p-old", recipients: both, queuedAt: 100.001)
  personalLedger.entries["p-today"] = .init(receivedAt: 5001)
  try writePrivately(JSONEncoder().encode(personalLedger), to: personalDirectory.ledger)
  func reply(_ entry: String, role: HistoryRole = .final, _ text: String) -> HistoryMessage {
    HistoryMessage(continuation: false, entryId: entry, finalChunk: true, role: role, text: text)
  }
  func page(_ messages: [HistoryMessage], next: String?) -> NativeEventHistory {
    .init(messages: messages, nextCursor: next, pageComplete: true)
  }
  await workFixture.replyToHistory(
    initial: page([reply("w-today", "A Work reply")], next: "older"),
    pages: ["older": page([reply("w-old", role: .user, "Flying to Lisbon")], next: nil)])
  await personalFixture.replyToHistory(
    initial: page([reply("p-today", "A Personal reply")], next: "older"),
    pages: ["older": page([reply("p-old", role: .user, "Flying to Lisbon")], next: nil)])
  func until(
    _ session: CoordinatorSession, _ predicate: @Sendable (ChatSnapshot) -> Bool
  ) async throws -> ChatSnapshot {
    for await snapshot in session.updates where predicate(snapshot) { return snapshot }
    throw ConnectionError.closed
  }
  let stamps = StampSource()
  let workSession = CoordinatorSession(
    directory: workDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: workFixture.id, stamps: stamps, transport: loopback(workPort))
  let personalSession = CoordinatorSession(
    directory: personalDirectory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: personalFixture.id, stamps: stamps, transport: loopback(personalPort))
  await workSession.connect()
  await personalSession.connect()
  _ = try await until(workSession) { $0.connection == .connected }
  _ = try await until(personalSession) { $0.connection == .connected }
  #expect(await workSession.submit("One more for Work"))
  try await eventually("Work's cap dropped its record of the old send") {
    let saved = try? JSONDecoder().decode(
      Ledger.self, from: Data(contentsOf: workDirectory.ledger))
    return saved != nil && saved?.sends["send-old"] == nil
  }
  // The placement that dropped it arrives on the reconnect that follows the submit, and an earlier
  // page loads only once that reconnect completes.
  _ = try await until(workSession) { $0.connection == .connected }
  await workSession.loadEarlier()
  await personalSession.loadEarlier()
  let workSnapshot = try await until(workSession) { $0.rows.contains { $0.entryID == "w-old" } }
  let personalSnapshot = try await until(personalSession) {
    $0.rows.contains { $0.entryID == "p-old" }
  }
  let old = Feed.merge([(work, workSnapshot), (personal, personalSnapshot)]).filter {
    $0.row.text == "Flying to Lisbon"
  }
  #expect(
    old.first { $0.id == "send:send-old" }?.receipts == [
      Receipt(lane: work, status: .unknown), Receipt(lane: personal, status: .placed),
    ], "Work placed it and its cap dropped the record, so Work must read Status unknown")
  await workSession.disconnect()
  await personalSession.disconnect()
  await workFixture.stop()
  await personalFixture.stop()
}

/// A message to both. Work's coordinator accepted Work's copy, but the phone never saw it placed,
/// so it stays in Work's outbox. Personal placed its copy. Then Work's `Outbox/pending.json`
/// cannot be read at the next launch. Work's coordinator has the message, so the bubble must
/// never say "Not sent to Work".
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageToBothReadsUnknownAtACoordinatorWhoseOutboxCouldNotBeRead() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "unreadable-outbox-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        LineConnection(
          connection: NWConnection(to: address.port == 4002 ? personalPort : workPort, using: .tcp))
      })
  }
  let before = launch()
  await before.setActive(true)
  let (work, personal) = try await addWorkAndPersonal(before)
  let text = "Invented: the plumber comes Thursday at 9"
  await workFixture.holdSnapshot()
  before.chat.draft = text
  await before.chat.send()
  try await eventually("Work's coordinator has Work's copy") {
    await submits(workFixture).map(\.text) == [text]
  }
  try await eventually("Personal placed its copy") {
    before.chat.rows.first { $0.row.text == text }?.receipts.last?.status == .placed
  }
  await before.setActive(false)
  await workFixture.releaseSnapshot()
  let personalInput = try #require(await submits(personalFixture).first?.inputId)
  await personalFixture.replyToHistory(
    initial: .init(
      messages: [
        HistoryMessage(
          continuation: false, entryId: "placed-\(personalInput)", finalChunk: true,
          role: .user, text: text)
      ], nextCursor: nil, pageComplete: true),
    pages: [:])
  let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
  #expect(try queuedRequests(outbox).map(\.text) == [text])
  try Data("not an outbox".utf8).write(to: outbox)

  let after = launch()
  await after.setActive(true)
  let chat = after.chat
  try await eventually("Personal's history loaded") {
    chat.snapshots[personal]?.rows.contains { $0.text == text } == true
  }
  try await eventually("Work's lane reported") { chat.snapshots[work]?.error != nil }
  let bubble = try #require(chat.rows.first { $0.row.text == text })
  let names = [work: "Work", personal: "Personal"]
  let lines =
    Receipt.summary(bubble.receipts, names: bubble.receipts.map { names[$0.lane]! })
    .map { [$0] } ?? bubble.receipts.map { $0.line(names[$0.lane]!) }
  #expect(!lines.contains("Not sent to Work"), "Work's coordinator has this message")
  #expect(lines == ["Work · Status unknown", "Personal · Delivered"])
  #expect(await submits(workFixture).map(\.text) == [text], "Nothing was sent again")
  await after.setActive(false)
  await workFixture.stop()
  await personalFixture.stop()
}

/// Personal places its copy of a message to both while Work's copy waits in Work's outbox. Then
/// Personal's ledger becomes unreadable, and the phone restarts after its clock moved back. A
/// missing record is not proof that Personal never got the message, whatever the clock says.
@Test(.timeLimit(.minutes(1)))
func aRecipientWhoseLedgerCouldNotBeReadReadsUnknownAfterTheClockMovedBack() async throws {
  let workPeer = FixtureCoordinator()
  let personalPeer = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workPeer)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalPeer)
  defer { personalListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let work = ProfileID()
  let personal = ProfileID()
  let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
  let personalDirectory = ProfileDirectory(personal, applicationSupport: root, caches: root)
  let address = try CoordinatorAddress(host: "100.64.1.2")
  func snapshot(
    _ session: CoordinatorSession, matching condition: @Sendable (ChatSnapshot) -> Bool
  ) async throws -> ChatSnapshot {
    for await snapshot in session.updates where condition(snapshot) { return snapshot }
    throw ConnectionError.closed
  }
  let oldClock = StampSource(now: { 4000 })
  let beforeWork = CoordinatorSession(
    directory: workDirectory, address: address, pin: workPeer.id, stamps: oldClock,
    transport: loopback(workPort))
  let beforePersonal = CoordinatorSession(
    directory: personalDirectory, address: address, pin: personalPeer.id, stamps: oldClock,
    transport: loopback(personalPort))
  await beforeWork.connect()
  await beforePersonal.connect()
  _ = try await snapshot(beforeWork) { $0.connection == .connected }
  _ = try await snapshot(beforePersonal) { $0.connection == .connected }
  let send = UUID().uuidString
  let text = "Invented: the appointment moved to 8"
  _ = try #require(await beforeWork.stage(text, sendID: send, recipients: [work, personal]))
  let personalInput = try #require(
    await beforePersonal.stage(text, sendID: send, recipients: [work, personal]))
  await beforePersonal.start(personalInput)
  _ = try await snapshot(beforePersonal) { $0.sends[send]?.progress == .placed }
  await beforeWork.disconnect()
  await beforePersonal.disconnect()
  #expect(await submits(personalPeer).map(\.text) == [text])
  try Data("unreadable ledger".utf8).write(to: personalDirectory.ledger)

  let newClock = StampSource(now: { 1000 })
  let afterWork = CoordinatorSession(
    directory: workDirectory, address: address, pin: workPeer.id, stamps: newClock,
    transport: loopback(workPort))
  let afterPersonal = CoordinatorSession(
    directory: personalDirectory, address: address, pin: personalPeer.id, stamps: newClock,
    transport: loopback(personalPort))
  await afterWork.connect()
  await afterPersonal.connect()
  let workSnapshot = try await snapshot(afterWork) {
    $0.connection == .connected && $0.sends[send] != nil
  }
  let personalSnapshot = try await snapshot(afterPersonal) { $0.connection == .connected }
  let receipt = try #require(
    Feed.merge([(work, workSnapshot), (personal, personalSnapshot)]).first {
      $0.id == "send:\(send)"
    }?.receipts.last)
  #expect(
    receipt.status == .unknown,
    "A receipt lost to unreadable storage is not proof of non-delivery after clock rollback")
  #expect(receipt.line("Personal") == "Personal · Status unknown")
  await afterWork.disconnect()
  await afterPersonal.disconnect()
  await workPeer.stop()
  await personalPeer.stop()
}

/// Personal refuses its copy of a message to both, and the user discards it. Personal never placed
/// the message, so the bubble must not read "To Work and Personal".
@MainActor @Test(.timeLimit(.minutes(1)))
func aCopyDiscardedAtPersonalLeavesTheOriginalNotSentToPersonal() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    await personalFixture.refuseUploads()
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the signed lease for both of you"
    chat.draft = text
    await chat.attach(data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
    await chat.send()
    var rejected: String?
    try await eventually("Work placed it and Personal refused it") {
      let receipts = chat.rows.first { $0.row.text == text }?.receipts ?? []
      guard receipts.first?.status == .placed, receipts.count == 2,
        case .pending(.rejected, let id?) = receipts[1].status
      else { return false }
      rejected = id
      return true
    }
    let original = try #require(chat.rows.first { $0.row.text == text })
    let send = String(original.id.dropFirst("send:".count))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await chat.discard(try #require(rejected))
    let personalOutbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    try await eventually("Personal's original withdrawn") {
      (try? queuedRequests(personalOutbox))?.isEmpty == true
        && chat.snapshots[personal]?.sends[send]?.progress == .withdrawn
    }
    let bubble = try #require(chat.rows.first { $0.id == original.id })
    #expect(
      bubble.receipts
        == [Receipt(lane: work, status: .placed), Receipt(lane: personal, status: .notSent)])
    #expect(Receipt.summary(bubble.receipts, names: ["Work", "Personal"]) == nil)
    #expect(await submits(personalFixture).isEmpty)
    #expect(await personalFixture.uploadCount() == 0)
  }
}

// MARK: - Each file that may show a coordinator's feed is owned by that coordinator

/// A kept automatic screenshot and a chosen file share the name `Feedback.png`. After a restore,
/// removing the chosen one leaves the screenshot owned by Work, so it never goes to Personal.
@MainActor @Test(.timeLimit(.minutes(1)))
func aSecondFileNamedFeedbackPngNeverClearsTheScreenshotsOwner() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let directory = ProfileDirectory(work, applicationSupport: root, caches: root)
    let privateImage = Data("Invented private Work screenshot bytes".utf8)
    try await withReadOnlyProfile(directory) {
      chat.draft = "/feedback The Work feed is clipped"
      await chat.send(screenshot: { privateImage })
    }
    try #require(chat.attachments.map(\.reference.name) == ["Feedback.png", "Composer.log"])
    await chat.attach(
      data: Data("Invented manually attached reference picture".utf8), name: "Feedback.png",
      mediaType: "image/png")
    await workFixture.refuseUploads()
    await chat.send()
    try await eventually("Work refused the upload") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(directory.outbox).first)
    try #require(queued.attachments?.count == 3)
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await chat.restore(queued.inputId)
    let automatic = try #require(chat.attachments.first)
    let chosen = try #require(chat.attachments.last)
    #expect(try Data(contentsOf: automatic.url) == privateImage)
    await chat.removeAttachment(chosen)
    chat.removeChip()
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true)
    try await Task.sleep(for: .milliseconds(350))
    let atPersonal = await submits(personalFixture)
    #expect(atPersonal.isEmpty, "Personal received \(atPersonal.map(\.text))")
    #expect(await personalFixture.uploaded(automatic.id) != privateImage)
  }
}

/// A restored `Feedback.png` belongs to the coordinator it came from. Sent to that coordinator
/// alone it goes, since no other coordinator sees it. Sent to both it is refused.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredFeedbackPngGoesToTheCoordinatorItCameFromAlone() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    await workFixture.refuseUploads()
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
    chat.setChip(work)
    chat.draft = "Invented ordinary note, not feedback"
    await chat.attach(
      data: Data("invented user file bytes".utf8), name: "Feedback.png", mediaType: "image/png")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(workDirectory.outbox).first)
    await chat.restore(queued.inputId)
    #expect(chat.destination.chip == work && chat.recipientLine == "To Work")
    chat.removeChip()
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true, "Not to both")
    chat.setChip(work)
    chat.failure = nil
    await workFixture.acceptUploads()
    await chat.send()
    #expect(chat.error == nil)
    #expect(chat.draft.isEmpty && chat.attachments.isEmpty)
    try await eventually("Work's copy") { await workFixture.count() == 1 }
    #expect(await submits(personalFixture).isEmpty)
    #expect(await personalFixture.uploadCount() == 0)
  }
}

// MARK: - A control a coordinator did not get says so by name

/// A control command is not saved, so it never waits for a lane (DESIGN-REVIEW #8). When Work's
/// lane drops between the stage and the start, Work does not get it, and the composer names
/// Work. When no recipient got it, the draft stays for another try.
@MainActor @Test(.timeLimit(.minutes(1)))
func aControlACoordinatorDidNotGetNamesItInTheError() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    @MainActor func sendWhileWorkDrops() async throws {
      // Both start on the main actor in this order, so Work drops after its stage.
      let sending = chat.startSend()
      let dropping = Task { @MainActor in await session.disconnect() }
      await sending?.value
      await dropping.value
      await session.connect()
      try await eventually("both connected again") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    }
    chat.draft = "/status"
    try await sendWhileWorkDrops()
    try await eventually("Personal got /status") {
      await submits(personalFixture).map(\.text) == ["/status"]
    }
    try await Task.sleep(for: .milliseconds(250))
    #expect(await submits(workFixture).isEmpty, "A control is never sent later")
    #expect(chat.error == "Work did not get /status. It is not connected.")
    #expect(chat.draft.isEmpty, "Personal got it")

    chat.setChip(work)
    chat.draft = "/status"
    try await sendWhileWorkDrops()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await submits(workFixture).isEmpty)
    #expect(chat.error == "Work did not get /status. It is not connected.")
    #expect(
      chat.draft == "/status" && chat.destination.chip == work, "Nothing went, so the draft stays")
  }
}

/// A control to both while Work is removed. Both start on the main actor in this order. Work did
/// not get it, so the error says so and why, and nothing keeps the control to send later.
@MainActor @Test(.timeLimit(.minutes(1)))
func aControlDuringRemoveNamesTheRemovedCoordinatorItSkipped() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.draft = "/status"
    let sending = chat.startSend()
    let removing = Task { @MainActor in try await coordinators.remove(coordinators.removal(work)) }
    await sending?.value
    try await removing.value
    let named = "Work did not get /status. It was removed."
    try await eventually("Personal got /status") {
      await submits(personalFixture).map(\.text) == ["/status"]
    }
    try await eventually("Work got /status, or the composer says it did not") {
      await !submits(workFixture).isEmpty || chat.error == named
    }
    let sentToWork = await submits(workFixture).map(\.text)
    #expect(
      sentToWork.isEmpty ? chat.error == named : chat.error == nil,
      "Work got \(sentToWork), and the error says \(chat.error ?? "nothing")")
    #expect(chat.draft.isEmpty, "Personal got it")
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    #expect((try? queuedRequests(outbox))?.isEmpty ?? true, "A control is never queued")
  }
}

// MARK: - A retired session's Send inputs that never left the phone are named

/// A message to both while Work is removed. Both start on the main actor in this order, so Remove
/// retires Work's session between Work's stage and its start, and deletes Work's copy with its
/// profile. If Work got nothing, the composer says so and why.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageDuringRemoveNamesTheRemovedCoordinatorItDidNotReach() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: ship the quarterly report"
    chat.draft = text
    let sending = chat.startSend()
    let removing = Task { @MainActor in try await coordinators.remove(coordinators.removal(work)) }
    await sending?.value
    try await removing.value
    let named = "Work did not get this message. It was removed."
    try await eventually("Personal got it") { await submits(personalFixture).map(\.text) == [text] }
    try await eventually("Work got it, or the composer says it did not") {
      await !submits(workFixture).isEmpty || chat.error == named
    }
    let atWork = await submits(workFixture).map(\.text)
    let atPersonal = await submits(personalFixture).map(\.text)
    print(
      "IF5-S1-A Work=\(atWork) Personal=\(atPersonal) error=\(chat.error ?? "nil") draft=\(chat.draft.debugDescription)"
    )
    #expect(atPersonal == [text])
    if atWork.isEmpty {
      #expect(
        chat.error == named, "Work got nothing, and the error says \(chat.error ?? "nothing")")
    }
  }
}

/// The same race removing Personal, the second recipient. Remove can finish before Personal's
/// stage, and then nothing is sent. The composer says so and names Personal, though only one
/// coordinator is left.
@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageDuringRemoveOfItsSecondRecipientNamesIt() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: water the plants on Friday"
    chat.draft = text
    let sending = chat.startSend()
    let removing = Task { @MainActor in
      try await coordinators.remove(coordinators.removal(personal))
    }
    await sending?.value
    try await removing.value
    let named = "Personal did not get this message. It was removed."
    let nothing = "Nothing was sent. \(named)"
    try await eventually("Work got it, or the composer says nothing was sent") {
      await !submits(workFixture).isEmpty || chat.error == nothing
    }
    try await eventually("Personal got it, or the composer says it did not") {
      await !submits(personalFixture).isEmpty || chat.error?.contains(named) == true
    }
    let atWork = await submits(workFixture).map(\.text)
    let atPersonal = await submits(personalFixture).map(\.text)
    print(
      "IF5-S1-B Work=\(atWork) Personal=\(atPersonal) error=\(chat.error ?? "nil") draft=\(chat.draft.debugDescription)"
    )
    if atPersonal.isEmpty {
      #expect(
        chat.error?.contains(named) == true,
        "Personal got nothing, and the error says \(chat.error ?? "nothing")")
    }
    if atWork.isEmpty {
      #expect(chat.error == nothing)
      #expect(chat.draft == text, "Nothing went, so the draft stays")
    }
  }
}

/// A Send to both whose socket to Work is still proving Work's identity when Remove retires Work's
/// session. Personal got it, and the composer names what Work did not get.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["/status", "Invented: renew the lease"])
func aSendRemovedDuringItsIdentityProofNamesTheCoordinatorItDidNotReach(_ draft: String)
  async throws
{
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await workFixture.holdNextIdentity()
    chat.draft = draft
    await chat.send()
    try await eventually("Work's socket waiting for its identity") {
      await workFixture.identityHeld
    }
    try await eventually("Personal got it") { await personalFixture.count() == 1 }
    try await coordinators.remove(coordinators.removal(work))
    await workFixture.releaseIdentity()
    try await Task.sleep(for: .milliseconds(350))
    print("IF5-S1-C draft=\(draft) error=\(chat.error ?? "nil")")
    #expect(await submits(workFixture).isEmpty)
    #expect(await submits(personalFixture).map(\.text) == [draft])
    #expect(
      chat.error
        == (draft == "/status"
          ? "Work did not get /status. It was removed."
          : "Work did not get this message. It was removed."))
    #expect(chat.draft.isEmpty, "Personal got it")
  }
}

/// A Send whose dial to Work is still pending when an edit of Work's address retires Work's
/// session, with one coordinator saved or two. A control is lost, so the composer names it. A
/// message stays in Work's outbox for the new session, as any message does, and nothing is said.
@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: [1, 2], ["/status", "Invented: renew the lease"])
func aSendWhoseAddressChangesWhileItsDialIsPendingIsNamedOnlyIfLost(saved: Int, draft: String)
  async throws
{
  let gate = DialGate()
  try await withTwoFixtures(holdingWork: gate) { coordinators, workFixture, personalFixture, root in
    let work: ProfileID
    if saved == 2 {
      work = try await addWorkAndPersonal(coordinators).work
    } else {
      try await coordinators.add(
        name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      work = try #require(coordinators.profiles.first?.id)
      try await eventually("Work connected") { coordinators.chat.connection == .connected }
    }
    let chat = coordinators.chat
    await gate.arm()
    chat.draft = draft
    await chat.send()
    try await eventually("Work's dial held") { await gate.waiting }
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.3", port: 4003))
    await gate.open()
    if saved == 2 {
      try await eventually("Personal got it") {
        await submits(personalFixture).map(\.text) == [draft]
      }
    }
    try await Task.sleep(for: .milliseconds(350))
    print("IF5-S1-D saved=\(saved) draft=\(draft) error=\(chat.error ?? "nil")")
    #expect(await submits(workFixture).isEmpty)
    #expect(await submits(personalFixture).map(\.text) == (saved == 2 ? [draft] : []))
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    if draft == "/status" {
      #expect(chat.error == "Work did not get /status. Its address changed.")
    } else {
      #expect(chat.error == nil)
      #expect(try queuedRequests(outbox).map(\.text) == [draft], "Kept for the new session")
    }
  }
}

// MARK: - A Send that reaches no one leaves no copy, whichever session holds the outbox

/// Puts `text` and eight files of the largest size in the draft, so copying them into each
/// recipient's outbox takes a while. With `clashAt`, that outbox already holds another file under
/// the last one's ID, so its coordinator cannot take the message. Returns that file's folder.
@MainActor private func draftEightLargeFiles(
  _ chat: ChatModel, _ text: String, clashAt directory: ProfileDirectory? = nil
) async throws -> URL? {
  chat.draft = text
  for index in 1...8 {
    await chat.attach(
      data: Data(repeating: UInt8(index), count: AttachmentLimits.maximumBytes),
      name: "Scan\(index).bin", mediaType: "application/octet-stream")
  }
  try #require(chat.attachments.count == 8)
  guard let directory else { return nil }
  let last = try #require(chat.attachments.last)
  let clash = directory.outboxAttachments.appending(path: last.id)
  try FileManager.default.createDirectory(at: clash, withIntermediateDirectories: true)
  try Data(repeating: 0xEE, count: AttachmentLimits.maximumBytes).write(
    to: clash.appending(path: last.reference.name))
  return clash
}

/// A draft file whose bytes come through a named pipe, so a copy that reaches it waits until the
/// test feeds it. Each feed gives one reader the file's bytes.
@MainActor private final class PipedFile {
  let url: URL
  private let bytes: Data
  private var writer: Int32 = -1

  init(_ file: LocalAttachment) throws {
    url = file.url
    bytes = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    guard mkfifo(url.path, 0o600) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }

  /// Returns once `copy` has opened the pipe. The copy then waits for `feed()`.
  func opened(by copy: String) async throws {
    try await eventually("\(copy) to open \(url.lastPathComponent)") {
      if writer < 0 { writer = open(url.path, O_WRONLY | O_NONBLOCK) }
      return writer >= 0
    }
  }

  /// Gives the copy that opened the pipe the file's bytes, then ends the file. Fails once the copy
  /// has read nothing for 15 seconds.
  func feed() async throws {
    let (writer, bytes) = (writer, bytes)
    self.writer = -1
    let sent = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
      DispatchQueue.global().async {
        var (sent, progress) = (0, ContinuousClock.now)
        var ready = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
        while sent < bytes.count, ContinuousClock.now - progress < .seconds(15) {
          // poll can report a named pipe writable while a write to it still returns EAGAIN.
          poll(&ready, 1, 1_000)
          let count = bytes[sent...].withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
          if count > 0 {
            (sent, progress) = (sent + count, .now)
          } else if errno != EAGAIN {
            break
          }
        }
        close(writer)
        continuation.resume(returning: sent)
      }
    }
    try #require(sent == bytes.count, "The copy stopped reading \(url.lastPathComponent)")
  }

  /// Ends a reader still waiting at the pipe with no bytes, so a failed test leaves no copy stuck.
  func release() {
    if writer < 0 { writer = open(url.path, O_WRONLY | O_NONBLOCK) }
    if writer >= 0 { close(writer) }
    writer = -1
  }
}

/// A message with eight files goes to both, and Work saves its copy first. While Personal still
/// copies the files, Work's address is edited to another that reaches Work, which retires Work's
/// session and gives its outbox to a new one, or it is not, the control. Then Personal cannot take
/// the message: another file is saved under one of its IDs, or Personal's connection drops. Nothing
/// was sent, so no coordinator keeps a copy, the feed shows none, and the draft stays with its
/// error. Sending it again gives each coordinator the message once.
@MainActor
@Test(
  .timeLimit(.minutes(5)), arguments: [(false, "clash"), (true, "clash"), (true, "Personal drops")])
func aSendToBothPersonalRefusesLeavesNothingAtWorkAfterAnAddressEdit(
  _ edit: Bool, _ failure: String
) async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the quarterly scans for both"
    let personalDirectory = ProfileDirectory(personal, applicationSupport: root, caches: root)
    let clash = try await draftEightLargeFiles(
      chat, text, clashAt: failure == "clash" ? personalDirectory : nil)
    // Personal's copy of the seventh file waits until the edit is done.
    let held = try edit ? PipedFile(#require(chat.attachments.dropLast().last)) : nil
    defer { held?.release() }
    let workOutbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let sending = chat.startSend()
    if let held {
      try await held.opened(by: "Work's copy")
      try await held.feed()
      try await eventually("Work saved its copy") {
        ((try? queuedRequests(workOutbox)) ?? []).count == 1
      }
      try await held.opened(by: "Personal's copy")
      if failure == "Personal drops" {
        // Personal's connection drops while it still copies the files, and stays down.
        await personalFixture.dropIdentify()
        await personalFixture.stop()
        try await eventually("Personal's lane down") {
          chat.snapshots[personal]?.connection != .connected
        }
      }
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
      try #require(chat.admitting, "The edit finished while Personal still copied the files")
      try await held.feed()
    }
    await sending?.value
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let queuedAtWork = ((try? queuedRequests(workOutbox)) ?? []).map(\.text)
    let workRow = chat.snapshots[work]?.rows.first { $0.text == text }
    let receipts =
      chat.rows.first { $0.row.text == text }?.receipts.map { $0.line(chat.name($0.lane)) } ?? []
    print(
      "IF11-2[edit=\(edit), \(failure)] after the Send: error=\(chat.error ?? "nil") draftKept=\(chat.draft == text) files=\(chat.attachments.count) Work's outbox=\(queuedAtWork) Work's row=\(workRow?.delivery?.rawValue ?? "none") receipts=\(receipts)"
    )
    #expect(chat.draft == text && chat.attachments.count == 8, "The draft stays")
    #expect(chat.error == "Nothing was sent. Personal did not take the message.")
    #expect(queuedAtWork.isEmpty, "Personal did not take it, yet Work keeps a copy queued")
    #expect(workRow == nil && receipts.isEmpty, "The feed shows a message that was not sent")
    if let clash { try FileManager.default.removeItem(at: clash) }
    if failure == "Personal drops" {
      await personalFixture.dropIdentify(false)
      await chat.reconnect(personal)
    }
    // The text alone is sent again, so its copies upload quickly however loaded the host is.
    for file in chat.attachments { await chat.removeAttachment(file) }
    try await eventually("both connected again") { chat.canSend }
    await chat.send()
    // Check / retry on a copy the failed Send left at Work, as its row offers.
    if let left = workRow?.inputID { await chat.retry(left) }
    try await eventually("each coordinator got it") {
      let (atWork, atPersonal) = (await workFixture.count(), await personalFixture.count())
      return atWork >= (workRow == nil ? 1 : 2) && atPersonal >= 1
    }
    let atWork = await submits(workFixture).map(\.text)
    let atPersonal = await submits(personalFixture).map(\.text)
    print(
      "IF11-2[edit=\(edit), \(failure)] sent again: Work got \(atWork.count)x, Personal got \(atPersonal.count)x"
    )
    #expect(atWork == [text] && atPersonal == [text], "Each coordinator gets the message once")
  }
}

/// The same Send, with Work's session retired while Personal still copies the files, and Personal
/// refusing before the change that retired it is done. An address edit retires Work's session before
/// it attaches the next one. Remove retires it, then deletes Work's files. The retired session
/// writes nothing, so Remove's deletion stands, and after an edit the next session withdraws Work's
/// copy once it is attached.
@MainActor @Test(.timeLimit(.minutes(2)), arguments: ["an address edit", "Remove"])
func aCopyWhoseSessionRetiredDuringASendThatReachedNoOneIsNotKept(_ change: String)
  async throws
{
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the signed lease for both"
    _ = try await draftEightLargeFiles(
      chat, text, clashAt: ProfileDirectory(personal, applicationSupport: root, caches: root))
    let workDirectory = ProfileDirectory(work, applicationSupport: root, caches: root)
    let retiring = try #require(chat.lanes.first { $0.id == work }?.session)
    let sending = chat.startSend()
    try await eventually("Work saved its copy") {
      ((try? queuedRequests(workDirectory.outbox)) ?? []).count == 1
    }
    if change == "Remove" {
      try await coordinators.remove(coordinators.removal(work))
    } else {
      await retiring.retire()
    }
    try #require(chat.admitting, "Work's session retired while Personal still copied the files")
    await sending?.value
    let afterSend = ((try? queuedRequests(workDirectory.outbox)) ?? []).map(\.text)
    if change == "Remove" {
      try await Task.sleep(for: .milliseconds(300))
      let recreated = FileManager.default.fileExists(atPath: workDirectory.root.path)
      print(
        "IF11-2[\(change)] error=\(chat.error ?? "nil") Work's folder recreated=\(recreated) Work got=\(await workFixture.count())"
      )
      #expect(!recreated, "Something wrote Work's folder after Remove deleted it")
    } else {
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
      try await eventually("Work's next session connected") {
        chat.snapshots[work]?.connection == .connected
      }
      let withdrawn = await within(15) {
        ((try? queuedRequests(workDirectory.outbox)) ?? []).isEmpty
          && chat.snapshots[work]?.rows.contains { $0.text == text } == false
      }
      print(
        "IF11-2[\(change)] error=\(chat.error ?? "nil") Work's outbox after the Send=\(afterSend) withdrawn once the next session is attached=\(withdrawn) Work got=\(await workFixture.count())"
      )
      #expect(withdrawn, "Work's next session keeps a copy of a message that was not sent")
    }
    // With one coordinator left, Personal's own error follows the composer's.
    #expect(chat.error?.hasPrefix("Nothing was sent. Personal did not take the message.") == true)
    #expect(chat.draft == text, "The draft stays")
    #expect((await workFixture.count(), await personalFixture.count()) == (0, 0))
  }
}

/// A message to both whose socket to Work is still proving Work's identity when Remove takes Work,
/// while Personal refuses its copy. One coordinator is left, so Personal's current error shows in
/// the composer, beside the composer's own failure. What Remove cut off stays named beside them
/// until the next Send.
@MainActor @Test(.timeLimit(.minutes(1)))
func whatRemoveCutOffStaysNamedUntilTheNextSendWithOneCoordinatorLeft() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await personalFixture.refuseUploads()
    print("IF6-T3 Remove's confirmation: \(coordinators.removal(work).message)")
    await workFixture.holdNextIdentity()
    chat.draft = "Invented: the shared holiday budget"
    await chat.attach(
      data: Data("invented budget".utf8), name: "Budget.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work's socket waiting for its identity") {
      await workFixture.identityHeld
    }
    try await eventually("Personal refused its copy") { chat.snapshots[personal]?.error != nil }
    print(
      "IF6-T3 before Remove: composer error=\(chat.error ?? "nil") Personal lane=\(chat.snapshots[personal]?.error ?? "nil")"
    )
    try await coordinators.remove(coordinators.removal(work))
    await workFixture.releaseIdentity()
    print("IF6-T3 Remove returned: composer error=\(chat.error ?? "nil")")
    let report = "Work did not get this message. It was removed."
    #expect(chat.error?.hasPrefix(report) == true)
    try await personalFixture.liveMessage(
      HistoryMessage(
        continuation: false, entryId: "if6-reply", finalChunk: true, role: .assistant,
        text: "Invented: noted."))
    try await eventually("Personal's reply") {
      chat.rows.contains { $0.row.text == "Invented: noted." }
    }
    print("IF6-T3 after Personal's next reply: composer error=\(chat.error ?? "nil")")
    #expect(chat.error == "\(report) Attachment storage is full")
    let refused = try #require(
      chat.snapshots[personal]?.rows.first { $0.delivery == .rejected }?.inputID)
    chat.draft = "Invented: a draft in progress"
    await chat.restore(refused)
    print("IF6-T3 after a refused Restore: composer error=\(chat.error ?? "nil")")
    #expect(
      chat.error
        == "\(report) Send or clear the current draft before restoring another message. Attachment storage is full"
    )
    await personalFixture.acceptUploads()
    await chat.send()
    try await eventually("Personal got the next message") {
      await submits(personalFixture).contains { $0.text == "Invented: a draft in progress" }
    }
    print("IF6-T3 after the next Send: composer error=\(chat.error ?? "nil")")
    #expect(chat.error?.contains(report) != true, "The next Send clears the report")
  }
}

// MARK: - The composer shows a coordinator's error only while it is current and saved alone

/// With Work saved alone, its address starts answering as a coordinator no profile has, so the
/// composer shows Work's line, which advises Remove. The user adds Personal, and the coordinator at
/// Work's address turns out to be Personal's, so Work's line above the feed names Personal and
/// points to Work's address. Nothing under the composer may still advise Remove, and once Work's
/// coordinator answers at Work's address again, nothing is left there.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLoneCoordinatorsErrorLeavesTheComposerOnceASecondIsAddedAndWhenItRecovers() async throws {
  let route = WorkRoute()
  try await withTwoFixtures(route: route) { coordinators, _, _, _ in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let chat = coordinators.chat
    let work = try #require(coordinators.profiles.first?.id)
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    await route.point(atPersonal: true)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work's line under the composer") {
      chat.error?.hasSuffix("Remove it and add it again.") == true
    }
    print("IF14-W1[Work alone] composer: \(chat.error ?? "nil")")
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("Work's line names Personal") {
      chat.laneError(work) == "This address now answers as Personal. Edit Work's address."
    }
    print(
      "IF14-W1[Personal added] Work's line: \(chat.laneError(work) ?? "nil") composer: \(chat.error ?? "nil")"
    )
    #expect(chat.error == nil, "The composer still shows Work's line from when it was alone")
    await route.point(atPersonal: false)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }
    print(
      "IF14-W1[Work recovered] Work's line: \(chat.laneError(work) ?? "nil") composer: \(chat.error ?? "nil")"
    )
    #expect(chat.laneError(work) == nil)
    #expect(chat.error == nil, "The composer still shows a line its lane no longer has")
  }
}

/// The other direction. Work's address answers as Personal while both are saved, so Work's error
/// is on Work's own line and not under the composer. The user removes Personal, which leaves Work
/// alone. Work's current error, the reinstall line once no saved coordinator answers there, then
/// shows under the composer, at once and after Work's next attempt.
@MainActor @Test(.timeLimit(.minutes(1)))
func aCoordinatorLeftAloneShowsItsCurrentErrorUnderTheComposer() async throws {
  let route = WorkRoute()
  try await withTwoFixtures(route: route) { coordinators, _, _, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await route.point(atPersonal: true)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work's line names Personal") {
      chat.laneError(work) == "This address now answers as Personal. Edit Work's address."
    }
    #expect(chat.error == nil, "With two coordinators each error shows on its own lane's line")
    try await coordinators.remove(coordinators.removal(personal))
    let atRemoval = chat.error
    await chat.reconnect(work)
    let afterAttempt = await within(6) {
      chat.error?.hasSuffix("Remove it and add it again.") == true
    }
    print(
      "IF14-W1[Personal removed] composer at once: \(atRemoval ?? "nil") after Work's next attempt: \(chat.error ?? "nil")"
    )
    #expect(afterAttempt, "Work's error never reached the composer")
    #expect(atRemoval == chat.laneError(work), "Work's current error waited for its next attempt")
  }
}

// MARK: - Overlapping lifecycle changes end where the last one asked

/// The app starts each scene-phase change as its own task, so an older change can finish after a
/// newer one. An inactive change overlapped by an active one leaves both lanes connected, so a
/// message to both can be sent.
@MainActor @Test(.timeLimit(.minutes(1)))
func anInactiveChangeOverlappedByAnActiveOneLeavesEveryLaneConnected() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    _ = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    @MainActor func connected() -> Int {
      chat.snapshots.values.filter { $0.connection == .connected }.count
    }
    var stranded: [Int] = []
    for attempt in 0..<20 {
      await coordinators.setActive(true)
      try await eventually("both connected before the overlap") { connected() == 2 }
      let inactive = Task { @MainActor in await coordinators.setActive(false) }
      let active = Task { @MainActor in await coordinators.setActive(true) }
      await inactive.value
      await active.value
      try await Task.sleep(for: .milliseconds(150))
      if chat.snapshots.values.contains(where: { $0.connection == .disconnected }) {
        stranded.append(attempt)
      }
    }
    print("IF5-S2-A stranded=\(stranded) / 20")
    #expect(stranded.isEmpty)
    try await eventually("both connected") { connected() == 2 }
    chat.draft = "Invented question for both coordinators"
    #expect(chat.canSend && chat.recipientLine == "To Work and Personal")
  }
}

/// The reverse: inactive, active and inactive again, overlapping, leave no lane live.
@MainActor @Test(.timeLimit(.minutes(1)))
func anActiveChangeOverlappedByAnInactiveOneLeavesNoLaneLive() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    _ = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    var revived: [Int] = []
    for attempt in 0..<20 {
      await coordinators.setActive(true)
      try await eventually("both connected before the overlap") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
      let first = Task { @MainActor in await coordinators.setActive(false) }
      let active = Task { @MainActor in await coordinators.setActive(true) }
      let last = Task { @MainActor in await coordinators.setActive(false) }
      await first.value
      await active.value
      await last.value
      try await Task.sleep(for: .milliseconds(100))
      if chat.snapshots.values.contains(where: { $0.connection != .disconnected }) {
        revived.append(attempt)
      }
    }
    print("IF5-S2-B revived=\(revived) / 20")
    #expect(revived.isEmpty)
  }
}

// MARK: - A restored source is withdrawn only while its coordinator still refuses it

/// Sends `text` with a file to both. Work places it and Personal refuses the file. Returns
/// Personal's refused input and the Send's bubble.
@MainActor private func sendToBothRefusedByPersonal(_ chat: ChatModel, _ text: String)
  async throws -> (source: String, bubble: String)
{
  chat.draft = text
  await chat.attach(data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
  await chat.send()
  var rejected: String?
  try await eventually("Work placed it and Personal refused it", within: reconnecting) {
    let receipts = chat.rows.first { $0.row.text == text }?.receipts ?? []
    guard receipts.first?.status == .placed, receipts.count == 2,
      case .pending(.rejected, let id?) = receipts[1].status
    else { return false }
    rejected = id
    return true
  }
  return (try #require(rejected), try #require(chat.rows.first { $0.row.text == text }?.id))
}

/// Personal is busy with a turn, so a follow-up waits there as Saved until the turn ends. Personal
/// refuses its copy of a message to both, and the user restores it. After the app goes inactive and
/// active, Check / retry gets the original Saved, and then the user sends the restored draft. The
/// original left the phone again, so it is never recorded withdrawn, and once Personal places it
/// the bubble reads Delivered there.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceSavedAgainBeforeItsCopyIsSentReadsDeliveredOncePlaced() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, _ in
    await personalFixture.refuseUploads()
    await personalFixture.holdPlacements()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    chat.mode = .followUp
    let (source, bubble) = try await sendToBothRefusedByPersonal(
      chat, "Invented: after this, book the boiler service")
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    @MainActor func connected() -> Int {
      chat.snapshots.values.filter { $0.connection == .connected }.count
    }
    try await eventually("both connected") { connected() == 2 }
    await chat.restore(source)
    #expect(chat.recipientLine == "To Personal")
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("both connected again") { connected() == 2 }
    await personalFixture.acceptUploads()
    await chat.retry(source)
    try await eventually("Personal saved the original") { lines().contains("Personal · Sent") }
    await chat.send()
    try await personalFixture.finishTurn()
    try await eventually("Personal placed the original and the copy") {
      await personalFixture.placedInputs().count == 2
        && chat.snapshots[personal]?.sends.values.allSatisfy {
          if case .pending = $0.progress { false } else { true }
        } == true
    }
    let placed = await personalFixture.placedInputs()
    print("IF5-S3-A placed=\(placed.map { $0.prefix(8) }) source=\(source.prefix(8)) \(lines())")
    #expect(!(placed.contains(source) && lines().contains("Not sent to Personal")))
    #expect(lines() == ["Work · Delivered", "Personal · Delivered"])
  }
}

/// The same with Check / retry and Send tapped one after the other, at a coordinator that places
/// each message at once. A retry that wrote the original before its copy was admitted gets it
/// placed, and it reads Delivered. One that had not written it is cancelled when the copy withdraws
/// the original, which then reads not sent and never reaches Personal.
@MainActor @Test(.timeLimit(.minutes(2)))
func aRestoredSourceRetriedAsItsCopyIsSentReadsDeliveredOncePlaced() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, _ in
    await personalFixture.refuseUploads()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let (source, bubble) = try await sendToBothRefusedByPersonal(
      chat, "Invented: the signed lease for both of you")
    let send = String(bubble.dropFirst("send:".count))
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    @MainActor func connected() -> Int {
      chat.snapshots.values.filter { $0.connection == .connected }.count
    }
    try await eventually("both connected", within: reconnecting) { connected() == 2 }
    await chat.restore(source)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("both connected again", within: reconnecting) { connected() == 2 }
    await personalFixture.acceptUploads()
    // Personal answers its first submit only once the copy is admitted. The answer ends that socket,
    // which would take Personal's lane down before the copy is saved.
    await personalFixture.holdNextSubmitReply()
    await chat.retry(source)
    await chat.send()
    await personalFixture.releaseSubmitReply()
    try await eventually("Personal placed or withdrew the original", within: reconnecting) {
      let progress = chat.snapshots[personal]?.sends[send]?.progress
      let submitted = await personalFixture.count()
      return progress == .placed && submitted == 2 || progress == .withdrawn && submitted >= 1
    }
    try await Task.sleep(for: .milliseconds(300))
    let atPersonal = await submits(personalFixture).map(\.inputId)
    print(
      "IF5-S3-B Personal got=\(atPersonal.map { $0.prefix(8) }) source=\(source.prefix(8)) \(lines())"
    )
    #expect(!(atPersonal.contains(source) && lines().contains("Not sent to Personal")))
    if atPersonal.contains(source) {
      #expect(lines() == ["Work · Delivered", "Personal · Delivered"])
      #expect(atPersonal.count == 2)
    } else {
      #expect(lines() == ["Work · Delivered", "Not sent to Personal"])
      #expect(atPersonal.count == 1, "Only the copy reached Personal")
    }
  }
}

/// Personal rejects its copy of a message to both but keeps it, as a coordinator whose turn ended
/// while saving it does, and the user restores that copy. When the app comes back, Personal reports
/// the original accepted. Sending the restored draft then leaves the original queued to reconcile,
/// and nothing records it withdrawn.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceTheCoordinatorAcceptsBeforeItsCopyIsSentStaysQueued() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    await personalFixture.holdPlacements()
    await personalFixture.rejectNextSubmitButKeepIt()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the gate code changed to 4410"
    chat.draft = text
    await chat.send()
    var rejected: String?
    try await eventually("Work placed it and Personal rejected it") {
      let receipts = chat.rows.first { $0.row.text == text }?.receipts ?? []
      guard receipts.first?.status == .placed, receipts.count == 2,
        case .pending(.rejected, let id?) = receipts[1].status
      else { return false }
      rejected = id
      return true
    }
    let source = try #require(rejected)
    let bubble = try #require(chat.rows.first { $0.row.text == text }?.id)
    let send = String(bubble.dropFirst("send:".count))
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    // A coordinator reports what it accepted before the history page that connects the lane.
    try await eventually("Personal reports the original accepted, and Send can go") {
      lines().contains("Personal · Sent") && chat.canSend
    }
    await chat.send()
    try await eventually("the copy at Personal") { await personalFixture.count() == 2 }
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    print("IF5-S3-C \(lines()) record=\(String(describing: chat.snapshots[personal]?.sends[send]))")
    #expect(try queuedRequests(outbox).contains { $0.inputId == source }, "Still queued")
    #expect(chat.snapshots[personal]?.sends[send]?.progress == .pending(.saved))
    #expect(lines() == ["Work · Delivered", "Personal · Sent"])
  }
}

// MARK: - The outbox keeps a coordinator's refusal until the input is written again

/// Waits up to `seconds` for `predicate`, without failing. Returns whether it held.
@MainActor private func within(_ seconds: Double, _ predicate: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if await predicate() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return await predicate()
}

/// Work refuses a message to it alone, and the user restores it. An edit of Work's address, to the
/// same coordinator, builds Work a new session before the restored copy is sent. The original is
/// withdrawn all the same, so its Check / retry never sends the message a second time.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceIsWithdrawnAfterAnAddressEditOnceItsCopyIsSent() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the signed contractor agreement"
    chat.setChip(work)
    chat.draft = text
    await chat.attach(
      data: Data("invented agreement".utf8), name: "Agreement.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    #expect(chat.recipientLine == "To Work")
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.3", port: 4001))
    try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }
    @MainActor func lines() -> [String] {
      chat.rows.filter { $0.row.role == .user && $0.row.text == text }.map { row in
        let which = row.row.inputID == original.inputId ? "original" : "copy"
        let status =
          row.receipts.isEmpty
          ? row.row.delivery?.rawValue ?? "nil"
          : row.receipts.map { $0.line(chat.name($0.lane)) }.joined(separator: ", ")
        return "\(which): \(status)"
      }
    }
    print("IF6-T2[edit] after the address edit: \(lines())")
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy left") { await workFixture.count() >= 1 }
    try await Task.sleep(for: .milliseconds(300))
    let stillQueued = try queuedRequests(outbox).contains { $0.inputId == original.inputId }
    print("IF6-T2[edit] after sending the copy: originalStillQueued=\(stillQueued) \(lines())")
    #expect(!stillQueued, "The original stayed queued after its copy was sent")
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    await chat.retry(original.inputId)
    _ = await within(3) { await workFixture.count() >= 2 }
    let got = await submits(workFixture)
    print(
      "IF6-T2[edit] after the original's Check / retry: Work received \(got.map(\.text)) \(lines())"
    )
    #expect(got.map(\.text) == [text], "Work got the restored message twice")
    #expect(lines().contains("original: Not sent to Work"))
  }
}

/// The same with one coordinator saved. The withdrawn original reads "Not sent" and offers no
/// Check / retry.
@MainActor @Test(.timeLimit(.minutes(1)))
func withOneCoordinatorARestoredSourceIsWithdrawnAfterAnAddressEdit() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let text = "Invented: renew the parking permit"
    chat.draft = text
    await chat.attach(
      data: Data("invented permit".utf8), name: "Permit.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.3", port: 4001))
    try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy left") { await workFixture.count() >= 1 }
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    @MainActor func originalRow() -> ChatRow? {
      chat.rows.first { $0.row.inputID == original.inputId }?.row
    }
    print(
      "IF6-T2[edit, one] after sending the copy: original row=\(originalRow()?.delivery?.rawValue ?? "gone")"
    )
    #expect(originalRow()?.delivery?.rawValue == "Not sent", "No Check / retry is offered")
    #expect(try !queuedRequests(outbox).contains { $0.inputId == original.inputId })
    await chat.retry(original.inputId)
    _ = await within(3) { await workFixture.count() >= 2 }
    let got = await submits(workFixture).map(\.text)
    print("IF6-T2[edit, one] after the original's Check / retry: Work received \(got)")
    #expect(got == [text], "Work got the restored message twice")
  }
}

/// Work refuses a message, and the user restores it. After the app goes inactive and active, Check
/// / retry of the original is refused again during its upload, so its submit is never written.
/// Sending the restored copy then withdraws the original, so Work gets the message once.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceRefusedAgainOnRetryIsWithdrawnOnceItsCopyIsSent() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let text = "Invented: the gas bill"
    chat.draft = text
    await chat.attach(data: Data("invented bill".utf8), name: "Bill.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    @MainActor func originalRow() -> String {
      chat.rows.first { $0.row.inputID == original.inputId }?.row.delivery?.rawValue ?? "gone"
    }
    await chat.restore(original.inputId)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }
    await chat.retry(original.inputId)
    try await eventually("the retry refused again") {
      chat.snapshots[work]?.error == "Attachment storage is full" && originalRow() != "Sending"
    }
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    print("IF6-T2[refused again] after Check / retry: original row=\(originalRow())")
    #expect(await workFixture.count() == 0, "The retry never wrote its submit")
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy left") { await workFixture.count() >= 1 }
    let row = originalRow()
    let stillQueued = try queuedRequests(outbox).contains { $0.inputId == original.inputId }
    print("IF6-T2[refused again] after sending the copy: original row=\(row) queued=\(stillQueued)")
    #expect(row == "Not sent")
    #expect(!stillQueued, "The original stayed queued after its copy was sent")
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    await chat.retry(original.inputId)
    _ = await within(3) { await workFixture.count() >= 2 }
    let got = await submits(workFixture).map(\.text)
    print("IF6-T2[refused again] after the original's Check / retry: Work received \(got)")
    #expect(got == [text], "Work got the restored message twice")
  }
}

/// Personal refuses its copy of a message to both, and the user restores it. Check / retry of the
/// original is cancelled by a trip to the background while it proves Personal's identity, so it
/// writes nothing. Back active, the user sends the restored copy. The original is withdrawn, so
/// nothing left on the phone can send Personal the text again.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceWhoseRetryWasCancelledIsWithdrawnOnceItsCopyIsSent() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    await personalFixture.refuseUploads()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: the gate code changed to 4410"
    let (source, bubble) = try await sendToBothRefusedByPersonal(chat, text)
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    @MainActor func connected() -> Int {
      chat.snapshots.values.filter { $0.connection == .connected }.count
    }
    try await eventually("both connected") { connected() == 2 }
    await chat.restore(source)
    await personalFixture.holdNextIdentity()
    await chat.retry(source)
    try await eventually("Personal's socket waiting for its identity") {
      await personalFixture.identityHeld
    }
    await coordinators.setActive(false)
    await personalFixture.releaseIdentity()
    await coordinators.setActive(true)
    try await eventually("both connected again") { connected() == 2 }
    await personalFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy at Personal") { await personalFixture.count() == 1 }
    try await Task.sleep(for: .milliseconds(300))
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    let stillQueued = try queuedRequests(outbox).contains { $0.inputId == source }
    print("IF6-T2[cancelled] lines=\(lines()) originalStillQueued=\(stillQueued)")
    #expect(!stillQueued, "The original stayed queued after its copy was sent")
    #expect(lines() == ["Work · Delivered", "Not sent to Personal"])
    await chat.retry(source)
    let session = try #require(chat.lanes.first { $0.id == personal }?.session)
    await session.retry(source)
    _ = await within(3) { await personalFixture.count() >= 2 }
    let atPersonal = await submits(personalFixture).map(\.text)
    print("IF6-T2[cancelled] after Check / retry: Personal received \(atPersonal)")
    #expect(atPersonal == [text], "Personal got the same text again")
  }
}

/// Sends `text` to both. Work places it and Personal rejects it. Returns Personal's rejected input
/// and the Send's bubble.
@MainActor private func sendToBothRejectedByPersonal(
  _ chat: ChatModel, _ personalFixture: FixtureCoordinator, _ text: String
) async throws -> (source: String, bubble: String) {
  await personalFixture.rejectSubmits()
  chat.draft = text
  await chat.send()
  var rejected: String?
  try await eventually("Work placed it and Personal rejected it") {
    let receipts = chat.rows.first { $0.row.text == text }?.receipts ?? []
    guard receipts.first?.status == .placed, receipts.count == 2,
      case .pending(.rejected, let id?) = receipts[1].status
    else { return false }
    rejected = id
    return true
  }
  await personalFixture.rejectSubmits(false)
  return (try #require(rejected), try #require(chat.rows.first { $0.row.text == text }?.id))
}

/// Check / retry of a restored original is still proving Personal's identity when the user sends
/// the restored copy. The copy wins: the original is withdrawn, and the retry never writes it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceRetriedButNotYetWrittenIsWithdrawnOnceItsCopyIsSent() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let (source, bubble) = try await sendToBothRejectedByPersonal(
      chat, personalFixture, "Invented: the plumber comes at noon")
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    await personalFixture.holdNextIdentity()
    await chat.retry(source)
    try await eventually("Personal's socket waiting for its identity") {
      await personalFixture.identityHeld
    }
    await chat.send()
    try await eventually("the copy at Personal") { await personalFixture.count() == 1 }
    await personalFixture.releaseIdentity()
    _ = await within(3) { await personalFixture.count() >= 2 }
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    let stillQueued = try queuedRequests(outbox).contains { $0.inputId == source }
    let writes = await submits(personalFixture).filter { $0.inputId == source }.count
    print(
      "IF6-T2[in flight] lines=\(lines()) originalStillQueued=\(stillQueued) writes of the original=\(writes) kept at Personal=\(await personalFixture.count())"
    )
    #expect(writes == 1, "The retry wrote the withdrawn original again")
    #expect(await personalFixture.count() == 1, "Only the copy reached Personal")
    #expect(!stillQueued)
    #expect(lines() == ["Work · Delivered", "Not sent to Personal"])
  }
}

/// Check / retry writes the restored original again, and Personal is slow to answer. The user sends
/// the restored copy meanwhile. Personal may hold the original now, so it stays queued until
/// Personal answers, and the bubble never reads "Not sent to Personal".
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredSourceWrittenAgainStaysQueuedUntilItsCoordinatorAnswers() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let (source, bubble) = try await sendToBothRejectedByPersonal(
      chat, personalFixture, "Invented: the boiler service is on Monday")
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    await personalFixture.holdNextSubmitReply()
    await chat.retry(source)
    try await eventually("Personal received the original again") {
      await personalFixture.count() == 1
    }
    await chat.send()
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    let stillQueued = try queuedRequests(outbox).contains { $0.inputId == source }
    print("IF6-T2[written] after sending the copy: originalStillQueued=\(stillQueued) \(lines())")
    #expect(stillQueued, "Personal may hold the original, so it was withdrawn too early")
    #expect(!lines().contains("Not sent to Personal"))
    await personalFixture.releaseSubmitReply()
    try await eventually("Personal's answer about the original") {
      lines() == ["Work · Delivered", "Personal · Sent"]
        || lines() == ["Work · Delivered", "Personal · Delivered"]
    }
    print("IF6-T2[written] once Personal answered: \(lines())")
    try await eventually("the copy at Personal") { await personalFixture.count() >= 2 }
    #expect(await personalFixture.count() == 2)
  }
}

// MARK: - With one coordinator, a withdrawn original reads not sent

/// One coordinator refuses a file, so the message needs attention. The user restores it and sends
/// the copy once uploads work. The original is withdrawn, so its row reads "Not sent" and no longer
/// offers Restore, before and after the app goes inactive and active.
@MainActor @Test(.timeLimit(.minutes(1)))
func withOneCoordinatorARestoredAndResentOriginalReadsNotSent() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    #expect(!chat.multiple)
    chat.draft = "Invented: the plumber's quote, attached"
    await chat.attach(data: Data("invented quote".utf8), name: "Quote.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy at Work and the original out of the outbox") {
      await workFixture.count() == 1
        && (try? queuedRequests(outbox))?.contains { $0.inputId == original.inputId } == false
    }
    @MainActor func originalRow() -> ChatRow? {
      chat.rows.first { $0.row.inputID == original.inputId }?.row
    }
    print("IF5-S4 original row delivery=\(originalRow()?.delivery?.rawValue ?? "gone")")
    #expect(originalRow().map { $0.delivery != .rejected } ?? true, "It still needs attention")
    #expect(originalRow()?.delivery?.rawValue == "Not sent")
    await chat.restore(original.inputId)
    #expect(chat.draft.isEmpty && chat.attachments.isEmpty, "Nothing is left to restore")
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }
    #expect(originalRow()?.delivery?.rawValue == "Not sent")
  }
}

/// With one coordinator saved, Restore fills the draft and its files and binds them to their
/// coordinator, with no chip drawn, as on `main`, and the text goes as typed. A cleared draft
/// leaves no recipient behind. Once another coordinator was removed the composer names recipients
/// again, so the restored draft shows its chip and its text stays literal.
@MainActor @Test(.timeLimit(.minutes(1)))
func restoreDrawsAChipOnlyWhileTheComposerNamesRecipients() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let text = "@Personal is copied on the invented lease"
    chat.draft = text
    await chat.attach(data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    #expect(chat.destination.chip == work, "Restore binds the draft to its coordinator")
    #expect(chat.shownChip == nil, "With one coordinator saved, Restore shows no chip")
    #expect(chat.draft == text && chat.attachments.count == 1)
    #expect(chat.addressing == .to([work], body: text))
    chat.draft = ""
    for file in chat.attachments { await chat.removeAttachment(file) }
    #expect(chat.destination.chip == nil, "A cleared restored draft binds nothing")

    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await coordinators.remove(
      coordinators.removal(try #require(coordinators.profiles.last?.id)))
    await chat.restore(original.inputId)
    #expect(chat.shownChip == work, "Once one was removed, Restore shows its chip")
    #expect(chat.addressing == .to([work], body: text))
  }
}

// MARK: - A restored or held message stays its source's when a coordinator is added

/// Work refuses a message with a file while it is the only coordinator saved, and the user
/// restores it. The draft is bound to Work, with no chip drawn. The user adds Personal before
/// tapping Send. Then the chip shows, the line reads "To Work", and the text is never read for
/// tags, so Work alone gets it and Personal gets nothing.
@MainActor private func restoreWithOneCoordinatorThenAddPersonal(_ text: String, _ tag: String)
  async throws
{
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    chat.draft = text
    await chat.attach(
      data: Data("Invented: Work's quarterly numbers".utf8), name: "Numbers.txt",
      mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    print(
      "IF6-T1[\(tag)] restored with one coordinator: recipient=\(chat.destination.chip.map(chat.name) ?? "none") chip=\(chat.shownChip.map(chat.name) ?? "none") draft=\(chat.draft)"
    )
    #expect(chat.destination.chip == work, "Restore binds the draft to Work")
    #expect(chat.shownChip == nil, "With one coordinator saved no chip is drawn")
    #expect(chat.draft == text && chat.attachments.map(\.reference.name) == ["Numbers.txt"])
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await workFixture.acceptUploads()
    print(
      "IF6-T1[\(tag)] after Add Personal: chip=\(chat.shownChip.map(chat.name) ?? "none") recipientLine=\(chat.recipientLine) canSend=\(chat.canSend)"
    )
    #expect(chat.shownChip == work && chat.recipientLine == "To Work")
    #expect(chat.addressing == .to([work], body: text), "The restored text stays literal")
    await chat.send()
    try await eventually("a submit arrived") {
      await workFixture.count() + personalFixture.count() >= 1
    }
    try await Task.sleep(for: .milliseconds(500))
    let workGot = await submits(workFixture).map(\.text)
    let personalGot = await submits(personalFixture)
    let personalChunks = await personalFixture.uploadCount()
    print(
      "IF6-T1[\(tag)] Work received \(workGot) Personal received \(personalGot.map(\.text)) files=\(personalGot.flatMap { $0.attachments ?? [] }.map(\.name)) uploadChunks=\(personalChunks)"
    )
    #expect(personalGot.isEmpty, "A message restored from Work's queue reached Personal")
    #expect(personalChunks == 0, "Work's file reached Personal")
    #expect(workGot == [text], "Work gets the restored text as it was")
    #expect(
      try !queuedRequests(outbox).contains { $0.inputId == original.inputId },
      "The original leaves Work's outbox once its copy was admitted")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aMessageRestoredWithOneCoordinatorStaysItsOnceAnotherIsAdded() async throws {
  try await restoreWithOneCoordinatorThenAddPersonal(
    "Invented: the board deck for Thursday", "untagged")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredTextNamingAnotherCoordinatorStaysLiteralOnceItIsAdded() async throws {
  try await restoreWithOneCoordinatorThenAddPersonal(
    "@Personal gets the invented numbers next week", "at-personal")
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredFileWithNoTextStaysItsSourcesOnceAnotherIsAdded() async throws {
  try await restoreWithOneCoordinatorThenAddPersonal("", "file only")
}

/// A message held from before the update, with no record of the address it was queued for, is
/// restored while Work is the only coordinator saved. Restore addresses it to no one until the user
/// chooses Work. The user adds Personal, then taps Send. The restored message stays Work's, so
/// Work alone gets it. Nothing shows that Work is the coordinator it was queued for, so it stays
/// held.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageRestoredWithOneCoordinatorStaysItsOnceAnotherIsAdded() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let text = "Invented: Work's held reorg memo"
    let hold = try heldQueue(
      [NativeRequestSubmit(inputId: "held-1", mode: .steer, text: text)], in: root)
    chat.holds.append(hold)
    let held = HeldMessage(
      queue: hold.queue.id, item: try #require(try await hold.store.items().first))
    await chat.restoreHeld(held)
    #expect(chat.draft.isEmpty && chat.owner(held) == nil, "Restore chose for the user")
    await chat.restoreHeld(held, for: work)
    print(
      "IF6-T1[legacy] restored with one coordinator: recipient=\(chat.destination.chip.map(chat.name) ?? "none") chip=\(chat.shownChip.map(chat.name) ?? "none") draft=\(chat.draft)"
    )
    #expect(chat.destination.chip == work && chat.shownChip == nil && chat.draft == text)
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    print("IF6-T1[legacy] after Add Personal: recipientLine=\(chat.recipientLine)")
    #expect(chat.shownChip == work && chat.recipientLine == "To Work")
    await chat.send()
    try await eventually("a submit arrived") {
      await workFixture.count() + personalFixture.count() >= 1
    }
    try await Task.sleep(for: .milliseconds(500))
    let workGot = await submits(workFixture).map(\.text)
    let personalGot = await submits(personalFixture).map(\.text)
    let left = try await hold.store.items().map(\.id)
    print("IF6-T1[legacy] Work received \(workGot) Personal received \(personalGot) held=\(left)")
    #expect(personalGot.isEmpty, "A message held for Work reached Personal")
    #expect(workGot == [text])
    #expect(
      left == ["held-1"], "A copy sent where the user chose took the original out of the hold")
  }
}

/// The single-address build left a queue, a message with a file, for a coordinator that is not
/// updated yet, so the migrated profile stays unpaired. The body gets the profile, Personal's
/// fixture, at port 4002, and the held message's text once the message shows and pairing failed.
@MainActor private func withAnUnpairedHeldMessage(
  _ body: (Coordinators, CoordinatorProfile, FixtureCoordinator, String) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let support = root.appending(path: "Support")
  let suite = "unpaired-held-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  defaults.set("4001", forKey: "coordinatorPort")
  let key = SHA256.hash(data: Data("100.64.1.2:4001".utf8)).map { String(format: "%02x", $0) }
    .joined()
  let old = support.appending(path: "Agent/Outbox/\(key)")
  let attachment = try await AttachmentStore(directory: old.appending(path: "Attachments"))
    .stage(
      data: Data("Invented Work salary bands".utf8), name: "Bands.txt", mediaType: "text/plain"
    )
    .reference
  let text = "Invented: draft the Work salary review"
  try JSONEncoder().encode([
    NativeRequestSubmit(
      attachments: [attachment], inputId: UUID().uuidString, mode: .steer, text: text)
  ]).write(to: old.appending(path: "pending.json"))
  let oldCoordinator = FixtureCoordinator()
  await oldCoordinator.dropIdentify()
  let personalFixture = FixtureCoordinator()
  let (oldListener, oldPort) = try await listen(oldCoordinator)
  defer { oldListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: support,
    caches: root.appending(path: "Caches"),
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(to: address.port == 4002 ? personalPort : oldPort, using: .tcp))
    })
  let chat = coordinators.chat
  let migrated = try #require(coordinators.profiles.first)
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await oldCoordinator.stop()
    await personalFixture.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("the held message shows") { !chat.held.isEmpty }
    try await eventually("pairing refused") { coordinators.pairingError[migrated.id] != nil }
    try await body(coordinators, migrated, personalFixture, text)
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The migrated coordinator is not updated yet, so it stays unpaired at the address the held
/// message was queued for. Restore addresses the message to no one and offers no coordinator, since
/// none is paired. The user adds Personal, which is up to date, at another address. Restore still
/// addresses it to no one and offers only Personal. Nothing reaches Personal, and the message stays
/// in its hold.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageOfAnUnpairedCoordinatorStaysItsOnceAnotherIsAdded() async throws {
  try await withAnUnpairedHeldMessage { coordinators, migrated, personalFixture, text in
    let chat = coordinators.chat
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    print(
      "IF6-T1[unpaired] Restore: draft=\(chat.draft.debugDescription) offered=\(chat.heldChoices.map(\.name.description))"
    )
    #expect(chat.draft.isEmpty && chat.heldChoices.isEmpty)
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    let personal = try #require(coordinators.profiles.last?.id)
    try await eventually("Personal connected") {
      chat.snapshots[personal]?.connection == .connected
    }
    await chat.restoreHeld(held)
    print(
      "IF6-T1[unpaired] after Add Personal, Restore: draft=\(chat.draft.debugDescription) offered=\(chat.heldChoices.map(\.name.description))"
    )
    #expect(chat.draft.isEmpty, "Restore addressed it to Personal without the user choosing")
    #expect(chat.heldChoices.map(\.id) == [personal], "Restore offered an unpaired coordinator")
    await chat.send()
    try await Task.sleep(for: .milliseconds(500))
    let got = await submits(personalFixture)
    print(
      "IF6-T1[unpaired] Personal received \(got.map(\.text)) files=\(got.flatMap { $0.attachments ?? [] }.map(\.name)) held=\(chat.held.map(\.item.text))"
    )
    #expect(got.isEmpty, "A message held for the migrated coordinator reached Personal")
    #expect(await personalFixture.uploadCount() == 0)
    #expect(chat.held.map(\.item.text) == [text], "It stays in its hold")
    #expect(migrated.pin == nil)
  }
}

/// The same held message with Personal added. The user chooses Personal for it, so the line reads
/// "To Personal", and sends it. Personal gets it, as the line said. Nothing shows that Personal is
/// the coordinator it was queued for, so the message stays in its hold.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageSentWithoutItsUnpairedCoordinatorStaysHeld() async throws {
  try await withAnUnpairedHeldMessage { coordinators, migrated, personalFixture, text in
    let chat = coordinators.chat
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    let personal = try #require(coordinators.profiles.last?.id)
    try await eventually("Personal connected") {
      chat.snapshots[personal]?.connection == .connected
    }
    await chat.restoreHeld(try #require(chat.held.first), for: personal)
    print(
      "IF10-1 before Send: line=\(chat.recipientLine) canSend=\(chat.canSend) draft=\(chat.draft.debugDescription)"
    )
    #expect(chat.recipientLine == "To Personal" && chat.canSend)
    await chat.send()
    try await eventually("Personal got it") { await personalFixture.count() == 1 }
    try await Task.sleep(for: .milliseconds(300))
    let hold = try #require(chat.holds.first)
    let heldForMigrated = try await hold.store.items().map(\.text)
    let got = await submits(personalFixture).map(\.text)
    print(
      "IF10-1 after Send: Personal=\(got) heldFor\(migrated.name)=\(heldForMigrated) modelHeld=\(chat.held.map(\.item.text))"
    )
    #expect(got == [text], "Personal did not get what the line named it for")
    #expect(heldForMigrated == [text], "The held message left the hold its coordinator never got")
    #expect(chat.held.map(\.item.text) == [text], "The held row is gone")
  }
}

// MARK: - A recipient's status follows its coordinator's latest word

/// Personal rejects its copy of a message to both but keeps it, and the user restores that copy.
/// Back active, Personal reports the original accepted, or placed once its turn ended, while this
/// phone cannot save its outbox or its ledger. Sending the restored copy once storage works again
/// never withdraws an original Personal holds. It stays queued and reads Saved, or reads Delivered.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func anAcknowledgementThisPhoneCouldNotSaveStillKeepsTheOriginal(placed: Bool, storageFails: Bool)
  async throws
{
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    await personalFixture.holdPlacements()
    await personalFixture.rejectNextSubmitButKeepIt()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "Invented: renew the greenhouse lease"
    chat.draft = text
    await chat.send()
    try await eventually("Personal rejected the original") {
      chat.snapshots[personal]?.rows.contains { $0.delivery == .rejected } == true
    }
    let directory = ProfileDirectory(personal, applicationSupport: root, caches: root)
    let original = try #require(try queuedRequests(directory.outbox).first)
    await chat.restore(original.inputId)
    // A placement writes the ledger in the profile's folder, an acceptance the outbox in its own.
    let blocked = placed ? directory.root : directory.outbox.deletingLastPathComponent()
    if storageFails {
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    }
    await coordinators.setActive(false)
    if placed { try await personalFixture.finishTurn() }
    await coordinators.setActive(true)
    try await eventually("Personal acknowledged the original") {
      guard chat.snapshots[personal]?.connection == .connected else { return false }
      if placed {
        return chat.snapshots[personal]?.sends.values.contains { $0.progress == .placed } == true
      }
      return chat.snapshots[personal]?.rows.contains {
        $0.inputID == original.inputId && $0.delivery == .saved
      } == true
    }
    let saved = try JSONDecoder().decode(
      [OutboxItem].self, from: Data(contentsOf: directory.outbox))
    print(
      "IF7-V1[placed=\(placed) storageFails=\(storageFails)] acknowledged: refusedOnDisk=\(saved.first?.refused == true)"
    )
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    await chat.send()
    try await eventually("the copy at Personal") { await personalFixture.count() == 2 }
    try await Task.sleep(for: .milliseconds(200))
    let bubble = try #require(chat.rows.first { $0.row.text == text && $0.receipts.count == 2 })
    let lines = bubble.receipts.map { $0.line(chat.name($0.lane)) }
    let stillQueued = try queuedRequests(directory.outbox).contains {
      $0.inputId == original.inputId
    }
    print(
      "IF7-V1[placed=\(placed) storageFails=\(storageFails)] after the copy: originalQueued=\(stillQueued) \(lines)"
    )
    #expect(!lines.contains("Not sent to Personal"), "Personal acknowledged the original")
    if !placed { #expect(stillQueued, "The accepted original must remain queued until placed") }
    #expect(lines == ["Work · Delivered", placed ? "Personal · Delivered" : "Personal · Sent"])
  }
}

/// Personal rejects its copy of a message to both while this phone cannot save its outbox, and the
/// user restores it. The phone still holds that refusal, through a trip to the background too, so
/// sending the restored copy withdraws the original and its Check / retry sends nothing.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
func aRefusalThisPhoneCouldNotSaveStillWithdrawsTheOriginal(
  storageFails: Bool, backgrounded: Bool
) async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await personalFixture.rejectSubmits()
    await personalFixture.holdNextIdentity()
    chat.draft = "Invented: cancel the garden service"
    await chat.send()
    try await eventually("Personal's identity held") { await personalFixture.identityHeld }
    let directory = ProfileDirectory(personal, applicationSupport: root, caches: root)
    let original = try #require(try queuedRequests(directory.outbox).first)
    let blocked = directory.outbox.deletingLastPathComponent()
    if storageFails {
      try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blocked.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    }
    await personalFixture.releaseIdentity()
    try await eventually("Personal refused the original") {
      chat.snapshots[personal]?.rows.contains {
        $0.inputID == original.inputId && $0.delivery == .rejected
      } == true
    }
    let refusedOnDisk =
      try queuedItems(directory.outbox).first?.refused == true
    await chat.restore(original.inputId)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
    if backgrounded {
      await coordinators.setActive(false)
      await coordinators.setActive(true)
      try await eventually("both connected again") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    }
    await personalFixture.rejectSubmits(false)
    await chat.send()
    try await eventually("the restored copy at Personal") { await personalFixture.count() == 1 }
    let originalQueued = try queuedRequests(directory.outbox).contains {
      $0.inputId == original.inputId
    }
    try await eventually("Personal connected after the copy") {
      chat.snapshots[personal]?.connection == .connected
        && chat.snapshots[personal]?.rows.contains {
          $0.inputID == original.inputId && $0.delivery != .sending
        } == true
    }
    await chat.retry(original.inputId)
    try await Task.sleep(for: .milliseconds(500))
    print(
      "IF7-V1[storageFails=\(storageFails) backgrounded=\(backgrounded)] refusedOnDisk=\(refusedOnDisk) originalQueuedAfterRestoreSend=\(originalQueued) PersonalKept=\(await personalFixture.count())"
    )
    #expect(!originalQueued, "The original stayed queued after its copy was sent")
    #expect(await personalFixture.count() == 1, "Personal got the message twice")
  }
}

/// Sends `text` to both while Personal is busy. Personal rejects its copy but keeps it, as a
/// coordinator whose turn ended while saving it does. Returns that copy and the Send's bubble.
@MainActor private func sendToBothKeptByPersonal(_ chat: ChatModel, _ text: String) async throws
  -> (source: String, bubble: String)
{
  chat.draft = text
  await chat.send()
  var rejected: String?
  try await eventually("Work placed it and Personal rejected it") {
    let receipts = chat.rows.first { $0.row.text == text }?.receipts ?? []
    guard receipts.first?.status == .placed, receipts.count == 2,
      case .pending(.rejected, let id?) = receipts[1].status
    else { return false }
    rejected = id
    return true
  }
  return (try #require(rejected), try #require(chat.rows.first { $0.row.text == text }?.id))
}

/// The user restores Personal's kept copy and sends the restored draft at once, so the original
/// is withdrawn. When Personal's turn ends it places what it kept. The bubble then reads Delivered
/// there, never "Not sent to Personal". Personal holding the text twice is the coordinator's doing.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWithdrawnOriginalItsCoordinatorPlacesLaterReadsDelivered() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, root in
    await personalFixture.holdPlacements()
    await personalFixture.rejectNextSubmitButKeepIt()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let (source, bubble) = try await sendToBothKeptByPersonal(
      chat, "Invented R7: the gate code changed to 4410")
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    await chat.send()
    try await eventually("the copy reached Personal") { await personalFixture.count() == 2 }
    try await Task.sleep(for: .milliseconds(300))
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    let originalQueued = try queuedRequests(outbox).contains { $0.inputId == source }
    print("IF7-V1[placed later] after the copy: \(lines()) originalQueued=\(originalQueued)")
    try await personalFixture.finishTurn()
    _ = await within(3) { lines() == ["Work · Delivered", "Personal · Delivered"] }
    let placed = await personalFixture.placedInputs()
    print(
      "IF7-V1[placed later] once Personal placed it: \(lines()) sourcePlaced=\(placed.contains(source))"
    )
    #expect(!originalQueued)
    #expect(
      lines() != ["Work · Delivered", "Not sent to Personal"] || !placed.contains(source),
      "The bubble reads Not sent to Personal for an input Personal placed")
    #expect(lines() == ["Work · Delivered", "Personal · Delivered"])
  }
}

/// The same original withdrawn while Personal still holds it unplaced. A refusal heard about it
/// afterwards changes nothing and is no error. Personal's next observation includes it, so once
/// the app comes back the bubble reads Saved there, and Delivered once Personal places it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aWithdrawnOriginalItsCoordinatorStillHoldsReadsSavedThenDelivered() async throws {
  try await withTwoFixtures { coordinators, _, personalFixture, _ in
    await personalFixture.holdPlacements()
    await personalFixture.rejectNextSubmitButKeepIt()
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let (source, bubble) = try await sendToBothKeptByPersonal(
      chat, "Invented: the hedge trimming is on Tuesday")
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    await chat.send()
    try await eventually("the original withdrawn") {
      lines() == ["Work · Delivered", "Not sent to Personal"]
    }
    try await personalFixture.emitOnObserver(
      .rejected(.init(inputId: source, message: "Invented: this saved input was stopped")))
    try await Task.sleep(for: .milliseconds(300))
    let row = chat.snapshots[personal]?.rows.first { $0.inputID == source }?.delivery
    print(
      "IF7-V1[held] after a later refusal: \(lines()) row=\(row?.rawValue ?? "gone") error=\(chat.snapshots[personal]?.error ?? "nil")"
    )
    #expect(lines() == ["Work · Delivered", "Not sent to Personal"])
    #expect(row == .withdrawn, "A withdrawn original offers no Restore")
    #expect(chat.snapshots[personal]?.error == nil)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("both connected again") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    let observed: [[String]] = await personalFixture.received().compactMap {
      if case .observe(let request) = $0 { request.inputIds } else { nil }
    }
    let watched = observed.last ?? []
    _ = await within(3) { lines() == ["Work · Delivered", "Personal · Sent"] }
    print("IF7-V1[held] back active: \(lines()) watched=\(watched.contains(source))")
    #expect(watched.contains(source), "Personal's observation leaves out the withdrawn original")
    #expect(lines() == ["Work · Delivered", "Personal · Sent"])
    try await personalFixture.finishTurn()
    _ = await within(3) { lines() == ["Work · Delivered", "Personal · Delivered"] }
    print("IF7-V1[held] once Personal placed it: \(lines())")
    #expect(lines() == ["Work · Delivered", "Personal · Delivered"])
  }
}

// MARK: - Restore keeps what the user added while it copied the files

/// Work, the only coordinator, refuses a message with large files, and the user taps Restore.
/// While the phone copies the files into the draft, the user types or attaches a file. Restore
/// then puts the restored text before what was typed, with a blank line between, and its files
/// before the one attached, as on `main`. Nothing the user put in the composer is dropped.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["typed", "attached", "typed-eight-files"])
func restoreKeepsWhatTheUserAddedWhileItCopied(_ what: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    await workFixture.refuseUploads()
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    let work = try #require(coordinators.profiles.first?.id)
    let chat = coordinators.chat
    try await eventually("Work connected") { chat.snapshots[work]?.connection == .connected }
    let count = what == "typed" ? 1 : 8
    let big = Data(repeating: 0x41, count: (count == 8 ? 16 : 12) * 1024 * 1024)
    let restoredText = "Invented: the scanned lease"
    let names = (0..<count).map { $0 == 0 ? "Lease.pdf" : "Lease\($0).pdf" }
    chat.draft = restoredText
    for name in names {
      await chat.attach(data: big, name: name, mediaType: "application/pdf")
    }
    await chat.send()
    try await eventually("Work refused it") { chat.rows.contains { $0.row.delivery == .rejected } }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    let restoring = Task { @MainActor in await chat.restore(original.inputId) }
    await Task.yield()
    let stillCopying = chat.restoredFrom == nil && chat.draft.isEmpty
    let typed = "Invented: also tell the landlord the boiler is fixed"
    if what.hasPrefix("typed") {
      chat.draft = typed
    } else {
      await chat.attach(
        data: Data("invented receipt".utf8), name: "Receipt.txt", mediaType: "text/plain")
    }
    let filledFirst = chat.restoredFrom != nil
    await restoring.value
    print(
      "IF7-V3[\(what)] copying when the user acted=\(stillCopying) filled first=\(filledFirst) draft=\(chat.draft.debugDescription) files=\(chat.attachments.map(\.reference.name)) error=\(chat.error ?? "nil")"
    )
    #expect(stillCopying && !filledFirst, "The user acted after Restore filled the composer")
    if what.hasPrefix("typed") {
      #expect(chat.draft.contains("boiler"), "The text the user typed is gone")
      #expect(chat.draft == restoredText + "\n\n" + typed)
      #expect(chat.attachments.map(\.reference.name) == names)
    } else {
      #expect(
        chat.attachments.map(\.reference.name).contains("Receipt.txt"),
        "The file the user attached is gone")
      #expect(chat.draft == restoredText)
      #expect(chat.attachments.map(\.reference.name) == names + ["Receipt.txt"])
    }
    #expect(chat.destination.chip == work)
  }
}

/// With Work and Personal saved, the user taps Restore on Work's refused message, then picks
/// Personal and types while the phone copies the files. Restore never puts a note for Personal into
/// Work's restored message, nor Work's message under Personal. The composer keeps what the user
/// added, Restore says why it did not fill it, its copies go, and Work's original stays queued.
@MainActor @Test(.timeLimit(.minutes(1)))
func restoreLeavesADraftAddressedElsewhereMeanwhileAlone() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await workFixture.refuseUploads()
    let big = Data(repeating: 0x42, count: 16 * 1024 * 1024)
    chat.setChip(work)
    chat.draft = "Invented: Work's scanned contracts"
    for index in 0..<8 {
      await chat.attach(data: big, name: "Contract\(index).pdf", mediaType: "application/pdf")
    }
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    let drafts = root.appending(path: "Agent/Drafts")
    let draftFiles = { (try? FileManager.default.contentsOfDirectory(atPath: drafts.path)) ?? [] }
    let before = draftFiles().count
    let restoring = Task { @MainActor in await chat.restore(original.inputId) }
    await Task.yield()
    let stillCopying = chat.restoredFrom == nil
    chat.choose(personal)
    let note = "Invented: a note for Personal only"
    chat.draft = note
    await restoring.value
    print(
      "IF7-V3[elsewhere] copying=\(stillCopying) chip=\(chat.destination.chip.map(chat.name) ?? "none") draft=\(chat.draft.debugDescription) files=\(chat.attachments.map(\.reference.name)) error=\(chat.error ?? "nil") draft files \(before)->\(draftFiles().count)"
    )
    #expect(stillCopying, "The user acted after Restore filled the composer")
    #expect(chat.destination.chip == personal && chat.draft == note && chat.attachments.isEmpty)
    #expect(chat.error == "Send or clear the current draft before restoring another message.")
    #expect(draftFiles().count == before, "Restore left its copies in the drafts folder")
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("Personal got the note") { await personalFixture.count() == 1 }
    try await Task.sleep(for: .milliseconds(300))
    #expect(await submits(personalFixture).map(\.text) == [note])
    #expect(await workFixture.count() == 0, "Work got the note meant for Personal")
    #expect(try queuedRequests(outbox).contains { $0.inputId == original.inputId })
  }
}

// MARK: - A restored draft's text is never a tag

/// Sends `text` with a file to Work alone, which refuses the file, and restores it. Returns
/// Work's original.
@MainActor private func restoreWorkOnlyMessage(
  _ chat: ChatModel, _ workFixture: FixtureCoordinator, _ text: String, root: URL
) async throws -> NativeRequestSubmit {
  let work = try #require(chat.profiles.first?.id)
  await workFixture.refuseUploads()
  chat.setChip(work)
  chat.draft = text
  await chat.attach(
    data: Data("Invented: Work board deck".utf8), name: "Deck.txt", mediaType: "text/plain")
  await chat.send()
  try await eventually("Work refused it") {
    chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
  }
  let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
  let original = try #require(try queuedRequests(outbox).first)
  await chat.restore(original.inputId)
  return original
}

private let restoredTagTexts = [
  "@Personal invented: forward Work's board deck to the auditors", "@Pers",
]

/// Work refuses a message the user sent it alone, whose text starts with a tag, and the user
/// restores it. The chip's ⓧ makes it a message to every coordinator, as the ⓧ's hint says, and
/// the restored text stays literal. The line reads "To Work and Personal", no picker opens, a key
/// typed at its end promotes nothing, and each coordinator gets the text as it was.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: restoredTagTexts)
func aRestoredDraftsTextStaysLiteralOnceItsChipIsRemoved(_ text: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let original = try await restoreWorkOnlyMessage(chat, workFixture, text, root: root)
    let tag = text == "@Pers" ? "lone tag" : "tag and text"
    print(
      "IF7-V4[\(tag)] restored: chip=\(chat.shownChip.map(chat.name) ?? "none") line=\(chat.recipientLine)"
    )
    // The chip's ⓧ, whose hint reads "Removes the recipient, so the message goes to every
    // coordinator."
    chat.removeChip()
    print(
      "IF7-V4[\(tag)] after the chip's ⓧ: line=\(chat.recipientLine) picker=\(chat.pickerMatches.map(\.name.description))"
    )
    #expect(chat.recipientLine == "To Work and Personal")
    #expect(chat.pickerMatches.isEmpty, "The picker offers to replace the restored text")
    #expect(!chat.addresses(personal), "A tag in Work's restored text holds Personal's Remove")
    chat.draft += "."
    chat.promoteTypedTag()
    print(
      "IF7-V4[\(tag)] after one more key: chip=\(chat.destination.chip.map(chat.name) ?? "none") line=\(chat.recipientLine) draft=\(chat.draft.debugDescription)"
    )
    #expect(chat.destination.chip == nil && chat.draft == text + ".")
    #expect(chat.addressing == .to([work, personal], body: text + "."))
    await workFixture.acceptUploads()
    await chat.send()
    _ = await within(3) { await workFixture.count() + personalFixture.count() == 2 }
    let workGot = await submits(workFixture).map(\.text)
    let personalGot = await submits(personalFixture)
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    print(
      "IF7-V4[\(tag)] Work received \(workGot) Personal received \(personalGot.map(\.text)) files=\(personalGot.flatMap { $0.attachments ?? [] }.map(\.name)) Work's original queued=\(try queuedRequests(outbox).contains { $0.inputId == original.inputId })"
    )
    #expect(personalGot.isEmpty || !workGot.isEmpty, "Only Personal got Work's restored message")
    #expect(workGot == [text + "."] && personalGot.map(\.text) == [text + "."])
  }
}

/// The same restored draft. After the chip's ⓧ the user types "@Work " at its start. A restored
/// draft's text is literal for good, so the typed tag stays text, the picker stays closed, and the
/// draft goes to every coordinator as written.
@MainActor @Test(.timeLimit(.minutes(1)))
func aTagTypedAtTheStartOfARestoredDraftStaysLiteral() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "@Personal invented: forward Work's board deck to the auditors"
    _ = try await restoreWorkOnlyMessage(chat, workFixture, text, root: root)
    chat.removeChip()
    var offered: [String] = []
    for (offset, character) in "@Work ".enumerated() {
      chat.draft.insert(character, at: chat.draft.index(chat.draft.startIndex, offsetBy: offset))
      chat.promoteTypedTag()
      offered += chat.pickerMatches.map(\.name.description)
    }
    print(
      "IF8-W2[typed at the start] chip=\(chat.destination.chip.map(chat.name) ?? "none") picker=\(offered) line=\(chat.recipientLine) draft=\(chat.draft.debugDescription)"
    )
    #expect(chat.destination.chip == nil && chat.draft == "@Work " + text)
    #expect(offered.isEmpty, "The picker opened over a restored draft")
    #expect(chat.recipientLine == "To Work and Personal")
    #expect(chat.addressing == .to([work, personal], body: "@Work " + text))
  }
}

/// Work refuses a message whose text is a heading line, then "@Personal …", and the user restores
/// it and removes its chip. Deleting the heading leaves "@Personal " at the start, but it is the
/// restored text's own, so it stays literal. Both coordinators get the text and the file as they
/// are, and nothing becomes Personal's alone.
@MainActor @Test(.timeLimit(.minutes(1)))
func deletingARestoredDraftsHeadingPromotesNothing() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let heading = "Invented memo heading\n"
    let body = "@Personal invented quotation from Work's meeting"
    _ = try await restoreWorkOnlyMessage(chat, workFixture, heading + body, root: root)
    chat.removeChip()
    print(
      "IF8-W2[heading] before deletion: \(chat.recipientLine), text=\(chat.draft.debugDescription)")
    chat.draft.removeFirst(heading.count)
    chat.promoteTypedTag()
    print(
      "IF8-W2[heading] after deleting it: \(chat.recipientLine), text=\(chat.draft.debugDescription), chip=\(chat.destination.chip.map(chat.name) ?? "none")"
    )
    #expect(chat.destination.chip == nil)
    #expect(chat.addressing == .to([work, personal], body: body))
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("Personal got it") { await personalFixture.count() == 1 }
    _ = await within(3) { await workFixture.count() == 1 }
    let atWork = await submits(workFixture)
    let atPersonal = await submits(personalFixture)
    print(
      "IF8-W2[heading] wire: Work=\(atWork.map(\.text)) Personal=\(atPersonal.map(\.text)) files=\(atWork.flatMap { $0.attachments ?? [] }.map(\.name)) \(atPersonal.flatMap { $0.attachments ?? [] }.map(\.name))"
    )
    #expect(atWork.map(\.text) == [body] && atPersonal.map(\.text) == [body])
    #expect(atWork.flatMap { $0.attachments ?? [] }.map(\.name) == ["Deck.txt"])
    #expect(atPersonal.flatMap { $0.attachments ?? [] }.map(\.name) == ["Deck.txt"])
  }
}

/// The user removes a restored draft's chip, deletes the "@" of its leading "@Personal" and types
/// it again, one edit each, as the field reports them. The tag is still the restored text's own,
/// so the draft stays literal and goes to both coordinators as written.
@MainActor @Test(.timeLimit(.minutes(1)))
func retypingTheAtSignOfARestoredTagPromotesNothing() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "@Personal invented: forward Work's board deck to the auditors"
    _ = try await restoreWorkOnlyMessage(chat, workFixture, text, root: root)
    chat.removeChip()
    chat.draft.removeFirst()
    chat.promoteTypedTag()
    chat.draft.insert("@", at: chat.draft.startIndex)
    chat.promoteTypedTag()
    print(
      "IF8-W2[retyped @] chip=\(chat.destination.chip.map(chat.name) ?? "none") line=\(chat.recipientLine) draft=\(chat.draft.debugDescription)"
    )
    #expect(chat.destination.chip == nil, "One retyped @ promoted Work's restored text to a chip")
    #expect(chat.draft == text, "The restored text changed")
    #expect(chat.addressing == .to([work, personal], body: text))
  }
}

/// Work refuses a message whose text is a heading line, then "@Personal …", and the user restores
/// it and removes its chip. Send empties the composer at its tap. While it copies the message for
/// both coordinators, the user enters the text again without the heading. Send delivers the
/// restored message and withdraws Work's original, and the draft entered meanwhile stays. Send did
/// not clear that draft, so it is still the restored one: a key typed after Send promotes nothing,
/// and the next Send gives both coordinators the text as written. Once a Send clears the draft, a
/// tag the user types becomes the chip again.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredDraftEditedWhileItsSendCopiesStaysLiteral() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let heading = "Invented memo heading\n"
    let body = "@Personal invented quotation from Work's memo"
    let original = try await restoreWorkOnlyMessage(chat, workFixture, heading + body, root: root)
    chat.removeChip()
    await workFixture.acceptUploads()
    let observed = await observes(workFixture) + observes(personalFixture)
    let sending = chat.startSend()
    await Task.yield()
    try #require(chat.admitting, "The edit comes while Send copies the message")
    try #require(chat.draft.isEmpty, "Send takes the text at its tap")
    chat.draft = body
    chat.promoteTypedTag()
    let during = chat.recipientLine
    await sending?.value
    // The fixtures close each accepted submit's socket unanswered, so both lanes reconnect, and
    // until then the line says which is not connected instead of naming the recipients.
    try await eventually("both observe again") {
      let again = await observes(workFixture) + observes(personalFixture)
      return again >= observed + 2
        && chat.snapshots.values.allSatisfy { $0.connection == .connected }
    }
    let after = chat.recipientLine
    chat.draft += "."
    chat.promoteTypedTag()
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let originalQueued = try queuedRequests(outbox).contains { $0.inputId == original.inputId }
    print(
      "IF9-Y1 during the Send: \(during); after it: \(after); one more key: chip=\(chat.destination.chip.map(chat.name) ?? "none") line=\(chat.recipientLine) draft=\(chat.draft.debugDescription) originalQueued=\(originalQueued)"
    )
    #expect(during == "To Work and Personal" && after == "To Work and Personal")
    #expect(chat.destination.chip == nil, "The restored text's own tag became the chip after Send")
    #expect(chat.addressing == .to([work, personal], body: body + "."))
    #expect(!originalQueued, "Send carried the restored message unchanged, yet the original stays")
    await chat.send()
    try await eventually("both got the next Send") {
      await workFixture.count() + personalFixture.count() == 4
    }
    let atWork = await submits(workFixture).map(\.text)
    let atPersonal = await submits(personalFixture).map(\.text)
    print("IF9-Y1 wire: Work=\(atWork) Personal=\(atPersonal)")
    #expect(atWork == [heading + body, body + "."], "Work did not get the text as written")
    #expect(atPersonal == [heading + body, body + "."])
    chat.draft = "@Personal "
    chat.promoteTypedTag()
    #expect(chat.destination.chip == personal, "A tag typed once Send cleared the draft stays text")
  }
}

/// Work refuses a message whose text starts with "@Personal", and the user restores it and removes
/// its chip. The user empties the composer, deleting the text and then the restored file if there
/// is one. That ends the restored draft, and the field's Undo never reaches back past it. The
/// original stays queued and still needs attention, so the user restores it again. Its text is
/// literal again, and with the chip removed both coordinators get it as written, which withdraws
/// the original.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["its text", "its text, then its file"])
func anEmptiedRestoredDraftLeavesItsOriginalToRestoreAgain(_ emptied: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let text = "@Personal invented: forward Work's board deck to the auditors"
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let withFile = emptied == "its text, then its file"
    let original: NativeRequestSubmit
    if withFile {
      original = try await restoreWorkOnlyMessage(chat, workFixture, text, root: root)
    } else {
      await workFixture.rejectSubmits()
      chat.setChip(work)
      chat.draft = text
      await chat.send()
      try await eventually("Work refused it") {
        chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
      }
      await workFixture.rejectSubmits(false)
      original = try #require(try queuedRequests(outbox).first)
      await chat.restore(original.inputId)
    }
    chat.removeChip()
    chat.draft = ""
    chat.promoteTypedTag()
    for file in chat.attachments { await chat.removeAttachment(file) }
    let kept = try queuedItem(outbox, original.inputId)
    print(
      "IF10-2[\(emptied)] emptied: restoredFrom=\(chat.restoredFrom.map(chat.name) ?? "none") recipient=\(chat.destination.chip.map(chat.name) ?? "none") originalQueued=\(kept != nil) refused=\(kept?.refused == true)"
    )
    #expect(chat.restoredFrom == nil && chat.destination.chip == nil)
    #expect(kept?.refused == true, "The original no longer needs attention")
    await workFixture.acceptUploads()
    await chat.restore(original.inputId)
    chat.removeChip()
    chat.promoteTypedTag()
    print(
      "IF10-2[\(emptied)] restored again: line=\(chat.recipientLine) draft=\(chat.draft.debugDescription) files=\(chat.attachments.count)"
    )
    #expect(chat.addressing == .to([work, personal], body: text))
    try await eventually("both connected") { chat.canSend }
    await chat.send()
    _ = await within(3) {
      await submits(workFixture).filter { $0.inputId != original.inputId }.count
        + personalFixture.count() == 2
    }
    try await Task.sleep(for: .milliseconds(300))
    let atWork = await submits(workFixture).filter { $0.inputId != original.inputId }.map(\.text)
    let atPersonal = await submits(personalFixture).map(\.text)
    let originalQueued = try queuedRequests(outbox).contains { $0.inputId == original.inputId }
    print(
      "IF10-2[\(emptied)] wire: Work=\(atWork) Personal=\(atPersonal) originalQueued=\(originalQueued)"
    )
    #expect(atWork == [text] && atPersonal == [text])
    #expect(!originalQueued, "The copy went unchanged to Work, yet the original stays")
  }
}

// MARK: - A restored source leaves only when its coordinator gets it unchanged, or by Discard

/// Holds `messages` from before the update for `profile`'s coordinator, which this phone proved
/// answers at the address they were queued for, as when the migrated profile pairs there.
@MainActor private func holdFor(
  _ profile: CoordinatorProfile, _ messages: [NativeRequestSubmit], in chat: ChatModel, root: URL
) throws -> Hold {
  let pin = try #require(profile.pin)
  let hold = try heldQueue(messages, in: root, address: profile.address, coordinator: pin)
  chat.holds.append(hold)
  return hold
}

/// `inputID`'s item in the outbox, if it is still queued. One still marked refused can be withdrawn
/// by Discard or by a Send that carries its restored copy unchanged.
private func queuedItem(_ outbox: URL, _ inputID: String) throws -> OutboxItem? {
  try queuedItems(outbox).first { $0.request.inputId == inputID }
}

@MainActor private func addWork(_ coordinators: Coordinators) async throws -> ProfileID {
  try await coordinators.add(
    name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
  let work = try #require(coordinators.profiles.first?.id)
  try await eventually("Work connected") {
    coordinators.chat.snapshots[work]?.connection == .connected
  }
  return work
}

/// Work refuses a message, and the user restores it. /status from the Commands menu replaces the
/// draft, and Send delivers /status. The restored message never went, so its original stays
/// queued, reads "Needs attention" and can be restored again.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["one coordinator", "two coordinators"])
func aCommandSentOverARestoredDraftKeepsTheOriginalQueued(_ setup: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work =
      setup == "two coordinators"
      ? try await addWorkAndPersonal(coordinators).work : try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.rejectSubmits()
    let text = "Invented: renew the greenhouse lease before Friday"
    if let chip = setup == "two coordinators" ? work : nil {
      chat.setChip(chip)
    } else {
      chat.removeChip()
    }
    chat.draft = text
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    await workFixture.rejectSubmits(false)
    // What the Commands menu's /status button does.
    chat.draft = "/status "
    chat.promoteTypedTag()
    await chat.send()
    try await eventually("Work got /status") {
      await submits(workFixture).contains { $0.text.hasPrefix("/status") }
    }
    try await Task.sleep(for: .milliseconds(300))
    let kept = try queuedItem(outbox, original.inputId)
    let stillQueued = kept != nil
    let row = chat.snapshots[work]?.rows.first { $0.inputID == original.inputId }
    let got = await submits(workFixture)
    print(
      "IF8-W1[\(setup)] Work received \(got.map(\.text)) originalQueued=\(stillQueued) refused=\(kept?.refused == true) originalRow=\(row?.delivery?.rawValue ?? "gone") observations=\(await observes(workFixture)) draft=\(chat.draft.debugDescription)"
    )
    let textAnywhere =
      stillQueued || chat.draft.contains("greenhouse")
      || got.contains { $0.text == text && $0.inputId != original.inputId }
    #expect(textAnywhere, "The restored message is neither queued, in the draft nor sent")
    #expect(stillQueued, "The original left the outbox, though its text was never sent")
    #expect(kept?.refused == true, "The original is no longer withdrawable by Discard")
    #expect(row?.delivery == .rejected, "The original no longer needs attention")
    await chat.restore(original.inputId)
    #expect(chat.draft == text, "The original can be restored again")
  }
}

/// A message held from before the update for Work, which paired where it was queued, is restored,
/// and /status from the Commands menu replaces the draft. Send delivers /status, and the held
/// message stays in its hold.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageStaysHeldWhenACommandIsSentOverItsRestoredDraft() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    _ = try await addWork(coordinators)
    let chat = coordinators.chat
    let text = "Invented: Work's held reorg memo"
    let hold = try holdFor(
      coordinators.profiles[0], [NativeRequestSubmit(inputId: "held-1", mode: .steer, text: text)],
      in: chat, root: root)
    let held = HeldMessage(
      queue: hold.queue.id, item: try #require(try await hold.store.items().first))
    await chat.restoreHeld(held)
    chat.draft = "/status "
    chat.promoteTypedTag()
    await chat.send()
    try await eventually("Work got /status") {
      await submits(workFixture).contains { $0.text.hasPrefix("/status") }
    }
    try await Task.sleep(for: .milliseconds(300))
    let left = try await hold.store.items()
    print(
      "IF8-W1[held] Work received \(await submits(workFixture).map(\.text)) held=\(left.map(\.text)) draft=\(chat.draft.debugDescription)"
    )
    #expect(!left.isEmpty || chat.draft.contains("reorg"), "The held message is gone unsent")
    #expect(left.map(\.text) == [text], "The held message stays in its hold")
  }
}

/// Work refuses a message with a file, and the user restores it. /feedback from the Commands menu
/// replaces the restored text, and the user describes a problem. Send delivers the feedback with
/// the file, but the restored text never went, so the original stays queued.
@MainActor @Test(.timeLimit(.minutes(1)))
func aFeedbackSentOverARestoredDraftKeepsTheOriginalQueued() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work = try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.refuseUploads()
    let text = "Invented: here is the signed greenhouse lease, please file it"
    chat.draft = text
    await chat.attach(data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    await workFixture.acceptUploads()
    chat.draft = "/feedback "
    chat.draft += "the upload button looks wrong"
    await chat.send()
    try await eventually("Work got the feedback") {
      await submits(workFixture).contains { $0.text.hasPrefix("/feedback") }
    }
    try await Task.sleep(for: .milliseconds(300))
    let kept = try queuedItem(outbox, original.inputId)
    let stillQueued = kept != nil
    let got = await submits(workFixture)
    print(
      "IF8-W1[feedback] Work received \(got.map(\.text)) files=\(got.map { ($0.attachments ?? []).map(\.name) }) originalQueued=\(stillQueued) refused=\(kept?.refused == true) draft=\(chat.draft.debugDescription)"
    )
    #expect(
      stillQueued || got.contains { $0.text == text && $0.inputId != original.inputId },
      "The restored text is neither queued nor sent")
    #expect(stillQueued, "The original left the outbox, though its text was never sent")
    #expect(kept?.refused == true, "The original is no longer withdrawable by Discard")
  }
}

/// Work refuses a message, and the user restores it, selects all of its text and types another
/// message over it. The first key replaces the selection, so the draft is never empty. Send
/// delivers the new message, and the original stays queued, needing attention.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRestoredTextReplacedInOneEditKeepsTheOriginalQueued() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work = try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.rejectSubmits()
    let text = "Invented: renew the greenhouse lease before Friday"
    chat.draft = text
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    await workFixture.rejectSubmits(false)
    chat.draft = "I"
    chat.draft += "nvented: what time is the standup tomorrow?"
    await chat.send()
    try await eventually("Work got the new message") {
      await submits(workFixture).contains { $0.text.contains("standup") }
    }
    try await Task.sleep(for: .milliseconds(300))
    let kept = try queuedItem(outbox, original.inputId)
    let stillQueued = kept != nil
    let row = chat.snapshots[work]?.rows.first { $0.inputID == original.inputId }
    print(
      "IF8-W1[replaced] Work received \(await submits(workFixture).map(\.text)) originalQueued=\(stillQueued) refused=\(kept?.refused == true) originalRow=\(row?.delivery?.rawValue ?? "gone")"
    )
    #expect(stillQueued, "The restored message is neither queued nor sent")
    #expect(kept?.refused == true, "The original is no longer withdrawable by Discard")
    #expect(row?.delivery == .rejected, "The original no longer needs attention")
  }
}

/// Work refuses a message with a file, and the user restores it. Send withdraws the original only
/// when it carries the restored content unchanged, meaning the same text, ignoring surrounding
/// whitespace, and every restored file, with or without another file. A word added or the restored
/// file removed leaves the original queued, needing attention.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "unchanged", "surrounding whitespace", "a file added", "a word added", "its file removed",
  ])
func aRestoredOriginalIsWithdrawnOnlyWhenItsContentIsSentUnchanged(_ edit: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work = try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.refuseUploads()
    let text = "Invented: the signed greenhouse lease"
    chat.draft = text
    await chat.attach(data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    await chat.restore(original.inputId)
    switch edit {
    case "surrounding whitespace": chat.draft = "  " + chat.draft + "\n"
    case "a file added":
      await chat.attach(
        data: Data("invented receipt".utf8), name: "Receipt.txt", mediaType: "text/plain")
    case "a word added": chat.draft += " today"
    case "its file removed": await chat.removeAttachment(try #require(chat.attachments.first))
    default: break
    }
    await workFixture.acceptUploads()
    await chat.send()
    try await eventually("the copy at Work") { await workFixture.count() == 1 }
    try await Task.sleep(for: .milliseconds(300))
    let kept = try queuedItem(outbox, original.inputId)
    let row = chat.snapshots[work]?.rows.first { $0.inputID == original.inputId }?.delivery
    let withdrawn = ["unchanged", "surrounding whitespace", "a file added"].contains(edit)
    print(
      "IF8-W1[\(edit)] Work received \(await submits(workFixture).map(\.text)) originalQueued=\(kept != nil) refused=\(kept?.refused == true) originalRow=\(row?.rawValue ?? "gone")"
    )
    if withdrawn {
      #expect(
        kept == nil && row == .withdrawn, "The restored message went, so its original is withdrawn")
    } else {
      #expect(kept?.refused == true, "The original left the outbox, though it was never sent")
      #expect(row == .rejected, "The original no longer needs attention")
    }
  }
}

/// The user restores a refused original, replaces it with another note and sends that, so the
/// original stays queued. Discard on its row then removes it and its files and records it
/// withdrawn. It reads "Not sent", and nothing is left to restore.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["one coordinator", "two coordinators"])
func discardRemovesARefusedOriginalAndRecordsItWithdrawn(_ setup: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let chat = coordinators.chat
    let lane: ProfileID
    let fixture: FixtureCoordinator
    var bubble: String?
    if setup == "two coordinators" {
      lane = try await addWorkAndPersonal(coordinators).personal
      fixture = personalFixture
      await fixture.refuseUploads()
      bubble = try await sendToBothRefusedByPersonal(chat, "Invented: the signed lease for both")
        .bubble
    } else {
      lane = try await addWork(coordinators)
      fixture = workFixture
      await fixture.refuseUploads()
      chat.draft = "Invented: the signed lease"
      await chat.attach(
        data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
      await chat.send()
      try await eventually("Work refused it") {
        chat.snapshots[lane]?.rows.contains { $0.delivery == .rejected } == true
      }
    }
    let directory = ProfileDirectory(lane, applicationSupport: root, caches: root)
    let item = try #require(try queuedItems(directory.outbox).first)
    let source = item.request.inputId
    @MainActor func lines() -> [String] {
      (chat.rows.first { $0.id == bubble }?.receipts ?? []).map { $0.line(chat.name($0.lane)) }
    }
    await chat.restore(source)
    chat.draft = "Invented: a different note instead"
    for file in chat.attachments { await chat.removeAttachment(file) }
    await fixture.acceptUploads()
    await chat.send()
    try await eventually("the new note arrived") {
      await submits(fixture).contains { $0.text.contains("different note") }
    }
    #expect(
      try queuedRequests(directory.outbox).contains { $0.inputId == source },
      "The original was replaced, not sent, so it stays")
    await chat.discard(source)
    try await eventually("the original reads Not sent") {
      chat.snapshots[lane]?.rows.first { $0.inputID == source }?.delivery == .withdrawn
    }
    let files =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.outboxAttachments.path)) ?? []
    let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: directory.ledger))
    print(
      "IF8-W1[discard, \(setup)] queued=\(try queuedRequests(directory.outbox).map(\.inputId)) files=\(files) withdrawn=\(ledger.sends[item.sendID]?.withdrawn == true) lines=\(lines())"
    )
    #expect(try !queuedRequests(directory.outbox).contains { $0.inputId == source })
    #expect(files.isEmpty, "The original's files stay on the phone")
    #expect(ledger.sends[item.sendID]?.withdrawn == true, "Discard records it withdrawn")
    #expect(chat.snapshots[lane]?.sends[item.sendID]?.progress == .withdrawn)
    if bubble != nil { #expect(lines() == ["Work · Delivered", "Not sent to Personal"]) }
    await chat.restore(source)
    #expect(chat.draft.isEmpty && chat.attachments.isEmpty, "Nothing is left to restore")
    #expect(!(await submits(fixture)).contains { $0.inputId == source })
  }
}

// MARK: - A refused original needs attention until its coordinator says otherwise

/// Work refuses a message. Its row reads "Needs attention", with Restore and Discard rather than
/// Check / retry, while the app is in the background and once it comes back, since the refusal is
/// still Work's latest word. Discard then withdraws it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRefusedOriginalStillNeedsAttentionOnceTheAppComesBack() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work = try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.rejectSubmits()
    chat.draft = "Invented: renew the greenhouse lease before Friday"
    await chat.send()
    try await eventually("Work refused it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let original = try #require(try queuedRequests(outbox).first)
    @MainActor func row() -> Delivery? {
      chat.snapshots[work]?.rows.first { $0.inputID == original.inputId }?.delivery
    }
    let observed = await observes(workFixture)
    await coordinators.setActive(false)
    try await eventually("Work disconnected") {
      chat.snapshots[work]?.connection == .disconnected
    }
    let away = row()
    await coordinators.setActive(true)
    try await eventually("Work observed again") {
      await observes(workFixture) > observed && chat.snapshots[work]?.connection == .connected
    }
    try await Task.sleep(for: .milliseconds(300))
    print(
      "IF8-W1b[background] before=rejected away=\(away?.rawValue ?? "gone") back=\(row()?.rawValue ?? "gone")"
    )
    #expect(away == .rejected, "In the background the refused original reads Delivery unconfirmed")
    #expect(row() == .rejected, "Back active the refused original reads Delivery unconfirmed")
    await chat.discard(original.inputId)
    try await eventually("the original reads Not sent") { row() == .withdrawn }
    #expect(try queuedItem(outbox, original.inputId) == nil)
  }
}

/// Work rejects a message but keeps it, as a coordinator whose turn ended while saving it does.
/// Its row needs attention. Back from the background, Work reports it accepted, so the row reads
/// Saved, and once Work places it the message reads delivered and leaves the outbox.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRefusedOriginalItsCoordinatorKeptReadsDeliveredOncePlaced() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let work = try await addWork(coordinators)
    let chat = coordinators.chat
    await workFixture.holdPlacements()
    await workFixture.rejectNextSubmitButKeepIt()
    chat.draft = "Invented: the gate code changed to 4410"
    await chat.send()
    try await eventually("Work rejected it") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let outbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let item = try #require(try queuedItems(outbox).first)
    let source = item.request.inputId
    @MainActor func row() -> ChatRow? { chat.snapshots[work]?.rows.first { $0.inputID == source } }
    await coordinators.setActive(false)
    try await eventually("Work disconnected") {
      chat.snapshots[work]?.connection == .disconnected
    }
    let away = row()?.delivery
    await coordinators.setActive(true)
    try await eventually("Work reports it accepted") { row()?.delivery == .saved }
    try await workFixture.finishTurn()
    try await eventually("Work placed it") {
      row()?.entryID != nil && (try? queuedItem(outbox, source)) == nil
    }
    print(
      "IF8-W1b[kept] away=\(away?.rawValue ?? "gone") placed: delivery=\(row()?.delivery?.rawValue ?? "nil") entry=\(row()?.entryID ?? "nil") send=\(String(describing: chat.snapshots[work]?.sends[item.sendID]?.progress))"
    )
    #expect(away == .rejected)
    #expect(row()?.delivery == .saved, "A placed message shows no delivery problem")
    #expect(chat.snapshots[work]?.sends[item.sendID]?.progress == .placed)
  }
}

// MARK: - A copy that may have left the phone stays when its Send reaches no one

/// Blocks the calling thread, so an actor running this holds every later call behind it.
private func blockUntil(_ release: DispatchSemaphore) { release.wait() }
private func signalled(_ semaphore: DispatchSemaphore) -> Bool {
  semaphore.wait(timeout: .now()) == .success
}
extension CoordinatorSession {
  /// Holds this session's actor until `release`, then drops its connection, so a stage queued
  /// behind it finds the lane down. It is a test-only barrier and changes no saved state.
  fileprivate func dropOnceReleased(entered: DispatchSemaphore, release: DispatchSemaphore) async {
    entered.signal()
    blockUntil(release)
    await disconnect()
  }
}

/// A Send to both saves Work's copy while Personal's actor is held. An edit of Work's address to
/// another address of Work replaces Work's session, and the next session shows the copy
/// unconfirmed. Check / retry writes it there, and Work accepts it. With `anotherEdit`, a second
/// edit replaces that session too. Personal then drops before its copy is saved, so the Send
/// reaches no one and withdraws Work's copy. Work may hold it, so the phone keeps it queued and in
/// the feed, and reads it delivered once Work places it.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aCopyCheckRetrySentDuringASendThatReachedNoOneStaysAfterAnyEdits(_ anotherEdit: Bool)
  async throws
{
  try await withTwoFixtures { coordinators, workFixture, _, root in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let personalSession = try #require(chat.lanes.first { $0.id == personal }?.session)
    let workOutbox = ProfileDirectory(work, applicationSupport: root, caches: root).outbox
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let dropping = Task.detached {
      await personalSession.dropOnceReleased(entered: entered, release: release)
    }
    try await eventually("Personal's actor held") { signalled(entered) }
    let text = "Invented invitation for both"
    chat.draft = text
    let sending = chat.startSend()
    try await eventually("Work saved its copy") {
      ((try? queuedRequests(workOutbox)) ?? []).count == 1
    }
    let input = try #require(try queuedRequests(workOutbox).first?.inputId)
    await workFixture.holdPlacements()
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
    try await eventually("Work's next session offers Check / retry") {
      chat.snapshots[work]?.connection == .connected
        && chat.snapshots[work]?.rows.contains { $0.inputID == input && $0.delivery == .uncertain }
          == true
    }
    await chat.retry(input)
    try await eventually("Work accepted the checked copy") {
      chat.snapshots[work]?.rows.contains { $0.inputID == input && $0.delivery == .saved } == true
    }
    if anotherEdit {
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4004))
      try await eventually("Work's next session saw the acceptance") {
        chat.snapshots[work]?.connection == .connected
          && chat.snapshots[work]?.rows.contains { $0.inputID == input && $0.delivery == .saved }
            == true
      }
    }
    try #require(chat.admitting, "The Send was still waiting for Personal")
    release.signal()
    await dropping.value
    await sending?.value
    let queued = ((try? queuedRequests(workOutbox)) ?? []).map(\.inputId)
    print(
      "IF12-1[anotherEdit=\(anotherEdit)] after the Send: error=\(chat.error ?? "nil") draftKept=\(chat.draft == text) Work got=\(await workFixture.count()) Work's outbox=\(queued.count)"
    )
    try #require(queued == [input], "Work's accepted copy was withdrawn as never sent")
    try await workFixture.finishTurn()
    await chat.reconnect(work)
    @MainActor func receipts() -> [String] {
      chat.rows.filter { $0.row.text == text }.flatMap { row in
        row.receipts.map { $0.line(chat.name($0.lane)) }
      }
    }
    try await eventually("Work placed it") { receipts().contains("Work · Delivered") }
    let bubbles = chat.rows.filter { $0.row.text == text }.count
    let atWork = await workFixture.count()
    print(
      "IF12-1[anotherEdit=\(anotherEdit)] once Work placed it: bubbles=\(bubbles) receipts=\(receipts()) Work got=\(atWork)"
    )
    #expect(bubbles == 1)
    #expect(try queuedRequests(workOutbox).isEmpty)
    #expect(atWork == 1, "Sent once")
  }
}
