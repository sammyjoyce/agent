#if canImport(AppIntentsTesting)
  import AgentCore
  import AppIntentsTesting
  import XCTest

  @MainActor
  final class SiriIntentTests: XCTestCase {
    @available(iOS 27, *)
    private var definitions: IntentDefinitions {
      IntentDefinitions(bundleIdentifier: "dev.jessfraz.Agent")
    }

    func testOpenCoordinatorRoutesWithoutChangingTheDraft() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let app = try await launchWithAWorkDraft()
      capture("siri-1-open-coordinator-before", app)
      let personal = try await coordinator(named: "Personal")

      try await definitions.intents["OpenCoordinatorIntent"].makeIntent(target: personal).run()

      assertShowsPersonalWithTheWorkDraft(app)
      capture("siri-1-open-coordinator-after", app)
    }

    /// The test terminates the app before the query and again before the intent, so the system
    /// starts it for each, with only the environment that the first launch saved.
    func testOpenCoordinatorStartsTheTerminatedApp() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let app = try await launchWithAWorkDraft()
      capture("siri-1-cold-start-before", app)
      XCUIDevice.shared.press(.home)
      let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
      terminate(app)
      let personal = try await coordinator(named: "Personal")
      terminate(app)

      try await definitions.intents["OpenCoordinatorIntent"].makeIntent(target: personal).run()

      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "state \(app.state.rawValue)")
      assertShowsPersonalWithTheWorkDraft(app)
      capture("siri-1-cold-start-after", app)
    }

    /// Refusing keeps the query off the app's own saved coordinators. The second launch names two
    /// ports and one coordinator, so it never has a fixture.
    func testTheQueryRefusesWhenTheFixtureIsUnavailable() async throws {
      try await assertTheQueryRefusesWithoutItsFixture(of: "CoordinatorEntity")
    }

    /// A job query that answered here would have dialed the app's own saved coordinators.
    func testTheJobQueryRefusesWhenTheFixtureIsUnavailable() async throws {
      try await assertTheQueryRefusesWithoutItsFixture(of: "JobEntity")
    }

    /// The test terminates the app before the query and again before the intent, so the system
    /// starts it in the background for each. App Intents Testing returns an intent's value and
    /// not its dialog, so `SiriJobTests` checks the sentence.
    func testRetryInterruptedRunFromTheBackground() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, personal) = try await launchWithJobsThenTerminate()
      let nightlyDeps = try await job(titled: "Nightly deps")
      XCTAssertEqual(try nightlyDeps.coordinator.as(String.self), "Work")
      terminate(app)

      try await definitions.intents["RetryInterruptedRunIntent"].makeIntent(job: nightlyDeps).run()

      let retried = await (work: work.retriedJobs(), personal: personal.retriedJobs())
      XCTAssertEqual(retried.work, ["nightly:deps"])
      XCTAssertEqual(retried.personal, [])
      XCTAssertNotEqual(app.state, .runningForeground, "The retry opened the app")
    }

    func testRetryRefusesAJobWithNoInterruptedRun() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, personal) = try await launchWithJobsThenTerminate()
      let weeklyReport = try await job(titled: "Weekly report")
      terminate(app)

      let intent = definitions.intents["RetryInterruptedRunIntent"].makeIntent(job: weeklyReport)
      do {
        try await intent.run()
        XCTFail("The intent retried a job whose last run completed")
      } catch {
        XCTAssertTrue(
          "\(error)".contains("Weekly report has no interrupted run to retry."), "\(error)")
      }

      let retried = await work.retriedJobs() + personal.retriedJobs()
      XCTAssertEqual(retried, [])
    }

    private func assertTheQueryRefusesWithoutItsFixture(of entity: String) async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let launches: [(environment: [String: String], screen: String)] = [
        (
          [
            "AGENT_INTERACTION_ID": UUID().uuidString, "AGENT_INTERACTION_PORT": "1",
            "AGENT_INTERACTION_COORDINATOR": UUID().uuidString, "AGENT_INTERACTION_CLEANUP": "1",
          ], "Interaction fixture cleaned"
        ),
        (
          ["AGENT_INTERACTION_PORT": "1,2", "AGENT_INTERACTION_COORDINATOR": UUID().uuidString],
          "Interaction fixture unavailable"
        ),
      ]
      let app = XCUIApplication()
      addTeardownBlock { @MainActor in app.terminate() }
      for launch in launches {
        app.launchEnvironment = launch.environment
        app.launch()
        XCTAssertTrue(app.staticTexts[launch.screen].waitForExistence(timeout: 10), launch.screen)
        do {
          let answered = try await definitions.entities[entity].allEntities()
          XCTFail("\(launch.screen): the query answered without its fixture: \(answered)")
        } catch {
          XCTAssertTrue("\(error)".contains("interaction fixture"), "\(launch.screen): \(error)")
        }
        app.terminate()
      }
    }

    /// Launches the app on two fixture peers, Work and Personal, with a draft for Work.
    private func launchWithAWorkDraft() async throws -> XCUIApplication {
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
      let app = try await launch(work: work, personal: personal)
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 10))
      menu.tap()
      let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Work"))
        .firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
      choice.tap()
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(field.wait(for: \.isEnabled, toEqual: true, timeout: 10))
      field.tap()
      field.typeText("Keep this Work draft")
      return app
    }

    /// Launches the app on two fixture peers. Work serves Nightly deps, parked at the restart
    /// limit, and Personal serves Weekly report, whose last run completed. Then the app is sent to
    /// the background and terminated.
    private func launchWithJobsThenTerminate() async throws -> (
      app: XCUIApplication, work: InteractionPeer, personal: InteractionPeer
    ) {
      let work = InteractionPeer()
      let personal = InteractionPeer()
      let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
      let served: [(InteractionPeer, String, String, JobExecutionState)] = [
        (work, "nightly:deps", "Nightly deps", .blocked(.init(message: "restart_limit"))),
        (personal, "weekly:report", "Weekly report", .completed),
      ]
      for (peer, id, title, lastRun) in served {
        await peer.history(initial: empty, pages: [:], latest: empty)
        await peer.serve(jobs: [
          ScheduledJobStatus(
            job: .init(
              cwd: "/workspace/example", id: id,
              model: .init(fast: false, modelId: "example-model", provider: .openai),
              prompt: "An invented prompt.", revision: "example-revision", schedules: [],
              timezone: "America/Los_Angeles", title: title),
            lastRun: JobExecution(
              outputTruncated: false, revision: "example-revision", scheduleId: "example-schedule",
              scheduledAt: 1_700_000_000_000, state: lastRun),
            schedules: [])
        ])
      }
      let app = try await launch(work: work, personal: personal)
      XCUIDevice.shared.press(.home)
      let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
      terminate(app)
      return (app, work, personal)
    }

    /// Launches the app with Work and Personal saved on the two peers. The launch saves its
    /// environment, so a launch that the system starts finds the same fixture.
    private func launch(work: InteractionPeer, personal: InteractionPeer) async throws
      -> XCUIApplication
    {
      continueAfterFailure = false
      executionTimeAllowance = 180
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
      XCTAssertTrue(app.textViews["Message the coordinator"].waitForExistence(timeout: 10))
      return app
    }

    @available(iOS 27, *)
    private func coordinator(named name: String) async throws -> AnyAppEntity {
      let coordinators = try await definitions.entities["CoordinatorEntity"].allEntities()
      let names = try coordinators.map { try $0.name.as(String.self) }
      XCTAssertEqual(names, ["Work", "Personal"])
      return try XCTUnwrap(names.firstIndex(of: name).map { coordinators[$0] }, "\(names)")
    }

    @available(iOS 27, *)
    private func job(titled title: String) async throws -> AnyAppEntity {
      let jobs = try await definitions.entities["JobEntity"].allEntities()
      let titles = try jobs.map { try $0.title.as(String.self) }
      XCTAssertEqual(titles, ["Nightly deps", "Weekly report"])
      return try XCTUnwrap(titles.firstIndex(of: title).map { jobs[$0] }, "\(titles)")
    }

    private func terminate(_ app: XCUIApplication) {
      if app.state != .notRunning { app.terminate() }
      XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "state \(app.state.rawValue)")
    }

    private func assertShowsPersonalWithTheWorkDraft(_ app: XCUIApplication) {
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
      XCTAssertTrue(becomes(menu, "label CONTAINS %@", "Personal"), menu.label)
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(
        becomes(field, "value == %@", "Keep this Work draft"), String(describing: field.value))
      let recipient = app.staticTexts["recipientLine"]
      XCTAssertTrue(becomes(recipient, "label == %@", "This draft goes to Work"), recipient.label)
      XCTAssertTrue(
        app.staticTexts["Personal's latest invented reply"].waitForExistence(timeout: 10))
    }

    private func becomes(_ element: XCUIElement, _ format: String, _ value: String) -> Bool {
      let expectation = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: format, value), object: element)
      return XCTWaiter().wait(for: [expectation], timeout: 10) == .completed
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
#endif
