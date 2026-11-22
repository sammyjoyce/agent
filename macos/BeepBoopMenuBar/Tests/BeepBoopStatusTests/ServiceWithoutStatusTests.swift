import AgentCore
import BeepBoopStatusCore
import Foundation
import Testing

private func runningState(of service: FakeService) -> ServiceRunningState {
  ServiceStatusClient(stateDir: service.stateDir).queryRunningService(
    socketPath: service.socketPath)
}

private func isStopped(_ state: ServiceRunningState) -> Bool {
  if case .stopped = state { return true }
  return false
}

@Test func reportsClosedConnectionAsRunningWithoutStatus() throws {
  let service = try FakeService.start(replying: "")
  defer { service.remove() }

  #expect(
    runningState(of: service)
      == .runningWithoutStatus(reason: "Service closed the connection without an answer"))
}

@Test func reportsSilentConnectionAsRunningWithoutStatus() throws {
  let clientGaveUp = DispatchSemaphore(value: 0)
  let service = try FakeService.start { _ in clientGaveUp.wait() }
  defer {
    clientGaveUp.signal()
    service.remove()
  }

  #expect(
    runningState(of: service)
      == .runningWithoutStatus(reason: "Service did not answer within 2 seconds"))
}

@Test func reportsDoneOnlyAnswerAsRunningWithoutStatus() throws {
  let service = try FakeService.start(replying: try FakeService.line(.done))
  defer { service.remove() }

  #expect(
    runningState(of: service)
      == .runningWithoutStatus(reason: "Service answered without a status"))
}

@Test func reportsUnknownAnswerTextAsRunningWithoutStatus() throws {
  let service = try FakeService.start(replying: "not a protocol frame\n")
  defer { service.remove() }

  #expect(
    runningState(of: service)
      == .runningWithoutStatus(reason: "Service answered with text that is not a known event"))
}

@Test func reportsFailureFrameAsRunningWithoutStatus() throws {
  let failure = NativeEvent.failure(.init(code: .invalidRequest, message: "invented failure"))
  let service = try FakeService.start(replying: try FakeService.line(failure))
  defer { service.remove() }

  #expect(runningState(of: service) == .runningWithoutStatus(reason: "invented failure"))
}

@Test func reportsMissingSocketFileAsStopped() throws {
  let service = try FakeService.withoutSocket()
  defer { service.remove() }

  let state = runningState(of: service)
  #expect(isStopped(state), "\(state)")
}

@Test func reportsRefusedConnectionAsStopped() throws {
  let service = try FakeService.stale()
  defer { service.remove() }

  let state = runningState(of: service)
  #expect(isStopped(state), "\(state)")
}

@Test func comparesServiceWithoutStatusAsItsOwnAlignment() {
  let installed = InstalledBinaryInfo(
    path: "/invented/profile/bin/beep-boop",
    resolvedPath: "/invented/store/bin/beep-boop",
    version: "0.1.0"
  )
  let running = ServiceRunningState.runningWithoutStatus(reason: "invented reason")

  #expect(
    ServiceStatusClient.compare(running: running, installed: installed)
      == .serviceRunningWithoutStatus)
  #expect(
    ServiceStatusClient.compare(running: running, installed: nil) == .serviceRunningWithoutStatus)
}
