import CryptoKit
import Foundation
import Network
import Synchronization
import Testing

@testable import AgentCore

private func until(
  _ session: CoordinatorSession, _ predicate: @Sendable (ChatSnapshot) -> Bool
) async throws -> ChatSnapshot {
  for await snapshot in session.updates where predicate(snapshot) { return snapshot }
  throw ConnectionError.closed
}

private func eventually(
  _ description: String, _ predicate: @Sendable () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while try !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func outboxItems(_ outbox: URL) throws -> [OutboxItem] {
  try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: outbox))
}

private func savedLedger(_ directory: ProfileDirectory) throws -> Ledger {
  try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: directory.ledger))
}

private func reply(_ entry: String, role: HistoryRole = .final, _ text: String) -> HistoryMessage {
  HistoryMessage(continuation: false, entryId: entry, finalChunk: true, role: role, text: text)
}

private actor Launched {
  private(set) var sessions: [CoordinatorSession] = []
  func add(_ session: CoordinatorSession) -> CoordinatorSession {
    sessions.append(session)
    return session
  }
}

/// One coordinator and one profile directory. `launch` builds a session over the directory,
/// standing in for an app launch with its own stamp source.
private func withProfile(
  _ body:
    @Sendable (
      FixtureCoordinator, ProfileDirectory, @Sendable () async throws -> CoordinatorSession
    ) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let launched = Launched()
  let launch: @Sendable () async throws -> CoordinatorSession = {
    await launched.add(
      CoordinatorSession(
        directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"),
        pin: fixture.id, stamps: StampSource(), transport: loopback(port)))
  }
  do { try await body(fixture, directory, launch) } catch {
    for session in await launched.sessions { await session.disconnect() }
    await fixture.stop()
    throw error
  }
  for session in await launched.sessions { await session.disconnect() }
  await fixture.stop()
}

@Test(.timeLimit(.minutes(1)))
func twoCoordinatorsStampRowsInTheOrderTheirEventsArrive() async throws {
  let stamps = StampSource()
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let (workDirectory, workRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: workRoot) }
  let (personalDirectory, personalRoot) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: personalRoot) }
  let address = try CoordinatorAddress(host: "100.64.1.2")
  let workSession = CoordinatorSession(
    directory: workDirectory, address: address, pin: work.id, stamps: stamps,
    transport: loopback(workPort))
  let personalSession = CoordinatorSession(
    directory: personalDirectory, address: address, pin: personal.id, stamps: stamps,
    transport: loopback(personalPort))
  await workSession.connect()
  await personalSession.connect()
  _ = try await until(workSession) { $0.connection == .connected }
  _ = try await until(personalSession) { $0.connection == .connected }
  // Both Work events land inside one 50 ms publication delay, with Personal's first between.
  for (fixture, entry) in [(work, "w1"), (personal, "p1"), (work, "w2"), (personal, "p2")] {
    try await fixture.liveMessage(reply(entry, "Reply \(entry)"))
    try await Task.sleep(for: .milliseconds(15))
  }
  let workRows = try await until(workSession) { $0.rows.contains { $0.entryID == "w2" } }.rows
  let personalRows = try await until(personalSession) {
    $0.rows.contains { $0.entryID == "p2" }
  }.rows
  let stamp = { (rows: [ChatRow], entry: String) in rows.first { $0.entryID == entry }?.receivedAt }
  let w1 = try #require(stamp(workRows, "w1"))
  let p1 = try #require(stamp(personalRows, "p1"))
  let w2 = try #require(stamp(workRows, "w2"))
  let p2 = try #require(stamp(personalRows, "p2"))
  #expect(w1 < p1 && p1 < w2 && w2 < p2, "Stamps follow arrival, not publication")
  await workSession.disconnect()
  await personalSession.disconnect()
  await work.stop()
  await personal.stop()
}

enum StreamEnd: CaseIterable, Sendable { case finalAnswer, commentary }

@Test(.timeLimit(.minutes(1)), arguments: StreamEnd.allCases)
func aStreamedReplyKeepsItsStampWhenItsEntryReplacesIt(_ end: StreamEnd) async throws {
  try await withProfile { fixture, directory, launch in
    let session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    try await fixture.emitOnObserver(.textDelta(.init(text: "Checking the invented report")))
    let streamed = try await until(session) { $0.rows.contains { $0.role == .partialAnswer } }
    let stamp = try #require(streamed.rows.first { $0.role == .partialAnswer }?.receivedAt)
    let text = "Checking the invented report. Done."
    switch end {
    case .finalAnswer:
      try await fixture.emitOnObserver(.answer(.init(entryId: "reply", text: text)))
    case .commentary: try await fixture.liveMessage(reply("reply", role: .commentary, text))
    }
    let replaced = try await until(session) { $0.rows.contains { $0.entryID == "reply" } }
    #expect(!replaced.rows.contains { $0.role == .partialAnswer })
    #expect(replaced.rows.first { $0.entryID == "reply" }?.receivedAt == stamp)
    let saved = try #require(try savedLedger(directory).entries["reply"])
    #expect(Date(timeIntervalSince1970: saved.receivedAt) == stamp, "Saved for the next launch")
  }
}

@Test(.timeLimit(.minutes(1)))
func aQueuedInputKeepsItsQueueTimeAcrossRelaunchAndPlacement() async throws {
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let staged = try #require(
      await first.stage("Keep my place", sendID: "send-1", recipients: [directory.profile]))
    // The app stops before `start`.
    await first.disconnect()
    let item = try #require(try outboxItems(directory.outbox).first)
    let queuedAt = Date(timeIntervalSince1970: item.queuedAt)

    let second = try await launch()
    await second.connect()
    let relaunched = try await until(second) { $0.connection == .connected }
    let pending = try #require(relaunched.rows.first { $0.inputID == staged.inputID })
    #expect(pending.delivery == .uncertain)
    #expect(pending.receivedAt == queuedAt)
    #expect(pending.sendID == "send-1")
    #expect(
      relaunched.sends["send-1"]
        == SendStatus(recipients: [directory.profile], delivery: .uncertain))
    await second.retry(staged.inputID)
    let entry = "placed-\(staged.inputID)"
    let placed = try await until(second) {
      $0.connection == .connected && $0.rows.contains { $0.entryID == entry && $0.delivery == nil }
    }
    let row = try #require(placed.rows.first { $0.entryID == entry })
    #expect(row.receivedAt == queuedAt, "The queue time moved to the entry")
    #expect(row.sendID == "send-1")
    #expect(placed.sends["send-1"] == SendStatus(recipients: [directory.profile], delivery: nil))
    #expect(try queuedRequests(directory.outbox).isEmpty)
    let ledger = try savedLedger(directory)
    #expect(
      try directory.ledger.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup == true)
    #if os(macOS)
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.ledger.path)
      #expect(attributes[.posixPermissions] as? Int == 0o600)
    #endif
    #expect(ledger.entries[entry] == Ledger.Entry(receivedAt: item.queuedAt, sendID: "send-1"))
    #expect(
      ledger.sends["send-1"]
        == Ledger.Send(inputID: staged.inputID, entryID: entry, recipients: [directory.profile]))
    await second.disconnect()

    await fixture.replyToHistory(
      initial: .init(messages: [reply(entry, role: .user, "Keep my place")], pageComplete: true),
      pages: [:])
    let third = try await launch()
    await third.connect()
    let history = try await until(third) {
      $0.connection == .connected && $0.rows.contains { $0.entryID == entry }
    }
    #expect(history.rows.first { $0.entryID == entry }?.receivedAt == queuedAt)
    #expect(history.rows.first { $0.entryID == entry }?.sendID == "send-1")
    #expect(try savedLedger(directory) == ledger, "Relaunching leaves the saved stamps alone")
  }
}

@Test(.timeLimit(.minutes(1)))
func aPlacementStaysQueuedUntilItsRecordIsSaved() async throws {
  try await withProfile { fixture, directory, launch in
    // A directory where the ledger belongs makes every ledger write fail.
    try FileManager.default.createDirectory(at: directory.ledger, withIntermediateDirectories: true)
    let session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    #expect(await session.submit("Record me first"))
    // The fixture drops the reply, so reconnecting reconciles and places the input.
    _ = try await until(session) {
      $0.connection == .connected && $0.rows.contains { $0.entryID?.hasPrefix("placed-") == true }
    }
    #expect(try queuedRequests(directory.outbox).map(\.text) == ["Record me first"])
    try FileManager.default.removeItem(at: directory.ledger)
    await session.connect()
    try await eventually("the placement recorded") {
      try queuedRequests(directory.outbox).isEmpty
    }
    let ledger = try savedLedger(directory)
    let send = try #require(ledger.sends.values.first)
    #expect(ledger.entries[try #require(send.entryID)]?.sendID != nil)
    #expect(await fixture.count() == 1, "Reconciling again never resends")
  }
}

@Test func unseenRowsFillFromNeighboursAndNeverReorderACoordinator() {
  var clock = 100.0
  func next() -> TimeInterval {
    clock += 1
    return clock
  }
  func fill(_ known: [TimeInterval?], keys: [String]? = nil) -> [TimeInterval] {
    Ledger.receiveStamps(keys: keys ?? known.indices.map { "row-\($0)" }, known: known, next: next)
  }
  func close(_ stamps: [TimeInterval], _ expected: [TimeInterval]) -> Bool {
    stamps.count == expected.count && zip(stamps, expected).allSatisfy { abs($0 - $1) < 1e-9 }
  }
  #expect(close(fill([nil, nil, 50]), [49.998, 49.999, 50]), "Leading run")
  #expect(close(fill([10, nil, nil]), [10, 101, 102]), "Trailing run")
  #expect(close(fill([10, nil, nil, 13]), [10, 11, 12, 13]), "Gap")
  #expect(close(fill([nil, nil, nil]), [102.998, 102.999, 103]), "Nothing known")
  #expect(close(fill([20, 10, nil]), [20, 20, 104]), "Never decreasing")
  #expect(
    close(fill([nil, nil, 30], keys: ["entry", "entry", "other"]), [29.998, 29.998, 30]),
    "One stamp per entry")
  #expect(fill([]).isEmpty)
  #expect(clock == 104)
}

@Test(.timeLimit(.minutes(1)))
func aSendStillReportsAfterItsRowLeavesTheWindow() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let recipients = [session.profile, ProfileID()]
    let staged = try #require(
      await session.stage("To both", sendID: "send-2", recipients: recipients))
    await session.start(staged)
    let placed = try await until(session) {
      $0.rows.contains { $0.sendID == "send-2" && $0.entryID != nil && $0.delivery == nil }
    }
    #expect(placed.sends["send-2"] == SendStatus(recipients: recipients, delivery: nil))
    await fixture.replyToLatest(
      .init(messages: [reply("newer", "A newer page")], pageComplete: true))
    await session.loadLatest()
    let evicted = try await until(session) {
      $0.rows.contains { $0.entryID == "newer" } && !$0.rows.contains { $0.sendID == "send-2" }
    }
    #expect(evicted.sends["send-2"] == SendStatus(recipients: recipients, delivery: nil))
  }
}

@Test(.timeLimit(.minutes(1)))
func aStageCutOffByDisconnectLeavesNothingInTheProfile() async throws {
  try await withCoordinator { session, fixture, outbox in
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let bytes = Data("Invented attachment bytes".utf8)
    let source = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).fifo")
    try #require(mkfifo(source.path, 0o600) == 0)
    defer { try? FileManager.default.removeItem(at: source) }
    let file = LocalAttachment(
      reference: AttachmentRef(
        id: UUID().uuidString, mediaType: "text/plain", name: "Notes.txt",
        sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
        sizeBytes: bytes.count),
      url: source)
    let staging = Task {
      await session.stage(
        "Never saved", files: [file], sendID: "send-3", recipients: [session.profile])
    }
    // Opening the pipe's write end waits until the session's copy has opened its read end.
    let writer = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        continuation.resume(with: Result { try FileHandle(forWritingTo: source) })
      }
    }
    await session.disconnect()
    try writer.write(contentsOf: bytes)
    try writer.close()
    #expect(await staging.value == nil)
    let files =
      FileManager.default.enumerator(
        at: outbox.deletingLastPathComponent(), includingPropertiesForKeys: [.isRegularFileKey]
      )?.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      } ?? []
    #expect(files.isEmpty, "No outbox item or attachment copy outlives the disconnect")
    #expect(await fixture.count() == 0)
  }
}

@Test func savedOutboxAndLedgerKeepTheirFileFormat() throws {
  let outbox = """
    [{"request":{"input_id":"11111111-1111-4111-8111-111111111111","mode":"steer",\
    "text":"Invented note"},"send_id":"S1","queued_at":1762100000.25,\
    "recipients":["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA","BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"]}]
    """
  let items = try JSONDecoder().decode([OutboxItem].self, from: Data(outbox.utf8))
  let item = try #require(items.first)
  #expect(item.request.text == "Invented note" && item.sendID == "S1")
  #expect(item.queuedAt == 1_762_100_000.25 && item.recipients.count == 2)
  #expect(try JSONDecoder().decode([OutboxItem].self, from: JSONEncoder().encode(items)) == items)
  let ledger = """
    {"entries":{"entry-1":{"received_at":1762100000.25,"send_id":"S1"},\
    "entry-2":{"received_at":1762100001.5}},"sends":{"S1":{"input_id":\
    "11111111-1111-4111-8111-111111111111","entry_id":"entry-1","recipients":\
    ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"]}}}
    """
  let saved = try JSONDecoder().decode(Ledger.self, from: Data(ledger.utf8))
  #expect(saved.entries["entry-1"] == Ledger.Entry(receivedAt: 1_762_100_000.25, sendID: "S1"))
  #expect(saved.entries["entry-2"] == Ledger.Entry(receivedAt: 1_762_100_001.5))
  #expect(saved.sends["S1"]?.entryID == "entry-1")
  #expect(saved.sends["S1"]?.recipients == Array(item.recipients.prefix(1)))
  #expect(try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(saved)) == saved)
}

@Test(.timeLimit(.minutes(1)))
func aCorruptLedgerStartsEmptyButACorruptOutboxStillBlocks() async throws {
  try await withProfile { fixture, directory, launch in
    try writePrivately(Data("not a ledger".utf8), to: directory.ledger)
    await fixture.replyToHistory(
      initial: .init(messages: [reply("kept", "Still ordered")], pageComplete: true),
      pages: [:])
    let session = try await launch()
    await session.connect()
    let connected = try await until(session) {
      $0.connection == .connected && $0.rows.contains { $0.entryID == "kept" }
    }
    #expect(connected.error == nil)
    #expect(connected.rows.first { $0.entryID == "kept" }?.receivedAt != nil)
    await session.disconnect()

    let corrupt = Data("not an outbox".utf8)
    try writePrivately(corrupt, to: directory.outbox)
    let blocked = try await launch()
    await blocked.connect()
    let refused = try await until(blocked) { $0.error != nil }
    #expect(
      refused.error
        == "The saved outbox could not be read. It was preserved; no messages were replayed.")
    #expect(refused.connection == .disconnected)
    #expect(try Data(contentsOf: directory.outbox) == corrupt)
  }
}

private final class TestClock: Sendable {
  private let time: Mutex<TimeInterval>
  init(_ start: TimeInterval) { time = Mutex(start) }
  var now: TimeInterval { time.withLock { $0 } }
  func set(_ value: TimeInterval) { time.withLock { $0 = value } }
}

@Test func stampsNeverStepBackWhenTheClockDoes() {
  let clock = TestClock(1000)
  let stamps = StampSource(now: { clock.now })
  #expect(stamps.next() == 1000)
  clock.set(900)
  #expect(abs(stamps.next() - 1000.001) < 1e-6)
  stamps.seed(5000)
  #expect(abs(stamps.next() - 5000.001) < 1e-6, "A saved stamp from a faster clock is a floor")
  clock.set(6000)
  #expect(stamps.next() == 6000)
}

@Test func theLedgerKeepsTheNewestTwoThousandAndEverythingShown() {
  var ledger = Ledger()
  for index in 0..<2002 {
    ledger.entries["entry-\(index)"] = Ledger.Entry(receivedAt: Double(index))
    ledger.sends["send-\(index)"] = Ledger.Send(
      inputID: "input-\(index)", entryID: "entry-\(index)", recipients: [])
  }
  let shown = ChatRow(id: "entry:entry-0:0", entryID: "entry-0", role: .user, text: "Oldest")
  ledger.prune(keeping: [shown])
  #expect(ledger.entries.count == 2000 && ledger.sends.count == 2000)
  #expect(ledger.entries["entry-0"] != nil && ledger.sends["send-0"] != nil, "Still shown")
  for pruned in 1...2 {
    #expect(ledger.entries["entry-\(pruned)"] == nil && ledger.sends["send-\(pruned)"] == nil)
  }
  #expect(ledger.entries["entry-3"] != nil && ledger.sends["send-3"] != nil)
}

@Test(.timeLimit(.minutes(1)))
func stagingSendsNothingAndUnstagingLeavesNoTrace() async throws {
  try await withCoordinator { session, fixture, outbox in
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let drafts = AttachmentStore(
      directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    let file = try await drafts.stage(
      data: Data("Invented bytes".utf8), name: "Notes.txt", mediaType: "text/plain")
    defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    let recipients = [session.profile, ProfileID()]
    let staged = try #require(
      await session.stage("To both", files: [file], sendID: "send-4", recipients: recipients))
    let item = try #require(try outboxItems(outbox).first)
    #expect(item.request.inputId == staged.inputID && item.request.attachments == [file.reference])
    #expect(item.sendID == "send-4" && item.recipients == recipients)
    let stored = outbox.deletingLastPathComponent().appending(path: "Attachments/\(file.id)")
    #expect(FileManager.default.fileExists(atPath: stored.path))
    await session.unstage(staged)
    #expect(try queuedRequests(outbox).isEmpty)
    #expect(!FileManager.default.fileExists(atPath: stored.path))
    let withdrawn = try await until(session) { _ in true }
    #expect(!withdrawn.rows.contains { $0.inputID == staged.inputID })
    #expect(withdrawn.sends["send-4"] == nil)
    await session.start(staged)
    #expect(await fixture.count() == 0, "Nothing staged or withdrawn leaves the phone")

    let again = try #require(
      await session.stage("To both", files: [file], sendID: "send-5", recipients: recipients))
    await session.start(again)
    await session.unstage(again)
    #expect(try queuedRequests(outbox).map(\.inputId) == [again.inputID], "Started stays queued")
    try await eventually("the started input") { await fixture.count() == 1 }
    let submitted = await fixture.received().compactMap {
      if case .submit(let input) = $0 { input.inputId } else { nil }
    }
    #expect(submitted == [again.inputID])
  }
}
