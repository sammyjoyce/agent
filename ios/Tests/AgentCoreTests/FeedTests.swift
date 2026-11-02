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
      ("@Work hi", false, personal, [saved(work, "Work")], .to([work], body: "@Work hi")),
      ("hi", false, nil, [], .blocked("No coordinator is paired yet")),
    ]
  for item in cases {
    #expect(
      Addressing.parse(
        item.draft, hasAttachments: item.files, chip: item.chip, among: item.saved)
        == item.expected, "\(item.draft.debugDescription) with \(item.saved.map(\.name))")
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
      Receipt(lane: work, status: .notSent), Receipt(lane: personal, status: .placed),
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

/// Two loopback coordinators at ports 4001 and 4002 of one invented address, and a fresh
/// `Coordinators` with nothing saved, as the app builds it.
@MainActor private func withTwoFixtures(
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
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
    })
  await coordinators.setActive(true)
  do {
    try await body(coordinators, first, second, root)
  } catch {
    await coordinators.setActive(false)
    await first.stop()
    await second.stop()
    throw error
  }
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
