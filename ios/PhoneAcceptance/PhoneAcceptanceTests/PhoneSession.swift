import XCTest

/// The target app under one configuration, and every guard the runner keeps before it types or
/// sends. Scenarios reach the app only through this type.
@MainActor
final class PhoneSession {
  let configuration: PhoneAcceptanceConfiguration
  let app: XCUIApplication
  private unowned let test: XCTestCase
  /// The title before the runner chose the coordinator, which teardown shows again.
  private var originalScope: String?
  #if targetEnvironment(simulator)
    private var rehearsal: Rehearsal?
  #endif
  /// Check numbers count up across the whole run, so no two messages read alike.
  private static var checks = 0

  private init(configuration: PhoneAcceptanceConfiguration, test: XCTestCase) {
    self.configuration = configuration
    self.app = XCUIApplication(bundleIdentifier: configuration.app)
    self.test = test
  }

  /// Attaches to the installed app, or launches the rehearsal, and registers the teardown that
  /// clears the runner's drafts and shows the original scope again.
  static func open(for test: XCTestCase, allowance: TimeInterval) async throws -> PhoneSession {
    let session = PhoneSession(configuration: try .current(), test: test)
    test.continueAfterFailure = false
    test.executionTimeAllowance = allowance
    switch session.configuration.mode {
    case .attach:
      session.app.activate()
    case .rehearsal:
      #if targetEnvironment(simulator)
        session.rehearsal = try await Rehearsal.launch(session.app, for: test)
      #else
        throw PhoneAcceptanceFailure("The rehearsal runs only on a simulator")
      #endif
    }
    test.addTeardownBlock { @MainActor in try session.restore() }
    guard session.composer.waitForExistence(timeout: 30) else {
      throw PhoneAcceptanceFailure("\(session.configuration.app) showed no composer")
    }
    return session
  }

  var composer: XCUIElement { app.textViews["Message the coordinator"] }
  var stopResponse: XCUIElement { app.buttons["Stop response"] }
  private var springboard: XCUIApplication {
    XCUIApplication(bundleIdentifier: "com.apple.springboard")
  }
  private var composerSurface: XCUIElement {
    app.descendants(matching: .any).matching(identifier: "messageComposer").firstMatch
  }
  private var scopeMenu: XCUIElement { app.buttons["scopeMenu"] }
  private var recipientLine: XCUIElement { app.staticTexts["recipientLine"] }
  private var sendButton: XCUIElement {
    app.buttons.matching(NSPredicate(format: "label IN %@", ["Send message", "Queue follow-up"]))
      .firstMatch
  }
  /// What the empty composer reads in the coordinator's conversation, in Steer and Follow-up.
  private var placeholders: [String] {
    let name = configuration.coordinator
    return ["Message \(name)", "Queue a follow-up for \(name)"]
  }

  // MARK: Scope

  /// The scope the title shows: a coordinator's name, or All coordinators.
  var scopeTitle: String? {
    scopeMenu.exists ? scopeMenu.label.components(separatedBy: ", ").first : nil
  }

  /// Shows the coordinator's conversation through the title menu.
  private func selectCoordinator() throws {
    guard scopeMenu.waitForExistence(timeout: 15) else {
      throw PhoneAcceptanceFailure(
        "The app shows no coordinator menu, so it cannot show \(configuration.coordinator) alone")
    }
    if originalScope == nil { originalScope = scopeTitle }
    try choose(configuration.coordinator)
  }

  private func choose(_ scope: String) throws {
    guard scopeTitle != scope else { return }
    scopeMenu.tap()
    let row = app.buttons.matching(
      NSPredicate(format: "label == %@ OR label BEGINSWITH %@", scope, scope + ", ")
    ).firstMatch
    guard row.waitForExistence(timeout: 5) else {
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).tap()
      throw PhoneAcceptanceFailure("The coordinator menu offers no \(scope)")
    }
    row.tap()
    guard poll(timeout: 5, until: { scopeTitle == scope }) else {
      throw PhoneAcceptanceFailure(
        "The title shows \(scopeTitle ?? "nothing") after choosing \(scope)")
    }
  }

  /// Shows the coordinator's conversation and refuses to go on over any draft.
  func beginScenario() throws {
    try selectCoordinator()
    try requireEmptyComposer()
  }

  // MARK: Guards

  /// Refuses to start a scenario over any draft: the composer must show its placeholder.
  private func requireEmptyComposer() throws {
    let value = composer.value as? String
    guard let value, placeholders.contains(value) else {
      throw PhoneAcceptanceFailure(
        "Refused to type over a draft: the composer holds \(String(reflecting: value))")
    }
  }

  /// Refuses a Send unless the runner typed the draft and only the coordinator can receive it.
  private func requireSendToCoordinator(_ draft: String) throws {
    guard draft.hasPrefix(configuration.run + " ") else {
      throw PhoneAcceptanceFailure(
        "Refused to send a draft the runner did not type: \(String(reflecting: draft))")
    }
    let expected = "To \(configuration.coordinator)"
    if recipientLine.exists, recipientLine.label != expected {
      throw PhoneAcceptanceFailure(
        "Refused to send: the recipient line reads \(String(reflecting: recipientLine.label)), not \(expected)"
      )
    }
    guard scopeTitle == configuration.coordinator else {
      throw PhoneAcceptanceFailure(
        "Refused to send: the title shows \(scopeTitle ?? "no coordinator"), not \(configuration.coordinator)"
      )
    }
  }

  // MARK: Typing and sending

  /// A message that starts with the run label and check number.
  func message(_ ask: String) -> String {
    Self.checks += 1
    return "\(configuration.run) phone check \(Self.checks): \(ask)"
  }

  /// Types `text` and returns the draft the composer then holds, which autocorrection can make
  /// differ from what was typed.
  @discardableResult func type(_ text: String) -> String {
    if !app.keyboards.firstMatch.exists { composer.tap() }
    composer.typeText(text)
    return composer.value as? String ?? ""
  }

  /// Types a draft of several lines and refuses to go on unless each Return made a new line in
  /// the composer. A hardware Return ends editing instead, and none of them sends.
  func typeLines(_ lines: [String]) throws {
    let value = type(lines.joined(separator: "\n"))
    let held = value.split(separator: "\n", omittingEmptySubsequences: false)
    guard held.count == lines.count, value.hasPrefix(configuration.run + " ") else {
      throw PhoneAcceptanceFailure(
        "A Return did not make a new line: the composer holds \(String(reflecting: value))")
    }
  }

  /// A draft the runner sent, and when it tapped Send.
  struct Sent {
    let text: String
    let at: Int64
  }

  /// Taps Send once the guards pass, and returns the draft it sent.
  @discardableResult func tapSend() throws -> Sent {
    let draft = composer.value as? String ?? ""
    try requireSendToCoordinator(draft)
    // After typing the keyboard moves the composer, and a tap before it settles can miss Send.
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: sendButton)
    guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
      throw PhoneAcceptanceFailure("Send never became available for \(String(reflecting: draft))")
    }
    let at = epochMilliseconds()
    sendButton.tap()
    return Sent(text: draft, at: at)
  }

  /// Sends the draft and checks the first composer screenshot after the tap.
  @discardableResult func send(_ label: String) throws -> Sent {
    let sent = try tapSend()
    try checkSend(snapshotComposer(), label: label, sent: sent)
    return sent
  }

  // MARK: Evidence

  /// The composer as one screenshot showed it, read before any OCR so capture stays immediate.
  struct ComposerSnapshot {
    let crop: XCUIScreenshot
    let screen: XCUIScreenshot
    let value: String?
    let recipientLine: String?
    let keyboardShown: Bool
  }

  func snapshotComposer() -> ComposerSnapshot {
    let crop = composerSurface.screenshot()
    return ComposerSnapshot(
      crop: crop, screen: app.screenshot(), value: composer.value as? String,
      recipientLine: recipientLine.exists ? recipientLine.label : nil,
      keyboardShown: app.keyboards.firstMatch.exists)
  }

  func checkSend(_ snapshot: ComposerSnapshot, label: String, sent: Sent) throws {
    let recognized = try recognizedText(snapshot)
    let placeholder = placeholders.first { $0 == snapshot.value }
    let evidence = SendEvidence(
      label: label, sentAt: sent.at, recipientLine: snapshot.recipientLine,
      composerValue: snapshot.value,
      placeholderShown: placeholder.map { Glyphs.showEveryLine(of: $0, in: recognized) } ?? false,
      sentGlyphsAbsent: !Glyphs.showAnyLine(of: sent.text, in: recognized),
      keyboardShown: snapshot.keyboardShown, ocrText: recognized,
      cropAttachment: "\(label)-composer", screenAttachment: "\(label)-screen")
    test.keep(snapshot.crop, as: evidence.cropAttachment)
    test.keep(snapshot.screen, as: evidence.screenAttachment)
    try test.check(evidence, kind: "send", name: label, problems: evidence.problems)
  }

  /// Checks that the composer holds `draft`, or its placeholder when `draft` is nil, and shows
  /// none of `sent`. A restored draft can arrive after the screen does, so this waits for it.
  func checkDraft(_ label: String, holds draft: String?, sent: String?) throws {
    let expected = draft ?? placeholders[0]
    let arrived = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value IN %@", draft.map { [$0] } ?? placeholders),
      object: composer)
    _ = XCTWaiter.wait(for: [arrived], timeout: 10)
    let snapshot = snapshotComposer()
    let recognized = try recognizedText(snapshot)
    let shown = draft ?? placeholders.first { $0 == snapshot.value } ?? expected
    let evidence = DraftEvidence(
      label: label, expected: expected, composerValue: snapshot.value,
      expectedShown: snapshot.value == shown && Glyphs.showEveryLine(of: shown, in: recognized),
      sent: sent,
      sentGlyphsAbsent: sent.map { !Glyphs.showAnyLine(of: $0, in: recognized) } ?? true,
      ocrText: recognized, cropAttachment: "\(label)-composer")
    test.keep(snapshot.crop, as: evidence.cropAttachment)
    try test.check(evidence, kind: "draft", name: label, problems: evidence.problems)
  }

  private func recognizedText(_ snapshot: ComposerSnapshot) throws -> String {
    guard let image = snapshot.crop.image.cgImage else {
      throw PhoneAcceptanceFailure("The composer screenshot has no bitmap")
    }
    return try Glyphs.recognized(in: image)
  }

  // MARK: Admission

  /// Waits until the transcript shows `text` as the user's message, marked Sent.
  func waitForAdmission(of text: String, timeout: TimeInterval) throws {
    let row = app.scrollViews["transcript"].descendants(matching: .any)
      .matching(NSPredicate(format: "label == 'You'"))
      .containing(NSPredicate(format: "label == %@", text))
      .containing(NSPredicate(format: "label == 'Sent' OR label BEGINSWITH 'Sent '"))
      .firstMatch
    guard row.waitForExistence(timeout: timeout) else {
      throw PhoneAcceptanceFailure(
        "No Sent row for \(String(reflecting: text)) in \(Int(timeout)) s")
    }
  }

  // MARK: App lifecycle

  func pressHome() throws {
    XCUIDevice.shared.press(.home)
    try waitForState("background", timeout: 15) {
      [.runningBackground, .runningBackgroundSuspended].contains($0)
    }
  }

  func returnToApp() throws {
    app.activate()
    try waitForForeground()
  }

  func waitForForeground() throws {
    try waitForState("foreground", timeout: 15) { $0 == .runningForeground }
  }

  func switchToSettingsAndBack() throws {
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    settings.activate()
    guard settings.wait(for: .runningForeground, timeout: 15) else {
      throw PhoneAcceptanceFailure("Settings did not come to the foreground")
    }
    try returnToApp()
  }

  func terminate() throws {
    app.terminate()
    try waitForState("terminated", timeout: 15) { $0 == .notRunning }
  }

  /// Opens the app again after `terminate()`. The rehearsal's fixture saved its launch values,
  /// so a plain launch finds the same storage and peers.
  func relaunch() throws {
    try returnToApp()
    guard composer.waitForExistence(timeout: 30) else {
      throw PhoneAcceptanceFailure("The relaunched app showed no composer")
    }
  }

  private func waitForState(
    _ name: String, timeout: TimeInterval, _ matches: (XCUIApplication.State) -> Bool
  ) throws {
    guard poll(timeout: timeout, until: { matches(app.state) }) else {
      throw PhoneAcceptanceFailure("The app stayed in state \(app.state.rawValue), not \(name)")
    }
  }

  /// Whether `condition` held before the deadline. Each check queries the device. XCTest updates
  /// an app's state on the main run loop, so the wait runs it rather than sleeping.
  func poll(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date.now.addingTimeInterval(timeout)
    while !condition() {
      guard Date.now < deadline else { return false }
      RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
    }
    return true
  }

  // MARK: Alerts

  /// A codeword no earlier run used: the run label and four random letters.
  func codeword() -> String {
    configuration.run
      + String((0..<4).compactMap { _ in "abcdefghijklmnopqrstuvwxyz".randomElement() })
  }

  /// Arranges for an alert showing the codeword after `stage`. On the phone the coordinator
  /// sends it. The rehearsal asks the host script to push it.
  func expectAlert(stage: String, codeword: String) throws {
    #if targetEnvironment(simulator)
      try rehearsal?.requestPush(stage: stage, codeword: codeword)
    #endif
  }

  private func alertElement(_ codeword: String) -> XCUIElement {
    springboard.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS[c] %@", codeword)).firstMatch
  }

  /// Waits until `element` is on screen, or off it. SpringBoard keeps a delivered alert's entry in
  /// its hierarchy while no surface shows it, so existence alone proves nothing a person saw.
  private func wait(_ element: XCUIElement, shown: Bool, timeout: TimeInterval) -> Bool {
    let format =
      shown ? "exists == true AND hittable == true" : "exists == false OR hittable == false"
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: format), object: element)
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  /// Waits for a banner that shows the codeword and keeps the screen it showed on.
  func awaitBanner(_ codeword: String, timeout: TimeInterval) -> (AlertEvidence, XCUIElement) {
    let element = alertElement(codeword)
    let found = wait(element, shown: true, timeout: timeout)
    return (keepAlert(codeword, element: found ? element : nil, surface: .banner), element)
  }

  /// Opens the app from the alert and records when.
  func tap(_ alert: inout AlertEvidence, _ element: XCUIElement) {
    alert.tappedAt = epochMilliseconds()
    element.tap()
  }

  /// Opens Notification Center from the top-left edge and finds the codeword's entry there.
  func findInNotificationCenter(_ codeword: String) -> (AlertEvidence, XCUIElement) {
    // A banner still on screen would be found in its place.
    _ = wait(alertElement(codeword), shown: false, timeout: 15)
    let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.005))
    top.press(
      forDuration: 0.1,
      thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.7)))
    let element = alertElement(codeword)
    let found = wait(element, shown: true, timeout: 10)
    return (
      keepAlert(codeword, element: found ? element : nil, surface: .notificationCenter), element
    )
  }

  private func keepAlert(
    _ codeword: String, element: XCUIElement?, surface: AlertEvidence.Surface
  ) -> AlertEvidence {
    let seenAt = element.map { _ in epochMilliseconds() }
    let screen = XCUIScreen.main.screenshot()
    let evidence = AlertEvidence(
      codeword: codeword, surface: surface, appState: .init(app.state),
      alertLabel: element?.label, seenAt: seenAt,
      attachment: "alert-\(codeword)-\(surface.rawValue)")
    test.keep(screen, as: evidence.attachment)
    return evidence
  }

  /// Keeps every observation of one codeword, then fails unless some surface showed it with the
  /// app in `state`.
  func checkAlerts(_ observations: [AlertEvidence], expecting state: AlertEvidence.AppState)
    throws
  {
    var problems: [String] = []
    for evidence in observations {
      let found = evidence.problems(expecting: state)
      try test.keepRecord(
        evidence, kind: "alert", name: "\(evidence.codeword)-\(evidence.surface.rawValue)",
        problems: found)
      problems += found.map { "\(evidence.surface.rawValue): \($0)" }
    }
    if !observations.contains(where: { $0.alertLabel != nil }) {
      let surfaces = observations.map(\.surface.rawValue).joined(separator: " or ")
      problems.append("no \(surfaces) showed \(observations.first?.codeword ?? "the codeword")")
    }
    guard problems.isEmpty else {
      throw PhoneAcceptanceFailure("alert: \(problems.joined(separator: "; "))")
    }
  }

  /// Checks that the rehearsal's coordinator received `draft` as one message of its lines. A
  /// phone's coordinator keeps its own record, so there this checks nothing.
  func checkRehearsalSubmit(_ label: String, draft: String) async throws {
    #if targetEnvironment(simulator)
      guard let work = rehearsal?.work else { return }
      let head = String(draft.prefix(while: { $0 != "\n" }))
      let deadline = ContinuousClock.now + .seconds(10)
      var submits: [String] = []
      repeat {
        submits = await work.submits().filter { $0.hasPrefix(head) }
        if !submits.isEmpty { break }
        try await Task.sleep(for: .milliseconds(200))
      } while ContinuousClock.now < deadline
      let evidence = SubmitEvidence(
        label: label,
        draftLines: draft.split(separator: "\n", omittingEmptySubsequences: false).count,
        submits: submits)
      try test.check(evidence, kind: "submit", name: label, problems: evidence.problems)
    #endif
  }

  // MARK: Teardown

  /// Deletes the runner's own draft key by key, and leaves any other draft alone.
  func clearRunnerDraft() throws {
    guard let value = composer.value as? String, value.hasPrefix(configuration.run + " ") else {
      return
    }
    composer.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.95)).tap()
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
    let left = composer.value as? String ?? ""
    guard !left.contains(configuration.run) else {
      throw PhoneAcceptanceFailure(
        "Could not clear the runner's draft: \(String(reflecting: left))")
    }
  }

  private func restore() throws {
    if app.state != .runningForeground { app.activate() }
    guard composer.waitForExistence(timeout: 30) else {
      throw PhoneAcceptanceFailure("Teardown found no composer to clear")
    }
    try clearRunnerDraft()
    if let originalScope { try choose(originalScope) }
  }
}
