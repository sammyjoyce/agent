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
  /// What the single-address build left, one queue for each launch of it that left something. The
  /// feed keeps the one copy, as it does `profiles`, each queue with the store that reads its folder.
  private(set) var queues: [HeldQueue] {
    get { chat.holds.map(\.queue) }
    set {
      let stores = Dictionary(
        chat.holds.map { ($0.queue.id, $0.store) }, uniquingKeysWith: { first, _ in first })
      chat.holds = newValue.map { queue in
        Hold(
          queue: queue,
          store: stores[queue.id]
            ?? LegacyHold(queue.folder(applicationSupport: applicationSupport)))
      }
    }
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
  @ObservationIgnored private var pairing: [ProfileID: Task<Void, Never>] = [:]
  /// Alert withdrawals `profiles.json` keeps until a coordinator confirms them.
  @ObservationIgnored private var withdrawals: [PendingWithdrawal] = []
  @ObservationIgnored private var withdrawing: [InstallationID: Task<Void, Never>] = [:]
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
      queues = saved.held
      Self.removeUnlisted(saved, applicationSupport: applicationSupport, caches: caches)
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
    if !active {
      for task in Array(pairing.values) + Array(withdrawing.values) { task.cancel() }
      pairing = [:]
      withdrawing = [:]
    }
    await chat.setActive(active)
    guard chat.active else { return }
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
        guard let self, self.chat.active, await !self.pair(id) else { return }
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
        guard try admit(found, for: id, in: &next, at: profile.address) else { return true }
        try save(next, answered: found, at: profile.address)
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
      _ = try admit(found, for: profile.id, in: &next, at: address)
      try save(next, answered: found, at: address)
      chat.attach(lane(next[next.count - 1]))
      if chat.active { await chat.lanes.first { $0.id == profile.id }?.session?.connect() }
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
      if let found { _ = try admit(found, for: id, in: &next, at: address) }
      try save(next, answered: found ?? next[index].pin, at: address)
      guard found != nil, profiles[index].pin != nil else { return }
      await chat.detach(id)
      chat.attach(lane(profiles[index]))
      if chat.active { await chat.lanes.first { $0.id == id }?.session?.connect() }
    }
  }

  /// Remove's confirmation: how many messages it deletes on this phone, queued plus held for its
  /// coordinator. A queue that cannot be read is never counted as empty.
  func removalMessage(_ id: ProfileID) -> String {
    do {
      return switch try directory(id).queuedMessages() {
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
  /// `profiles.json` without it, without the queues held for its coordinator, and with its pending
  /// alert withdrawal, in one write, and a failed save changes nothing else. Only then withdraws
  /// alerts over the still-attached session, retires the lane's session and deletes the profile's
  /// files and those queues. Every other held message stays.
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
        pending.append(
          PendingWithdrawal(installation: InstallationID(id), address: profile.address, pin: pin))
      }
      let held = queues.filter { $0.coordinator != nil && $0.coordinator == profile.pin }
      let kept = queues.filter { queue in !held.contains { $0.id == queue.id } }
      do {
        try save(SavedProfiles(profiles: remaining, withdrawals: pending, held: kept))
      } catch {
        chat.removed[id] = nil
        throw error
      }
      withdrawals = pending
      queues = kept
      // The profile stays until its lane is detached, so the feed still names that lane's rows.
      // The one save before then is given `remaining`.
      if await registration?.forget(id) == true {
        confirmWithdrawal(InstallationID(id), saved: remaining)
      }
      await chat.detach(id)
      pairing.removeValue(forKey: id)?.cancel()
      profiles = remaining
      pairingError[id] = nil
      try directory(id).remove()
      for folder in held.map({ $0.folder(applicationSupport: applicationSupport) })
      where FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
    }
  }

  /// Sends a saved withdrawal again over a socket that proves its pin: at its own address, else at
  /// the first saved address that answers as its coordinator, as after two coordinators trade
  /// addresses. Another coordinator never held this registration, so its answer confirms nothing.
  /// The record goes once its coordinator confirms, or once every one of those addresses answers
  /// as another coordinator, since this phone then knows no way to reach it, as after a reinstall.
  private func retry(_ withdrawal: PendingWithdrawal) {
    let id = withdrawal.installation
    withdrawing.removeValue(forKey: id)?.cancel()
    var addresses = [withdrawal.address]
    for profile in profiles where !addresses.contains(profile.address) {
      addresses.append(profile.address)
    }
    withdrawing[id] = Task { [weak self, transport] in
      var settled = true
      for address in addresses where !Task.isCancelled {
        do {
          settled = try await withdrawal.send(to: address, transport: transport)
          break
        } catch ConnectionError.wrongCoordinator {
          continue
        } catch {
          settled = false
        }
      }
      guard settled, !Task.isCancelled, let self else { return }
      await self.serially { self.confirmWithdrawal(id, saved: self.profiles) }
    }
  }

  /// Drops a confirmed withdrawal's record. If that save fails the record stays, and the next
  /// activation finds nothing left to withdraw.
  private func confirmWithdrawal(_ id: InstallationID, saved profiles: [CoordinatorProfile]) {
    let rest = withdrawals.filter { $0.installation != id }
    do {
      try save(SavedProfiles(profiles: profiles, withdrawals: rest, held: queues))
    } catch { return }
    withdrawals = rest
  }

  /// `CoordinatorProfile.admit`, whose refusal still saves what the probe proved: the socket at
  /// `address` answered as `found`, which may be a saved coordinator.
  private func admit(
    _ found: CoordinatorID, for id: ProfileID, in next: inout [CoordinatorProfile],
    at address: CoordinatorAddress
  ) throws -> Bool {
    do { return try CoordinatorProfile.admit(found, for: id, in: &next) } catch {
      // A save that fails is tried again the next time this address answers.
      try? save(profiles, answered: found, at: address)
      throw error
    }
  }

  /// Saves `next` after a socket at `address` answered as `found`. When a profile in `next` is
  /// pinned to `found`, each queue the single-address build left for `address` that no coordinator
  /// took yet goes to `found`, and its installation's withdrawal is saved in the same write and goes
  /// at once. A coordinator no saved profile is pinned to takes nothing. When nothing changed,
  /// nothing is written.
  private func save(
    _ next: [CoordinatorProfile], answered found: CoordinatorID?, at address: CoordinatorAddress
  ) throws {
    var queues = queues
    var handovers: [PendingWithdrawal] = []
    if let found, next.contains(where: { $0.pin == found }) {
      for index in queues.indices {
        if let handover = queues[index].bind(found, at: address) { handovers.append(handover) }
      }
    }
    guard next != profiles || queues != self.queues else { return }
    let pending = withdrawals + handovers
    try save(SavedProfiles(profiles: next, withdrawals: pending, held: queues))
    profiles = next
    withdrawals = pending
    self.queues = queues
    if chat.active { for handover in handovers { retry(handover) } }
  }

  private func start(_ id: ProfileID) async {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    chat.attach(lane(profile))
    if chat.active { await chat.lanes.first { $0.id == id }?.session?.connect() }
  }

  /// The one place a session is built. Only a pinned profile gets one.
  private func lane(_ profile: CoordinatorProfile) -> Lane {
    let directory = directory(profile.id)
    return Lane(
      id: profile.id,
      session: profile.pin.map {
        CoordinatorSession(
          directory: directory, address: profile.address, pin: $0, stamps: stamps,
          transport: transport)
      })
  }

  /// The profile's paths. Its count of what Remove deletes reads `profiles.json` for the queues
  /// held for its coordinator, so a session's banner and Remove's confirmation agree.
  private func directory(_ id: ProfileID) -> ProfileDirectory {
    ProfileDirectory(id, applicationSupport: applicationSupport, caches: caches) {
      [applicationSupport] in
      try Self.heldCount(for: id, applicationSupport: applicationSupport)
    }
  }

  /// Callers save first and assign after, so memory never runs ahead of disk.
  private func save(_ saved: SavedProfiles) throws {
    if let failure { throw SaveRefused(message: failure) }
    try Self.save(saved, applicationSupport: applicationSupport)
  }
}

// MARK: - profiles.json and migration

extension Coordinators {
  /// What `profiles.json` holds.
  struct SavedProfiles: Codable, Equatable {
    var profiles: [CoordinatorProfile]
    /// Alert withdrawals Remove saved that no coordinator has confirmed yet.
    var withdrawals: [PendingWithdrawal]
    /// What the single-address build left, one queue for each launch of it that left something.
    var held: [HeldQueue]
    /// What an earlier build of this app wrote about the single-address build in place of `held`,
    /// until `migrate` adopts it. Never written.
    var earlier: Earlier?

    private enum CodingKeys: String, CodingKey { case profiles, withdrawals, held }

    init(
      profiles: [CoordinatorProfile], withdrawals: [PendingWithdrawal] = [],
      held: [HeldQueue] = []
    ) {
      self.profiles = profiles
      self.withdrawals = withdrawals
      self.held = held
    }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profiles = try container.decode([CoordinatorProfile].self, forKey: .profiles)
      withdrawals =
        try container.decodeIfPresent([PendingWithdrawal].self, forKey: .withdrawals) ?? []
      if let held = try container.decodeIfPresent([HeldQueue].self, forKey: .held) {
        self.held = held
      } else {
        held = []
        earlier = try Earlier(from: decoder)
      }
    }
  }

  /// What earlier builds of this app wrote about the single-address build. One kept a single
  /// `origin` for its one held queue. One before it kept the build's alert installation on the
  /// migrated profile as `inherited` while that profile was unpaired. The first ones kept neither.
  struct Earlier: Decodable, Equatable {
    struct Origin: Decodable, Equatable {
      let address: CoordinatorAddress
      let coordinator: CoordinatorID?
      let installation: InstallationID?
    }
    let origin: Origin?
    let inherited: [ProfileID: InstallationID]

    private enum CodingKeys: String, CodingKey { case origin, profiles }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      origin = try container.decodeIfPresent(Origin.self, forKey: .origin)
      struct Profile: Decodable {
        let id: ProfileID
        let inherited: InstallationID?
      }
      inherited = Dictionary(
        try container.decode([Profile].self, forKey: .profiles).compactMap { profile in
          profile.inherited.map { (profile.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
  }

  /// Checkpoints after which a test can stop a migration, standing in for a crash.
  enum MigrationStep { case queueNamed, profileSaved, quarantined, markerRemoved }

  /// Names the queue a migration moves the single-address build's outbox into, until it finishes,
  /// so one that stops at any step resumes with the same queue while its move is still to do.
  private static let migratingQueue = "migratingHeldQueue"

  /// Idempotent and offline, at every launch. Adopts what earlier builds of this app held. Then
  /// moves the single-address build's last queue into a held queue of its own, keyed to the address
  /// it was queued for and keeping the build's alert installation, and saves a profile at that
  /// address, named so its `@` tag names it alone. `coordinatorAddress` is the resume marker. It goes before the port key, so a crash in
  /// between cannot re-run with the default port. Last, each queue held for an address that exactly
  /// one saved profile is pinned at goes to that profile's coordinator.
  static func migrate(
    defaults: UserDefaults, applicationSupport: URL, caches: URL,
    crash: (MigrationStep) throws -> Void = { _ in }
  ) throws -> SavedProfiles {
    var saved = try load(applicationSupport: applicationSupport)
    if let earlier = saved.earlier {
      saved.held = adopt(
        earlier, profiles: saved.profiles, applicationSupport: applicationSupport, caches: caches)
      saved.earlier = nil
      try save(saved, applicationSupport: applicationSupport)
    }
    for queue in saved.held {
      try queue.adoptFolder(applicationSupport: applicationSupport, caches: caches)
    }
    if let host = defaults.string(forKey: "coordinatorAddress") {
      try quarantine(
        host: host, into: &saved, defaults: defaults, applicationSupport: applicationSupport,
        caches: caches, crash: crash)
    }
    for key in ["coordinatorPort", "notificationInstallationID", migratingQueue] {
      defaults.removeObject(forKey: key)
    }
    if bindPinned(&saved) { try save(saved, applicationSupport: applicationSupport) }
    return saved
  }

  /// Earlier builds of this app held the single-address build's queue in the migrated profile's
  /// `Legacy` folder. Each saved profile's such folder becomes a queue, keyed to the address it was
  /// queued for when this phone knows it: the one the earlier build recorded, else the profile's own
  /// while it never paired, since only pairing changes a migrated profile's address. A paired one
  /// may have been edited before it paired, so its queue's address is unknown. An installation no
  /// folder took still waits for a coordinator at its address.
  private static func adopt(
    _ earlier: Earlier, profiles: [CoordinatorProfile], applicationSupport: URL, caches: URL
  ) -> [HeldQueue] {
    let holders = profiles.filter {
      FileManager.default.fileExists(
        atPath: ProfileDirectory($0.id, applicationSupport: applicationSupport, caches: caches)
          .legacy.path)
    }
    var origin = earlier.origin
    var queues = holders.map { holder in
      if let installation = earlier.inherited[holder.id] {
        return HeldQueue(adopting: holder.id, address: holder.address, installation: installation)
      }
      if let recorded = origin, holders.count == 1 {
        origin = nil
        return HeldQueue(
          adopting: holder.id, address: recorded.address, coordinator: recorded.coordinator,
          installation: recorded.installation)
      }
      return HeldQueue(
        adopting: holder.id, address: holder.pin == nil ? holder.address : nil, installation: nil)
    }
    if let origin, origin.installation != nil {
      queues.append(
        HeldQueue(
          address: origin.address, coordinator: origin.coordinator,
          installation: origin.installation))
    }
    for profile in profiles where !holders.contains(where: { $0.id == profile.id }) {
      if let installation = earlier.inherited[profile.id] {
        queues.append(HeldQueue(address: profile.address, installation: installation))
      }
    }
    return queues
  }

  /// Moves the single-address build's outbox for its last address into a held queue of its own.
  private static func quarantine(
    host: String, into saved: inout SavedProfiles, defaults: UserDefaults,
    applicationSupport: URL, caches: URL, crash: (MigrationStep) throws -> Void
  ) throws {
    let port = defaults.string(forKey: "coordinatorPort") ?? "43187"
    if let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
      let address = try? CoordinatorAddress(
        host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    {
      let id = try queueToFill(
        for: address, in: saved, defaults: defaults, applicationSupport: applicationSupport)
      defaults.set(id.uuidString, forKey: migratingQueue)
      try crash(.queueNamed)
      var next = saved
      if !next.profiles.contains(where: { $0.address == address }) {
        let name = CoordinatorProfile.unusedName(TagName(defaultFor: address), in: next.profiles)
        next.profiles.append(CoordinatorProfile(name: name, address: address))
      }
      if !next.held.contains(where: { $0.id == id }) {
        // In the same write as the profile, since the installation ID leaves the defaults below.
        next.held.append(
          HeldQueue(
            id: id, address: address,
            installation: defaults.string(forKey: "notificationInstallationID").flatMap(
              InstallationID.init(legacy:))))
      }
      // Saved before the move, so a quarantined queue always has a record pointing at it.
      if next != saved {
        try save(next, applicationSupport: applicationSupport)
        saved = next
      }
      try crash(.profileSaved)
      if let queue = saved.held.first(where: { $0.id == id }) {
        try moveOnce(
          legacyOutbox(for: address, applicationSupport: applicationSupport),
          to: queue.folder(applicationSupport: applicationSupport))
      }
      try crash(.quarantined)
    }
    let previews = caches.appending(path: "Agent/Previews")
    if FileManager.default.fileExists(atPath: previews.path) {
      try FileManager.default.removeItem(at: previews)
    }
    defaults.removeObject(forKey: "coordinatorAddress")
    try crash(.markerRemoved)
  }

  /// The queue this run moves the build's outbox for `address` into: the one a stopped run named
  /// while its move is still to do, else a new one. A stopped run's queue for another address first
  /// gets the move that run started. An outbox at a queue's address after its folder was filled is
  /// one the build queued since, so it gets a new queue.
  private static func queueToFill(
    for address: CoordinatorAddress, in saved: SavedProfiles, defaults: UserDefaults,
    applicationSupport: URL
  ) throws -> UUID {
    guard let named = defaults.string(forKey: migratingQueue).flatMap(UUID.init(uuidString:))
    else { return UUID() }
    guard let queue = saved.held.first(where: { $0.id == named }) else { return named }
    let folder = queue.folder(applicationSupport: applicationSupport)
    guard queue.address == address else {
      if let started = queue.address {
        try moveOnce(legacyOutbox(for: started, applicationSupport: applicationSupport), to: folder)
      }
      return UUID()
    }
    let files = FileManager.default
    let outbox = legacyOutbox(for: address, applicationSupport: applicationSupport)
    return files.fileExists(atPath: folder.path) && files.fileExists(atPath: outbox.path)
      ? UUID() : named
  }

  /// Gives each queue held for an address that exactly one saved profile is pinned at to that
  /// profile's coordinator, with its installation's withdrawal. True when any changed.
  private static func bindPinned(_ saved: inout SavedProfiles) -> Bool {
    let before = saved
    for index in saved.held.indices {
      guard let address = saved.held[index].address else { continue }
      let pins = saved.profiles.filter { $0.address == address }.compactMap(\.pin)
      guard pins.count == 1 else { continue }
      if let handover = saved.held[index].bind(pins[0], at: address) {
        saved.withdrawals.append(handover)
      }
    }
    return saved != before
  }

  /// How many held messages Remove deletes with `id`: those of every queue held for its
  /// coordinator, read from disk.
  nonisolated static func heldCount(for id: ProfileID, applicationSupport: URL) throws -> Int {
    let saved = try load(applicationSupport: applicationSupport)
    guard let pin = saved.profiles.first(where: { $0.id == id })?.pin else { return 0 }
    return try saved.held.filter { $0.coordinator == pin }.reduce(0) {
      try $0 + heldMessages(in: $1.folder(applicationSupport: applicationSupport))
    }
  }

  /// Deletes every profile directory and held queue `profiles.json` does not list, such as the
  /// files of a Remove that stopped after its save. Anything left is deleted at the next launch.
  private static func removeUnlisted(
    _ saved: SavedProfiles, applicationSupport: URL, caches: URL
  ) {
    let files = FileManager.default
    func removeEverything(in parent: URL, except listed: Set<String>) {
      let entries =
        (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
      for entry in entries where !listed.contains(entry.lastPathComponent) {
        try? files.removeItem(at: entry)
      }
    }
    let profiles = Set(saved.profiles.map(\.id.description))
    for base in [applicationSupport, caches] {
      removeEverything(in: base.appending(path: "Agent/Profiles"), except: profiles)
    }
    removeEverything(
      in: applicationSupport.appending(path: "Agent/Held"),
      except: Set(saved.held.map(\.id.uuidString)))
  }

  private nonisolated static func url(_ applicationSupport: URL) -> URL {
    applicationSupport.appending(path: "Agent/profiles.json")
  }

  private nonisolated static func load(applicationSupport: URL) throws -> SavedProfiles {
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
