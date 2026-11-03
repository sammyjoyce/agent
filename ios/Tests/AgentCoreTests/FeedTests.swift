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
        item.draft, hasAttachments: item.files, chip: item.chip, among: item.saved)
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
        item.draft, hasAttachments: false, chip: item.chip, among: item.saved,
        removed: [personal: "Personal"]) == item.expected,
      "\(item.draft.debugDescription) with \(item.saved.map(\.name))")
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
private actor DialGate {
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

/// Where Work's addresses lead. A test can point them at Personal, as a moved name would.
private actor WorkRoute {
  private(set) var answersAsPersonal = false
  func point(atPersonal value: Bool) { answersAsPersonal = value }
}

/// Two loopback coordinators, Personal at port 4002 of an invented address and Work at any
/// other address, and a fresh `Coordinators` with nothing saved, as the app builds it.
@MainActor private func withTwoFixtures(
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
      let repointed = await route?.answersAsPersonal == true
      let personal = address.port == 4002 || repointed
      return LineConnection(
        connection: NWConnection(
          host: .ipv4(.loopback), port: personal ? secondPort : firstPort, using: .tcp))
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

@MainActor private func eventually(
  _ description: String, _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor private func addWorkAndPersonal(_ coordinators: Coordinators) async throws -> (
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
    #expect(chat.recipient == work && chat.draft.isEmpty, "A typed tag becomes the chip")
    chat.draft = "@Personal rotate the staging deploy key"
    chat.promoteTypedTag()
    #expect(chat.recipientLine == "To Work", "Text after the chip is never routed")
    await chat.send()
    #expect(chat.recipient == nil && chat.draft.isEmpty)
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
    chat.recipient = personal
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
    #expect(chat.recipient == personal)
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
    chat.recipient = work
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
      chat.recipient = chip
      do {
        try await coordinators.remove(work)
        Issue.record("Remove went ahead with a draft from Work, chip \(String(describing: chip))")
      } catch {
        #expect(error.localizedDescription == "Send or clear the draft for Work first.")
      }
      #expect(coordinators.profiles.map(\.id) == [work, personal])
    }
    chat.draft = ""
    for file in chat.attachments { await chat.removeAttachment(file) }
    try await coordinators.remove(work)
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
    #expect(captures == 1 && chat.attachments.map(\.reference.name) == ["Feedback.png"])
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
    try await coordinators.remove(work)
    try await eventually("Personal connected") { chat.connection == .connected }
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true)
    await chat.removeAttachment(screenshot)
    await chat.send()
    try await eventually("Personal's feedback") { await personalFixture.count() > 0 }
    #expect(await submits(personalFixture).map { $0.attachments ?? [] } == [[]])
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
    chat.recipient = work
    chat.draft = "Invented Q3 payroll numbers for the Work board"
    await chat.attach(
      data: Data("invented payroll".utf8), name: "Payroll.txt", mediaType: "text/plain")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(workDirectory.outbox).first)
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: "held-1", mode: .steer, text: "Invented Work-only held text")
      ]), to: workDirectory.legacy.appending(path: "pending.json"))
    let hold = try #require(chat.lanes.first { $0.id == work }?.hold)
    let held = HeldMessage(lane: work, item: try #require(try await hold.items().first))

    await gate.arm()
    let removal = Task { try await coordinators.remove(work) }
    try await eventually("Remove waiting on Work's alert withdrawal") { await gate.waiting }
    chat.draft = "@Wo"
    #expect(chat.pickerMatches.isEmpty, "Work is not offered while it is removed")
    chat.choose(work)
    #expect(chat.recipient == nil)
    chat.draft = "@Work see the invented payroll"
    chat.promoteTypedTag()
    #expect(!chat.canSend && chat.recipientLine == "Work was removed")
    chat.recipient = nil
    chat.draft = ""
    await chat.restoreHeld(held)
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
    chat.recipient = work
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
    let removal = Task { @MainActor in try await coordinators.remove(work) }
    await restoring.value
    #expect(chat.draft == queued.text && chat.recipient == work)
    try await eventually("Remove waiting on Work's alert withdrawal") { await gate.waiting }
    await gate.open()
    try await removal.value
    #expect(coordinators.profiles.map(\.id) == [personal])
    for chip in [work, nil] {
      chat.recipient = chip
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
    #expect(chat.recipient == nil && chat.recipientLine == "To Work")
    do {
      try await coordinators.remove(work)
      Issue.record("Remove went ahead with a draft tagged @Work")
    } catch {
      #expect(error.localizedDescription == "Send or clear the draft for Work first.")
    }
    #expect(coordinators.profiles.map(\.id) == [work, personal])
    chat.draft = ""
    for file in chat.attachments { await chat.removeAttachment(file) }
    try await coordinators.remove(work)
    #expect(coordinators.profiles.map(\.id) == [personal])
    let drafts: [(chip: ProfileID?, text: String, blocked: String)] = [
      (nil, "@Work see the invented board minutes", "No coordinator named Work"),
      (work, "Invented board minutes", "Work was removed"),
    ]
    for draft in drafts {
      chat.recipient = draft.chip
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
    #expect(chat.attachments.map(\.reference.name) == ["Feedback.png"])
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
    chat.recipient = nil
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
    chat.recipient = work
    chat.draft = tagged
    await chat.send()
    try await eventually("the tagged Send placed") {
      chat.rows.first { $0.row.text == tagged }?.receipts == [Receipt(lane: work, status: .placed)]
    }
    try await bothConnected()
    try await coordinators.remove(personal)
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
      try await coordinators.remove(work)
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
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
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
    var editFinished = false
    let editing = Task { @MainActor in
      defer { editFinished = true }
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.3", port: 4001))
    }
    let original = chat.lanes.first { $0.id == work }?.session
    while !editFinished, chat.snapshots[work]?.connection == .connected,
      chat.lanes.first(where: { $0.id == work })?.session === original
    { await Task.yield() }
    try #require(!editFinished, "Remove starts while the edit swaps Work's session")
    try await coordinators.remove(work)
    try await editing.value
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
    #expect(chat.recipient == nil && chat.recipientLine == "To Work")
    try await coordinators.update(
      work, name: TagName("Job"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    #expect(chat.addressing == .blocked("No coordinator named Work"))
    try await coordinators.remove(work)
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
    do { try await coordinators.remove(work) } catch { refusal = error.localizedDescription }
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
    try await coordinators.remove(work)
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

/// A pending withdrawal whose address now answers as another coordinator is dropped: that
/// coordinator never held the registration, and it never sees the removed installation ID.
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
    try await coordinators.remove(work)
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

/// Nothing can attach a lane for a coordinator once Remove has marked it.
@MainActor @Test func aRemovedCoordinatorsLaneIsNeverAttachedAgain() {
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let chat = ChatModel()
  chat.removed[directory.profile] = "Work"
  chat.attach(Lane(id: directory.profile, session: nil, hold: LegacyHold(directory)))
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
    let removing = Task { @MainActor in try await coordinators.remove(personal) }
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
    #expect(await session.start(staged))
    #expect(
      await coordinators.removalMessage(personal)
        == "This deletes 1 queued message on this phone.")
    let activating = Task { @MainActor in await coordinators.setActive(true) }
    let removing = Task { @MainActor in try await coordinators.remove(personal) }
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
          connection: NWConnection(
            host: .ipv4(.loopback), port: address.port == 4002 ? personalPort : workPort,
            using: .tcp))
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
          connection: NWConnection(
            host: .ipv4(.loopback), port: address.port == 4002 ? personalPort : workPort,
            using: .tcp))
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
          connection: NWConnection(
            host: .ipv4(.loopback), port: address.port == 4002 ? personalPort : workPort,
            using: .tcp))
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

/// Personal refuses its copy of a message to both. Restoring that copy and sending it to Work
/// instead discards Personal's original, so Personal never placed the message, and the original
/// bubble must not read "To Work and Personal".
@MainActor @Test(.timeLimit(.minutes(1)))
func aCopyRestoredFromPersonalAndSentToWorkLeavesTheOriginalNotSentToPersonal() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
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
    await chat.restore(try #require(rejected))
    chat.recipient = nil
    chat.draft = "@Work " + chat.draft
    chat.promoteTypedTag()
    #expect(chat.recipient == work && chat.recipientLine == "To Work")
    await chat.send()
    try await eventually("the copy at Work") { await workFixture.count() == 2 }
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
    try #require(chat.attachments.count == 1)
    await chat.attach(
      data: Data("Invented manually attached reference picture".utf8), name: "Feedback.png",
      mediaType: "image/png")
    await workFixture.refuseUploads()
    await chat.send()
    try await eventually("Work refused the upload") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(directory.outbox).first)
    try #require(queued.attachments?.count == 2)
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
    chat.recipient = nil
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
    chat.recipient = work
    chat.draft = "Invented ordinary note, not feedback"
    await chat.attach(
      data: Data("invented user file bytes".utf8), name: "Feedback.png", mediaType: "image/png")
    await chat.send()
    try await eventually("rejected by Work") {
      chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
    }
    let queued = try #require(try queuedRequests(workDirectory.outbox).first)
    await chat.restore(queued.inputId)
    #expect(chat.recipient == work && chat.recipientLine == "To Work")
    chat.recipient = nil
    await chat.send()
    #expect(chat.error?.hasPrefix("Remove the automatic screenshot") == true, "Not to both")
    chat.recipient = work
    chat.error = nil
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
      let sending = Task { @MainActor in await chat.send() }
      let dropping = Task { @MainActor in await session.disconnect() }
      await sending.value
      await dropping.value
      await session.connect()
      try await eventually("both connected again") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    }
    chat.draft = "/status"
    try await sendWhileWorkDrops()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await submits(personalFixture).map(\.text) == ["/status"])
    #expect(await submits(workFixture).isEmpty, "A control is never sent later")
    #expect(chat.error == "Work did not get /status. It is not connected.")
    #expect(chat.draft.isEmpty, "Personal got it")

    chat.recipient = work
    chat.draft = "/status"
    try await sendWhileWorkDrops()
    try await Task.sleep(for: .milliseconds(250))
    #expect(await submits(workFixture).isEmpty)
    #expect(chat.error == "Work did not get /status. It is not connected.")
    #expect(chat.draft == "/status" && chat.recipient == work, "Nothing went, so the draft stays")
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
    let sending = Task { @MainActor in await chat.send() }
    let removing = Task { @MainActor in try await coordinators.remove(work) }
    await sending.value
    try await removing.value
    try await Task.sleep(for: .milliseconds(300))
    let sentToWork = await submits(workFixture).map(\.text)
    #expect(await submits(personalFixture).map(\.text) == ["/status"])
    #expect(
      sentToWork.isEmpty
        ? chat.error == "Work did not get /status. It was removed." : chat.error == nil,
      "Work got \(sentToWork), and the error says \(chat.error ?? "nothing")")
    #expect(chat.draft.isEmpty, "Personal got it")
    let outbox = ProfileDirectory(personal, applicationSupport: root, caches: root).outbox
    #expect((try? queuedRequests(outbox))?.isEmpty ?? true, "A control is never queued")
  }
}
