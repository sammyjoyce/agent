import AgentCore
import AppIntents

/// An item that one coordinator owns, such as a job, named by the saved profile it belongs to.
/// The string form is `<profile UUID>:<item>`. A UUID has no colon, so the first colon ends the
/// profile and the item may hold colons of its own.
public struct ScopedEntityID: Hashable, Sendable {
  public let profile: ProfileID
  public let item: String

  public init(profile: ProfileID, item: String) {
    self.profile = profile
    self.item = item
  }

  /// nil unless `string` is a profile UUID, a colon, and a non-empty item.
  public init?(parsing string: String) {
    guard let colon = string.firstIndex(of: ":"),
      let profile = ProfileID(wire: String(string[..<colon]))
    else { return nil }
    let item = String(string[string.index(after: colon)...])
    guard !item.isEmpty else { return nil }
    self.init(profile: profile, item: item)
  }
}

extension ScopedEntityID: CustomStringConvertible {
  public var description: String { "\(profile):\(item)" }
}

extension ScopedEntityID: EntityIdentifierConvertible {
  public var entityIdentifierString: String { description }

  public static func entityIdentifier(for entityIdentifierString: String) -> ScopedEntityID? {
    ScopedEntityID(parsing: entityIdentifierString)
  }
}
