import AgentCore
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
  import PhotosUI
  import QuickLook
#endif

public struct MainChatView: View {
  @State private var model: ChatModel
  @State private var activityExpansion = ActivityExpansion()
  private let coordinators: Coordinators?
  private let detailLoader: ToolDetailsLoader?
  private let initialScrollTarget: String?
  private let notifications: AppNotifications?
  @State private var settings = false
  @State private var sourceDetails = false
  @State private var followsLatest = true
  @State private var userScrolling = false
  @State private var atTop = false
  @State private var latestVisible = true
  @State private var presentedLatest = false
  @State private var visibleItem: String?
  @State private var historyRequest: HistoryNavigation?
  @State private var importingFiles = false
  #if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var capture = AppScreenshot()
  #endif
  @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.displayScale) private var displayScale

  public init(notifications: AppNotifications) {
    _model = State(initialValue: notifications.coordinators.chat)
    coordinators = notifications.coordinators
    detailLoader = nil
    initialScrollTarget = nil
    self.notifications = notifications
  }
  // Previews and hosted rendering use the real screen with a seeded model,
  // without taking ownership of a live connection or the user's saved address.
  init(
    model: ChatModel, expansion: ActivityExpansion = ActivityExpansion(),
    details: ToolDetailsLoader? = nil, initialScrollTarget: String? = nil
  ) {
    _model = State(initialValue: model)
    _activityExpansion = State(initialValue: expansion)
    coordinators = nil
    detailLoader = details
    self.initialScrollTarget = initialScrollTarget
    notifications = nil
    _followsLatest = State(initialValue: initialScrollTarget == nil)
  }
  public var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if model.multiple {
          ForEach(model.profiles) { profile in laneStatus(profile) }
        } else if let status = connectionStatus {
          HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text(status).font(.footnote).foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16).padding(.vertical, 8)
        }
        ForEach(model.sourceReports.filter { $0.warning != nil }) { report in
          Button {
            sourceDetails = true
          } label: {
            HStack {
              Label {
                model.multiple
                  ? badge(report.id).title + Text(" \(report.warning ?? "")")
                  : Text(report.warning ?? "")
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              Spacer(minLength: 8)
              Image(systemName: "chevron.right").font(.caption)
            }
            .font(.footnote).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(.orange.opacity(0.1), ignoresSafeAreaEdges: [])
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("sourceCoverageWarning")
          .accessibilityHint("Show source accounts and errors")
        }
        transcript
        if let error = composerError {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel("Error. \(error)")
            if !model.multiple, unpaired != nil || model.connection != .connected {
              Button("Try again") { tryAgain() }.font(.callout)
            }
          }
          .padding(.horizontal).padding(.vertical, 8)
        }
      }
      .background(.background)
      .safeAreaInset(edge: .bottom, spacing: 0) { composer }
      .navigationTitle("Agent")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(uiColor: .systemBackground), for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
      #endif
      .toolbar {
        ToolbarItem(placement: .principal) {
          VStack(spacing: 1) {
            Text("Agent").font(.headline)
            Text(
              model.multiple
                ? joinedNames(model.profiles.map(\.name.description))
                : model.model.split(separator: "/").last.map(String.init) ?? model.model
            )
            .font(.caption).foregroundStyle(.primary.opacity(0.65)).lineLimit(1)
          }.accessibilityElement(children: .combine)
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Connection", systemImage: "slider.horizontal.3") { settings = true }
            .tint(.primary)
        }
      }
      .sheet(isPresented: $settings) {
        connectionSettings.preferredColorScheme(appearance.colorScheme)
      }
      .sheet(isPresented: $sourceDetails) {
        NavigationStack {
          SourceDetailsView(model: model)
            .toolbar {
              ToolbarItem(placement: .confirmationAction) {
                Button("Done") { sourceDetails = false }
              }
            }
        }.preferredColorScheme(appearance.colorScheme)
      }
      .fileImporter(
        isPresented: $importingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true
      ) { result in
        switch result {
        case .success(let urls): Task { await model.attach(urls: urls) }
        case .failure(let error): model.failure = error.localizedDescription
        }
      }
      .dropDestination(for: URL.self) { urls, _ in
        guard !urls.isEmpty else { return false }
        Task { await model.attach(urls: urls) }
        return true
      }
      #if os(iOS)
        .background(ScreenshotAnchor(capture: capture).frame(width: 0, height: 0))
        .quickLookPreview($model.previewURL)
        .onChange(of: selectedPhoto) { _, photo in
          guard let photo else { return }
          Task {
            defer { selectedPhoto = nil }
            await model.attach(photo: photo)
          }
        }
      #endif
      .task {
        // With nothing saved, start on the Add form.
        if coordinators?.profiles.isEmpty == true { settings = true }
      }
      .onChange(of: scenePhase) { _, _ in notifications?.mainVisible = mainVisible }
      .onAppear { notifications?.mainVisible = mainVisible }
      .onDisappear { notifications?.mainVisible = false }
      .onChange(of: settings) { _, _ in notifications?.mainVisible = mainVisible }
      .onChange(of: sourceDetails) { _, _ in notifications?.mainVisible = mainVisible }
      .onChange(of: notifications?.openedTarget) { _, target in
        if target != nil {
          settings = false
          sourceDetails = false
          followsLatest = true
        }
      }
    }
    .preferredColorScheme(appearance.colorScheme)
  }
  private var mainVisible: Bool { scenePhase == .active && !settings && !sourceDetails }
  /// A saved profile that is not paired yet. It shows its held messages and takes no sends.
  private var unpaired: CoordinatorProfile? { coordinators?.profiles.first { $0.pin == nil } }
  /// The error under the feed. With one coordinator saved, an unpaired one's pairing error stands
  /// in for the composer's latest failure, after what the composer reported.
  private var composerError: String? {
    guard !model.multiple, let pairing = unpaired.flatMap({ coordinators?.pairingError[$0.id] })
    else { return model.error }
    return (model.reports + [pairing]).joined(separator: " ")
  }
  private var connectionStatus: String? {
    if let unpaired, coordinators?.pairingError[unpaired.id] == nil {
      return ConnectionState.connecting.label
    }
    return model.connection == .connecting || model.connection == .reconnecting
      ? model.connection.label : nil
  }
  private func tryAgain() {
    if let unpaired, let coordinators {
      coordinators.retryPairing(unpaired.id)
    } else {
      Task { await model.reconnect() }
    }
  }
  /// Each coordinator's name and color, with two or more saved. Empty otherwise, which keeps
  /// the one-coordinator feed as it was.
  private var badges: [ProfileID: CoordinatorBadge] {
    guard model.multiple else { return [:] }
    return Dictionary(
      model.profiles.enumerated().map { index, profile in
        (
          profile.id,
          CoordinatorBadge(
            name: profile.name.description,
            color: colorScheme == .dark
              ? coordinatorPalette[index % 4].dark : coordinatorPalette[index % 4].light)
        )
      }, uniquingKeysWith: { first, _ in first })
  }
  private func badge(_ id: ProfileID) -> CoordinatorBadge {
    badges[id] ?? CoordinatorBadge(name: model.name(id), color: .secondary)
  }
  /// Why a coordinator needs a line above the feed, or nil while it is connected and quiet.
  private func laneState(_ profile: CoordinatorProfile) -> (
    message: String, waiting: Bool, retry: Bool
  )? {
    guard model.paired(profile.id) else {
      if let error = coordinators?.pairingError[profile.id] { return (error, false, true) }
      return (ConnectionState.connecting.label, true, false)
    }
    guard let snapshot = model.snapshots[profile.id] else {
      return (ConnectionState.connecting.label, true, false)
    }
    if let error = snapshot.error { return (error, false, snapshot.connection != .connected) }
    switch snapshot.connection {
    case .connected: return nil
    case .connecting, .reconnecting: return (snapshot.connection.label, true, false)
    case .disconnected: return (snapshot.connection.label, false, true)
    }
  }
  @ViewBuilder private func laneStatus(_ profile: CoordinatorProfile) -> some View {
    if let state = laneState(profile) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        (badge(profile.id).title + Text(" \(state.message)").foregroundStyle(.secondary))
          .font(.footnote).fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("\(profile.name.description). \(state.message)")
        if state.waiting { ProgressView().controlSize(.mini) }
        if state.retry {
          Button("Try again") {
            if !model.paired(profile.id), let coordinators {
              coordinators.retryPairing(profile.id)
            } else {
              Task { await model.reconnect(profile.id) }
            }
          }
          .font(.footnote).accessibilityLabel("Try \(profile.name.description) again")
        }
      }
      .padding(.horizontal, 16).padding(.vertical, 6)
    }
  }
  private var transcript: some View {
    let items = model.transcriptItems
    let starts = model.multiple ? TranscriptItem.runStarts(items) : []
    let badges = badges
    return ScrollViewReader { scroll in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          // Pagination is section structure, not transcript content. Keep
          // one lazy layout so explicit row targets remain discoverable.
          Section {
            if model.rows.isEmpty && model.held.isEmpty {
              Text("No messages yet").font(.callout).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).padding(.vertical, 32)
            }
            if let heldError = model.heldError {
              Text(heldError).font(.callout).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(model.held) { message in
              HeldMessageRow(
                message: message, restore: { Task { await model.restoreHeld(message) } },
                discard: { Task { await model.discardHeld(message) } })
            }
            ForEach(items) { item in
              Group {
                if starts.contains(item.id), let lane = item.lane, let badge = badges[lane] {
                  VStack(alignment: .leading, spacing: 6) {
                    badge.title.font(.footnote).accessibilityLabel("From \(badge.name)")
                    transcriptItem(item, badges: badges)
                  }
                } else {
                  transcriptItem(item, badges: badges)
                }
              }
              .id(item.id)
            }
          } header: {
            if model.canLoadEarlier {
              Button {
                requestHistory()
              } label: {
                HStack {
                  if model.loadingHistory { ProgressView().controlSize(.small) }
                  Text("Load earlier messages")
                }
              }
              .disabled(model.loadingHistory).frame(maxWidth: .infinity).padding(.vertical)
              .id(TranscriptControlAnchor.earlier)
              .onScrollVisibilityChange(threshold: 0.1) { visible in
                // Initial/live-tail layout is not an instruction to page backward.
                if visible && presentedLatest && !followsLatest { requestHistory() }
              }
            }
          }
          if model.busy {
            HStack(spacing: 8) {
              ProgressView().controlSize(.mini)
              Text("Working…").font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
              .accessibilityLabel("Agent is working")
          }
          Color.clear.frame(height: 1).id(TranscriptControlAnchor.latest)
        }
        .scrollTargetLayout()
        .padding().frame(maxWidth: 720).frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier("transcript")
      .scrollDismissesKeyboard(.interactively)
      .scrollBounceBehavior(.always, axes: .vertical)
      .defaultScrollAnchor(initialScrollTarget == nil ? .bottom : .top, for: .initialOffset)
      .scrollPosition(
        id: Binding(
          // Following the latest, code scrolls without updating this binding, so a row here would
          // be out of date. Opening the picker reapplies it and would scroll back to that row.
          get: { followsLatest ? nil : visibleItem },
          set: { item in
            // Structural controls have no transcript row ID. Keep the real
            // reading anchor when a paging control temporarily leads.
            if let item { visibleItem = item }
          }), anchor: .top
      )
      .task {
        if let initialScrollTarget {
          await Task.yield()
          scroll.scrollTo(initialScrollTarget, anchor: .top)
        }
      }
      .task(id: historyRequest) {
        guard let request = historyRequest else { return }
        switch request {
        case .earlier(_, let anchorID): await model.history(anchorID: anchorID)
        case .latest: await model.latestHistory()
        }
        if !Task.isCancelled { historyRequest = nil }
      }
      .onScrollPhaseChange { _, phase in
        userScrolling = phase == .interacting || phase == .decelerating
        if userScrolling {
          followsLatest = latestVisible
          if atTop { requestHistory() }
        }
      }
      .onScrollGeometryChange(for: TranscriptEdges.self) { geometry in
        TranscriptEdges(
          top: geometry.contentOffset.y + geometry.contentInsets.top <= 80,
          latest: geometry.visibleRect.maxY >= geometry.contentSize.height - 1 / displayScale)
      } action: { _, current in
        atTop = current.top
        latestVisible = current.latest
        if current.latest && !model.rows.isEmpty { presentedLatest = true }
        // Layout and keyboard changes must not stop following a live
        // conversation. A person's scroll may leave the visible tail.
        if userScrolling || current.latest { followsLatest = current.latest }
      }
      .onChange(of: model.revision) { _, _ in
        if followsLatest { scroll.scrollTo(TranscriptControlAnchor.latest, anchor: .bottom) }
      }
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.containerSize.height
      } action: { old, new in
        // A taller composer, such as one opening the picker, makes the feed shorter. SwiftUI keeps
        // its bottom in view for a short feed but not for a long one.
        if new < old && followsLatest && !userScrolling {
          scroll.scrollTo(TranscriptControlAnchor.latest, anchor: .bottom)
        }
      }
      .onChange(of: notifications?.openedTarget) { _, target in
        if target != nil { scroll.scrollTo(TranscriptControlAnchor.latest, anchor: .bottom) }
      }
      .overlay(alignment: .bottomTrailing) {
        if (!latestVisible || !model.includesLatest) && !model.rows.isEmpty {
          Button("Latest", systemImage: "arrow.down") {
            followsLatest = true
            historyRequest = .latest(UUID())
            if reduceMotion {
              scroll.scrollTo(TranscriptControlAnchor.latest, anchor: .bottom)
            } else {
              withAnimation { scroll.scrollTo(TranscriptControlAnchor.latest, anchor: .bottom) }
            }
          }
          .accessibilityIdentifier("latest-messages")
          .buttonStyle(.borderedProminent).tint(.primary)
          .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
          .clipShape(Capsule()).padding()
        }
      }
    }
  }
  private func requestHistory() {
    guard historyRequest == nil, !model.loadingHistory, model.canLoadEarlier else { return }
    followsLatest = false
    let anchor =
      model.transcriptItems.first(where: { $0.id == visibleItem })
      ?? model.transcriptItems.first
    historyRequest = .earlier(UUID(), anchorID: anchor?.anchorID)
  }
  @ViewBuilder private func transcriptItem(
    _ item: TranscriptItem, badges: [ProfileID: CoordinatorBadge]
  ) -> some View {
    switch item {
    case .message(let row):
      MessageRow(
        model: row, retry: { id in Task { await model.retry(id) } },
        restore: { id in Task { await model.restore(id) } },
        discard: { id in Task { await model.discard(id) } },
        preview: { file in Task { await model.preview(file, lane: row.lane) } },
        badges: badges)
    case .activity(let group):
      ActivityGroupView(
        group: group, expansion: $activityExpansion,
        details: { row in try await loadDetails(row, lane: group.lane) },
        onExpand: { followsLatest = false })
    }
  }
  private func loadDetails(_ row: ChatRow, lane: ProfileID?) async throws -> ToolDetails {
    if let detailLoader { return try await detailLoader(row) }
    return try await model.toolDetails(for: row, lane: lane)
  }
  private var showsStop: Bool {
    model.busy && model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && model.attachments.isEmpty
  }
  private var composer: some View {
    VStack(spacing: 6) {
      if !model.pickerMatches.isEmpty { picker }
      if !model.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(model.attachments) { file in
              HStack(spacing: 0) {
                AttachmentLabel(reference: file.reference)
                Button("Remove \(file.reference.name)", systemImage: "xmark.circle.fill") {
                  Task { await model.removeAttachment(file) }
                }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .disabled(model.admitting)
              }
            }
          }
        }
      }
      HStack(alignment: .bottom, spacing: 4) {
        Menu {
          Section("Attachments") {
            Button("Choose files", systemImage: "folder") { importingFiles = true }
            #if os(iOS)
              PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose photo", systemImage: "photo")
              }
            #endif
          }.disabled(
            model.preparingAttachments || model.attachments.count >= AttachmentLimits.maximumCount)
          Menu("Commands", systemImage: "command") {
            ForEach(model.commands, id: \.usage) { command in
              Button {
                model.draft = String(command.usage.prefix(while: { !$0.isWhitespace })) + " "
              } label: {
                Text(command.usage)
                Text(command.description)
              }
            }
          }.disabled(model.commands.isEmpty)
          Picker("Delivery", selection: $model.mode) {
            Text("Steer").tag(InputMode.steer)
            Text("Follow-up").tag(InputMode.followUp)
          }.pickerStyle(.inline)
          if model.busy {
            Button("Stop response", systemImage: "stop.fill") { Task { await model.interrupt() } }
          }
        } label: {
          Image(systemName: "plus").font(.system(size: 19, weight: .regular))
            .frame(width: 44, height: 44).contentShape(Circle())
        }
        .tint(.primary).accessibilityLabel("Add attachments or commands")
        .accessibilityIdentifier("composerMenu")
        Group {
          #if os(iOS)
            draftField
          #else
            // Top-aligned, so a wrapping draft's first line stays beside the chip.
            HStack(alignment: .top, spacing: 4) {
              if let recipient = model.shownChip { chip(recipient) }
              // A key that leaves the text as it was, such as one finishing an inline
              // prediction, gets no field update, and SwiftUI then drops the next change made in
              // code, such as Send's clear. A new binding each render gives the field that update.
              TextField(
                placeholder, text: Binding(get: { model.draft }, set: { model.draft = $0 }),
                axis: .vertical
              )
              .lineLimit(1...6).textFieldStyle(.plain).padding(.vertical, 11)
              .padding(.horizontal, 2)
              .accessibilityLabel("Message the coordinator").accessibilityIdentifier(
                "Message the coordinator")
            }
          #endif
        }
        // The field drops a rewrite made inside its own write, so the tag moves after it.
        .onChange(of: model.draft) { model.promoteTypedTag() }
        Button {
          let stop = showsStop
          Task {
            if stop {
              await model.interrupt()
            } else {
              #if os(iOS)
                await model.send(screenshot: capture.png)
              #else
                await model.send()
              #endif
            }
          }
        } label: {
          Group {
            if model.admitting || model.preparingAttachments {
              ProgressView().tint(colorScheme == .dark ? .black : .white)
            } else {
              Image(systemName: showsStop ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
            }
          }
          .foregroundStyle(.background).frame(width: 32, height: 32)
          .background(.primary, in: Circle()).opacity(showsStop || model.canSend ? 1 : 0.25)
          .frame(width: 44, height: 44).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(showsStop ? model.connection != .connected : !model.canSend)
        .accessibilityLabel(
          showsStop ? "Stop response" : model.mode == .steer ? "Send message" : "Queue follow-up")
      }
      .padding(5)
      .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 26))
      .overlay {
        RoundedRectangle(cornerRadius: 26).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
      }
      if model.addressesByName {
        // With the picker open the tag is still being typed, which is not an error.
        let blocked =
          if case .blocked = model.addressing, model.pickerMatches.isEmpty { true } else { false }
        Text(model.recipientLine).font(.footnote)
          .foregroundStyle(blocked ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
          .accessibilityIdentifier("recipientLine")
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8).background(.background)
  }
  private var placeholder: String {
    model.mode == .steer ? "Message Agent" : "Queue a follow-up"
  }
  #if os(iOS)
    /// The draft with the chip on its first line, like a word typed there.
    private var draftField: some View {
      ComposerField(
        text: model.draft, placeholder: placeholder,
        chip: model.shownChip.map {
          let badge = badge($0)
          return .init(name: badge.name, color: UIColor(badge.color))
        }, promotion: model.promotion, edit: { model.draft = $0 },
        removeChip: { model.recipient = nil })
    }
  #else
    private func chip(_ recipient: ProfileID) -> some View {
      let badge = badge(recipient)
      return Button {
        model.recipient = nil
      } label: {
        HStack(spacing: 3) {
          Text("@\(badge.name)").fontWeight(.semibold)
          Image(systemName: "xmark.circle.fill").font(.caption)
        }
        // The field's vertical padding, so the chip's text shares its first line.
        .padding(.vertical, 11).foregroundStyle(badge.color).frame(minHeight: 44)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("To \(badge.name)")
      .accessibilityHint("Removes the recipient, so the message goes to every coordinator.")
    }
  #endif
  /// Saved names matching an `@` being typed. Choosing one sets the composer's recipient.
  private var picker: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(model.pickerMatches) { profile in
        Button {
          model.choose(profile.id)
        } label: {
          HStack(spacing: 10) {
            Circle().fill(badge(profile.id).color).frame(width: 8, height: 8)
            Text(profile.name.description).foregroundStyle(.primary)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .padding(.horizontal, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel("Send to \(profile.name.description)")
      }
    }
    .padding(6).frame(maxWidth: 220)
    .background(.background, in: RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 44)
  }
  private var connectionSettings: some View {
    NavigationStack {
      Form {
        Section {
          if !model.multiple {
            LabeledContent("Status", value: model.connection.label)
            LabeledContent("Model", value: model.model)
          }
          NavigationLink("Sources") { SourceDetailsView(model: model) }
          Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { appearance in
              Text(appearance.label).tag(appearance)
            }
          }
          .pickerStyle(.menu).tint(.primary).accessibilityIdentifier("appearancePicker")
        }
        if let coordinators {
          if model.multiple {
            Section("Coordinators") {
              ForEach(coordinators.profiles) { profile in
                NavigationLink {
                  Form {
                    CoordinatorForm(coordinators: coordinators, profile: profile, pushed: true)
                  }
                  .navigationTitle(profile.name.description)
                } label: {
                  VStack(alignment: .leading, spacing: 2) {
                    badge(profile.id).title
                    Text(laneState(profile)?.message ?? ConnectionState.connected.label)
                      .font(.footnote).foregroundStyle(.secondary)
                  }
                  .accessibilityElement(children: .combine)
                }
              }
              addCoordinator(coordinators)
            }
          } else {
            CoordinatorForm(
              coordinators: coordinators, profile: coordinators.profiles.first, pushed: false)
            if !coordinators.profiles.isEmpty { addCoordinator(coordinators) }
          }
        }
        if let registration = notifications?.registration {
          let channel = coordinators?.profiles.first.map { registration.status($0.id) }
          Section {
            Toggle(
              "Main-chat updates",
              isOn: Binding(
                get: { registration.enabled },
                set: { value in Task { await registration.setEnabled(value) } }
              )
            )
            .disabled(registration.busy)
            if model.multiple {
              if let error = registration.error {
                Text(error).font(.footnote).foregroundStyle(.primary)
              }
              ForEach(model.profiles) { profile in
                if let hint = alertHint(registration, profile.id) {
                  Text("\(profile.name.description): \(hint)").font(.footnote)
                }
              }
              if !registration.enabled,
                model.profiles.contains(where: { registration.status($0.id).registered })
              {
                Button("Retry removing this device") {
                  Task { await registration.setEnabled(false) }
                }.disabled(registration.busy)
              }
            } else if let error = registration.error ?? channel?.error {
              Text(error).font(.footnote).foregroundStyle(.primary)
              if !registration.enabled, channel?.registered == true {
                Button("Retry removing this device") {
                  Task { await registration.setEnabled(false) }
                }.disabled(registration.busy)
              }
            } else if model.connection != .connected {
              Text("Connect to the coordinator to receive updates.").font(.footnote)
            } else if channel?.configured != true {
              Text("APNs setup is required on the coordinator.").font(.footnote)
            } else if registration.enabled, channel?.registered != true {
              Text("Waiting for this device's Apple registration.").font(.footnote)
            }
          } header: {
            Text("Notifications").foregroundStyle(Color.primary)
          }
        }
      }
      .navigationTitle("Connection")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { settings = false }.accessibilityIdentifier("dismissConnection")
        }
      }
    }
  }
  private func addCoordinator(_ coordinators: Coordinators) -> some View {
    NavigationLink("Add coordinator") {
      Form { CoordinatorForm(coordinators: coordinators, profile: nil, pushed: true) }
        .navigationTitle("Add coordinator")
    }
  }
  /// One coordinator's alert state, as the single-coordinator section words it.
  private func alertHint(_ registration: NotificationRegistration, _ id: ProfileID) -> String? {
    let channel = registration.status(id)
    if let error = channel.error { return error }
    if model.snapshots[id]?.connection != .connected {
      return "Connect to the coordinator to receive updates."
    }
    if !channel.configured { return "APNs setup is required on the coordinator." }
    if registration.enabled, !channel.registered {
      return "Waiting for this device's Apple registration."
    }
    return nil
  }
}

/// Adds a coordinator, or edits a saved one. The form edits a copy, and Save stores nothing
/// until it has probed the address.
private struct CoordinatorForm: View {
  let coordinators: Coordinators
  let profile: CoordinatorProfile?
  /// On its own page, which closes after Remove. Inline, it is the Connection sheet's form.
  let pushed: Bool
  @State private var name = ""
  @State private var host = ""
  @State private var port = "43187"
  @State private var formError: String?
  @State private var saving = false
  @State private var removal: String?
  @Environment(\.dismiss) private var dismiss

  init(coordinators: Coordinators, profile: CoordinatorProfile?, pushed: Bool) {
    self.coordinators = coordinators
    self.profile = profile
    self.pushed = pushed
    _name = State(initialValue: profile?.name.description ?? "")
    _host = State(initialValue: profile?.address.host ?? "")
    _port = State(initialValue: String(profile?.address.port ?? 43187))
  }

  var body: some View {
    Section {
      LabeledContent("Name") {
        TextField("", text: $name, prompt: Text("Optional"))
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
          .autocorrectionDisabled().accessibilityIdentifier("coordinatorName")
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Tailscale address").font(.subheadline)
        TextField("", text: $host, prompt: Text("machine.example.ts.net"), axis: .vertical)
          #if os(iOS)
            .keyboardType(.URL).textInputAutocapitalization(.never)
          #endif
          .lineLimit(1...3).fixedSize(horizontal: false, vertical: true)
          .autocorrectionDisabled().accessibilityIdentifier("coordinatorAddress")
          .accessibilityLabel("Tailscale address")
      }
      LabeledContent("Port") {
        TextField("", text: $port, prompt: Text("43187"))
          #if os(iOS)
            .keyboardType(.numberPad)
          #endif
          .accessibilityIdentifier("coordinatorPort")
      }
    }
    if let error = coordinators.failure ?? formError ?? (pushed ? nil : coordinators.chat.error) {
      Text(error).foregroundStyle(.red)
    }
    Button("Save") { Task { await save() } }.disabled(!canSave)
      // Inline, Remove leaves the form to add a coordinator in its place.
      .onChange(of: profile?.id) { load() }
    if let profile {
      Button("Remove coordinator", role: .destructive) {
        removal = coordinators.removalMessage(profile.id)
      }
      .disabled(saving)
      .confirmationDialog(
        "Remove \(profile.name.description)?",
        isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
        titleVisibility: .visible
      ) {
        Button("Remove", role: .destructive) { Task { await remove(profile.id) } }
      } message: {
        Text(removal ?? "")
      }
    }
  }
  private var formAddress: CoordinatorAddress? {
    UInt16(port).flatMap {
      try? CoordinatorAddress(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: $0)
    }
  }
  private var canSave: Bool {
    guard !saving, let address = formAddress else { return false }
    guard let profile else { return true }
    return profile.address != address || profile.name.description != name
  }
  private func load() {
    name = profile?.name.description ?? ""
    host = profile?.address.host ?? ""
    port = String(profile?.address.port ?? 43187)
    formError = nil
  }
  /// Closes the Connection sheet inline, or this page when pushed.
  private func save() async {
    guard let address = formAddress else { return }
    saving = true
    defer { saving = false }
    do {
      let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      let tag = typed.isEmpty ? TagName(defaultFor: address) : try TagName(typed)
      if let profile {
        try await coordinators.update(profile.id, name: tag, address: address)
      } else {
        try await coordinators.add(name: tag, address: address)
      }
      dismiss()
    } catch { formError = error.localizedDescription }
  }
  private func remove(_ id: ProfileID) async {
    do {
      try await coordinators.remove(id)
      if pushed { dismiss() }
    } catch { formError = error.localizedDescription }
  }
}

/// A coordinator as the feed draws it: its name in its color.
struct CoordinatorBadge {
  let name: String
  let color: Color
  /// The coordinator's dot and name as one run of text.
  var title: Text {
    Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(color)
      + Text(" \(name)").fontWeight(.semibold).foregroundStyle(color)
  }
}

/// Coordinator colors by profile index: blue, orange, green and purple, each dark enough on a
/// light background and light enough on a dark one to read as text.
private let coordinatorPalette: [(light: Color, dark: Color)] = [
  (Color(red: 0.11, green: 0.31, blue: 0.85), Color(red: 0.38, green: 0.65, blue: 0.98)),
  (Color(red: 0.76, green: 0.25, blue: 0.05), Color(red: 0.98, green: 0.57, blue: 0.24)),
  (Color(red: 0.08, green: 0.50, blue: 0.24), Color(red: 0.29, green: 0.87, blue: 0.50)),
  (Color(red: 0.49, green: 0.13, blue: 0.81), Color(red: 0.75, green: 0.52, blue: 0.99)),
]

/// A message queued before the update. It has no transport. It leaves only when the user sends its
/// restored copy unchanged, or by Discard.
private struct HeldMessageRow: View {
  let message: HeldMessage
  let restore: () -> Void
  let discard: () -> Void

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      VStack(alignment: .leading, spacing: 8) {
        Text(message.item.text).textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        ForEach(message.item.attachments, id: \.id) { reference in
          AttachmentLabel(reference: reference)
        }
      }
      .padding(14)
      .background(
        Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      Label(
        message.item.accepted
          ? "Held from before the update. Its coordinator already saved it."
          : "Held from before the update. It may already have been delivered.",
        systemImage: "tray"
      )
      .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
      RestoreAndDiscard(restore: message.item.accepted ? nil : restore, discard: discard)
    }
    .padding(.leading, 32)
    .frame(maxWidth: .infinity, alignment: .trailing)
    .accessibilityElement(children: .contain).accessibilityLabel("Held message")
  }
}

/// Restore and Discard for a message that did not reach its coordinator. They share a line when
/// they fit and stack otherwise, so neither is cut off at large text sizes.
private struct RestoreAndDiscard: View {
  /// nil for a held message its coordinator already saved, since a restored copy would send it
  /// twice.
  let restore: (() -> Void)?
  let discard: () -> Void
  /// The coordinator whose copy the buttons act on, named for VoiceOver with two or more.
  var name: String?

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) { buttons }
      VStack(alignment: .trailing, spacing: 0) { buttons }
    }
    .font(.callout).buttonStyle(.plain)
  }
  @ViewBuilder private var buttons: some View {
    if let restore {
      Button(action: restore) {
        Label("Restore to composer", systemImage: "arrow.uturn.backward")
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
      }
      .accessibilityLabel(
        name.map { "Restore \($0)'s copy to composer" } ?? "Restore to composer")
    }
    Button(role: .destructive, action: discard) {
      Label("Discard", systemImage: "trash").frame(minHeight: 44)
    }
    .accessibilityLabel(name.map { "Discard \($0)'s copy" } ?? "Discard")
  }
}

// End visibility belongs to the viewport, not to a lazy one-pixel child.
// Allow one display pixel for native content-size rounding at the end.
private struct TranscriptEdges: Equatable {
  let top: Bool
  let latest: Bool
}

// Controls remain scroll-addressable without sharing transcript row identity.
private enum TranscriptControlAnchor: Hashable {
  case earlier
  case latest
}

private enum HistoryNavigation: Hashable {
  case earlier(UUID, anchorID: String?)
  case latest(UUID)
}

struct MessageRow: View {
  let model: RowModel
  let retry: (String) -> Void
  let restore: (String) -> Void
  let discard: (String) -> Void
  let preview: (AttachmentRef) -> Void
  /// Names and colors with two or more coordinators. Empty draws the one-coordinator row.
  let badges: [ProfileID: CoordinatorBadge]
  @State private var expanded = false
  @Environment(\.dynamicTypeSize) private var typeSize

  init(
    model: RowModel, retry: @escaping (String) -> Void, restore: @escaping (String) -> Void,
    discard: @escaping (String) -> Void, preview: @escaping (AttachmentRef) -> Void = { _ in },
    badges: [ProfileID: CoordinatorBadge] = [:]
  ) {
    self.model = model
    self.retry = retry
    self.restore = restore
    self.discard = discard
    self.preview = preview
    self.badges = badges
  }

  var body: some View {
    VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
      content
        .padding(isUser ? 14 : 0)
        .background(
          isUser ? AnyShapeStyle(Color.primary.opacity(0.07)) : AnyShapeStyle(.clear),
          in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .frame(
          maxWidth: isUser && !typeSize.isAccessibilitySize ? 520 : .infinity,
          alignment: isUser ? .trailing : .leading)
      if isUser, !badges.isEmpty, !model.receipts.isEmpty {
        receipt
      } else {
        delivery
      }
    }
    .padding(.leading, isUser && !typeSize.isAccessibilitySize ? 32 : 0)
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    .accessibilityElement(children: .contain).accessibilityLabel(title)
    .contextMenu {
      ShareLink(item: model.row.text) { Label("Share text", systemImage: "square.and.arrow.up") }
    }
  }
  /// Who a Send went to once every recipient placed it, else each recipient's own state with its
  /// own Check, or Restore and Discard. A recipient that is no longer saved reads as a removed
  /// coordinator.
  @ViewBuilder private var receipt: some View {
    let names = model.receipts.map { badges[$0.lane]?.name ?? "a removed coordinator" }
    if let summary = Receipt.summary(model.receipts, names: names) {
      Text(summary).font(.caption.weight(.medium)).foregroundStyle(.secondary)
    } else {
      ForEach(model.receipts, id: \.lane) { receipt in
        let badge =
          badges[receipt.lane]
          ?? CoordinatorBadge(name: "A removed coordinator", color: .secondary)
        (Text(Image(systemName: "circle.fill")).font(.system(size: 7)).foregroundStyle(badge.color)
          + Text(" " + receipt.line(badge.name)))
          .font(.caption.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        if let work = receipt.work { workLabel(work) }
        switch receipt.status {
        case .pending(.uncertain, let id?):
          Button {
            retry(id)
          } label: {
            Label("Check / retry", systemImage: "arrow.clockwise").frame(minHeight: 44)
          }
          .font(.callout).buttonStyle(.plain)
          .accessibilityLabel("Check / retry \(badge.name)")
          .accessibilityHint(
            "Checks the original message ID and retries without creating another message.")
        case .pending(.rejected, let id?):
          RestoreAndDiscard(restore: { restore(id) }, discard: { discard(id) }, name: badge.name)
        default: EmptyView()
        }
      }
    }
  }
  @ViewBuilder private var delivery: some View {
    if let delivery = model.row.delivery {
      Label(delivery.rawValue, systemImage: delivery.symbol)
        .font(.caption.weight(.medium)).foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
    if let work = model.row.work { workLabel(work) }
    if model.row.delivery == .uncertain, let id = model.row.inputID {
      Button {
        retry(id)
      } label: {
        Label("Check / retry", systemImage: "arrow.clockwise")
          .lineLimit(nil).fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
      }
      .font(.callout).buttonStyle(.plain)
      .accessibilityHint(
        "Checks the original message ID and retries without creating another message.")
    }
    if model.row.delivery == .rejected, let id = model.row.inputID {
      RestoreAndDiscard(restore: { restore(id) }, discard: { discard(id) })
    }
  }
  /// What the coordinator reports about processing an input it accepted, apart from its delivery.
  private func workLabel(_ work: InputWorkState) -> some View {
    Label(work.label, systemImage: work.symbol)
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
  }
  private var isUser: Bool { model.row.role == .user }
  private var showsHeader: Bool {
    model.row.role == .notice
  }
  private var content: some View {
    VStack(alignment: .leading, spacing: 8) {
      if showsHeader {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(
          .secondary)
      }
      if model.row.tool != nil || model.row.role == .thinking
        || (model.row.role == .tool && model.row.presentation != nil)
      {
        ActivityItemView(
          model: model, expanded: $expanded,
          details: { row in .unavailable(.init(callId: row.tool?.callId ?? "")) })
      } else {
        if let presentation = model.row.presentation {
          Text(presentation.activityTitle()).font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        RichMessage(blocks: blocks)
      }
      ForEach(model.row.attachments, id: \.id) { reference in
        Button {
          preview(reference)
        } label: {
          AttachmentLabel(reference: reference)
        }
        .buttonStyle(.plain).accessibilityHint("Download and preview attachment")
      }
    }
  }
  /// The row's text, led by the tag of the one coordinator a tagged Send went to.
  private var blocks: [RichBlock] {
    guard isUser, model.receipts.count == 1, let lane = model.receipts.first?.lane,
      let badge = badges[lane]
    else { return model.row.blocks }
    var tag = AttributedString("@\(badge.name) ")
    tag.foregroundColor = badge.color
    tag.font = .body.weight(.semibold)
    guard case .prose(let text)? = model.row.blocks.first else {
      return [.prose(tag)] + model.row.blocks
    }
    return [.prose(tag + text)] + model.row.blocks.dropFirst()
  }
  private var title: String {
    switch model.row.role {
    case .user: "You"
    case .assistant, .final: "Agent"
    case .commentary: "Update"
    case .partialAnswer: "Partial answer"
    case .notice: "Notice"
    case .thinking: "Reasoning"
    case .tool: "Tool"
    }
  }
  private var symbol: String {
    switch model.row.role {
    case .user: "person"
    case .thinking: "sparkle"
    case .tool: "terminal"
    case .notice: "info.circle"
    default: "bubble.left"
    }
  }
}

extension Delivery {
  fileprivate var symbol: String {
    switch self {
    case .sending: "clock"
    case .saved: "checkmark.circle"
    case .uncertain: "questionmark.circle"
    case .rejected: "exclamationmark.triangle"
    case .withdrawn: "xmark.circle"
    }
  }
}

extension InputWorkState {
  var label: String {
    switch self {
    case .queued: "Queued"
    case .running: "Working"
    case .completed: "Completed"
    case .stopped: "Stopped"
    case .blocked(let blocked):
      switch blocked.reason {
      case .restartLimit: "Processing paused after repeated restarts"
      case .missingTask: "Processing paused: task definition unavailable"
      case .taskTooOld: "Processing paused: task needs a compatible runtime"
      case .migrationFailed: "Processing paused: task migration needs attention"
      }
    }
  }
  fileprivate var symbol: String {
    switch self {
    case .queued: "clock"
    case .running: "ellipsis.circle"
    case .completed: "checkmark.circle"
    case .blocked: "pause.circle"
    case .stopped: "stop.circle"
    }
  }
}

struct RichMessage: View {
  let blocks: [RichBlock]
  var textStyle: Font = .body
  var compact = false
  @ScaledMetric(relativeTo: .body) private var leading = 3
  @ScaledMetric(relativeTo: .body) private var columnSpacing = 16
  @ScaledMetric(relativeTo: .body) private var listIndent = 16
  @ScaledMetric(relativeTo: .body) private var listMarkerWidth = 24
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(blocks.indices, id: \.self) { index in
        switch blocks[index] {
        case .prose(let text):
          Text(text).font(textStyle).lineSpacing(leading).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        case .heading(let text, let level):
          Text(text).font(compact ? textStyle : level <= 2 ? .title3 : .headline)
            .accessibilityAddTraits(.isHeader)
            .textSelection(.enabled)
        case .quote(let text):
          Text(text).font(textStyle).lineSpacing(leading).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true).padding(.leading, 12)
            .overlay(alignment: .leading) {
              RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
            }
        case .listItem(let text, let marker, let depth):
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(marker).frame(minWidth: listMarkerWidth, alignment: .trailing)
            Text(text).lineSpacing(leading).textSelection(.enabled)
              .fixedSize(horizontal: false, vertical: true)
          }
          .font(textStyle).padding(.leading, CGFloat(depth) * listIndent)
          .accessibilityElement(children: .combine)
        case .divider: Divider()
        case .code(let code, let language):
          VStack(alignment: .leading, spacing: 8) {
            if !language.isEmpty { Text(language).font(.caption).foregroundStyle(.secondary) }
            ScrollView(.horizontal) {
              Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            }
          }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        case .table(let rows):
          ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: columnSpacing, verticalSpacing: 10) {
              ForEach(rows.indices, id: \.self) { row in
                GridRow {
                  ForEach(rows[row].indices, id: \.self) { column in
                    Text(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular)
                      .fixedSize(horizontal: true, vertical: false).textSelection(.enabled)
                  }
                }
                if row == 0 {
                  GridRow {
                    Divider().gridCellColumns(rows[row].count).gridCellUnsizedAxes(.horizontal)
                  }
                }
              }
            }.padding(12)
          }.background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
  }
}
