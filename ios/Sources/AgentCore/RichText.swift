import Dispatch
import Foundation
import Synchronization

public enum RichBlock: Sendable, Equatable {
  case prose(AttributedString)
  case heading(AttributedString, level: Int)
  case code(String, language: String)
  /// One whole Markdown block quote. `listItemDepth` is the `depth` of the list item that holds
  /// the quote, and nil when no list item holds it.
  case quote(RichQuote, listItemDepth: Int? = nil)
  case listItem(AttributedString, marker: String, depth: Int)
  case divider
  case table([[AttributedString]])
}

/// One whole Markdown block quote: every block it holds, in order.
public struct RichQuote: Sendable, Equatable {
  public let blocks: [RichBlock]

  init(_ blocks: [RichBlock]) { self.blocks = blocks }

  /// The quote as plain text for another app. Blocks are one blank line apart, and two list items
  /// in a row are one line apart. A link is its text, a list item keeps the marker the screen
  /// shows, and a table has a tab between cells.
  public var plainText: String { Self.plainText(of: blocks) }

  private static func plainText(of blocks: [RichBlock]) -> String {
    var text = ""
    var afterListItem = false
    for block in blocks {
      let part: String
      var isListItem = false
      switch block {
      case .prose(let prose): part = String(prose.characters)
      case .heading(let heading, _): part = String(heading.characters)
      case .code(let code, _): part = code
      case .quote(let quote, let listItemDepth):
        let indent = String(repeating: "    ", count: listItemDepth.map { $0 + 1 } ?? 0)
        part = quote.plainText.split(separator: "\n", omittingEmptySubsequences: false)
          .map { indent + ($0.isEmpty ? ">" : "> \($0)") }.joined(separator: "\n")
      case .listItem(let item, let marker, let depth):
        let words = [marker, String(item.characters)].filter { !$0.isEmpty }
        part = String(repeating: "    ", count: depth) + words.joined(separator: " ")
        isListItem = true
      case .divider: part = "---"
      case .table(let rows):
        part = rows.map { $0.map { String($0.characters) }.joined(separator: "\t") }
          .joined(separator: "\n")
      }
      if !text.isEmpty { text += afterListItem && isListItem ? "\n" : "\n\n" }
      text += part
      afterListItem = isListItem
    }
    return text
  }
}

/// Foundation owns Markdown syntax; the session actor owns ordered snapshots.
public enum RichText {
  /// Separates adjacent bolded reasoning headings (`**First****Second**` ->
  /// `**First**\n\n**Second**`) while preserving inline bold, code spans, fences,
  /// and standalone thematic breaks.
  public static func separateReasoningSummaries(_ text: String) -> String {
    guard text.contains("****") else { return text }
    var output = ""
    output.reserveCapacity(text.utf8.count + 16)
    let scalars = Array(text.unicodeScalars)
    let count = scalars.count
    var index = 0
    var inlineBackticks = 0
    var fenceBackticks = 0
    var lineStart = true

    while index < count {
      let scalar = scalars[index]
      if fenceBackticks > 0 {
        if lineStart {
          var spaces = index
          while spaces < count && scalars[spaces] == " " { spaces += 1 }
          var ticks = spaces
          while ticks < count && scalars[ticks] == "`" { ticks += 1 }
          if ticks - spaces >= fenceBackticks {
            var tail = ticks
            while tail < count && (scalars[tail] == " " || scalars[tail] == "\t") { tail += 1 }
            if tail == count || scalars[tail] == "\n" { fenceBackticks = 0 }
          }
        }
        output.unicodeScalars.append(scalar)
        lineStart = scalar == "\n"
        index += 1
        continue
      }

      if scalar == "`" {
        var end = index
        while end < count && scalars[end] == "`" { end += 1 }
        let run = end - index
        if inlineBackticks == 0 {
          if lineStart && run >= 3 {
            var cursor = end
            var hasBacktick = false
            while cursor < count && scalars[cursor] != "\n" {
              if scalars[cursor] == "`" { hasBacktick = true }
              cursor += 1
            }
            if !hasBacktick { fenceBackticks = run }
          } else {
            inlineBackticks = run
          }
        } else if run == inlineBackticks {
          inlineBackticks = 0
        }
        for cursor in index..<end { output.unicodeScalars.append(scalars[cursor]) }
        lineStart = false
        index = end
        continue
      }

      if inlineBackticks == 0 && scalar == "*" {
        var end = index
        while end < count && scalars[end] == "*" { end += 1 }
        if end - index == 4, index > 0, end < count {
          let before = scalars[index - 1]
          let after = scalars[end]
          let wordBefore = !CharacterSet.whitespacesAndNewlines.contains(before) && before != "*"
          let wordAfter = !CharacterSet.whitespacesAndNewlines.contains(after) && after != "*"
          if wordBefore && wordAfter {
            output.append("**\n\n**")
            lineStart = false
            index = end
            continue
          }
        }
        for cursor in index..<end { output.unicodeScalars.append(scalars[cursor]) }
        lineStart = false
        index = end
        continue
      }

      output.unicodeScalars.append(scalar)
      lineStart = scalar == "\n"
      index += 1
    }
    return output
  }

  static func prepare(_ texts: [String]) -> [[RichBlock]] {
    guard texts.count > 1 else { return texts.map(parse) }
    let workers = min(4, ProcessInfo.processInfo.activeProcessorCount, texts.count)
    let result = Mutex([[RichBlock]](repeating: [], count: texts.count))
    // Complete row texts have independent Markdown scopes. Join all bounded
    // workers before returning to the actor; no worker can mutate its state.
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      for index in stride(from: worker, to: texts.count, by: workers) {
        let blocks = parse(texts[index])
        result.withLock { $0[index] = blocks }
      }
    }
    return result.withLock { $0 }
  }

  public static func parse(_ text: String) -> [RichBlock] {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    guard let parsed = try? AttributedString(markdown: text) else {
      return [.prose(AttributedString(text))]
    }
    return blocks(
      in: Array(parsed.runs[\.presentationIntent])[...], of: parsed, enclosingComponentCount: 0)
  }

  private typealias Run = (PresentationIntent?, Range<AttributedString.Index>)

  /// Foundation lists a run's components innermost first.
  private static func blocks(
    in runs: ArraySlice<Run>, of parsed: AttributedString, enclosingComponentCount: Int
  ) -> [RichBlock] {
    var blocks: [RichBlock] = []
    var leafID: Int?
    var leafComponents: ArraySlice<PresentationIntent.IntentType> = []
    var leafText = AttributedString()
    var markedListItems: Set<Int> = []
    var tableID: Int?
    var tableRows: [[AttributedString]] = []
    func flushLeaf() {
      if !leafText.characters.isEmpty {
        blocks.append(
          block(leafText, components: leafComponents, markedListItems: &markedListItems))
      }
      leafID = nil
      leafComponents = []
      leafText = AttributedString()
    }
    func flushTable() {
      if !tableRows.isEmpty { blocks.append(.table(tableRows)) }
      tableID = nil
      tableRows = []
    }
    var index = runs.startIndex
    while index < runs.endIndex {
      let (intent, range) = runs[index]
      let components = (intent?.components ?? []).dropLast(enclosingComponentCount)
      if let quoteAt = components.lastIndex(where: { $0.kind == .blockQuote }) {
        flushLeaf()
        flushTable()
        let quote = components[quoteAt]
        // Every run of one block quote carries that quote's component, and its runs are adjacent.
        let end =
          runs[index...].firstIndex { !($0.0?.components.contains(quote) ?? false) }
          ?? runs.endIndex
        let item = innermostListItem(components[(quoteAt + 1)...])
        if let item, markedListItems.insert(item.itemID).inserted {
          blocks.append(.listItem(AttributedString(), marker: item.marker, depth: item.depth))
        }
        let held = Self.blocks(
          in: runs[index..<end], of: parsed,
          enclosingComponentCount: enclosingComponentCount + components[quoteAt...].count)
        blocks.append(.quote(RichQuote(held), listItemDepth: item?.depth))
        index = end
        continue
      }
      index += 1
      var value = AttributedString(parsed[range])
      value.presentationIntent = nil
      if #available(iOS 26, macOS 26, *) { value.listItemDelimiter = nil }
      // Foundation represents soft line breaks as attributed spaces. Preserve
      // the model's line boundaries while retaining all other inline styling.
      let breaks: [(Bool, Range<AttributedString.Index>)] = value.runs[\.inlinePresentationIntent]
        .compactMap { flags, range in
          guard let flags, flags.contains(.softBreak) || flags.contains(.lineBreak) else {
            return nil
          }
          return (flags.contains(.softBreak), range)
        }
      for (soft, range) in breaks.reversed() {
        if soft {
          value.replaceSubrange(range, with: AttributedString("\n"))
        } else {
          value[range].inlinePresentationIntent = nil
        }
      }
      if let component = components.first(where: {
        if case .table = $0.kind { return true }
        return false
      }), case .table(let columns) = component.kind {
        flushLeaf()
        if tableID != component.identity {
          flushTable()
          tableID = component.identity
        }
        var row = 0
        var column = 0
        for part in components {
          if case .tableRow(let index) = part.kind { row = index }
          if case .tableCell(let index) = part.kind { column = index }
        }
        guard row >= 0, columns.indices.contains(column) else {
          flushTable()
          blocks.append(.prose(value))
          continue
        }
        // Empty cells have no attributed runs; native row/column indexes keep
        // their positions, including an entirely empty row before later data.
        while tableRows.count <= row {
          tableRows.append(Array(repeating: AttributedString(), count: columns.count))
        }
        tableRows[row][column].append(value)
        continue
      }
      flushTable()
      let identity = components.first?.identity
      if leafID != identity {
        flushLeaf()
        leafID = identity
        leafComponents = components
      }
      leafText.append(value)
    }
    flushLeaf()
    flushTable()
    return blocks
  }

  private static func block(
    _ text: AttributedString, components: ArraySlice<PresentationIntent.IntentType>,
    markedListItems: inout Set<Int>
  ) -> RichBlock {
    switch components.first?.kind {
    case .header(let level): return .heading(text, level: level)
    case .codeBlock(let language):
      var code = String(text.characters)
      if code.hasSuffix("\n") { code.removeLast() }
      return .code(code, language: language ?? "")
    case .thematicBreak: return .divider
    default: break
    }
    if let item = innermostListItem(components) {
      let marker = markedListItems.insert(item.itemID).inserted ? item.marker : ""
      return .listItem(text, marker: marker, depth: item.depth)
    }
    return .prose(text)
  }

  private static func innermostListItem(_ components: ArraySlice<PresentationIntent.IntentType>)
    -> (itemID: Int, marker: String, depth: Int)?
  {
    var ordinal: Int?
    var itemID: Int?
    var ordered: Bool?
    var depth = -1
    for component in components {
      switch component.kind {
      case .listItem(let index):
        if ordinal == nil {
          ordinal = index
          itemID = component.identity
        }
      case .orderedList:
        if ordered == nil { ordered = true }
        depth += 1
      case .unorderedList:
        if ordered == nil { ordered = false }
        depth += 1
      default: break
      }
    }
    guard let ordinal, let ordered, let itemID else { return nil }
    return (itemID, ordered ? "\(ordinal)." : "•", max(depth, 0))
  }
}
