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
  func update(_ feed: FeedRow) {
    if row != feed.row { row = feed.row }
    if lane != feed.lane { lane = feed.lane }
    if receipts != feed.receipts { receipts = feed.receipts }
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

/// Where the composer's restored draft came from, and what Restore put in it. The source stays
/// queued or held until a Send carries that content unchanged to its coordinator, or the user
/// discards it, so nothing its coordinator did not get is lost.
struct RestoredSource: Equatable {
  enum Kind: Equatable {
    case live
    /// Held from before the update in `queue`.
    case held(queue: UUID)
  }
  /// Its coordinator.
  let lane: ProfileID
  let item: String
  let kind: Kind
  let text: String
  /// The IDs of the file copies Restore put in the composer.
  let files: Set<String>

  /// True when a Send of `body` with `sent` files to `recipients` carries this content unchanged to
  /// its coordinator, meaning the same text, ignoring surrounding whitespace, and every file Restore
  /// put in the composer.
  func isCarried(by body: String, files sent: [LocalAttachment], to recipients: [ProfileID])
    -> Bool
  {
    recipients.contains(lane)
      && body.trimmingCharacters(in: .whitespacesAndNewlines)
        == text.trimmingCharacters(in: .whitespacesAndNewlines)
      && files.isSubset(of: sent.map(\.id))
  }
}

/// The one feed and the one composer for every saved coordinator.
@MainActor @Observable
final class ChatModel {
  var rows: [RowModel] = [] {
    didSet { transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems) }
  }
  private(set) var transcriptItems: [TranscriptItem] = []
  var connection: ConnectionState = .disconnected
  var model = "Main conversation"
  var commands: [SlashCommand] = []
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
  var profiles: [CoordinatorProfile] = []
  /// The one coordinator the draft goes to, or nil for every paired one. While it is set, the
  /// draft is never read for tags.
  var recipient: ProfileID?
  /// The latest tag that became the chip, so the composer moves the caret back by exactly what
  /// the draft lost.
  private(set) var promotion: Promotion?
  /// Coordinators removed in this process, or being removed, by the name they had. Nothing
  /// addresses one again, and profile IDs are never reused.
  var removed: [ProfileID: String] = [:]
  /// What the composer holds. A draft changed in code replaces the field's text, composition
  /// included, so all of it is committed.
  var draft = "" {
    didSet {
      draftRevision &+= 1
      committed = draft
      forgetClearedSource()
    }
  }
  /// Counts every change to the draft, so a Send clears only the draft it admitted, never a newer
  /// one with the same text.
  @ObservationIgnored private var draftRevision = 0
  /// The draft without the text an input method is still composing in the field, and the only text
  /// tags are read from. A composition is tentative until the input method commits it, so it never
  /// picks a recipient or changes the picker before then.
  private(set) var committed = ""
  var attachments: [LocalAttachment] = [] { didSet { forgetClearedSource() } }
  /// The queues the single-address build left, kept by `Coordinators`, each with the store that
  /// reads its folder. A queue that arrives is read at once.
  var holds: [Hold] = [] {
    didSet {
      let current = Set(holds.map(\.queue.id))
      for id in reads.keys where !current.contains(id) { reads[id] = nil }
      let known = Set(oldValue.map(\.queue.id))
      for hold in holds where !known.contains(hold.queue.id) { Task { await read(hold) } }
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
  /// Shown while any queue's held messages could not be read when last loaded.
  var heldError: String? {
    reads.values.contains { if case .failure = $0 { true } else { false } }
      ? "Messages held from before the update could not be read. They stay on this phone." : nil
  }
  /// Each queue's latest read of its messages.
  private var reads: [UUID: Result<[LegacyItem], any Error>] = [:]
  /// The coordinator whose restored message the draft holds. While it is set, no tag in the draft
  /// is read and the draft stays that coordinator's, however it is edited. Only clearing the draft
  /// ends it, and the field's Undo never reaches back past that.
  private(set) var restoredFrom: ProfileID?
  /// The original Restore copied into the draft, until the next Send or until the composer is
  /// emptied. A Send that carries it unchanged to its coordinator withdraws it.
  private(set) var source: RestoredSource?
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
  var mode: InputMode = .steer
  private(set) var admitting = false
  @ObservationIgnored private var draftStore: AttachmentStore?
  /// Draft files that may show a coordinator's feed, by attachment ID, each with the one
  /// coordinator it was captured for.
  @ObservationIgnored private var screenshotOwners: [String: ProfileID] = [:]
  @ObservationIgnored private let registration: NotificationRegistration?
  /// Whether the latest `setActive` asked for the app to be active.
  @ObservationIgnored private(set) var active = false
  @ObservationIgnored private(set) var lanes: [Lane] = []
  @ObservationIgnored private var observations: [ProfileID: Task<Void, Never>] = [:]
  /// Inputs of a Send that reached no one, staged at a session that was retired before they could
  /// be withdrawn, by profile. The profile's next session withdraws them once it is attached.
  @ObservationIgnored private var unstaging: [ProfileID: [StagedInput]] = [:]

  init(draftStore: AttachmentStore? = nil, registration: NotificationRegistration? = nil) {
    self.draftStore = draftStore
    self.registration = registration
  }
  deinit {
    for observation in observations.values { observation.cancel() }
    let sessions = lanes.compactMap(\.session)
    Task { for session in sessions { await session.disconnect() } }
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
      if let inputs = unstaging.removeValue(forKey: lane.id) {
        Task { for input in inputs { await withdraw(input, from: session, lane: lane.id) } }
      }
    }
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

  // MARK: - Addressing

  /// Who Send reaches with the current draft, or why it is blocked.
  var addressing: Addressing {
    address(draft, hasAttachments: !attachments.isEmpty, chip: recipient)
  }

  /// True while the draft is the coordinator's: chosen as the chip, restored from it, or led
  /// by a typed tag with its name.
  func addresses(_ id: ProfileID) -> Bool {
    if recipient == id || restoredFrom == id { return true }
    guard recipient == nil, restoredFrom == nil,
      let name = profiles.first(where: { $0.id == id })?.name.description
    else { return false }
    return Addressing.leadingTags(draft).tags.contains { $0.lowercased() == name.lowercased() }
  }

  private func address(_ text: String, hasAttachments: Bool, chip: ProfileID?) -> Addressing {
    // A restored message stays its source's under any chip, so a removed source blocks it.
    if let lane = restoredFrom, let name = removed[lane] {
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

  /// Saved coordinators matching an `@` still being typed in the committed text, for the picker
  /// above the composer. A restored draft offers none, since choosing one replaces the draft.
  var pickerMatches: [CoordinatorProfile] {
    guard addressesByName, recipient == nil, restoredFrom == nil, committed.first == "@",
      !committed.contains(where: \.isWhitespace)
    else { return [] }
    let typed = committed.dropFirst().lowercased()
    return profiles.filter {
      removed[$0.id] == nil && $0.name.description.lowercased().hasPrefix(typed)
    }
  }

  func choose(_ id: ProfileID) {
    guard removed[id] == nil else { return }
    recipient = id
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
    guard addressesByName, recipient == nil, restoredFrom == nil, committed == draft,
      draft.first == "@"
    else { return }
    let word = draft.dropFirst().prefix { !$0.isWhitespace }
    let named = profiles.filter { $0.name.description.lowercased() == word.lowercased() }
    guard word.endIndex < draft.endIndex, let match = named.first, named.count == 1 else { return }
    recipient = match.id
    let typed = draft
    draft = String(draft[draft.index(after: word.endIndex)...])
    promotion = Promotion(typed: typed, rest: draft)
  }

  // MARK: - Send

  var canSend: Bool {
    guard !admitting, !preparingAttachments, case .to = addressing else { return false }
    return true
  }

  /// Saves the message in every recipient's outbox before any of them starts, so a refusal
  /// leaves nothing queued anywhere and the draft untouched.
  func send(screenshot: (@MainActor () throws -> Data)? = nil) async {
    guard canSend else { return }
    admitting = true
    defer { admitting = false }
    let text = draft
    let submittedDraftRevision = draftRevision
    let mode = mode
    let original = source
    let chip = recipient
    var files = attachments
    // With one coordinator saved, `/feedback` attaches the screen, so the composer says why it did not.
    var withheld = false
    do {
      if text.split(whereSeparator: \.isWhitespace).first == "/feedback",
        !files.contains(where: { screenshotOwners[$0.id] != nil }), let screenshot
      {
        // The screenshot shows the feed, so it goes only where everything the feed shows belongs.
        if let shown = feedOwner {
          guard files.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
          // Capture before the composer changes. A failed admission retains this exact image.
          let data = try screenshot()
          let file = try await attachmentStore().stage(
            data: data, name: "Feedback.png", mediaType: "image/png")
          attachments.append(file)
          files.append(file)
          screenshotOwners[file.id] = shown
        } else {
          withheld = !multiple
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
    let sendID = UUID().uuidString
    // Cleared before staging, so what a retirement cancels during this Send stays named.
    failure = nil
    reports = []
    var staged: [(id: ProfileID, session: CoordinatorSession, input: StagedInput)] = []
    for id in recipients {
      guard let session = lanes.first(where: { $0.id == id })?.session,
        let input = await session.stage(
          body, mode: mode, files: files, sendID: sendID, recipients: recipients)
      else {
        for item in staged { await withdraw(item.input, from: item.session, lane: item.id) }
        // With one coordinator saved and none removed, its own reason is the composer's error.
        if removed[id] != nil {
          report("Nothing was sent. " + Missed.removed.sentence([name(id)], "this message"))
        } else if addressesByName {
          report("Nothing was sent. \(name(id)) did not take the message.")
        }
        return
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
    // Nothing went, so the draft stays for another try.
    guard misses.count < staged.count else { return }
    if withheld {
      report(
        "Feedback was sent without a screenshot. The screen shows messages held from before the update, which may be another coordinator's."
      )
    }
    if draftRevision == submittedDraftRevision {
      draft = ""
      restoredFrom = nil
      if recipient == chip { recipient = nil }
    }
    let sentIDs = Set(files.map(\.id))
    attachments.removeAll { sentIDs.contains($0.id) }
    for id in sentIDs { screenshotOwners[id] = nil }
    if let store = draftStore {
      for file in files { try? await store.remove(file) }
    }
    guard let original else { return }
    if source == original { source = nil }
    if original.isCarried(by: body, files: files, to: recipients) { await remove(original) }
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
  /// else to `chosen`, and with neither does nothing. It stays held until a Send carries the copy
  /// unchanged to its owner, since only that one is known to be the coordinator it was queued for.
  func restoreHeld(_ message: HeldMessage, for chosen: ProfileID? = nil) async {
    let owner = owner(message)
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
  /// Puts the restored message before what the user typed or attached while its files were copied,
  /// as on `main`. What the user addressed to another coordinator meanwhile stays as it is, since
  /// the restored message stays `lane`'s, and the copies go. Without a `source` it is a copy that
  /// withdraws nothing.
  private func fill(
    _ restored: RestoredDraft, for lane: ProfileID,
    source original: (item: String, kind: RestoredSource.Kind)?, _ store: AttachmentStore
  ) async {
    guard (draft.isEmpty && attachments.isEmpty) || recipient == nil || recipient == lane
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
      screenshotOwners[file.id] = lane
    }
    restoredFrom = lane
    source = original.map {
      RestoredSource(
        lane: lane, item: $0.item, kind: $0.kind, text: restored.text,
        files: Set(restored.attachments.map(\.id)))
    }
    // Last, since an empty restored text clears the draft above, which drops an undrawn recipient.
    recipient = lane
  }
  private func forgetClearedSource() {
    guard draft.isEmpty && attachments.isEmpty else { return }
    restoredFrom = nil
    source = nil
    // Only Restore sets a recipient no chip shows, so it goes with the draft it was set for.
    if !addressesByName { recipient = nil }
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
  func attach(urls: [URL]) async {
    guard !preparingAttachments else { return }
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
  func attach(data: Data, name: String, mediaType: String) async {
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
      guard !preparingAttachments else { return }
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
    guard !admitting else { return }
    attachments.removeAll { $0.id == file.id }
    screenshotOwners[file.id] = nil
    try? await draftStore?.remove(file)
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
    model = all.first?.model ?? "Main conversation"
    busy = all.contains(where: \.busy)
    var usages: Set<String> = []
    commands = all.flatMap(\.commands).filter { usages.insert($0.usage).inserted }
    canLoadEarlier = all.contains { $0.olderCursor != nil }
    loadingHistory = all.contains(where: \.loadingHistory)
    includesLatest = all.allSatisfy(\.includesLatest)
  }
}
