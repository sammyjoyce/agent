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
        == SendStatus(recipients: [directory.profile], progress: .pending(.uncertain)))
    await second.retry(staged.inputID)
    let entry = "placed-\(staged.inputID)"
    let placed = try await until(second) {
      $0.connection == .connected
        && $0.rows.contains { $0.entryID == entry && $0.delivery == .saved }
    }
    let row = try #require(placed.rows.first { $0.entryID == entry })
    #expect(row.receivedAt == queuedAt, "The queue time moved to the entry")
    #expect(row.sendID == "send-1")
    #expect(
      placed.sends["send-1"] == SendStatus(recipients: [directory.profile], progress: .placed))
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
        == Ledger.Send(
          inputID: staged.inputID, entryID: entry, recipients: [directory.profile],
          queuedAt: item.queuedAt))
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

/// A restored item, which its coordinator refused, is discarded once its copy was sent instead. The
/// ledger keeps that the item was withdrawn, after the outbox lets it go and across a relaunch, so
/// its Send reads not sent here.
@Test(.timeLimit(.minutes(1)))
func aDiscardedItemIsRecordedAsWithdrawnAcrossARelaunch() async throws {
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let recipients = [directory.profile, ProfileID()]
    let drafts = AttachmentStore(
      directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    let file = try await drafts.stage(
      data: Data("Invented key photo".utf8), name: "Key.txt", mediaType: "text/plain")
    defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    await fixture.refuseUploads()
    let staged = try #require(
      await first.stage(
        "Invented: the spare key is under the mat", files: [file], sendID: "send-7",
        recipients: recipients))
    await first.start(staged)
    _ = try await until(first) {
      $0.rows.contains { $0.inputID == staged.inputID && $0.delivery == .rejected }
    }
    await first.discard(staged.inputID)
    let withdrawn = SendStatus(recipients: recipients, progress: .withdrawn)
    _ = try await until(first) { $0.sends["send-7"] == withdrawn }
    #expect(try queuedRequests(directory.outbox).isEmpty)
    #expect(try savedLedger(directory).sends["send-7"]?.withdrawn == true)
    await first.disconnect()

    let second = try await launch()
    await second.connect()
    let relaunched = try await until(second) { $0.connection == .connected }
    #expect(relaunched.sends["send-7"] == withdrawn)
    #expect(await fixture.count() == 0, "A withdrawn item never left the phone")
  }
}

/// The coordinator's refusal is saved with the queued item. After a relaunch, Check / retry that
/// is refused again before its submit is written keeps it, so sending the restored copy still
/// withdraws the original, and nothing sends it again.
@Test(.timeLimit(.minutes(1)))
func aRefusalSavedWithTheQueuedItemStillWithdrawsItAfterARelaunch() async throws {
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let drafts = AttachmentStore(
      directory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    let file = try await drafts.stage(
      data: Data("Invented boarding pass".utf8), name: "Pass.txt", mediaType: "text/plain")
    defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    await fixture.refuseUploads()
    let staged = try #require(
      await first.stage(
        "Invented: the boarding pass for Friday", files: [file], sendID: "send-11",
        recipients: [directory.profile]))
    await first.start(staged)
    _ = try await until(first) {
      $0.rows.contains { $0.inputID == staged.inputID && $0.delivery == .rejected }
    }
    await first.disconnect()

    let second = try await launch()
    await second.connect()
    _ = try await until(second) { $0.connection == .connected }
    await second.retry(staged.inputID)
    _ = try await until(second) { $0.error == "Attachment storage is full" }
    #expect(await fixture.count() == 0, "The retry never wrote its submit")
    await second.discard(staged.inputID)
    #expect(try outboxItems(directory.outbox).isEmpty)
    #expect(try savedLedger(directory).sends["send-11"]?.withdrawn == true)
    await fixture.acceptUploads()
    await second.retry(staged.inputID)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await fixture.count() == 0, "A withdrawn item never left the phone")
  }
}

/// A coordinator may still place an input it refused, so each withdrawn input stays watched. The
/// observation carries every queued input, then the newest withdrawn ones, up to the coordinator's
/// cap of 32.
@Test(.timeLimit(.minutes(1)))
func theObservationWatchesTheNewestWithdrawnInputsUpToTheCap() async throws {
  try await withProfile { fixture, directory, launch in
    let queued = (1...3).map {
      NativeRequestSubmit(inputId: "queued-\($0)", mode: .steer, text: "Invented note \($0)")
    }
    try saveOutbox(queued, in: directory)
    var ledger = Ledger()
    for index in 1...40 {
      ledger.sends["send-\(index)"] = Ledger.Send(
        inputID: "withdrawn-\(index)", recipients: [directory.profile],
        queuedAt: TimeInterval(index), withdrawn: true)
    }
    try writePrivately(JSONEncoder().encode(ledger), to: directory.ledger)
    let session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let observed = await fixture.received().compactMap {
      if case .observe(let request) = $0 { request.inputIds } else { nil }
    }
    print("IF7-V1[watch] observed \(observed.last?.count ?? 0) IDs: \(observed.last ?? [])")
    #expect(
      observed.last == queued.map(\.inputId) + (12...40).reversed().map { "withdrawn-\($0)" })
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
    // The fixture closes the submit's socket, so the session reconnects, and it can publish the
    // placement before that reconnect completes. Latest loads nothing until it has.
    let placed = try await until(session) {
      $0.connection == .connected
        && $0.rows.contains { $0.sendID == "send-2" && $0.entryID != nil && $0.delivery == .saved }
    }
    #expect(placed.sends["send-2"] == SendStatus(recipients: recipients, progress: .placed))
    await fixture.replyToLatest(
      .init(messages: [reply("newer", "A newer page")], pageComplete: true))
    await session.loadLatest()
    let evicted = try await until(session) {
      $0.rows.contains { $0.entryID == "newer" } && !$0.rows.contains { $0.sendID == "send-2" }
    }
    #expect(evicted.sends["send-2"] == SendStatus(recipients: recipients, progress: .placed))
  }
}

@Test(.timeLimit(.minutes(1)))
func anOlderSendKeepsItsSendIDAfterItsEntryLeavesTheCappedLedger() async throws {
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let recipients = [directory.profile, ProfileID()]
    let staged = try #require(
      await first.stage("To both", sendID: "send-old", recipients: recipients))
    await first.start(staged)
    let placed = try await until(first) {
      $0.rows.contains { $0.sendID == "send-old" && $0.entryID != nil && $0.delivery == .saved }
    }
    let entry = try #require(placed.rows.first { $0.sendID == "send-old" }?.entryID)
    await first.disconnect()
    var ledger = try savedLedger(directory)
    let newest = try #require(ledger.entries.values.map(\.receivedAt).max())
    for index in 0..<2000 {
      ledger.entries["later-\(index)"] = Ledger.Entry(receivedAt: newest + 1 + Double(index))
    }
    try writePrivately(JSONEncoder().encode(ledger), to: directory.ledger)
    await fixture.replyToHistory(
      initial: .init(
        messages: [reply("today", "A reply from today")], nextCursor: "older", pageComplete: true),
      pages: [
        "older": .init(
          messages: [reply(entry, role: .user, "To both")], nextCursor: nil, pageComplete: true)
      ])
    let second = try await launch()
    await second.connect()
    _ = try await until(second) { $0.rows.contains { $0.entryID == "today" } }
    #expect(try savedLedger(directory).entries[entry] == nil, "Its entry left the capped ledger")
    await second.loadEarlier()
    let older = try await until(second) { $0.rows.contains { $0.entryID == entry } }
    #expect(older.rows.first { $0.entryID == entry }?.sendID == "send-old")
    #expect(older.sends["send-old"] == SendStatus(recipients: recipients, progress: .placed))
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
    ["AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"],"queued_at":1762100000.25}}}
    """
  let saved = try JSONDecoder().decode(Ledger.self, from: Data(ledger.utf8))
  #expect(saved.entries["entry-1"] == Ledger.Entry(receivedAt: 1_762_100_000.25, sendID: "S1"))
  #expect(saved.entries["entry-2"] == Ledger.Entry(receivedAt: 1_762_100_001.5))
  #expect(
    saved.sends["S1"]?.entryID == "entry-1" && saved.sends["S1"]?.queuedAt == 1_762_100_000.25)
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

/// A settled `/feedback` has no entry. The time it was queued, kept in its saved record, still
/// ranks it among the newest.
@Test func theLedgerKeepsTheNewestSendsByWhenEachWasQueued() throws {
  var entries: [String: Any] = [:]
  var sends: [String: Any] = [
    "send-feedback": ["input_id": "input-feedback", "recipients": [String](), "queued_at": 2000.0]
  ]
  for index in 0..<2000 {
    entries["entry-\(index)"] = ["received_at": Double(index)]
    sends["send-\(index)"] = [
      "input_id": "input-\(index)", "entry_id": "entry-\(index)", "recipients": [String](),
      "queued_at": Double(index),
    ]
  }
  var ledger = try JSONDecoder().decode(
    Ledger.self,
    from: JSONSerialization.data(withJSONObject: ["entries": entries, "sends": sends]))
  ledger.prune(keeping: [])
  #expect(ledger.sends.count == 2000)
  #expect(ledger.sends["send-feedback"] != nil, "The newest send stays")
  #expect(ledger.sends["send-0"] == nil, "The oldest send goes")
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

/// Remove retires a session before it deletes the profile's files. Whoever still holds the
/// session, it never connects, sends a waiting input or a control, or writes the directory again.
/// Retiring returns, once, the started input it cancelled before it left the phone.
@Test(.timeLimit(.minutes(1)))
func aRetiredSessionNeverConnectsSendsOrWritesAgain() async throws {
  try await withProfile { fixture, directory, launch in
    let session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let waiting = try #require(
      await session.stage(
        "Invented: call the vet", sendID: "send-8", recipients: [directory.profile]))
    let control = try #require(
      await session.stage("/status", sendID: "send-9", recipients: [directory.profile]))
    await session.disconnect()
    #expect(await session.start(waiting) == .started, "It waits for its lane to connect")
    #expect(await session.retire() == [waiting])
    #expect(await session.retire().isEmpty, "Once")
    let requests = await fixture.received().count
    await session.connect()
    try await Task.sleep(for: .seconds(1))
    #expect(await fixture.received().count == requests, "Nothing dials the coordinator again")
    #expect(await session.start(control) == .retired, "Its sender names what it did not send")
    #expect(await session.start(waiting) == .retired)
    try directory.remove()
    #expect(
      await session.stage("Invented: one more", sendID: "send-10", recipients: [directory.profile])
        == nil)
    await session.retry(waiting.inputID)
    await session.discard(waiting.inputID)
    try await Task.sleep(for: .milliseconds(200))
    #expect(await fixture.count() == 0, "Nothing was sent")
    #expect(
      !FileManager.default.fileExists(atPath: directory.root.path),
      "Nothing writes the deleted directory")
  }
}

/// A Send stages an input, and an address edit retires the session before the Send starts it. The
/// profile's next session shows the input as unconfirmed, since it cannot know the input never
/// left. The Send then reaches no one, so its sender withdraws the input. The retired session
/// writes nothing, and the next session withdraws it: before it connects, or while a Check / retry
/// it started has not written the input yet. Once that Check / retry wrote it, the coordinator may
/// hold it, so it stays queued.
@Test(
  .timeLimit(.minutes(1)),
  arguments: ["before it connects", "while Check / retry dials", "once Check / retry wrote it"])
func theNextSessionWithdrawsAnInputItsRetiredOneStagedUnlessItWroteIt(_ when: String)
  async throws
{
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let staged = try #require(
      await first.stage(
        "Invented: the venue is booked", sendID: "send-11", recipients: [directory.profile]))
    await first.retire()
    await first.unstage(staged)
    let keptByRetired = try outboxItems(directory.outbox).map(\.request.inputId)
    let next = try await launch()
    if when == "before it connects" {
      await next.unstage(staged)
      await next.connect()
      _ = try await until(next) { $0.connection == .connected }
    } else {
      await next.connect()
      _ = try await until(next) { snapshot in
        snapshot.connection == .connected
          && snapshot.rows.contains { $0.inputID == staged.inputID && $0.delivery == .uncertain }
      }
      if when == "while Check / retry dials" {
        await fixture.holdNextIdentity()
        await next.retry(staged.inputID)
        try await eventually("Check / retry's socket proving the coordinator") {
          await fixture.identityHeld
        }
        await next.unstage(staged)
        await fixture.releaseIdentity()
      } else {
        await fixture.holdNextSubmitReply()
        await next.retry(staged.inputID)
        try await eventually("the coordinator read the input") { await fixture.count() == 1 }
        await next.unstage(staged)
      }
    }
    try await Task.sleep(for: .milliseconds(300))
    let queued = (try? outboxItems(directory.outbox).map(\.request.inputId)) ?? []
    print(
      "IF11-2[\(when)] kept by the retired session=\(keptByRetired.count) queued once the next one withdrew it=\(queued.count) coordinator got=\(await fixture.count())"
    )
    #expect(keptByRetired == [staged.inputID], "The retired session wrote its outbox")
    if when == "once Check / retry wrote it" {
      #expect(queued == [staged.inputID], "An input that may have left the phone was withdrawn")
    } else {
      #expect(queued.isEmpty, "The next session kept an input that never left the phone")
      #expect(await fixture.count() == 0, "The withdrawn input was sent")
    }
  }
}

/// A Send stages an input, and an address edit retires the session that staged it. The next session
/// writes it with Check / retry, and the coordinator accepts it. More edits replace that session
/// before the Send, which reached no one, withdraws the input through the session that holds the
/// outbox then. The input may have left the phone, so it stays queued until its coordinator places
/// it, however many edits followed, and before or after that session saw the acceptance. An input
/// no session wrote is withdrawn.
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "never written", "before it connects", "once it saw the acceptance", "three edits on",
  ])
func noSessionWithdrawsAnInputAnEarlierSessionWrote(_ when: String) async throws {
  try await withProfile { fixture, directory, launch in
    let first = try await launch()
    await first.connect()
    _ = try await until(first) { $0.connection == .connected }
    let staged = try #require(
      await first.stage(
        "Invented: the venue deposit is paid", sendID: "send-12", recipients: [directory.profile]))
    await first.retire()
    var session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    if when != "never written" {
      await fixture.holdPlacements()
      await session.retry(staged.inputID)
      _ = try await until(session) { snapshot in
        snapshot.rows.contains { $0.inputID == staged.inputID && $0.delivery == .saved }
      }
    }
    for _ in 1...(when == "three edits on" ? 3 : 1) {
      await session.retire()
      session = try await launch()
      guard when == "once it saw the acceptance" || when == "three edits on" else { continue }
      await session.connect()
      _ = try await until(session) { snapshot in
        snapshot.connection == .connected
          && snapshot.rows.contains { $0.inputID == staged.inputID && $0.delivery == .saved }
      }
    }
    #expect(await session.unstage(staged))
    let queued = try outboxItems(directory.outbox).map(\.request.inputId)
    print(
      "IF12-1[\(when)] queued once the latest session withdrew it=\(queued.count) coordinator got=\(await fixture.count())"
    )
    guard when != "never written" else {
      #expect(queued.isEmpty, "An input no session wrote stayed queued")
      #expect(await fixture.count() == 0)
      return
    }
    try #require(queued == [staged.inputID], "An input a Check / retry wrote was withdrawn")
    try await fixture.finishTurn()
    await session.connect()
    let placed = try await until(session) { snapshot in
      snapshot.rows.contains { $0.entryID == "placed-\(staged.inputID)" && $0.delivery == .saved }
    }
    print(
      "IF12-1[\(when)] once placed: send=\(String(describing: placed.sends["send-12"]?.progress))")
    #expect(
      placed.sends["send-12"] == SendStatus(recipients: [directory.profile], progress: .placed))
    #expect(try outboxItems(directory.outbox).isEmpty)
    #expect(await fixture.count() == 1, "Sent once")
  }
}

/// Before a submit is written, the outbox saves that its input may have left the phone. When that
/// cannot be saved, the submit is not written, since a later session would read the input as never
/// sent and could withdraw it. It never left, so it needs attention.
@Test(.timeLimit(.minutes(1)))
func aSubmitIsNotWrittenWhileTheOutboxCannotSayItMayLeave() async throws {
  try await withProfile { fixture, directory, launch in
    let session = try await launch()
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let staged = try #require(
      await session.stage(
        "Invented: the alarm code changed", sendID: "send-13", recipients: [directory.profile]))
    let folder = directory.outbox.deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
    await session.start(staged)
    let failed = try await until(session) { snapshot in
      snapshot.rows.contains { $0.inputID == staged.inputID && $0.delivery != .sending }
    }
    let row = failed.rows.first { $0.inputID == staged.inputID }
    print(
      "IF12-1[unsaved] error=\(failed.error ?? "nil") row=\(row?.delivery?.rawValue ?? "none") coordinator got=\(await fixture.count())"
    )
    #expect(failed.error == "The on-device outbox could not be saved. Nothing was sent.")
    #expect(row?.delivery == .rejected)
    #expect(await fixture.count() == 0, "The submit was written")
  }
}

/// An older build saved no staged mark, so an input it queued may have left the phone, and no
/// session withdraws it.
@Test(.timeLimit(.minutes(1)))
func anInputAnOlderBuildQueuedIsNeverWithdrawn() async throws {
  try await withProfile { fixture, directory, launch in
    let request = NativeRequestSubmit(
      inputId: UUID().uuidString, mode: .steer, text: "Invented: the boiler service is booked")
    try saveOutbox([request], in: directory)
    let item = try #require(try outboxItems(directory.outbox).first)
    let session = try await launch()
    await session.unstage(
      StagedInput(
        inputID: request.inputId, sendID: item.sendID, profile: directory.profile, control: nil))
    let queued = try outboxItems(directory.outbox).map(\.request.inputId)
    print("IF12-1[older build] queued once a session withdrew it=\(queued.count)")
    #expect(queued == [request.inputId])
    await session.connect()
    let shown = try await until(session) { $0.connection == .connected }
    let row = shown.rows.first { $0.inputID == request.inputId }
    #expect(row?.delivery == .uncertain)
    #expect(await fixture.count() == 0)
  }
}

enum LaneReturn: Sendable { case reconnect, foreground }

@Test(.timeLimit(.minutes(1)), arguments: [LaneReturn.reconnect, .foreground])
func aStagedInputWhoseLaneDropsBeforeStartIsSentOnceItsLaneReturns(_ lane: LaneReturn)
  async throws
{
  try await withCoordinator { session, fixture, outbox in
    await session.connect()
    _ = try await until(session) { $0.connection == .connected }
    let staged = try #require(
      await session.stage(
        "Landing at 6, call me", sendID: "send-6", recipients: [session.profile]))
    func expectWaiting(_ snapshot: ChatSnapshot) async {
      #expect(
        snapshot.rows.first { $0.inputID == staged.inputID }?.delivery == .sending,
        "It never left the phone, so it is not unconfirmed")
      #expect(snapshot.sends["send-6"]?.progress == .pending(.sending))
      #expect(await fixture.count() == 0)
    }
    // The lane cannot connect again until the snapshot is released.
    await fixture.holdSnapshot()
    try await fixture.emitOnObserver(.done)
    _ = try await until(session) { $0.connection == .reconnecting }
    await session.start(staged)
    switch lane {
    case .reconnect:
      await expectWaiting(try await until(session) { $0.connection == .reconnecting })
    case .foreground:
      await session.disconnect()
      await expectWaiting(try await until(session) { $0.connection == .disconnected })
      await session.connect()
      await expectWaiting(try await until(session) { $0.connection == .connecting })
    }
    await fixture.releaseSnapshot()
    let entry = "placed-\(staged.inputID)"
    try await eventually("the waiting input placed") {
      try queuedRequests(outbox).isEmpty
    }
    let placed = try await until(session) {
      $0.connection == .connected
        && $0.rows.contains { $0.entryID == entry && $0.delivery == .saved }
    }
    #expect(placed.sends["send-6"] == SendStatus(recipients: [session.profile], progress: .placed))
    let submitted = await fixture.received().compactMap {
      if case .submit(let input) = $0 { input } else { nil }
    }
    #expect(submitted.map(\.inputId) == [staged.inputID], "Sent once, under its own input ID")
    #expect(submitted.map(\.text) == ["Landing at 6, call me"])
  }
}
