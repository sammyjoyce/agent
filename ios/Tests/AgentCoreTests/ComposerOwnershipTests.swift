import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

private actor ComposerOwnershipGate {
  nonisolated let entered = AsyncStream<Bool>.makeStream()
  private var continuation: CheckedContinuation<Void, Never>?

  func wait(after admitted: Bool) async -> Bool {
    await withCheckedContinuation { continuation in
      self.continuation = continuation
      entered.continuation.yield(admitted)
    }
    return admitted
  }
  func finish() {
    continuation?.resume()
    continuation = nil
  }
}

/// The lane's latest snapshot in `model` once it satisfies `predicate`. The model is the one
/// reader of its session's updates.
@MainActor private func snapshot(
  of session: CoordinatorSession, in model: ChatModel, where predicate: (ChatSnapshot) -> Bool
) async throws -> ChatSnapshot {
  let deadline = ContinuousClock.now + .seconds(8)
  while true {
    if let snapshot = model.snapshots[session.profile], predicate(snapshot) { return snapshot }
    guard ContinuousClock.now < deadline else { throw ConnectionError.timedOut }
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Attaches `sessions` as `model`'s coordinators, in order, and waits for each to connect.
@MainActor private func connect(
  _ model: ChatModel, to sessions: CoordinatorSession...
) async throws {
  for session in sessions { model.attach(lane(session)) }
  await model.setActive(true)
  for session in sessions {
    _ = try await snapshot(of: session, in: model) { $0.connection == .connected }
  }
}

/// Connects `session` and waits until it is connected. Nothing else reads its updates.
private func connected(_ session: CoordinatorSession) async throws {
  await session.connect()
  for await snapshot in session.updates where snapshot.connection == .connected { return }
  throw ConnectionError.closed
}

enum ComposerOwnershipStage: CaseIterable, Sendable {
  case admitted, accepted, placed, retired, liveRetry, relocated
}

@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ComposerOwnershipStage.allCases, [false, true])
func admittedComposerOwnershipSurvivesFailedCheckpointAndColdRestore(
  stage: ComposerOwnershipStage, newTyping: Bool
) async throws {
  try await withCoordinator { session, fixture, outbox in
    if stage == .admitted || stage == .liveRetry || stage == .relocated {
      await fixture.loseInputAcknowledgements()
    }
    if stage == .retired { await fixture.refuseUploads() }
    let root = outbox.deletingLastPathComponent()
    let directory = root.appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: root.appending(path: "Drafts"))
    let gate = ComposerOwnershipGate()
    let model = await MainActor.run {
      ChatModel(
        draftStore: files, persistence: ComposerDraftStore(url: url),
        admit: { deliver in await gate.wait(after: await deliver()) })
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    let original = "Two different drafts can contain this exact same text."
    await MainActor.run { model.draft = original }
    await model.attach(
      data: Data("Original file".utf8), name: "Original.txt", mediaType: "text/plain")
    try #require(await model.saveDraft())
    let originalFile = try #require(await model.attachments.first)
    let sending = Task { await model.send() }
    for await admitted in gate.entered.stream {
      try #require(admitted)
      break
    }
    let input = try #require(queuedRequests(outbox).first)
    #expect(input.text == original)
    switch stage {
    case .admitted, .liveRetry, .relocated: break
    case .accepted:
      _ = try await snapshot(of: session, in: model) {
        $0.rows.contains { $0.inputID == input.inputId && $0.delivery == .saved }
      }
    case .placed:
      let deadline = ContinuousClock.now + .seconds(8)
      while await fixture.count() == 0 {
        try #require(ContinuousClock.now < deadline)
        try await Task.sleep(for: .milliseconds(5))
      }
      await session.connect()
      _ = try await snapshot(of: session, in: model) {
        $0.connection == .connected
          && $0.rows.contains { $0.entryID == "placed-\(input.inputId)" }
      }
      #expect(try queuedRequests(outbox).isEmpty)
    case .retired:
      _ = try await snapshot(of: session, in: model) {
        $0.rows.contains { $0.inputID == input.inputId && $0.delivery == .rejected }
      }
      let recoveredFiles = AttachmentStore(directory: root.appending(path: "RecoveredFiles"))
      let recovered = try #require(await session.restore(input.inputId, to: recoveredFiles))
      try await ComposerDraftStore(url: root.appending(path: "recovered.json")).save(
        ComposerDraft(
          text: recovered.text, mode: recovered.mode, attachments: recovered.attachments),
        revision: 1)
      #expect(await session.commitRestoration(recovered) == .committed)
      #expect(try queuedRequests(outbox).isEmpty)
    }
    let newText = newTyping ? original : ""
    if newTyping {
      await MainActor.run {
        model.draft = newText
        model.mode = .followUp
      }
      await model.attach(data: Data("New file".utf8), name: "New.txt", mediaType: "text/plain")
      try #require(await model.saveDraft())
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await gate.finish()
    await sending.value
    #expect(await model.draft == newText)
    #expect(await model.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    #expect(await model.draftError != nil)

    var coldRoot = root
    var coldDirectory = directory
    var coldFiles = files
    var originalFileURL = originalFile.url
    if stage == .relocated {
      await session.disconnect()
      coldRoot = root.deletingLastPathComponent().appending(path: UUID().uuidString)
      try FileManager.default.moveItem(at: root, to: coldRoot)
      coldDirectory = coldRoot.appending(path: "Composer")
      coldFiles = AttachmentStore(directory: coldRoot.appending(path: "Drafts"))
      originalFileURL = try #require(await coldFiles.existing(originalFile.reference)).url
    }
    defer {
      if stage == .relocated {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: coldDirectory.path)
        try? FileManager.default.removeItem(at: coldRoot)
      }
    }

    // A different endpoint must not hide the admission proof in the original
    // endpoint's outbox. Receipt retirement must not hide it either.
    let cold: ChatModel
    if stage == .liveRetry {
      cold = model
    } else {
      let elsewhere = coldRoot.appending(path: "OtherEndpoint")
      let other = CoordinatorSession(
        directory: ProfileDirectory(ProfileID(), applicationSupport: elsewhere, caches: elsewhere),
        address: try CoordinatorAddress(host: "100.64.1.3"), pin: CoordinatorID(UUID()),
        stamps: StampSource(),
        transport: CoordinatorTransport { _ in throw ConnectionError.closed })
      cold = await MainActor.run {
        let cold = ChatModel(
          draftStore: coldFiles,
          persistence: ComposerDraftStore(url: coldDirectory.appending(path: "draft.json")))
        cold.attach(lane(other))
        return cold
      }
      await cold.restoreDraft()
    }
    #expect(FileManager.default.fileExists(atPath: originalFileURL.path))
    #expect(await cold.draft == newText)
    #expect(await cold.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    if newTyping {
      #expect(await cold.mode == .followUp)
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New file".utf8))
    }
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: coldDirectory.path)
    try #require(await cold.saveDraft())
    #expect(!FileManager.default.fileExists(atPath: originalFileURL.path))
    if newTyping {
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New file".utf8))
    }
  }
}

@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: [(false, false), (true, false), (false, true), (true, true)])
func failedInitialComposerOrOutboxPersistenceDoesNotClaimTheDraft(
  outboxFailure: Bool, control: Bool
) async throws {
  try await withCoordinator { session, fixture, outbox in
    let directory = outbox.deletingLastPathComponent().appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: directory.appending(path: "Files"))
    let model = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    let text = control ? "/status" : "Keep this unadmitted note."
    await MainActor.run { model.draft = text }
    if !control {
      await model.attach(data: Data("Keep file".utf8), name: "Keep.txt", mediaType: "text/plain")
    }
    try #require(await model.saveDraft())
    if outboxFailure {
      try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    } else {
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
    }
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await model.send()
    #expect(await model.draft == text)
    #expect(await fixture.count() == 0)
    if outboxFailure {
      try FileManager.default.removeItem(at: outbox)
      // Rejection restores the live draft in defer and schedules its autosave.
      // Finish that owner before simulating a cold process with another store.
      try #require(await model.saveDraft())
    }
    let cold = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await cold.restoreDraft()
    #expect(await cold.draft == text)
    #expect(await cold.attachments.map(\.reference.name) == (control ? [] : ["Keep.txt"]))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func acceptedSlashControlDoesNotReturnFromAFailedComposerCheckpoint(newTyping: Bool) async throws {
  try await withCoordinator { session, fixture, outbox in
    let directory = outbox.deletingLastPathComponent().appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: directory.appending(path: "Files"))
    let gate = ComposerOwnershipGate()
    let model = await MainActor.run {
      ChatModel(
        draftStore: files, persistence: ComposerDraftStore(url: url),
        admit: { deliver in await gate.wait(after: await deliver()) })
    }
    await model.restoreDraft()
    try await connect(model, to: session)
    await MainActor.run { model.draft = "/status" }
    let sending = Task { await model.send() }
    for await admitted in gate.entered.stream {
      try #require(admitted)
      break
    }
    for await input in fixture.observedInputs {
      #expect(input.text == "/status")
      #expect(input.attachments == nil)
      break
    }
    let newText = newTyping ? "/status" : ""
    if newTyping {
      await MainActor.run { model.draft = newText }
      await model.attach(data: Data("New note".utf8), name: "New.txt", mediaType: "text/plain")
      try #require(await model.saveDraft())
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await gate.finish()
    await sending.value
    #expect(await model.draft == newText)
    #expect(await model.draftError != nil)
    let cold = await MainActor.run {
      ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    }
    await cold.restoreDraft()
    #expect(await cold.draft == newText)
    #expect(await cold.attachments.map(\.reference.name) == (newTyping ? ["New.txt"] : []))
    if newTyping {
      let file = try #require(await cold.attachments.first)
      #expect(try Data(contentsOf: file.url) == Data("New note".utf8))
    }
    if FileManager.default.fileExists(atPath: outbox.path) {
      #expect(try queuedRequests(outbox).isEmpty, "Controls must not enter the replayable queue")
    }
    await session.disconnect()
    _ = try await snapshot(of: session, in: model) { $0.connection == .disconnected }
    await session.connect()
    let reconnected = try await snapshot(of: session, in: model) { $0.connection == .connected }
    #expect(reconnected.rows.isEmpty)
    #expect(await fixture.count() == 1, "Reconnection must not submit the control again")
  }
}

/// What the second recipient of a two-coordinator Send does with its copy.
enum SecondRecipient: CaseIterable, Sendable {
  case runsIt, isNotConnected
  /// Its session retires before the Send starts its copy, as an address edit retires it.
  case retiresFirst

  /// What `start` answers for its copy.
  var start: StartOutcome {
    switch self {
    case .runsIt: .started
    case .isNotConnected: .notSent
    case .retiresFirst: .retired
    }
  }
}

/// A control sent to two coordinators misses the first, and the second runs it or misses too. The
/// app stops before it saves a newer draft. Recovery from the checkpoint saved before the Send
/// offers the control again only when neither ran it, since sending it again runs it twice.
@Test(.timeLimit(.minutes(1)), arguments: SecondRecipient.allCases)
func recoveryOffersASendAgainOnlyWhenNoRecipientReceivedIt(second outcome: SecondRecipient)
  async throws
{
  let secondMisses = outcome != .runsIt
  try await withCoordinator { first, firstFixture, firstOutbox in
    try await withCoordinator { second, secondFixture, secondOutbox in
      try await connected(first)
      try await connected(second)
      let root = firstOutbox.deletingLastPathComponent()
      let files = AttachmentStore(directory: root.appending(path: "ProbeFiles"))
      let url = root.appending(path: "probe-draft.json")
      let store = ComposerDraftStore(url: url)
      _ = try await store.load(from: files)
      let identity = ComposerInputIdentity(composerID: UUID())
      let submission = ComposerSubmission(
        identity: identity, outboxURLs: [firstOutbox, secondOutbox], text: "/status",
        attachments: [])
      try await store.save(
        ComposerDraft(composerID: identity.composerID, submission: submission), revision: 1)
      let recipients = [first.profile, second.profile]
      let stagedFirst = try #require(
        await first.stage(
          "/status", sendID: "invented-send", recipients: recipients, composer: identity))
      let stagedSecond = try #require(
        await second.stage(
          "/status", sendID: "invented-send", recipients: recipients, composer: identity))
      #expect(try CoordinatorSession.ownsComposerInput(identity, outboxURL: firstOutbox))
      #expect(try CoordinatorSession.ownsComposerInput(identity, outboxURL: secondOutbox))
      await first.disconnect()
      switch outcome {
      case .runsIt: break
      case .isNotConnected: await second.disconnect()
      case .retiresFirst:
        #expect(await second.retire().isEmpty, "The second session had started nothing")
      }
      #expect(await first.start(stagedFirst) == .notSent)
      #expect(await second.start(stagedSecond) == outcome.start)
      let deadline = ContinuousClock.now + .seconds(5)
      while !secondMisses, await secondFixture.count() == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      #expect(await firstFixture.count() == 0)
      #expect(await secondFixture.count() == (secondMisses ? 0 : 1))
      #expect(
        try !CoordinatorSession.ownsComposerInput(identity, outboxURL: firstOutbox),
        "The first outbox released the receipt")
      let secondHolds = try CoordinatorSession.ownsComposerInput(identity, outboxURL: secondOutbox)
      #expect(secondHolds == !secondMisses, "The second outbox holds it while its copy went")
      let recovered = try await ComposerDraftStore(url: url).load(from: files)
      #expect(
        recovered.draft.text == (secondMisses ? "/status" : ""),
        "/status comes back only when neither coordinator ran it")
    }
  }
}

enum RecipientOutbox: CaseIterable, Sendable { case first, second }

/// A Send to two coordinators reaches both, and the checkpoint after it fails, so the saved draft
/// still holds the Send. One recipient's outbox is then gone, as after Remove deletes that
/// coordinator. The other recipient still proves the Send went.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: RecipientOutbox.allCases)
func aSendBothCoordinatorsReceivedIsNotOfferedAgainWhenOneOutboxIsGone(
  gone: RecipientOutbox
) async throws {
  try await withCoordinator { first, firstFixture, firstOutbox in
    try await withCoordinator { second, secondFixture, secondOutbox in
      let directory = firstOutbox.deletingLastPathComponent().appending(path: "Composer")
      let url = directory.appending(path: "draft.json")
      let files = AttachmentStore(directory: directory.appending(path: "Files"))
      let gate = ComposerOwnershipGate()
      let model = await MainActor.run {
        ChatModel(
          draftStore: files, persistence: ComposerDraftStore(url: url),
          admit: { deliver in await gate.wait(after: await deliver()) })
      }
      await model.restoreDraft()
      try await connect(model, to: first, second)
      await MainActor.run { model.draft = "/status" }
      let sending = Task { await model.send() }
      for await admitted in gate.entered.stream {
        try #require(admitted)
        break
      }
      for fixture in [firstFixture, secondFixture] {
        for await input in fixture.observedInputs {
          #expect(input.text == "/status")
          break
        }
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o500], ofItemAtPath: directory.path)
      defer {
        try? FileManager.default.setAttributes(
          [.posixPermissions: 0o700], ofItemAtPath: directory.path)
      }
      await gate.finish()
      await sending.value
      #expect(await model.draft.isEmpty)
      #expect(await model.draftError != nil, "The checkpoint after the Send failed")
      try FileManager.default.removeItem(at: gone == .first ? firstOutbox : secondOutbox)
      let cold = await MainActor.run {
        ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
      }
      await cold.restoreDraft()
      let offered = await cold.draft
      #expect(offered.isEmpty, "Both coordinators ran /status, so it stays sent")
      #expect(await firstFixture.count() == 1, "The first coordinator got /status once")
      #expect(await secondFixture.count() == 1, "The second coordinator got /status once")
    }
  }
}

/// A checkpoint the previous build saved during a Send names its one outbox under `outboxPath`.
/// While that outbox holds the receipt, the Send stays sent.
@Test(.timeLimit(.minutes(1)))
func aCheckpointNamingOneOutboxStaysSentWhileThatOutboxHoldsTheReceipt() async throws {
  try await withCoordinator { session, _, outbox in
    try await connected(session)
    let identity = ComposerInputIdentity(composerID: UUID())
    _ = try #require(
      await session.stage(
        "/status", sendID: "invented-send", recipients: [session.profile], composer: identity))
    let root = outbox.deletingLastPathComponent()
    let url = root.appending(path: "legacy-draft.json")
    let composer = identity.composerID.uuidString
    try Data(
      """
      {"revision":1,"text":"","mode":"steer","attachments":[],"consumedTransfers":[],
      "composerID":"\(composer)","submission":{"identity":{"composerID":"\(composer)",
      "inputID":"\(identity.inputID.uuidString)"},"outboxPath":"pending.json","text":"/status",
      "attachments":[]}}
      """.utf8
    ).write(to: url)
    let recovered = try await ComposerDraftStore(url: url).load(
      from: AttachmentStore(directory: root.appending(path: "LegacyFiles")))
    #expect(recovered.draft.text.isEmpty, "The outbox holds the receipt, so /status stays sent")
  }
}

/// Waits until `gate` holds a dial.
private func held(_ gate: DialGate) async throws {
  while await !gate.waiting { try await Task.sleep(for: .milliseconds(5)) }
}

/// A fixture coordinator and a session that dials it through `gate`, which can hold a Send's dial
/// so that its exchange waits before it writes anything.
private struct GatedCoordinator {
  let fixture: FixtureCoordinator
  let endpoint: NWEndpoint
  let directory: ProfileDirectory
  let gate: DialGate
  let session: CoordinatorSession
}

/// Runs `body` with `count` gated coordinators whose profiles share a fresh temporary root, then
/// opens every gate and stops them.
@MainActor private func withGatedCoordinators(
  _ count: Int, _ body: ([GatedCoordinator], URL) async throws -> Void
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  var listeners: [NWListener] = []
  defer {
    for listener in listeners { listener.cancel() }
    try? FileManager.default.removeItem(at: root)
  }
  var coordinators: [GatedCoordinator] = []
  for _ in 0..<count {
    let fixture = FixtureCoordinator()
    let (listener, endpoint) = try await listen(fixture)
    listeners.append(listener)
    let gate = DialGate()
    let directory = ProfileDirectory(ProfileID(), applicationSupport: root, caches: root)
    let session = CoordinatorSession(
      directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"), pin: fixture.id,
      stamps: StampSource(),
      transport: CoordinatorTransport { _ in
        await gate.pass()
        return LineConnection(connection: NWConnection(to: endpoint, using: .tcp))
      })
    coordinators.append(
      GatedCoordinator(
        fixture: fixture, endpoint: endpoint, directory: directory, gate: gate, session: session))
  }
  func stop() async {
    for coordinator in coordinators {
      await coordinator.gate.open()
      await coordinator.session.disconnect()
      await coordinator.fixture.stop()
    }
  }
  do { try await body(coordinators, root) } catch {
    await stop()
    throw error
  }
  await stop()
}

/// A Send has begun toward one coordinator, but its socket is still connecting, when an address
/// edit retires the session. Retirement cancels the input before it left the phone. The outbox
/// then releases a control's receipt, while a message's stays with its queued copy for the
/// profile's next session.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["/status", "An invented note"])
func retirementReleasesTheReceiptOfAControlItsSessionNeverWrote(text: String) async throws {
  try await withGatedCoordinators(1) { coordinators, _ in
    let coordinator = coordinators[0]
    let session = coordinator.session
    try await connected(session)
    await coordinator.gate.arm()
    let identity = ComposerInputIdentity(composerID: UUID())
    let staged = try #require(
      await session.stage(
        text, sendID: "invented-send", recipients: [session.profile], composer: identity))
    #expect(await session.start(staged) == .started)
    try await held(coordinator.gate)
    #expect(
      try CoordinatorSession.ownsComposerInput(identity, outboxURL: session.outboxURL),
      "The outbox holds the receipt while the Send is on its way")
    #expect(await session.retire() == [staged], "Retirement cancels the unwritten input")
    let holds = try CoordinatorSession.ownsComposerInput(identity, outboxURL: session.outboxURL)
    #expect(
      holds == !text.hasPrefix("/"),
      "The outbox releases a control's receipt and keeps a queued message's")
    #expect(await coordinator.fixture.count() == 0, "The coordinator got nothing")
  }
}

/// A Send of `/status` starts toward every recipient, and an address edit retires each session
/// while its socket is still connecting, so no coordinator gets it. The checkpoint after the Send
/// fails, as when the app stops before saving. Recovery offers `/status` again.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [1, 2])
func aSendAddressEditsStoppedEverywhereIsOfferedAgainAfterACrash(recipients: Int) async throws {
  try await withGatedCoordinators(recipients) { coordinators, root in
    let directory = root.appending(path: "Composer")
    let url = directory.appending(path: "draft.json")
    let files = AttachmentStore(directory: directory.appending(path: "Files"))
    let gate = ComposerOwnershipGate()
    let model = ChatModel(
      draftStore: files, persistence: ComposerDraftStore(url: url),
      admit: { deliver in await gate.wait(after: await deliver()) })
    await model.restoreDraft()
    for coordinator in coordinators { model.attach(lane(coordinator.session)) }
    await model.setActive(true)
    for coordinator in coordinators {
      _ = try await snapshot(of: coordinator.session, in: model) { $0.connection == .connected }
      await coordinator.gate.arm()
    }
    model.draft = "/status"
    let sending = Task { await model.send() }
    for await admitted in gate.entered.stream {
      try #require(admitted, "Every recipient started /status")
      break
    }
    for coordinator in coordinators {
      try await held(coordinator.gate)
      await model.detach(coordinator.session.profile)
      let next = CoordinatorSession(
        directory: coordinator.directory, address: try CoordinatorAddress(host: "100.64.1.2"),
        pin: coordinator.fixture.id, stamps: StampSource(),
        transport: loopback(coordinator.endpoint))
      model.attach(lane(next))
      await next.connect()
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    await gate.finish()
    await sending.value
    #expect(model.draftError != nil, "The checkpoint after the Send failed")
    let cold = ChatModel(draftStore: files, persistence: ComposerDraftStore(url: url))
    await cold.restoreDraft()
    #expect(cold.draft == "/status", "No coordinator ran /status, so it comes back")
    for coordinator in coordinators {
      #expect(await coordinator.fixture.count() == 0, "A coordinator got /status")
    }
    await model.setActive(false)
  }
}
