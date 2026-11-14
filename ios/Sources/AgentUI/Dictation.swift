import Foundation
import Synchronization

/// The voice model's files on this phone, as the engine reads them without the network.
public enum SpeechModel: Equatable, Sendable {
  /// Nothing usable is here. Installing downloads this many more bytes.
  case missing(download: Int64)
  /// The files are complete, but an app or OS update invalidated the compiled model, so the next
  /// load compiles it again.
  case stale
  case ready
  case unsupported
}

public enum MicrophonePermission: String, Codable, Sendable {
  case granted
  case denied
  case undetermined
}

public enum RecordingEvent: Equatable, Sendable {
  /// The latest audio's loudness, 0...1, about ten times a second.
  case level(Float)
  /// A call, Siri, a route change or a media-services reset stopped capture. What was heard is
  /// kept, and `finish` still returns its words.
  case interrupted
}

/// One open microphone, from `SpeechEngine.record` until `finish` or `cancel`.
public struct Recording: Sendable {
  /// Ends when capture stops.
  let events: AsyncStream<RecordingEvent>
  /// Stops capture, waits for the model load that `record` started (compiling a stale model),
  /// transcribes everything heard and unloads the model. Stopping is idempotent.
  let finish: @Sendable () async throws -> String
  /// Stops capture and abandons transcription. Idempotent.
  let cancel: @Sendable () -> Void

  public init(
    events: AsyncStream<RecordingEvent>, finish: @escaping @Sendable () async throws -> String,
    cancel: @escaping @Sendable () -> Void
  ) {
    self.events = events
    self.finish = finish
    self.cancel = cancel
  }
}

/// What dictation needs from a speech engine. The app builds Parakeet's (`AgentApp/Speech.swift`),
/// and tests and the interaction fixture build `ScriptedSpeech`'s. Text comes out as one String,
/// so how the engine transcribes stays its own decision.
public struct SpeechEngine: Sendable {
  /// Reads files only, never the network.
  let model: @Sendable () async -> SpeechModel
  /// The only network call. Resumes partial files, reports the download's progress 0...1, then
  /// compiles the model once and unloads it. Throws `CancellationError` when cancelled.
  let install: @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
  /// Compiles a stale model, then unloads it. Does nothing otherwise, and never downloads.
  let prewarm: @Sendable () async -> Void
  let remove: @Sendable () async -> Void
  /// Bytes the model's files take on this phone, partial downloads included.
  let diskUsage: @Sendable () async -> Int64
  /// Reads the network path once. True on cellular or another path the system calls expensive.
  let onCellular: @Sendable () async -> Bool
  let permission: @Sendable () -> MicrophonePermission
  /// Shows the system prompt if it was never answered. True when allowed.
  let requestPermission: @Sendable () async -> Bool
  /// Starts capture at once and starts loading the model beside it. Throws when the audio session
  /// cannot be taken, as during a call.
  let record: @Sendable () async throws -> Recording

  public init(
    model: @escaping @Sendable () async -> SpeechModel,
    install:
      @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void)
      async throws -> Void,
    prewarm: @escaping @Sendable () async -> Void,
    remove: @escaping @Sendable () async -> Void,
    diskUsage: @escaping @Sendable () async -> Int64,
    onCellular: @escaping @Sendable () async -> Bool,
    permission: @escaping @Sendable () -> MicrophonePermission,
    requestPermission: @escaping @Sendable () async -> Bool,
    record: @escaping @Sendable () async throws -> Recording
  ) {
    self.model = model
    self.install = install
    self.prewarm = prewarm
    self.remove = remove
    self.diskUsage = diskUsage
    self.onCellular = onCellular
    self.permission = permission
    self.requestPermission = requestPermission
    self.record = record
  }
}

/// A speech engine that hears nothing and returns scripted words, for tests and the DEBUG
/// interaction fixture. Invented words only.
final class ScriptedSpeech: Sendable {
  struct Script: Codable, Equatable, Sendable {
    enum Model: String, Codable, Sendable {
      case missing
      case stale
      case ready
      case unsupported
    }
    var model = Model.ready
    var download: Int64 = 614_082_275
    /// Fractions an install reports, one every `stepMilliseconds`.
    var progress: [Double] = [0.25, 0.5, 0.75, 1]
    var stepMilliseconds = 20
    var cellular = false
    var microphone = MicrophonePermission.granted
    /// What the system prompt answers.
    var grants = true
    /// Each take's words, in order. The last repeats.
    var takes = ["Invented dictated words"]

    init() {}

    /// Missing keys keep their defaults, so a UI test's JSON names only what it changes.
    init(from decoder: any Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      let defaults = Self()
      model = try values.decodeIfPresent(Model.self, forKey: .model) ?? defaults.model
      download = try values.decodeIfPresent(Int64.self, forKey: .download) ?? defaults.download
      progress = try values.decodeIfPresent([Double].self, forKey: .progress) ?? defaults.progress
      stepMilliseconds =
        try values.decodeIfPresent(Int.self, forKey: .stepMilliseconds) ?? defaults.stepMilliseconds
      cellular = try values.decodeIfPresent(Bool.self, forKey: .cellular) ?? defaults.cellular
      microphone =
        try values.decodeIfPresent(MicrophonePermission.self, forKey: .microphone)
        ?? defaults.microphone
      grants = try values.decodeIfPresent(Bool.self, forKey: .grants) ?? defaults.grants
      takes = try values.decodeIfPresent([String].self, forKey: .takes) ?? defaults.takes
    }
  }

  private struct State {
    var script: Script
    var takes = 0
    var installs = 0
    var holding = false
    var held: [CheckedContinuation<Void, Never>] = []
    var open: (take: Int, events: AsyncStream<RecordingEvent>.Continuation)?
  }
  private let state: Mutex<State>

  init(_ script: Script = Script()) {
    state = Mutex(State(script: script))
  }

  /// Recordings started so far.
  var recordings: Int { state.withLock { $0.takes } }
  var installs: Int { state.withLock { $0.installs } }

  /// Holds each `finish` until `release()`, as a slow transcription would.
  func hold() { state.withLock { $0.holding = true } }
  func release() {
    let held = state.withLock {
      $0.holding = false
      defer { $0.held = [] }
      return $0.held
    }
    for continuation in held { continuation.resume() }
  }
  /// Stops the open recording as a phone call would.
  func interrupt() {
    let events = state.withLock {
      defer { $0.open = nil }
      return $0.open?.events
    }
    events?.yield(.interrupted)
    events?.finish()
  }

  var engine: SpeechEngine {
    SpeechEngine(
      model: { [self] in
        state.withLock {
          switch $0.script.model {
          case .missing: .missing(download: $0.script.download)
          case .stale: .stale
          case .ready: .ready
          case .unsupported: .unsupported
          }
        }
      },
      install: { [self] progress in
        let (steps, step) = state.withLock {
          $0.installs += 1
          return ($0.script.progress, $0.script.stepMilliseconds)
        }
        for fraction in steps {
          try await Task.sleep(for: .milliseconds(step))
          progress(fraction)
        }
        state.withLock { $0.script.model = .ready }
      },
      prewarm: { [self] in
        state.withLock { if $0.script.model == .stale { $0.script.model = .ready } }
      },
      remove: { [self] in
        state.withLock { $0.script.model = .missing }
      },
      diskUsage: { [self] in
        state.withLock { $0.script.model == .missing ? 0 : $0.script.download }
      },
      onCellular: { [self] in state.withLock { $0.script.cellular } },
      permission: { [self] in state.withLock { $0.script.microphone } },
      requestPermission: { [self] in
        state.withLock {
          if $0.script.microphone == .undetermined {
            $0.script.microphone = $0.script.grants ? .granted : .denied
          }
          return $0.script.microphone == .granted
        }
      },
      record: { [self] in self.open() })
  }

  private func open() -> Recording {
    let (events, continuation) = AsyncStream.makeStream(of: RecordingEvent.self)
    let (take, words) = state.withLock {
      $0.open?.events.finish()
      $0.open = ($0.takes, continuation)
      defer { $0.takes += 1 }
      return ($0.takes, $0.script.takes[min($0.takes, $0.script.takes.count - 1)])
    }
    continuation.yield(.level(0.5))
    let stop: @Sendable () -> Void = { [self] in
      state.withLock { if $0.open?.take == take { $0.open = nil } }
      continuation.finish()
    }
    return Recording(
      events: events,
      finish: { [self] in
        stop()
        await withCheckedContinuation { held in
          let waits = state.withLock {
            if $0.holding { $0.held.append(held) }
            return $0.holding
          }
          if !waits { held.resume() }
        }
        return words
      },
      cancel: stop)
  }
}

/// Where the caret was when a take started, in the text it was read from.
struct DictationReservation: Equatable {
  let range: NSRange
  let text: String
}

/// The composer whose mic was pressed. On iOS its closures act on the field's own text view, so
/// words land the way typing does. Without a field, the words are appended through
/// `ChatModel.edit`.
@MainActor struct DictationTarget {
  let chat: ChatModel
  /// Commits a composition, snapshots where the words go and locks the field against edits.
  let reserve: () -> DictationReservation?
  /// Unlocks the field and inserts the words at the reservation, or at the end without one or
  /// once the field's text changed, as one Undo step. False when no field is on screen.
  let insert: (_ words: String, _ at: DictationReservation?) -> Bool
  let unlock: () -> Void
  /// Send's `/feedback` screenshot, as the Send button passes it.
  let screenshot: (@MainActor () throws -> Data)?

  init(
    chat: ChatModel, reserve: @escaping () -> DictationReservation? = { nil },
    insert: @escaping (String, DictationReservation?) -> Bool = { _, _ in false },
    unlock: @escaping () -> Void = {}, screenshot: (@MainActor () throws -> Data)? = nil
  ) {
    self.chat = chat
    self.reserve = reserve
    self.insert = insert
    self.unlock = unlock
    self.screenshot = screenshot
  }
}

/// What dictation tells the user above the field, until the next take or its ×.
enum DictationNotice: Equatable {
  case ready
  /// The press asked for the microphone, so it started nothing.
  case microphoneAllowed
  case microphoneDenied
  /// The phone kept the microphone, as during a call.
  case microphoneUnavailable
  case interrupted
  case nothingHeard
  /// A held take kept its words in the composer instead of sending them.
  case notSent(NotSent)
  case downloadFailed(String)
  case failed(String)

  enum NotSent: Equatable {
    case draftChanged
    case blocked(ChatModel.SendBlocker)
    /// `startSend` refused in its own turn, and `ChatModel.failure` says why.
    case refused
  }

  @MainActor func text(_ chat: ChatModel) -> String {
    switch self {
    case .ready: "Ready. Tap the mic to dictate, or hold it to talk and release to send."
    case .microphoneAllowed: "Microphone allowed. Tap or hold the mic to dictate."
    case .microphoneDenied: "Dictation needs the microphone. Allow it in Settings."
    case .microphoneUnavailable: "The microphone is busy, as during a call."
    case .interrupted: "Dictation stopped because the microphone was interrupted."
    case .nothingHeard: "Nothing heard."
    case .notSent(.draftChanged): "Not sent. The draft changed while you were dictating."
    case .notSent(.blocked(.addressing)): "Not sent. \(chat.recipientLine)."
    case .notSent(.blocked(.draftNotRestored)): "Not sent. The saved draft is still loading."
    case .notSent(.blocked(.sharedImport)): "Not sent. A shared draft is still being added."
    case .notSent(.blocked(.admitting)): "Not sent. The last message is still sending."
    case .notSent(.blocked(.preparingAttachments)): "Not sent. Files are still being added."
    case .notSent(.refused): "Not sent."
    case .downloadFailed(let reason): "The voice model did not download. \(reason)"
    case .failed(let reason): "Dictation failed. \(reason)"
    }
  }
}

/// Dictation for the composer: the voice model's lifecycle and the microphone's one take. One per
/// process, owned by the App beside the coordinators, so every window shares one model, one
/// audio session and one take.
///
/// It never owns the draft. Words reach it once, when a take lands, through the field the way
/// typing does, and a held take sends through `ChatModel.startSend`, the Send button's path.
@MainActor @Observable
public final class Dictation {
  enum ModelPhase: Equatable {
    case checking
    case missing(download: Int64)
    case downloading(Double, of: Int64)
    /// Compiling the model for this build of the app and OS. A take captures meanwhile, and its
    /// words land when the compile ends.
    case preparing
    case ready
    case unsupported
  }

  /// How a press is going. The mic opens on the press, before tap and hold can be told apart, so
  /// the first word is not lost.
  enum Gesture: Equatable {
    case pressing
    /// Down past `holdDelay`. Releasing on the mic sends; sliding off first keeps.
    case holding
    /// Started by a tap. The next tap stops it and keeps the words.
    case toggled
  }

  enum Landing: Equatable {
    case keep
    case send
  }

  /// The download the confirmation offers while it is shown.
  struct Offer: Equatable {
    let bytes: Int64
    /// On cellular, or another expensive path, when offered.
    let cellular: Bool

    var question: String {
      let size = bytes.formatted(.byteCount(style: .file))
      return cellular
        ? "This iPhone is on cellular. Download the voice model (\(size))?"
        : "Download the voice model (\(size))?"
    }
  }

  enum Stage: Equatable {
    case opening(Gesture)
    case listening(Gesture)
    case transcribing(Landing)
  }

  struct Take {
    let id = UUID()
    let target: DictationTarget
    let reservation: DictationReservation?
    let mark: ChatModel.DraftMark
    var stage: Stage
    var recording: Recording?
    var started: ContinuousClock.Instant?
  }

  /// What the mic reports. One entry point, so tap and hold are told apart in one place.
  enum MicEvent: Equatable {
    case down
    /// `onMic` is false when the finger slid off the mic first.
    case up(onMic: Bool)
    /// The system took the touch away. Never a send.
    case cancelled
    /// VoiceOver, Switch Control or Full Keyboard Access activated the mic, which is a tap.
    case activated
  }

  private(set) var model = ModelPhase.checking
  private(set) var take: Take?
  /// The open take's loudness, apart from `take` so only the meter redraws ten times a second.
  private(set) var level: Float = 0
  private(set) var notice: DictationNotice?
  private(set) var diskUsage: Int64 = 0
  var offering: Offer?

  @ObservationIgnored private let engine: SpeechEngine
  @ObservationIgnored private let holdDelay: Duration
  /// The one install, prewarm, removal or file read in flight.
  @ObservationIgnored private var work: Task<Void, Never>?
  @ObservationIgnored private var timers: [Task<Void, Never>] = []

  public init(engine: SpeechEngine, holdDelay: Duration = .milliseconds(300)) {
    self.engine = engine
    self.holdDelay = holdDelay
  }

  /// Foreground is any phase but background. Coming forward reads the model's files and compiles
  /// a model an update left stale. Leaving stops an open take, which keeps its words, and a held
  /// take still transcribing keeps them too, so leaving the app never sends.
  public func setForeground(_ foreground: Bool) {
    guard foreground else {
      switch take?.stage {
      case .opening?, .listening?: finish(.keep)
      case .transcribing(.send)?: take?.stage = .transcribing(.keep)
      case .transcribing(.keep)?, nil: break
      }
      return
    }
    guard work == nil, take == nil else { return }
    work = Task {
      defer { work = nil }
      if await engine.model() == .stale {
        model = .preparing
        await engine.prewarm()
      }
      await settle()
    }
  }

  func mic(_ event: MicEvent, in target: DictationTarget) {
    switch (event, take?.stage) {
    case (.down, nil):
      if model == .ready || model == .preparing { start(.pressing, in: target) }
    case (.up, .opening(.pressing)?), (.up, .listening(.pressing)?):
      regesture(.toggled)
    case (.up(let onMic), .opening(.holding)?), (.up(let onMic), .listening(.holding)?):
      finish(onMic ? .send : .keep)
    case (.cancelled, .opening(.pressing)?), (.cancelled, .listening(.pressing)?),
      (.cancelled, .opening(.holding)?), (.cancelled, .listening(.holding)?),
      (.up, .opening(.toggled)?), (.up, .listening(.toggled)?),
      (.activated, .opening?), (.activated, .listening?):
      finish(.keep)
    case (.up, nil), (.activated, nil):
      switch model {
      // Complete files left without a receipt need only the compile, so nothing to agree to.
      case .missing(let bytes): if bytes == 0 { download() } else { offer(bytes) }
      case .ready, .preparing: if event == .activated { start(.toggled, in: target) }
      case .checking, .downloading, .unsupported: break
      }
    default: break
    }
  }

  /// Reads the network path once, when the offer is made. Wi-Fi coming back starts nothing.
  private func offer(_ bytes: Int64) {
    guard work == nil else { return }
    work = Task {
      defer { work = nil }
      let cellular = await engine.onCellular()
      guard model == .missing(download: bytes) else { return }
      offering = Offer(bytes: bytes, cellular: cellular)
    }
  }

  /// After the user confirmed the download. Asks for the microphone now if it was never asked, so
  /// the first take is not spent on the system prompt. A download never opens the mic.
  func download() {
    guard work == nil, case .missing(let bytes) = model else { return }
    offering = nil
    notice = nil
    if engine.permission() == .undetermined {
      Task { _ = await engine.requestPermission() }
    }
    model = .downloading(0, of: bytes)
    work = Task {
      defer { work = nil }
      do {
        try await engine.install { fraction in
          Task { @MainActor in self.progressed(fraction) }
        }
        await settle()
        if model == .ready { notice = .ready }
      } catch is CancellationError {
        await settle()
      } catch {
        await settle()
        notice = .downloadFailed(error.localizedDescription)
      }
    }
  }

  /// Partial files stay, and the next download resumes them.
  func cancelDownload() {
    if case .downloading = model { work?.cancel() }
  }

  /// Removal waits for a take, a download or a compile to end.
  var canRemoveModel: Bool {
    guard take == nil, diskUsage > 0 else { return false }
    switch model {
    case .missing, .ready: return true
    case .checking, .downloading, .preparing, .unsupported: return false
    }
  }

  func removeModel() {
    guard work == nil, canRemoveModel else { return }
    work = Task {
      defer { work = nil }
      await engine.remove()
      await settle()
    }
  }

  func dismissNotice() { notice = nil }

  private func progressed(_ fraction: Double) {
    guard case .downloading(_, let bytes) = model else { return }
    model = fraction >= 1 ? .preparing : .downloading(fraction, of: bytes)
  }

  /// Reads the files once an install, prewarm or removal ends. A model still stale after its
  /// prewarm compiles on the next take's load instead.
  private func settle() async {
    model =
      switch await engine.model() {
      case .missing(let bytes): .missing(download: bytes)
      case .stale, .ready: .ready
      case .unsupported: .unsupported
      }
    diskUsage = await engine.diskUsage()
  }

  private func start(_ gesture: Gesture, in target: DictationTarget) {
    guard target.chat.dictationAllowed else { return }
    switch engine.permission() {
    case .denied:
      notice = .microphoneDenied
      return
    case .undetermined:
      // The prompt takes the touch, so the press that asked starts nothing.
      notice = nil
      Task { notice = await engine.requestPermission() ? .microphoneAllowed : .microphoneDenied }
      return
    case .granted: break
    }
    notice = nil
    let reservation = target.reserve()
    // Committing a composition can complete a leading tag. Promoting it now keeps the mark from
    // going stale when the composer's own promotion runs after this turn.
    target.chat.promoteTypedTag()
    let take = Take(
      target: target, reservation: reservation, mark: target.chat.draftMark,
      stage: .opening(gesture))
    self.take = take
    if gesture == .pressing {
      after(holdDelay, take.id) { [weak self] in self?.regesture(.holding) }
    }
    Task { await run(take.id) }
  }

  /// Opens the microphone, then follows its events until capture stops.
  private func run(_ id: UUID) async {
    let recording: Recording
    do {
      recording = try await engine.record()
    } catch {
      end(id, notice: .microphoneUnavailable)
      return
    }
    guard var take, take.id == id else {
      recording.cancel()
      return
    }
    take.recording = recording
    switch take.stage {
    case .opening(let gesture):
      take.stage = .listening(gesture)
      take.started = .now
      self.take = take
    case .transcribing:
      self.take = take
      transcribe(id, recording)
    case .listening:
      self.take = take
    }
    for await event in recording.events {
      guard self.take?.id == id else { break }
      switch event {
      case .level(let loudness): level = loudness
      case .interrupted: finish(.keep, notice: .interrupted)
      }
    }
  }

  private func regesture(_ next: Gesture) {
    switch take?.stage {
    case .opening(.pressing)?: take?.stage = .opening(next)
    case .listening(.pressing)?: take?.stage = .listening(next)
    default: break
    }
  }

  /// Closes the mic and fixes how the take lands. The first call wins, so a release, an
  /// interruption and leaving the app racing each other end the take once.
  private func finish(_ landing: Landing, notice: DictationNotice? = nil) {
    guard var take else { return }
    switch take.stage {
    case .opening, .listening: break
    case .transcribing: return
    }
    take.stage = .transcribing(landing)
    self.take = take
    level = 0
    cancelTimers()
    if let notice { self.notice = notice }
    // A take still opening transcribes once its recording arrives.
    if let recording = take.recording { transcribe(take.id, recording) }
  }

  private func transcribe(_ id: UUID, _ recording: Recording) {
    Task {
      let result: Result<String, any Error>
      do { result = .success(try await recording.finish()) } catch { result = .failure(error) }
      land(id, result)
    }
  }

  /// The words reach the draft, then maybe Send, in one main-actor turn, so nothing can change
  /// the draft between the check, the insertion and the send.
  private func land(_ id: UUID, _ result: Result<String, any Error>) {
    guard let take, take.id == id, case .transcribing(let landing) = take.stage else { return }
    self.take = nil
    let target = take.target
    let words: String
    do {
      words = try result.get().trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      target.unlock()
      notice = .failed(error.localizedDescription)
      return
    }
    guard !words.isEmpty else {
      target.unlock()
      notice = .nothingHeard
      return
    }
    let chat = target.chat
    let fresh = chat.draftMark == take.mark
    if !target.insert(words, fresh ? take.reservation : nil) {
      let text = DictationText.appended(words, to: chat.draft)
      chat.edit(text, committed: text)
    }
    // Typed text is promoted before any Send can read it, so dictated text is too: raw parsing
    // of "@Work @Personal note" would pick both.
    chat.promoteTypedTag()
    guard landing == .send else { return }
    if !fresh {
      notice = .notSent(.draftChanged)
    } else if let blocker = chat.sendBlocker {
      notice = .notSent(.blocked(blocker))
    } else if chat.startSend(screenshot: target.screenshot) == nil {
      notice = .notSent(.refused)
    }
  }

  private func end(_ id: UUID, notice: DictationNotice) {
    guard let take, take.id == id else { return }
    self.take = nil
    level = 0
    cancelTimers()
    take.target.unlock()
    self.notice = notice
  }

  private func after(_ delay: Duration, _ id: UUID, _ action: @escaping @MainActor () -> Void) {
    timers.append(
      Task { [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, self?.take?.id == id else { return }
        action()
      })
  }

  private func cancelTimers() {
    for timer in timers { timer.cancel() }
    timers = []
  }
}

/// How dictated words join text already in the composer. Only spacing changes, never case or
/// punctuation.
enum DictationText {
  private static let closing: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "…"]
  private static let opening: Set<Character> = ["(", "[", "{", "“", "‘"]

  /// `words` with a space where they would touch a word before or after them.
  static func fitted(_ words: String, between before: Character?, and after: Character?) -> String {
    var fitted = words
    if let before, !before.isWhitespace, !opening.contains(before), let first = words.first,
      !closing.contains(first)
    {
      fitted = " " + fitted
    }
    if let after, !after.isWhitespace, !closing.contains(after) { fitted += " " }
    return fitted
  }

  static func appended(_ words: String, to draft: String) -> String {
    draft + fitted(words, between: draft.last, and: nil)
  }
}
