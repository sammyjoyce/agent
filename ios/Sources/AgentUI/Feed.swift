import AgentCore
import Foundation

/// Who a draft goes to, or why Send is blocked. The recipient line and Send both read it.
enum Addressing: Equatable {
  /// Send reaches these coordinators, in profile order, with this body.
  case to([ProfileID], body: String)
  /// Nothing to send yet. It would reach these.
  case empty([ProfileID])
  case blocked(String)

  /// A saved coordinator as addressing sees it.
  struct Coordinator: Equatable {
    let id: ProfileID
    let name: String
    let paired: Bool
    let connected: Bool
  }

  /// With two or more saved coordinators, or one once another was `removed`, `chip` names the
  /// one recipient and the text is literal. Without a chip, leading `@Name` tags pick the
  /// recipients and are not sent, a tag naming no saved coordinator blocks Send, and no tag
  /// means every paired coordinator. With one saved coordinator and none removed the text goes
  /// as typed. A chip naming no saved coordinator blocks Send however many are saved.
  static func parse(
    _ draft: String, hasAttachments: Bool, chip: ProfileID?, among coordinators: [Coordinator],
    removed: [ProfileID: String] = [:]
  ) -> Addressing {
    let (tags, rest) = leadingTags(draft)
    func named(_ word: Substring) -> [Coordinator] {
      coordinators.filter { $0.name.lowercased() == word.lowercased() }
    }
    if let chip, !coordinators.contains(where: { $0.id == chip }) {
      return .blocked(
        removed[chip].map { "\($0) was removed" } ?? "Choose who receives this message")
    }
    var recipients = coordinators.filter(\.paired)
    var body = Substring(draft)
    if coordinators.count > 1 || !removed.isEmpty {
      if let chip {
        recipients = coordinators.filter { $0.id == chip }
      } else if !tags.isEmpty {
        var tagged: Set<ProfileID> = []
        for word in tags {
          guard !word.isEmpty else { return .blocked("Choose a coordinator") }
          let named = named(word)
          guard let match = named.first, named.count == 1 else {
            // A tag still being typed that starts a saved name is not an error yet.
            if named.isEmpty, word.endIndex == draft.endIndex,
              coordinators.contains(where: { $0.name.lowercased().hasPrefix(word.lowercased()) })
            {
              return .blocked("Choose a coordinator")
            }
            return .blocked(
              named.isEmpty
                ? "No coordinator named \(word)" : "More than one coordinator is named \(word)")
          }
          tagged.insert(match.id)
        }
        recipients = coordinators.filter { tagged.contains($0.id) }
        body = rest
      }
      if let unpaired = recipients.first(where: { !$0.paired }) {
        return .blocked("\(unpaired.name) is not paired yet")
      }
    }
    guard !recipients.isEmpty else { return .blocked("No coordinator is paired yet") }
    let offline = recipients.filter { !$0.connected }.map(\.name)
    guard offline.isEmpty else {
      return .blocked("\(joinedNames(offline)) \(offline.count == 1 ? "is" : "are") not connected")
    }
    let ids = recipients.map(\.id)
    if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments {
      return .empty(ids)
    }
    return .to(ids, body: String(body))
  }

  /// The draft's leading `@Name` words, and the text after them.
  static func leadingTags(_ draft: String) -> (tags: [Substring], body: Substring) {
    var tags: [Substring] = []
    var body = Substring(draft)
    while body.first == "@" {
      let word = body.dropFirst().prefix { !$0.isWhitespace }
      tags.append(word)
      body = body[word.endIndex...].drop(while: \.isWhitespace)
    }
    return (tags, body)
  }
}

/// "Work", "Work and Personal", "Work, Personal and Home".
func joinedNames(_ names: [String]) -> String {
  guard let last = names.last, names.count > 1 else { return names.joined() }
  return names.dropLast().joined(separator: ", ") + " and " + last
}

/// How far one recipient got with a Send, read from its coordinator's records rather than
/// its loaded rows.
struct Receipt: Equatable {
  enum Status: Equatable {
    case placed
    case pending(Delivery, inputID: String?)
    /// Addressed, but this phone holds no record of it there: its record was capped or
    /// withdrawn, or the coordinator is no longer saved. It may well have been placed.
    case unknown
  }
  let lane: ProfileID
  let status: Status
}

/// One row of the feed under a feed-wide ID.
struct FeedRow: Equatable {
  let id: String
  let lane: ProfileID
  let row: ChatRow
  /// For a Send's row: everyone the Send was addressed to, in its own order.
  let receipts: [Receipt]
}

enum Feed {
  /// Every lane's rows in the order this phone received them: by receive time, then lane
  /// order, then row order, which keeps each coordinator's own order. Row IDs become
  /// `<profile>/<row>`. A Send's user rows show once, as `send:<id>` at its first position.
  static func merge(_ lanes: [(id: ProfileID, snapshot: ChatSnapshot)]) -> [FeedRow] {
    let ordered = lanes.enumerated().flatMap { lane, source in
      source.snapshot.rows.enumerated().map { index, row in
        (stamp: row.receivedAt ?? .distantPast, lane: lane, index: index, id: source.id, row: row)
      }
    }.sorted { ($0.stamp, $0.lane, $0.index) < ($1.stamp, $1.lane, $1.index) }
    var shownIn: [String: ProfileID] = [:]
    var result: [FeedRow] = []
    for entry in ordered {
      let namespaced = FeedRow(
        id: "\(entry.id)/\(entry.row.id)", lane: entry.id, row: entry.row, receipts: [])
      guard entry.row.role == .user, let send = entry.row.sendID else {
        result.append(namespaced)
        continue
      }
      if let lane = shownIn[send] {
        // A further segment of the shown entry stays. Another coordinator's copy folds away.
        if lane == entry.id { result.append(namespaced) }
        continue
      }
      shownIn[send] = entry.id
      result.append(
        FeedRow(
          id: "send:\(send)", lane: entry.id, row: entry.row, receipts: receipts(send, lanes)))
    }
    return result
  }

  private static func receipts(
    _ send: String, _ lanes: [(id: ProfileID, snapshot: ChatSnapshot)]
  ) -> [Receipt] {
    guard let addressed = lanes.lazy.compactMap({ $0.snapshot.sends[send]?.recipients }).first
    else { return [] }
    return addressed.map { id in
      guard let lane = lanes.first(where: { $0.id == id }), let record = lane.snapshot.sends[send]
      else { return Receipt(lane: id, status: .unknown) }
      guard let delivery = record.delivery else { return Receipt(lane: id, status: .placed) }
      let input = lane.snapshot.rows.first { $0.sendID == send && $0.delivery != nil }?.inputID
      return Receipt(lane: id, status: .pending(delivery, inputID: input))
    }
  }
}
