import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private func nightlyDeps(
  title: String, lastRun: JobExecutionState?, scheduleError: String? = nil
) -> ScheduledJobStatus {
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
    schedules: scheduleError.map { [.init(error: $0, scheduleId: "example-schedule")] } ?? [])
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

@MainActor private func background(_ coordinators: Coordinators) async throws {
  let chat = coordinators.chat
  await coordinators.setActive(false)
  try await until("every lane disconnected") {
    chat.snapshots.values.allSatisfy { $0.connection == .disconnected }
  }
}

/// The text Siri and Shortcuts show for `error`.
private func shown(_ error: (any Error)?) -> String? {
  if let error = error as? any CustomLocalizedStringResourceConvertible {
    return String(localized: error.localizedStringResource)
  }
  return error?.localizedDescription
}

private func jobReads(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .jobs = $0 { true } else { false } }.count
}

private let updateTheCoordinator =
  "Update the coordinator to inspect scheduled jobs and saved work."

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
    let state = { (lastRun: JobExecutionState?) in
      nightlyDeps(title: "Nightly deps", lastRun: lastRun).runState
    }
    #expect(state(parked) == .interrupted)
    #expect(state(.blocked(.init(message: "Invented: waiting on approval"))) == .blocked)
    #expect(state(nil) == .notRun)
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
      // Work has to connect inside the wait that Personal runs out, on a busy machine too.
      let jobs = try await JobQuery.allJobs(in: coordinators, within: .seconds(3))
      #expect(jobs.map(\.title) == ["Work nightly deps"])
      let id = ScopedEntityID(profile: personal, item: "nightly:deps")
      await #expect(throws: CoordinatorDidNotAnswer.self) {
        try await JobQuery.jobs(identifiedBy: [id], in: coordinators, within: .milliseconds(300))
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

  /// The runtime reports a job parked at the restart limit on its schedule when no run of the
  /// job is retained. The retry intent retries that job, so its state reads Interrupted.
  @Test func aJobParkedOnItsScheduleWithNoLastRunReadsInterrupted() {
    let parkedOnSchedule = nightlyDeps(
      title: "Nightly deps", lastRun: nil,
      scheduleError:
        "Job model generation is parked after repeated interrupted restarts; retry the interrupted run"
    )
    #expect(parkedOnSchedule.canRetryInterruptedRun)
    #expect(JobEntity(parkedOnSchedule, on: ProfileID(), coordinator: "Work").state == .interrupted)
  }

  @MainActor @Test func anOutdatedCoordinatorsRejectionKeepsItsMessageUnderItsName() async throws {
    try await withJobPeers { coordinators, work, _, workPeer, personalPeer in
      await workPeer.advertiseWorkInspection(false)
      try await background(coordinators)
      let jobs = try await JobQuery.allJobs(in: coordinators)
      #expect(jobs.map(\.title) == ["Personal nightly deps"], "Personal still answers")
      let id = ScopedEntityID(profile: work, item: "nightly:deps")
      let picked = await #expect(throws: (any Error).self) {
        try await JobQuery.jobs(identifiedBy: [id], in: coordinators)
      }
      #expect(shown(picked) == "Work: \(updateTheCoordinator)")
      await personalPeer.advertiseWorkInspection(false)
      let listed = await #expect(throws: (any Error).self) {
        try await JobQuery.allJobs(in: coordinators)
      }
      #expect(shown(listed) == "Work: \(updateTheCoordinator)", "No coordinator returned jobs")
      #expect(await jobReads(workPeer) == 0, "An outdated coordinator is never asked")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aCoordinatorsRejectionIsReportedBeforeAnotherOnesSilence() async throws {
    try await withJobPeers { coordinators, _, _, workPeer, personalPeer in
      await personalPeer.advertiseWorkInspection(false)
      try await background(coordinators)
      await workPeer.leaveObserveUnanswered(.silent)
      // Personal has to connect inside the wait that Work runs out, on a busy machine too.
      let refused = await #expect(throws: (any Error).self) {
        try await JobQuery.allJobs(in: coordinators, within: .seconds(3))
      }
      #expect(shown(refused) == "Personal: \(updateTheCoordinator)")
      await personalPeer.leaveObserveUnanswered(.silent)
      let silent = await #expect(throws: CoordinatorDidNotAnswer.self) {
        try await JobQuery.allJobs(in: coordinators, within: .milliseconds(300))
      }
      #expect(shown(silent) == "Work did not answer. Check that it is running and reachable.")
    }
  }

  /// The retry is on the wire when the intent is cancelled. The session cuts the request, and the
  /// intent reports the cancellation, not a coordinator that went away.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRetryCancelledWhileItsReplyIsHeldIsCancelledAndSentOnce() async throws {
    try await withJobPeers { coordinators, work, _, workPeer, _ in
      let chat = coordinators.chat
      try await background(coordinators)
      await workPeer.holdNextRetryReply()
      let retrying = Task { @MainActor in
        try await coordinators.retryInterruptedRun(
          ScopedEntityID(profile: work, item: "nightly:deps"), title: "Work nightly deps")
      }
      try await until("the retry reached Work") { await workPeer.retryRequests().count == 1 }
      retrying.cancel()
      await #expect(throws: CancellationError.self) { try await retrying.value }
      #expect(!chat.demand.leased(work), "The lease was dropped")
      await workPeer.releaseRetryReply()
      #expect(await workPeer.retryRequests() == ["nightly:deps"], "Nothing sent it again")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aCancelledQueryIsCancelledAndNamesNoCoordinator() async throws {
    try await withJobPeers { coordinators, work, personal, workPeer, personalPeer in
      let chat = coordinators.chat
      try await background(coordinators)
      for peer in [workPeer, personalPeer] { await peer.leaveObserveUnanswered(.silent) }
      let reading = Task { @MainActor in try await JobQuery.allJobs(in: coordinators) }
      try await until("a lease held") { chat.demand.leased(work) || chat.demand.leased(personal) }
      reading.cancel()
      await #expect(throws: CancellationError.self) { try await reading.value }
      #expect(!chat.demand.leased(work) && !chat.demand.leased(personal))
    }
  }

  /// Work is saved first and is still connecting when the query starts. Personal is read
  /// meanwhile, and the jobs come back in saved order.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aCoordinatorStillConnectingDoesNotDelayTheNextOnesRead() async throws {
    try await withJobPeers { coordinators, _, _, workPeer, personalPeer in
      try await background(coordinators)
      await workPeer.holdSnapshot()
      let reading = Task { @MainActor in
        try await JobQuery.allJobs(in: coordinators, within: .seconds(40))
      }
      let deadline = ContinuousClock.now + .seconds(20)
      while await jobReads(personalPeer) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      let readMeanwhile = await jobReads(personalPeer)
      await workPeer.releaseSnapshot()
      let jobs = try await reading.value
      #expect(readMeanwhile == 1, "Personal was read while Work was still connecting")
      #expect(jobs.map(\.title) == ["Work nightly deps", "Personal nightly deps"])
    }
  }
}
