import AppIntents
import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

@MainActor
struct SiriOnscreenEntityTests {
  private func profile(_ name: String, _ index: Int) throws -> CoordinatorProfile {
    var profile = CoordinatorProfile(
      name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.\(index + 2)"))
    profile.pin = CoordinatorID(UUID())
    return profile
  }

  @Test func theFeedClaimsOnlyTheOneCoordinatorItShows() throws {
    let work = try profile("Work", 0)
    let personal = try profile("Personal", 1)
    let feed = ChatModel()
    feed.profiles = [work, personal]
    #expect(OnscreenEntity.feed(of: feed) == nil, "All with two saved shows both")
    feed.show(.one(personal.id))
    #expect(OnscreenEntity.feed(of: feed) == .coordinator(personal.id))

    let alone = ChatModel()
    alone.profiles = [work]
    #expect(alone.scope == .all)
    #expect(OnscreenEntity.feed(of: alone) == .coordinator(work.id), "The only one saved")

    let inspection = ChatModel(
      inspecting: SavedConversation(
        conversationId: "example-conversation", taskId: "example-task", title: "Example review"))
    inspection.profiles = [work]
    #expect(OnscreenEntity.feed(of: inspection) == nil, "An inspection is not Work's feed")
  }

  @Test func anOnscreenIdentifierIsTheOneTheQueryReturns() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "siri-onscreen-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
      defaults.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: root)
    }
    let work = try profile("Work", 0)
    try writePrivately(
      JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [work])),
      to: root.appending(path: "Agent/profiles.json"))
    let notifications = AppNotifications(
      defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet)
    let saved = try #require(CoordinatorEntity.saved(in: notifications.coordinators).first)
    #expect(OnscreenEntity.coordinator(work.id).identifier == EntityIdentifier(for: saved))

    let job = JobEntity(
      ScheduledJobStatus(
        job: .init(
          cwd: "/workspace/example", id: "nightly:deps",
          model: .init(fast: false, modelId: "example-model", provider: .openai),
          prompt: "Update the invented dependencies.", revision: "example-revision",
          schedules: [], timezone: "America/Los_Angeles", title: "Nightly deps"),
        schedules: []), on: work.id, coordinator: "Work")
    #expect(OnscreenEntity.job(job.id).identifier == EntityIdentifier(for: job))
  }
}
