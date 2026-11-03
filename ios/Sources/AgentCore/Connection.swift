import Darwin
import Foundation
import Network

public struct CoordinatorAddress: Sendable, Equatable {
  public let host: String
  public let port: UInt16

  // Full MagicDNS names are resolved and pinned to a validated tailnet address per connection.
  public init(host: String, port: UInt16 = 43187) throws {
    let host =
      host.lowercased().hasSuffix(".") ? String(host.dropLast()).lowercased() : host.lowercased()
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    let magicDNS =
      host.hasSuffix(".ts.net") && labels.count >= 4 && host.utf8.count <= 253
      && labels.allSatisfy { label in
        !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
          && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
      }
    guard port > 0, Self.isTailnetIP(host) || magicDNS else { throw ConnectionError.invalidAddress }
    self.host = host
    self.port = port
  }
  static func isTailnetIP(_ host: String) -> Bool {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    let octets = parts.compactMap { UInt8($0) }
    return octets.count == 4 && parts.map(String.init) == octets.map(String.init)
      && octets[0] == 100 && (64...127).contains(octets[1])
  }

  func resolvedHost(using resolve: (String) throws -> [String] = Self.resolve) throws -> String {
    if Self.isTailnetIP(host) { return host }
    let addresses = try resolve(host)
    guard let first = addresses.first, addresses.allSatisfy(Self.isTailnetIP) else {
      throw ConnectionError.invalidAddress
    }
    return first
  }
  private static func resolve(_ host: String) throws -> [String] {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP
    var first: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &first) == 0 else { throw ConnectionError.dnsUnavailable }
    defer { freeaddrinfo(first) }
    var addresses: [String] = []
    var cursor = first
    while let item = cursor {
      defer { cursor = item.pointee.ai_next }
      var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          item.pointee.ai_addr, item.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { throw ConnectionError.dnsUnavailable }
      addresses.append(
        String(
          decoding: name.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }
    return addresses
  }
}

extension CoordinatorAddress: Codable {
  private enum CodingKeys: String, CodingKey { case host, port }
  // A stored address that no longer validates fails to load instead of dialing.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      host: container.decode(String.self, forKey: .host),
      port: container.decode(UInt16.self, forKey: .port))
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(host, forKey: .host)
    try container.encode(port, forKey: .port)
  }
}

public enum ConnectionError: Error, LocalizedError, Sendable {
  case invalidAddress, dnsUnavailable, vpnUnavailable, frameTooLarge, incompleteFrame, closed,
    timedOut
  /// The socket closed or answered something other than `identity`, as a coordinator built
  /// before identities does.
  case unidentifiedCoordinator
  /// The socket named a coordinator other than the profile's pin.
  case wrongCoordinator
  public var errorDescription: String? {
    switch self {
    case .unidentifiedCoordinator: "Update the coordinator to use it with this app."
    case .wrongCoordinator:
      "This address now answers as a different coordinator. Remove it and add it again."
    case .vpnUnavailable:
      "Connect Tailscale first. No active point-to-point interface has a Tailscale IPv4 address."
    case .invalidAddress: "Enter a Tailscale IPv4 address or full MagicDNS name and port."
    case .dnsUnavailable:
      "The coordinator name could not be resolved. Check Tailscale’s DNS settings."
    case .frameTooLarge: "The coordinator sent a frame larger than 4 MiB."
    case .incompleteFrame:
      "The connection ended during a message. Reconnect to recover saved history."
    case .closed: "The coordinator disconnected. Saved work remains on the coordinator."
    case .timedOut: "The coordinator did not respond. Check Tailscale and the coordinator service."
    }
  }
  static func describe(_ error: any Error) -> String {
    if let network = error as? NWError, case .posix(.ECONNRESET) = network {
      return "The coordinator closed the connection. This device may need access."
    }
    return error.localizedDescription
  }
  static func shouldReconnect(after error: any Error) -> Bool {
    if let rejection = error as? CoordinatorRejection {
      switch rejection.code {
      case .coordinatorUnavailable?, .internal?: return true
      // Legacy failures have no safe transient classification. Keep requiring
      // correction rather than guessing from their human-readable message.
      case .invalidRequest?, .authenticationRequired?, .authenticationFailed?,
        .providerUnavailable?, .storageUnavailable?, nil:
        return false
      }
    }
    if let error = error as? ConnectionError {
      switch error {
      case .closed, .timedOut, .incompleteFrame, .dnsUnavailable, .vpnUnavailable,
        .unidentifiedCoordinator, .wrongCoordinator:
        return true
      case .invalidAddress, .frameTooLarge: return false
      }
    }
    if let error = error as? NWError {
      switch error {
      case .posix(.EACCES), .posix(.EPERM), .posix(.EINVAL), .tls: return false
      default: return true
      }
    }
    return false
  }
}

/// How sockets reach an address. Only `CoordinatorDialer` and the pairing probe use one,
/// and both write `identify` before anything else.
public struct CoordinatorTransport: Sendable {
  fileprivate let connect: @Sendable (CoordinatorAddress) async throws -> LineConnection
  init(connect: @escaping @Sendable (CoordinatorAddress) async throws -> LineConnection) {
    self.connect = connect
  }
  public static let tailnet = CoordinatorTransport { try await LineConnection(address: $0) }
}

/// The only way a session gets a socket a request can use. Address and pin are fixed, so no
/// caller can widen what counts as the right coordinator.
struct CoordinatorDialer: Sendable {
  let address: CoordinatorAddress
  let pin: CoordinatorID
  private let transport: CoordinatorTransport

  init(address: CoordinatorAddress, pin: CoordinatorID, transport: CoordinatorTransport) {
    self.address = address
    self.pin = pin
    self.transport = transport
  }

  /// Each call resolves the name again, so each socket proves its coordinator before the
  /// phone writes an input ID, text, attachment byte or installation ID on it.
  func open() async throws -> VerifiedConnection {
    let line = try await transport.connect(address)
    do {
      guard try await identify(line) == pin else { throw ConnectionError.wrongCoordinator }
      return VerifiedConnection(line: line)
    } catch {
      await line.close()
      throw error
    }
  }
}

/// Pairing probe, the only way a pin is learned. Writes only `identify`, then closes. It
/// returns no connection, so nothing can follow the answer.
public func identifyCoordinator(
  at address: CoordinatorAddress, transport: CoordinatorTransport = .tailnet
) async throws -> CoordinatorID {
  let line = try await transport.connect(address)
  do {
    let found = try await identify(line)
    await line.close()
    return found
  } catch {
    await line.close()
    throw error
  }
}

private func identify(_ line: LineConnection) async throws -> CoordinatorID {
  let event: NativeEvent
  do {
    try await timedSend(line, .identify)
    event = try await timedNext(line)
  } catch ConnectionError.closed {
    // A coordinator built before identities drops the socket without a frame.
    throw ConnectionError.unidentifiedCoordinator
  } catch is DecodingError { throw ConnectionError.unidentifiedCoordinator }
  guard case .identity(let identity) = event,
    let found = CoordinatorID(wire: identity.coordinatorId)
  else { throw ConnectionError.unidentifiedCoordinator }
  return found
}

/// A socket whose coordinator equals the dialer's pin. Only `CoordinatorDialer.open()`
/// constructs one, and the session's send paths accept nothing else.
struct VerifiedConnection: Sendable {
  fileprivate let line: LineConnection
  func send(_ request: NativeRequest) async throws { try await line.send(request) }
  func next() async throws -> NativeEvent { try verified(await line.next()) }
  func close() async { await line.close() }
}

/// Writes one frame, closing the connection if it is not written within 15 seconds.
func timedSend(_ connection: VerifiedConnection, _ request: NativeRequest) async throws {
  try await timedSend(connection.line, request)
}

/// Reads one frame, failing after 30 seconds.
func timedNext(_ connection: VerifiedConnection) async throws -> NativeEvent {
  try verified(await timedNext(connection.line))
}

/// `identity` answers only the dialer's `identify`. Anywhere else the peer is not speaking
/// this protocol, so the socket fails closed.
private func verified(_ event: NativeEvent) throws -> NativeEvent {
  if case .identity = event { throw ConnectionError.unidentifiedCoordinator }
  return event
}

private func timedNext(_ connection: LineConnection) async throws -> NativeEvent {
  try await withThrowingTaskGroup(of: NativeEvent.self) { group in
    group.addTask { try await connection.next() }
    group.addTask {
      try await Task.sleep(for: .seconds(30))
      throw ConnectionError.timedOut
    }
    defer { group.cancelAll() }
    guard let event = try await group.next() else { throw ConnectionError.closed }
    return event
  }
}

private func timedSend(_ connection: LineConnection, _ request: NativeRequest) async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    group.addTask { try await connection.send(request) }
    group.addTask {
      try await Task.sleep(for: .seconds(15))
      await connection.close()
      throw ConnectionError.timedOut
    }
    defer { group.cancelAll() }
    try await group.next()
  }
}

/// One owner, one reader. Cancellation closes the underlying socket, not just its waiter.
actor LineConnection {
  private let connection: NWConnection
  private var buffer = Data()
  private var scannedBytes = 0
  private enum ReadState: Equatable {
    case open, eof, closed
    case failed(NWError)
  }
  private var readState = ReadState.open
  private var terminalError: (any Error)? {
    switch readState {
    case .failed(let error): error
    case .closed: ConnectionError.closed
    case .open, .eof: nil
    }
  }
  static let maximumFrameBytes = 4 * 1024 * 1024

  fileprivate init(address: CoordinatorAddress) async throws {
    guard let port = NWEndpoint.Port(rawValue: address.port) else {
      throw ConnectionError.invalidAddress
    }
    let tcp = NWProtocolTCP.Options()
    tcp.connectionTimeout = 15
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 30
    tcp.keepaliveInterval = 10
    tcp.keepaliveCount = 3
    let parameters = NWParameters(tls: nil, tcp: tcp)
    // Binding the tunnel's own address fails closed when the VPN disappears.
    // Merely recognizing 100.64/10 is not enough on a carrier-grade NAT LAN.
    parameters.requiredLocalEndpoint = .hostPort(host: .init(try Self.tunnelAddress()), port: .any)
    let host = try await Task.detached(priority: .userInitiated) { try address.resolvedHost() }
      .value
    try Task.checkCancellation()
    connection = NWConnection(host: .init(host), port: port, using: parameters)
    Self.start(connection, owner: self)
  }

  // Tests exercise the real reader/writer over a local Network.framework listener.
  init(connection: NWConnection) {
    self.connection = connection
    Self.start(connection, owner: self)
  }

  private static func start(_ connection: NWConnection, owner: LineConnection) {
    let observe = connection.stateUpdateHandler
    connection.stateUpdateHandler = { [weak owner] state in
      observe?(state)
      // Network.framework waits for a path change. The session already owns
      // reconnection and backoff, including service restarts on the same path.
      if case .waiting(let error) = state { Task { await owner?.fail(error) } }
    }
    connection.start(queue: .global(qos: .userInitiated))
  }

  private func fail(_ error: NWError) {
    guard readState == .open else { return }
    readState = .failed(error)
    close()
  }

  private static func tunnelAddress() throws -> String {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { throw ConnectionError.vpnUnavailable }
    defer { freeifaddrs(first) }
    var cursor = first
    while let interface = cursor {
      defer { cursor = interface.pointee.ifa_next }
      let flags = interface.pointee.ifa_flags
      guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_POINTOPOINT) != 0,
        let address = interface.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard
        getnameinfo(
          address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
          NI_NUMERICHOST) == 0
      else { continue }
      let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
      let value = String(decoding: bytes, as: UTF8.self)
      if CoordinatorAddress.isTailnetIP(value) { return value }
    }
    throw ConnectionError.vpnUnavailable
  }
  func close() {
    if readState == .open || readState == .eof { readState = .closed }
    buffer.removeAll()
    scannedBytes = 0
    connection.cancel()
  }

  func send(_ request: NativeRequest) async throws {
    if let error = terminalError { throw error }
    guard readState == .open else { throw ConnectionError.closed }
    let command = NativeCommand.native(.init(request: request))
    var bytes = try JSONEncoder().encode(command)
    guard bytes.count <= Self.maximumFrameBytes else { throw ConnectionError.frameTooLarge }
    bytes.append(10)
    let connection = connection
    do {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          connection.send(
            content: bytes,
            completion: .contentProcessed { error in
              if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
      } onCancel: {
        connection.cancel()
      }
    } catch {
      let cause = terminalError ?? error
      close()
      throw cause
    }
  }

  func next() async throws -> NativeEvent {
    let connection = connection
    do {
      return try await withTaskCancellationHandler {
        try await receiveFrame()
      } onCancel: {
        connection.cancel()
      }
    } catch {
      // A rejected or interrupted read must release the peer's pending write,
      // even when the owner has not resumed to observe this error yet.
      let cause = terminalError ?? error
      close()
      throw cause
    }
  }

  private func receiveFrame() async throws -> NativeEvent {
    while true {
      try Task.checkCancellation()
      if let error = terminalError { throw error }
      // Fragmented frames are scanned once, rather than rescanning every byte
      // already received while the peer continues writing.
      let start = buffer.index(buffer.startIndex, offsetBy: scannedBytes)
      if let newline = buffer[start...].firstIndex(of: 10) {
        guard newline - buffer.startIndex <= Self.maximumFrameBytes else {
          throw ConnectionError.frameTooLarge
        }
        let frame = buffer.prefix(upTo: newline)
        let event = try JSONDecoder().decode(NativeEvent.self, from: frame)
        buffer.removeSubrange(...newline)
        scannedBytes = 0
        return event
      }
      scannedBytes = buffer.count
      guard buffer.count <= Self.maximumFrameBytes else { throw ConnectionError.frameTooLarge }
      if readState == .eof {
        throw buffer.isEmpty ? ConnectionError.closed : ConnectionError.incompleteFrame
      }
      let (data, complete) = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<(Data, Bool), any Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
          data, _, complete, error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: (data ?? Data(), complete))
          }
        }
      }
      if let error = terminalError { throw error }
      buffer.append(data)
      if complete { readState = .eof }
    }
  }
}
