import CryptoKit
import Foundation

/// One saved coordinator on this phone. It names the profile's directory and is the
/// installation ID registered with that coordinator only.
public struct ProfileID: Hashable, Sendable, Codable, CustomStringConvertible {
  let uuid: UUID
  public init() { uuid = UUID() }
  init(_ uuid: UUID) { self.uuid = uuid }
  /// A profile ID as another layer wrote it, such as the saved feed scope. nil unless it is a UUID.
  public init?(wire: String) {
    guard let uuid = UUID(uuidString: wire) else { return nil }
    self.uuid = uuid
  }
  public init(from decoder: any Decoder) throws {
    uuid = try decoder.singleValueContainer().decode(UUID.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuid)
  }
  public var description: String { uuid.uuidString }
}

/// A coordinator's persisted `<state-dir>/coordinator-id`, as it named itself on a socket.
/// The coordinator asserts it about itself. It catches a re-pointed name, a port typo or a
/// reinstall, not a hostile peer.
public struct CoordinatorID: Hashable, Sendable, Codable {
  let uuid: UUID
  init(_ uuid: UUID) { self.uuid = uuid }
  init?(wire: String) {
    guard let uuid = UUID(uuidString: wire) else { return nil }
    self.uuid = uuid
  }
  public init(from decoder: any Decoder) throws {
    uuid = try decoder.singleValueContainer().decode(UUID.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuid)
  }
}

/// A coordinator's name: 1 to 32 ASCII letters, digits, `_` or `-`, starting with a letter
/// or digit, so it can later be typed as an `@` tag.
public struct TagName: Hashable, Sendable, Codable, CustomStringConvertible {
  public let description: String

  public init(_ value: String) throws {
    func letterOrDigit(_ byte: UInt8) -> Bool {
      (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
    guard let first = value.utf8.first, letterOrDigit(first), value.utf8.count <= 32,
      value.utf8.allSatisfy({ letterOrDigit($0) || $0 == 95 || $0 == 45 })
    else { throw ProfileError.invalidName }
    description = value
  }

  /// The host's first MagicDNS label when it is a valid name, else "Coordinator".
  public init(defaultFor address: CoordinatorAddress) {
    if !CoordinatorAddress.isTailnetIP(address.host),
      let label = address.host.split(separator: ".").first,
      let name = try? TagName(String(label))
    {
      self = name
    } else {
      description = "Coordinator"
    }
  }

  /// `name` with `-number` after it, shortened to fit 32 characters.
  init(_ name: TagName, numbered number: Int) {
    let suffix = "-\(number)"
    description = String(name.description.prefix(32 - suffix.count)) + suffix
  }

  public init(from decoder: any Decoder) throws {
    try self.init(decoder.singleValueContainer().decode(String.self))
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

public enum ProfileError: Error, LocalizedError, Equatable, Sendable {
  case invalidName
  case duplicateName(String)
  case duplicateCoordinator(savedAs: String)
  /// An edited address answers as a coordinator that no saved profile is pinned to.
  case differentCoordinator
  public var errorDescription: String? {
    switch self {
    case .invalidName:
      "Use up to 32 letters, digits, hyphens or underscores, starting with a letter or digit."
    case .duplicateName(let name): "There is already a coordinator named \(name)."
    case .duplicateCoordinator(let name): "Already saved as \(name)."
    case .differentCoordinator:
      "This address answers as a different coordinator. Nothing was saved."
    }
  }
}

/// The only persisted record of a saved coordinator.
public struct CoordinatorProfile: Codable, Sendable, Identifiable, Equatable {
  public let id: ProfileID
  public var name: TagName
  /// Where to dial. An edit is probed against `pin` before it is saved.
  public var address: CoordinatorAddress
  /// The coordinator every socket must reach. `nil` until paired. Set once, by `admit`.
  public internal(set) var pin: CoordinatorID?

  public init(name: TagName, address: CoordinatorAddress) {
    id = ProfileID()
    self.name = name
    self.address = address
  }

  /// The pairing decision after `identifyCoordinator(at:)`. Returns true when it pinned the
  /// profile, so `profiles` must be saved before any session is built. A refused edit leaves the
  /// profile's saved address working, so its refusal names where the new address leads and never
  /// the lane's advice to remove the profile.
  public static func admit(
    _ found: CoordinatorID, for id: ProfileID, in profiles: inout [CoordinatorProfile]
  ) throws -> Bool {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
    if profiles[index].pin == found { return false }
    if let other = profiles.first(where: { $0.id != id && $0.pin == found }) {
      throw ProfileError.duplicateCoordinator(savedAs: other.name.description)
    }
    guard profiles[index].pin == nil else { throw ProfileError.differentCoordinator }
    profiles[index].pin = found
    return true
  }

  /// Names are unique ignoring case, so an `@` tag names one coordinator.
  public static func checkName(
    _ name: TagName, for id: ProfileID?, in profiles: [CoordinatorProfile]
  ) throws {
    let wanted = name.description.lowercased()
    if let other = profiles.first(where: {
      $0.id != id && $0.name.description.lowercased() == wanted
    }) {
      throw ProfileError.duplicateName(other.name.description)
    }
  }

  /// `name`, else the first of `name-2`, `name-3` and on that `checkName` accepts, for a profile
  /// the app names itself.
  public static func unusedName(_ name: TagName, in profiles: [CoordinatorProfile]) -> TagName {
    var candidate = name
    var number = 1
    while (try? checkName(candidate, for: nil, in: profiles)) == nil {
      number += 1
      candidate = TagName(name, numbered: number)
    }
    return candidate
  }

  /// `profiles` with each name a profile before it has, ignoring case, replaced by the `unusedName`
  /// no other profile has, as an earlier build's migration may have saved. Every other name stays.
  public static func uniquelyNamed(_ profiles: [CoordinatorProfile]) -> [CoordinatorProfile] {
    var named = profiles
    for index in named.indices
    where (try? checkName(named[index].name, for: nil, in: Array(named[..<index]))) == nil {
      named[index].name = unusedName(
        named[index].name, in: named.filter { $0.id != named[index].id })
    }
    return named
  }
}

/// What one launch of the single-address build left: the messages it queued for the coordinator at
/// `address`, held in the queue's own folder, and its alert installation. The build never learned
/// that coordinator's ID, so both belong to the first coordinator this phone proves answers at
/// `address` while a saved profile is pinned to it, whichever profile that is. Each launch's queue
/// keeps its own address and coordinator, whatever a later one left. The folder records the queue
/// itself, so nothing else has to list it, and only a Remove the user confirmed deletes it.
public struct HeldQueue: Codable, Sendable, Equatable, Identifiable {
  /// Names the queue's folder.
  public let id: UUID
  /// Where the build sent these messages, or nil when no build recorded it.
  public let address: CoordinatorAddress?
  /// The coordinator these messages belong to, once one was proven at `address`.
  public private(set) var coordinator: CoordinatorID?
  /// The build's alert installation, until the coordinator takes it as a withdrawal.
  public private(set) var installation: InstallationID?

  public init(
    id: UUID = UUID(), address: CoordinatorAddress?, coordinator: CoordinatorID? = nil,
    installation: InstallationID?
  ) {
    self.id = id
    self.address = address
    self.coordinator = coordinator
    self.installation = installation
  }

  /// Records `found` as this queue's coordinator when it is the first proven at `address`, and
  /// returns the installation's withdrawal to it there. Anywhere else, or later, changes nothing.
  public mutating func bind(_ found: CoordinatorID, at address: CoordinatorAddress)
    -> PendingWithdrawal?
  {
    guard address == self.address, coordinator == nil else { return nil }
    coordinator = found
    defer { installation = nil }
    return installation.map { PendingWithdrawal(installation: $0, address: address, pin: found) }
  }

  /// The queue's messages and their files. No profile's directory holds it, so it outlives any, and
  /// no earlier build of this app reads, writes or deletes anything in `Agent/HeldQueues`.
  public func folder(applicationSupport: URL) -> URL {
    applicationSupport.appending(path: "Agent/HeldQueues/\(id.uuidString)")
  }

  /// The queue an earlier build of this app held in `profile`'s directory. It takes the profile's
  /// ID, so a launch that stops before `adoptFolder` finds that folder again.
  public init(
    adopting profile: ProfileID, address: CoordinatorAddress?, coordinator: CoordinatorID? = nil,
    installation: InstallationID?
  ) {
    self.init(
      id: profile.uuid, address: address, coordinator: coordinator, installation: installation)
  }

  private static func record(in folder: URL) -> URL { folder.appending(path: "queue.json") }

  /// The queue `folder` records, or nil when it records none.
  public static func recorded(in folder: URL) throws -> HeldQueue? {
    do {
      return try JSONDecoder().decode(HeldQueue.self, from: Data(contentsOf: record(in: folder)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
  }

  /// Writes this queue's record into `folder`, creating it. Readable after first unlock, as
  /// `profiles.json` is, so a launch while locked still knows whose each queue is.
  public func record(in folder: URL) throws {
    try writePrivately(
      JSONEncoder().encode(self), to: Self.record(in: folder), readableAfterFirstUnlock: true)
  }

  /// Every queue in `Agent/HeldQueues`, oldest folder first. A folder that records none is a queue
  /// whose address and coordinator are unknown.
  public static func all(applicationSupport: URL) throws -> [HeldQueue] {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: applicationSupport.appending(path: "Agent/HeldQueues"),
        includingPropertiesForKeys: [.creationDateKey])
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    var queues: [(created: Date, queue: HeldQueue)] = []
    for entry in entries {
      guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
      let recorded = try recorded(in: entry)
      queues.append(
        (
          try entry.resourceValues(forKeys: [.creationDateKey]).creationDate ?? .distantPast,
          HeldQueue(
            id: id, address: recorded?.address, coordinator: recorded?.coordinator,
            installation: recorded?.installation)
        ))
    }
    return queues.sorted {
      ($0.created, $0.queue.id.uuidString) < ($1.created, $1.queue.id.uuidString)
    }.map(\.queue)
  }

  /// Records `queue` in `source`, over any record a stopped launch left there, and returns it. A
  /// queue whose folder another source already took gets a new ID first, so every source moves into
  /// a folder of its own.
  public static func name(_ source: URL, as queue: HeldQueue, applicationSupport: URL) throws
    -> HeldQueue
  {
    var named = queue
    if FileManager.default.fileExists(
      atPath: named.folder(applicationSupport: applicationSupport).path)
    {
      named = HeldQueue(
        address: named.address, coordinator: named.coordinator, installation: named.installation)
    }
    if try named != recorded(in: source) { try named.record(in: source) }
    return named
  }

  /// Renames the queue's folder to the name only a deletion reads, and returns that name. A launch
  /// deletes what a Remove marked and did not finish deleting.
  public func markDeleted(applicationSupport: URL) throws -> URL {
    let folder = folder(applicationSupport: applicationSupport)
    let marked = folder.appendingPathExtension("deleted")
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.moveItem(at: folder, to: marked)
    }
    return marked
  }

  /// Deletes every folder a Remove marked. Any other folder stays.
  public static func deleteMarked(applicationSupport: URL) {
    let held = applicationSupport.appending(path: "Agent/HeldQueues")
    let entries =
      (try? FileManager.default.contentsOfDirectory(at: held, includingPropertiesForKeys: nil))
      ?? []
    for entry in entries where entry.pathExtension == "deleted" {
      try? FileManager.default.removeItem(at: entry)
    }
  }
}

/// How many messages a held queue's folder holds, read from disk. A missing file holds none. An
/// unreadable one throws, so it is never counted as empty.
public func heldMessages(in folder: URL) throws -> Int {
  try countItems(NativeRequestSubmit.self, in: folder.appending(path: "pending.json"))
}

private func countItems<Item: Decodable>(_: Item.Type, in file: URL) throws -> Int {
  do {
    return try savedQueue(Item.self, from: Data(contentsOf: file)).count
  } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return 0 }
}

/// Every on-device path of one saved coordinator.
public struct ProfileDirectory: Sendable {
  public let profile: ProfileID
  let root: URL
  let cache: URL
  /// Counts the messages held from before the update that belong to this profile's coordinator.
  /// Their queues live outside this directory, and Remove deletes them with it.
  let held: @Sendable () throws -> Int

  public init(
    _ profile: ProfileID, applicationSupport: URL, caches: URL,
    held: @escaping @Sendable () throws -> Int = { 0 }
  ) {
    self.profile = profile
    root = applicationSupport.appending(path: "Agent/Profiles/\(profile)")
    cache = caches.appending(path: "Agent/Profiles/\(profile)")
    self.held = held
  }

  var outbox: URL { root.appending(path: "Outbox/pending.json") }
  var outboxAttachments: URL { root.appending(path: "Outbox/Attachments") }
  var ledger: URL { root.appending(path: "Ledger.json") }
  /// Where earlier builds of this app held the single-address build's queue, in the migrated
  /// profile's directory. Launch moves it to its `HeldQueue`'s folder.
  public var legacy: URL { root.appending(path: "Legacy") }
  var previews: URL { cache.appending(path: "Previews") }

  /// Every profile directory with a `Legacy` folder, whether `profiles.json` lists it or not.
  public static func holdingLegacy(applicationSupport: URL, caches: URL) -> [ProfileDirectory] {
    let entries =
      (try? FileManager.default.contentsOfDirectory(
        at: applicationSupport.appending(path: "Agent/Profiles"), includingPropertiesForKeys: nil))
      ?? []
    return entries.compactMap { UUID(uuidString: $0.lastPathComponent) }.map {
      ProfileDirectory(ProfileID($0), applicationSupport: applicationSupport, caches: caches)
    }.filter { FileManager.default.fileExists(atPath: $0.legacy.path) }
  }

  /// How many messages Remove deletes on this phone, queued in the outbox or held from before the
  /// update for this profile's coordinator, read from disk. A missing file holds none. An
  /// unreadable one throws, so it is never counted as empty.
  public func queuedMessages() throws -> Int {
    try countItems(OutboxItem.self, in: outbox) + held()
  }

  /// Deletes everything the phone keeps for this profile. Call only after its session is
  /// retired and `profiles.json` no longer lists it.
  public func remove() throws {
    for url in [root, cache] where FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }
}

/// Migration only. The single-address build's outbox for `address`,
/// `Agent/Outbox/<sha256(host:port)>`, which no session reads.
public func legacyOutbox(for address: CoordinatorAddress, applicationSupport: URL) -> URL {
  let key = SHA256.hash(data: Data("\(address.host):\(address.port)".utf8)).map {
    String(format: "%02x", $0)
  }.joined()
  return applicationSupport.appending(path: "Agent/Outbox/\(key)")
}

/// Renames `source` to `destination`. A missing source or an existing destination is a no-op, so
/// a crash at any point converges on the next launch.
public func moveOnce(_ source: URL, to destination: URL) throws {
  let files = FileManager.default
  guard files.fileExists(atPath: source.path), !files.fileExists(atPath: destination.path)
  else { return }
  try files.createDirectory(
    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  try files.moveItem(at: source, to: destination)
}

/// A message queued before the update. Its coordinator was never recorded, so it may
/// already have been delivered, or delivered nowhere.
public struct LegacyItem: Sendable, Identifiable, Equatable {
  public let id: String
  public let text: String
  public let attachments: [AttachmentRef]
  /// The earlier build saved its coordinator's acceptance of it, so a coordinator already holds it
  /// and a restored copy would send it twice.
  public let accepted: Bool
}

/// One input as the single-address build saved it. Its later releases save the coordinator's
/// acceptance beside the request, and a rewrite keeps it.
private struct HeldInput: Codable {
  let request: NativeRequestSubmit
  let deliveryState: String?
  var accepted: Bool { deliveryState == "accepted" }

  private enum CodingKeys: String, CodingKey { case deliveryState }
  init(from decoder: any Decoder) throws {
    request = try NativeRequestSubmit(from: decoder)
    deliveryState = try decoder.container(keyedBy: CodingKeys.self)
      .decodeIfPresent(String.self, forKey: .deliveryState)
  }
  func encode(to encoder: any Encoder) throws {
    try request.encode(to: encoder)
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encodeIfPresent(deliveryState, forKey: .deliveryState)
  }
}

/// A held queue's folder. It has no transport, so a held item can never be sent, retried or
/// observed. Restore copies it into a draft. Only Discard removes it.
public actor LegacyHold {
  private let file: URL
  private let attachments: AttachmentStore

  public init(_ folder: URL) {
    file = folder.appending(path: "pending.json")
    attachments = AttachmentStore(directory: folder.appending(path: "Attachments"))
  }

  /// A missing file holds nothing. An unreadable one throws and stays on disk.
  public func items() throws -> [LegacyItem] {
    try load().map {
      LegacyItem(
        id: $0.request.inputId, text: $0.request.text, attachments: $0.request.attachments ?? [],
        accepted: $0.accepted)
    }
  }

  /// Copies a held item into a draft. An item its coordinator accepted is never copied.
  public func restore(_ id: String, to drafts: AttachmentStore) async throws -> RestoredDraft? {
    guard let held = try load().first(where: { $0.request.inputId == id }), !held.accepted else {
      return nil
    }
    let request = held.request
    var files: [LocalAttachment] = []
    for reference in request.attachments ?? [] {
      files.append(try await drafts.duplicate(attachments.local(reference)))
    }
    return RestoredDraft(copying: request, attachments: files)
  }

  public func discard(_ id: String) async throws {
    var held = try load()
    guard let index = held.firstIndex(where: { $0.request.inputId == id }) else { return }
    let removed = held.remove(at: index).request
    try writePrivately(JSONEncoder().encode(held), to: file)
    let retained = Set(held.flatMap { $0.request.attachments ?? [] }.map(\.id))
    for reference in removed.attachments ?? [] where !retained.contains(reference.id) {
      if let local = try? await attachments.local(reference) {
        try? await attachments.remove(local)
      }
    }
  }

  private func load() throws -> [HeldInput] {
    do {
      return try savedQueue(HeldInput.self, from: Data(contentsOf: file))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
  }
}

/// The items of a queue file. It is a bare array, or, once a composer receipt was saved beside
/// the queue, an object that holds the array as `pending`. The single-address build's later
/// releases wrote the object form too.
private func savedQueue<Item: Decodable>(_: Item.Type, from data: Data) throws -> [Item] {
  if let items = try? JSONDecoder().decode([Item].self, from: data) { return items }
  return try JSONDecoder().decode(SavedQueue<Item>.self, from: data).pending
}
private struct SavedQueue<Item: Decodable>: Decodable { let pending: [Item] }

/// Atomic, readable only by this app, excluded from backup.
func writePrivately(_ data: Data, to url: URL, readableAfterFirstUnlock: Bool = false) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  #if os(iOS)
    try data.write(
      to: url,
      options: [
        .atomic,
        readableAfterFirstUnlock
          ? .completeFileProtectionUntilFirstUserAuthentication : .completeFileProtection,
      ])
  #else
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  #endif
  var url = url
  var values = URLResourceValues()
  values.isExcludedFromBackup = true
  try url.setResourceValues(values)
}
