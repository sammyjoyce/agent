import AppIntents
import CoreSpotlight
import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

private func job(_ id: String, _ title: String, _ state: JobExecutionState) -> ScheduledJobStatus {
  ScheduledJobStatus(
    job: .init(
      cwd: "/workspace/example", id: id,
      model: .init(fast: false, modelId: "example-model", provider: .openai),
      prompt: "An invented prompt.", revision: "example-revision", schedules: [],
      timezone: "America/Los_Angeles", title: title),
    lastRun: JobExecution(
      outputTruncated: false, revision: "example-revision", scheduleId: "example-schedule",
      scheduledAt: 1_700_000_000_000, state: state),
    schedules: [])
}

private func tap(on item: CSSearchableItem) -> NSUserActivity {
  let activity = NSUserActivity(activityType: CSSearchableItemActionType)
  activity.userInfo = [
    CSSearchableItemActivityIdentifier: item.uniqueIdentifier,
    CSSearchQueryString: "An invented search",
  ]
  return activity
}

@MainActor
struct SpotlightTapTests {
  @MainActor private struct Launch {
    let notifications: AppNotifications
    let spotlight: SpotlightFake
    let work: ProfileID
    let personal: ProfileID
    let workPeer: FixtureCoordinator

    var chat: ChatModel { notifications.coordinators.chat }

    func item(for key: SpotlightEntry.Key) async throws -> CSSearchableItem {
      let entry = try #require(await spotlight.entries[key], "Spotlight holds no \(key)")
      if let coordinator = entry.coordinatorEntity {
        return CSSearchableItem(appEntity: coordinator)
      }
      return CSSearchableItem(appEntity: try #require(entry.jobEntity))
    }
  }

  private func withAnIndexedLaunch(_ body: (Launch) async throws -> Void) async throws {
    let workPeer = FixtureCoordinator()
    let personalPeer = FixtureCoordinator()
    let (workListener, workPort) = try await listen(workPeer)
    defer { workListener.cancel() }
    let (personalListener, personalPort) = try await listen(personalPeer)
    defer { personalListener.cancel() }
    for (peer, served) in [
      (workPeer, job("nightly:deps", "Nightly deps", .stopped)),
      (personalPeer, job("weekly:report", "Weekly report", .completed)),
    ] {
      await peer.advertiseWorkInspection(true)
      await peer.serveWork(jobs: [served], conversations: [], pageSize: 10)
    }
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = TestPreferences()
    defaults.set(false, forKey: "notificationsEnabled")
    let spotlight = SpotlightFake()
    let notifications = AppNotifications(
      defaults: defaults, applicationSupport: root, caches: root,
      transport: CoordinatorTransport { address in
        LineConnection(
          connection: NWConnection(
            to: address.port == 4002 ? personalPort : workPort, using: .tcp))
      }, spotlight: spotlight, permission: { false })
    let coordinators = notifications.coordinators
    await coordinators.setActive(true)
    let outcome: Result<Void, any Error>
    do {
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      await coordinators.setActive(true)
      await coordinators.chat.spotlight?.settled()
      coordinators.chat.show(.one(work))
      coordinators.chat.draft = "An invented Work draft"
      try await body(
        Launch(
          notifications: notifications, spotlight: spotlight, work: work, personal: personal,
          workPeer: workPeer))
      outcome = .success(())
    } catch { outcome = .failure(error) }
    await coordinators.setActive(false)
    await workPeer.stop()
    await personalPeer.stop()
    try outcome.get()
  }

  @Test(.timeLimit(.minutes(1)))
  func aTapOnAJobOpensThatJobAndKeepsTheFeedAndTheDraft() async throws {
    try await withAnIndexedLaunch { launch in
      let weeklyReport = ScopedEntityID(profile: launch.personal, item: "weekly:report")
      let destination = launch.chat.destination

      await launch.notifications.open(
        spotlight: tap(on: try await launch.item(for: .job(weeklyReport))))

      #expect(launch.notifications.openRequest?.destination == .job(weeklyReport))
      #expect(launch.chat.scope == .one(launch.work))
      #expect(launch.chat.draft == "An invented Work draft")
      #expect(launch.chat.destination == destination)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aTapOnACoordinatorShowsItsFeedAndKeepsTheDraft() async throws {
    try await withAnIndexedLaunch { launch in
      let destination = launch.chat.destination

      await launch.notifications.open(
        spotlight: tap(on: try await launch.item(for: .coordinator(launch.personal))))

      #expect(launch.chat.scope == .one(launch.personal))
      #expect(launch.notifications.openRequest?.destination == .feed(notice: nil))
      #expect(launch.chat.draft == "An invented Work draft")
      #expect(launch.chat.destination == destination)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aTapOnAJobItsCoordinatorNoLongerListsOpensNothingAndSaysWhy() async throws {
    try await withAnIndexedLaunch { launch in
      let nightlyDeps = ScopedEntityID(profile: launch.work, item: "nightly:deps")
      let stale = try await launch.item(for: .job(nightlyDeps))
      await launch.workPeer.serveWork(
        jobs: [job("docs:sweep", "Docs sweep", .completed)], conversations: [], pageSize: 10)
      launch.chat.show(.one(launch.personal))

      await launch.notifications.open(spotlight: tap(on: stale))

      #expect(
        launch.notifications.openRequest?.destination
          == .feed(notice: "The scheduled job nightly:deps is no longer on Work."))
      #expect(launch.chat.scope == .one(launch.personal))
      #expect(launch.chat.draft == "An invented Work draft")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func aTapOnACoordinatorThatIsNoLongerSavedOpensNothingAndSaysWhy() async throws {
    try await withAnIndexedLaunch { launch in
      let stale = CSSearchableItem(
        appEntity: CoordinatorEntity(id: "\(ProfileID())", name: "Removed"))
      let jobOfIt = CSSearchableItem(
        appEntity: JobEntity(
          indexing: ScopedEntityID(profile: ProfileID(), item: "weekly:report"),
          title: "Weekly report", coordinator: "Removed", state: .completed))

      await launch.notifications.open(spotlight: tap(on: stale))

      #expect(
        launch.notifications.openRequest?.destination
          == .feed(notice: "This coordinator is no longer saved in Beep Boop."))
      #expect(launch.chat.scope == .one(launch.work))

      await launch.notifications.open(spotlight: tap(on: jobOfIt))

      #expect(
        launch.notifications.openRequest?.destination
          == .feed(notice: "This job's coordinator is no longer saved in Beep Boop."))
      #expect(launch.chat.scope == .one(launch.work))
      #expect(launch.chat.draft == "An invented Work draft")
    }
  }
}
