import Foundation

/// A conservative first pass, never evidence that a channel carries a game.
/// The college/professional policies still score every retained candidate.
/// A positive team match must contain at least the first whole word of one
/// normalized alias. Index only those words from this slate, not a word set
/// for every listing in the provider's guide.
struct MobileSportsCandidateIndex: Sendable {
    struct Channel: Sendable {
        let id: Int
        let name: String
        let guideID: String
    }

    private let coveredWords: Set<String>
    private var channelsByWord: [String: [Int]] = [:]
    private(set) var guideChannelsRead = 0

    init(channels: [Channel], aliases: [String], listings: (String) -> [String]) throws {
        coveredWords = Self.firstWords(aliases)
        guard !coveredWords.isEmpty else { return }
        var guideWords: [String: Set<String>] = [:]
        for channel in channels {
            try Task.checkCancellation()
            if guideWords[channel.guideID] == nil {
                var found: Set<String> = []
                for text in listings(channel.guideID) {
                    try Task.checkCancellation()
                    found.formUnion(words(in: text))
                }
                guideWords[channel.guideID] = found
                guideChannelsRead += 1
            }
            let found = words(in: channel.name).union(guideWords[channel.guideID] ?? [])
            for word in found { channelsByWord[word, default: []].append(channel.id) }
        }
    }

    /// nil means this index does not cover the query: inspect the full pool.
    /// Both teams are deliberately NOT required here. College's verified
    /// one-school/network evidence must also reach the original scorer.
    func candidates(for aliases: [String]) -> Set<Int>? {
        let words = Self.firstWords(aliases)
        guard words.isSubset(of: coveredWords) else { return nil }
        return words.reduce(into: Set<Int>()) { result, word in
            result.formUnion(channelsByWord[word] ?? [])
        }
    }

    private static func firstWords(_ aliases: [String]) -> Set<String> {
        Set(aliases.compactMap { $0.split(separator: " ").first.map(String.init) })
    }

    private func words(in text: String) -> Set<String> {
        Set(text.split(separator: " ").lazy.map(String.init).filter(coveredWords.contains))
    }
}

/// Replaced CPU work stops at its next cancellation check. New work begins
/// immediately; it is never queued behind a full obsolete matching pass.
@MainActor
final class MobileSportsWork {
    enum Lane: Hashable { case index, matching }
    private var jobs: [Lane: (id: UUID, cancel: @Sendable () -> Void)] = [:]

    func replace(_ lane: Lane, cancel: @escaping @Sendable () -> Void) -> UUID {
        jobs.removeValue(forKey: lane)?.cancel()
        if lane == .index { jobs.removeValue(forKey: .matching)?.cancel() }
        let id = UUID()
        jobs[lane] = (id, cancel)
        return id
    }

    func finish(_ lane: Lane, id: UUID) {
        guard jobs[lane]?.id == id else { return }
        jobs[lane] = nil
    }

    func cancel() {
        for job in jobs.values { job.cancel() }
        jobs = [:]
    }
}
