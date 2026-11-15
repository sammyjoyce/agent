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

/// The lane's state as its session reports it. A leased body runs on this, ahead of the copy
/// `connection` reads.
@MainActor private func sessionConnection(_ chat: ChatModel, _ id: ProfileID) async
  -> ConnectionState?
{
  await chat.lanes.first { $0.id == id }?.session?.connectionState
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
      (work: await sessionConnection(chat, work), personal: connection(chat, personal))
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
      try await coordinators.withConnection(to: work) {
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
    try await held.value
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
        #expect(await sessionConnection(chat, work) == .connected)
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
      try await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in firstGate {}
      }
    }
    let second = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in secondGate {}
      }
    }
    try await until("both leases held") { entries.count == 2 }
    let observes = await observeCount(workPeer)
    firstRelease.finish()
    try await first.value
    #expect(chat.demand.leased(work), "The second lease is still held")
    #expect(
      await sessionConnection(chat, work) == .connected, "One lease left keeps Work connected")
    #expect(await observeCount(workPeer) == observes, "Dropping the first lease never redialed")
    secondRelease.finish()
    try await second.value
    #expect(!chat.demand.leased(work))
    try await until("Work disconnected once the last lease dropped") {
      connection(chat, work) == .disconnected
    }
  }
}

extension CoordinatorSession {
  /// Occupies this session's actor until `released`, so a lifecycle call on it waits its turn, as
  /// one does behind a busy session.
  fileprivate func occupy(
    entered: AsyncStream<Void>.Continuation, until released: DispatchSemaphore
  ) {
    entered.finish()
    released.wait()
  }
}

/// Runs `work` off the main actor while the main thread is blocked, so nothing queued for the
/// main actor runs before the caller's next line. False if `work` took longer than `limit`.
@MainActor private func holdingTheMainActor(
  for limit: DispatchTimeInterval = .seconds(10), _ work: @escaping @Sendable () async -> Void
) -> Bool {
  let finished = DispatchSemaphore(value: 0)
  Task.detached {
    await work()
    finished.signal()
  }
  return finished.wait(timeout: .now() + limit) == .success
}

/// The scene's activation is held on Work, the first lane, when an intent takes a lease on
/// Personal. Personal is dialed for the lease without waiting for the activation to reach it.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseTakenWhileTheSceneActivatesAnotherLaneDialsItsOwn() async throws {
  try await withBackgroundedPair { coordinators, work, personal, _, personalPeer in
    let chat = coordinators.chat
    await personalPeer.advertiseWorkInspection(true)
    let workSession = try #require(chat.lanes.first { $0.id == work }?.session)
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await workSession.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let activating = Task { @MainActor in await coordinators.setActive(true) }
    try await until("the activation started") { chat.demand.sceneActive }
    let observes = await observeCount(personalPeer)
    let read: Result<NativeJobStatus, any Error>
    do {
      read = .success(
        try await coordinators.withConnection(to: personal) {
          try await chat.jobs(lane: personal)
        })
    } catch { read = .failure(error) }
    let dialed = await observeCount(personalPeer) - observes
    barrier.signal()
    await occupied.value
    await activating.value
    #expect(dialed == 1, "The lease dialed Personal while the activation was still on Work")
    #expect(try read.get() == .list(.init(jobs: [])), "Personal answered the job read")
    try await until("both lanes connected for the scene") {
      connection(chat, work) == .connected && connection(chat, personal) == .connected
    }
    #expect(await observeCount(personalPeer) == observes + 1, "The activation never redialed it")
  }
}

/// Work's observation ends while the main actor is busy, so the main actor's copy still says
/// connected when the lease is taken. The body runs only once the session reconnected.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseWaitsForTheSessionWhenTheMainActorsCopyStillSaysConnected() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    await workPeer.advertiseWorkInspection(true)
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let observes = await observeCount(workPeer)
    let reconnecting = holdingTheMainActor {
      try? await workPeer.emitOnObserver(.done)
      // The session refuses a job read once it is no longer connected.
      while (try? await session.jobs()) != nil {}
    }
    #expect(reconnecting, "Work's session left connected")
    #expect(connection(chat, work) == .connected, "The main actor's copy is stale")
    let read = try await coordinators.withConnection(to: work) {
      (jobs: try await chat.jobs(lane: work), observes: await observeCount(workPeer))
    }
    #expect(read.jobs == .list(.init(jobs: [])), "Work answered the job read")
    #expect(read.observes == observes + 1, "The body ran after Work's new observation")
  }
}

/// The scene leaves while Work's session is busy, and a lease is taken on Work before that
/// disconnect lands. The lane's loop ends at the latest demand, so Work is dialed again for the
/// lease and its body runs on the new connection.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseTakenWhileTheSceneLeavesReconnectsItsLane() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    await workPeer.advertiseWorkInspection(true)
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let observes = await observeCount(workPeer)
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await session.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let leaving = Task { @MainActor in await coordinators.setActive(false) }
    try await until("the scene left") { !chat.demand.sceneActive }
    let reading = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        (jobs: try await chat.jobs(lane: work), observes: await observeCount(workPeer))
      }
    }
    try await until("the lease taken") { chat.demand.leased(work) }
    barrier.signal()
    await occupied.value
    await leaving.value
    let read = try await reading.value
    #expect(read.jobs == .list(.init(jobs: [])), "Work answered the job read")
    #expect(read.observes == observes + 1, "Work was dialed once more, for the lease")
    #expect(await sessionConnection(chat, work) == .disconnected, "The dropped lease closed Work")
    #expect(await sessionConnection(chat, personal) == .disconnected)
    #expect(await observeCount(workPeer) == observes + 1)
  }
}

@MainActor @Test func anActivationNeverRedialsALaneThatIsConnectedOrLeased() async throws {
  try await withBackgroundedPair { coordinators, work, personal, workPeer, personalPeer in
    let chat = coordinators.chat
    let workObserves = await observeCount(workPeer)
    let personalObserves = await observeCount(personalPeer)
    let (gate, release) = AsyncStream<Void>.makeStream()
    let entries = Entries()
    let held = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in gate {}
      }
    }
    try await until("the lease held") { entries.count == 1 }
    await coordinators.setActive(true)
    try await until("Personal connected for the scene") {
      await sessionConnection(chat, personal) == .connected
    }
    await coordinators.setActive(true)
    release.finish()
    try await held.value
    try await Task.sleep(for: .milliseconds(300))
    #expect(await sessionConnection(chat, work) == .connected, "The scene keeps Work connected")
    #expect(await observeCount(workPeer) == workObserves + 1, "Only the lease dialed Work")
    #expect(await observeCount(personalPeer) == personalObserves + 1, "One dial for the scene")
  }
}

/// "Try again" redials Work while a lease waits on it, and the wait's read of the session was
/// answered before the redial reached the session. The body runs on the new connection, not on
/// the one the redial closes.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseThatReadsConnectedWhileItsLaneIsRedialedWaitsForTheRedial() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    await workPeer.advertiseWorkInspection(true)
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let observes = await observeCount(workPeer)
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await session.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let reading = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        (jobs: try await chat.jobs(lane: work), observes: await observeCount(workPeer))
      }
    }
    try await until("the lease taken") { chat.demand.leased(work) }
    let redialing = Task { @MainActor in await chat.reconnect(work) }
    // The redial takes two turns of the main actor to reach the session, behind the lease's read.
    for _ in 1...10 { await Task.yield() }
    barrier.signal()
    await occupied.value
    await redialing.value
    let read = try await reading.value
    #expect(read.jobs == .list(.init(jobs: [])), "Work answered the job read")
    #expect(read.observes == observes + 1, "The body ran after the redial's observation")
  }
}

/// "Try again" is redialing Work when the last lease on it is dropped. The lease waits for the
/// lane's loop, so Work is closed before `withConnection` returns.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseDroppedWhileItsLaneIsRedialedReturnsOnceTheLaneIsClosed() async throws {
  try await withBackgroundedPair { coordinators, work, _, _, _ in
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let (gate, release) = AsyncStream<Void>.makeStream()
    let entries = Entries()
    let held = Task { @MainActor in
      try await coordinators.withConnection(to: work) {
        entries.count += 1
        for await _ in gate {}
      }
      entries.count += 1
    }
    try await until("the lease held") { entries.count == 1 }
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await session.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let redialing = Task { @MainActor in await chat.reconnect(work) }
    for _ in 1...10 { await Task.yield() }
    release.finish()
    for _ in 1...10 { await Task.yield() }
    #expect(entries.count == 1, "The lease does not return while the redial is in flight")
    barrier.signal()
    await occupied.value
    await redialing.value
    try await held.value
    #expect(await sessionConnection(chat, work) == .disconnected, "Work was closed on return")
    #expect(!chat.demand.leased(work), "The lease was dropped")
  }
}

@MainActor @Test func tryAgainRedialsOnlyALaneSomethingWants() async throws {
  try await withTwoFixtures { coordinators, workPeer, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let observes = await observeCount(workPeer)
    await chat.reconnect(work)
    try await until("Work redialed") { await observeCount(workPeer) == observes + 1 }
    await coordinators.setActive(false)
    await chat.reconnect(work)
    try await Task.sleep(for: .milliseconds(300))
    #expect(await observeCount(workPeer) == observes + 1, "Nothing wants Work connected")
    #expect(await sessionConnection(chat, work) == .disconnected)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseThatDoesNotConnectInTimeNamesItsCoordinatorAndNeverRunsItsBody() async throws {
  try await withBackgroundedPair { coordinators, work, _, workPeer, _ in
    let chat = coordinators.chat
    let entries = Entries()
    await workPeer.leaveObserveUnanswered(.silent)
    let started = ContinuousClock.now
    await #expect(throws: LaneError.unanswered("Work")) {
      try await coordinators.withConnection(to: work, within: .milliseconds(300)) {
        entries.count += 1
      }
    }
    #expect(
      ContinuousClock.now - started < ConnectionLease.connectionWait,
      "The wait ended at the limit it was given")
    #expect(entries.count == 0, "The body never ran")
    #expect(!chat.demand.leased(work), "The lease was dropped")
    #expect(await sessionConnection(chat, work) == .disconnected, "Work was closed on return")
    #expect(LaneError.unanswered("Work").localizedDescription == "Work did not answer.")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseCancelledWhileItWaitsNeverRunsItsBody() async throws {
  try await withBackgroundedPair { coordinators, work, _, workPeer, _ in
    let chat = coordinators.chat
    let entries = Entries()
    await workPeer.leaveObserveUnanswered(.silent)
    let observes = await observeCount(workPeer)
    let waiting = Task { @MainActor in
      try await coordinators.withConnection(to: work) { entries.count += 1 }
    }
    try await until("Work dialed for the lease") { await observeCount(workPeer) == observes + 1 }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(entries.count == 0, "The body never ran")
    #expect(!chat.demand.leased(work), "The lease was dropped")
    #expect(await sessionConnection(chat, work) == .disconnected, "Work was closed on return")
  }
}

/// The lane is connected, so the wait would end on its first read of the session. The task is
/// cancelled while that read is in flight, and the body still never runs.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseCancelledAsItsLaneReadsConnectedNeverRunsItsBody() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let entries = Entries()
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await session.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let waiting = Task { @MainActor in
      try await coordinators.withConnection(to: work) { entries.count += 1 }
    }
    try await until("the lease taken") { chat.demand.leased(work) }
    waiting.cancel()
    barrier.signal()
    await occupied.value
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(entries.count == 0, "The body never ran")
    #expect(!chat.demand.leased(work), "The lease was dropped")
    #expect(await sessionConnection(chat, work) == .connected, "The scene keeps Work connected")
  }
}

/// The lane is connected, but its session answers the wait's read only after the deadline.
@MainActor @Test(.timeLimit(.minutes(1)))
func aLeaseWhoseLaneReadsConnectedAfterTheDeadlineNeverRunsItsBody() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let session = try #require(chat.lanes.first { $0.id == work }?.session)
    let entries = Entries()
    let (entered, enter) = AsyncStream<Void>.makeStream()
    let barrier = DispatchSemaphore(value: 0)
    let occupied = Task.detached { await session.occupy(entered: enter, until: barrier) }
    for await _ in entered {}
    let limit = Duration.milliseconds(100)
    let waiting = Task { @MainActor in
      try await coordinators.withConnection(to: work, within: limit) { entries.count += 1 }
    }
    try await until("the lease taken") { chat.demand.leased(work) }
    try await Task.sleep(for: limit * 2)
    barrier.signal()
    await occupied.value
    await #expect(throws: LaneError.unanswered("Work")) { try await waiting.value }
    #expect(entries.count == 0, "The body never ran")
    #expect(!chat.demand.leased(work), "The lease was dropped")
  }
}

@MainActor @Test func aLeaseRefusesARemovedOrUnpairedCoordinatorBeforeItDials() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let personal = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
  let chat = ChatModel()
  chat.profiles = [work, personal]
  let session = CoordinatorSession(
    directory: ProfileDirectory(work.id, applicationSupport: root, caches: root),
    address: work.address, pin: CoordinatorID(UUID()), stamps: StampSource())
  chat.attach(Lane(id: work.id, session: session))
  chat.attach(Lane(id: personal.id, session: nil))
  chat.removed[work.id] = "Work"
  let entries = Entries()
  await #expect(throws: LaneError.gone("Work")) {
    try await chat.withConnection(to: work.id, within: .seconds(1)) { entries.count += 1 }
  }
  await #expect(throws: LaneError.notPaired("Personal")) {
    try await chat.withConnection(to: personal.id, within: .seconds(1)) { entries.count += 1 }
  }
  #expect(entries.count == 0)
  #expect(!chat.demand.leased(work.id) && !chat.demand.leased(personal.id))
  #expect(await session.connectionState == .disconnected, "Nothing was dialed")
}
