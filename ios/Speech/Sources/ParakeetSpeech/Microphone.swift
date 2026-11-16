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

/// The session is `.record` with mode `.measurement`, which keeps the system's own signal
/// processing to a minimum, so the model hears audio closest to what it was trained on.
final class Capture: Sendable {
  let audio: AsyncThrowingStream<[Float], any Error>
  private let heard: AsyncThrowingStream<[Float], any Error>.Continuation
  private let reporting: AsyncStream<Take.Event>.Continuation
  private let state: OSAllocatedUnfairLock<State>
  /// A converter error halts capture on this queue, since `removeTap` inside the tap's block can
  /// run that block again before it returns. The queued halt holds the capture strongly. A weak
  /// reference could leave the last release, and the running engine with it, to the tap's block.
  private let teardown = DispatchQueue(label: "ParakeetSpeech.Capture.teardown")

  private struct State {
    var engine: AVAudioEngine?
    let converter: AVAudioConverter
    var observers: [any NSObjectProtocol] = []
    var power: Float = 0
    var counted = 0

    mutating func level(_ heard: [Float]) -> Float? {
      power += heard.reduce(0) { $0 + $1 * $1 }
      counted += heard.count
      guard counted >= 1_200 else { return nil }
      let decibels = 10 * log10(max(power / Float(counted), 1e-12))
      power = 0
      counted = 0
      return min(1, max(0, (decibels + 50) / 50))
    }
  }

  private init(
    engine: AVAudioEngine, converter: AVAudioConverter,
    reporting: AsyncStream<Take.Event>.Continuation
  ) {
    (audio, heard) = AsyncThrowingStream.makeStream(of: [Float].self)
    self.reporting = reporting
    state = OSAllocatedUnfairLock(uncheckedState: State(engine: engine, converter: converter))
  }

  static func start(reporting: AsyncStream<Take.Event>.Continuation) throws -> Capture {
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
    let capture = Capture(engine: engine, converter: converter, reporting: reporting)
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
      capture.observe(engine)
    } catch {
      capture.stop()
      throw error
    }
    return capture
  }

  var isRunning: Bool { state.withLockUnchecked { $0.engine != nil } }

  /// Halts, then waits for any halt a converter error queued, so that halt cannot deactivate the
  /// shared audio session after the next take activates it.
  func stop() {
    halt(interrupted: false)
    teardown.sync {}
  }

  private func halt(interrupted: Bool) {
    let running = state.withLockUnchecked { state -> (AVAudioEngine, [any NSObjectProtocol])? in
      guard let engine = state.engine else { return nil }
      let rest = (try? Self.convert(nil, with: state.converter)) ?? []
      if !rest.isEmpty { heard.yield(rest) }
      heard.finish()
      defer {
        state.engine = nil
        state.observers = []
      }
      return (engine, state.observers)
    }
    guard let (engine, observers) = running else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    Self.deactivate()
    if interrupted { reporting.yield(.interrupted) }
    reporting.finish()
  }

  private func hear(_ buffer: AVAudioPCMBuffer) {
    let level = state.withLockUnchecked { state -> Float? in
      guard state.engine != nil else { return nil }
      let samples: [Float]
      do {
        samples = try Self.convert(buffer, with: state.converter)
      } catch {
        // Under the lock, so a stop racing this buffer cannot end the audio cleanly first.
        heard.finish(throwing: error)
        teardown.async { self.halt(interrupted: false) }
        return nil
      }
      guard !samples.isEmpty else { return nil }
      heard.yield(samples)
      return state.level(samples)
    }
    if let level { reporting.yield(.level(level)) }
  }

  private static func convert(_ buffer: AVAudioPCMBuffer?, with converter: AVAudioConverter)
    throws -> [Float]
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
      if status == .error { throw ParakeetError.audioFormat }
      if let channel = output.floatChannelData {
        heard.append(
          contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
      }
      guard status == .haveData else { break }
    }
    return heard
  }

  /// The engine stops itself and posts this notice when the input's channel count or sample rate
  /// changes. A notice while it still runs did not stop its audio, so the take goes on.
  private func engineChanged() {
    guard let engine = state.withLockUnchecked({ $0.engine }), !engine.isRunning else { return }
    halt(interrupted: true)
  }

  /// The engine posts its notice on an internal queue, where tearing the engine down can deadlock,
  /// so the check runs on another queue. The engine may have stopped itself before the observer
  /// existed, so the check also runs once here.
  private func observe(_ engine: AVAudioEngine) {
    holdUntilHalt([
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
      ) { [weak self] _ in
        DispatchQueue.global().async { [weak self] in self?.engineChanged() }
      }
    ])
    engineChanged()
  }

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
      holdUntilHalt(observers)
    #endif
  }

  private func holdUntilHalt(_ observers: [any NSObjectProtocol]) {
    let halted = state.withLockUnchecked { state in
      guard state.engine != nil else { return true }
      state.observers += observers
      return false
    }
    guard halted else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
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
