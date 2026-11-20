import AgentCore
import SwiftUI

struct ConversationSettingsView: View {
  let model: ChatModel
  let lane: ProfileID
  @State private var busy = false
  @State private var error: String?

  private var ready: Bool {
    model.snapshots[lane]?.settingsSupported == true
      && model.snapshots[lane]?.connection == .connected
  }

  var body: some View {
    Form {
      if model.snapshots[lane]?.settingsSupported != true {
        Text("Conversation settings are not advertised by this connection.")
      } else if let settings = model.snapshots[lane]?.settings {
        Section {
          LabeledContent("Configured", value: description(settings.configured.model))
          LabeledContent("Effective", value: settings.effective.map(description) ?? "Unknown")
          Text(
            "The active turn may have captured a different selection. Unknown is not the configured default."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
          Picker(
            "Provider",
            selection: Binding(
              get: { settings.configured.model.provider.rawValue },
              set: { value in
                guard value != settings.configured.model.provider.rawValue,
                  let provider = ModelProvider(rawValue: value)
                else { return }
                let options = models(settings, provider: provider)
                // Keep the model ID when both providers offer it; otherwise use the first
                // catalog model in stable ID order. Send the pair as one server change.
                guard
                  let option = options.first(where: {
                    $0.modelId == settings.configured.model.modelId
                  }) ?? options.first
                else { return }
                change(.setModel(.init(modelId: option.modelId, provider: option.provider)))
              }
            )
          ) {
            ForEach(providers(settings), id: \.rawValue) { provider in
              Text(provider.rawValue).tag(provider.rawValue)
                .disabled(models(settings, provider: provider).isEmpty)
            }
          }
          .pickerStyle(.menu).accessibilityIdentifier("conversationProviderPicker")
          let selectedModels = models(settings, provider: settings.configured.model.provider)
          Picker(
            "Model",
            selection: Binding(
              get: { settings.configured.model.modelId },
              set: { value in
                guard value != settings.configured.model.modelId,
                  let option = selectedModels.first(where: { $0.modelId == value })
                else { return }
                change(.setModel(.init(modelId: option.modelId, provider: option.provider)))
              }
            )
          ) {
            if !selectedModels.contains(where: {
              $0.modelId == settings.configured.model.modelId
            }) {
              Text(settings.configured.model.modelId).tag(settings.configured.model.modelId)
                .disabled(true)
            }
            ForEach(selectedModels, id: \.settingsKey) { option in
              Text(option.name).tag(option.modelId)
            }
          }
          .pickerStyle(.menu).accessibilityIdentifier("conversationModelPicker")
          if let option = settings.configured.catalog.first(where: {
            key($0) == key(settings.configured.model)
          }) {
            Picker(
              "Reasoning",
              selection: Binding(
                get: { settings.configured.model.reasoning?.rawValue ?? "provider_default" },
                set: { value in
                  if value == "provider_default" {
                    change(.setReasoning(.init(reasoning: nil)))
                  } else if let reasoning = Reasoning(rawValue: value),
                    option.reasoning.contains(reasoning)
                  {
                    change(.setReasoning(.init(reasoning: reasoning)))
                  }
                }
              )
            ) {
              Text("Provider default").tag("provider_default")
              if let saved = settings.configured.model.reasoning, !option.reasoning.contains(saved)
              {
                Text("\(saved.selectionLabel) (not supported)").tag(saved.rawValue).disabled(true)
              }
              ForEach(option.reasoning, id: \.rawValue) { reasoning in
                Text(reasoning.selectionLabel).tag(reasoning.rawValue)
              }
            }
            .pickerStyle(.menu).accessibilityIdentifier("conversationReasoningPicker")
            Toggle(
              "Fast",
              isOn: Binding(
                get: { settings.configured.model.fast },
                set: { change(.setFast(.init(mode: $0 ? .on : .off))) }
              )
            )
            .disabled(!option.fast).accessibilityIdentifier("conversationFastToggle")
            if !option.fast { Text("Fast is not supported by this model.").font(.footnote) }
          } else {
            Text("Model capabilities have not been reported.").font(.footnote)
          }
        }
        .disabled(busy || !ready)
      } else if busy {
        ProgressView("Loading conversation settings")
      }
      if let error {
        Text(error).foregroundStyle(.red).accessibilityIdentifier("conversationSettingsError")
      }
      Button("Refresh") { Task { await run(nil) } }
        .disabled(busy || !ready)
    }
    .navigationTitle(model.laneTitle("Conversation settings", for: lane))
    .task(id: ready) { await run(nil) }
  }
  /// Reads the settings, or with `change` changes them, once. A read cut off by a reconnect stays
  /// quiet, since the next connection reads again.
  private func run(_ change: ConversationChange?) async {
    guard !busy, ready else { return }
    busy = true
    error = nil
    defer { busy = false }
    do { try await model.settings(change: change, lane: lane) } catch {
      guard !Task.isCancelled else { return }
      if change == nil, case LaneError.interrupted = error { return }
      self.error = error.localizedDescription
    }
  }
  private func change(_ change: ConversationChange) {
    Task { await run(change) }
  }
  private func providers(_ settings: NativeSettingsSnapshot) -> [ModelProvider] {
    let names = Set(
      settings.configured.catalog.map { $0.provider.rawValue }
        + [settings.configured.model.provider.rawValue])
    return names.sorted().compactMap(ModelProvider.init(rawValue:))
  }
  private func models(_ settings: NativeSettingsSnapshot, provider: ModelProvider) -> [ModelOption]
  {
    var seen = Set<String>()
    return settings.configured.catalog
      .filter { $0.provider == provider && seen.insert($0.modelId).inserted }
      .sorted { $0.modelId < $1.modelId }
  }
  private func key(_ selection: ModelSelection) -> String {
    "\(selection.provider.rawValue)/\(selection.modelId)"
  }
  private func key(_ option: ModelOption) -> String {
    "\(option.provider.rawValue)/\(option.modelId)"
  }
  private func description(_ selection: ModelSelection) -> String {
    "\(selection.provider.rawValue)/\(selection.modelId) · \(selection.reasoning?.selectionLabel ?? "Provider default") · Fast \(selection.fast ? "on" : "off")"
  }
}

extension Reasoning {
  var selectionLabel: String {
    switch self {
    case .off: "Off (legacy)"
    case .minimal: "Minimal"
    case .low: "Low"
    case .medium: "Medium"
    case .high: "High"
    case .xhigh: "Extra High"
    case .max: "Max"
    }
  }
}

extension ModelOption {
  fileprivate var settingsKey: String { "\(provider.rawValue)/\(modelId)" }
}
