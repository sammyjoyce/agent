#if DEBUG
  import Foundation
  import Network
  import SwiftUI

  @testable import AgentCore
  @testable import AgentUI

  // UI automation supplies only a loopback peer and the ID it answers `identify` with. The
  // real screen, composer, session, identity check and durable outbox remain in use;
  // release builds have no override.
  struct InteractionFixture: View {
    let port: NWEndpoint.Port
    let coordinator: CoordinatorID
    @State private var model = ChatModel()

    static func fromEnvironment() -> Self? {
      let environment = ProcessInfo.processInfo.environment
      guard let value = environment["AGENT_INTERACTION_PORT"],
        let number = UInt16(value), let port = NWEndpoint.Port(rawValue: number),
        let coordinator = environment["AGENT_INTERACTION_COORDINATOR"].flatMap(
          CoordinatorID.init(wire:))
      else { return nil }
      return Self(port: port, coordinator: coordinator)
    }

    var body: some View {
      MainChatView(model: model)
        .task {
          let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
          defer { try? FileManager.default.removeItem(at: root) }
          let directory = ProfileDirectory(ProfileID(), applicationSupport: root, caches: root)
          let port = port
          do {
            let session = CoordinatorSession(
              directory: directory, address: try CoordinatorAddress(host: "100.64.1.2"),
              pin: coordinator, stamps: StampSource(),
              transport: CoordinatorTransport { _ in
                LineConnection(
                  connection: NWConnection(host: .ipv4(.loopback), port: port, using: .tcp))
              })
            model.attach(Lane(id: directory.profile, session: session, hold: LegacyHold(directory)))
            await session.connect()
            // Keep the SwiftUI-owned task alive. Cancellation releases the session.
            let lifetime = AsyncStream<Void> { _ in }
            for await _ in lifetime {}
            await model.detach(directory.profile)
          } catch { model.error = error.localizedDescription }
        }
    }
  }
#endif
