import AgentCore
import Foundation
import Observation

/// What the car screen shows. No phase carries a word of the conversation.
public enum CarPhase: String, CaseIterable, Sendable {
  /// Nothing is held: no microphone, no lease.
  case idle
  /// The microphone is open for a message.
  case listening
  /// The message is read back, then the microphone is open for yes or no.
  case confirming
  /// Connecting, or waiting for the answer.
  case working
  case speaking
}

/// A car screen button. Done ends a listening take, Send confirms the message read back, and
/// Cancel ends the conversation.
public enum CarAction: Sendable { case done, send, cancel }

/// A paired coordinator the car can talk to. Its name is all the car screen shows of it.
public struct CarCoordinator: Equatable, Sendable {
  public let id: ProfileID
  public let name: String
}

/// Says a sentence aloud. Returns once it was said, and throws when an audio interruption cut it
/// short. A cancelled task stops it at once.
public struct Speaker: Sendable {
  let speak: @Sendable (String) async throws -> Void

  public init(speak: @escaping @Sendable (String) async throws -> Void) { self.speak = speak }
}

struct CarTimings: Sendable {
  var message: Endpointer.Policy
  var confirmation: Endpointer.Policy
  var turn: VoiceTurnLimits
  /// How often an open take checks its endpoint.
  var tick: Duration

  static let car = CarTimings(
    message: .message, confirmation: .confirmation, turn: .car, tick: .milliseconds(100))
}

/// A hands-free conversation with one paired coordinator. Its one task writes `phase` and holds
/// the microphone, the lease, and every word heard or answered as locals the screen never sees.
/// However it ends, that task releases them all and leaves `phase` idle.
@MainActor @Observable
public final class CarConversation {
  public private(set) var phase = CarPhase.idle

  @ObservationIgnored private let coordinators: Coordinators
  @ObservationIgnored private let engine: SpeechEngine
  @ObservationIgnored private let speaker: Speaker
  @ObservationIgnored private let protectedDataAvailable: @MainActor () -> Bool
  @ObservationIgnored private let timings: CarTimings
  @ObservationIgnored private var run: Task<Void, Never>?
  /// Where presses made for the current phase go.
  @ObservationIgnored private var inbox: AsyncStream<Signal>.Continuation?

  /// Talks to the coordinators intents use, which are the interaction fixture's in a Debug launch
  /// that asked for one.
  public convenience init(notifications: AppNotifications, engine: SpeechEngine, speaker: Speaker)
    throws
  {
    self.init(
      coordinators: try notifications.intentCoordinators, engine: engine, speaker: speaker,
      protectedDataAvailable: { notifications.protectedDataAvailable })
  }

  init(
    coordinators: Coordinators, engine: SpeechEngine, speaker: Speaker,
    protectedDataAvailable: @escaping @MainActor () -> Bool, timings: CarTimings = .car
  ) {
    self.coordinators = coordinators
    self.engine = engine
    self.speaker = speaker
    self.protectedDataAvailable = protectedDataAvailable
    self.timings = timings
  }

  /// Paired coordinators in saved order.
  public var choices: [CarCoordinator] {
    coordinators.profiles.filter { $0.pin != nil }.map {
      CarCoordinator(id: $0.id, name: $0.name.description)
    }
  }

  /// Starts a conversation with `coordinator` once any running one has ended. The task ends with
  /// that conversation.
  @discardableResult public func begin(with coordinator: CarCoordinator) -> Task<Void, Never> {
    let previous = run
    previous?.cancel()
    let next = Task {
      await previous?.value
      await converse(with: coordinator)
    }
    run = next
    return next
  }

  /// A press of a button made for `shown`. Done and Send do nothing once the conversation has left
  /// that phase, and Cancel always ends it.
  public func perform(_ action: CarAction, in shown: CarPhase) {
    switch (action, shown) {
    case (.cancel, _): end()
    case (.done, .listening), (.send, .confirming):
      if phase == shown { inbox?.yield(.press(action)) }
    default: break
    }
  }

  /// Ends the conversation. A message the coordinator has stays sent.
  public func end() { run?.cancel() }

  private enum Signal: Sendable {
    case press(CarAction)
    case heard(RecordingEvent)
    case captureEnded
    case tick
    case spoken(inFull: Bool)
    /// The take's final text, or nil when `finish` failed.
    case transcribed(String?)
  }

  /// One phase's signals, which only the conversation's task reads.
  private struct Step {
    var signals: AsyncStream<Signal>.Iterator
    let inbox: AsyncStream<Signal>.Continuation
  }

  @discardableResult private func enter(_ next: CarPhase) -> Step {
    inbox?.finish()
    let (signals, inbox) = AsyncStream.makeStream(of: Signal.self)
    self.inbox = inbox
    phase = next
    return Step(signals: signals.makeAsyncIterator(), inbox: inbox)
  }

  private func converse(with chosen: CarCoordinator) async {
    defer { enter(.idle) }
    guard !Task.isCancelled else { return }
    guard engine.microphone.take(.car) else {
      await refuse(.microphoneBusy, name: chosen.name)
      return
    }
    defer { engine.microphone.release(.car) }
    let refusal = CarRefusal.preflight(
      protectedData: protectedDataAvailable(), model: await engine.model(),
      microphone: engine.permission())
    if let refusal {
      await refuse(refusal, name: chosen.name)
      return
    }
    enter(.working)
    do {
      try await coordinators.chat.withConnection(
        to: chosen.id, within: ConnectionLease.connectionWait
      ) { session in
        guard await session.accepts(.carplay) else { throw CarRefusal.notSent(.notAdvertised) }
        try await talk(to: session, name: chosen.name)
      }
    } catch let error as LaneError {
      await refuse(.notSent(SiriNotSent(error)), name: chosen.name)
    } catch let refusal as CarRefusal {
      await refuse(refusal, name: chosen.name)
    } catch {}
  }

  private func refuse(_ refusal: CarRefusal, name: String) async {
    enter(.speaking)
    try? await say(CarSentence.refusal(refusal, name: name))
  }

  /// The opening, then one message after another until the driver stops or the last outcome
  /// says the next would not fare better.
  private func talk(to session: CoordinatorSession, name: String) async throws {
    enter(.speaking)
    try await say(CarSentence.opening(name))
    while true {
      guard protectedDataAvailable() else { throw CarRefusal.notSent(.locked) }
      var listening = enter(.listening)
      guard case .words(let words) = try await take(timings.message, in: &listening),
        VoicePhrase(words) != .end
      else { return }
      let message: SiriMessage
      do { message = try SiriMessage(parsing: words) } catch {
        enter(.speaking)
        try await say(CarSentence.refusal(error))
        continue
      }
      let reply: VoiceReply
      switch try await confirm(message, to: name) {
      case .yes where protectedDataAvailable():
        enter(.working)
        reply = await send(message, on: session)
      case .yes, .locked: reply = .notSent(.locked)
      case .no:
        enter(.speaking)
        try await say(CarSentence.notSentGoAhead)
        continue
      case .unclear:
        enter(.speaking)
        try await say(CarSentence.notSent)
        return
      case .interrupted: return
      }
      enter(.speaking)
      try await say(CarSentence.reply(reply, from: name))
      guard reply.continuesConversation else { return }
    }
  }

  private enum Confirmation { case yes, no, unclear, interrupted, locked }

  /// Reads `message` back, then listens for yes or no. Send is a yes at any point.
  private func confirm(_ message: SiriMessage, to name: String) async throws -> Confirmation {
    var step = enter(.confirming)
    switch try await say(CarSentence.readBack(message, to: name), in: &step) {
    case .pressed: return .yes
    case .interrupted: return .interrupted
    case .said: break
    }
    guard protectedDataAvailable() else { return .locked }
    switch try await take(timings.confirmation, in: &step) {
    case .words(let words):
      switch VoicePhrase(words) {
      case .yes: return .yes
      case .no: return .no
      case .end, .other: return .unclear
      }
    case .pressed: return .yes
    case .silence: return .unclear
    case .interrupted: return .interrupted
    }
  }

  /// Sends `message` and waits for its reply. A message the locked iPhone could not save says so,
  /// as Send Message does.
  private func send(_ message: SiriMessage, on session: CoordinatorSession) async -> VoiceReply {
    let reply = await session.converse(message, inputID: UUID().uuidString, limits: timings.turn)
    let unsaved = reply == .notSent(.outboxNotSaved) || reply == .notSent(.outboxUnreadable)
    return unsaved && !protectedDataAvailable() ? .notSent(.locked) : reply
  }

  private func say(_ sentence: String) async throws {
    try Task.checkCancellation()
    try await speaker.speak(sentence)
  }

  private enum Spoken { case said, pressed, interrupted }

  /// Says `sentence` unless Send cuts it short.
  private func say(_ sentence: String, in step: inout Step) async throws -> Spoken {
    try Task.checkCancellation()
    let inbox = step.inbox
    let speech = Task { [speaker] in
      do {
        try await speaker.speak(sentence)
        inbox.yield(.spoken(inFull: true))
      } catch {
        inbox.yield(.spoken(inFull: false))
      }
    }
    defer { speech.cancel() }
    while let signal = await step.signals.next(isolation: #isolation) {
      switch signal {
      case .press(.send): return .pressed
      case .spoken(let inFull): return inFull ? .said : .interrupted
      case .press, .heard, .captureEnded, .tick, .transcribed: continue
      }
    }
    throw CancellationError()
  }

  private enum Heard: Equatable {
    case words(String)
    case silence, interrupted, pressed
  }

  /// Opens one take and ends it by `policy`, by an interruption, or by a press. Done keeps what
  /// was heard, and Send stops listening.
  private func take(_ policy: Endpointer.Policy, in step: inout Step) async throws -> Heard {
    try Task.checkCancellation()
    let recording: Recording
    do { recording = try await engine.record() } catch { return .interrupted }
    let inbox = step.inbox
    let feeds = [
      Task {
        for await event in recording.events { inbox.yield(.heard(event)) }
        inbox.yield(.captureEnded)
      },
      Task { [tick = timings.tick] in
        while (try? await Task.sleep(for: tick)) != nil { inbox.yield(.tick) }
      },
    ]
    defer { for feed in feeds { feed.cancel() } }
    var endpointer = Endpointer(policy, startedAt: .now)
    while let signal = await step.signals.next(isolation: #isolation) {
      let verdict: Endpointer.Verdict?
      switch signal {
      case .heard(let event): verdict = endpointer.hear(event, at: .now)
      case .tick: verdict = endpointer.verdict(at: .now)
      case .captureEnded: verdict = .interrupted
      case .press(.done): verdict = .finish
      case .press(.send):
        recording.cancel()
        return .pressed
      case .press(.cancel), .spoken, .transcribed: verdict = nil
      }
      switch verdict {
      case .finish?: return try await transcription(of: recording, in: &step)
      case .silence?:
        recording.cancel()
        return .silence
      case .interrupted?:
        recording.cancel()
        return .interrupted
      case nil: continue
      }
    }
    recording.cancel()
    throw CancellationError()
  }

  /// The take's words once `finish` returns them. Ending the conversation abandons them at once,
  /// since `finish` can wait for a model that is still compiling. Send and an interruption count
  /// while the words are coming, as they do while listening.
  private func transcription(of recording: Recording, in step: inout Step) async throws -> Heard {
    let inbox = step.inbox
    Task { inbox.yield(.transcribed(try? await recording.finish())) }
    while let signal = await step.signals.next(isolation: #isolation) {
      switch signal {
      case .transcribed(let words):
        guard let heard = words?.trimmingCharacters(in: .whitespacesAndNewlines) else {
          return .interrupted
        }
        return heard.isEmpty ? .silence : .words(heard)
      case .press(.send):
        recording.cancel()
        return .pressed
      case .heard(.interrupted):
        recording.cancel()
        return .interrupted
      case .press, .heard, .captureEnded, .tick, .spoken: continue
      }
    }
    recording.cancel()
    throw CancellationError()
  }
}
