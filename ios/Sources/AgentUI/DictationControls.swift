#if os(iOS)
  import SwiftUI
  import UIKit

  struct MicButton: View {
    let dictation: Dictation
    let target: DictationTarget
    @State private var pressed = false
    /// Resets without `onEnded` when the system cancels the touch.
    @GestureState private var touching = false

    private static let slop: CGFloat = 30

    var body: some View {
      icon
        .frame(width: 44, height: 44).contentShape(Circle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .updating($touching) { _, state, _ in state = true }
            .onChanged { _ in
              guard !pressed else { return }
              pressed = true
              dictation.mic(.down, in: target)
            }
            .onEnded { value in
              pressed = false
              let area = CGRect(x: 0, y: 0, width: 44, height: 44)
                .insetBy(dx: -Self.slop, dy: -Self.slop)
              dictation.mic(.up(onMic: area.contains(value.location)), in: target)
            }
        )
        .onChange(of: touching) { _, now in
          guard !now, pressed else { return }
          pressed = false
          dictation.mic(.cancelled, in: target)
        }
        .disabled(disabled)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityHint(
          dictation.take == nil
            ? "Tap to start and stop. The words stay in the composer to edit. Touch and hold to talk, then release to send."
            : ""
        )
        .accessibilityAddTraits(
          dictation.take == nil && dictation.model == .ready
            ? [.isButton, .startsMediaSession] : .isButton
        )
        .accessibilityIdentifier("dictation")
        .accessibilityAction { dictation.mic(.activated, in: target) }
    }

    private var disabled: Bool {
      switch dictation.take?.stage {
      case .opening?, .listening?: return false
      case .transcribing?: return true
      case nil: break
      }
      switch dictation.model {
      case .checking, .downloading, .unsupported: return true
      case .missing, .preparing, .ready: return !target.chat.dictationAllowed
      }
    }

    private var label: String {
      switch dictation.take?.stage {
      case .opening?, .listening?: return "Stop dictating"
      case .transcribing?: return "Transcribing"
      case nil: break
      }
      switch dictation.model {
      case .missing: return "Set up dictation"
      case .downloading: return "Downloading voice model"
      case .checking, .preparing, .ready, .unsupported: return "Dictate"
      }
    }

    @ViewBuilder private var icon: some View {
      switch (dictation.take?.stage, dictation.model) {
      case (.transcribing?, _):
        ProgressView()
      case (.listening(.toggled)?, _), (.opening(.toggled)?, _):
        Image(systemName: "stop.fill").font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white).frame(width: 32, height: 32)
          .background(.red, in: Circle())
      case (.listening?, _), (.opening?, _):
        Image(systemName: "mic.fill").font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white).frame(width: 32, height: 32)
          .background(.red, in: Circle())
          .scaleEffect(1 + CGFloat(dictation.level) * 0.25)
      case (nil, .downloading(let fraction, _)):
        ProgressView(value: fraction).progressViewStyle(.circular)
      case (nil, _):
        Image(systemName: "mic").font(.system(size: 19, weight: .regular))
          .foregroundStyle(disabled ? .secondary : .primary)
      }
    }
  }

  struct DictationStatus: View {
    let dictation: Dictation
    let chat: ChatModel

    private enum Status {
      case listening(held: Bool)
      case working(String)
      case downloading(Double, of: Int64)
      case notice(DictationNotice)
    }

    var body: some View {
      if let status {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Group {
            switch status {
            case .listening(let held): Listening(dictation: dictation, held: held)
            case .working(let text): Text(text)
            case .downloading(let fraction, let bytes):
              Text("Downloading voice model · \(Int(fraction * 100))% of \(Self.size(bytes))")
            case .notice(let notice): Text(notice.text(chat))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          switch status {
          case .downloading:
            Button("Cancel") { dictation.cancelDownload() }.font(.footnote.weight(.semibold))
          case .notice(let notice):
            if notice == .microphoneDenied {
              Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                  UIApplication.shared.open(url)
                }
              }
              .font(.footnote.weight(.semibold))
            } else if case .downloadFailed = notice {
              Button("Try again") { dictation.download() }.font(.footnote.weight(.semibold))
            }
            Button("Dismiss dictation notice", systemImage: "xmark") { dictation.dismissNotice() }
              .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
          case .listening, .working: EmptyView()
          }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dictationStatus")
      }
    }

    private var status: Status? {
      switch dictation.take?.stage {
      case .opening(let gesture)?, .listening(let gesture)?:
        return .listening(held: gesture == .holding)
      case .transcribing?:
        return .working(
          dictation.model == .preparing
            ? "Preparing the voice model for this version…" : "Transcribing…")
      case nil: break
      }
      switch dictation.model {
      case .downloading(let fraction, let bytes): return .downloading(fraction, of: bytes)
      case .preparing: return .working("Preparing the voice model for this version…")
      case .checking, .missing, .ready, .unsupported: break
      }
      return dictation.notice.map(Status.notice)
    }

    static func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
  }

  private struct Listening: View {
    let dictation: Dictation
    let held: Bool

    var body: some View {
      HStack(spacing: 8) {
        Capsule().fill(.red)
          .frame(width: 4 + 36 * CGFloat(dictation.level), height: 6)
          .frame(width: 40, alignment: .leading)
          .accessibilityHidden(true)
        if let started = dictation.take?.started {
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(held ? "Release to send · slide off to keep" : "Listening \(clock(started))")
          }
        } else {
          Text(held ? "Release to send · slide off to keep" : "Listening")
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(held ? "Listening. Release to send, slide off to keep." : "Listening")
    }

    private func clock(_ started: ContinuousClock.Instant) -> String {
      let seconds = Int((ContinuousClock.now - started).components.seconds)
      return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
  }
#endif
