import AppIntents

public struct OpenJobIntent: OpenIntent {
  public static let title: LocalizedStringResource = "Open Job"
  public static let description = IntentDescription(
    "Shows a scheduled job in Beep Boop, with its last run and its conversation. The draft in the composer and the feed stay as they are."
  )

  /// The system resolves the job through `JobQuery` before `perform()` runs, so a job that is gone
  /// fails there with `JobUnavailable`.
  @Parameter(title: "Job", description: "The scheduled job to show.")
  public var target: JobEntity

  @Dependency private var notifications: AppNotifications

  public init() {}

  @MainActor public func perform() async throws -> some IntentResult {
    try notifications.receiver().open(target)
    return .result()
  }
}
