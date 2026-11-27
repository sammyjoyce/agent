import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

@Test(.timeLimit(.minutes(1)))
func sidechatsControlOperationsAndCapabilityGating() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected {
      #expect(!snapshot.sidechatsSupported)
      break
    }
    await #expect(throws: CoordinatorRejection.self) {
      _ = try await session.listSidechats()
    }
    await session.disconnect()

    await fixture.advertiseSidechats(true)
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected {
      #expect(snapshot.sidechatsSupported)
      break
    }

    let created = try await session.createSidechat(
      .init(
        charter: "Track release readiness.",
        handoff: "Seeded from Main.",
        isolated: false,
        notifications: .inherit,
        slug: "release-prep",
        title: "Release Prep"))
    #expect(created.slug == "release-prep")
    #expect(created.title == "Release Prep")
    #expect(created.charter == "Track release readiness.")
    #expect(!created.isolated)
    #expect(created.notifications == .inherit)

    let active = try await session.listSidechats(includeArchived: false)
    #expect(active.map(\.conversationId) == [created.conversationId])

    let updated = try await session.updateSidechat(
      .init(
        archived: true,
        clearCharter: true,
        conversationId: created.conversationId,
        isolated: true,
        notifications: .on,
        pinned: true))
    #expect(updated.pinned)
    #expect(updated.isolated)
    #expect(updated.charter == nil)
    #expect(updated.notifications == .on)
    #expect(updated.archivedAt != nil)

    #expect(try await session.listSidechats(includeArchived: false).isEmpty)
    #expect(
      try await session.listSidechats(includeArchived: true).map(\.conversationId) == [
        created.conversationId
      ])
  }
}

@Test(.timeLimit(.minutes(1)))
func sidechatSessionIsolatesOutboxStreamsRepliesInterruptsSettingsAndToolDetails() async throws {
  try await withCoordinator { mainSession, fixture, mainOutbox in
    await fixture.advertiseSidechats(true)
    await fixture.advertiseSettings(true)
    await fixture.advertiseInputOrigins(true)
    await fixture.answerEachSubmit("Side chat answer")
    await mainSession.connect()
    for await snapshot in mainSession.updates where snapshot.connection == .connected { break }

    let created = try await mainSession.createSidechat(
      .init(slug: "homelab-ops", title: "Homelab Ops"))
    await fixture.replyToSidechatHistory(
      created.conversationId,
      page: .init(
        messages: [
          HistoryMessage(
            continuation: false, entryId: "10", finalChunk: true, role: .notice,
            text: "Standing topic created")
        ], nextCursor: nil, pageComplete: true))
    await fixture.replyToSettings(
      .init(
        configured: .init(
          catalog: [], conversationId: created.conversationId,
          model: .init(fast: false, modelId: "fixture-model", provider: .openai))))
    await fixture.replyToToolLookups(with: [
      .toolDetails(.init(details: .unavailable(.init(callId: "call-sc-1")))),
      .done,
    ])

    let sidechatSession = try #require(await mainSession.sidechatSession(created))
    #expect(sidechatSession.outboxURL != mainOutbox)
    #expect(sidechatSession.outboxURL.path.contains("/Sidechats/"))

    await sidechatSession.connect()
    for await snapshot in sidechatSession.updates where snapshot.connection == .connected {
      #expect(snapshot.conversationID == created.conversationId)
      #expect(snapshot.sidechat?.slug == "homelab-ops")
      #expect(snapshot.rows.contains { $0.text == "Standing topic created" })
      break
    }

    let submitted = await sidechatSession.submit("Check rack temperatures")
    #expect(submitted)
    for await snapshot in sidechatSession.updates
    where snapshot.rows.contains(where: { $0.text == "Side chat answer" }) {
      break
    }
    let scInputs = await fixture.sidechatSubmissions()
    #expect(scInputs.count == 1)
    #expect(scInputs[0].conversationId == created.conversationId)
    #expect(scInputs[0].text == "Check rack temperatures")
    #expect(await fixture.count() == 0, "Side chat messages must never be sent to Main")
    #expect(!FileManager.default.fileExists(atPath: mainOutbox.path))

    await sidechatSession.interrupt()
    while await fixture.sidechatInterrupts().isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await fixture.sidechatInterrupts() == [created.conversationId])

    let settings = try await sidechatSession.settings()
    #expect(settings.configured.conversationId == created.conversationId)
    #expect(await fixture.settingsControls().last?.conversationId == created.conversationId)

    let details = try await sidechatSession.toolDetails(entryID: "10", callID: "call-sc-1")
    #expect(details == .unavailable(.init(callId: "call-sc-1")))
    #expect(await fixture.toolLookups().last?.conversationId == created.conversationId)

    await mainSession.retire()
    #expect(await sidechatSession.connectionState == .disconnected)
  }
}

@Test(.timeLimit(.minutes(1)))
func sidechatNotificationOverrideKeepsDeviceRegisteredWhenMainAlertsOff() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let profile = session.profile
    let installation = "\(profile)"
    let token = String(repeating: "ab", count: 32)
    let registration = await NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })

    await registration.connect(session.notificationChannel)
    #expect(await !registration.status(profile).registered)

    // Turning a side chat to On while Main is Off enrolls with main_enabled: false.
    await registration.received(token: token)
    await registration.setSidechatAlertsOn(true, for: profile)
    #expect(await registration.status(profile).registered)
    #expect(
      await fixture.notificationControls().last
        == .register(.init(installationId: installation, mainEnabled: false, token: token)))

    // Turning Main On updates main_enabled to true.
    await registration.setEnabled(true)
    #expect(
      await fixture.notificationControls().last
        == .register(.init(installationId: installation, mainEnabled: true, token: token)))

    // Turning Main back Off while a side chat is On keeps device registered with main_enabled: false.
    await registration.setEnabled(false)
    #expect(await registration.status(profile).registered)
    #expect(
      await fixture.notificationControls().last
        == .register(.init(installationId: installation, mainEnabled: false, token: token)))

    // Reopening with Main Off preserves registration when coordinator reports main_enabled: false.
    let reopened = await NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    await reopened.connect(session.notificationChannel)
    #expect(await reopened.hasSidechatOverrides(profile))
    #expect(await reopened.status(profile).registered)

    // Clearing the last side chat override while Main is Off unregisters the device.
    await registration.setSidechatAlertsOn(false, for: profile)
    #expect(await !registration.status(profile).registered)
    #expect(
      await fixture.notificationControls().last
        == .unregister(.init(installationId: installation)))
  }
}

@Test @MainActor
func sidechatPushNotificationRoutesDirectlyAndSuppressesOnlyWhenActive() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let defaults = TestPreferences()
  defaults.set(true, forKey: "notificationsEnabled")

  var work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  work.pin = CoordinatorID(UUID())
  var personal = CoordinatorProfile(
    name: try TagName("Personal"), address: try CoordinatorAddress(host: "100.64.1.3"))
  personal.pin = CoordinatorID(UUID())
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [work, personal])),
    to: root.appending(path: "Agent/profiles.json"))

  let notifications = AppNotifications(
    defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet,
    permission: { true })
  let chat = notifications.coordinators.chat
  chat.show(.one(work.id))
  chat.draft = "Keep my draft untouched"

  let userInfo: [AnyHashable: Any] = [
    "agent": [
      "conversation_id": "42",
      "entry_id": "99",
      "installation_id": "\(personal.id)",
    ]
  ]
  let payload = try #require(AppNotifications.payload(userInfo))
  #expect(payload.origin == .named(personal.id))
  #expect(payload.conversationID == "42")

  // Tapping routes directly to the side chat without altering Main's draft or scope.
  notifications.open(payload)
  #expect(
    notifications.openRequest?.destination
      == .sidechat(ScopedEntityID(profile: personal.id, item: "42")))
  #expect(chat.scope == .one(work.id))
  #expect(chat.draft == "Keep my draft untouched")

  // Foreground presentation: suppressed ONLY when viewing that exact side chat.
  notifications.mainVisible = .visible(atLatest: true)
  #expect(notifications.presents(payload: payload))
  notifications.activeSidechat = ScopedEntityID(profile: personal.id, item: "99")
  #expect(notifications.presents(payload: payload))
  notifications.activeSidechat = ScopedEntityID(profile: personal.id, item: "42")
  #expect(!notifications.presents(payload: payload))

  // When Main alerts are off, side chat banners still present when an override is active.
  notifications.activeSidechat = nil
  await notifications.registration.setEnabled(false)
  #expect(!notifications.presents(payload: payload))
  await notifications.registration.setSidechatAlertsOn(true, for: personal.id)
  #expect(notifications.presents(payload: payload))
  let mainPayload = AlertPayload(origin: .named(personal.id), conversationID: "1")
  #expect(!notifications.presents(payload: mainPayload))
}

@Test
func activeWorkItemCarriesSidechatSlugAndTitle() throws {
  let json = """
    {
      "id": "sidechat:42",
      "title": "Homelab Ops",
      "sidechat_slug": "homelab-ops",
      "conversation_id": "42",
      "status": "running",
      "detail": "read_file: docs/roadmap.md",
      "started_at": 4000,
      "is_job": false
    }
    """
  let item = try JSONDecoder().decode(ActiveWorkItem.self, from: Data(json.utf8))
  #expect(item.id == "sidechat:42")
  #expect(item.title == "Homelab Ops")
  #expect(item.sidechatSlug == "homelab-ops")
  #expect(item.conversationId == "42")
  #expect(item.status == .running)
}

@Test(.timeLimit(.minutes(1)))
func sidechatUpdatePersistsAcrossSubsequentSnapshots() async throws {
  try await withCoordinator { mainSession, fixture, _ in
    await fixture.advertiseSidechats(true)
    await fixture.answerEachSubmit("Follow-up answer")
    await mainSession.connect()
    for await snapshot in mainSession.updates where snapshot.connection == .connected { break }

    let created = try await mainSession.createSidechat(
      .init(slug: "homelab-ops", title: "Homelab Ops"))
    let sidechatSession = try #require(await mainSession.sidechatSession(created))
    await sidechatSession.connect()
    for await snapshot in sidechatSession.updates where snapshot.connection == .connected {
      #expect(snapshot.sidechat?.title == "Homelab Ops")
      break
    }

    let renamed = try await mainSession.updateSidechat(
      .init(conversationId: created.conversationId, title: "Homelab Ops v2"))
    await sidechatSession.updateActiveSidechat(renamed)
    for await snapshot in sidechatSession.updates where snapshot.sidechat?.title == "Homelab Ops v2"
    {
      break
    }

    // Subsequent message + answer snapshots must keep the updated title.
    let sent = await sidechatSession.submit("Check fans")
    #expect(sent)
    for await snapshot in sidechatSession.updates
    where snapshot.rows.contains(where: { $0.text == "Follow-up answer" }) {
      #expect(snapshot.sidechat?.title == "Homelab Ops v2")
      break
    }

    // Minting a second session for the same side chat retires the previous one cleanly.
    let replacement = try #require(await mainSession.sidechatSession(renamed))
    #expect(await sidechatSession.connectionState == .disconnected)
    await replacement.connect()
    for await snapshot in replacement.updates where snapshot.connection == .connected {
      #expect(snapshot.sidechat?.title == "Homelab Ops v2")
      break
    }
    await mainSession.retire()
  }
}

@Test
func profileDirectoryQueuedMessagesIncludesSidechatOutboxes() throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let profile = ProfileID()
  let directory = ProfileDirectory(profile, applicationSupport: root, caches: root)
  #expect(try directory.queuedMessages() == 0)

  let item = OutboxItem(
    request: NativeRequestSubmit(
      attachments: nil, inputId: UUID().uuidString, mode: .steer, origin: .ios, text: "Queued"),
    sendID: UUID().uuidString, recipients: [profile], queuedAt: 1, staged: false)
  let payload = try JSONEncoder().encode([item])
  let scOutbox = directory.sidechat("42").outbox
  try FileManager.default.createDirectory(
    at: scOutbox.deletingLastPathComponent(), withIntermediateDirectories: true)
  try payload.write(to: scOutbox)
  #expect(try directory.queuedMessages() == 1)

  try FileManager.default.createDirectory(
    at: directory.outbox.deletingLastPathComponent(), withIntermediateDirectories: true)
  try payload.write(to: directory.outbox)
  #expect(try directory.queuedMessages() == 2)
}

@Test(.timeLimit(.minutes(1)))
func sidechatNotificationRecoveryAndRapidOnOffUnregister() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let profile = session.profile
    let installation = "\(profile)"
    let token = String(repeating: "cd", count: 32)

    // 1. Server already holds main_enabled: false; reopening with Main alerts ON must send main_enabled: true.
    await fixture.register(installation, token: token, mainEnabled: false)
    let recovering = await NotificationRegistration(
      enabled: true, permission: { true }, register: {}, save: { _ in })
    await recovering.received(token: token)
    await recovering.connect(session.notificationChannel)
    #expect(
      await fixture.notificationControls().last
        == .register(.init(installationId: installation, mainEnabled: true, token: token)))

    // 2. Rapid On -> Off while enroll is in-flight must leave the coordinator unregistered.
    await fixture.holdNotificationRegistration()
    let racing = await NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    await racing.received(token: token)
    await racing.connect(session.notificationChannel)
    let enableTask = Task { await racing.setSidechatAlertsOn(true, for: profile) }
    while await fixture.notificationControls().last
      != .register(.init(installationId: installation, mainEnabled: false, token: token))
    {
      try await Task.sleep(for: .milliseconds(5))
    }
    let disableTask = Task { await racing.setSidechatAlertsOn(false, for: profile) }
    await fixture.releaseNotificationRegistration()
    await enableTask.value
    await disableTask.value
    #expect(await !fixture.holds(installation))

    // 3. Denied permission rolls back sidechatOverrides to false.
    let denied = await NotificationRegistration(
      enabled: false, permission: { false }, register: {}, save: { _ in })
    await denied.setSidechatAlertsOn(true, for: profile)
    #expect(await !denied.hasSidechatOverrides(profile))
  }
}

@Test @MainActor
func sidechatPushNotificationDoesNotMisrouteRemovedCoordinator() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let defaults = TestPreferences()
  defaults.set(true, forKey: "notificationsEnabled")

  var work = CoordinatorProfile(
    name: try TagName("Work"), address: try CoordinatorAddress(host: "100.64.1.2"))
  work.pin = CoordinatorID(UUID())
  try writePrivately(
    JSONEncoder().encode(Coordinators.SavedProfiles(profiles: [work])),
    to: root.appending(path: "Agent/profiles.json"))

  let notifications = AppNotifications(
    defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet,
    permission: { true })
  let removedID = ProfileID()
  let removedPayload = AlertPayload(origin: .named(removedID), conversationID: "42")
  notifications.mainVisible = .visible(atLatest: true)
  #expect(!notifications.presents(payload: removedPayload))
  notifications.open(removedPayload)
  if case .sidechat? = notifications.openRequest?.destination {
    Issue.record("Removed coordinator alert must never route to another coordinator's side chat")
  }
}

@Test(.timeLimit(.minutes(1)))
func sidechatComposerPreservesReplyTargetForSlashPrefixedText() async throws {
  try await withCoordinator { mainSession, fixture, _ in
    await fixture.advertiseSidechats(true)
    await fixture.answerEachSubmit("Literal slash reply")
    let owner = await MainActor.run {
      let model = ChatModel()
      model.attach(Lane(id: mainSession.profile, session: mainSession))
      return model
    }
    await owner.setActive(true)
    while await owner.connection != .connected { try await Task.sleep(for: .milliseconds(5)) }

    let created = try await mainSession.createSidechat(
      .init(slug: "ops", title: "Ops"))
    let sidechatModel = await MainActor.run { ChatModel(sidechat: created) }
    await sidechatModel.connectSidechat(using: owner, lane: mainSession.profile, sidechat: created)
    while await sidechatModel.connection != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }

    let replyRef = ReplyReference(entryId: "12", excerpt: "Earlier note", role: .assistant)
    await MainActor.run {
      let row = RowModel(
        ChatRow(
          id: "invented-reply", entryID: replyRef.entryId, role: replyRef.role,
          text: replyRef.excerpt))
      row.lane = mainSession.profile
      sidechatModel.reply(to: row)
      sidechatModel.draft = "/etc/hosts check"
    }
    await sidechatModel.send()

    while await fixture.sidechatSubmissions().isEmpty {
      try await Task.sleep(for: .milliseconds(5))
    }
    let sent = try #require(await fixture.sidechatSubmissions().first)
    #expect(sent.text == "/etc/hosts check")
    #expect(sent.replyTo == replyRef)
    #expect(await sidechatModel.replyTarget == nil)

    await mainSession.retire()
  }
}

@Test(.timeLimit(.minutes(1)))
func readOnlyInspectionOmitsConversationIdForLegacyCoordinatorToolDetails() async throws {
  try await withCoordinator { mainSession, fixture, _ in
    await fixture.advertiseSidechats(false)
    await fixture.replyToHistory(
      initial: .init(messages: [], nextCursor: nil, pageComplete: true), pages: [:])
    await fixture.replyToToolLookups(with: [
      .toolDetails(.init(details: .unavailable(.init(callId: "call-legacy-1")))),
      .done,
    ])
    await mainSession.connect()
    while await mainSession.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }

    let saved = SavedConversation(conversationId: "77", title: "Saved chat")
    let inspector = try #require(await mainSession.inspector(saved))
    await inspector.connect()
    while await inspector.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }

    _ = try await inspector.toolDetails(entryID: "10", callID: "call-legacy-1")
    #expect(await fixture.toolLookups().last?.conversationId == nil)

    // Positive companion check: when the coordinator advertises side chats, read-only inspection
    // of a saved conversation without a task includes conversationId.
    await mainSession.disconnect()
    await fixture.advertiseSidechats(true)
    await fixture.replyToToolLookups(with: [
      .toolDetails(.init(details: .unavailable(.init(callId: "call-modern-1")))),
      .done,
    ])
    await mainSession.connect()
    while await mainSession.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }
    let modernInspector = try #require(await mainSession.inspector(saved))
    await modernInspector.connect()
    while await modernInspector.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }
    _ = try await modernInspector.toolDetails(entryID: "10", callID: "call-modern-1")
    #expect(await fixture.toolLookups().last?.conversationId == "77")

    await mainSession.retire()
  }
}

@Test(.timeLimit(.minutes(1)))
func sidechatSendClearsLocalArchivedStateAndPresenceTokenProtectsBannerSuppression() async throws {
  try await withCoordinator { mainSession, fixture, _ in
    await fixture.advertiseSidechats(true)
    await fixture.answerEachSubmit("Unarchived reply")
    await mainSession.connect()
    while await mainSession.connectionState != .connected {
      try await Task.sleep(for: .milliseconds(5))
    }

    let created = try await mainSession.createSidechat(.init(slug: "archived-topic", title: "Old"))
    let archived = try await mainSession.updateSidechat(
      .init(archived: true, conversationId: created.conversationId))
    #expect(archived.archivedAt != nil)

    let sidechatSession = try #require(await mainSession.sidechatSession(archived))
    await sidechatSession.connect()
    for await snapshot in sidechatSession.updates where snapshot.connection == .connected {
      #expect(snapshot.sidechat?.archivedAt != nil)
      break
    }

    let sent = await sidechatSession.submit("Wake this topic")
    #expect(sent)
    for await snapshot in sidechatSession.updates
    where snapshot.rows.contains(where: { $0.text == "Unarchived reply" }) {
      #expect(snapshot.sidechat?.archivedAt == nil)
      break
    }

    await mainSession.retire()
  }

  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  await MainActor.run {
    let defaults = TestPreferences()
    let notifications = AppNotifications(
      defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet,
      permission: { true })
    let target = ScopedEntityID(profile: ProfileID(), item: "42")
    let firstToken = UUID()
    let secondToken = UUID()
    notifications.setActiveSidechat(target, token: firstToken)
    notifications.setActiveSidechat(target, token: secondToken)
    notifications.clearActiveSidechat(token: firstToken)
    #expect(notifications.activeSidechat == target)
    notifications.clearActiveSidechat(token: secondToken)
    #expect(notifications.activeSidechat == nil)
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func rootConversationNotificationRoutesToMainEvenWhenReadyReportsCustomRootID() async throws {
  let workFixture = FixtureCoordinator()
  let personalFixture = FixtureCoordinator()
  let (workListener, workPort) = try await listen(workFixture)
  let (personalListener, personalPort) = try await listen(personalFixture)

  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  let defaults = TestPreferences()
  defaults.set(true, forKey: "notificationsEnabled")

  let notifications = AppNotifications(
    defaults: defaults, applicationSupport: root, caches: root,
    transport: CoordinatorTransport { address in
      LineConnection(
        connection: NWConnection(to: address.port == 4002 ? personalPort : workPort, using: .tcp))
    },
    permission: { true })
  await notifications.coordinators.setActive(true)
  defer {
    workListener.cancel()
    personalListener.cancel()
    try? FileManager.default.removeItem(at: root)
  }

  do {
    let (work, personal) = try await addWorkAndPersonal(notifications.coordinators)
    let chat = notifications.coordinators.chat
    #expect(chat.snapshots[personal]?.conversationID == "fixture-root")
    #expect(chat.snapshots[personal]?.sidechatsSupported == false)

    // Connected coordinator without side chats: APNs root payload ("1") routes to Main, not a
    // dead-end "Side chats unavailable" screen, and preserves the unsent draft.
    chat.show(.one(work))
    chat.draft = "Keep this Work draft"
    let rootPayload = try #require(
      AppNotifications.payload([
        "agent": ["conversation_id": "1", "entry_id": "42", "installation_id": "\(personal)"]
      ]))
    notifications.open(rootPayload)
    #expect(notifications.openRequest?.destination == .feed(notice: nil))
    #expect(chat.scope == .one(personal))
    #expect(chat.draft == "Keep this Work draft")

    // Foreground banner policy follows Main's visibility rule for that coordinator.
    notifications.mainVisible = .visible(atLatest: true)
    #expect(!notifications.presents(payload: rootPayload))

    // Once the coordinator advertises side chats, root ("1" or "fixture-root") still routes to
    // Main while non-root side chat IDs ("42") route directly to the side chat.
    await personalFixture.advertiseSidechats(true)
    await notifications.coordinators.setActive(false)
    await notifications.coordinators.setActive(true)
    let reconnectDeadline = ContinuousClock.now + .seconds(15)
    while chat.snapshots[personal]?.connection != .connected
      || chat.snapshots[personal]?.sidechatsSupported != true
    {
      try #require(
        ContinuousClock.now < reconnectDeadline, "Timed out waiting for sidechat reconnect")
      try await Task.sleep(for: .milliseconds(5))
    }
    chat.show(.one(work))
    notifications.open(rootPayload)
    #expect(notifications.openRequest?.destination == .feed(notice: nil))
    #expect(chat.scope == .one(personal))

    let customRootPayload = try #require(
      AppNotifications.payload([
        "agent": [
          "conversation_id": "fixture-root", "entry_id": "43", "installation_id": "\(personal)",
        ]
      ]))
    chat.show(.one(work))
    notifications.open(customRootPayload)
    #expect(notifications.openRequest?.destination == .feed(notice: nil))
    #expect(chat.scope == .one(personal))

    let sidechatPayload = try #require(
      AppNotifications.payload([
        "agent": ["conversation_id": "42", "entry_id": "99", "installation_id": "\(personal)"]
      ]))
    notifications.open(sidechatPayload)
    #expect(
      notifications.openRequest?.destination
        == .sidechat(ScopedEntityID(profile: personal, item: "42")))
    #expect(notifications.presents(payload: sidechatPayload))
  } catch {
    await notifications.coordinators.setActive(false)
    await workFixture.stop()
    await personalFixture.stop()
    throw error
  }
  await notifications.coordinators.setActive(false)
  await workFixture.stop()
  await personalFixture.stop()
}
