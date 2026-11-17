import AgentCore
import AppIntents
import SwiftUI

enum OnscreenEntity: Hashable {
  case coordinator(ProfileID)
  case job(ScopedEntityID)

  var identifier: EntityIdentifier {
    switch self {
    case .coordinator(let id): EntityIdentifier(for: CoordinatorEntity.self, identifier: "\(id)")
    case .job(let id): EntityIdentifier(for: JobEntity.self, identifier: id)
    }
  }

  @MainActor static func feed(of model: ChatModel) -> OnscreenEntity? {
    guard model.inspectedConversation == nil else { return nil }
    return model.scope.shownCoordinator(among: model.profiles).map(OnscreenEntity.coordinator)
  }
}

extension View {
  @ViewBuilder func onscreenEntity(_ entity: OnscreenEntity?) -> some View {
    if #available(iOS 18.4, macOS 15.4, *) {
      appEntityIdentifier(entity?.identifier)
    } else {
      self
    }
  }
}
