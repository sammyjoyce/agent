import Foundation
import Network
import Testing

@testable import AgentCore
@testable import AgentUI

enum ReturnOrderStep: Hashable, Sendable, CustomStringConvertible {
  case send(control: Bool, to: Int, holdAdmission: Bool, holdDial: Bool)
  case refuse
  case admit
  case dialFails(Int)
  case dialPasses(Int)
  case type(String, paragraph: Bool)
  case delete(Int)
  case edit(Int)
  case clear
  case restore(withReturn: Bool)

  var description: String {
    switch self {
    case .send(let control, let to, let holdAdmission, let holdDial):
      "send(\(control ? "control" : "message"), to: \(to)"
        + (holdAdmission ? ", holdAdmission" : "") + (holdDial ? ", holdDial" : "") + ")"
    case .refuse: "refuse"
    case .admit: "admit"
    case .dialFails(let coordinator): "dialFails(\(coordinator))"
    case .dialPasses(let coordinator): "dialPasses(\(coordinator))"
    case .type(let word, let paragraph): "type(\(word)\(paragraph ? ", paragraph" : ""))"
    case .delete(let block): "delete(\(block))"
    case .edit(let block): "edit(\(block))"
    case .clear: "clear"
    case .restore(let withReturn): "restore\(withReturn ? "(withReturn)" : "")"
    }
  }
}

struct ReturnOrderReference {
  enum Block: Equatable {
    case returned(send: Int, text: String, typed: String)
    case other(String)
    var shown: String {
      switch self {
      case .returned(_, let text, let typed): text + typed
      case .other(let text): text
      }
    }
  }
  struct Send: Equatable {
    let number: Int
    let text: String
    let to: Int
    let holdsDial: Bool
  }
  enum Action {
    case send(Send, fresh: Bool, holdAdmission: Bool)
    case refuse
    case admit(Send)
    case dialFails(Int)
    case dialPasses(Int)
    case edit(String)
    case restore(withReturn: Bool)
  }
  static let coordinators = 4
  static let restoredText = "An invented refused note"

  private(set) var blocks: [Block] = []
  private var sends = 0
  private(set) var admitting: Send?
  private(set) var dialing: [Int: Send] = [:]
  private(set) var written = Array(repeating: 0, count: coordinators)
  private(set) var restorable: Bool

  init(restorable: Bool) { self.restorable = restorable }

  var draft: String { blocks.map(\.shown).joined(separator: "\n\n") }
  var recovered: String {
    guard let admitting else { return draft }
    var cold = self
    cold.comeBack(admitting)
    return cold.draft
  }

  private var leadingReturnCount: Int {
    var last = 0
    for (index, block) in blocks.enumerated() {
      guard case .returned(let send, _, _) = block, send > last else { return index }
      last = send
    }
    return blocks.count
  }

  private mutating func comeBack(_ send: Send) {
    let older = blocks[..<leadingReturnCount].lastIndex { block in
      guard case .returned(let number, _, _) = block else { return false }
      return number < send.number
    }
    blocks.insert(
      .returned(send: send.number, text: send.text, typed: ""), at: older.map { $0 + 1 } ?? 0)
  }

  private mutating func deliver(_ send: Send) {
    if send.holdsDial { dialing[send.to] = send } else { written[send.to] += 1 }
  }

  static func fresh(_ number: Int, control: Bool) -> String {
    let names = ["status", "help", "compact", "model"]
    if control { return "/\(names[number % names.count]) \(number)" }
    return number % 3 == 0
      ? "Invented note \(number)\n\nInvented detail \(number)" : "Invented note \(number)"
  }

  mutating func apply(_ step: ReturnOrderStep) -> Action? {
    switch step {
    case .send(let control, let to, let holdAdmission, let holdDial):
      guard admitting == nil else { return nil }
      sends += 1
      let fresh = blocks.isEmpty
      let text = fresh ? Self.fresh(sends, control: control) : draft
      let free = (0..<Self.coordinators).map { (to + $0) % Self.coordinators }
        .first { dialing[$0] == nil }
      let holdsDial = text.hasPrefix("/") && holdDial && free != nil
      let send = Send(
        number: sends, text: text, to: holdsDial ? free ?? to : to, holdsDial: holdsDial)
      blocks = []
      if holdAdmission { admitting = send } else { deliver(send) }
      return .send(send, fresh: fresh, holdAdmission: holdAdmission)
    case .refuse:
      guard let send = admitting else { return nil }
      admitting = nil
      comeBack(send)
      return .refuse
    case .admit:
      guard let send = admitting else { return nil }
      admitting = nil
      deliver(send)
      return .admit(send)
    case .dialFails(let coordinator):
      guard let send = dialing.removeValue(forKey: coordinator) else { return nil }
      comeBack(send)
      return .dialFails(coordinator)
    case .dialPasses(let coordinator):
      guard dialing.removeValue(forKey: coordinator) != nil else { return nil }
      written[coordinator] += 1
      return .dialPasses(coordinator)
    case .type(let word, let paragraph):
      if blocks.isEmpty || paragraph {
        blocks.append(.other(word))
      } else {
        switch blocks[blocks.count - 1] {
        case .returned(let send, let text, let typed):
          blocks[blocks.count - 1] = .returned(send: send, text: text, typed: typed + " " + word)
        case .other(let text): blocks[blocks.count - 1] = .other(text + " " + word)
        }
      }
      return .edit(draft)
    case .delete(let block):
      guard !blocks.isEmpty else { return nil }
      blocks.remove(at: block % blocks.count)
      return .edit(draft)
    case .edit(let block):
      guard !blocks.isEmpty else { return nil }
      let index = block % blocks.count
      let shown = blocks[index].shown
      blocks[index] = .other(String(shown.prefix(1)) + "X" + shown.dropFirst())
      return .edit(draft)
    case .clear:
      guard !blocks.isEmpty else { return nil }
      blocks = []
      return .edit("")
    case .restore(let withReturn):
      guard restorable, blocks.isEmpty, admitting == nil else { return nil }
      restorable = false
      let returning = withReturn ? dialing.removeValue(forKey: 0) : nil
      if let returning { comeBack(returning) }
      blocks.insert(.other(Self.restoredText), at: leadingReturnCount)
      return .restore(withReturn: returning != nil)
    }
  }
}

struct SeededRandom: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var value = state
    value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
    value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }
}

struct ReturnOrderHistory: CustomStringConvertible {
  var seed: UInt64
  var restorable: Bool
  var steps: [ReturnOrderStep]

  init(seed: UInt64, restorable: Bool, steps: [ReturnOrderStep]) {
    self.seed = seed
    self.restorable = restorable
    self.steps = steps
  }

  init(seed: UInt64, length: Int = 32) {
    var random = SeededRandom(seed: seed)
    let restorable = Int.random(in: 0..<4, using: &random) == 0
    var reference = ReturnOrderReference(restorable: restorable)
    var steps: [ReturnOrderStep] = []
    while steps.count < length {
      let step = Self.step(after: reference, number: steps.count, using: &random)
      var trial = reference
      guard trial.apply(step) != nil else { continue }
      reference = trial
      steps.append(step)
    }
    self.init(seed: seed, restorable: restorable, steps: steps)
  }

  private static func step(
    after reference: ReturnOrderReference, number: Int, using random: inout SeededRandom
  ) -> ReturnOrderStep {
    let empty = reference.blocks.isEmpty
    let admitting = reference.admitting != nil
    let dialing = reference.dialing.keys.sorted()
    let coordinator = dialing.randomElement(using: &random) ?? 0
    let send = ReturnOrderStep.send(
      control: Int.random(in: 0..<20, using: &random) < 13,
      to: Int.random(in: 0..<ReturnOrderReference.coordinators, using: &random),
      holdAdmission: Int.random(in: 0..<20, using: &random) < 6,
      holdDial: Int.random(in: 0..<20, using: &random) < 17)
    let weighted: [(Int, ReturnOrderStep)] = [
      (admitting ? 0 : empty ? 30 : 2, send),
      (admitting ? 9 : 0, .refuse), (admitting ? 5 : 0, .admit),
      (dialing.isEmpty ? 0 : 22, .dialFails(coordinator)),
      (dialing.isEmpty ? 0 : 3, .dialPasses(coordinator)),
      (6, .type("w\(number)", paragraph: Bool.random(using: &random))),
      (empty ? 0 : 12, .delete(Int.random(in: 0..<8, using: &random))),
      (empty ? 0 : 5, .edit(Int.random(in: 0..<8, using: &random))),
      (empty ? 0 : 2, .clear),
      (
        reference.restorable && empty && !admitting ? 10 : 0,
        .restore(withReturn: Int.random(in: 0..<5, using: &random) < 3)
      ),
    ]
    var pick = Int.random(in: 0..<weighted.map(\.0).reduce(0, +), using: &random)
    for (weight, step) in weighted {
      if pick < weight { return step }
      pick -= weight
    }
    return .clear
  }

  var description: String {
    "seed \(seed)\(restorable ? ", restorable" : "")\n"
      + steps.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n")
  }
}

@MainActor private final class AdmissionHold {
  var holdsNext = false
  private var release: CheckedContinuation<Bool, Never>?
  var holding: Bool { release != nil }

  func admit(_ deliver: @MainActor () async -> Bool) async -> Bool {
    guard holdsNext else { return await deliver() }
    holdsNext = false
    guard await withCheckedContinuation({ release = $0 }) else { return false }
    return await deliver()
  }
  func end(delivering: Bool) {
    release?.resume(returning: delivering)
    release = nil
  }
}

@MainActor private func settles(_ condition: () async -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(5)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(2))
  }
  return await condition()
}

private let dialRefusedWithoutRedial = NWError.posix(.EACCES)

private func stagesAsControl(_ text: String, on session: CoordinatorSession) async -> Bool? {
  guard
    let staged = await session.stage(
      text, sendID: "invented-retry", recipients: [session.profile])
  else { return nil }
  await session.unstage(staged)
  return staged.departure != nil
}

/// A session renames a temporary file into its outbox, and a copy can meet that file in flight.
private func copyWhileSessionsWrite(_ source: URL, to destination: URL) async throws {
  for attempt in 1...5 {
    do { return try FileManager.default.copyItem(at: source, to: destination) } catch {
      try? FileManager.default.removeItem(at: destination)
      guard attempt < 5, (error as NSError).code == NSFileNoSuchFileError else { throw error }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

private func kind(_ control: Bool?) -> String {
  control.map { $0 ? "control" : "message" } ?? "unstaged"
}

@MainActor private func rejectedNoteInputID(
  in model: ChatModel, at coordinator: GatedCoordinator
) async throws -> String {
  await coordinator.fixture.rejectSubmits()
  model.setChip(coordinator.profile.id)
  model.draft = ReturnOrderReference.restoredText
  await model.send()
  var inputID: String?
  _ = await settles {
    inputID =
      model.snapshots[coordinator.profile.id]?.rows
      .first { $0.delivery == .rejected }?.inputID
    return inputID != nil
  }
  await coordinator.fixture.rejectSubmits(false)
  return try #require(inputID, "The coordinator rejected the note")
}

@MainActor func firstReturnOrderViolation(_ history: ReturnOrderHistory) async throws -> String? {
  var violation: String?
  try await withGatedCoordinators(ReturnOrderReference.coordinators) { coordinators, root in
    for coordinator in coordinators { await coordinator.fixture.holdPlacements() }
    let hold = AdmissionHold()
    let model = try await connectedModel(
      to: coordinators, under: root, admit: { deliver in await hold.admit(deliver) })
    let rejected =
      history.restorable ? try await rejectedNoteInputID(in: model, at: coordinators[0]) : nil
    var reference = ReturnOrderReference(restorable: history.restorable)
    var sending: Task<Void, Never>?

    @MainActor func returned(_ coordinator: GatedCoordinator, from before: String) async -> String?
    {
      guard await settles({ model.draft != before }) else { return "nothing came back" }
      guard await settles({ await coordinator.session.connectionState == .connected }) else {
        return "\(coordinator.profile.name) did not reconnect"
      }
      return nil
    }

    @MainActor func perform(_ action: ReturnOrderReference.Action) async throws -> String? {
      switch action {
      case .send(let send, let fresh, let holdAdmission):
        let coordinator = coordinators[send.to]
        model.setChip(coordinator.profile.id)
        if fresh { model.draft = send.text }
        if send.holdsDial, !holdAdmission { await coordinator.gate.arm() }
        hold.holdsNext = holdAdmission
        guard let task = model.startSend() else {
          return "Send did not start: \(String(describing: model.sendBlocker))"
        }
        sending = task
        if holdAdmission {
          guard await settles({ hold.holding }) else { return "admission never began" }
        } else {
          await task.value
          if send.holdsDial, !(await settles({ await coordinator.gate.waiting })) {
            return "the dial was not held"
          }
        }
      case .refuse:
        hold.end(delivering: false)
        await sending?.value
      case .admit(let send):
        if send.holdsDial { await coordinators[send.to].gate.arm() }
        hold.end(delivering: true)
        await sending?.value
        if send.holdsDial, !(await settles({ await coordinators[send.to].gate.waiting })) {
          return "the dial was not held"
        }
      case .dialFails(let index):
        let before = model.draft
        await coordinators[index].gate.fail(dialRefusedWithoutRedial)
        return await returned(coordinators[index], from: before)
      case .dialPasses(let index):
        await coordinators[index].gate.open()
        let expected = reference.written[index]
        guard await settles({ await coordinators[index].fixture.count() == expected }) else {
          return "\(coordinators[index].profile.name) did not get the control"
        }
      case .edit(let text): model.draft = text
      case .restore(let withReturn):
        guard let rejected else { return "nothing to restore" }
        guard withReturn else {
          await model.restore(rejected)
          return nil
        }
        let restoring = Task { await model.restore(rejected) }
        _ = await settles { model.preparingAttachments || !model.draft.isEmpty }
        await coordinators[0].gate.fail(dialRefusedWithoutRedial)
        await restoring.value
        let expected = reference.draft
        _ = await settles { model.draft == expected }
        return await returned(coordinators[0], from: "")
      }
      return nil
    }

    @MainActor func compare() async throws -> String? {
      let live = model.draft
      guard live == reference.draft else {
        let session = coordinators[0].session
        let liveKind = kind(await stagesAsControl(live, on: session))
        let expectedKind = kind(await stagesAsControl(reference.draft, on: session))
        return "composer \(live.debugDescription) (a retry stages as \(liveKind)), reference "
          + "\(reference.draft.debugDescription) (\(expectedKind))"
      }
      guard await model.saveDraft() else { return "the draft did not save" }
      let copy = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
      try await copyWhileSessionsWrite(root, to: copy)
      defer { try? FileManager.default.removeItem(at: copy) }
      for relaunch in 1...2 {
        let cold = ChatModel(
          draftStore: AttachmentStore(directory: copy.appending(path: "Composer/Files")),
          persistence: ComposerDraftStore(url: copy.appending(path: "Composer/draft.json")))
        cold.profiles = model.profiles
        await cold.restoreDraft()
        guard cold.draftError == nil, cold.draft == reference.recovered else {
          return "relaunch \(relaunch) \(cold.draft.debugDescription) "
            + "(\(cold.draftError ?? "restored")), reference "
            + reference.recovered.debugDescription
        }
      }
      return nil
    }

    for (index, step) in history.steps.enumerated() {
      guard let action = reference.apply(step) else { continue }
      var found = try await perform(action)
      if found == nil { found = try await compare() }
      if let found {
        violation = "step \(index) \(step): \(found)"
        break
      }
    }
    if violation == nil {
      for (index, coordinator) in coordinators.enumerated() {
        let expected = reference.written[index]
        guard await settles({ await coordinator.fixture.count() == expected }) else {
          let got = await coordinator.fixture.count()
          violation = "\(coordinator.profile.name) got \(got) inputs, reference \(expected)"
          break
        }
      }
    }
    if violation == nil, !reference.draft.isEmpty {
      let control = await stagesAsControl(model.draft, on: coordinators[0].session)
      if control != reference.draft.hasPrefix("/") {
        violation = "a retry of \(model.draft.debugDescription) stages as \(kind(control))"
      }
    }
    hold.end(delivering: false)
    await sending?.value
    await model.setActive(false)
  }
  return violation
}

@MainActor func shrunk(_ history: ReturnOrderHistory) async -> ReturnOrderHistory {
  var current = history
  var changed = true
  while changed {
    changed = false
    for index in current.steps.indices.reversed() where index < current.steps.count {
      var candidate = current
      candidate.steps.remove(at: index)
      if (try? await firstReturnOrderViolation(candidate)) != nil {
        current = candidate
        changed = true
      }
    }
  }
  if current.restorable {
    var candidate = current
    candidate.restorable = false
    if (try? await firstReturnOrderViolation(candidate)) != nil { current = candidate }
  }
  return current
}

/// Every seed whose history has ever failed: the 36 a deleted return broke before the walk skipped
/// it, and 66, which a walk that stops at the first mismatch also fails. The default suite plays
/// only these, one at a time, because each history drives four loopback coordinators in the same
/// process as the rest of the host suite. To play every seed from 1 through N in eight parallel
/// lanes, run `COMPOSER_RETURN_SEEDS=N swift test --filter returnOrderExploration` in `ios/`.
let returnOrderCounterexampleSeeds: [UInt64] = [
  33, 66, 119, 133, 309, 335, 398, 686, 709, 872, 873, 1016, 1121, 1216, 1280, 1403, 1421, 1496,
  1581, 1601, 1725, 2123, 2172, 2208, 2283, 2363, 2370, 2385, 2551, 2664, 2706, 2722, 2779, 2833,
  2838, 2917, 2973,
]

@MainActor @Test(.serialized, .timeLimit(.minutes(1)), arguments: returnOrderCounterexampleSeeds)
func returnedTextsKeepTheOrderTheyWereSentInAnyHistory(seed: UInt64) async throws {
  let history = ReturnOrderHistory(seed: seed)
  let violation = try await firstReturnOrderViolation(history)
  #expect(violation == nil, "\(violation ?? "")\n\(history)")
}

private let explorationLastSeed = ProcessInfo.processInfo.environment["COMPOSER_RETURN_SEEDS"]
  .flatMap { UInt64($0) }
private let explorationLanes = 8

@MainActor
@Test(
  .enabled(if: explorationLastSeed != nil), .timeLimit(.minutes(120)),
  arguments: 0..<explorationLanes)
func returnOrderExploration(lane: Int) async throws {
  let last = explorationLastSeed ?? 0
  var played = 0
  var failed: [ReturnOrderHistory] = []
  var errors = 0
  for seed in stride(from: UInt64(lane + 1), through: last, by: explorationLanes) {
    let history = ReturnOrderHistory(seed: seed)
    played += 1
    do {
      if let violation = try await firstReturnOrderViolation(history) {
        failed.append(history)
        print("RETURN ORDER seed=\(seed) FAIL \(violation)")
      }
    } catch {
      errors += 1
      print("RETURN ORDER seed=\(seed) ERROR \(error)")
    }
  }
  for history in failed.prefix(2) {
    let small = await shrunk(history)
    let violation = try? await firstReturnOrderViolation(small)
    print("RETURN ORDER SHRUNK \(small)\n  -> \(violation ?? "passes")")
  }
  print(
    "RETURN ORDER lane=\(lane) played=\(played) failed=\(failed.count) errors=\(errors) "
      + "seeds=\(failed.map(\.seed))")
  #expect(failed.isEmpty && errors == 0)
}
