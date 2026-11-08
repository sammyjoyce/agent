import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

private let exampleConversation = SavedConversation(
  conversationId: "example-conversation", taskId: "example-task", title: "Example review")

private func inspections(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .inspect = $0 { true } else { false } }.count
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
