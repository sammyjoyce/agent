import AgentCore
import Foundation
import OSLog
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
  func update(_ feed: FeedRow) {
    if row != feed.row { row = feed.row }
    if lane != feed.lane { lane = feed.lane }
    if receipts != feed.receipts { receipts = feed.receipts }
  }
}

/// One saved coordinator in the feed. `session` is nil until the profile is paired. Its
/// messages held from before the update show either way.
struct Lane {
  let id: ProfileID
  let session: CoordinatorSession?
  let hold: LegacyHold
}

struct HeldMessage: Identifiable, Equatable {
  let lane: ProfileID
  let item: LegacyItem
  var id: String { item.id }
}

/// Where the composer's restored draft came from. The source stays queued or held until
/// the draft is admitted, so a draft lost before Send loses nothing.
struct RestoredSource: Equatable {
  enum Kind { case live, legacy }
  let lane: ProfileID
  let item: String
  let kind: Kind
}

/// The one feed and the one composer for every saved coordinator.
@MainActor @Observable
final class ChatModel {
  private enum ComposerEvent: String {
    case active, inactive, restored, edited, sendRequested, sendIgnored, cleared, outboxSaved,
      localDraftRestored,
      saveFailed
  }

  @ObservationIgnored private let composerLogger = Logger(
    subsystem: "dev.jessfraz.Agent", category: "Composer")
  private enum Admission {
    case pending(text: String, submission: ComposerSubmission?)
    case saved
  }
  /// Runs a Send's delivery to its recipients' outboxes and answers whether any took it. Tests
  /// wrap the delivery to hold a Send in flight, or answer without it to refuse one.
  typealias Admit = @MainActor (_ deliver: @MainActor () async -> Bool) async -> Bool

  var rows: [RowModel] = [] {
    didSet { transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems) }
  }
  private(set) var transcriptItems: [TranscriptItem] = []
  var connection: ConnectionState = .disconnected
  var model = "Unknown"
  var commands: [SlashCommand] = []
  private(set) var settingsSupported = false
  private(set) var workInspectionSupported = false
  let inspectedConversation: SavedConversation?
  private(set) var conversationSettings: NativeSettingsSnapshot?
  private(set) var settingsBusy = false
  var settingsError: String?
  @ObservationIgnored private var settingsRequest: UUID?
  var busy = false
  var canLoadEarlier = false
  var loadingHistory = false
  var includesLatest = true
  /// What the composer shows under the feed: what it reported since the last Send, then the latest
  /// failure.
  var error: String? {
    let parts = reports + [failure].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
  /// Who did not get the last Send, and why. Only the next Send clears it.
  private(set) var reports: [String] = []
  /// The latest failure: the composer's own, or, with one coordinator, that coordinator's error.
  var failure: String?
  var revision = 0
  /// Saved coordinators in order, kept by `Coordinators`. Names, colors and the feed's lane
  /// order come from here.
  var profiles: [CoordinatorProfile] = []
  /// The one coordinator the draft goes to, or nil for every paired one. While it is set, the
  /// draft is never read for tags.
  var recipient: ProfileID?
  /// Coordinators removed in this process, or being removed, by the name they had. Nothing
  /// addresses one again, and profile IDs are never reused.
  var removed: [ProfileID: String] = [:]
  var draft = "" {
    didSet {
      draftRevision &+= 1
      draftBeforeEdit = oldValue
      forgetClearedSource()
      scheduleDraftSave()
      if !changingDraft, oldValue.isEmpty != draft.isEmpty { logComposer(.edited) }
    }
  }
  /// Counts every change to the draft, so a Send that went clears the recipient only when nothing
  /// was typed since its tap.
  @ObservationIgnored private var draftRevision = 0
  /// The draft before its latest change, so a restored draft promotes only a tag just typed.
  @ObservationIgnored private var draftBeforeEdit = ""
  var attachments: [LocalAttachment] = [] {
    didSet {
      forgetClearedSource()
      scheduleDraftSave()
    }
  }
  private(set) var held: [HeldMessage] = []
  private(set) var heldError: String?
  private(set) var restoredFrom: RestoredSource?
  /// Each lane's latest published state.
  private(set) var snapshots: [ProfileID: ChatSnapshot] = [:]
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
  var mode: InputMode = .steer { didSet { scheduleDraftSave() } }
  private(set) var draftReady: Bool
  private(set) var pendingSharedImport = false
  var draftError: String?
  @ObservationIgnored private let persistence: ComposerDraftStore?
  @ObservationIgnored private let sharedInbox: SharedDraftInbox?
  @ObservationIgnored private var persistentRevision: UInt64 = 0
  @ObservationIgnored private var composerID = UUID()
  @ObservationIgnored private var consumedTransfers: Set<UUID> = []
  @ObservationIgnored private var changingDraft = false
  @ObservationIgnored private var restoringDraft = false
  private var admission: Admission?
  var admitting: Bool { admission != nil }
  @ObservationIgnored private var draftStore: AttachmentStore?
  @ObservationIgnored private var retiredDraftFiles: [LocalAttachment] = []
  @ObservationIgnored private let admit: Admit
  /// Draft files that may show a coordinator's feed, by attachment ID, each with the one
  /// coordinator it was captured for.
  @ObservationIgnored private var screenshotOwners: [String: ProfileID] = [:] {
    didSet { scheduleDraftSave() }
  }
  @ObservationIgnored private let registration: NotificationRegistration?
  /// Whether the latest `setActive` asked for the app to be active.
  @ObservationIgnored private(set) var active = false
  @ObservationIgnored private(set) var lanes: [Lane] = []
  @ObservationIgnored private var observations: [ProfileID: Task<Void, Never>] = [:]

  init(
    inspecting conversation: SavedConversation? = nil,
    draftStore: AttachmentStore? = nil, persistence: ComposerDraftStore? = nil,
    sharedInbox: SharedDraftInbox? = nil, registration: NotificationRegistration? = nil,
    admit: @escaping Admit = { deliver in await deliver() }
  ) {
    inspectedConversation = conversation
    self.draftStore = draftStore
    self.persistence = persistence
    self.sharedInbox = sharedInbox
    draftReady = persistence == nil
    self.registration = registration
    self.admit = admit
  }
  deinit {
    for observation in observations.values { observation.cancel() }
    let sessions = lanes.compactMap(\.session)
    Task { for session in sessions { await session.disconnect() } }
  }

  func insertCommand(_ command: SlashCommand) {
    let name = command.usage.prefix(while: { !$0.isWhitespace })
    guard draftReady, !name.isEmpty else { return }
    let text = draft.drop(while: \.isWhitespace)
    let leading = text.prefix(while: { !$0.isWhitespace })
    if commands.contains(where: { $0.usage.prefix(while: { !$0.isWhitespace }) == leading }) {
      let note = text.dropFirst(leading.count)
      draft = String(name) + (note.isEmpty ? " " : String(note))
    } else {
      draft = String(name) + " " + draft
    }
  }

  private var currentDraft: ComposerDraft {
    var value = ComposerDraft(
      text: draft, mode: mode, attachments: attachments, consumedTransfers: consumedTransfers,
      composerID: composerID)
    if case .pending(let text, let submission) = admission {
      if let submission {
        let submittedIDs = Set(submission.attachments.map(\.id))
        value.submission = submission
        value.attachments.removeAll { submittedIDs.contains($0.id) }
      } else if !text.isEmpty {
        value.text = text + (value.text.isEmpty ? "" : "\n\n" + value.text)
      }
    }
    value.feedbackScreenshotID = value.attachments.first { screenshotOwners[$0.id] != nil }?.id
    return value
  }
  private func scheduleDraftSave() {
    guard draftReady, !changingDraft, let persistence else { return }
    persistentRevision &+= 1
    let revision = persistentRevision
    let value = currentDraft
    Task { [weak self] in
      do { try await persistence.save(value, revision: revision) } catch {
        if let self, self.persistentRevision == revision {
          self.draftError = error.localizedDescription
          self.logComposer(.saveFailed, error: error)
        }
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
      // The saved record no longer references these admitted copies. A failed
      // checkpoint must keep them available for another restoration attempt.
      if let store = draftStore {
        let retired = retiredDraftFiles
        retiredDraftFiles = []
        for file in retired {
          do { try await store.remove(file) } catch { retiredDraftFiles.append(file) }
        }
      }
      draftError = nil
      return true
    } catch {
      draftError = error.localizedDescription
      logComposer(.saveFailed, error: error)
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
      // The saved draft marks the automatic screenshot but not whose feed it shows. With one
      // coordinator saved it can only be that one's. Otherwise it belongs to none, so Send refuses
      // it for every coordinator until it is removed.
      screenshotOwners = [:]
      if let id = restored.draft.feedbackScreenshotID {
        screenshotOwners[id] = profiles.count == 1 ? profiles[0].id : ProfileID()
      }
      composerID = restored.draft.composerID ?? composerID
      retiredDraftFiles = restored.retiredAttachments
      persistentRevision = restored.revision
      changingDraft = false
      draftReady = true
      logComposer(.restored)
      pendingSharedImport = !consumedTransfers.isEmpty
      _ = await saveDraft()
      guard sharedInbox != nil || consumedTransfers.isEmpty else {
        throw SharedDraftError.notConfigured
      }
      await receiveSharedDrafts()
    } catch { draftError = error.localizedDescription }
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
  /// The chip the composer draws: the recipient while the composer names recipients. With one
  /// coordinator saved and none removed none is drawn, as on `main`, though a restored draft keeps
  /// its recipient, so it stays its source's when another coordinator is added.
  var shownChip: ProfileID? { addressesByName ? recipient : nil }

  func name(_ id: ProfileID) -> String {
    profiles.first { $0.id == id }?.name.description ?? removed[id] ?? "Coordinator"
  }

  func paired(_ id: ProfileID) -> Bool { lanes.first { $0.id == id }?.session != nil }

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
      refresh()
      observations[lane.id] = observe(session, lane: lane.id)
    }
    Task { await loadHeld(lane) }
  }

  /// Retires the lane's session, then drops the lane. Every session that is not in a lane is
  /// retired, so nothing connects, sends or writes the profile's directory through it again. The
  /// composer names what the retirement cancelled before it left the phone.
  func detach(_ id: ProfileID) async {
    let cancelled = await lanes.first { $0.id == id }?.session?.retire() ?? []
    if let index = lanes.firstIndex(where: { $0.id == id }) {
      let lane = lanes.remove(at: index)
      observations.removeValue(forKey: id)?.cancel()
      registration?.disconnect(id)
      held.removeAll { $0.lane == id }
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
    logComposer(active ? .active : .inactive)
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

  // MARK: - Conversation settings and Jobs and work

  /// The lane conversation settings, jobs and inspections reach. With several coordinators saved
  /// there is none, so a settings change or a job retry never goes to a coordinator the user did
  /// not choose.
  private var soleLane: Lane? {
    guard !multiple, lanes.count == 1, lanes.first?.session != nil else { return nil }
    return lanes.first
  }
  /// Opens this inspection on `owner`'s coordinator, over a read-only session of its own.
  func connectInspection(using owner: ChatModel) async {
    guard let conversation = inspectedConversation, lanes.isEmpty, let lane = owner.soleLane,
      let inspector = lane.session?.inspector(conversation)
    else {
      failure = ConnectionError.closed.localizedDescription
      return
    }
    profiles = owner.profiles
    lanes = [Lane(id: lane.id, session: inspector, hold: lane.hold)]
    snapshots[lane.id] = nil
    observations[lane.id] = observe(inspector, lane: lane.id)
    await inspector.connect()
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
  func jobs(_ id: String? = nil) async throws -> NativeJobStatus {
    guard let session = soleLane?.session else { throw ConnectionError.closed }
    return try await session.jobs(id)
  }
  func retryJob(_ id: String) async throws -> ScheduledJobStatus {
    guard let session = soleLane?.session else { throw ConnectionError.closed }
    return try await session.retryJob(id)
  }
  func conversations(query: String = "", cursor: String? = nil) async throws
    -> NativeEventConversations
  {
    guard let session = soleLane?.session else { throw ConnectionError.closed }
    return try await session.conversations(query: query, cursor: cursor)
  }
  func refreshSettings(change: ConversationChange? = nil) async {
    guard !settingsBusy, settingsSupported, let session = soleLane?.session,
      connection == .connected
    else { return }
    let id = UUID()
    settingsRequest = id
    settingsBusy = true
    settingsError = nil
    defer {
      if settingsRequest == id {
        settingsRequest = nil
        settingsBusy = false
      }
    }
    do {
      let settings = try await session.settings(change: change)
      guard soleLane?.session === session, !Task.isCancelled else { return }
      conversationSettings = settings
    } catch {
      if soleLane?.session === session, !(error is CancellationError) {
        settingsError = error.localizedDescription
      }
    }
  }

  // MARK: - Addressing

  /// Who Send reaches with the current draft, or why it is blocked.
  var addressing: Addressing {
    address(draft, hasAttachments: !attachments.isEmpty, chip: recipient)
  }

  /// True while the draft is the coordinator's: chosen as the chip, restored from it, or led
  /// by a typed tag with its name.
  func addresses(_ id: ProfileID) -> Bool {
    if recipient == id || restoredFrom?.lane == id { return true }
    guard recipient == nil, restoredFrom == nil,
      let name = profiles.first(where: { $0.id == id })?.name.description
    else { return false }
    return Addressing.leadingTags(draft).tags.contains { $0.lowercased() == name.lowercased() }
  }

  private func address(_ text: String, hasAttachments: Bool, chip: ProfileID?) -> Addressing {
    // A restored message stays its source's under any chip, so a removed source blocks it.
    if let source = restoredFrom?.lane, let name = removed[source] {
      return .blocked("\(name) was removed")
    }
    // A restored message's text is never a tag, whatever its chip (DESIGN-REVIEW A2).
    return Addressing.parse(
      text, hasAttachments: hasAttachments, chip: chip, literal: restoredFrom != nil,
      among: lanes.filter { removed[$0.id] == nil }.map {
        .init(
          id: $0.id, name: name($0.id), paired: $0.session != nil, connected: connected($0.id))
      }, removed: removed)
  }

  /// The line under the composer with two or more saved coordinators, or once one was removed.
  var recipientLine: String {
    switch addressing {
    case .to(let ids, _), .empty(let ids): "To " + joinedNames(ids.map(name))
    case .blocked(let reason): reason
    }
  }

  /// Saved coordinators matching an `@` still being typed, for the picker above the composer. A
  /// restored draft offers none, since choosing one replaces the draft.
  var pickerMatches: [CoordinatorProfile] {
    guard addressesByName, recipient == nil, restoredFrom == nil, draft.first == "@",
      !draft.contains(where: \.isWhitespace)
    else { return [] }
    let typed = draft.dropFirst().lowercased()
    return profiles.filter {
      removed[$0.id] == nil && $0.name.description.lowercased().hasPrefix(typed)
    }
  }

  func choose(_ id: ProfileID) {
    guard removed[id] == nil else { return }
    recipient = id
    draft = ""
  }

  /// A complete leading tag followed by a space becomes the chip, and the text after it is
  /// never read for tags. The composer calls this after each edit. In a restored draft only a tag
  /// the user just finished typing at its start counts, never the restored text's own.
  func promoteTypedTag() {
    guard addressesByName, recipient == nil, draft.first == "@" else { return }
    let word = draft.dropFirst().prefix { !$0.isWhitespace }
    let named = profiles.filter { $0.name.description.lowercased() == word.lowercased() }
    guard word.endIndex < draft.endIndex, let match = named.first, named.count == 1 else { return }
    let tag = draft[...word.endIndex]
    guard restoredFrom == nil || !draftBeforeEdit.hasPrefix(tag) else { return }
    recipient = match.id
    draft = String(draft[draft.index(after: word.endIndex)...])
  }

  // MARK: - Send

  var canSend: Bool {
    guard draftReady, !pendingSharedImport, !admitting, !preparingAttachments,
      case .to = addressing
    else { return false }
    return true
  }

  func send(screenshot: (@MainActor () throws -> Data)? = nil) async {
    await startSend(screenshot: screenshot)?.value
  }

  /// Snapshot and clear on the button's event, before scheduling any async work. The message is
  /// then saved in every recipient's outbox before any of them starts, so a refusal leaves nothing
  /// queued anywhere and the text comes back to the composer.
  @discardableResult
  func startSend(screenshot: (@MainActor () throws -> Data)? = nil) -> Task<Void, Never>? {
    logComposer(.sendRequested)
    guard canSend, case .to(let addressed, _) = addressing else {
      logComposer(.sendIgnored)
      return nil
    }
    let text = draft
    let mode = mode
    let source = restoredFrom
    let chip = recipient
    let originalFiles = attachments
    let identity = ComposerInputIdentity(composerID: composerID)
    // Clear the actual bound value before any await. The pending admission
    // retains the recovery copy until the durable outbox takes ownership.
    admission = .pending(
      text: text,
      submission: submission(identity, text: text, files: originalFiles, to: addressed.first))
    changingDraft = true
    draft = ""
    changingDraft = false
    logComposer(.cleared)
    let clearedRevision = draftRevision
    return Task {
      var admitted = false
      defer {
        admission = nil
        if !admitted, !text.isEmpty {
          // Nothing went, so no outbox holds the message. Preserve both the original and
          // anything typed while admission or attachment preparation was pending.
          draft = text + (draft.isEmpty ? "" : "\n\n" + draft)
          logComposer(.localDraftRestored)
        }
      }
      var files = originalFiles
      do {
        // With two coordinators, a screenshot of the feed would show one's conversation to the
        // other.
        if profiles.count == 1, let shown = profiles.first?.id,
          lanes.allSatisfy({ $0.id == shown }),
          text.split(whereSeparator: \.isWhitespace).first == "/feedback",
          !files.contains(where: { screenshotOwners[$0.id] != nil }), let screenshot
        {
          guard files.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
          // Capture once. A failed admission retains this exact image.
          let data = try screenshot()
          let file = try await attachmentStore().stage(
            data: data, name: "Feedback.png", mediaType: "image/png")
          guard attachments.count < AttachmentLimits.maximumCount else {
            try? await draftStore?.remove(file)
            throw AttachmentError.tooMany
          }
          attachments.append(file)
          files.append(file)
          screenshotOwners[file.id] = shown
          // Feedback owns private evidence, not transcript messages. Preserve the
          // screenshot and user files even when log access or staging fails.
          if attachments.count < AttachmentLimits.maximumCount {
            let diagnostics = await ComposerDiagnostics.export()
            if let log = try? await attachmentStore().stage(
              data: Data(diagnostics.text.utf8), name: "Composer.log", mediaType: "text/plain")
            {
              if attachments.count < AttachmentLimits.maximumCount {
                attachments.append(log)
                files.append(log)
              } else {
                try? await draftStore?.remove(log)
              }
            }
          }
        }
      } catch {
        failure = error.localizedDescription
        return
      }
      guard
        case .to(let recipients, let body) = address(
          text, hasAttachments: !files.isEmpty, chip: chip)
      else { return }
      // A file that may show one coordinator's feed goes to that coordinator alone.
      guard files.compactMap({ screenshotOwners[$0.id] }).allSatisfy({ recipients == [$0] }) else {
        failure =
          "Remove the automatic screenshot before sending. It could show one coordinator's messages to another."
        return
      }
      // One receipt cannot name several outboxes, so the first recipient's holds it.
      let submission = submission(identity, text: text, files: files, to: recipients.first)
      admission = .pending(text: text, submission: submission)
      // The pending identity must be durable before the independent outbox can
      // claim it. New typing and files remain separate from this submitted note.
      guard await saveDraft() else { return }
      admitted = await admit { [self] in
        await deliver(
          body, mode: mode, files: files, to: recipients, receipt: submission?.identity)
      }
      // Nothing went, so the text comes back for another try.
      guard admitted else { return }
      // The outboxes own this message even if their connections have since stopped.
      admission = .saved
      logComposer(.outboxSaved)
      if draftRevision == clearedRevision, recipient == chip { recipient = nil }
      let sentIDs = Set(files.map(\.id))
      attachments.removeAll { sentIDs.contains($0.id) }
      for id in sentIDs { screenshotOwners[id] = nil }
      retiredDraftFiles.append(contentsOf: files)
      _ = await saveDraft()
      if let source { await remove(source) }
    }
  }

  /// Saves the message in every recipient's outbox, then starts each. A refusal withdraws every
  /// staged copy, so nothing is queued anywhere. Only the first recipient's copy carries the
  /// composer's receipt. True once any recipient has the message or still will.
  private func deliver(
    _ body: String, mode: InputMode, files: [LocalAttachment], to recipients: [ProfileID],
    receipt: ComposerInputIdentity?
  ) async -> Bool {
    let sendID = UUID().uuidString
    // Cleared before staging, so what a retirement cancels during this Send stays named.
    failure = nil
    reports = []
    var staged: [(id: ProfileID, session: CoordinatorSession, input: StagedInput)] = []
    for id in recipients {
      guard let session = lanes.first(where: { $0.id == id })?.session,
        let input = await session.stage(
          body, mode: mode, files: files, sendID: sendID, recipients: recipients,
          composer: id == recipients.first ? receipt : nil)
      else {
        for item in staged { await item.session.unstage(item.input) }
        // With one coordinator saved and none removed, its own reason is the composer's error.
        if removed[id] != nil {
          report("Nothing was sent. " + Missed.removed.sentence([name(id)], "this message"))
        } else if addressesByName {
          report("Nothing was sent. \(name(id)) did not take the message.")
        }
        return false
      }
      staged.append((id, session, input))
    }
    var misses: [(ProfileID, StagedInput, Missed)] = []
    for item in staged {
      let outcome = await item.session.start(item.input)
      if let why = missed(item.id, item.input, outcome) {
        misses.append((item.id, item.input, why))
      }
    }
    report(misses)
    return misses.count < staged.count
  }

  /// The composer's receipt for a Send whose first recipient is `recipient`, or nil while that
  /// coordinator has no session to hold it.
  private func submission(
    _ identity: ComposerInputIdentity, text: String, files: [LocalAttachment],
    to recipient: ProfileID?
  ) -> ComposerSubmission? {
    lanes.first { $0.id == recipient }?.session.map {
      ComposerSubmission(
        identity: identity, outboxURL: $0.outboxURL, text: text, attachments: files,
        feedbackScreenshotID: files.first { screenshotOwners[$0.id] != nil }?.id)
    }
  }
  private func logComposer(_ event: ComposerEvent, error: (any Error)? = nil) {
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    let failure = error.map { $0 as NSError }
    let domain = failure?.domain ?? "none"
    let code = failure?.code ?? 0
    // Only state, counts and error metadata enter logs; never text, paths or addresses.
    composerLogger.notice(
      "event=\(event.rawValue, privacy: .public) build=\(build, privacy: .public) lanes=\(self.lanes.count) revision=\(self.draftRevision) characters=\(self.draft.count) attachments=\(self.attachments.count) active=\(self.active) ready=\(self.draftReady) connected=\(self.connection == .connected) busy=\(self.busy) admitting=\(self.admitting) preparing=\(self.preparingAttachments) shared=\(self.pendingSharedImport) errorDomain=\(domain, privacy: .public) errorCode=\(code)"
    )
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
  /// as it was. The input stays queued until the copy is admitted.
  func restore(_ inputID: String) async {
    guard let lane = lane(holding: inputID), readyToRestore(from: lane.id) else { return }
    preparingAttachments = true
    defer { preparingAttachments = false }
    do {
      let store = try attachmentStore()
      guard let restored = await lane.session?.restore(inputID, to: store) else { return }
      await fill(restored, from: RestoredSource(lane: lane.id, item: inputID, kind: .live), store)
    } catch { failure = error.localizedDescription }
  }
  func restoreHeld(_ message: HeldMessage) async {
    guard let lane = lanes.first(where: { $0.id == message.lane }), readyToRestore(from: lane.id)
    else { return }
    preparingAttachments = true
    defer { preparingAttachments = false }
    do {
      let store = try attachmentStore()
      guard let restored = try await lane.hold.restore(message.id, to: store) else { return }
      await fill(
        restored, from: RestoredSource(lane: lane.id, item: message.id, kind: .legacy), store)
    } catch { failure = error.localizedDescription }
  }
  func discardHeld(_ message: HeldMessage) async {
    guard let lane = lanes.first(where: { $0.id == message.lane }) else { return }
    do { try await lane.hold.discard(message.id) } catch { failure = error.localizedDescription }
    await loadHeld(lane)
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
    guard !admitting, !preparingAttachments, draft.isEmpty, attachments.isEmpty else {
      failure = "Send or clear the current draft before restoring another message."
      return false
    }
    return true
  }
  /// Puts the restored message before what the user typed or attached while its files were copied,
  /// as on `main`. What the user addressed to another coordinator meanwhile stays as it is, since
  /// the restored message stays its source's, and the copies go.
  private func fill(
    _ restored: RestoredDraft, from source: RestoredSource, _ store: AttachmentStore
  ) async {
    guard (draft.isEmpty && attachments.isEmpty) || recipient == nil || recipient == source.lane
    else {
      failure = "Send or clear the current draft before restoring another message."
      for file in restored.attachments { try? await store.remove(file) }
      return
    }
    draft = restored.text + (draft.isEmpty ? "" : "\n\n" + draft)
    attachments.insert(contentsOf: restored.attachments, at: 0)
    mode = restored.mode
    // The text may have been edited since capture, so only the file's name marks a screenshot.
    for file in restored.attachments where file.reference.name == "Feedback.png" {
      screenshotOwners[file.id] = source.lane
    }
    restoredFrom = source
    // Last, since an empty restored text clears the draft above, which drops an undrawn recipient.
    recipient = source.lane
    // The original stays queued or held until a Send carries this copy, so the copy is made
    // durable here and a relaunch keeps it.
    _ = await saveDraft()
  }
  private func forgetClearedSource() {
    // A Send in flight emptied the composer at its tap and still decides who the message is for.
    guard admission == nil, draft.isEmpty && attachments.isEmpty else { return }
    restoredFrom = nil
    // Only Restore sets a recipient no chip shows, so it goes with the draft it was set for.
    if !addressesByName { recipient = nil }
  }
  /// Runs after the restored draft was admitted. A lane removed meanwhile took its
  /// source with it.
  private func remove(_ source: RestoredSource) async {
    if restoredFrom == source { restoredFrom = nil }
    guard let lane = lanes.first(where: { $0.id == source.lane }) else { return }
    switch source.kind {
    case .live: await lane.session?.discard(source.item)
    case .legacy:
      do { try await lane.hold.discard(source.item) } catch {
        failure = error.localizedDescription
      }
      await loadHeld(lane)
    }
  }
  private func loadHeld(_ lane: Lane) async {
    do {
      let items = try await lane.hold.items()
      guard lanes.contains(where: { $0.id == lane.id }) else { return }
      held = held.filter { $0.lane != lane.id } + items.map { HeldMessage(lane: lane.id, item: $0) }
      heldError = nil
    } catch {
      heldError =
        "Messages held from before the update could not be read. They stay on this phone."
    }
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
  func attach(urls: [URL]) async {
    guard draftReady, !preparingAttachments else { return }
    preparingAttachments = true
    defer { preparingAttachments = false }
    do {
      let store = try attachmentStore()
      for url in urls {
        guard attachments.count < AttachmentLimits.maximumCount else {
          throw AttachmentError.tooMany
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        attachments.append(try await store.stage(url: url))
      }
    } catch { failure = error.localizedDescription }
  }
  func attach(providers: [NSItemProvider]) async {
    guard draftReady, !preparingAttachments else { return }
    preparingAttachments = true
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
      attachments.append(contentsOf: staged)
    } catch {
      for file in staged { try? await draftStore?.remove(file) }
      if !(error is CancellationError) { failure = error.localizedDescription }
    }
  }
  func attach(data: Data, name: String, mediaType: String) async {
    guard draftReady else { return }
    do {
      guard attachments.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
      let file = try await attachmentStore().stage(data: data, name: name, mediaType: mediaType)
      guard attachments.count < AttachmentLimits.maximumCount else {
        try? await draftStore?.remove(file)
        throw AttachmentError.tooMany
      }
      attachments.append(file)
    } catch { failure = error.localizedDescription }
  }
  #if os(iOS)
    func attach(photo: PhotosPickerItem) async {
      guard draftReady, !preparingAttachments else { return }
      preparingAttachments = true
      defer { preparingAttachments = false }
      do {
        guard let image = try await photo.loadTransferable(type: ImportedPhoto.self) else {
          throw AttachmentError.invalidFile
        }
        await attach(data: image.data, name: "Photo.jpg", mediaType: "image/jpeg")
      } catch { failure = error.localizedDescription }
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
  func toolDetails(for row: ChatRow, lane: ProfileID?) async throws -> ToolDetails {
    guard let entryID = row.entryID, let tool = row.tool, let session = session(lane) else {
      throw ConnectionError.closed
    }
    return try await session.toolDetails(entryID: entryID, callID: tool.callId)
  }
  /// Every coordinator with older history loads a page. The one holding `anchorID` keeps
  /// that row in its window.
  func history(anchorID: String?) async {
    let anchor = rows.first { $0.id == anchorID }
    let pages = lanes.compactMap { lane in
      lane.session.map { ($0, anchor?.lane == lane.id ? anchor?.row.id : nil) }
    }
    await withTaskGroup(of: Void.self) { group in
      for (session, rowID) in pages {
        group.addTask { await session.loadEarlier(anchorID: rowID) }
      }
    }
  }
  func latestHistory() async {
    let sessions = lanes.compactMap(\.session)
    await withTaskGroup(of: Void.self) { group in
      for session in sessions { group.addTask { await session.loadLatest() } }
    }
  }
  /// Stop response stops every coordinator that is working.
  func interrupt() async {
    for lane in lanes where snapshots[lane.id]?.busy == true { await lane.session?.interrupt() }
  }

  // MARK: - Feed

  func apply(_ update: ChatSnapshot, lane id: ProfileID) {
    // With several coordinators each lane's error shows on its own line instead. With one, an
    // update that neither has nor clears an error leaves the composer's own failure in place.
    if !multiple, update.error != nil || snapshots[id]?.error != nil { failure = update.error }
    snapshots[id] = update
    refresh()
  }

  /// Rebuilds the feed and the composer's view of the coordinators from every lane's state.
  private func refresh() {
    let states = lanes.compactMap { lane in
      snapshots[lane.id].map { (id: lane.id, snapshot: $0) }
    }
    let existing = Dictionary(
      rows.map { ($0.id, $0) }, uniquingKeysWith: { original, _ in original })
    let next = Feed.merge(states).map { row -> RowModel in
      guard let model = existing[row.id] else { return RowModel(row) }
      model.update(row)
      return model
    }
    if rows.map(\.id) != next.map(\.id) {
      rows = next
    } else {
      transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems)
    }
    revision &+= 1
    let all = states.map(\.snapshot)
    connection =
      [ConnectionState.connected, .reconnecting, .connecting].first { state in
        all.contains { $0.connection == state }
      } ?? .disconnected
    model = all.first?.model ?? "Unknown"
    let sole = soleLane.flatMap { snapshots[$0.id] }
    settingsSupported = sole?.settingsSupported ?? false
    workInspectionSupported = sole?.workInspectionSupported ?? false
    conversationSettings = sole?.settings
    busy = all.contains(where: \.busy)
    var usages: Set<String> = []
    commands = all.flatMap(\.commands).filter { usages.insert($0.usage).inserted }
    canLoadEarlier = all.contains { $0.olderCursor != nil }
    loadingHistory = all.contains(where: \.loadingHistory)
    includesLatest = all.allSatisfy(\.includesLatest)
  }
}
