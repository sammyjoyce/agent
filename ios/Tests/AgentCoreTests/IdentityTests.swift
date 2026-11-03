import Foundation
import Network
import Testing

@testable import AgentCore

/// Stands in for a MagicDNS name that can be re-pointed at another coordinator.
private actor Route {
  private(set) var port: NWEndpoint.Port
  init(_ port: NWEndpoint.Port) { self.port = port }
  func point(to port: NWEndpoint.Port) { self.port = port }
}

private func snapshot(
  _ session: CoordinatorSession, where predicate: @Sendable (ChatSnapshot) -> Bool
) async throws -> ChatSnapshot {
  for await snapshot in session.updates where predicate(snapshot) { return snapshot }
  throw ConnectionError.closed
}

/// Two coordinators behind one re-pointable name. The session is pinned to the first. The
/// body gets both fixtures, the route, both ports and the session's directory.
private func withRepointedName(
  queue: [NativeRequestSubmit] = [],
  _ body:
    @Sendable (
      CoordinatorSession, FixtureCoordinator, FixtureCoordinator, Route, NWEndpoint.Port,
      NWEndpoint.Port, ProfileDirectory
    ) async throws -> Void
) async throws {
  let right = FixtureCoordinator()
  let wrong = FixtureCoordinator()
  let (rightListener, rightPort) = try await listen(right)
  defer { rightListener.cancel() }
  let (wrongListener, wrongPort) = try await listen(wrong)
  defer { wrongListener.cancel() }
  let route = Route(rightPort)
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  if !queue.isEmpty { try saveOutbox(queue, in: directory) }
  let session = CoordinatorSession(
    directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"), pin: right.id,
    stamps: StampSource(),
    transport: CoordinatorTransport { _ in
      LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: await route.port, using: .tcp))
    })
  do {
    try await body(session, right, wrong, route, rightPort, wrongPort, directory)
  } catch {
    await session.disconnect()
    await right.stop()
    await wrong.stop()
    throw error
  }
  await session.disconnect()
  await right.stop()
  await wrong.stop()
}

enum GatePath: CaseIterable, Sendable {
  case notifications, toolDetails, preview, history, submit, retry
}

/// The observer is verified, then the name moves to another coordinator. Every later
/// socket reaches that coordinator, which must see nothing but `identify`.
@Test(.timeLimit(.minutes(1)), arguments: GatePath.allCases)
func aSocketThatNamesAnotherCoordinatorCarriesOnlyIdentify(_ path: GatePath) async throws {
  let held = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .steer, text: "Queued for the paired coordinator")
  try await withRepointedName(queue: [held]) {
    session, right, wrong, route, _, wrongPort, directory in
    await session.connect()
    _ = try await snapshot(session) { $0.connection == .connected }
    await route.point(to: wrongPort)
    let text = "Typed for the paired coordinator"
    switch path {
    case .notifications:
      await #expect(throws: ConnectionError.wrongCoordinator) {
        try await session.notifications(.status(.init(installationId: "\(directory.profile)")))
      }
    case .toolDetails:
      await #expect(throws: ConnectionError.wrongCoordinator) {
        try await session.toolDetails(entryID: "7", callID: "call-7")
      }
    case .preview:
      let reference = AttachmentRef(
        id: UUID().uuidString, mediaType: "text/plain", name: "Notes.txt",
        sha256: String(repeating: "0", count: 64), sizeBytes: 3)
      await #expect(throws: ConnectionError.wrongCoordinator) {
        try await session.preview(reference)
      }
    case .history:
      await session.loadLatest()
    case .submit:
      let drafts = AttachmentStore(directory: directory.root.appending(path: "Drafts"))
      let file = try await drafts.stage(
        data: Data("Attachment bytes".utf8), name: "Notes.txt", mediaType: "text/plain")
      #expect(await session.submit(text, files: [file]))
    case .retry:
      await session.retry(held.inputId)
    }
    switch path {
    case .notifications, .toolDetails, .preview: break
    case .history, .submit, .retry:
      let refused = try await snapshot(session) {
        $0.connection == .reconnecting && $0.error?.contains("different coordinator") == true
      }
      #expect(refused.error?.contains("held on this phone. Remove it and add it again.") == true)
      #expect(refused.rows.first { $0.inputID == held.inputId }?.delivery == .uncertain)
      if path == .submit {
        let typed = try #require(refused.rows.first { $0.text == text })
        #expect(typed.delivery == .rejected || typed.delivery == .uncertain)
      }
    }
    let reached = await wrong.received()
    #expect(!reached.isEmpty)
    #expect(reached.allSatisfy { $0 == .identify }, "Only identify may reach another coordinator")
    #expect(await right.count() == 0)
    #expect(await right.uploadCount() == 0)
  }
}

@Test(.timeLimit(.minutes(1)))
func aNameThatReturnsToItsCoordinatorReconnectsAndReconciles() async throws {
  try await withRepointedName { session, right, wrong, route, rightPort, wrongPort, directory in
    await session.connect()
    _ = try await snapshot(session) { $0.connection == .connected }
    #expect(await session.submit("Keep this original"))
    // The fixture accepts, then drops the reply, so the observer must reconcile the ID. The
    // acceptance is saved, so the lost reply leaves it Saved rather than unconfirmed.
    let accepted = try await snapshot(session) { $0.rows.contains { $0.delivery == .saved } }
    let id = try #require(accepted.rows.first { $0.delivery == .saved }?.inputID)
    await route.point(to: wrongPort)
    let refused = try await snapshot(session) {
      $0.error?.contains("different coordinator") == true
    }
    #expect(refused.connection == .reconnecting)
    #expect(
      refused.error
        == "This address now answers as a different coordinator. 1 queued message is held on this phone. Remove it and add it again."
    )
    await route.point(to: rightPort)
    let recovered = try await snapshot(session) {
      $0.connection == .connected && $0.rows.contains { $0.inputID == id && $0.delivery == nil }
    }
    #expect(recovered.error == nil)
    #expect(try queuedRequests(directory.outbox).isEmpty)
    #expect(await right.count() == 1, "Reconciliation never resends")
    #expect(await right.received().contains(.observe(.init(inputIds: [id], sourceStatus: true))))
    #expect(await wrong.received().allSatisfy { $0 == .identify })
  }
}

@Test(.timeLimit(.minutes(1)))
func aCoordinatorWithoutIdentitiesFailsClosed() async throws {
  let fixture = FixtureCoordinator()
  await fixture.dropIdentify()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let held = NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Queued text")
  try saveOutbox([held], in: directory)
  let address = try CoordinatorAddress(host: "100.64.1.2")
  let session = CoordinatorSession(
    directory: directory, address: address, pin: CoordinatorID(UUID()), stamps: StampSource(),
    transport: loopback(port))
  await session.connect()
  let refused = try await snapshot(session) { $0.error != nil }
  await session.disconnect()
  #expect(refused.connection == .reconnecting)
  #expect(refused.error == "Update the coordinator to use it with this app.")
  await #expect(throws: ConnectionError.unidentifiedCoordinator) {
    try await identifyCoordinator(at: address, transport: loopback(port))
  }
  let reached = await fixture.received()
  #expect(!reached.isEmpty)
  #expect(reached.allSatisfy { $0 == .identify }, "Nothing follows an unanswered identify")
  #expect(try queuedRequests(directory.outbox) == [held])
  await fixture.stop()
}

@Test(.timeLimit(.minutes(1)))
func pairingProbeWritesOnlyIdentifyAndNamesTheCoordinator() async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let found = try await identifyCoordinator(
    at: CoordinatorAddress(host: "100.64.1.2"), transport: loopback(port))
  #expect(found == fixture.id)
  #expect(await fixture.received() == [.identify])
  await fixture.stop()
}

@Test(.timeLimit(.minutes(1)))
func anIdentityFrameAfterThePreambleFailsTheSocketClosed() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    _ = try await snapshot(session) { $0.connection == .connected }
    try await fixture.emitOnObserver(.identity(.init(coordinatorId: "\(fixture.id.uuid)")))
    let failed = try await snapshot(session) { $0.connection == .reconnecting }
    #expect(failed.error == "Update the coordinator to use it with this app.")
  }
}

@Test func pairingPinsOnceAndRefusesAnotherProfilesCoordinator() throws {
  let work = CoordinatorID(UUID())
  let personal = CoordinatorID(UUID())
  var profiles = [
    CoordinatorProfile(
      name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2")),
    CoordinatorProfile(
      name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3")),
  ]
  let first = profiles[0].id
  let second = profiles[1].id
  #expect(try CoordinatorProfile.admit(work, for: first, in: &profiles))
  #expect(profiles[0].pin == work)
  #expect(try !CoordinatorProfile.admit(work, for: first, in: &profiles), "Same coordinator")
  #expect(throws: ConnectionError.wrongCoordinator) {
    try CoordinatorProfile.admit(personal, for: first, in: &profiles)
  }
  #expect(profiles[0].pin == work, "A pin never changes")
  #expect(throws: ProfileError.duplicateCoordinator(savedAs: "Work")) {
    try CoordinatorProfile.admit(work, for: second, in: &profiles)
  }
  #expect(profiles[1].pin == nil)
  #expect(
    ProfileError.duplicateCoordinator(savedAs: "Work").localizedDescription
      == "Already saved as Work.")
}

@Test func coordinatorNamesAreTagsThatStayUniqueIgnoringCase() throws {
  for valid in ["Work", "a", "Work-1", "work_2", String(repeating: "x", count: 32)] {
    #expect(try TagName(valid).description == valid)
  }
  for invalid in [
    "", "-Work", "_Work", "My Mac", "Wörk", "@Work", String(repeating: "x", count: 33),
  ] {
    #expect(throws: ProfileError.invalidName) { try TagName(invalid) }
  }
  let work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  #expect(throws: ProfileError.duplicateName("Work")) {
    try CoordinatorProfile.checkName(try TagName("WORK"), for: nil, in: [work])
  }
  try CoordinatorProfile.checkName(try TagName("WORK"), for: work.id, in: [work])
  #expect(
    TagName(defaultFor: try CoordinatorAddress(host: "build-box.example-tailnet.ts.net"))
      .description == "build-box")
  #expect(
    TagName(defaultFor: try CoordinatorAddress(host: "100.64.1.2")).description == "Coordinator")
  #expect(
    TagName(
      defaultFor: try CoordinatorAddress(
        host: String(repeating: "a", count: 40) + ".example.ts.net")
    ).description == "Coordinator")
}

@Test func savedProfilesValidateAgainWhenDecoded() throws {
  var profiles = [
    CoordinatorProfile(
      name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  ]
  _ = try CoordinatorProfile.admit(CoordinatorID(UUID()), for: profiles[0].id, in: &profiles)
  let data = try JSONEncoder().encode(profiles)
  #expect(try JSONDecoder().decode([CoordinatorProfile].self, from: data) == profiles)
  let text = String(decoding: data, as: UTF8.self)
  for tampered in [
    text.replacingOccurrences(of: "100.64.1.2", with: "192.168.1.2"),
    text.replacingOccurrences(of: "\"Work\"", with: "\"My Work\""),
  ] {
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode([CoordinatorProfile].self, from: Data(tampered.utf8))
    }
  }
}
