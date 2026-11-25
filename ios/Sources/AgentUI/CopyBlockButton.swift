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
  private static let touchTargetHeightBeyondEachGlyphEdge: CGFloat = 15
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
        .layoutFrameAsTallAsTouchTarget(addingToEachEdge: Self.touchTargetHeightBeyondEachGlyphEdge)
        .hitAreaWiderThanLayoutFrame(by: (Self.touchTargetWidth - Self.glyphWidth) / 2)
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
  fileprivate func layoutFrameAsTallAsTouchTarget(addingToEachEdge height: CGFloat) -> some View {
    padding(.vertical, height)
  }

  fileprivate func hitAreaWiderThanLayoutFrame(by width: CGFloat) -> some View {
    padding(.horizontal, width).contentShape(Rectangle()).padding(.horizontal, -width)
  }
}
