import AgentCore
import BeepBoopStatusCore
import SwiftUI

@main
struct BeepBoopMenuBarApp: App {
  @State private var model = StatusMonitor()

  var body: some Scene {
    MenuBarExtra {
      StatusMenuView(model: model)
        .frame(width: 380)
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
  private(set) var snapshot: LocalHostSnapshot
  private(set) var refreshing = false
  private var pollingTask: Task<Void, Never>?

  init(client: ServiceStatusClient = ServiceStatusClient()) {
    self.client = client
    self.snapshot = LocalHostSnapshot(
      services: [],
      installedCLI: nil,
      overallHealth: .starting,
      defaultStateDir: client.stateDir.path,
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
    Self.icon(for: snapshot.overallHealth)
  }

  static func icon(for health: ServiceHealth) -> String {
    switch health {
    case .healthy:
      "checkmark.circle.fill"
    case .starting:
      "arrow.triangle.2.circlepath.circle"
    case .degraded:
      "exclamationmark.triangle.fill"
    case .stopped:
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
    snapshot = await client.refreshHostAsync()
  }
}

struct StatusMenuView: View {
  let model: StatusMonitor

  var body: some View {
    let snapshot = model.snapshot
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: model.iconName)
          .foregroundStyle(healthColor(snapshot.overallHealth))
        Text("Beep Boop")
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

      if snapshot.services.isEmpty && snapshot.overallHealth == .starting {
        Text("Checking local Beep Boop services…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if snapshot.services.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("No local Beep Boop service is running.")
            .font(.subheadline.weight(.medium))
          Text(
            "Checked \(snapshot.defaultStateDir) for coordinator, worker, and standby sockets."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      } else {
        let serviceList = VStack(alignment: .leading, spacing: 10) {
          ForEach(Array(snapshot.services.enumerated()), id: \.element.id) { index, service in
            if index > 0 {
              Divider()
            }
            ServiceSectionView(service: service)
          }
        }
        ViewThatFits(in: .vertical) {
          serviceList
          ScrollView {
            serviceList
          }
          .frame(maxHeight: 540)
        }
      }

      Divider()

      if let cli = snapshot.installedCLI {
        labeledRow("CLI (\(cli.version))", cli.resolvedPath)
      } else {
        labeledRow("CLI", "Not found in PATH")
      }

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
}

private struct ServiceSectionView: View {
  let service: ServiceSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: StatusMonitor.icon(for: service.health))
          .foregroundStyle(healthColor(service.health))
        Text(roleTitle(service.role))
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(statusSummary(service.running))
          .font(.caption.weight(.medium))
          .foregroundStyle(healthColor(service.health))
      }

      switch service.running {
      case .running(let info):
        HStack(spacing: 12) {
          compactField("PID", "\(info.pid)")
          compactField("Version", info.version)
          if let position = info.appliedPosition {
            compactField("Applied", "#\(position)")
          }
        }
        if let nodeName = info.nodeName, !nodeName.isEmpty {
          labeledRow("Node", nodeName)
        }
        if let target = info.target, !target.isEmpty {
          labeledRow("Coordinator target", target)
        }
        if !info.coordinatorID.isEmpty {
          labeledRow("Coordinator ID", info.coordinatorID)
        }
        if let detail = info.detail, !detail.isEmpty {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let exe = info.executablePath, !exe.isEmpty {
          labeledRow("Running binary", exe)
        }
      case .runningWithoutStatus(let reason):
        Text(
          "Service accepted the connection without returning status. Restart the service to update."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      case .stopped(let reason):
        Text(reason)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if service.configured && service.role != .coordinator {
          Text(
            "Configured via launchd; if the service is running an older build, restart it to expose local status."
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }

      alignmentBanner(service.alignment)

      labeledRow("State directory", service.stateDir)
    }
  }

  private func compactField(_ title: String, _ value: String) -> some View {
    HStack(spacing: 4) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
    }
  }

  @ViewBuilder
  private func alignmentBanner(_ alignment: VersionAlignment) -> some View {
    switch alignment {
    case .upToDate(let version):
      Text("Running binary matches installed build (\(version)).")
        .font(.caption)
        .foregroundStyle(.green)
        .fixedSize(horizontal: false, vertical: true)
    case .versionMismatch(let installed, let running):
      Text(
        "Installed version (\(installed)) differs from running service (\(running)); restart service."
      )
      .font(.caption)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    case .binaryReplaced(let version, let installedPath, _):
      VStack(alignment: .leading, spacing: 2) {
        Text("Binary on disk updated at \(version); restart service to pick it up.")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
        labeledRow("Configured binary", installedPath)
      }
    case .binaryMissing:
      Text("Running service detected, but installed `beep-boop` binary was not found.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    case .serviceStopped, .serviceRunningWithoutStatus:
      EmptyView()
    }
  }
}

private func labeledRow(_ title: String, _ value: String) -> some View {
  VStack(alignment: .leading, spacing: 1) {
    Text(title)
      .font(.caption2)
      .foregroundStyle(.secondary)
    Text(value)
      .font(.system(.caption, design: .monospaced))
      .fixedSize(horizontal: false, vertical: true)
      .textSelection(.enabled)
  }
}

private func roleTitle(_ role: ServiceRole) -> String {
  switch role {
  case .coordinator: "Coordinator"
  case .worker: "Worker"
  case .standby: "Failover Standby"
  }
}

private func statusSummary(_ state: ServiceRunningState) -> String {
  switch state {
  case .stopped:
    return "Stopped"
  case .runningWithoutStatus:
    return "No Status"
  case .running(let info):
    switch info.connectionState {
    case .connected: return "Connected"
    case .connecting: return "Connecting"
    case .reconnecting: return "Reconnecting"
    case .following: return "Following"
    case .authorityUnreachable: return "Authority Unreachable"
    case nil: return "Running"
    }
  }
}

private func healthColor(_ health: ServiceHealth) -> Color {
  switch health {
  case .healthy: .green
  case .starting: .blue
  case .degraded: .orange
  case .stopped: .secondary
  }
}
