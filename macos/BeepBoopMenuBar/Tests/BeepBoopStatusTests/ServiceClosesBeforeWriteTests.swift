import BeepBoopStatusCore
import Darwin
import Foundation
import Testing

nonisolated(unsafe) private var brokenPipeSignals: sig_atomic_t = 0

@Test func survivesListenerThatClosesBeforeTheClientWrites() throws {
  let queries = 300
  let service = try FakeService.start(closingConnections: queries)
  defer { service.remove() }

  // The default action for SIGPIPE ends the test process. A handler makes the signal countable,
  // and the kernel runs it on the writing thread before the write returns.
  brokenPipeSignals = 0
  let previousAction = signal(SIGPIPE) { _ in brokenPipeSignals += 1 }
  defer { signal(SIGPIPE, previousAction) }

  let client = ServiceStatusClient(stateDir: service.stateDir)
  let accepted: [ServiceRunningState] = [
    .runningWithoutStatus(reason: "Service closed the connection without an answer"),
    .runningWithoutStatus(reason: "Failed to write status query to service socket"),
  ]
  for query in 1...queries {
    let state = client.queryRunningService(socketPath: service.socketPath)
    #expect(accepted.contains(state), "query \(query) returned \(state)")
  }

  #expect(brokenPipeSignals == 0, "queries raised SIGPIPE \(brokenPipeSignals) times")
}
