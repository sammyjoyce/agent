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
          let root = FileManager.default.temporaryDirectory.appending(path: UUID().description)
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
#endif

#if DEBUG
  // PROTOTYPE: coordinator switcher variants over a seeded model with no network. Throwaway.
  struct PrototypeFixture: View {
    @State private var model = ChatModel()
    @State private var variant: String
    @State private var path: [String] = []
    @State private var seeded = false
    let initialScope: String
    let clean: Bool
    let draft: String?

    static func fromEnvironment() -> Self? {
      let environment = ProcessInfo.processInfo.environment
      guard environment["AGENT_PROTOTYPE"] == "1" else { return nil }
      return Self(
        variant: environment["AGENT_PROTOTYPE_VARIANT"] ?? "v1",
        initialScope: environment["AGENT_PROTOTYPE_SCOPE"] ?? "all",
        clean: environment["AGENT_PROTOTYPE_CLEAN"] == "1",
        draft: environment["AGENT_PROTOTYPE_DRAFT"])
    }
    init(variant: String, initialScope: String, clean: Bool, draft: String?) {
      _variant = State(initialValue: variant)
      self.initialScope = initialScope
      self.clean = clean
      self.draft = draft
    }

    var body: some View {
      Group {
        if seeded {
          if variant == "v4" {
            PrototypeConversationList(model: model, path: $path)
          } else {
            MainChatView(model: model)
          }
        } else {
          Color.clear
        }
      }
      .id(variant)
      .overlay(alignment: .topTrailing) {
        if !clean {
          Menu {
            Picker("Variant", selection: $variant) {
              Text("V1 Title menu").tag("v1")
              Text("V2 Scope bar").tag("v2")
              Text("V3 Filter pills").tag("v3")
              Text("V4 Conversation list").tag("v4")
              Text("V5 Composer scope").tag("v5")
            }
            Button("Reset new replies") { model.prototypeUnseen = [model.profiles[1].id: 2] }
          } label: {
            Text(variant.uppercased()).font(.caption.weight(.bold))
              .padding(.horizontal, 10).padding(.vertical, 6)
              .background(.yellow, in: Capsule()).foregroundStyle(.black)
          }
          .padding(.trailing, 64).padding(.top, 2)
        }
      }
      .onChange(of: variant) { _, value in
        model.prototypeVariant = value
        path = []
      }
      .task { seed() }
    }

    private func seed() {
      guard !seeded else { return }
      let work = CoordinatorProfile(
        name: try! TagName("Work"), address: try! CoordinatorAddress(host: "100.64.1.2"))
      let personal = CoordinatorProfile(
        name: try! TagName("Personal"), address: try! CoordinatorAddress(host: "100.64.1.3"))
      let many = ProcessInfo.processInfo.environment["AGENT_PROTOTYPE_MANY"] == "1"
      let extra =
        many
        ? ["Home", "Research"].map {
          CoordinatorProfile(
            name: try! TagName($0), address: try! CoordinatorAddress(host: "100.64.1.4"))
        } : []
      model.profiles = [work, personal] + extra
      model.prototypePaired = true
      model.prototypeVariant = variant
      for profile in model.profiles { model.attach(Lane(id: profile.id, session: nil)) }
      var calendar = Calendar.current
      calendar.timeZone = .current
      let day = calendar.startOfDay(for: Date())
      func at(_ hour: Int, _ minute: Int) -> Date {
        day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
      }
      var counter = 0
      func row(
        _ role: HistoryRole, _ text: String, _ time: Date, send: String? = nil,
        tool: String? = nil
      ) -> ChatRow {
        counter += 1
        var row: ChatRow
        if let tool {
          row = ChatRow(
            id: "tool:\(counter)", entryID: "tool:\(counter)", role: .tool, text: "",
            tool: .init(callId: "call\(counter)", name: tool, status: .finished))
        } else {
          row = ChatRow(
            id: "row:\(counter)", role: role, text: text,
            inputID: role == .user ? "in\(counter)" : nil,
            inputOrigin: role == .user ? .ios : nil)
          row.blocks = RichText.prepare([text])[0]
        }
        row.receivedAt = time
        row.sendID = send
        return row
      }
      var w = ChatSnapshot()
      w.connection = .connected
      w.model = "gpt-5.5"
      w.rows = [
        row(.user, "Is the billing retry test still flaky on main?", at(8, 41), send: "w1"),
        row(.tool, "", at(8, 41), tool: "exec"),
        row(.tool, "", at(8, 42), tool: "exec"),
        row(
          .final,
          "Yes. `invoice_retry_backoff` failed 3 of the last 20 runs. It waits on a real 2 second timer, so a slow runner misses the window. I can switch it to the fake clock the other billing tests use.",
          at(8, 43)),
        row(.user, "Heads up, I'm offline 12 to 1 for lunch.", at(9, 5), send: "both"),
        row(.final, "Noted. I'll hold anything that needs you until 1.", at(9, 5)),
        row(
          .user, "Go ahead with the fake clock, then start the 4.2 release checklist.", at(9, 20),
          send: "w2"),
        row(.tool, "", at(9, 21), tool: "exec"),
        row(.tool, "", at(9, 22), tool: "edit"),
        row(.tool, "", at(9, 23), tool: "exec"),
        row(
          .final,
          "The fix is on `fix/billing-fake-clock` and passed 50 runs in a row. For 4.2 the changelog is drafted and the version is bumped. Two items are left: the staging smoke test and QA sign-off.",
          at(9, 24)),
      ]
      w.sends = [
        "w1": SendStatus(recipients: [work.id], progress: .placed),
        "w2": SendStatus(recipients: [work.id], progress: .placed),
        "both": SendStatus(recipients: [work.id, personal.id], progress: .placed),
      ]
      var p = ChatSnapshot()
      p.connection = .connected
      p.model = "claude-sonnet-4.5"
      p.rows = [
        row(.user, "Find a dentist slot next week, after 4 pm if possible.", at(8, 52), send: "p1"),
        row(
          .final,
          "Dr. Alvarez's office has Tuesday at 4:30 pm and Thursday at 5:15 pm. Should I hold Tuesday?",
          at(8, 53)),
        row(.user, "Heads up, I'm offline 12 to 1 for lunch.", at(9, 5), send: "both"),
        row(.final, "Got it. Nothing on your list is due before 1.", at(9, 6)),
        row(
          .user, "Book Tuesday. Also look at lake cabins for the weekend of the 21st.", at(9, 31),
          send: "p2"),
        row(
          .final,
          "Booked Tuesday at 4:30 pm with Dr. Alvarez. I set a reminder for Monday evening.",
          at(9, 33)),
        row(
          .final,
          "Two cabins are open November 21 to 23: **Pine Hollow**, $180 a night, sleeps 4, and **Lakeview Loft**, $215 a night with a dock. Want me to hold one?",
          at(9, 34)),
      ]
      p.sends = [
        "p1": SendStatus(recipients: [personal.id], progress: .placed),
        "p2": SendStatus(recipients: [personal.id], progress: .placed),
        "both": SendStatus(recipients: [work.id, personal.id], progress: .placed),
      ]
      for (index, profile) in extra.enumerated() {
        var x = ChatSnapshot()
        x.connection = .connected
        x.model = "gpt-5.5"
        x.rows = [
          row(
            .final,
            index == 0
              ? "The furnace filter is due this week. I added it to Saturday's list."
              : "The summary of the three caching papers is ready in your notes.",
            at(7, 50 + index * 10))
        ]
        model.apply(x, lane: profile.id)
      }
      model.apply(w, lane: work.id)
      model.apply(p, lane: personal.id)
      let scope: ProfileID? =
        switch initialScope {
        case "work": work.id
        case "personal": personal.id
        default: nil
        }
      model.scope = scope
      model.prototypeUnseen =
        scope == nil && initialScope != "list" ? [:] : [personal.id: 2]
      if scope == personal.id { model.prototypeUnseen = [work.id: 1] }
      if many, scope != nil { model.prototypeUnseen[extra[0].id] = 1 }
      if variant == "v4", initialScope != "list" {
        path = [scope?.description ?? "all"]
      }
      if let draft { model.draft = draft }
      seeded = true
      Task {
        for _ in 0..<10 {
          try? await Task.sleep(for: .milliseconds(300))
          model.revision &+= 1
        }
      }
    }
  }

  struct PrototypeConversationList: View {
    let model: ChatModel
    @Binding var path: [String]
    @Environment(\.colorScheme) private var colorScheme

    private func color(_ index: Int) -> Color {
      let palette: [(Color, Color)] = [
        (Color(red: 0.11, green: 0.31, blue: 0.85), Color(red: 0.38, green: 0.65, blue: 0.98)),
        (Color(red: 0.76, green: 0.25, blue: 0.05), Color(red: 0.98, green: 0.57, blue: 0.24)),
      ]
      return colorScheme == .dark ? palette[index % 2].1 : palette[index % 2].0
    }
    private func time(_ date: Date?) -> String {
      date?.formatted(date: .omitted, time: .shortened) ?? ""
    }
    private func preview(_ row: ChatRow?) -> String {
      guard let row else { return "No messages yet" }
      let text = row.text.replacingOccurrences(of: "**", with: "").replacingOccurrences(
        of: "`", with: "")
      return row.role == .user ? "You: \(text)" : text
    }

    var body: some View {
      NavigationStack {
        List {
          entry(
            key: "all", title: "All coordinators", tint: .primary, symbol: "square.stack.fill",
            latest: model.latestRow(nil), count: 0,
            status: "Work and Personal connected")
          ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
            entry(
              key: profile.id.description, title: profile.name.description, tint: color(index),
              symbol: nil, latest: model.latestRow(profile.id), count: model.unseen(profile.id),
              status: "Connected · \(model.snapshotModel(profile.id))")
          }
        }
        .listStyle(.plain)
        .navigationTitle("Beep Boop")
        .toolbar {
          ToolbarItem(placement: .primaryAction) {
            Button("Connection", systemImage: "slider.horizontal.3") {}.tint(.primary)
          }
        }
      }
      .overlay {
        if let key = path.first {
          MainChatView(model: model).withPrototypeBack {
            withAnimation { path.removeAll() }
          }
          .id(key)
          .transition(.move(edge: .trailing))
        }
      }
    }

    private func entry(
      key: String, title: String, tint: Color, symbol: String?, latest: ChatRow?, count: Int,
      status: String
    ) -> some View {
      Button {
        model.scope = model.profiles.first { $0.id.description == key }?.id
        withAnimation { path = [key] }
      } label: {
        HStack(alignment: .top, spacing: 12) {
          ZStack {
            Circle().fill(tint.opacity(0.15)).frame(width: 44, height: 44)
            if let symbol {
              Image(systemName: symbol).foregroundStyle(tint)
            } else {
              Text(String(title.prefix(1))).font(.headline).foregroundStyle(tint)
            }
          }
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
              Text(title).font(.headline)
              Spacer()
              Text(time(latest?.receivedAt)).font(.subheadline).foregroundStyle(.secondary)
              Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top) {
              Text(preview(latest)).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(2)
              Spacer(minLength: 8)
              if count > 0 {
                Text("\(count)").font(.footnote.weight(.bold)).foregroundStyle(.white)
                  .padding(.horizontal, 8).padding(.vertical, 2).background(.blue, in: Capsule())
              }
            }
            HStack(spacing: 4) {
              Circle().fill(.green).frame(width: 6, height: 6)
              Text(status).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("row-\(title)")
    }
  }
#endif
