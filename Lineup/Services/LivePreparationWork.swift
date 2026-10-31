import Foundation

/// One active write and one latest pending snapshot per account. A slow disk
/// must not retain a chain of complete guide/schedule snapshots on every score.
@MainActor
final class LatestSnapshotQueue<Key: Hashable, Value: Sendable> {
    private var pending: [Key: Value] = [:]
    private var worker: Task<Void, Never>?

    func submit(key: Key, value: Value,
                operation: @escaping @Sendable (Value) async -> Void) -> Task<Void, Never> {
        pending[key] = value
        if let worker { return worker }
        let task = Task { [self] in
            while let next = pending.first {
                pending[next.key] = nil
                await operation(next.value)
            }
            worker = nil
        }
        worker = task
        return task
    }

    /// Retire pending work for a removed account. An in-progress atomic write
    /// is allowed to finish; callers can await the drain before deleting it.
    func discard(key: Key) -> Task<Void, Never>? {
        pending[key] = nil
        return worker
    }
}

/// A score poll may retire one event while another finishes matching. Publish
/// only results whose own identities still agree, instead of losing the entire
/// day's work because one unrelated court/game changed.
struct PreparedMatchPublication {
    let accepted: Set<String>
    let rejected: Set<String>

    init(requested: Set<String>, snapshot: [String: [String]], current: [String: [String]]) {
        accepted = Set(requested.filter { snapshot[$0] != nil && snapshot[$0] == current[$0] })
        rejected = requested.subtracting(accepted)
    }
}

/// Expiring match preparation does not expire a fresh provider catalog.
struct ProviderPreparationPlan {
    let channels: Bool
    let guide: Bool
    let prepare: Bool

    init(topUp: Bool, libraryFresh: Bool, guideFresh: Bool, dailyDue: Bool, indexReady: Bool) {
        channels = topUp || !libraryFresh
        guide = topUp || !guideFresh
        prepare = dailyDue || !indexReady
    }
}

/// The expensive catalog/guide checks run on a background snapshot. The owner
/// installs the new evidence and these retirements together on the main actor.
struct PreparedMatchReconciliation: Sendable {
    let matches: [String: PreparedLiveMatch]
    let changedIDs: Set<String>

    init(matches: [String: PreparedLiveMatch], streams: [XtreamStream],
         categories: [XtreamCategory], programs: [String: [CurrentProgram]], checkGuide: Bool) {
        let available = Dictionary(streams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = Dictionary(categories.map { ($0.id, $0.matchingName) }, uniquingKeysWith: { first, _ in first })
        var result = matches
        var changed: Set<String> = []
        for (id, saved) in matches {
            let candidates = saved.streams
            let allowed = Set(candidates.filter {
                saved.streamIsCurrent($0, available: available, programs: programs,
                                      categories: groups, checkGuide: checkGuide)
            }.map(\.id))
            guard allowed.count != candidates.count else { continue }
            changed.insert(id)
            result[id] = allowed.isEmpty ? nil : saved.retaining(allowed)
        }
        self.matches = result
        changedIDs = changed
    }
}

/// Provider, schedule and index completions join one pass. Requests arriving
/// during it are combined into one follow-up using the newest inputs.
@MainActor
final class SportsMatchingQueue {
    private var pending: (id: UUID, task: Task<Void, Never>)?
    private var requested = false
    private var forceRequested = false

    @discardableResult
    func request(force: Bool, operation: @escaping @MainActor (Bool) async -> Void) -> Task<Void, Never> {
        requested = true
        forceRequested = forceRequested || force
        if let pending { return pending.task }
        let id = UUID()
        let task = Task { [self] in
            defer { if pending?.id == id { pending = nil } }
            while requested, !Task.isCancelled {
                requested = false
                let force = forceRequested
                forceRequested = false
                await operation(force)
            }
        }
        pending = (id, task)
        return task
    }

    func run(force: Bool, operation: @escaping @MainActor (Bool) async -> Void) async {
        await request(force: force, operation: operation).value
    }

    func cancel() {
        pending?.task.cancel()
        pending = nil
        requested = false
        forceRequested = false
    }
}
