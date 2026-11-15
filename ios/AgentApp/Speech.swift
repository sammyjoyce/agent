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
