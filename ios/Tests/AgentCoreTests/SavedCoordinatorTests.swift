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
    struct Saved: Decodable { let profiles: [CoordinatorProfile] }
    #expect(try JSONDecoder().decode(Saved.self, from: savedProfiles()).profiles == profiles)
    #expect(try HeldQueue.all(applicationSupport: support) == held, "The queue records itself")
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
    Coordinators.MigrationStep.queueNamed, .profileSaved, .queueRecorded, .quarantined,
    .markerRemoved,
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

private let stoppedThenRelaunched: [(step: Coordinators.MigrationStep, host: String)] = [
  (.queueNamed, "100.64.1.2"), (.profileSaved, "100.64.1.2"), (.queueRecorded, "100.64.1.2"),
  (.quarantined, "100.64.1.2"), (.markerRemoved, "100.64.1.2"), (.queueNamed, "100.64.1.3"),
  (.profileSaved, "100.64.1.3"), (.queueRecorded, "100.64.1.3"), (.quarantined, "100.64.1.3"),
  (.markerRemoved, "100.64.1.3"),
]

/// A migration stops after a step, then the single-address build runs again and queues another
/// message, at its address or at another one it was pointed at. The resume finishes only the move
/// it started, from its queue's own address, and holds what the build queued after that move in a
/// queue of its own, also when the resume itself stops after each step in turn. Every message is
/// held once, in a queue keyed to the address it was queued for.
@MainActor @Test(arguments: stoppedThenRelaunched, [false, true])
func theSingleAddressBuildQueuingAgainBeforeAMigrationResumesGetsAQueueOfItsOwn(
  _ stopped: (step: Coordinators.MigrationStep, host: String), _ resumeStops: Bool
) async throws {
  let (step, host) = stopped
  let install = try await LegacyInstall()
  defer { install.remove() }
  func migrate(stoppingAfter stop: Coordinators.MigrationStep) {
    #expect(throws: Crash.self) {
      try Coordinators.migrate(
        defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
        crash: { if $0 == stop { throw Crash() } })
    }
  }
  migrate(stoppingAfter: step)
  let relaunched = try CoordinatorAddress(host: host)
  let outbox = LegacyInstall.outbox(install.support, relaunched.host, relaunched.port)
  let file = outbox.appending(path: "pending.json")
  let before =
    (try? JSONDecoder().decode([NativeRequestSubmit].self, from: Data(contentsOf: file))) ?? []
  let again = NativeRequestSubmit(
    inputId: UUID().uuidString, mode: .followUp, text: "New note from another launch")
  try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
  try JSONEncoder().encode(before + [again]).write(to: file)
  install.defaults.set(host, forKey: "coordinatorAddress")
  if resumeStops {
    for stop in [
      Coordinators.MigrationStep.queueNamed, .profileSaved, .queueRecorded, .quarantined,
      .markerRemoved,
    ] {
      migrate(stoppingAfter: stop)
    }
  }
  let resumed = try Coordinators.migrate(
    defaults: install.defaults, applicationSupport: install.support, caches: install.caches)
  func queued(_ text: String, for address: CoordinatorAddress?) -> String {
    "\(text) for \(address.map { "\($0.host):\($0.port)" } ?? "no address")"
  }
  var held: [String] = []
  for queue in resumed.held {
    held += try await LegacyHold(queue.folder(applicationSupport: install.support)).items().map {
      queued($0.text, for: queue.address)
    }
  }
  let left = Set([install.oldOutbox.path, outbox.path]).filter {
    FileManager.default.fileExists(atPath: $0)
  }
  print(
    "IF16-T1[stopped after \(step), relaunched at \(host), resume stops=\(resumeStops)] queues=\(resumed.held.count) held=\(held) outboxes left=\(left.count) marker=\(install.defaults.string(forKey: "coordinatorAddress") ?? "nil")"
  )
  var expected = install.queued.map { queued($0.text, for: install.address) }
  expected.append(queued(again.text, for: relaunched))
  #expect(held.sorted() == expected.sorted(), "Each message is held once, for its own address")
  #expect(left.isEmpty, "An outbox the build left is in no listed queue")
  let first = try #require(resumed.held.first)
  #expect(first.address == install.address && first.coordinator == nil)
  #expect(first.installation?.description == install.installation)
  let saved = resumed.profiles.map { "\($0.address.host):\($0.address.port)" }
  #expect(resumed.profiles.last?.address == relaunched && Set(saved).count == saved.count)
  #expect(resumed.profiles.allSatisfy { [install.address, relaunched].contains($0.address) })
  #expect(install.defaults.object(forKey: "coordinatorAddress") == nil)
  #expect(
    install.defaults.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("migrating") })
  let later = try Coordinators.migrate(
    defaults: install.defaults, applicationSupport: install.support, caches: install.caches)
  #expect(later == resumed, "A later launch changes nothing")
}

/// The single-address build is installed again after a migration and used at another address that
/// gets the same default name, a tailnet IP's or a MagicDNS label already 32 characters long. The
/// second migration names its profile so that no two saved names match ignoring case, and keeps the
/// first one's name. Once both are paired, each name's `@` tag addresses that coordinator alone.
@MainActor
@Test(
  arguments: [
    ("100.64.1.2", "100.64.1.3"),
    (
      "abcdefghijklmnopqrstuvwxyz012345.one.example-tailnet.ts.net",
      "abcdefghijklmnopqrstuvwxyz012345.two.example-tailnet.ts.net"
    ),
  ])
func aSecondMigrationNamesItsCoordinatorSoEachTagAddressesOne(_ first: String, _ second: String)
  throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let suite = "if16-names-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: root)
  }
  defaults.set(first, forKey: "coordinatorAddress")
  let before = try Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root)
  defaults.set(second, forKey: "coordinatorAddress")
  let after = try Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root)
  var profiles = after.profiles
  for profile in after.profiles {
    _ = try CoordinatorProfile.admit(CoordinatorID(UUID()), for: profile.id, in: &profiles)
  }
  let peers = profiles.map {
    Addressing.Coordinator(id: $0.id, name: $0.name.description, paired: true, connected: true)
  }
  let routed = profiles.map {
    Addressing.parse("@\($0.name) invented note", hasAttachments: false, chip: nil, among: peers)
  }
  print(
    "IF16-T2[\(first), then \(second)] names=\(after.profiles.map(\.name.description)) routed=\(routed)"
  )
  #expect(after.profiles.count == 2 && after.profiles.first == before.profiles.first)
  #expect(Set(after.profiles.map { $0.name.description.lowercased() }).count == 2)
  #expect(try after.profiles.allSatisfy { try TagName($0.name.description) == $0.name })
  #expect(routed == profiles.map { .to([$0.id], body: "invented note") })
}

/// This build migrated the single-address build's first launch at 100.64.1.2 as Coordinator. Then
/// #9 migrated a second launch at 100.64.1.3, which saves another Coordinator, after the user may
/// have saved Coordinator-2. This build, launched again, keeps the first name and every name no
/// other one has, and gives the later Coordinator the first free one, so each `@` tag addresses one
/// coordinator.
@MainActor @Test(arguments: [false, true])
func aDuplicateNameAnEarlierBuildSavedGetsTheFirstFreeOne(coordinator2Saved: Bool) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if17-names-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  func queue(_ text: String, in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]),
      to: folder.appending(path: "pending.json"))
  }
  defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  try queue("First launch's note", in: LegacyInstall.outbox(root, "100.64.1.2", 43187))
  let migrated = try #require(
    Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root).profiles.first)
  let saved = try CoordinatorProfile(
    name: TagName("Coordinator-2"), address: .init(host: "100.64.1.4"))
  let second = try CoordinatorProfile(
    name: TagName("Coordinator"), address: .init(host: "100.64.1.3"))
  struct WrittenByNine: Encodable {
    struct Origin: Encodable {
      let address: CoordinatorAddress
      let installation: String
    }
    let profiles: [CoordinatorProfile]
    let withdrawals: [PendingWithdrawal]
    let origin: Origin
  }
  try writePrivately(
    JSONEncoder().encode(
      WrittenByNine(
        profiles: [migrated] + (coordinator2Saved ? [saved] : []) + [second], withdrawals: [],
        origin: .init(address: second.address, installation: UUID().uuidString))),
    to: root.appending(path: "Agent/profiles.json"))
  try queue(
    "Second launch's note",
    in: ProfileDirectory(second.id, applicationSupport: root, caches: root).legacy)
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  let shown = try await settles { coordinators.chat.held.count == 2 }
  let names = coordinators.profiles.map(\.name.description)
  struct Saved: Decodable { let profiles: [CoordinatorProfile] }
  let written = try JSONDecoder().decode(
    Saved.self, from: Data(contentsOf: root.appending(path: "Agent/profiles.json")))
  var paired = coordinators.profiles
  for profile in coordinators.profiles {
    _ = try CoordinatorProfile.admit(CoordinatorID(UUID()), for: profile.id, in: &paired)
  }
  let peers = paired.map {
    Addressing.Coordinator(id: $0.id, name: $0.name.description, paired: true, connected: true)
  }
  let routed = paired.map {
    Addressing.parse("@\($0.name) invented note", hasAttachments: false, chip: nil, among: peers)
  }
  print(
    "IF17-S3[Coordinator-2 saved=\(coordinator2Saved)] names=\(names) saved=\(written.profiles.map(\.name.description)) held=\(coordinators.chat.held.map(\.item.text)) routed=\(routed)"
  )
  #expect(
    names
      == (coordinator2Saved
        ? ["Coordinator", "Coordinator-2", "Coordinator-3"] : ["Coordinator", "Coordinator-2"]))
  #expect(written.profiles == coordinators.profiles, "The new names are not saved")
  #expect(coordinators.profiles.map(\.id) == written.profiles.map(\.id))
  #expect(routed == paired.map { .to([$0.id], body: "invented note") })
  #expect(shown, "A held note is not shown")
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
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [work, personal])),
    to: root.appending(path: "Agent/profiles.json"))
  for queue in [unreadable, readable] {
    try queue.record(in: queue.folder(applicationSupport: root))
  }
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
  let confirmation = coordinators.removal(work.id).message
  try await coordinators.remove(coordinators.removal(work.id))
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
    let queue = try HeldQueue.all(applicationSupport: install.support).first
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
    Coordinators.MigrationStep.queueNamed, .profileSaved, .queueRecorded, .quarantined,
    .markerRemoved,
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

/// The app, active, with Work added at `fixture`.
@MainActor private func withWorkAdded(
  at fixture: FixtureCoordinator, _ body: (Coordinators, ProfileID) async throws -> Void
) async throws {
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "work-added-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  await coordinators.setActive(true)
  do {
    try await coordinators.add(
      name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2"))
    try await body(coordinators, try #require(coordinators.profiles.first?.id))
  } catch {
    await coordinators.setActive(false)
    await fixture.stop()
    throw error
  }
  await coordinators.setActive(false)
  await fixture.stop()
}

private func observes(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .observe = $0 { true } else { false } }.count
}

/// Round 19's probe of this app against a `0d8daa0` coordinator, which answers `identify` and then
/// closes on the observe's `source_status`. Add only asks who answers, so it saves the coordinator.
/// The lane then says to update it, keeps retrying, and connects once it is updated.
@MainActor @Test(.timeLimit(.minutes(1)))
func aCoordinatorThatIdentifiesThenClosesOnTheObserveSaysUpdateIt() async throws {
  let fixture = FixtureCoordinator()
  await fixture.leaveObserveUnanswered(.closedOnSourceStatus)
  try await withWorkAdded(at: fixture) { coordinators, work in
    let chat = coordinators.chat
    #expect(coordinators.profiles.first?.pin == fixture.id)
    chat.draft = "Invented note for the old coordinator"
    let found = try await settles { chat.laneError(work) != nil }
    print(
      "OLDCOORD lane=\(chat.snapshots[work].map { "\($0.connection)" } ?? "-") laneError=\(chat.laneError(work) ?? "nil") composerError=\(chat.error ?? "nil") canSend=\(chat.canSend) observes=\(await observes(fixture))"
    )
    #expect(found, "The lane reconnects with no reason")
    #expect(chat.laneError(work) == "Update the coordinator to use it with this app.")
    #expect(chat.error == "Update the coordinator to use it with this app.")
    #expect(chat.snapshots[work]?.connection == .reconnecting)
    #expect(!chat.canSend)
    let attempts = await observes(fixture)
    try await eventually("a retry after the backoff") { await observes(fixture) > attempts }
    #expect(chat.laneError(work) == "Update the coordinator to use it with this app.")
    await fixture.leaveObserveUnanswered(nil)
    try await eventually("connected once updated") {
      chat.snapshots[work]?.connection == .connected
    }
    #expect(chat.laneError(work) == nil)
    #expect(chat.draft == "Invented note for the old coordinator")
    #expect(await fixture.count() == 0)
  }
}

/// A socket the network resets before the first reply is a drop, not an old coordinator.
@MainActor @Test(.timeLimit(.minutes(1)))
func aSocketResetBeforeTheFirstReplyOnlyReconnects() async throws {
  let fixture = FixtureCoordinator()
  await fixture.leaveObserveUnanswered(.reset)
  try await withWorkAdded(at: fixture) { coordinators, work in
    let chat = coordinators.chat
    try await eventually("a retry after the backoff") { await observes(fixture) >= 2 }
    #expect(chat.snapshots[work]?.connection == .reconnecting)
    #expect(chat.laneError(work) == nil)
    #expect(chat.error == nil)
  }
}

/// A lost action reply makes the phone close its observer, here while that observer waits for its
/// first reply on a stalled network. The phone closed it, not the coordinator, so the lane only
/// reconnects.
@MainActor @Test(.timeLimit(.minutes(1)))
func anObserverThePhoneClosesBeforeItsFirstReplyOnlyReconnects() async throws {
  let fixture = FixtureCoordinator()
  try await withWorkAdded(at: fixture) { coordinators, work in
    let chat = coordinators.chat
    try await eventually("connected") { chat.snapshots[work]?.connection == .connected }
    await fixture.loseInputAcknowledgements()
    await fixture.holdNextSubmitReply()
    chat.draft = "Invented note whose reply is held"
    await chat.send()
    try await eventually("the held submit") { await fixture.count() == 1 }
    await fixture.leaveObserveUnanswered(.silent)
    chat.draft = "Invented note whose reply is lost"
    await chat.send()
    try await eventually("an observer waiting for its first reply") {
      await observes(fixture) == 2
    }
    await fixture.releaseSubmitReply()
    try await eventually("a retry after the phone closed it") { await observes(fixture) == 3 }
    #expect(chat.snapshots[work]?.connection == .reconnecting)
    #expect(chat.laneError(work) == nil)
  }
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
    coordinators.removal(profile.id).message
      == "This deletes 3 queued messages on this phone.")
  let agent = install.support.appending(path: "Agent")
  let directory = install.directory(profile)
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
  await #expect(throws: (any Error).self) {
    try await coordinators.remove(coordinators.removal(profile.id))
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
  #expect(
    FileManager.default.fileExists(atPath: directory.root.path), "Unsaved removal deletes nothing")
  #expect(coordinators.profiles.map(\.id) == [profile.id])
  try await coordinators.remove(coordinators.removal(profile.id))
  #expect(coordinators.profiles.isEmpty)
  struct Saved: Decodable { let profiles: [CoordinatorProfile] }
  #expect(try JSONDecoder().decode(Saved.self, from: install.savedProfiles()).profiles.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: directory.root.path))
  #expect(!FileManager.default.fileExists(atPath: directory.cache.path))
  #expect(coordinators.queues.isEmpty && chat.held.isEmpty)
  let heldLeft =
    (try? FileManager.default.contentsOfDirectory(
      atPath: install.support.appending(path: "Agent/HeldQueues").path)) ?? []
  #expect(heldLeft.isEmpty, "The messages held for the removed coordinator stay on this phone")
  #expect(
    await fixture.notificationControls().contains(
      .unregister(.init(installationId: "\(profile.id)"))), "Alerts are withdrawn")
  await coordinators.setActive(false)
  await fixture.stop()
}

/// Removing the coordinator the single-address build's queue belongs to leaves no record of that
/// queue, whether or not its coordinator confirms the alert withdrawal during Remove. When the
/// queue's folder cannot be deleted, the next launch deletes it, so the messages Remove counted
/// never come back.
@MainActor
@Test(
  .timeLimit(.minutes(1)), arguments: [(true, false), (true, true), (false, false), (false, true)])
func removeNeverSavesTheHeldQueuesItDeletes(confirmed: Bool, folderLocked: Bool) async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: confirmed
        ? NotificationRegistration(
          enabled: false, permission: { true }, register: {}, save: { _ in }) : nil,
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
      transport: loopback(port))
  }
  let coordinators = launch()
  let profile = try #require(coordinators.profiles.first)
  await coordinators.setActive(true)
  try await eventually("paired and connected") { coordinators.chat.connection == .connected }
  try await eventually("held rows") { coordinators.chat.held.count == 2 }
  if confirmed {
    try await eventually("alerts asked over the profile's session") {
      await fixture.notificationControls().contains(
        .status(.init(installationId: "\(profile.id)")))
    }
  }
  let folder = try #require(coordinators.queues.first).folder(applicationSupport: install.support)
  let files = FileManager.default
  if folderLocked {
    try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
  }
  var refused = false
  do { try await coordinators.remove(coordinators.removal(profile.id)) } catch { refused = true }
  let heldFolders = install.support.appending(path: "Agent/HeldQueues")
  func folders() -> [URL] {
    (try? files.contentsOfDirectory(at: heldFolders, includingPropertiesForKeys: nil)) ?? []
  }
  for entry in folders() {
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: entry.path)
  }
  await coordinators.setActive(false)
  struct Saved: Decodable {
    let profiles: [CoordinatorProfile]
    let withdrawals: [PendingWithdrawal]
  }
  let saved = try JSONDecoder().decode(Saved.self, from: install.savedProfiles())
  let recorded = try HeldQueue.all(applicationSupport: install.support)
  let relaunched = launch()
  print(
    "IF16-T3-A[confirmed=\(confirmed) folder locked=\(folderLocked)] Remove refused=\(refused) profiles.json: profiles=\(saved.profiles.count) queues recorded=\(recorded.count) | after a relaunch: queues=\(relaunched.queues.count) Held folders=\(folders().count)"
  )
  #expect(
    saved.withdrawals.contains { $0.installation == InstallationID(profile.id) } == !confirmed)
  #expect(refused == folderLocked)
  #expect(saved.profiles.isEmpty && recorded.isEmpty, "A queue Remove deleted is still recorded")
  #expect(relaunched.queues.isEmpty && folders().isEmpty, "Messages Remove deleted are held again")
  await fixture.stop()
}

/// What is on disk is all a relaunch sees, so after each change to saved coordinators it holds what
/// the app holds: the migrated profile edited to Work's address, Personal added at the build's
/// address, which takes the build's queue, then each removed while its coordinator confirms the
/// alert withdrawal.
@MainActor @Test(.timeLimit(.minutes(1)))
func profilesJSONListsWhatTheAppHoldsAfterEveryChange() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let registration = NotificationRegistration(
    enabled: false, permission: { true }, register: {}, save: { _ in })
  try await withTheOldAddressSilent(install, registration: registration) {
    coordinators, migrated, used, work, bringBack in
    var steps: [String] = []
    @MainActor func record(_ step: String) throws {
      let saved = try JSONDecoder().decode(
        Coordinators.SavedProfiles.self, from: install.savedProfiles())
      let held = try HeldQueue.all(applicationSupport: install.support)
      let same = saved.profiles == coordinators.profiles && held == coordinators.queues
      steps.append(
        "\(step): \(same ? "same" : "differs") | saved \(saved.profiles.map(\.name.description)) with \(held.count) queues | the app \(coordinators.profiles.map(\.name.description)) with \(coordinators.queues.count) queues"
      )
    }
    func alertsAsked(_ id: ProfileID, at fixture: FixtureCoordinator) async throws {
      try await eventually("alerts asked over \(id)'s session") {
        await fixture.notificationControls().contains(.status(.init(installationId: "\(id)")))
      }
    }
    try record("launch")
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try record("the migrated profile edited to Work's address")
    await bringBack()
    try await coordinators.add(name: TagName("Personal"), address: install.address)
    try record("Personal added at the build's address")
    let personal = try #require(coordinators.profiles.last)
    #expect(coordinators.queues.map(\.coordinator) == [personal.pin])
    try await alertsAsked(personal.id, at: used)
    try await alertsAsked(migrated.id, at: work)
    try await coordinators.remove(coordinators.removal(personal.id))
    try record("Personal removed")
    try await coordinators.remove(coordinators.removal(migrated.id))
    try record("Work removed")
    print("IF16-T3-B\n" + steps.joined(separator: "\n"))
    #expect(steps.allSatisfy { $0.contains(": same |") }, "The disk differs from the app")
  }
}

/// A Remove that stopped after saving leaves its files. The next launch deletes every profile
/// directory `profiles.json` does not list. It deletes no held folder no Remove marked: one that
/// records no queue, as a build that kept its records elsewhere left it, holds messages whose
/// address is unknown, so they show and Restore asks.
@MainActor @Test
func launchDeletesTheFilesOfEveryProfileThatIsNoLongerSavedAndKeepsEveryHeldFolder() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let caches = root.appending(path: "Caches")
  let suite = "launch-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let saved = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let recorded = HeldQueue(address: saved.address, installation: nil)
  let unrecorded = HeldQueue(address: saved.address, installation: nil)
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [saved])),
    to: root.appending(path: "Agent/profiles.json"))
  try recorded.record(in: recorded.folder(applicationSupport: root))
  for (queue, text) in [
    (recorded, "Invented recorded note"), (unrecorded, "Invented unrecorded note"),
  ] {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
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
  let chat = coordinators.chat
  let shown = try await settles { chat.held.count == 2 }
  let unknown = chat.held.first { $0.queue == unrecorded.id }.map(chat.heldNote)
  print(
    "IF16-T4[a held folder no Remove marked] queues=\(coordinators.queues.map { $0.address == nil ? "unknown" : "\($0.address!.host)" }) held=\(chat.held.map(\.item.text)) note=\(unknown ?? "nil")"
  )
  #expect(FileManager.default.fileExists(atPath: recorded.folder(applicationSupport: root).path))
  #expect(
    FileManager.default.fileExists(atPath: unrecorded.folder(applicationSupport: root).path),
    "Launch deleted a held folder no Remove marked")
  #expect(shown && coordinators.queues.map(\.id) == [recorded.id, unrecorded.id])
  #expect(coordinators.queues.map(\.address) == [saved.address, nil])
  #expect(unknown?.hasPrefix("This phone did not record which coordinator") == true)
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
    let confirmation = coordinators.removal(work).message
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
  try queue.record(in: queue.folder(applicationSupport: root))
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  try await coordinators.add(name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2"))
  let id = try #require(coordinators.profiles.first?.id)
  let directory = ProfileDirectory(id, applicationSupport: root, caches: root)
  let unreadable = "Queued messages on this phone could not be read. Removing deletes them."
  #expect(coordinators.removal(id).message == "No queued messages are on this phone.")
  try writePrivately(Data("not an outbox".utf8), to: directory.outbox)
  let outbox = coordinators.removal(id).message
  #expect(outbox == unreadable, "An unreadable outbox")
  try FileManager.default.removeItem(at: directory.outbox)
  let held = queue.folder(applicationSupport: root).appending(path: "pending.json")
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Invented held note")
    ]), to: held)
  try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: held.path)
  let hold = coordinators.removal(id).message
  #expect(hold == unreadable, "An unreadable hold")
  try await coordinators.remove(coordinators.removal(id))
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
    try await coordinators.remove(
      coordinators.removal(try #require(coordinators.profiles.first).id))
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
      #expect(captures == 1 && files == ["Feedback.png"])
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
    let confirmation = coordinators.removal(migrated.id).message
    try await coordinators.remove(coordinators.removal(migrated.id))
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

/// A held message queued for 100.64.1.2:43187 that this phone names no owner for, while Personal
/// answers there: its queue is bound to Work, which is no longer saved; or Work and Personal are
/// both paired there, so launch cannot tell whose it is; or only Personal is saved, at 4002.
/// Restore asks, its note says which of these it is and says nobody is paired at that address
/// only when nobody is, and a Send to Personal leaves the message held.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    (
      "bound to Work, no longer saved",
      "It was queued for a coordinator at 100.64.1.2:43187 that is no longer saved, so it stays held after you send it."
    ),
    (
      "Work and Personal paired there",
      "It was queued for the coordinator at 100.64.1.2:43187. This phone cannot tell which saved coordinator that is, so it stays held after you send it."
    ),
    (
      "nobody paired there",
      "It was queued for the coordinator at 100.64.1.2:43187. No saved coordinator is paired there, so it stays held after you send it."
    ),
  ])
func restoresNoteSaysNobodyIsPairedAtTheAddressOnlyWhenNobodyIs(
  _ state: String, _ expected: String
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r21r-note-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let personal = FixtureCoordinator()
  let (listener, port) = try await listen(personal)
  defer { listener.cancel() }
  let work = CoordinatorID(UUID())
  let queued = try CoordinatorAddress(host: "100.64.1.2")
  var profiles = [
    CoordinatorProfile(
      name: try TagName("Personal"),
      address: state == "nobody paired there"
        ? try CoordinatorAddress(host: "100.64.1.2", port: 4002) : queued)
  ]
  profiles[0].pin = personal.id
  if state == "Work and Personal paired there" {
    var both = CoordinatorProfile(name: try TagName("Work"), address: queued)
    both.pin = work
    profiles.append(both)
  }
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: profiles)),
    to: root.appending(path: "Agent/profiles.json"))
  let queue = HeldQueue(
    address: queued, coordinator: state == "bound to Work, no longer saved" ? work : nil,
    installation: nil)
  let note = "Invented note queued for 100.64.1.2:43187"
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: note)
    ]), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
  try queue.record(in: queue.folder(applicationSupport: root))
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(port))
  let chat = coordinators.chat
  let chosen = try #require(coordinators.profiles.first { $0.pin == personal.id }).id
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Personal connected and the message held") {
      chat.snapshots[chosen]?.connection == .connected && chat.held.count == 1
    }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let asked = chat.owner(held) == nil && chat.draft.isEmpty
    let shown = chat.heldNote(held)
    await chat.restoreHeld(held, for: chosen)
    _ = try await settles { chat.canSend }
    await chat.send()
    let delivered = try await settles { await submitted(personal) == [note] }
    print(
      "R21-note[\(state)] saved=\(coordinators.profiles.map { "\($0.name)@\($0.address.port)" }) Restore asked=\(asked) offered=\(chat.heldChoices.map(\.name.description)) note=\(shown.debugDescription) after choosing Personal and Send: delivered=\(delivered) still held=\(chat.held.count)"
    )
    #expect(asked, "Restore did not ask who gets a message with no owner")
    #expect(shown == expected)
    #expect(
      delivered && chat.held.map(\.item.text) == [note], "The copy sent to Personal was not kept")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Personal is paired at 100.64.1.2:4002, and "Coordinator" is unpaired. Restore on a message held
/// for 43187 asks who gets it. While it asks, the pairing retry pairs "Coordinator" with Work,
/// which makes it the message's owner: at 43187, which binds the message's queue to Work, or at
/// 4005 when the queue was already bound to Work. The question ends then, since its note says
/// nobody owns the message, and it does not come back once that owner is removed.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["pairs at the queue's address", "queue already Work's"])
func restoresQuestionEndsOnceTheHeldMessageGainsAnOwner(_ path: String) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r22d-asking-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let queued = try CoordinatorAddress(host: "100.64.1.2")
  let bound = path == "queue already Work's"
  let migrated = CoordinatorProfile(
    name: try TagName("Coordinator"),
    address: bound ? try CoordinatorAddress(host: "100.64.1.2", port: 4005) : queued)
  var paired = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4002))
  paired.pin = personal.id
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [migrated, paired])),
    to: root.appending(path: "Agent/profiles.json"))
  let queue = HeldQueue(address: queued, coordinator: bound ? work.id : nil, installation: nil)
  let note = "Invented note queued for 100.64.1.2:43187"
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: note)
    ]), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
  try queue.record(in: queue.folder(applicationSupport: root))
  let routes = Routes([4002: personalPort])
  let transport = CoordinatorTransport { address in
    guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
    return LineConnection(
      connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
  }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: transport)
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Personal connected and the message held") {
      chat.snapshots[paired.id]?.connection == .connected && chat.held.count == 1
    }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let askedFirst = chat.asking?.id == held.id
    await routes.set([4002: personalPort, migrated.address.port: workPort])
    try await eventually("Coordinator paired with Work and owns the message") {
      chat.owner(held) == migrated.id
    }
    let askedOwned = chat.asking?.id == held.id
    try await coordinators.remove(
      Coordinators.Removal(profile: migrated.id, message: "", held: []))
    let askedAfterRemove = chat.asking?.id == held.id
    print(
      "R22D-asking[\(path)] asked before pairing=\(askedFirst) after Coordinator paired=\(askedOwned) after it was removed=\(askedAfterRemove) owner now=\(chat.owner(held).map { "\($0)" } ?? "nobody") still held=\(chat.held.map(\.item.text))"
    )
    #expect(askedFirst, "Restore did not ask who gets a message with no owner")
    #expect(!askedOwned, "Restore still asks after the message gained an owner")
    #expect(
      chat.owner(held) == nil && chat.held.count == 1 && !askedAfterRemove,
      "Restore asks again once the message's owner is removed")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Restore asks who gets a message held for 100.64.1.2:43187, and offers Personal, paired at 4002.
/// Before the user answers, "Coordinator" pairs with Work at 43187, which makes Work the message's
/// owner. The user's tap on Personal then arrives. It restores nothing, so a Send gives Personal
/// nothing, and Restore then addresses the message to Work.
@MainActor @Test(.timeLimit(.minutes(1)))
func aChoiceMadeBeforeTheHeldMessageGainedAnOwnerRestoresNothing() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r22f-stale-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let queued = try CoordinatorAddress(host: "100.64.1.2")
  let migrated = CoordinatorProfile(name: try TagName("Coordinator"), address: queued)
  var paired = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.2", port: 4002))
  paired.pin = personal.id
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [migrated, paired])),
    to: root.appending(path: "Agent/profiles.json"))
  let queue = HeldQueue(address: queued, coordinator: nil, installation: nil)
  let note = "Invented note queued for 100.64.1.2:43187"
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: note)
    ]), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
  try queue.record(in: queue.folder(applicationSupport: root))
  let routes = Routes([4002: personalPort])
  let transport = CoordinatorTransport { address in
    guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
    return LineConnection(
      connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
  }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: transport)
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("Personal connected and the message held") {
      chat.snapshots[paired.id]?.connection == .connected && chat.held.count == 1
    }
    let held = try #require(chat.held.first)
    await chat.restoreHeld(held)
    let offered = chat.asking?.id == held.id && chat.heldChoices.map(\.id) == [paired.id]
    await routes.set([4002: personalPort, 43187: workPort])
    try await eventually("Coordinator paired with Work and owns the message") {
      chat.owner(held) == migrated.id && chat.snapshots[migrated.id]?.connection == .connected
    }
    await chat.restoreHeld(held, for: paired.id)
    let staleDraft = chat.draft
    await chat.send()
    await chat.restoreHeld(held)
    let toOwner = chat.draft == note && chat.recipient == migrated.id
    _ = try await settles { chat.canSend }
    await chat.send()
    let workGot = try await settles { await submitted(work) == [note] }
    let personalGot = await submitted(personal)
    print(
      "R22F-stale offered Personal=\(offered) draft after the stale tap=\(staleDraft.debugDescription) Restore again to Coordinator=\(toOwner) | Work got it=\(workGot) Personal got=\(personalGot) still held=\(chat.held.map(\.item.text))"
    )
    #expect(offered, "Restore did not ask, offering Personal, while the message had no owner")
    #expect(staleDraft.isEmpty, "A choice of Personal restored a message Work now owns")
    #expect(personalGot.isEmpty, "Personal got a message Work owns")
    #expect(
      toOwner && workGot && chat.held.isEmpty,
      "Restore did not send the message to its owner and withdraw the original")
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

/// A `profiles.json` #9 wrote: one `origin`, already paired with Work's coordinator, for the
/// messages held in the migrated profile's `Legacy` folder. Or #10's, which held them in
/// `Agent/Held` and listed that queue bound to Work. The held message goes to Work, and Remove counts
/// and deletes it with Work.
@MainActor @Test(.timeLimit(.minutes(1)), arguments: ["as #9 wrote it", "as #10 held it"])
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
  var source = ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy
  if state == "as #9 wrote it" {
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
    struct Listed: Encodable {
      let profiles: [CoordinatorProfile]
      let held: [HeldQueue]
    }
    let queue = HeldQueue(
      adopting: migrated, address: built, coordinator: work.id, installation: nil)
    try writePrivately(
      JSONEncoder().encode(Listed(profiles: [profile], held: [queue])), to: file)
    source = root.appending(path: "Agent/Held/\(migrated)")
  }
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: "Second held note")
    ]), to: source.appending(path: "pending.json"))
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
    let left = FileManager.default.fileExists(atPath: source.path)
    let confirmation = coordinators.removal(migrated).message
    try await coordinators.remove(coordinators.removal(migrated))
    print(
      "IF15-U4-F[\(state)] queues=\(coordinators.queues.count) Restore: draft=\(restored.draft.debugDescription) to Work=\(restored.recipient == migrated) folder moved=\(moved) left where it was=\(left) | Remove Work? \(confirmation) | after Remove: held=\(chat.held.map(\.item.text)) folder kept=\(FileManager.default.fileExists(atPath: queue.folder(applicationSupport: root).path))"
    )
    #expect(queue.address == built && queue.coordinator == work.id)
    #expect(restored.draft == "Second held note" && restored.recipient == migrated)
    #expect(moved && !left, "The held queue's folder is still where it was")
    #expect(confirmation == "This deletes 1 queued message on this phone.")
    #expect(chat.held.isEmpty && coordinators.queues.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: queue.folder(applicationSupport: root).path))
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The build before this one is installed over this one and saves `profiles.json` once, as its
/// pairing does at the build's address, writing only what it knows: the profiles and their
/// withdrawals. This build, installed again, still holds and shows every message the single-address
/// build left, and still keeps that build's alert installation, now for the coordinator proven
/// there.
@MainActor @Test(.timeLimit(.minutes(1)))
func thePreviousBuildRewritingProfilesJSONKeepsEveryHeldMessageAndInstallation() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches,
      transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  }
  var migrated = try #require(launch().profiles.first)
  migrated.pin = CoordinatorID(UUID())
  struct WrittenByThePreviousBuild: Codable {
    let withdrawals: [PendingWithdrawal]
    let profiles: [CoordinatorProfile]
  }
  try writePrivately(
    JSONEncoder().encode(WrittenByThePreviousBuild(withdrawals: [], profiles: [migrated])),
    to: install.support.appending(path: "Agent/profiles.json"))
  let again = launch()
  let shown = try await settles { again.chat.held.count == 2 }
  let saved = try JSONDecoder().decode(
    WrittenByThePreviousBuild.self, from: install.savedProfiles())
  let kept =
    again.queues.contains { $0.installation?.description == install.installation }
    || saved.withdrawals.contains { $0.installation.description == install.installation }
  let folders =
    (try? FileManager.default.contentsOfDirectory(
      atPath: install.support.appending(path: "Agent/HeldQueues").path)) ?? []
  print(
    "IF16-T4-1[this build after the previous build saved profiles.json] queues=\(again.queues.count) held=\(again.chat.held.map(\.item.text)) held folders=\(folders.count) old installation kept=\(kept)"
  )
  #expect(shown && again.chat.held.map(\.item.text) == install.queued.map(\.text))
  #expect(folders.count == 1, "The held folder is gone")
  #expect(kept, "The single-address build's alert installation is lost")
}

/// PR #10 (`0d8daa0`), the build the fork shipped before this one, as its launch reads
/// `profiles.json` and then deletes every entry of `Agent/Profiles`, in Application Support and in
/// Caches, and of `Agent/Held` that the file does not list. A file it cannot decode stops its launch
/// before it deletes anything. This copies what that build does, so it changes only if that build's
/// source does, which it cannot.
private enum ShippedBuild {
  struct Address: Codable, Equatable {
    let host: String
    let port: UInt16
  }
  struct Profile: Codable, Equatable {
    let id: UUID
    let name: String
    let address: Address
    let pin: UUID?
  }
  struct Withdrawal: Codable, Equatable {
    let installation: UUID
    let address: Address
    let pin: UUID
  }
  struct Queue: Codable, Equatable {
    let id: UUID
    let address: Address?
    var coordinator: UUID?
    var installation: UUID?
  }
  struct Saved: Codable, Equatable {
    var profiles: [Profile]
    var withdrawals: [Withdrawal]?
    /// Absent, it lists no held queue.
    var held: [Queue]?
  }

  static func file(_ support: URL) -> URL { support.appending(path: "Agent/profiles.json") }

  /// What its launch over `support` and `caches` deletes.
  static func launchDeletes(support: URL, caches: URL) throws -> [URL] {
    try launchDeletes(Data(contentsOf: file(support)), support: support, caches: caches)
  }

  /// What its launch deletes when `profiles.json` holds `data`.
  static func launchDeletes(_ data: Data, support: URL, caches: URL) throws -> [URL] {
    let saved = try JSONDecoder().decode(Saved.self, from: data)
    func unlisted(in parent: URL, _ listed: [UUID]) -> [URL] {
      let names = Set(listed.map(\.uuidString))
      let entries =
        (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil))
        ?? []
      return entries.filter { !names.contains($0.lastPathComponent) }
    }
    let profiles = saved.profiles.map(\.id)
    return unlisted(in: support.appending(path: "Agent/Profiles"), profiles)
      + unlisted(in: caches.appending(path: "Agent/Profiles"), profiles)
      + unlisted(in: support.appending(path: "Agent/Held"), (saved.held ?? []).map(\.id))
  }

  /// Its whole launch, offline, over a file in its own format or none, and what it deleted
  /// (`Coordinators.swift:431-455`, `499-559`, `573-591`). Each queue the file lists takes the
  /// `Legacy` folder of the profile with its ID. While `coordinatorAddress` is set, the outbox for
  /// that address moves into the queue `migratingHeldQueue` names, else into a new one, which the
  /// file lists at that address with `notificationInstallationID` unless it lists that ID already,
  /// and a profile is saved there. A queue no coordinator took goes to the only profile pinned at its
  /// address. Then every unlisted folder is deleted.
  static func launch(defaults: UserDefaults, support: URL, caches: URL) throws -> [URL] {
    var saved = Saved(profiles: [], withdrawals: [], held: [])
    if let data = try? Data(contentsOf: file(support)) {
      saved = try JSONDecoder().decode(Saved.self, from: data)
    }
    guard var held = saved.held else {
      throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "No held list"])
    }
    var withdrawals = saved.withdrawals ?? []
    func save() throws {
      saved = Saved(profiles: saved.profiles, withdrawals: withdrawals, held: held)
      try writePrivately(JSONEncoder().encode(saved), to: file(support))
    }
    func folder(_ id: UUID) -> URL { support.appending(path: "Agent/Held/\(id.uuidString)") }
    for queue in held {
      try moveOnce(
        ProfileDirectory(ProfileID(queue.id), applicationSupport: support, caches: caches).legacy,
        to: folder(queue.id))
    }
    if let host = defaults.string(forKey: "coordinatorAddress") {
      let port = defaults.string(forKey: "coordinatorPort") ?? "43187"
      if let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
        let address = try? CoordinatorAddress(
          host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
      {
        let id = defaults.string(forKey: "migratingHeldQueue").flatMap(UUID.init) ?? UUID()
        defaults.set(id.uuidString, forKey: "migratingHeldQueue")
        let at = Address(host: address.host, port: address.port)
        let before = (saved.profiles, held)
        if !saved.profiles.contains(where: { $0.address == at }) {
          saved.profiles.append(
            Profile(
              id: UUID(), name: TagName(defaultFor: address).description, address: at, pin: nil))
        }
        if !held.contains(where: { $0.id == id }) {
          held.append(
            Queue(
              id: id, address: at, coordinator: nil,
              installation: defaults.string(forKey: "notificationInstallationID").flatMap(
                UUID.init)))
        }
        if saved.profiles != before.0 || held != before.1 { try save() }
        try moveOnce(legacyOutbox(for: address, applicationSupport: support), to: folder(id))
      }
      let previews = caches.appending(path: "Agent/Previews")
      if FileManager.default.fileExists(atPath: previews.path) {
        try FileManager.default.removeItem(at: previews)
      }
      defaults.removeObject(forKey: "coordinatorAddress")
    }
    for key in ["coordinatorPort", "notificationInstallationID", "migratingHeldQueue"] {
      defaults.removeObject(forKey: key)
    }
    let unbound = held
    for index in held.indices {
      guard let address = held[index].address, held[index].coordinator == nil else { continue }
      let pins = saved.profiles.filter { $0.address == address }.compactMap(\.pin)
      guard pins.count == 1 else { continue }
      if let installation = held[index].installation {
        withdrawals.append(Withdrawal(installation: installation, address: address, pin: pins[0]))
      }
      held[index].coordinator = pins[0]
      held[index].installation = nil
    }
    if held != unbound { try save() }
    let deleted = try launchDeletes(
      JSONEncoder().encode(Saved(profiles: saved.profiles, withdrawals: withdrawals, held: held)),
      support: support, caches: caches)
    for entry in deleted { try FileManager.default.removeItem(at: entry) }
    return deleted
  }

  /// Its save after a socket at `address` answered as `found`, with the profiles `edit` leaves, as
  /// pairing, an edit and Add save (`Coordinators.swift:294-315`). Each listed queue at `address`
  /// that no coordinator took goes to `found` when a profile is pinned to it, and the queue's
  /// installation is withdrawn there.
  static func save(
    support: URL, answered found: CoordinatorID, at address: CoordinatorAddress,
    _ edit: (inout [Profile]) -> Void
  ) throws {
    var saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file(support)))
    edit(&saved.profiles)
    var held = saved.held ?? []
    var withdrawals = saved.withdrawals ?? []
    let at = Address(host: address.host, port: address.port)
    if saved.profiles.contains(where: { $0.pin == found.uuid }) {
      for index in held.indices where held[index].address == at && held[index].coordinator == nil {
        if let installation = held[index].installation {
          withdrawals.append(Withdrawal(installation: installation, address: at, pin: found.uuid))
        }
        held[index].coordinator = found.uuid
        held[index].installation = nil
      }
    }
    try writePrivately(
      JSONEncoder().encode(Saved(profiles: saved.profiles, withdrawals: withdrawals, held: held)),
      to: file(support))
  }
}

/// PR #9 (`ba93f33`), which the fork shipped before #10, as each of its saves writes
/// `profiles.json`: the profiles and withdrawals it read, and an `origin` it read from the file or
/// from a profile's `inherited`. It writes nothing else it read, so every save drops `held`
/// (`Coordinators.swift:313-345`). Pairing a profile is one such save, and it hands the origin's
/// alert installation to the coordinator paired at the origin's address (`:264-278`). This copies
/// what that build does, so it changes only if that build's source does, which it cannot.
private enum NinthBuild {
  struct Address: Codable, Equatable {
    let host: String
    let port: UInt16
  }
  struct Profile: Codable {
    let id: UUID
    let name: String
    let address: Address
    var pin: UUID?
  }
  struct Withdrawal: Codable {
    let installation: UUID
    let address: Address
    let pin: UUID
  }
  struct Origin: Codable {
    let address: Address
    var coordinator: UUID?
    var installation: UUID?
  }
  struct Saved: Codable {
    var profiles: [Profile]
    var withdrawals: [Withdrawal]
    var origin: Origin?

    private enum CodingKeys: String, CodingKey { case profiles, withdrawals, origin }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profiles = try container.decode([Profile].self, forKey: .profiles)
      withdrawals = try container.decodeIfPresent([Withdrawal].self, forKey: .withdrawals) ?? []
      struct Earlier: Decodable {
        let address: Address
        let inherited: UUID?
      }
      origin =
        try container.decodeIfPresent(Origin.self, forKey: .origin)
        ?? container.decode([Earlier].self, forKey: .profiles).first { $0.inherited != nil }.map {
          Origin(address: $0.address, coordinator: nil, installation: $0.inherited)
        }
    }
  }

  /// `data`, a `profiles.json`, as one save of that build writes it, pairing `profile` with
  /// `coordinator` when given.
  static func save(
    _ data: Data, pairing profile: ProfileID? = nil, with coordinator: CoordinatorID? = nil
  ) throws -> Data {
    var saved = try JSONDecoder().decode(Saved.self, from: data)
    if let profile, let coordinator,
      let index = saved.profiles.firstIndex(where: { $0.id == profile.uuid })
    {
      saved.profiles[index].pin = coordinator.uuid
      if var origin = saved.origin, origin.address == saved.profiles[index].address,
        origin.coordinator == nil
      {
        origin.coordinator = coordinator.uuid
        if let installation = origin.installation {
          saved.withdrawals.append(
            Withdrawal(installation: installation, address: origin.address, pin: coordinator.uuid))
        }
        origin.installation = nil
        saved.origin = origin
      }
    }
    return try JSONEncoder().encode(saved)
  }
}

/// The single-address build queued two messages for its coordinator, one with a file, and this
/// build holds them. The build the fork shipped before this one is installed over it and launched
/// once, and then this build again. Both messages and the file are still held.
@MainActor @Test
func launchingTheShippedBuildOverThisOneKeepsEveryHeldMessage() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches,
      transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  }
  let first = launch().queues
  let deleted = try ShippedBuild.launchDeletes(support: install.support, caches: install.caches)
  for entry in deleted { try FileManager.default.removeItem(at: entry) }
  let again = launch()
  let shown = try await settles { again.chat.held.count == 2 }
  let file = again.queues.first.flatMap {
    try? Data(
      contentsOf: $0.folder(applicationSupport: install.support).appending(
        path: "Attachments/\(install.attachment.id)/Notes.txt"))
  }
  print(
    "IF17-S1-1[the shipped build launched once over this one] it deleted=\(deleted.map(\.lastPathComponent)) | this build again: queues=\(again.queues.count) held=\(again.chat.held.map(\.item.text)) file kept=\(file == install.bytes)"
  )
  #expect(deleted.isEmpty, "The shipped build deleted what this build holds")
  #expect(shown && again.chat.held.map(\.item.text) == install.queued.map(\.text))
  #expect(again.queues == first)
  #expect(file == install.bytes, "The held message's file is gone")
}

/// Opus's round-18 R1. The single-address build queued two messages for its coordinator, one with a
/// file, and this build holds them while that coordinator answers nothing. #9 is installed over
/// this build, the coordinator answers, and #9 pairs the saved profile, which saves `profiles.json`
/// with only what #9 knows. Then #10 is installed and launched once, and then this build again.
/// Both messages and the file are still held, for the coordinator #9 paired.
@MainActor @Test
func theShippedBuildLaunchedAfterTheOneBeforeItSavedKeepsEveryHeldMessage() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches,
      transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  }
  let migrated = try #require(launch().profiles.first)
  let file = ShippedBuild.file(install.support)
  try writePrivately(
    NinthBuild.save(Data(contentsOf: file), pairing: migrated.id, with: CoordinatorID(UUID())),
    to: file)
  let keys = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
  let deleted = try ShippedBuild.launchDeletes(support: install.support, caches: install.caches)
  for entry in deleted { try FileManager.default.removeItem(at: entry) }
  let again = launch()
  let shown = try await settles { again.chat.held.count == 2 }
  let owners = again.chat.held.map { again.chat.owner($0) == migrated.id }
  let kept = again.queues.first.flatMap {
    try? Data(
      contentsOf: $0.folder(applicationSupport: install.support).appending(
        path: "Attachments/\(install.attachment.id)/Notes.txt"))
  }
  print(
    "IF18-R1[this build, #9 pairs, #10 launches, this build] #9 saved keys=\(keys?.keys.sorted() ?? []) | #10 deleted=\(deleted.map(\.lastPathComponent)) | this build again: queues=\(again.queues.count) held=\(again.chat.held.map(\.item.text)) for the paired coordinator=\(owners) file kept=\(kept == install.bytes)"
  )
  #expect(deleted.isEmpty, "#10 deleted what this build holds after #9 saved")
  #expect(shown && again.chat.held.map(\.item.text) == install.queued.map(\.text))
  #expect(owners == [true, true])
  #expect(kept == install.bytes, "The held message's file is gone")
}

/// After every change this build saves, a launch of the build the fork shipped before this one
/// deletes no held queue and no saved coordinator's files, also once #9 has saved `profiles.json`
/// with only what #9 knows: at the migration, which also holds a second launch's note for an
/// address this phone never saved, after the migrated profile is edited to Work's address, after
/// Personal is added at the build's address and takes its queue, and after each is removed.
@MainActor @Test(.timeLimit(.minutes(1)))
func theShippedBuildsLaunchDeletesNothingThisBuildSaved() async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(
        inputId: UUID().uuidString, mode: .steer, text: "Invented note from another launch")
    ]), to: install.otherOutbox.appending(path: "pending.json"))
  try await withTheOldAddressSilent(install) { coordinators, migrated, _, _, bringBack in
    var steps: [String] = []
    @MainActor func check(_ step: String) throws {
      let file = try Data(contentsOf: ShippedBuild.file(install.support))
      let held = try HeldQueue.all(applicationSupport: install.support)
      let live = Set(held.map(\.id.uuidString) + coordinators.profiles.map(\.id.description))
      func deletes(_ file: Data) throws -> String {
        let deleted = try ShippedBuild.launchDeletes(
          file, support: install.support, caches: install.caches
        ).map(\.lastPathComponent)
        let lost = deleted.filter(live.contains).count
        return "deletes \(deleted.count), of them held or saved \(lost)"
      }
      steps.append(
        "\(step): holds \(held.count) queues | the shipped build \(try deletes(file)) | after #9 saved, it \(try deletes(NinthBuild.save(file)))"
      )
    }
    try check("launch")
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try check("the migrated profile edited to Work's address")
    await bringBack()
    try await coordinators.add(name: TagName("Personal"), address: install.address)
    try check("Personal added at the build's address")
    let personal = try #require(coordinators.profiles.last)
    try await coordinators.remove(coordinators.removal(personal.id))
    try check("Personal removed")
    try await coordinators.remove(coordinators.removal(migrated.id))
    try check("Work removed")
    print("IF17-S1-2\n" + steps.joined(separator: "\n"))
    #expect(
      steps.allSatisfy { $0.components(separatedBy: "of them held or saved 0").count == 3 },
      "The shipped build deletes a held queue or a saved coordinator's files")
  }
}

/// The builds before this one left notes in two outboxes of the single-address build, in
/// Personal's `Legacy` folder and in a folder #10 kept in `Agent/Held` (`leaveEveryKindOfSource`).
/// The migration stops at each time it reaches `step`, and the build the fork shipped before this
/// one is launched over what it left: that launch deletes nothing. Then this build resumes, and every
/// queue named at the stop holds its notes, once.
@MainActor
@Test(
  arguments: [
    Coordinators.MigrationStep.queueNamed, .profileSaved, .queueRecorded, .quarantined,
    .markerRemoved,
  ])
func aMigrationStoppedAtAnyStepLeavesTheShippedBuildNothingToDelete(
  _ step: Coordinators.MigrationStep
) async throws {
  var stops: [String] = []
  for stop in 1... {
    let install = try await LegacyInstall()
    defer { install.remove() }
    let notes = try leaveEveryKindOfSource(install)
    var reached = 0
    do {
      _ = try Coordinators.migrate(
        defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
        crash: {
          guard $0 == step else { return }
          reached += 1
          if reached == stop { throw Crash() }
        })
      break
    } catch is Crash {}
    struct Listed: Decodable {
      struct Queue: Decodable { let id: UUID }
      let held: [Queue]?
    }
    let listed = try JSONDecoder().decode(Listed.self, from: install.savedProfiles()).held ?? []
    func entries(_ path: String) -> [URL] {
      (try? FileManager.default.contentsOfDirectory(
        at: install.support.appending(path: path), includingPropertiesForKeys: nil)) ?? []
    }
    let shipped = entries("Agent/Held")
    var named = Set(
      entries("Agent/HeldQueues").compactMap { UUID(uuidString: $0.lastPathComponent) })
    let legacy = ProfileDirectory.holdingLegacy(
      applicationSupport: install.support, caches: install.caches
    ).map(\.legacy)
    for source in [install.oldOutbox, install.otherOutbox] + legacy + shipped {
      let id =
        try HeldQueue.recorded(in: source)?.id
        ?? (shipped.contains(source) ? UUID(uuidString: source.lastPathComponent) : nil)
      if let id { named.insert(id) }
    }
    let deleted = try ShippedBuild.launchDeletes(support: install.support, caches: install.caches)
    let resumed = try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches)
    var held: [String] = []
    for queue in resumed.held {
      held += try await LegacyHold(queue.folder(applicationSupport: install.support)).items().map(
        \.text)
    }
    let after = try ShippedBuild.launchDeletes(support: install.support, caches: install.caches)
    stops.append(
      "\(step) #\(stop): Agent/Held=\(shipped.count) listed=\(listed.count) | the shipped build deletes \(deleted.map(\.lastPathComponent)) | resumed: queues=\(resumed.held.count) named at the stop kept=\(named.isSubset(of: Set(resumed.held.map(\.id)))) notes=\(held.count) the shipped build deletes \(after.count)"
    )
    #expect(deleted.isEmpty, "The shipped build deletes what a stopped migration left")
    #expect(named.isSubset(of: Set(resumed.held.map(\.id))), "A queue named at the stop is gone")
    #expect(resumed.held.count == 4)
    #expect(held.sorted() == notes.sorted())
    #expect(after.isEmpty)
  }
  print("IF17b-S4\n" + stops.joined(separator: "\n"))
}

/// The build the fork shipped before this one held the single-address build's queue in
/// `Agent/Held`, bound it to the coordinator it proved at the queue's address, 100.64.1.2:43187,
/// saved the withdrawal of the old alert installation, and the user then moved the profile to port
/// 4001. This build adopts that queue with the binding that build listed and saves no second
/// withdrawal. The same listing for a queue of this build's names no folder in `Agent/Held`, so it
/// gives that queue nothing: it stays unbound with its installation. Either way the list goes.
@MainActor @Test(arguments: ["#10's queue", "a queue of this build's"])
func aBindingTheShippedBuildListedCountsOnlyForItsOwnFolder(_ whose: String) async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: install.defaults, applicationSupport: install.support,
      caches: install.caches,
      transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  }
  let first = launch()
  let queue = try #require(first.queues.first)
  let migrated = try #require(first.profiles.first)
  let coordinator = CoordinatorID(UUID())
  let shipped = install.support.appending(path: "Agent/Held/\(queue.id.uuidString)")
  var withdrawals = ""
  if whose == "#10's queue" {
    try FileManager.default.createDirectory(
      at: shipped.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(
      at: queue.folder(applicationSupport: install.support), to: shipped)
    try FileManager.default.removeItem(at: shipped.appending(path: "queue.json"))
    withdrawals = """
      {"installation":"\(install.installation)",\
      "address":{"host":"100.64.1.2","port":43187},"pin":"\(coordinator.uuid.uuidString)"}
      """
  }
  try writePrivately(
    Data(
      """
      {"withdrawals":[\(withdrawals)],\
      "profiles":[{"id":"\(migrated.id)","name":"Work",\
      "address":{"host":"100.64.1.2","port":4001},"pin":"\(coordinator.uuid.uuidString)"}],\
      "held":[{"id":"\(queue.id.uuidString)","address":{"host":"100.64.1.2","port":43187},\
      "coordinator":"\(coordinator.uuid.uuidString)"}]}
      """.utf8), to: install.support.appending(path: "Agent/profiles.json"))
  let again = launch()
  let shown = try await settles { again.chat.held.count == 2 }
  let after = try #require(again.queues.first)
  struct Saved: Decodable {
    let withdrawals: [PendingWithdrawal]
    let held: [HeldQueue]?
  }
  let saved = try JSONDecoder().decode(Saved.self, from: install.savedProfiles())
  let owners = again.chat.held.map { again.chat.owner($0) == migrated.id }
  print(
    "IF18-bound[\(whose) listed bound] queue bound to it=\(after.coordinator == coordinator) old installation kept=\(after.installation != nil) withdrawals=\(saved.withdrawals.count) held=\(again.chat.held.map(\.item.text)) owned by Work=\(owners) profiles.json held=\(saved.held?.count ?? -1) left in Agent/Held=\(FileManager.default.fileExists(atPath: shipped.path))"
  )
  #expect(shown && again.chat.held.map(\.item.text) == install.queued.map(\.text))
  if whose == "#10's queue" {
    #expect(after.coordinator == coordinator && after.installation == nil)
    #expect(owners == [true, true])
    #expect(saved.withdrawals.count == 1, "The installation that build withdrew is withdrawn again")
  } else {
    #expect(after.coordinator == nil && after.installation?.description == install.installation)
    #expect(saved.withdrawals.isEmpty)
  }
  #expect(saved.held == [], "profiles.json names a queue no longer in Agent/Held")
  #expect(!FileManager.default.fileExists(atPath: shipped.path))
}

/// Opus's round-19 finding 2, chains S and V. The single-address build queued two notes for
/// 100.64.1.2:43187 while Work answered there. A launch of this build stops after `step`, once it
/// has recorded its queue in the folder it is adopting: that build's outbox, or the folder #10 held
/// the notes in. #10 then pairs the migrated profile with Work at 43187, which binds that queue to
/// Work. The user moves Work to 4002 and adds Personal, which now answers at 43187. This build keeps
/// #10's binding, so the notes restore to Work and only Work gets them.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    ("the outbox", Coordinators.MigrationStep.queueNamed), ("the outbox", .profileSaved),
    ("the outbox", .queueRecorded), ("#10's folder", .queueRecorded),
  ])
func aBindingTheShippedBuildMadeAfterALaunchStoppedOutlivesThatLaunchsRecord(
  _ adopting: String, _ step: Coordinators.MigrationStep
) async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  if adopting == "#10's folder" {
    _ = try ShippedBuild.launch(
      defaults: install.defaults, support: install.support, caches: install.caches)
  }
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
      crash: { if $0 == step { throw Crash() } })
  }
  let source =
    try adopting == "the outbox"
    ? install.oldOutbox
    : #require(
      FileManager.default.contentsOfDirectory(
        at: install.support.appending(path: "Agent/Held"), includingPropertiesForKeys: nil
      ).first)
  let recorded = try HeldQueue.recorded(in: source)
  _ = try ShippedBuild.launch(
    defaults: install.defaults, support: install.support, caches: install.caches)
  let old = ShippedBuild.Address(host: install.address.host, port: install.address.port)
  let moved = try CoordinatorAddress(host: install.address.host, port: 4002)
  try ShippedBuild.save(support: install.support, answered: work.id, at: install.address) {
    $0 = $0.map {
      $0.address == old ? .init(id: $0.id, name: $0.name, address: old, pin: work.id.uuid) : $0
    }
  }
  try ShippedBuild.save(support: install.support, answered: work.id, at: moved) {
    $0 = $0.map {
      $0.pin == work.id.uuid
        ? .init(id: $0.id, name: "Work", address: .init(host: moved.host, port: 4002), pin: $0.pin)
        : $0
    }
  }
  try ShippedBuild.save(support: install.support, answered: personal.id, at: install.address) {
    $0.append(.init(id: UUID(), name: "Personal", address: old, pin: personal.id.uuid))
  }
  let listed =
    try JSONDecoder().decode(
      ShippedBuild.Saved.self, from: Data(contentsOf: ShippedBuild.file(install.support))
    ).held ?? []
  let routes = Routes([4002: workPort, install.address.port: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
    caches: install.caches,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("both connected and the notes held") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
        && chat.held.count == 2
    }
    let owners = chat.held.map { chat.owner($0).map(chat.name) ?? "nobody" }
    let note = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(note)
    let restored = (draft: chat.draft, recipient: chat.recipient.map(chat.name) ?? "nobody")
    if !chat.draft.isEmpty {
      await chat.send()
      _ = try await settles { await submitted(work) + submitted(personal) != [] }
    }
    print(
      "IF19-stale[\(adopting) recorded, then stopped after \(step)] record left=\(recorded.map { "\($0.id.uuidString.prefix(8)) bound=\($0.coordinator != nil)" } ?? "none") #10 listed=\(listed.map { "\($0.id.uuidString.prefix(8)) bound to Work=\($0.coordinator == work.id.uuid)" }) | this build: queues=\(coordinators.queues.map { "\($0.id.uuidString.prefix(8)) bound to Work=\($0.coordinator == work.id) to Personal=\($0.coordinator == personal.id)" }) owners=\(owners) Restore: draft=\(restored.draft.debugDescription) to=\(restored.recipient) after Send: Work's coordinator got=\(await submitted(work)) Personal's coordinator got=\(await submitted(personal))"
    )
    #expect(recorded != nil, "The stopped launch recorded no queue in the folder it was adopting")
    #expect(listed.map(\.coordinator) == [work.id.uuid], "#10 did not bind the queue to Work")
    #expect(coordinators.queues.map(\.id) == listed.map(\.id), "The queue #10 listed is gone")
    #expect(owners == ["Work", "Work"])
    #expect(restored.draft == "Second held note" && restored.recipient == "Work")
    #expect(await submitted(work) == ["Second held note"])
    #expect(await submitted(personal).isEmpty, "A note queued while Work answered went to Personal")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// A launch of this build on a disk too full to save `profiles.json`, where a folder can still be
/// made: each held folder moves into `Agent/HeldQueues`, and the save after the moves fails.
@MainActor private func launchWhoseSaveFails(defaults: UserDefaults, root: URL) throws {
  let agent = root.appending(path: "Agent")
  try FileManager.default.createDirectory(
    at: agent.appending(path: "HeldQueues"), withIntermediateDirectories: true)
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
  defer {
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
  }
  #expect(throws: (any Error).self) {
    try Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root)
  }
}

/// Restores each held note that has an owner and sends it once the composer can, one at a time,
/// and returns the name Restore addressed each to, by the note's text.
@MainActor private func restoreAndSendEachOwnedNote(
  _ chat: ChatModel, to fixtures: [FixtureCoordinator]
) async throws -> [String: String] {
  func sent() async -> Int {
    var count = 0
    for fixture in fixtures { count += await submitted(fixture).count }
    return count
  }
  var addressed: [String: String] = [:]
  for note in chat.held where chat.owner(note) != nil {
    let before = await sent()
    await chat.restoreHeld(note)
    addressed[note.item.text] = chat.recipient.map(chat.name) ?? "nobody"
    guard !chat.draft.isEmpty else { continue }
    _ = try await settles { chat.canSend }
    await chat.send()
    _ = try await settles { await sent() > before }
  }
  return addressed
}

/// Opus's round-21 chain L. The single-address build queued m1 for 100.64.1.2:43187 while Work
/// answered there. #9 held it in the migrated profile's `Legacy` folder, and #10 held it in
/// `Agent/Held` under that profile's ID, bound to Work. The user moved Work to 4002. The
/// single-address build then queued m2 for 43187, and #9 held it in the same `Legacy` folder. A
/// launch of this build moves both folders into `Agent/HeldQueues` and fails to save, so
/// `profiles.json` still lists #10's binding. Then Personal answers at 43187, and the migrated
/// profile pairs with it. #10's binding was for m1 alone, so m1 reaches Work only, and m2, queued
/// after Work left 43187, reaches Personal only.
@MainActor @Test(.timeLimit(.minutes(1)))
func aBindingTheShippedBuildListedStaysWithTheNoteItWasForAfterAFailedSave() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r21r-chain-l-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let migrated = ProfileID()
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "held":[{"id":"\(migrated)","address":{"host":"100.64.1.2","port":43187},\
      "coordinator":"\(work.id.uuid.uuidString)"}],\
      "profiles":[{"id":"\(migrated)","name":"Coordinator",\
      "address":{"host":"100.64.1.2","port":43187}},\
      {"id":"\(ProfileID())","name":"Work",\
      "address":{"host":"100.64.1.2","port":4002},"pin":"\(work.id.uuid.uuidString)"}]}
      """.utf8), to: ShippedBuild.file(root))
  func queue(_ text: String, in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]), to: folder.appending(path: "pending.json"))
  }
  let m1 = "m1: queued at 43187 while Work answered"
  let m2 = "m2: queued at 43187 after Work moved to 4002"
  try queue(m1, in: root.appending(path: "Agent/Held/\(migrated)"))
  try queue(m2, in: ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy)
  try launchWhoseSaveFails(defaults: defaults, root: root)
  let listed =
    try JSONDecoder().decode(
      ShippedBuild.Saved.self, from: Data(contentsOf: ShippedBuild.file(root))
    ).held ?? []
  let leftInHeld =
    (try? FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Agent/Held").path)) ?? []
  let routes = Routes([4002: workPort, 43187: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("both connected and both notes held") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
        && chat.held.count == 2
    }
    _ = try await settles { chat.held.allSatisfy { chat.owner($0) != nil } }
    let owners = chat.held.map {
      "\($0.item.text.prefix(2)): \(chat.owner($0).map(chat.name) ?? "nobody")"
    }
    let addressed = try await restoreAndSendEachOwnedNote(chat, to: [work, personal])
    print(
      "R21-L[#10's folder and a later Legacy folder moved, then the save failed] still listed=\(listed.map { "bound to Work=\($0.coordinator == work.id.uuid)" }) left in Agent/Held=\(leftInHeld.count) | this build: owners=\(owners) Restore addressed=\(addressed.sorted { $0.key < $1.key }.map { "\($0.key.prefix(2)) to \($0.value)" }) after Send: Work's coordinator got=\(await submitted(work).map { $0.prefix(2) }) Personal's coordinator got=\(await submitted(personal).map { $0.prefix(2) })"
    )
    #expect(
      listed.map(\.coordinator) == [work.id.uuid] && leftInHeld.isEmpty,
      "The failed launch did not move #10's folder while its binding stayed listed")
    #expect(await submitted(work) == [m1], "Work did not get m1 alone")
    #expect(
      await submitted(personal) == [m2], "m2, queued after Work left 43187, did not reach Personal")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Opus's round-21 chain C. The single-address build queued m1 for 100.64.1.2:43187 with its alert
/// installation, and #9 held both in the migrated profile's `Legacy` folder. This build adopted that
/// folder offline. The single-address build then queued m2 for 43187, #9 held it in the same
/// `Legacy` folder, and #9 saved `profiles.json` without `held`. #10 listed that folder under the
/// profile's ID with no installation, and once Work answered at 43187 bound it to Work, saving no
/// withdrawal. A launch of this build moves #10's folder into `Agent/HeldQueues` and fails to save,
/// so `profiles.json` still lists that binding. Work answers at 43187 again: both notes reach Work,
/// and Work gets the old installation's withdrawal once.
@MainActor @Test(.timeLimit(.minutes(1)))
func theOldInstallationIsWithdrawnAfterTheShippedBuildBoundALaterFolderAndASaveFailed()
  async throws
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r21r-chain-c-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let migrated = ProfileID()
  let installation = UUID().uuidString
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "origin":{"address":{"host":"100.64.1.2","port":43187},"installation":"\(installation)"},\
      "profiles":[{"id":"\(migrated)","name":"Coordinator",\
      "address":{"host":"100.64.1.2","port":43187}}]}
      """.utf8), to: ShippedBuild.file(root))
  let legacy = ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy
  func queue(_ text: String) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]), to: legacy.appending(path: "pending.json"))
  }
  let m1 = "m1: queued at 43187 with the old alert installation"
  let m2 = "m2: queued at 43187 later"
  try queue(m1)
  _ = try Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root)
  try queue(m2)
  let shipped = root.appending(path: "Agent/Held/\(migrated)")
  try FileManager.default.createDirectory(
    at: shipped.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.moveItem(at: legacy, to: shipped)
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "held":[{"id":"\(migrated)","address":{"host":"100.64.1.2","port":43187}}],\
      "profiles":[{"id":"\(migrated)","name":"Coordinator",\
      "address":{"host":"100.64.1.2","port":43187}}]}
      """.utf8), to: ShippedBuild.file(root))
  let address = try CoordinatorAddress(host: "100.64.1.2")
  try ShippedBuild.save(support: root, answered: work.id, at: address) {
    $0 = $0.map { .init(id: $0.id, name: $0.name, address: $0.address, pin: work.id.uuid) }
  }
  let byTen = try JSONDecoder().decode(
    ShippedBuild.Saved.self, from: Data(contentsOf: ShippedBuild.file(root)))
  try launchWhoseSaveFails(defaults: defaults, root: root)
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: loopback(workPort))
  let chat = coordinators.chat
  func unregistered() async -> [String] {
    await work.notificationControls().compactMap {
      if case .unregister(let value) = $0 { value.installationId.uppercased() } else { nil }
    }
  }
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("connected and both notes held") {
      chat.snapshots.values.first?.connection == .connected && chat.held.count == 2
    }
    _ = try await settles { await !unregistered().isEmpty }
    let addressed = try await restoreAndSendEachOwnedNote(chat, to: [work])
    print(
      "R21-C[#10 bound a later folder under an adopted queue's ID, then the save failed] #10 listed=\(byTen.held?.map { "bound to Work=\($0.coordinator == work.id.uuid) installation=\($0.installation != nil)" } ?? []) withdrawals=\(byTen.withdrawals?.count ?? 0) | this build: queues=\(coordinators.queues.map { "bound to Work=\($0.coordinator == work.id) installation=\($0.installation != nil)" }) Restore addressed=\(addressed.sorted { $0.key < $1.key }.map { "\($0.key.prefix(2)) to \($0.value)" }) | Work's coordinator: unregistered the old installation=\(await unregistered().filter { $0 == installation }.count) others=\(await unregistered().filter { $0 != installation }.count) got=\(await submitted(work).map { $0.prefix(2) })"
    )
    #expect(
      byTen.held?.map(\.coordinator) == [work.id.uuid] && byTen.withdrawals?.isEmpty == true,
      "#10 did not bind its listing to Work without a withdrawal")
    #expect(
      await unregistered() == [installation],
      "Work did not get the old installation's withdrawal exactly once")
    #expect(await submitted(work).sorted() == [m1, m2])
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The `profiles.json` #9 wrote once it paired the migrated profile with Work at 43187 and bound
/// `origin` to Work, and the user then moved Work to 4002 and added Personal, which answers at 43187.
private func writeNinthBuildsPairedFile(
  root: URL, work: ProfileID, workCoordinator: CoordinatorID, personal: CoordinatorID,
  withdrawn installation: String?
) throws {
  let withdrawals = installation.map {
    """
    {"installation":"\($0)","address":{"host":"100.64.1.2","port":43187},\
    "pin":"\(workCoordinator.uuid.uuidString)"}
    """
  }
  try writePrivately(
    Data(
      """
      {"withdrawals":[\(withdrawals ?? "")],\
      "origin":{"address":{"host":"100.64.1.2","port":43187},\
      "coordinator":"\(workCoordinator.uuid.uuidString)"},\
      "profiles":[{"id":"\(work)","name":"Work",\
      "address":{"host":"100.64.1.2","port":4002},"pin":"\(workCoordinator.uuid.uuidString)"},\
      {"id":"\(UUID())","name":"Personal",\
      "address":{"host":"100.64.1.2","port":43187},"pin":"\(personal.uuid.uuidString)"}]}
      """.utf8), to: root.appending(path: "Agent/profiles.json"))
}

/// What the user sees once this build launches with Work at 4002 and Personal at 43187: who each held
/// note belongs to, the draft and recipient Restore gives the one held note, and what each
/// coordinator got after Send.
private struct RestoredAndSent {
  let queues: [String]
  let owners: [String]
  let draft: String
  let recipient: String
  let atWork: [String]
  let atPersonal: [String]
}

@MainActor private func restoreAndSend(
  root: URL, defaults: UserDefaults, work: FixtureCoordinator, workPort: NWEndpoint.Port,
  personal: FixtureCoordinator, personalPort: NWEndpoint.Port
) async throws -> RestoredAndSent {
  let routes = Routes([4002: workPort, 43187: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await eventually("both connected and the note held") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
        && chat.held.count == 1
    }
    func who(_ pin: CoordinatorID?) -> String {
      pin == work.id ? "Work" : pin == personal.id ? "Personal" : "nobody"
    }
    let queues = coordinators.queues.map {
      "\($0.id.uuidString.prefix(8)) at \($0.address.map { "\($0.port)" } ?? "?") bound to \(who($0.coordinator))"
    }
    let owners = chat.held.map { chat.owner($0).map(chat.name) ?? "nobody" }
    await chat.restoreHeld(try #require(chat.held.first))
    let draft = chat.draft
    let recipient = chat.recipient.map(chat.name) ?? "nobody"
    if !chat.draft.isEmpty {
      await chat.send()
      _ = try await settles { await submitted(work) + submitted(personal) != [] }
    }
    let result = RestoredAndSent(
      queues: queues, owners: owners, draft: draft, recipient: recipient,
      atWork: await submitted(work), atPersonal: await submitted(personal))
    await stop()
    return result
  } catch {
    await stop()
    throw error
  }
}

/// #9 held the single-address build's note for 100.64.1.2:43187 in the migrated profile's `Legacy`
/// folder, with an `origin` it had bound to Work. The user moved Work to 4002 and added Personal,
/// which answers at 43187. A launch of this build records the folder's queue from `origin`, saves
/// `profiles.json` without it, and stops before the folder moves. No `origin` is left to describe the
/// folder, and Work is pinned, so only that record says whose the note is. The next launch keeps it,
/// so the note restores to Work and only Work gets it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLegacyFolderKeepsWhatOriginSaidOnceALaunchStoppedAfterSavingWithoutIt() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r20t-record-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let migrated = ProfileID()
  try writeNinthBuildsPairedFile(
    root: root, work: migrated, workCoordinator: work.id, personal: personal.id, withdrawn: nil)
  let legacy = ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy
  let note = "Note queued while Work answered at 43187"
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: note)
    ]), to: legacy.appending(path: "pending.json"))
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: defaults, applicationSupport: root, caches: root,
      crash: { if $0 == .queueRecorded { throw Crash() } })
  }
  let recorded = try HeldQueue.recorded(in: legacy)
  let originLeft =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: root.appending(path: "Agent/profiles.json"))) as? [String: Any]
  let seen = try await restoreAndSend(
    root: root, defaults: defaults, work: work, workPort: workPort, personal: personal,
    personalPort: personalPort)
  print(
    "IF21-record[origin saved away, then stopped before the move] record left=\(recorded != nil) origin left=\(originLeft?["origin"] != nil) | this build: queues=\(seen.queues) owners=\(seen.owners) Restore: draft=\(seen.draft.debugDescription) to=\(seen.recipient) after Send: Work's coordinator got=\(seen.atWork) Personal's coordinator got=\(seen.atPersonal)"
  )
  #expect(recorded != nil, "The stopped launch recorded no queue in the Legacy folder")
  #expect(originLeft?["origin"] == nil, "origin is still saved, so it still describes the folder")
  #expect(seen.owners == ["Work"])
  #expect(seen.draft == note && seen.recipient == "Work")
  #expect(seen.atWork == [note])
  #expect(seen.atPersonal.isEmpty, "A note queued while Work answered went to Personal")
}

/// #9 held the single-address build's note for 100.64.1.2:43187 in the migrated profile's `Legacy`
/// folder, with an unpaired `origin` there carrying the build's alert installation. A launch of this
/// build records the folder's queue, unbound at 43187, and its save of `profiles.json` fails, so
/// `origin` stays. #9 then pairs the profile with Work at 43187 and binds `origin` to Work. The user
/// moves Work to 4002 and adds Personal, which answers at 43187. `origin` is newer than the record,
/// so the note restores to Work and only Work gets it.
@MainActor @Test(.timeLimit(.minutes(1)))
func theOriginNinePairedAfterAFailedSaveOutlivesThatLaunchsRecord() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "r20t-origin-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let migrated = ProfileID()
  let installation = UUID().uuidString
  let agent = root.appending(path: "Agent")
  try writePrivately(
    Data(
      """
      {"withdrawals":[],"origin":{"address":{"host":"100.64.1.2","port":43187},\
      "installation":"\(installation)"},\
      "profiles":[{"id":"\(migrated)","name":"Work",\
      "address":{"host":"100.64.1.2","port":43187}}]}
      """.utf8), to: agent.appending(path: "profiles.json"))
  let legacy = ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy
  let note = "Note queued while Work answered at 43187"
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: note)
    ]), to: legacy.appending(path: "pending.json"))
  try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: agent.path)
  #expect(throws: (any Error).self) {
    try Coordinators.migrate(defaults: defaults, applicationSupport: root, caches: root)
  }
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
  let recorded = try HeldQueue.recorded(in: legacy)
  let originLeft =
    try JSONSerialization.jsonObject(
      with: Data(contentsOf: agent.appending(path: "profiles.json"))) as? [String: Any]
  try writeNinthBuildsPairedFile(
    root: root, work: migrated, workCoordinator: work.id, personal: personal.id,
    withdrawn: installation)
  let seen = try await restoreAndSend(
    root: root, defaults: defaults, work: work, workPort: workPort, personal: personal,
    personalPort: personalPort)
  print(
    "IF21-origin[recorded, then the save failed, then #9 bound origin] record left=\(recorded.map { "at \($0.address.map { "\($0.port)" } ?? "?") bound=\($0.coordinator != nil)" } ?? "none") origin left=\(originLeft?["origin"] != nil) | this build: queues=\(seen.queues) owners=\(seen.owners) Restore: draft=\(seen.draft.debugDescription) to=\(seen.recipient) after Send: Work's coordinator got=\(seen.atWork) Personal's coordinator got=\(seen.atPersonal)"
  )
  #expect(
    recorded != nil && recorded?.coordinator == nil,
    "The failed launch recorded no unbound queue in the folder")
  #expect(originLeft?["origin"] != nil, "The failed save dropped origin, so #9 cannot bind it")
  #expect(seen.owners == ["Work"])
  #expect(seen.draft == note && seen.recipient == "Work")
  #expect(seen.atWork == [note])
  #expect(seen.atPersonal.isEmpty, "A note queued while Work answered went to Personal")
}

/// The single-address build left two messages for its coordinator at 100.64.1.2:43187, which
/// answers nothing at the update. The user taps Remove coordinator, and its confirmation counts no
/// held messages. Then the build's coordinator answers again: the migrated profile's own Try again
/// pairs it, or, with the same machine added as Personal at 4002 and Personal being removed, that
/// probe is refused as Personal. Either binds the build's queue to the coordinator being removed
/// before Remove runs. Remove deletes only what its confirmation counted, so both messages stay.
@MainActor
@Test(.timeLimit(.minutes(1)), arguments: ["the migrated profile", "Personal added by IP"])
func removeDeletesOnlyTheHeldQueuesItsConfirmationCounted(_ removing: String) async throws {
  let install = try await LegacyInstall()
  defer { install.remove() }
  let used = FixtureCoordinator()
  let (listener, port) = try await listen(used)
  defer { listener.cancel() }
  let routes = Routes([4002: port])
  let coordinators = Coordinators(
    registration: nil, defaults: install.defaults, applicationSupport: install.support,
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
    var target = migrated.id
    if removing == "Personal added by IP" {
      try await coordinators.add(
        name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
      target = try #require(coordinators.profiles.last?.id)
    }
    try await eventually("held rows") { chat.held.count == 2 }
    let confirmed = coordinators.removal(target)
    await used.holdNextIdentity()
    await routes.set([4002: port, 43187: port])
    coordinators.retryPairing(migrated.id)
    try await eventually("the probe in flight") { await used.identityHeld }
    let removal = Task { try await coordinators.remove(confirmed) }
    try await Task.sleep(for: .milliseconds(200))
    await used.releaseIdentity()
    try await removal.value
    let bound = coordinators.queues.map { $0.coordinator == used.id }
    let folders =
      (try? FileManager.default.contentsOfDirectory(
        atPath: install.support.appending(path: "Agent/HeldQueues").path)) ?? []
    print(
      "IF16-T4-2[\(removing)] Remove's confirmation: \(confirmed.message) | after Remove: saved=\(coordinators.profiles.map { "\($0.name) paired=\($0.pin != nil)" }) held=\(chat.held.map(\.item.text)) bound to the removed coordinator=\(bound) held folders=\(folders.count)"
    )
    #expect(confirmed.message == "No queued messages are on this phone.")
    #expect(bound == [true], "The probe did not bind the queue before Remove ran")
    #expect(
      chat.held.map(\.item.text) == install.queued.map(\.text) && folders.count == 1,
      "Remove deleted held messages its confirmation did not count")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The build before this one paired its migrated profile with Work's coordinator at the build's
/// address, 100.64.1.2:43187, where the build queued nothing, and recorded that as its one
/// `origin`. The user renamed it Work and added Personal at 4002. The single-address build then
/// queued a note for Personal's address, and the build before this one held it in Personal's
/// `Legacy` folder, keeping the origin it had. Personal is not described by that origin, so its
/// note goes to no one until the user chooses: never to Work.
@MainActor @Test(.timeLimit(.minutes(1)))
func aPreviousBuildsOriginGoesOnlyToTheFolderItDescribes() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if16-origin-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let workProfile = ProfileID()
  let personalProfile = ProfileID()
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "origin":{"coordinator":"\(work.id.uuid.uuidString)",\
      "address":{"host":"100.64.1.2","port":43187}},\
      "profiles":[{"address":{"host":"100.64.1.2","port":43187},"id":"\(workProfile)",\
      "name":"Work","pin":"\(work.id.uuid.uuidString)"},\
      {"address":{"host":"100.64.1.2","port":4002},"id":"\(personalProfile)",\
      "name":"Personal","pin":"\(personal.id.uuid.uuidString)"}]}
      """.utf8), to: root.appending(path: "Agent/profiles.json"))
  let note = "Invented note queued for Personal at 4002"
  try writePrivately(
    JSONEncoder().encode([NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: note)]
    ),
    to: ProfileDirectory(personalProfile, applicationSupport: root, caches: root).legacy.appending(
      path: "pending.json"))
  let routes = Routes([43187: workPort, 4002: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
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
    try await eventually("held row") { chat.held.count == 1 }
    let held = try #require(chat.held.first)
    let queue = try #require(coordinators.queues.first { $0.id == held.queue })
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, recipient: chat.recipient)
    await chat.send()
    _ = try await settles { await submitted(work) + submitted(personal) != [] }
    print(
      "IF16-T4-3[this build over the previous build's origin] queue address=\(queue.address.map { "\($0.host):\($0.port)" } ?? "unknown") bound=\(queue.coordinator == work.id ? "Work" : queue.coordinator == personal.id ? "Personal" : "nobody") Restore: draft=\(restored.draft.debugDescription) to=\(restored.recipient.map(chat.name) ?? "nobody") after Send: Work's coordinator got=\(await submitted(work)) Personal's coordinator got=\(await submitted(personal))"
    )
    #expect(queue.coordinator != work.id)
    #expect(restored.recipient != workProfile)
    #expect(await submitted(work).isEmpty, "A note queued for Personal's address went to Work")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The build the fork shipped before this one held the single-address build's first note, queued
/// for 100.64.1.2:43187, from Personal's `Legacy` folder, so its queue took Personal's ID, and bound
/// it to Work, saved at that address. The user had pointed Personal at 4002. Then the single-address
/// build queued a note for 4002, and #9 held it in Personal's `Legacy` folder again and kept that
/// build's `held` list. The list's record for Personal's ID describes the first note, already held,
/// and not this later one, so Restore asks who gets it and nothing goes to Work.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRecordOfAQueueAlreadyHeldGivesNothingToALaterLegacyFolder() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if17-chain-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let workProfile = ProfileID()
  let personalProfile = ProfileID()
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "held":[{"id":"\(personalProfile)","address":{"host":"100.64.1.2","port":43187},\
      "coordinator":"\(work.id.uuid.uuidString)"}],\
      "profiles":[{"address":{"host":"100.64.1.2","port":4002},"id":"\(personalProfile)",\
      "name":"Personal","pin":"\(personal.id.uuid.uuidString)"},\
      {"address":{"host":"100.64.1.2","port":43187},"id":"\(workProfile)",\
      "name":"Work","pin":"\(work.id.uuid.uuidString)"}]}
      """.utf8), to: root.appending(path: "Agent/profiles.json"))
  func queue(_ text: String, in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]),
      to: folder.appending(path: "pending.json"))
  }
  let first = "Invented note queued for Work at 43187"
  let later = "Invented note queued for Personal at 4002"
  try queue(first, in: root.appending(path: "Agent/Held/\(personalProfile)"))
  try queue(
    later, in: ProfileDirectory(personalProfile, applicationSupport: root, caches: root).legacy)
  let routes = Routes([43187: workPort, 4002: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
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
    try await eventually("two held rows") { chat.held.count == 2 }
    let owners = chat.held.map { "\($0.item.text): \(chat.owner($0).map(chat.name) ?? "nobody")" }
    let held = try #require(chat.held.first { $0.item.text == later })
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, recipient: chat.recipient)
    if !chat.draft.isEmpty {
      await chat.send()
      _ = try await settles { await submitted(work) + submitted(personal) != [] }
    }
    print(
      "IF17-S2[a later note in Personal's Legacy folder] owners=\(owners) Restore: draft=\(restored.draft.debugDescription) to=\(restored.recipient.map(chat.name) ?? "nobody") after Send: Work's coordinator got=\(await submitted(work)) Personal's coordinator got=\(await submitted(personal))"
    )
    #expect(owners == ["\(first): Work", "\(later): nobody"])
    #expect(restored.draft.isEmpty && restored.recipient == nil)
    #expect(await submitted(work).isEmpty, "A note queued for Personal's address went to Work")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// The build before this one migrated the single-address build's first launch into the migrated
/// profile's `Legacy` folder. The single-address build ran again and queued another note, and that
/// build left its outbox where it was: at the same address, or at one this phone never saved. This
/// build holds and shows both, the second at the address its outbox is keyed to when this phone
/// knows it, and unknown otherwise.
@MainActor @Test(arguments: ["100.64.1.2", "100.64.9.9"])
func anOutboxAnEarlierBuildLeftIsHeldAtTheAddressItWasQueuedFor(_ host: String) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if16-outbox-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let migrated = ProfileID()
  let installation = UUID().uuidString
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "origin":{"address":{"host":"100.64.1.2","port":43187},"installation":"\(installation)"},\
      "profiles":[{"address":{"host":"100.64.1.2","port":43187},"id":"\(migrated)",\
      "name":"Coordinator"}]}
      """.utf8), to: root.appending(path: "Agent/profiles.json"))
  func queue(_ text: String, in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]),
      to: folder.appending(path: "pending.json"))
  }
  try queue(
    "First launch's note",
    in: ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy)
  try queue("Second launch's note", in: LegacyInstall.outbox(root, host, 43187))
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  let chat = coordinators.chat
  let both = try await settles { chat.held.count == 2 }
  let addresses = coordinators.queues.map {
    $0.address.map { "\($0.host):\($0.port)" } ?? "unknown"
  }
  print(
    "IF16-T4-4[second outbox at \(host)] queues=\(addresses) held=\(chat.held.map(\.item.text)) installation kept=\(coordinators.queues.first?.installation?.description == installation)"
  )
  #expect(both && chat.held.map(\.item.text) == ["First launch's note", "Second launch's note"])
  #expect(addresses == ["100.64.1.2:43187", host == "100.64.1.2" ? "100.64.1.2:43187" : "unknown"])
  #expect(coordinators.queues.first?.installation?.description == installation)
  #expect(
    !FileManager.default.fileExists(atPath: LegacyInstall.outbox(root, host, 43187).path),
    "The second launch's outbox is still where only that build reads")
}

/// Two launches of the single-address build at one address, both migrated by this build, then that
/// address answers: one pairing binds both queues, and both old installations are withdrawn.
@MainActor @Test(.timeLimit(.minutes(1)))
func twoQueuesAtOneAddressBindOnOnePairing() async throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? files.removeItem(at: root) }
  let support = root.appending(path: "Support")
  let suite = "if16-two-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let used = FixtureCoordinator()
  let installations = [UUID().uuidString, UUID().uuidString]
  for installation in installations {
    await used.register(installation, token: String(repeating: "cd", count: 32))
  }
  func singleAddressBuild(_ text: String, _ installation: String) throws {
    defaults.set("100.64.1.2", forKey: "coordinatorAddress")
    defaults.set(installation, forKey: "notificationInstallationID")
    let outbox = LegacyInstall.outbox(support, "100.64.1.2", 43187)
    try files.createDirectory(at: outbox, withIntermediateDirectories: true)
    try JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
    ]).write(to: outbox.appending(path: "pending.json"))
  }
  let offline = CoordinatorTransport { _ in throw ConnectionError.timedOut }
  try singleAddressBuild("First launch's note", installations[0])
  _ = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: support,
    caches: root.appending(path: "Caches"), transport: offline)
  try singleAddressBuild("Second launch's note", installations[1])
  let (listener, port) = try await listen(used)
  defer { listener.cancel() }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: support,
    caches: root.appending(path: "Caches"), transport: loopback(port))
  let chat = coordinators.chat
  await coordinators.setActive(true)
  do {
    try await eventually("paired") { chat.snapshots.values.first?.connection == .connected }
    try await eventually("held rows") { chat.held.count == 2 }
    let owners = chat.held.map { chat.owner($0).map(chat.name) ?? "nobody" }
    let withdrawn = try await settles {
      let first = await used.holds(installations[0])
      let second = await used.holds(installations[1])
      return !first && !second
    }
    print(
      "IF16-T4-5 queues bound=\(coordinators.queues.map { $0.coordinator == used.id }) owners=\(owners) both old installations withdrawn=\(withdrawn)"
    )
    #expect(owners == ["Coordinator", "Coordinator"] && withdrawn)
  } catch {
    await coordinators.setActive(false)
    await used.stop()
    throw error
  }
  await coordinators.setActive(false)
  await used.stop()
}

/// Two held queues carry the single-address build's one alert installation, as after opus's round-18
/// R3 chain: one queued at 100.64.1.2:43187, where Work answers, and one at 4002, where Personal
/// answers. Both coordinators hold that installation. Each queue binds to its own coordinator, and
/// each binding's withdrawal goes to that coordinator alone: Personal's confirmation drops only
/// Personal's record, so while Work answers nothing its record stays, and Work gets its own
/// withdrawal once it answers.
@MainActor @Test(.timeLimit(.minutes(1)))
func eachCoordinatorHoldingTheOldInstallationGetsItsOwnWithdrawal() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if18-r4-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let installation = UUID().uuidString
  for fixture in [work, personal] {
    await fixture.register(installation, token: String(repeating: "ab", count: 32))
  }
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let first = try CoordinatorAddress(host: "100.64.1.2")
  let second = try CoordinatorAddress(host: "100.64.1.2", port: 4002)
  var profiles = [
    CoordinatorProfile(name: try TagName("Work"), address: first),
    CoordinatorProfile(name: try TagName("Personal"), address: second),
  ]
  profiles[0].pin = work.id
  profiles[1].pin = personal.id
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: profiles)),
    to: root.appending(path: "Agent/profiles.json"))
  for (address, text) in [(first, "m1"), (second, "m4")] {
    let queue = HeldQueue(address: address, installation: InstallationID(legacy: installation))
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "\(text): invented")
      ]), to: queue.folder(applicationSupport: root).appending(path: "pending.json"))
    try queue.record(in: queue.folder(applicationSupport: root))
  }
  let routes = Routes([4002: personalPort])
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
      return LineConnection(
        connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
    })
  struct Saved: Decodable { let withdrawals: [PendingWithdrawal] }
  func saved() throws -> [String] {
    let file = root.appending(path: "Agent/profiles.json")
    return try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)).withdrawals.map {
      $0.pin == work.id ? "to Work" : $0.pin == personal.id ? "to Personal" : "?"
    }
  }
  func unregistered(_ fixture: FixtureCoordinator) async -> Int {
    let controls = await fixture.notificationControls()
    return controls.filter { if case .unregister = $0 { true } else { false } }.count
  }
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  do {
    let atLaunch = try saved()
    await coordinators.setActive(true)
    _ = try await settles { (try? saved()) == ["to Work"] }
    let workOffline = (
      saved: try saved(), work: await unregistered(work), personal: await unregistered(personal),
      workHolds: await work.holds(installation), personalHolds: await personal.holds(installation)
    )
    await coordinators.setActive(false)
    await routes.set([43187: workPort, 4002: personalPort])
    await coordinators.setActive(true)
    _ = try await settles { (try? saved())?.isEmpty == true }
    print(
      "IF18-R4 saved withdrawals at launch=\(atLaunch) | Work offline: saved=\(workOffline.saved) unregisters Work=\(workOffline.work) Personal=\(workOffline.personal) still held by Work=\(workOffline.workHolds) Personal=\(workOffline.personalHolds) | Work answering: saved=\(try saved()) unregisters Work=\(await unregistered(work)) still held by Work=\(await work.holds(installation))"
    )
    #expect(atLaunch.sorted() == ["to Personal", "to Work"])
    #expect(workOffline.saved == ["to Work"], "Personal's confirmation dropped Work's record")
    #expect(!workOffline.personalHolds && workOffline.workHolds)
    #expect(try saved().isEmpty)
    #expect(await !work.holds(installation), "Work still holds the old installation")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Opus's round-18 R2. #9 held the single-address build's note m1, queued for 100.64.1.2:43187, in
/// the unpaired profile's `Legacy` folder, and this build adopted it. The user pointed that profile
/// at Personal's address, 4002, and added Work at 43187, which took m1. Work went offline, and the
/// user removed Work, which deleted m1 as its confirmation counted. Then the single-address build
/// queued m2 for 4002, and #9 held it in Personal's `Legacy` folder without saving. Nothing this
/// build knew about the deleted queue reaches m2: it goes to no one until the user chooses.
@MainActor @Test(.timeLimit(.minutes(1)))
func aQueueRemoveDeletedGivesNothingToALaterLegacyFolder() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if18-r2-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let work = FixtureCoordinator()
  let personal = FixtureCoordinator()
  let (workListener, workPort) = try await listen(work)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personal)
  defer { personalListener.cancel() }
  let migrated = ProfileID()
  try writePrivately(
    Data(
      """
      {"withdrawals":[],\
      "origin":{"address":{"host":"100.64.1.2","port":43187},"installation":"\(UUID().uuidString)"},\
      "profiles":[{"address":{"host":"100.64.1.2","port":43187},"id":"\(migrated)",\
      "name":"Coordinator"}]}
      """.utf8), to: root.appending(path: "Agent/profiles.json"))
  let legacy = ProfileDirectory(migrated, applicationSupport: root, caches: root).legacy
  func queue(_ text: String) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]), to: legacy.appending(path: "pending.json"))
  }
  try queue("m1: queued for Work at 43187")
  let routes = Routes([4002: personalPort])
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        guard let port = await routes.port(address.port) else { throw ConnectionError.timedOut }
        return LineConnection(
          connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
      })
  }
  let workAddress = try CoordinatorAddress(host: "100.64.1.2")
  let first = launch()
  try await first.update(
    migrated, name: TagName("Personal"),
    address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  await routes.set([43187: workPort, 4002: personalPort])
  try await first.add(name: TagName("Work"), address: workAddress)
  let removed = try #require(first.profiles.first { $0.pin == work.id })
  await routes.set([4002: personalPort])
  let removal = first.removal(removed.id)
  try await first.remove(removal)
  try queue("m2: queued for Personal at 4002")
  await routes.set([43187: workPort, 4002: personalPort])
  let coordinators = launch()
  let chat = coordinators.chat
  @MainActor func stop() async {
    await coordinators.setActive(false)
    await work.stop()
    await personal.stop()
  }
  await coordinators.setActive(true)
  do {
    try await coordinators.add(name: TagName("Work"), address: workAddress)
    try await eventually("both connected") {
      chat.snapshots.values.filter { $0.connection == .connected }.count == 2
    }
    try await eventually("m2 held") { chat.held.count == 1 }
    let held = try #require(chat.held.first)
    let owner = chat.owner(held).map(chat.name) ?? "nobody"
    let note = chat.heldNote(held)
    await chat.restoreHeld(held)
    let restored = (draft: chat.draft, recipient: chat.recipient)
    if !chat.draft.isEmpty {
      await chat.send()
      _ = try await settles { await submitted(work) + submitted(personal) != [] }
    }
    print(
      "IF18-R2[Work removed offline, then a later note in Personal's Legacy folder] Remove Work? \(removal.message) | m2: owner=\(owner) note=\(note.debugDescription) Restore: draft=\(restored.draft.debugDescription) to=\(restored.recipient.map(chat.name) ?? "nobody") after Send: Work's coordinator got=\(await submitted(work)) Personal's coordinator got=\(await submitted(personal))"
    )
    #expect(removal.message == "This deletes 1 queued message on this phone.")
    #expect(owner == "nobody")
    #expect(restored.draft.isEmpty && restored.recipient == nil)
    #expect(await submitted(work).isEmpty, "A note queued for Personal's address went to Work")
  } catch {
    await stop()
    throw error
  }
  await stop()
}

/// Opus's round-18 R3 and sonnet's round-18 finding 1. The single-address build queued m1 for
/// 100.64.1.2:43187, and this build's migration stopped after `step`. That build then ran again at
/// 4002 and queued m4 there, with its alert installation or a new one. #10 launched, and then this
/// build. Each note is held once, at the address it was queued for, no outbox is left, and each
/// installation is on a queue or a saved withdrawal.
@MainActor
@Test(
  arguments: [Coordinators.MigrationStep.queueNamed, .queueRecorded, .quarantined], [false, true])
func theShippedBuildMovesNoOutboxIntoAQueueAStoppedMigrationNamed(
  _ step: Coordinators.MigrationStep, _ newInstallation: Bool
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if18-r3-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  var installations = [UUID().uuidString]
  func singleAddressBuild(_ text: String, at address: CoordinatorAddress) throws {
    defaults.set(address.host, forKey: "coordinatorAddress")
    defaults.set("\(address.port)", forKey: "coordinatorPort")
    defaults.set(installations.last, forKey: "notificationInstallationID")
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
      ]),
      to: legacyOutbox(for: address, applicationSupport: root).appending(path: "pending.json"))
  }
  try singleAddressBuild(
    "m1: queued at 43187 before the update", at: CoordinatorAddress(host: "100.64.1.2"))
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: defaults, applicationSupport: root, caches: root,
      crash: { if $0 == step { throw Crash() } })
  }
  if newInstallation { installations.append(UUID().uuidString) }
  try singleAddressBuild(
    "m4: queued at 4002 by the reinstalled build",
    at: CoordinatorAddress(host: "100.64.1.2", port: 4002))
  let deleted = try ShippedBuild.launch(defaults: defaults, support: root, caches: root)
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  let shown = try await settles { coordinators.chat.held.count == 2 }
  let held = coordinators.chat.held.map { message in
    let address = coordinators.queues.first { $0.id == message.queue }?.address
    return "\(message.item.text) at \(address.map { "\($0.host):\($0.port)" } ?? "unknown")"
  }.sorted()
  let outboxes =
    (try? FileManager.default.contentsOfDirectory(
      atPath: root.appending(path: "Agent/Outbox").path)) ?? []
  let saved = try JSONDecoder().decode(
    Coordinators.SavedProfiles.self, from: Data(contentsOf: ShippedBuild.file(root)))
  let kept = installations.map { installation in
    coordinators.queues.contains { $0.installation?.description == installation }
      || saved.withdrawals.contains { $0.installation.description == installation }
  }
  print(
    "IF18-R3[stopped after \(step), \(newInstallation ? "a new" : "the same") installation at 4002] #10 deleted=\(deleted.map(\.lastPathComponent)) | this build: held=\(held) outboxes left=\(outboxes.count) installations recorded=\(kept)"
  )
  #expect(
    shown
      && held == [
        "m1: queued at 43187 before the update at 100.64.1.2:43187",
        "m4: queued at 4002 by the reinstalled build at 100.64.1.2:4002",
      ])
  #expect(outboxes.isEmpty, "An outbox the single-address build left is never shown")
  #expect(kept == installations.map { _ in true }, "An alert installation is recorded nowhere")
}

/// Sonnet's round-18 finding 2. This build holds the single-address build's note for
/// 100.64.1.2:43187. That build ran again at the same address with a new alert installation and
/// queued nothing, so the migration keeps that installation in a queue of its own, which holds no
/// message. The migration stops after `step`, #10 launches, and then this build: the installation
/// is still recorded, on a queue or as a saved withdrawal, and the note is still held.
@MainActor @Test(arguments: [Coordinators.MigrationStep.queueNamed, .markerRemoved])
func anAlertInstallationAStoppedMigrationKeptOutlivesTheShippedBuild(
  _ step: Coordinators.MigrationStep
) async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "if18-s2-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  @MainActor func launch() -> Coordinators {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { _ in throw ConnectionError.timedOut })
  }
  defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  defaults.set(UUID().uuidString, forKey: "notificationInstallationID")
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Invented held note")
    ]),
    to: legacyOutbox(for: CoordinatorAddress(host: "100.64.1.2"), applicationSupport: root)
      .appending(path: "pending.json"))
  _ = launch()
  let installation = UUID().uuidString
  defaults.set("100.64.1.2", forKey: "coordinatorAddress")
  defaults.set(installation, forKey: "notificationInstallationID")
  #expect(throws: Crash.self) {
    try Coordinators.migrate(
      defaults: defaults, applicationSupport: root, caches: root,
      crash: { if $0 == step { throw Crash() } })
  }
  let deleted = try ShippedBuild.launch(defaults: defaults, support: root, caches: root)
  let coordinators = launch()
  let shown = try await settles { coordinators.chat.held.count == 1 }
  let saved = try JSONDecoder().decode(
    Coordinators.SavedProfiles.self, from: Data(contentsOf: ShippedBuild.file(root)))
  let kept =
    coordinators.queues.contains { $0.installation?.description == installation }
    || saved.withdrawals.contains { $0.installation.description == installation }
  print(
    "IF18-S2[stopped after \(step)] #10 deleted=\(deleted.map(\.lastPathComponent)) | this build: queues=\(coordinators.queues.map { "\($0.id.uuidString.prefix(8)) installation=\($0.installation.map { "\($0)" == installation ? "the new one" : "the first" } ?? "none")" }) held=\(coordinators.chat.held.map(\.item.text)) the new installation recorded=\(kept)"
  )
  #expect(kept, "The single-address build's alert installation is recorded nowhere")
  #expect(shown, "The held note is gone")
}

/// Where a build the fork shipped deletes or moves what it finds, as a path relative to Application
/// Support or to Caches. `listed` names the profiles `profiles.json` lists, which #9 and #10 keep
/// when they save it:
/// - `Agent/Held`: #10's launch deletes every folder its `held` list does not name, and every #9
///   save drops that list (0d8daa0 `Coordinators.swift:588-590`, ba93f33 `:313-345`).
/// - `Agent/Profiles/<id>`, in both, unless `listed` names it: #2 to #10 delete it at launch
///   (0d8daa0 `Coordinators.swift:584-587`, ba93f33 `:403-416`).
/// - `Agent/Profiles/<id>/Legacy`: #10 moves it into `Agent/Held` (0d8daa0 `Profiles.swift:189-194`).
/// - `Agent/Outbox`: the single-address build sends what it queued there and deletes it, and #2 to
///   #10 move it (3978bb7 `ChatModel.swift:76-82`, ba93f33 `Profiles.swift:212-226`, 0d8daa0
///   `Profiles.swift:254-261`).
/// - `Agent/Previews` in Caches: #2 to #10 delete it while they migrate (ba93f33
///   `Coordinators.swift:390-393`, 0d8daa0 `:538-541`).
private func aShippedBuildDeletes(_ path: String, inCaches: Bool, listed: Set<String>) -> Bool {
  let parts = path.split(separator: "/").map(String.init)
  guard parts.count > 1, parts[0] == "Agent" else { return false }
  switch parts[1] {
  case "Held", "Outbox": return !inCaches
  case "Previews": return inCaches
  case "Profiles":
    return parts.count > 2
      && (!listed.contains(parts[2]) || (parts.count > 3 && parts[3] == "Legacy"))
  default: return false
  }
}

/// A queue's record that a migration writes into the folder it adopts, before that folder moves out
/// of where a build the fork shipped deletes or moves it.
private func isARecordInAnAdoptedFolder(_ path: String) -> Bool {
  let parts = path.split(separator: "/").map(String.init)
  return parts.last == "queue.json"
    && (parts.count == 4 && ["Held", "Outbox"].contains(parts[1])
      || parts.count == 5 && parts[1] == "Profiles" && parts[3] == "Legacy")
}

/// Every file this build writes or moves under Application Support and Caches, since the last look.
@MainActor private struct Writes {
  let support: URL
  let caches: URL
  private var seen: (support: [String: String], caches: [String: String])

  init(support: URL, caches: URL) {
    self.support = support
    self.caches = caches
    seen = (Self.files(under: support), Self.files(under: caches))
  }

  /// Each regular file under `base`, by its path relative to `base`, with what a write or a move
  /// changes: its file number, its modification time and its size.
  private static func files(under base: URL) -> [String: String] {
    let manager = FileManager.default
    var found: [String: String] = [:]
    for path in manager.subpaths(atPath: base.path) ?? [] {
      guard let attributes = try? manager.attributesOfItem(atPath: base.appending(path: path).path),
        attributes[.type] as? FileAttributeType == .typeRegular
      else { continue }
      let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
      found[path] = "\(attributes[.systemFileNumber] ?? 0) \(modified) \(attributes[.size] ?? 0)"
    }
    return found
  }

  /// What was written since the last look where a build the fork shipped deletes or moves it.
  mutating func whereAShippedBuildDeletes() throws -> [String] {
    struct Saved: Decodable {
      struct Profile: Decodable { let id: UUID }
      let profiles: [Profile]
    }
    let file = support.appending(path: "Agent/profiles.json")
    let listed =
      FileManager.default.fileExists(atPath: file.path)
      ? Set(
        try JSONDecoder().decode(Saved.self, from: Data(contentsOf: file)).profiles.map(
          \.id.uuidString)) : []
    let now = (support: Self.files(under: support), caches: Self.files(under: caches))
    defer { seen = now }
    let support = now.support.filter { seen.support[$0.key] != $0.value }.keys.filter {
      aShippedBuildDeletes($0, inCaches: false, listed: listed)
    }
    let caches = now.caches.filter { seen.caches[$0.key] != $0.value }.keys.filter {
      aShippedBuildDeletes($0, inCaches: true, listed: listed)
    }
    return support.sorted() + caches.map { "Caches/\($0)" }.sorted()
  }
}

/// What the builds before this one leave for a migration besides `install`: a note the
/// single-address build queued for another address, a note #9 held in Personal's `Legacy` folder,
/// and a note #10 held in `Agent/Held`, whose list #9 dropped when it saved. Returns every note left.
private func leaveEveryKindOfSource(_ install: LegacyInstall) throws -> [String] {
  func queue(_ text: String, in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode([
        NativeRequestSubmit(inputId: UUID().uuidString, mode: .followUp, text: text)
      ]), to: folder.appending(path: "pending.json"))
  }
  let personal = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
  try queue("Invented note from another launch", in: install.otherOutbox)
  try queue(
    "Invented note an earlier build held",
    in: ProfileDirectory(personal.id, applicationSupport: install.support, caches: install.caches)
      .legacy)
  try queue(
    "Invented note the shipped build held",
    in: install.support.appending(path: "Agent/Held/\(UUID().uuidString)"))
  struct Earlier: Encodable { let profiles: [CoordinatorProfile] }
  try writePrivately(
    JSONEncoder().encode(Earlier(profiles: [personal])),
    to: install.support.appending(path: "Agent/profiles.json"))
  return install.queued.map(\.text) + [
    "Invented note from another launch", "Invented note an earlier build held",
    "Invented note the shipped build held",
  ]
}

/// Nothing this build writes stays where a build the fork shipped deletes or moves it, so neither
/// installing one over this build nor #9 saving before #10 launches reaches a held message. The one
/// exception is a migration stopped while it adopts a folder: the queue's record in that folder,
/// written just before the folder moves out. Checked after a migration stopped at each step, each
/// time it reaches it, and after each change: the launch that migrates every kind of folder,
/// pairing, an edit, adding a coordinator that takes a queue, Restore, Discard, and Remove.
@MainActor @Test(.timeLimit(.minutes(1)))
func nothingThisBuildWritesStaysWhereAShippedBuildDeletesIt() async throws {
  var stops: [String] = []
  for step in [
    Coordinators.MigrationStep.queueNamed, .profileSaved, .queueRecorded, .quarantined,
    .markerRemoved,
  ] {
    for stop in 1... {
      let install = try await LegacyInstall()
      defer { install.remove() }
      let notes = try leaveEveryKindOfSource(install)
      var writes = Writes(support: install.support, caches: install.caches)
      var reached = 0
      var stopped = false
      do {
        _ = try Coordinators.migrate(
          defaults: install.defaults, applicationSupport: install.support, caches: install.caches,
          crash: {
            guard $0 == step else { return }
            reached += 1
            if reached == stop { throw Crash() }
          })
      } catch is Crash { stopped = true }
      let written = try writes.whereAShippedBuildDeletes()
      stops.append(
        "\(step) #\(stop) \(stopped ? "stopped" : "finished") with \(notes.count) notes: written where a shipped build deletes=\(written)"
      )
      #expect(
        written.allSatisfy { stopped && isARecordInAnAdoptedFolder($0) },
        "This build wrote where a shipped build deletes: \(written)")
      if !stopped { break }
    }
  }
  print("IF18-structural stops\n" + stops.joined(separator: "\n"))

  let install = try await LegacyInstall()
  defer { install.remove() }
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(
        inputId: UUID().uuidString, mode: .steer, text: "Invented note from another launch")
    ]), to: install.otherOutbox.appending(path: "pending.json"))
  let shipped = UUID()
  try writePrivately(
    JSONEncoder().encode([
      NativeRequestSubmit(
        inputId: UUID().uuidString, mode: .steer, text: "Invented note the shipped build held")
    ]),
    to: install.support.appending(path: "Agent/Held/\(shipped.uuidString)/pending.json"))
  try writePrivately(
    Data(
      """
      {"profiles":[],"withdrawals":[],"held":[{"id":"\(shipped.uuidString)",\
      "address":{"host":"100.64.1.3","port":43187},"installation":"\(UUID().uuidString)"}]}
      """.utf8), to: install.support.appending(path: "Agent/profiles.json"))
  var writes = Writes(support: install.support, caches: install.caches)
  try await withTheOldAddressSilent(install) { coordinators, migrated, _, _, bringBack in
    let chat = coordinators.chat
    var changes: [String] = []
    @MainActor func check(_ change: String) throws {
      let written = try writes.whereAShippedBuildDeletes()
      changes.append("\(change): written where a shipped build deletes=\(written)")
      #expect(written.isEmpty, "\(change) wrote where a shipped build deletes: \(written)")
    }
    try await eventually("held rows") { chat.held.count == 4 }
    try check("the launch that migrates")
    try await coordinators.update(
      migrated.id, name: TagName("Work"),
      address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    try await eventually("Work connected") {
      chat.snapshots[migrated.id]?.connection == .connected
    }
    try check("the migrated profile edited to Work's address and paired")
    await bringBack()
    try await coordinators.add(name: TagName("Personal"), address: install.address)
    let personal = try #require(coordinators.profiles.last)
    try await eventually("Personal connected") {
      chat.snapshots[personal.id]?.connection == .connected
    }
    try check("Personal added at the build's address, taking its queue")
    let restored = try #require(chat.held.first { $0.item.text == "Second held note" })
    await chat.restoreHeld(restored)
    chat.draft = ""
    chat.recipient = nil
    try check("Restore")
    await chat.discardHeld(restored)
    try check("Discard")
    try await coordinators.remove(coordinators.removal(personal.id))
    try check("Personal removed")
    try await coordinators.remove(coordinators.removal(migrated.id))
    try check("Work removed")
    print("IF18-structural changes\n" + changes.joined(separator: "\n"))
  }
}
