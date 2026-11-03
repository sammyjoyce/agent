import AgentCore
import Foundation
import Observation

/// Process-scoped owner of saved coordinators: `profiles.json`, the one-time migration from
/// the single-address build, pairing, edits and removal. `AppNotifications` owns it, so a
/// second iPad window cannot build a second session over the same outbox.
@MainActor @Observable
public final class Coordinators {
  /// Saved coordinators in order. The feed keeps the one copy, so its names and lane order
  /// never disagree with `profiles.json`.
  private(set) var profiles: [CoordinatorProfile] {
    get { chat.profiles }
    set { chat.profiles = newValue }
  }
  /// Why an unpaired profile is not paired yet.
  private(set) var pairingError: [ProfileID: String] = [:]
  /// Saved coordinators could not be loaded. Nothing is written over them.
  private(set) var failure: String?
  let chat: ChatModel
  @ObservationIgnored private let applicationSupport: URL
  @ObservationIgnored private let caches: URL
  @ObservationIgnored private let transport: CoordinatorTransport
  @ObservationIgnored private let registration: NotificationRegistration?
  /// One per process, so every coordinator's rows share one receive order.
  @ObservationIgnored private let stamps = StampSource()
  @ObservationIgnored private var active = false
  @ObservationIgnored private var pairing: [ProfileID: Task<Void, Never>] = [:]
  /// Alert withdrawals `profiles.json` keeps until a coordinator confirms them.
  @ObservationIgnored private var withdrawals: [PendingWithdrawal] = []
  @ObservationIgnored private var withdrawing: [ProfileID: Task<Void, Never>] = [:]
  /// True while a profile mutation runs. The ones waiting their turn, in call order.
  @ObservationIgnored private var mutating = false
  @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

  convenience init(registration: NotificationRegistration?, defaults: UserDefaults) {
    self.init(
      registration: registration, defaults: defaults,
      applicationSupport: .applicationSupportDirectory, caches: .cachesDirectory,
      transport: .tailnet)
  }

  /// Migrates first, so no session exists while a legacy queue moves.
  init(
    registration: NotificationRegistration?, defaults: UserDefaults, applicationSupport: URL,
    caches: URL, transport: CoordinatorTransport
  ) {
    self.registration = registration
    self.applicationSupport = applicationSupport
    self.caches = caches
    self.transport = transport
    chat = ChatModel(
      draftStore: AttachmentStore(directory: applicationSupport.appending(path: "Agent/Drafts")),
      registration: registration)
    do {
      let saved = try Self.migrate(
        defaults: defaults, applicationSupport: applicationSupport, caches: caches)
      profiles = saved.profiles
      withdrawals = saved.withdrawals
      Self.removeUnlisted(saved.profiles, applicationSupport: applicationSupport, caches: caches)
    } catch {
      failure =
        "Saved coordinators could not be loaded. Nothing was changed. Reopen Agent to try again. \(error.localizedDescription)"
    }
    for profile in profiles { chat.attach(lane(profile)) }
  }

  /// Every paired coordinator stays connected while the app is active, unpaired ones keep
  /// pairing with backoff, and each unconfirmed alert withdrawal is sent again. Everything
  /// stops when the app is not active.
  public func setActive(_ active: Bool) async {
    self.active = active
    if !active {
      for task in Array(pairing.values) + Array(withdrawing.values) { task.cancel() }
      pairing = [:]
      withdrawing = [:]
    }
    await chat.setActive(active)
    guard self.active else { return }
    for profile in profiles where profile.pin == nil { retryPairing(profile.id) }
    for withdrawal in withdrawals { retry(withdrawal) }
  }

  /// Runs add, edit, pairing and removal one at a time in call order, so none of them sees
  /// another half done and every `profiles.json` save starts from the last one.
  private func serially<T>(_ mutation: () async throws -> T) async rethrows -> T {
    if mutating {
      await withCheckedContinuation { waiting.append($0) }
    } else {
      mutating = true
    }
    defer {
      if waiting.isEmpty { mutating = false } else { waiting.removeFirst().resume() }
    }
    return try await mutation()
  }

  /// Pairs now, then with the sessions' backoff until paired or inactive.
  func retryPairing(_ id: ProfileID) {
    pairing.removeValue(forKey: id)?.cancel()
    pairing[id] = Task { [weak self] in
      var attempt = 0
      while !Task.isCancelled {
        guard let self, self.active, await !self.pair(id) else { return }
        attempt = min(attempt + 1, 5)
        try? await Task.sleep(for: .seconds(1 << attempt))
      }
    }
  }

  /// One attempt: probe, admit, save, then build the session. True once nothing is left to pair.
  private func pair(_ id: ProfileID) async -> Bool {
    await serially {
      guard !Task.isCancelled, let profile = profiles.first(where: { $0.id == id }),
        profile.pin == nil
      else { return true }
      do {
        let found = try await identifyCoordinator(at: profile.address, transport: transport)
        var next = profiles
        guard try CoordinatorProfile.admit(found, for: id, in: &next) else { return true }
        try save(next)
        profiles = next
        pairingError[id] = nil
        await start(id)
        return true
      } catch {
        if !Task.isCancelled { pairingError[id] = error.localizedDescription }
        return false
      }
    }
  }

  /// Probes before saving, so the saved profile is already pinned. A name another coordinator
  /// has, or a coordinator already saved, is refused.
  func add(name: TagName, address: CoordinatorAddress) async throws {
    try await serially {
      try CoordinatorProfile.checkName(name, for: nil, in: profiles)
      let found = try await identifyCoordinator(at: address, transport: transport)
      let profile = CoordinatorProfile(name: name, address: address)
      var next = profiles + [profile]
      _ = try CoordinatorProfile.admit(found, for: profile.id, in: &next)
      try save(next)
      profiles = next
      chat.attach(lane(next[next.count - 1]))
      if active { await chat.lanes.first { $0.id == profile.id }?.session?.connect() }
    }
  }

  /// Probes a new address against the pin before saving anything. A different coordinator
  /// saves nothing. An unpaired profile pairs at the new address.
  func update(_ id: ProfileID, name: TagName, address: CoordinatorAddress) async throws {
    try await serially {
      guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
      try CoordinatorProfile.checkName(name, for: id, in: profiles)
      let found =
        profiles[index].address == address
        ? nil : try await identifyCoordinator(at: address, transport: transport)
      var next = profiles
      next[index].name = name
      next[index].address = address
      if let found { _ = try CoordinatorProfile.admit(found, for: id, in: &next) }
      try save(next)
      profiles = next
      guard found != nil, next[index].pin != nil else { return }
      let hold = chat.lanes.first { $0.id == id }?.hold
      await chat.detach(id)
      chat.attach(lane(next[index], hold: hold))
      if active { await chat.lanes.first { $0.id == id }?.session?.connect() }
    }
  }

  /// Remove's confirmation: how many messages it deletes on this phone, queued plus held. A
  /// queue that cannot be read is never counted as empty.
  func removalMessage(_ id: ProfileID) async -> String {
    let lane = chat.lanes.first { $0.id == id }
    do {
      let queued = try await lane?.session?.queuedCount() ?? 0
      let held = try await lane?.hold.items().count ?? 0
      return switch queued + held {
      case 0: "No queued messages are on this phone."
      case 1: "This deletes 1 queued message on this phone."
      case let count: "This deletes \(count) queued messages on this phone."
      }
    } catch {
      return "Queued messages on this phone could not be read. Removing deletes them."
    }
  }

  /// Refuses while the draft is addressed to or restored from the coordinator. Otherwise marks
  /// it removed, with no await since the check, so nothing addresses it again. Then saves
  /// `profiles.json` without it and with its pending alert withdrawal in one write, and a failed
  /// save changes nothing else. Only then withdraws alerts over the still-attached session,
  /// retires the lane's session and deletes the profile's files.
  func remove(_ id: ProfileID) async throws {
    try await serially {
      guard let profile = profiles.first(where: { $0.id == id }) else { return }
      let name = profile.name.description
      guard !chat.addresses(id) else {
        throw SaveRefused(message: "Send or clear the draft for \(name) first.")
      }
      chat.removed[id] = name
      let remaining = profiles.filter { $0.id != id }
      var pending = withdrawals
      // Only a paired profile ever had a session to enroll alerts over.
      if let pin = profile.pin {
        pending.append(PendingWithdrawal(installation: id, address: profile.address, pin: pin))
      }
      do {
        try save(remaining, withdrawals: pending)
      } catch {
        chat.removed[id] = nil
        throw error
      }
      withdrawals = pending
      if await registration?.forget(id) == true { confirmWithdrawal(id, saved: remaining) }
      await chat.detach(id)
      pairing.removeValue(forKey: id)?.cancel()
      profiles = remaining
      pairingError[id] = nil
      try directory(id).remove()
    }
  }

  /// Sends a saved withdrawal again over a socket that proves its pin. The record goes once the
  /// coordinator confirms, or once the address answers as another coordinator, which never
  /// held this registration.
  private func retry(_ withdrawal: PendingWithdrawal) {
    let id = withdrawal.installation
    withdrawing.removeValue(forKey: id)?.cancel()
    withdrawing[id] = Task { [weak self, transport] in
      let confirmed: Bool
      do {
        confirmed = try await withdrawal.send(transport: transport)
      } catch ConnectionError.wrongCoordinator {
        confirmed = true
      } catch {
        confirmed = false
      }
      guard confirmed, let self else { return }
      await self.serially { self.confirmWithdrawal(id, saved: self.profiles) }
    }
  }

  /// Drops a confirmed withdrawal's record. If that save fails the record stays, and the next
  /// activation finds nothing left to withdraw.
  private func confirmWithdrawal(_ id: ProfileID, saved profiles: [CoordinatorProfile]) {
    let rest = withdrawals.filter { $0.installation != id }
    do { try save(profiles, withdrawals: rest) } catch { return }
    withdrawals = rest
  }

  private func start(_ id: ProfileID) async {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    chat.attach(lane(profile, hold: chat.lanes.first { $0.id == id }?.hold))
    if active { await chat.lanes.first { $0.id == id }?.session?.connect() }
  }

  /// The one place a session is built. Only a pinned profile gets one.
  private func lane(_ profile: CoordinatorProfile, hold: LegacyHold? = nil) -> Lane {
    let directory = directory(profile.id)
    return Lane(
      id: profile.id,
      session: profile.pin.map {
        CoordinatorSession(
          directory: directory, address: profile.address, pin: $0, stamps: stamps,
          transport: transport)
      },
      hold: hold ?? LegacyHold(directory))
  }

  private func directory(_ id: ProfileID) -> ProfileDirectory {
    ProfileDirectory(id, applicationSupport: applicationSupport, caches: caches)
  }

  /// Callers save first and assign after, so memory never runs ahead of disk.
  private func save(
    _ profiles: [CoordinatorProfile], withdrawals: [PendingWithdrawal]? = nil
  ) throws {
    if let failure { throw SaveRefused(message: failure) }
    try Self.save(
      SavedProfiles(profiles: profiles, withdrawals: withdrawals ?? self.withdrawals),
      applicationSupport: applicationSupport)
  }
}

// MARK: - profiles.json and migration

extension Coordinators {
  /// What `profiles.json` holds.
  struct SavedProfiles: Codable, Equatable {
    var profiles: [CoordinatorProfile]
    /// Alert withdrawals Remove saved that no coordinator has confirmed yet.
    var withdrawals: [PendingWithdrawal]

    init(profiles: [CoordinatorProfile], withdrawals: [PendingWithdrawal] = []) {
      self.profiles = profiles
      self.withdrawals = withdrawals
    }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profiles = try container.decode([CoordinatorProfile].self, forKey: .profiles)
      withdrawals =
        try container.decodeIfPresent([PendingWithdrawal].self, forKey: .withdrawals) ?? []
    }
  }

  /// Checkpoints after which a test can stop a migration, standing in for a crash.
  enum MigrationStep { case profileSaved, quarantined, markerRemoved }

  /// One-shot and idempotent, offline. Moves the single-address build's last queue into the
  /// migrated profile's read-only hold. `coordinatorAddress` is the resume marker. It goes
  /// before the port key, so a crash in between cannot re-run with the default port.
  static func migrate(
    defaults: UserDefaults, applicationSupport: URL, caches: URL,
    crash: (MigrationStep) throws -> Void = { _ in }
  ) throws -> SavedProfiles {
    var saved = try load(applicationSupport: applicationSupport)
    guard let host = defaults.string(forKey: "coordinatorAddress") else {
      defaults.removeObject(forKey: "coordinatorPort")
      defaults.removeObject(forKey: "notificationInstallationID")
      return saved
    }
    let port = defaults.string(forKey: "coordinatorPort") ?? "43187"
    if let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
      let address = try? CoordinatorAddress(
        host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    {
      // Saved before the move, so a quarantined queue always has a profile pointing at it.
      let profile: CoordinatorProfile
      if let existing = saved.profiles.first(where: { $0.address == address }) {
        profile = existing
      } else {
        profile = CoordinatorProfile(name: TagName(defaultFor: address), address: address)
        saved.profiles.append(profile)
        try save(saved, applicationSupport: applicationSupport)
      }
      try crash(.profileSaved)
      try quarantineLegacyOutbox(
        for: address,
        into: ProfileDirectory(profile.id, applicationSupport: applicationSupport, caches: caches),
        applicationSupport: applicationSupport)
      try crash(.quarantined)
    }
    let previews = caches.appending(path: "Agent/Previews")
    if FileManager.default.fileExists(atPath: previews.path) {
      try FileManager.default.removeItem(at: previews)
    }
    defaults.removeObject(forKey: "coordinatorAddress")
    try crash(.markerRemoved)
    defaults.removeObject(forKey: "coordinatorPort")
    defaults.removeObject(forKey: "notificationInstallationID")
    return saved
  }

  /// Deletes every profile directory `profiles.json` does not list, such as the files of a
  /// Remove that stopped after its save. Anything left is deleted at the next launch.
  private static func removeUnlisted(
    _ profiles: [CoordinatorProfile], applicationSupport: URL, caches: URL
  ) {
    let listed = Set(profiles.map(\.id.description))
    let files = FileManager.default
    for base in [applicationSupport, caches] {
      let parent = base.appending(path: "Agent/Profiles")
      let directories =
        (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
      for directory in directories where !listed.contains(directory.lastPathComponent) {
        try? files.removeItem(at: directory)
      }
    }
  }

  private static func url(_ applicationSupport: URL) -> URL {
    applicationSupport.appending(path: "Agent/profiles.json")
  }

  private static func load(applicationSupport: URL) throws -> SavedProfiles {
    do {
      return try JSONDecoder().decode(
        SavedProfiles.self, from: Data(contentsOf: url(applicationSupport)))
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return SavedProfiles(profiles: [])
    }
  }

  /// Readable after first unlock, so a launch while locked still knows its coordinators.
  private static func save(_ saved: SavedProfiles, applicationSupport: URL) throws {
    let url = url(applicationSupport)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let data = try JSONEncoder().encode(saved)
    #if os(iOS)
      try data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: url, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    #endif
    var excluded = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try excluded.setResourceValues(values)
  }
}

private struct SaveRefused: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
