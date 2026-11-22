import AgentCore
import SwiftUI

struct ActiveWorkRow: Identifiable, Equatable, Sendable {
  let id: String
  let lane: ProfileID
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
      .background(.background)
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
                ActiveWorkRowButtons(row: row, showLaneName: model.namesLanes) {
                  lane, conversation in
                  inspection = ActiveWorkInspectionTarget(lane: lane, conversation: conversation)
                }
              }
            }
          }
          if !waitingItems.isEmpty {
            Section("Waiting") {
              ForEach(waitingItems) { row in
                ActiveWorkRowButtons(row: row, showLaneName: model.namesLanes) {
                  lane, conversation in
                  inspection = ActiveWorkInspectionTarget(lane: lane, conversation: conversation)
                }
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
}

private struct ActiveWorkRowButtons: View {
  let row: ActiveWorkRow
  let showLaneName: Bool
  let inspect: (ProfileID, SavedConversation) -> Void

  var body: some View {
    Button {
      inspect(row.lane, row.inspectionTarget)
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
    if let children = row.item.children, !children.isEmpty {
      ForEach(children, id: \.agentId) { child in
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
      }
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
          if row.item.isJob {
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
