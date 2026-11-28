import AgentCore
import BeepBoopStatusCore
import Darwin
import Foundation
import Testing

private func makeScriptBinary(
  in dir: URL,
  version: String
) throws -> (wrapper: URL, wrapped: String) {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let script = "#!/bin/sh\necho 'beep-boop \(version)'\n"
  let binary = dir.appending(path: "beep-boop")
  let wrapped = dir.appending(path: ".beep-boop-wrapped")
  for file in [binary, wrapped] {
    try script.write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
  }
  return (binary, wrapped.resolvingSymlinksInPath().path)
}

private func startMockStatusSocket(
  in dir: URL,
  socketName: String,
  event: NativeEvent
) throws -> Int32 {
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let path = dir.appending(path: socketName).path
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(fd >= 0)
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.initializeMemory(as: UInt8.self, repeating: 0)
    raw.copyBytes(from: path.utf8)
  }
  let bound = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  #expect(bound == 0)
  #expect(Darwin.listen(fd, 4) == 0)

  let encoder = JSONEncoder()
  var reply = try encoder.encode(event)
  reply.append(0x0A)
  reply.append(try encoder.encode(NativeEvent.done))
  reply.append(0x0A)
  let payload = reply

  Thread {
    defer { Darwin.close(fd) }
    let client = Darwin.accept(fd, nil, nil)
    guard client >= 0 else { return }
    defer { Darwin.close(client) }
    var noSigpipe: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    var buf = [UInt8](repeating: 0, count: 1024)
    _ = Darwin.recv(client, &buf, buf.count, 0)
    payload.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      _ = Darwin.send(client, base, raw.count, 0)
    }
  }.start()
  return fd
}

@Test func discoversWorkerAndStandbyFromLaunchAgentsAndEvaluatesPerServiceBinaries() async throws {
  let root = URL(fileURLWithPath: "/tmp/bb-multi-\(UUID().uuidString.prefix(8))")
  let stateDir = root.appending(path: "agent", directoryHint: .isDirectory)
  let standbyDir = root.appending(path: "agent-standby", directoryHint: .isDirectory)
  let launchAgents = root.appending(path: "LaunchAgents", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: standbyDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  // Worker uses wrapped package; standby uses unwrapped package.
  let gatewayInstall = try makeScriptBinary(
    in: root.appending(path: "gw-pkg/bin"), version: "0.1.0")
  let standbyInstall = try makeScriptBinary(
    in: root.appending(path: "raw-pkg/bin"), version: "0.1.0")
  let marker = standbyDir.appending(path: "coordinator-id")
  try "coord-main\n".write(to: marker, atomically: true, encoding: .utf8)

  let workerPlist: [String: Any] = [
    "Label": "org.example.agent-worker",
    "ProgramArguments": [
      "/bin/sh", "-c", "/bin/wait4path /nix/store && exec \"$@\"", "beep-boop",
      gatewayInstall.wrapper.path, "--config", "/tmp/config.toml", "maintain",
    ],
  ]
  let standbyPlist: [String: Any] = [
    "Label": "org.example.beep-boop-standby",
    "KeepAlive": ["PathState": [marker.path: true]],
    "ProgramArguments": [
      "/bin/sh", "-c", "/bin/wait4path /nix/store && exec \"$@\"", "beep-boop",
      standbyInstall.wrapper.path, "--config", "/tmp/standby.toml", "--state-dir", standbyDir.path,
      "failover", "follow",
    ],
  ]
  let unrelatedPlist: [String: Any] = [
    "Label": "org.example.unrelated",
    "ProgramArguments": ["/bin/sleep", "60"],
  ]
  try PropertyListSerialization.data(fromPropertyList: workerPlist, format: .xml, options: 0)
    .write(to: launchAgents.appending(path: "org.example.agent-worker.plist"))
  try PropertyListSerialization.data(fromPropertyList: standbyPlist, format: .xml, options: 0)
    .write(to: launchAgents.appending(path: "org.example.beep-boop-standby.plist"))
  try PropertyListSerialization.data(fromPropertyList: unrelatedPlist, format: .xml, options: 0)
    .write(to: launchAgents.appending(path: "org.example.unrelated.plist"))

  let workerInner = gatewayInstall.wrapped
  let standbyInner = standbyInstall.wrapped

  _ = try startMockStatusSocket(
    in: stateDir,
    socketName: ServiceStatusClient.workerSocketFileName,
    event: .serviceStatus(
      .init(
        connectionState: .connected,
        coordinatorId: "coord-main",
        executablePath: workerInner,
        nodeName: "workstation",
        pid: 1001,
        role: .worker,
        stateDir: stateDir.path,
        target: "tailscale://100.64.0.10",
        version: "0.1.0"
      )))

  _ = try startMockStatusSocket(
    in: standbyDir,
    socketName: ServiceStatusClient.standbySocketFileName,
    event: .serviceStatus(
      .init(
        appliedPosition: 88,
        connectionState: .following,
        coordinatorId: "coord-main",
        executablePath: standbyInner,
        pid: 1002,
        role: .standby,
        stateDir: standbyDir.path,
        version: "0.1.0"
      )))

  let client = ServiceStatusClient(
    stateDir: stateDir,
    explicitBinaryPath: gatewayInstall.wrapper.path,
    launchAgentsDir: launchAgents
  )
  let snapshot = await client.refreshHostAsync()

  // Coordinator is neither configured nor running, so only Worker and Standby appear.
  #expect(snapshot.services.map(\.role) == [.worker, .standby])
  #expect(snapshot.overallHealth == .healthy)

  let worker = snapshot.services[0]
  #expect(worker.health == .healthy)
  #expect(worker.alignment == .upToDate(version: "0.1.0"))
  if case .running(let info) = worker.running {
    #expect(info.nodeName == "workstation")
    #expect(info.target == "tailscale://100.64.0.10")
    #expect(info.connectionState == .connected)
  } else {
    Issue.record("Expected running worker, got \(worker.running)")
  }

  let standby = snapshot.services[1]
  #expect(standby.health == .healthy)
  #expect(standby.alignment == .upToDate(version: "0.1.0"))
  if case .running(let info) = standby.running {
    #expect(info.appliedPosition == 88)
    #expect(info.connectionState == .following)
  } else {
    Issue.record("Expected running standby, got \(standby.running)")
  }
}

@Test func reconnectingWorkerMarksOverallHealthDegraded() async throws {
  let root = URL(fileURLWithPath: "/tmp/bb-reconn-\(UUID().uuidString.prefix(8))")
  let stateDir = root.appending(path: "agent", directoryHint: .isDirectory)
  let emptyLaunchAgents = root.appending(path: "LaunchAgents", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: emptyLaunchAgents, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let binary = try makeScriptBinary(in: root.appending(path: "pkg/bin"), version: "0.1.0")
  _ = try startMockStatusSocket(
    in: stateDir,
    socketName: ServiceStatusClient.workerSocketFileName,
    event: .serviceStatus(
      .init(
        connectionState: .reconnecting,
        coordinatorId: "coord-main",
        detail: "Coordinator unreachable",
        executablePath: binary.wrapped,
        nodeName: "workstation",
        pid: 2001,
        role: .worker,
        stateDir: stateDir.path,
        target: "tailscale://100.64.0.10",
        version: "0.1.0"
      )))

  let client = ServiceStatusClient(
    stateDir: stateDir,
    explicitBinaryPath: binary.wrapper.path,
    launchAgentsDir: emptyLaunchAgents
  )
  let snapshot = await client.refreshHostAsync()
  #expect(snapshot.services.count == 1)
  #expect(snapshot.services[0].health == .degraded)
  #expect(snapshot.overallHealth == .degraded)
}

@Test func aggregatesAllStoppedAsStoppedAndPartialStoppedAsDegraded() {
  let stopped = ServiceSnapshot(
    role: .worker,
    configured: true,
    socketPath: "/tmp/worker.sock",
    stateDir: "/tmp",
    running: .stopped(reason: "Socket not found"),
    installed: nil,
    alignment: .serviceStopped,
    health: .stopped
  )
  let healthy = ServiceSnapshot(
    role: .standby,
    configured: true,
    socketPath: "/tmp/standby.sock",
    stateDir: "/tmp",
    running: .running(
      RunningServiceInfo(
        coordinatorID: "coord-main",
        pid: 42,
        version: "0.1.0",
        executablePath: "/tmp/bin/beep-boop",
        stateDir: "/tmp",
        role: .standby,
        connectionState: .following
      )),
    installed: InstalledBinaryInfo(
      path: "/tmp/bin/beep-boop",
      resolvedPath: "/tmp/bin/beep-boop",
      version: "0.1.0"
    ),
    alignment: .upToDate(version: "0.1.0"),
    health: .healthy
  )
  #expect(ServiceStatusClient.aggregateHealth([]) == .stopped)
  #expect(ServiceStatusClient.aggregateHealth([stopped]) == .stopped)
  #expect(ServiceStatusClient.aggregateHealth([stopped, healthy]) == .degraded)
  #expect(ServiceStatusClient.aggregateHealth([healthy]) == .healthy)
}

@Test func treatsServeWithCoordinatorFlagAsWorkerAndIgnoresStaleUnconfiguredSockets() async throws {
  let root = URL(fileURLWithPath: "/tmp/bb-stale-\(UUID().uuidString.prefix(8))")
  let stateDir = root.appending(path: "agent", directoryHint: .isDirectory)
  let launchAgents = root.appending(path: "LaunchAgents", directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let binary = try makeScriptBinary(in: root.appending(path: "pkg/bin"), version: "0.1.0")

  // Stale standby socket without an active LaunchAgent must not become a stopped phantom.
  let stalePath = stateDir.appending(path: ServiceStatusClient.standbySocketFileName).path
  let staleFD = socket(AF_UNIX, SOCK_STREAM, 0)
  #expect(staleFD >= 0)
  var addr = sockaddr_un()
  addr.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &addr.sun_path) { raw in
    raw.initializeMemory(as: UInt8.self, repeating: 0)
    raw.copyBytes(from: stalePath.utf8)
  }
  _ = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      Darwin.bind(staleFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  Darwin.close(staleFD)

  // `beep-boop --coordinator <target> serve` runs a worker (`worker.sock`), not a coordinator.
  let plist: [String: Any] = [
    "Label": "org.example.worker-serve",
    "ProgramArguments": [
      binary.wrapper.path, "--coordinator", "tailscale://100.64.0.10", "serve",
    ],
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: launchAgents.appending(path: "org.example.worker-serve.plist"))

  let client = ServiceStatusClient(
    stateDir: stateDir,
    explicitBinaryPath: binary.wrapper.path,
    launchAgentsDir: launchAgents
  )
  let snapshot = await client.refreshHostAsync()
  #expect(snapshot.services.map(\.role) == [.worker])
  #expect(snapshot.overallHealth == .stopped)
}
