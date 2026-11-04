import CryptoKit
import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

func send(_ data: Data, on connection: NWConnection) async throws {
  try await withCheckedThrowingContinuation {
    (continuation: CheckedContinuation<Void, any Error>) in
    connection.send(
      content: data,
      completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      })
  }
}

actor FixtureCoordinator {
  /// What this fixture answers `identify` with. Sessions pass it as their pin.
  nonisolated let id = CoordinatorID(UUID())
  nonisolated let closedObservations: AsyncStream<Void>
  nonisolated let closedToolLookups: AsyncStream<Void>
  private let closedContinuation: AsyncStream<Void>.Continuation
  private let closedToolContinuation: AsyncStream<Void>.Continuation
  private var toolRequests: [NativeRequestToolDetails] = []
  private var toolReply: [NativeEvent] = []
  private var conversationSettings: Bool?
  private var settingsReply: [NativeEvent] = []
  private var settingsRequests: [NativeRequestSettings] = []
  private let settingsObserved = AsyncStream<Void>.makeStream()
  nonisolated var observedSettings: AsyncStream<Void> { settingsObserved.stream }
  private let settingsClosed = AsyncStream<Void>.makeStream()
  nonisolated var closedSettings: AsyncStream<Void> { settingsClosed.stream }
  private let inputsObserved = AsyncStream<NativeRequestSubmit>.makeStream()
  nonisolated var observedInputs: AsyncStream<NativeRequestSubmit> { inputsObserved.stream }
  func advertiseSettings(_ value: Bool?) { conversationSettings = value }
  func replyToSettings(_ value: NativeSettingsSnapshot) {
    settingsReply = [.notice(.init(settings: value, text: "Conversation settings")), .done]
  }
  func rejectSettings(_ message: String) {
    settingsReply = [.failure(.init(message: message)), .done]
  }
  func settingsControls() -> [NativeRequestSettings] { settingsRequests }
  private var inputOrigins: Bool?
  func advertiseInputOrigins(_ value: Bool?) { inputOrigins = value }
  private var notificationRequests: [NotificationRequest] = []
  /// Each installation this coordinator holds a registration for, with its device token.
  private var registrations: [String: String] = [:]
  private var notificationsHeld = false
  private var dropNotificationRemoval = false
  private var notificationRelease: CheckedContinuation<Void, Never>?
  private let notificationObserved = AsyncStream<Void>.makeStream()
  nonisolated var observedNotifications: AsyncStream<Void> { notificationObserved.stream }
  private var delaySnapshot = false
  private var dropInputAcknowledgements = false
  private var release: CheckedContinuation<Void, Never>?
  private var initialHistory: NativeEventHistory?
  private var latestHistory: NativeEventHistory?
  private var observer: NWConnection?
  private var historyPages: [String: NativeEventHistory] = [:]
  private var requestedHistory: [String] = []
  private var heldHistory: String?
  private var historyRelease: CheckedContinuation<Void, Never>?
  private let historyObserved = AsyncStream<String>.makeStream()
  nonisolated var observedHistory: AsyncStream<String> { historyObserved.stream }
  init() {
    let pair = AsyncStream<Void>.makeStream()
    closedObservations = pair.stream
    closedContinuation = pair.continuation
    let details = AsyncStream<Void>.makeStream()
    closedToolLookups = details.stream
    closedToolContinuation = details.continuation
  }
  func replyToToolLookups(with events: [NativeEvent]) { toolReply = events }
  func loseInputAcknowledgements() { dropInputAcknowledgements = true }
  func replyToHistory(initial: NativeEventHistory, pages: [String: NativeEventHistory]) {
    initialHistory = initial
    historyPages = pages
  }
  func historyRequests() -> [String] { requestedHistory }
  func replyToLatest(_ page: NativeEventHistory) { latestHistory = page }
  func liveMessage(_ message: HistoryMessage) async throws {
    try await emit(.message(.init(message: message)), on: #require(observer))
  }
  func holdHistory(_ cursor: String) { heldHistory = cursor }
  func releaseHistory() {
    heldHistory = nil
    historyRelease?.resume()
    historyRelease = nil
  }
  func toolLookups() -> [NativeRequestToolDetails] { toolRequests }
  func notificationControls() -> [NotificationRequest] { notificationRequests }
  /// Whether this coordinator holds any device registration, as its applied controls left it.
  func holdsRegistration() -> Bool { !registrations.isEmpty }
  /// Whether this coordinator holds a registration for `installation`.
  func holds(_ installation: String) -> Bool { registrations[installation.lowercased()] != nil }
  /// Registers `installation` as a client that never identifies does, such as the single-address
  /// build.
  func register(_ installation: String, token: String) { enroll(installation, token: token) }
  /// A token names one app on one device, so it moves to the installation that registered it
  /// last, as `runtime/src/notifications.ts` does.
  private func enroll(_ installation: String, token: String) {
    registrations = registrations.filter { $0.value != token.lowercased() }
    registrations[installation.lowercased()] = token.lowercased()
  }
  func dropNextNotificationRemoval() { dropNotificationRemoval = true }
  func holdNotificationRegistration() { notificationsHeld = true }
  func releaseNotificationRegistration() {
    notificationsHeld = false
    notificationRelease?.resume()
    notificationRelease = nil
  }
  func holdSnapshot() { delaySnapshot = true }
  func releaseSnapshot() {
    delaySnapshot = false
    release?.resume()
    release = nil
  }
  private var sockets: [NWConnection] = []
  private var requests: [NativeRequest] = []
  private var dropsIdentify = false
  private var holdsIdentity = false
  /// Set once an `identify` arrived and its answer was held.
  private(set) var identityHeld = false
  private var identityRelease: CheckedContinuation<Void, Never>?
  /// Holds the answer to the next `identify` until `releaseIdentity`, as a slow proof would.
  func holdNextIdentity() { holdsIdentity = true }
  func releaseIdentity() {
    holdsIdentity = false
    identityRelease?.resume()
    identityRelease = nil
  }
  /// Every request any socket carried, in arrival order.
  func received() -> [NativeRequest] { requests }
  /// Behaves like a coordinator built before identities. It closes on `identify` without a frame.
  func dropIdentify(_ drops: Bool = true) { dropsIdentify = drops }
  func emitOnObserver(_ event: NativeEvent) async throws {
    try await emit(event, on: #require(observer))
  }
  private var submissions: [NativeRequestSubmit] = []
  private var files: [String: Data] = [:]
  private var uploads = 0
  private var rejectUploads = false
  func refuseUploads() { rejectUploads = true }
  func acceptUploads() { rejectUploads = false }
  private var rejectsSubmits = false
  /// Rejects each submit once read, as a coordinator refusing an input does, and keeps nothing.
  func rejectSubmits(_ rejects: Bool = true) { rejectsSubmits = rejects }
  private var holdsSubmitReply = false
  private var submitReplyRelease: CheckedContinuation<Void, Never>?
  /// Keeps the next submit and holds its answer until `releaseSubmitReply`, as a slow coordinator
  /// does after the write.
  func holdNextSubmitReply() { holdsSubmitReply = true }
  func releaseSubmitReply() {
    holdsSubmitReply = false
    submitReplyRelease?.resume()
    submitReplyRelease = nil
  }
  func uploadCount() -> Int { uploads }
  func uploaded(_ id: String) -> Data? { files[id] }
  func count() -> Int { submissions.count }
  private var busy = false
  /// Submits the busy turn has not placed, each with the socket still waiting for it.
  private var unplaced: [(input: String, socket: NWConnection?)] = []
  private var keepsNextRejected = false
  /// From now on accepts each submit at once and places it only at `finishTurn`, as a coordinator
  /// busy with a turn does with a follow-up.
  func holdPlacements() { busy = true }
  /// Rejects the next submit but keeps it, as a coordinator whose turn ended while saving it does.
  /// Observing reports it as the turn left it.
  func rejectNextSubmitButKeepIt() { keepsNextRejected = true }
  /// The turn ends, and every submit it held is placed in order. Each placement goes to the socket
  /// that sent the submit while the phone keeps it open. A kept input's socket closed with its
  /// rejection, so its placement goes to the observer, as a coordinator tells every observer.
  func finishTurn() async throws {
    busy = false
    for (input, socket) in unplaced {
      let placed = NativeEvent.placed(.init(entryId: "placed-\(input)", inputId: input))
      if let socket {
        try? await emit(placed, on: socket)
        try? await emit(.done, on: socket)
      } else if let observer {
        try? await emit(placed, on: observer)
      }
    }
    unplaced = []
  }
  /// The input IDs of every submit placed so far.
  func placedInputs() -> [String] { placedSubmits.map(\.inputId) }
  private var placedSubmits: [NativeRequestSubmit] {
    submissions.filter { submit in !unplaced.contains { $0.input == submit.inputId } }
  }
  func stop() {
    releaseHistory()
    releaseIdentity()
    releaseSubmitReply()
    for socket in sockets { socket.cancel() }
    sockets = []
  }
  func accept(_ socket: NWConnection) async throws {
    sockets.append(socket)
    socket.start(queue: .global())
    var bytes = Data()
    while true {
      while !bytes.contains(10) {
        let data = try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Data, any Error>) in
          socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            data, _, complete, error in
            if let error {
              continuation.resume(throwing: error)
            } else if complete && data == nil {
              continuation.resume(throwing: ConnectionError.closed)
            } else {
              continuation.resume(returning: data ?? Data())
            }
          }
        }
        bytes.append(data)
      }
      let end = try #require(bytes.firstIndex(of: 10))
      let command = try JSONDecoder().decode(NativeCommand.self, from: bytes.prefix(upTo: end))
      bytes.removeSubrange(...end)
      guard case .native(let value) = command else { return }
      requests.append(value.request)
      switch value.request {
      case .identify:
        if holdsIdentity {
          holdsIdentity = false
          identityHeld = true
          await withCheckedContinuation { identityRelease = $0 }
        }
        if dropsIdentify {
          socket.cancel()
          return
        }
        try await emit(.identity(.init(coordinatorId: "\(id.uuid)".lowercased())), on: socket)
      case .settings(let request):
        settingsRequests.append(request)
        settingsObserved.continuation.yield(())
        for event in settingsReply { try await emit(event, on: socket) }
        if settingsReply.isEmpty {
          await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
              #expect(complete || error != nil)
              continuation.resume()
            }
          }
          settingsClosed.continuation.yield(())
        }
        return
      case .notifications(let request):
        notificationRequests.append(request.request)
        notificationObserved.continuation.yield(())
        if case .unregister = request.request, dropNotificationRemoval {
          dropNotificationRemoval = false
          socket.cancel()
          return
        }
        let installation: String
        switch request.request {
        case .register(let value):
          if notificationsHeld { await withCheckedContinuation { notificationRelease = $0 } }
          enroll(value.installationId, token: value.token)
          installation = value.installationId
        case .unregister(let value):
          registrations[value.installationId.lowercased()] = nil
          installation = value.installationId
        case .status(let value): installation = value.installationId
        }
        try await emit(
          .notifications(
            .init(status: .init(configured: true, registered: holds(installation)))), on: socket)
        try await emit(.done, on: socket)
      case .toolDetails(let request):
        toolRequests.append(request)
        var reply = Data()
        for event in toolReply {
          reply.append(try JSONEncoder().encode(event))
          reply.append(10)
        }
        if !reply.isEmpty { try? await send(reply, on: socket) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          socket.receive(minimumIncompleteLength: 1, maximumLength: 1) {
            data, _, complete, error in
            #expect(data?.isEmpty ?? true)
            #expect(complete || error != nil)
            continuation.resume()
          }
        }
        closedToolContinuation.yield(())
        return
      case .observe(let request):
        observer = socket
        try await emit(
          .ready(
            .init(
              conversationId: "fixture-root", conversationSettings: conversationSettings,
              inputOrigins: inputOrigins, model: "fixture/model")), on: socket)
        if delaySnapshot { await withCheckedContinuation { release = $0 } }
        let placed = placedSubmits
        let messages = placed.filter { request.inputIds.contains($0.inputId) }.map { input in
          HistoryMessage(
            attachments: input.attachments, continuation: false, entryId: "placed-\(input.inputId)",
            finalChunk: true, role: .user,
            text: input.text, tool: nil)
        }
        for input in submissions where request.inputIds.contains(input.inputId) {
          try await emit(
            placed.contains(input)
              ? .placed(.init(entryId: "placed-\(input.inputId)", inputId: input.inputId))
              : .accepted(.init(inputId: input.inputId)), on: socket)
        }
        try await emit(
          .history(
            initialHistory ?? .init(messages: messages, nextCursor: nil, pageComplete: true)),
          on: socket)
        try await emit(.idle, on: socket)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          socket.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
            continuation.resume()
          }
        }
        if observer === socket { observer = nil }
        closedContinuation.yield(())
        return
      case .submit(let request):
        if rejectsSubmits {
          try await emit(
            .rejected(
              .init(
                inputId: request.inputId, message: "Invented: the coordinator refused this input")
            ), on: socket)
          try await emit(.done, on: socket)
          return
        }
        submissions.append(request)
        inputsObserved.continuation.yield(request)
        if holdsSubmitReply {
          holdsSubmitReply = false
          await withCheckedContinuation { submitReplyRelease = $0 }
        }
        if keepsNextRejected {
          keepsNextRejected = false
          if busy { unplaced.append((request.inputId, nil)) }
          try await emit(
            .rejected(
              .init(
                inputId: request.inputId,
                message: "The turn ended while this input was being saved; its original is retained"
              )), on: socket)
          try await emit(.done, on: socket)
          return
        }
        if request.text.hasPrefix("/feedback ") {
          try await emit(
            .feedbackReady(
              .init(
                inputId: request.inputId,
                receipt: .init(
                  id: "feedback-fixture", path: "private/feedback", taskId: "repair-fixture"))),
            on: socket)
          // The client may close as soon as the durable receipt arrives.
          try? await emit(.done, on: socket)
          return
        }
        if !dropInputAcknowledgements {
          try await emit(.accepted(.init(inputId: request.inputId)), on: socket)
        }
        if busy {
          unplaced.append((request.inputId, socket))
          return
        }
        socket.send(
          content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        return
      case .history(let request):
        let cursor = request.cursor ?? "<latest>"
        requestedHistory.append(cursor)
        historyObserved.continuation.yield(cursor)
        if heldHistory == cursor { await withCheckedContinuation { historyRelease = $0 } }
        let page = try #require(
          request.cursor == nil ? latestHistory ?? initialHistory : historyPages[cursor])
        try await emit(.history(page), on: socket)
        try await emit(.done, on: socket)
      case .attachment(let value):
        let response: AttachmentResponse
        switch value.request {
        case .upload(let chunk):
          if rejectUploads {
            try await emit(.failure(.init(message: "Attachment storage is full")), on: socket)
            return
          }
          uploads += 1
          let data = try #require(Data(base64Encoded: chunk.dataBase64))
          var file = files[chunk.id] ?? Data()
          #expect(chunk.offset <= file.count)
          let end = chunk.offset + data.count
          if end > file.count { file.append(data.suffix(end - file.count)) }
          files[chunk.id] = file
          let reference =
            chunk.complete
            ? AttachmentRef(
              id: chunk.id, mediaType: chunk.mediaType, name: chunk.name,
              sha256: SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined(),
              sizeBytes: file.count) : nil
          response = .uploaded(.init(attachment: reference, nextOffset: end))
        case .download(let chunk):
          let file = try #require(files[chunk.id])
          let end = min(chunk.offset + chunk.limit, file.count)
          response = .download(
            .init(
              dataBase64: file.subdata(in: chunk.offset..<end).base64EncodedString(),
              nextOffset: end < file.count ? end : nil))
        case .discard: response = .discarded
        }
        try await emit(.attachment(.init(response: response)), on: socket)
        try await emit(.done, on: socket)
      default:
        try await emit(.done, on: socket)
        return
      }
    }
  }
  private func emit(_ event: NativeEvent, on socket: NWConnection) async throws {
    var data = try JSONEncoder().encode(event)
    data.append(10)
    try await send(data, on: socket)
  }
}

/// Serves `fixture` on a loopback port until the listener is cancelled.
func listen(_ fixture: FixtureCoordinator) async throws -> (NWListener, NWEndpoint.Port) {
  let parameters = NWParameters.tcp
  parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
  let listener = try NWListener(using: parameters)
  let ready = AsyncThrowingStream<Void, any Error>.makeStream()
  listener.stateUpdateHandler = { state in
    if case .ready = state { ready.continuation.yield(()) }
    if case .failed(let error) = state { ready.continuation.finish(throwing: error) }
  }
  listener.newConnectionHandler = { socket in
    Task {
      do { try await fixture.accept(socket) } catch ConnectionError.closed {
        // A completed transfer releases its owned socket.
      } catch let error as NWError where error == .posix(.ECANCELED) {
        // Fixture teardown cancels receives on its remaining connections.
      } catch let error as NWError
        where error == .posix(.EPIPE) || error == .posix(.ECONNRESET)
        || error == .posix(.ENOTCONN)
      {
        // A cancelled history batch closes its socket before the held reply.
      } catch { Issue.record(error) }
    }
  }
  listener.start(queue: .global())
  for try await _ in ready.stream { break }
  return (listener, try #require(listener.port))
}

func loopback(_ port: NWEndpoint.Port) -> CoordinatorTransport {
  CoordinatorTransport { _ in
    LineConnection(connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
  }
}

/// The requests in a profile's live outbox, in queue order.
func queuedRequests(_ outbox: URL) throws -> [NativeRequestSubmit] {
  try JSONDecoder().decode([OutboxItem].self, from: Data(contentsOf: outbox)).map(\.request)
}

/// Saves `requests` in the profile's outbox, each a Send to it alone from an earlier launch.
func saveOutbox(_ requests: [NativeRequestSubmit], in directory: ProfileDirectory) throws {
  let items = requests.map {
    OutboxItem(
      request: $0, sendID: UUID().uuidString, recipients: [directory.profile],
      queuedAt: Date().timeIntervalSince1970)
  }
  try writePrivately(JSONEncoder().encode(items), to: directory.outbox)
}

/// Makes the profile's directory read-only, so the next stage cannot save, until `body` ends.
@MainActor func withReadOnlyProfile(
  _ directory: ProfileDirectory, _ body: () async throws -> Void
) async throws {
  try FileManager.default.createDirectory(at: directory.root, withIntermediateDirectories: true)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o500], ofItemAtPath: directory.root.path)
  defer {
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory.root.path)
  }
  try await body()
}

/// A profile directory under a fresh temporary root, removed by the caller.
func temporaryProfile() -> (ProfileDirectory, URL) {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  return (ProfileDirectory(ProfileID(), applicationSupport: root, caches: root), root)
}

/// The feed lane of `session`.
func lane(_ session: CoordinatorSession) -> Lane { Lane(id: session.profile, session: session) }

/// A queue the single-address build left with `messages`, queued for `address`, in its own folder
/// under `root`, and its store, for the feed to hold.
func heldQueue(
  _ messages: [NativeRequestSubmit], in root: URL, address: CoordinatorAddress? = nil,
  coordinator: CoordinatorID? = nil
) throws -> Hold {
  let queue = HeldQueue(address: address, coordinator: coordinator, installation: nil)
  let folder = queue.folder(applicationSupport: root)
  try writePrivately(JSONEncoder().encode(messages), to: folder.appending(path: "pending.json"))
  return Hold(queue: queue, store: LegacyHold(folder))
}

func withCoordinator(
  _ body: @Sendable (CoordinatorSession, FixtureCoordinator, URL) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let (directory, root) = temporaryProfile()
  defer { try? FileManager.default.removeItem(at: root) }
  let session = CoordinatorSession(
    directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"), pin: fixture.id,
    stamps: StampSource(), transport: loopback(port))
  do {
    try await body(session, fixture, directory.outbox)
    await session.disconnect()
    await fixture.stop()
  } catch {
    await session.disconnect()
    await fixture.stop()
    throw error
  }
}

/// Saves one coordinator for `model` on a loopback fixture and connects it as the app does, so a
/// Send reaches it. The lane is detached after `body`.
@MainActor func withConnectedCoordinator(
  _ model: ChatModel, _ body: (FixtureCoordinator, ProfileDirectory) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let profile = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
  model.profiles = [profile]
  model.attach(
    Lane(
      id: profile.id,
      session: CoordinatorSession(
        directory: directory, address: profile.address, pin: fixture.id, stamps: StampSource(),
        transport: loopback(port))))
  await model.setActive(true)
  while model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
  do {
    try await body(fixture, directory)
  } catch {
    await model.detach(profile.id)
    await fixture.stop()
    throw error
  }
  await model.detach(profile.id)
  await fixture.stop()
}
