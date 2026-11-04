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
  /// The build's one alert installation ID, which its coordinator may still hold.
  let installation: String
  let alerts: Bool
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

  init(host: String = "100.64.1.2", port: String? = nil, alerts: Bool = false) async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let support = root.appending(path: "Support")
    let suite = "legacy-install-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defaults.set(host, forKey: "coordinatorAddress")
    if let port { defaults.set(port, forKey: "coordinatorPort") }
    let installation = UUID().uuidString
    defaults.set(installation, forKey: "notificationInstallationID")
    defaults.set(alerts, forKey: "notificationsEnabled")
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
    self.installation = installation
    self.alerts = alerts
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

  /// The end state migration.md promises, whatever run got it there: one unpaired profile at the
  /// build's address, and one queue keyed to that address, holding the build's messages in its own
  /// folder and its alert installation.
  func expectMigrated(_ profiles: [CoordinatorProfile], held: [HeldQueue]) throws {
    let files = FileManager.default
    #expect(profiles.count == 1)
    let profile = try #require(profiles.first)
    #expect(profile.pin == nil)
    #expect(profile.address == address)
    #expect(held.count == 1)
    let queue = try #require(held.first)
    #expect(queue.address == address && queue.coordinator == nil)
    #expect(queue.installation?.description == installation)
    let folder = queue.folder(applicationSupport: support)
    #expect(try Data(contentsOf: folder.appending(path: "pending.json")) == pending)
    #expect(
      try Data(contentsOf: folder.appending(path: "Attachments/\(attachment.id)/Notes.txt"))
        == bytes)
    #expect(!files.fileExists(atPath: directory(profile).root.path), "Nothing in the profile")
    #expect(!files.fileExists(atPath: oldOutbox.path))
    #expect(try Data(contentsOf: otherOutbox.appending(path: "pending.json")) == Data("[]".utf8))
    #expect(files.fileExists(atPath: draft.path), "The global composer store is kept")
    #expect(!files.fileExists(atPath: caches.appending(path: "Agent/Previews").path))
    #expect(defaults.object(forKey: "coordinatorAddress") == nil)
    #expect(defaults.object(forKey: "coordinatorPort") == nil)
    #expect(defaults.object(forKey: "notificationInstallationID") == nil)
    #expect(defaults.object(forKey: "notificationsEnabled") as? Bool == alerts)
    #expect(defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("migrating") })
    struct Saved: Decodable {
      let profiles: [CoordinatorProfile]
      let held: [HeldQueue]
    }
    let saved = try JSONDecoder().decode(Saved.self, from: savedProfiles())
    #expect(saved.profiles == profiles && saved.held == held)
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

/// Waits up to ten seconds for `predicate` and says whether it held, so a test can print what it
/// found before it expects.
@MainActor private func settles(_ predicate: () async -> Bool) async throws -> Bool {
  let deadline = ContinuousClock.now + .seconds(10)
  while !(await predicate()) {
    if ContinuousClock.now >= deadline { return false }
    try await Task.sleep(for: .milliseconds(10))
  }
  return true
}

/// Each alert control a coordinator got, naming the single-address build's installation "old" and
/// the profile's own "profile".
private func described(
  _ controls: [NotificationRequest], old: String, profile: ProfileID
) -> [String] {
  controls.map { request in
    let (kind, id) =
      switch request {
      case .status(let value): ("status", value.installationId)
      case .register(let value): ("register", value.installationId)
      case .unregister(let value): ("unregister", value.installationId)
      }
    return "\(kind)(\(id == old ? "old" : id == "\(profile)" ? "profile" : id))"
  }
}

@MainActor @Test
func migrationQuarantinesTheLastQueueIntoAnUnpairedProfileShownAtOnce() async throws {
  let install = try await LegacyInstall(host: "studio.example-tailnet.ts.net")
  defer { install.remove() }
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: .tailnet)
  try install.expectMigrated(coordinators.profiles, held: coordinators.queues)
  #expect(coordinators.profiles.first?.name.description == "studio")
  #expect(coordinators.chat.lanes.map(\.session).allSatisfy { $0 == nil }, "Unpaired: no session")
  try await eventually("held rows before pairing") { coordinators.chat.held.count == 2 }
  #expect(coordinators.chat.held.map(\.item.text) == install.queued.map(\.text))
}

@MainActor
@Test(
  arguments: [
    Coordinators.MigrationStep.queueNamed, .profileSaved, .quarantined, .markerRemoved,
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
    defaults: install.defaults, applicationSupport: install.support, caches: install.caches)
  try install.expectMigrated(resumed.profiles, held: resumed.held)
  #expect(resumed.profiles.first?.address.port == 4123)
}

@MainActor @Test func legacyHoldRestoresACopyAndDiscardsOnlyTheChosenItem() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let queue = try #require(
    try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches
    ).held.first)
  let folder = queue.folder(applicationSupport: install.support)
  let hold = LegacyHold(folder)
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
  let held = folder.appending(path: "Attachments/\(install.attachment.id)")
  #expect(!FileManager.default.fileExists(atPath: held.path))
  #expect(try Data(contentsOf: copy.url) == install.bytes, "The draft copy has its own lifetime")
}

@Test func anUnreadableHoldSurfacesAnErrorAndStaysOnDisk() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appending(path: "pending.json")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let garbage = Data("not a queue".utf8)
  try garbage.write(to: file)
  let hold = LegacyHold(root)
  await #expect(throws: (any Error).self) { try await hold.items() }
  await #expect(throws: (any Error).self) { try await hold.discard("any") }
  #expect(try Data(contentsOf: file) == garbage)
}

/// A later single-address build saves its coordinator's acceptance beside each queued request. A
/// held message it saw accepted is never restored, and discarding another keeps that record.
@Test func aHeldMessageTheEarlierBuildSawAcceptedIsNeverRestored() async throws {
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: directory.legacy, withIntermediateDirectories: true)
  let accepted = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .steer, text: "Invented: the coordinator saved this")
  let unconfirmed = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .steer, text: "Invented: this may have arrived")
  let refused = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .steer, text: "Invented: this one is discarded")
  func saved(_ request: NativeRequestSubmit, _ state: String) throws -> [String: Any] {
    var fields = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    fields["deliveryState"] = state
    return fields
  }
  try JSONSerialization.data(withJSONObject: [
    saved(accepted, "accepted"), saved(unconfirmed, "unconfirmed"), saved(refused, "rejected"),
  ]).write(to: directory.legacy.appending(path: "pending.json"))
  let hold = LegacyHold(directory.legacy)
  #expect(try await hold.items().map(\.accepted) == [true, false, false])
  let drafts = AttachmentStore(directory: root.appending(path: "Drafts"))
  #expect(try await hold.restore(accepted.inputId, to: drafts) == nil)
  #expect(try await hold.restore(unconfirmed.inputId, to: drafts)?.text == unconfirmed.text)
  try await hold.discard(refused.inputId)
  #expect(try await hold.items().map(\.id) == [accepted.inputId, unconfirmed.inputId])
  #expect(try await hold.items().map(\.accepted) == [true, false], "A rewrite keeps the record")
}

/// The single-address build's later releases save the queue as an object that also holds their
/// composer's receipts. Its messages are held like a bare array's, and a copy restored from the
/// hold belongs to no session's outbox.
@Test func aHeldQueueSavedWithComposerReceiptsIsReadAndRestored() async throws {
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: directory.legacy, withIntermediateDirectories: true)
  let accepted = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .steer, text: "Invented: the coordinator saved this")
  let unconfirmed = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .followUp, text: "Invented: this may have arrived")
  func saved(_ request: NativeRequestSubmit, _ state: String) throws -> [String: Any] {
    var fields = try #require(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    fields["deliveryState"] = state
    return fields
  }
  let file = directory.legacy.appending(path: "pending.json")
  try JSONSerialization.data(withJSONObject: [
    "pending": [saved(accepted, "accepted"), saved(unconfirmed, "unconfirmed")],
    "composerInputs": [UUID().uuidString: accepted.inputId],
  ]).write(to: file)
  let hold = LegacyHold(directory.legacy)
  #expect(try await hold.items().map(\.id) == [accepted.inputId, unconfirmed.inputId])
  #expect(try await hold.items().map(\.accepted) == [true, false])
  let drafts = AttachmentStore(directory: root.appending(path: "Drafts"))
  #expect(try await hold.restore(accepted.inputId, to: drafts) == nil)
  let restored = try #require(try await hold.restore(unconfirmed.inputId, to: drafts))
  #expect(restored.text == unconfirmed.text && restored.mode == .followUp)
  #expect(try await hold.items().count == 2, "Restore copies; the held item stays")
  let session = CoordinatorSession(
    directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"),
    pin: CoordinatorID(UUID()), stamps: StampSource(),
    transport: CoordinatorTransport { _ in throw ConnectionError.closed })
  #expect(await session.commitRestoration(restored) == .invalidated)
  try await hold.discard(unconfirmed.inputId)
  #expect(try await hold.items().map(\.id) == [accepted.inputId])
  #expect(try await hold.items().map(\.accepted) == [true], "A rewrite keeps the record")
}

/// Work's queue held from before the update cannot be read, and Personal's holds some that can.
@MainActor private struct TwoHolds {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let work: Hold
  let personal: Hold
  let chat = ChatModel()
  static let warning =
    "Messages held from before the update could not be read. They stay on this phone."

  init(personalHolds texts: [String]) throws {
    let unreadable = HeldQueue(
      address: try CoordinatorAddress(host: "100.64.1.2", port: 4001), installation: nil)
    let folder = unreadable.folder(applicationSupport: root)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not a queue".utf8).write(to: folder.appending(path: "pending.json"))
    work = Hold(queue: unreadable, store: LegacyHold(folder))
    personal = try heldQueue(
      texts.enumerated().map { index, text in
        NativeRequestSubmit(inputId: "held-\(index)", mode: .steer, text: text)
      }, in: root, address: try CoordinatorAddress(host: "100.64.1.3", port: 4002))
  }

  func hold(_ hold: Hold) { chat.holds.append(hold) }
  /// What Remove does to a queue held for the coordinator it removes.
  func release(_ hold: Hold) { chat.holds.removeAll { $0.queue.id == hold.queue.id } }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

/// Work's queue held from before the update cannot be read, and Personal's can. The user removes
/// Work, which deletes the messages held for its coordinator. The warning over the feed goes with
/// them, and Personal's held message stays, after a relaunch too.
@MainActor @Test(.timeLimit(.minutes(1)))
func removingTheCoordinatorWhoseHeldMessagesCannotBeReadRemovesTheWarning() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "two-holds-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4001))
  work.pin = CoordinatorID(UUID())
  var personal = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3", port: 4002))
  personal.pin = CoordinatorID(UUID())
  let unreadable = HeldQueue(address: work.address, coordinator: work.pin, installation: nil)
  let readable = HeldQueue(address: personal.address, coordinator: personal.pin, installation: nil)
  try writePrivately(
    Data("not a queue".utf8),
    to: unreadable.folder(applicationSupport: root).appending(path: "pending.json"))
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: "held-0", mode: .steer, text: "Invented: Personal's held note")
    ]), to: readable.folder(applicationSupport: root).appending(path: "pending.json"))
  try writePrivately(
    JSONEncoder().encode(
      Coordinators.SavedProfiles(profiles: [work, personal], held: [unreadable, readable])),
    to: root.appending(path: "Agent/profiles.json"))
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: .tailnet)
  }
  let coordinators = launch()
  let chat = coordinators.chat
  try await eventually("Personal's held message and the warning") {
    chat.held.count == 1 && chat.heldError != nil
  }
  let confirmation = coordinators.removalMessage(work.id)
  try await coordinators.remove(work.id)
  let relaunched = launch()
  try await eventually("Personal's held message after a relaunch") {
    relaunched.chat.held.count == 1
  }
  print(
    "IF14-W2[Work removed] Remove Work? \(confirmation) warning=\(chat.heldError ?? "nil") held=\(chat.held.map(\.item.text)) after a relaunch: warning=\(relaunched.chat.heldError ?? "nil")"
  )
  #expect(confirmation == "Queued messages on this phone could not be read. Removing deletes them.")
  #expect(chat.heldError == nil, "A removed coordinator's warning stays over the feed")
  #expect(chat.held.map(\.item.text) == ["Invented: Personal's held note"])
  #expect(relaunched.chat.heldError == nil)
  #expect(!FileManager.default.fileExists(atPath: unreadable.folder(applicationSupport: root).path))
}

/// Work's queue cannot be read, and Personal's is read after it, when it arrives and again after
/// the user discards one of Personal's held messages. Whichever read finishes last, the warning
/// shows while Work's queue is held, and only then.
@MainActor @Test(.timeLimit(.minutes(1)))
func theHeldWarningStaysWhileAnUnreadableQueueIsHeldWhicheverReadFinishesLast() async throws {
  let holds = try TwoHolds(personalHolds: [
    "Invented: Personal's first held note", "Invented: Personal's second held note",
  ])
  defer { holds.remove() }
  let chat = holds.chat
  holds.hold(holds.work)
  try await eventually("the warning over the feed") { chat.heldError != nil }
  holds.hold(holds.personal)
  try await eventually("Personal's held messages") { chat.held.count == 2 }
  let afterAttach = chat.heldError
  await chat.discardHeld(try #require(chat.held.first))
  let afterDiscard = chat.heldError
  holds.release(holds.work)
  print(
    "IF14-W2[Personal read last] warning after Personal's read=\(afterAttach ?? "nil") after Personal's discard=\(afterDiscard ?? "nil") after Work's queue left=\(chat.heldError ?? "nil") held=\(chat.held.map(\.item.text))"
  )
  #expect(afterAttach == TwoHolds.warning, "Personal's read hid Work's warning")
  #expect(afterDiscard == TwoHolds.warning, "Reading Personal's hold again hid Work's warning")
  #expect(chat.heldError == nil)
  #expect(chat.held.map(\.item.text) == ["Invented: Personal's second held note"])
}

/// Work's queue leaves before the read of its held messages, which cannot succeed, finishes. That
/// read shows no warning over the feed.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldReadThatFinishesAfterItsQueueLeftShowsNoWarning() async throws {
  let holds = try TwoHolds(personalHolds: ["Invented: Personal's held note"])
  defer { holds.remove() }
  let chat = holds.chat
  holds.hold(holds.personal)
  try await eventually("Personal's held message") { chat.held.count == 1 }
  holds.hold(holds.work)
  holds.release(holds.work)
  // Long enough for the read that Work's queue started to finish.
  try await Task.sleep(for: .milliseconds(500))
  print("IF14-W2[Work's queue left before its read finished] warning=\(chat.heldError ?? "nil")")
  #expect(chat.heldError == nil, "A late read of a queue that left put its warning over the feed")
  #expect(chat.held.map(\.item.text) == ["Invented: Personal's held note"])
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
  #expect(await fixture.received().contains(.observe(.init(inputIds: [], sourceStatus: true))))
  try await eventually("this lane's own notification channel, and the old installation withdrawn") {
    let controls = await fixture.notificationControls()
    return controls.contains(.status(.init(installationId: "\(profile.id)")))
      && controls.contains(.unregister(.init(installationId: install.installation)))
  }
  #expect(
    described(await fixture.notificationControls(), old: install.installation, profile: profile.id)
      .allSatisfy { $0.hasSuffix("(profile)") || $0 == "unregister(old)" },
    "Only this profile's installation, and the old one's withdrawal")
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

/// The single-address build registered one alert installation with its coordinator. With alerts
/// off, that build withdrew it again at each connection until the coordinator confirmed. With
/// alerts on, only a register of the same token for another installation removes it. The update
/// can land before either, and the user can turn alerts off before the first connection. Once the
/// migrated profile pairs, a socket that proves its pin withdraws the old installation, so the
/// coordinator alerts this device only through the profile's own installation, and only while
/// alerts are on.
@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: ["left off", "turned off after the update", "left on"])
func theSingleAddressBuildsAlertInstallationIsWithdrawnOnceTheMigratedProfilePairs(
  _ alerts: String
) async throws {
  let install = try await LegacyInstall(alerts: alerts != "left off")
  defer { install.remove() }
  let token = String(repeating: "ab", count: 32)
  let fixture = FixtureCoordinator()
  await fixture.register(install.installation, token: token)
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let registration = NotificationRegistration(
    enabled: install.alerts, permission: { true }, register: {},
    save: { install.defaults.set($0, forKey: "notificationsEnabled") })
  let coordinators = Coordinators(
    registration: registration, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: loopback(port))
  let profile = try #require(coordinators.profiles.first)
  switch alerts {
  case "turned off after the update": await registration.setEnabled(false)
  case "left on":
    await registration.start()
    await registration.received(token: token)
  default: break
  }
  await coordinators.setActive(true)
  do {
    try await eventually("the migrated profile paired and connected") {
      coordinators.chat.connection == .connected
    }
    try await eventually("its alert channel checked") {
      await fixture.notificationControls().contains(
        .status(.init(installationId: "\(profile.id)")))
    }
    let withdrawn = try await settles { !(await fixture.holds(install.installation)) }
    let profileHeld =
      alerts == "left on"
      ? try await settles { await fixture.holds("\(profile.id)") }
      : await fixture.holds("\(profile.id)")
    let controls = described(
      await fixture.notificationControls(), old: install.installation, profile: profile.id)
    print(
      "IF13-X2[\(alerts)] toggle=\(registration.enabled ? "on" : "off") controls=\(controls) old installation held=\(!withdrawn) profile's installation held=\(profileHeld)"
    )
    #expect(withdrawn, "The coordinator keeps the single-address build's installation")
    #expect(profileHeld == (alerts == "left on"))
  } catch {
    await coordinators.setActive(false)
    await fixture.stop()
    throw error
  }
  await coordinators.setActive(false)
  await fixture.stop()
}

/// The migrated profile's saved address no longer answers, so it stays unpaired until the user
/// edits the address, which pairs it at port 4001. The coordinator there is the single-address
/// build's own, under a new address, but the phone cannot tell it from another, so it is sent
/// nothing for the build's alert installation. The installation stays saved for a coordinator
/// paired at the build's address. Until one is, with alerts off, the build's coordinator keeps it.
@MainActor @Test(.timeLimit(.minutes(1)))
func anAddressEditThatPairsTheMigratedProfileElsewhereSendsTheBuildsInstallationNowhere()
  async throws
{
  let install = try await LegacyInstall()
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  await fixture.register(install.installation, token: String(repeating: "ab", count: 32))
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches,
    transport: CoordinatorTransport { address in
      guard address.port == 4001 else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let profile = try #require(coordinators.profiles.first)
  await coordinators.setActive(true)
  do {
    try await eventually("the saved address answered nothing") {
      coordinators.pairingError[profile.id] != nil
    }
    try await coordinators.update(
      profile.id, name: profile.name,
      address: CoordinatorAddress(host: install.address.host, port: 4001))
    try await eventually("paired at the edited address") {
      coordinators.chat.connection == .connected
    }
    // Long enough for a withdrawal sent at pairing to arrive over loopback.
    try await Task.sleep(for: .seconds(1))
    let sent = await fixture.notificationControls().contains(
      .unregister(.init(installationId: install.installation)))
    struct Saved: Decodable { let held: [HeldQueue] }
    let queue = try JSONDecoder().decode(Saved.self, from: install.savedProfiles()).held.first
    print(
      "IF14-V2[paired elsewhere] controls=\(described(await fixture.notificationControls(), old: install.installation, profile: profile.id)) installation still saved=\(queue?.installation != nil) old installation held=\(await fixture.holds(install.installation))"
    )
    #expect(!sent, "A coordinator paired at another address was sent the build's installation")
    #expect(queue?.installation?.description == install.installation)
    #expect(queue?.address == install.address)
  } catch {
    await coordinators.setActive(false)
    await fixture.stop()
    throw error
  }
  await coordinators.setActive(false)
  await fixture.stop()
}

/// A launch that stops after any migration step, then a withdrawal whose reply is lost, still end
/// with the single-address build's alert installation withdrawn. The phone keeps that withdrawal
/// across a relaunch until the coordinator confirms it.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    Coordinators.MigrationStep.queueNamed, .profileSaved, .quarantined, .markerRemoved,
  ])
func theSingleAddressBuildsAlertInstallationIsWithdrawnAfterACrashAndALostReply(
  _ step: Coordinators.MigrationStep
) async throws {
  let install = try await LegacyInstall(port: "4123")
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  await fixture.register(install.installation, token: String(repeating: "ab", count: 32))
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
      crash: { if $0 == step { throw Crash() } })
  }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: NotificationRegistration(
        enabled: false, permission: { true }, register: {}, save: { _ in }),
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
      transport: loopback(port))
  }
  let withdrawal = NotificationRequest.unregister(.init(installationId: install.installation))
  await fixture.dropNextNotificationRemoval()
  let first = launch()
  await first.setActive(true)
  let lost = try await settles { await fixture.notificationControls().contains(withdrawal) }
  await first.setActive(false)
  let second = launch()
  await second.setActive(true)
  let withdrawn = try await settles { !(await fixture.holds(install.installation)) }
  let sent = await fixture.notificationControls().filter { $0 == withdrawal }.count
  print(
    "IF13-X2[crash after \(step)] first withdrawal sent and lost=\(lost) withdrawals sent=\(sent) old installation held=\(!withdrawn)"
  )
  await second.setActive(false)
  await fixture.stop()
  #expect(lost, "The first launch never withdrew the old installation")
  #expect(withdrawn, "The coordinator keeps the single-address build's installation")
  #expect(sent == 2, "Sent once per launch until confirmed")
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
  try install.expectMigrated(coordinators.profiles, held: coordinators.queues)
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
  #expect(coordinators.queues.isEmpty && chat.held.isEmpty)
  let heldLeft =
    (try? FileManager.default.contentsOfDirectory(
      atPath: install.support.appending(path: "Agent/Held").path)) ?? []
  #expect(heldLeft.isEmpty, "The messages held for the removed coordinator stay on this phone")
  #expect(
    await fixture.notificationControls().contains(
      .unregister(.init(installationId: "\(profile.id)"))), "Alerts are withdrawn")
  await coordinators.setActive(false)
  await fixture.stop()
}

/// A Remove that stopped after saving leaves its files. The next launch deletes every profile
/// directory and held queue `profiles.json` does not list, and keeps the ones it lists.
@MainActor @Test func launchDeletesTheFilesOfEveryProfileThatIsNoLongerSaved() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let caches = root.appending(path: "Caches")
  let suite = "launch-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let saved = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let listed = HeldQueue(address: saved.address, installation: nil)
  let unlisted = HeldQueue(address: saved.address, installation: nil)
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [saved], held: [listed])),
    to: root.appending(path: "Agent/profiles.json"))
  for queue in [listed, unlisted] {
    try writePrivately(
      Data("[]".utf8), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
  }
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
  #expect(FileManager.default.fileExists(atPath: listed.folder(applicationSupport: root).path))
  #expect(!FileManager.default.fileExists(atPath: unlisted.folder(applicationSupport: root).path))
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
  // A queue the single-address build left for the address Work is added at, so it is Work's.
  let queue = HeldQueue(address: try CoordinatorAddress(host: "100.64.1.2"), installation: nil)
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [], held: [queue])),
    to: root.appending(path: "Agent/profiles.json"))
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
  let held = queue.folder(applicationSupport: root).appending(path: "pending.json")
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Invented held note")
    ]), to: held)
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: held.path)
  let hold = coordinators.removalMessage(id)
  #expect(hold == unreadable, "An unreadable hold")
  try await coordinators.remove(id)
  #expect(!FileManager.default.fileExists(atPath: directory.root.path))
  #expect(!FileManager.default.fileExists(atPath: held.deletingLastPathComponent().path))
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
  chat.attach(Lane(id: directory.profile, session: session))
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

// MARK: - What the single-address build left belongs to the coordinator at its address

/// What one launch of the single-address build left goes to the first coordinator proven at its
/// address, once. One proven at any other address, or a later one there, takes nothing.
@Test func theFirstCoordinatorPairedAtTheBuildsAddressTakesWhatItLeft() throws {
  let address = try CoordinatorAddress(host: "100.64.1.2")
  let installation = try #require(InstallationID(legacy: UUID().uuidString))
  var queue = HeldQueue(address: address, installation: installation)
  let first = CoordinatorID(UUID())
  let later = CoordinatorID(UUID())
  #expect(queue.bind(first, at: try CoordinatorAddress(host: "100.64.1.2", port: 4001)) == nil)
  #expect(queue.coordinator == nil && queue.installation == installation)
  #expect(
    queue.bind(first, at: address)
      == PendingWithdrawal(installation: installation, address: address, pin: first))
  #expect(queue.bind(later, at: address) == nil)
  #expect(queue.coordinator == first && queue.installation == nil)
}

private func submitted(_ fixture: FixtureCoordinator) async -> [String] {
  await fixture.received().compactMap {
    if case .submit(let input) = $0 { input.text } else { nil }
  }
}

/// The single-address build used `used` at `install.address`, which holds that build's alert
/// installation and answers nothing after the update. Port 4001 reaches Work's coordinator, or, with
/// `movedTo4001`, the build's own coordinator under a new address. `bringBack` makes the build's
/// address answer again. The body starts once the migrated profile's pairing has failed.
@MainActor private func withTheOldAddressSilent(
  _ install: LegacyInstall, registration: NotificationRegistration? = nil,
  movedTo4001: Bool = false,
  _ body: (
    _ coordinators: Coordinators, _ migrated: CoordinatorProfile, _ used: FixtureCoordinator,
    _ work: FixtureCoordinator, _ bringBack: @Sendable () async -> Void
  ) async throws -> Void
) async throws {
  let used = FixtureCoordinator()
  let work = FixtureCoordinator()
  await used.register(install.installation, token: String(repeating: "ab", count: 32))
  let (usedListener, usedPort) = try await listen(used)
  defer { usedListener.cancel() }
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let routes = Routes([4001: movedTo4001 ? usedPort : workPort])
  let coordinators = Coordinators(
    registration: registration, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let migrated = try #require(coordinators.profiles.first)
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await used.stop()
    await work.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("the build's address answered nothing") {
      coordinators.pairingError[migrated.id] != nil
    }
    let back = [4001: movedTo4001 ? usedPort : workPort, install.address.port: usedPort]
    try await body(coordinators, migrated, used, work) { await routes.set(back) }
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The single-address build queued two messages for its coordinator at its address, which answers
/// nothing after the update, so the user points the one saved coordinator at Work's address, which
/// pairs it with Work. In "after Personal is added", the build's coordinator answers again and the
/// user adds it as Personal at that address. A held message is addressed to the coordinator saved
/// at the address it was queued for. Without one, Restore addresses nothing until the user chooses,
/// and a copy sent where the user chose leaves the message held.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["one coordinator", "after Personal is added"])
func aHeldMessageGoesToTheCoordinatorAtItsAddressOrWhereTheUserChooses(_ when: String)
  async throws
{
  let install = try await LegacyInstall()
  defer { install.remove() }
  try await withTheOldAddressSilent(install) { coordinators, migrated, used, work, bringBack in
    let chat = coordinators.chat
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await eventually("the migrated profile paired with Work") {
      chat.snapshots[migrated.id]?.connection == .connected
    }
    if when == "after Personal is added" {
      await bringBack()
      try await coordinators.add(name: TagName("Personal"), address: install.address)
      try await eventually("both connected") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    }
    try await eventually("held rows") { chat.held.count == 2 }
    let held = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(held)
    let restored = chat.draft
    let line = chat.addressesByName ? chat.recipientLine : "(no recipient line)"
    let offered = chat.heldChoices.map(\.name.description)
    await chat.send()
    let reached = try await settles { await submitted(used) + submitted(work) != [] }
    print(
      "IF14-V1[\(when)] Restore: draft=\(restored.debugDescription) line=\(line) offered=\(offered) after Send, reached anyone=\(reached) Work's coordinator got=\(await submitted(work)) the build's coordinator got=\(await submitted(used)) held=\(chat.held.map(\.item.text))"
    )
    #expect(
      await submitted(work).isEmpty,
      "A message the build queued for its coordinator went to Work without the user choosing")
    if when == "after Personal is added" {
      #expect(restored == "Second held note" && line == "To Personal")
      #expect(await submitted(used) == ["Second held note"])
      #expect(
        !chat.held.contains { $0.id == held.id }, "It stays held after reaching its coordinator")
    } else {
      #expect(restored.isEmpty, "Restore addressed it to Work without the user choosing")
      #expect(offered == ["Work"])
      await chat.restoreHeld(held, for: migrated.id)
      await chat.send()
      let chosen = try await settles { await submitted(work) == ["Second held note"] }
      print(
        "IF14-V1[\(when)] the user chose Work: Work's coordinator got=\(await submitted(work)) held=\(chat.held.map(\.item.text))"
      )
      #expect(chosen, "The coordinator the user chose did not get it")
      #expect(
        chat.held.contains { $0.id == held.id },
        "A copy sent where the user chose took the build's message out of the hold")
    }
  }
}

/// Round 7's R7-6: the single-address build's coordinator answers only at a new address after the
/// update, and the user points the migrated profile there. The phone cannot tell that from another
/// coordinator, so the held message goes there after one explicit choice. That copy leaves the
/// message held until the user discards it. Before the edit nothing is paired, so Restore offers
/// no coordinator.
@MainActor @Test(.timeLimit(.minutes(1)))
func aHeldMessageForItsCoordinatorAtANewAddressTakesOneChoice() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  try await withTheOldAddressSilent(install, movedTo4001: true) {
    coordinators, migrated, used, _, _ in
    let chat = coordinators.chat
    try await eventually("held rows") { chat.held.count == 2 }
    let held = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(held)
    let beforeEdit = (draft: chat.draft, offered: chat.heldChoices.map(\.name.description))
    try await coordinators.update(
      migrated.id, name: migrated.name,
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await eventually("paired at the new address") {
      chat.snapshots[migrated.id]?.connection == .connected
    }
    await chat.restoreHeld(held)
    let withoutChoice = chat.draft
    let offered = chat.heldChoices.map(\.name.description)
    await chat.restoreHeld(held, for: migrated.id)
    await chat.send()
    let delivered = try await settles { await submitted(used) == ["Second held note"] }
    let stillHeld = chat.held.contains { $0.id == held.id }
    await chat.discardHeld(held)
    print(
      "IF14-V1[R7-6] before the edit: draft=\(beforeEdit.draft.debugDescription) offered=\(beforeEdit.offered) after it: draft without a choice=\(withoutChoice.debugDescription) offered=\(offered) delivered once chosen=\(delivered) still held=\(stillHeld) after Discard held=\(chat.held.map(\.item.text))"
    )
    #expect(beforeEdit.draft.isEmpty && beforeEdit.offered.isEmpty)
    #expect(withoutChoice.isEmpty, "Restore addressed it to a coordinator at another address")
    #expect(offered == [migrated.name.description])
    #expect(delivered, "One choice did not send it")
    #expect(stillHeld, "A copy sent where the user chose took the build's message out of the hold")
    #expect(!chat.held.contains { $0.id == held.id })
  }
}

/// The user points the migrated profile at Work's address before the build's own coordinator
/// answers again. Work's coordinator never held the build's alert installation, so it never sees
/// it. Later the user adds the build's coordinator as Personal at the build's address. That pairing
/// withdraws the installation there, whatever the toggle says, so the build's coordinator alerts
/// this device only through Personal's own installation, and only while alerts are on.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: ["left off", "turned off before the old coordinator pairs", "left on"])
func theBuildsAlertInstallationIsWithdrawnOnlyAtTheAddressItWasRegisteredAt(_ alerts: String)
  async throws
{
  let install = try await LegacyInstall(alerts: alerts != "left off")
  defer { install.remove() }
  let registration = NotificationRegistration(
    enabled: install.alerts, permission: { true }, register: {},
    save: { install.defaults.set($0, forKey: "notificationsEnabled") })
  if alerts != "left off" {
    await registration.start()
    await registration.received(token: String(repeating: "ab", count: 32))
  }
  try await withTheOldAddressSilent(install, registration: registration) {
    coordinators, migrated, used, work, bringBack in
    let chat = coordinators.chat
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await eventually("the migrated profile paired with Work") {
      chat.snapshots[migrated.id]?.connection == .connected
    }
    try await eventually("Work's alert channel checked") {
      await work.notificationControls().contains(.status(.init(installationId: "\(migrated.id)")))
    }
    if alerts == "turned off before the old coordinator pairs" {
      await registration.setEnabled(false)
    }
    await bringBack()
    try await coordinators.add(name: TagName("Personal"), address: install.address)
    let personal = coordinators.profiles[1].id
    try await eventually("Personal's alert channel checked") {
      await used.notificationControls().contains(.status(.init(installationId: "\(personal)")))
    }
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    let withdrawn = try await settles { !(await used.holds(install.installation)) }
    let toWork = described(
      await work.notificationControls(), old: install.installation, profile: migrated.id)
    print(
      "IF14-V2[\(alerts)] toggle=\(registration.enabled ? "on" : "off") Work's coordinator got=\(toWork) the build's coordinator got=\(described(await used.notificationControls(), old: install.installation, profile: personal)) old installation still held there=\(!withdrawn)"
    )
    #expect(
      !toWork.contains("unregister(old)"), "Work's coordinator was sent the build's installation")
    #expect(
      withdrawn, "The build's coordinator keeps alerting this device through its installation")
  }
}

/// The user adds the single-address build's coordinator as Personal at the build's address before
/// the migrated profile pairs. The migrated profile then never pairs ("Already saved as Personal."),
/// and Personal's pairing withdraws the build's alert installation.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["left off", "turned off before it pairs"])
func theBuildsAlertInstallationIsWithdrawnWhenItsCoordinatorIsAddedFirst(_ alerts: String)
  async throws
{
  let install = try await LegacyInstall(alerts: alerts != "left off")
  defer { install.remove() }
  let registration = NotificationRegistration(
    enabled: install.alerts, permission: { true }, register: {},
    save: { install.defaults.set($0, forKey: "notificationsEnabled") })
  if alerts != "left off" {
    await registration.start()
    await registration.received(token: String(repeating: "ab", count: 32))
    await registration.setEnabled(false)
  }
  try await withTheOldAddressSilent(install, registration: registration) {
    coordinators, migrated, used, _, bringBack in
    await bringBack()
    try await coordinators.add(name: TagName("Personal"), address: install.address)
    let personal = coordinators.profiles[1].id
    try await eventually("the migrated profile's pairing refused") {
      coordinators.pairingError[migrated.id]?.hasPrefix("Already saved") == true
    }
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    let withdrawn = try await settles { !(await used.holds(install.installation)) }
    print(
      "IF14-V2[added first, \(alerts)] pairing line=\(coordinators.pairingError[migrated.id] ?? "nil") the build's coordinator got=\(described(await used.notificationControls(), old: install.installation, profile: personal)) old installation still held=\(!withdrawn)"
    )
    #expect(
      withdrawn, "The build's coordinator keeps alerting this device through its installation")
  }
}

/// The previous build kept the single-address build's alert installation on the migrated profile as
/// `inherited` until that profile paired. A `profiles.json` it wrote still has the installation
/// withdrawn once a saved coordinator pairs at that profile's address.
@MainActor @Test(.timeLimit(.minutes(1)))
func anInstallationThePreviousBuildSavedOnTheMigratedProfileIsStillWithdrawn() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "previous-build-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let installation = UUID().uuidString
  let file = root.appending(path: "Agent/profiles.json")
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(
    """
    {"withdrawals":[],"profiles":[{"id":"\(UUID().uuidString)","name":"Coordinator",\
    "address":{"host":"100.64.1.2","port":43187},"inherited":"\(installation)"}]}
    """.utf8
  ).write(to: file)
  let fixture = FixtureCoordinator()
  await fixture.register(installation, token: String(repeating: "ab", count: 32))
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  await coordinators.setActive(true)
  do {
    try await eventually("paired") { coordinators.chat.connection == .connected }
    let withdrawn = try await settles { !(await fixture.holds(installation)) }
    print(
      "IF14-V2[previous build's profiles.json] withdrawn=\(withdrawn) saved=\(String(decoding: try Data(contentsOf: file), as: UTF8.self).replacingOccurrences(of: installation, with: "<old>"))"
    )
    #expect(withdrawn, "The installation the previous build saved was never withdrawn")
    // The queue that kept only the installation has no folder, and Remove still finishes.
    try await coordinators.remove(try #require(coordinators.profiles.first).id)
    #expect(coordinators.profiles.isEmpty && coordinators.queues.isEmpty)
  } catch {
    await coordinators.setActive(false)
    await fixture.stop()
    throw error
  }
  await coordinators.setActive(false)
  await fixture.stop()
}

/// The single-address build queued messages for its coordinator at its address, which answers
/// nothing after the update. In "held for another address", the user points the one saved
/// coordinator at Work's address, so the held messages show over Work's feed and nothing says they
/// are Work's. `/feedback` then reaches Work without the automatic screenshot, which would show
/// them, and the composer says why. In "held for this coordinator", the build's coordinator answers
/// at its address again and pairs, so everything on screen is its own and the screenshot goes.
@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: ["held for another address", "held for this coordinator"])
func feedbackAttachesTheScreenshotOnlyWhenEverythingOnScreenIsTheRecipients(_ held: String)
  async throws
{
  let install = try await LegacyInstall()
  defer { install.remove() }
  try await withTheOldAddressSilent(install) { coordinators, migrated, used, work, bringBack in
    let chat = coordinators.chat
    let recipient: FixtureCoordinator
    if held == "held for this coordinator" {
      await bringBack()
      coordinators.retryPairing(migrated.id)
      recipient = used
    } else {
      try await coordinators.update(
        migrated.id, name: TagName("Work"),
        address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      recipient = work
    }
    try await eventually("held rows and a connection") {
      chat.held.count == 2 && chat.connection == .connected
    }
    chat.draft = "/feedback The invented reply is clipped"
    var captures = 0
    await chat.send(screenshot: {
      captures += 1
      return Data("Invented screen showing the held notes".utf8)
    })
    try await eventually("the feedback at its coordinator") { await recipient.count() == 1 }
    let files = await recipient.received().compactMap { event -> NativeRequestSubmit? in
      if case .submit(let input) = event { input } else { nil }
    }.flatMap { $0.attachments ?? [] }.map(\.name)
    let uploads = await recipient.uploadCount()
    print(
      "IF15-U1[\(held)] screenshots captured=\(captures) uploads=\(uploads) files=\(files) composer=\(chat.error ?? "nil")"
    )
    if held == "held for this coordinator" {
      #expect(captures == 1 && files == ["Feedback.png", "Composer.log"])
      #expect(chat.error == nil)
    } else {
      #expect(captures == 0, "The screenshot captured messages held for another address")
      #expect(
        uploads == 0 && files.isEmpty, "Work got a screenshot of another coordinator's messages")
      #expect(
        chat.error
          == "Feedback was sent without a screenshot. The screen shows messages held from before the update, which may be another coordinator's."
      )
    }
  }
}

/// The single-address build used `studio.example-tailnet.ts.net`, which does not resolve yet after
/// the update, so the user adds the same machine as Personal by its tailnet IP. Once the name
/// resolves, the migrated profile's own pairing finds Personal's coordinator there and is refused.
/// That probe still proves Personal's coordinator answers at the build's address, so what the build
/// left goes to it: its alert installation is withdrawn there, whatever the toggle says, and Restore
/// addresses its held messages to Personal.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: ["left off", "turned off before the old coordinator pairs"])
func theBuildsCoordinatorSavedUnderAnotherAddressTakesWhatTheBuildLeft(_ alerts: String)
  async throws
{
  let install = try await LegacyInstall(
    host: "studio.example-tailnet.ts.net", alerts: alerts != "left off")
  defer { install.remove() }
  let registration = NotificationRegistration(
    enabled: install.alerts, permission: { true }, register: {},
    save: { install.defaults.set($0, forKey: "notificationsEnabled") })
  if alerts != "left off" {
    await registration.start()
    await registration.received(token: String(repeating: "ab", count: 32))
    await registration.setEnabled(false)
  }
  let used = FixtureCoordinator()
  await used.register(install.installation, token: String(repeating: "ab", count: 32))
  let (listener, port) = try await listen(used)
  defer { listener.cancel() }
  let routes = Routes([4002: port])
  let coordinators = Coordinators(
    registration: registration, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let chat = coordinators.chat
  let migrated = try #require(coordinators.profiles.first)
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await used.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("the build's address answered nothing") {
      coordinators.pairingError[migrated.id] != nil
    }
    try await coordinators.add(
      name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
    await routes.set([4002: port, install.address.port: port])
    coordinators.retryPairing(migrated.id)
    try await eventually("the migrated profile's pairing refused") {
      coordinators.pairingError[migrated.id]?.hasPrefix("Already saved") == true
    }
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    let withdrawn = try await settles { !(await used.holds(install.installation)) }
    try await eventually("held rows") { chat.held.count == 2 }
    let held = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(held)
    let personal = try #require(coordinators.profiles.first { $0.id != migrated.id })
    print(
      "IF15-U3[\(alerts)] the migrated profile's line=\(coordinators.pairingError[migrated.id] ?? "nil") toggle=\(registration.enabled ? "on" : "off") old installation still held=\(!withdrawn) Restore: draft=\(chat.draft.debugDescription) recipient=\(chat.recipient.map(chat.name) ?? "none")"
    )
    #expect(coordinators.pairingError[migrated.id] == "Already saved as Personal.")
    #expect(withdrawn, "The build's coordinator keeps alerting this device")
    #expect(chat.draft == "Second held note" && chat.recipient == personal.id)
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The user points Work at the single-address build's address, where a coordinator no saved profile
/// is pinned to answers, so the edit is refused. That coordinator takes nothing the build left: its
/// installation stays, and Restore still asks who gets a held message.
@MainActor @Test(.timeLimit(.minutes(1)))
func anEditRefusedAtTheBuildsAddressGivesWhatItLeftToNoOne() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  try await withTheOldAddressSilent(install) { coordinators, migrated, used, _, bringBack in
    let chat = coordinators.chat
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await eventually("Work paired") { chat.snapshots[migrated.id]?.connection == .connected }
    await bringBack()
    var shown = "nothing"
    do {
      try await coordinators.update(migrated.id, name: TagName("Work"), address: install.address)
    } catch { shown = error.localizedDescription }
    try await eventually("held rows") { chat.held.count == 2 }
    let held = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(held)
    // Long enough for a withdrawal sent at once to arrive over loopback.
    try await Task.sleep(for: .seconds(1))
    let kept = await used.holds(install.installation)
    print(
      "IF15-U3[refused, unsaved coordinator] the form shows \"\(shown)\" Restore: draft=\(chat.draft.debugDescription) offered=\(chat.heldChoices.map(\.name.description)) old installation still held=\(kept)"
    )
    #expect(shown == "This address answers as a different coordinator. Nothing was saved.")
    #expect(chat.draft.isEmpty, "Restore addressed a held message without a choice")
    #expect(kept, "A coordinator no saved profile is pinned to was sent the build's installation")
  }
}

/// The single-address build queued two messages for its coordinator at its address, which answers
/// nothing after the update. Either the user points the migrated profile at Work, or adds the
/// build's coordinator as Personal at that address before the migrated profile pairs. The messages
/// were queued for the coordinator Personal pins, so removing Work, or the duplicate profile, keeps
/// them in the feed and after a relaunch, and its confirmation does not count them.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: ["the migrated profile edited to Work", "Personal added before it pairs"])
func removingACoordinatorKeepsHeldMessagesQueuedForAnother(_ path: String) async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  try await withTheOldAddressSilent(install) { coordinators, migrated, _, _, bringBack in
    let chat = coordinators.chat
    if path == "the migrated profile edited to Work" {
      try await coordinators.update(
        migrated.id, name: TagName("Work"),
        address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      try await eventually("Work paired") {
        chat.snapshots[migrated.id]?.connection == .connected
      }
      await bringBack()
      try await coordinators.add(name: TagName("Personal"), address: install.address)
      try await eventually("both connected") {
        chat.snapshots.values.filter { $0.connection == .connected }.count == 2
      }
    } else {
      await bringBack()
      try await coordinators.add(name: TagName("Personal"), address: install.address)
      try await eventually("the migrated profile's pairing refused") {
        coordinators.pairingError[migrated.id]?.hasPrefix("Already saved") == true
      }
    }
    try await eventually("held rows") { chat.held.count == 2 }
    let holder = try #require(coordinators.profiles.first { $0.id == migrated.id })
    let held = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, line: chat.recipientLine)
    chat.draft = ""
    let confirmation = coordinators.removalMessage(migrated.id)
    try await coordinators.remove(migrated.id)
    let kept = chat.held.map(\.item.text)
    let relaunched = Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches, transport: .tailnet)
    let keptAfterRelaunch = try await settles { relaunched.chat.held.count == 2 }
    print(
      "IF15-U4-A[\(path)] Restore: draft=\(restored.draft.debugDescription) line=\(restored.line) | Remove \(holder.name)? \(confirmation) | after Remove: held=\(kept) saved=\(coordinators.profiles.map(\.name.description)) | after a relaunch: held=\(relaunched.chat.held.map(\.item.text))"
    )
    #expect(restored.draft == "Second held note" && restored.line == "To Personal")
    #expect(
      confirmation == "No queued messages are on this phone.",
      "Remove counts Personal's held messages as \(holder.name)'s")
    #expect(kept.count == 2, "Removing \(holder.name) deleted held messages queued for Personal")
    #expect(keptAfterRelaunch, "Held messages queued for Personal were gone after a relaunch")
  }
}

/// A `profiles.json` an earlier build wrote: the migrated profile is unpaired and keeps the build's
/// installation as `inherited`, and Personal is paired at the build's address. Personal's
/// coordinator takes what the build left at launch: the installation is withdrawn, whatever the
/// toggle says, and Restore addresses the held message to Personal.
@MainActor @Test(.timeLimit(.minutes(1)))
func aPreviousBuildsFileWithTheBuildsCoordinatorPairedAtItsAddressBindsWhatItLeft()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if15-b1-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set(false, forKey: "notificationsEnabled")
  let old = UUID().uuidString
  let used = FixtureCoordinator()
  await used.register(old, token: String(repeating: "ab", count: 32))
  let (listener, port) = try await listen(used)
  defer { listener.cancel() }
  let migrated = ProfileID()
  let personal = ProfileID()
  let file = root.appending(path: "Agent/profiles.json")
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(
    """
    {"withdrawals":[],"profiles":[{"id":"\(migrated)","name":"Coordinator",\
    "address":{"host":"100.64.1.2","port":43187},"inherited":"\(old)"},\
    {"id":"\(personal)","name":"Personal","address":{"host":"100.64.1.2","port":43187},\
    "pin":"\(used.id.uuid.uuidString)"}]}
    """.utf8
  ).write(to: file)
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: "Second held note")
    ]),
    to: root.appending(path: "Agent/Profiles/\(migrated)/Legacy/pending.json"))
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {},
    save: { defaults.set($0, forKey: "notificationsEnabled") })
  let coordinators = Coordinators(
    registration: registration, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await used.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Personal connected") {
      chat.snapshots[personal]?.connection == .connected
    }
    try await eventually("held row") { chat.held.count == 1 }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, line: chat.recipientLine)
    await coordinators.setActive(false)
    await coordinators.setActive(true)
    let withdrawn = try await settles { !(await used.holds(old)) }
    print(
      "IF15-U4-B1[#8 profiles.json, Personal paired at the build's address] Restore: draft=\(restored.draft.debugDescription) line=\(restored.line) toggle=\(registration.enabled ? "on" : "off") old installation still held=\(!withdrawn)"
    )
    #expect(restored.draft == "Second held note" && restored.line == "To Personal")
    #expect(withdrawn, "The build's coordinator keeps alerting this device")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// A `profiles.json` an earlier build wrote once its migrated profile paired, which recorded no
/// address for the messages held in that profile's directory. The profile may have been edited
/// before it paired, so Restore asks, the note does not claim to know the address, and a Send to
/// the one chosen leaves the message held.
@MainActor @Test(.timeLimit(.minutes(1)))
func heldMessagesWithNoRecordedAddressAskWithoutClaimingNothingIsPairedThere() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if15-b2-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let used = FixtureCoordinator()
  let (listener, port) = try await listen(used)
  defer { listener.cancel() }
  let migrated = ProfileID()
  let file = root.appending(path: "Agent/profiles.json")
  try FileManager.default.createDirectory(
    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(
    """
    {"withdrawals":[],"profiles":[{"id":"\(migrated)","name":"Coordinator",\
    "address":{"host":"100.64.1.2","port":43187},"pin":"\(used.id.uuid.uuidString)"}]}
    """.utf8
  ).write(to: file)
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: "Second held note")
    ]),
    to: root.appending(path: "Agent/Profiles/\(migrated)/Legacy/pending.json"))
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await used.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("connected") { chat.connection == .connected }
    try await eventually("held row") { chat.held.count == 1 }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let withoutChoice = chat.draft
    let offered = chat.heldChoices.map(\.name.description)
    let note = chat.heldNote(held)
    await chat.restoreHeld(held, for: migrated)
    await chat.send()
    let delivered = try await settles { await submitted(used) == ["Second held note"] }
    print(
      "IF15-U4-B2[#8 profiles.json, the migrated profile paired] Restore without a choice: draft=\(withoutChoice.debugDescription) offered=\(offered) note=\(note.debugDescription) after choosing and Send: delivered=\(delivered) still held=\(chat.held.map(\.item.text))"
    )
    #expect(withoutChoice.isEmpty && offered == ["Coordinator"])
    #expect(
      note
        == "This phone did not record which coordinator it was queued for, so it stays held after you send it."
    )
    #expect(delivered && chat.held.map(\.item.text) == ["Second held note"])
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// This build ran, and Work paired at the single-address build's address. Then the single-address
/// build ran again, at port 4002, and queued another message, and this build ran again. That
/// migration keys its own queue to 4002 and leaves the earlier one as it was. Each held message goes
/// to the coordinator at the address it was queued for: Personal when it is saved at 4002, and Work
/// for the first build's message after the second migration's profile pairs at 4002 and is named
/// Personal.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["saved as Personal", "new address"])
func aSecondMigrationAddressesEachHeldMessageToTheCoordinatorAtItsOwnAddress(_ when: String)
  async throws
{
  let install = try await LegacyInstall()
  defer { install.remove() }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let routes = Routes([install.address.port: workPort, 4002: personalPort])
  let transport = CoordinatorTransport { address in
    guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
    return LineConnection(
      connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
  }
  let second = try CoordinatorAddress(host: "100.64.1.2", port: 4002)
  do {
    let first = Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches, transport: transport)
    await first.setActive(true)
    let migrated = try #require(first.profiles.first)
    try await eventually("Work paired at the build's address") {
      first.chat.snapshots[migrated.id]?.connection == .connected
    }
    try await first.update(migrated.id, name: TagName("Work"), address: install.address)
    if when == "saved as Personal" {
      try await first.add(name: TagName("Personal"), address: second)
    }
    try await eventually("held rows") { first.chat.held.count == 2 }
    if when == "saved as Personal" {
      for message in first.chat.held { await first.chat.discardHeld(message) }
    }
    await first.setActive(false)
  }
  install.defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  install.defaults.set("4002", forKey: "coordinatorPort")
  install.defaults.set(UUID().uuidString, forKey: "notificationInstallationID")
  let outbox = LegacyInstall.outbox(install.support, "100.64.1.2", 4002)
  try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
  try JSONEncoder().encode([
    NativeRequestSubmit(
      inputId: UUID().uuidString, mode: .followUp, text: "Invented note queued for 4002")
  ]).write(to: outbox.appending(path: "pending.json"))
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches, transport: transport)
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    if when == "new address" {
      let added = try #require(coordinators.profiles.last)
      try await coordinators.update(added.id, name: TagName("Personal"), address: second)
    }
    try await eventually("held rows") { chat.held.count == (when == "new address" ? 3 : 1) }
    let held = try #require(
      when == "new address"
        ? chat.held.first { $0.item.text == "Second held note" } : chat.held.first)
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, line: chat.recipientLine)
    await chat.send()
    _ = try await settles { await submitted(work) + submitted(personal) != [] }
    print(
      "IF15-U4-C[\(when)] saved=\(coordinators.profiles.map { "\($0.name)@\($0.address.port)" }) Restore: draft=\(restored.draft.debugDescription) line=\(restored.line) after Send: Work's coordinator got=\(await submitted(work)) Personal's coordinator got=\(await submitted(personal))"
    )
    let atWork = await submitted(work)
    let atPersonal = await submitted(personal)
    if when == "new address" {
      #expect(restored.line == "To Work")
      #expect(atWork == ["Second held note"] && atPersonal.isEmpty)
    } else {
      #expect(restored.line == "To Personal")
      #expect(atPersonal == ["Invented note queued for 4002"] && atWork.isEmpty)
    }
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// A `profiles.json` the build before this one wrote: one `origin`, already paired with Work's
/// coordinator, for the messages held in the migrated profile's `Legacy` folder. A launch that
/// stopped after saving the queue and before moving its folder resumes the move. The held message
/// goes to Work, and Remove counts and deletes it with Work.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["as written", "after an adoption stopped"])
func aPreviousBuildsOriginStaysWithTheMessagesItHeld(_ state: String) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if15-origin-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let (listener, port) = try await listen(work)
  defer { listener.cancel() }
  var profile = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4001))
  profile.pin = work.id
  let migrated = profile.id
  let file = root.appending(path: "Agent/profiles.json")
  let built = try CoordinatorAddress(host: "100.64.1.2")
  if state == "as written" {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(
      """
      {"withdrawals":[],"profiles":[{"id":"\(migrated)","name":"Work",\
      "address":{"host":"100.64.1.2","port":4001},"pin":"\(work.id.uuid.uuidString)"}],\
      "origin":{"address":{"host":"100.64.1.2","port":43187},\
      "coordinator":"\(work.id.uuid.uuidString)"}}
      """.utf8
    ).write(to: file)
  } else {
    let queue = HeldQueue(
      adopting: migrated, address: built, coordinator: work.id, installation: nil)
    try writePrivately(
      JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [profile], held: [queue])),
      to: file)
  }
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: "Second held note")
    ]),
    to: ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy.appending(
      path: "pending.json"))
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Work connected") { chat.connection == .connected }
    try await eventually("held row") { chat.held.count == 1 }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, recipient: chat.recipient)
    chat.draft = ""
    let queue = try #require(coordinators.queues.first)
    let moved = FileManager.default.fileExists(
      atPath: queue.folder(applicationSupport: root).appending(path: "pending.json").path)
    let left = FileManager.default.fileExists(
      atPath: ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy.path)
    let confirmation = coordinators.removalMessage(migrated)
    try await coordinators.remove(migrated)
    print(
      "IF15-U4-F[\(state)] queues=\(coordinators.queues.count) Restore: draft=\(restored.draft.debugDescription) to Work=\(restored.recipient == migrated) folder moved=\(moved) left in the profile=\(left) | Remove Work? \(confirmation) | after Remove: held=\(chat.held.map(\.item.text)) folder kept=\(FileManager.default.fileExists(atPath: queue.folder(applicationSupport: root).path))"
    )
    #expect(queue.address == built && queue.coordinator == work.id)
    #expect(restored.draft == "Second held note" && restored.recipient == migrated)
    #expect(moved && !left, "The held queue's folder still depends on the profile's")
    #expect(confirmation == "This deletes 1 queued message on this phone.")
    #expect(chat.held.isEmpty && coordinators.queues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queue.folder(applicationSupport: root).path))
  } catch {
    await stop()
    throw error
  }
  await stop()
}
