import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private func nightlyDeps(title: String, lastRun: JobExecutionState?) -> ScheduledJobStatus {
  ScheduledJobStatus(
    job: .init(
      cwd: "/workspace/example", id: "nightly:deps",
      model: .init(fast: false, modelId: "example-model", provider: .openai),
      prompt: "Update the invented dependencies.", revision: "example-revision", schedules: [],
      timezone: "America/Los_Angeles", title: title),
    lastRun: lastRun.map {
      JobExecution(
        outputTruncated: false, revision: "example-revision", scheduleId: "example-schedule",
        scheduledAt: 1_700_000_000_000, state: $0)
    },
    schedules: [])
}

private let parked = JobExecutionState.blocked(.init(message: "restart_limit"))

@MainActor private func until(
  _ description: String, within limit: Duration = .seconds(15), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

@MainActor private func connection(_ chat: ChatModel, _ id: ProfileID) -> ConnectionState? {
  chat.snapshots[id]?.connection
}

/// Work serves an interrupted Nightly deps and Personal a healthy one, both paired and connected.
@MainActor private func withJobPeers(
  _ body: (Coordinators, ProfileID, ProfileID, FixtureCoordinator, FixtureCoordinator) async throws
    -> Void
) async throws {
  try await withTwoFixtures { coordinators, workPeer, personalPeer, _ in
    for (peer, title, state) in [
      (workPeer, "Work nightly deps", parked), (personalPeer, "Personal nightly deps", .completed),
    ] {
      await peer.advertiseWorkInspection(true)
      await peer.serveWork(
        jobs: [nightlyDeps(title: title, lastRun: state)], conversations: [], pageSize: 10)
    }
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    try await body(coordinators, work, personal, workPeer, personalPeer)
  }
}

struct SiriJobTests {
  @Test(arguments: ["nightly-deps", "work:nightly:deps", "a"])
  func aScopedIDSurvivesItsStringForm(item: String) throws {
    let id = ScopedEntityID(profile: ProfileID(), item: item)
    let parsed = try #require(ScopedEntityID.entityIdentifier(for: id.entityIdentifierString))
    #expect(parsed == id)
    #expect(parsed.item == item)
  }

  @Test(arguments: [
    "",
    "nightly-deps",
    ":nightly-deps",
    "not-a-uuid:nightly-deps",
    "\(ProfileID())",
    "\(ProfileID()):",
    "nightly:\(ProfileID())",
  ])
  func aMalformedScopedIDFailsToParse(string: String) {
    #expect(ScopedEntityID.entityIdentifier(for: string) == nil)
  }

  @Test func aRunAtTheRestartLimitMapsToInterruptedAndOtherBlocksStayBlocked() {
    #expect(JobRunState(parked) == .interrupted)
    #expect(JobRunState(.blocked(.init(message: "Invented: waiting on approval"))) == .blocked)
    #expect(JobRunState(nil) == .notRun)
  }

  @MainActor @Test func aReadFromTheBackgroundConnectsReturnsTheJobsAndDisconnects() async throws {
    try await withJobPeers { coordinators, work, personal, _, _ in
      let chat = coordinators.chat
      await coordinators.setActive(false)
      try await until("both lanes disconnected") {
        connection(chat, work) == .disconnected && connection(chat, personal) == .disconnected
      }
      let jobs = try await JobQuery.allJobs(in: coordinators)
      #expect(jobs.map(\.title).sorted() == ["Personal nightly deps", "Work nightly deps"])
      #expect(jobs.first { $0.id.profile == work }?.state == .interrupted)
      #expect(jobs.allSatisfy { $0.id.item == "nightly:deps" })
      try await until("both lanes disconnected after the read") {
        connection(chat, work) == .disconnected && connection(chat, personal) == .disconnected
      }
    }
  }

  @MainActor @Test func aReadWhileTheSceneIsActiveLeavesTheLanesConnected() async throws {
    try await withJobPeers { coordinators, work, personal, _, _ in
      let chat = coordinators.chat
      let jobs = try await JobQuery.allJobs(in: coordinators)
      #expect(jobs.count == 2)
      try await Task.sleep(for: .milliseconds(300))
      #expect(connection(chat, work) == .connected)
      #expect(connection(chat, personal) == .connected)
    }
  }

  @MainActor @Test func aSilentPeerDoesNotHideTheOtherPeersJobs() async throws {
    try await withJobPeers { coordinators, work, personal, _, personalPeer in
      let chat = coordinators.chat
      await coordinators.setActive(false)
      try await until("both lanes disconnected") {
        connection(chat, work) == .disconnected && connection(chat, personal) == .disconnected
      }
      await personalPeer.leaveObserveUnanswered(.silent)
      let jobs = try await JobQuery.allJobs(in: coordinators)
      #expect(jobs.map(\.title) == ["Work nightly deps"])
      let id = ScopedEntityID(profile: personal, item: "nightly:deps")
      await #expect(throws: CoordinatorDidNotAnswer.self) {
        try await JobQuery.jobs(identifiedBy: [id], in: coordinators)
      }
    }
  }

  @MainActor @Test func theRetryIntentRetriesOnlyAnInterruptedRun() async throws {
    try await withJobPeers { coordinators, work, personal, workPeer, personalPeer in
      let retried = try await coordinators.retryInterruptedRun(
        ScopedEntityID(profile: work, item: "nightly:deps"), title: "Work nightly deps")
      #expect(retried.job.title == "Work nightly deps")
      #expect(await workPeer.retryRequests() == ["nightly:deps"])
      await #expect(throws: NoInterruptedRun.self) {
        try await coordinators.retryInterruptedRun(
          ScopedEntityID(profile: personal, item: "nightly:deps"), title: "Personal nightly deps")
      }
      #expect(await personalPeer.retryRequests().isEmpty)
    }
  }
}
