#if os(iOS)
  import SwiftUI
  import UIKit

  /// The composer's draft, with the recipient chip on its first line like a word typed there.
  /// Wrapped lines start at the field's leading edge, under the chip. SwiftUI's text field can
  /// only wrap the draft in a column beside the chip.
  struct ComposerField: UIViewRepresentable {
    /// The coordinator the chip names, in its color.
    struct Chip: Equatable {
      let name: String
      let color: UIColor
    }
    static let inset = UIEdgeInsets(top: 11, left: 2, bottom: 11, right: 2)
    static let maximumLines: CGFloat = 6
    let text: String
    let placeholder: String
    let chip: Chip?
    /// Send clears this field's own buffer through it, in the event that takes the text.
    let editor: ComposerEditor
    let edit: (String) -> Void
    let removeChip: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> DraftBox {
      let box = DraftBox()
      let coordinator = context.coordinator
      box.draft.delegate = coordinator
      box.remove = { [weak coordinator] in coordinator?.field?.removeChip() }
      editor.view = box.draft
      return box
    }

    func updateUIView(_ box: DraftBox, context: Context) {
      context.coordinator.field = self
      let view = box.draft
      // The view keeps its own text, so a change made in code, such as Send's clear, is
      // applied here whatever the keyboard last did. The caret keeps its place in the text
      // around the change, so a tag that became the chip leaves it where the user typed.
      if view.text != text {
        let selection = Self.selection(view.selectedRange, from: view.text, to: text)
        view.text = text
        view.selectedRange = selection
      }
      view.placeholder.text = placeholder
      view.placeholder.isHidden = !text.isEmpty
      // SwiftUI's `disabled` reaches a UIKit view only through the environment.
      view.isEditable = context.environment.isEnabled
      box.chip = chip
    }

    /// Where `range` in `old` falls once the text becomes `new`: text before the change and after
    /// it keeps its place, and a position inside the change goes to its end.
    static func selection(_ range: NSRange, from old: String, to new: String) -> NSRange {
      let head = zip(old, new).prefix { $0 == $1 }.count
      let tail = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.prefix(
        min(old.count, new.count) - head
      ).count
      let kept = old.prefix(head).utf16.count
      let oldEnd = old.utf16.count - old.suffix(tail).utf16.count
      let newEnd = new.utf16.count - new.suffix(tail).utf16.count
      func moved(_ location: Int) -> Int {
        if location < kept { return location }
        if location >= oldEnd { return location - oldEnd + newEnd }
        return newEnd
      }
      let start = moved(range.location)
      return NSRange(location: start, length: max(0, moved(NSMaxRange(range)) - start))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView box: DraftBox, context: Context)
      -> CGSize?
    {
      guard let width = proposal.width, width.isFinite else { return nil }
      box.fitChip(width: width)
      let view = box.draft
      let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
      let limit =
        (view.font?.lineHeight ?? 0) * Self.maximumLines + Self.inset.top + Self.inset.bottom
      view.isScrollEnabled = fitting > limit
      return CGSize(width: width, height: min(fitting, limit))
    }

    /// The draft and its chip in one box that clips them, so the chip takes a tap only where it is
    /// drawn: on the first line, inside the field.
    final class DraftBox: UIView {
      let draft = DraftView()
      private let button = UIButton(configuration: .plain())
      private var titleSize: CGFloat = 0
      var remove: () -> Void = {}
      var chip: Chip? {
        didSet {
          guard chip != oldValue else { return }
          titleSize = 0
          button.isHidden = chip == nil
          button.accessibilityLabel = chip.map { "To \($0.name)" }
          // VoiceOver can remove the recipient from the draft, even with the chip scrolled away.
          draft.accessibilityCustomActions =
            chip == nil
            ? nil
            : [
              UIAccessibilityCustomAction(name: "Remove recipient") { [weak self] _ in
                self?.remove()
                return true
              }
            ]
          setNeedsLayout()
        }
      }

      init() {
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(draft)
        addSubview(button)
        button.isHidden = true
        button.accessibilityHint =
          "Removes the recipient, so the message goes to every coordinator."
        button.addAction(UIAction { [weak self] _ in self?.remove() }, for: .primaryActionTriggered)
      }
      required init?(coder: NSCoder) { return nil }

      /// Sizes the chip to one line of the draft. A chip that leaves a third of the line beside it
      /// shares the first line with the draft. A wider one takes the first line, truncating a name
      /// too long for it, and the draft starts under it.
      func fitChip(width: CGFloat) {
        guard let chip, let font = draft.font else {
          draft.chipRoom = .none
          return
        }
        if titleSize != font.pointSize {
          titleSize = font.pointSize
          var configuration = UIButton.Configuration.plain()
          configuration.contentInsets = .zero
          configuration.imagePlacement = .trailing
          configuration.imagePadding = 3
          configuration.image = UIImage(systemName: "xmark.circle.fill")
          configuration.preferredSymbolConfigurationForImage = .init(textStyle: .caption1)
          configuration.baseForegroundColor = chip.color
          configuration.titleLineBreakMode = .byTruncatingTail
          configuration.attributedTitle = AttributedString(
            "@\(chip.name)",
            attributes: AttributeContainer([
              .font: UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            ]))
          button.configuration = configuration
        }
        let line = width - ComposerField.inset.left - ComposerField.inset.right
        let natural = button.intrinsicContentSize.width
        if natural + 4 <= line * 2 / 3 {
          button.bounds.size = CGSize(width: natural, height: font.lineHeight)
          draft.chipRoom = .beside(natural + 4)
        } else {
          button.bounds.size = CGSize(width: min(natural, line), height: font.lineHeight)
          draft.chipRoom = .above(font.lineHeight)
        }
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        draft.frame = bounds
        fitChip(width: bounds.width)
        button.frame.origin = CGPoint(
          x: ComposerField.inset.left, y: ComposerField.inset.top - draft.contentOffset.y)
        // VoiceOver reads the recipient, then the draft. It reaches the chip only while all of
        // it shows, so its frame never lies over the feed.
        accessibilityElements =
          chip != nil && bounds.contains(button.frame) ? [button, draft] : [draft]
      }
    }

    final class DraftView: UITextView {
      /// The room the chip takes from the draft.
      enum ChipRoom: Equatable {
        case none
        /// The first line starts this far in, after the chip.
        case beside(CGFloat)
        /// The chip takes a first line this tall, and the draft starts under it.
        case above(CGFloat)
      }
      let placeholder = UILabel()
      var chipRoom = ChipRoom.none {
        didSet {
          guard chipRoom != oldValue else { return }
          textContainerInset = ComposerField.inset
          textContainer.exclusionPaths = []
          switch chipRoom {
          case .none: break
          case .beside(let indent):
            // Any line fragment this rect touches starts after it. Half a line touches only
            // the first. TextKit ignores a rect that leaves the line no room, hence `above`.
            let line = font?.lineHeight ?? 0
            textContainer.exclusionPaths = [
              UIBezierPath(rect: CGRect(x: 0, y: 0, width: indent, height: line / 2))
            ]
          case .above(let height): textContainerInset.top += height
          }
          // TextKit moves the lines for the new room but keeps drawing them where they were until
          // the text changes, so taps and the caret would miss what is drawn.
          if let layout = textLayoutManager {
            layout.invalidateLayout(for: layout.documentRange)
            layout.textViewportLayoutController.layoutViewport()
          }
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
        accessibilityLabel = "Message the coordinator"
        accessibilityIdentifier = "Message the coordinator"
      }
      required init?(coder: NSCoder) { return nil }

      /// An empty draft reads its placeholder, as the text field before it did. A text view has
      /// no placeholder of its own to report.
      override var accessibilityValue: String? {
        get { text.isEmpty ? placeholder.text : super.accessibilityValue }
        set { super.accessibilityValue = newValue }
      }

      // A hardware keyboard's Return ends editing, as the text field before it did, once no
      // input method is composing. The on-screen return key never arrives as a press, so it
      // still inserts a newline. A swallowed press never reaches UIKit, its release included.
      private var swallowed: Set<UIPress> = []
      override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let returns = markedTextRange == nil ? presses.filter(Self.isReturn) : []
        guard !returns.isEmpty else { return super.pressesBegan(presses, with: event) }
        swallowed.formUnion(returns)
        resignFirstResponder()
        let others = presses.subtracting(returns)
        if !others.isEmpty { super.pressesBegan(others, with: event) }
      }
      override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = release(presses)
        if !others.isEmpty { super.pressesEnded(others, with: event) }
      }
      override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let others = release(presses)
        if !others.isEmpty { super.pressesCancelled(others, with: event) }
      }
      private func release(_ presses: Set<UIPress>) -> Set<UIPress> {
        defer { swallowed.subtract(presses) }
        return presses.subtracting(swallowed)
      }
      private static func isReturn(_ press: UIPress) -> Bool {
        guard let key = press.key, key.keyCode == .keyboardReturnOrEnter else { return false }
        return key.modifierFlags.isDisjoint(with: [.shift, .control, .alternate, .command])
      }

      override func layoutSubviews() {
        super.layoutSubviews()
        let indent = if case .beside(let indent) = chipRoom { indent } else { CGFloat(0) }
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
      /// The chip moves with the first line.
      func scrollViewDidScroll(_ view: UIScrollView) { view.superview?.setNeedsLayout() }
    }
  }
#endif
