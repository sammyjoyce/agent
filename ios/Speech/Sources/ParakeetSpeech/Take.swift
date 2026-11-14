import Foundation
import Synchronization

#if canImport(UIKit)
  import UIKit
#endif

/// One dictation, from `Parakeet.record()` until `finish` or `cancel`: the microphone open, the
/// model loading beside it, and the audio streaming into the model once it loads.
public final class Take: Sendable {
  public enum Event: Equatable, Sendable {
    /// The latest audio's loudness, 0...1, about ten times a second.
    case level(Float)
    /// The whole transcript so far. Later audio can still change it, so each replaces the last.
    case partial(String)
    /// A call, Siri, losing the input or a media-services reset stopped capture. What was heard is
    /// kept, and `finish` still returns its words.
    case interrupted
  }

  private enum Stage {
    case listening
    case finishing
    case cancelled
    case ended
  }

  /// Ends when capture stops.
  public let events: AsyncStream<Event>

  private let capture: Capture
  /// The final text, once capture's audio ends and the model has decoded all of it. The model is
  /// released when this ends, however it ends.
  private let words: Task<String, any Error>
  private let stage = Mutex(Stage.listening)

  init(
    capture: Capture, events: AsyncStream<Event>, reporting: AsyncStream<Event>.Continuation,
    model: Task<Recognizer, any Error>, owner: Parakeet
  ) {
    self.capture = capture
    self.events = events
    words = Task {
      let outcome: Result<String, any Error>
      do {
        outcome = .success(
          try await Self.transcribe(capture.audio, with: model, reporting: reporting))
      } catch {
        outcome = .failure(error)
      }
      await owner.release()
      return try outcome.get()
    }
  }

  deinit {
    cancel()
  }

  /// Keeps listening for 200 ms so the last word is not cut, stops capture, and returns the final
  /// text once the model has decoded everything heard, waiting for a load still compiling. Throws
  /// `CancellationError` after `cancel` or on a second call.
  public func finish() async throws -> String {
    let starts = stage.withLock { stage in
      guard stage == .listening else { return false }
      stage = .finishing
      return true
    }
    guard starts else { throw CancellationError() }
    #if canImport(UIKit)
      let background = await BackgroundTime()
    #endif
    if capture.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
    capture.stop()
    let outcome: Result<String, any Error>
    do {
      outcome = .success(try await words.value)
    } catch {
      outcome = .failure(error)
    }
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

  /// Stops capture and abandons the words. Idempotent.
  public func cancel() {
    let cancels = stage.withLock { stage in
      switch stage {
      case .listening, .finishing:
        stage = .cancelled
        return true
      case .cancelled, .ended:
        return false
      }
    }
    guard cancels else { return }
    capture.stop()
    words.cancel()
  }

  private static func transcribe(
    _ audio: AsyncStream<[Float]>, with model: Task<Recognizer, any Error>,
    reporting: AsyncStream<Event>.Continuation
  ) async throws -> String {
    let recognizer = try await model.value
    try Task.checkCancellation()
    try await recognizer.reset()
    var shown = ""
    for await samples in audio {
      try Task.checkCancellation()
      let heard = try await recognizer.feed(samples)
      guard heard != shown else { continue }
      shown = heard
      reporting.yield(.partial(heard))
    }
    try Task.checkCancellation()
    return try await recognizer.finish()
  }
}

#if canImport(UIKit)
  /// A finite stretch of background time, so leaving the app as a take finishes still lands the
  /// words. The system's deadline ends it rather than the app.
  @MainActor private final class BackgroundTime {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init() {
      identifier = UIApplication.shared.beginBackgroundTask(withName: "Finish dictation") {
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
