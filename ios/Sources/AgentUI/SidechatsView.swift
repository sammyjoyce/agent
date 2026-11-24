import AgentCore
import SwiftUI

extension SidechatNotificationPreference {
  var selectionLabel: String {
    switch self {
    case .inherit: "Same as Main"
    case .on: "On"
    case .off: "Off"
    }
  }

  static let allOptions: [SidechatNotificationPreference] = [.inherit, .on, .off]
}

private struct SidechatListReload: Equatable {
  let lane: ProfileID
  let refresh: UUID
  let ready: Bool
}

private struct CreatedSidechat: Hashable {
  let summary: SidechatSummary
  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.summary.conversationId == rhs.summary.conversationId
  }
  func hash(into hasher: inout Hasher) {
    hasher.combine(summary.conversationId)
  }
}

struct SidechatsListView: View {
  let model: ChatModel
  let lockedLane: Bool
  let notifications: AppNotifications?
  let dictation: Dictation?
  @State private var selectedLane: ProfileID
  @State private var items: [SidechatSummary] = []
  @State private var loaded = false
  @State private var busy = false
  @State private var error: String?
  @State private var refresh = UUID()
  @State private var hasAppeared = false
  @State private var request = UUID()
  @State private var showArchived = false
  @State private var creating = false
  @State private var createdSidechat: CreatedSidechat?

  init(
    model: ChatModel, initialLane: ProfileID?, lockedLane: Bool = false,
    notifications: AppNotifications? = nil, dictation: Dictation? = nil
  ) {
    self.model = model
    self.lockedLane = lockedLane
    self.notifications = notifications
    self.dictation = dictation
    _selectedLane = State(
      initialValue: initialLane ?? model.defaultSidechatLane() ?? ProfileID())
  }

  private var pinned: [SidechatSummary] {
    items.filter { $0.archivedAt == nil && $0.pinned }
  }

  private var active: [SidechatSummary] {
    items.filter { $0.archivedAt == nil && !$0.pinned }
  }

  private var archived: [SidechatSummary] {
    items.filter { $0.archivedAt != nil }
  }

  var body: some View {
    List {
      if model.multiple && !lockedLane {
        Section("Coordinator") {
          Picker("Coordinator", selection: $selectedLane) {
            ForEach(model.profiles) { profile in
              Text(profile.name.description).tag(profile.id)
            }
          }
          .pickerStyle(.menu)
          .accessibilityIdentifier("sidechatsCoordinatorPicker")
        }
      }
      if let error { WorkDiagnosticText(error, identifier: "sidechatsReadError") }
      if !model.sidechatsReady(selectedLane) {
        let targetName = model.multiple ? model.name(selectedLane) : "the coordinator"
        if model.snapshots[selectedLane]?.connection == .connected {
          Text(
            "Side chats unavailable. Update \(targetName) to use standing side chats."
          )
          .font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("sidechatsUnsupportedNotice")
        } else {
          Text(
            "Not connected. Side chats read again when \(targetName) reconnects."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
      }
      if loaded {
        if error == nil, pinned.isEmpty, active.isEmpty {
          Section {
            ContentUnavailableView(
              "No side chats yet",
              systemImage: "bubble.left.and.bubble.right",
              description: Text("Create a standing topic to keep long-running work organized.")
            )
          }
        }
        if !pinned.isEmpty {
          Section("Pinned") {
            ForEach(pinned, id: \.conversationId) { item in sidechatRow(item) }
          }
        }
        if !active.isEmpty {
          Section("Active") {
            ForEach(active, id: \.conversationId) { item in sidechatRow(item) }
          }
        }
        if !archived.isEmpty {
          Section {
            DisclosureGroup("Archived (\(archived.count))", isExpanded: $showArchived) {
              ForEach(archived, id: \.conversationId) { item in sidechatRow(item) }
            }
            .accessibilityIdentifier("archivedSidechatsDisclosure")
          }
        }
      } else if model.sidechatsReady(selectedLane) {
        ProgressView("Reading side chats")
      }
    }
    .navigationTitle(model.laneTitle("Side chats", for: selectedLane))
    .navigationDestination(item: $createdSidechat) { created in
      LaneScreen(model: model, lane: selectedLane) {
        SidechatChatView(
          owner: model, lane: selectedLane, initial: created.summary, notifications: notifications,
          dictation: dictation)
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        Button("Refresh", systemImage: "arrow.clockwise") { refresh = UUID() }
          .disabled(busy)
          .accessibilityIdentifier("refreshSidechats")
        Button("New side chat", systemImage: "plus") { creating = true }
          .disabled(!model.sidechatsReady(selectedLane))
          .accessibilityIdentifier("newSidechatButton")
      }
    }
    .sheet(isPresented: $creating) {
      CreateSidechatSheet(model: model, lane: selectedLane) { created in
        refresh = UUID()
        createdSidechat = CreatedSidechat(summary: created)
      }
    }
    .onChange(of: selectedLane) { _, _ in
      items = []
      loaded = false
      error = nil
      createdSidechat = nil
    }
    .onAppear {
      if hasAppeared { refresh = UUID() }
      hasAppeared = true
    }
    .task(
      id: SidechatListReload(
        lane: selectedLane, refresh: refresh, ready: model.sidechatsReady(selectedLane))
    ) {
      await reload()
    }
    .refreshable { await reload() }
    .accessibilityIdentifier("sidechatsList")
  }

  @ViewBuilder private func sidechatRow(_ item: SidechatSummary) -> some View {
    NavigationLink {
      LaneScreen(model: model, lane: selectedLane) {
        SidechatChatView(
          owner: model, lane: selectedLane, initial: item, notifications: notifications,
          dictation: dictation)
      }
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(verbatim: item.title).font(.headline).lineLimit(1)
          Spacer(minLength: 4)
          if item.pinned {
            Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("Pinned")
          }
          if item.isolated {
            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("Isolated")
          }
          if item.notifications == .on {
            Image(systemName: "bell.fill").font(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("Alerts on")
          } else if item.notifications == .off {
            Image(systemName: "bell.slash").font(.caption).foregroundStyle(.secondary)
              .accessibilityLabel("Alerts off")
          }
        }
        Text(verbatim: item.slug).font(.caption).foregroundStyle(.secondary)
        if let charter = item.charter, !charter.isEmpty {
          Text(verbatim: charter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        WorkTime(item.updatedAt).font(.caption2).foregroundStyle(.tertiary)
      }
      .padding(.vertical, 2)
    }
    .accessibilityIdentifier("sidechat-\(item.slug)")
    .swipeActions(edge: .leading, allowsFullSwipe: true) {
      Button {
        Task { await togglePinned(item) }
      } label: {
        Label(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin")
      }
      .tint(.orange)
    }
    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
      Button {
        Task { await toggleArchived(item) }
      } label: {
        Label(
          item.archivedAt == nil ? "Archive" : "Unarchive",
          systemImage: item.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
      }
      .tint(.indigo)
    }
    .contextMenu {
      Button(item.pinned ? "Unpin" : "Pin", systemImage: item.pinned ? "pin.slash" : "pin") {
        Task { await togglePinned(item) }
      }
      Button(
        item.archivedAt == nil ? "Archive" : "Unarchive",
        systemImage: item.archivedAt == nil ? "archivebox" : "tray.and.arrow.up"
      ) {
        Task { await toggleArchived(item) }
      }
    }
  }

  private func reload() async {
    guard model.sidechatsReady(selectedLane) else { return }
    let id = UUID()
    request = id
    busy = true
    error = nil
    defer { if request == id { busy = false } }
    do {
      let list = try await model.listSidechats(includeArchived: true, lane: selectedLane)
      guard request == id, !Task.isCancelled else { return }
      items = list
      loaded = true
    } catch LaneError.interrupted {
      if request == id, !Task.isCancelled {
        loaded = true
        self.error = "Reading side chats was interrupted. Tap Refresh to try again."
      }
      return
    } catch {
      guard request == id, !Task.isCancelled else { return }
      loaded = true
      self.error = error.localizedDescription
    }
  }

  private func togglePinned(_ item: SidechatSummary) async {
    do {
      _ = try await model.updateSidechat(
        .init(conversationId: item.conversationId, pinned: !item.pinned), lane: selectedLane)
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func toggleArchived(_ item: SidechatSummary) async {
    do {
      _ = try await model.updateSidechat(
        .init(archived: item.archivedAt == nil, conversationId: item.conversationId),
        lane: selectedLane)
      await reload()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

private struct SidechatFormFields: View {
  @Binding var title: String
  @Binding var slug: String
  @Binding var charter: String
  @Binding var isolated: Bool
  @Binding var alerts: SidechatNotificationPreference
  var pinned: Binding<Bool>? = nil
  var slugPlaceholder: String
  var charterFooter: String? = nil
  var behaviorFooter: String? = nil
  var mainAlertsEnabled: Bool? = nil
  var titleIdentifier: String
  var slugIdentifier: String
  var charterIdentifier: String
  var isolatedIdentifier: String
  var notificationsIdentifier: String
  var pinnedIdentifier: String? = nil

  var body: some View {
    Section("Topic") {
      TextField("Title", text: $title)
        .accessibilityIdentifier(titleIdentifier)
      TextField(slugPlaceholder, text: $slug)
        #if os(iOS)
          .textInputAutocapitalization(.never)
        #endif
        .autocorrectionDisabled()
        .accessibilityIdentifier(slugIdentifier)
      if let pinned {
        Toggle("Pinned", isOn: pinned)
          .accessibilityIdentifier(pinnedIdentifier ?? "editSidechatPinnedToggle")
      }
    }
    Section {
      TextField("Standing instructions for this topic (optional)", text: $charter, axis: .vertical)
        .lineLimit(3...8)
        .accessibilityIdentifier(charterIdentifier)
    } header: {
      Text("Charter")
    } footer: {
      if let charterFooter { Text(charterFooter) }
    }
    Section {
      Toggle("Isolate from Main search", isOn: $isolated)
        .accessibilityIdentifier(isolatedIdentifier)
      Picker("Push notifications", selection: $alerts) {
        ForEach(SidechatNotificationPreference.allOptions, id: \.self) { option in
          Text(option.selectionLabel).tag(option)
        }
      }
      .accessibilityIdentifier(notificationsIdentifier)
      if let enabled = mainAlertsEnabled {
        Text(
          alerts == .inherit
            ? "Following Main-chat updates (currently \(enabled ? "On" : "Off"))."
            : alerts == .on
              ? "Always push replies from this topic, even when Main alerts are Off."
              : "Never push replies from this topic."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    } footer: {
      if let behaviorFooter { Text(behaviorFooter) }
    }
  }
}

struct CreateSidechatSheet: View {
  let model: ChatModel
  let lane: ProfileID
  var seed: ReplyReference? = nil
  let onCreated: (SidechatSummary) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var slug = ""
  @State private var charter = ""
  @State private var handoff = ""
  @State private var isolated = false
  @State private var alerts: SidechatNotificationPreference = .inherit
  @State private var saving = false
  @State private var error: String?

  var body: some View {
    NavigationStack {
      Form {
        SidechatFormFields(
          title: $title, slug: $slug, charter: $charter, isolated: $isolated, alerts: $alerts,
          slugPlaceholder: "Slug (optional)",
          charterFooter:
            "Applied to every turn in this side chat alongside your coordinator instructions.",
          behaviorFooter:
            "Shared side chats can be recalled from Main and tasks. Push notifications default to your Main setting and can be turned On or Off per topic.",
          titleIdentifier: "sidechatTitleField", slugIdentifier: "sidechatSlugField",
          charterIdentifier: "sidechatCharterField", isolatedIdentifier: "sidechatIsolatedToggle",
          notificationsIdentifier: "sidechatNotificationsPicker")
        Section("Handoff note (optional)") {
          TextField("Initial context or task handoff", text: $handoff, axis: .vertical)
            .lineLimit(2...6)
            .accessibilityIdentifier("sidechatHandoffField")
        }
        if let seed {
          Section("Linked from Main") {
            Text(verbatim: seed.excerpt).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
          }
        }
        if let error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("createSidechatError")
          }
        }
      }
      .navigationTitle("New side chat")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { Task { await create() } }
            .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("confirmCreateSidechat")
        }
      }
    }
  }

  private func create() async {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty, !saving else { return }
    saving = true
    error = nil
    defer { saving = false }
    let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCharter = charter.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedHandoff = handoff.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      let created = try await model.createSidechat(
        .init(
          charter: trimmedCharter.isEmpty ? nil : trimmedCharter,
          handoff: trimmedHandoff.isEmpty ? nil : trimmedHandoff,
          isolated: isolated,
          notifications: alerts,
          seed: seed,
          slug: trimmedSlug.isEmpty ? nil : trimmedSlug,
          title: trimmedTitle),
        lane: lane)
      dismiss()
      onCreated(created)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct SidechatSettingsSheet: View {
  let owner: ChatModel
  let lane: ProfileID
  let sidechatModel: ChatModel
  let sidechat: SidechatSummary
  let notifications: AppNotifications?
  @Environment(\.dismiss) private var dismiss
  @State private var title: String
  @State private var slug: String
  @State private var charter: String
  @State private var pinned: Bool
  @State private var isolated: Bool
  @State private var archived: Bool
  @State private var alerts: SidechatNotificationPreference
  @State private var saving = false
  @State private var error: String?

  init(
    owner: ChatModel, lane: ProfileID, sidechatModel: ChatModel, sidechat: SidechatSummary,
    notifications: AppNotifications? = nil
  ) {
    self.owner = owner
    self.lane = lane
    self.sidechatModel = sidechatModel
    self.sidechat = sidechat
    self.notifications = notifications
    _title = State(initialValue: sidechat.title)
    _slug = State(initialValue: sidechat.slug)
    _charter = State(initialValue: sidechat.charter ?? "")
    _pinned = State(initialValue: sidechat.pinned)
    _isolated = State(initialValue: sidechat.isolated)
    _archived = State(initialValue: sidechat.archivedAt != nil)
    _alerts = State(initialValue: sidechat.notifications)
  }

  private var hasChanges: Bool {
    title.trimmingCharacters(in: .whitespacesAndNewlines) != sidechat.title
      || slug.trimmingCharacters(in: .whitespacesAndNewlines) != sidechat.slug
      || charter.trimmingCharacters(in: .whitespacesAndNewlines) != (sidechat.charter ?? "")
      || pinned != sidechat.pinned
      || isolated != sidechat.isolated
      || archived != (sidechat.archivedAt != nil)
      || alerts != sidechat.notifications
  }

  private var canSave: Bool {
    !saving && hasChanges
      && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !slug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    NavigationStack {
      Form {
        SidechatFormFields(
          title: $title, slug: $slug, charter: $charter, isolated: $isolated, alerts: $alerts,
          pinned: $pinned, slugPlaceholder: "Slug",
          mainAlertsEnabled: notifications?.registration.enabled,
          titleIdentifier: "editSidechatTitleField", slugIdentifier: "editSidechatSlugField",
          charterIdentifier: "editSidechatCharterField",
          isolatedIdentifier: "editSidechatIsolatedToggle",
          notificationsIdentifier: "editSidechatNotificationsPicker",
          pinnedIdentifier: "editSidechatPinnedToggle")
        if sidechatModel.snapshots[lane]?.settingsSupported == true {
          Section("Model") {
            NavigationLink("Conversation settings") {
              ConversationSettingsView(model: sidechatModel, lane: lane)
            }
            .accessibilityIdentifier("sidechatModelSettingsLink")
          }
        }
        Section {
          Toggle("Archived", isOn: $archived)
            .accessibilityIdentifier("editSidechatArchivedToggle")
        } footer: {
          Text("Scheduled jobs or posts sent to an archived side chat automatically unarchive it.")
        }
        if let error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("editSidechatError")
          }
        }
      }
      .navigationTitle("Side chat settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(!canSave)
            .accessibilityIdentifier("saveSidechatSettings")
        }
      }
    }
  }

  private func save() async {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSlug = slug.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedCharter = charter.trimmingCharacters(in: .whitespacesAndNewlines)
    let oldCharter = sidechat.charter ?? ""
    guard !trimmedTitle.isEmpty, !trimmedSlug.isEmpty, !saving else { return }
    saving = true
    error = nil
    defer { saving = false }
    let request = NativeRequestUpdateSidechat(
      archived: archived != (sidechat.archivedAt != nil) ? archived : nil,
      charter: trimmedCharter != oldCharter && !trimmedCharter.isEmpty ? trimmedCharter : nil,
      clearCharter: !oldCharter.isEmpty && trimmedCharter.isEmpty ? true : nil,
      conversationId: sidechat.conversationId,
      isolated: isolated != sidechat.isolated ? isolated : nil,
      notifications: alerts != sidechat.notifications ? alerts : nil,
      pinned: pinned != sidechat.pinned ? pinned : nil,
      slug: trimmedSlug != sidechat.slug ? trimmedSlug : nil,
      title: trimmedTitle != sidechat.title ? trimmedTitle : nil)
    do {
      let updated = try await owner.updateSidechat(request, lane: lane)
      await sidechatModel.applyLocalSidechatUpdate(updated)
      dismiss()
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct SidechatChatView: View {
  let owner: ChatModel
  let lane: ProfileID
  let initial: SidechatSummary
  let notifications: AppNotifications?
  let dictation: Dictation?
  @State private var model: ChatModel
  @State private var presenceToken = UUID()

  init(
    owner: ChatModel, lane: ProfileID, initial: SidechatSummary,
    notifications: AppNotifications? = nil, dictation: Dictation? = nil
  ) {
    self.owner = owner
    self.lane = lane
    self.initial = initial
    self.notifications = notifications
    self.dictation = dictation
    _model = State(initialValue: ChatModel(sidechat: initial))
  }

  private var entityID: ScopedEntityID {
    ScopedEntityID(profile: lane, item: initial.conversationId)
  }

  var body: some View {
    MainChatView(
      sidechatModel: model, sidechatOwner: owner, sidechatLane: lane,
      sidechatNotifications: notifications, dictation: dictation
    )
    .onAppear { notifications?.setActiveSidechat(entityID, token: presenceToken) }
    .onDisappear {
      dictation?.stop(for: model)
      notifications?.clearActiveSidechat(token: presenceToken)
    }
    .task {
      await model.connectSidechat(using: owner, lane: lane, sidechat: initial)
      await model.runUntilCancelled()
    }
  }
}

private struct SidechatRouteReload: Equatable {
  let ready: Bool
  let token: UUID
}

struct SidechatRouteLoaderView: View {
  let owner: ChatModel
  let lane: ProfileID
  let conversationID: String
  let notifications: AppNotifications?
  let dictation: Dictation?
  @State private var sidechat: SidechatSummary?
  @State private var error: String?
  @State private var missing = false
  @State private var reloadToken = UUID()

  var body: some View {
    Group {
      if let sidechat {
        SidechatChatView(
          owner: owner, lane: lane, initial: sidechat, notifications: notifications,
          dictation: dictation)
      } else if missing {
        ContentUnavailableView(
          "Side chat not found",
          systemImage: "bubble.left.and.bubble.right",
          description: Text(
            "Conversation \(conversationID) could not be found on this coordinator.")
        )
      } else if let error {
        VStack(spacing: 12) {
          WorkDiagnosticText(error, identifier: "sidechatRouteError")
          Button("Try again") { reloadToken = UUID() }
        }
        .padding()
      } else if !owner.sidechatsReady(lane) {
        if owner.snapshots[lane]?.connection == .connected {
          ContentUnavailableView(
            "Side chats unavailable",
            systemImage: "bubble.left.and.bubble.right",
            description: Text("Update the coordinator to open standing side chats.")
          )
        } else {
          ContentUnavailableView(
            "Not connected",
            systemImage: "wifi.slash",
            description: Text(
              "This side chat opens when \(owner.multiple ? owner.name(lane) : "the coordinator") reconnects."
            )
          )
        }
      } else {
        ProgressView("Opening side chat…")
      }
    }
    .task(id: SidechatRouteReload(ready: owner.sidechatsReady(lane), token: reloadToken)) {
      guard sidechat == nil, owner.sidechatsReady(lane) else { return }
      await load()
    }
  }

  private func load() async {
    error = nil
    missing = false
    do {
      let list = try await owner.listSidechats(includeArchived: true, lane: lane)
      if let match = list.first(where: { $0.conversationId == conversationID }) {
        sidechat = match
      } else {
        missing = true
      }
    } catch LaneError.interrupted {
      return
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
  }
}
