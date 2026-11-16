import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// `@Dependency`'s setter writes one process-wide slot, and tests run in parallel. So these call the
/// functions that the query and the intent call, and never build either with a dependency.
@MainActor
struct SiriCoordinatorEntityTests {
  @MainActor
  private final class SavedFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "siri-coordinators-\(UUID())"
    let defaults: UserDefaults
    let profiles: [CoordinatorProfile]
    let notifications: AppNotifications

    init(
      names: [String] = ["Work", "Personal", "Home"], transport: CoordinatorTransport = .tailnet,
      permission: @escaping @MainActor () async throws -> Bool = AppNotifications.alertPermission
    ) throws {
      defaults = try #require(UserDefaults(suiteName: suite))
      profiles = try names.enumerated().map { index, name in
        var profile = CoordinatorProfile(
          name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.\(index + 2)"))
        profile.pin = CoordinatorID(UUID())
        return profile
      }
      try writePrivately(
        JSONEncoder().encode(Coordinators.SavedProfiles(profiles: profiles)),
        to: root.appending(path: "Agent/profiles.json"))
      notifications = AppNotifications(
        defaults: defaults, applicationSupport: root, caches: root, transport: transport,
        permission: permission)
    }

    func saved() -> [CoordinatorEntity] { CoordinatorEntity.saved(in: notifications.coordinators) }

    func saved(matching identifiers: [String]) -> [CoordinatorEntity] {
      CoordinatorEntity.saved(in: notifications.coordinators, matching: identifiers)
    }

    func entity(_ index: Int) -> CoordinatorEntity {
      CoordinatorEntity(id: "\(profiles[index].id)", name: "\(profiles[index].name)")
    }

    func clean() {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
  }

  private func named(_ entities: [CoordinatorEntity]) -> [String] { entities.map(\.name) }

  @Test func theQueryReturnsEachSavedCoordinatorOnceInSavedOrder() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let entities = fixture.saved()
    #expect(entities.map(\.id) == fixture.profiles.map { "\($0.id)" })
    #expect(named(entities) == ["Work", "Personal", "Home"])
    #expect(entities.map { String(localized: $0.displayRepresentation.title) } == named(entities))
  }

  @Test func aRenameShowsTheNewName() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let personal = fixture.profiles[1]
    try await fixture.notifications.coordinators.update(
      personal.id, name: TagName("Family"), address: personal.address)
    let entities = fixture.saved()
    #expect(named(entities) == ["Work", "Family", "Home"])
    let found = fixture.saved(matching: ["\(personal.id)"])
    #expect(named(found) == ["Family"])
  }

  @Test func aRemovedCoordinatorIsAbsent() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let coordinators = fixture.notifications.coordinators
    let home = fixture.profiles[2].id
    try await coordinators.remove(coordinators.removal(home))
    #expect(named(fixture.saved()) == ["Work", "Personal"])
    #expect(fixture.saved(matching: ["\(home)"]).isEmpty)
  }

  @Test func entitiesForIdentifiersIgnoresAnUnknownID() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let found = fixture.saved(matching: [
      "\(ProfileID())", "not-a-profile", "\(fixture.profiles[0].id)",
    ])
    #expect(found.map(\.id) == ["\(fixture.profiles[0].id)"])
  }

  #if DEBUG
    /// Counts the dials of the coordinators it is the transport of, and connects none.
    private actor DialLog {
      private(set) var count = 0
      private func dialed() { count += 1 }
      nonisolated var transport: CoordinatorTransport {
        CoordinatorTransport { _ in
          await self.dialed()
          throw ConnectionError.timedOut
        }
      }
    }

    /// No other test reads `AppNotifications.interactionLaunch`, so this test can set it while
    /// tests run in parallel. The app delegate's Work is paired, so a lease on it would dial, and
    /// no dial means no lease either.
    @Test func intentsReadTheInteractionFixtureAndOnlyAPlainLaunchAsksForAlerts() async throws {
      let dials = DialLog()
      let delegate = try SavedFixture(names: ["Work"], transport: dials.transport)
      let fixture = try SavedFixture(names: ["Personal"])
      defer {
        AppNotifications.interactionLaunch = nil
        delegate.clean()
        fixture.clean()
      }
      AppNotifications.interactionLaunch = .plain
      #expect(try delegate.notifications.intentCoordinators.savedNames == ["Work"])
      AppNotifications.interactionLaunch = .fixture(fixture.notifications)
      #expect(try delegate.notifications.intentCoordinators.savedNames == ["Personal"])
      let work = delegate.profiles[0].id
      let nightlyDeps = JobEntity(
        ScheduledJobStatus(
          job: .init(
            cwd: "/workspace/example", id: "nightly:deps",
            model: .init(fast: false, modelId: "example-model", provider: .openai),
            prompt: "Update the invented dependencies.", revision: "example-revision",
            schedules: [], timezone: "America/Los_Angeles", title: "Nightly deps"),
          schedules: []), on: work, coordinator: "Work")
      let refusals: [AppNotifications.InteractionLaunch?] = [
        nil, .unavailable(reason: "This launch erased its interaction fixture."),
      ]
      for launch in refusals {
        AppNotifications.interactionLaunch = launch
        do {
          let read = try delegate.notifications.intentCoordinators
          Issue.record("\(String(describing: launch)) read \(read.savedNames)")
        } catch {
          #expect("\(error)".contains("interaction fixture"), "\(error)")
        }
        let app = delegate.notifications
        let requests: [(what: String, ask: () async throws -> Void)] = [
          ("every job", { _ = try await JobQuery.allJobs(for: app) }),
          ("one job", { _ = try await JobQuery.jobs(identifiedBy: [nightlyDeps.id], for: app) }),
          ("a retry", { _ = try await RetryInterruptedRunIntent.retry(nightlyDeps, for: app) }),
        ]
        for (what, ask) in requests {
          await #expect(
            throws: AppNotifications.InteractionFixtureUnavailable.self,
            "\(what) under \(String(describing: launch))"
          ) { try await ask() }
        }
      }
      #expect(await dials.count == 0, "A refused intent reached the app's own Work")
      await #expect(throws: LaneError.self) {
        try await delegate.notifications.coordinators.withConnection(
          to: work, within: .milliseconds(300)
        ) {}
      }
      #expect(await dials.count > 0, "A lease on Work dials it, and the log counts the dial")

      var asked = 0
      let launching = try SavedFixture(names: ["Work"]) {
        asked += 1
        return false
      }
      defer { launching.clean() }
      let idle: [AppNotifications.InteractionLaunch?] = [
        .fixture(fixture.notifications), nil,
        .unavailable(reason: "This launch erased its interaction fixture."),
      ]
      for launch in idle {
        AppNotifications.interactionLaunch = launch
        await launching.notifications.startRegistration()
      }
      #expect(asked == 0, "A launch that the app delegate does not act for asked for alerts")
      AppNotifications.interactionLaunch = .plain
      await launching.notifications.startRegistration()
      #expect(asked == 1)
    }
  #endif

  @Test func openCoordinatorRoutesLikeAnAlertTapAndKeepsTheDraft() async throws {
    let tapped = try SavedFixture()
    defer { tapped.clean() }
    tapped.notifications.coordinators.chat.show(.one(tapped.profiles[0].id))
    tapped.notifications.open(.named(tapped.profiles[1].id))
    let tapScope = tapped.notifications.coordinators.chat.scope
    let tapDestination = try #require(tapped.notifications.openRequest).destination

    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let chat = fixture.notifications.coordinators.chat
    chat.show(.one(fixture.profiles[0].id))
    chat.draft = "An invented Work draft"
    let destination = chat.destination
    fixture.notifications.open(fixture.entity(1))
    #expect(chat.scope == .one(fixture.profiles[1].id))
    #expect(tapScope == .one(tapped.profiles[1].id))
    #expect(try #require(fixture.notifications.openRequest).destination == tapDestination)
    #expect(chat.draft == "An invented Work draft")
    #expect(chat.destination == destination)
  }
}
