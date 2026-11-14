#if os(iOS)
  import AgentCore
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
      /// False while a Send is admitting, when its ⓧ is disabled.
      let removable: Bool
    }
    static let inset = UIEdgeInsets(top: 11, left: 2, bottom: 11, right: 2)
    static let maximumLines: CGFloat = 6
    let text: String
    let placeholder: String
    let chip: Chip?
    /// Send clears this field's own buffer through it, in the event that takes the text.
    let editor: ComposerEditor
    /// The latest tag that became the chip.
    let promotion: Promotion?
    /// The coordinator whose restored message the draft holds. The field's undo actions go whenever
    /// it changes.
    let restoredFrom: ProfileID?
    /// The open take's transcript so far, shown dimmed where its words will land. Never the draft.
    let provisional: String
    let reservation: DictationReservation?
    /// Reports the field's text, and that text without what an input method is still composing.
    let edit: (_ text: String, _ committed: String) -> Void
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
      // around the change. A promoted tag's change is the range the model removed, since the
      // text alone cannot say which of two equal tags went.
      if view.draft != text {
        view.clearProvisional()
        let change =
          if let promotion, promotion.typed == view.text, promotion.rest == text {
            (
              range: NSRange(
                location: 0, length: promotion.typed.utf16.count - promotion.rest.utf16.count),
              length: 0
            )
          } else {
            Self.change(from: view.text, to: text)
          }
        let selection = Self.selection(
          view.selectedRange, replacing: change.range, with: change.length)
        view.text = text
        view.selectedRange = selection
        // The field's undo actions were recorded against the text it had. Applied to this one they
        // would change characters the user did not just type, such as a body after a promoted tag.
        view.undoManager?.removeAllActions()
      }
      // Undo never crosses the start or the end of a restored draft. Across a Restore it would put
      // earlier text into the restored message. Across the emptying of one it would bring the
      // restored text back as new text, read for tags and bound to no coordinator.
      if context.coordinator.restoredFrom != restoredFrom {
        context.coordinator.restoredFrom = restoredFrom
        view.undoManager?.removeAllActions()
      }
      if let reservation, !provisional.isEmpty {
        let range =
          reservation.text == text
          ? reservation.range : NSRange(location: text.utf16.count, length: 0)
        view.showProvisional(provisional, over: range)
      } else {
        view.clearProvisional()
      }
      view.placeholder.text = placeholder
      view.placeholder.isHidden = !view.text.isEmpty
      // SwiftUI's `disabled` reaches a UIKit view only through the environment.
      view.isEditable = context.environment.isEnabled
      box.chip = chip
    }

    /// The range of `old` a change replaced, and the UTF-16 length of what replaced it, read from
    /// the text as the part between the longest prefix and suffix `old` and `new` share.
    static func change(from old: String, to new: String) -> (range: NSRange, length: Int) {
      let head = zip(old, new).prefix { $0 == $1 }.count
      let tail = zip(old.reversed(), new.reversed()).prefix { $0 == $1 }.prefix(
        min(old.count, new.count) - head
      ).count
      let start = old.prefix(head).utf16.count
      let oldEnd = old.utf16.count - old.suffix(tail).utf16.count
      let newEnd = new.utf16.count - new.suffix(tail).utf16.count
      return (NSRange(location: start, length: oldEnd - start), newEnd - start)
    }

    /// Where `range` falls once `changed` is replaced by `length` UTF-16 units. Text before and
    /// after the change keeps its place, and a position inside the change goes to its end.
    static func selection(_ range: NSRange, replacing changed: NSRange, with length: Int)
      -> NSRange
    {
      func moved(_ location: Int) -> Int {
        if location < changed.location { return location }
        if location >= NSMaxRange(changed) { return location - changed.length + length }
        return changed.location + length
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
          button.isEnabled = chip?.removable == true
          button.accessibilityLabel = chip.map { "To \($0.name)" }
          // VoiceOver can remove the recipient from the draft, even with the chip scrolled away.
          draft.accessibilityCustomActions =
            chip?.removable != true
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
          "Removes the recipient. The draft is addressed to every coordinator and may need All to send."
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
      /// True while a dictation take holds the caret. The field stays first responder, so the
      /// keyboard does not drop the composer out from under a held mic, but no edit lands.
      var locked = false
      override func insertText(_ text: String) { if !locked { super.insertText(text) } }
      override func deleteBackward() { if !locked { super.deleteBackward() } }
      override func replace(_ range: UITextRange, withText text: String) {
        if !locked { super.replace(range, withText: text) }
      }
      override func setMarkedText(_ text: String?, selectedRange: NSRange) {
        if !locked { super.setMarkedText(text, selectedRange: selectedRange) }
      }
      override func setAttributedMarkedText(
        _ text: NSAttributedString?, selectedRange: NSRange
      ) {
        if !locked { super.setAttributedMarkedText(text, selectedRange: selectedRange) }
      }
      /// A take's words so far, drawn dimmed over the reserved range, and the draft text they
      /// cover. Display only: `draft` leaves them out, and showing or clearing them registers no
      /// Undo and calls no delegate, so they never reach the model or its save.
      private(set) var provisional: (range: NSRange, covered: String)?

      /// The text without the provisional words.
      var draft: String {
        guard let provisional else { return text }
        return (text as NSString).replacingCharacters(
          in: provisional.range, with: provisional.covered)
      }

      /// Shows `words` over `range` of the draft, spaced as the final text will land so it does
      /// not jump.
      func showProvisional(_ words: String, over range: NSRange) {
        let draft = self.draft as NSString
        guard NSMaxRange(range) <= draft.length else { return }
        let before =
          range.location > 0
          ? draft.substring(with: draft.rangeOfComposedCharacterSequence(at: range.location - 1))
            .last : nil
        let after =
          NSMaxRange(range) < draft.length
          ? draft.substring(with: draft.rangeOfComposedCharacterSequence(at: NSMaxRange(range)))
            .first : nil
        let fitted = DictationText.fitted(words, between: before, and: after)
        if let provisional, provisional.range.location == range.location,
          (text as NSString).substring(with: provisional.range) == fitted
        {
          return
        }
        clearProvisional()
        var dimmed = typingAttributes
        dimmed[.foregroundColor] = UIColor.secondaryLabel
        replaceWithoutUndo(range, with: NSAttributedString(string: fitted, attributes: dimmed))
        provisional = (
          range: NSRange(location: range.location, length: fitted.utf16.count),
          covered: draft.substring(with: range)
        )
        selectedRange = NSRange(location: range.location + fitted.utf16.count, length: 0)
      }

      func clearProvisional() {
        guard let provisional else { return }
        self.provisional = nil
        replaceWithoutUndo(
          provisional.range,
          with: NSAttributedString(string: provisional.covered, attributes: typingAttributes))
        selectedRange = NSRange(
          location: provisional.range.location, length: provisional.covered.utf16.count)
      }

      /// Edits the storage directly. Only the text view's input paths, such as `insertText`,
      /// register Undo or tell the delegate.
      private func replaceWithoutUndo(_ range: NSRange, with text: NSAttributedString) {
        textStorage.replaceCharacters(in: range, with: text)
        invalidateIntrinsicContentSize()
      }

      override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        let edits: [Selector] = [
          #selector(paste(_:)), #selector(cut(_:)), #selector(delete(_:)),
        ]
        return locked && edits.contains(action)
          ? false : super.canPerformAction(action, withSender: sender)
      }
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
      /// no placeholder of its own to report. During a take the value is the draft, so VoiceOver
      /// never reads words that are not yet final.
      override var accessibilityValue: String? {
        get {
          if draft.isEmpty { return placeholder.text }
          return provisional == nil ? super.accessibilityValue : draft
        }
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
      /// The `restoredFrom` the field's undo actions were recorded under.
      var restoredFrom: ProfileID?
      func textViewDidChange(_ view: UITextView) {
        var committed = view.text ?? ""
        if let marked = view.markedTextRange {
          let start = view.offset(from: view.beginningOfDocument, to: marked.start)
          let length = view.offset(from: marked.start, to: marked.end)
          committed = (committed as NSString).replacingCharacters(
            in: NSRange(location: start, length: length), with: "")
        }
        field?.edit(view.text, committed)
      }
      /// Covers the paths the overrides miss, such as an autocorrection or the system's own
      /// dictation.
      func textView(
        _ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
      ) -> Bool {
        !((view as? DraftView)?.locked ?? false)
      }
      /// The chip moves with the first line.
      func scrollViewDidScroll(_ view: UIScrollView) { view.superview?.setNeedsLayout() }
    }
  }
#endif
