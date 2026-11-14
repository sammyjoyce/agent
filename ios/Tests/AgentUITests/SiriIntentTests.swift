#if canImport(AppIntentsTesting)
  import AgentCore
  import AppIntentsTesting
  import XCTest

  @MainActor
  final class SiriIntentTests: XCTestCase {
    func testOpenCoordinatorRoutesWithoutChangingTheDraft() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      continueAfterFailure = false
      executionTimeAllowance = 180
      let work = InteractionPeer()
      let personal = InteractionPeer()
      let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
      await work.history(initial: empty, pages: [:], latest: empty)
      let history = NativeEventHistory(
        messages: [
          .init(
            continuation: false, entryId: "personal-latest", finalChunk: true, role: .final,
            text: "Personal's latest invented reply")
        ], nextCursor: nil, pageComplete: true)
      await personal.history(initial: history, pages: [:], latest: history)
      var ports: [String] = []
      for peer in [work, personal] {
        addTeardownBlock { await peer.stop() }
        ports.append(String(try await peer.start()))
      }
      let app = XCUIApplication()
      app.launchEnvironment["AGENT_INTERACTION_ID"] = UUID().uuidString
      app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.joined(separator: ",")
      app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = [work, personal]
        .map { $0.coordinator.uuidString }.joined(separator: ",")
      app.launchEnvironment["AGENT_INTERACTION_INTENTS"] = "1"
      app.launchArguments += ["-notificationsEnabled", "NO"]
      addTeardownBlock { @MainActor in
        if app.state != .notRunning { app.terminate() }
        app.launchEnvironment["AGENT_INTERACTION_CLEANUP"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Interaction fixture cleaned"].waitForExistence(timeout: 10))
        app.terminate()
      }
      app.launch()
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(field.waitForExistence(timeout: 10))

      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 10))
      menu.tap()
      let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Work"))
        .firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
      choice.tap()
      XCTAssertTrue(field.wait(for: \.isEnabled, toEqual: true, timeout: 10))
      field.tap()
      field.typeText("Keep this Work draft")
      capture("siri-1-open-coordinator-before", app)

      let definitions = IntentDefinitions(bundleIdentifier: "dev.jessfraz.Agent")
      let coordinators = try await definitions.entities["CoordinatorEntity"].allEntities()
      XCTAssertEqual(coordinators.count, 2, "\(coordinators)")
      // The entity exposes no properties, so Personal is found by its place in the saved order.
      let target = coordinators[1]
      try await definitions.intents["OpenCoordinatorIntent"].makeIntent(target: target).run()

      let personalScope = NSPredicate(format: "label CONTAINS 'Personal'")
      XCTAssertEqual(
        XCTWaiter().wait(
          for: [XCTNSPredicateExpectation(predicate: personalScope, object: menu)], timeout: 10),
        .completed, menu.label)
      XCTAssertEqual(field.value as? String, "Keep this Work draft")
      XCTAssertEqual(app.staticTexts["recipientLine"].label, "This draft goes to Work")
      XCTAssertTrue(
        app.staticTexts["Personal's latest invented reply"].waitForExistence(timeout: 10))
      capture("siri-1-open-coordinator-after", app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
#endif
