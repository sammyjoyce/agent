import AVFoundation
import Foundation
import os

#if canImport(UIKit)
  import UIKit
#endif

/// Whether this app may use the microphone, as the system answered.
public enum Microphone {
  public enum Permission: Equatable, Sendable {
    case granted
    case denied
    case undetermined
  }

  public static var permission: Permission {
    switch AVAudioApplication.shared.recordPermission {
    case .granted: .granted
    case .denied: .denied
    case .undetermined: .undetermined
    @unknown default: .denied
    }
  }

  /// Shows the system prompt if it was never answered. True when allowed.
  public static func requestPermission() async -> Bool {
    await AVAudioApplication.requestRecordPermission()
  }
}

/// One capture: the audio session for exactly its length, the input converted to 16 kHz mono and
/// kept in memory, never in a file.
///
/// The session is `.record` with mode `.measurement`, which keeps the system's own signal
/// processing to a minimum, so the model hears audio closest to what it was trained on.
final class Capture: Sendable {
  let events: AsyncStream<Take.Event>
  private let continuation: AsyncStream<Take.Event>.Continuation
  private let state: OSAllocatedUnfairLock<State>

  private struct State {
    /// Nil once capture stopped.
    var engine: AVAudioEngine?
    let converter: AVAudioConverter
    var observers: [any NSObjectProtocol] = []
    var samples: [Float] = []
    var power: Float = 0
    var counted = 0

    /// Keeps the samples and returns a level once 75 ms accumulated, which comes to about ten
    /// levels a second whatever buffer size the hardware delivers.
    mutating func keep(_ heard: [Float]) -> Float? {
      samples.append(contentsOf: heard)
      power += heard.reduce(0) { $0 + $1 * $1 }
      counted += heard.count
      guard counted >= 1_200 else { return nil }
      let decibels = 10 * log10(max(power / Float(counted), 1e-12))
      power = 0
      counted = 0
      return min(1, max(0, (decibels + 50) / 50))
    }
  }

  private init(engine: AVAudioEngine, converter: AVAudioConverter) {
    (events, continuation) = AsyncStream.makeStream(of: Take.Event.self)
    state = OSAllocatedUnfairLock(uncheckedState: State(engine: engine, converter: converter))
  }

  static func start() throws -> Capture {
    #if os(iOS)
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement)
      try session.setActive(true)
    #endif
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let hardware = input.outputFormat(forBus: 0)
    guard hardware.sampleRate > 0, hardware.channelCount > 0,
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: hardware, to: target)
    else {
      deactivate()
      throw ParakeetError.noMicrophone
    }
    converter.downmix = true
    let capture = Capture(engine: engine, converter: converter)
    #if canImport(UIKit)
      Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = true }
    #endif
    input.installTap(onBus: 0, bufferSize: 4_096, format: hardware) { [weak capture] buffer, _ in
      capture?.hear(buffer)
    }
    capture.observe()
    do {
      engine.prepare()
      try engine.start()
    } catch {
      capture.stop()
      throw error
    }
    return capture
  }

  /// Stops capture if it runs and returns everything heard. Idempotent.
  @discardableResult func stop() -> [Float] {
    halt(interrupted: false)
  }

  @discardableResult private func halt(interrupted: Bool) -> [Float] {
    let running = state.withLockUnchecked { state -> (AVAudioEngine, [any NSObjectProtocol])? in
      guard let engine = state.engine else { return nil }
      _ = state.keep(Self.convert(nil, with: state.converter))
      defer {
        state.engine = nil
        state.observers = []
      }
      return (engine, state.observers)
    }
    if let (engine, observers) = running {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
      for observer in observers { NotificationCenter.default.removeObserver(observer) }
      Self.deactivate()
      if interrupted { continuation.yield(.interrupted) }
      continuation.finish()
    }
    return state.withLockUnchecked { $0.samples }
  }

  private func hear(_ buffer: AVAudioPCMBuffer) {
    let level = state.withLockUnchecked { state -> Float? in
      guard state.engine != nil else { return nil }
      return state.keep(Self.convert(buffer, with: state.converter))
    }
    if let level { continuation.yield(.level(level)) }
  }

  /// Converts one buffer, or with nil flushes what the resampler still holds at the end.
  private static func convert(_ buffer: AVAudioPCMBuffer?, with converter: AVAudioConverter)
    -> [Float]
  {
    let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer?.frameLength ?? 0) * ratio) + 1_024
    var pending = buffer
    var heard: [Float] = []
    while let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)
    {
      let status = converter.convert(to: output, error: nil) { _, input in
        guard let next = pending else {
          input.pointee = buffer == nil ? .endOfStream : .noDataNow
          return nil
        }
        pending = nil
        input.pointee = .haveData
        return next
      }
      if let channel = output.floatChannelData {
        heard.append(
          contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
      }
      guard status == .haveData else { break }
    }
    return heard
  }

  /// A call or Siri, losing the input in use, or a media-services reset ends capture, keeping what
  /// was heard.
  private func observe() {
    #if os(iOS)
      let center = NotificationCenter.default
      let session = AVAudioSession.sharedInstance()
      let observers = [
        center.addObserver(
          forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] note in
          let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
          guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
          self?.halt(interrupted: true)
        },
        center.addObserver(
          forName: AVAudioSession.routeChangeNotification, object: session, queue: nil
        ) { [weak self] note in
          let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else {
            return
          }
          self?.halt(interrupted: true)
        },
        center.addObserver(
          forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
          self?.halt(interrupted: true)
        },
      ]
      state.withLockUnchecked { $0.observers = observers }
    #endif
  }

  private static func deactivate() {
    #if os(iOS)
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    #endif
    #if canImport(UIKit)
      Task { @MainActor in UIApplication.shared.isIdleTimerDisabled = false }
    #endif
  }
}
