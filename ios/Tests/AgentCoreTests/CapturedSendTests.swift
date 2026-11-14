import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

/// Work's and Personal's scripted coordinators, and the folder and defaults a launch reads. Work
/// answers at ports 4001 and 4003 of an invented address, and Personal at 4002 and 4004.
private struct Lab {
  let workFixture: FixtureCoordinator
  let personalFixture: FixtureCoordinator
  let root: URL
  let defaults: UserDefaults
  let inbox: SharedDraftInbox
  let transport: CoordinatorTransport

  /// `Coordinators` as a launch builds it, with a draft store and a share inbox, after restoring
  /// the saved draft.
  @MainActor func launch() async -> Coordinators {
    let coordinators = Coordinators(
      registration: nil, defaults: defaults, applicationSupport: root, caches: root,
      transport: transport,
      persistence: ComposerDraftStore(url: root.appending(path: "draft.json")),
      sharedInbox: inbox)
    await coordinators.chat.restoreDraft()
    return coordinators
  }

  /// The text of each message queued in the profile's outbox.
  func outbox(_ id: ProfileID) -> [String] {
    let directory = ProfileDirectory(id, applicationSupport: root, caches: root)
    return ((try? queuedRequests(directory.outbox)) ?? []).map(\.text)
  }
}

@MainActor private func withLab(
  _ body: @MainActor (Lab, Coordinators) async throws -> Void
) async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  defer { workListener.cancel() }
  let (personalListener, personalPort) = try await listen(personalFixture)
  defer { personalListener.cancel() }
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let suite = "captured-send-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let lab = Lab(
    workFixture: workFixture, personalFixture: personalFixture, root: root, defaults: defaults,
    inbox: SharedDraftInbox(containerURL: root),
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(
          to: [4002, 4004].contains(address.port) ? personalPort : workPort, using: .tcp))
    })
  let coordinators = await lab.launch()
  await coordinators.setActive(true)
  do {
    try await body(lab, coordinators)
  } catch {
    await coordinators.setActive(false)
    await workFixture.stop()
    await personalFixture.stop()
    throw error
  }
  await coordinators.setActive(false)
  await workFixture.stop()
  await personalFixture.stop()
}

@MainActor private func eventually(
  _ description: String, within limit: Duration = .seconds(15), _ predicate: () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + limit
  while !(await predicate()) {
    try #require(ContinuousClock.now < deadline, "Timed out waiting for \(description)")
    try await Task.sleep(for: .milliseconds(5))
  }
}

private func interrupts(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .interrupt = $0 { true } else { false } }.count
}

private func observes(_ fixture: FixtureCoordinator) async -> Int {
  await fixture.received().filter { if case .observe = $0 { true } else { false } }.count
}

private func reply(_ entry: String) -> HistoryMessage {
  HistoryMessage(
    continuation: false, entryId: entry, finalChunk: true, role: .final,
    text: "Invented reply \(entry)")
}

private func tool(_ entry: String) -> HistoryMessage {
  HistoryMessage(
    continuation: false, entryId: entry, finalChunk: true, role: .tool, text: "",
    tool: .init(callId: entry, name: "exec", status: .finished))
}

/// A history page of `count` replies, `prefix-0` oldest.
private func replies(_ prefix: String, _ count: Int, next: String? = nil) -> NativeEventHistory {
  NativeEventHistory(
    messages: (0..<count).map { reply("\(prefix)-\($0)") }, nextCursor: next, pageComplete: true)
}

@Suite struct CapturedSendTests {
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aSendInWorksScopeReachesOnlyWork() async throws {
    try await withLab { lab, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.show(.one(work))
      let text = "Invented: the Work standup moves to 10"
      chat.draft = text
      await chat.send()
      #expect(lab.outbox(work) == [text] && lab.outbox(personal).isEmpty)
      try await eventually("Work got it") { await submitted(lab.workFixture) == [text] }
      #expect(await submitted(lab.personalFixture).isEmpty, "Personal got nothing")
      #expect(chat.draft.isEmpty && chat.destination == .open)
    }
  }

  /// Send takes the draft, its recipients and their sessions in the tap's turn. A switch to
  /// Personal's feed and typing that tags Personal while Work's copy is still being saved change
  /// nothing about that Send. The chip the tag became and the text stay in the composer as a newer
  /// draft.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aSwitchAfterTheTapChangesNothing() async throws {
    try await withLab { lab, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.show(.one(work))
      let text = "Invented: the offsite agenda"
      chat.draft = text
      await chat.attach(
        data: Data("invented agenda".utf8), name: "Agenda.txt", mediaType: "text/plain")
      let held = try PipedCopy(replacing: #require(chat.attachments.first).url)
      defer { held.release() }
      let sending = try #require(chat.startSend(), "Work's feed sends a draft begun there")
      try await held.opened()
      chat.show(.one(personal))
      try #require(chat.draft.isEmpty, "Send takes the text at its tap")
      chat.draft = "@Personal " + text + " and the venue"
      chat.promoteTypedTag()
      held.finish()
      await sending.value
      #expect(lab.outbox(work) == [text], "Work's outbox holds the text sent at the tap")
      #expect(lab.outbox(personal).isEmpty, "Personal's outbox holds nothing")
      try await eventually("Work got it") { await submitted(lab.workFixture) == [text] }
      #expect(await submitted(lab.personalFixture).isEmpty)
      #expect(
        chat.draft == text + " and the venue" && chat.destination == .chip(personal),
        "The newer draft stays")
    }
  }

  /// Each draft is built as the user builds it, walked through All, Work's feed, Personal's feed
  /// and All again, and sent at one step of the walk. No switch changes where it goes. A Send
  /// either reaches exactly the coordinators the draft is addressed to, or is refused in the tap's
  /// turn with the draft kept.
  @MainActor
  @Test(
    .timeLimit(.minutes(1)),
    arguments: [
      "begun in All", "begun in Work", "Personal's chip", "an @Personal tag",
      "restored from Personal", "held for Personal", "a share import", "/feedback",
    ])
  func aScopeSwitchNeverChangesWhereADraftGoes(_ kind: String) async throws {
    try await withLab { lab, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      // Both are busy with a turn, so each Send is taken and waits on its socket to be placed, and
      // no lane reconnects between steps.
      for fixture in [lab.workFixture, lab.personalFixture] { await fixture.holdPlacements() }
      var addressed: [ProfileID: [String]] = [work: [], personal: []]
      /// Builds the draft, and returns the text it sends and whom it is addressed to.
      @MainActor func build(_ text: String) async throws -> (body: String, recipients: [ProfileID])
      {
        chat.show(kind == "begun in Work" ? .one(work) : .all)
        switch kind {
        case "begun in All", "begun in Work":
          chat.draft = text
          return (text, kind == "begun in Work" ? [work] : [work, personal])
        case "Personal's chip":
          chat.setChip(personal)
          chat.draft = text
          return (text, [personal])
        case "an @Personal tag":
          chat.draft = "@Personal " + text
          return (text, [personal])
        case "restored from Personal":
          // Personal refuses the original, which then waits in Personal's outbox for Restore.
          await lab.personalFixture.rejectSubmits()
          chat.setChip(personal)
          chat.draft = text
          await chat.send()
          addressed[personal]?.append(text)
          try await eventually("Personal refused the original") {
            chat.snapshots[personal]?.rows.contains { $0.text == text && $0.delivery == .rejected }
              == true
          }
          await lab.personalFixture.rejectSubmits(false)
          let original = try #require(
            chat.snapshots[personal]?.rows.first { $0.text == text }?.inputID)
          await chat.restore(original)
          return (text, [personal])
        case "held for Personal":
          let queued = NativeRequestSubmit(inputId: UUID().uuidString, mode: .steer, text: text)
          chat.holds.append(
            try heldQueue([queued], in: lab.root, coordinator: lab.personalFixture.id))
          try await eventually("the held message was read") {
            chat.held.contains { $0.id == queued.inputId }
          }
          let message = try #require(chat.held.first { $0.id == queued.inputId })
          await chat.restoreHeld(message)
          return (text, [personal])
        case "a share import":
          try await lab.inbox.enqueue(images: [], note: text)
          await chat.receiveSharedDrafts()
          return (text, [work, personal])
        default:
          chat.draft = "/feedback " + text
          return ("/feedback " + text, [work, personal])
        }
      }
      let walk: [FeedScope] = [.all, .one(work), .one(personal), .all]
      for step in walk.indices {
        let (body, recipients) = try await build("Invented: \(kind) sent at step \(step)")
        await chat.attach(
          data: Data("invented notes \(step)".utf8), name: "Notes.txt", mediaType: "text/plain")
        try #require(chat.failure == nil && chat.draftError == nil, "\(kind) was built")
        let draft = (text: chat.draft, addressing: chat.draftAddressing, files: chat.attachments)
        @MainActor func kept() -> Bool {
          chat.draft == draft.text && chat.draftAddressing == draft.addressing
            && chat.attachments == draft.files
        }
        for scope in walk[...step] {
          chat.show(scope)
          #expect(kept(), "\(kind) is unchanged in \(scope)")
        }
        let admission = chat.startSend()
        if walk[step].coordinator.map({ recipients == [$0] }) ?? true {
          try #require(admission != nil, "\(kind) goes from \(walk[step])")
          await admission?.value
          for id in recipients { addressed[id]?.append(body) }
          #expect(chat.draft.isEmpty && chat.attachments.isEmpty, "\(kind) went")
        } else {
          #expect(admission == nil, "\(kind) is refused in \(walk[step])")
          #expect(kept(), "A refused \(kind) stays")
          chat.draft = ""
          for file in chat.attachments { await chat.removeAttachment(file) }
          chat.removeChip()
        }
        try await eventually("each coordinator got what was addressed to it") {
          let (atWork, atPersonal) = (
            await submitted(lab.workFixture), await submitted(lab.personalFixture)
          )
          return atWork == addressed[work] && atPersonal == addressed[personal]
        }
      }
      try await Task.sleep(for: .milliseconds(200))
      #expect(await submitted(lab.workFixture) == addressed[work])
      #expect(await submitted(lab.personalFixture) == addressed[personal])
    }
  }

  /// Send keeps the session it took at the tap. An address edit retires that session while Work's
  /// copy is being saved, so the stage refuses, nothing starts, the draft stays, and Work's next
  /// session holds nothing from that tap.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aCapturedSessionThatRetiresIsNeverReplaced() async throws {
    try await withLab { lab, coordinators in
      let (work, _) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.setChip(work)
      let text = "Invented: the signed lease"
      chat.draft = text
      await chat.attach(
        data: Data("invented lease".utf8), name: "Lease.txt", mediaType: "text/plain")
      let files = chat.attachments
      let held = try PipedCopy(replacing: #require(chat.attachments.first).url)
      defer { held.release() }
      let sending = try #require(chat.startSend())
      try await held.opened()
      try await coordinators.update(
        work, name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
      try await eventually("Work's next session connected") {
        chat.snapshots[work]?.connection == .connected
      }
      held.finish()
      await sending.value
      #expect(chat.error == "Nothing was sent. Work did not take the message.")
      #expect(chat.draft == text && chat.attachments == files && chat.destination == .chip(work))
      #expect(lab.outbox(work).isEmpty, "Work's next session holds nothing from that tap")
      try await Task.sleep(for: .milliseconds(200))
      #expect(await submitted(lab.workFixture).isEmpty, "Nothing started")
    }
  }

  /// A file dropped while the Send is admitting makes a newer draft, so the completion keeps the
  /// chip and removes only the file it sent. The text went at the tap. With no edit it clears the
  /// composer.
  @MainActor @Test(.timeLimit(.minutes(1)), arguments: [false, true])
  func aCompletionClearsOnlyTheDraftItAdmitted(dropped: Bool) async throws {
    try await withLab { lab, coordinators in
      let (work, _) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.setChip(work)
      let text = "Invented: the venue contract"
      chat.draft = text
      await chat.attach(
        data: Data("invented contract".utf8), name: "Contract.txt", mediaType: "text/plain")
      let held = try PipedCopy(replacing: #require(chat.attachments.first).url)
      defer { held.release() }
      let sending = try #require(chat.startSend())
      try await held.opened()
      if dropped {
        let plan = lab.root.appending(path: "Floor plan.txt")
        try Data("invented floor plan".utf8).write(to: plan)
        await chat.attach(urls: [plan])?.value
      }
      held.finish()
      await sending.value
      try await eventually("Work got it") { await submitted(lab.workFixture) == [text] }
      if dropped {
        #expect(chat.draft.isEmpty && chat.destination == .chip(work))
        #expect(chat.attachments.map(\.reference.name) == ["Floor plan.txt"])
      } else {
        #expect(chat.draft.isEmpty && chat.attachments.isEmpty && chat.destination == .open)
      }
    }
  }

  /// Removing the coordinator whose feed is shown shows All, keeps the preference for the next
  /// launch to resolve, and leaves the draft as it was.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func removingTheShownCoordinatorFallsBackToAllAndTouchesNoDraft() async throws {
    try await withLab { lab, coordinators in
      let (work, _) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.show(.one(work))
      let preference = lab.defaults.string(forKey: ScopePreference.key)
      #expect(preference == work.description)
      let addressing = chat.draftAddressing
      try await coordinators.remove(coordinators.removal(work))
      #expect(chat.scope == .all)
      #expect(lab.defaults.string(forKey: ScopePreference.key) == preference)
      #expect(chat.draft.isEmpty && chat.attachments.isEmpty && chat.draftAddressing == addressing)
    }
  }

  /// Personal's feed needs another coordinator saved. With one left the feed shows All, and a
  /// second one brings Personal's feed back.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func oneCoordinatorLeftResolvesToAll() async throws {
    try await withLab { _, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      chat.show(.one(personal))
      try await coordinators.remove(coordinators.removal(work))
      #expect(chat.scope == .all)
      try await coordinators.add(
        name: TagName("Home"), address: CoordinatorAddress(host: "100.64.1.2", port: 4003))
      #expect(chat.scope == .one(personal))
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func coldLaunchRestoresTheLastScope() async throws {
    try await withLab { lab, coordinators in
      let (_, personal) = try await addWorkAndPersonal(coordinators)
      coordinators.chat.show(.one(personal))
      await coordinators.setActive(false)
      let relaunched = await lab.launch()
      #expect(relaunched.profiles.map(\.name.description) == ["Work", "Personal"])
      #expect(relaunched.chat.scope == .one(personal))
    }
  }

  /// Stop in Work's feed stops Work, and Personal keeps working. Stop in All stops both.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func stopInWorksScopeLeavesPersonalWorking() async throws {
    try await withLab { lab, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      for fixture in [lab.workFixture, lab.personalFixture] {
        try await fixture.emitOnObserver(.working(.init(working: true)))
      }
      try await eventually("both working") {
        chat.snapshots[work]?.busy == true && chat.snapshots[personal]?.busy == true
      }
      await chat.interrupt(in: .one(work))
      try await eventually("Work was stopped") { await interrupts(lab.workFixture) == 1 }
      try await Task.sleep(for: .milliseconds(200))
      #expect(await interrupts(lab.personalFixture) == 0, "Personal keeps working")
      await chat.interrupt(in: .all)
      try await eventually("Stop in All reaches both") {
        let (atWork, atPersonal) = (
          await interrupts(lab.workFixture), await interrupts(lab.personalFixture)
        )
        return atWork == 2 && atPersonal == 1
      }
    }
  }

  /// Earlier history in Work's feed pages Work alone, and latest in Personal's feed reloads
  /// Personal alone.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func historyInAScopePagesOnlyThatSession() async throws {
    try await withLab { lab, coordinators in
      for (fixture, name) in [(lab.workFixture, "work"), (lab.personalFixture, "personal")] {
        await fixture.replyToHistory(
          initial: replies(name, 3, next: "\(name)-older"),
          pages: ["\(name)-older": replies("\(name)-older", 3)])
      }
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      await chat.history(anchorID: nil, in: .one(work))
      #expect(await lab.workFixture.historyRequests() == ["work-older"])
      #expect(await lab.personalFixture.historyRequests().isEmpty)
      await chat.latestHistory(in: .one(personal))
      #expect(await lab.workFixture.historyRequests() == ["work-older"])
      #expect(await lab.personalFixture.historyRequests() == ["<latest>"])
    }
  }

  /// In Work's feed, Personal's activity changes nothing shown, so it never scrolls the feed. A
  /// Send-to-both receipt in Work's feed does.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func hiddenActivityNeverBumpsRevision() async throws {
    try await withLab { lab, coordinators in
      let (work, personal) = try await addWorkAndPersonal(coordinators)
      let chat = coordinators.chat
      // Both are busy with a turn, so neither lane reconnects after the Send.
      for fixture in [lab.workFixture, lab.personalFixture] { await fixture.holdPlacements() }
      let text = "Invented: the plan for both"
      chat.draft = text
      await chat.send()
      chat.show(.one(work))
      let receipts = {
        chat.rows.first { $0.row.text == text }?.receipts.map { $0.line(chat.name($0.lane)) }
      }
      try await eventually("Work's feed shows both took it") {
        receipts() == ["Work · Sent", "Personal · Sent"]
      }
      let before = chat.revision
      try await lab.personalFixture.liveMessage(reply("personal-live"))
      try await eventually("Personal's reply arrived") {
        chat.snapshots[personal]?.rows.contains { $0.entryID == "personal-live" } == true
      }
      #expect(chat.revision == before, "Personal's reply is not in Work's feed")
      try await lab.personalFixture.finishTurn()
      try await eventually("Personal placed it") {
        receipts() == ["Work · Sent", "Personal · Delivered"]
      }
      #expect(chat.revision != before, "The receipt in Work's feed changed")
    }
  }

  /// Every live reply counts once, streamed or whole. History pages count nothing, nor does what a
  /// reconnect catches up on before its page.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func liveRepliesCountOncePerReplyAndNeverForHistory() async throws {
    try await withLab { lab, coordinators in
      let fixture = lab.workFixture
      await fixture.replyToHistory(
        initial: replies("recent", 3, next: "older"), pages: ["older": replies("older", 3)])
      await fixture.replyToLatest(replies("latest", 3))
      try await coordinators.add(
        name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      let chat = coordinators.chat
      let work = try #require(coordinators.profiles.first?.id)
      let counted = { chat.snapshots[work]?.liveReplies }
      let shows = { (entry: String) in
        chat.snapshots[work]?.rows.contains { $0.entryID == entry } == true
      }
      try await eventually("Work's first page") {
        chat.snapshots[work]?.connection == .connected && shows("recent-2")
      }
      #expect(counted() == 0, "The first page counts nothing")

      for chunk in ["Invented ", "streamed ", "reply"] {
        try await fixture.emitOnObserver(.textDelta(.init(text: chunk)))
      }
      try await fixture.liveMessage(reply("streamed"))
      try await fixture.emitOnObserver(.answer(.init(entryId: "streamed", text: "Invented reply")))
      try await fixture.liveMessage(tool("after-streamed"))
      try await eventually("the streamed reply") { shows("after-streamed") }
      #expect(counted() == 1, "Three chunks, the message and the answer are one reply")

      try await fixture.emitOnObserver(.answer(.init(entryId: "answered", text: "Invented answer")))
      try await fixture.liveMessage(reply("messaged"))
      try await fixture.liveMessage(tool("after-whole"))
      try await eventually("the whole replies") { shows("after-whole") }
      #expect(counted() == 3, "An answer and a message count once each, and a tool not at all")

      await chat.history(anchorID: nil, in: .all)
      try await eventually("the earlier page") { shows("older-2") }
      await chat.latestHistory(in: .all)
      try await eventually("the latest page") { shows("latest-2") }
      #expect(counted() == 3, "History pages count nothing")

      // The coordinator holds the reconnect's page, and catches up on an answer before it.
      await fixture.holdSnapshot()
      await coordinators.setActive(false)
      await coordinators.setActive(true)
      try await eventually("Work is observed again") { await observes(fixture) == 2 }
      try await fixture.emitOnObserver(
        .answer(.init(entryId: "caught-up", text: "Invented catch-up")))
      try await eventually("the catch-up") { shows("caught-up") }
      await fixture.releaseSnapshot()
      try await eventually("Work connected again") {
        chat.snapshots[work]?.connection == .connected
      }
      try await fixture.liveMessage(reply("after-reconnect"))
      try await eventually("the reply after the reconnect") { shows("after-reconnect") }
      #expect(counted() == 4, "The catch-up counts nothing, and the next live reply counts")
    }
  }

  /// A coordinator added while another's feed is shown has nothing new, however long its first
  /// page. Live replies are new until its feed or All is shown. A replaced session starts from its
  /// own first page.
  @MainActor @Test(.timeLimit(.minutes(1)))
  func aNewCoordinatorsFirstPageIsNotNew() async throws {
    try await withLab { lab, coordinators in
      await lab.personalFixture.replyToHistory(initial: replies("personal", 20), pages: [:])
      let chat = coordinators.chat
      try await coordinators.add(
        name: TagName("Work"), address: CoordinatorAddress(host: "100.64.1.2", port: 4001))
      let work = try #require(coordinators.profiles.first?.id)
      chat.show(.one(work))
      try await coordinators.add(
        name: TagName("Personal"), address: CoordinatorAddress(host: "100.64.1.2", port: 4002))
      let personal = try #require(coordinators.profiles.last?.id)
      let unseen = { chat.news.first { $0.id == personal }?.unseen }
      let shows = { (entry: String) in
        chat.snapshots[personal]?.rows.contains { $0.entryID == entry } == true
      }
      try await eventually("Personal's first page") {
        chat.snapshots[personal]?.connection == .connected && shows("personal-19")
      }
      #expect(chat.scope == .one(work))
      #expect(unseen() == 0, "Twenty replies on the first page are not new")
      for entry in ["live-1", "live-2"] { try await lab.personalFixture.liveMessage(reply(entry)) }
      try await eventually("two live replies") { shows("live-2") }
      #expect(unseen() == 2)
      chat.show(.one(personal))
      #expect(unseen() == 0, "Showing Personal clears it")
      chat.show(.one(work))
      try await lab.personalFixture.liveMessage(reply("live-3"))
      try await eventually("a third live reply") { shows("live-3") }
      #expect(unseen() == 1)
      chat.show(.all)
      #expect(chat.news.map(\.unseen) == [0, 0], "All clears every count")

      chat.show(.one(work))
      try await coordinators.update(
        personal, name: TagName("Personal"),
        address: CoordinatorAddress(host: "100.64.1.2", port: 4004))
      try await eventually("Personal's next session has its first page") {
        chat.snapshots[personal]?.connection == .connected && shows("personal-19")
      }
      #expect(unseen() == 0)
      try await lab.personalFixture.liveMessage(reply("live-4"))
      try await eventually("a live reply to the next session") { shows("live-4") }
      #expect(unseen() == 1, "The next session's replies count from its own first page")
    }
  }

  /// One coordinator's feed shows only the held messages it is proven to own. All shows every one,
  /// counting those no coordinator owns. Only All names the coordinators.
  @MainActor @Test func heldMessagesAndNamesFollowTheScope() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let chat = ChatModel()
    var profiles = try [("Work", 4001), ("Personal", 4002)].map { name, port in
      CoordinatorProfile(
        name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.2", port: port))
    }
    profiles[0].pin = CoordinatorID(UUID())
    chat.profiles = profiles
    let (work, personal) = (profiles[0].id, profiles[1].id)
    chat.holds = [
      try heldQueue(
        [NativeRequestSubmit(inputId: "work-held", mode: .steer, text: "Invented: Work's")],
        in: root, coordinator: profiles[0].pin),
      try heldQueue(
        [NativeRequestSubmit(inputId: "unowned", mode: .steer, text: "Invented: nobody's")],
        in: root, address: CoordinatorAddress(host: "100.64.1.2", port: 4009)),
    ]
    try await eventually("both queues were read") { chat.held.count == 2 }
    #expect(chat.namesLanes)
    #expect(Set(chat.shownHeld.map(\.id)) == ["work-held", "unowned"])
    #expect(chat.unownedHeld == 1)
    #expect(chat.news.map(\.held) == [1, 0])
    #expect(chat.news.map(\.attention) == [.notPaired, .notPaired])
    chat.show(.one(work))
    #expect(!chat.namesLanes)
    #expect(chat.shownHeld.map(\.id) == ["work-held"])
    chat.show(.one(personal))
    #expect(chat.shownHeld.isEmpty)
  }
}
