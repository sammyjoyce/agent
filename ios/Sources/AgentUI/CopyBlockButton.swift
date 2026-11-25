import SwiftUI

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import AppKit
#endif

func copyToPasteboard(_ text: String) {
  #if os(iOS)
    UIPasteboard.general.string = text
  #elseif os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #endif
}

struct CopyBlockButton: View {
  private static let touchTargetWidth: CGFloat = 44
  private static let glyphWidth: CGFloat = 24
  static let trailingWidthABlockKeepsClear = glyphWidth + 8
  private static let typeSizeCapSoTheGlyphFitsItsWidth = DynamicTypeSize.xxxLarge

  let text: String
  let label: String
  @State private var copiedAt: Date?

  var body: some View {
    Button {
      copyToPasteboard(text)
      copiedAt = .now
    } label: {
      symbolLaidOutAsText
        .font(.footnote).foregroundStyle(.secondary)
        .dynamicTypeSize(...Self.typeSizeCapSoTheGlyphFitsItsWidth)
        .frame(width: Self.glyphWidth)
        .hitAreaLargerThanLayoutFrame(
          horizontal: (Self.touchTargetWidth - Self.glyphWidth) / 2, vertical: 15)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label).accessibilityValue(copiedAt == nil ? "" : "Copied")
    .sensoryFeedback(.success, trigger: copiedAt) { $1 != nil }
    .task(id: copiedAt) {
      guard copiedAt != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
      copiedAt = nil
    }
  }

  private var symbolLaidOutAsText: Text {
    Text(Image(systemName: copiedAt == nil ? "doc.on.doc" : "checkmark"))
  }
}

extension View {
  fileprivate func hitAreaLargerThanLayoutFrame(horizontal: CGFloat, vertical: CGFloat)
    -> some View
  {
    padding(.horizontal, horizontal).padding(.vertical, vertical).contentShape(Rectangle())
      .padding(.horizontal, -horizontal).padding(.vertical, -vertical)
  }
}
