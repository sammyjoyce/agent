import AgentCore
import CoreImage
import CryptoKit
import UIKit
import Vision
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
  func testWrappingDraftMovesAboveControlsWithoutSending() async throws {
    try await exerciseWrappingDraft(largestText: false)
  }

  func testWrappingDraftUsesFullWidthAtLargestDynamicType() async throws {
    try await exerciseWrappingDraft(largestText: true)
  }

  private func exerciseWrappingDraft(largestText: Bool) async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal(largestText: largestText)
    defer { app.terminate() }
    let composer = app.textViews["Message the coordinator"]
    let menu = app.buttons["composerMenu"]
    let send = app.buttons["Send message"]
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertTrue(composer.showsNoText)
    XCTAssertGreaterThan(composer.frame.minX, menu.frame.maxX, "Empty stays inline")
    XCTAssertGreaterThan(composer.frame.maxY, menu.frame.minY, "Empty stays beside controls")
    composer.typeText("Hi")
    try await eventually { composer.value as? String == "Hi" }
    // This fixture has no dictation controller. Real held-mic coverage is selected separately
    // by the native runner from DictationInteractionTests' existing progressive-speech cases.
    let controls = [menu, app.buttons["Paste images"], send].filter { $0.exists }
    // The Simulator shows and hides its software keyboard as hardware key events arrive, which
    // moves the whole composer on screen, and the composer's own frame gains the home indicator
    // inset while the keyboard is down. Measure each control from the recipient line under the
    // controls instead, so a control that jumps inside the composer still fails.
    let recipientLine = app.staticTexts["recipientLine"]
    try await eventually(description: "composer menu and send share a baseline") {
      abs(menu.frame.minY - send.frame.minY) < 1
    }
    func placement(_ control: XCUIElement) -> CGPoint {
      CGPoint(x: control.frame.minX, y: recipientLine.frame.minY - control.frame.minY)
    }
    func near(_ a: [CGPoint], _ b: [CGPoint]) -> Bool {
      zip(a, b).allSatisfy { abs($0.x - $1.x) < 1 && abs($0.y - $1.y) < 1 }
    }
    // Each frame is a separate query, so a reading taken while the keyboard moves the composer
    // mixes two positions. Take the placements once two readings agree.
    func settledPlacements() async throws -> [CGPoint] {
      var last = controls.map(placement)
      try await eventually(description: "composer controls settle") {
        let now = controls.map(placement)
        defer { last = now }
        return near(now, last)
      }
      return last
    }
    var controlPlacements = try await settledPlacements()
    func assertControlsStayPut() async throws {
      try await eventually(description: "composer controls stay put") {
        near(controls.map(placement), controlPlacements)
      }
    }
    // Hi fits even at accessibility sizes. Comparing to 44pt would incorrectly stack it.
    XCTAssertLessThan(composer.frame.minX, send.frame.minX)
    XCTAssertGreaterThan(composer.frame.minX, menu.frame.maxX, "Short stays inline")
    XCTAssertGreaterThan(composer.frame.maxY, menu.frame.minY, "Short stays beside controls")
    let ready = XCTAttachment(screenshot: app.screenshot())
    ready.name = "composer-wrap-short-ready"
    ready.lifetime = .keepAlways
    add(ready)
    print(
      "composer-wrap[short-ready] field=\(composer.frame) menu=\(menu.frame) send=\(send.frame)")
    let suffix = String(repeating: " invented wrapping words", count: 8)
    composer.typeText(suffix)
    try await eventually(description: "COMPOSER_WRAP_ABOVE_CONTROLS") {
      composer.frame.maxY <= menu.frame.minY + 1
    }
    func assertFullWidth(_ name: String) async throws {
      try await assertControlsStayPut()
      XCTAssertLessThanOrEqual(composer.frame.minX, menu.frame.minX + 1)
      XCTAssertGreaterThanOrEqual(composer.frame.maxX, send.frame.maxX - 1)
      XCTAssertLessThanOrEqual(composer.frame.maxY, menu.frame.minY + 1)
      XCTAssertGreaterThanOrEqual(menu.frame.height, 44)
      XCTAssertGreaterThanOrEqual(send.frame.height, 44)
      let image = XCTAttachment(screenshot: app.screenshot())
      image.name = name
      image.lifetime = .keepAlways
      add(image)
      print("composer-wrap[\(name)] field=\(composer.frame) menu=\(menu.frame) send=\(send.frame)")
    }
    try await assertFullWidth("wrapping-full-width")
    // No tap to recover focus: deletion must still reach the original editor/caret.
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: suffix.count))
    try await eventually { composer.value as? String == "Hi" }
    try await eventually { composer.frame.minX > menu.frame.maxX }
    try await assertControlsStayPut()
    composer.typeText("\nX")
    try await eventually { composer.value as? String == "Hi\nX" }
    try await assertFullWidth("explicit-newline-full-width")
    composer.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue)
    try await eventually { composer.value as? String == "Hi" }
    // A typed recipient must survive a subsequent reflow, without sending.
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2))
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    try await Task.sleep(for: .milliseconds(300))
    try await eventually(description: "composer menu and send share a baseline after the chip") {
      abs(menu.frame.minY - send.frame.minY) < 1
    }
    controlPlacements = try await settledPlacements()
    composer.typeText(suffix)
    try await eventually { composer.frame.maxY <= menu.frame.minY + 1 }
    try await assertFullWidth("recipient-wrapping-full-width")
    // At the largest size this draft passes its line limit and scrolls to the caret, and the field
    // exposes the chip only while all of it shows. The chip is checked again after the paste
    // below, where the draft is short at every size.
    if !largestText { XCTAssertTrue(app.buttons["To Work"].exists) }
    XCTAssertEqual(recipientLine.label, "To Work")
    // Native clipboard paste replaces a selection while retaining the recipient and focus.
    composer.typeKey("a", modifierFlags: .command)
    // The first hardware shortcut in a fresh Simulator can raise a passing "Keyboard Detected"
    // alert. Let it go before the next key, or the next key's interruption check fails on it.
    let keyboardAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    if keyboardAlert.waitForExistence(timeout: 2) {
      XCTAssertTrue(keyboardAlert.waitForNonExistence(timeout: 10))
    }
    UIPasteboard.general.string = "Pasted invented note\nSecond line"
    composer.typeKey("v", modifierFlags: .command)
    try await eventually { composer.value as? String == "Pasted invented note\nSecond line" }
    try await assertFullWidth("pasted-newline-full-width")
    composer.typeText("X")
    XCTAssertEqual(composer.value as? String, "Pasted invented note\nSecond lineX")
    XCTAssertTrue(app.buttons["To Work"].exists)
    let toWork = await work.submits()
    let toPersonal = await personal.submits()
    XCTAssertEqual(toWork, [], "Wrapping and editing never submit")
    XCTAssertEqual(toPersonal, [])
    print("composer-wrap: messagesSubmitted=\(toWork.count + toPersonal.count)")
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
      composer.showsNoText,
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
      composer.showsNoText,
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

  // The same restored text, chip removed. The user deletes it key by key, which ends the restored
  // draft, and presses Command-Z. Undo never reaches back past that, so nothing comes back and Send
  // stays off. Work's original still offers Restore, which brings its text back as Work's, and
  // with the chip removed each coordinator gets it as it was.
  func testUndoAfterDeletingARestoredDraftKeyByKeyBringsNothingBack() async throws {
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
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 3))
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    try await Task.sleep(for: .milliseconds(500))
    let cleared = composer.showsNoText
    composer.typeKey("z", modifierFlags: .command)
    try await Task.sleep(for: .seconds(1))
    let personalChip = app.buttons["To Personal"].exists
    let send = app.buttons["Send message"]
    print(
      "IF10-2[ui] cleared=\(cleared) after Command-Z: value=\(composer.value as? String ?? "nil") personalChip=\(personalChip) line=\(line.label) sendEnabled=\(send.isEnabled) restoreOffered=\(restore.exists)"
    )
    XCTAssertTrue(cleared, "The keys did not empty the field")
    XCTAssertTrue(composer.showsNoText, "Undo brought back the cleared restored text")
    XCTAssertFalse(personalChip, "Undo made the restored text's tag Personal's chip")
    XCTAssertFalse(send.isEnabled, "Send is on with nothing to send")
    XCTAssertTrue(restore.exists, "Work's original no longer offers Restore")
    restore.tap()
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    XCTAssertEqual(composer.value as? String, text)
    app.buttons["To Work"].tap()
    XCTAssertTrue(app.staticTexts["To Work and Personal"].waitForExistence(timeout: 3))
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
    print("IF10-2[ui] restored again, Work received \(toWork) Personal received \(toPersonal)")
    XCTAssertEqual(toWork, [text])
    XCTAssertEqual(toPersonal, [text])
  }

  // Work refuses its copy of a message to both. Its line offers Restore and Discard. Discard
  // removes Work's original, and the line reads "Not sent to Work" with no Restore.
  func testDiscardingARefusedCopyReadsNotSentToItsCoordinator() async throws {
    let (app, work, personal) = try await launchWithWorkAndPersonal()
    defer { app.terminate() }
    continueAfterFailure = true
    await work.rejectSubmits(true)
    let composer = app.textViews["Message the coordinator"]
    composer.tap()
    let text = "Invented: the gate code changed to 4410"
    composer.typeText(text)
    let send = app.buttons["Send message"]
    try await Task.sleep(for: .seconds(1))
    XCTAssertTrue(send.isHittable)
    send.tap()
    let restore = app.buttons["Restore Work's copy to composer"]
    let discard = app.buttons["Discard Work's copy"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10), "Work's refused copy offers Restore")
    XCTAssertTrue(discard.exists, "Work's refused copy offers Discard")
    discard.tap()
    let notSent = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Not sent to Work'"))
      .firstMatch
    XCTAssertTrue(notSent.waitForExistence(timeout: 5), "Work's discarded copy reads Not sent")
    XCTAssertFalse(restore.exists, "Restore is offered for a discarded copy")
    XCTAssertFalse(discard.exists)
    let toWork = await work.submits()
    let toPersonal = await personal.submits()
    print("IF8-W1[ui receipt] Work received \(toWork) Personal received \(toPersonal)")
    XCTAssertEqual(toWork, [])
    XCTAssertEqual(toPersonal, [text])
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
      field.contains("Message the coordinator Text field Is editing Message Beep Boop"), field)
    let before = try voiceOver.moveBackward().utterance
    XCTAssertTrue(before.hasPrefix("To Work Button"), before)
    let first = try voiceOver.moveBackward().utterance
    XCTAssertTrue(first.hasPrefix("Paste images"), first)
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

  // A reader scrolls up and taps Latest. The keyboard and then the picker shrink the feed, which
  // keeps the newest reply rather than going back to the rows the reader had scrolled to.
  func testTheKeyboardAndPickerAfterLatestKeepTheNewestReplyInView() async throws {
    let reply = { (index: Int) in
      "Reply \(index) from Work, long enough to wrap onto a second line of the feed."
    }
    let (app, work, _) = try await launchWithWorkAndPersonal(
      workHistory: (1...30).map {
        .init(
          continuation: false, entryId: "reply-\($0)", finalChunk: true, role: .final,
          text: reply($0))
      })
    defer { app.terminate() }
    let transcript = app.scrollViews["transcript"]
    let latest = app.buttons["latest-messages"]
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    var newest = app.staticTexts[reply(30)]
    XCTAssertTrue(newest.waitForExistence(timeout: 5))
    try await eventually(description: "the newest reply at launch") { newest.isHittable }
    func visibleReplies() -> Set<String> {
      Set(
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Reply "))
          .allElementsBoundByIndex.filter(\.isHittable).map(\.label))
    }
    func openPicker() -> XCUIElement {
      if !app.keyboards.keys["@"].exists { app.keyboards.keys["more"].tap() }
      app.keyboards.keys["@"].tap()
      let picker = app.buttons["Send to Work"]
      XCTAssertTrue(picker.waitForExistence(timeout: 3))
      return picker
    }

    for _ in 0..<3 { transcript.swipeDown() }
    XCTAssertTrue(latest.waitForExistence(timeout: 3), "Scrolling up offers Latest")
    XCTAssertFalse(newest.isHittable, "The reader scrolled away from the newest reply")
    let reading = visibleReplies()
    XCTAssertFalse(reading.isEmpty, "The reader sees older replies")
    func assertTheFeedHoldsTheNewestReply(
      _ newest: XCUIElement, after step: String, above picker: XCUIElement? = nil
    ) async throws {
      // A snap back lands only after the size change has animated, so give it time to happen.
      try await Task.sleep(for: .milliseconds(700))
      XCTAssertEqual(
        visibleReplies().intersection(reading), [],
        "\(step) snapped back to the rows the reader had scrolled to")
      XCTAssertTrue(newest.isHittable, "\(step) scrolled away from the newest reply")
      if let picker {
        XCTAssertLessThanOrEqual(
          newest.frame.maxY, picker.frame.minY - 6, "The picker covered the newest reply")
      }
    }

    latest.tap()
    try await assertTheFeedHoldsTheNewestReply(newest, after: "Latest")
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    try await assertTheFeedHoldsTheNewestReply(newest, after: "The keyboard after Latest")
    var picker = openPicker()
    try await assertTheFeedHoldsTheNewestReply(
      newest, after: "The picker after Latest", above: picker)
    app.keyboards.keys["delete"].tap()
    XCTAssertTrue(picker.waitForNonExistence(timeout: 3))

    for index in 31...34 {
      try await work.reply(reply(index), id: "reply-\(index)")
      newest = app.staticTexts[reply(index)]
      XCTAssertTrue(newest.waitForExistence(timeout: 5))
    }
    try await eventually(description: "the feed following the newest reply") {
      newest.isHittable
    }
    picker = openPicker()
    try await assertTheFeedHoldsTheNewestReply(
      newest, after: "The picker after new replies", above: picker)
  }

  func testSimulatorScopeSwitchingJobsNavigationAndLiveShellAnchoringDuringStream() async throws {
    let shellOutput = "Live stream shell output stays readable"
    let details = ToolDetails.available(
      .init(
        callId: "anchor-shell",
        input: .text(.init(text: #"{"program":"printf","args":["anchor"]}"#, truncated: false)),
        name: "exec",
        output: .text(
          .init(
            text:
              #"{"type":"process","exit_code":0,"stdout":"Live stream shell output stays readable","stderr":"","truncated":false}"#,
            truncated: false)),
        status: .finished))
    var workHistory = (1...6).map { index in
      HistoryMessage(
        continuation: false, entryId: "w-\(index)", finalChunk: true, role: .final,
        text: "Work entry \(index)")
    }
    workHistory.insert(
      HistoryMessage(
        continuation: false, entryId: "w-shell", finalChunk: true,
        presentation: .command(.init(command: "printf anchor", durationMs: 3, exitCode: 0)),
        role: .tool, text: shellOutput,
        tool: .init(callId: "anchor-shell", name: "exec", status: .finished)),
      at: 0)
    workHistory.insert(
      HistoryMessage(
        continuation: false, entryId: "w-neighbor", finalChunk: true,
        presentation: .command(.init(command: "echo neighbor", durationMs: 2, exitCode: 0)),
        role: .tool, text: "Neighbor output",
        tool: .init(callId: "neighbor-tool", name: "exec", status: .finished)),
      at: 1)
    let (app, work, _) = try await launchWithWorkAndPersonal(workHistory: workHistory)
    await work.toolDetails(["anchor-shell": details])
    defer { app.terminate() }

    let scopeMenu = app.buttons["scopeMenu"]
    XCTAssertTrue(scopeMenu.waitForExistence(timeout: 5), app.debugDescription)
    scopeMenu.tap()
    let workOption = app.buttons["Work"]
    XCTAssertTrue(workOption.waitForExistence(timeout: 5), app.debugDescription)
    workOption.tap()
    await work.serve(jobs: [])
    app.buttons["Connection"].tap()
    XCTAssertTrue(app.navigationBars["Connection"].waitForExistence(timeout: 5))
    app.buttons["dismissConnection"].tap()

    let transcript = app.scrollViews["transcript"]
    transcript.swipeDown()
    let shellGroup = app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'activity:' AND identifier ENDSWITH '/tool:anchor-shell'")
    ).firstMatch
    XCTAssertTrue(shellGroup.waitForExistence(timeout: 5))
    shellGroup.tap()
    let shellItem = app.buttons.matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH 'activity-item:' AND identifier ENDSWITH '/tool:anchor-shell'")
    ).firstMatch
    XCTAssertTrue(shellItem.waitForExistence(timeout: 3))
    shellItem.tap()
    let textEl = app.staticTexts[shellOutput]
    XCTAssertTrue(textEl.waitForExistence(timeout: 5))
    let anchoredY = textEl.frame.minY
    try await work.beginReply("Rapid trailing token update. ")
    let streamingCheckDeadline = ContinuousClock.now + .seconds(3)
    while !app.staticTexts["Rapid trailing token update. "].exists
      && ContinuousClock.now < streamingCheckDeadline
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTAssertLessThanOrEqual(abs(textEl.frame.minY - anchoredY), 2.0)
    let composer = app.descendants(matching: .any).matching(identifier: "Message the coordinator")
      .firstMatch
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    transcript.swipeDown()
    XCTAssertTrue(textEl.exists)
  }
}

@MainActor
final class HistoryInteractionTests: XCTestCase {
  private func drag(_ transcript: XCUIElement, down: Bool) {
    let start = transcript.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.65))
    let end = transcript.coordinate(
      withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.65 : 0.3))
    start.press(forDuration: 0.05, thenDragTo: end)
  }
  private func slowDrag(
    _ transcript: XCUIElement, by distance: CGFloat, from start: XCUICoordinate? = nil
  ) {
    let start =
      start ?? transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
    start.press(
      forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
      withVelocity: .slow, thenHoldForDuration: 0.3)
  }
  private func scroll(
    _ transcript: XCUIElement, until frame: () -> CGRect?, liesAcross y: CGFloat,
    rowMargin: CGFloat = 8, file: StaticString = #filePath, line: UInt = #line
  ) throws -> CGRect {
    for _ in 0..<20 {
      guard let row = frame() else { break }
      let distance = y - row.midY
      if abs(distance) <= row.height / 2 - rowMargin { return row }
      // The first 10 points of a drag do not move the transcript.
      slowDrag(transcript, by: max(-200, min(200, distance + (distance > 0 ? 10 : -10))))
    }
    return try XCTUnwrap(
      nil as CGRect?, "No row came to rest across the height \(y)", file: file, line: line)
  }
  private func screenIsBlank(in area: CGRect, of app: XCUIApplication) throws -> Bool {
    let image = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
    let scale = CGFloat(image.width) / app.frame.width
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var darkest = [255, 255, 255]
    var lightest = [0, 0, 0]
    for y in Int(area.minY * scale)..<Int(area.maxY * scale) {
      for x in Int(area.minX * scale)..<Int(area.maxX * scale) {
        for channel in 0..<3 {
          let value = Int(pixels[(y * image.width + x) * 4 + channel])
          darkest[channel] = min(darkest[channel], value)
          lightest[channel] = max(lightest[channel], value)
        }
      }
    }
    let faintestVisibleInk = 32
    return zip(lightest, darkest).allSatisfy { $0 - $1 < faintestVisibleInk }
  }
  func testLongSingleNoticeRemainsDraggableThroughKeyboardAndRevision() async throws {
    continueAfterFailure = true
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let paragraphs = (0..<32).map {
      "Scroll checkpoint \($0). This invented notice explains a separate observation in enough detail to wrap across several lines on a phone."
    }
    let history = NativeEventHistory(
      messages: [
        .init(
          continuation: false, entryId: "long-notice", finalChunk: true,
          role: .notice, text: paragraphs.joined(separator: "\n\n"))
      ], nextCursor: nil, pageComplete: true)
    await peer.history(initial: history, pages: [:], latest: history)
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    let marker = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH %@", "Scroll checkpoint 16.")
    ).firstMatch
    XCTAssertTrue(marker.waitForExistence(timeout: 5))
    let composer = app.textViews["Message the coordinator"]
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
    drag(transcript, down: true)  // The first downward drag may only dismiss the keyboard.
    XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    for index in 0..<3 {
      let before = marker.frame.minY
      drag(transcript, down: true)
      let after = marker.frame.minY
      print("LONG_SCROLL down \(index): \(before) -> \(after)")
      XCTAssertGreaterThan(after - before, 60, "A tall single row stopped moving downward")
    }
    let reading = marker.frame.minY
    let incoming = "An invented live revision arrives outside the reading viewport."
    try await peer.beginReply(incoming)
    let working = app.buttons["Stop response"]
    XCTAssertTrue(working.waitForExistence(timeout: 5))
    XCTAssertEqual(marker.frame.minY, reading, accuracy: 3, "Streaming displaced the reader")
    try await peer.reply(incoming)
    XCTAssertTrue(working.waitForNonExistence(timeout: 5))
    XCTAssertEqual(
      marker.frame.minY, reading, accuracy: 3, "Completing output displaced the reader")
    for index in 0..<3 {
      let before = marker.frame.minY
      drag(transcript, down: false)
      let after = marker.frame.minY
      print("LONG_SCROLL up \(index): \(before) -> \(after)")
      XCTAssertGreaterThan(before - after, 60, "A tall single row stopped moving upward")
    }
  }

  func testRunKeepsDraftAndCoordinatorsAcrossRelaunch() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 120
    let work = InteractionPeer()
    let personal = InteractionPeer()
    let relaunchedWork = InteractionPeer(coordinator: work.coordinator)
    let relaunchedPersonal = InteractionPeer(coordinator: personal.coordinator)
    let history = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    var ports: [String] = []
    for peer in [work, personal, relaunchedWork, relaunchedPersonal] {
      addTeardownBlock { await peer.stop() }
      await peer.history(initial: history, pages: [:], latest: history)
      ports.append(String(try await peer.start()))
    }
    let app = XCUIApplication()
    let runs = [UUID().uuidString, UUID().uuidString]
    app.launchEnvironment["AGENT_INTERACTION_ID"] = runs[0]
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.prefix(2).joined(separator: ",")
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = [work, personal]
      .map { $0.coordinator.uuidString }.joined(separator: ",")
    app.launchArguments += ["-notificationsEnabled", "NO"]
    addTeardownBlock { @MainActor in
      if app.state != .notRunning { app.terminate() }
      app.launchEnvironment["AGENT_INTERACTION_CLEANUP"] = "1"
      for run in runs {
        app.launchEnvironment["AGENT_INTERACTION_ID"] = run
        app.launch()
        XCTAssertTrue(app.staticTexts["Interaction fixture cleaned"].waitForExistence(timeout: 5))
        app.terminate()
      }
    }

    app.launch()
    try await eventually {
      let workObserved = await work.observationCount()
      let personalObserved = await personal.observationCount()
      return workObserved > 0 && personalObserved > 0
    }
    app.buttons["Connection"].tap()
    let appearance = app.descendants(matching: .any).matching(identifier: "appearancePicker")
      .firstMatch
    XCTAssertTrue(appearance.waitForExistence(timeout: 5))
    appearance.tap()
    app.buttons["Dark"].tap()
    app.buttons["Done"].tap()

    let composer = app.textViews["Message the coordinator"]
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    XCTAssertTrue(composer.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    composer.tap()
    composer.typeText("@Work ")
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 3))
    let draft = "Invented draft for the next launch"
    composer.typeText(draft)
    app.terminate()

    app.launchEnvironment["AGENT_INTERACTION_PORT"] = ports.suffix(2).joined(separator: ",")
    app.launch()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertTrue(composer.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertEqual(composer.value as? String, draft)
    XCTAssertTrue(app.buttons["To Work"].waitForExistence(timeout: 5))
    try await eventually {
      let workObserved = await relaunchedWork.observationCount()
      let personalObserved = await relaunchedPersonal.observationCount()
      return workObserved > 0 && personalObserved > 0
    }
    app.buttons["Connection"].tap()
    appearance.tap()
    let dark = app.buttons["Dark"]
    XCTAssertTrue(dark.isSelected)
    dark.tap()
    for name in ["Work", "Personal"] {
      let connected = app.buttons.matching(
        NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", name, "Connected")
      ).firstMatch
      XCTAssertTrue(connected.waitForExistence(timeout: 5), "\(name) did not connect")
    }

    app.terminate()
    app.launchEnvironment["AGENT_INTERACTION_ID"] = runs[1]
    app.launch()
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    XCTAssertTrue(composer.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    XCTAssertEqual(composer.value as? String, "Message Beep Boop")
    XCTAssertFalse(app.buttons["To Work"].exists)
    app.buttons["Connection"].tap()
    appearance.tap()
    XCTAssertTrue(app.buttons["System"].isSelected)
  }

  private func launchMessages(
    _ messages: [HistoryMessage], toolDetails: [String: ToolDetails] = [:],
    appearance: String? = nil, commands: [SlashCommand] = [],
    peer: InteractionPeer = InteractionPeer(),
    preserveHistory: Bool = false
  ) async throws -> XCUIApplication {
    continueAfterFailure = false
    executionTimeAllowance = 600
    addTeardownBlock { await peer.stop() }
    if !preserveHistory {
      let history = NativeEventHistory(messages: messages, nextCursor: nil, pageComplete: true)
      await peer.history(initial: history, pages: [:], latest: history)
    }
    await peer.toolDetails(toolDetails)
    await peer.commands(commands)
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_ID"] = UUID().uuidString
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

  private func waitForBackground(_ app: XCUIApplication) {
    let background = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        app.state == .runningBackground || app.state == .runningBackgroundSuspended
      }, object: app)
    XCTAssertEqual(
      XCTWaiter.wait(for: [background], timeout: 5), .completed,
      "Unexpected background state: \(app.state)")
  }

  private func returnToForeground(
    _ app: XCUIApplication, peer: InteractionPeer, waitForSuspension: Bool = false
  ) async throws {
    try await eventually(description: "initial conversation observer") {
      await peer.observationCount() > 0
    }
    let observers = await peer.observationCount()
    XCUIDevice.shared.press(.home)
    if waitForSuspension {
      guard app.wait(for: .runningBackgroundSuspended, timeout: 30) else {
        throw XCTSkip("The test runner kept the app in \(app.state), without suspending it.")
      }
    } else {
      waitForBackground(app)
    }
    app.activate()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    try await eventually(description: "conversation observer reconnect after foreground") {
      await peer.observationCount() > observers
    }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"), object: editor(app))
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
  }

  private func enableSimulatorAutocorrection() throws {
    continueAfterFailure = false
    #if targetEnvironment(simulator)
      func waitForValue(_ value: String, on element: XCUIElement) {
        let settled = XCTNSPredicateExpectation(
          predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(
          XCTWaiter.wait(for: [settled], timeout: 5), .completed, element.debugDescription)
      }
      func tapSwitch(_ element: XCUIElement) {
        // Settings can wrap the actual switch in another accessibility switch.
        let control = element.switches.firstMatch
        (control.exists ? control : element).tap()
      }
      // The native validation jobs own disposable simulators. Settings also
      // broadcasts the preference change to the keyboard's existing process.
      let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
      settings.launch()
      defer { settings.terminate() }
      let correction = settings.switches["Auto-Correction"]
      if !correction.exists {
        let back = settings.buttons["BackButton"]
        if back.exists { back.tap() }
        let keyboard = settings.staticTexts["Keyboard"]
        if !keyboard.exists {
          let general = settings.staticTexts["General"]
          for _ in 0..<6 {
            if general.exists && general.isHittable { break }
            settings.swipeUp()
          }
          XCTAssertTrue(general.isHittable, settings.debugDescription)
          general.tap()
        }
        for _ in 0..<6 {
          if keyboard.exists && keyboard.isHittable { break }
          settings.swipeUp()
        }
        XCTAssertTrue(keyboard.isHittable, settings.debugDescription)
        keyboard.tap()
      }
      XCTAssertTrue(correction.waitForExistence(timeout: 5), settings.debugDescription)
      if correction.value as? String == "1" {
        tapSwitch(correction)
        waitForValue("0", on: correction)
      }
      tapSwitch(correction)
      waitForValue("1", on: correction)
      // First-run Slide to Type onboarding can intercept later key taps.
      let slideToType = settings.switches["Slide to Type"]
      if slideToType.exists {
        for _ in 0..<6 {
          if slideToType.isHittable { break }
          settings.swipeUp()
        }
        XCTAssertTrue(slideToType.isHittable, settings.debugDescription)
        if slideToType.value as? String == "1" { tapSwitch(slideToType) }
        waitForValue("0", on: slideToType)
      }
    #else
      throw XCTSkip("Keyboard preference setup requires a disposable simulator.")
    #endif
  }

  private func recognizedEditorText(_ image: CGImage) throws -> String {
    // A dim placeholder can be visible while Vision sees only the bright buttons.
    let exposed = CIImage(cgImage: image).applyingFilter(
      "CIExposureAdjust", parameters: [kCIInputEVKey: 2])
    let brighter = try XCTUnwrap(CIContext().createCGImage(exposed, from: exposed.extent))
    var recognized: [String] = []
    for input in [image, brighter] {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.recognitionLanguages = ["en-US"]
      request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: input).perform([request])
      recognized += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }
    // Keep both passes so exposure cannot hide submitted text found in the original.
    return recognized.joined(separator: " ")
  }

  private func assertVisibleEditorText(
    _ expected: String, excluding submitted: String? = nil, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    let editor = editor(app)
    let surface = app.descendants(matching: .any).matching(identifier: "messageComposer").firstMatch
    XCTAssertTrue(surface.exists, file: file, line: line)
    let deadline = ContinuousClock.now + .seconds(5)
    var recognized = ""
    var screenshot = surface.screenshot()
    repeat {
      screenshot = surface.screenshot()
      let image = try XCTUnwrap(screenshot.image.cgImage, file: file, line: line)
      recognized = try recognizedEditorText(image)
      let visible = recognized.lowercased().filter { !$0.isWhitespace }
      let containsSubmitted =
        submitted.map {
          visible.contains($0.lowercased().filter { !$0.isWhitespace })
        } ?? false
      if visible.contains(expected.lowercased().filter { !$0.isWhitespace }), !containsSubmitted {
        return
      }
      if ContinuousClock.now >= deadline { break }
      try await Task.sleep(for: .milliseconds(100))
    } while true
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "native-composer-visible-text"
    attachment.lifetime = .keepAlways
    add(attachment)
    let window = XCTAttachment(screenshot: app.screenshot())
    window.name = "native-composer-window"
    window.lifetime = .keepAlways
    add(window)
    let value = editor.value
    let valueType = value.map { String(reflecting: type(of: $0)) } ?? "nil"
    XCTFail(
      "Expected visible editor text \(String(reflecting: expected)); recognized \(String(reflecting: recognized)); accessibility value \(String(reflecting: value)) type \(valueType); capture type \(surface.elementType.rawValue) frame \(surface.frame); editor frame \(editor.frame)",
      file: file, line: line)
  }

  func testPagedHistoryKeepsFollowingTheLiveTailWhileTypingAndSending() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 180
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    await peer.streamRepliesOnSubmit()
    let paragraph =
      "An invented tool result records the parcel inventory and explains the next verification step. "
    let toolText = String(String(repeating: paragraph, count: 100).prefix(8192))
    let dialogue: (Int, Int) -> String = { page, part in
      "Saffron history section \(page) part \(part). This invented conversation keeps the previous questions and answers available while new work arrives. The parcel inventory is consistent and the next task can proceed."
    }
    func page(_ index: Int) -> NativeEventHistory {
      var messages: [HistoryMessage] = []
      for row in 0..<20 {
        let entry = String(1000 + index * 20 + row)
        if row < 18 {
          messages.append(
            .init(
              continuation: false, entryId: entry, finalChunk: true, role: .tool, text: toolText,
              tool: .init(callId: "retained-call-\(entry)", name: "exec", status: .finished)))
        } else {
          messages.append(
            .init(
              continuation: false, entryId: entry, finalChunk: true,
              role: row == 18 ? .user : .final, text: dialogue(index, row)))
        }
      }
      return .init(
        messages: messages, nextCursor: index > 0 ? "page-\(index - 1)" : nil, pageComplete: true)
    }
    let allPages = (0..<25).map(page)
    let historyBytes = allPages.flatMap(\.messages).reduce(0) { $0 + $1.text.utf8.count }
    XCTAssertEqual(allPages.flatMap(\.messages).count, 500)
    XCTAssertLessThan(historyBytes, 4 * 1024 * 1024)
    XCTAssertTrue(allPages.allSatisfy { $0.messages.count == 20 })
    await peer.history(
      initial: allPages[24],
      pages: Dictionary(uniqueKeysWithValues: (0..<24).map { ("page-\($0)", allPages[$0]) }),
      latest: allPages[24])
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    addTeardownBlock { @MainActor in app.terminate() }
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    let recent = app.staticTexts.matching(NSPredicate(format: "label == %@", dialogue(24, 19)))
      .firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 5))
    for _ in 0..<100 {
      if await peer.cursors().count == 24 { break }
      let load = app.buttons["Load earlier messages"]
      if load.exists && load.isHittable && load.isEnabled {
        load.tap()
      } else {
        transcript.swipeDown(velocity: .fast)
      }
    }
    try await eventually(description: "all 24 real earlier-page requests") {
      await peer.cursors().count == 24
    }
    let loadedCursors = await peer.cursors()
    XCTAssertEqual(loadedCursors, (0..<24).reversed().map { "page-\($0)" })
    XCTAssertTrue(app.buttons["Load earlier messages"].waitForNonExistence(timeout: 5))
    let earlier = app.staticTexts.matching(NSPredicate(format: "label == %@", dialogue(0, 18)))
      .firstMatch
    for _ in 0..<5 {
      if earlier.exists && earlier.isHittable { break }
      transcript.swipeDown()
    }
    XCTAssertTrue(earlier.isHittable, app.debugDescription)
    for _ in 0..<40 {
      if recent.exists && recent.isHittable && !app.buttons["latest-messages"].exists { break }
      transcript.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(
      recent.isHittable, "Return to the retained live tail without replacing it through Latest")
    XCTAssertFalse(app.buttons["latest-messages"].exists)
    let composer = editor(app)
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    try await returnToForeground(app, peer: peer)
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    XCTAssertTrue(
      recent.isHittable,
      "The retained conversation must survive foreground reconciliation")
    try await peer.beginReply(
      "An invented reply starts while the large retained conversation is open. ")
    XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
    let stream = Task.detached {
      for index in 0..<160 {
        try Task.checkCancellation()
        try await peer.beginReply("Progress \(index): the parcel inventory remains consistent. ")
        try await Task.sleep(for: .milliseconds(30))
      }
    }
    defer { stream.cancel() }
    let note = "Juniper parcel: send after foreground with a busy retained conversation."
    for sendIndex in 0..<2 {
      composer.typeText(note)
      try await assertVisibleEditorText("Juniper parcel", in: app)
      if sendIndex == 1 {
        try await returnToForeground(app, peer: peer)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        try await assertVisibleEditorText("Juniper parcel", in: app)
      }
      let send = app.buttons["Send message"]
      XCTAssertTrue(send.waitForExistence(timeout: 3))
      XCTAssertTrue(send.isEnabled)
      send.tap()
      try await assertVisibleEditorText("Message Beep Boop", excluding: "Juniper parcel", in: app)
      XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
      XCTAssertTrue(app.keyboards.firstMatch.exists)
      try await peer.beginReply(
        "Another native stream update follows retained-history Send \(sendIndex). ")
      try await assertVisibleEditorText("Message Beep Boop", excluding: "Juniper parcel", in: app)
      let followsTail = app.buttons["latest-messages"].waitForNonExistence(timeout: 5)
      if !followsTail {
        let failure = XCTAttachment(screenshot: app.screenshot())
        failure.name = "native-composer-window"
        failure.lifetime = .keepAlways
        add(failure)
      }
      XCTAssertTrue(followsTail, "Streaming must continue following the real live tail")
    }
    try await stream.value
    let inputs = await peer.inputs()
    XCTAssertEqual(inputs.map(\.text), [note, note])
    let final = XCTAttachment(screenshot: app.screenshot())
    final.name = "paged-retained-history-focused-composer-after-send"
    final.lifetime = .keepAlways
    add(final)
  }

  func testSendClearsTheNativeComposerAndKeepsTheKeyboardForTheNextMessage() async throws {
    let app = try await launchMessages([])
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    for (visibleLine, text) in [
      ("Orchid beacon", "Orchid beacon\nThe first note expands the native editor."),
      ("Maple lantern", "Maple lantern\nThe next note uses the same focused editor."),
    ] {
      composer.typeText(text)
      try await assertVisibleEditorText(visibleLine, in: app)
      let send = app.buttons["Send message"]
      XCTAssertTrue(send.waitForExistence(timeout: 3))
      XCTAssertTrue(send.isEnabled)
      send.tap()
      // Check rendered glyphs before polling the transcript or changing focus.
      // Accessibility alone can already report an empty value.
      try await assertVisibleEditorText("Message Beep Boop", excluding: visibleLine, in: app)
      XCTAssertTrue(app.staticTexts[text].waitForExistence(timeout: 3), app.debugDescription)
      XCTAssertTrue(app.keyboards.firstMatch.exists)
    }
  }

  func testRotationKeepsTheLiveTailAndOlderReadingPosition() async throws {
    let paragraph =
      "The orchard inventory is ready for review. Each crate has a recorded destination and the next delivery can proceed once the remaining labels are checked."
    let messages = (0..<60).map { index in
      HistoryMessage(
        continuation: false, entryId: "rotation-\(index)", finalChunk: true, role: .final,
        text: "Orchard section \(index). \(paragraph)")
    }
    let peer = InteractionPeer()
    let app = try await launchMessages(messages, peer: peer)
    continueAfterFailure = true
    defer { XCUIDevice.shared.orientation = .portrait }
    let transcript = app.scrollViews["transcript"]
    let latest = app.staticTexts.matching(
      NSPredicate(format: "label == %@", messages.last!.text)
    ).firstMatch
    try await eventually(description: "initial live tail") { latest.isHittable }
    XCTAssertTrue(app.buttons["latest-messages"].waitForNonExistence(timeout: 3))
    for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
      XCUIDevice.shared.orientation = orientation
      try await eventually(description: "live tail after rotation") {
        latest.isHittable && !app.buttons["latest-messages"].exists
      }
    }
    transcript.swipeDown()
    XCTAssertTrue(app.buttons["latest-messages"].waitForExistence(timeout: 3))
    // A shorter landscape viewport cannot retain every portrait row. Preserve
    // the leading readable message rather than an arbitrary row near the bottom.
    let top = app.navigationBars.firstMatch.frame.maxY
    let bottom = app.descendants(matching: .any).matching(identifier: "messageComposer")
      .firstMatch.frame.minY
    let leading = try XCTUnwrap(
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Orchard section "))
        .allElementsBoundByIndex.first {
          $0.isHittable && $0.frame.minY >= top && $0.frame.maxY <= bottom
        }, app.debugDescription)
    let earlier = app.staticTexts.matching(NSPredicate(format: "label == %@", leading.label))
      .firstMatch
    XCUIDevice.shared.orientation = .landscapeLeft
    try await eventually(description: "older reading position after rotation") {
      earlier.isHittable && app.buttons["latest-messages"].exists
    }
    try await peer.beginReply("An incoming update must preserve the older reading position.")
    XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
    XCTAssertTrue(earlier.isHittable, app.debugDescription)
    XCTAssertTrue(app.buttons["latest-messages"].exists)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "rotation-preserves-older-reading-position"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    for _ in 0..<8 {
      if !app.buttons["latest-messages"].exists { break }
      transcript.swipeUp(velocity: .fast)
    }
    XCTAssertFalse(app.buttons["latest-messages"].exists)
    let fresh = "A fresh reply follows the reader's return to the live tail."
    try await peer.reply(fresh, id: "after-reader-return")
    XCTAssertTrue(app.staticTexts[fresh].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts[fresh].isHittable, app.debugDescription)
    XCTAssertFalse(app.buttons["latest-messages"].exists)
  }

  func testForegroundAndRelaunchKeepNewTypingWithoutRestoringSentText() async throws {
    let peer = InteractionPeer()
    await peer.streamRepliesOnSubmit()
    let app = try await launchMessages([], peer: peer)
    let first = "Orchid beacon: the first admitted note."
    continueAfterFailure = true
    let second = "Maple lantern: keep the next unsent note across relaunch."
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    composer.typeText(first)
    app.buttons["Send message"].tap()
    try await assertVisibleEditorText("Message Beep Boop", excluding: "Orchid beacon", in: app)
    composer.typeText(second)
    try await returnToForeground(app, peer: peer)
    try await assertVisibleEditorText("Maple lantern", excluding: "Orchid beacon", in: app)
    app.terminate()
    app.launch()
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", second), object: editor(app))
    let result = await XCTWaiter.fulfillment(of: [restored], timeout: 5)
    XCTAssertEqual(result, .completed, app.debugDescription)
    guard result == .completed else { return }
    try await assertVisibleEditorText("Maple lantern", excluding: "Orchid beacon", in: app)
    try await eventually(description: "reopened production connection") {
      app.buttons["Send message"].isEnabled
    }
    editor(app).tap()
    app.buttons["Send message"].tap()
    try await assertVisibleEditorText("Message Beep Boop", excluding: "Maple lantern", in: app)
    try await eventually(description: "both inputs admitted once") {
      await peer.inputs().count == 2
    }
    let inputs = await peer.inputs()
    XCTAssertEqual(inputs.map(\.text), [first, second])
    try await assertVisibleEditorText("Message Beep Boop", excluding: "Maple lantern", in: app)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "production-startup-retained-composer-after-send"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testSendClearsVisibleTextAfterReturningToTheForeground() async throws {
    let peer = InteractionPeer()
    await peer.streamRepliesOnSubmit()
    let app = try await launchMessages([], peer: peer)
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    for (visibleLine, text) in [
      ("Juniper parcel", "Juniper parcel\nA note typed after returning to the foreground."),
      ("Cedar signal", "Cedar signal\nAnother note after the next foreground transition."),
      (
        "Granite return",
        """
        A longer note fills the native editor.
        Its first lines scroll out of view.
        The draft spans more than six lines.
        Incoming output continues to stream.
        Sending must collapse the editor.
        The keyboard stays available.
        The next draft starts empty.
        Granite return
        """
      ),
    ] {
      try await returnToForeground(app, peer: peer)
      XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
      composer.typeText(text)
      try await assertVisibleEditorText(visibleLine, in: app)
      let send = app.buttons["Send message"]
      XCTAssertTrue(send.waitForExistence(timeout: 3))
      XCTAssertTrue(send.isEnabled)
      send.tap()
      try await assertVisibleEditorText("Message Beep Boop", excluding: visibleLine, in: app)
      XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
      let update = "Streaming continues for \(visibleLine)."
      try await peer.beginReply(update)
      XCTAssertTrue(
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", update)).firstMatch
          .waitForExistence(timeout: 3))
      try await assertVisibleEditorText("Message Beep Boop", excluding: visibleLine, in: app)
      let sent = app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
      XCTAssertTrue(sent.waitForExistence(timeout: 3), app.debugDescription)
      XCTAssertTrue(app.keyboards.firstMatch.exists)
    }
  }

  func testSendClearsAnUnacceptedAutocorrectionAndKeepsNewIdenticalTyping() async throws {
    try enableSimulatorAutocorrection()
    let peer = InteractionPeer()
    await peer.streamRepliesOnSubmit()
    let app = try await launchMessages([], peer: peer)
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    try await returnToForeground(app, peer: peer)
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    // Predictive suggestions alone do not establish that autocorrection is on.
    for key in ["T", "e", "h", "space"] { app.keys[key].tap() }
    let corrected = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        (composer.value as? String)?.lowercased() == "the "
      }, object: composer)
    XCTAssertEqual(XCTWaiter.wait(for: [corrected], timeout: 3), .completed, app.debugDescription)
    composer.press(forDuration: 1)
    let selectAll = action("Select All", app: app)
    XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
    selectAll.tap()
    app.keys["delete"].tap()
    try await assertVisibleEditorText("Message Beep Boop", in: app)
    let input = "The parcel is teh"
    // Exercise the software keyboard and its prediction UI with real key taps.
    for character in input {
      app.keys[character == " " ? "space" : String(character)].tap()
    }
    let correction = action("the", app: app)
    try await eventually(description: "pending native autocorrection") { correction.exists }
    let note = try XCTUnwrap(composer.value as? String)
    XCTAssertEqual(note.lowercased(), input.lowercased())
    let pending = XCTAttachment(screenshot: app.screenshot())
    pending.name = "unaccepted-native-autocorrection"
    pending.lifetime = .keepAlways
    add(pending)
    // Keep the correction pending: no space, suggestion tap or focus change.
    app.buttons["Send message"].tap()
    try await assertVisibleEditorText("Message Beep Boop", excluding: "The parcel", in: app)
    XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.keyboards.firstMatch.exists)
    for character in note {
      app.keys[character == " " ? "space" : String(character)].tap()
    }
    let typed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", note), object: composer)
    XCTAssertEqual(XCTWaiter.wait(for: [typed], timeout: 3), .completed, app.debugDescription)
    let update = "The next draft stays while output streams."
    try await peer.beginReply(update)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", update)).firstMatch
        .waitForExistence(timeout: 3))
    XCTAssertEqual(composer.value as? String, note)
    try await assertVisibleEditorText("The parcel", in: app)
  }

  func testSendClearsVisibleTextAfterActualSuspension() async throws {
    let peer = InteractionPeer()
    await peer.streamRepliesOnSubmit()
    let app = try await launchMessages([], peer: peer)
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    let note = "Cypress packet\nThis saved note returns after genuine app suspension."
    composer.tap()
    composer.typeText(note)
    try await assertVisibleEditorText("Cypress packet", in: app)
    try await returnToForeground(app, peer: peer, waitForSuspension: true)
    try await assertVisibleEditorText("Cypress packet", in: app)
    composer.tap()
    app.buttons["Send message"].tap()
    try await assertVisibleEditorText("Message Beep Boop", excluding: "Cypress packet", in: app)
    XCTAssertTrue(app.buttons["Stop response"].waitForExistence(timeout: 3))
    try await peer.beginReply("Streaming continues after suspension.")
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "Streaming continues after suspension.")
      ).firstMatch.waitForExistence(timeout: 3))
    try await assertVisibleEditorText("Message Beep Boop", excluding: "Cypress packet", in: app)
    XCTAssertTrue(app.keyboards.firstMatch.exists)
  }

  func testSendClearsTheFocusedDraftImmediatelyAfterAnAppSwitch() async throws {
    try enableSimulatorAutocorrection()
    let peer = InteractionPeer()
    await peer.streamRepliesOnSubmit()
    let output = String(
      repeating: "The invented inventory result keeps its recorded quantities. ", count: 120)
    let messages = (0..<480).map { index in
      HistoryMessage(
        continuation: false, entryId: "retained-\(index)", finalChunk: true,
        role: index.isMultiple(of: 10) ? .final : .tool,
        text: index.isMultiple(of: 10) ? "Recorded inventory section \(index)." : output,
        tool: index.isMultiple(of: 10)
          ? nil : .init(callId: "retained-call-\(index)", name: "exec", status: .finished))
    }
    let app = try await launchMessages(messages, peer: peer)
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    composer.tap()
    XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    defer { settings.terminate() }
    var expected: [String] = []
    // Repeated submissions can change native suggestions. Use a different
    // typo for each Send and keep them separate from the identical-typing test.
    let drafts = [
      ("The parcel will arive", "arrive"),
      ("The parcel has an adress", "address"),
      ("The parcel arrives tomorow", "tomorrow"),
    ]
    for (draft, correction) in drafts {
      for character in draft {
        app.keys[character == " " ? "space" : String(character)].tap()
      }
      try await eventually(description: "pending correction before the app switch") {
        self.action(correction, app: app).exists
      }
      let text = try XCTUnwrap(composer.value as? String)
      expected.append(text)
      let observations = await peer.observationCount()
      settings.activate()
      waitForBackground(app)
      app.activate()
      try await eventually(description: "resumed conversation observer") {
        await peer.observationCount() > observations
      }
      // Keep the existing editor focused across the switch and send. A new
      // editor tap can settle the keyboard state that this test exercises.
      let send = app.buttons["Send message"]
      try await eventually(description: "send available after the app switch") { send.isEnabled }
      send.tap()
      try await eventually(description: "the resumed draft admitted once") {
        await peer.inputs().count == expected.count
      }
      try await assertVisibleEditorText("Message Beep Boop", excluding: "The parcel", in: app)
      let inputs = await peer.inputs()
      XCTAssertEqual(inputs.map(\.text), expected)
      XCTAssertTrue(app.keyboards.firstMatch.exists)
      try await peer.beginReply("The admitted note is being processed.")
      try await assertVisibleEditorText("Message Beep Boop", excluding: "The parcel", in: app)
    }
  }

  func testCommandMenuPreservesTheNoteAndReplacesThePreviousCommand() async throws {
    let feedback = SlashCommand(description: "Report a problem", usage: "/feedback <note>")
    let help = SlashCommand(description: "Show supported commands", usage: "/help")
    let app = try await launchMessages([], commands: [feedback, help])
    let composer = editor(app)
    XCTAssertTrue(composer.waitForExistence(timeout: 5))
    let note = "Keep this note and /tmp/example.txt."
    composer.tap()
    composer.typeText(note)
    for command in [feedback, help, help] {
      app.buttons["composerMenu"].tap()
      action("Commands", app: app).tap()
      let choice = app.buttons.matching(
        NSPredicate(
          format: "label == %@ OR label == %@", command.usage,
          "\(command.usage), \(command.description)")
      ).firstMatch
      XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
      choice.tap()
      let name = command.usage.prefix(while: { !$0.isWhitespace })
      XCTAssertEqual(
        composer.value as? String, "\(name) \(note)",
        "Selecting \(command.usage) must preserve the note"
      )
      try await assertVisibleEditorText("Keep this note", in: app)
    }
  }

  private func feedButton(_ kind: String, row: String, app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "\(kind):", "/\(row)")
    ).firstMatch
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
    let sendInEitherMode = app.buttons.matching(
      NSPredicate(format: "label IN %@", ["Send message", "Queue follow-up"])
    ).firstMatch
    XCTAssertFalse(sendInEitherMode.isEnabled)
    app.terminate()
    app.launch()
    if app.buttons["dismissConnection"].waitForExistence(timeout: 3) {
      app.buttons["dismissConnection"].tap()
    }
    let restored = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", draft), object: editor(app))
    XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed, app.debugDescription)
    XCTAssertFalse(sendInEitherMode.isEnabled)
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
    pasteCopiedText(text, into: composer, app: app)
    XCTAssertEqual(composer.value as? String, text)
    try await clearComposer(composer, excluding: "Alpha bracket", app: app)
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
    pasteCopiedText("Alpha", into: composer, app: app)
    XCTAssertEqual(composer.value as? String, "Alpha")
  }

  func testCopyButtonsOnQuotesAndCodePasteTheirPlainTextThroughComposer() async throws {
    let app = try await launchMessages([
      .init(
        continuation: false, entryId: "1", finalChunk: true, role: .final,
        text: """
          **Mira Vale**

          > Lunch at noon works for me.

          **Tobin Ash**

          > The blue folder is ready.
          >
          > Please bring the **spare** key on Friday.

          Send either one when you are ready.

          ```swift
          let total = 2 + 3
          print(total)
          ```

          ```
          echo ready
          ```
          """)
    ])
    let copyQuotes = app.buttons.matching(NSPredicate(format: "label == %@", "Copy quote"))
    let copyCodes = app.buttons.matching(NSPredicate(format: "label == %@", "Copy code"))
    XCTAssertTrue(copyCodes.element(boundBy: 1).waitForExistence(timeout: 5))
    XCTAssertEqual(copyQuotes.count, 2)
    XCTAssertEqual(copyCodes.count, 2)
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "quote-copy-buttons"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    XCTAssertLessThan(
      copyCodes.element(boundBy: 1).frame.midY, app.staticTexts["echo ready"].frame.minY,
      "The Copy button of a fence with no language must sit above its code")
    copyQuotes.element(boundBy: 1).tap()
    let composer = editor(app)
    let quote = "The blue folder is ready.\n\nPlease bring the spare key on Friday."
    pasteCopiedText(quote, into: composer, app: app)
    XCTAssertEqual(composer.value as? String, quote)
    try await clearComposer(composer, excluding: "blue folder", app: app)
    copyCodes.element(boundBy: 0).tap()
    let code = "let total = 2 + 3\nprint(total)"
    pasteCopiedText(code, into: composer, app: app)
    XCTAssertEqual(composer.value as? String, code)
    try await clearComposer(composer, excluding: "total", app: app)
    copyCodes.element(boundBy: 1).tap()
    pasteCopiedText("echo ready", into: composer, app: app)
    XCTAssertEqual(composer.value as? String, "echo ready")
    app.staticTexts["Lunch at noon works for me."].press(forDuration: 1)
    XCTAssertTrue(
      action("Copy message", app: app).waitForExistence(timeout: 3),
      "A long press on quote text must still open the message menu")
  }

  func testOneCopyButtonOnAQuoteCopiesEverythingUnderItsBar() async throws {
    let app = try await launchMessages([
      .init(
        continuation: false, entryId: "1", finalChunk: true, role: .final,
        text: """
          > Hello Odo, please bring:
          >
          > - the rope
          > - the tape
          >
          > Thanks, see you at six.

          > Run this first:
          >
          > ```sh
          > echo inside
          > ```

          1. **Pim Rowan**

             > Draft for Pim.

          2. **Lark Hale**

             > Draft for Lark.
             >
             > Second paragraph for Lark.

          3. **Wren Tolle**

             > ```
             > echo listed
             > ```

          The plan:

          > | Day | Task |
          > | --- | --- |
          > | Friday | Rope |
          """)
    ])
    let copyQuotes = app.buttons.matching(NSPredicate(format: "label == %@", "Copy quote"))
    let copyCodes = app.buttons.matching(NSPredicate(format: "label == %@", "Copy code"))
    XCTAssertTrue(copyQuotes.element(boundBy: 5).waitForExistence(timeout: 5))
    XCTAssertEqual(copyQuotes.count, 6, "Each quote bar must hold exactly one Copy button")
    XCTAssertEqual(copyCodes.count, 0, "A code block under a quote bar must have no Copy button")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "quote-shapes"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    let codeInAListItem = app.staticTexts["echo listed"].frame
    XCTAssertEqual(
      app.staticTexts["The plan:"].frame.minY - codeInAListItem.maxY,
      app.staticTexts["Pim Rowan"].frame.minY - app.staticTexts["echo inside"].frame.maxY,
      accuracy: 0.5,
      "A list row must be as tall as the quote in it when that quote opens with a code block")
    let paddingAroundCode: CGFloat = 12
    XCTAssertEqual(
      copyQuotes.element(boundBy: 4).frame.minY, codeInAListItem.minY - paddingAroundCode,
      accuracy: 0.5,
      "The Copy button of a quote in a list item that opens with a code block must be at its top")
    let tableButton = copyQuotes.element(boundBy: 5).frame
    let paddingAroundATable: CGFloat = 12
    XCTAssertGreaterThanOrEqual(
      tableButton.minY, app.staticTexts["Day"].frame.minY - paddingAroundATable - 0.5,
      "The Copy button of a quote that opens with a table must not rise above the quote")
    XCTAssertLessThanOrEqual(
      tableButton.maxY, app.staticTexts["Rope"].frame.maxY + paddingAroundATable + 0.5,
      "The Copy button of a quote that opens with a table must not fall below the quote")
    copyQuotes.element(boundBy: 0).tap()
    let composer = editor(app)
    let quoteWithAList =
      "Hello Odo, please bring:\n\n• the rope\n• the tape\n\nThanks, see you at six."
    pasteCopiedText(quoteWithAList, into: composer, app: app)
    XCTAssertEqual(composer.value as? String, quoteWithAList)
    try await clearComposer(composer, excluding: "please bring", app: app)
    copyQuotes.element(boundBy: 3).tap()
    let quoteInAListItem = "Draft for Lark.\n\nSecond paragraph for Lark."
    pasteCopiedText(quoteInAListItem, into: composer, app: app)
    XCTAssertEqual(composer.value as? String, quoteInAListItem)
  }

  private func pasteCopiedText(_ expected: String, into composer: XCUIElement, app: XCUIApplication)
  {
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

  private func clearComposer(
    _ composer: XCUIElement, excluding pasted: String, app: XCUIApplication
  ) async throws {
    // Select the actual native range rather than assuming the insertion point
    // starts at the end, then wait for the real editor to finish the deletion.
    composer.press(forDuration: 1)
    let selectAll = action("Select All", app: app)
    XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
    selectAll.tap()
    let delete = app.keys["delete"]
    XCTAssertTrue(delete.exists)
    delete.tap()
    try await assertVisibleEditorText("Message Beep Boop", excluding: pasted, in: app)
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
      let group = feedButton("activity", row: "tool:shell-card", app: app)
      XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
      let collapsed = XCTAttachment(screenshot: app.screenshot())
      collapsed.name = "native-shell-collapsed-\(appearance)"
      collapsed.lifetime = .keepAlways
      add(collapsed)
      group.tap()
      let command = feedButton("activity-item", row: "tool:shell-card", app: app)
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

  func testExpandedGenericToolShowsRetainedOutputOnceAndKeepsTruncationNotice() async throws {
    let output = "The orchard parcel labels are ready."
    let additional = output + "\nA second retained label was verified."
    let cases: [(content: ToolDetailContent, expected: String, truncated: Bool)] = [
      (.text(.init(text: output, truncated: false)), output, false),
      (.text(.init(text: additional, truncated: false)), additional, false),
      (.text(.init(text: output, truncated: true)), output, true),
      (.text(.init(text: "The orchard", truncated: true)), output, true),
      (.text(.init(text: "", truncated: false)), output, false),
      (.unavailable(.init(reason: .notRecorded)), output, false),
    ]
    for (index, value) in cases.enumerated() {
      let details = ToolDetails.available(
        .init(
          callId: "single-output", input: .unavailable(.init(reason: .notRecorded)),
          name: "lookup_labels", output: value.content,
          status: .finished))
      let app = try await launchMessages(
        [
          .init(
            continuation: false, entryId: "single-output-entry", finalChunk: true, role: .tool,
            text: output,
            tool: .init(callId: "single-output", name: "lookup_labels", status: .finished))
        ], toolDetails: ["single-output": details])
      continueAfterFailure = true
      let group = feedButton("activity", row: "tool:single-output", app: app)
      XCTAssertTrue(group.waitForExistence(timeout: 5))
      group.tap()
      feedButton("activity-item", row: "tool:single-output", app: app).tap()
      XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))
      XCTAssertEqual(
        app.staticTexts.matching(NSPredicate(format: "label == %@", value.expected)).count, 1)
      if value.expected != output {
        XCTAssertFalse(
          app.staticTexts.matching(NSPredicate(format: "label == %@", output)).firstMatch.exists)
      }
      XCTAssertEqual(
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Output")).count, 1)
      XCTAssertEqual(app.staticTexts["Output truncated."].exists, value.truncated)
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "native-generic-output-once-\(index)"
      screenshot.lifetime = .keepAlways
      add(screenshot)
    }
  }

  func testATapOnAScreenshotUnderItsToolActivityPreviewsTheRetainedImage() async throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let png = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 48), format: format)
      .pngData { context in
        for (index, color) in [UIColor.systemRed, .systemGreen, .systemBlue].enumerated() {
          color.setFill()
          context.fill(CGRect(x: index * 32, y: 0, width: 32, height: 48))
        }
      }
    let screenshot = AttachmentRef(
      id: "33333333-3333-4333-8333-333333333333", mediaType: "image/png",
      name: "browser-screenshot-invented.png",
      sha256: SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined(),
      sizeBytes: png.count)
    let peer = InteractionPeer()
    await peer.retain(png, id: screenshot.id)
    let app = try await launchMessages(
      [
        .init(
          continuation: false, entryId: "41", finalChunk: true, role: .tool, text: "",
          tool: .init(callId: "screenshot-call", name: "browser_screenshot", status: .running)),
        .init(
          attachments: [screenshot], continuation: false, entryId: "42", finalChunk: true,
          role: .tool, text: "Captured tab 7 as attachment \(screenshot.id).",
          tool: .init(callId: "screenshot-call", name: "browser_screenshot", status: .finished)),
      ], peer: peer)
    XCTAssertTrue(
      feedButton("activity", row: "tool:screenshot-call", app: app).waitForExistence(timeout: 5))
    let attachment = app.buttons.matching(
      NSPredicate(format: "label CONTAINS %@", screenshot.name)
    ).firstMatch
    XCTAssertTrue(
      attachment.waitForExistence(timeout: 5), "The screenshot is listed under its tool's activity")
    attachment.tap()
    // QuickLook may hide its title and Done button, so the drawn image is the proof.
    let image = app.otherElements["QLPreviewControllerView"].images.firstMatch
    let opened = image.waitForExistence(timeout: 10)
    let hierarchy = XCTAttachment(string: app.debugDescription)
    hierarchy.name = "screenshot-preview-hierarchy"
    add(hierarchy)
    XCTAssertTrue(opened, "The preview opens on the screenshot")
    XCTAssertFalse(app.alerts.firstMatch.exists, "The download did not fail")
    let downloads = await peer.downloads()
    XCTAssertEqual(downloads, [screenshot.id], "The preview downloads the retained screenshot")
    let frame = image.frame
    XCTAssertEqual(frame.width, frame.height * 2, accuracy: 1, "The image is 2:1")
    let shown = app.screenshot()
    let capture = try XCTUnwrap(shown.image.cgImage)
    let scale = CGFloat(capture.width) / app.frame.width
    var pixels = [UInt8](repeating: 0, count: capture.width * capture.height * 4)
    let context = try XCTUnwrap(
      CGContext(
        data: &pixels, width: capture.width, height: capture.height, bitsPerComponent: 8,
        bytesPerRow: capture.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(capture, in: CGRect(x: 0, y: 0, width: capture.width, height: capture.height))
    let strongest = (0..<3).map { stripe in
      let x = Int((frame.minX + frame.width * CGFloat(stripe * 2 + 1) / 6) * scale)
      let pixel = (Int(frame.midY * scale) * capture.width + x) * 4
      let rgb = pixels[pixel..<pixel + 3]
      return rgb.firstIndex(of: rgb.max() ?? 0).map { $0 - pixel }
    }
    XCTAssertEqual(strongest, [0, 1, 2], "The preview draws the red, green and blue stripes")
    let evidence = XCTAttachment(screenshot: shown)
    evidence.name = "browser-screenshot-preview-from-tool-activity"
    evidence.lifetime = .keepAlways
    add(evidence)
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
    let group = feedButton("activity", row: "entry:1:0", app: app)
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

  func testConversationSettingsFilterModelsByProviderAndRoundTripMissingSelections() async throws {
    continueAfterFailure = false
    executionTimeAllowance = 90
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let history = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await peer.history(initial: history, pages: [:], latest: history)
    func option(_ provider: ModelProvider, _ id: String, _ name: String) -> ModelOption {
      .init(fast: false, modelId: id, name: name, provider: provider, reasoning: [.low])
    }
    await peer.settings(
      .init(
        configured: .init(
          catalog: [
            option(.google, "zeta", "Zeta model"),
            option(.google, "alpha", "Alpha model"),
            option(.openai, "shared", "Shared OpenAI model"),
            option(.openai, "only-openai", "OpenAI only model"),
            option(.anthropic, "shared", "Shared Anthropic model"),
            option(.anthropic, "only-anthropic", "Anthropic only model"),
          ], conversationId: "fixture-root",
          model: .init(fast: false, modelId: "retired-model", provider: .azure)),
        effective: nil))
    let app = XCUIApplication()
    app.launchEnvironment["AGENT_INTERACTION_PORT"] = String(try await peer.start())
    app.launchEnvironment["AGENT_INTERACTION_COORDINATOR"] = peer.coordinator.uuidString
    app.launchArguments += ["-notificationsEnabled", "NO"]
    app.launch()
    defer { app.terminate() }
    app.buttons["Connection"].tap()
    app.buttons["Conversation settings"].tap()
    let provider = app.buttons["conversationProviderPicker"]
    let model = app.buttons["conversationModelPicker"]
    XCTAssertTrue(provider.waitForExistence(timeout: 5), app.debugDescription)

    // A saved pair missing from the catalog remains visible; opening its menus writes nothing.
    model.tap()
    XCTAssertTrue(action("retired-model", app: app).waitForExistence(timeout: 3))
    XCTAssertFalse(action("Alpha model", app: app).exists)
    app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    provider.tap()
    XCTAssertTrue(action("azure", app: app).waitForExistence(timeout: 3))
    // Two Google models still produce one provider entry.
    XCTAssertEqual(
      app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "google")).count,
      1)
    action("google", app: app).tap()

    func expectPair(_ selectedProvider: ModelProvider, _ id: String) async throws {
      try await eventually(description: "atomic provider/model control") {
        await peer.settingsControls().last?.change
          == .setModel(.init(modelId: id, provider: selectedProvider))
      }
      let enabled = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "enabled == true"), object: provider)
      XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 3), .completed)
    }
    // Catalog order is deliberately reversed: fallback is stable model-ID order.
    try await expectPair(.google, "alpha")
    model.tap()
    XCTAssertTrue(action("Alpha model", app: app).waitForExistence(timeout: 3))
    XCTAssertTrue(action("Zeta model", app: app).exists)
    XCTAssertFalse(action("Shared OpenAI model", app: app).exists)
    XCTAssertFalse(action("Alpha model · google", app: app).exists)
    action("Zeta model", app: app).tap()
    try await expectPair(.google, "zeta")

    provider.tap()
    action("openai", app: app).tap()
    try await expectPair(.openai, "only-openai")
    model.tap()
    XCTAssertTrue(action("Shared OpenAI model", app: app).waitForExistence(timeout: 3))
    XCTAssertFalse(action("Shared Anthropic model", app: app).exists)
    action("Shared OpenAI model", app: app).tap()
    try await expectPair(.openai, "shared")
    provider.tap()
    action("anthropic", app: app).tap()
    // The same model ID belongs to two providers; retain the ID, never the old provider.
    try await expectPair(.anthropic, "shared")
    model.tap()
    XCTAssertTrue(action("Shared Anthropic model", app: app).waitForExistence(timeout: 3))
    XCTAssertTrue(action("Anthropic only model", app: app).exists)
    XCTAssertFalse(action("Shared OpenAI model", app: app).exists)
    action("Shared Anthropic model", app: app).tap()

    // Re-read the fixture over the actual settings protocol, not just the local picker binding.
    let beforeRefresh = await peer.settingsControls().count
    app.buttons["Refresh"].tap()
    try await eventually(description: "fresh settings read") {
      let requests = await peer.settingsControls()
      return requests.count > beforeRefresh && requests.last?.change == nil
    }
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format: "label == %@", "Configured, anthropic/shared · Provider default · Fast off")
      )
      .firstMatch.waitForExistence(timeout: 3), app.debugDescription)
    model.tap()
    XCTAssertTrue(action("Shared Anthropic model", app: app).waitForExistence(timeout: 3))
    action("Shared Anthropic model", app: app).tap()
    let changes = await peer.settingsControls().compactMap(\.change)
    XCTAssertEqual(
      changes,
      [
        .setModel(.init(modelId: "alpha", provider: .google)),
        .setModel(.init(modelId: "zeta", provider: .google)),
        .setModel(.init(modelId: "only-openai", provider: .openai)),
        .setModel(.init(modelId: "shared", provider: .openai)),
        .setModel(.init(modelId: "shared", provider: .anthropic)),
      ])
    let inputs = await peer.inputs()
    XCTAssertTrue(inputs.isEmpty)
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
    XCTAssertTrue(app.buttons["Details for Job: Original run title"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Details for Update"].exists)
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
    let group = feedButton("activity", row: "tool:call-75", app: app)
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

  func testConsecutiveBoldReasoningSummariesRenderWithoutDelimiters() async throws {
    let app = try await launchMessages([
      .init(
        continuation: false, entryId: "thinking-merge", finalChunk: true, role: .thinking,
        text: "**Inspecting report status****Reviewing message text**"),
      .init(
        continuation: false, entryId: "tool-1", finalChunk: true,
        presentation: .command(.init(command: "echo ok", durationMs: 4, exitCode: 0)),
        role: .tool, text: "ok", tool: .init(callId: "c1", name: "exec", status: .finished)),
    ])
    let group = feedButton("activity", row: "entry:thinking-merge:0", app: app)
    XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
    group.tap()
    XCTAssertTrue(app.staticTexts["Inspecting report status"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Reviewing message text"].exists)
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS '****'")).count, 0)
  }

  func testReconnectRetainsAllReasoningSummariesAndOpenShellCardPosition() async throws {
    struct Output: Encodable {
      let type = "process"
      let exitCode = 0
      enum CodingKeys: String, CodingKey {
        case type, stdout, stderr, truncated
        case exitCode = "exit_code"
      }
      let stdout = "Shell card stays anchored during reconnect"
      let stderr = ""
      let truncated = false
    }
    let output = Output()
    let details = ToolDetails.available(
      .init(
        callId: "c5",
        input: .text(.init(text: #"{"program":"printf","args":["anchored"]}"#, truncated: false)),
        name: "exec",
        output: .text(
          .init(
            text: String(decoding: try JSONEncoder().encode(output), as: UTF8.self),
            truncated: false)),
        status: .finished))
    let peer = InteractionPeer()
    let initialWithEarlierPage = NativeEventHistory(
      messages: [
        .init(
          continuation: false, entryId: "100", finalChunk: true, role: .final, text: "Earlier setup"
        )
      ], nextCursor: "99", pageComplete: true)
    await peer.history(initial: initialWithEarlierPage, pages: [:], latest: initialWithEarlierPage)
    let app = try await launchMessages(
      [], toolDetails: ["c5": details], peer: peer, preserveHistory: true)
    try await eventually { await peer.observationCount() > 0 }

    let steps = [
      ("Summary 1", "c1", "101", "102"),
      ("Summary 2", "c2", "103", "104"),
      ("Summary 3", "c3", "120", "121"),
      ("Summary 4", "c4", "124", "125"),
    ]
    for (summary, callID, assistantID, resultID) in steps {
      try await peer.publish(.activity(.init(activity: .thinking(.init(text: "**\(summary)**")))))
      try await peer.publish(
        .activity(.init(activity: .toolStarted(.init(callId: callID, name: "exec")))))
      try await peer.publish(
        .message(
          .init(
            message: .init(
              continuation: false, entryId: assistantID, finalChunk: true, role: .tool, text: "",
              tool: .init(callId: callID, name: "exec", status: .running)))))
      try await peer.publish(
        .message(
          .init(
            message: .init(
              continuation: false, entryId: resultID, finalChunk: true, role: .tool,
              text: "Output \(callID)",
              tool: .init(callId: callID, name: "exec", status: .finished)))))
    }
    try await peer.publish(
      .activity(.init(activity: .toolStarted(.init(callId: "c5", name: "exec")))))
    try await peer.publish(
      .message(
        .init(
          message: .init(
            continuation: false, entryId: "126", finalChunk: true, role: .tool, text: "",
            tool: .init(callId: "c5", name: "exec", status: .running)))))
    try await peer.publish(
      .message(
        .init(
          message: .init(
            continuation: false, entryId: "127", finalChunk: true,
            presentation: .command(.init(command: "printf anchored", durationMs: 8, exitCode: 0)),
            role: .tool, text: output.stdout,
            tool: .init(callId: "c5", name: "exec", status: .finished)))))
    try await peer.publish(.idle)

    let groupPredicate = NSPredicate(
      format: "identifier BEGINSWITH 'activity:' AND label CONTAINS '5 tool calls'")
    let group = app.buttons.matching(groupPredicate).firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(group.label.contains("4 summaries"), group.label)
    group.tap()

    let shellRow = feedButton("activity-item", row: "tool:c5", app: app)
    XCTAssertTrue(shellRow.waitForExistence(timeout: 3))
    shellRow.tap()
    XCTAssertTrue(app.staticTexts["Success"].waitForExistence(timeout: 5))
    let shellText = app.staticTexts[output.stdout]
    XCTAssertTrue(shellText.waitForExistence(timeout: 5))
    let transcript = app.scrollViews["transcript"]
    let topEdge = max(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY)
    let beforeY = shellText.frame.minY
    let beforeRelativeY = shellText.frame.minY - topEdge

    let boundedPage = NativeEventHistory(
      messages: [
        .init(
          continuation: false, entryId: "120", finalChunk: true, role: .thinking,
          text: "**Summary 3**"),
        .init(
          continuation: false, entryId: "121", finalChunk: true, role: .tool, text: "Output c3",
          tool: .init(callId: "c3", name: "exec", status: .finished)),
        .init(
          continuation: false, entryId: "124", finalChunk: true, role: .thinking,
          text: "**Summary 4**"),
        .init(
          continuation: false, entryId: "125", finalChunk: true, role: .tool, text: "Output c4",
          tool: .init(callId: "c4", name: "exec", status: .finished)),
        .init(
          continuation: false, entryId: "127", finalChunk: true,
          presentation: .command(.init(command: "printf anchored", durationMs: 8, exitCode: 0)),
          role: .tool, text: output.stdout,
          tool: .init(callId: "c5", name: "exec", status: .finished)),
      ], nextCursor: "119", pageComplete: true)
    await peer.updateHistory(initial: boundedPage, latest: boundedPage)
    await peer.holdObservations()
    await peer.dropObserver()

    try await eventually(description: "reconnecting banner appears") {
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'connecting'")).firstMatch
        .exists
    }
    XCTAssertTrue(group.label.contains("4 summaries"), "During Connecting: \(group.label)")
    let duringTopEdge = max(transcript.frame.minY, app.navigationBars.firstMatch.frame.maxY)
    let duringRelativeY = shellText.frame.minY - duringTopEdge
    XCTAssertLessThanOrEqual(
      abs(duringRelativeY - beforeRelativeY), 2.0,
      "beforeY=\(beforeY) topEdge=\(topEdge) duringY=\(shellText.frame.minY) duringTop=\(duringTopEdge)"
    )

    await peer.releaseObservations()
    try await eventually(description: "reconnection finishes and reconnecting banner clears") {
      let count = await peer.observationCount()
      let banner = app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS[c] 'connecting'")
      ).firstMatch
      return count >= 2 && !banner.exists
    }
    XCTAssertTrue(group.label.contains("5 tool calls"), group.label)
    XCTAssertTrue(group.label.contains("4 summaries"), group.label)
    XCTAssertLessThanOrEqual(abs(shellText.frame.minY - beforeY), 2.0)
  }

  func testExpandingLiveActivityGroupAtTailKeepsWorkingVisibleAboveComposer() async throws {
    let initial = (1...12).map { index in
      HistoryMessage(
        continuation: false, entryId: "msg-\(index)", finalChunk: true, role: .final,
        text: "Earlier response number \(index) fills the transcript above the active tail.")
    }
    let peer = InteractionPeer()
    let app = try await launchMessages(initial, peer: peer)
    try await eventually { await peer.observationCount() > 0 }

    try await peer.publish(
      .ready(.init(conversationId: "fixture-root", model: "fixture/model", working: true)))
    try await peer.publish(.activity(.init(activity: .thinking(.init(text: "**Live tail step**")))))
    try await peer.publish(
      .activity(.init(activity: .toolStarted(.init(callId: "live-1", name: "exec")))))
    try await peer.publish(
      .message(
        .init(
          message: .init(
            continuation: false, entryId: "200", finalChunk: true, role: .tool, text: "",
            tool: .init(callId: "live-1", name: "exec", status: .running)))))

    let working = app.staticTexts["Beep Boop is working"]
    XCTAssertTrue(working.waitForExistence(timeout: 5))
    let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'"))
      .firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 5))
    group.tap()

    try await peer.publish(
      .activity(.init(activity: .toolStarted(.init(callId: "live-2", name: "exec")))))
    try await peer.publish(
      .message(
        .init(
          message: .init(
            continuation: false, entryId: "201", finalChunk: true, role: .tool, text: "",
            tool: .init(callId: "live-2", name: "exec", status: .running)))))

    let composer = app.descendants(matching: .any).matching(identifier: "messageComposer")
      .firstMatch
    let expandedItem = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'activity-item:'")
    ).firstMatch
    XCTAssertTrue(expandedItem.waitForExistence(timeout: 5))
    try await eventually(description: "Working indicator remains visible above composer") {
      guard working.exists else { return false }
      return working.frame.maxY <= composer.frame.minY + 1
    }
    let latest = app.buttons["latest-messages"]
    XCTAssertFalse(latest.exists, "Expanding a live tail group should keep following the tail")
  }

  private func latestBarMessages() -> [HistoryMessage] {
    var messages: [HistoryMessage] = []
    for index in 0..<30 {
      messages.append(
        HistoryMessage(
          continuation: false, entryId: "bar-tool-\(index)", finalChunk: true,
          presentation: .command(.init(command: "echo \(index)", durationMs: 2, exitCode: 0)),
          role: .tool, text: "done \(index)",
          tool: .init(callId: "bar-call-\(index)", name: "exec", status: .finished)))
      messages.append(
        HistoryMessage(
          continuation: false, entryId: "bar-text-\(index)", finalChunk: true, role: .final,
          text: "Latest bar line \(index)."))
    }
    return messages
  }

  func testLatestBarTakesATapOverAHiddenRowAndADragFromItStillScrolls() async throws {
    let app = try await launchMessages(latestBarMessages())
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    let last = app.staticTexts["Latest bar line 29."]
    try await eventually(description: "live tail") { last.isHittable }
    drag(transcript, down: true)
    drag(transcript, down: true)
    let latest = app.buttons["latest-messages"]
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'"))
    let opened = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'activity-item:'"))
    func groupFrames() -> [CGRect] {
      groups.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
    }
    func onBar() -> XCUICoordinate {
      app.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(dx: transcript.frame.minX + 60, dy: latest.frame.midY))
    }
    let level = latest.frame.midY
    _ = try scroll(
      transcript,
      until: { groupFrames().min { abs($0.midY - level) < abs($1.midY - level) } },
      liesAcross: level)
    XCTAssertEqual(opened.count, 0)
    onBar().tap()
    XCTAssertFalse(
      opened.firstMatch.waitForExistence(timeout: 2),
      "A tap on the Latest bar opened the activity group that the bar hides")

    let shown = try XCTUnwrap(
      groupFrames().filter { $0.maxY < latest.frame.minY - 20 }.max { $0.minY < $1.minY })
    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: shown.midX, dy: shown.midY))
      .tap()
    try await eventually(description: "the group that shows above the Latest bar to open") {
      opened.count == 1
    }

    let lines = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Latest bar line '"))
    let middle = transcript.frame.midY
    let marker = app.staticTexts[
      try XCTUnwrap(
        lines.allElementsBoundByIndex.filter(\.isHittable)
          .min { abs($0.frame.midY - middle) < abs($1.frame.midY - middle) }
      ).label]
    let before = marker.frame.minY
    slowDrag(transcript, by: -150, from: onBar())
    XCTAssertLessThan(
      marker.frame.minY - before, -100, "A drag that starts on the Latest bar no longer scrolls")

    editor(app).tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    try await eventually(description: "the Latest bar above the keyboard") {
      latest.exists && latest.frame.maxY < keyboard.frame.minY
    }
    slowDrag(transcript, by: 320, from: onBar())
    XCTAssertTrue(
      keyboard.waitForNonExistence(timeout: 5),
      "A drag down that starts on the Latest bar no longer dismisses the keyboard")

    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    latest.tap()
    XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
    try await eventually(description: "the latest message after Latest") { last.isHittable }
  }

  func testLatestBarTakesTapsAtEveryHeightInLandscapeWithTheKeyboardUp() async throws {
    let app = try await launchMessages(latestBarMessages())
    defer { XCUIDevice.shared.orientation = .portrait }
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    let last = app.staticTexts["Latest bar line 29."]
    try await eventually(description: "live tail") { last.isHittable }
    drag(transcript, down: true)
    drag(transcript, down: true)
    let latest = app.buttons["latest-messages"]
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'"))
    let opened = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'activity-item:'"))
    XCUIDevice.shared.orientation = .landscapeLeft
    try await eventually(description: "the Latest bar in landscape") {
      app.frame.width > app.frame.height && latest.exists && groups.firstMatch.exists
    }
    let groupX = groups.firstMatch.frame.minX + 40
    let rowPitch = groups.element(boundBy: 1).frame.minY - groups.element(boundBy: 0).frame.minY
    editor(app).tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
    try await eventually(description: "the Latest bar above the keyboard") {
      latest.exists && latest.frame.maxY < keyboard.frame.minY
    }
    XCTAssertEqual(opened.count, 0)
    let tapSpan = latest.frame.height + 12
    for _ in 0...Int(rowPitch / tapSpan) {
      let top = max(latest.frame.minY - 6, app.navigationBars.firstMatch.frame.maxY + 1)
      for y in stride(from: top, to: latest.frame.maxY + 6, by: 6) {
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: groupX, dy: y)).tap()
        XCTAssertFalse(
          opened.firstMatch.waitForExistence(timeout: 1),
          "A tap \(y - latest.frame.minY) points under the top of the Latest button opened an "
            + "activity group that the bar hides")
      }
      slowDrag(
        transcript, by: -tapSpan,
        from: app.coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(dx: groupX, dy: latest.frame.midY)))
      XCTAssertTrue(keyboard.exists, "The keyboard left, so the bar no longer hides the rows")
    }

    latest.tap()
    XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
    // In landscape with the keyboard up, the title bar covers the last row at the tail.
    XCUIDevice.shared.orientation = .portrait
    try await eventually(description: "the latest message after Latest") {
      last.isHittable && !latest.exists
    }
  }

  func testLatestButtonDoesNotOverlapShellOutputOrDisclosureControls() async throws {
    struct Output: Encodable {
      let type = "process"
      let exitCode = 0
      enum CodingKeys: String, CodingKey {
        case type, stdout, stderr, truncated
        case exitCode = "exit_code"
      }
      let stdout = "Line one of shell output\nLine two of shell output"
      let stderr = ""
      let truncated = false
    }
    let output = Output()
    let details = ToolDetails.available(
      .init(
        callId: "shell-overlap",
        input: .text(.init(text: #"{"program":"printf","args":["test"]}"#, truncated: false)),
        name: "exec",
        output: .text(
          .init(
            text: String(decoding: try JSONEncoder().encode(output), as: UTF8.self),
            truncated: false)),
        status: .finished))
    var messages = (1...14).map { index in
      HistoryMessage(
        continuation: false, entryId: "lead-\(index)", finalChunk: true, role: .final,
        text: "Lead filler message \(index) that lets the shell card move down to the button.")
    }
    messages += [
      HistoryMessage(
        continuation: false, entryId: "e-shell", finalChunk: true,
        presentation: .command(.init(command: "printf test", durationMs: 5, exitCode: 0)),
        role: .tool, text: output.stdout,
        tool: .init(callId: "shell-overlap", name: "exec", status: .finished)),
      HistoryMessage(
        continuation: false, entryId: "e-between", finalChunk: true, role: .final,
        text: "Separator between shell card and collapsed disclosure group."),
      HistoryMessage(
        continuation: false, entryId: "e-collapsed", finalChunk: true,
        presentation: .command(.init(command: "echo collapsed", durationMs: 2, exitCode: 0)),
        role: .tool, text: "done",
        tool: .init(callId: "collapsed-call", name: "exec", status: .finished)),
    ]
    for index in 1...14 {
      messages.append(
        HistoryMessage(
          continuation: false, entryId: "tail-\(index)", finalChunk: true, role: .final,
          text: "Tail filler message \(index) that scrolls the shell card up off the bottom."))
    }
    let app = try await launchMessages(messages, toolDetails: ["shell-overlap": details])
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    try await eventually(description: "live tail") {
      app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Tail filler message 14 '"))
        .firstMatch.isHittable
    }
    let firstGroup = feedButton("activity", row: "tool:shell-overlap", app: app)
    for _ in 0..<10 where !firstGroup.exists { slowDrag(transcript, by: 200) }
    _ = try scroll(
      transcript, until: { firstGroup.exists ? firstGroup.frame : nil },
      liesAcross: transcript.frame.midY)
    firstGroup.tap()
    let shellItem = feedButton("activity-item", row: "tool:shell-overlap", app: app)
    XCTAssertTrue(shellItem.waitForExistence(timeout: 3))
    shellItem.tap()
    let shellText = app.staticTexts[output.stdout]
    XCTAssertTrue(shellText.waitForExistence(timeout: 5))
    let latest = app.buttons["latest-messages"]
    XCTAssertTrue(latest.waitForExistence(timeout: 5))
    func screenBesideLatest() -> CGRect {
      CGRect(
        x: transcript.frame.minX, y: latest.frame.minY,
        width: latest.frame.minX - 8 - transcript.frame.minX, height: latest.frame.height)
    }
    _ = try scroll(
      transcript, until: { shellText.exists ? shellText.frame : nil },
      liesAcross: latest.frame.midY)
    XCTAssertTrue(
      try screenIsBlank(in: screenBesideLatest(), of: app),
      "Shell output is drawn at the height of the Latest button, which covers its line ends")
    let collapsedGroup = feedButton("activity", row: "tool:collapsed-call", app: app)
    _ = try scroll(
      transcript, until: { collapsedGroup.exists ? collapsedGroup.frame : nil },
      liesAcross: latest.frame.midY)
    XCTAssertTrue(
      try screenIsBlank(in: screenBesideLatest(), of: app),
      "A collapsed activity row is drawn at the height of the Latest button, which covers its "
        + "disclosure control")
  }

  func testConnectionBannersStayClearOfScrolledTranscriptTopLine() async throws {
    let messages = (1...24).map { index in
      HistoryMessage(
        continuation: false, entryId: "banner-\(index)", finalChunk: true, role: .final,
        text: "Scrolled transcript entry \(index) used to verify banner separation cleanly.")
    }
    let peer = InteractionPeer()
    let app = try await launchMessages(messages, peer: peer)
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 5))
    transcript.swipeDown()
    await peer.holdObservations()
    await peer.dropObserver()
    let banner = app.otherElements["connectionStatusBanner"]
    let bannerText = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS[c] 'connecting' OR label CONTAINS[c] 'disconnected'")
    ).firstMatch
    XCTAssertTrue(bannerText.waitForExistence(timeout: 5))
    let bannerFrame = banner.exists ? banner.frame : bannerText.frame
    let transcriptFrame = transcript.frame
    XCTAssertGreaterThanOrEqual(transcriptFrame.minY, bannerFrame.maxY - 1)
    let completelyVisibleTop = app.staticTexts.matching(
      NSPredicate(format: "label BEGINSWITH 'Scrolled transcript entry '")
    ).allElementsBoundByIndex.filter { $0.isHittable }.map(\.frame).filter {
      !$0.isEmpty && $0.minY >= transcriptFrame.minY - 1
    }.min { $0.minY < $1.minY }
    let topRow = try XCTUnwrap(
      completelyVisibleTop,
      "Expected at least one completely visible transcript row below banner")
    XCTAssertGreaterThanOrEqual(
      topRow.minY, bannerFrame.maxY - 1,
      "Top visible transcript row \(topRow) collided with banner \(bannerFrame)")
    await peer.releaseObservations()
  }

  func testActiveWorkStripAndReadOnlySheetNavigateToInspection() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    await peer.serveActiveWork(
      TaskGraphSnapshot(conversations: [], nodes: [], omitted: 0, work: []))
    await peer.serveInspection(
      "10",
      messages: [
        .init(
          continuation: false, entryId: "inspected-1", finalChunk: true, role: .assistant,
          text: "Retained worker inspection message.")
      ])
    addTeardownBlock { await peer.stop() }
    let app = try await launchMessages(
      [
        .init(
          continuation: false, entryId: "main-1", finalChunk: true, role: .assistant, text: "Ready."
        )
      ],
      peer: peer)
    XCTAssertTrue(app.staticTexts["Ready."].waitForExistence(timeout: 10))
    let strip = app.buttons["activeWorkStrip"]
    XCTAssertFalse(strip.exists, "Strip stays hidden when active work counts are zero")

    let graph = TaskGraphSnapshot(
      conversations: [],
      nodes: [],
      omitted: 2,
      work: [
        ActiveWorkItem(
          children: [
            ActiveWorkChild(
              agentId: "review", conversationId: "12", detail: "read: src/protocol.rs",
              host: "laptop", status: .running, title: "Reviewer", tools: ["read: src/protocol.rs"])
          ],
          conversationId: "10", detail: "exec: cargo test", host: "workstation", id: "task:1",
          isJob: false, startedAt: 1_798_797_600_000, status: .running, title: "Build fix",
          tools: ["exec: cargo test"]),
        ActiveWorkItem(
          conversationId: "11", detail: "Confirm rollout", id: "task:2", isJob: false,
          startedAt: 1_798_797_601_000, status: .waitingOwner, title: "Deploy sign-off"),
        ActiveWorkItem(
          conversationId: "14", detail: nil, id: "task:2b", isJob: false,
          startedAt: 1_798_797_601_500, status: .waitingOwner, title: "Approve budget"),
        ActiveWorkItem(
          conversationId: "13", detail: "Waiting on CI", id: "task:3", isJob: true,
          startedAt: 1_798_797_602_000, status: .waitingExternal, title: "Nightly check"),
      ])
    try await peer.publish(.taskGraph(.init(graph: graph)))
    XCTAssertTrue(strip.waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.staticTexts["1 running · 2 needs you · 1 waiting · +2 more"].waitForExistence(timeout: 5))

    strip.tap()
    XCTAssertTrue(app.navigationBars["Active work"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Running"].exists)
    XCTAssertTrue(app.staticTexts["Waiting"].exists)
    XCTAssertTrue(app.staticTexts["Build fix"].exists)
    XCTAssertTrue(app.staticTexts["Reviewer"].exists)
    XCTAssertTrue(app.staticTexts["Deploy sign-off"].exists)
    XCTAssertTrue(app.staticTexts["Confirm rollout"].exists)
    XCTAssertFalse(app.staticTexts["Needs your reply · Confirm rollout"].exists)
    XCTAssertTrue(app.staticTexts["Approve budget"].exists)
    XCTAssertTrue(app.staticTexts["Needs your reply"].exists)
    XCTAssertTrue(app.staticTexts["Nightly check"].exists)
    XCTAssertFalse(app.buttons["Send message"].isHittable)
    XCTAssertFalse(app.buttons["Cancel"].isHittable)

    let buildRow = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH '-task:1'"))
      .firstMatch
    XCTAssertTrue(buildRow.waitForExistence(timeout: 5))
    buildRow.tap()
    XCTAssertTrue(
      app.staticTexts["Retained worker inspection message."].waitForExistence(timeout: 10))
  }

  func testDreamsBrowserDetailAndConfirmedApplyCommitFlow() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let summary = DreamsRunSummary(
      coverageComplete: false,
      outcomeLabel: "Proposed",
      proposalStatus: .pending,
      run: "2026-11-22T02-00-00Z",
      windowEndMs: 1_798_797_600_000,
      windowStartMs: 1_798_711_200_000)
    let detail = DreamsRunDetail(
      attemptsUsed: 1,
      baseRevision: "0123456789abcdef0123456789abcdef01234567",
      canApply: true,
      checks: [
        DreamsCheckItem(
          durationMs: 18,
          name: "format",
          output: "",
          passed: true,
          phase: "before",
          verdict: "ok"),
        DreamsCheckItem(
          durationMs: 42,
          name: "unit",
          output: "72 passed",
          passed: true,
          phase: "after",
          verdict: "ok"),
      ],
      citedEvidence: [
        DreamsEvidenceCite(
          body: "Receipt from nightly task check",
          id: "rec-1",
          kind: "receipt",
          title: "Check receipt")
      ],
      coverageComplete: false,
      files: ["docs/notes.md"],
      gaps: ["slack/workspace-example: token expired"],
      outcomeLabel: "Proposed",
      outcomeSha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      patch: "@@ -1 +1 @@\n-old\n+new\n",
      patchSha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      proposalStatus: .pending,
      rationaleOrNote: "Refresh stale nightly reminder note\\x1b[31m.",
      receiptsCount: 1,
      run: "2026-11-22T02-00-00Z",
      statusDetail: "ready for operator review",
      summariesCapturedAtMs: 1_798_797_605_000,
      summariesCount: 2,
      windowEndMs: 1_798_797_600_000,
      windowStartMs: 1_798_711_200_000)
    await peer.serveDreams(summaries: [summary], details: [detail])

    let app = try await launchMessages(
      [
        .init(
          continuation: false, entryId: "main-1", finalChunk: true, role: .assistant, text: "Ready."
        )
      ],
      peer: peer)
    XCTAssertTrue(app.staticTexts["Ready."].waitForExistence(timeout: 10))
    app.buttons["Connection"].tap()
    let dreamsLink = app.buttons["dreamsControlsLink"]
    XCTAssertTrue(dreamsLink.waitForExistence(timeout: 10), app.debugDescription)
    dreamsLink.tap()

    let row = app.buttons["dreamsRunRow:2026-11-22T02-00-00Z"]
    XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Coverage incomplete"].exists)
    row.tap()

    XCTAssertTrue(
      app.staticTexts["ready for operator review"].waitForExistence(timeout: 10),
      app.debugDescription)

    func scrollUpTo(_ element: XCUIElement) {
      var remaining = 8
      while !element.isHittable && remaining > 0 {
        app.swipeUp()
        remaining -= 1
      }
      XCTAssertTrue(element.waitForExistence(timeout: 3), app.debugDescription)
    }

    scrollUpTo(app.staticTexts["slack/workspace-example: token expired"])
    scrollUpTo(app.staticTexts["Refresh stale nightly reminder note\\x1b[31m."])
    scrollUpTo(app.staticTexts["After: unit"])
    scrollUpTo(app.staticTexts["rec-1"])

    let applyButton = app.buttons["dreamsApplyButton"]
    scrollUpTo(applyButton)
    applyButton.tap()

    let confirm = app.buttons["Apply changes"]
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
    confirm.tap()

    try await eventually {
      await peer.dreamsApplies()
        == [
          .init(
            approve: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            run: "2026-11-22T02-00-00Z")
        ]
    }
    var downs = 0
    let appliedBanner = app.staticTexts["Applied as commit 111122223333."]
    while !appliedBanner.exists && downs < 8 {
      app.swipeDown()
      downs += 1
    }
    XCTAssertTrue(appliedBanner.waitForExistence(timeout: 10), app.debugDescription)
  }

  func testReplyBannerIsAsTallAsItsTextAndLeavesTheTranscriptInReach() async throws {
    executionTimeAllowance = 120
    var messages: [HistoryMessage] = []
    for index in 0..<30 {
      messages.append(
        HistoryMessage(
          continuation: false, entryId: "reply-tool-\(index)", finalChunk: true,
          presentation: .command(.init(command: "echo \(index)", durationMs: 2, exitCode: 0)),
          role: .tool, text: "done \(index)",
          tool: .init(callId: "reply-call-\(index)", name: "exec", status: .finished)))
      messages.append(
        HistoryMessage(
          continuation: false, entryId: "reply-text-\(index)", finalChunk: true, role: .final,
          text: "Reply banner line \(index)."))
    }
    let app = try await launchMessages(messages)
    let transcript = app.scrollViews["transcript"]
    XCTAssertTrue(transcript.waitForExistence(timeout: 10))
    let last = transcript.staticTexts["Reply banner line 29."]
    try await eventually(description: "live tail") { last.isHittable }
    last.press(forDuration: 1.0)
    let replyAction = action("Reply", app: app)
    XCTAssertTrue(replyAction.waitForExistence(timeout: 5))
    replyAction.tap()

    let banner = app.otherElements["replyTargetBanner"]
    XCTAssertTrue(banner.waitForExistence(timeout: 5))
    let heading = banner.staticTexts["Replying to Beep Boop"]
    let excerpt = banner.staticTexts["Reply banner line 29."]
    XCTAssertTrue(heading.exists)
    XCTAssertTrue(excerpt.exists)
    try await eventually(description: "the last row in reach above the reply banner") {
      last.isHittable && last.frame.maxY <= banner.frame.minY
    }
    let textHeight = heading.frame.height + excerpt.frame.height
    XCTAssertLessThanOrEqual(
      banner.frame.height, 2 * textHeight,
      "The reply banner is \(banner.frame.height) points tall for \(textHeight) points of text")

    drag(transcript, down: true)
    drag(transcript, down: true)
    let latest = app.buttons["latest-messages"]
    XCTAssertTrue(
      latest.waitForExistence(timeout: 5),
      "The reader could not leave the tail with a reply pinned")
    XCTAssertLessThanOrEqual(latest.frame.maxY, banner.frame.minY)
    let groups = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'activity:'"))
    let opened = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'activity-item:'"))
    let level = latest.frame.midY
    _ = try scroll(
      transcript,
      until: {
        groups.allElementsBoundByIndex.map(\.frame).filter { !$0.isEmpty }
          .min { abs($0.midY - level) < abs($1.midY - level) }
      },
      liesAcross: level)
    XCTAssertEqual(opened.count, 0)
    app.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: transcript.frame.minX + 60, dy: latest.frame.midY)
    ).tap()
    XCTAssertFalse(
      opened.firstMatch.waitForExistence(timeout: 2),
      "A tap on the Latest bar opened the activity group that the bar hides")

    latest.tap()
    XCTAssertTrue(latest.waitForNonExistence(timeout: 5))
    try await eventually(description: "the latest message after Latest") {
      last.isHittable && last.frame.maxY <= banner.frame.minY
    }
  }

  func testReplyContextMenuPinsTargetAndSendsReplyReference() async throws {
    executionTimeAllowance = 120
    let peer = InteractionPeer()
    addTeardownBlock { await peer.stop() }
    let app = try await launchMessages(
      [
        .init(
          continuation: false,
          entryId: "main-2",
          finalChunk: true,
          role: .final,
          text: "Option A is default; Option B isolates state cleanly.")
      ],
      peer: peer)

    let answerText = app.staticTexts["Option A is default; Option B isolates state cleanly."]
    XCTAssertTrue(answerText.waitForExistence(timeout: 10), app.debugDescription)

    answerText.press(forDuration: 1.0)
    let replyAction = action("Reply", app: app)
    XCTAssertTrue(replyAction.waitForExistence(timeout: 5), app.debugDescription)
    replyAction.tap()

    let replyBanner = app.otherElements["replyTargetBanner"]
    XCTAssertTrue(replyBanner.waitForExistence(timeout: 5), app.debugDescription)
    XCTAssertTrue(app.staticTexts["Replying to Beep Boop"].exists)

    let composer = editor(app)
    composer.tap()
    composer.typeText("Compare Option B details")
    let send = app.buttons["Send message"]
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 5))
    send.tap()

    try await eventually {
      await peer.submitRequests().contains {
        $0.text == "Compare Option B details" && $0.replyTo?.entryId == "main-2"
      }
    }
    XCTAssertFalse(replyBanner.exists)
    XCTAssertTrue(app.buttons["replyQuoteCard:main-2"].waitForExistence(timeout: 5))
  }
}

@MainActor
final class RestoreInteractionTests: XCTestCase {
  // One saved coordinator refuses a message, and the user restores it, which binds it to that
  // coordinator with no chip. The user deletes it key by key, which ends the restored draft, and
  // presses Command-Z. Undo never reaches back past that, so no text comes back bound to no
  // coordinator, to go to every coordinator once another is added. The original still needs
  // attention, and Restore brings it back.
  func testUndoAfterDeletingARestoredDraftWithOneCoordinatorBringsNothingBack() async throws {
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
    let composer = app.textViews["Message the coordinator"]
    let send = app.buttons["Send message"]
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.tap()
    let text = "Invented: Work's merger memo for the board"
    composer.typeText(text)
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    send.tap()
    let restore = app.buttons["Restore to composer"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10), "The refused message offers Restore")
    await work.rejectSubmits(false)
    restore.tap()
    try await eventually { composer.value as? String == text }
    composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: text.count))
    try await Task.sleep(for: .milliseconds(500))
    let cleared = composer.showsNoText
    composer.typeKey("z", modifierFlags: .command)
    try await Task.sleep(for: .seconds(1))
    let undone = composer.value as? String
    print(
      "IF10-2[ui, one coordinator] cleared=\(cleared) after Command-Z: value=\(undone ?? "nil") sendEnabled=\(send.isEnabled) restoreOffered=\(restore.exists)"
    )
    XCTAssertTrue(cleared, "The keys did not empty the field")
    XCTAssertTrue(composer.showsNoText, "Undo brought back the cleared restored text")
    XCTAssertFalse(send.isEnabled, "Send is on with nothing to send")
    XCTAssertTrue(restore.exists, "The original no longer offers Restore")
    restore.tap()
    try await eventually { composer.value as? String == text }
    send.tap()
    try await eventually { await work.submits() == [text] }
  }

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

  // One saved coordinator refuses a message, and the user restores it. /status from the Commands
  // menu replaces the draft, and Send delivers /status. The restored message never went, so the
  // original still needs attention and offers Restore. Discard then removes it: "Not sent".
  func testACommandPickedOverARestoredDraftKeepsTheOriginalUntilDiscarded() async throws {
    continueAfterFailure = true
    executionTimeAllowance = 120
    let work = InteractionPeer()
    addTeardownBlock { await work.stop() }
    let empty = NativeEventHistory(messages: [], nextCursor: nil, pageComplete: true)
    await work.history(initial: empty, pages: [:], latest: empty)
    await work.announce([SlashCommand(description: "Show coordinator status", usage: "/status")])
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
    let text = "Invented: renew the greenhouse lease before Friday"
    composer.typeText(text)
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    send.tap()
    let restore = app.buttons["Restore to composer"]
    XCTAssertTrue(restore.waitForExistence(timeout: 10), "The refused message offers Restore")
    restore.tap()
    try await eventually { composer.value as? String == text }
    await work.rejectSubmits(false)
    app.buttons["composerMenu"].tap()
    let commands = app.buttons["Commands"]
    XCTAssertTrue(commands.waitForExistence(timeout: 5))
    commands.tap()
    let status = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '/status'")).firstMatch
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    status.tap()
    // Picking a command keeps the draft as the command's note.
    let command = "/status \(text)"
    try await eventually { composer.value as? String == command }
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    send.tap()
    try await eventually { await work.submits().contains(command) }
    try await Task.sleep(for: .seconds(1))
    let needsAttention = app.staticTexts["Needs attention"].exists
    print(
      "IF8-W1[ui] after Send: submits=\(await work.submits()) notSent=\(app.staticTexts["Not sent"].exists) needsAttention=\(needsAttention) restoreOffered=\(restore.exists)"
    )
    let sent = XCTAttachment(screenshot: app.screenshot())
    sent.name = "command-sent-over-a-restored-draft"
    sent.lifetime = .keepAlways
    add(sent)
    XCTAssertTrue(needsAttention && restore.exists, "The original message is gone unsent")
    let discard = app.buttons["Discard"]
    XCTAssertTrue(discard.exists, "The refused original offers Discard")
    discard.tap()
    XCTAssertTrue(
      app.staticTexts["Not sent"].waitForExistence(timeout: 5), "The discarded original")
    XCTAssertFalse(app.staticTexts["Needs attention"].exists)
    XCTAssertFalse(restore.exists, "Restore is offered for a discarded message")
    let submitted = await work.submits()
    XCTAssertEqual(submitted, [command], "Only /status reached Work")
    let discarded = XCTAttachment(screenshot: app.screenshot())
    discarded.name = "refused-original-discarded"
    discarded.lifetime = .keepAlways
    add(discarded)
  }

  // One saved coordinator refuses a message, so it needs attention, with Restore and Discard. The
  // connection drops and comes back. The coordinator still holds no copy, so its refusal is its
  // latest word, and the message still needs attention, with no Check / retry. Discard removes it.
  func testARefusedMessageStillNeedsAttentionAfterAReconnect() async throws {
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
    composer.typeText("Invented: water the plants on Friday")
    XCTAssertTrue(send.wait(for: \.isEnabled, toEqual: true, timeout: 10))
    send.tap()
    XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 10))
    await work.dropObserver()
    try await eventually { await work.observationCount() >= 2 }
    try await Task.sleep(for: .seconds(1))
    let needsAttention = app.staticTexts["Needs attention"].exists
    let checkRetry = app.buttons["Check / retry"].exists
    print(
      "IF8-W1b[ui] after the reconnect: observations=\(await work.observationCount()) needsAttention=\(needsAttention) unconfirmed=\(app.staticTexts["Delivery unconfirmed"].exists) restore=\(app.buttons["Restore to composer"].exists) discard=\(app.buttons["Discard"].exists) checkRetry=\(checkRetry)"
    )
    let reconnected = XCTAttachment(screenshot: app.screenshot())
    reconnected.name = "refused-original-after-a-reconnect"
    reconnected.lifetime = .keepAlways
    add(reconnected)
    XCTAssertTrue(needsAttention, "The refused message reads as unconfirmed after a reconnect")
    XCTAssertTrue(app.buttons["Restore to composer"].exists)
    XCTAssertFalse(checkRetry, "Check / retry would send a message its coordinator refused")
    let discard = app.buttons["Discard"]
    XCTAssertTrue(discard.exists)
    discard.tap()
    XCTAssertTrue(app.staticTexts["Not sent"].waitForExistence(timeout: 5))
  }
}
