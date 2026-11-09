import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// A feed with one saved coordinator, connected to a loopback fixture, as the app builds it.
@MainActor private func withConnectedModel(
  _ body: (ChatModel, FixtureCoordinator, ProfileDirectory) async throws -> Void
) async throws {
  let fixture = FixtureCoordinator()
  let (listener, port) = try await listen(fixture)
  defer { listener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let profile = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
  let model = ChatModel(draftStore: AttachmentStore(directory: root.appending(path: "Drafts")))
  model.profiles = [profile]
  model.attach(
    Lane(
      id: profile.id,
      session: CoordinatorSession(
        directory: directory, address: profile.address, pin: fixture.id, stamps: StampSource(),
        transport: loopback(port))))
  await model.setActive(true)
  while model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
  do {
    try await body(model, fixture, directory)
  } catch {
    await model.detach(profile.id)
    await fixture.stop()
    throw error
  }
  await model.detach(profile.id)
  await fixture.stop()
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sendPreservesNewTypingAndCannotAdmitTheSameDraftTwice() async throws {
  try await withConnectedModel { model, _, directory in
    model.draft = "Original draft"
    let sending = model.send()
    while !model.admitting { await Task.yield() }
    model.draft = "New typing while admission is pending"
    await model.send()?.value
    await sending?.value
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Original draft"])
    #expect(model.draft == "New typing while admission is pending")
    #expect(!model.admitting)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
func durableAdmissionDoesNotEraseANewerDraftWithIdenticalText(afterClearing: Bool) async throws {
  try await withConnectedModel { model, _, directory in
    model.draft = "The same text in a different draft"
    let sending = model.send()
    while !model.admitting { await Task.yield() }
    if afterClearing { model.draft = "" }
    model.draft = "The same text in a different draft"
    await model.send()?.value
    await sending?.value
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.count == 1)
    #expect(model.draft == "The same text in a different draft")
    #expect(!model.admitting)
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func sendKeepsAnUnadmittedDraftAndClearsOnlyItsAdmittedOriginal() async throws {
  try await withConnectedModel { model, _, directory in
    let oversized = String(repeating: "x", count: 65537)
    model.draft = oversized
    await model.send()?.value
    #expect(model.draft == oversized)
    #expect((try? queuedRequests(directory.outbox)) == nil, "Nothing was saved")
    model.draft = "Saved original"
    await model.send()?.value
    #expect(model.draft.isEmpty)
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == ["Saved original"])
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func feedbackCapturesOnceAndFailedAdmissionKeepsTheExactScreenshot() async throws {
  try await withConnectedModel { model, _, directory in
    try await withReadOnlyProfile(directory) {
      model.draft = "/feedback The text is clipped"
      var captures = 0
      await model.send(screenshot: {
        captures += 1
        return Data([1, 2, 3])
      })?.value
      let original = try #require(model.attachments.first)
      await model.send(screenshot: {
        captures += 1
        return Data([4, 5, 6])
      })?.value
      #expect(captures == 1)
      #expect(model.attachments == [original])
      #expect(try Data(contentsOf: original.url) == Data([1, 2, 3]))
      #expect(model.draft == "/feedback The text is clipped")
    }
  }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func attachmentOnlyAdmissionPreservesFilesAddedWhileTheOriginalIsSaving() async throws {
  try await withConnectedModel { model, _, directory in
    await model.attach(data: Data([1]), name: "First.txt", mediaType: "text/plain")
    let sending = model.send()
    while !model.admitting { await Task.yield() }
    await model.attach(data: Data([2]), name: "Second.txt", mediaType: "text/plain")
    await sending?.value
    #expect(model.attachments.map(\.reference.name) == ["Second.txt"])
    #expect(try Data(contentsOf: #require(model.attachments.first).url) == Data([2]))
    let queued = try queuedRequests(directory.outbox)
    #expect(queued.map(\.text) == [""])
    #expect(queued.first?.attachments?.map(\.name) == ["First.txt"])
  }
}

@MainActor private func connectModelThenRelease(_ session: CoordinatorSession) async throws {
  let model = ChatModel()
  model.attach(lane(session))
  await model.setActive(true)
  while model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
}

@Test(.timeLimit(.minutes(1)))
func detachAndModelDestructionBothCloseTheirSockets() async throws {
  try await withCoordinator { session, fixture, _ in
    let model = await MainActor.run { ChatModel() }
    let lane = lane(session)
    await model.attach(lane)
    await model.setActive(true)
    while await model.connection != .connected { try await Task.sleep(for: .milliseconds(1)) }
    await model.detach(lane.id)
    for await _ in fixture.closedObservations { break }
    #expect(await model.connection == .disconnected)
    #expect(await session.submit("No orphaned observer") == false)
  }
  try await withCoordinator { session, fixture, _ in
    try await connectModelThenRelease(session)
    for await _ in fixture.closedObservations { break }
    #expect(await session.submit("Model was released") == false)
  }
}
