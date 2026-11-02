import CryptoKit
import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

private actor NativeConnectionTrace {
  private var states: [String] = []
  func record(_ state: String) {
    states.append(state)
    if states.count > 12 { states.removeFirst() }
  }
  var description: String { states.joined(separator: ", ") }
}

// The runtime integration runner starts the production coordinator before
// selecting this test. Ordinary Swift unit runs have no server to connect to.
@Test(
  .enabled(if: ProcessInfo.processInfo.environment["AGENT_E2E_SOCKET"] != nil),
  .timeLimit(.minutes(1)))
@MainActor
func nativeClientReconcilesAgainstTheProductionCoordinator() async throws {
  let environment = ProcessInfo.processInfo.environment
  let socket = try #require(environment["AGENT_E2E_SOCKET"])
  let directory = URL(filePath: try #require(environment["AGENT_E2E_DIRECTORY"]))
  let inputID = try #require(environment["AGENT_E2E_INPUT"])
  let entryID = try #require(environment["AGENT_E2E_ENTRY"])
  let text = try #require(environment["AGENT_E2E_TEXT"])
  let restart = URL(filePath: try #require(environment["AGENT_E2E_RESTART_REQUEST"]))
  let reconnecting = URL(filePath: try #require(environment["AGENT_E2E_RECONNECTING"]))
  let draft = "Keep this unsent composer draft across the service restart."
  // The coordinator persists its ID in the state directory beside its socket.
  let pin = try #require(
    CoordinatorID(
      wire: String(
        contentsOf: URL(filePath: socket).deletingLastPathComponent().appending(
          path: "coordinator-id"), encoding: .utf8)))
  let profile = ProfileDirectory(
    ProfileID(), applicationSupport: directory.appending(path: "native"),
    caches: directory.appending(path: "native"))
  let outbox = profile.outbox
  let input = NativeRequestSubmit(inputId: inputID, mode: .steer, text: text)
  try saveOutbox([input], in: profile)
  let trace = NativeConnectionTrace()
  let session = CoordinatorSession(
    directory: profile, address: try CoordinatorAddress(host: "100.64.1.2"), pin: pin,
    stamps: StampSource(),
    transport: CoordinatorTransport { _ in
      let connection = NWConnection(to: .unix(path: socket), using: .tcp)
      connection.stateUpdateHandler = { state in
        let text = String(describing: state)
        Task { await trace.record(text) }
      }
      return LineConnection(connection: connection)
    })
  let model = ChatModel()
  func verifySavedInput(_ rows: [ChatRow]) throws {
    #expect(rows.filter { $0.text == text }.map(\.entryID) == [entryID])
    #expect(rows.filter { $0.role == .user }.count == 1)
    #expect(rows.allSatisfy { $0.delivery == nil })
    #expect(try queuedRequests(outbox).isEmpty)
  }
  func waitFor(_ description: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !predicate() {
      if ContinuousClock.now >= deadline {
        let states = await trace.description
        try #require(
          ContinuousClock.now < deadline,
          "Native client did not reach \(description): \(model.connection.label), \(model.error ?? "no error"); transport: \(states)"
        )
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  do {
    for _ in 0..<2 {
      await session.connect()
      var connected = false
      for await snapshot in session.updates {
        if snapshot.rows.contains(where: { $0.entryID == entryID }) {
          #expect(snapshot.rows.filter { $0.text == text }.count == 1)
        }
        if snapshot.connection == .connected {
          try verifySavedInput(snapshot.rows)
          connected = true
          break
        }
      }
      #expect(connected)
      await session.disconnect()
    }
    model.attach(Lane(id: profile.profile, session: session, hold: LegacyHold(profile)))
    await model.setActive(true)
    try await waitFor("connected before service restart") { model.connection == .connected }
    try verifySavedInput(model.rows.map(\.row))
    model.draft = draft
    try Data().write(to: restart, options: .atomic)
    try await waitFor("automatic reconnect while the service is stopped") {
      model.connection == .reconnecting
    }
    #expect(model.draft == draft)
    try verifySavedInput(model.rows.map(\.row))
    try Data().write(to: reconnecting, options: .atomic)
    try await waitFor("connected after service restart") { model.connection == .connected }
    try verifySavedInput(model.rows.map(\.row))
    #expect(model.draft == draft)
    #expect(model.error == nil)
    await model.detach(profile.profile)
  } catch {
    await model.detach(profile.profile)
    await session.disconnect()
    throw error
  }
}

// The two-coordinator runner starts Work and Personal behind recording proxies, serves the
// work lane's re-point requests, and checks what each coordinator received once this exits.
@Test(
  .enabled(if: ProcessInfo.processInfo.environment["AGENT_E2E_WORK_SOCKET"] != nil),
  .timeLimit(.minutes(2)))
@MainActor
func twoCoordinatorFeedRoutesOnlyToAddressedCoordinators() async throws {
  let environment = ProcessInfo.processInfo.environment
  func required(_ name: String) throws -> String {
    try #require(environment[name], "\(name) is set")
  }
  let directory = URL(filePath: try required("AGENT_E2E_DIRECTORY"))
  let support = directory.appending(path: "Application Support")
  let caches = directory.appending(path: "Caches")
  let legacyInput = try required("AGENT_E2E_LEGACY_INPUT")
  let legacyText = try required("AGENT_E2E_LEGACY_TEXT")
  let tagged = try required("AGENT_E2E_TAGGED_TEXT")
  let broadcast = try required("AGENT_E2E_BROADCAST_TEXT")
  let afterRepoint = "Invented note written after the re-point."
  let workPin = try #require(CoordinatorID(wire: required("AGENT_E2E_WORK_ID")))
  let personalPin = try #require(CoordinatorID(wire: required("AGENT_E2E_PERSONAL_ID")))
  let repointRequest = URL(filePath: try required("AGENT_E2E_REPOINT_REQUEST"))
  let repointAck = URL(filePath: try required("AGENT_E2E_REPOINT_ACK"))
  let workAddress = try CoordinatorAddress(host: "100.64.10.1")
  let personalAddress = try CoordinatorAddress(host: "100.64.20.1")
  let sockets = [
    workAddress.host: try required("AGENT_E2E_WORK_SOCKET"),
    personalAddress.host: try required("AGENT_E2E_PERSONAL_SOCKET"),
  ]

  // The single-address build kept its address in defaults and its queue under sha256("host:port").
  let suite = "two-coordinator-e2e-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(workAddress.host, forKey: "coordinatorAddress")
  let key = SHA256.hash(data: Data("\(workAddress.host):\(workAddress.port)".utf8)).map {
    String(format: "%02x", $0)
  }.joined()
  let legacyQueue = support.appending(path: "Agent/Outbox/\(key)")
  try FileManager.default.createDirectory(at: legacyQueue, withIntermediateDirectories: true)
  try JSONEncoder().encode([
    NativeRequestSubmit(inputId: legacyInput, mode: .steer, text: legacyText)
  ])
  .write(to: legacyQueue.appending(path: "pending.json"))

  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: support, caches: caches,
    transport: CoordinatorTransport { address in
      guard let socket = sockets[address.host] else { throw ConnectionError.invalidAddress }
      return LineConnection(connection: NWConnection(to: .unix(path: socket), using: .tcp))
    })
  let chat = coordinators.chat
  func lanes() -> String {
    coordinators.profiles.map {
      "\($0.name): \(chat.snapshots[$0.id]?.connection.label ?? "no session"), \(chat.snapshots[$0.id]?.error ?? "no error")"
    }.joined(separator: "; ")
  }
  func eventually(_ description: String, _ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !predicate() {
      try #require(
        ContinuousClock.now < deadline, "Timed out waiting for \(description). \(lanes())")
      try await Task.sleep(for: .milliseconds(10))
    }
  }
  /// Writes to the composer one character at a time, as the text field does.
  func type(_ text: String) {
    for character in text {
      chat.draft.append(character)
      chat.promoteTypedTag()
    }
  }
  func bubbles(_ text: String) -> [RowModel] {
    chat.rows.filter { $0.row.role == .user && $0.row.text == text }
  }
  func answered(_ receipt: Receipt) -> Bool {
    switch receipt.status {
    case .placed, .pending(.uncertain, _), .pending(.rejected, _): true
    case .pending(.sending, _), .pending(.saved, _), .notSent: false
    }
  }
  func repoint(_ name: String) async throws {
    try Data(name.utf8).write(to: repointRequest, options: .atomic)
    try await eventually("the work lane pointed at \(name)") {
      (try? String(contentsOf: repointAck, encoding: .utf8)) == name
    }
    try FileManager.default.removeItem(at: repointAck)
  }

  let migrated = try #require(coordinators.profiles.first)
  #expect(coordinators.profiles.count == 1 && migrated.pin == nil)
  try await eventually("the pre-update queue held") { chat.held.count == 1 }
  #expect(chat.held.map(\.id) == [legacyInput] && chat.held.first?.item.text == legacyText)
  await coordinators.setActive(true)
  try await eventually("the migrated profile paired and connected") {
    chat.connection == .connected
  }
  #expect(coordinators.profiles.first?.pin == workPin)
  #expect(chat.held.map(\.id) == [legacyInput], "Pairing leaves the pre-update queue held")
  let work = migrated.id
  try await coordinators.update(work, name: TagName("Work"), address: workAddress)
  try await coordinators.add(name: TagName("Personal"), address: personalAddress)
  let personal = try #require(coordinators.profiles.last?.id)
  #expect(coordinators.profiles.map(\.name.description) == ["Work", "Personal"])
  #expect(coordinators.profiles.last?.pin == personalPin)
  try await eventually("both lanes connected") {
    [work, personal].allSatisfy { chat.snapshots[$0]?.connection == .connected }
  }

  type("@Work ")
  #expect(chat.recipient == work && chat.draft.isEmpty, "A typed tag becomes the chip")
  #expect(chat.recipient.map(chat.name) == "Work", "The chip says Work")
  type(tagged)
  #expect(chat.recipientLine == "To Work")
  await chat.send()
  #expect(chat.draft.isEmpty && chat.recipient == nil, "The @Work message was admitted")
  try await eventually("Work answering the @Work submit") {
    bubbles(tagged).count == 1 && bubbles(tagged)[0].receipts.map(\.lane) == [work]
      && bubbles(tagged)[0].receipts.allSatisfy(answered)
  }

  type(broadcast)
  #expect(chat.recipient == nil)
  #expect(chat.recipientLine == "To Work and Personal")
  await chat.send()
  #expect(chat.draft.isEmpty, "The untagged message was admitted")
  try await eventually("both coordinators answering the untagged submit") {
    bubbles(broadcast).count == 1
      && bubbles(broadcast)[0].receipts.map(\.lane) == [work, personal]
      && bubbles(broadcast)[0].receipts.allSatisfy(answered)
  }
  #expect(bubbles(broadcast).first?.id.hasPrefix("send:") == true, "One folded bubble")

  func namesDifferentCoordinator() -> Bool {
    chat.snapshots[work]?.error?.hasPrefix(
      "This address now answers as a different coordinator.") == true
  }
  try await repoint("personal")
  try await eventually("Work's lane dropping its re-pointed socket") {
    chat.snapshots[work]?.connection != .connected
  }
  // A lane that skipped its pin check would reconnect instead. Going on lets the proxies
  // record what the retry and the send below would then carry.
  try await eventually("Work's lane dialing the re-pointed address") {
    namesDifferentCoordinator() || chat.snapshots[work]?.connection == .connected
  }
  let retried = try #require(
    bubbles(tagged).first?.receipts.compactMap { receipt -> String? in
      if case .pending(.uncertain, let id?) = receipt.status { id } else { nil }
    }.first, "The @Work row offers Check / retry")
  await chat.retry(retried)
  type("@Work ")
  type(afterRepoint)
  #expect(chat.recipientLine == "Work is not connected")
  await chat.send()
  #expect(chat.draft == afterRepoint && chat.recipient == work, "The new @Work message stays")
  let workOutbox = ProfileDirectory(work, applicationSupport: support, caches: caches).outbox
  #expect(try queuedRequests(workOutbox).allSatisfy { $0.text != afterRepoint })
  #expect(
    bubbles(tagged).first?.receipts
      == [Receipt(lane: work, status: .pending(.uncertain, inputID: retried))],
    "The retried row is still unconfirmed")
  #expect(namesDifferentCoordinator(), "Work's lane names a different coordinator")
  #expect(chat.snapshots[work]?.error?.contains("held on this phone") == true)
  #expect(chat.snapshots[personal]?.connection == .connected)
  try await repoint("work")
  try await eventually("Work reconnected") { chat.snapshots[work]?.connection == .connected }

  chat.recipient = nil
  chat.draft = ""
  let held = try #require(chat.held.first)
  await chat.restoreHeld(held)
  #expect(chat.recipient == work, "A held message restores to the coordinator it was held for")
  #expect(chat.recipientLine == "To Work")
  #expect(chat.draft == legacyText)
  await coordinators.setActive(false)
}
