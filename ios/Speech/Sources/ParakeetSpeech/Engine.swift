@preconcurrency import AVFoundation
@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Parakeet Unified English 0.6B streaming, with the int8 encoder whose window is 70 frames of
/// left context, a 13-frame chunk and 13 frames of right context (2.08 s), on the CPU and Neural
/// Engine. This file alone makes that decision. On an iPhone 16 Pro the spike measured a 10 to
/// 13 s compile, a 637 MB peak, the final text within 0.08 s of the audio's end at every length,
/// and one word wrong in 82 s of speech.
enum Engine {
  /// The Hugging Face commit the on-device spike measured. FluidAudio would otherwise download
  /// `main`, which a later push could fill with files this FluidAudio cannot load.
  static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
  /// Everything one install fetches at `revision`: the three bundles, `vocab.json`, and FluidAudio's
  /// `metadata.json` and `config.json`.
  static let downloadBytes: Int64 = 609_440_571
  /// FluidAudio's folder for the repository, inside the directory handed to `download`.
  static let folder = Repo.parakeetUnified.folderName
  fileprivate static let config = UnifiedConfig(leftFrames: 70, chunkFrames: 13, rightFrames: 13)
  /// What a load needs, and what FluidAudio checks before it decides a download is complete.
  static let files: Set<String> = [
    config.family.streamingEncoderFile(precision: .int8, contextSuffix: config.contextSuffix),
    config.family.decoderFile, config.family.jointDecisionFile, config.family.vocab,
  ]

  private static let pinned: Void = {
    ModelRegistry.revisionOverrides[Repo.parakeetUnified.remotePath] = revision
  }()

  /// Downloads whatever `files` lack into `directory`, resuming partial files by HTTP Range.
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

  /// FluidAudio's completeness rule, read from the files alone. Every bundle has its
  /// `coremldata.bin` and no `.partial` download, and every plain file exists.
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

/// The model in memory, about 620 MB on an iPhone, until `unload` lets it go. One stream at a
/// time: `reset` starts the next.
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

  /// Feeds 16 kHz mono samples, decodes every window they complete, and returns the whole
  /// transcript so far, which the next windows can still change.
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
