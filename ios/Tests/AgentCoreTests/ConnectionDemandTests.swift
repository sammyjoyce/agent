import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

@Test(arguments: [
  (scene: false, held: 0, dropped: 0, elsewhere: 0, wanted: false),
  (scene: true, held: 0, dropped: 0, elsewhere: 0, wanted: true),
  (scene: false, held: 1, dropped: 0, elsewhere: 0, wanted: true),
  (scene: true, held: 1, dropped: 0, elsewhere: 0, wanted: true),
  (scene: false, held: 1, dropped: 1, elsewhere: 0, wanted: false),
  (scene: true, held: 1, dropped: 1, elsewhere: 0, wanted: true),
  (scene: false, held: 2, dropped: 1, elsewhere: 0, wanted: true),
  (scene: false, held: 2, dropped: 2, elsewhere: 0, wanted: false),
  (scene: false, held: 0, dropped: 0, elsewhere: 1, wanted: false),
])
func aLaneWantsAConnectionWhileTheSceneIsActiveOrItHoldsALease(
  scene: Bool, held: Int, dropped: Int, elsewhere: Int, wanted: Bool
) {
  let work = ProfileID()
  let personal = ProfileID()
  var demand = ConnectionDemand()
  demand.sceneActive = scene
  let leases = (0..<held).map { _ in demand.take(work) }
  for _ in 0..<elsewhere { _ = demand.take(personal) }
  for lease in leases.prefix(dropped) { demand.drop(lease) }
  #expect(demand.wants(work) == wanted)
}

private struct LeasedBodyFailed: Error {}

@MainActor private final class Entries {
  var count = 0
}

@MainActor private func until(
  _ description: String, within limit: Duration = .seconds(15), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func observeCount(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .observe = $0 { true } else { false } }.count
}

@MainActor private func connection(_ chat: ChatModel, _ id: ProfileID) -> ConnectionState? {
  chat.snapshots[id]?.connection
}

/// Work and Personal paired and connected, then the scene sent to the background until both
/// lanes report disconnected.
@MainActor private func withBackgroundedPair(
  _ body: (Coordinators, ProfileID, ProfileID, FixtureCoordinator, FixtureCoordinator) async throws
    -> Void
) async throws {
  try await withTwoFixtures { coordinators, workPeer, personalPeer, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    await coordinators.setActive(false)
    try await until("both lanes disconnected") {
      connection(chat, work) == .disconnected && connection(chat, personal) == .disconnected
    }
    try await body(coordinators, work, personal, workPeer, personalPeer)
  }
}

@MainActor @Test func aLeaseFromTheBackgroundConnectsOnlyItsLaneUntilItIsDropped() async throws {
  try await withBackgroundedPair { coordinators, work, personal, workPeer, personalPeer in
    let chat = coordinators.chat
    let workObserves = await observeCount(workPeer)
    let personalObserves = await observeCount(personalPeer)
    let during = try await coordinators.withConnection(to: work) {
      (work: connection(chat, work), personal: connection(chat, personal))
    }
    #expect(during.work == .connected, "The leased lane connected before the body ran")
    #expect(during.personal == .disconnected, "The other lane stayed disconnected")
    #expect(await observeCount(workPeer) == workObserves + 1)
    #expect(await observeCount(personalPeer) == personalObserves, "Personal was never dialed")
    #expect(!chat.demand.leased(work))
    try await until("Work disconnected once the lease dropped") {
      connection(chat, work) == .disconnected
    }
    #expect(connection(chat, personal) == .disconnected)
  }
}

@MainActor @Test func aLeaseDroppedWhileTheSceneIsActiveLeavesTheLaneConnected() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let observes = await observeCount(workPeer)
    try await coordinators.withConnection(to: work) {
      #expect(connection(chat, work) == .connected)
    }
    try await Task.sleep(for: .milliseconds(300))
    #expect(connection(chat, work) == .connected, "Work stayed connected after the lease")
    #expect(await observeCount(workPeer) == observes, "The lease never redialed Work")
  }
}

@MainActor @Test func aLeaseKeepsItsLaneConnectedWhenTheSceneLeaves() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let entries = Entries()
    let (gate, release) = AsyncStream<Void>.makeStream()
    let held = Task { @MainActor in
      await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in gate {}
      }
    }
    try await until("the lease held") { entries.count == 1 }
    let observes = await observeCount(workPeer)
    await coordinators.setActive(false)
    try await until("Personal disconnected") { connection(chat, personal) == .disconnected }
    #expect(connection(chat, work) == .connected, "The leased lane stayed connected")
    #expect(await observeCount(workPeer) == observes, "Leaving the scene never redialed Work")
    release.finish()
    await held.value
    try await until("Work disconnected once the lease dropped") {
      connection(chat, work) == .disconnected
    }
  }
}

@MainActor @Test func aThrowingBodyStillDropsItsLease() async throws {
  try await withBackgroundedPair { coordinators, work, _, _, _ in
    let chat = coordinators.chat
    await #expect(throws: LeasedBodyFailed.self) {
      try await coordinators.withConnection(to: work) {
        #expect(connection(chat, work) == .connected)
        throw LeasedBodyFailed()
      }
    }
    #expect(!chat.demand.leased(work), "The lease was dropped")
    try await until("Work disconnected after the throw") { connection(chat, work) == .disconnected }
  }
}

@MainActor @Test func aCancelledTaskStillDropsItsLease() async throws {
  try await withBackgroundedPair { coordinators, work, _, _, _ in
    let chat = coordinators.chat
    let entries = Entries()
    let held = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        entries.count += 1
        try await Task.sleep(for: .seconds(600))
      }
    }
    try await until("the lease held") { entries.count == 1 }
    #expect(chat.demand.leased(work))
    held.cancel()
    await #expect(throws: CancellationError.self) { try await held.value }
    #expect(!chat.demand.leased(work), "The lease was dropped")
    try await until("Work disconnected after the cancel") {
      connection(chat, work) == .disconnected
    }
  }
}

@MainActor @Test func twoLeasesOnOneLaneKeepItConnectedUntilBothDrop() async throws {
  try await withBackgroundedPair { coordinators, work, _, workPeer, _ in
    let chat = coordinators.chat
    let entries = Entries()
    let (firstGate, firstRelease) = AsyncStream<Void>.makeStream()
    let (secondGate, secondRelease) = AsyncStream<Void>.makeStream()
    let first = Task { @MainActor in
      await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in firstGate {}
      }
    }
    let second = Task { @MainActor in
      await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in secondGate {}
      }
    }
    try await until("both leases held") { entries.count == 2 }
    let observes = await observeCount(workPeer)
    firstRelease.finish()
    await first.value
    #expect(chat.demand.leased(work), "The second lease is still held")
    #expect(connection(chat, work) == .connected, "One lease left keeps Work connected")
    #expect(await observeCount(workPeer) == observes, "Dropping the first lease never redialed")
    secondRelease.finish()
    await second.value
    #expect(!chat.demand.leased(work))
    try await until("Work disconnected once the last lease dropped") {
      connection(chat, work) == .disconnected
    }
  }
}
