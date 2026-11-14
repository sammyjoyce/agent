import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

/// Stands in for ScrawlKit. It keeps the latest target and every description a start asked for.
@MainActor final class FakeFeedbackRecorder: FeedbackRecorder {
  var isPaired = true
  var answer = FeedbackStart.started
  private(set) var target: FeedbackTarget?
  private(set) var starts: [String] = []

  func setTarget(_ target: FeedbackTarget?) { self.target = target }

  func start(description: String) -> FeedbackStart {
    starts.append(description)
    return answer
  }
}

private func pinned(_ name: String, port: UInt16 = 43187) throws -> CoordinatorProfile {
  var profile = CoordinatorProfile(
    name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.2", port: port))
  profile.pin = CoordinatorID(UUID())
  return profile
}

private func target(_ profile: CoordinatorProfile) -> FeedbackTarget? {
  profile.pin.map { FeedbackTarget(profile: profile.id, coordinator: $0, address: profile.address) }
}

@MainActor private func eventually(_ what: String, _ predicate: () async -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(15)
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(what)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

@Test func theTargetIsTheOneCoordinatorTheFeedShows() throws {
  let work = try pinned("Work")
  let personal = try pinned("Personal", port: 43188)
  let home = CoordinatorProfile(
    name: try TagName("Home"), address: try CoordinatorAddress(host: "100.64.1.4"))
  let removingWork = [work.id: "Work"]
  let cases:
    [(String, FeedScope, [CoordinatorProfile], [ProfileID: String], [ProfileID?], FeedbackTarget?)] =
      [
        ("nothing saved", .all, [], [:], [], nil),
        ("one saved", .all, [work], [:], [], target(work)),
        ("one saved and not paired", .all, [home], [:], [], nil),
        ("one saved and being removed", .all, [work], removingWork, [], nil),
        ("two saved in All", .all, [work, personal], [:], [], nil),
        ("two saved with Work shown", .one(work.id), [work, personal], [:], [], target(work)),
        (
          "two saved with Personal shown", .one(personal.id), [work, personal], [:], [],
          target(personal)
        ),
        ("an unpaired coordinator shown", .one(home.id), [work, home], [:], [], nil),
        ("Work shown while it is removed", .one(work.id), [work, personal], removingWork, [], nil),
        (
          "Personal shown while Work is removed", .one(personal.id), [work, personal],
          removingWork, [], target(personal)
        ),
        ("one saved with its own held message", .all, [work], [:], [work.id], target(work)),
        ("one saved with a held message no one owns", .all, [work], [:], [work.id, nil], nil),
        (
          "Work shown with Personal's held message", .one(work.id), [work, personal], [:],
          [personal.id], nil
        ),
      ]
  for (situation, scope, profiles, removed, owners, expected) in cases {
    let shown = FeedbackTarget.shown(
      scope: scope, profiles: profiles, removed: removed, owners: owners)
    #expect(shown == expected, "\(situation)")
  }
}

/// The feed hands the recorder its target whenever what it shows changes: a held message no saved
/// coordinator owns, a second coordinator, the scope, and a removal.
@MainActor @Test(.timeLimit(.minutes(1)))
func theRecorderFollowsWhatTheFeedShows() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let work = try pinned("Work")
  let personal = try pinned("Personal", port: 43188)
  let chat = ChatModel()
  chat.profiles = [work]
  let recorder = FakeFeedbackRecorder()
  chat.feedbackRecorder = recorder
  #expect(recorder.target == target(work))
  let note = NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: "Invented note")
  chat.holds.append(try heldQueue([note], in: root))
  try await eventually("the held note shows") { !chat.shownHeld.isEmpty }
  #expect(recorder.target == nil, "A held note that may be another coordinator's is on screen")
  await chat.discardHeld(try #require(chat.held.first))
  #expect(recorder.target == target(work))
  chat.profiles = [work, personal]
  #expect(recorder.target == nil, "All shows both")
  chat.show(.one(personal.id))
  #expect(recorder.target == target(personal))
  chat.removed[personal.id] = "Personal"
  #expect(recorder.target == nil, "All shows both while Personal is removed")
  chat.profiles = [work]
  #expect(recorder.target == target(work))
}

/// Typed `/feedback` in Work's conversation starts a recording for Work with the typed text and
/// empties the composer. The text never goes to a coordinator.
@MainActor @Test(.timeLimit(.minutes(1)))
func typedFeedbackRecordsForTheCoordinatorShownAndSendsItNothing() async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, _) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let recorder = FakeFeedbackRecorder()
    coordinators.feedbackRecorder = recorder
    chat.show(.one(work))
    chat.draft = "/feedback The invented send button stays grey"
    #expect(chat.canSend)
    #expect(chat.submit())
    #expect(recorder.starts == ["The invented send button stays grey"])
    #expect(recorder.target?.profile == work)
    #expect(chat.draft.isEmpty && chat.error == nil)
    #expect(await chat.saveDraft())
    try await Task.sleep(for: .milliseconds(300))
    let sent = (await workFixture.count(), await personalFixture.count())
    #expect(sent == (0, 0), "No coordinator got the feedback text")
  }
}

/// Each reason typed `/feedback` starts no recording. The draft and its files stay, and the line
/// under the composer says why.
@MainActor
@Test(
  .timeLimit(.minutes(1)),
  arguments: [
    "All shown", "Personal's chip", "a file", "Scrawl unpaired", "no recorder", "already recording",
  ])
func typedFeedbackThatCannotRecordKeepsTheDraftAndSaysWhy(_ situation: String) async throws {
  try await withTwoFixtures { coordinators, workFixture, personalFixture, _ in
    let (work, personal) = try await addWorkAndPersonal(coordinators)
    let chat = coordinators.chat
    let recorder = FakeFeedbackRecorder()
    coordinators.feedbackRecorder = recorder
    chat.show(.one(work))
    let refusal: FeedbackRefusal
    switch situation {
    case "All shown":
      chat.show(.all)
      refusal = .noCoordinator
    case "Personal's chip":
      chat.setChip(personal)
      refusal = .addressedElsewhere("Work")
    case "a file":
      await chat.attach(
        data: Data("invented notes".utf8), name: "Notes.txt", mediaType: "text/plain")
      refusal = .files
    case "Scrawl unpaired":
      recorder.isPaired = false
      refusal = .unpaired
    case "no recorder":
      coordinators.feedbackRecorder = nil
      refusal = .unpaired
    default:
      recorder.answer = .busy
      refusal = .recording
    }
    let text = "/feedback The invented chip overlaps the field"
    chat.draft = text
    let files = chat.attachments
    #expect(chat.canSend, "Send can be tried, so it can say why it records nothing")
    #expect(!chat.submit())
    #expect(chat.error == refusal.message)
    #expect(chat.draft == text && chat.attachments == files)
    let asked = situation == "already recording" ? ["The invented chip overlaps the field"] : []
    #expect(recorder.starts == asked)
    try await Task.sleep(for: .milliseconds(300))
    let sent = (await workFixture.count(), await personalFixture.count())
    #expect(sent == (0, 0), "No coordinator got the feedback text")
  }
}

/// A recording reaches its coordinator through Scrawl and the Mac, so typed `/feedback` records
/// while the coordinator shown is not connected.
@MainActor @Test(.timeLimit(.minutes(1)))
func typedFeedbackRecordsWhileTheCoordinatorIsNotConnected() async throws {
  let chat = ChatModel()
  let recorder = FakeFeedbackRecorder()
  chat.feedbackRecorder = recorder
  try await withConnectedCoordinator(chat) { fixture, _ in
    chat.profiles[0].pin = fixture.id
    await chat.setActive(false)
    try await eventually("disconnected") { chat.connection == .disconnected }
    chat.draft = "/feedback"
    #expect(chat.submit())
    #expect(recorder.starts == [""])
    #expect(recorder.target?.coordinator == fixture.id)
  }
}

/// A recording carries its `beepBoop` object while the feed still shows the
/// coordinator it started for, and nothing once the feed shows any other.
@MainActor @Test(.timeLimit(.minutes(1)))
func aRecordingNamesItsCoordinatorOnlyWhileTheFeedStillShowsIt() async throws {
  let work = try pinned("Work")
  let personal = try pinned("Personal", port: 43188)
  let recording = FeedbackRecording(
    target: try #require(target(work)), description: "Invented: the chip overlaps")
  let supplement = await recording.timelineSupplement(current: target(work))
  let timeline = try JSONSerialization.jsonObject(
    with: JSONSerialization.data(withJSONObject: supplement))
  let beepBoop = try #require((timeline as? [String: Any])?["beepBoop"] as? [String: Any])
  #expect(Set(supplement.keys) == ["beepBoop"])
  #expect(beepBoop["version"] as? Int == 1)
  #expect((beepBoop["coordinatorId"] as? String).flatMap(UUID.init(uuidString:)) == work.pin?.uuid)
  #expect(beepBoop["host"] as? String == "100.64.1.2")
  #expect(beepBoop["port"] as? Int == 43187)
  #expect(beepBoop["description"] as? String == "Invented: the chip overlaps")
  let log = try #require(beepBoop["composerLog"] as? String)
  #expect(log.hasPrefix("Composer diagnostics: coverage="))
  #expect(log.utf8.count <= 262_144)
  #expect(await recording.timelineSupplement(current: target(personal)).isEmpty)
  #expect(await recording.timelineSupplement(current: nil).isEmpty)
}
