import AgentCore
import Darwin
import Foundation

public struct RunningServiceInfo: Equatable, Sendable {
  public var coordinatorID: String
  public var pid: UInt32
  public var version: String
  public var executablePath: String?
  public var stateDir: String

  public init(
    coordinatorID: String,
    pid: UInt32,
    version: String,
    executablePath: String?,
    stateDir: String
  ) {
    self.coordinatorID = coordinatorID
    self.pid = pid
    self.version = version
    self.executablePath = executablePath
    self.stateDir = stateDir
  }
}

public struct InstalledBinaryInfo: Equatable, Sendable {
  public var path: String
  public var resolvedPath: String
  public var version: String

  public init(path: String, resolvedPath: String, version: String) {
    self.path = path
    self.resolvedPath = resolvedPath
    self.version = version
  }
}

public enum ServiceRunningState: Equatable, Sendable {
  case running(RunningServiceInfo)
  /// Something accepted the connection and gave no status, so a service process exists.
  case runningWithoutStatus(reason: String)
  case stopped(reason: String)
}

public enum VersionAlignment: Equatable, Sendable {
  case serviceStopped
  case serviceRunningWithoutStatus
  case binaryMissing
  case upToDate(version: String)
  case versionMismatch(installed: String, running: String)
  case binaryReplaced(version: String, installedPath: String, runningPath: String)
}

public struct LocalServiceSnapshot: Equatable, Sendable {
  public var socketPath: String
  public var stateDir: String
  public var running: ServiceRunningState
  public var installed: InstalledBinaryInfo?
  public var alignment: VersionAlignment
  public var checkedAt: Date

  public init(
    socketPath: String,
    stateDir: String,
    running: ServiceRunningState,
    installed: InstalledBinaryInfo?,
    alignment: VersionAlignment,
    checkedAt: Date
  ) {
    self.socketPath = socketPath
    self.stateDir = stateDir
    self.running = running
    self.installed = installed
    self.alignment = alignment
    self.checkedAt = checkedAt
  }
}

public struct ServiceStatusClient: Sendable {
  public static let socketFileName = "agent.sock"
  private static let versionCommandTimeoutSeconds: TimeInterval = 3
  private static let socketTimeoutSeconds = 2

  public var stateDir: URL
  public var explicitBinaryPath: String?

  public init(
    stateDir: URL? = nil,
    explicitBinaryPath: String? = nil
  ) {
    self.stateDir = stateDir ?? Self.defaultStateDirectory()
    self.explicitBinaryPath = explicitBinaryPath
  }

  /// Matches `src/state.rs` default macOS state location (`Application Support/agent`).
  public static func defaultStateDirectory() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appending(
        path: "Library/Application Support", directoryHint: .isDirectory)
    return base.appending(path: "agent", directoryHint: .isDirectory)
  }

  public var socketURL: URL {
    stateDir.appending(path: Self.socketFileName)
  }

  public func refresh(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> LocalServiceSnapshot {
    let installed = inspectInstalledBinary(environment: environment)
    let running = queryRunningService(socketPath: socketURL.path)
    let alignment = Self.compare(running: running, installed: installed)
    return LocalServiceSnapshot(
      socketPath: socketURL.path,
      stateDir: stateDir.path,
      running: running,
      installed: installed,
      alignment: alignment,
      checkedAt: Date()
    )
  }

  /// Runs socket and process inspection off the caller's actor.
  public func refreshAsync(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) async -> LocalServiceSnapshot {
    let client = self
    return await Task.detached(priority: .utility) {
      client.refresh(environment: environment)
    }.value
  }

  public static func compare(
    running: ServiceRunningState,
    installed: InstalledBinaryInfo?
  ) -> VersionAlignment {
    let service: RunningServiceInfo
    switch running {
    case .running(let info):
      service = info
    case .runningWithoutStatus:
      return .serviceRunningWithoutStatus
    case .stopped:
      return .serviceStopped
    }
    guard let installed else {
      return .binaryMissing
    }
    if installed.version != service.version {
      return .versionMismatch(installed: installed.version, running: service.version)
    }
    if let runningPath = service.executablePath,
      !runningPath.isEmpty,
      installed.resolvedPath != runningPath
    {
      return .binaryReplaced(
        version: service.version,
        installedPath: installed.resolvedPath,
        runningPath: runningPath
      )
    }
    return .upToDate(version: service.version)
  }

  public func inspectInstalledBinary(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> InstalledBinaryInfo? {
    guard let path = resolveBinaryPath(environment: environment) else {
      return nil
    }
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    guard let rawOutput = runVersionCommand(binaryPath: path) else {
      return nil
    }
    let parsed = Self.parseVersionOutput(rawOutput)
    guard !parsed.isEmpty else { return nil }
    return InstalledBinaryInfo(path: path, resolvedPath: resolved, version: parsed)
  }

  static func parseVersionOutput(_ output: String) -> String {
    let line =
      output
      .split(whereSeparator: \.isNewline)
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if line.hasPrefix("beep-boop ") {
      return String(line.dropFirst("beep-boop ".count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return line
  }

  private func resolveBinaryPath(environment: [String: String]) -> String? {
    let fm = FileManager.default
    if let explicitBinaryPath, fm.isExecutableFile(atPath: explicitBinaryPath) {
      return explicitBinaryPath
    }
    var searchDirs = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    if let user = environment["USER"], !user.isEmpty {
      searchDirs.append("/etc/profiles/per-user/\(user)/bin")
    }
    searchDirs.append(contentsOf: [
      "/run/current-system/sw/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ])
    for dir in searchDirs where !dir.isEmpty {
      let candidate = URL(fileURLWithPath: dir, isDirectory: true)
        .appending(path: "beep-boop")
        .path
      if fm.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }

  private func runVersionCommand(binaryPath: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = ["--version"]
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    do {
      try process.run()
    } catch {
      return nil
    }
    let waited = exited.wait(timeout: .now() + Self.versionCommandTimeoutSeconds)
    if waited == .timedOut {
      process.terminate()
      _ = exited.wait(timeout: .now() + 0.5)
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  public static func encodeServiceStatusFrame() throws -> Data {
    var payload = try JSONEncoder().encode(NativeCommand.native(.init(request: .serviceStatus)))
    payload.append(0x0A)
    return payload
  }

  public func queryRunningService(socketPath: String) -> ServiceRunningState {
    guard FileManager.default.fileExists(atPath: socketPath) else {
      return .stopped(reason: "Socket not found at \(socketPath)")
    }
    var addr = sockaddr_un()
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8.count < maxLen else {
      return .stopped(reason: "Socket path exceeds Unix sun_path limit")
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
      return .stopped(reason: String(cString: strerror(errno)))
    }
    defer { Darwin.close(fd) }

    var tv = timeval(tv_sec: Self.socketTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    addr.sun_family = sa_family_t(AF_UNIX)
    let copied = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
      raw.initializeMemory(as: UInt8.self, repeating: 0)
      guard let base = raw.baseAddress else { return false }
      let dst = base.assumingMemoryBound(to: CChar.self)
      socketPath.withCString { cstr in
        _ = strncpy(dst, cstr, maxLen - 1)
      }
      return true
    }
    guard copied else {
      return .stopped(reason: "Could not prepare Unix socket address")
    }

    let connectResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connectResult == 0 else {
      return .stopped(reason: "Coordinator offline (\(String(cString: strerror(errno))))")
    }

    let payload: Data
    do {
      payload = try Self.encodeServiceStatusFrame()
    } catch {
      return .runningWithoutStatus(reason: "Could not encode service status query")
    }

    let sent = payload.withUnsafeBytes { raw -> Int in
      guard let base = raw.baseAddress else { return -1 }
      var total = 0
      while total < raw.count {
        let written = Darwin.send(fd, base.advanced(by: total), raw.count - total, 0)
        if written <= 0 { return -1 }
        total += written
      }
      return total
    }
    guard sent == payload.count else {
      return .runningWithoutStatus(reason: "Failed to write status query to service socket")
    }
    Darwin.shutdown(fd, SHUT_WR)

    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 4096)
    var timedOut = false
    while buffer.count < 256 * 1024 {
      let readCount = Darwin.recv(fd, &chunk, chunk.count, 0)
      if readCount <= 0 {
        timedOut = readCount < 0 && errno == EWOULDBLOCK
        break
      }
      buffer.append(contentsOf: chunk[0..<readCount])
      if let text = String(data: buffer, encoding: .utf8), text.contains("\"type\":\"done\"") {
        break
      }
    }
    guard let lines = String(data: buffer, encoding: .utf8)?.split(whereSeparator: \.isNewline)
    else {
      return .runningWithoutStatus(reason: "Invalid UTF-8 response from service")
    }

    var answeredKnownEvent = false
    let decoder = JSONDecoder()
    for line in lines {
      guard let data = line.data(using: .utf8),
        let event = try? decoder.decode(NativeEvent.self, from: data)
      else { continue }
      switch event {
      case .serviceStatus(let status):
        return .running(
          RunningServiceInfo(
            coordinatorID: status.coordinatorId,
            pid: UInt32(clamping: status.pid),
            version: status.version,
            executablePath: status.executablePath,
            stateDir: status.stateDir
          ))
      case .failure(let failure):
        return .runningWithoutStatus(reason: failure.message)
      default:
        answeredKnownEvent = true
      }
    }
    if timedOut {
      return .runningWithoutStatus(
        reason: "Service did not answer within \(Self.socketTimeoutSeconds) seconds")
    }
    if buffer.isEmpty {
      return .runningWithoutStatus(reason: "Service closed the connection without an answer")
    }
    if !answeredKnownEvent {
      return .runningWithoutStatus(reason: "Service answered with text that is not a known event")
    }
    return .runningWithoutStatus(reason: "Service answered without a status")
  }
}
