#if targetEnvironment(simulator)
  import AgentCore
  import Foundation
  import XCTest

  /// The simulator's stand-in for the phone: the Debug app's interaction fixture with Work and
  /// Personal saved as loopback peers. Alert tests ask the host script for each push, so these
  /// alerts rehearse the phone-side detection and prove no delivery.
  @MainActor
  struct Rehearsal {
    let work: InteractionPeer
    let personal: InteractionPeer
    let id: UUID
    let simulator: String

    private var pushRequest: URL {
      URL(fileURLWithPath: "/tmp/phone-acceptance-\(simulator)-push.json")
    }
    private var watching: URL {
      URL(fileURLWithPath: "/tmp/phone-acceptance-\(simulator).watching")
    }

    static func launch(_ app: XCUIApplication, for test: XCTestCase) async throws -> Rehearsal {
      let simulator = try XCTUnwrap(ProcessInfo.processInfo.environment["SIMULATOR_UDID"])
      let rehearsal = Rehearsal(
        work: InteractionPeer(), personal: InteractionPeer(), id: UUID(), simulator: simulator)
      let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
      await rehearsal.work.streamRepliesOnSubmit()
      var ports: [String] = []
      for peer in [rehearsal.work, rehearsal.personal] {
        await peer.history(initial: empty, pages: [:], latest: empty)
        test.addTeardownBlock { await peer.stop() }
        ports.append(String(try await peer.start()))
      }
      app.launchEnvironment = [
        "AGENT_INTERACTION_ID": rehearsal.id.uuidString,
        "AGENT_INTERACTION_ALERTS": "1",
        "AGENT_INTERACTION_PORT": ports.joined(separator: ","),
        "AGENT_INTERACTION_COORDINATOR": [rehearsal.work, rehearsal.personal]
          .map { $0.coordinator.uuidString }.joined(separator: ","),
      ]
      app.launchArguments = ["-notificationsEnabled", "YES"]
      test.addTeardownBlock { @MainActor in
        if app.state != .notRunning { app.terminate() }
        app.launchEnvironment["AGENT_INTERACTION_CLEANUP"] = "1"
        app.launch()
        XCTAssertTrue(app.staticTexts["Interaction fixture cleaned"].waitForExistence(timeout: 10))
        app.terminate()
      }
      test.addTeardownBlock { @MainActor in try await rehearsal.keepSubmitCounts(in: test) }
      test.addUIInterruptionMonitor(withDescription: "Allow notifications") { alert in
        let allow = alert.buttons["Allow"]
        guard allow.exists else { return false }
        allow.tap()
        return true
      }
      app.launch()
      let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
      if allow.waitForExistence(timeout: 3) { allow.tap() }
      let deadline = ContinuousClock.now + .seconds(15)
      while await rehearsal.work.observationCount() == 0 {
        guard ContinuousClock.now < deadline else {
          throw PhoneAcceptanceFailure("The rehearsal app never observed Work's peer")
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      return rehearsal
    }

    /// Asks the host script to push an alert whose body shows the codeword, as the coordinator
    /// would after `stage`.
    func requestPush(stage: String, codeword: String) throws {
      guard FileManager.default.fileExists(atPath: watching.path) else {
        throw PhoneAcceptanceFailure(
          "No push watcher for \(simulator). Run ios/PhoneAcceptance/phone-acceptance.py simulator."
        )
      }
      let request = ["stage": stage, "codeword": codeword, "id": id.uuidString]
      try JSONSerialization.data(withJSONObject: request).write(to: pushRequest, options: .atomic)
    }

    private func keepSubmitCounts(in test: XCTestCase) async throws {
      let counts = [
        "work": await work.submitAttempts(), "personal": await personal.submitAttempts(),
      ]
      let attachment = XCTAttachment(
        data: try JSONSerialization.data(withJSONObject: counts, options: .sortedKeys),
        uniformTypeIdentifier: "public.json")
      attachment.name = "rehearsal-peers.json"
      attachment.lifetime = .keepAlways
      test.add(attachment)
    }
  }
#endif
