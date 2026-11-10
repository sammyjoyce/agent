import AgentCore
import Foundation

/// Which coordinators' conversations the feed shows, not a list of recipients.
enum FeedScope: Hashable, Sendable {
  case all
  case one(ProfileID)

  var coordinator: ProfileID? {
    if case .one(let id) = self { return id }
    return nil
  }

  func shows(_ id: ProfileID) -> Bool {
    switch self {
    case .all: true
    case .one(let shown): shown == id
    }
  }

  init(sending ids: [ProfileID]) {
    self = ids.count == 1 ? .one(ids[0]) : .all
  }

  static func resolve(
    _ requested: FeedScope, profiles: [CoordinatorProfile], removed: [ProfileID: String]
  ) -> FeedScope {
    guard profiles.count > 1, case .one(let id) = requested, removed[id] == nil,
      profiles.contains(where: { $0.id == id })
    else { return .all }
    return requested
  }
}

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
  /// means every paired coordinator. A `literal` text, such as a restored message, is never read
  /// for tags, so without a chip it goes to every paired coordinator as it is. With one saved
  /// coordinator and none removed the text goes as typed. A chip naming no saved coordinator
  /// blocks Send however many are saved.
  static func parse(
    _ draft: String, hasAttachments: Bool, chip: ProfileID?, literal: Bool = false,
    among coordinators: [Coordinator], removed: [ProfileID: String] = [:]
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
      } else if !literal, !tags.isEmpty {
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
    /// Its coordinator's record says its item was withdrawn when the user sent a restored copy
    /// instead, and the coordinator refused it.
    case notSent
    /// This phone holds no record of it there: the record was never written, was capped or could
    /// not be read, or the coordinator is no longer saved.
    case unknown
  }
  let lane: ProfileID
  let status: Status
  /// What the recipient's coordinator reports about processing its copy while it is pending.
  var work: InputWorkState? = nil

  /// "To Work and Personal" once every recipient placed the Send, else nil.
  static func summary(_ receipts: [Receipt], names: [String]) -> String? {
    receipts.allSatisfy { $0.status == .placed } ? "To \(joinedNames(names))" : nil
  }

  /// This recipient's line while the Send is not placed everywhere.
  func line(_ name: String) -> String {
    switch status {
    case .placed: "\(name) · Delivered"
    case .pending(let delivery, _): "\(name) · \(delivery.rawValue)"
    case .notSent: "Not sent to \(name)"
    case .unknown: "\(name) · Status unknown"
    }
  }
}

/// One row of the feed under a feed-wide ID.
struct FeedRow: Equatable {
  let id: String
  let lane: ProfileID
  let row: ChatRow
  /// For a Send's row: everyone the Send was addressed to, in its own order.
  let receipts: [Receipt]
}

struct FeedProjection: Equatable {
  var rows: [FeedRow]
  var connection: ConnectionState
  var model: String
  var busy: Bool
  var commands: [SlashCommand]
  var canLoadEarlier: Bool
  var loadingHistory: Bool
  var includesLatest: Bool
}

enum Feed {
  static func project(
    _ lanes: [(id: ProfileID, snapshot: ChatSnapshot)], scope: FeedScope
  ) -> FeedProjection {
    let shown = lanes.filter { scope.shows($0.id) }.map(\.snapshot)
    let connection =
      [ConnectionState.connected, .reconnecting, .connecting].first { state in
        shown.contains { $0.connection == state }
      } ?? .disconnected
    var usages: Set<String> = []
    let commands = shown.flatMap(\.commands).filter { usages.insert($0.usage).inserted }
    return FeedProjection(
      rows: merge(lanes, showing: scope), connection: connection,
      model: shown.first?.model ?? "Unknown", busy: shown.contains(where: \.busy),
      commands: commands, canLoadEarlier: shown.contains { $0.olderCursor != nil },
      loadingHistory: shown.contains(where: \.loadingHistory),
      includesLatest: shown.allSatisfy(\.includesLatest))
  }

  /// Shown lanes' rows in receive order, with receipts read from every lane. A Send's user
  /// rows show once, as `send:<id>` at its first position among the shown lanes.
  static func merge(
    _ lanes: [(id: ProfileID, snapshot: ChatSnapshot)], showing scope: FeedScope = .all
  ) -> [FeedRow] {
    let ordered = lanes.enumerated().filter { scope.shows($0.element.id) }.flatMap { lane, source in
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
    guard let addressed = lanes.lazy.compactMap({ $0.snapshot.sends[send] }).first else {
      return []
    }
    return addressed.recipients.map { id in
      guard let lane = lanes.first(where: { $0.id == id }), let record = lane.snapshot.sends[send]
      else { return Receipt(lane: id, status: .unknown) }
      switch record.progress {
      case .placed: return Receipt(lane: id, status: .placed)
      case .withdrawn: return Receipt(lane: id, status: .notSent)
      case .held: return Receipt(lane: id, status: .pending(.saved, inputID: nil))
      case .pending(let delivery):
        let row = lane.snapshot.rows.first { $0.sendID == send && $0.delivery != nil }
        return Receipt(lane: id, status: .pending(delivery, inputID: row?.inputID), work: row?.work)
      }
    }
  }
}
