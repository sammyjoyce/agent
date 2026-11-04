import Foundation
import Observation

/// One coordinator's enrollment channel. The app gets one only from
/// `CoordinatorSession.notificationChannel`, so a profile's installation ID travels only over
/// that profile's identity-checked sockets.
public struct NotificationChannel: Sendable {
  public let installation: ProfileID
  let exchange: @Sendable (NotificationRequest) async throws -> NotificationStatus
}

/// Device enrollment uses control requests, never model input. Tokens stay in memory.
/// The alerts toggle, permission and Apple registration belong to the app. Each saved
/// coordinator has its own channel, keyed by the profile ID that is its installation ID.
@MainActor @Observable
public final class NotificationRegistration {
  public private(set) var enabled: Bool
  public private(set) var busy = false
  /// Permission and Apple registration failures. Coordinator failures are per channel.
  public private(set) var error: String?
  public struct ChannelStatus: Sendable, Equatable {
    public var configured = false
    public var registered = false
    public var error: String?
  }
  private var channels: [ProfileID: ChannelStatus] = [:]
  private enum Authorization { case unchecked, allowed, denied }
  private enum AppleRegistration { case idle, requested, ready, failed }
  private struct Enrollment {
    let id: UUID
    let token: String
    let operation: Task<Void, any Error>
  }
  /// Present while that profile's session is connected. Replacing it invalidates its work.
  private struct Link {
    let channel: NotificationChannel
    let generation = UUID()
    var enrollment: Enrollment?
  }
  @ObservationIgnored private var links: [ProfileID: Link] = [:]
  /// Profiles whose installation Remove withdrew. Profile IDs are never reused, so none of
  /// these connects or enrolls again.
  @ObservationIgnored private var forgotten: Set<ProfileID> = []
  /// Outlives links, so a request from an earlier connection still orders before later ones.
  @ObservationIgnored private var controls: [ProfileID: Task<NotificationStatus, any Error>] = [:]
  @ObservationIgnored private var authorization = Authorization.unchecked
  @ObservationIgnored private var apple = AppleRegistration.idle
  @ObservationIgnored private var token: String?
  @ObservationIgnored private let permission: @MainActor () async throws -> Bool
  @ObservationIgnored private let register: @MainActor () -> Void
  @ObservationIgnored private let save: @MainActor (Bool) -> Void

  public init(
    enabled: Bool,
    permission: @escaping @MainActor () async throws -> Bool,
    register: @escaping @MainActor () -> Void,
    save: @escaping @MainActor (Bool) -> Void
  ) {
    self.enabled = enabled
    self.permission = permission
    self.register = register
    self.save = save
  }

  public func status(_ profile: ProfileID) -> ChannelStatus { channels[profile] ?? ChannelStatus() }

  public func start() async {
    guard enabled, authorization == .unchecked else { return }
    await setEnabled(true)
  }

  /// Keeps the last known `registered`, so a later opt-out can report an unconfirmed removal.
  public func disconnect(_ profile: ProfileID) {
    links[profile] = nil
    channels[profile]?.configured = false
  }

  public func connect(_ channel: NotificationChannel) async {
    let profile = channel.installation
    guard !forgotten.contains(profile) else { return }
    let link = Link(channel: channel)
    links[profile] = link
    channels[profile, default: ChannelStatus()].configured = false
    do {
      let status = try await request(.status(.init(installationId: "\(profile)")), on: profile)
        .value
      guard current(profile, link) else { return }
      channels[profile] = ChannelStatus(
        configured: status.configured, registered: status.registered)
      if enabled {
        await start()
        guard current(profile, link) else { return }
        if enabled, authorization == .allowed, status.configured {
          registerWithApple()
          if let token { try await enroll(token, on: profile, link: link) }
        }
      } else if status.registered {
        // A lost withdrawal receipt must not silently re-enable alerts after
        // relaunch. Removing the same installation again is idempotent.
        try await unregister(profile)
      }
    } catch {
      guard current(profile, link) else { return }
      channels[profile]?.error =
        enabled || !status(profile).registered
        ? error.localizedDescription : removalError(error)
    }
  }

  /// Enrolls or withdraws on every channel.
  public func setEnabled(_ value: Bool) async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      if value {
        // Authorization belongs to the installation, not a connection that may
        // reconnect while Apple's first-launch prompt is open.
        let allowed = try await permission()
        authorization = allowed ? .allowed : .denied
        guard allowed else {
          await withdraw()
          throw RegistrationError.permission
        }
        enabled = true
        save(true)
        registerWithApple()
        if let token { await enrollLinked(token) }
      } else {
        await withdraw()
      }
      error = nil
    } catch {
      self.error = error.localizedDescription
    }
  }

  /// Removes the profile's installation over its live channel, if any, then forgets it. True
  /// once its coordinator confirmed it holds no registration for it.
  @discardableResult public func forget(_ profile: ProfileID) async -> Bool {
    forgotten.insert(profile)
    // Without a configured status, a token arriving during the withdrawal skips this profile.
    channels[profile] = nil
    defer {
      links[profile] = nil
      controls[profile] = nil
    }
    let withdrawal = try? await request(
      .unregister(.init(installationId: "\(profile)")), on: profile
    ).value
    return withdrawal?.registered == false
  }

  public func received(token: String) async {
    self.token = token
    apple = .ready
    guard enabled, authorization == .allowed else { return }
    await enrollLinked(token)
  }

  public func failed() {
    apple = .failed
    // A late OS callback cannot confirm an earlier coordinator withdrawal.
    guard enabled else { return }
    error =
      "This device could not register with Apple. Check the app's Push Notifications signing capability and network connection."
  }

  private func registerWithApple() {
    guard apple == .idle || apple == .failed else { return }
    apple = .requested
    register()
  }

  private func current(_ profile: ProfileID, _ link: Link) -> Bool {
    !forgotten.contains(profile) && links[profile]?.generation == link.generation
  }

  private func enrollLinked(_ token: String) async {
    for (profile, link) in links where status(profile).configured {
      do {
        try await enroll(token, on: profile, link: link)
        if current(profile, link) { channels[profile]?.error = nil }
      } catch {
        if current(profile, link) { channels[profile]?.error = error.localizedDescription }
      }
    }
  }

  private func withdraw() async {
    // Persist intent before a receipt: late token callbacks cannot re-enroll.
    enabled = false
    save(false)
    for profile in Array(channels.keys) {
      links[profile]?.enrollment = nil
      do {
        try await unregister(profile)
        channels[profile]?.error = nil
      } catch {
        channels[profile]?.error = removalError(error)
      }
    }
  }

  private func unregister(_ profile: ProfileID) async throws {
    guard let link = links[profile] else {
      if status(profile).registered { throw ConnectionError.closed }
      return
    }
    let status = try await request(.unregister(.init(installationId: "\(profile)")), on: profile)
      .value
    guard current(profile, link) else { return }
    channels[profile]?.registered = status.registered
  }

  private func enroll(_ token: String, on profile: ProfileID, link: Link) async throws {
    let pending: Enrollment
    if let current = links[profile]?.enrollment, self.current(profile, link),
      current.token == token
    {
      pending = current
    } else {
      let id = UUID()
      let response = try request(
        .register(.init(installationId: "\(profile)", token: token)), on: profile)
      let operation = Task { [weak self] in
        let status = try await response.value
        guard let self, self.current(profile, link), self.links[profile]?.enrollment?.id == id
        else { return }
        self.channels[profile]?.registered = status.registered
        if !status.registered { throw RegistrationError.coordinatorSetup }
      }
      pending = Enrollment(id: id, token: token, operation: operation)
      links[profile]?.enrollment = pending
    }
    do {
      try await pending.operation.value
    } catch {
      if links[profile]?.enrollment?.id == pending.id { links[profile]?.enrollment = nil }
      throw error
    }
  }

  private func request(_ request: NotificationRequest, on profile: ProfileID) throws -> Task<
    NotificationStatus, any Error
  > {
    guard let link = links[profile] else { throw ConnectionError.closed }
    let previous = controls[profile]
    let exchange = link.channel.exchange
    // Serialize enrollment and withdrawal. A late token registration cannot
    // overtake a user's disable request on another control connection.
    let operation = Task {
      _ = try? await previous?.value
      return try await exchange(request)
    }
    controls[profile] = operation
    return operation
  }

  private func removalError(_ error: any Error) -> String {
    "Notification removal is unconfirmed. Reconnect or retry removing this device. \(error.localizedDescription)"
  }
}

/// An alert installation a coordinator may hold for this device: a saved profile's ID, or the one
/// the single-address build registered.
public struct InstallationID: Hashable, Sendable, Codable, CustomStringConvertible {
  let uuid: UUID
  public init(_ profile: ProfileID) { uuid = profile.uuid }
  /// The single-address build's `notificationInstallationID`, when it is a UUID.
  public init?(legacy value: String) {
    guard let uuid = UUID(uuidString: value) else { return nil }
    self.uuid = uuid
  }
  public init(from decoder: any Decoder) throws {
    uuid = try decoder.singleValueContainer().decode(UUID.self)
  }
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(uuid)
  }
  public var description: String { uuid.uuidString }
}

/// An alert withdrawal saved before it is sent: Remove's, or the single-address build's once the
/// profile migrated from it pairs. It outlives the profile, so it keeps the address and pin that
/// reach that coordinator alone.
public struct PendingWithdrawal: Codable, Sendable, Equatable {
  public let installation: InstallationID
  public let address: CoordinatorAddress
  public let pin: CoordinatorID

  public init(installation: InstallationID, address: CoordinatorAddress, pin: CoordinatorID) {
    self.installation = installation
    self.address = address
    self.pin = pin
  }

  /// Withdraws the installation over one socket to `address` that proves the pin. True once the
  /// coordinator confirmed it holds no registration for it.
  public func send(to address: CoordinatorAddress, transport: CoordinatorTransport) async throws
    -> Bool
  {
    let stream = try await CoordinatorDialer(address: address, pin: pin, transport: transport)
      .open()
    do {
      try await timedSend(
        stream,
        .notifications(.init(request: .unregister(.init(installationId: "\(installation)")))))
      let status = try await notificationStatus(on: stream)
      await stream.close()
      return !status.registered
    } catch {
      await stream.close()
      throw error
    }
  }
}

private enum RegistrationError: LocalizedError {
  case coordinatorSetup, permission
  var errorDescription: String? {
    switch self {
    case .coordinatorSetup:
      "Notifications are not configured on the coordinator. Complete the APNs setup to receive alerts."
    case .permission: "Allow Agent notifications in iPhone Settings to receive alerts."
    }
  }
}
