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
  var error: String?
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
  var draft = "" { didSet { forgetClearedSource() } }
  var attachments: [LocalAttachment] = [] { didSet { forgetClearedSource() } }
  private(set) var held: [HeldMessage] = []
  private(set) var heldError: String?
  private(set) var restoredFrom: RestoredSource?
  /// Each lane's latest published state.
  private(set) var snapshots: [ProfileID: ChatSnapshot] = [:]
  var previewURL: URL?
  private(set) var preparingAttachments = false
  var mode: InputMode = .steer
  private(set) var admitting = false
  @ObservationIgnored private var draftStore: AttachmentStore?
  /// Draft files that may show a coordinator's feed, by attachment ID, each with the one
  /// coordinator it was captured for.
  @ObservationIgnored private var screenshotOwners: [String: ProfileID] = [:]
  @ObservationIgnored private let registration: NotificationRegistration?
  @ObservationIgnored private(set) var lanes: [Lane] = []
  @ObservationIgnored private var observations: [ProfileID: Task<Void, Never>] = [:]

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
      if !multiple { error = nil }
      refresh()
      observations[lane.id] = observe(session, lane: lane.id)
    }
    Task { await loadHeld(lane) }
  }

  /// Stops sends to the lane and quiesces its session before returning, so nothing writes
  /// to the profile's directory afterwards.
  func detach(_ id: ProfileID) async {
    guard let index = lanes.firstIndex(where: { $0.id == id }) else { return }
    let lane = lanes.remove(at: index)
    observations.removeValue(forKey: id)?.cancel()
    registration?.disconnect(id)
    held.removeAll { $0.lane == id }
    if lane.session != nil {
      snapshots[id] = nil
      if !multiple { error = nil }
      refresh()
    }
    await lane.session?.disconnect()
  }

  func setActive(_ active: Bool) async {
    for session in lanes.compactMap(\.session) {
      if active { await session.connect() } else { await session.disconnect() }
    }
  }

  /// "Try again": reconnects now instead of waiting out the backoff, one lane or every lane
  /// that is not connected.
  func reconnect(_ id: ProfileID? = nil) async {
    for lane in lanes where id == lane.id || (id == nil && !connected(lane.id)) {
      await lane.session?.connect()
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
    if recipient == id || restoredFrom?.lane == id { return true }
    guard recipient == nil, let name = profiles.first(where: { $0.id == id })?.name.description
    else { return false }
    return Addressing.leadingTags(draft).tags.contains { $0.lowercased() == name.lowercased() }
  }

  private func address(_ text: String, hasAttachments: Bool, chip: ProfileID?) -> Addressing {
    // A restored message stays its source's under any chip, so a removed source blocks it.
    if let source = restoredFrom?.lane, let name = removed[source] {
      return .blocked("\(name) was removed")
    }
    return Addressing.parse(
      text, hasAttachments: hasAttachments, chip: chip,
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

  /// Saved coordinators matching an `@` still being typed, for the picker above the composer.
  var pickerMatches: [CoordinatorProfile] {
    guard multiple, recipient == nil, draft.first == "@", !draft.contains(where: \.isWhitespace)
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
  /// never read for tags. The composer calls this after each edit.
  func promoteTypedTag() {
    guard multiple, recipient == nil, draft.first == "@" else { return }
    let word = draft.dropFirst().prefix { !$0.isWhitespace }
    let named = profiles.filter { $0.name.description.lowercased() == word.lowercased() }
    guard word.endIndex < draft.endIndex, let match = named.first, named.count == 1 else { return }
    recipient = match.id
    draft = String(draft[draft.index(after: word.endIndex)...])
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
    let mode = mode
    let source = restoredFrom
    let chip = recipient
    var files = attachments
    do {
      // With two coordinators, a screenshot of the feed would show one's conversation to the other.
      if profiles.count == 1, let shown = profiles.first?.id, lanes.allSatisfy({ $0.id == shown }),
        text.split(whereSeparator: \.isWhitespace).first == "/feedback",
        !files.contains(where: { screenshotOwners[$0.id] != nil }), let screenshot
      {
        guard files.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
        // Capture before the composer changes. A failed admission retains this exact image.
        let data = try screenshot()
        let file = try await attachmentStore().stage(
          data: data, name: "Feedback.png", mediaType: "image/png")
        attachments.append(file)
        files.append(file)
        screenshotOwners[file.id] = shown
      }
    } catch {
      self.error = error.localizedDescription
      return
    }
    guard
      case .to(let recipients, let body) = address(
        text, hasAttachments: !files.isEmpty, chip: chip)
    else { return }
    // A file that may show one coordinator's feed goes to that coordinator alone.
    guard files.compactMap({ screenshotOwners[$0.id] }).allSatisfy({ recipients == [$0] }) else {
      error =
        "Remove the automatic screenshot before sending. It could show one coordinator's messages to another."
      return
    }
    let sendID = UUID().uuidString
    var staged: [(id: ProfileID, session: CoordinatorSession, input: StagedInput)] = []
    for id in recipients {
      guard let session = lanes.first(where: { $0.id == id })?.session,
        let input = await session.stage(
          body, mode: mode, files: files, sendID: sendID, recipients: recipients)
      else {
        for item in staged where attached(item.session) { await item.session.unstage(item.input) }
        if multiple { error = "Nothing was sent. \(name(id)) did not take the message." }
        return
      }
      staged.append((id, session, input))
    }
    // A lane detached meanwhile keeps its saved item for its own profile to resolve.
    var missed: [ProfileID] = []
    for item in staged where attached(item.session) {
      if await !item.session.start(item.input) { missed.append(item.id) }
    }
    error = nil
    if !missed.isEmpty {
      let command = body.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? body
      error =
        "\(joinedNames(missed.map(name))) did not get \(command). \(missed.count == 1 ? "It is" : "They are") not connected."
      // Nothing went, so the draft stays for another try.
      guard missed.count < staged.count else { return }
    }
    if draft == text {
      draft = ""
      if recipient == chip { recipient = nil }
    }
    let sentIDs = Set(files.map(\.id))
    attachments.removeAll { sentIDs.contains($0.id) }
    for id in sentIDs { screenshotOwners[id] = nil }
    if let store = draftStore {
      for file in files { try? await store.remove(file) }
    }
    if let source { await remove(source) }
  }

  private func attached(_ session: CoordinatorSession) -> Bool {
    lanes.contains { $0.session === session }
  }

  // MARK: - Restore

  /// Copies a queued input into the composer, addressed to its own coordinator, with its text
  /// as it was. The input stays queued until the copy is admitted.
  func restore(_ inputID: String) async {
    guard let lane = lane(holding: inputID), readyToRestore(from: lane.id) else { return }
    do {
      let store = try attachmentStore()
      guard let restored = await lane.session?.restore(inputID, to: store) else { return }
      fill(restored, from: RestoredSource(lane: lane.id, item: inputID, kind: .live))
    } catch { self.error = error.localizedDescription }
  }
  func restoreHeld(_ message: HeldMessage) async {
    guard let lane = lanes.first(where: { $0.id == message.lane }), readyToRestore(from: lane.id)
    else { return }
    do {
      guard let restored = try await lane.hold.restore(message.id, to: attachmentStore())
      else { return }
      fill(restored, from: RestoredSource(lane: lane.id, item: message.id, kind: .legacy))
    } catch { self.error = error.localizedDescription }
  }
  func discardHeld(_ message: HeldMessage) async {
    guard let lane = lanes.first(where: { $0.id == message.lane }) else { return }
    do { try await lane.hold.discard(message.id) } catch { self.error = error.localizedDescription }
    await loadHeld(lane)
  }
  private func readyToRestore(from lane: ProfileID) -> Bool {
    if let name = removed[lane] {
      error = "\(name) is being removed."
      return false
    }
    guard !admitting, draft.isEmpty, attachments.isEmpty else {
      error = "Send or clear the current draft before restoring another message."
      return false
    }
    return true
  }
  private func fill(_ restored: RestoredDraft, from source: RestoredSource) {
    recipient = source.lane
    draft = restored.text
    attachments = restored.attachments
    mode = restored.mode
    // The text may have been edited since capture, so only the file's name marks a screenshot.
    for file in restored.attachments where file.reference.name == "Feedback.png" {
      screenshotOwners[file.id] = source.lane
    }
    restoredFrom = source
  }
  private func forgetClearedSource() {
    if draft.isEmpty && attachments.isEmpty { restoredFrom = nil }
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
        self.error = error.localizedDescription
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
    } catch { self.error = error.localizedDescription }
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
    } catch { self.error = error.localizedDescription }
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
      } catch { self.error = error.localizedDescription }
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
      self.error = error.localizedDescription
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
    snapshots[id] = update
    // With several coordinators each lane's error shows on its own line instead.
    if !multiple { error = update.error }
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
