import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private let exampleConversation = SavedConversation(
  conversationId: "example-conversation", taskId: "example-task", title: "Example review")

/// The same job ID and task ID on every coordinator, so only the title shows which one answered.
private func exampleJob(title: String) -> ScheduledJobStatus {
  ScheduledJobStatus(
    job: .init(
      cwd: "/workspace/example", id: "example-review",
      model: .init(fast: false, modelId: "example-model", provider: .openai),
      prompt: "Review the invented evidence.", revision: "example-revision", schedules: [],
      timezone: "America/Los_Angeles", title: title),
    schedules: [], taskId: "11111111-1111-4111-8111-111111111111")
}

private func exampleSettings(_ modelID: String) -> NativeSettingsSnapshot {
  .init(
    configured: .init(
      catalog: [], conversationId: "fixture-root",
      model: .init(fast: false, modelId: modelID, provider: .openai)))
}

@MainActor private func eventually(_ what: String, _ predicate: () async -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func inspections(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .inspect = $0 { true } else { false } }.count
}

/// The Jobs and work requests a fixture received, in arrival order.
private func workControls(_ fixture: FixtureCoordinator) async -> [String] {
  await fixture.received().compactMap { request -> String? in
    switch request {
    case .jobs(let jobs): return "jobs \(jobs.jobId ?? "list")"
    case .retryJob(let retry): return "retry \(retry.jobId)"
    case .conversations(let page): return "catalog \(page.cursor ?? "start")"
    default: return nil
    }
  }
}

/// Opens an inspection of `exampleConversation` through the lane's own session, as the inspection
/// screen does, and waits until it is connected.
@MainActor private func openInspection(
  _ chat: ChatModel, lane: ProfileID, on fixture: FixtureCoordinator
) async throws -> CoordinatorSession {
  await fixture.replyToHistory(initial: .init(messages: [], pageComplete: true), pages: [:])
  let session = try #require(chat.lanes.first { $0.id == lane }?.session)
  let inspector = try #require(await session.inspector(exampleConversation))
  await inspector.connect()
  for await snapshot in inspector.updates where snapshot.connection == .connected { break }
  return inspector
}

@MainActor @Test(.timeLimit(.minutes(1)))
func removingACoordinatorRetiresItsOpenInspectionAndDeletesItsFiles() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, root in
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let inspector = try await openInspection(
      coordinators.chat, lane: personal, on: personalFixture)
    try await coordinators.remove(coordinators.removal(personal))
    for await id in personalFixture.closedInspections {
      #expect(id == exampleConversation.conversationId)
      break
    }
    await inspector.connect()
    try await Task.sleep(for: .milliseconds(150))
    #expect(await inspections(personalFixture) == 1, "A retired inspection never dials again")
    #expect(await inspections(workFixture) == 0)
    let directory = ProfileDirectory(personal, applicationSupport: root, caches: root)
    #expect(!FileManager.default.fileExists(atPath: directory.root.path))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func readdressingACoordinatorRetiresItsInspection() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let inspector = try await openInspection(coordinators.chat, lane: work, on: workFixture)
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
    for await _ in workFixture.closedInspections { break }
    await inspector.connect()
    try await Task.sleep(for: .milliseconds(150))
    #expect(
      await inspections(workFixture) == 1, "The replaced session's inspection never dials again")
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func backgroundingDisconnectsAnInspectionAndForegroundingReconnectsIt() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let inspector = try await openInspection(coordinators.chat, lane: work, on: workFixture)
    await coordinators.setActive(false)
    for await _ in workFixture.closedInspections { break }
    await coordinators.setActive(true)
    for await snapshot in inspector.updates where snapshot.connection == .connected { break }
    #expect(await inspections(workFixture) == 2)
  }
}

@Test(.timeLimit(.minutes(1)))
func aRetiredSessionMintsNoInspector() async throws {
  try await withCoordinator { session, _, _ in
    let inspector = try #require(await session.inspector(exampleConversation))
    #expect(await inspector.inspector(exampleConversation) == nil, "An inspection mints none")
    await session.retire()
    #expect(await session.inspector(exampleConversation) == nil)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func workControlsRideOnlyTheAddressedLanesSocket() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    for (fixture, name) in [(workFixture, "Work"), (personalFixture, "Personal")] {
      await fixture.advertiseWorkInspection(true)
      await fixture.serveWork(
        jobs: [exampleJob(title: "\(name) review")],
        conversations: [
          SavedConversation(conversationId: "example-1", title: "\(name) notes"),
          SavedConversation(conversationId: "example-2", title: "\(name) plans"),
        ], pageSize: 1)
    }
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    guard case .list(let listing) = try await chat.jobs(lane: personal) else {
      Issue.record("Job listing lost its typed diagnostics")
      return
    }
    #expect(listing.jobs.map(\.job.title) == ["Personal review"])
    guard case .detail(let detail) = try await chat.jobs("example-review", lane: work) else {
      Issue.record("Job detail lost its typed diagnostics")
      return
    }
    #expect(detail.job.job.title == "Work review")
    #expect(try await chat.retryJob("example-review", lane: work).job.title == "Work review")
    let first = try await chat.conversations(lane: personal)
    let second = try await chat.conversations(cursor: first.nextCursor, lane: personal)
    #expect((first.items + second.items).map(\.title) == ["Personal notes", "Personal plans"])
    #expect(await workControls(workFixture) == ["jobs example-review", "retry example-review"])
    #expect(await workControls(personalFixture) == ["jobs list", "catalog start", "catalog 1"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSettingsChangeReachesOnlyTheChosenCoordinator() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    for (fixture, model) in [(workFixture, "work-model"), (personalFixture, "personal-model")] {
      await fixture.advertiseSettings(true)
      await fixture.replyToSettings(exampleSettings(model))
    }
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let fast = ConversationChange.setFast(.init(mode: .on))
    try await chat.settings(change: fast, lane: personal)
    #expect(await personalFixture.settingsControls().map(\.change) == [fast])
    #expect(await workFixture.settingsControls().isEmpty)
    try await eventually("Personal's settings") { chat.snapshots[personal]?.settings != nil }
    #expect(chat.snapshots[personal]?.settings == exampleSettings("personal-model"))
    #expect(chat.snapshots[work]?.settings == nil)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aRetryInFlightWhenTheCoordinatorIsReaddressedIsInterruptedAndNeverResent() async throws {
  try await withTwoFixtures { coordinators, workFixture, _, _ in
    await workFixture.advertiseWorkInspection(true)
    await workFixture.serveWork(
      jobs: [exampleJob(title: "Work review")], conversations: [], pageSize: 10)
    await workFixture.holdNextRetryReply()
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let epoch = chat.laneEpoch(work)
    let retry = Task { try await chat.retryJob("example-review", lane: work) }
    try await eventually("the retry reached Work") {
      await workFixture.retryRequests() == ["example-review"]
    }
    try await coordinators.update(
      work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
    await workFixture.releaseRetryReply()
    await #expect(throws: LaneError.interrupted("Work")) { try await retry.value }
    #expect(await workFixture.retryRequests() == ["example-review"], "Nothing sent it again")
    #expect(chat.laneEpoch(work) > epoch)
    try await eventually("work advertised on the new session") {
      chat.snapshots[work]?.workInspectionSupported == true
    }
  }
}

@MainActor @Test func aLaneControlRefusesARemovedOrUnpairedCoordinator() async throws {
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
  await #expect(throws: LaneError.gone("Work")) { try await chat.jobs(lane: work.id) }
  await #expect(throws: LaneError.notPaired("Personal")) {
    try await chat.retryJob("example-review", lane: personal.id)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func controlsReadTheSurvivorsOwnStateAfterARemoveToOne() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    for fixture in [workFixture, personalFixture] { await fixture.advertiseWorkInspection(true) }
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    try await coordinators.remove(coordinators.removal(personal))
    #expect(!chat.multiple)
    #expect(chat.snapshots[work]?.workInspectionSupported == true)
    #expect(chat.snapshots[personal] == nil)
    #expect(!chat.isSaved(personal))
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func anInspectionIsOneCoordinatorWhateverTheOwnerHas() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    await personalFixture.replyToHistory(
      initial: .init(messages: [], pageComplete: true), pages: [:])
    let (_, personal) = try await addWorkAndPersonal(coordinators)
    let inspection = ChatModel(inspecting: exampleConversation)
    await inspection.connectInspection(using: coordinators.chat, lane: personal)
    #expect(inspection.failure == nil)
    #expect(inspection.profiles.map(\.id) == [personal])
    #expect(!inspection.multiple)
    try await eventually("the inspection connected") { inspection.connection == .connected }
    #expect(await inspections(personalFixture) == 1)
    #expect(await inspections(workFixture) == 0)
    await inspection.detach(personal)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func renamingKeepsTheEpoch() async throws {
  try await withTwoFixtures { coordinators, _, _, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let epoch = chat.laneEpoch(work)
    try await coordinators.update(
      work, name: TagName("Office"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
    #expect(chat.laneEpoch(work) == epoch)
    #expect(chat.laneTitle("Jobs and work", for: work) == "Office · Jobs and work")
  }
}
