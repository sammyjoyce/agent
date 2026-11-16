import AgentCore
import AppIntents
import CoreSpotlight
import UniformTypeIdentifiers

/// One entry of the Spotlight index, and all that Spotlight may know: a saved coordinator's name,
/// and a job's title, coordinator and run state. A prompt, working directory, schedule, run time or
/// output has no case, so none can reach the index.
enum SpotlightEntry: Hashable, Sendable {
  case coordinator(ProfileID, name: String)
  case job(ScopedEntityID, title: String, coordinator: String, state: JobRunState)

  /// The identifier `CoordinatorQuery` or `JobQuery` resolves, so a result opens through Open
  /// Coordinator or Open Job.
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

/// Core Spotlight in the app, a fake in tests. Package initializers default to none, so no test on
/// a Mac host writes the Mac's own Spotlight.
protocol SpotlightStore: Sendable {
  /// Deletes every entry in the index, whichever launch wrote it.
  func deleteAll() async throws
  /// Adds each entry, or replaces the one with its key.
  func index(_ entries: [SpotlightEntry]) async throws
  func delete(_ keys: [SpotlightEntry.Key]) async throws
}

/// The app's own named index.
struct CoreSpotlightStore: SpotlightStore {
  /// `.complete` keeps every name and title unreadable while the phone is locked. A write while
  /// locked fails, and the next activation resets the index. A handle per call keeps the store
  /// Sendable.
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

/// What Spotlight should hold, and its one writer. `ChatModel` tells it which coordinators are
/// saved and each job list a coordinator answers with. It writes nothing until its coordinators are
/// first activated, so under the interaction fixture the app delegate's idle coordinators never
/// touch the index. Its first write in each process resets the index, so a launch after a stop
/// anywhere converges without a record of what an earlier launch wrote.
@MainActor final class SpotlightIndex {
  private struct JobLine: Equatable {
    let item: String
    let title: String
    let state: JobRunState
  }

  /// A saved coordinator's name, and the job list it last answered with in this process.
  private struct Saved {
    var name: String
    var jobs: [JobLine] = []
  }

  private enum Mirror {
    /// No scene has activated the coordinators yet.
    case dormant
    /// The next write resets the index first.
    case unknown
    case known([SpotlightEntry.Key: SpotlightEntry])
  }

  private let store: any SpotlightStore
  /// Saved coordinators, without one being removed. A job list only lands on one of these.
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

  /// A list that lands after Remove began finds its coordinator gone and puts nothing back.
  func list(_ jobs: [ScheduledJobStatus], of profile: ProfileID) {
    saved[profile]?.jobs = jobs.map {
      JobLine(item: $0.job.id, title: $0.job.title, state: $0.runState)
    }
    write()
  }

  /// Starts writing, and reads every paired coordinator's job list, so Spotlight finds jobs
  /// nobody opened Jobs and work for. Each list reaches `list(_:of:)` through
  /// `ChatModel.jobs(_:lane:)`, the one read path.
  func activate(listing coordinators: Coordinators) {
    if case .dormant = mirror { mirror = .unknown }
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

  /// Returns once the activation's read and every write since have finished.
  func settled() async {
    await reading?.value
    while let writing { await writing.value }
  }

  /// A job carries its coordinator's saved name at this moment, so a rename rewrites the
  /// coordinator's jobs without reading them again.
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
    case .unknown: SpotlightWrite(held: nil, wanted: wanted)
    case .known(let held): SpotlightWrite(held: held, wanted: wanted)
    }
  }

  /// A running writer plans again after each step, so a change made meanwhile is written next. A
  /// failed step stops it, and the next change or activation starts over with a reset.
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
          mirror = .unknown
          break
        }
      }
      writing = nil
    }
  }
}

/// One step from what the index holds to what it should hold.
private struct SpotlightWrite {
  let reset: Bool
  let index: [SpotlightEntry]
  let delete: [SpotlightEntry.Key]

  /// nil once `held` is `wanted`. An index whose contents are unknown is reset, then given every
  /// entry.
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
