import Foundation

/// Where a viewer is in one film or one episode from the provider's catalogue.
///
/// Everything needed to put it back on screen and play it again is carried
/// here -- the name, the art, the file type -- so Continue Watching can be
/// drawn and resumed without asking the provider for anything first.
struct OnDemandPlayback: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case movie, episode }

    let kind: Kind
    /// The stream identifier the play URL is built from.
    let streamID: String
    let containerExtension: String
    /// The film's name, or the episode's own title.
    let title: String
    /// A poster: the film's, or the series'.
    let artwork: String?
    /// A wide picture for the card: the episode's still, or a backdrop.
    let still: String?
    let seriesID: String?
    let seriesName: String?
    let season: Int?
    let episode: Int?
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    var completed: Bool
    /// Put here by finishing the episode before it, not by watching any of it.
    var isUpNext: Bool

    var id: String { Self.key(kind, streamID) }

    static func key(_ kind: Kind, _ streamID: String) -> String { kind.rawValue + ":" + streamID }

    /// A series takes one place in Continue Watching, however many of its
    /// episodes have been started.
    var groupKey: String { seriesID.map { "series:" + $0 } ?? id }

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    var episodeCode: String? {
        guard let season, let episode else { return nil }
        return String(format: "S%02dE%02d", season, episode)
    }

    /// The name a card leads with: the series for an episode, since that is
    /// what a viewer is looking for in a row of them.
    var displayName: String { seriesName ?? title }
}

enum OnDemandProgressPolicy {
    static let continueWatchingLimit = 20
    /// Enough history to know what has been watched without keeping it all.
    static let historyLimit = 500

    /// Where to start again, when there is anywhere worth starting from: a few
    /// seconds in is a false start, and a few seconds from the end is finished.
    static func resumePosition(_ record: OnDemandPlayback?) -> TimeInterval? {
        guard let record, !record.completed, !record.isUpNext, record.position >= 10,
              record.duration - record.position > 30 else { return nil }
        return record.position
    }

    static func belongsInContinueWatching(_ record: OnDemandPlayback) -> Bool {
        !record.completed && (record.isUpNext || resumePosition(record) != nil)
    }

    /// Newest first, one place per film or series. The newest record for a
    /// series decides whether it appears at all: an episode finished with
    /// nothing after it takes the series out, even if an older episode was
    /// abandoned half way.
    static func continueWatching(_ records: some Collection<OnDemandPlayback>) -> [OnDemandPlayback] {
        var seen = Set<String>()
        var result: [OnDemandPlayback] = []
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard seen.insert(record.groupKey).inserted else { continue }
            if belongsInContinueWatching(record) { result.append(record) }
            if result.count == continueWatchingLimit { break }
        }
        return result
    }

    /// The records after a player has reported a position.
    ///
    /// `template` names what was playing; `upNext` is the episode after it,
    /// when there is one. Finishing an episode files its successor as up next,
    /// a moment newer so it is the one Continue Watching shows -- unless that
    /// episode already has a place of its own to resume from, which stands.
    static func recording(_ template: OnDemandPlayback, position: TimeInterval,
                          duration: TimeInterval, completed: Bool, upNext: OnDemandPlayback?,
                          now: Date, in records: [String: OnDemandPlayback]) -> [String: OnDemandPlayback] {
        var updated = records
        var record = template
        record.position = max(0, completed ? duration : position)
        record.duration = duration
        record.updatedAt = now
        record.completed = completed
        record.isUpNext = false
        updated[record.id] = record
        if completed, let upNext, upNext.id != record.id {
            let later = now.addingTimeInterval(0.001)
            if var existing = updated[upNext.id], resumePosition(existing) != nil {
                existing.updatedAt = later
                updated[existing.id] = existing
            } else {
                var next = upNext
                next.position = 0
                next.duration = 0
                next.completed = false
                next.isUpNext = true
                next.updatedAt = later
                updated[next.id] = next
            }
        }
        return trimmed(updated)
    }

    /// Marks something watched, or forgets it was ever started.
    static func marking(_ template: OnDemandPlayback, watched: Bool, upNext: OnDemandPlayback?,
                        now: Date, in records: [String: OnDemandPlayback]) -> [String: OnDemandPlayback] {
        guard watched else {
            var updated = records
            updated[template.id] = nil
            return updated
        }
        let duration = max(records[template.id]?.duration ?? 0, template.duration, 1)
        return recording(template, position: duration, duration: duration, completed: true,
                         upNext: upNext, now: now, in: records)
    }

    /// Takes a film or a series out of Continue Watching without saying it was
    /// watched: its records stay, pushed out of the running.
    static func removingFromContinueWatching(_ groupKey: String,
                                             in records: [String: OnDemandPlayback]) -> [String: OnDemandPlayback] {
        records.filter { $0.value.groupKey != groupKey || $0.value.completed }
    }

    static func trimmed(_ records: [String: OnDemandPlayback]) -> [String: OnDemandPlayback] {
        guard records.count > historyLimit else { return records }
        let kept = records.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(historyLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
    }

    // MARK: Series

    /// The episodes in the order a viewer works through them. Specials only
    /// count when the viewer is already in them.
    static func running(_ seasons: [OnDemandSeason], includingSpecials: Bool) -> [OnDemandEpisode] {
        seasons.filter { includingSpecials || !$0.isSpecials }.flatMap(\.episodes)
    }

    static func nextEpisode(after episodeID: String, in seasons: [OnDemandSeason],
                            isCompleted: (String) -> Bool) -> OnDemandEpisode? {
        let inSpecials = seasons.first(where: \.isSpecials)?.episodes.contains { $0.id == episodeID } == true
        let order = running(seasons, includingSpecials: inSpecials)
        guard let index = order.firstIndex(where: { $0.id == episodeID }) else { return nil }
        return order[(index + 1)...].first { !isCompleted($0.id) }
    }

    /// What a series' page offers to play: the episode being watched, else the
    /// one after the last finished, else the first.
    static func startingEpisode(in seasons: [OnDemandSeason],
                                records: [String: OnDemandPlayback]) -> (episode: OnDemandEpisode, resume: TimeInterval?)? {
        let all = seasons.flatMap(\.episodes)
        guard !all.isEmpty else { return nil }
        let ids = Set(all.map(\.id))
        let latest = records.values
            .filter { $0.kind == .episode && ids.contains($0.streamID) }
            .max { $0.updatedAt < $1.updatedAt }
        if let latest, let episode = all.first(where: { $0.id == latest.streamID }) {
            if !latest.completed { return (episode, resumePosition(latest)) }
            let completed: (String) -> Bool = { records[OnDemandPlayback.key(.episode, $0)]?.completed == true }
            if let next = nextEpisode(after: episode.id, in: seasons, isCompleted: completed) {
                return (next, resumePosition(records[OnDemandPlayback.key(.episode, next.id)]))
            }
        }
        return (running(seasons, includingSpecials: false).first ?? all[0], nil)
    }
}
