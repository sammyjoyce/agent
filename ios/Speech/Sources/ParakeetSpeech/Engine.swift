@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Parakeet Unified English 0.6B in batch, with the int8 full-attention offline encoder on the CPU
/// and Neural Engine. This file alone makes that decision. On an iPhone 16 Pro it turned 59 s of
/// audio into text 0.45 to 0.58 s after stop, with the same words as fp16 at half the download and
/// memory. Streaming would replace this file.
enum Engine {
  /// The Hugging Face commit the on-device spike measured. FluidAudio would otherwise download
  /// `main`, which a later push could fill with files this FluidAudio cannot load.
  static let revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
  /// Everything one install fetches at `revision`: the three bundles, `vocab.json`, and FluidAudio's
  /// `metadata.json` and `config.json`.
  static let downloadBytes: Int64 = 614_082_275
  /// FluidAudio's folder for the repository, inside the directory handed to `download`.
  static let folder = Repo.parakeetUnified.folderName
  private static let family = UnifiedConfig().family
  /// What a load needs, and what FluidAudio checks before it decides a download is complete.
  static let files: Set<String> = [
    family.offlineEncoderFile(precision: .int8), family.decoderFile, family.jointDecisionFile,
    family.vocab,
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
    // make FluidAudio purge the files and download 614 MB again.
    try await ModelHub.loadWithRecovery(
      .parakeetUnified, directory: directory, requiredFiles: files, variant: "offline",
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

/// The model in memory, about 650 MB on an iPhone, until `unload` brings it back to about 32 MB.
struct Recognizer: Sendable {
  private let manager: UnifiedAsrManager

  /// Compiles the model for this device first when an app or OS update invalidated Core ML's cache.
  static func load(from repository: URL) async throws -> Recognizer {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuAndNeuralEngine
    let manager = UnifiedAsrManager(
      configuration: configuration, config: UnifiedConfig(), encoderPrecision: .int8)
    try await manager.loadModels(from: repository)
    return Recognizer(manager: manager)
  }

  /// 16 kHz mono samples of any length in, punctuated text out.
  func transcribe(_ samples: [Float]) async throws -> String {
    try await manager.transcribe(samples)
  }

  func unload() async {
    await manager.cleanup()
  }
}
