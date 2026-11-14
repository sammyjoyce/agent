import Foundation
import Synchronization

#if canImport(UIKit)
  import UIKit
#endif

/// One dictation, from `Parakeet.record()` until `finish` or `cancel`: the microphone open, and
/// the model loading beside it.
public final class Take: Sendable {
  public enum Event: Equatable, Sendable {
    /// The latest audio's loudness, 0...1, about ten times a second.
    case level(Float)
    /// A call, Siri, losing the input or a media-services reset stopped capture. What was heard is
    /// kept, and `finish` still returns its words.
    case interrupted
  }

  private enum Stage {
    case listening
    case transcribing
    case cancelled
    case ended
  }

  /// Ends when capture stops.
  public var events: AsyncStream<Event> { capture.events }

  private let capture: Capture
  private let model: Task<Recognizer, any Error>
  private let owner: Parakeet
  private let stage = Mutex(Stage.listening)

  init(capture: Capture, model: Task<Recognizer, any Error>, owner: Parakeet) {
    self.capture = capture
    self.model = model
    self.owner = owner
  }

  deinit {
    cancel()
  }

  /// Stops capture, waits for the model load `record` started (compiling a stale model first),
  /// transcribes everything heard and unloads the model once nothing else holds it. Throws
  /// `CancellationError` after `cancel` or on a second call.
  public func finish() async throws -> String {
    let starts = stage.withLock { stage in
      guard stage == .listening else { return false }
      stage = .transcribing
      return true
    }
    guard starts else { throw CancellationError() }
    let samples = capture.stop()
    #if canImport(UIKit)
      let background = await BackgroundTime()
    #endif
    let outcome: Result<String, any Error>
    do {
      outcome = .success(samples.isEmpty ? "" : try await transcribe(samples))
    } catch {
      outcome = .failure(error)
    }
    await owner.release()
    #if canImport(UIKit)
      await background.end()
    #endif
    let cancelled = stage.withLock { stage in
      defer { stage = .ended }
      return stage == .cancelled
    }
    if cancelled { throw CancellationError() }
    return try outcome.get()
  }

  /// Stops capture and abandons transcription. Idempotent. A transcription already running keeps
  /// the model until it returns, and its words are dropped.
  public func cancel() {
    let holdsModel = stage.withLock { stage in
      switch stage {
      case .listening:
        stage = .cancelled
        return true
      case .transcribing:
        stage = .cancelled
        return false
      case .cancelled, .ended:
        return false
      }
    }
    capture.stop()
    if holdsModel {
      Task { [owner] in await owner.release() }
    }
  }

  private func transcribe(_ samples: [Float]) async throws -> String {
    let recognizer = try await model.value
    guard stage.withLock({ $0 }) == .transcribing else { throw CancellationError() }
    return try await recognizer.transcribe(samples)
  }
}

#if canImport(UIKit)
  /// A finite stretch of background time, so leaving the app mid-transcription still lands the
  /// words. The system's deadline ends it rather than the app.
  @MainActor private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
      identifier = UIApplication.shared.beginBackgroundTask(withName: "Transcribe dictation") {
        [weak self] in self?.end()
      }
    }

    func end() {
      guard identifier != .invalid else { return }
      UIApplication.shared.endBackgroundTask(identifier)
      identifier = .invalid
    }
  }
#endif
