import AgentCore
import SwiftUI

extension DreamsProposalStatus {
  var displayLabel: String {
    switch self {
    case .pending: "Pending approval"
    case .applied: "Applied"
    case .stale: "Stale"
    case .targetDirty: "Target dirty"
    case .targetLocked: "Target locked"
    case .patchChanged: "Patch changed"
    case .policyChanged: "Policy changed"
    }
  }

  var badgeColor: Color {
    switch self {
    case .pending: .orange
    case .applied: .green
    case .stale, .targetDirty, .targetLocked, .patchChanged, .policyChanged: .secondary
    }
  }
}

struct DreamsView: View {
  let model: ChatModel
  let lane: ProfileID

  @State private var runs: [DreamsRunSummary] = []
  @State private var pendingCount = 0
  @State private var loaded = false
  @State private var busy = false
  @State private var error: String?
  @State private var reloadToken = UUID()

  private var pendingRuns: [DreamsRunSummary] { runs.filter { $0.proposalStatus == .pending } }
  private var otherRuns: [DreamsRunSummary] { runs.filter { $0.proposalStatus != .pending } }

  var body: some View {
    List {
      if let error {
        Section {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      if !loaded && busy {
        Section {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading Dreams runs…").foregroundStyle(.secondary)
          }
        }
      } else if loaded && runs.isEmpty && error == nil {
        ContentUnavailableView(
          "No Dreams runs yet",
          systemImage: "moon.stars",
          description: Text("Nightly Dreams reviews and proposed edits appear here."))
      } else {
        if !pendingRuns.isEmpty {
          runsSection("Pending approval (\(pendingCount))", items: pendingRuns)
        }
        if !otherRuns.isEmpty {
          runsSection(pendingRuns.isEmpty ? "Runs" : "History", items: otherRuns)
        }
      }
    }
    .navigationTitle(model.laneTitle("Dreams", for: lane))
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          reloadToken = UUID()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(busy)
      }
    }
    .refreshable {
      await load()
    }
    .task(id: reloadToken) {
      await load()
    }
    .accessibilityIdentifier("dreamsList")
  }

  @ViewBuilder
  private func runsSection(_ title: String, items: [DreamsRunSummary]) -> some View {
    Section(title) {
      ForEach(items, id: \.run) { item in
        NavigationLink {
          DreamsDetailView(model: model, lane: lane, runID: item.run) {
            reloadToken = UUID()
          }
        } label: {
          DreamsSummaryRow(item: item)
        }
        .accessibilityIdentifier("dreamsRunRow:\(item.run)")
      }
    }
  }

  private func load() async {
    busy = true
    defer {
      busy = false
      loaded = true
    }
    do {
      let reply = try await model.dreamsList(lane: lane)
      runs = reply.runs
      pendingCount = reply.pendingCount
      error = nil
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
  }
}

private struct DreamsSummaryRow: View {
  let item: DreamsRunSummary

  private var statusLabel: String {
    if let status = item.proposalStatus {
      return status.displayLabel
    }
    return item.outcomeLabel.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private var badgeColor: Color {
    item.proposalStatus?.badgeColor ?? .secondary
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Circle()
          .fill(badgeColor)
          .frame(width: 8, height: 8)
        Text(item.run)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(statusLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(badgeColor)
      }
      HStack(spacing: 6) {
        Text(item.coverageComplete ? "Coverage complete" : "Coverage incomplete")
          .foregroundStyle(item.coverageComplete ? Color.secondary : Color.orange)
        Text("·").foregroundStyle(.secondary)
        Text(Self.formatEpoch(item.windowEndMs))
          .foregroundStyle(.secondary)
      }
      .font(.caption)
      .lineLimit(1)
    }
    .padding(.vertical, 2)
  }

  static func formatEpoch(_ ms: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    return date.formatted(date: .abbreviated, time: .shortened)
  }
}

struct DreamsDetailView: View {
  let model: ChatModel
  let lane: ProfileID
  let runID: String
  var onApplied: () -> Void = {}

  @State private var detail: DreamsRunDetail?
  @State private var error: String?
  @State private var busy = false
  @State private var applying = false
  @State private var confirmApply = false
  @State private var applyNotice: String?

  var body: some View {
    List {
      if let error {
        Section {
          Text(error)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      if let applyNotice {
        Section {
          Label(applyNotice, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .foregroundStyle(.green)
        }
      }
      if let detail {
        Section("Status") {
          LabeledContent("Run", value: detail.run)
          LabeledContent("Outcome", value: detail.outcomeLabel)
          if let status = detail.proposalStatus {
            LabeledContent("Status", value: status.displayLabel)
          }
          if let statusDetail = detail.statusDetail {
            Text(statusDetail)
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          LabeledContent("Base", value: String(detail.baseRevision.prefix(12)))
          LabeledContent("Attempts", value: "\(detail.attemptsUsed)")
          if let sha = detail.outcomeSha256 {
            VStack(alignment: .leading, spacing: 2) {
              Text("Sealed outcome digest").font(.caption).foregroundStyle(.secondary)
              Text(sha).font(.caption.monospaced()).textSelection(.enabled)
            }
          }
        }

        Section("Coverage") {
          LabeledContent("Window start", value: DreamsSummaryRow.formatEpoch(detail.windowStartMs))
          LabeledContent("Window end", value: DreamsSummaryRow.formatEpoch(detail.windowEndMs))
          LabeledContent(
            "Completeness",
            value: detail.coverageComplete ? "Complete" : "Incomplete (\(detail.gaps.count) gaps)")
          LabeledContent("Receipts", value: "\(detail.receiptsCount)")
          LabeledContent("Task summaries", value: "\(detail.summariesCount)")
          if !detail.gaps.isEmpty {
            ForEach(detail.gaps, id: \.self) { gap in
              Text(gap)
                .font(.caption.monospaced())
                .foregroundStyle(.orange)
            }
          }
        }

        if let note = detail.rationaleOrNote, !note.isEmpty {
          Section("Quoted rationale / note") {
            VStack(alignment: .leading, spacing: 6) {
              Text("Untrusted proposal text (control-escaped)")
                .font(.caption2)
                .foregroundStyle(.secondary)
              HStack(alignment: .top, spacing: 8) {
                Rectangle()
                  .fill(.orange.opacity(0.6))
                  .frame(width: 3)
                Text(note)
                  .font(.footnote)
                  .textSelection(.enabled)
              }
            }
            .padding(.vertical, 2)
          }
        }

        if !detail.checks.isEmpty {
          Section("Checks") {
            ForEach(Array(detail.checks.enumerated()), id: \.offset) { _, check in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Image(
                    systemName: check.passed
                      ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                  )
                  .foregroundStyle(check.passed ? .green : .red)
                  Text("\(check.phase.capitalized): \(check.name)")
                    .font(.subheadline.weight(.medium))
                  Spacer()
                  Text(check.verdict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !check.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text(check.output)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                }
              }
              .padding(.vertical, 2)
            }
          }
        }

        if !detail.citedEvidence.isEmpty {
          Section("Cited evidence") {
            ForEach(detail.citedEvidence, id: \.id) { item in
              VStack(alignment: .leading, spacing: 4) {
                HStack {
                  Text(item.kind.capitalized)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.secondary.opacity(0.15), in: Capsule())
                  Text(item.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }
                if let title = item.title, !title.isEmpty {
                  Text(title).font(.footnote.weight(.medium))
                }
                Text(item.body)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                  .textSelection(.enabled)
              }
              .padding(.vertical, 2)
            }
          }
        }

        if !detail.files.isEmpty || detail.patch != nil {
          Section("Patch") {
            if !detail.files.isEmpty {
              ForEach(detail.files, id: \.self) { file in
                Label(file, systemImage: "doc.text")
                  .font(.footnote.monospaced())
              }
            }
            if let patchSha = detail.patchSha256 {
              LabeledContent("Patch SHA-256", value: String(patchSha.prefix(16)))
            }
            if let patch = detail.patch {
              ScrollView(.horizontal) {
                Text(patch)
                  .font(.caption.monospaced())
                  .textSelection(.enabled)
              }
            }
          }
        }

        if detail.canApply, detail.outcomeSha256 != nil {
          Section {
            Button {
              confirmApply = true
            } label: {
              HStack {
                Spacer()
                if applying {
                  ProgressView().padding(.trailing, 6)
                }
                Text(applying ? "Applying…" : "Apply proposal")
                  .fontWeight(.semibold)
                Spacer()
              }
            }
            .disabled(applying)
            .accessibilityIdentifier("dreamsApplyButton")
          }
        }
      } else if busy {
        Section {
          HStack(spacing: 10) {
            ProgressView()
            Text("Loading run details…").foregroundStyle(.secondary)
          }
        }
      }
    }
    .navigationTitle(runID)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .confirmationDialog(
      "Apply Dreams proposal?",
      isPresented: $confirmApply,
      titleVisibility: .visible
    ) {
      Button("Apply changes", role: .destructive) {
        Task { await applyConfirmed() }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      if let detail {
        let filesList = detail.files.joined(separator: ", ")
        let digest = detail.outcomeSha256.map { String($0.prefix(16)) } ?? ""
        Text("Commit \(filesList) from run \(detail.run) (digest \(digest)…)?")
      }
    }
    .task {
      await load()
    }
    .accessibilityIdentifier("dreamsDetailView")
  }

  private func load() async {
    busy = true
    defer { busy = false }
    do {
      detail = try await model.dreamsShow(runID, lane: lane)
      error = nil
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func applyConfirmed() async {
    guard let detail, let approval = detail.outcomeSha256 else { return }
    applying = true
    defer { applying = false }
    do {
      let result = try await model.dreamsApply(run: detail.run, approve: approval, lane: lane)
      let shortCommit = String(result.commit.prefix(12))
      applyNotice =
        result.alreadyApplied
        ? "Already applied at commit \(shortCommit)."
        : "Applied as commit \(shortCommit)."
      error = nil
      onApplied()
      await load()
    } catch is CancellationError {
      return
    } catch {
      self.error = error.localizedDescription
    }
  }
}
