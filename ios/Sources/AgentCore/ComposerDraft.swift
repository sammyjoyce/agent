import CryptoKit
import Darwin
import Foundation

private enum ComposerDraftError: Error, LocalizedError {
  case invalidRecord, tooLarge, staleOwner
  var errorDescription: String? {
    switch self {
    case .invalidRecord: "The saved unsent draft could not be verified. It was preserved."
    case .tooLarge: "The unsent draft is too large to save. Shorten its text before retrying."
    case .staleOwner:
      "A newer unsent draft was saved by another owner. Reopen the composer before editing the saved draft."
    }
  }
}

/// Where the composer's restored draft came from, and what Restore put in it. The source stays
/// queued or held until a Send carries that content unchanged to its coordinator, or the user
/// discards it, so nothing its coordinator did not get is lost.
public struct RestoredSource: Codable, Sendable, Equatable {
  public enum Kind: Codable, Sendable, Equatable {
    case live
    /// Held from before the update in `queue`.
    case held(queue: UUID)
  }
  /// Its coordinator.
  public let lane: ProfileID
  public let item: String
  public let kind: Kind
  private let textDigest: String
  /// The IDs of the file copies Restore put in the composer.
  public let files: Set<String>

  public init(lane: ProfileID, item: String, kind: Kind, text: String, files: Set<String>) {
    self.lane = lane
    self.item = item
    self.kind = kind
    textDigest = Self.trimmedDigest(text)
    self.files = files
  }

  private static func trimmedDigest(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return SHA256.hash(data: Data(trimmed.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  /// True when a Send of `body` with `sentFiles` to `recipients` carries this content unchanged
  /// to its coordinator, meaning the same text, ignoring surrounding whitespace, and every file
  /// Restore put in the composer.
  public func isCarried(
    by body: String, files sentFiles: [LocalAttachment], to recipients: [ProfileID]
  ) -> Bool {
    recipients.contains(lane) && Self.trimmedDigest(body) == textDigest
      && files.isSubset(of: sentFiles.map(\.id))
  }
}

/// Where a draft goes when its text does not say. It is one value, so every check reads the chip
/// and the begin stamp together, and no draft holds both. Showing another coordinator never
/// writes it.
public enum DraftDestination: Sendable, Equatable {
  /// No chip and no stamp. Leading tags pick the recipients, else every paired coordinator.
  case open
  /// No chip. Leading tags pick the recipients, else this coordinator, whose conversation was
  /// shown when the user started the draft in an empty composer.
  case begunIn(ProfileID)
  /// The chip. This coordinator alone, and the text is literal.
  case chip(ProfileID)

  /// The coordinator the stamp or the chip names.
  public var coordinator: ProfileID? {
    switch self {
    case .open: nil
    case .begunIn(let id), .chip(let id): id
    }
  }

  public var chip: ProfileID? {
    if case .chip(let id) = self { return id }
    return nil
  }
}

/// Whom an unsent draft is for, by profile ID rather than name, so a rename cannot stale it. It is
/// saved in the same atomic record as the text, so the two never disagree on disk.
public struct DraftAddressing: Codable, Sendable, Equatable {
  /// Where the draft goes when its text does not say.
  public var destination: DraftDestination
  /// The coordinator whose restored message the draft holds.
  public var restoredFrom: ProfileID?
  /// Whose feed the automatic `/feedback` screenshot shows.
  public var screenshotOwner: ProfileID?
  /// The restored original, which a Send that carries it unchanged withdraws.
  public var source: RestoredSource?

  /// A chip keeps the `recipient` key that older records use, so they load with the meaning they
  /// had. A stamp is saved under `begunIn`.
  private enum CodingKeys: String, CodingKey {
    case recipient, begunIn, restoredFrom, screenshotOwner, source
  }

  public init(
    destination: DraftDestination = .open, restoredFrom: ProfileID? = nil,
    screenshotOwner: ProfileID? = nil, source: RestoredSource? = nil
  ) {
    self.destination = destination
    self.restoredFrom = restoredFrom
    self.screenshotOwner = screenshotOwner
    self.source = source
  }

  /// The one place the two keys become one value. A record holding both reads as the chip, since
  /// choosing a chip is the stronger act.
  public init(from decoder: any Decoder) throws {
    let keys = try decoder.container(keyedBy: CodingKeys.self)
    if let id = try keys.decodeIfPresent(ProfileID.self, forKey: .recipient) {
      destination = .chip(id)
    } else if let id = try keys.decodeIfPresent(ProfileID.self, forKey: .begunIn) {
      destination = .begunIn(id)
    } else {
      destination = .open
    }
    restoredFrom = try keys.decodeIfPresent(ProfileID.self, forKey: .restoredFrom)
    screenshotOwner = try keys.decodeIfPresent(ProfileID.self, forKey: .screenshotOwner)
    source = try keys.decodeIfPresent(RestoredSource.self, forKey: .source)
  }

  public func encode(to encoder: any Encoder) throws {
    var keys = encoder.container(keyedBy: CodingKeys.self)
    switch destination {
    case .open: break
    case .begunIn(let id): try keys.encode(id, forKey: .begunIn)
    case .chip(let id): try keys.encode(id, forKey: .recipient)
    }
    try keys.encodeIfPresent(restoredFrom, forKey: .restoredFrom)
    try keys.encodeIfPresent(screenshotOwner, forKey: .screenshotOwner)
    try keys.encodeIfPresent(source, forKey: .source)
  }

  public var isEmpty: Bool { self == DraftAddressing() }
}

public struct ComposerDraft: Sendable, Equatable {
  public var text: String
  public var mode: InputMode
  public var attachments: [LocalAttachment]
  public var consumedTransfers: Set<UUID>
  public var feedbackScreenshotID: String?
  public var addressing: DraftAddressing
  public init(
    text: String = "", mode: InputMode = .steer, attachments: [LocalAttachment] = [],
    consumedTransfers: Set<UUID> = [], feedbackScreenshotID: String? = nil,
    addressing: DraftAddressing = DraftAddressing()
  ) {
    self.text = text
    self.mode = mode
    self.attachments = attachments
    self.consumedTransfers = consumedTransfers
    self.feedbackScreenshotID = feedbackScreenshotID
    self.addressing = addressing
  }
}

/// One atomic record owns the unsent note, file references and transfer UUIDs.
/// A queued save of an older editor revision may never overwrite a newer save.
/// Each composer owner uses its own store instance.
public actor ComposerDraftStore {
  private struct Record: Codable {
    let revision: UInt64
    let text: String
    let mode: InputMode
    let attachments: [AttachmentRef]
    let consumedTransfers: Set<UUID>
    let feedbackScreenshotID: String?
    /// Absent from records saved before addressing was stored, and whenever it is empty.
    let addressing: DraftAddressing?
  }
  private static let maximumRecordBytes = 512 * 1024
  private let url: URL
  private var savedRevision: UInt64?
  private var savedData: Data?
  private var needsSynchronization = false
  public init(url: URL) { self.url = url }

  public func load(from store: AttachmentStore) async throws -> (
    draft: ComposerDraft, revision: UInt64
  ) {
    guard let data = try contents() else { return (ComposerDraft(), 0) }
    let record = try JSONDecoder().decode(Record.self, from: data)
    guard record.attachments.count <= AttachmentLimits.maximumCount,
      Set(record.attachments.map(\.id)).count == record.attachments.count,
      record.feedbackScreenshotID.map({ id in record.attachments.contains { $0.id == id } }) ?? true
    else { throw ComposerDraftError.invalidRecord }
    var files: [LocalAttachment] = []
    for reference in record.attachments {
      guard let file = try await store.existing(reference) else { throw AttachmentError.changed }
      files.append(file)
    }
    // Rehydration awaits another actor. Do not adopt an older record if a
    // different owner changed the metadata while its files were verified.
    guard try contents() == data else { throw ComposerDraftError.staleOwner }
    savedData = data
    savedRevision = max(savedRevision ?? record.revision, record.revision)
    var addressing = record.addressing ?? DraftAddressing()
    if record.feedbackScreenshotID == nil { addressing.screenshotOwner = nil }
    return (
      ComposerDraft(
        text: record.text, mode: record.mode, attachments: files,
        consumedTransfers: record.consumedTransfers,
        feedbackScreenshotID: record.feedbackScreenshotID, addressing: addressing), record.revision
    )
  }

  /// Returns false only when a newer complete record already owns the disk.
  @discardableResult public func save(_ draft: ComposerDraft, revision: UInt64) throws -> Bool {
    guard draft.attachments.count <= AttachmentLimits.maximumCount else {
      throw AttachmentError.tooMany
    }
    guard Set(draft.attachments.map(\.id)).count == draft.attachments.count,
      draft.feedbackScreenshotID.map({ id in draft.attachments.contains { $0.id == id } }) ?? true
    else { throw ComposerDraftError.invalidRecord }
    let record = Record(
      revision: revision, text: draft.text, mode: draft.mode,
      attachments: draft.attachments.map(\.reference), consumedTransfers: draft.consumedTransfers,
      feedbackScreenshotID: draft.feedbackScreenshotID,
      addressing: draft.addressing.isEmpty ? nil : draft.addressing)
    let data = try JSONEncoder().encode(record)
    guard data.count <= Self.maximumRecordBytes else { throw ComposerDraftError.tooLarge }
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    // Different scenes may have different store instances. Refuse stale owners
    // rather than silently overwriting another scene's unsent draft.
    let lockFD = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard lockFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw SharedDraftError.busy }
    guard try contents() == savedData else {
      throw ComposerDraftError.staleOwner
    }
    if let savedRevision, revision < savedRevision {
      if needsSynchronization { try synchronize(directory) }
      return false
    }
    #if os(iOS)
      try data.write(to: url, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: url, options: .atomic)
    #endif
    // The atomic rename has happened even if a later protection/fsync step fails.
    // Remember ownership and the newer record so an older queued save cannot
    // roll it back, and a retry can finish durability before acknowledging a share.
    savedRevision = revision
    savedData = data
    needsSynchronization = true
    try synchronize(directory)
    return true
  }

  private func synchronize(_ directory: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    var ownedURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try ownedURL.setResourceValues(values)
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    try file.synchronize()
    let fd = open(directory.path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    needsSynchronization = false
  }

  private func contents() throws -> Data? {
    do {
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      let data = try file.read(upToCount: Self.maximumRecordBytes + 1) ?? Data()
      guard data.count <= Self.maximumRecordBytes else { throw ComposerDraftError.invalidRecord }
      return data
    } catch let error as CocoaError
      where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile
    { return nil }
  }

}
