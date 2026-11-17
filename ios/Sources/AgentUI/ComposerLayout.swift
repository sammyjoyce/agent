import SwiftUI

/// Marks the one persistent editor among its controls.
struct ComposerEditorLayoutKey: LayoutValueKey {
  static let defaultValue = false
}

#if os(iOS)
  /// Probe the editor at the width it would have beside the controls, even while expanded.
  /// Using the expanded width as the threshold would make a two-line draft alternate layouts.
  /// This layout moves the same subview; it never swaps editors or touches text/selection.
  struct ComposerLayout: Layout {
    let singleLineHeight: CGFloat
    private let spacing: CGFloat = 4

    private struct Measurement {
      let editor: Int
      let controls: [Int]
      var sizes: [CGSize]
      let stacked: Bool
      let width: CGFloat
      let height: CGFloat
    }

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews) -> Measurement {
      let editor = subviews.firstIndex { $0[ComposerEditorLayoutKey.self] } ?? 0
      let controls = subviews.indices.filter { $0 != editor }
      var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
      let controlWidth = controls.reduce(CGFloat.zero) { $0 + sizes[$1].width }
      let gaps = spacing * CGFloat(controls.count)
      let width = proposal.width ?? controlWidth + gaps + sizes[editor].width
      let inlineWidth = max(1, width - controlWidth - gaps)
      let inline = subviews[editor].sizeThatFits(.init(width: inlineWidth, height: nil))
      let stacked = inline.height > singleLineHeight + 1
      sizes[editor] = subviews[editor].sizeThatFits(
        .init(width: stacked ? width : inlineWidth, height: nil))
      let rowHeight = controls.map { sizes[$0].height }.max() ?? 0
      let height =
        stacked
        ? sizes[editor].height + spacing + rowHeight : max(sizes[editor].height, rowHeight)
      return Measurement(
        editor: editor, controls: controls, sizes: sizes, stacked: stacked,
        width: width, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
      let measured = measure(proposal, subviews)
      return CGSize(width: measured.width, height: measured.height)
    }

    func placeSubviews(
      in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
      let measured = measure(.init(width: bounds.width, height: nil), subviews)
      if measured.stacked {
        let size = measured.sizes[measured.editor]
        subviews[measured.editor].place(
          at: bounds.origin, anchor: .topLeading, proposal: .init(size))
        // SwiftUI mirrors subview positions in RTL; these are semantic coordinates, not
        // physical screen edges. Keep the original control order as HStack does.
        var leading = bounds.minX
        let trailing = bounds.maxX
        for index in measured.controls {
          let size = measured.sizes[index]
          let x: CGFloat
          if index < measured.editor {
            x = leading
            leading += size.width + spacing
          } else {
            // Reserve the remaining trailing controls, keeping their original order.
            x =
              trailing
              - measured.controls.filter { $0 >= index }.reduce(CGFloat.zero) {
                $0 + measured.sizes[$1].width + spacing
              } + spacing
          }
          subviews[index].place(
            at: CGPoint(x: x, y: bounds.maxY - size.height),
            anchor: .topLeading, proposal: .init(size))
        }
      } else {
        var x = bounds.minX
        for index in subviews.indices {
          let size = measured.sizes[index]
          subviews[index].place(
            at: CGPoint(x: x, y: bounds.maxY - size.height),
            anchor: .topLeading, proposal: .init(size))
          x += size.width + spacing
        }
      }
    }
  }
#endif
