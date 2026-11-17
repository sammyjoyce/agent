import XCTest

/// Send clears the composer at once, the keyboard stays up, and sent text never comes back.
@MainActor
final class ComposerRecurrenceTests: XCTestCase {
  private func begin() async throws -> PhoneSession {
    let session = try await PhoneSession.open(for: self, allowance: 600)
    try session.beginScenario()
    return session
  }

  func testTwoConsecutiveSendsKeepTheKeyboardUp() async throws {
    let session = try await begin()
    session.type(session.message("first of two sends in a row, reply with just ok"))
    try session.send("consecutive-first")
    session.type(session.message("second of two sends in a row, reply with just ok"))
    try session.send("consecutive-second")
  }

  func testSentTextStaysGoneAcrossHomeAndAnAppSwitch() async throws {
    let session = try await begin()
    session.type(session.message("use exec to run sleep 20, then reply with just ok"))
    let sent = try session.send("switch-first")
    guard session.stopResponse.waitForExistence(timeout: 30) else {
      throw PhoneAcceptanceFailure("No reply became active after the first Send")
    }
    try session.pressHome()
    try session.returnToApp()
    try session.switchToSettingsAndBack()
    try session.checkDraft("switch-returned", holds: nil, sent: sent.text)
    session.type(session.message("back from Settings, reply with just ok"))
    try session.send("switch-second")
  }

  func testALongMultilineDraftLeavesNothingBehind() async throws {
    let session = try await begin()
    let lines =
      [session.message("a multiline check, reply with just ok")]
      + (1...7).map { "line \($0) of a multiline check" }
    try session.typeLines(lines)
    let sent = try session.send("multiline")
    try await session.checkRehearsalSubmit("multiline", draft: sent.text)
  }

  func testIdenticalNewerTypingSurvivesAdmission() async throws {
    let session = try await begin()
    let text = session.message("identical typing check, reply with just ok")
    session.type(text)
    let sent = try session.tapSend()
    let afterSend = session.snapshotComposer()
    let newer = session.type(text)
    try session.checkSend(afterSend, label: "identical-sent", sent: sent)
    try session.waitForAdmission(of: sent.text, timeout: 30)
    try session.checkDraft("identical-newer-kept", holds: newer, sent: nil)
    try session.clearRunnerDraft()
  }

  func testANewerDraftSurvivesARelaunchAndSentTextDoesNot() async throws {
    let session = try await begin()
    session.type(session.message("relaunch check, reply with just ok"))
    let sent = try session.send("relaunch-sent")
    let newer = session.type(session.message("a newer draft that is never sent"))
    try session.terminate()
    try session.relaunch()
    try session.checkDraft("relaunch-newer-kept", holds: newer, sent: sent.text)
    try session.clearRunnerDraft()
  }
}
