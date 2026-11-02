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
  init(_ row: ChatRow) {
    id = row.id
    self.row = row
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
  var draft = "" { didSet { forgetClearedSource() } }
  var attachments: [LocalAttachment] = [] { didSet { forgetClearedSource() } }
  private(set) var held: [HeldMessage] = []
  private(set) var heldError: String?
  private(set) var restoredFrom: RestoredSource?
  var previewURL: URL?
  private(set) var preparingAttachments = false
  var mode: InputMode = .steer
  private(set) var admitting = false
  @ObservationIgnored private var generation = UUID()
  @ObservationIgnored private var admit:
    @Sendable (String, InputMode, [LocalAttachment]) async -> Bool
  @ObservationIgnored private var draftStore: AttachmentStore?
  @ObservationIgnored private var feedbackScreenshotID: String?
  @ObservationIgnored private let registration: NotificationRegistration?
  @ObservationIgnored private(set) var lanes: [Lane] = []
  @ObservationIgnored private var observations: [ProfileID: Task<Void, Never>] = [:]

  init(
    draftStore: AttachmentStore? = nil, registration: NotificationRegistration? = nil,
    admit: @escaping @Sendable (String, InputMode, [LocalAttachment]) async -> Bool = { _, _, _ in
      false
    }
  ) {
    self.draftStore = draftStore
    self.registration = registration
    self.admit = admit
  }
  deinit {
    for observation in observations.values { observation.cancel() }
    let sessions = lanes.compactMap(\.session)
    Task { for session in sessions { await session.disconnect() } }
  }
  // shortcut: rows do not carry their lane yet, so row actions use the one paired lane.
  // Route each row to its own lane once the feed merges lanes.
  private var session: CoordinatorSession? { lanes.first { $0.session != nil }?.session }

  /// Adds a saved coordinator's lane, or replaces an unpaired lane with its paired one.
  /// A lane whose session was live must be detached first, so two sessions never share
  /// an outbox. Connecting is `setActive`'s job.
  func attach(_ lane: Lane) {
    observations.removeValue(forKey: lane.id)?.cancel()
    if let index = lanes.firstIndex(where: { $0.id == lane.id }) {
      lanes[index] = lane
    } else {
      lanes.append(lane)
    }
    if let session = lane.session {
      admit = { text, mode, files in await session.submit(text, mode: mode, files: files) }
      rows = []
      error = nil
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
      generation = UUID()
      admit = { _, _, _ in false }
      apply(ChatSnapshot())
    }
    await lane.session?.disconnect()
  }

  func setActive(_ active: Bool) async {
    for session in lanes.compactMap(\.session) {
      if active { await session.connect() } else { await session.disconnect() }
    }
  }

  /// "Try again": reconnects now instead of waiting out the backoff.
  func reconnect() async { await session?.connect() }

  private func observe(_ session: CoordinatorSession, lane id: ProfileID) -> Task<Void, Never> {
    Task { [weak self] in
      var connected = false
      for await update in session.updates {
        guard !Task.isCancelled, let self else { return }
        self.apply(update)
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

  var canSend: Bool {
    !admitting && !preparingAttachments && connection == .connected
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }
  func send(screenshot: (@MainActor () throws -> Data)? = nil) async {
    guard canSend
    else { return }
    admitting = true
    defer { admitting = false }
    let text = draft
    let mode = mode
    let generation = generation
    let admit = admit
    let source = restoredFrom
    var files = attachments
    do {
      if text.split(whereSeparator: \.isWhitespace).first == "/feedback",
        feedbackScreenshotID == nil, let screenshot
      {
        guard files.count < AttachmentLimits.maximumCount else { throw AttachmentError.tooMany }
        // Capture before the composer changes. A failed admission retains this exact image.
        let data = try screenshot()
        let file = try await attachmentStore().stage(
          data: data, name: "Feedback.png", mediaType: "image/png")
        guard self.generation == generation else {
          try? await draftStore?.remove(file)
          return
        }
        attachments.append(file)
        files.append(file)
        feedbackScreenshotID = file.id
      }
    } catch {
      self.error = error.localizedDescription
      return
    }
    guard self.generation == generation else { return }
    // Keep the draft until the owned actor has validated and saved the input.
    // Failures also remain available in the input row for copy/retry.
    if await admit(text, mode, files), self.generation == generation {
      if draft == text { draft = "" }
      let sentIDs = Set(files.map(\.id))
      attachments.removeAll { sentIDs.contains($0.id) }
      if let id = feedbackScreenshotID, sentIDs.contains(id) { feedbackScreenshotID = nil }
      if let store = draftStore {
        for file in files { try? await store.remove(file) }
      }
      if let source { await remove(source) }
    }
  }
  func restore(_ id: String) async {
    guard readyToRestore() else { return }
    do {
      let store = try attachmentStore()
      guard let lane = lanes.first(where: { $0.session != nil }),
        let restored = await lane.session?.restore(id, to: store)
      else { return }
      fill(restored, from: RestoredSource(lane: lane.id, item: id, kind: .live))
    } catch { self.error = error.localizedDescription }
  }
  func restoreHeld(_ message: HeldMessage) async {
    guard readyToRestore(), let lane = lanes.first(where: { $0.id == message.lane }) else {
      return
    }
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
  private func readyToRestore() -> Bool {
    guard !admitting, draft.isEmpty, attachments.isEmpty else {
      error = "Send or clear the current draft before restoring another message."
      return false
    }
    return true
  }
  private func fill(_ restored: RestoredDraft, from source: RestoredSource) {
    draft = restored.text
    attachments = restored.attachments
    mode = restored.mode
    if restored.text.split(whereSeparator: \.isWhitespace).first == "/feedback" {
      feedbackScreenshotID =
        restored.attachments.last(where: { $0.reference.name == "Feedback.png" })?.id
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
    if feedbackScreenshotID == file.id { feedbackScreenshotID = nil }
    try? await draftStore?.remove(file)
  }
  func preview(_ reference: AttachmentRef) async {
    do { previewURL = try await session?.preview(reference) } catch {
      self.error = error.localizedDescription
    }
  }
  func retry(_ id: String) async { await session?.retry(id) }
  func toolDetails(for row: ChatRow) async throws -> ToolDetails {
    guard let entryID = row.entryID, let tool = row.tool, let session else {
      throw ConnectionError.closed
    }
    return try await session.toolDetails(entryID: entryID, callID: tool.callId)
  }
  func history(anchorID: String?) async { await session?.loadEarlier(anchorID: anchorID) }
  func latestHistory() async { await session?.loadLatest() }
  func interrupt() async { await session?.interrupt() }
  private func apply(_ update: ChatSnapshot) {
    let existing = Dictionary(
      rows.map { ($0.id, $0) }, uniquingKeysWith: { original, _ in original })
    let next = update.rows.map { row -> RowModel in
      if let model = existing[row.id] {
        if model.row != row { model.row = row }
        return model
      }
      return RowModel(row)
    }
    if rows.map(\.id) != next.map(\.id) {
      rows = next
    } else {
      transcriptItems = TranscriptItem.grouped(rows, preserving: transcriptItems)
    }
    revision &+= 1
    connection = update.connection
    model = update.model
    busy = update.busy
    commands = update.commands
    canLoadEarlier = update.olderCursor != nil
    loadingHistory = update.loadingHistory
    includesLatest = update.includesLatest
    error = update.error
  }
}
