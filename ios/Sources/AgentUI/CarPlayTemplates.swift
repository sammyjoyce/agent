#if canImport(CarPlay) && os(iOS)
  import CarPlay
  import Observation
  import UIKit

  /// The car screen. Its list offers each paired coordinator. Choosing one pushes a voice template
  /// whose states show fixed words and that coordinator's name, never a word of the conversation.
  @available(iOS 26.4, *)
  @MainActor
  public final class CarScreen: NSObject, CPInterfaceControllerDelegate {
    private let interface: CPInterfaceController
    private let conversation: CarConversation?
    private let list = CPListTemplate(title: "Beep Boop", sections: [])
    private var voice: CPVoiceControlTemplate?

    /// Shows the list on `interface`. Without a conversation it offers no coordinator.
    public init(interface: CPInterfaceController, conversation: CarConversation?) {
      self.interface = interface
      self.conversation = conversation
      super.init()
      interface.delegate = self
      interface.setRootTemplate(list, animated: false, completion: nil)
      showChoices()
    }

    /// Ends the conversation in progress and closes its voice template.
    public func end() {
      voice = nil
      conversation?.end()
    }

    public func templateWillDisappear(_ template: CPTemplate, animated: Bool) {
      if template === voice { end() }
    }

    private func showChoices() {
      let choices = withObservationTracking {
        conversation?.choices ?? []
      } onChange: { [weak self] in
        Task { @MainActor in self?.showChoices() }
      }
      list.updateSections(Self.sections(choices) { [weak self] in self?.talk(to: $0) })
    }

    /// Pushes the voice template, and starts the conversation only once it shows.
    private func talk(to coordinator: CarCoordinator) {
      guard voice == nil, let conversation else { return }
      let voice = Self.voiceTemplate(for: coordinator.name) { conversation.perform($0, in: $1) }
      self.voice = voice
      Task {
        let pushed = (try? await interface.pushTemplate(voice, animated: true)) == true
        if pushed, self.voice === voice {
          mirror(on: voice)
          await conversation.begin(with: coordinator).value
        }
        if self.voice === voice { self.voice = nil }
        if interface.topTemplate === voice { _ = try? await interface.popTemplate(animated: true) }
      }
    }

    private func mirror(on voice: CPVoiceControlTemplate) {
      guard self.voice === voice, let conversation else { return }
      let phase = withObservationTracking {
        conversation.phase
      } onChange: { [weak self] in
        Task { @MainActor in self?.mirror(on: voice) }
      }
      if phase != .idle, voice.activeStateIdentifier != phase.rawValue {
        voice.activateVoiceControlState(withIdentifier: phase.rawValue)
      }
    }

    static func sections(
      _ choices: [CarCoordinator], choose: @escaping @MainActor (CarCoordinator) -> Void
    ) -> [CPListSection] {
      guard !choices.isEmpty else {
        let none = CPListItem(text: "No coordinator is paired", detailText: nil)
        none.isEnabled = false
        return [CPListSection(items: [none])]
      }
      return [
        CPListSection(
          items: choices.map { choice in
            let row = CPListItem(text: "Talk to \(choice.name)", detailText: nil)
            row.handler = { _, completion in
              choose(choice)
              completion()
            }
            return row
          })
      ]
    }

    /// One state for each phase but idle. Working comes first because the template shows its
    /// first state as it appears, and the conversation connects before it speaks.
    static func voiceTemplate(
      for name: String, perform: @escaping @MainActor (CarAction, CarPhase) -> Void
    ) -> CPVoiceControlTemplate {
      func state(
        _ phase: CarPhase, _ titles: [String], _ symbol: String,
        _ buttons: [(title: String, symbol: String, action: CarAction)]
      ) -> CPVoiceControlState {
        let state = CPVoiceControlState(
          identifier: phase.rawValue, titleVariants: titles,
          image: UIImage(
            systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 72)),
          repeats: false)
        state.actionButtons = buttons.map { button in
          let press = CPButton(image: UIImage(systemName: button.symbol) ?? UIImage()) { _ in
            perform(button.action, phase)
          }
          press.title = button.title
          return press
        }
        return state
      }
      let cancel = (title: "Cancel", symbol: "xmark", action: CarAction.cancel)
      return CPVoiceControlTemplate(voiceControlStates: [
        state(.working, ["Waiting for \(name)", "Waiting"], "ellipsis", [cancel]),
        state(
          .listening, ["Talking to \(name)", "Listening"], "waveform",
          [("Done", "checkmark", .done), cancel]),
        state(
          .confirming, ["Send to \(name)?", "Send?"], "questionmark.bubble",
          [("Send", "paperplane", .send), cancel]),
        state(.speaking, ["Speaking"], "speaker.wave.2", [("Stop", "stop", .cancel)]),
      ])
    }
  }
#endif
