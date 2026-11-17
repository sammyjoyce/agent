@testable import AgentCore
@testable import AgentUI

actor SpotlightFake: SpotlightStore {
  struct Job: Equatable {
    let title: String
    let coordinator: String
    let state: JobRunState
  }

  private(set) var entries: [SpotlightEntry.Key: SpotlightEntry] = [:]
  private(set) var refused = 0
  private enum Plan { case hold, refuse }
  private var next: Plan?
  private var held: CheckedContinuation<Void, any Error>?
  private var arrival: CheckedContinuation<Void, Never>?
  private struct WriteFailed: Error {}

  var coordinators: [ProfileID: String] {
    entries.values.reduce(into: [:]) { coordinators, entry in
      if case .coordinator(let id, let name) = entry { coordinators[id] = name }
    }
  }

  var jobs: [ScopedEntityID: Job] {
    entries.values.reduce(into: [:]) { jobs, entry in
      if case .job(let id, let title, let coordinator, let state) = entry {
        jobs[id] = Job(title: title, coordinator: coordinator, state: state)
      }
    }
  }

  func keys(of profile: ProfileID) -> [SpotlightEntry.Key] {
    entries.keys.filter { key in
      switch key {
      case .coordinator(let id): id == profile
      case .job(let job): job.profile == profile
      }
    }
  }

  func holdNextWrite() { next = .hold }

  func abandonHeldWrite() async {
    if held == nil { await withCheckedContinuation { arrival = $0 } }
    held?.resume(throwing: WriteFailed())
    held = nil
  }

  func refuseNextWrite() { next = .refuse }

  func deleteAll() async throws {
    try await admit()
    entries = [:]
  }

  func index(_ added: [SpotlightEntry]) async throws {
    try await admit()
    for entry in added { entries[entry.key] = entry }
  }

  func delete(_ keys: [SpotlightEntry.Key]) async throws {
    try await admit()
    for key in keys { entries[key] = nil }
  }

  private func admit() async throws {
    let plan = next
    next = nil
    switch plan {
    case .refuse:
      refused += 1
      throw WriteFailed()
    case .hold:
      try await withCheckedThrowingContinuation { continuation in
        held = continuation
        arrival?.resume()
        arrival = nil
      }
    case nil: return
    }
  }
}
