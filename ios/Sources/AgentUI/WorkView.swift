import AgentCore
import SwiftUI

/// When a page of Jobs and work reads again: on Refresh, and each time its coordinator becomes
/// ready, as after a reconnect or on a new session.
struct WorkReload: Equatable {
  let refresh: UUID
  let ready: Bool
}

extension ChatModel {
  /// True while `lane` is connected and advertises Jobs and work.
  fileprivate func workReady(_ lane: ProfileID) -> Bool {
    snapshots[lane].map { $0.workInspectionSupported && $0.connection == .connected } ?? false
  }
}

struct WorkView: View {
  let model: ChatModel
  let lane: ProfileID
  @State private var jobs: [ScheduledJobStatus] = []
  @State private var conversations: [SavedConversation] = []
  @State private var cursor: String?
  @State private var query = ""
  @State private var appliedQuery = ""
  @State private var error: String?
  @State private var loaded = false
  @State private var busy = false
  @State private var refresh = UUID()
  @State private var more = 0
  @State private var request = UUID()
  @State private var inspection: WorkInspection?

  var body: some View {
    List {
      if let error { WorkDiagnosticText(error, identifier: "workReadError") }
      if !model.workReady(lane) { WorkNotConnected(model: model, lane: lane) }
      if loaded {
        WorkCatalogSections(model: model, lane: lane, jobs: jobs, conversations: conversations) {
          inspection = .init($0)
        }
        if cursor != nil {
          Button("Load more saved conversations") { more += 1 }
            .disabled(busy).accessibilityIdentifier("loadMoreWork")
        }
      } else if model.workReady(lane) {
        ProgressView("Reading jobs and saved work")
      }
    }
    .navigationTitle(model.laneTitle("Jobs and work", for: lane))
    .searchable(text: $query, prompt: "Saved conversation title or ID")
    .onSubmit(of: .search) { refresh = UUID() }
    .onChange(of: query) { _, value in if value.isEmpty { refresh = UUID() } }
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { refresh = UUID() }
          .disabled(busy).accessibilityIdentifier("refreshWork")
      }
    }
    .task(id: WorkReload(refresh: refresh, ready: model.workReady(lane))) { await reload() }
    .task(id: more) { if more > 0 { await loadMore() } }
    .refreshable { await reload() }
    .sheet(item: $inspection) {
      ConversationInspectionView(owner: model, lane: lane, initial: $0.conversation)
    }
    .accessibilityIdentifier("workCatalog")
  }

  private func reload() async {
    guard model.workReady(lane) else { return }
    let id = UUID()
    let search = query
    request = id
    busy = true
    error = nil
    defer { if request == id { busy = false } }
    do {
      guard case .list(let listing) = try await model.jobs(lane: lane) else {
        throw ConnectionError.incompleteFrame
      }
      guard request == id, !Task.isCancelled else { return }
      jobs = listing.jobs
      let page = try await model.conversations(query: search, lane: lane)
      guard request == id, !Task.isCancelled else { return }
      conversations = page.items
      cursor = page.nextCursor
      appliedQuery = search
      loaded = true
    } catch LaneError.interrupted {
      // WorkReload reads again once the coordinator is ready, so an interrupted read stays quiet.
      return
    } catch {
      guard request == id, !Task.isCancelled else { return }
      loaded = true
      self.error = error.localizedDescription
    }
  }

  private func loadMore() async {
    guard let cursor, !busy, model.workReady(lane) else { return }
    let id = request
    busy = true
    defer { if request == id { busy = false } }
    do {
      let page = try await model.conversations(query: appliedQuery, cursor: cursor, lane: lane)
      guard request == id, !Task.isCancelled else { return }
      let known = Set(conversations.map(\.conversationId))
      conversations.append(contentsOf: page.items.filter { !known.contains($0.conversationId) })
      self.cursor = page.nextCursor
    } catch LaneError.interrupted {
      return
    } catch {
      if request == id, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}

private struct WorkNotConnected: View {
  let model: ChatModel
  let lane: ProfileID

  var body: some View {
    let name = model.multiple ? model.name(lane) : "the coordinator"
    Text("Not connected. This page reads again when \(name) reconnects.")
      .font(.footnote).foregroundStyle(.secondary)
  }
}

struct WorkCatalogSections: View {
  let model: ChatModel
  let lane: ProfileID
  let jobs: [ScheduledJobStatus]
  let conversations: [SavedConversation]
  let inspect: (SavedConversation) -> Void

  var body: some View {
    Section("Scheduled jobs") {
      if jobs.isEmpty { Text("No applied scheduled jobs.").foregroundStyle(.secondary) }
      ForEach(jobs, id: \.job.id) { status in
        NavigationLink {
          JobDetailView(jobID: status.job.id, model: model, lane: lane)
        } label: {
          VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: status.job.title).font(.headline)
            Text(verbatim: status.job.id).font(.caption).foregroundStyle(.secondary)
            if status.schedules.contains(where: { $0.error != nil }) {
              Label("Needs attention", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
            }
            HStack {
              Text("Next").foregroundStyle(.secondary)
              WorkTime(status.schedules.compactMap(\.nextAt).min())
            }
            .font(.caption)
          }
        }.accessibilityIdentifier("job-\(status.job.id)")
      }
    }
    Section("Saved and live conversations") {
      if conversations.isEmpty { Text("No matching saved work.").foregroundStyle(.secondary) }
      ForEach(conversations, id: \.conversationId) { item in
        Button {
          inspect(item)
        } label: {
          HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.agentId == nil ? "bubble.left.and.bubble.right" : "person.2")
              .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 5) {
              Text(verbatim: item.title).font(.headline).foregroundStyle(.primary)
              Text(
                item.agentId == nil
                  ? "Conversation \(item.conversationId)" : "Sub-agent · \(item.conversationId)"
              )
              .font(.caption).foregroundStyle(.secondary)
              if let host = item.host {
                Text(verbatim: host).font(.caption).foregroundStyle(.secondary)
              }
              if let updated = item.updatedAt {
                WorkTime(updated).font(.caption).foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain).accessibilityIdentifier("work-\(item.conversationId)")
      }
    }
  }

}

struct JobDetailView: View {
  let jobID: String
  let model: ChatModel
  let lane: ProfileID
  @State private var status: ScheduledJobStatus?
  @State private var owner: SavedConversation?
  @State private var error: String?
  @State private var refresh = UUID()
  @State private var retry = 0
  // Reappearing with the same view state must not repeat a previous tap.
  @State private var handledRetry = 0
  @State private var retrying = false
  @State private var request = UUID()
  @State private var inspection: WorkInspection?

  var body: some View {
    Form {
      if let error { WorkDiagnosticText(error, identifier: "jobReadError") }
      if !model.workReady(lane) { WorkNotConnected(model: model, lane: lane) }
      if let status {
        JobDiagnosticSections(status: status)
        if status.canRetryInterruptedRun {
          Section("Recovery") {
            Button("Retry interrupted run", systemImage: "arrow.clockwise") { retry += 1 }
              .disabled(retrying).accessibilityIdentifier("retryInterruptedJob")
            Text(
              model.multiple
                ? "Retries the retained interrupted execution on \(model.name(lane)). It does not start another scheduled run."
                : "Retries the retained interrupted execution. It does not start another scheduled run."
            )
            .font(.footnote).foregroundStyle(.secondary)
          }
        }
        Section("Conversation") {
          if let owner {
            Button("Open \(owner.title)", systemImage: "bubble.left.and.bubble.right") {
              inspection = .init(owner)
            }.accessibilityIdentifier("openJobConversation")
          } else if status.inspectionTaskID == nil {
            Text("An owning conversation has not been recorded for this job.")
              .foregroundStyle(.secondary)
          } else {
            Text("The owning conversation is unavailable. Refresh to check again.")
              .foregroundStyle(.secondary)
          }
        }
      } else if error == nil, model.workReady(lane) {
        ProgressView("Reading job")
      }
    }
    .navigationTitle(status?.job.title ?? "Scheduled job")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { refresh = UUID() }
          .disabled(retrying)
      }
    }
    .task(id: WorkReload(refresh: refresh, ready: model.workReady(lane))) { await load() }
    .task(id: retry) {
      guard retry > handledRetry else { return }
      handledRetry = retry
      await retryInterruptedRun()
    }
    .refreshable { await load() }
    .sheet(item: $inspection) {
      ConversationInspectionView(owner: model, lane: lane, initial: $0.conversation)
    }
    .accessibilityIdentifier("jobDetails")
  }

  private func load() async {
    guard !retrying, model.workReady(lane) else { return }
    let id = UUID()
    request = id
    error = nil
    do {
      guard case .detail(let detail) = try await model.jobs(jobID, lane: lane) else {
        throw ConnectionError.incompleteFrame
      }
      guard request == id, !Task.isCancelled else { return }
      status = detail.job
      owner = nil
      if let taskID = detail.job.inspectionTaskID {
        let page = try await model.conversations(query: taskID, lane: lane)
        guard request == id, !Task.isCancelled else { return }
        owner = page.items.first { $0.taskId == taskID && $0.agentId == nil }
      }
    } catch LaneError.interrupted {
      return
    } catch {
      if request == id, !Task.isCancelled { self.error = error.localizedDescription }
    }
  }

  private func retryInterruptedRun() async {
    guard !retrying, status?.canRetryInterruptedRun == true else { return }
    retrying = true
    error = nil
    defer { retrying = false }
    do {
      let resumed = try await model.retryJob(jobID, lane: lane)
      guard !Task.isCancelled else { return }
      status = resumed
    } catch {
      guard !Task.isCancelled else { return }
      self.error = error.localizedDescription
      // The retry may or may not have run, so the page reads the job again.
      if case LaneError.interrupted = error {
        status = nil
        refresh = UUID()
      }
    }
  }
}

extension ScheduledJobStatus {
  // The displayed output belongs to its run, even if the lane later changes owner.
  var inspectionTaskID: String? { lastRun?.taskId ?? taskId }
  var canRetryInterruptedRun: Bool {
    if let state = lastRun?.state {
      switch state {
      case .blocked(let blocked): return blocked.message == "restart_limit"
      case .queued, .running, .waiting, .retrying: return false
      case .completed, .failed, .stopped: break
      }
    }
    return schedules.contains {
      $0.error?.contains("parked after repeated interrupted restarts") == true
    }
  }
}

struct JobDiagnosticSections: View {
  let status: ScheduledJobStatus

  var body: some View {
    Section("Last run") {
      if let run = status.lastRun {
        LabeledContent("State", value: run.state.workLabel).accessibilityIdentifier("jobRunState")
        LabeledContent("Scheduled") { WorkTime(run.scheduledAt) }
        LabeledContent("Started") { WorkTime(run.startedAt) }
        LabeledContent("Finished") { WorkTime(run.finishedAt) }
        LabeledContent("Schedule", value: run.scheduleId)
        LabeledContent("Run revision") { Text(verbatim: run.revision).textSelection(.enabled) }
        if case .retrying(let retry) = run.state { LabeledContent("Retry") { WorkTime(retry.at) } }
        if let diagnostic = run.state.workDiagnostic {
          WorkDiagnosticText(diagnostic, identifier: "jobRunError")
        }
      } else {
        LabeledContent("Timing", value: "Unknown").accessibilityIdentifier("jobTimingUnknown")
        Text(
          "No retained execution reference exists for this older run. Scheduled admission is shown below."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    }
    Section("Last output") {
      if let run = status.lastRun, let output = run.output {
        if output.isEmpty {
          Text("Empty recorded output.").foregroundStyle(.secondary)
        } else {
          Text(verbatim: output).font(.callout).messageTextSelection()
            .messageTextActions(output).accessibilityIdentifier("jobOutput")
        }
        if run.outputTruncated {
          Text("This output is truncated. Open the owning conversation for its full history.")
            .font(.footnote).foregroundStyle(.secondary)
        }
      } else {
        Text("No completed reply recorded for this run.").foregroundStyle(.secondary)
      }
    }
    ForEach(status.schedules, id: \.scheduleId) { schedule in
      Section("Schedule: \(schedule.scheduleId)") {
        LabeledContent("Next") { WorkTime(schedule.nextAt) }
        LabeledContent("Last admitted") { WorkTime(schedule.lastAt) }
        if let diagnostic = schedule.error {
          WorkDiagnosticText(diagnostic, identifier: "jobScheduleError-\(schedule.scheduleId)")
        }
      }
    }
    Section("Applied configuration") {
      LabeledContent("Job", value: status.job.id)
      LabeledContent("Timezone", value: status.job.timezone)
      Text("Times above use this device’s time zone.").font(.footnote).foregroundStyle(.secondary)
      LabeledContent(
        "Model", value: "\(status.job.model.provider.rawValue)/\(status.job.model.modelId)")
      LabeledContent("Revision") { Text(verbatim: status.job.revision).textSelection(.enabled) }
      DisclosureGroup("Instructions") {
        Text(verbatim: status.job.prompt).font(.callout).messageTextSelection()
          .messageTextActions(status.job.prompt)
      }
    }
  }
}

extension JobExecutionState {
  var workLabel: String {
    switch self {
    case .queued: "Queued"
    case .running: "Running"
    case .waiting: "Waiting"
    case .retrying: "Retrying"
    case .blocked(let blocked): blocked.message == "restart_limit" ? "Parked" : "Blocked"
    case .completed: "Completed"
    case .failed: "Failed"
    case .stopped: "Stopped"
    }
  }
  var workDiagnostic: String? {
    switch self {
    case .retrying(let retry): retry.message
    case .blocked(let blocked):
      blocked.message == "restart_limit"
        ? "This run paused after repeated interrupted restarts. Retry resumes its saved work."
        : blocked.message
    case .failed(let failed): failed.message
    default: nil
    }
  }
}

struct WorkTime: View {
  let milliseconds: Int?
  init(_ milliseconds: Int?) { self.milliseconds = milliseconds }
  var body: some View {
    if let milliseconds {
      Text(
        Date(timeIntervalSince1970: Double(milliseconds) / 1000).formatted(
          date: .abbreviated, time: .standard))
    } else {
      Text("Unknown").foregroundStyle(.secondary)
    }
  }
}

struct WorkDiagnosticText: View {
  let text: String
  let identifier: String
  init(_ text: String, identifier: String) {
    self.text = text
    self.identifier = identifier
  }
  var body: some View {
    Text(verbatim: text).font(.callout).foregroundStyle(.primary).messageTextSelection()
      .messageTextActions(text).accessibilityIdentifier(identifier)
  }
}

private struct WorkInspection: Identifiable {
  let conversation: SavedConversation
  var id: String { conversation.conversationId }
  init(_ conversation: SavedConversation) { self.conversation = conversation }
}

struct ConversationInspectionView: View {
  let owner: ChatModel
  let lane: ProfileID
  @State private var selected: SavedConversation
  init(owner: ChatModel, lane: ProfileID, initial: SavedConversation) {
    self.owner = owner
    self.lane = lane
    _selected = State(initialValue: initial)
  }
  var body: some View {
    InspectionScreen(owner: owner, lane: lane, conversation: selected) { selected = $0 }
      .id(selected.conversationId)
  }
  static func relationships(for conversation: SavedConversation, in items: [SavedConversation])
    -> [SavedConversation]
  {
    guard let taskID = conversation.taskId else { return [] }
    return items.filter { $0.taskId == taskID && $0.conversationId != conversation.conversationId }
      .sorted { ($0.agentId != nil ? 1 : 0, $0.title) < ($1.agentId != nil ? 1 : 0, $1.title) }
  }
}

private struct InspectionScreen: View {
  let owner: ChatModel
  let lane: ProfileID
  let conversation: SavedConversation
  let select: (SavedConversation) -> Void
  @State private var model: ChatModel
  @State private var related: [SavedConversation] = []
  @State private var relationshipError: String?
  init(
    owner: ChatModel, lane: ProfileID, conversation: SavedConversation,
    select: @escaping (SavedConversation) -> Void
  ) {
    self.owner = owner
    self.lane = lane
    self.conversation = conversation
    self.select = select
    _model = State(initialValue: ChatModel(inspecting: conversation))
  }
  var body: some View {
    MainChatView(model: model, relatedWork: related, inspectRelated: select)
      .safeAreaInset(edge: .top) {
        if let relationshipError {
          WorkDiagnosticText(relationshipError, identifier: "workRelationshipError").padding()
        }
      }
      .task {
        await model.connectInspection(using: owner, lane: lane)
        if !Task.isCancelled, let taskID = conversation.taskId {
          do {
            let page = try await owner.conversations(query: taskID, lane: lane)
            related = ConversationInspectionView.relationships(for: conversation, in: page.items)
          } catch {
            if !Task.isCancelled { relationshipError = error.localizedDescription }
          }
        }
        await model.runUntilCancelled()
      }
  }
}
