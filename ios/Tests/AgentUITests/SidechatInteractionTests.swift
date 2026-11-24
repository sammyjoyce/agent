import AgentCore
import Foundation
import XCTest

@MainActor
final class SidechatInteractionTests: XCTestCase {
  private func launch(
    _ messages: [HistoryMessage], peer: InteractionPeer
  ) async throws -> XCUIApplication {
    let page = NativeEventHistory(messages: messages, nextCursor: nil, pageComplete: true)
    await peer.history(initial: page, pages: [:], latest: page)
    let port = try await peer.start()
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(port)
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    addTeardownBlock { @MainActor in app.terminate() }
    return app
  }

  private func editor(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "Message the coordinator").firstMatch
  }

  private func action(_ title: String, app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
  }

  private func eventually(
    timeout: Duration = .seconds(10), _ condition: @escaping () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("Condition was not satisfied within \(timeout)")
  }

  func testSidechatsToolbarListCreateChatAndEditSettingsFlow() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let pinned = SidechatSummary(
      archivedAt: nil,
      charter: "Keep track of rack temps and UPS alerts.",
      conversationId: "sc-10",
      createdAt: 1_798_797_600_000,
      isolated: false,
      notifications: .on,
      pinned: true,
      seed: nil,
      slug: "homelab-ops",
      title: "Homelab Ops",
      updatedAt: 1_798_797_605_000)
    let archived = SidechatSummary(
      archivedAt: 1_798_797_500_000,
      charter: nil,
      conversationId: "sc-11",
      createdAt: 1_798_797_400_000,
      isolated: true,
      notifications: .off,
      pinned: false,
      seed: nil,
      slug: "old-tax-filing",
      title: "Old Tax Filing",
      updatedAt: 1_798_797_500_000)
    await peer.serveSidechats([pinned, archived], autoReply: "Staging checks are green.")

    let app = try await launch(
      [
        .init(
          continuation: false, entryId: "main-1", finalChunk: true, role: .assistant,
          text: "Main ready.")
      ], peer: peer)
    XCTAssertTrue(app.staticTexts["Main ready."].waitForExistence(timeout: 10))

    let sidechatsButton = app.buttons["sidechatsButton"]
    XCTAssertTrue(sidechatsButton.waitForExistence(timeout: 10), app.debugDescription)
    sidechatsButton.tap()

    XCTAssertTrue(app.navigationBars["Side chats"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Homelab Ops"].exists)
    XCTAssertTrue(app.staticTexts["Archived (1)"].exists)

    let newButton = app.buttons["newSidechatButton"]
    XCTAssertTrue(newButton.waitForExistence(timeout: 5))
    newButton.tap()

    let titleField = app.textFields["sidechatTitleField"]
    XCTAssertTrue(titleField.waitForExistence(timeout: 5), app.debugDescription)
    titleField.tap()
    titleField.typeText("Release Prep")

    let createButton = app.buttons["confirmCreateSidechat"]
    XCTAssertTrue(createButton.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    createButton.tap()

    try await eventually {
      await peer.sidechatCreations().contains { $0.title == "Release Prep" }
    }
    XCTAssertTrue(
      app.staticTexts["Release Prep"].waitForExistence(timeout: 10), app.debugDescription)

    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    composer.typeText("Check staging rollout")
    let send = app.buttons["Send message"]
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    send.tap()

    try await eventually {
      await peer.sidechatInputs().contains { $0.text == "Check staging rollout" }
    }
    let mainSubmits = await peer.submits()
    XCTAssertTrue(mainSubmits.isEmpty, "Side chat messages must never go to Main")
    XCTAssertTrue(
      app.staticTexts["Staging checks are green."].waitForExistence(timeout: 10),
      app.debugDescription)

    let settingsButton = app.buttons["sidechatSettingsButton"]
    XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
    settingsButton.tap()

    let pinnedToggle = app.switches["editSidechatPinnedToggle"]
    XCTAssertTrue(pinnedToggle.waitForExistence(timeout: 5), app.debugDescription)
    if pinnedToggle.switches.firstMatch.exists {
      pinnedToggle.switches.firstMatch.tap()
    } else {
      pinnedToggle.tap()
    }

    let saveButton = app.buttons["saveSidechatSettings"]
    XCTAssertTrue(saveButton.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    saveButton.tap()

    try await eventually {
      await peer.sidechatUpdates().contains { $0.pinned == true }
    }
  }

  func testStartSidechatFromMainMessageMenuPrefillsSeedAndOpensSidechat() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    await peer.serveSidechats([])

    let app = try await launch(
      [
        .init(
          continuation: false, entryId: "main-seed-2", finalChunk: true, role: .final,
          text: "Let us track quarterly cloud budgets separately.")
      ], peer: peer)

    let message = app.staticTexts["Let us track quarterly cloud budgets separately."]
    XCTAssertTrue(message.waitForExistence(timeout: 10), app.debugDescription)

    message.press(forDuration: 1.0)
    let startAction = action("Start side chat from this", app: app)
    XCTAssertTrue(startAction.waitForExistence(timeout: 5), app.debugDescription)
    startAction.tap()

    XCTAssertTrue(app.navigationBars["New side chat"].waitForExistence(timeout: 5))
    let titleField = app.textFields["sidechatTitleField"]
    XCTAssertTrue(titleField.waitForExistence(timeout: 5))
    titleField.tap()
    titleField.typeText("Cloud Budget")

    let createButton = app.buttons["confirmCreateSidechat"]
    XCTAssertTrue(createButton.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    createButton.tap()

    try await eventually {
      await peer.sidechatCreations().contains {
        $0.title == "Cloud Budget" && $0.seed?.entryId == "main-seed-2"
      }
    }
    XCTAssertTrue(app.staticTexts["Cloud Budget"].waitForExistence(timeout: 10))
  }

  func testActiveWorkSidechatRowOpensInteractiveSidechatView() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let topic = SidechatSummary(
      archivedAt: nil,
      charter: "Keep rack sensors green.",
      conversationId: "sc-42",
      createdAt: 1_798_797_600_000,
      isolated: false,
      notifications: .inherit,
      pinned: false,
      seed: nil,
      slug: "homelab-ops",
      title: "Homelab Ops",
      updatedAt: 1_798_797_605_000)
    await peer.serveSidechats([topic])
    await peer.serveSidechatHistory(
      "sc-42",
      messages: [
        .init(
          continuation: false, entryId: "sc-msg-1", finalChunk: true, role: .assistant,
          text: "Checking rack fans now.")
      ])
    await peer.serveActiveWork(
      TaskGraphSnapshot(
        conversations: [],
        nodes: [],
        omitted: 0,
        work: [
          ActiveWorkItem(
            conversationId: "sc-42", detail: "read_file: sensors.toml", id: "sidechat:sc-42",
            isJob: false, sidechatSlug: "homelab-ops", startedAt: 1_798_797_600_000,
            status: .running, title: "Homelab Ops", tools: ["read_file: sensors.toml"])
        ]))

    let app = try await launch(
      [
        .init(
          continuation: false, entryId: "main-1", finalChunk: true, role: .assistant,
          text: "Main ready.")
      ], peer: peer)
    XCTAssertTrue(app.staticTexts["Main ready."].waitForExistence(timeout: 10))

    let strip = app.buttons["activeWorkStrip"]
    XCTAssertTrue(strip.waitForExistence(timeout: 10), app.debugDescription)
    strip.tap()

    XCTAssertTrue(app.navigationBars["Active work"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Side chat"].waitForExistence(timeout: 5))
    let row = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-sidechat:sc-42'"))
      .firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
    row.tap()

    XCTAssertTrue(
      app.staticTexts["Checking rack fans now."].waitForExistence(timeout: 10), app.debugDescription
    )
    XCTAssertTrue(
      editor(app).waitForExistence(timeout: 10),
      "Tapping a side chat row in Active work must open the interactive side chat")
  }
}
