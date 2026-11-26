import AgentCore
import SwiftUI

struct ActiveWorkRow: Identifiable, Equatable, Sendable {
  let id: String
  let lane: ProfileID
  let laneEpoch: Int
  let laneName: String
  let item: ActiveWorkItem

  var inspectionTarget: SavedConversation {
    SavedConversation(
      agentId: nil, conversationId: item.conversationId, host: item.host, sourceThreadId: nil,
      taskId: item.taskId, title: item.title, updatedAt: item.startedAt)
  }

  func childInspectionTarget(_ child: ActiveWorkChild) -> SavedConversation {
    SavedConversation(
      agentId: child.agentId, conversationId: child.conversationId, host: child.host,
      sourceThreadId: nil, taskId: item.taskId, title: child.title, updatedAt: item.startedAt)
  }

  func responseTarget(for child: ActiveWorkChild? = nil) -> WorkResponseTarget? {
    guard (child?.status ?? item.status) == .waitingOwner else { return nil }
    return WorkResponseTarget(
      reference: WorkResponseReference(
        lane: lane, coordinator: laneName, itemID: item.id,
        conversationID: child?.conversationId ?? item.conversationId, taskID: item.taskId,
        agentID: child?.agentId, sidechatSlug: item.sidechatSlug, isJob: item.isJob,
        title: child?.title ?? item.title, detail: child == nil ? item.detail : child?.detail),
      laneEpoch: laneEpoch)
  }
}

struct ActiveWorkSummary: Equatable, Sendable {
  let omittedCount: Int
  let items: [ActiveWorkRow]

  static let empty = ActiveWorkSummary(omittedCount: 0, items: [])

  var runningCount: Int { items.count { $0.item.status == .running } }
  var waitingOwnerCount: Int { items.count { $0.item.status == .waitingOwner } }
  var waitingExternalCount: Int { items.count { $0.item.status == .waitingExternal } }

  var isEmpty: Bool {
    items.isEmpty && omittedCount == 0
  }

  var stripText: String {
    var parts: [String] = []
    if runningCount > 0 { parts.append("\(runningCount) running") }
    if waitingOwnerCount > 0 { parts.append("\(waitingOwnerCount) needs you") }
    if waitingExternalCount > 0 { parts.append("\(waitingExternalCount) waiting") }
    if omittedCount > 0 { parts.append("+\(omittedCount) more") }
    return parts.joined(separator: " · ")
  }

  var runningItems: [ActiveWorkRow] { items.filter { $0.item.status == .running } }
  var waitingItems: [ActiveWorkRow] { items.filter { $0.item.status != .running } }
}

private struct ActiveWorkInspectionTarget: Identifiable {
  let id = UUID()
  let lane: ProfileID
  let conversation: SavedConversation
}

struct ActiveWorkStrip: View {
  let summary: ActiveWorkSummary
  let action: () -> Void

  private var dotColor: Color {
    if summary.waitingOwnerCount > 0 { return .orange }
    if summary.runningCount > 0 { return .green }
    return .secondary
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Circle()
          .fill(dotColor)
          .frame(width: 8, height: 8)
        Text(summary.stripText)
          .font(.footnote.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .background(.background, ignoresSafeAreaEdges: [])
    }
    .buttonStyle(.plain)
    .overlay(alignment: .bottom) { Divider() }
    .accessibilityIdentifier("activeWorkStrip")
  }
}

extension ActiveWorkStatus {
  var tintColor: Color {
    switch self {
    case .running: .green
    case .waitingOwner: .orange
    case .waitingExternal: .secondary
    }
  }
}

struct ActiveWorkSheet: View {
  let model: ChatModel
  var openSidechat: ((ProfileID, String) -> Void)? = nil
  let respond: (WorkResponseTarget) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var inspection: ActiveWorkInspectionTarget?

  var body: some View {
    let summary = model.activeWorkSummary
    let runningItems = summary.runningItems
    let waitingItems = summary.waitingItems
    NavigationStack {
      List {
        if summary.isEmpty {
          ContentUnavailableView(
            "No active work",
            systemImage: "checklist",
            description: Text(
              "Running and waiting tasks across connected coordinators appear here."))
        } else {
          if !runningItems.isEmpty {
            Section("Running") {
              ForEach(runningItems) { row in
                rowButtons(row)
              }
            }
          }
          if !waitingItems.isEmpty {
            Section("Waiting") {
              ForEach(waitingItems) { row in
                rowButtons(row)
              }
            }
          }
          if summary.omittedCount > 0 {
            Section {
              Text(
                "\(summary.omittedCount) older nested tasks omitted by the coordinator graph limit."
              )
              .font(.footnote)
              .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Active work")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
      .accessibilityIdentifier("activeWorkSheet")
    }
    .sheet(item: $inspection) { target in
      ConversationInspectionView(owner: model, lane: target.lane, initial: target.conversation)
    }
  }

  private func rowButtons(_ row: ActiveWorkRow) -> some View {
    ActiveWorkRowButtons(
      row: row, showLaneName: model.namesLanes, openSidechat: openSidechat,
      inspect: { lane, conversation in
        inspection = ActiveWorkInspectionTarget(lane: lane, conversation: conversation)
      }, respond: respond, responseEnabled: model.canSelectWorkResponse)
  }
}

private struct ActiveWorkRowButtons: View {
  let row: ActiveWorkRow
  let showLaneName: Bool
  let openSidechat: ((ProfileID, String) -> Void)?
  let inspect: (ProfileID, SavedConversation) -> Void
  let respond: (WorkResponseTarget) -> Void
  let responseEnabled: Bool

  var body: some View {
    HStack(spacing: 8) {
      Button {
        if row.item.sidechatSlug != nil, let openSidechat {
          openSidechat(row.lane, row.item.conversationId)
        } else {
          inspect(row.lane, row.inspectionTarget)
        }
      } label: {
        HStack(spacing: 8) {
          ActiveWorkRowContent(row: row, showLaneName: showLaneName)
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("activeWorkRow:\(row.id)")
      respondButton(row.responseTarget(), id: row.id)
    }
    if let children = row.item.children, !children.isEmpty {
      ForEach(children, id: \.agentId) { child in
        HStack(spacing: 8) {
          Button {
            inspect(row.lane, row.childInspectionTarget(child))
          } label: {
            HStack(spacing: 8) {
              ActiveWorkChildRowContent(child: child)
              Spacer(minLength: 4)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("activeWorkChild:\(row.id):\(child.agentId)")
          respondButton(row.responseTarget(for: child), id: "\(row.id):\(child.agentId)")
        }
      }
    }
  }

  @ViewBuilder
  private func respondButton(_ target: WorkResponseTarget?, id: String) -> some View {
    if let target {
      Button {
        respond(target)
      } label: {
        Label("Respond in chat", systemImage: "arrowshape.turn.up.left")
          .labelStyle(.iconOnly)
          .foregroundStyle(Color.accentColor)
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!responseEnabled)
      .help("Respond in chat")
      .accessibilityLabel("Respond in chat")
      .accessibilityHint(
        "Respond to \(target.reference.title) in \(target.reference.coordinator) chat"
      )
      .accessibilityIdentifier("activeWorkRespond:\(id)")
    }
  }
}

private struct ActiveWorkRowContent: View {
  let row: ActiveWorkRow
  let showLaneName: Bool

  private var subtitle: String {
    var parts: [String] = []
    if let detail = row.item.detail, !detail.isEmpty {
      parts.append(detail)
    } else if row.item.status == .waitingOwner {
      parts.append("Needs your reply")
    } else if row.item.status == .waitingExternal {
      parts.append("Waiting")
    } else if let host = row.item.host, !host.isEmpty {
      parts.append(host)
    }
    if showLaneName {
      parts.append(row.laneName)
    }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { context in
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Circle()
            .fill(row.item.status.tintColor)
            .frame(width: 8, height: 8)
          Text(row.item.title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          if row.item.sidechatSlug != nil {
            Text("Side chat")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.secondary.opacity(0.15), in: Capsule())
          } else if row.item.isJob {
            Text("Job")
              .font(.caption2.weight(.semibold))
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.secondary.opacity(0.15), in: Capsule())
          }
          Spacer(minLength: 4)
          if let startedAt = row.item.startedAt,
            let elapsed = Self.elapsedString(startedAtMs: startedAt, now: context.date)
          {
            Text(elapsed)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.footnote)
            .foregroundStyle(row.item.status == .waitingOwner ? .orange : .secondary)
            .lineLimit(1)
        }
      }
      .padding(.vertical, 2)
    }
  }

  private static func elapsedString(startedAtMs: Int, now: Date) -> String? {
    let nowMs = Int(now.timeIntervalSince1970 * 1000)
    let seconds = max(0, (nowMs - startedAtMs) / 1000)
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86_400)d"
  }
}

private struct ActiveWorkChildRowContent: View {
  let child: ActiveWorkChild

  var body: some View {
    HStack(spacing: 8) {
      Color.clear.frame(width: 8, height: 8)
      Circle()
        .fill(child.status.tintColor.opacity(0.85))
        .frame(width: 6, height: 6)
      VStack(alignment: .leading, spacing: 2) {
        Text(child.title)
          .font(.footnote.weight(.medium))
          .lineLimit(1)
        if let detail = child.detail ?? child.host, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
    }
  }
}
