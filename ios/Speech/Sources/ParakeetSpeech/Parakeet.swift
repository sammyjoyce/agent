import Foundation

/// Parakeet Unified English 0.6B on this device: its files, the one network operation that fetches
/// them, the model's memory, and the takes that use it.
///
/// Only `install` touches the network. The model is in memory only while a take or a prewarm
/// holds it. Takes and prewarms that overlap share one load, the last to finish unloads it, and a
/// new load waits for that unload, so two copies never sit in memory together.
public actor Parakeet {
  /// The model's files, as `model()` reads them without the network.
  public enum Model: Equatable, Sendable {
    /// Nothing usable is here. Installing downloads about this many more bytes.
    case missing(download: Int64)
    /// The files are complete, but the last successful load ran under another app or OS build,
    /// so the next load compiles the model again.
    case stale
    case ready
    /// Two loads in a row failed on complete files under this app and OS build. An app or OS
    /// update, or `remove()`, gives the model another try.
    case unsupported
  }

  private enum Residency {
    case idle(after: Task<Void, Never>?)
    case loaded(Task<Recognizer, any Error>, users: Int)
  }

  private let root: URL
  private var residency = Residency.idle(after: nil)
  private var waitingForIdle: [CheckedContinuation<Void, Never>] = []

  /// - Parameter root: Holds one directory per model revision. Application Support, not Caches,
  ///   which iOS empties under storage pressure. `install` excludes it from backup.
  public init(
    root: URL = .applicationSupportDirectory.appending(
      path: "Agent/Speech", directoryHint: .isDirectory)
  ) {
    self.root = root
  }

  private var directory: URL { root.appending(path: Engine.revision, directoryHint: .isDirectory) }
  private var repository: URL {
    directory.appending(path: Engine.folder, directoryHint: .isDirectory)
  }
  private var receiptFile: URL { directory.appending(path: "receipt.json") }

  public func model() -> Model {
    let receipt = readReceipt()
    if let failures = receipt.failures, failures.build == .current, failures.count >= 2 {
      return .unsupported
    }
    guard receipt.installed == Engine.files.sorted(), Engine.isComplete(repository) else {
      return .missing(download: max(0, Engine.downloadBytes - Self.sizes(of: repository).files))
    }
    return receipt.warm == .current ? .ready : .stale
  }

  /// Downloads what is missing, resuming partial files, reports the download 0...1, then compiles
  /// the model once and unloads it. Throws `CancellationError` when cancelled during the download,
  /// keeping what it fetched.
  public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
    try prepareDirectory()
    let missing = max(0, Engine.downloadBytes - Self.sizes(of: repository).files)
    let needed = missing + Self.compileRoom
    let free =
      try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      .volumeAvailableCapacityForImportantUsage ?? .max
    guard free >= needed else {
      throw ParakeetError.notEnoughSpace(needed: needed, available: free)
    }
    do {
      try await Engine.download(into: directory, progress: progress)
    } catch {
      if Task.isCancelled { throw CancellationError() }
      throw error
    }
    progress(1)
    try updateReceipt { $0.installed = Engine.files.sorted() }
    try Task.checkCancellation()
    let load = acquire()
    defer { release() }
    _ = try await load.value
  }

  /// Compiles a stale model, then unloads it. Does nothing otherwise, and never downloads.
  public func prewarm() async {
    guard model() == .stale else { return }
    let load = acquire()
    defer { release() }
    _ = try? await load.value
  }

  /// Deletes every file and receipt, once no take or prewarm holds the model.
  public func remove() async {
    while true {
      switch residency {
      case .loaded:
        await withCheckedContinuation { waitingForIdle.append($0) }
      case .idle(let unload):
        await unload?.value
        guard case .idle(let now) = residency, now == unload else { continue }
        try? FileManager.default.removeItem(at: root)
        return
      }
    }
  }

  /// Bytes the files take on disk, partial downloads included.
  public func diskUsage() -> Int64 {
    Self.sizes(of: root).disk
  }

  /// Takes the audio session and starts capture, then starts loading the model beside it. Audio
  /// heard before the load ends waits for it. Throws when the session cannot be taken, as during
  /// a call.
  public func record() throws -> Take {
    let (events, reporting) = AsyncStream.makeStream(of: Take.Event.self)
    let capture = try Capture.start(reporting: reporting)
    return Take(
      capture: capture, events: events, reporting: reporting, model: acquire(), owner: self)
  }

  func acquire() -> Task<Recognizer, any Error> {
    switch residency {
    case .loaded(let load, let users):
      residency = .loaded(load, users: users + 1)
      return load
    case .idle(let unload):
      let repository = self.repository
      let load = Task {
        await unload?.value
        do {
          let recognizer = try await Recognizer.load(from: repository)
          loadSucceeded()
          return recognizer
        } catch {
          loadFailed()
          throw error
        }
      }
      residency = .loaded(load, users: 1)
      return load
    }
  }

  func release() {
    guard case .loaded(let load, let users) = residency else { return }
    guard users == 1 else {
      residency = .loaded(load, users: users - 1)
      return
    }
    residency = .idle(
      after: Task {
        if let recognizer = try? await load.value { await recognizer.unload() }
      })
    for waiter in waitingForIdle { waiter.resume() }
    waitingForIdle = []
  }

  private func loadSucceeded() {
    try? updateReceipt {
      $0.warm = .current
      $0.failures = nil
    }
  }

  private func loadFailed() {
    guard Engine.isComplete(repository) else { return }
    try? updateReceipt {
      let earlier = $0.failures.flatMap { $0.build == .current ? $0.count : nil } ?? 0
      $0.failures = Receipt.Failures(build: .current, count: earlier + 1)
    }
  }

  /// Core ML writes its compiled model for the Neural Engine after the download, so leave room.
  private static let compileRoom: Int64 = 300_000_000

  private func prepareDirectory() throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var excluded = URLResourceValues()
    excluded.isExcludedFromBackup = true
    var root = root
    try root.setResourceValues(excluded)
    for old in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    where old.lastPathComponent != Engine.revision {
      try manager.removeItem(at: old)
    }
  }

  private func readReceipt() -> Receipt {
    guard let data = try? Data(contentsOf: receiptFile),
      let receipt = try? JSONDecoder().decode(Receipt.self, from: data)
    else { return Receipt() }
    return receipt
  }

  private func updateReceipt(_ change: (inout Receipt) -> Void) throws {
    var receipt = readReceipt()
    change(&receipt)
    try JSONEncoder().encode(receipt).write(to: receiptFile, options: .atomic)
  }

  private static func sizes(of folder: URL) -> (files: Int64, disk: Int64) {
    let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey]
    guard let items = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [])
    else { return (0, 0) }
    var sizes: (files: Int64, disk: Int64) = (0, 0)
    for case let item as URL in items {
      guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true
      else { continue }
      sizes.files += Int64(values.fileSize ?? 0)
      sizes.disk += Int64(values.totalFileAllocatedSize ?? 0)
    }
    return sizes
  }
}

public enum ParakeetError: LocalizedError, Equatable, Sendable {
  case notEnoughSpace(needed: Int64, available: Int64)
  /// The audio route offers no input.
  case noMicrophone
  case audioFormat

  public var errorDescription: String? {
    switch self {
    case .notEnoughSpace(let needed, let available):
      "The voice model needs \(Self.bytes(needed)) free, and \(Self.bytes(available)) is free."
    case .noMicrophone:
      "No microphone is available."
    case .audioFormat:
      "The audio could not be prepared for the voice model."
    }
  }

  private static func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
  }
}

struct Receipt: Codable, Equatable {
  struct Failures: Codable, Equatable {
    var build: Build
    var count: Int
  }

  var installed: [String]?
  var warm: Build?
  var failures: Failures?
}

/// An app build and an OS build. Core ML compiles the model again after either changes.
struct Build: Codable, Equatable {
  var app: String
  var os: String

  static let current: Build = {
    let info = Bundle.main.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? ""
    let build = info["CFBundleVersion"] as? String ?? ""
    return Build(
      app: "\(version) (\(build))", os: ProcessInfo.processInfo.operatingSystemVersionString)
  }()
}
