import AgentCore
import Foundation
import Network
import XCTest

// Shared DEBUG app fixture, real screen/session and an owned NDJSON loopback
// peer. Replies are released by assertions instead of elapsed time.
actor InteractionPeer {
  /// The ID this peer answers `identify` with. The app pins it.
  nonisolated let coordinator: UUID
  init(coordinator: UUID = UUID()) { self.coordinator = coordinator }
  private var listener: NWListener?
  private var sockets: [UUID: NWConnection] = [:]
  private var initial: NativeEventHistory?
  private var pages: [String: NativeEventHistory] = [:]
  private var latest: NativeEventHistory?
  private var observer: NWConnection?
  private var toolReplies: [String: ToolDetails] = [:]
  private var settingsValue: NativeSettingsSnapshot?
  private var settingRequests: [NativeRequestSettings] = []
  private var submitted: [NativeRequestSubmit] = []
  private var observations = 0
  private var working = false
  private var streamsOnSubmit = false
  private var commandValues: [SlashCommand] = []
  private var servedJobs: [ScheduledJobStatus] = []
  private var retried: [String] = []
  private var submitCount = 0
  private var files: [String: Data] = [:]
  private var downloaded: [String] = []
  func observationCount() -> Int { observations }
  func retain(_ data: Data, id: String) { files[id] = data }
  func downloads() -> [String] { downloaded }
  func streamRepliesOnSubmit() { streamsOnSubmit = true }
  func toolDetails(_ values: [String: ToolDetails]) { toolReplies = values }
  func commands(_ values: [SlashCommand]) { commandValues = values }
  func settings(_ value: NativeSettingsSnapshot) { settingsValue = value }
  func settingsControls() -> [NativeRequestSettings] { settingRequests }
  func inputs() -> [NativeRequestSubmit] { submitted }
  private var sourceStates: [SourceState]?
  private var requests: [String] = []
  private var held: Set<String> = []
  private var releases: [String: CheckedContinuation<Void, Never>] = [:]
  private var rejecting = false
  private var announced: [SlashCommand] = []

  func history(
    initial: NativeEventHistory, pages: [String: NativeEventHistory], latest: NativeEventHistory
  ) {
    self.initial = initial
    self.pages = pages
    self.latest = latest
  }
  func cursors() -> [String] { requests }
  func coverage(_ states: [SourceState]) async throws {
    sourceStates = states
    if let observer { try await emit(.sources(.init(sources: states)), to: observer) }
  }
  func submits() -> [String] { submitted.map(\.text) }
  func retries() -> Int { retried.count }
  /// The job of each `retry_job` this peer received, in order.
  func retriedJobs() -> [String] { retried }
  /// Advertises work inspection, and answers `jobs` and `retry_job` from these.
  func serve(jobs: [ScheduledJobStatus]) { servedJobs = jobs }
  func submitAttempts() -> Int { submitCount }
  /// Rejects each submit while set, as a coordinator that cannot take a message does.
  func rejectSubmits(_ value: Bool) { rejecting = value }
  /// The commands each observation announces, as a coordinator's `commands` frame does.
  func announce(_ commands: [SlashCommand]) { announced = commands }
  /// Closes the app's observation, as a dropped network does.
  func dropObserver() { observer?.cancel() }
  func placeLastSubmit() async throws {
    let input = try XCTUnwrap(submitted.last)
    try await emit(
      .placed(.init(entryId: "placed-\(input.inputId)", inputId: input.inputId)),
      to: XCTUnwrap(observer))
  }
  func beginReply(_ text: String) async throws {
    working = true
    try await emit(.textDelta(.init(text: text)), to: XCTUnwrap(observer))
  }
  func reply(_ text: String, id: String = "concurrent-reply") async throws {
    let message = HistoryMessage(
      continuation: false, entryId: id, finalChunk: true, role: .final, text: text)
    latest?.messages.append(message)
    try await emit(.answer(.init(entryId: id, text: text)), to: XCTUnwrap(observer))
    working = false
    try await emit(.idle, to: XCTUnwrap(observer))
  }
  func hold(_ cursor: String) { held.insert(cursor) }
  func release(_ cursor: String) {
    held.remove(cursor)
    releases.removeValue(forKey: cursor)?.resume()
  }
  func start() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    let ready = AsyncThrowingStream<Void, any Error>.makeStream()
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.continuation.yield(()) }
      if case .failed(let error) = state { ready.continuation.finish(throwing: error) }
    }
    listener.newConnectionHandler = { socket in Task { await self.accept(socket) } }
    listener.start(queue: .global())
    for try await _ in ready.stream { break }
    return try XCTUnwrap(listener.port).rawValue
  }
  func stop() {
    for continuation in releases.values { continuation.resume() }
    releases = [:]
    listener?.cancel()
    listener = nil
    for socket in sockets.values { socket.cancel() }
    sockets = [:]
  }
  private func accept(_ socket: NWConnection) async {
    let id = UUID()
    sockets[id] = socket
    socket.start(queue: .global())
    defer {
      sockets.removeValue(forKey: id)
      socket.cancel()
    }
    do {
      var data = Data()
      var request = try await read(socket, &data)
      if case .identify = request {
        try await emit(
          .identity(.init(coordinatorId: coordinator.uuidString.lowercased())), to: socket)
        request = try await read(socket, &data)
      }
      switch request {
      case .observe(let observe):
        observations += 1
        observer = socket
        if !announced.isEmpty {
          try await emit(.commands(.init(commands: announced)), to: socket)
        }
        try await emit(
          .ready(
            .init(
              conversationId: "fixture-root",
              conversationSettings: settingsValue == nil ? nil : true,
              inputOrigins: settingsValue == nil ? nil : true, model: "fixture/model",
              workInspection: servedJobs.isEmpty ? nil : true, working: working)), to: socket)
        try await emitHistory(try XCTUnwrap(initial), to: socket)
        if !commandValues.isEmpty {
          try await emit(.commands(.init(commands: commandValues)), to: socket)
        }
        if observe.sourceStatus == true, let sourceStates {
          try await emit(.sources(.init(sources: sourceStates)), to: socket)
        }
        if !working { try await emit(.idle, to: socket) }
      case .toolDetails(let request):
        let details = toolReplies[request.callId] ?? .unavailable(.init(callId: request.callId))
        try await emit(.toolDetails(.init(details: details)), to: socket)
        try await emit(.done, to: socket)
      case .settings(let request):
        settingRequests.append(request)
        var settings = try XCTUnwrap(settingsValue)
        switch request.change {
        case .setReasoning(let value): settings.configured.model.reasoning = value.reasoning
        case .setFast(let value): settings.configured.model.fast = value.mode == .on
        case .none: break
        default: XCTFail("Unexpected settings control")
        }
        settingsValue = settings
        try await emit(
          .notice(.init(settings: settings, text: "Conversation settings")), to: socket)
        try await emit(.done, to: socket)
      case .history(let request):
        let cursor = request.cursor ?? "<latest>"
        requests.append(cursor)
        if held.contains(cursor) { await withCheckedContinuation { releases[cursor] = $0 } }
        try await emitHistory(
          try XCTUnwrap(request.cursor == nil ? latest : pages[cursor]), to: socket)
        try await emit(.done, to: socket)
      case .attachment(let value):
        guard case .download(let chunk) = value.request, let file = files[chunk.id] else {
          try await emit(.failure(.init(message: "Invented: no such attachment")), to: socket)
          try await emit(.done, to: socket)
          break
        }
        downloaded.append(chunk.id)
        let end = min(chunk.offset + chunk.limit, file.count)
        try await emit(
          .attachment(
            .init(
              response: .download(
                .init(
                  dataBase64: file.subdata(in: chunk.offset..<end).base64EncodedString(),
                  nextOffset: end < file.count ? end : nil)))), to: socket)
        try await emit(.done, to: socket)
      case .jobs(let request) where !servedJobs.isEmpty:
        try await emit(jobStatus(request.jobId), to: socket)
        try await emit(.done, to: socket)
      case .retryJob(let request):
        retried.append(request.jobId)
        if !servedJobs.isEmpty { try await emit(jobStatus(request.jobId), to: socket) }
        try await emit(.done, to: socket)
      case .submit(let request):
        submitCount += 1
        if rejecting {
          try await emit(
            .rejected(
              .init(inputId: request.inputId, message: "Invented: the coordinator is busy")),
            to: socket)
        } else {
          submitted.append(request)
          if streamsOnSubmit { try await beginReply("A reply starts before acknowledgement. ") }
          try await emit(.accepted(.init(inputId: request.inputId)), to: socket)
          if streamsOnSubmit { try await beginReply("More text streams after acknowledgement. ") }
        }
        try await emit(.done, to: socket)
      default: try await emit(.done, to: socket)
      }
      _ = try await receive(socket)
    } catch {
      // Client cancellation owns closing both observers and history requests.
    }
  }
  private func jobStatus(_ id: String?) -> NativeEvent {
    guard let id else {
      return .notice(.init(jobStatus: .list(.init(jobs: servedJobs)), text: "Scheduled jobs"))
    }
    guard let job = servedJobs.first(where: { $0.job.id == id }) else {
      return .failure(.init(message: "Invented: no scheduled job \(id)"))
    }
    return .notice(.init(jobStatus: .detail(.init(job: job)), text: job.job.title))
  }
  private func read(_ socket: NWConnection, _ data: inout Data) async throws -> NativeRequest {
    while !data.contains(10) { data.append(try await receive(socket)) }
    let end = try XCTUnwrap(data.firstIndex(of: 10))
    let command = try JSONDecoder().decode(NativeCommand.self, from: data.prefix(upTo: end))
    data.removeSubrange(...end)
    guard case .native(let value) = command else { throw CocoaError(.fileReadUnknown) }
    return value.request
  }
  private func receive(_ socket: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if complete && (data?.isEmpty ?? true) {
          continuation.resume(throwing: CocoaError(.fileReadUnknown))
        } else {
          continuation.resume(returning: data ?? Data())
        }
      }
    }
  }
  private func emitHistory(_ page: NativeEventHistory, to socket: NWConnection) async throws {
    var batch: [HistoryMessage] = []
    var characters = 0
    for message in page.messages {
      if characters + message.text.utf16.count > 65536 {
        try await emit(
          .history(.init(messages: batch, nextCursor: nil, pageComplete: false)), to: socket)
        batch = []
        characters = 0
      }
      batch.append(message)
      characters += message.text.utf16.count
    }
    try await emit(
      .history(.init(messages: batch, nextCursor: page.nextCursor, pageComplete: true)), to: socket)
  }

  private func emit(_ event: NativeEvent, to socket: NWConnection) async throws {
    var data = try JSONEncoder().encode(event)
    data.append(10)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      socket.send(
        content: data,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }
}
