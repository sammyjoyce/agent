import AVFoundation
import AgentUI
import Network
import ParakeetSpeech
import os

extension SpeechEngine {
  static let parakeet: SpeechEngine = {
    let parakeet = Parakeet()
    return SpeechEngine(
      model: { SpeechModel(await parakeet.model()) },
      install: { progress in try await parakeet.install(progress: progress) },
      prewarm: { await parakeet.prewarm() },
      remove: { await parakeet.remove() },
      diskUsage: { await parakeet.diskUsage() },
      onCellular: onCellular,
      permission: { MicrophonePermission(Microphone.permission) },
      requestPermission: { await Microphone.requestPermission() },
      record: {
        let take = try await parakeet.record()
        let heard = take.events
        let (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
        let relay = Task {
          for await event in heard { continuation.yield(RecordingEvent(event)) }
          continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        return Recording(
          events: events, finish: { try await take.finish() }, cancel: { take.cancel() })
      })
  }()
}

extension Speaker {
  /// The system voice, with the app's audio session active only while it speaks.
  @MainActor static let onDevice: Speaker = {
    let voice = SystemVoice()
    return Speaker { sentence in try await voice.say(sentence) }
  }()
}

@MainActor
private final class SystemVoice: NSObject, AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  /// Keyed by utterance, because the synthesizer reports a sentence cut short after the next one
  /// has started.
  private var saying: [ObjectIdentifier: CheckedContinuation<Void, any Error>] = [:]

  override init() {
    super.init()
    synthesizer.usesApplicationAudioSession = true
    synthesizer.delegate = self
  }

  func say(_ sentence: String) async throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(
      .playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
    try session.setActive(true)
    defer { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    let utterance = AVSpeechUtterance(string: sentence)
    utterance.prefersAssistiveTechnologySettings = true
    let id = ObjectIdentifier(utterance)
    let interruption = NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification, object: session, queue: .main
    ) { notification in
      let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
      guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
      MainActor.assumeIsolated { self.cancel(id) }
    }
    defer { NotificationCenter.default.removeObserver(interruption) }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (said: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          said.resume(throwing: CancellationError())
        } else {
          saying[id] = said
          synthesizer.speak(utterance)
        }
      }
    } onCancel: {
      Task { @MainActor in self.cancel(id) }
    }
  }

  private func cancel(_ id: ObjectIdentifier) {
    guard let pending = saying.removeValue(forKey: id) else { return }
    synthesizer.stopSpeaking(at: .immediate)
    pending.resume(throwing: CancellationError())
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    let said = ObjectIdentifier(utterance)
    Task { @MainActor in self.saying.removeValue(forKey: said)?.resume() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    let cut = ObjectIdentifier(utterance)
    Task { @MainActor in
      self.saying.removeValue(forKey: cut)?.resume(throwing: CancellationError())
    }
  }
}

/// The first path a fresh monitor reports, which is the current one.
private func onCellular() async -> Bool {
  await withCheckedContinuation { reply in
    let pending = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(initialState: reply)
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { path in
      guard let reply = pending.withLock({ $0.take() }) else { return }
      monitor.cancel()
      monitor.pathUpdateHandler = nil
      reply.resume(returning: path.isExpensive || path.usesInterfaceType(.cellular))
    }
    monitor.start(queue: .global(qos: .userInitiated))
  }
}

extension SpeechModel {
  fileprivate init(_ model: Parakeet.Model) {
    switch model {
    case .missing(let download): self = .missing(download: download)
    case .stale: self = .stale
    case .ready: self = .ready
    case .unsupported: self = .unsupported
    }
  }
}

extension MicrophonePermission {
  fileprivate init(_ permission: Microphone.Permission) {
    switch permission {
    case .granted: self = .granted
    case .denied: self = .denied
    case .undetermined: self = .undetermined
    }
  }
}

extension RecordingEvent {
  fileprivate init(_ event: Take.Event) {
    switch event {
    case .level(let level): self = .level(level)
    case .partial(let words): self = .partial(words)
    case .interrupted: self = .interrupted
    }
  }
}
