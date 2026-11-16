import AgentCore
import XCTest

@MainActor
final class ScopeInteractionTests: XCTestCase {
  private func launch(
    count: Int = 2, largestText: Bool = false, notifications: Bool = false,
    configure: ((InteractionPeer, InteractionPeer) async -> Void)? = nil
  ) async throws -> (XCUIApplication, InteractionPeer, InteractionPeer) {
    continueAfterFailure = false
    executionTimeAllowance = 180
    let work = InteractionPeer()
    let personal = InteractionPeer()
    let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await work.history(initial: empty, pages: [:], latest: empty)
    await personal.history(initial: empty, pages: [:], latest: empty)
    await configure?(work, personal)
    var ports: [String] = []
    let peers = Array([work, personal].prefix(count))
    for peer in peers {
      addTeardownBlock { await peer.stop() }
      ports.append(String(try await peer.start()))
    }
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_ID"] = UUID().uuidString
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.joined(separator: ",")
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peers.map { $0.coordinator.uuidString }
      .joined(separator: ",")
    app.launchArguments += ["-notificationsEnabled", notifications ? "YES" : "NO"]
    if notifications {
      app.launchEnvironment["AGENT_INTERACTION_ALERTS"] = "1"
      addUIInterruptionMonitor(withDescription: "Allow notifications") { alert in
        let allow = alert.buttons["Allow"]
        guard allow.exists else { return false }
        allow.tap()
        return true
      }
    }
    if largestText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    addTeardownBlock { @MainActor in
      if app.state != .notRunning { app.terminate() }
      app.launchEnvironment["AGENT_INTERACTION_CLEANUP"] = "1"
      app.launch()
      XCTAssertTrue(app.staticTexts["Interaction fixture cleaned"].waitForExistence(timeout: 10))
      app.terminate()
    }
    app.launch()
    if notifications {
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let allow = springboard.buttons["Allow"]
      if allow.waitForExistence(timeout: 3) { allow.tap() }
    }
    XCTAssertTrue(app.textViews["Message the coordinator"].waitForExistence(timeout: 10))
    try await wait { await work.observationCount() > 0 }
    if count > 1 { try await wait { await personal.observationCount() > 0 } }
    return (app, work, personal)
  }

  func testNoticeHeaderOpensReadOnlyRecordedDetailsAndDismissesAtLargeText() async throws {
    let details = NoticeDetails(
      sourceConversationId: "invented-conversation", sourceEntryId: "invented-original",
      sources: [],
      taskId: "invented-task", taskTitle: "Parcel decision")
    let rows: [HistoryMessage] = [
      .init(
        continuation: false, entryId: "notice:1", finalChunk: true,
        noticeDetails: details, role: .notice, text: "A misleading body is not provenance."),
      .init(
        continuation: false, entryId: "notice:2", finalChunk: true,
        noticeOrigin: .init(jobId: "invented-job", title: "Morning review"),
        role: .notice, text: "Another invented update."),
      .init(
        continuation: false, entryId: "notice:3", finalChunk: true,
        role: .notice, text: "Legacy update."),
    ]
    let (app, peer, _) = try await launch(count: 1, largestText: true) { peer, _ in
      let history = NativeEventHistory(messages: rows, nextCursor: nil, pageComplete: true)
      await peer.history(initial: history, pages: [:], latest: history)
    }
    let taskHeader = app.buttons["Details for Task: Parcel decision"]
    // A large-text transcript may initially follow its last row.
    for _ in 0..<4 where !taskHeader.isHittable { app.swipeDown() }
    XCTAssertTrue(taskHeader.waitForExistence(timeout: 5))
    taskHeader.tap()
    XCTAssertTrue(app.navigationBars["Notice details"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Parcel decision"].exists)
    func reveal(_ text: String) {
      for _ in 0..<8 where !app.staticTexts[text].isHittable { app.swipeUp() }
      XCTAssertTrue(app.staticTexts[text].isHittable)
    }
    reveal("invented-task")
    reveal("invented-conversation")
    reveal("invented-original")
    app.buttons["Done"].tap()
    XCTAssertFalse(app.navigationBars["Notice details"].exists)
    let jobHeader = app.buttons["Details for Job: Morning review"]
    for _ in 0..<4 where !jobHeader.isHittable { app.swipeUp() }
    jobHeader.tap()
    XCTAssertTrue(app.staticTexts["invented-job"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    let legacyHeader = app.buttons["Details for Update"]
    for _ in 0..<4 where !legacyHeader.isHittable { app.swipeUp() }
    legacyHeader.tap()
    XCTAssertTrue(
      app.staticTexts["Source and task details were not recorded for this message."]
        .waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
    let inputs = await peer.inputs()
    let attempts = await peer.submitAttempts()
    let retries = await peer.retries()
    XCTAssertTrue(inputs.isEmpty)
    XCTAssertEqual(attempts, 0)
    XCTAssertEqual(retries, 0)
  }

  func testSourceOnlyNoticeHeadersOpenExactCanonicalEvidenceWithoutTaskMetadata() async throws {
    let origins = [
      (
        "google",
        "Parcel decision with a deliberately long invented source title that wraps compactly in the chat header"
      ),
      ("github", "Review requested"),
    ]
    let rows: [HistoryMessage] = origins.enumerated().map { index, origin in
      .init(
        continuation: false, entryId: "source:\(index)", finalChunk: true,
        noticeDetails: .init(
          sourceConversationId: "invented-source-conversation", sourceEntryId: "original-\(index)",
          sources: [
            .init(
              account: "invented-\(origin.0)-account", eventId: "event-\(index)",
              eventVersion: "v1", provider: origin.0, threadId: "thread-\(index)", title: origin.1)
          ]),
        role: .notice, text: "Job Fake: body text must not determine this header.")
    }
    let (app, peer, _) = try await launch(count: 1) { peer, _ in
      let history = NativeEventHistory(messages: rows, nextCursor: nil, pageComplete: true)
      await peer.history(initial: history, pages: [:], latest: history)
    }
    for (index, origin) in origins.enumerated() {
      let label = "Details for \(origin.0): \(origin.1)"
      let header = app.buttons[label]
      for _ in 0..<4 where !header.isHittable { app.swipeDown() }
      XCTAssertTrue(header.waitForExistence(timeout: 5))
      header.tap()
      XCTAssertTrue(app.navigationBars["Notice details"].waitForExistence(timeout: 5))
      func reveal(_ text: String) {
        for _ in 0..<8 where !app.staticTexts[text].isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts[text].isHittable)
      }
      reveal("invented-source-conversation")
      reveal("original-\(index)")
      reveal(origin.1)
      reveal(origin.0)
      reveal("invented-\(origin.0)-account")
      reveal("thread-\(index)")
      reveal("event-\(index)")
      reveal("v1")
      XCTAssertFalse(app.staticTexts["invented-task"].exists)
      let capture = XCTAttachment(screenshot: app.screenshot())
      capture.name = "Source-only \(origin.0) recorded details"
      capture.lifetime = .keepAlways
      add(capture)
      app.buttons["Done"].tap()
      XCTAssertFalse(app.navigationBars["Notice details"].exists)
    }
    let inputs = await peer.inputs()
    let attempts = await peer.submitAttempts()
    let retries = await peer.retries()
    XCTAssertTrue(inputs.isEmpty)
    XCTAssertEqual(attempts, 0)
    XCTAssertEqual(retries, 0)
  }

  private func wait(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !(await condition()) {
      if ContinuousClock.now >= deadline {
        XCTFail("Timed out waiting for peer")
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func choose(_ name: String, _ app: XCUIApplication) {
    let menu = app.buttons["scopeMenu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    menu.tap()
    let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
    choice.tap()
  }

  private func type(_ text: String, _ app: XCUIApplication) {
    let field = app.textViews["Message the coordinator"]
    XCTAssertTrue(field.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    field.tap()
    field.typeText(text)
  }

  func testNotificationTapsRouteWithoutChangingTheDraft() async throws {
    let device = try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: "/tmp/agent-notification-\(device).enabled"),
      "Run ios/scripts/test-notification-tap.py to deliver APNs payloads")
    let (app, work, personal) = try await launch(notifications: true) { _, personal in
      let history = NativeEventHistory(
        messages: [
          .init(
            continuation: false, entryId: "personal-latest", finalChunk: true, role: .final,
            text: "Personal's latest invented reply")
        ], nextCursor: nil, pageComplete: true)
      await personal.history(initial: history, pages: [:], latest: history)
    }
    let id = try XCTUnwrap(app.launchEnvironment["AGENT_INTERACTION_ID"])
    let signal = URL(fileURLWithPath: "/tmp/agent-notification-\(device).json")
    addTeardownBlock { try? FileManager.default.removeItem(at: signal) }
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    func tapAlert(_ stage: String) throws {
      let data = try JSONSerialization.data(withJSONObject: ["stage": stage, "id": id])
      try data.write(to: signal, options: .atomic)
      let alert = springboard.descendants(matching: .any).matching(
        NSPredicate(format: "label CONTAINS 'Private fixture response'")
      )
      .firstMatch
      if !alert.waitForExistence(timeout: 5) {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
        let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        top.press(forDuration: 0.1, thenDragTo: middle)
      }
      XCTAssertTrue(alert.waitForExistence(timeout: 15), springboard.debugDescription)
      alert.tap()
    }
    func capture(_ name: String) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    choose("Work", app)
    type("Keep this Work draft", app)
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    try tapAlert("named")
    XCTAssertTrue(app.buttons["scopeMenu"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["scopeMenu"].label.contains("Personal"))
    XCTAssertEqual(
      app.textViews["Message the coordinator"].value as? String, "Keep this Work draft")
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "This draft goes to Work")
    XCTAssertTrue(app.staticTexts["Personal's latest invented reply"].isHittable)
    capture("notification-personal-with-work-draft")
    try await wait { await personal.cursors().contains("<latest>") }
    let previousLatest = await personal.cursors().filter { $0 == "<latest>" }.count
    choose("Work", app)
    XCTAssertTrue(app.buttons["scopeMenu"].label.contains("Work"))
    app.terminate()
    try tapAlert("cold")
    XCTAssertTrue(app.buttons["scopeMenu"].waitForExistence(timeout: 15))
    XCTAssertTrue(app.buttons["scopeMenu"].label.contains("Personal"))
    XCTAssertEqual(
      app.textViews["Message the coordinator"].value as? String, "Keep this Work draft")
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "This draft goes to Work")
    try await wait { await personal.cursors().filter { $0 == "<latest>" }.count > previousLatest }
    XCUIDevice.shared.press(.home)
    XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
    try tapAlert("unnamed")
    let notice = app.staticTexts[
      "This notification did not say which coordinator sent it. Showing all."]
    XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.buttons["scopeMenu"].label.contains("All coordinators"))
    capture("notification-unnamed-all")
    app.buttons["scopeMenu"].tap()
    let all = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'All coordinators'")
    ).firstMatch
    XCTAssertTrue(all.waitForExistence(timeout: 5))
    all.tap()
    XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
    let workSubmits = await work.submitAttempts()
    let personalSubmits = await personal.submitAttempts()
    let workRetries = await work.retries()
    let personalRetries = await personal.retries()
    XCTAssertEqual(workSubmits, 0)
    XCTAssertEqual(personalSubmits, 0)
    XCTAssertEqual(workRetries, 0)
    XCTAssertEqual(personalRetries, 0)
  }

  func testTheTitleMenuShowsWorkAndASendReachesOnlyWork() async throws {
    let (app, work, personal) = try await launch()
    choose("Work", app)
    XCTAssertEqual(app.textViews["Message the coordinator"].value as? String, "Message Work")
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "To Work")
    type("An invented Work note", app)
    app.buttons["Send message"].tap()
    try await wait { await work.submits() == ["An invented Work note"] }
    let other = await personal.submits()
    XCTAssertEqual(other, [])
  }

  func testADraftBegunInAllIsVetoedInWorkAndNarrowedOnlyByTap() async throws {
    let (app, work, personal) = try await launch()
    type("A broadcast draft", app)
    choose("Work", app)
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "This draft goes to Work and Personal")
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
    app.buttons["Address to Work only"].tap()
    app.buttons["Send message"].tap()
    try await wait { await work.submits() == ["A broadcast draft"] }
    let other = await personal.submits()
    XCTAssertEqual(other, [])
  }

  func testATypedPersonalTagInWorksViewIsNamedAndNotSent() async throws {
    let (app, work, personal) = try await launch()
    choose("Work", app)
    type("@Personal hi", app)
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "This draft goes to Personal")
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
    let beforeWork = await work.submits()
    let beforePersonal = await personal.submits()
    XCTAssertEqual(beforeWork, [])
    XCTAssertEqual(beforePersonal, [])
    app.buttons["Show Personal"].tap()
    app.buttons["Send message"].tap()
    try await wait { await personal.submits() == ["hi"] }
    let afterWork = await work.submits()
    XCTAssertEqual(afterWork, [])
  }

  func testASendToBothStaysVisibleInEachScope() async throws {
    let (app, work, personal) = try await launch()
    type("A note for both", app)
    app.buttons["Send message"].tap()
    try await wait { await work.submits() == ["A note for both"] }
    try await wait { await personal.submits() == ["A note for both"] }
    try await work.placeLastSubmit()
    try await personal.placeLastSubmit()
    choose("Work", app)
    XCTAssertTrue(app.staticTexts["A note for both"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 5))
    choose("Personal", app)
    XCTAssertTrue(app.staticTexts["A note for both"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 5))
  }

  func testSwitchingResetsExpandedActivity() async throws {
    let (app, _, _) = try await launch { work, _ in
      let history = NativeEventHistory(
        messages: [
          .init(
            continuation: false, entryId: "reasoning", finalChunk: true, role: .thinking,
            text: "The invented review has two steps.")
        ], nextCursor: nil, pageComplete: true)
      await work.history(initial: history, pages: [:], latest: history)
    }
    choose("Work", app)
    let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'"))
      .firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 10))
    group.tap()
    XCTAssertTrue(
      app.staticTexts["The invented review has two steps."].waitForExistence(timeout: 5))
    choose("Personal", app)
    choose("Work", app)
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["The invented review has two steps."].exists)
  }

  func testSwitchingLandsAtTheTrueLatestRow() async throws {
    let (app, work, _) = try await launch { work, personal in
      func message(_ index: Int) -> HistoryMessage {
        .init(
          continuation: false, entryId: "history-\(index)", finalChunk: true,
          role: .final, text: "Invented history reply \(index)")
      }
      let recent = (554..<560).map(message)
      let initial = NativeEventHistory(messages: recent, nextCursor: "older", pageComplete: true)
      let older = NativeEventHistory(
        messages: (0..<500).map(message), nextCursor: nil, pageComplete: true)
      let latest = NativeEventHistory(messages: recent, nextCursor: nil, pageComplete: true)
      await work.history(initial: initial, pages: ["older": older], latest: latest)
      await personal.history(initial: latest, pages: [:], latest: latest)
    }
    choose("Work", app)
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(app.staticTexts["Invented history reply 559"].waitForExistence(timeout: 10))
    for _ in 0..<10 {
      if (await work.cursors()).contains("older") { break }
      if app.buttons["Load earlier messages"].isHittable {
        app.buttons["Load earlier messages"].tap()
        break
      }
      transcript.swipeDown(velocity: .fast)
    }
    try await wait { await work.cursors().contains("older") }
    XCTAssertTrue(app.buttons["latest-messages"].waitForExistence(timeout: 10))
    choose("Personal", app)
    choose("Work", app)
    try await wait { await work.cursors().contains("<latest>") }
    XCTAssertTrue(app.buttons["latest-messages"].waitForNonExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Invented history reply 559"].isHittable)
  }

  func testPersonalsRepliesShowAsNewInWorksSubtitle() async throws {
    let (app, _, personal) = try await launch()
    choose("Work", app)
    try await personal.reply("First hidden reply", id: "hidden-1")
    try await personal.reply("Second hidden reply", id: "hidden-2")
    let title = app.buttons["scopeMenu"]
    let news = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS 'Personal' AND label CONTAINS '2 new'"),
      object: title)
    XCTAssertEqual(XCTWaiter.wait(for: [news], timeout: 10), .completed, app.debugDescription)
    title.tap()
    let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '2 new replies'")).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.tap()
    XCTAssertFalse(app.buttons["scopeMenu"].label.contains("2 new"))
  }

  func testTheScopeSurvivesARelaunch() async throws {
    let (app, _, _) = try await launch()
    choose("Work", app)
    type("Keep this Work draft", app)
    app.terminate()
    app.launch()
    let field = app.textViews["Message the coordinator"]
    XCTAssertTrue(field.waitForExistence(timeout: 10))
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Keep this Work draft"), object: field)
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
    XCTAssertTrue(app.buttons["scopeMenu"].label.contains("Work"))
    XCTAssertEqual(app.staticTexts["recipientLine"].label, "To Work")
  }

  func testOneCoordinatorSavedShowsNoMenu() async throws {
    let (app, _, _) = try await launch(count: 1)
    XCTAssertFalse(app.buttons["scopeMenu"].exists)
    XCTAssertTrue(app.staticTexts["Beep Boop"].exists)
    XCTAssertFalse(app.staticTexts["recipientLine"].exists)
  }

  func testPrototypeStatesForReview() async throws {
    let (app, _, personal) = try await launch { work, personal in
      func item(_ id: String, _ role: HistoryRole, _ text: String) -> HistoryMessage {
        .init(continuation: false, entryId: id, finalChunk: true, role: role, text: text)
      }
      let workHistory = NativeEventHistory(
        messages: [
          item("w1", .user, "Is the billing retry test still flaky on main?"),
          item(
            "w2", .final,
            "Yes. The retry test failed 3 of the last 20 runs. I can switch it to the fake clock."),
          item("w3", .user, "Heads up, I'm offline 12 to 1 for lunch."),
          item("w4", .final, "Noted. I'll hold anything that needs you until 1."),
          item("w5", .user, "Go ahead with the fake clock, then start the release checklist."),
          item(
            "w6", .final,
            "The fix passed 50 runs in a row. The staging smoke test and QA sign-off are left."),
        ], nextCursor: nil, pageComplete: true)
      let personalHistory = NativeEventHistory(
        messages: [item("p1", .final, "The appointment is booked. I set a reminder.")],
        nextCursor: nil, pageComplete: true)
      await work.history(initial: workHistory, pages: [:], latest: workHistory)
      await personal.history(initial: personalHistory, pages: [:], latest: personalHistory)
    }
    func capture(_ name: String) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    capture("v1-all")
    choose("Work", app)
    try await personal.reply("First new reply", id: "new-1")
    try await personal.reply("Second new reply", id: "new-2")
    let news = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS '2 new'"), object: app.buttons["scopeMenu"])
    XCTAssertEqual(XCTWaiter.wait(for: [news], timeout: 10), .completed)
    capture("v1-work")
    app.buttons["Connection"].tap()
    let appearance = app.descendants(matching: .any).matching(identifier: "appearancePicker")
      .firstMatch
    XCTAssertTrue(appearance.waitForExistence(timeout: 5))
    appearance.tap()
    app.buttons["Dark"].tap()
    app.buttons["dismissConnection"].tap()
    capture("v1-work-dark")
    app.buttons["Connection"].tap()
    appearance.tap()
    app.buttons["Light"].tap()
    app.buttons["dismissConnection"].tap()
    app.buttons["scopeMenu"].tap()
    capture("v1-open")
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Personal'")).firstMatch.tap()
    choose("Work", app)
    type("Run the staging smoke test now", app)
    app.scrollViews["transcript"].swipeDown()
    capture("v1-work-typing")
    choose("Personal", app)
    capture("v1-personal-with-work-draft")
  }

  func testLargestTextMenuRemainsUsable() async throws {
    let (app, _, _) = try await launch(largestText: true)
    let menu = app.buttons["scopeMenu"]
    XCTAssertTrue(menu.isHittable)
    XCTAssertFalse(menu.frame.intersects(app.buttons["Connection"].frame))
    let titleCapture = XCTAttachment(screenshot: app.screenshot())
    titleCapture.name = "scope-title-largest-text"
    titleCapture.lifetime = .keepAlways
    add(titleCapture)
    menu.tap()
    let current = app.descendants(matching: .any).matching(
      NSPredicate(format: "label == 'All coordinators'")
    ).allElementsBoundByIndex
    XCTAssertTrue(
      current.contains { $0.isSelected || ($0.value as? String) == "1" }, app.debugDescription)
    let work = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Work'")).firstMatch
    let personal = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Personal'"))
      .firstMatch
    XCTAssertTrue(work.isHittable)
    XCTAssertTrue(personal.isHittable)
    XCTAssertFalse(work.frame.intersects(personal.frame))
    let capture = XCTAttachment(screenshot: app.screenshot())
    capture.name = "scope-menu-largest-text"
    capture.lifetime = .keepAlways
    add(capture)
    work.tap()
    XCTAssertTrue(menu.isHittable)
    let scopedCapture = XCTAttachment(screenshot: app.screenshot())
    scopedCapture.name = "scope-work-largest-text"
    scopedCapture.lifetime = .keepAlways
    add(scopedCapture)
  }
}
