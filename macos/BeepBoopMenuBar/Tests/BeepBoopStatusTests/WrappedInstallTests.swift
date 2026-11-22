import BeepBoopStatusCore
import Darwin
import Foundation
import Testing

/// An install laid out the way the Nix package lays it out: `bin/beep-boop` is a script that
/// runs the program beside it, `bin/.beep-boop-wrapped`.
struct WrappedInstall {
  let root: URL

  var wrapper: URL { root.appending(path: "bin/beep-boop") }

  init(version: String) throws {
    root = FileManager.default.temporaryDirectory.appending(path: "bb-menu-\(UUID().uuidString)")
    let bin = root.appending(path: "bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["beep-boop", ".beep-boop-wrapped"] {
      let file = bin.appending(path: name)
      try "#!/bin/sh\necho 'beep-boop \(version)'\n".write(
        to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
  }

  /// A service started from this install reports its program file after `canonicalize`.
  func runningProgramPath() throws -> String {
    guard let canonical = realpath(root.appending(path: "bin/.beep-boop-wrapped").path, nil) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { free(canonical) }
    return String(cString: canonical)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}

private func alignment(installedAt binary: URL, service: FakeService) -> VersionAlignment {
  ServiceStatusClient(stateDir: service.stateDir, explicitBinaryPath: binary.path)
    .refresh(environment: [:])
    .alignment
}

@Test func reportsWrapperScriptAndItsRunningProgramAsUpToDate() throws {
  let install = try WrappedInstall(version: "0.1.0")
  defer { install.remove() }
  let service = try FakeService.start(reporting: install.runningProgramPath(), version: "0.1.0")
  defer { service.remove() }

  #expect(alignment(installedAt: install.wrapper, service: service) == .upToDate(version: "0.1.0"))
}

@Test func reportsProfileLinkToWrapperScriptAsUpToDate() throws {
  let install = try WrappedInstall(version: "0.1.0")
  defer { install.remove() }
  let profile = FileManager.default.temporaryDirectory.appending(
    path: "bb-menu-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: profile) }
  let link = profile.appending(path: "bin/beep-boop")
  try FileManager.default.createDirectory(
    at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: install.wrapper)
  let service = try FakeService.start(reporting: install.runningProgramPath(), version: "0.1.0")
  defer { service.remove() }

  #expect(alignment(installedAt: link, service: service) == .upToDate(version: "0.1.0"))
}

@Test func reportsRunningProgramInAnotherFolderAsReplaced() throws {
  let installed = try WrappedInstall(version: "0.1.0")
  defer { installed.remove() }
  let running = try WrappedInstall(version: "0.1.0")
  defer { running.remove() }
  let runningPath = try running.runningProgramPath()
  let service = try FakeService.start(reporting: runningPath, version: "0.1.0")
  defer { service.remove() }

  #expect(
    alignment(installedAt: installed.wrapper, service: service)
      == .binaryReplaced(
        version: "0.1.0",
        installedPath: installed.wrapper.resolvingSymlinksInPath().path,
        runningPath: runningPath
      ))
}

@Test func reportsWrappedInstallOfAnotherVersionAsMismatch() throws {
  let install = try WrappedInstall(version: "0.2.0")
  defer { install.remove() }
  let service = try FakeService.start(reporting: install.runningProgramPath(), version: "0.1.0")
  defer { service.remove() }

  #expect(
    alignment(installedAt: install.wrapper, service: service)
      == .versionMismatch(installed: "0.2.0", running: "0.1.0"))
}
