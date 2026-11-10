#if DEBUG
  import Foundation
  import Network
  import SwiftUI

  @testable import AgentCore
  @testable import AgentUI

  // UI automation redirects only transport: loopback peers and the IDs they answer `identify`
  // with. The screen owns production startup, persistence and foreground recovery, and the
  // identity check stays in use; release builds have no override.
  struct InteractionFixture: View {
    typealias Peer = (port: NWEndpoint.Port, coordinator: CoordinatorID)

    /// Where one storage ID keeps its settings and files. A relaunch with the same ID finds both.
    private struct Storage {
      let suite: String
      let root: URL

      init(_ id: UUID) {
        let key = id.uuidString.lowercased()
        suite = "dev.jessfraz.Agent.Interaction.\(key)"
        root = URL.applicationSupportDirectory.appending(path: "Agent/Interaction/\(key)")
      }

      /// Leaves nothing of the ID behind. Storage already erased stays erased.
      func erase() throws {
        if FileManager.default.fileExists(atPath: root.path) {
          try FileManager.default.removeItem(at: root)
        }
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      }
    }

    @MainActor private struct Lifetime {
      let notifications: AppNotifications
      let defaults: UserDefaults

      /// One saved coordinator per peer, in order. Two peers are saved as Work and Personal.
      init?(peers: [Peer], storage: Storage) {
        let names = ["Work", "Personal"]
        guard peers.count <= names.count, let defaults = UserDefaults(suiteName: storage.suite)
        else { return nil }
        self.defaults = defaults
        defaults.register(defaults: ["notificationsEnabled": false])
        let root = storage.root
        let support = root.appending(path: "Support")
        do {
          let addresses = try peers.indices.map {
            try CoordinatorAddress(host: "100.64.1.\($0 + 2)")
          }
          // A relaunch keeps its saved coordinators, and with them their outboxes.
          let saved = support.appending(path: "Agent/profiles.json")
          if !FileManager.default.fileExists(atPath: saved.path) {
            let profiles = try peers.indices.map { index in
              var profile = CoordinatorProfile(
                name: try TagName(names[index]), address: addresses[index])
              profile.pin = peers[index].coordinator
              return profile
            }
            try writePrivately(
              JSONEncoder().encode(Coordinators.SavedProfiles(profiles: profiles)), to: saved)
          }
          notifications = AppNotifications(
            defaults: defaults, applicationSupport: support,
            caches: root.appending(path: "Caches"),
            transport: CoordinatorTransport { address in
              guard let peer = addresses.firstIndex(of: address) else {
                throw ConnectionError.invalidAddress
              }
              return LineConnection(
                connection: NWConnection(
                  host: .ipv4(.loopback), port: peers[peer].port, using: .tcp))
            },
            persistence: ComposerDraftStore(
              url: support.appending(path: "Agent/Composer/draft.json")),
            sharedInbox: try? SharedDraftInbox.configured())
        } catch { return nil }
      }
    }

    // Reconstruction must keep the model and its settings/store identity together. It is nil
    // once a cleanup launch erased its storage.
    @State private var lifetime: Lifetime?
    @Environment(\.scenePhase) private var scenePhase

    private init(lifetime: Lifetime?) { _lifetime = State(initialValue: lifetime) }

    /// The peers the launch names. `AGENT_INTERACTION_PORT` and `AGENT_INTERACTION_COORDINATOR`
    /// are comma-separated lists.
    private static var requestedPeers: [Peer]? {
      let environment = ProcessInfo.processInfo.environment
      guard let ports = environment["AGENT_INTERACTION_PORT"]?.split(separator: ","),
        let coordinators = environment["AGENT_INTERACTION_COORDINATOR"]?.split(separator: ","),
        ports.count == coordinators.count
      else { return nil }
      let peers = zip(ports, coordinators).compactMap { port, coordinator in
        UInt16(port).flatMap(NWEndpoint.Port.init(rawValue:)).flatMap { port in
          CoordinatorID(wire: String(coordinator)).map { (port, $0) }
        }
      }
      return !peers.isEmpty && peers.count == ports.count ? peers : nil
    }

    /// True when the launch asks for the fixture. Its own coordinators are then the only ones the
    /// scene phase drives, so the app delegate's never share an inbox or a registration with them.
    static var isRequested: Bool { requestedPeers != nil }

    /// `AGENT_INTERACTION_ID` names the storage a relaunch reuses. With it,
    /// `AGENT_INTERACTION_CLEANUP=1` erases that storage and shows only that it did.
    static func fromEnvironment() -> Self? {
      let environment = ProcessInfo.processInfo.environment
      guard let peers = requestedPeers else { return nil }
      let named = environment["AGENT_INTERACTION_ID"].flatMap(UUID.init(uuidString:))
      if let named, environment["AGENT_INTERACTION_CLEANUP"] == "1" {
        return (try? Storage(named).erase()).map { Self(lifetime: nil) }
      }
      guard let lifetime = Lifetime(peers: peers, storage: Storage(named ?? UUID())) else {
        return nil
      }
      return Self(lifetime: lifetime)
    }

    var body: some View {
      if let lifetime {
        MainChatView(notifications: lifetime.notifications)
          .defaultAppStorage(lifetime.defaults)
          .onChange(of: scenePhase, initial: true) { _, phase in
            Task { await lifetime.notifications.coordinators.setActive(phase == .active) }
          }
      } else {
        Text("Interaction fixture cleaned")
      }
    }
  }
#endif
