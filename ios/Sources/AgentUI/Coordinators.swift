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
  /// Records the screen for the coordinator the feed shows. `chat` holds it.
  public var feedbackRecorder: (any FeedbackRecorder)? {
    get { chat.feedbackRecorder }
    set { chat.feedbackRecorder = newValue }
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
  /// One retry per saved withdrawal. Two held queues can carry one installation to two
  /// coordinators, and each coordinator needs its own.
  @ObservationIgnored private var withdrawing: [PendingWithdrawal: Task<Void, Never>] = [:]
  /// True while a profile mutation runs. The ones waiting their turn, in call order.
  @ObservationIgnored private var mutating = false
  @ObservationIgnored private var waiting: [CheckedContinuation<Void, Never>] = []

  /// Migrates first, so no session exists while a legacy queue moves.
  init(
    registration: NotificationRegistration?, defaults: UserDefaults, applicationSupport: URL,
    caches: URL, transport: CoordinatorTransport, persistence: ComposerDraftStore? = nil,
    sharedInbox: SharedDraftInbox? = nil
  ) {
    self.registration = registration
    self.applicationSupport = applicationSupport
    self.caches = caches
    self.transport = transport
    chat = ChatModel(
      draftStore: AttachmentStore(directory: applicationSupport.appending(path: "Agent/Drafts")),
      persistence: persistence, sharedInbox: sharedInbox, registration: registration,
      scope: ScopePreference(defaults: defaults))
    do {
      let stored = try Self.migrate(
        defaults: defaults, applicationSupport: applicationSupport, caches: caches)
      profiles = stored.profiles
      withdrawals = stored.withdrawals
      queues = stored.held
      Self.removeUnlisted(stored.profiles, applicationSupport: applicationSupport, caches: caches)
    } catch {
      failure =
        "Saved coordinators could not be loaded. Nothing was changed. Reopen Beep Boop to try again. \(error.localizedDescription)"
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

  func route(_ origin: AlertOrigin) -> ProfileID? {
    switch origin {
    case .named(let id): return chat.isSaved(id) ? id : nil
    case .unnamed, .malformed: return nil
    }
  }

  func show(opening origin: AlertOrigin) -> String? {
    guard chat.multiple else { return nil }
    if let id = route(origin) {
      chat.show(.one(id))
      return nil
    }
    if origin == .unnamed {
      chat.show(.all)
      return "This notification did not say which coordinator sent it. Showing all."
    }
    return "This notification did not name a saved coordinator."
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
  /// saves nothing. An unpaired profile pairs at the new address. An unchanged address is not
  /// probed, so held queues there go to the profile's pin only as launch gives them, when it is the
  /// only one paired there.
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
      let pinned = next.filter { $0.address == address }.compactMap(\.pin)
      try save(next, answered: found ?? (pinned.count == 1 ? next[index].pin : nil), at: address)
      guard found != nil, profiles[index].pin != nil else { return }
      await chat.detach(id)
      chat.attach(lane(profiles[index]))
      if chat.active { await chat.lanes.first { $0.id == id }?.session?.connect() }
    }
  }

  /// What Remove's confirmation counted: its text, and the queues the single-address build left
  /// that it counted as the coordinator's. Remove deletes those queues and no other.
  struct Removal {
    let profile: ProfileID
    let message: String
    let held: Set<UUID>
  }

  /// Remove's confirmation: how many messages it deletes on this phone, queued plus held for its
  /// coordinator, read from disk. A queue that cannot be read is never counted as empty.
  func removal(_ id: ProfileID) -> Removal {
    let held = (try? Self.heldQueues(for: id, applicationSupport: applicationSupport)) ?? []
    let message =
      switch try? directory(id).queuedMessages() {
      case 0?: "No queued messages are on this phone."
      case 1?: "This deletes 1 queued message on this phone."
      case let count?: "This deletes \(count) queued messages on this phone."
      case nil: "Queued messages on this phone could not be read. Removing deletes them."
      }
    return Removal(profile: id, message: message, held: Set(held.map(\.id)))
  }

  /// Refuses while the draft is addressed to, begun in or restored from the coordinator. Otherwise
  /// marks it removed, with no await since the check, so nothing addresses it again. Then saves
  /// `profiles.json` without it and with its pending alert withdrawal, in one write, and a failed
  /// save changes nothing else. Next it marks the held queues its confirmation counted, so a launch
  /// after a stop from there deletes them. Only then withdraws alerts over the still-attached
  /// session, retires the lane's session and deletes the profile's files and those queues. Every
  /// other held message stays, as does a counted queue whose mark failed.
  func remove(_ confirmed: Removal) async throws {
    try await serially {
      let id = confirmed.profile
      guard let profile = profiles.first(where: { $0.id == id }) else { return }
      let name = profile.name.description
      guard !chat.addresses(id) else {
        throw SaveRefused(message: "Send or clear the draft for \(name) first.")
      }
      chat.removed[id] = name
      let remaining = profiles.filter { $0.id != id }
      var pending = withdrawals
      // Only a paired profile ever had a session to enroll alerts over.
      let withdrawal = profile.pin.map {
        PendingWithdrawal(installation: InstallationID(id), address: profile.address, pin: $0)
      }
      if let withdrawal { pending.append(withdrawal) }
      do {
        try save(SavedProfiles(profiles: remaining, withdrawals: pending))
      } catch {
        chat.removed[id] = nil
        throw error
      }
      withdrawals = pending
      var marked: [UUID: URL] = [:]
      var unmarked: (any Error)?
      for queue in queues where confirmed.held.contains(queue.id) {
        do {
          marked[queue.id] = try queue.markDeleted(applicationSupport: applicationSupport)
        } catch { unmarked = unmarked ?? error }
      }
      queues = queues.filter { marked[$0.id] == nil }
      // The profile stays until its lane is detached, so the feed still names that lane's rows.
      // The one save before then is given `remaining`.
      if await registration?.forget(id) == true, let withdrawal {
        confirmWithdrawal(withdrawal, saved: remaining)
      }
      await chat.detach(id)
      pairing.removeValue(forKey: id)?.cancel()
      profiles = remaining
      pairingError[id] = nil
      try directory(id).remove()
      for folder in marked.values where FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
      if let unmarked { throw unmarked }
    }
  }

  /// Sends a saved withdrawal again over a socket that proves its pin: at its own address, else at
  /// the first saved address that answers as its coordinator, as after two coordinators trade
  /// addresses. Another coordinator never held this registration, so its answer confirms nothing.
  /// The record goes once its coordinator confirms, or once every one of those addresses answers
  /// as another coordinator, since this phone then knows no way to reach it, as after a reinstall.
  private func retry(_ withdrawal: PendingWithdrawal) {
    withdrawing.removeValue(forKey: withdrawal)?.cancel()
    var addresses = [withdrawal.address]
    for profile in profiles where !addresses.contains(profile.address) {
      addresses.append(profile.address)
    }
    withdrawing[withdrawal] = Task { [weak self, transport] in
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
      await self.serially { self.confirmWithdrawal(withdrawal, saved: self.profiles) }
    }
  }

  /// Drops a confirmed withdrawal's record and no other, since another coordinator may hold the
  /// same installation. If that save fails the record stays, and the next activation finds nothing
  /// left to withdraw.
  private func confirmWithdrawal(
    _ withdrawal: PendingWithdrawal, saved profiles: [CoordinatorProfile]
  ) {
    let rest = withdrawals.filter { $0 != withdrawal }
    do {
      try save(SavedProfiles(profiles: profiles, withdrawals: rest))
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
  /// took yet goes to `found`, and its installation's withdrawal goes at once. That withdrawal is
  /// saved with `next` before each queue's record, so a stop in between binds the queue again and
  /// adds no second withdrawal. A coordinator no saved profile is pinned to takes nothing. When
  /// nothing changed, nothing is written.
  private func save(
    _ next: [CoordinatorProfile], answered found: CoordinatorID?, at address: CoordinatorAddress
  ) throws {
    var bound: [HeldQueue] = []
    var handovers: [PendingWithdrawal] = []
    if let found, next.contains(where: { $0.pin == found }) {
      for var queue in queues {
        let before = queue
        if let handover = queue.bind(found, at: address), !withdrawals.contains(handover) {
          handovers.append(handover)
        }
        if queue != before { bound.append(queue) }
      }
    }
    if next != profiles || !handovers.isEmpty {
      let pending = withdrawals + handovers
      try save(SavedProfiles(profiles: next, withdrawals: pending))
      profiles = next
      withdrawals = pending
    }
    for queue in bound {
      try queue.record(in: queue.folder(applicationSupport: applicationSupport))
      queues = queues.map { $0.id == queue.id ? queue : $0 }
    }
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

  /// The profile's paths. Its count of what Remove deletes reads the queues held for its
  /// coordinator from disk, so a session's banner and Remove's confirmation agree.
  private func directory(_ id: ProfileID) -> ProfileDirectory {
    ProfileDirectory(id, applicationSupport: applicationSupport, caches: caches) {
      [applicationSupport] in
      try Self.heldCount(for: id, applicationSupport: applicationSupport)
    }
  }

  /// Callers save first and assign after, so memory never runs ahead of disk.
  private func save(_ saved: SavedProfiles) throws {
    if let failure { throw SaveRefused(message: failure) }
    var saved = saved
    try Self.save(&saved, applicationSupport: applicationSupport)
  }
}

// MARK: - profiles.json and migration

extension Coordinators {
  /// What `profiles.json` holds. Each held queue records itself in its own folder, so a build that
  /// rewrites this file without knowing about held queues loses none of them.
  struct SavedProfiles: Codable, Equatable {
    var profiles: [CoordinatorProfile]
    /// Alert withdrawals that no coordinator has confirmed yet.
    var withdrawals: [PendingWithdrawal]
    /// The queues the build before this one keeps in `Agent/Held`, in its format. That build deletes
    /// every folder there this does not name, so each save names each folder still there, and no
    /// other queue.
    var held: [HeldQueue] = []
    /// What an earlier build of this app wrote about the single-address build, until `migrate`
    /// adopts it. Never written.
    var earlier: Earlier?

    private enum CodingKeys: String, CodingKey { case profiles, withdrawals, held }

    init(profiles: [CoordinatorProfile], withdrawals: [PendingWithdrawal] = []) {
      self.profiles = profiles
      self.withdrawals = withdrawals
    }
    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      profiles = try container.decode([CoordinatorProfile].self, forKey: .profiles)
      withdrawals =
        try container.decodeIfPresent([PendingWithdrawal].self, forKey: .withdrawals) ?? []
      held = try container.decodeIfPresent([HeldQueue].self, forKey: .held) ?? []
      let earlier = try Earlier(from: decoder)
      self.earlier = earlier.isEmpty ? nil : earlier
    }
  }

  /// What this phone keeps for its coordinators: `profiles.json`, and the queues the single-address
  /// build left, from their folders.
  struct Stored: Equatable {
    var profiles: [CoordinatorProfile]
    var withdrawals: [PendingWithdrawal]
    var held: [HeldQueue]
  }

  /// What earlier builds of this app wrote about the single-address build. One kept a single
  /// `origin`. One before it kept the build's alert installation on the migrated profile as
  /// `inherited` while that profile was unpaired. The first ones kept neither.
  struct Earlier: Decodable, Equatable {
    struct Origin: Decodable, Equatable {
      let address: CoordinatorAddress
      let coordinator: CoordinatorID?
      let installation: InstallationID?
    }
    let origin: Origin?
    let inherited: [ProfileID: InstallationID]
    var isEmpty: Bool { origin == nil && inherited.isEmpty }

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
  enum MigrationStep { case queueNamed, profileSaved, queueRecorded, quarantined, markerRemoved }

  /// Idempotent and offline, at every launch. Every folder the single-address build or an earlier
  /// build of this app left messages in becomes a held queue in `Agent/HeldQueues`, where no earlier
  /// build reads, writes or deletes. Each folder records its queue before it moves there, so a stop
  /// at any point resumes. Until a folder the build before this one left in `Agent/Held` moves,
  /// `profiles.json` names it, since that build deletes every folder there the file does not name.
  /// Each saved name is made unique, ignoring case.
  /// The single-address build's outbox for its last address keeps the build's alert installation,
  /// and a profile is saved at that address, named so its `@` tag names it alone.
  /// `coordinatorAddress` is the resume marker. It goes before the port key, so a crash in between
  /// cannot re-run with the default port. Then each queue no coordinator took yet goes to the only
  /// one a saved profile is pinned to at its address.
  static func migrate(
    defaults: UserDefaults, applicationSupport: URL, caches: URL,
    crash: (MigrationStep) throws -> Void = { _ in }
  ) throws -> Stored {
    var saved = try load(applicationSupport: applicationSupport)
    let (adopted, legacy) = try adoptEarlier(
      saved, applicationSupport: applicationSupport, caches: caches)
    let earlier = saved.earlier
    let named = CoordinatorProfile.uniquelyNamed(saved.profiles)
    let shipped = try leftInAgentHeld(listing: saved.held, applicationSupport: applicationSupport)
    if earlier != nil || named != saved.profiles || saved.held != shipped.map(\.queue) {
      saved.earlier = nil
      saved.profiles = named
      try save(&saved, applicationSupport: applicationSupport)
    }
    try hold(legacy, applicationSupport: applicationSupport, crash: crash)
    // One save per move: that build moves the `Legacy` folder of the profile whose ID a listed queue
    // has into that queue's folder, with its record, so a queue stays listed only while it is there.
    for source in shipped {
      try hold([source], applicationSupport: applicationSupport, crash: crash)
      try save(&saved, applicationSupport: applicationSupport)
    }
    if let host = defaults.string(forKey: "coordinatorAddress") {
      try quarantine(
        host: host, into: &saved, held: adopted, defaults: defaults,
        applicationSupport: applicationSupport, caches: caches, crash: crash)
    }
    // migratingHeldQueue: where the build before this one named a queue it was moving.
    for key in ["coordinatorPort", "notificationInstallationID", "migratingHeldQueue"] {
      defaults.removeObject(forKey: key)
    }
    try adoptOutboxes(
      knowing: saved.profiles.map(\.address) + saved.withdrawals.map(\.address)
        + adopted.compactMap(\.address) + [earlier?.origin?.address].compactMap { $0 },
      applicationSupport: applicationSupport, crash: crash)
    var held = try HeldQueue.all(applicationSupport: applicationSupport)
    try bind(&saved, &held, applicationSupport: applicationSupport)
    return Stored(profiles: saved.profiles, withdrawals: saved.withdrawals, held: held)
  }

  /// The held queues, once each `Legacy` folder earlier builds of this app left in a profile's
  /// directory records the queue it becomes, and each alert installation they recorded that no
  /// folder took has a queue of its own. Nothing is saved here, so what those builds wrote stays in
  /// `profiles.json` until each record is on disk. Those `Legacy` folders are returned to be held.
  /// A queue's address is known only where it is proven:
  /// - Only pairing changes an unpaired profile's address, so its `Legacy` folder was queued for it.
  /// - A recorded `origin` is a folder's only when exactly one holder matches it: unpaired at its
  ///   address, or pinned to its coordinator. It wins over the queue a stopped launch recorded in
  ///   that folder, since an earlier build may have paired its coordinator after the stop.
  /// - Any other folder keeps the queue a stopped launch recorded in it.
  /// - Anything else is unknown, and Restore asks.
  /// A queue the build before this one lists describes only its own folder in `Agent/Held`, so it
  /// gives nothing to a `Legacy` folder. Without that folder, only its installation is kept.
  private static func adoptEarlier(
    _ saved: SavedProfiles, applicationSupport: URL, caches: URL
  ) throws -> (held: [HeldQueue], legacy: [(source: URL, queue: HeldQueue)]) {
    let earlier = saved.earlier
    let holders = ProfileDirectory.holdingLegacy(
      applicationSupport: applicationSupport, caches: caches)
    func holder(_ directory: ProfileDirectory) -> CoordinatorProfile? {
      saved.profiles.first { $0.id == directory.profile }
    }
    let origin = earlier?.origin
    let described = holders.filter { directory in
      guard let origin, let holder = holder(directory) else { return false }
      return holder.pin == nil ? holder.address == origin.address : holder.pin == origin.coordinator
    }
    let originHolder = described.count == 1 ? described.first?.profile : nil
    var legacy: [(source: URL, queue: HeldQueue)] = []
    for directory in holders {
      let id = directory.profile
      let queue: HeldQueue
      if let origin, originHolder == id {
        queue = HeldQueue(
          adopting: id, address: origin.address, coordinator: origin.coordinator,
          installation: origin.installation)
      } else {
        let profile = holder(directory)
        queue =
          try HeldQueue.recorded(in: directory.legacy)
          ?? HeldQueue(
            adopting: id, address: profile?.pin == nil ? profile?.address : nil,
            installation: earlier?.inherited[id])
      }
      legacy.append(
        (
          directory.legacy,
          try HeldQueue.name(directory.legacy, as: queue, applicationSupport: applicationSupport)
        ))
    }
    var held = try HeldQueue.all(applicationSupport: applicationSupport) + legacy.map(\.queue)
    var waiting: [HeldQueue] = []
    if let origin, originHolder == nil, let installation = origin.installation {
      waiting.append(
        HeldQueue(
          address: origin.address, coordinator: origin.coordinator, installation: installation))
    }
    for profile in saved.profiles where !holders.contains(where: { $0.profile == profile.id }) {
      if let installation = earlier?.inherited[profile.id] {
        waiting.append(HeldQueue(address: profile.address, installation: installation))
      }
    }
    let shipped = applicationSupport.appending(path: "Agent/Held")
    for queue in saved.held
    where !FileManager.default.fileExists(atPath: shipped.appending(path: "\(queue.id)").path) {
      waiting.append(HeldQueue(address: queue.address, installation: queue.installation))
    }
    for queue in waiting {
      guard let installation = queue.installation,
        !carries(installation, held: held, saved: saved)
      else { continue }
      try queue.record(in: queue.folder(applicationSupport: applicationSupport))
      held.append(queue)
    }
    return (held, legacy)
  }

  /// Each folder the build before this one left in `Agent/Held`, with the queue `profiles.json`
  /// names it as: what `listing` says about it, else what the folder records, else a queue whose
  /// address is unknown. That build named each folder for its queue. The listing wins over what a
  /// stopped launch recorded in the folder, since that build may have bound the queue after the stop.
  private static func leftInAgentHeld(listing: [HeldQueue], applicationSupport: URL) throws
    -> [(source: URL, queue: HeldQueue)]
  {
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: applicationSupport.appending(path: "Agent/Held"), includingPropertiesForKeys: nil)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    return try entries.compactMap { folder in
      guard let id = UUID(uuidString: folder.lastPathComponent) else { return nil }
      let known = try listing.first { $0.id == id } ?? HeldQueue.recorded(in: folder)
      return (
        folder,
        HeldQueue(
          id: id, address: known?.address, coordinator: known?.coordinator,
          installation: known?.installation)
      )
    }
  }

  /// Moves each source into `queue`, recording it in the source first, so the queue's record moves
  /// with its folder.
  private static func hold(
    _ sources: [(source: URL, queue: HeldQueue)], applicationSupport: URL,
    crash: (MigrationStep) throws -> Void
  ) throws {
    for (source, queue) in sources where FileManager.default.fileExists(atPath: source.path) {
      let named = try HeldQueue.name(source, as: queue, applicationSupport: applicationSupport)
      try crash(.queueRecorded)
      try moveOnce(source, to: named.folder(applicationSupport: applicationSupport))
    }
  }

  /// True when a held queue or a saved withdrawal already carries `installation`, so a launch that
  /// stopped after recording it does not record it twice.
  private static func carries(
    _ installation: InstallationID, held: [HeldQueue], saved: SavedProfiles
  ) -> Bool {
    held.contains { $0.installation == installation }
      || saved.withdrawals.contains { $0.installation == installation }
  }

  /// Moves the single-address build's outbox for its last address into a held queue of its own,
  /// with the build's alert installation, and saves a profile at that address. The queue is
  /// recorded in the outbox first, so a stop at any point keeps that installation with it. Without
  /// an outbox, the installation still gets a queue, unless one already carries it.
  private static func quarantine(
    host: String, into saved: inout SavedProfiles, held: [HeldQueue],
    defaults: UserDefaults, applicationSupport: URL, caches: URL,
    crash: (MigrationStep) throws -> Void
  ) throws {
    let port = defaults.string(forKey: "coordinatorPort") ?? "43187"
    if let port = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)),
      let address = try? CoordinatorAddress(
        host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: port)
    {
      var queue = HeldQueue(
        address: address,
        installation: defaults.string(forKey: "notificationInstallationID").flatMap(
          InstallationID.init(legacy:)))
      let outbox = legacyOutbox(for: address, applicationSupport: applicationSupport)
      if FileManager.default.fileExists(atPath: outbox.path) {
        queue = try HeldQueue.name(
          outbox, as: HeldQueue.recorded(in: outbox) ?? queue,
          applicationSupport: applicationSupport)
      } else if let installation = queue.installation,
        !carries(installation, held: held, saved: saved)
      {
        try queue.record(in: queue.folder(applicationSupport: applicationSupport))
      }
      try crash(.queueNamed)
      if !saved.profiles.contains(where: { $0.address == address }) {
        let name = CoordinatorProfile.unusedName(TagName(defaultFor: address), in: saved.profiles)
        saved.profiles.append(CoordinatorProfile(name: name, address: address))
        try save(&saved, applicationSupport: applicationSupport)
      }
      try crash(.profileSaved)
      try hold([(outbox, queue)], applicationSupport: applicationSupport, crash: crash)
      try crash(.quarantined)
    }
    let previews = caches.appending(path: "Agent/Previews")
    if FileManager.default.fileExists(atPath: previews.path) {
      try FileManager.default.removeItem(at: previews)
    }
    defaults.removeObject(forKey: "coordinatorAddress")
    try crash(.markerRemoved)
  }

  /// Every other outbox the single-address build left becomes a held queue once it holds a message,
  /// or once a stopped launch recorded it. It keeps the queue a stopped launch recorded in it, else
  /// its address is the one of `known` whose key names the outbox, else unknown.
  private static func adoptOutboxes(
    knowing known: [CoordinatorAddress], applicationSupport: URL,
    crash: (MigrationStep) throws -> Void
  ) throws {
    let addresses = Dictionary(
      known.map {
        (legacyOutbox(for: $0, applicationSupport: applicationSupport).lastPathComponent, $0)
      }, uniquingKeysWith: { first, _ in first })
    let held = try outboxes(applicationSupport: applicationSupport).filter {
      try HeldQueue.recorded(in: $0) != nil || (try? heldMessages(in: $0)) != 0
    }.map {
      (
        $0,
        try HeldQueue.recorded(in: $0)
          ?? HeldQueue(address: addresses[$0.lastPathComponent], installation: nil)
      )
    }
    try hold(held, applicationSupport: applicationSupport, crash: crash)
  }

  /// Every outbox the single-address build left.
  private static func outboxes(applicationSupport: URL) -> [URL] {
    (try? FileManager.default.contentsOfDirectory(
      at: applicationSupport.appending(path: "Agent/Outbox"), includingPropertiesForKeys: nil))
      ?? []
  }

  /// Gives each queue no coordinator took yet to the only one a saved profile is pinned to at its
  /// address. Each binding's withdrawal is saved first, unless an equal one is saved already, so a
  /// stop before its record is written binds it again and adds no second withdrawal.
  private static func bind(
    _ saved: inout SavedProfiles, _ held: inout [HeldQueue], applicationSupport: URL
  ) throws {
    var bound: [HeldQueue] = []
    for index in held.indices {
      guard let address = held[index].address else { continue }
      let pins = saved.profiles.filter { $0.address == address }.compactMap(\.pin)
      guard pins.count == 1 else { continue }
      let before = held[index]
      if let handover = held[index].bind(pins[0], at: address),
        !saved.withdrawals.contains(handover)
      {
        saved.withdrawals.append(handover)
      }
      if held[index] != before { bound.append(held[index]) }
    }
    guard !bound.isEmpty else { return }
    try save(&saved, applicationSupport: applicationSupport)
    for queue in bound {
      try queue.record(in: queue.folder(applicationSupport: applicationSupport))
    }
  }

  /// The held queues of `id`'s coordinator, read from disk.
  nonisolated static func heldQueues(for id: ProfileID, applicationSupport: URL) throws
    -> [HeldQueue]
  {
    let saved = try load(applicationSupport: applicationSupport)
    guard let pin = saved.profiles.first(where: { $0.id == id })?.pin else { return [] }
    return try HeldQueue.all(applicationSupport: applicationSupport).filter {
      $0.coordinator == pin
    }
  }

  /// How many held messages Remove deletes with `id`: those of every queue held for its
  /// coordinator, read from disk.
  nonisolated static func heldCount(for id: ProfileID, applicationSupport: URL) throws -> Int {
    try heldQueues(for: id, applicationSupport: applicationSupport).reduce(0) {
      try $0 + heldMessages(in: $1.folder(applicationSupport: applicationSupport))
    }
  }

  /// Deletes every profile directory `profiles.json` does not list, such as the files of a Remove
  /// that stopped after its save, and every held folder a Remove marked. A held folder no Remove
  /// marked stays.
  private static func removeUnlisted(
    _ profiles: [CoordinatorProfile], applicationSupport: URL, caches: URL
  ) {
    let files = FileManager.default
    let listed = Set(profiles.map(\.id.description))
    for base in [applicationSupport, caches] {
      let parent = base.appending(path: "Agent/Profiles")
      let entries =
        (try? files.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
      for entry in entries where !listed.contains(entry.lastPathComponent) {
        try? files.removeItem(at: entry)
      }
    }
    HeldQueue.deleteMarked(applicationSupport: applicationSupport)
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

  /// Readable after first unlock, so a launch while locked still knows its coordinators. `held`
  /// becomes each folder still in `Agent/Held`, as `leftInAgentHeld` names it.
  private static func save(_ saved: inout SavedProfiles, applicationSupport: URL) throws {
    saved.held = try leftInAgentHeld(listing: saved.held, applicationSupport: applicationSupport)
      .map(\.queue)
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
