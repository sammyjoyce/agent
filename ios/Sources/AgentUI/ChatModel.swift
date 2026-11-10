import AgentCore
import Foundation
import Observation

#if os(iOS)
  import PhotosUI
  import SwiftUI
#endif

@MainActor @Observable
final class RowModel: Identifiable {
  let id: String
  var row: ChatRow
  /// The coordinator the row came from. nil only for rows seeded without a feed.
  var lane: ProfileID?
  /// For a Send's row: everyone it was addressed to, each with its status.
  var receipts: [Receipt] = []
  init(_ row: ChatRow) {
    id = row.id
    self.row = row
  }
  init(_ feed: FeedRow) {
    id = feed.id
    row = feed.row
    lane = feed.lane
    receipts = feed.receipts
  }
  @discardableResult
  func update(_ feed: FeedRow) -> Bool {
    let changed = row != feed.row || lane != feed.lane || receipts != feed.receipts
    if row != feed.row { row = feed.row }
    if lane != feed.lane { lane = feed.lane }
    if receipts != feed.receipts { receipts = feed.receipts }
    return changed
  }
}

/// One saved coordinator in the feed. `session` is nil until the profile is paired.
struct Lane {
  let id: ProfileID
  let session: CoordinatorSession?
}

/// One queue the single-address build left, and the store that reads its folder.
struct Hold {
  var queue: HeldQueue
  let store: LegacyHold
}

/// A tag typed at the start of the draft that became the chip. The draft went from `typed` to
/// `rest`, which lost the tag and its space from the start.
struct Promotion: Equatable {
  let typed: String
  let rest: String
}

struct HeldMessage: Identifiable, Equatable {
  /// The `HeldQueue` holding it.
  let queue: UUID
  let item: LegacyItem
  var id: String { item.id }
}

/// Where the feed scope is remembered for the device. `Coordinators` passes `UserDefaults`.
/// Inspections and previews keep it in memory.
struct ScopePreference {
  static let key = "feedScope"
  static var memory: ScopePreference { ScopePreference(defaults: nil) }
  let defaults: UserDefaults?

  /// "all", or a profile ID. Anything else loads as All.
  func load() -> FeedScope {
    defaults?.string(forKey: Self.key).flatMap(ProfileID.init(wire:)).map(FeedScope.one) ?? .all
  }
  func save(_ scope: FeedScope) {
    defaults?.set(scope.coordinator?.description ?? "all", forKey: Self.key)
  }
}

/// The one feed and the one composer for every saved coordinator.
@MainActor @Observable
final class ChatModel {
  var rows: [RowModel] = [] {
    didSet { transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems) }
  }
  private(set) var transcriptItems: [TranscriptItem] = []
  /// The feed's aggregate: the best state any lane is in. One coordinator's own state is its
  /// snapshot's.
  var connection: ConnectionState = .disconnected
  /// The model of the first lane that has reported, the header's label with one coordinator saved.
  var model = "Unknown"
  var commands: [SlashCommand] = []
  let inspectedConversation: SavedConversation?
  var busy = false
  var canLoadEarlier = false
  var loadingHistory = false
  var includesLatest = true
  /// What the composer shows under the feed: what it reported since the last Send, its own latest
  /// failure, then, with one coordinator, that coordinator's current error, which has no line of
  /// its own.
  var error: String? {
    let current = multiple ? nil : lanes.lazy.compactMap { self.laneError($0.id) }.first
    let parts = reports + [failure, current].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
  /// What the last Send left out, and why: who did not get it, or the screenshot `/feedback` did not
  /// attach. Only the next Send clears it.
  private(set) var reports: [String] = []
  /// The composer's own latest failure.
  var failure: String?
  var revision = 0
  /// Saved coordinators in order, kept by `Coordinators`. Names, colors and the feed's lane
  /// order come from here.
  var profiles: [CoordinatorProfile] = [] {
    didSet {
      endAnsweredQuestion()
      followScope()
    }
  }
  /// The scope last asked for, as saved. Only `show(_:)` changes it.
  private var requested: FeedScope { didSet { followScope() } }
  @ObservationIgnored private let preference: ScopePreference
  /// The scope `rows` were built for.
  @ObservationIgnored private var projected = FeedScope.all
  /// What the feed shows. It is the request while that names a saved coordinator not being removed
  /// and two or more are saved, else All. It is derived on every read, so Remove has nothing to fix
  /// up.
  var scope: FeedScope { FeedScope.resolve(requested, profiles: profiles, removed: removed) }
  private func followScope() {
    if scope != projected { refresh() }
  }
  /// Where the draft goes when its text does not say. Showing another scope never changes it.
  private(set) var destination: DraftDestination = .open { didSet { draftChanged() } }
  /// The latest tag that became the chip, so the composer moves the caret back by exactly what
  /// the draft lost.
  private(set) var promotion: Promotion?
  /// Coordinators removed in this process, or being removed, by the name they had. Nothing
  /// addresses one again, and profile IDs are never reused.
  var removed: [ProfileID: String] = [:] {
    didSet {
      endAnsweredQuestion()
      followScope()
    }
  }
  /// What the composer holds. A draft changed in code replaces the field's text, composition
  /// included, so all of it is committed.
  var draft = "" {
    didSet {
      if oldValue.isEmpty, attachments.isEmpty, !draft.isEmpty { stampBegun() }
      committed = draft
      forgetClearedSource()
      draftChanged()
    }
  }
  /// Counts every write to the draft's text, files, destination, mode, `restoredFrom`, `source` and
  /// screenshot owners. A Send clears only the draft it admitted, never a newer one with the same
  /// text, and a file action stamps only a draft nothing changed since the action began.
  @ObservationIgnored private var draftRevision = 0
  /// The draft without the text an input method is still composing in the field, and the only text
  /// tags are read from. A composition is tentative until the input method commits it, so it never
  /// picks a recipient or changes the picker before then.
  private(set) var committed = ""
  var attachments: [LocalAttachment] = [] {
    didSet {
      forgetClearedSource()
      draftChanged()
    }
  }
  /// The queues the single-address build left, kept by `Coordinators`, each with the store that
  /// reads its folder. A queue that arrives is read at once.
  var holds: [Hold] = [] {
    didSet {
      let current = Set(holds.map(\.queue.id))
      for id in reads.keys where !current.contains(id) { reads[id] = nil }
      let known = Set(oldValue.map(\.queue.id))
      for hold in holds where !known.contains(hold.queue.id) { Task { await read(hold) } }
      endAnsweredQuestion()
    }
  }
  /// The saved coordinator a held message belongs to: the one its queue went to once this phone
  /// proved it answers at the address the message was queued for. nil until then, and Restore then
  /// asks the user.
  func owner(_ message: HeldMessage) -> ProfileID? {
    guard
      let coordinator = holds.first(where: { $0.queue.id == message.queue })?.queue.coordinator
    else { return nil }
    return profiles.first { $0.pin == coordinator && removed[$0.id] == nil }?.id
  }
  /// The one saved coordinator that everything the feed can show belongs to: every lane's
  /// conversation and every message held from before the update. nil while the feed can show
  /// another coordinator's messages, or held messages this phone cannot name a coordinator for.
  var feedOwner: ProfileID? {
    let owners = Set(lanes.map { ProfileID?.some($0.id) } + held.map(owner))
    guard owners.count == 1, let only = owners.first else { return nil }
    return only
  }
  /// Whom Restore offers for a held message without an owner: every paired coordinator not being
  /// removed.
  var heldChoices: [CoordinatorProfile] {
    profiles.filter { $0.pin != nil && removed[$0.id] == nil }
  }
  /// The held message Restore is asking who should get. Restore asks only about a message with no
  /// owner, and `heldNote` says so, so the question ends once the message gains one, as when its
  /// queue's coordinator pairs, and does not come back if that owner goes.
  private(set) var asking: HeldMessage?
  func stopAsking() { asking = nil }
  /// Runs on each change to `profiles`, `removed` and `holds`, which are what `owner` reads.
  private func endAnsweredQuestion() {
    if let asking, owner(asking) != nil { self.asking = nil }
  }
  /// Why Restore asks who gets a held message, and what a Send to the one chosen leaves. It names
  /// the address the message was queued for only when this phone recorded it, and says no saved
  /// coordinator is paired there only when none is.
  func heldNote(_ message: HeldMessage) -> String {
    let queue = holds.first { $0.queue.id == message.queue }?.queue
    let stays =
      heldChoices.isEmpty
      ? ". Pair a coordinator to send it." : ", so it stays held after you send it."
    guard let address = queue?.address else {
      return "This phone did not record which coordinator it was queued for\(stays)"
    }
    let at = "\(address.host):\(address.port)"
    if queue?.coordinator != nil {
      return "It was queued for a coordinator at \(at) that is no longer saved\(stays)"
    }
    let queued = "It was queued for the coordinator at \(at)."
    if heldChoices.isEmpty { return "\(queued) Pair a coordinator to send it." }
    // Launch binds a queue only when exactly one coordinator is paired at its address.
    return heldChoices.contains { $0.address == address }
      ? "\(queued) This phone cannot tell which saved coordinator that is\(stays)"
      : "\(queued) No saved coordinator is paired there\(stays)"
  }
  /// Messages held from before the update, queue by queue.
  var held: [HeldMessage] {
    holds.flatMap { hold in
      ((try? reads[hold.queue.id]?.get()) ?? []).map {
        HeldMessage(queue: hold.queue.id, item: $0)
      }
    }
  }
  /// The held messages the scope shows. All shows every queue's, and one coordinator's feed shows
  /// only the messages it is proven to own.
  var shownHeld: [HeldMessage] {
    scope.coordinator.map { id in held.filter { owner($0) == id } } ?? held
  }
  /// How many held messages no saved coordinator is proven to own. Only All shows them.
  var unownedHeld: Int { held.filter { owner($0) == nil }.count }
  /// Shown while any queue's held messages could not be read when last loaded.
  var heldError: String? {
    reads.values.contains { if case .failure = $0 { true } else { false } }
      ? "Messages held from before the update could not be read. They stay on this phone." : nil
  }
  /// Each queue's latest read of its messages.
  private var reads: [UUID: Result<[LegacyItem], any Error>] = [:]
  /// The coordinator whose restored message the draft holds. While it is set, no tag in the draft
  /// is read, so the text goes as written. It goes to that coordinator under its chip, and to every
  /// paired coordinator once the chip is removed. Only clearing the draft ends it, and the field's
  /// Undo never reaches back past that.
  private(set) var restoredFrom: ProfileID? { didSet { draftChanged() } }
  /// The original Restore copied into the draft, until the next Send or until the composer is
  /// emptied. A Send that carries it unchanged to its coordinator withdraws it.
  private(set) var source: RestoredSource? { didSet { draftChanged() } }
  /// Each lane's latest published state.
  private(set) var snapshots: [ProfileID: ChatSnapshot] = [:]
  /// Bumped when a lane's session starts to retire and whenever a session attaches. Never reset,
  /// so a value is never reused.
  private(set) var laneEpochs: [ProfileID: Int] = [:]
  /// Each lane's `liveReplies` when it was last shown while the app was active, with the lane epoch
  /// it was read under. A lane's first snapshot under a new epoch sets it, so a new coordinator, a
  /// replaced session or a fresh launch has nothing new.
  private var seen: [ProfileID: (epoch: Int, count: Int)] = [:]
  /// One coordinator's source checks from its current connection, and the warning their gaps raise.
  struct SourceReport: Identifiable, Equatable {
    let id: ProfileID
    let states: [SourceState]
    let warning: String?
  }
  /// Every connected coordinator's latest source checks, in lane order. Coverage belongs to each
  /// coordinator's own connection, so no report speaks for another.
  var sourceReports: [SourceReport] {
    lanes.compactMap { lane in
      snapshots[lane.id].map {
        SourceReport(id: lane.id, states: $0.sources, warning: $0.sourceWarning)
      }
    }
  }
  var previewURL: URL?
  private(set) var preparingAttachments = false
  var mode: InputMode = .steer { didSet { draftChanged() } }
  private(set) var draftReady: Bool
  private(set) var pendingSharedImport = false
  var draftError: String?
  @ObservationIgnored private let persistence: ComposerDraftStore?
  @ObservationIgnored private let sharedInbox: SharedDraftInbox?
  @ObservationIgnored private var persistentRevision: UInt64 = 0
  @ObservationIgnored private var consumedTransfers: Set<UUID> = []
  @ObservationIgnored private var changingDraft = false
  @ObservationIgnored private var restoringDraft = false
  private(set) var admitting = false
  @ObservationIgnored private var draftStore: AttachmentStore?
  /// Draft files that may show a coordinator's feed, by attachment ID, each with the one
  /// coordinator it was captured for.
  @ObservationIgnored private var screenshotOwners: [String: ProfileID] = [:] {
    didSet { draftChanged() }
  }
  @ObservationIgnored private let registration: NotificationRegistration?
  /// Whether the latest `setActive` asked for the app to be active.
  @ObservationIgnored private(set) var active = false
  @ObservationIgnored private(set) var lanes: [Lane] = []
  @ObservationIgnored private var observations: [ProfileID: Task<Void, Never>] = [:]
  /// Inputs of a Send that reached no one, staged at a session that was retired before they could
  /// be withdrawn, by profile. The profile's next session withdraws them once it is attached.
  @ObservationIgnored private var unstaging: [ProfileID: [StagedInput]] = [:]

  init(
    inspecting conversation: SavedConversation? = nil,
    draftStore: AttachmentStore? = nil, persistence: ComposerDraftStore? = nil,
    sharedInbox: SharedDraftInbox? = nil, registration: NotificationRegistration? = nil,
    scope preference: ScopePreference = .memory
  ) {
    inspectedConversation = conversation
    self.draftStore = draftStore
    self.persistence = persistence
    self.sharedInbox = sharedInbox
    draftReady = persistence == nil
    self.registration = registration
    self.preference = preference
    requested = preference.load()
  }
  deinit {
    for observation in observations.values { observation.cancel() }
    let sessions = lanes.compactMap(\.session)
    Task { for session in sessions { await session.disconnect() } }
  }

  private var currentDraft: ComposerDraft {
    let shot = attachments.first { screenshotOwners[$0.id] != nil }
    return ComposerDraft(
      text: draft, mode: mode, attachments: attachments, consumedTransfers: consumedTransfers,
      feedbackScreenshotID: shot?.id,
      addressing: DraftAddressing(
        destination: destination, restoredFrom: restoredFrom,
        screenshotOwner: shot.flatMap { screenshotOwners[$0.id] }, source: source))
  }
  /// Whom the draft is for, as it would be saved.
  var draftAddressing: DraftAddressing { currentDraft.addressing }
  private func draftChanged() {
    draftRevision &+= 1
    scheduleDraftSave()
  }
  private func scheduleDraftSave() {
    guard draftReady, !changingDraft, let persistence else { return }
    persistentRevision &+= 1
    let revision = persistentRevision
    let value = currentDraft
    Task { [weak self] in
      do { try await persistence.save(value, revision: revision) } catch {
        if self?.persistentRevision == revision { self?.draftError = error.localizedDescription }
      }
    }
  }
  private func persistDraft() async throws {
    guard let persistence else { return }
    guard draftReady else { throw SharedDraftError.busy }
    persistentRevision &+= 1
    try await persistence.save(currentDraft, revision: persistentRevision)
  }
  @discardableResult func saveDraft() async -> Bool {
    do {
      try await persistDraft()
      draftError = nil
      return true
    } catch {
      draftError = error.localizedDescription
      return false
    }
  }
  func restoreDraft() async {
    guard !draftReady, !restoringDraft, let persistence else { return }
    restoringDraft = true
    defer { restoringDraft = false }
    let revision = draftRevision
    do {
      let restored = try await persistence.load(from: attachmentStore())
      guard draftRevision == revision, draft.isEmpty, attachments.isEmpty else {
        throw AttachmentError.unavailable(
          "The saved draft was preserved. Clear the current composer before restoring it.")
      }
      changingDraft = true
      draft = restored.draft.text
      mode = restored.draft.mode
      attachments = restored.draft.attachments
      consumedTransfers = restored.draft.consumedTransfers
      // Last, since the text's and files' didSet drops a restored source while both are empty.
      adopt(restored.draft)
      persistentRevision = restored.revision
      changingDraft = false
      draftReady = true
      pendingSharedImport = !consumedTransfers.isEmpty
      _ = await saveDraft()
      guard sharedInbox != nil || consumedTransfers.isEmpty else {
        throw SharedDraftError.notConfigured
      }
      await receiveSharedDrafts()
    } catch { draftError = error.localizedDescription }
  }
  /// Restores whom the saved draft is for. A chip, stamp or source coordinator not saved now,
  /// whether removed earlier or not loaded, is marked removed, so Send blocks instead of reaching
  /// another.
  private func adopt(_ saved: ComposerDraft) {
    let addressing = saved.addressing
    let named = [addressing.destination.coordinator, addressing.restoredFrom].compactMap { $0 }
    for id in named where !profiles.contains(where: { $0.id == id }) {
      removed[id] = removed[id] ?? "A coordinator"
    }
    screenshotOwners = [:]
    // Only a draft saved before owners were stored lacks one. With one coordinator saved it can
    // only be that one's. Otherwise it belongs to none, so Send refuses it for every coordinator
    // until the screenshot is removed.
    if let id = saved.feedbackScreenshotID {
      screenshotOwners[id] =
        addressing.screenshotOwner ?? (profiles.count == 1 ? profiles[0].id : ProfileID())
    }
    source = addressing.source
    restoredFrom = addressing.restoredFrom
    destination = addressing.destination
  }
  func receiveSharedDrafts() async {
    guard draftReady, !preparingAttachments, !admitting, let sharedInbox, persistence != nil else {
      return
    }
    preparingAttachments = true
    defer { preparingAttachments = false }
    do {
      let store = try attachmentStore()
      try await retireAcknowledgedTransfers(in: sharedInbox)
      // One activation must not drain an unbounded queue or overfill the composer.
      for _ in 0..<AttachmentLimits.maximumCount {
        let consumed = try await sharedInbox.consumeNext(into: store) { [self] batch in
          try await adoptSharedDraft(batch)
        }
        guard consumed else { break }
        // Only acknowledged IDs may leave the durable host ledger. A crash
        // before this cleanup is harmless and is reconciled on next launch.
        try await retireAcknowledgedTransfers(in: sharedInbox)
      }
      draftError = nil
    } catch {
      if !(error is CancellationError) { draftError = error.localizedDescription }
    }
  }
  private func retireAcknowledgedTransfers(in inbox: SharedDraftInbox) async throws {
    let acknowledged = consumedTransfers.filter { inbox.acknowledged($0) }
    consumedTransfers.subtract(acknowledged)
    pendingSharedImport = !consumedTransfers.isEmpty
    if !acknowledged.isEmpty { try await persistDraft() }
  }
  private func adoptSharedDraft(_ batch: SharedDraftBatch) async throws {
    if !consumedTransfers.contains(batch.id) {
      guard batch.attachments.count <= AttachmentLimits.maximumCount - attachments.count else {
        throw AttachmentError.tooMany
      }
      changingDraft = true
      if !batch.note.isEmpty { draft += (draft.isEmpty ? "" : "\n\n") + batch.note }
      attachments.append(contentsOf: batch.attachments)
      consumedTransfers.insert(batch.id)
      changingDraft = false
    }
    pendingSharedImport = true
    // This complete atomic record, including the UUID, must reach disk before
    // SharedDraftInbox is allowed to acknowledge or delete the source batch.
    try await persistDraft()
  }

  /// True with two or more saved coordinators, when the feed names them and the composer
  /// addresses them.
  var multiple: Bool { profiles.count > 1 }
  /// True while the composer names who gets the draft: with two or more saved coordinators, or
  /// once one was removed. With one saved and none removed it works as on `main`.
  var addressesByName: Bool { multiple || !removed.isEmpty }
  /// True while the feed names coordinators, with two or more saved and All shown. It never gates
  /// the composer, which reads `multiple` and `addressesByName`.
  var namesLanes: Bool { multiple && scope == .all }
  /// The chip the composer draws while the composer names recipients. With one coordinator saved
  /// and none removed none is drawn, as on `main`, though a restored draft keeps its chip, so it
  /// stays its source's when another coordinator is added.
  var shownChip: ProfileID? { addressesByName ? destination.chip : nil }

  /// Addresses the draft to `id` alone and keeps its text, as "Address to Work only" does. A
  /// coordinator no longer saved blocks Send as a stale chip does. While a Send is admitting it
  /// changes nothing.
  func setChip(_ id: ProfileID) {
    guard !admitting else { return }
    destination = .chip(id)
  }

  /// The chip's ⓧ. The draft goes to every coordinator, as its hint says, and a restored draft's
  /// text stays literal. While a Send is admitting the chip stays, since a changed draft would keep
  /// the sent text in the composer.
  func removeChip() {
    guard !admitting, case .chip = destination else { return }
    destination = .open
  }

  /// Shows a scope and saves it for the device, with fresh rows. It changes no draft, lane or
  /// session.
  func show(_ scope: FeedScope) {
    guard scope != requested else { return }
    requested = scope
    preference.save(scope)
  }

  func name(_ id: ProfileID) -> String {
    profiles.first { $0.id == id }?.name.description ?? removed[id] ?? "Coordinator"
  }

  func paired(_ id: ProfileID) -> Bool { lanes.first { $0.id == id }?.session != nil }

  func laneEpoch(_ id: ProfileID) -> Int { laneEpochs[id] ?? 0 }

  /// For the UI: whether `id` is saved and not being removed.
  func isSaved(_ id: ProfileID) -> Bool {
    removed[id] == nil && profiles.contains { $0.id == id }
  }

  /// `base` led by the coordinator's name while several are saved, as in "Work · Jobs and work".
  func laneTitle(_ base: String, for id: ProfileID) -> String {
    multiple ? "\(name(id)) · \(base)" : base
  }

  /// A coordinator's line under the feed and in Settings. When its address answers as another
  /// saved coordinator, the line names that one and points to this one's address, since editing
  /// it keeps the queue that Remove would delete.
  func laneError(_ id: ProfileID) -> String? {
    guard let snapshot = snapshots[id] else { return nil }
    guard let found = snapshot.answeredAs,
      let other = profiles.first(where: { $0.id != id && $0.pin == found })
    else { return snapshot.error }
    return "This address now answers as \(other.name). Edit \(name(id))'s address."
  }

  /// Every saved coordinator's news, in profile order, for whichever switcher is drawn.
  var news: [LaneNews] {
    let owners = held.map(owner)
    return profiles.map { profile in
      let id = profile.id
      let count = snapshots[id]?.liveReplies ?? 0
      return LaneNews(
        id: id, unseen: max(0, count - (seen[id]?.count ?? count)), attention: attention(id),
        held: owners.filter { $0 == id }.count)
    }
  }

  private func attention(_ id: ProfileID) -> LaneNews.Attention? {
    guard paired(id) else { return .notPaired }
    guard let snapshot = snapshots[id] else { return nil }
    if let error = laneError(id) { return .error(error) }
    return snapshot.connection == .disconnected ? .notConnected : nil
  }

  /// Adds a saved coordinator's lane, or replaces an unpaired lane with its paired one.
  /// A lane whose session was live must be detached first, so two sessions never share
  /// an outbox. A removed coordinator gets none. Connecting is `setActive`'s job.
  func attach(_ lane: Lane) {
    guard removed[lane.id] == nil else { return }
    observations.removeValue(forKey: lane.id)?.cancel()
    if let index = lanes.firstIndex(where: { $0.id == lane.id }) {
      lanes[index] = lane
    } else {
      // Lanes keep profile order, the feed's tiebreak between equal receive times.
      let rank = { (id: ProfileID) in self.profiles.firstIndex { $0.id == id } ?? .max }
      lanes.insert(
        lane, at: lanes.firstIndex { rank($0.id) > rank(lane.id) } ?? lanes.endIndex)
    }
    if let session = lane.session {
      snapshots[lane.id] = nil
      laneEpochs[lane.id, default: 0] += 1
      refresh()
      observations[lane.id] = observe(session, lane: lane.id)
      if let inputs = unstaging.removeValue(forKey: lane.id) {
        Task { for input in inputs { await withdraw(input, from: session, lane: lane.id) } }
      }
    }
  }

  /// Retires the lane's session, then drops the lane. Every session that is not in a lane is
  /// retired, so nothing connects, sends or writes the profile's directory through it again. The
  /// composer names what the retirement cancelled before it left the phone.
  func detach(_ id: ProfileID) async {
    if lanes.contains(where: { $0.id == id && $0.session != nil }) {
      laneEpochs[id, default: 0] += 1
    }
    let cancelled = await lanes.first { $0.id == id }?.session?.retire() ?? []
    if let index = lanes.firstIndex(where: { $0.id == id }) {
      let lane = lanes.remove(at: index)
      observations.removeValue(forKey: id)?.cancel()
      registration?.disconnect(id)
      if lane.session != nil {
        snapshots[id] = nil
        if !multiple { failure = nil }
        refresh()
      }
    }
    report(cancelled.compactMap { input in missed(id, input, .retired).map { (id, input, $0) } })
  }

  /// Connects every lane while the app is active and disconnects every lane while it is not. Each
  /// step reads the latest request and the lanes again after every await, so an older call that
  /// finishes last never undoes a newer one, and a lane detached meanwhile is skipped.
  func setActive(_ active: Bool) async {
    self.active = active
    for id in lanes.map(\.id) {
      guard let session = lanes.first(where: { $0.id == id })?.session else { continue }
      if self.active { await session.connect() } else { await session.disconnect() }
    }
  }

  /// "Try again": reconnects now instead of waiting out the backoff, one lane or every lane
  /// that is not connected.
  func reconnect(_ id: ProfileID? = nil) async {
    for lane in lanes.map(\.id) where id == lane || (id == nil && !connected(lane)) {
      await lanes.first { $0.id == lane }?.session?.connect()
    }
  }

  private func observe(_ session: CoordinatorSession, lane id: ProfileID) -> Task<Void, Never> {
    Task { [weak self] in
      var connected = false
      for await update in session.updates {
        guard !Task.isCancelled, let self else { return }
        self.apply(update, lane: id)
        guard (update.connection == .connected) != connected else { continue }
        connected.toggle()
        // Only this lane's own session carries its installation ID.
        if !connected {
          self.registration?.disconnect(id)
        } else if let registration = self.registration {
          Task { await registration.connect(session.notificationChannel) }
        }
      }
    }
  }

  private func connected(_ id: ProfileID) -> Bool { snapshots[id]?.connection == .connected }

  // MARK: - Conversation settings and Jobs and work, each on one coordinator

  /// The one way a lane control reaches a session. It runs `run` once and retries nothing, and
  /// nothing comes back from a session that changed under the call.
  func onLane<T>(_ id: ProfileID, _ run: (CoordinatorSession) async throws -> T) async throws -> T {
    if let name = removed[id] { throw LaneError.gone(name) }
    guard let lane = lanes.first(where: { $0.id == id }) else { throw LaneError.gone(name(id)) }
    guard let session = lane.session else { throw LaneError.notPaired(name(id)) }
    let epoch = laneEpoch(id)
    let value: T
    do { value = try await run(session) } catch {
      if let name = removed[id] { throw LaneError.gone(name) }
      // A session throws CancellationError when its connection is cut mid-request. Only this
      // task's own cancellation stays one.
      if laneEpoch(id) != epoch || (error is CancellationError && !Task.isCancelled) {
        throw LaneError.interrupted(name(id))
      }
      throw error
    }
    guard laneEpoch(id) == epoch else { throw LaneError.interrupted(name(id)) }
    return value
  }
  /// Opens this inspection on `owner`'s coordinator `id`, over a read-only session that the
  /// coordinator's own session mints and ends.
  func connectInspection(using owner: ChatModel, lane id: ProfileID) async {
    guard let conversation = inspectedConversation, lanes.isEmpty else {
      failure = ConnectionError.closed.localizedDescription
      return
    }
    do {
      let minted = try await owner.onLane(id) { await $0.inspector(conversation) }
      guard let inspector = minted else { throw ConnectionError.closed }
      profiles = owner.profiles.filter { $0.id == id }
      lanes = [Lane(id: id, session: inspector)]
      snapshots[id] = nil
      observations[id] = observe(inspector, lane: id)
      if owner.active { await inspector.connect() }
    } catch { failure = error.localizedDescription }
  }
  /// Keeps an inspection connected until the task that owns it is cancelled.
  func runUntilCancelled() async {
    let lifetime = AsyncStream<Void> { _ in }
    for await _ in lifetime {}
    for observation in observations.values { observation.cancel() }
    observations = [:]
    let sessions = lanes.compactMap(\.session)
    lanes = []
    connection = .disconnected
    for session in sessions { await session.retire() }
  }
  func jobs(_ id: String? = nil, lane: ProfileID) async throws -> NativeJobStatus {
    try await onLane(lane) { try await $0.jobs(id) }
  }
  func retryJob(_ id: String, lane: ProfileID) async throws -> ScheduledJobStatus {
    try await onLane(lane) { try await $0.retryJob(id) }
  }
  func conversations(query: String = "", cursor: String? = nil, lane: ProfileID) async throws
    -> NativeEventConversations
  {
    try await onLane(lane) { try await $0.conversations(query: query, cursor: cursor) }
  }
  /// Reads the lane's conversation settings, or changes them. The value lands in the lane's
  /// snapshot through its session's own publish.
  func settings(change: ConversationChange? = nil, lane: ProfileID) async throws {
    _ = try await onLane(lane) { try await $0.settings(change: change) }
  }

  // MARK: - Addressing

  /// Who Send reaches with the current draft from the scope shown, or why it does not.
  var addressing: Addressing {
    address(draft, hasAttachments: !attachments.isEmpty, destination: destination, in: scope)
  }

  /// True while the draft is the coordinator's. That is while the coordinator is its chip, the
  /// draft began in its conversation or was restored from it, or a typed tag with its name leads it.
  func addresses(_ id: ProfileID) -> Bool {
    if destination.coordinator == id || restoredFrom == id { return true }
    guard destination.chip == nil, restoredFrom == nil,
      let name = profiles.first(where: { $0.id == id })?.name.description
    else { return false }
    return Addressing.leadingTags(draft).tags.contains { $0.lowercased() == name.lowercased() }
  }

  /// Parses the draft over every coordinator not removed, then applies the veto of the scope shown.
  /// An empty composer with no chip or stamp in one coordinator's feed reads as begun there, since
  /// the first character will stamp it.
  private func address(
    _ text: String, hasAttachments: Bool, destination: DraftDestination, in scope: FeedScope
  ) -> Addressing {
    // A restored message stays its source's under any chip, so a removed source blocks it.
    if let lane = restoredFrom, let name = removed[lane] {
      return .blocked("\(name) was removed")
    }
    let effective =
      text.isEmpty && !hasAttachments && destination == .open
      ? scope.coordinator.map(DraftDestination.begunIn) ?? .open : destination
    // A restored message's text is never a tag, whatever its chip (DESIGN-REVIEW A2).
    let parsed = Addressing.parse(
      text, hasAttachments: hasAttachments, destination: effective, literal: restoredFrom != nil,
      among: lanes.filter { removed[$0.id] == nil }.map {
        .init(
          id: $0.id, name: name($0.id), paired: $0.session != nil, connected: connected($0.id))
      }, removed: removed)
    let unbound =
      effective == .open && restoredFrom == nil && Addressing.leadingTags(text).tags.isEmpty
    return parsed.gated(by: scope, unbound: unbound)
  }

  /// The line under the composer with two or more saved coordinators, or once one was removed.
  var recipientLine: String {
    switch addressing {
    case .to(let ids, _), .empty(let ids): "To " + joinedNames(ids.map(name))
    case .blocked(let reason): reason
    case .elsewhere(let ids, _): "This draft goes to " + joinedNames(ids.map(name))
    }
  }

  /// Saved coordinators matching an `@` still being typed in the committed text, for the picker
  /// above the composer. A restored draft offers none, since choosing one replaces the draft.
  var pickerMatches: [CoordinatorProfile] {
    guard addressesByName, destination.chip == nil, restoredFrom == nil, committed.first == "@",
      !committed.contains(where: \.isWhitespace)
    else { return [] }
    let typed = committed.dropFirst().lowercased()
    return profiles.filter {
      removed[$0.id] == nil && $0.name.description.lowercased().hasPrefix(typed)
    }
  }

  func choose(_ id: ProfileID) {
    guard removed[id] == nil else { return }
    destination = .chip(id)
    draft = ""
  }

  /// The field's text, and that text without what an input method is still composing.
  func edit(_ text: String, committed: String) {
    draft = text
    self.committed = committed
  }

  /// A complete leading tag followed by a space becomes the chip, and the text after it is
  /// never read for tags. The composer calls this whenever the committed text changes. A restored
  /// draft's text is literal for good, so no tag in it ever becomes the chip, and none does while
  /// an input method is still composing the draft.
  func promoteTypedTag() {
    guard addressesByName, destination.chip == nil, restoredFrom == nil, committed == draft,
      draft.first == "@"
    else { return }
    let word = draft.dropFirst().prefix { !$0.isWhitespace }
    let named = profiles.filter { $0.name.description.lowercased() == word.lowercased() }
    guard word.endIndex < draft.endIndex, let match = named.first, named.count == 1 else { return }
    destination = .chip(match.id)
    let typed = draft
    draft = String(draft[draft.index(after: word.endIndex)...])
    promotion = Promotion(typed: typed, rest: draft)
  }

  // MARK: - Send

  var canSend: Bool {
    guard draftReady, !pendingSharedImport, !admitting, !preparingAttachments,
      case .to = addressing
    else { return false }
    return true
  }

  /// Everything one Send needs, taken in the Send button's own turn. Only `send(screenshot:)` builds
  /// one and only `admit(_:)` reads it, so nothing after the tap, whether a switch, an edit or an
  /// address change, decides where the message goes.
  private struct PreparedSend {
    struct Target {
      let id: ProfileID
      let session: CoordinatorSession
    }
    /// The parsed recipients in order, each with the session it had at the tap.
    let targets: [Target]
    let body: String
    let mode: InputMode
    let files: [LocalAttachment]
    /// The automatic `/feedback` screenshot and the one coordinator it may go to.
    let screenshot: (png: Data, owner: ProfileID)?
    /// Why `/feedback` went without a screenshot, said once the message went.
    let withheld: String?
    let source: RestoredSource?
    /// `draftRevision` at the tap.
    let revision: Int
  }

  /// Sends the draft. It runs in the Send button's own turn, so the draft, its recipients, their
  /// sessions and any screenshot all come from the moment of the tap. Returns the admission it
  /// started, or nil when it refused the Send in this turn and kept the draft.
  @discardableResult
  func send(screenshot capture: (@MainActor () throws -> Data)? = nil) -> Task<Void, Never>? {
    guard canSend, case .to(let recipients, let body) = addressing else { return nil }
    var owners = attachments.compactMap { screenshotOwners[$0.id] }
    var screenshot: (png: Data, owner: ProfileID)?
    var withheld: String?
    if let capture, owners.isEmpty,
      draft.split(whereSeparator: \.isWhitespace).first == "/feedback"
    {
      if multiple {
        withheld =
          "Feedback was sent without a screenshot. With two or more coordinators saved, the screen can show another coordinator's messages."
      } else if let owner = feedOwner {
        // The screenshot shows the feed, so it goes only where everything the feed shows belongs.
        guard attachments.count < AttachmentLimits.maximumCount else {
          failure = AttachmentError.tooMany.localizedDescription
          return nil
        }
        do { screenshot = (try capture(), owner) } catch {
          failure = error.localizedDescription
          return nil
        }
        owners.append(owner)
      } else {
        withheld =
          "Feedback was sent without a screenshot. The screen shows messages held from before the update, which may be another coordinator's."
      }
    }
    // A file that may show one coordinator's feed goes to that coordinator alone.
    guard owners.allSatisfy({ recipients == [$0] }) else {
      failure =
        "Remove the automatic screenshot before sending. It could show one coordinator's messages to another."
      return nil
    }
    let targets = recipients.compactMap { id in
      lanes.first { $0.id == id }?.session.map { PreparedSend.Target(id: id, session: $0) }
    }
    guard targets.count == recipients.count else { return nil }
    admitting = true
    let prepared = PreparedSend(
      targets: targets, body: body, mode: mode, files: attachments, screenshot: screenshot,
      withheld: withheld, source: source, revision: draftRevision)
    return Task { await admit(prepared) }
  }

  /// Saves the message in every target's outbox before any of them starts, so a refusal leaves
  /// nothing queued anywhere and the draft untouched. A captured session retired meanwhile refuses
  /// its stage, and no other session stands in for it.
  private func admit(_ prepared: PreparedSend) async {
    defer { admitting = false }
    var files = prepared.files
    var expected = prepared.revision
    if let shot = prepared.screenshot {
      do {
        // The screenshot joins the draft, so a failed admission keeps this exact image.
        let file = try await attachmentStore().stage(
          data: shot.png, name: "Feedback.png", mediaType: "image/png")
        // The Send's own screenshot is not a newer draft, though an edit made while it was staged
        // is.
        let staged = draftRevision
        attachments.append(file)
        files.append(file)
        screenshotOwners[file.id] = shot.owner
        expected &+= draftRevision &- staged
      } catch {
        failure = error.localizedDescription
        return
      }
    }
    let recipients = prepared.targets.map(\.id)
    let sendID = UUID().uuidString
    // Cleared before staging, so what a retirement cancels during this Send stays named.
    failure = nil
    reports = []
    var staged: [(target: PreparedSend.Target, input: StagedInput)] = []
    for target in prepared.targets {
      guard
        let input = await target.session.stage(
          prepared.body, mode: prepared.mode, files: files, sendID: sendID, recipients: recipients)
      else {
        for item in staged {
          await withdraw(item.input, from: item.target.session, lane: item.target.id)
        }
        // With one coordinator saved and none removed, its own reason is the composer's error.
        if removed[target.id] != nil {
          report("Nothing was sent. " + Missed.removed.sentence([name(target.id)], "this message"))
        } else if addressesByName {
          report("Nothing was sent. \(name(target.id)) did not take the message.")
        }
        return
      }
      staged.append((target, input))
    }
    var misses: [(ProfileID, StagedInput, Missed)] = []
    for item in staged {
      let outcome = await item.target.session.start(item.input)
      if let why = missed(item.target.id, item.input, outcome) {
        misses.append((item.target.id, item.input, why))
      }
    }
    report(misses)
    // Nothing went, so the draft stays for another try.
    guard misses.count < staged.count else { return }
    if let withheld = prepared.withheld { report(withheld) }
    if draftRevision == expected {
      draft = ""
      restoredFrom = nil
      destination = .open
    }
    let sentIDs = Set(files.map(\.id))
    attachments.removeAll { sentIDs.contains($0.id) }
    for id in sentIDs { screenshotOwners[id] = nil }
    if await saveDraft(), let store = draftStore {
      for file in files { try? await store.remove(file) }
    }
    guard let original = prepared.source else { return }
    if source == original { source = nil }
    if original.isCarried(by: prepared.body, files: files, to: recipients) {
      await remove(original)
    }
  }

  /// Withdraws an input a Send staged and never started from its coordinator's outbox, through the
  /// session that holds the outbox now. An address edit retires the session that staged it and
  /// attaches the profile's next one, which then withdraws it, at once or once it is attached.
  /// Remove deletes the outbox, so nothing is left to withdraw.
  private func withdraw(_ input: StagedInput, from session: CoordinatorSession, lane id: ProfileID)
    async
  {
    var session = session
    while await session.unstage(input) == false {
      guard let next = lanes.first(where: { $0.id == id })?.session, next !== session else {
        if removed[id] == nil { unstaging[id, default: []].append(input) }
        return
      }
      session = next
    }
  }

  /// Why a coordinator did not get an input of a Send.
  private enum Missed {
    case notConnected, removed, readdressed

    /// "Work did not get /status. It was removed."
    func sentence(_ names: [String], _ what: String) -> String {
      let one = names.count == 1
      let reason =
        switch self {
        case .notConnected: one ? "It is not connected." : "They are not connected."
        case .removed: one ? "It was removed." : "They were removed."
        case .readdressed: one ? "Its address changed." : "Their addresses changed."
        }
      return "\(joinedNames(names)) did not get \(what). \(reason)"
    }
  }

  /// Why `lane` did not get `input`, or nil if it did or still will. A retired session's durable
  /// input stays in its outbox, which an address edit keeps for the new session and Remove deletes.
  private func missed(_ lane: ProfileID, _ input: StagedInput, _ outcome: StartOutcome) -> Missed? {
    switch outcome {
    case .started: nil
    case .notSent: .notConnected
    case .retired where removed[lane] != nil: .removed
    case .retired: input.command == nil ? nil : .readdressed
    }
  }

  /// Names each coordinator that did not get an input, and why, after what the composer already
  /// reported. A control is named by its command, anything else as "this message".
  private func report(_ misses: [(lane: ProfileID, input: StagedInput, why: Missed)]) {
    var groups: [(why: Missed, what: String, names: [String])] = []
    for miss in misses {
      let name = name(miss.lane)
      let what = miss.input.command ?? "this message"
      if let index = groups.firstIndex(where: { $0.why == miss.why && $0.what == what }) {
        if !groups[index].names.contains(name) { groups[index].names.append(name) }
      } else {
        groups.append((miss.why, what, [name]))
      }
    }
    for group in groups { report(group.why.sentence(group.names, group.what)) }
  }
  private func report(_ sentence: String) { reports.append(sentence) }

  // MARK: - Restore

  /// Copies a queued input into the composer, addressed to its own coordinator, with its text
  /// as it was. The input stays queued until a Send carries the copy unchanged.
  func restore(_ inputID: String) async {
    guard let lane = lane(holding: inputID), readyToRestore(from: lane.id) else { return }
    do {
      let store = try attachmentStore()
      guard let restored = await lane.session?.restore(inputID, to: store) else { return }
      await fill(restored, for: lane.id, source: (inputID, .live), store)
    } catch { failure = error.localizedDescription }
  }
  /// Copies a held message into the composer with its text as it was, addressed to its owner, or
  /// else to `chosen`, and with neither asks who should get it. It stays held until a Send carries
  /// the copy unchanged to its owner, since only that one is known to be the coordinator it was
  /// queued for. A `chosen` answers only a message with no owner, so once the message has gained
  /// another owner, as when its queue's coordinator paired while Restore asked, it restores nothing.
  func restoreHeld(_ message: HeldMessage, for chosen: ProfileID? = nil) async {
    let owner = owner(message)
    if chosen == nil, owner == nil {
      asking = message
      return
    }
    if let chosen, let owner, chosen != owner { return }
    guard let hold = holds.first(where: { $0.queue.id == message.queue }),
      let recipient = chosen ?? owner, readyToRestore(from: recipient)
    else { return }
    do {
      let store = try attachmentStore()
      guard let restored = try await hold.store.restore(message.id, to: store) else { return }
      await fill(
        restored, for: recipient,
        source: recipient == owner ? (message.id, .held(queue: message.queue)) : nil, store)
    } catch { failure = error.localizedDescription }
  }
  func discardHeld(_ message: HeldMessage) async {
    guard let hold = holds.first(where: { $0.queue.id == message.queue }) else { return }
    do { try await hold.store.discard(message.id) } catch { failure = error.localizedDescription }
    await read(hold)
  }
  private func readyToRestore(from lane: ProfileID) -> Bool {
    guard draftReady else {
      draftError = draftError ?? "Restore the saved draft before replacing the composer."
      return false
    }
    if let name = removed[lane] {
      failure = "\(name) is being removed."
      return false
    }
    guard !admitting, draft.isEmpty, attachments.isEmpty else {
      failure = "Send or clear the current draft before restoring another message."
      return false
    }
    return true
  }
  private func namesNoOneBut(_ lane: ProfileID) -> Bool {
    guard addressesByName else { return true }
    if let chip = destination.chip { return chip == lane }
    let tags = restoredFrom == nil ? Addressing.leadingTags(draft).tags : []
    guard tags.isEmpty else {
      return tags.allSatisfy { $0.lowercased() == name(lane).lowercased() }
    }
    return destination.coordinator.map { $0 == lane } ?? true
  }
  /// Puts the restored message before what the user typed or attached while its files were copied,
  /// as on `main`. Without a `source` it is a copy that withdraws nothing.
  private func fill(
    _ restored: RestoredDraft, for lane: ProfileID,
    source original: (item: String, kind: RestoredSource.Kind)?, _ store: AttachmentStore
  ) async {
    guard (draft.isEmpty && attachments.isEmpty) || namesNoOneBut(lane) else {
      failure = "Send or clear the current draft before restoring another message."
      for file in restored.attachments { try? await store.remove(file) }
      return
    }
    draft = restored.text + (draft.isEmpty ? "" : "\n\n" + draft)
    attachments.insert(contentsOf: restored.attachments, at: 0)
    mode = restored.mode
    // The text may have been edited since capture, so only the file's name marks a screenshot.
    for file in restored.attachments where file.reference.name == "Feedback.png" {
      screenshotOwners[file.id] = lane
    }
    restoredFrom = lane
    source = original.map {
      RestoredSource(
        lane: lane, item: $0.item, kind: $0.kind, text: restored.text,
        files: Set(restored.attachments.map(\.id)))
    }
    // Last, since an empty restored text clears the draft above, which drops an undrawn chip.
    destination = .chip(lane)
  }
  private func forgetClearedSource() {
    guard draft.isEmpty && attachments.isEmpty else { return }
    restoredFrom = nil
    source = nil
    switch destination {
    case .begunIn: destination = .open
    // Only Restore sets a chip the composer does not draw, so it goes with the draft it was set for.
    case .chip where !addressesByName: destination = .open
    case .open, .chip: break
    }
  }
  /// Runs once a Send carried the source's content unchanged. A lane or queue removed meanwhile
  /// took its source with it.
  private func remove(_ source: RestoredSource) async {
    switch source.kind {
    case .live: await lanes.first { $0.id == source.lane }?.session?.discard(source.item)
    case .held(let queue):
      guard let hold = holds.first(where: { $0.queue.id == queue }) else { return }
      do { try await hold.store.discard(source.item) } catch {
        failure = error.localizedDescription
      }
      await read(hold)
    }
  }
  private func read(_ hold: Hold) async {
    let result: Result<[LegacyItem], any Error>
    do { result = .success(try await hold.store.items()) } catch { result = .failure(error) }
    guard holds.contains(where: { $0.queue.id == hold.queue.id }) else { return }
    reads[hold.queue.id] = result
  }

  // MARK: - Attachments

  private func attachmentStore() throws -> AttachmentStore {
    if let draftStore { return draftStore }
    let directory = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let store = AttachmentStore(directory: directory.appending(path: "Agent/Drafts"))
    draftStore = store
    return store
  }

  /// The text's begin stamp, in the same turn as the first character typed into an empty
  /// composer. Share imports and a draft reload run under `changingDraft` and never stamp.
  private func stampBegun() {
    guard !changingDraft, destination == .open, let shown = scope.coordinator else { return }
    destination = .begunIn(shown)
  }

  /// A file action's begin stamp. It holds the destination the scope shown gave an empty draft when
  /// the user chose files, a photo, a paste or a drop, and the draft's revision then.
  private struct BeginClaim {
    let destination: DraftDestination
    let revision: Int
  }

  private func claimBegin() -> BeginClaim? {
    guard draft.isEmpty, attachments.isEmpty, destination == .open,
      let shown = scope.coordinator
    else { return nil }
    return BeginClaim(destination: .begunIn(shown), revision: draftRevision)
  }

  /// The one way a file action's files join the draft. The claim stamps only a draft nothing
  /// changed since it was taken, so a file that lands after a switch keeps the scope it was chosen
  /// in, and one that lands in a draft typed, replaced or cleared meanwhile joins it unstamped.
  private func append(_ files: [LocalAttachment], claim: BeginClaim?) {
    let stamps = claim?.revision == draftRevision
    attachments.append(contentsOf: files)
    if stamps, let claim { destination = claim.destination }
  }

  /// Returns the copy it started, or nil when the composer takes no files now.
  @discardableResult
  func attach(urls: [URL]) -> Task<Void, Never>? {
    guard draftReady, !preparingAttachments else { return nil }
    var claim = claimBegin()
    preparingAttachments = true
    return Task {
      defer { preparingAttachments = false }
      do {
        let store = try attachmentStore()
        for url in urls {
          guard attachments.count < AttachmentLimits.maximumCount else {
            throw AttachmentError.tooMany
          }
          let scoped = url.startAccessingSecurityScopedResource()
          defer { if scoped { url.stopAccessingSecurityScopedResource() } }
          append([try await store.stage(url: url)], claim: claim)
          claim = nil
        }
      } catch { failure = error.localizedDescription }
    }
  }
  @discardableResult
  func attach(providers: [NSItemProvider]) -> Task<Void, Never>? {
    guard draftReady, !preparingAttachments else { return nil }
    let claim = claimBegin()
    preparingAttachments = true
    return Task {
      defer { preparingAttachments = false }
      var staged: [LocalAttachment] = []
      do {
        guard providers.count <= AttachmentLimits.maximumCount - attachments.count else {
          throw AttachmentError.tooMany
        }
        let images = try await ItemProviderImages.load(providers)
        let store = try attachmentStore()
        for image in images {
          try Task.checkCancellation()
          staged.append(
            try await store.stage(data: image.data, name: image.name, mediaType: image.mediaType))
        }
        try Task.checkCancellation()
        guard staged.count <= AttachmentLimits.maximumCount - attachments.count else {
          throw AttachmentError.tooMany
        }
        // Adopt the complete selection once. Neither the note nor existing files
        // belong to this import, including when a provider fails or is cancelled.
        append(staged, claim: claim)
      } catch {
        for file in staged { try? await draftStore?.remove(file) }
        if !(error is CancellationError) { failure = error.localizedDescription }
      }
    }
  }
  func attach(data: Data, name: String, mediaType: String) async {
    await attach(data: data, name: name, mediaType: mediaType, claim: claimBegin())
  }
  private func attach(data: Data, name: String, mediaType: String, claim: BeginClaim?) async {
    guard draftReady else { return }
    do {
      guard attachments.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
      let file = try await attachmentStore().stage(data: data, name: name, mediaType: mediaType)
      guard attachments.count < AttachmentLimits.maximumCount else {
        try? await draftStore?.remove(file)
        throw AttachmentError.tooMany
      }
      append([file], claim: claim)
    } catch { failure = error.localizedDescription }
  }
  #if os(iOS)
    @discardableResult
    func attach(photo: PhotosPickerItem) -> Task<Void, Never>? {
      guard draftReady, !preparingAttachments else { return nil }
      let claim = claimBegin()
      preparingAttachments = true
      return Task {
        defer { preparingAttachments = false }
        do {
          guard let image = try await photo.loadTransferable(type: ImportedPhoto.self) else {
            throw AttachmentError.invalidFile
          }
          await attach(data: image.data, name: "Photo.jpg", mediaType: "image/jpeg", claim: claim)
        } catch { failure = error.localizedDescription }
      }
    }
  #endif
  func removeAttachment(_ file: LocalAttachment) async {
    guard !admitting, !preparingAttachments else { return }
    attachments.removeAll { $0.id == file.id }
    screenshotOwners[file.id] = nil
    if await saveDraft() { try? await draftStore?.remove(file) }
  }

  // MARK: - Row actions, each routed to the row's own coordinator

  /// The lane whose outbox holds `inputID`. Every input ID is minted for one coordinator.
  private func lane(holding inputID: String) -> Lane? {
    lanes.first { lane in snapshots[lane.id]?.rows.contains { $0.inputID == inputID } == true }
  }
  private func session(_ lane: ProfileID?) -> CoordinatorSession? {
    lanes.first { $0.id == lane }?.session
  }
  func preview(_ reference: AttachmentRef, lane: ProfileID?) async {
    guard let session = session(lane) else { return }
    do { previewURL = try await session.preview(reference) } catch {
      failure = error.localizedDescription
    }
  }
  func retry(_ inputID: String) async { await lane(holding: inputID)?.session?.retry(inputID) }
  /// Discard on a refused row. Its original leaves the outbox and is recorded withdrawn.
  func discard(_ inputID: String) async {
    await lane(holding: inputID)?.session?.discard(inputID)
  }
  func toolDetails(for row: ChatRow, lane: ProfileID?) async throws -> ToolDetails {
    guard let entryID = row.entryID, let tool = row.tool, let session = session(lane) else {
      throw ConnectionError.closed
    }
    return try await session.toolDetails(entryID: entryID, callID: tool.callId)
  }
  /// Every coordinator `scope` shows with older history loads a page. The one holding `anchorID`
  /// keeps that row in its window.
  func history(anchorID: String?, in scope: FeedScope) async {
    let anchor = rows.first { $0.id == anchorID }
    let pages = lanes.filter { scope.shows($0.id) }.compactMap { lane in
      lane.session.map { ($0, anchor?.lane == lane.id ? anchor?.row.id : nil) }
    }
    await withTaskGroup(of: Void.self) { group in
      for (session, rowID) in pages {
        group.addTask { await session.loadEarlier(anchorID: rowID) }
      }
    }
  }
  /// Every coordinator `scope` shows loads its latest page.
  func latestHistory(in scope: FeedScope) async {
    let sessions = lanes.filter { scope.shows($0.id) }.compactMap(\.session)
    await withTaskGroup(of: Void.self) { group in
      for session in sessions { group.addTask { await session.loadLatest() } }
    }
  }
  /// Stop response stops only the working coordinators `scope` shows.
  func interrupt(in scope: FeedScope) async {
    for lane in lanes where scope.shows(lane.id) && snapshots[lane.id]?.busy == true {
      await lane.session?.interrupt()
    }
  }

  // MARK: - Feed

  func apply(_ update: ChatSnapshot, lane id: ProfileID) {
    snapshots[id] = update
    if seen[id]?.epoch != laneEpoch(id) { seen[id] = (laneEpoch(id), update.liveReplies) }
    refresh(changed: id)
  }

  /// Rebuilds the feed and the composer's view of the coordinators from every lane's state. Rows
  /// built for another scope are never reused, since one ID can stand for another recipient's
  /// copy there.
  private func refresh(changed: ProfileID? = nil) {
    let states = lanes.compactMap { lane in
      snapshots[lane.id].map { (id: lane.id, snapshot: $0) }
    }
    let scope = scope
    let projection = Feed.project(states, scope: scope)
    let rebuilt = scope != projected
    projected = scope
    let existing =
      rebuilt
      ? [:] : Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { original, _ in original })
    var changedShown = rebuilt || rows.map(\.id) != projection.rows.map(\.id)
    let next = projection.rows.map { row -> RowModel in
      guard let model = existing[row.id] else { return RowModel(row) }
      if model.update(row) { changedShown = true }
      return model
    }
    if rebuilt || rows.map(\.id) != next.map(\.id) {
      rows = next
    } else {
      transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems)
    }
    if connection != projection.connection || model != projection.model || busy != projection.busy
      || commands != projection.commands || canLoadEarlier != projection.canLoadEarlier
      || loadingHistory != projection.loadingHistory || includesLatest != projection.includesLatest
    {
      changedShown = true
    }
    connection = projection.connection
    model = projection.model
    busy = projection.busy
    commands = projection.commands
    canLoadEarlier = projection.canLoadEarlier
    loadingHistory = projection.loadingHistory
    includesLatest = projection.includesLatest
    if changedShown || changed == nil { revision &+= 1 }
    guard active else { return }
    for id in lanes.map(\.id) where scope.shows(id) {
      if let count = snapshots[id]?.liveReplies, seen[id]?.count != count {
        seen[id]?.count = count
      }
    }
  }
}
