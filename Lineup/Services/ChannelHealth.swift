import Foundation

/// What Lineup has learned of each live channel from playing it: which ones
/// would not start lately, and which have shown a picture since.
///
/// A game's channel that failed is tried after the others the next time a
/// game is opened, for a few hours -- long enough to cover the game, short
/// enough that a channel down for an afternoon is not shunned for a week.
/// A channel that shows a picture is forgiven at once.
///
/// Channels are known by their name and guide id rather than the provider's
/// number for them, which differs between a single provider's list and the
/// combined one.
@MainActor
final class ChannelHealth {
    static let shared = ChannelHealth()

    struct Record: Codable, Equatable {
        var failedAt: Date?
        var failures = 0
        var playedAt: Date?
    }

    /// How long a failure counts against a channel.
    static let memory: TimeInterval = 6 * 60 * 60
    static let storageKey = "Lineup.channelHealth.v1"

    private var records: [String: Record]
    private let defaults: UserDefaults
    private let clock: () -> Date

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.clock = clock
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
        // A week is long past any game a record could still speak for.
        let cutoff = clock().addingTimeInterval(-7 * 24 * 60 * 60)
        records = saved.filter { ($0.value.failedAt ?? $0.value.playedAt ?? .distantPast) > cutoff }
    }

    nonisolated static func key(for stream: XtreamStream) -> String {
        stream.name.lowercased().trimmingCharacters(in: .whitespaces) + "|" + (stream.epgChannelID ?? "")
    }

    func failed(_ stream: XtreamStream) {
        let key = Self.key(for: stream), now = clock()
        var record = records[key] ?? Record()
        let recent = record.failedAt.map { now.timeIntervalSince($0) < Self.memory } ?? false
        record.failures = recent ? record.failures + 1 : 1
        record.failedAt = now
        records[key] = record
        save()
    }

    func played(_ stream: XtreamStream) {
        let key = Self.key(for: stream)
        var record = records[key] ?? Record()
        guard record.failedAt != nil || record.playedAt == nil
                || clock().timeIntervalSince(record.playedAt ?? .distantPast) > 60 * 60 else { return }
        record.failedAt = nil
        record.failures = 0
        record.playedAt = clock()
        records[key] = record
        save()
    }

    /// Failed within the last few hours, with no picture since.
    func isSuspect(_ stream: XtreamStream) -> Bool {
        guard let failed = records[Self.key(for: stream)]?.failedAt else { return false }
        return clock().timeIntervalSince(failed) < Self.memory
    }

    /// The same list with channels that failed lately moved to the end,
    /// fewest failures first among them, everything else in its order.
    func ordered<T>(_ items: [T], stream: (T) -> XtreamStream?) -> [T] {
        var healthy: [T] = [], suspect: [(item: T, failures: Int, index: Int)] = []
        for (index, item) in items.enumerated() {
            if let channel = stream(item), isSuspect(channel) {
                suspect.append((item, records[Self.key(for: channel)]?.failures ?? 1, index))
            } else {
                healthy.append(item)
            }
        }
        return healthy + suspect.sorted { $0.failures == $1.failures ? $0.index < $1.index : $0.failures < $1.failures }
            .map(\.item)
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(records), forKey: Self.storageKey)
    }
}
