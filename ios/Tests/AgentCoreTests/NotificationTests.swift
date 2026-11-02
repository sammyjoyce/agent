import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

@Test(arguments: [false, true]) @MainActor
func notificationStartupAsksOnceBeforeConnectionAndRemembersDenial(granted: Bool) async {
  var permissions = 0
  var registrations = 0
  var saved: [Bool] = []
  let registration = NotificationRegistration(
    enabled: true,
    permission: {
      permissions += 1
      return granted
    },
    register: { registrations += 1 }, save: { saved.append($0) })
  await registration.start()
  #expect(registration.enabled == granted)
  #expect(permissions == 1 && registrations == (granted ? 1 : 0))
  #expect(saved == [granted])
  if !granted { #expect(registration.error?.contains("Settings") == true) }
  await registration.start()
  await registration.connect(
    NotificationChannel(installation: ProfileID()) { _ in
      .init(configured: false, registered: false)
    })
  await registration.start()
  #expect(permissions == 1)
  #expect(registrations == (granted ? 1 : 0))
}

@Test @MainActor
func notificationExplicitOptOutNeverRequestsPermissionOrEnrolls() async {
  let profile = ProfileID()
  let registration = NotificationRegistration(
    enabled: false,
    permission: {
      Issue.record("Opt-out must not ask for permission")
      return true
    },
    register: { Issue.record("Opt-out must not register with Apple") }, save: { _ in })
  await registration.start()
  await registration.received(token: String(repeating: "ab", count: 32))
  await registration.connect(
    NotificationChannel(installation: profile) { request in
      if case .status = request {} else { Issue.record("Opt-out must not enroll") }
      return .init(configured: true, registered: false)
    })
  #expect(!registration.enabled && !registration.status(profile).registered)
}

@Test(.timeLimit(.minutes(1))) @MainActor
func notificationNativeControlsRefreshTheSameInstallationAndNeverSubmitModelInput() async throws {
  try await withCoordinator { session, fixture, outbox in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let installation = "\(session.profile)"
    let registration = await NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    await registration.connect(session.notificationChannel)
    await registration.setEnabled(true)
    await registration.received(token: String(repeating: "01ab", count: 16))
    await registration.received(token: String(repeating: "02cd", count: 24))
    #expect(await registration.status(session.profile).registered)
    await registration.setEnabled(false)
    #expect(await !registration.enabled)
    #expect(await !registration.status(session.profile).registered)
    #expect(
      await fixture.notificationControls() == [
        .status(.init(installationId: installation)),
        .register(.init(installationId: installation, token: String(repeating: "01ab", count: 16))),
        .register(.init(installationId: installation, token: String(repeating: "02cd", count: 24))),
        .unregister(.init(installationId: installation)),
      ])
    #expect(await fixture.count() == 0)
    #expect(!FileManager.default.fileExists(atPath: outbox.path))
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func notificationWithdrawalOrdersAfterAnInflightTokenAndSuppressesLateRegistration() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let registration = await NotificationRegistration(
      enabled: true, permission: { true }, register: {}, save: { _ in })
    await registration.connect(session.notificationChannel)
    await fixture.holdNotificationRegistration()
    let enroll = Task { await registration.received(token: String(repeating: "01ab", count: 16)) }
    for await _ in fixture.observedNotifications {
      if await fixture.notificationControls().contains(where: {
        if case .register = $0 { true } else { false }
      }) {
        break
      }
    }
    let withdraw = Task { await registration.setEnabled(false) }
    while await registration.enabled { await Task.yield() }
    await registration.received(token: String(repeating: "02cd", count: 16))
    #expect(await fixture.notificationControls().count == 2)
    await fixture.releaseNotificationRegistration()
    await enroll.value
    await withdraw.value
    #expect(await !registration.status(session.profile).registered)
    #expect(await fixture.notificationControls().count == 3)
    if case .unregister = await fixture.notificationControls().last {
    } else {
      Issue.record("Withdrawal must be the final native control")
    }
    #expect(await fixture.count() == 0)
  }
}

@MainActor private func notificationsWithoutSavedCoordinators(_ defaults: UserDefaults)
  -> AppNotifications
{
  let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
  return AppNotifications(
    defaults: defaults, applicationSupport: root, caches: root, transport: .tailnet)
}

@Test @MainActor
func notificationForegroundPolicyAndTapUseTheExistingMainWithoutPersistingDeviceTokens()
  async throws
{
  let name = "notification-fixture-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  defaults.set(true, forKey: "notificationsEnabled")
  let notifications = notificationsWithoutSavedCoordinators(defaults)
  #expect(notifications.presentsAlerts)
  notifications.mainVisible = true
  #expect(!notifications.presentsAlerts)
  let target = NotificationTarget(conversationId: "1", entryId: "42")
  notifications.open(target)
  notifications.open(target)
  #expect(notifications.openedTarget == target)
  await notifications.registration.received(token: String(repeating: "ab", count: 32))
  #expect(defaults.persistentDomain(forName: name)?.keys.sorted() == ["notificationsEnabled"])
}

@Test(.timeLimit(.minutes(1)))
func notificationRemovalIntentSurvivesAnUncertainReceiptAndAReopenedClient() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let profile = session.profile
    let original = await NotificationRegistration(
      enabled: true, permission: { true }, register: {}, save: { _ in })
    await original.connect(session.notificationChannel)
    await original.received(token: String(repeating: "ab", count: 32))
    await fixture.dropNextNotificationRemoval()
    await original.setEnabled(false)
    #expect(await !original.enabled)
    #expect(await original.status(profile).registered)
    #expect(await original.status(profile).error != nil)
    await original.failed()
    #expect(
      await original.status(profile).registered, "An OS callback cannot confirm coordinator removal"
    )
    #expect(await original.status(profile).error?.contains("removal is unconfirmed") == true)
    let reopened = await NotificationRegistration(
      enabled: false, permission: { true }, register: {}, save: { _ in })
    await reopened.connect(session.notificationChannel)
    #expect(await !reopened.status(profile).registered)
    #expect(await reopened.status(profile).error == nil)
    #expect(
      await fixture.notificationControls().filter {
        if case .unregister = $0 { true } else { false }
      }.count == 2)
    #expect(await fixture.count() == 0)
  }
}

@Test @MainActor
func notificationsDefaultOnWithoutOverridingAnExplicitPreference() throws {
  let name = "notification-default-fixture-\(UUID())"
  let defaults = try #require(UserDefaults(suiteName: name))
  defer { defaults.removePersistentDomain(forName: name) }
  #expect(defaults.object(forKey: "notificationsEnabled") == nil)
  #expect(notificationsWithoutSavedCoordinators(defaults).registration.enabled)
  defaults.set(false, forKey: "notificationsEnabled")
  #expect(!notificationsWithoutSavedCoordinators(defaults).registration.enabled)
  defaults.set(true, forKey: "notificationsEnabled")
  #expect(notificationsWithoutSavedCoordinators(defaults).registration.enabled)
}

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func notificationStartupEnrollsTheLatestTokenOncePerConnection(tokenBeforeConnection: Bool)
  async throws
{
  try await withCoordinator { session, fixture, outbox in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let probe = NotificationProbe()
    let profile = session.profile
    let installation = "\(profile)"
    let first = String(repeating: "ab", count: 32)
    let second = String(repeating: "cd", count: 32)
    let registration = await NotificationRegistration(
      enabled: true,
      permission: {
        probe.permissions += 1
        return true
      },
      register: { probe.registrations += 1 }, save: { probe.saved.append($0) })
    await registration.start()
    if tokenBeforeConnection { await registration.received(token: first) }
    await registration.connect(session.notificationChannel)
    if !tokenBeforeConnection { await registration.received(token: first) }
    await registration.received(token: first)
    #expect(await registration.status(profile).registered)
    #expect(await fixture.notificationControls().count == 2)

    await fixture.holdNotificationRegistration()
    let refresh = Task { await registration.received(token: second) }
    for await _ in fixture.observedNotifications {
      if await fixture.notificationControls().contains(
        .register(.init(installationId: installation, token: second)))
      {
        break
      }
    }
    let duplicate = Task { await registration.received(token: second) }
    await fixture.releaseNotificationRegistration()
    await refresh.value
    await duplicate.value
    #expect(await fixture.notificationControls().count == 3)

    await registration.disconnect(profile)
    await registration.connect(session.notificationChannel)
    #expect(await registration.status(profile).registered)
    #expect(await probe.permissions == 1)
    #expect(await probe.registrations == 1)
    await registration.setEnabled(false)
    await registration.received(token: first)
    #expect(await !registration.enabled)
    #expect(await !registration.status(profile).registered)
    #expect(
      await fixture.notificationControls() == [
        .status(.init(installationId: installation)),
        .register(.init(installationId: installation, token: first)),
        .register(.init(installationId: installation, token: second)),
        .status(.init(installationId: installation)),
        .register(.init(installationId: installation, token: second)),
        .unregister(.init(installationId: installation)),
      ])
    #expect(await fixture.count() == 0)
    #expect(!FileManager.default.fileExists(atPath: outbox.path))
  }
}

@Test(.timeLimit(.minutes(1)))
func notificationPermissionCanCompleteAfterTheConnectionAndTokenArrive() async throws {
  try await withCoordinator { session, fixture, _ in
    await session.connect()
    for await snapshot in session.updates where snapshot.connection == .connected { break }
    let gate = AsyncStream<Void>.makeStream()
    defer { gate.continuation.finish() }
    let probe = NotificationProbe()
    let registration = await NotificationRegistration(
      enabled: true,
      permission: {
        probe.permissions += 1
        for await _ in gate.stream { return true }
        return false
      }, register: { probe.registrations += 1 }, save: { probe.saved.append($0) })
    let opening = Task { await registration.start() }
    while await probe.permissions == 0 { await Task.yield() }
    await registration.connect(session.notificationChannel)
    await registration.received(token: String(repeating: "ab", count: 32))
    #expect(await fixture.notificationControls().count == 1)
    gate.continuation.yield(())
    await opening.value
    #expect(await registration.status(session.profile).registered)
    #expect(await fixture.notificationControls().count == 2)
    #expect(await probe.permissions == 1)
    #expect(await fixture.count() == 0)
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func notificationDuplicateTokenKeepsAnUnconfirmedEnrollmentVisible() async {
  let replies = AsyncStream<Void>.makeStream()
  let observed = AsyncStream<NotificationRequest>.makeStream()
  let joined = AsyncStream<Void>.makeStream()
  defer {
    replies.continuation.finish()
    observed.continuation.finish()
    joined.continuation.finish()
  }
  let profile = ProfileID()
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.connect(
    NotificationChannel(installation: profile) { request in
      observed.continuation.yield(request)
      if case .register = request {
        for await _ in replies.stream { break }
        return .init(configured: true, registered: false)
      }
      return .init(configured: true, registered: true)
    })
  #expect(registration.status(profile).registered)
  let token = String(repeating: "ab", count: 32)
  let first = Task(priority: .high) { await registration.received(token: token) }
  for await request in observed.stream {
    if case .register = request { break }
  }
  let follower = Task(priority: .background) {
    joined.continuation.yield(())
    await registration.received(token: token)
  }
  for await _ in joined.stream { break }
  replies.continuation.yield(())
  await first.value
  await follower.value
  #expect(!registration.status(profile).registered)
  #expect(registration.status(profile).error?.contains("coordinator") == true)
}

/// Each coordinator's channel carries only its own installation ID, and one opt-out
/// reaches every connected coordinator.
@Test @MainActor
func notificationChannelsKeepInstallationsApartAndOptOutReachesEveryChannel() async {
  let work = ProfileID()
  let personal = ProfileID()
  let log = ChannelLog()
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  for profile in [work, personal] {
    await registration.connect(
      NotificationChannel(installation: profile) { request in
        await log.record(request, on: profile)
        if case .unregister = request { return .init(configured: true, registered: false) }
        return .init(configured: true, registered: true)
      })
  }
  let token = String(repeating: "ab", count: 32)
  await registration.received(token: token)
  #expect(registration.status(work).registered && registration.status(personal).registered)
  await registration.setEnabled(false)
  for profile in [work, personal] {
    #expect(
      log.sent[profile] == [
        .status(.init(installationId: "\(profile)")),
        .register(.init(installationId: "\(profile)", token: token)),
        .unregister(.init(installationId: "\(profile)")),
      ])
    #expect(!registration.status(profile).registered)
  }
}

/// Remove withdraws a coordinator's alerts while its connect still waits for the status
/// answer. That connect must not enroll after the withdrawal.
@Test(.timeLimit(.minutes(1))) @MainActor
func notificationForgetDuringAnInflightConnectEnrollsNothingAfterIt() async throws {
  let profile = ProfileID()
  let coordinator = HeldControls()
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.received(token: String(repeating: "ab", count: 32))
  await coordinator.hold()
  let connect = Task {
    await registration.connect(
      NotificationChannel(installation: profile) { await coordinator.exchange($0) })
  }
  while await coordinator.sent.isEmpty { await Task.yield() }
  let release = Task { await coordinator.open() }
  await registration.forget(profile)
  await release.value
  await connect.value
  let sent = await coordinator.sent
  let registered = await coordinator.registered
  let installation = "\(profile)"
  #expect(
    sent == [
      .status(.init(installationId: installation)),
      .unregister(.init(installationId: installation)),
    ])
  #expect(!registered)
}

/// A device token that arrives while Remove's withdrawal is out must not enroll either.
@Test(.timeLimit(.minutes(1))) @MainActor
func notificationATokenDuringForgetEnrollsNothingAfterIt() async throws {
  let profile = ProfileID()
  let coordinator = HeldControls()
  let registration = NotificationRegistration(
    enabled: true, permission: { true }, register: {}, save: { _ in })
  await registration.connect(
    NotificationChannel(installation: profile) { await coordinator.exchange($0) })
  await coordinator.hold()
  let forget = Task { await registration.forget(profile) }
  while await coordinator.sent.count < 2 { await Task.yield() }
  let release = Task { await coordinator.open() }
  await registration.received(token: String(repeating: "ab", count: 32))
  await release.value
  await forget.value
  let sent = await coordinator.sent
  let registered = await coordinator.registered
  let installation = "\(profile)"
  #expect(
    sent == [
      .status(.init(installationId: installation)),
      .unregister(.init(installationId: installation)),
    ])
  #expect(!registered)
}

/// `ChatModel` starts each lane's connect untracked, so one can begin after Remove's withdrawal
/// finished. It must enroll nothing.
@Test(.timeLimit(.minutes(1))) @MainActor
func notificationAConnectStartingAfterForgetEnrollsNothing() async {
  var violations = 0
  for _ in 0..<10 {
    let profile = ProfileID()
    let coordinator = HeldControls()
    let registration = NotificationRegistration(
      enabled: true, permission: { true }, register: {}, save: { _ in })
    await registration.received(token: String(repeating: "ab", count: 32))
    let connect = Task {
      await registration.connect(
        NotificationChannel(installation: profile) { await coordinator.exchange($0) })
    }
    await registration.forget(profile)
    await connect.value
    if await coordinator.sent.contains(where: { if case .register = $0 { true } else { false } }) {
      violations += 1
    }
    #expect(!registration.status(profile).registered)
  }
  #expect(violations == 0, "A connect after forget registered in \(violations) of 10 runs")
}

/// One coordinator's notification controls. After `hold`, the next request waits for `open`.
private actor HeldControls {
  private(set) var sent: [NotificationRequest] = []
  private(set) var registered = false
  private var holding = false
  private var release: CheckedContinuation<Void, Never>?
  func hold() { holding = true }
  func open() {
    release?.resume()
    release = nil
  }
  func exchange(_ request: NotificationRequest) async -> NotificationStatus {
    sent.append(request)
    if holding {
      holding = false
      await withCheckedContinuation { release = $0 }
    }
    if case .register = request { registered = true }
    if case .unregister = request { registered = false }
    return .init(configured: true, registered: registered)
  }
}

@MainActor
private final class ChannelLog {
  var sent: [ProfileID: [NotificationRequest]] = [:]
  func record(_ request: NotificationRequest, on profile: ProfileID) {
    sent[profile, default: []].append(request)
  }
}

@MainActor
private final class NotificationProbe {
  var permissions = 0
  var registrations = 0
  var saved: [Bool] = []
}
