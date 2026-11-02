import Foundation
import Synchronization

/// Receive times for every session in the process, so rows from different coordinators sort
/// in the order this phone received them, even after the clock steps back.
public final class StampSource: Sendable {
  private let last = Mutex<TimeInterval>(0)
  private let now: @Sendable () -> TimeInterval

  public convenience init() { self.init(now: { Date().timeIntervalSince1970 }) }
  init(now: @escaping @Sendable () -> TimeInterval) { self.now = now }

  /// At least 1 ms after every stamp issued or loaded so far.
  func next() -> TimeInterval {
    last.withLock { last in
      last = max(now(), last + 0.001)
      return last
    }
  }

  /// Raises the floor to a stamp saved by an earlier launch.
  func seed(_ stamp: TimeInterval) { last.withLock { $0 = max($0, stamp) } }
}

/// One input in a coordinator's live outbox (`Outbox/pending.json`). A message to several
/// coordinators is one item per coordinator, each with its own input ID.
struct OutboxItem: Codable, Equatable, Sendable {
  var request: NativeRequestSubmit
  /// Shared by every coordinator's item for one Send. It never leaves the phone.
  var sendID: String
  /// Everyone the Send was addressed to, so a coordinator with no item reads as not sent.
  var recipients: [ProfileID]
  /// The pending row's receive stamp. It moves to the entry once placed.
  var queuedAt: TimeInterval

  enum CodingKeys: String, CodingKey {
    case request, recipients
    case sendID = "send_id"
    case queuedAt = "queued_at"
  }
}

/// One coordinator's receive stamps and completed sends on this phone (`Ledger.json`). It holds
/// entry IDs, times and send IDs, never message text.
struct Ledger: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    var receivedAt: TimeInterval
    var sendID: String?
    enum CodingKeys: String, CodingKey {
      case receivedAt = "received_at"
      case sendID = "send_id"
    }
  }
  struct Send: Codable, Equatable, Sendable {
    var inputID: String
    /// nil for feedback, which is acknowledged without an entry.
    var entryID: String?
    var recipients: [ProfileID]
    enum CodingKeys: String, CodingKey {
      case recipients
      case inputID = "input_id"
      case entryID = "entry_id"
    }
  }

  var entries: [String: Entry] = [:]
  var sends: [String: Send] = [:]

  /// Keeps the 2000 newest of each map and everything `rows` still shows.
  mutating func prune(keeping rows: [ChatRow]) {
    let limit = 2000
    let shownEntries = Set(rows.compactMap(\.entryID))
    let shownInputs = Set(rows.compactMap(\.inputID))
    if entries.count > limit {
      let oldest = entries.filter { !shownEntries.contains($0.key) }
        .sorted { $0.value.receivedAt < $1.value.receivedAt }.prefix(entries.count - limit)
      for (id, _) in oldest { entries[id] = nil }
    }
    if sends.count > limit {
      let entries = entries
      func stamp(_ send: Send) -> TimeInterval {
        send.entryID.flatMap { entries[$0]?.receivedAt } ?? -.infinity
      }
      let oldest = sends.filter {
        !shownInputs.contains($0.value.inputID) && !shownEntries.contains($0.value.entryID ?? "")
      }.sorted { stamp($0.value) < stamp($1.value) }.prefix(sends.count - limit)
      for (id, _) in oldest { sends[id] = nil }
    }
  }

  /// Stamps for rows in order, where `known` holds each row's saved stamp. Unknown rows fill
  /// from their neighbours, so one coordinator's order never changes: a leading run just
  /// before the first known stamp, a trailing run from `next`, a gap interpolated, and rows
  /// with nothing known as a block ending at one `next`, so a lone new row's stamp is unique.
  /// Rows sharing a key share a stamp, and stamps never decrease in row order.
  static func receiveStamps(
    keys: [String], known: [TimeInterval?], next: () -> TimeInterval
  ) -> [TimeInterval] {
    guard !known.isEmpty else { return [] }
    let step = 0.001
    var stamps = [TimeInterval](repeating: 0, count: known.count)
    let anchors = known.enumerated().compactMap { index, stamp in
      stamp.map { (index: index, stamp: $0) }
    }
    if let first = anchors.first, let last = anchors.last {
      for index in 0..<first.index {
        stamps[index] = first.stamp - Double(first.index - index) * step
      }
      for (start, end) in zip(anchors, anchors.dropFirst()) {
        stamps[start.index] = start.stamp
        for index in start.index + 1..<end.index {
          stamps[index] =
            start.stamp + (end.stamp - start.stamp) * Double(index - start.index)
            / Double(end.index - start.index)
        }
      }
      stamps[last.index] = last.stamp
      for index in last.index + 1..<known.count { stamps[index] = next() }
    } else {
      let end = next()
      for index in known.indices {
        stamps[index] = end - Double(known.count - 1 - index) * step
      }
    }
    var shared: [String: TimeInterval] = [:]
    var result: [TimeInterval] = []
    for (key, stamp) in zip(keys, stamps) {
      let stamp = shared[key] ?? stamp
      shared[key] = stamp
      result.append(max(stamp, result.last ?? stamp))
    }
    return result
  }
}
