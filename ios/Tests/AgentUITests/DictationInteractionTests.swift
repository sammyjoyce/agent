import AgentCore
import XCTest

@MainActor
final class DictationInteractionTests: XCTestCase {
  private func launch(script: String) async throws -> (XCUIApplication, InteractionPeer) {
    continueAfterFailure = false
    executionTimeAllowance = 120
    let work = InteractionPeer()
    let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await work.history(initial: empty, pages: [:], latest: empty)
    addTeardownBlock { await work.stop() }
    let port = try await work.start()
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(port)
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = work.coordinator.uuidString
    app.launchEnvironment["AGENT_INTERACTION_DICTATION"] = script
    app.launchArguments += ["-notificationsEnabled", "NO"]
    addTeardownBlock { @MainActor in app.terminate() }
    app.launch()
    XCTAssertTrue(app.textViews["Message the coordinator"].waitForExistence(timeout: 10))
    // A hosted test run earlier on this simulator can leave the notification prompt up. It keeps
    // the scene inactive, and the fixture connects only while the scene is active.
    let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts[
      "“Beep Boop” Would Like to Send You Notifications"]
    if prompt.exists { prompt.buttons["Allow"].tap() }
    let deadline = ContinuousClock.now + .seconds(10)
    while await work.observationCount() == 0 {
      guard ContinuousClock.now < deadline else {
        XCTFail("The app never connected to its peer")
        break
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    return (app, work)
  }

  private func mic(_ app: XCUIApplication, labeled label: String) -> XCUIElement {
    let mic = app.otherElements["messageComposer"].buttons["dictation"]
    XCTAssertTrue(mic.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(
      mic.wait(for: \.label, toEqual: label, timeout: 10), "The mic reads \(mic.label)")
    return mic
  }

  func testATapThenATapKeepsTheWordsInTheFieldAndSendsNothing() async throws {
    let (app, work) = try await launch(script: #"{"takes": ["Invented note from the mic"]}"#)
    mic(app, labeled: "Dictate").tap()
    mic(app, labeled: "Stop dictating").tap()
    let field = app.textViews["Message the coordinator"]
    await fulfillment(
      of: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", "Invented note from the mic"),
          object: field)
      ], timeout: 5)
    XCTAssertTrue(mic(app, labeled: "Dictate").exists)
    try await Task.sleep(for: .milliseconds(500))
    let sent = await work.submits()
    XCTAssertEqual(sent, [], "A tapped take never sends")
  }

  func testHoldingTheMicSendsTheWordsOnRelease() async throws {
    let (app, work) = try await launch(script: #"{"takes": ["Invented held message"]}"#)
    mic(app, labeled: "Dictate").press(forDuration: 1.5)
    let deadline = ContinuousClock.now + .seconds(10)
    while await work.submits().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let sent = await work.submits()
    XCTAssertEqual(sent, ["Invented held message"])
    XCTAssertTrue(app.textViews["Message the coordinator"].showsNoText)
  }

  private nonisolated static func sendsBeforeRelease(_ work: InteractionPeer) async throws
    -> [String]
  {
    // The caller resolves its coordinate first, then holds at least six seconds. Sample only the
    // first four seconds so gesture release and its legitimate Send are outside this window.
    for _ in 0..<20 {
      try await Task.sleep(for: .milliseconds(200))
      let sent = await work.submits()
      if !sent.isEmpty { return sent }
    }
    return []
  }

  func testStationaryLongHoldWithoutSpeechUpdatesSendsOnlyOnRelease() async throws {
    let (app, work) = try await launch(script: #"{"takes": ["Invented held message"]}"#)
    let button = mic(app, labeled: "Dictate")
    let duringHold = Task.detached { try await Self.sendsBeforeRelease(work) }
    button.press(forDuration: 7)
    let early = try await duringHold.value
    XCTAssertEqual(early, [], "Holding must not send before release")
    let deadline = ContinuousClock.now + .seconds(10)
    while await work.submits().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let sent = await work.submits()
    XCTAssertEqual(sent, ["Invented held message"])
  }

  private let changingSpeech = #"""
    {"takes": ["Invented final message"], "stepMilliseconds": 700,
     "partials": ["Invented", "Invented words", "Invented words continue",
       "Invented words continue across several lines with more invented speech",
       "Invented words continue across several lines with more invented speech and a final phrase"]}
    """#

  func testStationaryHoldSurvivesSpeechAndLayoutUpdatesUntilRelease() async throws {
    let (app, work) = try await launch(script: changingSpeech)
    let button = mic(app, labeled: "Dictate")
    let duringHold = Task.detached { try await Self.sendsBeforeRelease(work) }
    let began = ContinuousClock.now
    button.press(forDuration: 7)
    let deadline = ContinuousClock.now + .seconds(10)
    while await work.submits().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let early = try await duringHold.value
    XCTAssertEqual(early, [], "Speech updates while holding must not send")
    let sent = await work.submits()
    XCTAssertEqual(sent, ["Invented final message"], "A stationary held touch must survive updates")
    XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .seconds(7))
    XCTAssertTrue(app.textViews["Message the coordinator"].showsNoText)
  }

  func testKeyboardVisibleDriftingHoldSurvivesSpeechUpdatesUntilRelease() async throws {
    let (app, work) = try await launch(script: changingSpeech)
    app.textViews["Message the coordinator"].tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    let button = mic(app, labeled: "Dictate")
    let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let duringHold = Task.detached { try await Self.sendsBeforeRelease(work) }
    start.press(
      forDuration: 1, thenDragTo: start.withOffset(CGVector(dx: 10, dy: 10)),
      withVelocity: .slow, thenHoldForDuration: 5)
    let early = try await duringHold.value
    XCTAssertEqual(early, [], "The drifting held touch must not send early")
    let deadline = ContinuousClock.now + .seconds(10)
    while await work.submits().isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(50))
    }
    let sent = await work.submits()
    XCTAssertEqual(sent, ["Invented final message"])
  }

  func testSlidingOffAfterSpeechUpdatesKeepsWithoutSending() async throws {
    let (app, work) = try await launch(script: changingSpeech)
    let button = mic(app, labeled: "Dictate")
    let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(forDuration: 7, thenDragTo: start.withOffset(CGVector(dx: -140, dy: -100)))
    let field = app.textViews["Message the coordinator"]
    await fulfillment(
      of: [
        XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", "Invented final message"), object: field)
      ], timeout: 10)
    let sent = await work.submits()
    XCTAssertEqual(sent, [], "Sliding off must never send")
  }

  func testTheFirstTapAsksBeforeDownloadingAndShowsProgress() async throws {
    let (app, work) = try await launch(
      script: #"""
        {"model": "missing", "stepMilliseconds": 800,
         "progress": [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1]}
        """#)
    mic(app, labeled: "Set up dictation").tap()
    XCTAssertTrue(
      app.staticTexts["Download the voice model (609.4 MB)?"].waitForExistence(timeout: 5),
      app.debugDescription)
    XCTAssertTrue(app.staticTexts["What you say never leaves this iPhone."].exists)
    app.buttons["Download"].tap()
    let progress = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH 'Downloading voice model · '")
    ).firstMatch
    XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(mic(app, labeled: "Downloading voice model").exists)
    XCTAssertTrue(progress.label.hasSuffix("of 609.4 MB"), progress.label)
    let ready = app.staticTexts[
      "Ready. Tap the mic to dictate, or hold it to talk and release to send."]
    XCTAssertTrue(ready.waitForExistence(timeout: 20), app.debugDescription)
    XCTAssertTrue(mic(app, labeled: "Dictate").exists)
    let sent = await work.submits()
    XCTAssertEqual(sent, [], "Downloading never opens the mic or sends")
  }
}
