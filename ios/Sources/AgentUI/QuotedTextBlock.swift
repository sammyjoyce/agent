import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

/// Keep each explicit copy action on the native clipboard path.
@MainActor enum MessageClipboard {
  #if os(iOS)
    static func copy(_ text: String, to pasteboard: UIPasteboard = .general) {
      pasteboard.string = text
    }
  #elseif os(macOS)
    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
      pasteboard.clearContents()
      pasteboard.setString(text, forType: .string)
    }
  #endif
}

struct QuotedTextBlock: View {
  let text: AttributedString
  let textStyle: Font
  let lineSpacing: CGFloat

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(text).font(textStyle).lineSpacing(lineSpacing).messageTextSelection()
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        MessageClipboard.copy(String(text.characters))
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
          .font(.caption)
          .frame(minWidth: 44, minHeight: 44)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Copy quoted text")
      .accessibilityHint("Copies only this quoted text, without Markdown markers")
      .accessibilityIdentifier("copyQuotedText")
      .help("Copy quoted text")
    }
    .padding(.leading, 12)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2).fill(.secondary).frame(width: 3)
    }
  }
}
