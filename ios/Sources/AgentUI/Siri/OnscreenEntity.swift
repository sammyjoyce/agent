import AgentCore
import AppIntents
import SwiftUI

/// What a screen shows that Siri and Apple Intelligence can act on.
enum OnscreenEntity: Hashable {
  case coordinator(ProfileID)
  case job(ScopedEntityID)

  /// The identifier the entity's query gives the same coordinator or job.
  var identifier: EntityIdentifier {
    switch self {
    case .coordinator(let id): EntityIdentifier(for: CoordinatorEntity.self, identifier: "\(id)")
    case .job(let id): EntityIdentifier(for: JobEntity.self, identifier: id)
    }
  }

  /// The coordinator the feed shows. An inspection's model holds its one coordinator's profile,
  /// yet it shows one saved conversation and not that coordinator's feed, so it claims nothing.
  @MainActor static func feed(of model: ChatModel) -> OnscreenEntity? {
    guard model.inspectedConversation == nil else { return nil }
    return model.scope.shownCoordinator(among: model.profiles).map(OnscreenEntity.coordinator)
  }
}

extension View {
  /// Tells the system which coordinator or job this view shows. nil claims nothing.
  @ViewBuilder func onscreenEntity(_ entity: OnscreenEntity?) -> some View {
    if #available(iOS 18.4, macOS 15.4, *) {
      appEntityIdentifier(entity?.identifier)
    } else {
      self
    }
  }
}
