import CryptoKit
import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

/// What the single-address build left on disk, with invented data.
private struct LegacyInstall {
  let root: URL
  let suite: String
  let defaults: UserDefaults
  let address: CoordinatorAddress
  let queued: [NativeRequestSubmit]
  let pending: Data
  let attachment: AttachmentRef
  let bytes: Data
  var support: URL { root.appending(path: "Support") }
  var caches: URL { root.appending(path: "Caches") }
  var oldOutbox: URL { Self.outbox(support, address.host, address.port) }
  var otherOutbox: URL { Self.outbox(support, "100.64.9.9", 43187) }
  var draft: URL { support.appending(path: "Agent/Drafts/Draft.txt") }

  /// The old build named each queue by the typed address, `sha256("host:port")`.
  static func outbox(_ support: URL, _ host: String, _ port: UInt16) -> URL {
    let key = SHA256.hash(data: Data("\(host):\(port)".utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return support.appending(path: "Agent/Outbox/\(key)")
  }

  init(host: String = "100.64.1.2", port: String? = nil) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let support = root.appending(path: "Support")
    let suite = "legacy-install-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(host, forKey: "coordinatorAddress")
    if let port { defaults.set(port, forKey: "coordinatorPort") }
    defaults.set(UUID().uuidString, forKey: "notificationInstallationID")
    defaults.set(false, forKey: "notificationsEnabled")
    let address = try CoordinatorAddress(host: host, port: try #require(UInt16(port ?? "43187")))
    let old = Self.outbox(support, address.host, address.port)
    let bytes = Data("Invented attachment bytes".utf8)
    let attachment = try await AttachmentStore(directory: old.appending(path: "Attachments"))
      .stage(data: bytes, name: "Notes.txt", mediaType: "text/plain").reference
    let queued = [
      NativeRequestSubmit(
        attachments: [attachment], inputId: UUID().uuidString, mode: .steer,
        text: "@Personal check the invented report"),
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: "Second held note"),
    ]
    let pending = try JSONEncoder().encode(queued)
    try pending.write(to: old.appending(path: "pending.json"))
    let files = FileManager.default
    let other = Self.outbox(support, "100.64.9.9", 43187)
    try files.createDirectory(at: other, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: other.appending(path: "pending.json"))
    let drafts = support.appending(path: "Agent/Drafts")
    try files.createDirectory(at: drafts, withIntermediateDirectories: true)
    try Data("draft".utf8).write(to: drafts.appending(path: "Draft.txt"))
    let previews = root.appending(path: "Caches/Agent/Previews/\(old.lastPathComponent)")
    try files.createDirectory(at: previews, withIntermediateDirectories: true)
    try Data("preview".utf8).write(to: previews.appending(path: "Preview.png"))
    self.root = root
    self.suite = suite
    self.defaults = defaults
    self.address = address
    self.queued = queued
    self.pending = pending
    self.attachment = attachment
    self.bytes = bytes
  }

  func remove() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }

  func directory(_ profile: CoordinatorProfile) -> ProfileDirectory {
    ProfileDirectory(profile.id, applicationSupport: support, caches: caches)
  }

  func savedProfiles() throws -> Data {
    try Data(contentsOf: support.appending(path: "Agent/profiles.json"))
  }

  /// The end state migration.md promises, whatever run got it there.
  func expectMigrated(_ profiles: [CoordinatorProfile]) throws {
    let files = FileManager.default
    #expect(profiles.count == 1)
    let profile = try #require(profiles.first)
    #expect(profile.pin == nil)
    #expect(profile.address == address)
    let legacy = directory(profile).legacy
    #expect(try Data(contentsOf: legacy.appending(path: "pending.json")) == pending)
    #expect(
      try Data(contentsOf: legacy.appending(path: "Attachments/\(attachment.id)/Notes.txt"))
        == bytes)
    #expect(!files.fileExists(atPath: directory(profile).outbox.deletingLastPathComponent().path))
    #expect(!files.fileExists(atPath: oldOutbox.path))
    #expect(try Data(contentsOf: otherOutbox.appending(path: "pending.json")) == Data("[]".utf8))
    #expect(files.fileExists(atPath: draft.path), "The global composer store is kept")
    #expect(!files.fileExists(atPath: caches.appending(path: "Agent/Previews").path))
    #expect(defaults.object(forKey: "coordinatorAddress") == nil)
    #expect(defaults.object(forKey: "coordinatorPort") == nil)
    #expect(defaults.object(forKey: "notificationInstallationID") == nil)
    #expect(defaults.object(forKey: "notificationsEnabled") as? Bool == false)
    struct Saved: Decodable { let profiles: [CoordinatorProfile] }
    #expect(try JSONDecoder().decode(Saved.self, from: savedProfiles()).profiles == profiles)
  }
}

private struct Crash: Error {}

@MainActor private func eventually(
  _ description: String, _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor @Test
func migrationQuarantinesTheLastQueueIntoAnUnpairedProfileShownAtOnce() async throws {
  let install = try await LegacyInstall(host: "studio.example-tailnet.ts.net")
  defer { install.remove() }
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: .tailnet)
  try install.expectMigrated(coordinators.profiles)
  #expect(coordinators.profiles.first?.name.description == "studio")
  #expect(coordinators.chat.lanes.map(\.session).allSatisfy { $0 == nil }, "Unpaired: no session")
  try await eventually("held rows before pairing") { coordinators.chat.held.count == 2 }
  #expect(coordinators.chat.held.map(\.item.text) == install.queued.map(\.text))
}

@MainActor
@Test(
  arguments: [
    Coordinators.MigrationStep.profileSaved, .quarantined, .markerRemoved,
  ])
func migrationResumesAfterACrashAtEveryStepWithACustomPort(_ step: Coordinators.MigrationStep)
  async throws
{
  let install = try await LegacyInstall(port: "4123")
  defer { install.remove() }
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
      crash: { if $0 == step { throw Crash() } })
  }
  let profiles =
    (try? FileManager.default.contentsOfDirectory(
      at: install.support.appending(path: "Agent/Profiles"), includingPropertiesForKeys: nil)) ?? []
  for profile in profiles {
    #expect(!FileManager.default.fileExists(atPath: profile.appending(path: "Outbox").path))
  }
  let resumed = try Coordinators.migrate(
    defaults: install.defaults, applicationSupport: install.support, caches: install.caches
  ).profiles
  try install.expectMigrated(resumed)
  #expect(resumed.first?.address.port == 4123)
}

@MainActor @Test func legacyHoldRestoresACopyAndDiscardsOnlyTheChosenItem() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let profile = try #require(
    try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches
    ).profiles.first)
  let hold = LegacyHold(install.directory(profile))
  #expect(try await hold.items().map(\.id) == install.queued.map(\.inputId))
  let drafts = AttachmentStore(directory: install.support.appending(path: "Agent/Drafts"))
  let first = install.queued[0]
  let restored = try #require(try await hold.restore(first.inputId, to: drafts))
  #expect(restored.text == first.text && restored.mode == first.mode)
  let copy = try #require(restored.attachments.first)
  #expect(copy.id != install.attachment.id)
  #expect(try Data(contentsOf: copy.url) == install.bytes)
  #expect(try await hold.items().count == 2, "Restore copies; the held item stays")
  try await hold.discard(first.inputId)
  #expect(try await hold.items().map(\.id) == [install.queued[1].inputId])
  let held = install.directory(profile).legacy.appending(
    path: "Attachments/\(install.attachment.id)")
  #expect(!FileManager.default.fileExists(atPath: held.path))
  #expect(try Data(contentsOf: copy.url) == install.bytes, "The draft copy has its own lifetime")
}

@Test func anUnreadableHoldSurfacesAnErrorAndStaysOnDisk() async throws {
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let file = directory.legacy.appending(path: "pending.json")
  try FileManager.default.createDirectory(
    at: directory.legacy, withIntermediateDirectories: true)
  let garbage = Data("not a queue".utf8)
  try garbage.write(to: file)
  let hold = LegacyHold(directory)
  await #expect(throws: (any Error).self) { try await hold.items() }
  await #expect(throws: (any Error).self) { try await hold.discard("any") }
  #expect(try Data(contentsOf: file) == garbage)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func theMigratedProfilePairsAndHeldMessagesLeaveOnlyByADeliberateSend() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {}, save: { _ in })
  let coordinators = Coordinators(
    registration: registration, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: loopback(port))
  let chat = coordinators.chat
  let profile = try #require(coordinators.profiles.first)
  try await eventually("held rows before pairing") { chat.held.count == 2 }
  await coordinators.setActive(true)
  try await eventually("paired and connected") { chat.connection == .connected }
  #expect(coordinators.profiles.first?.pin == fixture.id)
  struct Saved: Decodable { let profiles: [CoordinatorProfile] }
  #expect(
    try JSONDecoder().decode(Saved.self, from: install.savedProfiles()).profiles.first?.pin
      == fixture.id)
  #expect(await fixture.received().contains(.observe(.init(inputIds: []))))
  try await eventually("this lane's own notification channel") {
    await fixture.notificationControls() == [.status(.init(installationId: "\(profile.id)"))]
  }
  let first = try #require(chat.held.first)
  await chat.restoreHeld(first)
  #expect(chat.draft == first.item.text, "Restore puts the text in verbatim")
  #expect(chat.attachments.map(\.reference.name) == ["Notes.txt"])
  chat.draft = ""
  for file in chat.attachments { await chat.removeAttachment(file) }
  #expect(chat.held.count == 2, "Clearing the restored draft keeps the held item")
  await chat.restoreHeld(first)
  #expect(await fixture.count() == 0, "Restore sends nothing")
  await chat.send()
  try await eventually("the held source removed after admission") {
    chat.held.map(\.id) == [install.queued[1].inputId]
  }
  try await eventually("the deliberate send reaching the coordinator") {
    await fixture.count() == 1
  }
  let submitted = await fixture.received().compactMap {
    if case .submit(let input) = $0 { input } else { nil }
  }
  #expect(submitted.map(\.text) == [first.item.text])
  #expect(submitted.first?.inputId != first.id, "A restored message is a new input")
  let wire = String(decoding: try JSONEncoder().encode(await fixture.received()), as: UTF8.self)
  for held in install.queued { #expect(!wire.contains(held.inputId)) }
  #expect(!wire.contains(install.queued[1].text))
  await coordinators.setActive(false)
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anOldCoordinatorLeavesTheProfileUnpairedUntilItAnswers() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  await fixture.dropIdentify()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: loopback(port))
  let id = try #require(coordinators.profiles.first?.id)
  await coordinators.setActive(true)
  try await eventually("a pairing error") { coordinators.pairingError[id] != nil }
  #expect(coordinators.pairingError[id] == "Update the coordinator to use it with this app.")
  #expect(coordinators.profiles.first?.pin == nil)
  try install.expectMigrated(coordinators.profiles)
  #expect(await fixture.received().allSatisfy { $0 == .identify })
  await fixture.dropIdentify(false)
  coordinators.retryPairing(id)
  try await eventually("paired after Try again") { coordinators.chat.connection == .connected }
  #expect(coordinators.pairingError[id] == nil)
  #expect(coordinators.profiles.first?.pin == fixture.id)
  await coordinators.setActive(false)
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anAddressEditIsProbedAgainstThePinBeforeAnythingIsSaved() async throws {
  let right = FixtureCoordinator()
  let wrong = FixtureCoordinator()
  let (rightListener, rightPort) = try await listen(right)
  defer { rightListener.cancel() }
  let (wrongListener, wrongPort) = try await listen(wrong)
  defer { wrongListener.cancel() }
  // The typed port picks which fixture answers, standing in for two addresses.
  let routes: [UInt16: NWEndpoint.Port] = [4001: rightPort, 4002: wrongPort, 4003: rightPort]
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "edit-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
    })
  await coordinators.setActive(true)
  let work = try TagName("Work")
  try await coordinators.add(
    name: work, address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
  try await eventually("connected") { coordinators.chat.connection == .connected }
  let id = try #require(coordinators.profiles.first?.id)
  await #expect(throws: ProfileError.duplicateCoordinator(savedAs: "Work")) {
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
  }
  let saved = try Data(contentsOf: root.appending(path: "Agent/profiles.json"))
  await #expect(throws: ProfileError.differentCoordinator) {
    try await coordinators.update(
      id, name: work, address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  }
  #expect(try Data(contentsOf: root.appending(path: "Agent/profiles.json")) == saved)
  #expect(coordinators.profiles.first?.address.port == 4001)
  #expect(await wrong.received() == [.identify])
  try await coordinators.update(
    id, name: TagName("Studio"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
  #expect(coordinators.profiles.first?.address.port == 4003)
  #expect(coordinators.profiles.first?.name.description == "Studio")
  try await eventually("reconnected at the new address") {
    coordinators.chat.connection == .connected
  }
  #expect(await wrong.received() == [.identify], "The refused address saw only the probe")
  await coordinators.setActive(false)
  await right.stop()
  await wrong.stop()
}

/// The user edits Work's address and mistypes it, so it reaches Personal's coordinator or one this
/// phone never saved. The edit saves nothing, and Work keeps its address, its connection and its
/// queued message. The form names the coordinator saved at that address, as Add does, or says the
/// address answers as a different coordinator and nothing was saved. It never tells the user to
/// remove Work, which would delete the queue.
@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: ["Personal's address", "an unsaved coordinator's address"])
func aRefusedAddressEditKeepsTheQueueAndNeverSendsTheUserToRemove(_ typo: String) async throws {
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let stranger = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let (strangerListener, strangerPort) = try await listen(stranger)
  defer { strangerListener.cancel() }
  let routes: [UInt16: NWEndpoint.Port] = [4001: workPort, 4002: personalPort, 4005: strangerPort]
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "edit-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
    })
  func stop() async {
    await coordinators.setActive(false)
    for fixture in [work, personal, stranger] { await fixture.stop() }
  }
  do {
    await coordinators.setActive(true)
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    let chat = coordinators.chat
    let id = coordinators.profiles[0].id
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    // Work is busy with a turn, so a follow-up it accepts stays queued on this phone.
    await work.holdPlacements()
    chat.draft = "@Work Invented follow-up for the Work board"
    chat.promoteTypedTag()
    await chat.send()
    let outbox = ProfileDirectory(id, applicationSupport: root, caches: root).outbox
    try await eventually("Work accepted the follow-up") {
      await work.count() == 1 && (try? queuedRequests(outbox).count) == 1
    }
    let saved = try Data(contentsOf: root.appending(path: "Agent/profiles.json"))
    let typed = try CoordinatorAddress(
      host: "100.64.1.2", port: typo == "Personal's address" ? 4002 : 4005)
    var shown = "nothing"
    do { try await coordinators.update(id, name: TagName("Work"), address: typed) } catch {
      shown = error.localizedDescription
    }
    var addShown = "nothing"
    if typo == "Personal's address" {
      do { try await coordinators.add(name: TagName("Spare"), address: typed) } catch {
        addShown = error.localizedDescription
      }
    }
    let port = coordinators.profiles.first { $0.id == id }?.address.port
    let queued = (try? queuedRequests(outbox).map(\.text)) ?? []
    let strangerHeard = await stranger.received().filter { $0 != .identify }.count
    print(
      "IF12-2[\(typo)] the form shows \"\(shown)\" Add shows \"\(addShown)\" Work's saved port=\(port ?? 0) connected=\(chat.snapshots[id]?.connection == .connected) Work's queue=\(queued)"
    )
    if typo == "Personal's address" {
      #expect(shown == "Already saved as Personal.")
      #expect(addShown == shown, "The edit says what Add says for the same address")
    } else {
      #expect(shown == "This address answers as a different coordinator. Nothing was saved.")
    }
    #expect(!shown.contains("Remove"), "The form sends the user to Remove, which deletes the queue")
    #expect(try Data(contentsOf: root.appending(path: "Agent/profiles.json")) == saved)
    #expect(port == 4001)
    #expect(chat.snapshots[id]?.connection == .connected)
    #expect(queued == ["Invented follow-up for the Work board"])
    #expect(strangerHeard == 0, "The refused address saw only the probe")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Which fixture each saved port reaches. A test changes it as coordinators move.
private actor Routes {
  private var table: [UInt16: NWEndpoint.Port]
  init(_ table: [UInt16: NWEndpoint.Port]) { self.table = table }
  func set(_ next: [UInt16: NWEndpoint.Port]) { table = next }
  func port(_ saved: UInt16) -> NWEndpoint.Port? { table[saved] }
}

/// Work and Personal run on one machine at ports 4001 and 4002, and Work refused a follow-up that
/// this phone still holds. Then the two coordinators trade ports, so each lane reaches the other
/// saved coordinator. Each line names that coordinator and points to editing its own address. It
/// never points to Remove, which deletes Work's follow-up, and re-adding Work there would bind the
/// name to Personal's coordinator. Following Work's line keeps the follow-up, and following both
/// keeps `@Work` going to Work's coordinator. An address that answers as a coordinator no profile
/// is pinned to, as after a reinstall, keeps the reinstall line with Remove's count.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["Work's line", "both lines", "a reinstall"])
func aLaneWhoseAddressAnswersAsAnotherSavedCoordinatorNamesItAndNeverSendsTheUserToRemove(
  _ followed: String
) async throws {
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let stranger = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let (strangerListener, strangerPort) = try await listen(stranger)
  defer { strangerListener.cancel() }
  let routes = Routes([4001: workPort, 4002: personalPort])
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "swap-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else {
        throw ConnectionError.invalidAddress
      }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  func stop() async {
    await coordinators.setActive(false)
    for fixture in [work, personal, stranger] { await fixture.stop() }
  }
  do {
    await coordinators.setActive(true)
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    let chat = coordinators.chat
    let workID = coordinators.profiles[0].id
    let personalID = coordinators.profiles[1].id
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    await work.rejectSubmits()
    chat.draft = "@Work Invented follow-up: renew the parking permit"
    chat.promoteTypedTag()
    await chat.send()
    let outbox = ProfileDirectory(workID, applicationSupport: root, caches: root).outbox
    try await eventually("Work refused the follow-up") {
      chat.snapshots[workID]?.rows.contains { $0.delivery == .rejected } == true
    }
    await work.rejectSubmits(false)
    await routes.set(
      followed == "a reinstall"
        ? [4001: strangerPort, 4002: personalPort] : [4001: personalPort, 4002: workPort])
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("Work's line names who answers") {
      chat.laneError(workID)?.hasPrefix("This address now answers as") == true
    }
    let workLine = chat.laneError(workID) ?? "nil"
    print("IF13-X1[\(followed)] Work's line: \(workLine)")
    if followed == "a reinstall" {
      #expect(
        workLine
          == "This address now answers as a different coordinator. 1 queued message is held on this phone. Remove it and add it again."
      )
      try await eventually("Personal connected beside it") {
        chat.snapshots[personalID]?.connection == .connected
      }
    } else {
      try await eventually("Personal's line names who answers") {
        chat.laneError(personalID)?.hasPrefix("This address now answers as") == true
      }
      let personalLine = chat.laneError(personalID) ?? "nil"
      print("IF13-X1[\(followed)] Personal's line: \(personalLine)")
      #expect(workLine == "This address now answers as Personal. Edit Work's address.")
      #expect(personalLine == "This address now answers as Work. Edit Personal's address.")
      #expect(
        !workLine.contains("Remove") && !personalLine.contains("Remove"),
        "A line sends the user to Remove, which deletes the queue")
      try await coordinators.update(
        workID, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
      try await eventually("Work reconnected where its coordinator answers") {
        chat.snapshots[workID]?.connection == .connected
      }
      let queued = (try? queuedRequests(outbox).map(\.text)) ?? []
      print(
        "IF13-X1[\(followed)] after editing Work's address: Work's line=\(chat.laneError(workID) ?? "nil") Work's queue=\(queued)"
      )
      #expect(queued == ["Invented follow-up: renew the parking permit"])
      #expect(chat.laneError(workID) == nil)
      if followed == "both lines" {
        try await coordinators.update(
          personalID, name: TagName("Personal"),
          address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
        try await eventually("Personal reconnected where its coordinator answers") {
          chat.snapshots[personalID]?.connection == .connected
        }
        let before = (await work.count(), await personal.count())
        chat.draft = "@Work Invented note: the quarterly board pack"
        chat.promoteTypedTag()
        let line = chat.recipientLine
        await chat.send()
        try await eventually("Work's coordinator got the note") { await work.count() > before.0 }
        try await Task.sleep(for: .milliseconds(300))
        let gotByWork = await work.count() - before.0
        let gotByPersonal = await personal.count() - before.1
        print(
          "IF13-X1[\(followed)] after editing both: line=\(line) Work's coordinator got=\(gotByWork) Personal's coordinator got=\(gotByPersonal)"
        )
        #expect(line == "To Work")
        #expect(gotByWork == 1)
        #expect(gotByPersonal == 0, "The @Work note reached Personal's coordinator")
      }
    }
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Holds the first dial until `open`, standing in for a slow address probe.
private actor ProbeGate {
  private(set) var waiting = false
  private var opened = false
  private var release: CheckedContinuation<Void, Never>?
  func pass() async {
    guard !opened else { return }
    waiting = true
    await withCheckedContinuation { release = $0 }
  }
  func open() {
    opened = true
    release?.resume()
    release = nil
  }
}

/// Two edits to one name run in turn. The first saves, and the second finds the name taken, so
/// no two coordinators are ever saved under one name.
@MainActor @Test(.timeLimit(.minutes(1)))
func twoEditsToOneNameRunInTurnAndOnlyTheFirstSaves() async throws {
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let routes: [UInt16: NWEndpoint.Port] = [4001: workPort, 4002: personalPort, 4003: workPort]
  let gate = ProbeGate()
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "edit-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      if address.port == 4003 { await gate.pass() }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
    })
  try await coordinators.add(
    name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
  try await coordinators.add(
    name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  let (workID, personalID) = (coordinators.profiles[0].id, coordinators.profiles[1].id)
  let edit = Task {
    try await coordinators.update(
      workID, name: TagName("Shared"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
  }
  try await eventually("Work's probe held") { await gate.waiting }
  let second = Task {
    try await coordinators.update(
      personalID, name: TagName("Shared"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  }
  await gate.open()
  try await edit.value
  await #expect(throws: ProfileError.duplicateName("Shared")) { try await second.value }
  struct Saved: Decodable { let profiles: [CoordinatorProfile] }
  let saved = try JSONDecoder().decode(
    Saved.self, from: Data(contentsOf: root.appending(path: "Agent/profiles.json")))
  #expect(saved.profiles.map(\.name.description) == ["Shared", "Personal"])
  #expect(coordinators.profiles.map(\.address.port) == [4003, 4002])
  await work.stop()
  await personal.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removeCountsQueuedAndHeldMessagesAndDeletesOnlyAfterSaving() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  await fixture.refuseUploads()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {}, save: { _ in })
  let coordinators = Coordinators(
    registration: registration, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: loopback(port))
  let chat = coordinators.chat
  let profile = try #require(coordinators.profiles.first)
  await coordinators.setActive(true)
  try await eventually("paired and connected") { chat.connection == .connected }
  chat.draft = "Kept on this phone"
  await chat.attach(data: Data("bytes".utf8), name: "Notes.txt", mediaType: "text/plain")
  await chat.send()
  try await eventually("a rejected live item") {
    chat.rows.contains { $0.row.delivery == .rejected }
  }
  #expect(
    coordinators.removalMessage(profile.id)
      == "This deletes 3 queued messages on this phone.")
  let agent = install.support.appending(path: "Agent")
  let directory = install.directory(profile)
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
  await #expect(throws: (any Error).self) { try await coordinators.remove(profile.id) }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
  #expect(
    FileManager.default.fileExists(atPath: directory.root.path), "Unsaved removal deletes nothing")
  #expect(coordinators.profiles.map(\.id) == [profile.id])
  try await coordinators.remove(profile.id)
  #expect(coordinators.profiles.isEmpty)
  struct Saved: Decodable { let profiles: [CoordinatorProfile] }
  #expect(try JSONDecoder().decode(Saved.self, from: install.savedProfiles()).profiles.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: directory.root.path))
  #expect(!FileManager.default.fileExists(atPath: directory.cache.path))
  #expect(
    await fixture.notificationControls().contains(
      .unregister(.init(installationId: "\(profile.id)"))), "Alerts are withdrawn")
  await coordinators.setActive(false)
  await fixture.stop()
}

/// A Remove that stopped after saving leaves its files. The next launch deletes every profile
/// directory `profiles.json` does not list, and keeps the ones it lists.
@MainActor @Test func launchDeletesTheFilesOfEveryProfileThatIsNoLongerSaved() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let caches = root.appending(path: "Caches")
  let suite = "launch-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let saved = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  struct Saved: Encodable { let profiles: [CoordinatorProfile] }
  try writePrivately(
    JSONEncoder().encode(Saved(profiles: [saved])),
    to: root.appending(path: "Agent/profiles.json"))
  let kept = ProfileDirectory(saved.id, applicationSupport: root, caches: caches)
  let removed = ProfileDirectory(ProfileID(), applicationSupport: root, caches: caches)
  for directory in [kept, removed] {
    try writePrivately(Data("{}".utf8), to: directory.ledger)
    try writePrivately(Data("preview".utf8), to: directory.previews.appending(path: "A.png"))
  }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: caches,
    transport: .tailnet)
  #expect(coordinators.profiles.map(\.id) == [saved.id])
  #expect(FileManager.default.fileExists(atPath: kept.ledger.path))
  #expect(FileManager.default.fileExists(atPath: kept.previews.path))
  #expect(!FileManager.default.fileExists(atPath: removed.root.path))
  #expect(!FileManager.default.fileExists(atPath: removed.cache.path))
}

/// Where the migrated address leads. Once Work is reinstalled it answers as another coordinator.
private actor Reinstall {
  private(set) var done = false
  func now() { done = true }
}

/// The single-address build left one queued message for Work, so it is held, and Work pairs. With
/// `queued`, Work also refuses a new message, which stays in its outbox. Work is then reinstalled,
/// so its address answers as another coordinator. The lane's banner counts what Remove deletes on
/// this phone, as Remove's confirmation does: queued plus held.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func aReinstalledCoordinatorsBannerCountsWhatRemoveDeletes(queued: Bool) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let support = root.appending(path: "Support")
  let suite = "reinstalled-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  defaults.set("4001", forKey: "coordinatorPort")
  let old = LegacyInstall.outbox(support, "100.64.1.2", 4001)
  try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
  try JSONEncoder().encode([
    NativeRequestSubmit(
      inputId: UUID().uuidString, mode: .steer, text: "Invented: book the van for Saturday")
  ]).write(to: old.appending(path: "pending.json"))
  let original = FixtureCoordinator()
  let reinstalled = FixtureCoordinator()
  let (originalListener, originalPort) = try await listen(original)
  defer { originalListener.cancel() }
  let (reinstalledListener, reinstalledPort) = try await listen(reinstalled)
  defer { reinstalledListener.cancel() }
  let reinstall = Reinstall()
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: support,
    caches: root.appending(path: "Caches"),
    transport: CoordinatorTransport { _ in
      let port = await reinstall.done ? reinstalledPort : originalPort
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let chat = coordinators.chat
  let work = try #require(coordinators.profiles.first?.id)
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await original.stop()
    await reinstalled.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Work paired and connected") {
      chat.snapshots[work]?.connection == .connected
    }
    try await eventually("the held message shows") { !chat.held.isEmpty }
    if queued {
      await original.rejectSubmits()
      chat.draft = "Invented: and the trailer"
      await chat.send()
      try await eventually("Work refused it") {
        chat.snapshots[work]?.rows.contains { $0.delivery == .rejected } == true
      }
    }
    await reinstall.now()
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    try await eventually("the identity failure") {
      chat.snapshots[work]?.error?.contains("different coordinator") == true
    }
    let banner = chat.snapshots[work]?.error ?? "nil"
    let confirmation = coordinators.removalMessage(work)
    print("IF8-W5[queued=\(queued)] held=\(chat.held.count) banner=\(banner)")
    print("IF8-W5[queued=\(queued)] Remove's confirmation: \(confirmation)")
    let count = queued ? "2 queued messages are" : "1 queued message is"
    #expect(banner.contains("\(count) held"), "The banner and Remove disagree")
    #expect(
      banner
        == "This address now answers as a different coordinator. \(count) held on this phone. Remove it and add it again."
    )
    #expect(
      confirmation
        == (queued
          ? "This deletes 2 queued messages on this phone."
          : "This deletes 1 queued message on this phone."))
  } catch {
    await stop()
    throw error
  }
  await stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removeNeverCallsAnUnreadableQueueEmpty() async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "remove-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  try await coordinators.add(name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2"))
  let id = try #require(coordinators.profiles.first?.id)
  let directory = ProfileDirectory(id, applicationSupport: root, caches: root)
  let unreadable = "Queued messages on this phone could not be read. Removing deletes them."
  #expect(coordinators.removalMessage(id) == "No queued messages are on this phone.")
  try writePrivately(Data("not an outbox".utf8), to: directory.outbox)
  let outbox = coordinators.removalMessage(id)
  #expect(outbox == unreadable, "An unreadable outbox")
  try FileManager.default.removeItem(at: directory.outbox)
  let held = directory.legacy.appending(path: "pending.json")
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Invented held note")
    ]), to: held)
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: held.path)
  let hold = coordinators.removalMessage(id)
  #expect(hold == unreadable, "An unreadable hold")
  try await coordinators.remove(id)
  #expect(!FileManager.default.fileExists(atPath: directory.root.path))
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func restoreCopiesARejectedItemAndRemovesItOnlyOnceTheCopyIsAdmitted() async throws {
  let fixture = FixtureCoordinator()
  await fixture.refuseUploads()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = CoordinatorSession(
    directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"), pin: fixture.id,
    stamps: StampSource(), transport: loopback(port))
  let chat = ChatModel(draftStore: AttachmentStore(directory: root.appending(path: "Drafts")))
  chat.attach(Lane(id: directory.profile, session: session, hold: LegacyHold(directory)))
  await chat.setActive(true)
  try await eventually("connected") { chat.connection == .connected }
  chat.draft = "Needs a second try"
  await chat.attach(data: Data("bytes".utf8), name: "Notes.txt", mediaType: "text/plain")
  await chat.send()
  try await eventually("rejected") { chat.rows.contains { $0.row.delivery == .rejected } }
  let original = try #require(try queuedRequests(directory.outbox).first)
  await chat.restore(original.inputId)
  #expect(chat.draft == "Needs a second try")
  #expect(try queuedRequests(directory.outbox) == [original], "Restore copies")
  chat.draft = ""
  for file in chat.attachments { await chat.removeAttachment(file) }
  #expect(
    try queuedRequests(directory.outbox) == [original], "Clearing the draft keeps the source")
  await chat.restore(original.inputId)
  await chat.send()
  let after = try queuedRequests(directory.outbox)
  #expect(after.count == 1 && after.first?.inputId != original.inputId)
  await chat.detach(directory.profile)
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageStartingWithAnotherNameRestoresToItsOwnCoordinatorAsTyped() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let migrated = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (migratedListener, migratedPort) = try await listen(migrated)
  defer { migratedListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let routes: [UInt16: NWEndpoint.Port] = [install.address.port: migratedPort, 4002: personalPort]
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches,
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: routes[address.port]!, using: .tcp))
    })
  let chat = coordinators.chat
  let profile = try #require(coordinators.profiles.first)
  await coordinators.setActive(true)
  try await eventually("the migrated profile paired") { chat.connection == .connected }
  try await coordinators.add(
    name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  try await eventually("both connected") {
    chat.snapshots.values.filter { $0.connection == .connected }.count == 2
  }
  let held = try #require(chat.held.first { $0.item.text.hasPrefix("@Personal") })
  await chat.restoreHeld(held)
  #expect(chat.recipient == profile.id, "Restore addresses the profile the queue was held for")
  #expect(chat.draft == held.item.text)
  #expect(chat.recipientLine == "To \(profile.name.description)")
  await chat.send()
  try await eventually("the restored message at its own coordinator") {
    await migrated.count() == 1
  }
  let submitted = await migrated.received().compactMap {
    if case .submit(let input) = $0 { input } else { nil }
  }
  #expect(submitted.map(\.text) == [held.item.text])
  #expect(await personal.count() == 0)
  try await eventually("the held source removed after admission") {
    !chat.held.contains { $0.id == held.id }
  }
  await coordinators.setActive(false)
  await migrated.stop()
  await personal.stop()
}
