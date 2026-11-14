import AgentCore
import AppIntents
import CoreTransferable
import Foundation

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

  init(_ state: JobExecutionState?) {
    guard let state else {
      self = .notRun
      return
    }
    switch state {
    case .queued: self = .queued
    case .running: self = .running
    case .waiting: self = .waiting
    case .retrying: self = .retrying
    case .blocked(let blocked): self = blocked.message == "restart_limit" ? .interrupted : .blocked
    case .completed: self = .completed
    case .failed: self = .failed
    case .stopped: self = .stopped
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
    state = JobRunState(status.lastRun?.state)
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
    try await Self.allJobs(in: notifications.coordinators)
  }

  public func entities(for identifiers: [ScopedEntityID]) async throws -> [JobEntity] {
    try await Self.jobs(identifiedBy: identifiers, in: notifications.coordinators)
  }

  @MainActor static func allJobs(in coordinators: Coordinators) async throws
    -> [JobEntity]
  {
    let profiles = coordinators.profiles.filter { $0.pin != nil }
    var jobs: [JobEntity] = []
    var silent: [String] = []
    for profile in profiles {
      do {
        jobs += try await coordinators.jobs(on: profile.id, coordinator: "\(profile.name)")
      } catch {
        silent.append("\(profile.name)")
      }
    }
    if jobs.isEmpty, let first = silent.first, silent.count == profiles.count {
      throw CoordinatorDidNotAnswer(name: first)
    }
    return jobs
  }

  @MainActor static func jobs(
    identifiedBy identifiers: [ScopedEntityID], in coordinators: Coordinators
  ) async throws -> [JobEntity] {
    let profiles = coordinators.profiles
    var jobs: [JobEntity] = []
    for profileID in Set(identifiers.map(\.profile)) {
      guard let profile = profiles.first(where: { $0.id == profileID }) else { continue }
      do {
        jobs += try await coordinators.jobs(on: profile.id, coordinator: "\(profile.name)")
          .filter { identifiers.contains($0.id) }
      } catch {
        throw CoordinatorDidNotAnswer(name: "\(profile.name)")
      }
    }
    return jobs
  }
}

/// A coordinator that did not return its jobs while the intent held it connected.
public struct CoordinatorDidNotAnswer: Error, CustomLocalizedStringResourceConvertible {
  public let name: String
  public var localizedStringResource: LocalizedStringResource {
    "\(name) did not answer. Check that it is running and reachable."
  }
}

extension Coordinators {
  func jobs(on profile: ProfileID, coordinator: String) async throws -> [JobEntity] {
    try await withConnection(to: profile) {
      guard case .list(let list) = try await chat.jobs(lane: profile) else { return [] }
      return list.jobs.map { JobEntity($0, on: profile, coordinator: coordinator) }
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
