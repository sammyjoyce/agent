import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

@MainActor
struct SiriCoordinatorEntityTests {
  @MainActor
  private final class SavedFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let suite = "siri-coordinators-\(UUID())"
    let defaults: UserDefaults
    let profiles: [CoordinatorProfile]
    let notifications: AppNotifications

    init(names: [String] = ["Work", "Personal", "Home"]) throws {
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
        defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet)
    }

    var query: CoordinatorQuery { CoordinatorQuery(notifications: notifications) }

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
    let entities = try await fixture.query.allEntities()
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
    let entities = try await fixture.query.allEntities()
    #expect(named(entities) == ["Work", "Family", "Home"])
    let found = try await fixture.query.entities(for: ["\(personal.id)"])
    #expect(named(found) == ["Family"])
  }

  @Test func aRemovedCoordinatorIsAbsent() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let coordinators = fixture.notifications.coordinators
    let home = fixture.profiles[2].id
    try await coordinators.remove(coordinators.removal(home))
    #expect(named(try await fixture.query.allEntities()) == ["Work", "Personal"])
    #expect(try await fixture.query.entities(for: ["\(home)"]).isEmpty)
  }

  @Test func entitiesForIdentifiersIgnoresAnUnknownID() async throws {
    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let found = try await fixture.query.entities(for: [
      "\(ProfileID())", "not-a-profile", "\(fixture.profiles[0].id)",
    ])
    #expect(found.map(\.id) == ["\(fixture.profiles[0].id)"])
  }

  @Test func openCoordinatorRoutesLikeAnAlertTapAndKeepsTheDraft() async throws {
    let tapped = try SavedFixture()
    defer { tapped.clean() }
    tapped.notifications.coordinators.chat.show(.one(tapped.profiles[0].id))
    tapped.notifications.open(.named(tapped.profiles[1].id))
    let tapScope = tapped.notifications.coordinators.chat.scope
    let tapNotice = try #require(tapped.notifications.openRequest).notice

    let fixture = try SavedFixture()
    defer { fixture.clean() }
    let chat = fixture.notifications.coordinators.chat
    chat.show(.one(fixture.profiles[0].id))
    chat.draft = "An invented Work draft"
    let destination = chat.destination
    _ = try await OpenCoordinatorIntent(
      target: fixture.entity(1), notifications: fixture.notifications
    ).perform()
    #expect(chat.scope == .one(fixture.profiles[1].id))
    #expect(tapScope == .one(tapped.profiles[1].id))
    #expect(try #require(fixture.notifications.openRequest).notice == tapNotice)
    #expect(chat.draft == "An invented Work draft")
    #expect(chat.destination == destination)
  }
}
