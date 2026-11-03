import AgentCore
import Network
import UIKit
import XCTest

@MainActor private func eventually(
  description: String = "interaction state",
  file: StaticString = #filePath, line: UInt = #line,
  _ predicate: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while try await !predicate() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Expected \(description) did not arrive", file: file, line: line)
      return
    }
    try await Task.sleep(for: .milliseconds(20))
  }
}

@MainActor
final class ComposerInteractionTests: XCTestCase {
  private func launchWithWorkAndPersonal(
    workHistory: [HistoryMessage] = [], largestText: Bool = false
  ) async throws -> (
    app: XCUIApplication, work: InteractionPeer, personal: InteractionPeer
  ) {
    continueAfterFailure = false
    executionTimeAllowance = 120
    let work = InteractionPeer()
    let personal = InteractionPeer()
    var ports: [String] = []
    for (peer, messages) in [(work, workHistory), (personal, [])] {
      addTeardownBlock { await peer.stop() }
      let history = NativeEventHistory(messages: messages, nextCursor: nil, pageComplete: true)
      await peer.history(initial: history, pages: [:], latest: history)
      ports.append(String(try await peer.start()))
    }
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.joined(separator: ",")
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = [work, personal]
      .map { $0.coordinator.uuidString }.joined(separator: ",")
    app.launchArguments += ["-notificationsEnabled", "NO"]
    if largestText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    app.launch()
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 10))
    return (app, work, personal)
  }
  /// An empty draft reports its placeholder as its value, which is what VoiceOver reads.
  private func isEmpty(_ field: XCUIElement) -> Bool {
    let value = field.value as? String
    return value == nil || value == "" || value == "Message Beep Boop"
  }
  /// Where the field draws its one line of text, in points from its leading edge: the leftmost and
  /// rightmost gray pixels in a screenshot that stand out from the field's background, in either
  /// appearance. A chip's name and the caret are colored, so neither counts.
  private func drawnLine(_ app: XCUIApplication, _ field: XCUIElement) throws
    -> ClosedRange<CGFloat>
  {
    let image = try XCTUnwrap(app.screenshot().image.cgImage)
    let scale = CGFloat(image.width) / app.frame.width
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let frame = field.frame
    func color(_ x: Int, _ y: Int) -> [Int] {
      let pixel = (y * image.width + x) * 4
      return pixels[pixel..<pixel + 3].map(Int.init)
    }
    // The one line of text ends well before the field's trailing edge.
    let background = color(Int((frame.maxX - 8) * scale), Int(frame.midY * scale)).reduce(0, +)
    var columns: [Int] = []
    for y in Int((frame.minY + 2) * scale)..<Int((frame.maxY - 2) * scale) {
      for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
        let rgb = color(x, y)
        let gray = (rgb.max() ?? 0) - (rgb.min() ?? 0) < 40
        if gray && abs(rgb.reduce(0, +) - background) > 300 { columns.append(x) }
      }
    }
    let first = try XCTUnwrap(columns.min(), "The field draws no text")
    let last = try XCTUnwrap(columns.max())
    return (CGFloat(first) / scale - frame.minX)...(CGFloat(last) / scale - frame.minX)
  }
  /// Double-taps the middle of `word` where the field draws it, after `prefix`, in its one line of
  /// `text`. That selects the word TextKit has there.
  private func doubleTap(
    _ word: String, after prefix: String, of text: String, in field: XCUIElement,
    _ app: XCUIApplication
  ) throws {
    let drawn = try drawnLine(app, field)
    let font = UIFont.preferredFont(forTextStyle: .body)
    func width(_ string: String) -> CGFloat {
      (string as NSString).size(withAttributes: [.font: font]).width
    }
    let middle = (width(prefix) + width(word) / 2) / width(text)
    let x = drawn.lowerBound + (drawn.upperBound - drawn.lowerBound) * middle
    field.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: x, dy: field.frame.height / 2)).doubleTap()
  }

  // Typed through the keyboard into the real field, where a model-level draft cannot reach.
  func testATypedTagBecomesTheRecipientAndNeverReachesTheWire() async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3), "The typed tag is the chip")
    XCTAssertTrue(
      isEmpty(composer),
      "The typed tag left the field, which shows \(composer.value as? String ?? "nil")")
    let text = "Anything urgent this morning?"
    composer.typeText(text)
    app.buttons["Send message"].tap()
    try await eventually { await work.submits() == [text] }
    let toWork = await work.submits()
    let toPersonal = await personal.submits()
    XCTAssertEqual(toWork, [text], "Work receives the text without its tag")
    XCTAssertEqual(toPersonal, [], "Personal receives nothing")
  }

  // The keyboard's inline prediction completes "airport", so the last key leaves the text as it
  // was. A field still showing sent text would send it again, untagged, with the next key.
  func testSendEmptiesTheFieldWhenTheLastKeyFinishedAnInlinePrediction() async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    let text = "Book a taxi to the airport"
    // typeText gets no inline prediction, so this taps the keys as a person does.
    for character in text {
      let name = character == " " ? "space" : String(character)
      let key = app.keyboards.keys[name]
      if key.exists { key.tap() } else { app.keyboards.keys[name.lowercased()].tap() }
    }
    app.buttons["Send message"].tap()
    try await eventually {
      let toWork = await work.submits()
      let toPersonal = await personal.submits()
      return toWork == [text] && toPersonal == [text]
    }
    XCTAssertTrue(
      isEmpty(composer),
      "The field kept the sent text: \(composer.value as? String ?? "nil")")
    composer.typeText("x")
    XCTAssertEqual(composer.value as? String, "x", "The next key starts a new draft")
  }

  // At the largest text size, a tap on the draft's second line, under the chip, places the cursor.
  // The draft stays Personal's, and Send reaches Personal alone.
  func testATapOnDraftTextUnderTheChipKeepsTheRecipientAtTheLargestTextSize() async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal(largestText: true)
    defer { app.terminate() }
    let composer = app.textViews["Message the coordinator"]
    composer.tap()
    composer.typeText("@Personal ")
    XCTAssertTrue(app.buttons["To Personal"].waitForExistence(timeout: 3))
    composer.typeText("Synthetic note")
    app.buttons["Connection"].tap()
    app.buttons["Done"].tap()
    composer.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 30, dy: 100)).tap()
    let retained = app.buttons["To Personal"].exists
    app.buttons["Send message"].tap()
    try await eventually { await personal.submits().count == 1 }
    let sentToWork = await work.submits()
    XCTAssertTrue(retained, "Tapping visible draft text removed its recipient")
    XCTAssertEqual(sentToWork, [])
  }

  // A line typed after a typed tag's chip, then the chip's ⓧ. The line is drawn at the field's
  // leading edge, where taps find it, so a double tap on the drawn word "one" selects it and the
  // next keys replace it there.
  func testATapOnADrawnWordOnceTheChipIsGoneEditsThere() async throws {
    let (app, _, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    continueAfterFailure = true
    let composer = app.textViews["Message the coordinator"]
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    let text = "Invented one line"
    composer.typeText(text)
    app.buttons["To Work"].tap()
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 3))
    try await Task.sleep(for: .seconds(1))
    let drawn = try drawnLine(app, composer)
    try doubleTap("one", after: "Invented ", of: text, in: composer, app)
    composer.typeText("oneX")
    print("IF7-V2[typed] drawn=\(drawn) after the edit: \(composer.value as? String ?? "nil")")
    XCTAssertLessThan(drawn.lowerBound, 8, "The line is drawn where the chip was")
    XCTAssertEqual(composer.value as? String, "Invented oneX line")
  }

  // The same after Restore, which sets the chip and the text in code.
  func testATapOnADrawnWordOnceARestoredChipIsGoneEditsThere() async throws {
    let (app, work, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    continueAfterFailure = true
    await work.rejectSubmits(true)
    let composer = app.textViews["Message the coordinator"]
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    let text = "Invented one line"
    composer.typeText(text)
    app.buttons["Send message"].tap()
    let restore = app.buttons["Restore Work's copy to composer"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10))
    await work.rejectSubmits(false)
    restore.tap()
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    app.buttons["To Work"].tap()
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 3))
    try await Task.sleep(for: .seconds(1))
    let drawn = try drawnLine(app, composer)
    try doubleTap("one", after: "Invented ", of: text, in: composer, app)
    composer.typeText("oneX")
    print("IF7-V2[restored] drawn=\(drawn) after the edit: \(composer.value as? String ?? "nil")")
    XCTAssertLessThan(drawn.lowerBound, 8, "The line is drawn where the chip was")
    XCTAssertEqual(composer.value as? String, "Invented oneX line")
  }

  // Work refuses a message to it alone whose text starts with @Personal, and the user restores it.
  // The chip's ⓧ makes it a message to both, as its hint says, and the restored text stays
  // literal: one more key promotes nothing, and each coordinator gets the text as it was.
  func testARestoredTagTextStaysLiteralOnceItsChipIsRemoved() async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    continueAfterFailure = true
    await work.rejectSubmits(true)
    let composer = app.textViews["Message the coordinator"]
    let line = app.staticTexts["recipientLine"]
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    let text = "@Personal invented: forward the deck to the auditors"
    composer.typeText(text)
    app.buttons["Send message"].tap()
    let restore = app.buttons["Restore Work's copy to composer"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10))
    await work.rejectSubmits(false)
    restore.tap()
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    app.buttons["To Work"].tap()
    let afterRemoval = line.label
    composer.typeText(".")
    try await Task.sleep(for: .milliseconds(500))
    let personalChip = app.buttons["To Personal"].exists
    print(
      "IF7-V4[ui] after the chip's ⓧ: line=\(afterRemoval) after one more key: personalChip=\(personalChip) value=\(composer.value as? String ?? "nil") line=\(line.label)"
    )
    XCTAssertEqual(afterRemoval, "To Work and Personal")
    XCTAssertFalse(personalChip, "The restored text became Personal's chip")
    XCTAssertEqual(composer.value as? String, text + ".")
    XCTAssertEqual(line.label, "To Work and Personal")
    // After typeText the keyboard moves the composer. A tap before it settles can miss Send.
    let send = app.buttons["Send message"]
    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(send.isHittable)
    send.tap()
    try await eventually {
      let toWork = await work.submits()
      let toPersonal = await personal.submits()
      return toWork.count == 1 && toPersonal.count == 1
    }
    let toWork = await work.submits()
    let toPersonal = await personal.submits()
    print("IF7-V4[ui] Work received \(toWork) Personal received \(toPersonal)")
    XCTAssertEqual(toWork, [text + "."])
    XCTAssertEqual(toPersonal, [text + "."])
  }

  // Wrapped lines start under the chip. A tap on the second line there places the cursor, as a
  // tap on the same line beyond the chip does, and the recipient stays.
  func testATapOnTheSecondLineUnderTheChipKeepsTheRecipient() async throws {
    let (app, _, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3), "The typed tag is the chip")
    composer.typeText(
      "wrapping words for the second line and the third line of this draft message here")
    XCTAssertTrue(app.buttons["To Work"].exists)
    composer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 200, dy: 38)).tap()
    XCTAssertTrue(app.buttons["To Work"].exists, "Control tap beyond the chip removed it")
    composer.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: 10, dy: 38)).tap()
    XCTAssertTrue(
      app.buttons["To Work"].exists, "Tapping the second draft line removed the recipient chip")
    XCTAssertFalse(
      app.staticTexts["To Work and Personal"].exists,
      "The draft now goes to both coordinators after tapping its second line")
  }

  // A draft taller than six lines scrolls its first line, and the chip with it, out of the field.
  // A tap on the feed where the chip was keeps the recipient, and the chip comes back with the
  // first line.
  func testATapOnTheFeedOverAScrolledChipKeepsTheRecipient() async throws {
    let (app, _, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    let line = app.staticTexts["recipientLine"]
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    composer.typeText("one\ntwo\nthree\nfour\nfive\nsix\nseven\neight")
    try await Task.sleep(for: .seconds(2))
    let field = composer.frame
    app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
      .withOffset(CGVector(dx: field.minX + 39, dy: field.minY - 30)).tap()
    XCTAssertEqual(
      line.label, "To Work", "Tapping the transcript over the scrolled-off chip removed it")
    composer.swipeDown()
    XCTAssertTrue(
      app.buttons["To Work"].isHittable,
      "Scrolling the draft to the top did not bring the chip back")
  }

  // The same with Work's feed long enough to scroll: one tap on the feed 100 points above a tall
  // draft keeps the recipient, and Send reaches Work alone.
  func testATapOnTheFeedAboveATallDraftKeepsTheRecipientAndPersonalGetsNothing() async throws {
    let replies = (1...10).map {
      HistoryMessage(
        continuation: false, entryId: "reply-\($0)", finalChunk: true, role: .final,
        text: "Invented Work reply \($0), long enough to fill a line of the feed.")
    }
    let (app, work, personal) = try await launchWithWorkAndPersonal(workHistory: replies)
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    let line = app.staticTexts["recipientLine"]
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    composer.typeText(
      (1...10).map { "Invented line \($0) for Work only" }.joined(separator: "\n"))
    try await Task.sleep(for: .milliseconds(500))
    // Hides the keyboard, so the layout holds still while the tap lands.
    app.scrollViews["transcript"].swipeDown()
    try await Task.sleep(for: .seconds(1))
    let field = composer.frame
    app.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: field.minX + 39, dy: field.minY - 100)).tap()
    try await Task.sleep(for: .milliseconds(500))
    XCTAssertEqual(line.label, "To Work", "A tap outside the composer kept the recipient")
    app.buttons["Send message"].tap()
    try await eventually { await work.submits().count == 1 }
    let toPersonal = await personal.submits()
    XCTAssertEqual(toPersonal, [], "Personal receives nothing composed for Work")
  }

  // The chip is read before the draft, as it is seen: the recipient, then the message.
  func testVoiceOverReadsTheRecipientChipBeforeTheDraft() async throws {
    guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver automation needs iOS 27") }
    let (app, _, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    let voiceOver = XCUIDevice.shared.voiceOverService
    // A stopped test skips `defer`, so a teardown block turns VoiceOver off for the next test.
    addTeardownBlock { @MainActor in try? XCUIDevice.shared.voiceOverService.disable() }
    try voiceOver.enable()
    defer { try? voiceOver.disable() }
    let field = try voiceOver.currentSpeech().utterance
    XCTAssertTrue(
      field.contains("Message the coordinator Text field Is editing Message Agen"), field)
    let before = try voiceOver.moveBackward().utterance
    XCTAssertTrue(before.hasPrefix("To Work Button"), before)
    let first = try voiceOver.moveBackward().utterance
    XCTAssertTrue(first.hasPrefix("Add attachments or commands"), first)
  }

  // The feed follows Work's replies as they arrive, from one to more than fill the screen. At
  // each length, opening the picker keeps the newest reply above it.
  func testOpeningThePickerKeepsTheNewestReplyAboveItAtEveryFeedLength() async throws {
    let (app, work, _) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    var covered: [Int] = []
    for count in 1...16 {
      let newest = "Reply \(count) from Work, long enough to fill a line of the feed."
      try await work.reply(newest, id: "reply-\(count)")
      XCTAssertTrue(app.staticTexts[newest].waitForExistence(timeout: 5))
      try await Task.sleep(for: .milliseconds(500))
      if !app.keyboards.keys["@"].exists { app.keyboards.keys["more"].tap() }
      app.keyboards.keys["@"].tap()
      let picker = app.buttons["Send to Work"]
      XCTAssertTrue(picker.waitForExistence(timeout: 3))
      try await Task.sleep(for: .milliseconds(500))
      // The picker's rows sit 6 points inside its card.
      if app.staticTexts[newest].frame.maxY > picker.frame.minY - 6 { covered.append(count) }
      app.keyboards.keys["delete"].tap()
      XCTAssertTrue(picker.waitForNonExistence(timeout: 3))
    }
    XCTAssertEqual(covered, [], "The picker covered the newest reply with this many replies")
  }

  // A person's scroll while the whole feed fits picks the first row as the reading position.
  // Replies then grow the feed past the screen, and the app follows them to the bottom.
  func testOpeningThePickerKeepsTheNewestRepliesInView() async throws {
    let first = "The first question in this conversation."
    let (app, work, _) = try await launchWithWorkAndPersonal(workHistory: [
      .init(continuation: false, entryId: "first", finalChunk: true, role: .user, text: first)
    ])
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    app.scrollViews["transcript"].swipeUp()
    var newest = ""
    for index in 1...12 {
      newest = "Reply \(index) from Work, long enough to fill a line of the feed."
      try await work.reply(newest, id: "reply-\(index)")
      XCTAssertTrue(app.staticTexts[newest].waitForExistence(timeout: 5))
    }
    XCTAssertTrue(app.staticTexts[newest].isHittable, "The feed follows the newest reply")
    XCTAssertFalse(app.staticTexts[first].isHittable, "The feed is longer than the screen")
    // typeText hides and restores the keyboard, which moves the feed on its own.
    app.keyboards.keys["more"].tap()
    app.keyboards.keys["@"].tap()
    XCTAssertTrue(app.buttons["Send to Work"].waitForExistence(timeout: 3))
    XCTAssertTrue(
      app.staticTexts[newest].isHittable, "Opening the picker scrolled away from the newest reply")
    XCTAssertFalse(
      app.staticTexts[first].isHittable, "Opening the picker scrolled back to the first row")
  }
}

@MainActor
final class HistoryInteractionTests: XCTestCase {
  private func launchMessages(
    _ messages: [HistoryMessage], toolDetails: [String: ToolDetails] = [:],
    appearance: String? = nil
  ) async throws -> XCUIApplication {
    continueAfterFailure = false
    executionTimeAllowance = 600
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let history = NativeEventHistory(messages: messages, nextCursor: nil, pageComplete: true)
    await peer.history(initial: history, pages: [:], latest: history)
    await peer.toolDetails(toolDetails)
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    if let appearance { app.launchArguments += ["-appearance", appearance] }
    app.launch()
    addTeardownBlock { @MainActor in app.terminate() }
    return app
  }

  private func action(_ label: String, app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
  }

  private func editor(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: "Message the coordinator").firstMatch
  }

  func testShareExtensionSavesAnUnsentDraftAndHostImportsItOnceAfterRelaunch() async throws {
    let text = "Selected content for the unsent shared draft."
    let app = try await launchMessages([
      .init(
        continuation: false, entryId: "share-source", finalChunk: true, role: .final, text: text)
    ])
    let message = app.staticTexts[text]
    XCTAssertTrue(message.waitForExistence(timeout: 5))
    func presentShare() -> XCUIElement {
      message.press(forDuration: 1)
      let share = action("Share text", app: app)
      XCTAssertTrue(share.waitForExistence(timeout: 3))
      share.tap()
      let destination = app.cells["Beep Boop"]
      XCTAssertTrue(destination.waitForExistence(timeout: 5), app.debugDescription)
      destination.tap()
      let save = app.buttons["Save draft"]
      // This launches a separate extension process. Wait for its usable view,
      // rather than imposing a five-second cold-launch performance threshold.
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND enabled == true"), object: save)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
      return save
    }
    let cancelled = presentShare()
    app.buttons["Cancel"].tap()
    XCTAssertTrue(cancelled.waitForNonExistence(timeout: 5))
    // The system owns the dismissal animation. Reopening the source also
    // verifies that cancel left no published draft before the real save.
    app.terminate()
    app.launch()
    XCTAssertTrue(message.waitForExistence(timeout: 5))
    let save = presentShare()
    let selection = XCTAttachment(screenshot: app.screenshot())
    selection.name = "native-share-unsent-draft"
    selection.lifetime = .keepAlways
    add(selection)
    save.tap()
    XCTAssertTrue(save.waitForNonExistence(timeout: 5), app.debugDescription)
    app.terminate()
    app.launchEnvironment.removeValue(forKey: "AGENT_INTERACTION_PORT")
    app.launch()
    if app.buttons["dismissConnection"].waitForExistence(timeout: 3) {
      app.buttons["dismissConnection"].tap()
    }
    let composer = editor(app)
    let imported = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", text), object: composer)
    XCTAssertEqual(XCTWaiter.wait(for: [imported], timeout: 5), .completed, app.debugDescription)
    let draft = try XCTUnwrap(composer.value as? String)
    XCTAssertEqual(draft.components(separatedBy: text).count, 2)
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
    app.terminate()
    app.launch()
    if app.buttons["dismissConnection"].waitForExistence(timeout: 3) {
      app.buttons["dismissConnection"].tap()
    }
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", draft), object: editor(app))
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, app.debugDescription)
    XCTAssertFalse(app.buttons["Send message"].isEnabled)
  }

  func testWholeMessageCopyAndPartialNativeSelectionPasteThroughComposer() async throws {
    let text = "Alpha bracket Charlie.\n\nSecond paragraph from the same answer."
    let app = try await launchMessages([
      .init(continuation: false, entryId: "1", finalChunk: true, role: .final, text: text)
    ])
    let first = app.staticTexts["Alpha bracket Charlie."]
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.press(forDuration: 1)
    let copy = action("Copy message", app: app)
    XCTAssertTrue(copy.waitForExistence(timeout: 3))
    copy.tap()
    let composer = editor(app)
    func pasteCopiedText(_ expected: String) {
      composer.tap()
      composer.press(forDuration: 1)
      let paste = action("Paste", app: app)
      XCTAssertTrue(paste.waitForExistence(timeout: 3), app.debugDescription)
      paste.tap()
      let pasted = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", expected), object: composer)
      XCTAssertEqual(
        XCTWaiter.wait(for: [pasted], timeout: 3), .completed,
        "The actual native Paste action must update the composer: \(composer.debugDescription)")
    }
    pasteCopiedText(text)
    XCTAssertEqual(composer.value as? String, text)
    // Select the actual native range rather than assuming the insertion point
    // starts at the end, then wait for the real editor to finish the deletion.
    composer.press(forDuration: 1)
    let selectAll = action("Select All", app: app)
    XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
    selectAll.tap()
    let delete = app.keys["delete"]
    XCTAssertTrue(delete.exists)
    delete.tap()
    let cleared = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", ""), object: composer)
    XCTAssertEqual(
      XCTWaiter.wait(for: [cleared], timeout: 3), .completed,
      "Native Select All/Delete must clear the exact composer value: \(composer.debugDescription)")
    XCTAssertEqual(composer.value as? String, "")
    first.press(forDuration: 1)
    let select = action("Select text", app: app)
    XCTAssertTrue(select.waitForExistence(timeout: 3))
    select.tap()
    let selection = app.textViews["Selectable message text"]
    XCTAssertTrue(selection.waitForExistence(timeout: 3))
    // Touch a word in the real, noneditable UITextView, not a test-only menu.
    selection.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: 35, dy: 27)
    ).press(forDuration: 1)
    let selectedCopy = action("Copy", app: app)
    XCTAssertTrue(selectedCopy.waitForExistence(timeout: 3))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "partial-message-selection-handles"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    selectedCopy.tap()
    app.buttons["Done"].tap()
    pasteCopiedText("Alpha")
    XCTAssertEqual(composer.value as? String, "Alpha")
  }

  func testPasteImagesKeepsTheNoteAndCreatesOnlyRemovableUnsentAttachments() async throws {
    let app = try await launchMessages([
      .init(continuation: false, entryId: "1", finalChunk: true, role: .final, text: "Ready")
    ])
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    let note = "Keep this note with the selected image."
    composer.tap()
    composer.typeText(note)
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24))
    UIPasteboard.general.image = renderer.image { context in
      UIColor.systemTeal.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
    }
    let paste = app.buttons["Paste images"]
    XCTAssertTrue(paste.waitForExistence(timeout: 3))
    XCTAssertTrue(paste.isEnabled)
    paste.tap()
    let remove = app.buttons["Remove Image.jpg"]
    XCTAssertTrue(remove.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Unsent attachments"].exists)
    XCTAssertEqual(composer.value as? String, note)
    XCTAssertTrue(app.buttons["Send message"].isEnabled)
    XCTAssertFalse(app.staticTexts["Sending"].exists)
    XCTAssertFalse(app.staticTexts["Sent"].exists)
    remove.tap()
    XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
    XCTAssertEqual(composer.value as? String, note)
  }

  func testShellActivityKeepsOneCardLiteralOutputAndAFinalResult() async throws {
    struct Input: Encodable {
      let program = "printf"
      let args = ["fixture"]
      let cwd = "/workspace/project"
    }
    struct Output: Encodable {
      let type = "process"
      let exitCode = 0
      enum CodingKeys: String, CodingKey {
        case type, stdout, stderr, truncated
        case exitCode = "exit_code"
      }
      let stdout = "Literal **stdout** 🦀\nA second output line"
      let stderr = ""
      let truncated = false
    }
    let output = Output()
    let encoder = JSONEncoder()
    let details = ToolDetails.available(
      .init(
        callId: "shell-card",
        input: .text(
          .init(
            text: String(decoding: try encoder.encode(Input()), as: UTF8.self), truncated: false)),
        name: "exec",
        output: .text(
          .init(text: String(decoding: try encoder.encode(output), as: UTF8.self), truncated: false)
        ),
        status: .finished))
    for appearance in ["dark", "light"] {
      let app = try await launchMessages(
        [
          .init(
            continuation: false, entryId: "shell-entry", finalChunk: true,
            presentation: .command(.init(command: "printf fixture", durationMs: 12, exitCode: 0)),
            role: .tool, text: output.stdout,
            tool: .init(callId: "shell-card", name: "exec", status: .finished))
        ], toolDetails: ["shell-card": details], appearance: appearance)
      let group = app.buttons["activity:tool:shell-card"]
      XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
      let collapsed = XCTAttachment(screenshot: app.screenshot())
      collapsed.name = "native-shell-collapsed-\(appearance)"
      collapsed.lifetime = .keepAlways
      add(collapsed)
      group.tap()
      let command = app.buttons["activity-item:tool:shell-card"]
      XCTAssertTrue(command.waitForExistence(timeout: 3), app.debugDescription)
      command.tap()
      let success = app.staticTexts["Success"]
      XCTAssertTrue(success.waitForExistence(timeout: 5), app.debugDescription)
      XCTAssertEqual(command.label, "Ran printf fixture")
      XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", "Shell")).count, 1)
      XCTAssertTrue(app.staticTexts["$ printf fixture"].exists)
      XCTAssertEqual(
        app.staticTexts.matching(NSPredicate(format: "label == %@", output.stdout)).count, 1)
      XCTAssertFalse(app.staticTexts["Command"].exists)
      XCTAssertFalse(app.staticTexts["Output"].exists)
      XCTAssertFalse(app.staticTexts["Finished"].exists)
      XCTAssertFalse(app.staticTexts["Working directory"].exists)
      XCTAssertGreaterThan(success.frame.minY, app.staticTexts[output.stdout].frame.maxY)
      let expanded = XCTAttachment(screenshot: app.screenshot())
      expanded.name = "native-shell-expanded-\(appearance)"
      expanded.lifetime = .keepAlways
      add(expanded)
      app.staticTexts[output.stdout].press(forDuration: 1)
      let copy = action("Copy message", app: app)
      XCTAssertTrue(copy.waitForExistence(timeout: 3), app.debugDescription)
      copy.tap()
      let composer = editor(app)
      composer.tap()
      composer.press(forDuration: 1)
      let paste = action("Paste", app: app)
      XCTAssertTrue(paste.waitForExistence(timeout: 3), app.debugDescription)
      paste.tap()
      let pasted = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", output.stdout), object: composer)
      XCTAssertEqual(XCTWaiter.wait(for: [pasted], timeout: 3), .completed, app.debugDescription)
      app.terminate()
    }
  }

  func testOneActivityExpansionShowsEverySuppliedSummaryWithoutFetchingHiddenThinking()
    async throws
  {
    let app = try await launchMessages([
      .init(
        continuation: false, entryId: "1", finalChunk: true, role: .thinking,
        text: "First supplied summary.\n\nEvery provider-supplied line stays visible."),
      .init(
        continuation: false, entryId: "2", finalChunk: true, role: .thinking,
        text: "Second supplied summary.\n\nNo hidden thinking is fetched."),
    ])
    let group = app.buttons["activity:entry:1:0"]
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    group.tap()
    XCTAssertTrue(app.staticTexts["Every provider-supplied line stays visible."].exists)
    XCTAssertTrue(app.staticTexts["No hidden thinking is fetched."].exists)
    XCTAssertFalse(app.buttons["Retry details"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "all-provider-shareable-summaries-one-expansion"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testSourceWarningShowsPerAccountErrorsAndUpdatesDuringRecovery() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 90
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let history = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await peer.history(initial: history, pages: [:], latest: history)
    let diagnostic =
      "Source helper authentication failure during authentication; check authentication for this account. Checkpoint retained."
    let checkedAt = 1_800_000_000_000
    var states = [
      SourceState(
        checkedAt: checkedAt, checkpoint: nil, coverage: .unavailable(.init(message: diagnostic)),
        source: .init(account: "mail-primary", provider: "google")),
      SourceState(
        checkedAt: checkedAt, checkpoint: nil, coverage: .complete,
        source: .init(account: "local-messages", provider: "messages")),
    ]
    try await peer.coverage(states)
    let port = try await peer.start()
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(port)
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    let warning = app.buttons["sourceCoverageWarning"]
    XCTAssertTrue(warning.waitForExistence(timeout: 5))
    warning.tap()
    XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 5))
    // Native LabeledContent may expose its label and value as one AX element.
    func text(_ value: String) -> XCUIElement {
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch
    }
    XCTAssertTrue(text("mail-primary").waitForExistence(timeout: 3), app.debugDescription)
    XCTAssertTrue(text("Unavailable").exists)
    let error = app.staticTexts[diagnostic]
    XCTAssertTrue(error.exists)
    let localTime = Date(timeIntervalSince1970: Double(checkedAt) / 1000)
      .formatted(date: .abbreviated, time: .standard)
    XCTAssertTrue(text(localTime).exists)
    let details = app.descendants(matching: .any).matching(identifier: "sourceDetails").firstMatch
    if !text("local-messages").isHittable { details.swipeUp() }
    XCTAssertTrue(text("local-messages").isHittable)
    XCTAssertTrue(text("Current").exists)
    if !error.isHittable { details.swipeDown() }
    XCTAssertTrue(error.isHittable)
    error.press(forDuration: 1)
    let copy = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy"))
      .firstMatch
    XCTAssertTrue(
      copy.waitForExistence(timeout: 3), "The complete source error must support native copying")
    copy.tap()
    states[0].coverage = .complete
    states[0].checkedAt += 60_000
    try await peer.coverage(states)
    XCTAssertTrue(
      error.waitForNonExistence(timeout: 5),
      "Recovered status must remove the old error while details stay open")
    XCTAssertTrue(text("mail-primary").exists)
    XCTAssertTrue(text("Unavailable").waitForNonExistence(timeout: 3))
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "source-details-live-recovery"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["Done"].tap()
    XCTAssertTrue(warning.waitForNonExistence(timeout: 3))
    app.buttons["Connection"].tap()
    app.buttons["Sources"].tap()
    XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 3))
    XCTAssertTrue(text("mail-primary").exists)
  }

  func testConversationSettingsPreserveTheDraftAndUseOnlyAdvertisedMainControls() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 90
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let history = NativeEventHistory(
      messages: [
        .init(
          continuation: false, entryId: "scheduled", finalChunk: true,
          noticeOrigin: .init(jobId: "invented-job", title: "Original run title"),
          role: .notice, text: "An invented scheduled update."),
        .init(
          continuation: false, entryId: "legacy", finalChunk: true,
          role: .notice, text: "An update with no supplied job provenance."),
      ], nextCursor: nil, pageComplete: true)
    await peer.history(initial: history, pages: [:], latest: history)
    await peer.settings(
      .init(
        configured: .init(
          catalog: [
            .init(
              fast: true, modelId: "test-model", name: "Test model", provider: .openaiCodex,
              reasoning: [.low, .high, .xhigh])
          ], conversationId: "fixture-root",
          model: .init(fast: true, modelId: "test-model", provider: .openaiCodex)), effective: nil))
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    XCTAssertTrue(app.staticTexts["Job: Original run title"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Notice"].exists)
    let composer = editor(app)
    composer.tap()
    let note = "Keep this unsent note."
    composer.typeText(note)
    app.buttons["Connection"].tap()
    app.buttons["Conversation settings"].tap()
    let reasoning = app.buttons["conversationReasoningPicker"]
    XCTAssertTrue(reasoning.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Unknown")).firstMatch
        .exists)
    reasoning.tap()
    action("Extra High", app: app).tap()
    try await eventually(description: "Extra High settings control") {
      await peer.settingsControls().last?.change == .setReasoning(.init(reasoning: .xhigh))
    }
    reasoning.tap()
    action("Provider default", app: app).tap()
    try await eventually(description: "Provider default settings control") {
      await peer.settingsControls().last?.change == .setReasoning(.init(reasoning: nil))
    }
    let fast = app.switches["conversationFastToggle"]
    func waitForFast(_ value: String) {
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@ AND enabled == true", value), object: fast)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 3), .completed, app.debugDescription)
    }
    func toggleFast() {
      // Touch the native switch, not the Form's labeled wrapper.
      let control = fast.switches.firstMatch
      let form = app.collectionViews.containing(.switch, identifier: "conversationFastToggle")
        .firstMatch
      XCTAssertTrue(control.exists, app.debugDescription)
      if !control.isHittable {
        // The draft keyboard can cover Fast and the default Form swipe origin.
        XCTAssertTrue(reasoning.isHittable, app.debugDescription)
        let start = reasoning.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
      }
      let viewport = app.windows.firstMatch.frame.intersection(form.frame)
      XCTAssertTrue(
        !control.frame.isEmpty && viewport.contains(control.frame), app.debugDescription)
      XCTAssertTrue(control.isEnabled, app.debugDescription)
      XCTAssertTrue(control.isHittable, app.debugDescription)
      control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
    waitForFast("1")
    toggleFast()
    waitForFast("0")
    try await eventually(description: "explicit Fast off control") {
      await peer.settingsControls().last?.change == .setFast(.init(mode: .off))
    }
    toggleFast()
    waitForFast("1")
    try await eventually(description: "explicit Fast on control") {
      await peer.settingsControls().last?.change == .setFast(.init(mode: .on))
    }
    let submittedBeforeClosing = await peer.inputs()
    XCTAssertTrue(submittedBeforeClosing.isEmpty)
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = "configured-effective-provider-default-extra-high-fast-controls"
    image.lifetime = .keepAlways
    add(image)
    // New native toolbars expose BackButton outside NavigationBar descendants.
    let back = app.buttons["BackButton"]
    if back.exists {
      back.tap()
    } else {
      app.navigationBars["Conversation settings"].buttons.element(boundBy: 0).tap()
    }
    app.buttons["dismissConnection"].tap()
    XCTAssertEqual(editor(app).value as? String, note)
    let submittedAfterClosing = await peer.inputs()
    XCTAssertTrue(submittedAfterClosing.isEmpty)
  }

  func testTopPagingPreservesVisibleGroupAndLatestReloadsTheActualTail() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    func activity(_ start: Int, count: Int = 25, next: String?) -> NativeEventHistory {
      .init(
        messages: (start..<(start + count)).map { index in
          .init(
            continuation: false, entryId: "tool-\(index)", finalChunk: true,
            role: .tool, text: "",
            tool: .init(callId: "call-\(index)", name: "exec", status: .finished))
        }, nextCursor: next, pageComplete: true)
    }
    let recent: [HistoryMessage] = (100..<120).map { index in
      .init(
        continuation: false, entryId: "recent-\(index)", finalChunk: true,
        role: index.isMultiple(of: 2) ? .user : .final,
        text: "Conversation message \(index). A useful question and a complete answer.")
    }
    let earlier = "The earlier question supplies useful conversation context."
    let latest = "The current latest reply is visible."
    await peer.history(
      initial: .init(
        messages: activity(75, next: nil).messages + recent,
        nextCursor: "one", pageComplete: true),
      pages: [
        "one": activity(50, next: "two"), "two": activity(25, next: "three"),
        "three": .init(
          messages: [
            .init(
              continuation: false, entryId: "earlier-question", finalChunk: true, role: .user,
              text: earlier),
            .init(
              continuation: false, entryId: "earlier-answer", finalChunk: true, role: .final,
              text: "The earlier answer closes the previous question and explains the later work."),
          ], nextCursor: "four", pageComplete: true),
        "four": activity(-500, count: 500, next: nil),
      ],
      latest: .init(
        messages: recent + [
          .init(
            continuation: false, entryId: "current-tail", finalChunk: true, role: .final,
            text: latest)
        ], nextCursor: "recent-older", pageComplete: true))
    await peer.hold("one")
    await peer.hold("four")
    let port = try await peer.start()
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(port)
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[recent.last!.text].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["latest-messages"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts[recent.last!.text].isHittable, "Initial history must show its actual tail")
    let initialRequests = await peer.cursors()
    XCTAssertEqual(initialRequests, [])
    for _ in 0..<8 {
      if !(await peer.cursors()).isEmpty { break }
      transcript.swipeDown(velocity: .fast)
    }
    try await eventually { await peer.cursors() == ["one"] }
    // Feed row IDs carry the coordinator's profile ID: `activity:<profile>/tool:call-75`.
    let group = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'activity:' AND identifier ENDSWITH '/tool:call-75'")
    ).firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 3))
    XCTAssertTrue(group.isHittable)
    let anchor = group.frame
    XCTAssertTrue(app.buttons["latest-messages"].isHittable)
    transcript.swipeDown()
    let heldRequests = await peer.cursors()
    XCTAssertEqual(
      heldRequests, ["one"], "Scrolling during a pending page started another request")
    let settledAnchor = group.frame
    await peer.release("one")
    try await eventually {
      await peer.cursors() == ["one", "two", "three"]
        && app.buttons["Load earlier messages"].isEnabled
    }
    XCTAssertEqual(
      group.frame.minY, settledAnchor.minY, accuracy: 2,
      "Prepending history moved the visible group")
    XCTAssertEqual(group.frame.height, anchor.height, accuracy: 2)
    XCTAssertTrue(app.staticTexts[earlier].exists)
    let receipt = XCTAttachment(screenshot: app.screenshot())
    receipt.name = "tool-heavy-history-preserves-visible-group"
    receipt.lifetime = .keepAlways
    add(receipt)

    let readingPosition = group.frame
    let incoming = "A reply streams while the earlier question is being read."
    try await peer.beginReply(incoming)
    // The reply is outside the lazy viewport. The visible composer proves
    // that its stream has arrived without scrolling away from the reader.
    let working = app.buttons["Stop response"]
    XCTAssertTrue(working.waitForExistence(timeout: 5))
    XCTAssertEqual(
      group.frame.minY, readingPosition.minY, accuracy: 2,
      "Streaming a reply moved the older reading position")
    let completed = incoming + " The reply is complete."
    try await peer.reply(completed, id: "reading-reply")
    XCTAssertTrue(working.waitForNonExistence(timeout: 5))
    XCTAssertEqual(
      group.frame.minY, readingPosition.minY, accuracy: 2,
      "Completing a reply moved the older reading position")

    // A further bounded page evicts the recent tail. At the retained window's
    // physical bottom, Latest must still return to real recent conversation.
    for _ in 0..<5 {
      if (await peer.cursors()).contains("four") { break }
      transcript.swipeDown()
    }
    try await eventually { await peer.cursors() == ["one", "two", "three", "four"] }
    await peer.release("four")
    try await eventually { !app.buttons["Load earlier messages"].exists }
    let concurrent = "A new reply arrived while older history was open."
    try await peer.reply(concurrent)
    XCTAssertTrue(app.staticTexts[concurrent].waitForExistence(timeout: 5))
    transcript.swipeUp()
    XCTAssertTrue(app.buttons["latest-messages"].isHittable)
    app.buttons["latest-messages"].tap()
    try await eventually { (await peer.cursors()).last == "<latest>" }
    XCTAssertTrue(app.staticTexts[latest].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[completed].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[concurrent].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["latest-messages"].waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts[latest].isHittable)
    XCTAssertTrue(
      app.staticTexts[concurrent].isHittable, "Latest must include the newest live reply")
    XCTAssertTrue(app.staticTexts[earlier].waitForNonExistence(timeout: 5))
    let tail = XCTAttachment(screenshot: app.screenshot())
    tail.name = "latest-reloads-current-conversation"
    tail.lifetime = .keepAlways
    add(tail)
  }
}

@MainActor
final class RestoreInteractionTests: XCTestCase {
  // One saved coordinator refuses a message. The user restores it and sends the copy once the
  // coordinator takes messages again.
  func testARefusedMessageRestoredAndResentWithOneCoordinator() async throws {
    continueAfterFailure = true
    executionTimeAllowance = 120
    let work = InteractionPeer()
    addTeardownBlock { await work.stop() }
    let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await work.history(initial: empty, pages: [:], latest: empty)
    let port = try await work.start()
    await work.rejectSubmits(true)
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(port)
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = work.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    let send = app.buttons["Send message"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    let text = "Invented: water the plants on Friday"
    composer.typeText(text)
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    send.tap()
    let restore = app.buttons["Restore to composer"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10), "The refused message offers Restore")
    XCTAssertTrue(app.staticTexts["Needs attention"].exists)
    restore.tap()
    try await eventually { composer.value as? String == text }
    XCTAssertFalse(app.buttons["To Work"].exists, "With one coordinator the composer shows no chip")
    XCTAssertFalse(app.staticTexts["recipientLine"].exists)
    let restored = XCTAttachment(screenshot: app.screenshot())
    restored.name = "restored-with-one-coordinator"
    restored.lifetime = .keepAlways
    add(restored)
    await work.rejectSubmits(false)
    send.tap()
    try await eventually { await work.submits() == [text] }
    XCTAssertTrue(app.staticTexts["Not sent"].waitForExistence(timeout: 5), "The original")
    XCTAssertFalse(app.staticTexts["Needs attention"].exists, "The resent message needs attention")
    XCTAssertFalse(restore.exists, "Restore is offered for a message already sent again")
    let resent = XCTAttachment(screenshot: app.screenshot())
    resent.name = "restored-and-resent-with-one-coordinator"
    resent.lifetime = .keepAlways
    add(resent)
  }
}

// Shared DEBUG app fixture, real screen/session and an owned NDJSON loopback
// peer. Replies are released by assertions instead of elapsed time.
private actor InteractionPeer {
  /// The ID this peer answers `identify` with. The app pins it.
  nonisolated let coordinator = UUID()
  private var listener: NWListener?
  private var sockets: [UUID: NWConnection] = [:]
  private var initial: NativeEventHistory?
  private var pages: [String: NativeEventHistory] = [:]
  private var latest: NativeEventHistory?
  private var observer: NWConnection?
  private var toolReplies: [String: ToolDetails] = [:]
  private var settingsValue: NativeSettingsSnapshot?
  private var settingRequests: [NativeRequestSettings] = []
  private var submitted: [NativeRequestSubmit] = []
  func toolDetails(_ values: [String: ToolDetails]) { toolReplies = values }
  func settings(_ value: NativeSettingsSnapshot) { settingsValue = value }
  func settingsControls() -> [NativeRequestSettings] { settingRequests }
  func inputs() -> [NativeRequestSubmit] { submitted }
  private var sourceStates: [SourceState]?
  private var requests: [String] = []
  private var held: Set<String> = []
  private var releases: [String: CheckedContinuation<Void, Never>] = [:]
  private var rejecting = false

  func history(
    initial: NativeEventHistory, pages: [String: NativeEventHistory], latest: NativeEventHistory
  ) {
    self.initial = initial
    self.pages = pages
    self.latest = latest
  }
  func cursors() -> [String] { requests }
  func coverage(_ states: [SourceState]) async throws {
    sourceStates = states
    if let observer { try await emit(.sources(.init(sources: states)), to: observer) }
  }
  func submits() -> [String] { submitted.map(\.text) }
  /// Rejects each submit while set, as a coordinator that cannot take a message does.
  func rejectSubmits(_ value: Bool) { rejecting = value }
  func beginReply(_ text: String) async throws {
    try await emit(.textDelta(.init(text: text)), to: XCTUnwrap(observer))
  }
  func reply(_ text: String, id: String = "concurrent-reply") async throws {
    let message = HistoryMessage(
      continuation: false, entryId: id, finalChunk: true, role: .final, text: text)
    latest?.messages.append(message)
    try await emit(.answer(.init(entryId: id, text: text)), to: XCTUnwrap(observer))
    try await emit(.idle, to: XCTUnwrap(observer))
  }
  func hold(_ cursor: String) { held.insert(cursor) }
  func release(_ cursor: String) {
    held.remove(cursor)
    releases.removeValue(forKey: cursor)?.resume()
  }
  func start() async throws -> UInt16 {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    let listener = try NWListener(using: parameters)
    self.listener = listener
    let ready = AsyncThrowingStream<Void, any Error>.makeStream()
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.continuation.yield(()) }
      if case .failed(let error) = state { ready.continuation.finish(throwing: error) }
    }
    listener.newConnectionHandler = { socket in Task { await self.accept(socket) } }
    listener.start(queue: .global())
    for try await _ in ready.stream { break }
    return try XCTUnwrap(listener.port).rawValue
  }
  func stop() {
    for continuation in releases.values { continuation.resume() }
    releases = [:]
    listener?.cancel()
    listener = nil
    for socket in sockets.values { socket.cancel() }
    sockets = [:]
  }
  private func accept(_ socket: NWConnection) async {
    let id = UUID()
    sockets[id] = socket
    socket.start(queue: .global())
    defer {
      sockets.removeValue(forKey: id)
      socket.cancel()
    }
    do {
      var data = Data()
      var request = try await read(socket, &data)
      if case .identify = request {
        try await emit(
          .identity(.init(coordinatorId: coordinator.uuidString.lowercased())), to: socket)
        request = try await read(socket, &data)
      }
      switch request {
      case .observe(let observe):
        observer = socket
        try await emit(
          .ready(
            .init(
              conversationId: "fixture-root",
              conversationSettings: settingsValue == nil ? nil : true,
              inputOrigins: settingsValue == nil ? nil : true, model: "fixture/model")), to: socket)
        try await emit(.history(try XCTUnwrap(initial)), to: socket)
        if observe.sourceStatus == true, let sourceStates {
          try await emit(.sources(.init(sources: sourceStates)), to: socket)
        }
        try await emit(.idle, to: socket)
      case .toolDetails(let request):
        let details = toolReplies[request.callId] ?? .unavailable(.init(callId: request.callId))
        try await emit(.toolDetails(.init(details: details)), to: socket)
        try await emit(.done, to: socket)
      case .settings(let request):
        settingRequests.append(request)
        var settings = try XCTUnwrap(settingsValue)
        switch request.change {
        case .setReasoning(let value): settings.configured.model.reasoning = value.reasoning
        case .setFast(let value): settings.configured.model.fast = value.mode == .on
        case .none: break
        default: XCTFail("Unexpected settings control")
        }
        settingsValue = settings
        try await emit(
          .notice(.init(settings: settings, text: "Conversation settings")), to: socket)
        try await emit(.done, to: socket)
      case .history(let request):
        let cursor = request.cursor ?? "<latest>"
        requests.append(cursor)
        if held.contains(cursor) { await withCheckedContinuation { releases[cursor] = $0 } }
        try await emit(
          .history(try XCTUnwrap(request.cursor == nil ? latest : pages[cursor])), to: socket)
        try await emit(.done, to: socket)
      case .submit(let request):
        if rejecting {
          try await emit(
            .rejected(
              .init(inputId: request.inputId, message: "Invented: the coordinator is busy")),
            to: socket)
        } else {
          submitted.append(request)
          try await emit(.accepted(.init(inputId: request.inputId)), to: socket)
        }
        try await emit(.done, to: socket)
      default: try await emit(.done, to: socket)
      }
      _ = try await receive(socket)
    } catch {
      // Client cancellation owns closing both observers and history requests.
    }
  }
  private func read(_ socket: NWConnection, _ data: inout Data) async throws -> NativeRequest {
    while !data.contains(10) { data.append(try await receive(socket)) }
    let end = try XCTUnwrap(data.firstIndex(of: 10))
    let command = try JSONDecoder().decode(NativeCommand.self, from: data.prefix(upTo: end))
    data.removeSubrange(...end)
    guard case .native(let value) = command else { throw CocoaError(.fileReadUnknown) }
    return value.request
  }
  private func receive(_ socket: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      socket.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
        if let error {
          continuation.resume(throwing: error)
        } else if complete && (data?.isEmpty ?? true) {
          continuation.resume(throwing: CocoaError(.fileReadUnknown))
        } else {
          continuation.resume(returning: data ?? Data())
        }
      }
    }
  }
  private func emit(_ event: NativeEvent, to socket: NWConnection) async throws {
    var data = try JSONEncoder().encode(event)
    data.append(10)
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      socket.send(
        content: data,
        completion: .contentProcessed { error in
          if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
  }
}
