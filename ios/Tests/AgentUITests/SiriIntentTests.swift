#if canImport(AppIntentsTesting)
  import AgentCore
  import AppIntentsTesting
  import Network
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

    func testOpenJobStartsTheTerminatedAppOnTheJob() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, _, _) = try await launchWithJobs()
      try chooseWorkAndType("Keep this Work draft", in: app)
      XCUIDevice.shared.press(.home)
      let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
      terminate(app)
      let weeklyReport = try await job(titled: "Weekly report")
      terminate(app)

      try await definitions.intents["OpenJobIntent"].makeIntent(target: weeklyReport).run()

      XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "state \(app.state.rawValue)")
      XCTAssertTrue(
        app.navigationBars["Weekly report"].waitForExistence(timeout: 15), app.debugDescription)
      let state = app.descendants(matching: .any)["jobRunState"]
      XCTAssertTrue(becomes(state, "label CONTAINS %@", "Completed"), app.debugDescription)
      capture("siri-open-job-cold-start", app)
      assertBackShowsTheFeed(app, from: "Weekly report")
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(becomes(menu, "label BEGINSWITH %@", "Work"), menu.label)
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(
        becomes(field, "value == %@", "Keep this Work draft"), String(describing: field.value))
    }

    func testOpenJobFromTheForegroundKeepsTheFeedAndTheDraft() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, _, _) = try await launchWithJobs()
      try chooseWorkAndType("Keep this Work draft", in: app)
      let weeklyReport = try await job(titled: "Weekly report")

      try await definitions.intents["OpenJobIntent"].makeIntent(target: weeklyReport).run()

      XCTAssertTrue(
        app.navigationBars["Weekly report"].waitForExistence(timeout: 15), app.debugDescription)
      capture("siri-open-job-foreground", app)
      assertBackShowsTheFeed(app, from: "Weekly report")
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(becomes(menu, "label BEGINSWITH %@", "Work"), menu.label)
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(
        becomes(field, "value == %@", "Keep this Work draft"), String(describing: field.value))
    }

    func testOpenJobSaysWhenTheJobIsNoLongerOnItsCoordinator() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, _) = try await launchWithJobs()
      let nightlyDeps = try await job(titled: "Nightly deps")
      await work.serve(jobs: [scheduledJob("docs:sweep", "Docs sweep", .completed)])
      terminate(app)

      let intent = definitions.intents["OpenJobIntent"].makeIntent(target: nightlyDeps)
      do {
        try await intent.run()
        XCTFail("The intent opened a job that Work no longer has")
      } catch {
        XCTAssertTrue(
          "\(error)".contains("The scheduled job nightly:deps is no longer on Work."), "\(error)")
      }
    }

    func testOnscreenEntitiesMatchWhatEachScreenShows() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, _, _) = try await launchWithJobs()
      let work = try await coordinator(named: "Work").identifier.instanceIdentifier
      let nightlyDeps = try await job(titled: "Nightly deps").identifier.instanceIdentifier
      let coordinators = definitions.entities["CoordinatorEntity"]
      let jobs = definitions.entities["JobEntity"]

      XCTAssertTrue(app.buttons["scopeMenu"].label.contains("All coordinators"))
      try await assertAnnotations(of: coordinators, become: [], "the feed of every coordinator")
      try chooseWorkAndType(nil, in: app)
      try await assertAnnotations(of: coordinators, become: [work], "Work's feed")
      try await assertAnnotations(of: jobs, become: [], "Work's feed")
      capture("siri-onscreen-work-feed", app)

      app.buttons["Connection"].tap()
      try await assertAnnotations(of: coordinators, become: [], "Connection over the feed")
      app.buttons["Jobs and work"].tap()
      XCTAssertTrue(
        app.buttons["job-nightly:deps"].waitForExistence(timeout: 15), app.debugDescription)
      try await assertAnnotations(of: jobs, become: [nightlyDeps], "Work's Jobs and work")
      capture("siri-onscreen-jobs-and-work", app)

      app.buttons["job-nightly:deps"].tap()
      XCTAssertTrue(app.navigationBars["Nightly deps"].waitForExistence(timeout: 15))
      try await assertAnnotations(of: jobs, become: [nightlyDeps], "the job's screen")
      capture("siri-onscreen-job", app)

      assertBackStepsToTheFeed(app, from: "Nightly deps", through: "Work · Jobs and work")
      try await assertAnnotations(of: jobs, become: [], "Work's feed after Back")
      try await assertAnnotations(of: coordinators, become: [work], "Work's feed after Back")

      let weeklyReport = try await job(titled: "Weekly report")
      try await definitions.intents["OpenJobIntent"].makeIntent(target: weeklyReport).run()
      XCTAssertTrue(app.navigationBars["Weekly report"].waitForExistence(timeout: 15))
      let personalJob = weeklyReport.identifier.instanceIdentifier
      try await assertAnnotations(of: jobs, become: [personalJob], "the opened job's screen")
      try await assertAnnotations(of: coordinators, become: [], "the opened job over the feed")
    }

    /// App Intents Testing confirms a confirmation by itself, so these tests check what follows
    /// it. `testShortcutsAsksBeforeItSends` answers the confirmation the system shows.
    /// The app is terminated before the intent, so the system starts it in the background.
    func testSendMessageDeliversFromTheBackgroundAndKeepsTheDraft() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, personal) = try await launchWithAWorkDraft(origins: ["siri"])
      goHome()
      terminate(app)
      let workEntity = try await coordinator(named: "Work")
      terminate(app)

      let sent = try await send("Check the build", to: workEntity)

      XCTAssertEqual(sent.value, "delivered")
      let submits = await work.submitRequests()
      XCTAssertEqual(submits.map(\.text), ["Check the build"])
      XCTAssertEqual(submits.map(\.origin), [.siri])
      let elsewhere = await personal.submitRequests()
      XCTAssertEqual(elsewhere.map(\.text), [], "Personal got a message")
      XCTAssertNotEqual(app.state, .runningForeground, "Send Message opened the app")
      app.launch()
      assertTheWorkDraftIsKept(app)
      capture("siri-send-delivered-draft-kept", app)
    }

    /// A held reply is a coordinator whose answer is lost. Asking again writes the saved copy
    /// under its own input ID, so the coordinator's deduplication sees one input.
    func testSendMessageAsksAgainWithTheSavedCopy() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, _) = try await launchWithAWorkDraft(origins: ["siri"])
      goHome()
      terminate(app)
      let workEntity = try await coordinator(named: "Work")
      await work.holdSubmits()

      let first = try await send("Rotate the Work logs", to: workEntity)
      XCTAssertEqual(first.value, "saved")
      await work.releaseSubmits()
      let again = try await send("Rotate the Work logs", to: workEntity)

      XCTAssertTrue(["delivered", "alreadyDelivered"].contains(again.value), again.value)
      let submits = await work.submitRequests()
      XCTAssertGreaterThanOrEqual(submits.count, 2, "\(submits)")
      XCTAssertEqual(Set(submits.map(\.inputId)).count, 1, "\(submits)")
      XCTAssertEqual(Set(submits.map(\.text)), ["Rotate the Work logs"])
    }

    /// A saved copy waits out the 8 second deadline. A failure answers before it.
    func testSendMessageSaysWhenTheCoordinatorFailsTheSend() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, _) = try await launchWithAWorkDraft(origins: ["siri"])
      goHome()
      terminate(app)
      let workEntity = try await coordinator(named: "Work")
      await work.failSubmits("The coordinator execution host is offline")

      let sent = try await send("Check the build", to: workEntity)

      XCTAssertEqual(sent.value, "refused")
      XCTAssertLessThan(sent.took, .seconds(7), "The failure waited for the deadline")
      let submits = await work.submitRequests()
      XCTAssertEqual(submits.map(\.text), ["Check the build"])
    }

    func testSendMessageNeverSendsACommand() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, personal) = try await launchWithAWorkDraft(origins: ["siri"])
      goHome()
      let workEntity = try await coordinator(named: "Work")

      for command in ["/status", " /goal clear", "?"] {
        let sent = try await send(command, to: workEntity)
        XCTAssertEqual(sent.value, "refusal.command", command)
      }

      let submits = await work.submitRequests() + personal.submitRequests()
      XCTAssertEqual(submits.map(\.text), [])
      app.activate()
      assertTheWorkDraftIsKept(app)
    }

    func testSendMessageNeedsTheSiriOrigin() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      let (app, work, _) = try await launchWithAWorkDraft(origins: ["cli", "ios"])
      goHome()
      terminate(app)
      let workEntity = try await coordinator(named: "Work")

      let sent = try await send("Check the build", to: workEntity)

      XCTAssertEqual(sent.value, "notSent.notAdvertised")
      let submits = await work.submitRequests()
      XCTAssertEqual(submits.map(\.text), [])
    }

    /// Runs the App Shortcut from the Shortcuts app, which shows the confirmation and the
    /// outcome. Cancel sends nothing, and Send sends one copy.
    func testShortcutsAsksBeforeItSends() async throws {
      let (app, work, personal) = try await launchWithAWorkDraft(origins: ["siri"])
      goHome()
      let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
      shortcuts.launch()
      var log: [String] = []
      defer { attach(log, named: "shortcuts-steps") }

      let asked = try await runSendMessageShortcut(
        "Check the build", to: "Work", answering: "Cancel", in: shortcuts, log: &log)
      capture("shortcuts-send-confirmation", shortcuts)
      XCTAssertTrue(
        asked.contains { $0.contains("Work") && $0.contains("Check the build") }, "\(asked)")
      try await Task.sleep(for: .seconds(3))
      var submits = await work.submitRequests() + personal.submitRequests()
      XCTAssertEqual(submits.map(\.text), [], "Cancel sent a message")

      _ = try await runSendMessageShortcut(
        "Check the build", to: "Work", answering: "Send", in: shortcuts, log: &log)
      let outcome = shortcuts.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "Sent to Work.")
      ).firstMatch
      XCTAssertTrue(outcome.waitForExistence(timeout: 20), shortcuts.debugDescription)
      capture("shortcuts-send-outcome", shortcuts)
      submits = await work.submitRequests()
      XCTAssertEqual(submits.map(\.text), ["Check the build"])
      XCTAssertEqual(submits.map(\.origin), [.siri])
      let elsewhere = await personal.submitRequests()
      XCTAssertEqual(elsewhere.map(\.text), [])
      app.activate()
      assertTheWorkDraftIsKept(app)
    }

    /// Runs against a private coordinator that `runtime/test/fixtures/siri-world.ts` serves: the
    /// real service, Pi and bridge with a synthetic model. Its runner passes
    /// `TEST_RUNNER_AGENT_SIRI_WORLD`, and the test is skipped without it.
    func testSendMessageToAPrivateCoordinator() async throws {
      guard #available(iOS 27, *) else { throw XCTSkip("App Intents Testing needs iOS 27") }
      guard let world = SiriWorld(ProcessInfo.processInfo.environment["AGENT_SIRI_WORLD"]) else {
        throw XCTSkip("Needs a private coordinator from runtime/test/fixtures/siri-world.ts")
      }
      let app = try launch(ports: [world.relay], coordinators: [world.coordinator])
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(field.wait(for: \.isEnabled, toEqual: true, timeout: 15))
      field.tap()
      field.typeText("Keep this Work draft")
      goHome()
      terminate(app)
      let work = try await coordinator(named: "Work", among: ["Work"])
      terminate(app)

      let delivered = try await send("Check the build", to: work)
      XCTAssertEqual(delivered.value, "delivered")
      var state = try await world.state()
      XCTAssertEqual(state.generations["Check the build"], 1)
      XCTAssertEqual(state.submits.map(\.origin), ["siri"])

      try await world.loseNextSubmitReply()
      let saved = try await send("Rotate the Work logs", to: work)
      XCTAssertEqual(saved.value, "saved")
      let again = try await send("Rotate the Work logs", to: work)
      XCTAssertTrue(["delivered", "alreadyDelivered"].contains(again.value), again.value)
      state = try await world.state()
      let rotations = state.submits.filter { $0.text == "Rotate the Work logs" }
      XCTAssertEqual(Set(rotations.map(\.inputId)).count, 1, "\(rotations)")
      XCTAssertEqual(rotations.map(\.replyLost).filter { $0 }.count, 1, "\(rotations)")
      XCTAssertEqual(state.generations["Rotate the Work logs"], 1)
      XCTAssertEqual(state.generations["Check the build"], 1)

      app.launch()
      XCTAssertTrue(
        becomes(field, "value == %@", "Keep this Work draft"), String(describing: field.value))
      capture("siri-send-private-coordinator-draft-kept", app)
    }

    private struct Sent {
      /// The intent's value, or `threw: <error>`.
      let value: String
      let took: Duration
    }

    @available(iOS 27, *)
    private func send(_ text: String, to coordinator: AnyAppEntity) async throws -> Sent {
      let intent = definitions.intents["SendMessageIntent"].makeIntent(
        message: text, coordinator: coordinator)
      let started = ContinuousClock.now
      do {
        let value: String = try await intent.run().value
        return Sent(value: value, took: .now - started)
      } catch { return Sent(value: "threw: \(error)", took: .now - started) }
    }

    /// Runs the Send Message App Shortcut in the Shortcuts app, answers its prompts, taps
    /// `answer` on the confirmation, and returns the confirmation's texts.
    private func runSendMessageShortcut(
      _ message: String, to coordinator: String, answering answer: String,
      in shortcuts: XCUIApplication, log: inout [String]
    ) async throws -> [String] {
      let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      let any = { (app: XCUIApplication, label: String) in
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
          .firstMatch
      }
      var typed = false
      var chose = false
      var started = false
      let deadline = ContinuousClock.now + .seconds(90)
      while ContinuousClock.now < deadline {
        let texts =
          (shortcuts.staticTexts.allElementsBoundByIndex
          + springboard.staticTexts.allElementsBoundByIndex).map(\.label)
        let buttons =
          (shortcuts.buttons.allElementsBoundByIndex
          + springboard.buttons.allElementsBoundByIndex).map(\.label)
        log.append("texts \(texts)\nbuttons \(buttons)")
        let confirm = [shortcuts.buttons[answer], springboard.buttons[answer]]
          .first { $0.exists && $0.isHittable }
        if typed || chose, let confirm, texts.contains(where: { $0.contains(message) }) {
          capture("shortcuts-confirmation-\(answer.lowercased())", shortcuts)
          log.append("tapped \(answer)")
          confirm.tap()
          return texts
        }
        if let field = [
          shortcuts.textFields.firstMatch, springboard.textFields.firstMatch,
          shortcuts.textViews.firstMatch, springboard.textViews.firstMatch,
        ]
        .first(where: { $0.exists && $0.isHittable }), !typed {
          field.tap()
          field.typeText(message)
          typed = true
          log.append("typed the message")
          for done in ["Done", "Continue", "Next"] {
            let button = [shortcuts.buttons[done], springboard.buttons[done]]
              .first { $0.exists && $0.isHittable }
            if let button {
              button.tap()
              log.append("tapped \(done)")
              break
            }
          }
          continue
        }
        if !chose, started,
          let option = [any(shortcuts, coordinator), any(springboard, coordinator)]
            .first(where: { $0.exists && $0.isHittable })
        {
          option.tap()
          chose = true
          log.append("chose \(coordinator)")
          continue
        }
        if !started {
          for label in ["Continue", "Not Now", "OK", "Get Started"] {
            let button = shortcuts.buttons[label]
            if button.exists && button.isHittable {
              button.tap()
              log.append("dismissed \(label)")
            }
          }
          let tile = any(shortcuts, "Send Message")
          if tile.exists && tile.isHittable {
            tile.tap()
            started = true
            log.append("tapped the Send Message tile")
          } else {
            let folder = any(shortcuts, "Beep Boop")
            if folder.exists && folder.isHittable {
              folder.tap()
              log.append("opened Beep Boop")
            }
          }
        }
        try await Task.sleep(for: .seconds(1))
      }
      attach(log, named: "shortcuts-steps-timeout")
      add(XCTAttachment(string: shortcuts.debugDescription))
      add(XCTAttachment(string: springboard.debugDescription))
      XCTFail("The Shortcuts app showed no \(answer) confirmation for \(message)")
      return []
    }

    private func attach(_ lines: [String], named name: String) {
      let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
      attachment.name = name
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    private func goHome() {
      XCUIDevice.shared.press(.home)
      let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")
      XCTAssertTrue(home.wait(for: .runningForeground, timeout: 10))
    }

    private func assertTheWorkDraftIsKept(_ app: XCUIApplication) {
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
      XCTAssertTrue(becomes(menu, "label BEGINSWITH %@", "Work"), menu.label)
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(
        becomes(field, "value == %@", "Keep this Work draft"), String(describing: field.value))
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
      try await launchWithAWorkDraft(origins: nil).app
    }

    /// Launches the app on Work and Personal, which accept `origins`, with a draft for Work.
    private func launchWithAWorkDraft(origins: [String]?) async throws -> (
      app: XCUIApplication, work: InteractionPeer, personal: InteractionPeer
    ) {
      let work = InteractionPeer()
      let personal = InteractionPeer()
      await work.acceptOrigins(origins)
      await personal.acceptOrigins(origins)
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
      return (app, work, personal)
    }

    private func launchWithJobs() async throws -> (
      app: XCUIApplication, work: InteractionPeer, personal: InteractionPeer
    ) {
      let work = InteractionPeer()
      let personal = InteractionPeer()
      let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
      let served: [(InteractionPeer, ScheduledJobStatus)] = [
        (
          work,
          scheduledJob("nightly:deps", "Nightly deps", .blocked(.init(message: "restart_limit")))
        ),
        (personal, scheduledJob("weekly:report", "Weekly report", .completed)),
      ]
      for (peer, job) in served {
        await peer.history(initial: empty, pages: [:], latest: empty)
        await peer.serve(jobs: [job])
      }
      return (try await launch(work: work, personal: personal), work, personal)
    }

    private func scheduledJob(_ id: String, _ title: String, _ lastRun: JobExecutionState)
      -> ScheduledJobStatus
    {
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
    }

    private func launchWithJobsThenTerminate() async throws -> (
      app: XCUIApplication, work: InteractionPeer, personal: InteractionPeer
    ) {
      let (app, work, personal) = try await launchWithJobs()
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
      var ports: [UInt16] = []
      for peer in [work, personal] {
        addTeardownBlock { await peer.stop() }
        ports.append(try await peer.start())
      }
      return try launch(
        ports: ports, coordinators: [work, personal].map { $0.coordinator.uuidString })
    }

    /// Launches the app with one saved coordinator for each loopback port, Work then Personal.
    private func launch(ports: [UInt16], coordinators: [String]) throws -> XCUIApplication {
      continueAfterFailure = false
      executionTimeAllowance = 180
      let app = XCUIApplication()
      app.launchEnvironment["AGENT_INTERACTION_ID"] = UUID().uuidString
      app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.map(String.init)
        .joined(separator: ",")
      app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] =
        coordinators
        .joined(separator: ",")
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
    private func coordinator(named name: String, among saved: [String] = ["Work", "Personal"])
      async throws -> AnyAppEntity
    {
      let coordinators = try await definitions.entities["CoordinatorEntity"].allEntities()
      let names = try coordinators.map { try $0.name.as(String.self) }
      XCTAssertEqual(names, saved)
      return try XCTUnwrap(names.firstIndex(of: name).map { coordinators[$0] }, "\(names)")
    }

    @available(iOS 27, *)
    private func job(titled title: String) async throws -> AnyAppEntity {
      let jobs = try await definitions.entities["JobEntity"].allEntities()
      let titles = try jobs.map { try $0.title.as(String.self) }
      XCTAssertEqual(titles, ["Nightly deps", "Weekly report"])
      return try XCTUnwrap(titles.firstIndex(of: title).map { jobs[$0] }, "\(titles)")
    }

    private func chooseWorkAndType(_ draft: String?, in app: XCUIApplication) throws {
      let menu = app.buttons["scopeMenu"]
      XCTAssertTrue(menu.waitForExistence(timeout: 10))
      menu.tap()
      let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Work"))
        .firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
      choice.tap()
      XCTAssertTrue(becomes(menu, "label BEGINSWITH %@", "Work"), menu.label)
      guard let draft else { return }
      let field = app.textViews["Message the coordinator"]
      XCTAssertTrue(field.wait(for: \.isEnabled, toEqual: true, timeout: 10))
      field.tap()
      field.typeText(draft)
    }

    private func assertBackStepsToTheFeed(
      _ app: XCUIApplication, from job: String, through jobsAndWork: String
    ) {
      var shown = job
      for screen in [jobsAndWork, "Connection"] {
        app.navigationBars[shown].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars[screen].waitForExistence(timeout: 5), app.debugDescription)
        shown = screen
      }
      app.buttons["dismissConnection"].tap()
      XCTAssertTrue(app.buttons["scopeMenu"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @available(iOS 27, *)
    private func assertAnnotations(
      of entity: AppEntityDefinition, become identifiers: Set<String>, _ screen: String
    ) async throws {
      let deadline = ContinuousClock.now + .seconds(10)
      var shown: Set<String> = []
      repeat {
        shown = Set(try await entity.viewAnnotations().map(\.entity.identifier.instanceIdentifier))
        if shown == identifiers { return }
        try await Task.sleep(for: .milliseconds(250))
      } while ContinuousClock.now < deadline
      XCTFail("\(screen): annotations \(shown), expected \(identifiers)")
    }

    private func assertBackShowsTheFeed(_ app: XCUIApplication, from job: String) {
      app.navigationBars[job].buttons.element(boundBy: 0).tap()
      XCTAssertTrue(app.buttons["scopeMenu"].waitForExistence(timeout: 5), app.debugDescription)
      XCTAssertFalse(app.navigationBars["Connection"].exists, app.debugDescription)
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

  /// A private coordinator that `runtime/test/fixtures/siri-world.ts` serves on loopback, read
  /// and steered through its control port.
  private struct SiriWorld {
    let relay: UInt16
    let control: UInt16
    let coordinator: String

    struct Submit: Decodable {
      let inputId: String
      let text: String
      let origin: String?
      let replyLost: Bool
    }
    struct State: Decodable {
      let submits: [Submit]
      /// Model requests per scripted text. More than one for a text is a second generation.
      let generations: [String: Int]
    }

    /// Reads `<relay port>,<control port>,<coordinator ID>`.
    init?(_ value: String?) {
      guard let parts = value?.split(separator: ","), parts.count == 3,
        let relay = UInt16(parts[0]), let control = UInt16(parts[1])
      else { return nil }
      (self.relay, self.control, coordinator) = (relay, control, String(parts[2]))
    }

    func state() async throws -> State {
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return try decoder.decode(State.self, from: try await request("GET", "/state"))
    }

    func loseNextSubmitReply() async throws {
      _ = try await request("POST", "/lose-next-submit-reply")
    }

    /// HTTP/1.0 over Network.framework, which App Transport Security leaves alone.
    private func request(_ method: String, _ path: String) async throws -> Data {
      let connection = NWConnection(
        host: .ipv4(.loopback), port: try XCTUnwrap(NWEndpoint.Port(rawValue: control)),
        using: .tcp)
      defer { connection.cancel() }
      connection.start(queue: .global())
      let head = Data(
        "\(method) \(path) HTTP/1.0\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n\r\n".utf8)
      try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
        connection.send(
          content: head,
          completion: .contentProcessed { error in
            if let error { done.resume(throwing: error) } else { done.resume() }
          })
      }
      var reply = Data()
      while true {
        let (chunk, complete) = try await withCheckedThrowingContinuation {
          (done: CheckedContinuation<(Data?, Bool), any Error>) in
          connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            data, _, complete, error in
            if let error {
              done.resume(throwing: error)
            } else {
              done.resume(returning: (data, complete))
            }
          }
        }
        reply.append(chunk ?? Data())
        if complete { break }
      }
      let separator = Data("\r\n\r\n".utf8)
      let body = try XCTUnwrap(reply.range(of: separator), "No HTTP reply from the world")
      let status = String(decoding: reply[..<body.lowerBound], as: UTF8.self)
      XCTAssertTrue(status.hasPrefix("HTTP/1.1 2") || status.hasPrefix("HTTP/1.0 2"), status)
      return reply[body.upperBound...]
    }
  }
#endif
