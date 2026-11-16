import XCTest

/// A completed main-chat reply and a mid-job notify_user notice reach the phone as visible alerts.
@MainActor
final class NotificationDeliveryTests: XCTestCase {
  private let alertDeadline: TimeInterval = 180

  private func begin() async throws -> PhoneSession {
    let session = try await PhoneSession.open(for: self, allowance: 900)
    try session.beginScenario()
    return session
  }

  func testRegistration() async throws {
    let configuration = try PhoneAcceptanceConfiguration.current()
    try XCTSkipIf(
      configuration.mode == .rehearsal,
      "The simulator has no APNs, so only the phone can show its registration")
    let session = try await PhoneSession.open(for: self, allowance: 300)
    let app = session.app
    app.buttons["Connection"].tap()
    let toggle = app.switches["Main-chat updates"]
    var swipes = 0
    while !(toggle.exists && toggle.isHittable) && swipes < 8 {
      app.swipeUp()
      swipes += 1
    }
    let hints = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", configuration.coordinator + ":")
    ).allElementsBoundByIndex.map(\.label)
    let evidence = RegistrationEvidence(
      mainChatUpdates: toggle.exists && toggle.value as? String == "1", coordinatorHints: hints,
      attachment: "registration-notifications")
    keep(XCUIScreen.main.screenshot(), as: evidence.attachment)
    app.buttons["dismissConnection"].tap()
    try check(
      evidence, kind: "registration", name: configuration.coordinator, problems: evidence.problems)
  }

  func testBackgroundReply() async throws {
    let session = try await begin()
    let codeword = session.codeword()
    session.type(session.message("reply with just the word \(codeword)"))
    try session.tapSend()
    try session.pressHome()
    try session.expectAlert(stage: "background-reply", codeword: codeword)
    let (banner, _) = session.awaitBanner(codeword, timeout: alertDeadline)
    let (listed, _) = session.findInNotificationCenter(codeword)
    XCUIDevice.shared.press(.home)
    try session.checkAlerts([banner, listed], expecting: .background)
  }

  func testMidJobNotice() async throws {
    let session = try await begin()
    let codeword = session.codeword()
    session.type(
      session.message(
        "start a new background task with delegate_task (new_task true, new_task_reason \"phone alert check\") whose worker first calls notify_user with the text \(codeword), then uses exec to run sleep 120, then finishes without changing any files. Reply with just the word started."
      ))
    try session.tapSend()
    let draft = session.type("\(session.configuration.run) keep draft")
    try session.pressHome()
    try session.expectAlert(stage: "mid-job", codeword: codeword)
    var (banner, element) = session.awaitBanner(codeword, timeout: alertDeadline)
    let observations: [AlertEvidence]
    if banner.alertLabel != nil, element.exists, element.isHittable {
      session.tap(&banner, element)
      observations = [banner]
    } else {
      var (listed, entry) = session.findInNotificationCenter(codeword)
      if listed.alertLabel != nil { session.tap(&listed, entry) }
      observations = [banner, listed]
    }
    try session.checkAlerts(observations, expecting: .background)
    try session.waitForForeground()
    guard
      session.poll(timeout: 10, until: { session.scopeTitle == session.configuration.coordinator })
    else {
      throw PhoneAcceptanceFailure(
        "The alert opened \(session.scopeTitle ?? "no conversation"), not \(session.configuration.coordinator)"
      )
    }
    try session.checkDraft("mid-job-draft-kept", holds: draft, sent: nil)
    try session.clearRunnerDraft()
  }

  func testTerminatedDelivery() async throws {
    let session = try await begin()
    let codeword = session.codeword()
    session.type(
      session.message("use exec to run sleep 30, then reply with just the word \(codeword)"))
    try session.tapSend()
    guard session.stopResponse.waitForExistence(timeout: 60) else {
      throw PhoneAcceptanceFailure("The coordinator never showed it was working on the message")
    }
    try session.terminate()
    try session.expectAlert(stage: "terminated", codeword: codeword)
    let (banner, _) = session.awaitBanner(codeword, timeout: alertDeadline)
    let (listed, _) = session.findInNotificationCenter(codeword)
    XCUIDevice.shared.press(.home)
    try session.checkAlerts([banner, listed], expecting: .terminated)
  }
}
