import AgentCore
import BeepBoopStatusCore
import Darwin
import Foundation
import Testing

@Test func encodesInternallyTaggedRuntimeCommandFrame() throws {
  let frame = try ServiceStatusClient.encodeServiceStatusFrame()
  #expect(frame.last == 0x0A)
  let object = try #require(
    try JSONSerialization.jsonObject(with: Data(frame.dropLast())) as? [String: Any])
  #expect(object["type"] as? String == "native")
  let request = try #require(object["request"] as? [String: Any])
  #expect(request["type"] as? String == "service_status")
}

@Test func detectsRunningServiceInstalledVersionAndPathMismatch() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "bb-menu-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let binary = root.appending(path: "beep-boop")
  let script = "#!/bin/sh\necho 'beep-boop 0.2.0'\n"
  try script.write(to: binary, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

  // Real Unix socket listener in short /tmp path (<104 byte sun_path limit).
  let shortDir = URL(fileURLWithPath: "/tmp/bb-menu-\(UUID().uuidString.prefix(8))")
  try FileManager.default.createDirectory(at: shortDir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: shortDir) }
  let socketPath = shortDir.appending(path: ServiceStatusClient.socketFileName).path

  let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(serverFD >= 0)
  defer { Darwin.close(serverFD) }

  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  let copied = withUnsafeMutableBytes(of: &addr.sun_path) { raw -> Bool in
    raw.initializeMemory(as: UInt8.self, repeating: 0)
    guard let base = raw.baseAddress else { return false }
    let dst = base.assumingMemoryBound(to: CChar.self)
    socketPath.withCString { cstr in
      _ = strncpy(dst, cstr, 103)
    }
    return true
  }
  #expect(copied)
  let bound = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  #expect(bound == 0)
  #expect(Darwin.listen(serverFD, 4) == 0)

  let serverStateDir = shortDir.path
  let serverThread = Thread {
    let clientFD = Darwin.accept(serverFD, nil, nil)
    guard clientFD >= 0 else { return }
    defer { Darwin.close(clientFD) }
    var buf = [UInt8](repeating: 0, count: 1024)
    let n = Darwin.recv(clientFD, &buf, buf.count, 0)
    let requestData = n > 0 ? Data(buf[0..<n]) : Data()
    let trimmed = Data(
      requestData.prefix { $0 != 0x0A && $0 != 0x0D }
    )
    let decoded = try? JSONDecoder().decode(NativeCommand.self, from: trimmed)
    let topLevel = (try? JSONSerialization.jsonObject(with: trimmed)) as? [String: Any]
    let validShape =
      topLevel?["type"] as? String == "native"
      && (topLevel?["request"] as? [String: Any])?["type"] as? String == "service_status"

    let encoder = JSONEncoder()
    var reply = Data()
    if validShape, case .native(let command) = decoded, command.request == .serviceStatus {
      let status = NativeEvent.serviceStatus(
        .init(
          coordinatorId: "coord-1",
          executablePath: "/nix/store/old/bin/beep-boop",
          pid: 4242,
          stateDir: serverStateDir,
          version: "0.1.0"
        ))
      if let statusBytes = try? encoder.encode(status),
        let doneBytes = try? encoder.encode(NativeEvent.done)
      {
        reply.append(statusBytes)
        reply.append(0x0A)
        reply.append(doneBytes)
        reply.append(0x0A)
      }
    } else if let failure = try? encoder.encode(
      NativeEvent.failure(.init(code: .invalidRequest, message: "unexpected request")))
    {
      reply.append(failure)
      reply.append(0x0A)
    }
    reply.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      _ = Darwin.send(clientFD, base, raw.count, 0)
    }
  }
  serverThread.start()

  let client = ServiceStatusClient(stateDir: shortDir, explicitBinaryPath: binary.path)
  let snapshot = await client.refreshAsync()

  #expect(
    snapshot.running
      == .running(
        RunningServiceInfo(
          coordinatorID: "coord-1",
          pid: 4242,
          version: "0.1.0",
          executablePath: "/nix/store/old/bin/beep-boop",
          stateDir: shortDir.path
        )))
  #expect(snapshot.installed?.version == "0.2.0")
  #expect(snapshot.alignment == .versionMismatch(installed: "0.2.0", running: "0.1.0"))

  // Missing socket reports service stopped cleanly.
  let missingClient = ServiceStatusClient(
    stateDir: root.appending(path: "missing"), explicitBinaryPath: binary.path)
  let stopped = await missingClient.refreshAsync()
  #expect(stopped.alignment == .serviceStopped)
}

@Test func detectsBinaryPathReplacementEvenWhenSemverMatches() {
  let running = ServiceRunningState.running(
    RunningServiceInfo(
      coordinatorID: "coord-1",
      pid: 100,
      version: "0.1.0",
      executablePath: "/nix/store/aaa-beep-boop/bin/beep-boop",
      stateDir: "/tmp/state"
    ))
  let installed = InstalledBinaryInfo(
    path: "/etc/profiles/per-user/example/bin/beep-boop",
    resolvedPath: "/nix/store/bbb-beep-boop/bin/beep-boop",
    version: "0.1.0"
  )
  #expect(
    ServiceStatusClient.compare(running: running, installed: installed)
      == .binaryReplaced(
        version: "0.1.0",
        installedPath: "/nix/store/bbb-beep-boop/bin/beep-boop",
        runningPath: "/nix/store/aaa-beep-boop/bin/beep-boop"
      ))
}
