#if os(iOS)
  import SwiftUI
  import UIKit

  /// The composer's draft. Its first line starts `indent` points in, after the chip laid over
  /// its top leading corner, and wrapped lines start at its leading edge. SwiftUI's text field
  /// can only wrap the draft in a column beside the chip.
  struct ComposerField: UIViewRepresentable {
    static let inset = UIEdgeInsets(top: 11, left: 2, bottom: 11, right: 2)
    static let maximumLines: CGFloat = 6
    let text: String
    let placeholder: String
    let indent: CGFloat
    let edit: (String) -> Void
    /// The draft's vertical scroll once it passes six lines, so the chip can move with it.
    let scroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DraftView {
      let view = DraftView()
      view.delegate = context.coordinator
      view.accessibilityLabel = "Message the coordinator"
      view.accessibilityIdentifier = "Message the coordinator"
      return view
    }

    func updateUIView(_ view: DraftView, context: Context) {
      context.coordinator.field = self
      // The view keeps its own text, so a change made in code, such as Send's clear, is
      // applied here whatever the keyboard last did.
      if view.text != text { view.text = text }
      view.placeholder.text = placeholder
      view.placeholder.isHidden = !text.isEmpty
      view.indent = indent
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: DraftView, context: Context)
      -> CGSize?
    {
      guard let width = proposal.width, width.isFinite else { return nil }
      let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
      let limit =
        (view.font?.lineHeight ?? 0) * Self.maximumLines + Self.inset.top + Self.inset.bottom
      view.isScrollEnabled = fitting > limit
      return CGSize(width: width, height: min(fitting, limit))
    }

    final class DraftView: UITextView {
      let placeholder = UILabel()
      var indent: CGFloat = 0 {
        didSet {
          guard indent != oldValue else { return }
          let line = font?.lineHeight ?? 0
          // Any line fragment this rect touches starts after it. Half a line touches only
          // the first.
          textContainer.exclusionPaths =
            indent > 0
            ? [UIBezierPath(rect: CGRect(x: 0, y: 0, width: indent, height: line / 2))] : []
          setNeedsLayout()
        }
      }

      init() {
        super.init(frame: .zero, textContainer: nil)
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        backgroundColor = .clear
        textContainerInset = ComposerField.inset
        textContainer.lineFragmentPadding = 0
        isScrollEnabled = false
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        placeholder.font = font
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.isAccessibilityElement = false
        addSubview(placeholder)
      }
      required init?(coder: NSCoder) { return nil }

      /// An empty draft reads its placeholder, as the text field before it did. A text view has
      /// no placeholder of its own to report.
      override var accessibilityValue: String? {
        get { text.isEmpty ? placeholder.text : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        let leading = textContainerInset.left + indent
        placeholder.frame = CGRect(
          x: leading, y: textContainerInset.top,
          width: max(0, bounds.width - leading - textContainerInset.right),
          height: placeholder.font.lineHeight.rounded(.up))
      }
    }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
      var field: ComposerField?
      func textViewDidChange(_ view: UITextView) { field?.edit(view.text) }
      func scrollViewDidScroll(_ view: UIScrollView) { field?.scroll(view.contentOffset.y) }
    }
  }
#endif
