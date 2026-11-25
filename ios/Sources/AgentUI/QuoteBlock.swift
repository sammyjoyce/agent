import AgentCore
import SwiftUI

extension EnvironmentValues {
  @Entry var isUnderAQuoteBar = false
}

struct QuoteBlock: View {
  let quote: RichQuote
  let textStyle: Font
  let compact: Bool
  let showsCopyButton: Bool

  var body: some View {
    RichMessage(blocks: quote.blocks, textStyle: textStyle, compact: compact)
      .environment(\.isUnderAQuoteBar, true)
      .padding(.leading, 12)
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
      }
      .padding(.trailing, showsCopyButton ? CopyBlockButton.trailingWidthABlockKeepsClear : 0)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: Self.copyButtonAlignment(in: quote)) {
        if showsCopyButton { CopyBlockButton(text: quote.plainText, label: "Copy quote") }
      }
  }

  /// SwiftUI puts the first text baseline of a stack whose first child has none at the stack's
  /// bottom edge or below it.
  private static func copyButtonAlignment(in quote: RichQuote) -> Alignment {
    switch quote.blocks.first {
    case .prose, .heading, .listItem: .trailingFirstTextBaseline
    case .quote(let held, _): copyButtonAlignment(in: held)
    case .code, .divider, .table, nil: .topTrailing
    }
  }
}
