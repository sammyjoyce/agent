import AgentCore
import Foundation

/// One holder's claim that a coordinator stay connected, whatever the scene is doing.
struct ConnectionLease: Hashable, Sendable {
  let profile: ProfileID
  let id: UUID
}

/// Which coordinators want a connection: every one while the scene is active, and each one that
/// holds at least one lease.
struct ConnectionDemand: Equatable, Sendable {
  var sceneActive = false
  private var leases: [ProfileID: Set<UUID>] = [:]

  func wants(_ profile: ProfileID) -> Bool { sceneActive || leased(profile) }
  func leased(_ profile: ProfileID) -> Bool { leases[profile] != nil }

  mutating func take(_ profile: ProfileID) -> ConnectionLease {
    let lease = ConnectionLease(profile: profile, id: UUID())
    leases[profile, default: []].insert(lease.id)
    return lease
  }

  mutating func drop(_ lease: ConnectionLease) {
    leases[lease.profile]?.remove(lease.id)
    if leases[lease.profile]?.isEmpty == true { leases[lease.profile] = nil }
  }
}
