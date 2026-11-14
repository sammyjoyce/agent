import AgentUI
import ParakeetSpeech

extension SpeechEngine {
  /// Parakeet on this iPhone. One per process, as there is one microphone and one model.
  static let parakeet: SpeechEngine = {
    let parakeet = Parakeet()
    return SpeechEngine(
      model: { SpeechModel(await parakeet.model()) },
      install: { progress in try await parakeet.install(progress: progress) },
      prewarm: { await parakeet.prewarm() },
      remove: { await parakeet.remove() },
      diskUsage: { await parakeet.diskUsage() },
      permission: { MicrophonePermission(Microphone.permission) },
      requestPermission: { await Microphone.requestPermission() },
      record: {
        let take = try await parakeet.record()
        // The relay holds the stream rather than the take, so dropping a Recording still ends it.
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
    case .interrupted: self = .interrupted
    }
  }
}
