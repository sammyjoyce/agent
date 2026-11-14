@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

enum Engine {
  /// The Hugging Face commit to download. FluidAudio would otherwise download `main`, which a
  /// later push could fill with files this FluidAudio cannot load.
  static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
  static let downloadBytes: Int64 = 609_440_571
  static let folder = Repo.parakeetUnified.folderName
  fileprivate static let config = UnifiedConfig(leftFrames: 70, chunkFrames: 13, rightFrames: 13)
  static let files: Set<String> = [
    config.family.streamingEncoderFile(precision: .int8, contextSuffix: config.contextSuffix),
    config.family.decoderFile, config.family.jointDecisionFile, config.family.vocab,
  ]

  private static let pinned: Void = {
    ModelRegistry.revisionOverrides[Repo.parakeetUnified.remotePath] = revision
  }()

  static func download(
    into directory: URL, progress: @escaping @Sendable (Double) -> Void
  ) async throws {
    _ = pinned
    // FluidAudio gives a repository's download the first half of its progress and the compile it
    // never reaches here the second. The load closure is empty so that a failed load can never
    // make FluidAudio purge the files and download them again.
    try await ModelHub.loadWithRecovery(
      .parakeetUnified, directory: directory, requiredFiles: files, variant: nil,
      progressHandler: { progress(min(1, $0.fractionCompleted * 2)) }, load: {})
  }

  /// FluidAudio's completeness rule, read from the files alone.
  static func isComplete(_ repository: URL) -> Bool {
    let manager = FileManager.default
    return files.allSatisfy { file in
      let path = repository.appending(path: file)
      guard file.hasSuffix(".mlmodelc") else {
        return manager.fileExists(atPath: path.path(percentEncoded: false))
      }
      let data = path.appending(path: "coremldata.bin").path(percentEncoded: false)
      guard manager.fileExists(atPath: data),
        let contents = manager.enumerator(at: path, includingPropertiesForKeys: nil)
      else { return false }
      for case let item as URL in contents where item.pathExtension == "partial" {
        return false
      }
      return true
    }
  }
}

struct Recognizer: Sendable {
  private let manager: StreamingUnifiedAsrManager

  /// Compiles the model for this device first when an app or OS update invalidated Core ML's cache.
  static func load(from repository: URL) async throws -> Recognizer {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let manager = StreamingUnifiedAsrManager(
      configuration: configuration, config: Engine.config, encoderPrecision: .int8)
    try await manager.loadModels(from: repository)
    return Recognizer(manager: manager)
  }

  func reset() async throws {
    try await manager.reset()
  }

  func feed(_ samples: [Float]) async throws -> String {
    try await manager.appendAudio(try Self.buffer(samples))
    try await manager.processBufferedAudio()
    return await manager.getPartialTranscript()
  }

  /// Feeds 400 ms of silence, as Hex does for Unified English so the last word's window fills,
  /// then flushes it and returns the final text.
  func finish() async throws -> String {
    try await manager.appendAudio(try Self.buffer([Float](repeating: 0, count: 6_400)))
    return try await manager.finish()
  }

  func unload() async {
    await manager.cleanup()
  }

  private static func buffer(_ samples: [Float]) throws -> AVAudioPCMBuffer {
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
      let buffer = AVAudioPCMBuffer(
        pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
      let channel = buffer.floatChannelData
    else { throw ParakeetError.audioFormat }
    buffer.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { source in
      guard let base = source.baseAddress else { return }
      channel[0].update(from: base, count: samples.count)
    }
    return buffer
  }
}
