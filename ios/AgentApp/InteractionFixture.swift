#if DEBUG
  import Foundation
  import Network
  import SwiftUI
  import UserNotifications

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
      let dictation: Dictation?

      /// One saved coordinator per peer, in order. Two peers are saved as Work and Personal.
      init?(peers: [Peer], storage: Storage, dictation: Dictation?) {
        let names = ["Work", "Personal"]
        guard peers.count <= names.count, let defaults = UserDefaults(suiteName: storage.suite)
        else { return nil }
        self.defaults = defaults
        self.dictation = dictation
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
            sharedInbox: try? SharedDraftInbox.configured(), spotlight: CoreSpotlightStore())
        } catch { return nil }
      }
    }

    private enum Launch {
      case running(Lifetime)
      case cleaned
      case unavailable
    }

    /// The process's one fixture, so alert taps and intents reach it even in a launch that builds
    /// no window.
    private static let current: Launch? = {
      guard environment["AGENT_INTERACTION_PORT"] != nil else { return nil }
      let named = environment["AGENT_INTERACTION_ID"].flatMap(UUID.init(uuidString:))
      if let named, environment["AGENT_INTERACTION_CLEANUP"] == "1" {
        return (try? Storage(named).erase()) == nil ? .unavailable : .cleaned
      }
      guard let peers = requestedPeers,
        let lifetime = Lifetime(
          peers: peers, storage: Storage(named ?? UUID()), dictation: requestedDictation)
      else { return .unavailable }
      return .running(lifetime)
    }()

    static var interactionLaunch: AppNotifications.InteractionLaunch {
      switch current {
      case nil: .plain
      case .running(let lifetime): .fixture(lifetime.notifications)
      case .cleaned: .unavailable(reason: "This launch erased its interaction fixture.")
      case .unavailable:
        .unavailable(reason: "This launch could not build its interaction fixture.")
      }
    }

    /// The dictation of the screen this launch shows, given the app's own. The fixture shows its
    /// scripted dictation or none, so under it the app's own never reads its model.
    static func shownDictation(app: Dictation) -> Dictation? {
      switch current {
      case nil: app
      case .running(let lifetime): lifetime.dictation
      case .cleaned, .unavailable: nil
      }
    }

    private let launch: Launch
    private let feedback: ScrawlFeedback

    /// The `AGENT_INTERACTION_*` values of this launch. A tap on an alert or a system-run intent
    /// starts the app with no environment, so a launch that names its storage and sets
    /// `AGENT_INTERACTION_ALERTS=1` or `AGENT_INTERACTION_INTENTS=1` saves its values, and a
    /// launch that names no port reads them back until a cleanup launch.
    private static let environment: [String: String] = {
      let current = ProcessInfo.processInfo.environment
      let key = "interactionFixtureLaunch"
      guard current["AGENT_INTERACTION_PORT"] != nil else {
        return UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
      }
      if current["AGENT_INTERACTION_CLEANUP"] == "1" {
        UserDefaults.standard.removeObject(forKey: key)
      } else if current["AGENT_INTERACTION_ID"] != nil,
        current["AGENT_INTERACTION_ALERTS"] == "1" || current["AGENT_INTERACTION_INTENTS"] == "1"
      {
        UserDefaults.standard.set(
          current.filter { $0.key.hasPrefix("AGENT_INTERACTION_") }, forKey: key)
      }
      return current
    }()

    /// The peers the launch names. `AGENT_INTERACTION_PORT` and `AGENT_INTERACTION_COORDINATOR`
    /// are comma-separated lists.
    private static var requestedPeers: [Peer]? {
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

    private static var requestedDictation: Dictation? {
      guard let json = environment["AGENT_INTERACTION_DICTATION"],
        let script = try? JSONDecoder().decode(ScriptedSpeech.Script.self, from: Data(json.utf8))
      else { return nil }
      return Dictation(engine: ScriptedSpeech(script).engine)
    }

    /// `AGENT_INTERACTION_ID` names the storage a relaunch reuses. With it,
    /// `AGENT_INTERACTION_CLEANUP=1` erases that storage and shows only that it did.
    /// `AGENT_INTERACTION_ALERTS=1` asks for permission to show alerts.
    static func fromEnvironment(feedback: ScrawlFeedback) -> Self? {
      current.map { Self(launch: $0, feedback: feedback) }
    }

    var body: some View {
      switch launch {
      case .running(let lifetime):
        MainChatView(notifications: lifetime.notifications, dictation: lifetime.dictation)
          .defaultAppStorage(lifetime.defaults)
          .onAppear { lifetime.notifications.coordinators.feedbackRecorder = feedback }
          .task {
            if Self.environment["AGENT_INTERACTION_ALERTS"] == "1" {
              _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert, .sound,
              ])
            }
          }
      case .cleaned: Text("Interaction fixture cleaned")
      case .unavailable: Text("Interaction fixture unavailable")
      }
    }
  }
#endif
