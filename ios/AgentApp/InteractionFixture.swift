#if DEBUG
  import CryptoKit
  import Foundation
  import Network
  import SwiftUI

  @testable import AgentCore
  @testable import AgentUI

  // UI automation supplies only loopback peers and the IDs they answer `identify` with. The
  // real screen, composer, session, identity check and durable outbox remain in use;
  // release builds have no override.
  struct InteractionFixture: View {
    /// One lane per peer, in order. Two peers are saved as Work and Personal.
    let peers: [(port: NWEndpoint.Port, coordinator: CoordinatorID)]
    let runID: String?
    let cleanup: Bool
    @State private var model = ChatModel()

    /// `AGENT_INTERACTION_PORT` and `AGENT_INTERACTION_COORDINATOR` are comma-separated lists.
    static func fromEnvironment() -> Self? {
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
      guard !peers.isEmpty, peers.count == ports.count else { return nil }
      let runID = environment["AGENT_INTERACTION_RUN"].flatMap { $0.isEmpty ? nil : $0 }
      return Self(
        peers: peers, runID: runID, cleanup: environment["AGENT_INTERACTION_CLEANUP"] == "1")
    }

    var body: some View {
      if let runID {
        PersistentInteractionFixture(peers: peers, runID: runID, cleanup: cleanup)
      } else {
        transient
      }
    }

    private var transient: some View {
      MainChatView(model: model)
        .task {
          let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let stamps = StampSource()
          do {
            let profiles = try zip(peers, ["Work", "Personal"]).map { _, name in
              CoordinatorProfile(
                name: try TagName(name), address: try CoordinatorAddress(host: "100.64.1.2"))
            }
            model.profiles = profiles
            for (profile, peer) in zip(profiles, peers) {
              let directory = ProfileDirectory(profile.id, applicationSupport: root, caches: root)
              let session = CoordinatorSession(
                directory: directory, address: profile.address, pin: peer.coordinator,
                stamps: stamps,
                transport: CoordinatorTransport { _ in
                  LineConnection(
                    connection: NWConnection(host: .ipv4(.loopback), port: peer.port, using: .tcp))
                })
              model.attach(Lane(id: profile.id, session: session))
            }
            await model.setActive(true)
            // Keep the SwiftUI-owned task alive. Cancellation releases the sessions.
            let lifetime = AsyncStream<Void> { _ in }
            for await _ in lifetime {}
            for profile in profiles { await model.detach(profile.id) }
          } catch { model.failure = error.localizedDescription }
        }
    }
  }

  private struct PersistentInteractionFixture: View {
    let peers: [(port: NWEndpoint.Port, coordinator: CoordinatorID)]
    let runID: String
    let cleanup: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var context: Context?
    @State private var message = "Preparing interaction fixture"

    private struct Context {
      let defaults: UserDefaults
      let notifications: AppNotifications
    }

    var body: some View {
      Group {
        if let context {
          MainChatView(notifications: context.notifications)
            .defaultAppStorage(context.defaults)
        } else {
          Text(message)
        }
      }
      .task { await start() }
      .onChange(of: scenePhase) { _, phase in
        guard let notifications = context?.notifications else { return }
        Task { await notifications.coordinators.setActive(phase == .active) }
      }
    }

    private func start() async {
      let key = SHA256.hash(data: Data(runID.utf8)).map { String(format: "%02x", $0) }.joined()
      let suite = "dev.jessfraz.Agent.InteractionFixture.\(key)"
      let root = URL.applicationSupportDirectory.appending(path: "Agent/InteractionFixtures/\(key)")
      guard let defaults = UserDefaults(suiteName: suite) else {
        message = "Could not create interaction fixture defaults"
        return
      }
      do {
        if cleanup {
          if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
          }
          defaults.removePersistentDomain(forName: suite)
          message = "Interaction fixture cleaned"
          return
        }
        let names = ["Work", "Personal"]
        guard peers.count <= names.count else {
          message = "Interaction fixture supports at most two peers"
          return
        }
        let support = root.appending(path: "Support")
        let caches = root.appending(path: "Caches")
        let addresses = try peers.indices.map {
          try CoordinatorAddress(host: "100.64.1.\($0 + 2)")
        }
        let ports = Dictionary(uniqueKeysWithValues: zip(addresses, peers.map(\.port)))
        let profilesURL = support.appending(path: "Agent/profiles.json")
        if !FileManager.default.fileExists(atPath: profilesURL.path) {
          let profiles = try peers.indices.map { index in
            var profile = CoordinatorProfile(
              name: try TagName(names[index]), address: addresses[index])
            profile.pin = peers[index].coordinator
            return profile
          }
          try writePrivately(
            JSONEncoder().encode(Coordinators.SavedProfiles(profiles: profiles)), to: profilesURL)
        }
        if defaults.persistentDomain(forName: suite)?["notificationsEnabled"] == nil {
          defaults.set(false, forKey: "notificationsEnabled")
        }
        let transport = CoordinatorTransport { address in
          guard let port = ports[address] else { throw ConnectionError.invalidAddress }
          return LineConnection(
            connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
        }
        let notifications = AppNotifications(
          defaults: defaults, applicationSupport: support, caches: caches, transport: transport,
          persistence: ComposerDraftStore(url: support.appending(path: "Agent/Composer/draft.json"))
        )
        context = Context(defaults: defaults, notifications: notifications)
        await notifications.coordinators.setActive(scenePhase == .active)
      } catch {
        message = "Interaction fixture failed: \(error.localizedDescription)"
      }
    }
  }
#endif
