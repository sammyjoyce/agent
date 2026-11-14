import AgentCore
import AppIntents

/// A saved coordinator as Siri and Shortcuts see it. The address stays private to the app.
public struct CoordinatorEntity: AppEntity {
  public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Coordinator"
  public static let defaultQuery = CoordinatorQuery()

  /// The profile's `ProfileID`, as `ProfileID(wire:)` reads it.
  public let id: String
  public let name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }

  public var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(name)")
  }

  @MainActor static func saved(in coordinators: Coordinators) -> [CoordinatorEntity] {
    coordinators.profiles.map { CoordinatorEntity(id: "\($0.id)", name: "\($0.name)") }
  }

  /// The saved coordinators among `identifiers`, in saved order. An unknown id is dropped.
  @MainActor static func saved(in coordinators: Coordinators, matching identifiers: [String])
    -> [CoordinatorEntity]
  {
    saved(in: coordinators).filter { identifiers.contains($0.id) }
  }
}

public struct CoordinatorQuery: EnumerableEntityQuery {
  @Dependency private var notifications: AppNotifications

  public init() {}

  public func allEntities() async throws -> [CoordinatorEntity] {
    let notifications = notifications
    return await MainActor.run { CoordinatorEntity.saved(in: notifications.intentCoordinators) }
  }

  public func entities(for identifiers: [String]) async throws -> [CoordinatorEntity] {
    let notifications = notifications
    return await MainActor.run {
      CoordinatorEntity.saved(in: notifications.intentCoordinators, matching: identifiers)
    }
  }
}

extension Coordinators {
  /// Saved names in order, so the app can refresh Siri's phrases when one changes.
  public var savedNames: [String] { profiles.map(\.name.description) }
}
