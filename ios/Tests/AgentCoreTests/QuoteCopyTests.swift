import Foundation
import Testing

@testable import AgentCore
@testable import AgentUI

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

@Suite struct QuoteCopyTests {
  @MainActor @Test func quotedBlocksCopyTheirOwnRenderedTextToANativePasteboard() throws {
    let source = """
      **First route**
      > Take the **blue** path.
      > Meet at the café — 😀.

      **Second route**
      > Try the [green path](https://example.invalid/route).

      End of the invented note.
      """
    let quotes = RichText.parse(source).compactMap { block -> AttributedString? in
      if case .quote(let text) = block { return text }
      return nil
    }
    #expect(quotes.count == 2)
    let expected = ["Take the blue path.\nMeet at the café — 😀.", "Try the green path."]
    #if os(macOS)
      let board = NSPasteboard.withUniqueName()
      defer { board.releaseGlobally() }
    #elseif os(iOS)
      let board = UIPasteboard.withUniqueName()
      defer { UIPasteboard.remove(withName: board.name) }
    #endif
    for (quote, wanted) in zip(quotes, expected) {
      MessageClipboard.copy(String(quote.characters), to: board)
      #if os(macOS)
        #expect(board.string(forType: .string) == wanted)
      #elseif os(iOS)
        #expect(board.string == wanted)
      #endif
    }
    // The existing whole-message action still copies its complete Markdown source.
    MessageClipboard.copy(source, to: board)
    #if os(macOS)
      #expect(board.string(forType: .string) == source)
    #elseif os(iOS)
      #expect(board.string == source)
    #endif
  }
}
