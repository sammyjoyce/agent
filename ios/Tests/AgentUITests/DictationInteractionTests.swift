import AgentCore
import XCTest

/// The mic in the real composer over a scripted speech engine, which hears no microphone and
/// returns invented words.
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
    let mic = app.buttons["dictation"]
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
