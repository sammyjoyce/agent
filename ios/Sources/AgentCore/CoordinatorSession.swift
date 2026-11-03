import Foundation

public enum ConnectionState: Sendable, Equatable {
  case disconnected, connecting, connected, reconnecting
  public var label: String {
    switch self {
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connected: "Connected via Tailscale"
    case .reconnecting: "Reconnecting…"
    }
  }
}

private struct CoordinatorRejection: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// A notification control's answer: one status, then `done`.
func notificationStatus(on stream: VerifiedConnection) async throws -> NotificationStatus {
  var status: NotificationStatus?
  while true {
    switch try await timedNext(stream) {
    case .notifications(let value):
      guard status == nil else { throw ConnectionError.incompleteFrame }
      status = value.status
    case .done:
      guard let status else { throw ConnectionError.incompleteFrame }
      return status
    case .failure(let value): throw CoordinatorRejection(message: value.message)
    default: throw ConnectionError.incompleteFrame
    }
  }
}

public struct ChatSnapshot: Sendable {
  public var rows: [ChatRow] = []
  public var connection: ConnectionState = .disconnected
  public var conversationID: String?
  public var model = "Main conversation"
  public var busy = false
  public var commands: [SlashCommand] = []
  public var olderCursor: String?
  public var loadingHistory = false
  public var includesLatest = true
  public var error: String?
  /// Every Send this coordinator holds, from its outbox and ledger rather than the loaded
  /// rows, so a Send whose row left the window still reports.
  public var sends: [String: SendStatus] = [:]
  public init() {}
}

/// One coordinator's part in a Send, from a record this phone holds.
public struct SendStatus: Sendable, Equatable {
  public enum Progress: Sendable, Equatable {
    /// Still in this coordinator's outbox.
    case pending(Delivery)
    case placed
    /// Its queued item was removed because the user sent a restored copy instead, and the
    /// coordinator refused it.
    case withdrawn
    /// Its queued item was withdrawn, but the coordinator reports holding it. It may still place it.
    case held
  }
  /// Everyone the Send was addressed to.
  public let recipients: [ProfileID]
  public let progress: Progress
}

public struct RestoredDraft: Sendable {
  public let text: String
  public let mode: InputMode
  public let attachments: [LocalAttachment]
}

/// An input `stage` saved, waiting for `start` or `unstage` on the same session.
public struct StagedInput: Sendable, Equatable {
  public let inputID: String
  public let sendID: String
  let profile: ProfileID
  /// A control command is not durable, so it waits here instead of in the outbox.
  let control: NativeRequestSubmit?
  /// A control's command, such as `/status`, or nil for an input the outbox keeps.
  public var command: String? {
    control.map { $0.text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? $0.text }
  }
}

/// What `start` did with a staged input.
public enum StartOutcome: Sendable, Equatable {
  /// It is on its way. A durable one may instead wait in the outbox for this lane or for Check.
  case started
  /// A control that cannot go now. It is saved nowhere, so it is not sent at all.
  case notSent
  /// This session was retired first and sent nothing. A durable input stays in the outbox, for the
  /// profile's next session or for Remove to delete.
  case retired
}

/// Owns all network work, decoding, rendering preparation and the on-device outbox.
/// Reconnect observes and reconciles. It never automatically replays an uncertain write.
public actor CoordinatorSession {
  public nonisolated let updates: AsyncStream<ChatSnapshot>
  nonisolated let profile: ProfileID
  private let continuation: AsyncStream<ChatSnapshot>.Continuation
  private var snapshot = ChatSnapshot()
  private var transcript = Transcript()
  private let dialer: CoordinatorDialer
  private var observation: Task<Void, Never>?
  private var connection: VerifiedConnection?
  /// An identity failure stays on screen through reconnects until a connection succeeds.
  private var identityFailure: String?
  private var actions: [UUID: Task<Void, Never>] = [:]
  private enum HistoryWindow {
    case earlier(cursor: String, anchorID: String?)
    case latest
  }
  private struct HistoryAction {
    let id: UUID
    let window: HistoryWindow
  }
  private var historyAction: HistoryAction?
  private var latestRowID: String?
  private var actionConnections: [UUID: VerifiedConnection] = [:]
  private var previewRequests: Set<UUID> = []
  private var pending: [OutboxItem] = []
  /// The outbox is read once per session. Its items then hold the coordinator's latest word even
  /// when a save fails.
  private var loaded = false
  private enum Unsent { case staged, waiting }
  /// Durable inputs this process staged that have not left the phone. Only a staged one can be
  /// unstaged. A started one waits for this lane to connect, then sends once.
  private var unsent: [String: Unsent] = [:]
  /// Exchanges that have not written their input to the coordinator yet, by action. `started` is
  /// the input a Send started, and nil for Check / retry of a queued one.
  private var unwritten: [(action: UUID, inputID: String, started: StagedInput?)] = []
  private var attemptedInputs: Set<String> = []
  /// Set for good by `retire`. A retired session never connects, sends or writes again.
  private var retired = false
  private var generation = UUID()
  private var flush: Task<Void, Never>?
  private let outboxURL: URL
  private let attachments: AttachmentStore
  private let previews: AttachmentStore
  private let stamps: StampSource
  private let ledgerURL: URL
  private var ledger: Ledger
  /// Each visible row's receive stamp, kept by row ID so a row that changes key keeps it.
  private var rowStamps: [String: TimeInterval] = [:]

  /// Every socket reaches `address` and must name `pin`. A profile without a pin has no session.
  /// Every session in the process shares `stamps`.
  public init(
    directory: ProfileDirectory, address: CoordinatorAddress, pin: CoordinatorID,
    stamps: StampSource, transport: CoordinatorTransport = .tailnet
  ) {
    profile = directory.profile
    dialer = CoordinatorDialer(address: address, pin: pin, transport: transport)
    outboxURL = directory.outbox
    attachments = AttachmentStore(directory: directory.outboxAttachments)
    previews = AttachmentStore(directory: directory.previews)
    self.stamps = stamps
    ledgerURL = directory.ledger
    // Loaded before any session connects, so every saved stamp seeds the shared source. A
    // missing or unreadable ledger only loses receive order and send records, so it never
    // blocks the session.
    ledger =
      (try? JSONDecoder().decode(Ledger.self, from: Data(contentsOf: directory.ledger)))
      ?? Ledger()
    if let newest = ledger.entries.values.map(\.receivedAt).max() { stamps.seed(newest) }
    let pair = AsyncStream<ChatSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    updates = pair.stream
    continuation = pair.continuation
  }

  public func connect() async {
    guard !retired else { return }
    let generation = UUID()
    await disconnect(generation: generation)
    guard self.generation == generation else { return }
    identityFailure = nil
    if !loaded {
      do {
        pending = try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: outboxURL))
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        pending = []
      } catch {
        snapshot.error =
          "The saved outbox could not be read. It was preserved; no messages were replayed."
        publish()
        return
      }
      loaded = true
    }
    if let newest = pending.map(\.queuedAt).max() { stamps.seed(newest) }
    // The outbox belongs to this profile and every socket proves its pinned coordinator,
    // so these IDs reach only the coordinator they were queued for.
    for item in pending {
      let mayHaveLeft = unsent[item.request.inputId] == nil
      if mayHaveLeft { attemptedInputs.insert(item.request.inputId) }
      transcript.pending(item.request, delivery: mayHaveLeft ? .uncertain : .sending)
    }
    stampRows()
    snapshot.error = nil
    observation = Task { [weak self] in await self?.observe(generation: generation) }
  }

  public func disconnect() async { await disconnect(generation: UUID()) }

  /// Ends this session when its lane leaves the feed, before its profile's files may be deleted.
  /// It disconnects, and whoever still holds it, it never connects, sends or writes its
  /// directory again. Returns, once, the started inputs it cancels before they left the phone:
  /// durable ones waiting for this lane, and any an exchange had not written yet. A staged input
  /// that was not started is its sender's to report, since `start` then answers `.retired`.
  @discardableResult public func retire() async -> [StagedInput] {
    guard !retired else { return [] }
    retired = true
    let waiting = pending.filter { unsent[$0.request.inputId] == .waiting }.map { staged($0) }
    let cancelled = waiting + unwritten.compactMap(\.started)
    await disconnect()
    return cancelled
  }
  private func staged(_ item: OutboxItem) -> StagedInput {
    StagedInput(inputID: item.request.inputId, sendID: item.sendID, profile: profile, control: nil)
  }
  private func disconnect(generation: UUID) async {
    self.generation = generation
    observation?.cancel()
    observation = nil
    flush?.cancel()
    flush = nil
    for action in actions.values { action.cancel() }
    actions = [:]
    unwritten = []
    historyAction = nil
    let ownedConnections = Array(actionConnections.values) + [connection].compactMap { $0 }
    actionConnections = [:]
    connection = nil
    snapshot.connection = .disconnected
    snapshot.busy = false
    snapshot.loadingHistory = false
    for item in pending where unsent[item.request.inputId] == nil {
      transcript.delivery(item.request.inputId, .uncertain)
    }
    publish()
    for connection in ownedConnections { await connection.close() }
  }

  /// Stages and starts at once, addressed to this coordinator alone.
  @discardableResult public func submit(
    _ text: String, mode: InputMode = .steer, files: [LocalAttachment] = []
  ) async -> Bool {
    guard
      let staged = await stage(
        text, mode: mode, files: files, sendID: UUID().uuidString, recipients: [profile])
    else { return false }
    start(staged)
    return true
  }

  /// Validates the input, copies `files` into this coordinator's outbox and saves the item
  /// there. Nothing leaves the phone until `start`. Returns nil, with any reason in the
  /// snapshot's error, when this coordinator cannot take it.
  public func stage(
    _ text: String, mode: InputMode = .steer, files: [LocalAttachment] = [], sendID: String,
    recipients: [ProfileID]
  ) async -> StagedInput? {
    guard !retired, actions.count < 32, snapshot.connection == .connected,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
    else { return nil }
    guard text.utf8.count <= 65536 else {
      snapshot.error = "Messages must be at most 64 KiB."
      publish()
      return nil
    }
    guard files.count <= AttachmentLimits.maximumCount,
      Set(files.map(\.id)).count == files.count
    else {
      snapshot.error = AttachmentError.tooMany.localizedDescription
      publish()
      return nil
    }
    let feedback = text.split(whereSeparator: \.isWhitespace).first == "/feedback"
    let control =
      text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
      || text.trimmingCharacters(in: .whitespacesAndNewlines) == "?"
    guard files.isEmpty || !control || feedback else {
      snapshot.error = "Files can be sent with messages or /feedback."
      publish()
      return nil
    }
    let generation = generation
    var adopted: [AttachmentRef] = []
    do {
      for file in files {
        // A quiesced session writes nothing more into its directory.
        guard self.generation == generation else { break }
        adopted.append(try await attachments.adopt(file).reference)
      }
    } catch {
      await removeFiles(adopted).value
      snapshot.error = error.localizedDescription
      publish()
      return nil
    }
    guard self.generation == generation, snapshot.connection == .connected, actions.count < 32
    else {
      await removeFiles(adopted).value
      return nil
    }
    let request = NativeRequestSubmit(
      attachments: files.isEmpty && !feedback ? nil : files.map(\.reference),
      inputId: UUID().uuidString, mode: mode, text: text)
    guard !control || feedback else {
      return StagedInput(
        inputID: request.inputId, sendID: sendID, profile: profile, control: request)
    }
    guard pending.count < 32 else {
      await removeFiles(adopted).value
      snapshot.error = "Resolve pending messages before sending more."
      publish()
      return nil
    }
    pending.append(
      OutboxItem(
        request: request, sendID: sendID, recipients: recipients, queuedAt: stamps.next()))
    do { try saveOutbox() } catch {
      pending.removeLast()
      await removeFiles(adopted).value
      snapshot.error = "The on-device outbox could not be saved. Nothing was sent."
      publish()
      return nil
    }
    unsent[request.inputId] = .staged
    transcript.pending(request, delivery: .sending)
    stampRows()
    return StagedInput(inputID: request.inputId, sendID: sendID, profile: profile, control: nil)
  }

  /// Sends a staged input on this coordinator's own verified socket. While this lane is not
  /// connected, a durable one waits and goes once it connects. One this session is too busy to
  /// send stays queued as unconfirmed, for Check.
  @discardableResult public func start(_ staged: StagedInput) -> StartOutcome {
    guard staged.profile == profile else { return .notSent }
    guard !retired else { return .retired }
    if staged.control == nil {
      guard unsent[staged.inputID] == .staged else { return .started }
      guard snapshot.connection == .connected else {
        unsent[staged.inputID] = .waiting
        return .started
      }
      unsent[staged.inputID] = nil
    }
    guard actions.count < 32, snapshot.connection == .connected else {
      guard staged.control == nil else { return .notSent }
      transcript.delivery(staged.inputID, .uncertain)
      publish()
      return .started
    }
    if let control = staged.control {
      perform(.submit(control), sending: staged)
    } else if let item = pending.first(where: { $0.request.inputId == staged.inputID }) {
      perform(.submit(item.request), inputID: staged.inputID, sending: staged)
    }
    snapshot.error = nil
    publish()
    return .started
  }

  /// Withdraws a staged input that never started: its outbox item, its row, and the stored
  /// files no other item uses.
  public func unstage(_ staged: StagedInput) async {
    guard staged.profile == profile, unsent[staged.inputID] == .staged else { return }
    guard let removal = acknowledge(staged.inputID) else {
      publish()
      return
    }
    unsent[staged.inputID] = nil
    transcript.removeInput(staged.inputID)
    publish()
    await removal.value
  }

  public func retry(_ inputID: String) {
    guard !retired, actions.count < 32, snapshot.connection == .connected,
      let item = pending.first(where: { $0.request.inputId == inputID })
    else { return }
    unsent[inputID] = nil
    transcript.delivery(inputID, .sending)
    perform(.submit(item.request), inputID: inputID)
    publish()
  }
  /// Copies a queued item into a draft. The item stays queued until `discard`, so a draft
  /// lost before it is sent loses nothing.
  public func restore(_ inputID: String, to draftStore: AttachmentStore) async -> RestoredDraft? {
    guard let request = pending.first(where: { $0.request.inputId == inputID })?.request else {
      return nil
    }
    var files: [LocalAttachment] = []
    do {
      for reference in request.attachments ?? [] {
        let original = try await attachments.local(reference)
        // Restoring creates a new draft. Original acknowledgement cleanup
        // must never share a file identity with a later submission.
        files.append(try await draftStore.duplicate(original))
      }
    } catch {
      snapshot.error = error.localizedDescription
      publish()
      return nil
    }
    return RestoredDraft(text: request.text, mode: request.mode, attachments: files)
  }

  /// Removes a restored item once its copy was admitted, with files no other item uses, and
  /// records it withdrawn. That holds only while the coordinator's latest word is a refusal, so an
  /// item written again or accepted since stays queued and reconciles as any other. An address
  /// edit, a reconnect or a cancelled Check / retry in between changes nothing. An attempt that has
  /// not written it is cancelled. A coordinator may still place an input it refused, so the
  /// withdrawn input stays watched, and its record follows what the coordinator reports.
  public func discard(_ inputID: String) {
    guard let item = pending.first(where: { $0.request.inputId == inputID }), item.refused == true
    else { return }
    if acknowledge(inputID) != nil {
      for attempt in unwritten where attempt.inputID == inputID {
        actions[attempt.action]?.cancel()
      }
      transcript.delivery(inputID, .withdrawn)
      ledger.sends[item.sendID] = Ledger.Send(
        inputID: inputID, recipients: item.recipients, queuedAt: item.queuedAt, withdrawn: true)
      saveLedger()
    }
    publish()
  }

  /// Items in the on-device outbox, read from disk so a session that never connected counts too.
  /// A missing outbox holds nothing. An unreadable one throws.
  public func queuedCount() throws -> Int {
    do {
      return try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: outboxURL)).count
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return 0 }
  }
  public func loadEarlier(anchorID: String? = nil) async {
    guard let cursor = snapshot.olderCursor else { return }
    await loadHistory(.earlier(cursor: cursor, anchorID: anchorID ?? transcript.rows.first?.id))
  }

  public func loadLatest() async {
    if let action = historyAction, let task = actions[action.id] {
      task.cancel()
      await actionConnections[action.id]?.close()
      await task.value
    }
    guard !Task.isCancelled else { return }
    await loadHistory(.latest)
  }

  private func loadHistory(_ window: HistoryWindow) async {
    guard actions.count < 32, historyAction == nil, snapshot.connection == .connected
    else { return }
    let id = UUID()
    let generation = generation
    historyAction = HistoryAction(id: id, window: window)
    snapshot.loadingHistory = true
    publish()
    let task = Task<Void, Never> { [weak self] in
      await self?.loadHistory(id: id, window: window, generation: generation)
    }
    actions[id] = task
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
      Task { await self.cancelHistory(id) }
    }
  }

  private func cancelHistory(_ id: UUID) async {
    guard historyAction?.id == id else { return }
    await actionConnections[id]?.close()
  }

  private func loadHistory(id: UUID, window: HistoryWindow, generation: UUID) async {
    defer {
      if historyAction?.id == id {
        historyAction = nil
        snapshot.loadingHistory = false
        publish()
      }
      actions.removeValue(forKey: id)
    }
    switch window {
    case .earlier(let cursor, _):
      await loadEarlier(id: id, cursor: cursor, generation: generation)
    case .latest:
      transcript.beginLatestHistory(id)
      await exchange(
        id: id, request: .history(.init(cursor: nil)), inputID: nil, generation: generation)
    }
  }

  private func loadEarlier(id: UUID, cursor: String, generation: UUID) async {
    let retainedEntries = Set(transcript.rows.compactMap(\.entryID))
    var cursor = cursor
    var requested: Set<String> = []
    var rows = 0
    var bytes = 0
    // A raw page can contain only collapsed activity. Fetch a useful piece of
    // conversation in one owned batch, without sweeping an unbounded history.
    for _ in 0..<8 {
      guard self.generation == generation, !Task.isCancelled,
        snapshot.connection == .connected
      else { return }
      guard requested.insert(cursor).inserted else {
        snapshot.error = "History pagination did not advance. Try loading earlier messages again."
        return
      }
      guard
        let page = await exchange(
          id: id, request: .history(.init(cursor: cursor)), inputID: nil, generation: generation)
      else { return }
      rows += page.rows
      bytes += page.bytes
      guard let next = page.nextCursor else { return }
      guard !requested.contains(next) else {
        snapshot.error = "History pagination did not advance. Try loading earlier messages again."
        return
      }
      let hasDialogue = !page.dialogueEntries.isSubset(of: retainedEntries)
      guard !hasDialogue, rows < Transcript.maximumRows, bytes < Transcript.maximumTextBytes
      else { return }
      cursor = next
    }
  }
  public func interrupt() {
    if actions.count < 32, snapshot.connection == .connected { perform(.interrupt) }
  }

  private func observe(generation: UUID) async {
    var attempt = 0
    while !Task.isCancelled && self.generation == generation {
      var stream: VerifiedConnection?
      do {
        transcript.reconnect()
        snapshot.connection = attempt == 0 ? .connecting : .reconnecting
        publish()
        let opened = try await dialer.open()
        guard self.generation == generation, !Task.isCancelled else {
          await opened.close()
          return
        }
        stream = opened
        connection = opened
        let stream = opened
        var ready = false
        try await timedSend(stream, .observe(.init(inputIds: watched)))
        while !Task.isCancelled {
          let event =
            try await (snapshot.connection == .connected ? stream.next() : timedNext(stream))
          guard self.generation == generation else { return }
          // Before readiness this rejects observation admission. Afterwards the
          // same event can be a mirrored model-turn failure; keep observing.
          if case .failure(let value) = event, !ready {
            throw CoordinatorRejection(message: value.message)
          }
          if case .disconnect = event {
            await disconnect()
            return
          }
          if case .ready = event { ready = true }
          if case .history(let frame) = event, frame.pageComplete, ready {
            attempt = 0
            snapshot.connection = .connected
            snapshot.error = nil
            identityFailure = nil
            for item in pending where unsent[item.request.inputId] == .waiting {
              unsent[item.request.inputId] = nil
              perform(.submit(item.request), inputID: item.request.inputId, sending: staged(item))
            }
          }
          if case .done = event { throw ConnectionError.closed }
          consume(event)
          schedulePublish()
        }
      } catch {
        await stream?.close()
        guard !Task.isCancelled, self.generation == generation else { return }
        connection = nil
        for item in pending where unsent[item.request.inputId] == nil {
          transcript.delivery(item.request.inputId, .uncertain)
        }
        snapshot.busy = false
        guard ConnectionError.shouldReconnect(after: error) else {
          let stoppedGeneration = UUID()
          await disconnect(generation: stoppedGeneration)
          guard self.generation == stoppedGeneration else { return }
          snapshot.error = ConnectionError.describe(error)
          publish()
          return
        }
        snapshot.connection = .reconnecting
        noteIdentityFailure(error)
        snapshot.error = identityFailure
        publish()
        attempt = min(attempt + 1, 5)
        do { try await Task.sleep(for: .seconds(1 << attempt)) } catch { return }
      }
    }
  }
  private func noteIdentityFailure(_ error: any Error) {
    switch error as? ConnectionError {
    case .wrongCoordinator:
      let held =
        pending.count == 1
        ? "1 queued message is" : "\(pending.count) queued messages are"
      identityFailure =
        "This address now answers as a different coordinator. \(held) held on this phone. Remove it and add it again."
    case .unidentifiedCoordinator: identityFailure = ConnectionError.describe(error)
    default: break
    }
  }
  /// Runs `request` on its own socket. `sending` is the started input it writes, if any.
  private func perform(
    _ request: NativeRequest, inputID: String? = nil, sending: StagedInput? = nil
  ) {
    let id = UUID()
    let generation = generation
    if let written = sending?.inputID ?? inputID { unwritten.append((id, written, sending)) }
    actions[id] = Task { [weak self] in
      _ = await self?.exchange(
        id: id, request: request, inputID: inputID, generation: generation)
    }
  }
  private struct HistoryPage {
    var rows = 0
    var bytes = 0
    var dialogueEntries: Set<String> = []
    var nextCursor: String?
    var complete = false

    mutating func include(_ frame: NativeEventHistory) {
      rows += frame.messages.count
      bytes += frame.messages.reduce(0) { $0 + $1.text.utf8.count }
      for message in frame.messages
      where !message.text.isEmpty || message.attachments?.isEmpty == false {
        switch message.role {
        case .user, .assistant, .partialAnswer, .final, .commentary, .notice:
          dialogueEntries.insert(message.entryId)
        case .thinking, .tool: break
        }
      }
      if frame.pageComplete {
        nextCursor = frame.nextCursor
        complete = true
      }
    }
  }

  @discardableResult private func exchange(
    id: UUID, request: NativeRequest, inputID: String?, generation: UUID
  ) async -> HistoryPage? {
    var page = HistoryPage()
    var failed = false
    defer {
      if historyAction?.id != id { actions.removeValue(forKey: id) }
      unwritten.removeAll { $0.action == id }
      transcript.abandonHistory(id)
    }
    do {
      let stream = try await dialer.open()
      guard self.generation == generation, !Task.isCancelled else {
        await stream.close()
        return nil
      }
      actionConnections[id] = stream
      if case .submit(let input) = request {
        for reference in input.attachments ?? [] {
          try Task.checkCancellation()
          let file = try await attachments.local(reference)
          try await upload(file, on: stream)
        }
      }
      try Task.checkCancellation()
      guard self.generation == generation else { throw CancellationError() }
      if let inputID {
        // Cleared before the write, so a refusal never stands once the input may have left.
        mark(inputID, refused: false)
        attemptedInputs.insert(inputID)
      }
      unwritten.removeAll { $0.action == id }
      try await timedSend(stream, request)
      while !Task.isCancelled {
        let event = try await timedNext(stream)
        guard self.generation == generation else { break }
        if case .done = event { break }
        if case .disconnect = event {
          await disconnect()
          return nil
        }
        // The observer alone owns live transcript presentation. Action
        // responses carry acknowledgements, controls and history pages.
        switch event {
        case .history(let frame):
          page.include(frame)
          consume(event, historyRequestID: id)
        case .message, .answer, .textDelta, .activity, .ready, .idle: break
        case .failure:
          failed = true
          consume(event, historyRequestID: id)
          if let inputID, pending.contains(where: { $0.request.inputId == inputID }) {
            transcript.delivery(inputID, .uncertain)
          }
        default: consume(event, historyRequestID: id)
        }
        schedulePublish()
        if case .placed(let placed) = event, placed.inputId == inputID { break }
        if case .rejected(let rejected) = event, rejected.inputId == inputID { break }
        if case .feedbackReady(let ready) = event, ready.inputId == inputID { break }
      }
    } catch {
      failed = true
      if self.generation == generation && !Task.isCancelled {
        if let inputID, pending.contains(where: { $0.request.inputId == inputID }) {
          let mayHaveLeft = attemptedInputs.contains(inputID)
          transcript.delivery(inputID, mayHaveLeft ? .uncertain : .rejected)
          if !mayHaveLeft { mark(inputID, refused: true) }
        }
        if ConnectionError.shouldReconnect(after: error) {
          snapshot.connection = .reconnecting
          noteIdentityFailure(error)
          snapshot.error = identityFailure
          snapshot.busy = false
          // The observer reconciles all pending IDs after a lost action reply.
          // Closing it never resends the action or its uncertain input.
          await connection?.close()
        } else {
          snapshot.error = ConnectionError.describe(error)
        }
      }
    }
    await actionConnections.removeValue(forKey: id)?.close()
    if self.generation == generation { publish() }
    return page.complete && !failed ? page : nil
  }
  private func transfer(_ request: AttachmentRequest, on stream: VerifiedConnection) async throws
    -> AttachmentResponse
  {
    try await timedSend(stream, .attachment(.init(request: request)))
    var response: AttachmentResponse?
    while true {
      let event = try await timedNext(stream)
      switch event {
      case .attachment(let value):
        guard response == nil else { throw AttachmentError.invalidResponse }
        response = value.response
      case .done:
        guard let response else { throw AttachmentError.invalidResponse }
        return response
      case .failure(let value): throw AttachmentError.unavailable(value.message)
      default: throw AttachmentError.invalidResponse
      }
    }
  }
  private func upload(_ file: LocalAttachment, on stream: VerifiedConnection) async throws {
    let input = try FileHandle(forReadingFrom: file.url)
    defer { try? input.close() }
    let reference = file.reference
    var offset = 0
    repeat {
      let bytes = try input.read(upToCount: AttachmentLimits.chunkBytes) ?? Data()
      let end = offset + bytes.count
      guard end <= reference.sizeBytes, !bytes.isEmpty || end == reference.sizeBytes else {
        throw AttachmentError.changed
      }
      let complete = end == reference.sizeBytes
      let response = try await transfer(
        .upload(
          .init(
            complete: complete, dataBase64: bytes.base64EncodedString(), id: reference.id,
            mediaType: reference.mediaType, name: reference.name, offset: offset,
            sizeBytes: reference.sizeBytes)), on: stream)
      guard case .uploaded(let uploaded) = response, uploaded.nextOffset == end,
        complete ? uploaded.attachment == reference : uploaded.attachment == nil
      else { throw AttachmentError.changed }
      offset = end
      if complete {
        guard (try input.read(upToCount: 1) ?? Data()).isEmpty else {
          throw AttachmentError.changed
        }
        return
      }
    } while true
  }

  /// This profile's enrollment channel. Its requests carry this profile's installation ID and
  /// travel only over this session's identity-checked sockets.
  public nonisolated var notificationChannel: NotificationChannel {
    NotificationChannel(installation: profile) { [weak self] request in
      guard let self else { throw ConnectionError.closed }
      return try await self.notifications(request)
    }
  }

  /// Device controls share trusted transport, never model input or transcript rows.
  func notifications(_ request: NotificationRequest) async throws -> NotificationStatus {
    guard actions.count + previewRequests.count < 32, snapshot.connection == .connected
    else { throw ConnectionError.closed }
    let id = UUID()
    previewRequests.insert(id)
    defer { previewRequests.remove(id) }
    let generation = generation
    let stream = try await dialer.open()
    guard self.generation == generation, !Task.isCancelled else {
      await stream.close()
      throw CancellationError()
    }
    actionConnections[id] = stream
    do {
      try await timedSend(stream, .notifications(.init(request: request)))
      let status = try await notificationStatus(on: stream)
      guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
      await actionConnections.removeValue(forKey: id)?.close()
      return status
    } catch {
      await actionConnections.removeValue(forKey: id)?.close()
      throw error
    }
  }

  /// Tool input and output are loaded only when their durable row is opened.
  public func toolDetails(entryID: String, callID: String) async throws -> ToolDetails {
    guard actions.count + previewRequests.count < 32, snapshot.connection == .connected
    else { throw ConnectionError.closed }
    let id = UUID()
    previewRequests.insert(id)
    defer { previewRequests.remove(id) }
    let generation = generation
    let stream = try await dialer.open()
    guard self.generation == generation, !Task.isCancelled else {
      await stream.close()
      throw CancellationError()
    }
    actionConnections[id] = stream
    do {
      try await timedSend(stream, .toolDetails(.init(callId: callID, entryId: entryID)))
      var details: ToolDetails?
      while true {
        let event = try await timedNext(stream)
        guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        switch event {
        case .toolDetails(let value):
          guard details == nil else { throw ConnectionError.incompleteFrame }
          switch value.details {
          case .available(let detail):
            guard detail.callId == callID else { throw ConnectionError.incompleteFrame }
          case .unavailable(let detail):
            guard detail.callId == callID else { throw ConnectionError.incompleteFrame }
          }
          details = value.details
        case .done:
          guard let details else { throw ConnectionError.incompleteFrame }
          await actionConnections.removeValue(forKey: id)?.close()
          return details
        case .failure(let value): throw CoordinatorRejection(message: value.message)
        default: throw ConnectionError.incompleteFrame
        }
      }
    } catch {
      await actionConnections.removeValue(forKey: id)?.close()
      throw error
    }
  }

  /// Fetch only on an explicit preview request; history carries metadata, never image bytes.
  public func preview(_ reference: AttachmentRef) async throws -> URL {
    guard actions.count + previewRequests.count < 32 else {
      throw AttachmentError.unavailable("Wait for the current files to finish opening.")
    }
    let id = UUID()
    previewRequests.insert(id)
    defer { previewRequests.remove(id) }
    if let cached = try await previews.existing(reference) { return cached.url }
    guard snapshot.connection == .connected else { throw ConnectionError.closed }
    let generation = generation
    let stream = try await dialer.open()
    guard self.generation == generation, !Task.isCancelled else {
      await stream.close()
      throw CancellationError()
    }
    actionConnections[id] = stream
    do {
      var data = Data()
      var offset = 0
      repeat {
        let response = try await transfer(
          .download(.init(id: reference.id, limit: AttachmentLimits.chunkBytes, offset: offset)),
          on: stream)
        guard self.generation == generation else { throw CancellationError() }
        guard case .download(let chunk) = response,
          let bytes = Data(base64Encoded: chunk.dataBase64),
          bytes.count <= AttachmentLimits.chunkBytes,
          data.count + bytes.count <= min(reference.sizeBytes, AttachmentLimits.maximumBytes)
        else { throw AttachmentError.invalidResponse }
        data.append(bytes)
        let end = offset + bytes.count
        if let next = chunk.nextOffset {
          guard next == end, next > offset, next < reference.sizeBytes else {
            throw AttachmentError.invalidResponse
          }
          offset = next
        } else {
          break
        }
      } while true
      let staged = try await previews.receive(data, reference: reference)
      await actionConnections.removeValue(forKey: id)?.close()
      return staged.url
    } catch {
      await actionConnections.removeValue(forKey: id)?.close()
      throw error
    }
  }
  private func consume(_ event: NativeEvent, historyRequestID: UUID? = nil) {
    let previousTail = transcript.lastReceivedRowID
    let streaming = transcript.streamingRowID
    switch event {
    case .commands(let value): snapshot.commands = value.commands
    case .ready(let value):
      snapshot.conversationID = value.conversationId
      snapshot.model = value.model
      snapshot.busy = true
    case .history(let value):
      let earlier: Bool
      let anchorID: String?
      if let action = historyAction, action.id == historyRequestID {
        switch action.window {
        case .earlier(_, let anchor):
          earlier = true
          anchorID = anchor
        case .latest:
          earlier = false
          anchorID = nil
        }
      } else {
        earlier = historyRequestID != nil
        anchorID = nil
      }
      transcript.history(
        value, olderPage: earlier, requestID: historyRequestID, preserving: anchorID)
      if value.pageComplete {
        snapshot.olderCursor = value.nextCursor
        if !earlier {
          latestRowID = transcript.lastReceivedRowID
          snapshot.includesLatest = true
        }
      }
    case .message(let value): transcript.message(value.message)
    case .answer(let value): transcript.answer(value)
    case .textDelta(let value):
      snapshot.busy = true
      transcript.response(value.text)
    case .activity(let value):
      snapshot.busy = true
      transcript.activity(value.activity)
    case .accepted(let value):
      mark(value.inputId, refused: false)
      transcript.delivery(value.inputId, .saved)
    case .placed(let value):
      mark(value.inputId, refused: false)
      transcript.delivery(value.inputId, .saved, entryID: value.entryId)
      settle(value.inputId, entryID: value.entryId)
    case .feedbackReady(let value):
      mark(value.inputId, refused: false)
      transcript.delivery(value.inputId, .saved)
      transcript.notice("Feedback saved. Repair task: \(value.receipt.taskId)")
      settle(value.inputId, entryID: nil)
    case .rejected(let value):
      if mark(value.inputId, refused: true) == .withdrawn {
        // The user already sent its copy, so this refusal needs nothing more.
        transcript.delivery(value.inputId, .withdrawn)
      } else {
        transcript.delivery(value.inputId, .rejected)
        // Keep the original on disk until the user explicitly restores it.
        // Rejections are not proof that a queued durable input never existed.
        snapshot.error = value.message
      }
    case .notice(let value): transcript.notice(value.text)
    case .failure(let value):
      snapshot.error = value.message
    case .idle:
      snapshot.busy = false
      transcript.idle()
    // `VerifiedConnection` fails a socket that repeats `identity`, so it never arrives here.
    case .attachment, .toolDetails, .notifications, .disconnect, .done, .identity: break
    }
    switch event {
    case .message, .answer, .textDelta, .activity, .notice, .placed:
      if historyRequestID == nil, transcript.lastReceivedRowID != previousTail {
        latestRowID = transcript.lastReceivedRowID
      }
    default: break
    }
    stampRows(replacing: streaming)
  }

  /// Stamps rows as the events that create them are consumed, never at publication, so the
  /// coalescing delay cannot reorder coordinators. A saved stamp wins, a pending input keeps
  /// its queue time, and a row that changes key keeps its stamp. When an event replaces the
  /// `replacing` streamed row, its first new row inherits that row's stamp.
  private func stampRows(replacing streamed: String? = nil) {
    let rows = transcript.unpreparedRows
    let queued = Dictionary(
      pending.map { ($0.request.inputId, $0.queuedAt) }, uniquingKeysWith: { first, _ in first })
    var inherited = streamed.flatMap { id in rows.contains { $0.id == id } ? nil : rowStamps[id] }
    let known = rows.map { row -> TimeInterval? in
      if let entry = row.entryID, let saved = ledger.entries[entry] { return saved.receivedAt }
      if row.entryID == nil, let input = row.inputID, let queuedAt = queued[input] {
        return queuedAt
      }
      if let stamp = rowStamps[row.id] { return stamp }
      let stamp = inherited
      inherited = nil
      return stamp
    }
    let assigned = Ledger.receiveStamps(
      keys: rows.map { $0.entryID ?? $0.id }, known: known, next: stamps.next)
    var added = false
    for (row, stamp) in zip(rows, assigned) {
      guard let entry = row.entryID, ledger.entries[entry] == nil else { continue }
      ledger.entries[entry] = Ledger.Entry(receivedAt: stamp)
      added = true
    }
    rowStamps = Dictionary(
      zip(rows.map(\.id), assigned), uniquingKeysWith: { first, _ in first })
    // shortcut: rewrites the whole ledger for each event that adds an entry, so debounce the
    // writes that are not placements if profiling shows the I/O.
    if added { saveLedger() }
  }

  /// Records a durable input's send, and its entry's stamp once placed, before the outbox lets
  /// it go. If the record cannot be saved the item stays queued, and the next reconciliation
  /// repeats this. A withdrawn input the coordinator placed anyway becomes a placed send.
  private func settle(_ inputID: String, entryID: String?) {
    if let item = pending.first(where: { $0.request.inputId == inputID }) {
      record(
        inputID, entryID: entryID, sendID: item.sendID, recipients: item.recipients,
        queuedAt: item.queuedAt)
      guard saveLedger() else {
        snapshot.error = "This phone could not record a delivered message. It stays queued."
        return
      }
      acknowledge(inputID)
    } else if let sendID = withdrawal(of: inputID), let send = ledger.sends[sendID] {
      record(
        inputID, entryID: entryID, sendID: sendID, recipients: send.recipients,
        queuedAt: send.queuedAt)
      saveLedger()
    }
  }
  private func record(
    _ inputID: String, entryID: String?, sendID: String, recipients: [ProfileID],
    queuedAt: TimeInterval?
  ) {
    if let entryID, let queuedAt {
      ledger.entries[entryID] = Ledger.Entry(receivedAt: queuedAt, sendID: sendID)
    }
    ledger.sends[sendID] = Ledger.Send(
      inputID: inputID, entryID: entryID, recipients: recipients, queuedAt: queuedAt)
  }
  /// The send ID of the ledger's record of a withdrawn input.
  private func withdrawal(of inputID: String) -> String? {
    ledger.sends.first { $0.value.inputID == inputID && $0.value.withdrawn == true }?.key
  }
  /// Every queued input, then the newest withdrawn ones, which the coordinator may still hold or
  /// place, up to the 32 IDs a coordinator observes.
  private var watched: [String] {
    let queued = pending.map(\.request.inputId)
    let withdrawn = ledger.sends.values.filter { $0.withdrawn == true }
      .sorted { ($0.queuedAt ?? -.infinity) > ($1.queuedAt ?? -.infinity) }
    return queued + withdrawn.prefix(max(0, 32 - queued.count)).map(\.inputID)
  }

  @discardableResult private func saveLedger() -> Bool {
    guard !retired else { return false }
    ledger.prune(keeping: transcript.unpreparedRows)
    do {
      try writePrivately(JSONEncoder().encode(ledger), to: ledgerURL)
      return true
    } catch { return false }
  }
  private func schedulePublish() {
    guard flush == nil else { return }
    flush = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
      await self?.flushUpdate()
    }
  }
  private func flushUpdate() {
    flush = nil
    publish()
  }
  private func publish() {
    let queued = Dictionary(
      pending.map { ($0.request.inputId, $0) }, uniquingKeysWith: { first, _ in first })
    // A settled send outlives its entry's stamp, and feedback settles with no entry at all.
    let sentInputs = Dictionary(
      ledger.sends.map { ($1.inputID, $0) }, uniquingKeysWith: { first, _ in first })
    let sentEntries = Dictionary(
      ledger.sends.compactMap { id, send in send.entryID.map { ($0, id) } },
      uniquingKeysWith: { first, _ in first })
    snapshot.rows = transcript.rows.map { row in
      var row = row
      row.receivedAt = rowStamps[row.id].map(Date.init(timeIntervalSince1970:))
      row.sendID =
        row.inputID.flatMap { queued[$0]?.sendID ?? sentInputs[$0] }
        ?? row.entryID.flatMap { ledger.entries[$0]?.sendID ?? sentEntries[$0] }
      return row
    }
    snapshot.sends = ledger.sends.mapValues { send in
      let progress: SendStatus.Progress =
        send.withdrawn != true ? .placed : send.held == true ? .held : .withdrawn
      return SendStatus(recipients: send.recipients, progress: progress)
    }
    for item in pending where snapshot.sends[item.sendID] == nil {
      let row = snapshot.rows.first { $0.inputID == item.request.inputId }
      snapshot.sends[item.sendID] = SendStatus(
        recipients: item.recipients, progress: .pending(row?.delivery ?? .uncertain))
    }
    // New replies do not fill a gap left by paging. Only a fresh recent page
    // can restore the complete latest window.
    if let latestRowID, !snapshot.rows.contains(where: { $0.id == latestRowID }) {
      snapshot.includesLatest = false
    }
    continuation.yield(snapshot)
  }
  /// Where this phone keeps an input it sent: queued in the outbox, or withdrawn in the ledger.
  private enum Kept { case queued, withdrawn }
  /// Records the coordinator's latest word on whether it refuses an input: on its outbox item while
  /// queued, or on its withdrawn send, which reads Saved while the coordinator holds it. The word
  /// stands in memory when the file cannot be saved, and the next save carries it. Returns where
  /// the input is kept, if anywhere.
  @discardableResult private func mark(_ inputID: String, refused: Bool) -> Kept? {
    if let index = pending.firstIndex(where: { $0.request.inputId == inputID }) {
      if (pending[index].refused == true) != refused {
        pending[index].refused = refused ? true : nil
        try? saveOutbox()
      }
      return .queued
    }
    guard let sendID = withdrawal(of: inputID) else { return nil }
    if (ledger.sends[sendID]?.held == true) == refused {
      ledger.sends[sendID]?.held = refused ? nil : true
      saveLedger()
    }
    return .withdrawn
  }
  /// Removes an item from the outbox. Returns the removal of its files, or nil when the outbox
  /// could not be saved and the item stays.
  @discardableResult private func acknowledge(_ inputID: String) -> Task<Void, Never>? {
    let previous = pending
    let completed = pending.filter { $0.request.inputId == inputID }.flatMap {
      $0.request.attachments ?? []
    }
    pending.removeAll { $0.request.inputId == inputID }
    do { try saveOutbox() } catch {
      pending = previous
      snapshot.error = "The saved outbox could not be updated. Original files were preserved."
      return nil
    }
    attemptedInputs.remove(inputID)
    return removeFiles(completed)
  }
  /// Deletes stored copies that no queued item still uses.
  private func removeFiles(_ references: [AttachmentRef]) -> Task<Void, Never> {
    let retained = Set(pending.flatMap { $0.request.attachments ?? [] }.map(\.id))
    let store = attachments
    return Task {
      for reference in references where !retained.contains(reference.id) {
        if let file = try? await store.local(reference) { try? await store.remove(file) }
      }
    }
  }
  private func saveOutbox() throws {
    guard !retired else { throw CancellationError() }
    try writePrivately(JSONEncoder().encode(pending), to: outboxURL)
  }
}
