import AgentCore
import AppIntents
import CoreTransferable
import Foundation
import Network

/// Where a job's last run stands, as Siri and Shortcuts name it.
public enum JobRunState: String, AppEnum {
  case notRun
  case queued
  case running
  case waiting
  case retrying
  case blocked
  case interrupted
  case completed
  case failed
  case stopped

  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Run State"
  public static let caseDisplayRepresentations: [JobRunState: DisplayRepresentation] = [
    .notRun: "Not run yet",
    .queued: "Queued",
    .running: "Running",
    .waiting: "Waiting",
    .retrying: "Retrying",
    .blocked: "Blocked",
    .interrupted: "Interrupted",
    .completed: "Completed",
    .failed: "Failed",
    .stopped: "Stopped",
  ]
}

extension ScheduledJobStatus {
  /// Interrupted exactly when the retry intent would retry the job, by the job screen's rule.
  /// Otherwise where the last run stands.
  var runState: JobRunState {
    if canRetryInterruptedRun { return .interrupted }
    guard let state = lastRun?.state else { return .notRun }
    return switch state {
    case .queued: .queued
    case .running: .running
    case .waiting: .waiting
    case .retrying: .retrying
    case .blocked: .blocked
    case .completed: .completed
    case .failed: .failed
    case .stopped: .stopped
    }
  }
}

/// A coordinator's scheduled job as Siri and Shortcuts see it. It leaves out the prompt, the
/// working directory and the run output.
public struct JobEntity: AppEntity {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Scheduled Job"
  public static let defaultQuery = JobQuery()

  public let id: ScopedEntityID
  @Property(title: "Title") public var title: String
  @Property(title: "Coordinator") public var coordinator: String
  @Property(title: "Schedule") public var schedule: String
  @Property(title: "State") public var state: JobRunState
  @Property(title: "Last Run") public var lastRun: Date?
  @Property(title: "Next Run") public var nextRun: Date?

  init(_ status: ScheduledJobStatus, on profile: ProfileID, coordinator: String) {
    id = ScopedEntityID(profile: profile, item: status.job.id)
    title = status.job.title
    self.coordinator = coordinator
    schedule = status.job.schedules.map(\.recurrence).joined(separator: "; ")
    state = status.runState
    lastRun = (status.lastRun.map { $0.startedAt ?? $0.scheduledAt }).map(Self.date)
    nextRun = status.schedules.compactMap(\.nextAt).min().map(Self.date)
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(title)", subtitle: "\(coordinator)")
  }

  private static func date(_ millis: UtcMillis) -> Date {
    Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
  }
}

/// The scheduled jobs of each paired coordinator, read over a held connection.
public struct JobQuery: EnumerableEntityQuery {
  @Dependency private var notifications: AppNotifications

  public init() {}

  public func allEntities() async throws -> [JobEntity] {
    try await Self.allJobs(for: notifications)
  }

  public func entities(for identifiers: [ScopedEntityID]) async throws -> [JobEntity] {
    try await Self.jobs(identifiedBy: identifiers, for: notifications)
  }

  /// The query's answer for the app's `notifications`. It reads the coordinators an intent may
  /// reach, so a launch without the interaction fixture it asked for is refused before any lease.
  @MainActor static func allJobs(for notifications: AppNotifications) async throws -> [JobEntity] {
    try await allJobs(in: notifications.intentCoordinators)
  }

  @MainActor static func jobs(
    identifiedBy identifiers: [ScopedEntityID], for notifications: AppNotifications
  ) async throws -> [JobEntity] {
    try await jobs(identifiedBy: identifiers, in: notifications.intentCoordinators)
  }

  /// Every paired coordinator's jobs, in saved order.
  @MainActor static func allJobs(
    in coordinators: Coordinators, within limit: Duration = ConnectionLease.connectionWait
  ) async throws -> [JobEntity] {
    let reads = await coordinators.jobs(
      of: coordinators.profiles.filter { $0.pin != nil }, within: limit)
    try Task.checkCancellation()
    return try jobs(in: reads)
  }

  /// Every job in `reads`. With none to show, a failure other than silence is thrown first, and a
  /// silence only when no coordinator answered at all.
  static func jobs(in reads: [JobRead]) throws -> [JobEntity] {
    let answers = reads.compactMap { try? $0.get() }
    let jobs = answers.flatMap { $0 }
    guard jobs.isEmpty, let failure = failure(in: reads) else { return jobs }
    if failure is CoordinatorDidNotAnswer, !answers.isEmpty { return [] }
    throw failure
  }

  @MainActor static func jobs(
    identifiedBy identifiers: [ScopedEntityID], in coordinators: Coordinators,
    within limit: Duration = ConnectionLease.connectionWait
  ) async throws -> [JobEntity] {
    let owners = Set(identifiers.map(\.profile))
    let reads = await coordinators.jobs(
      of: coordinators.profiles.filter { owners.contains($0.id) }, within: limit)
    try Task.checkCancellation()
    if let failure = failure(in: reads) { throw failure }
    return reads.flatMap { (try? $0.get()) ?? [] }.filter { identifiers.contains($0.id) }
  }

  /// The failure to report for `reads`: any other failure before a coordinator's silence.
  private static func failure(in reads: [JobRead]) -> (any Error)? {
    let failures = reads.compactMap { read -> (any Error)? in
      if case .failure(let error) = read { error } else { nil }
    }
    return failures.first { !($0 is CoordinatorDidNotAnswer) } ?? failures.first
  }
}

typealias JobRead = Result<[JobEntity], any Error>

/// A coordinator that never connected for the intent, or whose connection closed or timed out
/// under its request.
public struct CoordinatorDidNotAnswer: Error, CustomLocalizedStringResourceConvertible {
  public let name: String
  public var localizedStringResource: LocalizedStringResource {
    "\(name) did not answer. Check that it is running and reachable."
  }
}

/// A coordinator's own refusal of an intent's request, in its words under its name.
public struct CoordinatorRefused: Error, CustomLocalizedStringResourceConvertible {
  public let name: String
  public let message: String
  public var localizedStringResource: LocalizedStringResource { "\(name): \(message)" }
}

extension Coordinators {
  /// How reading each of `profiles`' jobs went, in the order given. They are read at the same
  /// time, each over its own lease, so one that is slow to connect delays no other.
  func jobs(of profiles: [CoordinatorProfile], within limit: Duration) async -> [JobRead] {
    await withTaskGroup(of: (ProfileID, JobRead).self) { group in
      for profile in profiles {
        group.addTask { (profile.id, await self.read(profile, within: limit)) }
      }
      var reads: [ProfileID: JobRead] = [:]
      for await (id, read) in group { reads[id] = read }
      return profiles.compactMap { reads[$0.id] }
    }
  }

  private func read(_ profile: CoordinatorProfile, within limit: Duration) async -> JobRead {
    let name = "\(profile.name)"
    do {
      return .success(
        try await withConnection(to: profile.id, within: limit) {
          guard case .list(let list) = try await chat.jobs(lane: profile.id) else { return [] }
          return list.jobs.map { JobEntity($0, on: profile.id, coordinator: name) }
        })
    } catch let rejection as CoordinatorRejection {
      return .failure(CoordinatorRefused(name: name, message: rejection.message))
    } catch LaneError.unanswered, LaneError.interrupted, ConnectionError.closed,
      ConnectionError.timedOut, is NWError
    {
      return .failure(CoordinatorDidNotAnswer(name: name))
    } catch {
      return .failure(error)
    }
  }
}

extension JobEntity: Transferable {
  /// One plain-text line, such as "Nightly deps, Work, Interrupted".
  public static var transferRepresentation: some TransferRepresentation {
    ProxyRepresentation(exporting: \.summary)
  }

  var summary: String {
    let state = JobRunState.caseDisplayRepresentations[state].map { String(localized: $0.title) }
    return "\(title), \(coordinator), \(state ?? self.state.rawValue)"
  }
}
