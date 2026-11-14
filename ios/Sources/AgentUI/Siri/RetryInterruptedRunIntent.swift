import AgentCore
import AppIntents

public struct RetryInterruptedRunIntent: AppIntent {
  public static let title: LocalizedStringResource = "Retry Interrupted Run"
  public static let description = IntentDescription(
    "Retries a scheduled job's run that paused after repeated interrupted restarts. It does not start another scheduled run."
  )
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(
    title: "Job", description: "The scheduled job whose interrupted run to retry.")
  public var job: JobEntity

  @Dependency private var notifications: AppNotifications

  public init() {}

  /// For tests, which run outside the perform flow that resolves `@Dependency`.
  init(job: JobEntity, notifications: AppNotifications) {
    self.job = job
    self.notifications = notifications
  }

  @MainActor public func perform() async throws -> some IntentResult & ProvidesDialog {
    let retried = try await notifications.coordinators.retryInterruptedRun(job.id, title: job.title)
    return .result(dialog: "Retrying the interrupted run of \(retried.job.title).")
  }
}

extension Coordinators {
  /// Reads the job again before the retry, so a run that recovered since the entity was read
  /// is refused by the same rule the job screen uses.
  func retryInterruptedRun(_ id: ScopedEntityID, title: String) async throws
    -> ScheduledJobStatus
  {
    try await withConnection(to: id.profile) {
      guard case .detail(let detail) = try await chat.jobs(id.item, lane: id.profile),
        detail.job.canRetryInterruptedRun
      else { throw NoInterruptedRun(title: title) }
      return try await chat.retryJob(id.item, lane: id.profile)
    }
  }
}

/// A job whose last run is not parked at the restart limit, so there is nothing to retry.
public struct NoInterruptedRun: Error, CustomLocalizedStringResourceConvertible {
  public let title: String
  public var localizedStringResource: LocalizedStringResource {
    "\(title) has no interrupted run to retry."
  }
}
