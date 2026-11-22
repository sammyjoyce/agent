import BeepBoopStatusCore
import SwiftUI

@main
struct BeepBoopMenuBarApp: App {
  @State private var model = StatusMonitor()

  var body: some Scene {
    MenuBarExtra {
      StatusMenuView(model: model)
        .frame(width: 320)
        .padding(14)
    } label: {
      Label("Beep Boop", systemImage: model.iconName)
    }
    .menuBarExtraStyle(.window)
  }
}

@MainActor
@Observable
final class StatusMonitor {
  private let client: ServiceStatusClient
  private(set) var snapshot: LocalServiceSnapshot
  private(set) var refreshing = false
  private var pollingTask: Task<Void, Never>?

  init(client: ServiceStatusClient = ServiceStatusClient()) {
    self.client = client
    self.snapshot = LocalServiceSnapshot(
      socketPath: client.socketURL.path,
      stateDir: client.stateDir.path,
      running: .stopped(reason: "Checking local service…"),
      installed: nil,
      alignment: .serviceStopped,
      checkedAt: Date()
    )
    self.pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        await self.performRefresh()
        try? await Task.sleep(for: .seconds(15))
      }
    }
  }

  var iconName: String {
    switch snapshot.alignment {
    case .upToDate:
      "checkmark.circle.fill"
    case .versionMismatch, .binaryReplaced:
      "exclamationmark.triangle.fill"
    case .binaryMissing:
      "questionmark.circle"
    case .serviceStopped:
      "pause.circle"
    }
  }

  func refreshNow() {
    Task { [weak self] in
      await self?.performRefresh()
    }
  }

  private func performRefresh() async {
    guard !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    snapshot = await client.refreshAsync()
  }
}

struct StatusMenuView: View {
  let model: StatusMonitor

  var body: some View {
    let snapshot = model.snapshot
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: model.iconName)
          .foregroundStyle(statusColor(snapshot.alignment))
        Text("Beep Boop Local Service")
          .font(.headline)
        Spacer()
        Button {
          model.refreshNow()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(model.refreshing)
        .buttonStyle(.borderless)
        .help("Refresh service status")
      }

      Divider()

      switch snapshot.running {
      case .running(let info):
        labeledRow("Status", "Running (PID \(info.pid))")
        labeledRow("Running version", info.version)
        if let exe = info.executablePath {
          labeledRow("Running binary", exe)
        }
        labeledRow("Coordinator", info.coordinatorID)
      case .stopped(let reason):
        labeledRow("Status", "Stopped")
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let installed = snapshot.installed {
        labeledRow("Installed version", installed.version)
        labeledRow("Installed binary", installed.resolvedPath)
      } else {
        labeledRow("Installed binary", "Not found in PATH")
      }

      statusBanner(snapshot.alignment)

      labeledRow("State directory", snapshot.stateDir)

      Divider()

      HStack {
        Text("Checked \(snapshot.checkedAt.formatted(date: .omitted, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
      }
    }
  }

  private func labeledRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func statusBanner(_ alignment: VersionAlignment) -> some View {
    switch alignment {
    case .upToDate(let version):
      Text("Service and installed binary match (\(version)).")
        .font(.caption)
        .foregroundStyle(.green)
    case .versionMismatch(let installed, let running):
      Text(
        "Installed version (\(installed)) differs from running service (\(running)); restart service."
      )
      .font(.caption)
      .foregroundStyle(.orange)
    case .binaryReplaced(let version, _, _):
      Text("Binary on disk replaced at version \(version); restart running service to pick it up.")
        .font(.caption)
        .foregroundStyle(.orange)
    case .binaryMissing:
      Text("Running service detected, but `beep-boop` CLI is not installed in PATH.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .serviceStopped:
      EmptyView()
    }
  }

  private func statusColor(_ alignment: VersionAlignment) -> Color {
    switch alignment {
    case .upToDate: .green
    case .versionMismatch, .binaryReplaced: .orange
    case .binaryMissing, .serviceStopped: .secondary
    }
  }
}
