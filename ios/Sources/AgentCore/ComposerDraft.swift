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

public struct ComposerInputIdentity: Codable, Sendable, Equatable {
  public let composerID: UUID
  public let inputID: UUID
  public init(composerID: UUID, inputID: UUID = UUID()) {
    self.composerID = composerID
    self.inputID = inputID
  }
}

public struct ComposerSubmission: Sendable, Equatable {
  public let identity: ComposerInputIdentity
  /// Each recipient's outbox. An outbox releases the receipt only when its own copy did not go,
  /// so the submission went while any of them still holds it.
  public let outboxURLs: [URL]
  public var text: String
  public var attachments: [LocalAttachment]
  public init(
    identity: ComposerInputIdentity, outboxURLs: [URL], text: String,
    attachments: [LocalAttachment]
  ) {
    self.identity = identity
    self.outboxURLs = outboxURLs
    self.text = text
    self.attachments = attachments
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
  /// The restored original, which a Send that carries it unchanged withdraws.
  public var source: RestoredSource?

  /// A chip keeps the `recipient` key that older records use, so they load with the meaning they
  /// had. A stamp is saved under `begunIn`.
  private enum CodingKeys: String, CodingKey {
    case recipient, begunIn, restoredFrom, source
  }

  public init(
    destination: DraftDestination = .open, restoredFrom: ProfileID? = nil,
    source: RestoredSource? = nil
  ) {
    self.destination = destination
    self.restoredFrom = restoredFrom
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
    try keys.encodeIfPresent(source, forKey: .source)
  }

  public var isEmpty: Bool { self == DraftAddressing() }
}

public struct ComposerDraft: Sendable, Equatable {
  public var text: String
  public var mode: InputMode
  public var attachments: [LocalAttachment]
  public var consumedTransfers: Set<UUID>
  public var composerID: UUID?
  public var submission: ComposerSubmission?
  public var addressing: DraftAddressing
  public init(
    text: String = "", mode: InputMode = .steer, attachments: [LocalAttachment] = [],
    consumedTransfers: Set<UUID> = [], composerID: UUID? = nil,
    submission: ComposerSubmission? = nil, addressing: DraftAddressing = DraftAddressing()
  ) {
    self.text = text
    self.mode = mode
    self.attachments = attachments
    self.consumedTransfers = consumedTransfers
    self.composerID = composerID
    self.submission = submission
    self.addressing = addressing
  }
}

/// One atomic record owns the unsent note, file references and transfer UUIDs.
/// A queued save of an older editor revision may never overwrite a newer save.
/// Each composer owner uses its own store instance.
public actor ComposerDraftStore {
  private struct Submission: Codable {
    let identity: ComposerInputIdentity
    let outboxPaths: [String]
    let text: String
    let attachments: [AttachmentRef]
    /// A record from a build that kept the receipt in the first recipient's outbox alone names
    /// that outbox under `outboxPath`, and loads as a submission held there alone.
    private enum LegacyKeys: String, CodingKey { case outboxPath }

    init(
      identity: ComposerInputIdentity, outboxPaths: [String], text: String,
      attachments: [AttachmentRef]
    ) {
      self.identity = identity
      self.outboxPaths = outboxPaths
      self.text = text
      self.attachments = attachments
    }

    init(from decoder: any Decoder) throws {
      let keys = try decoder.container(keyedBy: CodingKeys.self)
      identity = try keys.decode(ComposerInputIdentity.self, forKey: .identity)
      outboxPaths =
        try keys.decodeIfPresent([String].self, forKey: .outboxPaths)
        ?? [decoder.container(keyedBy: LegacyKeys.self).decode(String.self, forKey: .outboxPath)]
      text = try keys.decode(String.self, forKey: .text)
      attachments = try keys.decode([AttachmentRef].self, forKey: .attachments)
    }
  }
  private struct Record: Codable {
    let revision: UInt64
    let text: String
    let mode: InputMode
    let attachments: [AttachmentRef]
    let consumedTransfers: Set<UUID>
    let composerID: UUID?
    let submission: Submission?
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
    draft: ComposerDraft, revision: UInt64, retiredAttachments: [LocalAttachment]
  ) {
    guard let data = try contents() else { return (ComposerDraft(), 0, []) }
    let record = try JSONDecoder().decode(Record.self, from: data)
    let submitted = record.submission
    let references = (submitted?.attachments ?? []) + record.attachments
    guard references.count <= AttachmentLimits.maximumCount,
      Set(references.map(\.id)).count == references.count,
      submitted.map({ value in
        !value.outboxPaths.isEmpty
          && value.outboxPaths.allSatisfy { !$0.isEmpty && !$0.hasPrefix("/") }
      }) ?? true,
      submitted.map({ $0.identity.composerID == record.composerID }) ?? true
    else { throw ComposerDraftError.invalidRecord }
    let owned =
      try submitted.map { value in
        try value.outboxPaths.contains {
          try CoordinatorSession.ownsComposerInput(
            value.identity,
            outboxURL: url.deletingLastPathComponent().appending(path: $0).standardizedFileURL)
        }
      } ?? false
    var files: [LocalAttachment] = []
    for reference in (owned ? [] : submitted?.attachments ?? []) + record.attachments {
      guard let file = try await store.existing(reference) else { throw AttachmentError.changed }
      files.append(file)
    }
    var retired: [LocalAttachment] = []
    if owned {
      for reference in submitted?.attachments ?? [] {
        if let file = try? await store.existing(reference) { retired.append(file) }
      }
    }
    // Rehydration awaits another actor. Do not adopt an older record if a
    // different owner changed the metadata while its files were verified.
    guard try contents() == data else { throw ComposerDraftError.staleOwner }
    savedData = data
    savedRevision = max(savedRevision ?? record.revision, record.revision)
    var text = record.text
    if let submitted, !owned, !submitted.text.isEmpty {
      text = submitted.text + (text.isEmpty ? "" : "\n\n" + text)
    }
    var addressing = record.addressing ?? DraftAddressing()
    // An outbox holds the Send this record was saved for, and whom that draft was for went with
    // it. Only a draft begun since keeps an address.
    if owned, record.text.isEmpty, record.attachments.isEmpty { addressing = DraftAddressing() }
    return (
      ComposerDraft(
        text: text, mode: record.mode, attachments: files,
        consumedTransfers: record.consumedTransfers, composerID: record.composerID,
        addressing: addressing),
      record.revision, retired
    )
  }

  /// Returns false only when a newer complete record already owns the disk.
  @discardableResult public func save(_ draft: ComposerDraft, revision: UInt64) throws -> Bool {
    let references = (draft.submission?.attachments ?? []) + draft.attachments
    guard references.count <= AttachmentLimits.maximumCount else {
      throw AttachmentError.tooMany
    }
    guard Set(references.map(\.id)).count == references.count,
      draft.submission.map({ $0.identity.composerID == draft.composerID }) ?? true,
      draft.submission.map({ !$0.outboxURLs.isEmpty }) ?? true
    else { throw ComposerDraftError.invalidRecord }
    let submission =
      try draft.submission.map { value in
        Submission(
          identity: value.identity,
          outboxPaths: try value.outboxURLs.map { try relativeOutboxPath($0) }, text: value.text,
          attachments: value.attachments.map(\.reference))
      }
    let record = Record(
      revision: revision, text: draft.text, mode: draft.mode,
      attachments: draft.attachments.map(\.reference), consumedTransfers: draft.consumedTransfers,
      composerID: draft.composerID, submission: submission,
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
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      if code == EWOULDBLOCK { throw SharedDraftError.busy }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    // A spawned child may retain the descriptor until exec. End ownership at
    // this transaction's boundary, rather than waiting for every copy to close.
    defer { _ = flock(lockFD, LOCK_UN) }
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

  private func relativeOutboxPath(_ owner: URL) throws -> String {
    guard owner.isFileURL else { throw ComposerDraftError.invalidRecord }
    // Anchor ownership to this record's current location. iOS can move the
    // entire data container between launches without changing its contents.
    let base = url.deletingLastPathComponent().standardizedFileURL.pathComponents
    let target = owner.standardizedFileURL.pathComponents
    let common = zip(base, target).prefix { $0 == $1 }.count
    return (Array(repeating: "..", count: base.count - common) + target.dropFirst(common))
      .joined(separator: "/")
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
