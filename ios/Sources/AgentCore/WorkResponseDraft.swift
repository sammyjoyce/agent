/// The work item and the ownership check made when the draft was first bound to it.
/// Local composer metadata only. A restored reference has no live session identity.
public struct WorkResponseReference: Codable, Sendable, Equatable {
  public let lane: ProfileID
  public let coordinator: String
  public let itemID: String
  public let conversationID: String
  public let taskID: TaskId?
  public let agentID: String?
  public let sidechatSlug: String?
  public let isJob: Bool
  public let title: String
  public let detail: String?
  public var conflictsWithLeadingTags: Bool = false

  public init(
    lane: ProfileID, coordinator: String, itemID: String, conversationID: String, taskID: TaskId?,
    agentID: String?, sidechatSlug: String?, isJob: Bool, title: String, detail: String?
  ) {
    self.lane = lane
    self.coordinator = coordinator
    self.itemID = itemID
    self.conversationID = conversationID
    self.taskID = taskID
    self.agentID = agentID
    self.sidechatSlug = sidechatSlug
    self.isJob = isJob
    self.title = title
    self.detail = detail
  }

  public func identifiesSameItem(as other: Self) -> Bool {
    lane == other.lane && itemID == other.itemID && conversationID == other.conversationID
      && taskID == other.taskID && agentID == other.agentID && sidechatSlug == other.sidechatSlug
  }
}

/// One response whose Send was refused while the composer took a different draft.
/// Its files stay in the same composer store and move back with its text and addressing.
public struct RecoveredWorkResponse: Sendable, Equatable {
  public struct Metadata: Codable, Sendable, Equatable {
    public let reference: WorkResponseReference
    public let mode: InputMode
    public let addressing: DraftAddressing

    public init(reference: WorkResponseReference, mode: InputMode, addressing: DraftAddressing) {
      self.reference = reference
      self.mode = mode
      self.addressing = addressing
    }
  }

  public let metadata: Metadata
  public let text: String
  public let attachments: [LocalAttachment]

  public init(metadata: Metadata, text: String, attachments: [LocalAttachment]) {
    self.metadata = metadata
    self.text = text
    self.attachments = attachments
  }
}
