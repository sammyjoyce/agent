import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

private func nightlyDeps(
  title: String, lastRun: JobExecutionState?, scheduleError: String? = nil,
  id: String = "nightly:deps"
) -> ScheduledJobStatus {
  ScheduledJobStatus(
    job: .init(
      cwd: "/workspace/example", id: id,
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

private func serveNightlyDeps(work: FixtureCoordinator, personal: FixtureCoordinator) async {
  for (peer, title, state) in [
    (work, "Work nightly deps", parked), (personal, "Personal nightly deps", .completed),
  ] {
    await peer.advertiseWorkInspection(true)
    await peer.serveWork(
      jobs: [nightlyDeps(title: title, lastRun: state)], conversations: [], pageSize: 10)
  }
}

/// Work serves an interrupted Nightly deps and Personal a healthy one, both paired and connected.
@MainActor private func withJobPeers(
  registration: NotificationRegistration? = nil, holdingWork gate: DialGate? = nil,
  spotlight: SpotlightFake? = nil,
  _ body: (Coordinators, ProfileID, ProfileID, FixtureCoordinator, FixtureCoordinator) async throws
    -> Void
) async throws {
  try await withTwoFixtures(registration: registration, holdingWork: gate, spotlight: spotlight) {
    coordinators, workPeer, personalPeer, _ in
    await serveNightlyDeps(work: workPeer, personal: personalPeer)
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    try await body(coordinators, work, personal, workPeer, personalPeer)
  }
}

@MainActor private func withRelaunches(
  spotlight: SpotlightFake,
  _ body: (
    _ launch: @MainActor () -> Coordinators, FixtureCoordinator, FixtureCoordinator
  ) async throws -> Void
) async throws {
  let workPeer = FixtureCoordinator()
  let personalPeer = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workPeer)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalPeer)
  defer { personalListener.cancel() }
  await serveNightlyDeps(work: workPeer, personal: personalPeer)
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "relaunch-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let launch: @MainActor () -> Coordinators = {
    Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        LineConnection(
          connection: NWConnection(
            to: address.port == 4002 ? personalPort : workPort, using: .tcp))
      }, spotlight: spotlight)
  }
  let outcome: Result<Void, any Error>
  do {
    try await body(launch, workPeer, personalPeer)
    outcome = .success(())
  } catch { outcome = .failure(error) }
  await workPeer.stop()
  await personalPeer.stop()
  try outcome.get()
}

@MainActor private func activate(_ coordinators: Coordinators) async {
  await coordinators.setActive(true)
  await coordinators.chat.spotlight?.settled()
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
      try await background(coordinators)
      let jobs = try await JobQuery.allJobs(in: coordinators)
      let interrupted = try #require(jobs.first { $0.title == "Work nightly deps" })
      let healthy = try #require(jobs.first { $0.title == "Personal nightly deps" })
      let said = try await RetryInterruptedRunIntent.retry(interrupted, in: coordinators)
      #expect(String(localized: said) == "Retrying Work nightly deps on Work.")
      #expect(await workPeer.retryRequests() == ["nightly:deps"])
      let refused = await #expect(throws: NoInterruptedRun.self) {
        try await RetryInterruptedRunIntent.retry(healthy, in: coordinators)
      }
      #expect(shown(refused) == "Personal nightly deps has no interrupted run to retry.")
      #expect(await personalPeer.retryRequests().isEmpty)
      #expect(await workPeer.retryRequests() == ["nightly:deps"], "Nothing sent it again")
      let chat = coordinators.chat
      try await until("both lanes disconnected after the retries") {
        connection(chat, work) == .disconnected && connection(chat, personal) == .disconnected
      }
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

  @Test func withNoJobToShowARefusalIsThrownAndASilenceOnlyWhenNoOneAnswered() throws {
    let job = JobEntity(
      nightlyDeps(title: "Nightly deps", lastRun: .completed), on: ProfileID(),
      coordinator: "Personal")
    let silence = JobRead.failure(CoordinatorDidNotAnswer(name: "Work"))
    let refusal = JobRead.failure(CoordinatorRefused(name: "Work", message: updateTheCoordinator))
    #expect(try JobQuery.jobs(in: []).isEmpty)
    #expect(try JobQuery.jobs(in: [silence, .success([job])]).map(\.title) == ["Nightly deps"])
    #expect(try JobQuery.jobs(in: [refusal, .success([job])]).map(\.title) == ["Nightly deps"])
    #expect(try JobQuery.jobs(in: [silence, .success([])]).isEmpty, "Someone answered")
    #expect(throws: CoordinatorRefused.self) { try JobQuery.jobs(in: [refusal, .success([])]) }
    #expect(throws: CoordinatorRefused.self) { try JobQuery.jobs(in: [silence, refusal]) }
    #expect(throws: CoordinatorDidNotAnswer.self) { try JobQuery.jobs(in: [silence, silence]) }
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
      await personalPeer.advertiseWorkInspection(true)
      await personalPeer.serveWork(jobs: [], conversations: [], pageSize: 10)
      let hidden = await #expect(throws: (any Error).self) {
        try await JobQuery.allJobs(in: coordinators)
      }
      #expect(
        shown(hidden) == "Work: \(updateTheCoordinator)",
        "Personal's empty list does not hide what Work said")
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

  /// Personal's outbox cannot be read when the system starts the app for the query. Its failure is
  /// not a silence, so it is reported under Personal's name, at once, and ahead of Work's silence.
  @MainActor @Test(.timeLimit(.minutes(3)))
  func anUnreadableOutboxIsReportedUnderItsCoordinatorsNameAheadOfASilence() async throws {
    try await withBackgroundLaunch { coordinators, _, personal, workPeer, personalPeer in
      for (peer, title) in [
        (workPeer, "Work nightly deps"), (personalPeer, "Personal nightly deps"),
      ] {
        await peer.advertiseWorkInspection(true)
        await peer.serveWork(
          jobs: [nightlyDeps(title: title, lastRun: parked)], conversations: [], pageSize: 10)
      }
      let outbox = try #require(
        coordinators.chat.lanes.first { $0.id == personal }?.session
      ).outboxURL
      try SpoiledOutbox.unreadable.write(to: outbox)
      let started = ContinuousClock.now
      let jobs = try await JobQuery.allJobs(in: coordinators, within: .seconds(30))
      #expect(jobs.map(\.title) == ["Work nightly deps"], "Work still answers")
      #expect(ContinuousClock.now - started < .seconds(10), "Personal did not use up its limit")
      let id = ScopedEntityID(profile: personal, item: "nightly:deps")
      let picked = await #expect(throws: (any Error).self) {
        try await JobQuery.jobs(identifiedBy: [id], in: coordinators, within: .seconds(30))
      }
      #expect(picked is any CustomLocalizedStringResourceConvertible, "Siri can say it")
      #expect(!(picked is CoordinatorDidNotAnswer))
      #expect(shown(picked) == "Personal: \(outboxCouldNotBeRead)")
      await workPeer.leaveObserveUnanswered(.silent)
      let listed = await #expect(throws: (any Error).self) {
        try await JobQuery.allJobs(in: coordinators, within: .milliseconds(300))
      }
      #expect(shown(listed) == "Personal: \(outboxCouldNotBeRead)", "Ahead of Work's silence")
      #expect(await jobReads(personalPeer) == 0, "Personal was never asked")
    }
  }

  /// The retry intent maps no error, so it reports the lease's own.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRetryOnACoordinatorWhoseOutboxCannotBeReadSaysSoAndSendsNothing() async throws {
    try await withBackgroundLaunch { coordinators, _, personal, _, personalPeer in
      let outbox = try #require(
        coordinators.chat.lanes.first { $0.id == personal }?.session
      ).outboxURL
      try SpoiledOutbox.undecodable.write(to: outbox)
      let job = JobEntity(
        nightlyDeps(title: "Personal nightly deps", lastRun: parked), on: personal,
        coordinator: "Personal")
      let refused = await #expect(throws: (any Error).self) {
        try await RetryInterruptedRunIntent.retry(job, in: coordinators)
      }
      #expect(refused?.localizedDescription == "Personal: \(outboxCouldNotBeRead)")
      #expect(await personalPeer.retryRequests().isEmpty)
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aJobWhoseCoordinatorIsNoLongerSavedSaysSo() async throws {
    try await withJobPeers { coordinators, work, _, workPeer, _ in
      try await coordinators.remove(coordinators.removal(work))
      let asked = await jobReads(workPeer)
      for id in [work, ProfileID()].map({ ScopedEntityID(profile: $0, item: "nightly:deps") }) {
        let refused = await #expect(throws: JobUnavailable.self, "\(id)") {
          try await JobQuery.jobs(identifiedBy: [id], in: coordinators)
        }
        #expect(refused == .coordinatorNotSaved)
        #expect(shown(refused) == "This job's coordinator is no longer saved in Beep Boop.")
      }
      #expect(await jobReads(workPeer) == asked, "A coordinator no longer saved is never asked")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aJobItsCoordinatorNoLongerHasSaysSoUnderItsName() async throws {
    try await withJobPeers { coordinators, work, _, workPeer, _ in
      await workPeer.serveWork(
        jobs: [nightlyDeps(title: "Docs sweep", lastRun: .completed, id: "docs:sweep")],
        conversations: [], pageSize: 10)
      let id = ScopedEntityID(profile: work, item: "nightly:deps")
      let refused = await #expect(throws: JobUnavailable.self) {
        try await JobQuery.jobs(identifiedBy: [id], in: coordinators)
      }
      #expect(refused == .notOnCoordinator(job: "nightly:deps", coordinator: "Work"))
      #expect(shown(refused) == "The scheduled job nightly:deps is no longer on Work.")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRenamedCoordinatorAndARenamedJobStillResolve() async throws {
    try await withJobPeers { coordinators, work, _, workPeer, _ in
      let address = try #require(coordinators.profiles.first { $0.id == work }).address
      try await coordinators.update(work, name: TagName("Office"), address: address)
      await workPeer.serveWork(
        jobs: [nightlyDeps(title: "Nightly deps v2", lastRun: parked)], conversations: [],
        pageSize: 10)
      let id = ScopedEntityID(profile: work, item: "nightly:deps")
      let found = try await JobQuery.jobs(identifiedBy: [id], in: coordinators)
      #expect(found.map(\.id) == [id])
      #expect(found.map(\.coordinator) == ["Office"])
      #expect(found.map(\.title) == ["Nightly deps v2"])
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aCoordinatorsSilenceIsReportedBeforeAMissingJob() async throws {
    try await withJobPeers { coordinators, work, personal, workPeer, personalPeer in
      try await background(coordinators)
      await workPeer.serveWork(
        jobs: [nightlyDeps(title: "Docs sweep", lastRun: .completed, id: "docs:sweep")],
        conversations: [], pageSize: 10)
      await personalPeer.leaveObserveUnanswered(.silent)
      let ids = [work, personal].map { ScopedEntityID(profile: $0, item: "nightly:deps") }
      let refused = await #expect(throws: CoordinatorDidNotAnswer.self) {
        try await JobQuery.jobs(identifiedBy: ids, in: coordinators, within: .seconds(3))
      }
      #expect(shown(refused) == "Personal did not answer. Check that it is running and reachable.")
      #expect(await jobReads(workPeer) == 1, "Work answered without the job")
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

  /// Work has answered and Personal is still silent when the query is cancelled. The query throws
  /// the cancellation instead of returning Work's jobs as if Personal had only been silent.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aQueryCancelledAfterOneCoordinatorAnsweredIsStillCancelled() async throws {
    try await withJobPeers { coordinators, work, personal, workPeer, personalPeer in
      let chat = coordinators.chat
      try await background(coordinators)
      await personalPeer.leaveObserveUnanswered(.silent)
      // Personal's lease has to outlast Work's read, on a busy machine too.
      let reading = Task { @MainActor in
        try await JobQuery.allJobs(in: coordinators, within: .seconds(40))
      }
      try await until("Work's read finished") {
        await jobReads(workPeer) == 1 && !chat.demand.leased(work)
      }
      #expect(chat.demand.leased(personal), "Personal's lease still waits")
      reading.cancel()
      await #expect(throws: CancellationError.self) { try await reading.value }
      #expect(!chat.demand.leased(personal))
    }
  }

  /// Work is saved first and is still connecting when the query starts. Personal is read
  /// meanwhile, and the jobs come back in saved order.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func anActivationIndexesEveryPairedCoordinatorsJobs() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, work, personal, _, _ in
      try await background(coordinators)
      await activate(coordinators)
      let workJob = ScopedEntityID(profile: work, item: "nightly:deps")
      let personalJob = ScopedEntityID(profile: personal, item: "nightly:deps")
      #expect(
        await spotlight.jobs == [
          workJob: .init(title: "Work nightly deps", coordinator: "Work", state: .interrupted),
          personalJob: .init(
            title: "Personal nightly deps", coordinator: "Personal", state: .completed),
        ])
      #expect(await spotlight.coordinators == [work: "Work", personal: "Personal"])
      let indexed = try #require(await spotlight.entries[.job(workJob)]?.jobEntity)
      let opened = try await JobQuery.jobs(identifiedBy: [indexed.id], in: coordinators)
      #expect(opened.map(\.title) == ["Work nightly deps"], "Open Job resolves the result")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func theIndexedJobHoldsOnlyItsTitleCoordinatorAndState() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, work, _, _, _ in
      await activate(coordinators)
      let id = ScopedEntityID(profile: work, item: "nightly:deps")
      let job = try #require(await spotlight.entries[.job(id)]?.jobEntity)
      #expect(job.id == id)
      #expect(job.title == "Work nightly deps")
      #expect(job.coordinator == "Work")
      #expect(job.state == .interrupted)
      #expect(job.schedule.isEmpty)
      #expect(job.lastRun == nil, "Work's last run has a time, and the index leaves it out")
      #expect(job.nextRun == nil)
      #expect(job.summary == "Work nightly deps, Work, Interrupted")
      let attributes = job.attributeSet
      #expect(attributes.title == "Work nightly deps")
      #expect(attributes.displayName == "Work nightly deps")
      #expect(attributes.contentDescription == "Work, Interrupted")
      #expect(attributes.keywords == nil)
      #expect(attributes.textContent == nil)
      #expect(attributes.alternateNames == nil)
      #expect(attributes.subject == nil)
      #expect(attributes.comment == nil)
      let coordinator = try #require(await spotlight.entries[.coordinator(work)]?.coordinatorEntity)
      #expect(coordinator.id == "\(work)")
      #expect(coordinator.attributeSet.title == "Work")
      #expect(coordinator.attributeSet.displayName == "Work")
      #expect(coordinator.attributeSet.contentDescription == nil)
      #expect(coordinator.attributeSet.keywords == nil)
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRenameRewritesTheCoordinatorsJobsWithoutReadingThem() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, work, personal, workPeer, _ in
      await activate(coordinators)
      let reads = await jobReads(workPeer)
      let address = try #require(coordinators.profiles.first { $0.id == work }).address
      try await coordinators.update(work, name: TagName("Office"), address: address)
      await coordinators.chat.spotlight?.settled()
      #expect(await spotlight.coordinators == [work: "Office", personal: "Personal"])
      let workJob = ScopedEntityID(profile: work, item: "nightly:deps")
      #expect(
        await spotlight.jobs[workJob]
          == .init(title: "Work nightly deps", coordinator: "Office", state: .interrupted))
      #expect(await jobReads(workPeer) == reads, "The rename read no jobs")
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aJobItsCoordinatorNoLongerListsLeavesTheIndexWhenResolved() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, work, _, workPeer, _ in
      await activate(coordinators)
      let gone = ScopedEntityID(profile: work, item: "nightly:deps")
      try #require(await spotlight.jobs[gone] != nil)
      await workPeer.serveWork(
        jobs: [nightlyDeps(title: "Docs sweep", lastRun: .completed, id: "docs:sweep")],
        conversations: [], pageSize: 10)
      let refused = await #expect(throws: JobUnavailable.self) {
        try await JobQuery.jobs(identifiedBy: [gone], in: coordinators)
      }
      #expect(refused == .notOnCoordinator(job: "nightly:deps", coordinator: "Work"))
      await coordinators.chat.spotlight?.settled()
      let jobs = await spotlight.jobs
      #expect(jobs[gone] == nil)
      #expect(
        jobs[ScopedEntityID(profile: work, item: "docs:sweep")]
          == .init(title: "Docs sweep", coordinator: "Work", state: .completed))
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func removingACoordinatorRemovesItsJobs() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, work, personal, _, _ in
      await activate(coordinators)
      try #require(await spotlight.jobs.count == 2)
      try await coordinators.remove(coordinators.removal(work))
      await coordinators.chat.spotlight?.settled()
      #expect(await spotlight.keys(of: work).isEmpty)
      #expect(await spotlight.coordinators == [personal: "Personal"])
      #expect(
        await spotlight.jobs == [
          ScopedEntityID(profile: personal, item: "nightly:deps"): .init(
            title: "Personal nightly deps", coordinator: "Personal", state: .completed)
        ])
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aJobListThatArrivesAfterRemoveBeganPutsNothingBack() async throws {
    let spotlight = SpotlightFake()
    let registration = NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    let gate = DialGate()
    try await withJobPeers(registration: registration, holdingWork: gate, spotlight: spotlight) {
      coordinators, work, personal, workPeer, _ in
      let chat = coordinators.chat
      try await until("Work's alert channel linked") { registration.status(work).configured }
      await activate(coordinators)
      try #require(await spotlight.jobs.count == 2)
      await workPeer.holdNextJobsReply()
      let reads = await jobReads(workPeer)
      let reading = Task { @MainActor in try await chat.jobs(lane: work) }
      try await until("Work received the read") { await jobReads(workPeer) == reads + 1 }
      await gate.arm()
      let removal = Task { @MainActor in
        try await coordinators.remove(coordinators.removal(work))
      }
      try await until("Remove waiting on Work's alert withdrawal") { await gate.waiting }
      await chat.spotlight?.settled()
      #expect(await spotlight.keys(of: work).isEmpty, "Work left the index once Remove began")
      await workPeer.releaseJobsReply()
      let read = try await reading.value
      guard case .list(let listing) = read else {
        Issue.record("Work answered \(read)")
        return
      }
      #expect(listing.jobs.map(\.job.title) == ["Work nightly deps"], "The list landed")
      await chat.spotlight?.settled()
      #expect(await spotlight.keys(of: work).isEmpty, "The late list put nothing back")
      await gate.open()
      try await removal.value
      await chat.spotlight?.settled()
      #expect(await spotlight.coordinators == [personal: "Personal"])
      #expect(
        Array(await spotlight.jobs.keys) == [
          ScopedEntityID(profile: personal, item: "nightly:deps")
        ])
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func aRelaunchIndexesJobsAgainUnderTheCurrentName() async throws {
    let spotlight = SpotlightFake()
    try await withRelaunches(spotlight: spotlight) { launch, _, _ in
      let first = launch()
      await first.setActive(true)
      let (work, personal) = try await addWorkAndPersonal(first)
      await activate(first)
      try #require(await spotlight.jobs.count == 2)
      let address = try #require(first.profiles.first { $0.id == work }).address
      await spotlight.holdNextWrite()
      try await first.update(work, name: TagName("Office"), address: address)
      await spotlight.abandonHeldWrite()
      await first.setActive(false)
      #expect(await spotlight.coordinators[work] == "Work", "The stop left the old name")
      let second = launch()
      await activate(second)
      await second.setActive(false)
      #expect(await spotlight.coordinators == [work: "Office", personal: "Personal"])
      #expect(
        await spotlight.jobs == [
          ScopedEntityID(profile: work, item: "nightly:deps"): .init(
            title: "Work nightly deps", coordinator: "Office", state: .interrupted),
          ScopedEntityID(profile: personal, item: "nightly:deps"): .init(
            title: "Personal nightly deps", coordinator: "Personal", state: .completed),
        ])
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func anInspectionModelNeverIndexes() async throws {
    let spotlight = SpotlightFake()
    try await withJobPeers(spotlight: spotlight) { coordinators, _, personal, _, personalPeer in
      await personalPeer.replyToHistory(
        initial: .init(messages: [], pageComplete: true), pages: [:])
      await activate(coordinators)
      let indexed = await spotlight.entries
      try #require(indexed.count == 4)
      let inspection = ChatModel(
        inspecting: SavedConversation(
          conversationId: "example-conversation", taskId: "example-task",
          title: "Example review"))
      await inspection.connectInspection(using: coordinators.chat, lane: personal)
      #expect(inspection.failure == nil)
      #expect(inspection.profiles.map(\.id) == [personal])
      await coordinators.chat.spotlight?.settled()
      #expect(await spotlight.entries == indexed)
      await inspection.detach(personal)
    }
  }

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
