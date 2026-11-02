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
      ("@Personal hi", nil, [saved(work, "Work")], .blocked("Personal was removed")),
      (
        "@Work @personal hi", nil, [saved(work, "Work"), saved(work1, "Work-1")],
        .blocked("Personal was removed")
      ),
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
    "A": .init(recipients: [work], delivery: nil),
    "B": .init(recipients: [work, personal], delivery: nil),
    "D": .init(recipients: [work, personal], delivery: nil),
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
    "B": .init(recipients: [work, personal], delivery: .uncertain),
    "C": .init(recipients: [work, personal], delivery: nil),
    "D": .init(recipients: [work, personal], delivery: nil),
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

/// Two loopback coordinators at ports 4001 and 4002 of one invented address, and a fresh
/// `Coordinators` with nothing saved, as the app builds it.
@MainActor private func withTwoFixtures(
  registration: NotificationRegistration? = nil, holdingWork gate: DialGate? = nil,
  _ body: (Coordinators, FixtureCoordinator, FixtureCoordinator, URL) async throws -> Void
) async throws {
  let first = FixtureCoordinator()
  let second = FixtureCoordinator()
  let (firstListener, firstPort) = try await listen(first)
  defer { firstListener.cancel() }
  let (secondListener, secondPort) = try await listen(second)
  defer { secondListener.cancel() }
  let routes: [UInt16: NWEndpoint.Port] = [4001: firstPort, 4002: secondPort]
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "feed-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: registration, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      if address.port == 4001 { await gate?.pass() }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
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
    // The fixture closes each submit's socket after `accepted`, so both lanes reconnect.
    try await eventually("both reconnected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
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
          $0.sends.count == 1 && $0.sends.values.allSatisfy { $0.delivery == nil }
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
    let drafts: [(chip: ProfileID?, text: String)] = [
      (nil, "@Work see the invented board minutes"), (work, "Invented board minutes"),
    ]
    for draft in drafts {
      chat.recipient = draft.chip
      chat.draft = draft.text
      #expect(chat.addressing == .blocked("Work was removed"), "\(draft.text)")
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
      && snapshot.sends.values.filter { $0.recipients == [personal] && $0.delivery == nil }.count
        >= 2000
      && !snapshot.sends.values.contains { $0.delivery != nil }
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
