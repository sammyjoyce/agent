import AgentCore
import Network
import UIKit
import XCTest

@MainActor private func eventually(
  file: StaticString = #filePath, line: UInt = #line,
  _ predicate: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(5)
  while try await !predicate() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Expected interaction state did not arrive", file: file, line: line)
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
    return value == nil || value == "" || value == "Message Agent"
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
  private var requests: [String] = []
  private var submitted: [String] = []
  private var held: Set<String> = []
  private var releases: [String: CheckedContinuation<Void, Never>] = [:]

  func history(
    initial: NativeEventHistory, pages: [String: NativeEventHistory], latest: NativeEventHistory
  ) {
    self.initial = initial
    self.pages = pages
    self.latest = latest
  }
  func cursors() -> [String] { requests }
  func submits() -> [String] { submitted }
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
      case .observe:
        observer = socket
        try await emit(
          .ready(.init(conversationId: "fixture-root", model: "fixture/model")), to: socket)
        try await emit(.history(try XCTUnwrap(initial)), to: socket)
        try await emit(.idle, to: socket)
      case .history(let request):
        let cursor = request.cursor ?? "<latest>"
        requests.append(cursor)
        if held.contains(cursor) { await withCheckedContinuation { releases[cursor] = $0 } }
        try await emit(
          .history(try XCTUnwrap(request.cursor == nil ? latest : pages[cursor])), to: socket)
        try await emit(.done, to: socket)
      case .submit(let request):
        submitted.append(request.text)
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
