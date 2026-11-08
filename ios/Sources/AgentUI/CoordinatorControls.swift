import AgentCore
import SwiftUI

/// Why a control on one coordinator did not run or did not finish. None is retried.
enum LaneError: LocalizedError, Equatable {
  case gone(String)
  case notPaired(String)
  /// The coordinator's session changed, or its connection was cut, while the request ran. It may
  /// or may not have reached the coordinator.
  case interrupted(String)

  var errorDescription: String? {
    switch self {
    case .gone(let name): "\(name) was removed."
    case .notPaired(let name): "\(name) is not paired yet."
    case .interrupted(let name):
      "The connection to \(name) was interrupted before this finished. Reload to see its current state before trying again."
    }
  }
}

/// Jobs and work and Conversation settings for one coordinator: a link while it advertises the
/// feature, and a hint while it is connected without it.
struct CoordinatorControls: View {
  let model: ChatModel
  let lane: ProfileID

  var body: some View {
    let snapshot = model.snapshots[lane]
    let connected = snapshot?.connection == .connected
    if snapshot?.workInspectionSupported == true {
      NavigationLink("Jobs and work") {
        LaneScreen(model: model, lane: lane) { WorkView(model: model, lane: lane) }
      }
    } else if connected {
      Text("Update the coordinator to inspect scheduled jobs and saved work.").font(.footnote)
    }
    if snapshot?.settingsSupported == true {
      NavigationLink("Conversation settings") {
        LaneScreen(model: model, lane: lane) { ConversationSettingsView(model: model, lane: lane) }
      }
    } else if connected {
      Text("Conversation settings are not advertised by this coordinator.").font(.footnote)
    }
  }
}

/// A page that belongs to one coordinator. It starts over when that coordinator's session
/// changes, and says so once the coordinator is removed.
struct LaneScreen<Content: View>: View {
  let model: ChatModel
  let lane: ProfileID
  private let content: Content

  init(model: ChatModel, lane: ProfileID, @ViewBuilder content: () -> Content) {
    self.model = model
    self.lane = lane
    self.content = content()
  }

  var body: some View {
    if model.isSaved(lane) {
      content.id(model.laneEpoch(lane))
    } else {
      ContentUnavailableView("\(model.name(lane)) was removed", systemImage: "trash")
    }
  }
}
