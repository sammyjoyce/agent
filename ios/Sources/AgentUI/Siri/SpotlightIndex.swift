import AgentCore
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

enum SpotlightEntry: Hashable, Sendable {
  case coordinator(ProfileID, name: String)
  case job(ScopedEntityID, title: String, coordinator: String, state: JobRunState)

  enum Key: Hashable, Sendable {
    case coordinator(ProfileID)
    case job(ScopedEntityID)
  }

  var key: Key {
    switch self {
    case .coordinator(let id, _): .coordinator(id)
    case .job(let id, _, _, _): .job(id)
    }
  }

  var coordinatorEntity: CoordinatorEntity? {
    guard case .coordinator(let id, let name) = self else { return nil }
    return CoordinatorEntity(id: "\(id)", name: name)
  }

  var jobEntity: JobEntity? {
    guard case .job(let id, let title, let coordinator, let state) = self else { return nil }
    return JobEntity(indexing: id, title: title, coordinator: coordinator, state: state)
  }
}

protocol SpotlightStore: Sendable {
  func deleteAll() async throws
  func index(_ entries: [SpotlightEntry]) async throws
  func delete(_ keys: [SpotlightEntry.Key]) async throws
}

struct CoreSpotlightStore: SpotlightStore {
  /// `.complete` keeps every name and title unreadable while the phone is locked. A handle per
  /// call keeps the store Sendable.
  private var searchable: CSSearchableIndex {
    CSSearchableIndex(name: "coordinators-and-jobs", protectionClass: .complete)
  }

  func deleteAll() async throws {
    try await searchable.deleteAllSearchableItems()
  }

  func index(_ entries: [SpotlightEntry]) async throws {
    let index = searchable
    let coordinators = entries.compactMap(\.coordinatorEntity)
    let jobs = entries.compactMap(\.jobEntity)
    if !coordinators.isEmpty { try await index.indexAppEntities(coordinators) }
    if !jobs.isEmpty { try await index.indexAppEntities(jobs) }
  }

  func delete(_ keys: [SpotlightEntry.Key]) async throws {
    let index = searchable
    let coordinators = keys.compactMap { key in
      if case .coordinator(let id) = key { "\(id)" } else { nil }
    }
    let jobs = keys.compactMap { key in if case .job(let id) = key { id } else { nil } }
    if !coordinators.isEmpty {
      try await index.deleteAppEntities(identifiedBy: coordinators, ofType: CoordinatorEntity.self)
    }
    if !jobs.isEmpty {
      try await index.deleteAppEntities(identifiedBy: jobs, ofType: JobEntity.self)
    }
  }
}

extension CoordinatorEntity: IndexedEntity {
  public var attributeSet: CSSearchableItemAttributeSet {
    let attributes = CSSearchableItemAttributeSet(contentType: .item)
    attributes.title = name
    attributes.displayName = name
    return attributes
  }
}

extension JobEntity: IndexedEntity {
  /// Built from nothing rather than the default set, so no other property reaches Spotlight.
  public var attributeSet: CSSearchableItemAttributeSet {
    let attributes = CSSearchableItemAttributeSet(contentType: .item)
    attributes.title = title
    attributes.displayName = title
    attributes.contentDescription = coordinatorAndState
    return attributes
  }
}

@MainActor final class SpotlightIndex {
  private struct JobLine: Equatable {
    let item: String
    let title: String
    let state: JobRunState
  }

  private struct Saved {
    var name: String
    var jobs: [JobLine] = []
  }

  private enum Mirror {
    case dormant
    case resetFirst
    case known([SpotlightEntry.Key: SpotlightEntry])
  }

  private let store: any SpotlightStore
  private var saved: [ProfileID: Saved] = [:]
  private var mirror = Mirror.dormant
  private var writing: Task<Void, Never>?
  private var reading: Task<Void, Never>?

  init(store: any SpotlightStore) { self.store = store }

  func save(_ coordinators: [CoordinatorProfile]) {
    saved = Dictionary(
      coordinators.map { ($0.id, Saved(name: "\($0.name)", jobs: saved[$0.id]?.jobs ?? [])) },
      uniquingKeysWith: { first, _ in first })
    write()
  }

  func list(_ jobs: [ScheduledJobStatus], of profile: ProfileID) {
    saved[profile]?.jobs = jobs.map {
      JobLine(item: $0.job.id, title: $0.job.title, state: $0.runState)
    }
    write()
  }

  func activate(listing coordinators: Coordinators) {
    if case .dormant = mirror { mirror = .resetFirst }
    write()
    reading?.cancel()
    let paired = coordinators.profiles.filter { $0.pin != nil }
    reading = Task { [weak coordinators] in
      _ = await coordinators?.jobs(of: paired, within: ConnectionLease.connectionWait)
    }
  }

  func deactivate() {
    reading?.cancel()
    reading = nil
  }

  func settled() async {
    await reading?.value
    while let writing { await writing.value }
  }

  private var wanted: [SpotlightEntry.Key: SpotlightEntry] {
    var entries: [SpotlightEntry.Key: SpotlightEntry] = [:]
    for (profile, coordinator) in saved {
      entries[.coordinator(profile)] = .coordinator(profile, name: coordinator.name)
      for line in coordinator.jobs {
        let job = ScopedEntityID(profile: profile, item: line.item)
        entries[.job(job)] = .job(
          job, title: line.title, coordinator: coordinator.name, state: line.state)
      }
    }
    return entries
  }

  private func step(toward wanted: [SpotlightEntry.Key: SpotlightEntry]) -> SpotlightWrite? {
    switch mirror {
    case .dormant: nil
    case .resetFirst: SpotlightWrite(held: nil, wanted: wanted)
    case .known(let held): SpotlightWrite(held: held, wanted: wanted)
    }
  }

  private func write() {
    guard writing == nil, step(toward: wanted) != nil else { return }
    writing = Task {
      while true {
        let target = wanted
        guard let step = step(toward: target) else { break }
        do {
          try await step.run(on: store)
          mirror = .known(target)
        } catch {
          mirror = .resetFirst
          break
        }
      }
      writing = nil
    }
  }
}

private struct SpotlightWrite {
  let reset: Bool
  let index: [SpotlightEntry]
  let delete: [SpotlightEntry.Key]

  init?(held: [SpotlightEntry.Key: SpotlightEntry]?, wanted: [SpotlightEntry.Key: SpotlightEntry]) {
    guard let held else {
      reset = true
      index = Array(wanted.values)
      delete = []
      return
    }
    let index = wanted.values.filter { held[$0.key] != $0 }
    let delete = held.keys.filter { wanted[$0] == nil }
    guard !index.isEmpty || !delete.isEmpty else { return nil }
    reset = false
    self.index = index
    self.delete = delete
  }

  func run(on store: any SpotlightStore) async throws {
    if reset { try await store.deleteAll() }
    if !delete.isEmpty { try await store.delete(delete) }
    if !index.isEmpty { try await store.index(index) }
  }
}
