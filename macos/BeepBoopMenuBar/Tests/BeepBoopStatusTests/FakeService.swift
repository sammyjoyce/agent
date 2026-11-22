import AgentCore
import BeepBoopStatusCore
import Darwin
import Foundation

/// A Unix socket in its own temporary state directory, so a test never reaches a real service.
struct FakeService {
  let stateDir: URL

  var socketPath: String {
    stateDir.appending(path: ServiceStatusClient.socketFileName).path
  }

  /// Serves one connection. It reads the request before `answer` runs, as the real service does.
  static func start(answer: @escaping @Sendable (Int32) -> Void) throws -> FakeService {
    let service = try FakeService()
    try service.serve(answer: answer)
    return service
  }

  static func start(replying text: String) throws -> FakeService {
    try start { connection in
      let bytes = Array(text.utf8)
      var sent = 0
      while sent < bytes.count {
        let written = bytes[sent...].withUnsafeBytes {
          Darwin.send(connection, $0.baseAddress, $0.count, 0)
        }
        if written <= 0 { return }
        sent += written
      }
    }
  }

  static func start(reporting executablePath: String, version: String) throws -> FakeService {
    let status = NativeEvent.serviceStatus(
      .init(
        coordinatorId: "coord-1",
        executablePath: executablePath,
        pid: 4242,
        stateDir: "/invented/state",
        version: version
      ))
    return try start(replying: try line(status) + line(.done))
  }

  /// A socket file that nothing listens on, as a service leaves behind when it dies.
  static func stale() throws -> FakeService {
    let service = try FakeService()
    Darwin.close(try service.bindSocket())
    return service
  }

  static func withoutSocket() throws -> FakeService {
    try FakeService()
  }

  static func line(_ event: NativeEvent) throws -> String {
    String(decoding: try JSONEncoder().encode(event), as: UTF8.self) + "\n"
  }

  func remove() {
    try? FileManager.default.removeItem(at: stateDir)
  }

  private init() throws {
    // `/tmp` keeps the socket path under the 104 byte limit of `sun_path`.
    stateDir = URL(fileURLWithPath: "/tmp/bb-menu-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
  }

  private func serve(answer: @escaping @Sendable (Int32) -> Void) throws {
    let listener = try bindSocket()
    guard Darwin.listen(listener, 1) == 0 else {
      Darwin.close(listener)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    Thread {
      defer { Darwin.close(listener) }
      let connection = Darwin.accept(listener, nil, nil)
      guard connection >= 0 else { return }
      defer { Darwin.close(connection) }
      // A client that already left must not end the test process with SIGPIPE.
      var enabled: Int32 = 1
      setsockopt(
        connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
      Self.readRequestLine(from: connection)
      answer(connection)
    }.start()
  }

  private func bindSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = socketPath
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
      Darwin.close(descriptor)
      throw POSIXError(.ENAMETOOLONG)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  }

  private static func readRequestLine(from connection: Int32) {
    var chunk = [UInt8](repeating: 0, count: 1024)
    while true {
      let count = Darwin.recv(connection, &chunk, chunk.count, 0)
      if count <= 0 || chunk[0..<count].contains(0x0A) { return }
    }
  }
}
