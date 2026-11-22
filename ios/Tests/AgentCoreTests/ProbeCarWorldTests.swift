import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

// Adversary probe. Runs only when .adversary/car-world.mjs serves a private coordinator: the real
// service binary, Pi and bridge of this tree, with a synthetic model.

private let world = ProcessInfo.processInfo.environment

@MainActor private final class WorldLines {
  private(set) var lines: [String] = []
  var speaker: Speaker { Speaker { [self] in await say($0) } }
  private func say(_ sentence: String) async { lines.append(sentence) }
}

@MainActor private func wait(
  _ description: String, within limit: Duration = .seconds(30),
  _ predicate: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(try await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(10))
  }
}

private let quick = CarTimings(
  message: .init(trailingQuiet: .milliseconds(60), noWords: .seconds(2), longest: .seconds(5)),
  confirmation: .init(trailingQuiet: .milliseconds(60), noWords: .seconds(2), longest: .seconds(5)),
  turn: .car, tick: .milliseconds(10))

@MainActor private func car(_ coordinators: Coordinators, hearing takes: [String]) -> (
  CarConversation, WorldLines, ScriptedSpeech
) {
  var script = ScriptedSpeech.Script()
  script.takes = takes
  script.partials = ["Invented words"]
  let speech = ScriptedSpeech(script)
  let spoken = WorldLines()
  return (
    CarConversation(
      coordinators: coordinators, engine: speech.engine, speaker: spoken.speaker,
      protectedDataAvailable: { true }, timings: quick), spoken, speech
  )
}

@MainActor private func rows(_ coordinators: Coordinators, _ id: ProfileID) -> [String] {
  (coordinators.chat.snapshots[id]?.rows ?? []).map {
    "\($0.role) [\($0.provenanceLabel ?? "-")] \($0.delivery.map { "\($0)" } ?? "-") \($0.text.prefix(70))"
  }
}

@MainActor @Test(
  .enabled(if: world["AGENT_CAR_E2E_SOCKET"] != nil), .timeLimit(.minutes(5)))
func probeWorldCarTurnsAgainstTheProductionCoordinator() async throws {
  let socket = try #require(world["AGENT_CAR_E2E_SOCKET"])
  let gate = try #require(world["AGENT_CAR_E2E_GATE"])
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "car-world-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let coordinators = Coordinators(
    registration: nil, defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { _ in
      LineConnection(connection: NWConnection(to: .unix(path: socket), using: .tcp))
    })
  await coordinators.setActive(true)
  try await coordinators.add(
    name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
  try await wait("Work connected") {
    coordinators.chat.snapshots.values.contains { $0.connection == .connected }
  }
  let id = coordinators.profiles[0].id
  let session = try #require(coordinators.chat.lanes.first { $0.id == id }?.session)
  print("PROBE world accepts carplay:", await session.accepts(.carplay))

  // 1. Two turns in one conversation with an idle coordinator.
  do {
    let (car, spoken, _) = car(
      coordinators,
      hearing: ["Is the invented deploy done", "Yes.", "Water the invented ferns", "Yes.", ""])
    let work = try #require(car.choices.first)
    let start = ContinuousClock.now
    car.begin(with: work)
    try await wait("the two turns ended", within: .seconds(150)) {
      car.phase == .idle && spoken.lines.count >= 2
    }
    print("PROBE world two turns after", ContinuousClock.now - start, "lines:", spoken.lines)
    #expect(
      spoken.lines == [
        "Talking to Work.", "Send to Work: Is the invented deploy done?",
        "The invented deploy finished.", "Send to Work: Water the invented ferns?",
        "The invented ferns are watered. See the log.",
      ])
  }
  print("PROBE world rows after two turns:", rows(coordinators, id))

  // 2. A car message steered into a turn that a composer message started and that is in a tool.
  do {
    #expect(await session.submit("First invented question"))
    try await wait("the first turn's tool runs") {
      FileManager.default.fileExists(atPath: gate + ".started")
    }
    let (car, spoken, _) = car(coordinators, hearing: ["Is the invented deploy done", "Yes.", ""])
    let work = try #require(car.choices.first)
    let start = ContinuousClock.now
    car.begin(with: work)
    try await wait("the car waits for Work") { car.phase == .working && spoken.lines.count == 2 }
    try await Task.sleep(for: .seconds(2))
    FileManager.default.createFile(atPath: gate + ".release", contents: nil)
    try await wait("the steered turn ended", within: .seconds(120)) { car.phase == .idle }
    print("PROBE world steered turn after", ContinuousClock.now - start, "lines:", spoken.lines)
    #expect(spoken.lines.dropFirst(2).first == "The invented deploy finished.")
  }
  try await Task.sleep(for: .seconds(2))
  print("PROBE world rows at the end:", rows(coordinators, id))
  await coordinators.setActive(false)
}
