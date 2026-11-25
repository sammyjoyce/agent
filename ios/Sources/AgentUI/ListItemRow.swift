import SwiftUI

struct ListItemRow<Content: View>: View {
  let marker: String
  let depth: Int
  let markerFont: Font
  @ViewBuilder let content: Content
  @ScaledMetric(relativeTo: .body) private var listIndent = 16
  @ScaledMetric(relativeTo: .body) private var listMarkerWidth = 24

  var body: some View {
    HStack(alignment: markerAlignment, spacing: 8) {
      Text(marker).font(markerFont).frame(minWidth: listMarkerWidth, alignment: .trailing)
      content
    }
    .padding(.leading, CGFloat(depth) * listIndent)
  }

  /// An empty marker is still a line of text. Content with no text line holds that line's
  /// baseline at its own bottom edge, which makes the row taller than the content.
  private var markerAlignment: VerticalAlignment {
    marker.isEmpty ? .top : .firstTextBaseline
  }
}
