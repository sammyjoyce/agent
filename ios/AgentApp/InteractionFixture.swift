#if DEBUG
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
      return Self(peers: peers)
    }

    var body: some View {
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
              model.attach(Lane(id: profile.id, session: session, hold: LegacyHold(directory)))
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
#endif
